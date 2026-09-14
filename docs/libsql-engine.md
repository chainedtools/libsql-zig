# Local engine pin — SQLite vs libSQL fork

## Current pins

| Engine | Default | Location | Record |
|--------|---------|----------|--------|
| **sqlite** (default) | yes | `vendor/sqlite3.c`, `vendor/sqlite3.h` | `vendor/VERSION` — SQLite **3.49.1** |
| **libsql** | no (`-Dengine=libsql`) | `vendor/libsql/sqlite3.{c,h}` | `vendor/libsql/VERSION` — libSQL **0.2.3** bundled amalgamation |

Built by Zig C compilation (not system `libsqlite3`). Only **one** engine is linked per build (shared SQLite symbols).

### Default (`-Dengine=sqlite`)

Stock SQLite is sufficient for:

- rusty auth stores and similar local apps
- full prepare / bind / step / transaction surface
- remote Hrana (engine is on the server)

### Opt-in libSQL (`-Dengine=libsql`)

Required for classic **embedded replica WAL inject** (R3b). Virtual WAL /
`libsql_open_v3` exist only in the fork. Until pure inject is `implemented`
(`src/backend/replication/inject.zig`), replica `sync()` still fails closed
unless the rusty bridge is enabled.

```sh
zig build -Dengine=libsql
zig build test -Dengine=libsql
```

Feature detection:

```zig
const libsql = @import("zig_libsql");
_ = libsql.engine;           // .sqlite | .libsql
_ = libsql.engineVersion();  // sqlite3_libversion()
_ = libsql.libsqlVersion();  // non-null only when engine == .libsql
_ = libsql.pure_inject_available();
```

## Policy

1. **Default remains stock SQLite** for 0.2.x consumers and general local SQL.
2. Any engine bump is intentional: update the matching `VERSION`, checksums, ROADMAP.
3. Do not claim “libSQL extensions locally” while still on stock SQLite.
4. Do not claim pure classic inject until `inject.implemented` is true.
5. System `libsqlite3` stays a non-goal for the default module.

## R3b status

| Step | Status |
|------|--------|
| Vendor libsql amalgamation + `-Dengine=libsql` | **done** (R3b.0) |
| InjectorWal / `libsql_open_v3` apply port | next |
| Pure `Database.sync` apply + meta advance | wired; apply fails closed until inject lands |
| Parity vs rusty bridge | after inject |
