const std = @import("std");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

pub fn main() !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    while (true) {
        try stdout.print("$ ", .{});

        const input = (try stdin.takeDelimiter('\n')).?;
        const separator = std.mem.indexOf(u8, input, " ");

        const command = if (separator) |pos| input[0..pos] else input;
        const arguments = if (separator) |pos| input[(pos + 1)..] else "";

        if (std.mem.eql(u8, command, "exit")) {
            break;
        } else if (std.mem.eql(u8, command, "echo")) {
            try stdout.print("{s}\n", .{arguments});
        } else {
            try stdout.print("{s}: command not found\n", .{command});
        }
    }
}
