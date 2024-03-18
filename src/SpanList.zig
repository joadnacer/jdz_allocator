const std = @import("std");
const jdz_allocator = @import("jdz_allocator.zig");
const utils = @import("utils.zig");
const static_config = @import("static_config.zig");

const Span = @import("Span.zig");
const JdzAllocConfig = jdz_allocator.JdzAllocConfig;
const testing = std.testing;
const assert = std.debug.assert;

head: ?*Span = null,
tail: ?*Span = null,

const Self = @This();

pub fn write(self: *Self, span: *Span) void {
    assertNotInList(span);

    if (self.tail) |tail| {
        tail.next = span;
        self.tail = span;
        span.prev = tail;
    } else {
        self.head = span;
        self.tail = span;
    }
}

pub inline fn tryRead(self: *Self) ?*Span {
    return self.head;
}

pub fn remove(self: *Self, span: *Span) void {
    assert(span.prev == null or span.prev != span.next);

    if (span.prev) |prev| prev.next = span.next else self.head = span.next;
    if (span.next) |next| next.prev = span.prev else self.tail = span.prev;

    utils.resetLinkedSpan(span);
}

pub fn removeHead(self: *Self) *Span {
    assert(self.head != null);

    const head = self.head.?;
    self.head = head.next;

    if (self.head) |new_head| {
        new_head.prev = null;
    } else {
        self.tail = null;
    }

    utils.resetLinkedSpan(head);

    return head;
}

pub fn writeLinkedSpans(self: *Self, linked_spans: *Span) void {
    if (self.tail) |tail| {
        tail.next = linked_spans;
        linked_spans.prev = tail;
    } else {
        self.head = linked_spans;
    }

    var span = linked_spans;

    while (span.next) |next| {
        next.prev = span;

        span = next;
    }

    self.tail = span;
}

pub fn getEmptySpans(self: *Self) ?*Span {
    if (self.head == null) return null;

    var empty_spans_head: ?*Span = null;
    var empty_spans_cur: ?*Span = null;

    var opt_span = self.head;

    while (opt_span) |span| {
        assert(span != span.next);

        if (span.isEmpty()) {
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

pub fn getHeadFreeList(self: *Self) *usize {
    if (self.head) |head| {
        return &head.free_list;
    } else {
        return @constCast(&static_config.free_list_null);
    }
}

fn removeFromListGetNext(self: *Self, span: *Span) ?*Span {
    const next = span.next;

    self.remove(span);

    return next;
}

inline fn assertNotInList(span: *Span) void {
    assert(span.next == null);
    assert(span.prev == null);
}
