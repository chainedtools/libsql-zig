const std = @import("std");
const c = @import("c/sqlite.zig");
const err = @import("error.zig");
const value = @import("value.zig");
const rows = @import("rows.zig");
const remote = @import("backend/remote.zig");
const pipeline = @import("backend/hrana/pipeline.zig");
const batch_mod = @import("batch.zig");

pub const Statement = struct {
    kind: enum { local, remote },
    allocator: std.mem.Allocator,

    // local
    db: ?*c.sqlite3 = null,
    stmt: ?*c.sqlite3_stmt = null,
    /// Copied from Connection so step/execute fail closed after Database.sync().
    local_gen: u64 = 0,
    local_gen_src: ?*const u64 = null,

    // remote
    session: ?*remote.Session = null,
    sql: ?[]u8 = null,
    /// Positional binds. A `.text`/`.blob` entry owns its slice (allocated by
    /// this statement); replacing an index frees the previous owned slice.
    binds: std.ArrayListUnmanaged(value.Value) = .empty,
    /// Named binds. Each entry owns its `name`, and a `.text`/`.blob` value owns
    /// its slice; rebinding a name replaces in place instead of appending.
    named_binds: std.ArrayListUnmanaged(batch_mod.NamedArg) = .empty,
    result: ?pipeline.StmtResult = null,
    row_index: usize = 0,

    done: bool = false,

    pub fn deinit(self: *Statement) void {
        switch (self.kind) {
            .local => {
                if (self.stmt) |s| _ = c.sqlite3_finalize(s);
            },
            .remote => {
                if (self.result) |*r| r.deinit(self.allocator);
                if (self.sql) |s| self.allocator.free(s);
                for (self.binds.items) |v| freeOwnedValue(self.allocator, v);
                self.binds.deinit(self.allocator);
                for (self.named_binds.items) |entry| {
                    self.allocator.free(entry.name);
                    freeOwnedValue(self.allocator, entry.value);
                }
                self.named_binds.deinit(self.allocator);
            },
        }
        self.* = undefined;
    }

    /// Fail closed if the parent Database reopened (sync) or the handle is gone.
    fn requireLocalStmt(self: *const Statement) err.Error!*c.sqlite3_stmt {
        if (self.local_gen_src) |src| {
            if (src.* != self.local_gen) return error.Open;
        }
        return self.stmt orelse error.Open;
    }

    pub fn reset(self: *Statement) err.Error!void {
        switch (self.kind) {
            .local => try err.mapRc(c.sqlite3_reset(try self.requireLocalStmt())),
            .remote => {
                if (self.result) |*r| {
                    r.deinit(self.allocator);
                    self.result = null;
                }
                self.row_index = 0;
            },
        }
        self.done = false;
    }

    pub fn clearBindings(self: *Statement) err.Error!void {
        switch (self.kind) {
            .local => try err.mapRc(c.sqlite3_clear_bindings(try self.requireLocalStmt())),
            .remote => {
                for (self.binds.items) |v| freeOwnedValue(self.allocator, v);
                self.binds.clearRetainingCapacity();
                for (self.named_binds.items) |entry| {
                    self.allocator.free(entry.name);
                    freeOwnedValue(self.allocator, entry.value);
                }
                self.named_binds.clearRetainingCapacity();
            },
        }
    }

    // --- positional binds ---

    pub fn bindNull(self: *Statement, idx: usize) err.Error!void {
        switch (self.kind) {
            .local => try err.mapRc(c.sqlite3_bind_null(try self.requireLocalStmt(), @intCast(idx))),
            .remote => try self.remoteSet(idx, .{ .null = {} }),
        }
    }

    pub fn bindInt(self: *Statement, idx: usize, v: i64) err.Error!void {
        switch (self.kind) {
            .local => try err.mapRc(c.sqlite3_bind_int64(try self.requireLocalStmt(), @intCast(idx), v)),
            .remote => try self.remoteSet(idx, .{ .integer = v }),
        }
    }

    pub fn bindFloat(self: *Statement, idx: usize, v: f64) err.Error!void {
        switch (self.kind) {
            .local => try err.mapRc(c.sqlite3_bind_double(try self.requireLocalStmt(), @intCast(idx), v)),
            .remote => try self.remoteSet(idx, .{ .float = v }),
        }
    }

    pub fn bindText(self: *Statement, idx: usize, text: []const u8) err.Error!void {
        switch (self.kind) {
            .local => {
                const st = try self.requireLocalStmt();
                try err.mapRc(c.sqlite3_bind_text(
                    st,
                    @intCast(idx),
                    if (text.len == 0) "" else text.ptr,
                    @intCast(text.len),
                    c.SQLITE_TRANSIENT_DESTRUCTOR,
                ));
            },
            .remote => {
                const owned = self.allocator.dupe(u8, text) catch return error.OutOfMemory;
                // On success `binds[idx-1]` takes ownership of `owned`; on error
                // remoteSet leaves ownership with us, so free it exactly once.
                errdefer self.allocator.free(owned);
                try self.remoteSet(idx, .{ .text = owned });
            },
        }
    }

    pub fn bindBlob(self: *Statement, idx: usize, blob: []const u8) err.Error!void {
        switch (self.kind) {
            .local => {
                const st = try self.requireLocalStmt();
                // Pass a non-NULL pointer for the zero-length case so an empty
                // blob binds as an empty BLOB rather than SQL NULL (mirrors
                // bindText).
                const ptr: [*]const u8 = if (blob.len == 0) &[_]u8{} else blob.ptr;
                try err.mapRc(c.sqlite3_bind_blob(
                    st,
                    @intCast(idx),
                    ptr,
                    @intCast(blob.len),
                    c.SQLITE_TRANSIENT_DESTRUCTOR,
                ));
            },
            .remote => {
                const owned = self.allocator.dupe(u8, blob) catch return error.OutOfMemory;
                // On success `binds[idx-1]` takes ownership of `owned`; on error
                // remoteSet leaves ownership with us, so free it exactly once.
                errdefer self.allocator.free(owned);
                try self.remoteSet(idx, .{ .blob = owned });
            },
        }
    }

    pub fn bindValue(self: *Statement, idx: usize, v: value.Value) err.Error!void {
        switch (v) {
            .null => try self.bindNull(idx),
            .integer => |i| try self.bindInt(idx, i),
            .float => |f| try self.bindFloat(idx, f),
            .text => |t| try self.bindText(idx, t),
            .blob => |b| try self.bindBlob(idx, b),
        }
    }

    // --- named binds ---

    pub fn bindNamedNull(self: *Statement, name: []const u8) err.Error!void {
        try self.bindNamedValue(name, .{ .null = {} });
    }

    pub fn bindNamedInt(self: *Statement, name: []const u8, v: i64) err.Error!void {
        try self.bindNamedValue(name, .{ .integer = v });
    }

    pub fn bindNamedFloat(self: *Statement, name: []const u8, v: f64) err.Error!void {
        try self.bindNamedValue(name, .{ .float = v });
    }

    pub fn bindNamedText(self: *Statement, name: []const u8, text: []const u8) err.Error!void {
        switch (self.kind) {
            .local => {
                const idx = try self.resolveName(name);
                try self.bindText(@intCast(idx), text);
            },
            .remote => {
                const owned = self.allocator.dupe(u8, text) catch return error.OutOfMemory;
                // On success remoteNamedSet takes ownership of `owned`; on error
                // ownership stays with us, so free it exactly once.
                errdefer self.allocator.free(owned);
                try self.remoteNamedSet(name, .{ .text = owned });
            },
        }
    }

    pub fn bindNamedBlob(self: *Statement, name: []const u8, blob: []const u8) err.Error!void {
        switch (self.kind) {
            .local => {
                const idx = try self.resolveName(name);
                try self.bindBlob(@intCast(idx), blob);
            },
            .remote => {
                const owned = self.allocator.dupe(u8, blob) catch return error.OutOfMemory;
                // On success remoteNamedSet takes ownership of `owned`; on error
                // ownership stays with us, so free it exactly once.
                errdefer self.allocator.free(owned);
                try self.remoteNamedSet(name, .{ .blob = owned });
            },
        }
    }

    pub fn bindNamedValue(self: *Statement, name: []const u8, v: value.Value) err.Error!void {
        switch (self.kind) {
            .local => {
                const idx = try self.resolveName(name);
                try self.bindValue(@intCast(idx), v);
            },
            .remote => switch (v) {
                .text => |t| try self.bindNamedText(name, t),
                .blob => |b| try self.bindNamedBlob(name, b),
                else => try self.remoteNamedSet(name, v),
            },
        }
    }

    /// Resolve a parameter name to a 1-based index (local only).
    /// Tries `name` as given, then `:name`, `@name`, `$name` if no prefix.
    pub fn resolveName(self: *Statement, name: []const u8) err.Error!c_int {
        if (self.kind != .local) return error.Unsupported;
        const st = try self.requireLocalStmt();
        var buf: [256]u8 = undefined;
        if (name.len >= buf.len) return error.Bind;

        // As given
        {
            const z = self.allocator.dupeZ(u8, name) catch return error.OutOfMemory;
            defer self.allocator.free(z);
            const idx = c.sqlite3_bind_parameter_index(st, z.ptr);
            if (idx != 0) return idx;
        }

        // With common prefixes when name has none
        if (name.len > 0 and name[0] != ':' and name[0] != '@' and name[0] != '$' and name[0] != '?') {
            const prefixes = [_]u8{ ':', '@', '$' };
            for (prefixes) |p| {
                const z = std.fmt.bufPrintZ(&buf, "{c}{s}", .{ p, name }) catch return error.Bind;
                const idx = c.sqlite3_bind_parameter_index(st, z.ptr);
                if (idx != 0) return idx;
            }
        }
        return error.Bind;
    }

    /// Free the heap storage a bind value owns (text/blob); no-op otherwise.
    fn freeOwnedValue(allocator: std.mem.Allocator, v: value.Value) void {
        switch (v) {
            .text => |t| allocator.free(t),
            .blob => |b| allocator.free(b),
            else => {},
        }
    }

    fn remoteSet(self: *Statement, idx: usize, v: value.Value) err.Error!void {
        if (idx == 0) return error.Bind;
        const i = idx - 1;
        while (self.binds.items.len <= i) {
            try self.binds.append(self.allocator, .{ .null = {} });
        }
        // Replace in place: free the previous owned storage so rebinding an
        // index does not accumulate stale allocations (local replacement
        // semantics), then take ownership of the new value.
        freeOwnedValue(self.allocator, self.binds.items[i]);
        self.binds.items[i] = v;
    }

    fn remoteNamedSet(self: *Statement, name: []const u8, v: value.Value) err.Error!void {
        // Update an existing binding for this name in place: free its previous
        // owned value and reuse the already-owned name. This avoids growing the
        // list and sending duplicate named values when a statement is reused.
        for (self.named_binds.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                freeOwnedValue(self.allocator, entry.value);
                entry.value = v;
                return;
            }
        }
        const name_owned = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
        errdefer self.allocator.free(name_owned);
        try self.named_binds.append(self.allocator, .{ .name = name_owned, .value = v });
    }

    /// Bind a tuple positionally, or a non-tuple struct by field name.
    ///
    /// **Arity:** for positional (tuple) binds, the number of values must match
    /// the statement parameter count on local statements. On remote statements,
    /// tuple binds must match the densest positional index already recorded or
    /// the length of the bind list after binding (fail closed if the caller
    /// under-binds relative to the highest index used). Named (struct) binds
    /// skip local parameter-count checks; unknown names still fail on local.
    pub fn bind(self: *Statement, args: anytype) err.Error!void {
        const Args = @TypeOf(args);
        const info = @typeInfo(Args);
        switch (info) {
            .@"struct" => |s| {
                // Fail closed: for local statements the number of bind values must
                // match the statement's declared parameter count so omitted values
                // are not silently left bound to NULL.
                if (self.kind == .local and s.fields.len != try self.parameterCount()) {
                    return error.Bind;
                }
                if (s.is_tuple) {
                    // Remote: fail closed if the tuple length does not match the
                    // densest positional bind list we will send (1..N contiguous).
                    // We set binds to exactly the tuple fields; under-binding a
                    // multi-param statement is rejected when prior binds exist with
                    // a higher max index, or when a previous remote parameterCount
                    // is unknown we require consistent rebinds.
                    if (self.kind == .remote and self.binds.items.len > s.fields.len) {
                        return error.Bind;
                    }
                    inline for (s.fields, 0..) |field, i| {
                        try bindAny(self, i + 1, @field(args, field.name));
                    }
                    // After a full tuple bind, the list must be exactly the tuple
                    // length (no trailing holes from earlier higher-index binds).
                    if (self.kind == .remote and self.binds.items.len != s.fields.len) {
                        return error.Bind;
                    }
                } else {
                    inline for (s.fields) |field| {
                        try bindAnyNamed(self, field.name, @field(args, field.name));
                    }
                }
            },
            else => @compileError("bind expects a tuple or struct of bind values"),
        }
    }

    fn bindAny(self: *Statement, idx: usize, field_val: anytype) err.Error!void {
        const T = @TypeOf(field_val);
        if (T == value.Value) {
            try self.bindValue(idx, field_val);
            return;
        }
        if (T == @TypeOf(null)) {
            try self.bindNull(idx);
            return;
        }
        const ti = @typeInfo(T);
        switch (ti) {
            .null => try self.bindNull(idx),
            .optional => {
                if (field_val) |v| {
                    try bindAny(self, idx, v);
                } else {
                    try self.bindNull(idx);
                }
            },
            .int, .comptime_int => try self.bindInt(idx, @intCast(field_val)),
            .float, .comptime_float => try self.bindFloat(idx, @floatCast(field_val)),
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    try self.bindText(idx, field_val);
                    return;
                }
                if (ptr.size == .one) {
                    const child = @typeInfo(ptr.child);
                    if (child == .array and child.array.child == u8) {
                        try self.bindText(idx, field_val.*[0..]);
                        return;
                    }
                }
                @compileError("unsupported bind pointer type: " ++ @typeName(T));
            },
            .array => |arr| {
                if (arr.child == u8) {
                    try self.bindText(idx, field_val[0..]);
                    return;
                }
                @compileError("unsupported bind array type: " ++ @typeName(T));
            },
            else => @compileError("unsupported bind type: " ++ @typeName(T)),
        }
    }

    fn bindAnyNamed(self: *Statement, name: []const u8, field_val: anytype) err.Error!void {
        const T = @TypeOf(field_val);
        if (T == value.Value) {
            try self.bindNamedValue(name, field_val);
            return;
        }
        if (T == @TypeOf(null)) {
            try self.bindNamedNull(name);
            return;
        }
        const ti = @typeInfo(T);
        switch (ti) {
            .null => try self.bindNamedNull(name),
            .optional => {
                if (field_val) |v| {
                    try bindAnyNamed(self, name, v);
                } else {
                    try self.bindNamedNull(name);
                }
            },
            .int, .comptime_int => try self.bindNamedInt(name, @intCast(field_val)),
            .float, .comptime_float => try self.bindNamedFloat(name, @floatCast(field_val)),
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    try self.bindNamedText(name, field_val);
                    return;
                }
                if (ptr.size == .one) {
                    const child = @typeInfo(ptr.child);
                    if (child == .array and child.array.child == u8) {
                        try self.bindNamedText(name, field_val.*[0..]);
                        return;
                    }
                }
                @compileError("unsupported named bind pointer type: " ++ @typeName(T));
            },
            .array => |arr| {
                if (arr.child == u8) {
                    try self.bindNamedText(name, field_val[0..]);
                    return;
                }
                @compileError("unsupported named bind array type: " ++ @typeName(T));
            },
            else => @compileError("unsupported named bind type: " ++ @typeName(T)),
        }
    }

    pub fn step(self: *Statement) err.Error!?rows.Row {
        if (self.done) return null;
        switch (self.kind) {
            .local => {
                const st = try self.requireLocalStmt();
                const rc = c.sqlite3_step(st);
                switch (rc) {
                    c.SQLITE_ROW => return rows.Row{ .kind = .local, .local_stmt = st },
                    c.SQLITE_DONE => {
                        self.done = true;
                        return null;
                    },
                    else => {
                        try err.mapRc(rc);
                        return error.Sql;
                    },
                }
            },
            .remote => {
                if (self.result == null) {
                    try self.fetchRemote(true);
                }
                const res = self.result.?;
                if (self.row_index >= res.rows.len) {
                    self.done = true;
                    return null;
                }
                const row = rows.Row{
                    .kind = .remote,
                    .remote_cells = res.rows[self.row_index],
                    .remote_col_names = res.cols,
                };
                self.row_index += 1;
                return row;
            },
        }
    }

    pub fn execute(self: *Statement) err.Error!void {
        // sqlite3_step auto-resets a completed statement, so guard against
        // re-running the same DML on a second execute() call (idempotent).
        if (self.done) return;
        switch (self.kind) {
            .local => {
                const st = try self.requireLocalStmt();
                while (true) {
                    const rc = c.sqlite3_step(st);
                    switch (rc) {
                        c.SQLITE_DONE => {
                            self.done = true;
                            return;
                        },
                        c.SQLITE_ROW => {
                            // Unexpected rows for execute(): drain remaining rows, then
                            // map the terminal step code (BUSY/CONSTRAINT/etc. must not
                            // be ignored by a bare while-ROW loop).
                            var drain_rc = c.sqlite3_step(st);
                            while (drain_rc == c.SQLITE_ROW) {
                                drain_rc = c.sqlite3_step(st);
                            }
                            if (drain_rc == c.SQLITE_DONE) return error.Sql;
                            return err.mapRc(drain_rc);
                        },
                        else => return err.mapRc(rc),
                    }
                }
            },
            .remote => {
                try self.fetchRemote(false);
                self.done = true;
            },
        }
    }

    fn fetchRemote(self: *Statement, want_rows: bool) err.Error!void {
        if (self.result) |*r| {
            r.deinit(self.allocator);
            self.result = null;
        }
        const result = try self.session.?.execute(
            self.sql.?,
            self.binds.items,
            self.named_binds.items,
            want_rows,
        );
        self.result = result;
        self.row_index = 0;
    }

    pub fn parameterCount(self: *Statement) err.Error!usize {
        return switch (self.kind) {
            .local => @intCast(c.sqlite3_bind_parameter_count(try self.requireLocalStmt())),
            // Remote statements do not expose the SQL's declared parameter count;
            // the bind lists only reflect what has been bound so far, which is a
            // different quantity. Fail closed rather than return a misleading value.
            .remote => error.Unsupported,
        };
    }
};

test "remote rebind replaces without leaking or duplicating" {
    // testing.allocator fails the test on any leak or double-free, so this
    // exercises the ownership model for reused remote statements directly.
    const gpa = std.testing.allocator;
    var stmt = Statement{ .kind = .remote, .allocator = gpa };
    defer stmt.deinit();

    // Rebinding the same positional index must free the prior owned storage and
    // keep a single entry, not accumulate one allocation per bind.
    try stmt.bindText(1, "first");
    try stmt.bindBlob(1, "second-blob");
    try stmt.bindText(1, "third");
    try std.testing.expectEqual(@as(usize, 1), stmt.binds.items.len);
    try std.testing.expectEqualStrings("third", stmt.binds.items[0].text);

    // Rebinding the same name must replace in place (no duplicate NamedArg,
    // no leaked name/value copies).
    try stmt.bindNamedText("a", "x");
    try stmt.bindNamedBlob("a", "y-blob");
    try stmt.bindNamedInt("a", 7);
    try std.testing.expectEqual(@as(usize, 1), stmt.named_binds.items.len);
    try std.testing.expectEqual(@as(i64, 7), stmt.named_binds.items[0].value.integer);

    // A distinct name appends a new binding.
    try stmt.bindNamedText("b", "z");
    try std.testing.expectEqual(@as(usize, 2), stmt.named_binds.items.len);
}
