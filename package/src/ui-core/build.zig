const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("electrobun_ui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkPlatform(mod, target);

    const shot = b.addExecutable(.{
        .name = "shot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/shot.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "electrobun_ui", .module = mod }},
        }),
    });
    b.installArtifact(shot);

    const gpushot = b.addExecutable(.{
        .name = "gpushot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gpushot.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "electrobun_ui", .module = mod }},
        }),
    });
    b.installArtifact(gpushot);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run UI core tests");
    test_step.dependOn(&run_tests.step);
}

pub fn linkPlatform(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .macos) {
        mod.linkFramework("CoreText", .{});
        mod.linkFramework("CoreGraphics", .{});
        mod.linkFramework("CoreFoundation", .{});
    }
}
