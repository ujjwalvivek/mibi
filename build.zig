//! Build script for mibi. Pinned to Zig 0.16.0 (see build.zig.zon).
//!
//!   zig build                                  -> zig-out/bin/mibi (native)
//!   zig build run                              -> build and start it
//!   zig build -Doptimize=ReleaseSmall          -> smallest (default)
//!   zig build -Dtarget=x86_64-linux-gnu        -> cross-compile
//!   zig build -Dtarget=aarch64-macos
//!   zig build -Dtarget=x86_64-windows-gnu
//!
//! mibi has no third-party dependencies; only Zig's std. The toolchain itself
//! is vendored in tools/zig by tools/get-zig.ps1, so nothing is installed
//! globally.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseSmall by default: this project is measured in bytes.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Debug, ReleaseSafe, ReleaseFast, ReleaseSmall (default)",
    ) orelse .ReleaseSmall;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
        // No unwind tables: we have our own panic and never unwind.
        .unwind_tables = .none,
        // Unix goes through libc for termios and syscalls; Windows uses the
        // kernel32 declarations in src/os.zig and needs no libc.
        .link_libc = target.result.os.tag != .windows,
    });
    const exe = b.addExecutable(.{
        .name = "mibi",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Language definitions travel with the binary: `syntax.d` is looked up next
    // to the executable (or in the working directory when running from source).
    b.installDirectory(.{
        .source_dir = b.path("syntax.d"),
        .install_dir = .bin,
        .install_subdir = "syntax.d",
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run mibi");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` runs the unit tests in the same sources.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
