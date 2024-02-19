const std = @import("std");

const jdz_allocator = @import("jdz_allocator.zig");
const arena = @import("arena.zig");
const span_stack = @import("span_stack.zig");
const static_config = @import("static_config.zig");
const utils = @import("utils.zig");

const JdzAllocConfig = jdz_allocator.JdzAllocConfig;
const SizeClass = static_config.SizeClass;

const assert = std.debug.assert;

const span_size = static_config.span_size;
const span_header_size = static_config.span_header_size;
const page_size = static_config.page_size;
const free_list_null = static_config.free_list_null;

pub fn Span(comptime config: JdzAllocConfig) type {
    return struct {
        const Self = @This();

        const Arena = arena.Arena(config);

        const SpanStack = span_stack.SpanStack(config);

        arena: *anyopaque,
        stack: ?*SpanStack,
        free_list: usize,
        deferred_free_list: usize,
        next: ?*Self,
        prev: ?*Self,
        alloc_ptr: usize,
        class: SizeClass,
        block_count: u16,
        initial_ptr: usize,
        alloc_size: usize,
        span_count: u32,
        aligned_blocks: bool,

        pub fn pushFreeList(self: *Self, buf: []u8) void {
            const ptr = self.getBlockPtr(buf);

            self.pushFreeListElement(ptr);
        }

        pub fn pushDeferredFreeList(self: *Self, buf: []u8) void {
            const ptr = self.getBlockPtr(buf);

            self.pushDeferredFreeListElement(ptr);
        }

        pub fn allocate(self: *Self) [*]u8 {
            if (self.free_list != free_list_null) {
                return self.popFreeListElement();
            }

            return self.allocateDeferredOrPtr();
        }

        pub fn popFreeListElement(self: *Self) [*]u8 {
            _ = @atomicRmw(u16, &self.block_count, .Add, 1, .Monotonic);

            const block = self.free_list;
            self.free_list = @as(*usize, @ptrFromInt(block)).*;

            return @ptrFromInt(block);
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

            _ = @atomicRmw(u16, &self.block_count, .Add, 1, .Monotonic);

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

            while (true) {
                block.* = self.deferred_free_list;

                if (@cmpxchgWeak(usize, &self.deferred_free_list, block.*, @intFromPtr(block), .Monotonic, .Monotonic) == null) {
                    return;
                }
            }
        }

        inline fn freeDeferredList(self: *Self) bool {
            assert(self.free_list == free_list_null);

            if (self.deferred_free_list == free_list_null) return false;

            const deferred_free_list = @atomicRmw(usize, &self.deferred_free_list, .Xchg, free_list_null, .Monotonic);

            self.free_list = deferred_free_list;

            return true;
        }
    };
}
