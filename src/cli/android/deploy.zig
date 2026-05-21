/// `labelle android deploy` (#141) — build + package + upload APK to
/// GitHub Releases. v1 of the labelle.games OTA story: zero server
/// infrastructure, testers subscribe to the game's GitHub repo URL in
/// Obtainium, the release flows to their device on next poll.
///
/// Dispatcher lives in the parent `android.zig` which parses the flags
/// and hands them over as `DeployOpts`.
const std = @import("std");
const project_config = @import("../project_config.zig");

const util = @import("../util.zig");
const android = @import("../android.zig");

/// Parameters for `labelle android deploy`. Kept as a struct so the
/// call site in `handleAndroid` stays readable and so adding future
/// deploy-only flags doesn't ripple into every reader of the function
/// signature.
pub const DeployOpts = struct {
    tag: ?[]const u8,
    channel: []const u8, // "stable" | "staging" (others treated as stable for now)
    notes_file: ?[]const u8,
    release_mode: android.ReleaseMode,
    all_abis: bool,
    emulator: bool,
    signing: android.SigningConfig,
};

/// Build + package an APK, then upload it as a GitHub Release via the
/// `gh` CLI.
pub fn cmdDeploy(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    cfg: project_config.ProjectConfig,
    opts: DeployOpts,
) !void {
    const tag = opts.tag orelse {
        std.debug.print(
            \\labelle android deploy: --tag is required.
            \\  Example: labelle android deploy --tag v0.3.0
            \\  (use the release tag you want on GitHub — usually vMAJOR.MINOR.PATCH)
            \\
        , .{});
        return error.InvalidArgs;
    };

    const channel_is_prerelease = std.mem.eql(u8, opts.channel, "staging") or
        std.mem.eql(u8, opts.channel, "preview") or
        std.mem.eql(u8, opts.channel, "internal");

    // `gh` presence + auth is cheap to check up front. Failing here
    // is a much better UX than building a multi-MB APK and then
    // discovering the uploader isn't installed.
    try ensureGhAvailable(allocator);

    std.debug.print(
        "labelle android deploy: building APK (channel={s}, tag={s})...\n",
        .{ opts.channel, tag },
    );

    const apk_path = try android.buildAndPackage(
        allocator,
        target_dir,
        cfg,
        opts.release_mode,
        opts.all_abis,
        opts.emulator,
        opts.signing,
    );
    defer allocator.free(apk_path);

    std.debug.print("labelle android deploy: uploading {s} to GitHub Releases as {s}...\n", .{ apk_path, tag });

    // Match the label the APK itself ships with so the release name
    // in GitHub reads the same as what testers see on their device.
    // `packageApkWithAbis` uses `android.app_name ?? cfg.title`; we
    // mirror that precedence, then fall back to `cfg.name` instead of
    // printing an empty label if both are blank.
    const android_cfg = cfg.android orelse project_config.AndroidConfig{};
    const app_label = if (android_cfg.app_name.len > 0)
        android_cfg.app_name
    else if (cfg.title.len > 0)
        cfg.title
    else
        cfg.name;
    const release_title = try std.fmt.allocPrint(allocator, "{s} {s}", .{ app_label, tag });
    defer allocator.free(release_title);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        "gh",          "release", "create",
        tag,           apk_path,  "--title",
        release_title,
    });
    if (channel_is_prerelease) try argv.append(allocator, "--prerelease");
    if (opts.notes_file) |f| {
        try argv.append(allocator, "--notes-file");
        try argv.append(allocator, f);
    } else {
        try argv.append(allocator, "--generate-notes");
    }

    const res = try util.runCmd(allocator, argv.items);
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    switch (res.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print(
                    "labelle android deploy: gh release create failed (exit {d}):\n{s}\n",
                    .{ code, res.stderr },
                );
                return error.DeployFailed;
            }
        },
        else => {
            std.debug.print("labelle android deploy: gh release create terminated abnormally\n", .{});
            return error.DeployFailed;
        },
    }

    std.debug.print(
        \\labelle android deploy: release {s} published.
        \\  Testers with Obtainium subscribed to this repo will see the update on next poll.
        \\
    , .{tag});
}

/// Probe that `gh` is installed and authenticated. Cheaper to fail
/// here than to build the APK and then discover the uploader is
/// missing.
fn ensureGhAvailable(allocator: std.mem.Allocator) !void {
    const res = util.runCmd(allocator, &.{ "gh", "auth", "status" }) catch |err| {
        std.debug.print(
            \\labelle android deploy: failed to run `gh` ({s}).
            \\  Install it from https://cli.github.com/ and run `gh auth login`.
            \\
        , .{@errorName(err)});
        return error.DeployFailed;
    };
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print(
            \\labelle android deploy: `gh` is installed but not authenticated.
            \\  Run `gh auth login` to set up GitHub access.
            \\
        , .{});
        return error.DeployFailed;
    }
}
