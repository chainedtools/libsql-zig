//! Optional C ABI for classic libSQL embedded replica **sync**.
//!
//! Built with rusty (`crate-type = ["cdylib"]`) and loaded at runtime by Zig so
//! the libsql-sys amalgamation does not collide with zig-libsql's vendored
//! stock SQLite symbols at link time.
//!
//! ## Removal criteria
//!
//! Delete this crate when pure Zig gRPC-Web frame pull + libsql-sqlite3 inject
//! (R2/R3 in `docs/replica-protocol-spike.md`) passes parity tests against the
//! same primary.

use std::ffi::{c_char, c_int, CStr};
use std::path::Path;
use std::slice;

/// Package / bridge version string (NUL-terminated static).
#[no_mangle]
pub extern "C" fn zig_libsql_bridge_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

/// One-shot: open a remote embedded replica, `sync()` until caught up, drop.
///
/// Updates `db_path` on disk (plus `{basename}-client_wal_index`). Callers must
/// not hold other connections open on `db_path` during this call.
///
/// # Safety
///
/// - `db_path` and `primary_url` must be non-null C strings.
/// - `auth_token` may be null (treated as empty).
/// - `out_frame_no` / `out_frames_synced` may be null.
/// - If `err_buf` is non-null, `err_buf_len` bytes are writable.
///
/// Returns `0` on success, non-zero on failure (message in `err_buf` when provided).
#[no_mangle]
pub unsafe extern "C" fn zig_libsql_bridge_sync_once(
    db_path: *const c_char,
    primary_url: *const c_char,
    auth_token: *const c_char,
    read_your_writes: c_int,
    out_frame_no: *mut i64,
    out_frames_synced: *mut u64,
    err_buf: *mut c_char,
    err_buf_len: usize,
) -> c_int {
    if db_path.is_null() || primary_url.is_null() {
        write_err(err_buf, err_buf_len, "db_path and primary_url are required");
        return 1;
    }

    let path = match CStr::from_ptr(db_path).to_str() {
        Ok(s) if !s.is_empty() => s,
        _ => {
            write_err(err_buf, err_buf_len, "db_path must be valid UTF-8");
            return 1;
        }
    };
    let url = match CStr::from_ptr(primary_url).to_str() {
        Ok(s) if !s.is_empty() => s.to_owned(),
        _ => {
            write_err(err_buf, err_buf_len, "primary_url must be valid UTF-8");
            return 1;
        }
    };
    let token = if auth_token.is_null() {
        String::new()
    } else {
        match CStr::from_ptr(auth_token).to_str() {
            Ok(s) => s.to_owned(),
            Err(_) => {
                write_err(err_buf, err_buf_len, "auth_token must be valid UTF-8");
                return 1;
            }
        }
    };

    let ryw = read_your_writes != 0;

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        sync_once_inner(Path::new(path), url, token, ryw)
    }));

    match result {
        Ok(Ok(rep)) => {
            if !out_frame_no.is_null() {
                *out_frame_no = rep.frame_no.map(|n| n as i64).unwrap_or(-1);
            }
            if !out_frames_synced.is_null() {
                *out_frames_synced = rep.frames_synced as u64;
            }
            0
        }
        Ok(Err(msg)) => {
            write_err(err_buf, err_buf_len, &msg);
            2
        }
        Err(_) => {
            write_err(err_buf, err_buf_len, "libsql_bridge panicked during sync");
            3
        }
    }
}

struct SyncResult {
    frame_no: Option<u64>,
    frames_synced: usize,
}

fn sync_once_inner(
    path: &Path,
    url: String,
    token: String,
    read_your_writes: bool,
) -> Result<SyncResult, String> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("tokio runtime: {e}"))?;

    rt.block_on(async move {
        let db = libsql::Builder::new_remote_replica(path, url, token)
            .read_your_writes(read_your_writes)
            .build()
            .await
            .map_err(|e| format!("open remote replica: {e}"))?;

        let rep = db.sync().await.map_err(|e| format!("sync: {e}"))?;

        Ok(SyncResult {
            frame_no: rep.frame_no(),
            frames_synced: rep.frames_synced(),
        })
    })
}

fn write_err(err_buf: *mut c_char, err_buf_len: usize, msg: &str) {
    if err_buf.is_null() || err_buf_len == 0 {
        return;
    }
    // Leave room for NUL.
    let max = err_buf_len.saturating_sub(1);
    let bytes = msg.as_bytes();
    let n = bytes.len().min(max);
    unsafe {
        let dest = slice::from_raw_parts_mut(err_buf as *mut u8, err_buf_len);
        dest[..n].copy_from_slice(&bytes[..n]);
        dest[n] = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    #[test]
    fn version_non_empty() {
        let v = unsafe { CStr::from_ptr(zig_libsql_bridge_version()) };
        assert!(!v.to_bytes().is_empty());
    }
}
