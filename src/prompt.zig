const std = @import("std");
const vaxis = @import("vaxis");

pub fn sgr(style: *vaxis.Style, seq: CSI) void {
    if (seq.params.len == 0) {
        style.* = .{};
        return;
    }

    var iter = seq.iterator(u8);
    while (iter.next()) |ps| {
        switch (ps) {
            0 => style.* = .{},
            1 => style.bold = true,
            2 => style.dim = true,
            3 => style.italic = true,
            4 => {
                const kind: vaxis.Style.Underline = if (iter.next_is_sub)
                    @enumFromInt(iter.next() orelse 1)
                else
                    .single;
                style.ul_style = kind;
            },
            5 => style.blink = true,
            7 => style.reverse = true,
            8 => style.invisible = true,
            9 => style.strikethrough = true,
            21 => style.ul_style = .double,
            22 => {
                style.bold = false;
                style.dim = false;
            },
            23 => style.italic = false,
            24 => style.ul_style = .off,
            25 => style.blink = false,
            27 => style.reverse = false,
            28 => style.invisible = false,
            29 => style.strikethrough = false,
            30...37 => style.fg = .{ .index = ps - 30 },
            38 => {
                // must have another parameter
                const kind = iter.next() orelse return;
                switch (kind) {
                    2 => { // rgb
                        const r = r: {
                            // First param can be empty
                            var ps_r = iter.next() orelse return;
                            if (iter.is_empty)
                                ps_r = iter.next() orelse return;
                            break :r ps_r;
                        };
                        const g = iter.next() orelse return;
                        const b = iter.next() orelse return;
                        style.fg = .{ .rgb = .{ r, g, b } };
                    },
                    5 => {
                        const idx = iter.next() orelse return;
                        style.fg = .{ .index = idx };
                    }, // index
                    else => return,
                }
            },
            39 => style.fg = .default,
            40...47 => style.bg = .{ .index = ps - 40 },
            48 => {
                // must have another parameter
                const kind = iter.next() orelse return;
                switch (kind) {
                    2 => { // rgb
                        const r = r: {
                            // First param can be empty
                            var ps_r = iter.next() orelse return;
                            if (iter.is_empty)
                                ps_r = iter.next() orelse return;
                            break :r ps_r;
                        };
                        const g = iter.next() orelse return;
                        const b = iter.next() orelse return;
                        style.bg = .{ .rgb = .{ r, g, b } };
                    },
                    5 => {
                        const idx = iter.next() orelse return;
                        style.bg = .{ .index = idx };
                    }, // index
                    else => return,
                }
            },
            49 => style.bg = .default,
            90...97 => style.fg = .{ .index = ps - 90 + 8 },
            100...107 => style.bg = .{ .index = ps - 100 + 8 },
            else => continue,
        }
    }
}

pub const CSI = struct {
    params: []const u8,

    pub fn hasIntermediate(self: CSI, b: u8) bool {
        return b == self.intermediate orelse return false;
    }

    pub fn hasPrivateMarker(self: CSI, b: u8) bool {
        return b == self.private_marker orelse return false;
    }

    pub fn iterator(self: CSI, comptime T: type) ParamIterator(T) {
        return .{ .bytes = self.params };
    }

    pub fn format(
        self: CSI,
        comptime layout: []const u8,
        opts: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = layout;
        _ = opts;
        if (self.private_marker == null and self.intermediate == null)
            try std.fmt.format(writer, "CSI {s} {c}", .{
                self.params,
                self.final,
            })
        else if (self.private_marker != null and self.intermediate == null)
            try std.fmt.format(writer, "CSI {c} {s} {c}", .{
                self.private_marker.?,
                self.params,
                self.final,
            })
        else if (self.private_marker == null and self.intermediate != null)
            try std.fmt.format(writer, "CSI {s} {c} {c}", .{
                self.params,
                self.intermediate.?,
                self.final,
            })
        else
            try std.fmt.format(writer, "CSI {c} {s} {c} {c}", .{
                self.private_marker.?,
                self.params,
                self.intermediate.?,
                self.final,
            });
    }
};

pub fn ParamIterator(T: type) type {
    return struct {
        const Self = @This();

        bytes: []const u8,
        idx: usize = 0,
        /// indicates the next parameter will be a sub parameter of the current
        next_is_sub: bool = false,
        /// indicates the current parameter was an empty string
        is_empty: bool = false,

        pub fn next(self: *Self) ?T {
            // reset state
            self.next_is_sub = false;
            self.is_empty = false;

            const start = self.idx;
            var val: T = 0;
            while (self.idx < self.bytes.len) {
                defer self.idx += 1; // defer so we trigger on return as well
                const b = self.bytes[self.idx];
                switch (b) {
                    0x30...0x39 => {
                        val = (val * 10) + (b - 0x30);
                        if (self.idx == self.bytes.len - 1) return val;
                    },
                    ':', ';' => {
                        self.next_is_sub = b == ':';
                        self.is_empty = self.idx == start;
                        return val;
                    },
                    else => return null,
                }
            }
            return null;
        }

        /// verifies there are at least n more parameters
        pub fn hasAtLeast(self: *Self, n: usize) bool {
            const start = self.idx;
            defer self.idx = start;

            var i: usize = 0;
            while (self.next()) |_| {
                i += 1;
                if (i >= n) return true;
            }
            return i >= n;
        }
    };
}
