//! Internal bridge between indexed lookup and forward-reader state.

const std = @import("std");
const model = @import("../model.zig");
const owned = @import("../owned.zig");
const cv = @import("../../cv/source.zig");
const DecodedArrays = @import("../decoded_arrays.zig");

pub const Reader = @import("reader_engine.zig");
pub const Scope = Reader.Scope;
pub const ParsedFooter = Reader.ParsedFooter;

pub fn nextIndexRecord(reader: *Reader) Reader.Error!?model.Record {
    return reader.nextIndexRecord();
}

pub fn resetFragmentParser(reader: *Reader) void {
    reader.cursor.resetEmpty();
}

pub fn readFragment(
    reader: *Reader,
    allocator: std.mem.Allocator,
    input: *std.Io.Reader,
    ancestors: usize,
    physical_start: u64,
    prefix_length: usize,
    complete: bool,
    groups: []const cv.Group,
    output: ?*DecodedArrays,
    reuse_ancestors: bool,
    expected: Reader.FragmentTarget,
) Reader.Error!owned.Record {
    reader.header.groups = groups;
    reader.decoded_arrays = output;
    defer {
        reader.header.groups = &.{};
        reader.decoded_arrays = null;
    }
    return reader.readFragment(allocator, input, ancestors, physical_start, prefix_length, complete, reuse_ancestors, expected);
}

pub fn parseFooter(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: Reader.Options,
    physical_start: u64,
    prefix_length: usize,
) Reader.Error!ParsedFooter {
    return Reader.parseFooter(allocator, bytes, options, physical_start, prefix_length);
}

pub fn resumeFollowingList(
    reader: *Reader,
    input: *std.Io.Reader,
    ancestors: usize,
    physical_start: u64,
    prefix_length: usize,
) Reader.Error!void {
    return reader.resumeFollowingList(input, ancestors, physical_start, prefix_length);
}

pub fn finishEmptySpectrumList(reader: *Reader) Reader.Error!void {
    return reader.finishEmptySpectrumList();
}

pub fn scopes(reader: *const Reader) []const Scope {
    return reader.scopes[0..reader.scope_count];
}

pub fn listScope(reader: *const Reader, index: usize) ?Scope {
    return reader.list_scopes[index];
}

pub fn header(reader: *const Reader) *const model.Header {
    return &reader.header;
}
