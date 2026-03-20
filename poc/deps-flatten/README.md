# POC: Flattened deps for short build.zig.zon paths

## Problem
Generated build.zig.zon has long relative paths like:
```
.path = "../../../../../.labelle/packages/cli/1.15.0/ecs/zig-ecs"
```

## Approach: Override transitive deps in top-level zon

Zig's package system allows a parent package to override its dependencies'
transitive deps. If the top-level build.zig.zon declares ALL packages
(including transitive ones), sub-packages use the parent's versions.

The generated zon would declare:
```zon
.labelle_core = .{ .path = "deps/labelle_core" },
.labelle_gfx = .{ .path = "deps/labelle_gfx" },
.engine = .{ .path = "deps/engine" },
// Transitive: gfx sub-packages
.spatial_grid = .{ .path = "deps/labelle_gfx/spatial_grid" },
.camera = .{ .path = "deps/labelle_gfx/camera" },
.tilemap = .{ .path = "deps/labelle_gfx/tilemap" },
// Transitive: engine sub-packages
.scene = .{ .path = "deps/engine/scene" },
```

And the build.zig would override sub-package deps:
```zig
gfx_mod.addImport("labelle-core", core_mod); // already done
engine_mod.addImport("labelle-core", core_mod); // already done
```

## Key insight
Zig 0.15's build system does NOT follow symlinks for path resolution.
It resolves relative paths from the zon file's directory, not the symlink target.
So symlinks break transitive deps that use relative paths.

## Solution
Instead of symlinks, the generator should:
1. Create deps/ with symlinks to packages that have NO relative transitive deps
   (labelle_core, standalone plugins)
2. For packages WITH relative transitive deps (engine, gfx), declare their
   sub-packages explicitly in the top-level zon
3. Use addImport overrides (already done) to deduplicate module instances

This hybrid approach: symlinks for leaf packages + explicit sub-package
declarations for packages with relative transitive deps.
