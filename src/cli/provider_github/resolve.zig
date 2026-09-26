//! `labelle providers resolve` and `--accept`: select the declared releases,
//! record the preview, and on accept verify sources and write the lock.
const std = @import("std");
const config = @import("../config.zig");
const manifest = @import("../provider_manifest.zig");
const contract = @import("../provider_contract.zig");
const util = @import("../util.zig");
const dispatch = @import("../provider_dispatch.zig");
const hooks = @import("../provider_hooks.zig");
const registry = @import("../provider_registry.zig");
const pin_mod = @import("pin.zig");
const Pin = pin_mod.Pin;
const Document = pin_mod.Document;
const lock_name = pin_mod.lock_name;
const parse = pin_mod.parse;
const files = @import("files.zig");
const read = files.read;
const writeAtomically = files.writeAtomically;
const sha256Hex = files.sha256Hex;
const Sources = @import("sources.zig").Sources;
const preview_mod = @import("preview.zig");
const Preview = preview_mod.Preview;
const preview_name = preview_mod.preview_name;
const loadPreview = preview_mod.loadPreview;
const writePreview = preview_mod.writePreview;
const checkPreview = preview_mod.checkPreview;
const jsonText = preview_mod.jsonText;
const removePreview = preview_mod.removePreview;
const registry_cache = @import("registry_cache.zig");
const cacheRegistry = registry_cache.cacheRegistry;
const cachedRegistryOwner = registry_cache.cachedRegistryOwner;
const registry_cache_dir = registry_cache.registry_cache_dir;
const registry_cache_file = registry_cache.registry_cache_file;
const AcceptFixture = @import("test_fixtures.zig").AcceptFixture;

pub const registry_url = "https://raw.githubusercontent.com/labelle-toolkit/labelle-registry/main/providers.json";

/// Resolve only explicitly declared project versions. Preview is read-only
/// apart from recording what was shown in `preview_name`; --accept re-fetches
/// metadata, requires it to equal that record, verifies sources, and runs no
/// package code.
pub fn resolve(a: std.mem.Allocator, root: []const u8, source: []const u8, accept: bool, offline: bool, reserved: []const []const u8) !void {
    // Fail closed before any network or archive work when nothing was reviewed.
    const preview: ?Preview = if (accept) try loadPreview(a, root) else null;
    var metadata: []const u8 = undefined;
    if (std.mem.startsWith(u8, source, "https://raw.githubusercontent.com/")) {
        if (offline) return error.OfflineRegistryNeedsLocalFile;
        // stdout capture is bounded; curl cannot execute the returned document.
        const result = try util.runCmd(a, &.{ "curl", "--fail", "--silent", "--show-error", "--proto", "=https", "--connect-timeout", "30", "--max-time", "60", "--max-filesize", "1048576", source });
        if (result.term != .exited or result.term.exited != 0) return error.ProviderRegistryDownloadFailed;
        metadata = result.stdout;
    } else {
        if (std.mem.indexOf(u8, source, "://") != null) return error.InvalidProviderRegistrySource;
        metadata = try read(a, source, 1024 * 1024);
    }
    const doc = try registry.parse(a, metadata);
    const cfg = try config.readProjectConfigQuiet(a, root);
    var selected: std.ArrayList(Pin) = .empty;
    for (cfg.plugins, 0..) |dep, i| {
        for (cfg.plugins[0..i]) |prev| if (std.mem.eql(u8, dep.name, prev.name)) return error.DuplicateProjectPlugin;
        if (dep.isLocal()) continue;
        var known = false;
        var found = false;
        for (doc.pins) |pin| {
            if (!std.mem.eql(u8, pin.package, dep.name)) continue;
            known = true;
            if (!pin.matches(dep)) continue;
            try selected.append(a, pin);
            found = true;
            std.debug.print("  {s} {s}: {s}@{s}\n    sha256 {s}\n    {s}\n", .{ pin.package, pin.version, pin.repo, pin.commit, pin.sha256, try pin.archiveUrl(a) });
            if (doc.find(pin.package, pin.version)) |record| {
                std.debug.print("    namespace {s}, targets {s}\n", .{ jsonText(a, record.namespace), jsonText(a, record.targets) });
            }
        }
        if (known and !found) return error.ProviderReleaseNotInRegistry;
    }
    if (!accept) {
        const shown = try writePreview(a, root, source, doc, selected.items);
        if (doc.claimsOwnership()) std.debug.print("  registry defaults {s}\n", .{jsonText(a, doc.defaults)});
        std.debug.print("  registry schema {d}, normalised document sha256 {s}\n", .{ shown.registry_schema, shown.registry_digest });
        std.debug.print("Preview: {d} provider pin(s), digest {s}, recorded in {s}.\nRepeat with --accept to verify archives and write {s}; accept refuses any pin, claim, default or other registry record that differs from this preview.\n", .{ selected.items.len, shown.digest, preview_name, lock_name });
        return;
    }
    // Acceptance is bound to the reviewed record: the fresh fetch may only
    // confirm it (the whole normalised document, not just the selected
    // pins), and the pins prepared below are the previewed ones.
    try checkPreview(a, preview.?, source, doc, selected.items);
    // What the target-hint cache will hold after the commit: the normalised
    // form of the document just bound to the preview, so its bytes hash to
    // the reviewed `registry_digest`. `checkPreview` already refused any
    // other document; the re-check keeps that true if it ever changes.
    const reviewed = try doc.normalised(a);
    if (!std.mem.eql(u8, try sha256Hex(a, reviewed), preview.?.registry_digest)) return error.ProviderPreviewMismatch;
    selected.clearRetainingCapacity();
    for (preview.?.providers) |entry| try selected.append(a, entry.toPin());
    std.debug.print("Accepting preview digest {s}.\n", .{preview.?.digest});
    var sources: Sources = .{ .a = a };
    defer sources.deinit();
    var ownership: std.ArrayList(contract.Ownership) = .empty;
    // The accepted set as `discover` would see it, so the hook graph is
    // validated across remote AND local providers before any pin is written
    // (Codex P2 on #420): an accept that wrote a lock for a graph with a
    // missing reference, a phase-order violation, duplicate replacements or
    // a cycle only moved the failure to the project's next help/build.
    var providers: std.ArrayList(dispatch.Provider) = .empty;
    for (selected.items) |pin| {
        const dir = try sources.fromPin(pin, !offline);
        const meta = try manifest.parse(a, try read(a, try std.fs.path.join(a, &.{ dir, "plugin.labelle" }), 1024 * 1024));
        // A schema-2 registry's ownership claims for this release must be
        // what its verified manifest declares, before anything is pinned.
        try doc.checkDeclarations(pin, meta);
        const ns = try a.alloc([]const u8, if (meta.namespace != null) 1 else 0);
        if (meta.namespace) |value| ns[0] = value;
        try ownership.append(a, .{ .package = pin.package, .namespaces = ns, .targets = meta.targets });
        for (cfg.plugins) |dep| {
            if (std.mem.eql(u8, dep.name, pin.package)) try providers.append(a, .{ .dep = dep, .dir = dir, .meta = meta, .verified = true });
        }
    }
    // Include local owners before changing pins, even though they need no archive.
    for (cfg.plugins) |dep| {
        if (!dep.isLocal()) continue;
        const dir = try std.fs.path.resolve(a, &.{ root, dep.localPath() });
        const path = try std.fs.path.join(a, &.{ dir, "plugin.labelle" });
        const bytes = read(a, path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const meta = try manifest.parse(a, bytes);
        if (!meta.isProvider()) continue;
        if (!std.mem.eql(u8, dep.name, meta.name)) return error.ProviderNameMismatch;
        const ns = try a.alloc([]const u8, if (meta.namespace != null) 1 else 0);
        if (meta.namespace) |value| ns[0] = value;
        try ownership.append(a, .{ .package = dep.name, .namespaces = ns, .targets = meta.targets });
        try providers.append(a, .{ .dep = dep, .dir = dir, .meta = meta, .verified = true });
    }
    try contract.validateOwnership(ownership.items, reserved);
    try hooks.validateAll(a, providers.items, &.{});
    const dest = try std.fs.path.join(a, &.{ root, lock_name });
    try writeAtomically(a, dest, try std.json.Stringify.valueAlloc(a, Document{ .schema_version = 1, .providers = selected.items }, .{ .whitespace = .indent_2 }));
    // The lock rename above is the commit point: from here on the accept has
    // succeeded, so nothing below may turn it into a failed exit (a failed
    // accept promises the old lock). The preview is consumed so a second
    // --accept needs a new review; if it cannot be removed, say so and keep
    // the exit status in agreement with the lock on disk (#418).
    std.debug.print("Pinned {d} provider(s) in {s}. Commit this file with labelle.lock.\n", .{ selected.items.len, lock_name });
    removePreview(a, root) catch |err| {
        std.debug.print("labelle: warning: the new pins are committed, but the consumed preview {s} could not be removed ({s}); delete it by hand before the next review\n", .{ preview_name, @errorName(err) });
    };
    // The accepted document is kept as the hint source of the no-provider
    // diagnostic (a preview stays read-only): `reviewed`, never this run's
    // raw fetch. Best effort: a failed cache write changes nothing about the pins.
    cacheRegistry(a, reviewed) catch |err| {
        std.debug.print("labelle: warning: could not cache the registry document: {s}\n", .{@errorName(err)});
    };
}

test "provider github: accept is bound to the whole registry document, not only the selected pins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    const fixture_record = try std.fmt.allocPrint(a, "{{\"package\":\"fixture\",\"repo\":\"{s}\",\"version\":\"{s}\",\"commit\":\"{s}\",\"sha256\":\"{s}\",\"namespace\":\"probe\",\"targets\":[]}}", .{ fx.pin.repo, fx.pin.version, fx.pin.commit, fx.pin.sha256 });
    const other_record = "{\"package\":\"other\",\"repo\":\"example/other\",\"version\":\"1.0.0\",\"commit\":\"" ++ "3" ** 40 ++ "\",\"sha256\":\"" ++ "0" ** 64 ++ "\",\"namespace\":null,\"targets\":[\"TARGET\"]}";
    const Doc = struct {
        fn of(al: std.mem.Allocator, fixture: []const u8, other_target: []const u8, defaults: []const u8, sep: []const u8) ![]const u8 {
            const other = try std.mem.replaceOwned(u8, al, other_record, "TARGET", other_target);
            return std.fmt.allocPrint(al, "{{\"schema_version\":2,{s}\"defaults\":[{s}],{s}\"providers\":[{s},{s}{s}]}}", .{ sep, defaults, sep, fixture, sep, other });
        }
    };
    // (1) Schema 2 swapped for an otherwise identical schema 1: same pins,
    // but the declaration check would become a no-op. Rejected.
    try fx.publishSchemaTwo(a, "\"probe\"", "");
    try fx.run(a, false);
    try fx.publish(a, fx.pin);
    try std.testing.expectError(error.ProviderPreviewMismatch, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    // (2) A selected record's ownership claim changes. Mechanism: the
    // reviewed claim (`null`) is false and the served one is true, so the
    // declaration check alone would pin it; only the preview binding refuses.
    try fx.publishSchemaTwo(a, "null", "");
    try fx.run(a, false);
    try fx.publishSchemaTwo(a, "\"probe\"", "");
    try std.testing.expectError(error.ProviderPreviewMismatch, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    // (3) An unselected record's claim changes: only the document digest sees it.
    try fx.publishRaw(try Doc.of(a, fixture_record, "other-target", "", ""));
    try fx.run(a, false);
    try fx.publishRaw(try Doc.of(a, fixture_record, "moved-target", "", ""));
    try std.testing.expectError(error.ProviderPreviewMismatch, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    // (4) The defaults list changes.
    try fx.publishRaw(try Doc.of(a, fixture_record, "other-target", "", ""));
    try fx.run(a, false);
    try fx.publishRaw(try Doc.of(a, fixture_record, "other-target", "{\"package\":\"fixture\",\"version\":\"1.0.0\"}", ""));
    try std.testing.expectError(error.ProviderPreviewMismatch, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    // (5) The same document with other whitespace is the same normalised
    // document: accepted. The target-hint cache then holds exactly the
    // reviewed document (its bytes hash to the preview's registry digest).
    try fx.publishRaw(try Doc.of(a, fixture_record, "other-target", "", ""));
    try fx.run(a, false);
    const reviewed = try loadPreview(a, fx.root);
    try std.testing.expectEqual(@as(u8, 2), reviewed.registry_schema);
    try std.testing.expectEqualStrings("probe", reviewed.providers[0].namespace.?);
    try fx.publishRaw(try Doc.of(a, fixture_record, "other-target", "", "\n  "));
    try fx.run(a, true);
    try std.testing.expect(try fx.exists(a, lock_name));
    const cached = try read(a, try std.fs.path.join(a, &.{ fx.home, registry_cache_dir, registry_cache_file }), 1024 * 1024);
    try std.testing.expectEqualStrings(reviewed.registry_digest, try sha256Hex(a, cached));
    try std.testing.expectEqualStrings("other", cachedRegistryOwner(a, "other-target").?);
}

test "provider github: accept refuses a schema-2 record whose claims the verified manifest contradicts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    // The fixture manifest declares namespace `probe` and no target; the
    // record claims a target it does not declare. The archive verifies, so
    // only the claim check can refuse it, and it does before the lock exists.
    try fx.publishSchemaTwo(a, "\"probe\"", "\"probe-target\"");
    try fx.run(a, false);
    try std.testing.expectError(error.RegistryDeclarationMismatch, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    try fx.publishSchemaTwo(a, "null", "");
    try fx.run(a, false);
    try std.testing.expectError(error.RegistryDeclarationMismatch, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    // Truthful claims pin, and the accepted schema-2 document is the hint source.
    try fx.publishSchemaTwo(a, "\"probe\"", "");
    try fx.run(a, false);
    try fx.run(a, true);
    const lock = try parse(a, try read(a, try std.fs.path.join(a, &.{ fx.root, lock_name }), 1024 * 1024), true);
    try std.testing.expectEqual(@as(usize, 1), lock.providers.len);
    try std.testing.expectEqual(@as(u8, 1), lock.schema_version);
}
