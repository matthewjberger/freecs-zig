const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const freecs_module = b.createModule(.{
        .root_source_file = b.path("src/freecs.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "freecs",
        .root_module = freecs_module,
    });

    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/freecs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const lib_check = b.addLibrary(.{
        .linkage = .static,
        .name = "freecs-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/freecs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const check = b.step("check", "Check if code compiles");
    check.dependOn(&lib_check.step);

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const raylib = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");

    const boids_module = b.createModule(.{
        .root_source_file = b.path("examples/boids.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "freecs", .module = freecs_module },
            .{ .name = "raylib", .module = raylib },
        },
    });

    boids_module.linkLibrary(raylib_artifact);

    const boids = b.addExecutable(.{
        .name = "boids",
        .root_module = boids_module,
    });

    b.installArtifact(boids);

    const run_boids = b.addRunArtifact(boids);
    run_boids.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_boids.addArgs(args);
    }

    const run_boids_step = b.step("run-boids", "Run the boids example");
    run_boids_step.dependOn(&run_boids.step);

    const tower_defense_module = b.createModule(.{
        .root_source_file = b.path("examples/tower-defense.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "freecs", .module = freecs_module },
            .{ .name = "raylib", .module = raylib },
        },
    });

    tower_defense_module.linkLibrary(raylib_artifact);

    const tower_defense = b.addExecutable(.{
        .name = "tower-defense",
        .root_module = tower_defense_module,
    });

    b.installArtifact(tower_defense);

    const run_tower_defense = b.addRunArtifact(tower_defense);
    run_tower_defense.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_tower_defense.addArgs(args);
    }

    const run_tower_defense_step = b.step("run-tower-defense", "Run the tower defense example");
    run_tower_defense_step.dependOn(&run_tower_defense.step);
}
