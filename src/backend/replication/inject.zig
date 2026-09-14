//! Classic replica frame apply (R3b).
//!
//! Upstream applies 4 KiB page frames through a custom `WalManager` that swaps
//! pages during `xFrames` (see libsql-replication `SqliteInjector`). Stock SQLite
//! cannot do this. With `-Dengine=libsql` the amalgamation exposes
//! `libsql_open_v3` + virtual WAL; the full InjectorWal port is the next R3b slice.
//!
//! Until `implemented` is true, pure `Database.sync` fails closed with
//! `error.Unsupported` after pull (never pretends to inject on stock SQLite).

const std = @import("std");
const err = @import("../../error.zig");
const frame_mod = @import("frame.zig");

const build_options = @import("build_options");

/// Linked amalgamation is libSQL (virtual WAL / inject prerequisite).
pub const engine_is_libsql = build_options.engine == .libsql;

/// Pure Zig WAL inject is ready for production use.
/// Flip to `true` only after InjectorWal parity tests pass (R3b complete).
pub const implemented = false;

/// Whether this build can *eventually* inject (libsql engine pin).
pub const engine_supports_inject = engine_is_libsql;

/// Whether pure inject is available *now* (engine + implementation).
pub fn available() bool {
    return engine_supports_inject and implemented;
}

pub const ApplyResult = struct {
    /// Highest frame_no successfully committed via inject (commit boundary).
    last_commit_frame_no: ?u64 = null,
    frames_applied: u64 = 0,
};

/// Apply owned page frames to a local replica file.
///
/// R3b.0: always `error.Unsupported` until `implemented` is true. Callers must
/// not advance `{db}-client_wal_index` when this returns an error.
pub fn applyFrames(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    frames: []const frame_mod.Frame,
) err.Error!ApplyResult {
    _ = allocator;
    _ = db_path;
    _ = frames;
    if (!engine_supports_inject) return error.Unsupported;
    if (!implemented) return error.Unsupported;
    // R3b.1+: open via libsql_open_v3(InjectorWalManager), dummy INSERT flush,
    // advance only after LIBSQL_INJECT_OK — see docs/replica-protocol-spike.md.
    return error.Unsupported;
}

/// Buffer frames and flush on commit / capacity (mirrors SqliteInjector policy).
pub const Injector = struct {
    allocator: std.mem.Allocator,
    db_path: []const u8,
    capacity: usize,
    buffer: std.ArrayList(frame_mod.Frame),
    biggest_uncommitted: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        db_path: []const u8,
        capacity: usize,
    ) err.Error!Injector {
        if (!available()) return error.Unsupported;
        const path = allocator.dupe(u8, db_path) catch return error.OutOfMemory;
        errdefer allocator.free(path);
        return .{
            .allocator = allocator,
            .db_path = path,
            .capacity = if (capacity == 0) 64 else capacity,
            .buffer = .empty,
        };
    }

    pub fn deinit(self: *Injector) void {
        self.buffer.deinit(self.allocator);
        self.allocator.free(self.db_path);
        self.* = undefined;
    }

    /// Queue one frame; may flush when commit boundary or capacity is hit.
    pub fn injectFrame(self: *Injector, frame: frame_mod.Frame) err.Error!?u64 {
        self.buffer.append(self.allocator, frame) catch return error.OutOfMemory;
        const close_txn = frame.header.isCommit();
        if (close_txn or self.buffer.items.len >= self.capacity) {
            return self.flush();
        }
        return null;
    }

    pub fn flush(self: *Injector) err.Error!?u64 {
        if (self.buffer.items.len == 0) return null;
        const result = try applyFrames(self.allocator, self.db_path, self.buffer.items);
        self.buffer.clearRetainingCapacity();
        if (result.last_commit_frame_no) |n| {
            self.biggest_uncommitted = 0;
            return n;
        }
        return null;
    }

    pub fn rollback(self: *Injector) void {
        self.buffer.clearRetainingCapacity();
        self.biggest_uncommitted = 0;
    }
};

test "inject unavailable on stock or until implemented" {
    // Default CI engine is sqlite → Unsupported. Even with libsql, R3b.0 keeps
    // `implemented = false` so apply still fails closed.
    try std.testing.expect(!available() or !implemented);
    try std.testing.expectError(
        error.Unsupported,
        applyFrames(std.testing.allocator, "x.db", &.{}),
    );
}

test "injector init fails closed until implemented" {
    try std.testing.expectError(
        error.Unsupported,
        Injector.init(std.testing.allocator, "x.db", 8),
    );
}
