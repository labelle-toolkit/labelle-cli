//! The recorded `resolve` preview: its file, digest and registry binding,
//! and the check that an `--accept` still matches what was reviewed.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const registry = @import("../provider_registry.zig");
const pin_mod = @import("pin.zig");
const Pin = pin_mod.Pin;
const lock_name = pin_mod.lock_name;
const parse = pin_mod.parse;
const files = @import("files.zig");
const read = files.read;
const writeAtomically = files.writeAtomically;
const sha256Hex = files.sha256Hex;
const AcceptFixture = @import("test_fixtures.zig").AcceptFixture;

/// Project-local record of the last `resolve` preview. `--accept` refuses to
/// pin anything that differs from it (Codex P1 on #414: a registry repointed
/// between preview and accept must not cross the consent boundary).
pub const preview_name = ".labelle/providers.preview.json";

/// One previewed pin: every field the user was shown, including the derived
/// archive URL and, for a schema-2 registry, the record's ownership claims
/// (`null`/`[]` under schema 1, which claims nothing), so a later accept can
/// be checked against exactly that.
pub const PreviewEntry = struct {
    package: []const u8,
    repo: []const u8,
    version: []const u8,
    commit: []const u8,
    sha256: []const u8,
    archive_url: []const u8,
    namespace: ?[]const u8,
    targets: []const []const u8,

    fn fromPin(a: std.mem.Allocator, doc: registry.Registry, pin: Pin) !PreviewEntry {
        const record = doc.find(pin.package, pin.version);
        return .{
            .package = pin.package,
            .repo = pin.repo,
            .version = pin.version,
            .commit = pin.commit,
            .sha256 = pin.sha256,
            .archive_url = try pin.archiveUrl(a),
            .namespace = if (record) |r| r.namespace else null,
            .targets = if (record) |r| r.targets else &.{},
        };
    }

    pub fn toPin(self: PreviewEntry) Pin {
        return .{ .package = self.package, .repo = self.repo, .version = self.version, .commit = self.commit, .sha256 = self.sha256 };
    }
};

/// The preview file's own format. 2 added the registry binding (#433); an
/// older file is unreadable, which only asks for a new review.
pub const preview_schema: u8 = 2;

/// Persisted by a preview, consumed (and removed) by a successful accept.
/// It binds the WHOLE registry document, not only the selected pins (#433):
/// `registry_digest` is the SHA-256 of `Registry.normalised`, so a schema
/// swap, a changed claim or default, or a changed unselected record between
/// preview and accept is a mismatch. `registry_schema`, `defaults` and each
/// entry's claims repeat parts of that document so a mismatch can name the
/// field; the digest is the catch-all for everything else.
pub const Preview = struct {
    schema_version: u8,
    source: []const u8,
    registry_schema: u8,
    registry_digest: []const u8,
    defaults: []const registry.DefaultRef,
    digest: []const u8,
    providers: []const PreviewEntry,

    /// Everything the preview digest covers: the record minus the digest.
    fn body(self: Preview) PreviewBody {
        return .{ .source = self.source, .registry_schema = self.registry_schema, .registry_digest = self.registry_digest, .defaults = self.defaults, .providers = self.providers };
    }
};

const PreviewBody = struct {
    source: []const u8,
    registry_schema: u8,
    registry_digest: []const u8,
    defaults: []const registry.DefaultRef,
    providers: []const PreviewEntry,
};

/// SHA-256 over the canonical JSON of the registry source, the registry
/// binding and every shown field. Recomputed on load, so an edited preview
/// file is caught too.
fn previewDigest(a: std.mem.Allocator, body: PreviewBody) ![]const u8 {
    return sha256Hex(a, try std.json.Stringify.valueAlloc(a, body, .{}));
}

/// The preview record for `pins` selected from `doc` (read from `source`).
fn previewOf(a: std.mem.Allocator, source: []const u8, doc: registry.Registry, pins: []const Pin) !Preview {
    const entries = try a.alloc(PreviewEntry, pins.len);
    for (pins, 0..) |pin, i| entries[i] = try PreviewEntry.fromPin(a, doc, pin);
    var preview: Preview = .{
        .schema_version = preview_schema,
        .source = source,
        .registry_schema = doc.schema_version,
        .registry_digest = try sha256Hex(a, try doc.normalised(a)),
        .defaults = doc.defaults,
        .digest = "",
        .providers = entries,
    };
    preview.digest = try previewDigest(a, preview.body());
    return preview;
}

pub fn writePreview(a: std.mem.Allocator, root: []const u8, source: []const u8, doc: registry.Registry, pins: []const Pin) !Preview {
    const preview = try previewOf(a, source, doc, pins);
    const dest = try std.fs.path.join(a, &.{ root, preview_name });
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), std.fs.path.dirname(dest).?);
    try writeAtomically(a, dest, try std.json.Stringify.valueAlloc(a, preview, .{ .whitespace = .indent_2 }));
    return preview;
}

/// Missing, unparseable, or digest-mismatched previews all fail closed: accept
/// never falls back to a fresh registry fetch.
pub fn loadPreview(a: std.mem.Allocator, root: []const u8) !Preview {
    const path = try std.fs.path.join(a, &.{ root, preview_name });
    const bytes = read(a, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("labelle: no provider preview at {s}; run 'labelle providers resolve' first and review the pins before --accept\n", .{preview_name});
            return error.ProviderPreviewMissing;
        },
        else => return err,
    };
    const parsed = std.json.parseFromSlice(Preview, a, bytes, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("labelle: provider preview {s} is unreadable ({s}); run 'labelle providers resolve' again\n", .{ preview_name, @errorName(err) });
        return error.ProviderPreviewCorrupt;
    };
    const preview = parsed.value;
    if (preview.schema_version != preview_schema) {
        std.debug.print("labelle: provider preview {s} has format {d}, this CLI writes {d}; run 'labelle providers resolve' again\n", .{ preview_name, preview.schema_version, preview_schema });
        return error.ProviderPreviewCorrupt;
    }
    for (preview.providers) |entry| {
        const pin = entry.toPin();
        pin.validate() catch return error.ProviderPreviewCorrupt;
        if (!std.mem.eql(u8, entry.archive_url, try pin.archiveUrl(a))) return error.ProviderPreviewCorrupt;
    }
    if (!std.mem.eql(u8, preview.digest, try previewDigest(a, preview.body()))) {
        std.debug.print("labelle: provider preview {s} does not match its digest; run 'labelle providers resolve' again\n", .{preview_name});
        return error.ProviderPreviewCorrupt;
    }
    return preview;
}

fn reportChange(package: []const u8, field: []const u8, previewed: []const u8, now: []const u8) void {
    std.debug.print("labelle: provider '{s}' {s} changed since preview: {s} -> {s}\n", .{ package, field, previewed, now });
}

pub fn jsonText(a: std.mem.Allocator, value: anytype) []const u8 {
    return std.json.Stringify.valueAlloc(a, value, .{}) catch "<unprintable>";
}

/// Every field the user reviewed, and the whole registry document it came
/// from, must equal what the registry serves now. Any difference names the
/// field (and package) and aborts the accept.
pub fn checkPreview(a: std.mem.Allocator, preview: Preview, source: []const u8, doc: registry.Registry, pins: []const Pin) !void {
    var changed = false;
    if (!std.mem.eql(u8, preview.source, source)) {
        std.debug.print("labelle: registry source changed since preview: {s} -> {s}\n", .{ preview.source, source });
        changed = true;
    }
    const now = try previewOf(a, source, doc, pins);
    if (preview.registry_schema != now.registry_schema) {
        std.debug.print("labelle: registry schema_version changed since preview: {d} -> {d}\n", .{ preview.registry_schema, now.registry_schema });
        changed = true;
    }
    if (!std.mem.eql(u8, jsonText(a, preview.defaults), jsonText(a, now.defaults))) {
        std.debug.print("labelle: registry defaults changed since preview: {s} -> {s}\n", .{ jsonText(a, preview.defaults), jsonText(a, now.defaults) });
        changed = true;
    }
    const fresh = now.providers;
    for (preview.providers) |old| {
        var found = false;
        for (fresh) |new| {
            if (!std.mem.eql(u8, old.package, new.package)) continue;
            found = true;
            inline for (.{ "repo", "version", "commit", "sha256", "archive_url" }) |field| {
                if (!std.mem.eql(u8, @field(old, field), @field(new, field))) {
                    reportChange(old.package, field, @field(old, field), @field(new, field));
                    changed = true;
                }
            }
            inline for (.{ "namespace", "targets" }) |field| {
                const was = jsonText(a, @field(old, field));
                const is = jsonText(a, @field(new, field));
                if (!std.mem.eql(u8, was, is)) {
                    reportChange(old.package, field, was, is);
                    changed = true;
                }
            }
        }
        if (!found) {
            std.debug.print("labelle: provider '{s}' was previewed but is no longer selected\n", .{old.package});
            changed = true;
        }
    }
    for (fresh) |new| {
        var found = false;
        for (preview.providers) |old| found = found or std.mem.eql(u8, old.package, new.package);
        if (!found) {
            std.debug.print("labelle: provider '{s}' is selected now but was not previewed\n", .{new.package});
            changed = true;
        }
    }
    // The catch-all: nothing shown above differs, yet the document does, so
    // an unselected release record changed (it could otherwise reach the
    // cached ownership table the accept writes for target diagnostics).
    if (!changed and !std.mem.eql(u8, preview.registry_digest, now.registry_digest)) {
        std.debug.print("labelle: registry document changed since preview outside the selected releases (an unselected release record): sha256 {s} -> {s}\n", .{ preview.registry_digest, now.registry_digest });
        changed = true;
    }
    if (changed) {
        std.debug.print("labelle: refusing --accept: the registry no longer matches the reviewed preview. Run 'labelle providers resolve' again and review the new pins.\n", .{});
        return error.ProviderPreviewMismatch;
    }
}

/// Test-only fault: makes `removePreview` fail as an unwritable `.labelle`
/// would, so the post-commit path can be exercised on every host.
var fail_preview_removal_for_test = false;

pub fn removePreview(a: std.mem.Allocator, root: []const u8) !void {
    if (builtin.is_test and fail_preview_removal_for_test) return error.AccessDenied;
    std.Io.Dir.cwd().deleteFile(config.globalIo(), try std.fs.path.join(a, &.{ root, preview_name })) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

test "provider github: accept is bound to the recorded preview" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    // (c) Nothing reviewed yet: accept fails closed before touching the registry or the lock.
    try std.testing.expectError(error.ProviderPreviewMissing, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    // Preview records exactly what was shown, with a digest that verifies on load.
    try fx.run(a, false);
    try std.testing.expect(try fx.exists(a, preview_name));
    try std.testing.expect(!try fx.exists(a, lock_name));
    const preview = try loadPreview(a, fx.root);
    try std.testing.expectEqual(@as(usize, 1), preview.providers.len);
    try std.testing.expectEqualStrings(fx.pin.commit, preview.providers[0].commit);
    try std.testing.expectEqualStrings(fx.pin.sha256, preview.providers[0].sha256);
    try std.testing.expectEqualStrings(try fx.pin.archiveUrl(a), preview.providers[0].archive_url);
    try std.testing.expectEqualStrings(fx.registry, preview.source);
    try std.testing.expectEqualStrings(try previewDigest(a, preview.body()), preview.digest);
    // (b) The registry is repointed between preview and accept: the changed
    // field is rejected by name, the lock is never written, and the stale
    // preview stays so the diagnostic can be compared against it.
    var repointed = fx.pin;
    repointed.commit = "2" ** 40;
    try fx.publish(a, repointed);
    try std.testing.expectError(error.ProviderPreviewMismatch, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    var rehashed = fx.pin;
    rehashed.sha256 = "0" ** 64;
    try fx.publish(a, rehashed);
    try std.testing.expectError(error.ProviderPreviewMismatch, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    try std.testing.expect(try fx.exists(a, preview_name));
    // (a) The registry serves the reviewed record again: accept pins it,
    // verifying the archive against the previewed hash, and consumes the preview.
    try fx.publish(a, fx.pin);
    try fx.run(a, true);
    const lock = try parse(a, try read(a, try std.fs.path.join(a, &.{ fx.root, lock_name }), 1024 * 1024), true);
    try std.testing.expectEqual(@as(usize, 1), lock.providers.len);
    try std.testing.expectEqualStrings(fx.pin.commit, lock.providers[0].commit);
    try std.testing.expectEqualStrings(fx.pin.sha256, lock.providers[0].sha256);
    try std.testing.expect(!try fx.exists(a, preview_name));
    // A consumed preview cannot be accepted twice.
    try std.testing.expectError(error.ProviderPreviewMissing, fx.run(a, true));
}

test "provider github: accept stays committed when the consumed preview cannot be removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    const lock_path = try std.fs.path.join(a, &.{ fx.root, lock_name });
    const old_lock = "{\"schema_version\":1,\"providers\":[]}";
    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = lock_path, .data = old_lock });
    try fx.run(a, false);
    fail_preview_removal_for_test = true;
    defer fail_preview_removal_for_test = false;
    // The delete fails after the lock rename: the accept still succeeds, and
    // the lock on disk is the new one, so exit status and lock state agree.
    try fx.run(a, true);
    const lock = try parse(a, try read(a, lock_path, 1024 * 1024), true);
    try std.testing.expectEqual(@as(usize, 1), lock.providers.len);
    try std.testing.expectEqualStrings(fx.pin.sha256, lock.providers[0].sha256);
    // The fault really ran: the preview the accept could not consume is still there.
    try std.testing.expect(try fx.exists(a, preview_name));
    // Mechanism check: with the fault lifted the same path removes it.
    fail_preview_removal_for_test = false;
    try fx.run(a, true);
    try std.testing.expect(!try fx.exists(a, preview_name));
}

test "provider github: an edited preview file fails its digest and is not accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    try fx.run(a, false);
    const path = try std.fs.path.join(a, &.{ fx.root, preview_name });
    const original = try read(a, path, 1024 * 1024);
    // Same shape, one hex digit of the reviewed commit changed: the digest no longer verifies.
    const edited = try std.mem.replaceOwned(u8, a, original, fx.pin.commit, "2" ** 40);
    try std.testing.expect(!std.mem.eql(u8, original, edited));
    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = path, .data = edited });
    try std.testing.expectError(error.ProviderPreviewCorrupt, loadPreview(a, fx.root));
    try std.testing.expectError(error.ProviderPreviewCorrupt, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = path, .data = "{ not json" });
    try std.testing.expectError(error.ProviderPreviewCorrupt, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
}
