# Backend texture capabilities

`labelle astc` reads the pinned `.backend_package`'s `backend.manifest.zon`.
The CLI does not infer upload support from backend names or release versions.
The build pipeline installs dependencies before conversion. For a standalone
`labelle astc` on a cold cache, run `labelle install` first.

```zig
.texture_caps = .{
    .wasm = .{
        .astc = .{
            .blocks = .{ .@"4x4", .@"8x8" },
            .default_block = .@"8x8",
        },
        .fallback = .png,
    },
},
```

Target keys are the exact names supplied by the build pipeline or `--platform`.
There is no target-name table or implicit aliasing: a backend serving both
`wasm` and `web` declares both. Unknown unrelated root fields are ignored;
the texture declarations themselves are strict. Blocks must be supported ASTC
sizes, unique and nonempty, and `default_block` must be a member of `blocks`.
The optional `fallback` is `png` or `none` (default `none`). This records the
runtime fallback contract for assembler consumers; this change does not move
the assembler's existing PNG-fallback generation (assembler #378).

A missing package declaration, missing manifest/texture section, or undeclared
target uses the conservative 4x4-only default. A missing package directory or
malformed declaration is an error, never a silent fallback. The command logs
`manifest` or `conservative_default` so its decision is visible. An explicit
`--backend` switch away from the project's backend cannot reuse the previous
backend's package metadata and therefore uses the conservative default.

Selection precedence remains `--block`, then the atlas's `.astc_block`, then
the backend default. Unsupported explicit flags fail; unsupported atlas pins
warn and use the backend default. Existing sibling headers are checked before
reuse, so a capability/default change re-encodes stale blocks.

Older backend releases without this extension safely use 4x4. To retain an
8x8 default, pin a backend release carrying the declaration. In particular,
the companion bgfx manifest declares 4x4/8x8 with an 8x8 default and web PNG
fallback. It deliberately does not advertise unverified intermediate blocks.
