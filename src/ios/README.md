# iOS Support for labelle-cli

iOS packaging tools for labelle-engine games using Sokol + Metal.

## CLI Commands

```bash
labelle ios build              # Build for iOS device
labelle ios build --simulator  # Build for iOS simulator
labelle ios build --release    # Build release configuration
labelle ios xcode              # Generate Xcode project
labelle ios run --simulator    # Run on simulator
```

## Files

- `ios_commands.zig` - Main iOS command handler (build, xcode, run)
- `generate_xcode.zig` - Standalone Xcode project generator
- `build_ios.zig` - Reference iOS build configuration
- `templates/`
  - `ios_main.zig` - iOS entry point template with touch handling
  - `Info.plist.template` - iOS app metadata template
  - `LaunchScreen.storyboard` - Launch screen

## Configuration

Create `ios.labelle` in your project for iOS-specific settings:

```zig
.{
    .app_name = "My Game",
    .bundle_id = "com.example.mygame",
    .team_id = "XXXXXXXXXX",
    .minimum_ios = "15.0",
    .orientation = .landscape,  // .portrait, .landscape, or .all
}
```

## Overview

The iOS build process:
1. Generates iOS build files in `ios/` directory
2. Compiles game as iOS executable using Sokol + Metal
3. Generates Xcode project with pre-built binary
4. Opens in Xcode for code signing and deployment

## Generated Xcode Project Structure

```
ios-xcode/
├── AppName.xcodeproj/
│   └── project.pbxproj
└── AppName/
    ├── AppName (pre-built binary)
    ├── Info.plist
    ├── LaunchScreen.storyboard
    └── Assets.xcassets/
```

## Requirements

- Zig 0.15.2+
- Xcode 15+
- Apple Developer account (for device deployment, not needed for simulator)

## Targets

| Target | Architecture | Use Case |
|--------|--------------|----------|
| `device` | aarch64-ios | Physical iPhone/iPad |
| `simulator` | aarch64-ios-simulator | M1/M2 Mac simulator |

## Linked Frameworks

- Foundation
- UIKit
- Metal
- MetalKit
- AudioToolbox
- AVFoundation

## Known Issues

- Physics (Box2D) not supported on iOS - see labelle-engine#222
- Touch input basic implementation - see labelle-engine#218
