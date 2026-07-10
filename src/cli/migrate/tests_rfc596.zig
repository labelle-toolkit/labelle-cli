// ─────────────────────────────────────────────────────────────────────
// Tests — RFC #596 transforms 5-9 spec namespaces + xref pre-scan
// ─────────────────────────────────────────────────────────────────────
//
// Moved verbatim from migrate.zig. Spec namespaces are surfaced to the
// cli test runner via re-exports in migrate.zig.

const std = @import("std");
const scanner = @import("scanner.zig");
const walk = @import("walk.zig");
const pipeline = @import("pipeline.zig");
const transforms = @import("transforms.zig");
const helpers = @import("tests_helpers.zig");

const expect = @import("zspec").expect;

const stripJsoncToJson = scanner.stripJsoncToJson;
const scanPrefabRefs = walk.scanPrefabRefs;
const applyAllArenaFull = helpers.applyAllArenaFull;
const applyAllFullCounts = helpers.applyAllFullCounts;
const FileCounts = pipeline.FileCounts;


// ─────────────────────────────────────────────────────────────────────
// RFC #596 — Transform 5: lift `overrides` block on prefab refs
// ─────────────────────────────────────────────────────────────────────

pub const TransformLiftOverridesSpec = struct {
    test "single-line overrides on a prefab ref" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "[\n" ++
            "    { \"prefab\": \"rabbit\", \"overrides\": { \"Position\": { \"x\": 400, \"y\": 0 } } }\n" ++
            "]\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"prefab\": \"rabbit\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"Position\"") != null);
        // Must parse cleanly.
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const entry = parsed.value.array.items[0].object;
        try std.testing.expect(entry.get("overrides") == null);
        try std.testing.expectEqualStrings("rabbit", entry.get("prefab").?.string);
        try std.testing.expect(entry.get("Position") != null);
    }

    test "multi-line overrides on a prefab ref preserves comments" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "[\n" ++
            "    {\n" ++
            "        \"prefab\": \"kitchen\",\n" ++
            "        // overrides block has an inner comment\n" ++
            "        \"overrides\": {\n" ++
            "            // explanatory note\n" ++
            "            \"Position\": { \"x\": 156, \"y\": 93 }\n" ++
            "        }\n" ++
            "    }\n" ++
            "]\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "// explanatory note") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"Position\"") != null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const entry = parsed.value.array.items[0].object;
        try std.testing.expect(entry.get("Position") != null);
    }

    test "empty overrides block is dropped entirely" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "[\n" ++
            "    { \"prefab\": \"x\", \"overrides\": {} }\n" ++
            "]\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\"") == null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const entry = parsed.value.array.items[0].object;
        try std.testing.expectEqualStrings("x", entry.get("prefab").?.string);
        try std.testing.expect(entry.get("overrides") == null);
    }

    test "multiple overrides across siblings all lifted" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "[\n" ++
            "    { \"prefab\": \"a\", \"overrides\": { \"Position\": { \"x\": 1 } } },\n" ++
            "    { \"prefab\": \"b\", \"overrides\": { \"Position\": { \"x\": 2 } } },\n" ++
            "    { \"prefab\": \"c\", \"overrides\": { \"Position\": { \"x\": 3 } } }\n" ++
            "]\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\"") == null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const items = parsed.value.array.items;
        try std.testing.expectEqual(@as(usize, 3), items.len);
        for (items) |it| {
            try std.testing.expect(it.object.get("overrides") == null);
            try std.testing.expect(it.object.get("Position") != null);
        }
    }
};

// ─────────────────────────────────────────────────────────────────────
// RFC #596 — Transform 6: lift inline `components` block
// ─────────────────────────────────────────────────────────────────────

pub const TransformLiftComponentsSpec = struct {
    test "single-line inline components" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "[\n" ++
            "    { \"components\": { \"BuildIntent\": { \"room_type\": \"stair_room\" } } }\n" ++
            "]\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        try std.testing.expect(std.mem.indexOf(u8, out, "\"components\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"BuildIntent\"") != null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const entry = parsed.value.array.items[0].object;
        try std.testing.expect(entry.get("components") == null);
        try std.testing.expect(entry.get("BuildIntent") != null);
    }

    test "multi-line inline components with multiple PascalCase keys" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"components\": {\n" ++
            "        \"Workstation\": { \"kind\": \"kitchen\" },\n" ++
            "        \"Image\": { \"sprite\": \"kitchen\" },\n" ++
            "        \"Position\": { \"x\": 100, \"y\": 50 }\n" ++
            "    }\n" ++
            "}\n";
        // Use a basename other than "main" so transform 7+8 don't apply.
        const out = try applyAllArenaFull(&arena, src, "no_collapse_basename_xyz");
        try std.testing.expect(std.mem.indexOf(u8, out, "\"components\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"Workstation\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"Image\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"Position\"") != null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expect(obj.get("components") == null);
        try std.testing.expect(obj.get("Workstation") != null);
        try std.testing.expect(obj.get("Image") != null);
        try std.testing.expect(obj.get("Position") != null);
    }

    test "components NOT lifted when prefab sibling exists (pass 4 + 5 handle it)" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // This is the legacy "components-on-ref" case: pass 4 renames
        // `components` to `overrides`, then pass 5 lifts that. The
        // result should not have either `components` OR `overrides`,
        // and Position should be a direct sibling of prefab.
        const src =
            "[\n" ++
            "    { \"prefab\": \"x\", \"components\": { \"Position\": { \"x\": 1 } } }\n" ++
            "]\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        try std.testing.expect(std.mem.indexOf(u8, out, "\"components\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\"") == null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const entry = parsed.value.array.items[0].object;
        try std.testing.expectEqualStrings("x", entry.get("prefab").?.string);
        try std.testing.expect(entry.get("Position") != null);
    }

    test "deep-nested inline components (storages array) lifted recursively" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // Mimics the butcher_workstation shape: outer inline components,
        // inner storage entries each with their own inline components.
        const src =
            "{\n" ++
            "    \"components\": {\n" ++
            "        \"Workstation\": {\n" ++
            "            \"storages\": [\n" ++
            "                { \"components\": { \"Position\": { \"x\": -62 }, \"Eis\": {} } },\n" ++
            "                { \"components\": { \"Position\": { \"x\": -34 }, \"Eis\": {} } }\n" ++
            "            ]\n" ++
            "        }\n" ++
            "    }\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "no_collapse_xyz");
        // No more `components` wrappers anywhere.
        try std.testing.expect(std.mem.indexOf(u8, out, "\"components\"") == null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expect(obj.get("Workstation") != null);
        const storages = obj.get("Workstation").?.object.get("storages").?.array;
        for (storages.items) |slot| {
            try std.testing.expect(slot.object.get("components") == null);
            try std.testing.expect(slot.object.get("Position") != null);
            try std.testing.expect(slot.object.get("Eis") != null);
        }
    }
};

// ─────────────────────────────────────────────────────────────────────
// RFC #596 — Transform 7: top-level `name:` → `meta.name` or drop
// ─────────────────────────────────────────────────────────────────────

pub const TransformNameFieldSpec = struct {
    test "name matching basename is dropped" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // basename "colony" matches name "colony" — should drop.
        // We pick a structure where pass 8 will ALSO fire (children-only
        // wrapping object) to assert both behaviors integrate.
        const src =
            "{\n" ++
            "    \"name\": \"colony\",\n" ++
            "    \"children\": [\n" ++
            "        { \"prefab\": \"x\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "colony");
        // `name:` dropped, file collapsed to array.
        try std.testing.expect(std.mem.indexOf(u8, out, "\"name\"") == null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        // Should now be a top-level array.
        try std.testing.expect(parsed.value == .array);
    }

    test "name differing from basename moves to meta.name" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // basename "demo_scene", declared name "Production Demo" —
        // divergent. Pass 7 moves the `name:` into a `meta:` block;
        // pass 9 then collapses the wrapping object to a bundle with
        // a `{ meta: {...} }` header element (RFC #596 update).
        const src =
            "{\n" ++
            "    \"name\": \"Production Demo\",\n" ++
            "    \"children\": []\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "demo_scene");
        // `name:` no longer top-level; `meta:` block present in the
        // emitted bundle's header element.
        try std.testing.expect(std.mem.indexOf(u8, out, "\"meta\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "Production Demo") != null);
        // Collapses to a bundle array with a header element.
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        try std.testing.expect(parsed.value.array.items.len >= 1);
        const header = parsed.value.array.items[0].object;
        const meta = header.get("meta").?.object;
        try std.testing.expectEqualStrings("Production Demo", meta.get("name").?.string);
    }

    test "no name field — pass 7 is a no-op" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"children\": [\n" ++
            "        { \"prefab\": \"x\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        // No name field; output still parseable and collapsed to array.
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
    }

    test "divergent name WITHOUT existing meta counts as a move" {
        // Stat-accuracy (cli #241): a divergent `name:` on a file with no
        // `meta:` block is genuinely renamed to `meta.name` — count it as
        // a move, not a divergent drop.
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"Production Demo\",\n" ++
            "    \"children\": []\n" ++
            "}\n";
        var counts = FileCounts{};
        _ = try applyAllFullCounts(arena.allocator(), src, "demo_scene", &counts);
        try std.testing.expectEqual(@as(usize, 1), counts.name_field_meta_moves);
        try std.testing.expectEqual(@as(usize, 0), counts.name_field_divergent_drops);
    }

    test "divergent name WITH existing meta counts as a drop, not a move" {
        // Stat-accuracy (cli #241): when a `meta:` block already exists we
        // conservatively DROP the bare divergent `name:` (byte-merging is
        // unsafe). The summary must report this as a divergent drop, NOT a
        // move into meta.name — the value never made it into meta.
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"Production Demo\",\n" ++
            "    \"meta\": { \"author\": \"kb\" },\n" ++
            "    \"children\": []\n" ++
            "}\n";
        var counts = FileCounts{};
        const out = try applyAllFullCounts(arena.allocator(), src, "demo_scene", &counts);
        // Reported accurately: a divergent drop, not a meta.name move.
        try std.testing.expectEqual(@as(usize, 1), counts.name_field_divergent_drops);
        try std.testing.expectEqual(@as(usize, 0), counts.name_field_meta_moves);
        // The bare divergent name really was dropped — it is NOT present
        // in the existing meta (no merge happened).
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        // Header-bundle: first element's meta preserves the ORIGINAL meta
        // (author) but does not gain a `name` from the dropped field.
        try std.testing.expect(parsed.value == .array);
        const header = parsed.value.array.items[0].object;
        const meta = header.get("meta").?.object;
        try std.testing.expect(meta.get("name") == null);
        try std.testing.expect(meta.get("author") != null);
    }
};

// ─────────────────────────────────────────────────────────────────────
// RFC #596 — prefab-guard consistency (cli #241 item 6)
// ─────────────────────────────────────────────────────────────────────

pub const PrefabGuardConsistencySpec = struct {
    fn treeSays(json_src: []const u8) !bool {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json_src, .{});
        defer parsed.deinit();
        return transforms.treeHasInlineComponentsWrapper(parsed.value);
    }

    test "string prefab sibling suppresses the inline-components gate" {
        // A real prefab ref carrying a `components:` object is handled by
        // the overrides pass — the inline-components gate must skip it.
        try std.testing.expect(!try treeSays(
            "{ \"prefab\": \"x\", \"components\": { \"Position\": {} } }",
        ));
    }

    test "no prefab sibling — inline-components gate fires" {
        try std.testing.expect(try treeSays(
            "{ \"components\": { \"Position\": {} } }",
        ));
    }

    test "non-string prefab does NOT suppress the gate (matches byte scanner)" {
        // Regression for cli #241 item 6: the tree gate previously treated
        // ANY `prefab` key as a prefab ref, while the byte scanner only
        // keys off a STRING prefab. A malformed non-string `prefab` must
        // therefore NOT suppress the inline-components lift, so both paths
        // agree.
        try std.testing.expect(try treeSays(
            "{ \"prefab\": 123, \"components\": { \"Position\": {} } }",
        ));
    }
};

// ─────────────────────────────────────────────────────────────────────
// RFC #596 — Transform 8: file-as-array bundle
// ─────────────────────────────────────────────────────────────────────

pub const TransformFileAsArraySpec = struct {
    test "wrapping object with only `children:` collapses to array" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"children\": [\n" ++
            "        { \"prefab\": \"a\" },\n" ++
            "        { \"prefab\": \"b\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    }

    test "wrapping object with `name:` matching basename + `children:` collapses" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    \"children\": []\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        try std.testing.expectEqual(@as(usize, 0), parsed.value.array.items.len);
    }

    test "object with PascalCase root key does NOT collapse" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // A true root entity (has components on it) — must NOT collapse
        // because the file IS a single root entity.
        const src =
            "{\n" ++
            "    \"Workstation\": { \"kind\": \"kitchen\" },\n" ++
            "    \"children\": [\n" ++
            "        { \"prefab\": \"slot\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "kitchen");
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        try std.testing.expect(parsed.value.object.get("Workstation") != null);
    }

    test "leading comments above wrapping object are preserved" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "// header comment\n" ++
            "// another\n" ++
            "{\n" ++
            "    \"children\": [\n" ++
            "        { \"prefab\": \"x\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        try std.testing.expect(std.mem.indexOf(u8, out, "// header comment") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "// another") != null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
    }
};

// ─────────────────────────────────────────────────────────────────────
// RFC #596 (update) — Transform 8: file-level directives → meta header
// ─────────────────────────────────────────────────────────────────────

pub const TransformDirectivesToMetaHeaderSpec = struct {
    test "initial_state + children collapses to bundle with meta header" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"initial_state\": \"playing\",\n" ++
            "    \"children\": [\n" ++
            "        { \"prefab\": \"ship_carcase\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "fitness_test");
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
        // First element is the meta header.
        const header = parsed.value.array.items[0].object;
        const meta = header.get("meta").?.object;
        try std.testing.expectEqualStrings("playing", meta.get("initial_state").?.string);
        // Second element is the child entity.
        const child = parsed.value.array.items[1].object;
        try std.testing.expectEqualStrings("ship_carcase", child.get("prefab").?.string);
    }

    test "initial_state + name matching basename drops name, keeps directive" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"fitness_test\",\n" ++
            "    \"initial_state\": \"playing\",\n" ++
            "    \"children\": [\n" ++
            "        { \"prefab\": \"ship_carcase\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "fitness_test");
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        const header = parsed.value.array.items[0].object;
        const meta = header.get("meta").?.object;
        try std.testing.expectEqualStrings("playing", meta.get("initial_state").?.string);
        // name was redundant — must have been dropped by pass 7.
        try std.testing.expect(meta.get("name") == null);
    }

    test "initial_state + name differing from basename moves both to meta" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"Production Demo\",\n" ++
            "    \"initial_state\": \"playing\",\n" ++
            "    \"children\": [\n" ++
            "        { \"prefab\": \"ship_carcase\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "demo_scene");
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        const header = parsed.value.array.items[0].object;
        const meta = header.get("meta").?.object;
        try std.testing.expectEqualStrings("playing", meta.get("initial_state").?.string);
        try std.testing.expectEqualStrings("Production Demo", meta.get("name").?.string);
    }

    test "unknown lowercase key flows into meta" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // `tooltip` isn't an engine-known directive — but it's a
        // lowercase non-structural top-level key, so it has no home
        // post-bundle and must flow into `meta:`.
        const src =
            "{\n" ++
            "    \"tooltip\": \"hello\",\n" ++
            "    \"children\": [\n" ++
            "        { \"prefab\": \"x\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "demo");
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        const header = parsed.value.array.items[0].object;
        const meta = header.get("meta").?.object;
        try std.testing.expectEqualStrings("hello", meta.get("tooltip").?.string);
    }

    test "directive merges into existing meta block" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // Pre-existing meta + sibling directive: the two must merge
        // into a single meta object on the bundle header.
        const src =
            "{\n" ++
            "    \"meta\": { \"tooltip\": \"hello\" },\n" ++
            "    \"initial_state\": \"playing\",\n" ++
            "    \"children\": [\n" ++
            "        { \"prefab\": \"x\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "demo");
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        const header = parsed.value.array.items[0].object;
        const meta = header.get("meta").?.object;
        try std.testing.expectEqualStrings("hello", meta.get("tooltip").?.string);
        try std.testing.expectEqualStrings("playing", meta.get("initial_state").?.string);
    }

    test "directive merges into existing meta block with trailing comma" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // Pre-existing meta has a JSONC-legal trailing comma before `}`.
        // The merge must NOT emit a second comma — `, , "initial_state"`
        // is invalid JSON and would fail to round-trip.
        const src =
            "{\n" ++
            "    \"meta\": { \"tooltip\": \"hello\", },\n" ++
            "    \"initial_state\": \"playing\",\n" ++
            "    \"children\": [\n" ++
            "        { \"prefab\": \"x\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "demo");
        // Guard: the raw output must not contain a `,,` separator
        // inside the meta block.
        try std.testing.expect(std.mem.indexOf(u8, out, ",,") == null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        const header = parsed.value.array.items[0].object;
        const meta = header.get("meta").?.object;
        try std.testing.expectEqualStrings("hello", meta.get("tooltip").?.string);
        try std.testing.expectEqualStrings("playing", meta.get("initial_state").?.string);
    }

    test "directives only — no children — produces header-only bundle" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"initial_state\": \"playing\"\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "demo");
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
        const header = parsed.value.array.items[0].object;
        const meta = header.get("meta").?.object;
        try std.testing.expectEqualStrings("playing", meta.get("initial_state").?.string);
    }

    test "comments above directive line preserved across transform" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "// header file note\n" ++
            "{\n" ++
            "    // note about initial state\n" ++
            "    \"initial_state\": \"playing\",\n" ++
            "    \"children\": [\n" ++
            "        // entry note\n" ++
            "        { \"prefab\": \"x\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "demo");
        try std.testing.expect(std.mem.indexOf(u8, out, "// header file note") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "// entry note") != null);
        // Validate it round-trips as an array.
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
    }

    test "scripts directive flows into meta" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"scripts\": [\"a\", \"b\"],\n" ++
            "    \"children\": []\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "demo");
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        const header = parsed.value.array.items[0].object;
        const scripts = header.get("meta").?.object.get("scripts").?.array;
        try std.testing.expectEqual(@as(usize, 2), scripts.items.len);
    }

    test "PascalCase root key blocks directive migration" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // A single-root entity at file top-level with a sibling
        // directive — out of scope for this transform; leave alone.
        const src =
            "{\n" ++
            "    \"Workstation\": { \"kind\": \"kitchen\" },\n" ++
            "    \"initial_state\": \"playing\"\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "kitchen");
        // initial_state must remain — transform is gated out by
        // presence of PascalCase root key.
        try std.testing.expect(std.mem.indexOf(u8, out, "initial_state") != null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        // Still has top-level initial_state (NOT moved into meta).
        try std.testing.expect(parsed.value.object.get("initial_state") != null);
    }

    test "idempotent — already-migrated bundle is a no-op" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "[\n" ++
            "    { \"meta\": { \"initial_state\": \"playing\" } },\n" ++
            "    { \"prefab\": \"x\" }\n" ++
            "]\n";
        const once = try applyAllArenaFull(&arena, src, "demo");
        const twice = try applyAllArenaFull(&arena, once, "demo");
        try std.testing.expectEqualStrings(once, twice);
        // And running on this should be a no-op (no transformation).
        try std.testing.expectEqualStrings(src, once);
    }
};

// ─────────────────────────────────────────────────────────────────────
// RFC #596 — End-to-end + idempotency
// ─────────────────────────────────────────────────────────────────────

pub const Rfc596IdempotencySpec = struct {
    test "running migrator twice on a fully migrated file is a no-op" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // Already in the RFC-#596 final shape.
        const src =
            "[\n" ++
            "    { \"prefab\": \"a\", \"Position\": { \"x\": 1 } },\n" ++
            "    { \"prefab\": \"b\", \"Position\": { \"x\": 2 } }\n" ++
            "]\n";
        const once = try applyAllArenaFull(&arena, src, "main");
        const twice = try applyAllArenaFull(&arena, once, "main");
        try std.testing.expectEqualStrings(once, twice);
        // And running the legacy migrator on the same input is also a
        // no-op.
        try std.testing.expectEqualStrings(src, once);
    }

    test "running migrator twice on a legacy file lands at fixed point" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // Pre-#594 shape (root wrapper + entities + components-on-ref +
        // assets) PLUS post-#594 legacy patterns (overrides wrapper,
        // inline components wrapper, divergent name).
        const src =
            "{\n" ++
            "    \"name\": \"colony\",\n" ++
            "    \"assets\": [\"a\"],\n" ++
            "    \"root\": {\n" ++
            "        \"entities\": [\n" ++
            "            { \"prefab\": \"x\", \"components\": { \"Position\": { \"x\": 1 } } },\n" ++
            "            { \"components\": { \"BuildIntent\": { \"r\": 1 } } }\n" ++
            "        ]\n" ++
            "    }\n" ++
            "}\n";
        const once = try applyAllArenaFull(&arena, src, "colony");
        const twice = try applyAllArenaFull(&arena, once, "colony");
        try std.testing.expectEqualStrings(once, twice);
    }
};

pub const Rfc596MixedFileSpec = struct {
    test "all 8 transforms in one legacy file, end-to-end" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    // file-level note\n" ++
            "    \"name\": \"colony\",\n" ++
            "    \"assets\": [\"a\"],\n" ++
            "    \"root\": {\n" ++
            "        \"entities\": [\n" ++
            "            { \"prefab\": \"x\", \"components\": { \"Position\": { \"x\": 1 } } },\n" ++
            "            { \"components\": { \"BuildIntent\": { \"r\": 1 } } }\n" ++
            "        ]\n" ++
            "    }\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "colony");

        // Comment must survive every transform.
        try std.testing.expect(std.mem.indexOf(u8, out, "// file-level note") != null);

        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
        const first = parsed.value.array.items[0].object;
        try std.testing.expectEqualStrings("x", first.get("prefab").?.string);
        try std.testing.expect(first.get("Position") != null);
        try std.testing.expect(first.get("components") == null);
        try std.testing.expect(first.get("overrides") == null);
        const second = parsed.value.array.items[1].object;
        try std.testing.expect(second.get("BuildIntent") != null);
        try std.testing.expect(second.get("components") == null);
    }

    test "comments at every legal position survive end-to-end" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "// header\n" ++
            "{\n" ++
            "    // before name\n" ++
            "    \"name\": \"demo\",\n" ++
            "    // before children\n" ++
            "    \"children\": [\n" ++
            "        // before first entry\n" ++
            "        { \"prefab\": \"x\", \"overrides\": { /* inner */ \"Position\": { \"x\": 1 } } }\n" ++
            "        // after last entry\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "demo");
        try std.testing.expect(std.mem.indexOf(u8, out, "// header") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "// before first entry") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "// after last entry") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "/* inner */") != null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
    }
};

pub const PreScanXrefsSpec = struct {
    test "scanPrefabRefs dedups: N files referencing the same prefab yield ONE xref entry" {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var temp_arena = std.heap.ArenaAllocator.init(arena);
        defer temp_arena.deinit();

        var xrefs: std.StringHashMap(void) = .init(arena);

        // Five "files" all referencing the same prefab name "Hero". After
        // resetting the temp arena between each file, the xref name must
        // survive (duped into main arena) AND only one entry must exist
        // (dedup via xrefs.contains in collectPrefabRefsFromValue).
        const files = [_][]const u8{
            "[{ \"prefab\": \"Hero\" }]",
            "[{ \"prefab\": \"Hero\", \"overrides\": { \"Position\": { \"x\": 1 } } }]",
            "{ \"children\": [{ \"prefab\": \"Hero\" }] }",
            "[{ \"prefab\": \"Hero\" }, { \"prefab\": \"Hero\" }]", // intra-file dup too
            "[{ \"prefab\": \"Hero\" }]",
        };
        for (files) |raw| {
            try scanPrefabRefs(arena, temp_arena.allocator(), raw, &xrefs);
            _ = temp_arena.reset(.retain_capacity);
        }

        try std.testing.expectEqual(@as(u32, 1), xrefs.count());
        try std.testing.expect(xrefs.contains("Hero"));
    }

    test "scanPrefabRefs collects multiple distinct prefabs and dedups each" {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var temp_arena = std.heap.ArenaAllocator.init(arena);
        defer temp_arena.deinit();

        var xrefs: std.StringHashMap(void) = .init(arena);

        const files = [_][]const u8{
            "[{ \"prefab\": \"Hero\" }, { \"prefab\": \"Goblin\" }]",
            "[{ \"prefab\": \"Hero\" }]", // duplicate of Hero
            "[{ \"prefab\": \"Sword\" }]",
            "[{ \"prefab\": \"Goblin\" }]", // duplicate of Goblin
        };
        for (files) |raw| {
            try scanPrefabRefs(arena, temp_arena.allocator(), raw, &xrefs);
            _ = temp_arena.reset(.retain_capacity);
        }

        try std.testing.expectEqual(@as(u32, 3), xrefs.count());
        try std.testing.expect(xrefs.contains("Hero"));
        try std.testing.expect(xrefs.contains("Goblin"));
        try std.testing.expect(xrefs.contains("Sword"));
    }

    test "xref keys survive temp-arena reset (lifetime check)" {
        // Regression guard: if a future contributor accidentally dupes
        // the xref key into the temp arena instead of the main arena,
        // the key bytes will be invalidated by the reset and this test
        // will read garbage on the contains() lookup.
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var temp_arena = std.heap.ArenaAllocator.init(arena);
        defer temp_arena.deinit();

        var xrefs: std.StringHashMap(void) = .init(arena);

        // Use a long name so a stale pointer is less likely to land on
        // identical bytes by coincidence.
        try scanPrefabRefs(arena, temp_arena.allocator(), "[{ \"prefab\": \"VeryLongPrefabNameForLifetimeCheck\" }]", &xrefs);
        _ = temp_arena.reset(.retain_capacity);

        // Fill temp with unrelated bytes to clobber any released pages.
        const noise = try temp_arena.allocator().alloc(u8, 4096);
        @memset(noise, 0xAA);

        try std.testing.expectEqual(@as(u32, 1), xrefs.count());
        try std.testing.expect(xrefs.contains("VeryLongPrefabNameForLifetimeCheck"));
    }
};
