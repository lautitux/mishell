const std = @import("std");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

pub fn main() !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    while (true) {
        try stdout.print("$ ", .{});

        const command = try stdin.takeDelimiter('\n');
        if (command) |cmd| {
            if (std.mem.eql(u8, cmd, "exit")) {
                break;
            } else {
                try stdout.print("{s}: command not found\n", .{cmd});
            }
        }
    }
}
