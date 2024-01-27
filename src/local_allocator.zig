const std = @import("std");
const builtin = @import("builtin");

const jdz = @import("jdz_allocator.zig");
const handler = @import("arena_handler.zig");
const global_handler = @import("global_arena_handler.zig");
const span_arena = @import("arena.zig");
const span_file = @import("span.zig");
const static_config = @import("static_config.zig");
const utils = @import("utils.zig");

const JdzAllocConfig = jdz.JdzAllocConfig;
const Atomic = std.atomic.Atomic;
const assert = std.debug.assert;

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
            const arena_handler = if (config.global_allocator)
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

            const span = utils.getSpan(Span, buf);

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
            const span = utils.getSpan(Span, buf);
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
                    arena.allocateToSpan(utils.getSmallSizeClass(size))
                else if (size <= medium_max)
                    arena.allocateToSpan(utils.getMediumSizeClass(size))
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
                    arena.alignedAllocateToSpan(utils.getAlignedSizeClass(log2_align))
                else
                    arena.alignedAllocateLarge(alloc_offset, large_aligned_size);
            }

            _ = self.huge_count.fetchAdd(1, .Monotonic);
            return self.backing_allocator.rawAlloc(size, log2_align, ret_addr);
        }
    };
}

const SizeClass = static_config.SizeClass;

const span_size = static_config.span_size;
const span_header_size = static_config.span_header_size;
const span_upper_mask = static_config.span_upper_mask;

const small_granularity = static_config.small_granularity;
const small_granularity_shift = static_config.small_granularity_shift;
const small_max = static_config.small_max;

const medium_granularity = static_config.medium_granularity;
const medium_granularity_shift = static_config.medium_granularity_shift;
const medium_max = static_config.medium_max;

const span_max = static_config.span_max;
const span_class = static_config.span_class;

const large_max = static_config.large_max;

const page_size = static_config.page_size;
const page_alignment = static_config.page_alignment;

const small_size_classes = static_config.small_size_classes;
const medium_size_classes = static_config.medium_size_classes;

const aligned_size_classes = static_config.aligned_size_classes;
const aligned_spans_offset = static_config.aligned_spans_offset;
const span_align_max = static_config.span_align_max;

const zero_offset = static_config.zero_offset;
