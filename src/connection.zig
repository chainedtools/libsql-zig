const std = @import("std");
const c = @import("c/sqlite.zig");
const err = @import("error.zig");
const value = @import("value.zig");
const Statement = @import("statement.zig").Statement;
const remote = @import("backend/remote.zig");
const batch_mod = @import("batch.zig");

pub const BatchStep = batch_mod.Step;
pub const BatchResult = batch_mod.Result;
pub const NamedArg = batch_mod.NamedArg;

/// SQL session over a local or remote database handle.
///
/// **Ownership:**
/// - From `Database.connect`: non-owning view. Invalid after `Database.deinit`
///   and after `Database.sync()` (generation mismatch → `error.Open`).
/// - From convenience `open()`: owns the local handle when `owns_db` is true.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    kind: enum { local, remote },
    // local
    db: ?*c.sqlite3 = null,
    owns_db: bool = false,
    /// Snapshot of `Database.conn_gen` when this connection was created.
    /// Compared to `local_gen_src` so ops fail closed after `sync()` reopens.
    local_gen: u64 = 0,
    /// Points at `Database.conn_gen` for non-owning local connections; null for
    /// owning convenience opens (no parent Database).
    local_gen_src: ?*const u64 = null,
    // remote (pointer into Database-owned Session)
    session: ?*remote.Session = null,

    pub fn deinit(self: *Connection) void {
        if (self.kind == .local and self.owns_db) {
            if (self.db) |db| _ = c.sqlite3_close_v2(db);
        }
        self.* = undefined;
    }

    /// Resolve a live local SQLite handle, or `error.Open` if the connection is
    /// dead (null handle, or invalidated by `Database.sync()`).
    fn requireLocalDb(self: *const Connection) err.Error!*c.sqlite3 {
        if (self.local_gen_src) |src| {
            if (src.* != self.local_gen) return error.Open;
        }
        return self.db orelse error.Open;
    }

    /// Execute one or more SQL statements with no result rows expected.
    /// `args` is reserved; pass `{}`.
    pub fn exec(self: *Connection, sql: []const u8, args: anytype) err.Error!void {
        _ = args;
        switch (self.kind) {
            .local => {
                const db = try self.requireLocalDb();
                const zsql = self.allocator.dupeZ(u8, sql) catch return error.OutOfMemory;
                defer self.allocator.free(zsql);

                var errmsg_c: ?[*:0]u8 = null;
                const rc = c.sqlite3_exec(db, zsql.ptr, null, null, &errmsg_c);
                if (rc != c.SQLITE_OK) {
                    if (errmsg_c) |e| c.sqlite3_free(e);
                    try err.mapRc(rc);
                    return error.Sql;
                }
            },
            .remote => try self.session.?.sequence(sql),
        }
    }

    pub fn prepare(self: *Connection, sql: []const u8) err.Error!Statement {
        switch (self.kind) {
            .local => {
                const db = try self.requireLocalDb();
                var stmt: ?*c.sqlite3_stmt = null;
                var tail: ?[*]const u8 = null;
                const rc = c.sqlite3_prepare_v2(
                    db,
                    sql.ptr,
                    @intCast(sql.len),
                    &stmt,
                    &tail,
                );
                if (rc != c.SQLITE_OK or stmt == null) {
                    if (stmt) |s| _ = c.sqlite3_finalize(s);
                    if (rc != c.SQLITE_OK) {
                        try err.mapRc(rc);
                    }
                    return error.Sql;
                }
                // Fail closed on multi-statement input: prepare only compiles the
                // first statement, so a non-empty tail would silently drop the
                // rest. Callers that need to run scripts should use `exec`.
                if (tail) |t| {
                    const consumed = @intFromPtr(t) - @intFromPtr(sql.ptr);
                    const rest = std.mem.trim(u8, sql[consumed..], " \t\r\n;");
                    if (rest.len != 0) {
                        _ = c.sqlite3_finalize(stmt.?);
                        return error.Sql;
                    }
                }
                return .{
                    .kind = .local,
                    .allocator = self.allocator,
                    .db = db,
                    .stmt = stmt.?,
                    .local_gen = self.local_gen,
                    .local_gen_src = self.local_gen_src,
                };
            },
            .remote => {
                const sql_owned = self.allocator.dupe(u8, sql) catch return error.OutOfMemory;
                return .{
                    .kind = .remote,
                    .allocator = self.allocator,
                    .session = self.session,
                    .sql = sql_owned,
                };
            },
        }
    }

    /// Prepare, optional bind tuple/struct, execute to completion, finalize.
    /// Pass `.{}` when there are no bind parameters.
    /// Tuples bind positionally; structs bind by field name.
    pub fn execute(self: *Connection, sql: []const u8, bind_args: anytype) err.Error!void {
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        // Bind unconditionally so empty args and invalid shapes are validated
        // against the statement's parameter count (fail closed).
        try stmt.bind(bind_args);
        try stmt.execute();
    }

    /// Run multiple statements as a batch.
    ///
    /// - **local:** `BEGIN` → each step prepare/bind/execute → `COMMIT` (rollback on error)
    /// - **remote:** Hrana `batch` with BEGIN/COMMIT and ok-conditions
    pub fn batch(self: *Connection, steps: []const batch_mod.Step) err.Error!batch_mod.Result {
        if (steps.len == 0) return .{};

        switch (self.kind) {
            .local => {
                try self.begin();
                const total_affected = self.runLocalSteps(steps) catch |e| {
                    // Surface a rollback failure rather than swallowing it: if the
                    // rollback itself fails the connection is in an unknown state,
                    // and the caller must know. Otherwise report the original error.
                    self.rollback() catch |re| return re;
                    return e;
                };
                return .{
                    .steps_run = steps.len,
                    .total_affected = total_affected,
                };
            },
            .remote => return try self.session.?.batch(steps),
        }
    }

    /// Execute each batch step and COMMIT, returning the total affected rows.
    /// On any error the transaction is left open for the caller to roll back.
    fn runLocalSteps(self: *Connection, steps: []const batch_mod.Step) err.Error!i64 {
        var total_affected: i64 = 0;
        for (steps) |step| {
            var stmt = try self.prepare(step.sql);
            defer stmt.deinit();
            for (step.args, 0..) |a, i| {
                try stmt.bindValue(i + 1, a);
            }
            for (step.named_args) |na| {
                try stmt.bindNamedValue(na.name, na.value);
            }
            try stmt.execute();
            total_affected += self.changes();
        }
        try self.commit();
        return total_affected;
    }

    pub fn begin(self: *Connection) err.Error!void {
        try self.exec("BEGIN;", .{});
    }

    pub fn commit(self: *Connection) err.Error!void {
        try self.exec("COMMIT;", .{});
    }

    pub fn rollback(self: *Connection) err.Error!void {
        try self.exec("ROLLBACK;", .{});
    }

    pub fn changes(self: *Connection) i64 {
        return switch (self.kind) {
            .local => {
                const db = self.requireLocalDb() catch return 0;
                return c.sqlite3_changes(db);
            },
            .remote => self.session.?.last_affected,
        };
    }

    pub fn lastInsertRowid(self: *Connection) i64 {
        return switch (self.kind) {
            .local => {
                const db = self.requireLocalDb() catch return 0;
                return c.sqlite3_last_insert_rowid(db);
            },
            .remote => self.session.?.last_insert_rowid,
        };
    }

    /// Last error message for this connection.
    ///
    /// - **local:** SQLite `sqlite3_errmsg`. Not owned; valid until the next
    ///   SQL operation on the handle. After a failed `exec`/`prepare`, prefer
    ///   this over discarded per-call errmsg pointers: the handle still carries
    ///   the message. Fails closed with `error.Unsupported` when the handle is
    ///   dead/null (e.g. invalidated by `Database.sync()`) rather than
    ///   returning an empty string callers could mistake for "no error".
    /// - **remote:** last Hrana/server message stored on the session (owned by
    ///   the session; valid until the next remote op or session deinit). Fails
    ///   closed with `error.Unsupported` when there is no session.
    pub fn lastErrorMessage(self: *const Connection) err.Error![]const u8 {
        return switch (self.kind) {
            .local => {
                const db = self.requireLocalDb() catch return error.Unsupported;
                return err.errmsg(db);
            },
            .remote => {
                const s = self.session orelse return error.Unsupported;
                return s.lastErrorMessage();
            },
        };
    }

    /// Last extended SQLite error code for this connection (local only).
    ///
    /// Remote connections fail closed with `error.Unsupported`: `0` would be
    /// indistinguishable from `SQLITE_OK` (success). A dead/null local handle
    /// (e.g. invalidated by `Database.sync()`) fails closed the same way.
    pub fn lastErrorCode(self: *const Connection) err.Error!c_int {
        return switch (self.kind) {
            .local => {
                const db = self.requireLocalDb() catch return error.Unsupported;
                return c.sqlite3_extended_errcode(db);
            },
            .remote => error.Unsupported,
        };
    }
};
