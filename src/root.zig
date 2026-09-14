//! zig-libsql — pure(as)-Zig libSQL / SQLite adapter.
//!
//! Local engine: vendored amalgamation compiled by Zig (`-Dengine=sqlite|libsql`).
//! Remote (Hrana HTTP): Phase 2.
//! Named params + batch: Phase 3 — see docs/ROADMAP.md.
//! Optional rusty bridge for classic embedded replica sync (Phase 4 / R1):
//! `-Denable-rust-bridge=true` — see docs/rust-bridge.md.
//! Pure Zig replica wire + pull/Snapshot (R2/R2.1/R3a); inject (R3b) when
//! `-Dengine=libsql` and inject is implemented — see docs/ROADMAP.md.
//!
//! ## Ownership contracts
//!
//! | Type | Who frees / lifetime |
//! |------|----------------------|
//! | `Database` | Caller: `deinit` frees path, session, handles, sync error |
//! | `Connection` from `connect()` | Borrowed; invalid after `Database.deinit` / after `sync()` |
//! | `Connection` from `open()` | Owns local handle when `owns_db` |
//! | `Statement` | Caller: `deinit` finalizes / frees remote SQL + binds |
//! | `Row` text/blob | Borrowed until next step/reset/deinit (local) or statement deinit (remote) |
//! | `Value` text/blob on bind | Caller lifetime for input; remote path dupes into owned storage |

const std = @import("std");
const c = @import("c/sqlite.zig");

pub const version = "0.2.1";

pub const Error = @import("error.zig").Error;
pub const Value = @import("value.zig").Value;
pub const Database = @import("database.zig").Database;
pub const OpenOptions = @import("database.zig").OpenOptions;
pub const SyncResult = @import("database.zig").SyncResult;
pub const open = @import("database.zig").open;
pub const Connection = @import("connection.zig").Connection;
pub const Statement = @import("statement.zig").Statement;
pub const Row = @import("rows.zig").Row;
pub const BatchStep = @import("batch.zig").Step;
pub const BatchResult = @import("batch.zig").Result;
pub const NamedArg = @import("batch.zig").NamedArg;
pub const rust_bridge_enabled = @import("backend/bridge.zig").isCompileEnabled;

/// Linked local amalgamation kind (`sqlite` default, `libsql` for R3b inject).
pub const Engine = c.Engine;
pub const engine = c.engine;
pub const pure_inject_available = @import("backend/replication/inject.zig").available;

/// SQLite fundamental datatype codes as returned by `Row.columnType`.
pub const column_type = struct {
    pub const integer: c_int = c.SQLITE_INTEGER;
    pub const float: c_int = c.SQLITE_FLOAT;
    pub const text: c_int = c.SQLITE_TEXT;
    pub const blob: c_int = c.SQLITE_BLOB;
    pub const @"null": c_int = c.SQLITE_NULL;
};

/// SQLite amalgamation version string from the linked engine.
pub fn engineVersion() []const u8 {
    return std.mem.span(c.sqlite3_libversion());
}

/// libSQL package version when `-Dengine=libsql`; null for stock SQLite.
pub fn libsqlVersion() ?[]const u8 {
    return c.libsqlVersion();
}
