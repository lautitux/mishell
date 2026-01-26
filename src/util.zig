const std = @import("std");

pub fn dupe2(allocator: std.mem.Allocator, comptime T: type, m: []const []const T) ![]const []const T {
    const new_slice = try allocator.alloc([]T, m.len);
    for (m, 0..) |elem, i| {
        new_slice[i] = try allocator.dupe(T, elem);
    }
    return new_slice;
}

pub fn isExecutable(dir: std.fs.Dir, sub_path: []const u8) !bool {
    const stat = try dir.statFile(sub_path);
    const permissions = stat.mode & 0o7777;
    return permissions & 0o111 > 0;
}
