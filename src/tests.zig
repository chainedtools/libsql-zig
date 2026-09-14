//! Integration + submodule test aggregator.
//!
//! Kept out of `src/root.zig` so that the public root stays limited to exports
//! and the package version (see AGENTS.md). This module is the test root wired
//! up in `build.zig`.

const std = @import("std");

// Exercise the public package surface (root re-exports + version) via the
// same compilation unit as the submodule unit tests.
const libsql = @import("root.zig");
const Database = libsql.Database;
const Connection = libsql.Connection;
const Value = libsql.Value;
const open = libsql.open;
const engineVersion = libsql.engineVersion;
const c = @import("c/sqlite.zig");

test {
    _ = @import("util/path.zig");
    _ = @import("error.zig");
    _ = @import("value.zig");
    _ = @import("rows.zig");
    _ = @import("statement.zig");
    _ = @import("connection.zig");
    _ = @import("database.zig");
    _ = @import("batch.zig");
    _ = @import("backend/remote.zig");
    _ = @import("backend/bridge.zig");
    _ = @import("backend/replication/frame.zig");
    _ = @import("backend/replication/pb.zig");
    _ = @import("backend/replication/wal_log.zig");
    _ = @import("backend/replication/meta.zig");
    _ = @import("backend/replication/grpc_web.zig");
    _ = @import("backend/replication/http.zig");
    _ = @import("backend/replication/client.zig");
    _ = @import("backend/replication/inject.zig");
    _ = @import("backend/hrana/value_json.zig");
    _ = @import("backend/hrana/pipeline.zig");
    _ = @import("backend/hrana/http.zig");
}

test "engine version non-empty" {
    const v = engineVersion();
    try std.testing.expect(v.len > 0);
}

test "engine kind and optional libsql version" {
    const e = libsql.engine;
    try std.testing.expect(e == .sqlite or e == .libsql);
    if (e == .libsql) {
        const lv = libsql.libsqlVersion() orelse return error.TestUnexpectedResult;
        try std.testing.expect(lv.len > 0);
    } else {
        try std.testing.expect(libsql.libsqlVersion() == null);
    }
    // R3b.0: pure inject not shipped yet.
    try std.testing.expect(!libsql.pure_inject_available());
}

test "memory create insert select" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();

    try conn.exec(
        \\create table t(id integer primary key, name text not null, score real, blob blob);
    , .{});

    var ins = try conn.prepare("insert into t(name, score, blob) values (?1, ?2, ?3);");
    defer ins.deinit();
    try ins.bind(.{ "alice", 3.5, "hi" });
    try ins.execute();
    try std.testing.expectEqual(@as(i64, 1), conn.changes());
    try std.testing.expectEqual(@as(i64, 1), conn.lastInsertRowid());

    var sel = try conn.prepare("select id, name, score, blob from t where id = ?1;");
    defer sel.deinit();
    try sel.bindInt(1, 1);
    const row = (try sel.step()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1), try row.int(0));
    try std.testing.expectEqualStrings("alice", (try row.text(1)).?);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), try row.float(2), 0.0001);
    try std.testing.expectEqualStrings("hi", (try row.blob(3)).?);
    try std.testing.expect((try sel.step()) == null);
}

test "null bind and column" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();
    try conn.exec("create table t(id integer primary key, note text);", .{});
    var ins = try conn.prepare("insert into t(note) values (?1);");
    defer ins.deinit();
    try ins.bindNull(1);
    try ins.execute();

    var sel = try conn.prepare("select note from t where id = 1;");
    defer sel.deinit();
    const row = (try sel.step()) orelse return error.TestUnexpectedResult;
    try std.testing.expect(try row.isNull(0));
    try std.testing.expect((try row.text(0)) == null);
}

test "transaction rollback" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();
    try conn.exec("create table t(x integer);", .{});
    try conn.begin();
    try conn.exec("insert into t(x) values (1);", .{});
    try conn.rollback();

    var sel = try conn.prepare("select count(*) from t;");
    defer sel.deinit();
    const row = (try sel.step()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 0), try row.int(0));
}

test "file durability" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Portable, unique temp directory (no hardcoded /tmp or Linux-only getpid).
    // cleanup() removes the whole tree, so no stale files are left behind.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const db_path = try std.fs.path.join(gpa, &.{ dir_path, "durability.db" });
    defer gpa.free(db_path);

    {
        var db = try Database.open(gpa, .{ .path = db_path });
        defer db.deinit();
        var conn = db.connect();
        try conn.exec("create table t(x text);", .{});
        try conn.execute("insert into t(x) values (?1);", .{"persist"});
    }

    {
        var db = try Database.open(gpa, .{ .path = db_path, .create = false });
        defer db.deinit();
        var conn = db.connect();
        var sel = try conn.prepare("select x from t;");
        defer sel.deinit();
        const row = (try sel.step()) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("persist", (try row.text(0)).?);
    }
}

test "remote open requires io" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.Unsupported, Database.open(gpa, .{
        .path = "libsql://example.turso.io",
        .auth_token = "secret",
        // no io → Unsupported
    }));
}

test "remote open with io creates session" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var db = try Database.open(gpa, .{
        .path = "libsql://example.turso.io",
        .auth_token = "secret",
        .io = io,
    });
    defer db.deinit();
    try std.testing.expect(db.isRemote());
}

test "live remote smoke (gated)" {
    // Set LIBSQL_URL and LIBSQL_AUTH_TOKEN to exercise a real server.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const url = std.process.Environ.getPosix(std.testing.environ, "LIBSQL_URL") orelse return error.SkipZigTest;
    const token = std.process.Environ.getPosix(std.testing.environ, "LIBSQL_AUTH_TOKEN");

    var db = try Database.open(gpa, .{
        .path = url,
        .auth_token = token,
        .io = io,
    });
    defer db.deinit();
    var conn = db.connect();
    try conn.exec("select 1;", .{});
}

test "convenience open owns handle" {
    const gpa = std.testing.allocator;
    var conn = try open(gpa, ":memory:");
    defer conn.deinit();
    try conn.exec("select 1;", .{});
}

test "optional text bind" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();
    try conn.exec("create table t(a text, b text);", .{});
    const missing: ?[]const u8 = null;
    try conn.execute("insert into t(a, b) values (?1, ?2);", .{ "x", missing });
    var sel = try conn.prepare("select a, b from t;");
    defer sel.deinit();
    const row = (try sel.step()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("x", (try row.text(0)).?);
    try std.testing.expect(try row.isNull(1));
}

test "named parameters local" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();
    try conn.exec("create table t(id integer primary key, name text);", .{});

    var ins = try conn.prepare("insert into t(id, name) values (:id, :name);");
    defer ins.deinit();
    try ins.bindNamedInt(":id", 1);
    try ins.bindNamedText(":name", "bob");
    try ins.execute();

    // Struct field names resolve with :/@/$ prefixes.
    try conn.execute(
        "insert into t(id, name) values (:id, :name);",
        .{ .id = @as(i64, 2), .name = "cara" },
    );

    var sel = try conn.prepare("select name from t where id = :id;");
    defer sel.deinit();
    try sel.bind(.{ .id = @as(i64, 2) });
    const row = (try sel.step()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("cara", (try row.text(0)).?);
}

test "batch local transactional" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();
    try conn.exec("create table t(x integer);", .{});

    const result = try conn.batch(&.{
        .{ .sql = "insert into t(x) values (?1)", .args = &.{Value.fromInt(1)} },
        .{ .sql = "insert into t(x) values (?1)", .args = &.{Value.fromInt(2)} },
    });
    try std.testing.expectEqual(@as(usize, 2), result.steps_run);

    var sel = try conn.prepare("select count(*) from t;");
    defer sel.deinit();
    const row = (try sel.step()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 2), try row.int(0));
}

test "empty blob and text bind as non-null" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();
    try conn.exec("create table t(b blob, s text);", .{});
    var ins = try conn.prepare("insert into t(b, s) values (?1, ?2);");
    defer ins.deinit();
    try ins.bindBlob(1, "");
    try ins.bindText(2, "");
    try ins.execute();

    var sel = try conn.prepare("select b, s from t;");
    defer sel.deinit();
    const row = (try sel.step()) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!(try row.isNull(0)));
    try std.testing.expect(!(try row.isNull(1)));
    try std.testing.expectEqualStrings("", (try row.blob(0)).?);
    try std.testing.expectEqualStrings("", (try row.text(1)).?);
}

test "prepare rejects trailing statement" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();
    try std.testing.expectError(error.Sql, conn.prepare("select 1; select 2;"));
    // A single statement with a trailing `;` and whitespace still prepares.
    var ok = try conn.prepare("select 1;  ");
    ok.deinit();
}

test "bind rejects argument count mismatch" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();
    try conn.exec("create table t(a integer, b integer);", .{});
    var ins = try conn.prepare("insert into t(a, b) values (?1, ?2);");
    defer ins.deinit();
    try std.testing.expectError(error.Bind, ins.bind(.{1}));
    // Empty args against a parameterized statement must also fail closed.
    try std.testing.expectError(error.Bind, conn.execute("insert into t(a, b) values (?1, ?2);", .{}));
}

test "statement execute is idempotent after done" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();
    try conn.exec("create table t(x integer);", .{});
    var ins = try conn.prepare("insert into t(x) values (1);");
    defer ins.deinit();
    try ins.execute();
    try ins.execute(); // no-op: must not insert a second row
    var sel = try conn.prepare("select count(*) from t;");
    defer sel.deinit();
    const row = (try sel.step()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1), try row.int(0));
}

test "batch local rolls back on error" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();
    try conn.exec("create table t(x integer primary key);", .{});

    const batch_result = conn.batch(&.{
        .{ .sql = "insert into t(x) values (1)" },
        .{ .sql = "insert into t(x) values (1)" }, // PK conflict
    });
    try std.testing.expectError(error.Constraint, batch_result);

    var sel = try conn.prepare("select count(*) from t;");
    defer sel.deinit();
    const row = (try sel.step()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 0), try row.int(0));
}

test "constraint violation is typed Constraint" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();
    try conn.exec("create table t(x integer primary key);", .{});
    try conn.exec("insert into t(x) values (1);", .{});
    try std.testing.expectError(error.Constraint, conn.exec("insert into t(x) values (1);", .{}));
    try std.testing.expect((try conn.lastErrorCode()) != 0);
    try std.testing.expect((try conn.lastErrorMessage()).len > 0);
}

test "read_only open rejects writes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const db_path = try std.fs.path.join(gpa, &.{ dir_path, "ro.db" });
    defer gpa.free(db_path);

    {
        var db = try Database.open(gpa, .{ .path = db_path });
        defer db.deinit();
        var conn = db.connect();
        try conn.exec("create table t(x integer);", .{});
    }
    {
        var db = try Database.open(gpa, .{ .path = db_path, .read_only = true, .create = false });
        defer db.deinit();
        var conn = db.connect();
        // SQLITE_READONLY maps to error.Io.
        try std.testing.expectError(error.Io, conn.exec("insert into t(x) values (1);", .{}));
    }
}

test "connection fails closed after conn_gen bump" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();
    try conn.exec("create table t(x integer);", .{});

    // Simulate sync() invalidating open connections without closing the handle.
    db.conn_gen +%= 1;
    try std.testing.expectError(error.Open, conn.exec("insert into t(x) values (1);", .{}));
    try std.testing.expectError(error.Open, conn.prepare("select 1;"));

    // Reconnect after generation bump succeeds.
    var conn2 = db.connect();
    try conn2.exec("insert into t(x) values (1);", .{});
}

test "connection fails closed when local_db is null" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    if (db.local_db) |handle| {
        _ = c.sqlite3_close_v2(handle);
        db.local_db = null;
    }
    db.conn_gen +%= 1;
    var conn = db.connect();
    try std.testing.expectError(error.Open, conn.exec("select 1;", .{}));
    // A dead/null local handle fails closed rather than returning ""/0 sentinels.
    try std.testing.expectError(error.Unsupported, conn.lastErrorMessage());
    try std.testing.expectError(error.Unsupported, conn.lastErrorCode());
}

test "lastErrorMessage after bad SQL" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();
    try std.testing.expectError(error.Sql, conn.exec("not valid sql;;;", .{}));
    try std.testing.expect((try conn.lastErrorMessage()).len > 0);
    try std.testing.expect((try conn.lastErrorCode()) != 0);
}

test "remote diagnostics fail closed" {
    // Remote connections have no SQLite handle: both accessors must fail closed
    // with error.Unsupported rather than regress to the old ""/0 sentinels.
    const conn: Connection = .{ .allocator = std.testing.allocator, .kind = .remote };
    try std.testing.expectError(error.Unsupported, conn.lastErrorMessage());
    try std.testing.expectError(error.Unsupported, conn.lastErrorCode());
}

// Consumer contract: auth-style session store (mirrors rusty auth.db schema).
test "auth store contract put get clear" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();

    try conn.exec(
        \\PRAGMA journal_mode=DELETE;
        \\CREATE TABLE IF NOT EXISTS meta (
        \\  key   TEXT PRIMARY KEY,
        \\  value TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS session (
        \\  id              INTEGER PRIMARY KEY CHECK (id = 1),
        \\  clerk_user_id   TEXT NOT NULL,
        \\  email           TEXT,
        \\  access_token    TEXT NOT NULL,
        \\  refresh_token   TEXT,
        \\  expires_at      INTEGER NOT NULL,
        \\  scopes          TEXT,
        \\  updated_at      INTEGER NOT NULL
        \\);
        \\INSERT OR IGNORE INTO meta(key, value) VALUES('schema_version', '1');
    , .{});

    {
        var ins = try conn.prepare(
            \\INSERT INTO session(id, clerk_user_id, email, access_token, refresh_token, expires_at, scopes, updated_at)
            \\VALUES(1, ?1, ?2, ?3, ?4, ?5, ?6, ?7)
            \\ON CONFLICT(id) DO UPDATE SET
            \\  clerk_user_id=excluded.clerk_user_id,
            \\  email=excluded.email,
            \\  access_token=excluded.access_token,
            \\  refresh_token=excluded.refresh_token,
            \\  expires_at=excluded.expires_at,
            \\  scopes=excluded.scopes,
            \\  updated_at=excluded.updated_at;
        );
        defer ins.deinit();
        try ins.bindText(1, "user_abc");
        try ins.bindText(2, "dev@example.com");
        try ins.bindText(3, "access-secret");
        try ins.bindText(4, "refresh-secret");
        try ins.bindInt(5, 1_700_000_000);
        try ins.bindText(6, "profile email");
        try ins.bindInt(7, 1_700_000_000);
        try ins.execute();
    }

    {
        var sel = try conn.prepare(
            \\SELECT clerk_user_id, email, access_token, refresh_token, expires_at, scopes, updated_at
            \\FROM session WHERE id = 1;
        );
        defer sel.deinit();
        const row = (try sel.step()) orelse return error.TestUnexpectedResult;
        // Column text is borrowed; consumers must dupe before next step/deinit.
        const user_id = try gpa.dupe(u8, (try row.text(0)).?);
        defer gpa.free(user_id);
        const email = try gpa.dupe(u8, (try row.text(1)).?);
        defer gpa.free(email);
        const access = try gpa.dupe(u8, (try row.text(2)).?);
        defer gpa.free(access);
        const refresh = try gpa.dupe(u8, (try row.text(3)).?);
        defer gpa.free(refresh);
        try std.testing.expectEqualStrings("user_abc", user_id);
        try std.testing.expectEqualStrings("dev@example.com", email);
        try std.testing.expectEqualStrings("access-secret", access);
        try std.testing.expectEqualStrings("refresh-secret", refresh);
        try std.testing.expectEqual(@as(i64, 1_700_000_000), try row.int(4));
        try std.testing.expectEqualStrings("profile email", (try row.text(5)).?);
        try std.testing.expectEqual(@as(i64, 1_700_000_000), try row.int(6));
    }

    // Optional columns: bindNull for missing email / refresh / scopes.
    {
        var ins = try conn.prepare(
            \\INSERT INTO session(id, clerk_user_id, email, access_token, refresh_token, expires_at, scopes, updated_at)
            \\VALUES(1, ?1, ?2, ?3, ?4, ?5, ?6, ?7)
            \\ON CONFLICT(id) DO UPDATE SET
            \\  clerk_user_id=excluded.clerk_user_id,
            \\  email=excluded.email,
            \\  access_token=excluded.access_token,
            \\  refresh_token=excluded.refresh_token,
            \\  expires_at=excluded.expires_at,
            \\  scopes=excluded.scopes,
            \\  updated_at=excluded.updated_at;
        );
        defer ins.deinit();
        try ins.bindText(1, "user_xyz");
        try ins.bindNull(2);
        try ins.bindText(3, "tok");
        try ins.bindNull(4);
        try ins.bindInt(5, 42);
        try ins.bindNull(6);
        try ins.bindInt(7, 43);
        try ins.execute();
    }

    {
        var sel = try conn.prepare(
            \\SELECT clerk_user_id, email, access_token, refresh_token, scopes FROM session WHERE id = 1;
        );
        defer sel.deinit();
        const row = (try sel.step()) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("user_xyz", (try row.text(0)).?);
        try std.testing.expect((try row.text(1)) == null);
        try std.testing.expectEqualStrings("tok", (try row.text(2)).?);
        try std.testing.expect((try row.text(3)) == null);
        try std.testing.expect((try row.text(4)) == null);
    }

    try conn.exec("DELETE FROM session WHERE id = 1;", .{});
    {
        var sel = try conn.prepare("SELECT 1 FROM session WHERE id = 1;");
        defer sel.deinit();
        try std.testing.expect((try sel.step()) == null);
    }
}
