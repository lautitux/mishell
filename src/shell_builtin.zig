const std = @import("std");
const tools = @import("tools.zig");
const Writer = std.Io.Writer;
const EnvMap = std.process.EnvMap;

pub const BuiltinError = error{
    ShouldExit,
};

pub const Builtin = enum {
    Exit,
    Echo,
    Type,
};

pub const commands: std.StaticStringMap(Builtin) = .initComptime(&.{
    .{ "exit", .Exit },
    .{ "echo", .Echo },
    .{ "type", .Type },
});

pub fn exec_command(command: Builtin, env: EnvMap, stdout: *Writer, arguments: []const u8) !void {
    switch (command) {
        .Exit => try exit_command(env, stdout, arguments),
        .Echo => try echo_command(env, stdout, arguments),
        .Type => try type_command(env, stdout, arguments),
    }
}

fn exit_command(_: EnvMap, _: *Writer, _: []const u8) !void {
    return BuiltinError.ShouldExit;
}

fn echo_command(_: EnvMap, stdout: *Writer, arguments: []const u8) !void {
    try stdout.print("{s}\n", .{arguments});
}

fn type_command(env: EnvMap, stdout: *Writer, arguments: []const u8) !void {
    const key = std.mem.trim(u8, arguments, " \t\r");
    if (commands.has(key)) {
        try stdout.print("{s} is a shell builtin\n", .{key});
    } else {
        const maybe_dir = try tools.find_executable(env, key);
        if (maybe_dir) |dir| {
            try stdout.print("{s} is {s}{c}{s}\n", .{ key, dir, std.fs.path.sep, key });
        } else {
            try stdout.print("{s}: not found\n", .{key});
        }
    }
}
