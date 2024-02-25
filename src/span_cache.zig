const std = @import("std");

const jdz_allocator = @import("jdz_allocator.zig");
const mpsc_queue = @import("bounded_mpsc_queue.zig");
const span_file = @import("span.zig");
const static_config = @import("static_config.zig");
const utils = @import("utils.zig");

const testing = std.testing;
const assert = std.debug.assert;
const JdzAllocConfig = jdz_allocator.JdzAllocConfig;

const span_size = static_config.span_size;

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
            const span = self.cache.tryRead() orelse return null;

            if (span.span_count > 1) {
                const split_spans = span.splitFirstSpanReturnRemaining();

                _ = self.cache.tryWrite(split_spans);
            }

            return span;
        }
    };
}
