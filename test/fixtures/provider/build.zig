const std = @import("std");
pub fn build(b: *std.Build) void {
    // A hook's environment contribution (contract §2 `env_file`) reaches the
    // hooks' own processes and the project's zig invocations, never the
    // build of a provider's host tool: this build refuses to run with one.
    if (b.graph.environ_map.get("PROBE_TOOLCHAIN") != null) @panic("a hook environment contribution reached the provider tool build");
    // `PROVIDER_PROBE_BUILD_STDOUT=<text>`: the tool's build prints `<text>`
    // on stdout, the way a chatty provider build might, so a suite can check
    // it never reaches a stdout the CLI owns (`labelle doctor --json`).
    if (b.graph.environ_map.get("PROVIDER_PROBE_BUILD_STDOUT")) |text| {
        var buf: [256]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(b.graph.io, &buf);
        out.interface.print("{s}\n", .{text}) catch {};
        out.interface.flush() catch {};
    }
    const exe = b.addExecutable(.{
        .name = "provider-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = b.graph.host,
        }),
    });
    const install = b.addInstallArtifact(exe, .{});
    b.step("probe-tool", "Install the host probe").dependOn(&install.step);
    _ = b.step("missing-tool", "Succeed without installing the declared artifact");
}
