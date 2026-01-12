//! Xcode Project Generator for labelle_ios
//!
//! Generates an Xcode project structure that wraps the Zig-compiled static library.
//! The generated project can be opened in Xcode for code signing and deployment.
//!
//! Usage: generate_xcode <app_name> <bundle_id> <target> [lib_path]
//!
//! The generator creates:
//! - MyApp.xcodeproj/project.pbxproj
//! - MyApp/main.m (entry point that calls labelle_ios_main)
//! - MyApp/compiler_rt_stubs.c (128-bit float stubs)
//! - MyApp/Assets.xcassets (placeholder)
//!
//! The project links against:
//! - lib{AppName}.a (Zig static library)
//! - libsokol_clib.a (Sokol C library)
//! - iOS frameworks (Foundation, UIKit, Metal, etc.)

const std = @import("std");
const fs = std.fs;
const mem = std.mem;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 4) {
        std.debug.print("Usage: generate_xcode <app_name> <bundle_id> <target> [lib_path]\n", .{});
        std.debug.print("  target: device, simulator\n", .{});
        std.debug.print("  lib_path: path to zig-out/lib (default: ../ios/zig-out/lib)\n", .{});
        return;
    }

    const app_name = args[1];
    const bundle_id = args[2];
    const target = args[3];
    const lib_path = if (args.len > 4) args[4] else "../ios/zig-out/lib";

    std.debug.print("Generating Xcode project for: {s}\n", .{app_name});
    std.debug.print("Bundle ID: {s}\n", .{bundle_id});
    std.debug.print("Target: {s}\n", .{target});
    std.debug.print("Library path: {s}\n", .{lib_path});

    // Create output directory structure
    const output_dir = "xcode";
    const xcodeproj_name = try std.fmt.allocPrint(allocator, "{s}.xcodeproj", .{app_name});
    defer allocator.free(xcodeproj_name);

    const xcodeproj_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, xcodeproj_name });
    defer allocator.free(xcodeproj_path);

    const app_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, app_name });
    defer allocator.free(app_dir);

    // Create directories
    try fs.cwd().makePath(xcodeproj_path);
    try fs.cwd().makePath(app_dir);

    // Generate source files
    try generateMainM(allocator, app_dir, app_name);
    try generateCompilerRtStubs(allocator, app_dir);

    // Generate project.pbxproj
    try generateProjectFile(allocator, xcodeproj_path, app_name, bundle_id, target, lib_path);

    // Create placeholder Assets.xcassets
    try createAssetCatalog(allocator, app_dir);

    // Generate scheme for xcodebuild compatibility
    try generateScheme(allocator, xcodeproj_path, app_name);

    std.debug.print("\nXcode project generated at: {s}\n", .{xcodeproj_path});
    std.debug.print("Open with: open {s}\n", .{xcodeproj_path});
}

fn generateMainM(allocator: mem.Allocator, app_dir: []const u8, app_name: []const u8) !void {
    const main_path = try std.fmt.allocPrint(allocator, "{s}/main.m", .{app_dir});
    defer allocator.free(main_path);

    var file = try fs.cwd().createFile(main_path, .{});
    defer file.close();

    const content = try std.fmt.allocPrint(allocator,
        \\// main.m - iOS Entry Point for {s}
        \\//
        \\// This minimal Objective-C file allows Xcode to compile source code,
        \\// which satisfies iOS code signing requirements.
        \\// The actual game logic is in the Zig static library.
        \\
        \\#import <Foundation/Foundation.h>
        \\
        \\// Declare the Zig entry point
        \\extern void labelle_ios_main(void);
        \\
        \\int main(int argc, char * argv[]) {{
        \\    @autoreleasepool {{
        \\        // Call into the Zig static library
        \\        // This sets up sokol_app which handles UIApplication lifecycle
        \\        labelle_ios_main();
        \\    }}
        \\    return 0;
        \\}}
        \\
    , .{app_name});
    defer allocator.free(content);

    try file.writeAll(content);
}

fn generateCompilerRtStubs(allocator: mem.Allocator, app_dir: []const u8) !void {
    const stubs_path = try std.fmt.allocPrint(allocator, "{s}/compiler_rt_stubs.c", .{app_dir});
    defer allocator.free(stubs_path);

    var file = try fs.cwd().createFile(stubs_path, .{});
    defer file.close();

    try file.writeAll(
        \\// Stubs for 128-bit float (quad precision) functions not available on iOS
        \\// These are needed because Zig may emit f128 operations
        \\// We approximate using long double (80-bit on x86, 64-bit on ARM)
        \\
        \\#include <math.h>
        \\#include <stdint.h>
        \\
        \\typedef long double fp128;
        \\
        \\// Division
        \\fp128 __divtf3(fp128 a, fp128 b) { return a / b; }
        \\
        \\// Comparison functions
        \\int __eqtf2(fp128 a, fp128 b) { return !(a == b); }
        \\int __netf2(fp128 a, fp128 b) { return a != b; }
        \\int __lttf2(fp128 a, fp128 b) { if (a < b) return -1; if (a == b) return 0; return 1; }
        \\int __gttf2(fp128 a, fp128 b) { if (a > b) return 1; if (a == b) return 0; return -1; }
        \\int __getf2(fp128 a, fp128 b) { if (a >= b) return 0; return -1; }
        \\int __letf2(fp128 a, fp128 b) { if (a <= b) return 0; return 1; }
        \\
        \\// Multiplication
        \\fp128 __multf3(fp128 a, fp128 b) { return a * b; }
        \\
        \\// Conversion functions
        \\fp128 __extendsftf2(float a) { return (fp128)a; }
        \\float __trunctfsf2(fp128 a) { return (float)a; }
        \\int __fixtfsi(fp128 a) { return (int)a; }
        \\unsigned int __fixunstfsi(fp128 a) { return (unsigned int)a; }
        \\fp128 __floatuntitf(uint64_t a) { return (fp128)a; }
        \\
        \\// Trunc function
        \\long double truncq(long double x) { return truncl(x); }
        \\
    );
}

fn generateProjectFile(
    allocator: mem.Allocator,
    xcodeproj_path: []const u8,
    app_name: []const u8,
    bundle_id: []const u8,
    target: []const u8,
    lib_path: []const u8,
) !void {
    const project_path = try std.fmt.allocPrint(allocator, "{s}/project.pbxproj", .{xcodeproj_path});
    defer allocator.free(project_path);

    var file = try fs.cwd().createFile(project_path, .{});
    defer file.close();

    // Determine SDK based on target
    const sdk_root = if (mem.eql(u8, target, "device")) "iphoneos" else "iphonesimulator";

    // Generate library name from app name
    const lib_name = try std.fmt.allocPrint(allocator, "lib{s}.a", .{app_name});
    defer allocator.free(lib_name);

    // Build the project file using ArrayList for dynamic content
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);
    const w = content.writer(allocator);

    // Use a helper for indentation (tabs work with regular strings, not multiline literals)
    const T1 = "\t";
    const T2 = "\t\t";
    const T3 = "\t\t\t";
    const T4 = "\t\t\t\t";
    const T5 = "\t\t\t\t\t";

    // Header
    try w.writeAll("// !$*UTF8*$!\n{\n");
    try w.print("{s}archiveVersion = 1;\n", .{T1});
    try w.print("{s}classes = {{\n{s}}};\n", .{ T1, T1 });
    try w.print("{s}objectVersion = 56;\n", .{T1});
    try w.print("{s}objects = {{\n\n", .{T1});

    // PBXBuildFile section
    try w.writeAll("/* Begin PBXBuildFile section */\n");
    try w.print("{s}A1000001 /* main.m in Sources */ = {{isa = PBXBuildFile; fileRef = A2000001 /* main.m */; }};\n", .{T2});
    try w.print("{s}A1000011 /* compiler_rt_stubs.c in Sources */ = {{isa = PBXBuildFile; fileRef = A2000012 /* compiler_rt_stubs.c */; }};\n", .{T2});
    try w.print("{s}A1000003 /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = A2000003 /* Assets.xcassets */; }};\n", .{T2});
    try w.print("{s}A1000006 /* {s} in Frameworks */ = {{isa = PBXBuildFile; fileRef = A2000007 /* {s} */; }};\n", .{ T2, lib_name, lib_name });
    try w.print("{s}A100000F /* libsokol_clib.a in Frameworks */ = {{isa = PBXBuildFile; fileRef = A2000010 /* libsokol_clib.a */; }};\n", .{T2});
    try w.print("{s}A1000007 /* Foundation.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = A2000008 /* Foundation.framework */; }};\n", .{T2});
    try w.print("{s}A1000008 /* UIKit.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = A2000009 /* UIKit.framework */; }};\n", .{T2});
    try w.print("{s}A1000009 /* Metal.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = A200000A /* Metal.framework */; }};\n", .{T2});
    try w.print("{s}A100000A /* MetalKit.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = A200000B /* MetalKit.framework */; }};\n", .{T2});
    try w.print("{s}A100000B /* AudioToolbox.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = A200000C /* AudioToolbox.framework */; }};\n", .{T2});
    try w.print("{s}A100000C /* AVFoundation.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = A200000D /* AVFoundation.framework */; }};\n", .{T2});
    try w.print("{s}A100000D /* QuartzCore.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = A200000E /* QuartzCore.framework */; }};\n", .{T2});
    try w.print("{s}A100000E /* CoreFoundation.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = A200000F /* CoreFoundation.framework */; }};\n", .{T2});
    try w.writeAll("/* End PBXBuildFile section */\n\n");

    // PBXFileReference section
    try w.writeAll("/* Begin PBXFileReference section */\n");
    try w.print("{s}A4000001 /* {s}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {s}.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n", .{ T2, app_name, app_name });
    try w.print("{s}A2000001 /* main.m */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = main.m; sourceTree = \"<group>\"; }};\n", .{T2});
    try w.print("{s}A2000012 /* compiler_rt_stubs.c */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = compiler_rt_stubs.c; sourceTree = \"<group>\"; }};\n", .{T2});
    try w.print("{s}A2000003 /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};\n", .{T2});
    try w.print("{s}A2000007 /* {s} */ = {{isa = PBXFileReference; lastKnownFileType = archive.ar; name = {s}; path = \"{s}/{s}\"; sourceTree = \"<group>\"; }};\n", .{ T2, lib_name, lib_name, lib_path, lib_name });
    try w.print("{s}A2000010 /* libsokol_clib.a */ = {{isa = PBXFileReference; lastKnownFileType = archive.ar; name = libsokol_clib.a; path = \"{s}/libsokol_clib.a\"; sourceTree = \"<group>\"; }};\n", .{ T2, lib_path });
    try w.print("{s}A2000008 /* Foundation.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = Foundation.framework; path = System/Library/Frameworks/Foundation.framework; sourceTree = SDKROOT; }};\n", .{T2});
    try w.print("{s}A2000009 /* UIKit.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = UIKit.framework; path = System/Library/Frameworks/UIKit.framework; sourceTree = SDKROOT; }};\n", .{T2});
    try w.print("{s}A200000A /* Metal.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = Metal.framework; path = System/Library/Frameworks/Metal.framework; sourceTree = SDKROOT; }};\n", .{T2});
    try w.print("{s}A200000B /* MetalKit.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = MetalKit.framework; path = System/Library/Frameworks/MetalKit.framework; sourceTree = SDKROOT; }};\n", .{T2});
    try w.print("{s}A200000C /* AudioToolbox.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = AudioToolbox.framework; path = System/Library/Frameworks/AudioToolbox.framework; sourceTree = SDKROOT; }};\n", .{T2});
    try w.print("{s}A200000D /* AVFoundation.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = AVFoundation.framework; path = System/Library/Frameworks/AVFoundation.framework; sourceTree = SDKROOT; }};\n", .{T2});
    try w.print("{s}A200000E /* QuartzCore.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = QuartzCore.framework; path = System/Library/Frameworks/QuartzCore.framework; sourceTree = SDKROOT; }};\n", .{T2});
    try w.print("{s}A200000F /* CoreFoundation.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = CoreFoundation.framework; path = System/Library/Frameworks/CoreFoundation.framework; sourceTree = SDKROOT; }};\n", .{T2});
    try w.writeAll("/* End PBXFileReference section */\n\n");

    // PBXFrameworksBuildPhase section
    try w.writeAll("/* Begin PBXFrameworksBuildPhase section */\n");
    try w.print("{s}A3000001 /* Frameworks */ = {{\n", .{T2});
    try w.print("{s}isa = PBXFrameworksBuildPhase;\n", .{T3});
    try w.print("{s}buildActionMask = 2147483647;\n", .{T3});
    try w.print("{s}files = (\n", .{T3});
    try w.print("{s}A1000006 /* {s} in Frameworks */,\n", .{ T4, lib_name });
    try w.print("{s}A100000F /* libsokol_clib.a in Frameworks */,\n", .{T4});
    try w.print("{s}A1000007 /* Foundation.framework in Frameworks */,\n", .{T4});
    try w.print("{s}A1000008 /* UIKit.framework in Frameworks */,\n", .{T4});
    try w.print("{s}A1000009 /* Metal.framework in Frameworks */,\n", .{T4});
    try w.print("{s}A100000A /* MetalKit.framework in Frameworks */,\n", .{T4});
    try w.print("{s}A100000B /* AudioToolbox.framework in Frameworks */,\n", .{T4});
    try w.print("{s}A100000C /* AVFoundation.framework in Frameworks */,\n", .{T4});
    try w.print("{s}A100000D /* QuartzCore.framework in Frameworks */,\n", .{T4});
    try w.print("{s}A100000E /* CoreFoundation.framework in Frameworks */,\n", .{T4});
    try w.print("{s});\n", .{T3});
    try w.print("{s}runOnlyForDeploymentPostprocessing = 0;\n", .{T3});
    try w.print("{s}}};\n", .{T2});
    try w.writeAll("/* End PBXFrameworksBuildPhase section */\n\n");

    // PBXGroup section
    try w.writeAll("/* Begin PBXGroup section */\n");
    // Main group
    try w.print("{s}A5000001 = {{\n", .{T2});
    try w.print("{s}isa = PBXGroup;\n", .{T3});
    try w.print("{s}children = (\n", .{T3});
    try w.print("{s}A5000002 /* {s} */,\n", .{ T4, app_name });
    try w.print("{s}A5000004 /* Frameworks */,\n", .{T4});
    try w.print("{s}A5000003 /* Products */,\n", .{T4});
    try w.print("{s});\n", .{T3});
    try w.print("{s}sourceTree = \"<group>\";\n", .{T3});
    try w.print("{s}}};\n", .{T2});
    // App group
    try w.print("{s}A5000002 /* {s} */ = {{\n", .{ T2, app_name });
    try w.print("{s}isa = PBXGroup;\n", .{T3});
    try w.print("{s}children = (\n", .{T3});
    try w.print("{s}A2000001 /* main.m */,\n", .{T4});
    try w.print("{s}A2000012 /* compiler_rt_stubs.c */,\n", .{T4});
    try w.print("{s}A2000003 /* Assets.xcassets */,\n", .{T4});
    try w.print("{s});\n", .{T3});
    try w.print("{s}path = {s};\n", .{ T3, app_name });
    try w.print("{s}sourceTree = \"<group>\";\n", .{T3});
    try w.print("{s}}};\n", .{T2});
    // Products group
    try w.print("{s}A5000003 /* Products */ = {{\n", .{T2});
    try w.print("{s}isa = PBXGroup;\n", .{T3});
    try w.print("{s}children = (\n", .{T3});
    try w.print("{s}A4000001 /* {s}.app */,\n", .{ T4, app_name });
    try w.print("{s});\n", .{T3});
    try w.print("{s}name = Products;\n", .{T3});
    try w.print("{s}sourceTree = \"<group>\";\n", .{T3});
    try w.print("{s}}};\n", .{T2});
    // Frameworks group
    try w.print("{s}A5000004 /* Frameworks */ = {{\n", .{T2});
    try w.print("{s}isa = PBXGroup;\n", .{T3});
    try w.print("{s}children = (\n", .{T3});
    try w.print("{s}A2000007 /* {s} */,\n", .{ T4, lib_name });
    try w.print("{s}A2000010 /* libsokol_clib.a */,\n", .{T4});
    try w.print("{s}A2000008 /* Foundation.framework */,\n", .{T4});
    try w.print("{s}A2000009 /* UIKit.framework */,\n", .{T4});
    try w.print("{s}A200000A /* Metal.framework */,\n", .{T4});
    try w.print("{s}A200000B /* MetalKit.framework */,\n", .{T4});
    try w.print("{s}A200000C /* AudioToolbox.framework */,\n", .{T4});
    try w.print("{s}A200000D /* AVFoundation.framework */,\n", .{T4});
    try w.print("{s}A200000E /* QuartzCore.framework */,\n", .{T4});
    try w.print("{s}A200000F /* CoreFoundation.framework */,\n", .{T4});
    try w.print("{s});\n", .{T3});
    try w.print("{s}name = Frameworks;\n", .{T3});
    try w.print("{s}sourceTree = \"<group>\";\n", .{T3});
    try w.print("{s}}};\n", .{T2});
    try w.writeAll("/* End PBXGroup section */\n\n");

    // PBXNativeTarget section
    try w.writeAll("/* Begin PBXNativeTarget section */\n");
    try w.print("{s}A6000001 /* {s} */ = {{\n", .{ T2, app_name });
    try w.print("{s}isa = PBXNativeTarget;\n", .{T3});
    try w.print("{s}buildConfigurationList = A7000003;\n", .{T3});
    try w.print("{s}buildPhases = (\n", .{T3});
    try w.print("{s}A3000002 /* Sources */,\n", .{T4});
    try w.print("{s}A3000001 /* Frameworks */,\n", .{T4});
    try w.print("{s}A3000003 /* Resources */,\n", .{T4});
    try w.print("{s});\n", .{T3});
    try w.print("{s}buildRules = (\n{s});\n", .{ T3, T3 });
    try w.print("{s}dependencies = (\n{s});\n", .{ T3, T3 });
    try w.print("{s}name = {s};\n", .{ T3, app_name });
    try w.print("{s}productName = {s};\n", .{ T3, app_name });
    try w.print("{s}productReference = A4000001 /* {s}.app */;\n", .{ T3, app_name });
    try w.print("{s}productType = \"com.apple.product-type.application\";\n", .{T3});
    try w.print("{s}}};\n", .{T2});
    try w.writeAll("/* End PBXNativeTarget section */\n\n");

    // PBXProject section
    try w.writeAll("/* Begin PBXProject section */\n");
    try w.print("{s}A8000001 /* Project object */ = {{\n", .{T2});
    try w.print("{s}isa = PBXProject;\n", .{T3});
    try w.print("{s}attributes = {{\n", .{T3});
    try w.print("{s}BuildIndependentTargetsInParallel = 1;\n", .{T4});
    try w.print("{s}LastUpgradeCheck = 1500;\n", .{T4});
    try w.print("{s}}};\n", .{T3});
    try w.print("{s}buildConfigurationList = A7000001;\n", .{T3});
    try w.print("{s}compatibilityVersion = \"Xcode 14.0\";\n", .{T3});
    try w.print("{s}developmentRegion = en;\n", .{T3});
    try w.print("{s}hasScannedForEncodings = 0;\n", .{T3});
    try w.print("{s}knownRegions = (\n{s}en,\n{s}Base,\n{s});\n", .{ T3, T4, T4, T3 });
    try w.print("{s}mainGroup = A5000001;\n", .{T3});
    try w.print("{s}productRefGroup = A5000003 /* Products */;\n", .{T3});
    try w.print("{s}projectDirPath = \"\";\n", .{T3});
    try w.print("{s}projectRoot = \"\";\n", .{T3});
    try w.print("{s}targets = (\n{s}A6000001 /* {s} */,\n{s});\n", .{ T3, T4, app_name, T3 });
    try w.print("{s}}};\n", .{T2});
    try w.writeAll("/* End PBXProject section */\n\n");

    // PBXResourcesBuildPhase section
    try w.writeAll("/* Begin PBXResourcesBuildPhase section */\n");
    try w.print("{s}A3000003 /* Resources */ = {{\n", .{T2});
    try w.print("{s}isa = PBXResourcesBuildPhase;\n", .{T3});
    try w.print("{s}buildActionMask = 2147483647;\n", .{T3});
    try w.print("{s}files = (\n{s}A1000003 /* Assets.xcassets in Resources */,\n{s});\n", .{ T3, T4, T3 });
    try w.print("{s}runOnlyForDeploymentPostprocessing = 0;\n", .{T3});
    try w.print("{s}}};\n", .{T2});
    try w.writeAll("/* End PBXResourcesBuildPhase section */\n\n");

    // PBXSourcesBuildPhase section
    try w.writeAll("/* Begin PBXSourcesBuildPhase section */\n");
    try w.print("{s}A3000002 /* Sources */ = {{\n", .{T2});
    try w.print("{s}isa = PBXSourcesBuildPhase;\n", .{T3});
    try w.print("{s}buildActionMask = 2147483647;\n", .{T3});
    try w.print("{s}files = (\n", .{T3});
    try w.print("{s}A1000001 /* main.m in Sources */,\n", .{T4});
    try w.print("{s}A1000011 /* compiler_rt_stubs.c in Sources */,\n", .{T4});
    try w.print("{s});\n", .{T3});
    try w.print("{s}runOnlyForDeploymentPostprocessing = 0;\n", .{T3});
    try w.print("{s}}};\n", .{T2});
    try w.writeAll("/* End PBXSourcesBuildPhase section */\n\n");

    // XCBuildConfiguration section
    try w.writeAll("/* Begin XCBuildConfiguration section */\n");
    // Project Debug config
    try w.print("{s}A7000002 /* Debug */ = {{\n", .{T2});
    try w.print("{s}isa = XCBuildConfiguration;\n", .{T3});
    try w.print("{s}buildSettings = {{\n", .{T3});
    try w.print("{s}ALWAYS_SEARCH_USER_PATHS = NO;\n", .{T4});
    try w.print("{s}CLANG_ENABLE_MODULES = YES;\n", .{T4});
    try w.print("{s}CLANG_ENABLE_OBJC_ARC = YES;\n", .{T4});
    try w.print("{s}GCC_C_LANGUAGE_STANDARD = gnu17;\n", .{T4});
    try w.print("{s}IPHONEOS_DEPLOYMENT_TARGET = 15.0;\n", .{T4});
    try w.print("{s}MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;\n", .{T4});
    try w.print("{s}MTL_FAST_MATH = YES;\n", .{T4});
    try w.print("{s}ONLY_ACTIVE_ARCH = YES;\n", .{T4});
    try w.print("{s}SDKROOT = {s};\n", .{ T4, sdk_root });
    try w.print("{s}}};\n", .{T3});
    try w.print("{s}name = Debug;\n", .{T3});
    try w.print("{s}}};\n", .{T2});
    // Project Release config
    try w.print("{s}A7000006 /* Release */ = {{\n", .{T2});
    try w.print("{s}isa = XCBuildConfiguration;\n", .{T3});
    try w.print("{s}buildSettings = {{\n", .{T3});
    try w.print("{s}ALWAYS_SEARCH_USER_PATHS = NO;\n", .{T4});
    try w.print("{s}CLANG_ENABLE_MODULES = YES;\n", .{T4});
    try w.print("{s}CLANG_ENABLE_OBJC_ARC = YES;\n", .{T4});
    try w.print("{s}GCC_C_LANGUAGE_STANDARD = gnu17;\n", .{T4});
    try w.print("{s}IPHONEOS_DEPLOYMENT_TARGET = 15.0;\n", .{T4});
    try w.print("{s}MTL_ENABLE_DEBUG_INFO = NO;\n", .{T4});
    try w.print("{s}MTL_FAST_MATH = YES;\n", .{T4});
    try w.print("{s}SDKROOT = {s};\n", .{ T4, sdk_root });
    try w.print("{s}VALIDATE_PRODUCT = YES;\n", .{T4});
    try w.print("{s}}};\n", .{T3});
    try w.print("{s}name = Release;\n", .{T3});
    try w.print("{s}}};\n", .{T2});
    // Target Debug config
    try w.print("{s}A7000004 /* Debug */ = {{\n", .{T2});
    try w.print("{s}isa = XCBuildConfiguration;\n", .{T3});
    try w.print("{s}buildSettings = {{\n", .{T3});
    try w.print("{s}ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;\n", .{T4});
    try w.print("{s}CODE_SIGN_STYLE = Automatic;\n", .{T4});
    try w.print("{s}CURRENT_PROJECT_VERSION = 1;\n", .{T4});
    try w.print("{s}GENERATE_INFOPLIST_FILE = YES;\n", .{T4});
    try w.print("{s}INFOPLIST_KEY_CFBundleDisplayName = {s};\n", .{ T4, app_name });
    try w.print("{s}INFOPLIST_KEY_LSRequiresIPhoneOS = YES;\n", .{T4});
    try w.print("{s}INFOPLIST_KEY_MinimumOSVersion = 15.0;\n", .{T4});
    try w.print("{s}INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;\n", .{T4});
    try w.print("{s}INFOPLIST_KEY_UIRequiredDeviceCapabilities = metal;\n", .{T4});
    try w.print("{s}INFOPLIST_KEY_UIRequiresFullScreen = YES;\n", .{T4});
    try w.print("{s}INFOPLIST_KEY_UIStatusBarHidden = YES;\n", .{T4});
    try w.print("{s}INFOPLIST_KEY_UISupportedInterfaceOrientations = \"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\";\n", .{T4});
    try w.print("{s}LD_RUNPATH_SEARCH_PATHS = (\n{s}\"$(inherited)\",\n{s}\"@executable_path/Frameworks\",\n{s});\n", .{ T4, T5, T5, T4 });
    try w.print("{s}LIBRARY_SEARCH_PATHS = \"$(PROJECT_DIR)/{s}\";\n", .{ T4, lib_path });
    try w.print("{s}MARKETING_VERSION = 1.0;\n", .{T4});
    try w.print("{s}OTHER_LDFLAGS = \"-lc++\";\n", .{T4});
    try w.print("{s}PRODUCT_BUNDLE_IDENTIFIER = \"{s}\";\n", .{ T4, bundle_id });
    try w.print("{s}PRODUCT_NAME = \"$(TARGET_NAME)\";\n", .{T4});
    try w.print("{s}TARGETED_DEVICE_FAMILY = \"1,2\";\n", .{T4});
    try w.print("{s}}};\n", .{T3});
    try w.print("{s}name = Debug;\n", .{T3});
    try w.print("{s}}};\n", .{T2});
    // Target Release config
    try w.print("{s}A7000005 /* Release */ = {{\n", .{T2});
    try w.print("{s}isa = XCBuildConfiguration;\n", .{T3});
    try w.print("{s}buildSettings = {{\n", .{T3});
    try w.print("{s}ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;\n", .{T4});
    try w.print("{s}CODE_SIGN_STYLE = Automatic;\n", .{T4});
    try w.print("{s}CURRENT_PROJECT_VERSION = 1;\n", .{T4});
    try w.print("{s}GENERATE_INFOPLIST_FILE = YES;\n", .{T4});
    try w.print("{s}INFOPLIST_KEY_CFBundleDisplayName = {s};\n", .{ T4, app_name });
    try w.print("{s}INFOPLIST_KEY_LSRequiresIPhoneOS = YES;\n", .{T4});
    try w.print("{s}INFOPLIST_KEY_MinimumOSVersion = 15.0;\n", .{T4});
    try w.print("{s}INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;\n", .{T4});
    try w.print("{s}INFOPLIST_KEY_UIRequiredDeviceCapabilities = metal;\n", .{T4});
    try w.print("{s}INFOPLIST_KEY_UIRequiresFullScreen = YES;\n", .{T4});
    try w.print("{s}INFOPLIST_KEY_UIStatusBarHidden = YES;\n", .{T4});
    try w.print("{s}INFOPLIST_KEY_UISupportedInterfaceOrientations = \"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\";\n", .{T4});
    try w.print("{s}LD_RUNPATH_SEARCH_PATHS = (\n{s}\"$(inherited)\",\n{s}\"@executable_path/Frameworks\",\n{s});\n", .{ T4, T5, T5, T4 });
    try w.print("{s}LIBRARY_SEARCH_PATHS = \"$(PROJECT_DIR)/{s}\";\n", .{ T4, lib_path });
    try w.print("{s}MARKETING_VERSION = 1.0;\n", .{T4});
    try w.print("{s}OTHER_LDFLAGS = \"-lc++\";\n", .{T4});
    try w.print("{s}PRODUCT_BUNDLE_IDENTIFIER = \"{s}\";\n", .{ T4, bundle_id });
    try w.print("{s}PRODUCT_NAME = \"$(TARGET_NAME)\";\n", .{T4});
    try w.print("{s}TARGETED_DEVICE_FAMILY = \"1,2\";\n", .{T4});
    try w.print("{s}}};\n", .{T3});
    try w.print("{s}name = Release;\n", .{T3});
    try w.print("{s}}};\n", .{T2});
    try w.writeAll("/* End XCBuildConfiguration section */\n\n");

    // XCConfigurationList section
    try w.writeAll("/* Begin XCConfigurationList section */\n");
    try w.print("{s}A7000001 /* Build configuration list for PBXProject \"{s}\" */ = {{\n", .{ T2, app_name });
    try w.print("{s}isa = XCConfigurationList;\n", .{T3});
    try w.print("{s}buildConfigurations = (\n{s}A7000002 /* Debug */,\n{s}A7000006 /* Release */,\n{s});\n", .{ T3, T4, T4, T3 });
    try w.print("{s}defaultConfigurationIsVisible = 0;\n", .{T3});
    try w.print("{s}defaultConfigurationName = Release;\n", .{T3});
    try w.print("{s}}};\n", .{T2});
    try w.print("{s}A7000003 /* Build configuration list for PBXNativeTarget \"{s}\" */ = {{\n", .{ T2, app_name });
    try w.print("{s}isa = XCConfigurationList;\n", .{T3});
    try w.print("{s}buildConfigurations = (\n{s}A7000004 /* Debug */,\n{s}A7000005 /* Release */,\n{s});\n", .{ T3, T4, T4, T3 });
    try w.print("{s}defaultConfigurationIsVisible = 0;\n", .{T3});
    try w.print("{s}defaultConfigurationName = Release;\n", .{T3});
    try w.print("{s}}};\n", .{T2});
    try w.writeAll("/* End XCConfigurationList section */\n\n");

    // Footer
    try w.print("{s}}};\n", .{T1});
    try w.print("{s}rootObject = A8000001 /* Project object */;\n}}\n", .{T1});

    try file.writeAll(content.items);
}

fn createAssetCatalog(allocator: mem.Allocator, app_dir: []const u8) !void {
    const assets_path = try std.fmt.allocPrint(allocator, "{s}/Assets.xcassets", .{app_dir});
    defer allocator.free(assets_path);

    try fs.cwd().makePath(assets_path);

    // Create Contents.json
    const contents_path = try std.fmt.allocPrint(allocator, "{s}/Contents.json", .{assets_path});
    defer allocator.free(contents_path);

    var file = try fs.cwd().createFile(contents_path, .{});
    defer file.close();

    try file.writeAll(
        \\{
        \\  "info" : {
        \\    "author" : "xcode",
        \\    "version" : 1
        \\  }
        \\}
        \\
    );

    // Create AppIcon.appiconset
    const appicon_path = try std.fmt.allocPrint(allocator, "{s}/AppIcon.appiconset", .{assets_path});
    defer allocator.free(appicon_path);

    try fs.cwd().makePath(appicon_path);

    const appicon_contents_path = try std.fmt.allocPrint(allocator, "{s}/Contents.json", .{appicon_path});
    defer allocator.free(appicon_contents_path);

    var appicon_file = try fs.cwd().createFile(appicon_contents_path, .{});
    defer appicon_file.close();

    try appicon_file.writeAll(
        \\{
        \\  "images" : [
        \\    {
        \\      "idiom" : "universal",
        \\      "platform" : "ios",
        \\      "size" : "1024x1024"
        \\    }
        \\  ],
        \\  "info" : {
        \\    "author" : "xcode",
        \\    "version" : 1
        \\  }
        \\}
        \\
    );
}

fn generateScheme(allocator: mem.Allocator, xcodeproj_path: []const u8, app_name: []const u8) !void {
    // Create scheme directory structure
    const schemes_dir = try std.fmt.allocPrint(allocator, "{s}/xcshareddata/xcschemes", .{xcodeproj_path});
    defer allocator.free(schemes_dir);
    try fs.cwd().makePath(schemes_dir);

    const scheme_path = try std.fmt.allocPrint(allocator, "{s}/{s}.xcscheme", .{ schemes_dir, app_name });
    defer allocator.free(scheme_path);

    var file = try fs.cwd().createFile(scheme_path, .{});
    defer file.close();

    const content = try std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Scheme
        \\   LastUpgradeVersion = "1500"
        \\   version = "1.3">
        \\   <BuildAction
        \\      parallelizeBuildables = "YES"
        \\      buildImplicitDependencies = "YES">
        \\      <BuildActionEntries>
        \\         <BuildActionEntry
        \\            buildForTesting = "YES"
        \\            buildForRunning = "YES"
        \\            buildForProfiling = "YES"
        \\            buildForArchiving = "YES"
        \\            buildForAnalyzing = "YES">
        \\            <BuildableReference
        \\               BuildableIdentifier = "primary"
        \\               BlueprintIdentifier = "A6000001"
        \\               BuildableName = "{s}.app"
        \\               BlueprintName = "{s}"
        \\               ReferencedContainer = "container:{s}.xcodeproj">
        \\            </BuildableReference>
        \\         </BuildActionEntry>
        \\      </BuildActionEntries>
        \\   </BuildAction>
        \\   <TestAction
        \\      buildConfiguration = "Debug"
        \\      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
        \\      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
        \\      shouldUseLaunchSchemeArgsEnv = "YES">
        \\   </TestAction>
        \\   <LaunchAction
        \\      buildConfiguration = "Debug"
        \\      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
        \\      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
        \\      launchStyle = "0"
        \\      useCustomWorkingDirectory = "NO"
        \\      ignoresPersistentStateOnLaunch = "NO"
        \\      debugDocumentVersioning = "YES"
        \\      debugServiceExtension = "internal"
        \\      allowLocationSimulation = "YES">
        \\      <BuildableProductRunnable
        \\         runnableDebuggingMode = "0">
        \\         <BuildableReference
        \\            BuildableIdentifier = "primary"
        \\            BlueprintIdentifier = "A6000001"
        \\            BuildableName = "{s}.app"
        \\            BlueprintName = "{s}"
        \\            ReferencedContainer = "container:{s}.xcodeproj">
        \\         </BuildableReference>
        \\      </BuildableProductRunnable>
        \\   </LaunchAction>
        \\   <ProfileAction
        \\      buildConfiguration = "Release"
        \\      shouldUseLaunchSchemeArgsEnv = "YES"
        \\      savedToolIdentifier = ""
        \\      useCustomWorkingDirectory = "NO"
        \\      debugDocumentVersioning = "YES">
        \\      <BuildableProductRunnable
        \\         runnableDebuggingMode = "0">
        \\         <BuildableReference
        \\            BuildableIdentifier = "primary"
        \\            BlueprintIdentifier = "A6000001"
        \\            BuildableName = "{s}.app"
        \\            BlueprintName = "{s}"
        \\            ReferencedContainer = "container:{s}.xcodeproj">
        \\         </BuildableReference>
        \\      </BuildableProductRunnable>
        \\   </ProfileAction>
        \\   <AnalyzeAction
        \\      buildConfiguration = "Debug">
        \\   </AnalyzeAction>
        \\   <ArchiveAction
        \\      buildConfiguration = "Release"
        \\      revealArchiveInOrganizer = "YES">
        \\   </ArchiveAction>
        \\</Scheme>
        \\
    , .{ app_name, app_name, app_name, app_name, app_name, app_name, app_name, app_name, app_name });
    defer allocator.free(content);

    try file.writeAll(content);
}
