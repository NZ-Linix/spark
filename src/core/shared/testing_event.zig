//! Waiting for a test thread's event, so a thread that never sets it fails its
//! test instead of hanging it.

const std = @import("std");
const io_mod = @import("io.zig");

/// How long a test waits for a thread it started to set its event.
const limit_ms: u32 = 5000;

/// Whether `event` is set within `ms`. The wait ends when the event is set, so
/// a thread that gets there quickly costs the test no time.
fn setWithin(event: *std.Io.Event, ms: u32) bool {
    event.waitTimeout(io_mod.getIo(), .{ .duration = .{
        .clock = .awake,
        .raw = .fromMilliseconds(ms),
    } }) catch return false;
    return true;
}

/// Whether `event` is set within `limit_ms`.
pub fn setInTime(event: *std.Io.Event) bool {
    return setWithin(event, limit_ms);
}
