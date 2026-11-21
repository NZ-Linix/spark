const std = @import("std");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const repo_root = @import("repo_root.zig");

const max_branch_bytes: usize = 255;
const max_metadata_bytes = repo_root.max_metadata_bytes;

/// Returns an allocator-owned branch name when `cwd` is inside a Git worktree.
/// Missing, detached, malformed, or unreadable metadata is absent.
pub fn read(
    alloc: std.mem.Allocator,
    cwd: []const u8,
) error{OutOfMemory}!?[]u8 {
    if (!std.Io.Dir.path.isAbsolute(cwd)) return null;
    const git_dir = try resolveGitDir(alloc, cwd);
    defer if (git_dir) |path| alloc.free(path);
    const path = git_dir orelse return null;

    var dir = io_mod.openDirAbsoluteNoFollow(path, .{}) catch return null;
    defer dir.close(io_mod.getIo());
    var head_file = io_mod.openExistingReadOnlyRegularFile(
        dir,
        "HEAD",
        .no_follow,
    ) catch return null;
    defer head_file.close(io_mod.getIo());
    const stat = head_file.stat(io_mod.getIo()) catch return null;
    if (stat.size > max_metadata_bytes) return null;
    const head = io_mod.readFileToEnd(
        alloc,
        &head_file,
        max_metadata_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer alloc.free(head);
    const branch = parseHead(head) orelse return null;
    return try alloc.dupe(u8, branch);
}

fn parseHead(head: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, head, " \t\r\n");
    const prefix = "ref: refs/heads/";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const branch = trimmed[prefix.len..];
    if (branch.len == 0 or branch.len > max_branch_bytes or
        !text_utils.isTerminalSafe(branch))
    {
        return null;
    }
    return branch;
}

/// The git directory of the worktree holding `cwd`, which must open as a
/// directory without following a symlink (`repo_root.zig`).
fn resolveGitDir(
    alloc: std.mem.Allocator,
    cwd: []const u8,
) error{OutOfMemory}!?[]u8 {
    const found = try repo_root.find(alloc, cwd) orelse return null;
    var dir = io_mod.openDirAbsoluteNoFollow(found.git_dir, .{}) catch {
        alloc.free(found.git_dir);
        return null;
    };
    dir.close(io_mod.getIo());
    return found.git_dir;
}

fn writeTestFile(
    dir: std.Io.Dir,
    path: []const u8,
    content: []const u8,
) !void {
    if (std.Io.Dir.path.dirname(path)) |parent| {
        try dir.createDirPath(std.testing.io, parent);
    }
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, content);
}
