const std = @import("std");
const libsql = @import("zig_libsql");

/// Demo CLI: `zig build run -- [path] [sql]`
/// Defaults: path=`:memory:`, sql=`select 1 as n;`
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    // args[0] is executable name when present.
    var path: []const u8 = ":memory:";
    var sql: []const u8 = "select 1 as n;";
    if (args.len >= 2) path = args[1];
    if (args.len >= 3) sql = args[2];

    var db = libsql.Database.open(arena, .{ .path = path }) catch |e| {
        std.debug.print("open failed: {s}\n", .{@errorName(e)});
        return e;
    };
    defer db.deinit();

    var conn = db.connect();

    // A local prepare compiles only the first statement and silently drops the
    // remainder (sqlite3_prepare_v2's tail is ignored), so a multi-statement
    // script would run only its first statement. Detect that up front and route
    // the whole script through exec, which executes every statement.
    if (hasTrailingStatement(sql)) {
        conn.exec(sql, .{}) catch |e| {
            std.debug.print("exec failed: {s}\n", .{@errorName(e)});
            return e;
        };
        std.debug.print("ok (engine {s}, zig-libsql {s})\n", .{
            libsql.engineVersion(),
            libsql.version,
        });
        return;
    }

    // Fail closed: propagate prepare errors rather than blindly re-running the
    // input through exec, which would mask syntax/allocation/database failures.
    var stmt = conn.prepare(sql) catch |e| {
        std.debug.print("prepare failed: {s}\n", .{@errorName(e)});
        return e;
    };
    defer stmt.deinit();

    var row_i: usize = 0;
    while (try stmt.step()) |row| {
        const n = row.columnCount();
        if (row_i == 0) {
            var col: usize = 0;
            while (col < n) : (col += 1) {
                if (col > 0) std.debug.print("|", .{});
                const name = try row.columnName(col);
                std.debug.print("{s}", .{name});
            }
            std.debug.print("\n", .{});
        }
        var col: usize = 0;
        while (col < n) : (col += 1) {
            if (col > 0) std.debug.print("|", .{});
            if (try row.isNull(col)) {
                std.debug.print("NULL", .{});
            } else {
                const ty = try row.columnType(col);
                switch (ty) {
                    libsql.column_type.integer => std.debug.print("{d}", .{try row.int(col)}),
                    libsql.column_type.float => std.debug.print("{d}", .{try row.float(col)}),
                    libsql.column_type.blob => {
                        const b = (try row.blob(col)) orelse &[_]u8{};
                        std.debug.print("<blob {d} bytes>", .{b.len});
                    },
                    else => {
                        const t = (try row.text(col)) orelse "";
                        std.debug.print("{s}", .{t});
                    },
                }
            }
        }
        std.debug.print("\n", .{});
        row_i += 1;
    }

    if (row_i == 0) {
        std.debug.print("ok (engine {s}, zig-libsql {s})\n", .{
            libsql.engineVersion(),
            libsql.version,
        });
    }
}

/// True when `sql` contains a further statement after the first top-level `;`.
/// Quote- and comment-aware so that semicolons inside string literals, quoted
/// identifiers, or comments are not treated as statement separators, and a
/// trailing comment / whitespace after the final statement does not count.
fn hasTrailingStatement(sql: []const u8) bool {
    var i: usize = 0;
    var seen_semicolon = false;
    while (i < sql.len) : (i += 1) {
        const ch = sql[i];
        switch (ch) {
            '\'', '"', '`' => {
                // Skip a quoted string / identifier; a doubled quote escapes.
                const q = ch;
                i += 1;
                while (i < sql.len) : (i += 1) {
                    if (sql[i] == q) {
                        if (i + 1 < sql.len and sql[i + 1] == q) {
                            i += 1;
                        } else break;
                    }
                }
            },
            '-' => {
                if (i + 1 < sql.len and sql[i + 1] == '-') {
                    i += 2;
                    while (i < sql.len and sql[i] != '\n') : (i += 1) {}
                }
            },
            '/' => {
                if (i + 1 < sql.len and sql[i + 1] == '*') {
                    i += 2;
                    while (i + 1 < sql.len and !(sql[i] == '*' and sql[i + 1] == '/')) : (i += 1) {}
                    i += 1; // skip closing '/'
                }
            },
            ';' => seen_semicolon = true,
            else => {
                // Any non-whitespace token after the first separator is a
                // second statement to run.
                if (seen_semicolon and !std.ascii.isWhitespace(ch)) return true;
            },
        }
    }
    return false;
}

test "cli module loads" {
    try std.testing.expect(libsql.version.len > 0);
}

test "hasTrailingStatement detects multi-statement scripts" {
    try std.testing.expect(!hasTrailingStatement("select 1 as n;"));
    try std.testing.expect(!hasTrailingStatement("select 1 as n"));
    try std.testing.expect(!hasTrailingStatement("select 1;   "));
    try std.testing.expect(!hasTrailingStatement("select 1; -- trailing comment"));
    try std.testing.expect(!hasTrailingStatement("select ';' as s;"));
    try std.testing.expect(hasTrailingStatement("create table t(a); insert into t values(1);"));
    try std.testing.expect(hasTrailingStatement("select 1; select 2"));
}
