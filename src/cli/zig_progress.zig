//! Parser for Zig's native `std.Progress` IPC wire format (labelle-cli#284).
//!
//! When a child is spawned with `ZIG_PROGRESS=<fd>` in its environment,
//! `std.Progress.start` inside that child writes progress-tree snapshots
//! to that fd instead of rendering to the terminal. This module decodes
//! those snapshots so the CLI gets *real* compile step counts and the
//! current unit name — no log-line scraping. Caveat (labelle-cli#317):
//! the `zig build` frontend does not forward the pipe to the build runner
//! it spawns, so in practice only the frontend's own nodes arrive —
//! transitively-decoded "steps" data awaits ziglang/zig#24722 (see
//! `runner.zig` for the full mechanism).
//!
//! Wire format (verified against `lib/std/Progress.zig` of Zig 0.16.0 —
//! `serialize`/`writeIpc` on the sending side, `Ipc.Data.findLastPacket`
//! on the receiving side):
//!
//!   packet := nodes_len:u8
//!             storage[nodes_len]   — 128 bytes each:
//!                 completed_count:u32 LE
//!                 estimated_total_count:u32 LE   (0 = unknown)
//!                 name:[120]u8                   (NUL-padded)
//!             parent[nodes_len]:u8 — 0xFF = root/none, 0xFE = unused,
//!                                    else index into THIS packet's nodes
//!
//! Every packet is a complete snapshot of the tree (children's subtrees
//! already folded in by the intermediate `zig build` process), sent about
//! every 80ms. Like std's own reader, we only ever act on the LAST complete
//! packet in the buffer and keep any trailing partial packet for the next
//! read. `estimated_total_count == 0xFFFFFFFF` marks an internal IPC-proxy
//! node whose `completed_count` is a file-descriptor slot, not a count —
//! such nodes are skipped.
//!
//! Tree shape the build runner produces (lib/compiler/build_runner.zig;
//! not currently relayed by the frontend — see above):
//! node 0 is the root (empty name); a child named "steps" carries
//! `completed/estimated = finished/total build steps` — that is the N/M a
//! consumer wants. The deepest named node is the current activity (e.g. a
//! compiler's "Semantic Analysis" / the unit being processed).
//!
//! Pure: no I/O, no clock, no allocation. The pipe pump lives in
//! `runner.zig`; the phase model in `progress.zig`.

const std = @import("std");

pub const max_name_len = 120;
const storage_size = 128; // 4 + 4 + 120
const bytes_per_node = storage_size + 1; // + parent byte
const parent_none: u8 = 0xFF;
const parent_unused: u8 = 0xFE;
/// std's sender serializes at most `node_storage_buffer_len` (127) nodes
/// per packet; a larger claim means we lost framing.
const max_nodes_per_packet: usize = 127;
/// The special `estimated_total_count` marking an IPC-proxy node.
const ipc_marker: u32 = std.math.maxInt(u32);

/// What one snapshot boils down to for the progress feed.
pub const Snapshot = struct {
    /// Completed / total build steps, from the `"steps"` node (fallback:
    /// the root node when it carries a real total). Null when unknown.
    step: ?u64 = null,
    total: ?u64 = null,
    /// Name of the deepest active node — the current activity.
    detail_buf: [max_name_len]u8 = @splat(0),
    detail_len: u8 = 0,
    /// A node name indicates the linker is running (best-effort heuristic;
    /// when it never trips, the consumer simply stays in the compile phase).
    saw_link: bool = false,
    /// Nodes decoded from the packet (diagnostics).
    node_count: usize = 0,

    pub fn detail(s: *const Snapshot) []const u8 {
        return s.detail_buf[0..s.detail_len];
    }
};

/// Incremental stream parser. Feed it whatever `read(2)` returns; poll it
/// for the latest complete snapshot.
pub const Parser = struct {
    /// Legit packets are at most `1 + 127*129` = 16384 bytes; keep room for
    /// a couple plus a partial tail.
    pub const buffer_capacity = 48 * 1024;

    buf: [buffer_capacity]u8 = undefined,
    len: usize = 0,

    /// Append raw bytes from the pipe. If the buffer would overflow (which
    /// a healthy stream never does — `poll` consumes as we go), the buffer
    /// is reset: losing a snapshot is fine, they are full-state.
    pub fn feed(p: *Parser, bytes: []const u8) void {
        if (p.len + bytes.len > buffer_capacity) {
            p.len = 0;
            if (bytes.len > buffer_capacity) return; // absurd; drop
        }
        @memcpy(p.buf[p.len..][0..bytes.len], bytes);
        p.len += bytes.len;
    }

    /// Decode and consume the LAST complete packet buffered, preserving any
    /// trailing partial packet. Returns null when no complete packet is
    /// available or the packet is empty (both mean "no new information").
    pub fn poll(p: *Parser) ?Snapshot {
        var packet_start: usize = 0;
        var packet_end: usize = 0;
        var found = false;
        while (p.len - packet_end >= 1) {
            const n: usize = p.buf[packet_end];
            if (n > max_nodes_per_packet) {
                // Framing lost (never produced by a real zig): resync by
                // dropping everything buffered.
                p.len = 0;
                return null;
            }
            const packet_len = 1 + n * bytes_per_node;
            if (packet_end + packet_len > p.len) break;
            packet_start = packet_end;
            packet_end += packet_len;
            found = true;
        }
        if (!found) return null;

        const snapshot = parsePacket(p.buf[packet_start..packet_end]);

        // Rebase: keep the unconsumed tail for the next feed.
        const tail_len = p.len - packet_end;
        std.mem.copyForwards(u8, p.buf[0..tail_len], p.buf[packet_end..p.len]);
        p.len = tail_len;

        return snapshot;
    }
};

/// Decode one complete packet. Exposed for tests.
pub fn parsePacket(bytes: []const u8) ?Snapshot {
    const n: usize = bytes[0];
    if (n == 0) return null;
    std.debug.assert(bytes.len == 1 + n * bytes_per_node);
    const storage = bytes[1..][0 .. n * storage_size];
    const parents = bytes[1 + n * storage_size ..][0..n];

    var snap = Snapshot{ .node_count = n };
    var steps_found = false;
    var best_depth: usize = 0;
    var have_detail = false;

    for (0..n) |i| {
        const estimated = nodeEstimated(storage, i);
        if (estimated == ipc_marker) continue; // fd-proxy node, not a count
        const name = nodeName(storage, i);

        if (!steps_found and std.mem.eql(u8, name, "steps")) {
            snap.step = nodeCompleted(storage, i);
            snap.total = if (estimated > 0) estimated else null;
            steps_found = true;
        }

        if (name.len > 0) {
            if (nameIndicatesLink(name)) snap.saw_link = true;
            const depth = depthOf(parents, i);
            // `>=` so a later node wins ties: siblings are created in
            // order, making the most recent activity the better label.
            if (!have_detail or depth >= best_depth) {
                best_depth = depth;
                snap.detail_len = @intCast(name.len);
                @memcpy(snap.detail_buf[0..name.len], name);
                have_detail = true;
            }
        }
    }

    if (!steps_found) {
        // Fallback: the sender's root node, when it carries a real total.
        const estimated = nodeEstimated(storage, 0);
        if (estimated != ipc_marker and estimated > 0) {
            snap.step = nodeCompleted(storage, 0);
            snap.total = estimated;
        }
    }

    return snap;
}

fn nodeCompleted(storage: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, storage[i * storage_size ..][0..4], .little);
}

fn nodeEstimated(storage: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, storage[i * storage_size + 4 ..][0..4], .little);
}

fn nodeName(storage: []const u8, i: usize) []const u8 {
    const raw = storage[i * storage_size + 8 ..][0..max_name_len];
    const end = std.mem.indexOfScalar(u8, raw, 0) orelse max_name_len;
    return raw[0..end];
}

/// Walk the parent chain to the root. Hop count is capped at the node count
/// so untrusted/cyclic parent data can never loop forever (mirrors std's
/// own distrust of child data).
fn depthOf(parents: []const u8, i: usize) usize {
    var depth: usize = 0;
    var cur = i;
    var hops: usize = 0;
    while (hops < parents.len) : (hops += 1) {
        const par = parents[cur];
        if (par == parent_none or par == parent_unused) return depth;
        if (par >= parents.len) return depth; // out-of-range: treat as root
        cur = par;
        depth += 1;
    }
    return depth;
}

/// Does this node name look like the link stage? Zig's linker progress
/// node is named "linking" ("LLD Link" historically); match conservatively
/// so a user step named e.g. "blink" can't trip it.
fn nameIndicatesLink(name: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(name, "linking")) return true;
    if (std.ascii.startsWithIgnoreCase(name, "lld ")) return true;
    if (std.ascii.eqlIgnoreCase(name, "link")) return true;
    return false;
}

// --- Tests ---

test {
    @import("zspec").runAll(@This());
}

const expect = @import("zspec").expect;

/// Test helper: append one serialized packet built from (name, completed,
/// estimated, parent) tuples — the exact byte layout `writeIpc` produces.
const PacketBuilder = struct {
    const TestNode = struct {
        name: []const u8,
        completed: u32 = 0,
        estimated: u32 = 0,
        parent: u8 = parent_none,
    };

    fn append(list: *std.ArrayList(u8), allocator: std.mem.Allocator, nodes: []const TestNode) !void {
        try list.append(allocator, @intCast(nodes.len));
        for (nodes) |node| {
            var storage: [storage_size]u8 = @splat(0);
            std.mem.writeInt(u32, storage[0..4], node.completed, .little);
            std.mem.writeInt(u32, storage[4..8], node.estimated, .little);
            @memcpy(storage[8..][0..node.name.len], node.name);
            try list.appendSlice(allocator, &storage);
        }
        for (nodes) |node| {
            try list.append(allocator, node.parent);
        }
    }
};

pub const PacketDecodingSpec = struct {
    test "decodes step/total from the steps node and detail from the deepest node" {
        const allocator = std.testing.allocator;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        try PacketBuilder.append(&bytes, allocator, &.{
            .{ .name = "" }, // root: zig build's main node has no name
            .{ .name = "steps", .completed = 34, .estimated = 210, .parent = 0 },
            .{ .name = "zig build-exe game Debug native", .parent = 1 },
            .{ .name = "Semantic Analysis", .completed = 5, .estimated = 40, .parent = 2 },
        });

        var parser = Parser{};
        parser.feed(bytes.items);
        const snap = parser.poll() orelse return error.TestFailed;
        try expect.equal(snap.step.?, @as(u64, 34));
        try expect.equal(snap.total.?, @as(u64, 210));
        try std.testing.expectEqualStrings("Semantic Analysis", snap.detail());
        try expect.toBeFalse(snap.saw_link);
        try expect.equal(snap.node_count, @as(usize, 4));
    }

    test "last complete packet wins when several are buffered" {
        const allocator = std.testing.allocator;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        try PacketBuilder.append(&bytes, allocator, &.{
            .{ .name = "" },
            .{ .name = "steps", .completed = 1, .estimated = 9, .parent = 0 },
        });
        try PacketBuilder.append(&bytes, allocator, &.{
            .{ .name = "" },
            .{ .name = "steps", .completed = 7, .estimated = 9, .parent = 0 },
        });

        var parser = Parser{};
        parser.feed(bytes.items);
        const snap = parser.poll() orelse return error.TestFailed;
        try expect.equal(snap.step.?, @as(u64, 7));
        // Both packets were consumed.
        try expect.equal(parser.len, @as(usize, 0));
    }

    test "partial trailing packet is preserved and completes on the next feed" {
        const allocator = std.testing.allocator;
        var whole: std.ArrayList(u8) = .empty;
        defer whole.deinit(allocator);
        try PacketBuilder.append(&whole, allocator, &.{
            .{ .name = "" },
            .{ .name = "steps", .completed = 3, .estimated = 5, .parent = 0 },
        });

        var parser = Parser{};
        const split = whole.items.len - 17; // mid-parents/mid-storage cut
        parser.feed(whole.items[0..split]);
        try std.testing.expect(parser.poll() == null); // incomplete: nothing to report
        try expect.equal(parser.len, split); // partial bytes retained

        parser.feed(whole.items[split..]);
        const snap = parser.poll() orelse return error.TestFailed;
        try expect.equal(snap.step.?, @as(u64, 3));
        try expect.equal(snap.total.?, @as(u64, 5));
    }

    test "empty packet (nodes_len 0) is consumed but reports nothing" {
        var parser = Parser{};
        parser.feed(&.{0});
        try std.testing.expect(parser.poll() == null);
        try expect.equal(parser.len, @as(usize, 0));
    }

    test "ipc-proxy nodes (estimated == maxInt u32) are skipped everywhere" {
        const allocator = std.testing.allocator;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        try PacketBuilder.append(&bytes, allocator, &.{
            .{ .name = "" },
            // A proxy node whose name would otherwise win the depth race
            // AND whose counts would be misread as 3/maxInt.
            .{ .name = "steps", .completed = 3, .estimated = ipc_marker, .parent = 0 },
            .{ .name = "real work", .completed = 1, .estimated = 2, .parent = 0 },
        });

        var parser = Parser{};
        parser.feed(bytes.items);
        const snap = parser.poll() orelse return error.TestFailed;
        try std.testing.expect(snap.step == null);
        try std.testing.expect(snap.total == null);
        try std.testing.expectEqualStrings("real work", snap.detail());
    }

    test "linker node flips saw_link" {
        const allocator = std.testing.allocator;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        try PacketBuilder.append(&bytes, allocator, &.{
            .{ .name = "" },
            .{ .name = "steps", .completed = 208, .estimated = 210, .parent = 0 },
            .{ .name = "linking game", .parent = 1 },
        });

        var parser = Parser{};
        parser.feed(bytes.items);
        const snap = parser.poll() orelse return error.TestFailed;
        try expect.toBeTrue(snap.saw_link);
        try std.testing.expectEqualStrings("linking game", snap.detail());
    }

    test "a user step merely containing 'link' does not flip saw_link" {
        const allocator = std.testing.allocator;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        try PacketBuilder.append(&bytes, allocator, &.{
            .{ .name = "" },
            .{ .name = "blink assets", .parent = 0 },
        });
        var parser = Parser{};
        parser.feed(bytes.items);
        const snap = parser.poll() orelse return error.TestFailed;
        try expect.toBeFalse(snap.saw_link);
    }

    test "root counts are the fallback when no steps node exists" {
        const allocator = std.testing.allocator;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        try PacketBuilder.append(&bytes, allocator, &.{
            .{ .name = "compiling", .completed = 2, .estimated = 8 },
        });
        var parser = Parser{};
        parser.feed(bytes.items);
        const snap = parser.poll() orelse return error.TestFailed;
        try expect.equal(snap.step.?, @as(u64, 2));
        try expect.equal(snap.total.?, @as(u64, 8));
        try std.testing.expectEqualStrings("compiling", snap.detail());
    }

    test "garbage nodes_len resets the stream instead of wedging" {
        var parser = Parser{};
        parser.feed(&.{ 200, 1, 2, 3 }); // 200 nodes is beyond std's own cap
        try std.testing.expect(parser.poll() == null);
        try expect.equal(parser.len, @as(usize, 0)); // resynced
    }

    test "cyclic parent data cannot loop the depth walk" {
        const allocator = std.testing.allocator;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        // Two nodes pointing at each other.
        try PacketBuilder.append(&bytes, allocator, &.{
            .{ .name = "a", .parent = 1 },
            .{ .name = "b", .parent = 0 },
        });
        var parser = Parser{};
        parser.feed(bytes.items);
        // Must terminate; whichever detail wins is fine.
        _ = parser.poll() orelse return error.TestFailed;
    }
};
