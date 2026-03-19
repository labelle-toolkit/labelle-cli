// Carry demo script
//
// Demonstrates parent-child position inheritance:
// 1. Carrier moves right to pickup position
// 2. Picks up item (setParent) — item follows carrier
// 3. Carrier moves right to drop position
// 4. Drops item (removeParentKeepTransform) — item stays at drop position
// 5. Carrier moves left back to start
// 6. Repeat

const Carrier = @import("../components/carrier.zig").Carrier;
const PickupItem = @import("../components/pickup_item.zig").PickupItem;

const ARRIVAL_DIST: f32 = 3.0;

pub fn tick(game: anytype, dt: f32) void {
    const Entity = @TypeOf(game.*).EntityType;

    var buf: [4]Entity = undefined;
    var count: usize = 0;
    {
        var view = game.ecs_backend.view(.{Carrier}, .{});
        while (view.next()) |entity| {
            if (count < buf.len) {
                buf[count] = entity;
                count += 1;
            }
        }
        view.deinit();
    }

    for (buf[0..count]) |entity| {
        const carrier = game.ecs_backend.getComponent(entity, Carrier) orelse continue;
        const pos = game.getPosition(entity);

        switch (carrier.phase) {
            0 => {
                // Move right to pickup position
                const new_x = pos.x + carrier.speed * dt;
                game.setPosition(entity, .{ .x = new_x, .y = pos.y });

                if (new_x >= carrier.pickup_x - ARRIVAL_DIST) {
                    // Find item to pick up
                    var item_view = game.ecs_backend.view(.{PickupItem}, .{});
                    while (item_view.next()) |item_entity| {
                        const Parent = @TypeOf(game.*).ParentComp;
                        if (game.ecs_backend.hasComponent(item_entity, Parent)) continue;

                        // Pick up: attach as child
                        game.setParent(item_entity, entity, .{});
                        game.setPosition(item_entity, .{ .x = 0, .y = -20 }); // above carrier
                        carrier.item_id = @intCast(item_entity);
                        carrier.phase = 1;
                        game.log.info("[CarryDemo] picked up item {d}", .{carrier.item_id});
                        break;
                    }
                    item_view.deinit();

                    // No item found — just go to phase 3 (return)
                    if (carrier.phase == 0) {
                        carrier.phase = 3;
                    }
                }
            },
            1 => {
                // Carrying — move right to drop position
                const new_x = pos.x + carrier.speed * dt;
                game.setPosition(entity, .{ .x = new_x, .y = pos.y });

                if (new_x >= carrier.drop_x - ARRIVAL_DIST) {
                    // Drop: detach item
                    const item_entity: Entity = @intCast(carrier.item_id);
                    game.removeParentKeepTransform(item_entity);
                    // Place at drop position explicitly
                    game.setPosition(item_entity, .{ .x = carrier.drop_x, .y = pos.y });
                    game.log.info("[CarryDemo] dropped item {d} at x={d:.0}", .{ carrier.item_id, carrier.drop_x });
                    carrier.item_id = 0;
                    carrier.phase = 2;
                }
            },
            2 => {
                // Pause briefly at drop, then return
                carrier.phase = 3;
            },
            3 => {
                // Move left back to start
                const new_x = pos.x - carrier.speed * dt;
                game.setPosition(entity, .{ .x = new_x, .y = pos.y });

                if (new_x <= 50) {
                    game.setPosition(entity, .{ .x = 50, .y = pos.y });
                    carrier.phase = 0;
                    game.log.info("[CarryDemo] returned to start, restarting cycle", .{});
                }
            },
            else => {},
        }
    }
}
