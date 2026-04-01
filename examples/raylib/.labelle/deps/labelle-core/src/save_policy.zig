/// Save policy declarations for ECS components.
///
/// Components declare their serialization behavior with a single `Saveable` call:
///
/// ```
/// const core = @import("labelle-core");
///
/// pub const Stored = struct {
///     pub const save = core.Saveable(.saveable, @This(), .{
///         .entity_refs = &.{"storage_id"},
///     });
///     storage_id: u64 = 0,
/// };
/// ```
///
/// Legacy style (`pub const save_policy: SavePolicy = ...`) is also supported.

const std = @import("std");

pub const SavePolicy = enum {
    /// Serialized and restored on load.
    saveable,
    /// Stripped on load — re-derived by scripts each frame.
    transient,
    /// Zero-size marker from prefab — not serialized.
    marker,
};

// ─── Saveable: config-only comptime function ────────────────────────────────

pub const SaveableOptions = struct {
    entity_refs: []const []const u8 = &.{},
    skip: []const []const u8 = &.{},
    ref_arrays: []const []const u8 = &.{},
    remap_exclude: []const []const u8 = &.{},
    post_load_add: []const type = &.{},
    post_load_create: bool = false,
};

/// Returns a config struct with all save metadata. Validates that declared
/// field names exist on the Owner struct at comptime.
pub fn Saveable(comptime policy: SavePolicy, comptime Owner: type, comptime opts: SaveableOptions) type {
    const fields = @typeInfo(Owner).@"struct".fields;

    inline for (opts.entity_refs) |name| {
        if (!hasField(fields, name))
            @compileError("entity_refs: field '" ++ name ++ "' does not exist");
    }
    inline for (opts.skip) |name| {
        if (!hasField(fields, name))
            @compileError("skip: field '" ++ name ++ "' does not exist");
    }
    inline for (opts.ref_arrays) |name| {
        if (!hasField(fields, name))
            @compileError("ref_arrays: field '" ++ name ++ "' does not exist");
    }
    inline for (opts.remap_exclude) |name| {
        if (!hasField(fields, name))
            @compileError("remap_exclude: field '" ++ name ++ "' does not exist");
    }

    return struct {
        pub const save_policy: SavePolicy = policy;
        pub const entity_ref_fields = toTuple(opts.entity_refs);
        pub const skip_fields = toTuple(opts.skip);
        pub const entity_ref_array_fields = toTuple(opts.ref_arrays);
        pub const remap_exclude_fields = toTuple(opts.remap_exclude);
        pub const post_load_markers = opts.post_load_add;
        pub const post_load_create: bool = opts.post_load_create;
    };
}

fn hasField(fields: []const std.builtin.Type.StructField, name: []const u8) bool {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

fn toTuple(comptime names: []const []const u8) [names.len][]const u8 {
    var result: [names.len][]const u8 = undefined;
    inline for (names, 0..) |name, i| {
        result[i] = name;
    }
    return result;
}

// ─── Accessor helpers (work with both new and legacy styles) ────────────────

/// Check if a type declares a save policy (new or legacy style).
pub fn hasSavePolicy(comptime T: type) bool {
    return @hasDecl(T, "save") or @hasDecl(T, "save_policy");
}

/// Get the save_policy of a type, or null if not declared.
pub fn getSavePolicy(comptime T: type) ?SavePolicy {
    if (@hasDecl(T, "save")) return T.save.save_policy;
    if (@hasDecl(T, "save_policy")) return @field(T, "save_policy");
    return null;
}

/// Get entity ref field names for ID remapping.
pub fn getEntityRefFields(comptime T: type) []const []const u8 {
    if (@hasDecl(T, "save")) return &T.save.entity_ref_fields;
    if (@hasDecl(T, "entity_ref_fields")) return &@field(T, "entity_ref_fields");
    return &.{};
}

/// Get field names to skip during serialization.
pub fn getSkipFields(comptime T: type) []const []const u8 {
    if (@hasDecl(T, "save")) return &T.save.skip_fields;
    if (@hasDecl(T, "skip_fields")) return &@field(T, "skip_fields");
    return &.{};
}

/// Get entity ref array field names ([]const u64 slices).
pub fn getRefArrayFields(comptime T: type) []const []const u8 {
    if (@hasDecl(T, "save")) return &T.save.entity_ref_array_fields;
    if (@hasDecl(T, "entity_ref_array_fields")) return &@field(T, "entity_ref_array_fields");
    return &.{};
}

/// Get field names excluded from entity ID remapping (sentinel values).
pub fn getRemapExclude(comptime T: type) []const []const u8 {
    if (@hasDecl(T, "save")) return &T.save.remap_exclude_fields;
    if (@hasDecl(T, "remap_exclude_fields")) return &@field(T, "remap_exclude_fields");
    return &.{};
}

/// Check if a type declares a postLoad function.
pub fn hasPostLoad(comptime T: type) bool {
    return @hasDecl(T, "postLoad");
}

/// Get marker types to add to entities after load.
pub fn getPostLoadMarkers(comptime T: type) []const type {
    if (@hasDecl(T, "save")) return T.save.post_load_markers;
    return &.{};
}

/// Check if a type should be auto-created as a new entity after load.
pub fn getPostLoadCreate(comptime T: type) bool {
    if (@hasDecl(T, "save")) return T.save.post_load_create;
    return false;
}

/// Check if a type declares entity_ref_fields (legacy compat).
pub fn hasEntityRefFields(comptime T: type) bool {
    return getEntityRefFields(T).len > 0;
}

/// Check if a type declares skip_fields (legacy compat).
pub fn hasSkipFields(comptime T: type) bool {
    return getSkipFields(T).len > 0;
}

/// Check if a field name should be skipped based on the type's skip_fields declaration.
pub fn shouldSkipField(comptime T: type, comptime field_name: []const u8) bool {
    const skip = comptime getSkipFields(T);
    inline for (skip) |name| {
        if (comptime std.mem.eql(u8, name, field_name)) return true;
    }
    return false;
}

/// Check if a field name is excluded from remapping.
pub fn isRemapExcluded(comptime T: type, comptime field_name: []const u8) bool {
    const excl = comptime getRemapExclude(T);
    inline for (excl) |name| {
        if (comptime std.mem.eql(u8, name, field_name)) return true;
    }
    return false;
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

const testing = std.testing;

// ─── Basic SavePolicy enum ─────────────────────────────────────────────────

test "SavePolicy enum values" {
    try testing.expectEqual(SavePolicy.saveable, SavePolicy.saveable);
    try testing.expect(SavePolicy.saveable != SavePolicy.transient);
    try testing.expect(SavePolicy.transient != SavePolicy.marker);
}

// ─── Legacy style (backward compat) ────────────────────────────────────────

test "legacy: hasSavePolicy detects declaration" {
    const WithPolicy = struct {
        pub const save_policy: SavePolicy = .saveable;
        x: f32 = 0,
    };
    const WithoutPolicy = struct {
        x: f32 = 0,
    };

    try testing.expect(hasSavePolicy(WithPolicy));
    try testing.expect(!hasSavePolicy(WithoutPolicy));
}

test "legacy: getSavePolicy returns correct value" {
    const LegacySaveable = struct {
        pub const save_policy: SavePolicy = .saveable;
    };
    const LegacyTransient = struct {
        pub const save_policy: SavePolicy = .transient;
    };
    const NoDeclare = struct {};

    try testing.expectEqual(SavePolicy.saveable, getSavePolicy(LegacySaveable).?);
    try testing.expectEqual(SavePolicy.transient, getSavePolicy(LegacyTransient).?);
    try testing.expectEqual(@as(?SavePolicy, null), getSavePolicy(NoDeclare));
}

test "legacy: shouldSkipField checks skip_fields" {
    const WithSkip = struct {
        pub const skip_fields = .{ "storages", "eis_slots" };
        storages: u32 = 0,
        eis_slots: u32 = 0,
        name: u32 = 0,
    };
    const NoSkip = struct {
        name: u32 = 0,
    };

    try testing.expect(shouldSkipField(WithSkip, "storages"));
    try testing.expect(shouldSkipField(WithSkip, "eis_slots"));
    try testing.expect(!shouldSkipField(WithSkip, "name"));
    try testing.expect(!shouldSkipField(NoSkip, "name"));
}

test "legacy: hasEntityRefFields detects declaration" {
    const WithRefs = struct {
        pub const entity_ref_fields = .{"storage_id"};
        storage_id: u64 = 0,
    };
    const WithoutRefs = struct {
        value: f32 = 0,
    };

    try testing.expect(hasEntityRefFields(WithRefs));
    try testing.expect(!hasEntityRefFields(WithoutRefs));
}

test "legacy: accessor helpers work with old style" {
    const LegacyFull = struct {
        pub const save_policy: SavePolicy = .saveable;
        pub const entity_ref_fields = .{ "target", "source" };
        pub const skip_fields = .{"cache"};
        pub const entity_ref_array_fields = .{"children"};
        target: u64 = 0,
        source: u64 = 0,
        cache: u32 = 0,
        children: []const u64 = &.{},
    };

    try testing.expectEqual(SavePolicy.saveable, getSavePolicy(LegacyFull).?);
    try testing.expectEqual(@as(usize, 2), getEntityRefFields(LegacyFull).len);
    try testing.expectEqual(@as(usize, 1), getSkipFields(LegacyFull).len);
    try testing.expectEqual(@as(usize, 1), getRefArrayFields(LegacyFull).len);
    try testing.expectEqual(@as(usize, 0), getRemapExclude(LegacyFull).len);
    try testing.expect(!hasPostLoad(LegacyFull));
    try testing.expectEqual(@as(usize, 0), getPostLoadMarkers(LegacyFull).len);
    try testing.expect(!getPostLoadCreate(LegacyFull));
}

// ─── New style: Saveable(...) ──────────────────────────────────────────────

const NeedsClosestNode = struct { _marker: u8 = 0 };

test "Saveable: marker component" {
    const Worker = struct {
        pub const save = Saveable(.marker, @This(), .{});
        _pad: u8 = 0,
    };

    try testing.expectEqual(SavePolicy.marker, getSavePolicy(Worker).?);
    try testing.expect(hasSavePolicy(Worker));
    try testing.expectEqual(@as(usize, 0), getEntityRefFields(Worker).len);
    try testing.expectEqual(@as(usize, 0), getSkipFields(Worker).len);

    // Can be instantiated normally
    const w: Worker = .{};
    try testing.expectEqual(@as(u8, 0), w._pad);
}

test "Saveable: saveable with entity_refs" {
    const Eis = struct {
        pub const save = Saveable(.saveable, @This(), .{
            .entity_refs = &.{"workstation"},
        });
        workstation: u64 = 0,
        item_type: u8 = 0,
    };

    try testing.expectEqual(SavePolicy.saveable, getSavePolicy(Eis).?);
    const refs = getEntityRefFields(Eis);
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("workstation", refs[0]);

    // Direct field access (no .inner)
    var e: Eis = .{};
    e.workstation = 42;
    try testing.expectEqual(@as(u64, 42), e.workstation);
}

test "Saveable: skip + ref_arrays" {
    const Room = struct {
        pub const save = Saveable(.saveable, @This(), .{
            .skip = &.{ "workstations", "movement_nodes" },
            .ref_arrays = &.{ "workstations", "movement_nodes" },
        });
        name_hash: u32 = 0,
        workstations: []const u64 = &.{},
        movement_nodes: []const u64 = &.{},
    };

    try testing.expectEqual(@as(usize, 2), getSkipFields(Room).len);
    try testing.expect(shouldSkipField(Room, "workstations"));
    try testing.expect(shouldSkipField(Room, "movement_nodes"));
    try testing.expect(!shouldSkipField(Room, "name_hash"));
    try testing.expectEqual(@as(usize, 2), getRefArrayFields(Room).len);
    try testing.expectEqualStrings("workstations", getRefArrayFields(Room)[0]);
}

test "Saveable: remap_exclude" {
    const WorkingOn = struct {
        pub const save = Saveable(.saveable, @This(), .{
            .entity_refs = &.{ "workstation_id", "item" },
            .remap_exclude = &.{"item"},
        });
        workstation_id: u64 = 0,
        item: u64 = 0,
    };

    const excl = getRemapExclude(WorkingOn);
    try testing.expectEqual(@as(usize, 1), excl.len);
    try testing.expectEqualStrings("item", excl[0]);
    try testing.expect(isRemapExcluded(WorkingOn, "item"));
    try testing.expect(!isRemapExcluded(WorkingOn, "workstation_id"));
}

test "Saveable: post_load_add markers" {
    const Eis = struct {
        pub const save = Saveable(.saveable, @This(), .{
            .entity_refs = &.{"workstation"},
            .post_load_add = &.{NeedsClosestNode},
        });
        workstation: u64 = 0,
    };

    const markers = getPostLoadMarkers(Eis);
    try testing.expectEqual(@as(usize, 1), markers.len);
    try testing.expect(markers[0] == NeedsClosestNode);
}

test "Saveable: postLoad hook" {
    const Workstation = struct {
        pub const save = Saveable(.saveable, @This(), .{
            .skip = &.{"cached_slot_count"},
        });
        producer: bool = false,
        cached_slot_count: u32 = 0,

        pub fn postLoad(self: *@This(), game: anytype, entity: anytype) void {
            _ = game;
            _ = entity;
            self.cached_slot_count = if (self.producer) 1 else 4;
        }
    };

    try testing.expect(hasPostLoad(Workstation));

    var ws: Workstation = .{ .producer = true };
    ws.postLoad({}, {});
    try testing.expectEqual(@as(u32, 1), ws.cached_slot_count);
}

test "Saveable: no postLoad returns false" {
    const Item = struct {
        pub const save = Saveable(.saveable, @This(), .{});
        item_type: u8 = 0,
    };
    try testing.expect(!hasPostLoad(Item));
}

test "Saveable: post_load_create" {
    const PathfinderRebuild = struct {
        pub const save = Saveable(.transient, @This(), .{
            .post_load_create = true,
        });
        _marker: u8 = 0,
    };

    try testing.expect(getPostLoadCreate(PathfinderRebuild));
    try testing.expectEqual(SavePolicy.transient, getSavePolicy(PathfinderRebuild).?);

    // Non-create component returns false
    const Regular = struct {
        pub const save = Saveable(.saveable, @This(), .{});
        x: f32 = 0,
    };
    try testing.expect(!getPostLoadCreate(Regular));
}

test "Saveable: simulated generic loader" {
    const Types = [_]type{
        // Marker
        struct {
            pub const save = Saveable(.marker, @This(), .{});
            _pad: u8 = 0,
        },
        // Saveable with postLoad
        struct {
            pub const save = Saveable(.saveable, @This(), .{
                .post_load_add = &.{NeedsClosestNode},
            });
            value: u32 = 0,

            pub fn postLoad(self: *@This(), game: anytype, entity: anytype) void {
                _ = game;
                _ = entity;
                self.value = 99;
            }
        },
        // post_load_create
        struct {
            pub const save = Saveable(.transient, @This(), .{
                .post_load_create = true,
            });
            _marker: u8 = 0,
        },
        // Legacy style
        struct {
            pub const save_policy: SavePolicy = .saveable;
            pub const entity_ref_fields = .{"target"};
            target: u64 = 0,
        },
    };

    // Verify all types are detectable
    inline for (Types) |T| {
        try testing.expect(hasSavePolicy(T));
        try testing.expect(getSavePolicy(T) != null);
    }

    // Verify generic loader patterns
    inline for (Types) |T| {
        if (comptime getSavePolicy(T)) |policy| {
            if (policy == .saveable or policy == .marker) {
                if (comptime hasPostLoad(T)) {
                    var instance: T = .{};
                    instance.postLoad({}, {});
                    _ = &instance;
                }
                const markers = comptime getPostLoadMarkers(T);
                inline for (markers) |Marker| {
                    var m: Marker = .{};
                    _ = &m;
                }
            }
            if (comptime getPostLoadCreate(T)) {
                var create_instance: T = .{};
                _ = &create_instance;
            }
        }
    }
}
