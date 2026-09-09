//! Defines the z-mzML package module and verification step.

const std = @import("std");

const NumpressSlofMathBackend = enum { bundled, glibc_vector };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const numpress_slof_math_backend = b.option(
        NumpressSlofMathBackend,
        "numpress_slof_math_backend",
        "Select bundled or Linux x86_64 glibc vector SLOF math",
    ) orelse .bundled;

    const mzml = b.addModule("z_mzml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = if (numpress_slof_math_backend == .glibc_vector) true else null,
    });
    const numpress_options = b.addOptions();
    numpress_options.addOption(
        []const u8,
        "slof_math_backend",
        @tagName(numpress_slof_math_backend),
    );
    mzml.addOptions("numpress_math_options", numpress_options);
    if (numpress_slof_math_backend == .glibc_vector) {
        mzml.linkSystemLibrary("mvec", .{ .use_pkg_config = .no });
    }

    const test_step = b.step("test", "Run library tests");
    inline for (.{
        "tests/test_numpress.zig",
        "tests/test_binary.zig",
        "tests/test_cv.zig",
    }) |test_root| {
        const library_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_root),
                .target = target,
                .optimize = optimize,
                .strip = optimize == .ReleaseFast,
                .imports = &.{.{ .name = "z_mzml", .module = mzml }},
            }),
        });
        b.getInstallStep().dependOn(&library_tests.step);
        test_step.dependOn(&b.addRunArtifact(library_tests).step);
    }
}
