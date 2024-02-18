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

pub fn Span(comptime config: JdzAllocConfig) type {
    const Mutex = utils.getMutexType(config);

    return struct {
        const Self = @This();

        const Arena = arena.Arena(config);

        const SpanStack = span_stack.SpanStack(config);

        arena: *Arena,
        stack: ?*SpanStack,
        free_list: ?usize,
        mutex: Mutex,
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

        pub fn allocate(self: *Self) [*]u8 {
            assert(self.block_count < self.class.block_max);

            self.block_count += 1;

            if (self.free_list) |block| {
                self.free_list = @as(*?usize, @ptrFromInt(block)).*;

                return @ptrFromInt(block);
            }

            return self.allocateFromAllocPtr();
        }

        pub fn allocateFromAllocPtr(self: *Self) [*]u8 {
            assert(self.alloc_ptr <= @intFromPtr(self) + span_size - self.class.block_size);

            const res: [*]u8 = @ptrFromInt(self.alloc_ptr);
            self.alloc_ptr += self.class.block_size;

            return res;
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
    };
}
