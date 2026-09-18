# Building game-owned shaders

The assembler discovers `materials/<name>/material.json` and generates the `@import("materials")` module. `labelle generate` validates and stages descriptors; `labelle build`, `labelle run`, and direct `zig build` execute shaderc in the generated build graph. Shader compilation is not a user prebuild hook, and `LABELLE_NO_PREBUILD` does not disable it. Watched wasm builds retain the same generate/build sequence.

Without an override, the generated graph builds the hash-pinned compiler for the **host**, independently of the game target. To reuse a compatible compiler on Windows:

```powershell
$env:LABELLE_SHADERC = 'C:/tools/shaderc.exe'
labelle build
```

The override is inherited by the Zig subprocess. It must be an absolute path to an existing, **executable** regular file. When the project has `materials/`, the CLI preflights the value **before package installation and before generation** and **fails the build** — naming the offending value — if it is relative (`LABELLE_SHADERC 'shaderc' is not an absolute path...`), missing (`... is unavailable (FileNotFound)`), a directory (`... is a directory, not an executable file`), or not executable (`... is not executable by the user running labelle: mode 644; \`chmod +x ...\`` — the check is an `access(X_OK)`-equivalent, so a file whose execute bit belongs to a permission class you are not in, such as mode `001` on a file you own, is rejected rather than accepted; on Windows, no `.exe`/`.com` extension). A Windows `.bat`/`.cmd` wrapper is **rejected** with its own message: Windows cannot spawn a batch file as a process image (it only runs via `cmd.exe /c`) and the generated build graph spawns this path directly, so point `LABELLE_SHADERC` at the `shaderc.exe` the wrapper invokes. Because the gate runs ahead of the install step, a bad value is reported without first waiting for the package fetch. It never falls back to the pinned compiler behind your back: unset the variable to get automatic provisioning. Direct generated builds also accept `zig build -Dshaderc=C:/tools/shaderc.exe`.

**`--docker` builds do not receive the override.** The value is still validated on the host — a bad one fails at the preflight, naming it, rather than deep inside the container — but it is deliberately *not* forwarded in, and the CLI prints:

```
labelle: note: LABELLE_SHADERC '<path>' is a HOST path and is NOT forwarded into the --docker build; the container compiles shaders with its own pinned compiler. A host executable cannot run inside the linux build image, so mapping it in would fail at exec time. Drop --docker for the override to take effect.
```

Bind-mounting a host-OS/arch `shaderc` into the Linux build image would only swap an honest preflight failure for an `Exec format error` far into `zig build`, so the containerised build provisions the pinned compiler itself.

The generated graph supplies pinned BGFX headers and sprite varyings, compiles each explicitly requested variant, and propagates shader diagnostics/nonzero exits. Windows/Linux desktop currently require SPIR-V, Apple requires Metal, Android/web require GLES. GLSL/Metal/GLES bytecode generation on Windows is supported by shaderc; this alone does not establish GPU runtime coverage on those targets.

Use `materials.NAME.shaders`, `&materials.NAME.parameters`, `.label`, and `.blend` with the engine's catalog-backed texture bindings. The low-level generated `descriptor(&bindings)` helper returns core's borrowed descriptor, whose texture bindings differ from the engine's catalog union. Source includes can use material-local files or `materials/shared/`; parent traversal and macro include paths are rejected. The complete materials tree is tracked for conservative include-cache invalidation.

See the assembler's `docs/shader-materials.md` for the exact JSON contract and tests. No release version pins change as part of this feature; local integration must use compatible core/engine/gfx/backend snapshots with material contract v2.
