//! Copies retained record metadata and binary text to a new indexed mzML file.
//! With --ms1, filters spectra in one input pass and fills in the surviving count.
//! Chromatograms are kept. Record IDs and references stay unchanged; only surviving
//! spectrum indexes are reassigned. Other list attributes stay unchanged.
//! With --zlib, decodes modeled arrays and reencodes their values losslessly with zlib.
//! Source metadata and array references are kept through prepared header groups.
//! --replace-user-param NAME VALUE and --remove-user-param NAME edit all matching
//! direct user parameters on spectra and chromatograms, without expanding groups.
//! Parameter replacement keeps units, type, and extra XML; removal deletes the whole
//! parameter. Other parameters, children, and surrounding XML keep their order.

const std = @import("std");
const mzml = @import("zmz").mzml;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const ms1 = args.len == 4 and std.mem.eql(u8, args[3], "--ms1");
    const reencode = args.len == 4 and std.mem.eql(u8, args[3], "--zlib");
    const replace_param = args.len == 6 and std.mem.eql(u8, args[3], "--replace-user-param");
    const remove_param = args.len == 5 and std.mem.eql(u8, args[3], "--remove-user-param");
    if (args.len != 3 and !ms1 and !reencode and !replace_param and !remove_param) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "usage: mzml-rewrite INPUT.mzML OUTPUT.mzML [--ms1|--zlib|--replace-user-param NAME VALUE|--remove-user-param NAME]\n");
        return error.InvalidArguments;
    }
    const dir = std.Io.Dir.cwd();
    const source = try dir.openFile(init.io, args[1], .{});
    defer source.close(init.io);
    var input_buffer: [64 * 1024]u8 = undefined;
    var input = source.reader(init.io, &input_buffer);
    var reader = try mzml.StreamReader.init(init.gpa, &input.interface, .{});
    defer reader.deinit();
    errdefer if (reader.diagnostic()) |report| std.debug.print("{s}: {f}\n", .{ args[1], report });
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
    errdefer if (writer.diagnostic()) |report| std.debug.print("{s}: {f}\n", .{ args[2], report });
    var attributes: std.ArrayList(mzml.model.Attribute) = .empty;
    defer attributes.deinit(init.gpa);
    var editor: ?ParameterEditor = if (replace_param or remove_param)
        .{ .name = args[4], .replacement = if (replace_param) args[5] else null }
    else
        null;
    defer if (editor) |*value| value.deinit(init.gpa);
    var decoded = mzml.DecodedArrays.init(init.gpa, .{});
    defer decoded.deinit();
    var header_builder = mzml.Builder.init(init.gpa, .{});
    defer header_builder.deinit();
    const prepared_header = if (reencode) try header_builder.reencoding(header.*, &.{
        .{ .primitive = .float32, .pipeline = .zlib },
        .{ .primitive = .float64, .pipeline = .zlib },
        .{ .primitive = .int32, .pipeline = .zlib },
        .{ .primitive = .int64, .pipeline = .zlib },
    }) else null;
    var encoder: ?Reencoder = if (prepared_header) |prepared| Reencoder.init(init.gpa, prepared) else null;
    defer if (encoder) |*value| value.deinit();
    try writer.writeHeader(if (prepared_header) |prepared| prepared.header else header.*);
    var written: usize = 0;
    while (if (reencode) try reader.nextDecodedItem(&decoded) else try reader.nextItem()) |item| {
        switch (item) {
            .list_start => |start| {
                const filter = ms1 and start.kind == .spectrum_list;
                try writer.beginListWithAttributes(start.kind, if (filter) null else start.list.declared_count, start.list.attributes);
                written = 0;
            },
            .record => |record| {
                const filter = ms1 and record.node.kind == .spectrum;
                if (!filter or try record.msLevel(header.groups) == 1) {
                    var emitted = record.node;
                    var index_text: [32]u8 = undefined;
                    if (filter) {
                        try attributes.resize(init.gpa, emitted.attributes.len);
                        @memcpy(attributes.items, emitted.attributes);
                        const index = try std.fmt.bufPrint(&index_text, "{d}", .{written});
                        for (attributes.items) |*attribute| {
                            if (attribute.namespace_uri == null and std.mem.eql(u8, attribute.name, "index")) {
                                attribute.value = index;
                                break;
                            }
                        } else try attributes.append(init.gpa, .{ .name = "index", .value = index });
                        emitted.attributes = attributes.items;
                    }
                    if (editor) |*value| emitted = try value.apply(init.gpa, emitted);
                    if (encoder) |*value|
                        try value.write(&writer, emitted, &decoded)
                    else
                        try writer.writeRecord(emitted);
                    written += 1;
                }
            },
            else => try writer.writeItem(item),
        }
    }
    try writer.finish();
    try output.interface.flush();
}

const ParameterEditor = struct {
    name: []const u8,
    replacement: ?[]const u8,
    params: std.ArrayList(mzml.cv.Entry) = .empty,
    items: std.ArrayList(mzml.model.Content.Item) = .empty,
    content: mzml.model.Content = .{ .items = &.{} },

    fn deinit(self: *ParameterEditor, allocator: std.mem.Allocator) void {
        self.params.deinit(allocator);
        self.items.deinit(allocator);
    }

    fn apply(self: *ParameterEditor, allocator: std.mem.Allocator, source: mzml.model.Node) !mzml.model.Node {
        self.params.clearRetainingCapacity();
        try self.params.ensureTotalCapacity(allocator, source.params.len);
        var result = source;
        if (source.content) |content| {
            try self.items.resize(allocator, content.items.len);
            var position: usize = 0;
            for (content.items, self.items.items) |item, *out| {
                out.* = item;
                if (item == .params) {
                    out.* = .{ .params = self.append(source.params[position..][0..item.params]) };
                    position += item.params;
                }
            }
            self.content.items = self.items.items;
            result.content = &self.content;
        } else {
            _ = self.append(source.params);
        }
        result.params = self.params.items;
        return result;
    }

    fn append(self: *ParameterEditor, entries: []const mzml.cv.Entry) usize {
        const start = self.params.items.len;
        for (entries) |entry| {
            var changed = entry;
            if (entry == .user and entry.user.name != null and std.mem.eql(u8, entry.user.name.?, self.name)) {
                if (self.replacement) |value| changed.user.value = value else continue;
            }
            self.params.appendAssumeCapacity(changed);
        }
        return self.params.items.len - start;
    }
};

const Reencoder = struct {
    allocator: std.mem.Allocator,
    builder: mzml.Builder,
    reencoding: mzml.Builder.Reencoding,
    encoder: mzml.arrays.Encoder,
    arrays: std.ArrayList(mzml.model.Node) = .empty,
    children: std.ArrayList(mzml.model.Node) = .empty,
    payloads: std.ArrayList(mzml.Writer.ArrayPayload) = .empty,

    fn init(allocator: std.mem.Allocator, reencoding: mzml.Builder.Reencoding) Reencoder {
        return .{ .allocator = allocator, .builder = .init(allocator, .{}), .reencoding = reencoding, .encoder = .init(allocator, .fast) };
    }

    fn deinit(self: *Reencoder) void {
        self.arrays.deinit(self.allocator);
        self.children.deinit(self.allocator);
        self.payloads.deinit(self.allocator);
        self.encoder.deinit();
        self.builder.deinit();
    }

    fn write(self: *Reencoder, writer: *mzml.Writer, source: mzml.model.Node, decoded: *const mzml.DecodedArrays) !void {
        self.builder.reset();
        self.encoder.reset();
        const source_arrays = if (source.child(.binary_data_array_list)) |list| list.children else &.{};
        try self.arrays.resize(self.allocator, source_arrays.len);
        try self.payloads.resize(self.allocator, source_arrays.len);
        for (source_arrays, self.arrays.items, self.payloads.items, 0..) |array, *node, *payload, i| {
            const prepared = switch (decoded.get(i).?.values) {
                inline else => |values| try self.reencoding.prepareArray(&self.builder, @typeInfo(@TypeOf(values)).pointer.child, values, array, .{ .pipeline = .zlib }, &self.encoder),
            };
            node.* = prepared.array.node;
            payload.* = prepared.payload;
        }
        try self.children.resize(self.allocator, source.children.len);
        @memcpy(self.children.items, source.children);
        for (self.children.items) |*child| {
            if (child.kind == .binary_data_array_list) child.children = self.arrays.items;
        }
        var record = source;
        record.children = self.children.items;
        try writer.writeRecordWithArrays(record, self.payloads.items);
    }
};
