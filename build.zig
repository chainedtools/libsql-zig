const std = @import("std");

/// Local C engine amalgamation. Only one can be linked (same SQLite symbols).
pub const Engine = enum {
    /// Stock SQLite amalgamation under `vendor/` (default; 0.2 consumers).
    sqlite,
    /// libSQL fork amalgamation under `vendor/libsql/` (R3b WAL inject path).
    libsql,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const engine = b.option(
        Engine,
        "engine",
        "Local amalgamation: sqlite (default) or libsql (R3b inject prerequisite)",
    ) orelse .sqlite;

    const enable_rust_bridge = b.option(
        bool,
        "enable-rust-bridge",
        "Load rusty-built libsql_bridge cdylib for classic embedded replica sync",
    ) orelse false;
    const rust_bridge_lib = b.option(
        []const u8,
        "rust-bridge-lib",
        "Path to liblibsql_bridge shared library (empty = platform default name / loader path)",
    ) orelse "";

    const build_options = b.addOptions();
    build_options.addOption(Engine, "engine", engine);
    build_options.addOption(bool, "enable_rust_bridge", enable_rust_bridge);
    build_options.addOption([]const u8, "rust_bridge_lib", rust_bridge_lib);

    // Amalgamation is ~260k lines of C. Optimizing it at -O2 dominates cold
    // `zig build` time for consumers (rusty / pms-sdk). Strategy:
    // - Always -g0 (no DWARF) so Debug Zig apps do not pay multi-GB debug-info.
    // - Match C opt to the *consumer* optimize mode: Debug → -O0 (fast compile),
    //   Release* → -O2 (fast runtime). Override with -Damalg-optimize=… when needed.
    const amalg_optimize = b.option(
        std.builtin.OptimizeMode,
        "amalg-optimize",
        "Optimize mode for the SQLite amalgamation C unit (default: follow package optimize)",
    ) orelse optimize;

    const c_opt_flag: []const u8 = switch (amalg_optimize) {
        .Debug => "-O0",
        // Safe/Fast: full opt. Small: still -O2 for the amalgamation — -Os on
        // sqlite3.c is rarely worth the extra compile time vs size savings here.
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => "-O2",
    };

    const sqlite_flags = [_][]const u8{
        "-std=c99",
        c_opt_flag,
        "-g0",
        // Thread-safe default (matches multi-threaded Zig consumers).
        "-DSQLITE_THREADSAFE=1",
        // Compatibility contract: enforces foreign-key constraints by default
        // for EVERY local database opened through this library (upstream SQLite
        // ships them off), so consumers relying on stock defaults must account
        // for it.
        "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
        // Embedded: no dynamic extension loading unless we opt in later.
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        // Compatibility contract: disables the double-quoted-string misfeature,
        // changing SQL parsing semantics so a "..." token is always an
        // identifier, never a string literal. Affects every local database
        // opened through this library.
        "-DSQLITE_DQS=0",
    };

    const engine_c = switch (engine) {
        .sqlite => b.path("vendor/sqlite3.c"),
        .libsql => b.path("vendor/libsql/sqlite3.c"),
    };
    const engine_include = switch (engine) {
        .sqlite => b.path("vendor"),
        .libsql => b.path("vendor/libsql"),
    };

    // Single amalgamation compile unit shared by the public module and tests.
    // Compiles the selected engine (`-Dengine=sqlite|libsql`) exactly once.
    // Stub Zig module optimize tracks amalg_optimize so the cache key matches
    // the C flags (Debug stub + -O0 C vs ReleaseFast + -O2 C).
    const engine_mod = b.createModule(.{
        .root_source_file = b.path("src/c/engine_stub.zig"),
        .target = target,
        .optimize = amalg_optimize,
        .link_libc = true,
    });
    engine_mod.addCSourceFile(.{
        .file = engine_c,
        .flags = &sqlite_flags,
    });
    engine_mod.addIncludePath(engine_include);

    const engine_lib = b.addLibrary(.{
        .name = "sqlite_amalg",
        .linkage = .static,
        .root_module = engine_mod,
    });

    const mod = b.addModule("zig_libsql", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.linkLibrary(engine_lib);
    mod.addIncludePath(engine_include);
    mod.addOptions("build_options", build_options);
    // DynLib for optional rust bridge.
    if (enable_rust_bridge) {
        mod.link_libcpp = false;
    }

    const exe = b.addExecutable(.{
        .name = "zig_libsql",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_libsql", .module = mod },
            },
            .link_libc = true,
        }),
    });
    // Amalgamation is linked through the zig_libsql module graph.
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the demo CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests live in `src/tests.zig` so that `src/root.zig` stays limited to
    // public exports + version. Link the same amalgamation static lib (no second
    // sqlite3.c compile). Cannot `addImport("zig_libsql", mod)` — Zig forbids
    // the same source file existing in two modules of one compilation.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.linkLibrary(engine_lib);
    test_mod.addIncludePath(engine_include);
    test_mod.addOptions("build_options", build_options);

    const mod_tests = b.addTest(.{
        .root_module = test_mod,
    });
    // DynLib needs libdl on Linux.
    if (enable_rust_bridge and target.result.os.tag == .linux) {
        mod_tests.root_module.linkSystemLibrary("dl", .{});
        test_mod.linkSystemLibrary("dl", .{});
        mod.linkSystemLibrary("dl", .{});
    }
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run library and CLI tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // --- rusty bridge (optional) ---
    const bridge_step = b.step("bridge", "Build libsql_bridge cdylib with rusty");
    const rusty_build = b.addSystemCommand(&.{ "rusty", "build" });
    rusty_build.setCwd(b.path("bridge"));
    rusty_build.setEnvironmentVariable("CARGO_TERM_COLOR", "always");
    bridge_step.dependOn(&rusty_build.step);
}
