//! Maps established mzML encoding declarations to binary pipelines and back.

const std = @import("std");
const cv = @import("../cv/source.zig");
const numpress = @import("numpress.zig");

pub const Primitive = enum {
    float32,
    float64,
    int32,
    int64,

    /// The primitive stored as Zig type T.
    pub fn of(comptime T: type) Primitive {
        return switch (T) {
            f32 => .float32,
            f64 => .float64,
            i32 => .int32,
            i64 => .int64,
            else => @compileError("array values must be f32, f64, i32, or i64"),
        };
    }

    /// The Zig type of the primitive.
    pub fn Type(comptime self: Primitive) type {
        return switch (self) {
            .float32 => f32,
            .float64 => f64,
            .int32 => i32,
            .int64 => i64,
        };
    }

    /// Bytes per value.
    pub fn size(self: Primitive) usize {
        return switch (self) {
            .float32, .int32 => 4,
            .float64, .int64 => 8,
        };
    }
};

/// Names follow encoding order before Base64.
pub const Pipeline = enum {
    none,
    zlib,
    linear,
    pic,
    slof,
    linear_zlib,
    pic_zlib,
    slof_zlib,

    /// The Numpress step, applied before optional zlib.
    pub fn transform(self: Pipeline) ?numpress.Transform {
        return switch (self) {
            .none, .zlib => null,
            .linear, .linear_zlib => .linear,
            .pic, .pic_zlib => .pic,
            .slof, .slof_zlib => .slof,
        };
    }

    pub fn hasZlib(self: Pipeline) bool {
        return switch (self) {
            .zlib, .linear_zlib, .pic_zlib, .slof_zlib => true,
            .none, .linear, .pic, .slof => false,
        };
    }

    pub fn isNumpress(self: Pipeline) bool {
        return self.transform() != null;
    }
};

pub const Term = struct { accession: []const u8, name: []const u8 };

pub fn primitiveTerm(primitive: Primitive) Term {
    return switch (primitive) {
        .float32 => .{ .accession = "MS:1000521", .name = "32-bit float" },
        .float64 => .{ .accession = "MS:1000523", .name = "64-bit float" },
        .int32 => .{ .accession = "MS:1000519", .name = "32-bit integer" },
        .int64 => .{ .accession = "MS:1000522", .name = "64-bit integer" },
    };
}

pub fn primitiveFromAccession(accession: []const u8) ?Primitive {
    inline for (std.meta.tags(Primitive)) |primitive| {
        if (std.mem.eql(u8, accession, primitiveTerm(primitive).accession)) return primitive;
    }
    return null;
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

pub fn codecFromAccession(accession: []const u8) ?Pipeline {
    inline for (std.meta.tags(Pipeline)) |pipeline| {
        if (std.mem.eql(u8, accession, codecTerm(pipeline).accession)) return pipeline;
    }
    return null;
}

/// A recognized established encoding. Unknown metadata remains in the source node.
pub const Descriptor = struct {
    primitive: Primitive,
    pipeline: Pipeline,

    /// The primitive of decoded values: f64 for Numpress, the declared primitive otherwise.
    pub fn decodedPrimitive(self: Descriptor) Primitive {
        return if (self.pipeline.isNumpress()) .float64 else self.primitive;
    }

    /// The pipeline to decode a payload with. Some producers omit the zlib stream of an
    /// empty array, so an empty zlib array without Base64 characters decodes uncompressed.
    pub fn payloadPipeline(self: Descriptor, value_count: usize, empty_text: bool) Pipeline {
        return if (value_count == 0 and self.pipeline == .zlib and empty_text) .none else self.pipeline;
    }
};

/// Failures when selecting an encoding, distinct from malformed payload bytes.
pub const Error = cv.ExpansionError || error{
    MissingPrimitive,
    MissingCompression,
    ConflictingPrimitive,
    ConflictingCompression,
    UnsupportedEncoding,
};

/// What one CV accession declares about an array's encoding.
pub const Declared = union(enum) { primitive: Primitive, compression: Pipeline, unsupported };

/// The encoding meaning of one accession, or null when it says nothing about encoding. Recognized
/// but unsupported encodings (zstd, byte shuffling, other Numpress forms, coordinate grids) are
/// `unsupported`; tests check every current PSI-MS binary data and compression type is covered.
pub fn declared(accession: []const u8) ?Declared {
    if (primitiveFromAccession(accession)) |primitive| return .{ .primitive = primitive };
    if (codecFromAccession(accession)) |pipeline| return .{ .compression = pipeline };
    inline for (.{
        "MS:1000520", "MS:1001479", "MS:1003088", "MS:1003089", "MS:1003090",
        "MS:1003780", "MS:1003781", "MS:1003782", "MS:1003783", "MS:1003784",
        "MS:1003785", "MS:1003826",
    }) |unsupported| {
        if (std.mem.eql(u8, accession, unsupported)) return .unsupported;
    }
    return null;
}

/// Classifies the reviewed primitive and compression terms. A missing term is an error, and
/// repeated terms must agree.
pub fn classify(params: []const cv.Entry, groups: []const cv.Group) Error!Descriptor {
    var primitive: ?Primitive = null;
    var pipeline: ?Pipeline = null;
    var iterator: cv.EffectiveIterator = .{ .entries = params, .groups = groups };
    while (try iterator.next()) |entry| {
        if (entry != .cv) continue;
        const accession = entry.cv.accession orelse continue;
        switch (declared(accession.raw) orelse continue) {
            .primitive => |selected| {
                if (primitive != null and primitive.? != selected) return error.ConflictingPrimitive;
                primitive = selected;
            },
            .compression => |selected| {
                if (pipeline != null and pipeline.? != selected) return error.ConflictingCompression;
                pipeline = selected;
            },
            .unsupported => return error.UnsupportedEncoding,
        }
    }
    return .{
        .primitive = primitive orelse return error.MissingPrimitive,
        .pipeline = pipeline orelse return error.MissingCompression,
    };
}
