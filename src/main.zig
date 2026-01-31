const std = @import("std");
const Shell = @import("shell.zig").Shell;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("got a memory leak");
    }

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    var shell: Shell = .init(allocator, env);
    defer shell.deinit();

    if (env.get("HISTFILE")) |history_file_path| history: {
        const file = std.fs.openFileAbsolute(history_file_path, .{}) catch break :history;
        defer file.close();
        try shell.loadHistory(file);
    }

    while (!shell.should_exit) {
        if (try shell.prompt())
            try shell.run();
    }

    if (env.get("HISTFILE")) |history_file_path| history: {
        const file = std.fs.createFileAbsolute(history_file_path, .{}) catch break :history;
        defer file.close();
        try shell.storeHistory(file, .{});
    }
}

test {
    _ = @import("scanner.zig");
}
