const std = @import("std");

// https://www.geeksforgeeks.org/dsa/longest-common-prefix-using-divide-and-conquer-algorithm/

fn commonPrefixUtil(comptime T: type, s1: []const T, s2: []const T) []const T {
    var i: usize = 0;
    while (i < s1.len and i < s2.len and s1[i] == s2[i]) : (i += 1) {}
    return s1[0..i];
}

fn commonPrefix(comptime T: type, slices: []const []const T, l: usize, r: usize) []const T {
    if (l == r) {
        return slices[l];
    }
    if (l < r) {
        const mid = l + (r - l) / 2;
        const p1 = commonPrefix(T, slices, l, mid);
        const p2 = commonPrefix(T, slices, mid + 1, r);
        return commonPrefixUtil(T, p1, p2);
    } else {
        unreachable;
    }
}

pub fn longestCommonPrefix(comptime T: type, slices: []const []const T) ?[]const T {
    const prefix = commonPrefix(T, slices, 0, slices.len - 1);
    return if (prefix.len == 0) null else prefix;
}

pub fn isExecutable(dir: std.fs.Dir, sub_path: []const u8) !bool {
    const stat = try dir.statFile(sub_path);
    const permissions = stat.mode & 0o7777;
    return permissions & 0o111 > 0;
}
