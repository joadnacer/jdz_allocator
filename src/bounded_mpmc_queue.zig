const std = @import("std");
const utils = @import("utils.zig");
const testing = std.testing;
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;
const Ordering = std.atomic.Ordering;

const cache_line = std.atomic.cache_line;

/// Array based bounded multiple producer multiple consumer queue
/// This is a Zig port of Dmitry Vyukov's https://www.1024cores.net/home/lock-free-algorithms/queues/bounded-mpmc-queue
pub fn BoundedMpmcQueue(comptime T: type, comptime buffer_size: usize) type {
    assert(utils.isPowerOfTwo(buffer_size));

    const buffer_mask = buffer_size - 1;

    const Cell = struct {
        sequence: Atomic(usize),
        data: T,
    };

    return struct {
        enqueue_pos: Atomic(usize) align(cache_line),
        dequeue_pos: Atomic(usize) align(cache_line),
        buffer: [buffer_size]Cell,

        const Self = @This();

        pub fn init() BoundedMpmcQueue(T, buffer_size) {
            var buf: [buffer_size]Cell = undefined;

            for (&buf, 0..) |*cell, i| {
                cell.sequence = Atomic(usize).init(i);
            }

            return .{
                .enqueue_pos = Atomic(usize).init(0),
                .dequeue_pos = Atomic(usize).init(0),
                .buffer = buf,
            };
        }

        /// Attempts to write to the queue, without overwriting any data
        /// Returns `true` if the data is written, `false` if the queue was full
        pub fn tryWrite(self: *Self, data: T) bool {
            @setCold(true);

            var pos = self.enqueue_pos.load(Ordering.Monotonic);

            var cell: *Cell = undefined;

            while (true) {
                cell = &self.buffer[pos & buffer_mask];
                const seq = cell.sequence.load(Ordering.Acquire);
                const diff = @as(i128, seq) - @as(i128, pos);

                if (diff == 0 and utils.tryCASAddOne(&self.enqueue_pos, pos, Ordering.Monotonic) == null) {
                    break;
                } else if (diff < 0) {
                    return false;
                } else {
                    pos = self.enqueue_pos.load(Ordering.Monotonic);
                }
            }

            cell.data = data;
            cell.sequence.store(pos + 1, Ordering.Release);

            return true;
        }

        /// Attempts to read and remove the head element of the queue
        /// Returns `null` if there was no element to read
        pub fn tryRead(self: *Self) ?T {
            @setCold(true);

            var cell: *Cell = undefined;
            var pos = self.dequeue_pos.load(Ordering.Monotonic);

            while (true) {
                cell = &self.buffer[pos & buffer_mask];
                const seq = cell.sequence.load(Ordering.Acquire);
                const diff = @as(i128, seq) - @as(i128, (pos + 1));

                if (diff == 0 and utils.tryCASAddOne(&self.dequeue_pos, pos, Ordering.Monotonic) == null) {
                    break;
                } else if (diff < 0) {
                    return null;
                } else {
                    pos = self.dequeue_pos.load(Ordering.Monotonic);
                }
            }

            const res = cell.data;
            cell.sequence.store(pos + buffer_mask + 1, Ordering.Release);

            return res;
        }
    };
}

test "tryWrite/tryRead" {
    var queue = BoundedMpmcQueue(u64, 16).init();

    _ = queue.tryWrite(17);
    _ = queue.tryWrite(36);

    try testing.expect(queue.tryRead().? == 17);
    try testing.expect(queue.tryRead().? == 36);
}

test "tryRead empty" {
    var queue = BoundedMpmcQueue(u64, 16).init();

    try testing.expect(queue.tryRead() == null);
}

test "tryRead emptied" {
    var queue = BoundedMpmcQueue(u64, 2).init();

    _ = queue.tryWrite(1);
    _ = queue.tryWrite(2);

    try testing.expect(queue.tryRead().? == 1);
    try testing.expect(queue.tryRead().? == 2);
    try testing.expect(queue.tryRead() == null);
}

test "tryWrite to full" {
    var queue = BoundedMpmcQueue(u64, 2).init();

    _ = queue.tryWrite(1);
    _ = queue.tryWrite(2);

    try testing.expect(queue.tryWrite(3) == false);
    try testing.expect(queue.tryRead().? == 1);
    try testing.expect(queue.tryRead().? == 2);
}
