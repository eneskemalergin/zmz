//! Defines supported mzML parent/child relationships.

const std = @import("std");
const xml = @import("../xml/mzml_adapter.zig");
const model = @import("model.zig");

// A child kind a parent allows, at most once unless many.
const Rule = struct { kind: model.Kind, many: bool = false };

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
            if (!rule.many) singular.insert(rule.kind);
        }
        result.set(parent, .{ .allowed = allowed, .singular = singular });
    }
    break :blk result;
};

pub const MAX_DEPTH = xml.MAX_DEPTH;

pub const Error = error{InvalidStructure};

// The caller checks the namespace.
pub fn kindOf(local_name: []const u8) ?model.Kind {
    return ELEMENT_KINDS.get(local_name);
}

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
            .{ .kind = .file_content },          .{ .kind = .source_file_list },
            .{ .kind = .contact, .many = true },
        },
        .cv_list => &.{.{ .kind = .cv, .many = true }},
        .source_file_list => &.{.{ .kind = .source_file, .many = true }},
        .referenceable_param_group_list => &.{.{ .kind = .referenceable_param_group, .many = true }},
        .sample_list => &.{.{ .kind = .sample, .many = true }},
        .software_list => &.{.{ .kind = .software, .many = true }},
        .software => &.{.{ .kind = .software_param }},
        .acquisition_settings_list => &.{.{ .kind = .acquisition_settings, .many = true }},
        .acquisition_settings => &.{ .{ .kind = .source_file_ref_list }, .{ .kind = .target_list } },
        .scan_settings_list => &.{.{ .kind = .scan_settings, .many = true }},
        .scan_settings => &.{ .{ .kind = .source_file_ref_list }, .{ .kind = .target_list } },
        .source_file_ref_list => &.{.{ .kind = .source_file_ref, .many = true }},
        .target_list => &.{.{ .kind = .target, .many = true }},
        .instrument_configuration_list => &.{.{ .kind = .instrument_configuration, .many = true }},
        .instrument_configuration => &.{ .{ .kind = .component_list }, .{ .kind = .software_ref } },
        .component_list => &.{
            .{ .kind = .source, .many = true },
            .{ .kind = .analyzer, .many = true },
            .{ .kind = .detector, .many = true },
        },
        .data_processing_list => &.{.{ .kind = .data_processing, .many = true }},
        .data_processing => &.{.{ .kind = .processing_method, .many = true }},
        .run => &.{ .{ .kind = .source_file_ref_list }, .{ .kind = .spectrum_list }, .{ .kind = .chromatogram_list } },
        .spectrum_list => &.{.{ .kind = .spectrum, .many = true }},
        .chromatogram_list => &.{.{ .kind = .chromatogram, .many = true }},
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
        .scan_list => &.{.{ .kind = .scan, .many = true }},
        .spectrum_description => &.{ .{ .kind = .acquisition_list }, .{ .kind = .precursor_list }, .{ .kind = .scan } },
        .acquisition_list => &.{.{ .kind = .acquisition, .many = true }},
        .scan => &.{.{ .kind = .scan_window_list }},
        .scan_window_list => &.{.{ .kind = .scan_window, .many = true }},
        .precursor_list => &.{.{ .kind = .precursor, .many = true }},
        .precursor => &.{
            .{ .kind = .isolation_window }, .{ .kind = .selected_ion_list },
            .{ .kind = .activation },
        },
        .selected_ion_list => &.{.{ .kind = .selected_ion, .many = true }},
        .product_list => &.{.{ .kind = .product, .many = true }},
        .product => &.{.{ .kind = .isolation_window }},
        .binary_data_array_list => &.{.{ .kind = .binary_data_array, .many = true }},
        .binary_data_array => &.{.{ .kind = .binary }},
        .index_list => &.{.{ .kind = .index, .many = true }},
        .index => &.{.{ .kind = .offset, .many = true }},
        else => &.{},
    };
}

pub fn checkHeader(header: model.Header) Error!void {
    if (header.document.kind != .mzml or header.run.kind != .run)
        return error.InvalidStructure;
    for (header.run.children) |child| if (child.kind != .source_file_ref_list) return error.InvalidStructure;
    if (header.document.text != null or header.run.text != null) return error.InvalidStructure;
}

const ELEMENT_KINDS = std.StaticStringMap(model.Kind).initComptime(blk: {
    const kinds = std.meta.tags(model.Kind);
    var entries: [kinds.len]struct { []const u8, model.Kind } = undefined;
    for (kinds, &entries) |value, *entry| entry.* = .{ value.xmlName(), value };
    break :blk entries;
});
