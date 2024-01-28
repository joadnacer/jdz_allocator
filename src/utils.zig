const std = @import("std");

const jdz_allocator = @import("jdz_allocator.zig");
const static_config = @import("static_config.zig");
const lock = @import("lock.zig");

const JdzAllocConfig = jdz_allocator.JdzAllocConfig;
const SizeClass = static_config.SizeClass;

const Atomic = std.atomic.Atomic;
const Ordering = std.atomic.Ordering;
const assert = std.debug.assert;

const usize_bits_subbed = @bitSizeOf(usize) - 1;

const log2_usize_type = @Type(std.builtin.Type{ .Int = std.builtin.Type.Int{
    .signedness = std.builtin.Signedness.unsigned,
    .bits = std.math.log2(@bitSizeOf(usize)),
} });

const DummyMutex = struct {
    pub fn lock(_: @This()) void {}
    pub fn unlock(_: @This()) void {}
};

pub fn getMutexType(comptime config: JdzAllocConfig) type {
    return if (config.thread_safe)
        std.Thread.Mutex
    else
        DummyMutex;
}

pub fn getArenaLockType(comptime config: JdzAllocConfig) type {
    return if (config.thread_safe)
        lock.Lock
    else
        lock.DummyLock;
}

pub inline fn getSmallSizeClass(len: usize) SizeClass {
    assert(len <= small_max);

    return small_size_classes[getSmallSizeIdx(len)];
}

pub inline fn getMediumSizeClass(len: usize) SizeClass {
    assert(len <= medium_max);

    return medium_size_classes[getMediumSizeIdx(len)];
}

pub inline fn getAlignedSizeClass(log2_align: u8) SizeClass {
    assert(log2_align <= page_alignment);

    return aligned_size_classes[log2_align - aligned_spans_offset];
}

pub inline fn getSmallSizeIdx(len: usize) usize {
    return (len - 1) >> small_granularity_shift;
}

pub inline fn getMediumSizeIdx(len: usize) usize {
    return (len - small_max - 1) >> medium_granularity_shift;
}

pub inline fn getSpan(comptime T: type, buf: []u8) *T {
    return @ptrFromInt(@intFromPtr(buf.ptr) & span_upper_mask);
}

pub inline fn isPowerOfTwo(n: u64) bool {
    return n & (n - 1) == 0;
}

pub inline fn getSpanCount(len: usize) u32 {
    assert(len <= large_max);

    const size: u32 = @truncate(len + span_header_size);

    return (((size - 1) / span_size) * span_size + span_size) / span_size;
}

pub inline fn roundUpToPowerOfTwo(n: usize) usize {
    return @as(usize, 1) << (usize_bits_subbed - @as(log2_usize_type, @truncate(@clz(n))));
}

pub inline fn tryCASAddOne(atomic_ptr: *Atomic(usize), val: usize, success_ordering: Ordering) ?usize {
    return atomic_ptr.tryCompareAndSwap(val, val + 1, success_ordering, .Monotonic);
}

const span_size = static_config.span_size;
const span_upper_mask = static_config.span_upper_mask;
const span_header_size = static_config.span_header_size;

const small_granularity_shift = static_config.small_granularity_shift;
const small_max = static_config.small_max;

const medium_granularity_shift = static_config.medium_granularity_shift;
const medium_max = static_config.medium_max;

const large_max = static_config.large_max;

const page_alignment = static_config.page_alignment;

const small_size_classes = static_config.small_size_classes;
const medium_size_classes = static_config.medium_size_classes;

const aligned_size_classes = static_config.aligned_size_classes;
const aligned_spans_offset = static_config.aligned_spans_offset;
