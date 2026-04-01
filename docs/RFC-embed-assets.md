# RFC: Embed Assets in Binary

## Problem

Game builds ship loose `.png` and `.json` files alongside the binary. Users can see/modify game assets. WASM builds can't access the filesystem at all (#105).

## Solution

Always embed sprite atlases into the binary via `@embedFile`. Single code path for dev and production. No flags, no conditional logic.

## Architecture

```
@embedFile("assets/background.png")  →  g.loadAtlasFromMemory("bg", json_bytes, png_bytes, ".png")
                                         ↓
                                     renderer.loadTextureFromMemory(data, ".png")
                                         ↓
                                     Backend.loadTextureFromMemory(data, ".png")  →  decode PNG in memory
```

## Changes per layer

### 1. labelle-gfx (backend contract)

Add to backend interface:
```zig
pub fn loadTextureFromMemory(file_type: [:0]const u8, data: []const u8) !Texture;
```

Add to `retained_engine.zig` and `renderer.zig` the same method.

### 2. Backend implementations

**Raylib**:
```zig
pub fn loadTextureFromMemory(file_type: [:0]const u8, data: []const u8) !Texture {
    const image = rl.loadImageFromMemory(file_type, data) catch return error.LoadFailed;
    defer rl.unloadImage(image);
    const tex = rl.loadTextureFromImage(image) catch return error.LoadFailed;
    return .{ .id = tex.id, .width = tex.width, .height = tex.height };
}
```

**Sokol**: Use `stbi_load_from_memory` (already a sokol dep) to decode PNG to raw pixels, then `sg_make_image()`.

**Mock**: Stub returning dummy texture.

### 3. labelle-engine (game API)

```zig
pub fn loadAtlasFromMemory(self: *Self, name: []const u8, json_content: []const u8, image_data: []const u8, file_type: [:0]const u8) !void {
    const tex_id = try self.renderer.loadTextureFromMemory(file_type, image_data);
    const id: u32 = @intFromEnum(tex_id);
    try self.atlas_manager.loadAtlasFromJsonContent(name, json_content, id);
}
```

`loadAtlasFromJsonContent` already exists — parses JSON from a slice.

### 4. labelle-cli (codegen)

Always generate:
```zig
const background_json = @embedFile("assets/background.json");
const background_png = @embedFile("assets/background.png");

// In setup:
try g.loadAtlasFromMemory("background", background_json, background_png, ".png");
```

Remove file-based `loadAtlas` from generated code. The `game.loadAtlas(path)` API stays for manual use but the CLI never generates it.

## Migration path

1. Add `loadTextureFromMemory` to gfx backend contract + raylib + sokol + mock
2. Add `loadAtlasFromMemory` to engine
3. CLI generates `@embedFile` + `loadAtlasFromMemory` for all resources
4. Remove file-based codegen path
