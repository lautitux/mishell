const std = @import("std");
const fs = std.fs;
const Thread = std.Thread;
const util = @import("util.zig");
const Scanner = @import("scanner.zig").Scanner;
const parser_mod = @import("parser.zig");
const Parser = parser_mod.Parser;
const Expr = parser_mod.Expr;

pub const Shell = struct {
    should_exit: bool = false,
    env: std.process.EnvMap,
    io: IoFiles,
    cwd: fs.Dir,
    arena_allocator: std.heap.ArenaAllocator,
    expr: ?*Expr = null,

    pub const IoFiles = struct {
        stdin: fs.File,
        stdout: fs.File,
        stderr: fs.File,
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

    const CommandKind = union(enum) {
        Builtin: BuiltinCommand,
        Executable: []const u8,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        env: std.process.EnvMap,
    ) Shell {
        return .{
            .arena_allocator = .init(allocator),
            .env = env,
            .cwd = fs.cwd(),
            .io = .{
                .stdin = fs.File.stdin(),
                .stdout = fs.File.stdout(),
                .stderr = fs.File.stderr(),
            },
        };
    }

    pub fn deinit(self: *Shell) void {
        self.arena_allocator.deinit();
    }

    pub fn prompt(self: *Shell, gpa: std.mem.Allocator) !void {
        var stdin_buf: [512]u8 = undefined;
        var stdin_r = self.io.stdin.readerStreaming(&stdin_buf);
        const stdin = &stdin_r.interface;

        var stdout_w = self.io.stdout.writerStreaming(&.{});
        const stdout = &stdout_w.interface;

        try stdout.print("$ ", .{});

        _ = self.arena_allocator.reset(.retain_capacity);

        var scanner_arena: std.heap.ArenaAllocator = .init(gpa);
        defer scanner_arena.deinit();
        const scanner_allocator = scanner_arena.allocator();

        var string_builder: std.ArrayList(u8) = .{};
        defer string_builder.deinit(scanner_allocator);

        var keep_reading = true;
        while (keep_reading) {
            const char = try stdin.takeByte();
            if (char == '\n') {
                keep_reading = false;
            } else {
                try string_builder.append(scanner_allocator, char);
            }
        }

        const line = string_builder.items;

        var scanner: Scanner = .init(scanner_allocator, line);
        const tokens = try scanner.scan();
        if (tokens.len > 0) {
            var parser: Parser = .{ .tokens = tokens };
            self.expr = try parser.parse(&self.arena_allocator);
        } else {
            self.expr = null;
        }
    }

    pub fn run(self: *Shell, gpa: std.mem.Allocator) !void {
        if (self.expr) |expr| {
            try self.evalExpr(gpa, expr, null);
        }
    }

    fn evalExpr(self: *Shell, gpa: std.mem.Allocator, expr: *Expr, override_io: ?IoFiles) !void {
        const io = override_io orelse self.io;
        switch (expr.*) {
            .Command => |cmd| {
                if (try self.typeof(cmd.name)) |cmd_kind| {
                    switch (cmd_kind) {
                        .Builtin => |builtin| try self.runBuiltin(gpa, builtin, cmd.arguments, io),
                        .Executable => |dir_path| {
                            var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
                            defer arena_allocator.deinit();
                            const arena = arena_allocator.allocator();
                            const path = try fs.path.joinZ(arena, &.{ dir_path, cmd.name });
                            const argv = try arena.allocSentinel(?[*:0]const u8, cmd.arguments.len + 1, null);
                            argv[0] = try arena.dupeZ(u8, cmd.name);
                            for (1..argv.len) |i|
                                argv[i] = try arena.dupeZ(u8, cmd.arguments[i - 1]);
                            const environ = try std.process.createEnvironFromMap(arena, &self.env, .{});
                            const pid = try std.posix.fork();
                            if (pid == 0) {
                                try std.posix.dup2(io.stdin.handle, std.posix.STDIN_FILENO);
                                try std.posix.dup2(io.stdout.handle, std.posix.STDOUT_FILENO);
                                try std.posix.dup2(io.stderr.handle, std.posix.STDERR_FILENO);
                                const err = std.posix.execveZ(path, argv, environ);
                                switch (err) {
                                    else => {},
                                }
                                std.process.exit(0);
                            } else {
                                _ = std.posix.waitpid(pid, 0);
                            }
                        },
                    }
                    // Cleanup
                    if (io.stdin.handle != self.io.stdin.handle) {
                        io.stdin.close();
                    }
                    if (io.stdout.handle != self.io.stdout.handle) {
                        io.stdout.close();
                    }
                    if (io.stderr.handle != self.io.stderr.handle) {
                        io.stderr.close();
                    }
                }
            },
            .Redirect => |redirect| {
                var file = try self.cwd.createFile(
                    redirect.output_file,
                    .{ .truncate = !redirect.append },
                );
                if (redirect.append)
                    try file.seekFromEnd(0);
                var new_io = io;
                if (redirect.file_descriptor == 0) {
                    new_io.stdin = file;
                } else if (redirect.file_descriptor == 1) {
                    new_io.stdout = file;
                } else if (redirect.file_descriptor == 2) {
                    new_io.stderr = file;
                } else {
                    return error.UnsupportedRedirect;
                }
                try self.evalExpr(gpa, redirect.command, new_io);
            },
            .Pipeline => |pipeline| {
                std.debug.assert(pipeline.len > 1);
                var processes = try gpa.alloc(Thread, pipeline.len);
                defer gpa.free(processes);
                var prev_pipe_read: ?std.posix.fd_t = null;
                for (pipeline, 0..) |sub_expr, i| {
                    const is_last = i == pipeline.len - 1;
                    var pipe: ?[2]std.posix.fd_t = null;
                    if (!is_last) {
                        pipe = try std.posix.pipe2(.{ .CLOEXEC = true });
                    }
                    const new_io: IoFiles = .{
                        .stdin = if (prev_pipe_read) |fd| .{ .handle = fd } else io.stdin,
                        .stdout = if (pipe) |p| .{ .handle = p[1] } else io.stdout,
                        .stderr = io.stderr,
                    };
                    processes[i] = try .spawn(.{}, Shell.evalExpr, .{
                        self,
                        gpa,
                        sub_expr,
                        new_io,
                    });
                    prev_pipe_read = if (pipe) |p| p[0] else null;
                }
                for (processes) |thread| thread.join();
            },
        }
    }

    fn runBuiltin(
        self: *Shell,
        gpa: std.mem.Allocator,
        builtin: BuiltinCommand,
        arguments: []const []const u8,
        override_io: ?IoFiles,
    ) !void {
        const io = override_io orelse self.io;

        var stdout_w = io.stdout.writerStreaming(&.{});
        const stdout = &stdout_w.interface;

        var stderr_w = io.stderr.writerStreaming(&.{});
        const stderr = &stderr_w.interface;

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
                                    fs.path.sep,
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

    fn typeof(self: *const Shell, command: []const u8) !?CommandKind {
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
                var dir = try fs.openDirAbsolute(dir_path, .{});
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
