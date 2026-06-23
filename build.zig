const std = @import("std");
const rlz = @import("raylib_zig");

const Ctx = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    fn mod(c: Ctx, src: []const u8, imports: []const std.Build.Module.Import) *std.Build.Module {
        return c.b.createModule(.{
            .root_source_file = c.b.path(src),
            .target = c.target,
            .optimize = c.optimize,
            .imports = imports,
        });
    }

    fn app(
        c: Ctx,
        name: []const u8,
        root: *std.Build.Module,
        libs: []const *std.Build.Step.Compile,
        step_name: []const u8,
        step_desc: []const u8,
        hw: bool,
    ) void {
        const b = c.b;
        const exe = b.addExecutable(.{ .name = name, .root_module = root });
        for (libs) |lib| exe.linkLibrary(lib);
        if (libs.len > 0) exe.linkLibC();
        if (hw) {
            exe.linkSystemLibrary("GLESv2");
            exe.linkSystemLibrary("EGL");
            exe.linkSystemLibrary("gbm");
            exe.linkSystemLibrary("drm");
        }
        const options = b.addOptions();
        options.addOption(bool, "hw", hw);
        exe.root_module.addOptions("config", options);
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        // run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);
        b.step(step_name, step_desc).dependOn(&run.step);
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const c: Ctx = .{ .b = b, .target = target, .optimize = optimize };

    // soundio
    const soundio_dep = b.dependency("libsoundio", .{ .target = target, .optimize = optimize });
    const soundio_mod = soundio_dep.module("SoundIo"); // weird capitalization
    const soundio_artifact = soundio_dep.artifact("soundio");

    // raylib
    const raylib = b.dependency("raylib_zig", .{ .target = target, .optimize = optimize });
    const raylib_hw = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        .opengl_version = rlz.OpenglVersion.gles_2,
        .platform = rlz.PlatformBackend.drm,
    });

    const main_mod = c.mod("src/main.zig", &.{
        .{ .name = "raylib", .module = raylib.module("raylib") },
        .{ .name = "raygui", .module = raylib.module("raygui") },
        .{ .name = "soundio", .module = soundio_mod },
    });
    main_mod.linkLibrary(soundio_artifact);

    const hw_mod = c.mod("src/main.zig", &.{
        .{ .name = "raylib", .module = raylib_hw.module("raylib") },
        .{ .name = "raygui", .module = raylib_hw.module("raygui") },
        .{ .name = "soundio", .module = soundio_mod },
    });
    hw_mod.linkLibrary(soundio_artifact);

    const libs: []const *std.Build.Step.Compile = &.{ raylib.artifact("raylib"), soundio_artifact };

    const targets = [_]struct {
        root: *std.Build.Module,
        name: []const u8,
        step: []const u8,
        desc: []const u8,
        hw: bool,
        libs: []const *std.Build.Step.Compile = &.{},
    }{
        .{
            .name = "ledaw",
            .step = "run",
            .desc = "Run the emulator",
            .libs = libs,
            .hw = false,
            .root = main_mod,
        },
        .{
            .name = "ledaw_hw",
            .step = "hw",
            .desc = "Run the app",
            .libs = &.{
                raylib_hw.artifact("raylib"),
                soundio_artifact,
            },
            .hw = true,
            .root = hw_mod,
        },
        .{
            .name = "fuzz",
            .step = "fuzz",
            .desc = "Run fuzz test",
            .libs = libs,
            .hw = false,
            .root = c.mod("test/test_fuzz.zig", &.{
                .{ .name = "main", .module = main_mod },
                .{
                    .name = "raylib",
                    .module = raylib.module("raylib"),
                },
            }),
        },
        .{
            .name = "test_display",
            .step = "test_display",
            .desc = "Run display test",
            .hw = false,
            .root = c.mod("test/test_display.zig", &.{}),
        },
    };
    for (targets) |t| c.app(t.name, t.root, t.libs, t.step, t.desc, t.hw);

    // unit tests
    const queue_mod = c.mod("src/queue.zig", &.{});
    const unit_tests = b.addTest(.{
        .root_module = c.mod("test/test_queue.zig", &.{
            .{ .name = "queue", .module = queue_mod },
        }),
    });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit_tests).step);
}
