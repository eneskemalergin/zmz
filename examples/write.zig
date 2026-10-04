//! Constructs one example spectrum from numeric values and writes plain or indexed mzML.
//! The values and the encoder stay borrowed until writeRecordWithArrays returns; the writer
//! encodes each array while writing it.
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

    var encoder = mzml.arrays.Encoder.init(init.gpa, .fast);
    defer encoder.deinit();
    const mz = try builder.prepareArray(f64, &.{ 100, 200, 300 }, .{
        .cv_ref = "MS",
        .role = .{ .cv_ref = "MS", .accession = mzml.model.Terms.MZ_ARRAY, .name = "m/z array" },
        .encoding = .{ .pipeline = .zlib },
    }, &encoder);
    const intensity = try builder.prepareArray(f32, &.{ 10, 20, 30 }, .{
        .cv_ref = "MS",
        .role = .{ .cv_ref = "MS", .accession = mzml.model.Terms.INTENSITY_ARRAY, .name = "intensity array" },
        .encoding = .{ .pipeline = .zlib },
    }, &encoder);
    const record = try builder.record(.spectrum, "scan=1", 0, 3, &.{.{ .cv = .{
        .cv_ref = "MS",
        .accession = mzml.model.Terms.MS_LEVEL,
        .name = "ms level",
        .value = "1",
    } }}, &.{}, &.{ mz.array, intensity.array });
    try writer.beginList(.spectrum_list, 1, "example-processing");
    try writer.writeRecordWithArrays(record.node, &.{ mz.payload, intensity.payload });
    builder.reset();
    try writer.endList();
    try writer.finish();
    try output.interface.flush();
}

fn makeHeader(builder: *mzml.Builder) !mzml.model.Header {
    return builder.header(.{
        .document = .{
            .kind = .mzml,
            .attributes = &.{.{ .name = "version", .value = "1.1.0" }},
            .children = &.{
                try builder.list(.cv_list, &.{try builder.cvDeclaration(.{
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
