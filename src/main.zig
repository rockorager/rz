const std = @import("std");
const vaxis = @import("vaxis");
const rz = @import("rz.zig");

const log = std.log.scoped(.rz);

pub const panic = vaxis.panic_handler;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) {
            log.err("memory leak", .{});
        }
    }
    const allocator = gpa.allocator();

    var shell = try rz.Shell.init(allocator);

    var map = try std.process.getEnvMap(allocator);
    var iter = map.iterator();
    while (iter.next()) |v| {
        log.debug("{s}={s}", .{ v.key_ptr.*, v.value_ptr.* });
    }
    defer map.deinit();
    defer shell.deinit();
    try shell.run();
}

test "simple test" {
    _ = @import("lex.zig");
    _ = @import("Line.zig");
}
