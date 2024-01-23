const std = @import("std");
const jdz_allocator = @import("allocator.zig");
const mpsc_queue = @import("bounded_mpsc_queue.zig");
const span_file = @import("span.zig");
const utils = @import("utils.zig");

const testing = std.testing;
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;
const Ordering = std.atomic.Ordering;
const JdzAllocConfig = jdz_allocator.JdzAllocConfig;

const span_size = jdz_allocator.span_size;

pub fn SpanCache(comptime config: JdzAllocConfig) type {
    assert(utils.isPowerOfTwo(config.cache_limit));

    const Span = span_file.Span(config);

    const Cache = mpsc_queue.BoundedMpscQueue(*Span, config.cache_limit);

    return struct {
        cache: Cache,

        const Self = @This();

        pub fn init() Self {
            return .{
                .cache = Cache.init(),
            };
        }

        pub fn tryWrite(self: *Self, span: *Span) bool {
            return self.cache.tryWrite(span);
        }

        pub fn tryRead(self: *Self) ?*Span {
            return self.cache.tryRead();
        }

        pub fn tryWriteLarge(self: *Self, large_span: *Span) ?*Span {
            var to_move = large_span.span_count;
            assert(to_move <= large_span.alloc_size / span_size);

            var remaining_span = large_span;

            for (0..to_move) |_| {
                var cached = remaining_span;
                remaining_span = self.cacheFromLargeReturnRemaining(remaining_span) orelse return null;

                // was not written, cache is full
                if (cached == remaining_span) return remaining_span;
            }

            assert(remaining_span.alloc_size >= span_size);
            return remaining_span;
        }

        fn cacheFromLargeReturnRemaining(self: *Self, large_span: *Span) ?*Span {
            if (large_span.span_count == 1) {
                if (self.cache.tryWrite(large_span)) return null;

                return large_span;
            }

            const span = large_span;
            const remaining_span = span.splitFirstSpanReturnRemaining();
            span.alloc_size = remaining_span.initial_ptr - span.initial_ptr;
            span.span_count = 1;

            if (!self.cache.tryWrite(span)) {
                span.alloc_size += remaining_span.alloc_size;
                span.span_count += remaining_span.span_count;

                return span;
            }

            return remaining_span;
        }
    };
}
