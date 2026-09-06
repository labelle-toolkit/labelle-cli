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

fn parseUpdateArgs(cmd_args: []const []const u8) !UpdateArgs {
    var out = UpdateArgs{};
    for (cmd_args) |arg| {
        if (std.mem.eql(u8, arg, "--no-path")) {
            out.skip_path = true;
        } else if (std.mem.eql(u8, arg, "--check")) {
            out.check = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            out.json = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            // Reject unknown flags instead of silently treating them as the
            // target version. Critical: a typo like `--chek` — especially
            // `--chek 1.60.0`, where the good version would overwrite the
            // dropped typo — must NEVER slip past the read-only `--check`
            // guard into the binary-replacing install path (CodeRabbit,
            // PR #299). Mirrors the `labelle status` unknown-flag convention.
            std.debug.print("labelle update: unknown flag '{s}'\n", .{arg});
            std.debug.print("  usage: labelle update [ver] [--no-path] [--check] [--json]\n", .{});
            return error.InvalidArguments;
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

/// How many times the Windows helper retries the replace before giving up.
/// At ~1s per attempt that is a ~30s window for the parent `labelle.exe` to
/// exit and release its lock on the binary.
const windows_update_max_tries = 30;

/// Build the Windows self-replace helper script (labelle-cli#375).
///
/// The running `labelle.exe` cannot overwrite itself, so `update` writes this
/// batch file, spawns it detached, and exits; the helper waits for the lock to
/// drop, moves the freshly downloaded binary into place, and deletes itself.
///
/// Three things here are deliberate and must not be "simplified" back:
///
///   1. **The delay is `ping.exe` by ABSOLUTE PATH, not `timeout`.** Two
///      independent reasons, both verified on Windows 11:
///
///      a. `timeout` is not a `cmd` builtin — it lives in
///         `%SystemRoot%\System32` and is resolved through `PATH`. The helper
///         inherits the environment of whatever shell ran `labelle update`,
///         and Git Bash / MSYS2 / Cygwin put their own `/usr/bin` (which
///         ships a GNU coreutils `timeout.exe`) AHEAD of System32. GNU
///         `timeout` rejects the DOS `/t` switch, so the bare name produced
///         `timeout: invalid time interval '/t'` and returned instantly.
///
///      b. Even the REAL `System32\timeout.exe` refuses to run when stdin is
///         not a console — it prints `ERROR: Input redirection is not
///         supported, exiting the process immediately.` and exits in ~40ms.
///         The helper is spawned detached by the CLI, so its stdin is exactly
///         that. Fixing only (a) would still leave the wait broken here.
///
///      `ping -n 2 127.0.0.1` is the redirection-proof batch delay (~1s) and
///      is unaffected by both. The absolute path keeps (a) fixed for it too.
///
///      Losing the wait is not cosmetic: it makes the `move` race the
///      exiting parent, and a failed `move` turns `goto wait` into an
///      unthrottled busy loop.
///
///   2. **The retry loop is BOUNDED** (`windows_update_max_tries`). Even with
///      a working sleep, an indefinite loop leaves a stray background process
///      hammering `move` forever if the old binary never unlocks. On give-up
///      it prints where the new binary is so the user can move it by hand.
///
///   3. **Self-delete uses `(goto) 2>nul & del "%~f0"`.** A plain
///      `del "%~f0"` deletes the script while `cmd` still holds an open read
///      handle on it, which is what printed the stray
///      `The batch file cannot be found.` line. Popping the batch context
///      first makes the delete the last thing that happens.
///
/// Caller owns the returned buffer.
fn windowsUpdateScript(
    allocator: std.mem.Allocator,
    tmp_path: []const u8,
    bin_path: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\@echo off
        \\setlocal
        \\if not defined SystemRoot set "SystemRoot=C:\Windows"
        \\set "LABELLE_SLEEP=%SystemRoot%\System32\ping.exe"
        \\set /a tries=0
        \\:wait
        \\"%LABELLE_SLEEP%" -n 2 127.0.0.1 >nul 2>&1
        \\move /Y "{s}" "{s}" >nul 2>&1
        \\if not errorlevel 1 goto done
        \\set /a tries+=1
        \\if %tries% lss {d} goto wait
        \\echo labelle: could not replace "{s}" after {d} attempts.
        \\echo labelle: the new binary is at "{s}" — move it there manually.
        \\goto end
        \\:done
        \\echo Update complete.
        \\:end
        \\(goto) 2>nul & del "%~f0"
        \\
    , .{
        tmp_path,
        bin_path,
        windows_update_max_tries,
        bin_path,
        windows_update_max_tries,
        tmp_path,
    });
}

/// Self-update the CLI binary by downloading from the release server.
pub fn cmdUpdate(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    const parsed = try parseUpdateArgs(cmd_args);

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

        const bat_content = try windowsUpdateScript(allocator, tmp_path, bin_path);
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
        const a = try parseUpdateArgs(&.{});
        try testing.expect(!a.reportOnly());
        try testing.expect(!a.skip_path);
        try testing.expect(a.version_arg == null);
    }

    test "--no-path is still recognized and stays install mode" {
        const a = try parseUpdateArgs(&.{"--no-path"});
        try testing.expect(a.skip_path);
        try testing.expect(!a.reportOnly());
    }

    test "--check selects read-only report mode (not json)" {
        const a = try parseUpdateArgs(&.{"--check"});
        try testing.expect(a.check);
        try testing.expect(!a.json);
        try testing.expect(a.reportOnly());
    }

    test "--json implies report-only (never mutates)" {
        const a = try parseUpdateArgs(&.{"--json"});
        try testing.expect(a.json);
        try testing.expect(a.reportOnly());
    }

    test "--check --json together" {
        const a = try parseUpdateArgs(&.{ "--check", "--json" });
        try testing.expect(a.check);
        try testing.expect(a.json);
        try testing.expect(a.reportOnly());
    }

    test "explicit version arg is captured alongside --check" {
        const a = try parseUpdateArgs(&.{ "--check", "1.99.0" });
        try testing.expect(a.reportOnly());
        try testing.expectEqualStrings("1.99.0", a.version_arg.?);
    }

    test "unknown flag is rejected, not treated as a version" {
        // Without the reject branch this returns version_arg="--jso" and
        // proceeds to the mutating install path — CodeRabbit PR #299.
        try testing.expectError(error.InvalidArguments, parseUpdateArgs(&.{"--jso"}));
    }

    test "typo'd flag before a real version is rejected (never mutates)" {
        // The safety-critical exploit: `--chek 1.60.0` — the dropped typo
        // leaves 1.60.0 as version_arg and INSTALLS it. Reject on the
        // unknown flag before the version is ever considered.
        try testing.expectError(error.InvalidArguments, parseUpdateArgs(&.{ "--chek", "1.60.0" }));
    }

    test "a bare non-dash token is still a valid version positional" {
        const a = try parseUpdateArgs(&.{"1.2.3"});
        try testing.expect(!a.reportOnly());
        try testing.expectEqualStrings("1.2.3", a.version_arg.?);
    }
};

/// The Windows self-replace helper script (labelle-cli#375). Re-exported into
/// cli.zig so `zspec.runAll` walks into it. These run on every host, not just
/// Windows: the bug was in the generated TEXT, and a Windows-only spec would
/// leave it unguarded on the two CI runners that finish first.
pub const WindowsUpdateScriptSpec = struct {
    const testing = std.testing;

    fn script(allocator: std.mem.Allocator) ![]u8 {
        return windowsUpdateScript(allocator, "C:\\tmp\\labelle-new.exe", "C:\\bin\\labelle.exe");
    }

    test "the delay never uses `timeout`, under any spelling" {
        // Reason (a): a bare `timeout` is resolved through PATH, and Git Bash
        // / MSYS2 / Cygwin shadow System32 with a GNU coreutils `timeout.exe`
        // that rejects `/t`. Reason (b): even the real System32 timeout.exe
        // bails out when stdin is not a console, which is exactly how the
        // helper is spawned. Neither spelling is acceptable.
        const s = try script(testing.allocator);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "timeout") == null);
    }

    test "the delay is ping.exe by absolute path" {
        const s = try script(testing.allocator);
        defer testing.allocator.free(s);

        try testing.expect(std.mem.indexOf(u8, s, "%SystemRoot%\\System32\\ping.exe") != null);
        // No line may invoke a system tool as a bare, PATH-resolved word.
        var lines = std.mem.splitScalar(u8, s, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            try testing.expect(!std.mem.startsWith(u8, trimmed, "ping "));
        }
    }

    test "SystemRoot is defaulted before it is used" {
        const s = try script(testing.allocator);
        defer testing.allocator.free(s);

        const guard = std.mem.indexOf(u8, s, "if not defined SystemRoot").?;
        const use = std.mem.indexOf(u8, s, "%SystemRoot%\\System32\\ping.exe").?;
        try testing.expect(guard < use);
    }

    test "the retry loop is bounded, not an unthrottled goto" {
        // A failed `move` used to jump back to a `timeout` that returned
        // instantly, spinning a background process at 100% CPU forever.
        const s = try script(testing.allocator);
        defer testing.allocator.free(s);

        try testing.expect(std.mem.indexOf(u8, s, "set /a tries+=1") != null);
        try testing.expect(std.mem.indexOf(u8, s, "lss 30") != null);
    }

    test "give-up branch tells the user where the new binary is" {
        const s = try script(testing.allocator);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "C:\\tmp\\labelle-new.exe\" — move it there manually") != null);
    }

    test "self-delete pops the batch context first" {
        // A plain `del \"%~f0\"` printed `The batch file cannot be found.`
        // because cmd still held a read handle on the script.
        const s = try script(testing.allocator);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "(goto) 2>nul & del \"%~f0\"") != null);
    }

    test "still moves the downloaded binary onto the installed path" {
        const s = try script(testing.allocator);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "move /Y \"C:\\tmp\\labelle-new.exe\" \"C:\\bin\\labelle.exe\"") != null);
        try testing.expect(std.mem.indexOf(u8, s, "echo Update complete.") != null);
    }
};
