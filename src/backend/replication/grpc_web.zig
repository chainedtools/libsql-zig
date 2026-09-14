//! Binary gRPC-Web framing for classic replica RPCs (not Hrana).
//!
//! Wire format (application/grpc-web+proto):
//!   request:  single data frame  [flags:u8][len:u32 BE][protobuf]
//!   unary response: zero+ data frames **concatenated** into one protobuf + trailer
//!   stream response: each data frame is **one** stream message + trailer (flags bit 0x80)
//!   trailer:  HTTP-style `key: value\r\n` pairs; require grpc-status: 0
//!
//! Never log auth tokens, session tokens, or full message payloads.

const std = @import("std");

pub const data_flag: u8 = 0x00;
pub const trailer_flag: u8 = 0x80;
pub const header_size: usize = 5;

pub const FrameError = error{
    Truncated,
    Overflow,
    MissingTrailer,
    /// Trailer frame present but carried no `grpc-status` line.
    MissingStatus,
    GrpcStatus,
    OutOfMemory,
};

/// Encode a single unary request message as one gRPC-Web data frame.
pub fn encodeRequest(allocator: std.mem.Allocator, message: []const u8) FrameError![]u8 {
    if (message.len > std.math.maxInt(u32)) return error.Overflow;
    const total = header_size + message.len;
    var out = try allocator.alloc(u8, total);
    out[0] = data_flag;
    std.mem.writeInt(u32, out[1..5], @intCast(message.len), .big);
    @memcpy(out[header_size..], message);
    return out;
}

pub const DecodedResponse = struct {
    /// Concatenated data-frame payloads (owned).
    message: []u8,
    /// Raw trailer body (owned), for optional grpc-message inspection.
    trailer: []u8,
    /// Parsed grpc-status (0 = OK).
    status: u32,
    /// grpc-message value if present (view into trailer storage after parse — not owned separately).
    status_message: []const u8,

    pub fn deinit(self: *DecodedResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.trailer);
        self.* = undefined;
    }
};

/// Decode a gRPC-Web response body into message + trailer status.
pub fn decodeResponse(allocator: std.mem.Allocator, body: []const u8) FrameError!DecodedResponse {
    var msg_buf: std.ArrayList(u8) = .empty;
    errdefer msg_buf.deinit(allocator);

    var trailer_owned: ?[]u8 = null;
    errdefer if (trailer_owned) |t| allocator.free(t);

    var i: usize = 0;
    var saw_trailer = false;
    while (i < body.len) {
        if (body.len - i < header_size) return error.Truncated;
        const flags = body[i];
        const len = std.mem.readInt(u32, body[i + 1 ..][0..4], .big);
        i += header_size;
        if (len > body.len - i) return error.Truncated;
        const payload = body[i .. i + len];
        i += len;

        if ((flags & trailer_flag) != 0) {
            trailer_owned = try allocator.dupe(u8, payload);
            saw_trailer = true;
            // Official clients treat the first trailer as terminal; ignore trailing junk.
            break;
        }
        try msg_buf.appendSlice(allocator, payload);
    }

    if (!saw_trailer) return error.MissingTrailer;
    const trailer = trailer_owned.?;
    trailer_owned = null;
    // Ownership transferred out of `trailer_owned`; keep an errdefer so any later
    // failure (unwrap, toOwnedSlice) frees it instead of leaking. `msg_buf` is
    // covered by its own errdefer above, so no explicit frees here would ever
    // double-free.
    errdefer allocator.free(trailer);

    const parsed = parseTrailer(trailer);
    // Fail closed on a trailer that omits grpc-status rather than treating it as OK.
    const status = parsed.status orelse return error.MissingStatus;
    if (status != 0) return error.GrpcStatus;

    return .{
        .message = try msg_buf.toOwnedSlice(allocator),
        .trailer = trailer,
        .status = status,
        .status_message = parsed.message,
    };
}

/// Like `decodeResponse`, but on non-zero grpc-status still returns the decoded
/// trailer fields so callers can map `NO_HELLO` / `NEED_SNAPSHOT` / etc.
pub fn decodeResponseAllowStatus(allocator: std.mem.Allocator, body: []const u8) FrameError!DecodedResponse {
    var msg_buf: std.ArrayList(u8) = .empty;
    errdefer msg_buf.deinit(allocator);

    var trailer_owned: ?[]u8 = null;
    errdefer if (trailer_owned) |t| allocator.free(t);

    var i: usize = 0;
    var saw_trailer = false;
    while (i < body.len) {
        if (body.len - i < header_size) return error.Truncated;
        const flags = body[i];
        const len = std.mem.readInt(u32, body[i + 1 ..][0..4], .big);
        i += header_size;
        if (len > body.len - i) return error.Truncated;
        const payload = body[i .. i + len];
        i += len;

        if ((flags & trailer_flag) != 0) {
            trailer_owned = try allocator.dupe(u8, payload);
            saw_trailer = true;
            break;
        }
        try msg_buf.appendSlice(allocator, payload);
    }

    if (!saw_trailer) return error.MissingTrailer;
    const trailer = trailer_owned.?;
    trailer_owned = null;
    // See `decodeResponse`: keep an errdefer for the now-owned trailer so a
    // failure below frees it instead of leaking.
    errdefer allocator.free(trailer);

    const parsed = parseTrailer(trailer);
    // Even in the allow-status path, a trailer with no grpc-status is malformed.
    const status = parsed.status orelse return error.MissingStatus;

    return .{
        .message = try msg_buf.toOwnedSlice(allocator),
        .trailer = trailer,
        .status = status,
        .status_message = parsed.message,
    };
}

const TrailerFields = struct {
    /// `null` when the trailer carried no `grpc-status` line at all.
    status: ?u32,
    message: []const u8,
};

fn parseTrailer(trailer: []const u8) TrailerFields {
    var status: ?u32 = null;
    var message: []const u8 = "";
    var rest = trailer;
    while (rest.len > 0) {
        // Split on \r\n or \n
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        var line = rest[0..line_end];
        if (line_end < rest.len) {
            rest = rest[line_end + 1 ..];
        } else {
            rest = rest[line_end..];
        }
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "grpc-status")) {
            status = std.fmt.parseInt(u32, value, 10) catch 2; // UNKNOWN
        } else if (std.ascii.eqlIgnoreCase(key, "grpc-message")) {
            message = value;
        }
    }
    return .{ .status = status, .message = message };
}

/// Server-streaming gRPC-Web response: one protobuf message per data frame.
pub const DecodedStream = struct {
    /// Owned copies of each data-frame payload (one stream message each).
    messages: [][]u8,
    /// Raw trailer body (owned).
    trailer: []u8,
    /// Parsed grpc-status (0 = OK).
    status: u32,
    /// grpc-message value if present (view into trailer storage).
    status_message: []const u8,

    pub fn deinit(self: *DecodedStream, allocator: std.mem.Allocator) void {
        for (self.messages) |m| allocator.free(m);
        allocator.free(self.messages);
        allocator.free(self.trailer);
        self.* = undefined;
    }
};

/// Decode a server-streaming gRPC-Web body (each data frame = one message).
pub fn decodeStreamResponse(allocator: std.mem.Allocator, body: []const u8) FrameError!DecodedStream {
    var dec = try decodeStreamResponseAllowStatus(allocator, body);
    errdefer dec.deinit(allocator);
    if (dec.status != 0) return error.GrpcStatus;
    return dec;
}

/// Like `decodeStreamResponse`, but keeps non-zero grpc-status for callers.
pub fn decodeStreamResponseAllowStatus(allocator: std.mem.Allocator, body: []const u8) FrameError!DecodedStream {
    var msgs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (msgs.items) |m| allocator.free(m);
        msgs.deinit(allocator);
    }

    var trailer_owned: ?[]u8 = null;
    errdefer if (trailer_owned) |t| allocator.free(t);

    var i: usize = 0;
    var saw_trailer = false;
    while (i < body.len) {
        if (body.len - i < header_size) return error.Truncated;
        const flags = body[i];
        const len = std.mem.readInt(u32, body[i + 1 ..][0..4], .big);
        i += header_size;
        if (len > body.len - i) return error.Truncated;
        const payload = body[i .. i + len];
        i += len;

        if ((flags & trailer_flag) != 0) {
            trailer_owned = try allocator.dupe(u8, payload);
            saw_trailer = true;
            break;
        }
        const owned = try allocator.dupe(u8, payload);
        errdefer allocator.free(owned);
        try msgs.append(allocator, owned);
    }

    if (!saw_trailer) return error.MissingTrailer;
    const trailer = trailer_owned.?;
    trailer_owned = null;
    errdefer allocator.free(trailer);

    const parsed = parseTrailer(trailer);
    const status = parsed.status orelse return error.MissingStatus;

    return .{
        .messages = try msgs.toOwnedSlice(allocator),
        .trailer = trailer,
        .status = status,
        .status_message = parsed.message,
    };
}

/// True when a grpc-message (or status detail) indicates NEED_SNAPSHOT.
pub fn messageIsNeedSnapshot(msg: []const u8) bool {
    return std.mem.indexOf(u8, msg, "NEED_SNAPSHOT") != null;
}

pub fn messageIsNoHello(msg: []const u8) bool {
    return std.mem.indexOf(u8, msg, "NO_HELLO") != null;
}

pub fn messageIsNamespaceMissing(msg: []const u8) bool {
    return std.mem.indexOf(u8, msg, "NAMESPACE_DOESNT_EXIST") != null;
}

test "encode request frame" {
    const gpa = std.testing.allocator;
    const msg = "hello";
    const framed = try encodeRequest(gpa, msg);
    defer gpa.free(framed);
    try std.testing.expectEqual(@as(usize, header_size + msg.len), framed.len);
    try std.testing.expectEqual(data_flag, framed[0]);
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, framed[1..5], .big));
    try std.testing.expectEqualStrings(msg, framed[header_size..]);
}

test "decode response with data and trailer ok" {
    const gpa = std.testing.allocator;
    const payload = "proto-bytes";
    const trailer_body = "grpc-status: 0\r\ngrpc-message: \r\n";

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, data_flag);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(payload.len), .big);
    try body.appendSlice(gpa, &len_buf);
    try body.appendSlice(gpa, payload);
    try body.append(gpa, trailer_flag);
    std.mem.writeInt(u32, &len_buf, @intCast(trailer_body.len), .big);
    try body.appendSlice(gpa, &len_buf);
    try body.appendSlice(gpa, trailer_body);

    var dec = try decodeResponse(gpa, body.items);
    defer dec.deinit(gpa);
    try std.testing.expectEqualStrings(payload, dec.message);
    try std.testing.expectEqual(@as(u32, 0), dec.status);
}

test "decode response status failure" {
    const gpa = std.testing.allocator;
    const trailer_body = "grpc-status: 13\r\ngrpc-message: NEED_SNAPSHOT\r\n";
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, trailer_flag);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(trailer_body.len), .big);
    try body.appendSlice(gpa, &len_buf);
    try body.appendSlice(gpa, trailer_body);

    try std.testing.expectError(error.GrpcStatus, decodeResponse(gpa, body.items));

    var dec = try decodeResponseAllowStatus(gpa, body.items);
    defer dec.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 13), dec.status);
    try std.testing.expect(messageIsNeedSnapshot(dec.status_message));
}

test "missing trailer" {
    const gpa = std.testing.allocator;
    const payload = "x";
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, data_flag);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, 1, .big);
    try body.appendSlice(gpa, &len_buf);
    try body.appendSlice(gpa, payload);
    try std.testing.expectError(error.MissingTrailer, decodeResponse(gpa, body.items));
}

test "trailer without grpc-status is rejected" {
    const gpa = std.testing.allocator;
    // Trailer frame present but carrying only grpc-message: must not be treated
    // as a successful (status 0) response by either decoder.
    const trailer_body = "grpc-message: something\r\n";
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, trailer_flag);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(trailer_body.len), .big);
    try body.appendSlice(gpa, &len_buf);
    try body.appendSlice(gpa, trailer_body);

    try std.testing.expectError(error.MissingStatus, decodeResponse(gpa, body.items));
    try std.testing.expectError(error.MissingStatus, decodeResponseAllowStatus(gpa, body.items));
    try std.testing.expectError(error.MissingStatus, decodeStreamResponseAllowStatus(gpa, body.items));
}

fn appendDataFrame(body: *std.ArrayList(u8), gpa: std.mem.Allocator, payload: []const u8) !void {
    try body.append(gpa, data_flag);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(payload.len), .big);
    try body.appendSlice(gpa, &len_buf);
    try body.appendSlice(gpa, payload);
}

fn appendTrailer(body: *std.ArrayList(u8), gpa: std.mem.Allocator, trailer_body: []const u8) !void {
    try body.append(gpa, trailer_flag);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(trailer_body.len), .big);
    try body.appendSlice(gpa, &len_buf);
    try body.appendSlice(gpa, trailer_body);
}

test "decode stream multi-message ok" {
    const gpa = std.testing.allocator;
    const trailer_body = "grpc-status: 0\r\ngrpc-message: \r\n";

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try appendDataFrame(&body, gpa, "msg-a");
    try appendDataFrame(&body, gpa, "msg-b");
    try appendTrailer(&body, gpa, trailer_body);

    var dec = try decodeStreamResponse(gpa, body.items);
    defer dec.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), dec.messages.len);
    try std.testing.expectEqualStrings("msg-a", dec.messages[0]);
    try std.testing.expectEqualStrings("msg-b", dec.messages[1]);
    try std.testing.expectEqual(@as(u32, 0), dec.status);

    // Unary decoder concatenates — stream path must keep messages separate.
    var unary = try decodeResponse(gpa, body.items);
    defer unary.deinit(gpa);
    try std.testing.expectEqualStrings("msg-amsg-b", unary.message);
}

test "decode stream empty with ok trailer" {
    const gpa = std.testing.allocator;
    const trailer_body = "grpc-status: 0\r\n";
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try appendTrailer(&body, gpa, trailer_body);

    var dec = try decodeStreamResponse(gpa, body.items);
    defer dec.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), dec.messages.len);
    try std.testing.expectEqual(@as(u32, 0), dec.status);
}

test "decode stream status failure" {
    const gpa = std.testing.allocator;
    const trailer_body = "grpc-status: 13\r\ngrpc-message: NEED_SNAPSHOT\r\n";
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try appendDataFrame(&body, gpa, "partial");
    try appendTrailer(&body, gpa, trailer_body);

    try std.testing.expectError(error.GrpcStatus, decodeStreamResponse(gpa, body.items));

    var dec = try decodeStreamResponseAllowStatus(gpa, body.items);
    defer dec.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), dec.messages.len);
    try std.testing.expectEqual(@as(u32, 13), dec.status);
    try std.testing.expect(messageIsNeedSnapshot(dec.status_message));
}

test "decode stream truncated" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, data_flag);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, 10, .big);
    try body.appendSlice(gpa, &len_buf);
    try body.appendSlice(gpa, "short"); // fewer than 10 bytes
    try std.testing.expectError(error.Truncated, decodeStreamResponseAllowStatus(gpa, body.items));
}
