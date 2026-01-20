const std = @import("std");

pub fn find_executable(env: std.process.EnvMap, name: []const u8) !?[]const u8 {
    if (env.get("PATH")) |path| {
        var iter = std.mem.splitScalar(u8, path, ':');
        while (iter.next()) |dir_path| {
            var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
            defer dir.close();
            const stat = dir.statFile(name) catch continue;
            const permissions = stat.mode & 0o7777;
            if (permissions & 0o111 > 0) {
                return dir_path;
            }
        }
    }
    return null;
}
