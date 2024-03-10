const std = @import("std");

const jdz_allocator = @import("jdz_allocator.zig");
const span_list = @import("span_list.zig");
const static_config = @import("static_config.zig");
const utils = @import("utils.zig");

const JdzAllocConfig = jdz_allocator.JdzAllocConfig;
const SizeClass = static_config.SizeClass;
const Atomic = std.atomic.Atomic;
const RwLock = std.Thread.RwLock;

const assert = std.debug.assert;

const span_size = static_config.span_size;
const span_header_size = static_config.span_header_size;
const page_size = static_config.page_size;
const free_list_null = static_config.free_list_null;

const deferred_pending_free: usize = @bitCast(@as(isize, -1));

pub fn Span(comptime config: JdzAllocConfig) type {
    return struct {
        const Self = @This();

        const SpanList = span_list.SpanList(config);

        arena: *anyopaque,
        free_list: usize,
        deferred_free_list: usize,
        deferred_lock: RwLock,
        full: bool,
        next: ?*Self,
        prev: ?*Self,
        alloc_ptr: usize,
        class: SizeClass,
        block_count: u16,
        deferred_frees: u16,
        initial_ptr: usize,
        alloc_size: usize,
        span_count: u32,
        aligned_blocks: bool,

        pub inline fn pushFreeList(self: *Self, buf: []u8) void {
            const ptr = self.getBlockPtr(buf);

            self.pushFreeListElement(ptr);

            self.block_count -= 1;
        }

        pub inline fn pushDeferredFreeList(self: *Self, buf: []u8) void {
            const ptr = self.getBlockPtr(buf);

            self.pushDeferredFreeListElement(ptr);
        }

        pub fn allocate(self: *Self) [*]u8 {
            if (self.free_list != free_list_null) {
                return self.popFreeListElement();
            }

            return self.allocateDeferredOrPtr();
        }

        pub fn allocateFromFreshSpan(self: *Self) [*]u8 {
            assert(self.isEmpty());

            const res: [*]u8 = @ptrFromInt(self.alloc_ptr);
            self.alloc_ptr += self.class.block_size;
            self.block_count = 1;

            return res;
        }

        pub fn allocateFromLargeSpan(self: *Self) [*]u8 {
            assert(self.isEmpty());

            self.block_count = 1;

            return @as([*]u8, @ptrFromInt(self.alloc_ptr));
        }

        pub inline fn popFreeListElement(self: *Self) [*]u8 {
            self.block_count += 1;

            const block = self.free_list;
            self.free_list = @as(*usize, @ptrFromInt(block)).*;

            return @ptrFromInt(block);
        }

        pub fn initialiseFreshSpan(self: *Self, arena: *anyopaque, size_class: SizeClass) void {
            self.* = .{
                .arena = arena,
                .initial_ptr = self.initial_ptr,
                .alloc_ptr = @intFromPtr(self) + span_header_size,
                .alloc_size = self.alloc_size,
                .class = size_class,
                .free_list = free_list_null,
                .deferred_free_list = free_list_null,
                .deferred_lock = .{},
                .full = false,
                .next = null,
                .prev = null,
                .block_count = 0,
                .deferred_frees = 0,
                .span_count = 1,
                .aligned_blocks = false,
            };
        }

        pub fn initialiseFreshLargeSpan(self: *Self, arena: *anyopaque, span_count: u32) void {
            self.* = .{
                .arena = arena,
                .initial_ptr = self.initial_ptr,
                .alloc_ptr = @intFromPtr(self) + span_header_size,
                .alloc_size = self.alloc_size,
                .class = undefined,
                .free_list = free_list_null,
                .deferred_free_list = free_list_null,
                .full = false,
                .deferred_lock = .{},
                .next = null,
                .prev = null,
                .block_count = 0,
                .deferred_frees = 0,
                .span_count = span_count,
                .aligned_blocks = false,
            };
        }

        pub fn isFull(self: *Self) bool {
            return self.block_count == self.class.block_max and self.deferred_frees == 0;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.block_count - self.deferred_frees == 0;
        }

        pub fn splitLastSpans(self: *Self, span_count: u32) *Self {
            return self.splitFirstSpansReturnRemaining(self.span_count - span_count);
        }

        pub fn splitFirstSpanReturnRemaining(self: *Self) *Self {
            return self.splitFirstSpansReturnRemaining(1);
        }

        pub fn splitFirstSpansReturnRemaining(self: *Self, span_count: u32) *Self {
            assert(self.span_count > span_count);

            const remaining_span_addr = @intFromPtr(self) + span_size * span_count;
            const remaining_span: *Self = @ptrFromInt(remaining_span_addr);
            remaining_span.span_count = self.span_count - span_count;
            remaining_span.alloc_size = self.alloc_size - (remaining_span_addr - self.initial_ptr);
            remaining_span.initial_ptr = remaining_span_addr;

            self.span_count = span_count;
            self.alloc_size = remaining_span.initial_ptr - self.initial_ptr;

            return remaining_span;
        }

        inline fn allocateDeferredOrPtr(self: *Self) [*]u8 {
            if (self.freeDeferredList()) {
                return self.popFreeListElement();
            } else {
                return self.allocateFromAllocPtr();
            }
        }

        inline fn allocateFromAllocPtr(self: *Self) [*]u8 {
            assert(self.alloc_ptr <= @intFromPtr(self) + span_size - self.class.block_size);

            self.block_count += 1;

            const res: [*]u8 = @ptrFromInt(self.alloc_ptr);
            self.alloc_ptr += self.class.block_size;

            return res;
        }

        inline fn getBlockPtr(self: *Self, buf: []u8) [*]u8 {
            if (!self.aligned_blocks) {
                return buf.ptr;
            } else {
                const start_alloc_ptr = @intFromPtr(self) + span_header_size;
                const block_offset = @intFromPtr(buf.ptr) - start_alloc_ptr;

                return buf.ptr - block_offset % self.class.block_size;
            }
        }

        inline fn pushFreeListElement(self: *Self, ptr: [*]u8) void {
            const block: *?usize = @ptrCast(@alignCast(ptr));
            block.* = self.free_list;
            self.free_list = @intFromPtr(block);
        }

        inline fn pushDeferredFreeListElement(self: *Self, ptr: [*]u8) void {
            const block: *usize = @ptrCast(@alignCast(ptr));

            self.deferred_lock.lockShared();
            defer self.deferred_lock.unlockShared();

            while (true) {
                block.* = self.deferred_free_list;

                if (@cmpxchgWeak(usize, &self.deferred_free_list, block.*, @intFromPtr(block), .Monotonic, .Monotonic) == null) {
                    _ = @atomicRmw(u16, &self.deferred_frees, .Add, 1, .Monotonic);

                    return;
                }
            }
        }

        inline fn freeDeferredList(self: *Self) bool {
            assert(self.free_list == free_list_null);

            if (self.deferred_free_list == free_list_null) return false;

            self.deferred_lock.lock();
            defer self.deferred_lock.unlock();

            self.free_list = self.deferred_free_list;
            self.block_count -= self.deferred_frees;
            self.deferred_free_list = free_list_null;
            self.deferred_frees = 0;

            return true;
        }
    };
}
