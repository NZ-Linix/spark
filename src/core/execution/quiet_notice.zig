//! When a wait on a running shell command ends because the command went
//! quiet, and when its result asks the model to check the command. A command
//! that prints nothing for the quiet limit may have hung, or may be a server
//! or watcher at rest; spark never stops it, but a model that waits on it learns
//! how long it has been quiet.
//!
//! Every time is an argument, so tests choose the clock. The module imports
//! only `std`. `tests/tla/managed_execution/QuietWait.tla` models it, and
//! `tests/tla/drivers/managed_execution/` walks it along that model.

const std = @import("std");

/// How long a command may print nothing before its result asks the model to
/// check it.
pub const default_limit_ms: u64 = 2 * std.time.ms_per_min;

/// The shortest limit `SPARK_TEST_SHELL_QUIET_NOTICE_MS` may set.
pub const min_test_limit_ms: u64 = 100;

/// One wait on a running command, such as an `interact` call.
pub const Wait = struct {
    started_ms: i64,
    /// The wait's ceiling, its `yield_time_ms`.
    ceiling_ms: u64,
    /// The wait has seen the command under the quiet limit, so the moment
    /// the quiet time reaches the limit ends it. A wait that begins past the
    /// limit runs to its ceiling until new output brings the command back
    /// under it, so a model that waits again is not woken at once.
    armed: bool,
};

pub const End = enum {
    /// The command reached the quiet limit during the wait.
    quiet,
    /// The wait ran its whole ceiling.
    ceiling,
};

pub const Poll = struct {
    wait: Wait,
    end: ?End,
};

/// How long the command has printed nothing: from its last output, or from
/// its start when it has printed nothing yet. A clock that moves back reads
/// as no time.
pub fn quietMs(now_ms: i64, last_output_ms: i64) u64 {
    return elapsedMs(last_output_ms, now_ms);
}

/// How long the command has run.
fn runningMs(now_ms: i64, started_ms: i64) u64 {
    return elapsedMs(started_ms, now_ms);
}

/// The result asks the model to check the command.
fn noticeDue(quiet_ms: u64, limit_ms: u64) bool {
    return quiet_ms >= limit_ms;
}

/// What a result for a running command says about its time.
pub const Times = struct {
    running_ms: u64,
    quiet_ms: u64,
    notice: bool,
};

/// The time fields of a result: only a running command has them.
pub fn timesFor(running: bool, now_ms: i64, started_ms: i64, last_output_ms: i64, limit_ms: u64) ?Times {
    if (!running) return null;
    const quiet_ms = quietMs(now_ms, last_output_ms);
    return .{
        .running_ms = runningMs(now_ms, started_ms),
        .quiet_ms = quiet_ms,
        .notice = noticeDue(quiet_ms, limit_ms),
    };
}

pub fn beginWait(now_ms: i64, last_output_ms: i64, ceiling_ms: u64, limit_ms: u64) Wait {
    return .{
        .started_ms = now_ms,
        .ceiling_ms = ceiling_ms,
        .armed = !noticeDue(quietMs(now_ms, last_output_ms), limit_ms),
    };
}

/// One look at a running command during a wait: the wait as it now stands,
/// and why it ends, or null while it goes on.
pub fn poll(wait: Wait, now_ms: i64, last_output_ms: i64, limit_ms: u64) Poll {
    const due = noticeDue(quietMs(now_ms, last_output_ms), limit_ms);
    var next = wait;
    if (!due) next.armed = true;
    if (next.armed and due) return .{ .wait = next, .end = .quiet };
    if (elapsedMs(wait.started_ms, now_ms) >= wait.ceiling_ms) return .{ .wait = next, .end = .ceiling };
    return .{ .wait = next, .end = null };
}

/// The quiet limit: the default, or the value of
/// `SPARK_TEST_SHELL_QUIET_NOTICE_MS` when it is a whole number of milliseconds
/// from `min_test_limit_ms` to the default.
pub fn limitFromValue(value: ?[]const u8) u64 {
    const text = value orelse return default_limit_ms;
    const parsed = std.fmt.parseInt(u64, text, 10) catch return default_limit_ms;
    if (parsed < min_test_limit_ms or parsed > default_limit_ms) return default_limit_ms;
    return parsed;
}

fn elapsedMs(from_ms: i64, to_ms: i64) u64 {
    if (to_ms <= from_ms) return 0;
    return @intCast(to_ms - from_ms);
}

const testing = std.testing;

test "the notice is due exactly at the limit" {
    try testing.expect(!noticeDue(1_499, 1_500));
    try testing.expect(noticeDue(1_500, 1_500));
    try testing.expect(noticeDue(1_501, 1_500));
}
