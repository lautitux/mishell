const std = @import("std");
const util = @import("util.zig");
const Scanner = @import("scanner.zig").Scanner;
const parser_mod = @import("parser.zig");
const Parser = parser_mod.Parser;
const Ast = parser_mod.Ast;

pub const Shell = struct {
    should_exit: bool = false,
    env: std.process.EnvMap,
    pipe_to: Streams = .{},
    cwd: std.fs.Dir,
    arena: std.heap.ArenaAllocator,
    ast: ?*Ast = null,

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
        _ = allocator;
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

        var scanner_arena: std.heap.ArenaAllocator = .init(gpa);
        defer scanner_arena.deinit();

        var scanner: Scanner = .init(scanner_arena.allocator(), line);
        const tokens = try scanner.scan();
        if (tokens.len > 0) {
            var parser: Parser = .{ .tokens = tokens };
            self.ast = try parser.parse(&self.arena);
            // std.debug.print("[AST {any}]\n", .{self.ast});
        } else {
            self.ast = null;
        }
    }

    pub fn run(self: *Shell, gpa: std.mem.Allocator) !void {
        if (self.ast) |ast| {
            switch (ast.*) {
                .Command => |cmd| {
                    self.pipe_to = .{};
                    try self.runCommand(gpa, cmd.name, cmd.arguments);
                },
                .Binary => |binary| {
                    switch (binary.op) {
                        .RedirectStdout,
                        .RedirectStderr,
                        .RedirectAppendStdout,
                        .RedirectAppendStderr,
                        => {
                            std.debug.assert(binary.lhs.* == .Command);
                            std.debug.assert(binary.rhs.* == .Literal);
                            const opt: std.fs.File.CreateFlags =
                                .{
                                    .truncate = binary.op == .RedirectStdout or binary.op == .RedirectStderr,
                                };
                            var file = try self.cwd.createFile(binary.rhs.Literal, opt);
                            defer file.close();
                            if (!opt.truncate) {
                                try file.seekFromEnd(0);
                            }
                            var file_writer = file.writerStreaming(&.{});
                            if (binary.op == .RedirectStdout or binary.op == .RedirectAppendStdout) {
                                self.pipe_to = .{ .stdout = &file_writer.interface };
                            } else if (binary.op == .RedirectStderr or binary.op == .RedirectAppendStderr) {
                                self.pipe_to = .{ .stderr = &file_writer.interface };
                            }
                            try self.runCommand(gpa, binary.lhs.Command.name, binary.lhs.Command.arguments);
                        },
                    }
                },
                .Literal => return error.UnexpectedLiteral,
            }
        }
    }

    fn runCommand(
        self: *Shell,
        gpa: std.mem.Allocator,
        command: []const u8,
        arguments: []const []const u8,
    ) !void {
        const maybe_command_type = try self.typeof(command);
        if (maybe_command_type) |command_type| {
            switch (command_type) {
                .Builtin => |builtin| try self.runBuiltin(gpa, builtin, arguments),
                .Executable => |dir_path| try self.runExe(gpa, dir_path, command, arguments),
            }
        } else {
            try default_stderr.print("{s}: command not found\n", .{command});
        }
    }

    fn runExe(
        self: *Shell,
        gpa: std.mem.Allocator,
        dir_path: []const u8,
        command: []const u8,
        arguments: []const []const u8,
    ) !void {
        // const path = try std.fs.path.join(gpa, &.{ dir_path, shell.command });
        // defer gpa.free(path);
        _ = dir_path;

        var argv_list: std.ArrayList([]const u8) = .{};
        defer argv_list.deinit(gpa);
        try argv_list.append(gpa, command);
        try argv_list.appendSlice(gpa, arguments);

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

    fn runBuiltin(
        self: *Shell,
        gpa: std.mem.Allocator,
        builtin: BuiltinCommand,
        arguments: []const []const u8,
    ) !void {
        const stdout = self.pipe_to.stdout orelse default_stdout;
        const stderr = self.pipe_to.stderr orelse default_stderr;
        switch (builtin) {
            .Exit => self.should_exit = true,
            .Echo => {
                for (arguments, 0..) |arg, i| {
                    try stdout.writeAll(arg);
                    if (i != arguments.len) {
                        try stdout.writeAll(" ");
                    }
                }
                try stdout.writeByte('\n');
                try stdout.flush();
            },
            .Type => {
                for (arguments) |command| {
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
                if (arguments.len == 1) {
                    const arg = arguments[0];
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
