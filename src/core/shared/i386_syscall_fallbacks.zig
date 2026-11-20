//! libc functions for 32-bit x86 Linux that avoid system calls the iSH app
//! lacks. iSH emulates i386 Linux on iPhone and iPad, and its App Store
//! build kills a program with SIGSYS ("Bad system call") when it makes a
//! call iSH does not implement, so musl's fallbacks after ENOSYS never run.
//! spark's static musl build reaches four such calls through std.Io:
//! `preadv` and `pwritev` for positional file I/O, `clock_nanosleep` (and
//! its time64 form) for sleeping, and `fchmodat2` for `fchmodat` with flags.
//! The versions here use `pread`, `pwrite`, `nanosleep`, and `fchmodat`
//! instead, which every Linux, iSH included, has.
//! A strong definition here wins over musl's, so std.Io calls these.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const active = builtin.cpu.arch == .x86 and builtin.os.tag == .linux and builtin.link_libc;

comptime {
    if (active) {
        @export(&preadv, .{ .name = "preadv" });
        @export(&pwritev, .{ .name = "pwritev" });
        @export(&clockNanosleep, .{ .name = "clock_nanosleep" });
        @export(&fchmodat, .{ .name = "fchmodat" });
    }
}

/// Reads each buffer in turn and stops at the first short read, as one
/// `preadv` would. An error after some bytes were read returns those bytes.
fn preadv(fd: c_int, iov: [*]const std.c.iovec, iovcnt: c_uint, offset: std.c.off_t) callconv(.c) isize {
    var total: usize = 0;
    for (iov[0..iovcnt]) |vec| {
        if (vec.len == 0) continue;
        const rc = std.c.pread(fd, vec.base, vec.len, offset + @as(std.c.off_t, @intCast(total)));
        if (rc < 0) return if (total == 0) rc else @intCast(total);
        const got: usize = @intCast(rc);
        total += got;
        if (got < vec.len) break;
    }
    return @intCast(total);
}

/// Writes each buffer in turn and stops at the first short write, as one
/// `pwritev` would. An error after some bytes were written returns those.
fn pwritev(fd: c_int, iov: [*]const std.c.iovec_const, iovcnt: c_uint, offset: std.c.off_t) callconv(.c) isize {
    var total: usize = 0;
    for (iov[0..iovcnt]) |vec| {
        if (vec.len == 0) continue;
        const rc = std.c.pwrite(fd, vec.base, vec.len, offset + @as(std.c.off_t, @intCast(total)));
        if (rc < 0) return if (total == 0) rc else @intCast(total);
        const put: usize = @intCast(rc);
        total += put;
        if (put < vec.len) break;
    }
    return @intCast(total);
}

/// The i386 `nanosleep` call takes 32-bit seconds.
const Timespec32 = extern struct { sec: i32, nsec: i32 };

/// Returns 0 or a positive errno, as POSIX `clock_nanosleep` does. A
/// relative sleep uses `nanosleep`, whose clock (realtime) differs from a
/// monotonic one only when the wall clock jumps mid-sleep. An absolute
/// deadline sleeps for its distance from `clk`'s current time; a caller
/// that is woken early by a clock change sees success and checks again.
fn clockNanosleep(clk: std.c.clockid_t, flags: c_int, req: *const std.c.timespec, rem: ?*std.c.timespec) callconv(.c) c_int {
    var sec: i64 = req.sec;
    var nsec: i64 = req.nsec;
    const abstime = flags & 1 != 0; // TIMER_ABSTIME
    if (abstime) {
        var now: std.c.timespec = undefined;
        if (std.c.clock_gettime(clk, &now) != 0) return @backingInt(std.c.E.INVAL);
        sec -= now.sec;
        nsec -= now.nsec;
        if (nsec < 0) {
            nsec += std.time.ns_per_s;
            sec -= 1;
        }
        if (sec < 0) return 0;
    }
    var ts: Timespec32 = .{
        .sec = std.math.cast(i32, sec) orelse std.math.maxInt(i32),
        .nsec = @intCast(nsec),
    };
    const rc = linux.syscall2(.nanosleep, @intFromPtr(&ts), @intFromPtr(&ts));
    const err = linux.errno(rc);
    if (err == .INTR and !abstime) {
        if (rem) |r| r.* = .{ .sec = ts.sec, .nsec = ts.nsec };
    }
    return @intCast(@backingInt(err));
}

/// `fchmodat` without `fchmodat2`. The only flag is AT_SYMLINK_NOFOLLOW,
/// and Linux cannot change a symlink's own mode, so a symlink fails with
/// EOPNOTSUPP as in musl, and anything else changes through the plain call.
/// Unlike musl's fallback, which pins the file through an O_PATH descriptor,
/// a symlink swapped in between the check and the change is followed: iSH
/// may lack O_PATH, and spark only changes modes of files it just wrote.
fn fchmodat(fd: c_int, path: [*:0]const u8, mode: std.c.mode_t, flags: c_int) callconv(.c) c_int {
    if (flags != 0) {
        if (flags != linux.AT.SYMLINK_NOFOLLOW) return fail(.INVAL);
        var st: linux.Statx = undefined;
        const found = linux.errno(linux.statx(fd, path, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st));
        if (found != .SUCCESS) return fail(found);
        if (st.mode & linux.S.IFMT == linux.S.IFLNK) return fail(.OPNOTSUPP);
    }
    const rc = linux.syscall3(.fchmodat, @bitCast(@as(isize, fd)), @intFromPtr(path), mode);
    const err = linux.errno(rc);
    return if (err == .SUCCESS) 0 else fail(err);
}

fn fail(err: std.c.E) c_int {
    std.c._errno().* = @backingInt(err);
    return -1;
}

test "positional reads and writes match one preadv or pwritev" {
    if (!active) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "data", .{ .read = true });
    defer file.close(io);
    const parts = [_]std.c.iovec_const{
        .{ .base = "hello ", .len = 6 },
        .{ .base = "", .len = 0 },
        .{ .base = "world", .len = 5 },
    };
    try std.testing.expectEqual(@as(isize, 11), pwritev(file.handle, &parts, parts.len, 3));
    var a: [4]u8 = undefined;
    var b: [20]u8 = undefined;
    const into = [_]std.c.iovec{ .{ .base = &a, .len = a.len }, .{ .base = &b, .len = b.len } };
    try std.testing.expectEqual(@as(isize, 10), preadv(file.handle, &into, into.len, 4));
    try std.testing.expectEqualStrings("ello", &a);
    try std.testing.expectEqualStrings(" world", b[0..6]);
    const closed = [_]std.c.iovec{.{ .base = &a, .len = a.len }};
    try std.testing.expectEqual(@as(isize, -1), preadv(-1, &closed, closed.len, 0));
}

test "clock_nanosleep sleeps for a duration and until a deadline" {
    if (!active) return error.SkipZigTest;
    var before: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &before);
    try std.testing.expectEqual(@as(c_int, 0), clockNanosleep(.MONOTONIC, 0, &.{ .sec = 0, .nsec = 20 * std.time.ns_per_ms }, null));
    var deadline = before;
    deadline.nsec += 60 * std.time.ns_per_ms;
    if (deadline.nsec >= std.time.ns_per_s) {
        deadline.nsec -= std.time.ns_per_s;
        deadline.sec += 1;
    }
    try std.testing.expectEqual(@as(c_int, 0), clockNanosleep(.MONOTONIC, 1, &deadline, null));
    var after: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &after);
    const elapsed_ns = (after.sec - before.sec) * std.time.ns_per_s + (after.nsec - before.nsec);
    try std.testing.expect(elapsed_ns >= 60 * std.time.ns_per_ms);
    // A deadline already past returns at once.
    try std.testing.expectEqual(@as(c_int, 0), clockNanosleep(.MONOTONIC, 1, &before, null));
}

test "fchmodat changes a file's mode and refuses a symlink with NOFOLLOW" {
    if (!active) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "script", .{});
    file.close(io);
    try tmp.dir.symLink(io, "script", "link", .{});
    const dir_fd = tmp.dir.handle;
    try std.testing.expectEqual(@as(c_int, 0), fchmodat(dir_fd, "script", 0o700, linux.AT.SYMLINK_NOFOLLOW));
    var st: linux.Statx = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.statx(dir_fd, "script", 0, .{ .MODE = true }, &st));
    try std.testing.expectEqual(@as(u16, 0o700), st.mode & 0o777);
    try std.testing.expectEqual(@as(c_int, 0), fchmodat(dir_fd, "script", 0o600, 0));
    try std.testing.expectEqual(@as(c_int, -1), fchmodat(dir_fd, "link", 0o700, linux.AT.SYMLINK_NOFOLLOW));
    try std.testing.expectEqual(@backingInt(std.c.E.OPNOTSUPP), std.c._errno().*);
    try std.testing.expectEqual(@as(c_int, -1), fchmodat(dir_fd, "script", 0o700, 0x100000));
    try std.testing.expectEqual(@backingInt(std.c.E.INVAL), std.c._errno().*);
}
