const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tools = b.option(bool, "tools", "Build the dev tools and examples") orelse true;
    macos_sdk = b.option([]const u8, "macos-sdk", "macOS SDK path (needed when cross-compiling)");

    const mod = b.addModule("electrobun_ui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkPlatform(mod, target);

    if (!tools) {
        const lib_only = b.addLibrary(.{ .name = "ElectrobunUI", .linkage = .dynamic, .root_module = libModule(b, target, optimize) });
        b.installArtifact(lib_only);
        return;
    }

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

    if (target.result.os.tag == .macos) {
        const devhost = b.addExecutable(.{
            .name = "devhost",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/devhost.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "electrobun_ui", .module = mod }},
            }),
        });
        devhost.root_module.linkFramework("AppKit", .{});
        devhost.root_module.linkFramework("QuartzCore", .{});
        devhost.root_module.linkFramework("Metal", .{});
        b.installArtifact(devhost);

        const todo = b.addExecutable(.{
            .name = "todo",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/todo.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "electrobun_ui", .module = mod }},
            }),
        });
        todo.root_module.linkFramework("AppKit", .{});
        todo.root_module.linkFramework("QuartzCore", .{});
        b.installArtifact(todo);
    }

    // libElectrobunUI shared library
    const lib = b.addLibrary(.{ .name = "ElectrobunUI", .linkage = .dynamic, .root_module = libModule(b, target, optimize) });
    b.installArtifact(lib);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run UI core tests");
    test_step.dependOn(&run_tests.step);
}

fn libModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkPlatform(lib_mod, target);
    if (target.result.os.tag == .macos) lib_mod.addRPathSpecial("@executable_path");
    return lib_mod;
}

var macos_sdk: ?[]const u8 = null;

pub fn linkPlatform(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .macos) {
        if (macos_sdk) |sdk| {
            const b = mod.owner;
            mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
            mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        }
        mod.linkFramework("CoreText", .{});
        mod.linkFramework("CoreGraphics", .{});
        mod.linkFramework("CoreFoundation", .{});
        mod.linkFramework("ImageIO", .{});
    }
}
