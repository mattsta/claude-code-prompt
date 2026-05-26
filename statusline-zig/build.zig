const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "statusline",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the binary");
    const run = b.addRunArtifact(exe);
    run_step.dependOn(&run.step);

    const test_step = b.step("test", "Run unit tests");
    inline for (.{ "main", "fmt", "ansi", "input" }) |name| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const r = b.addRunArtifact(t);
        test_step.dependOn(&r.step);
    }

    // `zig build parity`: run tests/parity.sh against the just-built binary.
    // Forces a Release build so we benchmark/validate what would actually ship.
    const parity_exe = b.addExecutable(.{
        .name = "statusline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const parity_install = b.addInstallArtifact(parity_exe, .{});
    const parity_run = b.addSystemCommand(&.{ "bash", "tests/parity.sh" });
    parity_run.addFileArg(parity_exe.getEmittedBin());
    parity_run.step.dependOn(&parity_install.step);
    parity_run.has_side_effects = true;
    const parity_step = b.step("parity", "Diff zig output vs python reference on every fixture");
    parity_step.dependOn(&parity_run.step);

    // `zig build check` runs unit tests AND parity diff — the one-command gate.
    const check_step = b.step("check", "Run unit tests and parity diff");
    check_step.dependOn(test_step);
    check_step.dependOn(parity_step);
}
