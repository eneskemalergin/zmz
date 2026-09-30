//! Saved mzML failures contain values only and survive parser/output cleanup.
//! Native Zig errors still control execution. IDs group related causes and keep
//! explicit numbers; descriptions may change, but published IDs are not reused.
//! Locations are optional physical byte offsets. Input events do not identify an
//! exact bad decoded character; output offsets do not imply a successful flush.
//! Formatting writes to the caller's sink without allocating or changing the report.

const std = @import("std");
const model = @import("model.zig");
const xml = @import("../xml/mzml_adapter.zig");

const Diagnostic = @This();
const Errors = @import("stream_reader.zig").StreamReader.Error || @import("indexed_reader.zig").Error || @import("writer.zig").Error;

id: Id,
code: anyerror,
operation: Operation,
stage: Stage,
location: ?Location = null,
element: ?model.Kind = null,
record: ?RecordPosition = null,
array_position: ?usize = null,
detail: Detail = .none,

pub const Id = enum(u16) {
    out_of_memory = 1,
    limit_exceeded = 2,
    xml_encoding_unavailable = 3,
    array_encoding_unavailable = 4,
    missing_attribute = 5,
    invalid_base64 = 6,
    decoded_size_mismatch = 7,
    invalid_index = 8,
    write_failed = 9,
    array_decode_failed = 10,
    invalid_xml = 11,
    invalid_structure = 12,
    invalid_value = 13,
    invalid_state = 14,
    invalid_options = 15,
    size_overflow = 16,
    buffer_error = 17,
    missing_payload = 18,
    group_error = 19,
    array_declaration_error = 20,
    missing_index = 21,
    duplicate_id = 22,
    ambiguous_id = 23,
    source_changed = 24,
    unsupported_source = 25,
    truncated_source = 26,
    io_failed = 27,
    canceled = 28,
    count_mismatch = 29,
    encoded_length_mismatch = 30,

    pub fn description(self: Id) []const u8 {
        return switch (self) {
            .out_of_memory => "allocation failed",
            .limit_exceeded => "configured limit exceeded",
            .xml_encoding_unavailable => "XML character encoding is not supported",
            .array_encoding_unavailable => "array encoding is not supported",
            .missing_attribute => "operation needs an absent attribute",
            .invalid_base64 => "Base64 decoding failed",
            .decoded_size_mismatch => "decoded size differs from the expected size",
            .invalid_index => "record index or index entry is invalid",
            .write_failed => "output write failed",
            .array_decode_failed => "array decoding failed",
            .invalid_xml => "XML cannot be processed",
            .invalid_structure => "structure cannot be processed",
            .invalid_value => "value cannot be interpreted",
            .invalid_state => "operation cannot run in the current state",
            .invalid_options => "options cannot be used for this operation",
            .size_overflow => "size or offset cannot be represented",
            .buffer_error => "buffer cannot be used for this operation",
            .missing_payload => "array payload is not available",
            .group_error => "parameter group cannot be expanded",
            .array_declaration_error => "array declarations cannot be interpreted",
            .missing_index => "embedded index is not available",
            .duplicate_id => "record ID occurs more than once in its index",
            .ambiguous_id => "ID identifies both a spectrum and a chromatogram",
            .source_changed => "indexed source has changed",
            .unsupported_source => "source does not allow indexed reading",
            .truncated_source => "source ended before the requested bytes",
            .io_failed => "input or output operation failed",
            .canceled => "operation was canceled",
            .count_mismatch => "count differs from the expected count",
            .encoded_length_mismatch => "encodedLength differs from the prepared bytes",
        };
    }
};

pub const Operation = enum { read_header, read_record, read_item, open_index, rebuild_index, lookup_record, write_header, open_list, write_record, write_item, close_list, finish };
pub const Stage = enum { xml, metadata, base64, array, index, output };
pub const Location = union(enum) { input_event: u64, input_byte: u64, output_byte: u64 };
pub const RecordPosition = struct {
    kind: enum { spectrum, chromatogram },
    ordinal: usize,

    /// Positions a record; any kind other than spectrum counts as a chromatogram.
    pub fn of(kind: model.Kind, ordinal: usize) RecordPosition {
        return .{ .kind = if (kind == .spectrum) .spectrum else .chromatogram, .ordinal = ordinal };
    }
};
pub const Attribute = enum {
    id,
    index,
    count,
    default_array_length,
    array_length,
    encoded_length,
    ref,
    name,
    id_ref,

    pub fn xmlName(self: Attribute) []const u8 {
        return switch (self) {
            .default_array_length => "defaultArrayLength",
            .array_length => "arrayLength",
            .encoded_length => "encodedLength",
            .id_ref => "idRef",
            else => @tagName(self),
        };
    }
};
pub const Limit = enum {
    depth,
    attributes,
    attribute_bytes,
    header_bytes,
    record_bytes,
    nodes,
    list_entries,
    binary_text_bytes,
    array_bytes,
    base64_text_bytes,
    base64_significant_bytes,
    base64_decoded_bytes,
    index_bytes,
    record_span_bytes,
    records,
    id_bytes,
    text_bytes,
    xml_declaration_bytes,
    xml_text_bytes,
};
pub const Detail = union(enum) {
    none,
    attribute: Attribute,
    limit: struct { name: Limit, maximum: u64, needed: ?u64 = null },
    size: struct { expected: u64, actual: u64, unit: SizeUnit },
};
pub const SizeUnit = enum { bytes, values, records, arrays, index };

/// Maps a typed operation error using its capture stage and any known limit.
/// New errors must be assigned deliberately; generic I/O errors are listed explicitly.
pub fn init(code: Errors, operation: Operation, stage: Stage, detail: Detail) Diagnostic {
    const id: Id = switch (code) {
        error.OutOfMemory => .out_of_memory,
        error.LimitExceeded, error.WriterLimit => if (detail == .limit) .limit_exceeded else .size_overflow,
        error.UnsupportedEncoding => if (stage == .xml) .xml_encoding_unavailable else .array_encoding_unavailable,
        error.MissingAttribute => .missing_attribute,
        error.MissingValue => if (detail == .attribute) .missing_attribute else .invalid_value,
        error.InvalidCharacter => if (stage == .base64) .invalid_base64 else .invalid_xml,
        error.InvalidPadding, error.NonCanonicalTail => .invalid_base64,
        error.TruncatedInput => if (stage == .base64) .invalid_base64 else .array_decode_failed,
        error.DecodedSizeMismatch => .decoded_size_mismatch,
        error.InvalidIndex => .invalid_index,
        error.WriteFailed => .write_failed,
        error.InvalidData, error.ChecksumMismatch, error.TrailingInput, error.UnsupportedDictionary, error.InvalidFixedPoint, error.MissingFixedPoint, error.UnexpectedFixedPoint, error.ToleranceUnattainable, error.ValueOutOfRange, error.MissingCompressor => .array_decode_failed,
        error.InvalidXml, error.InvalidEncoding, error.UnsupportedVersion, error.DtdForbidden, error.WrongNamespace, error.UnexpectedEnd, error.EndOfStream, error.NoText, error.InvalidName, error.InvalidNamespace, error.DuplicateAttribute => .invalid_xml,
        error.InvalidStructure, error.UnknownAttribute => .invalid_structure,
        error.EmptyValue, error.InvalidValue, error.Overflow => .invalid_value,
        error.InvalidState, error.FailedState, error.AlreadyFinished => .invalid_state,
        error.InvalidOptions => .invalid_options,
        error.LengthOverflow => .size_overflow,
        error.OutputTooSmall, error.OverlappingBuffers => .buffer_error,
        error.PayloadNotRetained => .missing_payload,
        error.MissingGroup, error.DuplicateGroup, error.NestedGroup, error.ExpansionLimit => .group_error,
        error.MissingPrimitive, error.MissingCompression, error.ConflictingPrimitive, error.ConflictingCompression, error.NotBinaryArray, error.TypeMismatch => .array_declaration_error,
        error.MissingIndex => .missing_index,
        error.DuplicateId => .duplicate_id,
        error.AmbiguousId => .ambiguous_id,
        error.StaleSource => .source_changed,
        error.UnsupportedSource => .unsupported_source,
        error.TruncatedSource, error.UnexpectedEndOfFile => .truncated_source,
        error.ReadFailed, error.AccessDenied, error.PermissionDenied, error.InputOutput, error.IsDir, error.LockViolation, error.NotOpenForReading, error.Streaming, error.SystemResources, error.Unexpected, error.Unseekable, error.WouldBlock, error.BrokenPipe, error.DeviceBusy, error.DiskQuota, error.FileBusy, error.FileTooBig, error.NoDevice, error.NoSpaceLeft, error.NotOpenForWriting => .io_failed,
        error.Canceled => .canceled,
        error.CountMismatch => .count_mismatch,
        error.EncodedLengthMismatch => .encoded_length_mismatch,
    };
    return .{ .id = id, .code = code, .operation = operation, .stage = stage, .detail = detail };
}

pub fn xmlDetail(cursor: *const xml.Cursor) Detail {
    const limit = cursor.limit_failure orelse return .none;
    return .{ .limit = .{
        .name = switch (limit) {
            .depth => .depth,
            .attributes => .attributes,
            .attribute_bytes => .attribute_bytes,
            .nodes => .nodes,
            .declaration_bytes => .xml_declaration_bytes,
            .text_bytes => .xml_text_bytes,
        },
        .maximum = switch (limit) {
            .depth => cursor.max_depth,
            .attributes => cursor.max_attributes,
            .attribute_bytes => cursor.max_attribute_bytes,
            .nodes => 0,
            .declaration_bytes => 4096,
            .text_bytes => 64 * 1024,
        },
    } };
}

/// Translates only events inside the source portion of an indexed fragment.
pub fn translate(self: *Diagnostic, start: u64, length: u64, prefix: usize) void {
    const location = self.location orelse return;
    self.location = switch (location) {
        .input_event => |offset| if (offset >= prefix and offset - prefix < length)
            .{ .input_event = start + (offset - prefix) }
        else
            null,
        else => null,
    };
}

pub fn format(self: Diagnostic, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("[ZMZ{d:0>4}] {s}: {s} ({s}); stage={s}", .{
        @intFromEnum(self.id), @tagName(self.operation), self.id.description(), @errorName(self.code), @tagName(self.stage),
    });
    if (self.location) |location| switch (location) {
        inline else => |offset, kind| try writer.print("; {s}={d}", .{ @tagName(kind), offset }),
    };
    if (self.element) |element| try writer.print("; element={s}", .{element.xmlName()});
    if (self.record) |record| try writer.print("; {s}_ordinal={d}", .{ @tagName(record.kind), record.ordinal });
    if (self.array_position) |position| try writer.print("; array_position={d}", .{position});
    switch (self.detail) {
        .none => {},
        .attribute => |attribute| try writer.print("; attribute={s}", .{attribute.xmlName()}),
        .limit => |limit| {
            try writer.print("; limit={s}; maximum={d}", .{ @tagName(limit.name), limit.maximum });
            if (limit.needed) |needed| try writer.print("; needed={d}", .{needed});
        },
        .size => |size| try writer.print("; expected={d}; actual={d}; unit={s}", .{ size.expected, size.actual, @tagName(size.unit) }),
    }
}
