/// mr_ecs (zcs) adapter — satisfies the labelle-core Ecs(Impl) contract.
/// Wraps Games-by-Mason/mr_ecs with the required interface.
///
/// mr_ecs uses a command buffer pattern: mutations go through CmdBuf,
/// then are flushed with CmdBuf.Exec.immediate(). This adapter auto-flushes
/// after each mutation for compatibility with the synchronous ECS contract.
const std = @import("std");
const zcs = @import("mr_ecs");

/// External entity type — plain u32 for engine compatibility.
pub const Entity = u32;

const Self = @This();

entities: zcs.Entities,
cmd_buf: ?zcs.CmdBuf,
/// Map zcs.Entity → external u32 id
zcs_to_ext: std.AutoHashMap(zcs.Entity, u32),
/// Map external u32 id → zcs.Entity
ext_to_zcs: std.AutoHashMap(u32, zcs.Entity),
next_id: u32,
entity_count: usize,
alive_entities: std.ArrayListUnmanaged(Entity),
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .entities = zcs.Entities.init(.{ .gpa = allocator }) catch @panic("mr_ecs: Entities.init failed"),
        .cmd_buf = null,
        .zcs_to_ext = std.AutoHashMap(zcs.Entity, u32).init(allocator),
        .ext_to_zcs = std.AutoHashMap(u32, zcs.Entity).init(allocator),
        .next_id = 1,
        .entity_count = 0,
        .alive_entities = .{},
        .allocator = allocator,
    };
}

fn ensureCmdBuf(self: *Self) *zcs.CmdBuf {
    if (self.cmd_buf == null) {
        self.cmd_buf = zcs.CmdBuf.init(.{
            .name = "labelle_cmdbuf",
            .gpa = self.allocator,
            .es = &self.entities,
        }) catch @panic("mr_ecs: CmdBuf.init failed");
    }
    return &self.cmd_buf.?;
}

fn flush(self: *Self) void {
    if (self.cmd_buf) |*cb| {
        zcs.CmdBuf.Exec.immediate(&self.entities, cb);
    }
}

pub fn deinit(self: *Self) void {
    self.alive_entities.deinit(self.allocator);
    self.ext_to_zcs.deinit();
    self.zcs_to_ext.deinit();
    if (self.cmd_buf) |*cb| {
        cb.deinit(self.allocator, &self.entities);
    }
    self.entities.deinit(self.allocator);
}

pub fn createEntity(self: *Self) Entity {
    const id = self.next_id;
    self.next_id += 1;

    const cb = self.ensureCmdBuf();
    const zcs_entity = zcs.Entity.reserve(cb);
    self.flush();

    self.zcs_to_ext.put(zcs_entity, id) catch @panic("OOM");
    self.ext_to_zcs.put(id, zcs_entity) catch @panic("OOM");
    self.entity_count += 1;
    self.alive_entities.append(self.allocator, id) catch @panic("OOM");
    return id;
}

pub fn destroyEntity(self: *Self, entity: Entity) void {
    const zcs_entity = self.ext_to_zcs.get(entity) orelse return;
    const cb = self.ensureCmdBuf();
    zcs_entity.destroy(cb);
    self.flush();
    _ = self.zcs_to_ext.remove(zcs_entity);
    _ = self.ext_to_zcs.remove(entity);
    self.entity_count -= 1;
    for (self.alive_entities.items, 0..) |e, idx| {
        if (e == entity) {
            _ = self.alive_entities.swapRemove(idx);
            break;
        }
    }
}

pub fn entityExists(self: *Self, entity: Entity) bool {
    const zcs_entity = self.ext_to_zcs.get(entity) orelse return false;
    return zcs_entity.exists(&self.entities);
}

pub fn entityCount(self: *Self) usize {
    return self.entity_count;
}

pub fn addComponent(self: *Self, entity: Entity, component: anytype) void {
    const T = @TypeOf(component);
    const zcs_entity = self.ext_to_zcs.get(entity) orelse return;
    const cb = self.ensureCmdBuf();
    _ = zcs_entity.addVal(cb, T, component);
    self.flush();
}

pub fn getComponent(self: *Self, entity: Entity, comptime T: type) ?*T {
    const zcs_entity = self.ext_to_zcs.get(entity) orelse return null;
    return zcs_entity.get(&self.entities, T);
}

pub fn hasComponent(self: *Self, entity: Entity, comptime T: type) bool {
    const zcs_entity = self.ext_to_zcs.get(entity) orelse return false;
    return zcs_entity.has(&self.entities, T);
}

pub fn removeComponent(self: *Self, entity: Entity, comptime T: type) void {
    const zcs_entity = self.ext_to_zcs.get(entity) orelse return;
    const cb = self.ensureCmdBuf();
    zcs_entity.remove(cb, T);
    self.flush();
}

/// View type — iterates matching entities using component filters.
/// Materializes results into a buffer since mr_ecs uses command buffers.
pub fn View(comptime _includes: anytype, comptime _excludes: anytype) type {
    return struct {
        entities: []const Entity,
        index: usize = 0,
        allocator: std.mem.Allocator,

        const ViewSelf = @This();
        const includes = _includes;
        const excludes = _excludes;

        pub fn next(self: *ViewSelf) ?Entity {
            if (self.index < self.entities.len) {
                const entity = self.entities[self.index];
                self.index += 1;
                return entity;
            }
            return null;
        }

        pub fn deinit(self: *ViewSelf) void {
            self.allocator.free(self.entities);
        }
    };
}

/// Create a view iterating entities with the given include/exclude filters.
pub fn view(self: *Self, comptime includes: anytype, comptime excludes: anytype) View(includes, excludes) {
    var result: std.ArrayListUnmanaged(Entity) = .{};
    var it = self.ext_to_zcs.iterator();
    while (it.next()) |entry| {
        const ext_id = entry.key_ptr.*;
        if (matchesAll(self, ext_id, includes, excludes)) {
            result.append(self.allocator, ext_id) catch @panic("OOM");
        }
    }

    return .{
        .entities = result.toOwnedSlice(self.allocator) catch @panic("OOM"),
        .allocator = self.allocator,
    };
}

fn matchesAll(self: *Self, entity: Entity, comptime includes: anytype, comptime excludes: anytype) bool {
    inline for (includes) |T| {
        if (!self.hasComponent(entity, T)) return false;
    }
    inline for (excludes) |T| {
        if (self.hasComponent(entity, T)) return false;
    }
    return true;
}

/// Validates that `components` is a tuple of types.
fn validateComponentTuple(comptime components: anytype) void {
    const info = @typeInfo(@TypeOf(components));
    if (info != .@"struct" or !info.@"struct".is_tuple)
        @compileError("query() expects a tuple of component types, e.g. .{Pos, Vel}");
    inline for (info.@"struct".fields) |field| {
        if (field.type != type)
            @compileError("query() tuple elements must be types, got: " ++ @typeName(field.type));
    }
}

fn QueryResultType(comptime components: anytype) type {
    comptime validateComponentTuple(components);
    const fields_info = @typeInfo(@TypeOf(components)).@"struct".fields;
    var fields: [fields_info.len + 1]std.builtin.Type.StructField = undefined;
    fields[0] = .{
        .name = "entity",
        .type = Entity,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(Entity),
    };
    for (fields_info, 0..) |_, i| {
        const T = components[i];
        const name = std.fmt.comptimePrint("comp_{d}", .{i});
        fields[i + 1] = .{
            .name = name,
            .type = *T,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(*T),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

/// QueryIterator type for this backend.
pub fn QueryIterator(comptime components: anytype) type {
    comptime validateComponentTuple(components);
    return struct {
        backend: *Self,
        entities: std.ArrayListUnmanaged(Entity),
        index: usize,

        const QI = @This();
        pub const Result = QueryResultType(components);

        pub fn next(self_qi: *QI) ?Result {
            while (self_qi.index < self_qi.entities.items.len) {
                const entity = self_qi.entities.items[self_qi.index];
                self_qi.index += 1;

                var has_all = true;
                inline for (@typeInfo(@TypeOf(components)).@"struct".fields, 0..) |_, i| {
                    const T = components[i];
                    if (self_qi.backend.getComponent(entity, T) == null) {
                        has_all = false;
                        break;
                    }
                }
                if (!has_all) continue;

                var result: Result = undefined;
                result.entity = entity;
                inline for (@typeInfo(@TypeOf(components)).@"struct".fields, 0..) |_, i| {
                    const T = components[i];
                    @field(result, std.fmt.comptimePrint("comp_{d}", .{i})) = self_qi.backend.getComponent(entity, T).?;
                }
                return result;
            }
            return null;
        }

        pub fn deinit(self_qi: *QI, allocator: std.mem.Allocator) void {
            self_qi.entities.deinit(allocator);
        }
    };
}

/// Query entities with direct component access.
pub fn query(self: *Self, comptime components: anytype) QueryIterator(components) {
    var entities = std.ArrayListUnmanaged(Entity){};
    entities.appendSlice(self.allocator, self.alive_entities.items) catch @panic("OOM");
    return .{
        .backend = self,
        .entities = entities,
        .index = 0,
    };
}
