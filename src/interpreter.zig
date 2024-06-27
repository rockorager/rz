const std = @import("std");
const testing = std.testing;
const ast = @import("ast.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.interpreter);

/// executes `src` as an rz script. env will be updated as necessary
pub fn exec(allocator: std.mem.Allocator, src: []const u8, env: *std.process.EnvMap) !u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cmds = try ast.parse(src, alloc);

    var interp: Interpreter = .{
        .allocator = alloc,
        .env = env,
    };
    return interp.exec(cmds);
}

const Interpreter = struct {
    arena: std.mem.Allocator,
    env: *std.process.EnvMap,

    /// exec can only error for out of memory
    fn exec(self: *Interpreter, cmds: []const ast.Command) Allocator.Error!u8 {
        for (cmds) |cmd| {
            switch (cmd) {
                .simple => |simple| try self.execSimple(simple),
                .function => |func| {
                    var buf: [256]u8 = undefined;
                    const key = try std.fmt.bufPrint(&buf, "fn#{s}", .{func.name});
                    try self.env.put(key, func.body);
                },
                .assignment => |assignment| try self.execAssignment(self.arena(), assignment),
            }
            // if (self.callstack.items.len > 0 and self.exit != null) {
            //     self.setStatus(self.exit.?);
            //     self.exit = null;
            //     return;
            // }
        }
    }

    fn execAssignment(self: *Interpreter, cmd: ast.Assignment) Allocator.Error!u8 {
        switch (cmd.value.tag) {
            .word => try self.env.put(cmd.key, cmd.value.val),
            // .variable => {
            //     if (self.env.get(cmd.value.val)) |val| {
            //         try self.env.put(cmd.key, val);
            //     }
            // },
            // .variable_string => {
            //     if (self.env.get(cmd.value.val)) |val| {
            //         const val2 = try allocator.dupe(u8, val);
            //         std.mem.replaceScalar(u8, val2, '\x01', ' ');
            //         try self.env.put(cmd.key, val2);
            //     } else try self.env.put(cmd.key, "");
            // },
            // .variable_count => {
            //     if (self.env.get(cmd.value.val)) |val| {
            //         const n = std.mem.count(u8, val, "\x01");
            //         var buf: [8]u8 = undefined;
            //         const val2 = try std.fmt.bufPrint(&buf, "{d}", .{n});
            //         try self.env.put(cmd.key, val2);
            //     } else try self.env.put(cmd.key, "0");
            // },
            else => unreachable,
        }
    }

    /// resolves an argument to list of strings
    /// quoted_word is unquoted
    fn resolveArg(self: *Interpreter, arg: ast.Argument) Allocator.Error![]const []const u8 {
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
                        continue;
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
                    return result.items;
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
