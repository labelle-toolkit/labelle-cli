# iOS Support for labelle-cli

iOS packaging tools for labelle-engine games using Sokol + Metal.

## Files

- `generate_xcode.zig` - Xcode project generator
- `build_ios.zig` - Reference iOS build configuration
- `templates/`
  - `ios_main.zig` - iOS entry point template with touch handling
  - `Info.plist.template` - iOS app metadata template
  - `LaunchScreen.storyboard` - Launch screen

## Overview

The iOS build process:
1. Compiles game as a static library (`.a`)
2. Generates Xcode project with:
   - `main.m` - Objective-C entry point calling `labelle_ios_main()`
   - `compiler_rt_stubs.c` - 128-bit float stubs
   - Framework linking (Foundation, UIKit, Metal, etc.)
3. Opens in Xcode for code signing and deployment

## Generated Xcode Project Structure

```
xcode/
├── AppName.xcodeproj/
│   ├── project.pbxproj
│   └── xcshareddata/xcschemes/AppName.xcscheme
└── AppName/
    ├── main.m
    ├── compiler_rt_stubs.c
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
| `simulator_x86` | x86_64-ios-simulator | Intel Mac simulator |

## Linked Frameworks

- Foundation
- UIKit
- Metal
- MetalKit
- AudioToolbox
- AVFoundation
- QuartzCore
- CoreFoundation

## Known Issues

- Physics (Box2D) not supported on iOS - see labelle-engine#222
- Touch input basic implementation - see labelle-engine#218
