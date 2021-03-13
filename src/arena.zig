const std = @import("std");

fn isUnsignedInt(comptime T: type) bool {
    comptime const info = @typeInfo(T);

    return info == .Int and info.Int.signedness == .unsigned;
}

/// Design choices:
/// Reuses memory before touching previously unused memory.
/// Handle == 0 is always invalid. That is when an entry is allocated it gets version 1.
/// Iterable and supports const.
pub fn GenericArena(comptime ItemType: type, comptime VersionType: type, comptime IndexType: type, DEFAULT_CAPACITY: comptime_int) type {
    comptime {
        if (@bitSizeOf(IndexType) >= @bitSizeOf(usize))
            @compileError("Expected IndexType to be usize or less.");
        if (!isUnsignedInt(IndexType))
            @compileError("Expected IndexType to be unsigned integer.");
        if (!isUnsignedInt(VersionType))
            @compileError("Expected VersionType to be unsigned integer.");
    }

    return struct {
        const Self = @This();

        fn intoHandle(v: VersionType, i: usize) Handle {
            return (@intCast(Handle, v) << @bitSizeOf(IndexType)) | @truncate(IndexType, i);
        }

        fn id(handle: Handle) usize {
            return @truncate(IndexType, handle);
        }

        fn version(handle: Handle) VersionType {
            return @truncate(VersionType, handle >> @bitSizeOf(IndexType));
        }

        /// Zero handle is always invalid, others may be invalid.
        pub const Handle = std.meta.Int(.unsigned, @bitSizeOf(VersionType) + @bitSizeOf(IndexType));

        pub const Entry = struct {
            handle: Handle,
            value: ItemType,

            fn create(self: *Entry, index: usize) void {
                self.handle = intoHandle(1, index);
            }

            fn free(self: *Entry, next_free: usize) void {
                self.handle = intoHandle(version(self.handle) + 1, next_free);
            }

            fn unfree(self: *Entry, index: usize) usize {
                const next_free = id(self.handle);
                self.handle = intoHandle(version(self.handle), index);
                return next_free;
            }
        };

        items: []Entry = &[_]Entry{},
        allocated: usize = 0,
        free_count: usize = 0,
        free_index: usize = 0,
        allocator: *std.mem.Allocator,

        pub fn init(allocator: *std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
            self.* = undefined;
        }

        pub fn ensureCapacity(self: *Self, new_capacity: usize) !void {
            if (self.items.len >= new_capacity)
                return;
            self.items = try self.allocator.realloc(self.items, new_capacity);
        }

        pub fn capacity(self: *const Self) usize {
            return self.items.len;
        }

        pub fn count(self: *const Self) usize {
            return self.allocated - self.free_count;
        }

        pub fn remove(self: *Self, handle: Handle) void {
            const index = id(handle);
            if (index >= self.allocated)
                return;

            var item = &self.items[index];
            if (item.handle != handle)
                return;

            item.free(self.free_index);
            self.free_index = index;
            self.free_count += 1;
        }

        pub fn remove_all(self: *Self) void {
            if (self.allocated > 0) {
                for (self.items[0..self.allocated]) |*item, i| {
                    item.free(@truncate(IndexType, i + 1));
                }
                self.free_index = 0;
                self.free_count = self.allocated;
            }
        }

        pub fn reset(self: *Self) void {
            self.allocated = 0;
            self.free_count = 0;
        }

        pub fn create(self: *Self) !*Entry {
            if (self.free_count > 0) {
                self.free_count -= 1;
                const index = self.free_index;
                var item = &self.items[index];
                self.free_index = item.unfree(index);
                return item;
            } else {
                const index = self.allocated;
                if (self.items.len <= index)
                    try self.ensureCapacity(std.math.max(comptime std.math.max(DEFAULT_CAPACITY, 1), self.items.len * 2));
                self.allocated += 1;

                var item = &self.items[index];
                item.create(index);
                return item;
            }
        }

        pub fn insert(self: *Self, value: ItemType) !Handle {
            var item = try self.create();
            item.value = value;
            return item.handle;
        }

        pub fn ref(self: *Self, handle: Handle) ?*ItemType {
            const index = id(handle);
            if (index < self.allocated) {
                var item = &self.items[index];
                return if (item.handle == handle) &item.value else null;
            } else {
                return null;
            }
        }

        pub fn get(self: *const Self, handle: Handle) ?*const ItemType {
            const index = id(handle);
            if (index < self.allocated) {
                var item = &self.items[index];
                return if (item.handle == handle) &item.value else null;
            } else {
                return null;
            }
        }

        pub fn contains(self: *const Self, handle: Handle) bool {
            const index = id(handle);
            return index < self.allocated and self.items[index].handle == handle;
        }

        const Iterator = struct {
            items: []Entry,
            index: IndexType,

            pub fn next(self: *Iterator) ?*Entry {
                while (self.index < self.items.len) {
                    const index = self.index;
                    self.index += 1;

                    const item = &self.items.ptr[index];
                    if (item.handle != 0 and id(item.handle) == index) {
                        return item;
                    }
                }
                return null;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return Iterator{ .items = self.items[0..self.allocated], .index = 0 };
        }

        const ConstIterator = struct {
            items: []const Entry,
            index: IndexType,

            pub fn next(self: *ConstIterator) ?*const Entry {
                while (self.index < self.items.len) {
                    const index = self.index;
                    self.index += 1;

                    const item = &self.items.ptr[index];
                    if (item.handle != 0 and id(item.handle) == index) {
                        return item;
                    }
                }
                return null;
            }
        };

        pub fn iteratorConst(self: *const Self) ConstIterator {
            return Iterator{ .items = self.items[0..self.allocated], .index = 0 };
        }
    };
}

/// 64 bit handle, 4 million maximum entries, 4096 default capacity
pub fn Arena(comptime ItemType: type) type {
    return GenericArena(ItemType, u32, u32, 4096);
}

test "Arena usage" {
    const expect = std.testing.expect;
    var arena = Arena(i32).init(std.testing.allocator);
    defer arena.deinit();

    const h1 = try arena.insert(1);
    expect(arena.contains(h1));

    arena.ref(h1).?.* = 2;
    expect(arena.get(h1).?.* == 2);
    arena.remove(h1);
    expect(!arena.contains(h1));
    expect(arena.get(h1) == null);
    expect(arena.count() == 0);
    arena.reset();

    const h2 = try arena.insert(2);
    expect(arena.contains(h2));
    expect(arena.get(h2).?.* == 2);
    arena.remove_all();
    expect(!arena.contains(h1));
    expect(arena.get(h2) == null);

    const h3 = try arena.insert(3);
    const h4 = try arena.insert(4);

    var iter = arena.iterator();
    std.testing.expectEqual(iter.next().?.value, 3);
    std.testing.expectEqual(iter.next().?.value, 4);
    expect(iter.next() == null);
}
