//! Guard for RFC #406 (docs/rfc-package-commands.md, "Enforcement"): the
//! CLI core under `src/` must not name platforms, stores, packages or
//! backends. Those names belong in provider packages; the core only knows
//! the contract (`cli/provider_contract.zig`) and the host OS it runs on.
//!
//! Walks every source file under `src/` at test time (`.zig`, plus the
//! compiled `.c`/`.h` vendored there), splits each into `[A-Za-z0-9]+` runs,
//! splits those again at CamelCase boundaries and compares the pieces
//! case-insensitively against `forbidden`. So `ios_cmd`, `cli/android/`,
//! `IosConfig` and `getSDLPath` flag while `std.Io`, `biosphere` and
//! `Iostream` do not. Comments count: the mandate is textual, so a doc
//! comment naming a platform is a finding too. The JSON wire fixtures under
//! `cli/provider_contract/` are data, not source, and stay out of scope:
//! they describe what a provider may send, so a provider name there is not
//! core code knowing a platform.
//!
//! Files that still carry legacy platform code sit on `allowed_files`, a
//! migration allowlist that can only SHRINK: the test also fails when an
//! allowlisted file no longer contains any forbidden word, so the entry has
//! to go. The run step sets the working directory to the repository root
//! (build.zig, `addAgnosticGuard`); the walk must reach `cli_root`, or the
//! test fails instead of passing vacuously.
const std = @import("std");

/// Platform, store, package and backend names the core must not mention.
/// Canonical lowercase; a token is compared after lowercasing.
const forbidden = [_][]const u8{
    "android", "ios",   "wasm",   "emsdk", "emscripten", "steam",
    "itch",    "xcode", "gradle", "apk",   "aab",        "ndk",
    "raylib",  "sokol", "sdl",    "sdl2",  "bgfx",       "wgpu",
};

/// Host OS names: the core legitimately branches on the OS it runs on,
/// so these are permanently allowed and never flagged.
const allowed_words = [_][]const u8{ "macos", "windows", "linux", "darwin", "win32" };

/// Migration allowlist of files that still contain forbidden words. Paths
/// are relative to `src/` with `/` separators, one file per entry: there
/// are no directory prefixes, so a new file under `cli/android/` is not
/// exempt. Recomputed on `feat/agnostic-guard` after the CamelCase split
/// and the C scan (53 entries). Shrink only: an entry whose file is clean
/// fails the test until it is removed.
const allowed_files = [_][]const u8{
    // This file: it spells the forbidden table out.
    "agnostic_guard_test.zig",
    // Legacy platform, store, package and backend sites (RFC #406 "Migration").
    "astc/cmd.zig",
    "astc/convert.zig",
    "cli.zig",
    "cli/add.zig",
    "cli/android.zig",
    "cli/android/apk_slim.zig",
    "cli/android/build.zig",
    "cli/android/deploy.zig",
    "cli/android/doctor.zig",
    "cli/android/launcher_icon.zig",
    "cli/android/package.zig",
    "cli/android/run.zig",
    "cli/android/studio.zig",
    "cli/android_sdk.zig",
    "cli/app_icon.zig",
    "cli/args.zig",
    "cli/args_tests.zig",
    "cli/assembler_proc.zig",
    "cli/bundle.zig",
    "cli/check.zig",
    "cli/compatibility.zig",
    "cli/config.zig",
    "cli/docker.zig",
    "cli/doctor.zig",
    "cli/emsdk_activate.zig",
    "cli/emsdk_cache.zig",
    "cli/emsdk_toolchain.zig",
    "cli/export.zig",
    "cli/help.zig",
    "cli/install.zig",
    "cli/ios.zig",
    "cli/launcher_manifest.zig",
    "cli/linux_desktop.zig",
    "cli/lockfile.zig",
    "cli/material_toolchain.zig",
    "cli/pack.zig",
    "cli/pipeline.zig",
    "cli/plugins.zig",
    "cli/prebuild.zig",
    "cli/progress.zig",
    "cli/project_config.zig",
    "cli/provider_dispatch.zig",
    "cli/python_provision.zig",
    "cli/runner.zig",
    "cli/screenshot_format.zig",
    "cli/sdl_provision.zig",
    "cli/serve.zig",
    "cli/status.zig",
    "cli/stb_image.h",
    "cli/stb_image_impl.c",
    "cli/update_check.zig",
    "cli/upgrade.zig",
};

const finding_note = "(platform/store/package names belong in providers; see docs/rfc-package-commands.md#enforcement)";

/// The CLI's root source (build.zig's exe `root_source_file`). The walk must
/// see it: a wrong working directory would otherwise scan nothing and pass.
const cli_root = "cli.zig";

/// Extensions the guard reads: Zig, and the vendored C compiled into the
/// binary (`build.zig`, `wireStb`).
const source_exts = [_][]const u8{ ".zig", ".c", ".h" };

fn isSource(path: []const u8) bool {
    for (source_exts) |e| if (std.mem.endsWith(u8, path, e)) return true;
    return false;
}

/// Longest entry of `forbidden`; longer runs cannot match and are skipped
/// without lowercasing.
const max_word_len = blk: {
    var n: usize = 0;
    for (forbidden) |w| n = @max(n, w.len);
    break :blk n;
};

comptime {
    // A host OS name on the forbidden table would make `allowed_words`
    // silently win; keep the two tables disjoint.
    for (allowed_words) |a| for (forbidden) |f| if (std.mem.eql(u8, a, f))
        @compileError("'" ++ a ++ "' is both allowed and forbidden");
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

/// The canonical forbidden word `run` spells (case-insensitively), or null.
fn classify(run: []const u8) ?[]const u8 {
    if (run.len > max_word_len) return null;
    var buf: [max_word_len]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..run.len], run);
    for (allowed_words) |a| if (std.mem.eql(u8, a, lower)) return null;
    for (forbidden) |f| if (std.mem.eql(u8, f, lower)) return f;
    return null;
}

/// True when a CamelCase boundary falls between `text[i - 1]` and
/// `text[i]`, both word bytes: a lowercase letter or digit followed by an
/// uppercase one (`getSDL`, `Sdl2Provision`), or the last letter of an
/// uppercase run when a lowercase letter follows it (`SDL|Path`). Digits
/// never start a piece, so `sdl2` and `win32` stay whole.
fn splitsBefore(text: []const u8, i: usize) bool {
    const prev = text[i - 1];
    const cur = text[i];
    if (!std.ascii.isUpper(cur)) return false;
    if (std.ascii.isLower(prev) or std.ascii.isDigit(prev)) return true;
    return i + 1 < text.len and std.ascii.isLower(text[i + 1]);
}

/// Yields the forbidden words of `text` in order of occurrence, one per
/// CamelCase piece of each `[A-Za-z0-9]+` run.
const Tokenizer = struct {
    text: []const u8,
    pos: usize = 0,

    fn next(self: *Tokenizer) ?[]const u8 {
        while (self.pos < self.text.len) {
            if (!isWordByte(self.text[self.pos])) {
                self.pos += 1;
                continue;
            }
            const start = self.pos;
            self.pos += 1;
            while (self.pos < self.text.len and isWordByte(self.text[self.pos]) and !splitsBefore(self.text, self.pos)) self.pos += 1;
            if (classify(self.text[start..self.pos])) |word| return word;
        }
        return null;
    }
};

/// `path` as the walker returns it: native separators, so `\\` on Windows.
/// Returns the index of the `allowed_files` entry naming it, if any.
fn allowedIndex(path: []const u8) ?usize {
    for (allowed_files, 0..) |a, i| {
        if (a.len != path.len) continue;
        const same = for (a, path) |x, y| {
            const yy: u8 = if (y == '\\') '/' else y;
            if (x != yy) break false;
        } else true;
        if (same) return i;
    }
    return null;
}

/// Accumulates one tree walk: findings in non-allowlisted files, and which
/// allowlist entries were actually exercised (so stale ones can be named).
const Scan = struct {
    gpa: std.mem.Allocator,
    offenders: std.ArrayList([]const u8) = .empty,
    dirty: [allowed_files.len]bool = @splat(false),
    saw_cli_root: bool = false,

    fn deinit(self: *Scan) void {
        for (self.offenders.items) |o| self.gpa.free(o);
        self.offenders.deinit(self.gpa);
    }

    /// Note one file's contents. `path` is relative to `src/`.
    fn file(self: *Scan, path: []const u8, bytes: []const u8) !void {
        if (std.mem.eql(u8, path, cli_root)) self.saw_cli_root = true;
        const allowed = allowedIndex(path);
        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            var tokens: Tokenizer = .{ .text = line };
            while (tokens.next()) |word| {
                if (allowed) |i| {
                    self.dirty[i] = true;
                    return; // one hit keeps the entry; no need to read on
                }
                const msg = try std.fmt.allocPrint(self.gpa, "src/{s}:{d}: '{s}' {s}", .{ path, line_no, word, finding_note });
                try self.offenders.append(self.gpa, msg);
            }
        }
    }

    /// Allowlist entries no scanned file needed: they must be removed.
    fn stale(self: *const Scan, out: *std.ArrayList([]const u8)) !void {
        for (allowed_files, 0..) |a, i| if (!self.dirty[i]) try out.append(self.gpa, a);
    }
};

fn expectWords(text: []const u8, expected: []const []const u8) !void {
    var t: Tokenizer = .{ .text = text };
    for (expected) |e| try std.testing.expectEqualStrings(e, t.next() orelse return error.TestExpectedWord);
    try std.testing.expectEqual(@as(?[]const u8, null), t.next());
}

test "the tokenizer flags whole alphanumeric runs, case-insensitively" {
    try expectWords("std.Io ios_cmd biosphere Android cli/android/run.zig SDL2_image", &.{ "ios", "android", "android", "sdl2" });
    // Substrings inside a longer lowercase run never match: `wasm` is not a word here.
    try expectWords("wasmtime bgfxdebug libsdl", &.{});
}

test "the tokenizer splits CamelCase at case transitions and acronym boundaries" {
    try expectWords("IosConfig", &.{"ios"});
    try expectWords("AndroidProvider", &.{"android"});
    try expectWords("WasmConfig", &.{"wasm"});
    try expectWords("SDL2Provision", &.{"sdl2"});
    try expectWords("getSDLPath", &.{"sdl"});
    try expectWords("pub const IosConfig2 = struct {};", &.{"ios"});
    // Digits stay attached to the preceding run; host OS names still pass.
    try expectWords("Win32Handle win32 x86_64", &.{});
    // No boundary inside a capitalised word or an all-lowercase run.
    try expectWords("std.Io Iostream biosphere wasmtime IoReader", &.{});
}

test "CamelCase pieces" {
    const Piece = struct {
        fn all(text: []const u8, out: *std.ArrayList([]const u8)) !void {
            var start: usize = 0;
            for (1..text.len) |i| if (splitsBefore(text, i)) {
                try out.append(std.testing.allocator, text[start..i]);
                start = i;
            };
            try out.append(std.testing.allocator, text[start..]);
        }
    };
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try Piece.all("SDL2Provision", &out);
    try std.testing.expectEqualDeep(&[_][]const u8{ "SDL2", "Provision" }, out.items);
    out.clearRetainingCapacity();
    try Piece.all("getSDLPath", &out);
    try std.testing.expectEqualDeep(&[_][]const u8{ "get", "SDL", "Path" }, out.items);
    out.clearRetainingCapacity();
    try Piece.all("Iostream", &out);
    try std.testing.expectEqualDeep(&[_][]const u8{"Iostream"}, out.items);
}

test "host OS names never flag" {
    for (allowed_words) |w| {
        try std.testing.expectEqual(@as(?[]const u8, null), classify(w));
        var upper: [8]u8 = undefined;
        try std.testing.expectEqual(@as(?[]const u8, null), classify(std.ascii.upperString(upper[0..w.len], w)));
    }
    var t: Tokenizer = .{ .text = "builtin.os.tag == .macos or .windows or .linux; darwin; win32" };
    try std.testing.expectEqual(@as(?[]const u8, null), t.next());
}

test "the allowlist matches Windows-style walker paths, one file per entry" {
    try std.testing.expect(allowedIndex("cli/pipeline.zig") != null);
    try std.testing.expect(allowedIndex("cli\\pipeline.zig") != null);
    try std.testing.expect(allowedIndex("cli\\android\\run.zig") != null);
    try std.testing.expect(allowedIndex("cli/android.zig") != null);
    // A new file under a legacy directory is NOT exempt.
    try std.testing.expect(allowedIndex("cli/android/not_yet_written.zig") == null);
    try std.testing.expect(allowedIndex("cli/android/") == null);
    try std.testing.expect(allowedIndex("cli/androidx/foo.zig") == null);
    try std.testing.expect(allowedIndex("cli\\provider_manifest.zig") == null);
    try std.testing.expect(allowedIndex("cli/provider_contract.zig") == null);
}

test "the walk reads Zig and vendored C, not JSON fixtures" {
    try std.testing.expect(isSource("cli.zig"));
    try std.testing.expect(isSource("cli/stb_image_impl.c"));
    try std.testing.expect(isSource("cli/stb_image.h"));
    try std.testing.expect(!isSource("cli/provider_contract/projectless.json"));
    try std.testing.expect(!isSource("cli/notes.md"));
}

test "a finding is reported per line and a clean allowlisted file goes stale" {
    const gpa = std.testing.allocator;
    var scan: Scan = .{ .gpa = gpa };
    defer scan.deinit();
    // Non-allowlisted: every hit is a finding with the documented shape.
    try scan.file("cli/provider_manifest.zig", "// runs on Android\nconst x = 1;\nconst y = sokol_dep;\n");
    try std.testing.expectEqual(@as(usize, 2), scan.offenders.items.len);
    try std.testing.expectEqualStrings("src/cli/provider_manifest.zig:1: 'android' " ++ finding_note, scan.offenders.items[0]);
    try std.testing.expectEqualStrings("src/cli/provider_manifest.zig:3: 'sokol' " ++ finding_note, scan.offenders.items[1]);
    // Allowlisted and dirty: no finding, entry kept. Clean: entry stale.
    try scan.file("cli/pipeline.zig", "// wasm\n");
    try scan.file("cli/android/run.zig", "const x = 1;\n");
    try std.testing.expectEqual(@as(usize, 2), scan.offenders.items.len);
    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(gpa);
    try scan.stale(&stale);
    try std.testing.expect(!containsString(stale.items, "cli/pipeline.zig"));
    try std.testing.expect(containsString(stale.items, "cli/android/run.zig"));
    try std.testing.expect(containsString(stale.items, "cli/serve.zig"));
    // The sentinel is only set by the CLI root itself.
    try std.testing.expect(!scan.saw_cli_root);
    try scan.file(cli_root, "// android\n");
    try std.testing.expect(scan.saw_cli_root);
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

test "no core file names a platform, store, package or backend" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var src = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    var walker = try src.walk(gpa);
    defer walker.deinit();

    var scan: Scan = .{ .gpa = gpa };
    defer scan.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !isSource(entry.path)) continue;
        const bytes = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(4 << 20));
        defer gpa.free(bytes);
        try scan.file(entry.path, bytes);
    }
    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(gpa);
    try scan.stale(&stale);

    for (scan.offenders.items) |o| std.debug.print("{s}\n", .{o});
    for (stale.items) |s| std.debug.print("src/{s} is on the migration allowlist but is clean; remove it\n", .{s});
    if (!scan.saw_cli_root) {
        std.debug.print("agnostic guard: the walk never reached src/{s}; run from the repository root (build.zig sets the cwd)\n", .{cli_root});
        return error.CliRootNotScanned;
    }
    try std.testing.expectEqual(@as(usize, 0), scan.offenders.items.len);
    try std.testing.expectEqual(@as(usize, 0), stale.items.len);
}
