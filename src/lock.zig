const std = @import("std");

pub const Lock = enum {
    unlocked,
    locked,

    pub fn tryAcquire(lock: *Lock) bool {
        return @cmpxchgWeak(Lock, lock, .unlocked, .locked, .Acquire, .Monotonic) == null;
    }

    pub fn acquire(lock: *Lock) void {
        while (@cmpxchgWeak(Lock, lock, .unlocked, .locked, .Acquire, .Monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn release(lock: *Lock) void {
        @atomicStore(Lock, lock, .unlocked, .Release);
    }
};

pub const DummyLock = enum {
    unlocked,
    locked,

    pub fn tryAcquire(lock: *DummyLock) bool {
        _ = lock;
        return true;
    }

    pub fn acquire(lock: *DummyLock) void {
        _ = lock;
    }

    pub fn release(lock: *DummyLock) void {
        _ = lock;
    }
};
