const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const jdz_allocator = b.addModule("jdz_allocator", .{ .source_file = .{
        .path = "src/jdz_allocator.zig",
    } });

    const static_lib = b.addStaticLibrary(.{
        .name = "jdz_allocator",
        .root_source_file = .{ .path = "src/jdz_allocator.zig" },
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(static_lib);

    const libjdzglobal = b.addSharedLibrary(.{
        .name = "jdzglobal",
        .root_source_file = .{ .path = "libso/libjdzglobal.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    libjdzglobal.addModule("jdz_allocator", jdz_allocator);

    b.installArtifact(libjdzglobal);

    const libjdzglobalwrap = b.addSharedLibrary(.{
        .name = "jdzglobalwrap",
        .root_source_file = .{ .path = "libso/libjdzglobal.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    libjdzglobalwrap.addCSourceFile(.{
        .file = .{ .path = "libso/libjdzglobalwrap.c" },
        .flags = &[_][]const u8{},
    });

    libjdzglobalwrap.addModule("jdz_allocator", jdz_allocator);

    b.installArtifact(libjdzglobalwrap);

    const libjdzshared = b.addSharedLibrary(.{
        .name = "jdzshared",
        .root_source_file = .{ .path = "libso/libjdzshared.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    libjdzshared.addModule("jdz_allocator", jdz_allocator);

    b.installArtifact(libjdzshared);

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/jdz_allocator.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_source_file = .{ .path = "src/bench.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const grow_shrink_bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_source_file = .{ .path = "src/grow_shrink_bench.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    b.installArtifact(bench_exe);
    b.installArtifact(grow_shrink_bench_exe);

    const run_bench_exe = b.addRunArtifact(bench_exe);
    const run_grow_shrink_bench_exe = b.addRunArtifact(grow_shrink_bench_exe);

    const run_bench_step = b.step("run-bench", "Run src/bench.zig");
    run_bench_step.dependOn(&run_bench_exe.step);

    const run_grow_shrink_bench_step = b.step("run-grow-shrink-bench", "Run src/grow_shrink_bench.zig");
    run_grow_shrink_bench_step.dependOn(&run_grow_shrink_bench_exe.step);
}
