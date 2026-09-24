//! Decodes one requested array role, leaving unrequested codecs uninterpreted.
//! The default retains text so selection sees complete metadata, including parameters
//! after binary. --stream selects from leading parameters and reuses numeric buffers
//! without retaining text. --ms1 does the same for spectra with MS level 1 available
//! before the array list. Parameter groups remain borrowed from the reader's header.

const std = @import("std");
const mzml = @import("zmz").mzml;

const Selection = struct {
    role: mzml.cv.Accession,
    groups: []const mzml.cv.Group = &.{},
    failure: ?mzml.model.MetadataError = null,

    fn array(data: ?*anyopaque, _: usize, attributes: []const mzml.model.Attribute, params: []const mzml.cv.Entry) mzml.StreamReader.Payload {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        const node: mzml.model.Node = .{ .kind = .binary_data_array, .attributes = attributes, .params = params };
        const parameter = node.parameter(self.groups, self.role) catch |err| {
            self.failure = err;
            return .skip;
        };
        return if (parameter != null) .retain else .skip;
    }

    fn ms1(data: ?*anyopaque, kind: mzml.model.Kind, attributes: []const mzml.model.Attribute, params: []const mzml.cv.Entry) mzml.StreamReader.Payload {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        if (kind != .spectrum) return .skip;
        const node: mzml.model.Node = .{ .kind = kind, .attributes = attributes, .params = params };
        const level = node.integer(i32, self.groups, mzml.model.Terms.MS_LEVEL) catch |err| {
            self.failure = err;
            return .skip;
        };
        return if (level == 1) .retain else .skip;
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if ((args.len != 3 and args.len != 4) or
        (args.len == 4 and !std.mem.eql(u8, args[3], "--stream") and !std.mem.eql(u8, args[3], "--ms1")))
    {
        try std.Io.File.stderr().writeStreamingAll(init.io, "usage: mzml-select FILE.mzML ROLE_ACCESSION [--stream|--ms1]\n");
        return error.InvalidArguments;
    }
    const streaming = args.len == 4;
    var selection: Selection = .{ .role = .{ .raw = args[2] } };
    const file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer file.close(init.io);
    var input_buffer: [64 * 1024]u8 = undefined;
    var input = file.reader(init.io, &input_buffer);
    var reader = try mzml.StreamReader.init(init.gpa, &input.interface, .{
        .array_selector = if (streaming) .{
            .user_data = &selection,
            .select = Selection.array,
            .select_record = if (std.mem.eql(u8, args[3], "--ms1")) Selection.ms1 else null,
        } else null,
    });
    defer reader.deinit();
    const header = try reader.readHeader();
    selection.groups = header.groups;
    var decoded = mzml.StreamReader.DecodedArrays.init(init.gpa, .{});
    defer decoded.deinit();
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    while (if (streaming) try reader.nextDecodedRecord(&decoded) else try reader.nextRecord()) |record| {
        if (selection.failure) |err| return err;
        if (streaming) {
            if (decoded.len() > 1) return error.RepeatedArray;
            const array = decoded.get(0) orelse continue;
            try output.interface.print("{s} {s} ", .{ record.id, args[2] });
            switch (array.values) {
                inline else => |values| try printNumbers(@typeInfo(@TypeOf(values)).pointer.child, values, &output.interface),
            }
            continue;
        }
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
    try printNumbers(T, numbers, output);
}

fn printNumbers(comptime T: type, numbers: []const T, output: *std.Io.Writer) !void {
    try output.print("type={s} count={d}", .{ @typeName(T), numbers.len });
    if (numbers.len != 0) try output.print(" first={d}", .{numbers[0]});
    try output.writeByte('\n');
}
