const std = @import("std");
pub const Builder = @import("./builder.zig").Builder;
pub const exampleMonster = @import("./builder.zig").exampleMonster;
pub const Table = @import("./table.zig").Table;

pub const isScalar = Table.isScalar;
pub const Error = Table.Error || std.mem.Allocator.Error;

fn hasAllocator(comptime T: type) bool {
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "init")) {
        return @typeInfo(@TypeOf(T.init)).@"fn".params.len == 2;
    }
    return false;
}

/// Unpacks a codegenned vector field of a flatbuffer table into a native Zig slice type. Caller owns returned slice.
pub fn unpackVector(
    allocator: std.mem.Allocator,
    comptime T: type,
    packed_: anytype,
    comptime getter_name: []const u8,
) Error![]T {
    const PackedT = @TypeOf(packed_);
    const getter = @field(PackedT, getter_name);

    // 1. Vector of scalar (type has getter that returns a slice)
    // We call this just to fix alignment.
    if (comptime isScalar(T)) {
        const arr = try getter(packed_);
        var res = try allocator.alloc(T, arr.len);
        for (0..arr.len) |i| res[i] = arr[i];
        return res;
    }

    const len_getter = @field(PackedT, getter_name ++ "Len");
    const len = try len_getter(packed_);
    var res = try allocator.alloc(T, len);
    errdefer allocator.free(res);

    if (@typeInfo(T) == .@"struct") {
        // 2. Vector of object
        const has_allocator = comptime hasAllocator(T);

        var i: usize = 0;
        errdefer {
            if (has_allocator) for (0..i) |j| res[j].deinit(allocator);
        }
        for (res) |*r| {
            r.* = if (has_allocator)
                try T.init(allocator, try getter(packed_, i))
            else
                try T.init(try getter(packed_, i));
            i += 1;
        }
    } else if (T == [:0]const u8) {
        // 3. Vector of string
        var i: usize = 0;
        errdefer {
            for (0..i) |j| allocator.free(res[j]);
        }
        for (res) |*r| {
            r.* = try allocator.dupeZ(u8, try getter(packed_, i));
            i += 1;
        }
    } else {
        @compileError("cannot unpack type " ++ @typeName(T));
    }
    return res;
}

test "lib" {
    _ = @import("./backwards_buffer.zig");
    _ = @import("./builder.zig");
    _ = @import("./table.zig");
}
