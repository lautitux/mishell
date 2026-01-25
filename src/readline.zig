const std = @import("std");
const fs = std.fs;

pub const Console = struct {
    stdin: fs.File,
    stdout: fs.File,

    keywords: []const []const u8,

    fn beginRaw(self: *const Console) !void {
        var termios = try std.posix.tcgetattr(self.stdin.handle);
        termios.lflag = .{ .ICANON = false, .ECHO = false };
        try std.posix.tcsetattr(self.stdin.handle, .FLUSH, termios);
    }

    fn endRaw(self: *const Console) !void {
        var termios = try std.posix.tcgetattr(self.stdin.handle);
        termios.lflag = .{ .ICANON = true, .ECHO = true };
        try std.posix.tcsetattr(self.stdin.handle, .FLUSH, termios);
    }

    pub fn prompt(self: *const Console, gpa: std.mem.Allocator, ppt: []const u8) ![]const u8 {
        try self.beginRaw();
        var stdin_buf: [4]u8 = undefined;
        var stdin_r = self.stdin.readerStreaming(&stdin_buf);
        const stdin = &stdin_r.interface;

        var stdout_w = self.stdout.writerStreaming(&.{});
        const stdout = &stdout_w.interface;

        try stdout.writeAll(ppt);

        var line_pos: usize = 0;
        var input: std.ArrayList(u8) = .{};
        errdefer input.deinit(gpa);

        while (stdin.takeByte()) |char| {
            // https://www.asciitable.com/
            switch (char) {
                '\n' => {
                    break;
                },
                '\t' => {
                    for (self.keywords) |kwd| {
                        if (std.mem.startsWith(u8, kwd, input.items)) {
                            try stdout.writeByte('\r'); // Goto start of line
                            try stdout.writeAll(&.{ 27, '[', 'K' }); // Clear line
                            try stdout.writeByte('\r'); // Goto start of line
                            try stdout.writeAll(ppt);
                            try stdout.writeAll(kwd);
                            try stdout.writeByte(' ');
                            input.clearRetainingCapacity();
                            try input.appendSlice(gpa, kwd);
                            try input.append(gpa, ' ');
                            line_pos = kwd.len + 1;
                            break;
                        }
                    }
                },
                3 => {
                    // ^C
                    try stdout.writeByte('\n');
                    return error.EndOfText;
                },
                4 => {
                    // ^D
                    return error.EndOfTransmission;
                },
                12 => {
                    // ^L
                    try stdout.writeAll(&.{ 27, '[', '2', 'J' }); // Clear screen
                    try stdout.writeAll(&.{ 27, '[', 'H' }); // Cursor to home
                    try stdout.writeAll(ppt);
                    try stdout.writeAll(input.items);
                },
                27 => {
                    // TODO: Support escape codes
                    var next_char = try stdin.takeByte();
                    std.debug.assert(next_char == '[');
                    next_char = try stdin.takeByte();
                    continue;
                },
                127 => {
                    // Backspace
                    if (line_pos > 0) {
                        _ = input.pop();
                        try stdout.writeAll(&.{ 0x08, ' ', 0x08 });
                        line_pos -= 1;
                    }
                },
                else => {
                    switch (char) {
                        0...31 => continue,
                        else => {},
                    }
                    try input.append(gpa, char);
                    try stdout.writeByte(char);
                    line_pos += 1;
                },
            }
        } else |err| {
            if (err == error.ReadFailed) return err;
        }
        try stdout.writeByte('\n');

        try self.endRaw();
        return input.toOwnedSlice(gpa);
    }
};
