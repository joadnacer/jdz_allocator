const std = @import("std");
const jdz_allocator = @import("jdz_allocator.zig");
const span_file = @import("span.zig");
const utils = @import("utils.zig");

const JdzAllocConfig = jdz_allocator.JdzAllocConfig;
const testing = std.testing;
const assert = std.debug.assert;

pub fn SpanList(comptime config: JdzAllocConfig) type {
    const Span = span_file.Span(config);

    return struct {
        head: ?*Span align(std.atomic.cache_line) = null,

        const Self = @This();

        pub fn write(self: *Self, span: *Span) void {
            assertNotInList(span);

            var list_span = self.head orelse {
                self.head = span;

                return;
            };

            while (list_span.next) |next| {
                list_span = next;
            }

            list_span.next = span;
            span.prev = list_span;
        }

        pub fn writeLinkedSpans(self: *Self, linked_spans: *Span) void {
            var span = self.head orelse {
                self.head = linked_spans;

                return;
            };

            while (span.next) |next| {
                span = next;
            }

            span.next = linked_spans;
            linked_spans.prev = span;
        }

        pub fn tryRead(self: *Self) ?*Span {
            return self.head;
        }

        pub fn removeHead(self: *Self) *Span {
            assert(self.head != null);

            const head = self.head.?;
            self.head = head.next;

            if (self.head) |new_head| new_head.prev = null;

            resetSpan(head);

            return head;
        }

        pub fn getEmptySpans(self: *Self) ?*Span {
            if (self.head == null) return null;

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
                        span.prev = empty_span;
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

        pub fn getPartialSpans(self: *Self) ?*Span {
            if (self.head == null) return null;

            var partial_spans_head: ?*Span = null;
            var partial_spans_cur: ?*Span = null;

            var opt_span = self.head;

            while (opt_span) |span| {
                assert(span != span.next);

                if (span.block_count != span.class.block_max) {
                    opt_span = self.removeFromListGetNext(span);

                    if (partial_spans_cur) |partial_span| {
                        assert(partial_span != span);

                        partial_span.next = span;
                        partial_spans_cur = span;
                        span.prev = partial_span;
                    } else {
                        partial_spans_head = span;
                        partial_spans_cur = span;
                    }
                } else {
                    opt_span = span.next;
                }
            }

            return partial_spans_head;
        }

        fn removeFromListGetNext(self: *Self, span: *Span) ?*Span {
            assert(span.prev == null or span.prev != span.next);

            if (span.prev) |prev| prev.next = span.next else self.head = span.next;
            if (span.next) |next| next.prev = span.prev;

            const next = span.next;

            resetSpan(span);

            return next;
        }

        inline fn resetSpan(span: *Span) void {
            span.next = null;
            span.prev = null;
        }

        inline fn assertNotInList(span: *Span) void {
            assert(span.next == null);
            assert(span.prev == null);
        }
    };
}
