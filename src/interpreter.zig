const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const ast = @import("ast.zig");
const Allocator = std.mem.Allocator;
const ctlseqs = @import("vaxis").ctlseqs;

const main = @import("main.zig");

const log = std.log.scoped(.interpreter);

pub const Error = error{
    SyntaxError,
    BuiltinCommandError,
    OutOfMemory,
} || posix.ChangeCurDirError;

const Builtin = enum {
    cd,
    clear,
    exit,
};

/// executes `src` as an rz script. env will be updated as necessary. If a u8 is returned, the shell
/// must exit with that as it's exit code
pub fn exec(allocator: std.mem.Allocator, src: []const u8, env: *std.process.EnvMap) Allocator.Error!u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cmds = ast.parse(src, alloc) catch |err| {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SyntaxError => log.err("syntax error", .{}),
        }
        return 255;
    };

    var interp: Interpreter = .{
        .arena = alloc,
        .env = env,
    };

    const fds = saveFds();
    defer restoreFds(fds);

    return interp.exec(cmds) catch |err| {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return 255,
        }
    };
}

fn saveFds() [3]posix.fd_t {
    var fds: [3]posix.fd_t = .{
        posix.STDIN_FILENO,
        posix.STDOUT_FILENO,
        posix.STDERR_FILENO,
    };
    fds[0] = posix.dup(fds[0]) catch |err| blk: {
        log.err("dup error: {}", .{err});
        break :blk posix.STDIN_FILENO;
    };
    fds[1] = posix.dup(fds[1]) catch |err| blk: {
        log.err("dup error: {}", .{err});
        break :blk posix.STDOUT_FILENO;
    };
    fds[2] = posix.dup(fds[2]) catch |err| blk: {
        log.err("dup error: {}", .{err});
        break :blk posix.STDERR_FILENO;
    };
    return fds;
}

fn restoreFds(fds: [3]posix.fd_t) void {
    if (fds[0] != posix.STDIN_FILENO) {
        posix.dup2(fds[0], std.posix.STDIN_FILENO) catch |err| {
            log.err("dup2 error: {}", .{err});
        };
        posix.close(fds[0]);
    }
    if (fds[1] != posix.STDOUT_FILENO) {
        posix.dup2(fds[1], std.posix.STDOUT_FILENO) catch |err| {
            log.err("dup2 error: {}", .{err});
        };
        posix.close(fds[1]);
    }
    if (fds[2] != posix.STDERR_FILENO) {
        posix.dup2(fds[2], std.posix.STDERR_FILENO) catch |err| {
            log.err("dup2 error: {}", .{err});
        };
        posix.close(fds[2]);
    }
}
const Interpreter = struct {
    arena: std.mem.Allocator,
    env: *std.process.EnvMap,
    /// The saved value of $*. We save it here and restore as needed
    arg_env: ?[]const u8 = null,
    /// In prompt mode, we prevent anything from setting the $status var
    prompt_mode: bool = false,

    fn exec(self: *Interpreter, cmds: []const ast.Command) Error!u8 {
        var code: u8 = 0;
        for (cmds) |cmd| {
            code = try self.execCommand(cmd);
            if (self.prompt_mode) continue;
            switch (cmd) {
                .assignment => continue,
                else => try self.setStatus(code),
            }
        }
        return code;
    }

    fn execCommand(self: *Interpreter, cmd: ast.Command) Error!u8 {
        switch (cmd) {
            .simple => |simple| return self.execSimple(simple),
            .function => |func| {
                const key = try std.fmt.allocPrint(self.arena, "fn#{s}", .{func.name});
                try self.env.put(key, func.body);
            },
            .assignment => |assignment| try self.execAssignment(assignment),
            .group => |grp| return self.exec(grp),
            .if_nonzero,
            .if_zero,
            => |bin| return self.execBinary(bin, std.meta.activeTag(cmd)),
            .pipe => |pipe| return self.execPipe(pipe),
            .if_statement => |stmt| return self.execIfStatement(stmt),
        }
        return 0;
    }

    fn execIfStatement(self: *Interpreter, cmd: ast.IfStatement) Error!u8 {
        const result = try self.exec(cmd.condition);
        if (result == 0)
            return self.exec(cmd.body)
        else if (cmd.alt) |alt|
            return self.exec(alt)
        else
            return result;
    }

    fn execAssignment(self: *Interpreter, cmd: ast.Assignment) Error!void {
        // TODO: keep $path and $PATH in sync
        const value = try self.resolveArg(cmd.value);
        const storage = try std.mem.join(self.arena, "\x01", value);
        try self.env.put(cmd.key, storage);
    }

    fn execSimple(self: *Interpreter, cmd: ast.Simple) Error!u8 {
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
        if (arguments.items.len == 0) return 0;

        for (cmd.redirections) |redir| {
            const file = try self.resolveArg(redir.file);
            if (file.len != 1) {
                log.err("redirection requires exactly 1 target", .{});
                return error.SyntaxError;
            }
            if (file[0][0] == '[') {
                const f = file[0];
                if (f[f.len - 1] != ']') return error.SyntaxError;
                var iter = std.mem.splitScalar(u8, f[1 .. f.len - 1], '=');
                const lhs_buf = iter.first();
                const lhs = std.fmt.parseUnsigned(u16, lhs_buf, 10) catch return error.SyntaxError;
                if (iter.next()) |rhs_buf| {
                    const rhs = std.fmt.parseUnsigned(u16, rhs_buf, 10) catch return error.SyntaxError;
                    posix.dup2(rhs, lhs) catch @panic("TODO");
                } else {
                    posix.close(lhs);
                }
            } else {
                const dir = std.fs.cwd();
                switch (redir.direction) {
                    .in => {
                        const fd = dir.openFile(file[0], .{}) catch @panic("TODO");
                        defer fd.close();
                        posix.dup2(fd.handle, redir.fd) catch @panic("TODO");
                    },
                    .out => {
                        const flags: posix.O = .{
                            .ACCMODE = .WRONLY,
                            .CREAT = true,
                            .TRUNC = !redir.append,
                            .APPEND = redir.append,
                        };
                        const fd = createFile(dir, file[0], flags) catch @panic("TODO");
                        defer posix.close(fd);
                        posix.dup2(fd, redir.fd) catch @panic("TODO");
                    },
                }
            }
        }

        return self.execFunction(arguments.items);
    }

    /// Attempts to exec a function. If there is no function, this will try a builtin. If there is
    /// no builtin, this will try a command in $path
    fn execFunction(self: *Interpreter, args: []const []const u8) Error!u8 {
        if (std.mem.eql(u8, args[0], "prompt"))
            self.prompt_mode = true
        else if (std.mem.eql(u8, args[0], "builtin"))
            return self.execBuiltin(args[1..]);

        const key = try std.fmt.allocPrint(self.arena, "fn#{s}", .{args[0]});
        const body = self.env.get(key) orelse
            return self.execBuiltin(args);
        if (main.args.verbose)
            log.err("executing function: '{s}'", .{args});
        try self.setArgEnv(args);
        defer self.restoreArgEnv();
        const cmds = ast.parse(body, self.arena) catch |err| {
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.SyntaxError => log.err("syntax error", .{}),
            }
            return 1;
        };
        return self.exec(cmds);
    }

    fn execBuiltin(self: *Interpreter, args: []const []const u8) Error!u8 {
        const cmd = std.meta.stringToEnum(Builtin, args[0]) orelse
            return self.execChild(args);
        if (main.args.verbose)
            log.err("executing builtin: '{s}'", .{args});
        switch (cmd) {
            .cd => {
                if (args.len == 1) {
                    if (self.env.get("home")) |home| {
                        try std.process.changeCurDir(home);
                    }
                    return 0;
                }
                if (args[1][0] == '/') {
                    try std.process.changeCurDir(args[1]);
                    return 0;
                }
                errdefer |err| log.err("error {}", .{err});
                var components = std.ArrayList([]const u8).init(self.arena);
                // we add a / because path.join doesn't return an absolute path
                try components.append("/");
                const cwd = std.process.getCwdAlloc(self.arena) catch |err| {
                    switch (err) {
                        Allocator.Error.OutOfMemory => return error.OutOfMemory,
                        else => return error.BuiltinCommandError,
                    }
                };
                var iter = std.mem.splitScalar(u8, cwd, '/');
                while (iter.next()) |v| {
                    if (v.len == 0) continue;
                    try components.append(v);
                }
                iter = std.mem.splitScalar(u8, args[1], '/');
                while (iter.next()) |p| {
                    if (std.mem.eql(u8, "..", p)) {
                        components.items.len -|= 1;
                        continue;
                    }
                    try components.append(p);
                }

                const path = try std.fs.path.join(self.arena, components.items);
                try std.process.changeCurDir(path);
                return 0;
            },
            .clear => {
                const writer = std.io.getStdOut().writer();
                // We don't reset sync since we want it to hold until our render loop is done
                writer.writeAll(ctlseqs.sync_set ++
                    ctlseqs.home ++
                    ctlseqs.erase_below_cursor) catch |err| {
                    log.err("clear: couldn't write to stdout: {}", .{err});
                    return error.BuiltinCommandError;
                };
                return 0;
            },
            .exit => {
                if (args.len > 1) {
                    const code = std.fmt.parseUnsigned(u8, args[1], 10) catch 1;
                    std.process.exit(code);
                } else std.process.exit(0);
            },
        }
    }

    fn execChild(self: *Interpreter, args: []const []const u8) Error!u8 {
        if (main.args.verbose)
            log.err("executing command: '{s}'", .{args});
        var process = std.process.Child.init(args, self.arena);
        process.env_map = self.env;
        const exit = process.spawnAndWait() catch |err| {
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FileNotFound => {
                    log.err("command '{s}' not found", .{args[0]});
                    return 127;
                },
                error.AccessDenied => log.err("access denied", .{}),
                else => log.err("unexpected error: {}", .{err}),
            }
            return 1;
        };
        switch (exit) {
            .Exited => |val| {
                return val;
            },
            else => return 1,
        }
    }

    fn execBinary(self: *Interpreter, cmd: ast.Binary, tag: std.meta.Tag(ast.Command)) Error!u8 {
        _ = try self.exec(&.{cmd.lhs.*});
        if (self.env.get("status")) |status| {
            if (std.mem.eql(u8, "0", status))
                switch (tag) {
                    .if_zero => _ = try self.exec(&.{cmd.rhs.*}),
                    else => return 0,
                }
            else {
                switch (tag) {
                    .if_nonzero => _ = try self.exec(&.{cmd.rhs.*}),
                    else => return 0,
                }
            }
        }
        return 0;
    }

    fn execPipe(self: *Interpreter, cmd: ast.Binary) Error!u8 {
        const read_end, const write_end = posix.pipe() catch @panic("TODO");

        const lhs: posix.fd_t = lhs: {
            const pid = posix.fork() catch @panic("TODO");
            switch (pid) {
                0 => {
                    // we don't need the read_end in lhs
                    posix.close(read_end);
                    // Dupe our stdout to the pipe
                    posix.dup2(write_end, posix.STDOUT_FILENO) catch @panic("TODO");
                    // Now the write_end fd is not needed
                    posix.close(write_end);
                    _ = try self.exec(&.{cmd.lhs.*});
                    std.process.exit(0);
                },
                else => break :lhs pid, // we are the parent. Keep the child pid
            }
        };
        const rhs: posix.fd_t = rhs: {
            const pid = posix.fork() catch @panic("TODO");
            switch (pid) {
                0 => {
                    // we don't need the write_end in rhs
                    posix.close(write_end);
                    // Dupe our stdin to the pipe
                    posix.dup2(read_end, posix.STDIN_FILENO) catch @panic("TODO");
                    // Now the read_end fd is not needed
                    posix.close(read_end);
                    _ = try self.exec(&.{cmd.rhs.*});
                    std.process.exit(0);
                },
                else => break :rhs pid, // we are the parent. Keep the child pid
            }
        };

        // In the parent, we don't need either pipe.
        posix.close(read_end);
        posix.close(write_end);

        // wait for the commands to finish
        const lhs_stat = posix.waitpid(lhs, 0);
        _ = lhs_stat; // autofix
        const rhs_stat = posix.waitpid(rhs, 0);
        _ = rhs_stat; // autofix
        return 0;
    }

    fn restoreArgEnv(self: *Interpreter) void {
        if (self.arg_env) |val| {
            self.env.put("*", val) catch {};
            self.arena.free(val);
        } else {
            self.env.remove("*");
        }
    }

    /// Saves a copy of $* to our interpreter state and sets the new environment value
    fn setArgEnv(self: *Interpreter, args: []const []const u8) Allocator.Error!void {
        if (self.env.get("*")) |val| {
            self.arg_env = try self.arena.dupe(u8, val);
        }
        if (args.len > 1) {
            const storage = try std.mem.join(self.arena, "\x01", args[1..]);
            try self.env.put("*", storage);
        }
    }

    fn setStatus(self: *Interpreter, status: u8) Allocator.Error!void {
        if (self.prompt_mode) return;
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
            .substitution => |cmds| {
                // We run the commands as usual, but we gather all stdout. We do this with a simple
                // pipe
                const fds = posix.pipe() catch @panic("TODO");
                const read_end = fds[0];
                const write_end = fds[1];
                defer {
                    posix.close(read_end);
                    posix.close(write_end);
                }

                {
                    // Set read_end to nonblocking
                    const flags = posix.fcntl(read_end, std.posix.F.GETFL, 0) catch @panic("TODO");
                    _ = posix.fcntl(
                        read_end,
                        posix.F.SETFL,
                        flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
                    ) catch @panic("TODO");
                }

                const saved = saveFds();
                defer restoreFds(saved);
                posix.dup2(write_end, std.posix.STDOUT_FILENO) catch @panic("TODO");
                _ = try self.exec(cmds);
                var buf: [4096]u8 = undefined;
                var stdout = std.ArrayList(u8).init(self.arena);
                while (true) {
                    const n = posix.read(read_end, &buf) catch break;
                    if (n == 0) break;
                    try stdout.appendSlice(buf[0..n]);
                }
                // Next we split by $ifs
                const ifs: []const u8 = if (self.env.get("ifs")) |ifs| blk: {
                    var ifs_joined = std.ArrayList(u8).init(self.arena);
                    var iter = std.mem.splitScalar(u8, ifs, '\x01');
                    while (iter.next()) |sep| {
                        if (sep.len != 1) {
                            log.err("invalid ifs char: {s}. Must be a single byte", .{sep});
                            continue;
                        }
                        try ifs_joined.append(sep[0]);
                    }
                    break :blk ifs_joined.items;
                } else " \t\n";
                var iter = std.mem.splitAny(u8, stdout.items, ifs);
                while (iter.next()) |item| {
                    if (item.len == 0) continue;
                    try result.append(item);
                }
            },
        }
        return result.items;
    }
};

fn createFile(dir: std.fs.Dir, path: []const u8, flags: posix.O) !std.posix.fd_t {
    const cpath = try posix.toPosixPath(path);
    return posix.openatZ(dir.fd, &cpath, flags, std.fs.File.default_mode);
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
