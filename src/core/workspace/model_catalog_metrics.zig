//! Bounded, always-on model-catalog breadcrumbs for the user-initiated
//! /trace report. Records catalog load outcomes, capability lookup misses, and
//! image gate rejections so a shared trace explains why spark could not verify a
//! model's capabilities even when SPARK_TRACE is off. Callers supply model slugs,
//! enum names, and internal counters only, never credentials or user prompts.
//! A second ring keeps only the failed events, so a failure stays in the
//! report however many events come after it.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

pub const ring_capacity = 32;
/// Failed events kept apart from the window, so later events never push them
/// out.
pub const failure_ring_capacity = 32;
const max_detail_bytes = 256;

pub const Kind = enum {
    load,
    lookup,
    image_gate,
};

pub const Event = struct {
    sequence: u64 = 0,
    timestamp_ms: i64 = 0,
    failed: bool = false,
    kind: Kind = .load,
    detail_len: u16 = 0,
    truncated: bool = false,
    /// One byte longer than the kept detail, so a cut can see whether the
    /// next byte continues a UTF-8 sequence.
    detail_buf: [max_detail_bytes + 1]u8 = @splat(0),

    pub fn name(self: *const Event) []const u8 {
        return @tagName(self.kind);
    }

    pub fn detail(self: *const Event) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }

    fn matches(self: *const Event, kind: Kind, event_detail: []const u8, failed: bool) bool {
        return self.failed == failed and
            self.kind == kind and
            std.mem.eql(u8, self.detail(), event_detail);
    }
};

fn Ring(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        events: [capacity]Event = std.mem.zeroes([capacity]Event),
        head: usize = 0,
        stored: usize = 0,
        total: u64 = 0,

        /// Stores `event` as the newest, numbered by this ring's count.
        fn append(self: *Self, event: Event) void {
            self.keep(event);
            self.events[(self.head + capacity - 1) % capacity].sequence = self.total;
        }

        /// Stores `event` as the newest with the sequence number it carries.
        fn keep(self: *Self, event: Event) void {
            self.total +|= 1;
            self.events[self.head] = event;
            self.head = (self.head + 1) % capacity;
            self.stored = @min(self.stored + 1, capacity);
        }

        fn newest(self: *const Self) ?*const Event {
            if (self.stored == 0) return null;
            return &self.events[(self.head + capacity - 1) % capacity];
        }

        fn snapshot(self: *const Self, out: []Event) usize {
            const count = @min(self.stored, out.len);
            for (out[0..count], 0..) |*event, index| {
                event.* = self.events[(self.head + capacity - count + index) % capacity];
            }
            return count;
        }

        fn clear(self: *Self) void {
            self.head = 0;
            self.stored = 0;
            self.total = 0;
        }
    };
}

var mutex: std.Io.Mutex = .init;
// Zero-initialized storage stays in .bss; unused slots are never read.
var ring: Ring(ring_capacity) = std.mem.zeroes(Ring(ring_capacity));
var failures: Ring(failure_ring_capacity) = std.mem.zeroes(Ring(failure_ring_capacity));

/// Records one catalog event. Consecutive identical events collapse into the
/// newest slot so a per-turn lookup miss cannot evict rarer load and rejection
/// evidence from the bounded ring.
pub fn record(kind: Kind, failed: bool, comptime fmt: []const u8, args: anytype) void {
    var event: Event = .{
        .timestamp_ms = io_mod.milliTimestamp(),
        .failed = failed,
        .kind = kind,
    };
    var writer: std.Io.Writer = .fixed(&event.detail_buf);
    writer.print(fmt, args) catch {
        event.truncated = true;
    };
    keepDetail(&event, writer.buffered().len);
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (ring.newest()) |last| {
        if (last.matches(event.kind, event.detail(), event.failed)) return;
    }
    ring.append(event);
    // Under the same lock, and with the window's sequence number, so a kept
    // failure and its line in the window carry the same `seq`.
    if (event.failed) failures.keep(ring.newest().?.*);
}

/// Cuts the formatted detail back to `max_detail_bytes`, on a UTF-8 boundary.
fn keepDetail(event: *Event, written: usize) void {
    const kept = text_utils.utf8PrefixByBytes(event.detail_buf[0..written], max_detail_bytes);
    if (kept.len < written) event.truncated = true;
    event.detail_len = @intCast(kept.len);
}

pub fn snapshot(out: []Event) usize {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return ring.snapshot(out);
}

/// Copies the newest kept failed events into `out`, oldest first. Later
/// events never remove them; only newer failures and `reset` do.
pub fn snapshotFailures(out: []Event) usize {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return failures.snapshot(out);
}

/// Failed events recorded this session, including any the failure ring no
/// longer holds. A repeat that collapses into the newest event is not counted.
pub fn failureCount() u64 {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return failures.total;
}

pub fn reset() void {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    ring.clear();
    failures.clear();
}

test "model catalog diagnostic ring retains the newest events in order" {
    var local: Ring(ring_capacity) = .{};
    for (0..ring_capacity + 3) |index| {
        local.append(.{ .timestamp_ms = @intCast(index) });
    }
    var events: [ring_capacity]Event = undefined;
    try std.testing.expectEqual(ring_capacity, local.snapshot(&events));
    try std.testing.expectEqual(@as(u64, 4), events[0].sequence);
    try std.testing.expectEqual(@as(i64, 3), events[0].timestamp_ms);
    try std.testing.expectEqual(@as(u64, ring_capacity + 3), events[ring_capacity - 1].sequence);
    var tail: [2]Event = undefined;
    try std.testing.expectEqual(@as(usize, 2), local.snapshot(&tail));
    try std.testing.expectEqual(@as(u64, ring_capacity + 2), tail[0].sequence);
    try std.testing.expectEqual(@as(usize, 0), local.snapshot(&.{}));
}
