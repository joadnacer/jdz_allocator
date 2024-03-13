const std = @import("std");

const jdz_allocator = @import("jdz_allocator.zig");
const bounded_stack = @import("bounded_stack.zig");
const static_config = @import("static_config.zig");
const utils = @import("utils.zig");

const Span = @import("Span.zig");
const testing = std.testing;
const assert = std.debug.assert;
const JdzAllocConfig = jdz_allocator.JdzAllocConfig;

const span_size = static_config.span_size;

pub fn SpanCache(comptime cache_limit: u32) type {
    assert(utils.isPowerOfTwo(cache_limit));

    const Cache = bounded_stack.BoundedStack(*Span, cache_limit);

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
