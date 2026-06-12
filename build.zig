const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The core z-machine library, importable as "zgigye".
    const mod = b.addModule("zgigye", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The TUI frontend depends on libvaxis; the core library does not.
    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });

    // The command-line interpreter.
    const exe = b.addExecutable(.{
        .name = "zgigye",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zgigye", .module = mod },
                .{ .name = "vaxis", .module = vaxis.module("vaxis") },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the interpreter (pass a story file after --)");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Line coverage via kcov (brew install kcov). Writes an HTML report
    // and coverage.json under zig-out/coverage/.
    const coverage = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--include-path=src",
        b.pathJoin(&.{ b.install_path, "coverage" }),
    });
    coverage.addArtifactArg(mod_tests);
    const coverage_step = b.step("coverage", "Generate a test coverage report (requires kcov)");
    coverage_step.dependOn(&coverage.step);
}
