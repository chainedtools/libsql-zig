# Classic libSQL embedded replica — protocol spike

**Status:** complete (source-backed; no live traffic capture)  
**Target:** classic libSQL embedded replicas (`file:` + `syncUrl` + `authToken`)  
**Out of scope:** newer Turso Sync (`push`/`pull` / CDC) — see Turso product docs; different engine and SDK surface.

This note answers the spike checklist in `docs/embedded-replicas.md` and records go/no-go for a pure-Zig path on **stock** SQLite amalgamation.

## Executive summary

Classic embedded replica sync is **not Hrana**. Official clients:

1. Keep a **local SQLite file** for reads.
2. Pull **4 KiB page frames** from the primary over **gRPC-Web** (`ReplicationLog` protobuf service).
3. **Inject** those frames into a local WAL via **libSQL custom WAL hooks** (`SqliteInjector` / `InjectorWal`).
4. Send **writes to the primary** over a separate gRPC-Web **`Proxy`** service (not the local file first).
5. Re-apply frames locally for **read-your-writes** after a successful primary write (or via `sync()` / periodic sync).

**Go/no-go:** a correct classic replica **cannot** be implemented on **stock SQLite 3.49.1** alone. Frame *transport* is reimplementable in pure Zig; frame *apply* requires libSQL WAL injection (libsql-sqlite3 / `libsql_sys` WAL manager) or a **rusty-built bridge** wrapping the official client (Phase 4).

Existing Phase 2 **Hrana HTTP** remains the right remote SQL path. Replicas are a **separate stack**.

---

## 1. Wire surface

### Transport

| Item | Finding |
|------|---------|
| Protocol | **gRPC over HTTP** via **gRPC-Web** (`tonic` + `tonic-web` / hyper), TLS in production |
| Not used | Hrana `POST …/v3/pipeline` JSON (that is remote *SQL*, not page replication) |
| Origin | Same host as `syncUrl` / primary (`libsql://` → HTTPS origin) |
| Client entry | `libsql/src/replication/client.rs` — dual clients: `ReplicationLogClient` + `ProxyClient` |

### Auth & metadata (every request)

From `GrpcInterceptor` in `libsql/src/replication/client.rs`:

| Header | Value |
|--------|--------|
| `x-authorization` | `Bearer <auth_token>` (ASCII) |
| `x-namespace-bin` | Binary metadata: DB namespace (from hostname label or config; default `"default"`) |
| `x-libsql-client-version` | e.g. `libsql-rpc-<semver>` |
| `x-session-token` | After `Hello`: server-issued UUID session (must match until restart) |

Tokens must **never** be logged. Plaintext HTTP with a token is fail-closed in our remote SQL path; replicas should follow the same rule.

### `ReplicationLog` service (pull)

Protobuf package `wal_log` — `libsql-replication/proto/replication_log.proto`:

```protobuf
service ReplicationLog {
  rpc Hello(HelloRequest) returns (HelloResponse) {}
  rpc LogEntries(LogOffset) returns (stream Frame) {}
  rpc BatchLogEntries(LogOffset) returns (Frames) {}
  rpc Snapshot(LogOffset) returns (stream Frame) {}
}
```

| RPC | Role |
|-----|------|
| **Hello** | Handshake: log identity, session token, current replication index, optional `DatabaseConfig` |
| **BatchLogEntries** | Pull a batch of frames starting at `next_offset` (preferred client path; prefetch during handshake) |
| **LogEntries** | Streaming variant of the same |
| **Snapshot** | Full/dense snapshot stream when incremental log is insufficient (`NEED_SNAPSHOT`) |

**LogOffset:**

```text
next_offset: u64          // next frame_no to pull (committed+1, or 0)
wal_flavor?: Sqlite | Libsql
```

**HelloResponse (key fields):**

```text
generation_id: string
generation_start_index: u64
log_id: string            // UUID of the replicated log
session_token: bytes      // UUID; verify as UTF-8 UUID
current_replication_index?: u64
config?: DatabaseConfig   // block_reads/writes, max_db_pages, …
```

**Session errors** (string messages in tonic status, from `rpc.rs`):

- `NO_HELLO` — missing/invalid session token after restart  
- `NEED_SNAPSHOT` — client must call `Snapshot`  
- `NAMESPACE_DOESNT_EXIST`

### `Proxy` service (writes / describe)

Protobuf package `proxy` — `libsql-replication/proto/proxy.proto`:

| RPC | Role |
|-----|------|
| **Execute** (`ProgramReq`) | Run a multi-step program on the **primary** (deprecated but still used by Rust client) |
| **Describe** | Parameter/column metadata |
| **StreamExec** | Streaming execute (newer) |
| **Disconnect** | Drop server-side client state |

Writes are **primary-only** by default (classic model). Local file is updated by frame inject after write / sync, not by applying SQL locally first.

---

## 2. Frame / page format

Defined in `libsql-replication/src/frame.rs`. Page size constant: **`LIBSQL_PAGE_SIZE = 4096`**.

### Binary layout (little-endian, fixed size)

```text
FrameBorrowed {
  header: FrameHeader {
    frame_no:   u64   // incremental replication index
    checksum:   u64   // rolling checksum including this frame
    page_no:    u32   // SQLite page number
    size_after: u32   // DB size in pages after commit; 0 = not a commit boundary
  }                   // 24 bytes
  page: [u8; 4096]
}
// total ≈ 4120 bytes per frame
```

- **Commit boundary:** `size_after != 0` marks end of a transaction unit.  
- **Unit of sync:** one frame ≈ one 4 KiB page (Turso docs: writing 1 byte still surfaces as a 4 KiB frame).  
- **RPC envelope:** `wal_log.Frame { data: bytes, timestamp?, durable_frame_no? }` — `data` is the raw `FrameBorrowed` bytes.

### Client progress metadata

Sidecar file next to the DB (prefixed open path):

```text
{db_filename}-client_wal_index
```

`WalIndexMetaData` (`meta.rs`):

```text
log_id:              u128   // from Hello.log_id UUID
committed_frame_no:  u64    // last successfully applied commit; MAX = none
padding:             8 bytes
```

Rules:

- Existing DB **without** wal-index → error (`RequiresCleanDatabase`): the local file may hold user data, so **do not delete it automatically**. Surface the outcome and require an explicit reset/backup decision (back up or discard the file), then reopen as a replica only as an opt-in recovery step.  
- `committed_frame_no == MAX` is the "uninitialized / no commit" sentinel. Handle it **before** any comparison or offset arithmetic: force `next_offset = 0` (pull from the first frame) and bypass the numeric `committed_frame_no >= primary_index` caught-up check. Do **not** compute `committed_frame_no + 1` on the sentinel (it would overflow). Numeric progression applies only once a real commit value is stored.  
- Hello `log_id` mismatch → `LogIncompatible`: mark dirty, wipe/resync from scratch.  
- `set_commit_frame_no` after each successful inject commit (idempotent re-apply of last txn only).

---

## 3. Write policy (classic)

| Policy | Behavior |
|--------|----------|
| Default | Writes (and write+read transactions) go to **primary** via `Proxy` |
| Local reads | Always from local file |
| Read-your-writes | After primary write succeeds, replica applies frames so initiator sees data without waiting for another peer’s `sync()` |
| Offline writes | Optional `offline: true` in some SDKs — local-first; **not** the default classic path |
| `sync()` | Force handshake + pull until caught up. On the `MAX` sentinel, start from `next_offset = 0`; otherwise pull until `committed_frame_no >= primary_index` |
| Periodic sync | Background loop calling oneshot sync on interval |

**zig-libsql v1 decision (locked):** primary-only writes; no offline multi-writer in the first implementation slice.

---

## 4. Crash recovery & concurrency

| Risk | Mitigation in official stack |
|------|------------------------------|
| Partial inject mid-txn | Buffer frames; only advance `committed_frame_no` after inject returns commit; `rollback()` clears buffer + SQL `ROLLBACK` |
| Crash mid-commit | Re-apply last transaction is considered safe; losing *more than one* commit index is not |
| Log generation change | `LogIncompatible` → dirty meta, full re-replicate |
| Concurrent open while syncing | **Documented corruption risk** — “Do not open the local database while the embedded replica is syncing” (Turso docs) |
| Dirty server WAL after restart | May force extra frames / snapshot |

**Implication for us:** `sync()` must hold an exclusive write lock on the local DB handle; no concurrent consumer connections during inject (or mirror official “single connector” model).

---

## 5. Local apply — engine requirement

### How inject works

`SqliteInjector` (`libsql-replication/src/injector/sqlite_injector/`):

1. Opens the DB with a **custom `WalManager`** (`InjectorWalManager`).  
2. Buffers frames; on flush runs a dummy write (`INSERT INTO libsql_temp_injection …`) under `writable_schema` to force SQLite into `xFrame` / `insert_frames`.  
3. `InjectorWal::insert_frames` **replaces** the pending page headers with pages from the frame buffer and calls into the real WAL.  
4. Signals success via custom extended codes (`LIBSQL_INJECT_OK` / `OK_TXN` / `FATAL`).  
5. Rolls back the dummy transaction; durable state is the injected pages + meta file.

This path depends on **libSQL’s WAL manager / `libsql_sys` connection API**, not on public stock SQLite C API.

### Feasibility matrix

| Approach | Frame pull (wire) | Frame apply | Writes | Fit for zig-libsql |
|----------|-------------------|-------------|--------|--------------------|
| A. Pure Zig + **stock** amalgamation | Possible (gRPC-Web + protos) | **No** — no VWAL inject | Primary via Proxy or reuse Hrana | **No-go for classic replica** |
| B. Pure Zig wire + **libsql-sqlite3** pin + WAL inject port | Possible | Possible long-term (large) | Proxy or Hrana | Preferred long-term pure path |
| C. **rusty** staticlib wrapping official libsql client | N/A (inside Rust) | Yes | Yes | **Near-term correctness** (Phase 4) |
| D. Soft replica (Hrana query cache only) | Reuse Phase 2 | N/A | Remote | **Not** classic embedded replica |

`docs/libsql-engine.md` already anticipated this: switch engine when “Virtual WAL hooks required for embedded replica apply.”

---

## 6. Decision table (spike exit)

| Decision | Options | **Recommendation** |
|----------|---------|----------------------|
| Wire protocol | Classic frames vs soft-replica only | **Classic `ReplicationLog` + `Proxy` gRPC-Web** for true embedded replicas; keep Hrana for remote SQL only |
| Local apply | Stock SQLite / libsql-sqlite3 / rusty bridge | **Not stock SQLite.** Prefer **Phase 4 rusty bridge** for first working feature; long-term pure Zig + libsql engine pin + inject port |
| Write path v1 | Primary-only vs offline | **Primary-only** (locked) |
| Auth policy | Token optional vs required | **Require `auth_token` when replica/sync URL is set** (fail closed); TLS/HTTPS only in production |
| Open API shape | Design’s `path` + `url` + … | Keep **`path` (local file) + `sync_url` + `auth_token` + `io` + `sync_interval_ms`**; add explicit `kind` dual open; do not overload single `path` remote URL |
| First code slice | Manual `sync()` vs interval | **Manual `Database.sync()` only** first; interval later |
| Soft replica | Ship as interim | **No** as a substitute named “embedded replica” |

### Product stance

- Do **not** advertise embedded replicas until apply is real.  
- Do **not** block Phase 3 *exit for named params + batch* on replicas (already shipped).  
- Replica **implementation** is a follow-on that either (C) rusty bridge or (B) engine pin + pure Zig wire+inject.

---

## 7. Recommended implementation slices (after this spike)

### Slice R0 — this document ✅

Protocol + decisions documented.

### Slice R1 — Phase 4 rusty bridge (fastest correct MVP)

```sh
rusty init libsql_bridge -lib -y   # or equivalent
```

- Gated: `-Denable-rust-bridge=true`.  
- Expose minimal C ABI: open embedded replica, `sync()`, connect, exec/query or hand back path.  
- Zig `OpenOptions` dual path calls bridge when enabled.  
- Document **removal criteria**: pure Zig wire + libsql inject lands and passes parity tests.

### Slice R2 — Pure Zig wire only (optional parallel)

- Encode/decode `Hello` / `BatchLogEntries` / frame headers against fixtures.  
- Integration test against Turso/libsql-server when credentials present.  
- **No** public `sync()` until inject exists (avoid half-broken API).

### Slice R3 — Engine pin + inject

- Vendor libsql amalgamation / WAL hooks per `docs/libsql-engine.md`.  
- Port or reimplement `SqliteInjector` semantics in Zig.  
- Wire R2 client → inject → meta file.  
- Then public `Database.sync()` + dual open.

### Not first

- Periodic background sync, encryption-at-rest, offline writes, Turso Sync CDC.

---

## 8. Mapping to proposed Zig API

Status: R1 pull-sync is **implemented** via the rusty bridge
(`OpenOptions.sync_url` + `Database.sync()`, gated `-Denable-rust-bridge`).
Primary-write forwarding is **not yet implemented** and remains future work.

```zig
var db = try libsql.Database.open(allocator, .{
    .path = "replica.db",              // local file (required)
    .sync_url = "libsql://primary…",   // primary to pull frames from (R1)
    .auth_token = token,               // required for replica open
    .io = io,                          // required
    .sync_interval_ms = 0,             // 0 = manual only
    .read_your_writes = true,          // after primary write (bridge/inject)
});
try db.sync();                         // R1: pull frames until caught up (implemented)
var conn = db.connect();               // local reads (implemented);
                                       // writes → primary forwarding: future work, not R1
```

Fail closed:

- `sync_url` without `io` → error.  
- `sync_url` without `auth_token` → error (stricter than pure remote SQL).  
- Stock engine without bridge/inject → `error.Unsupported` with clear message.

---

## 9. Spike method / sources

No live packet capture (no credentials in this environment). Findings from public sources:

| Source | URL / path |
|--------|------------|
| Product behavior | https://docs.turso.tech/features/embedded-replicas/introduction |
| gRPC client + headers | `tursodatabase/libsql` → `libsql/src/replication/client.rs` |
| Pull + handshake | `libsql/src/replication/remote_client.rs` |
| Embed orchestrator | `libsql/src/replication/mod.rs` (`EmbeddedReplicator`) |
| Protos | `libsql-replication/proto/replication_log.proto`, `proxy.proto`, `metadata.proto` |
| Frame layout | `libsql-replication/src/frame.rs` |
| Meta / crash index | `libsql-replication/src/meta.rs` |
| Apply / WAL inject | `libsql-replication/src/injector/sqlite_injector/` |
| Session constants | `libsql-replication/src/rpc.rs` |

Pin note: upstream evolves; re-check protos and injector before coding R2/R3.

---

## 10. Security checklist

- [x] Auth: Bearer in metadata; never log.  
- [x] Session tokens treated as secrets.  
- [x] TLS for production origins.  
- [x] Local replica file mode remains consumer-owned (`0600` guidance).  
- [x] Fail closed when replica open missing `io` / token / inject capability.

---

## 11. Checklist (from design doc)

1. [x] Wire traffic / protocol from official client sources (gRPC-Web, not Hrana).  
2. [x] Frame format, auth, conflict/`LogIncompatible` behavior documented.  
3. [x] Write path: primary-only for v1.  
4. [x] Crash recovery: meta commit index + inject rollback; no concurrent open during sync.  
5. [x] Fail closed for replica `io` / token; stock SQLite alone → Unsupported.
