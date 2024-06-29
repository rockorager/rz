const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;

const non_word_bytes = " \t\r\n#;&|^$`'{}()<>=~!@";

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "case", .keyword_case },
        .{ "fn", .keyword_fn },
        .{ "for", .keyword_for },
        .{ "if", .keyword_if },
        .{ "in", .keyword_in },
        .{ "else", .keyword_else },
        .{ "switch", .keyword_switch },
        .{ "while", .keyword_while },
    });

    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }

    pub const Tag = enum {
        eof, // end of file or input
        wsp, // whitespace (' ', '\t')
        comment, // # to \n
        word, // any sequence of bytes except '#', ';', '&', '|', '^', '$', '`', ''', '{', '}', '(', ')', '<', '>', ' ', '\t', '\n'
        quoted_word, // sequence of bytes surrounded by '. Escape ' with ''
        variable, // '$' followed by [A-Za-z0-9_]
        variable_count,
        variable_string,
        ampersand, // &
        ampersand_ampersand, // &&
        l_paren, // (
        r_paren, // )
        newline, // \n
        semicolon, // ;
        pipe, // |
        pipe_pipe, // ||
        caret, // ^
        backtick, // `
        backtick_l_brace, // `{
        l_brace, // {
        r_brace, // }
        l_angle, // <
        l_angle_l_angle, // <<
        l_angle_l_brace, // <{
        l_angle_r_angle_l_brace, // <>{
        r_angle, // >
        r_angle_r_angle, // >>
        r_angle_l_brace, // >{
        at_sign, // @
        bang, // !
        tilde, // ~
        equal, // =
        keyword_case, // "case"
        keyword_else, // "else"
        keyword_fn, // "fn"
        keyword_for, // "for"
        keyword_if, // "if"
        keyword_in, // "in"
        keyword_switch, // "switch"
        keyword_while, // "while"
    };
};

pub const Tokenizer = struct {
    buf: []const u8,
    index: usize,

    pub fn init(buf: []const u8) Tokenizer {
        return .{
            .buf = buf,
            .index = 0,
        };
    }

    pub fn next(self: *Tokenizer) Token {
        var token: Token = .{
            .tag = .eof,
            .loc = .{ .start = self.index, .end = self.buf.len },
        };
        const b = self.readByte() orelse return token;
        switch (b) {
            '\n' => {
                token.tag = .newline;
                token.loc.end = self.index;
            },
            ' ', '\t' => {
                token.tag = .wsp;
                var _b = self.peek();
                while (_b == ' ' or _b == '\t') {
                    self.index += 1;
                    _b = self.peek();
                }
                token.loc.end = self.index;
            },
            '#' => {
                token.tag = .comment;
                token.loc.end = mem.indexOfScalarPos(u8, self.buf, self.index, '\n') orelse
                    self.buf.len;
                self.index = @min(token.loc.end + 1, self.buf.len);
            },
            ';' => {
                token.tag = .semicolon;
                token.loc.end = self.index;
            },
            '&' => {
                token.tag = .ampersand;
                token.loc.end = self.index;
                const _b = self.peek() orelse return token;
                if (_b == '&') {
                    self.consumeByte();
                    token.tag = .ampersand_ampersand;
                    token.loc.end = self.index;
                }
            },
            '|' => {
                token.tag = .pipe;
                token.loc.end = self.index;
                const _b = self.peek() orelse return token;
                if (_b == '|') {
                    self.consumeByte();
                    token.tag = .pipe_pipe;
                    token.loc.end = self.index;
                }
            },
            '^' => {
                token.tag = .caret;
                token.loc.end = self.index;
            },
            '$' => {
                token.loc.start += 1;
                const _b = self.peek() orelse {
                    token.tag = .variable;
                    token.loc.end = self.index;
                    return token;
                };
                switch (_b) {
                    '#' => {
                        token.tag = .variable_count;
                        token.loc.start += 1;
                        self.consumeByte();
                    },
                    '"' => {
                        token.tag = .variable_string;
                        token.loc.start += 1;
                        self.consumeByte();
                    },
                    else => token.tag = .variable,
                }
                while (self.readByte()) |__b| {
                    if (ascii.isAlphanumeric(__b) or __b == '_' or __b == '*')
                        continue;
                    self.index -= 1;
                    break;
                }
                token.loc.end = self.index;
            },
            '`' => {
                token.tag = .backtick;
                token.loc.end = self.index;
                if (self.peek()) |_b| {
                    switch (_b) {
                        '{' => {
                            self.index += 1;
                            token.tag = .backtick_l_brace;
                            token.loc.end = self.index;
                        },
                        else => {},
                    }
                }
            },
            '\'' => {
                token.tag = .quoted_word;
                var single_quote: bool = false;
                while (self.readByte()) |_b| {
                    switch (_b) {
                        '\'' => single_quote = !single_quote,
                        else => if (single_quote) {
                            self.index -|= 1;
                            break;
                        },
                    }
                }
                token.loc.end = self.index;
            },
            '{' => {
                token.tag = .l_brace;
                token.loc.end = self.index;
            },
            '}' => {
                token.tag = .r_brace;
                token.loc.end = self.index;
            },
            '(' => {
                token.tag = .l_paren;
                token.loc.end = self.index;
            },
            ')' => {
                token.tag = .r_paren;
                token.loc.end = self.index;
            },
            '<' => {
                token.tag = .l_angle;
                token.loc.end = self.index;
                if (self.peek()) |_b| {
                    switch (_b) {
                        '<' => {
                            self.index += 1;
                            token.tag = .l_angle_l_angle;
                            token.loc.end = self.index;
                        },
                        '{' => {
                            self.index += 1;
                            token.tag = .l_angle_l_brace;
                            token.loc.end = self.index;
                        },
                        '>' => {
                            if (self.peek()) |__b| {
                                switch (__b) {
                                    '{' => {
                                        self.index += 1;
                                        token.tag = .l_angle_r_angle_l_brace;
                                        token.loc.end = self.index;
                                    },
                                    else => {},
                                }
                            }
                        },
                        else => {},
                    }
                }
            },
            '>' => {
                token.tag = .r_angle;
                token.loc.end = self.index;
                if (self.peek()) |_b| {
                    switch (_b) {
                        '>' => {
                            self.index += 1;
                            token.tag = .r_angle_r_angle;
                            token.loc.end = self.index;
                        },
                        '{' => {
                            self.index += 1;
                            token.tag = .r_angle_l_brace;
                            token.loc.end = self.index;
                        },
                        else => {},
                    }
                }
            },
            '~' => {
                token.tag = .tilde;
                token.loc.end = self.index;
            },
            '!' => {
                token.tag = .bang;
                token.loc.end = self.index;
            },
            '@' => {
                token.tag = .at_sign;
                token.loc.end = self.index;
            },
            '=' => {
                token.tag = .equal;
                token.loc.end = self.index;
            },
            else => {
                token.tag = .word;
                token.loc.end = mem.indexOfAnyPos(u8, self.buf, self.index, non_word_bytes) orelse
                    self.buf.len;
                self.index = token.loc.end;
                if (Token.getKeyword(self.buf[token.loc.start..token.loc.end])) |tag|
                    token.tag = tag;
            },
        }
        return token;
    }

    /// Returns the next byte and advances the index by 1
    fn readByte(self: *Tokenizer) ?u8 {
        if (self.index >= self.buf.len) return null;
        defer self.index += 1;
        return self.buf[self.index];
    }

    /// Returns the next byte without advancing the index
    fn peek(self: *Tokenizer) ?u8 {
        if (self.index >= self.buf.len) return null;
        return self.buf[self.index];
    }

    fn consumeByte(self: *Tokenizer) void {
        self.index += 1;
    }
};

test "whitespace and comments" {
    const input = " \t   # comment";
    var tokenizer = Tokenizer.init(input);
    const tokens = [_]Token{
        .{ .tag = .wsp, .loc = .{ .start = 0, .end = 5 } },
        .{ .tag = .comment, .loc = .{ .start = 5, .end = input.len } },
        .{ .tag = .eof, .loc = .{ .start = input.len, .end = input.len } },
    };
    for (tokens) |expected| {
        const actual = tokenizer.next();
        try std.testing.expectEqual(expected, actual);
    }
}

test "variables" {
    const input = "$abc $#abc $";
    var tokenizer = Tokenizer.init(input);
    const tokens = [_]Token{
        .{ .tag = .variable, .loc = .{ .start = 1, .end = 4 } },
        .{ .tag = .wsp, .loc = .{ .start = 4, .end = 5 } },
        .{ .tag = .variable_count, .loc = .{ .start = 7, .end = 10 } },
        .{ .tag = .wsp, .loc = .{ .start = 10, .end = 11 } },
        .{ .tag = .variable, .loc = .{ .start = 12, .end = 12 } },
        .{ .tag = .eof, .loc = .{ .start = input.len, .end = input.len } },
    };
    for (tokens) |expected| {
        const actual = tokenizer.next();
        try std.testing.expectEqual(expected, actual);
    }
}

test "ampersands" {
    const input = "a && b &";
    var tokenizer = Tokenizer.init(input);
    const tokens = [_]Token{
        .{ .tag = .word, .loc = .{ .start = 0, .end = 1 } },
        .{ .tag = .wsp, .loc = .{ .start = 1, .end = 2 } },
        .{ .tag = .ampersand_ampersand, .loc = .{ .start = 2, .end = 4 } },
        .{ .tag = .wsp, .loc = .{ .start = 4, .end = 5 } },
        .{ .tag = .word, .loc = .{ .start = 5, .end = 6 } },
        .{ .tag = .wsp, .loc = .{ .start = 6, .end = 7 } },
        .{ .tag = .ampersand, .loc = .{ .start = 7, .end = 8 } },
        .{ .tag = .eof, .loc = .{ .start = input.len, .end = input.len } },
    };
    for (tokens) |expected| {
        const actual = tokenizer.next();
        try std.testing.expectEqual(expected, actual);
    }
}

test "quoted word" {
    const input = "a 'can''t'";
    var tokenizer = Tokenizer.init(input);
    const tokens = [_]Token{
        .{ .tag = .word, .loc = .{ .start = 0, .end = 1 } },
        .{ .tag = .wsp, .loc = .{ .start = 1, .end = 2 } },
        .{ .tag = .quoted_word, .loc = .{ .start = 2, .end = input.len } },
        .{ .tag = .eof, .loc = .{ .start = input.len, .end = input.len } },
    };
    for (tokens) |expected| {
        const actual = tokenizer.next();
        try std.testing.expectEqual(expected, actual);
    }
}

test "quoted word single space" {
    const input = "' ' ";
    var tokenizer = Tokenizer.init(input);
    const tokens = [_]Token{
        .{ .tag = .quoted_word, .loc = .{ .start = 0, .end = 3 } },
        .{ .tag = .wsp, .loc = .{ .start = 3, .end = 4 } },
    };
    for (tokens) |expected| {
        const actual = tokenizer.next();
        try std.testing.expectEqual(expected, actual);
    }
}

test "list" {
    const input = "(1 2 3)";
    var tokenizer = Tokenizer.init(input);
    const tokens = [_]Token{
        .{ .tag = .l_paren, .loc = .{ .start = 0, .end = 1 } },
        .{ .tag = .word, .loc = .{ .start = 1, .end = 2 } },
        .{ .tag = .wsp, .loc = .{ .start = 2, .end = 3 } },
        .{ .tag = .word, .loc = .{ .start = 3, .end = 4 } },
        .{ .tag = .wsp, .loc = .{ .start = 4, .end = 5 } },
        .{ .tag = .word, .loc = .{ .start = 5, .end = 6 } },
        .{ .tag = .r_paren, .loc = .{ .start = 6, .end = 7 } },
        .{ .tag = .eof, .loc = .{ .start = input.len, .end = input.len } },
    };
    for (tokens) |expected| {
        const actual = tokenizer.next();
        try std.testing.expectEqual(expected, actual);
    }
}
