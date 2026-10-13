//! Copies mzML headers, records, and forward items into independently owned arenas.
//!
//! Owners must not be copied: a copy and the original would free the same arena on deinit. Their
//! views remain valid until deinit; cloning does not restore skipped payloads. Keep an owned header
//! for group resolution. Failed copies release their allocated storage.

const std = @import("std");
const model = @import("model.zig");
const schema = @import("schema.zig");
const copy = @import("internal/owned_copy.zig");

/// Limits copied storage, excluding arena bookkeeping and alignment padding.
pub const Limits = struct {
    bytes: usize = 256 * 1024 * 1024,
};

pub const Error = copy.HeaderError;

/// Independently owned forward item, including XML or list attributes.
pub const Item = Owned(model.Item, copyItem);

/// Independently owned record. Group references remain references to header metadata.
pub const Record = Owned(model.Record, copyRecord);

/// Independently owned metadata, including parameter groups and observed list descriptors.
/// Copies the current header state, not future counts or offsets from its reader.
pub const Header = Owned(model.Header, copy.Copier.header);

fn Owned(comptime T: type, comptime copyValue: fn (*copy.Copier, T) Error!T) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        /// Deep-copies every source slice; the caller releases the result with deinit.
        pub fn init(allocator: std.mem.Allocator, source: T, limits: Limits) Error!@This() {
            var arena: std.heap.ArenaAllocator = .init(allocator);
            errdefer arena.deinit();
            var copier: copy.Copier = .{ .allocator = arena.allocator(), .remaining = limits.bytes };
            const value = try copyValue(&copier, source);
            return .{ .arena = arena, .value = value };
        }

        /// Releases all copied slices and invalidates value and any borrowed views of it.
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

fn copyItem(copier: *copy.Copier, source: model.Item) Error!model.Item {
    return switch (source) {
        .xml => |bytes| .{ .xml = try copier.text(bytes) },
        .list_start => |start| .{ .list_start = .{ .kind = start.kind, .list = (try copier.list(start.list)).? } },
        .record => |record| .{ .record = try copyRecord(copier, record) },
        .list_end, .run_end => source,
    };
}

fn copyRecord(copier: *copy.Copier, source: model.Record) Error!model.Record {
    var value = source;
    value.node = try copier.node(source.node, schema.MAX_DEPTH);
    value.id = try copier.text(source.id);
    return value;
}
