const std = @import("std");
const span_cache = @import("span_cache.zig");
const stack = @import("bounded_stack.zig");
const jdz_allocator = @import("jdz_allocator.zig");
const mpsc_queue = @import("bounded_mpsc_queue.zig");
const global_allocator = @import("global_allocator.zig");
const global_arena_handler = @import("global_arena_handler.zig");
const static_config = @import("static_config.zig");
const utils = @import("utils.zig");
const span_file = @import("span.zig");

const SpanList = @import("SpanList.zig");
const Span = span_file.Span;
const DeferredSpanList = @import("DeferredSpanList.zig");
const JdzAllocConfig = jdz_allocator.JdzAllocConfig;
const SizeClass = static_config.SizeClass;
const Value = std.atomic.Value;

const assert = std.debug.assert;

const cache_line = std.atomic.cache_line;

threadlocal var cached_thread_id: ?std.Thread.Id = null;

pub fn Arena(comptime config: JdzAllocConfig, comptime is_threadlocal: bool) type {
    const ArenaSpanCache = span_cache.SpanCache(config.cache_limit);

    const Lock = utils.getArenaLockType(config);

    const ArenaLargeCache = mpsc_queue.BoundedMpscQueue(*Span, config.large_cache_limit);

    const ArenaMapCache = stack.BoundedStack(*Span, config.map_cache_limit);

    const GlobalArenaHandler = global_arena_handler.GlobalArenaHandler(config);

    return struct {
        backing_allocator: std.mem.Allocator,
        spans: [size_class_count]SpanList,
        free_lists: [size_class_count]*usize,
        deferred_partial_spans: [size_class_count]DeferredSpanList,
        span_count: Value(usize),
        cache: ArenaSpanCache,
        large_cache: [large_class_count]ArenaLargeCache,
        map_cache: [large_class_count]ArenaMapCache,
        writer_lock: Lock align(cache_line),
        thread_id: ?std.Thread.Id align(cache_line),
        next: ?*Self align(cache_line),
        is_alloc_master: bool,

        const GlobalAllocator = if (is_threadlocal) global_allocator.JdzGlobalAllocator(config) else {};

        const Self = @This();

        pub fn init(writer_lock: Lock, thread_id: ?std.Thread.Id) Self {
            var large_cache: [large_class_count]ArenaLargeCache = undefined;
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
                .free_lists = .{@constCast(&free_list_null)} ** size_class_count,
                .deferred_partial_spans = .{.{}} ** size_class_count,
                .span_count = Value(usize).init(0),
                .cache = ArenaSpanCache.init(),
                .large_cache = large_cache,
                .map_cache = map_cache,
                .writer_lock = writer_lock,
                .thread_id = thread_id,
                .next = null,
                .is_alloc_master = false,
            };
        }

        pub fn deinit(self: *Self) usize {
            self.writer_lock.acquire();
            defer self.writer_lock.release();

            self.freeEmptySpansFromLists();

            while (self.cache.tryRead()) |span| {
                self.freeSpanOnArenaDeinit(span);
            }

            for (&self.large_cache) |*large_cache| {
                while (large_cache.tryRead()) |span| {
                    self.freeSpanOnArenaDeinit(span);
                }
            }

            for (0..self.map_cache.len) |i| {
                while (self.getCachedMapped(i)) |span| {
                    self.freeSpanOnArenaDeinit(span);
                }
            }

            return self.span_count.load(.monotonic);
        }

        pub fn makeMaster(self: *Self) void {
            self.is_alloc_master = true;
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
        pub inline fn allocateToSpan(self: *Self, size_class: SizeClass) ?[*]u8 {
            assert(size_class.class_idx != span_class.class_idx);

            if (self.free_lists[size_class.class_idx].* != free_list_null) {
                return self.spans[size_class.class_idx].head.?.popFreeListElement();
            }

            return self.allocateGeneric(size_class);
        }

        fn allocateGeneric(self: *Self, size_class: SizeClass) ?[*]u8 {
            return self.allocateFromSpanList(size_class) orelse
                self.allocateFromDeferredPartialSpans(size_class) orelse
                self.allocateFromCacheOrNew(size_class);
        }

        fn allocateFromSpanList(self: *Self, size_class: SizeClass) ?[*]u8 {
            while (self.spans[size_class.class_idx].tryRead()) |span| {
                if (span.isFull()) {
                    @atomicStore(bool, &span.full, true, .monotonic);

                    _ = self.spans[size_class.class_idx].removeHead();
                    self.free_lists[size_class.class_idx] = self.spans[size_class.class_idx].getHeadFreeList();
                } else {
                    return span.allocate();
                }
            }

            return null;
        }

        fn allocateFromDeferredPartialSpans(self: *Self, size_class: SizeClass) ?[*]u8 {
            const partial_span = self.deferred_partial_spans[size_class.class_idx].getAndRemoveList() orelse {
                return null;
            };

            self.spans[size_class.class_idx].writeLinkedSpans(partial_span);
            self.free_lists[size_class.class_idx] = self.spans[size_class.class_idx].getHeadFreeList();

            return partial_span.allocate();
        }

        fn allocateFromCacheOrNew(self: *Self, size_class: SizeClass) ?[*]u8 {
            const span = self.getSpanFromCacheOrNew() orelse return null;

            span.initialiseFreshSpan(self, size_class);

            self.spans[size_class.class_idx].write(span);
            self.free_lists[size_class.class_idx] = self.spans[size_class.class_idx].getHeadFreeList();

            return span.allocateFromFreshSpan();
        }

        const getSpanFromCacheOrNew = if (config.split_large_spans_to_one)
            getSpanFromCacheOrNewSplitting
        else
            getSpanFromCacheOrNewNonSplitting;

        fn getSpanFromCacheOrNewSplitting(self: *Self) ?*Span {
            return self.cache.tryRead() orelse
                self.getSpanFromOneSpanLargeCache() orelse
                self.getEmptySpansFromLists() orelse
                self.getSpansFromMapCache() orelse
                self.getSpansFromLargeCache() orelse
                self.getSpansExternal();
        }

        fn getSpanFromCacheOrNewNonSplitting(self: *Self) ?*Span {
            return self.cache.tryRead() orelse
                self.getSpanFromOneSpanLargeCache() orelse
                self.getEmptySpansFromLists() orelse
                self.getSpansFromMapCache() orelse
                self.getSpansExternal();
        }

        fn getSpansExternal(self: *Self) ?*Span {
            if (is_threadlocal) {
                if (self.getSpansFromGlobalCaches()) |span| {
                    return span;
                }
            }
            return self.mapSpan(MapMode.multiple, config.span_alloc_count);
        }

        inline fn getSpanFromOneSpanLargeCache(self: *Self) ?*Span {
            return self.large_cache[0].tryRead();
        }

        fn getEmptySpansFromLists(self: *Self) ?*Span {
            var ret_span: ?*Span = null;

            for (0.., &self.spans) |i, *spans| {
                var empty_spans = spans.getEmptySpans() orelse continue;
                self.free_lists[i] = spans.getHeadFreeList();

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
                const large_span = self.large_cache[span_count - 1].tryRead() orelse continue;

                assert(large_span.span_count == span_count);

                self.getSpansFromLargeSpan(large_span);

                return large_span;
            }

            return null;
        }

        fn getSpansFromGlobalCaches(self: *Self) ?*Span {
            assert(is_threadlocal);

            return self.getSpansFromGlobalSpanCache() orelse {
                if (config.split_large_spans_to_one) {
                    return self.getSpansFromGlobalLargeCache();
                } else {
                    return null;
                }
            };
        }

        fn getSpansFromGlobalSpanCache(self: *Self) ?*Span {
            assert(is_threadlocal);

            for (0..config.span_alloc_count) |_| {
                const span = GlobalAllocator.getCachedSpan() orelse break;

                const written = self.cache.tryWrite(span);

                // should never be called if we have spans in cache
                assert(written);
            }

            return self.cache.tryRead();
        }

        fn getSpansFromGlobalLargeCache(self: *Self) ?*Span {
            assert(is_threadlocal);

            var span_count: usize = large_class_count;

            while (span_count >= 2) : (span_count -= 1) {
                const large_span = GlobalAllocator.getCachedLargeSpan(span_count - 1) orelse continue;

                assert(large_span.span_count == span_count);

                self.getSpansFromLargeSpan(large_span);

                return large_span;
            }

            return null;
        }

        fn getSpansFromLargeSpan(self: *Self, span: *Span) void {
            const to_cache = span.splitFirstSpanReturnRemaining();

            const written = self.cache.tryWrite(to_cache);

            // should never be called if we have spans in cache
            assert(written);
        }

        ///
        /// Large Span Allocations
        ///
        pub inline fn allocateOneSpan(self: *Self, size_class: SizeClass) ?[*]u8 {
            const span = self.getSpanFromCacheOrNew() orelse return null;

            span.initialiseFreshSpan(self, size_class);

            return @ptrFromInt(span.alloc_ptr);
        }

        pub inline fn allocateToLargeSpan(self: *Self, span_count: usize) ?[*]u8 {
            if (self.getLargeSpan(span_count)) |span| {
                span.initialiseFreshLargeSpan(self, span.span_count);

                return span.allocateFromLargeSpan();
            }

            return self.allocateFromNewLargeSpan(span_count);
        }

        inline fn getLargeSpan(self: *Self, span_count: usize) ?*Span {
            const span_count_float: f32 = @floatFromInt(span_count);
            const span_overhead: u32 = @intFromFloat(span_count_float * config.large_span_overhead_mul);
            const max_span_count = @min(large_class_count, span_count + span_overhead);

            return self.getLargeSpanFromCaches(span_count, max_span_count);
        }

        const getLargeSpanFromCaches = if (config.split_large_spans_to_large)
            getLargeSpanFromCachesSplitting
        else
            getLargeSpanFromCachesNonSplitting;

        fn getLargeSpanFromCachesSplitting(self: *Self, span_count: usize, max_count: u32) ?*Span {
            return self.getFromLargeCache(span_count, max_count) orelse
                self.getFromMapCache(span_count) orelse
                self.splitFromLargeCache(span_count, max_count) orelse {
                if (is_threadlocal) {
                    return getFromGlobalLargeCache(span_count, max_count) orelse
                        self.splitFromGlobalLargeCache(span_count, max_count);
                } else {
                    return null;
                }
            };
        }

        fn getLargeSpanFromCachesNonSplitting(self: *Self, span_count: usize, max_count: u32) ?*Span {
            return self.getFromLargeCache(span_count, max_count) orelse
                self.getFromMapCache(span_count) orelse {
                if (is_threadlocal) {
                    return getFromGlobalLargeCache(span_count, max_count);
                } else {
                    return null;
                }
            };
        }

        fn getFromLargeCache(self: *Self, span_count: usize, max_span_count: usize) ?*Span {
            for (span_count..max_span_count) |count| {
                const cached = self.large_cache[count - 1].tryRead() orelse continue;

                assert(cached.span_count == count);

                return cached;
            }

            return null;
        }

        fn getFromGlobalLargeCache(span_count: usize, max_span_count: usize) ?*Span {
            assert(is_threadlocal);

            for (span_count..max_span_count) |count| {
                const cached = GlobalAllocator.getCachedLargeSpan(count - 1) orelse continue;

                assert(cached.span_count == count);

                return cached;
            }

            return null;
        }

        fn splitFromLargeCache(self: *Self, desired_count: usize, from_count: usize) ?*Span {
            for (from_count..large_class_count) |count| {
                const cached = self.large_cache[count - 1].tryRead() orelse continue;

                assert(cached.span_count == count);

                const remaining = cached.splitFirstSpansReturnRemaining(desired_count);

                if (remaining.span_count > 1)
                    self.cacheLargeSpanOrFree(remaining)
                else
                    self.cacheSpanOrFree(remaining);

                return cached;
            }

            return null;
        }

        fn splitFromGlobalLargeCache(self: *Self, desired_count: usize, from_count: usize) ?*Span {
            assert(is_threadlocal);

            for (from_count..large_class_count) |count| {
                const cached = GlobalAllocator.getCachedLargeSpan(count - 1) orelse continue;

                assert(cached.span_count == count);

                const remaining = cached.splitFirstSpansReturnRemaining(desired_count);

                if (remaining.span_count > 1)
                    self.cacheLargeSpanOrFree(remaining)
                else
                    self.cacheSpanOrFree(remaining);

                return cached;
            }

            return null;
        }

        fn allocateFromNewLargeSpan(self: *Self, span_count: usize) ?[*]u8 {
            const span = self.mapSpan(MapMode.large, span_count) orelse return null;

            span.initialiseFreshLargeSpan(self, span_count);

            return span.allocateFromLargeSpan();
        }

        ///
        /// Huge Allocation/Free
        ///
        pub fn allocateHuge(self: *Self, span_count: usize) ?[*]u8 {
            const span = self.mapSpan(MapMode.large, span_count) orelse return null;

            span.initialiseFreshLargeSpan(self, span_count);

            return @ptrFromInt(span.alloc_ptr);
        }

        pub const freeHuge = freeSpan;

        ///
        /// Span Mapping
        ///
        fn mapSpan(self: *Self, comptime map_mode: MapMode, span_count: usize) ?*Span {
            var map_count = getMapCount(span_count, map_mode);

            // need padding to guarantee allocating enough spans
            if (map_count == span_count) map_count += 1;

            const alloc_size = map_count * span_size;
            const span_alloc = self.backing_allocator.rawAlloc(alloc_size, page_alignment, @returnAddress()) orelse {
                return null;
            };
            const span_alloc_ptr = @intFromPtr(span_alloc);

            if ((span_alloc_ptr & mod_span_size) != 0) map_count -= 1;

            if (config.report_leaks) _ = self.span_count.fetchAdd(map_count, .monotonic);

            const span = self.getSpansCacheRemaining(span_alloc_ptr, alloc_size, map_count, span_count);

            return self.desiredMappingToDesiredSpan(span, map_mode);
        }

        fn desiredMappingToDesiredSpan(self: *Self, span: *Span, map_mode: MapMode) *Span {
            return switch (map_mode) {
                .multiple => self.mapMultipleSpans(span),
                .large, .huge => span,
            };
        }

        inline fn getMapCount(desired_span_count: usize, map_mode: MapMode) usize {
            return switch (map_mode) {
                .multiple, .large => @max(page_size / span_size, @max(config.map_alloc_count, desired_span_count)),
                .huge => desired_span_count,
            };
        }

        fn mapMultipleSpans(self: *Self, span: *Span) *Span {
            if (span.span_count > 1) {
                const remaining = span.splitFirstSpanReturnRemaining();

                const could_cache = self.cache.tryWrite(remaining);

                // should never be mapping if have spans in span cache
                assert(could_cache);
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

        fn getSpansCacheRemaining(self: *Self, span_alloc_ptr: usize, alloc_size: usize, map_count: usize, desired_span_count: usize) *Span {
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

        fn instantiateMappedSpan(span_alloc_ptr: usize, alloc_size: usize, map_count: usize) *Span {
            const after_pad = span_alloc_ptr & (span_size - 1);
            const before_pad = if (after_pad != 0) span_size - after_pad else 0;
            const span_ptr = span_alloc_ptr + before_pad;

            const span: *Span = @ptrFromInt(span_ptr);
            span.initial_ptr = span_alloc_ptr;
            span.alloc_size = alloc_size;
            span.span_count = map_count;

            return span;
        }

        fn getFromMapCache(self: *Self, span_count: usize) ?*Span {
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

        inline fn splitMappedSpans(self: *Self, span: *Span, span_count: usize) void {
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
                self.cacheLargeSpanOrFree(span);
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
        pub const freeSmallOrMedium = if (is_threadlocal)
            freeSmallOrMediumThreadLocal
        else
            freeSmallOrMediumShared;

        inline fn freeSmallOrMediumThreadLocal(self: *Self, span: *Span, buf: []u8) void {
            if (self == GlobalArenaHandler.getThreadArena()) {
                span.pushFreeList(buf);

                self.handleSpanNoLongerFull(span);
            } else {
                span.pushDeferredFreeList(buf);

                self.handleSpanNoLongerFullDeferred(span);
            }
        }

        inline fn freeSmallOrMediumShared(self: *Self, span: *Span, buf: []u8) void {
            const tid = getThreadId();

            if (self.thread_id == tid and self.tryAcquire()) {
                defer self.release();

                span.pushFreeList(buf);

                self.handleSpanNoLongerFull(span);
            } else {
                span.pushDeferredFreeList(buf);

                self.handleSpanNoLongerFullDeferred(span);
            }
        }

        inline fn handleSpanNoLongerFull(self: *Self, span: *Span) void {
            if (span.full and @atomicRmw(bool, &span.full, .Xchg, false, .monotonic)) {
                self.spans[span.class.class_idx].write(span);
                self.free_lists[span.class.class_idx] = self.spans[span.class.class_idx].getHeadFreeList();
            }
        }

        inline fn handleSpanNoLongerFullDeferred(self: *Self, span: *Span) void {
            if (span.full and @atomicRmw(bool, &span.full, .Xchg, false, .monotonic)) {
                self.deferred_partial_spans[span.class.class_idx].write(span);
            }
        }

        inline fn getThreadId() std.Thread.Id {
            return cached_thread_id orelse {
                cached_thread_id = std.Thread.getCurrentId();

                return cached_thread_id.?;
            };
        }

        fn freeSpanOnArenaDeinit(self: *Self, span: *Span) void {
            if (is_threadlocal and span.span_count == 1) {
                self.cacheSpanToGlobalOrFree(span);
            } else if (is_threadlocal) {
                self.cacheLargeSpanToGlobalOrFree(span);
            } else {
                self.freeSpan(span);
            }
        }

        fn cacheSpanToGlobalOrFree(self: *Self, span: *Span) void {
            assert(is_threadlocal);

            if (GlobalAllocator.cacheSpan(span)) {
                if (config.report_leaks) _ = self.span_count.fetchSub(span.span_count, .monotonic);
            } else {
                self.freeSpan(span);
            }
        }

        fn cacheLargeSpanToGlobalOrFree(self: *Self, span: *Span) void {
            assert(is_threadlocal);

            if (GlobalAllocator.cacheLargeSpan(span)) {
                if (config.report_leaks) _ = self.span_count.fetchSub(span.span_count, .monotonic);
            } else {
                self.freeSpan(span);
            }
        }

        fn freeSpan(self: *Self, span: *Span) void {
            assert(span.alloc_size >= span_size);

            if (config.report_leaks) _ = self.span_count.fetchSub(span.span_count, .monotonic);

            const initial_alloc = @as([*]u8, @ptrFromInt(span.initial_ptr))[0..span.alloc_size];
            self.backing_allocator.rawFree(initial_alloc, page_alignment, @returnAddress());
        }

        pub inline fn cacheSpanOrFree(self: *Self, span: *Span) void {
            if (!self.cache.tryWrite(span)) {
                if (is_threadlocal) {
                    self.cacheSpanToGlobalOrFree(span);
                } else {
                    self.freeSpan(span);
                }
            }
        }

        fn freeEmptySpansFromLists(self: *Self) void {
            for (&self.spans) |*spans| {
                self.freeList(spans);
            }

            for (&self.deferred_partial_spans) |*deferred_partial_spans| {
                self.freeDeferredList(deferred_partial_spans);
            }
        }

        fn freeList(self: *Self, spans: *SpanList) void {
            var empty_spans = spans.getEmptySpans();

            if (empty_spans) |span| {
                self.free_lists[span.class.class_idx] = spans.getHeadFreeList();
            }

            while (empty_spans) |span| {
                empty_spans = span.next;

                self.freeSpanFromList(span);
            }
        }

        fn freeDeferredList(self: *Self, deferred_spans: *DeferredSpanList) void {
            var spans = deferred_spans.getAndRemoveList();

            while (spans) |span| {
                spans = span.next;

                if (span.isEmpty()) {
                    self.freeSpanFromList(span);
                } else {
                    self.spans[span.class.class_idx].write(span);
                    self.free_lists[span.class.class_idx] = self.spans[span.class.class_idx].getHeadFreeList();
                }
            }
        }

        fn freeSpanFromList(self: *Self, span: *Span) void {
            if (is_threadlocal) {
                utils.resetLinkedSpan(span);

                self.cacheSpanToGlobalOrFree(span);
            } else {
                self.freeSpan(span);
            }
        }

        ///
        /// Large Span Free/Cache
        ///
        pub inline fn cacheLargeSpanOrFree(self: *Self, span: *Span) void {
            const span_count = span.span_count;

            if (!self.large_cache[span_count - 1].tryWrite(span)) {
                if (is_threadlocal) {
                    self.cacheLargeSpanToGlobalOrFree(span);
                } else {
                    self.freeSpan(span);
                }
            }
        }
    };
}

const MapMode = enum {
    multiple,
    large,
    huge,
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
