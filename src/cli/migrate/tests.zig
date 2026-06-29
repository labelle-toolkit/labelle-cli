// ─────────────────────────────────────────────────────────────────────
// Tests — legacy transforms 1-4 (pre-RFC-#596) spec namespaces
// ─────────────────────────────────────────────────────────────────────
//
// Moved verbatim from migrate.zig. Spec namespaces are surfaced to the
// cli test runner via re-exports in migrate.zig.

const std = @import("std");
const scanner = @import("scanner.zig");
const helpers = @import("tests_helpers.zig");

const expect = @import("zspec").expect;

const stripJsoncToJson = scanner.stripJsoncToJson;
const applyAllArena = helpers.applyAllArena;

pub const TransformRootWrapperSpec = struct {
    pub const lifts_simple_wrapper = struct {
        test "lifts `\"root\": { \"children\": [] }` and de-indents" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"root\": {\n" ++
                "        \"children\": []\n" ++
                "    }\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            const expected =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"children\": []\n" ++
                "}\n";
            try std.testing.expectEqualStrings(expected, out);
        }
    };

    pub const preserves_comments = struct {
        test "comments on lifted children survive" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    // top-level note stays put\n" ++
                "    \"root\": {\n" ++
                "        // inner note moves up one indent\n" ++
                "        \"children\": [\n" ++
                "            { \"prefab\": \"x\" } // inline note\n" ++
                "        ]\n" ++
                "    }\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            // The three comments must all still appear, verbatim.
            try std.testing.expect(std.mem.indexOf(u8, out, "// top-level note stays put") != null);
            try std.testing.expect(std.mem.indexOf(u8, out, "// inner note moves up one indent") != null);
            try std.testing.expect(std.mem.indexOf(u8, out, "// inline note") != null);
            // And the `"root"` wrapper is gone.
            try std.testing.expect(std.mem.indexOf(u8, out, "\"root\"") == null);
        }
    };

    pub const root_in_middle_of_metadata = struct {
        // Regression for cursor[bot] finding: when `"root"` is not the
        // LAST top-level key (i.e. has a trailing comma) the lift used to
        // consume the comma but never re-emit it, producing invalid JSON
        // like `..."children": []"metadata": "x"...`.
        test "root in middle of metadata keys produces valid JSON" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"root\": {\n" ++
                "        \"children\": []\n" ++
                "    },\n" ++
                "    \"metadata\": \"x\"\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            // Must round-trip through the JSON parser.
            const stripped = try stripJsoncToJson(arena.allocator(), out);
            var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            try std.testing.expect(obj.get("root") == null);
            try std.testing.expect(obj.get("children") != null);
            try std.testing.expectEqualStrings("main", obj.get("name").?.string);
            try std.testing.expectEqualStrings("x", obj.get("metadata").?.string);
        }

        test "root in middle with trailing comma on its own line" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"root\": {\n" ++
                "        \"children\": []\n" ++
                "    }\n" ++
                "    ,\n" ++
                "    \"metadata\": \"x\"\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            const stripped = try stripJsoncToJson(arena.allocator(), out);
            var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            try std.testing.expect(obj.get("root") == null);
            try std.testing.expect(obj.get("children") != null);
            try std.testing.expectEqualStrings("x", obj.get("metadata").?.string);
        }

        // Adversarial: root not last, a `//` line comment between two
        // outer-level keys, and a `/* */` block comment elsewhere. The
        // whole file must round-trip through the JSON parser after the
        // lift.
        test "root in middle with mixed line + block comments around" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    // line note between name and root\n" ++
                "    \"root\": {\n" ++
                "        /* inside-root block note */\n" ++
                "        \"children\": []\n" ++
                "    },\n" ++
                "    \"metadata\": \"x\"\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            const stripped = try stripJsoncToJson(arena.allocator(), out);
            var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            try std.testing.expect(obj.get("root") == null);
            try std.testing.expect(obj.get("children") != null);
            try std.testing.expectEqualStrings("main", obj.get("name").?.string);
            try std.testing.expectEqualStrings("x", obj.get("metadata").?.string);
        }

        test "root in middle with line comment between `}` and next key" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"root\": {\n" ++
                "        \"children\": []\n" ++
                "    }, // close root\n" ++
                "    \"metadata\": \"x\"\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            const stripped = try stripJsoncToJson(arena.allocator(), out);
            var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            try std.testing.expect(obj.get("root") == null);
            try std.testing.expect(obj.get("children") != null);
            try std.testing.expectEqualStrings("x", obj.get("metadata").?.string);
        }
    };
};

pub const DeleteTopLevelKeyBlockCommentSpec = struct {
    // Regression for cursor[bot] finding: the backward walk that looks
    // for the preceding comma when the target key is the LAST entry used
    // to land one byte too late after skipping a `/* ... */` block. The
    // outer `p -= 1` from the for-loop then put `p` on the `/` of `/*`,
    // which broke the walk early and left the preceding sibling with a
    // dangling `,` — producing invalid JSON.
    test "deletes last key preceded by a block comment" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    /* trailing note */\n" ++
            "    \"assets\": [\"a\"]\n" ++
            "}\n";
        const out = try applyAllArena(&arena, src);
        // Pre-fix the backward walk lost the preceding `,` because it
        // landed on the `/` of `/*` and broke. The trailing comma after
        // `"main"` MUST be removed — otherwise the raw .jsonc parses as
        // {"name":"main",} which is illegal JSON (the JSONC-stripper
        // happens to forgive trailing commas, but a strict reader does
        // not).
        try std.testing.expect(std.mem.indexOf(u8, out, "\"assets\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"main\",") == null);
        // And it must round-trip through the JSON parser too.
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("main", parsed.value.object.get("name").?.string);
    }

    // Regression for cursor[bot] finding: the backward walk that looks
    // for the preceding comma when the target key is the LAST entry
    // claims (per its doc) to skip "whitespace + comments", but only
    // handled `/* ... */` block comments — never `//` line comments. A
    // `//` comment sitting on its own line between the preceding comma
    // and the deleted key made the walk hit the comment text and break
    // before finding the comma — leaving a dangling trailing comma on
    // the preceding sibling and producing invalid strict JSON.
    test "deletes last key preceded by a `//` line comment" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    // trailing note\n" ++
            "    \"assets\": [\"a\"]\n" ++
            "}\n";
        const out = try applyAllArena(&arena, src);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"assets\"") == null);
        // Trailing comma on `"main"` must be gone.
        try std.testing.expect(std.mem.indexOf(u8, out, "\"main\",") == null);
        // Round-trip through the JSON parser to be safe.
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("main", parsed.value.object.get("name").?.string);
    }

    // Adversarial: both kinds of comments interleaved before the
    // deleted last-key.
    test "deletes last key preceded by mixed `//` and `/* */` comments" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    // line note\n" ++
            "    /* block note */\n" ++
            "    \"assets\": [\"a\"]\n" ++
            "}\n";
        const out = try applyAllArena(&arena, src);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"assets\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"main\",") == null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("main", parsed.value.object.get("name").?.string);
    }
};

pub const TransformEntitiesRenameSpec = struct {
    test "top-level `entities` becomes `children`" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    \"entities\": [\n" ++
            "        { \"prefab\": \"x\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArena(&arena, src);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"children\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"entities\"") == null);
    }
};

pub const TransformComponentsOnRefSpec = struct {
    pub const renames_when_prefab_sibling = struct {
        test "`components` next to `prefab` becomes `overrides`" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"children\": [\n" ++
                "        { \"prefab\": \"x\", \"components\": { \"Position\": { \"x\": 1 } } }\n" ++
                "    ]\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\"") != null);
            // No more `"components"` key (the value's nested keys
            // happen not to use the word, so a substring search is OK).
            try std.testing.expect(std.mem.indexOf(u8, out, "\"components\"") == null);
        }
    };

    pub const leaves_inline_components_alone = struct {
        test "inline `components` without `prefab` is the canonical shape and stays" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"children\": [\n" ++
                "        { \"components\": { \"Position\": { \"x\": 1 } } }\n" ++
                "    ]\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"components\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\"") == null);
        }
    };
};

pub const TransformAssetsDeleteSpec = struct {
    pub const deletes_with_trailing_comma = struct {
        test "drops `\"assets\": [...]` line entirely" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"assets\": [\"a\", \"b\"],\n" ++
                "    \"children\": []\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"assets\"") == null);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"children\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"name\"") != null);
        }
    };

    pub const deletes_when_last_key = struct {
        test "drops preceding comma when `assets` is the last entry" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"assets\": [\"a\"]\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            // Must still parse as valid JSON (no dangling comma).
            const stripped = try stripJsoncToJson(arena.allocator(), out);
            var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
            defer parsed.deinit();
            try std.testing.expect(parsed.value.object.get("assets") == null);
            try std.testing.expectEqualStrings("main", parsed.value.object.get("name").?.string);
        }
    };
};

pub const IdempotencySpec = struct {
    test "running the migrator twice produces the same bytes" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    \"assets\": [\"a\"],\n" ++
            "    \"root\": {\n" ++
            "        \"children\": [\n" ++
            "            { \"prefab\": \"x\", \"components\": { \"Position\": { \"x\": 1 } } }\n" ++
            "        ]\n" ++
            "    }\n" ++
            "}\n";
        const once = try applyAllArena(&arena, src);
        const twice = try applyAllArena(&arena, once);
        try std.testing.expectEqualStrings(once, twice);
    }
};

pub const MixedFileSpec = struct {
    test "all four transforms in one file" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    \"assets\": [\"a\"],\n" ++
            "    \"root\": {\n" ++
            "        \"entities\": [\n" ++
            "            { \"prefab\": \"x\", \"components\": { \"Position\": { \"x\": 1 } } }\n" ++
            "        ]\n" ++
            "    }\n" ++
            "}\n";
        const out = try applyAllArena(&arena, src);

        // Must parse + have the expected post-migration shape.
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expect(obj.get("assets") == null);
        try std.testing.expect(obj.get("root") == null);
        try std.testing.expect(obj.get("entities") == null);
        try std.testing.expect(obj.get("children") != null);
        const child0 = obj.get("children").?.array.items[0].object;
        try std.testing.expect(child0.get("components") == null);
        try std.testing.expect(child0.get("overrides") != null);
    }
};
