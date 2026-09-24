//! Decodes only the requested array role after each complete record is available.
//! This retains one record's binary text so selection sees all parameters, including
//! group references and parameters after binary. Unselected codecs are not interpreted.

const std = @import("std");
const mzml = @import("zmz").mzml;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "usage: mzml-select FILE.mzML ROLE_ACCESSION\n");
        return error.InvalidArguments;
    }
    const file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer file.close(init.io);
    var input_buffer: [64 * 1024]u8 = undefined;
    var input = file.reader(init.io, &input_buffer);
    var reader = try mzml.StreamReader.init(init.gpa, &input.interface, .{});
    defer reader.deinit();
    const header = try reader.readHeader();
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    while (try reader.nextRecord()) |record| {
        const node = (try record.arrayByRole(header.groups, .{ .raw = args[2] })) orelse continue;
        const array = try mzml.model.BinaryArray.init(node, record.default_array_length, header.groups);
        try output.interface.print("{s} {s} ", .{ record.id, args[2] });
        switch (array.encoding.pipeline) {
            .linear, .pic, .slof, .linear_zlib, .pic_zlib, .slof_zlib => try decode(f64, init.gpa, array, &output.interface),
            .none, .zlib => switch (array.encoding.primitive) {
                .float32 => try decode(f32, init.gpa, array, &output.interface),
                .float64 => try decode(f64, init.gpa, array, &output.interface),
                .int32 => try decode(i32, init.gpa, array, &output.interface),
                .int64 => try decode(i64, init.gpa, array, &output.interface),
            },
        }
    }
    try output.interface.flush();
}

fn decode(comptime T: type, allocator: std.mem.Allocator, array: mzml.model.BinaryArray, output: *std.Io.Writer) !void {
    const limits: mzml.arrays.Limits = .{};
    if (array.length > limits.array_bytes / @sizeOf(T)) return error.LimitExceeded;
    const binary = array.node.child(.binary) orelse return error.MissingBinary;
    const text = binary.text orelse return error.PayloadNotRetained;
    if (text.len > limits.base64_text.text_bytes) return error.LimitExceeded;
    const numbers = try allocator.alloc(T, array.length);
    defer allocator.free(numbers);
    const transport_size = if (array.encoding.pipeline == .none) 0 else @min(text.len / 4 * 3, limits.base64_text.decoded_bytes);
    const transport = try allocator.alloc(u8, transport_size);
    defer allocator.free(transport);
    const transformed_size = switch (array.encoding.pipeline) {
        .linear_zlib, .pic_zlib, .slof_zlib => try mzml.arrays.wireBound(T, array.length, array.encoding.pipeline),
        else => 0,
    };
    if (transformed_size > limits.array_bytes) return error.LimitExceeded;
    const transformed = try allocator.alloc(u8, transformed_size);
    defer allocator.free(transformed);
    try array.decode(T, numbers, .{ .transport = transport, .transformed = transformed }, limits);
    try output.print("type={s} count={d}", .{ @typeName(T), numbers.len });
    if (numbers.len != 0) try output.print(" first={d}", .{numbers[0]});
    try output.writeByte('\n');
}
