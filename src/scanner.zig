const std = @import("std");
const ascii = std.ascii;

const Allocator = std.mem.Allocator;

pub const TokenKind = enum {
    Pipe,
    Redirect,
    String,
};

pub const Token = union(TokenKind) {
    Pipe: void,
    Redirect: struct {
        file_descriptor: u8,
        append: bool,
    },
    String: []const u8,
};

pub const Scanner = struct {
    source: []const u8,
    current: usize = 0,
    tokens: std.ArrayList(Token) = .{},
    allocator: Allocator,

    pub fn init(allocator: Allocator, source: []const u8) Scanner {
        return .{
            .allocator = allocator,
            .source = source,
        };
    }

    pub fn deinit(self: *Scanner) void {
        for (self.tokens.items) |token| {
            if (token == .String)
                self.allocator.free(token.String);
        }
        self.tokens.deinit(self.allocator);
    }

    fn isAtEnd(self: *const Scanner) bool {
        return self.current >= self.source.len;
    }

    fn peekN(self: *const Scanner, n: usize) ?u8 {
        return if (self.current + n >= self.source.len)
            null
        else
            self.source[self.current + n];
    }

    fn peek(self: *const Scanner) ?u8 {
        return self.peekN(0);
    }

    fn advance(self: *Scanner) ?u8 {
        if (!self.isAtEnd()) {
            self.current += 1;
            return self.source[self.current - 1];
        }
        return null;
    }

    pub fn scan(self: *Scanner) Allocator.Error![]const Token {
        while (!self.isAtEnd()) {
            if (try self.scanToken()) |token| {
                try self.tokens.append(self.allocator, token);
            }
        }
        return self.tokens.items;
    }

    fn scanToken(self: *Scanner) Allocator.Error!?Token {
        while (self.peek()) |char| {
            switch (char) {
                ' ', '\r', '\t', '\n' => _ = self.advance(), // Skip whitespaces
                '|' => {
                    _ = self.advance();
                    return .{ .Pipe = undefined };
                },
                else => {
                    const isDigit = ascii.isDigit(char);
                    const isRedirect = char == '>' or (isDigit and self.peekN(1) == '>');
                    if (isRedirect) {
                        const number = if (isDigit) char - '0' else 1;
                        if (isDigit) _ = self.advance();

                        _ = self.advance();

                        const append = self.peek() == '>';
                        if (append) _ = self.advance();

                        return .{
                            .Redirect = .{
                                .file_descriptor = number,
                                .append = append,
                            },
                        };
                    } else {
                        return try self.scanString();
                    }
                },
            }
        }
        return null;
    }

    fn scanString(self: *Scanner) Allocator.Error!?Token {
        var char_list: std.ArrayList(u8) = .{};
        var escape_next = false;
        while (self.peek()) |char| {
            if (escape_next) {
                _ = self.advance();
                try char_list.append(self.allocator, char);
                escape_next = false;
            } else {
                switch (char) {
                    '\'' => try self.scanSingleQuotedString(&char_list),
                    '"' => try self.scanDoubleQuotedString(&char_list),
                    '\\' => {
                        _ = self.advance();
                        escape_next = true;
                    },
                    ' ', '\r', '\t', '\n' => {
                        _ = self.advance();
                        break;
                    },
                    '>', '|' => break,
                    else => {
                        _ = self.advance();
                        try char_list.append(self.allocator, char);
                    },
                }
            }
        }
        if (char_list.items.len == 0) {
            char_list.deinit(self.allocator);
            return null;
        } else {
            return .{ .String = try char_list.toOwnedSlice(self.allocator) };
        }
    }

    fn scanSingleQuotedString(self: *Scanner, char_list: *std.ArrayList(u8)) Allocator.Error!void {
        _ = self.advance(); // Consume '
        while (self.advance()) |char| {
            if (char == '\'') break;
            try char_list.append(self.allocator, char);
        }
    }

    fn scanDoubleQuotedString(self: *Scanner, char_list: *std.ArrayList(u8)) Allocator.Error!void {
        _ = self.advance(); // Consume "
        var escape = false;
        while (self.advance()) |char| {
            if (escape) {
                switch (char) {
                    '"', '\\' => {},
                    else => try char_list.append(self.allocator, '\\'),
                }
            } else {
                switch (char) {
                    '"' => break,
                    '\\' => {
                        escape = true;
                        continue;
                    },
                    else => {},
                }
            }
            escape = false;
            try char_list.append(self.allocator, char);
        }
    }
};

// Tests

const testing = std.testing;

fn printToken(tk: Token) void {
    switch (tk) {
        .Pipe => std.debug.print("|", .{}),
        .String => |str| std.debug.print("{s}", .{str}),
        .Redirect => |red| std.debug.print("{d}>{s}", .{
            red.file_descriptor,
            if (red.append) ">" else "",
        }),
    }
}

fn printTokenSlice(tks: []const Token) void {
    for (tks, 0..) |tk, i| {
        printToken(tk);
        if (i + 1 < tks.len)
            std.debug.print(" ", .{});
    }
}

fn expectEqualTokenSlice(expect: []const Token, actual: []const Token) !void {
    errdefer {
        std.debug.print("Expected: ", .{});
        printTokenSlice(expect);
        std.debug.print("\n", .{});
        std.debug.print("Found: ", .{});
        printTokenSlice(actual);
        std.debug.print("\n", .{});
    }
    try testing.expectEqual(expect.len, actual.len);
    for (expect, 0..) |tk_e, i| {
        const tk_a = actual[i];
        try testing.expectEqualStrings(
            @tagName(std.meta.activeTag(tk_e)),
            @tagName(std.meta.activeTag(tk_a)),
        );
        switch (tk_e) {
            .Pipe => {},
            .String => |str_e| try testing.expectEqualStrings(str_e, tk_a.String),
            .Redirect => |red_e| {
                try testing.expectEqual(red_e.file_descriptor, tk_a.Redirect.file_descriptor);
                try testing.expectEqual(red_e.append, tk_a.Redirect.append);
            },
        }
    }
}

const TestCase = struct {
    input: []const u8,
    expect: []const Token,
};

test "memory management" {
    var scanner: Scanner = .init(testing.allocator, "echo 'hello world' banana \"mango\"\\ pineapple");
    defer scanner.deinit();
    _ = try scanner.scan();
}

test "basic tokenization" {
    const cases: []const TestCase = &.{
        .{
            .input = "echo banana mango pineapple",
            .expect = &.{
                .{ .String = "echo" },
                .{ .String = "banana" },
                .{ .String = "mango" },
                .{ .String = "pineapple" },
            },
        },
        .{
            .input = "type -l -2 123 hello",
            .expect = &.{
                .{ .String = "type" },
                .{ .String = "-l" },
                .{ .String = "-2" },
                .{ .String = "123" },
                .{ .String = "hello" },
            },
        },
    };

    for (cases) |case| {
        var scanner = Scanner.init(testing.allocator, case.input);
        defer scanner.deinit();
        const tokens = try scanner.scan();
        try expectEqualTokenSlice(case.expect, tokens);
    }
}

test "operators and redirections" {
    const cases: []const TestCase = &.{
        .{
            .input = "ls | grep .zig > out.txt",
            .expect = &.{
                .{ .String = "ls" },
                .{ .Pipe = {} },
                .{ .String = "grep" },
                .{ .String = ".zig" },
                .{ .Redirect = .{ .file_descriptor = 1, .append = false } },
                .{ .String = "out.txt" },
            },
        },
        .{
            .input = "run 2>> error.log 1>info.log",
            .expect = &.{
                .{ .String = "run" },
                .{ .Redirect = .{ .file_descriptor = 2, .append = true } },
                .{ .String = "error.log" },
                .{ .Redirect = .{ .file_descriptor = 1, .append = false } },
                .{ .String = "info.log" },
            },
        },
    };

    for (cases) |case| {
        var scanner = Scanner.init(testing.allocator, case.input);
        defer scanner.deinit();
        const tokens = try scanner.scan();
        try expectEqualTokenSlice(case.expect, tokens);
    }
}

test "quoting and escaping" {
    const cases: []const TestCase = &.{
        .{
            .input = "echo 'hello > | >>'",
            .expect = &.{
                .{ .String = "echo" },
                .{ .String = "hello > | >>" },
            },
        },
        .{
            .input = "echo \"He said \\\"hi\\\"\"",
            .expect = &.{
                .{ .String = "echo" },
                .{ .String = "He said \"hi\"" },
            },
        },
        .{
            .input = "ls \\| file\\ name",
            .expect = &.{
                .{ .String = "ls" },
                .{ .String = "|" },
                .{ .String = "file name" },
            },
        },
    };

    for (cases) |case| {
        var scanner = Scanner.init(testing.allocator, case.input);
        defer scanner.deinit();
        const tokens = try scanner.scan();
        try expectEqualTokenSlice(case.expect, tokens);
    }
}

test "scanner edge cases" {
    const cases: []const TestCase = &.{
        .{
            .input = "",
            .expect = &.{},
        },
        .{
            .input = "cat2>file|grep'single'2>>out",
            .expect = &.{
                .{ .String = "cat2" },
                .{ .Redirect = .{ .file_descriptor = 1, .append = false } },
                .{ .String = "file" },
                .{ .Pipe = {} },
                .{ .String = "grepsingle2" },
                .{ .Redirect = .{ .file_descriptor = 1, .append = true } },
                .{ .String = "out" },
            },
        },
        .{
            .input = "echo \\\\ \"\\\\\" \\ \\ ",
            .expect = &.{
                .{ .String = "echo" },
                .{ .String = "\\" },
                .{ .String = "\\" },
                .{ .String = "  " },
            },
        },
    };

    for (cases) |case| {
        var scanner = Scanner.init(testing.allocator, case.input);
        defer scanner.deinit();
        const tokens = try scanner.scan();
        try expectEqualTokenSlice(case.expect, tokens);
    }
}
