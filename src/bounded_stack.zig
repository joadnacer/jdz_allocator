const std = @import("std");
const utils = @import("utils.zig");

const testing = std.testing;
const assert = std.debug.assert;

pub fn BoundedStack(comptime T: type, comptime buffer_size: usize) type {
    return struct {
        count: usize,
        buffer: [buffer_size]T,

        const Self = @This();

        pub fn init() BoundedStack(T, buffer_size) {
            return .{
                .count = 0,
                .buffer = undefined,
            };
        }

        pub fn tryWrite(self: *Self, data: T) bool {
            if (self.count == buffer_size) return false;

            self.buffer[self.count] = data;
            self.count += 1;

            return true;
        }

        pub fn tryRead(self: *Self) ?T {
            if (self.count == 0) return null;

            self.count -= 1;

            return self.buffer[self.count];
        }
    };
}

test "tryWrite/tryRead" {
    var queue = BoundedStack(u64, 16).init();

    _ = queue.tryWrite(17);
    _ = queue.tryWrite(36);

    try testing.expect(queue.tryRead().? == 36);
    try testing.expect(queue.tryRead().? == 17);
}

test "tryRead empty" {
    var queue = BoundedStack(u64, 16).init();

    try testing.expect(queue.tryRead() == null);
}

test "tryRead emptied" {
    var queue = BoundedStack(u64, 2).init();

    _ = queue.tryWrite(1);
    _ = queue.tryWrite(2);

    try testing.expect(queue.tryRead().? == 2);
    try testing.expect(queue.tryRead().? == 1);
    try testing.expect(queue.tryRead() == null);
}

test "tryWrite to full" {
    var queue = BoundedStack(u64, 2).init();

    _ = queue.tryWrite(1);
    _ = queue.tryWrite(2);

    try testing.expect(queue.tryWrite(3) == false);
    try testing.expect(queue.tryRead().? == 2);
    try testing.expect(queue.tryRead().? == 1);
}
