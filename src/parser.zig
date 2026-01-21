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

    fn peek(self: *const Parser) ?u8 {
        return if (self.isAtEnd())
            null
        else
            self.source[self.current];
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
        var char_list: std.ArrayList(u8) = .{};
        var escape_next = false;
        while (self.advance()) |char| {
            if (escape_next) {
                try char_list.append(self.allocator, char);
                escape_next = false;
            } else {
                switch (char) {
                    '\'' => try self.parseSingleQuotedString(&char_list),
                    '"' => try self.parseDoubleQuotedString(&char_list),
                    '\\' => escape_next = true,
                    ' ', '\r', '\t', '\n' => break,
                    else => try char_list.append(self.allocator, char),
                }
            }
        }
        if (char_list.items.len == 0) {
            char_list.deinit(self.allocator);
            return null;
        } else {
            return char_list.items;
        }
    }

    fn parseSingleQuotedString(self: *Parser, char_list: *std.ArrayList(u8)) !void {
        while (self.advance()) |char| {
            if (char == '\'') break;
            try char_list.append(self.allocator, char);
        }
    }

    fn parseDoubleQuotedString(self: *Parser, char_list: *std.ArrayList(u8)) !void {
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
