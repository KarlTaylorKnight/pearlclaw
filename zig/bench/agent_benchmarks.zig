//! Cross-language-comparable benchmarks for the Zig pilot.
//!
//! Mirrors `rust/benches/agent_benchmarks.rs` (criterion). Each benchmark
//! has the same ID as on the Rust side. Output is the common JSON schema
//! consumed by `benches/runner/normalize.py`.
//!
//! Methodology (matches criterion):
//!   - Warm-up: 3 s or 100 iterations, whichever first.
//!   - 100 samples per bench.
//!   - Each sample = N iterations sized so the batch >= 10 ms.
//!   - Reports mean / median / stddev / p99 ns-per-op.
//!   - `std.mem.doNotOptimizeAway(result)` after each call.
//!
//! Run: `zig build bench -Doptimize=ReleaseFast > raw-zig-<date>.json`

const std = @import("std");
const zeroclaw = @import("zeroclaw");

const Sample = struct {
    iterations: u64,
    duration_ns: u64,
};

const BenchResult = struct {
    id: []const u8,
    samples: usize,
    iterations_per_sample: u64,
    mean_ns_per_op: f64,
    median_ns_per_op: f64,
    stddev_ns_per_op: f64,
    p99_ns_per_op: f64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var results = std.ArrayList(BenchResult).init(allocator);
    defer results.deinit();

    // Parser and dispatcher benchmarks land with their dispatcher ports.
    try results.append(try benchMemoryStoreSingle(allocator));
    try results.append(try benchMemoryRecallTop10(allocator));
    try results.append(try benchMemoryCount(allocator));

    try emitJson(allocator, results.items);
}

fn emitJson(allocator: std.mem.Allocator, results: []const BenchResult) !void {
    const stdout = std.io.getStdOut().writer();
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll("{\"lang\":\"zig\",\"version\":\"");
    try w.writeAll(@import("builtin").zig_version_string);
    try w.writeAll("\",\"build_profile\":\"");
    try w.writeAll(@tagName(@import("builtin").mode));
    try w.writeAll("\",\"benchmarks\":[");
    for (results, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try w.print(
            "{{\"id\":\"{s}\",\"samples\":{d},\"iterations_per_sample\":{d},\"ns_per_op\":{{\"mean\":{d},\"median\":{d},\"stddev\":{d},\"p99\":{d}}}}}",
            .{ r.id, r.samples, r.iterations_per_sample, r.mean_ns_per_op, r.median_ns_per_op, r.stddev_ns_per_op, r.p99_ns_per_op },
        );
    }
    try w.writeAll("]}\n");
    try stdout.writeAll(buf.items);
}

/// Generic benchmark driver: warm up, run N samples, return statistics.
pub fn runBench(
    allocator: std.mem.Allocator,
    id: []const u8,
    comptime BodyFn: type,
    body: BodyFn,
    body_ctx: anytype,
) !BenchResult {
    _ = allocator;
    // Warm-up: 3 s or 100 iters.
    var timer = try std.time.Timer.start();
    var warm_iters: u64 = 0;
    while (warm_iters < 100 and timer.read() < 3 * std.time.ns_per_s) : (warm_iters += 1) {
        _ = body(body_ctx);
    }

    // Calibrate: find iterations-per-sample such that one sample >= 10 ms.
    const target_sample_ns: u64 = 10 * std.time.ns_per_ms;
    var iters_per_sample: u64 = 1;
    while (true) {
        timer.reset();
        var i: u64 = 0;
        while (i < iters_per_sample) : (i += 1) {
            _ = body(body_ctx);
        }
        const elapsed = timer.read();
        if (elapsed >= target_sample_ns or iters_per_sample > 1_000_000_000) break;
        iters_per_sample *= 2;
    }

    // Collect 100 samples.
    var samples: [100]Sample = undefined;
    for (&samples) |*s| {
        timer.reset();
        var i: u64 = 0;
        while (i < iters_per_sample) : (i += 1) {
            _ = body(body_ctx);
        }
        s.* = .{ .iterations = iters_per_sample, .duration_ns = timer.read() };
    }

    // Statistics.
    var ns_per_op: [100]f64 = undefined;
    for (samples, 0..) |s, idx| {
        ns_per_op[idx] = @as(f64, @floatFromInt(s.duration_ns)) / @as(f64, @floatFromInt(s.iterations));
    }
    std.sort.heap(f64, &ns_per_op, {}, std.sort.asc(f64));
    const median = ns_per_op[50];
    const p99 = ns_per_op[99];

    var sum: f64 = 0;
    for (ns_per_op) |v| sum += v;
    const mean = sum / 100.0;

    var ssq: f64 = 0;
    for (ns_per_op) |v| {
        const d = v - mean;
        ssq += d * d;
    }
    const stddev = @sqrt(ssq / 100.0);

    return .{
        .id = id,
        .samples = 100,
        .iterations_per_sample = iters_per_sample,
        .mean_ns_per_op = mean,
        .median_ns_per_op = median,
        .stddev_ns_per_op = stddev,
        .p99_ns_per_op = p99,
    };
}

const MemoryBenchCtx = struct {
    allocator: std.mem.Allocator,
    memory: *zeroclaw.memory.SqliteMemory,
    counter: usize = 1000,
};

fn benchMemoryStoreSingle(allocator: std.mem.Allocator) !BenchResult {
    const workspace = try tempWorkspace(allocator, "store");
    defer cleanupWorkspace(allocator, workspace);

    var mem = try zeroclaw.memory.SqliteMemory.new(allocator, workspace);
    defer mem.deinit();
    try seedMemory(allocator, &mem);

    var ctx = MemoryBenchCtx{ .allocator = allocator, .memory = &mem };
    return runBench(allocator, "memory_store_single", @TypeOf(memoryStoreBody), memoryStoreBody, &ctx);
}

fn benchMemoryRecallTop10(allocator: std.mem.Allocator) !BenchResult {
    const workspace = try tempWorkspace(allocator, "recall");
    defer cleanupWorkspace(allocator, workspace);

    var mem = try zeroclaw.memory.SqliteMemory.new(allocator, workspace);
    defer mem.deinit();
    try seedMemory(allocator, &mem);

    var ctx = MemoryBenchCtx{ .allocator = allocator, .memory = &mem };
    return runBench(allocator, "memory_recall_top10", @TypeOf(memoryRecallBody), memoryRecallBody, &ctx);
}

fn benchMemoryCount(allocator: std.mem.Allocator) !BenchResult {
    const workspace = try tempWorkspace(allocator, "count");
    defer cleanupWorkspace(allocator, workspace);

    var mem = try zeroclaw.memory.SqliteMemory.new(allocator, workspace);
    defer mem.deinit();
    try seedMemory(allocator, &mem);

    var ctx = MemoryBenchCtx{ .allocator = allocator, .memory = &mem };
    return runBench(allocator, "memory_count", @TypeOf(memoryCountBody), memoryCountBody, &ctx);
}

fn seedMemory(allocator: std.mem.Allocator, mem: *zeroclaw.memory.SqliteMemory) !void {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var key_buf: [64]u8 = undefined;
        var content_buf: [128]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{d}", .{i});
        const content = try std.fmt.bufPrint(
            &content_buf,
            "Content entry number {d} about zeroclaw agent runtime",
            .{i},
        );
        try mem.store(allocator, key, content, .core, null);
    }
}

fn memoryStoreBody(ctx: *MemoryBenchCtx) void {
    ctx.counter += 1;
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "bench_key_{d}", .{ctx.counter}) catch unreachable;
    ctx.memory.store(
        ctx.allocator,
        key,
        "Benchmark content for store operation",
        .daily,
        null,
    ) catch unreachable;
}

fn memoryRecallBody(ctx: *MemoryBenchCtx) void {
    const entries = ctx.memory.recall(ctx.allocator, "zeroclaw agent", 10, null, null, null) catch unreachable;
    std.mem.doNotOptimizeAway(entries.len);
    zeroclaw.memory.sqlite.freeEntries(ctx.allocator, entries);
}

fn memoryCountBody(ctx: *MemoryBenchCtx) void {
    const count = ctx.memory.count() catch unreachable;
    std.mem.doNotOptimizeAway(count);
}

fn tempWorkspace(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const stamp: u128 = @intCast(std.time.nanoTimestamp());
    const path = try std.fmt.allocPrint(
        allocator,
        "/tmp/zeroclaw-zig-memory-bench-{s}-{d}",
        .{ name, stamp },
    );
    errdefer allocator.free(path);
    try std.fs.cwd().makePath(path);
    return path;
}

fn cleanupWorkspace(allocator: std.mem.Allocator, path: []u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
    allocator.free(path);
}
