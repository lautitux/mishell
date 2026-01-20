const std = @import("std");
const Shell = @import("shell.zig").Shell;

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

pub fn main() !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("got a memory leak");
    }

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    var shell: Shell = .init(allocator, env, stdout, stdin);
    defer shell.deinit();

    while (!shell.should_exit) {
        try shell.prompt(allocator);
        try shell.run(allocator);
    }
}
