const std = @import("std");
const jdz_allocator = @import("allocator.zig");
const lock = @import("lock.zig");

const JdzAllocConfig = jdz_allocator.JdzAllocConfig;
const Atomic = std.atomic.Atomic;
const Ordering = std.atomic.Ordering;
const assert = std.debug.assert;

const span_size = jdz_allocator.span_size;
const span_header_size = jdz_allocator.span_header_size;
const large_max = jdz_allocator.large_max;

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
    return if (config.thread_safe and !config.global_allocator)
        lock.Lock
    else
        lock.DummyLock;
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
