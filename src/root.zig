test {
    const Packet = extern struct {
        host_len: usize,
        tail: Tail(@This(), struct {
            host: TailSlice(u8, .{ .header = .host_len }),
            buf_lens: usize,
            read_buf: TailSlice(u8, .{ .tail = .buf_lens }),
            write_buf: TailSlice(u8, .{ .tail = .buf_lens }),
            butts: TailSlice(u8, .external),
        }),
    };

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

const IsTail = struct {};

pub fn Tail(Parent: type, Layout: type) type {
    return struct {
        const is_tail = IsTail{};

        pub fn get(self: *@This(), comptime field: FieldEnum(Layout)) []@FieldType(Layout, @tagName(field)).Element {
            const parent: *Parent = @alignCast(@fieldParentPtr(getTailFieldName(Parent), self));
            const bytes: [*]align(@alignOf(Parent)) u8 = @ptrCast(parent);
            const offset = offsetOf(parent, @tagName(field));
            const size = sizeOf(parent, @tagName(field));

            return @ptrCast(@alignCast(bytes[offset..][0..size]));
        }

        pub fn copy(self: *@This(), comptime field: FieldEnum(Layout), value: []const @FieldType(Layout, @tagName(field)).Element) void {
            const dest = self.get(field);

            @memcpy(dest, value);
        }

        /// Returns the `LengthLocation`, indicating where the length of the given tail slice is held.
        fn getLenLocation(comptime field_name: []const u8) LengthLocation {
            return @FieldType(Layout, field_name).len;
        }

        /// Returns the integer type used for storing the length of the given tail slice.
        fn LenOf(comptime field_name: []const u8) type {
            return switch (comptime getLenLocation(field_name)) {
                .external => @panic("TODO"),
                .header => |tag| @FieldType(Parent, @tagName(tag)),
                .tail => |tag| @FieldType(Layout, @tagName(tag)),
            };
        }

        /// Returns the length of the given tail slice.
        fn lenOf(parent: *const Parent, comptime field_name: []const u8) LenOf(field_name) {
            return switch (comptime getLenLocation(field_name)) {
                .external => @panic("TODO"),
                .header => |tag| @field(parent, @tagName(tag)),
                .tail => |tag| {
                    const bytes: [*]align(@alignOf(Parent)) const u8 = @ptrCast(parent);
                    const offset = offsetOf(parent, @tagName(tag));
                    const size = @sizeOf(LenOf(field_name));
                    const len: *const LenOf(field_name) = @ptrCast(@alignCast(bytes[offset..][0..size]));
                    return len.*;
                },
            };
        }

        /// Returns the size of the given tail field. For tail slices, calculates the size with the length of the slice.
        fn sizeOf(parent: *const Parent, comptime field_name: []const u8) usize {
            const Field = @FieldType(Layout, field_name);
            if (comptime isTailSlice(Field)) {
                const len = lenOf(parent, field_name);
                return @sizeOf(Field.Element) * len;
            } else {
                return @sizeOf(Field);
            }
        }

        /// Returns the offset of the given tail field.
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

fn isTail(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasDecl(T, "is_tail") and
        @TypeOf(T.is_tail) == IsTail;
}

pub fn hasTail(comptime T: type) bool {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (isTail(f.type)) return true;
    }
}

pub fn getTailFieldName(comptime T: type) []const u8 {
    comptime {
        if (!hasTail(T)) @compileError("'" ++ @typeName(T) ++ "' is not a tail type");
        var field: ?[]const u8 = null;
        var err: []const u8 = "";
        for (@typeInfo(T).@"struct".fields) |f| {
            if (!isTail(f.type)) continue;
            if (field != null) {
                if (err.len == 0) {
                    err = "multiple tail types on " ++ @typeName(T) ++ ", found: " ++ field.?;
                }
                err = err ++ ", " ++ f.name;
            }
            field = f.name;
        }
        if (err.len > 0) @compileError(err);
        return field.?;
    }
}

pub fn getTail(comptime T: type, parent: *T) *TailOf(T) {
    return @field(parent, getTailFieldName(T));
}

pub fn TailOf(comptime T: type) type {
    return @FieldType(T, getTailFieldName(T));
}

const IsTailSlice = struct {};

pub fn TailSlice(comptime T: type, comptime length_location: LengthLocation) type {
    return struct {
        const is_tail_slice = IsTailSlice{};

        pub const Element = T;
        pub const len = length_location;
    };
}

pub const LengthLocation = union(enum) {
    external: void,
    header: @Type(.enum_literal),
    tail: @Type(.enum_literal),
};

pub fn isTailSlice(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasDecl(T, "is_tail_slice") and
        @TypeOf(T.is_tail_slice) == IsTailSlice;
}

const native = builtin.cpu.arch.endian();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const FieldEnum = std.meta.FieldEnum;
const FieldInfo = std.builtin.Type.FieldInfo;
const builtin = @import("builtin");
