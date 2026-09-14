# R2 / R2.1 / R3a — Pure Zig classic replica wire + pull client

**Status:** codecs + gRPC-Web unary/stream pull + meta disk I/O (no public pure sync)  
**Depends on:** protocol spike (`docs/replica-protocol-spike.md`)

## Scope

| Included | Excluded |
|----------|----------|
| Frame header + 4 KiB page layout | WAL inject / libsql-sqlite3 |
| `wal_log` protobuf (Hello, LogOffset, Frame, Frames) | `Proxy` write RPCs |
| `{db}-client_wal_index` meta layout + load/save | Streaming `LogEntries` (optional later) |
| gRPC-Web framing (`application/grpc-web+proto`) | Public pure-Zig `Database.sync()` |
| Unary `Hello` + `BatchLogEntries` over HTTPS | Claiming stock SQLite can apply frames |
| Server-stream `Snapshot` + `NEED_SNAPSHOT` recovery | Disk-backed snapshot > 64 MiB body |

## Modules

| Path | Role |
|------|------|
| `src/backend/replication/frame.zig` | LE `FrameHeader` + fixed `Frame` |
| `src/backend/replication/pb.zig` | Minimal protobuf varint / length fields |
| `src/backend/replication/wal_log.zig` | Hello / LogOffset / Frames codecs |
| `src/backend/replication/meta.zig` | Client WAL index layout, path, load/save |
| `src/backend/replication/grpc_web.zig` | Unary + stream framing + trailer status |
| `src/backend/replication/http.zig` | HTTPS POST unary/stream + replica auth headers |
| `src/backend/replication/client.zig` | `hello` / `batchLogEntries` / `snapshot` / `pullUntilCaughtUp` |

## Client usage (internal)

```zig
var client = try replication.Client.open(io, allocator, sync_url, auth_token, "default");
defer client.deinit();

_ = try client.hello();

// Prefer the orchestrator (handles NEED_SNAPSHOT → Snapshot → resume batches):
var pull = try client.pullUntilCaughtUp(meta.nextOffset(), null, 64);
defer pull.deinit();
// pull.frames ready for inject (R1 bridge or future R3b) — not public pure sync yet

// Or call RPCs directly:
// var batch = try client.batchLogEntries(offset); // may return error.NeedSnapshot
// var snap = try client.snapshot(offset);
```

Auth headers (never logged): `x-authorization`, `x-namespace-bin` (base64),
`x-libsql-client-version`, `x-session-token` after Hello.

TLS: auth token requires `https://` origin (`libsql://` maps to HTTPS).

Stream responses use one protobuf message per gRPC-Web data frame (not
concatenated like unary). Response body cap is **64 MiB** for both unary and
stream RPCs.

## Meta disk

- Path: `{basename}-client_wal_index` beside the DB file  
- `load` → `null` if missing (caller must not auto-delete an existing user DB)  
- `save` writes temp then renames  
- Advance `committed_frame_no` only after successful inject (not in this slice)

## Next (R3b+)

1. ~~libsql engine pin~~ (**R3b.0** — `-Dengine=libsql`, `vendor/libsql/`)  
2. **WAL inject** (R3b.1 — InjectorWal / `libsql_open_v3`)  
3. Wire client → inject → meta; flip pure public `Database.sync()` (R3b.2)  
4. Apply only via R1 bridge or pure inject — never claim stock SQLite inject 

## Security

- Do not log session tokens, auth tokens, or full frame payloads.  
- Codecs and transport treat secrets as opaque bytes.  
