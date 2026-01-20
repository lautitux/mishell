const std = @import("std");
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
            try stdout.print("{s}: command not found\n", .{command});
        }
    }
}
