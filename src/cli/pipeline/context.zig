//! What the cold pipeline has settled once the hook site exists: the
//! values the generate, build, bundle and run stages share. `run`
//! (`pipeline.zig`) owns every resource these fields borrow.
const std = @import("std");
const project_config = @import("../project_config.zig");
const assembler_proc = @import("../assembler_proc.zig");
const progress = @import("../progress.zig");
const args_mod = @import("../args.zig");
const provider_dispatch = @import("../provider_dispatch.zig");
const provider_github = @import("../provider_github.zig");
const provider_hooks = @import("../provider_hooks.zig");
const provider_targets = @import("../provider_targets.zig");

/// The hook plans for the four steps (contract §6).
pub const HookPlans = struct {
    generate: provider_hooks.Plan,
    build: provider_hooks.Plan,
    bundle: provider_hooks.Plan,
    run: provider_hooks.Plan,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    parsed_args: *const args_mod.ParsedArgs,
    parsed: project_config.ProjectConfig,
    project_dir: []const u8,
    hook_arena: std.mem.Allocator,
    target_name: []const u8,
    target_dir: []const u8,
    output_dir: []const u8,
    reporter: ?*progress.Reporter,
    asm_bin: assembler_proc.Assembler,
    providers: []const provider_dispatch.Provider,
    provider_sources: *provider_github.Sources,
    target: provider_targets.Resolved,
    hook_plans: HookPlans,
    hook_site: *provider_hooks.Site,
    effective_optimize: ?[]const u8,
};
