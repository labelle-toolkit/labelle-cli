//! `labelle bundle` — macOS application bundle output (labelle-cli#359).
//!
//! `labelle build` / `labelle run` emit a BARE binary in `zig-out/bin`.
//! macOS only reads an application's icon from a bundle
//! (`.app/Contents/Info.plist` → `CFBundleIconFile` →
//! `Contents/Resources/*.icns`), so a bare binary shows the generic
//! executable glyph in the Dock, Finder and Launchpad no matter what
//! `project.labelle` `.app_icon` says. Android has had the icon since
//! cli#340; this module gives desktop macOS parity.
//!
//! It runs AFTER the normal generate+build pipeline (see `pipeline.zig`)
//! and wraps the built exe:
//!
//!     <out>/<Title>.app/
//!       Contents/
//!         Info.plist                  CFBundle* keys, see `renderInfoPlist`
//!         PkgInfo                     "APPL????" (legacy Finder hint)
//!         MacOS/<exe>                 copy of zig-out/bin/<exe>, mode preserved
//!         Resources/AppIcon.icns      from the resolved icon PNG, via iconutil
//!
//! `<out>` defaults to the target dir's `zig-out/` (next to `bin/`), or
//! `--output <dir>`. The exe keeps the name the generated build.zig
//! produced (`util.sanitizeExeName(project.name)`, labelle-assembler#362)
//! so `CFBundleExecutable` and `pgrep -f <name>` agree with `labelle run`.
//!
//! ## Icon
//!
//! Source precedence and failure policy are the shared `app_icon.zig`
//! rules (custom `.app_icon` → hard error if missing; assembler default
//! → degrade to "no icon" if absent). The `.icns` is produced the way
//! Apple documents it: write an `AppIcon.iconset/` holding the ten
//! standard PNGs (16…512 at @1x/@2x, i.e. 16…1024 px) and run
//! `iconutil -c icns` (the iconset is scratch under `~/.labelle/tmp/`,
//! never under the output dir). Sizes at or below the master use the same box
//! filter as Android; sizes ABOVE it use nearest-neighbour so a
//! pixel-art master (flying-platform: 576×576 on a 24-px grid) is not
//! blurred into the 1024 slot. 1024 is not a multiple of 24, so a 1152
//! or 1536 master (24×48 / 24×64) gives integer ratios for most entries.
//!
//! ## Scope
//!
//! macOS only, at RUNTIME: `iconutil` is a macOS tool and a `.app` is
//! only meaningful there. Other hosts get a one-line refusal (see
//! `printUnsupported`). Windows (`.ico` resource) and Linux (`.desktop`)
//! are the remaining halves of #359. DMG/zip packaging is out of scope.
//! `labelle run`/`build` are unchanged — no bundle unless asked.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const util = @import("util.zig");
const project_config = @import("project_config.zig");
const app_icon = @import("app_icon.zig");
const asm_cache = @import("asm_cache.zig");

/// `CFBundleIconFile` value. macOS resolves it to
/// `Contents/Resources/<value>.icns` (extension optional in the plist;
/// we keep it off, matching Xcode's default).
pub const icon_file_key = "AppIcon";
pub const icns_name = icon_file_key ++ ".icns";
/// Conventional iconset dir name; only used by tests as a fixture name.
/// The real scratch dir is `makeScratchIconset`'s uniquely-suffixed path
/// in CLI-owned storage, never a fixed name under the output dir.
pub const iconset_dir_name = icon_file_key ++ ".iconset";

/// Oldest macOS the bundle claims to run on. Big Sur is the first
/// release with the current Dock/Launchpad icon pipeline and the oldest
/// macOS the toolchain's backends (bgfx Metal, sokol Metal) still
/// target; we have no evidence for anything older, so don't claim it.
pub const min_system_version = "11.0";

/// One entry of the `.iconset`. `name` is what `iconutil` expects
/// verbatim; `size` is the PNG's edge in pixels (the `@2x` entries are
/// twice the nominal point size in their name).
pub const IconsetEntry = struct {
    name: []const u8,
    size: u32,
};

/// The ten PNGs Apple's `iconutil` accepts. Nothing else is read: a
/// stray file makes iconutil fail, and a missing one is silently
/// dropped from the `.icns` (so the Dock would pick the nearest present
/// size and scale it). All ten keep every context crisp.
pub const iconset_entries = [_]IconsetEntry{
    .{ .name = "icon_16x16.png", .size = 16 },
    .{ .name = "icon_16x16@2x.png", .size = 32 },
    .{ .name = "icon_32x32.png", .size = 32 },
    .{ .name = "icon_32x32@2x.png", .size = 64 },
    .{ .name = "icon_128x128.png", .size = 128 },
    .{ .name = "icon_128x128@2x.png", .size = 256 },
    .{ .name = "icon_256x256.png", .size = 256 },
    .{ .name = "icon_256x256@2x.png", .size = 512 },
    .{ .name = "icon_512x512.png", .size = 512 },
    .{ .name = "icon_512x512@2x.png", .size = 1024 },
};

/// Largest edge the iconset carries — what a master should be sized
/// for; surfaced in the decode-failure hint.
pub const iconset_max_px: u32 = iconset_entries[iconset_entries.len - 1].size;

/// Whether this host can produce a bundle at all. Checked at dispatch
/// time (cli.zig) so a Linux/Windows user gets the refusal BEFORE the
/// multi-minute generate+build, not after.
pub fn hostSupported() bool {
    return builtin.os.tag == .macos;
}

/// One line, exit non-zero. Windows/Linux icon paths are tracked on the
/// same issue; point there rather than pretending to succeed.
pub fn printUnsupported() void {
    std.debug.print("labelle bundle: macOS only for now (see #359)\n", .{});
}

/// `CFBundleIdentifier` from the project `.name`, following the
/// `com.labelle.<name>` scheme the Android manifest and the iOS plist
/// already use (`android/package.zig` `defaultPackageName`, `ios.zig`
/// `defaultBundleId`) so one project is the same "app" everywhere.
///
/// Apple's allowed alphabet is narrower than Android's: `[A-Za-z0-9-.]`
/// — no underscore, while Android REQUIRES underscore over hyphen. So
/// the map is `_`/space → `-` and any other disallowed byte dropped,
/// falling back to `game` (like `sanitizeExeName`) if nothing survives.
/// Caller owns the slice.
pub fn deriveBundleId(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "com.labelle.");
    const prefix_len = buf.items.len;
    for (name) |ch| {
        const keep = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-';
        if (keep) {
            try buf.append(allocator, ch);
        } else if (ch == '_' or ch == ' ') {
            try buf.append(allocator, '-');
        }
    }
    if (buf.items.len == prefix_len) try buf.appendSlice(allocator, "game");
    return buf.toOwnedSlice(allocator);
}

/// Append `raw` to `buf` as a single legal path component: `/` is the
/// separator, `\` is one on Windows (and confuses Finder), `:` is the
/// legacy HFS separator Finder still displays as `/` — all become `-`;
/// control bytes are dropped. Everything else (spaces, unicode,
/// punctuation) is fine on APFS. Leading/trailing spaces and dots are
/// then trimmed: a name of only those is invisible or hidden in Finder,
/// and a leading `..` is how `<out>/../x.app` would escape `<out>`.
/// Returns false when nothing usable survived (buf is left empty).
fn appendComponent(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), raw: []const u8) !bool {
    const start = buf.items.len;
    for (raw) |ch| {
        if (ch < 0x20 or ch == 0x7f) continue;
        try buf.append(allocator, if (ch == '/' or ch == '\\' or ch == ':') '-' else ch);
    }
    const trimmed = std.mem.trim(u8, buf.items[start..], " .");
    if (trimmed.len == 0) {
        buf.items.len = start;
        return false;
    }
    if (trimmed.len != buf.items.len - start) {
        std.mem.copyForwards(u8, buf.items[start .. start + trimmed.len], trimmed);
        buf.items.len = start + trimmed.len;
    }
    return true;
}

/// `<Title>.app`. The bundle is a DIRECTORY that `layoutBundle` deletes
/// and recreates, so the name MUST be one legal path component — see
/// `appendComponent`. Falls back to `.name` when the title has nothing
/// usable, and the fallback goes through the SAME sanitizer (Codex on
/// #362: a raw `.name` of `../Saved` produced `<out>/../Saved.app` and
/// the deleteTree that followed would have destroyed a sibling app).
/// Last resort is `game`, so there is always a bundle to `open`. Caller
/// owns the slice; the result always satisfies `isSafeBundleDirName`.
pub fn bundleDirName(allocator: std.mem.Allocator, title: []const u8, name: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    if (!try appendComponent(allocator, &buf, title)) {
        if (!try appendComponent(allocator, &buf, name)) {
            try buf.appendSlice(allocator, "game");
        }
    }
    try buf.appendSlice(allocator, ".app");
    return buf.toOwnedSlice(allocator);
}

/// Belt and braces for the delete in `layoutBundle`: true only for a
/// bare `<something>.app` component — no separators, no `.`/`..`, not
/// hidden, not the bare extension. Anything else could point the
/// recursive delete outside `<out>`, so it is refused.
pub fn isSafeBundleDirName(dir_name: []const u8) bool {
    if (dir_name.len <= ".app".len) return false;
    if (!std.mem.endsWith(u8, dir_name, ".app")) return false;
    if (dir_name[0] == '.') return false;
    if (std.mem.indexOfAny(u8, dir_name, "/\\:") != null) return false;
    if (std.mem.indexOfAny(u8, dir_name, "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x7f") != null) return false;
    return true;
}

/// Normalize the project version for BOTH plist version keys.
///
/// Apple requires `CFBundleShortVersionString` (the marketing version)
/// and `CFBundleVersion` (the build number) to be period-separated
/// integers, at most three components — a raw semver `1.2.3-beta` or
/// `2.0.0+build.7` fails distribution validation. So keep the leading
/// run of `digits(.digits)*` up to three components and drop prerelease
/// / build metadata: `1.2.3-beta` → `1.2.3`, `1.2.3.4` → `1.2.3`,
/// `2.` → `2`. Nothing usable (`""`, `v2`) → `1.0`. Pure slice into
/// `version` (or the literal fallback).
pub fn plistVersion(version: []const u8) []const u8 {
    var end: usize = 0;
    var components: u8 = 0;
    while (components < 3) {
        var i = end;
        if (components > 0) {
            if (i >= version.len or version[i] != '.') break;
            i += 1;
        }
        const digits_start = i;
        while (i < version.len and std.ascii.isDigit(version[i])) : (i += 1) {}
        if (i == digits_start) break;
        end = i;
        components += 1;
    }
    return if (components == 0) "1.0" else version[0..end];
}

/// Bytes that make a title "unusable" when they are all it contains:
/// whitespace and dots (a dots-only name is hidden in Finder; a blank
/// one is an empty Dock label). Shared by the bundle dir name and the
/// plist display names so the two can never disagree about what the
/// title is.
const title_strip = std.ascii.whitespace ++ [_]u8{'.'};

/// `CFBundleName` / `CFBundleDisplayName`: the trimmed `.title` when
/// anything usable remains, else the project `.name`, else `game` —
/// the SAME usable-title rule `bundleDirName` applies (Codex on #362:
/// a length-only check let a dots-only title through to a blank Dock
/// label while the bundle itself was sensibly named after `.name`).
/// Pure slice into one of the inputs (or the literal fallback).
pub fn displayName(title: []const u8, name: []const u8) []const u8 {
    const t = std.mem.trim(u8, title, &title_strip);
    if (t.len > 0) return t;
    const n = std.mem.trim(u8, name, &title_strip);
    return if (n.len > 0) n else "game";
}

/// Quote `s` as ONE POSIX shell word: wrap in single quotes, and turn
/// each embedded `'` into `'\''` (close, escaped quote, reopen). Inside
/// single quotes nothing else is special, so `"`, `$`, backticks and
/// spaces in a bundle path are literal — a double-quoted hint would let
/// a `$VAR` or `$(…)` in a project title expand when pasted (Codex on
/// #362). Caller owns the slice.
pub fn shellSingleQuote(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '\'');
    for (s) |ch| {
        if (ch == '\'') {
            try buf.appendSlice(allocator, "'\\''");
        } else {
            try buf.append(allocator, ch);
        }
    }
    try buf.append(allocator, '\'');
    return buf.toOwnedSlice(allocator);
}

/// The exe name the generated `build.zig` declares: the `.name = "…"` of
/// its `addExecutable(.{ … })` call, which the assembler emits BEFORE
/// `.root_module` (the module's `.imports` carry their own `.name`
/// fields, so the search stops at `.root_module` rather than risk
/// picking up `"labelle-core"`). Null when the file has no executable,
/// the field is not where expected, or the value is not a bare file
/// name — the caller then falls back to probing. Pure slice into
/// `source`.
pub fn exeNameFromBuildZig(source: []const u8) ?[]const u8 {
    const call = std.mem.indexOf(u8, source, "addExecutable(") orelse return null;
    const rest = source[call..];
    const limit = std.mem.indexOf(u8, rest, ".root_module") orelse rest.len;
    const key = std.mem.indexOf(u8, rest[0..limit], ".name = \"") orelse return null;
    const start = key + ".name = \"".len;
    const close = std.mem.indexOfScalarPos(u8, rest, start, '"') orelse return null;
    const name = rest[start..close];
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\") != null) return null;
    return name;
}

/// The built desktop executable: `name` (what `CFBundleExecutable` gets)
/// and its `path` under `<target>/zig-out/bin/`. Both owned.
pub const ResolvedExe = struct {
    name: []u8,
    path: []u8,

    pub fn deinit(self: ResolvedExe, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

/// Find the exe the CURRENT build produced.
///
/// The assembler names the desktop exe after the sanitized project
/// (labelle-assembler#362); older generated `build.zig` emit `game`.
/// The obvious "sanitized if it exists, else `game`" probe (what the
/// `labelle run` spawn site does) has a hole Codex flagged on #362: a
/// project pinned to an older assembler REBUILDS `game`, but a stale
/// sanitized-name binary from an earlier build still sits in `bin/` and
/// wins, so the bundle silently ships an outdated game — precisely in
/// the legacy scenario the fallback exists for.
///
/// So decide by the build that just ran: read the target dir's
/// `build.zig` and take the exe it declares when that file exists. Only
/// when that fails (unreadable/unparseable build.zig, or it names
/// something the build didn't produce) fall back to probing the two
/// candidates, and then prefer the MOST RECENTLY MODIFIED one — the one
/// the build just wrote.
pub fn resolveBuiltExe(allocator: std.mem.Allocator, target_dir: []const u8, project_name: []const u8) !ResolvedExe {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const bin_dir = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin" });
    defer allocator.free(bin_dir);

    // 1. What the generated build.zig says.
    const build_zig = try std.fs.path.join(allocator, &.{ target_dir, "build.zig" });
    defer allocator.free(build_zig);
    if (cwd.readFileAlloc(io, build_zig, allocator, .limited(8 * 1024 * 1024))) |source| {
        defer allocator.free(source);
        if (exeNameFromBuildZig(source)) |declared| {
            const path = try std.fs.path.join(allocator, &.{ bin_dir, declared });
            errdefer allocator.free(path);
            if (util.fileExists(path)) {
                return .{ .name = try allocator.dupe(u8, declared), .path = path };
            }
            allocator.free(path);
        }
    } else |_| {}

    // 2. Fallback: newest existing candidate.
    const sanitized = try util.sanitizeExeName(allocator, project_name);
    defer allocator.free(sanitized);
    const candidates = [_][]const u8{ sanitized, "game" };
    var best: ?ResolvedExe = null;
    errdefer if (best) |b| b.deinit(allocator);
    var best_mtime: i96 = 0;
    for (candidates) |cand| {
        const path = try std.fs.path.join(allocator, &.{ bin_dir, cand });
        const st = cwd.statFile(io, path, .{}) catch {
            allocator.free(path);
            continue;
        };
        if (best == null or st.mtime.nanoseconds > best_mtime) {
            if (best) |b| b.deinit(allocator);
            best = .{ .name = try allocator.dupe(u8, cand), .path = path };
            best_mtime = st.mtime.nanoseconds;
        } else {
            allocator.free(path);
        }
    }
    return best orelse {
        std.debug.print("labelle bundle: built executable not found in {s} (looked for '{s}' and 'game')\n", .{ bin_dir, sanitized });
        return error.BinaryNotFound;
    };
}

/// Escape the five XML specials so a title like `Rock & Roll` produces
/// a plist `plutil -lint` accepts. Caller owns the slice.
pub fn escapeXml(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (s) |ch| {
        switch (ch) {
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            '\'' => try buf.appendSlice(allocator, "&apos;"),
            else => try buf.append(allocator, ch),
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Everything `renderInfoPlist` needs. Raw (unescaped) strings — the
/// renderer escapes. `icon_file` null omits `CFBundleIconFile` entirely,
/// mirroring the Android manifest dropping `android:icon` when there is
/// no icon to stage: a dangling reference makes Finder show a broken
/// document glyph, which is worse than the generic app icon.
pub const PlistInfo = struct {
    bundle_id: []const u8,
    /// `CFBundleName` — short name, ≤15 chars recommended by Apple but
    /// not enforced; we pass the title through.
    name: []const u8,
    /// `CFBundleDisplayName` — what the Dock/Finder show.
    display_name: []const u8,
    /// `CFBundleExecutable` — MUST equal the file name in `Contents/MacOS/`.
    executable: []const u8,
    short_version: []const u8,
    build_version: []const u8,
    min_system: []const u8 = min_system_version,
    icon_file: ?[]const u8 = icon_file_key,
};

/// Render `Contents/Info.plist`. Caller owns the slice.
///
/// Key choices, and why:
///   * `CFBundlePackageType = APPL` — marks a launchable application.
///   * `NSHighResolutionCapable = true` — without it macOS renders the
///     window at 1x and upscales it blurry on Retina displays.
///   * `LSApplicationCategoryType = games` — the App Store category
///     Launchpad uses for grouping; harmless elsewhere.
///   * `NSSupportsAutomaticGraphicsSwitching = true` — lets dual-GPU
///     Macs stay on the integrated GPU; a 2D game does not need the
///     discrete one spun up.
pub fn renderInfoPlist(allocator: std.mem.Allocator, info: PlistInfo) ![]u8 {
    const bundle_id = try escapeXml(allocator, info.bundle_id);
    defer allocator.free(bundle_id);
    const name = try escapeXml(allocator, info.name);
    defer allocator.free(name);
    const display_name = try escapeXml(allocator, info.display_name);
    defer allocator.free(display_name);
    const executable = try escapeXml(allocator, info.executable);
    defer allocator.free(executable);
    const short_version = try escapeXml(allocator, info.short_version);
    defer allocator.free(short_version);
    const build_version = try escapeXml(allocator, info.build_version);
    defer allocator.free(build_version);
    const min_system = try escapeXml(allocator, info.min_system);
    defer allocator.free(min_system);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleDevelopmentRegion</key>
        \\    <string>en</string>
        \\
    );
    try w.print("    <key>CFBundleDisplayName</key>\n    <string>{s}</string>\n", .{display_name});
    try w.print("    <key>CFBundleExecutable</key>\n    <string>{s}</string>\n", .{executable});
    if (info.icon_file) |icon| {
        const icon_esc = try escapeXml(allocator, icon);
        defer allocator.free(icon_esc);
        try w.print("    <key>CFBundleIconFile</key>\n    <string>{s}</string>\n", .{icon_esc});
    }
    try w.print("    <key>CFBundleIdentifier</key>\n    <string>{s}</string>\n", .{bundle_id});
    try w.writeAll("    <key>CFBundleInfoDictionaryVersion</key>\n    <string>6.0</string>\n");
    try w.print("    <key>CFBundleName</key>\n    <string>{s}</string>\n", .{name});
    try w.writeAll("    <key>CFBundlePackageType</key>\n    <string>APPL</string>\n");
    try w.print("    <key>CFBundleShortVersionString</key>\n    <string>{s}</string>\n", .{short_version});
    try w.print("    <key>CFBundleVersion</key>\n    <string>{s}</string>\n", .{build_version});
    try w.writeAll("    <key>LSApplicationCategoryType</key>\n    <string>public.app-category.games</string>\n");
    try w.print("    <key>LSMinimumSystemVersion</key>\n    <string>{s}</string>\n", .{min_system});
    try w.writeAll(
        \\    <key>NSHighResolutionCapable</key>
        \\    <true/>
        \\    <key>NSSupportsAutomaticGraphicsSwitching</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    );
    return aw.toOwnedSlice();
}

/// Scale a decoded RGBA master to one square iconset size.
///
/// At or below the master's smaller edge → box filter (area average,
/// same as Android — crisp AND alias-free on non-integer ratios). Above
/// it → nearest-neighbour, because a box UPSCALE blends neighbours into
/// every output pixel and smears pixel art. Caller owns the buffer.
pub fn scaleForEntry(
    allocator: std.mem.Allocator,
    px: []const u8,
    src_w: usize,
    src_h: usize,
    size: u32,
) ![]u8 {
    const upscaling = size > @min(src_w, src_h);
    return if (upscaling)
        app_icon.resampleNearest(allocator, px, src_w, src_h, size, size)
    else
        app_icon.resampleBox(allocator, px, src_w, src_h, size, size);
}

/// Write the ten iconset PNGs into `iconset_dir` (created if needed).
/// Pure Zig — no Apple tool involved, so it is unit-tested on every CI
/// host; only the `iconutil` step below is macOS-bound.
pub fn writeIconset(
    allocator: std.mem.Allocator,
    iconset_dir: []const u8,
    px: []const u8,
    src_w: usize,
    src_h: usize,
) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, iconset_dir);

    for (iconset_entries) |entry| {
        const scaled = try scaleForEntry(allocator, px, src_w, src_h, entry.size);
        defer allocator.free(scaled);
        const png = try app_icon.encodePng(allocator, scaled, entry.size, entry.size);
        defer allocator.free(png);
        const out = try std.fs.path.join(allocator, &.{ iconset_dir, entry.name });
        defer allocator.free(out);
        try cwd.writeFile(io, .{ .sub_path = out, .data = png });
    }
}

/// `iconutil -c icns -o <icns_path> <iconset_dir>`. Spawned like the
/// CLI's other external tools (`util.runCmd` → `std.process.run`). A
/// missing binary is the ONE failure worth a tailored message: iconutil
/// ships with macOS itself, so its absence means the Xcode Command Line
/// Tools were never installed.
pub fn buildIcns(allocator: std.mem.Allocator, iconset_dir: []const u8, icns_path: []const u8) !void {
    const argv = [_][]const u8{ "iconutil", "-c", "icns", "-o", icns_path, iconset_dir };
    const result = util.runCmd(allocator, &argv) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print(
                \\labelle bundle: `iconutil` not found — it ships with macOS / the Xcode Command Line Tools.
                \\  fix: xcode-select --install
                \\
            , .{});
            return error.IconutilMissing;
        },
        else => {
            std.debug.print("labelle bundle: could not spawn iconutil: {s}\n", .{@errorName(err)});
            return err;
        },
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("labelle bundle: iconutil failed (exit {d}):\n{s}\n", .{ code, result.stderr });
            return error.IconutilFailed;
        },
        else => {
            std.debug.print("labelle bundle: iconutil terminated abnormally\n{s}\n", .{result.stderr});
            return error.IconutilFailed;
        },
    }
}

/// Where the `.app` goes. `--output` absolute → as given; relative →
/// anchored to the PROJECT dir (same rule as `wasm export --output`, so
/// `labelle bundle ../game --output dist` lands under the game, next to
/// where its build output already lives); none → the target dir's
/// `zig-out/`, beside `bin/`. Caller owns the slice.
///
/// Unlike `wasm export` this never wipes the output dir itself — only
/// the one `<Title>.app` inside it — so no destructive-path guard is
/// needed.
pub fn resolveOutputDir(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    target_dir: []const u8,
    output: ?[]const u8,
) ![]u8 {
    if (output) |o| {
        if (std.fs.path.isAbsolute(o)) return allocator.dupe(u8, o);
        return std.fs.path.join(allocator, &.{ project_dir, o });
    }
    return std.fs.path.join(allocator, &.{ target_dir, "zig-out" });
}

/// Lay the bundle skeleton down at `<out_dir>/<dir_name>`: dirs, the
/// exe copy, `Info.plist`, `PkgInfo`. Wipes any previous bundle there
/// first so a renamed exe or a removed icon can't leave stale files
/// behind. Filesystem-only (no Apple tools), so it is unit-tested
/// everywhere.
///
/// The wipe is the ONLY recursive delete `labelle bundle` performs under
/// a user-chosen directory, so it is guarded twice: `bundleDirName`
/// only ever produces a safe component, and this refuses
/// (`error.UnsafeBundleName`) any `dir_name` that is not a bare
/// `<x>.app` — a caller bug can then not turn into `rm -rf <out>/..`.
///
/// `copyFile` with default options copies the source's permissions, so
/// the exec bit survives without a `chmod` spawn (`ios.zig` predates
/// that option and still shells out). Returns the caller-owned bundle path.
pub fn layoutBundle(
    allocator: std.mem.Allocator,
    out_dir: []const u8,
    dir_name: []const u8,
    exe_src: []const u8,
    exe_name: []const u8,
    plist: []const u8,
) ![]u8 {
    if (!isSafeBundleDirName(dir_name)) {
        std.debug.print("labelle bundle: refusing to replace '{s}' — not a plain <name>.app component\n", .{dir_name});
        return error.UnsafeBundleName;
    }
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const bundle_dir = try std.fs.path.join(allocator, &.{ out_dir, dir_name });
    errdefer allocator.free(bundle_dir);
    cwd.deleteTree(io, bundle_dir) catch {};

    const macos_dir = try std.fs.path.join(allocator, &.{ bundle_dir, "Contents", "MacOS" });
    defer allocator.free(macos_dir);
    try cwd.createDirPath(io, macos_dir);
    const resources_dir = try std.fs.path.join(allocator, &.{ bundle_dir, "Contents", "Resources" });
    defer allocator.free(resources_dir);
    try cwd.createDirPath(io, resources_dir);

    const exe_dst = try std.fs.path.join(allocator, &.{ macos_dir, exe_name });
    defer allocator.free(exe_dst);
    try cwd.copyFile(exe_src, cwd, exe_dst, io, .{});

    const plist_path = try std.fs.path.join(allocator, &.{ bundle_dir, "Contents", "Info.plist" });
    defer allocator.free(plist_path);
    try cwd.writeFile(io, .{ .sub_path = plist_path, .data = plist });

    // Type `APPL`, creator `????` (none). Modern macOS reads the plist
    // instead, but Finder still consults PkgInfo on some paths and every
    // Xcode-built app ships it — cheap insurance.
    const pkginfo_path = try std.fs.path.join(allocator, &.{ bundle_dir, "Contents", "PkgInfo" });
    defer allocator.free(pkginfo_path);
    try cwd.writeFile(io, .{ .sub_path = pkginfo_path, .data = "APPL????" });

    return bundle_dir;
}

/// Create a fresh, uniquely named `<cache-root>/tmp/AppIcon-<n>.iconset`
/// for `iconutil` to read (the suffix must be `.iconset` or iconutil
/// refuses it). Caller owns the returned path AND the directory: remove
/// it with `deleteTree` on every exit path.
///
/// It lives in CLI-owned storage (`~/.labelle/`, or `LABELLE_HOME` —
/// the same tree as the assembler/zig caches) and NOT under `<out>`:
/// `AppIcon.iconset` is the conventional name for a developer's own
/// source iconset and `--output` may be the project root, so a fixed
/// scratch path there would have deleted real assets (Codex on #362).
/// Uniqueness follows the `zig_toolchain` staging idiom — 0.16 has no
/// `std.crypto.random`, so a PRNG seeded from a stack address mixed with
/// the path; collisions between concurrent bundles are what the suffix
/// guards against, not adversaries.
pub fn makeScratchIconset(allocator: std.mem.Allocator) ![]u8 {
    const root = try asm_cache.getCacheRoot(allocator);
    defer allocator.free(root);
    const tmp_root = try std.fs.path.join(allocator, &.{ root, "tmp" });
    defer allocator.free(tmp_root);
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, tmp_root);

    var prng = std.Random.DefaultPrng.init(@intFromPtr(&tmp_root) ^ std.hash.Wyhash.hash(0, tmp_root));
    var attempt: u8 = 0;
    while (attempt < 8) : (attempt += 1) {
        const name = try std.fmt.allocPrint(allocator, "{s}-{x}.iconset", .{ icon_file_key, prng.random().int(u64) });
        defer allocator.free(name);
        const path = try std.fs.path.join(allocator, &.{ tmp_root, name });
        errdefer allocator.free(path);
        // createDir (not createDirPath) so an existing dir is an error and
        // we never adopt — let alone later delete — someone else's tree.
        cwd.createDir(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => return err,
        };
        return path;
    }
    return error.ScratchDirCollision;
}

/// Post-build entry point called from `pipeline.zig` once `zig build`
/// has produced the desktop exe. Returns the caller-owned `.app` path.
///
/// Order matters: the icon is resolved FIRST so a misconfigured
/// `.app_icon` fails before anything is written, and the `.icns` is
/// built before the plist so `CFBundleIconFile` is only emitted when
/// the file it names exists.
pub fn createFromBuild(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    target_dir: []const u8,
    cfg: project_config.ProjectConfig,
    output_override: ?[]const u8,
) ![]u8 {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    // 1. Icon (may legitimately be absent — older assembler, no default).
    const maybe_img = try app_icon.load(allocator, project_dir, target_dir, cfg.app_icon, .{
        .label = "bundle icon",
        .recommended_px = iconset_max_px,
    });
    defer if (maybe_img) |img| img.free();
    if (maybe_img) |img| {
        if (img.width != img.height) {
            std.debug.print(
                "labelle bundle: app icon is {d}x{d} (not square) — macOS icons are square, it will be stretched to fit\n",
                .{ img.width, img.height },
            );
        }
    }

    // 2. Locate the exe the CURRENT build produced (see `resolveBuiltExe`
    //    for why this is not a plain existence probe).
    const exe = try resolveBuiltExe(allocator, target_dir, cfg.name);
    defer exe.deinit(allocator);
    const exe_name: []const u8 = exe.name;
    const exe_src: []const u8 = exe.path;

    // 3. Paths. Only `<out>/<Title>.app` is ever created or removed under
    //    the user's chosen directory — nothing else there is touched.
    const out_dir = try resolveOutputDir(allocator, project_dir, target_dir, output_override);
    defer allocator.free(out_dir);
    try cwd.createDirPath(io, out_dir);
    const dir_name = try bundleDirName(allocator, cfg.title, cfg.name);
    defer allocator.free(dir_name);

    // 4. Skeleton + exe. The plist is rendered knowing whether an icon
    //    will land; the .icns itself is built right after.
    const bundle_id = try deriveBundleId(allocator, cfg.name);
    defer allocator.free(bundle_id);
    const display = displayName(cfg.title, cfg.name);
    const has_icon = maybe_img != null;
    const plist = try renderInfoPlist(allocator, .{
        .bundle_id = bundle_id,
        .name = display,
        .display_name = display,
        .executable = exe_name,
        .short_version = plistVersion(cfg.version),
        .build_version = plistVersion(cfg.version),
        .icon_file = if (has_icon) icon_file_key else null,
    });
    defer allocator.free(plist);
    const bundle_dir = try layoutBundle(allocator, out_dir, dir_name, exe_src, exe_name, plist);
    errdefer allocator.free(bundle_dir);
    // A bundle whose plist names an `.icns` that never landed shows the
    // broken-document glyph — worse than no bundle. If anything below
    // fails, take the skeleton down with it.
    errdefer cwd.deleteTree(io, bundle_dir) catch {};

    // 5. Icon → iconset → icns. The iconset is scratch in CLI-owned temp
    //    storage (see `makeScratchIconset` for why not under `<out>`),
    //    removed once iconutil has consumed it, on success and on error.
    if (maybe_img) |img| {
        const iconset_dir = try makeScratchIconset(allocator);
        defer allocator.free(iconset_dir);
        defer cwd.deleteTree(io, iconset_dir) catch {};
        try writeIconset(allocator, iconset_dir, img.pixels, img.width, img.height);

        const icns_path = try std.fs.path.join(allocator, &.{ bundle_dir, "Contents", "Resources", icns_name });
        defer allocator.free(icns_path);
        try buildIcns(allocator, iconset_dir, icns_path);
    }

    std.debug.print("labelle: bundle ready: {s}\n", .{bundle_dir});
    return bundle_dir;
}

// ── Tests ──────────────────────────────────────────────────────────
//
// CI runs these on ubuntu and windows too, so nothing here spawns
// `iconutil` or needs macOS: the plist, the id/name/version derivations,
// the iconset table, the scale-mode choice and the on-disk layout are
// all exercised with fixtures.

const testing = std.testing;

test "deriveBundleId follows com.labelle.<name> and swaps _ for - (Apple's alphabet)" {
    const a = testing.allocator;
    const fp = try deriveBundleId(a, "flying_platform");
    defer a.free(fp);
    try testing.expectEqualStrings("com.labelle.flying-platform", fp);

    const clean = try deriveBundleId(a, "my-game-2");
    defer a.free(clean);
    try testing.expectEqualStrings("com.labelle.my-game-2", clean);

    const spaced = try deriveBundleId(a, "My Game!");
    defer a.free(spaced);
    try testing.expectEqualStrings("com.labelle.My-Game", spaced);

    const empty = try deriveBundleId(a, "!!!");
    defer a.free(empty);
    try testing.expectEqualStrings("com.labelle.game", empty);
}

test "bundleDirName uses the title, sanitizes path separators, falls back to name" {
    const a = testing.allocator;
    const fp = try bundleDirName(a, "Flying Platform", "flying_platform");
    defer a.free(fp);
    try testing.expectEqualStrings("Flying Platform.app", fp);

    const slashed = try bundleDirName(a, "Rock/Roll: Live", "rr");
    defer a.free(slashed);
    try testing.expectEqualStrings("Rock-Roll- Live.app", slashed);

    const blank = try bundleDirName(a, "   ", "my_game");
    defer a.free(blank);
    try testing.expectEqualStrings("my_game.app", blank);

    const nothing = try bundleDirName(a, "", "");
    defer a.free(nothing);
    try testing.expectEqualStrings("game.app", nothing);
}

test "bundleDirName sanitizes the .name fallback exactly like the title (Codex on #362)" {
    const a = testing.allocator;
    // Empty title, traversal-shaped name: must NOT become `<out>/../Saved.app`.
    const traversal = try bundleDirName(a, "", "../Saved");
    defer a.free(traversal);
    try testing.expectEqualStrings("-Saved.app", traversal);
    try testing.expect(isSafeBundleDirName(traversal));

    const dots = try bundleDirName(a, " . ", "..");
    defer a.free(dots);
    try testing.expectEqualStrings("game.app", dots);

    const backslash = try bundleDirName(a, "", "a\\b");
    defer a.free(backslash);
    try testing.expectEqualStrings("a-b.app", backslash);

    // Every output — from title, from name, or the last resort — passes
    // the guard `layoutBundle` applies before its recursive delete.
    const from_title = try bundleDirName(a, "Rock/Roll: Live", "x");
    defer a.free(from_title);
    try testing.expect(isSafeBundleDirName(from_title));
}

test "isSafeBundleDirName accepts only a bare <name>.app component" {
    try testing.expect(isSafeBundleDirName("Flying Platform.app"));
    try testing.expect(isSafeBundleDirName("game.app"));
    try testing.expect(isSafeBundleDirName("-Saved.app"));
    try testing.expect(!isSafeBundleDirName("../Saved.app"));
    try testing.expect(!isSafeBundleDirName("..\\Saved.app"));
    try testing.expect(!isSafeBundleDirName("a/b.app"));
    try testing.expect(!isSafeBundleDirName("a:b.app"));
    try testing.expect(!isSafeBundleDirName(".hidden.app"));
    try testing.expect(!isSafeBundleDirName(".app"));
    try testing.expect(!isSafeBundleDirName("noext"));
    try testing.expect(!isSafeBundleDirName(""));
    try testing.expect(!isSafeBundleDirName("bad\nname.app"));
}

test "layoutBundle refuses to delete anything that is not <name>.app inside out_dir" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const work = ".zig-cache/bundle-layout-refuse";
    cwd.deleteTree(io, work) catch {};
    defer cwd.deleteTree(io, work) catch {};
    // `<work>/out` is the output dir; `<work>/Saved.app` is an unrelated
    // sibling that a traversal-shaped name would have pointed the wipe at.
    const out = try std.fs.path.join(a, &.{ work, "out" });
    defer a.free(out);
    try cwd.createDirPath(io, out);
    const sibling = try std.fs.path.join(a, &.{ work, "Saved.app", "keep.txt" });
    defer a.free(sibling);
    const sibling_dir = std.fs.path.dirname(sibling).?;
    try cwd.createDirPath(io, sibling_dir);
    try cwd.writeFile(io, .{ .sub_path = sibling, .data = "precious" });
    const exe_src = try std.fs.path.join(a, &.{ work, "exe" });
    defer a.free(exe_src);
    try cwd.writeFile(io, .{ .sub_path = exe_src, .data = "bin" });

    try testing.expectError(error.UnsafeBundleName, layoutBundle(a, out, "../Saved.app", exe_src, "exe", "<plist/>"));
    try testing.expectError(error.UnsafeBundleName, layoutBundle(a, out, "Saved", exe_src, "exe", "<plist/>"));
    try testing.expectError(error.UnsafeBundleName, layoutBundle(a, out, ".app", exe_src, "exe", "<plist/>"));
    try testing.expect(util.fileExists(sibling));
}

test "makeScratchIconset lives under the CLI cache root, is unique, and ends in .iconset" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const root = ".zig-cache/bundle-scratch-root";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    // Tests can't see env vars (empty environ under `zig build test`), so
    // pin the cache root the way the other cache modules' tests do.
    asm_cache.setCacheRootOverride(root);
    defer asm_cache.clearCacheRootOverride();

    const first = try makeScratchIconset(a);
    defer a.free(first);
    const second = try makeScratchIconset(a);
    defer a.free(second);

    const tmp_root = try std.fs.path.join(a, &.{ root, "tmp" });
    defer a.free(tmp_root);
    const tmp_prefix = try std.fs.path.join(a, &.{ tmp_root, icon_file_key ++ "-" });
    defer a.free(tmp_prefix);
    try testing.expect(std.mem.startsWith(u8, first, tmp_prefix));
    try testing.expect(std.mem.endsWith(u8, first, ".iconset"));
    try testing.expect(util.dirExists(first));
    try testing.expect(util.dirExists(second));
    try testing.expect(!std.mem.eql(u8, first, second));
}

test "createFromBuild touches nothing under <out> except <Title>.app (Codex on #362)" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-out-untouched";
    try bundleFixture(a, work, "my_game");
    defer cwd.deleteTree(io, work) catch {};
    const target = try std.fs.path.join(a, &.{ work, "target" });
    defer a.free(target);

    // `<out>` already holds a developer's own source iconset (the fixed
    // scratch path used to deleteTree exactly this), an unrelated file, a
    // DIFFERENT app bundle, and a stale copy of ours with a stray file.
    const out = try std.fs.path.join(a, &.{ work, "dist" });
    defer a.free(out);
    const dev_iconset = try std.fs.path.join(a, &.{ out, iconset_dir_name, "icon_16x16.png" });
    defer a.free(dev_iconset);
    try cwd.createDirPath(io, std.fs.path.dirname(dev_iconset).?);
    try cwd.writeFile(io, .{ .sub_path = dev_iconset, .data = "dev's own" });
    const other_file = try std.fs.path.join(a, &.{ out, "notes.txt" });
    defer a.free(other_file);
    try cwd.writeFile(io, .{ .sub_path = other_file, .data = "keep" });
    const other_app = try std.fs.path.join(a, &.{ out, "Other.app", "Contents", "Info.plist" });
    defer a.free(other_app);
    try cwd.createDirPath(io, std.fs.path.dirname(other_app).?);
    try cwd.writeFile(io, .{ .sub_path = other_app, .data = "other" });
    const stale_stray = try std.fs.path.join(a, &.{ out, "My Game.app", "stray" });
    defer a.free(stale_stray);
    try cwd.createDirPath(io, std.fs.path.dirname(stale_stray).?);
    try cwd.writeFile(io, .{ .sub_path = stale_stray, .data = "stale" });

    const cfg = project_config.ProjectConfig{ .name = "my_game", .title = "My Game" };
    const bundle = try createFromBuild(a, work, target, cfg, "dist");
    defer a.free(bundle);

    // Ours was replaced wholesale...
    try testing.expect(!util.fileExists(stale_stray));
    const exe = try std.fs.path.join(a, &.{ bundle, "Contents", "MacOS", "my_game" });
    defer a.free(exe);
    try testing.expect(util.fileExists(exe));
    // ...and everything else in <out> is exactly as it was.
    const dev_bytes = try cwd.readFileAlloc(io, dev_iconset, a, .unlimited);
    defer a.free(dev_bytes);
    try testing.expectEqualStrings("dev's own", dev_bytes);
    try testing.expect(util.fileExists(other_file));
    try testing.expect(util.fileExists(other_app));
}

test "plistVersion keeps up to three integer components and falls back to 1.0" {
    try testing.expectEqualStrings("0.1.0", plistVersion("0.1.0"));
    try testing.expectEqualStrings("1.2.3", plistVersion("1.2.3-beta"));
    try testing.expectEqualStrings("2.0.0", plistVersion("2.0.0+build.7"));
    try testing.expectEqualStrings("1.2.3", plistVersion("1.2.3-beta+5"));
    try testing.expectEqualStrings("1.2.3", plistVersion("1.2.3.4"));
    try testing.expectEqualStrings("2", plistVersion("2."));
    try testing.expectEqualStrings("1.0", plistVersion(""));
    try testing.expectEqualStrings("1.0", plistVersion("v2"));
    try testing.expectEqualStrings("1.0", plistVersion(".5"));
}

test "displayName shares bundleDirName's usable-title rule" {
    try testing.expectEqualStrings("Flying Platform", displayName("Flying Platform", "flying_platform"));
    try testing.expectEqualStrings("Trim Me", displayName("  Trim Me. ", "x"));
    // Dots/whitespace-only title: NOT a blank Dock label — the project name.
    try testing.expectEqualStrings("my_game", displayName("...", "my_game"));
    try testing.expectEqualStrings("my_game", displayName(" \t ", "my_game"));
    try testing.expectEqualStrings("game", displayName("", ""));
}

test "shellSingleQuote yields one literal POSIX word" {
    const a = testing.allocator;
    const plain = try shellSingleQuote(a, "/tmp/My Game.app");
    defer a.free(plain);
    try testing.expectEqualStrings("'/tmp/My Game.app'", plain);
    const nasty = try shellSingleQuote(a, "it's $HOME `x` \"q\"");
    defer a.free(nasty);
    try testing.expectEqualStrings("'it'\\''s $HOME `x` \"q\"'", nasty);
    const empty = try shellSingleQuote(a, "");
    defer a.free(empty);
    try testing.expectEqualStrings("''", empty);
}

test "exeNameFromBuildZig reads the addExecutable name and ignores import names" {
    const generated =
        \\    const exe = b.addExecutable(.{
        \\        .name = "flying_platform",
        \\        .root_module = b.createModule(.{
        \\            .imports = &.{
        \\                .{ .name = "labelle-core", .module = core_mod },
        \\            },
        \\        }),
        \\    });
    ;
    try testing.expectEqualStrings("flying_platform", exeNameFromBuildZig(generated).?);
    // No executable at all (a lib-only / tests build.zig).
    try testing.expect(exeNameFromBuildZig("const lib = b.addLibrary(.{ .name = \"x\" });") == null);
    // `.root_module` first: the only `.name` in reach is an import's — refuse.
    const inverted =
        \\    const exe = b.addExecutable(.{
        \\        .root_module = b.createModule(.{ .imports = &.{ .{ .name = "labelle-core", .module = m } } }),
        \\        .name = "game",
        \\    });
    ;
    try testing.expect(exeNameFromBuildZig(inverted) == null);
    // A path is not a file name.
    try testing.expect(exeNameFromBuildZig("b.addExecutable(.{ .name = \"../x\", .root_module = m })") == null);
}

test "renderInfoPlist emits every required key and escapes XML specials" {
    const a = testing.allocator;
    const plist = try renderInfoPlist(a, .{
        .bundle_id = "com.labelle.rock-roll",
        .name = "Rock & Roll <Live>",
        .display_name = "Rock & Roll <Live>",
        .executable = "rock_roll",
        .short_version = "1.2.3-beta",
        .build_version = "1.2.3",
    });
    defer a.free(plist);

    try testing.expect(std.mem.startsWith(u8, plist, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"));
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleIdentifier</key>\n    <string>com.labelle.rock-roll</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleExecutable</key>\n    <string>rock_roll</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleIconFile</key>\n    <string>AppIcon</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundlePackageType</key>\n    <string>APPL</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleShortVersionString</key>\n    <string>1.2.3-beta</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleVersion</key>\n    <string>1.2.3</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>LSMinimumSystemVersion</key>\n    <string>" ++ min_system_version ++ "</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>NSHighResolutionCapable</key>\n    <true/>") != null);
    // Escaped title, in both name keys; raw specials must be gone.
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleName</key>\n    <string>Rock &amp; Roll &lt;Live&gt;</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleDisplayName</key>\n    <string>Rock &amp; Roll &lt;Live&gt;</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "Rock & Roll") == null);
    try testing.expect(std.mem.endsWith(u8, plist, "</dict>\n</plist>\n"));
}

test "renderInfoPlist omits CFBundleIconFile when there is no icon" {
    const a = testing.allocator;
    const plist = try renderInfoPlist(a, .{
        .bundle_id = "com.labelle.x",
        .name = "X",
        .display_name = "X",
        .executable = "x",
        .short_version = "0.1.0",
        .build_version = "0.1.0",
        .icon_file = null,
    });
    defer a.free(plist);
    try testing.expect(std.mem.indexOf(u8, plist, "CFBundleIconFile") == null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleExecutable</key>") != null);
}

test "iconset table is the ten iconutil names with sizes that match them" {
    try testing.expectEqual(@as(usize, 10), iconset_entries.len);
    try testing.expectEqual(@as(u32, 1024), iconset_max_px);
    var prev: u32 = 0;
    for (iconset_entries) |e| {
        // `icon_<n>x<n>[@2x].png`, with size == n or 2n.
        try testing.expect(std.mem.startsWith(u8, e.name, "icon_"));
        try testing.expect(std.mem.endsWith(u8, e.name, ".png"));
        const body = e.name["icon_".len .. e.name.len - ".png".len];
        const is_2x = std.mem.endsWith(u8, body, "@2x");
        const dims = if (is_2x) body[0 .. body.len - "@2x".len] else body;
        const x = std.mem.indexOfScalar(u8, dims, 'x') orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(dims[0..x], dims[x + 1 ..]);
        const nominal = try std.fmt.parseInt(u32, dims[0..x], 10);
        try testing.expectEqual(if (is_2x) nominal * 2 else nominal, e.size);
        // Non-decreasing so "largest = last" holds for iconset_max_px.
        try testing.expect(e.size >= prev);
        prev = e.size;
    }
}

test "scaleForEntry box-filters when shrinking and point-samples when enlarging" {
    const a = testing.allocator;
    // 2x2 of distinct colours.
    const src = [_]u8{
        0,   0,   0,   255, 100, 100, 100, 255,
        200, 200, 200, 255, 255, 255, 255, 255,
    };
    // Shrink to 1: the mean (box), not a corner.
    const down = try scaleForEntry(a, &src, 2, 2, 1);
    defer a.free(down);
    try testing.expectEqual(@as(u8, 139), down[0]);
    // Enlarge to 4: exact source colours only (nearest), no blends.
    const up = try scaleForEntry(a, &src, 2, 2, 4);
    defer a.free(up);
    for (0..16) |i| {
        const v = up[i * 4];
        try testing.expect(v == 0 or v == 100 or v == 200 or v == 255);
    }
    // Top-left block is the top-left source pixel, verbatim.
    try testing.expectEqualSlices(u8, src[0..4], up[0..4]);
    try testing.expectEqualSlices(u8, src[0..4], up[(1 * 4 + 1) * 4 ..][0..4]);
    // Equal size is "not upscaling" → box path, which is the identity here.
    const same = try scaleForEntry(a, &src, 2, 2, 2);
    defer a.free(same);
    try testing.expectEqualSlices(u8, &src, same);
}

test "writeIconset emits all ten PNGs at their sizes, upscaling a small master" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const work = ".zig-cache/bundle-iconset";
    cwd.deleteTree(io, work) catch {};
    defer cwd.deleteTree(io, work) catch {};
    const iconset = try std.fs.path.join(a, &.{ work, iconset_dir_name });
    defer a.free(iconset);

    // 48px master: below every @2x entry from 64 up, so most entries take
    // the nearest path; 16/32 take the box path.
    const src = try app_icon.gradientRgba(a, 48, 48);
    defer a.free(src);
    try writeIconset(a, iconset, src, 48, 48);

    for (iconset_entries) |e| {
        const path = try std.fs.path.join(a, &.{ iconset, e.name });
        defer a.free(path);
        const bytes = try cwd.readFileAlloc(io, path, a, .unlimited);
        defer a.free(bytes);
        const img = try app_icon.decodePng(bytes);
        defer img.free();
        try testing.expectEqual(@as(usize, e.size), img.width);
        try testing.expectEqual(@as(usize, e.size), img.height);
    }
}

test "resolveOutputDir: absolute passes through, relative anchors to the project, default is target zig-out" {
    const a = testing.allocator;
    const abs_in = if (builtin.os.tag == .windows) "C:\\dist" else "/dist";
    const abs = try resolveOutputDir(a, "/proj", "/proj/.labelle/bgfx_desktop", abs_in);
    defer a.free(abs);
    try testing.expectEqualStrings(abs_in, abs);

    const rel = try resolveOutputDir(a, "/proj", "/proj/.labelle/bgfx_desktop", "dist");
    defer a.free(rel);
    const want_rel = try std.fs.path.join(a, &.{ "/proj", "dist" });
    defer a.free(want_rel);
    try testing.expectEqualStrings(want_rel, rel);

    const def = try resolveOutputDir(a, "/proj", "/proj/.labelle/bgfx_desktop", null);
    defer a.free(def);
    const want_def = try std.fs.path.join(a, &.{ "/proj/.labelle/bgfx_desktop", "zig-out" });
    defer a.free(want_def);
    try testing.expectEqualStrings(want_def, def);
}

test "layoutBundle writes Contents/{MacOS/<exe>,Info.plist,PkgInfo,Resources/} and replaces a stale bundle" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const work = ".zig-cache/bundle-layout";
    cwd.deleteTree(io, work) catch {};
    defer cwd.deleteTree(io, work) catch {};
    try cwd.createDirPath(io, work);

    const exe_src = try std.fs.path.join(a, &.{ work, "my_game" });
    defer a.free(exe_src);
    try cwd.writeFile(io, .{ .sub_path = exe_src, .data = "#!/bin/sh\necho hi\n" });

    const want_bundle = try std.fs.path.join(a, &.{ work, "My Game.app" });
    defer a.free(want_bundle);
    // A stale file from a "previous" bundle with a different exe name.
    const stale_dir = try std.fs.path.join(a, &.{ want_bundle, "Contents", "MacOS" });
    defer a.free(stale_dir);
    try cwd.createDirPath(io, stale_dir);
    const stale = try std.fs.path.join(a, &.{ stale_dir, "game" });
    defer a.free(stale);
    try cwd.writeFile(io, .{ .sub_path = stale, .data = "old" });

    const bundle = try layoutBundle(a, work, "My Game.app", exe_src, "my_game", "<plist/>");
    defer a.free(bundle);
    try testing.expectEqualStrings(want_bundle, bundle);

    const exe_dst = try std.fs.path.join(a, &.{ bundle, "Contents", "MacOS", "my_game" });
    defer a.free(exe_dst);
    const copied = try cwd.readFileAlloc(io, exe_dst, a, .unlimited);
    defer a.free(copied);
    try testing.expectEqualStrings("#!/bin/sh\necho hi\n", copied);

    const plist_path = try std.fs.path.join(a, &.{ bundle, "Contents", "Info.plist" });
    defer a.free(plist_path);
    const plist = try cwd.readFileAlloc(io, plist_path, a, .unlimited);
    defer a.free(plist);
    try testing.expectEqualStrings("<plist/>", plist);

    const pkginfo_path = try std.fs.path.join(a, &.{ bundle, "Contents", "PkgInfo" });
    defer a.free(pkginfo_path);
    const pkginfo = try cwd.readFileAlloc(io, pkginfo_path, a, .unlimited);
    defer a.free(pkginfo);
    try testing.expectEqualStrings("APPL????", pkginfo);

    const resources = try std.fs.path.join(a, &.{ bundle, "Contents", "Resources" });
    defer a.free(resources);
    try testing.expect(util.dirExists(resources));

    // The stale exe from the previous layout is gone.
    try testing.expect(!util.fileExists(stale));
}

/// A fixture project + target dir with a fake built exe at
/// `<target>/zig-out/bin/<exe>`. Returns the work root; caller deletes.
fn bundleFixture(a: std.mem.Allocator, work: []const u8, exe: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, work) catch {};
    const bin = try std.fs.path.join(a, &.{ work, "target", "zig-out", "bin" });
    defer a.free(bin);
    try cwd.createDirPath(io, bin);
    const exe_path = try std.fs.path.join(a, &.{ bin, exe });
    defer a.free(exe_path);
    try cwd.writeFile(io, .{ .sub_path = exe_path, .data = "ELF-ish" });
}

/// Set a file's mtime to an explicit instant so ordering in tests does
/// not depend on filesystem timestamp granularity.
fn setMtime(path: []const u8, nanoseconds: i96) !void {
    const io = config.globalIo();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = nanoseconds } } });
}

test "resolveBuiltExe prefers the exe the generated build.zig declares, even if a stale one is newer" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-exe-declared";
    try bundleFixture(a, work, "my_game");
    defer cwd.deleteTree(io, work) catch {};
    const target = try std.fs.path.join(a, &.{ work, "target" });
    defer a.free(target);
    // A second, NEWER candidate that the current build.zig does not name.
    const legacy = try std.fs.path.join(a, &.{ target, "zig-out", "bin", "game" });
    defer a.free(legacy);
    try cwd.writeFile(io, .{ .sub_path = legacy, .data = "stale legacy" });
    const named = try std.fs.path.join(a, &.{ target, "zig-out", "bin", "my_game" });
    defer a.free(named);
    try setMtime(named, 1_000_000_000_000_000_000);
    try setMtime(legacy, 1_000_000_000_000_000_000 + 100 * std.time.ns_per_s);
    const build_zig = try std.fs.path.join(a, &.{ target, "build.zig" });
    defer a.free(build_zig);
    try cwd.writeFile(io, .{ .sub_path = build_zig, .data = "const exe = b.addExecutable(.{ .name = \"my_game\", .root_module = m });" });

    const exe = try resolveBuiltExe(a, target, "my_game");
    defer exe.deinit(a);
    try testing.expectEqualStrings("my_game", exe.name);
    try testing.expectEqualStrings(named, exe.path);
}

test "resolveBuiltExe falls back to the most recently modified candidate (Codex on #362)" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-exe-newest";
    try bundleFixture(a, work, "my_game");
    defer cwd.deleteTree(io, work) catch {};
    const target = try std.fs.path.join(a, &.{ work, "target" });
    defer a.free(target);
    const legacy = try std.fs.path.join(a, &.{ target, "zig-out", "bin", "game" });
    defer a.free(legacy);
    try cwd.writeFile(io, .{ .sub_path = legacy, .data = "fresh legacy build" });
    const named = try std.fs.path.join(a, &.{ target, "zig-out", "bin", "my_game" });
    defer a.free(named);
    // The legacy-assembler scenario: `my_game` is a leftover from an earlier
    // build, `game` is what the build that just ran wrote. No build.zig to
    // consult (or one naming a binary that isn't there) → newest wins.
    try setMtime(named, 1_000_000_000_000_000_000);
    try setMtime(legacy, 1_000_000_000_000_000_000 + 100 * std.time.ns_per_s);

    const exe = try resolveBuiltExe(a, target, "my_game");
    defer exe.deinit(a);
    try testing.expectEqualStrings("game", exe.name);

    // build.zig names something the build never produced → same fallback.
    const build_zig = try std.fs.path.join(a, &.{ target, "build.zig" });
    defer a.free(build_zig);
    try cwd.writeFile(io, .{ .sub_path = build_zig, .data = "b.addExecutable(.{ .name = \"renamed\", .root_module = m })" });
    const exe2 = try resolveBuiltExe(a, target, "my_game");
    defer exe2.deinit(a);
    try testing.expectEqualStrings("game", exe2.name);

    // And the reverse ordering picks the sanitized name.
    try setMtime(named, 1_000_000_000_000_000_000 + 200 * std.time.ns_per_s);
    cwd.deleteFile(io, build_zig) catch {};
    const exe3 = try resolveBuiltExe(a, target, "my_game");
    defer exe3.deinit(a);
    try testing.expectEqualStrings("my_game", exe3.name);
}

test "resolveBuiltExe errors when no candidate exists" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-exe-none";
    cwd.deleteTree(io, work) catch {};
    defer cwd.deleteTree(io, work) catch {};
    try cwd.createDirPath(io, work);
    try testing.expectError(error.BinaryNotFound, resolveBuiltExe(a, work, "my_game"));
}

test "createFromBuild fails loudly on a missing custom icon before writing anything" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-missing-icon";
    try bundleFixture(a, work, "my_game");
    defer cwd.deleteTree(io, work) catch {};
    const target = try std.fs.path.join(a, &.{ work, "target" });
    defer a.free(target);

    const cfg = project_config.ProjectConfig{ .name = "my_game", .title = "My Game", .app_icon = "art/nope.png" };
    try testing.expectError(error.AppIconNotFound, createFromBuild(a, work, target, cfg, null));

    // Precedence: the custom path is fatal even though nothing else is
    // wrong — and no half-written bundle is left behind.
    const bundle = try std.fs.path.join(a, &.{ target, "zig-out", "My Game.app" });
    defer a.free(bundle);
    try testing.expect(!util.dirExists(bundle));
}

test "createFromBuild without any icon still produces a launchable bundle whose plist has no icon key" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-no-icon";
    try bundleFixture(a, work, "my_game");
    defer cwd.deleteTree(io, work) catch {};
    const target = try std.fs.path.join(a, &.{ work, "target" });
    defer a.free(target);

    // No `.app_icon`, and the fixture target has no default_icon.png —
    // the "older assembler" case: degrade, don't fail. No iconutil spawn
    // happens on this path, which is what lets it run on Linux/Windows CI.
    const cfg = project_config.ProjectConfig{ .name = "my_game", .title = "My Game", .version = "2.0.1" };
    const bundle = try createFromBuild(a, work, target, cfg, "dist");
    defer a.free(bundle);

    const want = try std.fs.path.join(a, &.{ work, "dist", "My Game.app" });
    defer a.free(want);
    try testing.expectEqualStrings(want, bundle);

    const exe = try std.fs.path.join(a, &.{ bundle, "Contents", "MacOS", "my_game" });
    defer a.free(exe);
    try testing.expect(util.fileExists(exe));

    const plist_path = try std.fs.path.join(a, &.{ bundle, "Contents", "Info.plist" });
    defer a.free(plist_path);
    const plist = try cwd.readFileAlloc(io, plist_path, a, .unlimited);
    defer a.free(plist);
    try testing.expect(std.mem.indexOf(u8, plist, "CFBundleIconFile") == null);
    try testing.expect(std.mem.indexOf(u8, plist, "<string>com.labelle.my-game</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<string>My Game</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<string>2.0.1</string>") != null);

    const icns = try std.fs.path.join(a, &.{ bundle, "Contents", "Resources", icns_name });
    defer a.free(icns);
    try testing.expect(!util.fileExists(icns));
}

test "createFromBuild gives a dots-only title the project name as its Dock label and normalizes the version" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-dots-title";
    try bundleFixture(a, work, "my_game");
    defer cwd.deleteTree(io, work) catch {};
    const target = try std.fs.path.join(a, &.{ work, "target" });
    defer a.free(target);

    const cfg = project_config.ProjectConfig{ .name = "my_game", .title = "...", .version = "1.2.3-beta" };
    const bundle = try createFromBuild(a, work, target, cfg, null);
    defer a.free(bundle);
    try testing.expect(std.mem.endsWith(u8, bundle, "my_game.app"));

    const plist_path = try std.fs.path.join(a, &.{ bundle, "Contents", "Info.plist" });
    defer a.free(plist_path);
    const plist = try cwd.readFileAlloc(io, plist_path, a, .unlimited);
    defer a.free(plist);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleDisplayName</key>\n    <string>my_game</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleName</key>\n    <string>my_game</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleShortVersionString</key>\n    <string>1.2.3</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleVersion</key>\n    <string>1.2.3</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "beta") == null);
    try testing.expect(std.mem.indexOf(u8, plist, "<string>...</string>") == null);
}

test "createFromBuild falls back to the legacy `game` exe name" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-legacy-exe";
    try bundleFixture(a, work, "game");
    defer cwd.deleteTree(io, work) catch {};
    const target = try std.fs.path.join(a, &.{ work, "target" });
    defer a.free(target);

    const cfg = project_config.ProjectConfig{ .name = "my_game", .title = "My Game" };
    const bundle = try createFromBuild(a, work, target, cfg, null);
    defer a.free(bundle);

    const exe = try std.fs.path.join(a, &.{ bundle, "Contents", "MacOS", "game" });
    defer a.free(exe);
    try testing.expect(util.fileExists(exe));
    const plist_path = try std.fs.path.join(a, &.{ bundle, "Contents", "Info.plist" });
    defer a.free(plist_path);
    const plist = try cwd.readFileAlloc(io, plist_path, a, .unlimited);
    defer a.free(plist);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleExecutable</key>\n    <string>game</string>") != null);
}
