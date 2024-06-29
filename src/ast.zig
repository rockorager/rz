const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const lex = @import("lex.zig");
const Token = lex.Token;

const log = std.log.scoped(.rz);

pub const Error = error{
    SyntaxError,
    OutOfMemory,
};

pub const Command = union(enum) {
    simple: Simple, // echo foo bar
    function: Function, // fn foo {...}
    assignment: Assignment, // foo=$bar
    group: []const Command, // {foo;bar}
    if_zero, // &&
    if_nonzero, // ||
    pipe: Pipe,
};

pub const Pipe = struct {
    lhs: *const Command,
    rhs: *const Command,
};

pub const Argument = union(enum) {
    word: []const u8,
    quoted_word: []const u8,
    variable: []const u8,
    variable_count: []const u8,
    variable_string: []const u8,
    variable_subscript: struct {
        key: []const u8,
        fields: *const Argument,
    },
    concatenate: struct {
        lhs: *const Argument,
        rhs: *const Argument,
    },
    list: []const Argument,
    substitution: []const Command,

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
            .variable_subscript => |variable| try writer.print("${s}{}", .{ variable.key, variable.fields }),
            .substitution => |sub| try writer.print("`{{{any}}}", .{sub}),
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
    direction: enum {
        in,
        out,
    },
    append: bool,
    fd: posix.fd_t,
    /// File *could* be more information for redirection, however this is easier parsed at execution
    /// eg: it could be a concat of the form [2^=^1], which resolves to [2=1]. The interpreter will need
    /// to handle this
    file: Argument,
};

pub const Assignment = struct {
    key: []const u8,
    value: Argument,
};

/// Parses src into a sequence of commands. Allocations are not tracked. Use an arena!
pub fn parse(src: []const u8, arena: std.mem.Allocator) Error![]Command {
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
    return parser.parseTokens();
}

const Parser = struct {
    src: []const u8,
    allocator: std.mem.Allocator,
    commands: std.ArrayList(Command),
    tokens: []const Token,
    /// token index
    index: usize = 0,
    /// When we encounter a pipe, we allocate our previous command onto the stack and store it here.
    /// When we get our next command we will construct our pipe command
    pipe: ?*const Command = null,

    fn parseTokens(self: *Parser) Error![]Command {
        while (self.peekToken()) |token| {
            switch (token.tag) {
                .eof => break,
                .wsp,
                .comment,
                .newline,
                => self.index += 1,
                .word,
                .variable,
                .backtick_l_brace,
                => try self.parseSimple(),
                .l_brace => {
                    self.index += 1;
                    // parse group wants us to consume the first brace
                    const cmds = try self.parseGroup();
                    try self.appendCommand(.{ .group = cmds });
                },
                .keyword_fn => try self.parseFn(),
                .ampersand_ampersand => {
                    self.index += 1;
                    try self.appendCommand(.if_zero);
                },
                .pipe_pipe => {
                    self.index += 1;
                    try self.appendCommand(.if_nonzero);
                },
                .pipe => {
                    if (self.commands.items.len == 0) return error.SyntaxError;
                    self.index += 1;
                    const lhs = try self.allocator.create(Command);
                    lhs.* = self.commands.pop();
                    self.pipe = lhs;
                },
                else => {
                    log.debug("unhandled first token: {}", .{token.tag});
                    self.index += 1;
                },
            }
        }
        return self.commands.items;
    }

    fn appendCommand(self: *Parser, cmd: Command) Error!void {
        if (self.pipe) |lhs| {
            const rhs = try self.allocator.create(Command);
            rhs.* = cmd;
            const pipe: Command = .{ .pipe = .{ .lhs = lhs, .rhs = rhs } };
            try self.commands.append(pipe);
            self.pipe = null;
            return;
        }
        try self.commands.append(cmd);
    }

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

    fn nextArgument(self: *Parser) Error!?Argument {
        const first = self.nextToken() orelse return null;
        switch (first.tag) {
            .word,
            .quoted_word,
            .variable,
            .variable_count,
            .variable_string,
            .equal,
            => {
                const arg: Argument = switch (first.tag) {
                    .word => .{ .word = self.tokenContent(first.loc) },
                    .quoted_word => .{ .quoted_word = self.tokenContent(first.loc) },
                    .variable => blk: {
                        if (self.peekToken()) |token| {
                            switch (token.tag) {
                                .l_paren => {
                                    const fields = try self.nextArgument() orelse return error.SyntaxError;
                                    const arg = try self.allocator.create(Argument);
                                    arg.* = fields;
                                    break :blk .{ .variable_subscript = .{
                                        .key = self.tokenContent(first.loc),
                                        .fields = arg,
                                    } };
                                },
                                else => {},
                            }
                        }

                        break :blk .{ .variable = self.tokenContent(first.loc) };
                    },
                    .variable_count => .{ .variable_count = self.tokenContent(first.loc) },
                    .variable_string => .{ .variable_string = self.tokenContent(first.loc) },
                    .equal => .{ .word = self.tokenContent(first.loc) },
                    else => unreachable,
                };
                const final = try self.checkConcat(arg);
                return final;
            },
            .l_paren => {
                var list = std.ArrayList(Argument).init(self.allocator);
                while (self.peekToken()) |token| {
                    switch (token.tag) {
                        .wsp => self.eat(.wsp),
                        .eof => return error.SyntaxError,
                        .r_paren => {
                            self.index += 1;
                            const final = try self.checkConcat(.{ .list = list.items });
                            return final;
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
            .backtick_l_brace,
            => {
                const cmds = try self.parseGroup();
                return .{ .substitution = cmds };
            },
            else => return error.SyntaxError,
        }
        return null;
    }

    fn parseGroup(self: *Parser) Error![]Command {
        const start = self.index;
        var brace_cnt: usize = 1;
        const end = while (self.nextToken()) |tok| {
            switch (tok.tag) {
                .l_brace,
                .l_angle_l_brace,
                .r_angle_l_brace,
                .backtick_l_brace,
                => brace_cnt += 1,
                .r_brace => {
                    brace_cnt -|= 1;
                    if (brace_cnt == 0) break self.index -| 1;
                },
                else => {},
            }
        } else return error.SyntaxError;

        var parser: Parser = .{
            .allocator = self.allocator,
            .tokens = self.tokens[start..end],
            .commands = try std.ArrayList(Command).initCapacity(self.allocator, 1),
            .src = self.src,
        };
        return parser.parseTokens();
    }

    fn parseAssignments(self: *Parser) Error![]Assignment {
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
    fn parseSimple(self: *Parser) Error!void {
        var args = std.ArrayList(Argument).init(self.allocator);
        var redirs = std.ArrayList(Redirection).init(self.allocator);
        const locals = try self.parseAssignments();

        while (self.peekToken()) |token| {
            switch (token.tag) {
                .wsp => self.eat(.wsp),
                .word,
                .quoted_word,
                .variable,
                .variable_count,
                .variable_string,
                .l_paren,
                .backtick_l_brace,
                => {
                    const arg = try self.nextArgument() orelse unreachable;
                    try args.append(arg);
                },
                .l_angle,
                .r_angle,
                .r_angle_r_angle,
                => {
                    const redir = try self.parseRedirection();
                    try redirs.append(redir);
                },
                .l_angle_l_angle => {}, // heredoc
                .l_angle_l_brace,
                .r_angle_l_brace,
                .l_angle_r_angle_l_brace,
                => {}, // pipefile redirection
                .semicolon,
                .newline,
                .eof,
                .ampersand,
                .ampersand_ampersand,
                .pipe,
                .pipe_pipe,
                => break,
                else => {
                    log.warn("unhandled token: {}", .{token});
                    self.index += 1;
                },
            }
        }

        switch (args.items.len) {
            0 => switch (locals.len) {
                1 => try self.appendCommand(.{ .assignment = locals[0] }),
                else => {},
            },
            else => try self.appendCommand(.{
                .simple = .{
                    .arguments = args.items,
                    .redirections = redirs.items,
                    .assignments = locals,
                },
            }),
        }
    }

    fn parseRedirection(self: *Parser) Error!Redirection {
        const first = self.nextToken() orelse unreachable;
        var redir: Redirection = undefined;

        switch (first.tag) {
            .l_angle => {
                redir.direction = .in;
                redir.append = false;
                redir.fd = posix.STDIN_FILENO;
            },
            .r_angle => {
                redir.direction = .out;
                redir.append = false;
                redir.fd = posix.STDOUT_FILENO;
            },
            .r_angle_r_angle => {
                redir.direction = .out;
                redir.append = true;
                redir.fd = posix.STDOUT_FILENO;
            },
            else => unreachable,
        }

        blk: {
            if (self.maybeAny(&.{.wsp})) |_| {
                redir.file = try self.nextArgument() orelse return error.SyntaxError;
                break :blk;
            }
            const arg = try self.nextArgument() orelse return error.SyntaxError;
            switch (arg) {
                .word => |val| {
                    // >[2] <file>
                    // >[2=] or >[2=1] will be concats that the interpreter handles
                    if (val[0] != '[') {
                        redir.file = arg;
                        break :blk;
                    }
                    const end = std.mem.indexOfScalarPos(u8, val, 1, ']') orelse return error.SyntaxError;
                    redir.fd = std.fmt.parseUnsigned(u16, val[1..end], 10) catch return error.SyntaxError;
                    self.eat(.wsp);
                    redir.file = try self.nextArgument() orelse return error.SyntaxError;
                },
                else => redir.file = arg,
            }
        }
        return redir;
    }

    fn parseFn(self: *Parser) Error!void {
        // first token is 'fn'
        _ = self.nextToken() orelse unreachable;

        _ = try self.want(.wsp);

        const name_tok = self.nextToken() orelse return error.SyntaxError;
        if (name_tok.tag != .word) return error.SyntaxError;
        const name = self.tokenContent(name_tok.loc);

        self.eat(.wsp);

        const opening_brace = try self.want(.l_brace);
        const start = opening_brace.loc.end;

        var count: usize = 1;
        const end: usize = while (self.nextToken()) |tok| {
            switch (tok.tag) {
                .l_brace,
                .l_angle_l_brace,
                .r_angle_l_brace,
                .backtick_l_brace,
                => count += 1,
                .r_brace => count -= 1,
                else => continue,
            }
            if (count == 0) break tok.loc.start;
        } else return error.SyntaxError;
        try self.appendCommand(.{ .function = .{ .name = name, .body = self.src[start..end] } });
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

    fn checkConcat(self: *Parser, arg: Argument) Error!Argument {
        var local = arg;
        while (self.freeCaret(local)) {
            const lhs = try self.allocator.create(Argument);
            lhs.* = arg;

            const rhs = try self.allocator.create(Argument);
            rhs.* = try self.nextArgument() orelse unreachable;
            local = .{ .concatenate = .{ .lhs = lhs, .rhs = rhs } };
        }
        return local;
    }

    /// Returns true when a free caret should be inserted
    fn freeCaret(self: *Parser, cur: Argument) bool {
        self.eat(.caret);
        const next = self.peekToken() orelse return false;
        switch (cur) {
            .word,
            .quoted_word,
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
            .list => switch (next.tag) {
                .l_paren => return true,
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
                    .lhs = &.{ .word = "--foo" },
                    .rhs = &.{
                        .concatenate = .{
                            .lhs = &.{ .word = "=" },
                            .rhs = &.{ .word = "bar" },
                        },
                    },
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
                    .lhs = &.{ .word = "foo" },
                    .rhs = &.{
                        .concatenate = .{
                            .lhs = &.{ .variable = "bar" },
                            .rhs = &.{ .word = ".c" },
                        },
                    },
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
                    .lhs = &.{ .word = "foo" },
                    .rhs = &.{
                        .concatenate = .{
                            .lhs = &.{ .variable = "bar" },
                            .rhs = &.{ .word = ".c" },
                        },
                    },
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

test "list concatenate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "echo (foo bar)^(baz bam)";
    const expect: Command = .{ .simple = .{
        .arguments = &.{
            .{ .word = "echo" },
            .{ .concatenate = .{
                .lhs = &.{
                    .list = &.{
                        .{ .word = "foo" },
                        .{ .word = "bar" },
                    },
                },
                .rhs = &.{
                    .list = &.{
                        .{ .word = "baz" },
                        .{ .word = "bam" },
                    },
                },
            } },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };
    const cmds = try parse(cmdline, allocator);
    try testing.expectEqual(1, cmds.len);
    try testing.expectEqualDeep(expect, cmds[0]);
}

test "variable subscript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "$foo(1 2 3)";
    const expect: Command = .{ .simple = .{
        .arguments = &.{
            .{
                .variable_subscript = .{
                    .key = "foo",
                    .fields = &.{
                        .list = &.{
                            .{ .word = "1" },
                            .{ .word = "2" },
                            .{ .word = "3" },
                        },
                    },
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

test "redirection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "echo >foo >>[2] bar <[2=1]";
    const expect: Command = .{
        .simple = .{
            .arguments = &.{.{ .word = "echo" }},
            .redirections = &.{
                .{
                    .direction = .out,
                    .append = false,
                    .fd = posix.STDOUT_FILENO,
                    .file = .{ .word = "foo" },
                },
                .{
                    .direction = .out,
                    .append = true,
                    .fd = 2,
                    .file = .{ .word = "bar" },
                },
                .{
                    .direction = .in,
                    .append = false,
                    .fd = posix.STDIN_FILENO,
                    .file = .{ .concatenate = .{
                        .lhs = &.{ .word = "[2" },
                        .rhs = &.{ .concatenate = .{
                            .lhs = &.{ .word = "=" },
                            .rhs = &.{ .word = "1]" },
                        } },
                    } },
                },
            },
            .assignments = &.{},
        },
    };
    const cmds = try parse(cmdline, allocator);
    try testing.expectEqual(1, cmds.len);
    try testing.expectEqualDeep(expect, cmds[0]);
}

test "global assignment from command substitution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "foo=`{bar}";
    const cmd: Command = .{ .simple = .{
        .arguments = &.{
            .{ .word = "bar" },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };

    const expect: Command = .{
        .assignment = .{ .key = "foo", .value = .{ .substitution = &.{cmd} } },
    };
    const cmds = try parse(cmdline, allocator);
    try testing.expectEqual(1, cmds.len);
    try testing.expectEqualDeep(expect, cmds[0]);
}

test "group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "{echo foo; echo bar}";
    const cmd1: Command = .{ .simple = .{
        .arguments = &.{
            .{ .word = "echo" },
            .{ .word = "foo" },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };
    const cmd2: Command = .{ .simple = .{
        .arguments = &.{
            .{ .word = "echo" },
            .{ .word = "bar" },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };

    const expect: Command = .{
        .group = &.{ cmd1, cmd2 },
    };
    const cmds = try parse(cmdline, allocator);
    try testing.expectEqual(1, cmds.len);
    try testing.expectEqualDeep(expect, cmds[0]);
}

test "&&" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "ls && echo foo";
    const cmd1: Command = .{ .simple = .{
        .arguments = &.{
            .{ .word = "ls" },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };
    const cmd2: Command = .if_zero;
    const cmd3: Command = .{ .simple = .{
        .arguments = &.{
            .{ .word = "echo" },
            .{ .word = "foo" },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };

    const cmds = try parse(cmdline, allocator);
    try testing.expectEqual(3, cmds.len);
    try testing.expectEqualDeep(cmd1, cmds[0]);
    try testing.expectEqualDeep(cmd2, cmds[1]);
    try testing.expectEqualDeep(cmd3, cmds[2]);
}

test "||" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "ls || echo foo";
    const cmd1: Command = .{ .simple = .{
        .arguments = &.{
            .{ .word = "ls" },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };
    const cmd2: Command = .if_nonzero;
    const cmd3: Command = .{ .simple = .{
        .arguments = &.{
            .{ .word = "echo" },
            .{ .word = "foo" },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };

    const cmds = try parse(cmdline, allocator);
    try testing.expectEqual(3, cmds.len);
    try testing.expectEqualDeep(cmd1, cmds[0]);
    try testing.expectEqualDeep(cmd2, cmds[1]);
    try testing.expectEqualDeep(cmd3, cmds[2]);
}

test "pipe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cmdline = "ls | echo foo";
    const cmd1: Command = .{ .simple = .{
        .arguments = &.{
            .{ .word = "ls" },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };
    const cmd2: Command = .{ .simple = .{
        .arguments = &.{
            .{ .word = "echo" },
            .{ .word = "foo" },
        },
        .redirections = &.{},
        .assignments = &.{},
    } };

    const pipe: Pipe = .{ .lhs = &cmd1, .rhs = &cmd2 };
    const cmd: Command = .{ .pipe = pipe };
    const cmds = try parse(cmdline, allocator);
    try testing.expectEqual(1, cmds.len);
    try testing.expectEqualDeep(cmd, cmds[0]);
}
