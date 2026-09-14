//! Hrana JSON Value encode/decode (Hrana 3 shared structures).

const std = @import("std");
const value = @import("../../value.zig");

/// Encode a bind Value as a Hrana JSON object into `w`.
pub fn writeValue(w: *std.Io.Writer, v: value.Value) std.Io.Writer.Error!void {
    switch (v) {
        .null => try w.writeAll("{\"type\":\"null\"}"),
        .integer => |i| try w.print("{{\"type\":\"integer\",\"value\":\"{d}\"}}", .{i}),
        .float => |f| {
            if (std.math.isNan(f) or std.math.isInf(f)) return error.WriteFailed;
            try w.print("{{\"type\":\"float\",\"value\":{d}}}", .{f});
        },
        .text => |t| {
            try w.writeAll("{\"type\":\"text\",\"value\":");
            try writeJsonString(w, t);
            try w.writeAll("}");
        },
        .blob => |b| {
            try w.writeAll("{\"type\":\"blob\",\"base64\":\"");
            try writeBase64(w, b);
            try w.writeAll("\"}");
        },
    }
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
    try w.writeByte('"');
}

fn writeBase64(w: *std.Io.Writer, data: []const u8) std.Io.Writer.Error!void {
    const Encoder = std.base64.standard.Encoder;
    var i: usize = 0;
    var buf: [1024]u8 = undefined;
    const chunk = 768; // 768 in → 1024 out
    while (i < data.len) {
        const end = @min(i + chunk, data.len);
        const slice = data[i..end];
        const out_len = Encoder.calcSize(slice.len);
        if (out_len > buf.len) return error.WriteFailed;
        const encoded = Encoder.encode(buf[0..out_len], slice);
        try w.writeAll(encoded);
        i = end;
    }
}

/// Owned value decoded from a Hrana JSON result cell.
pub const Owned = union(enum) {
    null: void,
    integer: i64,
    float: f64,
    text: []u8,
    blob: []u8,

    pub fn deinit(self: *Owned, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |t| allocator.free(t),
            .blob => |b| allocator.free(b),
            else => {},
        }
        self.* = .{ .null = {} };
    }

    pub fn fromJson(allocator: std.mem.Allocator, v: std.json.Value) !Owned {
        const obj = switch (v) {
            .object => |o| o,
            else => return error.Sql,
        };
        const type_val = obj.get("type") orelse return error.Sql;
        const type_str = switch (type_val) {
            .string => |s| s,
            else => return error.Sql,
        };

        if (std.mem.eql(u8, type_str, "null")) return .{ .null = {} };
        if (std.mem.eql(u8, type_str, "integer")) {
            const raw = obj.get("value") orelse return error.Sql;
            switch (raw) {
                .string => |s| {
                    const n = std.fmt.parseInt(i64, s, 10) catch return error.Sql;
                    return .{ .integer = n };
                },
                .integer => |i| return .{ .integer = i },
                else => return error.Sql,
            }
        }
        if (std.mem.eql(u8, type_str, "float")) {
            const raw = obj.get("value") orelse return error.Sql;
            const f: f64 = switch (raw) {
                .float => |x| x,
                .integer => |i| @floatFromInt(i),
                .string => |s| std.fmt.parseFloat(f64, s) catch return error.Sql,
                else => return error.Sql,
            };
            return .{ .float = f };
        }
        if (std.mem.eql(u8, type_str, "text")) {
            const raw = obj.get("value") orelse return error.Sql;
            const s = switch (raw) {
                .string => |str| str,
                else => return error.Sql,
            };
            return .{ .text = try allocator.dupe(u8, s) };
        }
        if (std.mem.eql(u8, type_str, "blob")) {
            const raw = obj.get("base64") orelse return error.Sql;
            const s = switch (raw) {
                .string => |str| str,
                else => return error.Sql,
            };
            const Decoder = std.base64.standard.Decoder;
            const out_len = Decoder.calcSizeForSlice(s) catch return error.Sql;
            const out = try allocator.alloc(u8, out_len);
            errdefer allocator.free(out);
            Decoder.decode(out, s) catch return error.Sql;
            return .{ .blob = out };
        }
        return error.Sql;
    }
};

test "write integer value json" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeValue(&aw.writer, .{ .integer = 42 });
    try std.testing.expectEqualStrings("{\"type\":\"integer\",\"value\":\"42\"}", aw.written());
}

test "write text escapes" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeValue(&aw.writer, .{ .text = "a\"b" });
    try std.testing.expectEqualStrings("{\"type\":\"text\",\"value\":\"a\\\"b\"}", aw.written());
}

test "decode integer string" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"type":"integer","value":"99"}
    , .{});
    defer parsed.deinit();
    var o = try Owned.fromJson(gpa, parsed.value);
    defer o.deinit(gpa);
    try std.testing.expect(o == .integer);
    try std.testing.expectEqual(@as(i64, 99), o.integer);
}
