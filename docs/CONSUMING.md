# Consuming zig-libsql

How product toolchains (rusty, scripty, hasky, …) depend on this package.

## Requirements

- Zig **0.16.x**
- libc (local engine)

## Depend via release tag (production)

Prefer a **published GitHub tag** so builds are reproducible and offline after fetch:

```sh
zig fetch --save https://github.com/solvedggorg/zig-libsql/archive/refs/tags/v0.2.1.tar.gz
```

> The `v0.2.0` tarball resolves only after that release tag is published. Until then, use the [local path dep](#local-path-development-only) below and swap to the tag once it exists.

That writes `url` + content `hash` into your `build.zig.zon` under `.dependencies.zig_libsql`.

### `build.zig`

```zig
const libsql = b.dependency("zig_libsql", .{
    .target = target,
    .optimize = optimize,
});
mod.addImport("zig_libsql", libsql.module("zig_libsql"));
// Do NOT also linkSystemLibrary("sqlite3") — the module links the vendored amalgamation.
```

Wire the import on every module that `@import("zig_libsql")` (library root **and** executable / tests, as needed).

### Local engine compile (consumer cost)

The vendored amalgamation (`vendor/sqlite3.c`) is always compiled with **`-O2 -g0`**
inside a static library (`sqlite_amalg`), regardless of your package’s Zig
`optimize` mode. Zig application code still follows `-Doptimize=…`; only the C
engine is forced to optimized / no-DWARF so Debug consumers do not pay huge
debug-info costs for SQLite.

### Import

```zig
const libsql = @import("zig_libsql");

var db = try libsql.Database.open(allocator, .{ .path = db_path });
defer db.deinit();
var conn = db.connect();

try conn.exec("PRAGMA journal_mode=DELETE; CREATE TABLE IF NOT EXISTS t(...);", .{});

var stmt = try conn.prepare("SELECT x FROM t WHERE id = ?1;");
defer stmt.deinit();
try stmt.bindInt(1, 1);
while (try stmt.step()) |row| {
    // row.text is borrowed until the next step/reset/deinit — dupe if you keep it.
    const s = try row.text(0);
    _ = s;
}

// After a failed exec/prepare (local, or remote via Hrana; errors with
// Unsupported when there is no live handle/session):
// log.err("sql: {s}", .{try conn.lastErrorMessage()});

// After Database.sync() (replicas): prior Connection values are invalid,
// call db.connect() again. Local ops on a stale connection return error.Open.
```

Module name: **`zig_libsql`**. Package name in `build.zig.zon`: **`zig_libsql`**.

## Local path (development only)

```zig
// build.zig.zon — temporary while hacking both repos
.zig_libsql = .{ .path = "../zig-libsql" },
```

Do **not** ship products on path deps. Release tags are the production contract.

## Security (consumer-owned)

- Restrict file modes **before / at open** for secret stores (`0600`). Prefer a tight `umask` or pre-create the file; verify mode after open. This library does not chmod by default.
- Prefer `PRAGMA journal_mode=DELETE` for token DBs (no WAL sidecars that need separate permissioning).
- Never log auth tokens or URLs that embed secrets. `lastErrorMessage` is for SQL diagnostics only.

## API map (from system libsqlite3)

See [examples/migrate_from_sqlite3.md](../examples/migrate_from_sqlite3.md).

| Need | API |
|------|-----|
| Open file / memory | `Database.open` |
| Multi-statement DDL | `Connection.exec` |
| Bound DML / SELECT | `prepare` + `bind*` + `step` / `execute` |
| Optional bind | `bindNull` |
| Diagnostics | `lastErrorMessage` (local SQLite + remote Hrana); `lastErrorCode` (local); `Database.lastSyncError` (bridge) |
| Recoverable errors | `Busy`, `Constraint`, `Io`, `Bind`, `Column`, `OutOfMemory` — else `Sql` / `Open` / … |
| Remote Turso/libSQL | `path = "libsql://…"` + `auth_token` + `io` |
| Embedded replica sync | optional; requires `-Denable-rust-bridge` — see `docs/rust-bridge.md`. Reconnect after `sync()`. |

### Ownership (summary)

- **`Database`**: owned result — call `deinit`.
- **`Connection` from `connect()`**: borrowed view; **invalid after `sync()`** (`error.Open`); call `connect()` again.
- **`Statement`**: owned prepare — call `deinit`.
- **`Row` text/blob slices**: borrowed until next `step` / `reset` / statement `deinit` (local) or statement `deinit` (remote). Dupe if you store them.
- **Bind text/blob**: caller-owned input lifetime for local (`SQLITE_TRANSIENT` copies); remote path owns a dupe until rebind/`deinit`.

### Engine compile contracts (local)

Every local open uses the amalgamation built with:

- `SQLITE_DEFAULT_FOREIGN_KEYS=1` (FKs on by default; stock SQLite ships them off)
- `SQLITE_DQS=0` (double-quoted tokens are identifiers, never string literals)
- `SQLITE_THREADSAFE=1`, `SQLITE_OMIT_LOAD_EXTENSION`

Account for these if migrating from stock system SQLite defaults.

## Versioning

- Semver in `build.zig.zon` and `src/root.zig` (`libsql.version`) stay in sync.
- Never move a published tag. Bugfixes → `v0.2.2+`; breaking API → major/minor per policy.
- Current production pin: **v0.2.1** (package polish: single amalgamation compile, `-g0`/`-O2` C flags).
- Default package **does not** include `bridge/`; optional replica tooling is out of band.

## First consumer

**rusty** product auth (`$RUSTY_HOME/auth.db`) is the intended first integration: drop system `libsqlite3`, depend on a release tag, keep file mode and DELETE journal semantics.
