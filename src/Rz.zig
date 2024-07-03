const Rz = @This();

const std = @import("std");
const assert = std.debug.assert;
const vaxis = @import("vaxis");
const ast = @import("ast.zig");
const interpreter = @import("interpreter.zig");
const prompt = @import("prompt.zig");
const History = @import("History.zig");

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
/// A reference to the prompt string
prompt_str: ?[]const u8 = null,
history: History,

pub fn init(allocator: std.mem.Allocator) !Rz {
    var env = try std.process.getEnvMap(allocator);
    // ifs=(' ' \t \n)
    try env.put("ifs", " \x01\t\x01\n");
    try env.put("nl", "\n");
    try env.put("tab", "\t");
    try env.put("prompt", "> \x01\x01\x01");
    try env.put("status", "0");
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
        .history = .{
            .allocator = allocator,
            .file = "/home/tim/.local/share/rz/history",
            .entries = std.ArrayList(History.Entry).init(allocator),
        },
    };
}

pub fn deinit(self: *Rz) void {
    self.vx.deinit(self.allocator, self.tty.anyWriter());
    self.tty.deinit();
    self.env.deinit();
    if (self.prompt_str) |str| {
        self.allocator.free(str);
    }
    self.history.deinit();
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
            _ = try interpreter.exec(self.allocator, src, &self.env);
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

    try self.updatePrompt(&zedit);

    try self.history.init();

    var history_index: ?usize = null;

    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| blk: {
                if (key.matches(vaxis.Key.enter, .{})) {
                    zedit.hint = "";
                    history_index = null;
                    if (zedit.buf.items.len == 0) {
                        try any.writeAll(vaxis.ctlseqs.sync_set ++ "\r\n");
                        try self.clearInternalScreen();
                        break :blk;
                    }
                    _ = arena.reset(.retain_capacity);
                    loop.stop();

                    {
                        if (self.vx.caps.kitty_keyboard)
                            try any.writeAll(vaxis.ctlseqs.csi_u_pop);
                        const n = zedit.last_drawn_row -| zedit.prev_cursor_row;
                        try any.writeAll("\r\n");
                        for (0..n) |_| {
                            try any.writeAll("\r\n");
                        }
                        try writer.flush();
                        resetTty(self.tty);
                    }

                    // Only returns an error for OutOfMemory
                    const exit = try interpreter.exec(self.allocator, zedit.buf.items, &self.env);
                    try any.writeAll(vaxis.ctlseqs.hide_cursor);
                    try writer.flush();
                    const pwd = try std.process.getCwdAlloc(self.allocator);
                    defer self.allocator.free(pwd);
                    try self.history.append(zedit.buf.items, pwd, exit);

                    {
                        for (0..zedit.last_drawn_row) |_| {
                            try any.writeAll("\r\n");
                        }
                        if (self.vx.caps.kitty_keyboard) {
                            const flags: vaxis.Key.KittyFlags = .{ .report_events = true };
                            const flag_int: u5 = @bitCast(flags);
                            try any.print(vaxis.ctlseqs.csi_u_push, .{flag_int});
                        }
                        zedit.clearRetainingCapacity();
                        try makeRaw(self.tty);
                        try loop.start();
                        try writer.flush();
                    }
                    {
                        // Internally clear our model. We write to a null_writer because we don't
                        // actually have to write these bits
                        try self.updatePrompt(&zedit);
                        try self.clearInternalScreen();
                    }
                    {
                        try any.writeAll(vaxis.ctlseqs.sync_set);
                        try any.writeAll(vaxis.ctlseqs.erase_below_cursor);
                        try writer.flush();
                    }
                } else if (key.matches('r', .{ .ctrl = true })) {
                    // TODO: history search
                } else if (key.matches('l', .{ .ctrl = true })) {
                    try any.writeAll(vaxis.ctlseqs.sync_set);
                    try any.writeAll(vaxis.ctlseqs.hide_cursor);
                    try any.writeAll(vaxis.ctlseqs.home);
                    try any.writeAll(vaxis.ctlseqs.erase_below_cursor);
                    try writer.flush();
                    try self.clearInternalScreen();
                } else if (key.matches(vaxis.Key.up, .{})) {
                    if (history_index) |idx| {
                        history_index = @min(self.history.entries.items.len - 1, idx + 1);
                    } else {
                        history_index = 0;
                    }
                    const cmd = self.history.nthEntry(history_index.?);
                    zedit.clearRetainingCapacity();
                    try zedit.insertSliceAtCursor(cmd);
                } else if (key.matches(vaxis.Key.down, .{})) {
                    const idx = history_index orelse break :blk;
                    if (idx == 0) {
                        history_index = null;
                        zedit.clearRetainingCapacity();
                        break :blk;
                    }
                    history_index = idx -| 1;
                    const cmd = self.history.nthEntry(history_index.?);
                    zedit.clearRetainingCapacity();
                    try zedit.insertSliceAtCursor(cmd);
                } else {
                    history_index = null;
                    try zedit.update(.{ .key_press = key });
                    switch (zedit.buf.items.len) {
                        0 => zedit.hint = "",
                        else => {
                            const hint = self.history.findPrefix(zedit.buf.items);
                            zedit.hint = hint;
                        },
                    }
                    {
                        // TODO: syntax highlight
                        const cmds = ast.parse(zedit.buf.items, allocator) catch break :blk;
                        _ = cmds;
                    }
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

fn updatePrompt(self: *Rz, edit: *Line) !void {
    const status = self.env.get("status") orelse "0";
    _ = try interpreter.exec(self.allocator, "prompt", &self.env);
    try self.env.put("status", status);
    const promptstr = self.env.get("prompt") orelse return;
    if (self.prompt_str) |str| {
        self.allocator.free(str);
    }
    self.prompt_str = try self.allocator.dupe(u8, promptstr);

    var iter = std.mem.splitScalar(u8, self.prompt_str.?, '\x01');
    const left = iter.first();
    const top_left = iter.next();
    const top_right = iter.next();
    const right = iter.next();

    var segs = std.ArrayList(vaxis.Segment).init(self.allocator);
    defer segs.deinit();
    var i: usize = 0;
    var style: vaxis.Style = .{};
    while (i < left.len) {
        const esc = std.mem.indexOfScalarPos(u8, left, i, '\x1b') orelse {
            try segs.append(.{ .text = left[i..], .style = style });
            i = left.len;
            break;
        };
        try segs.append(.{ .text = left[i..esc], .style = style });
        const m = std.mem.indexOfScalarPos(u8, left, esc + 1, 'm') orelse return error.FormatError;
        const params: prompt.CSI = .{ .params = left[esc + 2 .. m] };
        prompt.sgr(&style, params);
        i = m + 1;
    }

    try edit.update(.{ .prompt = .{ .left = segs.items } });
    if (top_left) |_| {}
    if (top_right) |_| {}
    if (right) |_| {}
}

/// Writes a clear screen to a null writer, which has the effect of clearing out the internal screen
fn clearInternalScreen(self: *Rz) !void {
    const win = self.vx.window();
    win.clear();
    win.hideCursor();
    try self.vx.render(std.io.null_writer.any());
}
