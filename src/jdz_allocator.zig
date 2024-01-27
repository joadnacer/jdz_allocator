const std = @import("std");
const builtin = @import("builtin");

const local_allocator = @import("local_allocator.zig");

pub const JdzAllocator = local_allocator.JdzAllocator;

pub const JdzAllocConfig = struct {
    /// backing allocator
    backing_allocator: std.mem.Allocator = std.heap.page_allocator,

    /// Whether to use this allocator as a global allocator using threadlocal arenas
    global_allocator: bool = false,

    /// controls batch span allocation amount for one span allocations
    /// will return 1 span to allocating function and all remaining spans will be written to the one span cache
    span_alloc_count: u32 = 64,

    /// controls batch memory mapping amount in spans
    /// overhead from desired span count will be saved to map_cache for reuse on future map requests
    /// as memory mapping will likely not be aligned, we will use 1 span worth of padding per map call
    /// padding may be used as a span if alignment allows it
    /// minimum is 1 (not recommended) - default is 64, resulting in 4MiB memory mapping + 64KiB padding
    map_alloc_count: u32 = 64,

    /// maximum number of spans in arena cache
    cache_limit: u32 = 64,

    /// maximum number spans in arena large caches
    large_cache_limit: u32 = 64,

    /// maximum number of spans in arena map cache
    map_cache_limit: u32 = 16,

    /// percentage overhead applied to span count when looking for a large span in cache
    /// increases cache hits and memory usage, but does hurt performance
    large_span_overhead_mul: f64 = 0.5,

    /// cache large spans as normal spans if self.large_cache_upper_limit is hit
    recycle_large_spans: bool = true,

    /// if cached large spans should be split to accomodate small or medium allocations
    /// improves memory usage but hurts performance
    split_large_spans_to_one: bool = true,

    /// if cached large spans should be split to accomodate smaller large allocations
    /// improves memory usage but hurts performance
    split_large_spans_to_large: bool = true,

    /// if leaks should be reported
    report_leaks: bool = true,

    /// Whether to synchronize usage of this allocator.
    /// For actual thread safety, the backing allocator must also be thread safe.
    thread_safe: bool = !builtin.single_threaded,
};

///
/// Tests
///
const static_config = @import("static_config.zig");
const utils = @import("utils.zig");

const log2 = std.math.log2;
const testing = std.testing;

const span_max = static_config.span_max;
const small_max = static_config.small_max;
const large_max = static_config.large_max;
const page_alignment = static_config.page_alignment;

test "small allocations - free in same order" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    var list = std.ArrayList(*u64).init(std.testing.allocator);
    defer list.deinit();

    var i: usize = 0;
    while (i < 513) : (i += 1) {
        const ptr = try allocator.create(u64);
        try list.append(ptr);
    }

    for (list.items) |ptr| {
        allocator.destroy(ptr);
    }
}

test "small allocations - free in reverse order" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    var list = std.ArrayList(*u64).init(std.testing.allocator);
    defer list.deinit();

    var i: usize = 0;
    while (i < 513) : (i += 1) {
        const ptr = try allocator.create(u64);
        try list.append(ptr);
    }

    while (list.popOrNull()) |ptr| {
        allocator.destroy(ptr);
    }
}

test "small allocations - alloc free alloc" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    const a = try allocator.create(u64);
    allocator.destroy(a);
    const b = try allocator.create(u64);
    allocator.destroy(b);
}

test "large allocations" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    const ptr1 = try allocator.alloc(u64, 42768);
    const ptr2 = try allocator.alloc(u64, 52768);
    allocator.free(ptr1);
    const ptr3 = try allocator.alloc(u64, 62768);
    allocator.free(ptr3);
    allocator.free(ptr2);
}

test "very large allocation" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, std.math.maxInt(usize)));
}

test "realloc" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    var slice = try allocator.alignedAlloc(u8, @alignOf(u32), 1);
    defer allocator.free(slice);
    slice[0] = 0x12;

    // This reallocation should keep its pointer address.
    const old_slice = slice;
    slice = try allocator.realloc(slice, 2);
    try std.testing.expect(old_slice.ptr == slice.ptr);
    try std.testing.expect(slice[0] == 0x12);
    slice[1] = 0x34;

    // This requires upgrading to a larger bin size
    slice = try allocator.realloc(slice, 17);
    try std.testing.expect(old_slice.ptr != slice.ptr);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[1] == 0x34);
}

test "shrink" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    var slice = try allocator.alloc(u8, 20);
    defer allocator.free(slice);

    @memset(slice, 0x11);

    try std.testing.expect(allocator.resize(slice, 17));
    slice = slice[0..17];

    for (slice) |b| {
        try std.testing.expect(b == 0x11);
    }

    try std.testing.expect(allocator.resize(slice, 16));

    for (slice) |b| {
        try std.testing.expect(b == 0x11);
    }
}

test "large object - grow" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    var slice1 = try allocator.alloc(u8, 8192 - 20);
    defer allocator.free(slice1);

    const old = slice1;
    slice1 = try allocator.realloc(slice1, 8192 - 10);
    try std.testing.expect(slice1.ptr == old.ptr);

    slice1 = try allocator.realloc(slice1, 8192);
    try std.testing.expect(slice1.ptr == old.ptr);

    slice1 = try allocator.realloc(slice1, 8192 + 1);
}

test "realloc small object to large object" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    var slice = try allocator.alloc(u8, 70);
    defer allocator.free(slice);
    slice[0] = 0x12;
    slice[60] = 0x34;

    // This requires upgrading to a large object
    const large_object_size = 8192 + 50;
    slice = try allocator.realloc(slice, large_object_size);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[60] == 0x34);
}

test "shrink large object to large object" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    var slice = try allocator.alloc(u8, 8192 + 50);
    defer allocator.free(slice);
    slice[0] = 0x12;
    slice[60] = 0x34;

    if (!allocator.resize(slice, 8192 + 1)) return;
    slice = slice.ptr[0 .. 8192 + 1];
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[60] == 0x34);

    try std.testing.expect(allocator.resize(slice, 8192 + 1));
    slice = slice[0 .. 8192 + 1];
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[60] == 0x34);

    slice = try allocator.realloc(slice, 8192);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[60] == 0x34);
}

test "shrink large object to large object with larger alignment" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    var debug_buffer: [1000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&debug_buffer);
    const debug_allocator = fba.allocator();

    const alloc_size = 8192 + 50;
    var slice = try allocator.alignedAlloc(u8, 16, alloc_size);
    defer allocator.free(slice);

    const big_alignment: usize = switch (builtin.os.tag) {
        .windows => 65536, // Windows aligns to 64K.
        else => 8192,
    };
    // This loop allocates until we find a page that is not aligned to the big
    // alignment. Then we shrink the allocation after the loop, but increase the
    // alignment to the higher one, that we know will force it to realloc.
    var stuff_to_free = std.ArrayList([]align(16) u8).init(debug_allocator);
    while (std.mem.isAligned(@intFromPtr(slice.ptr), big_alignment)) {
        try stuff_to_free.append(slice);
        slice = try allocator.alignedAlloc(u8, 16, alloc_size);
    }
    while (stuff_to_free.popOrNull()) |item| {
        allocator.free(item);
    }
    slice[0] = 0x12;
    slice[60] = 0x34;

    slice = try allocator.reallocAdvanced(slice, big_alignment, alloc_size / 2);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[60] == 0x34);
}

test "realloc large object to small object" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    var slice = try allocator.alloc(u8, 8192 + 50);
    defer allocator.free(slice);
    slice[0] = 0x12;
    slice[16] = 0x34;

    slice = try allocator.realloc(slice, 19);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[16] == 0x34);
}

test "realloc large object to larger alignment" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    var debug_buffer: [1000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&debug_buffer);
    const debug_allocator = fba.allocator();

    var slice = try allocator.alignedAlloc(u8, 16, 8192 + 50);
    defer allocator.free(slice);

    const big_alignment: usize = switch (builtin.os.tag) {
        .windows => 65536, // Windows aligns to 64K.
        else => 8192,
    };
    // This loop allocates until we find a page that is not aligned to the big alignment.
    var stuff_to_free = std.ArrayList([]align(16) u8).init(debug_allocator);
    while (std.mem.isAligned(@intFromPtr(slice.ptr), big_alignment)) {
        try stuff_to_free.append(slice);
        slice = try allocator.alignedAlloc(u8, 16, 8192 + 50);
    }
    while (stuff_to_free.popOrNull()) |item| {
        allocator.free(item);
    }
    slice[0] = 0x12;
    slice[16] = 0x34;

    slice = try allocator.reallocAdvanced(slice, 32, 8192 + 100);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[16] == 0x34);

    slice = try allocator.reallocAdvanced(slice, 32, 8192 + 25);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[16] == 0x34);

    slice = try allocator.reallocAdvanced(slice, big_alignment, 8192 + 100);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[16] == 0x34);
}

test "large object shrinks to small" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    var slice = try allocator.alloc(u8, 8192 + 50);
    defer allocator.free(slice);

    try std.testing.expect(allocator.resize(slice, 4));
}

test "objects of size 1024 and 2048" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    const slice = try allocator.alloc(u8, 1025);
    const slice2 = try allocator.alloc(u8, 3000);

    allocator.free(slice);
    allocator.free(slice2);
}

test "max large alloc" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    const buf = try allocator.alloc(u8, large_max);
    defer allocator.free(buf);
}

test "small alignment small alloc" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    const slice = allocator.rawAlloc(1, 4, @returnAddress()).?;
    defer allocator.rawFree(slice[0..1], 4, @returnAddress());

    try std.testing.expect(@intFromPtr(slice) % std.math.pow(u16, 2, 4) == 0);
}

test "medium alignment small alloc" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    const alignment: u8 = @truncate(log2(utils.roundUpToPowerOfTwo(small_max + 1)));

    if (alignment > page_alignment) return error.SkipZigTest;

    const slice = allocator.rawAlloc(1, alignment, @returnAddress()).?;
    defer allocator.rawFree(slice[0..1], alignment, @returnAddress());

    try std.testing.expect(@intFromPtr(slice) % std.math.pow(u16, 2, 4) == 0);
}

test "page size alignment small alloc" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    const slice = allocator.rawAlloc(1, page_alignment, @returnAddress()).?;
    defer allocator.rawFree(slice[0..1], page_alignment, @returnAddress());

    try std.testing.expect(@intFromPtr(slice) % std.math.pow(u16, 2, page_alignment) == 0);
}

test "small alignment large alloc" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    const slice = allocator.rawAlloc(span_max, 4, @returnAddress()).?;
    defer allocator.rawFree(slice[0..span_max], 4, @returnAddress());

    try std.testing.expect(@intFromPtr(slice) % std.math.pow(u16, 2, 4) == 0);
}

test "medium alignment large alloc" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    const alignment: u8 = @truncate(log2(utils.roundUpToPowerOfTwo(small_max + 1)));

    if (alignment > page_alignment) return error.SkipZigTest;

    const slice = allocator.rawAlloc(span_max, alignment, @returnAddress()).?;
    defer allocator.rawFree(slice[0..span_max], alignment, @returnAddress());

    try std.testing.expect(@intFromPtr(slice) % std.math.pow(u16, 2, 4) == 0);
}

test "page size alignment large alloc" {
    var jdz_allocator = JdzAllocator(.{}).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    const slice = allocator.rawAlloc(span_max, page_alignment, @returnAddress()).?;
    defer allocator.rawFree(slice[0..span_max], page_alignment, @returnAddress());

    try std.testing.expect(@intFromPtr(slice) % std.math.pow(u16, 2, page_alignment) == 0);
}

test "deinitThread" {
    var jdz_allocator = JdzAllocator(.{ .global_allocator = true }).init();
    defer jdz_allocator.deinit();
    const allocator = jdz_allocator.allocator();

    const slice = try allocator.alloc(u8, 8);
    allocator.free(slice);

    jdz_allocator.deinitThread();
}
