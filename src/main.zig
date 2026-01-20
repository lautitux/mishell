const std = @import("std");
const tools = @import("tools.zig");
const builtin = @import("shell_builtin.zig");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

pub fn main() !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    const allocator = std.heap.page_allocator;
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    while (true) {
        try stdout.print("$ ", .{});

        const input = (try stdin.takeDelimiter('\n')).?;
        const separator = std.mem.indexOf(u8, input, " ");

        const command = if (separator) |pos| input[0..pos] else input;
        const arguments = if (separator) |pos| input[(pos + 1)..] else "";

        if (builtin.commands.get(command)) |kind| {
            builtin.exec_command(kind, env, stdout, arguments) catch |err| {
                switch (err) {
                    error.ShouldExit => break,
                    else => std.debug.print("error: {}\n", .{err}),
                }
            };
        } else {
            const maybe_dir = try tools.find_executable(env, command);
            if (maybe_dir) |dir| {
                _ = dir;
                var argv: std.ArrayList([]const u8) = .{};
                try argv.append(allocator, command);
                var iter = std.mem.splitAny(u8, arguments, " ");
                while (iter.next()) |argument| {
                    if (argument.len > 0) {
                        try argv.append(allocator, argument);
                    }
                }
                defer argv.deinit(allocator);
                var executable: std.process.Child = .init(argv.items, allocator);
                executable.stdin_behavior = .Inherit;
                executable.stdout_behavior = .Inherit;
                executable.stderr_behavior = .Inherit;
                try executable.spawn();
                _ = try executable.wait();
            } else {
                try stdout.print("{s}: command not found\n", .{command});
            }
        }
    }
}
