const std = @import("std");
const jdz_allocator = @import("jdz_allocator.zig");
const utils = @import("utils.zig");

const Span = @import("Span.zig");
const JdzAllocConfig = jdz_allocator.JdzAllocConfig;
const testing = std.testing;
const assert = std.debug.assert;

head: ?*Span = null,

const Self = @This();

pub fn write(self: *Self, span: *Span) void {
    while (true) {
        span.next = self.head;

        if (@cmpxchgWeak(?*Span, &self.head, span.next, span, .Monotonic, .Monotonic) == null) {
            return;
        }
    }
}

pub fn getAndRemoveList(self: *Self) ?*Span {
    return @atomicRmw(?*Span, &self.head, .Xchg, null, .Monotonic);
}
