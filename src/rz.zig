const std = @import("std");
const vaxis = @import("vaxis");
const parse = @import("parse.zig");

const Line = @import("Line.zig");

const log = std.log.scoped(.rz);

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

pub const Shell = struct {
    allocator: std.mem.Allocator,
    // arena allocator for parsing
    arena: std.heap.ArenaAllocator,
    vx: vaxis.Vaxis,
    tty: vaxis.Tty,
    writer: std.io.BufferedWriter(4096, std.io.AnyWriter),
    env: std.process.EnvMap,

    pub fn init(allocator: std.mem.Allocator) !Shell {
        // Initalize a tty
        const tty = try vaxis.Tty.init();

        var env = try std.process.getEnvMap(allocator);
        // ifs=(' ' \t \n)
        try env.put("ifs", " \x01\t\x01\n");
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
            .arena = std.heap.ArenaAllocator.init(allocator),
            .vx = try vaxis.init(allocator, .{ .kitty_keyboard_flags = .{ .report_events = true } }),
            .tty = tty,
            .writer = tty.bufferedWriter(),
            .env = env,
        };
    }

    pub fn deinit(self: *Shell) void {
        self.vx.deinit(self.allocator, self.tty.anyWriter());
        self.tty.deinit();
        self.arena.deinit();
        self.env.deinit();
    }

    pub fn run(self: *Shell) !void {
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

        while (true) {
            const event = loop.nextEvent();
            switch (event) {
                .key_press => |key| {
                    if (key.matches('c', .{ .ctrl = true })) {
                        break;
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        try self.tty.anyWriter().writeAll("\r\n");
                        loop.stop();
                        self.exec(zedit.buf.items) catch |err| {
                            log.err("rz: {}", .{err});
                        };
                        zedit.clearRetainingCapacity();
                        try makeRaw(self.tty);
                        try loop.start();
                    } else {
                        try zedit.update(.{ .key_press = key });
                        const cmds = try parse.parse(zedit.buf.items, self.arena.allocator());
                        _ = cmds;
                    }
                },

                .winsize => |ws| try self.vx.resize(self.allocator, self.tty.anyWriter(), ws),
                else => {},
            }

            const win = self.vx.window();
            win.clear();
            zedit.draw(win);

            try self.vx.render(self.writer.writer().any());
            try self.writer.flush();
        }
    }

    fn exec(self: *Shell, src: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        resetTty(self.tty);
        _ = self.arena.reset(.retain_capacity);
        const cmds = try parse.parse(src, self.arena.allocator());
        for (cmds) |cmd| {
            switch (cmd) {
                .simple => |simple| {
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
                            else => {},
                        }
                    }
                    var process = std.process.Child.init(args.items, allocator);
                    process.env_map = &self.env;
                    _ = try process.spawnAndWait();
                },
            }
        }
    }
};

fn resetTty(tty: vaxis.Tty) void {
    std.posix.tcsetattr(tty.fd, .FLUSH, tty.termios) catch |err| {
        std.log.err("couldn't restore terminal: {}", .{err});
    };
}

fn makeRaw(tty: vaxis.Tty) !void {
    _ = try vaxis.Tty.makeRaw(tty.fd);
}
