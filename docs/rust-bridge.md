# Rust bridge (Phase 4 / R1)

Optional **rusty**-built `cdylib` for classic libSQL **embedded replica sync**.

Default builds of zig-libsql do **not** require Rust, cargo, or the bridge.

## Why a bridge

The protocol spike (`docs/replica-protocol-spike.md`) showed that classic
replicas apply **4 KiB page frames** through libSQL’s custom WAL injector.
Stock SQLite amalgamation cannot do that inject. Until pure Zig wire +
libsql-sqlite3 inject (R2/R3) lands, the official `libsql` Rust client is the
correct apply path.

The bridge is a **cdylib** loaded with `std.DynLib` so libsql-sys’s amalgamation
never collides with our vendored stock SQLite at **link** time.

## Enable

```sh
# 1. Build the bridge when rusty can emit the cdylib (see limits below)
zig build bridge
# or: (cd bridge && rusty lock && rusty build)

# 2. Build / test Zig with the gate
zig build -Denable-rust-bridge=true \
  -Drust-bridge-lib=$PWD/bridge/target/.../liblibsql_bridge.so
zig build test -Denable-rust-bridge=true \
  -Drust-bridge-lib=$PWD/bridge/target/.../liblibsql_bridge.so
```

### Current tooling limits (track in rusty)

As of this R1 scaffold:

1. **rusty native graph** returns `Unsupported` for `libsql` 0.9.x (heavy
   `libsql-ffi` / cmake / bindgen build-script path). Zig API + `bridge/src`
   are ready; emitting the `.so` waits on rusty native support for that graph.
2. **rusty.json** path packages currently compile as **rlib**, not **cdylib**.
   DynLib needs a shared library. Prefer rusty growing first-class `cdylib`
   support over a cargo-only product path.

Until both land, `-Denable-rust-bridge=true` compiles the Zig loader, but
`Database.sync()` fails at runtime if the shared library is missing
(`error.Open` / `error.Sql`).

## API

```zig
var db = try libsql.Database.open(allocator, .{
    .path = "replica.db",
    .sync_url = "libsql://your-db.turso.io",
    .auth_token = token, // required; never logged
    .read_your_writes = true,
});
defer db.deinit();

const rep = try db.sync(); // close local → bridge sync → reopen local
_ = rep.frames_synced;

var conn = db.connect(); // local stock SQLite reads
```

Constraints (R1):

- `sync_url` only with a **file** path (not `:memory:` or remote-only `path`).
- `auth_token` required for replica open.
- Without `-Denable-rust-bridge`, replica open returns `error.Unsupported`.
- Do not use `connect()` handles across `sync()` (handle is closed/reopened).
- Primary **writes** are not yet forwarded through this bridge; R1 is **pull
  sync + local read**. Use Hrana remote (`path = libsql://…`) for primary SQL,
  or extend the bridge later.

## Build layout

| Path | Role |
|------|------|
| `bridge/` | rusty package (`crate-type = ["cdylib"]`) |
| `bridge/include/libsql_bridge.h` | C ABI |
| `src/backend/bridge.zig` | DynLib loader + `syncOnce` |
| `build.zig` | `-Denable-rust-bridge`, `-Drust-bridge-lib`, `zig build bridge` |

## Removal criteria

Remove `bridge/` and the DynLib path when all of the following hold:

1. Pure Zig gRPC-Web client implements `Hello` + `BatchLogEntries` + `Snapshot`.
2. Local apply uses libsql-sqlite3 (or equivalent) WAL inject with crash-safe
   `{db}-client_wal_index` semantics.
3. Parity tests against a classic primary match bridge `sync()` results.
4. ROADMAP marks pure path as the default replica implementation.

Until then this bridge remains the only supported classic-replica apply path.
