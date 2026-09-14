//! HTTPS transport for classic `ReplicationLog` gRPC-Web RPCs.
//!
//! Supports unary (Hello, BatchLogEntries) and server-streaming (Snapshot)
//! responses. Mirrors Hrana HTTP policy: never log tokens; fail closed on
//! plaintext when an auth token is present; bound response body size.
//!
//! Snapshot responses share the same in-memory body cap as unary (64 MiB).
//! Huge databases may need a higher cap or disk-backed streaming later.

const std = @import("std");
const Io = std.Io;
const err = @import("../../error.zig");
const path_util = @import("../../util/path.zig");
const grpc_web = @import("grpc_web.zig");

/// Client identifier sent as `x-libsql-client-version` (not a secret).
pub const client_version = "zig-libsql-rpc-0.2.0";

/// Max response body for unary and stream RPCs (batches / snapshots of ~4 KiB frames).
const max_response_bytes = 64 * 1024 * 1024; // 64 MiB

pub const RequestHeaders = struct {
    auth_token: []const u8,
    /// Raw namespace bytes (default `"default"`); sent base64 in `x-namespace-bin`.
    namespace: []const u8 = "default",
    /// After Hello; omit when null.
    session_token: ?[]const u8 = null,
};

/// Owned list of stream message payloads from a server-streaming RPC.
pub const StreamMessages = struct {
    allocator: std.mem.Allocator,
    /// Each element is one gRPC data-frame payload (one protobuf stream item).
    messages: [][]u8,

    pub fn deinit(self: *StreamMessages) void {
        for (self.messages) |m| self.allocator.free(m);
        self.allocator.free(self.messages);
        self.* = undefined;
    }
};

/// Join HTTPS origin with `/wal_log.ReplicationLog/{method}`.
pub fn rpcUrl(allocator: std.mem.Allocator, base: []const u8, method: []const u8) err.Error![]u8 {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    return std.fmt.allocPrint(allocator, "{s}/wal_log.ReplicationLog/{s}", .{ trimmed, method }) catch return error.OutOfMemory;
}

/// Map open/sync URL to HTTP(S) base; reject empty authority / query.
pub fn httpBase(allocator: std.mem.Allocator, url: []const u8) err.Error![]u8 {
    return path_util.toHttpBase(allocator, url) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => return error.InvalidPath,
    };
}

fn mapGrpcStatus(status_message: []const u8) err.Error {
    if (grpc_web.messageIsNeedSnapshot(status_message)) return error.NeedSnapshot;
    if (grpc_web.messageIsNoHello(status_message)) return error.Sql;
    if (grpc_web.messageIsNamespaceMissing(status_message)) return error.Sql;
    return error.Sql;
}

const PostBody = struct {
    body: []u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *PostBody) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

/// Shared HTTPS POST of a framed protobuf request; returns the raw response body.
fn postRaw(
    io: Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: RequestHeaders,
    protobuf_request: []const u8,
) err.Error!PostBody {
    if (!std.mem.startsWith(u8, url, "https://")) {
        // Token is always required for replica RPCs; plaintext is fail-closed.
        return error.InvalidPath;
    }
    if (headers.auth_token.len == 0) return error.InvalidPath;

    const framed = grpc_web.encodeRequest(allocator, protobuf_request) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Overflow => return error.Sql,
        else => return error.Sql,
    };
    defer allocator.free(framed);

    var ns_b64_buf: [256]u8 = undefined;
    const ns_b64 = blk: {
        const enc = std.base64.standard.Encoder;
        const need = enc.calcSize(headers.namespace.len);
        if (need > ns_b64_buf.len) return error.Sql;
        break :blk enc.encode(ns_b64_buf[0..need], headers.namespace);
    };

    var auth_buf: [512]u8 = undefined;
    if (headers.auth_token.len + "Bearer ".len >= auth_buf.len) return error.Sql;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{headers.auth_token}) catch return error.Sql;

    var headers_buf: [6]std.http.Header = undefined;
    var n: usize = 0;
    headers_buf[n] = .{ .name = "content-type", .value = "application/grpc-web+proto" };
    n += 1;
    headers_buf[n] = .{ .name = "accept", .value = "application/grpc-web+proto" };
    n += 1;
    headers_buf[n] = .{ .name = "x-authorization", .value = auth };
    n += 1;
    headers_buf[n] = .{ .name = "x-namespace-bin", .value = ns_b64 };
    n += 1;
    headers_buf[n] = .{ .name = "x-libsql-client-version", .value = client_version };
    n += 1;
    if (headers.session_token) |st| {
        headers_buf[n] = .{ .name = "x-session-token", .value = st };
        n += 1;
    }

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const resp_buf = allocator.alloc(u8, max_response_bytes) catch return error.OutOfMemory;
    defer allocator.free(resp_buf);
    var resp_writer: std.Io.Writer = .fixed(resp_buf);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = framed,
        .extra_headers = headers_buf[0..n],
        .response_writer = &resp_writer,
        .redirect_behavior = .not_allowed,
    }) catch return error.Sql;

    const status: u16 = @intFromEnum(result.status);
    if (status < 200 or status >= 300) return error.Sql;

    const body = allocator.dupe(u8, resp_writer.buffered()) catch return error.OutOfMemory;
    return .{ .body = body, .allocator = allocator };
}

/// POST a framed protobuf request; return decoded unary gRPC-Web message (owned).
///
/// On non-zero `grpc-status`, maps `NEED_SNAPSHOT` → `error.NeedSnapshot` and
/// otherwise returns `error.Sql`. Does not log tokens or payloads.
pub fn postUnary(
    io: Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: RequestHeaders,
    protobuf_request: []const u8,
) err.Error![]u8 {
    var raw = try postRaw(io, allocator, url, headers, protobuf_request);
    defer raw.deinit();

    var dec = grpc_web.decodeResponseAllowStatus(allocator, raw.body) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Sql,
    };
    defer dec.deinit(allocator);

    if (dec.status != 0) return mapGrpcStatus(dec.status_message);

    return allocator.dupe(u8, dec.message) catch return error.OutOfMemory;
}

/// POST a framed protobuf request; return server-stream messages (one per data frame).
///
/// Same auth/TLS policy as `postUnary`. Body size capped at 64 MiB (see module doc).
pub fn postStream(
    io: Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: RequestHeaders,
    protobuf_request: []const u8,
) err.Error!StreamMessages {
    var raw = try postRaw(io, allocator, url, headers, protobuf_request);
    defer raw.deinit();

    var dec = grpc_web.decodeStreamResponseAllowStatus(allocator, raw.body) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Sql,
    };
    // On error paths below, free all stream buffers. On success we steal
    // `messages` and free only the trailer, so disarm before returning OK.
    errdefer dec.deinit(allocator);

    if (dec.status != 0) {
        return mapGrpcStatus(dec.status_message);
    }

    // Steal messages; free trailer ourselves. Clear fields so a later
    // accidental deinit would not double-free (errdefer is not run on success).
    const messages = dec.messages;
    const trailer = dec.trailer;
    dec.messages = &.{};
    dec.trailer = "";
    allocator.free(trailer);

    return .{
        .allocator = allocator,
        .messages = messages,
    };
}

test "rpc url join" {
    const gpa = std.testing.allocator;
    const u = try rpcUrl(gpa, "https://example.turso.io/", "Hello");
    defer gpa.free(u);
    try std.testing.expectEqualStrings("https://example.turso.io/wal_log.ReplicationLog/Hello", u);
}

test "http base from libsql" {
    const gpa = std.testing.allocator;
    const u = try httpBase(gpa, "libsql://db.turso.io/");
    defer gpa.free(u);
    try std.testing.expectEqualStrings("https://db.turso.io", u);
}
