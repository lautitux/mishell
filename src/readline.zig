const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const util = @import("util.zig");

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return mem.order(u8, lhs, rhs) == .lt;
}

// https://www.asciitable.com/
const ETX = 0x03; // End of text
const EOT = 0x04; // End of transmission
const BELL = 0x07;
const BACKSPACE = 0x08;
const NEW_PAGE = 0x0C;
const ESC = 0x1B;
const DEL = 0x7F;

const Prompt = struct {
    allocator: std.mem.Allocator,
    input: std.ArrayList(u8) = .{},
    cursor: struct {
        line: usize = 0,
        column: usize = 0,
    } = .{},
    prompt: []const u8,
    stdout: *std.Io.Writer,

    pub const Direction = enum {
        Left,
        Right,
    };

    pub fn deinit(self: *Prompt) void {
        self.input.deinit(self.allocator);
    }

    pub fn clearText(self: *Prompt) !void {
        try self.stdout.writeAll(&.{ '\r', ESC, '[', 'K' });
        self.input.clearRetainingCapacity();
        self.cursor.column = 0;
        try self.show();
    }

    pub fn setText(self: *Prompt, str: []const u8) !void {
        try self.clearText();
        try self.input.appendSlice(self.allocator, str);
        self.cursor.column = str.len;
        try self.show();
    }

    pub fn text(self: *const Prompt) []const u8 {
        return self.input.items;
    }

    pub fn appendChar(self: *Prompt, char: u8) !void {
        try self.input.insert(self.allocator, self.cursor.column, char);
        self.cursor.column += 1;
        try self.show();
    }

    pub fn backspace(self: *Prompt) !void {
        if (self.cursor.column > 0) {
            _ = self.input.orderedRemove(self.cursor.column - 1);
            self.cursor.column -= 1;
            try self.show();
        }
    }

    pub fn clearScreen(self: *Prompt) !void {
        try self.stdout.writeAll(&.{ ESC, '[', '2', 'J' }); // Clear screen
        try self.stdout.writeAll(&.{ ESC, '[', 'H' }); // Cursor to home
        try self.show();
    }

    fn moveCursorUnchecked(self: *Prompt, direction: Direction, amount: usize) !void {
        const escape_seq = &.{ ESC, '[' };
        const fmt_str = "{s}{d}{c}";
        switch (direction) {
            .Left => try self.stdout.print(fmt_str, .{ escape_seq, amount, 'D' }),
            .Right => try self.stdout.print(fmt_str, .{ escape_seq, amount, 'C' }),
        }
    }

    pub fn moveCursor(self: *Prompt, direction: Direction, amount: usize) !void {
        switch (direction) {
            .Left => if (self.cursor.column >= amount) {
                try self.moveCursorUnchecked(.Left, amount);
                self.cursor.column -= amount;
            },
            .Right => if (self.cursor.column + amount <= self.input.items.len) {
                try self.moveCursorUnchecked(.Right, amount);
                self.cursor.column += amount;
            },
        }
    }

    pub fn show(self: *Prompt) !void {
        try self.stdout.writeAll(&.{ '\r', ESC, '[', 'K' });
        try self.stdout.print("{s}{s}\r", .{ self.prompt, self.input.items });
        try self.moveCursorUnchecked(.Right, self.prompt.len + self.cursor.column);
    }
};

pub const Console = struct {
    stdin: fs.File,
    stdout: fs.File,

    completion: struct {
        keywords: []const []const u8,
        path: ?[]const u8,
        search_in_cwd: bool = false,
    },

    history: []const []const u8,

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

        if (self.completion.search_in_cwd) search_cwd: {
            const cwd = fs.cwd().openDir(".", .{ .iterate = true }) catch break :search_cwd;
            try getCompletionsFromDir(&completions_set, cwd, input);
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
        defer self.endRaw() catch {};

        var stdin_buf: [4]u8 = undefined;
        var stdin_r = self.stdin.readerStreaming(&stdin_buf);
        const stdin = &stdin_r.interface;

        var stdout_w = self.stdout.writerStreaming(&.{});
        const stdout = &stdout_w.interface;

        var state: Prompt = .{
            .allocator = gpa,
            .prompt = ppt,
            .stdout = stdout,
        };
        errdefer state.deinit();
        try state.show();

        var history_index: usize = self.history.len;
        var history_replaced_input: ?[]const u8 = null;
        defer if (history_replaced_input) |str| gpa.free(str);

        var double_tab = false;

        while (stdin.takeByte()) |char| {
            switch (char) {
                '\n' => break,
                '\t' => double_tab = try self.handleTab(&state, double_tab),
                ETX => { // ^C
                    try stdout.writeByte('\n');
                    return error.EndOfText;
                },
                EOT => { // ^D
                    try stdout.writeByte('\n'); // advance to a new line before exiting
                    return error.EndOfTransmission;
                },
                NEW_PAGE => try state.clearScreen(), // ^L
                ESC => {
                    var next_char = try stdin.takeByte();
                    std.debug.assert(next_char == '[');
                    next_char = try stdin.takeByte();
                    std.debug.assert(!std.ascii.isDigit(next_char));
                    switch (next_char) {
                        'A' => if (history_index > 0) {
                            history_index -= 1;
                            if (history_replaced_input == null)
                                history_replaced_input = try gpa.dupe(u8, state.input.items);
                            try state.setText(self.history[history_index]);
                        },
                        'B' => if (history_index < self.history.len) {
                            history_index += 1;
                            if (history_index == self.history.len) {
                                const line = history_replaced_input orelse "";
                                try state.setText(line);
                                gpa.free(line);
                                history_replaced_input = null;
                            } else {
                                try state.setText(self.history[history_index]);
                            }
                        },
                        'C' => try state.moveCursor(.Right, 1),
                        'D' => try state.moveCursor(.Left, 1),
                        else => continue,
                    }
                },
                DEL => try state.backspace(),
                else => {
                    switch (char) {
                        0...31 => continue, // Non printable characters
                        else => {},
                    }
                    try state.appendChar(char);
                },
            }

            if (char != '\t') double_tab = false;
        } else |err| {
            if (err == error.ReadFailed) return err;
        }
        try stdout.writeByte('\n');

        return state.input.toOwnedSlice(gpa);
    }

    fn handleTab(self: *const Console, state: *Prompt, double_tab: bool) !bool {
        var arena_allocator: std.heap.ArenaAllocator = .init(state.allocator);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        if (try self.getCompletions(state.text(), arena)) |completions| {
            // SAFETY: completions is not empty, and at least all
            //         possible completions start with 'input'
            const prefix = util.longestCommonPrefix(u8, completions).?;
            const unique = completions.len == 1;

            if (unique or !mem.startsWith(u8, state.text(), prefix)) {
                try state.setText(prefix);
                if (unique) try state.appendChar(' ');
                return false;
            } else if (double_tab) {
                mem.sort([]const u8, completions, {}, lessThan);
                try state.stdout.writeByte('\n');
                for (completions, 0..) |candidate, i| {
                    try state.stdout.print("{s}{s}", .{
                        candidate,
                        if (i < completions.len - 1) "  " else "\n",
                    });
                }
                try state.show();
                return false;
            }
        }

        try state.stdout.writeByte(BELL);
        return true;
    }
};
