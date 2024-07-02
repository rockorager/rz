const Line = @This();

const std = @import("std");
const assert = std.debug.assert;
const vaxis = @import("vaxis");
const Key = vaxis.Key;
const Cell = vaxis.Cell;
const Window = vaxis.Window;
const Unicode = vaxis.Unicode;

/// The events that this widget handles
const Event = union(enum) {
    key_press: Key,
    prompt: union(enum) {
        left: []const vaxis.Segment,
        right: []const vaxis.Segment,
        top_left: []const vaxis.Segment,
        top_right: []const vaxis.Segment,
    },
};

// Index of our cursor
cursor_idx: usize = 0,
grapheme_count: usize = 0,
buf: std.ArrayList(u8),

/// the column we placed the cursor the last time we drew
prev_cursor_col: usize = 0,
prev_cursor_row: usize = 0,
/// the grapheme index of the cursor the last time we drew
prev_cursor_idx: usize = 0,

unicode: *const Unicode,

prompt: struct {
    left: std.ArrayList(vaxis.Segment),
    right: std.ArrayList(vaxis.Segment),
    top_left: std.ArrayList(vaxis.Segment),
    top_right: std.ArrayList(vaxis.Segment),
},

/// Shown in dimmed color after the end of the line
hint: []const u8,

last_drawn_row: usize = 0,

pub fn init(alloc: std.mem.Allocator, unicode: *const Unicode) Line {
    return .{
        .buf = std.ArrayList(u8).init(alloc),
        .unicode = unicode,
        .prompt = .{
            .left = std.ArrayList(vaxis.Segment).init(alloc),
            .right = std.ArrayList(vaxis.Segment).init(alloc),
            .top_left = std.ArrayList(vaxis.Segment).init(alloc),
            .top_right = std.ArrayList(vaxis.Segment).init(alloc),
        },
        .hint = "",
    };
}

pub fn deinit(self: *Line) void {
    self.buf.deinit();
    self.prompt.left.deinit();
    self.prompt.right.deinit();
    self.prompt.top_left.deinit();
    self.prompt.top_right.deinit();
}

pub fn update(self: *Line, event: Event) !void {
    switch (event) {
        .key_press => |key| {
            if (key.matches(Key.backspace, .{})) {
                if (self.cursor_idx == 0) return;
                try self.deleteBeforeCursor();
            } else if (key.matches(Key.delete, .{}) or key.matches('d', .{ .ctrl = true })) {
                if (self.cursor_idx == self.grapheme_count) return;
                try self.deleteAtCursor();
            } else if (key.matches(Key.left, .{}) or key.matches('b', .{ .ctrl = true })) {
                if (self.cursor_idx > 0) self.cursor_idx -= 1;
            } else if (key.matches(Key.right, .{}) or key.matches('f', .{ .ctrl = true })) {
                if (self.cursor_idx == self.grapheme_count) {
                    // accept hint
                    try self.insertSliceAtCursor(self.hint);
                    self.hint = "";
                }
                if (self.cursor_idx < self.grapheme_count) self.cursor_idx += 1;
            } else if (key.matches('a', .{ .ctrl = true })) {
                self.cursor_idx = 0;
            } else if (key.matches('e', .{ .ctrl = true })) {
                self.cursor_idx = self.grapheme_count;
            } else if (key.matches('k', .{ .ctrl = true })) {
                try self.deleteToEnd();
            } else if (key.matches('u', .{ .ctrl = true })) {
                try self.deleteToStart();
            } else if (key.text) |text| {
                try self.insertSliceAtCursor(text);
            }
        },
        .prompt => |prompt| {
            switch (prompt) {
                .left => |val| {
                    self.prompt.left.clearRetainingCapacity();
                    try self.prompt.left.appendSlice(val);
                },
                .right => {},
                .top_left => {},
                .top_right => {},
            }
        },
    }
}

/// insert text at the cursor position
pub fn insertSliceAtCursor(self: *Line, data: []const u8) !void {
    var iter = self.unicode.graphemeIterator(data);
    var byte_offset_to_cursor = self.byteOffsetToCursor();
    while (iter.next()) |text| {
        try self.buf.insertSlice(byte_offset_to_cursor, text.bytes(data));
        byte_offset_to_cursor += text.len;
        self.cursor_idx += 1;
        self.grapheme_count += 1;
    }
}

pub fn sliceToCursor(self: *Line) []const u8 {
    const offset = self.byteOffsetToCursor();
    return self.buf.items[0..offset];
}

/// calculates the display width from the draw_offset to the cursor
fn widthToCursor(self: *Line, win: Window) usize {
    var width: usize = 0;
    var first_iter = self.unicode.graphemeIterator(self.buf.items);
    var i: usize = 0;
    while (first_iter.next()) |grapheme| {
        defer i += 1;
        if (i < self.draw_offset) {
            continue;
        }
        if (i == self.cursor_idx) return width;
        const g = grapheme.bytes(self.buf.items);
        width += win.gwidth(g);
    }
    return width;
}

pub fn draw(self: *Line, win: Window) void {
    if (win.width == 0) return;

    var col: usize = 0;
    var row: usize = 0;

    if (self.prompt.left.items.len > 0) {
        const result = try win.print(self.prompt.left.items, .{ .wrap = .grapheme });
        col = result.col;
        row = result.row;
    } else {
        const default_prompt: vaxis.Segment = .{ .text = "> " };
        const result = try win.printSegment(default_prompt, .{ .wrap = .grapheme });
        col = result.col;
        row = result.row;
    }

    self.prev_cursor_idx = self.cursor_idx;
    self.prev_cursor_col = col;
    self.prev_cursor_row = row;

    var first_iter = self.unicode.graphemeIterator(self.buf.items);
    var i: usize = 0;
    while (first_iter.next()) |grapheme| {
        const g = grapheme.bytes(self.buf.items);
        const w = win.gwidth(g);
        if (col + w > win.width) {
            row += 1;
            col = 0;
        }
        win.writeCell(col, row, .{
            .char = .{
                .grapheme = g,
                .width = w,
            },
        });
        col += w;
        i += 1;
        if (col >= win.width) {
            row += 1;
            col = 0;
        }
        if (i == self.cursor_idx) {
            self.prev_cursor_col = col;
            self.prev_cursor_row = row;
        }
    }

    var hint_iter = self.unicode.graphemeIterator(self.hint);
    i = 0;
    while (hint_iter.next()) |grapheme| {
        const g = grapheme.bytes(self.hint);
        const w = win.gwidth(g);
        if (col + w > win.width) {
            row += 1;
            col = 0;
        }
        win.writeCell(col, row, .{
            .char = .{
                .grapheme = g,
                .width = w,
            },
            .style = .{
                .fg = .{ .index = 8 },
            },
        });
        col += w;
        i += 1;
        if (col >= win.width) {
            row += 1;
            col = 0;
        }
    }
    win.showCursor(self.prev_cursor_col, self.prev_cursor_row);
    self.last_drawn_row = row;
}

pub fn clearAndFree(self: *Line) void {
    self.buf.clearAndFree();
    self.reset();
}

pub fn clearRetainingCapacity(self: *Line) void {
    self.buf.clearRetainingCapacity();
    self.reset();
}

pub fn toOwnedSlice(self: *Line) ![]const u8 {
    defer self.reset();
    return self.buf.toOwnedSlice();
}

fn reset(self: *Line) void {
    self.cursor_idx = 0;
    self.grapheme_count = 0;
    self.prev_cursor_col = 0;
    self.prev_cursor_idx = 0;
}

// returns the number of bytes before the cursor
// (since GapBuffers are strictly speaking not contiguous, this is a number in 0..realLength()
// which would need to be fed to realIndex() to get an actual offset into self.buf.items.ptr)
pub fn byteOffsetToCursor(self: Line) usize {
    // assumption! the gap is never in the middle of a grapheme
    // one way to _ensure_ this is to move the gap... but that's a cost we probably don't want to pay.
    var iter = self.unicode.graphemeIterator(self.buf.items);
    var offset: usize = 0;
    var i: usize = 0;
    while (iter.next()) |grapheme| {
        if (i == self.cursor_idx) break;
        offset += grapheme.len;
        i += 1;
    }
    return offset;
}

fn deleteToEnd(self: *Line) !void {
    const offset = self.byteOffsetToCursor();
    self.buf.shrinkRetainingCapacity(offset);
    self.grapheme_count = self.cursor_idx;
}

fn deleteToStart(self: *Line) !void {
    const offset = self.byteOffsetToCursor();
    var i: usize = 0;
    while (i < offset) : (i += 1) {
        _ = self.buf.orderedRemove(0);
    }
    self.grapheme_count -= self.cursor_idx;
    self.cursor_idx = 0;
}

fn deleteBeforeCursor(self: *Line) !void {
    // assumption! the gap is never in the middle of a grapheme
    // one way to _ensure_ this is to move the gap... but that's a cost we probably don't want to pay.
    var iter = self.unicode.graphemeIterator(self.buf.items);
    var offset: usize = 0;
    var i: usize = 1;
    while (iter.next()) |grapheme| {
        if (i == self.cursor_idx) {
            var j: usize = 0;
            while (j < grapheme.len) : (j += 1) {
                _ = self.buf.orderedRemove(offset);
            }
            self.cursor_idx -= 1;
            self.grapheme_count -= 1;
            return;
        }
        offset += grapheme.len;
        i += 1;
    }
}

fn deleteAtCursor(self: *Line) !void {
    // assumption! the gap is never in the middle of a grapheme
    // one way to _ensure_ this is to move the gap... but that's a cost we probably don't want to pay.
    var iter = self.unicode.graphemeIterator(self.buf.items);
    var offset: usize = 0;
    var i: usize = 1;
    while (iter.next()) |grapheme| {
        if (i == self.cursor_idx + 1) {
            var j: usize = 0;
            while (j < grapheme.len) : (j += 1) {
                _ = self.buf.orderedRemove(offset);
            }
            self.grapheme_count -= 1;
            return;
        }
        offset += grapheme.len;
        i += 1;
    }
}
