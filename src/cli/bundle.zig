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
//!         MacOS/<exe>                 POSIX sh launcher, see `renderLauncher`
//!         MacOS/<exe>-bin             copy of zig-out/bin/<exe>, mode preserved
//!         Resources/AppIcon.icns      from the resolved icon PNG, via iconutil
//!         Resources/assets/           copy of the project's `assets/` tree
//!
//! `<out>` defaults to the target dir's `zig-out/` (next to `bin/`), or
//! `--output <dir>`. The exe keeps the name the generated build.zig
//! produced (`util.sanitizeExeName(project.name)`, labelle-assembler#362)
//! so `CFBundleExecutable` and `pgrep -f <name>` agree with `labelle run`.
//!
//! ## Runtime layout (cli#364)
//!
//! A `.app` launched by LaunchServices (Finder, Dock, `open`) starts with
//! cwd `/`. The generated game still resolves some runtime files RELATIVE
//! TO CWD: labelle-bgfx streams video from `assets/<name>` (it is not
//! `@embedFile`d), the engine's save/load mixin writes save files to a
//! cwd-relative path, and games write `saves/` / `snapshots/` the same
//! way (flying-platform-labelle#773). `labelle run` hides all of this by
//! spawning the exe with cwd = the generated target dir, where the
//! assembler left `assets -> ../../assets` (and `scenes/`, `prefabs/`, …)
//! as relative symlinks into the project. Scenes and prefabs are
//! unconditionally embedded (`addEmbeddedSceneSource` /
//! `addEmbeddedPrefab`, engine 2.x) so only `assets/` needs to travel.
//!
//! The bundle reproduces that layout: `assets/` is copied into
//! `Contents/Resources/` and `CFBundleExecutable` names a two-line
//! `sh` launcher that `cd`s into `Contents/Resources` and `exec`s the
//! real Mach-O beside it (`<exe>-bin`). LaunchServices is fine with a
//! script executable; AppKit still finds the bundle from the Mach-O's
//! path, so the Dock icon and name are unaffected. No engine change is
//! needed — once the engine grows an asset root (`LABELLE_ASSET_ROOT`-
//! style, issue #364 option 2) the script can go away. The launcher also
//! exports `LABELLE_DATA_DIR` (a per-user writable dir) so the game can
//! stop writing saves next to a read-only installed bundle once it
//! adopts the variable; it does NOT do so yet (#773).
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

/// Suffix of the real Mach-O inside `Contents/MacOS/`; `<exe>` itself is
/// the launcher script (cli#364, see the module doc).
pub const bin_suffix = "-bin";
/// Env var the launcher exports for writable per-user data. The game does
/// not read it yet (flying-platform-labelle#773); exported so it can.
pub const data_dir_env = "LABELLE_DATA_DIR";
/// Project subtree staged into `Contents/Resources/` — the one tree the
/// game reads from disk at runtime (streamed video; see module doc).
pub const assets_dir_name = "assets";
/// Bound on directory nesting while staging `assets/`. Symlinked
/// directories are FOLLOWED (a shared-art link must land as real files or
/// it dangles inside the bundle), so a link cycle would recurse forever;
/// any real asset tree is far shallower than this.
pub const max_stage_depth: u32 = 32;

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

/// `CFBundleVersion` — the BUILD number, distinct from the marketing
/// version: Apple only requires it to be period-separated integers with
/// a POSITIVE first component (and monotonic across releases), not to
/// equal `CFBundleShortVersionString`. A pre-1.0 project — `0.1.0` is
/// the `ProjectConfig` default and what flying-platform ships — would
/// fail validation with a leading zero (Codex on #362), so when the
/// marketing major is 0 the build number is written as `1.<minor>.<patch>`
/// (`0.1.0` → `1.1.0`, `0.0.7` → `1.0.7`); a positive major passes
/// through unchanged (`2.3.4` → `2.3.4`). Deterministic and documented
/// rather than clever: the value is only ever compared against itself
/// across builds of the same project. Caller owns the slice.
pub fn buildVersion(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const marketing = plistVersion(version);
    const first_end = std.mem.indexOfScalar(u8, marketing, '.') orelse marketing.len;
    const first = marketing[0..first_end];
    // `plistVersion` guarantees `first` is a non-empty digit run.
    var all_zero = true;
    for (first) |ch| {
        if (ch != '0') all_zero = false;
    }
    if (!all_zero) return allocator.dupe(u8, marketing);
    return std.fmt.allocPrint(allocator, "1{s}", .{marketing[first_end..]});
}

/// Validate `s` as UTF-8 and strip the code points XML 1.0 forbids in
/// character data — C0 controls other than TAB/LF/CR, and U+FFFE/U+FFFF
/// — so a ZON escape like `\x01` in a title can't produce an
/// `Info.plist` that is not well-formed (Codex on #362: escaping the
/// five markup characters alone is not enough). Returns null for
/// invalid UTF-8 (the caller decides between fallback and error); the
/// returned slice is owned by the caller. Surrogates never appear in
/// valid UTF-8, so they need no separate check.
pub fn sanitizePlistString(allocator: std.mem.Allocator, s: []const u8) !?[]u8 {
    const view = std.unicode.Utf8View.init(s) catch return null;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return null;
        const forbidden = (cp < 0x20 and cp != '\t' and cp != '\n' and cp != '\r') or cp == 0xFFFE or cp == 0xFFFF;
        if (forbidden) continue;
        try buf.appendSlice(allocator, slice);
    }
    return try buf.toOwnedSlice(allocator);
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

/// Turn `s` into well-formed plist text: validate/sanitize it first
/// (`sanitizePlistString` — invalid UTF-8 is `error.InvalidBundleMetadata`
/// here because by this point the caller has already applied its
/// fallbacks), THEN escape the five markup specials so a title like
/// `Rock & Roll` produces a plist `plutil -lint` accepts. Every string
/// `renderInfoPlist` writes goes through this, so no field can smuggle a
/// forbidden byte in. Caller owns the slice.
pub fn escapeXml(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const s = (try sanitizePlistString(allocator, raw)) orelse return error.InvalidBundleMetadata;
    defer allocator.free(s);
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

/// `child` is `parent` itself or lies below it. A plain prefix test is not
/// enough: `assets-dist` starts with `assets` but is a sibling, so the
/// match must end at a path separator (or `parent` must already end in one,
/// e.g. a filesystem root).
pub fn pathIsWithin(child: []const u8, parent: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    if (parent.len > 0 and std.fs.path.isSep(parent[parent.len - 1])) return true;
    return std.fs.path.isSep(child[parent.len]);
}

/// Refuse an output placement that would make the assets copy feed on
/// itself (Codex on #366). `--output assets/dist` puts `<Title>.app` INSIDE
/// `<project>/assets/`, so `stageAssets` would descend into the bundle it
/// is filling and fail with `AssetTreeTooDeep` — after `layoutBundle` had
/// already wiped the previous bundle. The inverse — the project's `assets/`
/// living under `<out>/<Title>.app` — would have that wipe delete the
/// project's assets. Both are compared as REAL paths (symlinks resolved;
/// `out_dir` exists by the time this runs, `assets/` may not — then there
/// is nothing to overlap) with the separator-aware `pathIsWithin`, and
/// the check runs BEFORE anything is deleted.
pub fn checkAssetsOverlap(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    out_dir: []const u8,
    dir_name: []const u8,
) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const assets = try std.fs.path.join(allocator, &.{ project_dir, assets_dir_name });
    defer allocator.free(assets);
    const assets_real = cwd.realPathFileAlloc(io, assets, allocator) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer allocator.free(assets_real);
    const out_real = try cwd.realPathFileAlloc(io, out_dir, allocator);
    defer allocator.free(out_real);

    if (pathIsWithin(out_real, assets_real)) {
        std.debug.print("labelle bundle: --output '{s}' is inside the project's {s}/ — the bundle would copy itself into itself\n  choose a directory outside {s}/, e.g. --output ./dist\n", .{ out_dir, assets_dir_name, assets_dir_name });
        return error.OutputInsideAssets;
    }
    const bundle_real = try std.fs.path.join(allocator, &.{ out_real, dir_name });
    defer allocator.free(bundle_real);
    if (pathIsWithin(assets_real, bundle_real)) {
        std.debug.print("labelle bundle: the project's {s}/ lies inside '{s}', which the bundle step replaces — refusing\n", .{ assets_dir_name, bundle_real });
        return error.AssetsInsideBundle;
    }
}

/// Name of the real Mach-O beside the launcher: `<exe>-bin`. Caller owns.
pub fn binName(allocator: std.mem.Allocator, exe_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ exe_name, bin_suffix });
}

/// Render the `Contents/MacOS/<exe>` launcher script (cli#364).
///
/// Why a script and not a chdir in the game: LaunchServices starts every
/// `.app` with cwd `/`, and the game resolves streamed video, saves and
/// snapshots relative to cwd (see the module doc). `labelle run` gives it
/// cwd = target dir where `assets/` is a symlink into the project; the
/// launcher gives it cwd = `Contents/Resources` where `assets/` was
/// staged. That reproduces the working layout with zero engine/assembler
/// changes and keeps `pgrep -f <exe>` working (the Mach-O is `<exe>-bin`).
/// When the engine grows an asset root the script becomes redundant.
///
/// It also (a) exports `LABELLE_DATA_DIR` = `~/Library/Application
/// Support/<bundle-id>` and creates it — an installed bundle is read-only
/// so saves must not land beside the assets; the game has to start
/// honouring it (flying-platform-labelle#773), this only makes the target
/// available — and (b) appends the Homebrew prefixes to `PATH`: apps get
/// the launchd default `/usr/bin:/bin:/usr/sbin:/sbin`, and labelle-bgfx's
/// desktop video path shells out to `ffmpeg`/`ffprobe` via `popen`, so a
/// Finder launch would otherwise fail to play video that a terminal
/// launch plays (ffmpeg is a system dependency, not shipped in the app).
///
/// `exe_name` is single-quoted so a name with spaces or shell specials
/// stays one word; `bundle_id` is `[A-Za-z0-9-.]` by construction
/// (`deriveBundleId`) but is quoted the same way. Caller owns the slice.
pub fn renderLauncher(allocator: std.mem.Allocator, exe_name: []const u8, bundle_id: []const u8) ![]u8 {
    const bin = try binName(allocator, exe_name);
    defer allocator.free(bin);
    const bin_q = try shellSingleQuote(allocator, bin);
    defer allocator.free(bin_q);
    const id_q = try shellSingleQuote(allocator, bundle_id);
    defer allocator.free(id_q);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(
        \\#!/bin/sh
        \\# Launcher generated by `labelle bundle` (labelle-cli#364) -- do not edit.
        \\#
        \\# LaunchServices (Finder, Dock, `open`) starts a .app with cwd "/", but the
        \\# game resolves some runtime files RELATIVE TO CWD -- streamed video under
        \\# assets/, saves/, snapshots/ -- exactly as `labelle run` does from the
        \\# generated target dir, where assets/ is a symlink into the project. This
        \\# script re-creates that layout: cwd = Contents/Resources (where `labelle
        \\# bundle` staged assets/), then exec the real Mach-O beside this script.
        \\# A future engine-side asset root (LABELLE_ASSET_ROOT-style) would let the
        \\# game resolve against the bundle itself and retire this script.
        \\here=$(cd "$(dirname "$0")" && pwd)
        \\
        \\# Writable per-user data. An installed bundle (/Applications) is read-only,
        \\# so saves/snapshots must NOT land next to the assets. The game does not
        \\# honour this yet (flying-platform-labelle#773) -- it is exported so it can.
        \\if [ -n "$HOME" ]; then
        \\
    );
    try w.print("    {s}=\"$HOME/Library/Application Support\"/{s}\n", .{ data_dir_env, id_q });
    try w.print("    mkdir -p \"${s}\" 2>/dev/null\n", .{data_dir_env});
    try w.print("    export {s}\n", .{data_dir_env});
    try w.writeAll(
        \\fi
        \\
        \\# LaunchServices hands apps a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin).
        \\# The bgfx desktop video path shells out to ffmpeg/ffprobe, which Homebrew
        \\# installs under /opt/homebrew/bin or /usr/local/bin -- append them so a
        \\# Finder launch finds the same tools a terminal launch does.
        \\PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
        \\export PATH
        \\
        \\
    );
    try w.print("cd \"$here/../Resources\" && exec \"$here\"/{s} \"$@\"\n", .{bin_q});
    return aw.toOwnedSlice();
}

/// What `stageAssets` copied, for the summary line.
pub const StageReport = struct {
    files: usize = 0,
    bytes: u64 = 0,
};

/// Copy `<project_dir>/assets/` into `<bundle_dir>/Contents/Resources/assets/`
/// (cli#364). Returns null when the project has no `assets/` (a legal
/// project; nothing to stage). Every regular file is copied byte for byte
/// with its permissions; symlinks are FOLLOWED — a file link becomes a
/// real file, a directory link is descended — because a relative link
/// copied verbatim would dangle inside the bundle (the very failure this
/// fixes). A dangling source link is skipped with a warning; any other
/// stat failure propagates (see `resolveProbedKind`).
///
/// Two kinds of directory link are NOT followed, each skipped with a
/// warning that names the link (Codex on #366): one whose canonical
/// target lies in the bundle output — `assets/generated -> ../dist` with
/// `--output dist` would otherwise walk into the `.app` being filled and
/// die at the depth cap after the previous bundle was wiped — and one
/// that points at an ancestor of itself (`assets/loop -> .`), a cycle.
/// "Bundle output" is `<out>` itself, except when `<out>` is an ancestor
/// of `assets/` (`--output .`) where only `<out>/<Title>.app` is
/// off-limits — a link to a sibling of `assets/` is a real asset there.
/// `checkAssetsOverlap` stays the pre-flight for the two ROOTS; this is
/// the per-entry guard for what links can reach. As a last net every
/// directory's canonical path is checked against the bundle before
/// descending, whatever route led to it.
///
/// Everything is copied. The project has no manifest that separates
/// `@embedFile`d assets from runtime-streamed ones (the atlases here are
/// embedded twice over, on FP ~35 MB in total), and a wrongly skipped
/// file is a broken game while a redundant one is disk — correctness
/// beats size. A manifest-driven trim is a follow-up.
pub fn stageAssets(allocator: std.mem.Allocator, project_dir: []const u8, bundle_dir: []const u8) !?StageReport {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const src = try std.fs.path.join(allocator, &.{ project_dir, assets_dir_name });
    defer allocator.free(src);
    if (!util.dirExists(src)) return null;
    const dst = try std.fs.path.join(allocator, &.{ bundle_dir, "Contents", "Resources", assets_dir_name });
    defer allocator.free(dst);

    // Canonical roots, computed once and threaded through the walk.
    const src_real = try cwd.realPathFileAlloc(io, src, allocator);
    defer allocator.free(src_real);
    const out_dir = std.fs.path.dirname(bundle_dir) orelse ".";
    const out_real = try cwd.realPathFileAlloc(io, out_dir, allocator);
    defer allocator.free(out_real);
    const bundle_real = try std.fs.path.join(allocator, &.{ out_real, std.fs.path.basename(bundle_dir) });
    defer allocator.free(bundle_real);

    var ctx = StageCtx{
        .allocator = allocator,
        .io = io,
        .cwd = cwd,
        .bundle_real = bundle_real,
        .forbidden_root = if (pathIsWithin(src_real, out_real)) bundle_real else out_real,
    };
    try copyTreeFollowingLinks(&ctx, src, src_real, dst, 0);
    return ctx.report;
}

/// Per-walk state for `copyTreeFollowingLinks`, so the canonical roots are
/// resolved once rather than per entry.
const StageCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    /// Canonical `<out>/<Title>.app`. No directory below it is ever descended.
    bundle_real: []const u8,
    /// Canonical root a directory LINK may not resolve into: `<out>`, or
    /// `bundle_real` when `<out>` is an ancestor of `assets/` itself.
    forbidden_root: []const u8,
    report: StageReport = .{},
};

/// Entry kinds the directory listing cannot be trusted on: a symlink
/// (we copy what it points at) and `.unknown` (the filesystem gave no
/// type). Both go through a follow-`statFile` before dispatch.
pub fn needsStat(kind: std.Io.File.Kind) bool {
    return kind == .sym_link or kind == .unknown;
}

/// Classify the outcome of that follow-stat. `null` = the target does not
/// exist (a dangling link: skip it, nothing to copy). Every other error is
/// returned as-is: an unreadable or unmountable target is not "nothing to
/// copy", it is a bundle we cannot complete, and the caller's `errdefer`
/// must get to remove it. Kept separate from the I/O so the policy is
/// unit-testable with injected errors.
pub fn resolveProbedKind(probe: anyerror!std.Io.File.Kind) anyerror!?std.Io.File.Kind {
    const kind = probe catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return kind;
}

/// Why a directory reached through a link is not descended. Pure decision
/// over canonical paths so it is unit-testable without a filesystem.
pub const LinkVerdict = enum { follow, into_output, cycle };

/// `target_real` is the link's canonical target, `dir_real` the canonical
/// directory the link sits in. A target inside the forbidden output root
/// can never be a real asset (the bundle must not contain itself); a
/// target that is `dir_real` or an ancestor of it is a cycle the walk
/// would otherwise unroll until the depth cap.
pub fn linkVerdict(target_real: []const u8, dir_real: []const u8, forbidden_root: []const u8) LinkVerdict {
    if (pathIsWithin(target_real, forbidden_root)) return .into_output;
    if (pathIsWithin(dir_real, target_real)) return .cycle;
    return .follow;
}

/// `src_real` is the canonical path of `src`; a real (non-link) child
/// directory's canonical path is then just `src_real/<name>`, so only
/// links and `.unknown` entries pay for a `realPath`.
fn copyTreeFollowingLinks(
    ctx: *StageCtx,
    src: []const u8,
    src_real: []const u8,
    dst: []const u8,
    depth: u32,
) !void {
    if (depth > max_stage_depth) {
        std.debug.print("labelle bundle: assets/ nests deeper than {d} levels at '{s}' — symlink cycle?\n", .{ max_stage_depth, src });
        return error.AssetTreeTooDeep;
    }
    const allocator = ctx.allocator;
    const io = ctx.io;
    const cwd = ctx.cwd;
    try cwd.createDirPath(io, dst);

    var dir = try cwd.openDir(io, src, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const src_sub = try std.fs.path.join(allocator, &.{ src, entry.name });
        defer allocator.free(src_sub);
        const dst_sub = try std.fs.path.join(allocator, &.{ dst, entry.name });
        defer allocator.free(dst_sub);

        // A symlink is resolved to what it points at, and so is `.unknown`
        // (NFS/SMB/FUSE enumerations may report no type at all — dropping
        // those would silently ship a partial tree). `statFile` follows
        // links, so a MISSING target is the one skippable outcome; any
        // other failure (permissions, I/O) propagates so `createFromBuild`
        // tears the half-built bundle down (Codex/CodeRabbit on #366).
        const via_link = needsStat(entry.kind);
        const kind: std.Io.File.Kind = if (via_link) blk: {
            const probe: anyerror!std.Io.File.Kind = if (cwd.statFile(io, src_sub, .{})) |st| st.kind else |err| err;
            break :blk (try resolveProbedKind(probe)) orelse {
                std.debug.print("labelle bundle: skipping dangling symlink '{s}' in assets/\n", .{src_sub});
                continue;
            };
        } else entry.kind;

        switch (kind) {
            .directory => {
                // `realPathFileAlloc` hands back a `[:0]u8` whose allocation
                // is len+1; it must be freed under that type or the
                // allocator sees a size mismatch (see assembler.zig).
                const real_z: ?[:0]u8 = if (via_link) try cwd.realPathFileAlloc(io, src_sub, allocator) else null;
                defer if (real_z) |z| allocator.free(z);
                const joined: ?[]u8 = if (via_link) null else try std.fs.path.join(allocator, &.{ src_real, entry.name });
                defer if (joined) |j| allocator.free(j);
                const child_real: []const u8 = if (real_z) |z| z else joined.?;
                if (via_link) switch (linkVerdict(child_real, src_real, ctx.forbidden_root)) {
                    .follow => {},
                    .into_output => {
                        std.debug.print("labelle bundle: skipping '{s}' -> '{s}': it resolves into the bundle output, which cannot be an asset\n", .{ src_sub, child_real });
                        continue;
                    },
                    .cycle => {
                        std.debug.print("labelle bundle: skipping '{s}' -> '{s}': symlink cycle (points at an ancestor of itself)\n", .{ src_sub, child_real });
                        continue;
                    },
                };
                // Last net for any route that lands in the bundle itself.
                if (pathIsWithin(child_real, ctx.bundle_real)) {
                    std.debug.print("labelle bundle: skipping '{s}': it is the bundle being built\n", .{src_sub});
                    continue;
                }
                try copyTreeFollowingLinks(ctx, src_sub, child_real, dst_sub, depth + 1);
            },
            .file => {
                try cwd.copyFile(src_sub, cwd, dst_sub, io, .{});
                ctx.report.files += 1;
                const st = cwd.statFile(io, dst_sub, .{}) catch continue;
                ctx.report.bytes += st.size;
            },
            else => {},
        }
    }
}

/// Lay the bundle skeleton down at `<out_dir>/<dir_name>`: dirs, the
/// launcher, the exe copy, `Info.plist`, `PkgInfo`. Wipes any previous
/// bundle there first so a renamed exe or a removed icon can't leave
/// stale files behind. Filesystem-only (no Apple tools), so it is
/// unit-tested everywhere.
///
/// The wipe is the ONLY recursive delete `labelle bundle` performs under
/// a user-chosen directory, so it is guarded twice: `bundleDirName`
/// only ever produces a safe component, and this refuses
/// (`error.UnsafeBundleName`) any `dir_name` that is not a bare
/// `<x>.app` — a caller bug can then not turn into `rm -rf <out>/..`.
///
/// `MacOS/<exe_name>` receives `launcher` (mode 0755; the plist's
/// `CFBundleExecutable` names it) and the built exe lands beside it as
/// `MacOS/<exe_name>-bin` (cli#364). `copyFile` with default options
/// copies the source's permissions, so the exec bit survives without a
/// `chmod` spawn (`ios.zig` predates that option and still shells out).
/// Returns the caller-owned bundle path.
pub fn layoutBundle(
    allocator: std.mem.Allocator,
    out_dir: []const u8,
    dir_name: []const u8,
    exe_src: []const u8,
    exe_name: []const u8,
    launcher: []const u8,
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

    const bin = try binName(allocator, exe_name);
    defer allocator.free(bin);
    const exe_dst = try std.fs.path.join(allocator, &.{ macos_dir, bin });
    defer allocator.free(exe_dst);
    try cwd.copyFile(exe_src, cwd, exe_dst, io, .{});

    // The launcher must be executable or LaunchServices reports the app
    // as damaged. Windows has no mode bits (and no `.fromMode`); the
    // bundle is never launched there, only laid out by tests.
    const launcher_dst = try std.fs.path.join(allocator, &.{ macos_dir, exe_name });
    defer allocator.free(launcher_dst);
    const launcher_flags: std.Io.Dir.CreateFileOptions = if (builtin.os.tag == .windows) .{} else .{ .permissions = .fromMode(0o755) };
    try cwd.writeFile(io, .{ .sub_path = launcher_dst, .data = launcher, .flags = launcher_flags });

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
    // Metadata hygiene (Codex on #362): the plist must be well-formed XML
    // and the label must agree with the file name. A title that is not
    // valid UTF-8 is treated as unusable — it falls back to `.name`, for
    // BOTH the bundle dir and the Dock label — while a `.name` that is
    // not valid UTF-8 has nowhere left to fall back to and is an error.
    const safe_title_opt = try sanitizePlistString(allocator, cfg.title);
    defer if (safe_title_opt) |t| allocator.free(t);
    const safe_title: []const u8 = safe_title_opt orelse "";
    const safe_name = (try sanitizePlistString(allocator, cfg.name)) orelse {
        std.debug.print("labelle bundle: project .name is not valid UTF-8 — cannot name the bundle\n", .{});
        return error.InvalidBundleMetadata;
    };
    defer allocator.free(safe_name);
    const dir_name = try bundleDirName(allocator, safe_title, safe_name);
    defer allocator.free(dir_name);
    // Before anything is wiped: the assets copy must not overlap the
    // bundle in either direction (cli#364 staging, Codex on #366).
    try checkAssetsOverlap(allocator, project_dir, out_dir, dir_name);

    // 4. Skeleton + exe. The plist is rendered knowing whether an icon
    //    will land; the .icns itself is built right after.
    const bundle_id = try deriveBundleId(allocator, cfg.name);
    defer allocator.free(bundle_id);
    const display = displayName(safe_title, safe_name);
    const build_ver = try buildVersion(allocator, cfg.version);
    defer allocator.free(build_ver);
    const has_icon = maybe_img != null;
    const plist = try renderInfoPlist(allocator, .{
        .bundle_id = bundle_id,
        .name = display,
        .display_name = display,
        .executable = exe_name,
        .short_version = plistVersion(cfg.version),
        .build_version = build_ver,
        .icon_file = if (has_icon) icon_file_key else null,
    });
    defer allocator.free(plist);
    const launcher = try renderLauncher(allocator, exe_name, bundle_id);
    defer allocator.free(launcher);
    const bundle_dir = try layoutBundle(allocator, out_dir, dir_name, exe_src, exe_name, launcher, plist);
    errdefer allocator.free(bundle_dir);
    // A bundle whose plist names an `.icns` that never landed shows the
    // broken-document glyph — worse than no bundle, and one missing half
    // its assets is the bug this fixes (cli#364). If anything below
    // fails, take the skeleton down with it.
    errdefer cwd.deleteTree(io, bundle_dir) catch {};

    // 4b. Runtime-read project files (cli#364): `assets/` → Resources/,
    //     the tree the launcher makes cwd. Read the project's, not the
    //     target dir's — there it is a symlink back into the project.
    if (try stageAssets(allocator, project_dir, bundle_dir)) |staged| {
        std.debug.print("labelle: staged {s}/ into Contents/Resources ({d} files, {d} KiB)\n", .{ assets_dir_name, staged.files, staged.bytes / 1024 });
    } else {
        std.debug.print("labelle: project has no {s}/ — nothing to stage into Contents/Resources\n", .{assets_dir_name});
    }

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

    try testing.expectError(error.UnsafeBundleName, layoutBundle(a, out, "../Saved.app", exe_src, "exe", "#!/bin/sh\n", "<plist/>"));
    try testing.expectError(error.UnsafeBundleName, layoutBundle(a, out, "Saved", exe_src, "exe", "#!/bin/sh\n", "<plist/>"));
    try testing.expectError(error.UnsafeBundleName, layoutBundle(a, out, ".app", exe_src, "exe", "#!/bin/sh\n", "<plist/>"));
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

test "buildVersion gives CFBundleVersion a positive first component, leaves the rest alone" {
    const a = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "0.1.0", "1.1.0" },
        .{ "0.0.7", "1.0.7" },
        .{ "0", "1" },
        .{ "00.2", "1.2" },
        .{ "2.3.4", "2.3.4" },
        .{ "1.2.3-beta", "1.2.3" },
        .{ "", "1.0" },
    };
    for (cases) |c| {
        const got = try buildVersion(a, c[0]);
        defer a.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
    // The marketing version is untouched: 0.1.0 stays 0.1.0 there.
    try testing.expectEqualStrings("0.1.0", plistVersion("0.1.0"));
}

test "sanitizePlistString drops XML-forbidden code points and rejects invalid UTF-8" {
    const a = testing.allocator;
    const ctrl = (try sanitizePlistString(a, "a\x01b\x7fc\td\n")).?;
    defer a.free(ctrl);
    // \x01 gone; DEL, TAB and LF are legal XML chars and stay.
    try testing.expectEqualStrings("ab\x7fc\td\n", ctrl);
    const nonchar = (try sanitizePlistString(a, "x\u{FFFE}y\u{FFFF}z\u{FFFD}")).?;
    defer a.free(nonchar);
    try testing.expectEqualStrings("xyz\u{FFFD}", nonchar);
    const unicode = (try sanitizePlistString(a, "Vol\u{E9} \u{1F600}")).?;
    defer a.free(unicode);
    try testing.expectEqualStrings("Vol\u{E9} \u{1F600}", unicode);
    try testing.expect((try sanitizePlistString(a, "Fl\xffying")) == null);
    try testing.expect((try sanitizePlistString(a, "\xc3")) == null); // truncated sequence
}

test "renderInfoPlist strips forbidden bytes from every field and rejects invalid UTF-8" {
    const a = testing.allocator;
    const plist = try renderInfoPlist(a, .{
        .bundle_id = "com.labelle.x",
        .name = "Bad\x01Title",
        .display_name = "Bad\x01Title",
        .executable = "x\x02",
        .short_version = "1.0",
        .build_version = "1.0",
    });
    defer a.free(plist);
    try testing.expect(std.mem.indexOf(u8, plist, "<string>BadTitle</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<string>x</string>") != null);
    try testing.expect(std.mem.indexOfScalar(u8, plist, 0x01) == null);
    try testing.expect(std.mem.indexOfScalar(u8, plist, 0x02) == null);

    try testing.expectError(error.InvalidBundleMetadata, renderInfoPlist(a, .{
        .bundle_id = "com.labelle.x",
        .name = "Fl\xffying",
        .display_name = "Fl\xffying",
        .executable = "x",
        .short_version = "1.0",
        .build_version = "1.0",
    }));
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

    const bundle = try layoutBundle(a, work, "My Game.app", exe_src, "my_game", "#!/bin/sh\nexec launcher\n", "<plist/>");
    defer a.free(bundle);
    try testing.expectEqualStrings(want_bundle, bundle);

    // `MacOS/<exe>` is the launcher; the built exe sits beside it as
    // `<exe>-bin` (cli#364).
    const launcher_dst = try std.fs.path.join(a, &.{ bundle, "Contents", "MacOS", "my_game" });
    defer a.free(launcher_dst);
    const launcher = try cwd.readFileAlloc(io, launcher_dst, a, .unlimited);
    defer a.free(launcher);
    try testing.expectEqualStrings("#!/bin/sh\nexec launcher\n", launcher);
    if (builtin.os.tag != .windows) {
        const st = try cwd.statFile(io, launcher_dst, .{});
        try testing.expect(st.permissions.toMode() & 0o111 == 0o111);
    }

    const exe_dst = try std.fs.path.join(a, &.{ bundle, "Contents", "MacOS", "my_game-bin" });
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

/// Lay a small `assets/` tree under `<work>/assets`: a top-level file, a
/// nested one, and (POSIX only — Windows CI has no symlink privilege) a
/// file symlink plus a dangling one. Returns nothing; callers know the
/// names.
fn assetsFixture(a: std.mem.Allocator, work: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const assets = try std.fs.path.join(a, &.{ work, "assets" });
    defer a.free(assets);
    const nested = try std.fs.path.join(a, &.{ assets, "video", "cut" });
    defer a.free(nested);
    try cwd.createDirPath(io, nested);
    const top = try std.fs.path.join(a, &.{ assets, "intro.mp4" });
    defer a.free(top);
    try cwd.writeFile(io, .{ .sub_path = top, .data = "\x00\x00\x00\x1cftypisom-intro" });
    const deep = try std.fs.path.join(a, &.{ nested, "outro.mp4" });
    defer a.free(deep);
    try cwd.writeFile(io, .{ .sub_path = deep, .data = "outro-bytes" });
    if (builtin.os.tag != .windows) {
        const link = try std.fs.path.join(a, &.{ assets, "alias.mp4" });
        defer a.free(link);
        try cwd.symLink(io, "intro.mp4", link, .{});
        const dangling = try std.fs.path.join(a, &.{ assets, "gone.mp4" });
        defer a.free(dangling);
        try cwd.symLink(io, "does-not-exist.mp4", dangling, .{});
    }
}

/// Count the entries of a directory (files, dirs and links alike).
fn countEntries(path: []const u8) !usize {
    const io = config.globalIo();
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    return n;
}

test "renderLauncher: cd into Resources, export LABELLE_DATA_DIR, exec <exe>-bin (cli#364)" {
    const a = testing.allocator;
    const script = try renderLauncher(a, "my_game", "com.labelle.my-game");
    defer a.free(script);
    try testing.expectEqualStrings(
        \\#!/bin/sh
        \\# Launcher generated by `labelle bundle` (labelle-cli#364) -- do not edit.
        \\#
        \\# LaunchServices (Finder, Dock, `open`) starts a .app with cwd "/", but the
        \\# game resolves some runtime files RELATIVE TO CWD -- streamed video under
        \\# assets/, saves/, snapshots/ -- exactly as `labelle run` does from the
        \\# generated target dir, where assets/ is a symlink into the project. This
        \\# script re-creates that layout: cwd = Contents/Resources (where `labelle
        \\# bundle` staged assets/), then exec the real Mach-O beside this script.
        \\# A future engine-side asset root (LABELLE_ASSET_ROOT-style) would let the
        \\# game resolve against the bundle itself and retire this script.
        \\here=$(cd "$(dirname "$0")" && pwd)
        \\
        \\# Writable per-user data. An installed bundle (/Applications) is read-only,
        \\# so saves/snapshots must NOT land next to the assets. The game does not
        \\# honour this yet (flying-platform-labelle#773) -- it is exported so it can.
        \\if [ -n "$HOME" ]; then
        \\    LABELLE_DATA_DIR="$HOME/Library/Application Support"/'com.labelle.my-game'
        \\    mkdir -p "$LABELLE_DATA_DIR" 2>/dev/null
        \\    export LABELLE_DATA_DIR
        \\fi
        \\
        \\# LaunchServices hands apps a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin).
        \\# The bgfx desktop video path shells out to ffmpeg/ffprobe, which Homebrew
        \\# installs under /opt/homebrew/bin or /usr/local/bin -- append them so a
        \\# Finder launch finds the same tools a terminal launch does.
        \\PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
        \\export PATH
        \\
        \\cd "$here/../Resources" && exec "$here"/'my_game-bin' "$@"
        \\
    , script);
}

test "renderLauncher single-quotes an exe name with spaces or a quote so it stays one word" {
    const a = testing.allocator;
    const spaced = try renderLauncher(a, "my game", "com.labelle.my-game");
    defer a.free(spaced);
    try testing.expect(std.mem.indexOf(u8, spaced, "exec \"$here\"/'my game-bin' \"$@\"") != null);

    const quoted = try renderLauncher(a, "it's", "com.labelle.its");
    defer a.free(quoted);
    // `'\''` is the POSIX way to embed a single quote in a single-quoted word.
    try testing.expect(std.mem.indexOf(u8, quoted, "exec \"$here\"/'it'\\''s-bin' \"$@\"") != null);
    // The bin name is derived through one helper so the script and the
    // file `layoutBundle` writes can never disagree.
    const bin = try binName(a, "it's");
    defer a.free(bin);
    try testing.expectEqualStrings("it's-bin", bin);
}

test "stageAssets copies assets/ into Contents/Resources byte for byte, following links, leaving none dangling" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-stage-assets";
    cwd.deleteTree(io, work) catch {};
    defer cwd.deleteTree(io, work) catch {};
    try cwd.createDirPath(io, work);
    try assetsFixture(a, work);
    const bundle = try std.fs.path.join(a, &.{ work, "Fixture.app" });
    defer a.free(bundle);

    const report = (try stageAssets(a, work, bundle)) orelse return error.TestUnexpectedResult;
    const posix = builtin.os.tag != .windows;
    // intro + nested outro (+ the alias, dereferenced, on POSIX); the
    // dangling link is skipped, never reproduced.
    try testing.expectEqual(@as(usize, if (posix) 3 else 2), report.files);
    const intro_len: u64 = "\x00\x00\x00\x1cftypisom-intro".len;
    try testing.expectEqual(intro_len * (if (posix) 2 else 1) + "outro-bytes".len, report.bytes);

    const staged_root = try std.fs.path.join(a, &.{ bundle, "Contents", "Resources", "assets" });
    defer a.free(staged_root);
    const intro = try std.fs.path.join(a, &.{ staged_root, "intro.mp4" });
    defer a.free(intro);
    const intro_bytes = try cwd.readFileAlloc(io, intro, a, .unlimited);
    defer a.free(intro_bytes);
    try testing.expectEqualStrings("\x00\x00\x00\x1cftypisom-intro", intro_bytes);
    const outro = try std.fs.path.join(a, &.{ staged_root, "video", "cut", "outro.mp4" });
    defer a.free(outro);
    const outro_bytes = try cwd.readFileAlloc(io, outro, a, .unlimited);
    defer a.free(outro_bytes);
    try testing.expectEqualStrings("outro-bytes", outro_bytes);
    try testing.expectEqual(@as(usize, if (posix) 3 else 2), try countEntries(staged_root));

    if (posix) {
        // The alias is a REAL file in the bundle (a relative link would
        // resolve against the bundle and dangle) …
        const alias = try std.fs.path.join(a, &.{ staged_root, "alias.mp4" });
        defer a.free(alias);
        const alias_st = try cwd.statFile(io, alias, .{ .follow_symlinks = false });
        try testing.expectEqual(std.Io.File.Kind.file, alias_st.kind);
        const alias_bytes = try cwd.readFileAlloc(io, alias, a, .unlimited);
        defer a.free(alias_bytes);
        try testing.expectEqualStrings("\x00\x00\x00\x1cftypisom-intro", alias_bytes);
        // … and the dangling source link has no counterpart at all.
        const gone = try std.fs.path.join(a, &.{ staged_root, "gone.mp4" });
        defer a.free(gone);
        try testing.expectError(error.FileNotFound, cwd.statFile(io, gone, .{ .follow_symlinks = false }));
    }
}

test "stageAssets is a no-op (null) for a project without assets/" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-stage-none";
    cwd.deleteTree(io, work) catch {};
    defer cwd.deleteTree(io, work) catch {};
    try cwd.createDirPath(io, work);
    const bundle = try std.fs.path.join(a, &.{ work, "Fixture.app" });
    defer a.free(bundle);
    try testing.expect((try stageAssets(a, work, bundle)) == null);
    const resources_assets = try std.fs.path.join(a, &.{ bundle, "Contents", "Resources", "assets" });
    defer a.free(resources_assets);
    try testing.expect(!util.dirExists(resources_assets));
}

test "resolveProbedKind: only a missing target is a skippable dangling link; other stat errors propagate (#366)" {
    // `.sym_link` and `.unknown` both need the follow-stat; real kinds don't.
    try testing.expect(needsStat(.sym_link));
    try testing.expect(needsStat(.unknown));
    try testing.expect(!needsStat(.file));
    try testing.expect(!needsStat(.directory));

    // Dangling → null (skip). Anything else → the error, verbatim.
    try testing.expectEqual(@as(?std.Io.File.Kind, null), try resolveProbedKind(error.FileNotFound));
    try testing.expectError(error.AccessDenied, resolveProbedKind(error.AccessDenied));
    try testing.expectError(error.InputOutput, resolveProbedKind(error.InputOutput));
    try testing.expectError(error.NotDir, resolveProbedKind(error.NotDir));
    // A resolved `.unknown`/link dispatches on the REAL kind.
    try testing.expectEqual(@as(?std.Io.File.Kind, .directory), try resolveProbedKind(.directory));
    try testing.expectEqual(@as(?std.Io.File.Kind, .file), try resolveProbedKind(.file));
}

test "stageAssets fails (does not skip) on a symlink whose target is unreadable (#366)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // root ignores mode bits, so the probe would succeed and prove nothing.
    if (std.c.getuid() == 0) return error.SkipZigTest;
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-stage-unreadable";
    cwd.deleteTree(io, work) catch {};
    try cwd.createDirPath(io, work);
    const locked = try std.fs.path.join(a, &.{ work, "assets", "locked" });
    defer a.free(locked);
    try cwd.createDirPath(io, locked);
    const inner = try std.fs.path.join(a, &.{ locked, "inner.txt" });
    defer a.free(inner);
    try cwd.writeFile(io, .{ .sub_path = inner, .data = "secret" });
    const link = try std.fs.path.join(a, &.{ work, "assets", "peek.txt" });
    defer a.free(link);
    try cwd.symLink(io, "locked/inner.txt", link, .{});
    // No search permission on the dir → stat through it is EACCES, not ENOENT.
    try cwd.setFilePermissions(io, locked, .fromMode(0), .{});
    defer {
        cwd.setFilePermissions(io, locked, .fromMode(0o755), .{}) catch {};
        cwd.deleteTree(io, work) catch {};
    }
    const bundle = try std.fs.path.join(a, &.{ work, "Fixture.app" });
    defer a.free(bundle);
    try testing.expectError(error.AccessDenied, stageAssets(a, work, bundle));
}

test "pathIsWithin matches only at a separator boundary" {
    try testing.expect(pathIsWithin("/p/assets", "/p/assets"));
    try testing.expect(pathIsWithin("/p/assets/dist", "/p/assets"));
    try testing.expect(pathIsWithin("/p/assets/dist", "/p/assets/"));
    try testing.expect(pathIsWithin("/p/assets", "/"));
    try testing.expect(!pathIsWithin("/p/assets-dist", "/p/assets"));
    try testing.expect(!pathIsWithin("/p/assets", "/p/assets/dist"));
    try testing.expect(!pathIsWithin("/p/asset", "/p/assets"));
}

test "createFromBuild refuses --output inside assets/ before deleting anything (#366)" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-out-in-assets";
    try bundleFixture(a, work, "my_game");
    defer cwd.deleteTree(io, work) catch {};
    try assetsFixture(a, work);
    const target = try std.fs.path.join(a, &.{ work, "target" });
    defer a.free(target);
    // A previous bundle already sits there — it must survive the refusal.
    const stale = try std.fs.path.join(a, &.{ work, "assets", "dist", "My Game.app", "Contents", "keep" });
    defer a.free(stale);
    try cwd.createDirPath(io, std.fs.path.dirname(stale).?);
    try cwd.writeFile(io, .{ .sub_path = stale, .data = "still here" });

    const cfg = project_config.ProjectConfig{ .name = "my_game", .title = "My Game" };
    const nested = try std.fs.path.join(a, &.{ "assets", "dist" });
    defer a.free(nested);
    try testing.expectError(error.OutputInsideAssets, createFromBuild(a, work, target, cfg, nested));
    try testing.expect(util.fileExists(stale));
    // `assets/` itself as the output is the same refusal.
    try testing.expectError(error.OutputInsideAssets, createFromBuild(a, work, target, cfg, "assets"));
    try testing.expect(util.fileExists(stale));
}

test "createFromBuild refuses a project whose assets/ lies under <out>/<Title>.app, allows a sibling `assets-dist` (#366)" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-assets-in-bundle";
    try bundleFixture(a, work, "my_game");
    defer cwd.deleteTree(io, work) catch {};
    const target = try std.fs.path.join(a, &.{ work, "target" });
    defer a.free(target);
    const cfg = project_config.ProjectConfig{ .name = "my_game", .title = "My Game" };

    // Project rooted INSIDE the would-be bundle: <work>/dist/My Game.app/proj,
    // `--output ../..` → <work>/dist → bundle = <work>/dist/My Game.app,
    // which contains the project's assets/. Wiping it would eat them.
    const proj = try std.fs.path.join(a, &.{ work, "dist", "My Game.app", "proj" });
    defer a.free(proj);
    try cwd.createDirPath(io, proj);
    try assetsFixture(a, proj);
    const up_two = try std.fs.path.join(a, &.{ "..", ".." });
    defer a.free(up_two);
    try testing.expectError(error.AssetsInsideBundle, createFromBuild(a, proj, target, cfg, up_two));
    const src_intro = try std.fs.path.join(a, &.{ proj, "assets", "intro.mp4" });
    defer a.free(src_intro);
    try testing.expect(util.fileExists(src_intro));

    // The prefix test respects the separator: `assets-dist` is a sibling
    // of `assets`, not inside it — a legal output.
    try assetsFixture(a, work);
    const bundle = try createFromBuild(a, work, target, cfg, "assets-dist");
    defer a.free(bundle);
    const staged = try std.fs.path.join(a, &.{ bundle, "Contents", "Resources", "assets", "intro.mp4" });
    defer a.free(staged);
    try testing.expect(util.fileExists(staged));
}

test "linkVerdict: into the output root → skip, ancestor of itself → cycle, elsewhere → follow (#366)" {
    try testing.expectEqual(LinkVerdict.into_output, linkVerdict("/p/dist", "/p/assets", "/p/dist"));
    try testing.expectEqual(LinkVerdict.into_output, linkVerdict("/p/dist/My Game.app/Contents", "/p/assets", "/p/dist"));
    try testing.expectEqual(LinkVerdict.follow, linkVerdict("/p/dist-old", "/p/assets", "/p/dist"));
    try testing.expectEqual(LinkVerdict.cycle, linkVerdict("/p/assets", "/p/assets", "/p/dist"));
    try testing.expectEqual(LinkVerdict.cycle, linkVerdict("/p", "/p/assets/a", "/p/dist"));
    try testing.expectEqual(LinkVerdict.follow, linkVerdict("/p/assets/b", "/p/assets/a", "/p/dist"));
    try testing.expectEqual(LinkVerdict.follow, linkVerdict("/p/shared", "/p/assets", "/p/dist"));
}

test "createFromBuild skips a directory link that resolves into <out> and still replaces the stale bundle (#366)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-link-into-out";
    try bundleFixture(a, work, "my_game");
    defer cwd.deleteTree(io, work) catch {};
    try assetsFixture(a, work);
    const target = try std.fs.path.join(a, &.{ work, "target" });
    defer a.free(target);
    // <out> = <work>/dist already holds a previous bundle …
    const stale = try std.fs.path.join(a, &.{ work, "dist", "My Game.app", "Contents", "stale" });
    defer a.free(stale);
    try cwd.createDirPath(io, std.fs.path.dirname(stale).?);
    try cwd.writeFile(io, .{ .sub_path = stale, .data = "old" });
    // … and assets/generated points at it.
    const generated = try std.fs.path.join(a, &.{ work, "assets", "generated" });
    defer a.free(generated);
    try cwd.symLink(io, "../dist", generated, .{ .is_directory = true });

    const cfg = project_config.ProjectConfig{ .name = "my_game", .title = "My Game" };
    const bundle = try createFromBuild(a, work, target, cfg, "dist");
    defer a.free(bundle);
    try testing.expect(!util.fileExists(stale));
    const staged_root = try std.fs.path.join(a, &.{ bundle, "Contents", "Resources", "assets" });
    defer a.free(staged_root);
    const staged_generated = try std.fs.path.join(a, &.{ staged_root, "generated" });
    defer a.free(staged_generated);
    try testing.expect(!util.dirExists(staged_generated));
    try testing.expect(!util.fileExists(staged_generated));
    const staged_intro = try std.fs.path.join(a, &.{ staged_root, "intro.mp4" });
    defer a.free(staged_intro);
    try testing.expect(util.fileExists(staged_intro));
    // intro, alias (dereferenced), video/ — the link contributed nothing.
    try testing.expectEqual(@as(usize, 3), try countEntries(staged_root));
}

test "stageAssets follows a directory link to a sibling outside <out>, also when <out> is the project root (#366)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-link-sibling";
    try bundleFixture(a, work, "my_game");
    defer cwd.deleteTree(io, work) catch {};
    try assetsFixture(a, work);
    const target = try std.fs.path.join(a, &.{ work, "target" });
    defer a.free(target);
    const extra = try std.fs.path.join(a, &.{ work, "shared", "extra.txt" });
    defer a.free(extra);
    try cwd.createDirPath(io, std.fs.path.dirname(extra).?);
    try cwd.writeFile(io, .{ .sub_path = extra, .data = "shared art" });
    const shared_link = try std.fs.path.join(a, &.{ work, "assets", "shared" });
    defer a.free(shared_link);
    try cwd.symLink(io, "../shared", shared_link, .{ .is_directory = true });
    const cfg = project_config.ProjectConfig{ .name = "my_game", .title = "My Game" };

    // `--output dist`: <out> is not an ancestor of assets/, the sibling is fine.
    {
        const bundle = try createFromBuild(a, work, target, cfg, "dist");
        defer a.free(bundle);
        const got = try std.fs.path.join(a, &.{ bundle, "Contents", "Resources", "assets", "shared", "extra.txt" });
        defer a.free(got);
        const bytes = try cwd.readFileAlloc(io, got, a, .unlimited);
        defer a.free(bytes);
        try testing.expectEqualStrings("shared art", bytes);
    }
    // `--output .`: <out> IS an ancestor of assets/ — the whole project is
    // under it, so only the `.app` itself is off-limits and the sibling
    // link must still be followed (no over-refusal).
    {
        const bundle = try createFromBuild(a, work, target, cfg, ".");
        defer a.free(bundle);
        const got = try std.fs.path.join(a, &.{ bundle, "Contents", "Resources", "assets", "shared", "extra.txt" });
        defer a.free(got);
        try testing.expect(util.fileExists(got));
    }
}

test "stageAssets skips a symlink cycle inside assets/ with the link named, instead of hitting the depth cap (#366)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-link-cycle";
    cwd.deleteTree(io, work) catch {};
    defer cwd.deleteTree(io, work) catch {};
    try cwd.createDirPath(io, work);
    try assetsFixture(a, work);
    // assets/loop -> . and assets/video/up -> .. : both point at an ancestor.
    const loop = try std.fs.path.join(a, &.{ work, "assets", "loop" });
    defer a.free(loop);
    try cwd.symLink(io, ".", loop, .{ .is_directory = true });
    const up = try std.fs.path.join(a, &.{ work, "assets", "video", "up" });
    defer a.free(up);
    try cwd.symLink(io, "..", up, .{ .is_directory = true });
    const out = try std.fs.path.join(a, &.{ work, "dist" });
    defer a.free(out);
    try cwd.createDirPath(io, out);
    const bundle = try std.fs.path.join(a, &.{ out, "Fixture.app" });
    defer a.free(bundle);

    const report = (try stageAssets(a, work, bundle)) orelse return error.TestUnexpectedResult;
    // Exactly the fixture's files: intro, alias, video/cut/outro.
    try testing.expectEqual(@as(usize, 3), report.files);
    const staged_loop = try std.fs.path.join(a, &.{ bundle, "Contents", "Resources", "assets", "loop" });
    defer a.free(staged_loop);
    try testing.expect(!util.dirExists(staged_loop));
    const staged_up = try std.fs.path.join(a, &.{ bundle, "Contents", "Resources", "assets", "video", "up" });
    defer a.free(staged_up);
    try testing.expect(!util.dirExists(staged_up));
}

test "createFromBuild: CFBundleExecutable names the launcher, the launcher execs <exe>-bin, assets/ rides along (cli#364)" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-self-contained";
    try bundleFixture(a, work, "my_game");
    defer cwd.deleteTree(io, work) catch {};
    try assetsFixture(a, work);
    const target = try std.fs.path.join(a, &.{ work, "target" });
    defer a.free(target);
    const project_assets = try std.fs.path.join(a, &.{ work, "assets" });
    defer a.free(project_assets);
    const project_entries_before = try countEntries(work);
    const assets_entries_before = try countEntries(project_assets);

    const cfg = project_config.ProjectConfig{ .name = "my_game", .title = "My Game" };
    const bundle = try createFromBuild(a, work, target, cfg, "dist");
    defer a.free(bundle);

    // Plist → launcher → Mach-O chain.
    const plist_path = try std.fs.path.join(a, &.{ bundle, "Contents", "Info.plist" });
    defer a.free(plist_path);
    const plist = try cwd.readFileAlloc(io, plist_path, a, .unlimited);
    defer a.free(plist);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleExecutable</key>\n    <string>my_game</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "my_game-bin") == null);

    const launcher_path = try std.fs.path.join(a, &.{ bundle, "Contents", "MacOS", "my_game" });
    defer a.free(launcher_path);
    const launcher = try cwd.readFileAlloc(io, launcher_path, a, .unlimited);
    defer a.free(launcher);
    try testing.expect(std.mem.startsWith(u8, launcher, "#!/bin/sh\n"));
    try testing.expect(std.mem.indexOf(u8, launcher, "cd \"$here/../Resources\" && exec \"$here\"/'my_game-bin' \"$@\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, launcher, "LABELLE_DATA_DIR=\"$HOME/Library/Application Support\"/'com.labelle.my-game'") != null);

    const bin_path = try std.fs.path.join(a, &.{ bundle, "Contents", "MacOS", "my_game-bin" });
    defer a.free(bin_path);
    const bin = try cwd.readFileAlloc(io, bin_path, a, .unlimited);
    defer a.free(bin);
    try testing.expectEqualStrings("ELF-ish", bin);

    // Resources/assets mirrors the project's tree where the launcher's cwd lands.
    const staged_intro = try std.fs.path.join(a, &.{ bundle, "Contents", "Resources", "assets", "intro.mp4" });
    defer a.free(staged_intro);
    try testing.expect(util.fileExists(staged_intro));
    const staged_outro = try std.fs.path.join(a, &.{ bundle, "Contents", "Resources", "assets", "video", "cut", "outro.mp4" });
    defer a.free(staged_outro);
    try testing.expect(util.fileExists(staged_outro));

    // The project itself is untouched: same entries at its root and in
    // its assets/ (nothing was moved, hardlinked into, or written there).
    try testing.expectEqual(project_entries_before + 1, try countEntries(work)); // +1: the `dist` output dir we asked for
    try testing.expectEqual(assets_entries_before, try countEntries(project_assets));
    const src_intro = try std.fs.path.join(a, &.{ project_assets, "intro.mp4" });
    defer a.free(src_intro);
    const src_intro_bytes = try cwd.readFileAlloc(io, src_intro, a, .unlimited);
    defer a.free(src_intro_bytes);
    try testing.expectEqualStrings("\x00\x00\x00\x1cftypisom-intro", src_intro_bytes);
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

/// Run `createFromBuild` on a fresh fixture and return the rendered plist.
fn plistFor(a: std.mem.Allocator, work: []const u8, cfg: project_config.ProjectConfig, bundle_out: *[]u8) ![]u8 {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    try bundleFixture(a, work, "my_game");
    const target = try std.fs.path.join(a, &.{ work, "target" });
    defer a.free(target);
    const bundle = try createFromBuild(a, work, target, cfg, null);
    errdefer a.free(bundle);
    const plist_path = try std.fs.path.join(a, &.{ bundle, "Contents", "Info.plist" });
    defer a.free(plist_path);
    bundle_out.* = bundle;
    return cwd.readFileAlloc(io, plist_path, a, .unlimited);
}

test "createFromBuild: a control byte in the title is dropped from the plist and the file name" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-ctrl-title";
    defer cwd.deleteTree(io, work) catch {};
    var bundle: []u8 = undefined;
    const plist = try plistFor(a, work, .{ .name = "my_game", .title = "My\x01 Game" }, &bundle);
    defer a.free(plist);
    defer a.free(bundle);
    try testing.expect(std.mem.endsWith(u8, bundle, "My Game.app"));
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleDisplayName</key>\n    <string>My Game</string>") != null);
    try testing.expect(std.mem.indexOfScalar(u8, plist, 0x01) == null);
}

test "createFromBuild: an invalid-UTF-8 title falls back to the project name for label AND file name" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-utf8-title";
    defer cwd.deleteTree(io, work) catch {};
    var bundle: []u8 = undefined;
    const plist = try plistFor(a, work, .{ .name = "my_game", .title = "Fl\xffying" }, &bundle);
    defer a.free(plist);
    defer a.free(bundle);
    try testing.expect(std.mem.endsWith(u8, bundle, "my_game.app"));
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleDisplayName</key>\n    <string>my_game</string>") != null);
    try testing.expect(std.mem.indexOfScalar(u8, plist, 0xff) == null);
}

test "createFromBuild: an invalid-UTF-8 project name is a hard error" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-utf8-name";
    try bundleFixture(a, work, "my_game");
    defer cwd.deleteTree(io, work) catch {};
    const target = try std.fs.path.join(a, &.{ work, "target" });
    defer a.free(target);
    // The exe fixture is `my_game`; sanitizeExeName drops the bad byte so
    // the probe still finds it — the metadata check must fail FIRST.
    try testing.expectError(error.InvalidBundleMetadata, createFromBuild(a, work, target, .{ .name = "my_game\xff", .title = "" }, null));
}

test "createFromBuild writes a positive CFBundleVersion for a 0.x project" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const work = ".zig-cache/bundle-zero-major";
    defer cwd.deleteTree(io, work) catch {};
    var bundle: []u8 = undefined;
    // `.version` left at the ProjectConfig default, 0.1.0 — flying-platform's case.
    const plist = try plistFor(a, work, .{ .name = "my_game", .title = "My Game" }, &bundle);
    defer a.free(plist);
    defer a.free(bundle);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleShortVersionString</key>\n    <string>0.1.0</string>") != null);
    try testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleVersion</key>\n    <string>1.1.0</string>") != null);
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
