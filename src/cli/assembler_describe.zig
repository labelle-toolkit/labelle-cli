//! `labelle-assembler describe` from the CLI side (RFC cli#471 D3).
//!
//! The CLI used to re-derive a project's backend/target facts from its own
//! mirror of the assembler's enums, and the two drifted (cli#471 finding 4):
//! a third-party `.backend_package = .{ .name = "acme" }` project with no
//! `.backend` generates into `.labelle/acme_desktop`, while the CLI named
//! the dir after its default backend tag. From protocol 7 the assembler
//! answers the question itself:
//!
//!   labelle-assembler describe --project-root <P> --target <T> --json
//!
//! which prints one `labelle.describe/v1` document (target dir, resolved
//! backend package, asset format, whether the backend supports the target
//! and why not). It is offline and config-only: nothing is fetched,
//! written or generated.
//!
//! Everything here is optional. Below protocol 7, or when `describe` cannot
//! be run or its output cannot be read, `query` returns null and the caller
//! keeps its enum-derived answer (one debug line, no user-facing noise).
//! Removing that fallback is cli#471 P3.
const std = @import("std");
const config = @import("config.zig");
const assembler_proc = @import("assembler_proc.zig");

/// The first assembler protocol that ships `describe`.
pub const min_protocol: u32 = 7;

/// The only document shape this CLI reads. A different tag is a shape it
/// does not know, and reads as "no answer" (the fallback).
pub const schema = "labelle.describe/v1";

/// One `labelle.describe/v1` document. Unknown fields are ignored so a
/// newer assembler can add keys without breaking this CLI. `asset_format`
/// and `capabilities_source` stay strings: the CLI mirrors no enum of the
/// assembler's here.
pub const Description = struct {
    schema: []const u8,
    /// The target name as asked.
    target: []const u8,
    /// `.labelle/<backend name>_<target>`, relative to the project root.
    target_dir: []const u8,
    backend: Backend,
    /// The backend package's directory, present only once it is installed.
    package_dir: ?[]const u8 = null,
    asset_format: []const u8,
    supported: bool,
    /// Why `supported` is false; absent when supported.
    reason: ?[]const u8 = null,
    capabilities_source: ?[]const u8 = null,

    pub const Backend = struct {
        /// The package name the assembler resolved (its `backendName()`).
        name: []const u8,
        id: ?[]const u8 = null,
        repo: ?[]const u8 = null,
        version: ?[]const u8 = null,
        local_path: ?[]const u8 = null,
    };

    /// The generated target dir's name (without `.labelle/`), or null when
    /// `target_dir` is not exactly `.labelle/<one path component>` — a
    /// shape the CLI will not join under the project root.
    pub fn targetDirName(self: Description) ?[]const u8 {
        const prefix = ".labelle/";
        if (!std.mem.startsWith(u8, self.target_dir, prefix)) return null;
        const name = self.target_dir[prefix.len..];
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return null;
        if (std.mem.indexOfAny(u8, name, "/\\") != null) return null;
        return name;
    }
};

pub const ParseError = error{UnknownSchema} || std.json.ParseError(std.json.Scanner);

/// Parse a `describe --json` document. Every string is owned by `arena`.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) ParseError!Description {
    const d = try std.json.parseFromSliceLeaky(Description, arena, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    if (!std.mem.eql(u8, d.schema, schema)) return error.UnknownSchema;
    return d;
}

/// Runs `describe` and returns its stdout when it exited 0, else null.
/// A seam so the fallback path is tested without an assembler binary.
pub const SpawnFn = *const fn (arena: std.mem.Allocator, argv: []const []const u8) ?[]const u8;

fn spawnDescribe(arena: std.mem.Allocator, argv: []const []const u8) ?[]const u8 {
    const res = std.process.run(arena, config.globalIo(), .{ .argv = argv }) catch return null;
    if (res.term != .exited or res.term.exited != 0) return null;
    return res.stdout;
}

/// How the pipeline asks `describe`: the resolved assembler and the project
/// it answers for. `off` (protocol 0) never spawns and always falls back.
pub const Describer = struct {
    bin_path: []const u8 = "",
    protocol: u32 = 0,
    project_dir: []const u8 = "",
    spawn: SpawnFn = spawnDescribe,

    pub const off: Describer = .{};

    pub fn init(bin: assembler_proc.Assembler, project_dir: []const u8) Describer {
        return .{ .bin_path = bin.path, .protocol = bin.protocol, .project_dir = project_dir };
    }

    /// The assembler's answer for `target`, or null for the fallback: the
    /// protocol predates `describe`, the spawn failed or exited nonzero, the
    /// output is not a `labelle.describe/v1` document, or it answers for a
    /// different target. Strings are owned by `arena`.
    pub fn query(self: Describer, arena: std.mem.Allocator, target: []const u8) ?Description {
        if (self.protocol < min_protocol) return null;
        const argv = [_][]const u8{ self.bin_path, "describe", "--project-root", self.project_dir, "--target", target, "--json" };
        const out = self.spawn(arena, &argv) orelse {
            std.log.debug("assembler describe unavailable; using the CLI's own backend/target facts", .{});
            return null;
        };
        const d = parse(arena, out) catch |err| {
            std.log.debug("assembler describe output unreadable ({s}); using the CLI's own backend/target facts", .{@errorName(err)});
            return null;
        };
        if (!std.mem.eql(u8, d.target, target)) return null;
        return d;
    }
};

/// The generated target dir's name: describe's when it gave a usable one,
/// else the enum-derived `<fallback_backend>_<target>` of pre-D3 CLIs.
/// Caller owns the result.
pub fn targetDirName(allocator: std.mem.Allocator, described: ?Description, fallback_backend: []const u8, target: []const u8) ![]u8 {
    if (described) |d| if (d.targetDirName()) |name| return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}_{s}", .{ fallback_backend, target });
}

/// The backend name for status lines: the package describe resolved, else
/// the CLI's enum tag.
pub fn backendLabel(described: ?Description, fallback_backend: []const u8) []const u8 {
    return if (described) |d| d.backend.name else fallback_backend;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// The exact shape `labelle-assembler describe --json` (v0.119.0,
/// `describe.writeJson`) prints for a third-party package that is not
/// installed: `backend`'s five keys always present, `package_dir` and
/// `reason` omitted.
const fixture_third_party =
    \\{
    \\  "schema": "labelle.describe/v1",
    \\  "target": "desktop",
    \\  "target_dir": ".labelle/acme_desktop",
    \\  "backend": {
    \\    "name": "acme",
    \\    "id": null,
    \\    "repo": "github.com/acme/labelle-acme",
    \\    "version": "1.2.0",
    \\    "local_path": null
    \\  },
    \\  "asset_format": "png",
    \\  "supported": true,
    \\  "capabilities_source": "unknown"
    \\}
    \\
;

/// An installed package that refuses the target, plus a key a newer
/// assembler might add.
const fixture_unsupported =
    \\{
    \\  "schema": "labelle.describe/v1",
    \\  "target": "probe",
    \\  "target_dir": ".labelle/acme_probe",
    \\  "backend": {
    \\    "name": "acme",
    \\    "id": "acme.gfx",
    \\    "repo": "local:vendor/acme",
    \\    "version": "0.1.0",
    \\    "local_path": "/proj/vendor/acme"
    \\  },
    \\  "package_dir": "/proj/vendor/acme",
    \\  "asset_format": "astc",
    \\  "supported": false,
    \\  "reason": "provider 'acme.gfx' does not support capability 'probe'",
    \\  "capabilities_source": "manifest",
    \\  "added_by_a_newer_assembler": { "x": [1, 2] }
    \\}
;

test "parse: a third-party package document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const d = try parse(arena.allocator(), fixture_third_party);
    try testing.expectEqualStrings("desktop", d.target);
    try testing.expectEqualStrings(".labelle/acme_desktop", d.target_dir);
    try testing.expectEqualStrings("acme", d.backend.name);
    try testing.expect(d.backend.id == null);
    try testing.expectEqualStrings("github.com/acme/labelle-acme", d.backend.repo.?);
    try testing.expectEqualStrings("1.2.0", d.backend.version.?);
    try testing.expect(d.backend.local_path == null);
    try testing.expect(d.package_dir == null);
    try testing.expectEqualStrings("png", d.asset_format);
    try testing.expect(d.supported);
    try testing.expect(d.reason == null);
    try testing.expectEqualStrings("unknown", d.capabilities_source.?);
    try testing.expectEqualStrings("acme_desktop", d.targetDirName().?);
}

test "parse: unsupported with a reason, unknown keys ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const d = try parse(arena.allocator(), fixture_unsupported);
    try testing.expect(!d.supported);
    try testing.expectEqualStrings("provider 'acme.gfx' does not support capability 'probe'", d.reason.?);
    try testing.expectEqualStrings("/proj/vendor/acme", d.package_dir.?);
    try testing.expectEqualStrings("acme.gfx", d.backend.id.?);
    try testing.expectEqualStrings("astc", d.asset_format);
}

test "parse: a different schema tag or malformed output is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v2 = try std.mem.replaceOwned(u8, a, fixture_third_party, "labelle.describe/v1", "labelle.describe/v2");
    try testing.expectError(error.UnknownSchema, parse(a, v2));
    try testing.expect(std.meta.isError(parse(a, "not json")));
    try testing.expect(std.meta.isError(parse(a, "{\"schema\": \"labelle.describe/v1\"}")));
}

test "Description.targetDirName: only .labelle/<one component> is accepted" {
    var d = std.mem.zeroInit(Description, .{ .target_dir = ".labelle/acme_desktop" });
    try testing.expectEqualStrings("acme_desktop", d.targetDirName().?);
    for ([_][]const u8{ "acme_desktop", ".labelle/", ".labelle/..", ".labelle/a/b", ".labelle/a\\b", "/abs/.labelle/x", "../.labelle/x" }) |bad| {
        d.target_dir = bad;
        try testing.expect(d.targetDirName() == null);
    }
}

const Fake = struct {
    var calls: usize = 0;
    var last_argv: [7][]const u8 = undefined;
    var reply: ?[]const u8 = null;

    fn spawn(arena: std.mem.Allocator, argv: []const []const u8) ?[]const u8 {
        _ = arena;
        calls += 1;
        for (argv, 0..) |arg, i| last_argv[i] = arg;
        return reply;
    }

    fn reset(r: ?[]const u8) void {
        calls = 0;
        reply = r;
    }
};

test "Describer.query: protocol 7 asks describe with the documented flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    Fake.reset(fixture_third_party);
    const describer: Describer = .{ .bin_path = "/asm", .protocol = 7, .project_dir = "/proj", .spawn = Fake.spawn };
    const d = describer.query(arena.allocator(), "desktop").?;
    try testing.expectEqualStrings("acme", d.backend.name);
    try testing.expectEqual(@as(usize, 1), Fake.calls);
    const want = [_][]const u8{ "/asm", "describe", "--project-root", "/proj", "--target", "desktop", "--json" };
    for (want, Fake.last_argv) |w, got| try testing.expectEqualStrings(w, got);
}

test "Describer.query: falls back (null) without describe or a usable answer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Protocol below 7 (and `off`): never spawns.
    Fake.reset(fixture_third_party);
    try testing.expect((Describer{ .protocol = 6, .spawn = Fake.spawn }).query(a, "desktop") == null);
    try testing.expect((Describer{ .spawn = Fake.spawn }).query(a, "desktop") == null);
    try testing.expectEqual(@as(usize, 0), Fake.calls);
    // Spawn failed / nonzero exit, unreadable output, another target.
    const on: Describer = .{ .protocol = 7, .spawn = Fake.spawn };
    for ([_]?[]const u8{ null, "usage: labelle-assembler ..." }) |reply| {
        Fake.reset(reply);
        try testing.expect(on.query(a, "desktop") == null);
        try testing.expectEqual(@as(usize, 1), Fake.calls);
    }
    Fake.reset(fixture_third_party);
    try testing.expect(on.query(a, "probe") == null);
    try testing.expectEqual(@as(usize, 1), Fake.calls);
}

test "targetDirName: describe wins; the enum tag is the fallback (cli#471 finding 4)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parse(a, fixture_third_party);
    // A third-party `acme` package with no `.backend`: the CLI's enum says
    // its default tag, the assembler generates into `acme_desktop`.
    try testing.expectEqualStrings("acme_desktop", try targetDirName(a, d, "enum-default", "desktop"));
    try testing.expectEqualStrings("acme", backendLabel(d, "enum-default"));
    // No answer: the pre-D3 name.
    try testing.expectEqualStrings("enum-default_desktop", try targetDirName(a, null, "enum-default", "desktop"));
    try testing.expectEqualStrings("enum-default", backendLabel(null, "enum-default"));
    // An unusable target_dir falls back too.
    var odd = d;
    odd.target_dir = "elsewhere/acme_desktop";
    try testing.expectEqualStrings("enum-default_desktop", try targetDirName(a, odd, "enum-default", "desktop"));
}
