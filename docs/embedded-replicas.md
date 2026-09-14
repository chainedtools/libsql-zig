# Embedded replicas — design (Phase 3)

## Goal

Let Zig consumers open a **local** database file that stays in sync with a
**remote** libSQL primary (Turso Cloud or self-hosted), with optional write
forwarding to the primary.

This is a design note for a later implementation slice. Phase 3 ships named
params + batch; replica *code* is not required to exit Phase 3.

**Protocol spike (complete):** classic libSQL page-frame replication over
gRPC-Web — see [`docs/replica-protocol-spike.md`](replica-protocol-spike.md).
Key finding: transport is reimplementable in pure Zig; **apply requires
libSQL WAL injection** (not stock SQLite). Near-term MVP is Phase 4 rusty
bridge; long-term is libsql engine pin + pure Zig wire/inject.

## Background

libSQL embedded replicas typically:

1. Keep a local SQLite-compatible file (WAL-aware).
2. Periodically (or on demand) **sync** frames / pages from the primary over
   Hrana or a dedicated sync protocol.
3. Serve reads from local storage for low latency.
4. Route writes either to local-then-sync or directly to the primary
   (“read your writes” policies vary).

Official clients often use the **Rust** libSQL core for the full replica stack.
Our constraint is pure(as) Zig — prefer reimplementing the wire protocol, and
only fall back to a rusty-built bridge (Phase 4) if the pure path cannot meet
correctness.

## Proposed public API (not yet implemented)

```zig
var db = try libsql.Database.open(allocator, .{
    .path = "replica.db",                 // local file
    .url = "libsql://primary.example",    // remote primary
    .auth_token = token,
    .io = io,
    .sync_interval_ms = 60_000,           // 0 = manual only
    .read_your_writes = true,
});
defer db.deinit();

try db.sync(); // manual pull from primary
var conn = db.connect();
// reads hit local; writes policy TBD
```

## Architecture options

### A. Pure Zig sync client (long-term preferred)

```text
OpenOptions{path + sync_url}
  → local libsql-sqlite3 open (engine pin — not stock SQLite alone)
  → gRPC-Web ReplicationLog client (Hello / BatchLogEntries / Snapshot)
  → Proxy client for primary writes
  → SqliteInjector-equivalent:
       - inject 4KiB page frames under exclusive lock
       - {db}-client_wal_index commit cursor
```

**Pros:** no Rust, matches org DNA.  
**Cons:** large; needs libsql WAL hooks + gRPC-Web stack. **Not** the existing
Hrana `Session` path.

### B. Hrana-only “soft replica” (rejected as substitute)

Local file is a cache of query results, not a full binary replica.

**Pros:** reuses Phase 2 pipeline only.  
**Cons:** not a true embedded replica; weak offline story. **Do not ship under
the name “embedded replica.”**

### C. rusty-built staticlib bridge (Phase 4 — near-term recommended)

Link official libsql client / inject stack only when `-Denable-rust-bridge=true`.

**Pros:** classic frame-apply / pull-sync MVP sooner (R1: pull sync + local
reads; primary-write forwarding is future work).  
**Cons:** second toolchain; must stay opt-in and documented for removal when
pure path lands.

## Decision for Phase 3 exit

| Item | Status |
|------|--------|
| Named params | **implemented** |
| Batch | **implemented** |
| Replica design | **this doc** |
| Protocol spike | **done** — `docs/replica-protocol-spike.md` |
| Replica code | **not started** — next: Phase 4 rusty bridge MVP *or* pure Zig wire+inject after engine pin |
| Engine pin (libsql-sqlite3) | required for pure apply — see `docs/libsql-engine.md` |

## Spike checklist (before coding replicas)

1. [x] Map official client wire path (gRPC-Web ReplicationLog + Proxy; not Hrana).
2. [x] Document frame format, auth headers, session / `LogIncompatible` behavior.
3. [x] Write path v1: **primary-only** (classic default).
4. [x] Crash recovery: commit cursor after inject; exclusive lock during sync.
5. [x] Fail closed: replica open requires `io` + `auth_token`; stock SQLite alone → `Unsupported`.

## Security

- Never log `auth_token` or batons.
- Local replica files should recommend `0600` (consumer responsibility, same as auth.db).
- Sync must verify TLS for remote origins (`https` only in production guidance).
