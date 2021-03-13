const std = @import("std");
const toPtr = @import("metatype.zig").toPtr;

pub const UniformBlobs = struct {
    const Self = @This();

    data: []u8,
    len: usize,
    capacity: usize,
    item_size: usize,
    allocator: *std.mem.Allocator,

    pub fn init(allocator: *std.mem.Allocator, item_size: usize) Self {
        return .{
            .data = &[_]u8{},
            .len = 0,
            .capacity = 0,
            .item_size = item_size,
            .allocator = allocator,
        };
    }

    pub fn initCapacity(allocator: *std.mem.Allocator, item_size: usize, capacity: usize) !Self {
        var self = Self.init(allocator, item_size);
        try self.ensureCapacity(capacity);
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }

    pub fn ensureCapacity(self: *Self, new_capacity: usize) !void {
        if (self.capacity < new_capacity) {
            self.data = try self.allocator.realloc(self.data, new_capacity * self.item_size);
            self.capacity = new_capacity;
        }
    }

    pub fn items(self: *Self, comptime T: type) []T {
        if (comptime @sizeOf(T) == 0) {
            var x: []T = undefined;
            x.ptr = @ptrCast([*]T, self.data.ptr);
            x.len = self.len;
            return x;
        } else {
            return std.mem.bytesAsSlice(T, @alignCast(@alignOf(T), self.data[0 .. self.len * self.item_size]));
        }
    }

    pub fn getBytes(self: *Self, index: usize) []u8 {
        const offset = self.item_size * index;
        return self.data[offset .. offset + self.item_size];
    }

    pub fn pushBytes(self: *Self, item: []const u8) void {
        std.mem.copy(u8, self.getBytes(self.len), item);
        self.len += 1;
    }

    pub fn popBytes(self: *Self, item: []u8) void {
        self.len -= 1;
        std.mem.copy(u8, item, self.getBytes(self.len)[0..item.len]);
    }

    pub fn get(self: *Self, comptime T: type, index: usize) *T {
        const offset = self.item_size * index;
        return toPtr(T, self.data[offset .. offset + self.item_size]);
    }

    pub fn push(self: *Self, item: anytype) void {
        const T = @TypeOf(item);
        if (comptime @sizeOf(T) == 0) {
            self.len += 1;
        } else if (comptime @typeInfo(T) == .Pointer) {
            self.pushBytes(std.mem.asBytes(item));
        } else {
            self.pushBytes(std.mem.asBytes(&item));
        }
    }

    pub fn pop(self: *Self, comptime T: type) T {
        var result: T = undefined;
        if (comptime @sizeOf(T) != 0) {
            self.popBytes(std.mem.asBytes(&result));
        } else {
            self.len -= 1;
        }
        return result;
    }

    pub fn replaceRemove(self: *Self, index: usize) void {
        if (index + 1 != self.len) {
            std.mem.copy(u8, self.getBytes(index), self.getBytes(self.len - 1));
        }
        self.len -= 1;
    }

    pub fn swap(self: *Self, index1: usize, index2: usize) void {
        const a = self.getBytes(index1);
        const b = self.getBytes(index2);

        var buffer: [128]u8 = undefined;
        var offset: usize = 0;
        var end = offset + buffer.len;
        var buf: []u8 = buffer[0..];
        while (end < a.len) {
            const sub_a = a[offset..end];
            const sub_b = b[offset..end];
            std.mem.copy(u8, buf, sub_a);
            std.mem.copy(u8, sub_a, sub_b);
            std.mem.copy(u8, sub_b, buf);

            offset += buffer.len;
            end += buffer.len;
        }

        const final_a = a[offset..];
        const final_b = b[offset..];
        buf = buffer[0..final_a.len];
        std.mem.copy(u8, buf, final_a);
        std.mem.copy(u8, final_a, final_b);
        std.mem.copy(u8, final_b, buf);
    }
};

test "UniformBlobs.push" {
    var array = UniformBlobs.init(std.testing.allocator, 32);
    defer array.deinit();

    try array.ensureCapacity(1);

    const item: i32 = 1;
    array.push(item);
    std.testing.expect(array.get(i32, 0).* == 1);
}

test "UniformBlobs.push.ptr" {
    var array = UniformBlobs.init(std.testing.allocator, 32);
    defer array.deinit();

    try array.ensureCapacity(1);

    const item: i32 = 1;
    array.push(&item);
    std.testing.expect(array.pop(i32) == 1);
}

test "UniformBlobs.swap" {
    var array = UniformBlobs.init(std.testing.allocator, 32);
    defer array.deinit();

    try array.ensureCapacity(2);

    const item: i32 = 1;
    const item2: i32 = 2;
    array.push(item);
    array.push(item2);
    array.swap(0, 1);
    std.testing.expect(array.pop(i32) == 1);
}

test "UniformBlobs.items" {
    var array = UniformBlobs.init(std.testing.allocator, @sizeOf(i32));
    defer array.deinit();

    try array.ensureCapacity(2);

    const item: i32 = 1;
    const item2: i32 = 2;
    array.push(item);
    array.push(item2);

    var items = array.items(i32);
    std.testing.expectEqual(@as(usize, 2), items.len);
    std.testing.expect(items[0] == 1);
    std.testing.expect(items[1] == 2);
}

test "UniformBlobs.empty type" {
    var array = UniformBlobs.init(std.testing.allocator, 0);
    defer array.deinit();

    try array.ensureCapacity(2);

    array.push({});
    array.push({});
    array.push({});
    array.pop(void);

    var items = array.items(void);
    std.testing.expectEqual(@as(usize, 2), items.len);
}
