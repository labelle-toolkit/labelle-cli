# Building game-owned shaders

The assembler discovers `materials/<name>/material.json` and generates the `@import("materials")` module. `labelle generate` validates and stages descriptors; `labelle build`, `labelle run`, and direct `zig build` execute shaderc in the generated build graph. Shader compilation is not a user prebuild hook, and `LABELLE_NO_PREBUILD` does not disable it. Watched wasm builds retain the same generate/build sequence.

Without an override, the generated graph builds the hash-pinned compiler for the **host**, independently of the game target. To reuse a compatible compiler on Windows:

```powershell
$env:LABELLE_SHADERC = 'C:/tools/shaderc.exe'
labelle build
```

The override is inherited by the Zig subprocess. It must be an absolute executable path; the CLI diagnoses an unavailable override when the project has `materials/`. Direct generated builds also accept `zig build -Dshaderc=C:/tools/shaderc.exe`. Unset the override to return to automatic provisioning. Docker builds need paths and tools available inside the container.

The generated graph supplies pinned BGFX headers and sprite varyings, compiles each explicitly requested variant, and propagates shader diagnostics/nonzero exits. Windows/Linux desktop currently require SPIR-V, Apple requires Metal, Android/web require GLES. GLSL/Metal/GLES bytecode generation on Windows is supported by shaderc; this alone does not establish GPU runtime coverage on those targets.

Use `materials.NAME.shaders`, `&materials.NAME.parameters`, `.label`, and `.blend` with the engine's catalog-backed texture bindings. The low-level generated `descriptor(&bindings)` helper returns core's borrowed descriptor, whose texture bindings differ from the engine's catalog union. Source includes can use material-local files or `materials/shared/`; parent traversal and macro include paths are rejected. The complete materials tree is tracked for conservative include-cache invalidation.

See the assembler's `docs/shader-materials.md` for the exact JSON contract and tests. No release version pins change as part of this feature; local integration must use compatible core/engine/gfx/backend snapshots with material contract v2.
