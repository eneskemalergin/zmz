//! Constructs one example spectrum from numeric values and writes plain or indexed mzML.
//! Each compressed array keeps its own scratch until writeRecordWithArrays returns.
//! Output creation is exclusive; failed writes remove only the new partial file.

const std = @import("std");
const mzml = @import("zmz").mzml;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const indexed = args.len == 3 and std.mem.eql(u8, args[2], "--indexed");
    if (args.len != 2 and !indexed) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "usage: mzml-write OUTPUT.mzML [--indexed]\n");
        return error.InvalidArguments;
    }
    const dir = std.Io.Dir.cwd();
    const file = try dir.createFile(init.io, args[1], .{ .exclusive = true });
    errdefer dir.deleteFile(init.io, args[1]) catch {};
    defer file.close(init.io);
    var output_buffer: [64 * 1024]u8 = undefined;
    var output = file.writer(init.io, &output_buffer);
    var writer = if (indexed)
        try mzml.Writer.initIndexed(init.gpa, &output.interface, .{}, .{})
    else
        try mzml.Writer.init(init.gpa, &output.interface, .{});
    defer writer.deinit();
    var builder = mzml.Builder.init(init.gpa, .{});
    defer builder.deinit();
    try writer.writeHeader(try makeHeader(&builder));
    builder.reset();

    var compressor = try mzml.zlib.Compressor.init(init.gpa, .fast);
    defer compressor.deinit();
    var mz_storage: std.ArrayList(u8) = .empty;
    defer mz_storage.deinit(init.gpa);
    var intensity_storage: std.ArrayList(u8) = .empty;
    defer intensity_storage.deinit(init.gpa);
    const mz = try prepare(f64, init.gpa, &builder, &compressor, &mz_storage, &.{ 100, 200, 300 }, .{
        .cv_ref = "MS",
        .accession = mzml.model.Terms.MZ_ARRAY,
        .name = "m/z array",
    });
    const intensity = try prepare(f32, init.gpa, &builder, &compressor, &intensity_storage, &.{ 10, 20, 30 }, .{
        .cv_ref = "MS",
        .accession = mzml.model.Terms.INTENSITY_ARRAY,
        .name = "intensity array",
    });
    const record = try builder.preparedRecord(.spectrum, "scan=1", 0, 3, &.{.{ .cv = .{
        .cv_ref = "MS",
        .accession = mzml.model.Terms.MS_LEVEL,
        .name = "ms level",
        .value = "1",
    } }}, &.{}, &.{ mz.array, intensity.array });
    try writer.beginList(.spectrum_list, 1, "example-processing");
    try writer.writeRecordWithArrays(record.node, &.{ mz.wire, intensity.wire });
    builder.reset();
    try writer.endList();
    try writer.finish();
    try output.interface.flush();
}

fn prepare(
    comptime T: type,
    allocator: std.mem.Allocator,
    builder: *mzml.Builder,
    compressor: *mzml.zlib.Compressor,
    storage: *std.ArrayList(u8),
    values: []const T,
    role: mzml.cv.Param,
) !mzml.Builder.PreparedArray {
    const byte_limit = 1024 * 1024;
    const bound = try mzml.arrays.wireBound(T, values.len, .zlib);
    if (bound > byte_limit) return error.LimitExceeded;
    const transformed = try allocator.alloc(u8, bound);
    defer allocator.free(transformed);
    try storage.resize(allocator, @max(bound, 1));
    while (true) {
        return builder.prepareArray(T, values, .{ .cv_ref = "MS", .role = role, .encoding = .{ .pipeline = .zlib } }, .{
            .transport = storage.items,
            .transformed = transformed,
        }, compressor) catch |err| switch (err) {
            error.OutputTooSmall => {
                // wireBound excludes zlib overhead, so incompressible input may need more space.
                if (storage.items.len == byte_limit) return error.LimitExceeded;
                try storage.resize(allocator, @min(storage.items.len * 2, byte_limit));
                continue;
            },
            else => return err,
        };
    }
}

fn makeHeader(builder: *mzml.Builder) !mzml.model.Header {
    return builder.header(.{
        .document = .{
            .kind = .mzml,
            .attributes = &.{.{ .name = "version", .value = "1.1.0" }},
            .children = &.{
                try builder.list(.cv_list, &.{try builder.vocabulary(.{
                    .id = "MS",
                    .full_name = "PSI-MS",
                    .uri = "http://purl.obolibrary.org/obo/ms/psi-ms.obo",
                })}),
                .{
                    .kind = .file_description,
                    .children = &.{.{
                        .kind = .file_content,
                        .params = &.{.{ .user = .{ .name = "example values, not an acquisition" } }},
                    }},
                },
                try builder.list(.software_list, &.{.{
                    .kind = .software,
                    .attributes = &.{
                        .{ .name = "id", .value = "example-software" },
                        .{ .name = "version", .value = "1" },
                    },
                }}),
                try builder.list(.instrument_configuration_list, &.{.{
                    .kind = .instrument_configuration,
                    .attributes = &.{.{ .name = "id", .value = "example-instrument" }},
                }}),
                try builder.list(.data_processing_list, &.{.{
                    .kind = .data_processing,
                    .attributes = &.{.{ .name = "id", .value = "example-processing" }},
                    .children = &.{.{
                        .kind = .processing_method,
                        .attributes = &.{
                            .{ .name = "order", .value = "0" },
                            .{ .name = "softwareRef", .value = "example-software" },
                        },
                    }},
                }}),
            },
        },
        .run = .{
            .kind = .run,
            .attributes = &.{
                .{ .name = "id", .value = "example-run" },
                .{ .name = "defaultInstrumentConfigurationRef", .value = "example-instrument" },
            },
        },
    });
}
