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

const active = builtin.target.cpu.arch == .x86 and builtin.target.os.tag == .linux and builtin.link_libc;

comptime {
    if (active) {
        @export(&preadv, .{ .name = "preadv" });
        @export(&pwritev, .{ .name = "pwritev" });
        @export(&clockNanosleep, .{ .name = "clock_nanosleep" });
        @export(&fchmodat, .{ .name = "fchmodat" });
    }
}

const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

var metadata_available: ?bool = null;
var compatible_vtable: Io.VTable = undefined;
var metadata_inner: ?*const Io.VTable = null;

/// The App Store build of iSH returns ENOSYS from statx. Probe with an
/// invalid descriptor so the check never touches the filesystem.
pub fn wrapIo(inner: Io) Io {
    if (comptime !active) return inner;
    if (metadata_available == null) {
        var result: linux.Statx = undefined;
        metadata_available = linux.errno(linux.statx(-1, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &result)) != .NOSYS;
    }
    return compatibleIo(inner, !metadata_available.?);
}

fn compatibleIo(inner: Io, use_legacy_metadata: bool) Io {
    if (metadata_inner) |vtable| {
        std.debug.assert(vtable == inner.vtable);
    } else {
        compatible_vtable = inner.vtable.*;
        compatible_vtable.dirDeleteFile = dirDeleteFile;
        if (use_legacy_metadata) {
            compatible_vtable.fileStat = fileStat;
            compatible_vtable.fileLength = fileLength;
            compatible_vtable.dirStat = dirStat;
            compatible_vtable.dirStatFile = dirStatFile;
        }
        metadata_inner = inner.vtable;
    }
    return .{ .userdata = inner.userdata, .vtable = &compatible_vtable };
}

/// Linux i386's stat64 syscall layout. The kernel aligns the 64-bit fields
/// to four-byte boundaries and writes 96 bytes.
const Stat64 = extern struct {
    device: u64 align(4),
    device_padding: u32,
    truncated_inode: u32,
    mode: u32,
    nlink: u32,
    uid: u32,
    gid: u32,
    rdev: u64 align(4),
    rdev_padding: u32,
    size: i64 align(4),
    block_size: u32,
    blocks: u64 align(4),
    atime_sec: i32,
    atime_nsec: u32,
    mtime_sec: i32,
    mtime_nsec: u32,
    ctime_sec: i32,
    ctime_nsec: u32,
    inode: u64 align(4),

    fn toFileStat(s: Stat64) File.Stat {
        return .{
            .inode = s.inode,
            .nlink = s.nlink,
            .size = @intCast(@max(0, s.size)),
            .permissions = .fromMode(s.mode),
            .kind = Io.Threaded.statxKind(@truncate(s.mode)),
            .atime = .{ .nanoseconds = timestamp(s.atime_sec, s.atime_nsec) },
            .mtime = .{ .nanoseconds = timestamp(s.mtime_sec, s.mtime_nsec) },
            .ctime = .{ .nanoseconds = timestamp(s.ctime_sec, s.ctime_nsec) },
            .block_size = s.block_size,
        };
    }
};

fn timestamp(sec: i32, nsec: u32) i96 {
    return @as(i96, sec) * std.time.ns_per_s + nsec;
}

fn fileStat(userdata: ?*anyopaque, file: File) File.StatError!File.Stat {
    const io: Io = .{ .userdata = userdata, .vtable = metadata_inner.? };
    var result: Stat64 = undefined;
    while (true) {
        try io.checkCancel();
        switch (linux.errno(linux.syscall2(.fstat64, @bitCast(file.handle), @intFromPtr(&result)))) {
            .SUCCESS => return result.toFileStat(),
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .NOMEM => return error.SystemResources,
            .PERM => return error.PermissionDenied,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn fileLength(userdata: ?*anyopaque, file: File) File.LengthError!u64 {
    return (try fileStat(userdata, file)).size;
}

fn dirStat(userdata: ?*anyopaque, dir: Dir) Dir.StatError!Dir.Stat {
    return fileStat(userdata, .{ .handle = dir.handle, .flags = .{ .nonblocking = false } });
}

fn dirStatFile(userdata: ?*anyopaque, dir: Dir, path: []const u8, options: Dir.StatFileOptions) Dir.StatFileError!File.Stat {
    if (std.mem.findScalar(u8, path, 0) != null) return error.BadPathName;
    const path_z = try std.posix.toPosixPath(path);
    const flags: u32 = if (options.follow_symlinks) 0 else linux.AT.SYMLINK_NOFOLLOW;
    const io: Io = .{ .userdata = userdata, .vtable = metadata_inner.? };
    var result: Stat64 = undefined;
    while (true) {
        try io.checkCancel();
        switch (linux.errno(linux.syscall4(.fstatat64, @bitCast(dir.handle), @intFromPtr(&path_z), @intFromPtr(&result), flags))) {
            .SUCCESS => return result.toFileStat(),
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NOMEM => return error.SystemResources,
            .PERM => return error.PermissionDenied,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

/// iSH returns EPERM when unlinking a directory. Zig's deleteTree first
/// tries unlink and only descends after IsDir. Distinguish a directory
/// from a genuine permission failure without following the final symlink.
fn dirDeleteFile(userdata: ?*anyopaque, dir: Dir, path: []const u8) Dir.DeleteFileError!void {
    return metadata_inner.?.dirDeleteFile(userdata, dir, path) catch |err| {
        if (err != error.PermissionDenied) return err;
        const stat = compatible_vtable.dirStatFile(userdata, dir, path, .{ .follow_symlinks = false }) catch |stat_err| {
            if (stat_err == error.Canceled) return error.Canceled;
            return err;
        };
        return if (stat.kind == .directory) error.IsDir else err;
    };
}

test "legacy i386 metadata and deletion preserve no-follow semantics" {
    if (!active) return error.SkipZigTest;
    comptime {
        std.debug.assert(@sizeOf(Stat64) == 96);
        std.debug.assert(@offsetOf(Stat64, "size") == 44);
        std.debug.assert(@offsetOf(Stat64, "inode") == 88);
    }
    const io = compatibleIo(std.testing.io, true);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "history.jsonl", .data = "saved\n" });
    try tmp.dir.symLink(io, "history.jsonl", "history-link", .{});
    var file = try tmp.dir.openFile(io, "history.jsonl", .{ .mode = .read_write });
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0o600));
    const stat = try file.stat(io);
    try std.testing.expectEqual(@as(u64, 6), stat.size);
    try std.testing.expectEqual(@as(u64, 6), try file.length(io));
    try std.testing.expectEqual(@as(u64, 1), stat.nlink);
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(File.Kind.directory, (try tmp.dir.stat(io)).kind);
    try std.testing.expectEqual(File.Kind.file, (try tmp.dir.statFile(io, "history-link", .{})).kind);
    try std.testing.expectEqual(File.Kind.sym_link, (try tmp.dir.statFile(io, "history-link", .{ .follow_symlinks = false })).kind);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "missing", .{}));
    try tmp.dir.createDir(io, "profile", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "profile/history.jsonl", .data = "saved\n" });
    try tmp.dir.symLink(io, "../history.jsonl", "profile/outside", .{});
    try tmp.dir.deleteTree(io, "profile");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "profile", .{}));
    try std.testing.expectEqual(File.Kind.file, (try tmp.dir.statFile(io, "history.jsonl", .{})).kind);
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
