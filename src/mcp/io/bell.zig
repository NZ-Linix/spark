//! A doorbell for several I/O queues: each HTTP client and server
//! process rings it after posting, so the engine can sleep until any of its
//! servers has something, then read each with `poll`. One pending ring is
//! enough, since the engine reads every server when it wakes: a ring while
//! one is pending changes nothing, and none is ever lost. A timed wait starts
//! no task: the waiting thread itself sleeps until a ring or the deadline.

const std = @import("std");

pub const Bell = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    rung: bool = false,

    pub fn init(b: *Bell, io: std.Io) void {
        b.* = .{ .io = io };
    }

    /// From any task; holds the lock only to set the flag.
    pub fn ring(b: *Bell) void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        b.rung = true;
        b.cond.signal(b.io);
    }

    /// Waits for a ring, at most `timeout_ms` (forever when null). A wake-up
    /// may come early or late; the caller checks its own clock.
    pub fn wait(b: *Bell, timeout_ms: ?u32) error{Canceled}!void {
        const timeout: std.Io.Timeout = if (timeout_ms) |ms|
            .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } }
        else
            .none;
        const deadline = timeout.toDeadline(b.io);
        try b.mutex.lock(b.io);
        defer b.mutex.unlock(b.io);
        while (!b.rung) b.cond.waitTimeout(b.io, &b.mutex, deadline) catch |err| switch (err) {
            error.Timeout => return,
            error.Canceled => return error.Canceled,
        };
        b.rung = false;
    }
};

/// Milliseconds `wait` took, for the tests.
fn timed(b: *Bell, timeout_ms: ?u32) !i64 {
    const started = std.Io.Clock.awake.now(b.io).toMilliseconds();
    try b.wait(timeout_ms);
    return std.Io.Clock.awake.now(b.io).toMilliseconds() - started;
}
