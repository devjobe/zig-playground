const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entity = struct {
    const Self = @This();

    generation: u32,
    id: u32,

    pub fn eql(self: Self, other: Self) bool {
        return std.meta.eql(self, other);
    }
};

pub const EntitySlot = struct {
    generation: u32,
    archetype: u32,
    index: usize,

    pub fn init(generation: u32) EntitySlot {
        return .{ .generation = generation, .archetype = 0, .index = 0 };
    }
};

pub const EntitiesError = error{
    UnknownEntity,
};

pub const Entities = struct {
    const Self = @This();

    slots: []EntitySlot,
    free_list: []u32,
    capacity: usize,
    allocator: *Allocator,

    pub fn init(allocator: *Allocator) Entities {
        return Entities{
            .slots = &[_]EntitySlot{},
            .free_list = &[_]u32{},
            .capacity = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.slots);
        self.allocator.free(self.free_list.ptr[0..self.capacity]);
    }

    pub fn ensureCapacity(self: *Self, new_capacity: usize) !void {
        self.slots = try self.allocator.reallocAtLeast(self.slots, new_capacity);
        const free_index = self.free_list.len;
        self.free_list = try self.allocator.reallocAtLeast(self.free_list.ptr[0..self.capacity], new_capacity);
        self.free_list.len = new_capacity;

        const list = std.ArrayList(u32);

        std.mem.set(EntitySlot, self.slots[self.capacity..], EntitySlot.init(0));

        for (self.free_list[0..free_index]) |*value, i| {
            self.free_list[new_capacity - free_index + i] = value.*;
        }

        var counter = @truncate(u32, new_capacity);
        const new_slots = new_capacity - self.capacity;
        for (self.free_list[0..new_slots]) |*value| {
            counter -= 1;
            value.* = counter;
        }

        self.capacity = new_capacity;
    }

    pub fn alloc(self: *Self) !Entity {
        if (self.free_list.len == 0) {
            try self.ensureCapacity(std.math.max(self.capacity * 2, 1024));
        }

        const next = self.free_list.len - 1;
        const id = self.free_list[next];
        self.free_list.len = next;
        return Entity{ .generation = self.slots[id].generation, .id = id };
    }

    pub fn get(self: *const Self, entity: Entity) EntitiesError!*EntitySlot {
        if (entity.id >= self.capacity) {
            return EntitiesError.UnknownEntity;
        }

        var slot = &self.slots[entity.id];
        if (slot.generation != entity.generation) {
            return EntitiesError.UnknownEntity;
        }
        return slot;
    }

    pub fn free(self: *Self, entity: Entity) EntitiesError!EntitySlot {
        const slot = (try self.get(entity)).*;
        self.slots[entity.id] = EntitySlot.init(slot.generation + 1);
        const index = self.free_list.len;
        self.free_list.len += 1;
        self.free_list.ptr[index] = entity.id;

        return slot;
    }

    pub fn clear(self: *Self) void {
        if (self.capacity > 0) {
            self.free_list.len = self.capacity;
            const offset = self.capacity - 1;
            for (self.free_list) |*value, i| {
                value.* = @truncate(u32, offset - i);
            }
        }
    }

    pub fn count(self: *Self) usize {
        return self.slots.len - self.free_list.len;
    }
};

const expect = std.testing.expect;

test "Entities.alloc" {
    var entities = Entities.init(std.testing.allocator);
    defer entities.deinit();

    const e1 = try entities.alloc();
    expect(e1.generation == 0 and e1.id == 0);
}

test "Entities.ensureCapacity" {
    var entities = Entities.init(std.testing.allocator);
    defer entities.deinit();

    try entities.ensureCapacity(5);
    _ = try entities.alloc();
    _ = try entities.alloc();
    _ = try entities.alloc();
    _ = try entities.alloc();
    const e1 = try entities.alloc();
    expect(entities.capacity == 5);
    _ = try entities.free(e1);
    try entities.ensureCapacity(10);
    const e2 = try entities.alloc();
    expect(!e1.eql(e2) and e1.id == e2.id);
}

test "Entities.get" {
    var entities = Entities.init(std.testing.allocator);
    defer entities.deinit();

    const bogus = Entity{ .generation = 0, .id = 0xff_ffff };
    if (entities.get(bogus)) |_| unreachable else |err| switch (err) {
        error.UnknownEntity => {}, // ok
    }

    const e1 = try entities.alloc();
    _ = try entities.free(e1);

    if (entities.get(e1)) |_| unreachable else |err| switch (err) {
        error.UnknownEntity => {}, // ok
    }
}

test "Entities.free" {
    var entities = Entities.init(std.testing.allocator);
    defer entities.deinit();
    _ = try entities.alloc();
    const e1 = try entities.alloc();
    _ = try entities.free(e1);
    const e2 = try entities.alloc();
    expect(e1.generation != e2.generation and e1.id == e2.id);
    expect(!e1.eql(e2));
}

test "Entities.clear" {
    var entities = Entities.init(std.testing.allocator);
    defer entities.deinit();

    _ = try entities.alloc();
    _ = try entities.alloc();

    entities.clear();
    expect(entities.free_list.len == entities.capacity);
}
