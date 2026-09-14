//! HTTP transport for Hrana over HTTP (JSON, v3/pipeline).

const std = @import("std");
const Io = std.Io;
const err = @import("../../error.zig");

/// Hard cap on a single v3/pipeline response body (bytes).
pub const max_response_bytes: usize = 32 * 1024 * 1024;

/// Stack buffer size for `Authorization: Bearer …` (token + prefix).
pub const max_auth_header_bytes: usize = 512;

pub fn postPipeline(
    io: Io,
    allocator: std.mem.Allocator,
    pipeline_url: []const u8,
    auth_token: ?[]const u8,
    body: []const u8,
) err.Error![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var auth_buf: [max_auth_header_bytes]u8 = undefined;
    var headers_buf: [2]std.http.Header = undefined;
    var header_count: usize = 1;
    headers_buf[0] = .{ .name = "content-type", .value = "application/json" };

    if (auth_token) |tok| {
        // Oversized tokens are a client configuration error, not a SQL failure.
        if (tok.len + "Bearer ".len >= auth_buf.len) return error.InvalidPath;
        const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{tok}) catch return error.InvalidPath;
        headers_buf[1] = .{ .name = "authorization", .value = auth };
        header_count = 2;
    }

    // Grow with the response instead of reserving the full 32 MiB up front,
    // but enforce max_response_bytes during streaming: the writer refuses to
    // grow past the cap, so an oversized body fails mid-fetch (surfaced as
    // error.Sql) and can never force an allocation larger than the cap.
    var cw = CappedResponseWriter.init(allocator, max_response_bytes);
    defer cw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = pipeline_url },
        .method = .POST,
        .payload = body,
        .extra_headers = headers_buf[0..header_count],
        .response_writer = &cw.writer,
        // Do not follow redirects with POST body blindly.
        .redirect_behavior = .not_allowed,
    }) catch return error.Sql;

    const status: u16 = @intFromEnum(result.status);
    if (status < 200 or status >= 300) return error.Sql;

    return cw.toOwnedSlice() catch return error.OutOfMemory;
}

/// A `std.Io.Writer` that grows its heap buffer with the response but never
/// past `max` bytes. Writing past the cap returns `error.WriteFailed`, which
/// aborts `client.fetch` mid-stream, so a hostile or misconfigured server
/// cannot drive an allocation larger than the cap before rejection.
const CappedResponseWriter = struct {
    writer: std.Io.Writer,
    allocator: std.mem.Allocator,
    max: usize,

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .rebase = rebase,
        // Data accumulates in the buffer and is never consumed, so flushing is
        // a no-op (the default flush would loop on drain forever).
        .flush = flushNoop,
    };

    fn init(allocator: std.mem.Allocator, max: usize) CappedResponseWriter {
        return .{
            .allocator = allocator,
            .max = max,
            .writer = .{ .buffer = &.{}, .vtable = &vtable },
        };
    }

    fn deinit(self: *CappedResponseWriter) void {
        if (self.writer.buffer.len != 0) self.allocator.free(self.writer.buffer);
        self.* = undefined;
    }

    fn written(self: *const CappedResponseWriter) []u8 {
        return self.writer.buffer[0..self.writer.end];
    }

    fn toOwnedSlice(self: *CappedResponseWriter) std.mem.Allocator.Error![]u8 {
        return self.allocator.dupe(u8, self.written());
    }

    /// Ensure the buffer can hold `need` total bytes, growing geometrically on
    /// the heap but clamped to `max`. Requesting more than `max` fails.
    fn ensureTotal(self: *CappedResponseWriter, need: usize) std.Io.Writer.Error!void {
        if (need > self.max) return error.WriteFailed;
        if (need <= self.writer.buffer.len) return;
        const doubled = self.writer.buffer.len *| 2;
        const target = @min(self.max, @max(need, @max(doubled, 4096)));
        const grown = self.allocator.realloc(self.writer.buffer, target) catch
            return error.WriteFailed;
        self.writer.buffer = grown;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *CappedResponseWriter = @fieldParentPtr("writer", w);
        const start = w.end;
        const pattern = data[data.len - 1];
        for (data) |bytes| {
            try self.ensureTotal(w.end +| bytes.len);
            @memcpy(w.buffer[w.end..][0..bytes.len], bytes);
            w.end += bytes.len;
        }
        // The final slice is repeated `splat` times; it was already written
        // once by the loop above.
        if (splat == 0) {
            w.end -= pattern.len;
        } else switch (pattern.len) {
            0 => {},
            1 => {
                try self.ensureTotal(w.end +| (splat - 1));
                @memset(w.buffer[w.end..][0 .. splat - 1], pattern[0]);
                w.end += splat - 1;
            },
            else => for (0..splat - 1) |_| {
                try self.ensureTotal(w.end +| pattern.len);
                @memcpy(w.buffer[w.end..][0..pattern.len], pattern);
                w.end += pattern.len;
            },
        }
        return w.end - start;
    }

    fn rebase(w: *std.Io.Writer, preserve: usize, minimum_len: usize) std.Io.Writer.Error!void {
        _ = preserve; // data is never discarded, so nothing to preserve-shift.
        const self: *CappedResponseWriter = @fieldParentPtr("writer", w);
        try self.ensureTotal(w.end +| minimum_len);
    }

    fn flushNoop(w: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = w;
    }
};

/// Join base URL (no trailing slash preferred) with `/v3/pipeline`.
pub fn pipelineUrl(allocator: std.mem.Allocator, base: []const u8) err.Error![]u8 {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    return std.fmt.allocPrint(allocator, "{s}/v3/pipeline", .{trimmed}) catch return error.OutOfMemory;
}

test "pipeline url join" {
    const gpa = std.testing.allocator;
    const u = try pipelineUrl(gpa, "https://example.turso.io/");
    defer gpa.free(u);
    try std.testing.expectEqualStrings("https://example.turso.io/v3/pipeline", u);
}

test "capped response writer rejects oversize bodies mid-stream" {
    const gpa = std.testing.allocator;
    var cw = CappedResponseWriter.init(gpa, 8);
    defer cw.deinit();
    const w = &cw.writer;
    try w.writeAll("1234");
    try w.writeAll("5678"); // exactly at the cap
    try std.testing.expectError(error.WriteFailed, w.writeAll("9"));
    try std.testing.expectEqualStrings("12345678", cw.written());
}

test "capped response writer hands over small bodies" {
    const gpa = std.testing.allocator;
    var cw = CappedResponseWriter.init(gpa, 1024);
    defer cw.deinit();
    const w = &cw.writer;
    try w.writeAll("hello ");
    try w.print("{d}", .{42});
    const owned = try cw.toOwnedSlice();
    defer gpa.free(owned);
    try std.testing.expectEqualStrings("hello 42", owned);
}

test "auth header oversize is InvalidPath" {
    // postPipeline without a real server: only the pre-request path is checked.
    // A token that fills the 512-byte buffer must not map to error.Sql.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var huge: [max_auth_header_bytes]u8 = undefined;
    @memset(&huge, 'a');
    // Bearer + token >= 512 → InvalidPath before any HTTP.
    const tok = huge[0 .. max_auth_header_bytes - "Bearer ".len];
    try std.testing.expectError(error.InvalidPath, postPipeline(
        io,
        gpa,
        "https://example.turso.io/v3/pipeline",
        tok,
        "{}",
    ));
}
