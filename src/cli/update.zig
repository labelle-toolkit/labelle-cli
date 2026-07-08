const std = @import("std");
const project_config = @import("project_config.zig");
const asm_cache = @import("asm_cache.zig");
const util = @import("util.zig");
const config = @import("config.zig");
const update_check = @import("update_check.zig");

/// Release server that hosts the CLI binaries + `latest.txt`.
const r2_base_url = "https://releases.labelle.games/cli";

/// Parsed `update` flags. `--check`/`--json` select the read-only,
/// machine-readable reporting mode (labelle-cli#276); `--json` implies
/// `--check` so a tool asking for JSON never triggers a mutating install.
const UpdateArgs = struct {
    skip_path: bool = false,
    check: bool = false,
    json: bool = false,
    version_arg: ?[]const u8 = null,

    /// True when the invocation is a read-only version check rather than a
    /// self-update install.
    fn reportOnly(self: UpdateArgs) bool {
        return self.check or self.json;
    }
};

fn parseUpdateArgs(cmd_args: []const []const u8) UpdateArgs {
    var out = UpdateArgs{};
    for (cmd_args) |arg| {
        if (std.mem.eql(u8, arg, "--no-path")) {
            out.skip_path = true;
        } else if (std.mem.eql(u8, arg, "--check")) {
            out.check = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            out.json = true;
        } else {
            out.version_arg = arg;
        }
    }
    return out;
}

/// Fetch the newest published CLI version from the R2 release server.
/// Returns an owned, trimmed version string (leading `v` stripped), or
/// `null` on any failure (curl missing, network error, HTTP error, empty
/// body). Read-only — never downloads a binary.
fn fetchLatestCliVersion(allocator: std.mem.Allocator) ?[]u8 {
    const latest_url = r2_base_url ++ "/latest.txt";
    const result = util.runCmd(allocator, &.{ "curl", "-s", "-f", latest_url }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    var latest = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (std.mem.startsWith(u8, latest, "v")) latest = latest[1..];
    if (latest.len == 0) return null;
    return allocator.dupe(u8, latest) catch null;
}

/// `labelle update --check [--json]` (labelle-cli#276): report the running
/// CLI version vs the newest published release WITHOUT installing anything.
/// Emits `{ "cli": {...}, "packages": [] }` under `--json` (studio#7) or a
/// human line otherwise. Exits 2 when an update is available, else 0.
fn cmdUpdateCheck(allocator: std.mem.Allocator, version_arg: ?[]const u8, json: bool) !void {
    // `latest` is either an explicit version arg (borrowed from argv) or a
    // fetched owned string; track ownership so we free only what we alloc.
    var latest_owned: ?[]u8 = null;
    defer if (latest_owned) |l| allocator.free(l);
    const latest: ?[]const u8 = version_arg orelse blk: {
        latest_owned = fetchLatestCliVersion(allocator);
        break :blk latest_owned;
    };

    const cli = update_check.cliStatus(project_config.CLI_VERSION, latest);
    const report = update_check.Report{ .cli = cli };

    var out_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(config.globalIo(), &out_buf);
    if (json) {
        update_check.writeJson(&w.interface, report) catch {};
    } else {
        update_check.writeHumanCli(&w.interface, cli) catch {};
    }
    w.interface.flush() catch {};

    const code = update_check.exitCode(report);
    if (code != 0) {
        // std.process.exit skips defers — free before leaving.
        if (latest_owned) |l| allocator.free(l);
        latest_owned = null;
        std.process.exit(code);
    }
}

/// Self-update the CLI binary by downloading from the release server.
pub fn cmdUpdate(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    const parsed = parseUpdateArgs(cmd_args);

    // Read-only reporting mode: never mutate/install (labelle-cli#276).
    if (parsed.reportOnly()) {
        return cmdUpdateCheck(allocator, parsed.version_arg, parsed.json);
    }

    const skip_path = parsed.skip_path;
    const version_arg = parsed.version_arg;

    std.debug.print("labelle: checking for updates...\n", .{});
    std.debug.print("  current version: {s}\n\n", .{project_config.CLI_VERSION});

    var target_version: []const u8 = undefined;
    var target_version_owned: ?[]u8 = null;
    defer if (target_version_owned) |v| allocator.free(v);

    if (version_arg) |ver| {
        target_version = ver;
    } else {
        target_version_owned = fetchLatestCliVersion(allocator) orelse {
            std.debug.print("labelle: could not check for updates (is curl installed / are you online?)\n", .{});
            printManualUpdateInstructions("latest");
            return;
        };
        target_version = target_version_owned.?;
    }

    const current = util.parseVersion(project_config.CLI_VERSION);
    const target = util.parseVersion(target_version);

    if (current >= target) {
        if (current > target) {
            std.debug.print("  you are running a newer version ({s}) than {s}\n", .{ project_config.CLI_VERSION, target_version });
        } else {
            std.debug.print("  already on the latest version ({s})\n", .{project_config.CLI_VERSION});
        }
        return;
    }

    std.debug.print("  new version available: {s}\n\n", .{target_version});

    const builtin = @import("builtin");
    const os_name: []const u8 = switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "windows",
        else => {
            std.debug.print("labelle: unsupported platform for binary download\n", .{});
            printManualUpdateInstructions(target_version);
            return;
        },
    };
    const arch_name: []const u8 = switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        else => {
            std.debug.print("labelle: unsupported architecture for binary download\n", .{});
            printManualUpdateInstructions(target_version);
            return;
        },
    };

    const download_url = try std.fmt.allocPrint(allocator, "{s}/v{s}/labelle-{s}-{s}", .{
        r2_base_url, target_version, os_name, arch_name,
    });
    defer allocator.free(download_url);

    const tmp_path = try util.getTempFilePath(allocator, "labelle-update");
    defer allocator.free(tmp_path);
    std.debug.print("  downloading {s}...\n", .{download_url});

    const dl_result = util.runCmd(allocator, &.{ "curl", "-s", "-f", "-o", tmp_path, download_url }) catch {
        std.debug.print("labelle: download failed (is curl installed?)\n", .{});
        printManualUpdateInstructions(target_version);
        return;
    };
    defer allocator.free(dl_result.stdout);
    defer allocator.free(dl_result.stderr);

    switch (dl_result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("labelle: download failed (HTTP error)\n", .{});
            printManualUpdateInstructions(target_version);
            return;
        },
        else => {
            std.debug.print("labelle: download process terminated abnormally\n", .{});
            return;
        },
    }

    if (builtin.os.tag != .windows) {
        _ = util.runCmd(allocator, &.{ "chmod", "+x", tmp_path }) catch {};
    }

    const cache_root = asm_cache.getCacheRoot(allocator) catch {
        std.debug.print("labelle: could not determine cache root\n", .{});
        return;
    };
    defer allocator.free(cache_root);

    const bin_dir = try std.fs.path.join(allocator, &.{ cache_root, "bin" });
    defer allocator.free(bin_dir);

    const bin_name: []const u8 = if (builtin.os.tag == .windows) "labelle.exe" else "labelle";
    const bin_path = try std.fs.path.join(allocator, &.{ bin_dir, bin_name });
    defer allocator.free(bin_path);

    std.Io.Dir.cwd().createDirPath(config.globalIo(), bin_dir) catch |err| {
        std.debug.print("labelle: could not create {s}: {any}\n", .{ bin_dir, err });
        return;
    };

    if (builtin.os.tag == .windows) {
        const bat_path = try std.fs.path.join(allocator, &.{ bin_dir, "labelle-update.bat" });
        defer allocator.free(bat_path);

        const bat_content = try std.fmt.allocPrint(allocator,
            \\@echo off
            \\:wait
            \\timeout /t 1 /nobreak >nul
            \\move /Y "{s}" "{s}" >nul 2>&1
            \\if errorlevel 1 goto wait
            \\echo Update complete.
            \\del "%~f0"
            \\
        , .{ tmp_path, bin_path });
        defer allocator.free(bat_content);

        const bat_file = std.Io.Dir.cwd().createFile(config.globalIo(), bat_path, .{}) catch |err| {
            std.debug.print("labelle: could not create update script: {any}\n", .{err});
            std.debug.print("  downloaded to {s} — move it manually to {s}\n", .{ tmp_path, bin_path });
            return;
        };
        const io_w = config.globalIo();
        bat_file.writeStreamingAll(io_w, bat_content) catch {
            bat_file.close(io_w);
            std.debug.print("labelle: could not write update script\n", .{});
            std.debug.print("  downloaded to {s} — move it manually to {s}\n", .{ tmp_path, bin_path });
            return;
        };
        bat_file.close(io_w);

        _ = std.process.spawn(io_w, .{
            .argv = &.{ "cmd.exe", "/c", "start", "/b", bat_path },
        }) catch |err| {
            std.debug.print("labelle: could not launch update script: {any}\n", .{err});
            std.debug.print("  downloaded to {s} — move it manually to {s}\n", .{ tmp_path, bin_path });
            return;
        };

        std.debug.print("\n  downloaded v{s}\n", .{target_version});
        std.debug.print("  the binary will be replaced at {s} after this process exits\n\n", .{bin_path});
    } else {
        const mv_result = util.runCmd(allocator, &.{ "mv", "-f", tmp_path, bin_path });

        if (mv_result) |result2| {
            defer allocator.free(result2.stdout);
            defer allocator.free(result2.stderr);
            switch (result2.term) {
                .exited => |code| if (code != 0) {
                    std.debug.print("labelle: could not move binary to {s}\n", .{bin_path});
                    std.debug.print("  downloaded v{s} to {s}\n", .{ target_version, tmp_path });
                    std.debug.print("  to complete the update, run:\n", .{});
                    std.debug.print("    mv '{s}' '{s}'\n", .{ tmp_path, bin_path });
                    return;
                },
                else => {
                    std.debug.print("labelle: could not move binary to {s}\n", .{bin_path});
                    std.debug.print("  downloaded v{s} to {s}\n", .{ target_version, tmp_path });
                    std.debug.print("  to complete the update, run:\n", .{});
                    std.debug.print("    mv '{s}' '{s}'\n", .{ tmp_path, bin_path });
                    return;
                },
            }
        } else |_| {
            std.debug.print("labelle: could not move binary to {s}\n", .{bin_path});
            std.debug.print("  downloaded v{s} to {s}\n", .{ target_version, tmp_path });
            std.debug.print("  to complete the update, run:\n", .{});
            std.debug.print("    mv '{s}' '{s}'\n", .{ tmp_path, bin_path });
            return;
        }

        std.debug.print("\n  updated to v{s}\n", .{target_version});
        std.debug.print("  installed at {s}\n\n", .{bin_path});
    }

    if (!skip_path) {
        setupPath(allocator, bin_dir);
    }

    checkOldBinary(bin_path);
}

fn setupPath(allocator: std.mem.Allocator, bin_dir: []const u8) void {
    const builtin = @import("builtin");

    if (builtin.os.tag == .windows) {
        setupPathWindows(allocator, bin_dir);
        return;
    }

    if (config.globalEnviron().getAlloc(allocator, "PATH")) |current_path| {
        defer allocator.free(current_path);
        if (util.pathContainsDir(current_path, bin_dir)) return;
    } else |_| {}

    const shell_env = config.globalEnviron().getAlloc(allocator, "SHELL") catch {
        std.debug.print("  could not detect shell — add {s} to your PATH manually\n\n", .{bin_dir});
        return;
    };
    defer allocator.free(shell_env);

    const home_dir = config.globalEnviron().getAlloc(allocator, "HOME") catch {
        std.debug.print("  could not determine home directory — add {s} to your PATH manually\n\n", .{bin_dir});
        return;
    };
    defer allocator.free(home_dir);

    const path_line = std.fmt.allocPrint(allocator, "export PATH=\"{s}:$PATH\"", .{bin_dir}) catch return;
    defer allocator.free(path_line);

    if (std.mem.endsWith(u8, shell_env, "zsh")) {
        const rc_path = std.fs.path.join(allocator, &.{ home_dir, ".zshrc" }) catch return;
        defer allocator.free(rc_path);
        if (util.appendToProfile(allocator, rc_path, path_line, bin_dir)) {
            std.debug.print("  added to PATH in ~/.zshrc\n", .{});
            std.debug.print("  run `source ~/.zshrc` or restart your terminal\n\n", .{});
        }
    } else if (std.mem.endsWith(u8, shell_env, "bash")) {
        const bashrc = std.fs.path.join(allocator, &.{ home_dir, ".bashrc" }) catch return;
        defer allocator.free(bashrc);
        const bash_profile = std.fs.path.join(allocator, &.{ home_dir, ".bash_profile" }) catch return;
        defer allocator.free(bash_profile);

        const target_rc = if (builtin.os.tag == .macos and !util.fileExists(bashrc))
            bash_profile
        else
            bashrc;

        if (util.appendToProfile(allocator, target_rc, path_line, bin_dir)) {
            const rc_name = std.fs.path.basename(target_rc);
            std.debug.print("  added to PATH in ~/{s}\n", .{rc_name});
            std.debug.print("  run `source ~/{s}` or restart your terminal\n\n", .{rc_name});
        }
    } else if (std.mem.endsWith(u8, shell_env, "fish")) {
        const fish_cmd = std.fmt.allocPrint(allocator, "fish_add_path {s}", .{bin_dir}) catch return;
        defer allocator.free(fish_cmd);
        if (util.runCmd(allocator, &.{ "fish", "-c", fish_cmd })) |result| {
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            switch (result.term) {
                .exited => |code| if (code == 0) {
                    std.debug.print("  added to PATH via fish_add_path\n\n", .{});
                } else {
                    std.debug.print("  fish_add_path failed — add {s} to your PATH manually\n\n", .{bin_dir});
                },
                else => std.debug.print("  fish_add_path failed — add {s} to your PATH manually\n\n", .{bin_dir}),
            }
        } else |_| {
            std.debug.print("  could not run fish — add {s} to your PATH manually\n\n", .{bin_dir});
        }
    } else {
        std.debug.print("  add {s} to your PATH to use labelle from anywhere\n\n", .{bin_dir});
    }
}

fn setupPathWindows(allocator: std.mem.Allocator, bin_dir: []const u8) void {
    const get_result = util.runCmd(allocator, &.{
        "powershell",                                            "-NoProfile", "-Command",
        "[Environment]::GetEnvironmentVariable('Path', 'User')",
    }) catch {
        std.debug.print("  could not read current PATH — add {s} to your PATH manually\n\n", .{bin_dir});
        return;
    };
    defer allocator.free(get_result.stdout);
    defer allocator.free(get_result.stderr);

    const current = std.mem.trim(u8, get_result.stdout, &std.ascii.whitespace);

    var iter = std.mem.splitScalar(u8, current, ';');
    while (iter.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, &std.ascii.whitespace);
        if (util.windowsPathEql(trimmed, bin_dir)) return;
    }

    const escaped_dir = util.escapePowerShellString(allocator, bin_dir) catch return;
    defer allocator.free(escaped_dir);
    const set_cmd = std.fmt.allocPrint(allocator, "[Environment]::SetEnvironmentVariable('Path', '{s};' + [Environment]::GetEnvironmentVariable('Path', 'User'), 'User')", .{escaped_dir}) catch return;
    defer allocator.free(set_cmd);

    if (util.runCmd(allocator, &.{ "powershell", "-NoProfile", "-Command", set_cmd })) |set_result| {
        defer allocator.free(set_result.stdout);
        defer allocator.free(set_result.stderr);
        switch (set_result.term) {
            .exited => |code| if (code == 0) {
                std.debug.print("  added {s} to user PATH (restart your terminal to take effect)\n\n", .{bin_dir});
            } else {
                std.debug.print("  could not update PATH via registry: {s}\n", .{set_result.stderr});
                std.debug.print("  add {s} to your PATH manually\n\n", .{bin_dir});
            },
            else => {
                std.debug.print("  could not update PATH — add {s} to your PATH manually\n\n", .{bin_dir});
            },
        }
    } else |_| {
        std.debug.print("  could not run PowerShell — add {s} to your PATH manually\n\n", .{bin_dir});
    }
}

fn checkOldBinary(new_path: []const u8) void {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return;

    const system_paths = [_][]const u8{ "/usr/local/bin/labelle", "/usr/bin/labelle" };
    for (system_paths) |sys_path| {
        if (std.mem.eql(u8, sys_path, new_path)) continue;
        if (util.fileExists(sys_path)) {
            std.debug.print("  warning: found old labelle binary at {s}\n", .{sys_path});
            std.debug.print("  remove it with: sudo rm {s}\n", .{sys_path});
            std.debug.print("  the CLI now runs from {s}\n\n", .{new_path});
            return;
        }
    }
}

fn printManualUpdateInstructions(version: []const u8) void {
    std.debug.print("\n  to update manually, download from:\n", .{});
    std.debug.print("    https://releases.labelle.games/cli/v{s}/\n\n", .{version});
    std.debug.print("  or build from source:\n", .{});
    std.debug.print("    git clone https://github.com/labelle-toolkit/labelle-cli.git\n", .{});
    std.debug.print("    zig build -Doptimize=ReleaseSafe\n", .{});
}

// ── Tests ────────────────────────────────────────────────────────────

test {
    @import("zspec").runAll(@This());
}

/// Flag parsing for `labelle update` (labelle-cli#276). Re-exported into
/// cli.zig so `zspec.runAll` walks into it under `zig build test`.
pub const ParseUpdateArgsSpec = struct {
    const testing = std.testing;

    test "bare update: install mode, no version, keeps PATH setup" {
        const a = parseUpdateArgs(&.{});
        try testing.expect(!a.reportOnly());
        try testing.expect(!a.skip_path);
        try testing.expect(a.version_arg == null);
    }

    test "--no-path is still recognized and stays install mode" {
        const a = parseUpdateArgs(&.{"--no-path"});
        try testing.expect(a.skip_path);
        try testing.expect(!a.reportOnly());
    }

    test "--check selects read-only report mode (not json)" {
        const a = parseUpdateArgs(&.{"--check"});
        try testing.expect(a.check);
        try testing.expect(!a.json);
        try testing.expect(a.reportOnly());
    }

    test "--json implies report-only (never mutates)" {
        const a = parseUpdateArgs(&.{"--json"});
        try testing.expect(a.json);
        try testing.expect(a.reportOnly());
    }

    test "--check --json together" {
        const a = parseUpdateArgs(&.{ "--check", "--json" });
        try testing.expect(a.check);
        try testing.expect(a.json);
        try testing.expect(a.reportOnly());
    }

    test "explicit version arg is captured alongside --check" {
        const a = parseUpdateArgs(&.{ "--check", "1.99.0" });
        try testing.expect(a.reportOnly());
        try testing.expectEqualStrings("1.99.0", a.version_arg.?);
    }
};
