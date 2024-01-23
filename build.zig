const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("jdz_allocator", .{ .source_file = .{
        .path = "src/jdz_allocator.zig",
    } });

    const lib = b.addStaticLibrary(.{
        .name = "jdz_allocator",
        .root_source_file = .{ .path = "src/jdz_allocator.zig" },
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/jdz_allocator.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);
}
