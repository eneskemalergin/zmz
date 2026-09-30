//! Defines supported mzML parent/child relationships and shared writing limits.

const std = @import("std");
const model = @import("model.zig");

pub const Rule = struct { kind: model.Kind, maximum: usize = 1 };

pub fn children(kind: model.Kind) []const Rule {
    return switch (kind) {
        .mzml => &.{
            .{ .kind = .cv_list },                        .{ .kind = .file_description },
            .{ .kind = .referenceable_param_group_list }, .{ .kind = .sample_list },
            .{ .kind = .software_list },                  .{ .kind = .scan_settings_list },
            .{ .kind = .acquisition_settings_list },      .{ .kind = .instrument_configuration_list },
            .{ .kind = .data_processing_list },           .{ .kind = .run },
        },
        .file_description => &.{
            .{ .kind = .file_content },             .{ .kind = .source_file_list },
            .{ .kind = .contact, .maximum = MANY },
        },
        .cv_list => &.{.{ .kind = .cv, .maximum = MANY }},
        .source_file_list => &.{.{ .kind = .source_file, .maximum = MANY }},
        .referenceable_param_group_list => &.{.{ .kind = .referenceable_param_group, .maximum = MANY }},
        .sample_list => &.{.{ .kind = .sample, .maximum = MANY }},
        .software_list => &.{.{ .kind = .software, .maximum = MANY }},
        .software => &.{.{ .kind = .software_param }},
        .acquisition_settings_list => &.{.{ .kind = .acquisition_settings, .maximum = MANY }},
        .acquisition_settings => &.{ .{ .kind = .source_file_ref_list }, .{ .kind = .target_list } },
        .scan_settings_list => &.{.{ .kind = .scan_settings, .maximum = MANY }},
        .scan_settings => &.{ .{ .kind = .source_file_ref_list }, .{ .kind = .target_list } },
        .source_file_ref_list => &.{.{ .kind = .source_file_ref, .maximum = MANY }},
        .target_list => &.{.{ .kind = .target, .maximum = MANY }},
        .instrument_configuration_list => &.{.{ .kind = .instrument_configuration, .maximum = MANY }},
        .instrument_configuration => &.{ .{ .kind = .component_list }, .{ .kind = .software_ref } },
        .component_list => &.{
            .{ .kind = .source, .maximum = MANY },
            .{ .kind = .analyzer, .maximum = MANY },
            .{ .kind = .detector, .maximum = MANY },
        },
        .data_processing_list => &.{.{ .kind = .data_processing, .maximum = MANY }},
        .data_processing => &.{.{ .kind = .processing_method, .maximum = MANY }},
        .run => &.{ .{ .kind = .source_file_ref_list }, .{ .kind = .spectrum_list }, .{ .kind = .chromatogram_list } },
        .spectrum_list => &.{.{ .kind = .spectrum, .maximum = MANY }},
        .chromatogram_list => &.{.{ .kind = .chromatogram, .maximum = MANY }},
        .spectrum => &.{
            .{ .kind = .spectrum_description },
            .{ .kind = .scan_list },
            .{ .kind = .precursor_list },
            .{ .kind = .product_list },
            .{ .kind = .binary_data_array_list },
        },
        .chromatogram => &.{
            .{ .kind = .precursor },              .{ .kind = .product },
            .{ .kind = .binary_data_array_list },
        },
        .scan_list => &.{.{ .kind = .scan, .maximum = MANY }},
        .spectrum_description => &.{ .{ .kind = .acquisition_list }, .{ .kind = .precursor_list }, .{ .kind = .scan } },
        .acquisition_list => &.{.{ .kind = .acquisition, .maximum = MANY }},
        .scan => &.{.{ .kind = .scan_window_list }},
        .scan_window_list => &.{.{ .kind = .scan_window, .maximum = MANY }},
        .precursor_list => &.{.{ .kind = .precursor, .maximum = MANY }},
        .precursor => &.{
            .{ .kind = .isolation_window }, .{ .kind = .selected_ion_list },
            .{ .kind = .activation },
        },
        .selected_ion_list => &.{.{ .kind = .selected_ion, .maximum = MANY }},
        .product_list => &.{.{ .kind = .product, .maximum = MANY }},
        .product => &.{.{ .kind = .isolation_window }},
        .binary_data_array_list => &.{.{ .kind = .binary_data_array, .maximum = MANY }},
        .binary_data_array => &.{.{ .kind = .binary }},
        .index_list => &.{.{ .kind = .index, .maximum = 2 }},
        .index => &.{.{ .kind = .offset, .maximum = MANY }},
        else => &.{},
    };
}

pub const CHILD_KINDS = blk: {
    @setEvalBranchQuota(2000);
    var result: std.EnumArray(model.Kind, struct {
        allowed: std.EnumSet(model.Kind),
        singular: std.EnumSet(model.Kind),
    }) = undefined;
    for (std.enums.values(model.Kind)) |parent| {
        var allowed = std.EnumSet(model.Kind).initEmpty();
        var singular = std.EnumSet(model.Kind).initEmpty();
        for (children(parent)) |rule| {
            allowed.insert(rule.kind);
            if (rule.maximum == 1) singular.insert(rule.kind);
        }
        result.set(parent, .{ .allowed = allowed, .singular = singular });
    }
    break :blk result;
};

/// Deepest element nesting any reader, writer, copy, or builder supports, counting the root.
pub const MAX_DEPTH = 64;

pub const Limits = struct { depth: usize = MAX_DEPTH, nodes: usize = 100_000, text_bytes: usize = 256 * 1024 * 1024 };
pub const Error = error{
    InvalidStructure,
    MissingAttribute,
    PayloadNotRetained,
    LimitExceeded,
    InvalidOptions,
};

pub fn checkHeader(header: model.Header) Error!void {
    if (header.document.kind != .mzml or header.run.kind != .run)
        return error.InvalidStructure;
    for (header.run.children) |child| if (child.kind != .source_file_ref_list) return error.InvalidStructure;
    if (header.document.text != null or header.run.text != null) return error.InvalidStructure;
}

pub fn checkLimits(limits: Limits) Error!void {
    if (limits.depth == 0 or limits.depth > MAX_DEPTH or limits.nodes == 0) return error.InvalidOptions;
}

const MANY = std.math.maxInt(usize);
