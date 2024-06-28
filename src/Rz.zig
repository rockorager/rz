const Rz = @This();

const std = @import("std");
const assert = std.debug.assert;
const vaxis = @import("vaxis");
const ast = @import("ast.zig");
const interpreter = @import("interpreter.zig");

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
            const exit = try interpreter.exec(self.allocator, src, &self.env);
            if (exit) |code| return code;
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

                    resetTty(self.tty);
                    // Only returns an error for OutOfMemory
                    const exit = try interpreter.exec(self.allocator, zedit.buf.items, &self.env);

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
                    // we check exit condition after restarting loop so we can properly clean up
                    // vaxis
                    if (exit) |code| return code;

                    const win = self.vx.window();
                    win.clear();
                    try self.vx.render(any);
                    try writer.flush();
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

fn resetTty(tty: vaxis.Tty) void {
    std.posix.tcsetattr(tty.fd, .FLUSH, tty.termios) catch |err| {
        std.log.err("couldn't restore terminal: {}", .{err});
    };
}

fn makeRaw(tty: vaxis.Tty) !void {
    _ = try vaxis.Tty.makeRaw(tty.fd);
}
