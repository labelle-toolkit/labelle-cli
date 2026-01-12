//! labelle_ios - iOS packaging for labelle-engine games
//!
//! This build system provides:
//! - iOS device and simulator targets
//! - Xcode project generation
//! - Framework linking for iOS
//!
//! Usage:
//!   zig build                    # Build for host (testing on macOS)
//!   zig build run                # Run on host for testing
//!   zig build xcode              # Generate Xcode project only
//!   zig build ios-binary         # Build iOS binary only (needs sysroot)
//!   zig build ios                # Build iOS + generate Xcode project
//!   zig build ios-sim            # Build for iOS simulator + generate Xcode project
//!
//! For iOS cross-compilation, you need to specify the iOS SDK sysroot:
//!   zig build ios-binary --sysroot $(xcrun --show-sdk-path --sdk iphoneos)
//!
//! Requirements:
//!   - Xcode with iOS SDK installed (run `xcode-select --install` if needed)

const std = @import("std");

pub const IOSTarget = enum {
    device, // aarch64-ios (physical iPhone/iPad)
    simulator, // aarch64-ios-simulator (M1/M2 Mac simulator)
    simulator_x86, // x86_64-ios-simulator (Intel Mac simulator)
};

pub fn build(b: *std.Build) void {
    // Standard target/optimize for host builds (testing on macOS)
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // iOS-specific options
    const app_name = b.option([]const u8, "app_name", "Application name") orelse "LabelleGame";
    const bundle_id = b.option([]const u8, "bundle_id", "Bundle identifier") orelse "com.labelle.game";

    // ========================================
    // Host build for testing (macOS with sokol) - DEFAULT
    // ========================================
    const host_sokol_dep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });

    const host_exe = b.addExecutable(.{
        .name = "labelle_ios_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ios_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sokol", .module = host_sokol_dep.module("sokol") },
            },
        }),
    });

    host_exe.linkLibrary(host_sokol_dep.artifact("sokol_clib"));
    host_exe.linkLibC();

    b.installArtifact(host_exe);

    const run_cmd = b.addRunArtifact(host_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run on host (macOS) for testing");
    run_step.dependOn(&run_cmd.step);

    // ========================================
    // Xcode project generator (runs on host)
    // Uses b.graph.host explicitly so it's not affected by --sysroot
    // ========================================
    const gen_xcode_exe = b.addExecutable(.{
        .name = "generate_xcode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/generate_xcode.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    // Standalone Xcode generation step
    const gen_xcode_standalone = b.addRunArtifact(gen_xcode_exe);
    gen_xcode_standalone.addArg(app_name);
    gen_xcode_standalone.addArg(bundle_id);
    gen_xcode_standalone.addArg("device");
    const xcode_step = b.step("xcode", "Generate Xcode project only (no iOS build)");
    xcode_step.dependOn(&gen_xcode_standalone.step);

    // ========================================
    // iOS Device build
    // ========================================
    const ios_device_query: std.Target.Query = .{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
    };
    const ios_device_target = b.resolveTargetQuery(ios_device_query);

    // Detect iOS SDK path for framework search
    // See: https://github.com/ziglang/zig/issues/22704
    const ios_sdk_path = std.zig.system.darwin.getSdk(b.allocator, &ios_device_target.result);

    // Pass dont_link_system_libs=true to sokol and handle frameworks ourselves
    const ios_sokol_dep = b.dependency("sokol", .{
        .target = ios_device_target,
        .optimize = optimize,
        .dont_link_system_libs = true, // We'll link frameworks explicitly
    });

    const sokol_clib = ios_sokol_dep.artifact("sokol_clib");

    // Add iOS SDK paths to sokol_clib for C compilation (workaround for sysroot bug)
    // See: https://github.com/ziglang/zig/issues/22704
    if (ios_sdk_path) |sdk| {
        const fw_path = b.pathJoin(&.{ sdk, "System", "Library", "Frameworks" });
        const subfw_path = b.pathJoin(&.{ sdk, "System", "Library", "SubFrameworks" });
        const inc_path = b.pathJoin(&.{ sdk, "usr", "include" });
        const lib_path = b.pathJoin(&.{ sdk, "usr", "lib" });

        // Add paths to sokol_clib so it can find iOS headers during compilation
        sokol_clib.root_module.addSystemIncludePath(.{ .cwd_relative = inc_path });
        sokol_clib.root_module.addSystemFrameworkPath(.{ .cwd_relative = fw_path });
        sokol_clib.root_module.addSystemFrameworkPath(.{ .cwd_relative = subfw_path });
        sokol_clib.root_module.addLibraryPath(.{ .cwd_relative = lib_path });
    }

    const ios_exe = b.addExecutable(.{
        .name = app_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ios_main.zig"),
            .target = ios_device_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sokol", .module = ios_sokol_dep.module("sokol") },
            },
        }),
    });

    ios_exe.linkLibrary(sokol_clib);
    ios_exe.linkLibC();

    // Add iOS framework paths explicitly (workaround for sysroot bug)
    if (ios_sdk_path) |sdk| {
        const fw_path = b.pathJoin(&.{ sdk, "System", "Library", "Frameworks" });
        const subfw_path = b.pathJoin(&.{ sdk, "System", "Library", "SubFrameworks" });
        ios_exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = fw_path });
        ios_exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = subfw_path });
        ios_exe.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr", "include" }) });
        ios_exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr", "lib" }) });
    }

    // Link iOS frameworks explicitly
    ios_exe.root_module.linkFramework("Foundation", .{});
    ios_exe.root_module.linkFramework("UIKit", .{});
    ios_exe.root_module.linkFramework("Metal", .{});
    ios_exe.root_module.linkFramework("MetalKit", .{});
    ios_exe.root_module.linkFramework("AudioToolbox", .{});
    ios_exe.root_module.linkFramework("AVFoundation", .{});

    // Install iOS binary
    b.installArtifact(ios_exe);

    // Step to build iOS binary only (requires sysroot)
    const ios_binary_step = b.step("ios-binary", "Build iOS binary only (requires --sysroot)");
    ios_binary_step.dependOn(&ios_exe.step);

    // Xcode generator for device
    const gen_xcode_device = b.addRunArtifact(gen_xcode_exe);
    gen_xcode_device.addArg(app_name);
    gen_xcode_device.addArg(bundle_id);
    gen_xcode_device.addArg("device");

    const ios_step = b.step("ios", "Build for iOS device and generate Xcode project");
    ios_step.dependOn(&ios_exe.step);
    ios_step.dependOn(&gen_xcode_device.step);

    // ========================================
    // iOS Simulator build
    // ========================================
    const ios_sim_query: std.Target.Query = .{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
        .abi = .simulator,
    };
    const ios_sim_target = b.resolveTargetQuery(ios_sim_query);

    // Detect iOS Simulator SDK path
    const ios_sim_sdk_path = std.zig.system.darwin.getSdk(b.allocator, &ios_sim_target.result);

    const ios_sim_sokol_dep = b.dependency("sokol", .{
        .target = ios_sim_target,
        .optimize = optimize,
        .dont_link_system_libs = true,
    });

    const sim_sokol_clib = ios_sim_sokol_dep.artifact("sokol_clib");

    // Add iOS Simulator SDK paths
    if (ios_sim_sdk_path) |sdk| {
        const fw_path = b.pathJoin(&.{ sdk, "System", "Library", "Frameworks" });
        const subfw_path = b.pathJoin(&.{ sdk, "System", "Library", "SubFrameworks" });
        const inc_path = b.pathJoin(&.{ sdk, "usr", "include" });
        const lib_path = b.pathJoin(&.{ sdk, "usr", "lib" });

        sim_sokol_clib.root_module.addSystemIncludePath(.{ .cwd_relative = inc_path });
        sim_sokol_clib.root_module.addSystemFrameworkPath(.{ .cwd_relative = fw_path });
        sim_sokol_clib.root_module.addSystemFrameworkPath(.{ .cwd_relative = subfw_path });
        sim_sokol_clib.root_module.addLibraryPath(.{ .cwd_relative = lib_path });
    }

    const ios_sim_exe = b.addExecutable(.{
        .name = "LabelleGame_sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ios_main.zig"),
            .target = ios_sim_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sokol", .module = ios_sim_sokol_dep.module("sokol") },
            },
        }),
    });

    ios_sim_exe.linkLibrary(sim_sokol_clib);
    ios_sim_exe.linkLibC();

    // Add simulator framework paths
    if (ios_sim_sdk_path) |sdk| {
        const fw_path = b.pathJoin(&.{ sdk, "System", "Library", "Frameworks" });
        const subfw_path = b.pathJoin(&.{ sdk, "System", "Library", "SubFrameworks" });
        ios_sim_exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = fw_path });
        ios_sim_exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = subfw_path });
        ios_sim_exe.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr", "include" }) });
        ios_sim_exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr", "lib" }) });
    }

    // Link simulator frameworks
    ios_sim_exe.root_module.linkFramework("Foundation", .{});
    ios_sim_exe.root_module.linkFramework("UIKit", .{});
    ios_sim_exe.root_module.linkFramework("Metal", .{});
    ios_sim_exe.root_module.linkFramework("MetalKit", .{});
    ios_sim_exe.root_module.linkFramework("AudioToolbox", .{});
    ios_sim_exe.root_module.linkFramework("AVFoundation", .{});

    // Xcode generator for simulator
    const gen_xcode_sim = b.addRunArtifact(gen_xcode_exe);
    gen_xcode_sim.addArg(app_name);
    gen_xcode_sim.addArg(bundle_id);
    gen_xcode_sim.addArg("simulator");

    const ios_sim_step = b.step("ios-sim", "Build for iOS simulator and generate Xcode project");
    ios_sim_step.dependOn(&ios_sim_exe.step);
    ios_sim_step.dependOn(&gen_xcode_sim.step);
}
