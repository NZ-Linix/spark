//! Bounded reads of untrusted metadata files. Only existing regular files are
//! read: a final symlink is not followed, FIFOs and devices are refused
//! without blocking, and content larger than the cap is refused rather than
//! truncated, so a caller never acts on a partial file.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Outcome = union(enum) {
    /// Content owned by the allocator passed to the read.
    content: []u8,
    missing,
    /// Present but unsafe, unreadable, or over the cap. Static string.
    unavailable: []const u8,
};

/// Reads `sub_path` relative to `dir`, accepting at most `max_bytes`.
pub fn readAt(alloc: Allocator, dir: std.Io.Dir, sub_path: []const u8, max_bytes: usize) Allocator.Error!Outcome {
    return readWith(alloc, dir, sub_path, max_bytes, .no_follow);
}

/// Reads an absolute `path`.
pub fn readAbsolute(alloc: Allocator, path: []const u8, max_bytes: usize) Allocator.Error!Outcome {
    if (!std.Io.Dir.path.isAbsolute(path)) return .{ .unavailable = "relative_path" };
    return readAt(alloc, std.Io.Dir.cwd(), path, max_bytes);
}

/// Reads an absolute `path` that the user's own git config or environment
/// names, following a final symlink as git does, since dotfile managers often
/// link these files. The target must still be a regular file within the cap.
/// Paths a repository names use `readAbsolute`.
pub fn readUserAbsolute(alloc: Allocator, path: []const u8, max_bytes: usize) Allocator.Error!Outcome {
    if (!std.Io.Dir.path.isAbsolute(path)) return .{ .unavailable = "relative_path" };
    return readWith(alloc, std.Io.Dir.cwd(), path, max_bytes, .follow);
}

fn readWith(
    alloc: Allocator,
    dir: std.Io.Dir,
    sub_path: []const u8,
    max_bytes: usize,
    final_symlink: io_mod.FinalSymlinkPolicy,
) Allocator.Error!Outcome {
    const file = io_mod.openExistingReadOnlyRegularFile(dir, sub_path, final_symlink) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .missing,
        else => .{ .unavailable = @errorName(err) },
    };
    defer file.close(io_mod.getIo());
    if (try readSized(alloc, file, max_bytes)) |outcome| return outcome;
    // The file holds more than its stat said: it grew, or its file system
    // reports no size, as Linux does for /proc. A positional reader would stop
    // at the stat size, so read it as a stream, which never trusts one.
    var read_buffer: [8192]u8 = undefined;
    var reader = file.readerStreaming(io_mod.getIo(), &read_buffer);
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    // A stream that fills its limit reads as too long, so allow one extra byte
    // to accept a file of exactly `max_bytes`.
    reader.interface.appendRemaining(alloc, &content, .limited(max_bytes +| 1)) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => .{ .unavailable = "too_large" },
        error.ReadFailed => .{ .unavailable = if (reader.err) |read_err| @errorName(read_err) else @errorName(err) },
    };
    return .{ .content = try content.toOwnedSlice(alloc) };
}

/// Reads the whole file into a buffer sized from its stat, so a small file
/// does not claim a stream reader's growth buffer. Returns null when the file
/// holds more than its stat said, which the caller reads as a stream.
fn readSized(alloc: Allocator, file: std.Io.File, max_bytes: usize) Allocator.Error!?Outcome {
    const io = io_mod.getIo();
    const stat = file.stat(io) catch |err| return .{ .unavailable = @errorName(err) };
    if (stat.size > max_bytes) return .{ .unavailable = "too_large" };
    // `stat.size <= max_bytes`, so it fits in a usize.
    const size: usize = @intCast(stat.size);
    // One byte past the size shows whether the file grew since the stat.
    const buffer = try alloc.alloc(u8, size + 1);
    const read = file.readPositionalAll(io, buffer, 0) catch |err| {
        alloc.free(buffer);
        return .{ .unavailable = @errorName(err) };
    };
    if (read > size) {
        alloc.free(buffer);
        return null;
    }
    return .{ .content = try alloc.realloc(buffer, read) };
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
