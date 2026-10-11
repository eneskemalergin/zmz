//! Exercises metadata access, array decoding, and indexed lookups on explicit mzML files.
//!
//! For each file it rebuilds the index (policy `rebuild`), streams every record, resolving its
//! metadata and decoding its arrays, compares the first, middle, and last record with their indexed
//! lookups, and prints the totals. Selected-ion and isolation-window fields are read one at a
//! time, so a malformed field is counted in `invalid_fields` and the rest of the file is still
//! checked. Any other failure stops at that file, prints the file and its error, and exits with
//! status 1.

const std = @import("std");
const mzml = @import("zmz").mzml;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "usage: zig build check-mzml -- FILE.mzML [FILE.mzML ...]\n");
        std.process.exit(1);
    }
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    for (args[1..]) |path| {
        const totals = checkFile(init.gpa, init.io, path) catch |err| {
            var error_buffer: [4096]u8 = undefined;
            var diagnostic = std.Io.File.stderr().writer(init.io, &error_buffer);
            try diagnostic.interface.print("{s}: {s}\n", .{ path, @errorName(err) });
            try diagnostic.interface.flush();
            std.process.exit(1);
        };
        try output.interface.print("{s}: records={d} arrays={d} values={d} lookups={d}\n", .{
            path, totals.records, totals.arrays, totals.values, totals.lookups,
        });
        try output.interface.print(
            "metadata: scans={d} precursors={d} selected_ions={d} products={d} quantities={d} unresolved_units={d}" ++
                " disallowed_units={d} invalid_fields={d}\n",
            .{
                totals.scans,      totals.precursors,       totals.selected_ions,    totals.products,
                totals.quantities, totals.unresolved_units, totals.disallowed_units, totals.invalid_fields,
            },
        );
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
    invalid_fields: usize = 0,
};

fn checkFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Totals {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var failure: ?mzml.Diagnostic = null;
    var index = mzml.IndexedReader.buildWithDiagnostic(allocator, .{ .file = .{ .handle = file, .io = io } }, .{ .policy = .rebuild }, &failure) catch |err| {
        if (failure) |report| std.debug.print("index diagnostic: {f}\n", .{report});
        return err;
    };
    defer index.deinit();
    errdefer if (index.diagnostic()) |report| std.debug.print("index diagnostic: {f}\n", .{report});
    var buffer: [64 * 1024]u8 = undefined;
    var input = file.reader(io, &buffer);
    var reader = try mzml.StreamReader.init(allocator, &input.interface, .{});
    defer reader.deinit();
    const header = reader.readHeader() catch |err| {
        reportReaderFailure(&reader, err);
        return err;
    };
    const declarations = try header.cvDeclarations(allocator);
    defer allocator.free(declarations);
    const resolver = mzml.cv.Resolver.init(declarations);
    const count = index.entryCount();
    var totals: Totals = .{};
    var decoded = mzml.DecodedArrays.init(allocator, .{});
    defer decoded.deinit();
    var ordinals = [_]usize{ 0, 0 };
    while (true) {
        const next = reader.nextRecord() catch |err| {
            reportReaderFailure(&reader, err);
            return err;
        };
        const record = next orelse break;
        const k: usize = if (record.node.kind == .spectrum) 0 else 1;
        const ordinal = ordinals[k];
        ordinals[k] += 1;
        if (totals.records == 0 or totals.records == count / 2 or totals.records == count -| 1) {
            var found = (try index.at(allocator, record.node.kind, ordinal)) orelse return error.MissingIndexedRecord;
            defer found.deinit();
            std.testing.expectEqualDeep(record.node, found.value.node) catch return error.IndexedRecordMismatch;
            totals.lookups += 1;
        }
        totals.records += 1;
        try checkMetadata(record, header.groups, resolver, &totals);
        decoded.decodeRecord(record, header.groups) catch |err| {
            if (decoded.diagnostic()) |report| std.debug.print("array diagnostic: {f}\n", .{report});
            return err;
        };
        for (0..decoded.len()) |position| {
            const values = switch (decoded.get(position).?.values) {
                inline else => |numbers| numbers.len,
            };
            totals.values = std.math.add(usize, totals.values, values) catch return error.LimitExceeded;
        }
        totals.arrays = std.math.add(usize, totals.arrays, decoded.len()) catch return error.LimitExceeded;
    }
    if (totals.records != count) return error.RecordCountMismatch;
    return totals;
}

fn reportReaderFailure(reader: *mzml.StreamReader, err: anyerror) void {
    if (reader.diagnostic()) |diagnostic| {
        std.debug.print("diagnostic: {f}\n", .{diagnostic});
    } else {
        std.debug.print("diagnostic: {s} without reader location\n", .{@errorName(err)});
    }
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
            const ion = try node.selectedIonFields(groups);
            try checkField(ion.mz, resolver, totals);
            if (ion.charge) |_| {} else |_| totals.invalid_fields += 1;
            try checkField(ion.intensity, resolver, totals);
        }
        try checkWindow(precursor.child(.isolation_window), groups, resolver, totals);
    }
    for (record.products()) |product| {
        totals.products += 1;
        try checkWindow(product.child(.isolation_window), groups, resolver, totals);
    }
}

fn checkWindow(node: ?mzml.model.Node, groups: []const mzml.cv.Group, resolver: mzml.cv.Resolver, totals: *Totals) !void {
    const window = try (node orelse return).isolationWindowFields(groups);
    try checkField(window.target, resolver, totals);
    try checkField(window.lower_offset, resolver, totals);
    try checkField(window.upper_offset, resolver, totals);
}

fn checkField(field: mzml.model.FieldError!?mzml.model.Number, resolver: mzml.cv.Resolver, totals: *Totals) !void {
    const number = field catch {
        totals.invalid_fields += 1;
        return;
    };
    try checkQuantity(number, resolver, totals);
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
