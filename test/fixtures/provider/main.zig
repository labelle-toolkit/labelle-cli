const std = @import("std");
pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    // `provider-probe linger`: a grandchild the watch suites start from a
    // hook or a replacement, to prove it does not outlive `labelle run`.
    {
        var probe_args = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
        _ = probe_args.skip();
        if (probe_args.next()) |first| if (std.mem.eql(u8, first, "linger")) {
            init.io.sleep(std.Io.Duration.fromSeconds(120), .awake) catch {};
            return 0;
        };
    }
    const context = try init.minimal.environ.getAlloc(a, "LABELLE_CONTEXT");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, context, a, .limited(1024 * 1024));
    const ctx = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    const output = ctx.value.object.get("output_dir").?.string;
    const setting_file = ctx.value.object.get("config_file").?;
    const setting: ?[]const u8 = if (setting_file == .null) null else blk: {
        const raw = try std.Io.Dir.cwd().readFileAlloc(init.io, setting_file.string, a, .limited(1024 * 1024));
        const settings = try std.json.parseFromSlice(struct { label: []const u8 }, a, raw, .{});
        break :blk settings.value.label;
    };
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    _ = args.skip();
    var collected: std.ArrayList([]const u8) = .empty;
    while (args.next()) |arg| try collected.append(a, arg);
    const capture = try std.json.Stringify.valueAlloc(a, .{
        .context_path = context,
        .context = ctx.value,
        .args = collected.items,
        .setting = setting,
        .revision = @import("revision.zig").value,
        .cwd = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", a),
    }, .{});
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fs.path.join(a, &.{ output, "capture.json" }),
        .data = capture,
    });
    // Hooks share one output directory per step, so appending one line per
    // invocation to `hooks.log` makes their order observable. The timestamp
    // is monotonic within a host; `lock_file_exists` is checked at the moment
    // the hook runs (the lock must already exist for a `before generate` hook).
    const invocation = ctx.value.object.get("invocation").?;
    const lock_file = ctx.value.object.get("lock_file").?;
    const lock_exists = lock_file == .string and blk: {
        std.Io.Dir.cwd().access(init.io, lock_file.string, .{}) catch break :blk false;
        break :blk true;
    };
    // What the step's output directory holds at the moment the hook runs
    // (sorted names), so an `after` hook can prove it saw the finished
    // artifact rather than an intermediate tree (Codex P2 on #420).
    var output_entries: std.ArrayList([]const u8) = .empty;
    if (std.Io.Dir.cwd().openDir(init.io, output, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(init.io);
        var it = dir.iterate();
        while (try it.next(init.io)) |entry| try output_entries.append(a, try a.dupe(u8, entry.name));
    } else |_| {}
    std.mem.sort([]const u8, output_entries.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    // What this invocation's own process sees of an environment an earlier
    // hook contributed (contract §2 `env_file`, wire 1.3.0+): the probe
    // variable the suites contribute, and the first PATH entry.
    const probe_toolchain: ?[]const u8 = init.minimal.environ.getAlloc(a, "PROBE_TOOLCHAIN") catch null;
    const path_head: ?[]const u8 = if (init.minimal.environ.getAlloc(a, "PATH")) |path_value|
        path_value[0 .. std.mem.indexOfScalar(u8, path_value, std.fs.path.delimiter) orelse path_value.len]
    else |_|
        null;
    const line = try std.json.Stringify.valueAlloc(a, .{
        .invocation = invocation,
        .target = ctx.value.object.get("target").?,
        .output_dir = output,
        .output_entries = output_entries.items,
        .lock_file = lock_file,
        .lock_file_exists = lock_exists,
        .optimize = ctx.value.object.get("optimize").?,
        .progress = ctx.value.object.get("progress").?,
        .package_dir = ctx.value.object.get("package_dir").?,
        // The whole context, so a suite can assert any key a wire version
        // adds (`target_dir`, `run`) and that an older wire lacks it.
        .context = ctx.value,
        .probe_toolchain = probe_toolchain,
        .path_head = path_head,
        .nanoseconds = std.Io.Timestamp.now(init.io, .awake).nanoseconds,
    }, .{});
    const log_path = try std.fs.path.join(a, &.{ output, "hooks.log" });
    const previous = std.Io.Dir.cwd().readFileAlloc(init.io, log_path, a, .limited(1024 * 1024)) catch "";
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = log_path,
        .data = try std.mem.concat(a, u8, &.{ previous, line, "\n" }),
    });
    // `PROVIDER_PROBE_SLOW=<hook id>|<marker>` makes that hook — once the
    // file `<marker>.arm` exists — start a lingering grandchild, write
    // `<own pid> <grandchild pid>` to <marker> and then sleep, so a suite
    // can stop the session while it runs and check that neither process
    // survives it.
    if (init.minimal.environ.getAlloc(a, "PROVIDER_PROBE_SLOW")) |spec| {
        const bar = std.mem.indexOfScalar(u8, spec, '|') orelse return error.BadProbeSlowSpec;
        const armed = if (std.Io.Dir.cwd().access(init.io, try std.fmt.allocPrint(a, "{s}.arm", .{spec[bar + 1 ..]}), .{})) |_| true else |_| false;
        if (armed and invocation == .object and std.mem.eql(u8, invocation.object.get("id").?.string, spec[0..bar])) {
            try linger(init, a, spec[bar + 1 ..]);
            init.io.sleep(std.Io.Duration.fromSeconds(120), .awake) catch {};
            return 0;
        }
    } else |_| {}
    // The watch-capable run replacement (contract §2 `run.watch`, wire
    // 1.3.0+): a stand-in for a dev server. It never serves HTTP: it polls
    // the generation file and, on every new generation, appends
    // `gen=<n> data=<bin/data.txt as published>` to `watch.log` in its
    // step output directory — reading the PUBLISHED output directory, the
    // way a server would serve it. It exits with the code written to
    // `PROVIDER_PROBE_WATCH_STOP` (a file path) once that file exists, and
    // with 3 after two minutes. `PROVIDER_PROBE_WATCH_CHILD=<marker>`
    // makes it start a lingering grandchild first (see `linger`).
    if (invocation == .object and ctx.value.object.get("run") != null) {
        const run_ctx = ctx.value.object.get("run").?;
        const watch_ctx = if (run_ctx == .object) run_ctx.object.get("watch") else null;
        if (watch_ctx) |w| if (w == .object) return watchServer(init, a, output, w.object);
    }
    // `PROVIDER_PROBE_PATCH=<hook id>` makes that hook post-process the step
    // output the way a signing/stripping hook would: it overwrites
    // `<output_dir>/bin/data.txt`, a file the fixture game's build INSTALLS
    // from source, so any later redundant build that re-installs the
    // original is observable from the launched game (Codex P2 on #420).
    if (init.minimal.environ.getAlloc(a, "PROVIDER_PROBE_PATCH")) |patch_id| {
        if (invocation == .object and std.mem.eql(u8, invocation.object.get("id").?.string, patch_id)) {
            try std.Io.Dir.cwd().writeFile(init.io, .{
                .sub_path = try std.fs.path.join(a, &.{ output, "bin", "data.txt" }),
                .data = try std.fmt.allocPrint(a, "patched:{s}", .{patch_id}),
            });
        }
    } else |_| {}
    // `PROVIDER_PROBE_COPY=<hook id>|<src>|<dest>` makes that hook produce a
    // generation INPUT the way an asset-generating hook would: it copies the
    // absolute `<src>` to `<dest>`, relative to the project root (the hook's
    // cwd), creating the parent directory. A `before generate` hook's output
    // must be visible to every pre-pass that reads declared resources
    // (Codex P2 on #420).
    if (init.minimal.environ.getAlloc(a, "PROVIDER_PROBE_COPY")) |spec| {
        var parts = std.mem.splitScalar(u8, spec, '|');
        const copy_id = parts.next() orelse "";
        const src = parts.next() orelse "";
        const dest = parts.next() orelse "";
        if (invocation == .object and std.mem.eql(u8, invocation.object.get("id").?.string, copy_id)) {
            if (std.fs.path.dirname(dest)) |dir| try std.Io.Dir.cwd().createDirPath(init.io, dir);
            const copied = try std.Io.Dir.cwd().readFileAlloc(init.io, src, a, .limited(16 * 1024 * 1024));
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = dest, .data = copied });
        }
    } else |_| {}
    // `PROVIDER_PROBE_ENV=<hook id>|<file>` makes that hook contribute an
    // environment (contract §2 `env_file`, wire 1.3.0+): it copies `<file>`'s
    // bytes, verbatim, to the `env_file` its context names, so a suite can
    // hand it a valid, empty or malformed document alike. A hook whose
    // context has no env_file exits 9 instead: the slot is wrong.
    if (init.minimal.environ.getAlloc(a, "PROVIDER_PROBE_ENV")) |spec| {
        const bar = std.mem.indexOfScalar(u8, spec, '|') orelse return error.BadProbeEnvSpec;
        if (invocation == .object and std.mem.eql(u8, invocation.object.get("id").?.string, spec[0..bar])) {
            const env_file = ctx.value.object.get("env_file") orelse return 9;
            if (env_file != .string) return 9;
            const contribution = try std.Io.Dir.cwd().readFileAlloc(init.io, spec[bar + 1 ..], a, .limited(1024 * 1024));
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = env_file.string, .data = contribution });
        }
    } else |_| {}
    // `PROVIDER_PROBE_SAY=1` makes every invocation print numbered lines to
    // stdout and stderr, the way a real provider reports progress, so a suite
    // can check the CLI's and the provider's output interleave intact when
    // both land in one redirected FILE (cli#446). The writers are STREAMING,
    // as every provider's must be: a positional `File.writer` pwrite()s at
    // its own offset from 0 and overwrites whatever the CLI already wrote.
    if (init.minimal.environ.getAlloc(a, "PROVIDER_PROBE_SAY")) |_| {
        const id = if (invocation == .object) invocation.object.get("id").?.string else "?";
        var out_buf: [64]u8 = undefined;
        var err_buf: [64]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
        var err = std.Io.File.stderr().writerStreaming(init.io, &err_buf);
        for (1..4) |n| {
            try out.interface.print("PROBE_SAY {s} stdout line {d} of 3\n", .{ id, n });
            try out.interface.flush();
            try err.interface.print("PROBE_SAY {s} stderr line {d} of 3\n", .{ id, n });
            try err.interface.flush();
        }
    } else |_| {}
    // Hooks receive no argv, so a failing hook is selected by environment:
    // `PROVIDER_PROBE_FAIL=<hook id>` makes that hook exit 7.
    if (init.minimal.environ.getAlloc(a, "PROVIDER_PROBE_FAIL")) |fail_id| {
        if (invocation == .object and invocation.object.get("id").?.string.len > 0 and
            std.mem.eql(u8, invocation.object.get("id").?.string, fail_id)) return 7;
    } else |_| {}
    // Commands run with no argv under `labelle doctor`, so a failing package
    // is selected by environment too: `PROVIDER_PROBE_FAIL_PACKAGE=<package>`
    // makes the tool exit 7 when its output directory is that package's
    // (`.labelle/providers/<package>`).
    if (init.minimal.environ.getAlloc(a, "PROVIDER_PROBE_FAIL_PACKAGE")) |fail_package| {
        if (std.mem.eql(u8, std.fs.path.basename(output), fail_package)) return 7;
    } else |_| {}
    if (collected.items.len > 0 and std.mem.eql(u8, collected.items[0], "fail")) return 7;
    if (collected.items.len > 0 and std.mem.eql(u8, collected.items[0], "crash")) @panic("provider fixture crash");
    return 0;
}

/// Start `provider-probe linger` and write `<own pid> <its pid>\n` to
/// `marker` (written last, whole: a reader sees both or nothing).
fn linger(init: std.process.Init, a: std.mem.Allocator, marker: []const u8) !void {
    const self_exe = try std.process.executablePathAlloc(init.io, a);
    const child = try std.process.spawn(init.io, .{ .argv = &.{ self_exe, "linger" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    const is_windows = @import("builtin").os.tag == .windows;
    const own: u64 = if (is_windows) GetCurrentProcessId() else if (@import("builtin").os.tag == .linux) @intCast(std.os.linux.getpid()) else @intCast(std.c.getpid());
    const theirs: u64 = if (is_windows) GetProcessId(child.id.?) else @intCast(child.id.?);
    const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{marker});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = tmp, .data = try std.fmt.allocPrint(a, "{d} {d}\n", .{ own, theirs }) });
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), marker, init.io);
}

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetProcessId(process: std.os.windows.HANDLE) callconv(.winapi) u32;

fn watchServer(init: std.process.Init, a: std.mem.Allocator, output: []const u8, watch: std.json.ObjectMap) !u8 {
    const io = init.io;
    const generation_file = watch.get("generation_file").?.string;
    const output_dir = watch.get("output_dir").?.string;
    const log_path = try std.fs.path.join(a, &.{ output, "watch.log" });
    const stop_path: ?[]const u8 = init.minimal.environ.getAlloc(a, "PROVIDER_PROBE_WATCH_STOP") catch null;
    if (init.minimal.environ.getAlloc(a, "PROVIDER_PROBE_WATCH_CHILD")) |marker| try linger(init, a, marker) else |_| {}
    var seen: ?[]const u8 = null;
    var ticks: u32 = 0;
    while (ticks < 2400) : (ticks += 1) {
        if (std.Io.Dir.cwd().readFileAlloc(io, generation_file, a, .limited(64))) |raw| {
            const gen = std.mem.trim(u8, raw, " \r\n");
            if (seen == null or !std.mem.eql(u8, seen.?, gen)) {
                seen = gen;
                const data_path = try std.fs.path.join(a, &.{ output_dir, "bin", "data.txt" });
                const data = std.Io.Dir.cwd().readFileAlloc(io, data_path, a, .limited(1024)) catch "missing";
                const previous = std.Io.Dir.cwd().readFileAlloc(io, log_path, a, .limited(1 << 20)) catch "";
                const line = try std.fmt.allocPrint(a, "{s}gen={s} data={s}\n", .{ previous, gen, std.mem.trim(u8, data, " \r\n") });
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log_path, .data = line });
            }
        } else |_| {}
        if (stop_path) |path| {
            if (std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16))) |code| {
                return std.fmt.parseInt(u8, std.mem.trim(u8, code, " \r\n"), 10) catch 0;
            } else |_| {}
        }
        io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    }
    return 3;
}
