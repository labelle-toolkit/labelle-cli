const std = @import("std");
pub fn build(b: *std.Build) void {
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
