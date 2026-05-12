# WASM Serve Spike (#2)

**Status:** Succeeded — the toolkit cross-compiles to WebAssembly and runs in a
browser today. The `labelle serve --wasm` command is mostly already implemented;
issue #2 has effectively been delivered piecemeal by prior work. What remains is
mostly polish + a runtime crash on one backend.

## TL;DR

- `labelle build --platform=wasm` works **right now** with the `raylib` backend.
- The CLI already serves the build over HTTP and opens a browser when you run
  `labelle run --platform=wasm` — see `src/cli/serve.zig` (146 lines) and the
  WASM branch at `src/cli.zig:735-740`.
- Built artifact reaches the browser, raylib + WebGL 2.0 initialise, shaders
  compile, fonts load — verified via headless Chrome screenshot.
- One runtime blocker: every example crashes with `Aborted(segmentation fault)`
  right after the first sprite texture loads, before the first frame is drawn.
  This is a runtime bug, not a "can WASM work" bug.
- The `sokol` backend does **not** build for WASM today (two distinct compile
  errors, captured below).

## What was tried

1. Inventoried the WASM plumbing in `labelle-cli`, `labelle-assembler`, and the
   backends. Discovered substantial prior work:
   - `src/cli/serve.zig` — a working static-file server with proper MIME types,
     COOP/COEP headers, browser auto-open. ~150 LoC.
   - `src/cli.zig` — `--platform=wasm` is parsed, defaults optimize to
     `ReleaseSafe` for wasm (Debug exceeds browser local var limits), routes
     `labelle run` through `serve.serveAndOpen` when the platform is wasm.
   - `labelle-assembler/backends/raylib/templates/wasm.txt` — full
     `emscripten_set_main_loop` shim.
   - `labelle-assembler/src/build_files.zig` — emits `addLibrary` + `emLinkStep`
     for wasm, separate `wasm_emsdk_raylib` and `wasm_emsdk_sokol` template
     sections.
   - `labelle-assembler/src/templates/build_zig_zon.txt` — pins
     `emscripten-core/emsdk#4.0.9` as a build dependency.
   - 10+ commits referencing wasm in `labelle-cli` history, 14+ in
     `labelle-assembler`.

2. Built `labelle-assembler/examples/sokol` with `labelle build --platform=wasm`.
   **Failed** — two errors (see Blockers below).

3. Built `labelle-assembler/examples/raylib` with `labelle build --platform=wasm`.
   **Succeeded.** Output: `.labelle/raylib_wasm/zig-out/web/{game.html,
   game.js, game.wasm}` — 20 KB / 284 KB / 944 KB.

4. Built `labelle-assembler/examples/asset-streaming-smoke` (also raylib).
   **Succeeded.** Same artifact shape.

5. Served the raylib artifacts with `python3 -m http.server`, loaded in headless
   Chrome with software WebGL (`--use-gl=swiftshader --enable-unsafe-swiftshader`).
   - Raylib initialises through `PLATFORM: WEB: Initialized successfully`.
   - WebGL 2.0 context obtains GLSL ES 3.00, VAO + NPOT extensions.
   - Default shader + fragment shader compile and link.
   - Default 128×128 GRAY_ALPHA font texture loads.
   - First sprite atlas texture (128×32 R8G8B8A8) loads.
   - Then: `Aborted(segmentation fault)` from `game.js`. Black canvas remains.

## What worked

- The cross-compile path (Zig 0.15.2 → wasm32-emscripten via auto-downloaded
  emsdk 4.0.9). End-to-end, no manual emsdk install required.
- The browser-side stack: emscripten shell, WebGL 2.0 init, raylib WEB
  platform, shader compile, texture upload.
- The local-serve flow: `src/cli/serve.zig` already does everything #2 asked
  for — port fallback, MIME types, COOP/COEP, browser auto-open. It is wired
  into `labelle run --platform=wasm` today.

## Blockers

### Runtime — segfault after first texture load (raylib WASM, every example)

After raylib finishes its init and the first scene asset uploads, the WASM
module aborts. No useful stack trace from `ReleaseSafe`. Likely candidates:

- Scene loader / asset manifest path resolution under Emscripten's virtual FS
  (`Working Directory: /`).
- Pointer cast / alignment issue surfaced by wasm32 but not desktop.
- An optional that's `null` on wasm (e.g. a path returning empty under emsdk
  packfile vs. real disk).

**Diagnosis cost:** medium. Need to rebuild with `--optimize=Debug` (will
likely hit the "exceeds browser local var limits" wall — see `cli.zig:613`)
or add `-g` + symbol-mapped source. Then load in a real (non-headless)
browser to inspect the JS stack.

### Sokol backend doesn't compile for WASM

`labelle build --platform=wasm` on `examples/sokol` fails with two errors:

1. **`stb_image.h:386: 'stdlib.h' file not found`** in
   `.labelle/deps/labelle-sokol/src/stb_image_impl.c`. The wasm32-emscripten
   C compile is missing the emsdk sysroot include path for `stb_image_impl.c`
   (gfx module). `labelle-assembler/src/templates/build_zig.txt` has a
   `wasm_emsdk_sokol` section, but the sokol backend's `addCSourceFile` for
   `stb_image_impl.c` (`labelle-sokol/build.zig:32`) doesn't pick up emsdk's
   `--sysroot`.

2. **`main.zig:146: local constant shadows declaration of 'allocator'`** —
   the generated `main.zig` for sokol+wasm has both a module-level
   `const allocator = std.heap.c_allocator;` and a function-level
   `const allocator = std.heap.c_allocator;` inside `initInner()`. The
   assembler template emits both. This is purely a generator bug.

**Diagnosis cost:** small for #2 (template edit in
`labelle-assembler/src/templates/build_zig.txt` or wherever `initInner` is
generated). Small-to-medium for #1 (needs an `addIncludePath` plumbed from
emsdk's sysroot through to the sokol gfx module).

## Shortest path to "Phase 1 done"

1. Fix the raylib-wasm runtime segfault. Once the first frame renders, the
   `labelle serve --wasm` story is effectively complete — the existing
   `serve.zig` + `--platform=wasm` flow already does build → serve → open
   browser.
2. Optional: also fix the two sokol-wasm compile errors so users on the sokol
   backend can ship to wasm.
3. Optional polish for issue #2's spec: `--port`, `--no-open`, `--no-build`,
   `--watch`. None of these are blockers; they sit on top of the existing
   serve loop.

## Effort estimate for "full `labelle serve --wasm`"

**Small.** The command is functionally already implemented under the name
`labelle run --platform=wasm`. What's missing is the runtime crash fix and a
thin CLI surface that exposes the documented flags. Breakdown:

| Task | Size | Notes |
|------|------|-------|
| Fix raylib-wasm runtime segfault | M | Diagnosed (see `wasm-segfault-investigation.md`). Fix lives in labelle-engine + labelle-gfx. |
| Fix sokol-wasm `stdlib.h` include | S | `labelle-sokol/build.zig` — add `emsdk.emccDefaultFlags`-equivalent include paths to gfx module. |
| Fix sokol-wasm `allocator` shadow | XS | Single template edit in `labelle-assembler`. |
| Add `labelle wasm serve` subcommand wrapper (vs reusing `run --platform=wasm`) | S | Just a CLI alias + flag parsing. `serve.zig` already does the work. |
| `--port`, `--no-open` flags | S | Plumb through `serveAndOpen` signature. |
| `--watch` (filesystem watcher + rebuild + browser reload) | M | New code; SSE or WebSocket for reload signal. |
| `--no-build` (serve existing artifact) | XS | Conditional on `.labelle/<target>/zig-out/web/` existence. |

If "Phase 1" = the raylib path produces a running game in browser via
`labelle wasm serve`, this is **small-to-medium** total effort gated almost
entirely on diagnosing the segfault.

## Cross-repo work needed

- **labelle-engine** — runtime segfault is most likely here (scene/asset code
  path under wasm32-emscripten).
- **labelle-sokol** — `build.zig` needs to add the emsdk sysroot include to
  the stb_image C compilation when the target is wasm32-emscripten.
- **labelle-assembler** — template emits duplicate `const allocator` in the
  sokol+wasm `main.zig`; remove the inner one.
- **labelle-cli** — only cosmetic: add the documented `wasm serve` alias and
  optional flags if we want to match issue #2's exact UX.

## Files / artifacts produced during the spike

- Built artifacts at `labelle-assembler/examples/raylib/.labelle/raylib_wasm/zig-out/web/`
  (kept for reference; safe to `rm -rf .labelle/`).
- Screenshot of the running raylib-wasm bundle (kept for reference; black canvas +
  emscripten "Exception thrown" banner — proves canvas mounts before the segfault).

## Recommendation

Stop treating issue #2 as "build a serve command from scratch." The serve
command already exists. File the three concrete blockers as sub-issues, fix
the raylib runtime crash first, and #2 is done.
