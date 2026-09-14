const std = @import("std");
const c = @import("c/sqlite.zig");

/// Library-wide error set. Prefer typed variants for recovery; use
/// `Connection.lastErrorMessage` / `lastErrorCode` for detail.
pub const Error = error{
    /// Failed to open the database file or memory handle, or a local
    /// connection was invalidated (e.g. after `Database.sync()`).
    Open,
    /// SQL execution failed (exec / step / prepare) when no more specific
    /// variant applies.
    Sql,
    /// Parameter index out of range, bind arity mismatch, or type mismatch.
    Bind,
    /// Column index out of range on a row getter.
    Column,
    /// Requested backend is not available yet (e.g. remote Hrana).
    Unsupported,
    /// Invalid path / URI / auth header / open options for the backend.
    InvalidPath,
    /// Classic replica: primary requires a Snapshot RPC before incremental log pull.
    NeedSnapshot,
    /// Database is locked or busy (`SQLITE_BUSY` / `SQLITE_LOCKED`).
    Busy,
    /// Constraint violation (`SQLITE_CONSTRAINT`).
    Constraint,
    /// I/O or storage failure at runtime (`SQLITE_IOERR` / `FULL` / `CANTOPEN` / `READONLY` / `CORRUPT` / `NOTADB` / `PERM`).
    Io,
    OutOfMemory,
};

/// Map a SQLite result code to a library error when non-OK.
///
/// `mapRc` is used on statement-time paths (bind/reset/step) and multi-statement
/// exec. Database.open maps its own open-time codes to `Open`. Codes that look
/// like open failures (`CANTOPEN`, `PERM`, …) seen here are runtime SQL/IO
/// failures and map to `Io` rather than `Open`.
pub fn mapRc(rc: c_int) Error!void {
    if (rc == c.SQLITE_OK or rc == c.SQLITE_ROW or rc == c.SQLITE_DONE) return;
    // Primary codes only (low 8 bits); extended codes share the same primary.
    const primary = rc & 0xff;
    return switch (primary) {
        c.SQLITE_NOMEM => error.OutOfMemory,
        c.SQLITE_RANGE => error.Bind,
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.Busy,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_IOERR,
        c.SQLITE_FULL,
        c.SQLITE_CANTOPEN,
        c.SQLITE_READONLY,
        c.SQLITE_CORRUPT,
        c.SQLITE_NOTADB,
        c.SQLITE_PERM,
        c.SQLITE_NOLFS,
        => error.Io,
        else => error.Sql,
    };
}

pub fn errmsg(db: ?*c.sqlite3) []const u8 {
    if (db) |d| return std.mem.span(c.sqlite3_errmsg(d));
    return "unknown sqlite error";
}

pub fn errstr(rc: c_int) []const u8 {
    return std.mem.span(c.sqlite3_errstr(rc));
}

test "mapRc classifies busy constraint and io" {
    try mapRc(c.SQLITE_OK);
    try std.testing.expectError(error.Busy, mapRc(c.SQLITE_BUSY));
    try std.testing.expectError(error.Busy, mapRc(c.SQLITE_LOCKED));
    try std.testing.expectError(error.Constraint, mapRc(c.SQLITE_CONSTRAINT));
    try std.testing.expectError(error.Io, mapRc(c.SQLITE_IOERR));
    try std.testing.expectError(error.Io, mapRc(c.SQLITE_FULL));
    try std.testing.expectError(error.OutOfMemory, mapRc(c.SQLITE_NOMEM));
    try std.testing.expectError(error.Bind, mapRc(c.SQLITE_RANGE));
    try std.testing.expectError(error.Sql, mapRc(c.SQLITE_ERROR));
}
