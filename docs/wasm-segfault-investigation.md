# WASM segfault root-cause investigation (#196)

**Status:** Root cause identified and reproduced under a fix. The fix
lives in `labelle-engine` (and `labelle-gfx`), not in this repo — see
"Fix" below for the patch. The original "first sprite texture upload
segfaults" framing was a red herring: the texture upload itself
succeeds. What actually crashes is the *first Zig-side `std.debug.print`
to stderr* that runs immediately after the upload.

## Reproduction

```bash
cd labelle-assembler/examples/raylib
rm -rf .labelle && labelle build --platform=wasm
cd .labelle/raylib_wasm/zig-out/web
python3 -m http.server 8765
# Real Chrome (NOT headless software-WebGL):
google-chrome http://localhost:8765/game.html
```

Console output stops at:

```
INFO: TEXTURE: [ID 13] Texture loaded successfully (128x32 | R8G8B8A8 | 1 mipmaps)
Aborted(segmentation fault)
```

## The "segfault" is `SAFE_HEAP` misreporting

The default `ReleaseSafe` build sets `SAFE_HEAP=1`. With that off, the
real abort surfaces:

```
Aborted(Assertion failed)
  at Object.write (game.js:3378:9)         ← assert(offset >= 0)
  at doWritev    (game.js:10697:23)
  at _fd_write   (game.js:10786:17)
  at game.wasm.writev
  at game.wasm.posix.writev
  at game.wasm.fs.File.Writer.drain
  at game.wasm.Io.Writer.write
```

So it's a Zig `Io.Writer` → `posix.writev` → `_fd_write` chain, not a
texture or GL crash. The texture upload printed `Texture loaded
successfully` from raylib's *own* stdout `TRACELOG`; that one went
through fine. The very next write — Zig writing the first line to
stderr (fd=2) — is the one that aborts.

## The real bug: JS `HEAPU32` is detached when `_fd_write` reads `iov`

Instrumenting `doWritev` to log the JS-side state just before it touches
`HEAPU32` produces this on the failing call:

```
[DBG doWritev] fd=2 iov=47784 iovcnt=2 HEAPU32.len=0 wasmBuf.byteLength=67502080 same=false
[DBG doWritev] i=0 ptr=undefined len=undefined
  → "Cannot perform Construct on a detached ArrayBuffer"
```

Key signals:

- `HEAPU32.len = 0` — the cached `HEAPU32` typed-array view's backing
  buffer was **detached**.
- `wasmBuf.byteLength = 67502080` — meanwhile `wasmMemory.buffer` is
  now a *new*, larger buffer (was 67108864 = 64 MB, grew by exactly 6
  wasm pages).
- `same = false` — `HEAPU32.buffer !== wasmMemory.buffer`. The wasm
  memory grew; the JS views never picked up the new buffer.

The next `_fd_write` reads `HEAPU32[iov >> 2]`, the typed array is
detached, that read returns `undefined`, the eventual `assert(offset
>= 0)` fires on `undefined >= 0 === false`, and emscripten aborts. The
emscripten "Aborted(segmentation fault)" string is a generic abort
label and unrelated to a real CPU segfault.

## Why the views are stale: `@wasmMemoryGrow` bypasses `_emscripten_resize_heap`

Emscripten owns memory growth: every call to libc `malloc`/`realloc`
that needs more pages goes through `_emscripten_resize_heap` →
`growMemory` → `wasmMemory.grow()` → `updateMemoryViews()`, which
rebinds `HEAPU32` (et al.) to the new `ArrayBuffer`. So all libc-routed
growth keeps JS views fresh.

`std.heap.page_allocator` on `wasm32-emscripten` resolves to
`std.heap.WasmAllocator` (see `std/heap.zig:346-352` in Zig 0.15.2),
which calls **`@wasmMemoryGrow(0, …)` directly** — a raw wasm
`memory.grow` instruction. That instruction grows the linear memory
without ever crossing into JS, so `updateMemoryViews()` never runs and
every JS-side typed-array view stays bound to the old (now-detached)
`ArrayBuffer`. The next time JS reads `HEAPU32[…]`, length is 0 and
every index returns `undefined`.

The raylib backend's `decodeImage` allocates `width*height*4` bytes
through whichever allocator the asset catalog hands it (currently
`game.allocator = std.heap.c_allocator`, which IS routed via emscripten
and IS safe). But several places in `labelle-engine` and one in
`labelle-gfx` use `std.heap.page_allocator` directly — and those are
the calls that detach the heap:

| Location | Use |
|---|---|
| `labelle-engine/src/jsonc/prefab_cache.zig:28,65` | persistent prefab `Value` arena (lives game-lifetime so GPA doesn't flag as leak) |
| `labelle-engine/src/jsonc/deserializer.zig:57` | interned-string arena |
| `labelle-engine/src/jsonc/scene_loader.zig:523` | persistent ID array per scene entity array |
| `labelle-gfx/src/backend.zig:219` | legacy `loadTextureFromMemory` decode buffer (no engine caller today, but still compiled in) |

The first one of these to fire under our raylib-wasm example is
`prefab_cache.zig`'s persistent allocator — invoked by the very next
line of generated `main.zig` after `loadAtlasFromMemory("sprites",
…)`:

```zig
JsoncBridge.addEmbeddedPrefab(&g, "coin", @embedFile("prefabs/coin.jsonc"), "prefabs") catch @panic(…);
```

`addEmbeddedPrefab` → `getOrCreatePrefabCache` → `persistent.create(PrefabCache)`
→ `WasmAllocator.alloc` → `@wasmMemoryGrow` → JS views detached →
first `std.debug.print` (which the asset-streaming pipeline emits in
the assembler-generated init log right around the same point) aborts.

The reason it *looks like* the crash is during the texture upload is
purely ordering: raylib's stdout `TRACELOG("INFO: TEXTURE: … loaded
successfully")` is the last successful console output, then the
prefab-cache page-alloc grows wasm memory, then the next Zig stderr
write aborts.

## Validation

Patching the four `std.heap.page_allocator` sites above to use
`std.heap.c_allocator` on `wasm32-emscripten` (and keeping
`page_allocator` everywhere else so desktop GPA leak-detection still
works) lets the example clear the texture-upload barrier cleanly. With
the patch the failing line stops being the writev assertion and
becomes a *different* panic further downstream:

```
INFO: TEXTURE: [ID 13] Texture loaded successfully (128x32 | R8G8B8A8 | 1 mipmaps)
info: [Scene] 'main' has no manifest, eager-loaded 1 resources (Debug build)
panic: failed to set initial scene
```

That stderr `info: [Scene] …` line is the proof point: it's the first
successful Zig→stderr write under wasm32-emscripten. The follow-on
`failed to set initial scene` is a separate downstream bug (the scene
loader's filesystem fallback under emscripten's virtual FS) — not part
of #196 and out of scope here.

## Fix (lives in labelle-engine + labelle-gfx, not labelle-cli)

Four single-line swaps. The pattern is identical in each site — add a
file-scope const that selects the allocator by target.os and reference
it instead of `std.heap.page_allocator`:

```zig
const builtin = @import("builtin");
const persistent_allocator: std.mem.Allocator = if (builtin.target.os.tag == .emscripten)
    std.heap.c_allocator
else
    std.heap.page_allocator;
```

Replace every `std.heap.page_allocator` in the four files above with
`persistent_allocator`. `c_allocator` is libc-backed → emscripten's
malloc → `_emscripten_resize_heap` → `updateMemoryViews()`. JS views
stay live, `_fd_write` never sees a detached buffer.

Desktop targets keep `page_allocator` (preserves the existing
"deliberately not freed → page allocator so GPA doesn't flag" pattern
documented in `prefab_cache.zig`'s top-of-file note).

## What this does NOT fix

- `failed to set initial scene` — scene loader filesystem fallback
  under emscripten VFS. Separate issue; reproducible the moment #196's
  texture barrier is past.
- sokol-wasm build errors (#197, #198 territory). Unrelated.
- `--watch` / `--no-build` / `--port` flags for `labelle serve --wasm`.
  Polish; the underlying serve loop in `src/cli/serve.zig` already
  works.

## Notes for future debuggers

- **Build with `SAFE_HEAP` off when chasing wasm aborts.** It rewrites
  every signal into a uniform "segmentation fault" string and buries
  the real assertion. The `ReleaseSafe` default in
  `zemscripten.emccDefaultSettings` turns it on; an
  `emcc_settings.remove("SAFE_HEAP")` in the generated `build.zig`
  while diagnosing is invaluable.
- **`--profiling-funcs` preserves wasm function names in stack
  traces.** Without it you get `wasm-function[1077]` and nothing else.
- **Headless Chrome's software WebGL refuses to initialise GLFW** —
  the GLFW init fails silently, raylib later calls `glBindTexture` on
  an undefined GL context, and you'll think you're chasing a GL bug.
  Use `--use-gl=swiftshader --enable-unsafe-swiftshader` (the spike
  doc uses these) or a real headed browser.
- The Chrome warning `GL Driver Message (… GL_CLOSE_PATH_NV, High):
  GPU stall due to ReadPixels` that shows up *after* the abort is
  unrelated — it's swiftshader telling you it stalled while writing
  the post-abort error screenshot.
