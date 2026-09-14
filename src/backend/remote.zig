//! Remote libSQL backend — Hrana over HTTP (JSON).
//!
//! Pure Zig: no Rust, no cargo. Auth tokens are never logged.

const std = @import("std");
const Io = std.Io;
const err = @import("../error.zig");
const value = @import("../value.zig");
const path_util = @import("../util/path.zig");
const batch_mod = @import("../batch.zig");
const pipeline = @import("hrana/pipeline.zig");
const http = @import("hrana/http.zig");

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: Io,
    /// Current HTTP origin for stream requests (may be rewritten by server).
    base_url: []u8,
    baton: ?[]u8,
    auth_token: ?[]u8,
    last_affected: i64 = 0,
    last_insert_rowid: i64 = 0,
    closed: bool = false,
    /// Last server/pipeline error message (owned). Never logs secrets.
    last_error_message: ?[]u8 = null,

    pub fn open(
        io: Io,
        allocator: std.mem.Allocator,
        url: []const u8,
        auth_token: ?[]const u8,
        allow_insecure: bool,
    ) err.Error!Session {
        const http_base = path_util.toHttpBase(allocator, url) catch return error.InvalidPath;
        errdefer allocator.free(http_base);

        // Fail closed on plaintext (non-TLS) transport. `http://` / `ws://`
        // origins expose the SQL and results in cleartext, and a bearer token
        // would leak outright, so:
        //   - a token over plaintext is always rejected, and
        //   - tokenless plaintext requires an explicit `allow_insecure` opt-in
        //     rather than silently falling back to cleartext.
        if (!std.mem.startsWith(u8, http_base, "https://")) {
            if (auth_token != null or !allow_insecure) return error.InvalidPath;
        }

        var token_owned: ?[]u8 = null;
        errdefer if (token_owned) |t| allocator.free(t);
        if (auth_token) |t| {
            token_owned = allocator.dupe(u8, t) catch return error.OutOfMemory;
        }

        return .{
            .allocator = allocator,
            .io = io,
            .base_url = http_base,
            .baton = null,
            .auth_token = token_owned,
        };
    }

    pub fn deinit(self: *Session) void {
        if (!self.closed) {
            self.closeStream() catch {};
        }
        if (self.baton) |b| self.allocator.free(b);
        if (self.auth_token) |t| self.allocator.free(t);
        if (self.last_error_message) |m| self.allocator.free(m);
        self.allocator.free(self.base_url);
        self.* = undefined;
    }

    /// Last Hrana/server error message. Empty when none. Owned by Session;
    /// valid until the next remote op or `deinit`.
    pub fn lastErrorMessage(self: *const Session) []const u8 {
        return self.last_error_message orelse "";
    }

    fn clearLastError(self: *Session) void {
        if (self.last_error_message) |m| {
            self.allocator.free(m);
            self.last_error_message = null;
        }
    }

    /// On pipeline failure, adopt `out.error_message` into `last_error_message`
    /// and return `error.Sql`. On success, clear the last error.
    fn finishOutcome(self: *Session, out: *pipeline.PipelineOutcome) err.Error!void {
        if (!out.failed) {
            self.clearLastError();
            return;
        }
        if (out.error_message) |m| {
            self.clearLastError();
            self.last_error_message = m;
            out.error_message = null;
        } else {
            // Failed without a message: keep prior diagnostic if any, or set generic.
            if (self.last_error_message == null) {
                self.last_error_message = self.allocator.dupe(u8, "remote pipeline failed") catch null;
            }
        }
        return error.Sql;
    }

    pub fn closeStream(self: *Session) err.Error!void {
        if (self.closed) return;
        if (self.baton == null) {
            self.closed = true;
            return;
        }
        const body = try pipeline.buildCloseBody(self.allocator, self.baton);
        defer self.allocator.free(body);
        var out = try self.roundTrip(body);
        defer out.deinit(self.allocator);
        // The close request was sent; mark the stream closed regardless, then
        // surface a server-reported failure instead of silently swallowing it.
        self.closed = true;
        try self.finishOutcome(&out);
    }

    /// Execute multi-statement SQL; rows discarded (Hrana `sequence`).
    pub fn sequence(self: *Session, sql: []const u8) err.Error!void {
        if (self.closed) return error.Sql;
        const body = try pipeline.buildSequenceBody(self.allocator, self.baton, sql);
        defer self.allocator.free(body);
        var out = try self.roundTrip(body);
        defer out.deinit(self.allocator);
        try self.finishOutcome(&out);
    }

    /// Execute a single statement with positional and named binds.
    pub fn execute(
        self: *Session,
        sql: []const u8,
        args: []const value.Value,
        named_args: []const pipeline.NamedArg,
        want_rows: bool,
    ) err.Error!pipeline.StmtResult {
        if (self.closed) return error.Sql;
        const body = try pipeline.buildExecuteBody(self.allocator, self.baton, sql, args, named_args, want_rows);
        defer self.allocator.free(body);
        var out = try self.roundTrip(body);
        defer out.deinit(self.allocator);
        try self.finishOutcome(&out);
        // A successful `execute` always carries a statement result; a missing one
        // is a protocol violation, not an empty success.
        const stmt = out.stmt orelse return error.Sql;
        out.stmt = null;
        self.last_affected = @intCast(stmt.affected_row_count);
        self.last_insert_rowid = stmt.last_insert_rowid;
        return stmt;
    }

    /// Run a transactional batch (BEGIN + steps + COMMIT with ok-conditions).
    pub fn batch(self: *Session, steps: []const batch_mod.Step) err.Error!batch_mod.Result {
        if (self.closed) return error.Sql;
        if (steps.len == 0) return .{};

        const body = try pipeline.buildBatchBody(self.allocator, self.baton, steps);
        defer self.allocator.free(body);
        var out = try self.roundTrip(body);
        defer out.deinit(self.allocator);
        try self.finishOutcome(&out);

        self.last_affected = out.batch_affected;
        return .{
            .steps_run = out.batch_steps_run,
            .total_affected = out.batch_affected,
        };
    }

    fn roundTrip(self: *Session, body: []const u8) err.Error!pipeline.PipelineOutcome {
        const url = try http.pipelineUrl(self.allocator, self.base_url);
        defer self.allocator.free(url);

        const resp_body = try http.postPipeline(
            self.io,
            self.allocator,
            url,
            self.auth_token,
            body,
        );
        defer self.allocator.free(resp_body);

        var out = try pipeline.parsePipelineResponse(self.allocator, resp_body);
        errdefer out.deinit(self.allocator);

        if (self.baton) |old| self.allocator.free(old);
        self.baton = out.baton;
        out.baton = null;

        if (out.base_url) |new_base| {
            // Only honor a base_url override that stays on the same origin. A
            // server-chosen cross-origin value would redirect subsequent stream
            // requests (which still carry the bearer token) to an arbitrary
            // host: SSRF plus token exfiltration. Fail closed instead.
            if (!sameOrigin(self.base_url, new_base)) return error.Sql;
            self.allocator.free(self.base_url);
            self.base_url = new_base;
            out.base_url = null;
        }

        if (self.baton == null) {
            self.closed = true;
        }

        return out;
    }
};

/// True when both URLs share the same `scheme://authority` origin (case-insensitive).
fn sameOrigin(a: []const u8, b: []const u8) bool {
    const oa = originOf(a) orelse return false;
    const ob = originOf(b) orelse return false;
    return std.ascii.eqlIgnoreCase(oa, ob);
}

/// Return the `scheme://authority` prefix of a URL (no path/query/fragment), or
/// null when the input has no `scheme://` separator.
fn originOf(url: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    const authority_start = sep + 3;
    if (authority_start > url.len) return null;
    const rest = url[authority_start..];
    const off = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return url[0 .. authority_start + off];
}

test "session open maps libsql url" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.open(io, gpa, "libsql://db.example.com", "tok", false);
    defer s.deinit();
    try std.testing.expectEqualStrings("https://db.example.com", s.base_url);
}

test "finishOutcome adopts pipeline error_message" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.open(io, gpa, "https://db.example.com", null, true);
    defer s.deinit();

    var out = pipeline.PipelineOutcome{
        .baton = null,
        .base_url = null,
        .stmt = null,
        .failed = true,
        .error_message = try gpa.dupe(u8, "constraint failed"),
    };
    // finishOutcome takes ownership of error_message on failure.
    try std.testing.expectError(error.Sql, s.finishOutcome(&out));
    try std.testing.expect(out.error_message == null);
    try std.testing.expectEqualStrings("constraint failed", s.lastErrorMessage());
    out.deinit(gpa);

    // Success clears the stored diagnostic.
    var ok = pipeline.PipelineOutcome{
        .baton = null,
        .base_url = null,
        .stmt = null,
        .failed = false,
        .error_message = null,
    };
    try s.finishOutcome(&ok);
    ok.deinit(gpa);
    try std.testing.expectEqualStrings("", s.lastErrorMessage());
}

test "session rejects token over plaintext http" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // A token over plaintext is rejected regardless of the insecure opt-in.
    try std.testing.expectError(error.InvalidPath, Session.open(io, gpa, "http://db.example.com", "tok", false));
    try std.testing.expectError(error.InvalidPath, Session.open(io, gpa, "ws://db.example.com", "tok", false));
    try std.testing.expectError(error.InvalidPath, Session.open(io, gpa, "http://db.example.com", "tok", true));
}

test "session rejects tokenless plaintext without opt-in" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Fail closed: tokenless plaintext still exposes SQL/results in cleartext.
    try std.testing.expectError(error.InvalidPath, Session.open(io, gpa, "http://db.example.com", null, false));
    try std.testing.expectError(error.InvalidPath, Session.open(io, gpa, "ws://db.example.com", null, false));
}

test "session allows plaintext http without token when opted in" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.open(io, gpa, "http://db.example.com", null, true);
    defer s.deinit();
    try std.testing.expectEqualStrings("http://db.example.com", s.base_url);
}

test "sameOrigin accepts same origin, rejects cross-origin" {
    // Same origin (path differences ignored, host case-insensitive).
    try std.testing.expect(sameOrigin("https://db.example.com", "https://db.example.com/v3"));
    try std.testing.expect(sameOrigin("https://DB.Example.com", "https://db.example.com"));
    // Different host, scheme, or port are cross-origin.
    try std.testing.expect(!sameOrigin("https://db.example.com", "https://evil.example.com"));
    try std.testing.expect(!sameOrigin("https://db.example.com", "http://db.example.com"));
    try std.testing.expect(!sameOrigin("https://db.example.com", "https://db.example.com:8443"));
}
