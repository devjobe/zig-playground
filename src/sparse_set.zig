const std = @import("std");
const hasDeclaration = @import("metatype.zig").hasDeclaration;

pub fn SparseSet(comptime T: type) type {
    return struct {
        const Self = @This();

        dense: std.ArrayList(T),
        indices: std.ArrayList(usize),
        sparse: std.ArrayList(usize),

        pub fn init(allocator: *std.mem.Allocator) Self {
            return .{ .dense = std.ArrayList(T).init(allocator), .indices = std.ArrayList(usize).init(allocator), .sparse = std.ArrayList(usize).init(allocator) };
        }

        pub fn initCapacity(allocator: *std.mem.Allocator, dense_capacity: usize, sparse_capacity: usize) Self {
            return .{ .dense = std.ArrayList(T).initCapacity(allocator, dense_capacity), .indices = std.ArrayList(usize).initCapacity(allocator, dense_capacity), .sparse = std.ArrayList(usize).initCapacity(allocator, std.math.max(dense_capacity, sparse_capacity)) };
        }

        pub fn deinit(self: *Self) void {
            if (comptime hasDeclaration(T, "deinit")) {
                for (self.dense.items) |*item| {
                    item.deinit();
                }
            }
            self.dense.deinit();
            self.indices.deinit();
            self.sparse.deinit();
        }

        pub fn ensureCapacity(self: *Self, dense_capacity: usize, sparse_capacity: usize) !void {
            try self.dense.ensureCapacity(dense_capacity);
            try self.indices.ensureCapacity(dense_capacity);
            try self.sparse.ensureCapacity(std.math.max(dense_capacity, sparse_capacity));
        }

        pub fn count(self: *Self) usize {
            return self.dense.items.len;
        }

        pub fn items(self: *Self) []T {
            return self.dense.items;
        }

        pub fn indices(self: *Self) []usize {
            return self.indices.items;
        }

        pub fn getOrCreate(self: *Self, index: usize) !*T {
            const len = self.sparse.items.len;
            if (index >= len) {
                try self.sparse.appendNTimes(0, index + 1 - len);
            }
            var slot = self.sparse.items[index];
            if (slot == 0) {
                try self.indices.append(index);
                _ = try self.dense.addOne();
                slot = self.dense.items.len;
                self.sparse.items[index] = slot;
            }
            return &self.dense.items[slot - 1];
        }

        pub fn getOrAssert(self: *Self, index: usize) *T {
            const len = self.sparse.items.len;
            std.debug.assert(index < len);
            const slot = self.sparse.items[index];
            std.debug.assert(slot != 0);
            return &self.dense.items[slot - 1];
        }

        pub fn getOpt(self: *Self, index: usize) ?*T {
            const len = self.sparse.items.len;
            if (index >= len) {
                return null;
            }
            const slot = self.sparse.items[index];
            if (slot == 0) {
                return null;
            }
            return &self.dense.items[slot - 1];
        }

        pub fn contains(self: *const Self, index: usize) bool {
            return index < self.sparse.items.len and self.sparse.items[index] != 0;
        }

        pub fn swapDenseSlot(self: *Self, index1: usize, index2: usize) void {
            const slot1 = self.sparse.items[index1];
            const slot2 = self.sparse.items[index2];
            self.sparse.items[index1] = slot2;
            self.sparse.items[index2] = slot1;

            self.indices.items[slot1 - 1] = index2;
            self.indices.items[slot2 - 1] = index1;

            std.mem.swap(T, &self.dense.items[slot1 - 1], &self.dense.items[slot2 - 1]);
        }

        pub fn swapRemove(self: *Self, index: usize) T {
            const slot = self.sparse.items[index];
            std.debug.assert(slot != 0);
            self.sparse.items[index] = 0;
            _ = self.indices.swapRemove(slot - 1);
            if (self.indices.items.len > 0)
                self.sparse.items[self.indices.items[slot - 1]] = slot;
            return self.dense.swapRemove(slot - 1);
        }
    };
}

test "SparseSet.get" {
    var set = SparseSet(i32).init(std.testing.allocator);
    defer set.deinit();

    (try set.getOrCreate(5)).* = 10;
    std.testing.expect(set.contains(5));
    std.testing.expect(set.getOpt(5).?.* == 10);
    std.testing.expect(set.getOpt(1) == null);
}

test "SparseSet.swapRemove" {
    var set = SparseSet(i32).init(std.testing.allocator);
    defer set.deinit();

    (try set.getOrCreate(1)).* = 10;
    (try set.getOrCreate(2)).* = 20;

    _ = set.swapRemove(1);
    _ = set.swapRemove(2);

    std.testing.expect(set.count() == 0);
}
