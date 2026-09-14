/* libsql_bridge — optional C ABI for classic libSQL embedded replica sync.
 *
 * Built with rusty as a cdylib; loaded at runtime by zig-libsql when
 * -Denable-rust-bridge=true (see docs/rust-bridge.md).
 */
#ifndef ZIG_LIBSQL_BRIDGE_H
#define ZIG_LIBSQL_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** NUL-terminated bridge version string (static storage). */
const char *zig_libsql_bridge_version(void);

/**
 * Open a remote embedded replica at db_path, sync from primary_url, then close.
 *
 * @param db_path            Local SQLite file path (not :memory:).
 * @param primary_url        Primary URL (libsql:// or https://).
 * @param auth_token         Bearer token; may be NULL (empty).
 * @param read_your_writes   Non-zero to enable RYW while the libsql handle lives
 *                           (this one-shot API drops the handle after sync).
 * @param out_frame_no       Optional; last committed frame, or -1 if none.
 * @param out_frames_synced  Optional; frames applied this call.
 * @param err_buf            Optional UTF-8 error message buffer.
 * @param err_buf_len        Size of err_buf including NUL.
 * @return 0 on success, non-zero on failure.
 */
int zig_libsql_bridge_sync_once(
    const char *db_path,
    const char *primary_url,
    const char *auth_token,
    int read_your_writes,
    int64_t *out_frame_no,
    uint64_t *out_frames_synced,
    char *err_buf,
    size_t err_buf_len);

#ifdef __cplusplus
}
#endif

#endif /* ZIG_LIBSQL_BRIDGE_H */
