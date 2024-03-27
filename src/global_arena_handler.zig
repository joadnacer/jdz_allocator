const std = @import("std");
const span_arena = @import("arena.zig");
const jdz_allocator = @import("jdz_allocator.zig");
const utils = @import("utils.zig");

const JdzAllocConfig = jdz_allocator.JdzAllocConfig;

const threadlocal_arenas = @cImport({
    @cInclude("threadlocal_arenas.c");
});

const _jdz_get_thread_arena = threadlocal_arenas._jdz_get_thread_arena;
const _jdz_set_thread_arena = threadlocal_arenas._jdz_set_thread_arena;

pub fn GlobalArenaHandler(comptime config: JdzAllocConfig) type {
    const Mutex = utils.getMutexType(config);

    return struct {
        const Arena = span_arena.Arena(config, true);

        var preinit_arena: Arena = Arena.init(.unlocked, 0);
        var arena_list: ?*Arena = &preinit_arena;
        var mutex: Mutex = .{};

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
            const arena: *Arena = @ptrCast(@alignCast(_jdz_get_thread_arena() orelse return));

            _ = arena.deinit();

            _jdz_set_thread_arena(@as(?*anyopaque, null));

            addArenaToList(arena);
        }

        pub inline fn getArena() ?*Arena {
            return getThreadArena() orelse
                getArenaFromList() orelse
                createArena();
        }

        pub inline fn getThreadArena() ?*Arena {
            return @ptrCast(@alignCast(_jdz_get_thread_arena()));
        }

        fn getArenaFromList() ?*Arena {
            mutex.lock();
            defer mutex.unlock();

            if (arena_list) |arena| {
                arena_list = arena.next;
                arena.next = null;
                arena.thread_id = std.Thread.getCurrentId();

                _jdz_set_thread_arena(arena);

                return arena;
            }

            return null;
        }

        fn createArena() ?*Arena {
            const new_arena = config.backing_allocator.create(Arena) catch return null;

            new_arena.* = Arena.init(.unlocked, std.Thread.getCurrentId());

            _jdz_set_thread_arena(new_arena);

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
