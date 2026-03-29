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
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);
        try data.scalars.put(a, "name", "Alice");

        const result = try render("Hello, {{name}}!", data);
        defer a.free(result);
        try expect.equalStrings("Hello, Alice!", result);
    }

    test "replaces multiple variables" {
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);
        try data.scalars.put(a, "first", "Jane");
        try data.scalars.put(a, "last", "Doe");

        const result = try render("{{first}} {{last}}", data);
        defer a.free(result);
        try expect.equalStrings("Jane Doe", result);
    }

    test "handles variables with spaces in braces" {
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);
        try data.scalars.put(a, "x", "42");

        const result = try render("{{ x }}", data);
        defer a.free(result);
        try expect.equalStrings("42", result);
    }
};

pub const MissingVariables = struct {
    test "missing variable outputs empty string" {
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);

        const result = try render("a{{missing}}b", data);
        defer a.free(result);
        try expect.equalStrings("ab", result);
    }
};

pub const ConditionalBlocks = struct {
    test "truthy if renders body" {
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);
        try data.scalars.put(a, "show", "yes");

        const result = try render("{{#if show}}visible{{/if}}", data);
        defer a.free(result);
        try expect.equalStrings("visible", result);
    }

    test "falsy if skips body" {
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);

        const result = try render("{{#if show}}hidden{{/if}}", data);
        defer a.free(result);
        try expect.equalStrings("", result);
    }

    test "empty string is falsy" {
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);
        try data.scalars.put(a, "val", "");

        const result = try render("{{#if val}}yes{{/if}}", data);
        defer a.free(result);
        try expect.equalStrings("", result);
    }

    test "else branch when falsy" {
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);

        const result = try render("{{#if x}}A{{#else}}B{{/if}}", data);
        defer a.free(result);
        try expect.equalStrings("B", result);
    }

    test "else branch skipped when truthy" {
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);
        try data.scalars.put(a, "x", "1");

        const result = try render("{{#if x}}A{{#else}}B{{/if}}", data);
        defer a.free(result);
        try expect.equalStrings("A", result);
    }
};

pub const NestedIfBlocks = struct {
    test "nested if inside if" {
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);
        try data.scalars.put(a, "a", "1");
        try data.scalars.put(a, "b", "2");

        const result = try render("{{#if a}}A{{#if b}}B{{/if}}{{/if}}", data);
        defer a.free(result);
        try expect.equalStrings("AB", result);
    }

    test "nested if falsy inner" {
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);
        try data.scalars.put(a, "a", "1");

        const result = try render("{{#if a}}A{{#if b}}B{{/if}}C{{/if}}", data);
        defer a.free(result);
        try expect.equalStrings("AC", result);
    }
};

pub const EachLoops = struct {
    test "iterates over list items" {
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);

        var item1: tpl.ListItem = .{ .fields = .{} };
        defer item1.fields.deinit(a);
        try item1.fields.put(a, "name", "Alice");

        var item2: tpl.ListItem = .{ .fields = .{} };
        defer item2.fields.deinit(a);
        try item2.fields.put(a, "name", "Bob");

        const items = try a.alloc(tpl.ListItem, 2);
        defer a.free(items);
        items[0] = item1;
        items[1] = item2;

        try data.lists.put(a, "people", items);

        const result = try render("{{#each people}}[{{name}}]{{/each}}", data);
        defer a.free(result);
        try expect.equalStrings("[Alice][Bob]", result);
    }

    test "empty list produces no output" {
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);

        const items = try a.alloc(tpl.ListItem, 0);
        defer a.free(items);
        try data.lists.put(a, "things", items);

        const result = try render("{{#each things}}X{{/each}}", data);
        defer a.free(result);
        try expect.equalStrings("", result);
    }

    test "missing list produces no output" {
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);

        const result = try render("{{#each nope}}X{{/each}}", data);
        defer a.free(result);
        try expect.equalStrings("", result);
    }
};

pub const FallbackToParentScalars = struct {
    test "item fields checked first then parent scalars" {
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);
        try data.scalars.put(a, "project", "labelle");

        var item1: tpl.ListItem = .{ .fields = .{} };
        defer item1.fields.deinit(a);
        try item1.fields.put(a, "file", "main.zig");

        const items = try a.alloc(tpl.ListItem, 1);
        defer a.free(items);
        items[0] = item1;
        try data.lists.put(a, "files", items);

        const result = try render("{{#each files}}{{project}}/{{file}}{{/each}}", data);
        defer a.free(result);
        try expect.equalStrings("labelle/main.zig", result);
    }

    test "item field shadows parent scalar" {
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);
        try data.scalars.put(a, "name", "parent");

        var item1: tpl.ListItem = .{ .fields = .{} };
        defer item1.fields.deinit(a);
        try item1.fields.put(a, "name", "child");

        const items = try a.alloc(tpl.ListItem, 1);
        defer a.free(items);
        items[0] = item1;
        try data.lists.put(a, "entries", items);

        const result = try render("{{#each entries}}{{name}}{{/each}}", data);
        defer a.free(result);
        try expect.equalStrings("child", result);
    }
};

pub const NestedIfInsideEach = struct {
    test "if inside each checks item fields" {
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);

        var item1: tpl.ListItem = .{ .fields = .{} };
        defer item1.fields.deinit(a);
        try item1.fields.put(a, "name", "Alice");
        try item1.fields.put(a, "admin", "true");

        var item2: tpl.ListItem = .{ .fields = .{} };
        defer item2.fields.deinit(a);
        try item2.fields.put(a, "name", "Bob");

        const items = try a.alloc(tpl.ListItem, 2);
        defer a.free(items);
        items[0] = item1;
        items[1] = item2;
        try data.lists.put(a, "users", items);

        const result = try render(
            "{{#each users}}{{name}}{{#if admin}}*{{/if}} {{/each}}",
            data,
        );
        defer a.free(result);
        try expect.equalStrings("Alice* Bob ", result);
    }

    test "if-else inside each" {
        var data: tpl.TemplateData = .{ .scalars = .{}, .lists = .{} };
        defer data.scalars.deinit(a);
        defer data.lists.deinit(a);

        var item1: tpl.ListItem = .{ .fields = .{} };
        defer item1.fields.deinit(a);
        try item1.fields.put(a, "active", "yes");

        var item2: tpl.ListItem = .{ .fields = .{} };
        defer item2.fields.deinit(a);

        const items = try a.alloc(tpl.ListItem, 2);
        defer a.free(items);
        items[0] = item1;
        items[1] = item2;
        try data.lists.put(a, "rows", items);

        const result = try render(
            "{{#each rows}}{{#if active}}ON{{#else}}OFF{{/if}}\n{{/each}}",
            data,
        );
        defer a.free(result);
        try expect.equalStrings("ON\nOFF\n", result);
    }
};
