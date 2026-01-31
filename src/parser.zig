const std = @import("std");
const scanner = @import("scanner.zig");
const Token = scanner.Token;
const TokenKind = scanner.TokenKind;

pub const Expr = union(enum) {
    Pipeline: []const *Expr,
    Redirect: struct {
        command: *Expr,
        file_descriptor: u8,
        output_file: []const u8,
        append: bool,
    },
    Command: struct {
        name: []const u8,
        arguments: []const []const u8,
    },
};

pub const Parser = struct {
    tokens: []const Token,
    current: usize = 0,

    pub const Error = error{
        OutOfMemory,
        ExpectedCommand,
        ExpectedString,
    };

    fn isAtEnd(self: *const Parser) bool {
        return self.current >= self.tokens.len;
    }

    fn peek(self: *const Parser) ?Token {
        return if (self.isAtEnd())
            null
        else
            self.tokens[self.current];
    }

    fn check(self: *const Parser, kind: TokenKind) bool {
        if (self.peek()) |token| {
            return token == kind;
        }
        return false;
    }

    fn consume(self: *Parser, kind: TokenKind) error{ExpectedOtherTokenKind}!Token {
        if (self.check(kind)) {
            return self.advance().?;
        }
        return error.ExpectedOtherTokenKind;
    }

    fn advance(self: *Parser) ?Token {
        if (!self.isAtEnd()) {
            self.current += 1;
            return self.tokens[self.current - 1];
        }
        return null;
    }

    pub fn parse(self: *Parser, arena: *std.heap.ArenaAllocator) Error!?*Expr {
        if (!self.isAtEnd()) {
            const allocator = arena.allocator();
            return try self.pipeline(allocator);
        }
        return null;
    }

    fn pipeline(self: *Parser, allocator: std.mem.Allocator) Error!*Expr {
        const lhs = try self.redirect(allocator);
        if (self.check(.Pipe)) {
            var pipeline_list: std.ArrayList(*Expr) = .{};
            try pipeline_list.append(allocator, lhs);
            while (self.check(.Pipe)) {
                _ = self.advance();
                try pipeline_list.append(
                    allocator,
                    try self.redirect(allocator),
                );
            }
            const expr = try allocator.create(Expr);
            expr.* = .{
                .Pipeline = try pipeline_list.toOwnedSlice(allocator),
            };
            return expr;
        }
        return lhs;
    }

    fn redirect(self: *Parser, allocator: std.mem.Allocator) Error!*Expr {
        const lhs = try self.command(allocator);
        if (self.check(.Redirect)) {
            const token = self.advance().?;
            const rhs_token =
                self.consume(.String) catch return error.ExpectedString;

            const expr = try allocator.create(Expr);
            expr.* = .{
                .Redirect = .{
                    .command = lhs,
                    .file_descriptor = token.Redirect.file_descriptor,
                    .output_file = try allocator.dupe(u8, rhs_token.String),
                    .append = token.Redirect.append,
                },
            };
            return expr;
        }
        return lhs;
    }

    fn command(self: *Parser, allocator: std.mem.Allocator) Error!*Expr {
        const name_token =
            self.consume(.String) catch return error.ExpectedCommand;
        const name = try allocator.dupe(u8, name_token.String);

        var arguments_list: std.ArrayList([]const u8) = .{};
        // Include itself as first argument
        try arguments_list.append(allocator, name);
        while (self.check(.String)) {
            const token = self.advance().?;
            const arg = try allocator.dupe(u8, token.String);
            try arguments_list.append(allocator, arg);
        }

        const expr = try allocator.create(Expr);
        expr.* = .{
            .Command = .{
                .name = name,
                .arguments = try arguments_list.toOwnedSlice(allocator),
            },
        };
        return expr;
    }
};
