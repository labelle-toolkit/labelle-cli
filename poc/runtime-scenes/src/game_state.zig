const std = @import("std");
const Allocator = std.mem.Allocator;

/// Game state system — manages a state machine that controls which scripts run.
///
/// States are user-defined strings (not an enum) so they can be declared in
/// config files without recompilation. The engine doesn't need to know what
/// states exist — scripts declare which states they run in.
pub fn GameStateManager(comptime max_scripts: usize) type {
    return struct {
        const Self = @This();

        pub const ScriptEntry = struct {
            name: []const u8,
            init_fn: ?*const fn (*anyopaque) void = null,
            update_fn: ?*const fn (*anyopaque, f32) void = null,
            deinit_fn: ?*const fn (*anyopaque) void = null,
            /// States this script runs in. null = all states.
            states: ?[]const []const u8 = null,
            /// Whether init has been called.
            initialized: bool = false,
            /// Whether this script is currently active (state matches).
            active: bool = false,
        };

        scripts: [max_scripts]ScriptEntry = undefined,
        script_count: usize = 0,

        current_state: []const u8 = "menu",
        pending_state: ?[]const u8 = null,

        game_ptr: *anyopaque = undefined,

        // Hooks
        on_state_enter: ?*const fn ([]const u8) void = null,
        on_state_exit: ?*const fn ([]const u8) void = null,

        // Stats
        state_change_count: usize = 0,

        /// Whether the initial state activation has been performed.
        activated: bool = false,

        pub fn init(game_ptr: *anyopaque, initial_state: []const u8) Self {
            return .{
                .game_ptr = game_ptr,
                .current_state = initial_state,
            };
        }

        /// Activate scripts for the current state. Called automatically on first tick,
        /// or can be called manually after all scripts are registered.
        pub fn activate(self: *Self) void {
            if (self.activated) return;
            self.activated = true;
            self.state_change_count += 1;

            for (self.scripts[0..self.script_count]) |*script| {
                const matches = self.scriptMatchesState(script, self.current_state);
                script.active = matches;
                if (matches and !script.initialized) {
                    if (script.init_fn) |init_fn| {
                        init_fn(self.game_ptr);
                    }
                    script.initialized = true;
                }
            }

            if (self.on_state_enter) |cb| cb(self.current_state);
        }

        /// Register a script that runs in all states.
        pub fn registerScript(
            self: *Self,
            name: []const u8,
            update_fn: ?*const fn (*anyopaque, f32) void,
        ) void {
            self.registerScriptFull(name, .{
                .update_fn = update_fn,
            });
        }

        /// Register a script with full options.
        pub fn registerScriptFull(self: *Self, name: []const u8, opts: struct {
            init_fn: ?*const fn (*anyopaque) void = null,
            update_fn: ?*const fn (*anyopaque, f32) void = null,
            deinit_fn: ?*const fn (*anyopaque) void = null,
            states: ?[]const []const u8 = null,
        }) void {
            if (self.script_count >= max_scripts) return;
            self.scripts[self.script_count] = .{
                .name = name,
                .init_fn = opts.init_fn,
                .update_fn = opts.update_fn,
                .deinit_fn = opts.deinit_fn,
                .states = opts.states,
            };
            self.script_count += 1;
        }

        /// Change state immediately.
        pub fn setState(self: *Self, new_state: []const u8) void {
            if (!self.activated) {
                self.current_state = new_state;
                self.activate();
                return;
            }
            if (std.mem.eql(u8, self.current_state, new_state)) return;

            const old_state = self.current_state;

            // Deinit scripts that were active but won't be in the new state
            for (self.scripts[0..self.script_count]) |*script| {
                const was_active = script.active;
                const will_be_active = self.scriptMatchesState(script, new_state);

                if (was_active and !will_be_active) {
                    if (script.deinit_fn) |deinit_fn| {
                        deinit_fn(self.game_ptr);
                    }
                    script.initialized = false;
                    script.active = false;
                }
            }

            if (self.on_state_exit) |cb| cb(old_state);

            self.current_state = new_state;
            self.state_change_count += 1;

            // Activate and init scripts for the new state
            for (self.scripts[0..self.script_count]) |*script| {
                const matches = self.scriptMatchesState(script, new_state);
                script.active = matches;

                if (matches and !script.initialized) {
                    if (script.init_fn) |init_fn| {
                        init_fn(self.game_ptr);
                    }
                    script.initialized = true;
                }
            }

            if (self.on_state_enter) |cb| cb(new_state);
        }

        /// Queue a state change for next tick.
        pub fn queueStateChange(self: *Self, new_state: []const u8) void {
            self.pending_state = new_state;
        }

        /// Tick: process pending state change, then run active scripts.
        pub fn tick(self: *Self, dt: f32) void {
            // Auto-activate on first tick if not already done
            if (!self.activated) self.activate();

            // Process pending state change
            if (self.pending_state) |new_state| {
                self.setState(new_state);
                self.pending_state = null;
            }

            // Run active scripts
            for (self.scripts[0..self.script_count]) |*script| {
                if (!script.active) continue;
                if (script.update_fn) |update_fn| {
                    update_fn(self.game_ptr, dt);
                }
            }
        }

        /// Get the current state.
        pub fn getState(self: *const Self) []const u8 {
            return self.current_state;
        }

        /// Check if a specific script is currently active.
        pub fn isScriptActive(self: *const Self, name: []const u8) bool {
            for (self.scripts[0..self.script_count]) |script| {
                if (std.mem.eql(u8, script.name, name)) return script.active;
            }
            return false;
        }

        /// Get names of all active scripts.
        pub fn getActiveScripts(self: *const Self, buf: [][]const u8) usize {
            var count: usize = 0;
            for (self.scripts[0..self.script_count]) |script| {
                if (script.active and count < buf.len) {
                    buf[count] = script.name;
                    count += 1;
                }
            }
            return count;
        }

        fn scriptMatchesState(self: *const Self, script: *const ScriptEntry, state: []const u8) bool {
            _ = self;
            const states = script.states orelse return true; // null = all states
            for (states) |s| {
                if (std.mem.eql(u8, s, state)) return true;
            }
            return false;
        }
    };
}

// ======================== Tests ========================

// Mock game pointer
var mock_game: u32 = 0;

fn gamePtr() *anyopaque {
    return @ptrCast(&mock_game);
}

// Track script calls for assertions
var call_log: [64][]const u8 = undefined;
var call_count: usize = 0;

fn resetLog() void {
    call_count = 0;
}

fn logCall(name: []const u8) void {
    if (call_count < 64) {
        call_log[call_count] = name;
        call_count += 1;
    }
}

fn expectCalls(expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, call_count);
    for (expected, 0..) |exp, i| {
        try std.testing.expectEqualStrings(exp, call_log[i]);
    }
}

// Mock scripts
fn workerMovementUpdate(_: *anyopaque, _: f32) void {
    logCall("worker_movement");
}
fn productionSystemUpdate(_: *anyopaque, _: f32) void {
    logCall("production_system");
}
fn cameraControlUpdate(_: *anyopaque, _: f32) void {
    logCall("camera_control");
}
fn menuSystemUpdate(_: *anyopaque, _: f32) void {
    logCall("menu_system");
}
fn pauseOverlayUpdate(_: *anyopaque, _: f32) void {
    logCall("pause_overlay");
}
fn saveLoadUpdate(_: *anyopaque, _: f32) void {
    logCall("save_load");
}

var init_log: [16][]const u8 = undefined;
var init_count: usize = 0;

fn resetInitLog() void {
    init_count = 0;
}

fn workerMovementInit(_: *anyopaque) void {
    if (init_count < 16) {
        init_log[init_count] = "worker_movement_init";
        init_count += 1;
    }
}

var deinit_log: [16][]const u8 = undefined;
var deinit_count: usize = 0;

fn resetDeinitLog() void {
    deinit_count = 0;
}

fn workerMovementDeinit(_: *anyopaque) void {
    if (deinit_count < 16) {
        deinit_log[deinit_count] = "worker_movement_deinit";
        deinit_count += 1;
    }
}

const Manager = GameStateManager(16);

test "initial state" {
    var mgr = Manager.init(gamePtr(), "menu");
    try std.testing.expectEqualStrings("menu", mgr.getState());
    try std.testing.expectEqual(@as(usize, 0), mgr.state_change_count);
}

test "scripts run only in matching states" {
    resetLog();
    var mgr = Manager.init(gamePtr(), "playing");

    mgr.registerScriptFull("worker_movement", .{
        .update_fn = workerMovementUpdate,
        .states = &.{"playing"},
    });
    mgr.registerScriptFull("menu_system", .{
        .update_fn = menuSystemUpdate,
        .states = &.{"menu"},
    });
    mgr.registerScriptFull("camera_control", .{
        .update_fn = cameraControlUpdate,
        .states = &.{ "playing", "paused" },
    });

    // In "playing" state: worker_movement + camera_control should run
    mgr.setState("playing"); // activate scripts
    mgr.tick(0.016);
    try expectCalls(&.{ "worker_movement", "camera_control" });

    // Switch to "menu": only menu_system
    resetLog();
    mgr.setState("menu");
    mgr.tick(0.016);
    try expectCalls(&.{"menu_system"});

    // Switch to "paused": only camera_control
    resetLog();
    mgr.setState("paused");
    mgr.tick(0.016);
    try expectCalls(&.{"camera_control"});
}

test "null states means run in all states" {
    resetLog();
    var mgr = Manager.init(gamePtr(), "playing");

    // save_load runs everywhere
    mgr.registerScriptFull("save_load", .{
        .update_fn = saveLoadUpdate,
        .states = null,
    });
    mgr.registerScriptFull("production_system", .{
        .update_fn = productionSystemUpdate,
        .states = &.{"playing"},
    });

    mgr.setState("playing");
    mgr.tick(0.016);
    try expectCalls(&.{ "save_load", "production_system" });

    resetLog();
    mgr.setState("menu");
    mgr.tick(0.016);
    try expectCalls(&.{"save_load"}); // save_load still runs
}

test "registerScript shorthand registers for all states" {
    resetLog();
    var mgr = Manager.init(gamePtr(), "anything");

    mgr.registerScript("camera_control", cameraControlUpdate);
    mgr.setState("anything");
    mgr.tick(0.016);
    try expectCalls(&.{"camera_control"});

    resetLog();
    mgr.setState("other");
    mgr.tick(0.016);
    try expectCalls(&.{"camera_control"}); // still runs
}

test "queued state change applies on next tick" {
    resetLog();
    var mgr = Manager.init(gamePtr(), "menu");

    mgr.registerScriptFull("menu_system", .{
        .update_fn = menuSystemUpdate,
        .states = &.{"menu"},
    });
    mgr.registerScriptFull("worker_movement", .{
        .update_fn = workerMovementUpdate,
        .states = &.{"playing"},
    });

    mgr.setState("menu");
    mgr.tick(0.016);
    try expectCalls(&.{"menu_system"});

    // Queue change — shouldn't take effect yet
    resetLog();
    mgr.queueStateChange("playing");
    try std.testing.expectEqualStrings("menu", mgr.getState()); // still menu

    // Next tick processes the change
    mgr.tick(0.016);
    try std.testing.expectEqualStrings("playing", mgr.getState());
    try expectCalls(&.{"worker_movement"});
}

test "script init called on first activation" {
    resetLog();
    resetInitLog();
    var mgr = Manager.init(gamePtr(), "menu");

    mgr.registerScriptFull("worker_movement", .{
        .init_fn = workerMovementInit,
        .update_fn = workerMovementUpdate,
        .states = &.{"playing"},
    });

    // In menu — worker_movement not active, init not called
    mgr.setState("menu");
    mgr.tick(0.016);
    try std.testing.expectEqual(@as(usize, 0), init_count);

    // Switch to playing — init called
    mgr.setState("playing");
    mgr.tick(0.016);
    try std.testing.expectEqual(@as(usize, 1), init_count);
    try std.testing.expectEqualStrings("worker_movement_init", init_log[0]);

    // Second tick — init not called again
    mgr.tick(0.016);
    try std.testing.expectEqual(@as(usize, 1), init_count);
}

test "script deinit called when state changes away" {
    resetLog();
    resetInitLog();
    resetDeinitLog();
    var mgr = Manager.init(gamePtr(), "playing");

    mgr.registerScriptFull("worker_movement", .{
        .init_fn = workerMovementInit,
        .update_fn = workerMovementUpdate,
        .deinit_fn = workerMovementDeinit,
        .states = &.{"playing"},
    });

    mgr.setState("playing");
    mgr.tick(0.016);
    try std.testing.expectEqual(@as(usize, 1), init_count);
    try std.testing.expectEqual(@as(usize, 0), deinit_count);

    // Switch away — deinit called
    mgr.setState("menu");
    try std.testing.expectEqual(@as(usize, 1), deinit_count);
    try std.testing.expectEqualStrings("worker_movement_deinit", deinit_log[0]);

    // Switch back — init called again (re-initialized)
    mgr.setState("playing");
    mgr.tick(0.016);
    try std.testing.expectEqual(@as(usize, 2), init_count);
}

test "isScriptActive reflects current state" {
    var mgr = Manager.init(gamePtr(), "menu");

    mgr.registerScriptFull("worker_movement", .{
        .update_fn = workerMovementUpdate,
        .states = &.{"playing"},
    });
    mgr.registerScriptFull("menu_system", .{
        .update_fn = menuSystemUpdate,
        .states = &.{"menu"},
    });

    mgr.setState("menu");
    try std.testing.expect(!mgr.isScriptActive("worker_movement"));
    try std.testing.expect(mgr.isScriptActive("menu_system"));

    mgr.setState("playing");
    try std.testing.expect(mgr.isScriptActive("worker_movement"));
    try std.testing.expect(!mgr.isScriptActive("menu_system"));
}

test "getActiveScripts returns correct list" {
    resetLog();
    var mgr = Manager.init(gamePtr(), "playing");

    mgr.registerScriptFull("worker_movement", .{
        .update_fn = workerMovementUpdate,
        .states = &.{"playing"},
    });
    mgr.registerScriptFull("production_system", .{
        .update_fn = productionSystemUpdate,
        .states = &.{"playing"},
    });
    mgr.registerScriptFull("camera_control", .{
        .update_fn = cameraControlUpdate,
        .states = null,
    });
    mgr.registerScriptFull("menu_system", .{
        .update_fn = menuSystemUpdate,
        .states = &.{"menu"},
    });

    mgr.setState("playing");
    var buf: [8][]const u8 = undefined;
    const count = mgr.getActiveScripts(&buf);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("worker_movement", buf[0]);
    try std.testing.expectEqualStrings("production_system", buf[1]);
    try std.testing.expectEqualStrings("camera_control", buf[2]);
}

test "execution order matches registration order" {
    resetLog();
    var mgr = Manager.init(gamePtr(), "playing");

    // Register in specific order — should execute in same order
    mgr.registerScriptFull("camera_control", .{
        .update_fn = cameraControlUpdate,
        .states = &.{"playing"},
    });
    mgr.registerScriptFull("worker_movement", .{
        .update_fn = workerMovementUpdate,
        .states = &.{"playing"},
    });
    mgr.registerScriptFull("production_system", .{
        .update_fn = productionSystemUpdate,
        .states = &.{"playing"},
    });

    mgr.setState("playing");
    mgr.tick(0.016);
    try expectCalls(&.{ "camera_control", "worker_movement", "production_system" });
}

test "setState to same state is a no-op" {
    var mgr = Manager.init(gamePtr(), "playing");
    mgr.setState("playing");
    mgr.setState("playing");
    try std.testing.expectEqual(@as(usize, 1), mgr.state_change_count);
}

test "full game lifecycle: menu → playing → paused → playing" {
    resetLog();
    resetInitLog();
    resetDeinitLog();
    var mgr = Manager.init(gamePtr(), "menu");

    mgr.registerScriptFull("menu_system", .{
        .update_fn = menuSystemUpdate,
        .states = &.{"menu"},
    });
    mgr.registerScriptFull("worker_movement", .{
        .init_fn = workerMovementInit,
        .update_fn = workerMovementUpdate,
        .deinit_fn = workerMovementDeinit,
        .states = &.{"playing"},
    });
    mgr.registerScriptFull("pause_overlay", .{
        .update_fn = pauseOverlayUpdate,
        .states = &.{"paused"},
    });
    mgr.registerScriptFull("camera_control", .{
        .update_fn = cameraControlUpdate,
        .states = &.{ "playing", "paused" },
    });

    // Menu
    mgr.setState("menu");
    mgr.tick(0.016);
    try expectCalls(&.{"menu_system"});

    // Start playing
    resetLog();
    mgr.setState("playing");
    mgr.tick(0.016);
    try expectCalls(&.{ "worker_movement", "camera_control" });
    try std.testing.expectEqual(@as(usize, 1), init_count); // worker init

    // Pause
    resetLog();
    mgr.setState("paused");
    mgr.tick(0.016);
    try expectCalls(&.{ "pause_overlay", "camera_control" });
    try std.testing.expectEqual(@as(usize, 1), deinit_count); // worker deinit

    // Resume
    resetLog();
    mgr.setState("playing");
    mgr.tick(0.016);
    try expectCalls(&.{ "worker_movement", "camera_control" });
    try std.testing.expectEqual(@as(usize, 2), init_count); // worker re-inited

    try std.testing.expectEqual(@as(usize, 4), mgr.state_change_count);
}
