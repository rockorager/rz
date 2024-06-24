const std = @import("std");
const lex = @import("lex.zig");
const Token = lex.Token;

pub const Command = union(enum) {
    simple: Simple,
};

pub const Simple = struct {
    arguments: []const Argument,
};

pub const Argument = struct {
    tag: Token.Tag,
    val: []const u8,
};

const Parser = struct {
    src: []const u8,
    allocator: std.mem.Allocator,
    commands: std.ArrayList(Command),
    tokens: []const Token,
    /// token index
    index: usize = 0,

    fn tokenContent(self: Parser, loc: Token.Loc) []const u8 {
        return self.src[loc.start..loc.end];
    }

    fn nextToken(self: *Parser) ?Token {
        if (self.index >= self.tokens.len) return null;
        defer self.index += 1;
        return self.tokens[self.index];
    }

    fn peekToken(self: *Parser) ?Token {
        if (self.index >= self.tokens.len) return null;
        return self.tokens[self.index];
    }

    fn parseSimple(self: *Parser) !void {
        var args = std.ArrayList(Argument).init(self.allocator);
        while (self.nextToken()) |token| {
            switch (token.tag) {
                .word,
                .variable,
                .variable_count,
                .variable_string,
                .variable_init,
                => try args.append(.{ .tag = token.tag, .val = self.tokenContent(token.loc) }),
                else => {},
            }
        }
        try self.commands.append(.{ .simple = .{ .arguments = args.items } });
    }
};

/// Parses src into a sequence of commands. Allocations are not tracked. Use an arena!
pub fn parse(src: []const u8, arena: std.mem.Allocator) ![]Command {
    var lexer = lex.Tokenizer.init(src);

    // We init capacity to 4:1 ratio. Because maybe median token is is 4 long?
    var tokens = try std.ArrayList(Token).initCapacity(arena, src.len / 4);
    // Consume all the tokens
    while (true) {
        const token = lexer.next();
        try tokens.append(token);
        if (token.tag == .eof) break;
    }

    var parser: Parser = .{
        .allocator = arena,
        .tokens = tokens.items,
        .commands = try std.ArrayList(Command).initCapacity(arena, 1),
        .src = src,
    };
    while (parser.peekToken()) |token| {
        switch (token.tag) {
            .eof => break,
            .wsp => continue,
            .comment => continue,
            .word => try parser.parseSimple(),
            else => {},
        }
    }

    return parser.commands.items;
}
