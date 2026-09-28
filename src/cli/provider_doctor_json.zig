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
//! - A capability from a VALID provider report replaces a core capability
//!   with the same id: the provider owns what it reports.
//! - Two or more providers reporting one id become a single failed entry
//!   with that id whose item names every one of them. Neither report is
//!   trusted.
//! - A provider doctor that failed to run, exited with invalid output, or
//!   was never run (an unavailable or unverified package) becomes a failed
//!   capability with the synthetic id `provider:<package>` (`synthetic_prefix`;
//!   the label when there is no package) whose item carries the error. A
//!   synthetic id never replaces a core capability. A WARN (a package not
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

/// The id prefix of a capability the core writes for a provider that gave
/// no valid report. No provider data chooses it, so it cannot claim a core
/// capability's id.
pub const synthetic_prefix = "provider:";

/// One provider outcome's contribution: its capability, and whether the id
/// came from a valid report (only such an id may replace a core one).
pub const Contribution = struct { capability: Capability, reported: bool };

fn synthetic(a: std.mem.Allocator, outcome: provider_doctor.Outcome, required: bool, item: Item) !Contribution {
    return .{ .reported = false, .capability = .{
        .id = try std.fmt.allocPrint(a, "{s}{s}", .{ synthetic_prefix, owner(outcome) }),
        .required = required,
        .ok = false,
        .items = try a.dupe(Item, &.{item}),
    } };
}

/// The capability one provider outcome contributes (see the module doc).
pub fn fromOutcome(a: std.mem.Allocator, outcome: provider_doctor.Outcome) !Contribution {
    const name = try subject(a, outcome);
    if (outcome.code) |code| {
        switch (try validate(a, outcome.stdout orelse "")) {
            .capability => |cap| {
                if (code == 0) return .{ .capability = cap, .reported = true };
                var failed = cap;
                failed.ok = false;
                if (cap.ok) {
                    const note = errorItem(name, try std.fmt.allocPrint(a, "exited {d} although its report says ok", .{code}), null);
                    failed.items = try std.mem.concat(a, Item, &.{ cap.items, &.{note} });
                }
                return .{ .capability = failed, .reported = true };
            },
            .invalid => |why| {
                const detail = try std.fmt.allocPrint(a, "exited {d}, and {s}", .{ code, why });
                return synthetic(a, outcome, true, errorItem(name, detail, null));
            },
        }
    }
    const err = outcome.err orelse error.ProviderDoctorDidNotRun;
    const detail = try std.fmt.allocPrint(a, "did not run: {s}", .{@errorName(err)});
    return synthetic(a, outcome, !outcome.warning, errorItem(name, detail, hintFor(err)));
}

fn indexOf(caps: []const Capability, id: []const u8) ?usize {
    for (caps, 0..) |cap, i| if (std.mem.eql(u8, cap.id, id)) return i;
    return null;
}

/// The merged document: the core capabilities no provider report claims,
/// then one entry per provider capability id. `sources[i]` names who
/// produced `capabilities[i]` for the stderr summary: empty for the core,
/// else the provider package(s).
pub const Aggregated = struct {
    capabilities: []const Capability,
    sources: []const []const u8,
    /// Whether provider doctors took part (inside a project, not
    /// `--core-only`); the summary is printed only then.
    providers: bool,
};

/// The core's capabilities and the providers' outcomes, as the one list
/// `labelle doctor --json` prints: the core capabilities no valid provider
/// report claims, in order, then one entry per provider capability id, in
/// report order (a duplicated id at its first position).
pub fn aggregate(a: std.mem.Allocator, core: []const Capability, report: ?provider_doctor.Report) !Aggregated {
    const outcomes: []const provider_doctor.Outcome = if (report) |r| r.outcomes else &.{};
    const provided = try a.alloc(Contribution, outcomes.len);
    for (outcomes, provided) |outcome, *contribution| contribution.* = try fromOutcome(a, outcome);

    var out: std.ArrayList(Capability) = .empty;
    var sources: std.ArrayList([]const u8) = .empty;
    core: for (core) |cap| {
        for (provided) |contribution| {
            if (contribution.reported and std.mem.eql(u8, contribution.capability.id, cap.id)) continue :core;
        }
        try out.append(a, cap);
        try sources.append(a, "");
    }
    for (provided, 0..) |contribution, i| {
        const cap = contribution.capability;
        var earlier = false;
        for (provided[0..i]) |other| earlier = earlier or std.mem.eql(u8, other.capability.id, cap.id);
        if (earlier) continue;
        var owners: std.ArrayList([]const u8) = .empty;
        for (provided[i..], outcomes[i..]) |other, outcome| {
            if (std.mem.eql(u8, other.capability.id, cap.id)) try owners.append(a, owner(outcome));
        }
        var names: std.ArrayList(u8) = .empty;
        for (owners.items, 0..) |name, n| {
            const sep: []const u8 = if (n == 0) "" else if (n + 1 == owners.items.len) " and " else ", ";
            try names.print(a, "{s}'{s}'", .{ sep, name });
        }
        try sources.append(a, names.items);
        if (owners.items.len == 1) {
            try out.append(a, cap);
            continue;
        }
        const detail = try std.fmt.allocPrint(a, "capability '{s}' is reported by providers {s}; a capability id must have one owner", .{ cap.id, names.items });
        try out.append(a, .{
            .id = cap.id,
            .required = true,
            .ok = false,
            .items = try a.dupe(Item, &.{errorItem("duplicate capability id", detail, "remove one of these providers, or have one of them report a different capability id")}),
        });
    }
    return .{ .capabilities = out.items, .sources = sources.items, .providers = report != null };
}

pub const Verdict = enum { ok, failed, warning };

/// A capability's verdict: failed when required and not ok, a WARN when
/// optional and not ok.
pub fn verdict(cap: Capability) Verdict {
    if (cap.ok) return .ok;
    return if (cap.required) .failed else .warning;
}

/// The stderr summary of the provider capabilities in the merged document,
/// derived from it so the two cannot disagree: one line per provider entry
/// and a count. Nothing when no provider doctor took part.
pub fn printSummary(w: *std.Io.Writer, agg: Aggregated) !void {
    if (!agg.providers) return;
    var reported: usize = 0;
    var failed: std.ArrayList(u8) = .empty;
    var warned: std.ArrayList(u8) = .empty;
    var failed_n: usize = 0;
    var warned_n: usize = 0;
    var scratch: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const a = fba.allocator();
    try w.print("\nProvider capabilities (--json)\n------------------------------------------------------------\n", .{});
    for (agg.capabilities, agg.sources) |cap, source| {
        if (source.len == 0) continue;
        reported += 1;
        const v = verdict(cap);
        const tag = switch (v) {
            .ok => "  OK  ",
            .failed => " FAIL ",
            .warning => " WARN ",
        };
        try w.print("  [{s}] {s} ({s})\n", .{ tag, cap.id, source });
        if (v != .ok) {
            for (cap.items) |item| if (!item.ok) {
                if (item.detail) |d| try w.print("           {s}\n", .{d});
                if (item.hint) |h| try w.print("           -> {s}\n", .{h});
                break;
            };
        }
        const list = switch (v) {
            .ok => continue,
            .failed => blk: {
                failed_n += 1;
                break :blk &failed;
            },
            .warning => blk: {
                warned_n += 1;
                break :blk &warned;
            },
        };
        list.appendSlice(a, if (list.items.len == 0) "" else ", ") catch {};
        list.appendSlice(a, cap.id) catch {};
    }
    try w.print("Provider capabilities: {d} reported, {d} failed", .{ reported, failed_n });
    if (failed_n != 0) try w.print(" ({s})", .{failed.items});
    if (warned_n != 0) try w.print(", {d} warning(s) ({s})", .{ warned_n, warned.items });
    try w.print("\n", .{});
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

fn summary(a: std.mem.Allocator, agg: Aggregated) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try printSummary(&out.writer, agg);
    return out.written();
}

test "provider doctor json: a valid object is kept, an invalid one becomes a synthetic failed capability" {
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
    const agg = try aggregate(a, &core_caps, report);
    const caps = agg.capabilities;
    try testing.expectEqual(@as(usize, 2 + 6), caps.len);
    try testing.expectEqualStrings("core-a", caps[0].id);
    try testing.expectEqualStrings("shared", caps[1].id);
    try testing.expectEqualStrings("cap-x", caps[2].id);
    try testing.expect(caps[2].ok);
    try testing.expectEqualStrings("d", caps[2].items[0].detail.?);
    // Every invalid output is a failed capability under the synthetic id,
    // carrying why.
    for (caps[3..], [_][]const u8{ "provider:bad-pkg", "provider:empty-pkg", "provider:typed-pkg", "provider:two-pkg", "provider:noid-pkg" }) |cap, id| {
        try testing.expectEqualStrings(id, cap.id);
        try testing.expect(!cap.ok and cap.required);
        try testing.expectEqual(@as(usize, 1), cap.items.len);
        try testing.expectEqualStrings(error_item_id, cap.items[0].id);
        try testing.expect(std.mem.startsWith(u8, cap.items[0].detail.?, "exited 0, and "));
        try testing.expect(std.mem.indexOf(u8, cap.items[0].name, "-pkg'") != null);
    }
    try testing.expect(std.mem.indexOf(u8, caps[4].items[0].detail.?, "printed nothing") != null);
    try testing.expect(std.mem.indexOf(u8, caps[7].items[0].detail.?, "id is empty") != null);
    const text = try summary(a, agg);
    try testing.expect(std.mem.indexOf(u8, text, "[  OK  ] cap-x ('x-pkg')") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Provider capabilities: 6 reported, 5 failed (provider:bad-pkg, provider:empty-pkg, provider:typed-pkg, provider:two-pkg, provider:noid-pkg)") != null);
    // The core's entries are not the providers' to summarise.
    try testing.expect(std.mem.indexOf(u8, text, "core-a") == null);
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
    const agg = try aggregate(a, &.{}, report);
    const caps = agg.capabilities;
    try testing.expectEqual(@as(usize, 5), caps.len);
    // Non-zero with a report claiming ok: kept, failed, and the exit recorded.
    try testing.expectEqualStrings("cap-y", caps[0].id);
    try testing.expect(!caps[0].ok);
    try testing.expectEqualStrings("exited 3 although its report says ok", caps[0].items[0].detail.?);
    // Non-zero with an honest failed report: kept as it is.
    try testing.expectEqualStrings("cap-z", caps[1].id);
    try testing.expect(!caps[1].ok and !caps[1].required and caps[1].items.len == 0);
    try testing.expectEqualStrings("provider:gone", caps[2].id);
    try testing.expect(caps[2].required and !caps[2].ok);
    try testing.expectEqualStrings("did not run: ProviderArchiveMissing", caps[2].items[0].detail.?);
    try testing.expect(std.mem.indexOf(u8, caps[2].items[0].hint.?, "labelle providers fetch") != null);
    // A WARN does not make the document's verdict required.
    try testing.expectEqualStrings("provider:later", caps[3].id);
    try testing.expect(!caps[3].required and !caps[3].ok);
    try testing.expectEqualStrings("provider:provider discovery", caps[4].id);
    try testing.expectEqualStrings("provider discovery", caps[4].items[0].name);
    const text = try summary(a, agg);
    try testing.expect(std.mem.indexOf(u8, text, "5 reported, 3 failed (cap-y, provider:gone, provider:provider discovery), 2 warning(s) (cap-z, provider:later)") != null);
}

test "provider doctor json: a valid report saying ok:false counts as failed in the summary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const report: provider_doctor.Report = .{ .outcomes = &.{
        fakeOutcome("fine", "fine-pkg", 0, "{\"id\":\"fine\",\"required\":true,\"ok\":true,\"items\":[]}"),
        fakeOutcome("sad", "sad-pkg", 0, "{\"id\":\"sad\",\"required\":true,\"ok\":false,\"items\":[{\"id\":\"t\",\"name\":\"T\",\"ok\":false,\"fixable\":false,\"size_mb\":0,\"action\":null,\"detail\":\"missing tool\",\"hint\":\"install it\"}]}"),
    } };
    const text = try summary(a, try aggregate(a, &.{}, report));
    try testing.expect(std.mem.indexOf(u8, text, "[ FAIL ] sad ('sad-pkg')\n           missing tool\n           -> install it\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2 reported, 1 failed (sad)") != null);
}

test "provider doctor json: a duplicate id names every provider and fails the summary; a reported id replaces the core's" {
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
    const agg = try aggregate(a, &core_caps, report);
    const caps = agg.capabilities;
    try testing.expectEqual(@as(usize, 3), caps.len);
    try testing.expectEqualStrings("core-a", caps[0].id);
    // One entry for the duplicated id, at its first position, naming all three.
    try testing.expectEqualStrings("dup", caps[1].id);
    try testing.expect(!caps[1].ok);
    try testing.expectEqualStrings("capability 'dup' is reported by providers 'one-pkg', 'two-pkg' and 'three-pkg'; a capability id must have one owner", caps[1].items[0].detail.?);
    // The provider's `shared` replaced the core's (which was not ok).
    try testing.expectEqualStrings("shared", caps[2].id);
    try testing.expect(caps[2].ok);
    const text = try summary(a, agg);
    try testing.expect(std.mem.indexOf(u8, text, "[ FAIL ] dup ('one-pkg', 'two-pkg' and 'three-pkg')") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2 reported, 1 failed (dup)") != null);
}

test "provider doctor json: a package that never ran cannot displace a core capability, whatever its name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Remote packages named exactly like the core's capability ids: one not
    // installed (a WARN), one unavailable, one with invalid output.
    const report: provider_doctor.Report = .{ .outcomes = &.{
        .{ .label = "core-a", .package = "core-a", .code = null, .err = error.PackageNotInstalled, .warning = true },
        .{ .label = "shared", .package = "shared", .code = null, .err = error.ProviderArchiveMissing },
        fakeOutcome("core-a", "core-a", 0, "{not json"),
    } };
    const caps = (try aggregate(a, &core_caps, report)).capabilities;
    try testing.expectEqualStrings("core-a", caps[0].id);
    try testing.expectEqualStrings("shared", caps[1].id);
    try testing.expectEqual(@as(usize, 0), caps[0].items.len);
    try testing.expectEqualStrings("provider:core-a", caps[2].id);
    try testing.expectEqualStrings("provider:shared", caps[3].id);
}

test "provider doctor json: the document is one line; no report keeps the core's capabilities and prints no summary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const agg = try aggregate(a, &core_caps, null);
    try testing.expectEqual(@as(usize, 2), agg.capabilities.len);
    try testing.expectEqualStrings("", try summary(a, agg));
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(&w, agg.capabilities);
    try testing.expectEqualStrings(
        \\{"capabilities":[{"id":"core-a","required":true,"ok":true,"items":[]},{"id":"shared","required":true,"ok":false,"items":[]}]}
    ++ "\n", w.buffered());
}
