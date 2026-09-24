//! Copies retained record metadata and binary text to a new indexed mzML file.
//! This example requires accurate list counts, consecutive record indexes, and lists
//! with only count and defaultDataProcessingRef. No array decoding or filtering occurs.

const std = @import("std");
const mzml = @import("zmz").mzml;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "usage: mzml-rewrite INPUT.mzML OUTPUT.mzML\n");
        return error.InvalidArguments;
    }
    const dir = std.Io.Dir.cwd();
    const source = try dir.openFile(init.io, args[1], .{});
    defer source.close(init.io);
    var input_buffer: [64 * 1024]u8 = undefined;
    var input = source.reader(init.io, &input_buffer);
    var reader = try mzml.StreamReader.init(init.gpa, &input.interface, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    const destination = try dir.createFile(init.io, args[2], .{ .exclusive = true });
    errdefer dir.deleteFile(init.io, args[2]) catch {};
    defer destination.close(init.io);
    var output_buffer: [64 * 1024]u8 = undefined;
    var output = destination.writer(init.io, &output_buffer);
    var writer = try mzml.Writer.initIndexed(init.gpa, &output.interface, .{}, .{});
    defer writer.deinit();
    try writer.writeHeader(header.*);
    var current = try reader.nextRecord();
    inline for (.{ mzml.model.Kind.spectrum_list, mzml.model.Kind.chromatogram_list }) |kind| {
        const descriptor = if (kind == .spectrum_list) header.spectrum_list else header.chromatogram_list;
        if (descriptor) |list| {
            // beginList cannot preserve additional attributes or an absent processing reference.
            for (list.attributes) |attribute| {
                if (attribute.namespace_uri != null or
                    (!std.mem.eql(u8, attribute.name, "count") and !std.mem.eql(u8, attribute.name, "defaultDataProcessingRef")))
                    return error.ListAttributesNotWritable;
            }
            const node: mzml.model.Node = .{ .kind = kind, .attributes = list.attributes };
            const processing_ref = node.attribute("defaultDataProcessingRef") orelse return error.ListAttributesNotWritable;
            try writer.beginList(kind, list.declared_count, processing_ref);
            while (current) |record| {
                if (record.node.kind != (if (kind == .spectrum_list) mzml.model.Kind.spectrum else .chromatogram)) break;
                try writer.writeRecord(record.node);
                current = try reader.nextRecord();
            }
            try writer.endList();
        }
    }
    if (current != null) return error.UnwrittenRecord;
    try writer.finish();
    try output.interface.flush();
}
