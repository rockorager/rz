const std = @import("std");
const lex = @import("lex.zig");
const Token = lex.Token;

pub const Command = union(enum) {
    simple: Simple,
};

/// A command consisting only of words, variables, and redirections
///     echo "hello world"
pub const Simple = struct {
    arguments: []const Argument,
    redirections: []const Redirection,
};

pub const Argument = struct {
    tag: Token.Tag,
    val: []const u8,
};

pub const Redirection = struct {
    source: union(enum) {
        arg: Argument,
        heredoc: []const u8,
    },
    /// The fd of the command that is affected (could be either redirecting in or out)
    fd: std.posix.fd_t,
    truncate: bool,
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

    /// parses a simple command
    fn parseSimple(self: *Parser) !void {
        var args = std.ArrayList(Argument).init(self.allocator);
        var redirs = std.ArrayList(Redirection).init(self.allocator);
        while (self.nextToken()) |token| {
            switch (token.tag) {
                .word,
                .variable,
                .variable_count,
                .variable_string,
                .variable_init,
                => try args.append(.{ .tag = token.tag, .val = self.tokenContent(token.loc) }),
                .l_angle => {
                    // const heredoc: bool = blk: {
                    //     if (self.peekToken() == .l_angle) {
                    //         _ = self.nextToken();
                    //         break :blk true;
                    //     }
                    //     break :blk false;
                    // };
                    // _ = heredoc;
                },
                .r_angle => {
                    const truncate: bool = blk: {
                        const tk = self.peekToken() orelse return error.SyntaxError;
                        if (tk.tag == .r_angle) {
                            _ = self.nextToken();
                            break :blk false;
                        }
                        break :blk true;
                    };
                    const source = blk: while (self.nextToken()) |token2| {
                        switch (token2.tag) {
                            .wsp => continue,
                            .word,
                            .variable,
                            .variable_count,
                            .variable_string,
                            .variable_init,
                            => break :blk token2,
                            else => return error.SyntaxError,
                        }
                    } else return error.SyntaxError;
                    std.log.debug("source: {s}", .{self.tokenContent(source.loc)});
                    try redirs.append(.{
                        .source = .{ .arg = .{ .tag = source.tag, .val = self.tokenContent(source.loc) } },
                        .fd = std.posix.STDOUT_FILENO,
                        .truncate = truncate,
                    });
                },
                else => {},
            }
        }
        try self.commands.append(.{
            .simple = .{ .arguments = args.items, .redirections = redirs.items },
        });
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
