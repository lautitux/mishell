const std = @import("std");

pub const Shell = struct {
    should_exit: bool = false,
    env: std.process.EnvMap,
    stdout: *std.Io.Writer,
    stdin: *std.Io.Reader,
    cwd: std.fs.Dir,
    arena: std.heap.ArenaAllocator,
    command: []const u8 = "",
    argv: []const []const u8 = &.{},

    const BuiltinCommand = enum {
        Exit,
        Echo,
        Type,
        PrintWorkingDir,
        ChangeDir,
    };

    const builtins: std.StaticStringMap(BuiltinCommand) = .initComptime(&.{
        .{ "exit", .Exit },
        .{ "echo", .Echo },
        .{ "type", .Type },
        .{ "pwd", .PrintWorkingDir },
        .{ "cd", .ChangeDir },
    });

    const CommandType = union(enum) {
        Builtin: BuiltinCommand,
        Executable: []const u8,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        env: std.process.EnvMap,
        stdout: *std.Io.Writer,
        stdin: *std.Io.Reader,
    ) Shell {
        return .{
            .arena = .init(allocator),
            .env = env,
            .stdout = stdout,
            .stdin = stdin,
            .cwd = std.fs.cwd(),
        };
    }

    pub fn deinit(shell: *Shell) void {
        shell.arena.deinit();
    }

    pub fn prompt(shell: *Shell, gpa: std.mem.Allocator) !void {
        try shell.stdout.print("$ ", .{});

        _ = shell.arena.reset(.{ .retain_with_limit = 4096 });
        const allocator = shell.arena.allocator();

        var string_builder: std.ArrayList(u8) = .{};
        defer string_builder.deinit(gpa);

        var keep_reading = true;
        while (keep_reading) {
            const char = try shell.stdin.takeByte();
            if (char == '\n') {
                keep_reading = false;
            } else {
                try string_builder.append(gpa, char);
            }
        }

        const line = string_builder.items;
        const delimiter = std.mem.indexOfAny(u8, line, " \t\r");
        const command = if (delimiter) |pos| line[0..pos] else line;
        const argv_str = if (delimiter) |pos| line[(pos + 1)..] else "";

        var iter = std.mem.splitAny(u8, argv_str, " \t\r");
        var argv: std.ArrayList([]const u8) = .{};
        defer argv.deinit(gpa);

        while (iter.next()) |arg| {
            if (arg.len != 0) {
                try argv.append(gpa, try allocator.dupe(u8, arg));
            }
        }

        shell.command = try allocator.dupe(u8, command);
        shell.argv = try allocator.dupe([]const u8, argv.items);
    }

    pub fn run(shell: *Shell, gpa: std.mem.Allocator) !void {
        const maybe_command_type = try shell.typeof(shell.command);
        if (maybe_command_type) |command_type| {
            switch (command_type) {
                .Builtin => |builtin| try shell.run_builtin(builtin),
                .Executable => |dir_path| try shell.run_executable(gpa, dir_path),
            }
        } else {
            try shell.stdout.print("{s}: command not found\n", .{shell.command});
        }
    }

    fn run_executable(shell: *Shell, gpa: std.mem.Allocator, dir_path: []const u8) !void {
        // const path = try std.fs.path.join(gpa, &.{ dir_path, shell.command });
        // defer gpa.free(path);
        _ = dir_path;

        var argv_list: std.ArrayList([]const u8) = .{};
        defer argv_list.deinit(gpa);
        try argv_list.append(gpa, shell.command);
        try argv_list.appendSlice(gpa, shell.argv);

        var child: std.process.Child = .init(argv_list.items, gpa);
        try child.spawn();
        const status = try child.wait();
        switch (status) {
            // TODO
            else => {},
        }
    }

    fn run_builtin(shell: *Shell, builtin: BuiltinCommand) !void {
        switch (builtin) {
            .Exit => shell.should_exit = true,
            .Echo => {
                for (shell.argv, 0..) |arg, i| {
                    try shell.stdout.writeAll(arg);
                    if (i != shell.argv.len) {
                        try shell.stdout.writeAll(" ");
                    }
                }
                try shell.stdout.writeByte('\n');
                try shell.stdout.flush();
            },
            .Type => {
                for (shell.argv) |command| {
                    const maybe_command_type = try shell.typeof(command);
                    if (maybe_command_type) |command_type| {
                        switch (command_type) {
                            .Builtin => |_| try shell.stdout.print("{s} is a shell builtin\n", .{command}),
                            .Executable => |dir_path| try shell.stdout.print(
                                "{s} is {s}{c}{s}\n",
                                .{
                                    command,
                                    dir_path,
                                    std.fs.path.sep,
                                    command,
                                },
                            ),
                        }
                    } else {
                        try shell.stdout.print("{s}: not found\n", .{command});
                    }
                }
            },
            .PrintWorkingDir => {
                var buffer: [1024]u8 = undefined;
                const path = try shell.cwd.realpath(".", &buffer);
                try shell.stdout.print("{s}\n", .{path});
            },
            .ChangeDir => {
                if (shell.argv.len == 1) {
                    const path = shell.argv[0];
                    const dir = shell.cwd.openDir(path, .{}) catch {
                        try shell.stdout.print("cd: {s}: No such file or directory\n", .{path});
                        return;
                    };
                    shell.cwd = dir;
                }
            },
        }
    }

    fn typeof(shell: *const Shell, command: []const u8) !?CommandType {
        if (builtins.get(command)) |builtin| {
            return .{ .Builtin = builtin };
        } else {
            const maybe_dir = try shell.find_executable(command);
            if (maybe_dir) |dir_path| {
                return .{ .Executable = dir_path };
            }
        }
        return null;
    }

    fn find_executable(shell: *const Shell, name: []const u8) !?[]const u8 {
        if (shell.env.get("PATH")) |path| {
            var iter = std.mem.splitScalar(u8, path, ':');
            while (iter.next()) |dir_path| {
                var dir = try std.fs.openDirAbsolute(dir_path, .{});
                defer dir.close();
                const stat = dir.statFile(name) catch continue;
                const permissions = stat.mode & 0o7777;
                if (permissions & 0o111 > 0) {
                    return dir_path;
                }
            }
        }
        return null;
    }
};
