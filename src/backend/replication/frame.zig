//! Classic libSQL replication page frame layout (not Hrana).
//!
//! Matches `libsql-replication` `FrameHeader` / `FrameBorrowed`:
//! little-endian header + 4096-byte page.

const std = @import("std");

pub const page_size: usize = 4096;
pub const header_size: usize = 24;
pub const frame_size: usize = header_size + page_size;

pub const FrameHeader = struct {
    frame_no: u64,
    checksum: u64,
    page_no: u32,
    /// DB size in pages after commit; 0 = not a commit boundary.
    size_after: u32,

    pub fn isCommit(self: FrameHeader) bool {
        return self.size_after != 0;
    }

    pub fn encode(self: FrameHeader, out: *[header_size]u8) void {
        std.mem.writeInt(u64, out[0..8], self.frame_no, .little);
        std.mem.writeInt(u64, out[8..16], self.checksum, .little);
        std.mem.writeInt(u32, out[16..20], self.page_no, .little);
        std.mem.writeInt(u32, out[20..24], self.size_after, .little);
    }

    pub fn decode(bytes: *const [header_size]u8) FrameHeader {
        return .{
            .frame_no = std.mem.readInt(u64, bytes[0..8], .little),
            .checksum = std.mem.readInt(u64, bytes[8..16], .little),
            .page_no = std.mem.readInt(u32, bytes[16..20], .little),
            .size_after = std.mem.readInt(u32, bytes[20..24], .little),
        };
    }
};

/// Owned fixed-size frame (header + page).
pub const Frame = struct {
    header: FrameHeader,
    page: [page_size]u8,

    pub fn fromParts(header: FrameHeader, page: *const [page_size]u8) Frame {
        var f: Frame = .{
            .header = header,
            .page = undefined,
        };
        f.page = page.*;
        return f;
    }

    pub fn encode(self: *const Frame, out: *[frame_size]u8) void {
        self.header.encode(out[0..header_size]);
        @memcpy(out[header_size..], &self.page);
    }

    pub fn decode(bytes: *const [frame_size]u8) Frame {
        return .{
            .header = FrameHeader.decode(bytes[0..header_size]),
            .page = bytes[header_size..].*,
        };
    }

    pub fn tryDecode(bytes: []const u8) error{InvalidFrameLen}!Frame {
        if (bytes.len != frame_size) return error.InvalidFrameLen;
        return decode(bytes[0..frame_size]);
    }
};

test "frame header round-trip" {
    const h = FrameHeader{
        .frame_no = 42,
        .checksum = 0xdeadbeefcafebabe,
        .page_no = 7,
        .size_after = 100,
    };
    var buf: [header_size]u8 = undefined;
    h.encode(&buf);
    const d = FrameHeader.decode(&buf);
    try std.testing.expectEqual(h.frame_no, d.frame_no);
    try std.testing.expectEqual(h.checksum, d.checksum);
    try std.testing.expectEqual(h.page_no, d.page_no);
    try std.testing.expectEqual(h.size_after, d.size_after);
    try std.testing.expect(d.isCommit());
}

test "frame round-trip and size" {
    try std.testing.expectEqual(@as(usize, 4120), frame_size);
    var page: [page_size]u8 = undefined;
    @memset(&page, 0xab);
    page[0] = 1;
    page[page_size - 1] = 2;
    const f = Frame.fromParts(.{
        .frame_no = 1,
        .checksum = 0,
        .page_no = 1,
        .size_after = 0,
    }, &page);
    try std.testing.expect(!f.header.isCommit());
    var buf: [frame_size]u8 = undefined;
    f.encode(&buf);
    const d = try Frame.tryDecode(&buf);
    try std.testing.expectEqual(@as(u64, 1), d.header.frame_no);
    try std.testing.expectEqual(@as(u8, 1), d.page[0]);
    try std.testing.expectEqual(@as(u8, 2), d.page[page_size - 1]);
    try std.testing.expectError(error.InvalidFrameLen, Frame.tryDecode(buf[0 .. frame_size - 1]));
}
