const std = @import("std");

pub const MetaTypeId = u64;

pub fn uniqueTypeId(comptime T: type) MetaTypeId {
    return comptime std.hash.Fnv1a_64.hash(@typeName(T));
}

pub fn namedTypeId(comptime T: type, comptime name: ?[]const u8) MetaTypeId {
    comptime {
        var h = std.hash.Fnv1a_64.init();
        h.update(@typeName(T));
        if (name) |n| {
            h.update(n);
        }
        return h.final();
    }
}

pub fn hasDeclaration(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .Struct, .Enum, .Union => @hasDecl(T, name),
        else => false,
    };
}

pub fn toPtr(comptime T: type, ptr: anytype) *T {
    if (comptime @sizeOf(T) == 0) {
        return @ptrCast(*T, ptr);
    } else {
        return @ptrCast(*T, @alignCast(@alignOf(T), ptr));
    }
}
