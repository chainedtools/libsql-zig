# libsql_bridge (Phase 4 / R1)

Optional **rusty**-built `cdylib` that wraps the official `libsql` Rust client for
classic **embedded replica sync** (`new_remote_replica` + `sync()`).

zig-libsql loads this library **at runtime** when built with
`-Denable-rust-bridge=true`, so the libsql-sys amalgamation never collides with
the package’s vendored stock SQLite at link time.

## Build (rusty only)

```sh
cd bridge
rusty lock
rusty build
# desired artifact: liblibsql_bridge.so (cdylib)
```

Or from the package root: `zig build bridge`.

**Note:** rusty’s native builder currently reports `Unsupported` for the
`libsql` crate graph (ffi/cmake). This package is scaffolded for that path;
see `docs/rust-bridge.md` tooling limits.

## C ABI

See `include/libsql_bridge.h`:

- `zig_libsql_bridge_sync_once` — open replica, sync, close
- `zig_libsql_bridge_version` — bridge version string

## Removal criteria

Remove this crate when **pure Zig** gRPC-Web frame transport + libsql-sqlite3
WAL inject (R2/R3 in `docs/replica-protocol-spike.md`) is implemented and
passes parity tests against the same primary.

Until then this bridge is the only correct classic-replica apply path.
