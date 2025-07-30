pub fn Tail(Parent: type, Layout: type) type {
    return struct {
        const IsTail = {};
        const tail_field_name = getTailField(Parent).?.name;

        pub fn get(self: *@This(), comptime field: FieldEnum(Layout)) PtrTypeOf(@tagName(field)) {
            const parent: *Parent = @fieldParentPtr(tail_field_name, self);
            const bytes: [*]align(@alignOf(Parent)) u8 = @ptrCast(parent);
            const offset = offsetOf(parent, @tagName(field));
            const size = sizeOf(parent, @tagName(field));

            return @ptrCast(@alignCast(bytes[offset..][0..size]));
        }

        pub fn copy(self: *@This(), comptime field: FieldEnum(Layout), value: []const ElementOf(@tagName(field))) void {
            const dest = self.get(field);

            @memcpy(dest, value);
        }

        pub fn getSize(self: *@This()) usize {
            const parent: *Parent = @fieldParentPtr(tail_field_name, self);
            var size: usize = 0;
            inline for (@typeInfo(Layout).@"struct".fields) |f| {
                size += sizeOf(parent, f.name);
            }
            return size;
        }

        fn PtrTypeOf(field_name: []const u8) type {
            if (isTailSlice(@FieldType(Layout, field_name))) {
                const Element = ElementOf(field_name);
                if (hasTailField(Element)) {
                    return *@FieldType(Layout, field_name);
                } else {
                    return []Element;
                }
            } else {
                return *@FieldType(Layout, field_name);
            }
        }

        fn ElementOf(field_name: []const u8) type {
            const config = @FieldType(Layout, field_name);
            return config.Element;
        }

        fn LenTypeOf(field_name: []const u8) type {
            return @FieldType(Parent, lenFieldOf(field_name));
        }

        fn lenFieldOf(field_name: []const u8) []const u8 {
            const config = @FieldType(Layout, field_name);
            return @tagName(config.len.?);
        }

        fn sizeFieldOf(field_name: []const u8) []const u8 {
            const config = @FieldType(Layout, field_name);
            return @tagName(config.size);
        }

        fn lenOf(parent: *Parent, comptime field_name: []const u8) LenTypeOf(field_name) {
            return @field(parent, lenFieldOf(field_name));
        }

        fn sizeOf(parent: *Parent, comptime field_name: []const u8) usize {
            const T = ElementOf(field_name);
            const len = lenOf(parent, field_name);
            if (comptime hasTailField(T)) {
                // todo refactor..
                const offset = offsetOf(parent, field_name);
                var ptr: *T = @ptrFromInt(@intFromPtr(parent) + offset);

                var size: usize = 0;
                for (0..len) |_| {
                    const n = @sizeOf(T) + @field(ptr, getTailField(T).?.name).getSize();
                    size += n;
                    ptr = @ptrFromInt(@intFromPtr(ptr) + n);
                }
                return size;
            }
            return len * @sizeOf(T);
        }

        fn offsetOf(parent: *Parent, comptime field_name: []const u8) usize {
            var offset: usize = @sizeOf(Parent);
            inline for (@typeInfo(Layout).@"struct".fields) |f| {
                const T = ElementOf(f.name);
                offset = std.mem.alignForward(usize, offset, @alignOf(T));
                if (std.mem.eql(u8, f.name, field_name)) {
                    return offset;
                }
                offset += sizeOf(parent, f.name);
            }
            unreachable;
        }
    };
}

pub fn getTailField(comptime T: type) ?StructField {
    if (@typeInfo(T) != .@"struct") return null;
    var field: ?StructField = null;
    var err: []const u8 = "";
    for (@typeInfo(T).@"struct".fields) |f| {
        if (!isTail(f.type)) continue;
        if (field != null) {
            if (err.len == 0) {
                err = "multiple tail types on " ++ @typeName(T) ++ ", found: ";
            } else {
                err = err ++ ", ";
            }
            err = err ++ f.name;
        }
        field = f;
    }
    if (err.len > 0) @compileError(err);
    return field;
}

pub fn isTail(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "IsTail");
}

pub fn hasTailField(comptime T: type) bool {
    return getTailField(T) != null;
}

pub fn SizedSlice(T: type, len_field: ?@Type(.enum_literal)) type {
    return struct {
        comptime {
            if (hasTailField(T)) {}
        }
        pub const IsTailSlice = {};
        pub const Element = T;
        pub const len = len_field;
    };
}

pub fn UnsizedSlice(T: type, len_field: ?@Type(.enum_literal), size_field: @Type(.enum_literal)) type {
    return struct {
        pub const IsTailSlice = {};
        pub const Element = T;
        pub const len = len_field;
        pub const size = size_field;
    };
}

pub fn isTailSlice(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "IsTailSlice");
}

test {
    const Packet = extern struct {
        host_len: u8 = 0,
        buf_lens: u8 = 0,
        tail: Tail(@This(), struct {
            host: SizedSlice(u8, .host_len),
            read_buf: SizedSlice(u8, .buf_lens),
            write_buf: SizedSlice(u8, .buf_lens),
        }),
    };

    const host = "foobar";

    var buffer: [100]u8 align(@alignOf(Packet)) = undefined;
    buffer[0] = @intCast(host.len);
    buffer[1] = 16;

    const packet: *Packet = @alignCast(@ptrCast(&buffer));
    packet.tail.copy(.host, @ptrCast(host[0..]));

    try std.testing.expectEqualSlices(u8, host[0..], packet.tail.get(.host));
    try std.testing.expectEqual(16, packet.tail.get(.read_buf).len);
    try std.testing.expectEqual(16, packet.tail.get(.write_buf).len);
}

test "nested" {
    const Page = extern struct {
        len: u8,
        tail: Tail(@This(), struct {
            chars: SizedSlice(u8, null),
        }),
    };
    const Database = extern struct {
        page_count: u8,
        page_size: u8,
        tail: Tail(@This(), struct {
            strings: UnsizedSlice(Page, .page_count, .page_size),
        }),
    };

    try std.testing.expect(true);

    const strings = [_][]const u8{
        "small",
        "a bigger string",
        "an even bigger string",
        "someone stop this man before he makes a bigger string",
    };

    var buffer: [100]u8 align(@alignOf(Database)) = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var w = stream.writer();
    try w.writeInt(u8, 4, .little);
    try w.writeInt(u8, strings[0].len, .little);
    try w.writeAll(strings[0]);
    try w.writeInt(u8, strings[1].len, .little);
    try w.writeAll(strings[1]);
    try w.writeInt(u8, strings[2].len, .little);
    try w.writeAll(strings[2]);
    try w.writeInt(u8, strings[3].len, .little);

    const string_list: *Database = @alignCast(@ptrCast(&buffer));

    try std.testing.expectEqual(
        4 + strings[0].len + strings[1].len + strings[2].len + strings[3].len,
        string_list.tail.getSize(),
    );
    // for (0..strings.len) |i| {
    //     try std.testing.expectEqualSlices(
    //         u8,
    //         strings[i],
    //         string_list.tail.get(.strings).get(i).tail.get(.chars),
    //     );
    // }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const FieldEnum = std.meta.FieldEnum;
const StructField = std.builtin.Type.StructField;
