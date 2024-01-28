const std = @import("std");
const jdz = @import("jdz_allocator.zig");

const mixed_rounds = 10_000_000;
const mixed_min = 1;
const mixed_max = 80000;

const small_rounds = 10_000_000;
const small_min = 1;
const small_max = 2048;

const medium_rounds = 10_000_000;
const medium_min = 2049;
const medium_max = 32512;

const big_rounds = 10_000_000;
const big_min = 32513;
const big_max = 4194176;

const BUFFER_CAPACITY = 256;

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    const num_args = args.len - 1;

    if (num_args == 0) return try bench(1);

    for (0..num_args) |i| {
        const num_threads = try std.fmt.parseInt(u32, args[i + 1], 10);

        try bench(num_threads);
    }
}

fn bench(num_threads: u32) !void {
    try std.io.getStdOut().writer().print("=== Num Threads={} ===\n", .{num_threads});

    try std.io.getStdOut().writer().print("==Mixed Alloc==\n", .{});
    try jdz_mixed(num_threads);
    try jdz_global_mixed(num_threads);
    try c_mixed(num_threads);
    try gpa_mixed(num_threads);

    try std.io.getStdOut().writer().print("==Small Alloc==\n", .{});
    try jdz_small(num_threads);
    try jdz_global_small(num_threads);
    try c_small(num_threads);
    try gpa_small(num_threads);

    try std.io.getStdOut().writer().print("==Medium Alloc==\n", .{});
    try jdz_medium(num_threads);
    try jdz_global_medium(num_threads);
    try c_medium(num_threads);
    try gpa_medium(num_threads);

    try std.io.getStdOut().writer().print("==Big Alloc==\n", .{});
    try jdz_big(num_threads);
    try jdz_global_big(num_threads);
    try c_big(num_threads);
    try gpa_big(num_threads);

    try std.io.getStdOut().writer().print("\n", .{});
}

///
/// Mixed
///
fn jdz_mixed(num_threads: u32) !void {
    var jdz_allocator = jdz.JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    var allocator = jdz_allocator.allocator();

    try runPerfTestAlloc("jdz/mixed", mixed_min, mixed_max, allocator, mixed_rounds, num_threads);
}

fn jdz_global_mixed(num_threads: u32) !void {
    const jdz_allocator = jdz.JdzGlobalAllocator(.{});
    defer jdz_allocator.deinit();
    var allocator = jdz_allocator.allocator();

    try runPerfTestAlloc("jdz-global/mixed", mixed_min, mixed_max, allocator, mixed_rounds, num_threads);
}

fn gpa_mixed(num_threads: u32) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    try runPerfTestAlloc("gpa/mixed", mixed_min, mixed_max, allocator, mixed_rounds, num_threads);
}

fn c_mixed(num_threads: u32) !void {
    var allocator = std.heap.c_allocator;
    try runPerfTestAlloc("c/mixed", mixed_min, mixed_max, allocator, mixed_rounds, num_threads);
}

///
/// Small
///
fn jdz_small(num_threads: u32) !void {
    var jdz_allocator = jdz.JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    var allocator = jdz_allocator.allocator();

    try runPerfTestAlloc("jdz/small", small_min, small_max, allocator, small_rounds, num_threads);
}

fn c_small(num_threads: u32) !void {
    var allocator = std.heap.c_allocator;
    try runPerfTestAlloc("c/small", small_min, small_max, allocator, small_rounds, num_threads);
}

fn jdz_global_small(num_threads: u32) !void {
    const jdz_allocator = jdz.JdzGlobalAllocator(.{});
    defer jdz_allocator.deinit();
    var allocator = jdz_allocator.allocator();

    try runPerfTestAlloc("jdz-global/small", small_min, small_max, allocator, mixed_rounds, num_threads);
}

fn gpa_small(num_threads: u32) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    try runPerfTestAlloc("gpa/small", small_min, small_max, allocator, small_rounds, num_threads);
}

///
/// Medium
///
fn jdz_medium(num_threads: u32) !void {
    var jdz_allocator = jdz.JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    var allocator = jdz_allocator.allocator();

    try runPerfTestAlloc("jdz/medium", medium_min, medium_max, allocator, medium_rounds, num_threads);
}

fn jdz_global_medium(num_threads: u32) !void {
    const jdz_allocator = jdz.JdzGlobalAllocator(.{});
    defer jdz_allocator.deinit();
    var allocator = jdz_allocator.allocator();

    try runPerfTestAlloc("jdz-global/medium", medium_min, medium_max, allocator, mixed_rounds, num_threads);
}

fn c_medium(num_threads: u32) !void {
    var allocator = std.heap.c_allocator;
    try runPerfTestAlloc("c/medium", medium_min, medium_max, allocator, medium_rounds, num_threads);
}

fn gpa_medium(num_threads: u32) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    try runPerfTestAlloc("gpa/medium", medium_min, medium_max, allocator, medium_rounds, num_threads);
}

///
/// Big
///
fn jdz_big(num_threads: u32) !void {
    var jdz_allocator = jdz.JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    var allocator = jdz_allocator.allocator();

    try runPerfTestAlloc("jdz/big", big_min, big_max, allocator, big_rounds, num_threads);
}

fn jdz_global_big(num_threads: u32) !void {
    const jdz_allocator = jdz.JdzGlobalAllocator(.{});
    defer jdz_allocator.deinit();
    var allocator = jdz_allocator.allocator();

    try runPerfTestAlloc("jdz-global/big", big_min, big_max, allocator, mixed_rounds, num_threads);
}

fn c_big(num_threads: u32) !void {
    var allocator = std.heap.c_allocator;
    try runPerfTestAlloc("c/big", big_min, big_max, allocator, big_rounds, num_threads);
}

fn gpa_big(num_threads: u32) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    try runPerfTestAlloc("gpa/big", big_min, big_max, allocator, big_rounds, num_threads);
}

///
/// Bench Methods
///
fn threadAllocWorker(min: usize, max: usize, allocator: std.mem.Allocator, max_rounds: usize) !void {
    var slots = std.BoundedArray([]u8, BUFFER_CAPACITY){};
    var rounds: usize = max_rounds;

    var random_source = std.rand.DefaultPrng.init(1337);
    const rng = random_source.random();

    var max_fill_level: usize = 0;
    var allocs: usize = 0;
    var frees: usize = 0;

    while (rounds > 0) {
        rounds -= 1;

        const free_chance = @as(f32, @floatFromInt(slots.len)) / @as(f32, @floatFromInt(slots.buffer.len - 1)); // more elements => more frees
        const alloc_chance = 1.0 - free_chance; // more elements => less allocs
        const alloc_amount = rng.intRangeAtMost(usize, min, max);

        if (slots.len > 0) {
            if (rng.float(f32) <= free_chance) {
                var index = rng.intRangeLessThan(usize, 0, slots.len);
                var ptr = slots.swapRemove(index);
                allocator.free(ptr);

                frees += 1;
            }
        }

        if (slots.len < slots.capacity()) {
            if (rng.float(f32) <= alloc_chance) {
                var item = try allocator.alloc(u8, alloc_amount);
                slots.appendAssumeCapacity(item);

                allocs += 1;
            }
        }

        max_fill_level = @max(max_fill_level, slots.len);
    }

    for (slots.slice()) |ptr| {
        allocator.free(ptr);
    }
}

fn runPerfTestAlloc(tag: []const u8, min: usize, max: usize, allocator: std.mem.Allocator, max_rounds: usize, num_threads: u32) !void {
    var workers: []std.Thread = try std.heap.page_allocator.alloc(std.Thread, num_threads);
    defer std.heap.page_allocator.free(workers);

    const begin_time = std.time.nanoTimestamp();

    for (0..num_threads) |i| {
        workers[i] = try std.Thread.spawn(.{}, threadAllocWorker, .{ min, max, allocator, max_rounds });
    }

    for (0..num_threads) |i| {
        workers[i].join();
    }

    const end_time = std.time.nanoTimestamp();

    try std.io.getStdOut().writer().print("time={d: >10.2}us test={s} num_threads={}\n", .{
        @as(f32, @floatFromInt(end_time - begin_time)) / 1000.0, tag, num_threads,
    });
}
