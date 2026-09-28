//! `labelle doctor --json` (RFC cli#466 D7): the capability objects the
//! pinned providers' doctors print, validated and aggregated into the core's
//! one document.
//!
//! Each provider doctor runs with `--json` and its stdout is captured, never
//! passed through: the core owns stdout and prints exactly one document,
//! `{"capabilities":[...]}`. A provider prints ONE capability object,
//!
//!     {"id":..., "required":bool, "ok":bool, "items":[{"id", "name", "ok",
//!      "fixable", "size_mb", "action", "detail", "hint"}, ...]}
//!
//! the same shape as the core's own capabilities (labelle-studio's
//! ToolchainGate schema). Unknown keys are ignored; a missing key, a wrong
//! type, an empty id, or anything but one object is invalid.
//!
//! Nothing here names a capability: every id comes from provider data.
//!
//! - A provider capability replaces a core capability with the same id: the
//!   provider owns what it reports.
//! - Two or more providers reporting one id become a single failed entry
//!   with that id whose item names every one of them. Neither report is
//!   trusted.
//! - A provider doctor that failed to run, exited with invalid output, or
//!   was never run (an unavailable or unverified package) becomes a failed
//!   capability whose id is the provider's label (its namespace, or its
//!   package name) and whose item carries the error. A WARN (a package not
//!   installed yet) is `required: false`. Nothing a provider prints can make
//!   the command crash.
//! - A doctor that exits non-zero with a valid object keeps it, marked
//!   `ok: false`; if the object claimed `ok: true`, an item records the exit.
const std = @import("std");
const provider_doctor = @import("provider_doctor.zig");

pub const Item = struct {
    id: []const u8,
    name: []const u8,
    ok: bool,
    fixable: bool,
    size_mb: u32,
    action: ?[]const u8,
    detail: ?[]const u8,
    hint: ?[]const u8,
};

pub const Capability = struct {
    id: []const u8,
    required: bool,
    ok: bool,
    items: []const Item,
};

pub const Document = struct {
    capabilities: []const Capability,
};

/// The item id of every entry the core writes about a provider (a failure,
/// a duplicate id, a non-zero exit).
pub const error_item_id = "provider-doctor";

pub const Validated = union(enum) {
    capability: Capability,
    /// Why the output is not a capability object.
    invalid: []const u8,
};

/// Validate one provider doctor's captured stdout as a capability object.
pub fn validate(a: std.mem.Allocator, stdout: []const u8) !Validated {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0) return .{ .invalid = "it printed nothing on stdout" };
    const cap = std.json.parseFromSliceLeaky(Capability, a, trimmed, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| return .{ .invalid = try std.fmt.allocPrint(a, "its stdout is not one capability object ({s})", .{@errorName(err)}) };
    if (cap.id.len == 0) return .{ .invalid = "its capability id is empty" };
    for (cap.items, 0..) |item, i| {
        if (item.id.len == 0) return .{ .invalid = try std.fmt.allocPrint(a, "item {d} of capability '{s}' has an empty id", .{ i, cap.id }) };
    }
    return .{ .capability = cap };
}

/// Who reported an outcome: the package, or the label for an entry with no
/// package (provider discovery, the provider_config mapping).
fn owner(outcome: provider_doctor.Outcome) []const u8 {
    return if (outcome.package.len != 0) outcome.package else outcome.label;
}

fn subject(a: std.mem.Allocator, outcome: provider_doctor.Outcome) ![]const u8 {
    if (outcome.package.len == 0) return outcome.label;
    return std.fmt.allocPrint(a, "labelle {s} {s} (provider '{s}')", .{ outcome.label, provider_doctor.command_name, outcome.package });
}

fn errorItem(name: []const u8, detail: []const u8, hint: ?[]const u8) Item {
    return .{ .id = error_item_id, .name = name, .ok = false, .fixable = false, .size_mb = 0, .action = null, .detail = detail, .hint = hint };
}

fn hintFor(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ProviderArchiveMissing, error.ProviderArchiveHashMismatch => "run `labelle providers fetch` to download the pinned archives",
        error.StaleProviderIntegrityPin, error.RemoteProviderIntegrityRequired => "run `labelle providers resolve`, review the pins, then repeat with --accept",
        error.PackageNotInstalled => "run `labelle install`",
        else => null,
    };
}

/// The capability one provider outcome contributes (see the module doc).
pub fn fromOutcome(a: std.mem.Allocator, outcome: provider_doctor.Outcome) !Capability {
    const name = try subject(a, outcome);
    if (outcome.code) |code| {
        switch (try validate(a, outcome.stdout orelse "")) {
            .capability => |cap| {
                if (code == 0) return cap;
                var failed = cap;
                failed.ok = false;
                if (cap.ok) {
                    const note = errorItem(name, try std.fmt.allocPrint(a, "exited {d} although its report says ok", .{code}), null);
                    failed.items = try std.mem.concat(a, Item, &.{ cap.items, &.{note} });
                }
                return failed;
            },
            .invalid => |why| {
                const detail = try std.fmt.allocPrint(a, "exited {d}, and {s}", .{ code, why });
                return .{ .id = outcome.label, .required = true, .ok = false, .items = try a.dupe(Item, &.{errorItem(name, detail, null)}) };
            },
        }
    }
    const err = outcome.err orelse error.ProviderDoctorDidNotRun;
    const detail = try std.fmt.allocPrint(a, "did not run: {s}", .{@errorName(err)});
    return .{ .id = outcome.label, .required = !outcome.warning, .ok = false, .items = try a.dupe(Item, &.{errorItem(name, detail, hintFor(err))}) };
}

fn indexOf(caps: []const Capability, id: []const u8) ?usize {
    for (caps, 0..) |cap, i| if (std.mem.eql(u8, cap.id, id)) return i;
    return null;
}

/// The core's capabilities and the providers' outcomes, as the one list
/// `labelle doctor --json` prints: the core capabilities no provider
/// reports, in order, then one entry per provider capability id, in report
/// order (a duplicated id at its first position).
pub fn aggregate(a: std.mem.Allocator, core: []const Capability, report: ?provider_doctor.Report) ![]const Capability {
    const outcomes: []const provider_doctor.Outcome = if (report) |r| r.outcomes else &.{};
    const provided = try a.alloc(Capability, outcomes.len);
    for (outcomes, provided) |outcome, *cap| cap.* = try fromOutcome(a, outcome);

    var out: std.ArrayList(Capability) = .empty;
    for (core) |cap| {
        if (indexOf(provided, cap.id) == null) try out.append(a, cap);
    }
    for (provided, 0..) |cap, i| {
        if (indexOf(provided[0..i], cap.id) != null) continue;
        var owners: std.ArrayList([]const u8) = .empty;
        for (provided[i..], outcomes[i..]) |other, outcome| {
            if (std.mem.eql(u8, other.id, cap.id)) try owners.append(a, owner(outcome));
        }
        if (owners.items.len == 1) {
            try out.append(a, cap);
            continue;
        }
        var names: std.ArrayList(u8) = .empty;
        for (owners.items, 0..) |name, n| {
            const sep: []const u8 = if (n == 0) "" else if (n + 1 == owners.items.len) " and " else ", ";
            try names.print(a, "{s}'{s}'", .{ sep, name });
        }
        const detail = try std.fmt.allocPrint(a, "capability '{s}' is reported by providers {s}; a capability id must have one owner", .{ cap.id, names.items });
        try out.append(a, .{
            .id = cap.id,
            .required = true,
            .ok = false,
            .items = try a.dupe(Item, &.{errorItem("duplicate capability id", detail, "remove one of these providers, or have one of them report a different capability id")}),
        });
    }
    return out.items;
}

/// Print `caps` as the one document: a single compact line and a newline.
pub fn write(w: *std.Io.Writer, caps: []const Capability) !void {
    try std.json.Stringify.value(Document{ .capabilities = caps }, .{}, w);
    try w.writeByte('\n');
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn fakeOutcome(label: []const u8, package: []const u8, code: ?u8, stdout: ?[]const u8) provider_doctor.Outcome {
    return .{ .label = label, .package = package, .code = code, .stdout = stdout };
}

const core_caps = [_]Capability{
    .{ .id = "core-a", .required = true, .ok = true, .items = &.{} },
    .{ .id = "shared", .required = true, .ok = false, .items = &.{} },
};

test "provider doctor json: a valid object is kept, an invalid one becomes a failed capability" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const valid =
        \\{"id":"cap-x","required":true,"ok":true,"extra":1,"items":[{"id":"tool","name":"Tool","ok":true,"fixable":false,"size_mb":0,"action":null,"detail":"d","hint":null}]}
    ;
    const report: provider_doctor.Report = .{ .outcomes = &.{
        fakeOutcome("xns", "x-pkg", 0, valid ++ "\n"),
        fakeOutcome("bad", "bad-pkg", 0, "{not json"),
        fakeOutcome("empty", "empty-pkg", 0, ""),
        fakeOutcome("typed", "typed-pkg", 0, "{\"id\":\"t\",\"required\":\"yes\",\"ok\":true,\"items\":[]}"),
        fakeOutcome("two", "two-pkg", 0, "{\"id\":\"t2\",\"required\":true,\"ok\":true,\"items\":[]}\n{\"id\":\"t3\",\"required\":true,\"ok\":true,\"items\":[]}"),
        fakeOutcome("noid", "noid-pkg", 0, "{\"id\":\"\",\"required\":true,\"ok\":true,\"items\":[]}"),
    } };
    const caps = try aggregate(a, &core_caps, report);
    try testing.expectEqual(@as(usize, 2 + 6), caps.len);
    try testing.expectEqualStrings("core-a", caps[0].id);
    try testing.expectEqualStrings("shared", caps[1].id);
    try testing.expectEqualStrings("cap-x", caps[2].id);
    try testing.expect(caps[2].ok);
    try testing.expectEqualStrings("d", caps[2].items[0].detail.?);
    // Every invalid output is a failed capability under the provider's label,
    // carrying why.
    for (caps[3..], [_][]const u8{ "bad", "empty", "typed", "two", "noid" }) |cap, label| {
        try testing.expectEqualStrings(label, cap.id);
        try testing.expect(!cap.ok and cap.required);
        try testing.expectEqual(@as(usize, 1), cap.items.len);
        try testing.expectEqualStrings(error_item_id, cap.items[0].id);
        try testing.expect(std.mem.startsWith(u8, cap.items[0].detail.?, "exited 0, and "));
        try testing.expect(std.mem.indexOf(u8, cap.items[0].name, "-pkg'") != null);
    }
    try testing.expect(std.mem.indexOf(u8, caps[4].items[0].detail.?, "printed nothing") != null);
    try testing.expect(std.mem.indexOf(u8, caps[7].items[0].detail.?, "id is empty") != null);
}

test "provider doctor json: a failed run, a never-run package and a WARN each become a capability" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok_but_failed = "{\"id\":\"cap-y\",\"required\":true,\"ok\":true,\"items\":[]}";
    const honest = "{\"id\":\"cap-z\",\"required\":false,\"ok\":false,\"items\":[]}";
    const report: provider_doctor.Report = .{ .outcomes = &.{
        fakeOutcome("yns", "y-pkg", 3, ok_but_failed),
        fakeOutcome("zns", "z-pkg", 1, honest),
        .{ .label = "gone", .package = "gone", .code = null, .err = error.ProviderArchiveMissing },
        .{ .label = "later", .package = "later", .code = null, .err = error.PackageNotInstalled, .warning = true },
        .{ .label = "provider discovery", .package = "", .code = null, .err = error.ProbeDiscovery },
    } };
    const caps = try aggregate(a, &.{}, report);
    try testing.expectEqual(@as(usize, 5), caps.len);
    // Non-zero with a report claiming ok: kept, failed, and the exit recorded.
    try testing.expectEqualStrings("cap-y", caps[0].id);
    try testing.expect(!caps[0].ok);
    try testing.expectEqualStrings("exited 3 although its report says ok", caps[0].items[0].detail.?);
    // Non-zero with an honest failed report: kept as it is.
    try testing.expectEqualStrings("cap-z", caps[1].id);
    try testing.expect(!caps[1].ok and !caps[1].required and caps[1].items.len == 0);
    try testing.expectEqualStrings("gone", caps[2].id);
    try testing.expect(caps[2].required and !caps[2].ok);
    try testing.expectEqualStrings("did not run: ProviderArchiveMissing", caps[2].items[0].detail.?);
    try testing.expect(std.mem.indexOf(u8, caps[2].items[0].hint.?, "labelle providers fetch") != null);
    // A WARN does not make the document's verdict required.
    try testing.expect(!caps[3].required and !caps[3].ok);
    try testing.expectEqualStrings("provider discovery", caps[4].items[0].name);
}

test "provider doctor json: a duplicate id names every provider; a provider id replaces the core's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dup = "{\"id\":\"dup\",\"required\":true,\"ok\":true,\"items\":[]}";
    const shared = "{\"id\":\"shared\",\"required\":true,\"ok\":true,\"items\":[]}";
    const report: provider_doctor.Report = .{ .outcomes = &.{
        fakeOutcome("one", "one-pkg", 0, dup),
        fakeOutcome("mid", "mid-pkg", 0, shared),
        fakeOutcome("two", "two-pkg", 0, dup),
        fakeOutcome("three", "three-pkg", 0, dup),
    } };
    const caps = try aggregate(a, &core_caps, report);
    try testing.expectEqual(@as(usize, 3), caps.len);
    try testing.expectEqualStrings("core-a", caps[0].id);
    // One entry for the duplicated id, at its first position, naming all three.
    try testing.expectEqualStrings("dup", caps[1].id);
    try testing.expect(!caps[1].ok);
    try testing.expectEqualStrings("capability 'dup' is reported by providers 'one-pkg', 'two-pkg' and 'three-pkg'; a capability id must have one owner", caps[1].items[0].detail.?);
    // The provider's `shared` replaced the core's (which was not ok).
    try testing.expectEqualStrings("shared", caps[2].id);
    try testing.expect(caps[2].ok);
}

test "provider doctor json: the document is one line; no report keeps the core's capabilities" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const caps = try aggregate(a, &core_caps, null);
    try testing.expectEqual(@as(usize, 2), caps.len);
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(&w, caps);
    try testing.expectEqualStrings(
        \\{"capabilities":[{"id":"core-a","required":true,"ok":true,"items":[]},{"id":"shared","required":true,"ok":false,"items":[]}]}
    ++ "\n", w.buffered());
}
