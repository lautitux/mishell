const std = @import("std");
const Writer = std.Io.Writer;

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

pub fn exec_command(command: Builtin, stdout: *Writer, arguments: []const u8) BuiltinError!void {
    switch (command) {
        .Exit => try exit_command(stdout, arguments),
        .Echo => try echo_command(stdout, arguments),
        .Type => try type_command(stdout, arguments),
    }
}

fn exit_command(_: *Writer, _: []const u8) BuiltinError!void {
    return BuiltinError.ShouldExit;
}

fn echo_command(stdout: *Writer, arguments: []const u8) BuiltinError!void {
    stdout.print("{s}\n", .{arguments}) catch return error.ShouldExit;
}

fn type_command(stdout: *Writer, arguments: []const u8) BuiltinError!void {
    const key = std.mem.trim(u8, arguments, " \t\r");
    if (commands.has(key)) {
        stdout.print("{s} is a shell builtin\n", .{key}) catch return error.ShouldExit;
    } else {
        stdout.print("{s}: not found\n", .{key}) catch return error.ShouldExit;
    }
}
