//! Open-target path / URI classification for Database.open.

const std = @import("std");

pub const Kind = enum {
    memory,
    file,
    remote,
};

pub const Parsed = struct {
    kind: Kind,
    /// For `.file`: filesystem path (no `file:` prefix).
    /// For `.memory`: empty or ignored.
    /// For `.remote`: original URL (token never stored here).
    path: []const u8,
};

/// Classify an open path string.
///
/// Accepted:
/// - `:memory:` → memory
/// - `file:PATH` or plain path → file
/// - `libsql://…`, `https://…`, `http://…` → remote (Phase 2)
pub fn parse(path: []const u8) Parsed {
    if (std.mem.eql(u8, path, ":memory:")) {
        return .{ .kind = .memory, .path = path };
    }
    if (std.mem.startsWith(u8, path, "libsql://") or
        std.mem.startsWith(u8, path, "https://") or
        std.mem.startsWith(u8, path, "http://") or
        std.mem.startsWith(u8, path, "wss://") or
        std.mem.startsWith(u8, path, "ws://"))
    {
        return .{ .kind = .remote, .path = path };
    }
    if (std.mem.startsWith(u8, path, "file:")) {
        const rest = path["file:".len..];
        // file:/abs or file:rel — strip single leading slash only when `file:///`.
        if (std.mem.startsWith(u8, rest, "///")) {
            return .{ .kind = .file, .path = rest[2..] }; // keep one leading /
        }
        if (std.mem.startsWith(u8, rest, "//")) {
            // file://host/path — treat as path after host for local-only simplicity:
            // file:///tmp/x already handled; file://localhost/tmp/x → /tmp/x
            if (std.mem.indexOfScalar(u8, rest[2..], '/')) |idx| {
                return .{ .kind = .file, .path = rest[2 + idx ..] };
            }
            return .{ .kind = .file, .path = rest };
        }
        return .{ .kind = .file, .path = rest };
    }
    return .{ .kind = .file, .path = path };
}

test "parse memory" {
    const p = parse(":memory:");
    try std.testing.expect(p.kind == .memory);
}

test "parse plain file" {
    const p = parse("/tmp/x.db");
    try std.testing.expect(p.kind == .file);
    try std.testing.expectEqualStrings("/tmp/x.db", p.path);
}

test "parse file uri" {
    const p = parse("file:///tmp/x.db");
    try std.testing.expect(p.kind == .file);
    try std.testing.expectEqualStrings("/tmp/x.db", p.path);
}

test "parse remote" {
    const p = parse("libsql://example.turso.io");
    try std.testing.expect(p.kind == .remote);
}

/// True when a remote open URL uses a cleartext transport (`http://` or `ws://`)
/// that would expose an auth token in transit. `https://`, `libsql://`, and
/// `wss://` all map to TLS and are considered secure.
pub fn isCleartextRemote(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "ws://");
}

/// Map a remote open URL to an HTTP(S) origin for Hrana over HTTP.
///
/// - `libsql://host/...` → `https://host/...`
/// - `wss://host/...` → `https://host/...`
/// - `ws://host/...` → `http://host/...`
/// - `https://` / `http://` left as-is (trailing slash stripped)
///
/// A Hrana base URL carries only `scheme://authority[/path]`; the client appends
/// its own `/v3/pipeline`. Query or fragment components are rejected rather than
/// silently mangled by the trailing-slash trim. Bare scheme / empty authority is
/// also rejected.
pub fn toHttpBase(allocator: std.mem.Allocator, url: []const u8) error{ OutOfMemory, InvalidPath }![]u8 {
    const mapped = blk: {
        if (std.mem.startsWith(u8, url, "libsql://")) {
            break :blk try std.fmt.allocPrint(allocator, "https://{s}", .{url["libsql://".len..]});
        }
        if (std.mem.startsWith(u8, url, "wss://")) {
            break :blk try std.fmt.allocPrint(allocator, "https://{s}", .{url["wss://".len..]});
        }
        if (std.mem.startsWith(u8, url, "ws://")) {
            break :blk try std.fmt.allocPrint(allocator, "http://{s}", .{url["ws://".len..]});
        }
        break :blk try allocator.dupe(u8, url);
    };
    errdefer allocator.free(mapped);

    // Fail closed on remote URLs without a valid authority: inputs such as
    // `https://` or `libsql://` map to a bare scheme with no host, which would
    // otherwise be accepted and only fail later on a doomed HTTP request. The
    // host is the run between `://` and the first `/`, `?`, or `#`.
    const authority = blk2: {
        const sep = "://";
        const idx = std.mem.indexOf(u8, mapped, sep) orelse break :blk2 "";
        const after = mapped[idx + sep.len ..];
        const host_end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
        break :blk2 after[0..host_end];
    };
    if (authority.len == 0) return error.InvalidPath;

    // Fail closed on query/fragment: trimming trailing '/' below would also
    // corrupt query or fragment data (e.g. `.../?x=/` → `.../?x=`), and such a
    // URL is not a valid Hrana base anyway.
    if (std.mem.indexOfAny(u8, mapped, "?#") != null) return error.InvalidPath;

    // Strip trailing path separators for a stable join with /v3/pipeline.
    var end = mapped.len;
    while (end > 0 and mapped[end - 1] == '/') end -= 1;
    if (end == mapped.len) return mapped;
    const trimmed = try allocator.dupe(u8, mapped[0..end]);
    allocator.free(mapped);
    return trimmed;
}

test "toHttpBase libsql" {
    const gpa = std.testing.allocator;
    const u = try toHttpBase(gpa, "libsql://db.turso.io/");
    defer gpa.free(u);
    try std.testing.expectEqualStrings("https://db.turso.io", u);
}

test "toHttpBase rejects query or fragment" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidPath, toHttpBase(gpa, "https://db.turso.io/path?x=/"));
    try std.testing.expectError(error.InvalidPath, toHttpBase(gpa, "libsql://db.turso.io/#frag"));
}

test "toHttpBase rejects missing authority" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidPath, toHttpBase(gpa, "https://"));
    try std.testing.expectError(error.InvalidPath, toHttpBase(gpa, "libsql://"));
    try std.testing.expectError(error.InvalidPath, toHttpBase(gpa, "ws://"));
    try std.testing.expectError(error.InvalidPath, toHttpBase(gpa, "https:///only/path"));
}

test "toHttpBase survives allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn f(allocator: std.mem.Allocator) !void {
            const u = try toHttpBase(allocator, "libsql://db.turso.io/");
            allocator.free(u);
        }
    }.f, .{});
}
