//! Hash maps that store entry positions and find them by the entries' IDs. An entry addresses its
//! ID by `id_start` and `id_len` in one byte list its owner keeps, so a position and a map key
//! are each 32 bits.

const std = @import("std");

pub fn IdIndex(comptime Entry: type) type {
    return struct {
        pub const Map = std.HashMapUnmanaged(u32, void, Context, std.hash_map.default_max_load_percentage);

        // Capacity comes first, so a failure leaves no position without its entry. The entry's ID
        // is already in ids.
        pub fn insert(
            map: *Map,
            allocator: std.mem.Allocator,
            entries: *std.ArrayList(Entry),
            ids: []const u8,
            entry: Entry,
        ) error{ OutOfMemory, DuplicateId }!void {
            try entries.ensureUnusedCapacity(allocator, 1);
            const context: Context = .{ .entries = entries.items, .ids = ids };
            const query: Query = .{ .entries = entries.items, .ids = ids };
            const found = try map.getOrPutContextAdapted(allocator, idOf(entry, ids), query, context);
            if (found.found_existing) return error.DuplicateId;
            found.key_ptr.* = @intCast(entries.items.len);
            entries.appendAssumeCapacity(entry);
        }

        pub fn idOf(entry: Entry, ids: []const u8) []const u8 {
            return ids[entry.id_start..][0..entry.id_len];
        }

        const Context = struct {
            entries: []const Entry,
            ids: []const u8,

            pub fn hash(self: Context, position: u32) u64 {
                return std.hash_map.hashString(idOf(self.entries[position], self.ids));
            }

            pub fn eql(_: Context, left: u32, right: u32) bool {
                return left == right;
            }
        };

        pub const Query = struct {
            entries: []const Entry,
            ids: []const u8,

            pub fn hash(_: Query, id: []const u8) u64 {
                return std.hash_map.hashString(id);
            }

            pub fn eql(self: Query, id: []const u8, position: u32) bool {
                return std.mem.eql(u8, id, idOf(self.entries[position], self.ids));
            }
        };
    };
}
