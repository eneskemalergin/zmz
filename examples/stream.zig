//! Reads spectra and chromatograms through EOF, decoding modeled arrays or returning metadata only.
//! The first record's metadata and header are copied so they can outlive the reader.
//! Numeric slices belong to DecodedArrays and are consumed before its next use.

const std = @import("std");
const mzml = @import("zmz").mzml;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const metadata_only = args.len == 3 and std.mem.eql(u8, args[2], "--metadata");
    if (args.len != 2 and !metadata_only) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "usage: mzml-stream FILE.mzML [--metadata]\n");
        return error.InvalidArguments;
    }
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    var retained_header: ?mzml.owned.Header = null;
    defer if (retained_header) |*header| header.deinit();
    var retained_record: ?mzml.owned.Record = null;
    defer if (retained_record) |*record| record.deinit();
    var records: usize = 0;
    var values: usize = 0;
    {
        const file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
        defer file.close(init.io);
        var input_buffer: [64 * 1024]u8 = undefined;
        var input = file.reader(init.io, &input_buffer);
        var reader = try mzml.StreamReader.init(init.gpa, &input.interface, .{ .payload = .skip });
        defer reader.deinit();
        errdefer if (reader.diagnostic()) |diagnostic| {
            std.debug.print("{s}: {s} at byte {d}, element {?s}\n", .{
                args[1],                                                       @errorName(diagnostic.code), diagnostic.byte_offset,
                if (diagnostic.element) |element| @tagName(element) else null,
            });
        };
        const header = try reader.readHeader();
        var decoded = mzml.StreamReader.DecodedArrays.init(init.gpa, .{});
        defer decoded.deinit();
        while (if (metadata_only) try reader.nextRecord() else try reader.nextDecodedRecord(&decoded)) |record| {
            records += 1;
            if (retained_record == null) {
                retained_header = try mzml.owned.Header.init(init.gpa, header.*, .{});
                retained_record = try mzml.owned.Record.init(init.gpa, record, .{});
            }
            try output.interface.print("{s} {s} arrays={d}", .{ @tagName(record.node.kind), record.id, record.binaryArrays().len });
            if (record.node.kind == .spectrum)
                try output.interface.print(" ms_level={?d}", .{try record.msLevel(header.groups)});
            try output.interface.writeByte('\n');
            for (record.scans()) |scan| {
                if (try scan.scanStartTime(header.groups)) |time|
                    try output.interface.print("  scan_time={d} unit={s}\n", .{ time.value, time.parameter.unit.name orelse "unspecified" });
            }
            for (0..decoded.len()) |position| {
                const array = decoded.get(position).?;
                switch (array.values) {
                    inline else => |numbers, primitive| {
                        values += numbers.len;
                        try output.interface.print("  array={d} type={s} count={d}", .{ position, @tagName(primitive), numbers.len });
                        if (numbers.len != 0) try output.interface.print(" first={d}", .{numbers[0]});
                        try output.interface.writeByte('\n');
                    },
                }
            }
        }
        if (header.spectrum_list) |list|
            try output.interface.print("spectra: declared={?d} observed={d}\n", .{ list.declared_count, list.observed_count });
        if (header.chromatogram_list) |list|
            try output.interface.print("chromatograms: declared={?d} observed={d}\n", .{ list.declared_count, list.observed_count });
    }
    if (retained_record) |record| {
        try output.interface.print("retained: {s}", .{record.value.id});
        if (record.value.node.kind == .spectrum)
            try output.interface.print(" ms_level={?d}", .{try record.value.msLevel(retained_header.?.value.groups)});
        try output.interface.writeByte('\n');
    }
    try output.interface.print("records={d} values={d}\n", .{ records, values });
    try output.interface.flush();
}
