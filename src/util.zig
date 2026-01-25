const std = @import("std");

pub fn dupe2(allocator: std.mem.Allocator, comptime T: type, m: []const []const T) ![]const []const T {
    const new_slice = try allocator.alloc([]T, m.len);
    for (m, 0..) |elem, i| {
        new_slice[i] = try allocator.dupe(T, elem);
    }
    return new_slice;
}
