const std = @import("std");
const util = @import("util.zig");
const Parser = @import("parser.zig").Parser;

pub const Shell = struct {
    should_exit: bool = false,
    env: std.process.EnvMap,
    pipe_to: Streams = .{},
    cwd: std.fs.Dir,
    arena: std.heap.ArenaAllocator,
    command: []const u8 = "",
    argv: []const []const u8 = &.{},

    var default_stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
    const default_stdout = &default_stdout_writer.interface;

    var default_stderr_writer = std.fs.File.stderr().writerStreaming(&.{});
    const default_stderr = &default_stderr_writer.interface;

    var default_stdin_buffer: [4096]u8 = undefined;
    var default_stdin_reader = std.fs.File.stdin().readerStreaming(&default_stdin_buffer);
    const default_stdin = &default_stdin_reader.interface;

    pub const Streams = struct {
        stdin: ?*std.Io.Reader = null,
        stdout: ?*std.Io.Writer = null,
        stderr: ?*std.Io.Writer = null,
    };

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
    ) Shell {
        return .{
            .arena = .init(allocator),
            .env = env,
            .cwd = std.fs.cwd(),
        };
    }

    pub fn deinit(self: *Shell) void {
        self.arena.deinit();
    }

    pub fn prompt(self: *Shell, gpa: std.mem.Allocator) !void {
        try default_stdout.print("$ ", .{});

        _ = self.arena.reset(.{ .retain_with_limit = 4096 });
        const allocator = self.arena.allocator();

        var string_builder: std.ArrayList(u8) = .{};
        defer string_builder.deinit(gpa);

        var keep_reading = true;
        while (keep_reading) {
            const char = try default_stdin.takeByte();
            if (char == '\n') {
                keep_reading = false;
            } else {
                try string_builder.append(gpa, char);
            }
        }

        const line = string_builder.items;

        var parser_arena: std.heap.ArenaAllocator = .init(gpa);
        defer parser_arena.deinit();

        var parser: Parser = .init(parser_arena.allocator(), line);
        const tokens = try parser.parse();
        if (tokens.len > 0) {
            self.command = try allocator.dupe(u8, tokens[0]);
            self.argv = if (tokens.len > 1)
                try util.dupe2(allocator, u8, tokens[1..])
            else
                &.{};
        }
    }

    pub fn run(self: *Shell, gpa: std.mem.Allocator) !void {
        const maybe_command_type = try self.typeof(self.command);
        if (maybe_command_type) |command_type| {
            switch (command_type) {
                .Builtin => |builtin| try self.run_builtin(gpa, builtin),
                .Executable => |dir_path| try self.run_executable(gpa, dir_path),
            }
        } else {
            try default_stderr.print("{s}: command not found\n", .{self.command});
        }
    }

    fn run_executable(self: *Shell, gpa: std.mem.Allocator, dir_path: []const u8) !void {
        // const path = try std.fs.path.join(gpa, &.{ dir_path, shell.command });
        // defer gpa.free(path);
        _ = dir_path;

        var argv_list: std.ArrayList([]const u8) = .{};
        defer argv_list.deinit(gpa);
        try argv_list.append(gpa, self.command);
        try argv_list.appendSlice(gpa, self.argv);

        var child: std.process.Child = .init(argv_list.items, gpa);
        child.stdout_behavior = if (self.pipe_to.stdout) |_| .Pipe else .Inherit;
        child.stderr_behavior = if (self.pipe_to.stderr) |_| .Pipe else .Inherit;
        try child.spawn();
        try child.waitForSpawn();
        var stdout_thread: ?std.Thread = null;
        var stderr_thread: ?std.Thread = null;
        if (self.pipe_to.stdout) |pipe_stdout| {
            var buffer: [1024]u8 = undefined;
            var child_stdout_reader = child.stdout.?.readerStreaming(&buffer);
            const child_stdout = &child_stdout_reader.interface;
            stdout_thread = try std.Thread.spawn(.{}, util.pipe, .{ child_stdout, pipe_stdout });
        }
        if (self.pipe_to.stderr) |pipe_stderr| {
            var buffer: [1024]u8 = undefined;
            var child_stderr_reader = child.stderr.?.readerStreaming(&buffer);
            const child_stderr = &child_stderr_reader.interface;
            stderr_thread = try std.Thread.spawn(.{}, util.pipe, .{ child_stderr, pipe_stderr });
        }
        if (stdout_thread) |thread| thread.join();
        if (stderr_thread) |thread| thread.join();
        const status = try child.wait();
        switch (status) {
            // TODO
            else => {},
        }
    }

    fn run_builtin(self: *Shell, gpa: std.mem.Allocator, builtin: BuiltinCommand) !void {
        const stdout = self.pipe_to.stdout orelse default_stdout;
        const stderr = self.pipe_to.stderr orelse default_stderr;
        switch (builtin) {
            .Exit => self.should_exit = true,
            .Echo => {
                for (self.argv, 0..) |arg, i| {
                    try stdout.writeAll(arg);
                    if (i != self.argv.len) {
                        try stdout.writeAll(" ");
                    }
                }
                try stdout.writeByte('\n');
                try stdout.flush();
            },
            .Type => {
                for (self.argv) |command| {
                    const maybe_command_type = try self.typeof(command);
                    if (maybe_command_type) |command_type| {
                        switch (command_type) {
                            .Builtin => |_| try stdout.print("{s} is a shell builtin\n", .{command}),
                            .Executable => |dir_path| try stdout.print(
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
                        try stderr.print("{s}: not found\n", .{command});
                    }
                }
            },
            .PrintWorkingDir => {
                var buffer: [1024]u8 = undefined;
                const path = try self.cwd.realpath(".", &buffer);
                try stdout.print("{s}\n", .{path});
            },
            .ChangeDir => {
                if (self.argv.len == 1) {
                    const arg = self.argv[0];
                    const home_dir = self.env.get("HOME") orelse ".";
                    const path = try std.mem.replaceOwned(u8, gpa, arg, "~", home_dir);
                    defer gpa.free(path);
                    const dir = self.cwd.openDir(path, .{}) catch {
                        try stderr.print("cd: {s}: No such file or directory\n", .{path});
                        return;
                    };
                    try dir.setAsCwd();
                    self.cwd = dir;
                }
            },
        }
    }

    fn typeof(self: *const Shell, command: []const u8) !?CommandType {
        if (builtins.get(command)) |builtin| {
            return .{ .Builtin = builtin };
        } else {
            const maybe_dir = try self.find_executable(command);
            if (maybe_dir) |dir_path| {
                return .{ .Executable = dir_path };
            }
        }
        return null;
    }

    fn find_executable(self: *const Shell, name: []const u8) !?[]const u8 {
        if (self.env.get("PATH")) |path| {
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
