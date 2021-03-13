const std = @import("std");

const UniformBlobs = @import("uniform_blobs.zig").UniformBlobs;
const toPtr = @import("metatype.zig").toPtr;

pub const SparseBlobSet = struct {
    const Self = @This();

    dense: UniformBlobs,
    indices: std.ArrayList(usize),
    sparse: std.ArrayList(usize),

    pub fn init(allocator: *std.mem.Allocator, item_size: usize) Self {
        return .{ .dense = UniformBlobs.init(allocator, item_size), .indices = std.ArrayList(usize).init(allocator), .sparse = std.ArrayList(usize).init(allocator) };
    }

    pub fn initCapacity(allocator: *std.mem.Allocator, item_size: usize, dense_capacity: usize, sparse_capacity: usize) Self {
        return .{ .dense = UniformBlobs.initCapacity(allocator, item_size, dense_capacity), .indices = std.ArrayList(usize).initCapacity(allocator, dense_capacity), .sparse = std.ArrayList(usize).initCapacity(allocator, std.math.max(dense_capacity, sparse_capacity)) };
    }

    pub fn deinit(self: *Self) void {
        self.dense.deinit();
        self.indices.deinit();
        self.sparse.deinit();
    }

    pub fn ensureCapacity(self: *Self, dense_capacity: usize, sparse_capacity: usize) !void {
        try self.indices.ensureCapacity(dense_capacity);
        try self.dense.ensureCapacity(self.indices.capacity);
        try self.sparse.ensureCapacity(std.math.max(dense_capacity, sparse_capacity));
    }

    pub fn count(self: *Self) usize {
        return self.dense.len;
    }

    pub fn getOrCreateSlot(self: *Self, index: usize) usize {
        const len = self.sparse.items.len;
        if (index >= len) {
            self.ensureCapacity(self.indices.items.len + 1, index + 1) catch unreachable;
            self.sparse.appendNTimes(0, index + 1 - len) catch unreachable;
        }

        var slot = self.sparse.items[index];
        if (slot == 0) {
            self.indices.append(index) catch unreachable;
            self.dense.len += 1;

            slot = self.dense.len;
            self.sparse.items[index] = slot;
        }
        return slot;
    }

    pub fn getBytes(self: *Self, index: usize) []u8 {
        return self.dense.getBytes(self.getOrCreateSlot(index) - 1);
    }

    pub fn get(self: *Self, comptime T: type, index: usize) *T {
        return self.dense.get(T, self.getOrCreateSlot(index) - 1);
    }

    pub fn getBytesOrNull(self: *Self, index: usize) ?[]u8 {
        const len = self.sparse.items.len;
        if (index >= len) {
            return null;
        }
        const slot = self.sparse.items[index];
        if (slot == 0) {
            return null;
        }
        return self.dense.getBytes(slot - 1);
    }

    pub fn getOrNull(self: *Self, comptime T: type, index: usize) ?*T {
        const data = self.getBytesOrNull(index);
        return if (data) |bytes| toPtr(T, bytes) else null;
    }

    pub fn contains(self: *Self, index: usize) bool {
        return index < self.sparse.items.len and self.sparse.items[index] != 0;
    }

    pub fn discard(self: *Self, index: usize) void {
        const slot = self.sparse.items[index];
        self.sparse.items[index] = 0;
        self.dense.swapRemove(slot - 1);

        if (slot > 1) {
            const slot_new_index = self.indices.item[slot - 1];
            self.indices.items[slot - 1] = slot_new_index;
        }
        self.indices.shrinkRetainingCapacity(slot - 1);
    }

    pub fn swapDenseSlot(self: *Self, index1: usize, index2: usize) void {
        if (index1 == index2)
            return;

        const slot1 = self.sparse.items[index1];
        const slot2 = self.sparse.items[index2];
        self.sparse.items[index1] = slot2;
        self.sparse.items[index2] = slot1;

        self.indices.items[slot1 - 1] = index2;
        self.indices.items[slot2 - 1] = index1;

        self.dense.swap(slot1 - 1, slot2 - 1);
    }

    pub fn remove(self: *Self, comptime T: type, index: usize) T {
        const slot = self.sparse.items[index];
        if (slot != self.indices.items.len) {
            self.swapDenseSlot(index, self.indices.items[self.indices.items.len - 1]);
        }

        self.sparse.items[index] = 0;
        self.indices.shrinkRetainingCapacity(self.indices.items.len - 1);
        return self.dense.pop(T);
    }
};

test "SparseBlobSet.get" {
    var set = SparseBlobSet.init(std.testing.allocator, 32);
    defer set.deinit();

    set.get(i32, 5).* = 10;
    std.testing.expect(set.contains(5));
    std.testing.expect(set.getOrNull(i32, 5).?.* == 10);
    std.testing.expect(set.getOrNull(i32, 1) == null);
}

test "SparseBlobSet.discard" {
    var set = SparseBlobSet.init(std.testing.allocator, 32);
    defer set.deinit();

    set.get(i32, 1).* = 10;
    set.get(i32, 2).* = 20;

    set.discard(1);
    set.discard(2);

    std.testing.expect(set.count() == 0);
}

test "SparseBlobSet.remove" {
    var set = SparseBlobSet.init(std.testing.allocator, 32);
    defer set.deinit();

    set.get(i32, 1).* = 10;
    set.get(i32, 2).* = 20;

    std.testing.expect(set.remove(i32, 2) == 20);
    std.testing.expect(set.remove(i32, 1) == 10);
    std.testing.expect(set.count() == 0);
}
