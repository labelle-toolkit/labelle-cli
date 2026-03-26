# ZON-to-JSONC Scene Conversion Guide

Part of RFC #87 (runtime scenes). This guide covers converting comptime `.zon` scene
files to runtime `.jsonc` format for games in the labelle-toolkit monorepo.

## Syntax mapping

| ZON                                    | JSONC                                   |
|----------------------------------------|-----------------------------------------|
| `.{ .key = value }`                    | `{ "key": value }`                      |
| `.enum_literal`                        | `"enum_literal"`                        |
| `.{ item1, item2 }` (tuple)           | `[item1, item2]` (array)               |
| `// comment`                           | `// comment`                            |
| `.{}`  (empty struct)                  | `{}`                                    |
| `.{}`  (empty tuple)                   | `[]`                                    |

## File changes

- Rename `scenes/*.zon` to `scenes/*.jsonc`
- Add `.states` to `project.labelle` if not already present

## Script directory convention

With runtime scenes, scripts can be organized by game state:

```
scripts/              # global scripts (run in all states)
scripts/playing/      # only active in "playing" state
scripts/menu/         # only active in "menu" state
```

## Games requiring conversion

The following sibling repos still have comptime `.zon` scenes and need conversion.

### bakery-game

**scenes/main.zon** — 1 scene, 9 scripts, ~15 entities (baker, items, workstations,
movement nodes, labels). Key conversion notes:
- `.scripts = .{ "name1", "name2" }` becomes `"scripts": ["name1", "name2"]`
- `.{ .prefab = "oven" }` becomes `{ "prefab": "oven" }`
- Nested shapes: `.shape = .{ .rectangle = .{ .width = 80, .height = 40 } }` becomes
  `"shape": { "rectangle": { "width": 80, "height": 40 } }`
- Enum values: `.item_type = .Flour` becomes `"item_type": "Flour"`
- Commented-out entities (IOS/EOS) can remain as JSONC comments

**project.labelle** — add `.states = .{ "playing" }`

### flying-platform-labelle

**8 scene files** to convert: `main.zon`, `menu.zon`, `grid_test.zon`,
`sleep_test.zon`, `drink_test.zon`, `eat_test.zon`, `hydroponics_test.zon`,
`rabbit_test.zon`.

Each scene has its own script list. Key conversion notes:
- All scenes use prefab-heavy entity definitions
- `menu.zon` is minimal (1 script, no entities)
- Test scenes override prefab components inline:
  `.NeedState = .{ .sleep = 0.3 }` becomes `"NeedState": { "sleep": 0.3 }`

**project.labelle** — add `.states = .{ "menu", "playing" }`

Scripts that appear only in `menu.zon` (`scene_menu`) could move to `scripts/menu/`.
Scripts shared across gameplay scenes could stay in `scripts/` (global).

### df-labelle

**scenes/main.zon** — 1 scene with player entity, fire hazards, and spike traps.
Key conversion notes:
- Polygon shapes: `.polygon = .{ .sides = 3, .radius = 20, .fill = .outline }` becomes
  `"polygon": { "sides": 3, "radius": 20, "fill": "outline" }`
- Named entities with `name` field carry over directly

**project.labelle** — add `.states = .{ "playing" }`

## Example: full conversion

### Before (ZON)

```zon
.{
    .name = "main",
    .scripts = .{
        "camera_control",
        "save_load",
    },
    .entities = .{
        .{ .prefab = "oven" },
        .{
            .components = .{
                .Position = .{ .x = 400, .y = 300 },
                .Text = .{ .text = "Hello", .size = 16, .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
            },
        },
    },
}
```

### After (JSONC)

```jsonc
{
    "name": "main",
    "scripts": [
        "camera_control",
        "save_load"
    ],
    "entities": [
        { "prefab": "oven" },
        {
            "components": {
                "Position": { "x": 400, "y": 300 },
                "Text": {
                    "text": "Hello",
                    "size": 16,
                    "color": { "r": 255, "g": 255, "b": 255, "a": 255 }
                }
            }
        }
    ]
}
```
