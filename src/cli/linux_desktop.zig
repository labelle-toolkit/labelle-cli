//! Linux `.desktop` entry + icon for the built desktop exe (labelle-cli#359).
//!
//! `labelle build` leaves a bare binary in `zig-out/bin`. On Linux the
//! launcher/dock/task-switcher identity of an app — its name and icon —
//! comes from a freedesktop `.desktop` entry, not from the exe. So after a
//! successful desktop build this module writes, beside `bin/`:
//!
//!     <target>/zig-out/<exe>.desktop     the entry (absolute paths)
//!     <target>/zig-out/<exe>.png         256×256, box-downscaled from the
//!                                        same icon source every platform
//!                                        uses (`app_icon.zig` precedence)
//!
//! Emitted automatically on a Linux host, or anywhere with the `build
//! --linux-desktop` opt-in (useful for testing the output on other hosts —
//! the paths inside are absolute for THIS machine).
//!
//! ## Scope
//!
//! The entry is written next to the build output and is complete: a user
//! can `cp` it into `~/.local/share/applications/` (or `desktop-file-install`
//! it) and the game appears in their menu. Installing it there ourselves —
//! `labelle install --desktop` — is deliberately OUT of scope for this
//! change: it touches user-global state and needs an uninstall story.
//!
//! ## Format notes (Desktop Entry Specification 1.5)
//!
//! - `Exec` is parsed by the launcher: the value is first %-expanded (so a
//!   literal `%` in the path must be written `%%`), then split shell-style.
//!   An argument containing a reserved character (space, quotes, `$`, `` ` ``,
//!   `\`, `>`, `<`, `~`, `|`, `&`, `;`, `*`, `?`, `#`, `(`, `)`) is
//!   double-quoted, and inside quotes `"`, `` ` ``, `$` and `\` are
//!   backslash-escaped. `escapeExecArg` implements exactly that.
//! - `Path` is the working directory the launcher `cd`s into first. We set
//!   it to the generated target dir, where a `labelle run` game already runs
//!   from, so cwd-relative asset/save paths behave the same (cf. cli#364's
//!   cwd launcher for the macOS bundle).
//! - `Icon` may be an absolute path to a PNG — no theme lookup needed.
//! - `Name` is a localestring; control characters are stripped so a title
//!   cannot inject a second key.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const project_config = @import("project_config.zig");
const app_icon = @import("app_icon.zig");
const bundle = @import("bundle.zig");

/// The one icon size the entry ships. Launchers rescale from a 256 master
/// cleanly; a full hicolor theme tree is `install --desktop` territory.
pub const icon_px: u32 = 256;

/// Whether to emit the entry for this build: the explicit `--linux-desktop`
/// opt-in anywhere, else automatically on a Linux host.
pub fn shouldEmit(opt_in: bool) bool {
    return opt_in or builtin.os.tag == .linux;
}

/// Characters the spec reserves in `Exec` arguments — their presence means
/// the argument must be double-quoted.
const exec_reserved = " \t\n\"'\\><~|&;$*?#()`";

/// Render one `Exec` argument: quote + escape when the spec requires it,
/// and double every `%` (field-code escape) in either case. Caller owns.
pub fn escapeExecArg(allocator: std.mem.Allocator, arg: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const needs_quotes = std.mem.indexOfAny(u8, arg, exec_reserved) != null or arg.len == 0;
    if (needs_quotes) try out.append(allocator, '"');
    for (arg) |c| {
        switch (c) {
            '%' => try out.appendSlice(allocator, "%%"),
            '"', '`', '$', '\\' => {
                // Only meaningful inside quotes — and any of these forces quotes.
                try out.append(allocator, '\\');
                try out.append(allocator, c);
            },
            else => try out.append(allocator, c),
        }
    }
    if (needs_quotes) try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

/// Bytes that make a title unusable when they are all it has (same rule as
/// `bundle.displayName`).
const name_strip = std.ascii.whitespace ++ [_]u8{'.'};

/// The `Name=` value: the project title with control characters removed
/// (a newline would start a new key), trimmed; falls back to the project
/// `.name`, then to `game`. Caller owns.
pub fn displayName(allocator: std.mem.Allocator, title: []const u8, name: []const u8) ![]u8 {
    for ([_][]const u8{ title, name }) |candidate| {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (candidate) |c| {
            if (c < 0x20 or c == 0x7f) continue;
            try out.append(allocator, c);
        }
        const trimmed = std.mem.trim(u8, out.items, &name_strip);
        if (trimmed.len != 0) {
            const owned = try allocator.dupe(u8, trimmed);
            out.deinit(allocator);
            return owned;
        }
        out.deinit(allocator);
    }
    return allocator.dupe(u8, "game");
}

/// Everything the entry needs. All paths are expected ABSOLUTE — a
/// relative `Exec`/`Icon` is resolved against the launcher's cwd, which is
/// never ours.
pub const Entry = struct {
    /// `Name=` — already sanitised via `displayName`.
    name: []const u8,
    /// `Comment=` — the project description; omitted when empty.
    comment: []const u8 = "",
    /// The exe to launch (absolute).
    exec_path: []const u8,
    /// Working directory (absolute): the generated target dir.
    working_dir: []const u8,
    /// Absolute PNG path, or null to omit `Icon=` (no icon source at all).
    icon_path: ?[]const u8,
};

/// Strip control characters from a plain string value (Comment/Path/Icon
/// cannot carry a newline without corrupting the file). Caller owns.
fn plainValue(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        if (c < 0x20 or c == 0x7f) continue;
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

/// Render the `.desktop` file. Caller owns the bytes.
pub fn render(allocator: std.mem.Allocator, entry: Entry) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    const exec = try escapeExecArg(allocator, entry.exec_path);
    defer allocator.free(exec);
    const path = try plainValue(allocator, entry.working_dir);
    defer allocator.free(path);

    try w.writeAll("[Desktop Entry]\n");
    try w.writeAll("Type=Application\n");
    try w.writeAll("Version=1.5\n");
    try w.print("Name={s}\n", .{entry.name});
    if (entry.comment.len != 0) {
        const comment = try plainValue(allocator, entry.comment);
        defer allocator.free(comment);
        if (comment.len != 0) try w.print("Comment={s}\n", .{comment});
    }
    try w.print("Exec={s}\n", .{exec});
    try w.print("Path={s}\n", .{path});
    if (entry.icon_path) |icon| {
        const icon_clean = try plainValue(allocator, icon);
        defer allocator.free(icon_clean);
        try w.print("Icon={s}\n", .{icon_clean});
    }
    try w.writeAll("Terminal=false\n");
    try w.writeAll("Categories=Game;\n");
    try w.writeAll("StartupNotify=false\n");
    return aw.toOwnedSlice();
}

/// Scale the decoded icon to `icon_px` (box filter down, nearest up — the
/// `bundle.scaleForEntry` rule) and write it as a PNG at `out_path`.
pub fn stageIcon(allocator: std.mem.Allocator, img: app_icon.DecodedImage, out_path: []const u8) !void {
    const scaled = try bundle.scaleForEntry(allocator, img.pixels, img.width, img.height, icon_px);
    defer allocator.free(scaled);
    const png = try app_icon.encodePng(allocator, scaled, icon_px, icon_px);
    defer allocator.free(png);
    const io = config.globalIo();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = png });
}

/// Post-build entry point called from `pipeline.zig` once `zig build` has
/// produced the desktop exe. Writes `<target>/zig-out/<exe>.png` (when an
/// icon source exists) and `<target>/zig-out/<exe>.desktop`; returns the
/// caller-owned absolute path of the `.desktop` file.
pub fn createFromBuild(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    target_dir: []const u8,
    cfg: project_config.ProjectConfig,
) ![]u8 {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    // 1. Icon first, so a misconfigured `.app_icon` fails before anything
    //    is written (same order as `bundle.createFromBuild`). Null only
    //    when an older assembler wrote no default.
    const maybe_img = try app_icon.load(allocator, project_dir, target_dir, cfg.app_icon, .{
        .label = "desktop icon",
        .recommended_px = icon_px,
    });
    defer if (maybe_img) |img| img.free();

    // 2. The exe the CURRENT build produced.
    const exe = try bundle.resolveBuiltExe(allocator, target_dir, cfg.name);
    defer exe.deinit(allocator);

    // 3. Absolute paths: the entry is consumed by a launcher with an
    //    unrelated cwd, so everything in it must be absolute.
    const target_abs = try cwd.realPathFileAlloc(io, target_dir, allocator);
    defer allocator.free(target_abs);
    const exe_abs = try cwd.realPathFileAlloc(io, exe.path, allocator);
    defer allocator.free(exe_abs);
    const out_dir = try std.fs.path.join(allocator, &.{ target_abs, "zig-out" });
    defer allocator.free(out_dir);
    try cwd.createDirPath(io, out_dir);

    // 4. Icon PNG beside the entry.
    var icon_abs: ?[]u8 = null;
    defer if (icon_abs) |p| allocator.free(p);
    if (maybe_img) |img| {
        const icon_name = try std.fmt.allocPrint(allocator, "{s}.png", .{exe.name});
        defer allocator.free(icon_name);
        const icon_path = try std.fs.path.join(allocator, &.{ out_dir, icon_name });
        errdefer allocator.free(icon_path);
        try stageIcon(allocator, img, icon_path);
        icon_abs = icon_path;
    }

    // 5. The entry itself.
    const name = try displayName(allocator, cfg.title, cfg.name);
    defer allocator.free(name);
    const text = try render(allocator, .{
        .name = name,
        .comment = cfg.description,
        .exec_path = exe_abs,
        .working_dir = target_abs,
        .icon_path = icon_abs,
    });
    defer allocator.free(text);
    const entry_name = try std.fmt.allocPrint(allocator, "{s}.desktop", .{exe.name});
    defer allocator.free(entry_name);
    const entry_path = try std.fs.path.join(allocator, &.{ out_dir, entry_name });
    errdefer allocator.free(entry_path);
    try cwd.writeFile(io, .{ .sub_path = entry_path, .data = text });

    std.debug.print("labelle: desktop entry written to {s}\n", .{entry_path});
    std.debug.print("  install with: desktop-file-install --dir=$HOME/.local/share/applications '{s}'\n", .{entry_path});
    return entry_path;
}

// ── Tests ──────────────────────────────────────────────────────────────

const expect = @import("zspec").expect;

pub const EscapeExecArgSpec = struct {
    test "a plain absolute path is left bare" {
        const got = try escapeExecArg(std.testing.allocator, "/opt/games/colony/colony");
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("/opt/games/colony/colony", got);
    }

    test "a space forces double quotes" {
        const got = try escapeExecArg(std.testing.allocator, "/home/me/My Games/colony");
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("\"/home/me/My Games/colony\"", got);
    }

    test "percent is doubled (field-code escape), quoted or not" {
        const bare = try escapeExecArg(std.testing.allocator, "/tmp/100%done/game");
        defer std.testing.allocator.free(bare);
        try std.testing.expectEqualStrings("/tmp/100%%done/game", bare);
        const quoted = try escapeExecArg(std.testing.allocator, "/tmp/100% done/game");
        defer std.testing.allocator.free(quoted);
        try std.testing.expectEqualStrings("\"/tmp/100%% done/game\"", quoted);
    }

    test "quote, backslash, dollar and backtick are backslash-escaped inside quotes" {
        const got = try escapeExecArg(std.testing.allocator, "/a\"b\\c$d`e/game");
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("\"/a\\\"b\\\\c\\$d\\`e/game\"", got);
    }

    test "every other reserved character forces quotes without escaping" {
        inline for (.{ "~", "|", "&", ";", "*", "?", "#", "(", ")", "<", ">", "'" }) |ch| {
            const arg = "/x/" ++ ch ++ "/game";
            const got = try escapeExecArg(std.testing.allocator, arg);
            defer std.testing.allocator.free(got);
            try std.testing.expectEqualStrings("\"" ++ arg ++ "\"", got);
        }
    }
};

pub const DisplayNameSpec = struct {
    test "uses the trimmed title" {
        const got = try displayName(std.testing.allocator, "  Colony Ship  ", "colony");
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("Colony Ship", got);
    }

    test "strips control characters so a title cannot inject a key" {
        const got = try displayName(std.testing.allocator, "Colony\nExec=rm -rf /", "colony");
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("ColonyExec=rm -rf /", got);
    }

    test "falls back to the name, then to game" {
        const from_name = try displayName(std.testing.allocator, " ... ", "colony");
        defer std.testing.allocator.free(from_name);
        try std.testing.expectEqualStrings("colony", from_name);
        const last = try displayName(std.testing.allocator, "", "\t");
        defer std.testing.allocator.free(last);
        try std.testing.expectEqualStrings("game", last);
    }
};

pub const RenderSpec = struct {
    test "renders every required key with absolute paths and Game category" {
        const got = try render(std.testing.allocator, .{
            .name = "Colony Ship",
            .comment = "A colony sim",
            .exec_path = "/home/me/colony/.labelle/bgfx_desktop/zig-out/bin/colony",
            .working_dir = "/home/me/colony/.labelle/bgfx_desktop",
            .icon_path = "/home/me/colony/.labelle/bgfx_desktop/zig-out/colony.png",
        });
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(
            "[Desktop Entry]\n" ++
                "Type=Application\n" ++
                "Version=1.5\n" ++
                "Name=Colony Ship\n" ++
                "Comment=A colony sim\n" ++
                "Exec=/home/me/colony/.labelle/bgfx_desktop/zig-out/bin/colony\n" ++
                "Path=/home/me/colony/.labelle/bgfx_desktop\n" ++
                "Icon=/home/me/colony/.labelle/bgfx_desktop/zig-out/colony.png\n" ++
                "Terminal=false\n" ++
                "Categories=Game;\n" ++
                "StartupNotify=false\n",
            got,
        );
    }

    test "Exec is quoted+escaped while Path/Icon stay plain; no Icon key without an icon" {
        const got = try render(std.testing.allocator, .{
            .name = "G",
            .exec_path = "/My Games/100%/g",
            .working_dir = "/My Games/100%",
            .icon_path = null,
        });
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.indexOf(u8, got, "Exec=\"/My Games/100%%/g\"\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, got, "Path=/My Games/100%\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, got, "Icon=") == null);
        try std.testing.expect(std.mem.indexOf(u8, got, "Comment=") == null);
    }

    test "a newline in Comment or Path cannot start a new key" {
        const got = try render(std.testing.allocator, .{
            .name = "G",
            .comment = "line one\nExec=evil",
            .exec_path = "/g",
            .working_dir = "/w\nExec=evil",
            .icon_path = null,
        });
        defer std.testing.allocator.free(got);
        try expect.equal(std.mem.count(u8, got, "\nExec="), @as(usize, 1));
        try std.testing.expect(std.mem.indexOf(u8, got, "Comment=line oneExec=evil\n") != null);
    }
};

pub const StageIconSpec = struct {
    test "writes a 256x256 PNG from a larger master (box) and a smaller one (nearest)" {
        const allocator = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(dir);

        inline for (.{ 512, 64 }) |edge| {
            const px = try app_icon.gradientRgba(allocator, edge, edge);
            defer allocator.free(px);
            const out = try std.fs.path.join(allocator, &.{ dir, "icon.png" });
            defer allocator.free(out);
            try stageIcon(allocator, .{ .pixels = px, .width = edge, .height = edge }, out);

            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, out, allocator, .limited(4 << 20));
            defer allocator.free(bytes);
            const decoded = try app_icon.decodePng(bytes);
            defer decoded.free();
            try expect.equal(decoded.width, @as(usize, icon_px));
            try expect.equal(decoded.height, @as(usize, icon_px));
        }
    }
};

pub const CreateFromBuildSpec = struct {
    test "writes <exe>.desktop + <exe>.png beside zig-out/bin with absolute paths" {
        const allocator = std.testing.allocator;
        const io = config.globalIo();
        const cwd = std.Io.Dir.cwd();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(root);

        // A generated target: the built exe (legacy `game` name, so no
        // build.zig is needed) and the assembler's default icon.
        const target_dir = try std.fs.path.join(allocator, &.{ root, ".labelle", "bgfx_desktop" });
        defer allocator.free(target_dir);
        const bin_dir = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin" });
        defer allocator.free(bin_dir);
        try cwd.createDirPath(io, bin_dir);
        const exe_path = try std.fs.path.join(allocator, &.{ bin_dir, "game" });
        defer allocator.free(exe_path);
        try cwd.writeFile(io, .{ .sub_path = exe_path, .data = "#!/bin/sh\n" });
        const px = try app_icon.gradientRgba(allocator, 64, 64);
        defer allocator.free(px);
        const png = try app_icon.encodePng(allocator, px, 64, 64);
        defer allocator.free(png);
        const default_icon = try std.fs.path.join(allocator, &.{ target_dir, app_icon.default_icon_name });
        defer allocator.free(default_icon);
        try cwd.writeFile(io, .{ .sub_path = default_icon, .data = png });

        const entry_path = try createFromBuild(allocator, root, target_dir, .{
            .name = "game",
            .title = "Colony Ship",
            .description = "A colony sim",
        });
        defer allocator.free(entry_path);
        // Path assertions go through the same realpath + separator rules the
        // implementation uses, so this holds on Windows (backslashes, drive
        // letters) as well as POSIX — the CI matrix runs all three.
        try std.testing.expect(std.fs.path.isAbsolute(entry_path));
        try std.testing.expectEqualStrings("game.desktop", std.fs.path.basename(entry_path));
        try std.testing.expectEqualStrings("zig-out", std.fs.path.basename(std.fs.path.dirname(entry_path).?));
        const target_real = try cwd.realPathFileAlloc(io, target_dir, allocator);
        defer allocator.free(target_real);
        const exe_real = try cwd.realPathFileAlloc(io, exe_path, allocator);
        defer allocator.free(exe_real);

        const text = try cwd.readFileAlloc(io, entry_path, allocator, .limited(1 << 16));
        defer allocator.free(text);
        // A Windows path carries backslashes, which the Exec grammar quotes
        // and escapes — so compare against the escaper, not the raw path.
        const exe_escaped = try escapeExecArg(allocator, exe_real);
        defer allocator.free(exe_escaped);
        const want_exec = try std.fmt.allocPrint(allocator, "Exec={s}\n", .{exe_escaped});
        defer allocator.free(want_exec);
        try std.testing.expect(std.mem.indexOf(u8, text, want_exec) != null);
        const want_path = try std.fmt.allocPrint(allocator, "Path={s}\n", .{target_real});
        defer allocator.free(want_path);
        try std.testing.expect(std.mem.indexOf(u8, text, want_path) != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Name=Colony Ship\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Comment=A colony sim\n") != null);

        const icon_path = try std.fs.path.join(allocator, &.{ target_real, "zig-out", "game.png" });
        defer allocator.free(icon_path);
        const want_icon = try std.fmt.allocPrint(allocator, "Icon={s}\n", .{icon_path});
        defer allocator.free(want_icon);
        try std.testing.expect(std.mem.indexOf(u8, text, want_icon) != null);
        const icon_bytes = try cwd.readFileAlloc(io, icon_path, allocator, .limited(4 << 20));
        defer allocator.free(icon_bytes);
        const decoded = try app_icon.decodePng(icon_bytes);
        defer decoded.free();
        try expect.equal(decoded.width, @as(usize, icon_px));
    }

    test "no icon source (older assembler) → entry without Icon=, no PNG written" {
        const allocator = std.testing.allocator;
        const io = config.globalIo();
        const cwd = std.Io.Dir.cwd();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(root);
        const bin_dir = try std.fs.path.join(allocator, &.{ root, "zig-out", "bin" });
        defer allocator.free(bin_dir);
        try cwd.createDirPath(io, bin_dir);
        const exe_path = try std.fs.path.join(allocator, &.{ bin_dir, "game" });
        defer allocator.free(exe_path);
        try cwd.writeFile(io, .{ .sub_path = exe_path, .data = "" });

        const entry_path = try createFromBuild(allocator, root, root, .{ .name = "game" });
        defer allocator.free(entry_path);
        const text = try cwd.readFileAlloc(io, entry_path, allocator, .limited(1 << 16));
        defer allocator.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "Icon=") == null);
        const icon_path = try std.fs.path.join(allocator, &.{ root, "zig-out", "game.png" });
        defer allocator.free(icon_path);
        try std.testing.expectError(error.FileNotFound, cwd.access(io, icon_path, .{}));
    }

    test "a custom app_icon that does not exist fails before anything is written" {
        const allocator = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(root);
        try std.testing.expectError(
            error.AppIconNotFound,
            createFromBuild(allocator, root, root, .{ .name = "game", .app_icon = "assets/missing.png" }),
        );
    }
};

pub const ShouldEmitSpec = struct {
    test "the opt-in always wins; otherwise only a Linux host emits" {
        try std.testing.expect(shouldEmit(true));
        try expect.equal(shouldEmit(false), builtin.os.tag == .linux);
    }
};
