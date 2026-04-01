/// Hierarchy components — universal parent-child relationship types.
/// These live in core so both engine and renderer plugins can use them.

/// Parent component — establishes parent-child hierarchy for position inheritance.
/// Parameterized by Entity type since we don't know the ECS backend at definition time.
pub fn ParentComponent(comptime Entity: type) type {
    return struct {
        entity: Entity,
        inherit_rotation: bool = false,
        inherit_scale: bool = false,
    };
}

/// Children component — tracks child entities for hierarchical operations.
/// Automatically managed by the engine when Parent components are added/removed.
pub fn ChildrenComponent(comptime Entity: type) type {
    return struct {
        const Self = @This();
        pub const MAX_CHILDREN = 16;

        children_buf: [MAX_CHILDREN]Entity = undefined,
        len: u8 = 0,

        pub fn getChildren(self: *const Self) []const Entity {
            return self.children_buf[0..self.len];
        }

        pub fn addChild(self: *Self, child: Entity) void {
            if (self.len >= MAX_CHILDREN) return;
            self.children_buf[self.len] = child;
            self.len += 1;
        }

        pub fn removeChild(self: *Self, child: Entity) void {
            var i: u8 = 0;
            while (i < self.len) : (i += 1) {
                if (self.children_buf[i] == child) {
                    self.children_buf[i] = self.children_buf[self.len - 1];
                    self.len -= 1;
                    return;
                }
            }
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
