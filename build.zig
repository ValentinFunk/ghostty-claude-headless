const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (b.lazyDependency("ghostty", .{
        .@"emit-lib-vt" = true,
        .@"emit-xcframework" = false,
    })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const exe = b.addExecutable(.{
        .name = "ghostty-claude-headless",
        .root_module = exe_mod,
    });
    exe.linkLibC();
    if (target.result.os.tag != .macos) exe.linkSystemLibrary("util");
    b.installArtifact(exe);

    const run_step = b.step("run", "Run ghostty-claude-headless");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = exe_mod });
    unit_tests.linkLibC();
    if (target.result.os.tag != .macos) unit_tests.linkSystemLibrary("util");
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const e2e_step = b.step("e2e", "Build and run the real Claude e2e smoke test");
    const e2e = b.addSystemCommand(&.{ "./scripts/e2e-claude.sh", b.getInstallPath(.bin, "ghostty-claude-headless") });
    e2e.step.dependOn(b.getInstallStep());
    e2e_step.dependOn(&e2e.step);
}
