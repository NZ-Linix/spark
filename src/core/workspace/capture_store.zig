//! One workspace capture of a git repository into spark's own store.
//!
//! Each repository gets a bare store under the profile, keyed by its common
//! git directory, with alternates into the user's objects, so hashing a file
//! the user's git already holds writes nothing. The store still holds its
//! own compressed copy of every object its captures reach (see below), so it
//! grows to about the size of the worktree's tree, packed, plus what changed
//! since. Each worktree, named by its git directory and its work tree
//! (`worktreeIdentity`), gets its own capture index, lock and scratch
//! directory. A capture lists the worktree, applies `workspace_capture`'s
//! policy, writes a tree, and appends a commit to the ref for the session and
//! worktree, `refs/spark/sessions/<session key>/<worktree key>`, with
//! compare-and-swap, and `encodeRecord` turns the outcome into the session's
//! `workspace_capture` item (D98). git reads the user's repository through
//! `safe_git`'s read-only route, and the store reads the user's objects
//! through its alternates. spark itself reads the index file to copy it and
//! checks a few files in the git directory, and opens only regular files of
//! bounded size, so a pipe or device there cannot stall it. The one write
//! that reaches the user's repository is git's own freshening: when the store
//! hashes a file whose object the user's objects folder already holds, git
//! updates the modification time of that loose object or of the pack holding
//! it instead of writing a copy. It never changes their content, and git
//! offers no setting to turn it off.
//!
//! A capture never depends on the user's objects. Its tree can name objects
//! only the user's repository holds, such as a staged blob or a file of a
//! branch the user may delete and prune. Before the ref moves, the capture
//! copies into the store every object its tree reaches that the parent
//! capture's tree does not (`copyObjects`), so every commit a capture ref
//! names is readable with the alternates gone. A capture with no parent
//! leaves out what the store's newest captures hold instead, so until the
//! store holds a capture, a copy takes the whole tree. The copy writes packs
//! of at most `copy_batch_objects` objects and skips what the store already
//! holds itself, loose or in its own packs, so the packs an interrupted copy
//! finished are kept and the next capture goes on from there. A copy that
//! cannot finish leaves the ref where it was and the capture reports no
//! tree: `timeout` at the deadline, `io_error` for another failure.
//! Objects the store wrote itself stay loose and are not copied again.
//! Retention keeps both: its `gc` and `repack` store commands repack
//! everything with `repack -a -d` and without `-l`, which `git gc` always
//! passes and which would drop every object the alternates also hold, and
//! only then delete loose objects. Capture commits link only to earlier
//! captures, never to the user's, so the store takes in no user history.
//!
//! The caller passes one deadline and, optionally, a cancel flag. Every git
//! run, lock wait and the untracked listing stop at them. A capture runs on
//! a longer one-time budget instead (`first_capture_budget_ms`) while the
//! store, the worktree's capture index or any capture ref is missing: it
//! creates them, writes the objects the store lacks and copies every object
//! of its tree, which in a large repository takes longer than a turn's
//! budget allows. That lasts until a capture lands, however many runs out
//! of time first.
//!
//! A path whose presence decides whether the store or capture index is
//! created counts as missing only when the system says it does not exist.
//! Any other answer, such as a permission error or a cancel, fails the
//! capture, so a store is never replaced because a check could not see it.
//!
//! A folder that git hands to another checkout's git directory is
//! `foreign_git_dir`: a `.git` symlink, a `gitdir:` file into another
//! checkout's `.git` folder, or one into a linked worktree's git directory
//! that names another `.git` file. A separate git directory, such as one
//! `git init --separate-git-dir` makes, records no work tree, so git's view is
//! taken as it is; its worktree key includes the work tree, so two folders
//! that point at it never share a capture index or a ref.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const safe_git = @import("../shell_command/safe_git.zig");
const indexer = @import("../indexer/indexer.zig");
const policy = @import("workspace_capture.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const session_adapter = @import("../session/session_adapter.zig");

const Allocator = std.mem.Allocator;

/// The repository a capture read, as absolute paths with every symlink
/// resolved, so two spellings of one repository name the same one.
pub const Repository = struct {
    /// Root of the worktree being captured.
    work_tree: []const u8,
    /// This worktree's git directory (`.git`, or `.git/worktrees/<name>`).
    git_dir: []const u8,
    /// The common git directory that holds the objects.
    common_dir: []const u8,
};

pub const Phase = enum { start, end };

pub const Request = struct {
    /// The spark profile root, such as `~/.spark`.
    profile_root: []const u8,
    /// An absolute folder inside the worktree to capture, such as the
    /// session's working directory. The whole worktree that holds it is
    /// captured, and `Outcome.repository` names it.
    path: []const u8,
    /// spark's session id, `[A-Za-z0-9._-]{1,255}` not starting with `.`.
    /// The ref names it by a hash, so every valid id fits git's ref rules.
    session_id: []const u8,
    phase: Phase,
    unix_seconds: i64,
    /// One budget for the whole capture, shared by every git command, lock
    /// wait and the untracked listing; a worktree's first capture may extend
    /// it (`first_capture_budget_ms`).
    deadline: std.Io.Clock.Timestamp,
    limits: policy.Limits = .{},
    /// Thread-safe allocator for the native indexer, which lists folders on
    /// several threads, and for the copy's pack indexes. Its memory is freed
    /// before `capture` returns.
    scan_allocator: Allocator,
    /// The host's cancel flag for the turn. Once set, the running git ends
    /// within `safe_git`'s poll, no further git starts, and lock waits stop;
    /// the capture is `cancelled`. It reaches git even when a `std.Io` cancel
    /// was already spent.
    cancel: ?*const std.atomic.Value(bool) = null,
    /// The user's home folder as the host knows it. A repository whose
    /// worktree root is the filesystem root, this folder or `HOME`, or
    /// a folder above either, is never captured (`private_root`).
    home: ?[]const u8 = null,
};

pub const Status = enum { complete, partial, failed, unavailable };

/// HEAD as the capture saw it: not read, a repository with no commit yet,
/// or a commit.
pub const Head = union(enum) { unknown, unborn, commit: []const u8 };

/// Where the untracked listing came from.
pub const Listing = enum { indexer, git };

/// How the capture index started: a copy of the user's index, a rebuild
/// from HEAD (split index), or this worktree's index from a previous capture.
pub const IndexStart = enum { copied, rebuilt, persisted };

/// What one capture did. A field stays at its default when the capture
/// stopped before measuring it, so a failure never claims a fact it did not
/// see.
pub const Outcome = struct {
    status: Status,
    /// Set for every status but `complete`.
    reason: ?policy.Reason = null,
    /// Set once git has resolved the repository.
    repository: ?Repository = null,
    /// The ref the capture extends, set with `repository`.
    ref: ?[]const u8 = null,
    head: Head = .unknown,
    object_format: ?safe_git.ObjectFormat = null,
    listing: ?Listing = null,
    index: ?IndexStart = null,
    /// Set for `complete` and `partial`.
    tree: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    /// Whether the tree can be compared with the user's commits.
    comparable: bool = false,
    /// Paths the policy left out, borrowed from the arena.
    excluded: []const policy.Exclusion = &.{},
    /// The tool whose action reached this repository first in the turn, for
    /// a start capture it triggered; null for the turn's own captures (D98).
    /// Set by the caller, not by `capture`.
    trigger_tool: ?[]const u8 = null,
};

/// The budget of a first capture, counted from its setup: one that creates
/// the repository's store or the worktree's capture index, or that finds no
/// capture ref in the store, so its copy has nothing to leave out. It writes
/// every object the new store lacks and copies its whole tree into the
/// store, and in a large repository that alone takes longer than a turn's
/// capture budget, so the whole capture runs until this much after setup
/// begins, or until the caller's deadline when that is later. A first
/// capture that runs out of time keeps the packs it finished, so the next
/// one, on this budget again, goes on from there; once a capture lands,
/// later ones keep the caller's deadline.
const first_capture_budget_ms: i64 = 10_000;

/// The deadline a capture runs on from its setup on: for a first capture
/// (`first`), `first_capture_budget_ms` after `started` unless the caller's
/// `deadline` is later; otherwise `deadline`.
fn setupDeadline(started: std.Io.Clock.Timestamp, deadline: std.Io.Clock.Timestamp, first: bool) std.Io.Clock.Timestamp {
    if (!first) return deadline;
    const budget_end = started.addDuration(.{ .raw = .fromMilliseconds(first_capture_budget_ms), .clock = deadline.clock });
    return if (budget_end.compare(.gt, deadline)) budget_end else deadline;
}

/// A capture index or session ref lock older than this was left by a git
/// that died: spark's own git runs on them only under the worktree lock, or for
/// one short ref command, and stops at the capture's deadline plus the setup
/// budget, both far shorter.
const stale_lock_ms: i64 = 2 * std.time.ms_per_min;

/// Captures `request.repository` into its store. Every failure is an
/// `Outcome`; only allocation failure is returned as an error. Memory belongs
/// to `arena`.
pub fn capture(arena: Allocator, request: Request) Allocator.Error!Outcome {
    if (!session_adapter.validSessionId(request.session_id)) return .{ .status = .failed, .reason = .invalid_request };
    for ([_][]const u8{ request.profile_root, request.path }) |path| {
        if (!std.Io.Dir.path.isAbsolute(path)) return .{ .status = .failed, .reason = .invalid_request };
    }
    var run: Run = .{ .arena = arena, .io = io_mod.getIo(), .request = request, .deadline = request.deadline };
    if (try run.resolve()) |done| return done;
    if (try run.checkPrivateRoot()) |done| return done;
    if (try run.findProfile()) |done| return done;
    if (try run.lockWorktree()) |done| return done;
    defer if (run.lock) |*lock| lock.close(run.io);
    if (try run.clearStaleLocks()) |done| return done;
    if (try run.setUp()) |done| return done;
    if (try run.select()) |done| return done;
    if (try run.apply()) |done| return done;
    return run.commit();
}

/// One capture's state, filled in step by step. Each step returns the
/// final outcome when the capture stops there, or null to go on.
const Run = struct {
    arena: Allocator,
    io: std.Io,
    request: Request,
    /// The capture's deadline, moved later by the time setup took.
    deadline: std.Io.Clock.Timestamp,
    outcome: Outcome = .{ .status = .complete },
    ready: safe_git.Ready = undefined,
    store_ready: safe_git.StoreReady = undefined,
    facts: safe_git.RepositoryFacts = undefined,
    canonical: Repository = undefined,
    /// `worktreeIdentity` of `canonical`.
    worktree: []const u8 = undefined,
    ref: []const u8 = undefined,
    /// The repository's folder under the profile (`storeDir`).
    store_dir: []const u8 = undefined,
    store: safe_git.Store = undefined,
    /// The worktree's lock, held from `lockWorktree` to the end.
    lock: ?Lock = null,
    /// What the user's git tracks, and what the capture index held before.
    tracked: []const Staged = &.{},
    captured: []const Staged = &.{},
    tracked_paths: std.StringHashMapUnmanaged(Staged) = .empty,
    selection: policy.Selection = undefined,
    /// spark's profile folder relative to the work tree when the work tree
    /// holds it (`findProfile`), which the capture never lists.
    profile: ?[]const u8 = null,
    /// The one exclusion recorded for the profile folder: set only when the
    /// user's git tracks files in it, which the tree then lacks.
    profile_exclusion: ?policy.Exclusion = null,
    /// The store's newest captures, which a capture with no parent leaves
    /// out of its copy (`newestCaptures`); read in `setUp`.
    copy_base: []const []const u8 = &.{},

    fn limits(self: *const Run) safe_git.Limits {
        return .{ .deadline = self.deadline, .cancel = self.request.cancel };
    }

    fn fail(self: *const Run, status: Status, reason: policy.Reason) Outcome {
        return withFailure(self.outcome, status, reason);
    }

    /// `outcome`, unless the cancel flag or the deadline explains it: a git
    /// run they stopped can surface as a refusal.
    fn stoppedOr(self: *const Run, outcome: Outcome) Outcome {
        if (self.request.cancel) |flag| if (flag.load(.acquire)) return withFailure(outcome, .unavailable, .cancelled);
        return deadlineOr(self.io, self.deadline, outcome);
    }

    fn gitFail(self: *const Run, failure: safe_git.Failure) Outcome {
        return withGitFailure(self.outcome, failure);
    }

    /// `io_error` for a failure outside git, logged with what failed, since
    /// the record names no path; `cancelled` for a cancel request, which is
    /// re-armed for the caller's next step.
    fn ioFail(self: *const Run, step: []const u8, path: []const u8, err: anyerror) Outcome {
        if (err == error.Canceled) {
            self.io.recancel();
            return self.fail(.unavailable, .cancelled);
        }
        logIoError(step, path, err);
        return self.fail(.failed, .io_error);
    }

    /// The user's repository: read only, through the agent's read-only
    /// prelude. A refusal after the deadline is the deadline's: prepare's own
    /// git runs stop there too.
    fn resolve(self: *Run) Allocator.Error!?Outcome {
        const arena = self.arena;
        self.ready = switch (try safe_git.prepareWithin(arena, self.request.path, self.limits())) {
            .ready => |value| value,
            .refused => return self.stoppedOr(.{ .status = .unavailable, .reason = .git_refused }),
        };
        // No repository holds the folder.
        if (self.ready.git_dir == null) return .{ .status = .unavailable, .reason = .not_git };
        // The store route needs git 2.29; check it before `repositoryFacts`,
        // which already uses a 2.29 option, so old git is unavailable, not
        // failed.
        self.store_ready = switch (try safe_git.prepareStore(arena, self.limits())) {
            .ready => |value| value,
            .refused => return self.stoppedOr(.{ .status = .unavailable, .reason = .git_refused }),
        };
        self.facts = switch (try safe_git.repositoryFacts(arena, self.ready, self.request.path, self.limits())) {
            .ok => |facts| facts,
            .failed => |failure| {
                debug_trace.logf("workspace", "event=workspace_capture_facts_failed kind={s}", .{@tagName(failure)});
                return self.stoppedOr(.{ .status = .failed, .reason = .io_error });
            },
        };
        // The repository as git resolves it, with symlinks resolved: every
        // key below uses these spellings, so `/tmp/x`, `/private/tmp/x` and
        // any folder inside the worktree reach the same store, index and ref.
        self.outcome = .{
            .status = .complete,
            .head = if (self.facts.head) |oid| .{ .commit = oid } else .unborn,
            .object_format = self.facts.object_format,
        };
        self.canonical = .{
            .work_tree = try resolvedPath(arena, self.facts.work_tree) orelse return self.ioFail("resolve", self.facts.work_tree, error.Unresolvable),
            .git_dir = try resolvedPath(arena, self.facts.git_dir) orelse return self.ioFail("resolve", self.facts.git_dir, error.Unresolvable),
            .common_dir = try resolvedPath(arena, self.facts.common_dir) orelse return self.ioFail("resolve", self.facts.common_dir, error.Unresolvable),
        };
        // The outcome claims nothing here: HEAD, the repository and the ref
        // would all be the other checkout's.
        if (!try ownsGitDir(arena, self.io, self.canonical, self.request.path)) {
            return .{ .status = .unavailable, .reason = .foreign_git_dir };
        }
        self.outcome.repository = self.canonical;
        // One chain per session and worktree: two worktrees of one
        // repository in the same session never race for one ref or mix their
        // trees.
        self.worktree = try worktreeIdentity(arena, self.canonical);
        self.ref = try sessionRefName(arena, self.request.session_id, self.worktree);
        self.outcome.ref = self.ref;
        // A sparse index holds folder entries the store cannot expand without
        // the user's sparse-checkout patterns.
        if (self.facts.sparse_index) return self.fail(.unavailable, .index_sparse);
        return null;
    }

    /// Layout and the worktree lock, held for the whole capture. flock is
    /// released by the kernel if spark dies, so a crash never leaves it held.
    fn lockWorktree(self: *Run) Allocator.Error!?Outcome {
        const arena = self.arena;
        const store_dir = try storeDir(arena, self.request.profile_root, self.canonical.common_dir);
        self.store_dir = store_dir;
        const worktree_dir = try worktreeDir(arena, store_dir, self.worktree);
        const scratch_dir = try std.Io.Dir.path.join(arena, &.{ worktree_dir, "scratch" });
        // Captures hold the user's uncommitted work: every folder spark creates
        // for them is private, whatever the umask.
        for ([_][]const u8{ try std.Io.Dir.path.join(arena, &.{ self.request.profile_root, "captures" }), store_dir, try std.Io.Dir.path.join(arena, &.{ store_dir, "worktrees" }), worktree_dir, scratch_dir }) |dir| {
            ensurePrivateDir(self.io, dir) catch |err| return self.ioFail("private_dir", dir, err);
        }
        // `lockUntil` logs why a lock could not be taken.
        const lock_path = try std.Io.Dir.path.join(arena, &.{ worktree_dir, "lock" });
        // Maintenance holds an existing store's `init.lock` and every
        // worktree lock for a whole pack or prune; the turn waits for that
        // only briefly. A missing store has no maintenance yet.
        const store_head = try std.Io.Dir.path.join(arena, &.{ try storeGitDir(arena, store_dir), "HEAD" });
        const store_exists = isPresent(self.io, store_head) catch |err| blk: {
            keepCancel(self.io, err);
            break :blk false;
        };
        const store_lock: ?[]const u8 = if (store_exists) try initLockPath(arena, store_dir) else null;
        self.lock = .{ .file = lockWorktreeUntil(self.io, lock_path, store_lock, self.deadline, self.request.cancel) catch |err| return switch (err) {
            error.Busy => self.fail(.unavailable, .capture_locked),
            error.Unavailable => self.fail(.failed, .io_error),
            error.Canceled => self.fail(.unavailable, .cancelled),
        } };
        self.store = .{
            .git_dir = try storeGitDir(arena, store_dir),
            .index_file = try std.Io.Dir.path.join(arena, &.{ worktree_dir, "index" }),
            .work_tree = self.canonical.work_tree,
            .scratch_dir = scratch_dir,
            .conversions = self.facts.conversions,
        };
        return null;
    }

    /// A git that outlived its capture, such as one a killed spark left, can
    /// leave the capture index or this session's ref locked. Only captures
    /// holding the worktree lock run git on the index and move the ref, and
    /// this one holds it; the fork copy and retention touch the ref for one
    /// short command at most. So a lock older than any of them can run is
    /// removed; a newer one is reported.
    fn clearStaleLocks(self: *Run) Allocator.Error!?Outcome {
        const locks = [_][]const u8{
            try self.arena.print("{s}.lock", .{self.store.index_file}),
            try self.arena.print("{s}/{s}.lock", .{ self.store.git_dir, self.ref }),
        };
        for (locks) |path| if (try self.clearStaleLock(path)) |done| return done;
        return null;
    }

    fn clearStaleLock(self: *Run, path: []const u8) Allocator.Error!?Outcome {
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            error.Canceled => return self.ioFail("lock_stat", path, err),
            else => return self.fail(.unavailable, .capture_locked),
        };
        const age_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds() - stat.mtime.toMilliseconds();
        if (age_ms < stale_lock_ms) return self.fail(.unavailable, .capture_locked);
        std.Io.Dir.deleteFileAbsolute(self.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            error.Canceled => return self.ioFail("lock_remove", path, err),
            else => return self.fail(.unavailable, .capture_locked),
        };
        debug_trace.logf("workspace", "event=workspace_capture_stale_lock_removed lock={s} age_ms={d}", .{ path, age_ms });
        return null;
    }

    /// Makes sure the store exists and the worktree has a capture index. The
    /// first capture starts the index from a copy of the user's with its
    /// timestamp, so git's racy-entry check still sees files changed in the
    /// index's second. A split index keeps entries in a shared file the copy
    /// would miss, so it is rebuilt from HEAD instead. When either is new,
    /// or the store holds no capture ref, the rest of the capture runs on
    /// `first_capture_budget_ms` (`setupDeadline`). An index that is not a
    /// regular file of bounded size, such as a pipe whose open would block
    /// past any deadline, is rebuilt from HEAD too. Only a store or index
    /// the system reports missing is created; a check that fails otherwise
    /// fails the capture.
    fn setUp(self: *Run) Allocator.Error!?Outcome {
        const arena = self.arena;
        const io = self.io;
        const clock = self.deadline.clock;
        const store_head = try std.Io.Dir.path.join(arena, &.{ self.store.git_dir, "HEAD" });
        const store_missing = !(isPresent(io, store_head) catch |err| return self.ioFail("store_check", store_head, err));
        const index_missing = !(isPresent(io, self.store.index_file) catch |err| return self.ioFail("index_check", self.store.index_file, err));
        const started: std.Io.Clock.Timestamp = .now(io, clock);
        const setup_deadline = setupDeadline(started, self.deadline, store_missing or index_missing);
        // An existing store is only checked. Its lock, which a prune or a
        // pack also holds, is waited for only briefly, so a turn never waits
        // for a maintenance repack.
        const store_wait: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = clock, .raw = .fromMilliseconds(existing_store_wait_ms) });
        const store_deadline = if (store_missing) setup_deadline else if (self.deadline.compare(.lte, store_wait)) self.deadline else store_wait;
        if (try ensureStore(arena, io, self.store_ready, self.store_dir, self.store.git_dir, self.canonical.common_dir, self.facts.object_format, .{ .deadline = store_deadline, .cancel = self.request.cancel }, store_deadline)) |failure| {
            // Maintenance holds an existing store's lock for a whole repack;
            // the capture is skipped rather than waiting for it.
            if (!store_missing and failure == .timeout) return self.fail(.unavailable, .capture_locked);
            return self.gitFail(failure);
        }
        // Until the store holds a capture, a copy has nothing to leave out
        // and takes the whole tree, so the capture keeps the first budget;
        // a new store holds none.
        if (!store_missing) {
            const refs = switch (try storeOutput(arena, self.store_ready, self.store, .list_refs, .{ .deadline = setup_deadline, .cancel = self.request.cancel })) {
                .ok => |stdout| stdout,
                .failed => |failure| return self.gitFail(failure),
            };
            self.copy_base = try newestCaptures(arena, refs, self.facts.object_format);
        }
        const first = store_missing or index_missing or self.copy_base.len == 0;
        if (builtin.is_test) test_hooks.first_budget = first;
        const first_deadline = setupDeadline(started, self.deadline, first);
        self.outcome.index = .persisted;
        if (index_missing) {
            const user_index = try std.Io.Dir.path.join(arena, &.{ self.canonical.git_dir, "index" });
            if (self.facts.split_index or try hasSharedIndex(io, self.canonical.git_dir) or !copyableIndex(io, user_index)) {
                if (try runStore(arena, self.store_ready, self.store, .{ .read_tree = self.facts.head }, .{ .deadline = first_deadline, .cancel = self.request.cancel })) |failure| return self.gitFail(failure);
                self.outcome.index = .rebuilt;
            } else {
                copyPreservingTime(arena, io, user_index, self.store.index_file) catch |err| return self.ioFail("index_copy", user_index, err);
                self.outcome.index = .copied;
            }
        }
        if (first) {
            // The first capture keeps the longer budget for its whole run:
            // the objects the new store lacks are written, and its whole
            // tree copied, after setup.
            self.deadline = first_deadline;
            const took = started.durationTo(.now(io, clock));
            debug_trace.logf("workspace", "event=workspace_capture_setup store_created={} index={s} captures={d} ms={d} budget_ms={d}", .{ store_missing, @tagName(self.outcome.index.?), self.copy_base.len, took.raw.toMilliseconds(), first_capture_budget_ms });
        }
        return null;
    }

    /// Lists what the user's git tracks, what the capture index holds and
    /// the untracked files, checks each on disk, and applies
    /// `workspace_capture`'s policy.
    fn select(self: *Run) Allocator.Error!?Outcome {
        const arena = self.arena;
        const io = self.io;
        const tracked_listing = switch (try safe_git.listRepository(arena, self.ready, self.canonical.work_tree, .tracked, null, self.limits())) {
            .ok => |stdout| stdout,
            .failed => |failure| return self.gitFail(failure),
        };
        self.tracked = try self.leaveOutProfile(safe_git.parseStageListing(arena, tracked_listing) catch return self.fail(.failed, .inconsistent));
        const index_listing = switch (try storeOutput(arena, self.store_ready, self.store, .list_index, self.limits())) {
            .ok => |stdout| stdout,
            .failed => |failure| return self.gitFail(failure),
        };
        self.captured = safe_git.parseStageListing(arena, index_listing) catch return self.fail(.failed, .inconsistent);

        // Untracked files: the native indexer, or git when it cannot read the
        // index format completely.
        for (self.tracked) |entry| try self.tracked_paths.put(arena, entry.path, entry);
        const untracked = switch (try listUntracked(arena, self.request.scan_allocator, self.ready, self.facts, self.profile, self.limits(), &self.tracked_paths, &self.outcome)) {
            .listed => |value| value,
            .stopped => return self.fail(.unavailable, .untracked_timeout),
            .cancelled => return self.fail(.unavailable, .cancelled),
            .failed => return deadlineOr(io, self.deadline, self.fail(.failed, .io_error)),
        };
        if (pastDeadline(io, self.deadline)) return self.fail(.unavailable, .timeout);

        // Candidates with what the disk holds now.
        var candidates: std.ArrayList(policy.Candidate) = .empty;
        var disk: Disk = .{ .arena = arena, .io = io, .work_tree = self.canonical.work_tree };
        // Sensitive names the user's index holds: one git run tells which of
        // them HEAD's tree lacks, such as a staged new `.env`.
        var sensitive: std.ArrayList([]const u8) = .empty;
        for (self.tracked) |entry| if (policy.isSensitive(entry.path)) try sensitive.append(arena, entry.path);
        const in_head = try self.headPaths(sensitive.items);
        for (self.tracked, 0..) |entry, i| {
            if (i % 1024 == 1023 and pastDeadline(io, self.deadline)) return self.fail(.unavailable, .timeout);
            const found = disk.lstat(entry.path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Unreadable => return self.fail(.failed, .io_error),
                error.Canceled => return self.fail(.unavailable, .cancelled),
            };
            // A tracked file replaced by a folder is gone, unless it is a
            // gitlink.
            const present = found.present and ((entry.mode == .gitlink) or found.kind != .gitlink);
            const new_in_index = policy.isSensitive(entry.path) and !in_head.contains(entry.path);
            try candidates.append(arena, .{
                .path = entry.path,
                .tracked = true,
                .present = present,
                .skip_worktree = entry.skip_worktree,
                .new_in_index = new_in_index,
                .bytes = found.bytes,
                .kind = if ((entry.mode == .gitlink)) .gitlink else found.kind,
            });
        }
        for (untracked.files, 0..) |path, i| {
            if (i % 1024 == 1023 and pastDeadline(io, self.deadline)) return self.fail(.unavailable, .timeout);
            const found = disk.lstat(path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Unreadable => return self.fail(.failed, .io_error),
                error.Canceled => return self.fail(.unavailable, .cancelled),
            };
            const holds_key = found.present and found.kind == .file and found.bytes <= self.request.limits.untracked_file_bytes and (disk.holdsPrivateKey(path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return self.fail(.unavailable, .cancelled),
            });
            try candidates.append(arena, .{ .path = path, .tracked = false, .present = found.present, .bytes = found.bytes, .kind = found.kind, .holds_private_key = holds_key });
        }
        // A repository nested inside the worktree is recorded as left out,
        // never silently dropped.
        for (untracked.nested) |path| {
            try candidates.append(arena, .{ .path = path, .tracked = false, .present = true, .kind = .gitlink });
        }
        var previous: std.ArrayList([]const u8) = .empty;
        for (self.captured) |entry| try previous.append(arena, entry.path);
        self.selection = policy.select(arena, candidates.items, previous.items, self.request.limits) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPath, error.DuplicatePath => return self.fail(.failed, .inconsistent),
        };
        if (self.profile_exclusion) |exclusion| {
            self.selection.excluded = try std.mem.concat(arena, policy.Exclusion, &.{ self.selection.excluded, &.{exclusion} });
        }
        return null;
    }

    /// Finds spark's own profile folder, `~/.spark` or `$SPARK_HOME`, in the work
    /// tree. It holds sessions, credentials and this very store, so a capture
    /// never lists it: otherwise every capture would list the objects the
    /// earlier ones wrote. A work tree that is the profile folder itself
    /// holds only spark's data and is `private_root`.
    fn findProfile(self: *Run) Allocator.Error!?Outcome {
        self.profile = try profileWithin(self.arena, self.canonical.work_tree, self.request.profile_root);
        if (self.profile) |profile| if (profile.len == 0) return self.fail(.unavailable, .private_root);
        return null;
    }

    /// The `paths` that HEAD's tree holds. With no HEAD, or when git cannot
    /// answer, none: every sensitive tracked file then counts as new, so the
    /// capture leaves it out.
    fn headPaths(self: *Run, paths: []const []const u8) Allocator.Error!std.StringHashMapUnmanaged(void) {
        var set: std.StringHashMapUnmanaged(void) = .empty;
        const head = self.facts.head orelse return set;
        const found = try safe_git.pathsInTree(self.arena, self.ready, self.canonical.work_tree, head, paths, self.limits()) orelse {
            debug_trace.logf("workspace", "event=workspace_capture_head_paths_failed paths={d} dropped=committed_sensitive_files", .{paths.len});
            return set;
        };
        for (found) |path| try set.put(self.arena, path, {});
        return set;
    }

    /// A worktree root that is private (`isPrivateRoot`) is never captured.
    fn checkPrivateRoot(self: *Run) Allocator.Error!?Outcome {
        if (try isPrivateRoot(self.arena, self.canonical.work_tree, &.{ io_mod.getenv("HOME"), self.request.home })) return self.fail(.unavailable, .private_root);
        return null;
    }

    /// `tracked` without the files under the profile folder. The untracked
    /// listing skips the folder without a trace, since what spark wrote there
    /// is not the user's work and a tree never held it, so a capture stays
    /// complete and comparable. A file the user's git tracks there is
    /// different: the tree lacks what the user's commits hold, so the folder
    /// is recorded once as a `sensitive` exclusion, which makes the capture
    /// partial.
    fn leaveOutProfile(self: *Run, tracked: []const Staged) Allocator.Error![]const Staged {
        const profile = self.profile orelse return tracked;
        var kept: std.ArrayList(Staged) = .empty;
        for (tracked) |entry| if (!isUnder(profile, entry.path)) try kept.append(self.arena, entry);
        if (kept.items.len < tracked.len) self.profile_exclusion = .{ .path = profile, .reason = .sensitive };
        return kept.items;
    }

    /// Applies the selection to the capture index only. Paths read from disk
    /// lose the flags the index copy inherited, or git would keep their old
    /// content.
    fn apply(self: *Run) Allocator.Error!?Outcome {
        const arena = self.arena;
        const selection = self.selection;
        {
            var inherited: std.StringHashMapUnmanaged(Staged) = .empty;
            for (self.captured) |entry| if (entry.assume_unchanged or entry.skip_worktree) try inherited.put(arena, entry.path, entry);
            var assume: std.ArrayList([]const u8) = .empty;
            var skip: std.ArrayList([]const u8) = .empty;
            for (selection.read) |path| if (inherited.get(path)) |entry| {
                if (entry.assume_unchanged) try assume.append(arena, path);
                if (entry.skip_worktree) try skip.append(arena, path);
            };
            if (assume.items.len > 0) {
                if (try runStore(arena, self.store_ready, self.store, .{ .clear_flag = .{ .flag = .assume_unchanged, .paths = assume.items } }, self.limits())) |failure| return self.gitFail(failure);
            }
            if (skip.items.len > 0) {
                if (try runStore(arena, self.store_ready, self.store, .{ .clear_flag = .{ .flag = .skip_worktree, .paths = skip.items } }, self.limits())) |failure| return self.gitFail(failure);
            }
        }
        if (selection.keep_index.len > 0) {
            var entries: std.ArrayList(safe_git.IndexEntry) = .empty;
            for (selection.keep_index) |path| {
                const entry = self.tracked_paths.get(path) orelse return self.fail(.failed, .inconsistent);
                try entries.append(arena, .{ .mode = entry.mode, .oid = entry.oid, .path = path });
            }
            if (try runStore(arena, self.store_ready, self.store, .{ .index_info = entries.items }, self.limits())) |failure| return self.gitFail(failure);
        }
        // Removed paths may still be on disk (an untracked file that became
        // ignored, or went over a limit), so they are forced out.
        if (selection.remove.len > 0) {
            if (try runStore(arena, self.store_ready, self.store, .{ .force_remove = selection.remove }, self.limits())) |failure| return self.gitFail(failure);
        }
        if (selection.read.len > 0) {
            if (try runStore(arena, self.store_ready, self.store, .{ .add_remove = selection.read }, self.limits())) |failure| return self.gitFail(failure);
        }
        return null;
    }

    /// Writes the tree and the commit, and moves the session ref to it.
    fn commit(self: *Run) Allocator.Error!Outcome {
        const arena = self.arena;
        const format = self.facts.object_format;
        const tree = switch (try storeOutput(arena, self.store_ready, self.store, .write_tree, self.limits())) {
            .ok => |stdout| std.mem.trimEnd(u8, stdout, "\n"),
            .failed => |failure| return self.gitFail(failure),
        };
        if (!safe_git.isOid(tree, format)) return self.fail(.failed, .inconsistent);
        const parent_out = switch (try storeOutput(arena, self.store_ready, self.store, .{ .resolve_ref = self.ref }, self.limits())) {
            .ok => |stdout| std.mem.trimEnd(u8, stdout, "\n"),
            .failed => |failure| return self.gitFail(failure),
        };
        const parent: ?[]const u8 = if (parent_out.len == 0) null else parent_out;
        const message = try arena.print("spark capture {s} {s}\n", .{ self.request.session_id, @tagName(self.request.phase) });
        const commit_oid = switch (try storeOutput(arena, self.store_ready, self.store, .{ .commit_tree = .{ .tree = tree, .parent = parent, .message = message, .unix_seconds = self.request.unix_seconds } }, self.limits())) {
            .ok => |stdout| std.mem.trimEnd(u8, stdout, "\n"),
            .failed => |failure| return self.gitFail(failure),
        };
        if (!safe_git.isOid(commit_oid, format)) return self.fail(.failed, .inconsistent);
        // The ref moves only once the store holds every object of the tree
        // itself, so every commit a capture ref names is self-sufficient.
        // Every capture ref passed this copy, so what the parent, or with no
        // parent the store's newest captures, reach is left out.
        const except: []const []const u8 = if (parent) |oid| try arena.dupe([]const u8, &.{oid}) else self.copy_base;
        if (try copyObjects(arena, self.request.scan_allocator, self.store_ready, self.store, format, tree, except, self.limits())) |failure| return self.gitFail(failure);
        if (try runStore(arena, self.store_ready, self.store, .{ .update_ref = .{ .ref = self.ref, .new = commit_oid, .old = parent } }, self.limits())) |failure| return self.gitFail(failure);

        var outcome = self.outcome;
        outcome.tree = tree;
        outcome.commit = commit_oid;
        outcome.excluded = self.selection.excluded;
        // Filters or attributes from the repository's own config never reach
        // the store, so its tree may differ from the user's. A file that
        // cannot be checked counts as there, so the capture claims less.
        const repository_conversions = self.ready.filter_names.len > 0 or
            presentOr(self.io, try std.Io.Dir.path.join(arena, &.{ self.canonical.git_dir, "info", "attributes" }), true) or
            presentOr(self.io, try std.Io.Dir.path.join(arena, &.{ self.canonical.common_dir, "info", "attributes" }), true);
        outcome.comparable = self.selection.canCompareTrees(repository_conversions);
        if (lossReason(self.selection.excluded)) |reason| {
            outcome.status = .partial;
            outcome.reason = reason;
        }
        return outcome;
    }
};

/// Whether the worktree git reports is the captured folder's own: the folder
/// lies inside it, and the git directory's own record of its work tree, where
/// it keeps one, names this worktree's `.git`. A `.git` symlink, or a
/// `gitdir:` file into another checkout's `.git` folder or linked worktree,
/// makes git treat the folder as that checkout's worktree and report its
/// HEAD.
fn ownsGitDir(arena: Allocator, io: std.Io, repo: Repository, path: []const u8) Allocator.Error!bool {
    const folder = try resolvedPath(arena, path) orelse return false;
    if (!isWithin(repo.work_tree, folder)) return false;
    const dot_git = try std.Io.Dir.path.join(arena, &.{ repo.work_tree, ".git" });
    const stat = std.Io.Dir.cwd().statFile(io, dot_git, .{ .follow_symlinks = false }) catch |err| {
        keepCancel(io, err);
        return false;
    };
    switch (stat.kind) {
        .directory => {
            const real = try resolvedPath(arena, dot_git) orelse return false;
            return std.mem.eql(u8, real, repo.git_dir);
        },
        .file => {
            if (!std.mem.eql(u8, repo.git_dir, repo.common_dir)) {
                // A linked worktree: its git directory records which `.git`
                // file is the worktree's, absolute or relative to itself.
                const gitdir_file = try std.Io.Dir.path.join(arena, &.{ repo.git_dir, "gitdir" });
                const recorded = try readSmallRegularFile(arena, io, gitdir_file, std.Io.Dir.max_path_bytes) orelse return false;
                const trimmed = std.mem.trimEnd(u8, recorded, "\r\n");
                const target = if (std.Io.Dir.path.isAbsolute(trimmed)) trimmed else try std.Io.Dir.path.join(arena, &.{ repo.git_dir, trimmed });
                const real_target = try resolvedPath(arena, target) orelse return false;
                const real_dot_git = try resolvedPath(arena, dot_git) orelse return false;
                return std.mem.eql(u8, real_target, real_dot_git);
            }
            // Never another checkout's own `.git` folder.
            const parent = std.Io.Dir.path.dirname(repo.git_dir) orelse return false;
            if (std.mem.eql(u8, std.Io.Dir.path.basename(repo.git_dir), ".git")) return std.mem.eql(u8, parent, repo.work_tree);
            // A submodule's git directory names its work tree in
            // `core.worktree`, which git applied: a `.git` file elsewhere
            // gets that work tree, and `isWithin` above refuses it. A
            // separate git directory names none, so git's work tree, the
            // folder holding this `.git` file, is the only record there is.
            // Its worktree key includes that work tree (`worktreeIdentity`),
            // so another folder pointing at the same git directory never
            // shares this one's capture index or ref.
            return true;
        },
        else => return false,
    }
}

/// What names one worktree inside its repository's store, for its folder
/// (`worktreeDir`) and its session refs (`sessionRefName`). A work tree's own
/// `.git` folder belongs to that work tree alone, so it is named by its git
/// directory. Any other git directory, a separate one or a linked
/// worktree's, can be handed to a second folder by a `gitdir:` file, so it is
/// named by the git directory and the work tree together, joined by a NUL
/// that no path holds, so the two forms never collide. Owned by `arena`.
fn worktreeIdentity(arena: Allocator, repo: Repository) Allocator.Error![]const u8 {
    const own_dot_git = std.mem.eql(u8, std.Io.Dir.path.basename(repo.git_dir), ".git") and
        std.mem.eql(u8, std.Io.Dir.path.dirname(repo.git_dir) orelse "", repo.work_tree);
    if (own_dot_git) return repo.git_dir;
    return arena.print("{s}\x00{s}", .{ repo.git_dir, repo.work_tree });
}

/// The contents of `path` when it is a regular file of at most `max_bytes`,
/// checked before it is opened; null otherwise. A pipe, socket or device is
/// never opened, since opening one can block with no deadline. A cancel
/// request is re-armed for the capture's next step.
fn readSmallRegularFile(arena: Allocator, io: std.Io, path: []const u8, max_bytes: usize) Allocator.Error!?[]const u8 {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
        keepCancel(io, err);
        return null;
    };
    if (stat.kind != .file or stat.size > max_bytes) {
        debug_trace.logf("workspace", "event=workspace_capture_file_skipped path={s} kind={s} bytes={d}", .{ path, @tagName(stat.kind), stat.size });
        return null;
    }
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            keepCancel(io, err);
            return null;
        },
    };
}

/// Whether the user's index at `path` can be copied: a regular file no larger
/// than `max_index_bytes`. Anything else is rebuilt from HEAD, which is
/// always correct.
fn copyableIndex(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
        keepCancel(io, err);
        if (err != error.FileNotFound) logIoError("index_stat", path, err);
        return false;
    };
    if (stat.kind == .file and stat.size <= max_index_bytes) return true;
    debug_trace.logf("workspace", "event=workspace_capture_index_rebuilt path={s} kind={s} bytes={d}", .{ path, @tagName(stat.kind), stat.size });
    return false;
}

/// Logs a failure outside git that a capture reports as `io_error`.
fn logIoError(step: []const u8, path: []const u8, err: anyerror) void {
    debug_trace.logf("workspace", "event=workspace_capture_failed step={s} path={s} err={s}", .{ step, path, @errorName(err) });
}

/// Whether `path` is `root` or inside it; both absolute and resolved.
pub fn isWithin(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or root[root.len - 1] == '/' or path[root.len] == '/';
}

/// Whether a repository at `root` is never captured: the filesystem
/// root, or a root that is one of `homes` or holds one, such as a home
/// kept as a dotfiles repository. Each home is compared by its real
/// path; an unset or unresolvable one is skipped.
pub fn isPrivateRoot(arena: Allocator, root: []const u8, homes: []const ?[]const u8) Allocator.Error!bool {
    if (std.mem.trimEnd(u8, root, "/").len == 0) return true;
    for (homes) |maybe| {
        const home = maybe orelse continue;
        if (home.len == 0) continue;
        const real = try resolvedPath(arena, home) orelse continue;
        if (isWithin(root, real)) return true;
    }
    return false;
}

/// Where the profile folder `profile_root` lies in `work_tree`, relative to
/// it and empty when it is the work tree itself; null when it lies outside
/// or cannot be resolved.
fn profileWithin(arena: Allocator, work_tree: []const u8, profile_root: []const u8) Allocator.Error!?[]const u8 {
    const resolved = try resolvedPath(arena, profile_root) orelse return null;
    if (!isWithin(work_tree, resolved)) return null;
    return std.mem.trimStart(u8, resolved[@min(work_tree.len, resolved.len)..], "/");
}

/// Whether the repository-relative `path` is `folder` or inside it; an empty
/// `folder` holds every path.
fn isUnder(folder: []const u8, path: []const u8) bool {
    if (folder.len == 0) return true;
    if (!std.mem.startsWith(u8, path, folder)) return false;
    return path.len == folder.len or path[folder.len] == '/';
}

/// `path` with every symlink resolved, or null when it cannot be resolved.
fn resolvedPath(arena: Allocator, path: []const u8) Allocator.Error!?[]const u8 {
    return io_mod.realpathAlloc(arena, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

/// The ref for `session_id` and the worktree whose `worktreeIdentity` is
/// `worktree`. Both parts are hashes, so any id spark accepts fits git's ref
/// rules and `safe_git`'s two-segment ref check.
fn sessionRefName(arena: Allocator, session_id: []const u8, worktree: []const u8) Allocator.Error![]const u8 {
    return arena.print("refs/spark/sessions/{s}/{s}", .{ try sessionKey(arena, session_id), try pathKey(arena, worktree) });
}

/// The ref segment that names `session_id`: the first 16 bytes of its
/// SHA-256, in hex. Retention matches sessions to refs with it.
pub fn sessionKey(arena: Allocator, session_id: []const u8) Allocator.Error![]const u8 {
    return pathKey(arena, session_id);
}

pub fn pastDeadline(io: std.Io, deadline: std.Io.Clock.Timestamp) bool {
    return deadline.compare(.lte, .now(io, deadline.clock));
}

fn ensurePrivateDir(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
    // `iterate` opens a real descriptor: on Linux a plain open is O_PATH,
    // which fchmod rejects with EBADF (as `settings_store` opens its home).
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    try dir.setPermissions(io, .fromMode(0o700));
}

fn withFailure(base: Outcome, status: Status, reason: policy.Reason) Outcome {
    var outcome = base;
    outcome.status = status;
    outcome.reason = reason;
    outcome.tree = null;
    outcome.commit = null;
    return outcome;
}

fn withGitFailure(base: Outcome, failure: safe_git.Failure) Outcome {
    return switch (failure) {
        .timeout => withFailure(base, .unavailable, .timeout),
        .cancelled => withFailure(base, .unavailable, .cancelled),
        .path_rejected => withFailure(base, .failed, .inconsistent),
        // Config defines a hook for the store that spark cannot turn off.
        .hooks_refused => withFailure(base, .unavailable, .git_refused),
        .spawn_failed, .input_failed, .read_failed, .output_too_large, .exited_nonzero, .terminated => withFailure(base, .failed, .io_error),
    };
}

/// A failure observed after the shared deadline passed is a timeout.
fn deadlineOr(io: std.Io, deadline: std.Io.Clock.Timestamp, outcome: Outcome) Outcome {
    if (pastDeadline(io, deadline)) return withFailure(outcome, .unavailable, .timeout);
    return outcome;
}

/// Runs a store command and returns its output. Every argument comes from
/// git's own listings or validated input, so a rejected argument means the
/// listing and the store disagree.
pub fn storeOutput(arena: Allocator, ready: safe_git.StoreReady, store: safe_git.Store, command: safe_git.StoreCommand, limits: safe_git.Limits) Allocator.Error!safe_git.Outcome {
    return safe_git.runStore(arena, ready, store, command, limits) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArgument => return .{ .failed = .path_rejected },
    };
}

/// Runs a store command whose output is not needed; null on success.
fn runStore(arena: Allocator, ready: safe_git.StoreReady, store: safe_git.Store, command: safe_git.StoreCommand, limits: safe_git.Limits) Allocator.Error!?safe_git.Failure {
    return switch (try storeOutput(arena, ready, store, command, limits)) {
        .ok => null,
        .failed => |failure| failure,
    };
}

/// Captures whose trees a parentless capture's copy leaves out, newest first.
/// Each costs one tree walk, so a store with many refs stays bounded.
const max_copy_exclusions = 16;

/// Objects in one pack the copy writes. Each finished pack stays when a later
/// one runs out of time, so an interrupted copy loses at most one pack's work,
/// and the copy of a large tree leaves a few dozen packs until retention
/// repacks them into one.
const copy_batch_objects: usize = 20_000;

/// Seams for tests. Production code reads and writes them only under
/// `builtin.is_test`, so a release build has none.
const test_hooks = struct {
    /// Replaces `copy_batch_objects`.
    var copy_batch_objects: ?usize = null;
    /// The packs a copy writes before it stops as if its deadline passed.
    var copy_packs_before_timeout: ?usize = null;
    /// A path suffix whose presence check fails as if access were denied.
    var access_denied_suffix: ?[]const u8 = null;
    /// Whether the last capture's setup chose the first-capture budget.
    var first_budget: ?bool = null;
    /// The objects the last copy packed.
    var copied_objects: usize = 0;
};

/// Copies into the store every object `tree` reaches that it might hold only
/// through its alternates: a staged blob, or one from a branch the user may
/// delete. Objects the trees of the `except` commits reach are left out:
/// every commit a capture ref names already passed this copy. Objects the
/// store holds itself are skipped: loose ones, which it wrote, and those in
/// its own packs, such as the packs an earlier copy finished before it ran
/// out of time. They stay safe because no store command deletes a loose
/// object before packing it into the store's own pack, and none drops an
/// object a ref reaches from a pack: retention's `gc` and `repack` both
/// repack everything without `-l`. The rest goes into packs of at most
/// `copy_batch_objects` objects, each kept once written. `scratch` holds the
/// pack indexes while the copy runs. Null on success; `.path_rejected` when
/// git lists something that is not an object ID.
fn copyObjects(
    arena: Allocator,
    scratch: Allocator,
    ready: safe_git.StoreReady,
    store: safe_git.Store,
    format: safe_git.ObjectFormat,
    tree: []const u8,
    except: []const []const u8,
    limits: safe_git.Limits,
) Allocator.Error!?safe_git.Failure {
    const io = io_mod.getIo();
    const started: std.Io.Clock.Timestamp = .now(io, .awake);
    if (builtin.is_test) test_hooks.copied_objects = 0;
    const listing = switch (try storeOutput(arena, ready, store, .{ .list_objects = .{ .tree = tree, .except = except } }, limits)) {
        .ok => |stdout| stdout,
        .failed => |failure| return failure,
    };
    var packs = OwnPacks.load(arena, scratch, io, store.git_dir, format) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return .cancelled,
    };
    defer packs.deinit(io);
    var objects: std.ArrayList([]const u8) = .empty;
    var loose: usize = 0;
    var held: usize = 0;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!safe_git.isOid(line, format)) return .path_rejected;
        if (packs.contains(io, line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return .cancelled,
        }) {
            held += 1;
            continue;
        }
        // A loose object in the store is one it wrote itself. One that
        // cannot be checked is copied.
        const loose_path = try arena.print("{s}/objects/{s}/{s}", .{ store.git_dir, line[0..2], line[2..] });
        if (isPresent(io, loose_path) catch |err| switch (err) {
            error.Canceled => {
                io.recancel();
                return .cancelled;
            },
            else => false,
        }) {
            loose += 1;
            continue;
        }
        try objects.append(arena, line);
    }
    const batch = @max(1, if (builtin.is_test) test_hooks.copy_batch_objects orelse copy_batch_objects else copy_batch_objects);
    var start: usize = 0;
    var written: usize = 0;
    while (start < objects.items.len) : (written += 1) {
        if (builtin.is_test) if (test_hooks.copy_packs_before_timeout) |limit| if (written == limit) return .timeout;
        const end = @min(objects.items.len, start + batch);
        if (try runStore(arena, ready, store, .{ .pack_objects = objects.items[start..end] }, limits)) |failure| return failure;
        if (builtin.is_test) test_hooks.copied_objects += end - start;
        start = end;
    }
    debug_trace.logf("workspace", "event=workspace_capture_objects_copied objects={d} packs={d} loose={d} packed={d} excluded={d} ms={d}", .{
        objects.items.len,
        written,
        loose,
        held,
        except.len,
        started.durationTo(.now(io, .awake)).raw.toMilliseconds(),
    });
    return null;
}

/// The store's own packs, read from their version 2 `.idx` files, apart from
/// the packs its alternates hold: which objects the store already holds
/// itself in a pack. Loading also deletes the temporary files of a pack that
/// a killed git left, once older than any git of a capture or retention
/// runs (`stale_lock_ms`). A pack that cannot be read is left out, which only
/// copies more.
const OwnPacks = struct {
    scratch: Allocator,
    indexes: []PackIndex,

    const Error = Allocator.Error || error{Canceled};

    fn load(arena: Allocator, scratch: Allocator, io: std.Io, git_dir: []const u8, format: safe_git.ObjectFormat) Error!OwnPacks {
        var indexes: std.ArrayList(PackIndex) = .empty;
        const pack_dir = try std.Io.Dir.path.join(arena, &.{ git_dir, "objects", "pack" });
        var dir = std.Io.Dir.openDirAbsolute(io, pack_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return .{ .scratch = scratch, .indexes = indexes.items },
            error.Canceled => {
                io.recancel();
                return error.Canceled;
            },
            else => {
                logIoError("pack_list", pack_dir, err);
                return .{ .scratch = scratch, .indexes = indexes.items };
            },
        };
        defer dir.close(io);
        const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
        var entries = dir.iterate();
        while (entries.next(io) catch |err| {
            if (err == error.Canceled) {
                io.recancel();
                return error.Canceled;
            }
            logIoError("pack_list", pack_dir, err);
            return .{ .scratch = scratch, .indexes = indexes.items };
        }) |entry| {
            if (std.mem.startsWith(u8, entry.name, "tmp_")) {
                removeStaleTemporaryPack(io, dir, pack_dir, entry.name, now_ms);
                continue;
            }
            if (!std.mem.startsWith(u8, entry.name, "pack-") or !std.mem.endsWith(u8, entry.name, ".idx")) continue;
            const pack_name = try arena.print("{s}.pack", .{entry.name[0 .. entry.name.len - ".idx".len]});
            if (PackIndex.open(io, dir, entry.name, pack_name, format)) |index| {
                try indexes.append(arena, index);
            } else |err| switch (err) {
                error.Canceled => {
                    io.recancel();
                    return error.Canceled;
                },
                else => debug_trace.logf("workspace", "event=workspace_capture_pack_skipped dir={s} name={s} err={s}", .{ pack_dir, entry.name, @errorName(err) }),
            }
        }
        return .{ .scratch = scratch, .indexes = indexes.items };
    }

    fn deinit(self: *OwnPacks, io: std.Io) void {
        for (self.indexes) |*index| index.close(io, self.scratch);
    }

    /// Whether one of the packs holds `oid`, given in hex. Reads each pack's
    /// object table once lookups are many enough that reading it whole
    /// costs less than searching it on disk.
    fn contains(self: *OwnPacks, io: std.Io, oid: []const u8) Error!bool {
        var raw_buffer: [32]u8 = undefined;
        const raw = std.fmt.hexToBytes(raw_buffer[0 .. oid.len / 2], oid) catch return false;
        for (self.indexes) |*index| {
            if (index.contains(io, self.scratch, raw) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => {
                    io.recancel();
                    return error.Canceled;
                },
                else => {
                    // A pack that fails to read is left out from here on.
                    index.count = 0;
                    continue;
                },
            }) return true;
        }
        return false;
    }
};

/// Deletes `name`, a temporary file of a pack in `dir`, when it was last
/// written longer ago than any capture's or retention's git runs, so it is
/// left by a git that died, never one still writing. Logged either way.
fn removeStaleTemporaryPack(io: std.Io, dir: std.Io.Dir, pack_dir: []const u8, name: []const u8, now_ms: i64) void {
    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| {
        keepCancel(io, err);
        return;
    };
    if (stat.kind != .file) return;
    const age_ms = now_ms - stat.mtime.toMilliseconds();
    if (age_ms < stale_lock_ms) return;
    if (dir.deleteFile(io, name)) {
        debug_trace.logf("workspace", "event=workspace_capture_temp_pack_removed dir={s} name={s} age_ms={d}", .{ pack_dir, name, age_ms });
    } else |err| {
        keepCancel(io, err);
        debug_trace.logf("workspace", "event=workspace_capture_temp_pack_remove_failed dir={s} name={s} err={s}", .{ pack_dir, name, @errorName(err) });
    }
}

/// One version 2 pack index: a header, a fan-out table of 256 counts, then
/// the sorted object IDs (git's `gitformat-pack`).
const PackIndex = struct {
    file: std.Io.File,
    fanout: [256]u32,
    /// Objects in the pack; 0 once the pack is left out.
    count: u32,
    hash_len: usize,
    /// The object table, read once lookups are many.
    table: ?[]u8 = null,
    lookups: usize = 0,

    const header_len = 8;
    const table_offset = header_len + 256 * 4;
    /// Lookups that are searched on disk before the table is read whole.
    const lookups_before_read = 64;

    /// Opens `name` in `dir` when its pack, `pack_name`, is there too and
    /// the index is a version 2 one of the store's object format.
    fn open(io: std.Io, dir: std.Io.Dir, name: []const u8, pack_name: []const u8, format: safe_git.ObjectFormat) !PackIndex {
        _ = try dir.statFile(io, pack_name, .{ .follow_symlinks = false });
        const file = try dir.openFile(io, name, .{});
        errdefer file.close(io);
        var header: [table_offset]u8 = undefined;
        if (try file.readPositionalAll(io, &header, 0) != header.len) return error.Truncated;
        if (!std.mem.eql(u8, header[0..4], "\xfftOc") or std.mem.readInt(u32, header[4..8], .big) != 2) return error.UnsupportedIndex;
        var index: PackIndex = .{ .file = file, .fanout = undefined, .count = 0, .hash_len = switch (format) {
            .sha1 => 20,
            .sha256 => 32,
        } };
        var previous: u32 = 0;
        for (&index.fanout, 0..) |*slot, i| {
            slot.* = std.mem.readInt(u32, header[header_len + i * 4 ..][0..4], .big);
            if (slot.* < previous) return error.Corrupt;
            previous = slot.*;
        }
        index.count = index.fanout[255];
        // The object IDs, a CRC and an offset for each, then the pack's and
        // the index's own checksums.
        const minimum = table_offset + @as(u64, index.count) * (index.hash_len + 8) + 2 * index.hash_len;
        if (try file.length(io) < minimum) return error.Truncated;
        return index;
    }

    fn close(self: *PackIndex, io: std.Io, scratch: Allocator) void {
        if (self.table) |table| scratch.free(table);
        self.file.close(io);
    }

    fn contains(self: *PackIndex, io: std.Io, scratch: Allocator, raw: []const u8) !bool {
        if (self.count == 0 or raw.len != self.hash_len) return false;
        self.lookups += 1;
        if (self.table == null and self.lookups > lookups_before_read) {
            const table = try scratch.alloc(u8, @as(usize, self.count) * self.hash_len);
            errdefer scratch.free(table);
            if (try self.file.readPositionalAll(io, table, table_offset) != table.len) return error.Truncated;
            self.table = table;
        }
        var low: usize = if (raw[0] == 0) 0 else self.fanout[raw[0] - 1];
        var high: usize = self.fanout[raw[0]];
        var buffer: [32]u8 = undefined;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const entry = if (self.table) |table| table[middle * self.hash_len ..][0..self.hash_len] else blk: {
                const slot = buffer[0..self.hash_len];
                if (try self.file.readPositionalAll(io, slot, table_offset + middle * self.hash_len) != slot.len) return error.Truncated;
                break :blk slot;
            };
            switch (std.mem.order(u8, entry, raw)) {
                .eq => return true,
                .lt => low = middle + 1,
                .gt => high = middle,
            }
        }
        return false;
    }
};

/// One `list_refs` line.
pub const RefLine = struct {
    /// `refs/spark/sessions/<key>/<worktree>`.
    name: []const u8,
    /// The session's `sessionKey`.
    key: []const u8,
    /// The worktree's key (`sessionRefName`).
    worktree: []const u8,
    /// The commit the ref names, SHA-1 or SHA-256.
    oid: []const u8,
    /// The newest capture's commit time.
    seconds: i64,
};

/// The length of each key in a capture ref: 16 bytes in hex (`pathKey`).
const ref_key_len = 32;

/// Parses one line of `list_refs` output,
/// `refs/spark/sessions/<key>/<worktree> <object> <unix seconds>`, where both
/// keys are `ref_key_len` lowercase hex characters and the object a SHA-1 or
/// SHA-256 ID. Null for anything else, such as an extra field or segment.
/// Slices borrow `line`.
pub fn parseRefLine(line: []const u8) ?RefLine {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const name = fields.next() orelse return null;
    const oid = fields.next() orelse return null;
    const seconds = std.fmt.parseInt(i64, fields.next() orelse return null, 10) catch return null;
    if (fields.next() != null) return null;
    const prefix = "refs/spark/sessions/";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    var segments = std.mem.splitScalar(u8, name[prefix.len..], '/');
    const key = segments.next() orelse return null;
    const worktree = segments.next() orelse return null;
    if (segments.next() != null or !isRefKey(key) or !isRefKey(worktree)) return null;
    if (!safe_git.isOid(oid, .sha1) and !safe_git.isOid(oid, .sha256)) return null;
    return .{ .name = name, .key = key, .worktree = worktree, .oid = oid, .seconds = seconds };
}

fn isRefKey(text: []const u8) bool {
    if (text.len != ref_key_len) return false;
    for (text) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// The commits of the newest `max_copy_exclusions` captures of `format` in
/// `list_refs` output (`parseRefLine`). A line that does not parse is
/// skipped: leaving a capture out only copies more.
fn newestCaptures(arena: Allocator, refs: []const u8, format: safe_git.ObjectFormat) Allocator.Error![]const []const u8 {
    const Entry = struct { commit: []const u8, seconds: i64 };
    var entries: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, refs, '\n');
    while (lines.next()) |line| {
        const parsed = parseRefLine(line) orelse continue;
        if (!safe_git.isOid(parsed.oid, format)) continue;
        try entries.append(arena, .{ .commit = parsed.oid, .seconds = parsed.seconds });
    }
    sort_utils.sort(Entry, entries.items, {}, struct {
        fn newer(_: void, a: Entry, b: Entry) bool {
            return a.seconds > b.seconds;
        }
    }.newer);
    const kept = entries.items[0..@min(entries.items.len, max_copy_exclusions)];
    const commits = try arena.alloc([]const u8, kept.len);
    for (kept, commits) |entry, *commit| commit.* = entry.commit;
    return commits;
}

/// The reason for a partial capture: the most telling exclusion that loses
/// content, whatever the paths' order. A file that vanished mid-capture
/// shows concurrent change, so it outranks limits, which outrank secrets,
/// which outrank submodules.
fn lossReason(excluded: []const policy.Exclusion) ?policy.Reason {
    const ranked = [_]struct { policy.Reason, @FieldType(policy.Exclusion, "reason") }{
        .{ .inconsistent, .missing },
        .{ .too_large, .too_large },
        .{ .file_limit, .file_limit },
        .{ .sensitive, .sensitive },
        .{ .submodule, .submodule },
    };
    var best: ?usize = null;
    for (excluded) |entry| {
        for (ranked, 0..) |rank, i| {
            if (entry.reason == rank[1] and (best == null or i < best.?)) best = i;
        }
    }
    return if (best) |i| ranked[i][0] else null;
}

pub const EncodeError = Allocator.Error || error{InvalidOutcome};

/// Excluded paths the record names one by one; the rest are only counted.
const max_sample_paths = 32;
const max_sample_bytes = 32 * 1024;

const ExclusionReason = @FieldType(policy.Exclusion, "reason");

/// The session's `workspace_capture` item for `outcome` at `phase`, as one
/// line of JSON (D98). Exclusions are counted by reason with a bounded
/// sample, so the item stays far below the 256 KiB a session item allows
/// however many paths a capture leaves out; a path that is not UTF-8 is
/// written as hex. Fails with `InvalidOutcome` when the outcome contradicts
/// itself. Returns owned bytes; the caller frees them.
pub fn encodeRecord(alloc: Allocator, phase: Phase, outcome: Outcome) EncodeError![]u8 {
    try checkOutcome(outcome);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var by_reason: Counts = .{};
    var sample: std.ArrayList(Sample) = .empty;
    var sample_bytes: usize = 0;
    var truncated = false;
    for (outcome.excluded) |entry| {
        switch (entry.reason) {
            .sensitive => by_reason.sensitive += 1,
            .too_large => by_reason.too_large += 1,
            .file_limit => by_reason.file_limit += 1,
            .missing => by_reason.missing += 1,
            .submodule => by_reason.submodule += 1,
        }
        const utf8 = std.unicode.utf8ValidateSlice(entry.path);
        const cost = if (utf8) entry.path.len else entry.path.len * 2;
        if (sample.items.len == max_sample_paths or sample_bytes + cost > max_sample_bytes) {
            truncated = true;
            continue;
        }
        sample_bytes += cost;
        try sample.append(arena, if (utf8)
            .{ .path = entry.path, .reason = entry.reason }
        else
            .{ .path_hex = try arena.print("{x}", .{entry.path}), .reason = entry.reason });
    }
    const record: RecordJson = .{
        .phase = phase,
        .status = outcome.status,
        .reason = outcome.reason,
        .work_tree = if (outcome.repository) |repo| repo.work_tree else null,
        .ref = outcome.ref,
        .head_state = outcome.head,
        .head = switch (outcome.head) {
            .commit => |oid| oid,
            else => null,
        },
        .tree = outcome.tree,
        .commit = outcome.commit,
        .object_format = outcome.object_format,
        .listing = outcome.listing,
        .index = outcome.index,
        .comparable = outcome.comparable,
        .trigger_tool = outcome.trigger_tool,
        .excluded = .{ .total = outcome.excluded.len, .by_reason = by_reason, .sample = sample.items, .sample_truncated = truncated },
    };
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    std.json.Stringify.value(record, .{}, &writer.writer) catch return error.OutOfMemory;
    return writer.toOwnedSlice();
}

const RecordJson = struct {
    v: u8 = 1,
    phase: Phase,
    status: Status,
    reason: ?policy.Reason,
    work_tree: ?[]const u8,
    ref: ?[]const u8,
    head_state: std.meta.Tag(Head),
    head: ?[]const u8,
    tree: ?[]const u8,
    commit: ?[]const u8,
    object_format: ?safe_git.ObjectFormat,
    listing: ?Listing,
    index: ?IndexStart,
    comparable: bool,
    trigger_tool: ?[]const u8,
    excluded: struct {
        total: usize,
        by_reason: Counts,
        sample: []const Sample,
        sample_truncated: bool,
    },
};

const Counts = struct {
    sensitive: usize = 0,
    too_large: usize = 0,
    file_limit: usize = 0,
    missing: usize = 0,
    submodule: usize = 0,
};

const Sample = struct {
    path: ?[]const u8 = null,
    path_hex: ?[]const u8 = null,
    reason: ExclusionReason,
};

/// Rejects an outcome whose status, reason and object IDs disagree, so a
/// record never claims a tree for a failure or a reason the status rules out.
fn checkOutcome(outcome: Outcome) error{InvalidOutcome}!void {
    switch (outcome.status) {
        .complete => if (outcome.reason != null or outcome.tree == null or outcome.commit == null) return error.InvalidOutcome,
        .partial => if (outcome.reason == null or outcome.tree == null or outcome.commit == null) return error.InvalidOutcome,
        .failed, .unavailable => if (outcome.reason == null or outcome.tree != null or outcome.commit != null) return error.InvalidOutcome,
    }
    if (outcome.reason) |reason| {
        const allowed = switch (reason) {
            .sensitive, .too_large, .file_limit, .submodule => outcome.status == .partial,
            .timeout, .not_git, .git_refused, .index_sparse, .capture_locked, .foreign_git_dir, .cancelled, .budget, .private_root, .untracked_timeout => outcome.status == .unavailable,
            .inconsistent => outcome.status == .partial or outcome.status == .failed,
            .io_error, .invalid_request => outcome.status == .failed,
        };
        if (!allowed) return error.InvalidOutcome;
    }
    const oids = [_]?[]const u8{ outcome.tree, outcome.commit, switch (outcome.head) {
        .commit => |oid| oid,
        else => null,
    } };
    for (oids) |maybe| if (maybe) |oid| {
        const format = outcome.object_format orelse return error.InvalidOutcome;
        if (!safe_git.isOid(oid, format)) return error.InvalidOutcome;
    };
}

const Lock = struct {
    file: std.Io.File,

    fn close(self: *Lock, io: std.Io) void {
        self.file.close(io);
    }
};

/// Takes the worktree's lock, waiting for another capture of the same
/// worktree, such as a parallel subagent's, until `deadline`. A cancel
/// request or a set `cancel` flag that ends the wait is `Unavailable`, and
/// a cancel request stays armed for the caller's next step.
pub fn acquireLock(io: std.Io, path: []const u8, deadline: std.Io.Clock.Timestamp, cancel: ?*const std.atomic.Value(bool)) error{ Busy, Unavailable }!Lock {
    return .{ .file = lockUntil(io, path, deadline, cancel) catch |err| return switch (err) {
        error.Canceled => error.Unavailable,
        else => |other| other,
    } };
}

/// How long a lock wait sleeps between tries.
const lock_poll_ns: u64 = 10 * std.time.ns_per_ms;

/// How long a capture waits for an existing store's `init.lock`.
/// Another capture holds it for milliseconds; maintenance holds it
/// for a whole repack, which the turn must not wait for.
const existing_store_wait_ms: i64 = 250;

/// Opens `path`, creating it, and takes an exclusive flock on it, trying
/// again until `deadline`. The kernel releases flock when its holder dies,
/// so a crash never leaves one held. `Busy` when the deadline passed first;
/// `Unavailable`, logged, when the file cannot be opened or locked;
/// `Canceled` once `cancel` is set or on a `std.Io` cancel request, which is
/// re-armed for the caller's next step.
fn lockUntil(io: std.Io, path: []const u8, deadline: std.Io.Clock.Timestamp, cancel: ?*const std.atomic.Value(bool)) error{ Busy, Unavailable, Canceled }!std.Io.File {
    const file = std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = false, .read = true }) catch |err| return lockFailed(io, path, err);
    errdefer file.close(io);
    while (!(file.tryLock(io, .exclusive) catch |err| return lockFailed(io, path, err))) {
        if (pastDeadline(io, deadline)) return error.Busy;
        if (cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
        io.sleep(.fromNanoseconds(lock_poll_ns), .awake) catch |err| return lockFailed(io, path, err);
    }
    return file;
}

fn lockFailed(io: std.Io, path: []const u8, err: anyerror) error{ Unavailable, Canceled } {
    if (err == error.Canceled) {
        io.recancel();
        return error.Canceled;
    }
    logIoError("lock", path, err);
    return error.Unavailable;
}

/// `lockUntil` for a worktree's lock. While `store_lock`, the existing
/// store's `init.lock`, is held too, maintenance is packing or pruning the
/// store with every worktree lock held, so the wait ends as `Busy` after
/// `existing_store_wait_ms` instead of at `deadline`. Another capture of the
/// worktree, such as a parallel subagent's, holds only the worktree lock and
/// is waited for until `deadline`.
fn lockWorktreeUntil(io: std.Io, path: []const u8, store_lock: ?[]const u8, deadline: std.Io.Clock.Timestamp, cancel: ?*const std.atomic.Value(bool)) error{ Busy, Unavailable, Canceled }!std.Io.File {
    const file = std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = false, .read = true }) catch |err| return lockFailed(io, path, err);
    errdefer file.close(io);
    var maintenance_until: ?std.Io.Clock.Timestamp = null;
    while (!(file.tryLock(io, .exclusive) catch |err| return lockFailed(io, path, err))) {
        if (pastDeadline(io, deadline)) return error.Busy;
        if (cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
        if (store_lock) |store_path| {
            if (try lockHeld(io, store_path)) {
                const until = maintenance_until orelse std.Io.Clock.Timestamp.fromNow(io, .{ .clock = deadline.clock, .raw = .fromMilliseconds(existing_store_wait_ms) });
                maintenance_until = until;
                if (pastDeadline(io, until)) return error.Busy;
            } else maintenance_until = null;
        }
        io.sleep(.fromNanoseconds(lock_poll_ns), .awake) catch |err| return lockFailed(io, path, err);
    }
    return file;
}

/// Whether another holder has the flock on `path`. The lock this takes to
/// look is released by the close.
fn lockHeld(io: std.Io, path: []const u8) error{ Unavailable, Canceled }!bool {
    const file = std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = false, .read = true }) catch |err| return lockFailed(io, path, err);
    defer file.close(io);
    return !(file.tryLock(io, .exclusive) catch |err| return lockFailed(io, path, err));
}

/// Whether `path` exists. Only a path the system reports missing is false;
/// any other failure, a cancel request included, is returned as it is and
/// not re-armed, so the caller decides. A check whose wrong "missing" would
/// create, replace or delete something must use this, never `exists`.
fn isPresent(io: std.Io, path: []const u8) std.Io.Dir.AccessError!bool {
    const denied = builtin.is_test and test_hooks.access_denied_suffix != null and std.mem.endsWith(u8, path, test_hooks.access_denied_suffix.?);
    const access: std.Io.Dir.AccessError!void = if (denied) error.AccessDenied else std.Io.Dir.accessAbsolute(io, path, .{});
    access catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// `isPresent`, or `fallback` when the check fails, with a cancel request
/// re-armed for the caller's next step.
fn presentOr(io: std.Io, path: []const u8, fallback: bool) bool {
    return isPresent(io, path) catch |err| {
        keepCancel(io, err);
        return fallback;
    };
}

/// Whether `path` exists, false when that cannot be checked. Only for a
/// check whose wrong answer deletes and creates nothing, such as which
/// stores to list; see `isPresent`.
pub fn exists(io: std.Io, path: []const u8) bool {
    return presentOr(io, path, false);
}

/// Re-arms a `std.Io` cancel request that `err` consumed, so the next
/// cancelation point, such as the next git run, still sees it. Call once for
/// each `error.Canceled` a helper swallows instead of returning, in the
/// capture path and in maintenance alike.
pub fn keepCancel(io: std.Io, err: anyerror) void {
    if (err == error.Canceled) io.recancel();
}

fn hasSharedIndex(io: std.Io, git_dir: []const u8) Allocator.Error!bool {
    // When the folder cannot be read, assume a split index: rebuilding from
    // HEAD is always correct, a copy of a split index is not.
    var dir = std.Io.Dir.openDirAbsolute(io, git_dir, .{ .iterate = true }) catch |err| {
        keepCancel(io, err);
        return true;
    };
    defer dir.close(io);
    var entries = dir.iterate();
    while (entries.next(io) catch |err| {
        keepCancel(io, err);
        return true;
    }) |entry| {
        if (std.mem.startsWith(u8, entry.name, "sharedindex.")) return true;
    }
    return false;
}

/// Makes sure the store exists with alternates into the user's objects. It is
/// built under a temporary name and renamed into place, so a store is either
/// absent or complete: a crash between `git init` and the alternates can never
/// leave a store that cannot read the user's objects. Everything happens under
/// a store-wide lock shared by the repository's worktrees. Null on success.
fn ensureStore(
    arena: Allocator,
    io: std.Io,
    ready: safe_git.StoreReady,
    store_dir: []const u8,
    git_dir: []const u8,
    common_dir: []const u8,
    format: safe_git.ObjectFormat,
    limits: safe_git.Limits,
    deadline: std.Io.Clock.Timestamp,
) Allocator.Error!?safe_git.Failure {
    const init_lock_path = try std.Io.Dir.path.join(arena, &.{ store_dir, "init.lock" });
    const init_lock = lockUntil(io, init_lock_path, deadline, limits.cancel) catch |err| return switch (err) {
        error.Busy => .timeout,
        error.Unavailable => .read_failed,
        error.Canceled => .cancelled,
    };
    defer init_lock.close(io);
    const alternates_line = try arena.print("{s}\n", .{try std.Io.Dir.path.join(arena, &.{ common_dir, "objects" })});
    // Only a HEAD the system reports missing means no store: a check that
    // fails otherwise, such as on a permission error or a cancel, must never
    // set a complete store aside to be deleted.
    const head = try std.Io.Dir.path.join(arena, &.{ git_dir, "HEAD" });
    if (isPresent(io, head) catch |err| return storeFailed(io, "store_check", head, err)) {
        // A store from before atomic creation may lack its alternates.
        const alternates = try std.Io.Dir.path.join(arena, &.{ git_dir, "objects", "info", "alternates" });
        if (!(isPresent(io, alternates) catch |err| return storeFailed(io, "store_check", alternates, err))) {
            writeAlternates(io, alternates, alternates_line) catch |err| return storeFailed(io, "store_alternates", alternates, err);
        }
        return null;
    }
    // A store folder without HEAD is a removal that stopped halfway; move it
    // aside so the rename below finds the name free. Its refs and objects
    // are what that removal meant to delete.
    if (isPresent(io, git_dir) catch |err| return storeFailed(io, "store_check", git_dir, err)) {
        const aside = try arena.print("{s}.tmp-aside-{d}", .{ git_dir, io_mod.nanoTimestamp() });
        std.Io.Dir.renameAbsolute(git_dir, aside, io) catch |err| return storeFailed(io, "store_set_aside", git_dir, err);
        debug_trace.logf("workspace", "event=workspace_capture_store_set_aside path={s} aside={s} reason=no_head", .{ git_dir, aside });
    }
    removeTemporaryStores(io, store_dir);
    const temporary = try arena.print("{s}.tmp-{d}", .{ git_dir, io_mod.nanoTimestamp() });
    switch (safe_git.initStore(arena, ready, temporary, format, limits) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArgument => return .spawn_failed,
    }) {
        .ok => {},
        .failed => |failure| return failure,
    }
    const info = try std.Io.Dir.path.join(arena, &.{ temporary, "objects", "info" });
    std.Io.Dir.cwd().createDirPath(io, info) catch |err| return storeFailed(io, "store_info", info, err);
    const alternates = try std.Io.Dir.path.join(arena, &.{ info, "alternates" });
    writeAlternates(io, alternates, alternates_line) catch |err| return storeFailed(io, "store_alternates", alternates, err);
    ensurePrivateDir(io, temporary) catch |err| return storeFailed(io, "store_private_dir", temporary, err);
    std.Io.Dir.renameAbsolute(temporary, git_dir, io) catch |err| return storeFailed(io, "store_rename", temporary, err);
    return null;
}

/// Logs a store check or write that failed outside git; the capture reports
/// it as `io_error`, or `cancelled` for a cancel request, which is re-armed.
fn storeFailed(io: std.Io, step: []const u8, path: []const u8, err: anyerror) safe_git.Failure {
    if (err == error.Canceled) {
        io.recancel();
        return .cancelled;
    }
    logIoError(step, path, err);
    return .read_failed;
}

fn writeAlternates(io: std.Io, path: []const u8, line: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = line, .flags = .{ .permissions = .fromMode(0o600) } });
}

/// Deletes stores a crash left half built and stores set aside without HEAD.
/// Called under the store lock. Each removal, and each failed one, is logged.
fn removeTemporaryStores(io: std.Io, store_dir: []const u8) void {
    var dir = std.Io.Dir.openDirAbsolute(io, store_dir, .{ .iterate = true }) catch |err| {
        keepCancel(io, err);
        logIoError("temp_store_list", store_dir, err);
        return;
    };
    defer dir.close(io);
    var entries = dir.iterate();
    while (entries.next(io) catch |err| {
        keepCancel(io, err);
        logIoError("temp_store_list", store_dir, err);
        return;
    }) |entry| {
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "store.git.tmp-")) {
            if (dir.deleteTree(io, entry.name)) {
                debug_trace.logf("workspace", "event=workspace_capture_temp_store_removed store={s} name={s}", .{ store_dir, entry.name });
            } else |err| {
                keepCancel(io, err);
                debug_trace.logf("workspace", "event=workspace_capture_temp_store_remove_failed store={s} name={s} err={s}", .{ store_dir, entry.name, @errorName(err) });
            }
        }
    }
}

/// Copies `from` to `to` through a temporary file and gives the copy the
/// original's modification time.
fn copyPreservingTime(arena: Allocator, io: std.Io, from: []const u8, to: []const u8) !void {
    var source = try std.Io.Dir.openFileAbsolute(io, from, .{});
    defer source.close(io);
    const stat = try source.stat(io);
    const bytes = try io_mod.readFileToEnd(arena, &source, max_index_bytes);
    const temporary = try arena.print("{s}.tmp", .{to});
    {
        var copy = try std.Io.Dir.createFileAbsolute(io, temporary, .{});
        defer copy.close(io);
        try copy.writeStreamingAll(io, bytes);
        try copy.setTimestamps(io, .{ .modify_timestamp = .{ .new = stat.mtime } });
    }
    try std.Io.Dir.renameAbsolute(temporary, to, io);
}

const max_index_bytes: usize = 1 << 30;

const Staged = safe_git.StagedEntry;

const Untracked = struct {
    files: []const []const u8,
    /// Folders holding their own repository, which git never enters.
    nested: []const []const u8,
};

const UntrackedListing = union(enum) {
    listed: Untracked,
    /// The deadline passed before a listing finished.
    stopped,
    /// No listing could be made.
    failed,
    /// The cancel flag ended git's listing.
    cancelled,
};

/// Untracked paths relative to the worktree root, outside `skip_folder`: the
/// native indexer's listing, or git's when the indexer cannot list exactly
/// what git would. Both stop at `limits`' deadline and at its cancel flag.
/// Records the source in `outcome.listing`.
fn listUntracked(
    arena: Allocator,
    scan_allocator: Allocator,
    ready: safe_git.Ready,
    facts: safe_git.RepositoryFacts,
    skip_folder: ?[]const u8,
    limits: safe_git.Limits,
    tracked: *const std.StringHashMapUnmanaged(Staged),
    outcome: *Outcome,
) Allocator.Error!UntrackedListing {
    const io = io_mod.getIo();
    const deadline = limits.deadline.?;
    if (pastDeadline(io, deadline)) return .stopped;
    // The indexer skips folders only outside a repository, so git lists
    // when a folder must be skipped; it never enters that folder.
    if (skip_folder == null) if (try listWithIndexer(arena, scan_allocator, facts, deadline, limits.cancel, tracked)) |listing| {
        if (listing == .listed) outcome.listing = .indexer;
        return listing;
    };
    // git starts only while time remains.
    if (pastDeadline(io, deadline)) return .stopped;
    const listing = try listWithGit(arena, ready, facts.work_tree, skip_folder, limits);
    if (listing == .listed) outcome.listing = .git;
    return listing;
}

/// The indexer's untracked listing, or null when git must list instead:
/// no task can stop the scan, or the indexer left something out or would
/// spell a name differently from git.
fn listWithIndexer(
    arena: Allocator,
    scan_allocator: Allocator,
    facts: safe_git.RepositoryFacts,
    deadline: std.Io.Clock.Timestamp,
    cancel: ?*const std.atomic.Value(bool),
    tracked: *const std.StringHashMapUnmanaged(Staged),
) Allocator.Error!?UntrackedListing {
    const io = io_mod.getIo();
    // Where git compares paths without case, a case-only rename shows up as
    // a new untracked spelling of a tracked file; git does not list it.
    var folded: std.StringHashMapUnmanaged(void) = .empty;
    if (facts.ignore_case) {
        var it = tracked.keyIterator();
        while (it.next()) |path| try folded.put(arena, try std.ascii.allocLowerString(arena, path.*), {});
    }
    // The indexer's workers check the stop time themselves; a task that
    // raised a flag at the deadline could wake late while the scan holds
    // every core, as it did on Linux.
    const remaining_ns = std.Io.Clock.Timestamp.now(io, deadline.clock).durationTo(deadline).raw.toNanoseconds();
    const stop_at_ns: i64 = @intCast(std.math.clamp(@as(i128, io_mod.nanoTimestamp()) + remaining_ns, std.math.minInt(i64), std.math.maxInt(i64)));
    var result = indexer.scan(scan_allocator, facts.work_tree, .{ .candidate_cap = max_listed_paths, .stop_at_ns = stop_at_ns }, cancel) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => {
            if (cancel) |flag| if (flag.load(.acquire)) return .cancelled;
            return .stopped;
        },
        error.RootUnavailable => return null,
    };
    defer result.deinit();
    if (pastDeadline(io, deadline)) return .stopped;
    const listing = result.tree;
    // Anything the indexer left out sends the listing to git.
    if (listing.incomplete or listing.cap_reached or listing.skipped_overlong > 0 or !listing.repository) return null;
    var files: std.ArrayList([]const u8) = .empty;
    var nested: std.ArrayList([]const u8) = .empty;
    // A folder the indexer listed but did not enter holds its own
    // repository, exactly where git stops too.
    for (listing.folders) |folder| {
        if (folder.boundary and !tracked.contains(folder.rel)) try nested.append(arena, try arena.dupe(u8, folder.rel));
    }
    for (listing.entries, 0..) |entry, i| {
        if (i % 4096 == 4095 and pastDeadline(io, deadline)) return .stopped;
        if (tracked.contains(entry.path)) continue;
        // The indexer lists file names as the folder stores them; with
        // precomposed Unicode git compares another form of those names.
        if (facts.precompose_unicode and !isAscii(entry.path)) return null;
        switch (entry.kind) {
            .file => {
                if (facts.ignore_case and folded.contains(try std.ascii.allocLowerString(arena, entry.path))) continue;
                try files.append(arena, try arena.dupe(u8, entry.path));
            },
            .directory => {},
        }
    }
    return .{ .listed = .{ .files = files.items, .nested = nested.items } };
}

/// git's untracked listing outside `skip_folder`, which stops at `limits`.
fn listWithGit(arena: Allocator, ready: safe_git.Ready, work_tree: []const u8, skip_folder: ?[]const u8, limits: safe_git.Limits) Allocator.Error!UntrackedListing {
    const listing = switch (try safe_git.listRepository(arena, ready, work_tree, .untracked, skip_folder, limits)) {
        .ok => |stdout| stdout,
        .failed => |failure| return switch (failure) {
            .timeout => .stopped,
            .cancelled => .cancelled,
            else => .failed,
        },
    };
    var files: std.ArrayList([]const u8) = .empty;
    var nested: std.ArrayList([]const u8) = .empty;
    var records = std.mem.splitScalar(u8, listing, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        // git lists a nested repository once, as a folder with a slash.
        if (record[record.len - 1] == '/') {
            try nested.append(arena, record[0 .. record.len - 1]);
        } else {
            try files.append(arena, record);
        }
    }
    return .{ .listed = .{ .files = files.items, .nested = nested.items } };
}

fn isAscii(text: []const u8) bool {
    for (text) |c| if (c >= 0x80) return false;
    return true;
}

const max_listed_paths: usize = 1_000_000;

const Found = struct {
    present: bool,
    bytes: u64 = 0,
    kind: @FieldType(policy.Candidate, "kind") = .file,
};

const not_on_disk: Found = .{ .present = false };

/// What the disk holds at worktree paths, without following symlinks at any
/// level: a path under a symlinked folder is absent, as git sees it.
const Disk = struct {
    arena: Allocator,
    io: std.Io,
    work_tree: []const u8,
    /// Parent folders already checked: true when a real folder.
    parents: std.StringHashMapUnmanaged(bool) = .empty,

    /// Fails only when the disk cannot answer, such as a folder without read
    /// permission, or on a cancel request, which is re-armed; a missing path
    /// is `absent`.
    fn lstat(self: *Disk, path: []const u8) (Allocator.Error || error{ Unreadable, Canceled })!Found {
        var end: usize = 0;
        while (std.mem.findScalarPos(u8, path, end, '/')) |slash| : (end = slash + 1) {
            const parent = path[0..slash];
            const real = self.parents.get(parent) orelse blk: {
                const found = try self.statOne(parent);
                const is_dir = found.present and found.kind == .gitlink;
                try self.parents.put(self.arena, parent, is_dir);
                break :blk is_dir;
            };
            if (!real) return not_on_disk;
        }
        return self.statOne(path);
    }

    fn statOne(self: *Disk, path: []const u8) (Allocator.Error || error{ Unreadable, Canceled })!Found {
        const absolute = try std.Io.Dir.path.join(self.arena, &.{ self.work_tree, path });
        const stat = std.Io.Dir.cwd().statFile(self.io, absolute, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return not_on_disk,
            error.Canceled => {
                self.io.recancel();
                return error.Canceled;
            },
            else => {
                logIoError("stat", absolute, err);
                return error.Unreadable;
            },
        };
        return switch (stat.kind) {
            .sym_link => .{ .present = true, .bytes = stat.size, .kind = .symlink },
            .file => .{ .present = true, .bytes = stat.size, .kind = .file },
            // Callers decide what a folder means: a gitlink, or a gone file.
            .directory => .{ .present = true, .kind = .gitlink },
            // git records neither pipes, sockets nor devices.
            else => not_on_disk,
        };
    }

    /// Whether the regular file at `path` starts with a PEM private key:
    /// "PRIVATE KEY-----" within its first 4096 bytes. A file that cannot
    /// be opened or is no longer a regular file counts as not a key.
    fn holdsPrivateKey(self: *Disk, path: []const u8) (Allocator.Error || error{Canceled})!bool {
        const absolute = try std.Io.Dir.path.join(self.arena, &.{ self.work_tree, path });
        var file = io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), absolute, .no_follow) catch |err| switch (err) {
            error.Canceled => {
                self.io.recancel();
                return error.Canceled;
            },
            else => return false,
        };
        defer file.close(self.io);
        var buf: [4096]u8 = undefined;
        const n = file.readPositionalAll(self.io, &buf, 0) catch |err| switch (err) {
            error.Canceled => {
                self.io.recancel();
                return error.Canceled;
            },
            else => return false,
        };
        return std.mem.find(u8, buf[0..n], "PRIVATE KEY-----") != null;
    }
};

/// The directory for the repository whose common git directory is
/// `common_dir`: it holds the bare store (`storeGitDir`) and, beside it, one
/// directory per worktree. The worktree directories stay outside the bare
/// repository because git reserves its `worktrees/` folder and `git gc` prunes
/// it. Owned by `arena`.
fn storeDir(arena: Allocator, profile_root: []const u8, common_dir: []const u8) Allocator.Error![]const u8 {
    return std.Io.Dir.path.join(arena, &.{ profile_root, "captures", try pathKey(arena, common_dir) });
}

/// The bare store inside a repository's `storeDir`. Owned by `arena`.
pub fn storeGitDir(arena: Allocator, store_dir: []const u8) Allocator.Error![]const u8 {
    return std.Io.Dir.path.join(arena, &.{ store_dir, "store.git" });
}

/// The directory that holds one worktree's capture index, lock and scratch
/// files inside its repository's store directory, for the worktree whose
/// `worktreeIdentity` is `worktree`. Owned by `arena`.
fn worktreeDir(arena: Allocator, store_dir: []const u8, worktree: []const u8) Allocator.Error![]const u8 {
    return std.Io.Dir.path.join(arena, &.{ store_dir, "worktrees", try pathKey(arena, worktree) });
}

fn pathKey(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &digest, .{});
    return arena.print("{x}", .{digest[0..16]});
}

pub const CopyRequest = struct {
    /// The spark profile root, such as `~/.spark`.
    profile_root: []const u8,
    /// The session whose captures are copied. Its refs are only read.
    from_session_id: []const u8,
    /// The session that receives them, such as a fork of `from_session_id`.
    to_session_id: []const u8,
    /// One budget for every store.
    deadline: std.Io.Clock.Timestamp,
};

/// What `copySessionRefs` did, counted in refs and stores.
pub const CopyResult = struct {
    /// Refs created for the receiving session.
    copied: usize = 0,
    /// Refs the receiving session already had at the same commit, such as
    /// from an earlier copy.
    existing: usize = 0,
    /// Refs the receiving session already had at another commit, which stay
    /// as they are.
    conflicting: usize = 0,
    /// Refs that could not be created, such as one a stale lock blocks; the
    /// store's other refs are still copied.
    failed_refs: usize = 0,
    /// Stores that could not be locked or listed, or stayed locked past the
    /// deadline; refs not copied from them are not counted.
    failed_stores: usize = 0,
};

pub const CopyError = Allocator.Error || error{InvalidRequest};

/// Gives `to_session_id` every capture `from_session_id` has, for a fork:
/// each of the first session's refs, in every repository's store, gets a
/// twin under the second session's key that names the same commit, so the
/// fork's captures stay when the original's are evicted. It only creates
/// refs, never moves or deletes one, so the first session's refs are never
/// touched and a second run changes nothing. Each store is handled under its
/// `init.lock`, which pruning holds, so no commit is pruned between listing
/// it and naming it. Memory belongs to `arena`.
pub fn copySessionRefs(arena: Allocator, request: CopyRequest) CopyError!CopyResult {
    if (!session_adapter.validSessionId(request.from_session_id) or !session_adapter.validSessionId(request.to_session_id) or
        std.mem.eql(u8, request.from_session_id, request.to_session_id) or
        !std.Io.Dir.path.isAbsolute(request.profile_root)) return error.InvalidRequest;
    const io = io_mod.getIo();
    var result: CopyResult = .{};
    const stores = try listStoreDirs(arena, io, try std.Io.Dir.path.join(arena, &.{ request.profile_root, "captures" }));
    if (stores.len == 0) return result;
    const limits: safe_git.Limits = .{ .deadline = request.deadline };
    const ready = switch (try safe_git.prepareStore(arena, limits)) {
        .ready => |value| value,
        .refused => {
            result.failed_stores = stores.len;
            return result;
        },
    };
    const from_prefix = try arena.print("refs/spark/sessions/{s}/", .{try sessionKey(arena, request.from_session_id)});
    const to_key = try sessionKey(arena, request.to_session_id);
    for (stores) |store_dir| {
        if (!try copyStoreRefs(arena, io, ready, store_dir, from_prefix, to_key, request.deadline, &result)) result.failed_stores += 1;
    }
    return result;
}

/// Copies the refs under `from_prefix` in one store to `to_key`. A ref that
/// cannot be created is counted in `failed_refs` and the rest are still
/// tried. False when the store could not be locked or listed.
fn copyStoreRefs(
    arena: Allocator,
    io: std.Io,
    ready: safe_git.StoreReady,
    store_dir: []const u8,
    from_prefix: []const u8,
    to_key: []const u8,
    deadline: std.Io.Clock.Timestamp,
    result: *CopyResult,
) Allocator.Error!bool {
    const lock = lockUntil(io, try initLockPath(arena, store_dir), deadline, null) catch return false;
    defer lock.close(io);
    const limits: safe_git.Limits = .{ .deadline = deadline };
    const store = try refStore(arena, store_dir);
    const listing = switch (try storeOutput(arena, ready, store, .list_refs, limits)) {
        .ok => |stdout| stdout,
        .failed => return false,
    };
    const Source = struct { worktree: []const u8, oid: []const u8 };
    var sources: std.ArrayList(Source) = .empty;
    var existing: std.StringHashMapUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        const parsed = parseRefLine(line) orelse continue;
        if (std.mem.startsWith(u8, parsed.name, from_prefix)) {
            try sources.append(arena, .{ .worktree = parsed.worktree, .oid = parsed.oid });
        } else {
            try existing.put(arena, parsed.name, parsed.oid);
        }
    }
    for (sources.items) |source| {
        const target = try arena.print("refs/spark/sessions/{s}/{s}", .{ to_key, source.worktree });
        if (existing.get(target)) |oid| {
            if (std.mem.eql(u8, oid, source.oid)) result.existing += 1 else result.conflicting += 1;
            continue;
        }
        // A null `old` creates the ref only if it does not exist yet.
        switch (try storeOutput(arena, ready, store, .{ .update_ref = .{ .ref = target, .new = source.oid, .old = null } }, limits)) {
            .ok => result.copied += 1,
            .failed => |failure| {
                result.failed_refs += 1;
                debug_trace.logf("workspace", "event=workspace_capture_ref_copy_failed store={s} ref={s} failure={s}", .{ store_dir, target, @tagName(failure) });
            },
        }
    }
    return true;
}

/// A store's git directory for ref commands, which touch neither an index
/// nor a worktree; git still needs both names, so they point inside the
/// store's folder.
pub fn refStore(arena: Allocator, store_dir: []const u8) Allocator.Error!safe_git.Store {
    return .{
        .git_dir = try storeGitDir(arena, store_dir),
        .index_file = try std.Io.Dir.path.join(arena, &.{ store_dir, "refs.index" }),
        .work_tree = store_dir,
        .scratch_dir = store_dir,
    };
}

/// The repository folders under `captures` whose store is complete, in name
/// order.
pub fn listStoreDirs(arena: Allocator, io: std.Io, captures: []const u8) Allocator.Error![]const []const u8 {
    var stores: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.openDirAbsolute(io, captures, .{ .iterate = true }) catch |err| {
        keepCancel(io, err);
        return stores.items;
    };
    defer dir.close(io);
    var entries = dir.iterate();
    while (entries.next(io) catch |err| blk: {
        keepCancel(io, err);
        break :blk null;
    }) |entry| {
        if (entry.kind != .directory or entry.name.len != 32) continue;
        const store_dir = try std.Io.Dir.path.join(arena, &.{ captures, entry.name });
        if (exists(io, try std.Io.Dir.path.join(arena, &.{ store_dir, "store.git", "HEAD" }))) try stores.append(arena, store_dir);
    }
    sort_utils.sort([]const u8, stores.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return stores.items;
}

/// The store-wide lock a capture holds from before it writes the store's
/// first object (`ensureStore`). Owned by `arena`.
pub fn initLockPath(arena: Allocator, store_dir: []const u8) Allocator.Error![]const u8 {
    return std.Io.Dir.path.join(arena, &.{ store_dir, "init.lock" });
}

/// The folder that holds every `worktreeDir` of a store. Owned by `arena`.
pub fn worktreesDir(arena: Allocator, store_dir: []const u8) Allocator.Error![]const u8 {
    return std.Io.Dir.path.join(arena, &.{ store_dir, "worktrees" });
}

/// The file names of a worktree directory's capture lock and capture index.
pub const worktree_lock_name = "lock";
pub const worktree_index_name = "index";

// ---- Tests below this line ----

const testing = std.testing;

/// Plain git for fixtures and oracles. The capture itself finds its own git.
const test_git = "/usr/bin/git";
const test_unix_seconds: i64 = 1_700_000_000;
const test_deadline_ms: i64 = 20_000;
const fixture_identity = [_][]const u8{ "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid" };
/// Programs a repository could name stay off in oracles and probes.
const oracle_overrides = [_][]const u8{ "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null" };

const EnvPair = struct { []const u8, []const u8 };

/// Real repositories under one temporary folder. spark's environment, which
/// `safe_git.environment()` reads through `io_mod.getenv`, and the fixtures'
/// git both point HOME and the global config at files inside it and turn the
/// system config off, so neither the developer's nor the machine's git config
/// reaches a test. The global config has no identity: capture commits must
/// not depend on one.
const TestRepos = struct {
    arena: Allocator,
    root: []const u8,
    home: []const u8,
    profile: []const u8,
    global_config: []const u8,
    sentinel: []const u8,
    sentinel_log: []const u8,
    env: *std.process.Environ.Map,

    fn init(arena: Allocator, dir: std.Io.Dir) !TestRepos {
        if (builtin.target.os.tag == .windows) return error.SkipZigTest;
        std.Io.Dir.accessAbsolute(testing.io, test_git, .{}) catch return error.SkipZigTest;
        switch (try safe_git.prepareStore(arena, .{})) {
            .ready => {},
            .refused => return error.SkipZigTest,
        }
        const root = try io_mod.dirRealpathAlloc(arena, dir, ".");
        const home = try std.Io.Dir.path.join(arena, &.{ root, "home" });
        const env = try arena.create(std.process.Environ.Map);
        env.* = std.process.Environ.Map.init(arena);
        const self: TestRepos = .{
            .arena = arena,
            .root = root,
            .home = home,
            .profile = try std.Io.Dir.path.join(arena, &.{ root, "profile" }),
            .global_config = try std.Io.Dir.path.join(arena, &.{ home, ".gitconfig" }),
            .sentinel = try std.Io.Dir.path.join(arena, &.{ root, "sentinel.sh" }),
            .sentinel_log = try std.Io.Dir.path.join(arena, &.{ root, "sentinel.log" }),
            .env = env,
        };
        try std.Io.Dir.cwd().createDirPath(testing.io, home);
        try std.Io.Dir.cwd().createDirPath(testing.io, self.profile);
        try writeAbsolute(self.global_config, "[init]\n\tdefaultBranch = main\n[protocol \"file\"]\n\tallow = always\n");
        try env.put("HOME", home);
        try env.put("XDG_CONFIG_HOME", try std.Io.Dir.path.join(arena, &.{ home, ".config" }));
        try env.put("GIT_CONFIG_GLOBAL", self.global_config);
        try env.put("GIT_CONFIG_NOSYSTEM", "1");
        if (!try self.fixtureGitSupported()) return error.SkipZigTest;
        io_mod.setEnvironMap(env);
        return self;
    }

    fn deinit(self: TestRepos) void {
        _ = self;
        io_mod.resetEnvironForTest();
    }

    /// The fixtures use `--path-format`, `init -b` and `--sparse-index`.
    fn fixtureGitSupported(self: TestRepos) !bool {
        const result = try self.run(self.root, &.{ test_git, "--version" }, &.{});
        switch (result.term) {
            .exited => |code| if (code != 0) return false,
            else => return false,
        }
        const prefix = "git version ";
        if (!std.mem.startsWith(u8, result.stdout, prefix)) return false;
        var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, result.stdout[prefix.len..], "\n"), '.');
        const major = std.fmt.parseInt(u32, parts.next() orelse return false, 10) catch return false;
        const minor_text = parts.next() orelse return false;
        var end: usize = 0;
        while (end < minor_text.len and std.ascii.isDigit(minor_text[end])) end += 1;
        const minor = std.fmt.parseInt(u32, minor_text[0..end], 10) catch return false;
        return major > 2 or (major == 2 and minor >= 32);
    }

    fn path(self: TestRepos, sub_path: []const u8) ![]const u8 {
        return std.Io.Dir.path.join(self.arena, &.{ self.root, sub_path });
    }

    // Files, by path relative to the temporary folder.

    fn writeAbsolute(absolute: []const u8, data: []const u8) !void {
        if (std.Io.Dir.path.dirname(absolute)) |parent| try std.Io.Dir.cwd().createDirPath(testing.io, parent);
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = absolute, .data = data });
    }

    fn write(self: TestRepos, sub_path: []const u8, data: []const u8) !void {
        try writeAbsolute(try self.path(sub_path), data);
    }

    fn append(self: TestRepos, sub_path: []const u8, data: []const u8) !void {
        const old = self.read(sub_path) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        try self.write(sub_path, try std.mem.concat(self.arena, u8, &.{ old, data }));
    }

    fn read(self: TestRepos, sub_path: []const u8) ![]const u8 {
        return readAbsolute(self.arena, try self.path(sub_path));
    }

    fn readAbsolute(arena: Allocator, absolute: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, absolute, arena, .limited(64 * 1024 * 1024));
    }

    fn chmod(self: TestRepos, sub_path: []const u8, mode: std.posix.mode_t) !void {
        try std.Io.Dir.cwd().setFilePermissions(testing.io, try self.path(sub_path), .fromMode(mode), .{});
    }

    fn remove(self: TestRepos, sub_path: []const u8) !void {
        try std.Io.Dir.deleteFileAbsolute(testing.io, try self.path(sub_path));
    }

    fn rename(self: TestRepos, old: []const u8, new: []const u8) !void {
        try std.Io.Dir.renameAbsolute(try self.path(old), try self.path(new), testing.io);
    }

    fn symlink(self: TestRepos, target: []const u8, sub_path: []const u8) !void {
        try std.Io.Dir.cwd().symLink(testing.io, target, try self.path(sub_path), .{});
    }

    fn exists(self: TestRepos, sub_path: []const u8) !bool {
        return existsAbsolute(try self.path(sub_path));
    }

    fn existsAbsolute(absolute: []const u8) !bool {
        _ = std.Io.Dir.cwd().statFile(testing.io, absolute, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    fn deleteIfPresent(absolute: []const u8) !void {
        std.Io.Dir.deleteFileAbsolute(testing.io, absolute) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    fn setModified(self: TestRepos, sub_path: []const u8, unix_seconds: i64) !void {
        const at: std.Io.Timestamp = .{ .nanoseconds = @as(i96, unix_seconds) * std.time.ns_per_s };
        try std.Io.Dir.cwd().setTimestamps(testing.io, try self.path(sub_path), .{ .access_timestamp = .{ .new = at }, .modify_timestamp = .{ .new = at } });
    }

    /// Like `cp -p`: the copy keeps the source's modification time, so git's
    /// racy-timestamp check behaves as it does on the original index.
    fn copyKeepingTime(self: TestRepos, source: []const u8, dest: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = dest, .data = try readAbsolute(self.arena, source) });
        const stat = try std.Io.Dir.cwd().statFile(testing.io, source, .{});
        try std.Io.Dir.cwd().setTimestamps(testing.io, dest, .{ .access_timestamp = .init(stat.atime), .modify_timestamp = .{ .new = stat.mtime } });
    }

    fn randomBytes(self: TestRepos, len: usize, seed: u64) ![]const u8 {
        const bytes = try self.arena.alloc(u8, len);
        var prng = std.Random.DefaultPrng.init(seed);
        prng.random().bytes(bytes);
        return bytes;
    }

    // Processes.

    fn run(self: TestRepos, cwd: []const u8, argv: []const []const u8, extra: []const EnvPair) !std.process.RunResult {
        var env = std.process.Environ.Map.init(self.arena);
        try env.put("PATH", "/usr/bin:/bin");
        try env.put("LC_ALL", "C");
        try env.put("GIT_TERMINAL_PROMPT", "0");
        // A fixture command never climbs out of the temporary folder into the
        // checkout that holds it.
        try env.put("GIT_CEILING_DIRECTORIES", self.root);
        var keys = self.env.iterator();
        while (keys.next()) |entry| try env.put(entry.key_ptr.*, entry.value_ptr.*);
        for (extra) |pair| try env.put(pair[0], pair[1]);
        return std.process.run(self.arena, testing.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .environ_map = &env,
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
    }

    fn gitArgv(self: TestRepos, args: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.arena, test_git);
        try argv.appendSlice(self.arena, args);
        return argv.items;
    }

    /// Runs plain git and returns its trimmed stdout. Any failure fails the
    /// fixture, never the capture under test, and prints git's stderr.
    fn gitEnv(self: TestRepos, cwd: []const u8, args: []const []const u8, extra: []const EnvPair) ![]const u8 {
        const result = try self.run(cwd, try self.gitArgv(args), extra);
        switch (result.term) {
            .exited => |code| if (code == 0) return std.mem.trimEnd(u8, result.stdout, "\n"),
            else => {},
        }
        std.debug.print("fixture git", .{});
        for (args) |arg| std.debug.print(" {s}", .{arg});
        std.debug.print(" failed in {s}: {s}\n", .{ cwd, result.stderr });
        return error.FixtureGitFailed;
    }

    fn git(self: TestRepos, cwd: []const u8, args: []const []const u8) ![]const u8 {
        return self.gitEnv(cwd, args, &.{});
    }

    fn gitIn(self: TestRepos, sub_path: []const u8, args: []const []const u8) ![]const u8 {
        return self.git(try self.path(sub_path), args);
    }

    fn commit(self: TestRepos, sub_path: []const u8, message: []const u8) !void {
        _ = try self.gitIn(sub_path, &(fixture_identity ++ [_][]const u8{ "commit", "-q", "-m", message }));
    }

    fn commitAll(self: TestRepos, sub_path: []const u8, message: []const u8) !void {
        _ = try self.gitIn(sub_path, &(fixture_identity ++ [_][]const u8{ "commit", "-q", "-am", message }));
    }

    fn initRepo(self: TestRepos, sub_path: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(testing.io, try self.path(sub_path));
        _ = try self.gitIn(sub_path, &.{ "init", "-q", "-b", "main" });
    }

    /// The paths a capture reads, as git itself resolves them.
    fn repository(self: TestRepos, sub_path: []const u8) !Repository {
        const out = try self.gitIn(sub_path, &.{ "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir" });
        var lines = std.mem.splitScalar(u8, out, '\n');
        return .{
            .work_tree = lines.next() orelse return error.FixtureGitFailed,
            .git_dir = lines.next() orelse return error.FixtureGitFailed,
            .common_dir = lines.next() orelse return error.FixtureGitFailed,
        };
    }

    // Capture and store.

    fn request(self: TestRepos, repo: Repository, session_id: []const u8, limits: policy.Limits) Request {
        return .{
            .profile_root = self.profile,
            .path = repo.work_tree,
            .session_id = session_id,
            .phase = .start,
            .unix_seconds = test_unix_seconds,
            .deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(test_deadline_ms) }),
            .limits = limits,
            .scan_allocator = testing.allocator,
        };
    }

    fn captureRepo(self: TestRepos, repo: Repository, session_id: []const u8) !Outcome {
        return capture(self.arena, self.request(repo, session_id, .{}));
    }

    /// The ref a capture of `repo` for `session_id` extends.
    fn sessionRef(self: TestRepos, repo: Repository, session_id: []const u8) ![]const u8 {
        return sessionRefName(self.arena, session_id, try worktreeIdentity(self.arena, repo));
    }

    fn store(self: TestRepos, repo: Repository) ![]const u8 {
        return storeGitDir(self.arena, try storeDir(self.arena, self.profile, repo.common_dir));
    }

    fn storeGit(self: TestRepos, repo: Repository, args: []const []const u8) ![]const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.arena, &.{ "--git-dir", try self.store(repo) });
        try argv.appendSlice(self.arena, args);
        return self.git(self.root, argv.items);
    }

    /// One file of a stored tree, read from the store.
    fn storedFile(self: TestRepos, repo: Repository, tree: []const u8, file: []const u8) ![]const u8 {
        return self.storeGit(repo, &.{ "cat-file", "blob", try self.arena.print("{s}:{s}", .{ tree, file }) });
    }

    fn treeHas(self: TestRepos, repo: Repository, tree: []const u8, file: []const u8) !bool {
        return (try self.storeGit(repo, &.{ "ls-tree", "--name-only", tree, "--", file })).len != 0;
    }

    /// The object a store ref names, or null when the store or ref is missing.
    fn storeRef(self: TestRepos, repo: Repository, ref: []const u8) !?[]const u8 {
        const store_dir = try self.store(repo);
        if (!try existsAbsolute(store_dir)) return null;
        const result = try self.run(self.root, try self.gitArgv(&.{ "--git-dir", store_dir, "rev-parse", "-q", "--verify", ref }), &.{});
        return switch (result.term) {
            .exited => |code| if (code == 0) std.mem.trimEnd(u8, result.stdout, "\n") else null,
            else => null,
        };
    }

    fn storeRefs(self: TestRepos, repo: Repository) ![]const u8 {
        if (!try existsAbsolute(try self.store(repo))) return "";
        return self.storeGit(repo, &.{ "for-each-ref", "--format=%(refname) %(objectname)" });
    }

    /// Runs git on the store with its alternates moved aside, so only the
    /// objects the store holds itself count. They come back afterwards.
    fn storeAlone(self: TestRepos, repo: Repository, args: []const []const u8) ![]const u8 {
        const alternates = try std.Io.Dir.path.join(self.arena, &.{ try self.store(repo), "objects", "info", "alternates" });
        const aside = try self.path("alternates.aside");
        try std.Io.Dir.renameAbsolute(alternates, aside, testing.io);
        defer std.Io.Dir.renameAbsolute(aside, alternates, testing.io) catch {};
        return self.storeGit(repo, args);
    }

    /// Whether `oid` can still be read from the user's repository.
    fn userHas(self: TestRepos, repo: Repository, oid: []const u8) !bool {
        return self.succeeds(repo.work_tree, &.{ "cat-file", "-e", oid });
    }

    /// Whether the store holds `oid` itself, without its alternates.
    fn storeAloneHas(self: TestRepos, repo: Repository, oid: []const u8) !bool {
        const alternates = try std.Io.Dir.path.join(self.arena, &.{ try self.store(repo), "objects", "info", "alternates" });
        const aside = try self.path("alternates.aside");
        try std.Io.Dir.renameAbsolute(alternates, aside, testing.io);
        defer std.Io.Dir.renameAbsolute(aside, alternates, testing.io) catch {};
        return self.succeeds(self.root, &.{ "--git-dir", try self.store(repo), "cat-file", "-e", oid });
    }

    fn succeeds(self: TestRepos, cwd: []const u8, args: []const []const u8) !bool {
        const result = try self.run(cwd, try self.gitArgv(args), &.{});
        return switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    /// Proves the store alone, without its alternates, reaches every object
    /// of every capture ref and holds `file` of `tree` as `content`.
    fn expectSelfSufficient(self: TestRepos, repo: Repository, tree: []const u8, file: []const u8, content: []const u8) !void {
        _ = try self.storeAlone(repo, &.{ "fsck", "--connectivity-only", "--no-dangling", "--no-progress" });
        // `git` trims the output's final newline.
        try testing.expectEqualStrings(std.mem.trimEnd(u8, content, "\n"), try self.storeAlone(repo, &.{ "cat-file", "blob", try self.arena.print("{s}:{s}", .{ tree, file }) }));
    }

    /// Deletes every object the user's repository no longer reaches, as
    /// `git gc --prune=now` after dropping a branch or a staged change does.
    fn pruneUser(self: TestRepos, sub_path: []const u8) !void {
        _ = try self.gitIn(sub_path, &.{ "reflog", "expire", "--expire=now", "--all" });
        _ = try self.gitIn(sub_path, &.{ "gc", "-q", "--prune=now" });
        _ = try self.gitIn(sub_path, &.{ "prune", "--expire=now" });
    }

    // Oracles.

    /// The tree the user's own git records for the worktree as it is now:
    /// `git add -A` and `write-tree` on a copy of the worktree's index that
    /// keeps its time, minus the paths the capture leaves out on purpose.
    /// New objects go to a scratch object directory, so the oracle writes
    /// nothing into the user's repository or the store.
    fn expectedTree(self: TestRepos, repo: Repository, excluded: []const []const u8) ![]const u8 {
        const index_file = try self.path("oracle.index");
        try deleteIfPresent(index_file);
        const user_index = try std.Io.Dir.path.join(self.arena, &.{ repo.git_dir, "index" });
        if (try existsAbsolute(user_index)) try self.copyKeepingTime(user_index, index_file);
        const objects = try self.path("oracle-objects");
        try std.Io.Dir.cwd().deleteTree(testing.io, objects);
        try std.Io.Dir.cwd().createDirPath(testing.io, objects);
        const env = [_]EnvPair{
            .{ "GIT_INDEX_FILE", index_file },
            .{ "GIT_OBJECT_DIRECTORY", objects },
            .{ "GIT_ALTERNATE_OBJECT_DIRECTORIES", try std.Io.Dir.path.join(self.arena, &.{ repo.common_dir, "objects" }) },
        };
        _ = try self.gitEnv(repo.work_tree, &(oracle_overrides ++ [_][]const u8{ "add", "-A" }), &env);
        for (excluded) |excluded_path| {
            _ = try self.gitEnv(repo.work_tree, &(oracle_overrides ++ [_][]const u8{ "rm", "-q", "--cached", "--ignore-unmatch", "--", excluded_path }), &env);
        }
        return self.gitEnv(repo.work_tree, &(oracle_overrides ++ [_][]const u8{"write-tree"}), &env);
    }

    /// Everything a capture must leave as it found it in the user's
    /// repository, read without refreshing the index.
    fn userState(self: TestRepos, repo: Repository) ![]const u8 {
        const no_locks = [_]EnvPair{.{ "GIT_OPTIONAL_LOCKS", "0" }};
        var out: std.Io.Writer.Allocating = .init(self.arena);
        const w = &out.writer;
        try w.print("status:\n{s}\n", .{try self.gitEnv(repo.work_tree, &(oracle_overrides ++ [_][]const u8{ "status", "--porcelain=v1", "-uall" }), &no_locks)});
        try w.print("index:\n{s}\n", .{try self.gitEnv(repo.work_tree, &(oracle_overrides ++ [_][]const u8{ "ls-files", "-s", "-v" }), &no_locks)});
        try w.print("refs:\n{s}\n", .{try self.gitEnv(repo.work_tree, &.{ "for-each-ref", "--format=%(refname) %(objectname)" }, &no_locks)});
        for ([_][]const u8{ "index", "HEAD" }) |name| {
            const file = try std.Io.Dir.path.join(self.arena, &.{ repo.git_dir, name });
            if (!try existsAbsolute(file)) {
                try w.print("{s}: none\n", .{name});
                continue;
            }
            var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(try readAbsolute(self.arena, file), &digest, .{});
            const stat = try std.Io.Dir.cwd().statFile(testing.io, file, .{});
            try w.print("{s}: {x} {d}\n", .{ name, digest, stat.mtime.nanoseconds });
        }
        const config = try std.Io.Dir.path.join(self.arena, &.{ repo.common_dir, "config" });
        try w.print("config:\n{s}\n", .{try readAbsolute(self.arena, config)});
        return out.written();
    }

    /// Checks `tree` out of the store into an empty folder and compares each
    /// of `paths` with the worktree: bytes, executable bit and symlink target.
    /// Proves the store, alone or through its alternates, holds every object.
    fn expectRestores(self: TestRepos, repo: Repository, tree: []const u8, paths: []const []const u8) !void {
        const out = try self.path("restore");
        try std.Io.Dir.cwd().deleteTree(testing.io, out);
        try std.Io.Dir.cwd().createDirPath(testing.io, out);
        const index_file = try self.path("restore.index");
        try deleteIfPresent(index_file);
        const env = [_]EnvPair{.{ "GIT_INDEX_FILE", index_file }};
        const store_dir = try self.store(repo);
        _ = try self.gitEnv(self.root, &.{ "--git-dir", store_dir, "--work-tree", out, "read-tree", tree }, &env);
        _ = try self.gitEnv(self.root, &.{ "--git-dir", store_dir, "--work-tree", out, "checkout-index", "-a", "-f" }, &env);
        for (paths) |rel| {
            const source = try std.Io.Dir.path.join(self.arena, &.{ repo.work_tree, rel });
            const restored = try std.Io.Dir.path.join(self.arena, &.{ out, rel });
            const source_stat = try std.Io.Dir.cwd().statFile(testing.io, source, .{ .follow_symlinks = false });
            const restored_stat = std.Io.Dir.cwd().statFile(testing.io, restored, .{ .follow_symlinks = false }) catch |err| {
                std.debug.print("restore is missing {s}\n", .{rel});
                return err;
            };
            try testing.expectEqual(source_stat.kind, restored_stat.kind);
            if (source_stat.kind == .sym_link) {
                var source_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                var restored_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const source_len = try std.Io.Dir.cwd().readLink(testing.io, source, &source_buf);
                const restored_len = try std.Io.Dir.cwd().readLink(testing.io, restored, &restored_buf);
                try testing.expectEqualStrings(source_buf[0..source_len], restored_buf[0..restored_len]);
                continue;
            }
            try testing.expectEqualSlices(u8, try readAbsolute(self.arena, source), try readAbsolute(self.arena, restored));
            try testing.expectEqual(source_stat.permissions.toMode() & 0o100, restored_stat.permissions.toMode() & 0o100);
        }
    }

    /// How many times the sentinel program ran since the last call.
    fn sentinelRuns(self: TestRepos) !usize {
        const data = readAbsolute(self.arena, self.sentinel_log) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        try std.Io.Dir.deleteFileAbsolute(testing.io, self.sentinel_log);
        return std.mem.count(u8, data, "ran\n");
    }

    // Repository shapes a capture must store as the user's git would.

    fn in(self: TestRepos, repo_name: []const u8, rel: []const u8) ![]const u8 {
        return std.Io.Dir.path.join(self.arena, &.{ repo_name, rel });
    }

    /// `make_repo`: a committed repository with every shape the capture must
    /// handle.
    fn makeShapes(self: TestRepos, name: []const u8) !void {
        try self.initRepo(name);
        const files = [_]EnvPair{
            .{ "a.txt", "one\n" },
            .{ "dir/b.txt", "b\n" },
            .{ "space name.txt", "space\n" },
            .{ "\xc3\xb1and\xc3\xba.txt", "unicode\n" },
            .{ "nested/.gitignore", "tmp/\n" },
            .{ "nested/c.txt", "c\n" },
            .{ "todelete.txt", "delete me\n" },
            .{ "torename.txt", "rename me\n" },
            .{ ".gitignore", "*.log\n" },
            .{ "keep.log", "tracked but ignored\n" },
            .{ "exec.sh", "#!/bin/sh\necho hi\n" },
        };
        for (files) |file| try self.write(try self.in(name, file[0]), file[1]);
        try self.chmod(try self.in(name, "exec.sh"), 0o755);
        try self.symlink("a.txt", try self.in(name, "link"));
        try self.write(try self.in(name, "bin.dat"), try self.randomBytes(4096, 1));
        _ = try self.gitIn(name, &.{ "add", "-A" });
        _ = try self.gitIn(name, &.{ "add", "-f", "keep.log" });
        try self.commit(name, "base");
    }

    /// `dirty_repo`. `big.bin` is larger than `shapes_limits` allows for an
    /// untracked file.
    fn dirtyShapes(self: TestRepos, name: []const u8) !void {
        try self.append(try self.in(name, "a.txt"), "two\n");
        try self.append(try self.in(name, "dir/b.txt"), "staged\n");
        _ = try self.gitIn(name, &.{ "add", "dir/b.txt" });
        try self.append(try self.in(name, "dir/b.txt"), "unstaged\n");
        try self.chmod(try self.in(name, "exec.sh"), 0o644);
        try self.remove(try self.in(name, "todelete.txt"));
        try self.rename(try self.in(name, "torename.txt"), try self.in(name, "renamed.txt"));
        try self.remove(try self.in(name, "link"));
        try self.symlink("dir/b.txt", try self.in(name, "link"));
        try self.write(try self.in(name, "new.txt"), "new\n");
        try self.write(try self.in(name, "newdir/x.txt"), "x\n");
        try self.write(try self.in(name, "new.bin"), try self.randomBytes(1000, 2));
        try self.write(try self.in(name, "debug.log"), "ignored\n");
        try self.write(try self.in(name, "nested/tmp/t.txt"), "t\n");
        try self.write(try self.in(name, "local.txt"), "local\n");
        try self.append(try self.in(name, ".git/info/exclude"), "local.txt\n");
        try self.write(try self.in(name, ".env"), "SECRET=1\n");
        try self.write(try self.in(name, "big.bin"), try self.randomBytes(100 * 1024, 3));
        try self.append(try self.in(name, "keep.log"), "more tracked-ignored\n");
    }

    /// A main worktree and a linked `side` worktree, each on its own branch
    /// with a different `out/b`, both in a sparse cone that leaves `out/` off
    /// disk.
    fn makeTwoWorktrees(self: TestRepos) !void {
        try self.initRepo("wt-main");
        try self.write("wt-main/in/a", "i\n");
        try self.write("wt-main/out/b", "main\n");
        _ = try self.gitIn("wt-main", &.{ "add", "-A" });
        try self.commit("wt-main", "base");
        _ = try self.gitIn("wt-main", &.{ "worktree", "add", "-q", "-b", "side", try self.path("wt-side") });
        try self.write("wt-side/out/b", "side\n");
        try self.commitAll("wt-side", "side");
        _ = try self.gitIn("wt-side", &.{ "sparse-checkout", "set", "--cone", "in" });
        _ = try self.gitIn("wt-main", &.{ "sparse-checkout", "set", "--cone", "in" });
    }
};

const shapes_limits: policy.Limits = .{ .untracked_file_bytes = 64 * 1024 };
const shapes_excluded = [_][]const u8{ ".env", "big.bin" };
const shapes_restored = [_][]const u8{
    "a.txt",       "dir/b.txt", "exec.sh", "link",         "bin.dat",  "space name.txt", "\xc3\xb1and\xc3\xba.txt",
    "renamed.txt", "new.txt",   "new.bin", "newdir/x.txt", "keep.log", "nested/c.txt",   "nested/.gitignore",
};

fn printOutcome(outcome: Outcome) void {
    std.debug.print("capture outcome: status={s} reason={s} tree={s}\n", .{
        @tagName(outcome.status),
        if (outcome.reason) |reason| @tagName(reason) else "none",
        outcome.tree orelse "none",
    });
}

/// A capture that wrote a tree and a commit; returns the tree.
fn expectStored(outcome: Outcome) ![]const u8 {
    switch (outcome.status) {
        .complete, .partial => {},
        .failed, .unavailable => {
            printOutcome(outcome);
            return error.TestExpectedStoredCapture;
        },
    }
    const tree = outcome.tree orelse return error.TestExpectedTree;
    if (outcome.commit == null) return error.TestExpectedCommit;
    if (outcome.status == .partial and outcome.reason == null) return error.TestExpectedReason;
    return tree;
}

fn expectComplete(outcome: Outcome) ![]const u8 {
    const tree = try expectStored(outcome);
    if (outcome.status != .complete) printOutcome(outcome);
    try testing.expectEqual(Status.complete, outcome.status);
    try testing.expect(outcome.reason == null);
    return tree;
}

/// A capture that wrote nothing and says why.
fn expectNotStored(outcome: Outcome) !void {
    if (outcome.status == .complete or outcome.status == .partial) {
        printOutcome(outcome);
        return error.TestExpectedNoCapture;
    }
    try testing.expect(outcome.reason != null);
    try testing.expect(outcome.tree == null);
    try testing.expect(outcome.commit == null);
}

fn exclusionReason(outcome: Outcome, path: []const u8) ?ExclusionReason {
    for (outcome.excluded) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry.reason;
    }
    return null;
}

fn expectExcluded(outcome: Outcome, path: []const u8, reason: ExclusionReason) !void {
    const found = exclusionReason(outcome, path) orelse {
        std.debug.print("{s} is not in the capture's exclusions\n", .{path});
        return error.TestExpectedExclusion;
    };
    try testing.expectEqual(reason, found);
}

const CaptureJob = struct {
    arena_state: std.heap.ArenaAllocator,
    request: Request,
    outcome: ?Outcome = null,

    fn run(job: *CaptureJob) void {
        job.outcome = capture(job.arena_state.allocator(), job.request) catch null;
    }
};

/// Starts every job on its own thread at once and waits for all of them.
fn captureConcurrently(jobs: []CaptureJob) !void {
    var threads: [2]std.Thread = undefined;
    std.debug.assert(jobs.len <= threads.len);
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (jobs) |*job| {
        threads[started] = try std.Thread.spawn(.{}, CaptureJob.run, .{job});
        started += 1;
    }
}

/// Sets a file's times to longer ago than any capture can run.
fn makeStale(absolute: []const u8) !void {
    const now = std.Io.Timestamp.now(testing.io, .real);
    const old: std.Io.Timestamp = .{ .nanoseconds = now.nanoseconds - (stale_lock_ms + 60_000) * std.time.ns_per_ms };
    try std.Io.Dir.cwd().setTimestamps(testing.io, absolute, .{ .access_timestamp = .{ .new = old }, .modify_timestamp = .{ .new = old } });
}

/// Replaces `absolute` with a named pipe.
fn replaceWithFifo(repos: TestRepos, absolute: []const u8) !void {
    const mkfifo = "/usr/bin/mkfifo";
    std.Io.Dir.accessAbsolute(testing.io, mkfifo, .{}) catch return error.SkipZigTest;
    try TestRepos.deleteIfPresent(absolute);
    const result = try repos.run(repos.root, &.{ mkfifo, absolute }, &.{});
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.FixtureMkfifoFailed;
}

/// Opens a named pipe for writing, without blocking, from `after_ms` on
/// until `done`, so a reader a regression left blocked on it wakes at end of
/// file: its test then fails on the time taken instead of hanging the suite.
const FifoGuard = struct {
    path: [:0]const u8,
    after_ms: i64,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *FifoGuard) void {
        const started: std.Io.Clock.Timestamp = .now(testing.io, .awake);
        while (!self.done.load(.acquire)) {
            if (started.durationTo(.now(testing.io, .awake)).raw.toMilliseconds() >= self.after_ms) {
                const fd = std.c.open(self.path, .{ .ACCMODE = .WRONLY, .NONBLOCK = true });
                if (fd >= 0) _ = std.c.close(fd);
            }
            io_mod.sleep(20 * std.time.ns_per_ms);
        }
    }
};

/// How long the pipe tests let a capture run before their guard wakes a
/// blocked reader; a capture that took this long was blocked. Past the
/// first capture's budget, which a capture beside a pipe index runs on.
const fifo_guard_ms: i64 = first_capture_budget_ms + 4_000;

/// Captures `repo` with a 2 s deadline while a `FifoGuard` watches `fifo`.
/// Returns the outcome and the time it took.
fn captureBesideFifo(repos: TestRepos, repo: Repository, fifo: []const u8) !struct { Outcome, i64 } {
    var guard: FifoGuard = .{ .path = try repos.arena.dupeSentinel(u8, fifo, 0), .after_ms = fifo_guard_ms };
    const thread = try std.Thread.spawn(.{}, FifoGuard.run, .{&guard});
    defer {
        guard.done.store(true, .release);
        thread.join();
    }
    var request = repos.request(repo, "pipe", .{});
    request.deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(2000) });
    const started: std.Io.Clock.Timestamp = .now(testing.io, .awake);
    const outcome = try capture(repos.arena, request);
    return .{ outcome, started.durationTo(.now(testing.io, .awake)).raw.toMilliseconds() };
}

test "capture store: dirty worktree matches the user's git, restores byte for byte and leaves the repository untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    try repos.dirtyShapes("repo");
    const repo = try repos.repository("repo");
    const before = try repos.userState(repo);
    const expected = try repos.expectedTree(repo, &shapes_excluded);
    const head = try repos.gitIn("repo", &.{ "rev-parse", "HEAD" });

    const outcome = try capture(repos.arena, repos.request(repo, "one", shapes_limits));
    const tree = try expectStored(outcome);
    try testing.expectEqualStrings(expected, tree);
    try testing.expectEqual(Status.partial, outcome.status);
    try testing.expect(outcome.reason.? == .sensitive or outcome.reason.? == .too_large);
    try testing.expect(!outcome.comparable);
    try expectExcluded(outcome, ".env", .sensitive);
    try expectExcluded(outcome, "big.bin", .too_large);
    for (outcome.excluded) |entry| {
        try testing.expect(std.mem.eql(u8, entry.path, ".env") or std.mem.eql(u8, entry.path, "big.bin"));
    }
    try testing.expectEqualStrings(head, outcome.head.commit);
    try testing.expectEqual(@as(?safe_git.ObjectFormat, .sha1), outcome.object_format);
    try testing.expectEqual(@as(?IndexStart, .copied), outcome.index);
    try testing.expectEqual(@as(?Listing, .indexer), outcome.listing);
    try testing.expectEqualStrings(outcome.commit.?, (try repos.storeRef(repo, try repos.sessionRef(repo, "one"))).?);
    try testing.expectEqualStrings("tree", try repos.storeGit(repo, &.{ "cat-file", "-t", tree }));

    try testing.expect(try repos.treeHas(repo, tree, "keep.log"));
    for ([_][]const u8{ "local.txt", "todelete.txt", "torename.txt", "debug.log", "nested/tmp", ".env", "big.bin" }) |absent| {
        try testing.expect(!try repos.treeHas(repo, tree, absent));
    }
    try testing.expectEqualStrings("100644", (try repos.storeGit(repo, &.{ "ls-tree", tree, "exec.sh" }))[0..6]);
    try testing.expectEqualStrings("120000", (try repos.storeGit(repo, &.{ "ls-tree", tree, "link" }))[0..6]);
    try repos.expectRestores(repo, tree, &shapes_restored);
    try testing.expectEqualStrings(before, try repos.userState(repo));
}

const record_oid = "0123456789abcdef0123456789abcdef01234567";

fn parseRecord(bytes: []const u8) !std.json.Parsed(std.json.Value) {
    try testing.expect(std.mem.findScalar(u8, bytes, '\n') == null);
    try testing.expect(bytes.len <= 256 * 1024);
    return std.json.parseFromSlice(std.json.Value, testing.allocator, bytes, .{});
}

fn encodeRecordCase(alloc: Allocator) !void {
    const bytes = try encodeRecord(alloc, .start, .{
        .status = .partial,
        .reason = .sensitive,
        .object_format = .sha1,
        .tree = record_oid,
        .commit = record_oid,
        .excluded = &.{ .{ .path = ".env", .reason = .sensitive }, .{ .path = "\xff", .reason = .file_limit } },
    });
    alloc.free(bytes);
}

/// Enough untracked files that an unstopped scan takes far longer than the
/// deadline the running-scan test gives it.
const running_scan_files: usize = 100_000;

// ---- Retention (`capture_retention.zig`) against real stores ----

const retention = @import("capture_retention.zig");

/// The profile's sessions as maintenance sees them: every id exists and is
/// idle unless listed.
const TestSessions = struct {
    arena: Allocator,
    missing: []const []const u8 = &.{},
    busy_ids: []const []const u8 = &.{},
    /// Moved when maintenance asks whether its session is open, as a capture
    /// that starts between the inventory and the deletes would.
    moved: ?RefMove = null,

    const RefMove = struct { repos: TestRepos, repo: Repository, id: []const u8, to: []const u8 };

    fn listed(self: *TestSessions, ids: []const []const u8, key: []const u8) bool {
        for (ids) |id| if (std.mem.eql(u8, sessionKey(self.arena, id) catch return true, key)) return true;
        return false;
    }

    fn existsFn(ctx: *anyopaque, key: []const u8) bool {
        const self: *TestSessions = @ptrCast(@alignCast(ctx));
        return !self.listed(self.missing, key);
    }

    fn busyFn(ctx: *anyopaque, key: []const u8) bool {
        const self: *TestSessions = @ptrCast(@alignCast(ctx));
        if (self.moved) |move| if (self.listed(&.{move.id}, key)) {
            const ref = move.repos.sessionRef(move.repo, move.id) catch return true;
            _ = move.repos.storeGit(move.repo, &.{ "update-ref", ref, move.to }) catch return true;
        };
        return self.listed(self.busy_ids, key);
    }

    fn view(self: *TestSessions) retention.Sessions {
        return .{ .ctx = self, .exists = existsFn, .busy = busyFn };
    }
};

fn retentionConfig(repos: TestRepos, current_id: []const u8, sessions: *TestSessions, budget: u64, target: u64) !retention.Config {
    return .{
        .profile_root = repos.profile,
        .current_key = try sessionKey(repos.arena, current_id),
        .sessions = sessions.view(),
        .now_ms = io_mod.milliTimestamp(),
        .deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(test_deadline_ms) }),
        .budget = budget,
        .target = target,
    };
}

/// A capture of `repo` for `session_id` dated `unix_seconds`.
fn captureAt(repos: TestRepos, repo: Repository, session_id: []const u8, unix_seconds: i64) ![]const u8 {
    var request = repos.request(repo, session_id, .{});
    request.unix_seconds = unix_seconds;
    _ = try expectStored(try capture(repos.arena, request));
    return (try repos.storeRef(repo, try repos.sessionRef(repo, session_id))).?;
}

/// Sets every loose object of `repo`'s store an hour back, as an evicted
/// session's objects are: retention's prune keeps loose objects written since
/// it took the store's locks, so one written in that same second would stay.
fn ageLooseObjects(repos: TestRepos, repo: Repository) !void {
    const objects = try std.Io.Dir.path.join(repos.arena, &.{ try repos.store(repo), "objects" });
    var dir = try std.Io.Dir.openDirAbsolute(testing.io, objects, .{ .iterate = true });
    defer dir.close(testing.io);
    const past: std.Io.File.SetTimestamp = .{ .new = .{ .nanoseconds = (@as(i96, test_unix_seconds) - 3600) * std.time.ns_per_s } };
    var fanout = dir.iterate();
    while (try fanout.next(testing.io)) |entry| {
        if (entry.kind != .directory or entry.name.len != 2) continue;
        var sub = try dir.openDir(testing.io, entry.name, .{ .iterate = true });
        defer sub.close(testing.io);
        var files = sub.iterate();
        while (try files.next(testing.io)) |file| {
            if (file.kind != .file) continue;
            try sub.setTimestamps(testing.io, file.name, .{ .access_timestamp = past, .modify_timestamp = past });
        }
    }
}

fn storeHasObject(repos: TestRepos, repo: Repository, oid: []const u8) !bool {
    const result = try repos.run(repos.root, try repos.gitArgv(&.{ "--git-dir", try repos.store(repo), "cat-file", "-e", oid }), &.{});
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn journalLines(repos: TestRepos) ![]const []const u8 {
    const text = TestRepos.readAbsolute(repos.arena, try std.Io.Dir.path.join(repos.arena, &.{ repos.profile, "captures", "evictions.jsonl" })) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |line| if (line.len > 0) try lines.append(repos.arena, line);
    return lines.items;
}

fn usagePath(repos: TestRepos) ![]const u8 {
    return std.Io.Dir.path.join(repos.arena, &.{ repos.profile, "captures", "usage" });
}

/// The folder name a store has in `usage`.
fn storeName(repos: TestRepos, repo: Repository) ![]const u8 {
    return std.Io.Dir.path.basename(try storeDir(repos.arena, repos.profile, repo.common_dir));
}

/// Field `field` of the `usage` line that starts with `first`: `v2` for the
/// header, a store name for its line. Null when no line does.
fn usageField(repos: TestRepos, first: []const u8, field: usize) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, try TestRepos.readAbsolute(repos.arena, try usagePath(repos)), '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ' ');
        if (!std.mem.eql(u8, fields.first(), first)) continue;
        for (1..field) |_| _ = fields.next() orelse return error.TestUnexpectedResult;
        return fields.next() orelse error.TestUnexpectedResult;
    }
    return null;
}

/// Rewrites one field of a `usage` line, as `usageField` names it.
fn setUsageField(repos: TestRepos, first: []const u8, field: usize, value: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    var found = false;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, try TestRepos.readAbsolute(repos.arena, try usagePath(repos)), "\n"), '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ' ');
        var index: usize = 0;
        const own = std.mem.eql(u8, fields.first(), first);
        fields.reset();
        while (fields.next()) |text| : (index += 1) {
            if (index > 0) try out.append(repos.arena, ' ');
            try out.appendSlice(repos.arena, if (own and index == field) value else text);
        }
        try out.append(repos.arena, '\n');
        found = found or own;
    }
    if (!found) return error.TestUnexpectedResult;
    try TestRepos.writeAbsolute(try usagePath(repos), out.items);
}

/// Moves every store's object folder times that are too recent to
/// fingerprint back past that window, as waiting would, so the next admit
/// can keep its measure. Older times stay, so a store settled before keeps
/// its fingerprint.
fn settle(repos: TestRepos) !void {
    const past: i96 = @intCast(io_mod.nanoTimestamp() - 3 * std.time.ns_per_s);
    const captures = try std.Io.Dir.path.join(repos.arena, &.{ repos.profile, "captures" });
    for (try listStoreDirs(repos.arena, testing.io, captures)) |store_dir| {
        try setObjectTimes(try std.Io.Dir.path.join(repos.arena, &.{ try storeGitDir(repos.arena, store_dir), "objects" }), past, true);
    }
}

/// Sets the modification time of the `objects` folder and each folder in it
/// to `ns`; with `only_later`, only of those whose time is later.
fn setObjectTimes(objects: []const u8, ns: i96, only_later: bool) !void {
    var dir = try std.Io.Dir.openDirAbsolute(testing.io, objects, .{ .iterate = true });
    defer dir.close(testing.io);
    const time: std.Io.File.SetTimestamp = .{ .new = .{ .nanoseconds = ns } };
    var entries = dir.iterate();
    while (try entries.next(testing.io)) |entry| {
        if (entry.kind != .directory) continue;
        if (only_later and (try dir.statFile(testing.io, entry.name, .{})).mtime.nanoseconds <= ns) continue;
        try dir.setTimestamps(testing.io, entry.name, .{ .modify_timestamp = time });
    }
    // Last: changing a folder in it leaves the folder's own time alone, but
    // only the folder's own update is certain not to move it again.
    if (only_later and (try dir.stat(testing.io)).mtime.nanoseconds <= ns) return;
    try dir.setTimestamps(testing.io, ".", .{ .modify_timestamp = time });
}

/// A folder in `store_dir` that no walk can open, so measuring the store
/// fails; null when this user opens it anyway, such as root. The caller
/// gives it back its permissions with `unblock`.
fn blockedFolder(repos: TestRepos, store_dir: []const u8) !?[]const u8 {
    const path = try std.Io.Dir.path.join(repos.arena, &.{ store_dir, "blocked" });
    try std.Io.Dir.cwd().createDirPath(testing.io, path);
    try setFolderMode(path, 0o000);
    if (std.Io.Dir.openDirAbsolute(testing.io, path, .{ .iterate = true })) |opened| {
        var dir = opened;
        dir.close(testing.io);
        unblock(path);
        return null;
    } else |_| {}
    return path;
}

fn unblock(path: []const u8) void {
    setFolderMode(path, 0o700) catch {};
}

fn setFolderMode(path: []const u8, mode: std.posix.mode_t) !void {
    var parent = try std.Io.Dir.openDirAbsolute(testing.io, std.Io.Dir.path.dirname(path).?, .{});
    defer parent.close(testing.io);
    try parent.setFilePermissions(testing.io, std.Io.Dir.path.basename(path), .fromMode(mode), .{});
}

fn markerPath(repos: TestRepos, repo: Repository) ![]const u8 {
    return std.Io.Dir.path.join(repos.arena, &.{ try storeDir(repos.arena, repos.profile, repo.common_dir), retention.prune_marker });
}

/// `count` captures of `repo` for `session_id`, one second apart from
/// `first_seconds`, each a small edit of one 64 KiB file of random bytes:
/// loose, each version takes the whole file; packed, a version is a delta.
fn editingCaptures(repos: TestRepos, repo: Repository, session_id: []const u8, count: usize, first_seconds: i64, seed: u64) ![]const u8 {
    const path = try repos.arena.print("{s}/edited.bin", .{std.Io.Dir.path.basename(repo.work_tree)});
    const bytes = try repos.arena.dupe(u8, try repos.randomBytes(64 * 1024, seed));
    var last: []const u8 = "";
    for (0..count) |i| {
        bytes[(i * 4099) % bytes.len] +%= 1;
        try repos.write(path, bytes);
        last = try captureAt(repos, repo, session_id, first_seconds + @as(i64, @intCast(i)));
    }
    return last;
}

/// Whether the store still holds loose objects. A capture packs only the
/// objects it copies from the user's repository; those it writes stay loose.
fn storeUnpacked(repos: TestRepos, repo: Repository) !bool {
    return !std.mem.startsWith(u8, try repos.storeGit(repo, &.{ "count-objects", "-v" }), "count: 0\n");
}
