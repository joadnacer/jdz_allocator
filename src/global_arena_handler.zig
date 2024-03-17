const std = @import("std");
const span_arena = @import("arena.zig");
const jdz_allocator = @import("jdz_allocator.zig");
const utils = @import("utils.zig");

const JdzAllocConfig = jdz_allocator.JdzAllocConfig;

pub fn GlobalArenaHandler(comptime config: JdzAllocConfig) type {
    const Mutex = utils.getMutexType(config);

    return struct {
        const Arena = span_arena.Arena(config, true);

        var preinit_arena: Arena = Arena.init(.unlocked, 0);
        var arena_list: ?*Arena = &preinit_arena;
        var mutex: Mutex = .{};

        threadlocal var thread_arena: ?*Arena = null;

        pub fn deinit() void {
            mutex.lock();
            defer mutex.unlock();

            var opt_arena = arena_list;

            while (opt_arena) |arena| {
                const next = arena.next;

                if (arena != &preinit_arena) {
                    config.backing_allocator.destroy(arena);
                }

                opt_arena = next;
            }
        }

        pub fn deinitThread() void {
            const arena = thread_arena orelse return;

            _ = arena.deinit();

            thread_arena = null;

            addArenaToList(arena);
        }

        pub inline fn getArena() ?*Arena {
            return thread_arena orelse
                getArenaFromList() orelse
                createArena();
        }

        pub inline fn getThreadArena() ?*Arena {
            return thread_arena;
        }

        fn getArenaFromList() ?*Arena {
            mutex.lock();
            defer mutex.unlock();

            if (arena_list) |arena| {
                arena_list = arena.next;
                arena.next = null;
                arena.thread_id = std.Thread.getCurrentId();

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

        fn addArenaToList(new_arena: *Arena) void {
            mutex.lock();
            defer mutex.unlock();

            if (arena_list == null) {
                arena_list = new_arena;

                return;
            }

            var arena = arena_list.?;

            while (arena.next) |next| {
                arena = next;
            }

            arena.next = new_arena;
        }
    };
}
