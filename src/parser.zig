const std = @import("std");
const scanner = @import("scanner.zig");
const Token = scanner.Token;
const TokenKind = scanner.TokenKind;

pub const Operator = enum {};

pub const Expr = union(enum) {
    // Binary: struct { lhs: *Expr, op: Operator, rhs: *Expr },
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
    Literal: []const u8,
};

pub const Parser = struct {
    tokens: []const Token,
    current: usize = 0,

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

    fn consume(self: *Parser, kind: TokenKind) !Token {
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

    pub fn parse(self: *Parser, arena: *std.heap.ArenaAllocator) !?*Expr {
        if (!self.isAtEnd()) {
            const allocator = arena.allocator();
            return try self.redirect(allocator);
        }
        return null;
    }

    fn redirect(self: *Parser, allocator: std.mem.Allocator) !*Expr {
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

    fn command(self: *Parser, allocator: std.mem.Allocator) !*Expr {
        const name_token =
            self.consume(.String) catch return error.ExpectedString;
        const name = try allocator.dupe(u8, name_token.String);

        var arguments_list: std.ArrayList([]const u8) = .{};
        while (self.check(.String)) {
            const token = self.advance().?;
            const arg = try allocator.dupe(u8, token.String);
            try arguments_list.append(allocator, arg);
        }

        const expr = try allocator.create(Expr);
        expr.* = .{
            .Command = .{
                .name = name,
                .arguments = arguments_list.items,
            },
        };
        return expr;
    }

    fn literal(self: *Parser, allocator: std.mem.Allocator) !*Expr {
        const token = self.consume(.String) catch return error.ExpectedString;
        const value = try allocator.dupe(u8, token.String);
        const expr = try allocator.create(Expr);
        expr.* = .{
            .Literal = value,
        };
        return expr;
    }
};
