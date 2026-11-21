//! Locates the git repository that contains a workspace root the way git's
//! discovery does, reading only data: `.git` directories, `.git` files with a
//! `gitdir:` pointer (linked worktrees and submodules), and `commondir`.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const bounded_read = @import("bounded_read.zig");

const Allocator = std.mem.Allocator;

const max_metadata_bytes: usize = 4096;

pub const Layout = struct {
    /// Absolute directory holding `.git`; repository paths are relative to it.
    worktree_root: []const u8,
    /// Absolute per-worktree git directory, holding `HEAD` and `index`.
    git_dir: []const u8,
    /// Absolute shared git directory, holding `config` and `info/exclude`.
    common_dir: []const u8,
    /// Workspace root relative to `worktree_root`: empty, or `a/b` without
    /// a leading or trailing slash.
    prefix: []const u8,
};

pub const DiscoverError = error{ OutOfMemory, InvalidGitFile };

/// Returns the innermost repository containing the absolute directory
/// `start`, or null when there is none. All memory belongs to `arena`. As in
/// git, a `.git` file that is not a valid `gitdir:` pointer is an error, and a
/// `.git` directory that is not a git directory is skipped.
pub fn discover(arena: Allocator, start: []const u8) DiscoverError!?Layout {
    std.debug.assert(std.Io.Dir.path.isAbsolute(start));
    const normalized = try std.Io.Dir.path.resolveAlloc(arena, &.{start});
    var candidate: []const u8 = normalized;
    while (true) {
        if (try layoutAt(arena, candidate)) |found| {
            const prefix = if (found.worktree_root.len == normalized.len)
                ""
            else if (std.mem.eql(u8, found.worktree_root, "/"))
                normalized[1..]
            else
                normalized[found.worktree_root.len + 1 ..];
            return .{
                .worktree_root = found.worktree_root,
                .git_dir = found.git_dir,
                .common_dir = found.common_dir,
                .prefix = prefix,
            };
        }
        const parent = std.Io.Dir.path.dirname(candidate) orelse return null;
        if (std.mem.eql(u8, parent, candidate)) return null;
        candidate = parent;
    }
}

/// Whether the absolute directory `dir` holds a repository of its own, as
/// git's is_nonbare_repository_dir decides: a `.git` git directory or a valid
/// `gitdir:` file. An invalid `.git` file does not count.
pub fn hasOwnRepository(arena: Allocator, dir: []const u8) Allocator.Error!bool {
    const found = layoutAt(arena, dir) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidGitFile => return false,
    };
    return found != null;
}

fn layoutAt(arena: Allocator, dir: []const u8) DiscoverError!?Layout {
    const dot_git = try std.Io.Dir.path.join(arena, &.{ dir, ".git" });
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), dot_git, .{ .follow_symlinks = true }) catch return null;
    switch (stat.kind) {
        .directory => {
            const dirs = try gitDirs(arena, dot_git) orelse return null;
            return .{ .worktree_root = dir, .git_dir = dirs.git_dir, .common_dir = dirs.common_dir, .prefix = "" };
        },
        .file => {
            const target = try readGitFile(arena, dir, dot_git) orelse return error.InvalidGitFile;
            const dirs = try gitDirs(arena, target) orelse return error.InvalidGitFile;
            return .{ .worktree_root = dir, .git_dir = dirs.git_dir, .common_dir = dirs.common_dir, .prefix = "" };
        },
        else => return null,
    }
}

/// git's read_gitfile: `gitdir: <path>`, relative to the `.git` file's
/// directory.
fn readGitFile(arena: Allocator, dir: []const u8, dot_git: []const u8) Allocator.Error!?[]const u8 {
    const content = switch (try bounded_read.readAbsolute(arena, dot_git, max_metadata_bytes)) {
        .content => |bytes| bytes,
        .missing, .unavailable => return null,
    };
    const prefix = "gitdir: ";
    if (!std.mem.startsWith(u8, content, prefix)) return null;
    const raw = std.mem.trimEnd(u8, content[prefix.len..], " \t\r\n");
    if (raw.len == 0) return null;
    return try std.Io.Dir.path.resolveAlloc(arena, &.{ dir, raw });
}

const GitDirs = struct { git_dir: []const u8, common_dir: []const u8 };

/// git's is_git_directory: a valid `HEAD` in the git directory, and `objects`
/// and `refs` directories in the common directory, which `commondir` may
/// relocate. Discovery must accept exactly the directories git accepts, or git
/// would walk past one spark stopped at and use another repository's config. A
/// symlinked `HEAD`, which git accepts when it points into `refs/`, is
/// rejected here; safe git then refuses because git and spark disagree.
fn gitDirs(arena: Allocator, git_dir: []const u8) Allocator.Error!?GitDirs {
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), git_dir, .{}) catch return null;
    defer dir.close(io_mod.getIo());
    const head = switch (try bounded_read.readAt(arena, dir, "HEAD", max_metadata_bytes)) {
        .content => |bytes| bytes,
        .missing, .unavailable => return null,
    };
    if (!validHead(head[0..@min(head.len, max_head_bytes)])) return null;
    const common_dir = switch (try bounded_read.readAt(arena, dir, "commondir", max_metadata_bytes)) {
        .content => |bytes| blk: {
            const raw = std.mem.trimEnd(u8, bytes, " \t\r\n");
            if (raw.len == 0) return null;
            break :blk try std.Io.Dir.path.resolveAlloc(arena, &.{ git_dir, raw });
        },
        .missing => git_dir,
        .unavailable => return null,
    };
    for ([_][]const u8{ "objects", "refs" }) |name| {
        const path = try std.Io.Dir.path.join(arena, &.{ common_dir, name });
        const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{ .follow_symlinks = true }) catch return null;
        if (stat.kind != .directory) return null;
    }
    return .{ .git_dir = git_dir, .common_dir = common_dir };
}

/// git reads at most 255 bytes of `HEAD` when validating it.
const max_head_bytes: usize = 255;

/// git's validate_headref for a regular file: a symbolic ref into `refs/`,
/// or a detached object id in either hash format.
fn validHead(content: []const u8) bool {
    if (content.len < 4) return false;
    if (std.mem.startsWith(u8, content, "ref:")) {
        const target = std.mem.trimStart(u8, content["ref:".len..], " \t\r\n\x0b\x0c");
        if (std.mem.startsWith(u8, target, "refs/")) return true;
    }
    return hexPrefix(content, 40) or hexPrefix(content, 64);
}

fn hexPrefix(content: []const u8, len: usize) bool {
    if (content.len < len) return false;
    for (content[0..len]) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

/// Returns the branch `HEAD` points at (`refs/heads/<name>`), or null when
/// detached or unreadable. Memory belongs to `arena`.
pub fn currentBranch(arena: Allocator, layout: Layout) Allocator.Error!?[]const u8 {
    const head_path = try std.Io.Dir.path.join(arena, &.{ layout.git_dir, "HEAD" });
    const content = switch (try bounded_read.readAbsolute(arena, head_path, max_metadata_bytes)) {
        .content => |bytes| bytes,
        .missing, .unavailable => return null,
    };
    const prefix = "ref: refs/heads/";
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, prefix) or trimmed.len == prefix.len) return null;
    return trimmed[prefix.len..];
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.Io.Dir.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = content });
}

fn makeTestRepo(dir: std.Io.Dir, git_dir: []const u8) !void {
    const head = try std.Io.Dir.path.join(std.testing.allocator, &.{ git_dir, "HEAD" });
    defer std.testing.allocator.free(head);
    try writeTestFile(dir, head, "ref: refs/heads/main\n");
    for ([_][]const u8{ "objects", "refs" }) |name| {
        const path = try std.Io.Dir.path.join(std.testing.allocator, &.{ git_dir, name });
        defer std.testing.allocator.free(path);
        try dir.createDirPath(std.testing.io, path);
    }
}
