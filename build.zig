//! Defines the zmz module and its `-Dkernel_backend` option (`dispatch` also builds a separate
//! x86-64-v3 zlib decoder object), the example programs, the `check-mzml` and `vocabulary` tool
//! steps, and the test steps.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});
    const strip = optimize == .ReleaseFast or optimize == .ReleaseSmall;
    const kernel_backend = b.option(
        KernelBackend,
        "kernel_backend",
        "dispatch: pick CPU-specific code for the running CPU; portable: never use it",
    ) orelse .dispatch;
    const library_kernels = buildKernels(b, target, optimize, kernel_backend);
    const zmz = b.addModule("zmz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    configureLibraryModule(zmz, library_kernels);

    const test_step = b.step("test", "Run the library, example, and tool tests");
    const empty_run = b.path("tests/data/gates/empty_run.mzML");
    const library_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/library.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    library_tests_module.addImport("zmz", zmz);
    library_tests_module.addAnonymousImport("empty_run", .{ .root_source_file = empty_run });
    const library_tests = b.addTest(.{ .root_module = library_tests_module });
    test_step.dependOn(&b.addRunArtifact(library_tests).step);

    const package_tests_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    configureLibraryModule(package_tests_module, library_kernels);
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
    const check_test_options = b.addOptions();
    check_test_options.addOptionPath("executable", file_check.getEmittedBin());
    const check_cli_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/cli/test_check_mzml.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{.{ .name = "check_test_options", .module = check_test_options.createModule() }},
    }) });
    test_step.dependOn(&b.addRunArtifact(check_cli_tests).step);

    // Always ReleaseFast, the library and its dependency included: the numbers describe release
    // builds whatever -Doptimize says.
    const bench_zmz = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = .ReleaseFast });
    configureLibraryModule(bench_zmz, buildKernels(b, target, .ReleaseFast, kernel_backend));
    const bench = b.addExecutable(.{
        .name = "zmz-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .strip = true,
            .imports = &.{.{ .name = "zmz", .module = bench_zmz }},
        }),
    });
    // The generator and cases are checked like the rest, in the requested mode, on tiny inputs.
    const bench_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{.{ .name = "zmz", .module = zmz }},
    }) });
    test_step.dependOn(&b.addRunArtifact(bench_tests).step);
    const bench_run = b.addRunArtifact(bench);
    bench_run.addArg(b.cache_root.join(b.allocator, &.{"zmz-bench"}) catch @panic("OOM"));
    b.step("bench", "Generate inputs and time reading, decoding, lookup, copying, and writing (ReleaseFast)").dependOn(&bench_run.step);

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
    b.step("vocabulary", "Inspect, review, or generate vocabulary resources, or scan explicit mzML files, offline").dependOn(&vocabulary_run.step);
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
    vocabulary_cli_test_module.addAnonymousImport("empty_run", .{ .root_source_file = empty_run });
    vocabulary_cli_test_module.addAnonymousImport("manifest", .{ .root_source_file = b.path("vocabularies/manifest.json") });
    const vocabulary_cli_tests = b.addTest(.{ .root_module = vocabulary_cli_test_module });
    test_step.dependOn(&b.addRunArtifact(vocabulary_cli_tests).step);
}

const KernelBackend = enum { dispatch, portable };
// How the x86-64-v3 zlib decoder reaches a build: the target already has the features (the
// module's own decoder is that fast), a separate object chosen at run time, or not at all.
const FastZlib = enum { direct, object, absent };
const V3_FEATURES = [_]std.Target.x86.Feature{ .avx, .avx2, .bmi, .bmi2, .f16c, .fma, .lzcnt, .movbe };

const Kernels = struct {
    options: *std.Build.Step.Options,
    zipir: *std.Build.Module,
    fast_zlib: ?*std.Build.Step.Compile,
};

fn configureLibraryModule(module: *std.Build.Module, library_kernels: Kernels) void {
    module.addImport("zipir", library_kernels.zipir);
    module.addOptions("kernel_options", library_kernels.options);
    if (library_kernels.fast_zlib) |object| module.addObject(object);
}

// One option for every CPU-specific path: Base64's AVX2, SHA-1's SHA extensions, zipir's
// checksum kernels, and the x86-64-v3 zlib decoder, each chosen at run time under dispatch.
fn buildKernels(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, backend: KernelBackend) Kernels {
    const zipir = b.dependency("zipir", .{ .target = target, .optimize = optimize, .@"kernel-backend" = backend }).module("zipir");
    const fast_zlib: FastZlib = if (backend == .portable or target.result.cpu.arch != .x86_64)
        .absent
    else if (std.Target.x86.featureSetHasAll(target.result.cpu.features, V3_FEATURES))
        .direct
    else
        .object;
    const options = b.addOptions();
    options.addOption(bool, "dispatch", backend == .dispatch);
    options.addOption(FastZlib, "zlib_fast", fast_zlib);
    options.addOption(bool, "as_object", false);
    var object: ?*std.Build.Step.Compile = null;
    if (fast_zlib == .object) {
        var query = target.query;
        query.cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 };
        // PCLMUL (on every x86-64-v3 CPU) keeps zipir's CRC-32 kernel inside this instance, so
        // its exported symbols are not linked twice.
        query.cpu_features_add = std.Target.x86.featureSet(&.{.pclmul});
        query.cpu_features_sub = .empty;
        const v3_target = b.resolveTargetQuery(query);
        // zlib.zig again, built for x86-64-v3, exporting its fast decoder (see zlib.zig).
        const object_options = b.addOptions();
        object_options.addOption(bool, "as_object", true);
        const module = b.createModule(.{
            .root_source_file = b.path("src/binary/zlib.zig"),
            .target = v3_target,
            .optimize = optimize,
            .single_threaded = true,
        });
        module.addImport("zipir", b.dependency("zipir", .{ .target = v3_target, .optimize = optimize, .@"kernel-backend" = backend }).module("zipir"));
        module.addOptions("kernel_options", object_options);
        object = b.addObject(.{ .name = "zmz_zlib_fast", .root_module = module, .use_llvm = true });
    }
    return .{ .options = options, .zipir = zipir, .fast_zlib = object };
}
