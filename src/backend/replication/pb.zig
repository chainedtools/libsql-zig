//! Minimal protobuf wire helpers for replica RPC messages.
//! Only the field types used by `replication_log.proto` are implemented.

const std = @import("std");

pub const WireType = enum(u3) {
    varint = 0,
    fixed64 = 1,
    len = 2,
    fixed32 = 5,
};

pub const DecodeError = error{
    Truncated,
    Overflow,
    InvalidWireType,
    InvalidFieldNumber,
    InvalidUtf8,
};

pub fn tag(field: u32, wt: WireType) u32 {
    return (field << 3) | @intFromEnum(wt);
}

pub fn writeVarint(w: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var v = value;
    while (v >= 0x80) {
        try w.append(allocator, @as(u8, @truncate(v)) | 0x80);
        v >>= 7;
    }
    try w.append(allocator, @truncate(v));
}

pub fn writeTag(w: *std.ArrayList(u8), allocator: std.mem.Allocator, field: u32, wt: WireType) !void {
    try writeVarint(w, allocator, tag(field, wt));
}

pub fn writeUint64Field(w: *std.ArrayList(u8), allocator: std.mem.Allocator, field: u32, value: u64) !void {
    try writeTag(w, allocator, field, .varint);
    try writeVarint(w, allocator, value);
}

pub fn writeInt64Field(w: *std.ArrayList(u8), allocator: std.mem.Allocator, field: u32, value: i64) !void {
    try writeUint64Field(w, allocator, field, @bitCast(value));
}

pub fn writeBytesField(w: *std.ArrayList(u8), allocator: std.mem.Allocator, field: u32, bytes: []const u8) !void {
    try writeTag(w, allocator, field, .len);
    try writeVarint(w, allocator, bytes.len);
    try w.appendSlice(allocator, bytes);
}

pub fn writeStringField(w: *std.ArrayList(u8), allocator: std.mem.Allocator, field: u32, s: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    try writeBytesField(w, allocator, field, s);
}

pub fn writeMessageField(w: *std.ArrayList(u8), allocator: std.mem.Allocator, field: u32, msg: []const u8) !void {
    try writeBytesField(w, allocator, field, msg);
}

pub const Reader = struct {
    data: []const u8,
    i: usize = 0,

    pub fn remaining(self: *const Reader) []const u8 {
        return self.data[self.i..];
    }

    pub fn done(self: *const Reader) bool {
        return self.i >= self.data.len;
    }

    pub fn readVarint(self: *Reader) DecodeError!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        var n: usize = 0;
        while (n < 10) : (n += 1) {
            if (self.i >= self.data.len) return error.Truncated;
            const b = self.data[self.i];
            self.i += 1;
            if (n == 9 and b > 1) return error.Overflow;
            result |= @as(u64, b & 0x7f) << shift;
            if ((b & 0x80) == 0) return result;
            const next: u16 = @as(u16, shift) + 7;
            if (next >= 64) return error.Overflow;
            shift = @intCast(next);
        }
        return error.Overflow;
    }

    pub fn readTag(self: *Reader) DecodeError!struct { field: u32, wt: WireType } {
        const t = try self.readVarint();
        const wt_n: u3 = @truncate(t & 0x7);
        const wt = std.enums.fromInt(WireType, wt_n) orelse return error.InvalidWireType;
        const field_value = t >> 3;
        if (field_value == 0 or field_value > 0x1fffffff)
            return error.InvalidFieldNumber;
        const field: u32 = @intCast(field_value);
        return .{ .field = field, .wt = wt };
    }

    pub fn readLen(self: *Reader) DecodeError![]const u8 {
        const n = try self.readVarint();
        if (n > self.data.len - self.i) return error.Truncated;
        const start = self.i;
        self.i += @intCast(n);
        return self.data[start..self.i];
    }

    pub fn skip(self: *Reader, wt: WireType) DecodeError!void {
        switch (wt) {
            .varint => _ = try self.readVarint(),
            .fixed64 => {
                if (self.i + 8 > self.data.len) return error.Truncated;
                self.i += 8;
            },
            .fixed32 => {
                if (self.i + 4 > self.data.len) return error.Truncated;
                self.i += 4;
            },
            .len => _ = try self.readLen(),
        }
    }
};

test "varint round-trip" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try writeVarint(&buf, gpa, 0);
    try writeVarint(&buf, gpa, 127);
    try writeVarint(&buf, gpa, 128);
    try writeVarint(&buf, gpa, 300);
    var r = Reader{ .data = buf.items };
    try std.testing.expectEqual(@as(u64, 0), try r.readVarint());
    try std.testing.expectEqual(@as(u64, 127), try r.readVarint());
    try std.testing.expectEqual(@as(u64, 128), try r.readVarint());
    try std.testing.expectEqual(@as(u64, 300), try r.readVarint());
}
