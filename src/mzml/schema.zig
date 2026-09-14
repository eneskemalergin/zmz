//! Defines mzML 1.1 structural ordering and required source attributes.

const std = @import("std");
const model = @import("model.zig");
const cv = @import("../cv/source.zig");
const base64 = @import("../binary/base64.zig");

pub const Rule = struct { kind: model.Kind, minimum: usize = 0, maximum: usize = 1 };

pub fn children(kind: model.Kind) []const Rule {
    return switch (kind) {
        .mzml => &.{
            .{ .kind = .cv_list, .minimum = 1 },                       .{ .kind = .file_description, .minimum = 1 },
            .{ .kind = .referenceable_param_group_list },              .{ .kind = .sample_list },
            .{ .kind = .software_list, .minimum = 1 },                 .{ .kind = .scan_settings_list },
            .{ .kind = .instrument_configuration_list, .minimum = 1 }, .{ .kind = .data_processing_list, .minimum = 1 },
            .{ .kind = .run, .minimum = 1 },
        },
        .file_description => &.{
            .{ .kind = .file_content, .minimum = 1 }, .{ .kind = .source_file_list },
            .{ .kind = .contact, .maximum = MANY },
        },
        .cv_list => &.{.{ .kind = .cv, .minimum = 1, .maximum = MANY }},
        .source_file_list => &.{.{ .kind = .source_file, .minimum = 1, .maximum = MANY }},
        .referenceable_param_group_list => &.{.{ .kind = .referenceable_param_group, .minimum = 1, .maximum = MANY }},
        .sample_list => &.{.{ .kind = .sample, .minimum = 1, .maximum = MANY }},
        .software_list => &.{.{ .kind = .software, .minimum = 1, .maximum = MANY }},
        .scan_settings_list => &.{.{ .kind = .scan_settings, .minimum = 1, .maximum = MANY }},
        .scan_settings => &.{ .{ .kind = .source_file_ref_list }, .{ .kind = .target_list } },
        .source_file_ref_list => &.{.{ .kind = .source_file_ref, .maximum = MANY }},
        .target_list => &.{.{ .kind = .target, .minimum = 1, .maximum = MANY }},
        .instrument_configuration_list => &.{.{ .kind = .instrument_configuration, .minimum = 1, .maximum = MANY }},
        .instrument_configuration => &.{ .{ .kind = .component_list }, .{ .kind = .software_ref } },
        .component_list => &.{
            .{ .kind = .source, .minimum = 1, .maximum = MANY },
            .{ .kind = .analyzer, .minimum = 1, .maximum = MANY },
            .{ .kind = .detector, .minimum = 1, .maximum = MANY },
        },
        .data_processing_list => &.{.{ .kind = .data_processing, .minimum = 1, .maximum = MANY }},
        .data_processing => &.{.{ .kind = .processing_method, .minimum = 1, .maximum = MANY }},
        .run => &.{ .{ .kind = .spectrum_list }, .{ .kind = .chromatogram_list } },
        .spectrum_list => &.{.{ .kind = .spectrum, .maximum = MANY }},
        .chromatogram_list => &.{.{ .kind = .chromatogram, .minimum = 1, .maximum = MANY }},
        .spectrum => &.{
            .{ .kind = .scan_list },              .{ .kind = .precursor_list }, .{ .kind = .product_list },
            .{ .kind = .binary_data_array_list },
        },
        .chromatogram => &.{
            .{ .kind = .precursor },                            .{ .kind = .product },
            .{ .kind = .binary_data_array_list, .minimum = 1 },
        },
        .scan_list => &.{.{ .kind = .scan, .minimum = 1, .maximum = MANY }},
        .scan => &.{.{ .kind = .scan_window_list }},
        .scan_window_list => &.{.{ .kind = .scan_window, .minimum = 1, .maximum = MANY }},
        .precursor_list => &.{.{ .kind = .precursor, .minimum = 1, .maximum = MANY }},
        .precursor => &.{
            .{ .kind = .isolation_window },         .{ .kind = .selected_ion_list },
            .{ .kind = .activation, .minimum = 1 },
        },
        .selected_ion_list => &.{.{ .kind = .selected_ion, .minimum = 1, .maximum = MANY }},
        .product_list => &.{.{ .kind = .product, .minimum = 1, .maximum = MANY }},
        .product => &.{.{ .kind = .isolation_window }},
        .binary_data_array_list => &.{.{ .kind = .binary_data_array, .minimum = 2, .maximum = MANY }},
        .binary_data_array => &.{.{ .kind = .binary, .minimum = 1 }},
        .index_list => &.{.{ .kind = .index, .minimum = 1, .maximum = 2 }},
        .index => &.{.{ .kind = .offset, .maximum = MANY }},
        else => &.{},
    };
}

pub fn hasParams(kind: model.Kind) bool {
    return switch (kind) {
        .file_content, .source_file, .contact, .referenceable_param_group, .sample, .software, .scan_settings, .target, .instrument_configuration, .source, .analyzer, .detector, .processing_method, .run, .spectrum, .chromatogram, .scan_list, .scan, .scan_window, .isolation_window, .selected_ion, .activation, .binary_data_array => true,
        else => false,
    };
}

pub fn requiredAttributes(kind: model.Kind) []const u8 {
    return switch (kind) {
        .mzml => "version",
        .cv => "id fullName URI",
        .source_file => "id name location",
        .referenceable_param_group, .sample, .scan_settings, .instrument_configuration, .data_processing => "id",
        .software => "id version",
        .source_file_ref, .software_ref => "ref",
        .source, .analyzer, .detector => "order",
        .processing_method => "order softwareRef",
        .run => "id defaultInstrumentConfigurationRef",
        .spectrum_list, .chromatogram_list => "count defaultDataProcessingRef",
        .spectrum, .chromatogram => "id index defaultArrayLength",
        .binary_data_array => "encodedLength",
        .index_list => "count",
        .index => "name",
        .offset => "idRef",
        .cv_list, .source_file_list, .referenceable_param_group_list, .sample_list, .software_list, .scan_settings_list, .source_file_ref_list, .target_list, .instrument_configuration_list, .component_list, .data_processing_list, .scan_list, .scan_window_list, .precursor_list, .selected_ion_list, .product_list, .binary_data_array_list => "count",
        else => "",
    };
}

pub fn optionalAttributes(kind: model.Kind) []const u8 {
    return switch (kind) {
        .mzml => "id accession",
        .cv => "version",
        .sample => "name",
        .instrument_configuration => "scanSettingsRef",
        .run => "defaultSourceFileRef sampleRef startTimeStamp",
        .spectrum => "spotID dataProcessingRef sourceFileRef",
        .chromatogram => "dataProcessingRef",
        .scan => "spectrumRef sourceFileRef externalSpectrumID instrumentConfigurationRef",
        .precursor => "spectrumRef sourceFileRef externalSpectrumID",
        .binary_data_array => "arrayLength dataProcessingRef",
        .offset => "spotID scanTime",
        else => "",
    };
}

pub fn contains(words: []const u8, name: []const u8) bool {
    var iterator = std.mem.tokenizeScalar(u8, words, ' ');
    while (iterator.next()) |word| if (std.mem.eql(u8, word, name)) return true;
    return false;
}

pub const Sequence = struct {
    rules: []const Rule,
    position: usize = 0,
    count: usize = 0,

    pub fn accept(self: *Sequence, kind: model.Kind) error{InvalidStructure}!void {
        while (self.position < self.rules.len) {
            const rule = self.rules[self.position];
            if (rule.kind == kind) {
                if (self.count == rule.maximum) return error.InvalidStructure;
                self.count += 1;
                return;
            }
            if (self.count < rule.minimum) return error.InvalidStructure;
            self.position += 1;
            self.count = 0;
        }
        return error.InvalidStructure;
    }

    pub fn finish(self: *Sequence) error{InvalidStructure}!void {
        while (self.position < self.rules.len) {
            if (self.count < self.rules[self.position].minimum) return error.InvalidStructure;
            self.position += 1;
            self.count = 0;
        }
    }
};

// --- Constructed hierarchy checks ---

pub const Limits = struct { depth: usize = 64, nodes: usize = 100_000, text_bytes: usize = 256 * 1024 * 1024 };
pub const Error = cv.ValueError || base64.Error || error{
    InvalidStructure,
    MissingAttribute,
    UnknownAttribute,
    CountMismatch,
    EncodedLengthMismatch,
    PayloadNotRetained,
    UnsupportedVersion,
    LimitExceeded,
    InvalidOptions,
    DuplicateAttribute,
};

/// Checks retained metadata without emitting XML or requiring future record lists.
pub fn checkHeader(header: model.Header, limits: Limits) Error!void {
    try checkLimits(limits);
    if (header.document.kind != .mzml or header.run.kind != .run or header.run.children.len != 0)
        return error.InvalidStructure;
    if (!std.mem.eql(u8, header.document.attribute("version") orelse "", "1.1.0"))
        return error.UnsupportedVersion;
    var sequence: Sequence = .{ .rules = children(.mzml) };
    var budget: usize = limits.nodes;
    try checkAttributes(header.document);
    try checkAttributes(header.run);
    if (header.document.params.len != 0 or header.document.text != null or header.run.text != null)
        return error.InvalidStructure;
    for (header.document.children) |node| {
        try sequence.accept(node.kind);
        _ = try validateNode(node, limits, 1, &budget, true);
    }
    try sequence.accept(.run);
    try sequence.finish();
    try validateParams(header.run.params, true);
}

/// Checks a standalone hierarchy with the same structural rules used when writing.
pub fn checkNode(node: model.Node, limits: Limits) Error!void {
    try checkLimits(limits);
    var budget = limits.nodes;
    _ = try validateNode(node, limits, 1, &budget, true);
}

/// Checks a record hierarchy without inspecting retained or skipped binary text.
pub fn checkMetadataNode(node: model.Node, limits: Limits) Error!void {
    try checkLimits(limits);
    var budget = limits.nodes;
    _ = try validateNode(node, limits, 1, &budget, false);
}

pub fn checkLimits(limits: Limits) Error!void {
    if (limits.depth == 0 or limits.depth > 64 or limits.nodes == 0) return error.InvalidOptions;
}

/// Checks schema numeric ranges before counts are used for allocation or comparison.
/// Collection sizes remain nonnegative even where the XSD uses the signed xs:int type.
pub fn checkNumericAttributes(node: model.Node) cv.ValueError!void {
    inline for (.{ "count", "arrayLength", "defaultArrayLength", "index", "encodedLength" }) |name| {
        if (node.attribute(name)) |value| _ = try cv.parseInteger(usize, value);
    }
    if (node.attribute("defaultArrayLength")) |value| _ = try cv.parseInteger(i32, value);
    if (node.kind == .scan_window_list) {
        if (node.attribute("count")) |value| _ = try cv.parseInteger(i32, value);
    }
    if (node.attribute("order")) |value| switch (node.kind) {
        .source, .analyzer, .detector => _ = try cv.parseInteger(i32, value),
        .processing_method => _ = try cv.parseInteger(usize, value),
        else => {},
    };
}

fn validateNode(node: model.Node, limits: Limits, depth: usize, budget: *usize, comptime payload: bool) Error!usize {
    if (depth > limits.depth or budget.* == 0) return error.LimitExceeded;
    budget.* -= 1;
    try checkAttributes(node);
    if (hasParams(node.kind)) {
        try validateParams(node.params, node.kind != .referenceable_param_group);
    } else if (node.params.len != 0) return error.InvalidStructure;
    var significant: usize = 0;
    if (node.kind == .binary) {
        if (payload) {
            const text = node.text orelse return error.PayloadNotRetained;
            if (text.len > limits.text_bytes) return error.LimitExceeded;
            const counts = try base64.validate(text, .{
                .text_bytes = limits.text_bytes,
                .significant_bytes = limits.text_bytes,
                .decoded_bytes = limits.text_bytes,
            });
            significant = counts.significant_bytes;
        }
    } else if (node.text != null) return error.InvalidStructure;
    var sequence: Sequence = .{ .rules = children(node.kind) };
    for (node.children) |child| {
        try sequence.accept(child.kind);
        const child_length = try validateNode(child, limits, depth + 1, budget, payload);
        if (payload and child.kind == .binary) significant = child_length;
    }
    try sequence.finish();
    if (try node.declaredCount()) |count| {
        if (count != node.children.len) return error.CountMismatch;
    }
    if (payload and node.kind == .binary_data_array) {
        if (try cv.parseInteger(usize, node.attribute("encodedLength")) != significant)
            return error.EncodedLengthMismatch;
    }
    return significant;
}

fn checkAttributes(node: model.Node) Error!void {
    const required = requiredAttributes(node.kind);
    var names = std.mem.tokenizeScalar(u8, required, ' ');
    while (names.next()) |name| if (node.attribute(name) == null) return error.MissingAttribute;
    for (node.attributes, 0..) |attr, i| {
        for (node.attributes[0..i]) |previous| {
            const same_namespace = if (attr.namespace_uri) |uri|
                (if (previous.namespace_uri) |other| std.mem.eql(u8, uri, other) else false)
            else
                previous.namespace_uri == null;
            if (std.mem.eql(u8, attr.name, previous.name) and same_namespace)
                return error.DuplicateAttribute;
        }
        if (attr.namespace_uri) |uri| {
            if (!std.mem.eql(u8, uri, "http://www.w3.org/2001/XMLSchema-instance") or !std.mem.eql(u8, attr.name, "schemaLocation"))
                return error.UnknownAttribute;
        } else if (!contains(required, attr.name) and
            !contains(optionalAttributes(node.kind), attr.name)) return error.UnknownAttribute;
    }
    try checkNumericAttributes(node);
}

fn validateParams(params: []const cv.Entry, allow_refs: bool) Error!void {
    var rank: u2 = 0;
    for (params) |entry| {
        const selected: u2 = switch (entry) {
            .group_ref => 0,
            .cv => 1,
            .user => 2,
        };
        if (selected < rank or (selected == 0 and !allow_refs)) return error.InvalidStructure;
        rank = selected;
        switch (entry) {
            .group_ref => |ref| if (ref == null) {
                return error.MissingAttribute;
            },
            .cv => |p| if (p.cv_ref == null or p.accession == null or p.name == null) {
                return error.MissingAttribute;
            },
            .user => |p| if (p.name == null) {
                return error.MissingAttribute;
            },
        }
    }
}

const MANY = std.math.maxInt(usize);
