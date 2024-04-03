const std = @import("std");
const builtin = @import("builtin");

const shared_allocator = @import("shared_allocator.zig");
const global_allocator = @import("global_allocator.zig");

pub const JdzAllocator = shared_allocator.JdzAllocator;
pub const JdzGlobalAllocator = global_allocator.JdzGlobalAllocator;

pub const JdzAllocConfig = struct {
    /// backing allocator
    backing_allocator: std.mem.Allocator = std.heap.page_allocator,

    /// controls batch span allocation amount for one span allocations
    /// will return 1 span to allocating function and all remaining spans will be written to the one span cache
    span_alloc_count: u32 = 64,

    /// controls batch memory mapping amount in spans
    /// overhead from desired span count will be saved to map_cache for reuse on future map requests
    /// as memory mapping will likely not be aligned, we will use 1 span worth of padding per map call
    /// padding may be used as a span if alignment allows it
    /// minimum is 1 (not recommended) - default is 64, resulting in 4MiB memory mapping + 64KiB padding
    map_alloc_count: u32 = 64,

    /// maximum number of spans in arena cache
    cache_limit: u32 = 64,

    /// maximum number spans in arena large caches
    large_cache_limit: u32 = 64,

    /// maximum number of spans in arena map cache
    map_cache_limit: u32 = 16,

    /// global cache multiplier
    global_cache_multiplier: u32 = 8,

    /// percentage overhead applied to span count when looking for a large span in cache
    /// increases cache hits and memory usage, but does hurt performance
    large_span_overhead_mul: f64 = 0.5,

    /// if cached large spans should be split to accomodate small or medium allocations
    /// improves memory usage but hurts performance
    split_large_spans_to_one: bool = true,

    /// if cached large spans should be split to accomodate smaller large allocations
    /// improves memory usage but hurts performance
    split_large_spans_to_large: bool = true,

    /// JdzSharedAllocator batch arena instantiation amount
    /// prevents allocator-induced false sharing if greater than total number of allocating threads
    shared_arena_batch_size: u32 = 8,

    /// if leaks should be reported - only works with JdzSharedAllocator
    report_leaks: bool = builtin.mode == .Debug,

    /// Whether to synchronize usage of this allocator.
    /// For actual thread safety, the backing allocator must also be thread safe.
    thread_safe: bool = !builtin.single_threaded,
};

test {
    std.testing.refAllDecls(@This());
}
