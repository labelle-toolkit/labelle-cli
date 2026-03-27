const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;
const generator = @import("generator");
const deps_linker = generator.deps_linker;
const DepEntry = deps_linker.DepEntry;

test {
    zspec.runAll(@This());
}

// Regression test for memory leak (issue #78).
// DepEntry string fields were not freed — only the slice itself was freed.
// std.testing.allocator (GPA) will fail the test if any allocation leaks.
pub const FreeDepEntries = struct {
    test "frees all string fields and the slice (regression #78)" {
        const alloc = std.testing.allocator;

        var deps_list = std.ArrayList(DepEntry){};
        try deps_list.append(alloc, .{
            .zon_name = try alloc.dupe(u8, "labelle_core"),
            .link_name = try alloc.dupe(u8, "labelle-core"),
            .abs_path = try alloc.dupe(u8, "/tmp/core"),
        });
        try deps_list.append(alloc, .{
            .zon_name = try alloc.dupe(u8, "labelle_sokol"),
            .link_name = try alloc.dupe(u8, "labelle-sokol"),
            .abs_path = try alloc.dupe(u8, "/tmp/sokol"),
        });
        try deps_list.append(alloc, .{
            .zon_name = try alloc.dupe(u8, "labelle_gui"),
            .link_name = try alloc.dupe(u8, "labelle-gui"),
            .abs_path = try alloc.dupe(u8, "/tmp/gui"),
        });

        const deps = try deps_list.toOwnedSlice(alloc);
        // This must free zon_name, link_name, abs_path for each entry + the slice
        deps_linker.freeDepEntries(alloc, deps);
        // If anything leaks, std.testing.allocator will fail this test
    }
};
