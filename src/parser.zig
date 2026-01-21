const std = @import("std");

pub const Token = []const u8;

pub const Parser = struct {
    source: []const u8,
    current: usize = 0,
    tokens: std.ArrayList(Token) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .source = source,
        };
    }

    pub fn deinit(self: *Parser) void {
        for (self.tokens) |token| {
            self.allocator.free(token);
        }
        self.tokens.deinit(self.allocator);
    }

    fn isAtEnd(self: *const Parser) bool {
        return self.current >= self.source.len;
    }

    fn previous(self: *const Parser) ?u8 {
        return if (self.current > 0)
            self.source[self.current - 1]
        else
            null;
    }

    fn peek(self: *const Parser) ?u8 {
        return if (self.isAtEnd())
            null
        else
            self.source[self.current];
    }

    fn peek2(self: *const Parser) ?u8 {
        return if (self.current + 1 >= self.source.len)
            null
        else
            self.source[self.current + 1];
    }

    fn advance(self: *Parser) ?u8 {
        if (!self.isAtEnd()) {
            self.current += 1;
            return self.source[self.current - 1];
        }
        return null;
    }

    pub fn parse(self: *Parser) ![]const Token {
        while (!self.isAtEnd()) {
            if (try self.parseToken()) |token| {
                try self.tokens.append(self.allocator, token);
            }
        }
        return self.tokens.items;
    }

    pub fn parseToken(self: *Parser) !?Token {
        while (self.advance()) |char| {
            switch (char) {
                '\'' => return try self.parseSingleQuoteString(),
                ' ', '\r', '\t', '\n' => {}, // Skip whitespaces
                else => return try self.parseWord(),
            }
        }
        return null;
    }

    pub fn parseSingleQuoteString(self: *Parser) !?Token {
        var str_list: std.ArrayList(u8) = .{};
        while (self.advance()) |char| {
            if (char == '\'') {
                if (self.peek() orelse ' ' == '\'') {
                    // Concatenate contigous strings
                    _ = self.advance();
                } else {
                    break;
                }
            } else {
                try str_list.append(self.allocator, char);
            }
        }
        if (str_list.items.len == 0) {
            str_list.deinit(self.allocator);
            return null;
        } else {
            return str_list.items;
        }
    }

    pub fn parseWord(self: *Parser) !Token {
        var word_list: std.ArrayList(u8) = .{};
        try word_list.append(self.allocator, self.previous().?);
        while (self.peek()) |char| {
            if (char == '\'' and self.peek2() orelse ' ' == '\'') {
                // Ignore empty string
                _ = self.advance();
                _ = self.advance();
            } else if (char == '\'' or std.ascii.isWhitespace(char)) {
                break;
            } else {
                try word_list.append(self.allocator, self.advance().?);
            }
        }
        return word_list.items;
    }
};
