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

    // The demo web frontend: one HTTP request per game turn.
    const serve_exe = b.addExecutable(.{
        .name = "zgigye-serve",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/serve.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zgigye", .module = mod },
            },
        }),
    });
    b.installArtifact(serve_exe);

    const serve_step = b.step("serve", "Run the demo web server (pass a story file after --)");
    const serve_cmd = b.addRunArtifact(serve_exe);
    serve_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| serve_cmd.addArgs(args);
    serve_step.dependOn(&serve_cmd.step);

    // The WebAssembly frontend. The browser sandbox is a pure-computation
    // target with no syscalls — exactly the constraint the core already
    // meets — so we build a separate wasm-targeted copy of the core and a
    // thin shim that exports one call per turn. ReleaseSmall keeps the .wasm
    // lean; entry/rdynamic make it a "reactor" module (no main, exported
    // functions callable from JS).
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_core = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const wasm = b.addExecutable(.{
        .name = "zgigye",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "zgigye", .module = wasm_core },
            },
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    const wasm_step = b.step("wasm", "Build the WebAssembly module (zig-out/bin/zgigye.wasm)");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{}).step);

    // Stage the module, the play page, and a story together as static files,
    // so the browser demo needs no server of ours — any static file server
    // works:  zig build web && (cd zig-out/web && python3 -m http.server)
    const web_dir: std.Build.InstallDir = .{ .custom = "web" };
    const stage_wasm = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = web_dir } });
    const stage_page = b.addInstallFileWithDir(b.path("src/web/wasm.html"), web_dir, "index.html");
    const stage_story = b.addInstallFileWithDir(b.path("stories/minizork.z3"), web_dir, "minizork.z3");
    const web_step = b.step("web", "Stage the wasm browser demo under zig-out/web/");
    web_step.dependOn(&stage_wasm.step);
    web_step.dependOn(&stage_page.step);
    web_step.dependOn(&stage_story.step);

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
