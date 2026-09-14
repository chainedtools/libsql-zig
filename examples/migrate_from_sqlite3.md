# Migrating from system libsqlite3 (rusty sketch)

## Today (rusty)

```zig
// build.zig
mod.linkSystemLibrary("sqlite3", .{});
mod.link_libc = true;

// src/auth/c.zig — hand-rolled extern
// src/auth/store.zig — c.sqlite3_open / prepare / bind / step
```

## Target

Production: fetch a **release tag** (not a monorepo path). See [docs/CONSUMING.md](../docs/CONSUMING.md).

```sh
zig fetch --save https://github.com/solvedggorg/zig-libsql/archive/refs/tags/v0.2.0.tar.gz
```

> Resolves once `v0.2.0` is tagged; use the local path dep below for pre-release development.

```zig
// build.zig
const libsql = b.dependency("zig_libsql", .{
    .target = target,
    .optimize = optimize,
});
mod.addImport("zig_libsql", libsql.module("zig_libsql"));
// drop linkSystemLibrary("sqlite3")
```

Local hack only: `.zig_libsql = .{ .path = "../zig-libsql" }` in `build.zig.zon`.

```zig
// store.zig
const libsql = @import("zig_libsql");

var db = try libsql.Database.open(allocator, .{ .path = db_path });
defer db.deinit();
var conn = db.connect();

try conn.exec(
    \\PRAGMA journal_mode=DELETE;
    \\CREATE TABLE IF NOT EXISTS session ( ... );
, .{});

var stmt = try conn.prepare(
    \\INSERT INTO session(...) VALUES(?1, ?2, ...)
    \\ON CONFLICT(id) DO UPDATE SET ...;
);
defer stmt.deinit();
try stmt.bindText(1, session.clerk_user_id);
// optional: try stmt.bindNull(2);
// ...
try stmt.execute();
// on failure (local): conn.lastErrorMessage()
```

## Security still on the consumer

- Restrict permissions *before* opening a new auth DB: set a tight `umask`
  (e.g. `0o077`) or pre-create the file `0600`, then verify the resulting mode
  after `Database.open`. Don't rely solely on a post-open `chmod` — that leaves
  a window where the freshly created DB is readable under the process umask. The
  library does not chmod consumer-owned files by default.
- Prefer `PRAGMA journal_mode=DELETE` for token stores (no WAL sidecars).
- Never log tokens.

## API mapping

| sqlite3 C | zig_libsql |
|-----------|------------|
| `sqlite3_open` | `Database.open` / `open` |
| `sqlite3_exec` | `Connection.exec` |
| `sqlite3_prepare_v2` | `Connection.prepare` |
| `sqlite3_bind_*` | `Statement.bindInt/Text/...` or `bind(.{...})` |
| `sqlite3_step` ROW/DONE | `Statement.step` → `?Row` |
| `sqlite3_column_*` | `Row.int/text/blob/...` |
| `sqlite3_finalize` | `Statement.deinit` |
| `sqlite3_close` | `Database.deinit` |
| `sqlite3_errmsg` | `Connection.lastErrorMessage` |
| `sqlite3_extended_errcode` | `Connection.lastErrorCode` |
