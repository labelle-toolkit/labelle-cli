//! No-op stub for the fake plugin in the plugin-manifest system test.
//! The test only exercises the generator's manifest-reading pipeline;
//! nothing actually imports this module at runtime.

pub const marker: u32 = 0xFACEFEED;
