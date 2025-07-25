const std = @import("std");
const BackwardsBuffer = @import("./backwards_buffer.zig").BackwardsBuffer;
const types = @import("./types.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;
const Offset = types.Offset;
const VOffset = types.VOffset;
const log = types.log;

/// Flatbuffer builder. Written bottom to top. Includes header, tables, vtables, and strings.
pub const Builder = struct {
    const VTable = std.ArrayList(VOffset);
    const VTables = std.StringHashMap(Offset);

    buffer: BackwardsBuffer,
    vtable: VTable,
    vtables: VTables,
    table_start: Offset = 0,
    min_alignment: usize = @sizeOf(Offset),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .buffer = BackwardsBuffer.init(allocator),
            .vtable = VTable.init(allocator),
            .vtables = VTables.init(allocator),
        };
    }

    fn deinitAdvanced(self: *Self, comptime deinit_buffer: bool) void {
        self.vtable.deinit();
        var iter = self.vtables.keyIterator();
        while (iter.next()) |k| self.buffer.allocator.free(k.*);
        self.vtables.deinit();
        if (deinit_buffer) self.buffer.deinit();
    }

    pub fn deinit(self: *Self) void {
        self.deinitAdvanced(true);
    }

    pub fn offset(self: Self) Offset {
        return @intCast(self.buffer.data.len);
    }

    fn prepAdvanced(self: *Self, size: usize, n_bytes_after: usize) !void {
        if (size > self.min_alignment) self.min_alignment = size;

        const buf_size: i64 = @intCast(self.buffer.data.len + n_bytes_after);
        const sizei: i64 = @intCast(size);
        const align_size: usize = @intCast((~buf_size + 1) & (sizei - 1));
        try self.buffer.fill(align_size, 0);
    }

    fn prep(self: *Self, comptime T: type, n_bytes_after: usize) !void {
        const size = @sizeOf(T);
        try self.prepAdvanced(size, n_bytes_after);
    }

    pub fn prepend(self: *Self, value: anytype) !void {
        const T = @TypeOf(value);
        if (T == void) return;
        try self.prep(T, 0);
        try self.buffer.prepend(value);
    }

    pub fn prependSlice(self: *Self, comptime T: type, slice: []const T) !void {
        try self.prep(T, 0);
        try self.buffer.prependSlice(std.mem.sliceAsBytes(slice));
    }

    pub fn prependVector(self: *Self, comptime T: type, slice: []const T) !Offset {
        if (slice.len == 0) return 0;
        const n_bytes = @sizeOf(T) * slice.len;
        try self.prep(Offset, n_bytes);
        try self.prep(T, n_bytes);
        try self.buffer.prependSlice(std.mem.sliceAsBytes(slice));
        const len: Offset = @intCast(slice.len);
        try self.buffer.prepend(len);
        return self.offset();
    }

    pub fn prependOffset(self: *Self, offset_: Offset) !void {
        try self.prep(Offset, 0);
        try self.buffer.prepend(self.offset() - offset_ + @sizeOf(Offset));
    }

    pub fn prependOffsets(self: *Self, offsets: []Offset) !Offset {
        if (offsets.len == 0) return 0;
        const n_bytes = @sizeOf(u32) * offsets.len;
        try self.prep(Offset, n_bytes);
        // These have to be relative to themselves.
        for (0..offsets.len) |i| {
            const index = offsets.len - i - 1;
            try self.buffer.prepend(self.offset() - offsets[index] + @sizeOf(Offset));
        }
        const len: Offset = @intCast(offsets.len);
        try self.buffer.prepend(len);
        return self.offset();
    }

    pub fn prependVectorOffsets(self: *Self, comptime T: type, packable: []T) !Offset {
        if (packable.len == 0) return 0;
        const allocator = self.buffer.allocator;
        var offsets = try allocator.alloc(u32, packable.len);
        defer allocator.free(offsets);
        for (packable, 0..) |p, i| offsets[i] = if (T == [:0]const u8)
            try self.prependString(p)
        else
            try p.pack(self);
        return self.prependOffsets(offsets);
    }

    pub fn prependString(self: *Self, string: ?[]const u8) !Offset {
        if (string) |str| {
            if (str.len == 0) return 0;
            try self.prep(Offset, str.len + 1);
            try self.buffer.prepend(@as(u8, 0));
            try self.buffer.prependSlice(str);
            const len: Offset = @intCast(str.len);
            try self.buffer.prepend(len);
            return self.offset();
        }
        return 0;
    }

    pub fn startTable(self: *Self) !void {
        try self.vtable.resize(0);
        self.table_start = self.offset();
    }

    pub fn appendTableField(self: *Self, comptime T: type, value: T) !void {
        if (@typeInfo(T) == .optional and value == null) {
            try self.vtable.append(@as(VOffset, 0));
        } else {
            try self.prepend(value);
            const voffset: VOffset = @intCast(self.offset());
            try self.vtable.append(voffset);
        }
    }

    pub fn appendTableFieldWithDefault(self: *Self, comptime T: type, value: T, default: T) !void {
        if (value == default) {
            try self.vtable.append(@as(VOffset, 0));
        } else {
            try self.appendTableField(T, value);
        }
    }

    pub fn appendTableFieldOffset(self: *Self, offset_: Offset) !void {
        if (offset_ == 0) { // Default or null.
            try self.vtable.append(@as(VOffset, 0));
        } else {
            try self.prep(Offset, 0); // The offset we write needs to include padding
            try self.prepend(self.offset() - offset_ + @sizeOf(Offset));
            const voffset: VOffset = @intCast(self.offset());
            try self.vtable.append(voffset);
        }
    }

    fn writeVTable(self: *Self) !Offset {
        const n_items = brk: {
            // Starting from end look for non-0 VOffset
            const len = self.vtable.items.len;
            for (0..len) |i| {
                const index = len - i - 1;
                if (self.vtable.items[index] != 0) break :brk index + 1;
            }
            break :brk 0;
        };

        const vtable_len: VOffset = @intCast((n_items + 2) * @sizeOf(VOffset));

        try self.prepend(@as(Offset, vtable_len)); // offset to start of vtable
        const vtable_start = self.offset();
        for (0..n_items) |i| {
            const offset_ = self.vtable.items[n_items - i - 1];
            if (offset_ == 0) {
                try self.prepend(offset_);
            } else {
                const voffset: VOffset = @intCast(vtable_start - offset_);
                try self.prepend(voffset);
            }
        }
        const table_len: VOffset = @intCast(vtable_start - self.table_start);
        try self.prepend(table_len);
        try self.prepend(vtable_len);

        const vtable_bytes = self.buffer.data[0..vtable_len];
        if (self.vtables.get(vtable_bytes)) |o| {
            self.buffer.data = self.buffer.data[vtable_len + @sizeOf(Offset) ..];
            const neg_offset: i32 = @as(i32, @bitCast(o)) + vtable_len - // original offset
                @sizeOf(i32) - @as(i32, @bitCast(self.offset()));
            try self.prepend(neg_offset);

            return vtable_start;
        }
        const owned_bytes = try self.buffer.allocator.dupe(u8, vtable_bytes);
        try self.vtables.put(owned_bytes, vtable_start);

        return vtable_start;
    }

    pub fn endTable(self: *Self) !Offset {
        return try self.writeVTable();
    }

    pub fn finish(self: *Self, root: Offset) ![]u8 {
        try self.prepAdvanced(self.min_alignment, @sizeOf(Offset));
        try self.prependOffset(root);

        self.deinitAdvanced(false);
        return try self.buffer.toOwnedSlice();
    }
};

test "prepend scalars" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();

    try builder.prepend(true);
    try builder.prepend(@as(i8, 8));
    try builder.prepend(@as(u8, 9));
    try testing.expectEqualSlices(u8, &.{ 9, 8, 1 }, builder.buffer.data);
    try builder.prepend(@as(i16, 0x1234)); // Gotta add padding.
    try testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0, 9, 8, 1 }, builder.buffer.data);
}

test "prepend slice" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();

    const T = i16;
    const slice = &[_]T{ 9, 8, 1 };
    try builder.prependSlice(T, slice);
    const actual: []T = @alignCast(std.mem.bytesAsSlice(T, builder.buffer.data));
    try testing.expectEqualSlices(T, slice, actual);
}

test "prepend vector" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();

    const T = u32;
    const slice = &[_]T{ 9, 8, 1 };
    _ = try builder.prependVector(T, slice);
    const actual: []T = @alignCast(std.mem.bytesAsSlice(T, builder.buffer.data));
    try testing.expectEqualSlices(T, [_]Offset{slice.len} ++ slice, actual);
}

test "prepend vector padding" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();

    const T = u8;
    const slice = &[_]T{ 8, 1 };
    _ = try builder.prependVector(T, slice);
    try testing.expectEqualSlices(T, std.mem.toBytes(@as(Offset, slice.len)) ++ slice ++ [_]u8{ 0, 0 }, builder.buffer.data);
}

test "prepend string" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();

    const string = "asd";
    const len = std.mem.toBytes(@as(Offset, string.len));
    _ = try builder.prependString(string);
    const expected = len ++ string ++ &[_]u8{0};
    try testing.expectEqualSlices(u8, expected, builder.buffer.data);

    const string2 = "hjkl";
    const len2 = std.mem.toBytes(@as(Offset, string2.len));
    _ = try builder.prependString(string2);
    const expected2 = len2 ++ string2 ++ &[_]u8{0};
    try testing.expectEqualSlices(u8, expected2 ++ &[_]u8{0} ** 3 ++ expected, builder.buffer.data);
}

test "prepend object with single field" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();

    try builder.startTable();
    try builder.appendTableField(bool, true); // field 0
    _ = try builder.endTable();
    try testing.expectEqualSlices(u8, &[_]u8{
        6, 0, // vtable len
        8, 0, // table len
        7, 0, // offset to field 0 offset from vtable start
        // vtable start
        6, 0, 0, 0, // negative offset to  start of vtable from here
        0, 0, 0, // padded to 4 bytes
        1, // field 0
        // table start
    }, builder.buffer.data);
}

test "prepend object with single default field" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();

    try builder.startTable();
    // If it's the default, just don't append it.
    // try builder.appendTableField(bool, false);
    _ = try builder.endTable();
    try testing.expectEqualSlices(u8, &[_]u8{
        4, 0, // vtable len
        4, 0, // table len
        // vtable start
        4, 0, 0, 0, // negative offset to  start of vtable from here
        // table start
    }, builder.buffer.data);
}

test "prepend object with 2 fields" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();

    try builder.startTable();
    try builder.appendTableField(i16, 0x3456); // field 0
    try builder.appendTableField(i16, 0x789A); // field 1
    _ = try builder.endTable();
    try testing.expectEqualSlices(u8, &[_]u8{
        8, 0, // vtable len
        8, 0, // table len
        6, 0, // offset to field 0 from vtable start
        4, 0, // offset to field 1 from vtable start
        // vtable start
        8, 0, 0, 0, // negative offset to start of vtable from here
        0x9A, 0x78, // field 1
        0x56, 0x34, // field 0
        // table start
    }, builder.buffer.data);
}

test "prepend object with vector" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();

    const T = i16;
    const slice = &[_]T{ 0x5678, 0x1234 };
    const vec_offset = try builder.prependVector(T, slice);

    try builder.startTable();
    try builder.appendTableField(i16, 0x37); // field 0
    try builder.appendTableFieldOffset(vec_offset); // field 1
    _ = try builder.endTable();
    try testing.expectEqualSlices(u8, &[_]u8{
        8, 0, // vtable len
        12, 0, // table len
        10, 0, // offset to field 0 from vtable start
        4, 0, // offset to field 1 from vtable start
        // vtable start
        8, 0, 0, 0, // negative offset to start of vtable from here
        8, 0, 0, 0, // field 1 (vector offset from here)
        0, 0, // padding
        0x37, 0, // field 0
        // table start
        2, 0, 0, 0, // length of vector (u32)
        0x78, 0x56, // vector value 1
        0x34, 0x12, // vector value 0
        // vector data
    }, builder.buffer.data);
}

test "prepend object with vector of string" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();

    const s1 = try builder.prependString("s1");
    const s2 = try builder.prependString("s2");
    const vec_offset = try builder.prependOffsets(@constCast(&[_]Offset{ s1, s2 }));

    try builder.startTable();
    try builder.appendTableFieldOffset(vec_offset); // field 0
    _ = try builder.endTable();
    try testing.expectEqualSlices(u8, &[_]u8{
        6, 0, // vtable len
        8, 0, // table len
        4, 0, // offset to field 0 from vtable start (vector)
        // vtable start
        6, 0, 0, 0, // negative offset to start of vtable from here
        4, 0, 0, 0, // offset to field 0 from here
        // table start
        2, 0, 0, 0, // field 0 len
        16, 0, 0, 0, // field 0 item 0 offset from here
        4, 0, 0, 0, // field 0 item 1 offset from here
        2, 0, 0, 0, // "s2".len
        's', '2', 0, 0, // s2
        2, 0, 0, 0, // "s1".len
        's', '1', 0, 0, // s1
        // data
    }, builder.buffer.data);
}

const Color = enum(u8) {
    red = 0,
    green,
    blue = 2,
};

const Vec3 = extern struct {
    x: f32,
    y: f32,
    z: f32,
};

const Vec4 = extern struct {
    v: [4]f32,
};

const Equipment = enum(u8) { none, weapon };

fn exampleWeapon(builder: *Builder, name: []const u8, damage: i16) !Offset {
    const owners = try builder.prependVectorOffsets([:0]const u8, @constCast(&[_][:0]const u8{
        "Shrek",
        "Fiona",
    }));
    const weapon_name = try builder.prependString(name);
    try builder.startTable();
    try builder.appendTableFieldOffset(weapon_name); // field 0 (name)
    try builder.appendTableField(i16, damage); // field 1 (damage)
    try builder.appendTableFieldOffset(owners); // field 2 (owners)
    return try builder.endTable();
}

/// Creates an example flatbuffer conforming to ./src/codegen/examples/monster/monster.fbs
/// which includes a field of every type class.
pub fn exampleMonster(allocator: Allocator) ![]u8 {
    var builder = Builder.init(allocator);

    const weapon0 = try exampleWeapon(&builder, "saw", 21);
    const weapon1 = try exampleWeapon(&builder, "axe", 23);

    const monster_name = try builder.prependString("orc");
    const inventory = try builder.prependVector(i16, &[_]i16{ 1, 2 });
    const weapons = try builder.prependOffsets(@constCast(&[_]Offset{ weapon0, weapon1 }));
    const path = try builder.prependVector(Vec3, &[_]Vec3{ .{ .x = 1, .y = 2, .z = 3 }, .{ .x = 4, .y = 5, .z = 6 } });

    try builder.startTable();
    try builder.appendTableField(Vec3, .{ .x = 1, .y = 2, .z = 3 }); // field 0 (pos)
    try builder.appendTableFieldWithDefault(i16, 100, 150); // field 1 (mana)
    try builder.appendTableFieldWithDefault(i16, 200, 100); // field 2 (hp)
    try builder.appendTableFieldOffset(monster_name); // field 3 (name)
    try builder.appendTableFieldOffset(0); // field 4 (friendly, deprecated)
    try builder.appendTableFieldOffset(inventory); // field 5 (inventory)
    try builder.appendTableFieldWithDefault(Color, .green, .green); // field 6 (color)
    try builder.appendTableFieldOffset(weapons); // field 7 (weapons)
    try builder.appendTableFieldWithDefault(Equipment, Equipment.weapon, .none); // field 8 (equipment type)
    try builder.appendTableFieldOffset(weapon0); // field 9 (equipment value)
    try builder.appendTableFieldOffset(path); // field 10 (path)
    try builder.appendTableField(Vec4, .{ .v = .{ 1, 2, 3, 4 } }); // field 11 (rotation)
    const root = try builder.endTable();

    return builder.finish(root);
}

test "build monster" {
    testing.log_level = .debug;
    // annotated to make debugging Table easier
    const bytes = try exampleMonster(testing.allocator);
    defer testing.allocator.free(bytes);
    // Flatc has a handly annotation tool for making this test. Just uncomment the lines below:
    // var file = try std.fs.cwd().createFile("monster_data.bfbs", .{});
    // defer file.close();
    // try file.writer().writeAll(bytes);

    // And run these commands:
    // flatc --annotate ./src/codegen/examples/monster/monster.fbs ./monster_data.bfbs
    // less monster_data.afb
    try testing.expectEqualSlices(u8, &[_]u8{
        // header 0x00
        0x2C, 0, 0, 0, // offset to root table `Monster`
        0,    0, 0, 0,
        0,    0, 0, 0,
        0, 0, 0, 0, // padding (align to 16)

        // vtable (Monster) 0x10
        0x1C, 0, // vtable len
        0x44, 0, // table len
        0x38, 0, // offset to field `pos` (id: 0)
        0x36, 0, // offset to field `mana` (id: 1)
        0x34, 0, // offset to field `hp` (id: 2)
        0x30, 0, // offset to field `name` (id: 3)
        0x00, 0, // offset to field `friendly` (id: 4) <defaults to 0> (Bool)
        0x2C, 0, // offset to field `inventory` (id: 5)
        0, 0, // offset to field `color` (id: 6) <defaults to .green> (Enum)
        0x28, 0, // offset to field `weapons` (id: 7)
        0x27, 0, // offset to field `equipped_type` (id: 8)
        0x20, 0, // offset to field `equipped` (id: 9)
        0x1C, 0, // offset to field `path` (id: 10)
        0x04, 0, // offset to field `rotation` (id: 11)

        // root table (Monster) 0x2c
        0x1C, 0, 0, 0, // offset to vtable
        0, 0, 0x80, 0x3F, // rotation[0] = @as(f32, 1)
        0, 0, 0, 0x40, // rotation[1] = @as(f32, 2)
        0, 0, 0x40, 0x40, // rotation[2] = @as(f32, 3)
        0, 0, 0x80, 0x40, // rotation[3] = @as(f32, 4)
        0, 0, 0, 0, // padding
        0, 0, 0, 0, // padding
        0x28, 0, 0, 0, // offset to field `path` (vector)
        0xA8, 0, 0, 0, // offset to field `equipped` (union of type `Weapon`)
        0, 0, 0, @intFromEnum(Equipment.weapon), // equipped_type
        0x40, 0, 0, 0, // offset to field `weapons` (vector)
        0x48, 0, 0, 0, // offset to field `inventory` (vector)
        0x4C, 0, 0, 0, // offset to field `name` (string)
        0xC8, 0, // table field `hp` (Short)
        0x64, 0, // table field `mana` (Short)
        0, 0, 0x80, 0x3F, // struct field `pos.x` of 'Vec3' (Float)
        0, 0, 0, 0x40, // struct field `pos.y` of 'Vec3' (Float)
        0, 0, 0x40, 0x40, // struct field `pos.z` of 'Vec3' (Float)

        // vector (Monster.path) 0x70
        0x02, 0, 0, 0, // length of vector (# items)
        0, 0, 0x80, 0x3F, // struct field `[0].x` of 'Vec3' (Float)
        0, 0, 0, 0x40, // struct field `[0].y` of 'Vec3' (Float)
        0, 0, 0x40, 0x40, // struct field `[0].z` of 'Vec3' (Float)
        0, 0, 0x80, 0x40, // struct field `[1].x` of 'Vec3' (Float)
        0, 0, 0xA0, 0x40, // struct field `[1].y` of 'Vec3' (Float)
        0, 0, 0xC0, 0x40, // struct field `[1].z` of 'Vec3' (Float)
        0, 0, 0, 0, // padding
        0, 0, 0, 0, // padding
        // vector (Monster.weapons):
        0x02, 0, 0, 0, // length of vector (# items)
        0x5C, 0, 0, 0, // offset to table[0]
        0x14, 0, 0, 0, // offset to table[1]

        // vector (Monster.inventory):
        0x02, 0, 0, 0, // length of vector (# items)
        0x01, 0, // value[0]
        0x02, 0, // value[1]

        // string (Monster.name):
        0x03, 0, 0, 0, // length of string
        'o', 'r', 'c', 0, // string

        // table (Weapon):
        0xC6, 0xFF, 0xFF, 0xFF, // offset to vtable
        0x14, 0, 0, 0, // offset to field `owners` (vector)
        0, 0, // padding
        0x17, 0, // table field `damage` (Short)
        0x04, 0, 0, 0, // offset to field `name` (string)

        // string (Weapon.name):
        0x03, 0, 0, 0, // length of string
        'a', 'x', 'e', 0, // string

        // vector (Weapon.owners):
        0x02, 0, 0, 0, // length of vector (# items)
        0x14, 0, 0, 0, // offset to string[0]
        0x04, 0, 0, 0, // offset to string[1]

        // string (Weapon.owners):
        0x05, 0, 0, 0, // length of string
        'F', 'i', 'o', 'n', // string
        'a', 0, 0, 0, // string

        // string (Weapon.owners):
        0x05, 0, 0, 0, // length of string
        'S', 'h', 'r', 'e', // string
        'k', 0, // string

        // vtable (Weapon):
        0x0A, 0, // size of this vtable
        0x10, 0, // size of referring table
        0x0C, 0, // offset to field `name` (id: 0)
        0x0A, 0, // offset to field `damage` (id: 1)
        0x04, 0, // offset to field `owners` (id: 2)

        // table (Weapon):
        0x0A, 0, 0, 0, // offset to vtable
        0x14, 0, 0, 0, // offset to field `owners` (vector)
        0, 0, // padding
        0x15, 0, // table field `damage` (Short)
        0x04, 0, 0, 0, // offset to field `name` (string)

        // string (Weapon.name):
        0x03, 0, 0, 0, // length of string
        's', 'a', 'w', 0, // string

        // vector (Weapon.owners):
        0x02, 0, 0, 0, // length of vector (# items)
        0x14, 0, 0, 0, // offset to string[0]
        0x04, 0, 0, 0, // offset to string[1]

        // string (Weapon.owners):
        0x05, 0,   0,   0, // length of string
        'F',  'i', 'o', 'n',
        'a', 0, 0, 0, // padding

        // string (Weapon.owners):
        0x05, 0, 0, 0, // length of string
        'S', 'h', 'r', 'e', // string
        'k', 0, 0, 0, // string
    }, bytes);
}

test "vtable truncates trailing null fields" {
    const allocator = testing.allocator;
    var builder = Builder.init(allocator);

    try builder.startTable();
    try builder.appendTableField(i32, 1);
    try builder.appendTableField(?i64, null);
    try builder.appendTableField(?i32, null);
    const root = try builder.endTable();

    const bytes = try builder.finish(root);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, &[_]u8{
        // header
        0x0C, 0, 0, 0, // offset to root table
        0, 0, // padding
        0x06, 0, // vtable len
        0x08, 0, // table len
        0x04, 0, // offset to field 0
        // <- field 1 optimized away
        // <- field 2 optimized away
        // table start
        0x06, 0, 0, 0, // negative offset to vtable
        0x01, 0, 0, 0, // field 0 @as(i32, 1)
    }, bytes);
}

test "vtable caching" {
    const allocator = testing.allocator;
    var builder = Builder.init(allocator);

    try builder.startTable();
    try builder.appendTableField(i32, 1);
    try builder.appendTableField(u32, 2);
    _ = try builder.endTable();

    try builder.startTable();
    try builder.appendTableField(i32, 3);
    try builder.appendTableField(u32, 4);
    const root = try builder.endTable();

    const bytes = try builder.finish(root);
    defer allocator.free(bytes);

    try testing.expectEqualSlices(u8, &[_]u8{
        // header
        0x04, 0, 0, 0, // offset to root table
        0xF4, 0xFF, 0xFF, 0xFF, // negative offset to vtable (-12)
        0x04, 0, 0, 0, // field 1 @as(u32, 4)
        0x03, 0, 0, 0, // field 0 @as(i32, 3)
        0x08, 0, // vtable len
        0x0C, 0, // table len
        0x08, 0, // offset to field 0
        0x04, 0, // offset to field 1
        0x08, 0, 0, 0, // negative offset to vtable
        0x02, 0, 0, 0, // field 1 @as(u32, 2)
        0x01, 0, 0, 0, // field 0 @as(i32, 1)
    }, bytes);
}
