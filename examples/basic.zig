//! Sketch of library usage (not a separate build target).
//! Prefer: `zig build run -- :memory: "select 1;"`

const std = @import("std");
const libsql = @import("zig_libsql");

pub fn run(allocator: std.mem.Allocator) !void {
    var db = try libsql.Database.open(allocator, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();

    try conn.exec(
        \\create table users(id integer primary key, email text not null);
        \\insert into users(email) values ('a@example.com');
    , .{});

    var stmt = try conn.prepare("select id, email from users where id = ?1;");
    defer stmt.deinit();
    try stmt.bind(.{1});

    while (try stmt.step()) |row| {
        std.debug.print("{d} {s}\n", .{ try row.int(0), (try row.text(1)).? });
    }
}
