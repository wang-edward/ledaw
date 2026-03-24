const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = std.builtin.OptimizeMode.Debug;

    // raylib
    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib = raylib_dep.module("raylib"); // main raylib module
    const raygui = raylib_dep.module("raygui"); // raygui module
    const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library

    // soundio
    const soundio_dep = b.dependency("libsoundio", .{
        .target = target,
        .optimize = optimize,
    });
    const soundio_mod = soundio_dep.module("SoundIo");
    const soundio_artifact = soundio_dep.artifact("soundio");

    // main module
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "raylib", .module = raylib },
            .{ .name = "raygui", .module = raygui },
            .{ .name = "soundio", .module = soundio_mod },
        },
    });
    main_mod.linkLibrary(soundio_artifact);

    // exe
    const exe = b.addExecutable(.{
        .name = "synth",
        .root_module = main_mod,
    });
    exe.linkLibrary(raylib_artifact);
    exe.linkLibrary(soundio_artifact);
    exe.linkLibC();
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // fuzz
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test_fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "main", .module = main_mod },
                .{ .name = "raylib", .module = raylib },
            },
        }),
    });
    fuzz_exe.linkLibrary(raylib_artifact);
    fuzz_exe.linkLibrary(soundio_artifact);
    fuzz_exe.linkLibC();
    b.installArtifact(fuzz_exe);
    const fuzz_run = b.addRunArtifact(fuzz_exe);
    fuzz_run.step.dependOn(b.getInstallStep());
    const fuzz_step = b.step("fuzz", "Run fuzz test");
    fuzz_step.dependOn(&fuzz_run.step);

    // art
    const art_exe = b.addExecutable(.{
        .name = "art",
        .root_module = b.createModule(.{
            .root_source_file = b.path("art/art.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "main", .module = main_mod },
                .{ .name = "raylib", .module = raylib },
            },
        }),
    });
    art_exe.linkLibrary(raylib_artifact);
    art_exe.linkLibrary(soundio_artifact);
    art_exe.linkLibC();
    b.installArtifact(art_exe);
    const art_run = b.addRunArtifact(art_exe);
    art_run.step.dependOn(b.getInstallStep());
    const art_step = b.step("art", "Run art project");
    art_step.dependOn(&art_run.step);

    // test
    const queue_mod = b.createModule(.{
        .root_source_file = b.path("src/queue.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test_queue.zig"),
            .imports = &.{
                .{ .name = "queue", .module = queue_mod },
            },
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_exe_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
