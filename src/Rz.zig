const Rz = @This();

const std = @import("std");
const assert = std.debug.assert;
const vaxis = @import("vaxis");
const ast = @import("ast.zig");

const Line = @import("Line.zig");

const log = std.log.scoped(.rz);

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

allocator: std.mem.Allocator,
vx: vaxis.Vaxis,
tty: vaxis.Tty,
env: std.process.EnvMap,
exit: ?u8 = null,
callstack: std.ArrayList([]const u8),

pub fn init(allocator: std.mem.Allocator) !Rz {
    var env = try std.process.getEnvMap(allocator);
    // ifs=(' ' \t \n)
    try env.put("ifs", " \x01\t\x01\n");
    try env.put("nl", "\n");
    try env.put("tab", "\t");
    try env.put("prompt", "> \x01\x01\x01");
    if (env.get("HOME")) |home| {
        try env.put("home", home);
    }
    if (env.get("HOME")) |home| {
        try env.put("home", home);
    }
    if (env.get("PATH")) |path| {
        const path2 = try allocator.dupe(u8, path);
        const key2 = try allocator.dupe(u8, "path");
        std.mem.replaceScalar(u8, path2, ':', '\x01');
        try env.putMove(key2, path2);
    }

    // TODO: pid

    return .{
        .allocator = allocator,
        .vx = try vaxis.init(allocator, .{ .kitty_keyboard_flags = .{ .report_events = true } }),
        .tty = try vaxis.Tty.init(),
        .env = env,
        .callstack = std.ArrayList([]const u8).init(allocator),
    };
}

pub fn deinit(self: *Rz) void {
    self.vx.deinit(self.allocator, self.tty.anyWriter());
    self.tty.deinit();
    self.env.deinit();
}

pub fn run(self: *Rz) !u8 {
    var writer = self.tty.bufferedWriter();
    const any = writer.writer().any();

    // Load config files
    {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var files = try std.ArrayList([]const u8).initCapacity(arena.allocator(), 8);
        try files.append("/etc/rz/config.rz");
        if (self.env.get("XDG_DATA_DIRS")) |dirs| {
            var iter = std.mem.splitScalar(u8, dirs, ':');
            while (iter.next()) |dir| {
                const path = try std.fs.path.join(arena.allocator(), &.{ dir, "rz/config.rz" });
                try files.append(path);
            }
        }
        if (self.env.get("XDG_CONFIG_HOME")) |dir| {
            const path = try std.fs.path.join(arena.allocator(), &.{ dir, "rz/config.rz" });
            try files.append(path);
        } else if (self.env.get("HOME")) |dir| {
            const path = try std.fs.path.join(arena.allocator(), &.{ dir, ".config/rz/config.rz" });
            try files.append(path);
        }

        for (files.items) |path| {
            log.debug("trying config at {s}", .{path});
            const file = std.fs.openFileAbsolute(
                path,
                .{ .mode = .read_only },
            ) catch continue;
            const src = try file.readToEndAlloc(self.allocator, 1_000_000);
            defer self.allocator.free(src);
            const fd = try std.posix.dup(self.tty.fd);
            self.exec(src) catch |err| {
                switch (err) {
                    error.FileNotFound => try any.print("rz: command not found\r\n", .{}),
                    std.mem.Allocator.Error.OutOfMemory => try any.print("rz: out of memory\r\n", .{}),

                    // TODO: Print to stdout at the location of the error everywhere in exec
                    else => try any.print("rz: unexpected error: {}\r\n", .{err}),
                }
            };
            try std.posix.dup2(fd, std.posix.STDOUT_FILENO);
            self.tty.fd = fd;
            try makeRaw(self.tty);
        }
    }
    var loop: vaxis.Loop(Event) = .{
        .vaxis = &self.vx,
        .tty = &self.tty,
    };
    try loop.init();

    try loop.start();
    defer loop.stop();

    try self.vx.queryTerminal(self.tty.anyWriter(), 1 * std.time.ns_per_s);

    var zedit = Line.init(self.allocator, &self.vx.unicode);
    defer zedit.deinit();
    try zedit.buf.ensureTotalCapacity(256);

    // arena allocator for parsing
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| blk: {
                if (key.matches('c', .{ .ctrl = true })) {
                    break;
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    _ = arena.reset(.retain_capacity);
                    loop.stop();

                    try any.writeAll("\r\n");
                    if (self.vx.caps.kitty_keyboard)
                        try any.writeAll(vaxis.ctlseqs.csi_u_pop);
                    try writer.flush();
                    const fd = try std.posix.dup(self.tty.fd);
                    self.exec(zedit.buf.items) catch |err| {
                        switch (err) {
                            error.FileNotFound => try any.print("rz: command not found\r\n", .{}),
                            std.mem.Allocator.Error.OutOfMemory => try any.print("rz: out of memory\r\n", .{}),

                            // TODO: Print to stdout at the location of the error everywhere in exec
                            else => try any.print("rz: unexpected error: {}\r\n", .{err}),
                        }
                    };
                    self.callstack.clearAndFree();
                    try any.writeAll(vaxis.ctlseqs.hide_cursor);
                    if (self.vx.caps.kitty_keyboard) {
                        const flags: vaxis.Key.KittyFlags = .{ .report_events = true };
                        const flag_int: u5 = @bitCast(flags);
                        try any.print(vaxis.ctlseqs.csi_u_push, .{flag_int});
                    }
                    zedit.clearRetainingCapacity();
                    try std.posix.dup2(fd, std.posix.STDOUT_FILENO);
                    self.tty.fd = fd;
                    try makeRaw(self.tty);
                    try loop.start();
                    const win = self.vx.window();
                    win.clear();
                    try self.vx.render(any);
                    try writer.flush();

                    // we check exit condition after restarting loop so we can properly clean up
                    // vaxis
                    if (self.exit) |exit| return exit;
                } else {
                    try zedit.update(.{ .key_press = key });
                    const cmds = ast.parse(zedit.buf.items, allocator) catch break :blk;
                    _ = cmds;
                }
            },

            .winsize => |ws| {
                if (ws.cols != self.vx.screen.width or ws.rows != self.vx.screen.height) {
                    try self.vx.resize(self.allocator, self.tty.anyWriter(), ws);
                    var buf: [8]u8 = undefined;
                    const rows = try std.fmt.bufPrint(&buf, "{d}", .{ws.rows});
                    try self.env.put("LINES", rows);
                    const cols = try std.fmt.bufPrint(&buf, "{d}", .{ws.cols});
                    try self.env.put("COLUMNS", cols);
                }
            },
            else => {},
        }

        const win = self.vx.window();
        win.clear();
        win.hideCursor();
        zedit.draw(win);

        try self.vx.render(any);
        try writer.flush();
    }

    return 0;
}

fn exec(self: *Rz, src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    resetTty(self.tty);
    const cmds = try ast.parse(src, allocator);
    for (cmds) |cmd| {
        switch (cmd) {
            .simple => |simple| try self.execSimple(allocator, simple),
            .function => |func| {
                var buf: [256]u8 = undefined;
                const key = try std.fmt.bufPrint(&buf, "fn#{s}", .{func.name});
                try self.env.put(key, func.body);
            },
            .assignment => |assignment| try self.execAssignment(allocator, assignment),
        }
        if (self.callstack.items.len > 0 and self.exit != null) {
            self.setStatus(self.exit.?);
            self.exit = null;
            return;
        }
    }
}

fn execAssignment(self: *Rz, allocator: std.mem.Allocator, cmd: ast.Assignment) !void {
    switch (cmd.value.tag) {
        .word => try self.env.put(cmd.key, cmd.value.val),
        .variable => {
            if (self.env.get(cmd.value.val)) |val| {
                try self.env.put(cmd.key, val);
            }
        },
        .variable_string => {
            if (self.env.get(cmd.value.val)) |val| {
                const val2 = try allocator.dupe(u8, val);
                std.mem.replaceScalar(u8, val2, '\x01', ' ');
                try self.env.put(cmd.key, val2);
            } else try self.env.put(cmd.key, "");
        },
        .variable_count => {
            if (self.env.get(cmd.value.val)) |val| {
                const n = std.mem.count(u8, val, "\x01");
                var buf: [8]u8 = undefined;
                const val2 = try std.fmt.bufPrint(&buf, "{d}", .{n});
                try self.env.put(cmd.key, val2);
            } else try self.env.put(cmd.key, "0");
        },
        else => unreachable,
    }
}

fn execSimple(self: *Rz, allocator: std.mem.Allocator, simple: ast.Simple) !void {
    for (simple.assignments) |assignment| {
        try self.execAssignment(allocator, assignment);
    }
    defer {
        for (simple.assignments) |assignment| {
            self.env.remove(assignment.key);
        }
    }

    var args = try std.ArrayList([]const u8).initCapacity(allocator, simple.arguments.len);
    for (simple.arguments) |arg| {
        switch (arg.tag) {
            .word => try args.append(arg.val),
            .variable => {
                if (self.env.get(arg.val)) |val| {
                    try args.append(val);
                }
            },
            .variable_string => {
                if (self.env.get(arg.val)) |val| {
                    const val2 = try allocator.dupe(u8, val);
                    std.mem.replaceScalar(u8, val2, '\x01', ' ');
                    try args.append(val2);
                } else try args.append("");
            },
            .variable_count => {
                if (self.env.get(arg.val)) |val| {
                    const n = std.mem.count(u8, val, "\x01");
                    var buf: [8]u8 = undefined;
                    const val2 = try std.fmt.bufPrint(&buf, "{d}", .{n});
                    try args.append(val2);
                } else try args.append("0");
            },
            .equal => try args.append("="),
            else => {},
        }
        if (arg.concatenate) blk: {
            const last = args.popOrNull() orelse break :blk;
            const penultimate = args.popOrNull() orelse {
                try args.append(last);
                break :blk;
            };
            const result = try std.mem.concat(allocator, u8, &.{ penultimate, last });
            try args.append(result);
        }
    }

    if (args.items.len == 0) return;

    for (simple.redirections) |redir| {
        switch (redir.fd) {
            std.posix.STDIN_FILENO => {},
            std.posix.STDOUT_FILENO,
            std.posix.STDERR_FILENO,
            => {
                const dst = redir.source.arg;
                switch (dst.tag) {
                    .word => {
                        const dir = std.fs.cwd();
                        const flags: std.posix.O = .{
                            .ACCMODE = .WRONLY,
                            .CREAT = true,
                            .TRUNC = redir.truncate,
                            .APPEND = !redir.truncate,
                        };
                        const fd = try createFile(dir, dst.val, flags);
                        defer std.posix.close(fd);
                        try std.posix.dup2(fd, redir.fd);
                    },
                    else => @panic("TODO"),
                }
            },
            else => {},
        }
    }

    if (std.mem.eql(u8, "builtin", args.items[0])) {
        if (self.execBuiltin(allocator, args.items[1..])) return;
        var process = std.process.Child.init(args.items[1..], allocator);
        process.env_map = &self.env;
        const exit = try process.spawnAndWait();
        switch (exit) {
            .Exited => |val| self.setStatus(val),
            else => {},
        }
    } else {
        for (self.callstack.items) |item| {
            if (std.mem.eql(u8, item, args.items[0])) {
                try self.tty.anyWriter().print(
                    "rz: function '{s}' called recursively. Consider using `builtin {s}`",
                    .{ item, item },
                );
                return error.InfiniteLoop;
            }
        }
        if (self.execFunction(args.items)) return;
        if (self.execBuiltin(allocator, args.items)) return;

        var process = std.process.Child.init(args.items, allocator);
        process.env_map = &self.env;
        const exit = try process.spawnAndWait();
        switch (exit) {
            .Exited => |val| self.setStatus(val),
            else => {},
        }
    }
}

fn setStatus(self: *Rz, status: u8) void {
    var buf: [8]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{status}) catch return;
    self.env.put("status", str) catch return;
}

fn execBuiltin(self: *Rz, allocator: std.mem.Allocator, args: []const []const u8) bool {
    assert(args.len > 0);
    if (std.mem.eql(u8, "cd", args[0])) {
        if (args.len == 1) {
            if (self.env.get("home")) |home| {
                std.process.changeCurDir(home) catch return true;
            }
            return true;
        }
        if (args[1][0] == '/') {
            std.process.changeCurDir(args[1]) catch return true;
            return true;
        }
        var components = std.ArrayList([]const u8).init(allocator);
        // we add a / because path.join doesn't return an absolute path
        components.append("/") catch return true;
        const cwd = std.process.getCwdAlloc(allocator) catch return true;
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

        const path = std.fs.path.join(allocator, components.items) catch return true;
        std.process.changeCurDir(path) catch |err| {
            log.err("cd: couldn't change directory: {}", .{err});
            return true;
        };
        return true;
    }
    if (std.mem.eql(u8, "exit", args[0])) {
        if (args.len > 1)
            self.exit = std.fmt.parseUnsigned(u8, args[1], 10) catch return false
        else
            self.exit = 0;
        return true;
    }
    return false;
}

fn execFunction(self: *Rz, args: []const []const u8) bool {
    assert(args.len > 0);

    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "fn#{s}", .{args[0]}) catch return false;
    if (self.env.get(key)) |val| {
        self.callstack.append(args[0]) catch {};
        self.exec(val) catch {
            self.tty.anyWriter().writeAll("\r\n") catch {};
            return true;
        };
        return true;
    }
    return false;
}

fn resetTty(tty: vaxis.Tty) void {
    std.posix.tcsetattr(tty.fd, .FLUSH, tty.termios) catch |err| {
        std.log.err("couldn't restore terminal: {}", .{err});
    };
}

fn makeRaw(tty: vaxis.Tty) !void {
    _ = try vaxis.Tty.makeRaw(tty.fd);
}

fn createFile(dir: std.fs.Dir, path: []const u8, flags: std.posix.O) !std.posix.fd_t {
    const cpath = try std.posix.toPosixPath(path);
    return std.posix.openatZ(dir.fd, &cpath, flags, std.fs.File.default_mode);
}
