const Packet = extern struct {
    host_len: usize,
    tail: Tail,

    const Tail = TailStruct(@This(), struct {
        host: TailSlice(u8, .host_len),
        buf_lens: usize,
        read_buf: TailSlice(u8, .buf_lens),
        write_buf: TailSlice(u8, .buf_lens),
    });
};

test {
    var buffer: [128]u8 align(@alignOf(Packet)) = @splat(0);

    var stream = std.io.fixedBufferStream(&buffer);
    var w = stream.writer();
    try w.writeInt(usize, "hello world".len, native);
    try w.writeAll("hello world");
    try stream.seekBy(5); // alignment
    try w.writeInt(usize, 16, native);

    const packet: *Packet = @ptrCast(@alignCast(&buffer));
    try std.testing.expectEqualSlices(u8, "hello world", packet.tail.get(.host));
    try std.testing.expectEqual(16, packet.tail.get(.read_buf).len);
    try std.testing.expectEqual(16, packet.tail.get(.write_buf).len);
}

pub fn TailStruct(Parent: type, Layout: type) type {
    return struct {
        const IsTail = {};
        const tail_field_name = @tagName(getTailField(Parent) orelse @compileError("'" ++ @typeName(Parent) ++ "' does not have a tail field"));

        pub fn get(self: *@This(), comptime field: FieldEnum(Layout)) []@FieldType(Layout, @tagName(field)).Element {
            const parent: *Parent = @alignCast(@fieldParentPtr(tail_field_name, self));
            const bytes: [*]align(@alignOf(Parent)) u8 = @ptrCast(parent);
            const offset = offsetOf(parent, @tagName(field));
            const size = sizeOf(parent, @tagName(field));

            return @ptrCast(@alignCast(bytes[offset..][0..size]));
        }

        pub fn copy(self: *@This(), comptime field: FieldEnum(Layout), value: []const @FieldType(Layout, @tagName(field)).Element) void {
            const dest = self.get(field);

            @memcpy(dest, value);
        }

        fn LenOf(comptime field_name: []const u8) type {
            const len_field = @tagName(@FieldType(Layout, field_name).len_field);
            return if (comptime @hasField(Parent, len_field))
                @FieldType(Parent, len_field)
            else if (comptime @hasField(Layout, len_field))
                @FieldType(Layout, len_field)
            else
                @compileError("'" ++ len_field ++ "', the length field of '" ++ field_name ++ "', does not exist on either '" ++ @typeName(Parent) ++ "' or the layout struct.");
        }

        fn lenOf(parent: *const Parent, comptime field_name: []const u8) LenOf(field_name) {
            const len_field = @tagName(@FieldType(Layout, field_name).len_field);
            return if (comptime @hasField(Parent, len_field))
                @field(parent, len_field)
            else if (comptime @hasField(Layout, len_field)) blk: {
                const offset = offsetOf(parent, len_field);
                const ptr: *LenOf(field_name) = @ptrFromInt(@intFromPtr(parent) + offset);
                break :blk ptr.*;
            } else @compileError("'" ++ len_field ++ "', the length field of '" ++ field_name ++ "', does not exist on either '" ++ @typeName(Parent) ++ "' or the layout struct.");
        }

        fn sizeOf(parent: *const Parent, comptime field_name: []const u8) usize {
            const Field = @FieldType(Layout, field_name);
            if (comptime isTailSlice(Field)) {
                const len = lenOf(parent, field_name);
                return @sizeOf(Field.Element) * len;
            } else {
                return @sizeOf(Field);
            }
        }

        fn offsetOf(parent: *const Parent, comptime field_name: []const u8) usize {
            var offset: usize = @sizeOf(Parent);
            inline for (@typeInfo(Layout).@"struct".fields) |f| {
                const T = if (comptime isTailSlice(f.type)) f.type.Element else f.type;
                offset = std.mem.alignForward(usize, offset, @alignOf(T));
                if (comptime std.mem.eql(u8, f.name, field_name)) {
                    return offset;
                }
                offset += sizeOf(parent, f.name);
            }
            unreachable;
        }
    };
}

pub fn hasTail(comptime T: type) bool {
    return getTailField(T) != null;
}

pub fn getTail(comptime T: type, val: *T) blk: {
    const field = getTailField() orelse @compileError("'" ++ @typeName(T) ++ "' is not a tail type");
    break :blk *@FieldType(T, @tagName(field));
} {
    return @field(val, @tagName(getTailField(T)).?);
}

pub fn getTailField(comptime T: type) ?FieldEnum(T) {
    var field: ?[]const u8 = null;
    var err: []const u8 = "";
    for (@typeInfo(T).@"struct".fields) |f| {
        if (@typeInfo(f.type) != .@"struct" or !@hasDecl(f.type, "IsTail")) continue;
        if (field != null) {
            if (err.len == 0) {
                err = "multiple tail types on " ++ @typeName(T) ++ ", found: " ++ field.?;
            }
            err = err ++ ", " ++ f.name;
        }
        field = f.name;
    }
    if (err.len > 0) @compileError(err);
    return if (field) |name| @field(FieldEnum(T), name) else null;
}

pub fn TailSlice(T: type, field: @Type(.enum_literal)) type {
    return struct {
        const is_tail_slice = {};

        pub const Element = T;
        pub const len_field = field;
    };
}

pub fn isTailSlice(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasDecl(T, "is_tail_slice");
}

const native = builtin.cpu.arch.endian();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const FieldEnum = std.meta.FieldEnum;
const FieldInfo = std.builtin.Type.FieldInfo;
const builtin = @import("builtin");
