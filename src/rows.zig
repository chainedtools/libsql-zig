const std = @import("std");
const c = @import("c/sqlite.zig");
const err = @import("error.zig");
const value_json = @import("backend/hrana/value_json.zig");

/// A single row from a stepped statement.
///
/// - **local:** borrowed from the SQLite statement (invalid after next step/reset/deinit).
/// - **remote:** references owned cells in the remote statement result (valid until next step/deinit).
pub const Row = struct {
    kind: enum { local, remote },
    local_stmt: ?*c.sqlite3_stmt = null,
    remote_cells: ?[]const value_json.Owned = null,
    remote_col_names: ?[]const []const u8 = null,

    pub fn columnCount(self: Row) usize {
        return switch (self.kind) {
            .local => @intCast(c.sqlite3_column_count(self.local_stmt.?)),
            .remote => self.remote_cells.?.len,
        };
    }

    pub fn columnType(self: Row, col: usize) err.Error!c_int {
        try self.checkCol(col);
        return switch (self.kind) {
            .local => c.sqlite3_column_type(self.local_stmt.?, @intCast(col)),
            .remote => switch (self.remote_cells.?[col]) {
                .null => c.SQLITE_NULL,
                .integer => c.SQLITE_INTEGER,
                .float => c.SQLITE_FLOAT,
                .text => c.SQLITE_TEXT,
                .blob => c.SQLITE_BLOB,
            },
        };
    }

    pub fn isNull(self: Row, col: usize) err.Error!bool {
        return (try self.columnType(col)) == c.SQLITE_NULL;
    }

    pub fn int(self: Row, col: usize) err.Error!i64 {
        try self.checkCol(col);
        return switch (self.kind) {
            .local => c.sqlite3_column_int64(self.local_stmt.?, @intCast(col)),
            .remote => switch (self.remote_cells.?[col]) {
                .integer => |i| i,
                .float => |f| blk: {
                    // @intFromFloat is illegal behavior for non-finite or
                    // out-of-range inputs; fail closed instead of trapping.
                    const min_f: f64 = @floatFromInt(std.math.minInt(i64));
                    const max_f: f64 = @floatFromInt(std.math.maxInt(i64));
                    if (!std.math.isFinite(f) or f < min_f or f >= max_f) return error.Sql;
                    break :blk @intFromFloat(f);
                },
                .null => 0,
                else => return error.Sql,
            },
        };
    }

    pub fn float(self: Row, col: usize) err.Error!f64 {
        try self.checkCol(col);
        return switch (self.kind) {
            .local => c.sqlite3_column_double(self.local_stmt.?, @intCast(col)),
            .remote => switch (self.remote_cells.?[col]) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                .null => 0,
                else => return error.Sql,
            },
        };
    }

    /// Text valid until the next step/reset/finalize (local) or statement deinit (remote).
    pub fn text(self: Row, col: usize) err.Error!?[]const u8 {
        try self.checkCol(col);
        return switch (self.kind) {
            .local => blk: {
                if (c.sqlite3_column_type(self.local_stmt.?, @intCast(col)) == c.SQLITE_NULL) break :blk null;
                // A non-NULL column that yields no pointer means SQLite failed to
                // materialize the value (e.g. OOM during conversion): fail closed
                // rather than silently downgrading the value to null.
                const ptr = c.sqlite3_column_text(self.local_stmt.?, @intCast(col)) orelse return error.Sql;
                const n = c.sqlite3_column_bytes(self.local_stmt.?, @intCast(col));
                if (n < 0) return error.Sql;
                break :blk ptr[0..@intCast(n)];
            },
            .remote => switch (self.remote_cells.?[col]) {
                .text => |t| t,
                .null => null,
                else => return error.Sql,
            },
        };
    }

    pub fn blob(self: Row, col: usize) err.Error!?[]const u8 {
        try self.checkCol(col);
        return switch (self.kind) {
            .local => blk: {
                if (c.sqlite3_column_type(self.local_stmt.?, @intCast(col)) == c.SQLITE_NULL) break :blk null;
                const n = c.sqlite3_column_bytes(self.local_stmt.?, @intCast(col));
                if (n < 0) return error.Sql;
                // sqlite3_column_blob returns NULL for a zero-length BLOB, which is
                // a valid (non-NULL) empty blob: handle it before treating NULL as
                // an error.
                if (n == 0) break :blk &[_]u8{};
                // n > 0 with a NULL pointer means SQLite could not materialize the
                // blob (e.g. OOM during conversion): fail closed.
                const ptr = c.sqlite3_column_blob(self.local_stmt.?, @intCast(col)) orelse return error.Sql;
                break :blk ptr[0..@intCast(n)];
            },
            .remote => switch (self.remote_cells.?[col]) {
                .blob => |b| b,
                .null => null,
                else => return error.Sql,
            },
        };
    }

    pub fn columnName(self: Row, col: usize) err.Error![]const u8 {
        try self.checkCol(col);
        return switch (self.kind) {
            .local => blk: {
                const name = c.sqlite3_column_name(self.local_stmt.?, @intCast(col)) orelse return error.Sql;
                break :blk std.mem.span(name);
            },
            .remote => {
                // Fail closed: absent metadata or a col/name length mismatch is a
                // malformed result, not an empty name.
                const names = self.remote_col_names orelse return error.Sql;
                if (col >= names.len) return error.Sql;
                return names[col];
            },
        };
    }

    fn checkCol(self: Row, col: usize) err.Error!void {
        if (col >= self.columnCount()) return error.Column;
    }
};

test "remote int rejects out-of-range float" {
    const cells = [_]value_json.Owned{.{ .float = 1e300 }};
    const row = Row{ .kind = .remote, .remote_cells = &cells };
    try std.testing.expectError(error.Sql, row.int(0));
}

test "remote int accepts in-range float" {
    const cells = [_]value_json.Owned{.{ .float = 42.0 }};
    const row = Row{ .kind = .remote, .remote_cells = &cells };
    try std.testing.expectEqual(@as(i64, 42), try row.int(0));
}

test "remote columnName fails closed without metadata" {
    const cells = [_]value_json.Owned{.{ .integer = 1 }};
    const row = Row{ .kind = .remote, .remote_cells = &cells };
    try std.testing.expectError(error.Sql, row.columnName(0));
}

test "column OOB is Column not Bind" {
    const cells = [_]value_json.Owned{.{ .integer = 1 }};
    const row = Row{ .kind = .remote, .remote_cells = &cells };
    try std.testing.expectError(error.Column, row.int(1));
    try std.testing.expectError(error.Column, row.isNull(99));
}
