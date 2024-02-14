const std = @import("std");
const span_arena = @import("arena.zig");
const jdz_allocator = @import("jdz_allocator.zig");
const utils = @import("utils.zig");

const JdzAllocConfig = jdz_allocator.JdzAllocConfig;

pub fn GlobalArenaHandler(comptime config: JdzAllocConfig) type {
    const Arena = span_arena.Arena(config);

    const Mutex = utils.getMutexType(config);

    return struct {
        arena_list: ?*Arena,
        // using mutex as not ABA free - can be done better in future
        mutex: Mutex,

        threadlocal var thread_arena: ?*Arena = null;

        const Self = @This();

        pub fn init() Self {
            return .{
                .arena_list = null,
                .mutex = .{},
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

                config.backing_allocator.destroy(arena);

                opt_arena = next;
            }

            return spans_leaked;
        }

        pub fn deinitThread(self: *Self) void {
            const arena = thread_arena orelse return;

            thread_arena = null;

            self.addArenaToList(arena);
        }

        pub fn getArena(self: *Self) ?*Arena {
            return thread_arena orelse
                self.getArenaFromList() orelse
                createArena();
        }

        inline fn getArenaFromList(self: *Self) ?*Arena {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.arena_list) |arena| {
                arena.next = null;

                thread_arena = arena;

                return arena;
            }

            return null;
        }

        fn createArena() ?*Arena {
            const new_arena = config.backing_allocator.create(Arena) catch return null;

            new_arena.* = Arena.init(.unlocked, std.Thread.getCurrentId());

            thread_arena = new_arena;

            return new_arena;
        }

        fn addArenaToList(self: *Self, new_arena: *Arena) void {
            self.mutex.lock();
            defer self.mutex.unlock();

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
    };
}
