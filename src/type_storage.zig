const std = @import("std");

usingnamespace @import("metatype.zig");

pub const TypeStorage = struct {
    const Self = @This();
    const Map = std.AutoHashMap(MetaTypeId, []u8);
    const Size = Map.Size;

    map: Map,

    pub fn init(allocator: *std.mem.Allocator) Self {
        return .{
            .map = Map.init(allocator),
        };
    }

    fn deallocValues(self: *Self) void {
        var iter = self.map.iterator();
        while (iter.next()) |kv| {
            self.map.allocator.free(kv.value);
        }
    }

    pub fn deinit(self: *Self) void {
        self.deallocValues();
        self.map.deinit();
    }

    pub fn clearRetainingCapacity(self: *Self) void {
        self.deallocValues();
        return self.map.clearRetainingCapacity();
    }

    pub fn clearAndFree(self: *Self) void {
        self.deallocValues();
        return self.map.clearAndFree();
    }

    pub fn count(self: Self) Size {
        return self.map.count();
    }

    pub fn get(self: *Self, comptime T: type) *T {
        if (self.map.get(uniqueTypeId(T))) |data| {
            return toPtr(T, data);
        }
        unreachable;
    }

    pub fn getOpt(self: *Self, comptime T: type) ?*T {
        if (self.map.get(uniqueTypeId(T))) |data| {
            return toPtr(T, data);
        }
        return null;
    }

    pub fn getOrPutZeroed(self: *Self, comptime T: type) *T {
        const result = self.map.getOrPut(uniqueTypeId(T)) catch unreachable;
        if (!result.found_existing) {
            var data = self.map.allocator.create(T) catch unreachable;
            if (@typeInfo(T) == .Struct) {
                data.* = std.mem.zeroInit(T, T);
            } else {
                data.* = std.mem.zeroes(T);
            }
            result.entry.value = std.mem.asBytes(data);
        }
        return toPtr(T, result.entry.value);
    }

    pub fn getOrPut(self: *Self, value: anytype) *@TypeOf(value) {
        const T = @TypeOf(value);

        const result = self.map.getOrPut(uniqueTypeId(T)) catch unreachable;
        if (!result.found_existing) {
            var data = self.map.allocator.create(T) catch unreachable;
            data.* = value;
            result.entry.value = std.mem.asBytes(data);
        }
        return toPtr(T, result.entry.value);
    }

    pub fn put(self: *Self, value: anytype) *@TypeOf(value) {
        const T = @TypeOf(value);

        const result = self.map.getOrPut(uniqueTypeId(T)) catch unreachable;
        if (!result.found_existing) {
            const data = self.map.allocator.create(T) catch unreachable;
            data.* = value;
            result.entry.value = std.mem.asBytes(data);
            return data;
        } else {
            const ptr = toPtr(T, result.entry.value);
            ptr.* = value;
            return ptr;
        }
    }

    pub fn contains(self: Self, comptime T: type) bool {
        return self.map.contains(uniqueTypeId(T));
    }

    pub fn ensureCapacity(self: *Self, expected_count: Size) !void {
        return self.map.ensureCapacity(expected_count);
    }

    pub fn capacity(self: *Self) Size {
        return self.map.capacity();
    }

    pub fn discard(self: *Self, comptime T: type) void {
        if (self.map.remove(uniqueTypeId(T))) |entry| {
            const ptr = toPtr(T, entry.value);
            self.map.allocator.destroy(ptr);
        }
    }

    pub fn remove(self: *Self, comptime T: type) ?T {
        if (self.map.remove(uniqueTypeId(T))) |entry| {
            const ptr = toPtr(T, entry.value);
            defer self.map.allocator.destroy(ptr);
            return ptr.*;
        }
        return null;
    }

    pub fn clone(self: Self) Self {
        var other = Self{ .map = self.map.clone() catch unreachable };

        var iter = other.map.iterator();
        while (iter.next()) |kv| {
            kv.value = other.map.allocator.dupe(u8, kv.value) catch unreachable;
        }
        return other;
    }
};

test "TypeStorage.getOrPutZeroed" {
    var map = TypeStorage.init(std.testing.allocator);
    defer map.deinit();
    map.getOrPutZeroed(i32).* = 5;
    std.testing.expectEqual(map.get(i32).*, 5);
    std.testing.expect(map.contains(i32));
}

test "TypeStorage.getOrPut" {
    var map = TypeStorage.init(std.testing.allocator);
    defer map.deinit();
    _ = map.getOrPut(@as(i32, 5));
    std.testing.expectEqual(map.get(i32).*, 5);
}

test "TypeStorage.put" {
    var map = TypeStorage.init(std.testing.allocator);
    defer map.deinit();
    _ = map.put(@as(i32, 5));
    std.testing.expectEqual(map.get(i32).*, 5);
}

test "TypeStorage.discard" {
    var map = TypeStorage.init(std.testing.allocator);
    defer map.deinit();

    const A = struct {};

    const ptr = map.put(A{});
    map.discard(A);
    std.testing.expect(map.contains(A) == false);
}

test "TypeStorage.remove" {
    var map = TypeStorage.init(std.testing.allocator);
    defer map.deinit();
    _ = map.put(@as(i32, 5));
    std.testing.expect(map.remove(i32).? == 5);
}

test "TypeStorage.clone" {
    var map = TypeStorage.init(std.testing.allocator);
    defer map.deinit();
    const a = map.put(@as(i32, 1));

    var other = map.clone();
    defer other.deinit();
    const b = other.get(i32);

    std.testing.expectEqual(b.*, 1);
    b.* = 2;
    std.testing.expectEqual(a.*, 1);
}
