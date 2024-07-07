const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const Rz = @import("Rz.zig");

const log = std.log.scoped(.rz);

pub const panic = vaxis.panic_handler;

pub const std_options = .{
    .logFn = logFn,
};

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    logargs: anytype,
) void {
    switch (scope) {
        .interpreter => {
            const stderr = std.io.getStdErr().writer();
            std.debug.lockStdErr();
            defer std.debug.unlockStdErr();
            var bw = std.io.bufferedWriter(stderr);
            const writer = bw.writer();
            writer.print("rz: " ++ format ++ "\r\n", logargs) catch return;
            bw.flush() catch return;
        },
        else => {
            const lf = log_file orelse return;

            const level_txt = comptime level.asText();
            const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

            var bw = std.io.bufferedWriter(lf.writer());
            const writer = bw.writer();
            writer.print(level_txt ++ prefix2 ++ format ++ "\n", logargs) catch return;
            bw.flush() catch return;
        },
    }
}

var log_file: ?std.fs.File = null;

pub var args: struct {
    /// prints each executed function, builtin, or command to stderr prior to executing
    verbose: bool = false,
} = .{};

pub fn main() !u8 {
    if (builtin.mode == .Debug)
        log_file = try std.fs.cwd().createFile("rz.log", .{ .truncate = true });
    defer if (log_file) |lf| lf.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) {
            log.err("memory leak", .{});
        }
    }
    const allocator = gpa.allocator();

    var arg_iter = std.process.args();
    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v"))
            args.verbose = true;
    }

    var rz = try Rz.init(allocator);

    defer rz.deinit();
    return rz.run();
}

test "simple test" {
    _ = @import("ast.zig");
    _ = @import("interpreter.zig");
    _ = @import("lex.zig");
    _ = @import("Line.zig");
    _ = @import("Rz.zig");
}
