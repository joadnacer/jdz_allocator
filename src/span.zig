const std = @import("std");

const jdz_allocator = @import("jdz_allocator.zig");
const static_config = @import("static_config.zig");
const utils = @import("utils.zig");
const span_file = @import("span.zig");

const SpanList = @import("SpanList.zig");
const JdzAllocConfig = jdz_allocator.JdzAllocConfig;
const SizeClass = static_config.SizeClass;
const Value = std.atomic.Value;

const assert = std.debug.assert;

const span_size = static_config.span_size;
const span_header_size = static_config.span_header_size;
const page_size = static_config.page_size;
const mod_page_size = static_config.mod_page_size;
const free_list_null = static_config.free_list_null;

const invalid_pointer: usize = std.mem.alignBackward(usize, std.math.maxInt(usize), static_config.small_granularity);

pub const Span = extern struct {
    free_list: usize,
    full: bool,
    aligned_blocks: bool,
    block_count: u16,
    class: SizeClass,
    span_count: usize,
    arena: *anyopaque,
    next: ?*Span,
    prev: ?*Span,
    alloc_ptr: usize,
    initial_ptr: usize,
    alloc_size: usize,

    deferred_free_list: usize align(std.atomic.cache_line),
    deferred_frees: u16,

    pub inline fn pushFreeList(self: *Span, buf: []u8) void {
        const ptr = self.getBlockPtr(buf);

        self.pushFreeListElement(ptr);

        self.block_count -= 1;
    }

    pub inline fn pushDeferredFreeList(self: *Span, buf: []u8) void {
        const ptr = self.getBlockPtr(buf);

        self.pushDeferredFreeListElement(ptr);
    }

    pub fn allocate(self: *Span) [*]u8 {
        if (self.free_list != free_list_null) {
            return self.popFreeListElement();
        }

        return self.allocateDeferredOrPtr();
    }

    pub fn allocateFromFreshSpan(self: *Span) [*]u8 {
        assert(self.isEmpty());

        return self.allocateFromAllocPtr();
    }

    pub fn allocateFromAllocPtr(self: *Span) [*]u8 {
        assert(self.alloc_ptr <= @intFromPtr(self) + span_size - self.class.block_size);

        self.block_count += 1;

        const next_page = self.alloc_ptr + page_size - (self.alloc_ptr & mod_page_size);
        const end_span = @intFromPtr(self) + span_size;
        const target = @min(end_span, next_page);
        const bytes_to_fill = target - self.alloc_ptr;
        const blocks_to_add = bytes_to_fill / self.class.block_size;

        const res: [*]u8 = @ptrFromInt(self.alloc_ptr);
        self.alloc_ptr += self.class.block_size;

        if (blocks_to_add > 1) {
            self.free_list = self.alloc_ptr;

            for (1..blocks_to_add) |_| {
                self.pushFreeListElementForwardPointing();
            }

            @as(*usize, @ptrFromInt(self.alloc_ptr - self.class.block_size)).* = free_list_null;
        }

        return res;
    }

    pub fn allocateFromLargeSpan(self: *Span) [*]u8 {
        assert(self.isEmpty());

        self.block_count = 1;

        return @as([*]u8, @ptrFromInt(self.alloc_ptr));
    }

    pub inline fn popFreeListElement(self: *Span) [*]u8 {
        self.block_count += 1;

        const block = self.free_list;
        self.free_list = @as(*usize, @ptrFromInt(block)).*;

        return @ptrFromInt(block);
    }

    pub fn initialiseFreshSpan(self: *Span, arena: *anyopaque, size_class: SizeClass) void {
        self.* = .{
            .arena = arena,
            .initial_ptr = self.initial_ptr,
            .alloc_ptr = @intFromPtr(self) + span_header_size,
            .alloc_size = self.alloc_size,
            .class = size_class,
            .free_list = free_list_null,
            .deferred_free_list = free_list_null,
            .full = false,
            .next = null,
            .prev = null,
            .block_count = 0,
            .deferred_frees = 0,
            .span_count = 1,
            .aligned_blocks = false,
        };
    }

    pub fn initialiseFreshLargeSpan(self: *Span, arena: *anyopaque, span_count: usize) void {
        assert(static_config.large_max <= std.math.maxInt(u32));

        self.* = .{
            .arena = arena,
            .initial_ptr = self.initial_ptr,
            .alloc_ptr = @intFromPtr(self) + span_header_size,
            .alloc_size = self.alloc_size,
            .class = .{
                .block_size = @truncate(span_count * span_size - span_header_size),
                .class_idx = undefined,
                .block_max = 1,
            },
            .free_list = free_list_null,
            .deferred_free_list = free_list_null,
            .full = false,
            .next = null,
            .prev = null,
            .block_count = 0,
            .deferred_frees = 0,
            .span_count = span_count,
            .aligned_blocks = false,
        };
    }

    pub inline fn isFull(self: *Span) bool {
        return self.block_count == self.class.block_max and self.deferred_frees == 0;
    }

    pub inline fn isEmpty(self: *Span) bool {
        return self.block_count - self.deferred_frees == 0;
    }

    pub inline fn splitLastSpans(self: *Span, span_count: usize) *Span {
        return self.splitFirstSpansReturnRemaining(self.span_count - span_count);
    }

    pub inline fn splitFirstSpanReturnRemaining(self: *Span) *Span {
        return self.splitFirstSpansReturnRemaining(1);
    }

    pub fn splitFirstSpansReturnRemaining(self: *Span, span_count: usize) *Span {
        assert(self.span_count > span_count);

        const remaining_span_addr = @intFromPtr(self) + span_size * span_count;
        const remaining_span: *Span = @ptrFromInt(remaining_span_addr);
        remaining_span.span_count = self.span_count - span_count;
        remaining_span.alloc_size = self.alloc_size - (remaining_span_addr - self.initial_ptr);
        remaining_span.initial_ptr = remaining_span_addr;

        self.span_count = span_count;
        self.alloc_size = remaining_span.initial_ptr - self.initial_ptr;

        return remaining_span;
    }

    inline fn allocateDeferredOrPtr(self: *Span) [*]u8 {
        if (self.freeDeferredList()) {
            return self.popFreeListElement();
        } else {
            return self.allocateFromAllocPtr();
        }
    }

    inline fn getBlockPtr(self: *Span, buf: []u8) [*]u8 {
        if (!self.aligned_blocks) {
            return buf.ptr;
        } else {
            const start_alloc_ptr = @intFromPtr(self) + span_header_size;
            const block_offset = @intFromPtr(buf.ptr) - start_alloc_ptr;

            return buf.ptr - block_offset % self.class.block_size;
        }
    }

    inline fn pushFreeListElementForwardPointing(self: *Span) void {
        const next_block = self.alloc_ptr + self.class.block_size;
        @as(*usize, @ptrFromInt(self.alloc_ptr)).* = next_block;
        self.alloc_ptr = next_block;
    }

    inline fn pushFreeListElement(self: *Span, ptr: [*]u8) void {
        const block: *?usize = @ptrCast(@alignCast(ptr));
        block.* = self.free_list;
        self.free_list = @intFromPtr(block);
    }

    inline fn pushDeferredFreeListElement(self: *Span, ptr: [*]u8) void {
        const block: *usize = @ptrCast(@alignCast(ptr));

        while (true) {
            block.* = @atomicRmw(usize, &self.deferred_free_list, .Xchg, invalid_pointer, .acquire);

            if (block.* != invalid_pointer) {
                break;
            }
        }

        self.deferred_frees += 1;

        @atomicStore(usize, &self.deferred_free_list, @intFromPtr(block), .release);
    }

    inline fn freeDeferredList(self: *Span) bool {
        assert(self.free_list == free_list_null);

        if (self.deferred_free_list == free_list_null) return false;

        while (true) {
            self.free_list = @atomicRmw(usize, &self.deferred_free_list, .Xchg, invalid_pointer, .acquire);

            if (self.free_list != invalid_pointer) {
                break;
            }
        }
        self.block_count -= self.deferred_frees;
        self.deferred_frees = 0;

        @atomicStore(usize, &self.deferred_free_list, free_list_null, .release);

        return true;
    }
};
