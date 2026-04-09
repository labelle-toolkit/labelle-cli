//! Probe file for the plugin-manifest system test.
//!
//! Lives in the game project's `state_machines/` directory, which is a
//! **plugin-declared** convention directory (contributed by
//! `fake-fsm-plugin/plugin.labelle`). `labelle generate` should copy
//! this file into `.labelle/<backend>_<platform>/state_machines/` as
//! part of the manifest-driven scan pass.
//!
//! The CI step asserts `.labelle/raylib_desktop/state_machines/probe_machine.zig`
//! exists after running `labelle generate` on this fixture.

pub const probe_marker: u32 = 0xFACADE;
