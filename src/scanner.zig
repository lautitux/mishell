const std = @import("std");
const ascii = std.ascii;

pub const TokenKind = enum {
    Redirect,
    String,
};

pub const Token = union(TokenKind) {
    Redirect: u8,
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
                '>' => {
                    _ = self.advance();
                    return .{ .Redirect = 1 };
                },
                else => {
                    const isRedirect = ascii.isDigit(char) and (self.peekN(1) orelse 0 == '>');
                    if (isRedirect) {
                        const number = char - '0';
                        _ = self.advance();
                        _ = self.advance();
                        return .{ .Redirect = number };
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
                    ' ', '\r', '\t', '\n', '>' => break,
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
