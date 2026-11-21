//! A lock whose holder stamps the lock file with the time, on the awake
//! clock, when it takes it and again before each step of its work, every step
//! ending within a bound its users agree on. A waiter gives up once the stamp,
//! or its own start if later, is `wait_ms` old: that bound plus `slack_ms`. So
//! a live holder is never given up on however long its work, and one frozen
//! holding the lock (ctrl+z) costs a waiter `wait_ms`. A stamp from the
//! future, a damaged one, or none, as from an older spark, counts as the waiter's
//! start (`tests/tla/mcp_host/StoreLockBudget.tla`).

const std = @import("std");
const io_mod = @import("io.zig");
const debug_trace = @import("debug_trace.zig");

/// How much longer than a step's bound a waiter gives the holder.
pub const slack_ms: i64 = 2_000;

pub const Taken = struct { lock: io_mod.TimedAdvisoryLock, stamp_ms: i64 };

/// Lock file `name` in `dir`, stamped, for a waiter that started at
/// `started`, or `error.LockBusy` once its holder's stamp is `wait_ms` old.
/// `ops` tries the lock; `label` names it in `scope`'s traces.
pub fn acquire(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    started: i64,
    wait_ms: i64,
    ops: io_mod.LockOps,
    scope: []const u8,
    label: []const u8,
) !Taken {
    while (true) {
        if (io_mod.acquireTimedAdvisoryLockWithOps(dir, name, 0, ops)) |advisory| {
            const now = io_mod.awakeMilliTimestamp();
            writeStamp(advisory.file, now, scope);
            debug_trace.logf(scope, "{s} lock taken stamp={d} started={d}", .{ label, now, started });
            return .{ .lock = advisory, .stamp_ms = now };
        } else |err| if (err != error.LockBusy) return err;
        const stamp = readStamp(dir, name);
        const now = io_mod.awakeMilliTimestamp();
        if (expired(stamp, started, now, wait_ms)) {
            debug_trace.logf(scope, "{s} lock given up stamp={?d} started={d} at={d}", .{ label, stamp, started, now });
            return error.LockBusy;
        }
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
}

/// Stamps a held lock again, before its holder's next step, and returns the stamp.
pub fn restamp(file: std.Io.File, scope: []const u8, label: []const u8) i64 {
    const now = io_mod.awakeMilliTimestamp();
    writeStamp(file, now, scope);
    debug_trace.logf(scope, "{s} lock stamped stamp={d}", .{ label, now });
    return now;
}

/// Writes a stamp over the lock file's first 8 bytes. A holder whose stamp
/// didn't land still holds the lock; its waiters time it from an older stamp
/// or their own start, as with an older spark.
pub fn writeStamp(file: std.Io.File, now_ms: i64, scope: []const u8) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &bytes, now_ms, .little);
    file.writePositionalAll(io_mod.getIo(), &bytes, 0) catch |err|
        debug_trace.logf(scope, "lock stamp not written err={s}", .{@errorName(err)});
}

/// The stamp the holder of lock file `name` wrote, or null when there is none to read.
pub fn readStamp(dir: *io_mod.VerifiedDir, name: []const u8) ?i64 {
    const io = io_mod.getIo();
    var file = dir.dir.openFile(io, name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch return null;
    defer file.close(io);
    var bytes: [8]u8 = undefined;
    const n = file.readPositionalAll(io, &bytes, 0) catch return null;
    if (n != bytes.len) return null;
    return std.mem.readInt(i64, &bytes, .little);
}

/// Pure: when a waiter that started at `started_ms` times a holder whose
/// stamp reads `stamp_ms` from, at `now_ms`. A stamp from before the waiter
/// started, or from the future (damaged, or from before a reboot), counts as
/// its start.
pub fn stampFrom(stamp_ms: ?i64, started_ms: i64, now_ms: i64) i64 {
    const t = stamp_ms orelse return started_ms;
    return if (t > started_ms and t <= now_ms) t else started_ms;
}

/// Pure: whether a waiter gives up at `now_ms`.
pub fn expired(stamp_ms: ?i64, started_ms: i64, now_ms: i64, wait_ms: i64) bool {
    return now_ms -| stampFrom(stamp_ms, started_ms, now_ms) >= wait_ms;
}

const testing = std.testing;
