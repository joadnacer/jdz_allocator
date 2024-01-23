const std = @import("std");
const builtin = @import("builtin");

const handler = @import("arena_handler.zig");
const global_handler = @import("global_arena_handler.zig");
const span_arena = @import("arena.zig");
const span_file = @import("span.zig");
const utils = @import("utils.zig");

const log2 = std.math.log2;
const log2_int = std.math.log2_int;
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;
const testing = std.testing;

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

var global_arena_handler: ?*anyopaque = null;

pub fn JdzAllocator(comptime config: JdzAllocConfig) type {
    const Span = span_file.Span(config);

    const GlobalArenaHandler = global_handler.GlobalArenaHandler(config);

    const ArenaHandler = if (config.global_allocator)
        *GlobalArenaHandler
    else
        handler.ArenaHandler(config);

    const Arena = span_arena.Arena(config);

    assert(config.span_alloc_count >= 1);

    // currently not supporting page sizes greater than 64KiB
    assert(page_size <= span_size);

    // -1 as one span gets allocated to span list and not cache
    assert(config.span_alloc_count - 1 <= config.cache_limit);

    assert(span_header_size >= @sizeOf(Span));
    assert(config.large_span_overhead_mul >= 0.0);

    // These asserts must be true for alignment purposes
    assert(utils.isPowerOfTwo(span_header_size));
    assert(utils.isPowerOfTwo(small_granularity));
    assert(utils.isPowerOfTwo(small_max));
    assert(utils.isPowerOfTwo(medium_granularity));
    assert(medium_granularity <= small_max);
    assert(span_header_size % small_granularity == 0);

    // These asserts must be true for MPSC queue to work
    assert(config.cache_limit > 1);
    assert(config.large_cache_limit > 1);
    assert(utils.isPowerOfTwo(config.cache_limit));
    assert(utils.isPowerOfTwo(config.large_cache_limit));

    return struct {
        backing_allocator: std.mem.Allocator,
        arena_handler: ArenaHandler,
        huge_count: Atomic(usize),

        const Self = @This();

        pub fn init() Self {
            var arena_handler = if (config.global_allocator)
                getGlobalArenaHandler()
            else
                ArenaHandler.init();

            return .{
                .backing_allocator = config.backing_allocator,
                .arena_handler = arena_handler,
                .huge_count = Atomic(usize).init(0),
            };
        }

        inline fn getGlobalArenaHandler() *GlobalArenaHandler {
            if (global_arena_handler) |global_arena_handler_ptr| {
                return @ptrCast(@alignCast(global_arena_handler_ptr));
            }

            const global_arena_handler_ptr = config.backing_allocator.create(GlobalArenaHandler) catch {
                @panic("Unable to instantiate global arena handler: OutOfMemory");
            };

            global_arena_handler_ptr.* = GlobalArenaHandler.init();
            global_arena_handler = global_arena_handler_ptr;

            return global_arena_handler_ptr;
        }

        pub fn deinit(self: *Self) void {
            const spans_leaked = self.arena_handler.deinit();

            if (config.report_leaks) {
                const log = std.log.scoped(.jdz_allocator);

                if (spans_leaked != 0) {
                    log.warn("{} leaked 64KiB spans", .{spans_leaked});
                }

                const huge_count = self.huge_count.load(.Monotonic);
                if (huge_count != 0) {
                    log.warn("{} leaked huge allocations", .{huge_count});
                }
            }
        }

        pub const deinitThread = if (config.global_allocator)
            deinitThreadGlobal
        else
            deinitThreadDummy;

        fn deinitThreadGlobal(self: *Self) void {
            self.arena_handler.deinitThread();
        }

        fn deinitThreadDummy(self: *Self) void {
            _ = self;
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .free = free,
                },
            };
        }

        fn alloc(ctx: *anyopaque, len: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (log2_align <= small_granularity_shift) {
                return self.allocate(len, log2_align, ret_addr);
            }

            const alignment = @as(usize, 1) << @intCast(log2_align);
            const size = @max(alignment, len);

            if (size <= span_header_size) {
                const aligned_block_size: usize = utils.roundUpToPowerOfTwo(size);
                return self.allocate(aligned_block_size, log2_align, ret_addr);
            }

            assert(alignment <= page_size);

            return self.alignedAllocate(size, alignment, log2_align, ret_addr);
        }

        fn resize(ctx: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
            _ = ret_addr;
            _ = ctx;
            const alignment = @as(usize, 1) << @intCast(log2_align);
            const aligned = (@intFromPtr(buf.ptr) & (alignment - 1)) == 0;

            const span = getSpan(buf);

            if (buf.len <= span_max) return new_len <= span.class.block_size and aligned;
            if (buf.len <= large_max) return new_len <= span.alloc_size - (span.alloc_ptr - span.initial_ptr) and aligned;

            // round up to greater than or equal page size
            const max_len = (buf.len - 1 / page_size) * page_size + page_size;

            return aligned and new_len <= max_len;
        }

        fn free(ctx: *anyopaque, buf: []u8, log2_align: u8, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const alignment = @as(usize, 1) << @intCast(log2_align);
            const size = @max(alignment, buf.len);
            const span = getSpan(buf);
            const arena: *Arena = @ptrCast(@alignCast(span.arena));

            if (size <= medium_max) {
                arena.freeSmallOrMedium(span, buf);
            } else if (size <= span_max) {
                arena.cacheSpanOrFree(span);
            } else if (size <= large_max) {
                arena.cacheLargeSpanOrFree(span, config.recycle_large_spans);
            } else {
                _ = self.huge_count.fetchSub(1, .Monotonic);
                self.backing_allocator.rawFree(buf, log2_align, ret_addr);
            }
        }

        ///
        /// Allocation
        ///
        fn allocate(self: *Self, size: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
            if (size <= large_max) {
                const arena = self.arena_handler.getArena() orelse return null;
                defer arena.writer_lock.release();

                return if (size <= small_max)
                    arena.allocateToSpan(getSmallSizeClass(size))
                else if (size <= medium_max)
                    arena.allocateToSpan(getMediumSizeClass(size))
                else if (size <= span_max)
                    arena.allocateOneSpan(span_class, zero_offset)
                else
                    arena.allocateToLargeSpan(utils.getSpanCount(size), zero_offset);
            }

            if (self.backing_allocator.rawAlloc(size, log2_align, ret_addr)) |buf| {
                _ = self.huge_count.fetchAdd(1, .Monotonic);

                return buf;
            }

            return null;
        }

        fn alignedAllocate(self: *Self, size: usize, alignment: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
            assert(alignment <= span_align_max);

            const align_size = utils.roundUpToPowerOfTwo(size);
            const alloc_offset = alignment - span_header_size;
            const large_aligned_size = size + alloc_offset;

            if (large_aligned_size <= large_max) {
                const arena = self.arena_handler.getArena() orelse return null;
                defer arena.writer_lock.release();

                return if (align_size <= medium_max)
                    arena.alignedAllocateToSpan(getAlignedSizeClass(log2_align))
                else
                    arena.alignedAllocateLarge(alloc_offset, large_aligned_size);
            }

            _ = self.huge_count.fetchAdd(1, .Monotonic);
            return self.backing_allocator.rawAlloc(size, log2_align, ret_addr);
        }

        ///
        /// Helpers
        ///
        inline fn getSmallSizeClass(len: usize) SizeClass {
            assert(len <= small_max);

            return small_size_classes[getSmallSizeIdx(len)];
        }

        inline fn getMediumSizeClass(len: usize) SizeClass {
            assert(len <= medium_max);

            return medium_size_classes[getMediumSizeIdx(len)];
        }

        inline fn getAlignedSizeClass(log2_align: u8) SizeClass {
            assert(log2_align <= page_alignment);

            return aligned_size_classes[log2_align - aligned_spans_offset];
        }

        inline fn getSmallSizeIdx(len: usize) usize {
            return (len - 1) >> small_granularity_shift;
        }

        inline fn getMediumSizeIdx(len: usize) usize {
            return (len - small_max - 1) >> medium_granularity_shift;
        }

        inline fn getSpan(buf: []u8) *Span {
            return @ptrFromInt(@intFromPtr(buf.ptr) & span_upper_mask);
        }
    };
}

pub const SizeClass = struct {
    block_size: u32,
    block_max: u32,
    class_idx: u32,
};

pub const span_size = 65536;
pub const mod_span_size = span_size - 1;

// must be a multiple of small_granularity
pub const span_header_size = 128;
pub const span_effective_size = span_size - span_header_size;
pub const span_max = span_effective_size;

pub const page_size = std.mem.page_size;
pub const page_alignment = log2(page_size);

pub const aligned_spans_offset = log2(span_header_size);
pub const aligned_class_count = log2(medium_max) - aligned_spans_offset;

pub const large_class_count = 64;
pub const large_max = large_class_count * span_size - span_header_size;

pub const span_class = SizeClass{
    .block_max = 1,
    .block_size = span_effective_size,
    .class_idx = small_class_count + medium_class_count,
};

pub const size_class_count = small_class_count + medium_class_count + 1;

pub const zero_offset = 0;

const small_granularity = 16;
const small_granularity_shift = log2(small_granularity);
const small_max = 2048;
const small_class_count = small_max / small_granularity;

const medium_granularity = 256;
const medium_granularity_shift = log2(medium_granularity);
// fit at least 2 medium allocs in one span
const medium_max = span_effective_size / 2 - ((span_effective_size / 2) % medium_granularity);
const medium_class_count = (medium_max - small_max) / medium_granularity;

const span_align_max = std.math.pow(u16, 2, log2_int(u16, medium_max));
// small class count + medium class count + 1 for large <= span_effective_size

const span_alignment = log2(span_size);
const span_lower_mask: usize = span_size - 1;
const span_upper_mask: usize = ~span_lower_mask;

const small_size_classes = generateSmallSizeClasses();
const medium_size_classes = generateMediumSizeClasses();
const aligned_size_classes = generateAlignedSizeClasses();

fn generateSmallSizeClasses() [small_class_count]SizeClass {
    var size_classes: [small_class_count]SizeClass = undefined;

    for (0..small_class_count) |i| {
        size_classes[i].block_size = (i + 1) * small_granularity;
        size_classes[i].block_max = span_effective_size / size_classes[i].block_size;
        size_classes[i].class_idx = i;
    }

    mergeSizeClasses(&size_classes);

    assert(size_classes[0].block_size == small_granularity);
    assert(size_classes[size_classes.len - 1].block_size == small_max);

    return size_classes;
}

fn generateMediumSizeClasses() [medium_class_count]SizeClass {
    var size_classes: [medium_class_count]SizeClass = undefined;

    for (0..medium_class_count) |i| {
        size_classes[i].block_size = small_max + (i + 1) * medium_granularity;
        size_classes[i].block_max = span_effective_size / size_classes[i].block_size;
        size_classes[i].class_idx = small_class_count + i;
    }

    mergeSizeClasses(&size_classes);

    assert(size_classes[0].block_size == small_max + medium_granularity);
    assert(size_classes[size_classes.len - 1].block_size == medium_max);
    assert(size_classes[size_classes.len - 1].block_max > 1);

    return size_classes;
}

fn generateAlignedSizeClasses() [aligned_class_count]SizeClass {
    var size_classes: [aligned_class_count]SizeClass = undefined;

    for (0..aligned_class_count) |i| {
        const block_size = 1 << (i + aligned_spans_offset);

        size_classes[i].block_size = block_size;
        size_classes[i].block_max = (span_size - block_size) / block_size;
        size_classes[i].class_idx = i;
    }

    return size_classes;
}

// merge size classes with equal block count to higher size
fn mergeSizeClasses(size_classes: []SizeClass) void {
    var i = size_classes.len - 1;
    while (i > 0) : (i -= 1) {
        if (size_classes[i].block_max == size_classes[i - 1].block_max) {
            // need to maintain power of 2 classes for alignment
            if (utils.isPowerOfTwo(size_classes[i - 1].block_size)) continue;

            size_classes[i - 1].block_size = size_classes[i].block_size;
            size_classes[i - 1].class_idx = size_classes[i].class_idx;
        }
    }
}

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
