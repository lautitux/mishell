const std = @import("std");
const scanner = @import("scanner.zig");
const Token = scanner.Token;
const TokenKind = scanner.TokenKind;

pub const Operator = enum {
    RedirectStdout,
    RedirectStderr,
    RedirectAppendStdout,
    RedirectAppendStderr,
};

pub const Ast = union(enum) {
    Binary: struct { lhs: *Ast, op: Operator, rhs: *Ast },
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

    pub fn parse(self: *Parser, arena: *std.heap.ArenaAllocator) !?*Ast {
        if (!self.isAtEnd()) {
            const allocator = arena.allocator();
            return try self.redirect(allocator);
        }
        return null;
    }

    pub fn redirect(self: *Parser, allocator: std.mem.Allocator) !*Ast {
        const lhs = try self.command(allocator);
        if (self.check(.Redirect) or self.check(.RedirectAppend)) {
            const token = self.advance().?;
            const rhs = self.literal(allocator) catch return error.ExpectedLiteral;
            const op: Operator =
                if (token == .Redirect and token.Redirect == 1)
                    .RedirectStdout
                else if (token == .Redirect and token.Redirect == 2)
                    .RedirectStderr
                else if (token == .RedirectAppend and token.RedirectAppend == 1)
                    .RedirectAppendStdout
                else if (token == .RedirectAppend and token.RedirectAppend == 2)
                    .RedirectAppendStderr
                else
                    return error.InvalidRedirectNumber;
            const expr = try allocator.create(Ast);
            expr.* = .{
                .Binary = .{
                    .lhs = lhs,
                    .op = op,
                    .rhs = rhs,
                },
            };
            return expr;
        }
        return lhs;
    }

    pub fn command(self: *Parser, allocator: std.mem.Allocator) !*Ast {
        const name_token = self.consume(.String) catch return error.ExpectedString;
        const name = try allocator.dupe(u8, name_token.String);
        var arguments_list: std.ArrayList([]const u8) = .{};
        while (self.check(.String)) {
            const token = self.advance().?;
            const arg = try allocator.dupe(u8, token.String);
            try arguments_list.append(allocator, arg);
        }
        const expr = try allocator.create(Ast);
        expr.* = .{
            .Command = .{
                .name = name,
                .arguments = arguments_list.items,
            },
        };
        return expr;
    }

    pub fn literal(self: *Parser, allocator: std.mem.Allocator) !*Ast {
        const token = self.consume(.String) catch return error.ExpectedString;
        const value = try allocator.dupe(u8, token.String);
        const expr = try allocator.create(Ast);
        expr.* = .{
            .Literal = value,
        };
        return expr;
    }
};
