# RFC: iOS Platform Support

## Problem Statement

labelle-cli v1.x recognizes `--platform=ios` and generates callback-based Zig code via sokol's `mobile.txt` template, but the platform is non-functional. A developer who runs `labelle build --platform=ios` gets a binary that **cannot run on iOS** because:

1. **No target resolution** — the generated `build.zig` uses `b.standardTargetOptions()`, which defaults to the host machine. There is no `aarch64-ios` or `aarch64-ios-simulator` target override, unlike WASM which explicitly resolves `wasm32-emscripten`.

2. **No `.app` bundle** — iOS requires a specific directory layout (binary + `Info.plist` + resources inside a `.app` folder). The generated output is a bare executable with no packaging.

3. **No `Info.plist`** — every iOS app needs metadata: bundle identifier, display name, minimum OS version, device family, launch screen declaration. None of this is generated.

4. **No deployment tooling** — `labelle run --platform=wasm` serves the build and opens a browser. `labelle run --platform=ios` falls through to the desktop runner and tries to execute a native binary, which fails silently or crashes.

5. **No iOS SDK path configuration** — Zig's cross-compilation for iOS requires explicit SDK framework and include paths because `getSdk()` returns null for cross-compilation targets (Zig bug #22704). sokol's C library (`sokol_clib`) needs these paths to compile Metal/UIKit headers.

6. **No iOS framework linking** — iOS apps must link against system frameworks (Metal, MetalKit, UIKit, AudioToolbox, AVFoundation, Foundation, QuartzCore) and `libobjc`. None of this is in the generated build.

### Prior Art: labelle-cli v0.4.5

iOS was fully functional in CLI v0.4.5 (with engine v0.51.0+). That implementation is the primary reference for this RFC. The v0.4.5 architecture was fundamentally different — the **engine** was the code generator, and the CLI was a thin bootstrap that added iOS packaging on top. In v1.x, the CLI **is** the generator, so the iOS support must be re-integrated into the new architecture.

Key files from v0.4.5:

| v0.4.5 File | Purpose |
|-------------|---------|
| `src/ios/ios_commands.zig` (1571 lines) | CLI commands: `labelle ios build`, `ios xcode`, `ios run` |
| `src/ios/build_ios.zig` | Reference `build.zig` for iOS with device/simulator/simulator_x86 targets |
| `src/ios/generate_xcode.zig` | Full `.xcodeproj/project.pbxproj` generator |
| `src/ios/templates/ios_main.zig` (369 lines) | Standalone iOS main with touch input, sokol callbacks |
| `src/ios/templates/Info.plist.template` | Templated plist with `{{BUNDLE_ID}}`, `{{APP_NAME}}`, orientation |
| `src/ios/templates/LaunchScreen.storyboard` | Standard launch screen XIB |

Engine v0.51.0+ files:

| Engine File | Purpose |
|-------------|---------|
| `tools/templates/main_sokol_ios.txt` | Separate iOS main template (sokol callbacks) |
| `tools/templates/build_zig.txt` sections: `sokol_ios_exe_start/end`, `ios_frameworks` | iOS-specific build.zig sections |
| `tools/generator.zig` | iOS branch: uses iOS template when `target == .ios` |
| `build.zig` | iOS SDK framework paths, `dont_link_system_libs` for sokol, zflecs iOS workarounds |

### Scope

Only the **sokol** backend supports iOS. sokol-zig handles Metal rendering, UIKit app lifecycle, and touch input internally. This RFC does not propose iOS support for raylib, sdl, bgfx, or wgpu backends.

## Proven Technical Requirements (from v0.4.5)

The following requirements were validated in the v0.4.5 implementation and must be preserved in v1.x.

### 1. sokol must be built with `dont_link_system_libs = true`

On iOS and WASM, sokol's automatic system library linking doesn't work. The generated build must pass this flag and handle linking manually:

```zig
const sokol_dep = b.dependency("sokol", .{
    .target = target,
    .optimize = optimize,
    .dont_link_system_libs = true,  // iOS: we link frameworks manually
});
```

### 2. Explicit iOS SDK paths for C compilation

Zig's `getSdk()` returns null for cross-compilation targets. sokol_clib needs explicit paths to compile Metal/UIKit headers. The v0.4.5 solution detects SDK paths dynamically via `xcrun`:

```zig
fn getIosSdkPath(b: *std.Build, sdk_name: []const u8) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "xcrun", "--sdk", sdk_name, "--show-sdk-path" },
    }) catch return null;
    // ... trim and return
}
```

The SDK paths are applied to both `sokol_clib` (for compiling) and the final executable (for linking):

```zig
// sokol_clib needs framework + include paths for compilation
fn configureSdkPaths(b: *std.Build, artifact: *std.Build.Step.Compile, sdk_path: []const u8) void {
    artifact.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr/include" }) });
    artifact.root_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "System/Library/Frameworks" }) });
    artifact.root_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "System/Library/SubFrameworks" }) });
}

// Executable needs library + framework paths for linking
fn addExeSdkPaths(b: *std.Build, exe: *std.Build.Step.Compile, sdk_path: []const u8) void {
    exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr/lib" }) });
    exe.root_module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "System/Library/Frameworks" }) });
}
```

Device and simulator use **different SDKs**:
- Device: `xcrun --sdk iphoneos --show-sdk-path`
- Simulator: `xcrun --sdk iphonesimulator --show-sdk-path`

### 3. iOS framework linking

The following frameworks must be linked on the final executable:

```zig
exe.root_module.linkFramework("Foundation", .{});
exe.root_module.linkFramework("UIKit", .{});
exe.root_module.linkFramework("Metal", .{});
exe.root_module.linkFramework("MetalKit", .{});
exe.root_module.linkFramework("AudioToolbox", .{});
exe.root_module.linkFramework("AVFoundation", .{});
```

Plus `exe.linkLibC()` and implicitly `libobjc` (via sokol's Objective-C code).

### 4. Three distinct iOS targets

```zig
// Device (physical iPhone/iPad)
const device_target = b.resolveTargetQuery(.{
    .cpu_arch = .aarch64,
    .os_tag = .ios,
});

// Simulator on Apple Silicon
const sim_target = b.resolveTargetQuery(.{
    .cpu_arch = .aarch64,
    .os_tag = .ios,
    .abi = .simulator,
    .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_a14 },
});

// Simulator on Intel Mac
const sim_x86_target = b.resolveTargetQuery(.{
    .cpu_arch = .x86_64,
    .os_tag = .ios,
    .abi = .simulator,
});
```

The `apple_a14` CPU model is required for the simulator on Apple Silicon — it enables NEON SIMD features that libraries like box2d (physics) require. Without it, SIMD intrinsics fail at compile time.

### 5. Sokol module access through engine re-export

iOS apps access sokol through `engine.sokol`, not as a direct import. This avoids Zig module conflicts when both the engine and the app import sokol (the dependency graph would create two different sokol module instances):

```zig
// In generated main.zig — CORRECT for iOS
const sokol = engine.sokol;
const sapp = sokol.app;

// NOT this — would cause module conflict
// const sokol = @import("sokol");
```

The build.zig reflects this — the iOS executable module only imports `labelle-engine`, not sokol directly. Sokol is only referenced as an artifact for linking `sokol_clib`.

### 6. Simulator deployment via `xcrun simctl`

The v0.4.5 deployment flow (proven working):

1. Build binary with `zig build ios-sim`
2. Create `.app` bundle directory
3. Copy binary into `.app/`
4. Generate minimal `Info.plist` into `.app/`
5. `chmod +x` the binary
6. Auto-detect or boot a simulator via `xcrun simctl list devices booted -j`
7. If no simulator booted, find an iPhone in `xcrun simctl list devices available`, boot it
8. `xcrun simctl install booted GameName.app`
9. `xcrun simctl launch booted com.bundle.id` — returns PID

### 7. Xcode project generation for device deployment

The v0.4.5 `generatePbxproj()` function produces a complete `project.pbxproj` with:
- PBXBuildFile, PBXCopyFilesBuildPhase, PBXFileReference, PBXGroup sections
- PBXNativeTarget referencing the pre-built Zig binary
- PBXResourcesBuildPhase for LaunchScreen.storyboard and Assets.xcassets
- XCBuildConfiguration with `CODE_SIGN_STYLE = Automatic`, `PRODUCT_BUNDLE_IDENTIFIER`, `TARGETED_DEVICE_FAMILY`, `IPHONEOS_DEPLOYMENT_TARGET`
- Debug and Release configurations
- Proper `objectVersion = 56` (Xcode 14.0 compatibility)

The generated directory structure:

```
ios-xcode/
├── GameName.xcodeproj/
│   └── project.pbxproj
└── GameName/
    ├── GameName           (pre-built Zig binary)
    ├── Info.plist
    ├── LaunchScreen.storyboard
    ├── Assets.xcassets/
    │   ├── Contents.json
    │   └── AppIcon.appiconset/
    │       └── Contents.json
    ├── resources/         (copied from project)
    └── project.labelle    (copied for reference)
```

## Proposal: Three-Phase iOS Support for v1.x

### Configuration

iOS settings move into `project.labelle` (v0.4.5 used a separate `ios.labelle` file — consolidating reduces file sprawl):

```zon
// project.labelle
.{
    .name = "my_game",
    .title = "My Game",
    .backend = .sokol,
    .ios = .{
        .app_name = "My Game",
        .bundle_id = "com.studio.mygame",
        .minimum_ios = "15.0",
        .orientation = .landscape,   // .portrait, .landscape, .all
        .device_family = "1,2",      // 1=iPhone, 2=iPad
    },
}
```

When `.ios` is omitted, derive defaults from the project:
- `app_name` = `cfg.title` or `cfg.name`
- `bundle_id` = `"com.labelle.{sanitized_name}"`
- `minimum_ios` = `"15.0"` (covers ~98% of active devices)
- `orientation` = `.all`
- `device_family` = `"1,2"` (Universal)

```zig
pub const IosConfig = struct {
    app_name: []const u8 = "",
    bundle_id: []const u8 = "",
    team_id: []const u8 = "",               // for code signing (Phase 3)
    minimum_ios: []const u8 = "15.0",
    orientation: Orientation = .all,
    device_family: []const u8 = "1,2",

    pub const Orientation = enum { portrait, landscape, all };
};
```

---

## Phase 1: Cross-Compilation + Simulator (MVP)

**Goal**: `labelle run --platform=ios` cross-compiles the game, packages a `.app` bundle, and launches it in the iOS Simulator.

### 1.1 — Generated `build.zig` for iOS

New template sections in `build_zig.txt`. Unlike the minimal WASM target override, iOS needs significant build infrastructure (SDK detection, framework linking, dual device/simulator targets). Based on the proven v0.4.5 `generateIosBuildZig()`:

```
.header_ios
const std = @import("std");

/// Get iOS SDK path using xcrun
fn getIosSdkPath(b: *std.Build, sdk_name: []const u8) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "xcrun", "--sdk", sdk_name, "--show-sdk-path" },
    }) catch return null;
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    if (result.term == .Exited and result.term.Exited == 0) {
        const path = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
        if (path.len == 0) return null;
        return b.allocator.dupe(u8, path) catch null;
    }
    return null;
}

fn configureSdkPaths(b: *std.Build, artifact: *std.Build.Step.Compile, sdk_path: []const u8) void {
    artifact.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr/include" }) });
    artifact.root_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "System/Library/Frameworks" }) });
    artifact.root_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "System/Library/SubFrameworks" }) });
}

fn addExeSdkPaths(b: *std.Build, exe: *std.Build.Step.Compile, sdk_path: []const u8) void {
    exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr/lib" }) });
    exe.root_module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "System/Library/Frameworks" }) });
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

.ios_sdk_detect
    const device_sdk = getIosSdkPath(b, "iphoneos") orelse
        @panic("Could not find iOS device SDK. Is Xcode installed?");
    const sim_sdk = getIosSdkPath(b, "iphonesimulator") orelse
        @panic("Could not find iOS simulator SDK. Is Xcode installed?");

.ios_targets
    const ios_device_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
    });
    const ios_sim_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
        .abi = .simulator,
        .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_a14 },
    });
```

Then for each target (device and simulator), emit sections for:
- sokol dependency with `dont_link_system_libs = true`
- SDK path configuration on `sokol_clib`
- Core/gfx/engine dependencies
- Executable module (imports engine only, not sokol directly)
- Framework linking (Metal, MetalKit, UIKit, AudioToolbox, AVFoundation, Foundation)
- Build step (`ios` for device, `ios-sim` for simulator)

### 1.2 — iOS branch in `build_files.zig`

Modify `generateBuildZig()` — change from two-way to three-way:

```zig
if (cfg.platform == .wasm) {
    // ... existing WASM path
} else if (cfg.platform == .ios) {
    try tpl.writeSection(build_zig_tmpl, "header_ios", w);
    try tpl.writeSection(build_zig_tmpl, "ios_sdk_detect", w);
    try tpl.writeSection(build_zig_tmpl, "ios_targets", w);
    try tpl.writeSection(build_zig_tmpl, "deps", w);

    // Backend: sokol with dont_link_system_libs=true
    try tpl.writeSection(build_zig_tmpl, "backend_sokol_ios", w);

    // ECS, GUI, plugin wiring (shared with desktop)
    // ...

    // Device build: exe + framework linking + install step
    try tpl.writeSection(build_zig_tmpl, "ios_device_exe", w);
    try tpl.writeSection(build_zig_tmpl, "ios_link_frameworks", w);
    try tpl.writeSection(build_zig_tmpl, "ios_device_step", w);

    // Simulator build: exe + framework linking + install step
    try tpl.writeSection(build_zig_tmpl, "ios_sim_exe", w);
    try tpl.writeSection(build_zig_tmpl, "ios_link_frameworks_sim", w);
    try tpl.writeSection(build_zig_tmpl, "ios_sim_step", w);

    try tpl.writeSection(build_zig_tmpl, "ios_footer", w);
} else {
    // ... existing desktop path
}
```

No new dependencies needed in `build.zig.zon` — sokol-zig handles iOS natively, unlike WASM which needs the emsdk dependency.

### 1.3 — iOS config in `config.zig`

Add `IosConfig` struct and `ios: ?IosConfig` field on `ProjectConfig`. Defaults derived from project name/title when absent.

### 1.4 — New `src/cli/ios.zig`

New module (analogous to `src/cli/serve.zig` for WASM), ported from v0.4.5's `ios_commands.zig`. Core functions:

**`deployToSimulator(allocator, target_dir, ios_config)`**:
1. Run `zig build ios-sim` in the target dir (cross-compiles to iOS simulator)
2. Create `.app` bundle directory with binary + `Info.plist`
3. `chmod +x` the binary (required for simulator execution)
4. Call `ensureSimulatorBooted()` — checks for booted simulator via `xcrun simctl list devices booted -j`, boots an iPhone if none found
5. `xcrun simctl install booted GameName.app`
6. `xcrun simctl launch booted com.bundle.id` — parse PID from output

**`generateSimulatorInfoPlist(allocator, ios_config)`**:
Minimal plist for simulator (proven in v0.4.5):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>{{SANITIZED_NAME}}</string>
    <key>CFBundleIdentifier</key>
    <string>{{BUNDLE_ID}}</string>
    <key>CFBundleName</key>
    <string>{{APP_NAME}}</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>UIRequiredDeviceCapabilities</key>
    <array><string>arm64</string></array>
    <key>UISupportedInterfaceOrientations</key>
    <!-- orientation-dependent array -->
</dict>
</plist>
```

**`ensureSimulatorBooted(allocator)`**:
Auto-detection logic (from v0.4.5):
1. `xcrun simctl list devices booted -j` — parse JSON for first UDID
2. If none booted, `xcrun simctl list devices available` — find first iPhone line, extract UDID
3. `xcrun simctl boot <udid>`, sleep 2s for boot
4. Return UDID (or `"booted"` as fallback, which simctl understands)

### 1.5 — CLI run handler in `cli.zig`

In the run command section (line ~401):

```zig
if (parsed.platform == .wasm) {
    try serve.serveAndOpen(allocator, web_dir, 8080);
} else if (parsed.platform == .ios) {
    try ios.deployToSimulator(allocator, target_dir, parsed.ios_config);
} else {
    // desktop: zig build run
}
```

### 1.6 — Fingerprint auto-fix

v0.4.5 included a clever fingerprint fix: if `zig build` fails with a fingerprint mismatch, parse the suggested fingerprint from stderr, update `build.zig.zon`, and retry. This eliminates a common friction point when iOS build files are regenerated. Port this to v1.x.

---

## Phase 2: Asset Bundling + Info.plist Polish

**Goal**: Assets load correctly on iOS, and the app presents properly on all screen sizes.

### 2.1 — Asset inclusion in `.app` bundle

Copy `assets/` directory into the `.app` bundle during `deployToSimulator()`. The v0.4.5 implementation also copies `resources/` and `project.labelle` into the Xcode project output.

If the engine's asset loader uses relative paths (e.g., `assets/sprite.tga`), it may need a small adjustment on iOS to resolve from the app bundle's resource directory. This is an engine-level concern.

### 2.2 — Full Info.plist generation

Port the v0.4.5 `generateInfoPlist()` which includes all required keys:

```xml
<key>CFBundleDevelopmentRegion</key>     <string>en</string>
<key>CFBundleDisplayName</key>           <string>{{APP_NAME}}</string>
<key>CFBundleExecutable</key>            <string>$(EXECUTABLE_NAME)</string>
<key>CFBundleIdentifier</key>            <string>{{BUNDLE_ID}}</string>
<key>CFBundlePackageType</key>           <string>APPL</string>
<key>LSRequiresIPhoneOS</key>            <true/>
<key>UILaunchStoryboardName</key>        <string>LaunchScreen</string>
<key>UIRequiredDeviceCapabilities</key>  <array><string>arm64</string><string>metal</string></array>
<key>UIRequiresFullScreen</key>          <true/>
<key>UIStatusBarHidden</key>             <true/>
<key>UISupportedInterfaceOrientations</key>  <!-- orientation-dependent -->
<key>MinimumOSVersion</key>              <string>{{MINIMUM_IOS}}</string>
```

Orientation is configurable (`.portrait`, `.landscape`, `.all`) and maps to the correct UIInterfaceOrientation strings.

### 2.3 — LaunchScreen.storyboard generation

Port the v0.4.5 `generateLaunchScreen()` — a minimal storyboard with centered app name label on dark background. This is required for full-screen rendering on modern iOS.

### 2.4 — Post-generation step in `root.zig`

Write `Info.plist` and `LaunchScreen.storyboard` during `labelle generate` so they live alongside `build.zig` and `main.zig` in the generated directory.

---

## Phase 3: Device Deployment + Code Signing

**Goal**: `labelle ios xcode` generates a complete Xcode project for device deployment with code signing.

### 3.1 — CLI command structure

Following v0.4.5's proven UX (subcommands rather than flags):

```
labelle ios build              # Build for iOS device
labelle ios build --simulator  # Build for iOS simulator
labelle ios build --release    # Release configuration
labelle ios xcode              # Generate Xcode project
labelle ios xcode --team-id=X  # With signing team
labelle ios run --simulator    # Build + deploy to simulator
```

### 3.2 — Xcode project generation

Port `generatePbxproj()` from v0.4.5. The function generates a complete `project.pbxproj` with:

- **PBXBuildFile** — references for binary, LaunchScreen, Assets
- **PBXCopyFilesBuildPhase** — copies pre-built Zig binary into app
- **PBXFileReference** — all project files
- **PBXGroup** — directory structure
- **PBXNativeTarget** — app target with build phases
- **PBXProject** — project root with build config list
- **PBXResourcesBuildPhase** — LaunchScreen + Assets
- **XCBuildConfiguration** — Debug + Release with:
  - `CODE_SIGN_STYLE = Automatic`
  - `PRODUCT_BUNDLE_IDENTIFIER = "{{BUNDLE_ID}}"`
  - `TARGETED_DEVICE_FAMILY = "1,2"`
  - `IPHONEOS_DEPLOYMENT_TARGET = "{{MINIMUM_IOS}}"`
  - `GENERATE_INFOPLIST_FILE = YES`
  - `INFOPLIST_KEY_UILaunchStoryboardName = LaunchScreen`
  - `INFOPLIST_KEY_UIRequiresFullScreen = YES`
  - `INFOPLIST_KEY_UIStatusBarHidden = YES`

The Xcode project wraps the pre-built Zig binary — it doesn't compile anything. Xcode's role is code signing, provisioning profile management, and deployment to physical devices.

### 3.3 — Device deployment flow

The v0.4.5 approach for device deployment:

1. `labelle ios build` — cross-compile with device target (`aarch64-ios`)
2. `labelle ios xcode` — generate Xcode project, copy binary + assets
3. Open in Xcode: `open GameName.xcodeproj`
4. User selects team in Signing & Capabilities
5. Build and run on device via Xcode

Automated deployment (future): `xcodebuild` + `xcrun devicectl device install app`.

---

## Adaptation from v0.4.5 to v1.x Architecture

### What changes

| v0.4.5 | v1.x |
|--------|------|
| Engine generates `main.zig` → CLI adds iOS packaging on top | CLI generates everything (main.zig, build.zig, iOS packaging) |
| Separate `ios.labelle` config file | Inline `.ios` section in `project.labelle` |
| `ios_main.zig` was a standalone template in the CLI | iOS main is generated by `main_zig.zig` using `mobile.txt` backend template (already works) |
| Engine's `build.zig` handled iOS SDK paths + framework linking | Generated `build.zig` must include these (new template sections) |
| `build_ios.zig` was a reference/standalone build file | iOS build logic embedded in `build_zig.txt` template sections |
| iOS as separate `labelle ios` subcommand tree | iOS as `labelle build/run --platform=ios` (consistent with WASM) + `labelle ios xcode` for device |
| Engine resolved sokol dependency + its own module conflicts | Generated build resolves all dependencies uniformly |

### What stays the same

- **sokol callback lifecycle** (`sokol_main()`, `init()`, `frame()`, `cleanup()`) — already in `mobile.txt`
- **sokol module access via engine re-export** — `const sokol = engine.sokol;`
- **`dont_link_system_libs = true`** for iOS sokol builds
- **iOS SDK path detection** via `xcrun --show-sdk-path`
- **Framework linking** — same 6 frameworks
- **Simulator deployment** — same `xcrun simctl` flow
- **Xcode project format** — same `project.pbxproj` structure
- **Three target variants** — device, simulator (arm64), simulator (x86_64)
- **`apple_a14` CPU model** for simulator SIMD compatibility

---

## Impact

### Files to create

| File | Purpose |
|------|---------|
| `src/cli/ios.zig` | Simulator deployment, Info.plist generation, .app bundling (port from v0.4.5 `ios_commands.zig`) |

### Files to modify

| File | Change |
|------|--------|
| `generator/src/config.zig` | Add `IosConfig` struct, `ios: ?IosConfig` field on `ProjectConfig` |
| `generator/src/templates/build_zig.txt` | Add iOS sections: `header_ios`, `ios_sdk_detect`, `ios_targets`, `backend_sokol_ios`, `ios_device_exe`, `ios_sim_exe`, `ios_link_frameworks`, `ios_footer` |
| `generator/src/build_files.zig` | Three-way platform branch in `generateBuildZig()` (wasm / ios / desktop) |
| `src/cli.zig` | iOS dispatch in run command handler, `labelle ios` subcommand |
| `generator/src/root.zig` | (Phase 2) Info.plist + LaunchScreen post-generation |

### Files unchanged

| File | Why |
|------|-----|
| `backends/sokol/templates/mobile.txt` | Already generates correct callback lifecycle for iOS |
| `generator/src/main_zig.zig` | Already handles callback-based lifecycle, iOS comments, module-scope runner |
| All other backends | iOS is sokol-only |
| labelle-engine, labelle-core, labelle-gfx | No changes needed — sokol abstraction handles everything |

---

## Known Issues (from v0.4.5 Experience)

1. **Clay GUI disabled on iOS Simulator** — Clay's SIMD code doesn't work on the simulator and `zclay` doesn't expose its clay artifact for adding `CLAY_DISABLE_SIMD`. Workaround: skip Clay on iOS simulator builds (engine handled this with `is_ios_simulator` flag).

2. **zaudio disabled on iOS** — miniaudio requires Objective-C compilation for `AVFoundation.h`, but zaudio compiles it as C. sokol_audio works on iOS as an alternative (the engine already uses sokol audio for the sokol backend).

3. **Fingerprint mismatches** — Zig's package fingerprint can mismatch after regeneration. v0.4.5 solved this by parsing the suggested fingerprint from build stderr and auto-fixing `build.zig.zon`.

4. **Path resolution for `ios/` subdirectory** — v0.4.5 generated iOS build files in a `project/ios/` subdirectory, requiring relative path adjustments (`../main.zig`, engine path from `ios/` to `..`). The v1.x architecture generates everything in `.labelle/<target>/` which simplifies this.

---

## Risks

1. **sokol-zig + Zig 0.15.2 iOS cross-compilation** — v0.4.5 used a pinned sokol-zig commit (`bb1a4e9`). The current v1.x uses master. Need to verify the master branch still builds for iOS targets. Mitigation: test early with `zig build -Dtarget=aarch64-ios-simulator`.

2. **Module conflict between v1.x backend architecture and iOS** — v1.x's backend system (separate gfx/input/audio/window modules) is different from v0.4.5's monolithic engine. The iOS build must wire all 4 backend modules plus avoid sokol module duplication. Mitigation: follow the existing `mobile.txt` template pattern, which already handles this.

3. **Asset paths at runtime** — The sokol backend's asset loader may not resolve relative paths correctly inside an iOS `.app` bundle. Mitigation: test with actual assets in Phase 2.

---

## Open Questions

1. **Command structure** — Should iOS use `labelle build --platform=ios` (consistent with WASM) or `labelle ios build` (v0.4.5 UX, more discoverable)? Recommendation: both — `--platform=ios` for build/run, `labelle ios xcode` as a dedicated subcommand for Xcode project generation.

2. **Simulator auto-detection** — v0.4.5 scans `xcrun simctl list` for the first available iPhone. Should v1.x prefer the newest iPhone model, or allow `--simulator="iPhone 16 Pro"` override?

3. **Android parity** — v0.4.5 also had `src/android/` with similar structure. Android shares the `mobile.txt` template and needs equivalent packaging (APK, AndroidManifest.xml). Should this RFC cover both, or keep them separate?

4. **Hot reload** — Should `labelle run --platform=ios` watch for changes and redeploy? WASM gets free reload via browser refresh. iOS would need to rebuild, reinstall, and relaunch — doable but adds scope.
