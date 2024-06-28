const std = @import("std");
const testing = std.testing;
const ast = @import("ast.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.interpreter);

pub const Error = error{
    SyntaxError,
    BuiltinCommandError,
    OutOfMemory,
} || std.posix.ChangeCurDirError;

const Builtin = enum {
    cd,
    exit,
};

/// executes `src` as an rz script. env will be updated as necessary
pub fn exec(allocator: std.mem.Allocator, src: []const u8, env: *std.process.EnvMap) Allocator.Error!?u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cmds = ast.parse(src, alloc) catch |err| {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SyntaxError => log.err("syntax error", .{}),
        }
        return null;
    };

    var interp: Interpreter = .{
        .arena = alloc,
        .env = env,
    };
    return interp.exec(cmds) catch |err| {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        }
    };
}

const Interpreter = struct {
    arena: std.mem.Allocator,
    env: *std.process.EnvMap,
    exit: ?u8 = null,

    fn exec(self: *Interpreter, cmds: []const ast.Command) Error!?u8 {
        for (cmds) |cmd| {
            switch (cmd) {
                .simple => |simple| try self.execSimple(simple),
                .function => |func| {
                    const key = try std.fmt.allocPrint(self.arena, "fn#{s}", .{func.name});
                    try self.env.put(key, func.body);
                },
                .assignment => |assignment| try self.execAssignment(assignment),
            }
        }
        return self.exit;
    }

    fn execAssignment(self: *Interpreter, cmd: ast.Assignment) Error!void {
        const value = try self.resolveArg(cmd.value);
        const storage = try std.mem.join(self.arena, "\x01", value);
        try self.env.put(cmd.key, storage);
    }

    fn execSimple(self: *Interpreter, cmd: ast.Simple) Error!void {
        for (cmd.assignments) |assignment| {
            try self.execAssignment(assignment);
        }
        defer {
            for (cmd.assignments) |assignment| {
                self.env.remove(assignment.key);
            }
        }

        var arguments = std.ArrayList([]const u8).init(self.arena);
        for (cmd.arguments) |arg| {
            const resolved = try self.resolveArg(arg);
            try arguments.appendSlice(resolved);
        }
        if (arguments.items.len == 0) return;

        for (cmd.redirections) |redir| {
            switch (redir.fd) {
                std.posix.STDIN_FILENO => {},
                std.posix.STDOUT_FILENO,
                std.posix.STDERR_FILENO,
                => {
                    const dest = try self.resolveArg(redir.source.arg);
                    if (dest.len != 1) {
                        log.err("redirection requires exactly 1 destination", .{});
                        return error.SyntaxError;
                    }
                    const dir = std.fs.cwd();
                    const flags: std.posix.O = .{
                        .ACCMODE = .WRONLY,
                        .CREAT = true,
                        .TRUNC = !redir.append,
                        .APPEND = redir.append,
                    };
                    const fd = createFile(dir, dest[0], flags) catch @panic("TODO");
                    defer std.posix.close(fd);
                    std.posix.dup2(fd, redir.fd) catch @panic("TODO");
                },
                else => {},
            }
        }

        const builtin = std.mem.eql(u8, "builtin", arguments.items[0]);

        const args = if (builtin) blk: {
            if (arguments.items.len == 1) return;
            break :blk arguments.items[1..];
        } else arguments.items;

        if (!builtin and try self.execFunction(args)) return;

        if (try self.execBuiltin(args)) return;

        var process = std.process.Child.init(args, self.arena);
        process.env_map = self.env;
        const exit = process.spawnAndWait() catch |err| {
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FileNotFound => {
                    log.err("command '{s}' not found", .{arguments.items[0]});
                    self.setStatus(127) catch return;
                },
                error.AccessDenied => log.err("access denied", .{}),
                else => log.err("unexpected error: {}", .{err}),
            }
            // TODO: map error codes
            self.setStatus(1) catch return;
            return;
        };
        switch (exit) {
            .Exited => |val| try self.setStatus(val),
            else => {},
        }
    }

    fn execFunction(self: *Interpreter, args: []const []const u8) Error!bool {
        const key = try std.fmt.allocPrint(self.arena, "fn#{s}", .{args[0]});
        if (self.env.get(key)) |val| {
            try self.setArgEnv(args);
            const cmds = ast.parse(val, self.arena) catch |err| {
                switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.SyntaxError => log.err("syntax error", .{}),
                }
                return true;
            };
            _ = try self.exec(cmds);
            return true;
        }
        return false;
    }

    fn execBuiltin(self: *Interpreter, args: []const []const u8) Error!bool {
        const cmd = std.meta.stringToEnum(Builtin, args[0]) orelse return false;
        switch (cmd) {
            .cd => {
                if (args.len == 1) {
                    if (self.env.get("home")) |home| {
                        try std.process.changeCurDir(home);
                    }
                    return true;
                }
                if (args[1][0] == '/') {
                    try std.process.changeCurDir(args[1]);
                    return true;
                }
                var components = std.ArrayList([]const u8).init(self.arena);
                // we add a / because path.join doesn't return an absolute path
                components.append("/") catch return true;
                const cwd = std.process.getCwdAlloc(self.arena) catch |err| {
                    switch (err) {
                        Allocator.Error.OutOfMemory => return error.OutOfMemory,
                        else => return error.BuiltinCommandError,
                    }
                };
                var iter = std.mem.splitScalar(u8, cwd, '/');
                while (iter.next()) |v| {
                    if (v.len == 0) continue;
                    components.append(v) catch return true;
                }
                iter = std.mem.splitScalar(u8, args[1], '/');
                while (iter.next()) |p| {
                    if (std.mem.eql(u8, "..", p)) {
                        components.items.len -|= 1;
                        continue;
                    }
                    components.append(p) catch return true;
                }

                const path = try std.fs.path.join(self.arena, components.items);
                try std.process.changeCurDir(path);
                return true;
            },
            .exit => {
                self.exit = if (args.len > 1)
                    std.fmt.parseUnsigned(u8, args[1], 10) catch return error.SyntaxError
                else
                    0;
                try self.setStatus(self.exit.?);
                return true;
            },
        }
        return false;
    }

    fn setArgEnv(self: *Interpreter, args: []const []const u8) Allocator.Error!void {
        if (args.len > 1) {
            const storage = try std.mem.join(self.arena, "\x01", args[1..]);
            log.err("{s}", .{storage});
            log.err("{any}", .{storage});
            try self.env.put("*", storage);
        }
    }

    fn setStatus(self: *Interpreter, status: u8) Allocator.Error!void {
        const str = try std.fmt.allocPrint(self.arena, "{d}", .{status});
        try self.env.put("status", str);
    }

    /// resolves an argument to list of strings
    fn resolveArg(self: *Interpreter, arg: ast.Argument) Error![]const []const u8 {
        var result = std.ArrayList([]const u8).init(self.arena);
        switch (arg) {
            .word => |word| try result.append(word),
            .quoted_word => |qw| {
                // we must have at least 2 bytes for this to be a valid quoted word
                if (qw.len < 2) return result.items;
                const unquoted = qw[1 .. qw.len - 1];
                const buf = try std.mem.replaceOwned(u8, self.arena, unquoted, "''", "'");
                try result.append(buf);
            },
            .variable => |v| {
                const val = self.env.get(v) orelse return result.items;
                var iter = std.mem.splitScalar(u8, val, '\x01');
                while (iter.next()) |item| {
                    try result.append(item);
                }
            },
            .variable_count => |v| {
                const count = if (self.env.get(v)) |val|
                    std.mem.count(u8, val, "\x01") + 1
                else
                    0;
                const buf = try std.fmt.allocPrint(self.arena, "{d}", .{count});
                try result.append(buf);
            },
            .variable_string => |v| {
                const val = self.env.get(v) orelse return result.items;
                const buf = try self.arena.dupe(u8, val);
                std.mem.replaceScalar(u8, buf, '\x01', ' ');
                try result.append(buf);
            },
            .variable_subscript => |v| {
                const val = self.env.get(v.key) orelse return result.items;
                var list = std.ArrayList([]const u8).init(self.arena);
                {
                    var iter = std.mem.splitScalar(u8, val, '\x01');
                    while (iter.next()) |item| {
                        try list.append(item);
                    }
                }
                const subscripts = try self.resolveArg(v.fields.*);
                for (subscripts) |subscript| {
                    const n = std.fmt.parseUnsigned(usize, subscript, 10) catch |err| {
                        log.err("subscript error: '{s}' error: {}", .{ subscript, err });
                        return error.SyntaxError;
                    };
                    if (n == 0) continue;
                    if (n - 1 < list.items.len) {
                        try result.append(list.items[n - 1]);
                    }
                }
            },
            .concatenate => |concat| {
                const lhs = try self.resolveArg(concat.lhs.*);
                const rhs = try self.resolveArg(concat.rhs.*);
                if (lhs.len == 0 or rhs.len == 0) {
                    log.err("tried concatenating a zero length list. Not supported at this time", .{});
                    return error.SyntaxError;
                }
                // equal lengths we pairwise concatenate
                if (lhs.len == rhs.len) {
                    for (lhs, 0..) |item, i| {
                        const buf = try std.mem.concat(self.arena, u8, &.{ item, rhs[i] });
                        try result.append(buf);
                    }
                } else if (lhs.len > 1 and rhs.len == 1) {
                    for (lhs) |item| {
                        const buf = try std.mem.concat(self.arena, u8, &.{ item, rhs[0] });
                        try result.append(buf);
                    }
                } else if (lhs.len == 1 and rhs.len > 1) {
                    for (rhs) |item| {
                        const buf = try std.mem.concat(self.arena, u8, &.{ lhs[0], item });
                        try result.append(buf);
                    }
                }
            },
            .list => |list| {
                for (list) |item| {
                    const resolved = try self.resolveArg(item);
                    try result.appendSlice(resolved);
                }
            },
        }
        return result.items;
    }
};

fn createFile(dir: std.fs.Dir, path: []const u8, flags: std.posix.O) !std.posix.fd_t {
    const cpath = try std.posix.toPosixPath(path);
    return std.posix.openatZ(dir.fd, &cpath, flags, std.fs.File.default_mode);
}

test "resolve arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = std.process.EnvMap.init(allocator);
    var interp: Interpreter = .{
        .arena = allocator,
        .env = &env,
    };
    {
        const result = try interp.resolveArg(.{ .word = "foo" });
        try testing.expectEqual(1, result.len);
        try testing.expectEqualStrings("foo", result[0]);
    }
    {
        const result = try interp.resolveArg(.{ .quoted_word = "'foo'" });
        try testing.expectEqual(1, result.len);
        try testing.expectEqualStrings("foo", result[0]);
    }
    {
        const result = try interp.resolveArg(.{ .quoted_word = "'fo''o'" });
        try testing.expectEqual(1, result.len);
        try testing.expectEqualStrings("fo'o", result[0]);
    }
    {
        const result = try interp.resolveArg(.{ .quoted_word = "''''" });
        try testing.expectEqual(1, result.len);
        try testing.expectEqualStrings("'", result[0]);
    }
    {
        const result = try interp.resolveArg(.{ .variable = "foo" });
        try testing.expectEqual(0, result.len);
    }
    {
        try env.put("foo", "bar");
        const result = try interp.resolveArg(.{ .variable = "foo" });
        try testing.expectEqual(1, result.len);
        try testing.expectEqualStrings("bar", result[0]);
    }
    {
        try env.put("foo", "bar\x01baz");
        var result = try interp.resolveArg(.{ .variable = "foo" });
        try testing.expectEqual(2, result.len);
        try testing.expectEqualStrings("bar", result[0]);
        try testing.expectEqualStrings("baz", result[1]);

        result = try interp.resolveArg(.{ .variable_count = "foo" });
        try testing.expectEqual(1, result.len);
        try testing.expectEqualStrings("2", result[0]);

        result = try interp.resolveArg(.{ .variable_string = "foo" });
        try testing.expectEqual(1, result.len);
        try testing.expectEqualStrings("bar baz", result[0]);

        const fields: ast.Argument = .{ .list = &.{.{ .word = "1" }} };
        result = try interp.resolveArg(.{
            .variable_subscript = .{ .key = "foo", .fields = &fields },
        });
        try testing.expectEqual(1, result.len);
        try testing.expectEqualStrings("bar", result[0]);

        const fields2: ast.Argument = .{
            .list = &.{
                .{ .word = "1" },
                .{ .word = "1" },
                .{ .word = "1" },
            },
        };
        result = try interp.resolveArg(.{
            .variable_subscript = .{ .key = "foo", .fields = &fields2 },
        });
        try testing.expectEqual(3, result.len);
        try testing.expectEqualStrings("bar", result[0]);
        try testing.expectEqualStrings("bar", result[1]);
        try testing.expectEqualStrings("bar", result[2]);
    }
    {
        const lhs: ast.Argument = .{ .word = "foo" };
        const rhs: ast.Argument = .{ .word = "bar" };
        const result = try interp.resolveArg(.{ .concatenate = .{
            .lhs = &lhs,
            .rhs = &rhs,
        } });
        try testing.expectEqual(1, result.len);
        try testing.expectEqualStrings("foobar", result[0]);
    }
    {
        const lhs: ast.Argument = .{ .word = "foo" };
        const rhs: ast.Argument = .{
            .list = &.{
                .{ .word = "bar" },
                .{ .word = "baz" },
            },
        };
        var result = try interp.resolveArg(.{ .concatenate = .{
            .lhs = &lhs,
            .rhs = &rhs,
        } });
        try testing.expectEqual(2, result.len);
        try testing.expectEqualStrings("foobar", result[0]);
        try testing.expectEqualStrings("foobaz", result[1]);

        const lhs_list: ast.Argument = .{
            .list = &.{
                .{ .word = "-" },
                .{ .word = "--" },
            },
        };

        result = try interp.resolveArg(.{ .concatenate = .{
            .lhs = &lhs_list,
            .rhs = &rhs,
        } });
        try testing.expectEqual(2, result.len);
        try testing.expectEqualStrings("-bar", result[0]);
        try testing.expectEqualStrings("--baz", result[1]);
    }
}
