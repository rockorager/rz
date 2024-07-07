const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
        .libxev = false,
    });

    const exe = b.addExecutable(.{
        .name = "rz",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("vaxis", vaxis_dep.module("vaxis"));

    b.installArtifact(exe);
    b.installFile("default_config.rz", "share/rz/config.rz");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.root_module.addImport("vaxis", vaxis_dep.module("vaxis"));

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // check step for zls
    {
        const exe_check = b.addExecutable(.{
            .name = "rz",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe_check.root_module.addImport("vaxis", vaxis_dep.module("vaxis"));
        const check = b.step("check", "Check if rz compiles");
        check.dependOn(&exe_check.step);
    }
}
