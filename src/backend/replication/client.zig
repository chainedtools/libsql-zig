//! Pure Zig classic `ReplicationLog` pull client (R2.1 + R3a).
//!
//! Handshake (`Hello`) + `BatchLogEntries` + streaming `Snapshot` over gRPC-Web.
//! Does **not** inject frames or expose public `Database.sync` — apply remains
//! R1 bridge / R3b inject.

const std = @import("std");
const Io = std.Io;
const err = @import("../../error.zig");
const wal_log = @import("wal_log.zig");
const frame_mod = @import("frame.zig");
const meta_mod = @import("meta.zig");
const http = @import("http.zig");

/// Handshake outcome. `log_id` / `session_token` are views into `Client`-owned
/// storage (valid until the next `hello` or `deinit`).
pub const HelloResult = struct {
    generation_start_index: u64,
    log_id: []const u8,
    session_token: []const u8,
    current_replication_index: ?u64,
};

pub const BatchResult = struct {
    allocator: std.mem.Allocator,
    /// Owned raw response buffer that `frames` views into.
    raw: []u8,
    frames: []wal_log.RpcFrame,

    pub fn deinit(self: *BatchResult) void {
        self.allocator.free(self.frames);
        self.allocator.free(self.raw);
        self.* = undefined;
    }

    pub fn pageFrame(self: *const BatchResult, i: usize) error{InvalidFrameLen}!frame_mod.Frame {
        return self.frames[i].parsePageFrame();
    }
};

/// Owned page frames from a Snapshot stream (no meta advance).
pub const SnapshotResult = struct {
    allocator: std.mem.Allocator,
    frames: []frame_mod.Frame,

    pub fn deinit(self: *SnapshotResult) void {
        self.allocator.free(self.frames);
        self.* = undefined;
    }
};

/// Accumulated pull without apply (meta is not advanced).
pub const PullResult = struct {
    allocator: std.mem.Allocator,
    /// Owned copies of full FrameBorrowed bytes (header + page) for each frame.
    frames: []frame_mod.Frame,
    /// Primary index from last Hello, if any.
    primary_index: ?u64,
    log_id: []u8,

    pub fn deinit(self: *PullResult) void {
        self.allocator.free(self.frames);
        self.allocator.free(self.log_id);
        self.* = undefined;
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    base_url: []u8,
    auth_token: []u8,
    namespace: []u8,
    session_token: ?[]u8 = null,
    log_id: ?[]u8 = null,
    current_replication_index: ?u64 = null,

    pub fn open(
        io: Io,
        allocator: std.mem.Allocator,
        sync_url: []const u8,
        auth_token: []const u8,
        namespace: []const u8,
    ) err.Error!Client {
        if (auth_token.len == 0) return error.InvalidPath;
        const base = try http.httpBase(allocator, sync_url);
        errdefer allocator.free(base);
        if (!std.mem.startsWith(u8, base, "https://")) return error.InvalidPath;

        const token = allocator.dupe(u8, auth_token) catch return error.OutOfMemory;
        errdefer allocator.free(token);
        const ns = allocator.dupe(u8, namespace) catch return error.OutOfMemory;
        errdefer allocator.free(ns);

        return .{
            .allocator = allocator,
            .io = io,
            .base_url = base,
            .auth_token = token,
            .namespace = ns,
        };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.base_url);
        self.allocator.free(self.auth_token);
        self.allocator.free(self.namespace);
        if (self.session_token) |t| self.allocator.free(t);
        if (self.log_id) |id| self.allocator.free(id);
        self.* = undefined;
    }

    fn headers(self: *const Client) http.RequestHeaders {
        return .{
            .auth_token = self.auth_token,
            .namespace = self.namespace,
            .session_token = self.session_token,
        };
    }

    /// Handshake; stores session token + log_id for subsequent batch/snapshot pulls.
    pub fn hello(self: *Client) err.Error!HelloResult {
        const req_pb = wal_log.HelloRequest.default().encode(self.allocator) catch return error.OutOfMemory;
        defer self.allocator.free(req_pb);

        const url = try http.rpcUrl(self.allocator, self.base_url, "Hello");
        defer self.allocator.free(url);

        // Hello does not send a session token.
        const hdrs = http.RequestHeaders{
            .auth_token = self.auth_token,
            .namespace = self.namespace,
            .session_token = null,
        };
        const resp_pb = try http.postUnary(self.io, self.allocator, url, hdrs, req_pb);
        defer self.allocator.free(resp_pb);

        const decoded = wal_log.HelloResponse.decode(resp_pb) catch return error.Sql;

        // A valid Hello carries both a session token and a log id. Reject a
        // response missing either (fail closed) so we never combine a fresh
        // Hello with stale session state. Duplicate both before freeing or
        // replacing either old value, so the swap is all-or-nothing.
        if (decoded.session_token.len == 0 or
            !wal_log.sessionTokenLooksValid(decoded.session_token) or
            decoded.log_id.len == 0)
        {
            return error.Sql;
        }

        const st = self.allocator.dupe(u8, decoded.session_token) catch return error.OutOfMemory;
        errdefer self.allocator.free(st);
        const id = self.allocator.dupe(u8, decoded.log_id) catch return error.OutOfMemory;

        if (self.session_token) |old| self.allocator.free(old);
        if (self.log_id) |old| self.allocator.free(old);
        self.session_token = st;
        self.log_id = id;

        self.current_replication_index = decoded.current_replication_index;

        // Only return slices owned by `self` — `decoded` views `resp_pb`, which
        // is freed on return.
        return .{
            .generation_start_index = decoded.generation_start_index,
            .log_id = self.log_id orelse "",
            .session_token = self.session_token orelse "",
            .current_replication_index = self.current_replication_index,
        };
    }

    /// Pull one batch of frames starting at `next_offset` (requires prior `hello`).
    ///
    /// Returns `error.NeedSnapshot` when the primary signals that incremental
    /// log pull is insufficient — call `snapshot` then resume.
    pub fn batchLogEntries(self: *Client, next_offset: u64) err.Error!BatchResult {
        if (self.session_token == null) return error.Sql;

        const off = wal_log.LogOffset{ .next_offset = next_offset };
        const req_pb = off.encode(self.allocator) catch return error.OutOfMemory;
        defer self.allocator.free(req_pb);

        const url = try http.rpcUrl(self.allocator, self.base_url, "BatchLogEntries");
        defer self.allocator.free(url);

        const resp_pb = try http.postUnary(self.io, self.allocator, url, self.headers(), req_pb);
        errdefer self.allocator.free(resp_pb);

        // On decode failure the active `errdefer` above frees `resp_pb`; do not
        // free it again here or it would double-free.
        const frames = wal_log.Frames.decodeOwned(self.allocator, resp_pb) catch return error.Sql;

        return .{
            .allocator = self.allocator,
            .raw = resp_pb,
            .frames = frames,
        };
    }

    /// Full/dense snapshot stream from `next_offset` (requires prior `hello`).
    ///
    /// Does **not** write meta or inject frames. Caller applies then advances
    /// `committed_frame_no`. Body size is capped by the HTTP transport (64 MiB).
    pub fn snapshot(self: *Client, next_offset: u64) err.Error!SnapshotResult {
        if (self.session_token == null) return error.Sql;

        const off = wal_log.LogOffset{ .next_offset = next_offset };
        const req_pb = off.encode(self.allocator) catch return error.OutOfMemory;
        defer self.allocator.free(req_pb);

        const url = try http.rpcUrl(self.allocator, self.base_url, "Snapshot");
        defer self.allocator.free(url);

        var stream = try http.postStream(self.io, self.allocator, url, self.headers(), req_pb);
        defer stream.deinit();

        var list: std.ArrayList(frame_mod.Frame) = .empty;
        errdefer list.deinit(self.allocator);

        var offset = next_offset;
        for (stream.messages) |msg| {
            const rpc = wal_log.RpcFrame.decode(msg) catch return error.Sql;
            const pf = rpc.parsePageFrame() catch return error.Sql;
            try appendFrameWithContinuity(&list, self.allocator, pf, &offset);
        }

        return .{
            .allocator = self.allocator,
            .frames = try list.toOwnedSlice(self.allocator),
        };
    }

    /// Hello + pull batches until empty or caught up vs primary index.
    ///
    /// On `NEED_SNAPSHOT` from `BatchLogEntries`, performs one `Snapshot` RPC
    /// (counts as one batch toward `max_batches`) then resumes incremental pull.
    ///
    /// Does **not** write meta or inject frames. On `log_id` mismatch with
    /// `expected_log_id` (from meta), returns `error.Sql` without wiping files.
    ///
    /// `start_offset` should be `WalIndexMeta.nextOffset()` (0 when none).
    pub fn pullUntilCaughtUp(
        self: *Client,
        start_offset: u64,
        expected_log_id: ?[]const u8,
        max_batches: usize,
    ) err.Error!PullResult {
        const hello_res = try self.hello();

        if (expected_log_id) |want| {
            if (hello_res.log_id.len != 0 and !std.mem.eql(u8, want, hello_res.log_id)) {
                return error.Sql; // LogIncompatible — caller must not auto-delete
            }
        }

        const log_id_owned = self.allocator.dupe(u8, hello_res.log_id) catch return error.OutOfMemory;
        errdefer self.allocator.free(log_id_owned);

        var list: std.ArrayList(frame_mod.Frame) = .empty;
        errdefer list.deinit(self.allocator);

        var offset = start_offset;
        var batches: usize = 0;
        while (batches < max_batches) : (batches += 1) {
            if (self.current_replication_index) |primary| {
                // Caught up: next frame would be primary+1 or we already have primary.
                if (offset > 0 and offset - 1 >= primary) break;
                if (offset == 0 and primary == 0) {
                    // Empty primary — still try one batch then stop on empty.
                }
            }

            var batch = self.batchLogEntries(offset) catch |e| switch (e) {
                error.NeedSnapshot => {
                    // Snapshot counts as this loop iteration's batch budget.
                    var snap = try self.snapshot(offset);
                    defer snap.deinit();
                    if (snap.frames.len == 0) {
                        // Fail closed: an empty snapshot is only acceptable when
                        // the replica is provably caught up to the primary.
                        const caught_up = if (self.current_replication_index) |primary|
                            (offset == 0 and primary == 0) or
                                (offset > 0 and offset - 1 >= primary)
                        else
                            false;
                        if (!caught_up) return error.Sql;
                        break;
                    }
                    for (snap.frames) |pf| {
                        try appendFrameWithContinuity(&list, self.allocator, pf, &offset);
                    }
                    if (self.current_replication_index) |primary| {
                        if (offset > 0 and offset - 1 >= primary) break;
                    }
                    continue;
                },
                else => return e,
            };
            defer batch.deinit();

            if (batch.frames.len == 0) break;

            for (batch.frames) |rpc| {
                const pf = rpc.parsePageFrame() catch return error.Sql;
                try appendFrameWithContinuity(&list, self.allocator, pf, &offset);
            }

            if (self.current_replication_index) |primary| {
                if (offset > 0 and offset - 1 >= primary) break;
            }
        }

        return .{
            .allocator = self.allocator,
            .frames = try list.toOwnedSlice(self.allocator),
            .primary_index = self.current_replication_index,
            .log_id = log_id_owned,
        };
    }
};

/// Append one page frame, enforcing frame_no continuity and advancing `offset`.
///
/// On a fresh pull (`offset == 0` means "from the first frame") frame numbers
/// are 1-based, so accept the server's first frame_no as the baseline.
fn appendFrameWithContinuity(
    list: *std.ArrayList(frame_mod.Frame),
    allocator: std.mem.Allocator,
    pf: frame_mod.Frame,
    offset: *u64,
) err.Error!void {
    const frame_no = pf.header.frame_no;
    if (offset.* == 0) {
        if (frame_no == 0) return error.Sql;
    } else if (frame_no != offset.*) {
        return error.Sql;
    }
    // Guard against a server-provided maxInt(u64) overflowing offset.
    const next = std.math.add(u64, frame_no, 1) catch return error.Sql;
    list.append(allocator, pf) catch return error.OutOfMemory;
    offset.* = next;
}

/// Parse a UUID string into little-endian u128 for `WalIndexMeta.log_id`.
/// Official client stores UUID as u128; we accept standard 8-4-4-4-12 hex form.
pub fn logIdFromUuidString(s: []const u8) err.Error!u128 {
    if (!wal_log.sessionTokenLooksValid(s)) return error.Sql;
    var hex: [32]u8 = undefined;
    var j: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (j >= hex.len) return error.Sql;
        hex[j] = c;
        j += 1;
    }
    if (j != 32) return error.Sql;
    // UUID as big-endian 128-bit integer is common; store as big-endian value
    // in the u128 bits so encode/decode LE on disk still round-trips the same
    // 16 raw bytes as parsing network order into a native u128 via big-endian.
    return std.fmt.parseInt(u128, hex[0..], 16) catch return error.Sql;
}

/// Build meta after apply: official layout uses log_id u128 + committed frame.
pub fn metaFromHelloLogId(log_id_str: []const u8, committed_frame_no: u64) err.Error!meta_mod.WalIndexMeta {
    return .{
        .log_id = try logIdFromUuidString(log_id_str),
        .committed_frame_no = committed_frame_no,
    };
}

test "log id uuid parse" {
    const id = try logIdFromUuidString("550e8400-e29b-41d4-a716-446655440000");
    try std.testing.expect(id != 0);
    const m = try metaFromHelloLogId("550e8400-e29b-41d4-a716-446655440000", meta_mod.WalIndexMeta.none_frame);
    try std.testing.expectEqual(id, m.log_id);
    try std.testing.expectEqual(@as(u64, 0), m.nextOffset());
}

test "client open rejects empty token and plaintext base" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    try std.testing.expectError(error.InvalidPath, Client.open(io, gpa, "libsql://x.example", "", "default"));
    try std.testing.expectError(error.InvalidPath, Client.open(io, gpa, "http://x.example", "tok", "default"));
}

test "appendFrameWithContinuity continuity" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(frame_mod.Frame) = .empty;
    defer list.deinit(gpa);

    var page0 = [_]u8{0} ** frame_mod.page_size;
    var page1 = [_]u8{1} ** frame_mod.page_size;
    var page2 = [_]u8{2} ** frame_mod.page_size;

    var offset: u64 = 0;
    const f1 = frame_mod.Frame.fromParts(.{
        .frame_no = 3,
        .checksum = 1,
        .page_no = 1,
        .size_after = 1,
    }, &page0);
    try appendFrameWithContinuity(&list, gpa, f1, &offset);
    try std.testing.expectEqual(@as(u64, 4), offset);

    const f2 = frame_mod.Frame.fromParts(.{
        .frame_no = 4,
        .checksum = 2,
        .page_no = 2,
        .size_after = 0,
    }, &page1);
    try appendFrameWithContinuity(&list, gpa, f2, &offset);
    try std.testing.expectEqual(@as(u64, 5), offset);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);

    const gap = frame_mod.Frame.fromParts(.{
        .frame_no = 9,
        .checksum = 3,
        .page_no = 3,
        .size_after = 0,
    }, &page2);
    try std.testing.expectError(error.Sql, appendFrameWithContinuity(&list, gpa, gap, &offset));
}
