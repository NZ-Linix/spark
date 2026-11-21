//! Bounded, always-on context-compaction breadcrumbs for the user-initiated
//! /trace report. Records the same events that the `context_compaction`
//! debug-trace scope emits so compaction decisions and failure reasons stay
//! visible even when SPARK_TRACE is off. Callers supply internal counters, stage
//! and enum names only, never user prompts or tool payloads; the one bounded
//! provider error detail is secret-masked and control-byte neutralized at the
//! capture site before it reaches the ring. A second ring keeps only the
//! failed events, so a failure stays in the report however many events come
//! after it.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");

const trace_scope = "context_compaction";

/// Records an informational compaction decision in the always-on ring and
/// forwards the same event to the opt-in debug-trace log unchanged.
pub fn info(ctx: debug_trace.TraceContext, comptime kind: Kind, comptime fmt: []const u8, args: anytype) void {
    record(kind, ctx.turn_id, ctx.step_id, ctx.subagent_id, false, fmt, args);
    debug_trace.eventf(trace_scope, @tagName(kind), ctx, fmt, args);
}

/// Same as `info` but marks the event as a failure so the trace report can
/// surface it under Problems.
pub fn failure(ctx: debug_trace.TraceContext, comptime kind: Kind, comptime fmt: []const u8, args: anytype) void {
    record(kind, ctx.turn_id, ctx.step_id, ctx.subagent_id, true, fmt, args);
    debug_trace.eventf(trace_scope, @tagName(kind), ctx, fmt, args);
}

/// Records a high-cadence compaction evaluation only when it changed the
/// outcome; routine no-op evaluations still reach the debug-trace log but do
/// not evict rarer events from the bounded ring.
pub fn infoIf(recorded: bool, ctx: debug_trace.TraceContext, comptime kind: Kind, comptime fmt: []const u8, args: anytype) void {
    if (recorded) record(kind, ctx.turn_id, ctx.step_id, ctx.subagent_id, false, fmt, args);
    debug_trace.eventf(trace_scope, @tagName(kind), ctx, fmt, args);
}

/// Records a free-form compaction note (no turn context available at the
/// call site) and forwards it to the debug-trace log unchanged.
pub fn log(failed: bool, comptime fmt: []const u8, args: anytype) void {
    record(.log, 0, 0, 0, failed, fmt, args);
    debug_trace.logf(trace_scope, fmt, args);
}

pub const ring_capacity = 64;
/// Failed events kept apart from the window, so later events never push them
/// out.
pub const failure_ring_capacity = 32;
const max_detail_bytes = 512;

pub const Kind = enum {
    log,
    provider_start,
    provider_completed,
    summary_transport_failed,
    summary_too_long,
    summary_incomplete,
    summary_tool_call_rejected,
    summary_truncated,
    source_checkpointed,
    transaction_failed,
    credential_unauthorized,
    committed,
    decision,
    overflow_without_compaction,
    no_compactable_context,
    retention_exhausted,
    retention_forced_zero,
    installed,
    overflow_recovery_incomplete,
    provider_overflow_recovery,
};

pub const Event = struct {
    sequence: u64 = 0,
    timestamp_ms: i64 = 0,
    turn_id: u64 = 0,
    step_id: u64 = 0,
    subagent_id: u64 = 0,
    failed: bool = false,
    kind: Kind = .log,
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
};

fn Ring(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        events: [capacity]Event = std.mem.zeroes([capacity]Event),
        head: usize = 0,
        stored: usize = 0,
        total: u64 = 0,

        /// Stores `event` as the newest, numbered by this ring's count, and
        /// returns the stored copy.
        fn append(self: *Self, event: *const Event) *const Event {
            const slot = self.keep(event);
            slot.sequence = self.total;
            return slot;
        }

        /// Stores `event` as the newest with the sequence number it carries.
        fn keep(self: *Self, event: *const Event) *Event {
            self.total +|= 1;
            const slot = &self.events[self.head];
            slot.* = event.*;
            self.head = (self.head + 1) % capacity;
            self.stored = @min(self.stored + 1, capacity);
            return slot;
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

// Keep format specialization at the caller while sharing ring mutation without
// adding another Event-sized stack copy.
inline fn record(kind: Kind, turn_id: u64, step_id: u64, subagent_id: u64, failed: bool, comptime fmt: []const u8, args: anytype) void {
    var recorded: Event = .{
        .timestamp_ms = io_mod.milliTimestamp(),
        .turn_id = turn_id,
        .step_id = step_id,
        .subagent_id = subagent_id,
        .failed = failed,
        .kind = kind,
    };
    var writer: std.Io.Writer = .fixed(&recorded.detail_buf);
    writer.print(fmt, args) catch {
        recorded.truncated = true;
    };
    recorded.detail_len = @intCast(writer.buffered().len);
    append_recorded_event(&recorded);
}

noinline fn append_recorded_event(event: *Event) void {
    // The detail may hold the look-ahead byte; cut it back on a UTF-8
    // boundary before it is stored.
    const kept = text_utils.utf8PrefixByBytes(event.detail(), max_detail_bytes);
    if (kept.len < event.detail_len) event.truncated = true;
    event.detail_len = @intCast(kept.len);
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const newest = ring.append(event);
    // Under the same lock, and with the window's sequence number, so a kept
    // failure and its line in the window carry the same number.
    if (event.failed) _ = failures.keep(newest);
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
/// longer holds.
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

test "compaction diagnostic ring retains the newest events in order" {
    var local: Ring(ring_capacity) = .{};
    for (0..ring_capacity + 3) |index| {
        _ = local.append(&.{ .timestamp_ms = @intCast(index) });
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
