//! Maps established mzML encoding declarations to binary pipelines and back.

const std = @import("std");
const cv = @import("../cv/source.zig");

pub const Primitive = enum { float32, float64, int32, int64 };
pub const Pipeline = enum { none, zlib, linear, pic, slof, linear_zlib, pic_zlib, slof_zlib };

/// Returns whether a pipeline changes numeric values into the Numpress wire format.
pub fn isNumpress(pipeline: Pipeline) bool {
    return switch (pipeline) {
        .linear, .pic, .slof, .linear_zlib, .pic_zlib, .slof_zlib => true,
        .none, .zlib => false,
    };
}

pub const Term = struct { accession: []const u8, name: []const u8 };

pub fn primitiveTerm(primitive: Primitive) Term {
    return switch (primitive) {
        .float32 => .{ .accession = "MS:1000521", .name = "32-bit float" },
        .float64 => .{ .accession = "MS:1000523", .name = "64-bit float" },
        .int32 => .{ .accession = "MS:1000519", .name = "32-bit integer" },
        .int64 => .{ .accession = "MS:1000522", .name = "64-bit integer" },
    };
}

pub fn codecTerm(pipeline: Pipeline) Term {
    return switch (pipeline) {
        .none => .{ .accession = "MS:1000576", .name = "no compression" },
        .zlib => .{ .accession = "MS:1000574", .name = "zlib compression" },
        .linear => .{ .accession = "MS:1002312", .name = "MS-Numpress linear prediction compression" },
        .pic => .{ .accession = "MS:1002313", .name = "MS-Numpress positive integer compression" },
        .slof => .{ .accession = "MS:1002314", .name = "MS-Numpress short logged float compression" },
        .linear_zlib => .{ .accession = "MS:1002746", .name = "MS-Numpress linear prediction compression followed by zlib compression" },
        .pic_zlib => .{ .accession = "MS:1002747", .name = "MS-Numpress positive integer compression followed by zlib compression" },
        .slof_zlib => .{ .accession = "MS:1002748", .name = "MS-Numpress short logged float compression followed by zlib compression" },
    };
}

/// A recognized established encoding. Unknown metadata remains in the source node.
pub const Descriptor = struct { primitive: Primitive, pipeline: Pipeline };

/// Failures when selecting an encoding, distinct from malformed payload bytes.
pub const Error = cv.ExpansionError || error{
    MissingPrimitive,
    MissingCompression,
    ConflictingPrimitive,
    ConflictingCompression,
    UnsupportedEncoding,
    NotBinaryArray,
    PayloadNotRetained,
    TypeMismatch,
};

/// Classifies only reviewed wire terms. It never selects a default for missing declarations.
/// This does not resolve arbitrary ontology descendants.
pub fn classify(params: []const cv.Entry, groups: []const cv.Group) Error!Descriptor {
    var primitive: ?Primitive = null;
    var pipeline: ?Pipeline = null;
    var iterator: cv.EffectiveIterator = .{ .entries = params, .groups = groups };
    while (try iterator.next()) |entry| {
        if (entry != .cv) continue;
        const accession = entry.cv.accession orelse continue;
        const raw = accession.raw;
        var p: ?Primitive = null;
        inline for (std.meta.tags(Primitive)) |candidate| {
            if (std.mem.eql(u8, raw, primitiveTerm(candidate).accession)) p = candidate;
        }
        if (p) |selected| {
            if (primitive != null) return error.ConflictingPrimitive;
            primitive = selected;
        }
        var c: ?Pipeline = null;
        inline for (std.meta.tags(Pipeline)) |candidate| {
            if (std.mem.eql(u8, raw, codecTerm(candidate).accession)) c = candidate;
        }
        if (c) |selected| {
            if (pipeline != null) return error.ConflictingCompression;
            pipeline = selected;
        }
        if (std.mem.eql(u8, raw, "MS:1000520") or std.mem.eql(u8, raw, "MS:1001479"))
            return error.UnsupportedEncoding;
        inline for (.{
            "MS:1003088", "MS:1003089", "MS:1003090",
            "MS:1003780", "MS:1003781", "MS:1003782",
            "MS:1003783", "MS:1003784", "MS:1003785",
        }) |unsupported| {
            if (std.mem.eql(u8, raw, unsupported)) return error.UnsupportedEncoding;
        }
    }
    return .{
        .primitive = primitive orelse return error.MissingPrimitive,
        .pipeline = pipeline orelse return error.MissingCompression,
    };
}
