//! Hash maps that store entry positions and find them by the entries' IDs.

const std = @import("std");

/// Types for a set of positions into a slice of Entry, looked up by Entry.id.
pub fn IdIndex(comptime Entry: type) type {
    return struct {
        pub const Map = std.HashMapUnmanaged(usize, void, Context, std.hash_map.default_max_load_percentage);

        // Capacity comes first, so a failure leaves no position without its entry.
        pub fn insert(
            map: *Map,
            allocator: std.mem.Allocator,
            entries: *std.ArrayList(Entry),
            entry: Entry,
        ) error{ OutOfMemory, DuplicateId }!void {
            try entries.ensureUnusedCapacity(allocator, 1);
            const query: Query = .{ .entries = entries.items };
            const found = try map.getOrPutContextAdapted(allocator, entry.id, query, .{ .entries = entries.items });
            if (found.found_existing) return error.DuplicateId;
            found.key_ptr.* = entries.items.len;
            entries.appendAssumeCapacity(entry);
        }

        const Context = struct {
            entries: []const Entry,

            pub fn hash(self: Context, position: usize) u64 {
                return std.hash_map.hashString(self.entries[position].id);
            }

            pub fn eql(_: Context, left: usize, right: usize) bool {
                return left == right;
            }
        };

        pub const Query = struct {
            entries: []const Entry,

            pub fn hash(_: Query, id: []const u8) u64 {
                return std.hash_map.hashString(id);
            }

            pub fn eql(self: Query, id: []const u8, position: usize) bool {
                return std.mem.eql(u8, id, self.entries[position].id);
            }
        };
    };
}
