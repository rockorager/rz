const std = @import("std");
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
    args: anytype,
) void {
    const level_txt = comptime level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    var bw = std.io.bufferedWriter(log_file.writer());
    const writer = bw.writer();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    nosuspend {
        writer.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
        bw.flush() catch return;
    }
}

var log_file: std.fs.File = undefined;

pub fn main() !void {
    log_file = try std.fs.cwd().createFile("rz.log", .{ .truncate = true });
    defer log_file.close();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) {
            log.err("memory leak", .{});
        }
    }
    const allocator = gpa.allocator();

    var rz = try Rz.init(allocator);

    var map = try std.process.getEnvMap(allocator);
    var iter = map.iterator();
    while (iter.next()) |v| {
        log.debug("{s}={s}", .{ v.key_ptr.*, v.value_ptr.* });
    }
    defer map.deinit();
    defer rz.deinit();
    try rz.run();
}

test "simple test" {
    _ = @import("lex.zig");
    _ = @import("Line.zig");
}
