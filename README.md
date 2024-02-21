# jdz_allocator: A Zig General Purpose Memory Allocator
jdz_allocator is an original general purpose allocator inspired by Mattias Jansson's [rpmalloc](https://github.com/mjansson/rpmalloc). It is currently a work in progress, and segfaults on one [mimalloc-bench](https://github.com/daanx/mimalloc-bench) test. The current focus is on improving performance, and I would not advise using this yet.

In its default configuration, it uses no global or threadlocal vars, making it compatible with Zig allocator design. This allows it to function without the need for any `deinitThread` calls while still achieving reasonable multi-threaded performance.

If multithreaded performance is essential, and cannot be handled appropriately through the use of multiple allocator instances, a global allocator is available under `jdz_allocator.JdzGlobalAllocator`. With this allocator, make sure to call `deinitThread` before thread termination to free thread memory for re-use. This allocator exists as a singleton-per-configuration, with distinct instances existing for different configs.

Please note that this allocator is a work in progress, and has not yet been thoroughly tested. Usage and bug reports are appreciated and will help contribute to this allocator's completion.

Performance is also still being worked on, with a few obvious targets for improvement.

This allocator currently does not support page sizes larger than 64KiB.

# Benchmarks
The allocator has been benchmarked against Zig std's GeneralPurposeAllocator and c_allocator, as well as InKryption's [rpmalloc Zig port](https://github.com/InKryption/rpmalloc-zig-port) and dweiller's [zimalloc](https://github.com/dweiller/zimalloc). Please note that any mention of rpmalloc in these benchmarks is in reference to the Zig port, not to the original C implementation.

Benchmarks consist of 75,000,000 linearly distributed allocations of 1-80000 bytes per thread, with no cross-thread frees. This is an unrealistic benchmark, and will be improved to further guide development.

jdz_allocator's default configuration performs competitively but is significantly slower than rpmalloc at high contention. The global allocator's performance is consistently matching rpmalloc's, remaining within the margin of error, with considerably less memory usage.

Benchmarks were run on an 8 core Intel i7-11800H @2.30GHz on Linux in ReleaseFast mode.

Benchmarks can be run as follows: `zig run -O ReleaseFast src/bench.zig -lc -- [num_threads...]`.

src/bench.zig in this repo does not contain rpmalloc or zimalloc - more complete benchmarks will eventually be posted to a parallel repository.

### Performance
![image](https://i.imgur.com/X93jgs2.png)
### Memory Usage
zimalloc was excluded from the memory usage charts due to too high memory usage (at 16 threads, RSS was ~1.5M bytes and VSZ was ~2M).

![image](https://i.imgur.com/h0MpuMP.png)
![image](https://i.imgur.com/MINQn7b.png)

# Usage
Currently this project has been built for Zig 0.11.0. The allocator can be used as follows:

Create a build.zig.zon file like this:
```zig
.{
    .name = "testlib",
    .version = "0.0.1",

    .dependencies = .{
        .jdz_allocator = .{
            .url = "https://github.com/joadnacer/jdz_allocator/archive/4fbfaf5883e1f1117dd5b410fdbfef8de23984d3.tar.gz",
            .hash = "1220e341421a18a8682c5707ed52ef7e60d1d40a723bfa9c9bf16d900fb57c21d480" },
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
    const jdz = jdz_allocator.JdzGlobalAllocator(.{});
    defer jdz.deinit();
    defer jdz.deinitThread(); // call this from every thread that makes an allocation

    const allocator = jdz.allocator();

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

Arenas are distributed to threads through the arena_handler, which in the default configuration will distribute arenas stored in a concurrent linked list through the use of try-locks. Threads will attempt to claim arenas as theirs via the storing of thread-ids, but arena stealing will consistently occur.

When used as a global allocator, no arena stealing will occur as arenas will be stored as threadlocal vars, guaranteeing ideal performance.

Arenas consist of the following:
<ul>
  <li>Span Stacks: A locking array of span linked-lists from which small or medium allocations may occur (locking only when removing or adding spans).</li>
  <li>Span Cache: A bounded MPSC queue used as a cache for single spans.</li>
  <li>Large Caches: A non-threadsafe array of bounded stacks, used to cache large spans by span count.</li>
  <li>Map Cache: A non-threadsafe array of bounded stacks, used to cache spans that have been mapped but not yet claimed.</li>
</ul>

Spans, the span stack and the global arena handler's arena list (which is not ABA safe, unlike the non-global arena handler's) are currently protected with mutexes. This will likely be improved in the future, with the first two needing to be benchmarked with cross-thread frees.
