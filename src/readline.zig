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

    // https://www.asciitable.com/
    const ETX = 0x03; // End of text
    const EOT = 0x04; // End of transmission
    const BELL = 0x07;
    const BACKSPACE = 0x08;
    const NEW_PAGE = 0x0C;
    const ESC = 0x1B;
    const DEL = 0x7F;

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

    fn clearLine(stdout: *std.Io.Writer) !void {
        try stdout.writeByte('\r'); // Goto start of line
        try stdout.writeAll(&.{ ESC, '[', 'K' }); // Clear line
    }

    fn getCompletionsFromDir(completions_set: *std.BufSet, dir: fs.Dir, input: []const u8) !void {
        var dir_iter = dir.iterate();
        while (dir_iter.next()) |maybe_entry| {
            const entry = maybe_entry orelse break;
            if (entry.kind != .file) continue;
            const isExec = util.isExecutable(dir, entry.name) catch false;
            if (!isExec) continue;
            if (mem.startsWith(u8, entry.name, input) and !completions_set.contains(entry.name)) {
                try completions_set.insert(entry.name);
            }
        } else |_| {} // Ignore errors iterating dir
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
                try getCompletionsFromDir(&completions_set, dir, input);
            }
        }

        if (self.completion.search_in_cwd) {
            if (fs.cwd().openDir(".", .{ .iterate = true })) |cwd| {
                try getCompletionsFromDir(&completions_set, cwd, input);
            } else |_| {}
        }

        if (completions_set.count() > 0) {
            const completions = try gpa.alloc(
                []const u8,
                completions_set.count(),
            );
            var i: usize = 0;
            var completions_set_iter = completions_set.iterator();
            while (completions_set_iter.next()) |key| : (i += 1) {
                completions[i] = try gpa.dupe(u8, key.*);
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
            switch (char) {
                '\n' => break,
                '\t' => {
                    line_pos =
                        try self.handleTab(
                            gpa,
                            &double_tab,
                            stdout,
                            ppt,
                            &input,
                        );
                },
                ETX => {
                    // ^C
                    try stdout.writeByte('\n');
                    return error.EndOfText;
                },
                EOT => {
                    // ^D
                    return error.EndOfTransmission;
                },
                NEW_PAGE => {
                    // ^L
                    try stdout.writeAll(&.{ ESC, '[', '2', 'J' }); // Clear screen
                    try stdout.writeAll(&.{ ESC, '[', 'H' }); // Cursor to home
                    try stdout.writeAll(ppt);
                    try stdout.writeAll(input.items);
                },
                ESC => {
                    // TODO: Support escape codes
                    var next_char = try stdin.takeByte();
                    std.debug.assert(next_char == '[');
                    next_char = try stdin.takeByte();
                    continue;
                },
                DEL => {
                    // Backspace
                    if (line_pos > 0) {
                        _ = input.pop();
                        try stdout.writeAll(&.{ BACKSPACE, ' ', BACKSPACE });
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

    fn handleTab(
        self: *const Console,
        gpa: std.mem.Allocator,
        double_tab: *bool,
        stdout: *std.Io.Writer,
        ppt: []const u8,
        input: *std.ArrayList(u8),
    ) !usize {
        var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        if (try self.getCompletions(input.items, arena)) |completions| {
            // SAFETY: completions is not empty, and at least all
            //         possible completions start with 'input'
            const prefix = util.longestCommonPrefix(u8, completions).?;
            const unique = completions.len == 1;
            if (unique or !mem.startsWith(u8, input.items, prefix)) {
                try clearLine(stdout);
                try stdout.print(
                    "\r{s}{s}{s}",
                    .{
                        ppt,
                        prefix,
                        if (unique) " " else "",
                    },
                );

                input.clearRetainingCapacity();
                try input.appendSlice(gpa, prefix);
                if (unique) try input.append(gpa, ' ');

                double_tab.* = false;
                return prefix.len + @as(usize, if (unique) 1 else 0);
            } else if (double_tab.*) {
                mem.sort([]const u8, completions, {}, lessThan);
                try stdout.writeByte('\n');

                for (completions, 0..) |candidate, i| {
                    try stdout.print(
                        "{s}{s}",
                        .{
                            candidate,
                            if (i < completions.len - 1) "  " else "\n",
                        },
                    );
                }

                try stdout.print("{s}{s}", .{ ppt, input.items });

                double_tab.* = false;
                return input.items.len;
            }
        }

        try stdout.writeByte(BELL);
        double_tab.* = true;
        return input.items.len;
    }
};
