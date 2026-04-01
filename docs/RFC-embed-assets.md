# RFC: Embed Assets in Binary

## Problem

Production game builds ship loose `.png` and `.json` files alongside the binary. Users can see/modify game assets. WASM builds can't access the filesystem at all (blocked by #105).

## Goal

A single-binary deployment where all sprite atlases (PNG textures + JSON frame data) are compiled into the executable via `@embedFile`. No loose asset files.

## Trigger

```zig
// project.labelle
.embed_assets = true,  // or inferred from --optimize=Release*
```

## Architecture

### Current flow (file-based)
```
assets/background.png  →  game.loadAtlas("bg", "assets/background.json", "assets/background.png")
                           ↓
                       renderer.loadTexture(path)  →  Backend.loadTexture(path)  →  file I/O
```

### Proposed flow (embedded)
```
@embedFile("assets/background.png")  →  game.loadAtlasFromMemory("bg", json_bytes, png_bytes, ".png")
                                         ↓
                                     renderer.loadTextureFromMemory(data, ".png")  →  Backend.loadTextureFromMemory(data, ".png")
```

## Changes per layer

### 1. labelle-gfx (backend contract)

Add to backend interface:
```zig
pub fn loadTextureFromMemory(file_type: [:0]const u8, data: []const u8) !Texture;
```

Add to `retained_engine.zig` and `renderer.zig`:
```zig
pub fn loadTextureFromMemory(self: *Self, file_type: [:0]const u8, data: []const u8) !TextureId;
```

### 2. Backend implementations

**Raylib** (`labelle-cli/backends/raylib/src/gfx.zig`):
```zig
pub fn loadTextureFromMemory(file_type: [:0]const u8, data: []const u8) !Texture {
    const image = rl.loadImageFromMemory(file_type, data) catch return error.LoadFailed;
    defer rl.unloadImage(image);
    const tex = rl.loadTextureFromImage(image) catch return error.LoadFailed;
    return .{ .id = tex.id, .width = tex.width, .height = tex.height };
}
```

**Sokol** — equivalent approach:
- `sg_make_image()` with `.data.subimage[0][0] = .{ .ptr = data.ptr, .size = data.len }`
- Requires decoding PNG to raw pixels first (sokol doesn't decode PNG)
- Options: (a) use `stbi_load_from_memory` (stb_image is already a sokol dep), (b) use Zig's `std.compress.zlib` + custom PNG decoder
- **Recommendation**: Use stb_image which sokol already bundles — `stbi_load_from_memory(data.ptr, data.len, &w, &h, &channels, 4)`

**Mock** — trivial stub returning a dummy texture.

### 3. labelle-engine (game API)

Add to `game.zig`:
```zig
pub fn loadAtlasFromMemory(
    self: *Self,
    name: []const u8,
    json_content: []const u8,
    image_data: []const u8,
    file_type: [:0]const u8,
) !void {
    const tex_id = try self.renderer.loadTextureFromMemory(file_type, image_data);
    const id: u32 = @intFromEnum(tex_id);
    try self.atlas_manager.loadAtlasFromJsonContent(name, json_content, id);
}
```

Note: `atlas_manager.loadAtlasFromJsonContent()` already exists — it parses JSON from a string instead of reading a file.

### 4. labelle-cli (codegen)

When `embed_assets = true` (or `--optimize != Debug`), generate:

```zig
// Embedded atlas data (comptime)
const background_json = @embedFile("assets/background.json");
const background_png = @embedFile("assets/background.png");

// In setup:
try g.loadAtlasFromMemory("background", background_json, background_png, ".png");
```

When `embed_assets = false` (default, dev mode):
```zig
// File-based loading (current behavior)
try g.loadAtlas("background", "assets/background.json", "assets/background.png");
```

### 5. WASM special case

WASM should always embed assets (no filesystem). The CLI can enforce:
```zig
const should_embed = cfg.embed_assets or cfg.platform == .wasm;
```

## Config surface

```zig
// project.labelle
.embed_assets = true,  // explicit opt-in
```

Or automatic based on optimize mode:
```
labelle build --optimize=ReleaseSafe  →  embed_assets = true
labelle build                         →  embed_assets = false (dev, file-based)
```

## Binary size impact

Typical 2D game assets:
- Background atlas: ~2-4 MB (PNG)
- Character atlas: ~1-2 MB (PNG)
- Objects atlas: ~500 KB (PNG)
- JSON frame data: ~50 KB total

Total: ~5-8 MB added to binary. Acceptable for single-binary deployment.

## Migration path

1. Add `loadTextureFromMemory` to gfx backend contract + raylib + sokol
2. Add `loadAtlasFromMemory` to engine
3. CLI generates `@embedFile` when `embed_assets = true`
4. WASM always embeds

No breaking changes — file-based loading remains the default for development.

## Open questions

- Should `embed_assets` auto-enable for all release builds, or require explicit opt-in?
- Should embedded assets be compressed (gzip) in the binary and decompressed at load? Saves ~60% binary size but adds startup cost.
- Should we embed JSONC scenes (#105) at the same time using the same flag?
