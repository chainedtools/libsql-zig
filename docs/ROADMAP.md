# ROADMAP

## One-liner

**zig-libsql** is a pure(as)-Zig libSQL adapter: Zig API, Zig-compiled local
engine, pure Zig remote (Hrana) — not a cargo wrapper.

## Status matrix

| Capability | Status | Notes |
|------------|--------|-------|
| Local file DB | **MVP** | Vendored SQLite 3.49.1 amalgamation |
| In-memory DB | **MVP** | `:memory:` |
| Prepare / bind / step | **MVP** | Positional + **named** binds |
| Transactions | **MVP** | begin / commit / rollback |
| Batch | **MVP** | Phase 3 — local txn + remote Hrana batch |
| Remote Hrana HTTP | **MVP** | Phase 2 — JSON `v3/pipeline` |
| Hrana WebSocket | later | |
| Embedded replicas | design + spike + R1 + R2.1 + R3a + **R3b.0** | Protocol + pull/Snapshot; libsql engine pin; inject not yet (`docs/libsql-engine.md`) |
| libSQL SQL extensions | deferred | Default stock SQLite; opt-in `-Dengine=libsql` for inject |
| System libsqlite3 backend | non-goal | Debug-only option only if ever added |
| Rust C FFI default | non-goal | Optional bridge only (Phase 4) |

## Phases

### Phase 0 — Identity ✅

README, AGENTS, ROADMAP, package scaffold.

### Phase 1 — Local adapter ✅

- Vendor amalgamation, Zig `extern` surface, idiomatic API
- Tests + demo CLI
- rusty migration sketch

### Phase 2 — Remote ✅

- URI: `libsql://`, `https://`, `http://` (+ `ws`/`wss` mapped to HTTP)
- Auth token in `OpenOptions.auth_token` (never logged); `OpenOptions.io` required
- Hrana over HTTP JSON (`POST …/v3/pipeline`) with baton stream state
- Same public `Connection` / `Statement` / `Row` surface (materialized rows)
- Live smoke test gated on `LIBSQL_URL` / `LIBSQL_AUTH_TOKEN`

### Phase 3 — Completeness (current)

- [x] Named parameters (local SQLite + remote `named_args`)
- [x] `Connection.batch` (local transaction; remote Hrana batch + BEGIN/COMMIT)
- [x] Embedded replica **design** (`docs/embedded-replicas.md`)
- [x] Engine pin policy (`docs/libsql-engine.md`) — keep SQLite until fork needed
- [x] Replica **protocol spike** (`docs/replica-protocol-spike.md`) — classic
  gRPC-Web page frames; apply needs libSQL WAL inject (not stock SQLite)
- [x] Production consumer prep — `lastErrorMessage`/`lastErrorCode`, auth-store
  contract test, `docs/CONSUMING.md`, CI; first release track `v0.2.0`
- [ ] Replica **implementation** — next slices:
  1. **R1 (scaffold):** Phase 4 rusty bridge — required for libSQL WAL
     injection unavailable in stock SQLite; see `docs/rust-bridge.md`
     (`OpenOptions.sync_url` + `Database.sync()`, gated; blocked on rusty/libsql build)
  2. **R2 ✅:** pure Zig wire codecs — `src/backend/replication/`
     (frame header, wal_log protobuf, client_wal_index meta)
  3. **R2.1 ✅:** gRPC-Web unary pull — framing + HTTPS `Hello` /
     `BatchLogEntries` + meta load/save (`docs/replica-wire-r2.md`);
     **no** public pure `Database.sync` / inject
  4. **R3a ✅:** streaming `Snapshot` + `error.NeedSnapshot` recovery in
     `pullUntilCaughtUp` (still no inject / public pure sync)
  5. **R3b (0.3 workstream — in progress):**
     - **R3b.0 ✅:** vendor libSQL amalgamation + `-Dengine=sqlite|libsql`,
       `inject.zig` scaffold, pure `sync()` path that fails closed until
       inject is implemented (`docs/libsql-engine.md`)
     - **R3b.1 (next):** InjectorWal / `libsql_open_v3` apply port
     - **R3b.2:** wire pull → inject → meta; flip `inject.implemented`;
       pure public `Database.sync` without rusty bridge
     - **R3b.3:** parity tests vs classic primary / bridge

### Phase 4 — Optional Rust interop

R1 classic replica sync uses a **rusty-built cdylib** (not cargo product path):

```sh
rusty init libsql_bridge -lib -y    # bootstrap the bridge package (once)
zig build bridge                    # rusty build in bridge/
zig build -Denable-rust-bridge=true
```

See `docs/rust-bridge.md` and `bridge/README.md`. Removal criteria: pure Zig
wire+inject parity (R2/R3).

## Non-goals

- Pure Zig rewrite of the SQLite VM as v1
- Cargo as the default build
- Full Turso Cloud feature marketing claims before implementation
- Shipping `libsql-server` from this package

## First consumer / release track

| Step | Status |
|------|--------|
| Production-harden local API + auth contract tests | ✅ |
| Tag **`v0.2.0`** + GitHub Release | ✅ https://github.com/solvedggorg/zig-libsql/releases/tag/v0.2.0 |
| rusty `zig fetch --save` tag tarball | ✅ (PR) |
| Migrate rusty `auth.db` off system `libsqlite3` | ✅ (PR https://github.com/solvedggorg/rusty/pull/22) |
| Package-ready polish (**v0.2.1**) | amalgamation `-O2 -g0`, single `sqlite_amalg` static lib, consumer CI smoke |

Consumer guide: `docs/CONSUMING.md`. Replica R3b / rusty bridge stay **0.3.x**
(package version remains **0.2.1** until pure inject ships; R3b.0 is foundation only).
