//! Defines the zmz package module, compiled examples, and test steps.

const std = @import("std");

const NumpressSlofMathBackend = enum { bundled, glibc_vector };
const LibraryTest = struct {
    root_source_file: []const u8,
    add_gates_support: bool = false,
};
const library_test_specs = [_]LibraryTest{
    .{ .root_source_file = "tests/binary/test_numpress.zig" },
    .{ .root_source_file = "tests/binary/test_codecs.zig" },
    .{ .root_source_file = "tests/cv/test_cv.zig" },
    .{ .root_source_file = "tests/mzml/test_metadata.zig" },
    .{ .root_source_file = "tests/mzml/test_construction.zig" },
    .{ .root_source_file = "tests/mzml/test_indexing.zig" },
    .{ .root_source_file = "tests/mzml/test_ownership.zig" },
    .{ .root_source_file = "tests/mzml/test_writing.zig" },
    .{ .root_source_file = "tests/mzml/test_reader.zig", .add_gates_support = true },
};

fn configureLibraryModule(
    module: *std.Build.Module,
    numpress_options: *std.Build.Step.Options,
    base64_options: *std.Build.Step.Options,
    use_glibc_vector: bool,
) void {
    module.addOptions("numpress_math_options", numpress_options);
    module.addOptions("base64_options", base64_options);
    if (use_glibc_vector) module.linkSystemLibrary("mvec", .{ .use_pkg_config = .no });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});
    const strip = optimize == .ReleaseFast or optimize == .ReleaseSmall;
    const numpress_slof_math_backend = b.option(
        NumpressSlofMathBackend,
        "numpress_slof_math_backend",
        "Select bundled or Linux x86_64 glibc vector SLOF math",
    ) orelse .bundled;
    const use_glibc_vector = numpress_slof_math_backend == .glibc_vector;
    const link_libc: ?bool = if (use_glibc_vector) true else null;
    const zmz = b.addModule("zmz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = link_libc,
    });
    const numpress_options = b.addOptions();
    numpress_options.addOption(
        []const u8,
        "slof_math_backend",
        @tagName(numpress_slof_math_backend),
    );
    const base64_options = b.addOptions();
    base64_options.addOption(bool, "simd", b.option(bool, "base64_simd", "Select AVX2 at runtime when available; false forces scalar") orelse true);
    configureLibraryModule(zmz, numpress_options, base64_options, use_glibc_vector);

    const test_step = b.step("test", "Run library tests");
    const gates_test_support = b.createModule(.{
        .root_source_file = b.path("tests/data/gates/support.zig"),
        .target = target,
        .optimize = optimize,
    });
    for (library_test_specs) |test_spec| {
        const test_module = b.createModule(.{
            .root_source_file = b.path(test_spec.root_source_file),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        });
        test_module.addImport("zmz", zmz);
        if (test_spec.add_gates_support)
            test_module.addImport("gates_test_support", gates_test_support);
        const library_test_artifact = b.addTest(.{ .root_module = test_module });
        test_step.dependOn(&b.addRunArtifact(library_test_artifact).step);
    }

    const package_tests_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = link_libc,
    });
    configureLibraryModule(package_tests_module, numpress_options, base64_options, use_glibc_vector);
    const package_tests = b.addTest(.{ .root_module = package_tests_module });
    test_step.dependOn(&b.addRunArtifact(package_tests).step);

    const examples_step = b.step("examples", "Build and install the mzML usage examples");
    const example_test_options = b.addOptions();
    for ([_][]const u8{ "stream", "select", "indexed", "write", "rewrite" }) |name| {
        const executable = b.addExecutable(.{
            .name = b.fmt("mzml-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .strip = strip,
                .imports = &.{.{ .name = "zmz", .module = zmz }},
            }),
        });
        examples_step.dependOn(&b.addInstallArtifact(executable, .{}).step);
        example_test_options.addOptionPath(name, executable.getEmittedBin());
    }
    const example_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/mzml/test_examples.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{.{ .name = "zmz", .module = zmz }},
    });
    example_tests_module.addOptions("example_test_options", example_test_options);
    const example_tests = b.addTest(.{ .root_module = example_tests_module });
    const example_test_run = b.addRunArtifact(example_tests);
    test_step.dependOn(&example_test_run.step);
    b.step("test-examples", "Run the compiled mzML examples on small fixtures").dependOn(&example_test_run.step);

    const file_check = b.addExecutable(.{
        .name = "check-mzml",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_mzml.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{.{ .name = "zmz", .module = zmz }},
        }),
    });
    const check_file = b.addRunArtifact(file_check);
    if (b.args) |args| check_file.addArgs(args);
    const check_step = b.step("check-mzml", "Read, decode, and compare indexed lookups in explicit external files");
    check_step.dependOn(&check_file.step);
    check_step.dependOn(&b.addInstallArtifact(file_check, .{}).step);

    const vocabulary_module = b.createModule(.{
        .root_source_file = b.path("tools/vocabulary.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{.{ .name = "zmz", .module = zmz }},
    });
    vocabulary_module.addAnonymousImport("pinned_manifest", .{
        .root_source_file = b.path("vocabularies/manifest.json"),
    });
    const vocabulary = b.addExecutable(.{ .name = "vocabulary", .root_module = vocabulary_module });
    const vocabulary_run = b.addRunArtifact(vocabulary);
    if (b.args) |args| vocabulary_run.addArgs(args);
    b.step("vocabulary", "Generate or review explicit local vocabulary resources offline").dependOn(&vocabulary_run.step);
    const vocabulary_tests = b.addTest(.{ .root_module = vocabulary_module });
    test_step.dependOn(&b.addRunArtifact(vocabulary_tests).step);

    const vocabulary_test_options = b.addOptions();
    vocabulary_test_options.addOptionPath("executable", vocabulary.getEmittedBin());
    const vocabulary_cli_test_module = b.createModule(.{
        .root_source_file = b.path("tests/cli/test_vocabulary.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{.{ .name = "vocabulary_test_options", .module = vocabulary_test_options.createModule() }},
    });
    vocabulary_cli_test_module.addImport("gates_test_support", gates_test_support);
    const vocabulary_cli_tests = b.addTest(.{ .root_module = vocabulary_cli_test_module });
    test_step.dependOn(&b.addRunArtifact(vocabulary_cli_tests).step);
}
