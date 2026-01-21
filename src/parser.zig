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
        while (self.peek()) |char| {
            switch (char) {
                ' ', '\r', '\t', '\n' => _ = self.advance(), // Skip whitespaces
                else => return try self.parseString(),
            }
        }
        return null;
    }

    pub fn parseString(self: *Parser) !?Token {
        var string_list: std.ArrayList(u8) = .{};
        while (self.advance()) |char| {
            switch (char) {
                '\'' => {
                    while (self.advance()) |inner_char| {
                        if (inner_char == '\'') break;
                        try string_list.append(self.allocator, inner_char);
                    }
                },
                ' ', '\r', '\t', '\n' => break,
                else => try string_list.append(self.allocator, char),
            }
        }
        if (string_list.items.len == 0) {
            string_list.deinit(self.allocator);
            return null;
        } else {
            return string_list.items;
        }
    }
};
