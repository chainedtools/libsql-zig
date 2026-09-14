//! Optional runtime loader for the rusty-built `libsql_bridge` cdylib.
//!
//! When the package is built without `-Denable-rust-bridge=true`, all entry
//! points return `error.Unsupported`. When enabled, the cdylib is opened via
//! `std.DynLib` so stock SQLite and libsql-sys are never linked together.

const std = @import("std");
const builtin = @import("builtin");
const err = @import("../error.zig");

/// Compile-time gate from `build.zig` (`-Denable-rust-bridge=true`).
pub const enabled = @import("build_options").enable_rust_bridge;

/// Optional absolute/relative path to the cdylib; empty → platform default name.
pub const default_lib_path = @import("build_options").rust_bridge_lib;

const SyncOnceFn = *const fn (
    db_path: [*:0]const u8,
    primary_url: [*:0]const u8,
    auth_token: ?[*:0]const u8,
    read_your_writes: c_int,
    out_frame_no: ?*i64,
    out_frames_synced: ?*u64,
    err_buf: ?[*]u8,
    err_buf_len: usize,
) callconv(.c) c_int;

const VersionFn = *const fn () callconv(.c) [*:0]const u8;

pub const SyncResult = struct {
    frame_no: ?i64,
    frames_synced: u64,
};

var lib_mutex: std.Thread.Mutex = .{};
var dyn_lib: ?std.DynLib = null;
var sync_once_fn: ?SyncOnceFn = null;
var version_fn: ?VersionFn = null;

fn platformLibName() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "liblibsql_bridge.so",
        .macos => "liblibsql_bridge.dylib",
        .windows => "libsql_bridge.dll",
        else => "liblibsql_bridge.so",
    };
}

fn ensureLoaded() err.Error!void {
    if (!enabled) return error.Unsupported;

    // All reads/writes of sync_once_fn are synchronized under lib_mutex; there is
    // no unlocked fast path, so concurrent first use cannot race initialization.
    lib_mutex.lock();
    defer lib_mutex.unlock();
    if (sync_once_fn != null) return;

    const path = if (default_lib_path.len > 0) default_lib_path else platformLibName();
    var lib = std.DynLib.open(path) catch return error.Open;
    errdefer lib.close();

    const sync_sym = lib.lookup(SyncOnceFn, "zig_libsql_bridge_sync_once") orelse {
        lib.close();
        return error.Open;
    };
    const ver_sym = lib.lookup(VersionFn, "zig_libsql_bridge_version");

    dyn_lib = lib;
    sync_once_fn = sync_sym;
    version_fn = ver_sym;
}

/// Bridge package version, if the cdylib is loaded.
pub fn version() err.Error![]const u8 {
    try ensureLoaded();
    const f = version_fn orelse return error.Unsupported;
    return std.mem.span(f());
}

/// One-shot classic embedded replica sync via the rusty bridge.
///
/// Caller must not hold other connections open on `db_path` during this call.
/// On failure, copies a NUL-terminated diagnostic into `err_msg_out` when
/// provided (never log secrets; buffer may include path info).
pub fn syncOnce(
    db_path: []const u8,
    primary_url: []const u8,
    auth_token: ?[]const u8,
    read_your_writes: bool,
    err_msg_out: ?*[512]u8,
) err.Error!SyncResult {
    try ensureLoaded();
    const f = sync_once_fn orelse return error.Unsupported;

    var path_z_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (db_path.len >= path_z_buf.len) return error.InvalidPath;
    @memcpy(path_z_buf[0..db_path.len], db_path);
    path_z_buf[db_path.len] = 0;

    var url_z_buf: [4096]u8 = undefined;
    if (primary_url.len >= url_z_buf.len) return error.InvalidPath;
    @memcpy(url_z_buf[0..primary_url.len], primary_url);
    url_z_buf[primary_url.len] = 0;

    var token_z_buf: [8192]u8 = undefined;
    var token_z: ?[*:0]const u8 = null;
    if (auth_token) |t| {
        if (t.len >= token_z_buf.len) return error.InvalidPath;
        @memcpy(token_z_buf[0..t.len], t);
        token_z_buf[t.len] = 0;
        token_z = token_z_buf[0..t.len :0].ptr;
    }

    var frame_no: i64 = -1;
    var frames_synced: u64 = 0;
    var err_buf: [512]u8 = undefined;
    @memset(&err_buf, 0);

    const rc = f(
        path_z_buf[0..db_path.len :0].ptr,
        url_z_buf[0..primary_url.len :0].ptr,
        token_z,
        if (read_your_writes) @as(c_int, 1) else 0,
        &frame_no,
        &frames_synced,
        &err_buf,
        err_buf.len,
    );
    if (rc != 0) {
        // Surface diagnostic to caller via out-buffer; never log (may include paths).
        if (err_msg_out) |out| {
            out.* = err_buf;
        }
        return error.Sql;
    }

    if (err_msg_out) |out| @memset(out, 0);

    return .{
        .frame_no = if (frame_no < 0) null else frame_no,
        .frames_synced = frames_synced,
    };
}

/// True when this build was compiled with the rust-bridge option (cdylib may still be missing at runtime).
pub fn isCompileEnabled() bool {
    return enabled;
}

test "bridge disabled returns Unsupported when not enabled" {
    if (enabled) return;
    try std.testing.expectError(error.Unsupported, version());
    try std.testing.expectError(error.Unsupported, syncOnce("x.db", "libsql://example", null, true, null));
}
