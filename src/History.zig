const History = @This();

const std = @import("std");

pub const Error = error{
    InvalidEntry,
};

/// A history entry
pub const Entry = struct {
    command: []const u8,
    path: []const u8,
    exit_code: u8,
    /// Our history is always post epoch, never a negative number
    timestamp: u32,

    fn eql(self: Entry, command: []const u8) bool {
        return std.mem.eql(u8, self.command, command);
    }

    fn encode(self: Entry, writer: std.io.AnyWriter) anyerror!void {
        return writer.print(
            "{d}\x01{s}\x01{s}\x01{d}\n",
            .{ self.timestamp, self.path, self.command, self.exit_code },
        );
    }

    fn decode(allocator: std.mem.Allocator, line: []const u8) !Entry {
        var iter = std.mem.splitScalar(u8, line, '\x01');
        const timestamp_str = iter.first();
        const path = iter.next() orelse return error.InvalidEntry;
        const command = iter.next() orelse return error.InvalidEntry;
        const exit_code_str = iter.next() orelse return error.InvalidEntry;

        const timestamp = std.fmt.parseUnsigned(u32, timestamp_str, 10) catch return error.InvalidEntry;
        const exit_code = std.fmt.parseUnsigned(u8, exit_code_str, 10) catch return error.InvalidEntry;
        return .{
            .command = try allocator.dupe(u8, command),
            .path = try allocator.dupe(u8, path),
            .exit_code = exit_code,
            .timestamp = timestamp,
        };
    }

    fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
        return lhs.timestamp < rhs.timestamp;
    }
};

allocator: std.mem.Allocator,
entries: std.ArrayList(Entry),
file: []const u8,

pub fn init(self: *History) !void {
    var retries: u2 = 0;
    const file: std.fs.File = while (retries < 4) {
        const file = std.fs.openFileAbsolute(self.file, .{ .mode = .read_only }) catch |err| {
            retries += 1;
            switch (err) {
                std.fs.File.OpenError.FileBusy => {
                    std.time.sleep(100 * std.time.ns_per_ms);
                    retries += 1;
                    continue;
                },
                std.fs.File.OpenError.FileNotFound => return,
                else => return err,
            }
        };
        break file;
    } else return error.FileBusy;

    var buffered = std.io.bufferedReader(file.reader());
    const reader = buffered.reader().any();

    var list = std.ArrayList(u8).init(self.allocator);
    defer list.deinit();
    // 10mb
    try reader.readAllArrayList(&list, 10_000_000);
    var iter = std.mem.splitScalar(u8, list.items, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const entry = try Entry.decode(self.allocator, line);
        try self.entries.append(entry);
    }
}

pub fn deinit(self: *History) void {
    for (self.entries.items) |entry| {
        self.allocator.free(entry.command);
        self.allocator.free(entry.path);
    }
    self.entries.deinit();
}

// TODO: dedupe
pub fn append(self: *History, command: []const u8, path: []const u8, exit_code: u8) !void {
    const dir_path = std.fs.path.dirname(self.file) orelse return error.InvalidPath;
    const basename = std.fs.path.basename(self.file);

    const dir = try std.fs.openDirAbsolute(dir_path, .{});

    const flags: std.posix.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = false,
        .APPEND = true,
    };

    const fd = try std.posix.openat(dir.fd, basename, flags, std.fs.File.default_mode);
    const file: std.fs.File = .{ .handle = fd };

    const entry: Entry = .{
        .command = try self.allocator.dupe(u8, command),
        .path = try self.allocator.dupe(u8, path),
        .exit_code = exit_code,
        .timestamp = @intCast(std.time.timestamp()),
    };
    try self.entries.append(entry);
    try entry.encode(file.writer().any());
}

/// Sorts the entries in descending order by timestamp. This means the latest command is the last in
/// the list
fn sortDescending(self: *History) void {
    std.sort.block(Entry, self.entries.items, {}, Entry.lessThan);
}

/// Finds an an entry with the exact prefix and returns the most recent command. The returned text
/// is owned by History, and is trimmed of the prefix
pub fn findPrefix(self: History, cmdline: []const u8) []const u8 {
    var latest: ?Entry = null;
    for (self.entries.items) |entry| {
        if (!std.mem.startsWith(u8, entry.command, cmdline)) continue;
        if (latest) |l| {
            if (entry.timestamp > l.timestamp)
                latest = entry;
        } else latest = entry;
    }
    if (latest) |l|
        return l.command[cmdline.len..]
    else
        return "";
}

/// Returns the command from the nth position when sorted by most recent
pub fn nthEntry(self: *History, n: usize) []const u8 {
    self.sortDescending();
    const i = (self.entries.items.len -| 1) -| n;
    return self.entries.items[i].command;
}

// Algorithm:
//
// 1. entry must start with cmdline
// 2. Rank higher for more recent entries (entries with same rank are sorted by time)
// 3. Rank higher for same path
// 4. Rank higher for exit code 0
pub fn findMatches(self: History, cmdline: []const u8, path: []const u8, results: []Entry) !usize {
    var ranked = std.ArrayList(RankedEntry).init(self.allocator);
    defer ranked.deinit();

    outer: for (self.entries.items) |entry| {
        if (!std.mem.startsWith(u8, entry.command, cmdline)) continue;
        var rank: u8 = 255;
        if (std.mem.eql(u8, entry.path, path))
            rank -|= 50;
        if (entry.exit_code == 0)
            rank -|= 50;

        // dedupe
        for (ranked.items, 0..) |item, j| {
            if (item.entry.eql(entry.command)) {
                if (item.rank > rank) {
                    ranked.items[j] = .{ .rank = rank, .entry = entry };
                }
                continue :outer;
            }
        }
        try ranked.append(.{ .rank = rank, .entry = entry });
    }

    std.sort.block(RankedEntry, ranked.items, {}, RankedEntry.lessThan);
    for (ranked.items, 0..) |item, i| {
        if (i >= results.len) return i;
        results[i] = item.entry;
    }
    return ranked.items.len;
}

const RankedEntry = struct {
    rank: u8,
    entry: Entry,

    fn lessThan(_: void, lhs: RankedEntry, rhs: RankedEntry) bool {
        if (lhs.rank == rhs.rank)
            return lhs.entry.timestamp > rhs.entry.timestamp;
        return lhs.rank < rhs.rank;
    }
};
