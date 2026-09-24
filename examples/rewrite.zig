//! Copies retained record metadata and binary text to a new indexed mzML file.
//! With --ms1, filters spectra in one input pass and fills in the surviving count.
//! Chromatograms are kept. Record IDs and references stay unchanged; only surviving
//! spectrum indexes are reassigned. Lists need count and defaultDataProcessingRef.

const std = @import("std");
const mzml = @import("zmz").mzml;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const ms1 = args.len == 4 and std.mem.eql(u8, args[3], "--ms1");
    if (args.len != 3 and !ms1) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "usage: mzml-rewrite INPUT.mzML OUTPUT.mzML [--ms1]\n");
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
    const destination = try dir.createFile(init.io, args[2], .{ .exclusive = true, .read = ms1 });
    errdefer dir.deleteFile(init.io, args[2]) catch {};
    defer destination.close(init.io);
    var output_buffer: [64 * 1024]u8 = undefined;
    var output = destination.writer(init.io, &output_buffer);
    var writer = if (ms1)
        try mzml.Writer.initFile(init.gpa, &output, .{}, .{})
    else
        try mzml.Writer.initIndexed(init.gpa, &output.interface, .{}, .{});
    defer writer.deinit();
    var attributes: std.ArrayList(mzml.model.Attribute) = .empty;
    defer attributes.deinit(init.gpa);
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
            const filter = ms1 and kind == .spectrum_list;
            try writer.beginList(kind, if (filter) null else list.declared_count, processing_ref);
            var written: usize = 0;
            while (current) |record| {
                if (record.node.kind != (if (kind == .spectrum_list) mzml.model.Kind.spectrum else .chromatogram)) break;
                if (!filter or try record.msLevel(header.groups) == 1) {
                    var emitted = record.node;
                    var index_text: [32]u8 = undefined;
                    if (filter) {
                        try attributes.resize(init.gpa, emitted.attributes.len);
                        @memcpy(attributes.items, emitted.attributes);
                        for (attributes.items) |*attribute| {
                            if (attribute.namespace_uri == null and std.mem.eql(u8, attribute.name, "index"))
                                attribute.value = try std.fmt.bufPrint(&index_text, "{d}", .{written});
                        }
                        emitted.attributes = attributes.items;
                    }
                    try writer.writeRecord(emitted);
                    written += 1;
                }
                current = try reader.nextRecord();
            }
            try writer.endList();
        }
    }
    if (current != null) return error.UnwrittenRecord;
    try writer.finish();
    try output.interface.flush();
}
