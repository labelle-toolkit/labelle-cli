// Manual carry script
//
// Arrow keys to move, spacebar to pick up / drop nearest item.

const ManualCarrier = @import("../components/manual_carrier.zig").ManualCarrier;
const PickupItem = @import("../components/pickup_item.zig").PickupItem;

const KEY_LEFT: u32 = 263;
const KEY_RIGHT: u32 = 262;
const KEY_SPACE: u32 = 32;

pub fn tick(game: anytype, dt: f32) void {
    const Entity = @TypeOf(game.*).EntityType;
    const Parent = @TypeOf(game.*).ParentComp;

    var buf: [4]Entity = undefined;
    var count: usize = 0;
    {
        var view = game.ecs_backend.view(.{ManualCarrier}, .{});
        while (view.next()) |entity| {
            if (count < buf.len) {
                buf[count] = entity;
                count += 1;
            }
        }
        view.deinit();
    }

    for (buf[0..count]) |entity| {
        const carrier = game.ecs_backend.getComponent(entity, ManualCarrier) orelse continue;
        const pos = game.getPosition(entity);

        // Move with arrow keys
        var new_x = pos.x;
        if (game.isKeyDown(KEY_LEFT)) new_x -= carrier.speed * dt;
        if (game.isKeyDown(KEY_RIGHT)) new_x += carrier.speed * dt;
        if (new_x != pos.x) {
            game.setPosition(entity, .{ .x = new_x, .y = pos.y });
        }

        // Spacebar: toggle pick up / drop
        if (game.isKeyPressed(KEY_SPACE)) {
            if (carrier.item_id != 0) {
                // Drop — keep item at current world position
                const item_entity: Entity = @intCast(carrier.item_id);
                game.removeParentKeepTransform(item_entity);
                game.log.info("[ManualCarry] dropped item {d}", .{carrier.item_id});
                carrier.item_id = 0;
            } else {
                // Pick up nearest item — keep at its current position relative to carrier
                var best_entity: ?Entity = null;
                var best_dist: f32 = 50; // max pickup range

                var item_view = game.ecs_backend.view(.{PickupItem}, .{});
                while (item_view.next()) |item_entity| {
                    if (game.ecs_backend.hasComponent(item_entity, Parent)) continue;
                    const ipos = game.getWorldPosition(item_entity);
                    const dx = ipos.x - pos.x;
                    const dist = if (dx > 0) dx else -dx;
                    if (dist < best_dist) {
                        best_dist = dist;
                        best_entity = item_entity;
                    }
                }
                item_view.deinit();

                if (best_entity) |item_entity| {
                    const ipos = game.getWorldPosition(item_entity);
                    game.setParent(item_entity, entity, .{});
                    game.setWorldPosition(item_entity, ipos);
                    carrier.item_id = @intCast(item_entity);
                    game.log.info("[ManualCarry] picked up item {d}", .{carrier.item_id});
                }
            }
        }
    }
}
