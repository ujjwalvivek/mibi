//! Build script for mibi. Pinned to Zig 0.16.0 (see build.zig.zon).
//!
//!   zig build                                  -> zig-out/bin/mibi (native)
//!   zig build run                              -> build and start it
//!   zig build -Doptimize=ReleaseSmall          -> smallest (default)
//!   zig build -Dtarget=x86_64-linux-gnu        -> cross-compile
//!   zig build -Dtarget=aarch64-macos
//!   zig build -Dtarget=x86_64-windows-gnu
//!   zig build web                              -> zig-out/web (wasm + page)
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

    // The layers are modules, so the direction of the imports is checked by
    // the compiler: a file cannot import a path outside its own module, only
    // the modules listed for it here.
    //
    //   core      the text model               imports nothing
    //   ui        widgets, events, cells       imports core
    //   platform  OS and terminal              imports ui (for the event types)
    //   mibi      the application (src/*.zig)  imports all three
    const libc = target.result.os.tag != .windows;
    const layers = Layers.create(b, target, optimize, "src/platform/platform.zig", libc);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
        // No unwind tables: we have our own panic and never unwind.
        .unwind_tables = .none,
        // Unix goes through libc for termios and syscalls; Windows uses the
        // kernel32 declarations in src/platform and needs no libc.
        .link_libc = libc,
    });
    layers.addTo(exe_mod);
    const exe = b.addExecutable(.{
        .name = "mibi",
        .root_module = exe_mod,
    });
    // Windows builds carry the app icon (assets/mibi.ico) as a resource, and
    // use a message box when started without a terminal.
    if (target.result.os.tag == .windows) {
        exe_mod.addWin32ResourceFile(.{ .file = b.path("assets/mibi.rc") });
    }
    b.installArtifact(exe);

    // Packaging assets: icons under share/mibi/icons, the Windows Terminal
    // profile under share/mibi/windows-terminal.
    b.installDirectory(.{
        .source_dir = b.path("assets/png"),
        .install_dir = .prefix,
        .install_subdir = "share/mibi/icons/png",
    });
    b.installFile("assets/mibi.ico", "share/mibi/icons/mibi.ico");
    b.installFile("assets/mibi.svg", "share/mibi/icons/mibi.svg");
    b.installFile("LICENSE", "share/mibi/LICENSE");
    b.installDirectory(.{
        .source_dir = b.path("assets/windows-terminal"),
        .install_dir = .prefix,
        .install_subdir = "share/mibi/windows-terminal",
    });

    // Language definitions travel with the binary: `syntax.d` is looked up next
    // to the executable (or in the working directory when running from source).
    b.installDirectory(.{
        .source_dir = b.path("syntax.d"),
        .install_dir = .bin,
        .install_subdir = "syntax.d",
    });

    // Colour themes are data files too (themes/<name>.ini).
    b.installDirectory(.{
        .source_dir = b.path("themes"),
        .install_dir = .bin,
        .install_subdir = "themes",
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run mibi");
    run_step.dependOn(&run_cmd.step);

    // --- web -----------------------------------------------------------------
    // The same layers compiled to wasm32-freestanding, with the platform
    // module swapped for src/platform/web.zig (an in-memory filesystem and
    // three host calls) and src/web_main.zig as the entry: exports the page
    // calls, instead of a loop. `zig build web` installs a static site.
    const web_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const web_layers = Layers.create(b, web_target, optimize, "src/platform/web.zig", false);
    const web_mod = b.createModule(.{
        .root_source_file = b.path("src/web_main.zig"),
        .target = web_target,
        .optimize = optimize,
        .single_threaded = true,
        .strip = true,
        .unwind_tables = .none,
    });
    web_layers.addTo(web_mod);
    const web_exe = b.addExecutable(.{ .name = "mibi", .root_module = web_mod });
    web_exe.entry = .disabled; // no _start: the page calls the exports
    web_exe.rdynamic = true;

    // web/site is the page as it is served; the data files come from the
    // same directories the native build ships.
    const web_step = b.step("web", "Build the WebAssembly editor and its page into zig-out/web");
    const web_installs = [_]*std.Build.Step{
        &b.addInstallFile(web_exe.getEmittedBin(), "web/mibi.wasm").step,
        &b.addInstallDirectory(.{
            .source_dir = b.path("web/site"),
            .install_dir = .prefix,
            .install_subdir = "web",
        }).step,
        &b.addInstallDirectory(.{ .source_dir = b.path("syntax.d"), .install_dir = .prefix, .install_subdir = "web/syntax.d" }).step,
        &b.addInstallDirectory(.{ .source_dir = b.path("themes"), .install_dir = .prefix, .install_subdir = "web/themes" }).step,
        &b.addInstallFile(b.path("config/mibi.ini.example"), "web/mibi.ini.example").step,
        &b.addInstallFile(b.path("LICENSE"), "web/LICENSE").step,
    };
    for (web_installs) |step| web_step.dependOn(step);

    // `zig build test` runs the unit tests in the same sources. Tests build
    // in Debug unless told otherwise: the release mode turns off the bounds,
    // overflow and aliasing checks that tests exist to trip.
    const test_optimize = b.option(
        std.builtin.OptimizeMode,
        "test-optimize",
        "Optimize mode for the tests (default Debug)",
    ) orelse .Debug;
    const test_step = b.step("test", "Run every layer's tests");
    const test_layers = Layers.create(b, target, test_optimize, "src/platform/platform.zig", libc);
    const app_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = test_optimize,
        .link_libc = libc,
    });
    test_layers.addTo(app_test_mod);
    // A module's tests are only the ones in its own files, so each layer is
    // a test binary: `zig build test-core` runs the text model alone.
    const suites = [_]struct { name: []const u8, about: []const u8, module: *std.Build.Module }{
        .{ .name = "test-core", .about = "Run the text model's tests", .module = test_layers.core },
        .{ .name = "test-ui", .about = "Run the widgets' tests", .module = test_layers.ui },
        .{ .name = "test-platform", .about = "Run the OS and terminal layer's tests", .module = test_layers.platform },
        .{ .name = "test-app", .about = "Run the application's tests", .module = app_test_mod },
        // The web platform's filesystem has no host calls, so it is tested
        // natively; the rest of the web build is tested from web/test.
        .{ .name = "test-web", .about = "Run the web platform's filesystem tests", .module = b.createModule(.{
            .root_source_file = b.path("src/platform/web/vfs.zig"),
            .target = target,
            .optimize = test_optimize,
        }) },
    };
    for (suites) |suite| {
        const run = b.addRunArtifact(b.addTest(.{ .root_module = suite.module }));
        const step = b.step(suite.name, suite.about);
        step.dependOn(&run.step);
        test_step.dependOn(step);
    }
}

const Layers = struct {
    core: *std.Build.Module,
    ui: *std.Build.Module,
    platform: *std.Build.Module,

    fn create(
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        platform_root: []const u8,
        libc: bool,
    ) Layers {
        // wasm has no threads; saying so drops the atomics and locks.
        const single_threaded: ?bool = if (target.result.cpu.arch.isWasm()) true else null;
        const core = b.createModule(.{
            .root_source_file = b.path("src/core/core.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = single_threaded,
        });
        const ui = b.createModule(.{
            .root_source_file = b.path("src/ui/ui.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = single_threaded,
        });
        ui.addImport("core", core);
        const platform = b.createModule(.{
            .root_source_file = b.path(platform_root),
            .target = target,
            .optimize = optimize,
            .single_threaded = single_threaded,
            .link_libc = libc,
        });
        platform.addImport("ui", ui);
        // The message box shown when mibi is started without a terminal.
        if (target.result.os.tag == .windows) platform.linkSystemLibrary("user32", .{});
        return .{ .core = core, .ui = ui, .platform = platform };
    }

    fn addTo(self: Layers, module: *std.Build.Module) void {
        module.addImport("core", self.core);
        module.addImport("ui", self.ui);
        module.addImport("platform", self.platform);
    }
};
