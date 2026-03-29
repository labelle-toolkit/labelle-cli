const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;
const generator = @import("generator");
const tpl = generator.template;

const a = std.testing.allocator;

test {
    zspec.runAll(@This());
}

// ── Helpers ───────────────────────────────────────────────────────────

fn render(template: []const u8, data: tpl.TemplateData) ![]const u8 {
    var buf = std.ArrayList(u8){};
    try tpl.renderDynamic(template, data, buf.writer(a));
    return buf.toOwnedSlice(a);
}

// ── Tests ─────────────────────────────────────────────────────────────

pub const SimpleVariableInterpolation = struct {
    test "replaces a single variable" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();
        try data.scalars.put("name", "Alice");

        const result = try render("Hello, {{name}}!", data);
        defer a.free(result);
        try std.testing.expectEqualStrings("Hello, Alice!", result);
    }

    test "replaces multiple variables" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();
        try data.scalars.put("first", "Jane");
        try data.scalars.put("last", "Doe");

        const result = try render("{{first}} {{last}}", data);
        defer a.free(result);
        try std.testing.expectEqualStrings("Jane Doe", result);
    }

    test "handles variables with spaces in braces" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();
        try data.scalars.put("x", "42");

        const result = try render("{{ x }}", data);
        defer a.free(result);
        try std.testing.expectEqualStrings("42", result);
    }
};

pub const MissingVariables = struct {
    test "missing variable outputs empty string" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();

        const result = try render("a{{missing}}b", data);
        defer a.free(result);
        try std.testing.expectEqualStrings("ab", result);
    }
};

pub const ConditionalBlocks = struct {
    test "truthy if renders body" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();
        try data.scalars.put("show", "yes");

        const result = try render("{{#if show}}visible{{/if}}", data);
        defer a.free(result);
        try std.testing.expectEqualStrings("visible", result);
    }

    test "falsy if skips body" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();

        const result = try render("{{#if show}}hidden{{/if}}", data);
        defer a.free(result);
        try std.testing.expectEqualStrings("", result);
    }

    test "empty string is falsy" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();
        try data.scalars.put("val", "");

        const result = try render("{{#if val}}yes{{/if}}", data);
        defer a.free(result);
        try std.testing.expectEqualStrings("", result);
    }

    test "else branch when falsy" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();

        const result = try render("{{#if x}}A{{#else}}B{{/if}}", data);
        defer a.free(result);
        try std.testing.expectEqualStrings("B", result);
    }

    test "else branch skipped when truthy" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();
        try data.scalars.put("x", "1");

        const result = try render("{{#if x}}A{{#else}}B{{/if}}", data);
        defer a.free(result);
        try std.testing.expectEqualStrings("A", result);
    }
};

pub const NestedIfBlocks = struct {
    test "nested if inside if" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();
        try data.scalars.put("a", "1");
        try data.scalars.put("b", "2");

        const result = try render("{{#if a}}A{{#if b}}B{{/if}}{{/if}}", data);
        defer a.free(result);
        try std.testing.expectEqualStrings("AB", result);
    }

    test "nested if falsy inner" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();
        try data.scalars.put("a", "1");

        const result = try render("{{#if a}}A{{#if b}}B{{/if}}C{{/if}}", data);
        defer a.free(result);
        try std.testing.expectEqualStrings("AC", result);
    }
};

pub const EachLoops = struct {
    test "iterates over list items" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();

        var item1: tpl.ListItem = .{ .fields = std.StringHashMap([]const u8).init(a) };
        defer item1.fields.deinit();
        try item1.fields.put("name", "Alice");

        var item2: tpl.ListItem = .{ .fields = std.StringHashMap([]const u8).init(a) };
        defer item2.fields.deinit();
        try item2.fields.put("name", "Bob");

        const items = try a.alloc(tpl.ListItem, 2);
        defer a.free(items);
        items[0] = item1;
        items[1] = item2;

        try data.lists.put("people", items);

        const result = try render("{{#each people}}[{{name}}]{{/each}}", data);
        defer a.free(result);
        try std.testing.expectEqualStrings("[Alice][Bob]", result);
    }

    test "empty list produces no output" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();

        const items = try a.alloc(tpl.ListItem, 0);
        defer a.free(items);
        try data.lists.put("things", items);

        const result = try render("{{#each things}}X{{/each}}", data);
        defer a.free(result);
        try std.testing.expectEqualStrings("", result);
    }

    test "missing list produces no output" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();

        const result = try render("{{#each nope}}X{{/each}}", data);
        defer a.free(result);
        try std.testing.expectEqualStrings("", result);
    }
};

pub const FallbackToParentScalars = struct {
    test "item fields checked first then parent scalars" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();
        try data.scalars.put("project", "labelle");

        var item1: tpl.ListItem = .{ .fields = std.StringHashMap([]const u8).init(a) };
        defer item1.fields.deinit();
        try item1.fields.put("file", "main.zig");

        const items = try a.alloc(tpl.ListItem, 1);
        defer a.free(items);
        items[0] = item1;
        try data.lists.put("files", items);

        const result = try render("{{#each files}}{{project}}/{{file}}{{/each}}", data);
        defer a.free(result);
        try std.testing.expectEqualStrings("labelle/main.zig", result);
    }

    test "item field shadows parent scalar" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();
        try data.scalars.put("name", "parent");

        var item1: tpl.ListItem = .{ .fields = std.StringHashMap([]const u8).init(a) };
        defer item1.fields.deinit();
        try item1.fields.put("name", "child");

        const items = try a.alloc(tpl.ListItem, 1);
        defer a.free(items);
        items[0] = item1;
        try data.lists.put("entries", items);

        const result = try render("{{#each entries}}{{name}}{{/each}}", data);
        defer a.free(result);
        try std.testing.expectEqualStrings("child", result);
    }
};

pub const NestedIfInsideEach = struct {
    test "if inside each checks item fields" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();

        var item1: tpl.ListItem = .{ .fields = std.StringHashMap([]const u8).init(a) };
        defer item1.fields.deinit();
        try item1.fields.put("name", "Alice");
        try item1.fields.put("admin", "true");

        var item2: tpl.ListItem = .{ .fields = std.StringHashMap([]const u8).init(a) };
        defer item2.fields.deinit();
        try item2.fields.put("name", "Bob");

        const items = try a.alloc(tpl.ListItem, 2);
        defer a.free(items);
        items[0] = item1;
        items[1] = item2;
        try data.lists.put("users", items);

        const result = try render(
            "{{#each users}}{{name}}{{#if admin}}*{{/if}} {{/each}}",
            data,
        );
        defer a.free(result);
        try std.testing.expectEqualStrings("Alice* Bob ", result);
    }

    test "if-else inside each" {
        var data: tpl.TemplateData = .{ .scalars = std.StringHashMap([]const u8).init(a), .lists = std.StringHashMap([]const tpl.ListItem).init(a) };
        defer data.scalars.deinit();
        defer data.lists.deinit();

        var item1: tpl.ListItem = .{ .fields = std.StringHashMap([]const u8).init(a) };
        defer item1.fields.deinit();
        try item1.fields.put("active", "yes");

        var item2: tpl.ListItem = .{ .fields = std.StringHashMap([]const u8).init(a) };
        defer item2.fields.deinit();

        const items = try a.alloc(tpl.ListItem, 2);
        defer a.free(items);
        items[0] = item1;
        items[1] = item2;
        try data.lists.put("rows", items);

        const result = try render(
            "{{#each rows}}{{#if active}}ON{{#else}}OFF{{/if}}\n{{/each}}",
            data,
        );
        defer a.free(result);
        try std.testing.expectEqualStrings("ON\nOFF\n", result);
    }
};
