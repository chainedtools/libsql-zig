//! On-disk client WAL index meta for classic embedded replicas.
//!
//! Layout matches `libsql-replication` `WalIndexMetaData` (little-endian):
//! `log_id: u128`, `committed_frame_no: u64`, padding 8 bytes.
//! File name next to the DB: `{basename}-client_wal_index`.

const std = @import("std");
const Io = std.Io;

pub const meta_size: usize = 32;

pub const WalIndexMeta = struct {
    log_id: u128,
    /// `std.math.maxInt(u64)` means “no commit yet” (official client sentinel).
    committed_frame_no: u64,

    pub const none_frame: u64 = std.math.maxInt(u64);

    pub fn encode(self: WalIndexMeta, out: *[meta_size]u8) void {
        std.mem.writeInt(u128, out[0..16], self.log_id, .little);
        std.mem.writeInt(u64, out[16..24], self.committed_frame_no, .little);
        @memset(out[24..32], 0);
    }

    pub fn decode(bytes: *const [meta_size]u8) WalIndexMeta {
        return .{
            .log_id = std.mem.readInt(u128, bytes[0..16], .little),
            .committed_frame_no = std.mem.readInt(u64, bytes[16..24], .little),
        };
    }

    pub fn currentFrameNo(self: WalIndexMeta) ?u64 {
        if (self.committed_frame_no == none_frame) return null;
        return self.committed_frame_no;
    }

    pub fn nextOffset(self: WalIndexMeta) u64 {
        return if (self.currentFrameNo()) |n| n + 1 else 0;
    }
};

/// `{dir}/{basename}-client_wal_index` for a db path like `/tmp/foo.db`.
pub fn indexPathAlloc(allocator: std.mem.Allocator, db_path: []const u8) error{OutOfMemory}![]u8 {
    const base = std.fs.path.basename(db_path);
    const dir = std.fs.path.dirname(db_path) orelse ".";
    return std.fmt.allocPrint(allocator, "{s}/{s}-client_wal_index", .{ dir, base });
}

pub const IoError = error{
    OutOfMemory,
    /// File present but wrong size / unreadable.
    InvalidMeta,
    /// Filesystem failure (permission, I/O, rename, …).
    Io,
};

/// Load `{db}-client_wal_index` if it exists.
///
/// Returns `null` when the file is missing (caller decides: new replica vs
/// RequiresCleanDatabase for an existing user DB — do **not** auto-delete).
pub fn load(io: Io, allocator: std.mem.Allocator, db_path: []const u8) IoError!?WalIndexMeta {
    const path = try indexPathAlloc(allocator, db_path);
    defer allocator.free(path);

    // Read one extra byte so oversized files fail as InvalidMeta.
    var buf: [meta_size + 1]u8 = undefined;
    const data = Io.Dir.cwd().readFile(io, path, &buf) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return error.Io,
    };
    if (data.len != meta_size) return error.InvalidMeta;
    return WalIndexMeta.decode(data[0..meta_size]);
}

/// Persist meta next to the DB (temp file then rename into place).
///
/// Callers must only advance `committed_frame_no` after a successful inject
/// commit; this helper does not interpret frame numbers.
pub fn save(io: Io, allocator: std.mem.Allocator, db_path: []const u8, meta: WalIndexMeta) IoError!void {
    const path = try indexPathAlloc(allocator, db_path);
    defer allocator.free(path);

    var buf: [meta_size]u8 = undefined;
    meta.encode(&buf);

    // Write to a randomly named, exclusively created (`O_EXCL`) temp file beside
    // the target, then atomically rename it into place. Avoids the predictable
    // `{path}.tmp` name, which a local attacker could pre-create as a symlink to
    // redirect the write. `deinit` removes the temp file on any failure.
    var af = Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true }) catch return error.Io;
    defer af.deinit(io);

    af.file.writePositionalAll(io, &buf, 0) catch return error.Io;
    af.replace(io) catch return error.Io;
}

test "wal index meta round-trip" {
    const m = WalIndexMeta{
        .log_id = 0x11223344556677889900aabbccddeeff,
        .committed_frame_no = 7,
    };
    var buf: [meta_size]u8 = undefined;
    m.encode(&buf);
    const d = WalIndexMeta.decode(&buf);
    try std.testing.expectEqual(m.log_id, d.log_id);
    try std.testing.expectEqual(m.committed_frame_no, d.committed_frame_no);
    try std.testing.expectEqual(@as(?u64, 7), d.currentFrameNo());
    try std.testing.expectEqual(@as(u64, 8), d.nextOffset());
}

test "none frame sentinel" {
    const m = WalIndexMeta{ .log_id = 1, .committed_frame_no = WalIndexMeta.none_frame };
    try std.testing.expect(m.currentFrameNo() == null);
    try std.testing.expectEqual(@as(u64, 0), m.nextOffset());
}

test "index path" {
    const gpa = std.testing.allocator;
    const p = try indexPathAlloc(gpa, "/var/lib/app/replica.db");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("/var/lib/app/replica.db-client_wal_index", p);
}

test "meta load missing and save round-trip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const db_path = try std.fs.path.join(gpa, &.{ dir_path, "replica.db" });
    defer gpa.free(db_path);

    try std.testing.expect((try load(io, gpa, db_path)) == null);

    const m = WalIndexMeta{
        .log_id = 0x11223344556677889900aabbccddeeff,
        .committed_frame_no = 42,
    };
    try save(io, gpa, db_path, m);

    const loaded = (try load(io, gpa, db_path)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(m.log_id, loaded.log_id);
    try std.testing.expectEqual(m.committed_frame_no, loaded.committed_frame_no);

    // Corrupt size → InvalidMeta
    try tmp.dir.writeFile(io, .{ .sub_path = "replica.db-client_wal_index", .data = "short" });
    try std.testing.expectError(error.InvalidMeta, load(io, gpa, db_path));
}
