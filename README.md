# jdz_allocator: A Zig General Purpose Memory Allocator
jdz_allocator is an original general purpose allocator inspired by Mattias Jansson's [rpmalloc](https://github.com/mjansson/rpmalloc) and Microsoft's [mimalloc](https://github.com/microsoft/mimalloc). Although it currently passes all mimalloc-bench tests without faults, it is not yet battle-tested and may error under certain loads or configurations.

In its default configuration, it uses no global or threadlocal vars, making it compatible with Zig allocator design. This allows it to function without the need for any `deinitThread` calls while still achieving reasonable multi-threaded performance. It may induce false sharing in the case that `N allocating threads > config.shared_arena_batch_size` - I believe this is unavoidable when not using threadlocal variables.

For optimal performance, a global-state-based allocator is available under `jdz_allocator.JdzGlobalAllocator`. With this allocator, make sure to call `deinitThread` before thread termination to free thread memory for re-use. This allocator exists as a singleton-per-configuration, with distinct instances existing for different configs.

Please note that this allocator is a work in progress, and has not yet been thoroughly tested. Usage and bug reports are appreciated and will help contribute to this allocator's completion. Performance is also still being worked on. Contributions are welcome.

This allocator currently does not support page sizes larger than 64KiB.

# mimalloc-bench
The allocator has been benchmarked in mimalloc-bench against InKryption's [rpmalloc Zig port](https://github.com/InKryption/rpmalloc-zig-port), dweiller's [zimalloc](https://github.com/dweiller/zimalloc) and c malloc.

Results here: https://pastebin.com/QDA2UW67

# Zig Benchmarks
The allocator has been benchmarked against Zig std's GeneralPurposeAllocator and c_allocator, as well as InKryption's [rpmalloc Zig port](https://github.com/InKryption/rpmalloc-zig-port) and dweiller's [zimalloc](https://github.com/dweiller/zimalloc). Please note that any mention of rpmalloc in these benchmarks is in reference to the Zig port, not to the original C implementation.

Benchmarks consist of 75,000,000 linearly distributed allocations of 1-80000 bytes per thread, with no cross-thread frees. This is an unrealistic benchmark, and will be improved to further guide development.

jdz_allocator's default configuration performs competitively but is significantly slower than rpmalloc at high contention. The global allocator's performance is consistently matching rpmalloc's, remaining within the margin of error, with considerably less memory usage.

Benchmarks were run on an 8 core Intel i7-11800H @2.30GHz on Linux in ReleaseFast mode.

Benchmarks can be run as follows: `zig run -O ReleaseFast src/bench.zig -lc -- [num_threads...]`.

The allocator can also be linked via LD_PRELOAD for benchmarking with mimalloc-bench using the shared libraries outputted on build - libjdzglobal, libjdzshared and libjdzglobalwrap - the latter adding threadlocal arena deinit calls on pthread destructor.

### Performance
![image](https://i.imgur.com/X93jgs2.png)
### Memory Usage
zimalloc was excluded from the memory usage charts due to too high memory usage (at 16 threads, RSS was ~1.5M bytes and VSZ was ~2M).

![image](https://i.imgur.com/h0MpuMP.png)
![image](https://i.imgur.com/MINQn7b.png)

# Usage
Current master is written in Zig 0.12.0-dev.3522+b88ae8dbd. The allocator can be used as follows:

Create a build.zig.zon file like this:
```zig
.{
    .name = "testlib",
    .version = "0.0.1",

    .dependencies = .{
        .jdz_allocator = .{
            .url = "https://github.com/joadnacer/jdz_allocator/archive/a34e18705529adf8c1dd6e9afb9f38defa9761e8.tar.gz",
            .hash = "122041a5792fa779a0aff08c1fb75e8ab847b8ec102666c309dd0fe07550d3249249" },
    },
}

```

Add these lines to your build.zig:
```zig
const jdz_allocator = b.dependency("jdz_allocator", .{
.target = target,
.optimize = optimize,
});

exe.addModule("jdz_allocator", jdz_allocator.module("jdz_allocator"));
```

Use as follows:
```zig
const jdz_allocator = @import("jdz_allocator");

pub fn main() !void {
    var jdz = jdz_allocator.JdzAllocator(.{}).init();
    defer jdz.deinit();

    const allocator = jdz.allocator();

    const res = try allocator.alloc(u8, 8);
    defer allocator.free(res);
}
```

Or if using the global allocator:
```zig
const jdz_allocator = @import("jdz_allocator");

pub fn main() !void {
    const JdzGlobalAllocator = jdz_allocator.JdzGlobalAllocator(.{});
    defer JdzGlobalAllocator.deinit();
    defer JdzGlobalAllocator.deinitThread(); // call this from every thread that makes an allocation

    const allocator = JdzGlobalAllocator.allocator();

    const res = try allocator.alloc(u8, 8);
    defer allocator.free(res);
}
```

# Design
As in rpmalloc, allocations occur from 64 KiB spans guaranteeing at least 16 byte block alignment, with each span serving one size class. The span header can be obtained from an allocation through the application of a simple bitmask.
There exist 5 size categories:
<ul>
  <li>Small : 16-2048 byte allocations, with 16 byte granularity.</li>
  <li>Medium: 2049-32512 byte allocations, with 256 byte granularity.</li>
  <li>Span  : 32513-65408 byte allocations.</li>
  <li>Large : 65409-4194176 byte allocations, with 64KiB granularity.</li>
  <li>Huge  : 4194177+ byte allocations - allocated and freed directly from backing allocator.</li>
</ul>

Large allocations are made to "large spans" which consist of up to 64 contiguous spans.

Allocations occur from arenas, which may only have one thread allocating at a time, although threads may free concurrently.

Arenas are distributed to threads through the arena_handler, which in the default configuration will distribute arenas stored in a concurrent linked list through the use of try-locks. Threads will attempt to claim arenas as theirs via the storing of thread-ids, but arena stealing will consistently occur for `N allocating threads > config.shared_arena_batch_size`, leading to allocator-induced false sharing.

When used as a global allocator, no arena stealing will occur as arenas will be stored as threadlocal vars, guaranteeing ideal performance.

Arenas consist of the following:
<ul>
  <li>Span Stacks: A locking array of span linked-lists from which small or medium allocations may occur (locking only when removing or adding spans).</li>
  <li>Span Cache: A bounded MPSC queue used as a cache for single spans.</li>
  <li>Large Caches: A non-threadsafe array of bounded stacks, used to cache large spans by span count.</li>
  <li>Map Cache: A non-threadsafe array of bounded stacks, used to cache spans that have been mapped but not yet claimed.</li>
</ul>

The global allocator also makes use of global caches - one for single spans and one for large spans, implemented as bounded MPMC queues. Upon filling of an arena's local caches, or thread deinit, spans will be freed to the global cache to be reused by other arenas.
