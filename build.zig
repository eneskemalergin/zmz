//! Defines the z-mzML package module and verification step.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mzml = b.addModule("z_mzml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const library_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_library.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize == .ReleaseFast,
            .imports = &.{.{ .name = "z_mzml", .module = mzml }},
        }),
    });
    b.getInstallStep().dependOn(&library_tests.step);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&b.addRunArtifact(library_tests).step);
}
