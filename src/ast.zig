const std = @import("std");
const testing = std.testing;
const lex = @import("lex.zig");
const Token = lex.Token;

const log = std.log.scoped(.rz);

pub const Command = union(enum) {
    simple: Simple,
    function: Function,
    assignment: Assignment,
};

pub const Argument = union(enum) {
    word: []const u8,
    quoted_word: []const u8,
    variable: []const u8,
    variable_count: []const u8,
    variable_string: []const u8,
    concatenate: struct {
        lhs: *const Argument,
        rhs: *const Argument,
    },
    list: []const Argument,

    pub fn format(
        self: Argument,
        comptime layout: []const u8,
        opts: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = layout;
        _ = opts;
        switch (self) {
            .concatenate => |concat| try writer.print("{s}^{s}", .{ concat.lhs, concat.rhs }),
            .list => |list| {
                try writer.writeByte('(');
                try writer.writeByte(' ');
                for (list) |arg| {
                    try std.fmt.format(writer, "{s} ", .{arg});
                }
                try writer.writeByte(')');
            },
            .word,
            .quoted_word,
            => |word| try writer.print("{s}", .{word}),
            .variable => |variable| try writer.print("${s}", .{variable}),
            .variable_count => |variable| try writer.print("$#{s}", .{variable}),
            .variable_string => |variable| try writer.print("$\"{s}", .{variable}),
        }
    }
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

pub const Redirection = struct {
    source: union(enum) {
        arg: Argument,
        heredoc: []const u8,
    },
    /// The fd of the command that is affected (could be either redirecting in or out)
    fd: std.posix.fd_t,
    append: bool,
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

    fn nextArgument(self: *Parser) !?Argument {
        const first = self.nextToken() orelse return null;
        switch (first.tag) {
            .word,
            .variable,
            .variable_count,
            .variable_string,
            => {
                var arg: Argument = switch (first.tag) {
                    .word => .{ .word = self.tokenContent(first.loc) },
                    .variable => .{ .variable = self.tokenContent(first.loc) },
                    .variable_count => .{ .variable_count = self.tokenContent(first.loc) },
                    .variable_string => .{ .variable_string = self.tokenContent(first.loc) },
                    else => unreachable,
                };
                // We do this in a loop because we could have multiple concats
                // ie a^b^c
                var tag: Token.Tag = first.tag;
                while (self.freeCaret(tag)) {
                    var next = self.nextToken() orelse unreachable;
                    tag = next.tag;
                    // word followed by any of these results in a concat
                    // if (self.freeCaret(.word))
                    // var next = self.maybeAny(&.{
                    //     .word,
                    //     .quoted_word,
                    //     .variable,
                    //     .variable_count,
                    //     .variable_string,
                    //     .caret,
                    //     .equal,
                    // }) orelse return arg;

                    const lhs = try self.allocator.create(Argument);
                    lhs.* = arg;

                    const rhs = try self.allocator.create(Argument);
                    rhs.* = switch (next.tag) {
                        .caret => blk: {
                            next = self.nextToken() orelse return error.SyntaxError;
                            switch (next.tag) {
                                .word => break :blk .{ .word = self.tokenContent(next.loc) },
                                .quoted_word => break :blk .{ .quoted_word = self.tokenContent(next.loc) },
                                .variable => break :blk .{ .variable = self.tokenContent(next.loc) },
                                .variable_count => break :blk .{ .variable_count = self.tokenContent(next.loc) },
                                .variable_string => break :blk .{ .variable_string = self.tokenContent(next.loc) },
                                else => return error.SyntaxError,
                            }
                        },
                        else => self.tokenToArgument(next),
                    };
                    arg = .{ .concatenate = .{ .lhs = lhs, .rhs = rhs } };
                }
                return arg;
            },
            .l_paren => {
                var list = std.ArrayList(Argument).init(self.allocator);
                while (self.peekToken()) |token| {
                    switch (token.tag) {
                        .wsp => self.eat(.wsp),
                        .eof => return error.SyntaxError,
                        .r_paren => {
                            self.index += 1;
                            // Check for concatenation
                            // var next = self.maybeAny(&.{.caret}) orelse return arg;
                            return .{ .list = list.items };
                        },
                        else => {
                            const next = try self.nextArgument() orelse return error.SyntaxError;
                            switch (next) {
                                .list => |l| {
                                    for (l) |item| {
                                        try list.append(item);
                                    }
                                },
                                else => try list.append(next),
                            }
                        },
                    }
                }
                return error.SyntaxError;
            },
            else => return error.SyntaxError,
        }
        return null;
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
            const rhs = try self.nextArgument() orelse break;
            try locals.append(.{
                .key = self.tokenContent(lhs.loc),
                .value = rhs,
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

        while (self.peekToken()) |token| {
            switch (token.tag) {
                .wsp => self.eat(.wsp),
                .word,
                .variable,
                .variable_count,
                .variable_string,
                .l_paren,
                => {
                    const arg = try self.nextArgument() orelse unreachable;
                    try args.append(arg);
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
                    const append: bool = blk: {
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
                            => break :blk token2,
                            else => return error.SyntaxError,
                        }
                    } else return error.SyntaxError;
                    try redirs.append(.{
                        .source = .{ .arg = self.tokenToArgument(source) },
                        .fd = std.posix.STDOUT_FILENO,
                        .append = append,
                    });
                },
                .semicolon,
                .newline,
                .eof,
                => break,
                else => {},
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

    /// Advances the token by 1 if it is the passed tags. Otherwise, the state is unchanged
    fn maybeAny(self: *Parser, tags: []const Token.Tag) ?Token {
        const tok = self.peekToken() orelse return null;
        for (tags) |tag| {
            if (tok.tag == tag) {
                self.index += 1;
                return tok;
            }
        }
        return null;
    }

    fn eat(self: *Parser, tag: Token.Tag) void {
        while (self.peekToken()) |tok| {
            if (tok.tag == tag)
                self.index += 1
            else
                return;
        }
    }

    fn tokenToArgument(self: Parser, token: Token) Argument {
        switch (token.tag) {
            .word => return .{ .word = self.tokenContent(token.loc) },
            .quoted_word => return .{ .quoted_word = self.tokenContent(token.loc) },
            .variable => return .{ .variable = self.tokenContent(token.loc) },
            .variable_count => return .{ .variable_count = self.tokenContent(token.loc) },
            .variable_string => return .{ .variable_string = self.tokenContent(token.loc) },
            .equal => return .{ .word = self.tokenContent(token.loc) },
            else => unreachable,
        }
    }

    /// Returns true when a free caret should be inserted
    fn freeCaret(self: *Parser, cur: Token.Tag) bool {
        self.eat(.caret);
        const next = self.peekToken() orelse return false;
        switch (cur) {
            .word,
            .equal,
            => switch (next.tag) {
                .word => return true,
                .quoted_word => return true,
                .variable => return true,
                .variable_count => return true,
                .variable_string => return true,
                .equal => return true,
                .l_paren => return true,
                .caret => unreachable,
                else => return false,
            },
            .variable,
            .variable_count,
            .variable_string,
            => switch (next.tag) {
                .word => return true,
                .quoted_word => return true,
                .variable => return true,
                .variable_count => return true,
                .variable_string => return true,
                .equal => return true,
                .l_paren => return false,
                .caret => unreachable,
                else => return false,
            },
            else => return false,
        }
    }
};

test "single simple command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "foo";
    const expect: Command = .{ .simple = .{
        .arguments = &.{
            .{ .word = "foo" },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };
    const cmds = try parse(cmdline, allocator);
    try testing.expectEqual(1, cmds.len);
    try testing.expectEqualDeep(expect, cmds[0]);
}

test "simple command with arg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "foo bar";
    const expect: Command = .{ .simple = .{
        .arguments = &.{
            .{ .word = "foo" },
            .{ .word = "bar" },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };
    const cmds = try parse(cmdline, allocator);
    try testing.expectEqual(1, cmds.len);
    try testing.expectEqualDeep(expect, cmds[0]);
}

test "global assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "foo=bar";
    const expect: Command = .{
        .assignment = .{ .key = "foo", .value = .{ .word = "bar" } },
    };
    const cmds = try parse(cmdline, allocator);
    try testing.expectEqual(1, cmds.len);
    try testing.expectEqualDeep(expect, cmds[0]);
}

test "local assignment with arg containing '='" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "foo=bar baz --foo=bar";
    const expect: Command = .{
        .simple = .{
            .arguments = &.{
                .{ .word = "baz" },
                .{ .concatenate = .{
                    .lhs = &.{
                        .concatenate = .{
                            .lhs = &.{ .word = "--foo" },
                            .rhs = &.{ .word = "=" },
                        },
                    },
                    .rhs = &.{ .word = "bar" },
                } },
            },
            .redirections = &.{},
            .assignments = &.{
                .{ .key = "foo", .value = .{ .word = "bar" } },
            },
        },
    };
    const cmds = try parse(cmdline, allocator);
    try testing.expectEqual(1, cmds.len);
    try testing.expectEqualDeep(expect, cmds[0]);
}

test "explicit concat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "foo^bar";
    const expect: Command = .{ .simple = .{
        .arguments = &.{
            .{
                .concatenate = .{
                    .lhs = &.{ .word = "foo" },
                    .rhs = &.{ .word = "bar" },
                },
            },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };
    const cmds = try parse(cmdline, allocator);
    try testing.expectEqual(1, cmds.len);
    try testing.expectEqualDeep(expect, cmds[0]);
}

test "implicit concat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "foo$bar";
    const expect: Command = .{ .simple = .{
        .arguments = &.{
            .{
                .concatenate = .{
                    .lhs = &.{ .word = "foo" },
                    .rhs = &.{ .variable = "bar" },
                },
            },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };
    const cmds = try parse(cmdline, allocator);
    try testing.expectEqual(1, cmds.len);
    try testing.expectEqualDeep(expect, cmds[0]);
}

test "nested implicit concat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "foo$bar.c";
    const expect: Command = .{ .simple = .{
        .arguments = &.{
            .{
                .concatenate = .{
                    .lhs = &.{
                        .concatenate = .{
                            .lhs = &.{ .word = "foo" },
                            .rhs = &.{ .variable = "bar" },
                        },
                    },
                    .rhs = &.{ .word = ".c" },
                },
            },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };
    const cmds = try parse(cmdline, allocator);
    try testing.expectEqual(1, cmds.len);
    try testing.expectEqualDeep(expect, cmds[0]);
}

test "nested explicit concat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "foo^$bar^.c";
    const expect: Command = .{ .simple = .{
        .arguments = &.{
            .{
                .concatenate = .{
                    .lhs = &.{
                        .concatenate = .{
                            .lhs = &.{ .word = "foo" },
                            .rhs = &.{ .variable = "bar" },
                        },
                    },
                    .rhs = &.{ .word = ".c" },
                },
            },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };
    const cmds = try parse(cmdline, allocator);
    try testing.expectEqual(1, cmds.len);
    try testing.expectEqualDeep(expect, cmds[0]);
}

test "word list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "echo (foo bar)";
    const expect: Command = .{ .simple = .{
        .arguments = &.{
            .{ .word = "echo" },
            .{
                .list = &.{
                    .{ .word = "foo" },
                    .{ .word = "bar" },
                },
            },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };
    const cmds = try parse(cmdline, allocator);
    try testing.expectEqual(1, cmds.len);
    try testing.expectEqualDeep(expect, cmds[0]);
}

test "word list with args and concat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "echo (foo (($bar) $#baz $\"bam $foo^$bar))";
    const expect: Command = .{ .simple = .{
        .arguments = &.{
            .{ .word = "echo" },
            .{
                .list = &.{
                    .{ .word = "foo" },
                    .{ .variable = "bar" },
                    .{ .variable_count = "baz" },
                    .{ .variable_string = "bam" },
                    .{ .concatenate = .{
                        .lhs = &.{ .variable = "foo" },
                        .rhs = &.{ .variable = "bar" },
                    } },
                },
            },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };
    const cmds = try parse(cmdline, allocator);
    try testing.expectEqual(1, cmds.len);
    try testing.expectEqualDeep(expect, cmds[0]);
}

// test "list concatenate" {
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();
//     const cmdline = "echo (foo bar)^(baz bam)";
//     const expect: Command = .{ .simple = .{
//         .arguments = &.{
//             .{ .word = "echo" },
//             .{ .concatenate = .{
//                 .lhs = &.{
//                     .list = &.{
//                         .{ .word = "foo" },
//                         .{ .word = "bar" },
//                     },
//                 },
//                 .rhs = &.{
//                     .list = &.{
//                         .{ .word = "baz" },
//                         .{ .word = "bam" },
//                     },
//                 },
//             } },
//         },
//         .redirections = &.{},
//         .assignments = &.{},
//     } };
//     const cmds = try parse(cmdline, allocator);
//     try testing.expectEqual(1, cmds.len);
//     try testing.expectEqualDeep(expect, cmds[0]);
// }
