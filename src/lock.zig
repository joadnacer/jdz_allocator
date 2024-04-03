const std = @import("std");

pub const Lock = enum {
    unlocked,
    locked,

    pub fn tryAcquire(lock: *Lock) bool {
        return @cmpxchgStrong(Lock, lock, .unlocked, .locked, .acquire, .monotonic) == null;
    }

    pub fn acquire(lock: *Lock) void {
        while (@cmpxchgWeak(Lock, lock, .unlocked, .locked, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn release(lock: *Lock) void {
        @atomicStore(Lock, lock, .unlocked, .release);
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
