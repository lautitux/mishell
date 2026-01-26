const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Writer = std.Io.Writer;
const Shell = @import("shell.zig").Shell;

pub fn exit(shell: *Shell) void {
    shell.should_exit = true;
}

pub fn echo(stdout: *Writer, arguments: []const []const u8) !void {
    for (arguments, 0..) |arg, i| {
        try stdout.writeAll(arg);
        if (i != arguments.len - 1) {
            try stdout.writeAll(" ");
        }
    }
    try stdout.writeByte('\n');
}

pub fn _type(shell: *const Shell, stdout: *Writer, stderr: *Writer, arguments: []const []const u8) !void {
    for (arguments) |command| {
        const maybe_command_type = try shell.typeof(command);
        if (maybe_command_type) |command_type| {
            switch (command_type) {
                .Builtin => |_| try stdout.print("{s} is a shell builtin\n", .{command}),
                .Executable => |dir_path| try stdout.print(
                    "{s} is {s}{c}{s}\n",
                    .{
                        command,
                        dir_path,
                        fs.path.sep,
                        command,
                    },
                ),
            }
        } else {
            try stderr.print("{s}: not found\n", .{command});
        }
    }
}

pub fn pwd(shell: *const Shell, stdout: *Writer) !void {
    var buffer: [1024]u8 = undefined;
    const path = try shell.cwd.realpath(".", &buffer);
    try stdout.print("{s}\n", .{path});
}

pub fn cd(shell: *Shell, stderr: *Writer, arguments: []const []const u8) !void {
    if (arguments.len == 1) {
        const arg = arguments[0];
        const home_dir = shell.env.get("HOME") orelse ".";
        const path = try std.mem.replaceOwned(u8, shell.allocator, arg, "~", home_dir);
        defer shell.allocator.free(path);
        const dir = shell.cwd.openDir(path, .{}) catch {
            try stderr.print("cd: {s}: No such file or directory\n", .{path});
            return;
        };
        try dir.setAsCwd();
        shell.cwd = dir;
    } else {
        try stderr.writeAll("cd: too many arguments\n");
    }
}

pub fn history(shell: *Shell, stdout: *Writer, stderr: *Writer, args: []const []const u8) !void {
    const history_len = shell.history.items.len;
    var opt: struct {
        read_from_file: ?[]const u8 = null,
        max_lines: ?usize = null,
    } = .{};
    var arg_i: usize = 0;
    while (arg_i < args.len and args[arg_i].len > 1 and args[arg_i][0] == '-') : (arg_i += 1) {
        if (arg_i + 1 < args.len) {
            switch (args[arg_i][1]) {
                'r' => opt.read_from_file = args[arg_i + 1],
                else => {
                    try stderr.print("history: -{c}: invalid option\n", .{args[arg_i][1]});
                    return;
                },
            }
            arg_i += 1;
        } else {
            // Missing flag value
            return;
        }
    }
    if (args.len - arg_i > 1) {
        try stderr.print("history: too many arguments\n", .{});
        return;
    } else if (arg_i == 0 and args.len == 1) {
        opt.max_lines = std.fmt.parseInt(usize, args[0], 10) catch {
            try stderr.print("history: {s}: numeric argument required\n", .{args[0]});
            return;
        };
    }

    if (opt.read_from_file) |file_path| {
        const file = shell.cwd.openFile(file_path, .{}) catch return;
        defer file.close();
        var buffer: [1024]u8 = undefined;
        var file_r = file.readerStreaming(&buffer);
        const file_stream = &file_r.interface;
        while (try file_stream.takeDelimiter('\n')) |line| {
            if (line.len == 0) continue;
            try shell.history.append(shell.allocator, try shell.allocator.dupe(u8, line));
        }
    } else {
        const start = history_len - mem.min(usize, &.{ history_len, opt.max_lines orelse history_len });
        for (start..history_len) |i| {
            try stdout.print("{d:5}  {s}\n", .{ i + 1, shell.history.items[i] });
        }
    }
}
