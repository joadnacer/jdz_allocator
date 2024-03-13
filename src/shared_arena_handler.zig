const std = @import("std");
const span_arena = @import("arena.zig");
const jdz_allocator = @import("jdz_allocator.zig");
const utils = @import("utils.zig");

const JdzAllocConfig = jdz_allocator.JdzAllocConfig;

const assert = std.debug.assert;

threadlocal var cached_thread_id: ?std.Thread.Id = null;

pub fn SharedArenaHandler(comptime config: JdzAllocConfig) type {
    const Arena = span_arena.Arena(config, false);

    const Mutex = utils.getMutexType(config);

    return struct {
        arena_list: ?*Arena,
        mutex: Mutex,
        arena_batch: u32,

        const Self = @This();

        pub fn init() Self {
            return .{
                .arena_list = null,
                .mutex = .{},
                .arena_batch = 0,
            };
        }

        pub fn deinit(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();

            var spans_leaked: usize = 0;
            var opt_arena = self.arena_list;

            while (opt_arena) |arena| {
                const next = arena.next;

                spans_leaked += arena.deinit();

                opt_arena = next;
            }

            while (opt_arena) |arena| {
                const next = arena.next;

                if (arena.is_alloc_master) {
                    config.backing_allocator.destroy(arena);
                }

                opt_arena = next;
            }

            return spans_leaked;
        }

        pub inline fn getArena(self: *Self) ?*Arena {
            const tid = getThreadId();

            return self.findOwnedThreadArena(tid) orelse
                self.claimOrCreateArena(tid);
        }

        inline fn findOwnedThreadArena(self: *Self, tid: std.Thread.Id) ?*Arena {
            var opt_arena = self.arena_list;

            while (opt_arena) |list_arena| {
                if (list_arena.thread_id == tid or list_arena.thread_id == null) {
                    return acquireArena(list_arena, tid) orelse continue;
                }

                opt_arena = list_arena.next;
            }

            return null;
        }

        inline fn claimOrCreateArena(self: *Self, tid: std.Thread.Id) ?*Arena {
            var opt_arena = self.arena_list;

            while (opt_arena) |arena| {
                return acquireArena(arena, tid) orelse {
                    opt_arena = arena.next;

                    continue;
                };
            }

            return self.tryCreateArena();
        }

        fn tryCreateArena(self: *Self) ?*Arena {
            const arena_batch = self.arena_batch;

            self.mutex.lock();
            defer self.mutex.unlock();

            if (arena_batch != self.arena_batch) {
                return self.getArena();
            }

            return self.createArena();
        }

        fn createArena(self: *Self) ?*Arena {
            var new_arenas = config.backing_allocator.alloc(Arena, config.shared_arena_batch_size) catch {
                return null;
            };

            self.arena_batch += 1;

            for (new_arenas) |*new_arena| {
                new_arena.* = Arena.init(.unlocked, null);
            }

            new_arenas[0].makeMaster();
            const acquired = acquireArena(&new_arenas[0], getThreadId());

            assert(acquired != null);

            for (new_arenas) |*new_arena| {
                self.addArenaToList(new_arena);
            }

            return acquired;
        }

        fn addArenaToList(self: *Self, new_arena: *Arena) void {
            if (self.arena_list == null) {
                self.arena_list = new_arena;

                return;
            }

            var arena = self.arena_list.?;

            while (arena.next) |next| {
                arena = next;
            }

            arena.next = new_arena;
        }

        inline fn acquireArena(arena: *Arena, tid: std.Thread.Id) ?*Arena {
            if (arena.tryAcquire()) {
                arena.thread_id = tid;

                return arena;
            }

            return null;
        }

        inline fn getThreadId() std.Thread.Id {
            return cached_thread_id orelse {
                cached_thread_id = std.Thread.getCurrentId();

                return cached_thread_id.?;
            };
        }
    };
}
