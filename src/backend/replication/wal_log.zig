//! Protobuf codecs for classic `wal_log` ReplicationLog messages.
//!
//! Source of truth: libsql-replication `replication_log.proto` (see
//! `docs/replica-protocol-spike.md`). R2 implements encode/decode only —
//! no gRPC-Web transport and no public `Database.sync` pure path yet.

const std = @import("std");
const pb = @import("pb.zig");
const frame_mod = @import("frame.zig");

pub const DecodeError = pb.DecodeError || error{ OutOfMemory, InvalidWalFlavor };

pub const WalFlavor = enum(u32) {
    sqlite = 0,
    libsql = 1,
};

pub const HelloRequest = struct {
    handshake_version: ?u64 = null,

    pub fn encode(self: HelloRequest, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        if (self.handshake_version) |v| {
            try pb.writeUint64Field(&buf, allocator, 1, v);
        }
        return try buf.toOwnedSlice(allocator);
    }

    pub fn decode(data: []const u8) DecodeError!HelloRequest {
        var r = pb.Reader{ .data = data };
        var out: HelloRequest = .{};
        while (!r.done()) {
            const t = try r.readTag();
            switch (t.field) {
                1 => {
                    if (t.wt != .varint) return error.InvalidWireType;
                    out.handshake_version = try r.readVarint();
                },
                else => try r.skip(t.wt),
            }
        }
        return out;
    }

    /// Official clients send `handshake_version = 1`.
    pub fn default() HelloRequest {
        return .{ .handshake_version = 1 };
    }
};

pub const HelloResponse = struct {
    generation_id: []const u8 = "",
    generation_start_index: u64 = 0,
    log_id: []const u8 = "",
    session_token: []const u8 = "",
    current_replication_index: ?u64 = null,
    /// Raw embedded `DatabaseConfig` message bytes (field 6), if present.
    config_raw: []const u8 = "",

    pub fn encode(self: HelloResponse, allocator: std.mem.Allocator) error{ OutOfMemory, InvalidUtf8 }![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        if (self.generation_id.len != 0) try pb.writeStringField(&buf, allocator, 1, self.generation_id);
        if (self.generation_start_index != 0) try pb.writeUint64Field(&buf, allocator, 2, self.generation_start_index);
        if (self.log_id.len != 0) try pb.writeStringField(&buf, allocator, 3, self.log_id);
        if (self.session_token.len != 0) try pb.writeBytesField(&buf, allocator, 4, self.session_token);
        if (self.current_replication_index) |idx| try pb.writeUint64Field(&buf, allocator, 5, idx);
        if (self.config_raw.len != 0) try pb.writeMessageField(&buf, allocator, 6, self.config_raw);
        return try buf.toOwnedSlice(allocator);
    }

    /// Decode into views of `data` (no allocations). Caller must keep `data` alive.
    pub fn decode(data: []const u8) DecodeError!HelloResponse {
        var r = pb.Reader{ .data = data };
        var out: HelloResponse = .{};
        while (!r.done()) {
            const t = try r.readTag();
            switch (t.field) {
                1 => {
                    if (t.wt != .len) return error.InvalidWireType;
                    out.generation_id = try r.readLen();
                    if (!std.unicode.utf8ValidateSlice(out.generation_id)) return error.InvalidUtf8;
                },
                2 => {
                    if (t.wt != .varint) return error.InvalidWireType;
                    out.generation_start_index = try r.readVarint();
                },
                3 => {
                    if (t.wt != .len) return error.InvalidWireType;
                    out.log_id = try r.readLen();
                    if (!std.unicode.utf8ValidateSlice(out.log_id)) return error.InvalidUtf8;
                },
                4 => {
                    if (t.wt != .len) return error.InvalidWireType;
                    out.session_token = try r.readLen();
                },
                5 => {
                    if (t.wt != .varint) return error.InvalidWireType;
                    out.current_replication_index = try r.readVarint();
                },
                6 => {
                    if (t.wt != .len) return error.InvalidWireType;
                    out.config_raw = try r.readLen();
                },
                else => try r.skip(t.wt),
            }
        }
        return out;
    }
};

pub const LogOffset = struct {
    next_offset: u64 = 0,
    wal_flavor: ?WalFlavor = null,

    pub fn encode(self: LogOffset, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        if (self.next_offset != 0) try pb.writeUint64Field(&buf, allocator, 1, self.next_offset);
        if (self.wal_flavor) |f| try pb.writeUint64Field(&buf, allocator, 2, @intFromEnum(f));
        return try buf.toOwnedSlice(allocator);
    }

    pub fn decode(data: []const u8) DecodeError!LogOffset {
        var r = pb.Reader{ .data = data };
        var out: LogOffset = .{};
        while (!r.done()) {
            const t = try r.readTag();
            switch (t.field) {
                1 => {
                    if (t.wt != .varint) return error.InvalidWireType;
                    out.next_offset = try r.readVarint();
                },
                2 => {
                    if (t.wt != .varint) return error.InvalidWireType;
                    const v = try r.readVarint();
                    if (v > std.math.maxInt(u32)) return error.InvalidWireType;
                    out.wal_flavor = std.enums.fromInt(
                        WalFlavor,
                        @as(u32, @intCast(v)),
                    ) orelse return error.InvalidWalFlavor;
                },
                else => try r.skip(t.wt),
            }
        }
        return out;
    }
};

/// Single RPC `Frame` message (`bytes data` = full FrameBorrowed).
pub const RpcFrame = struct {
    /// Length-delimited payload; typically `frame_size` bytes.
    data: []const u8 = "",
    timestamp: ?i64 = null,
    durable_frame_no: ?u64 = null,

    pub fn encode(self: RpcFrame, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        if (self.data.len != 0) try pb.writeBytesField(&buf, allocator, 1, self.data);
        if (self.timestamp) |ts| try pb.writeInt64Field(&buf, allocator, 2, ts);
        if (self.durable_frame_no) |n| try pb.writeUint64Field(&buf, allocator, 3, n);
        return try buf.toOwnedSlice(allocator);
    }

    pub fn decode(data: []const u8) DecodeError!RpcFrame {
        var r = pb.Reader{ .data = data };
        var out: RpcFrame = .{};
        while (!r.done()) {
            const t = try r.readTag();
            switch (t.field) {
                1 => {
                    if (t.wt != .len) return error.InvalidWireType;
                    out.data = try r.readLen();
                },
                2 => {
                    if (t.wt != .varint) return error.InvalidWireType;
                    out.timestamp = @bitCast(try r.readVarint());
                },
                3 => {
                    if (t.wt != .varint) return error.InvalidWireType;
                    out.durable_frame_no = try r.readVarint();
                },
                else => try r.skip(t.wt),
            }
        }
        return out;
    }

    pub fn parsePageFrame(self: RpcFrame) error{InvalidFrameLen}!frame_mod.Frame {
        return frame_mod.Frame.tryDecode(self.data);
    }
};

pub const Frames = struct {
    /// Decoded RpcFrame views into the original buffer (no owned copies).
    frames: []const RpcFrame = &.{},

    pub fn encode(frames: []const RpcFrame, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        for (frames) |f| {
            const msg = try f.encode(allocator);
            defer allocator.free(msg);
            try pb.writeMessageField(&buf, allocator, 1, msg);
        }
        return try buf.toOwnedSlice(allocator);
    }

    /// Decode all frames into an owned slice of views into `data`.
    pub fn decodeOwned(allocator: std.mem.Allocator, data: []const u8) DecodeError![]RpcFrame {
        var list: std.ArrayList(RpcFrame) = .empty;
        errdefer list.deinit(allocator);
        var r = pb.Reader{ .data = data };
        while (!r.done()) {
            const t = try r.readTag();
            switch (t.field) {
                1 => {
                    if (t.wt != .len) return error.InvalidWireType;
                    const msg = try r.readLen();
                    try list.append(allocator, try RpcFrame.decode(msg));
                },
                else => try r.skip(t.wt),
            }
        }
        return try list.toOwnedSlice(allocator);
    }
};

/// Session token is a UUID string in UTF-8 (official client verifies via Uuid parse).
pub fn sessionTokenLooksValid(token: []const u8) bool {
    // 8-4-4-4-12 hex with hyphens = 36 chars
    if (token.len != 36) return false;
    const hyphens = [_]usize{ 8, 13, 18, 23 };
    for (hyphens) |i| {
        if (token[i] != '-') return false;
    }
    for (token, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

test "hello request default round-trip" {
    const gpa = std.testing.allocator;
    const enc = try HelloRequest.default().encode(gpa);
    defer gpa.free(enc);
    const d = try HelloRequest.decode(enc);
    try std.testing.expectEqual(@as(?u64, 1), d.handshake_version);
}

test "hello response round-trip" {
    const gpa = std.testing.allocator;
    const src = HelloResponse{
        .generation_id = "gen-1",
        .generation_start_index = 10,
        .log_id = "550e8400-e29b-41d4-a716-446655440000",
        .session_token = "550e8400-e29b-41d4-a716-446655440001",
        .current_replication_index = 99,
    };
    const enc = try src.encode(gpa);
    defer gpa.free(enc);
    const d = try HelloResponse.decode(enc);
    try std.testing.expectEqualStrings(src.generation_id, d.generation_id);
    try std.testing.expectEqual(src.generation_start_index, d.generation_start_index);
    try std.testing.expectEqualStrings(src.log_id, d.log_id);
    try std.testing.expectEqualStrings(src.session_token, d.session_token);
    try std.testing.expectEqual(src.current_replication_index, d.current_replication_index);
    try std.testing.expect(sessionTokenLooksValid(d.session_token));
}

test "log offset and frames with page frame" {
    const gpa = std.testing.allocator;

    const off = LogOffset{ .next_offset = 5, .wal_flavor = .sqlite };
    const off_enc = try off.encode(gpa);
    defer gpa.free(off_enc);
    const off_d = try LogOffset.decode(off_enc);
    try std.testing.expectEqual(@as(u64, 5), off_d.next_offset);
    try std.testing.expectEqual(WalFlavor.sqlite, off_d.wal_flavor.?);

    var page: [frame_mod.page_size]u8 = undefined;
    @memset(&page, 0);
    page[0] = 0x42;
    const pf = frame_mod.Frame.fromParts(.{
        .frame_no = 5,
        .checksum = 1,
        .page_no = 2,
        .size_after = 3,
    }, &page);
    var raw: [frame_mod.frame_size]u8 = undefined;
    pf.encode(&raw);

    const rpc = RpcFrame{ .data = &raw, .timestamp = 123 };
    const frames_enc = try Frames.encode(&.{rpc}, gpa);
    defer gpa.free(frames_enc);
    const frames = try Frames.decodeOwned(gpa, frames_enc);
    defer gpa.free(frames);
    try std.testing.expectEqual(@as(usize, 1), frames.len);
    const parsed = try frames[0].parsePageFrame();
    try std.testing.expectEqual(@as(u64, 5), parsed.header.frame_no);
    try std.testing.expectEqual(@as(u32, 2), parsed.header.page_no);
    try std.testing.expectEqual(@as(u8, 0x42), parsed.page[0]);
    try std.testing.expectEqual(@as(?i64, 123), frames[0].timestamp);
}
