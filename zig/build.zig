const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Third-party deps. mvzr (pure-Zig regex) per D4. libxev deferred per D7.
    const mvzr_dep = b.dependency("mvzr", .{ .target = target, .optimize = optimize });
    const mvzr_mod = mvzr_dep.module("mvzr");

    // Core library module — re-exports parser/memory/dispatcher/providers.
    const zeroclaw_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zeroclaw_mod.addImport("mvzr", mvzr_mod);
    zeroclaw_mod.addIncludePath(b.path("vendor/sqlite3"));
    zeroclaw_mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite3/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
        },
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zeroclaw",
        .root_module = zeroclaw_mod,
    });
    linkSqlite(b, lib);
    b.installArtifact(lib);

    // ─── Eval runner binaries ────────────────────────────────────────────
    // Each binary reads stdin, runs the corresponding pilot subsystem,
    // writes canonical JSON to stdout. Mirrors eval-tools/ on the Rust side.

    const eval_parser_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/eval_parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    eval_parser_mod.addImport("zeroclaw", zeroclaw_mod);
    const eval_parser_exe = b.addExecutable(.{
        .name = "eval-parser",
        .root_module = eval_parser_mod,
    });
    linkSqlite(b, eval_parser_exe);
    b.installArtifact(eval_parser_exe);

    const eval_memory_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/eval_memory.zig"),
        .target = target,
        .optimize = optimize,
    });
    eval_memory_mod.addImport("zeroclaw", zeroclaw_mod);
    const eval_memory_exe = b.addExecutable(.{
        .name = "eval-memory",
        .root_module = eval_memory_mod,
    });
    linkSqlite(b, eval_memory_exe);
    b.installArtifact(eval_memory_exe);

    const eval_dispatcher_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/eval_dispatcher.zig"),
        .target = target,
        .optimize = optimize,
    });
    eval_dispatcher_mod.addImport("zeroclaw", zeroclaw_mod);
    const eval_dispatcher_exe = b.addExecutable(.{
        .name = "eval-dispatcher",
        .root_module = eval_dispatcher_mod,
    });
    linkSqlite(b, eval_dispatcher_exe);
    b.installArtifact(eval_dispatcher_exe);

    const eval_providers_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/eval_providers.zig"),
        .target = target,
        .optimize = optimize,
    });
    eval_providers_mod.addImport("zeroclaw", zeroclaw_mod);
    const eval_providers_exe = b.addExecutable(.{
        .name = "eval-providers",
        .root_module = eval_providers_mod,
    });
    linkSqlite(b, eval_providers_exe);
    b.installArtifact(eval_providers_exe);

    // ─── Test step ───────────────────────────────────────────────────────
    const lib_unit_tests = b.addTest(.{ .root_module = zeroclaw_mod });
    linkSqlite(b, lib_unit_tests);
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // ─── Benchmark step ──────────────────────────────────────────────────
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/agent_benchmarks.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("zeroclaw", zeroclaw_mod);
    const bench_exe = b.addExecutable(.{
        .name = "agent-benchmarks",
        .root_module = bench_mod,
    });
    linkSqlite(b, bench_exe);
    b.installArtifact(bench_exe);

    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run cross-language-comparable benchmarks");
    bench_step.dependOn(&bench_run.step);
}

fn linkSqlite(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.addIncludePath(b.path("vendor/sqlite3"));
    compile.linkLibC();
}
