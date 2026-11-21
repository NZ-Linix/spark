//! Schedules turning a terminal mode on again while spark runs. A terminal reset,
//! or another program's restore on the same terminal, can turn a DEC private
//! mode off under a running spark, and nothing tells spark. Each owner of such a
//! mode keeps one `Schedule` and writes the mode's enable sequence again when
//! the schedule is due. Enabling a mode that is already on changes nothing, so
//! the extra writes are harmless.
const std = @import("std");

/// How often spark turns each mode on again.
pub const interval_ms: i64 = 30_000;

pub const Schedule = struct {
    /// When the mode is next due. Null until the first check, which schedules
    /// it one interval out, because spark turned the mode on just before.
    next_ms: ?i64 = null,

    /// Makes the mode due at once, such as after a job-control resume whose
    /// terminal restore turned it off.
    pub fn requestNow(self: *Schedule) void {
        self.next_ms = std.math.minInt(i64);
    }

    /// Reports whether the mode is due. The first check only schedules it.
    pub fn due(self: *Schedule, now_ms: i64) bool {
        const next_ms = self.next_ms orelse {
            self.schedule(now_ms);
            return false;
        };
        return now_ms >= next_ms;
    }

    /// Makes the mode due one interval after `now_ms`.
    pub fn schedule(self: *Schedule, now_ms: i64) void {
        self.next_ms = std.math.add(i64, now_ms, interval_ms) catch std.math.maxInt(i64);
    }

    /// Returns true when the mode is due, and schedules the next time.
    pub fn take(self: *Schedule, now_ms: i64) bool {
        if (!self.due(now_ms)) return false;
        self.schedule(now_ms);
        return true;
    }
};
