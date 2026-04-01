const position = @import("position.zig");
const Position = position.Position;

/// Comptime-validated physics interface.
/// The assembler provides the concrete Impl (Box2D, Chipmunk, custom, etc.).
/// Both engine and plugins use this for zero-cost dispatch.
pub fn PhysicsInterface(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "createBody")) @compileError("Physics impl must define 'createBody'");
        if (!@hasDecl(Impl, "destroyBody")) @compileError("Physics impl must define 'destroyBody'");
        if (!@hasDecl(Impl, "step")) @compileError("Physics impl must define 'step'");
        if (!@hasDecl(Impl, "getPosition")) @compileError("Physics impl must define 'getPosition'");
    }

    return struct {
        pub const Implementation = Impl;
        pub const BodyId = Impl.BodyId;

        pub const BodyType = enum { static, dynamic, kinematic };

        pub const BodyDef = struct {
            body_type: BodyType = .dynamic,
            x: f32 = 0,
            y: f32 = 0,
            angle: f32 = 0,
            fixed_rotation: bool = false,
        };

        pub const Shape = union(enum) {
            box: struct { width: f32, height: f32 },
            circle: struct { radius: f32 },
        };

        pub const RaycastHit = struct {
            body: BodyId,
            point: Position,
            normal: Position,
            fraction: f32,
        };

        // ── Bodies ──

        pub inline fn createBody(def: BodyDef) BodyId {
            return Impl.createBody(def);
        }

        pub inline fn destroyBody(body: BodyId) void {
            Impl.destroyBody(body);
        }

        // ── Shapes ──

        pub inline fn addShape(body: BodyId, shape: Shape) void {
            if (@hasDecl(Impl, "addShape")) {
                Impl.addShape(body, shape);
            }
        }

        // ── Queries ──

        pub inline fn getPosition(body: BodyId) Position {
            return Impl.getPosition(body);
        }

        pub inline fn getAngle(body: BodyId) f32 {
            if (@hasDecl(Impl, "getAngle")) {
                return Impl.getAngle(body);
            }
            return 0;
        }

        pub inline fn getVelocity(body: BodyId) Position {
            if (@hasDecl(Impl, "getVelocity")) {
                return Impl.getVelocity(body);
            }
            return .{ .x = 0, .y = 0 };
        }

        pub inline fn setPosition(body: BodyId, pos: Position) void {
            if (@hasDecl(Impl, "setPosition")) {
                Impl.setPosition(body, pos);
            }
        }

        pub inline fn setVelocity(body: BodyId, vel: Position) void {
            if (@hasDecl(Impl, "setVelocity")) {
                Impl.setVelocity(body, vel);
            }
        }

        pub inline fn applyForce(body: BodyId, force: Position) void {
            if (@hasDecl(Impl, "applyForce")) {
                Impl.applyForce(body, force);
            }
        }

        pub inline fn applyImpulse(body: BodyId, impulse: Position) void {
            if (@hasDecl(Impl, "applyImpulse")) {
                Impl.applyImpulse(body, impulse);
            }
        }

        // ── Collision queries ──

        pub inline fn overlapPoint(point: Position) ?BodyId {
            if (@hasDecl(Impl, "overlapPoint")) {
                return Impl.overlapPoint(point);
            }
            return null;
        }

        pub inline fn overlapCircle(center: Position, radius: f32) ?BodyId {
            if (@hasDecl(Impl, "overlapCircle")) {
                return Impl.overlapCircle(center, radius);
            }
            return null;
        }

        pub inline fn raycast(from: Position, to: Position) ?RaycastHit {
            if (@hasDecl(Impl, "raycast")) {
                return Impl.raycast(from, to);
            }
            return null;
        }

        // ── Simulation ──

        pub inline fn step(dt: f32) void {
            Impl.step(dt);
        }

        pub inline fn bodyCount() u32 {
            if (@hasDecl(Impl, "bodyCount")) {
                return Impl.bodyCount();
            }
            return 0;
        }
    };
}

/// Stub physics for testing — tracks bodies in static arrays.
pub const StubPhysics = struct {
    pub const BodyId = u32;

    const max_bodies = 64;
    var positions: [max_bodies]position.Position = [_]position.Position{.{ .x = 0, .y = 0 }} ** max_bodies;
    var velocities: [max_bodies]position.Position = [_]position.Position{.{ .x = 0, .y = 0 }} ** max_bodies;
    var alive: [max_bodies]bool = [_]bool{false} ** max_bodies;
    var next_id: u32 = 0;
    var body_count_val: u32 = 0;
    var step_count: u32 = 0;

    pub fn createBody(def: PhysicsInterface(StubPhysics).BodyDef) BodyId {
        const id = next_id;
        next_id += 1;
        if (id < max_bodies) {
            positions[id] = .{ .x = def.x, .y = def.y };
            velocities[id] = .{ .x = 0, .y = 0 };
            alive[id] = true;
        }
        body_count_val += 1;
        return id;
    }

    pub fn destroyBody(body: BodyId) void {
        if (body < max_bodies) {
            alive[body] = false;
        }
        if (body_count_val > 0) body_count_val -= 1;
    }

    pub fn addShape(_: BodyId, _: PhysicsInterface(StubPhysics).Shape) void {}

    pub fn getPosition(body: BodyId) position.Position {
        if (body < max_bodies) return positions[body];
        return .{ .x = 0, .y = 0 };
    }

    pub fn setPosition(body: BodyId, pos: position.Position) void {
        if (body < max_bodies) positions[body] = pos;
    }

    pub fn getVelocity(body: BodyId) position.Position {
        if (body < max_bodies) return velocities[body];
        return .{ .x = 0, .y = 0 };
    }

    pub fn setVelocity(body: BodyId, vel: position.Position) void {
        if (body < max_bodies) velocities[body] = vel;
    }

    pub fn applyForce(_: BodyId, _: position.Position) void {}
    pub fn applyImpulse(_: BodyId, _: position.Position) void {}

    pub fn step(dt: f32) void {
        step_count += 1;
        // Simple Euler integration for testing
        for (0..max_bodies) |i| {
            if (alive[i]) {
                positions[i].x += velocities[i].x * dt;
                positions[i].y += velocities[i].y * dt;
            }
        }
    }

    pub fn bodyCount() u32 {
        return body_count_val;
    }

    pub fn overlapPoint(_: position.Position) ?BodyId {
        return null;
    }

    pub fn raycast(_: position.Position, _: position.Position) ?PhysicsInterface(StubPhysics).RaycastHit {
        return null;
    }

    // ── Test helpers ──

    pub fn reset() void {
        positions = [_]position.Position{.{ .x = 0, .y = 0 }} ** max_bodies;
        velocities = [_]position.Position{.{ .x = 0, .y = 0 }} ** max_bodies;
        alive = [_]bool{false} ** max_bodies;
        next_id = 0;
        body_count_val = 0;
        step_count = 0;
    }

    pub fn getStepCount() u32 {
        return step_count;
    }
};
