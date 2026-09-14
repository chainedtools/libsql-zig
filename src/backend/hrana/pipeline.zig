//! Build and parse Hrana over HTTP `v3/pipeline` JSON bodies.

const std = @import("std");
const value = @import("../../value.zig");
const value_json = @import("value_json.zig");
const err = @import("../../error.zig");
const batch_mod = @import("../../batch.zig");

pub const StmtResult = struct {
    cols: [][]u8,
    rows: [][]value_json.Owned,
    affected_row_count: u64,
    last_insert_rowid: i64,

    pub fn deinit(self: *StmtResult, allocator: std.mem.Allocator) void {
        for (self.cols) |c| allocator.free(c);
        allocator.free(self.cols);
        for (self.rows) |row| {
            for (row) |*cell| cell.deinit(allocator);
            allocator.free(row);
        }
        allocator.free(self.rows);
        self.* = undefined;
    }
};

pub const PipelineOutcome = struct {
    /// Owned baton string, or null if stream closed.
    baton: ?[]u8,
    /// Owned base_url override, or null to keep previous.
    base_url: ?[]u8,
    /// First execute/sequence result when applicable.
    stmt: ?StmtResult,
    /// True when a stream-level error occurred.
    failed: bool,
    /// Human message for failed (not logged with secrets).
    error_message: ?[]u8,
    /// Total affected rows from batch (best-effort).
    batch_affected: i64 = 0,
    /// Number of batch steps that produced a result (not skipped).
    batch_steps_run: usize = 0,

    pub fn deinit(self: *PipelineOutcome, allocator: std.mem.Allocator) void {
        if (self.baton) |b| allocator.free(b);
        if (self.base_url) |u| allocator.free(u);
        if (self.stmt) |*s| s.deinit(allocator);
        if (self.error_message) |m| allocator.free(m);
        self.* = undefined;
    }
};

pub const NamedArg = batch_mod.NamedArg;

/// Build a pipeline body with a single `execute` request.
pub fn buildExecuteBody(
    allocator: std.mem.Allocator,
    baton: ?[]const u8,
    sql: []const u8,
    args: []const value.Value,
    named_args: []const NamedArg,
    want_rows: bool,
) err.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    writeExecuteBody(&aw.writer, baton, sql, args, named_args, want_rows) catch return error.Sql;
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeExecuteBody(
    w: *std.Io.Writer,
    baton: ?[]const u8,
    sql: []const u8,
    args: []const value.Value,
    named_args: []const NamedArg,
    want_rows: bool,
) std.Io.Writer.Error!void {
    try w.writeAll("{\"baton\":");
    if (baton) |b| {
        try writeJsonString(w, b);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"requests\":[{\"type\":\"execute\",\"stmt\":");
    try writeStmt(w, sql, args, named_args, want_rows);
    try w.writeAll("}]}");
}

fn writeStmt(
    w: *std.Io.Writer,
    sql: []const u8,
    args: []const value.Value,
    named_args: []const NamedArg,
    want_rows: bool,
) std.Io.Writer.Error!void {
    try w.writeAll("{\"sql\":");
    try writeJsonString(w, sql);
    try w.writeAll(",\"args\":[");
    for (args, 0..) |a, i| {
        if (i > 0) try w.writeAll(",");
        try value_json.writeValue(w, a);
    }
    try w.writeAll("],\"named_args\":[");
    for (named_args, 0..) |na, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try writeJsonString(w, na.name);
        try w.writeAll(",\"value\":");
        try value_json.writeValue(w, na.value);
        try w.writeAll("}");
    }
    try w.print("],\"want_rows\":{s}}}", .{if (want_rows) "true" else "false"});
}

/// Build a pipeline body with a Hrana `batch` request wrapping the steps.
/// Wraps steps in BEGIN/COMMIT with ok-conditions so partial failure rolls back
/// when the server supports conditional batch (Hrana 1+).
pub fn buildBatchBody(
    allocator: std.mem.Allocator,
    baton: ?[]const u8,
    steps: []const batch_mod.Step,
) err.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    writeBatchBody(&aw.writer, baton, steps) catch return error.Sql;
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeBatchBody(
    w: *std.Io.Writer,
    baton: ?[]const u8,
    steps: []const batch_mod.Step,
) std.Io.Writer.Error!void {
    try w.writeAll("{\"baton\":");
    if (baton) |b| {
        try writeJsonString(w, b);
    } else {
        try w.writeAll("null");
    }
    // Batch step layout (0-based Hrana indices):
    //   0             : BEGIN
    //   1 .. steps.len: user steps (user step i → index i+1, conditioned on ok(i))
    //   steps.len + 1 : COMMIT   (conditioned on ok of the last user step)
    //   steps.len + 2 : ROLLBACK (runs when BEGIN opened a transaction that did not
    //                   COMMIT, so a failed user step still closes the explicit
    //                   transaction on the baton instead of leaking it to the next
    //                   request on the same stream)
    try w.writeAll(",\"requests\":[{\"type\":\"batch\",\"batch\":{\"steps\":[");
    // BEGIN
    try w.writeAll("{\"stmt\":");
    try writeStmt(w, "BEGIN", &.{}, &.{}, false);
    try w.writeAll("}");
    for (steps, 0..) |step, i| {
        try w.writeAll(",");
        // condition: previous step ok
        try w.print("{{\"condition\":{{\"type\":\"ok\",\"step\":{d}}},\"stmt\":", .{i});
        try writeStmt(w, step.sql, step.args, step.named_args, step.want_rows);
        try w.writeAll("}");
    }
    // COMMIT conditioned on the last user step (index steps.len) being ok.
    try w.print(",{{\"condition\":{{\"type\":\"ok\",\"step\":{d}}},\"stmt\":", .{steps.len});
    try writeStmt(w, "COMMIT", &.{}, &.{}, false);
    try w.writeAll("}");
    // ROLLBACK when BEGIN succeeded (transaction open) but COMMIT did not run or
    // did not succeed: and(ok(BEGIN), not(ok(COMMIT))).
    const commit_index: usize = steps.len + 1;
    try w.print(
        ",{{\"condition\":{{\"type\":\"and\",\"conds\":[{{\"type\":\"ok\",\"step\":0}},{{\"type\":\"not\",\"cond\":{{\"type\":\"ok\",\"step\":{d}}}}}]}},\"stmt\":",
        .{commit_index},
    );
    try writeStmt(w, "ROLLBACK", &.{}, &.{}, false);
    try w.writeAll("}]}}]}");
}

/// Build a pipeline body with a single `sequence` request (multi-statement, no rows).
pub fn buildSequenceBody(
    allocator: std.mem.Allocator,
    baton: ?[]const u8,
    sql: []const u8,
) err.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    writeSequenceBody(&aw.writer, baton, sql) catch return error.Sql;
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeSequenceBody(w: *std.Io.Writer, baton: ?[]const u8, sql: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("{\"baton\":");
    if (baton) |b| {
        try writeJsonString(w, b);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"requests\":[{\"type\":\"sequence\",\"sql\":");
    try writeJsonString(w, sql);
    try w.writeAll("}]}");
}

/// Build a pipeline body with a single `close` request.
pub fn buildCloseBody(
    allocator: std.mem.Allocator,
    baton: ?[]const u8,
) err.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    writeCloseBody(&aw.writer, baton) catch return error.Sql;
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeCloseBody(w: *std.Io.Writer, baton: ?[]const u8) std.Io.Writer.Error!void {
    try w.writeAll("{\"baton\":");
    if (baton) |b| {
        try writeJsonString(w, b);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"requests\":[{\"type\":\"close\"}]}");
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

pub fn parsePipelineResponse(allocator: std.mem.Allocator, body: []const u8) err.Error!PipelineOutcome {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.Sql;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.Sql,
    };

    var outcome: PipelineOutcome = .{
        .baton = null,
        .base_url = null,
        .stmt = null,
        .failed = false,
        .error_message = null,
    };
    errdefer outcome.deinit(allocator);

    if (root.get("baton")) |baton_v| {
        switch (baton_v) {
            .string => |s| outcome.baton = try allocator.dupe(u8, s),
            .null => {},
            else => return error.Sql,
        }
    }
    if (root.get("base_url")) |url_v| {
        switch (url_v) {
            .string => |s| outcome.base_url = try allocator.dupe(u8, s),
            .null => {},
            else => return error.Sql,
        }
    }

    const results_v = root.get("results") orelse return error.Sql;
    const results = switch (results_v) {
        .array => |a| a,
        else => return error.Sql,
    };

    // We always send exactly one request, so an empty results array is a
    // protocol violation rather than a benign no-op.
    if (results.items.len == 0) return error.Sql;

    // Process first result (we send single-request pipelines).
    const first = results.items[0];
    const robj = switch (first) {
        .object => |o| o,
        else => return error.Sql,
    };
    const rtype = robj.get("type") orelse return error.Sql;
    const rtype_s = switch (rtype) {
        .string => |s| s,
        else => return error.Sql,
    };

    if (std.mem.eql(u8, rtype_s, "error")) {
        outcome.failed = true;
        if (robj.get("error")) |e| {
            if (e == .object) {
                if (e.object.get("message")) |m| {
                    if (m == .string) {
                        outcome.error_message = try allocator.dupe(u8, m.string);
                    }
                }
            }
        }
        return outcome;
    }

    if (!std.mem.eql(u8, rtype_s, "ok")) return error.Sql;
    const response = robj.get("response") orelse return error.Sql;
    const resp_obj = switch (response) {
        .object => |o| o,
        else => return error.Sql,
    };
    const resp_type = resp_obj.get("type") orelse return error.Sql;
    const resp_type_s = switch (resp_type) {
        .string => |s| s,
        else => return error.Sql,
    };

    if (std.mem.eql(u8, resp_type_s, "execute")) {
        const result = resp_obj.get("result") orelse return error.Sql;
        outcome.stmt = try parseStmtResult(allocator, result);
    } else if (std.mem.eql(u8, resp_type_s, "batch")) {
        const br = resp_obj.get("result") orelse return error.Sql;
        try parseBatchResult(allocator, br, &outcome);
    } else if (std.mem.eql(u8, resp_type_s, "sequence") or std.mem.eql(u8, resp_type_s, "close")) {
        // no rows
    } else {
        // Unknown response type for a request we sent is a protocol violation.
        return error.Sql;
    }

    return outcome;
}

fn parseBatchResult(allocator: std.mem.Allocator, v: std.json.Value, outcome: *PipelineOutcome) err.Error!void {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.Sql,
    };
    // step_results is an array (JSON) of StmtResult | null, one entry per batch
    // step. Our batch layout is [BEGIN, user steps..., COMMIT, ROLLBACK], so only
    // the interior indices are user steps; the transaction wrappers are excluded
    // from steps_run and the affected-row total.
    const sr = obj.get("step_results") orelse return error.Sql;
    {
        const arr = switch (sr) {
            .array => |a| a,
            else => return error.Sql,
        };
        const user_start: usize = 1;
        const user_end: usize = if (arr.items.len >= 3) arr.items.len - 2 else user_start;
        for (arr.items, 0..) |item, i| {
            const is_user = i >= user_start and i < user_end;
            switch (item) {
                .null => {},
                .object => |o| {
                    if (is_user) {
                        outcome.batch_steps_run += 1;
                        if (o.get("affected_row_count")) |a| switch (a) {
                            .integer => |n| outcome.batch_affected += @intCast(@max(n, 0)),
                            else => return error.Sql,
                        };
                    }
                },
                else => return error.Sql,
            }
        }
    }
    // step_errors: if any non-null, mark failed
    const se = obj.get("step_errors") orelse return error.Sql;
    {
        const arr = switch (se) {
            .array => |a| a,
            else => return error.Sql,
        };
        for (arr.items) |item| {
            if (item != .null) {
                outcome.failed = true;
                if (item == .object) {
                    if (item.object.get("message")) |m| {
                        if (m == .string and outcome.error_message == null) {
                            outcome.error_message = try allocator.dupe(u8, m.string);
                        }
                    }
                }
            }
        }
    }
}

fn parseStmtResult(allocator: std.mem.Allocator, v: std.json.Value) err.Error!StmtResult {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.Sql,
    };

    var cols: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (cols.items) |c| allocator.free(c);
        cols.deinit(allocator);
    }
    if (obj.get("cols")) |cols_v| {
        const arr = switch (cols_v) {
            .array => |a| a,
            else => return error.Sql,
        };
        for (arr.items) |col| {
            const cobj = switch (col) {
                .object => |o| o,
                else => return error.Sql,
            };
            const name_v = cobj.get("name") orelse {
                try cols.append(allocator, try allocator.dupe(u8, ""));
                continue;
            };
            switch (name_v) {
                .string => |s| try cols.append(allocator, try allocator.dupe(u8, s)),
                .null => try cols.append(allocator, try allocator.dupe(u8, "")),
                else => try cols.append(allocator, try allocator.dupe(u8, "")),
            }
        }
    }

    var rows: std.ArrayListUnmanaged([]value_json.Owned) = .empty;
    errdefer {
        for (rows.items) |row| {
            for (row) |*cell| cell.deinit(allocator);
            allocator.free(row);
        }
        rows.deinit(allocator);
    }
    if (obj.get("rows")) |rows_v| {
        const arr = switch (rows_v) {
            .array => |a| a,
            else => return error.Sql,
        };
        for (arr.items) |row_v| {
            const cells = switch (row_v) {
                .array => |a| a,
                else => return error.Sql,
            };
            const owned_row = try allocator.alloc(value_json.Owned, cells.items.len);
            errdefer allocator.free(owned_row);
            var filled: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < filled) : (i += 1) owned_row[i].deinit(allocator);
            }
            for (cells.items, 0..) |cell, i| {
                // Propagate allocation failures unchanged; only decode errors map to Sql.
                owned_row[i] = value_json.Owned.fromJson(allocator, cell) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.Sql,
                };
                filled = i + 1;
            }
            try rows.append(allocator, owned_row);
        }
    }

    var affected: u64 = 0;
    if (obj.get("affected_row_count")) |a| {
        affected = switch (a) {
            .integer => |i| @intCast(@max(i, 0)),
            else => return error.Sql,
        };
    }

    var last_id: i64 = 0;
    if (obj.get("last_insert_rowid")) |lid| {
        switch (lid) {
            .string => |s| last_id = std.fmt.parseInt(i64, s, 10) catch return error.Sql,
            .integer => |i| last_id = i,
            .null => {},
            else => return error.Sql,
        }
    }

    return .{
        .cols = try cols.toOwnedSlice(allocator),
        .rows = try rows.toOwnedSlice(allocator),
        .affected_row_count = affected,
        .last_insert_rowid = last_id,
    };
}

test "build execute body has sql" {
    const gpa = std.testing.allocator;
    const body = try buildExecuteBody(gpa, null, "select 1", &.{}, &.{}, true);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "select 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"baton\":null") != null);
}

test "build execute body named args" {
    const gpa = std.testing.allocator;
    const named = [_]NamedArg{.{ .name = ":id", .value = .{ .integer = 7 } }};
    const body = try buildExecuteBody(gpa, null, "select :id", &.{}, &named, true);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "named_args") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, ":id") != null);
}

test "build batch body wraps begin commit rollback" {
    const gpa = std.testing.allocator;
    const steps = [_]batch_mod.Step{
        .{ .sql = "insert into t values (1)" },
        .{ .sql = "insert into t values (2)" },
    };
    const body = try buildBatchBody(gpa, null, &steps);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "BEGIN") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "COMMIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ROLLBACK") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"batch\"") != null);
    // ROLLBACK closes the transaction when COMMIT (step steps.len+1 = 3) did not run.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"not\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"step\":3") != null);

    // The generated body must be well-formed JSON.
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "parse batch result counts only user steps" {
    const gpa = std.testing.allocator;
    // Layout: [BEGIN, user1, user2, COMMIT, ROLLBACK(skipped)].
    const body =
        \\{"baton":"b","base_url":null,"results":[{"type":"ok","response":{"type":"batch","result":{"step_results":[{"cols":[],"rows":[],"affected_row_count":0,"last_insert_rowid":null},{"cols":[],"rows":[],"affected_row_count":1,"last_insert_rowid":10},{"cols":[],"rows":[],"affected_row_count":1,"last_insert_rowid":11},{"cols":[],"rows":[],"affected_row_count":0,"last_insert_rowid":null},null],"step_errors":[null,null,null,null,null]}}}]}
    ;
    var out = try parsePipelineResponse(gpa, body);
    defer out.deinit(gpa);
    try std.testing.expect(!out.failed);
    try std.testing.expectEqual(@as(usize, 2), out.batch_steps_run);
    try std.testing.expectEqual(@as(i64, 2), out.batch_affected);
}

test "parse rejects malformed baton" {
    const gpa = std.testing.allocator;
    const body =
        \\{"baton":123,"results":[]}
    ;
    try std.testing.expectError(error.Sql, parsePipelineResponse(gpa, body));
}

test "parse execute ok response" {
    const gpa = std.testing.allocator;
    const body =
        \\{"baton":"abc","base_url":null,"results":[{"type":"ok","response":{"type":"execute","result":{"cols":[{"name":"n","decltype":null}],"rows":[[{"type":"integer","value":"1"}]],"affected_row_count":0,"last_insert_rowid":null}}}]}
    ;
    var out = try parsePipelineResponse(gpa, body);
    defer out.deinit(gpa);
    try std.testing.expectEqualStrings("abc", out.baton.?);
    try std.testing.expect(out.stmt != null);
    try std.testing.expectEqual(@as(usize, 1), out.stmt.?.rows.len);
    try std.testing.expectEqual(@as(i64, 1), out.stmt.?.rows[0][0].integer);
}
