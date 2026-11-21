const std = @import("std");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const debug_trace = @import("../shared/debug_trace.zig");

pub fn profileFile(
    file_name: []const u8,
    max_bytes: usize,
) host.SecretStorePresence {
    if (comptime host_target.is_wasm) return .missing;
    return profileFileFromHome(io_mod.homeDir(), file_name, max_bytes);
}

/// Returns whether the credential file exists after checking both write targets.
pub fn requireWritableProfileFile(file_name: []const u8, lock_name: []const u8) error{CredentialStorageUnavailable}!bool {
    if (comptime host_target.is_wasm) return false;
    const home = io_mod.homeDir() orelse return error.CredentialStorageUnavailable;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(home), .{ .iterate = true }) catch return error.CredentialStorageUnavailable;
    defer home_dir.close(io_mod.getIo());
    var profile_dir = home_dir.openDir(io_mod.getIo(), profile_paths.rootName(), .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| {
        if (err != error.FileNotFound) return error.CredentialStorageUnavailable;
        const stat = home_dir.stat(io_mod.getIo()) catch return error.CredentialStorageUnavailable;
        if (stat.permissions.toMode() & 0o200 == 0) return error.CredentialStorageUnavailable;
        return false;
    };
    defer profile_dir.close(io_mod.getIo());
    const exists = try requireWritableInDir(profile_dir, file_name);
    _ = try requireWritableInDir(profile_dir, lock_name);
    return exists;
}

/// Storage-origin errors must not be interpreted as OAuth AccessDenied.
pub fn storageError(file_name: []const u8, err: anyerror) error{ OutOfMemory, Cancelled, LockBusy, CredentialStorageUnavailable } {
    debug_trace.logf("auth", "credential storage operation failed file={s} err={s}", .{ file_name, @errorName(err) });
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.LockBusy => error.LockBusy,
        else => error.CredentialStorageUnavailable,
    };
}

/// Borrows the verified store directory; checks metadata without changing it.
pub fn requireWritableInDir(dir: std.Io.Dir, file_name: []const u8) error{CredentialStorageUnavailable}!bool {
    const dir_stat = dir.stat(io_mod.getIo()) catch return error.CredentialStorageUnavailable;
    if (dir_stat.permissions.toMode() & 0o200 == 0) return error.CredentialStorageUnavailable;
    const stat = dir.statFile(io_mod.getIo(), file_name, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.FileNotFound) return false;
        return error.CredentialStorageUnavailable;
    };
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o777 != 0o600) {
        return error.CredentialStorageUnavailable;
    }
    return true;
}

/// A login file as it is at its name now, with its metadata.
pub const CurrentFile = struct {
    file: std.Io.File,
    stat: std.Io.File.Stat,
};

const max_opens = 3;

/// Opens login file `name` in `dir` for reading, without following a link or
/// waiting for a writer when it's a fifo. Null when there's none. Another spark
/// that saves the login replaces the file, and one that signs out deletes it,
/// so a file opened just before has no links left; the name then holds the
/// new file, or none, and is opened again. The caller closes the file.
pub fn openCurrent(dir: std.Io.Dir, name: []const u8) !?CurrentFile {
    return openCurrentWith(dir, name, null);
}

/// `openCurrent`, with `between` run after each open and before its check,
/// as another spark's save or logout can.
fn openCurrentWith(dir: std.Io.Dir, name: []const u8, between: ?*const fn (std.Io.Dir, []const u8) void) !?CurrentFile {
    for (0..max_opens) |_| {
        var file = io_mod.openExistingReadOnlyRegularFile(dir, name, .no_follow) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        if (between) |run| run(dir, name);
        const stat = file.stat(io_mod.getIo()) catch |err| {
            file.close(io_mod.getIo());
            return err;
        };
        if (stat.nlink != 0) return .{ .file = file, .stat = stat };
        file.close(io_mod.getIo());
        debug_trace.logf("auth", "login file replaced or deleted after it was opened name={s}; opening it again", .{name});
    }
    return error.LoginFileKeptChanging;
}

fn profileFileFromHome(
    home_value: ?[]const u8,
    file_name: []const u8,
    max_bytes: usize,
) host.SecretStorePresence {
    const home = home_value orelse return .unavailable;
    var home_dir = std.Io.Dir.openDirAbsolute(
        io_mod.getIo(),
        profile_paths.rootParent(home),
        .{ .iterate = true },
    ) catch |err| return if (err == error.FileNotFound) .missing else .unavailable;
    defer home_dir.close(io_mod.getIo());

    var profile_dir = home_dir.openDir(
        io_mod.getIo(),
        profile_paths.rootName(),
        .{ .iterate = true, .follow_symlinks = false },
    ) catch |err| return if (err == error.FileNotFound) .missing else .unavailable;
    defer profile_dir.close(io_mod.getIo());

    var current = (openCurrent(profile_dir, file_name) catch return .unavailable) orelse return .missing;
    defer current.file.close(io_mod.getIo());

    const stat = current.stat;
    if (stat.kind != .file or
        stat.nlink != 1 or
        stat.permissions.toMode() & 0o077 != 0 or
        stat.size == 0 or
        stat.size > max_bytes)
    {
        return .unavailable;
    }
    return .present;
}

test "a login file another spark replaces after this one opened it is opened again" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "auth.json", .data = "old", .flags = .{ .permissions = .fromMode(0o600) } });
    // Another spark saves a new login over it, by rename, once.
    const Save = struct {
        var done = false;
        var failed: ?anyerror = null;
        fn run(dir: std.Io.Dir, name: []const u8) void {
            if (done) return;
            done = true;
            dir.writeFile(std.testing.io, .{ .sub_path = "auth.json.new", .data = "new", .flags = .{ .permissions = .fromMode(0o600) } }) catch |err| {
                failed = err;
                return;
            };
            dir.rename("auth.json.new", dir, name, std.testing.io) catch |err| {
                failed = err;
            };
        }
    };

    var current = (try openCurrentWith(tmp.dir, "auth.json", Save.run)).?;
    defer current.file.close(std.testing.io);
    try std.testing.expectEqual(@as(?anyerror, null), Save.failed);
    try std.testing.expect(Save.done);
    const bytes = try io_mod.readFileToEnd(std.testing.allocator, &current.file, 64);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("new", bytes);
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
