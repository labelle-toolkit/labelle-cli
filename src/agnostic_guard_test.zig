//! Guard for RFC #406 (docs/rfc-package-commands.md, "Enforcement"): the
//! CLI core under `src/` must not name platforms, stores, packages or
//! backends. Those names belong in provider packages; the core only knows
//! the contract (`cli/provider_contract.zig`) and the host OS it runs on.
//!
//! Walks every source file under `src/` at test time (`.zig`, plus the
//! compiled `.c`/`.h` vendored there), splits each into `[A-Za-z0-9]+` runs
//! and compares each run case-insensitively against `forbidden`, first as a
//! whole and then piece by piece at CamelCase boundaries. A token that ends
//! in digits is also compared by its letter root, so a version or bit-width
//! suffix does not hide a name. So `ios_cmd`, `cli/android/`, `IosConfig`,
//! `iOS`, `iOSConfig`, `getSDLPath`, `wasm32`, `android14`, `sdl3` and
//! `Wasm32Target` flag while `std.Io`, `biosphere`, `Iostream`, `iostream`,
//! `win32`, `x86_64`, `utf8`, `base64` and `sha256` do not. The file's
//! path relative to `src/` is scanned the same way: a file whose directory
//! or name carries a platform (`cli/steam/upload.zig`) is a finding even
//! when its contents are clean, so renaming and moving files stays part of
//! the migration. Comments count: the mandate is textual, so a doc comment
//! naming a platform is a finding too. The JSON wire fixtures under
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
/// Canonical lowercase; a token is compared after lowercasing. `web` is the
/// platform the RFC moves into the `labelle-web` provider, alongside its
/// `wasm`/`emsdk` toolchain names. The Apple target platforms sit beside
/// `ios`: `macos` is a host the core runs on, `tvos`, `watchos`, `visionos`
/// and `maccatalyst` are only ever targets.
const forbidden = [_][]const u8{
    "android",  "ios",         "web",    "wasm", "emsdk", "emscripten", "steam",
    "itch",     "xcode",       "gradle", "apk",  "aab",   "ndk",        "raylib",
    "sokol",    "sdl",         "sdl2",   "bgfx", "wgpu",  "tvos",       "watchos",
    "visionos", "maccatalyst",
};

/// Host OS names: the core legitimately branches on the OS it runs on,
/// so these are permanently allowed and never flagged. Exact forms: `win32`
/// is allowed as spelled, and its root `win` is not forbidden, so the
/// numeric-suffix rule in `classify` cannot reach past it.
const allowed_words = [_][]const u8{ "macos", "windows", "linux", "darwin", "win32" };

/// Migration allowlist of files that still contain forbidden words. Paths
/// are relative to `src/` with `/` separators, one file per entry: there
/// are no directory prefixes, so a new file under `cli/android/` is not
/// exempt. Recomputed on `feat/agnostic-guard` after the CamelCase split
/// and the C scan, and again after the path scan, the `iOS` spelling and
/// `web` joined, and once more after the numeric-suffix rule (`wasm32`,
/// `sdl3`) and the Apple targets (`tvos`, `watchos`, `visionos`,
/// `maccatalyst`, spelled in `astc/cmd.zig`) joined (still 53 entries: every
/// file those reach was already listed). Shrink only: an entry whose file is
/// clean fails the test until it is removed. Note the path scan: an entry
/// under `cli/android/` or named `cli/ios.zig` stays dirty until the file is
/// moved or renamed, not merely emptied of platform words.
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

/// The canonical forbidden word `run` spells exactly (case-insensitively),
/// or null: a host OS name, or nothing on either table.
fn classifyExact(run: []const u8) ?[]const u8 {
    if (run.len > max_word_len) return null;
    var buf: [max_word_len]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..run.len], run);
    for (allowed_words) |a| if (std.mem.eql(u8, a, lower)) return null;
    for (forbidden) |f| if (std.mem.eql(u8, f, lower)) return f;
    return null;
}

/// The canonical forbidden word `run` spells, or null. Exact spelling
/// first (so `sdl2` and the allowed `win32` resolve as listed); then, when
/// the run is `<letters><digits>`, its letter root, so a version or
/// bit-width suffix does not hide a name: `wasm32`, `android14`, `sdl3` and
/// `bgfx2` flag. `win32`, `x86_64`, `utf8`, `base64` and `sha256` do not:
/// `win32` is allowed as spelled and `win`, `x`, `utf`, `base` and `sha` are
/// not forbidden. An all-digit run has no root and never matches.
fn classify(run: []const u8) ?[]const u8 {
    if (classifyExact(run)) |word| return word;
    var root = run.len;
    while (root > 0 and std.ascii.isDigit(run[root - 1])) root -= 1;
    if (root == 0 or root == run.len) return null;
    return classifyExact(run[0..root]);
}

/// True when a CamelCase boundary falls between `text[i - 1]` and
/// `text[i]`, both word bytes of the piece starting at `start`: a lowercase
/// letter or digit followed by an uppercase one (`getSDL`, `Sdl2Provision`),
/// or the last letter of an uppercase run when a lowercase letter follows
/// it (`SDL|Path`). Digits never start a piece, so `sdl2` and `win32` stay
/// whole. A run that opens with one lowercase letter and then two or more
/// uppercase ones is a lowercase-leading acronym (`iOS`, `iOSConfig`): no
/// boundary after its first letter, so it splits as `iOS|Config`, not
/// `i|OS|Config`. Only the first piece of a run can open with a lowercase
/// letter (every later piece starts at an uppercase one), so `start` is the
/// run's start whenever that rule can fire.
fn splitsBefore(text: []const u8, start: usize, i: usize) bool {
    const prev = text[i - 1];
    const cur = text[i];
    if (!std.ascii.isUpper(cur)) return false;
    if (std.ascii.isLower(prev)) {
        const leading_acronym = i == start + 1 and i + 1 < text.len and std.ascii.isUpper(text[i + 1]);
        return !leading_acronym;
    }
    if (std.ascii.isDigit(prev)) return true;
    return i + 1 < text.len and std.ascii.isLower(text[i + 1]);
}

/// Yields the forbidden words of `text` in order of occurrence. Each
/// `[A-Za-z0-9]+` run is classified whole first (`iOS`, `ANDROID`), then,
/// when the whole run is not a forbidden word, once per CamelCase piece.
const Tokenizer = struct {
    text: []const u8,
    pos: usize = 0,
    /// End of the run currently being split into pieces; `pos == run_end`
    /// between runs.
    run_end: usize = 0,

    fn next(self: *Tokenizer) ?[]const u8 {
        while (true) {
            if (self.pos >= self.run_end) {
                while (self.pos < self.text.len and !isWordByte(self.text[self.pos])) self.pos += 1;
                if (self.pos >= self.text.len) return null;
                const start = self.pos;
                var end = start;
                while (end < self.text.len and isWordByte(self.text[end])) end += 1;
                self.run_end = end;
                if (classify(self.text[start..end])) |word| {
                    self.pos = end;
                    return word;
                }
            }
            const start = self.pos;
            self.pos += 1;
            while (self.pos < self.run_end and !splitsBefore(self.text, start, self.pos)) self.pos += 1;
            if (classify(self.text[start..self.pos])) |word| return word;
        }
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

    /// Note one file: its path (relative to `src/`, scanned first, every
    /// segment) and then its contents, line by line.
    fn file(self: *Scan, path: []const u8, bytes: []const u8) !void {
        if (std.mem.eql(u8, path, cli_root)) self.saw_cli_root = true;
        const allowed = allowedIndex(path);
        var path_tokens: Tokenizer = .{ .text = path };
        while (path_tokens.next()) |word| {
            if (allowed) |i| {
                self.dirty[i] = true;
                return; // a platform in the name keeps the entry on its own
            }
            const msg = try std.fmt.allocPrint(self.gpa, "src/{s}: '{s}' in path {s}", .{ path, word, finding_note });
            try self.offenders.append(self.gpa, msg);
        }
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
    // Digits stay attached to the preceding piece; host OS names still pass.
    try expectWords("Win32Handle win32 x86_64", &.{});
    // No boundary inside a capitalised word or an all-lowercase run.
    try expectWords("std.Io Iostream biosphere wasmtime IoReader", &.{});
}

test "the tokenizer keeps lowercase-leading acronyms whole" {
    // Whole run first: the conventional spelling is one word.
    try expectWords("iOS", &.{"ios"});
    try expectWords("runs on iOS and Android", &.{ "ios", "android" });
    // `iOS|Config`, not `i|OS|Config`; plain camelCase still splits.
    try expectWords("iOSConfig", &.{"ios"});
    try expectWords("iosConfig", &.{"ios"});
    try expectWords("const iOSConfig = struct {};", &.{"ios"});
    // A one-letter lowercase prefix before a single capital is ordinary camelCase.
    try expectWords("getSDLPath aSdl", &.{ "sdl", "sdl" });
    // Neither an all-lowercase run nor a capitalised `Io` is the platform.
    try expectWords("iostream std.Io IoReader Io", &.{});
    // Host OS names keep passing under the whole-run rule too.
    try expectWords("macOS macos MacOS", &.{});
}

test "web is forbidden alongside its toolchain names" {
    try expectWords("web", &.{"web"});
    try expectWords("labelle-web WebProvider WebGL web/index.html", &.{ "web", "web", "web", "web" });
    try expectWords("wasm emsdk WasmConfig", &.{ "wasm", "emsdk", "wasm" });
    // Substrings inside a longer lowercase run never match.
    try expectWords("webhook website cobweb", &.{});
}

test "a numeric suffix does not hide a forbidden root" {
    // Whole runs: the letter root before an all-digit suffix is classified.
    try expectWords("wasm32", &.{"wasm"});
    try expectWords("android14", &.{"android"});
    try expectWords("sdl3", &.{"sdl"});
    try expectWords("bgfx2 SOKOL3 Emsdk4", &.{ "bgfx", "sokol", "emsdk" });
    try expectWords("target = .wasm32; api >= android14; libSDL3", &.{ "wasm", "android", "sdl" });
    // The exact table entry wins over the root: `sdl2` is listed as such.
    try expectWords("sdl2 SDL2_image", &.{ "sdl2", "sdl2" });
    // CamelCase pieces get the same treatment.
    try expectWords("Wasm32Target", &.{"wasm"});
    try expectWords("Sdl3Provision getAndroid14Sdk", &.{ "sdl", "android" });
    // Exact allowed forms and roots that are not forbidden stay clean.
    try expectWords("win32 Win32Handle x86_64 utf8 base64 sha256 macos14", &.{});
    try std.testing.expectEqual(@as(?[]const u8, null), classify("win32"));
    try std.testing.expectEqual(@as(?[]const u8, null), classify("x86"));
    try std.testing.expectEqual(@as(?[]const u8, null), classify("64"));
    try std.testing.expectEqual(@as(?[]const u8, null), classify("utf8"));
    try std.testing.expectEqual(@as(?[]const u8, null), classify("base64"));
    try std.testing.expectEqual(@as(?[]const u8, null), classify("sha256"));
    // Digits in the middle are not a suffix: no root is taken from them.
    try expectWords("web2py sdl2image", &.{});
}

test "the Apple target platforms are forbidden; macOS is a host" {
    try expectWords("tvos watchos visionos maccatalyst", &.{ "tvos", "watchos", "visionos", "maccatalyst" });
    try expectWords("tvOS watchOS visionOS MacCatalyst", &.{ "tvos", "watchos", "visionos", "maccatalyst" });
    try expectWords("TvosTarget WatchosBuild VisionosSim", &.{ "tvos", "watchos", "visionos" });
    try expectWords("macOS macos MacOS macos14", &.{});
    // Prose and longer runs around the names do not match.
    try expectWords("television watchdog vision catalyst", &.{});
}

test "CamelCase pieces" {
    const Piece = struct {
        fn all(text: []const u8, out: *std.ArrayList([]const u8)) !void {
            var start: usize = 0;
            for (1..text.len) |i| if (splitsBefore(text, 0, i)) {
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
    out.clearRetainingCapacity();
    try Piece.all("iOSConfig", &out);
    try std.testing.expectEqualDeep(&[_][]const u8{ "iOS", "Config" }, out.items);
    out.clearRetainingCapacity();
    try Piece.all("iosConfig", &out);
    try std.testing.expectEqualDeep(&[_][]const u8{ "ios", "Config" }, out.items);
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
    // The conventional `iOS` spelling and `web` count in a clean-looking file.
    try scan.file("cli/provider_manifest.zig", "const iOSConfig = struct {};\nconst w = labelle_web;\n");
    try std.testing.expectEqual(@as(usize, 4), scan.offenders.items.len);
    try std.testing.expectEqualStrings("src/cli/provider_manifest.zig:1: 'ios' " ++ finding_note, scan.offenders.items[2]);
    try std.testing.expectEqualStrings("src/cli/provider_manifest.zig:2: 'web' " ++ finding_note, scan.offenders.items[3]);
    // Allowlisted and dirty: no finding, entry kept. Clean name and body: stale.
    try scan.file("cli/pipeline.zig", "// wasm\n");
    try scan.file("cli/pack.zig", "const x = 1;\n");
    try std.testing.expectEqual(@as(usize, 4), scan.offenders.items.len);
    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(gpa);
    try scan.stale(&stale);
    try std.testing.expect(!containsString(stale.items, "cli/pipeline.zig"));
    try std.testing.expect(containsString(stale.items, "cli/pack.zig"));
    try std.testing.expect(containsString(stale.items, "cli/serve.zig"));
    // The sentinel is only set by the CLI root itself.
    try std.testing.expect(!scan.saw_cli_root);
    try scan.file(cli_root, "// android\n");
    try std.testing.expect(scan.saw_cli_root);
}

test "a platform in the path is a finding, and keeps an allowlist entry dirty" {
    const gpa = std.testing.allocator;
    var scan: Scan = .{ .gpa = gpa };
    defer scan.deinit();
    // Clean contents, dirty name: the directory segment is the finding.
    try scan.file("cli/steam/upload.zig", "const x = 1;\n");
    try std.testing.expectEqual(@as(usize, 1), scan.offenders.items.len);
    try std.testing.expectEqualStrings("src/cli/steam/upload.zig: 'steam' in path " ++ finding_note, scan.offenders.items[0]);
    // Every segment counts, on either separator, and `_`/`-`/`.` are boundaries.
    try scan.file("cli\\itch_upload.zig", "");
    try scan.file("cli/build-apk.zig", "");
    try scan.file("cli/xcode.h", "");
    try std.testing.expectEqual(@as(usize, 4), scan.offenders.items.len);
    try std.testing.expectEqualStrings("src/cli\\itch_upload.zig: 'itch' in path " ++ finding_note, scan.offenders.items[1]);
    try std.testing.expectEqualStrings("src/cli/build-apk.zig: 'apk' in path " ++ finding_note, scan.offenders.items[2]);
    try std.testing.expectEqualStrings("src/cli/xcode.h: 'xcode' in path " ++ finding_note, scan.offenders.items[3]);
    // Path hits come before content hits, once per segment hit.
    try scan.file("cli/android/gradle.zig", "// ndk\n");
    try std.testing.expectEqual(@as(usize, 7), scan.offenders.items.len);
    try std.testing.expectEqualStrings("src/cli/android/gradle.zig: 'android' in path " ++ finding_note, scan.offenders.items[4]);
    try std.testing.expectEqualStrings("src/cli/android/gradle.zig: 'gradle' in path " ++ finding_note, scan.offenders.items[5]);
    try std.testing.expectEqualStrings("src/cli/android/gradle.zig:1: 'ndk' " ++ finding_note, scan.offenders.items[6]);
    // Provider-neutral names produce nothing.
    try scan.file("cli/provider_settings.zig", "");
    try scan.file("cli/webhook_biosphere.zig", "");
    try std.testing.expectEqual(@as(usize, 7), scan.offenders.items.len);
    // An allowlisted file under a platform directory stays dirty with clean
    // contents: the entry is only stale once the file is moved or renamed.
    try scan.file("cli/android/run.zig", "const x = 1;\n");
    try scan.file("cli\\ios.zig", "");
    try std.testing.expectEqual(@as(usize, 7), scan.offenders.items.len);
    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(gpa);
    try scan.stale(&stale);
    try std.testing.expect(!containsString(stale.items, "cli/android/run.zig"));
    try std.testing.expect(!containsString(stale.items, "cli/ios.zig"));
    try std.testing.expect(containsString(stale.items, "cli/pack.zig"));
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
