const std = @import("std");
const span_stack = @import("span_stack.zig");
const span_cache = @import("span_cache.zig");
const stack = @import("bounded_stack.zig");
const jdz_allocator = @import("jdz_allocator.zig");
const mpsc_queue = @import("bounded_mpsc_queue.zig");
const span_file = @import("span.zig");
const static_config = @import("static_config.zig");
const utils = @import("utils.zig");

const JdzAllocConfig = jdz_allocator.JdzAllocConfig;
const SizeClass = static_config.SizeClass;

const assert = std.debug.assert;

const cache_line = std.atomic.cache_line;

pub fn Arena(comptime config: JdzAllocConfig, comptime is_threadlocal: bool) type {
    const Span = span_file.Span(config);

    const SpanStack = span_stack.SpanStack(config);

    const ArenaSpanCache = span_cache.SpanCache(config);

    const Lock = utils.getArenaLockType(config);

    const ArenaLargeCache = mpsc_queue.BoundedMpscQueue(*Span, config.large_cache_limit);

    const ArenaMapCache = stack.BoundedStack(*Span, config.map_cache_limit);

    return struct {
        backing_allocator: std.mem.Allocator,
        spans: [size_class_count]SpanStack,
        full_spans: [size_class_count]SpanStack,
        span_count: usize,
        cache: ArenaSpanCache,
        large_cache: [large_class_count - 1]ArenaLargeCache,
        map_cache: [large_class_count]ArenaMapCache,
        writer_lock: Lock align(cache_line),
        thread_id: ?std.Thread.Id align(cache_line),
        next: ?*Self align(cache_line),

        const Self = @This();

        pub fn init(writer_lock: Lock, thread_id: std.Thread.Id) Self {
            var large_cache: [large_class_count - 1]ArenaLargeCache = undefined;
            var map_cache: [large_class_count]ArenaMapCache = undefined;

            for (&map_cache) |*cache| {
                cache.* = ArenaMapCache.init();
            }

            for (&large_cache) |*cache| {
                cache.* = ArenaLargeCache.init();
            }

            return .{
                .backing_allocator = config.backing_allocator,
                .spans = .{.{}} ** size_class_count,
                .full_spans = .{.{}} ** size_class_count,
                .span_count = 0,
                .cache = ArenaSpanCache.init(),
                .large_cache = large_cache,
                .map_cache = map_cache,
                .writer_lock = writer_lock,
                .thread_id = thread_id,
                .next = null,
            };
        }

        pub fn deinit(self: *Self) usize {
            self.writer_lock.acquire();
            defer self.writer_lock.release();

            self.freeEmptySpansFromStacks();

            while (self.cache.tryRead()) |span| {
                self.freeSpan(span);
            }

            for (&self.large_cache) |*large_cache| {
                while (large_cache.tryRead()) |span| {
                    self.freeSpan(span);
                }
            }

            for (0..self.map_cache.len) |i| {
                while (self.getCachedMapped(i)) |span| {
                    self.freeSpan(span);
                }
            }

            return self.span_count;
        }

        pub inline fn tryAcquire(self: *Self) bool {
            return self.writer_lock.tryAcquire();
        }

        pub inline fn release(self: *Self) void {
            self.writer_lock.release();
        }

        ///
        /// Small Or Medium Allocations
        ///
        pub fn allocateToSpan(self: *Self, size_class: SizeClass) ?[*]u8 {
            if (self.spans[size_class.class_idx].tryRead()) |span| {
                if (span.free_list != free_list_null) {
                    return span.popFreeListElement();
                }
            }

            return self.allocateGeneric(size_class);
        }

        fn allocateGeneric(self: *Self, size_class: SizeClass) ?[*]u8 {
            return self.allocateFromSpanStack(size_class) orelse
                self.allocateFromFullSpans(size_class) orelse
                self.allocateFromCacheOrNew(size_class);
        }

        fn allocateFromSpanStack(self: *Self, size_class: SizeClass) ?[*]u8 {
            while (self.spans[size_class.class_idx].tryRead()) |span| {
                if (span.block_count == span.class.block_max) {
                    const full_span = self.spans[size_class.class_idx].removeHead();

                    self.full_spans[size_class.class_idx].write(full_span);

                    continue;
                }

                return span.allocate();
            }

            return null;
        }

        fn allocateFromFullSpans(self: *Self, size_class: SizeClass) ?[*]u8 {
            const partial_span = self.full_spans[size_class.class_idx].getPartialSpans() orelse {
                return null;
            };

            const leftover_partials = partial_span.splitFirstSpanReturnRemainingIfExist();

            self.spans[size_class.class_idx].writeLinkedSpans(leftover_partials);

            return partial_span.allocate();
        }

        fn allocateFromCacheOrNew(self: *Self, size_class: SizeClass) ?[*]u8 {
            const span = self.getSpanFromCacheOrNew() orelse return null;

            self.initialiseFreshSpan(span, size_class);

            const res = allocateFromFreshSpan(span);

            self.spans[size_class.class_idx].write(span);

            return res;
        }

        fn allocateFromFreshSpan(span: *Span) [*]u8 {
            assert(span.block_count == 0);

            const res: [*]u8 = @ptrFromInt(span.alloc_ptr);
            span.alloc_ptr += span.class.block_size;
            span.block_count = 1;

            return res;
        }

        fn initialiseFreshSpan(self: *Self, span: *Span, size_class: SizeClass) void {
            span.* = .{
                .arena = self,
                .initial_ptr = span.initial_ptr,
                .alloc_ptr = @intFromPtr(span) + span_header_size,
                .alloc_size = span.alloc_size,
                .class = size_class,
                .free_list = free_list_null,
                .deferred_free_list = free_list_null,
                .next = null,
                .prev = null,
                .block_count = 0,
                .span_count = 1,
                .aligned_blocks = false,
            };
        }

        const getSpanFromCacheOrNew = if (config.split_large_spans_to_one)
            getSpanFromCacheOrNewSplitting
        else
            getSpanFromCacheOrNewNonSplitting;

        fn getSpanFromCacheOrNewSplitting(self: *Self) ?*Span {
            return self.cache.tryRead() orelse
                self.getEmptySpansFromStacks() orelse
                self.getSpansFromMapCache() orelse
                self.getSpansFromLargeCache() orelse
                self.mapSpan(MapMode.multiple, config.span_alloc_count);
        }

        fn getSpanFromCacheOrNewNonSplitting(self: *Self) ?*Span {
            return self.cache.tryRead() orelse
                self.getEmptySpansFromStacks() orelse
                self.getSpansFromMapCache() orelse
                self.mapSpan(MapMode.multiple, config.span_alloc_count);
        }

        fn getEmptySpansFromStacks(self: *Self) ?*Span {
            var ret_span: ?*Span = null;

            for (&self.spans) |*spans| {
                var empty_spans = spans.getEmptySpans() orelse continue;

                if (ret_span) |span| self.cacheSpanOrFree(span);

                ret_span = empty_spans;

                while (empty_spans.next) |next| {
                    ret_span = next;

                    self.cacheSpanOrFree(empty_spans);

                    empty_spans = next;
                }
            }

            return ret_span;
        }

        fn getSpansFromLargeCache(self: *Self) ?*Span {
            var span_count: usize = large_class_count;

            while (span_count >= 2) : (span_count -= 1) {
                const large_span = self.large_cache[span_count - 2].tryRead() orelse continue;

                return self.getSpansFromLargeSpan(large_span);
            }

            return null;
        }

        fn getSpansFromLargeSpan(self: *Self, span: *Span) *Span {
            const to_cache = span.splitFirstSpanReturnRemaining();

            if (self.cache.tryWriteLarge(to_cache)) |remaining| {
                if (remaining.span_count > 1)
                    self.cacheLargeSpanOrFree(remaining, false)
                else
                    self.cacheSpanOrFree(remaining);
            }

            return span;
        }

        ///
        /// Large Span Allocations
        ///
        pub fn allocateOneSpan(self: *Self, size_class: SizeClass) ?[*]u8 {
            const span = self.getSpanFromCacheOrNew() orelse return null;

            self.initialiseFreshSpan(span, size_class);

            return allocateFromFreshSpan(span);
        }

        pub fn allocateToLargeSpan(self: *Self, span_count: u32) ?[*]u8 {
            if (self.getLargeSpan(span_count)) |span| {
                self.initialiseFreshLargeSpan(span, span.span_count);

                return allocateFromLargeSpan(span);
            }

            return self.allocateFromNewLargeSpan(span_count);
        }

        fn getLargeSpan(self: *Self, span_count: u32) ?*Span {
            const span_count_float: f32 = @floatFromInt(span_count);
            const span_overhead: u32 = @intFromFloat(span_count_float * config.large_span_overhead_mul);
            const max_span_count = @min(large_class_count, span_count + span_overhead);

            return self.getLargeSpanFromCaches(span_count, max_span_count);
        }

        const getLargeSpanFromCaches = if (config.split_large_spans_to_large)
            getLargeSpanFromCachesSplitting
        else
            getLargeSpanFromCachesNonSplitting;

        fn getLargeSpanFromCachesSplitting(self: *Self, span_count: u32, max_count: u32) ?*Span {
            return self.getFromLargeCache(span_count, max_count) orelse
                self.getFromMapCache(span_count) orelse
                self.splitLargerCachedSpan(span_count, max_count);
        }

        fn getLargeSpanFromCachesNonSplitting(self: *Self, span_count: u32, max_count: u32) ?*Span {
            return self.getFromLargeCache(span_count, max_count) orelse
                self.getFromMapCache(span_count);
        }

        fn getFromLargeCache(self: *Self, span_count: u32, max_span_count: u32) ?*Span {
            for (span_count..max_span_count + 1) |count| {
                const cached = self.large_cache[count - 2].tryRead() orelse continue;

                assert(cached.span_count == count);

                return cached;
            }

            return null;
        }

        fn splitLargerCachedSpan(self: *Self, desired_count: u32, from_count: u32) ?*Span {
            for (from_count..large_class_count + 1) |count| {
                const cached = self.large_cache[count - 2].tryRead() orelse continue;

                assert(cached.span_count == count);

                const remaining = cached.splitFirstSpansReturnRemaining(desired_count);

                if (remaining.span_count > 1)
                    self.cacheLargeSpanOrFree(remaining, config.recycle_large_spans)
                else
                    self.cacheSpanOrFree(remaining);

                return cached;
            }

            return null;
        }

        fn allocateFromNewLargeSpan(self: *Self, span_count: u32) ?[*]u8 {
            const span = self.mapSpan(MapMode.large, span_count) orelse return null;

            self.initialiseFreshLargeSpan(span, span_count);

            return allocateFromLargeSpan(span);
        }

        fn allocateFromLargeSpan(span: *Span) [*]u8 {
            assert(span.block_count == 0);

            const res: [*]u8 = @ptrFromInt(span.alloc_ptr);
            span.block_count = 1;

            return res;
        }

        fn initialiseFreshLargeSpan(self: *Self, span: *Span, span_count: u32) void {
            span.* = .{
                .arena = self,
                .initial_ptr = span.initial_ptr,
                .alloc_ptr = @intFromPtr(span) + span_header_size,
                .alloc_size = span.alloc_size,
                .class = undefined,
                .free_list = free_list_null,
                .deferred_free_list = free_list_null,
                .next = null,
                .prev = null,
                .block_count = 0,
                .span_count = span_count,
                .aligned_blocks = false,
            };
        }

        ///
        /// Span Mapping
        ///
        fn mapSpan(self: *Self, comptime map_mode: MapMode, span_count: u32) ?*Span {
            var map_count = getMapCount(span_count);

            // need padding to guarantee allocating enough spans
            if (map_count == span_count) map_count += 1;

            const alloc_size = map_count * span_size;
            const span_alloc = self.backing_allocator.rawAlloc(alloc_size, page_alignment, @returnAddress()) orelse {
                return null;
            };
            const span_alloc_ptr = @intFromPtr(span_alloc);

            if ((span_alloc_ptr & mod_span_size) != 0) map_count -= 1;

            if (config.report_leaks) self.span_count += map_count;

            const span = self.getSpansCacheRemaining(span_alloc_ptr, alloc_size, map_count, span_count);

            return self.desiredMappingToDesiredSpan(span, map_mode);
        }

        fn desiredMappingToDesiredSpan(self: *Self, span: *Span, map_mode: MapMode) *Span {
            return switch (map_mode) {
                .multiple => self.mapMultipleSpans(span),
                .large => span,
            };
        }

        inline fn getMapCount(desired_span_count: u32) u32 {
            return @max(page_size / span_size, @max(config.map_alloc_count, desired_span_count));
        }

        fn mapMultipleSpans(self: *Self, span: *Span) *Span {
            if (span.span_count > 1) {
                const remaining = span.splitFirstSpanReturnRemaining();

                if (self.cache.tryWriteLarge(remaining)) |leftover| {
                    self.cacheFromMapping(leftover);
                }
            }

            return span;
        }

        ///
        /// Arena Map Cache
        ///
        fn getSpansFromMapCache(self: *Self) ?*Span {
            const map_cache_min = 2;

            if (self.getFromMapCache(map_cache_min)) |mapped_span| {
                return self.desiredMappingToDesiredSpan(mapped_span, .multiple);
            }

            return null;
        }

        fn getSpansCacheRemaining(self: *Self, span_alloc_ptr: usize, alloc_size: usize, map_count: u32, desired_span_count: u32) *Span {
            const span = instantiateMappedSpan(span_alloc_ptr, alloc_size, map_count);

            if (span.span_count > desired_span_count) {
                const remaining = span.splitFirstSpansReturnRemaining(desired_span_count);

                if (remaining.span_count == 1)
                    self.cacheSpanOrFree(remaining)
                else
                    self.cacheFromMapping(remaining);
            }

            return span;
        }

        fn instantiateMappedSpan(span_alloc_ptr: usize, alloc_size: usize, map_count: u32) *Span {
            const after_pad = span_alloc_ptr & (span_size - 1);
            const before_pad = if (after_pad != 0) span_size - after_pad else 0;
            const span_ptr = span_alloc_ptr + before_pad;

            const span: *Span = @ptrFromInt(span_ptr);
            span.initial_ptr = span_alloc_ptr;
            span.alloc_size = alloc_size;
            span.span_count = map_count;

            return span;
        }

        fn getFromMapCache(self: *Self, span_count: u32) ?*Span {
            for (span_count..self.map_cache.len) |count| {
                const cached_span = self.getCachedMapped(count);

                if (cached_span) |span| {
                    assert(count == span.span_count);

                    if (count > span_count) {
                        self.splitMappedSpans(span, span_count);
                    }

                    return span;
                }
            }

            return null;
        }

        inline fn splitMappedSpans(self: *Self, span: *Span, span_count: u32) void {
            const remaining = span.splitFirstSpansReturnRemaining(span_count);

            if (remaining.span_count == 1)
                self.cacheSpanOrFree(remaining)
            else
                self.cacheMapped(remaining);
        }

        fn cacheFromMapping(self: *Self, span: *Span) void {
            const map_cache_max = self.map_cache.len - 1;

            while (span.span_count > map_cache_max) {
                const remaining = span.splitLastSpans(map_cache_max);

                self.cacheMapped(remaining);
            }

            self.cacheMapped(span);
        }

        fn cacheMapped(self: *Self, span: *Span) void {
            assert(span.span_count < self.map_cache.len);

            if (span.span_count == 1) {
                self.cacheSpanOrFree(span);
            } else if (!self.map_cache[span.span_count].tryWrite(span)) {
                self.cacheLargeSpanOrFree(span, false);
            }
        }

        inline fn getCachedMapped(self: *Self, span_count: usize) ?*Span {
            return self.map_cache[span_count].tryRead();
        }

        ///
        /// Free/Cache Methods
        ///
        ///
        /// Single Span Free/Cache
        ///
        pub fn freeSmallOrMedium(self: *Self, span: *Span, buf: []u8) void {
            self.pushFreeListElement(span, buf);

            _ = @atomicRmw(u16, &span.block_count, .Sub, 1, .Monotonic);
        }

        const pushFreeListElement = if (is_threadlocal)
            pushFreeListElementThreadLocal
        else
            pushFreeListElementShared;

        fn pushFreeListElementThreadLocal(self: *Self, span: *Span, buf: []u8) void {
            if (self.thread_id == std.Thread.getCurrentId()) {
                span.pushFreeList(buf);
            } else {
                span.pushDeferredFreeList(buf);
            }
        }

        fn pushFreeListElementShared(self: *Self, span: *Span, buf: []u8) void {
            if (self.thread_id == std.Thread.getCurrentId() and self.tryAcquire()) {
                defer self.release();

                span.pushFreeList(buf);
            } else {
                span.pushDeferredFreeList(buf);
            }
        }

        fn freeSpan(self: *Self, span: *Span) void {
            assert(span.alloc_size >= span_size);

            if (config.report_leaks) self.span_count -= span.span_count;

            const initial_alloc = @as([*]u8, @ptrFromInt(span.initial_ptr))[0..span.alloc_size];
            self.backing_allocator.rawFree(initial_alloc, page_alignment, @returnAddress());
        }

        pub inline fn cacheSpanOrFree(self: *Self, span: *Span) void {
            if (!self.cache.tryWrite(span)) {
                self.freeSpan(span);
            }
        }

        fn freeEmptySpansFromStacks(self: *Self) void {
            for (&self.spans) |*spans| {
                self.freeStack(spans);
            }
        }

        fn freeStack(self: *Self, spans: *SpanStack) void {
            var empty_spans = spans.getEmptySpans();

            while (empty_spans) |span| {
                empty_spans = span.next;

                self.freeSpan(span);
            }
        }

        ///
        /// Large Span Free/Cache
        ///
        pub fn cacheLargeSpanOrFree(self: *Self, span: *Span, recycle_large_spans: bool) void {
            const span_count = span.span_count;

            if (!self.large_cache[span_count - 2].tryWrite(span)) {
                if (recycle_large_spans) {
                    if (self.cache.tryWriteLarge(span)) |remaining_span| {
                        self.freeSpan(remaining_span);
                    }

                    return;
                }

                self.freeSpan(span);
            }
        }
    };
}

const MapMode = enum {
    large,
    multiple,
};

const span_size = static_config.span_size;
const span_max = static_config.span_max;
const span_class = static_config.span_class;

const page_size = static_config.page_size;
const page_alignment = static_config.page_alignment;

const span_header_size = static_config.span_header_size;
const mod_span_size = static_config.mod_span_size;

const size_class_count = static_config.size_class_count;
const large_class_count = static_config.large_class_count;

const free_list_null = static_config.free_list_null;
