//! Checks external mzML references, scientific metadata, arrays, and indexed lookups through the public API.

const std = @import("std");
const mzml = @import("zmz").mzml;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "usage: zig build validate -- FILE.mzML [FILE.mzML ...]\n");
        return error.MissingInput;
    }
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    for (args[1..]) |path| {
        const totals = validateFile(init.gpa, init.io, path) catch |err| {
            var error_buffer: [4096]u8 = undefined;
            var diagnostic = std.Io.File.stderr().writer(init.io, &error_buffer);
            try diagnostic.interface.print("{s}: {s}\n", .{ path, @errorName(err) });
            try diagnostic.interface.flush();
            return err;
        };
        try output.interface.print("{s}: records={d} arrays={d} values={d} lookups={d}\n", .{
            path, totals.records, totals.arrays, totals.values, totals.lookups,
        });
        try output.interface.print("metadata: scans={d} precursors={d} selected_ions={d} products={d} quantities={d} unresolved_units={d} disallowed_units={d}\n", .{
            totals.scans,      totals.precursors,       totals.selected_ions,    totals.products,
            totals.quantities, totals.unresolved_units, totals.disallowed_units,
        });
        try output.interface.flush();
    }
}

const Totals = struct {
    records: usize = 0,
    arrays: usize = 0,
    values: usize = 0,
    lookups: usize = 0,
    scans: usize = 0,
    precursors: usize = 0,
    selected_ions: usize = 0,
    products: usize = 0,
    quantities: usize = 0,
    unresolved_units: usize = 0,
    disallowed_units: usize = 0,
};

fn validateFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Totals {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var index = try mzml.IndexedReader.build(allocator, .{ .file = .{ .handle = file, .io = io } }, .{ .policy = .rebuild });
    defer index.deinit();
    var buffer: [64 * 1024]u8 = undefined;
    var input = file.reader(io, &buffer);
    var reader = try mzml.StreamReader.init(allocator, &input.interface, .{ .validation = .{} });
    defer reader.deinit();
    const header = try reader.readHeader();
    const cv_nodes = header.document.child(.cv_list).?.children;
    const declarations = try allocator.alloc(mzml.cv.Declaration, cv_nodes.len);
    defer allocator.free(declarations);
    for (declarations, cv_nodes) |*declaration, node| declaration.* = .{
        .id = node.attribute("id"),
        .full_name = node.attribute("fullName"),
        .uri = node.attribute("URI"),
        .version = node.attribute("version"),
    };
    const resolver = mzml.cv.Resolver.init(declarations);
    const count = index.entries.items.len;
    var totals: Totals = .{};
    while (try reader.nextRecord()) |record| {
        if (totals.records == 0 or totals.records == count / 2 or totals.records == count -| 1) {
            var found = (try index.at(allocator, record.node.kind, record.index)) orelse return error.MissingIndexedRecord;
            defer found.deinit();
            if (!sameNode(record.node, found.value.node)) return error.IndexedRecordMismatch;
            totals.lookups += 1;
        }
        totals.records += 1;
        try checkMetadata(record, header.groups, resolver, &totals);
        for (record.binaryArrays()) |array| {
            const encoding = try mzml.model.arrayEncoding(array, header.groups);
            const values = switch (encoding.primitive) {
                .float32 => try decodeArray(allocator, f32, array, record, header.*),
                .float64 => try decodeArray(allocator, f64, array, record, header.*),
                .int32 => try decodeArray(allocator, i32, array, record, header.*),
                .int64 => try decodeArray(allocator, i64, array, record, header.*),
            };
            totals.values = std.math.add(usize, totals.values, values) catch return error.LimitExceeded;
            totals.arrays = std.math.add(usize, totals.arrays, 1) catch return error.LimitExceeded;
        }
    }
    if (totals.records != count) return error.RecordCountMismatch;
    return totals;
}

fn checkMetadata(record: mzml.model.Record, groups: []const mzml.cv.Group, resolver: mzml.cv.Resolver, totals: *Totals) !void {
    _ = try record.polarity(groups);
    if (record.node.kind == .spectrum) {
        _ = try record.msLevel(groups);
        _ = try record.representation(groups);
    }
    for (record.scans()) |scan| {
        totals.scans += 1;
        try checkQuantity(try scan.scanStartTime(groups), resolver, totals);
    }
    for (record.precursors()) |precursor| {
        totals.precursors += 1;
        for (try precursor.selectedIons()) |node| {
            totals.selected_ions += 1;
            const ion = try node.selectedIonValues(groups);
            try checkQuantity(ion.mz, resolver, totals);
            try checkQuantity(ion.intensity, resolver, totals);
        }
        try checkWindow(precursor.child(.isolation_window), groups, resolver, totals);
    }
    for (record.products()) |product| {
        totals.products += 1;
        try checkWindow(product.child(.isolation_window), groups, resolver, totals);
    }
}

fn checkWindow(node: ?mzml.model.Node, groups: []const mzml.cv.Group, resolver: mzml.cv.Resolver, totals: *Totals) !void {
    const window = try (node orelse return).isolationWindowValues(groups);
    try checkQuantity(window.target, resolver, totals);
    try checkQuantity(window.lower_offset, resolver, totals);
    try checkQuantity(window.upper_offset, resolver, totals);
}

fn checkQuantity(number: ?mzml.model.Number, resolver: mzml.cv.Resolver, totals: *Totals) !void {
    const source = number orelse return;
    const quantity = try resolver.quantity(f64, source.parameter);
    if (@as(u64, @bitCast(source.value)) != @as(u64, @bitCast(quantity.value)))
        return error.QuantityMismatch;
    totals.quantities += 1;
    if (quantity.parameter.unit_allowed == .unresolved) totals.unresolved_units += 1;
    if (quantity.parameter.unit_allowed == .disallowed) totals.disallowed_units += 1;
}

fn decodeArray(
    allocator: std.mem.Allocator,
    comptime T: type,
    node: mzml.model.Node,
    record: mzml.model.Record,
    header: mzml.model.Header,
) !usize {
    const encoding = try mzml.model.arrayEncoding(node, header.groups);
    const count = if (node.attribute("arrayLength")) |text|
        try mzml.cv.parseInteger(usize, text)
    else
        record.default_array_length;
    const limits: mzml.arrays.Limits = .{};
    const size = std.math.mul(usize, count, @sizeOf(T)) catch return error.LimitExceeded;
    if (size > limits.array_bytes) return error.LimitExceeded;
    const values = try allocator.alloc(T, count);
    defer allocator.free(values);
    const transport = try allocator.alloc(u8, node.child(.binary).?.text.?.len);
    defer allocator.free(transport);
    const transformed = try allocator.alloc(u8, try mzml.arrays.wireBound(T, count, encoding.pipeline));
    defer allocator.free(transformed);
    try mzml.model.decodeArray(T, values, node, record.default_array_length, header.groups, .{
        .transport = transport,
        .transformed = transformed,
    }, limits);
    return count;
}

fn sameNode(a: mzml.model.Node, b: mzml.model.Node) bool {
    if (a.kind != b.kind or a.start_offset != b.start_offset or
        a.content_offset != b.content_offset or a.end_offset != b.end_offset or
        a.attributes.len != b.attributes.len or a.params.len != b.params.len or
        a.children.len != b.children.len or !sameText(a.text, b.text)) return false;
    for (a.attributes, b.attributes) |left, right| {
        if (!sameText(left.name, right.name) or !sameText(left.value, right.value) or
            !sameText(left.namespace_uri, right.namespace_uri)) return false;
    }
    for (a.params, b.params) |left, right| {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        switch (left) {
            .group_ref => |ref| if (!sameText(ref, right.group_ref)) return false,
            .cv => |param| {
                const other = right.cv;
                if (!sameText(param.cv_ref, other.cv_ref) or !sameText(param.name, other.name) or
                    !sameText(param.value, other.value) or !sameAccession(param.accession, other.accession) or
                    !sameUnit(param.unit, other.unit)) return false;
            },
            .user => |param| {
                const other = right.user;
                if (!sameText(param.name, other.name) or !sameText(param.value, other.value) or
                    !sameText(param.value_type, other.value_type) or !sameUnit(param.unit, other.unit)) return false;
            },
        }
    }
    for (a.children, b.children) |left, right| if (!sameNode(left, right)) return false;
    return true;
}

fn sameUnit(a: mzml.cv.Unit, b: mzml.cv.Unit) bool {
    return sameText(a.cv_ref, b.cv_ref) and sameText(a.name, b.name) and sameAccession(a.accession, b.accession);
}

fn sameAccession(a: ?mzml.cv.Accession, b: ?mzml.cv.Accession) bool {
    return sameText(if (a) |term| term.raw else null, if (b) |term| term.raw else null);
}

fn sameText(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |left| return if (b) |right| std.mem.eql(u8, left, right) else false;
    return b == null;
}
