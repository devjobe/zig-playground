const std = @import("std");

usingnamespace @import("entities.zig");
usingnamespace @import("component.zig");
usingnamespace @import("metatype.zig");

fn excludeComponentsInPlace(components: []ComponentId, exclude: []const ComponentId) []ComponentId {
    var i: usize = 0;
    var len = components.len;
    while (i < len) {
        if (std.mem.indexOfScalar(ComponentId, exclude, components[i]) != null) {
            if (i + 1 < components.len) {
                std.mem.swap(ComponentId, &components[i], &components[len - 1]);
            }
            len -= 1;
        } else {
            i += 1;
        }
    }
    return components[0..len];
}

const WorldEntityRef = struct {
    const Self = @This();

    world: *World,
    id: Entity,
    slot: EntitySlot,

    pub fn archetype(self: *Self) *Archetype {
        return &self.world.archetypes.items[self.slot.archetype];
    }

    pub fn table(self: *Self) *ComponentTable {
        return &self.world.tables.items[self.archetype().table_id];
    }

    pub fn contains(self: *Self, comptime T: type, comptime name: ?[]const u8) bool {
        return self.table().hasComponent(self.world.getComponentId(comptime Component.init(T, name)));
    }

    pub fn insertBundle(self: *Self, bundle: anytype) void {
        const new_archetype = self.world.addBundleToArchetype(@TypeOf(bundle), self.slot.archetype);

        if (new_archetype != self.slot.archetype) {
            self.slot = self.world.transferEntity(self.id, new_archetype);
        }

        self.table().writeColumns(self.slot.index, self.world.component_map, bundle);
    }

    pub fn insert(self: *Self, comptime T: type, value: T) void {
        self.insertBundle(.{value});
    }

    pub fn component(self: *Self, comptime T: type, comptime name: ?[]const u8) *T {
        const component_id = self.world.getComponentId(comptime Component.init(T, name));
        return &self.table().column(T, component_id)[self.slot.index];
    }
};

const ArchetypeId = u32;

const ArchetypeEdges = struct {
    const Self = @This();
    const Map = std.AutoHashMap(MetaTypeId, ArchetypeId);

    added: Map,

    pub fn init(allocator: *std.mem.Allocator) Self {
        return .{ .added = Map.init(allocator) };
    }

    pub fn deinit(self: *Self) void {
        self.added.deinit();
    }
};

const Archetype = struct {
    const Self = @This();

    table_id: ComponentTableId,
    edges: ArchetypeEdges,

    pub fn init(allocator: *std.mem.Allocator, table_id: ComponentTableId) Self {
        return .{ .table_id = table_id, .edges = ArchetypeEdges.init(allocator) };
    }

    pub fn deinit(self: *Self) void {
        self.edges.deinit();
    }
};

const World = struct {
    const Self = @This();

    entities: Entities,
    tables: std.ArrayList(ComponentTable),
    components: std.ArrayList(Component),
    component_map: std.AutoHashMap(MetaTypeId, ComponentId),
    archetypes: std.ArrayList(Archetype),
    archetypes_lookup: std.AutoHashMap(u64, ArchetypeId),
    allocator: *std.mem.Allocator,

    pub fn initCapacity(allocator: *std.mem.Allocator, entity_capacity: u32, table_capacity: u32, components_capacity: u32) !Self {
        var self = Self{ .entities = Entities.init(allocator), .tables = std.ArrayList(ComponentTable).init(allocator), .components = std.ArrayList(Component).init(allocator), .component_map = std.AutoHashMap(MetaTypeId, ComponentId).init(allocator), .archetypes = std.ArrayList(Archetype).init(allocator), .archetypes_lookup = std.AutoHashMap(u64, ArchetypeId).init(allocator), .allocator = allocator };

        try self.entities.ensureCapacity(entity_capacity);
        try self.tables.ensureCapacity(table_capacity);
        try self.tables.append(ComponentTable.init(allocator));
        try self.components.ensureCapacity(components_capacity);
        try self.component_map.ensureCapacity(components_capacity);
        try self.archetypes.ensureCapacity(table_capacity);
        try self.archetypes.append(Archetype.init(allocator, 0));
        try self.archetypes_lookup.ensureCapacity(table_capacity);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.entities.deinit();
        for (self.tables.items) |*item| {
            item.deinit();
        }
        self.tables.deinit();
        self.components.deinit();
        self.component_map.deinit();
        for (self.archetypes.items) |*item| {
            item.deinit();
        }
        self.archetypes.deinit();
        self.archetypes_lookup.deinit();
    }

    pub fn spawn(self: *Self) !WorldEntityRef {
        var empty_table = &self.tables.items[0];

        const entity = try self.entities.alloc();
        var slot = self.entities.get(entity) catch unreachable;
        slot.index = try empty_table.addEntity(entity);
        return WorldEntityRef{ .world = self, .id = entity, .slot = slot.* };
    }

    pub fn despawn(self: *Self, entity: Entity) void {
        const slot = self.entities.free(entity) catch unreachable;

        var table = &self.tables.items[slot.archetype];

        if (table.replaceRemove(slot.index)) |replacement| {
            var replacement_slot = self.entities.get(replacement) catch unreachable;
            replacement_slot.index = slot.index;
        }
    }

    pub fn getComponentId(self: *Self, component: Component) ComponentId {
        var result = self.component_map.getOrPut(component.instance_type_id) catch unreachable;
        if (!result.found_existing) {
            result.entry.value = self.components.items.len;
            self.components.append(component) catch unreachable;
        }
        return result.entry.value;
    }

    pub fn getComponentIdList(self: *Self, comptime components: []const Component) [components.len]ComponentId {
        var res: [components.len]ComponentId = undefined;
        inline for (comptime components) |c, i| {
            res[i] = self.getComponentId(c);
        }
        return res;
    }

    fn getOrCreateArchetype(self: *Self, components: []const ComponentId) ArchetypeId {
        var result = self.archetypes_lookup.getOrPut(std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(components)[0..])) catch unreachable;
        if (result.found_existing) {
            return result.entry.value;
        }

        result.entry.value = @intCast(ArchetypeId, self.archetypes.items.len);

        self.archetypes.append(Archetype.init(self.allocator, self.tables.items.len)) catch unreachable;
        self.tables.append(ComponentTable.init(self.allocator)) catch unreachable;

        var table = &self.tables.items[self.tables.items.len - 1];

        table.ensureCapacity(64) catch unreachable;
        for (components) |component_id| {
            _ = table.addColumn(component_id, self.components.items[component_id]) catch unreachable;
        }

        return result.entry.value;
    }

    pub fn addBundleToArchetype(self: *Self, comptime T: type, archetype_id: ArchetypeId) ArchetypeId {
        var archetype = &self.archetypes.items[archetype_id];
        comptime const bundle_id = uniqueTypeId(T);

        var archetype_entry = archetype.edges.added.getOrPut(uniqueTypeId(T)) catch unreachable;

        if (archetype_entry.found_existing) {
            return archetype_entry.entry.value;
        }

        const table = &self.tables.items[archetype.table_id];

        var components = self.getComponentIdList(comptime getComponents(T));
        var new_components = excludeComponentsInPlace(components[0..], table.components());

        if (new_components.len == 0) {
            archetype_entry.entry.value = archetype_id;
            return archetype_id;
        }

        std.sort.sort(ComponentId, new_components, {}, comptime std.sort.asc(ComponentId));

        var sorted_components = std.mem.concat(self.allocator, ComponentId, ([_][]const ComponentId{
            table.components(), new_components,
        })[0..]) catch unreachable;
        defer self.allocator.free(sorted_components);
        std.sort.sort(ComponentId, sorted_components, {}, comptime std.sort.asc(ComponentId));

        const new_archetype_id = self.getOrCreateArchetype(sorted_components);

        archetype_entry.entry.value = new_archetype_id;
        return new_archetype_id;
    }

    pub fn transferEntity(self: *Self, entity: Entity, new_archetype_id: ArchetypeId) EntitySlot {
        var slot = self.entities.get(entity) catch unreachable;

        var archetype = &self.archetypes.items[slot.archetype];
        var table = self.tables.items[archetype.table_id];

        var new_archetype = &self.archetypes.items[new_archetype_id];
        var new_table = &self.tables.items[new_archetype.table_id];

        const result = table.transferRow(slot.index, new_table) catch unreachable;

        if (result.replacement_entity) |replacement| {
            (self.entities.get(replacement) catch unreachable).index = slot.index;
        }

        slot.archetype = new_archetype_id;
        slot.index = result.new_index;

        return slot.*;
    }
};

test "World.spawnEntities" {
    var world = try World.initCapacity(std.testing.allocator, 32, 16, 256);
    defer world.deinit();

    var ref = try world.spawn();
    world.despawn(ref.id);

    std.testing.expect(ref.contains(i32, null) == false);
    std.testing.expect(world.entities.count() == 0);
}

test "World.getComponentId" {
    var world = try World.initCapacity(std.testing.allocator, 32, 16, 256);
    defer world.deinit();

    const a = Component.init(i32, null);
    const b = Component.init(i32, "x");
    std.testing.expect(world.getComponentId(a) == 0);
    std.testing.expect(world.getComponentId(b) == 1);
    std.testing.expect(world.getComponentId(a) == 0);
}

test "World.getComponentIdList" {
    var world = try World.initCapacity(std.testing.allocator, 32, 16, 256);
    defer world.deinit();

    const A = struct {
        const BUNDLE: void;
        a: i32,
        b: i32
    };
    const components = world.getComponentIdList(comptime getComponents(A));

    std.testing.expect(components.len == 2);
}

test "World.archetypesReused" {
    var world = try World.initCapacity(std.testing.allocator, 32, 16, 256);
    defer world.deinit();

    var ref = try world.spawn();

    ref.insert(i32, 5);
    ref.insertBundle(.{@as(f32, 1.0)});

    std.testing.expectEqual(ref.component(i32, null).*, 5);

    const num_archetypes = world.archetypes.items.len;

    var ref2 = try world.spawn();
    ref2.insert(i32, 5);
    ref2.insertBundle(.{ @as(f32, 1.0), @as(i32, 5) });

    std.testing.expectEqual(num_archetypes, world.archetypes.items.len);
}
