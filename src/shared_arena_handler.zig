const std = @import("std");
const span_arena = @import("arena.zig");
const jdz_allocator = @import("jdz_allocator.zig");

const JdzAllocConfig = jdz_allocator.JdzAllocConfig;

pub fn SharedArenaHandler(comptime config: JdzAllocConfig) type {
    const Arena = span_arena.Arena(config, false);

    return struct {
        arena_list: ?*Arena,

        const Self = @This();

        pub fn init() Self {
            return .{
                .arena_list = null,
            };
        }

        pub fn deinit(self: *Self) usize {
            var spans_leaked: usize = 0;
            var opt_arena = self.arena_list;

            while (opt_arena) |arena| {
                const next = arena.next;

                spans_leaked += arena.deinit();

                config.backing_allocator.destroy(arena);

                opt_arena = next;
            }

            return spans_leaked;
        }

        pub fn getArena(self: *Self) ?*Arena {
            const tid = std.Thread.getCurrentId();

            return self.findOwnedThreadArena(tid) orelse
                self.claimOrCreateArena(tid);
        }

        fn findOwnedThreadArena(self: *Self, tid: std.Thread.Id) ?*Arena {
            var opt_arena = self.arena_list;

            while (opt_arena) |list_arena| {
                if (list_arena.thread_id == tid) {
                    return acquireArena(list_arena, tid) orelse break;
                }

                opt_arena = list_arena.next;
            }

            return null;
        }

        fn claimOrCreateArena(self: *Self, tid: std.Thread.Id) ?*Arena {
            var opt_arena = self.arena_list;

            while (opt_arena) |arena| {
                return acquireArena(arena, tid) orelse {
                    opt_arena = arena.next;

                    continue;
                };
            }

            return self.createArena();
        }

        fn createArena(self: *Self) ?*Arena {
            const new_arena = config.backing_allocator.create(Arena) catch return null;

            new_arena.* = Arena.init(.locked, std.Thread.getCurrentId());

            self.addArenaToList(new_arena);

            return new_arena;
        }

        fn addArenaToList(self: *Self, new_arena: *Arena) void {
            while (self.arena_list == null) {
                if (@cmpxchgWeak(?*Arena, &self.arena_list, null, new_arena, .Monotonic, .Monotonic) == null) {
                    return;
                }
            }

            var arena = self.arena_list.?;

            while (true) {
                while (arena.next) |next| {
                    arena = next;
                }

                if (@cmpxchgWeak(?*Arena, &arena.next, null, new_arena, .Monotonic, .Monotonic) == null) {
                    return;
                }
            }
        }

        fn acquireArena(arena: *Arena, tid: std.Thread.Id) ?*Arena {
            if (arena.tryAcquire()) {
                arena.thread_id = tid;

                return arena;
            }

            return null;
        }
    };
}
