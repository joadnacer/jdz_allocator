const std = @import("std");
const jdz_allocator = @import("allocator.zig");
const span_file = @import("span.zig");
const utils = @import("utils.zig");

const JdzAllocConfig = jdz_allocator.JdzAllocConfig;
const testing = std.testing;
const assert = std.debug.assert;

pub fn SpanStack(comptime config: JdzAllocConfig) type {
    const Span = span_file.Span(config);

    const Mutex = utils.getMutexType(config);

    return struct {
        head: ?*Span align(std.atomic.cache_line) = null,
        mutex: Mutex = .{},

        const Self = @This();

        pub fn write(self: *Self, span: *Span) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            assert(self.head != span);

            resetSpan(span);

            span.next = self.head;
            self.head = span;

            if (span.next) |next| next.prev = span;
        }

        pub fn tryRead(self: *Self) ?*Span {
            return self.head;
        }

        pub fn remove(self: *Self, span: *Span) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (span.prev) |prev| prev.next = span.next else self.head = span.next;
            if (span.next) |next| next.prev = span.prev;

            resetSpan(span);
        }

        pub fn removeFromStackIfFull(self: *Self, span: *Span) void {
            span.block_count += 1;

            if (span.block_count == span.class.block_max) {
                self.remove(span);
            }
        }

        pub fn getEmptySpans(self: *Self) ?*Span {
            if (self.head == null) return null;

            self.mutex.lock();
            defer self.mutex.unlock();

            var empty_spans_head: ?*Span = null;
            var empty_spans_cur: ?*Span = null;

            var opt_span = self.head;

            while (opt_span) |span| {
                assert(span != span.next);

                if (span.block_count == 0) {
                    opt_span = self.removeFromListGetNext(span);

                    if (empty_spans_cur) |empty_span| {
                        assert(empty_span != span);

                        empty_span.next = span;
                        empty_spans_cur = span;
                    } else {
                        empty_spans_head = span;
                        empty_spans_cur = span;
                    }
                } else {
                    opt_span = span.next;
                }
            }

            return empty_spans_head;
        }

        fn removeFromListGetNext(self: *Self, span: *Span) ?*Span {
            assert(span.prev == null or span.prev != span.next);

            if (span.prev) |prev| prev.next = span.next else self.head = span.next;
            if (span.next) |next| next.prev = span.prev;

            const next = span.next;

            resetSpan(span);

            return next;
        }

        fn resetSpan(span: *Span) void {
            span.next = null;
            span.prev = null;
        }
    };
}
