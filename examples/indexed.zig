//! Retrieves one record by ID using an embedded index or an explicitly rebuilt index.
//! The file stays open and unchanged while the index exists. Returned metadata and
//! numeric buffers have separate owners; both are released after use.

const std = @import("std");
const mzml = @import("zmz").mzml;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const rebuild = args.len == 4 and std.mem.eql(u8, args[3], "--rebuild");
    if (args.len != 3 and !rebuild) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "usage: mzml-indexed FILE.mzML ID [--rebuild]\n");
        return error.InvalidArguments;
    }
    const file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer file.close(init.io);
    var failure: ?mzml.Diagnostic = null;
    var index = mzml.IndexedReader.buildWithDiagnostic(init.gpa, .{ .file = .{ .handle = file, .io = init.io } }, .{
        .policy = if (rebuild) .rebuild else .open_embedded,
    }, &failure) catch |err| {
        if (failure) |report| std.debug.print("{s}: {f}\n", .{ args[1], report });
        return err;
    };
    defer index.deinit();
    errdefer if (index.diagnostic()) |report| std.debug.print("{s}: {f}\n", .{ args[1], report });
    var decoded = mzml.DecodedArrays.init(init.gpa, .{});
    defer decoded.deinit();
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    if (try index.byIdDecoded(init.gpa, args[2], &decoded)) |found| {
        var record = found;
        defer record.deinit();
        try output.interface.print("{s} {s} arrays={d}\n", .{ @tagName(record.value.node.kind), record.value.id, decoded.len() });
        for (0..decoded.len()) |position| {
            switch (decoded.get(position).?.values) {
                inline else => |numbers, primitive| {
                    try output.interface.print("  array={d} type={s} count={d}", .{ position, @tagName(primitive), numbers.len });
                    if (numbers.len != 0) try output.interface.print(" first={d}", .{numbers[0]});
                    try output.interface.writeByte('\n');
                },
            }
        }
    } else try output.interface.print("not found: {s}\n", .{args[2]});
    try output.interface.flush();
}
