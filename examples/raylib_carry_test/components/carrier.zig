/// Marks an entity as a carrier that picks up and drops items.
pub const Carrier = struct {
    /// Current phase: 0=moving to pickup, 1=carrying, 2=moving to drop, 3=returning
    phase: u8 = 0,
    /// Entity ID of the item being carried (0 = none)
    item_id: u64 = 0,
    /// Pickup position X
    pickup_x: f32 = 100,
    /// Drop position X
    drop_x: f32 = 600,
    /// Movement speed
    speed: f32 = 100,
};
