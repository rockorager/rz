const std = @import("std");
const testing = std.testing;
const ast = @import("ast.zig");
const Allocator = std.mem.Allocator;

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
            .quoted_word => {},
            .variable => |v| {
                if (self.env.get(v)) |val| {
                    var iter = std.mem.splitScalar(u8, val, '\x01');
                    while (iter.next()) |item| {
                        try result.append(item);
                    }
                }
            },
            .variable_count => {},
            .variable_string => {},
            .variable_subscript => {},
            .concatenate => {},
            .list => {},
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
        const result = try interp.resolveArg(.{ .variable = "foo" });
        try testing.expectEqual(0, result.len);
    }
    {
        try env.put("foo", "bar");
        const result = try interp.resolveArg(.{ .variable = "foo" });
        try testing.expectEqual(1, result.len);
        try testing.expectEqualStrings("bar", result[0]);
    }
}
