//! Minimal SQLite C bindings for the local backend.
//! Prefer explicit `extern` over `@cImport` so we only depend on the surface we use.
//! Linked object comes from the selected amalgamation (`-Dengine=sqlite|libsql`),
//! not system libsqlite3.

const std = @import("std");
const build_options = @import("build_options");

/// Which amalgamation was compiled into this module.
pub const Engine = enum { sqlite, libsql };

pub const engine: Engine = switch (build_options.engine) {
    .sqlite => .sqlite,
    .libsql => .libsql,
};

pub const engine_is_libsql = engine == .libsql;

pub const SQLITE_OK: c_int = 0;
pub const SQLITE_ERROR: c_int = 1;
pub const SQLITE_INTERNAL: c_int = 2;
pub const SQLITE_PERM: c_int = 3;
pub const SQLITE_ABORT: c_int = 4;
pub const SQLITE_BUSY: c_int = 5;
pub const SQLITE_LOCKED: c_int = 6;
pub const SQLITE_NOMEM: c_int = 7;
pub const SQLITE_READONLY: c_int = 8;
pub const SQLITE_INTERRUPT: c_int = 9;
pub const SQLITE_IOERR: c_int = 10;
pub const SQLITE_CORRUPT: c_int = 11;
pub const SQLITE_NOTFOUND: c_int = 12;
pub const SQLITE_FULL: c_int = 13;
pub const SQLITE_CANTOPEN: c_int = 14;
pub const SQLITE_PROTOCOL: c_int = 15;
pub const SQLITE_EMPTY: c_int = 16;
pub const SQLITE_SCHEMA: c_int = 17;
pub const SQLITE_TOOBIG: c_int = 18;
pub const SQLITE_CONSTRAINT: c_int = 19;
pub const SQLITE_MISMATCH: c_int = 20;
pub const SQLITE_MISUSE: c_int = 21;
pub const SQLITE_NOLFS: c_int = 22;
pub const SQLITE_AUTH: c_int = 23;
pub const SQLITE_FORMAT: c_int = 24;
pub const SQLITE_RANGE: c_int = 25;
pub const SQLITE_NOTADB: c_int = 26;
pub const SQLITE_NOTICE: c_int = 27;
pub const SQLITE_WARNING: c_int = 28;
pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_DONE: c_int = 101;

pub const SQLITE_INTEGER: c_int = 1;
pub const SQLITE_FLOAT: c_int = 2;
pub const SQLITE_TEXT: c_int = 3;
pub const SQLITE_BLOB: c_int = 4;
pub const SQLITE_NULL: c_int = 5;

pub const SQLITE_OPEN_READONLY: c_int = 0x00000001;
pub const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
pub const SQLITE_OPEN_CREATE: c_int = 0x00000004;
pub const SQLITE_OPEN_URI: c_int = 0x00000040;
pub const SQLITE_OPEN_MEMORY: c_int = 0x00000080;
pub const SQLITE_OPEN_NOMUTEX: c_int = 0x00008000;
pub const SQLITE_OPEN_FULLMUTEX: c_int = 0x00010000;

/// Request SQLite to make its own copy of bind data (destructor = transient).
pub const SQLITE_TRANSIENT: isize = -1;
pub const SQLITE_STATIC: isize = 0;

// SQLite treats these sentinel destructor arguments by their pointer-sized bit
// pattern (-1 / 0), so a change to either value would silently produce a bad
// destructor pointer. Fail at compile time instead.
comptime {
    if (SQLITE_TRANSIENT != -1) @compileError("SQLITE_TRANSIENT must be -1");
    if (SQLITE_STATIC != 0) @compileError("SQLITE_STATIC must be 0");
}

/// Build a `sqlite3_bind_*` destructor pointer from a sentinel value. Routing
/// both constants through one cast avoids open-coding `@ptrFromInt` per site.
fn destructorPtr(sentinel: isize) ?*const anyopaque {
    return @ptrFromInt(@as(usize, @bitCast(sentinel)));
}

/// `sqlite3_bind_*` destructor argument: SQLite copies the buffer immediately.
/// Prefer this over open-coding `@ptrFromInt` at every bind site.
pub const SQLITE_TRANSIENT_DESTRUCTOR: ?*const anyopaque = destructorPtr(SQLITE_TRANSIENT);
/// Caller guarantees the buffer lives until clear/reset/finalize.
pub const SQLITE_STATIC_DESTRUCTOR: ?*const anyopaque = destructorPtr(SQLITE_STATIC);

pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

pub const ExecCallback = *const fn (
    arg: ?*anyopaque,
    ncols: c_int,
    values: ?[*]?[*:0]u8,
    names: ?[*]?[*:0]u8,
) callconv(.c) c_int;

pub extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
pub extern fn sqlite3_open_v2(
    filename: [*:0]const u8,
    ppDb: *?*sqlite3,
    flags: c_int,
    zVfs: ?[*:0]const u8,
) c_int;
pub extern fn sqlite3_close(db: ?*sqlite3) c_int;
pub extern fn sqlite3_close_v2(db: ?*sqlite3) c_int;
pub extern fn sqlite3_exec(
    db: ?*sqlite3,
    sql: [*:0]const u8,
    callback: ?ExecCallback,
    arg: ?*anyopaque,
    errmsg: *?[*:0]u8,
) c_int;
pub extern fn sqlite3_free(p: ?*anyopaque) void;
pub extern fn sqlite3_errmsg(db: ?*sqlite3) [*:0]const u8;
pub extern fn sqlite3_errstr(rc: c_int) [*:0]const u8;
pub extern fn sqlite3_extended_errcode(db: ?*sqlite3) c_int;
pub extern fn sqlite3_prepare_v2(
    db: ?*sqlite3,
    zSql: [*]const u8,
    nByte: c_int,
    ppStmt: *?*sqlite3_stmt,
    pzTail: ?*?[*]const u8,
) c_int;
pub extern fn sqlite3_bind_text(
    stmt: ?*sqlite3_stmt,
    idx: c_int,
    text: ?[*]const u8,
    n: c_int,
    destructor: ?*const anyopaque,
) c_int;
pub extern fn sqlite3_bind_blob(
    stmt: ?*sqlite3_stmt,
    idx: c_int,
    value: ?[*]const u8,
    n: c_int,
    destructor: ?*const anyopaque,
) c_int;
pub extern fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, idx: c_int, value: i64) c_int;
pub extern fn sqlite3_bind_double(stmt: ?*sqlite3_stmt, idx: c_int, value: f64) c_int;
pub extern fn sqlite3_bind_null(stmt: ?*sqlite3_stmt, idx: c_int) c_int;
pub extern fn sqlite3_bind_parameter_count(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_bind_parameter_index(stmt: ?*sqlite3_stmt, zName: [*:0]const u8) c_int;
pub extern fn sqlite3_bind_parameter_name(stmt: ?*sqlite3_stmt, i: c_int) ?[*:0]const u8;
pub extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_column_count(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_column_name(stmt: ?*sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
pub extern fn sqlite3_column_type(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;
pub extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
pub extern fn sqlite3_column_blob(stmt: ?*sqlite3_stmt, iCol: c_int) ?[*]const u8;
pub extern fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;
pub extern fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, iCol: c_int) i64;
pub extern fn sqlite3_column_double(stmt: ?*sqlite3_stmt, iCol: c_int) f64;
pub extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_reset(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_clear_bindings(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_changes(db: ?*sqlite3) c_int;
pub extern fn sqlite3_last_insert_rowid(db: ?*sqlite3) i64;
pub extern fn sqlite3_libversion() [*:0]const u8;

/// libSQL package version string when `-Dengine=libsql`; null for stock SQLite.
pub fn libsqlVersion() ?[]const u8 {
    if (comptime !engine_is_libsql) return null;
    const extra = @import("libsql_extra.zig");
    return std.mem.span(extra.libsql_libversion());
}
