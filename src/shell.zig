const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const util = @import("util.zig");
const builtins = @import("builtins.zig");
const parser_mod = @import("parser.zig");
const Scanner = @import("scanner.zig").Scanner;
const Subprocess = @import("subprocess.zig").Subprocess;
const Console = @import("readline.zig").Console;
const Thread = std.Thread;
const Parser = parser_mod.Parser;
const Expr = parser_mod.Expr;

pub const Shell = struct {
    should_exit: bool = false,
    env: std.process.EnvMap,
    io: IoFiles,
    cwd: fs.Dir,
    allocator: std.mem.Allocator,
    arena_allocator: std.heap.ArenaAllocator,
    expr: ?*Expr = null,
    history: std.ArrayList([]const u8) = .{},
    last_stored_history: usize = 0,

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
        History,
    };

    const builtins_map: std.StaticStringMap(BuiltinCommand) = .initComptime(&.{
        .{ "exit", .Exit },
        .{ "echo", .Echo },
        .{ "type", .Type },
        .{ "pwd", .PrintWorkingDir },
        .{ "cd", .ChangeDir },
        .{ "history", .History },
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
            .allocator = allocator,
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
        for (self.history.items) |entry| {
            self.allocator.free(entry);
        }
        self.history.deinit(self.allocator);
    }

    // Returns true if succesful, that means that shell.run may be called
    pub fn prompt(self: *Shell) !bool {
        _ = self.arena_allocator.reset(.retain_capacity);
        self.expr = null;

        var scanner_arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer scanner_arena.deinit();
        const scanner_allocator = scanner_arena.allocator();

        const console: Console = .{
            .stdin = self.io.stdin,
            .stdout = self.io.stdout,
            .history = self.history.items,
            .completion = .{
                .keywords = builtins_map.keys(),
                .path = self.env.get("PATH"),
                .search_in_cwd = true,
            },
        };

        const input = console.prompt(self.allocator, "$ ") catch |err| {
            switch (err) {
                error.EndOfText => return false,
                error.EndOfTransmission => {
                    self.should_exit = true;
                    return false;
                },
                else => return err,
            }
        };
        defer self.allocator.free(input);

        try self.history.append(
            self.allocator,
            try self.allocator.dupe(u8, input),
        );

        var stderr_w = self.io.stderr.writerStreaming(&.{});
        const stderr = &stderr_w.interface;

        var scanner: Scanner = .init(scanner_allocator, input);
        const tokens = scanner.scan() catch {
            try stderr.print("scanner: out of memory\n", .{});
            return false;
        };

        if (tokens.len > 0) {
            var parser: Parser = .{ .tokens = tokens };
            self.expr = parser.parse(&self.arena_allocator) catch |err| {
                try stderr.print("parser: {s}\n", .{@errorName(err)});
                return false;
            };
            return true;
        }

        self.expr = null;
        return false;
    }

    pub fn run(self: *Shell) !void {
        var stderr_w = self.io.stderr.writerStreaming(&.{});
        const stderr = &stderr_w.interface;

        if (self.expr) |expr| {
            self.evalExpr(self.allocator, expr, null) catch |err| {
                try stderr.print("error: {s}\n", .{@errorName(err)});
            };
        }
    }

    fn evalExpr(self: *Shell, gpa: std.mem.Allocator, expr: *Expr, override_io: ?IoFiles) !void {
        const io = override_io orelse self.io;
        var stderr_w = io.stderr.writerStreaming(&.{});
        const stderr = &stderr_w.interface;
        switch (expr.*) {
            .Command => |cmd| {
                if (try self.typeof(cmd.name)) |cmd_kind| {
                    switch (cmd_kind) {
                        .Builtin => |builtin| try self.runBuiltin(builtin, cmd.arguments[1..], io),
                        .Executable => |dir_path| try self.runExe(cmd.name, dir_path, cmd.arguments, io),
                    }
                    // Cleanup
                    if (io.stdin.handle != self.io.stdin.handle) io.stdin.close();
                    if (io.stdout.handle != self.io.stdout.handle) io.stdout.close();
                    if (io.stderr.handle != self.io.stderr.handle) io.stderr.close();
                } else {
                    try stderr.print("{s}: command not found\n", .{cmd.name});
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
                const shell_f: fs.File, const new_io_f: *fs.File =
                    if (redirect.file_descriptor == 0)
                        .{ self.io.stdin, &new_io.stdin }
                    else if (redirect.file_descriptor == 1)
                        .{ self.io.stdout, &new_io.stdout }
                    else if (redirect.file_descriptor == 2)
                        .{ self.io.stderr, &new_io.stderr }
                    else
                        return error.UnsupportedRedirect;
                if (shell_f.handle == new_io_f.handle) {
                    new_io_f.* = file;
                } else {
                    new_io_f.close();
                    new_io_f.* = file;
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

    fn runExe(
        self: *Shell,
        exe_name: []const u8,
        dir_path: []const u8,
        arguments: []const []const u8,
        io: IoFiles,
    ) !void {
        var dir = try fs.openDirAbsolute(dir_path, .{});
        defer dir.close();
        const exe_absolute_path = try dir.realpathAlloc(self.allocator, exe_name);
        defer self.allocator.free(exe_absolute_path);
        var subprocess: Subprocess = .{
            .allocator = self.allocator,
            .exe_absolute_path = exe_absolute_path,
            .argv = arguments,
            .env_map = &self.env,
            .stdin = io.stdin,
            .stdout = io.stdout,
            .stderr = io.stderr,
        };
        try subprocess.spawn();
        _ = try subprocess.wait();
    }

    fn runBuiltin(
        self: *Shell,
        builtin: BuiltinCommand,
        arguments: []const []const u8,
        io: IoFiles,
    ) !void {
        var stdout_w = io.stdout.writerStreaming(&.{});
        const stdout = &stdout_w.interface;

        var stderr_w = io.stderr.writerStreaming(&.{});
        const stderr = &stderr_w.interface;

        switch (builtin) {
            .Exit => builtins.exit(self),
            .Echo => try builtins.echo(stdout, arguments),
            .Type => try builtins._type(self, stdout, stderr, arguments),
            .PrintWorkingDir => try builtins.pwd(self, stdout),
            .ChangeDir => try builtins.cd(self, stderr, arguments),
            .History => try builtins.history(self, stdout, stderr, arguments),
        }
    }

    pub fn loadHistory(self: *Shell, file: fs.File) !void {
        var buffer: [1024]u8 = undefined;
        var file_r = file.readerStreaming(&buffer);
        const file_stream = &file_r.interface;
        while (try file_stream.takeDelimiter('\n')) |line| {
            if (line.len == 0) continue;
            try self.history.append(self.allocator, try self.allocator.dupe(u8, line));
        }
    }

    pub fn storeHistory(self: *Shell, file: fs.File, opt: struct { only_new: bool = false }) !void {
        var buffer: [1024]u8 = undefined;
        var file_w = file.writerStreaming(&buffer);
        const file_stream = &file_w.interface;

        const start = if (opt.only_new) self.last_stored_history else 0;
        const history_len = self.history.items.len;
        for (start..history_len) |i| {
            const entry = self.history.items[i];
            _ = try file_stream.write(entry);
            _ = try file_stream.write(&.{'\n'});
        }
        try file_stream.flush();
        try file_stream.writeByte('\n');

        if (opt.only_new) {
            self.last_stored_history = history_len;
        }
    }

    pub fn typeof(self: *const Shell, command: []const u8) !?CommandKind {
        if (builtins_map.get(command)) |builtin| {
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
                var dir = fs.openDirAbsolute(dir_path, .{}) catch continue;
                defer dir.close();
                const is_exec = util.isExecutable(dir, name) catch continue;
                if (is_exec) return dir_path;
            }
        }
        return null;
    }
};
