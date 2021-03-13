const std = @import("std");

usingnamespace @import("metatype.zig");
const UniformBlobs = @import("uniform_blobs.zig").UniformBlobs;
const SparseSet = @import("sparse_set.zig").SparseSet;
const Entity = @import("entities.zig").Entity;

pub const ComponentId = usize;
pub const ComponentTableId = usize;

pub const Component = struct {
    type_id: MetaTypeId,
    type_name: []const u8,
    instance_type_id: MetaTypeId,
    instance_name: ?[]const u8,
    deinit: fn (usize) void,
    alignment: usize,
    size: usize,

    pub fn init(comptime T: type, comptime name: ?[]const u8) Component {
        const type_id = uniqueTypeId(T);

        return .{
            .type_id = type_id,
            .type_name = @typeName(T),
            .instance_type_id = if (name) |n| namedTypeId(T, n) else type_id,
            .instance_name = name,
            .deinit = struct {
                fn callback(self: usize) void {
                    if (comptime hasDeclaration(T, "deinit")) {
                        @call(.{ .modifier = .always_inline }, @field(@intToPtr(T, self), "deinit"), .{});
                    }
                }
            }.callback,
            .alignment = @alignOf(T),
            .size = @sizeOf(T),
        };
    }
};

fn compareComponent(context: void, a: Component, b: Component) bool {
    return a.type_id < b.type_id or a.instance_type_id <= b.instance_type_id;
}

fn hasInstanceTypeId(components: []Component, instance_id: u64) bool {
    for (components) |c| {
        if (c.instance_type_id == instance_id)
            return true;
    }
    return false;
}

fn componentDetails(comptime info: std.builtin.TypeInfo, unique_components: []Component) []Component {
    if (info != .Struct)
        @compileError("Expected struct");

    const fields = info.Struct.fields;
    const is_tuple = info.Struct.is_tuple;

    var n: comptime_int = unique_components.len;
    var components: [fields.len + n]Component = undefined;
    std.mem.copy(Component, components[0..n], unique_components);

    var bundles: [fields.len]std.builtin.TypeInfo = undefined;
    var bundle_count = 0;

    for (comptime fields) |field, i| {
        if (hasDeclaration(field.field_type, "BUNDLE")) {
            continue;
        }

        var c = Component.init(field.field_type, if (is_tuple) null else field.name);
        if (!hasInstanceTypeId(components[0..n], c.instance_type_id)) {
            components[n] = c;
            n += 1;
        }
    }

    var result: []Component = components[0..n];

    inline for (comptime fields) |field| {
        if (hasDeclaration(field.field_type, "BUNDLE")) {
            result = componentDetails(@typeInfo(field.field_type), result);
        }
    }

    return result;
}

fn alignTo(alignment: usize, k: usize) usize {
    var n = k % alignment;
    if (n != 0)
        return k + alignment - n;
    return k;
}

pub fn getComponents(comptime T: type) []const Component {
    return comptime blk: {
        var components = componentDetails(@typeInfo(T), &[_]Component{});
        std.sort.sort(Component, components, {}, compareComponent);
        break :blk components;
    };
}

pub fn getComponentList(comptime T: type) ComponentList {
    const result = comptime blk: {
        var components = componentDetails(@typeInfo(T), &[_]Component{});
        std.sort.sort(Component, components, {}, compareComponent);
        break :blk components;
    };

    comptime var offsets: [result.len]usize = undefined;
    comptime var total_size = 0;
    inline for (comptime result) |c, i| {
        total_size = comptime alignTo(c.alignment, total_size);
        offsets[i] = total_size;
        total_size += c.size;
    }
    if (result.len != 0) {
        total_size = comptime alignTo(result[0].alignment, total_size);
    }

    return struct {
        var component_list =
            ComponentList{ .components = result, .offsets = offsets[0..], .total_size = total_size };
    }.component_list;
}

pub const ComponentList = struct {
    components: []const Component,
    offsets: []usize,
    total_size: usize,

    pub fn init(components: []Components, offsets: []usize) void {
        std.sort.sort(Component, components, {}, compareComponent);
        var total_size = 0;
        for (components) |c, i| {
            total_size = comptime alignTo(c.alignment, total_size);
            offsets[i] = total_size;
            total_size += c.size;
        }
        if (result.len != 0) {
            total_size = alignTo(result[0].alignment, total_size);
        }
    }
};

pub const ComponentColumn = struct {
    const Self = @This();
    component_id: ComponentId,
    data: UniformBlobs,
    deinit_fn: fn (usize) void,

    pub fn init(allocator: *std.mem.Allocator, component_id: ComponentId, component: Component) Self {
        return .{
            .component_id = component_id,
            .data = UniformBlobs.init(allocator, component.size),
            .deinit_fn = component.deinit,
        };
    }

    pub fn initCapacity(allocator: *std.mem.Allocator, component_id: ComponentId, component: Component, capacity: usize) !Self {
        var self = Self.init(allocator, component_id, component);
        try self.ensureCapacity(capacity);
        return self;
    }

    pub fn deinit_row(self: *Self, row_index: usize) void {
        self.deinit_fn(@ptrToInt(&self.data.getBytes(row_index).ptr));
    }

    pub fn deinit(self: *Self) void {
        var i: usize = 0;
        while (i < self.data.len) : (i += 1) {
            self.deinit_row(i);
        }
        self.data.deinit();
    }

    pub fn ensureCapacity(self: *Self, new_capacity: usize) !void {
        try self.data.ensureCapacity(new_capacity);
    }

    pub fn setLength(self: *Self, new_length: usize) void {
        std.debug.assert(self.data.capacity >= new_length);
        self.data.len = new_length;
    }

    pub fn items(self: *Self, comptime T: type) []T {
        return self.data.items(T);
    }

    pub fn replaceRemove(self: *Self, row_index: usize) void {
        self.deinit_row(row_index);
        self.data.replaceRemove(row_index);
    }

    pub fn transferCell(self: *Self, row_index: usize, new_column: *Self, new_index: usize) void {
        std.mem.copy(u8, new_column.data.getBytes(new_index), self.data.getBytes(row_index));
        self.data.replaceRemove(row_index);
    }
};

pub const ComponentTableTransferResult = struct {
    replacement_entity: ?Entity,
    new_index: usize,
};

pub const ComponentTable = struct {
    const Self = @This();

    columns: SparseSet(ComponentColumn),
    entities: std.ArrayList(Entity),

    pub fn init(allocator: *std.mem.Allocator) Self {
        return .{
            .columns = SparseSet(ComponentColumn).init(allocator),
            .entities = std.ArrayList(Entity).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.columns.deinit();
        self.entities.deinit();
    }

    pub fn rows(self: *const Self) usize {
        return self.entities.items.len;
    }

    pub fn ensureCapacity(self: *Self, new_capacity: usize) !void {
        try self.entities.ensureCapacity(new_capacity);

        const capacity = self.entities.capacity;
        for (self.columns.items()) |*c| {
            try c.ensureCapacity(capacity);
        }
    }

    pub fn addEntity(self: *Self, new_entity: Entity) !usize {
        try self.entities.append(new_entity);
        const len = self.entities.items.len;
        const capacity = self.entities.capacity;
        for (self.columns.items()) |*c| {
            try c.ensureCapacity(capacity);
            c.setLength(len);
        }

        return len - 1;
    }

    pub fn addColumn(self: *Self, component_id: ComponentId, component: Component) !*ComponentColumn {
        if (self.columns.contains(component_id)) {
            @panic("Component already exists in table.");
        }
        var c = try self.columns.getOrCreate(component_id);

        c.* = try ComponentColumn.initCapacity(self.entities.allocator, component_id, component, self.entities.capacity);
        c.setLength(self.entities.items.len);
        return c;
    }

    pub fn getColumn(self: *Self, component_id: ComponentId) ComponentColumn {
        return self.columns.getOrAssert(component_id);
    }

    pub fn entity(self: *const Self, row_index: usize) Entity {
        return self.entities.items[row_index];
    }

    pub fn column(self: *Self, comptime T: type, component_id: ComponentId) []T {
        return self.columns.getOrAssert(component_id).items(T);
    }

    pub fn replaceRemove(self: *Self, row_index: usize) ?Entity {
        for (self.columns.items()) |*c| {
            c.replaceRemove(row_index);
        }

        _ = self.entities.swapRemove(row_index);
        return if (row_index < self.entities.items.len) self.entities.items[row_index] else null;
    }

    pub fn components(self: *const Self) []const ComponentId {
        return self.columns.indices.items;
    }

    pub fn hasComponent(self: *const Self, component_id: ComponentId) bool {
        return self.columns.contains(component_id);
    }

    pub fn transferRow(self: *Self, row_index: usize, new_table: *Self) !ComponentTableTransferResult {
        const new_index = try new_table.addEntity(self.entities.items[row_index]);

        _ = self.entities.swapRemove(row_index);
        const replacement_entity = if (row_index < self.entities.items.len) self.entities.items[row_index] else null;

        for (self.columns.dense.items) |*old_column| {
            if (new_table.columns.getOpt(old_column.component_id)) |new_column| {
                old_column.transferCell(row_index, new_column, new_index);
            } else {
                old_column.replaceRemove(row_index);
            }
        }

        return ComponentTableTransferResult{ .replacement_entity = replacement_entity, .new_index = new_index };
    }

    pub fn writeColumns(self: *Self, row_index: usize, component_lookup: std.AutoHashMap(MetaTypeId, ComponentId), cells: anytype) void {
        comptime const T = @TypeOf(cells);
        comptime const info = @typeInfo(T);
        if (info != .Struct)
            @compileError("Expected struct not " ++ @typeName(T));

        comptime const fields = info.Struct.fields;
        comptime const is_tuple = info.Struct.is_tuple;

        inline for (comptime fields) |field| {
            if (comptime hasDeclaration(field.field_type, "BUNDLE")) {
                self.writeColumns(row_index, component_lookup, @field(cells, field.name));
            } else {
                const typeId = comptime namedTypeId(field.field_type, if (is_tuple) null else field.name);
                const component_id = component_lookup.get(typeId) orelse unreachable;
                self.column(field.field_type, component_id)[row_index] = @field(cells, field.name);
            }
        }
    }
};

test "ComponentTable.addRow" {
    var table = ComponentTable.init(std.testing.allocator);
    defer table.deinit();

    try table.ensureCapacity(1);
    _ = try table.addColumn(123, Component.init(i32, null));

    const e = Entity{ .generation = 0, .id = 777 };
    const row_index = try table.addEntity(e);

    std.testing.expectEqual(table.entity(row_index).id, 777);
    std.testing.expectEqual(@as(usize, 1), table.column(i32, 123).len);
}

test "ComponentTable.replaceRemove" {
    var table = ComponentTable.init(std.testing.allocator);
    defer table.deinit();

    _ = try table.addColumn(123, Component.init(i32, null));

    try table.ensureCapacity(2);

    const e1 = Entity{ .generation = 0, .id = 777 };
    const e2 = Entity{ .generation = 0, .id = 666 };
    const row_index = try table.addEntity(e1);
    _ = try table.addEntity(e2);
    std.testing.expect(table.replaceRemove(row_index).?.id == e2.id);
}
