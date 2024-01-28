const std = @import("std");

const jdz_allocator = @import("jdz_allocator.zig");
const arena = @import("arena.zig");
const static_config = @import("static_config.zig");
const utils = @import("utils.zig");

const JdzAllocConfig = jdz_allocator.JdzAllocConfig;
const SizeClass = static_config.SizeClass;

const assert = std.debug.assert;

const span_size = static_config.span_size;

pub fn Span(comptime config: JdzAllocConfig) type {
    const Mutex = utils.getMutexType(config);

    return struct {
        const Self = @This();

        const Arena = arena.Arena(config);

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
        arena: *Arena,

        pub fn pushFreeList(self: *Self, buf: []u8) void {
            const list = &self.free_list;
            const block: *?usize = @ptrCast(@alignCast(buf.ptr));
            block.* = list.*;
            list.* = @intFromPtr(block);
        }

        pub fn popFreeList(self: *Self) ?usize {
            const opt_block = self.free_list;

            if (opt_block) |block| {
                self.free_list = @as(*?usize, @ptrFromInt(block)).*;

                return block;
            }

            return null;
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
