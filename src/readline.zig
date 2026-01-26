const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const util = @import("util.zig");

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return mem.order(u8, lhs, rhs) == .lt;
}

pub const Console = struct {
    stdin: fs.File,
    stdout: fs.File,

    completion: struct {
        keywords: []const []const u8,
        path: ?[]const u8,
        search_in_cwd: bool = false,
    },

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

    fn getCompletions(self: *const Console, input: []const u8, gpa: std.mem.Allocator) !?[][]const u8 {
        var completions_set: std.BufSet = .init(gpa);
        defer completions_set.deinit();
        for (self.completion.keywords) |kwd| {
            if (mem.startsWith(u8, kwd, input)) {
                try completions_set.insert(kwd);
            }
        }
        if (self.completion.path) |path| {
            var path_iter = mem.splitScalar(u8, path, ':');
            while (path_iter.next()) |dir_path| {
                var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch continue;
                defer dir.close();
                var dir_iter = dir.iterate();
                while (dir_iter.next() catch continue) |entry| {
                    if (entry.kind != .file) continue;
                    const isExec = util.isExecutable(dir, entry.name) catch false;
                    if (!isExec) continue;
                    if (mem.startsWith(u8, entry.name, input)) {
                        if (!completions_set.contains(entry.name)) {
                            try completions_set.insert(entry.name);
                        }
                    }
                }
            }
        }
        if (self.completion.search_in_cwd) {
            if (fs.cwd().openDir(".", .{ .iterate = true })) |cwd| {
                var dir_iter = cwd.iterate();
                while (dir_iter.next()) |maybe_entry| {
                    const entry = maybe_entry orelse break;
                    if (entry.kind != .file) continue;
                    const isExec = util.isExecutable(cwd, entry.name) catch false;
                    if (!isExec) continue;
                    if (mem.startsWith(u8, entry.name, input)) {
                        if (!completions_set.contains(entry.name)) {
                            try completions_set.insert(entry.name);
                        }
                    }
                } else |_| {}
            } else |_| {}
        }
        if (completions_set.count() > 0) {
            const completions = try gpa.alloc([]const u8, completions_set.count());
            var set_iter = completions_set.iterator();
            var i: usize = 0;
            while (set_iter.next()) |key| {
                completions[i] = try gpa.dupe(u8, key.*);
                i += 1;
            }
            return completions;
        } else {
            return null;
        }
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

        var double_tab = false;

        while (stdin.takeByte()) |char| {
            // https://www.asciitable.com/
            switch (char) {
                '\n' => {
                    break;
                },
                '\t' => {
                    var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
                    defer arena_allocator.deinit();
                    const arena = arena_allocator.allocator();
                    const maybe_completions = try self.getCompletions(input.items, arena);
                    if (maybe_completions) |completions| {
                        if (completions.len == 1) {
                            try stdout.writeByte('\r'); // Goto start of line
                            try stdout.writeAll(&.{ 27, '[', 'K' }); // Clear line
                            try stdout.writeByte('\r'); // Goto start of line
                            try stdout.writeAll(ppt);
                            try stdout.writeAll(completions[0]);
                            try stdout.writeByte(' ');
                            input.clearRetainingCapacity();
                            try input.appendSlice(gpa, completions[0]);
                            try input.append(gpa, ' ');
                            line_pos = completions[0].len + 1;
                        } else if (double_tab) {
                            mem.sort([]const u8, completions, {}, lessThan);
                            try stdout.writeByte('\n');
                            for (completions, 0..) |completion, i| {
                                try stdout.writeAll(completion);
                                if (i < completions.len - 1) {
                                    try stdout.writeAll("  ");
                                }
                            }
                            try stdout.writeByte('\n');
                            try stdout.writeAll(ppt);
                            try stdout.writeAll(input.items);
                        } else {
                            try stdout.writeByte(0x07); // Bell
                        }
                    } else {
                        try stdout.writeByte(0x07); // Bell
                    }
                    double_tab = !double_tab;
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
