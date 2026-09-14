//! libSQL-only C symbols (linked when `-Dengine=libsql`).
//!
//! Do not import this module when the stock SQLite amalgamation is linked —
//! these symbols are undefined there.

const c = @import("sqlite.zig");

pub extern fn libsql_libversion() [*:0]const u8;

/// Open a database with a custom WAL manager (R3b inject prerequisite).
/// Signature matches libSQL amalgamation `libsql_open_v3`.
pub extern fn libsql_open_v3(
    filename: [*:0]const u8,
    ppDb: *?*c.sqlite3,
    flags: c_int,
    zVfs: ?[*:0]const u8,
    wal_manager: LibsqlWalManager,
) c_int;

/// Opaque manager impl (owned by WAL manager constructors).
pub const wal_manager_impl = opaque {};
pub const wal_impl = opaque {};
pub const libsql_wal = opaque {};

/// Matches amalgamation `libsql_wal_manager` (virtual WAL factory).
pub const LibsqlWalManager = extern struct {
    bUsesShm: c_int,
    xOpen: ?*const fn (
        pData: ?*wal_manager_impl,
        vfs: ?*anyopaque,
        file: ?*anyopaque,
        no_shm_mode: c_int,
        max_size: i64,
        zMainDbFileName: ?[*:0]const u8,
        out_wal: ?*libsql_wal,
    ) callconv(.c) c_int,
    xClose: ?*const fn (
        pData: ?*wal_manager_impl,
        pWal: ?*wal_impl,
        db: ?*c.sqlite3,
        sync_flags: c_int,
        nBuf: c_int,
        zBuf: ?[*]u8,
    ) callconv(.c) c_int,
    xLogDestroy: ?*const fn (
        pData: ?*wal_manager_impl,
        vfs: ?*anyopaque,
        zMainDbFileName: ?[*:0]const u8,
    ) callconv(.c) c_int,
    xLogExists: ?*const fn (
        pData: ?*wal_manager_impl,
        vfs: ?*anyopaque,
        zMainDbFileName: ?[*:0]const u8,
        exist: *c_int,
    ) callconv(.c) c_int,
    xDestroy: ?*const fn (pData: ?*wal_manager_impl) callconv(.c) void,
    pData: ?*wal_manager_impl,
};

/// Default libSQL WAL manager (no inject). Used as the delegate for InjectorWal.
pub extern const sqlite3_wal_manager: LibsqlWalManager;
