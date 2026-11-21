//! Pure workspace capture policy. No filesystem, process or session I/O.
const std = @import("std");
const sort_utils = @import("../shared/sort_utils.zig");
const repo_path = @import("../shared/repo_path.zig");

const Allocator = std.mem.Allocator;

pub const Limits = struct {
    untracked_file_bytes: u64 = 2 * 1024 * 1024,
    untracked_count: usize = 1000,
};

pub const Candidate = struct {
    /// One candidate per repository-relative path; the caller collapses index
    /// stages for unmerged paths. Paths are borrowed by the selection.
    path: []const u8,
    tracked: bool,
    present: bool = true,
    skip_worktree: bool = false,
    /// Tracked only: the index holds the path but HEAD's tree does
    /// not, as for a staged new file. The caller sets it only for
    /// sensitive names.
    new_in_index: bool = false,
    /// Untracked only: the file's start holds a PEM private key.
    holds_private_key: bool = false,
    /// lstat size, never the size of a symlink's target.
    bytes: u64 = 0,
    kind: enum { file, symlink, gitlink } = .file,
};

pub const Exclusion = struct {
    path: []const u8,
    reason: enum { sensitive, too_large, file_limit, missing, submodule },
};

pub const Selection = struct {
    /// Paths to refresh from the worktree with Git: file/symlink content or
    /// a gitlink's current HEAD, never a recursive read of its contents. Paths
    /// borrow candidate/previous strings; only the slices are owned.
    read: []const []const u8,
    /// Absent skip-worktree paths whose current index mode/OID must be retained.
    keep_index: []const []const u8,
    remove: []const []const u8,
    excluded: []const Exclusion,

    /// Conservative eligibility, not proof that a later commit will match.
    /// Ignored paths never become candidates, so any exclusion, or differing
    /// conversions, loses it.
    pub fn canCompareTrees(self: Selection, conversions_differ: bool) bool {
        return !conversions_differ and self.excluded.len == 0;
    }

    pub fn deinit(self: Selection, alloc: Allocator) void {
        alloc.free(self.read);
        alloc.free(self.keep_index);
        alloc.free(self.remove);
        alloc.free(self.excluded);
    }
};

pub const SelectError = Allocator.Error || error{ InvalidPath, DuplicatePath };

/// Returns owned slices borrowing input paths. Caller calls deinit.
/// Candidates must include tracked paths absent on disk, not just a listing.
pub fn select(alloc: Allocator, candidates: []const Candidate, previous: []const []const u8, limits: Limits) SelectError!Selection {
    for (candidates) |entry| try validatePath(entry.path);
    for (previous) |path| try validatePath(path);
    const sorted = try alloc.dupe(Candidate, candidates);
    defer alloc.free(sorted);
    sort_utils.sort(Candidate, sorted, {}, candidateLessThan);
    for (sorted, 0..) |entry, i| {
        if (i > 0 and std.mem.eql(u8, sorted[i - 1].path, entry.path)) return error.DuplicatePath;
    }

    var read: std.ArrayList([]const u8) = .empty;
    defer read.deinit(alloc);
    var keep: std.ArrayList([]const u8) = .empty;
    defer keep.deinit(alloc);
    var remove: std.ArrayList([]const u8) = .empty;
    defer remove.deinit(alloc);
    var excluded: std.ArrayList(Exclusion) = .empty;
    defer excluded.deinit(alloc);
    var untracked_count: usize = 0;

    for (sorted) |entry| {
        if (entry.tracked) {
            if (entry.new_in_index and isSensitive(entry.path)) {
                try excluded.append(alloc, .{ .path = entry.path, .reason = .sensitive });
                try remove.append(alloc, entry.path);
                continue;
            }
            if (entry.present) {
                try read.append(alloc, entry.path);
                if (entry.kind == .gitlink) try excluded.append(alloc, .{ .path = entry.path, .reason = .submodule });
            } else if (entry.skip_worktree) {
                try keep.append(alloc, entry.path);
            } else {
                try remove.append(alloc, entry.path);
            }
            continue;
        }
        const reason: ?@FieldType(Exclusion, "reason") = if (!entry.present)
            .missing
        else if (isSensitive(entry.path) or entry.holds_private_key)
            .sensitive
        else if (entry.kind == .gitlink)
            .submodule
        else if (entry.bytes > limits.untracked_file_bytes)
            .too_large
        else if (untracked_count >= limits.untracked_count)
            .file_limit
        else
            null;
        if (reason) |value| {
            try excluded.append(alloc, .{ .path = entry.path, .reason = value });
        } else {
            try read.append(alloc, entry.path);
            untracked_count += 1;
        }
    }
    // read and keep are sorted subsequences of sorted candidates. Previous
    // paths no longer admitted must leave the persistent capture index.
    for (previous) |path| {
        if (!containsPath(read.items, path) and !containsPath(keep.items, path)) try remove.append(alloc, path);
    }
    sort_utils.sort([]const u8, remove.items, {}, pathLessThan);
    var unique: usize = 0;
    for (remove.items) |path| {
        if (unique == 0 or !std.mem.eql(u8, remove.items[unique - 1], path)) {
            remove.items[unique] = path;
            unique += 1;
        }
    }
    remove.shrinkRetainingCapacity(unique);

    const owned_read = try read.toOwnedSlice(alloc);
    errdefer alloc.free(owned_read);
    const owned_keep = try keep.toOwnedSlice(alloc);
    errdefer alloc.free(owned_keep);
    const owned_remove = try remove.toOwnedSlice(alloc);
    errdefer alloc.free(owned_remove);
    return .{ .read = owned_read, .keep_index = owned_keep, .remove = owned_remove, .excluded = try excluded.toOwnedSlice(alloc) };
}

pub const Reason = enum {
    sensitive,
    too_large,
    file_limit,
    submodule,
    /// The untracked listing did not finish before the capture's deadline.
    untracked_timeout,
    timeout,
    not_git,
    git_refused,
    index_sparse,
    capture_locked,
    /// The folder's git directory belongs to another checkout, such as a
    /// `.git` symlink into another repository.
    foreign_git_dir,
    cancelled,
    budget,
    /// The repository's worktree root is the filesystem root, the home
    /// folder, or above it, such as a home kept as a dotfiles repository, so
    /// spark never captures it.
    private_root,
    inconsistent,
    io_error,
    /// The caller passed a malformed session id or repository path.
    invalid_request,
};

fn validatePath(path: []const u8) error{InvalidPath}!void {
    if (!repo_path.isValid(path)) return error.InvalidPath;
}

/// Names that usually hold credentials, compared without case: a disk that
/// ignores case opens `.ENV` as `.env`, and `ID_RSA` is still a key. It also
/// covers key folders, cloud and cluster credentials, Terraform variables and
/// shell histories.
pub fn isSensitive(path: []const u8) bool {
    const slash = std.mem.findScalarLast(u8, path, '/');
    const base = if (slash) |i| path[i + 1 ..] else path;
    // A key folder, cloud config or cluster config above the file.
    var folders = std.mem.splitScalar(u8, if (slash) |i| path[0..i] else "", '/');
    var previous: ?[]const u8 = null;
    while (folders.next()) |folder| {
        if (std.ascii.eqlIgnoreCase(folder, ".ssh") or std.ascii.eqlIgnoreCase(folder, ".gnupg") or std.ascii.eqlIgnoreCase(folder, ".aws")) return true;
        if (previous) |parent| {
            if (std.ascii.eqlIgnoreCase(parent, ".config") and std.ascii.eqlIgnoreCase(folder, "gcloud")) return true;
        }
        previous = folder;
    }
    const names = [_][]const u8{
        ".env",         ".envrc",           ".netrc",       ".npmrc",           ".pgpass",
        ".pypirc",      "auth.json",        "credentials",  ".git-credentials", "hosts.yml",
        ".htpasswd",    "credentials.json", "secrets.yaml", "secrets.yml",      "secrets.json",
        "secrets.toml", "secrets.env",
    };
    for (names) |name| if (std.ascii.eqlIgnoreCase(base, name)) return true;
    for ([_][]const u8{ ".env.", "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa" }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(base, prefix)) return true;
    }
    for ([_][]const u8{ ".pem", ".key", ".p12", ".keystore", ".jks", ".tfvars", ".tfvars.json" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(base, suffix)) return true;
    }
    // Shells and tools keep command histories in dot files ending `_history`.
    if (std.ascii.startsWithIgnoreCase(base, ".") and std.ascii.endsWithIgnoreCase(base, "_history")) return true;
    // A service account key is a JSON file whose name says what it is.
    if (std.ascii.startsWithIgnoreCase(base, "service-account") and std.ascii.endsWithIgnoreCase(base, ".json")) return true;
    // Docker keeps registry logins in `~/.docker/config.json`; any other
    // `config.json` is ordinary.
    if (std.ascii.eqlIgnoreCase(base, "config.json")) {
        const parent_path = path[0 .. slash orelse return false];
        const parent = if (std.mem.findScalarLast(u8, parent_path, '/')) |i| parent_path[i + 1 ..] else parent_path;
        return std.ascii.eqlIgnoreCase(parent, ".docker");
    }
    // kubectl keeps cluster credentials in `~/.kube/config`; any other
    // `config` file is ordinary.
    if (std.ascii.eqlIgnoreCase(base, "config")) {
        const parent_path = path[0 .. slash orelse return false];
        const parent = if (std.mem.findScalarLast(u8, parent_path, '/')) |i| parent_path[i + 1 ..] else parent_path;
        return std.ascii.eqlIgnoreCase(parent, ".kube");
    }
    return false;
}

fn candidateLessThan(_: void, a: Candidate, b: Candidate) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn pathLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn containsPath(paths: []const []const u8, path: []const u8) bool {
    var low: usize = 0;
    var high = paths.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, paths[mid], path)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return true,
        }
    }
    return false;
}

fn expectPaths(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |a, b| try std.testing.expectEqualStrings(a, b);
}

test "capture selection includes tracked ignored and staged-new files without applying untracked limits" {
    const alloc = std.testing.allocator;
    const entries = [_]Candidate{
        .{ .path = "keep.log", .tracked = true, .bytes = 99_000_000 },
        .{ .path = ".env", .tracked = true },
        .{ .path = "new-staged.txt", .tracked = true },
    };
    const result = try select(alloc, &entries, &.{}, .{ .untracked_count = 0 });
    defer result.deinit(alloc);
    try expectPaths(&.{ ".env", "keep.log", "new-staged.txt" }, result.read);
    try std.testing.expectEqual(@as(usize, 0), result.excluded.len);
}

fn selectionAllocationCase(alloc: Allocator) !void {
    const result = try select(alloc, &.{
        .{ .path = "sparse", .tracked = true, .present = false, .skip_worktree = true },
        .{ .path = "read", .tracked = true },
        .{ .path = ".env", .tracked = false },
        .{ .path = "new", .tracked = false },
    }, &.{ "removed", "removed", ".env" }, .{});
    defer result.deinit(alloc);
    try expectPaths(&.{ "new", "read" }, result.read);
    try expectPaths(&.{"sparse"}, result.keep_index);
    try expectPaths(&.{ ".env", "removed" }, result.remove);
}
