const std = @import("std");
const lex = @import("lex.zig");
const Token = lex.Token;

const log = std.log.scoped(.rz);

pub const Command = union(enum) {
    simple: Simple,
    function: Function,
    assignment: Assignment,
};

/// A command consisting only of words, variables, and redirections
///     echo "hello world"
pub const Simple = struct {
    arguments: []const Argument,
    redirections: []const Redirection,
    assignments: []const Assignment,
};

pub const Function = struct {
    name: []const u8,
    body: []const u8,
};

pub const Argument = struct {
    tag: Token.Tag,
    val: []const u8,
    // If this argument should be concatenated with the previous argument
    concatenate: bool = false,
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

pub const Assignment = struct {
    key: []const u8,
    value: Argument,
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
            .wsp => parser.index += 1,
            .comment => parser.index += 1,
            .word => try parser.parseSimple(),
            .keyword_fn => try parser.parseFn(),
            else => {
                log.debug("unhandled first token: {}", .{token.tag});
                parser.index += 1;
            },
        }
    }

    return parser.commands.items;
}

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

    fn parseAssignments(self: *Parser) ![]Assignment {
        var locals = std.ArrayList(Assignment).init(self.allocator);
        while (true) {
            self.eat(.wsp);
            const start_index = self.index;
            const lhs = self.want(.word) catch {
                self.index = start_index;
                break;
            };
            _ = self.want(.equal) catch {
                self.index = start_index;
                break;
            };
            const rhs = self.wantAny(&.{
                .word,
                .variable,
                .variable_string,
                .variable_count,
                .variable_init,
                .quoted_word,
            }) catch {
                self.index = start_index;
                break;
            };
            try locals.append(.{
                .key = self.tokenContent(lhs.loc),
                .value = .{
                    .tag = rhs.tag,
                    .val = self.tokenContent(rhs.loc),
                    .concatenate = false,
                },
            });
            self.eat(.wsp);
        }
        return locals.items;
    }

    /// parses a simple command
    fn parseSimple(self: *Parser) !void {
        var args = std.ArrayList(Argument).init(self.allocator);
        var redirs = std.ArrayList(Redirection).init(self.allocator);
        const locals = try self.parseAssignments();

        var free_caret: bool = false;
        while (self.nextToken()) |token| {
            switch (token.tag) {
                .word,
                .variable,
                .variable_count,
                .variable_string,
                .variable_init,
                .equal,
                => {
                    try args.append(.{
                        .tag = token.tag,
                        .val = self.tokenContent(token.loc),
                        .concatenate = free_caret,
                    });
                },
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
                    try redirs.append(.{
                        .source = .{ .arg = .{
                            .tag = source.tag,
                            .val = self.tokenContent(source.loc),
                        } },
                        .fd = std.posix.STDOUT_FILENO,
                        .truncate = truncate,
                    });
                },
                .semicolon,
                .newline,
                => break,
                else => {},
            }

            // Check if we should consider a free caret next time
            switch (token.tag) {
                .word,
                .variable,
                .variable_count,
                .variable_string,
                .variable_init,
                .equal,
                .caret,
                => free_caret = true,
                else => free_caret = false,
            }
        }

        switch (args.items.len) {
            0 => switch (locals.len) {
                1 => try self.commands.append(.{ .assignment = locals[0] }),
                else => {},
            },
            else => try self.commands.append(.{
                .simple = .{
                    .arguments = args.items,
                    .redirections = redirs.items,
                    .assignments = locals,
                },
            }),
        }
    }

    fn parseFn(self: *Parser) !void {
        // first token is 'fn'
        _ = self.nextToken() orelse unreachable;

        _ = try self.want(.wsp);

        const name_tok = self.nextToken() orelse return error.SyntaxError;
        if (name_tok.tag != .word) return error.SyntaxError;
        const name = self.tokenContent(name_tok.loc);

        self.eat(.wsp);

        const opening_bracket = try self.want(.l_bracket);
        const start = opening_bracket.loc.end;

        var count: usize = 1;
        const end: usize = while (self.nextToken()) |tok| {
            switch (tok.tag) {
                .l_bracket => count += 1,
                .r_bracket => count -= 1,
                else => continue,
            }
            if (count == 0) break tok.loc.start;
        } else return error.SyntaxError;
        try self.commands.append(.{ .function = .{ .name = name, .body = self.src[start..end] } });
    }

    fn want(self: *Parser, tag: Token.Tag) !Token {
        const tok = self.nextToken() orelse return error.SyntaxError;
        if (tok.tag != tag) return error.SyntaxError;
        return tok;
    }

    fn wantAny(self: *Parser, tags: []const Token.Tag) !Token {
        const tok = self.nextToken() orelse return error.SyntaxError;
        for (tags) |tag| {
            if (tok.tag == tag) return tok;
        }
        return error.SyntaxError;
    }

    fn eat(self: *Parser, tag: Token.Tag) void {
        while (self.peekToken()) |tok| {
            if (tok.tag == tag)
                self.index += 1
            else
                return;
        }
    }
};
