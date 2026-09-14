const std = @import("std");
const Io = std.Io;
const c = @import("c/sqlite.zig");
const err = @import("error.zig");
const path_util = @import("util/path.zig");
const Connection = @import("connection.zig").Connection;
const remote = @import("backend/remote.zig");
const bridge = @import("backend/bridge.zig");
const inject = @import("backend/replication/inject.zig");
const rep_client = @import("backend/replication/client.zig");
const rep_meta = @import("backend/replication/meta.zig");

pub const OpenOptions = struct {
    /// File path, `:memory:`, `file:…`, or remote URL (`libsql://`, `https://`, …).
    path: []const u8,
    /// When set with a local `path`, enables classic embedded-replica mode:
    /// local file for reads + `Database.sync()` via rusty bridge (R1) or pure
    /// Zig pull+inject (R3b when available).
    /// Remote-only opens use `path` as the URL instead.
    sync_url: ?[]const u8 = null,
    /// Remote auth token (never logged). Required for most remote servers and
    /// required when `sync_url` is set (replica open).
    auth_token: ?[]const u8 = null,
    /// Allow a remote connection over plaintext (`http://` / `ws://`) transport.
    /// Off by default (fail closed): plaintext exposes SQL and results in
    /// cleartext. A bearer token is rejected over plaintext even when this is
    /// set — tokens always require HTTPS. Remote only; ignored for local.
    allow_insecure: bool = false,
    /// Open read-only (local only).
    read_only: bool = false,
    /// Create file if missing (local only; default true when not read_only).
    create: bool = true,
    /// Required for remote backends (HTTP) and pure Zig replica sync (R2/R3b).
    /// Optional for R1 rusty-bridge-only replica open.
    io: ?Io = null,
    /// Classic RYW while the libsql handle is alive during `sync()` (passed to bridge).
    read_your_writes: bool = true,
};

pub const SyncResult = bridge.SyncResult;

/// Owns a local database handle, a remote Hrana session, and/or replica sync config.
///
/// **Connections:** `connect()` returns a non-owning view tied to `conn_gen`.
/// After `sync()` (or any path that closes/reopens `local_db`), prior
/// `Connection` values return `error.Open` on local ops — reconnect with
/// `connect()`.
pub const Database = struct {
    allocator: std.mem.Allocator,
    /// Owned copy of the original open path (for diagnostics / local file).
    path: []const u8,
    kind: path_util.Kind,
    local_db: ?*c.sqlite3 = null,
    session: ?*remote.Session = null,
    /// Replica: owned primary URL for `sync()` (null if not a replica).
    sync_url: ?[]const u8 = null,
    /// Owned token for replica sync (never logged).
    auth_token: ?[]const u8 = null,
    read_your_writes: bool = true,
    /// Local open flags restored after `sync()` reopens the file.
    local_flags: c_int = 0,
    /// Pure Zig replica path needs Io for gRPC-Web pull (R2.1/R3b).
    io: ?Io = null,
    /// Bumped whenever `local_db` is closed so existing Connections fail closed.
    conn_gen: u64 = 0,
    /// Last bridge sync diagnostic (owned); never logs secrets. Cleared on success.
    last_sync_error: ?[]u8 = null,

    pub fn open(allocator: std.mem.Allocator, opts: OpenOptions) err.Error!Database {
        const parsed = path_util.parse(opts.path);

        // Classic embedded replica: local file + sync_url.
        if (opts.sync_url) |surl| {
            if (parsed.kind != .file) return error.InvalidPath;
            if (opts.auth_token == null) return error.InvalidPath;
            if (surl.len == 0) return error.InvalidPath;

            // Apply path must exist: rusty bridge and/or pure inject engine.
            const bridge_ok = bridge.isCompileEnabled();
            const pure_ok = inject.engine_supports_inject;
            if (!bridge_ok and !pure_ok) return error.Unsupported;
            // Pure path needs Io for pull; bridge can sync without it.
            if (!bridge_ok and opts.io == null) return error.Unsupported;

            const path_owned = allocator.dupe(u8, parsed.path) catch return error.OutOfMemory;
            errdefer allocator.free(path_owned);
            const surl_owned = allocator.dupe(u8, surl) catch return error.OutOfMemory;
            errdefer allocator.free(surl_owned);
            const token_owned = allocator.dupe(u8, opts.auth_token.?) catch return error.OutOfMemory;
            errdefer allocator.free(token_owned);

            var flags: c_int = 0;
            if (opts.read_only) {
                flags |= c.SQLITE_OPEN_READONLY;
            } else {
                flags |= c.SQLITE_OPEN_READWRITE;
                if (opts.create) flags |= c.SQLITE_OPEN_CREATE;
            }
            flags |= c.SQLITE_OPEN_URI;
            flags |= c.SQLITE_OPEN_FULLMUTEX;

            const local = try openLocalPath(allocator, path_owned, flags);
            return .{
                .allocator = allocator,
                .path = path_owned,
                .kind = .file,
                .local_db = local,
                .sync_url = surl_owned,
                .auth_token = token_owned,
                .read_your_writes = opts.read_your_writes,
                .local_flags = flags,
                .io = opts.io,
            };
        }

        const path_owned = allocator.dupe(u8, opts.path) catch return error.OutOfMemory;
        errdefer allocator.free(path_owned);

        switch (parsed.kind) {
            .remote => {
                const io = opts.io orelse return error.Unsupported;
                // Fail-closed transport is enforced inside Session.open
                // (token always requires HTTPS; tokenless plaintext needs allow_insecure).
                const session_ptr = allocator.create(remote.Session) catch return error.OutOfMemory;
                errdefer allocator.destroy(session_ptr);
                session_ptr.* = try remote.Session.open(io, allocator, opts.path, opts.auth_token, opts.allow_insecure);
                return .{
                    .allocator = allocator,
                    .path = path_owned,
                    .kind = .remote,
                    .session = session_ptr,
                };
            },
            .memory, .file => {
                const open_path = if (parsed.kind == .memory) ":memory:" else parsed.path;
                var flags: c_int = 0;
                if (opts.read_only) {
                    flags |= c.SQLITE_OPEN_READONLY;
                } else {
                    flags |= c.SQLITE_OPEN_READWRITE;
                    if (opts.create) flags |= c.SQLITE_OPEN_CREATE;
                }
                flags |= c.SQLITE_OPEN_URI;
                flags |= c.SQLITE_OPEN_FULLMUTEX;

                const local = try openLocalPath(allocator, open_path, flags);
                return .{
                    .allocator = allocator,
                    .path = path_owned,
                    .kind = parsed.kind,
                    .local_db = local,
                    .local_flags = flags,
                };
            },
        }
    }

    pub fn deinit(self: *Database) void {
        if (self.local_db) |db| {
            _ = c.sqlite3_close_v2(db);
            self.local_db = null;
        }
        self.conn_gen +%= 1;
        if (self.session) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        if (self.sync_url) |u| self.allocator.free(u);
        if (self.auth_token) |t| self.allocator.free(t);
        if (self.last_sync_error) |m| self.allocator.free(m);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    /// Non-owning connection view.
    ///
    /// Do not use after `Database.deinit`. After `sync()`, this connection is
    /// invalidated (local ops return `error.Open`); call `connect()` again.
    pub fn connect(self: *Database) Connection {
        return switch (self.kind) {
            .remote => .{
                .allocator = self.allocator,
                .kind = .remote,
                .session = self.session,
            },
            .memory, .file => .{
                .allocator = self.allocator,
                .kind = .local,
                .db = self.local_db,
                .owns_db = false,
                .local_gen = self.conn_gen,
                .local_gen_src = &self.conn_gen,
            },
        };
    }

    /// Last bridge sync error message (replica only). Empty when none.
    /// Owned by Database; valid until next `sync()` or `deinit`.
    pub fn lastSyncError(self: *const Database) []const u8 {
        return self.last_sync_error orelse "";
    }

    fn clearSyncError(self: *Database) void {
        if (self.last_sync_error) |m| {
            self.allocator.free(m);
            self.last_sync_error = null;
        }
    }

    fn setSyncError(self: *Database, msg: []const u8) void {
        self.clearSyncError();
        if (msg.len == 0) return;
        self.last_sync_error = self.allocator.dupe(u8, msg) catch null;
    }

    pub fn isRemote(self: *const Database) bool {
        return self.kind == .remote;
    }

    pub fn isReplica(self: *const Database) bool {
        return self.sync_url != null;
    }

    /// Classic embedded replica pull.
    ///
    /// Preference order:
    /// 1. R1 rusty bridge when compiled in (`-Denable-rust-bridge`)
    /// 2. Pure Zig pull + inject when `inject.available()` (R3b)
    ///
    /// Closes the local SQLite handle for the duration of sync (official clients
    /// forbid concurrent open during inject), then reopens it. **All existing
    /// `Connection` values from `connect()` are invalidated** — call `connect()`
    /// again after a successful or recovered sync.
    ///
    /// On failure the local handle is reopened best-effort. If that reopen also
    /// fails, its error is returned (superseding any sync error) to signal that
    /// `local_db` is null; local ops on new connections return `error.Open`.
    pub fn sync(self: *Database) err.Error!SyncResult {
        const surl = self.sync_url orelse return error.Unsupported;
        const token = self.auth_token orelse return error.Unsupported;

        // Exclusive: no concurrent local use during inject. Bump generation so
        // any Connection still holding the old handle fails closed.
        if (self.local_db) |db| {
            _ = c.sqlite3_close_v2(db);
            self.local_db = null;
        }
        self.conn_gen +%= 1;

        // Zeroed so the pure path (and early bridge errors that never touch the
        // buffer) yield an empty diagnostic instead of reading undefined memory.
        var bridge_err = std.mem.zeroes([512]u8);
        const result = self.syncImpl(surl, token, &bridge_err) catch |e| {
            // Capture sync diagnostic before reopen (never log secrets).
            const msg = std.mem.sliceTo(&bridge_err, 0);
            self.setSyncError(msg);
            // Best-effort reopen so the Database remains usable after a failed sync.
            // If the reopen itself fails, surface that error: `local_db` is now null
            // and local ops return `error.Open` (no panic on null handle).
            self.local_db = openLocalPath(self.allocator, self.path, self.local_flags) catch |reopen_err| {
                return reopen_err;
            };
            return e;
        };

        self.clearSyncError();
        self.local_db = try openLocalPath(self.allocator, self.path, self.local_flags);
        return result;
    }

    fn syncImpl(self: *Database, surl: []const u8, token: []const u8, err_out: ?*[512]u8) err.Error!SyncResult {
        if (bridge.isCompileEnabled()) {
            return bridge.syncOnce(self.path, surl, token, self.read_your_writes, err_out);
        }
        // Pure Zig path has no 512-byte bridge diagnostic buffer; errors carry
        // no message, so `err_out` stays zeroed (empty last_sync_error).
        return self.syncPure(surl, token);
    }

    /// Pure Zig: gRPC-Web pull (R2.1/R3a) + WAL inject (R3b when `inject.available`).
    fn syncPure(self: *Database, surl: []const u8, token: []const u8) err.Error!SyncResult {
        if (!inject.available()) return error.Unsupported;
        const io = self.io orelse return error.Unsupported;

        var client = try rep_client.Client.open(io, self.allocator, surl, token, "default");
        defer client.deinit();

        var meta = (rep_meta.load(io, self.allocator, self.path) catch return error.Sql) orelse
            rep_meta.WalIndexMeta{
                .log_id = 0,
                .committed_frame_no = rep_meta.WalIndexMeta.none_frame,
            };

        var pull = try client.pullUntilCaughtUp(meta.nextOffset(), null, 64);
        defer pull.deinit();

        if (pull.frames.len == 0) {
            const fn_opt: ?i64 = if (meta.currentFrameNo()) |n| @intCast(n) else null;
            return .{ .frame_no = fn_opt, .frames_synced = 0 };
        }

        const applied = try inject.applyFrames(self.allocator, self.path, pull.frames);
        // Only advance meta after successful inject commit.
        if (applied.last_commit_frame_no) |n| {
            meta.committed_frame_no = n;
            if (pull.log_id.len != 0) {
                meta.log_id = rep_client.logIdFromUuidString(pull.log_id) catch meta.log_id;
            }
            rep_meta.save(io, self.allocator, self.path, meta) catch return error.Sql;
        }

        return .{
            .frame_no = if (applied.last_commit_frame_no) |n| @intCast(n) else null,
            .frames_synced = applied.frames_applied,
        };
    }
};

fn openLocalPath(allocator: std.mem.Allocator, open_path: []const u8, flags: c_int) err.Error!*c.sqlite3 {
    const zpath = allocator.dupeZ(u8, open_path) catch return error.OutOfMemory;
    defer allocator.free(zpath);

    var db_ptr: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(zpath.ptr, &db_ptr, flags, null);
    if (rc != c.SQLITE_OK or db_ptr == null) {
        if (db_ptr) |d| _ = c.sqlite3_close(d);
        if (rc == c.SQLITE_NOMEM) return error.OutOfMemory;
        return error.Open;
    }
    return db_ptr.?;
}

/// Convenience: open a local path (or `:memory:`) as an owning `Connection`.
/// Remote URLs and replica mode are not supported here — use `Database.open`.
pub fn open(allocator: std.mem.Allocator, path: []const u8) err.Error!Connection {
    const parsed = path_util.parse(path);
    if (parsed.kind == .remote) return error.Unsupported;

    var db = try Database.open(allocator, .{ .path = path });
    const conn = Connection{
        .allocator = allocator,
        .kind = .local,
        .db = db.local_db,
        .owns_db = true,
    };
    allocator.free(db.path);
    db.local_db = null;
    db = undefined;
    return conn;
}

test "replica open without bridge or libsql engine is Unsupported" {
    if (bridge.isCompileEnabled()) return;
    if (inject.engine_supports_inject) return;
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.Unsupported, Database.open(gpa, .{
        .path = "/tmp/zig-libsql-replica-test.db",
        .sync_url = "libsql://example.turso.io",
        .auth_token = "secret",
    }));
}

test "replica open on libsql engine without io is Unsupported when no bridge" {
    if (bridge.isCompileEnabled()) return;
    if (!inject.engine_supports_inject) return;
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.Unsupported, Database.open(gpa, .{
        .path = "/tmp/zig-libsql-replica-test.db",
        .sync_url = "libsql://example.turso.io",
        .auth_token = "secret",
        // io missing → pure path closed
    }));
}

test "replica open requires auth_token" {
    if (!bridge.isCompileEnabled() and !inject.engine_supports_inject) return;
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidPath, Database.open(gpa, .{
        .path = "/tmp/zig-libsql-replica-test.db",
        .sync_url = "libsql://example.turso.io",
    }));
}

test "memory open survives allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn f(allocator: std.mem.Allocator) !void {
            var db = try Database.open(allocator, .{ .path = ":memory:" });
            defer db.deinit();
            var conn = db.connect();
            try conn.exec("select 1;", .{});
        }
    }.f, .{});
}
