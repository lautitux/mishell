const std = @import("std");
const ascii = std.ascii;

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
    String: []u8,
};

pub const Scanner = struct {
    source: []const u8,
    current: usize = 0,
    tokens: std.ArrayList(Token) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Scanner {
        return .{
            .allocator = allocator,
            .source = source,
        };
    }

    pub fn deinit(self: *Scanner) void {
        for (self.tokens) |token| {
            self.allocator.free(token);
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

    pub fn scan(self: *Scanner) ![]const Token {
        while (!self.isAtEnd()) {
            if (try self.scanToken()) |token| {
                try self.tokens.append(self.allocator, token);
            }
        }
        return self.tokens.items;
    }

    pub fn scanToken(self: *Scanner) !?Token {
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

                        return if (number < 0 or number > 2)
                            error.UnsupportedFileDescriptor
                        else
                            .{
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

    pub fn scanString(self: *Scanner) !?Token {
        var char_list: std.ArrayList(u8) = .{};
        var escape_next = false;
        while (self.advance()) |char| {
            if (escape_next) {
                try char_list.append(self.allocator, char);
                escape_next = false;
            } else {
                switch (char) {
                    '\'' => try self.scanSingleQuotedString(&char_list),
                    '"' => try self.scanDoubleQuotedString(&char_list),
                    '\\' => escape_next = true,
                    ' ', '\r', '\t', '\n', '>', '|' => break,
                    else => try char_list.append(self.allocator, char),
                }
            }
        }
        if (char_list.items.len == 0) {
            char_list.deinit(self.allocator);
            return null;
        } else {
            return .{ .String = char_list.items };
        }
    }

    fn scanSingleQuotedString(self: *Scanner, char_list: *std.ArrayList(u8)) !void {
        while (self.advance()) |char| {
            if (char == '\'') break;
            try char_list.append(self.allocator, char);
        }
    }

    fn scanDoubleQuotedString(self: *Scanner, char_list: *std.ArrayList(u8)) !void {
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
