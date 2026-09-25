//! Copies mzML records and header metadata into independently owned arenas.
//!
//! Owners must not be copied. Their views remain valid until deinit; cloning does not
//! restore skipped payloads. Keep an owned header for group resolution.

const std = @import("std");
const cv = @import("../cv/source.zig");
const model = @import("model.zig");
const copy = @import("internal/owned_copy.zig");

/// Limits copied storage, excluding arena bookkeeping and alignment padding.
pub const Limits = struct {
    bytes: usize = 256 * 1024 * 1024,
    /// Maximum node nesting, counting the root as one; supported range is 1-64.
    depth: usize = 64,
};

/// Copying failures leave no owned allocations behind.
pub const Error = copy.Error;

/// Independently owned record. Group references remain references to header metadata.
pub const Record = struct {
    arena: std.heap.ArenaAllocator,
    value: model.Record,

    /// Deep-copies every source slice; the caller releases the result with deinit.
    pub fn init(allocator: std.mem.Allocator, source: model.Record, limits: Limits) Error!Record {
        if (limits.depth == 0 or limits.depth > 64) return error.LimitExceeded;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var copier: copy.Copier = .{ .allocator = arena.allocator(), .remaining = limits.bytes };
        var value = source;
        value.node = try copier.node(source.node, limits.depth);
        value.id = try copier.text(source.id);
        return .{ .arena = arena, .value = value };
    }

    /// Releases all copied slices and invalidates value and any borrowed views of it.
    pub fn deinit(self: *Record) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Independently owned metadata, including parameter groups and observed list descriptors.
pub const Header = struct {
    arena: std.heap.ArenaAllocator,
    value: model.Header,

    /// Copies the current header state, not future counts or offsets from its reader.
    /// The caller releases the result with deinit.
    pub fn init(allocator: std.mem.Allocator, source: model.Header, limits: Limits) Error!Header {
        if (limits.depth == 0 or limits.depth > 64) return error.LimitExceeded;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var copier: copy.Copier = .{ .allocator = arena.allocator(), .remaining = limits.bytes };
        var value = source;
        value.namespace_uri = try copier.text(source.namespace_uri);
        value.document = try copier.node(source.document, limits.depth);
        value.run = try copier.node(source.run, limits.depth);
        const groups = try copier.alloc(cv.Group, source.groups.len);
        for (source.groups, groups) |group, *destination| destination.* = .{
            .id = try copier.text(group.id),
            .entries = try copier.entries(group.entries),
        };
        value.groups = groups;
        value.spectrum_list = try copier.list(source.spectrum_list);
        value.chromatogram_list = try copier.list(source.chromatogram_list);
        return .{ .arena = arena, .value = value };
    }

    /// Releases all metadata and invalidates value and group-dependent borrowed views.
    pub fn deinit(self: *Header) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
