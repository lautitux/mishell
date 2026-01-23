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

    while (!shell.should_exit) {
        try shell.prompt(allocator);
    }
}
