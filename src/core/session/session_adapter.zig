//! The one door between spark and the session manager (sessions v2), spark's only
//! session store.
//!
//! Hosts call this file; it is the only spark file that imports
//! `session_manager`, and the boundary test at the bottom keeps it so. v1
//! code is never called from here except for its encoders and its turn
//! builder, so a session converted from v1 holds the same bytes for the same
//! history as one spark started here.
//!
//! What goes where:
//! - each completed piece of a turn is one `item` whose `type` is the v1
//!   piece kind and whose `data` is the v1 payload;
//! - a turn ends with a `turn_end` item and `turn_committed`, or an
//!   `interruption` item and `turn_interrupted` (`cancel` or `failed`);
//! - preferences, permissions, conversation language, title and usage are
//!   `set` values in v1's encodings;
//! - large bodies (tool results, tool images, command replay, web-fetch
//!   downloads) are blobs of the session, each named by its hash (D44); an
//!   ACP client's prompt and tool identities are settings (D46); hosted
//!   terminal state lives in `~/.spark/terminal/{id}/` (D45). An older session
//!   with a `~/.spark/session-files/{id}/` side folder moves on its first
//!   writable open (D47, `tests/tla/session_manager/MoveSideFiles.tla`).
//!
//! Models of the sessions v2 rollout, one per step that changed this file:
//! - `tests/tla/session_manager/rollout/pr-1072/PR1072Ask.tla`: `spark ask`
//! - `tests/tla/session_manager/rollout/pr-1073/PR1073Interactive.tla`: resume and switch
//! - `tests/tla/session_manager/rollout/pr-1076/PR1076RunningTools.tla`: running tool calls
//! - `tests/tla/session_manager/rollout/pr-1079/PR1079ACP.tla`: ACP sessions
//! - `tests/tla/session_manager/rollout/pr-1081/PR1081Subagents.tla`: subagents
//! - `tests/tla/session_manager/rollout/pr-1082/PR1082Commands.tla`: session commands
//! - `tests/tla/session_manager/rollout/pr-1116/PR1116Blobs.tla`: bodies as blobs
//! - `tests/tla/session_manager/rollout/pr-1116/PR1116ChildCheckpoint.tla`: child checkpoints
//! - `tests/tla/session_manager/rollout/pr-1116/PR1116Migration.tla`: moving older sessions
//! - `tests/tla/session_manager/rollout/pr-1116/PR1116Records.tla`: records and forks
//! - `tests/tla/session_manager/rollout/pr-1116/PR1116Terminal.tla`: hosted terminal state

const std = @import("std");
const atomic_value = @import("../shared/atomic_value.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const builtin = @import("builtin");
const sm = @import("session_manager");
/// A line boundary in a session log, for hosts that walk it.
pub const LogCursor = sm.Cursor;
/// The session manager's rule for a session id, for code that may not
/// import the session manager itself.
pub const validSessionId = sm.validId;
const debug_trace = @import("../shared/debug_trace.zig");
const write_test_controls = @import("write_test_controls.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const agent_frame = @import("../shared/agent_frame.zig");
const image_attachments = @import("../images/image_attachments.zig");
const image_data = @import("../images/image_data.zig");
const convo = @import("convo.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const session_event = @import("session_event.zig");
const result_store = @import("result_store.zig");
const session_log = @import("session_log.zig");
const session_codec = @import("session_codec.zig");
const session_layout = @import("session_layout.zig");
const session_child_store = @import("session_child_store.zig");
const session_display_metadata = @import("session_display_metadata.zig");
const session_store = @import("session_store.zig");
const session_summary_codec = @import("session_summary_codec.zig");
const v1_conversion = @import("v1_conversion.zig");
const child_state = @import("../subagent/child_state.zig");
const subagent_domain = @import("../subagent/domain.zig");
const artifact_digest = @import("artifact_digest.zig");
const model_provider = @import("../config/model_provider.zig");
const text_utils = @import("../shared/text_utils.zig");
const history_range = @import("../shared/history_range.zig");
const json_decode = @import("../shared/json_decode.zig");

const Allocator = std.mem.Allocator;
const Event = session_event.ConversationEvent;
const PieceKind = std.meta.Tag(Event);

/// Folder of the side files older v2 sessions kept, under `~/.spark`; a
/// session moves out of it on its first writable open (D47).
pub const files_dir_name = profile_paths.session_files_dir_name;
/// Folder of v2 sessions' hosted terminal state, under `~/.spark` (D45).
pub const terminal_dir_name = profile_paths.terminal_dir_name;
/// The profile's home folder, opened for listing: creating `~/.spark` in it
/// syncs it, and Linux cannot sync a folder opened any other way (`O_PATH`).
fn openHome(home: []const u8) !io_mod.VerifiedDir {
    return .{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true, .follow_symlinks = false }) };
}

/// Pieces larger than this go to a blob; the line keeps a reference.
const max_inline_piece_bytes: usize = 256 * 1024;
/// A workspace capture always fits inline: one held for a turn not on disk
/// yet could not go to a blob, which needs the turn on disk (D44, D98).
const max_workspace_capture_bytes = max_inline_piece_bytes;
/// The next capture turn token, shared by every Session of the process so a
/// token from one never matches another's turn (D98). Starts at 1: 0 means
/// no turn.
var capture_turns: atomic_value.Value(u64) = .init(1);
/// Lines per page when replaying history.
const replay_page_lines: usize = 256;

pub const Host = sm.Host;
pub const ChildOutcome = sm.Outcome;

/// One child as its parent's log folds it (D22). Owns its strings.
pub const Child = struct {
    id: []u8,
    /// The child's newest work item.
    work_id: []u8,
    /// That work item is spawned and not finished.
    open: bool,
    /// How the newest finished work item ended; null before the first.
    outcome: ?ChildOutcome,
    /// spark's data on the newest `child_spawned` and `child_finished`.
    spawn_data: ?[]u8,
    finish_data: ?[]u8,
    /// Seq of the newest line about this child.
    seq: u64,
};

pub fn freeChildren(alloc: Allocator, children: []Child) void {
    for (children) |child| freeChild(alloc, child);
    alloc.free(children);
}

fn freeChild(alloc: Allocator, child: Child) void {
    alloc.free(child.id);
    alloc.free(child.work_id);
    if (child.spawn_data) |data| alloc.free(data);
    if (child.finish_data) |data| alloc.free(data);
}

/// One fact about a subagent's report in its parent's log (`reportLines`).
pub const ReportLine = union(enum) {
    spawned: struct { child: []const u8, work_id: []const u8, data: ?[]const u8 },
    finished: struct { child: []const u8, work_id: []const u8, outcome: ChildOutcome, data: ?[]const u8 },
    /// The parent took the report for this work into its history.
    taken: struct { child: []const u8, work_id: []const u8 },
};

/// A line about a child, appended through its parent.
pub const ChildLine = union(enum) {
    spawned: struct { child: []const u8, work_id: []const u8, data: ?[]const u8 = null },
    finished: struct { child: []const u8, work_id: []const u8, outcome: ChildOutcome, data: ?[]const u8 = null },
};

// ---------------------------------------------------------------------------
// Wiring trace

/// One step of `Wiring.tla`, as a `wiring` trace line that trace validation
/// reads back: the store opening and closing (the process's start and
/// exit), a host session opening and closing, and the turn and child lines
/// a host session writes. `pid` tells one process's steps from another's.
fn traceWiring(comptime action: []const u8, session_id: []const u8, comptime detail: []const u8, pid: i64) void {
    debug_trace.logf("wiring", "action=" ++ action ++ " session={s}" ++ detail ++ " pid={d}", .{ session_id, pid });
}

fn processId() i64 {
    if (comptime builtin.target.os.tag == .wasi) return 0;
    return std.c.getpid();
}

// ---------------------------------------------------------------------------
// Store: one per process

pub const Store = struct {
    manager: *sm.Manager,
    /// `$HOME`, owned: the base of `~/.spark/sessions/v2` and of the side folders.
    home: []u8,
    /// Read once, for the wiring trace: not a call per append.
    pid: i64,
    /// Why the last v1 session this store refused to convert is unreadable
    /// (D61): the file and the reason.
    problem: v1_conversion.Problem = .{},
    /// Told once when converting a v1 session runs past
    /// `slow_conversion_ms`, so the host can say why the open is slow (D61).
    notice: ?Notice = null,

    pub const Notice = struct {
        context: ?*anyopaque,
        emit: *const fn (context: ?*anyopaque, text: []const u8) void,
    };

    /// The file and the reason the last refused conversion found its v1
    /// session unreadable, or null. Borrowed until the next conversion.
    pub fn conversionProblem(store: *const Store) ?[]const u8 {
        return if (store.problem.len == 0) null else store.problem.text();
    }

    /// Touches no disk: a session's folder appears with its first turn.
    pub fn open(alloc: Allocator, home: []const u8) !Store {
        // Resolved as v1 resolves its sessions root, so a home reached
        // through a symlink (macOS `/var`) passes the no-follow opens below.
        const owned_home = io_mod.realpathAlloc(alloc, home) catch |err| blk: {
            debug_trace.logf("session", "event=sessions_v2_home_unresolved err={s} using=given", .{@errorName(err)});
            break :blk try alloc.dupe(u8, home);
        };
        errdefer alloc.free(owned_home);
        try checkSessionsPath(owned_home);
        // `spark --convo FILE` keeps its one session in a private store.
        const root = if (convo.storeRoot()) |private| try alloc.dupe(u8, private) else try profile_paths.rootPath(alloc, home, &.{ profile_paths.sessions_dir_name, session_layout.sessions_v2_dir });
        defer alloc.free(root);
        const manager = try sm.Manager.init(alloc, io_mod.getIo(), .{
            .root = root,
            .diagnostics = .{ .context = null, .emit = traceDiagnostic },
        });
        const pid = processId();
        traceWiring("StoreOpen", "-", "", pid);
        return .{ .manager = manager, .home = owned_home, .pid = pid };
    }

    /// Refuses, before any session is asked for, a `~/.spark`, `~/.spark/sessions`
    /// or `v2` folder that is not a real folder, such as a file or a symlink
    /// (D67): every write would fail on it. One that is missing is made by
    /// the first write; one that others can read converts (D61).
    fn checkSessionsPath(home: []const u8) !void {
        // Start from the folder that holds spark's folder, so SPARK_HOME is checked.
        var parent = openHome(profile_paths.rootParent(home)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer parent.close();
        for ([_][]const u8{ profile_paths.rootName(), profile_paths.sessions_dir_name, session_layout.sessions_v2_dir }) |name| {
            const next = (io_mod.openRealDirIfPresent(&parent, name) catch |err| switch (err) {
                error.DurablePathUnsafe => return error.SessionPathUnsafe,
                else => return err,
            }) orelse return;
            parent.close();
            parent = next;
        }
    }

    /// `$HOME` from the environment.
    pub fn openFromEnv(alloc: Allocator) !Store {
        return open(alloc, io_mod.homeDir() orelse return error.HomeNotSet);
    }

    /// Every Session must be closed first.
    pub fn deinit(store: *Store, alloc: Allocator) void {
        traceWiring("StoreClose", "-", "", store.pid);
        store.manager.deinit();
        alloc.free(store.home);
        store.* = undefined;
    }

    /// `~/.spark/{name}`, or null when nothing has made it yet.
    /// Every caller is about to change the folder, so an existing `~/.spark` is
    /// made `0700` as every other spark writer makes it: one made by hand or an
    /// install script keeps the default mode, and refusing it would refuse
    /// every resume.
    fn openProfileFolder(store: *Store, name: []const u8) !?io_mod.VerifiedDir {
        var home = try openHome(profile_paths.rootParent(store.home));
        defer home.close();
        _ = home.dir.statFile(io_mod.getIo(), profile_paths.rootName(), .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        var spark = try io_mod.openOrCreateVerifiedPrivateDir(&home, profile_paths.rootName());
        defer spark.close();
        return io_mod.openVerifiedPrivateDirIfPresent(&spark, name);
    }

    /// `~/.spark/{name}`, made `0700` when missing; `~/.spark` too, as v1's
    /// writable root makes it.
    fn makeProfileFolder(store: *Store, name: []const u8) !io_mod.VerifiedDir {
        var home = try openHome(profile_paths.rootParent(store.home));
        defer home.close();
        var spark = try io_mod.openOrCreateVerifiedPrivateDir(&home, profile_paths.rootName());
        defer spark.close();
        return io_mod.openOrCreateVerifiedPrivateDir(&spark, name);
    }

    /// The folders of `id` outside the manager: its terminal state (D45)
    /// and a side folder not yet moved (D47).
    const outside_folders = [_][]const u8{ terminal_dir_name, files_dir_name };

    /// Removes the folders of `id` outside the manager; `why` names the
    /// caller in the trace.
    fn removeFiles(store: *Store, id: []const u8, why: []const u8) void {
        for (outside_folders) |root_name| {
            var root = (store.openProfileFolder(root_name) catch |err| {
                debug_trace.logf("session", "event=sessions_v2_files_kept session={s} root={s} why={s} err={s}", .{ id, root_name, why, @errorName(err) });
                continue;
            }) orelse continue;
            defer root.close();
            if (root.dir.statFile(io_mod.getIo(), id, .{ .follow_symlinks = false })) |_| {} else |_| continue;
            root.dir.deleteTree(io_mod.getIo(), id) catch |err| {
                debug_trace.logf("session", "event=sessions_v2_files_kept session={s} root={s} why={s} err={s}", .{ id, root_name, why, @errorName(err) });
                continue;
            };
            debug_trace.logf("session", "event=sessions_v2_files_removed session={s} root={s} why={s}", .{ id, root_name, why });
        }
    }

    /// Copies the folders of `from` outside the manager to `to`, root by
    /// root: plain files and folders only, never through a link. False when
    /// anything was left out; a source with none has nothing to copy. A
    /// side folder not yet moved is copied as it is, and the copy moves on
    /// its own first open.
    fn copyFiles(store: *Store, from: []const u8, to: []const u8) bool {
        var complete = true;
        for (outside_folders) |root_name| {
            var root = (store.openProfileFolder(root_name) catch |err| {
                complete = copyFailed(from, err);
                continue;
            }) orelse continue;
            defer root.close();
            var source = (io_mod.openVerifiedPrivateDirIfPresent(&root, from) catch |err| {
                complete = copyFailed(from, err);
                continue;
            }) orelse continue;
            defer source.close();
            var target = io_mod.openOrCreateVerifiedPrivateDir(&root, to) catch |err| {
                complete = copyFailed(from, err);
                continue;
            };
            defer target.close();
            if (!copyTree(io_mod.openVerifiedPrivateDirIfPresent, &source, &target, 0)) complete = false;
        }
        return complete;
    }

    /// Finds folders outside the manager whose session is gone, except young
    /// ones (D36, D45), in both roots, and counts or removes them as
    /// `orphans` says.
    fn sweepFiles(store: *Store, alloc: Allocator, report: *Doctor, now_ms: i64, orphans: OrphanSweep) !void {
        for (outside_folders) |root_name| try store.sweepRoot(alloc, root_name, report, now_ms, orphans);
    }

    fn sweepRoot(store: *Store, alloc: Allocator, root_name: []const u8, report: *Doctor, now_ms: i64, orphans: OrphanSweep) !void {
        var files = try store.openProfileFolder(root_name) orelse return;
        defer files.close();
        var it = files.dir.iterate();
        while (try it.next(io_mod.getIo())) |entry| {
            if (entry.kind != .directory) continue;
            session_layout.validateSessionId(entry.name) catch continue;
            var probe = store.manager.read(alloc, entry.name, .start, .forward, 1) catch |err| switch (err) {
                error.NotFound => null,
                else => continue,
            };
            if (probe) |*page| {
                page.deinit();
                continue;
            }
            const stat = files.dir.statFile(io_mod.getIo(), entry.name, .{ .follow_symlinks = false }) catch {
                report.kept += 1;
                continue;
            };
            const changed_ms: i64 = @intCast(@divFloor(stat.mtime.toNanoseconds(), std.time.ns_per_ms));
            if (now_ms - changed_ms < orphan_min_age_ms) {
                debug_trace.logf("session", "event=sessions_v2_orphan_files_young session={s} root={s}", .{ entry.name, root_name });
                continue;
            }
            if (orphans == .count) {
                report.removable += 1;
                continue;
            }
            files.dir.deleteTree(io_mod.getIo(), entry.name) catch |err| {
                debug_trace.logf("session", "event=sessions_v2_files_kept session={s} root={s} why=orphan err={s}", .{ entry.name, root_name, @errorName(err) });
                report.kept += 1;
                continue;
            };
            debug_trace.logf("session", "event=sessions_v2_files_removed session={s} root={s} why=orphan", .{ entry.name, root_name });
            report.removed += 1;
        }
    }

    /// A child's stored title, read without opening it; null when it has
    /// none yet. Caller owns it.
    pub fn childTitle(store: *Store, alloc: Allocator, child_id: []const u8) !?[]u8 {
        var peeked = try store.manager.peek(alloc, child_id);
        defer peeked.deinit(alloc);
        const raw = peeked.state.title orelse return null;
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        return try alloc.dupe(u8, try json_decode.parseFromSliceLeaky([]const u8, scratch.allocator(), raw, .{}));
    }

    /// Every saved session's id, children included, owned by `arena`; null
    /// when the catalog cannot be read. Capture retention matches sessions
    /// to their capture refs with it (D98). The catalog lists roots only,
    /// so each session's children come from its folded state, as `peek`
    /// reads it, down to the depth `Manager.delete` follows; a session
    /// deleted meanwhile is skipped, and any other failure returns null.
    pub fn sessionIds(store: *Store, arena: Allocator) ?[]const []const u8 {
        var ids: std.ArrayList([]const u8) = .empty;
        var cursor: ?sm.ListCursor = null;
        while (true) {
            var page = store.manager.list(arena, .all, cursor, 512) catch return null;
            defer page.deinit();
            for (page.items) |item| {
                const id = arena.dupe(u8, item.id) catch return null;
                ids.append(arena, id) catch return null;
            }
            cursor = page.next orelse break;
        }
        // Breadth first: each level's children follow the level before.
        var level_start: usize = 0;
        var depth: usize = 0;
        while (level_start < ids.items.len and depth <= 8) : (depth += 1) {
            const level_end = ids.items.len;
            for (level_start..level_end) |index| {
                var peeked = store.manager.peek(arena, ids.items[index]) catch |err| switch (err) {
                    error.NotFound => continue,
                    else => return null,
                };
                defer peeked.deinit(arena);
                for (peeked.state.children.items) |child| {
                    const id = arena.dupe(u8, child.id) catch return null;
                    ids.append(arena, id) catch return null;
                }
            }
            level_start = level_end;
        }
        return ids.items;
    }

    /// Whether another process has session `id` open; true when unsure.
    pub fn sessionBusy(store: *Store, id: []const u8) bool {
        return store.manager.isBusy(id) catch true;
    }

    /// A child's whole history, read without its lock: every turn, oldest
    /// first. Free with `types.freeHistoryTurnSlice`.
    pub fn childHistory(store: *Store, alloc: Allocator, child_id: []const u8) ![]types.HistoryTurn {
        var history: std.ArrayList(types.HistoryTurn) = .empty;
        errdefer {
            for (history.items) |turn| types.freeHistoryTurn(alloc, turn);
            history.deinit(alloc);
        }
        const Sink = struct {
            alloc: Allocator,
            history: *std.ArrayList(types.HistoryTurn),

            fn turn(sink: *@This(), value: types.HistoryTurn, _: ?u64) !void {
                errdefer types.freeHistoryTurn(sink.alloc, value);
                try sink.history.append(sink.alloc, value);
            }

            /// A child's history is its turns only.
            fn summary(_: *@This(), _: []const u8) !void {}
        };
        var sink: Sink = .{ .alloc = alloc, .history = &history };
        try replay(.{ .store = store, .id = child_id }, alloc, alloc, .start, null, ReplaySink.init(&sink));
        return history.toOwnedSlice(alloc);
    }

    /// A child's newest preferences, read without its lock. Caller owns.
    pub fn childPreferences(store: *Store, alloc: Allocator, child_id: []const u8) !session_codec.DurableSessionPreferences {
        var from: sm.From = .end;
        while (true) {
            var page = try store.manager.read(alloc, child_id, from, .backward, replay_page_lines);
            defer page.deinit();
            for (page.entries) |entry| {
                const body = entry.body orelse continue;
                if (body == .set and body.set.key == .prefs) return decodePreferences(alloc, body.set.value);
            }
            from = .{ .at = page.next orelse return error.InvalidSessionFormat };
        }
    }
};

/// Every repair or drop the manager makes reaches the trace log.
fn traceDiagnostic(_: ?*anyopaque, event: sm.Diagnostic) void {
    debug_trace.logf("session", "event=sessions_v2_diagnostic kind={s} session={s} count={d} offset={d}", .{
        @tagName(event.kind), event.session_id, event.count, event.offset,
    });
}

// ---------------------------------------------------------------------------
// Commands: `spark session {id}`, `spark session recover`, doctor

/// What the session commands report, in the names spark's CLI knows.
pub const CommandError = error{
    SessionNotFound,
    InvalidSessionId,
    SessionBusy,
    InvalidSessionFormat,
    UnsupportedSessionSchema,
    SessionRecoveryBoundaryInvalid,
    SessionRecoveryNotNeeded,
    SessionStoreUnavailable,
    DurablePathUnsafe,
    HomeNotSet,
    OutOfMemory,
};

/// Maps an error from `Store.openFromEnv`, `listPage`, `readSession`,
/// `recover` or `doctor` onto `CommandError`: a storage fault leaves the
/// store unavailable, and anything else a record fails with is damage.
pub fn commandError(err: anyerror) CommandError {
    return switch (err) {
        error.SessionNotFound, error.NotFound, error.ChildSession => error.SessionNotFound,
        error.InvalidArgument, error.InvalidSessionId => error.InvalidSessionId,
        error.Busy, error.SessionBusy => error.SessionBusy,
        error.UnsupportedVersion => error.UnsupportedSessionSchema,
        error.Corrupt => error.InvalidSessionFormat,
        // `recover` of a session whose first turn never ended whole (D15).
        error.InvalidForkPoint => error.SessionRecoveryBoundaryInvalid,
        // v1's own recovery, salvaging a v1 session (D64). An older format
        // it reads whole needs none; one it cannot read has no boundary.
        error.SessionRecoveryNotNeeded => error.SessionRecoveryNotNeeded,
        error.SessionRecoveryBoundaryInvalid, error.SessionRecoveryRequiresCurrentSchema => error.SessionRecoveryBoundaryInvalid,
        error.SessionRecoveryUnsupportedSchema => error.UnsupportedSessionSchema,
        // A v1 file others can write, say: unsafe, not damaged.
        error.DurablePathUnsafe, error.SessionPathUnsafe, error.PrivateStatePermissionsUnsupported => error.DurablePathUnsafe,
        error.HomeNotSet => error.HomeNotSet,
        error.OutOfMemory => error.OutOfMemory,
        error.Io, error.NoSpaceLeft, error.AccessDenied, error.ReadOnlyFileSystem, error.FileTooBig => blk: {
            debug_trace.logf("session", "event=sessions_v2_command_failed kind=store err={s}", .{@errorName(err)});
            break :blk error.SessionStoreUnavailable;
        },
        else => blk: {
            debug_trace.logf("session", "event=sessions_v2_command_failed kind=record err={s}", .{@errorName(err)});
            break :blk error.InvalidSessionFormat;
        },
    };
}

/// A saved root session as v1's state, read without its lock while another
/// process may hold it (D37), for `spark session {id}`: every turn, with each
/// compaction's summary where it happened (D32). A missing session, a
/// child, or an id that cannot name one is `error.SessionNotFound`. Caller
/// owns the result.
pub fn readSession(store: *Store, alloc: Allocator, id: []const u8) !Resumed {
    var peeked = store.manager.peek(alloc, id) catch |err| return switch (err) {
        error.NotFound, error.InvalidArgument => readV1Session(store, alloc, id),
        else => err,
    };
    defer peeked.deinit(alloc);
    if (peeked.role != .root) return error.SessionNotFound;
    return detailOf(store, alloc, id, peeked);
}

/// A subagent's session, by its own id, as `readSession` reads a root's:
/// without its lock (D37). `resolveAgent` finds the id from the names its
/// parents gave it. Anything but a v2 child is `error.SessionNotFound`.
/// Caller owns the result.
pub fn readChild(store: *Store, alloc: Allocator, id: []const u8) !Resumed {
    var peeked = store.manager.peek(alloc, id) catch |err| return switch (err) {
        error.NotFound, error.InvalidArgument => error.SessionNotFound,
        else => err,
    };
    defer peeked.deinit(alloc);
    if (peeked.role != .child) return error.SessionNotFound;
    return detailOf(store, alloc, id, peeked);
}

/// Every turn and setting of peeked session `id`, as `spark session` shows it.
fn detailOf(store: *Store, alloc: Allocator, id: []const u8, peeked: sm.Peeked) !Resumed {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var restored = try settingsFrom(alloc, scratch.allocator(), peeked.state);
    defer restored.deinit(alloc);
    restored.history = try detailHistory(.{ .store = store, .id = id }, alloc);
    return resumedOf(alloc, &restored, id, peeked.workspace);
}

/// A v1 root v2 does not hold yet, read by v1's reader without converting
/// it (D61). Caller owns the result.
fn readV1Session(store: *Store, alloc: Allocator, id: []const u8) !Resumed {
    store.problem = .{};
    var detail = (v1_conversion.readDetail(alloc, store.home, id, &store.problem) catch |err| switch (err) {
        // A folder others can write, a symlink or a FIFO is unsafe, not
        // damaged: recover refuses it the same way (D61).
        error.OutOfMemory,
        error.SessionNotFound,
        error.PrivateStatePermissionsUnsupported,
        error.DurablePathUnsafe,
        error.SessionPathUnsafe,
        => return err,
        else => return v1Unreadable(store, alloc, id, err),
    }) orelse return error.SessionNotFound;
    defer detail.summary.deinit(alloc);
    errdefer detail.state.deinit(alloc);
    const title = if (detail.summary.title) |value| try alloc.dupe(u8, value) else null;
    return .{ .state = detail.state, .title = title };
}

/// A v1 root v1's reader refuses, however it fails: damage, with the file
/// and the reason in `store.problem` when the converter's read names them
/// (D78).
fn v1Unreadable(store: *Store, alloc: Allocator, id: []const u8, err: anyerror) error{ OutOfMemory, InvalidSessionFormat } {
    debug_trace.logf("session", "event=v1_detail_unreadable session={s} err={s}", .{ id, @errorName(err) });
    const stuck = (checkV1(store, alloc, id) catch |check_err| switch (check_err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    }) orelse {
        store.problem = .{};
        return error.InvalidSessionFormat;
    };
    defer {
        alloc.free(stuck.id);
        alloc.free(stuck.reason);
    }
    store.problem = .{};
    return store.problem.set("{s}", .{stuck.reason});
}

/// A page of saved root sessions as v1 pages them: newest first, one
/// workspace when `workspace` is set, and only what follows `continuation`.
/// It reads only the part of v2's index the page needs (D62), and those of
/// v1's roots not converted yet that can reach the page, each one v2 does
/// not hold (D59). Caller owns the page.
pub fn listPage(
    store: *Store,
    alloc: Allocator,
    workspace: ?[]const u8,
    continuation: ?session_store.ResumableSessionContinuation,
    limit: usize,
) !session_store.SessionListPage {
    if (limit == 0 or limit > session_store.session_list_max_limit) return error.InvalidSessionListLimit;
    var candidates: std.ArrayList(session_store.SessionSummary) = .empty;
    defer {
        for (candidates.items) |*summary| summary.deinit(alloc);
        candidates.deinit(alloc);
    }
    try v2Window(store, alloc, workspace, continuation, limit + 1, &candidates);
    session_summary_codec.sortSummariesNewestFirst(candidates.items);
    const v2_count = candidates.items.len;

    var v1_roots = try v1_conversion.listRoots(alloc, store.home, null);
    defer v1_roots.deinit(alloc);
    session_summary_codec.sortSummariesNewestFirst(v1_roots.summaries.items);
    var added: usize = 0;
    for (v1_roots.summaries.items) |summary| {
        if (workspace) |root| if (!std.mem.eql(u8, summary.workspace_root orelse continue, root)) continue;
        if (continuation) |position| if (!session_summary_codec.summaryFollowsContinuation(summary, position)) continue;
        // After `limit` newer ones, this one and every later one is off the page.
        if (countBefore(candidates.items[0..v2_count], summary) + added > limit) break;
        if (holdsV2(store, alloc, summary.id)) continue;
        try candidates.ensureUnusedCapacity(alloc, 1);
        candidates.appendAssumeCapacity(try session_summary_codec.cloneSessionSummary(alloc, summary));
        added += 1;
    }
    session_summary_codec.sortSummariesNewestFirst(candidates.items);
    var page = try session_summary_codec.sessionListPageFromSummaries(alloc, candidates.items, workspace, continuation, limit);
    // A workspace's page leaves out v1's roots that can't be read, whose
    // workspace is unknown, and counts them as v1 did; the profile-wide
    // listing shows them instead (D61).
    if (workspace != null and continuation == null) {
        for (v1_roots.summaries.items) |summary| {
            if (summary.workspace_root == null) page.skipped_invalid += 1;
        }
    }
    return page;
}

/// Appends v2's roots that follow `continuation` in v1's order to `out`,
/// owned by `alloc`: at least `want` when there are, and every one tied at
/// the time of the last, since v2 orders a tie by id ascending and v1 by
/// id descending (D11), so a page cut inside a tie has all of it.
fn v2Window(
    store: *Store,
    alloc: Allocator,
    workspace: ?[]const u8,
    continuation: ?session_store.ResumableSessionContinuation,
    want: usize,
    out: *std.ArrayList(session_store.SessionSummary),
) !void {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const filter: sm.Filter = if (workspace) |root| .{ .workspace = root } else .all;
    // From the continuation's time with its ties: those v1 orders first
    // are dropped below.
    var cursor: ?sm.ListCursor = if (continuation) |position| .{ .updated_ms = std.math.cast(u64, position.updated_at_ms) orelse return } else null;
    var kept: usize = 0;
    var cut: ?u64 = null;
    while (true) {
        var page = try store.manager.list(alloc, filter, cursor, want);
        defer page.deinit();
        for (page.items) |item| {
            if (cut) |at| if (item.updated_ms != at) return;
            var summary = try summaryOf(alloc, scratch.allocator(), item);
            if (continuation) |position| if (!session_summary_codec.summaryFollowsContinuation(summary, position)) {
                summary.deinit(alloc);
                continue;
            };
            out.append(alloc, summary) catch |err| {
                summary.deinit(alloc);
                return err;
            };
            kept += 1;
            if (kept == want) cut = item.updated_ms;
        }
        cursor = page.next orelse return;
    }
}

/// How many of `sorted`, newest first, come before `summary`.
fn countBefore(sorted: []const session_store.SessionSummary, summary: session_store.SessionSummary) usize {
    var count: usize = 0;
    while (count < sorted.len and session_summary_codec.summaryFollowsContinuation(summary, .{ .updated_at_ms = sorted[count].updated_at_ms, .id = sorted[count].id })) count += 1;
    return count;
}

// ---------------------------------------------------------------------------
// Live sessions, and subagents by name

/// How deep a live listing and an agent address follow subagents: spark nests
/// two levels below a root, and this leaves room. A log that names a deeper
/// chain, or a loop, stops here.
const max_agent_depth = 4;

/// Index rows read per page while scanning for live sessions. Each page
/// loads the whole index again, so one page covers any common profile.
const live_scan_page = 4096;

/// Every root session in `workspace`, or in every workspace when it is null,
/// that an spark process has open right now, newest first, each with its
/// subagents (`tests/tla/session/LiveSessions.tla`). A session is live while
/// a process holds its writer lock, which the kernel frees however the
/// process ends. The scan tries each lock without waiting and lets a free
/// one go at once (`isBusy`), then reads the live session's log without the
/// lock (D37). It writes nothing. A session whose lock can't be tried is not
/// live, and one whose log can't be read is listed as `unknown`; both are
/// traced. The caller frees the list with `deinit`.
pub fn listLive(store: *Store, alloc: Allocator, workspace: ?[]const u8) !session_store.LiveSessionList {
    var list: session_store.LiveSessionList = .{ .arena = .init(alloc), .sessions = &.{} };
    errdefer list.arena.deinit();
    const arena = list.arena.allocator();
    var sessions: std.ArrayList(session_store.LiveSession) = .empty;
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const filter: sm.Filter = if (workspace) |root| .{ .workspace = root } else .all;
    var cursor: ?sm.ListCursor = null;
    while (true) {
        var page = try store.manager.list(alloc, filter, cursor, live_scan_page);
        defer page.deinit();
        for (page.items) |item| {
            if (item.role != .root) continue;
            const live = store.manager.isBusy(item.id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    debug_trace.logf("session", "event=live_probe_failed session={s} err={s}", .{ item.id, @errorName(err) });
                    continue;
                },
            };
            if (!live) continue;
            _ = scratch.reset(.retain_capacity);
            try sessions.append(arena, try liveSession(store, arena, scratch.allocator(), item));
        }
        cursor = page.next orelse break;
    }
    list.sessions = sessions.items;
    return list;
}

/// Live root session `item`, read from its log into `arena`.
fn liveSession(store: *Store, arena: Allocator, scratch: Allocator, item: sm.Summary) !session_store.LiveSession {
    const summary = try summaryOf(arena, scratch, item);
    const peeked = store.manager.peek(scratch, item.id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("session", "event=live_peek_failed session={s} err={s}", .{ item.id, @errorName(err) });
            return .{ .summary = summary, .saved_model = null, .state = .unknown, .agents = &.{} };
        },
    };
    return .{
        .summary = summary,
        .saved_model = savedModel(arena, peeked.state.prefs),
        .state = if (peeked.state.open_turn != null) .working else .idle,
        .agents = try liveAgents(store, arena, scratch, item.id, peeked.state.children.items, 1),
    };
}

/// The model a session's `prefs` saved, copied into `arena`, or null when
/// it can't be read.
fn savedModel(arena: Allocator, prefs: ?[]const u8) ?[]const u8 {
    const raw = prefs orelse return null;
    const Saved = struct { model: ?[]const u8 = null };
    const saved = json_decode.parseFromSliceLeaky(Saved, arena, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    return saved.model;
}

/// A folded child as the subagent code reads it, borrowing `child`.
fn foldedChild(child: sm.Child) Child {
    return .{
        .id = child.id,
        .work_id = child.work_id,
        .open = child.open,
        .outcome = child.outcome,
        .spawn_data = child.spawn_data,
        .finish_data = child.finish_data,
        .seq = child.seq,
    };
}

/// The newest spawn in `children` that goes by `name`, closed for good or
/// not, so a closed subagent's turns stay readable. Null when none does.
fn newestNamed(scratch: Allocator, children: []const sm.Child, name: []const u8) ?sm.Child {
    var best: ?sm.Child = null;
    for (children) |child| {
        const own = child_state.foldedName(scratch, foldedChild(child)) orelse continue;
        if (!std.mem.eql(u8, own, name)) continue;
        if (best == null or child.seq > best.?.seq) best = child;
    }
    return best;
}

/// Whether a spawn in `children` that goes by `name` and is not closed for
/// good is newer than `seq`.
fn newerOpenNamed(scratch: Allocator, children: []const sm.Child, name: []const u8, seq: u64) bool {
    for (children) |child| {
        if (child.seq <= seq) continue;
        const entry = foldedChild(child);
        if (child_state.foldedClosed(entry)) continue;
        const own = child_state.foldedName(scratch, entry) orelse continue;
        if (std.mem.eql(u8, own, name)) return true;
    }
    return false;
}

/// The subagents a live listing shows of one parent, whose folded children
/// are `children`: each named one not closed for good, the newest spawn of
/// each name, with its own below it down to `max_agent_depth`. Their
/// addresses start with `parent`.
fn liveAgents(store: *Store, arena: Allocator, scratch: Allocator, parent: []const u8, children: []const sm.Child, depth: usize) ![]const session_store.LiveAgent {
    var agents: std.ArrayList(session_store.LiveAgent) = .empty;
    for (children) |child| {
        const entry = foldedChild(child);
        if (child_state.foldedClosed(entry)) continue;
        const name = child_state.foldedName(scratch, entry) orelse continue;
        if (newerOpenNamed(scratch, children, name, child.seq)) continue;
        const address = try std.mem.concat(arena, u8, &.{ parent, "/", name });
        var nested: []const session_store.LiveAgent = &.{};
        if (depth < max_agent_depth) {
            if (store.manager.peek(scratch, child.id)) |peeked| {
                nested = try liveAgents(store, arena, scratch, address, peeked.state.children.items, depth + 1);
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => debug_trace.logf("session", "event=live_agent_peek_failed session={s} err={s}", .{ child.id, @errorName(err) }),
            }
        }
        try agents.append(arena, .{
            .name = try arena.dupe(u8, name),
            .address = address,
            .id = try arena.dupe(u8, child.id),
            .state = if (child.open) .working else .idle,
            .agents = nested,
        });
    }
    return agents.items;
}

/// `<session-id>/<name>[/<name>...]`: a subagent by the names its parents
/// gave it, below a root session. Borrows the text it was parsed from.
pub const AgentAddress = struct {
    root: []const u8,
    names_buffer: [max_agent_depth][]const u8 = undefined,
    depth: usize = 0,

    fn names(address: *const AgentAddress) []const []const u8 {
        return address.names_buffer[0..address.depth];
    }
};

/// What `spark session <target>` names, before any session is read.
pub const SessionTarget = union(enum) {
    /// No `/`: a session id alone.
    session,
    agent: AgentAddress,
    /// An address `spark session` cannot follow.
    invalid: AddressProblem,
};

/// Why an agent address names no subagent, before any session is read.
pub const AddressProblem = union(enum) {
    /// The first part below the root that is not a name spark gives a
    /// subagent; empty when the address has an empty part.
    bad_name: []const u8,
    /// More names than `max_agent_depth`.
    too_deep,

    /// The problem as `spark session` says it, quoting the part at fault or
    /// `text`, the address, as a terminal can show it.
    pub fn describe(problem: AddressProblem, writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
        switch (problem) {
            .bad_name => |name| if (name.len == 0)
                try writer.print("{f} has an empty agent name", .{text_utils.terminalSafe(text)})
            else
                try writer.print(
                    "{f} is not an agent name; agent names are lowercase letters, digits, \"_\", and \"-\", start with a letter or digit, and are at most {d} bytes",
                    .{ text_utils.terminalSafe(name), subagent_domain.max_agent_name_bytes },
                ),
            .too_deep => try writer.print("{f} goes more than {d} agents deep", .{ text_utils.terminalSafe(text), max_agent_depth }),
        }
    }
};

/// Pure: what `text` names as a `spark session` target. Borrows `text`.
/// `error.InvalidSessionId` when the part before the first `/` is not a
/// session id.
pub fn parseSessionTarget(text: []const u8) error{InvalidSessionId}!SessionTarget {
    const slash = std.mem.findScalar(u8, text, '/') orelse return .session;
    var address: AgentAddress = .{ .root = text[0..slash] };
    session_store.validateSessionId(address.root) catch return error.InvalidSessionId;
    var parts = std.mem.splitScalar(u8, text[slash + 1 ..], '/');
    while (parts.next()) |name| {
        if (address.depth == max_agent_depth) return .{ .invalid = .too_deep };
        if (!subagent_domain.validAgentName(name)) return .{ .invalid = .{ .bad_name = name } };
        address.names_buffer[address.depth] = name;
        address.depth += 1;
    }
    return .{ .agent = address };
}

/// What an agent address names: the subagent's own session, or the first
/// name no subagent of `parent` goes by, with the names its subagents do.
/// Strings are borrowed from the arena `resolveAgent` was given.
const AgentLookup = union(enum) {
    found: []const u8,
    missing: struct { parent: []const u8, name: []const u8, names: []const []const u8 },
};

/// Follows `address` from its root session down the names each parent gave
/// its subagent, through each parent's log read without its lock (D37). A
/// name two children took reaches the newer, closed for good or not, so a
/// closed subagent's turns stay readable. A missing root, or one that is a
/// child itself, is `error.SessionNotFound`.
pub fn resolveAgent(store: *Store, arena: Allocator, address: AgentAddress) !AgentLookup {
    // Only `parseSessionTarget` makes one, and it names at least one subagent.
    std.debug.assert(address.depth >= 1);
    var peeked = store.manager.peek(arena, address.root) catch |err| return switch (err) {
        error.NotFound, error.InvalidArgument => error.SessionNotFound,
        else => err,
    };
    if (peeked.role != .root) return error.SessionNotFound;
    var parent: []const u8 = address.root;
    for (address.names(), 0..) |name, index| {
        const children = peeked.state.children.items;
        const child = newestNamed(arena, children, name) orelse
            return .{ .missing = .{ .parent = parent, .name = name, .names = try agentNames(arena, children) } };
        if (index + 1 == address.depth) return .{ .found = child.id };
        parent = try std.mem.concat(arena, u8, &.{ parent, "/", name });
        peeked = store.manager.peek(arena, child.id) catch |err| return switch (err) {
            error.NotFound, error.InvalidArgument => error.SessionNotFound,
            else => err,
        };
    }
    unreachable;
}

/// The names of the subagents in `children` that are not closed for good,
/// each once, in the order they were first started.
fn agentNames(arena: Allocator, children: []const sm.Child) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (children) |child| {
        const entry = foldedChild(child);
        if (child_state.foldedClosed(entry)) continue;
        const name = child_state.foldedName(arena, entry) orelse continue;
        for (out.items) |known| {
            if (std.mem.eql(u8, known, name)) break;
        } else try out.append(arena, name);
    }
    return out.items;
}

test "a session target splits into its root and the names below it" {
    const address = (try parseSessionTarget("abc123/reviewer/helper-2")).agent;
    try std.testing.expectEqualStrings("abc123", address.root);
    try std.testing.expectEqual(@as(usize, 2), address.names().len);
    try std.testing.expectEqualStrings("reviewer", address.names()[0]);
    try std.testing.expectEqualStrings("helper-2", address.names()[1]);
    try std.testing.expectEqual(SessionTarget.session, try parseSessionTarget("abc123"));
    // A part that is not a subagent name is named, an empty one as empty.
    for ([_][2][]const u8{ .{ "abc123/Reviewer", "Reviewer" }, .{ "abc123/a b", "a b" }, .{ "abc123/reviewer/x.y", "x.y" }, .{ "abc123/", "" }, .{ "abc123//reviewer", "" } }) |case| {
        try std.testing.expectEqualStrings(case[1], (try parseSessionTarget(case[0])).invalid.bad_name);
    }
    try std.testing.expectEqual(AddressProblem.too_deep, (try parseSessionTarget("abc123/a/b/c/d/e")).invalid);
    // A root that is not a session id is not one.
    for ([_][]const u8{ "/reviewer", "../x/reviewer", "a b/reviewer" }) |text| {
        try std.testing.expectError(error.InvalidSessionId, parseSessionTarget(text));
    }
    // The deepest address it takes.
    try std.testing.expectEqual(@as(usize, max_agent_depth), (try parseSessionTarget("abc123/a/b/c/d")).agent.depth);
}

fn fuzzAgentAddress(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [512]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    const slash = std.mem.findScalar(u8, bytes, '/');
    const target = parseSessionTarget(bytes) catch {
        // Only a root that is not a session id is refused.
        try std.testing.expect(slash != null);
        try std.testing.expectError(error.InvalidSessionId, session_store.validateSessionId(bytes[0..slash.?]));
        return;
    };
    const names = if (slash) |at| bytes[at + 1 ..] else {
        try std.testing.expectEqual(SessionTarget.session, target);
        return;
    };
    try session_store.validateSessionId(bytes[0..slash.?]);
    switch (target) {
        .session => return error.TestUnexpectedResult,
        .invalid => |problem| switch (problem) {
            .too_deep => try std.testing.expect(std.mem.count(u8, names, "/") >= max_agent_depth),
            .bad_name => |name| {
                // One of the parts, and the first that is not a subagent name.
                try std.testing.expect(!subagent_domain.validAgentName(name));
                var parts = std.mem.splitScalar(u8, names, '/');
                while (parts.next()) |part| {
                    if (part.ptr == name.ptr and part.len == name.len) break;
                    try std.testing.expect(subagent_domain.validAgentName(part));
                } else return error.TestUnexpectedResult;
            },
        },
        .agent => |address| {
            // A valid root and valid names that join back to the text.
            try std.testing.expect(address.depth >= 1 and address.depth <= max_agent_depth);
            var joined: std.ArrayList(u8) = .empty;
            defer joined.deinit(std.testing.allocator);
            try joined.appendSlice(std.testing.allocator, address.root);
            for (address.names()) |name| {
                try std.testing.expect(subagent_domain.validAgentName(name));
                try joined.append(std.testing.allocator, '/');
                try joined.appendSlice(std.testing.allocator, name);
            }
            try std.testing.expectEqualStrings(bytes, joined.items);
        },
    }
}

pub const Recovered = struct {
    id: []u8,
    /// Entries in the copy's history; a compaction summary counts as one.
    history_len: usize,
    /// False when a side file could not be copied.
    files_complete: bool,
    /// True when the source's saved permission rules could not be read, so
    /// the copy has none (D72).
    permission_rules_dropped: bool = false,

    pub fn deinit(recovered: *Recovered, alloc: Allocator) void {
        alloc.free(recovered.id);
        recovered.* = undefined;
    }
};

/// `spark session recover` (D15): a new root session copied from `id` up to
/// its last turn that ended before any damage, with a copy of its side
/// files. The source is never changed, and may be held by another process.
/// A v1 session is salvaged as v1's recover salvaged it (D64). Caller owns
/// the result.
pub fn recover(store: *Store, alloc: Allocator, id: []const u8) !Recovered {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    // Line 1 names the session's kind and workspace, however damaged the rest is.
    var first = store.manager.read(sa, id, .start, .forward, 1) catch |err| return switch (err) {
        error.NotFound, error.InvalidArgument => salvageV1(store, alloc, id),
        else => err,
    };
    defer first.deinit();
    if (first.entries.len == 0) return error.SessionNotFound;
    const created = switch (first.entries[0].body orelse return error.InvalidSessionFormat) {
        .session_created => |value| value,
        else => return error.InvalidSessionFormat,
    };
    if (created.role != .root) return error.SessionNotFound;
    const copy = store.manager.openFork(.{ .source = id, .at = .last_good, .workspace = created.workspace, .host = .ask }) catch |err| return switch (err) {
        error.NotFound, error.ChildSession => error.SessionNotFound,
        else => err,
    };
    defer copy.release();
    var restored = try restoreFrom(.{ .store = store, .id = copy.id(), .handle = copy }, alloc, sa, try copy.state(sa), null);
    defer restored.deinit(alloc);
    const copy_id = try alloc.dupe(u8, copy.id());
    errdefer alloc.free(copy_id);
    copy.close() catch |err| debug_trace.logf("session", "event=sessions_v2_recovered_close_failed session={s} err={s}", .{ copy_id, @errorName(err) });
    return .{ .id = copy_id, .history_len = restored.history.len, .files_complete = store.copyFiles(id, copy_id) };
}

/// `spark session recover` on a session only v1 holds (D64). Caller owns the
/// result.
fn salvageV1(store: *Store, alloc: Allocator, id: []const u8) !Recovered {
    var conversion: Conversion = .{ .store = store, .alloc = alloc, .host = .ask, .started = io_mod.nanoTimestamp() };
    defer conversion.deinit();
    return conversion.salvage(id);
}

pub const Doctor = struct {
    /// Saved root sessions.
    sessions: usize = 0,
    /// The most recently updated one.
    latest: ?[]u8 = null,
    /// Sessions whose log was checked, up to the limit.
    checked: usize = 0,
    /// Checked sessions with a damaged line or a stale snapshot.
    damaged: std.ArrayList([]u8) = .empty,
    /// Sessions within the limit whose check the caller's stop cut short or
    /// never started, with no damage found in what was read.
    unfinished: usize = 0,
    /// The caller's stop ended the scan of the sessions an older spark saved,
    /// so `unconverted`, `keeps_left_out`, and `kept_children` count only
    /// the folders read before it.
    v1_incomplete: bool = false,
    /// Side folders removed because their session is gone.
    removed: usize = 0,
    /// Side folders whose session is gone that `spark doctor --fix` would
    /// remove; counted only when the sweep does not remove.
    removable: usize = 0,
    /// Side folders with no session that could not be removed.
    kept: usize = 0,
    /// Roots an older spark saved that v2 does not hold yet; each converts
    /// when it is first opened (D73).
    unconverted: usize = 0,
    /// v1 folders of converted sessions and subagents, kept subagents among
    /// them, that keep something their copy left out (D56, D62).
    keeps_left_out: usize = 0,
    /// Those of them that can't be converted, among the checked ones.
    stuck: std.ArrayList(Stuck) = .empty,
    /// Each v1 subagent no conversion takes, kept as it is (D88).
    kept_children: []KeptChild = &.{},

    pub const Stuck = struct {
        id: []u8,
        /// The file and the reason the conversion refuses it.
        reason: []u8,
        /// What `spark session recover` copies of it.
        recover: enum { without_rules, good_turns, nothing },
    };

    pub fn deinit(report: *Doctor, alloc: Allocator) void {
        if (report.latest) |id| alloc.free(id);
        for (report.damaged.items) |id| alloc.free(id);
        report.damaged.deinit(alloc);
        for (report.stuck.items) |stuck| {
            alloc.free(stuck.id);
            alloc.free(stuck.reason);
        }
        report.stuck.deinit(alloc);
        freeKeptChildren(alloc, report.kept_children);
        report.* = undefined;
    }
};

/// A side folder younger than this may belong to a new session whose first
/// turn has not created its log yet (D36).
const orphan_min_age_ms: i64 = 24 * std.time.ms_per_hour;

/// What `spark doctor` does with a side folder whose session is gone.
pub const OrphanSweep = enum {
    /// Counts it as removable: plain `spark doctor`.
    count,
    /// Removes it: `spark doctor --fix`.
    remove,
};

/// `spark doctor` on v2 (D36): verifies up to `limit` sessions and finds side
/// folders whose session is gone, counting or removing them as `orphans`
/// says. Rebuilds nothing. Caller owns the report.
pub fn doctor(store: *Store, alloc: Allocator, limit: usize, now_ms: i64, orphans: OrphanSweep) !Doctor {
    return doctorWith(store, alloc, .{ .limit = limit, .now_ms = now_ms, .orphans = orphans });
}

pub const DoctorOptions = struct {
    /// The most sessions whose log is checked.
    limit: usize,
    now_ms: i64,
    orphans: OrphanSweep,
    /// `hash` reads every blob; `exists` only checks that each is a file.
    blobs: @FieldType(sm.VerifyOptions, "blobs") = .hash,
    /// When it says stop, the session being checked and the ones after it
    /// are counted in `Doctor.unfinished`, not checked.
    stop: ?sm.Stop = null,
    /// Told before each session's check, with how many are done and how
    /// many will be checked, so a long check can show where it is.
    progress: ?Progress = null,

    pub const Progress = struct {
        context: *anyopaque,
        report: *const fn (context: *anyopaque, done: usize, total: usize) void,
    };

    fn stopRequested(options: DoctorOptions) bool {
        return sm.Stop.now(options.stop);
    }

    fn tell(options: DoctorOptions, done: usize, total: usize) void {
        const progress = options.progress orelse return;
        progress.report(progress.context, done, total);
    }
};

/// `doctor`, with the blob check, stop, and progress `options` choose.
pub fn doctorWith(store: *Store, alloc: Allocator, options: DoctorOptions) !Doctor {
    var report: Doctor = .{};
    errdefer report.deinit(alloc);
    var latest_ms: u64 = 0;
    // The sessions to check, listed first so progress can say how many.
    var to_check: std.ArrayList([]u8) = .empty;
    defer {
        for (to_check.items) |id| alloc.free(id);
        to_check.deinit(alloc);
    }
    var cursor: ?sm.ListCursor = null;
    while (true) {
        var page = try store.manager.list(alloc, .all, cursor, list_page_size);
        defer page.deinit();
        for (page.items) |item| {
            if (item.role != .root) continue;
            report.sessions += 1;
            if (report.latest == null or item.updated_ms > latest_ms) {
                const id = try alloc.dupe(u8, item.id);
                if (report.latest) |old| alloc.free(old);
                report.latest = id;
                latest_ms = item.updated_ms;
            }
            if (to_check.items.len == options.limit) continue;
            try to_check.ensureUnusedCapacity(alloc, 1);
            to_check.appendAssumeCapacity(try alloc.dupe(u8, item.id));
        }
        cursor = page.next orelse break;
    }
    for (to_check.items, 0..) |id, done| {
        options.tell(done, to_check.items.len);
        if (options.stopRequested()) {
            report.unfinished += 1;
            continue;
        }
        const verified = store.manager.verifyWith(id, .{ .blobs = options.blobs, .stop = options.stop }) catch |err| switch (err) {
            error.NotFound => {
                report.checked += 1;
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                report.checked += 1;
                debug_trace.logf("session", "event=sessions_v2_doctor_unreadable session={s} err={s}", .{ id, @errorName(err) });
                try report.damaged.append(alloc, try alloc.dupe(u8, id));
                continue;
            },
        };
        // What the check read before it stopped still reports damage.
        const damaged = verified.damaged_at != null or verified.bad_snapshots > 0 or verified.bad_blobs > 0;
        if (damaged) try report.damaged.append(alloc, try alloc.dupe(u8, id));
        if (verified.stopped_at != null and !damaged) {
            debug_trace.logf("session", "event=sessions_v2_doctor_stopped session={s} at={d}", .{ id, verified.stopped_at.? });
            report.unfinished += 1;
        } else report.checked += 1;
    }
    options.tell(to_check.items.len, to_check.items.len);
    const limit = options.limit -| report.unfinished;
    try doctorV1(store, alloc, &report, limit, options.stop);
    var kept_complete = true;
    report.kept_children = try keptChildrenUntil(store, alloc, options.stop, &kept_complete);
    if (!kept_complete) report.v1_incomplete = true;
    for (report.kept_children) |child| report.keeps_left_out += @intFromBool(child.keeps);
    try store.sweepFiles(alloc, &report, options.now_ms, options.orphans);
    return report;
}

/// Counts the roots an older spark saved that v2 does not hold yet, and names
/// each checked one that can't be converted with what `spark session recover`
/// copies of it (D73). Reads only; a busy family is left out.
fn doctorV1(store: *Store, alloc: Allocator, report: *Doctor, limit: usize, stop: ?sm.Stop) !void {
    var complete = true;
    defer if (!complete) {
        report.v1_incomplete = true;
    };
    const roots = v1_conversion.rootIdsUntil(alloc, store.home, stop, &complete) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("session", "event=doctor_v1_unlisted err={s}", .{@errorName(err)});
            return;
        },
    };
    defer {
        for (roots) |root| root.deinit(alloc);
        alloc.free(roots);
    }
    for (roots) |root| {
        if (sm.Stop.now(stop)) {
            complete = false;
            break;
        }
        if (store.manager.peek(alloc, root.id)) |peeked_value| {
            var peeked = peeked_value;
            defer peeked.deinit(alloc);
            var scratch = std.heap.ArenaAllocator.init(alloc);
            defer scratch.deinit();
            const a = scratch.allocator();
            if (parseV1Source(a, peeked.state.v1_source)) |source| {
                if (source.keeps()) report.keeps_left_out += 1;
            }
            for (peeked.state.children.items) |child| {
                const present = v1_conversion.hasFolder(store.home, child.id) catch |err| {
                    debug_trace.logf("session", "event=doctor_v1_child_unread session={s} err={s}", .{ child.id, @errorName(err) });
                    continue;
                };
                if (!present) continue;
                const child_state_value = store.manager.peek(a, child.id) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {
                        debug_trace.logf("session", "event=doctor_v1_child_unread session={s} err={s}", .{ child.id, @errorName(err) });
                        continue;
                    },
                };
                if (parseV1Source(a, child_state_value.state.v1_source)) |source| {
                    if (source.keeps()) report.keeps_left_out += 1;
                }
            }
            continue;
        } else |err| switch (err) {
            error.NotFound, error.InvalidArgument => {},
            error.OutOfMemory => return err,
            else => continue,
        }
        report.unconverted += 1;
        if (report.checked == limit) continue;
        report.checked += 1;
        try report.stuck.ensureUnusedCapacity(alloc, 1);
        if (root.unreadable) |why| {
            report.stuck.appendAssumeCapacity(try stuckRoot(alloc, root.id, why, .nothing));
            continue;
        }
        if (try checkV1(store, alloc, root.id)) |stuck| report.stuck.appendAssumeCapacity(stuck);
    }
}

fn stuckRoot(alloc: Allocator, id: []const u8, reason: []const u8, recover_kind: @FieldType(Doctor.Stuck, "recover")) !Doctor.Stuck {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    return .{ .id = owned_id, .reason = try alloc.dupe(u8, reason), .recover = recover_kind };
}

/// Null when `root_id`'s family converts, or is busy.
fn checkV1(store: *Store, alloc: Allocator, root_id: []const u8) !?Doctor.Stuck {
    store.problem = .{};
    var v1 = try session_store.Store.initReadOnlyFromHome(alloc, store.home, "/");
    defer v1.deinit(alloc);
    var locks = v1_conversion.lockFamily(alloc, &v1, root_id, 0, &store.problem) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.SessionBusy, error.SessionNotFound => return null,
        error.InvalidSessionFormat => return try stuckRoot(alloc, root_id, store.problem.text(), .nothing),
        // A member folder others can write: `problem` names it and its fix (D61).
        else => return try stuckRoot(alloc, root_id, if (store.problem.len > 0) store.problem.text() else @errorName(err), .nothing),
    };
    defer locks.release();
    for (locks.members.items) |*locked| {
        var member = v1_conversion.readMember(alloc, &v1, locked, &store.problem, .required) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => break,
        };
        member.deinit();
    } else return null;
    var reason: [v1_conversion.Problem.capacity]u8 = undefined;
    const why = if (store.problem.len > 0) store.problem.text() else "its folder can't be read";
    @memcpy(reason[0..why.len], why);
    // What `recover` would copy, read in the order its salvage reads: a
    // root that reads whole is not salvaged at all.
    const root = &locks.members.items[0];
    const recover_kind: @FieldType(Doctor.Stuck, "recover") = kind: {
        store.problem = .{};
        if (v1_conversion.readMember(alloc, &v1, root, &store.problem, .required)) |whole| {
            var read = whole;
            read.deinit();
            break :kind .nothing;
        } else |err| if (err == error.OutOfMemory) return err;
        store.problem = .{};
        if (v1_conversion.readMember(alloc, &v1, root, &store.problem, .drop_unreadable)) |whole| {
            var read = whole;
            read.deinit();
            break :kind .without_rules;
        } else |err| if (err == error.OutOfMemory) return err;
        store.problem = .{};
        if (v1_conversion.readSalvage(alloc, &v1, root, &store.problem)) |salvaged| {
            var read = salvaged;
            read.deinit();
            break :kind .good_turns;
        } else |err| if (err == error.OutOfMemory) return err;
        break :kind .nothing;
    };
    return try stuckRoot(alloc, root_id, reason[0..why.len], recover_kind);
}

// ---------------------------------------------------------------------------
// Session: one per open session

/// Settings a new session starts with; held in memory until its first turn.
pub const Seed = struct {
    preferences: session_codec.DurableSessionPreferences,
    language: types.ConversationLanguage,
    /// A child's instructions, kept in its own `prefs` (D34); roots leave
    /// it empty.
    instructions: []const u8 = "",
};

pub const Target = union(enum) {
    id: []const u8,
    /// The newest updated root session in the workspace.
    last,
    /// The session this host last opened in the workspace (`spark -c`).
    last_opened,
};

/// What resume gives back. Owns everything; free with `deinit`.
pub const Restored = struct {
    history: []types.HistoryTurn,
    language: types.ConversationLanguage,
    preferences: ?session_codec.DurableSessionPreferences = null,
    /// The stored title, generated or chosen by the user.
    title: ?[]u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64 = 0,

    pub fn deinit(restored: *Restored, alloc: Allocator) void {
        types.freeHistoryTurnSlice(alloc, restored.history);
        if (restored.title) |value| alloc.free(value);
        if (restored.preferences) |*value| value.deinit(alloc);
        restored.* = undefined;
    }
};

/// A resumed session as v1's state. Owns everything; free with `deinit`.
pub const Resumed = struct {
    state: session_codec.DurableSessionState,
    title: ?[]u8,

    pub fn deinit(resumed: *Resumed, alloc: Allocator) void {
        resumed.state.deinit(alloc);
        if (resumed.title) |value| alloc.free(value);
        resumed.* = undefined;
    }
};

/// A session's blobs as spark's stores reach them (D44), shared by every
/// capability over the session, including the copies a background reader or
/// a running command keeps. It lives until the last holder releases it.
/// Once the session closes it stores nothing more; reads go to the
/// process's manager, which outlives every session.
///
/// Locks: `life` is held through each store, so a close waits for one in
/// flight; `mutex` guards only the counts and lists. Neither is taken while
/// the other is wanted, and no store takes the session's own lock.
const BlobHost = struct {
    alloc: Allocator,
    store: *Store,
    /// The session's id, owned.
    id: []u8,
    life: std.Io.Mutex = .init,
    /// The open session; null once it closed.
    session: ?sm.Session,
    mutex: std.Io.Mutex = .init,
    /// One write of the session at a time. `Session.write` holds it from
    /// taking the due records until it clears them, so two writes on
    /// different threads, such as main's compaction line and a subagent's
    /// finish line, never take the same records
    /// (`tests/tla/session/SessionWrite.tla` NoStaleRemoval, ListedOnce).
    /// Taken before `life` and `mutex`, and never while holding either.
    write_lock: std.Io.Mutex = .init,
    refs: usize = 1,
    /// Blobs stored since the last item that lists them (D44).
    pending: std.ArrayList(Hash) = .empty,
    /// A moved session's old side-file names, as `{folder}/{name}`, to their
    /// blobs (D47). Set while the session opens; read-only after.
    moved: std.StringHashMapUnmanaged(Hash) = .empty,
    /// The compactor's records by name (D50), loaded on open and kept
    /// since; `mutex` guards them.
    records: std.array_hash_map.String(Hash) = .empty,
    /// Records kept since the last `compaction_records` line, which the
    /// next one lists.
    records_added: std.ArrayList(Hash) = .empty,
    /// Counts record changes, so a line written while another record
    /// arrives leaves the map due again.
    records_generation: u64 = 0,
    records_written: u64 = 0,

    const Hash = session_child_store.Blobs.Hash;

    const vtable: session_child_store.Blobs.VTable = .{
        .put = put,
        .put_file = putFile,
        .put_record = putRecord,
        .record_names = recordNames,
        .resolve = resolve,
        .get = get,
        .path = path,
        .retain = retain,
        .release = release,
    };

    fn create(alloc: Allocator, store: *Store, handle: sm.Session) !*BlobHost {
        const host = try alloc.create(BlobHost);
        errdefer alloc.destroy(host);
        host.* = .{ .alloc = alloc, .store = store, .id = try alloc.dupe(u8, handle.id()), .session = handle };
        return host;
    }

    fn blobs(host: *BlobHost) session_child_store.Blobs {
        return .{ .ctx = host, .vtable = &vtable };
    }

    fn from(ctx: *anyopaque) *BlobHost {
        return @ptrCast(@alignCast(ctx));
    }

    /// The session is closing: waits for a store in flight, then refuses
    /// new ones. Blobs stored but never listed stay unreachable from a fork,
    /// so the trace counts them.
    fn detach(host: *BlobHost) void {
        const io = io_mod.getIo();
        host.life.lockUncancelable(io);
        host.session = null;
        host.life.unlock(io);
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        if (host.pending.items.len > 0) debug_trace.logf("session", "event=sessions_v2_blobs_unlisted session={s} count={d}", .{ host.id, host.pending.items.len });
        if (host.records_generation != host.records_written) debug_trace.logf("session", "event=sessions_v2_records_unlisted session={s} count={d}", .{ host.id, host.records_added.items.len });
    }

    /// A page of the session's log for a reader that holds the host: through
    /// the open session, or through the process's manager once it closed.
    /// A close waits for a read in flight, as it waits for a store.
    fn readLog(host: *BlobHost, sa: Allocator, from_cursor: sm.From, direction: sm.Direction, limit: usize) !sm.Page {
        const io = io_mod.getIo();
        host.life.lockUncancelable(io);
        defer host.life.unlock(io);
        if (host.session) |handle| return handle.read(sa, from_cursor, direction, limit);
        return host.store.manager.read(sa, host.id, from_cursor, direction, limit);
    }

    fn put(ctx: *anyopaque, bytes: []const u8) session_child_store.BlobError!Hash {
        const host = from(ctx);
        const io = io_mod.getIo();
        host.life.lockUncancelable(io);
        defer host.life.unlock(io);
        const handle = host.session orelse return error.BlobStoreClosed;
        const hash = handle.putBlob(bytes) catch |err| return host.storeFailed(err);
        try host.remember(hash);
        return hash;
    }

    fn putFile(ctx: *anyopaque, file: std.Io.File, len: u64) session_child_store.BlobError!Hash {
        const host = from(ctx);
        const io = io_mod.getIo();
        host.life.lockUncancelable(io);
        defer host.life.unlock(io);
        const handle = host.session orelse return error.BlobStoreClosed;
        const hash = handle.putBlobFile(file, len) catch |err| return host.storeFailed(err);
        try host.remember(hash);
        return hash;
    }

    fn putRecord(ctx: *anyopaque, name: []const u8, bytes: []const u8) session_child_store.BlobError!void {
        const host = from(ctx);
        const io = io_mod.getIo();
        host.life.lockUncancelable(io);
        defer host.life.unlock(io);
        const handle = host.session orelse return error.BlobStoreClosed;
        const hash = handle.putBlob(bytes) catch |err| return host.storeFailed(err);
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        try host.records_added.ensureUnusedCapacity(host.alloc, 1);
        if (host.records.getPtr(name)) |known| {
            known.* = hash;
        } else {
            const key = try host.alloc.dupe(u8, name);
            errdefer host.alloc.free(key);
            try host.records.put(host.alloc, key, hash);
        }
        host.records_added.appendAssumeCapacity(hash);
        host.records_generation += 1;
    }

    /// Every record's name, then a moved session's old tool-results names
    /// that no record replaced (D47, D50).
    fn recordNames(ctx: *anyopaque, arena: Allocator) session_child_store.BlobError![]const []const u8 {
        const host = from(ctx);
        const io = io_mod.getIo();
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        var names: std.ArrayList([]const u8) = .empty;
        try names.ensureTotalCapacity(arena, host.records.count() + host.moved.count());
        for (host.records.keys()) |name| names.appendAssumeCapacity(try arena.dupe(u8, name));
        // `movedFolder(.tool_results)`'s names.
        const prefix = "tool-results/";
        var moved = host.moved.keyIterator();
        while (moved.next()) |key| {
            if (!std.mem.startsWith(u8, key.*, prefix)) continue;
            const name = key.*[prefix.len..];
            if (host.records.contains(name)) continue;
            names.appendAssumeCapacity(try arena.dupe(u8, name));
        }
        return names.items;
    }

    /// The records map as JSON and the records it adds, when it changed
    /// since the last line that recorded it (D50); in `a`.
    fn recordsDue(host: *BlobHost, a: Allocator) error{OutOfMemory}!?RecordsDue {
        const io = io_mod.getIo();
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        if (host.records_generation == host.records_written) return null;
        var map: std.array_hash_map.String([]const u8) = .empty;
        try map.ensureTotalCapacity(a, host.records.count());
        for (host.records.keys(), host.records.values()) |name, *hash| map.putAssumeCapacity(name, try a.dupe(u8, hash));
        var json: std.Io.Writer.Allocating = .init(a);
        std.json.Stringify.value(std.json.ArrayHashMap([]const u8){ .map = map }, .{}, &json.writer) catch return error.OutOfMemory;
        return .{ .map_json = json.written(), .added = try a.dupe(Hash, host.records_added.items), .generation = host.records_generation };
    }

    /// A durable line now records `due`: its records are listed, and the map
    /// is current unless a record arrived since.
    fn recordsWritten(host: *BlobHost, due: RecordsDue) void {
        const io = io_mod.getIo();
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        host.records_added.replaceRangeAssumeCapacity(0, due.added.len, &.{});
        host.records_written = due.generation;
    }

    const RecordsDue = struct { map_json: []const u8, added: []const Hash, generation: u64 };

    fn storeFailed(host: *BlobHost, err: sm.AppendError) session_child_store.BlobError {
        // A body is stored only while the session is on disk (D44).
        if (err == error.InvalidTransition) debug_trace.logf("session", "event=sessions_v2_body_before_turn session={s}", .{host.id});
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.TooLarge => error.BlobTooLarge,
            error.SessionClosed => error.BlobStoreClosed,
            error.NoSpaceLeft => error.NoSpaceLeft,
            error.AccessDenied => error.AccessDenied,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            error.FileTooBig => error.FileTooBig,
            error.InvalidArgument, error.InvalidTransition, error.Io => error.BlobStoreFailed,
        };
    }

    fn remember(host: *BlobHost, hash: Hash) error{OutOfMemory}!void {
        const io = io_mod.getIo();
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        for (host.pending.items) |*known| if (std.mem.eql(u8, known, &hash)) return;
        try host.pending.append(host.alloc, hash);
    }

    /// The pending blobs, in `a`.
    fn pendingCopy(host: *BlobHost, a: Allocator) error{OutOfMemory}![]Hash {
        const io = io_mod.getIo();
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        return a.dupe(Hash, host.pending.items);
    }

    /// Forgets pending blobs a durable line now lists.
    fn listed(host: *BlobHost, hashes: []const Hash) void {
        const io = io_mod.getIo();
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        for (hashes) |*hash| {
            for (host.pending.items, 0..) |*known, index| {
                if (!std.mem.eql(u8, known, hash)) continue;
                _ = host.pending.orderedRemove(index);
                break;
            }
        }
    }

    fn resolve(ctx: *anyopaque, kind: session_child_store.ManagedChildKind, name: []const u8) session_child_store.BlobError!Hash {
        const host = from(ctx);
        if (artifact_digest.blobHash(name)) |hash| return hash[0..artifact_digest.blob_hex_bytes].*;
        if (kind == .tool_results) {
            const io = io_mod.getIo();
            host.mutex.lockUncancelable(io);
            defer host.mutex.unlock(io);
            if (host.records.get(name)) |hash| return hash;
        }
        const folder = movedFolder(kind) orelse return error.BlobNotFound;
        var key_buffer: [movedKeyMax]u8 = undefined;
        const key = std.mem.print(&key_buffer, "{s}/{s}", .{ folder, name }) catch return error.BlobNotFound;
        return host.moved.get(key) orelse error.BlobNotFound;
    }

    fn get(ctx: *anyopaque, alloc: Allocator, hash: []const u8, max_bytes: usize) session_child_store.BlobError![]u8 {
        const host = from(ctx);
        const bytes = host.store.manager.getBlob(alloc, host.id, hash) catch |err| return blobReadFailed(err);
        if (bytes.len > max_bytes) {
            alloc.free(bytes);
            return error.BlobTooLarge;
        }
        return bytes;
    }

    fn path(ctx: *anyopaque, alloc: Allocator, hash: []const u8) session_child_store.BlobError![]u8 {
        const host = from(ctx);
        return host.store.manager.blobPath(alloc, host.id, hash) catch |err| blobReadFailed(err);
    }

    fn blobReadFailed(err: sm.BlobError) session_child_store.BlobError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidArgument, error.NotFound => error.BlobNotFound,
            error.Corrupt => error.BlobDamaged,
            error.NoSpaceLeft => error.NoSpaceLeft,
            error.AccessDenied => error.AccessDenied,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            error.FileTooBig => error.FileTooBig,
            error.Io => error.BlobStoreFailed,
        };
    }

    fn retain(ctx: *anyopaque) void {
        const host = from(ctx);
        const io = io_mod.getIo();
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        host.refs += 1;
    }

    fn release(ctx: *anyopaque) void {
        const host = from(ctx);
        const io = io_mod.getIo();
        host.mutex.lockUncancelable(io);
        host.refs -= 1;
        const last = host.refs == 0;
        host.mutex.unlock(io);
        if (!last) return;
        var keys = host.moved.keyIterator();
        while (keys.next()) |key| host.alloc.free(key.*);
        host.moved.deinit(host.alloc);
        for (host.records.keys()) |name| host.alloc.free(name);
        host.records.deinit(host.alloc);
        host.records_added.deinit(host.alloc);
        host.pending.deinit(host.alloc);
        host.alloc.free(host.id);
        host.alloc.destroy(host);
    }
};

/// The side-folder layout an older session kept each kind of body in, as
/// `session_child_store` routes it; the key prefix of its moved names (D47).
fn movedFolder(kind: session_child_store.ManagedChildKind) ?[]const u8 {
    return switch (kind) {
        .tool_results => "tool-results",
        .command_artifacts => "logs/commands",
        .browser_artifacts => "artifacts/web-fetch",
        else => null,
    };
}

/// A moved name's key: a folder of a few bytes and a handle of at most 160.
const movedKeyMax = 256;

/// Whether the session `spark -c` opens in `workspace` left its newest turn
/// unfinished: still open, or ended by a crash or a closed window. A session
/// another spark has open is working, not interrupted. Reads the index, the
/// session's lock, and its log tail, and writes nothing.
pub fn hasInterruptedTurn(store: *Store, alloc: Allocator, workspace: []const u8) bool {
    const id = (store.manager.lastOpened(alloc, workspace, .app) catch return false) orelse return false;
    defer alloc.free(id);
    if (store.manager.isBusy(id) catch true) return false;
    var peeked = store.manager.peek(alloc, id) catch return false;
    defer peeked.deinit(alloc);
    const state = peeked.state;
    const turn = if (state.open_turn) |open| open else blk: {
        const last = state.last_interrupted orelse return false;
        if (last.turn != state.last_turn or !(last.reason == .crash or last.reason == .closed)) return false;
        break :blk last.turn;
    };
    return firstHint(store, alloc, id, turn);
}

/// Whether this is the first launch to point at turn `turn` of session `id`.
/// The hint names one interrupted turn once: launches after it that send
/// nothing don't repeat it. The last turn hinted is kept in
/// `~/.spark/sessions/v2/interrupted-hint`.
fn firstHint(store: *Store, alloc: Allocator, id: []const u8, turn: u64) bool {
    const path = profile_paths.rootPath(alloc, store.home, &.{ profile_paths.sessions_dir_name, session_layout.sessions_v2_dir, "interrupted-hint" }) catch return true;
    defer alloc.free(path);
    var key_buf: [96]u8 = undefined;
    const key = std.mem.print(&key_buf, "{s}:{d}", .{ id, turn }) catch return true;
    if (std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, alloc, .limited(128))) |seen| {
        defer alloc.free(seen);
        if (std.mem.eql(u8, std.mem.trim(u8, seen, " \n"), key)) return false;
    } else |_| {}
    io_mod.writeFileAtomic(alloc, path, key) catch {};
    return true;
}

pub const Session = struct {
    alloc: Allocator,
    store: *Store,
    handle: sm.Session,
    /// `~/.spark/session-files/{id}`, owned: where an older session kept its
    /// side files, read once by the move (D47).
    files_path: []u8,
    /// The session's blobs, shared with every capability over it (D44).
    host: *BlobHost,
    capability: ?session_child_store.SessionChildCapability = null,
    /// Serializes this adapter's own state; the manager's Session is
    /// thread-safe on its own.
    mutex: std.Io.Mutex = .init,
    /// Encodings of the open turn's pieces already appended, in order.
    streamed: std.ArrayList([]u8) = .empty,
    /// Result files the open turn's stream wrote, by call id; both owned.
    stored_results: std.StringHashMapUnmanaged([]u8) = .empty,
    /// Ids of the open turn's calls already saved as running (D28), owned.
    running: std.ArrayList([]u8) = .empty,
    /// Prompt images saved as blobs (D89), digest to blob path, both owned.
    /// The store deletes no blob of a live session, so an entry stays true,
    /// and every copy of a turn the host passes encodes its images alike.
    prompt_blobs: std.array_hash_map.String([]u8) = .empty,
    /// The workspace captures of the current capture turn and of the ended
    /// one waiting for its commit, each with its token, in the order saved
    /// (D98). Each turn's stay until its `commitTurnWithCaptures` lands or
    /// a later `beginCaptureTurn` drops them; a fresh turn after a
    /// supersede writes its starts again.
    captures: std.ArrayList(Capture) = .empty,
    /// The token of the current capture turn (`CaptureTurn`), drawn from
    /// `capture_turns`; 0 when no capture turn is open.
    capture_turn: u64 = 0,
    /// The token of a turn whose end capture was taken and whose commit
    /// has not landed when the next turn began (`beginCaptureTurnKeeping`):
    /// its captures stay held for its own commit. 0 when none waits; at
    /// most one does.
    ended_turn: u64 = 0,
    /// The capture token whose turn is open on disk, set by the write that
    /// opens it; 0 when that write belonged to no capture turn, such as a
    /// commit of an earlier turn. Only this turn takes `captures` (D98).
    turn_token: u64 = 0,
    /// The open turn is one a failed turn left behind: the next write
    /// closes it as superseded instead of continuing it (D98).
    turn_stale: bool = false,
    turn_open: bool = false,
    /// Highest turn number started; the manager numbers turns the same way.
    last_turn: u64 = 0,
    /// The v2 turn behind each of spark's history turns, in order; null for a
    /// compacted summary.
    turn_numbers: std.ArrayList(?u64) = .empty,
    /// What spark's history leaves out of its first kept turn (D87).
    trim: Trim = .{},
    /// The language tag last written, owned.
    language: ?[]u8 = null,
    /// Started in this process: its first commit may name it.
    fresh: bool,
    /// A host's own session, not a subagent child's: `Wiring.tla` models
    /// only these.
    root: bool = true,
    titled: bool = false,
    /// Set once this open handed out its owed reports (`pendingReportLines`).
    reports_handed_out: bool = false,
    /// A resumed session with no title: the title its first prompt gives,
    /// owned, written with its next turn end (D52).
    first_title: ?[]u8 = null,
    /// A child's instructions as its `prefs` hold them (D34), owned; null
    /// for a root and for a child without any.
    instructions: ?[]u8 = null,
    /// A conversion's import: the original time of the batches it writes
    /// next (D59). Null for every other session.
    import_ts: ?u64 = null,
    /// The session's token totals as its newest `set usage` holds them
    /// (D92), read from the log on the first reply this process records.
    usage: ?types.Usage = null,

    pub fn create(alloc: Allocator, store: *Store, workspace: []const u8, host: Host, seed: Seed) !*Session {
        // Every v2 write needs a writable open, and both start here or in
        // resumeSession: E2E tests use this to prove read-only paths never
        // reach one.
        io_mod.e2eFailIfDurableMutationAttempted();
        const handle = try newHandle(store, workspace, host);
        errdefer handle.release();
        const self = try init(alloc, store, handle, true);
        errdefer self.destroyInner();
        try self.appendSeed(seed);
        traceWiring("Open", self.id(), "", self.store.pid);
        return self;
    }

    /// A new session whose id no v1 folder has, so it never hides a session
    /// still to convert (`tests/tla/session_manager/V1Conversion.tla` NoShadow). `openNew` touches
    /// no disk, so a taken id costs one more try.
    fn newHandle(store: *Store, workspace: []const u8, host: Host) !sm.Session {
        for (0..8) |_| {
            const handle = try store.manager.openNew(.{ .workspace = workspace, .host = host });
            const taken = v1_conversion.hasFolder(store.home, handle.id()) catch |err| {
                debug_trace.logf("convert", "action=IdUnchecked session={s} err={s}", .{ handle.id(), @errorName(err) });
                handle.release();
                return error.SessionStoreUnavailable;
            };
            if (!taken) return handle;
            debug_trace.logf("convert", "action=IdTaken session={s}", .{handle.id()});
            handle.release();
        }
        return error.SessionStoreUnavailable;
    }

    /// The settings a new session holds until its first turn.
    fn appendSeed(self: *Session, seed: Seed) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        _ = try self.write(&.{
            .{ .set = .{ .key = .prefs, .value = try encodePreferences(a, seed.preferences, self.instructions) } },
            .{ .set = .{ .key = .language, .value = try jsonString(a, seed.language.view()) } },
        });
        self.language = try self.alloc.dupe(u8, seed.language.view());
    }

    /// Opens a child of `parent_id` for one work item (D22, D34): its log
    /// when it has one, or a new child under `child_id`, the id the parent's
    /// `child_spawned` already names, holding `seed` until its first turn.
    /// Instructions in `seed` replace the stored ones; empty keeps them.
    pub fn openChild(alloc: Allocator, store: *Store, parent_id: []const u8, child_id: []const u8, workspace: []const u8, seed: Seed) !*Session {
        io_mod.e2eFailIfDurableMutationAttempted();
        if (store.manager.openResume(.{ .target = .{ .id = child_id }, .workspace = workspace, .host = .child, .parent = parent_id })) |handle| {
            errdefer handle.release();
            const self = try init(alloc, store, handle, false);
            errdefer self.destroyInner();
            self.root = false;
            try self.openMoved();
            var scratch = std.heap.ArenaAllocator.init(alloc);
            defer scratch.deinit();
            const state = try handle.state(scratch.allocator());
            self.last_turn = state.last_turn;
            // Every child starts with its preferences (`appendSeed`).
            const raw = state.prefs orelse return error.InvalidSessionFormat;
            self.instructions = try decodeInstructions(alloc, raw);
            if (seed.instructions.len > 0 and !std.mem.eql(u8, seed.instructions, self.childInstructions())) {
                var preferences = try decodePreferences(alloc, raw);
                defer preferences.deinit(alloc);
                try self.replaceInstructions(preferences, seed.instructions);
            }
            return self;
        } else |err| switch (err) {
            error.NotFound => {},
            else => return err,
        }
        const handle = try store.manager.openNew(.{ .workspace = workspace, .host = .child, .role = .child, .parent = parent_id, .id = child_id });
        errdefer handle.release();
        const self = try init(alloc, store, handle, false);
        errdefer self.destroyInner();
        self.root = false;
        if (seed.instructions.len > 0) self.instructions = try alloc.dupe(u8, seed.instructions);
        try self.appendSeed(seed);
        return self;
    }

    /// The session's current preferences. Caller owns.
    pub fn currentPreferences(self: *Session, alloc: Allocator) !session_codec.DurableSessionPreferences {
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const state = try self.handle.state(scratch.allocator());
        return decodePreferences(alloc, state.prefs orelse return error.InvalidSessionFormat);
    }

    /// A child's instructions (D34), or empty. Borrowed until `close`.
    pub fn childInstructions(self: *const Session) []const u8 {
        return self.instructions orelse "";
    }

    fn replaceInstructions(self: *Session, preferences: session_codec.DurableSessionPreferences, text: []const u8) !void {
        const owned = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(owned);
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        _ = try self.write(&.{.{ .set = .{ .key = .prefs, .value = try encodePreferences(arena.allocator(), preferences, owned) } }});
        if (self.instructions) |old| self.alloc.free(old);
        self.instructions = owned;
    }

    pub fn resumeSession(alloc: Allocator, store: *Store, target: Target, workspace: []const u8, host: Host) !*Session {
        return resumeWaiting(alloc, store, target, workspace, host, null);
    }

    /// As `resumeSession`, but SessionBusy at once when another process has
    /// the session open, for the session picker (D38).
    pub fn resumeSessionWithoutWaiting(alloc: Allocator, store: *Store, target: Target, workspace: []const u8, host: Host) !*Session {
        return resumeWaiting(alloc, store, target, workspace, host, 0);
    }

    /// `lock_wait_ms` null waits 2 s for the writer lock, v2's or v1's. A
    /// session only v1 holds is converted first, its family whole (D55,
    /// D61, `tests/tla/session_manager/V1Conversion.tla`): every host opens through here.
    fn resumeWaiting(alloc: Allocator, store: *Store, target: Target, workspace: []const u8, host: Host, lock_wait_ms: ?u64) !*Session {
        io_mod.e2eFailIfDurableMutationAttempted();
        // A reason belongs to this open only, never an earlier one's.
        store.problem = .{};
        const started = io_mod.nanoTimestamp();
        switch (target) {
            .id => |session_id| return openOrConvert(alloc, store, session_id, workspace, host, lock_wait_ms, started),
            // The newest of the listing, which holds v1's unconverted roots
            // too (D61).
            .last => {
                const newest = (try newestListed(store, alloc, workspace)) orelse return noLatestError(store, alloc);
                defer alloc.free(newest);
                return openOrConvert(alloc, store, newest, workspace, host, lock_wait_ms, started);
            },
            .last_opened => {
                if (store.manager.openResume(.{ .target = .{ .last_opened = host }, .workspace = workspace, .host = host, .lock_wait_ms = lock_wait_ms })) |handle| {
                    return opened(alloc, store, handle, true);
                } else |err| switch (err) {
                    error.NotFound => {},
                    else => return resumeError(err, target),
                }
                // v1's remembered session, when v2 has none (D56).
                const remembered = (try v1_conversion.rememberedId(alloc, store.home, workspace)) orelse return error.NoRememberedSession;
                defer alloc.free(remembered);
                return openOrConvert(alloc, store, remembered, workspace, host, lock_wait_ms, started);
            },
        }
    }

    /// Opens `session_id`, converting it first when only v1 holds it. The
    /// `[convert] action=Opened` line times a converting open from `started`
    /// to its return.
    fn openOrConvert(alloc: Allocator, store: *Store, session_id: []const u8, workspace: []const u8, host: Host, lock_wait_ms: ?u64, started: i128) !*Session {
        const target: Target = .{ .id = session_id };
        const resume_options: sm.ResumeOptions = .{ .target = .{ .id = session_id }, .workspace = workspace, .host = host, .lock_wait_ms = lock_wait_ms };
        if (store.manager.openResume(resume_options)) |handle| {
            return opened(alloc, store, handle, true);
        } else |err| switch (err) {
            error.NotFound => {},
            else => return resumeError(err, target),
        }
        var conversion: Conversion = .{ .store = store, .alloc = alloc, .host = host, .started = started };
        defer conversion.deinit();
        const outcome = try conversion.family(session_id, lock_wait_ms orelse v1_conversion.lock_wait_ms);
        const handle = store.manager.openResume(resume_options) catch |err| return resumeError(err, target);
        // Held: another process converted it, and may have left v1 state.
        const self = try opened(alloc, store, handle, outcome == .held);
        if (outcome == .converted) {
            const ms = @as(f64, @floatFromInt(io_mod.nanoTimestamp() - started)) / std.time.ns_per_ms;
            debug_trace.logf("convert", "action=Opened session={s} members={d} turns={d} files={d} ms={d:.3}", .{ session_id, conversion.members, conversion.turns, conversion.files, ms });
            conversion.tellLeftOut(session_id);
        }
        return self;
    }

    /// `clean` removes what a conversion left in v1 for this session.
    fn opened(alloc: Allocator, store: *Store, handle: sm.Session, clean: bool) !*Session {
        errdefer handle.release();
        const self = try init(alloc, store, handle, false);
        errdefer self.destroyInner();
        try self.openMoved();
        var state = try handle.state(alloc);
        defer state.deinit(alloc);
        self.last_turn = state.last_turn;
        if (clean) cleanLeftovers(store, alloc, self.id(), &state);
        traceWiring("Open", self.id(), "", self.store.pid);
        return self;
    }

    fn init(alloc: Allocator, store: *Store, handle: sm.Session, fresh: bool) !*Session {
        const files_path = try profile_paths.rootPath(alloc, store.home, &.{ files_dir_name, handle.id() });
        errdefer alloc.free(files_path);
        const host = try BlobHost.create(alloc, store, handle);
        errdefer BlobHost.release(host);
        const self = try alloc.create(Session);
        self.* = .{ .alloc = alloc, .store = store, .handle = handle, .files_path = files_path, .host = host, .fresh = fresh };
        return self;
    }

    pub fn id(self: *const Session) []const u8 {
        return self.handle.id();
    }

    /// Appends through the manager; a host session also traces the turn and
    /// child lines `Wiring.tla` models. The first item lists every blob the
    /// stores kept since the last such line, so verify and recover see a
    /// lost one as damage (D39, D44). Compactor records kept since the last
    /// `compaction_records` line get a new one first, so the line that
    /// cites them never lands without them (D50). Writes of the session run
    /// one at a time (`BlobHost.write_lock`).
    fn write(self: *Session, events: []const sm.Event) sm.AppendError!u64 {
        self.host.write_lock.lockUncancelable(io_mod.getIo());
        defer self.host.write_lock.unlock(io_mod.getIo());
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const a = scratch.allocator();
        const due = try self.host.recordsDue(a);
        if (due) |records| write_test_controls.holdDueRecords(records.added.len);
        const with_records = if (due) |records| try std.mem.concat(a, sm.Event, &.{ try self.recordLines(a, records), events }) else events;
        const pending = try self.host.pendingCopy(a);
        const batch = try listPending(a, with_records, pending);
        const seq = if (self.import_ts) |ts| try self.handle.appendAt(batch.events, ts) else try self.handle.append(batch.events);
        if (batch.listed) self.host.listed(pending);
        if (due) |records| self.host.recordsWritten(records);
        if (self.root) for (events) |event| switch (event) {
            .turn_started => traceWiring("BeginTurn", self.id(), "", self.store.pid),
            .turn_committed => traceWiring("EndTurn", self.id(), " end=commit", self.store.pid),
            .turn_interrupted => traceWiring("EndTurn", self.id(), " end=interrupt", self.store.pid),
            .child_spawned => traceWiring("Spawn", self.id(), "", self.store.pid),
            .child_finished => traceWiring("ChildDone", self.id(), "", self.store.pid),
            else => {},
        };
        return seq;
    }

    /// The `compaction_records` lines for `due`: its map as one more blob,
    /// listed with the records it adds, in chunks as the move's are (D50).
    fn recordLines(self: *Session, a: Allocator, due: BlobHost.RecordsDue) sm.AppendError![]const sm.Event {
        const map_hash = try a.dupe(u8, &(try self.handle.putBlob(due.map_json)));
        const value = try a.print("{{\"map\":\"{s}\"}}", .{map_hash});
        var refs: std.ArrayList([]const u8) = .empty;
        try refs.ensureTotalCapacity(a, due.added.len + 1);
        for (due.added) |*hash| refs.appendAssumeCapacity(hash);
        refs.appendAssumeCapacity(map_hash);
        var lines: std.ArrayList(sm.Event) = .empty;
        var rest = refs.items;
        while (rest.len > 0) {
            const take = @min(rest.len, moved_refs_per_line);
            try lines.append(a, .{ .set = .{ .key = .compaction_records, .value = value, .blobs = rest[0..take] } });
            rest = rest[take..];
        }
        return lines.items;
    }

    /// The session is on disk, so `spark --resume` opens it: from its first
    /// turn, ended or open, or from its open when it was resumed or forked.
    /// A fork before the first prompt holds no turn and is saved (D90).
    pub fn saved(self: *const Session) bool {
        return self.handle.onDisk();
    }

    /// The session's folder under `~/.spark/sessions/v2`, for display. Caller owns it.
    pub fn folderPath(self: *const Session, alloc: Allocator) ![]u8 {
        return profile_paths.rootPath(alloc, self.store.home, &.{ profile_paths.sessions_dir_name, session_layout.sessions_v2_dir, self.id() });
    }

    /// Closes the session and frees the adapter. Every child thread of this
    /// session must have joined (`tests/tla/session_manager/Wiring.tla` ParentOutlivesChildren).
    /// A copy of its capability that a background reader still holds keeps
    /// reading, and stores nothing more (D44).
    pub fn close(self: *Session) void {
        // Before the close, which forgets whether the log is on disk.
        const was_saved = self.saved();
        // A failed turn left open is closed as superseded, so readers drop it
        // with its captures instead of keeping it as an interrupted turn (D98).
        if (self.turn_open and self.turn_stale) {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            self.supersedeOpenTurn("failed_turn") catch |err| debug_trace.logf("session", "event=sessions_v2_stale_turn_kept session={s} err={s}", .{ self.id(), @errorName(err) });
        }
        self.host.detach();
        self.handle.close() catch |err| debug_trace.logf("session", "event=sessions_v2_close_failed session={s} err={s}", .{ self.id(), @errorName(err) });
        if (self.root) traceWiring("Close", self.id(), "", self.store.pid);
        if (self.turn_open) debug_trace.logf("session", "event=sessions_v2_turn_closed_open session={s} streamed={d}", .{ self.id(), self.streamed.items.len });
        self.traceDroppedCaptures("closed");
        // Before `release`: the id lives in the handle.
        if (!was_saved) self.removeUnsavedFiles();
        self.handle.release();
        self.destroyInner();
    }

    /// A session that never reached the disk takes its terminal folder with
    /// it, as v1 removes a pristine session's folder. Asks the manager
    /// first: a first write that failed may still have landed.
    fn removeUnsavedFiles(self: *Session) void {
        var probe = self.store.manager.read(self.alloc, self.id(), .start, .forward, 1) catch |err| switch (err) {
            error.NotFound => null,
            else => {
                debug_trace.logf("session", "event=sessions_v2_unsaved_files_kept session={s} err={s}", .{ self.id(), @errorName(err) });
                return;
            },
        };
        if (probe) |*page| {
            page.deinit();
            return;
        }
        self.store.removeFiles(self.id(), "unsaved");
    }

    fn destroyInner(self: *Session) void {
        const alloc = self.alloc;
        if (self.capability) |*capability| capability.deinit();
        BlobHost.release(self.host);
        self.clearStreamed();
        self.streamed.deinit(alloc);
        self.stored_results.deinit(alloc);
        self.running.deinit(alloc);
        for (self.prompt_blobs.keys(), self.prompt_blobs.values()) |digest, path| {
            alloc.free(digest);
            alloc.free(path);
        }
        self.prompt_blobs.deinit(alloc);
        self.clearCaptures();
        self.captures.deinit(alloc);
        self.turn_numbers.deinit(alloc);
        if (self.language) |value| alloc.free(value);
        if (self.instructions) |value| alloc.free(value);
        if (self.first_title) |value| alloc.free(value);
        alloc.free(self.files_path);
        alloc.destroy(self);
    }

    /// Forgets what the open turn holds, once it ends or is superseded.
    fn clearStreamed(self: *Session) void {
        for (self.streamed.items) |bytes| self.alloc.free(bytes);
        self.streamed.clearRetainingCapacity();
        var stored = self.stored_results.iterator();
        while (stored.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.stored_results.clearRetainingCapacity();
        for (self.running.items) |call_id| self.alloc.free(call_id);
        self.running.clearRetainingCapacity();
    }

    // -- bodies --------------------------------------------------------------

    /// The capability over this session's blobs (D44): it stores and reads
    /// large bodies, routes terminal state to `~/.spark/terminal/{id}` (D45),
    /// and has no side folder. Borrowed until `close`.
    pub fn childCapability(self: *Session) !*session_child_store.SessionChildCapability {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.capabilityLocked();
    }

    fn capabilityLocked(self: *Session) !*session_child_store.SessionChildCapability {
        if (self.capability) |*capability| return capability;
        const terminal_path = try profile_paths.rootPath(self.alloc, self.store.home, &.{ terminal_dir_name, self.id() });
        defer self.alloc.free(terminal_path);
        self.capability = try session_child_store.SessionChildCapability.initBlobs(self.alloc, self.host.blobs(), terminal_path, .writable);
        return &self.capability.?;
    }

    // -- turns ---------------------------------------------------------------

    /// Opens the turn on disk if it is not open yet, so a body stored for it
    /// is a blob of a session on disk (D44). `opener` is the capture token
    /// of the turn being opened, or 0 when it is not the current capture
    /// turn's. Caller holds the mutex.
    fn openTurnLocked(self: *Session, opener: u64) !void {
        if (self.turn_open and !self.turn_stale) return;
        if (self.turn_open) try self.supersedeOpenTurn("failed_turn");
        var batch: std.ArrayList(sm.Event) = .empty;
        defer batch.deinit(self.alloc);
        try batch.append(self.alloc, .turn_started);
        try self.appendHeldStarts(self.alloc, &batch, opener);
        _ = try self.write(batch.items);
        self.startedTurn(opener);
    }

    /// Opens the turn as its work starts. A subagent child streams nothing,
    /// and its tools may store bodies before the commit (D44); an ACP prompt
    /// opens it before the model is asked, so a disk that cannot take the
    /// turn fails the prompt first.
    pub fn beginTurn(self: *Session) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        try self.openTurnLocked(self.capture_turn);
    }

    /// Stores the turn's tool results and images as blobs and gives them
    /// handles, as v1 does at commit. A result whose blob the stream already
    /// wrote (`withResultFiles`) keeps it, unwritten a second time.
    pub fn prepareTurn(self: *Session, turn: *types.HistoryTurn) !void {
        try self.reuseStreamedFiles(turn);
        {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            const stores = switch (turn.*) {
                .assistant => |entry| storesBodies(entry.execution),
                .interrupted => |entry| storesBodies(entry.execution),
                .compacted_summary => false,
            };
            // The turn prepared may be an earlier one than the current capture
            // turn's, so it opens with no captures.
            if (stores) try self.openTurnLocked(0);
        }
        try session_log.externalizeConversationTurnResults(self.alloc, turn, try self.childCapability());
    }

    fn reuseStreamedFiles(self: *Session, turn: *types.HistoryTurn) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.stored_results.count() == 0) return;
        const execution = switch (turn.*) {
            .assistant => |*entry| &entry.execution,
            .interrupted => |*entry| &entry.execution,
            .compacted_summary => return,
        };
        for (execution.tool_steps) |step| for (step.tool_results) |*result| {
            if (result.output_handle != null) continue;
            const stored = self.stored_results.get(result.tool_call_id) orelse continue;
            // The name is the content's hash, so a match means the same bytes.
            const handle = try result_store.blobHandle(self.alloc, result.output);
            if (!std.mem.eql(u8, handle, stored)) {
                self.alloc.free(handle);
                continue;
            }
            result.output_handle = handle;
            result.stored_output_bytes = result.output.len;
        };
    }

    /// Appends a finished turn: the pieces not streamed yet, then its end,
    /// in one durable batch. `turn` must already be prepared. Writes no
    /// workspace capture and leaves the current capture turn as it is, so a
    /// commit of an earlier turn, such as ACP's interrupted one, never takes
    /// the next turn's captures: an open turn that holds another capture
    /// token's written starts, with nothing streamed, is superseded rather
    /// than continued (`othersOpenTurn`, D98).
    pub fn commitTurn(self: *Session, turn: types.HistoryTurn, language: types.ConversationLanguage) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        try self.commitTurnLocked(turn, language, 0);
    }

    /// Commits `turn` as `commitTurn` does, with the workspace captures of
    /// `capture`, the turn's token: start captures not on disk yet and every
    /// end capture join the closing batch, before `turn_committed` or
    /// `turn_interrupted`. Once the batch lands the capture turn ends. A
    /// failed commit keeps the captures, so a retry of the same turn with
    /// the same token writes them once; the next `beginCaptureTurn` drops
    /// them. The token may be the current one or the ended one a later turn
    /// kept (`beginCaptureTurnKeeping`); each commit takes only its own
    /// token's captures and never continues a turn another token opened
    /// (`othersOpenTurn`). Any other token commits the turn without
    /// captures (D98).
    pub fn commitTurnWithCaptures(self: *Session, turn: types.HistoryTurn, language: types.ConversationLanguage, capture: CaptureTurn) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const token = @backingInt(capture);
        const held = token != 0 and (token == self.capture_turn or token == self.ended_turn);
        if (!held) debug_trace.logf("session", "event=sessions_v2_workspace_captures_dropped session={s} reason=turn_closed held=0", .{self.id()});
        try self.commitTurnLocked(turn, language, if (held) token else 0);
        if (held) {
            self.clearCapturesOf(token);
            if (token == self.capture_turn) self.capture_turn = 0 else self.ended_turn = 0;
        }
    }

    /// `owner` is the capture token whose captures the turn takes, current
    /// or ended, or 0.
    fn commitTurnLocked(self: *Session, turn: types.HistoryTurn, language: types.ConversationLanguage, owner: u64) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var events: std.ArrayList(Event) = .empty;
        try session_event.appendHistoryTurnConversationEvents(a, &events, turn);
        if (events.items.len < 2) return error.InvalidConversationFrame;
        const pieces = events.items[0 .. events.items.len - 1];
        const end = events.items[events.items.len - 1];

        // The end piece joins the others; its line ends the turn.
        const all = events.items;
        const encoded = try a.alloc([]u8, all.len);
        for (all, encoded) |piece, *bytes| bytes.* = try self.encodeEvent(a, piece);
        if (self.othersOpenTurn(owner)) try self.supersedeOpenTurn("other_turn");
        const start = try self.streamedPrefix(encoded[0..pieces.len], .commit, countResults(pieces));

        var tail: std.ArrayList(sm.Event) = .empty;
        if (owner != 0) {
            // A turn already open, but not by this token, has not taken its
            // starts yet; one opened by the batch below takes them first.
            if (self.turn_open) for (self.captures.items) |capture| {
                if (capture.turn == owner and capture.place == .start and !capture.written) try tail.append(a, .{ .item = capturePiece(capture.data) });
            };
            // End captures close the turn with it, in the order saved (D98).
            for (self.captures.items) |capture| {
                if (capture.turn == owner and capture.place == .end) try tail.append(a, .{ .item = capturePiece(capture.data) });
            }
        }
        switch (end) {
            .turn_completed => try tail.append(a, .turn_committed),
            .interrupted => |interruption| try tail.append(a, .{ .turn_interrupted = switch (interruption.reason) {
                .cancelled => .cancel,
                .failed => .failed,
            } }),
            else => return error.InvalidConversationFrame,
        }
        const language_tag = language.view();
        const language_changed = self.language == null or !std.mem.eql(u8, self.language.?, language_tag);
        if (language_changed) try tail.append(a, .{ .set = .{ .key = .language, .value = try jsonString(a, language_tag) } });
        // A new session's first turn names it, or a resumed one's first
        // prompt, which a crash may have left in an interrupted turn (D52).
        const derived_title = if (!self.root or self.titled)
            null
        else if (self.first_title) |title|
            title
        else if (self.fresh)
            try deriveTitle(a, &.{turn})
        else
            null;
        if (derived_title) |title| try tail.append(a, .{ .set = .{ .key = .title, .value = try jsonString(a, title) } });

        // Allocated first: once the batch lands, nothing here can fail and
        // leave this side thinking the turn is still open.
        try self.turn_numbers.ensureUnusedCapacity(self.alloc, 1);
        const owned_language = if (language_changed) try self.alloc.dupe(u8, language_tag) else null;
        errdefer if (owned_language) |owned| self.alloc.free(owned);

        try self.writePieces(a, all[start..], encoded[start..], tail.items, openingAuthor(turn), owner);
        self.turn_numbers.appendAssumeCapacity(self.last_turn);
        self.turn_open = false;
        self.turn_token = 0;
        self.clearStreamed();
        if (owned_language) |owned| {
            if (self.language) |old| self.alloc.free(old);
            self.language = owned;
        }
        if (derived_title != null) self.titled = true;
        self.fresh = false;
    }

    /// Whether the open turn belongs to another capture token than `owner`,
    /// a commit's token or 0, so the commit supersedes it instead of
    /// continuing it, even when nothing streamed into it lets
    /// `streamedPrefix` tell the turns apart. The supersede holds that
    /// token's captures again, so its own turn writes them when it opens
    /// afresh (D98).
    ///
    /// A commit with a token knows its turn: a turn another nonzero token
    /// opened is never its own, as when a kept ended turn's late commit
    /// finds the next turn open. A plain commit carries no token, so it may
    /// be the open turn's own, committed without its captures. With pieces
    /// streamed, their content decides. With none, continuing harms only a
    /// turn holding its token's written captures, which the commit would
    /// take, as when ACP commits an earlier turn after the next one opened
    /// with its start; only that turn is superseded.
    fn othersOpenTurn(self: *const Session, owner: u64) bool {
        if (!self.turn_open or self.turn_stale) return false;
        const token = self.turn_token;
        if (token == 0 or token == owner) return false;
        if (owner != 0) return true;
        if (self.streamed.items.len != 0) return false;
        for (self.captures.items) |capture| {
            if (capture.turn == token and capture.written) return true;
        }
        return false;
    }

    /// Saves each prompt image of the turn as a blob named by its digest
    /// before the turn's first request is built, and gives the image that
    /// blob's path for the model's note (`AgentRuntimeDeps.save_prompt_images`,
    /// D89, `tests/tla/session_manager/PromptImages.tla`). Each save lists
    /// the blob again on the turn's next item, so a fork hard-links it even
    /// after a crash lost an earlier listing. A saved image then keeps only
    /// that handle, and readers load its bytes from the blob. An image the
    /// store refuses keeps its bytes inline, as before D89, and gets no
    /// path. An image that arrives as only a handle, perhaps to another
    /// session's blob, is saved from that file. `alloc` owns `images` and
    /// what this sets on them; the bytes an image arrived with are the
    /// caller's and are not freed.
    pub fn savePromptImages(self: *Session, alloc: Allocator, images: []types.ImageAttachment) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (images) |*image| {
            // Bytes this read from the file a handle names, which `alloc` owns.
            var loaded: ?[]u8 = null;
            if (image.inline_data == null) {
                const verified = image_attachments.loadVerifiedSnapshot(alloc, image.*, .{}) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {
                        debug_trace.logf("session", "event=sessions_v2_prompt_image_unreadable session={s} image={d} reason={s}", .{ self.id(), image.id, @errorName(err) });
                        image.blob_path = null;
                        continue;
                    },
                };
                loaded = verified.bytes;
                image.inline_data = verified.bytes;
            }
            image.blob_path = null;
            const bytes = image.inline_data.?;
            const digest = image.snapshot_sha256 orelse continue;
            const path = self.savePromptImageLocked(bytes, digest) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    debug_trace.logf("session", "event=sessions_v2_prompt_image_inline session={s} image={d} reason={s}", .{ self.id(), image.id, @errorName(err) });
                    continue;
                },
            };
            image.blob_path = try alloc.dupe(u8, path);
            image.inline_data = null;
            if (loaded) |value| alloc.free(value);
        }
    }

    /// The path of the blob holding `bytes`, owned by `prompt_blobs`. A turn
    /// the store cannot start fails the save, as a refused blob does, so the
    /// image stays inline and the prompt goes on.
    fn savePromptImageLocked(self: *Session, bytes: []const u8, digest: []const u8) ![]const u8 {
        // A blob needs the turn on disk (D44).
        try self.openTurnLocked(self.capture_turn);
        const hash = try BlobHost.put(self.host, bytes);
        // The digest names the blob: bytes that do not match it are not
        // saved under it.
        if (!std.mem.eql(u8, &hash, digest)) return error.ImageDigestMismatch;
        if (self.prompt_blobs.get(digest)) |path| return path;
        // The blob's path once the session is published, as
        // `Manager.blobPath` joins it, so a conversion's staged import (D59)
        // names its images too. The put above just stored the file.
        const path = try std.Io.Dir.path.join(self.alloc, &.{ self.store.manager.root_path, self.id(), "blobs", &hash });
        errdefer self.alloc.free(path);
        const key = try self.alloc.dupe(u8, digest);
        errdefer self.alloc.free(key);
        try self.prompt_blobs.put(self.alloc, key, path);
        return path;
    }

    /// `event` as this session writes it: an image is written as a blob
    /// exactly when this session saved it as one, whichever copy of the turn
    /// the host passes and whatever path the copy carries. So a commit
    /// matches what was streamed, and an item never names another session's
    /// blob (D89, `tests/tla/session_manager/PromptImages.tla` RefHasBlob).
    fn encodeEvent(self: *Session, a: Allocator, event: Event) ![]u8 {
        const user = switch (event) {
            .user => |value| value,
            .tool_result => |value| return encodePiece(a, .{ .tool_result = try withoutReviewLines(value) }),
            else => return encodePiece(a, event),
        };
        if (user.images.len == 0) return encodePiece(a, event);
        const images = try a.dupe(types.ImageAttachment, user.images);
        for (images) |*image| {
            const digest = image.snapshot_sha256 orelse {
                image.blob_path = null;
                continue;
            };
            image.blob_path = self.prompt_blobs.get(digest);
        }
        return encodePiece(a, .{ .user = .{ .text = user.text, .images = images, .work_id = user.work_id } });
    }

    /// Streams the turn so far (`AgentRuntimeDeps.append_turn_piece`): the
    /// first call starts the turn, later calls append only the pieces
    /// completed since. A tool result gets the side file the commit would
    /// write for it (`withResultFiles`); a tool image without its handle
    /// waits for the commit, which is authoritative. `running`'s calls are
    /// saved once each as `tool_running` items, outside the streamed pieces,
    /// so a finished step still streams and commits as it always did (D28),
    /// and its message's text with them (D51).
    pub fn appendProgress(
        self: *Session,
        user: types.UserTurn,
        execution: types.ExecutionMemory,
        running: Running,
    ) !void {
        return self.appendProgressWithRecord(user, execution, running, .keep);
    }

    /// `appendProgress`, with the recovery module's record for the send this
    /// write goes before (`recovery_type`).
    pub fn appendProgressWithRecord(
        self: *Session,
        user: types.UserTurn,
        execution: types.ExecutionMemory,
        running: Running,
        record: types.RecoveryRecordWrite,
    ) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var events: std.ArrayList(Event) = .empty;
        try events.append(a, .{ .user = .{ .text = user.text, .images = user.images, .work_id = user.work_id } });
        // A result's blob needs the turn on disk first (D44).
        if (storesBodies(execution)) try self.openTurnLocked(self.capture_turn);
        // On a missing handle the list keeps the pieces before it.
        session_event.appendExecutionConversationEvents(a, &events, try self.withResultFiles(a, execution)) catch |err| switch (err) {
            error.ConversationArtifactRequired => {},
            else => return err,
        };
        const encoded = try a.alloc([]u8, events.items.len);
        for (events.items, encoded) |event, *bytes| bytes.* = try self.encodeEvent(a, event);
        const start = try self.streamedPrefix(encoded, .stream, countResults(events.items));
        // The record goes out in the same write as the pieces before its
        // send, so a turn's first write already carries it
        // (`tests/tla/recovery/Resume.tla` CrashLoopAsks).
        var tail: std.ArrayList(sm.Event) = .empty;
        if (try self.recoveryItem(a, record)) |piece| try tail.append(a, .{ .item = piece });
        if (!self.turn_open or start < encoded.len) {
            try self.writePieces(a, events.items[start..], encoded[start..], tail.items, user.author, self.capture_turn);
            try self.streamed.ensureUnusedCapacity(self.alloc, encoded.len - start);
            for (encoded[start..]) |bytes| self.streamed.appendAssumeCapacity(try self.alloc.dupe(u8, bytes));
        } else if (tail.items.len > 0) {
            _ = try self.write(tail.items);
        }
        try self.saveRunning(a, running);
    }

    /// Saves or clears the record in the open turn. A turn not written yet
    /// takes the record with its first pieces instead, so this writes
    /// nothing and returns false.
    pub fn saveRecovery(self: *Session, record: types.RecoveryRecordWrite) !bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        // A failed turn left open is not the turn the record belongs to: the
        // fresh turn's first write takes it (D98).
        if (!self.turn_open or self.turn_stale) return false;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const piece = (try self.recoveryItem(a, record)) orelse return false;
        _ = try self.write(&.{.{ .item = piece }});
        return true;
    }

    /// Where a workspace capture goes in its turn (D98).
    pub const CapturePlace = enum {
        /// Written in the open turn now, or with the first write of a
        /// turn not on disk yet.
        start,
        /// Held for `commitTurn`, which writes it in the turn's closing
        /// batch, before `turn_committed` or `turn_interrupted`.
        end,
    };

    /// A workspace capture: its payload, owned, the capture token of its
    /// turn, and whether the open turn holds it on disk.
    const Capture = struct { data: []u8, place: CapturePlace, turn: u64, written: bool = false };

    /// The turn a workspace capture belongs to (D98), from
    /// `beginCaptureTurn`. Good only for this Session, and only until that
    /// turn's `commitTurnWithCaptures` lands or the next `beginCaptureTurn`.
    pub const CaptureTurn = enum(u64) { _ };

    /// Begins the captures of a new turn and returns its token. A host
    /// calls it once as each turn starts, saves every capture of that turn
    /// with the token, and commits the turn with `commitTurnWithCaptures`,
    /// so one that arrives late is dropped instead of joining a later turn.
    /// Whatever an earlier token still holds is dropped here, however that
    /// turn ended, such as a failed commit with no retry or a `prepareTurn`
    /// that failed (D98).
    pub fn beginCaptureTurn(self: *Session) CaptureTurn {
        return self.beginCaptureTurnKeeping(null);
    }

    /// `beginCaptureTurn`, except that `ended`, when it is the current token
    /// and its turn's end capture is taken but its commit has not landed,
    /// keeps its captures for that commit: in the app, a prompt sent while
    /// the previous answer is still drawn begins its turn before the UI
    /// commits the previous one. At most one ended turn waits, so one kept
    /// before is dropped as superseded. A null or other `ended` drops every
    /// earlier token's captures, as `beginCaptureTurn` does (D98).
    pub fn beginCaptureTurnKeeping(self: *Session, ended: ?CaptureTurn) CaptureTurn {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const keep = if (ended) |token| self.capture_turn != 0 and @backingInt(token) == self.capture_turn else false;
        self.dropCapturesOf(self.ended_turn, "superseded_token");
        if (keep) {
            debug_trace.logf("session", "event=sessions_v2_workspace_captures_kept session={s} reason=ended_turn", .{self.id()});
            self.ended_turn = self.capture_turn;
        } else {
            self.ended_turn = 0;
            self.dropCapturesOf(self.capture_turn, "superseded_token");
        }
        self.capture_turn = capture_turns.fetchAdd(1, .monotonic);
        // A turn opened for no capture turn and still live is this turn,
        // started before its token: an ACP prompt or a prompt image opens it
        // first. When an ended turn is kept, it is that turn's instead: its
        // `prepareTurn` opens it with no token just before its late commit,
        // while this turn's writes before now carried the ended token. A turn
        // an earlier token opened keeps that token.
        if (self.turn_open and !self.turn_stale and self.turn_token == 0) self.turn_token = if (keep) self.ended_turn else self.capture_turn;
        return @fromBackingInt(self.capture_turn);
    }

    const SaveWorkspaceCaptureError = error{
        InvalidWorkspaceCapture,
        WorkspaceCaptureTooLarge,
        /// `turn` has ended: its `commitTurnWithCaptures` landed or a later
        /// `beginCaptureTurn` replaced it.
        WorkspaceCaptureTurnClosed,
    } || sm.AppendError;

    /// Saves `payload`, one repository's workspace capture for `turn`, as a
    /// `workspace_capture` item outside the streamed pieces, so it never
    /// supersedes the turn and never reaches the model's messages (D98).
    /// `payload` is an encoded JSON object this does not interpret, at most
    /// `max_workspace_capture_bytes`, without line breaks; the caller keeps
    /// whatever phase it names in step with `place`. Returns true when it is
    /// written now and false when it is held: an end until
    /// `commitTurnWithCaptures`, a start until its turn's first write or that
    /// commit. A crash or `close` before then loses what is held, and so
    /// does the next `beginCaptureTurn`. A refused payload, a closed turn or
    /// a failed write keeps nothing.
    pub fn saveWorkspaceCapture(self: *Session, turn: CaptureTurn, payload: []const u8, place: CapturePlace) SaveWorkspaceCaptureError!bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const token = @backingInt(turn);
        if (token == 0 or (token != self.capture_turn and token != self.ended_turn)) {
            debug_trace.logf("session", "event=sessions_v2_workspace_captures_dropped session={s} reason=turn_closed held=1", .{self.id()});
            return error.WorkspaceCaptureTurnClosed;
        }
        try checkWorkspaceCapture(self.alloc, payload);
        try self.captures.ensureUnusedCapacity(self.alloc, 1);
        const data = try self.alloc.dupe(u8, payload);
        errdefer self.alloc.free(data);
        // Only the turn this token opened takes it now: a failed turn left
        // open waits for the fresh turn that replaces it, and a turn opened
        // for an earlier commit never takes it.
        const now = place == .start and self.turn_open and !self.turn_stale and self.turn_token == token;
        if (now) _ = try self.write(&.{.{ .item = capturePiece(data) }});
        self.captures.appendAssumeCapacity(.{ .data = data, .place = place, .turn = token, .written = now });
        return now;
    }

    /// Appends the start captures of `opener`, a capture token, not on
    /// disk yet to the write that opens its turn; `startedTurn` marks them
    /// written once that write lands. Only that token's captures go.
    fn appendHeldStarts(self: *const Session, a: Allocator, batch: *std.ArrayList(sm.Event), opener: u64) !void {
        if (opener == 0) return;
        for (self.captures.items) |capture| {
            if (capture.turn == opener and capture.place == .start and !capture.written) try batch.append(a, .{ .item = capturePiece(capture.data) });
        }
    }

    fn clearCaptures(self: *Session) void {
        for (self.captures.items) |capture| self.alloc.free(capture.data);
        self.captures.clearRetainingCapacity();
    }

    /// Forgets the captures of token `turn`, keeping the others in order.
    fn clearCapturesOf(self: *Session, turn: u64) void {
        var kept: usize = 0;
        for (self.captures.items) |capture| {
            if (capture.turn == turn) {
                self.alloc.free(capture.data);
            } else {
                self.captures.items[kept] = capture;
                kept += 1;
            }
        }
        self.captures.shrinkRetainingCapacity(kept);
    }

    /// Forgets the captures of token `turn`, a turn that did not commit.
    /// When the open turn is that turn's and holds some of them, it is the
    /// failed turn, left open: the next write closes it as superseded
    /// rather than adding to it, so readers drop it with its captures
    /// (D98). Token 0 holds nothing.
    fn dropCapturesOf(self: *Session, turn: u64, reason: []const u8) void {
        if (turn == 0) return;
        self.traceDroppedCapturesOf(turn, reason);
        for (self.captures.items) |capture| {
            if (capture.turn == turn and capture.written and self.turn_open and self.turn_token == turn) self.turn_stale = true;
        }
        self.clearCapturesOf(turn);
    }

    /// Names what a drop discards: captures held in memory, and captures
    /// already in the open turn, which its supersede discards.
    fn traceDroppedCaptures(self: *const Session, reason: []const u8) void {
        self.traceDroppedCapturesOf(null, reason);
    }

    /// `traceDroppedCaptures` for token `turn`'s captures only, or every
    /// token's when null.
    fn traceDroppedCapturesOf(self: *const Session, turn: ?u64, reason: []const u8) void {
        var held: usize = 0;
        var written: usize = 0;
        for (self.captures.items) |capture| {
            if (turn) |token| if (capture.turn != token) continue;
            if (capture.written) written += 1 else held += 1;
        }
        if (held + written > 0) debug_trace.logf("session", "event=sessions_v2_workspace_captures_dropped session={s} reason={s} held={d} written={d}", .{ self.id(), reason, held, written });
    }

    /// Saves a call a command made through `spark mcp call` in the open turn,
    /// as it ends (`bridge_call_type`). The shell call that ran the command
    /// is still running, so the turn is open; with none open, nothing is
    /// written and the caller logs the row as dropped.
    pub fn saveBridgeCall(self: *Session, record: types.BridgeCallRecord) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.turn_open) return error.NoOpenTurn;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        _ = try self.write(&.{.{ .item = .{ .type = bridge_call_type, .data = try encodeBridgeCall(a, record) } }});
    }

    fn recoveryItem(self: *Session, a: Allocator, record: types.RecoveryRecordWrite) !?sm.Piece {
        const bytes: []u8 = switch (record) {
            .keep => return null,
            .save => |value| try a.print("{{\"record\":\"{x}\"}}", .{&value}),
            .clear => try a.dupe(u8, "{\"record\":null}"),
        };
        return try self.itemAs(a, recovery_type, bytes);
    }

    /// The model request a crash or a close left unfinished in the newest
    /// turn: the record of its newest `recovery` piece, null when its
    /// response had arrived or none was saved, and when it was saved. Null
    /// when the newest turn ended otherwise, has no prompt, or completed.
    pub fn interruptedRequest(self: *Session) !?InterruptedRequest {
        var state = try self.handle.state(self.alloc);
        defer state.deinit(self.alloc);
        const ended = state.last_interrupted orelse return null;
        if (state.open_turn != null or ended.turn != state.last_turn) return null;
        switch (ended.reason) {
            .crash, .closed => {},
            .cancel, .failed => return null,
        }
        var found: InterruptedRequest = .{ .record = null, .saved_ms = 0 };
        var record_seen = false;
        var has_prompt = false;
        var from: sm.From = .end;
        scan: while (true) {
            var page = try self.source().readTo(self.alloc, from, .backward, replay_page_lines);
            defer page.deinit();
            for (page.entries) |entry| {
                const body = entry.body orelse continue;
                switch (body) {
                    .turn_started => |started| if (started.turn == ended.turn) break :scan,
                    .item => |piece| {
                        if (found.saved_ms == 0) found.saved_ms = entry.ts_ms;
                        if (std.mem.eql(u8, piece.type, itemType(.turn_completed).?)) return null;
                        if (std.mem.eql(u8, piece.type, itemType(.user).?)) has_prompt = true;
                        if (record_seen or !std.mem.eql(u8, piece.type, recovery_type)) continue;
                        record_seen = true;
                        found.saved_ms = entry.ts_ms;
                        found.record = parseRecoveryRecord(try self.source().pieceData(page.arena.allocator(), piece));
                    },
                    else => {},
                }
            }
            from = .{ .at = page.next orelse break };
        }
        return if (has_prompt) found else null;
    }

    /// See `interruptedRequest`.
    pub const InterruptedRequest = struct {
        record: ?[32]u8,
        /// `ts` of the line that saved the record, or of the turn's newest
        /// piece when no record was saved.
        saved_ms: u64,
    };

    /// The step whose calls are running: its calls in their saved form, and
    /// the text of the message that issued them.
    pub const Running = struct {
        calls: []const types.ToolCall = &.{},
        assistant: ?[]const u8 = null,
    };

    /// Saves the calls not yet saved as running in the open turn, which the
    /// pieces above have just opened if it was not. A step's first save also
    /// keeps its message's text as an `assistant_running` item (D51). Not
    /// its provider replay, which binds to all of that message's calls.
    fn saveRunning(self: *Session, a: Allocator, running: Running) !void {
        var batch: std.ArrayList(sm.Event) = .empty;
        var ids: std.ArrayList([]const u8) = .empty;
        for (running.calls) |call| {
            if (self.isRunning(call.id)) continue;
            const bytes = try encodePiece(a, .{ .tool_call = conversationToolCall(call) });
            try batch.append(a, .{ .item = try self.itemAs(a, running_type, bytes) });
            try ids.append(a, call.id);
        }
        if (batch.items.len == 0) return;
        const text = running.assistant orelse "";
        if (text.len > 0) {
            const bytes = try encodePiece(a, .{ .assistant = .{ .text = text } });
            try batch.insert(a, 0, .{ .item = try self.itemAs(a, running_assistant_type, bytes) });
        }
        _ = try self.write(batch.items);
        try self.running.ensureUnusedCapacity(self.alloc, ids.items.len);
        for (ids.items) |call_id| self.running.appendAssumeCapacity(try self.alloc.dupe(u8, call_id));
    }

    fn isRunning(self: *const Session, call_id: []const u8) bool {
        for (self.running.items) |running_id| if (std.mem.eql(u8, running_id, call_id)) return true;
        return false;
    }

    /// A copy of `execution` in which each tool result without a result file
    /// has the one the commit gives it (`session_log.externalizeConversationTurnResults`):
    /// the same handle, size and preview, so its streamed piece is the
    /// committed one. A result backed only by its command replay has no file
    /// before then. Each file is written once a turn.
    fn withResultFiles(self: *Session, a: Allocator, execution: types.ExecutionMemory) !types.ExecutionMemory {
        var copy = execution;
        copy.tool_steps = try a.dupe(types.ToolExecutionStep, execution.tool_steps);
        for (copy.tool_steps) |*step| {
            step.tool_results = try a.dupe(types.PersistedToolResult, step.tool_results);
            for (step.tool_results) |*result| {
                if (result.output_handle != null) continue;
                const handle = self.stored_results.get(result.tool_call_id) orelse blk: {
                    const stored = try result_store.storeLargeResultManaged(self.alloc, try self.capabilityLocked(), result.tool_call_id, result.tool_name, result.output);
                    errdefer self.alloc.free(stored);
                    const key = try self.alloc.dupe(u8, result.tool_call_id);
                    errdefer self.alloc.free(key);
                    try self.stored_results.put(self.alloc, key, stored);
                    break :blk stored;
                };
                // Copied: a superseded turn frees the cache before its pieces are written.
                result.output_handle = try a.dupe(u8, handle);
                result.stored_output_bytes = result.output.len;
                if (result.preview == null) result.preview = try result_store.previewText(a, result.output, result_store.preview_bytes);
            }
        }
        return copy;
    }

    /// Appends `events` (already encoded) as items, then `tail`, starting
    /// the turn first if none is open. One durable batch, except that a
    /// blob needs a published session with an open turn before it.
    /// Writes `events` as the open turn's items, opening it first if it is
    /// not open. When the user piece is among them and someone other than
    /// the user wrote it, an `author` item follows it, once: a stream writes
    /// each piece once, and a superseded turn is written afresh.
    /// `opener` is the capture token of the turn written, as for
    /// `openTurnLocked`.
    fn writePieces(self: *Session, a: Allocator, events: []const Event, encoded: []const []u8, tail: []const sm.Event, author: types.MessageAuthor, opener: u64) !void {
        const reviews = try a.alloc(?[]u8, events.len);
        for (events, reviews) |event, *review| review.* = try encodeFileReview(a, event);
        var batch: std.ArrayList(sm.Event) = .empty;
        if (!self.turn_open) {
            try batch.append(a, .turn_started);
            // Held start captures go with the line that starts the turn (D98).
            try self.appendHeldStarts(a, &batch, opener);
            const needs_blob = for (encoded, reviews) |bytes, review| {
                if (bytes.len > max_inline_piece_bytes) break true;
                if (review) |data| if (data.len > max_inline_piece_bytes) break true;
            } else false;
            if (needs_blob) {
                _ = try self.write(batch.items);
                self.startedTurn(opener);
                batch.clearRetainingCapacity();
            }
        }
        for (events, encoded, reviews) |event, bytes, review| {
            // Before the interruption, which ends the turn when replay reads it.
            if (try encodeCancelledCommand(a, event)) |data| {
                try batch.append(a, .{ .item = try self.itemAs(a, cancelled_command_type, data) });
            }
            try batch.append(a, .{ .item = try self.item(a, std.meta.activeTag(event), bytes) });
            if (review) |data| try batch.append(a, .{ .item = try self.itemAs(a, file_review_type, data) });
            if (event == .user and author != .user) {
                try batch.append(a, .{ .item = try self.itemAs(a, author_type, try encodeAuthor(a, author)) });
            }
            if (try takenReportData(a, event, author)) |data| {
                try batch.append(a, .{ .item = try self.itemAs(a, child_report_type, data) });
            }
        }
        try batch.appendSlice(a, tail);
        if (batch.items.len == 0) return;
        _ = try self.write(batch.items);
        if (!self.turn_open) self.startedTurn(opener);
    }

    /// A turn started on disk for `opener`; it holds that capture token's
    /// starts (`appendHeldStarts`).
    fn startedTurn(self: *Session, opener: u64) void {
        self.last_turn += 1;
        self.turn_open = true;
        self.turn_token = opener;
        if (opener != 0) self.markStartsWritten(opener);
    }

    fn markStartsWritten(self: *Session, opener: u64) void {
        for (self.captures.items) |*capture| {
            if (capture.turn == opener and capture.place == .start) capture.written = true;
        }
    }

    // -- a conversion's import (D56) -----------------------------------------

    /// Writes a turn as v1 framed it: its pieces, then its end. One v1
    /// never ended gets the end v1's next writable open gives it, a failed
    /// interruption.
    fn importFramed(self: *Session, a: Allocator, events: []const Event, open: bool) !void {
        const all = if (open) try std.mem.concat(a, Event, &.{ events, &.{.{ .interrupted = .{ .reason = .failed } }} }) else events;
        // v1 had subagent results only as tool results: every turn is the user's.
        try self.importTurn(a, all, .user);
    }

    /// Writes a whole turn with its bodies as blobs, as a commit does.
    fn importWhole(self: *Session, a: Allocator, turn: types.HistoryTurn) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var copy = turn;
        const stores = switch (copy) {
            .assistant => |entry| storesBodies(entry.execution),
            .interrupted => |entry| storesBodies(entry.execution),
            .compacted_summary => return error.InvalidConversationFrame,
        };
        if (stores) try self.openTurnLocked(0);
        try session_log.externalizeConversationTurnResults(a, &copy, try self.capabilityLocked());
        var events: std.ArrayList(Event) = .empty;
        try session_event.appendHistoryTurnConversationEvents(a, &events, copy);
        try self.importTurn(a, events.items, openingAuthor(copy));
    }

    /// Saves each image of `events`' user items as this session's blob, as
    /// a turn's start saves a prompt's (D89), so a converted session names
    /// its images by blob too. An image the store refuses keeps its bytes
    /// inline. The caller holds the mutex.
    fn saveImportedImages(self: *Session, events: []const Event) !void {
        for (events) |event| switch (event) {
            .user => |user| for (user.images) |image| {
                const bytes = image.inline_data orelse continue;
                const digest = image.snapshot_sha256 orelse continue;
                _ = self.savePromptImageLocked(bytes, digest) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    debug_trace.logf("session", "event=sessions_v2_prompt_image_inline session={s} image={d} reason={s}", .{ self.id(), image.id, @errorName(err) });
                    continue;
                };
            },
            else => {},
        };
    }

    /// `events`, a turn's pieces, ended by the last one.
    fn importTurn(self: *Session, a: Allocator, turn_events: []const Event, author: types.MessageAuthor) !void {
        if (turn_events.len < 2) return error.InvalidConversationFrame;
        const events = try a.dupe(Event, turn_events);
        try self.saveImportedImages(events);
        const encoded = try a.alloc([]u8, events.len);
        for (events, encoded) |event, *bytes| bytes.* = try self.encodeEvent(a, event);
        const end: sm.Event = switch (events[events.len - 1]) {
            .turn_completed => .turn_committed,
            .interrupted => |interruption| .{ .turn_interrupted = switch (interruption.reason) {
                .cancelled => .cancel,
                .failed => .failed,
            } },
            else => return error.InvalidConversationFrame,
        };
        try self.writePieces(a, events, encoded, &.{end}, author, 0);
        self.turn_open = false;
        self.turn_token = 0;
    }

    /// Lets go of an import, published or not. A published one is opened
    /// again as any session is.
    fn dropImport(self: *Session) void {
        self.host.detach();
        self.handle.release();
        self.destroyInner();
    }

    /// How many of `encoded` the open turn already holds. A streamed piece
    /// that differs from the final turn is a bug; the stale turn is closed
    /// as superseded and the whole turn is written afresh, never mixed.
    /// `phase` and `results`, the rebuild's tool result count, only name
    /// the decision in the session trace, which the driver of
    /// `tests/tla/session/TurnStreamTrace.tla` replays.
    fn streamedPrefix(self: *Session, encoded: []const []u8, phase: StreamPhase, results: usize) !usize {
        // A failed turn left open is never the one to continue (D98).
        if (self.turn_open and self.turn_stale) try self.supersedeOpenTurn("failed_turn");
        const streamed = self.streamed.items;
        const held = if (self.turn_open) streamed.len else 0;
        const reparsed: ?usize = if (self.turn_open) reparsedPrefix(self.alloc, streamed, encoded) else 0;
        debug_trace.logf("session", "event=sessions_v2_stream session={s} phase={s} held={d} kept={d} results={d} reparsed={d}", .{
            self.id(), @tagName(phase), held, if (reparsed != null) held else 0, results, reparsed orelse 0,
        });
        if (!self.turn_open) return 0;
        if (reparsed != null) return streamed.len;
        debug_trace.logf("session", "event=sessions_v2_stream_mismatch session={s} streamed={d} final={d} dropped=stale_turn", .{ self.id(), streamed.len, encoded.len });
        try self.supersedeOpenTurn("stream_mismatch");
        return 0;
    }

    /// Closes the open turn as superseded, which readers drop whole; the
    /// next write starts the turn afresh, with its start captures again
    /// (D98).
    fn supersedeOpenTurn(self: *Session, reason: []const u8) !void {
        debug_trace.logf("session", "event=sessions_v2_turn_superseded session={s} reason={s}", .{ self.id(), reason });
        _ = try self.write(&.{
            .{ .item = .{ .type = superseded_type, .data = "{}" } },
            .{ .turn_interrupted = .failed },
        });
        self.turn_open = false;
        self.turn_stale = false;
        self.turn_token = 0;
        self.clearStreamed();
        for (self.captures.items) |*capture| capture.written = false;
    }

    /// One piece as an item; a large one goes to a blob.
    fn item(self: *Session, a: Allocator, kind: PieceKind, bytes: []u8) !sm.Piece {
        return self.itemAs(a, itemType(kind) orelse return error.InvalidConversationFrame, bytes);
    }

    fn itemAs(self: *Session, a: Allocator, item_type: []const u8, bytes: []u8) !sm.Piece {
        if (bytes.len <= max_inline_piece_bytes) return .{ .type = item_type, .data = bytes };
        const hash = try self.handle.putBlob(bytes);
        const hash_copy = try a.dupe(u8, &hash);
        const refs = try a.alloc([]const u8, 1);
        refs[0] = hash_copy;
        return .{
            .type = item_type,
            .data = try a.print("{{\"{s}\":\"{s}\"}}", .{ blob_ref_key, hash_copy }),
            .blobs = refs,
        };
    }

    // -- compaction ----------------------------------------------------------

    /// Records a compaction. The history after it starts with the summary,
    /// then the retained turns, which the log already holds.
    pub fn commitCompaction(
        self: *Session,
        summary: types.CompactedSummaryHistoryTurn,
        active_prefix: bool,
        retained_from: ?types.ContextHistoryCut,
    ) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const cut = retained_from orelse types.ContextHistoryCut{ .turns = self.turn_numbers.items.len };
        const first_kept = turnSlot(self.turn_numbers.items, cut.turns);
        var keep_from: ?u64 = null;
        // Whether `keep_from` is the turn the cut falls in.
        var cut_turn = false;
        for (self.turn_numbers.items[first_kept..], 0..) |number, slot| {
            if (number) |n| {
                keep_from = n;
                cut_turn = slot == 0;
                break;
            }
        }
        // A failed turn left open is not the active turn: its fresh turn is
        // not on disk yet (D98).
        if (keep_from == null and active_prefix and self.turn_open and !self.turn_stale) {
            keep_from = self.last_turn;
            cut_turn = true;
        }
        // A cut inside a turn counts from where spark's view of that turn starts,
        // past what an earlier compaction inside it covered (D87).
        const trim: Trim = if (!cut_turn) .{} else if (self.trim.turn == keep_from) .{
            .turn = keep_from,
            .tool_steps = self.trim.tool_steps + cut.tool_steps,
            .steering = self.trim.steering + cut.steering,
        } else .{ .turn = keep_from, .tool_steps = cut.tool_steps, .steering = cut.steering };
        if (trim.tool_steps != 0 or trim.steering != 0) {
            debug_trace.logf("session", "event=sessions_v2_compaction_cut session={s} turn={?d} tool_steps={d} steering={d}", .{ self.id(), trim.turn, trim.tool_steps, trim.steering });
        }
        const data: CompactedData = .{
            .summary = summary.summary,
            .removed_turn_count = summary.removed_turn_count,
            .compaction_count = summary.compaction_count,
            .keep_from_turn = keep_from,
            .keep_tool_steps = trim.tool_steps,
            .keep_steering = trim.steering,
        };
        _ = try self.write(&.{.{ .compacted = try jsonValue(arena.allocator(), data) }});
        self.trim = if (trim.tool_steps != 0 or trim.steering != 0) trim else .{};
        // spark's history is now the summary, then the retained turns.
        var kept: std.ArrayList(?u64) = .empty;
        errdefer kept.deinit(self.alloc);
        try kept.append(self.alloc, null);
        try kept.appendSlice(self.alloc, self.turn_numbers.items[first_kept..]);
        self.turn_numbers.deinit(self.alloc);
        self.turn_numbers = kept;
    }

    /// Where spark's raw history turn `turn` sits in `numbers`. A compaction cut
    /// counts only raw turns, while `numbers` also holds the summary's slot.
    /// Returns `numbers.len` when the history has no such turn.
    fn turnSlot(numbers: []const ?u64, turn: usize) usize {
        var seen: usize = 0;
        for (numbers, 0..) |number, slot| {
            if (number == null) continue;
            if (seen == turn) return slot;
            seen += 1;
        }
        return numbers.len;
    }

    // -- settings ------------------------------------------------------------

    pub fn setPreferences(self: *Session, preferences: session_codec.DurableSessionPreferences) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        _ = try self.write(&.{.{ .set = .{ .key = .prefs, .value = try encodePreferences(arena.allocator(), preferences, self.instructions) } }});
    }

    // -- children (D22) ------------------------------------------------------

    /// Every child of this session as its log folds them, in first-spawn
    /// order. Free with `freeChildren`.
    pub fn children(self: *Session, alloc: Allocator) ![]Child {
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const state = try self.handle.state(scratch.allocator());
        return childrenOf(alloc, &state);
    }

    /// The children this session had at the end of the turn before
    /// `before_turn`, a `ForkPoint.turn`, each as its newest work stood
    /// then: what `fork` can copy (D97). Free with `freeChildren`.
    pub fn forkChildren(self: *Session, alloc: Allocator, before_turn: u64) ![]Child {
        if (before_turn == 0) return error.InvalidForkPoint;
        var state = try self.store.manager.stateAt(self.id(), .{ .turn = before_turn - 1 });
        defer state.deinit(self.store.manager.gpa);
        return childrenOf(alloc, &state);
    }

    fn childrenOf(alloc: Allocator, state: *const sm.State) ![]Child {
        const out = try alloc.alloc(Child, state.children.items.len);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |child| freeChild(alloc, child);
            alloc.free(out);
        }
        for (state.children.items) |child| {
            const id_copy = try alloc.dupe(u8, child.id);
            errdefer alloc.free(id_copy);
            const work_copy = try alloc.dupe(u8, child.work_id);
            errdefer alloc.free(work_copy);
            const spawn_copy = if (child.spawn_data) |data| try alloc.dupe(u8, data) else null;
            errdefer if (spawn_copy) |data| alloc.free(data);
            out[built] = .{
                .id = id_copy,
                .work_id = work_copy,
                .open = child.open,
                .outcome = child.outcome,
                .spawn_data = spawn_copy,
                .finish_data = if (child.finish_data) |data| try alloc.dupe(u8, data) else null,
                .seq = child.seq,
            };
            built += 1;
        }
        return out;
    }

    /// Appends child lines as one durable batch. The manager refuses a spawn
    /// while that child has unfinished work, and a finish for other work.
    pub fn appendChildLines(self: *Session, lines: []const ChildLine) !void {
        if (lines.len == 0) return;
        const events = try self.alloc.alloc(sm.Event, lines.len);
        defer self.alloc.free(events);
        for (lines, events) |line, *event| event.* = switch (line) {
            .spawned => |spawned| .{ .child_spawned = .{ .child = spawned.child, .work_id = spawned.work_id, .data = spawned.data } },
            .finished => |finished| .{ .child_finished = .{ .child = finished.child, .work_id = finished.work_id, .outcome = finished.outcome, .data = finished.data } },
        };
        _ = try self.write(events);
    }

    // -- an ACP client's settings (D46) ---------------------------------------

    /// The system prompt the ACP client gave this session, or null. Caller
    /// owns it.
    pub fn clientPrompt(self: *Session, alloc: Allocator) !?[]u8 {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const raw = (try self.handle.state(sa)).client_prompt orelse return null;
        return try alloc.dupe(u8, try json_decode.parseFromSliceLeaky([]const u8, sa, raw, .{}));
    }

    /// Keeps the ACP client's system prompt with the session; the same
    /// prompt again writes nothing.
    pub fn setClientPrompt(self: *Session, text: []const u8) !void {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        try self.putSetting(scratch.allocator(), .client_prompt, try jsonString(scratch.allocator(), text));
    }

    /// The MCP tool identities this ACP session recorded for replay, as
    /// their JSON object, or null. Caller owns it.
    pub fn toolIdentities(self: *Session, alloc: Allocator) !?[]u8 {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const raw = (try self.handle.state(scratch.allocator())).tool_identities orelse return null;
        return try alloc.dupe(u8, raw);
    }

    /// Keeps the session's tool identity record, a JSON object; the same
    /// record again writes nothing.
    pub fn setToolIdentities(self: *Session, record_json: []const u8) !void {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        try self.putSetting(scratch.allocator(), .tool_identities, record_json);
    }

    /// Writes `key` only when its value changed, in `sa`.
    fn putSetting(self: *Session, sa: Allocator, key: sm.SetKey, value: []const u8) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const state = try self.handle.state(sa);
        const current = switch (key) {
            .client_prompt => state.client_prompt,
            .tool_identities => state.tool_identities,
            else => unreachable,
        };
        if (current) |stored| if (std.mem.eql(u8, stored, value)) return;
        _ = try self.write(&.{.{ .set = .{ .key = key, .value = value } }});
    }

    /// Adds one model reply's provider usage to the session's totals and
    /// writes them as `set usage`, so a run that is killed or times out
    /// keeps the usage of every reply it received (D92). A reply with no
    /// counts writes nothing.
    pub fn recordUsage(self: *Session, reply: types.Usage) !void {
        if (std.meta.eql(reply, types.Usage{})) return;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var total = self.usage orelse try self.savedUsage(sa);
        total.add(reply);
        const value = try std.json.Stringify.valueAlloc(sa, total, .{});
        _ = try self.write(&.{.{ .set = .{ .key = .usage, .value = value } }});
        self.usage = total;
    }

    /// The totals the log's newest `set usage` holds. A value written
    /// before D92, or one spark cannot read, counts from zero.
    fn savedUsage(self: *Session, sa: Allocator) !types.Usage {
        const raw = (try self.handle.state(sa)).usage orelse return .{};
        return json_decode.parseFromSliceLeaky(types.Usage, sa, raw, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                debug_trace.logf("session", "event=sessions_v2_usage_reset session={s} reason={s} dropped=saved_usage", .{ self.id(), @errorName(err) });
                return .{};
            },
        };
    }

    /// A title the user chose. It differs from the derived one, so a
    /// generated title never replaces it.
    pub fn rename(self: *Session, title: []const u8) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const value = try jsonString(self.alloc, title);
        defer self.alloc.free(value);
        _ = try self.write(&.{.{ .set = .{ .key = .title, .value = value } }});
        self.titled = true;
    }

    /// v1's rule: a generated title never replaces one the user chose, only
    /// none or the one derived from the first message.
    pub fn installGeneratedTitle(self: *Session, history: []const types.HistoryTurn, title: []const u8) !bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var state = try self.handle.state(a);
        defer state.deinit(a);
        if (state.title) |raw| {
            const current = try json_decode.parseFromSliceLeaky([]const u8, a, raw, .{});
            var display = try session_display_metadata.deriveFromHistory(a, history);
            defer display.deinit(a);
            if (!display.present or !std.mem.eql(u8, current, display.title)) {
                debug_trace.logf("session", "event=title_generation_apply result=dropped reason=user_title_present", .{});
                return false;
            }
        }
        _ = try self.write(&.{.{ .set = .{ .key = .title, .value = try jsonString(a, title) } }});
        self.titled = true;
        return true;
    }

    // -- resume --------------------------------------------------------------

    /// Rebuilds spark's history and settings from the open log (`restoreFrom`),
    /// and keeps what later appends compare against: the last turn, the turn
    /// behind each history entry, and the stored usage and language.
    pub fn restore(self: *Session, alloc: Allocator) !Restored {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const state = try self.handle.state(sa);
        self.last_turn = state.last_turn;
        self.turn_numbers.clearRetainingCapacity();
        var restored = try restoreFrom(self.source(), alloc, sa, state, .{ .alloc = self.alloc, .list = &self.turn_numbers, .trim = &self.trim });
        errdefer restored.deinit(alloc);
        if (self.first_title) |value| self.alloc.free(value);
        self.first_title = null;
        if (self.root and state.title == null) {
            if (try deriveTitle(sa, restored.history)) |title| self.first_title = try self.alloc.dupe(u8, title);
        }
        if (state.language != null) {
            const owned = try self.alloc.dupe(u8, restored.language.view());
            if (self.language) |old| self.alloc.free(old);
            self.language = owned;
        }
        return restored;
    }

    /// Hands `visitor.append` every turn in the log, oldest first, as v1's
    /// conversation reader does: a compaction hides no turn from the
    /// transcript. Each turn is freed after its call, and pages are freed as
    /// they are read, so memory stays bounded by one page and one turn.
    /// Leaves the state resume keeps untouched. It reads only through the
    /// manager's thread-safe handle and changes no adapter state, so it
    /// takes no lock: a visitor may call back into this session, as the app
    /// does to read a command replay's side file while it draws a turn.
    pub fn visitHistory(self: *Session, alloc: Allocator, visitor: anytype) !void {
        var sink: VisitorSink(@TypeOf(visitor), .skip) = .{ .alloc = alloc, .visitor = visitor };
        try replay(self.source(), alloc, alloc, .start, null, ReplaySink.init(&sink));
    }

    /// What a `visitHistory` reader does at a compaction summary. The
    /// transcript shows turns only, as v1's does, so a summary is never handed
    /// to the visitor.
    const AtSummary = enum {
        /// Replay on past it.
        skip,
        /// End the replay with `error.CycleEnd`: one cycle has been read.
        end_cycle,
    };

    /// The replay sink behind the `visitHistory` readers: hands each turn to
    /// the visitor, frees it, and counts it.
    fn VisitorSink(comptime Visitor: type, comptime at_summary: AtSummary) type {
        return struct {
            alloc: Allocator,
            visitor: Visitor,
            turns: usize = 0,

            fn turn(sink: *@This(), value: types.HistoryTurn, _: ?u64) !void {
                defer types.freeHistoryTurn(sink.alloc, value);
                sink.turns += 1;
                try sink.visitor.append(value);
            }

            fn summary(_: *@This(), _: []const u8) !void {
                switch (at_summary) {
                    .skip => {},
                    .end_cycle => return error.CycleEnd,
                }
            }
        };
    }

    /// `visitHistory` from the newest compaction on: the turns the transcript
    /// window holds after a resume (`transcript_window_shell.zig`), which are
    /// the blocks that finished after that compaction. Ctrl+O reads the older
    /// cycles from the log. Without a compaction it visits every turn. When no
    /// turn finished after the newest compaction, it visits the cycle before
    /// it instead and returns true: the window holds that cycle until the next
    /// turn ends, as it does live.
    pub fn visitHistorySinceCompaction(self: *Session, alloc: Allocator, visitor: anytype) !bool {
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const state = try self.handle.state(scratch.allocator());
        var sink: VisitorSink(@TypeOf(visitor), .skip) = .{ .alloc = alloc, .visitor = visitor };
        const offset = state.compaction_offset orelse {
            try replay(self.source(), alloc, alloc, .start, null, ReplaySink.init(&sink));
            return false;
        };
        const compaction: sm.Cursor = .{ .offset = offset, .seq = state.last_compaction_seq orelse return error.InvalidSessionFormat };
        try replay(self.source(), alloc, alloc, .{ .at = try self.source().cycleStart(scratch.allocator(), compaction) }, offset, ReplaySink.init(&sink));
        if (sink.turns > 0) return false;
        // The newest cycle has no turn yet: the cycle before it, read across
        // the newest compaction line, whose summary this sink ignores.
        const previous = (try self.previousCompactionCursor(alloc, compaction)).cursor;
        const from: sm.From = if (previous) |cursor| .{ .at = try self.source().cycleStart(scratch.allocator(), cursor) } else .start;
        try replay(self.source(), alloc, alloc, from, if (previous) |cursor| cursor.offset else null, ReplaySink.init(&sink));
        return sink.turns > 0;
    }

    /// What `previousCompactionCursor` found before a compaction line.
    pub const PreviousCompaction = struct {
        /// The compaction line, or null when the log starts first.
        cursor: ?sm.Cursor,
        /// The backward read stopped at a damaged line first: `cursor` is
        /// null, and the cycles from the damage back cannot be found.
        damaged: bool = false,
    };

    /// Where the cycle that ends at the compaction line `before` starts: the
    /// compaction line before it, read backward a page at a time, or none
    /// when the log starts first. With `before` null, the newest compaction
    /// line, from the folded state. Ctrl+O walks older cycles this way, so it
    /// reads only as much of the log as the cycles it shows.
    pub fn previousCompactionCursor(self: *Session, alloc: Allocator, before: ?sm.Cursor) !PreviousCompaction {
        const end = before orelse {
            var scratch = std.heap.ArenaAllocator.init(alloc);
            defer scratch.deinit();
            const state = try self.handle.state(scratch.allocator());
            const offset = state.compaction_offset orelse return .{ .cursor = null };
            return .{ .cursor = .{ .offset = offset, .seq = state.last_compaction_seq orelse return error.InvalidSessionFormat } };
        };
        const src = self.source();
        var from: sm.From = .{ .at = end };
        while (true) {
            var page = try src.readTo(alloc, from, .backward, replay_page_lines);
            defer page.deinit();
            for (page.entries) |entry| {
                if (entry.offset >= end.offset) continue;
                if (entry.kind == .compacted) return .{ .cursor = .{ .offset = entry.offset, .seq = entry.seq } };
            }
            if (page.damaged) {
                debug_trace.logf("session", "event=sessions_v2_cycle_scan_damaged session={s} before={d} dropped=older_cycles", .{ src.id, end.offset });
                return .{ .cursor = null, .damaged = true };
            }
            from = .{ .at = page.next orelse return .{ .cursor = null } };
        }
    }

    /// A reader of this session's log that another thread can keep after
    /// this call returns, such as the one that reads a cycle for Ctrl+O.
    /// Caller owns it; free it with `CycleReader.deinit` on any thread.
    pub fn cycleReader(self: *Session, alloc: Allocator) !CycleReader {
        const files_path = try alloc.dupe(u8, self.files_path);
        errdefer alloc.free(files_path);
        BlobHost.retain(self.host);
        return .{ .alloc = alloc, .store = self.store, .host = self.host, .files_path = files_path };
    }

    /// This open's report lines, the first time it is asked, so the reports
    /// a restart left owed are posted once however often its subagent host
    /// is enabled again. Null after that, and when the session has no
    /// subagents. Strings live in `arena`.
    pub fn pendingReportLines(self: *Session, arena: Allocator) !?[]ReportLine {
        if (self.reports_handed_out) return null;
        self.reports_handed_out = true;
        const folded = try self.children(arena);
        if (folded.len == 0) return null;
        return try self.reportLines(arena);
    }

    /// What this session's log says about its subagents' reports, oldest
    /// first: every work spawned and finished, with spark's data, and every
    /// report it took (`child_report`). Read from the start, past any
    /// compaction, since a report can stay owed across one. Strings live in
    /// `arena`.
    pub fn reportLines(self: *Session, arena: Allocator) ![]ReportLine {
        const src = self.source();
        var lines: std.ArrayList(ReportLine) = .empty;
        var from: sm.From = .start;
        while (true) {
            var page = try src.read(arena, from, replay_page_lines);
            defer page.deinit();
            for (page.entries) |entry| {
                const body = entry.body orelse continue;
                switch (body) {
                    .child_spawned => |line| try lines.append(arena, .{ .spawned = .{
                        .child = try arena.dupe(u8, line.child),
                        .work_id = try arena.dupe(u8, line.work_id),
                        .data = if (line.data) |data| try arena.dupe(u8, data) else null,
                    } }),
                    .child_finished => |line| try lines.append(arena, .{ .finished = .{
                        .child = try arena.dupe(u8, line.child),
                        .work_id = try arena.dupe(u8, line.work_id),
                        .outcome = line.outcome,
                        .data = if (line.data) |data| try arena.dupe(u8, data) else null,
                    } }),
                    .item => |piece| {
                        if (!std.mem.eql(u8, piece.type, child_report_type)) continue;
                        const data = try src.pieceData(arena, piece);
                        const taken = std.json.parseFromSliceLeaky(ChildReportData, arena, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
                            debug_trace.logf("session", "event=sessions_v2_child_report_unreadable session={s}", .{src.id});
                            continue;
                        };
                        try lines.append(arena, .{ .taken = .{ .child = taken.child, .work_id = taken.work_id } });
                    },
                    else => {},
                }
            }
            from = .{ .at = page.next orelse break };
        }
        return lines.toOwnedSlice(arena);
    }

    /// A prompt a fork can start before: the turn it opened and its text.
    pub const ForkPoint = struct {
        turn: u64,
        prompt: []u8,
    };

    /// Every turn's prompt in the log, oldest first, for `fork` (D58).
    /// Caller owns the slice and each prompt; free with `freeForkPoints`.
    pub fn forkPoints(self: *Session, alloc: Allocator) ![]ForkPoint {
        const Sink = struct {
            alloc: Allocator,
            points: std.ArrayList(ForkPoint) = .empty,

            fn turn(sink: *@This(), value: types.HistoryTurn, number: ?u64) !void {
                defer types.freeHistoryTurn(sink.alloc, value);
                const user = switch (value) {
                    .assistant => |entry| entry.user,
                    .interrupted => |entry| entry.user,
                    .compacted_summary => return,
                };
                const prompt = try sink.alloc.dupe(u8, user.text);
                errdefer sink.alloc.free(prompt);
                try sink.points.append(sink.alloc, .{ .turn = number orelse return error.InvalidConversationFrame, .prompt = prompt });
            }

            fn summary(_: *@This(), _: []const u8) !void {}
        };
        var sink: Sink = .{ .alloc = alloc };
        errdefer {
            for (sink.points.items) |point| alloc.free(point.prompt);
            sink.points.deinit(alloc);
        }
        try replay(self.source(), alloc, alloc, .start, null, ReplaySink.init(&sink));
        return sink.points.toOwnedSlice(alloc);
    }

    pub fn freeForkPoints(alloc: Allocator, points: []const ForkPoint) void {
        for (points) |point| alloc.free(point.prompt);
        alloc.free(points);
    }

    pub const Fork = struct {
        /// The fork holds every turn before this one (a `ForkPoint.turn`).
        before_turn: u64,
        workspace: []const u8,
        host: Host,
        /// The title the source shows; the fork gets it marked as a fork.
        title: ?[]const u8 = null,
        /// The children the fork takes a copy of, from `forkChildren` (D97).
        children: []const ChildCopy = &.{},
    };

    pub const ChildCopy = sm.ChildCopy;

    /// A new session holding this one's log up to the end of the turn before
    /// `options.before_turn`, under a new id (D58). The manager copies the
    /// lines and hard-links the blobs; this session is never written. The
    /// caller owns the fork, open for writing.
    pub fn fork(self: *Session, alloc: Allocator, options: Fork) !*Session {
        if (options.before_turn == 0) return error.InvalidForkPoint;
        io_mod.e2eFailIfDurableMutationAttempted();
        const handle = try self.store.manager.openFork(.{
            .source = self.id(),
            .at = .{ .turn = options.before_turn - 1 },
            .workspace = options.workspace,
            .host = options.host,
            .children = options.children,
        });
        errdefer handle.release();
        const copy = try init(alloc, self.store, handle, false);
        errdefer copy.destroyInner();
        try copy.openMoved();
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const state = try handle.state(arena.allocator());
        copy.last_turn = state.last_turn;
        if (options.title) |title| try copy.rename(try forkTitle(arena.allocator(), title));
        traceWiring("Fork", copy.id(), "", copy.store.pid);
        return copy;
    }

    /// The session as v1's `DurableSessionState`, for hosts that restore
    /// through it, and its stored title. Caller owns both.
    pub fn durableState(self: *Session, alloc: Allocator, workspace: []const u8) !Resumed {
        var restored = try self.restore(alloc);
        defer restored.deinit(alloc);
        return resumedOf(alloc, &restored, self.id(), workspace);
    }

    pub const Info = struct {
        /// The stored title, decoded; owned by the caller.
        title: ?[]u8,
        /// The time of the newest line; 0 before the first turn.
        updated_ms: i64,
    };

    /// What a host shows about the open session.
    pub fn info(self: *Session, alloc: Allocator) !Info {
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const st = try self.handle.state(sa);
        const title = if (st.title) |raw| try alloc.dupe(u8, try json_decode.parseFromSliceLeaky([]const u8, sa, raw, .{})) else null;
        return .{ .title = title, .updated_ms = std.math.cast(i64, st.updated_ms) orelse 0 };
    }

    fn source(self: *Session) Source {
        return .{ .store = self.store, .id = self.id(), .handle = self.handle, .host = self.host, .files_path = self.files_path };
    }

    // -- the move off the side folder (D47) -----------------------------------

    /// Makes an older session one manager folder (D47,
    /// `tests/tla/session_manager/MoveSideFiles.tla`) on its first writable
    /// open, then loads the map its old handles resolve through. Every body
    /// in the side folder becomes a blob, the map from each old name to its
    /// blob is one more blob, and one batch records the map, every moved
    /// blob, and the client's settings from the old files.
    /// Then the terminal folder moves to `~/.spark/terminal/{id}` and the side
    /// folder goes. Each step can be repeated, so a crash at any point
    /// redoes the move on the next open.
    fn openMoved(self: *Session) !void {
        try self.moveSideFiles();
        try self.loadMovedMap();
        try self.loadRecords();
    }

    fn moveSideFiles(self: *Session) !void {
        var files_root = (try self.store.openProfileFolder(files_dir_name)) orelse return;
        defer files_root.close();
        const bodies = blk: {
            var side = (try io_mod.openVerifiedPrivateDirIfPresent(&files_root, self.id())) orelse return;
            defer side.close();
            break :blk try self.moveOut(&side);
        };
        files_root.dir.deleteTree(io_mod.getIo(), self.id()) catch |err| {
            // The next open redoes the move; every step is repeatable.
            debug_trace.logf("session", "event=sessions_v2_move_folder_kept session={s} err={s}", .{ self.id(), @errorName(err) });
            return;
        };
        debug_trace.logf("session", "event=sessions_v2_moved session={s} bodies={d}", .{ self.id(), bodies });
    }

    /// Every step of the move but the side folder's removal, in the order
    /// `tests/tla/session_manager/MoveSideFiles.tla` checks; returns how many bodies moved.
    fn moveOut(self: *Session, side: *io_mod.VerifiedDir) !usize {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const lines = try sideFileLines(scratch.allocator(), self.handle, side, &moved_body_folders, &.{}, &.{});
        {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            _ = try self.write(lines.events);
        }

        try self.moveTerminalFolder(side);
        return lines.bodies;
    }

    /// Renames `side/terminal` to `~/.spark/terminal/{id}/terminal`, the layout
    /// the terminal store keeps (D45). A terminal folder already there was
    /// moved by an earlier try.
    fn moveTerminalFolder(self: *Session, side: *io_mod.VerifiedDir) !void {
        const io = io_mod.getIo();
        _ = side.dir.statFile(io, terminal_dir_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        var root = try self.store.makeProfileFolder(terminal_dir_name);
        defer root.close();
        var owner = try io_mod.openOrCreateVerifiedPrivateDir(&root, self.id());
        defer owner.close();
        if (owner.dir.statFile(io, terminal_dir_name, .{ .follow_symlinks = false })) |_| {
            debug_trace.logf("session", "event=sessions_v2_move_terminal_kept session={s} reason=already_moved", .{self.id()});
            return;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try std.Io.Dir.rename(side.dir, terminal_dir_name, owner.dir, terminal_dir_name, io);
        io_mod.syncVerifiedDir(owner.dir) catch |err| debug_trace.logf("session", "event=sessions_v2_move_terminal_unsynced session={s} err={s}", .{ self.id(), @errorName(err) });
    }

    /// Reads the map a moved session's old names resolve through, once.
    fn loadMovedMap(self: *Session) !void {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const raw = (try self.handle.state(sa)).moved_files orelse return;
        const Value = struct { map: []const u8 };
        const value = json_decode.parseFromSliceLeaky(Value, sa, raw, .{ .ignore_unknown_fields = true }) catch return error.InvalidSessionFormat;
        const bytes = self.store.manager.getBlob(sa, self.id(), value.map) catch |err| switch (err) {
            // A lost or damaged map damages the session, as a lost blob
            // does (D39); its old handles read as gone.
            error.NotFound, error.Corrupt, error.InvalidArgument => {
                debug_trace.logf("session", "event=sessions_v2_moved_map_unreadable session={s} err={s}", .{ self.id(), @errorName(err) });
                return;
            },
            else => |e| return e,
        };
        const map = json_decode.parseFromSliceLeaky(std.json.ArrayHashMap([]const u8), sa, bytes, .{}) catch return error.InvalidSessionFormat;
        const host = self.host;
        try host.moved.ensureUnusedCapacity(host.alloc, @intCast(map.map.count()));
        for (map.map.keys(), map.map.values()) |key, hash| {
            if (key.len > movedKeyMax or hash.len != artifact_digest.blob_hex_bytes) return error.InvalidSessionFormat;
            if (host.moved.contains(key)) continue;
            host.moved.putAssumeCapacity(try host.alloc.dupe(u8, key), hash[0..artifact_digest.blob_hex_bytes].*);
        }
    }

    /// Reads the compactor's records map (D50), once, as `loadMovedMap` reads
    /// the move's.
    fn loadRecords(self: *Session) !void {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const raw = (try self.handle.state(sa)).compaction_records orelse return;
        const Value = struct { map: []const u8 };
        const value = json_decode.parseFromSliceLeaky(Value, sa, raw, .{ .ignore_unknown_fields = true }) catch return error.InvalidSessionFormat;
        const bytes = self.store.manager.getBlob(sa, self.id(), value.map) catch |err| switch (err) {
            // A lost or damaged map damages the session, as a lost blob
            // does (D39); its records read as gone.
            error.NotFound, error.Corrupt, error.InvalidArgument => {
                debug_trace.logf("session", "event=sessions_v2_records_map_unreadable session={s} err={s}", .{ self.id(), @errorName(err) });
                return;
            },
            else => |e| return e,
        };
        const map = json_decode.parseFromSliceLeaky(std.json.ArrayHashMap([]const u8), sa, bytes, .{}) catch return error.InvalidSessionFormat;
        const host = self.host;
        host.mutex.lockUncancelable(io_mod.getIo());
        defer host.mutex.unlock(io_mod.getIo());
        try host.records.ensureUnusedCapacity(host.alloc, map.map.count());
        for (map.map.keys(), map.map.values()) |name, hash| {
            session_child_store.SessionChildCapability.validateManagedName(name) catch return error.InvalidSessionFormat;
            if (hash.len != artifact_digest.blob_hex_bytes) return error.InvalidSessionFormat;
            if (host.records.contains(name)) continue;
            host.records.putAssumeCapacity(try host.alloc.dupe(u8, name), hash[0..artifact_digest.blob_hex_bytes].*);
        }
    }
};

/// The side-folder layouts an older session kept its bodies in (D47); the
/// first three are `movedFolder`'s, and `images` holds prompt images.
/// The folders whose files become blobs on a move or a conversion. A
/// converted v1 session's images go inside its prompts instead (D44).
const body_folders = [_][]const u8{ "tool-results", "logs/commands", "artifacts/web-fetch" };
const moved_body_folders = body_folders ++ [_][]const u8{"images"};

const SideFileLines = struct {
    events: []const sm.Event,
    bodies: usize,
};

/// The `set` lines that carry a side folder into `handle` (D46, D47): each
/// file of `folders` but those `left_out` names (`{folder}/{name}`, D62),
/// and each of `stored` (results an older format kept inline), put as a
/// blob and named in the moved map, which is one more blob, and the ACP
/// client's files. In `a`.
/// Whether `stored` holds the result body named `handle`.
fn storedInline(stored: []const v1_conversion.Stored, handle: []const u8) bool {
    const prefix = "tool-results/";
    for (stored) |entry| {
        if (entry.key.len == prefix.len + handle.len and std.mem.startsWith(u8, entry.key, prefix) and std.mem.endsWith(u8, entry.key, handle)) return true;
    }
    return false;
}

fn sideFileLines(a: Allocator, handle: sm.Session, side: *io_mod.VerifiedDir, folders: []const []const u8, stored: []const v1_conversion.Stored, left_out: []const []const u8) !SideFileLines {
    const io = io_mod.getIo();
    var bodies: std.ArrayList(Body) = .empty;
    var dirs: std.ArrayList(std.Io.Dir) = .empty;
    defer for (dirs.items) |dir| dir.close(io);
    for (folders) |folder| try listFolder(a, handle, side, folder, &dirs, &bodies);
    var kept: usize = 0;
    for (bodies.items) |body| {
        for (left_out) |key| {
            if (std.mem.eql(u8, key, body.key)) break;
        } else {
            bodies.items[kept] = body;
            kept += 1;
        }
    }
    bodies.shrinkRetainingCapacity(kept);
    try putBodies(handle, bodies.items);
    var moved: std.array_hash_map.String([]const u8) = .empty;
    try moved.ensureTotalCapacity(a, bodies.items.len + stored.len);
    for (bodies.items) |body| moved.putAssumeCapacity(body.key, try a.dupe(u8, &body.hash));
    for (stored) |body| moved.putAssumeCapacity(body.key, try a.dupe(u8, &(try handle.putBlob(body.bytes))));
    var map_json: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(std.json.ArrayHashMap([]const u8){ .map = moved }, .{}, &map_json.writer);
    const map_hash = try a.dupe(u8, &(try handle.putBlob(map_json.written())));

    var events: std.ArrayList(sm.Event) = .empty;
    const value = try a.print("{{\"map\":\"{s}\"}}", .{map_hash});
    // One line per chunk of blobs keeps each line well under the limit;
    // the last one names the map, so the value is the same on each.
    var refs: std.ArrayList([]const u8) = .empty;
    try refs.appendSlice(a, moved.values());
    try refs.append(a, map_hash);
    var rest = refs.items;
    while (rest.len > 0) {
        const take = @min(rest.len, moved_refs_per_line);
        try events.append(a, .{ .set = .{ .key = .moved_files, .value = value, .blobs = rest[0..take] } });
        rest = rest[take..];
    }
    if (try readSideFile(a, side, moved_client_prompt_file, moved_client_prompt_max)) |text| {
        if (std.unicode.utf8ValidateSlice(text)) {
            try events.append(a, .{ .set = .{ .key = .client_prompt, .value = try jsonString(a, text) } });
        } else debug_trace.logf("session", "event=sessions_v2_move_dropped session={s} file={s} reason=not_utf8", .{ handle.id(), moved_client_prompt_file });
    }
    if (try readSideFile(a, side, moved_tool_identities_file, moved_tool_identities_max)) |record| {
        if (isJsonObject(a, record)) {
            try events.append(a, .{ .set = .{ .key = .tool_identities, .value = record } });
        } else debug_trace.logf("session", "event=sessions_v2_move_dropped session={s} file={s} reason=not_a_json_object", .{ handle.id(), moved_tool_identities_file });
    }
    return .{ .events = events.items, .bodies = moved.count() };
}

/// A side file to put as a blob, named `key` (`{folder}/{name}`) in the
/// moved map.
const Body = struct {
    dir: std.Io.Dir,
    name: []const u8,
    key: []const u8,
    hash: BlobHost.Hash = undefined,
};

/// Lists each regular file of `side/{folder}`, keeping the folder open in
/// `dirs`. Anything else there is not spark's and is left for the side
/// folder's removal, with a trace.
fn listFolder(a: Allocator, handle: sm.Session, side: *io_mod.VerifiedDir, folder: []const u8, dirs: *std.ArrayList(std.Io.Dir), bodies: *std.ArrayList(Body)) !void {
    const io = io_mod.getIo();
    try dirs.ensureUnusedCapacity(a, 1);
    const dir = side.dir.openDir(io, folder, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    dirs.appendAssumeCapacity(dir);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or entry.name.len > 160) {
            debug_trace.logf("session", "event=sessions_v2_move_dropped session={s} folder={s} kind={s}", .{ handle.id(), folder, @tagName(entry.kind) });
            continue;
        }
        try bodies.append(a, .{ .dir = dir, .name = try a.dupe(u8, entry.name), .key = try a.print("{s}/{s}", .{ folder, entry.name }) });
    }
}

const PutBodyError = sm.AppendError || OpenRegularError || std.Io.File.StatError;
/// What `io_mod.openExistingReadOnlyRegularFile` can return.
const OpenRegularError = @typeInfo(@typeInfo(@TypeOf(io_mod.openExistingReadOnlyRegularFile)).@"fn".return_type.?).error_union.error_set;

/// Puts `bodies` as blobs, a few at a time: each waits on its own syncs
/// (D44), which then overlap.
fn putBodies(handle: sm.Session, bodies: []Body) PutBodyError!void {
    const Putter = struct {
        handle: sm.Session,
        bodies: []Body,
        next: std.atomic.Value(usize) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),
        failure: PutBodyError = undefined,
        mutex: std.Io.Mutex = .init,

        fn run(putter: *@This()) void {
            while (!putter.failed.load(.acquire)) {
                const index = putter.next.fetchAdd(1, .monotonic);
                if (index >= putter.bodies.len) return;
                putter.put(&putter.bodies[index]) catch |err| {
                    putter.mutex.lockUncancelable(io_mod.getIo());
                    defer putter.mutex.unlock(io_mod.getIo());
                    if (!putter.failed.load(.monotonic)) putter.failure = err;
                    putter.failed.store(true, .release);
                };
            }
        }

        fn put(putter: *@This(), body: *Body) PutBodyError!void {
            const io = io_mod.getIo();
            var file = try io_mod.openExistingReadOnlyRegularFile(body.dir, body.name, .no_follow);
            defer file.close(io);
            body.hash = try putter.handle.putBlobFile(file, (try file.stat(io)).size);
        }
    };
    var putter: Putter = .{ .handle = handle, .bodies = bodies };
    var threads: [3]?std.Thread = @splat(null);
    for (&threads, 1..) |*thread, count| {
        if (bodies.len <= count) break;
        // Without a thread the others, and this one, do its share.
        thread.* = std.Thread.spawn(.{}, Putter.run, .{&putter}) catch null;
    }
    putter.run();
    for (threads) |thread| if (thread) |value| value.join();
    if (putter.failed.load(.acquire)) return putter.failure;
}
/// The side files an ACP client's settings came from, as `acp`'s
/// `client_instructions.file_name` and `tool_call_identities.file_name`
/// name them under the `client` folder (D46).
pub const moved_client_prompt_file = "client/system-prompt.txt";
pub const moved_tool_identities_file = "client/mcp-tool-identities.json";
const moved_client_prompt_max = 64 * 1024;
const moved_tool_identities_max = 256 * 1024;
/// Blobs listed on one `moved_files` line: about 270 KiB of hashes.
const moved_refs_per_line = 4096;

/// A side file's bytes, or null when it is missing; at most `max_bytes`.
fn readSideFile(a: Allocator, side: *io_mod.VerifiedDir, name: []const u8, max_bytes: usize) !?[]u8 {
    // Never waits on a FIFO or other special file put in its place.
    var file = io_mod.openExistingReadOnlyRegularFile(side.dir, name, .no_follow) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(a, &file, max_bytes + 1) catch |err| switch (err) {
        error.StreamTooLong => {
            debug_trace.logf("session", "event=sessions_v2_move_dropped file={s} reason=too_large", .{name});
            return null;
        },
        else => err,
    };
}

fn isJsonObject(a: Allocator, bytes: []const u8) bool {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return false;
    return parsed == .object;
}

/// Where replay reads a log: an open session's own handle, or the store by
/// id without a lock, as for a finished child's result.
const Source = struct {
    store: *Store,
    id: []const u8,
    handle: ?sm.Session = null,
    /// An open session's blobs, for a moved session's old names (D47).
    host: ?*BlobHost = null,
    /// Where that session kept its side files before the move.
    files_path: ?[]const u8 = null,

    fn read(src: Source, sa: Allocator, from: sm.From, limit: usize) !sm.Page {
        return src.readTo(sa, from, .forward, limit);
    }

    fn readTo(src: Source, sa: Allocator, from: sm.From, direction: sm.Direction, limit: usize) !sm.Page {
        if (src.handle) |handle| return handle.read(sa, from, direction, limit);
        // A `CycleReader` on another thread: through the host, which knows
        // whether the session is still open.
        if (src.host) |host| return host.readLog(sa, from, direction, limit);
        return src.store.manager.read(sa, src.id, from, direction, limit);
    }

    /// Where the display cycle opened by the compaction line `compaction`
    /// starts: the `turn_started` of a turn still open at that line, so a turn
    /// the compaction splits (an overflow compacts after the prompt) shows
    /// whole, or the compaction line itself.
    fn cycleStart(src: Source, sa: Allocator, compaction: sm.Cursor) !sm.Cursor {
        var from: sm.From = .{ .at = compaction };
        while (true) {
            var page = try src.readTo(sa, from, .backward, replay_page_lines);
            defer page.deinit();
            for (page.entries) |entry| {
                if (entry.offset >= compaction.offset) continue;
                const body = entry.body orelse continue;
                switch (body) {
                    .turn_started => return .{ .offset = entry.offset, .seq = entry.seq },
                    .turn_committed, .turn_interrupted => return compaction,
                    else => {},
                }
            }
            from = .{ .at = page.next orelse return compaction };
        }
    }

    /// The cursor of `turn`'s `turn_started`, reading back from `before`.
    fn findTurnStart(src: Source, sa: Allocator, before: sm.Cursor, turn: u64) !sm.Cursor {
        var from: sm.From = .{ .at = before };
        while (true) {
            var page = try src.readTo(sa, from, .backward, replay_page_lines);
            defer page.deinit();
            for (page.entries) |entry| {
                const body = entry.body orelse continue;
                if (body == .turn_started and body.turn_started.turn == turn) return .{ .offset = entry.offset, .seq = entry.seq };
            }
            const next = page.next orelse {
                // A damaged line hides the turn's start: the session is
                // damaged, which a resume refuses (D39).
                if (page.damaged) {
                    debug_trace.logf("session", "event=sessions_v2_kept_turn_unreadable session={s} turn={d} reason=damaged_line", .{ src.id, turn });
                    return error.InvalidSessionFormat;
                }
                return error.InvalidConversationFrame;
            };
            from = .{ .at = next };
        }
    }

    /// `user` with the blob path of each image an older session kept in its
    /// side folder (D47), as a v2 session's own prompt images have it
    /// (D89). Other images are unchanged; one whose blob is gone keeps its
    /// old path, as a lost snapshot does.
    fn withMovedImages(src: Source, pa: Allocator, user: session_event.ConversationUser) !session_event.ConversationUser {
        const host = src.host orelse return user;
        const files_path = src.files_path orelse return user;
        if (host.moved.count() == 0) return user;
        var images: ?[]types.ImageAttachment = null;
        for (user.images, 0..) |image, index| {
            if (image.inline_data != null) continue;
            const path = image.snapshot_path orelse continue;
            if (path.len <= files_path.len + 1 or !std.mem.startsWith(u8, path, files_path) or path[files_path.len] != '/') continue;
            const hash = host.moved.get(path[files_path.len + 1 ..]) orelse continue;
            // The image is its own blob now, which readers load and the
            // model's note names (D89).
            const blob_path = src.store.manager.blobPath(pa, src.id, &hash) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    debug_trace.logf("session", "event=sessions_v2_moved_image_unreadable session={s} err={s}", .{ src.id, @errorName(err) });
                    continue;
                },
            };
            if (images == null) images = try pa.dupe(types.ImageAttachment, user.images);
            images.?[index].blob_path = blob_path;
        }
        const list = images orelse return user;
        return .{ .text = user.text, .images = list, .work_id = user.work_id };
    }

    /// A `user` item, each image saved as its own blob given only that
    /// blob's path, from which readers load its bytes when they need them
    /// (D89). A fork reads the blobs it hard-linked here too.
    fn decodeUser(src: Source, pa: Allocator, data: []const u8) !session_event.ConversationUser {
        const wire = try json_decode.parseFromSliceLeaky(WireUser, pa, data, .{ .allocate = .alloc_if_needed });
        const images = try wire.toImages(pa);
        for (wire.images, images) |image, *out| {
            const hash = image.blob orelse continue;
            out.blob_path = src.store.manager.blobPath(pa, src.id, hash) catch |err| return imageBlobFailed(src, image.id, err);
        }
        return .{ .text = wire.text, .images = images, .work_id = wire.work_id };
    }

    /// An image blob the log names that is gone or misnamed damages the
    /// session, as a piece's blob does (D39). One whose bytes were damaged is
    /// found by `verify`, and by any reader, which checks them against the
    /// image's digest (D89).
    fn imageBlobFailed(src: Source, image_id: usize, err: sm.BlobError) (sm.BlobError || error{InvalidSessionFormat}) {
        return switch (err) {
            error.NotFound, error.Corrupt, error.InvalidArgument => {
                debug_trace.logf("session", "event=sessions_v2_prompt_image_unreadable session={s} image={d} err={s}", .{ src.id, image_id, @errorName(err) });
                return error.InvalidSessionFormat;
            },
            else => |e| e,
        };
    }

    /// A piece's bytes, from its blob when the line holds a reference. The
    /// item may list more blobs, the stores' bodies (D44); the reference is
    /// the one its data names.
    fn pieceData(src: Source, pa: Allocator, piece: sm.Body.Piece) ![]const u8 {
        const hash = blobRefOf(piece.data) orelse return piece.data;
        const listed = for (piece.blobs) |ref| {
            if (std.mem.eql(u8, ref, hash)) break true;
        } else false;
        if (!listed) return piece.data;
        return src.store.manager.getBlob(pa, src.id, hash) catch |err| switch (err) {
            // A blob the log names that is gone or damaged damages the
            // session, as a bad line does (D39).
            error.NotFound, error.Corrupt => {
                debug_trace.logf("session", "event=sessions_v2_blob_unreadable session={s} err={s}", .{ src.id, @errorName(err) });
                return error.InvalidSessionFormat;
            },
            else => |e| return e,
        };
    }
};

/// A session's log as a background thread reads it (`Session.cycleReader`).
/// It holds the session's blob host, so it reads through the open session
/// while it is open and through the process's manager after it closes, as a
/// background reader's capability does (D44). It never touches the
/// `Session`, which may close and free while the reader works.
pub const CycleReader = struct {
    alloc: Allocator,
    store: *Store,
    host: *BlobHost,
    files_path: []u8,

    pub fn deinit(self: *CycleReader) void {
        self.alloc.free(self.files_path);
        BlobHost.release(self.host);
        self.* = undefined;
    }

    fn source(self: *const CycleReader) Source {
        return .{ .store = self.store, .id = self.host.id, .host = self.host, .files_path = self.files_path };
    }

    /// `visitHistory` over one compaction cycle: the turns after the
    /// compaction line at `start`, or from the log's start when null, up to
    /// the next compaction line. A turn the next compaction splits is not
    /// visited; the next cycle shows it whole (`cycleStart`). Returns true
    /// when reading stopped at a damaged line, so turns are missing.
    pub fn visitHistoryCycle(self: *const CycleReader, alloc: Allocator, start: ?sm.Cursor, visitor: anytype) !bool {
        return visitCycle(self.source(), alloc, start, visitor);
    }
};

/// The turns of one compaction cycle from `src`, each handed to
/// `visitor.append` and freed after it returns (`CycleReader.visitHistoryCycle`).
fn visitCycle(src: Source, alloc: Allocator, start: ?sm.Cursor, visitor: anytype) !bool {
    var sink: Session.VisitorSink(@TypeOf(visitor), .end_cycle) = .{ .alloc = alloc, .visitor = visitor };
    const from: sm.From = if (start) |cursor| .{ .at = try src.cycleStart(alloc, cursor) } else .start;
    const skip_offset: ?u64 = if (start) |cursor| cursor.offset else null;
    var damaged = false;
    var replay_sink = ReplaySink.init(&sink);
    replay_sink.damaged = &damaged;
    replay(src, alloc, alloc, from, skip_offset, replay_sink) catch |err| switch (err) {
        error.CycleEnd => {},
        else => |other| return other,
    };
    return damaged;
}

// ---------------------------------------------------------------------------
// Converting v1 sessions (D55 to D61, `tests/tla/session_manager/V1Conversion.tla`)

/// A conversion that runs past this tells the host why the open is slow.
const slow_conversion_ns: i128 = 150 * std.time.ns_per_ms;
const slow_conversion_text = "Converting this session from the previous session format…";

/// What v2 keeps of a converted member's v1 source (`set v1_source`): the
/// fingerprint its removal checks (D60), and what its copy left out (D56,
/// D62), the first `max_records` files by name and how many in all, which
/// its v1 folder keeps and no removal then takes. The fingerprint is empty
/// then, so an older spark, which removes a v1 folder whose fingerprint
/// matches, never takes that folder either.
const V1Source = struct {
    fingerprint: []const u8 = "",
    left_out: []const Record = &.{},
    left_out_total: usize = 0,

    const Record = struct { file: []const u8, cause: LeftOut.Cause, bytes: u64 = 0 };
    /// The most files a copy names, which keeps its line far below the
    /// log's limit; the v1 folder keeps every file.
    const max_records = 32;

    fn leftOutCount(source: V1Source) usize {
        return @max(source.left_out_total, source.left_out.len);
    }

    fn keeps(source: V1Source) bool {
        return source.leftOutCount() > 0;
    }
};

/// A file a conversion leaves out, which the member's v1 folder keeps: a
/// side file larger than one v2 blob (D62), hosted terminal state the copy
/// can't take (D56), or, in salvage, a side file a kept result names that
/// is not what it records (D74).
pub const LeftOut = struct {
    /// The family member that kept it in v1.
    member: []u8,
    /// Its path in that member's v1 folder.
    file: []u8,
    /// Its size, for `too_large`.
    bytes: u64,
    cause: Cause,

    pub const Cause = enum {
        /// A side file larger than one v2 blob (D62).
        too_large,
        /// Hosted terminal state that is not a folder or a regular file,
        /// such as a link or a FIFO (D56).
        not_regular,
        /// Hosted terminal state that does not open (D56).
        unreadable,
        /// Hosted terminal state nested deeper than the copy goes (D56).
        too_deep,
        /// A side file a kept result names that is missing or not what the
        /// result records, which salvage does not copy (D74).
        unavailable,
    };

    fn deinit(entry: LeftOut, alloc: Allocator) void {
        alloc.free(entry.member);
        alloc.free(entry.file);
    }

    /// What a host tells the user about it.
    fn note(entry: LeftOut, alloc: Allocator, root_id: []const u8) ![]u8 {
        const why = try entry.reason(alloc);
        defer alloc.free(why);
        if (std.mem.eql(u8, entry.member, root_id))
            return alloc.print("This session was converted without {s} because {s}. Its earlier folder ~/.spark/sessions/{s} keeps it.", .{ entry.file, why, entry.member });
        return alloc.print("This session was converted without {s} of its subagent {s} because {s}. Its earlier folder ~/.spark/sessions/{s} keeps it.", .{ entry.file, entry.member, why, entry.member });
    }

    /// Why the copy left it out, as a clause. Caller owns it.
    pub fn reason(entry: LeftOut, alloc: Allocator) ![]u8 {
        return switch (entry.cause) {
            .too_large => alloc.print("it is {d} bytes, more than the {d} the new store keeps in one file", .{ entry.bytes, sm.max_blob_bytes }),
            .not_regular => alloc.dupe(u8, "it is not a file or folder"),
            .unreadable => alloc.dupe(u8, "it can't be read"),
            .too_deep => alloc.dupe(u8, "it is nested deeper than the copy goes"),
            .unavailable => alloc.dupe(u8, "it is missing or not what its result records"),
        };
    }
};

/// One family's conversion, in the order `tests/tla/session_manager/V1Conversion.tla` checks:
/// lock every member or answer busy (CBegin); once locked, see whether
/// another process converted it meanwhile, then sweep what a crashed try
/// left (CSweep, D61); stage every member, any unreadable one refusing the
/// whole family with nothing half converted (CStage); publish the children
/// and then the root (CPublishChild, CPublishRoot); remove the v1 folder of
/// each member still the copy converted, under its lock (CDelete).
const Conversion = struct {
    store: *Store,
    alloc: Allocator,
    /// The host the publish stamps as having opened it (`publishImport`).
    host: Host,
    started: i128,
    noticed: bool = false,
    members: usize = 0,
    turns: usize = 0,
    files: usize = 0,
    /// Every file this conversion left out, of every member (D56, D62).
    left_out: std.ArrayList(LeftOut) = .empty,

    const Outcome = enum { converted, held };

    fn deinit(c: *Conversion) void {
        for (c.left_out.items) |entry| entry.deinit(c.alloc);
        c.left_out.deinit(c.alloc);
    }

    /// A member ready to publish, or a child an earlier try already
    /// published, reused as it is (TLA `Orphan`).
    const Staged = struct {
        id: []const u8,
        session: ?*Session,
        /// Whether its v1 state goes once the root is published (TLA
        /// `Unchanged`): copied in this run, or reused while its v1 copy is
        /// the one converted.
        unchanged: bool = true,
        /// Whether its v1 folder keeps something its copy left out (TLA
        /// `keeps`), which then stays.
        keeps: bool = false,
    };

    /// A member the first pass checked (D62): a child an earlier try
    /// published, reused as it is, or one to stage, whose read only a family
    /// of one keeps, so that family is read once.
    const Checked = union(enum) {
        reused: Staged,
        read: ?v1_conversion.Member,
    };

    fn family(c: *Conversion, root_id: []const u8, wait_ms: u64) !Outcome {
        const store = c.store;
        store.problem = .{};
        var v1 = try session_store.Store.initReadOnlyFromHome(c.alloc, store.home, "/");
        defer v1.deinit(c.alloc);
        const kind = v1_conversion.kindOf(&v1, c.alloc, root_id) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                v1_conversion.kindProblem(&v1, c.alloc, root_id, err, &store.problem) catch {};
                c.traceUnreadable(root_id, root_id);
                return error.InvalidSessionFormat;
            },
        };
        if (kind != .root) return error.SessionNotFound;
        var locks = v1_conversion.lockFamily(c.alloc, &v1, root_id, wait_ms, &store.problem) catch |err| {
            switch (err) {
                error.SessionBusy => debug_trace.logf("convert", "action=Busy session={s}", .{root_id}),
                error.InvalidSessionFormat => c.traceUnreadable(root_id, root_id),
                // A member folder others can write, which `problem` names
                // with its fix (D61): unreadable, as a damaged one is.
                error.PrivateStatePermissionsUnsupported => {
                    c.traceUnreadable(root_id, root_id);
                    return error.InvalidSessionFormat;
                },
                // Another process converted it while this one waited, and
                // removed its v1 folder once v2 held it (D61).
                error.SessionNotFound => if (holdsV2(store, c.alloc, root_id)) return traceHeld(root_id),
                else => {},
            }
            return err;
        };
        defer locks.release();
        if (holdsV2(store, c.alloc, root_id)) return traceHeld(root_id);
        try c.sweep(&v1, &locks);

        // Every member to copy is checked before any is staged, keeping
        // nothing (TLA CStage, D62), so one v1 cannot read refuses the family
        // with nothing staged; then each is read again and staged in turn,
        // so memory holds one member at a time.
        const members = locks.members.items;
        var checked: std.ArrayList(Checked) = .empty;
        defer {
            for (checked.items) |*item| if (item.* == .read) if (item.read) |*member| member.deinit();
            checked.deinit(c.alloc);
        }
        try checked.ensureTotalCapacity(c.alloc, members.len);
        for (members, 0..) |*member, index| checked.appendAssumeCapacity(try c.check(&v1, member, root_id, index == 0, members.len == 1));

        var staged: std.ArrayList(Staged) = .empty;
        defer staged.deinit(c.alloc);
        errdefer for (staged.items) |member| c.discard(member);
        defer for (staged.items) |member| if (member.session) |session| session.dropImport();
        try staged.ensureTotalCapacity(c.alloc, members.len);
        // The children first: the root's child lines name them.
        for (members[1..], checked.items[1..]) |*member, *item| {
            const instructions = childInstructionsOf(locks.registry, member.id);
            staged.appendAssumeCapacity(try c.stage(&v1, item, member, .{ .child = .{ .parent = root_id, .instructions = instructions } }));
        }
        const has_log = try c.alloc.alloc(bool, locks.registry.children.len);
        defer c.alloc.free(has_log);
        for (locks.registry.children, has_log) |child, *logged| logged.* = locks.isMember(child.id);
        staged.appendAssumeCapacity(try c.stage(&v1, &checked.items[0], &members[0], .{ .root = .{ .registry = &locks.registry, .has_log = has_log } }));
        c.phase();

        for (staged.items, 0..) |member, index| {
            const session = member.session orelse continue;
            try session.handle.publishImport();
            const root = index == staged.items.len - 1;
            debug_trace.logf("convert", "action={s} session={s} member={s}", .{ if (root) "PublishedRoot" else "PublishedChild", root_id, member.id });
        }
        c.phase();
        // The root's v1 state first, so v1 stops listing the family.
        removeMember(&v1, root_id, staged.items[staged.items.len - 1]);
        for (staged.items[0 .. staged.items.len - 1]) |member| removeMember(&v1, root_id, member);
        c.members = members.len;
        return .converted;
    }

    /// A salvage of a v1 root (D64; `tests/tla/session_manager/V1Conversion.tla`
    /// SBegin, SFinish): under the family's locks, v1's own recovery reads
    /// the start of the root it keeps, which is written under a fresh id as
    /// a root of its own and published. No v1 file is written.
    fn salvage(c: *Conversion, root_id: []const u8) !Recovered {
        const store = c.store;
        store.problem = .{};
        var v1 = try session_store.Store.initReadOnlyFromHome(c.alloc, store.home, "/");
        defer v1.deinit(c.alloc);
        if (try v1_conversion.kindOfRecorded(&v1, c.alloc, root_id, &store.problem) != .root) return error.SessionNotFound;
        var locks = try v1_conversion.lockFamily(c.alloc, &v1, root_id, 0, &store.problem);
        defer locks.release();
        const locked = &locks.members.items[0];
        // A session the converter reads whole needs no salvage, as v1's
        // recover finds once it has brought an older format up to date.
        if (v1_conversion.readMember(c.alloc, &v1, locked, &store.problem, .required)) |whole| {
            var read = whole;
            read.deinit();
            return error.SessionRecoveryNotNeeded;
        } else |err| if (err == error.OutOfMemory) return err;
        store.problem = .{};
        // A conversation that only its saved rules keep from converting is
        // copied whole without them (D72); anything else is salvaged as v1
        // salvaged it.
        var member = v1_conversion.readMember(c.alloc, &v1, locked, &store.problem, .drop_unreadable) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => salvaged: {
                store.problem = .{};
                break :salvaged try v1_conversion.readSalvage(c.alloc, &v1, locked, &store.problem);
            },
        };
        defer member.deinit();
        try c.findLeftOut(root_id, locked);
        try c.checkKeptFiles(root_id, locked, &member);
        var id: [sm.new_id_len]u8 = undefined;
        sm.newId(io_mod.getIo(), &id);
        const handle = store.manager.openImport(.{ .id = &id, .workspace = member.workspace, .host = c.host, .created_ms = member.created_ms }) catch |err|
            return conversionStorageFailed("salvage", err);
        const session = Session.init(c.alloc, store, handle, false) catch |err| {
            handle.release();
            c.discardStaging(&id);
            return err;
        };
        session.root = false;
        defer session.dropImport();
        errdefer c.discardStaging(&id);
        var arena = std.heap.ArenaAllocator.init(c.alloc);
        defer arena.deinit();
        var registry = try child_state.Registry.init(arena.allocator(), &id);
        try c.writeMember(session, &member, locked, .{ .root = .{ .registry = &registry, .has_log = &.{} } }, &.{}, 0);
        try session.handle.publishImport();
        debug_trace.logf("convert", "action=Salvaged session={s} copy={s} turns={d} rules_dropped={}", .{ root_id, &id, member.turns, member.rules_dropped });
        return .{
            .id = try c.alloc.dupe(u8, &id),
            .history_len = member.steps.len,
            .files_complete = c.left_out.items.len == 0,
            .permission_rules_dropped = member.rules_dropped,
        };
    }

    /// Copies `<v1>/terminal` to `~/.spark/terminal/{id}/terminal` (D45), over
    /// what a crashed try left there, whatever its folders' modes, as v1
    /// opened them (it made each private). An entry the copy can't take is
    /// left out, and the member's v1 folder keeps it (D56, D62). A copy, not
    /// a move: a conversion that stops leaves v1 whole.
    fn copyTerminalState(c: *Conversion, root_id: []const u8, locked: *v1_conversion.Locked) !void {
        const io = io_mod.getIo();
        var source = (io_mod.openRealDirIfPresent(&locked.dir, terminal_dir_name) catch |err|
            return c.leaveOut(root_id, locked.id, terminal_dir_name, .unreadable, err)) orelse return;
        defer source.close();
        var root = try c.store.makeProfileFolder(terminal_dir_name);
        defer root.close();
        var owner = try io_mod.openOrCreateVerifiedPrivateDir(&root, locked.id);
        defer owner.close();
        try owner.dir.deleteTree(io, terminal_dir_name);
        var target = try io_mod.openOrCreateVerifiedPrivateDir(&owner, terminal_dir_name);
        defer target.close();
        try c.copyTerminalTree(root_id, locked.id, &source, &target, terminal_dir_name, 0);
    }

    /// Copies the folders and regular files below `source`, at `path` in
    /// the member's v1 folder. An entry that is neither, one that does not
    /// open, or one nested deeper than `max_copy_depth` is left out. A write
    /// that fails fails the copy.
    fn copyTerminalTree(
        c: *Conversion,
        root_id: []const u8,
        member_id: []const u8,
        source: *io_mod.VerifiedDir,
        target: *io_mod.VerifiedDir,
        path: []const u8,
        depth: usize,
    ) (ConversionStorageError || Allocator.Error)!void {
        const io = io_mod.getIo();
        var it = source.dir.iterate();
        while (it.next(io) catch |err| return c.leaveOut(root_id, member_id, path, .unreadable, err)) |entry| {
            var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const sub = std.mem.print(&buffer, "{s}/{s}", .{ path, entry.name }) catch return conversionStorageFailed("terminal", error.NameTooLong);
            switch (entry.kind) {
                .directory => {
                    if (depth + 1 == max_copy_depth) {
                        try c.leaveOut(root_id, member_id, sub, .too_deep, null);
                        continue;
                    }
                    var from = (io_mod.openRealDirIfPresent(source, entry.name) catch |err| {
                        try c.leaveOut(root_id, member_id, sub, .unreadable, err);
                        continue;
                    }) orelse continue;
                    defer from.close();
                    var to = io_mod.openOrCreateVerifiedPrivateDir(target, entry.name) catch |err| return conversionStorageFailed("terminal", err);
                    defer to.close();
                    try c.copyTerminalTree(root_id, member_id, &from, &to, sub, depth + 1);
                },
                .file => {
                    var file = io_mod.openExistingReadOnlyRegularFile(source.dir, entry.name, .no_follow) catch |err| {
                        try c.leaveOut(root_id, member_id, sub, .unreadable, err);
                        continue;
                    };
                    defer file.close(io);
                    copyOpenedFile(&file, target.dir, entry.name) catch |err| return conversionStorageFailed("terminal", err);
                },
                else => try c.leaveOut(root_id, member_id, sub, .not_regular, null),
            }
        }
    }

    /// Records `file`, which it takes, in `member_id`'s v1 folder as left
    /// out of its copy. `file` is freed when that fails.
    fn addLeftOut(c: *Conversion, member_id: []const u8, file: []u8, bytes: u64, cause: LeftOut.Cause) Allocator.Error!void {
        errdefer c.alloc.free(file);
        try c.left_out.ensureUnusedCapacity(c.alloc, 1);
        const member = try c.alloc.dupe(u8, member_id);
        c.left_out.appendAssumeCapacity(.{ .member = member, .file = file, .bytes = bytes, .cause = cause });
    }

    /// `addLeftOut` for hosted terminal state, naming it in the trace.
    fn leaveOut(c: *Conversion, root_id: []const u8, member_id: []const u8, file: []const u8, cause: LeftOut.Cause, err: ?anyerror) Allocator.Error!void {
        try c.addLeftOut(member_id, try c.alloc.dupe(u8, file), 0, cause);
        debug_trace.logf("convert", "action=LeftOut session={s} member={s} file={s} cause={s} err={s}", .{ root_id, member_id, file, @tagName(cause), if (err) |value| @errorName(value) else "none" });
    }

    fn traceHeld(root_id: []const u8) Outcome {
        debug_trace.logf("convert", "action=Held session={s}", .{root_id});
        return .held;
    }

    /// Removes a published member's v1 folder while it is the copy converted
    /// (CDelete), unless it keeps something its copy left out (D56, D62),
    /// which then stays only there.
    fn removeMember(v1: *session_store.Store, root_id: []const u8, member: Staged) void {
        if (!member.unchanged or member.keeps) {
            debug_trace.logf("convert", "action=KeptV1 session={s} member={s} reason={s}", .{ root_id, member.id, if (member.keeps) "left_out" else "changed" });
            return;
        }
        _ = v1_conversion.removeFolder(v1, member.id, "converted");
    }

    /// Empties the trash and drops the unpublished staging of every member
    /// and of each child the root names whose folder is gone (TLA CSweep),
    /// under the family's locks (D61).
    fn sweep(c: *Conversion, v1: *session_store.Store, locks: *const v1_conversion.Family) !void {
        const root_id = locks.members.items[0].id;
        v1_conversion.emptyTrash(c.alloc, v1);
        for (locks.members.items) |member| try c.sweepOne(root_id, member.id);
        for (locks.absent.items) |id| try c.sweepOne(root_id, id);
        debug_trace.logf("convert", "action=Swept session={s} members={d} absent={d}", .{ root_id, locks.members.items.len, locks.absent.items.len });
    }

    fn sweepOne(c: *Conversion, root_id: []const u8, id: []const u8) !void {
        c.store.manager.discardImport(id) catch |err| switch (err) {
            error.InvalidArgument => return c.refuse(root_id, id, "the session id {s} is not one the new store can keep", .{id}),
            else => return conversionStorageFailed("sweep", err),
        };
    }

    const Role = union(enum) {
        root: struct { registry: *const child_state.Registry, has_log: []const bool },
        child: struct { parent: []const u8, instructions: ?[]const u8 },
    };

    /// Checks one locked member, or finds the child an earlier try
    /// published. Keeps its read only when `keep`.
    fn check(c: *Conversion, v1: *session_store.Store, locked: *v1_conversion.Locked, root_id: []const u8, is_root: bool, keep: bool) !Checked {
        if (!is_root) if (try c.reusedOrphan(locked)) |kept| return .{ .reused = kept };
        var member = try c.load(v1, locked, root_id);
        errdefer member.deinit();
        try c.findLeftOut(root_id, locked);
        c.phase();
        if (keep) return .{ .read = member };
        member.deinit();
        return .{ .read = null };
    }

    fn load(c: *Conversion, v1: *session_store.Store, locked: *v1_conversion.Locked, root_id: []const u8) !v1_conversion.Member {
        return v1_conversion.readMember(c.alloc, v1, locked, &c.store.problem, .required) catch |err| {
            if (err == error.InvalidSessionFormat) c.traceUnreadable(root_id, locked.id);
            return err;
        };
    }

    /// Records each side file larger than one v2 blob, which the conversion
    /// leaves out (D62), naming it in the trace. A side folder it cannot
    /// list refuses the family before anything is staged.
    fn findLeftOut(c: *Conversion, root_id: []const u8, locked: *v1_conversion.Locked) !void {
        const io = io_mod.getIo();
        for (body_folders) |folder| {
            var dir = locked.dir.dir.openDir(io, folder, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return c.refuse(root_id, locked.id, "{s} can't be opened ({s})", .{ folder, @errorName(err) }),
            };
            defer dir.close(io);
            var it = dir.iterate();
            while (it.next(io) catch |err| return c.refuse(root_id, locked.id, "{s} can't be listed ({s})", .{ folder, @errorName(err) })) |entry| {
                if (entry.kind != .file) continue;
                const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err|
                    return c.refuse(root_id, locked.id, "{s}/{s} can't be read ({s})", .{ folder, entry.name, @errorName(err) });
                if (stat.size <= sm.max_blob_bytes) continue;
                const file = try c.alloc.print("{s}/{s}", .{ folder, entry.name });
                try c.addLeftOut(locked.id, file, stat.size, .too_large);
                debug_trace.logf("convert", "action=LeftOut session={s} member={s} file={s} bytes={d} limit={d}", .{ root_id, locked.id, file, stat.size, sm.max_blob_bytes });
            }
        }
    }

    /// Leaves out each side file a kept result names that is missing, not
    /// the size its record gives, or not the bytes the digest in its name
    /// gives, which v1's recover would not copy (D74). The copy's result
    /// then says its content is unavailable, and the recovery says so.
    fn checkKeptFiles(c: *Conversion, root_id: []const u8, locked: *v1_conversion.Locked, member: *const v1_conversion.Member) !void {
        for (member.steps) |step| switch (step) {
            .framed => |framed| for (framed.events) |event| switch (event) {
                .tool_result => |result| {
                    try c.checkKeptFile(root_id, locked, "tool-results", result.artifact_ref, ".txt", result.stored_bytes);
                    if (result.command_replay_ref) |ref| try c.checkKeptFile(root_id, locked, "logs/commands", ref, ".bin", result.command_replay_bytes);
                },
                else => {},
            },
            .whole => |whole| {
                const execution = switch (whole.turn) {
                    .assistant => |entry| entry.execution,
                    .interrupted => |entry| entry.execution,
                    .compacted_summary => continue,
                };
                for (execution.tool_steps) |tool_step| for (tool_step.tool_results) |result| {
                    const handle = result.output_handle orelse continue;
                    // An older format's inline result, which the conversion
                    // writes itself.
                    if (storedInline(member.stored, handle)) continue;
                    try c.checkKeptFile(root_id, locked, "tool-results", handle, ".txt", result.stored_output_bytes);
                };
            },
            .compacted => {},
        };
    }

    fn checkKeptFile(c: *Conversion, root_id: []const u8, locked: *v1_conversion.Locked, folder: []const u8, name: []const u8, suffix: []const u8, expected_bytes: ?u64) !void {
        if (name.len == 0) return;
        for (c.left_out.items) |entry| {
            if (std.mem.eql(u8, entry.member, locked.id) and entry.file.len == folder.len + 1 + name.len and
                std.mem.startsWith(u8, entry.file, folder) and std.mem.endsWith(u8, entry.file, name)) return;
        }
        const io = io_mod.getIo();
        const why: []const u8 = why: {
            var dir = locked.dir.dir.openDir(io, folder, .{ .follow_symlinks = false }) catch break :why "missing";
            defer dir.close(io);
            var file = io_mod.openExistingReadOnlyRegularFile(dir, name, .no_follow) catch break :why "missing";
            defer file.close(io);
            const stat = file.stat(io) catch break :why "unreadable";
            if (expected_bytes) |bytes| if (stat.size != bytes) break :why "not the size its result records";
            if (!artifact_digest.hasContentDigest(name, suffix)) return;
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            var buffer: [16 * 1024]u8 = undefined;
            var offset: u64 = 0;
            while (offset < stat.size) {
                const count: usize = @intCast(@min(buffer.len, stat.size - offset));
                const read = file.readPositionalAll(io, buffer[0..count], offset) catch break :why "unreadable";
                if (read != count) break :why "unreadable";
                hash.update(buffer[0..count]);
                offset += count;
            }
            if (artifact_digest.handleMatchesContentDigest(name, suffix, hash.finalResult())) return;
            break :why "not the bytes its name records";
        };
        const file = try c.alloc.print("{s}/{s}", .{ folder, name });
        try c.addLeftOut(locked.id, file, 0, .unavailable);
        debug_trace.logf("convert", "action=LeftOut session={s} member={s} file={s} reason=\"{s}\"", .{ root_id, locked.id, file, why });
    }

    /// Reads a checked member again unless its read was kept, and writes it
    /// as an import, unpublished; its read is freed either way.
    fn stage(c: *Conversion, v1: *session_store.Store, checked: *Checked, locked: *v1_conversion.Locked, role: Role) !Staged {
        const store = c.store;
        const kept = switch (checked.*) {
            .reused => |reused| return reused,
            .read => |*kept| kept,
        };
        if (kept.* == null) kept.* = try c.load(v1, locked, rootOf(role, locked.id));
        const member = &kept.*.?;
        defer {
            member.deinit();
            kept.* = null;
        }
        const handle = store.manager.openImport(.{
            .id = locked.id,
            .workspace = member.workspace,
            .host = c.host,
            .role = if (role == .root) .root else .child,
            .parent = if (role == .child) role.child.parent else null,
            .created_ms = member.created_ms,
        }) catch |err| switch (err) {
            error.Exists => return c.refuse(rootOf(role, locked.id), locked.id, "the session {s} was deleted from the new store", .{locked.id}),
            error.Busy => return error.SessionBusy,
            else => return conversionStorageFailed("import", err),
        };
        const session = Session.init(c.alloc, store, handle, false) catch |err| {
            handle.release();
            c.discardStaging(locked.id);
            return err;
        };
        session.root = false;
        errdefer {
            session.dropImport();
            c.discardStaging(locked.id);
        }
        try c.copyTerminalState(rootOf(role, locked.id), locked);
        var records: std.ArrayList(V1Source.Record) = .empty;
        defer records.deinit(c.alloc);
        var total: usize = 0;
        for (c.left_out.items) |entry| {
            if (!std.mem.eql(u8, entry.member, locked.id)) continue;
            total += 1;
            if (records.items.len < V1Source.max_records) try records.append(c.alloc, .{ .file = entry.file, .cause = entry.cause, .bytes = entry.bytes });
        }
        if (total > records.items.len) debug_trace.logf("convert", "action=LeftOutUnnamed member={s} named={d} total={d}", .{ locked.id, records.items.len, total });
        try c.writeMember(session, member, locked, role, records.items, total);
        return .{ .id = locked.id, .session = session, .keeps = total > 0 };
    }

    /// A child an earlier try published before it stopped (TLA `Orphan`):
    /// reused as it is, unread, since the sweep cannot take it back without
    /// a tombstone (`tests/tla/session_manager/Catalog.tla` NoResurrection) and its v1 copy may
    /// have changed or been damaged since. Its v1 folder goes only while it
    /// is the copy converted (D60).
    fn reusedOrphan(c: *Conversion, locked: *v1_conversion.Locked) !?Staged {
        var peeked = c.store.manager.peek(c.alloc, locked.id) catch |err| switch (err) {
            error.NotFound => return null,
            else => return conversionStorageFailed("orphan", err),
        };
        defer peeked.deinit(c.alloc);
        var scratch = std.heap.ArenaAllocator.init(c.alloc);
        defer scratch.deinit();
        const a = scratch.allocator();
        const source = parseV1Source(a, peeked.state.v1_source);
        const unchanged = if (source) |known| std.mem.eql(u8, known.fingerprint, &(try v1_conversion.fingerprintOf(a, &locked.dir))) else false;
        const named: []const V1Source.Record = if (source) |known| known.left_out else &.{};
        const total = if (source) |known| known.leftOutCount() else 0;
        // What the earlier try left out, told now as this run tells its own.
        for (named) |record| try c.addLeftOut(locked.id, try c.alloc.dupe(u8, record.file), record.bytes, record.cause);
        debug_trace.logf("convert", "action=Reused member={s} v1={s} left_out={d} named={d}", .{ locked.id, if (unchanged) "unchanged" else "kept", total, named.len });
        return .{
            .id = locked.id,
            .session = null,
            .unchanged = unchanged,
            .keeps = total > 0,
        };
    }

    /// Writes `member` into `session`, each batch at its original time
    /// (D59): its turns and compactions, then its settings at the time v1
    /// lists it, among them what its copy left out: `left_out_total` files,
    /// the first of them named in `records`.
    fn writeMember(c: *Conversion, session: *Session, member: *const v1_conversion.Member, locked: *v1_conversion.Locked, role: Role, records: []const V1Source.Record, left_out_total: usize) !void {
        var arena = std.heap.ArenaAllocator.init(c.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var newest = member.created_ms;
        // The v2 turn of each of the member's turns, for `keep_from`.
        var turns: std.ArrayList(u64) = .empty;
        try turns.ensureTotalCapacity(a, member.steps.len);
        // Each turn is encoded in its own scratch, so a long session never
        // holds every turn's encoding at once (D62).
        var step_arena = std.heap.ArenaAllocator.init(c.alloc);
        defer step_arena.deinit();
        for (member.steps) |step| {
            _ = step_arena.reset(.retain_capacity);
            const sa = step_arena.allocator();
            const ts = switch (step) {
                inline else => |value| value.ts_ms,
            };
            newest = @max(newest, ts);
            session.import_ts = newest;
            switch (step) {
                .framed => |turn| try session.importFramed(sa, turn.events, turn.open),
                .whole => |turn| try session.importWhole(sa, turn.turn),
                .compacted => |compacted| {
                    const data: CompactedData = .{
                        .summary = compacted.summary,
                        .removed_turn_count = compacted.removed_turn_count,
                        .compaction_count = compacted.compaction_count,
                        .keep_from_turn = if (compacted.keep_from) |index| turns.items[index] else null,
                        .keep_tool_steps = compacted.keep_tool_steps,
                        .keep_steering = compacted.keep_steering,
                    };
                    _ = try session.write(&.{.{ .compacted = try jsonValue(sa, data) }});
                    continue;
                },
            }
            turns.appendAssumeCapacity(session.last_turn);
        }

        var settings: std.ArrayList(sm.Event) = .empty;
        const instructions = if (role == .child) role.child.instructions else null;
        try settings.append(a, .{ .set = .{ .key = .prefs, .value = try encodePreferences(a, member.preferences, instructions) } });
        try settings.append(a, .{ .set = .{ .key = .language, .value = try jsonString(a, member.language.view()) } });
        if (member.title) |title| try settings.append(a, .{ .set = .{ .key = .title, .value = try jsonString(a, title) } });
        var left_out: std.ArrayList([]const u8) = .empty;
        for (c.left_out.items) |entry| if (std.mem.eql(u8, entry.member, locked.id)) try left_out.append(a, entry.file);
        const side = try sideFileLines(a, session.handle, &locked.dir, &body_folders, member.stored, left_out.items);
        try settings.appendSlice(a, side.events);
        const source: V1Source = .{ .fingerprint = if (left_out_total > 0) "" else &member.fingerprint, .left_out = records, .left_out_total = left_out_total };
        try settings.append(a, .{ .set = .{ .key = .v1_source, .value = try jsonValue(a, source) } });
        if (role == .root) {
            for (try child_state.v1ImportLines(a, role.root.registry.*, role.root.has_log)) |line| try settings.append(a, switch (line) {
                .spawned => |spawned| .{ .child_spawned = .{ .child = spawned.child, .work_id = spawned.work_id, .data = spawned.data } },
                .finished => |finished| .{ .child_finished = .{ .child = finished.child, .work_id = finished.work_id, .outcome = finished.outcome, .data = finished.data } },
            });
        }
        session.import_ts = @max(newest, member.listed_ms);
        _ = try session.write(settings.items);
        c.turns += member.turns;
        c.files += side.bodies;
    }

    /// Tells the host about each file the conversion left out (D56, D62),
    /// as it tells it the open is slow.
    fn tellLeftOut(c: *Conversion, root_id: []const u8) void {
        const notice = c.store.notice orelse return;
        for (c.left_out.items) |entry| {
            const text = entry.note(c.alloc, root_id) catch continue;
            defer c.alloc.free(text);
            notice.emit(notice.context, text);
        }
    }

    /// Tells the host once that the open is slow (D61), at a step boundary.
    fn phase(c: *Conversion) void {
        if (c.noticed or io_mod.nanoTimestamp() - c.started < slow_conversion_ns) return;
        c.noticed = true;
        const notice = c.store.notice orelse return;
        notice.emit(notice.context, slow_conversion_text);
    }

    fn discard(c: *Conversion, member: Staged) void {
        if (member.session != null) c.discardStaging(member.id);
    }

    /// Drops `id`'s staging after a failed try; what stays is swept by the
    /// next one (CSweep).
    fn discardStaging(c: *Conversion, id: []const u8) void {
        c.store.manager.discardImport(id) catch |err| debug_trace.logf("convert", "action=DiscardFailed member={s} err={s}", .{ id, @errorName(err) });
    }

    fn refuse(c: *Conversion, root_id: []const u8, member_id: []const u8, comptime fmt: []const u8, args: anytype) error{InvalidSessionFormat} {
        const refused = c.store.problem.set(fmt, args);
        c.traceUnreadable(root_id, member_id);
        return refused;
    }

    fn traceUnreadable(c: *Conversion, root_id: []const u8, member_id: []const u8) void {
        debug_trace.logf("convert", "action=Unreadable session={s} member={s} reason=\"{s}\"", .{ root_id, member_id, c.store.problem.text() });
    }

    fn rootOf(role: Role, id: []const u8) []const u8 {
        return switch (role) {
            .root => id,
            .child => |child| child.parent,
        };
    }
};

fn childInstructionsOf(registry: child_state.Registry, id: []const u8) ?[]const u8 {
    for (registry.children) |child| if (std.mem.eql(u8, child.id, id)) return switch (child.kind) {
        .one_off => null,
        .persistent => |persistent| if (persistent.instructions.len == 0) null else persistent.instructions,
    };
    return null;
}

/// Whether v2 holds `id`, a damaged copy included: nothing converts over
/// it, nor over one v2 cannot tell about, and the listing shows v2's.
fn holdsV2(store: *Store, alloc: Allocator, id: []const u8) bool {
    var peeked = store.manager.peek(alloc, id) catch |err| switch (err) {
        error.NotFound => return false,
        else => {
            debug_trace.logf("convert", "action=HeldUnknown session={s} err={s}", .{ id, @errorName(err) });
            return true;
        },
    };
    peeked.deinit(alloc);
    return true;
}

fn parseV1Source(a: Allocator, raw: ?[]const u8) ?V1Source {
    const bytes = raw orelse return null;
    const source = json_decode.parseFromSliceLeaky(V1Source, a, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    if (!source.keeps() and source.fingerprint.len != 64) return null;
    return source;
}

/// Removes what a conversion left in v1 for the converted session
/// `root_id` and its children: each member's v1 state, while its v1 copy is
/// what was converted (TLA CClean, D60). A member whose copy left something
/// out (D56, D62), one another process holds, or one that changed keeps
/// it; nothing here fails the open.
fn cleanLeftovers(store: *Store, alloc: Allocator, root_id: []const u8, state: *const sm.State) void {
    if (state.v1_source == null) return;
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const a = scratch.allocator();
    var ids: std.ArrayList([]const u8) = .empty;
    var sources: std.ArrayList(?[]const u8) = .empty;
    if (leftFolder(store, root_id)) {
        ids.append(a, root_id) catch return;
        sources.append(a, state.v1_source) catch return;
    }
    for (state.children.items) |child| {
        if (!leftFolder(store, child.id)) continue;
        const peeked = store.manager.peek(a, child.id) catch |err| {
            debug_trace.logf("convert", "action=CleanRefused session={s} err={s}", .{ child.id, @errorName(err) });
            continue;
        };
        ids.append(a, child.id) catch return;
        sources.append(a, peeked.state.v1_source) catch return;
    }
    if (ids.items.len == 0) return;
    var v1 = session_store.Store.initReadOnlyFromHome(alloc, store.home, "/") catch |err| {
        debug_trace.logf("convert", "action=CleanRefused session={s} err={s}", .{ root_id, @errorName(err) });
        return;
    };
    defer v1.deinit(alloc);
    for (ids.items, sources.items) |id, raw| {
        const source = parseV1Source(a, raw) orelse {
            debug_trace.logf("convert", "action=Kept session={s} reason=no_source", .{id});
            continue;
        };
        if (source.keeps()) {
            debug_trace.logf("convert", "action=Kept session={s} reason=left_out", .{id});
            continue;
        }
        var locked = (v1_conversion.tryLockLeftover(alloc, &v1, id) catch |err| {
            debug_trace.logf("convert", "action=CleanRefused session={s} err={s}", .{ id, @errorName(err) });
            continue;
        }) orelse {
            debug_trace.logf("convert", "action=Kept session={s} reason=busy", .{id});
            continue;
        };
        defer v1_conversion.releaseLocked(alloc, &locked);
        const fingerprint = v1_conversion.fingerprintOf(a, &locked.dir) catch |err| {
            debug_trace.logf("convert", "action=CleanRefused session={s} err={s}", .{ id, @errorName(err) });
            continue;
        };
        if (!std.mem.eql(u8, &fingerprint, source.fingerprint)) {
            debug_trace.logf("convert", "action=Kept session={s} reason=changed", .{id});
            continue;
        }
        if (v1_conversion.removeFolder(&v1, id, "leftover")) debug_trace.logf("convert", "action=Cleaned session={s}", .{id});
    }
}

/// Whether v1 still has a folder for `id`; one that cannot be checked is
/// traced and left for a later open.
fn leftFolder(store: *Store, id: []const u8) bool {
    return v1_conversion.hasFolder(store.home, id) catch |err| {
        debug_trace.logf("convert", "action=CleanRefused session={s} err={s}", .{ id, @errorName(err) });
        return false;
    };
}

/// The newest session of the merged listing in `workspace` (D61). Caller
/// owns it.
/// What a latest lookup that finds nothing says: that there are no saved
/// sessions, or that only ones it can't read are left, as v1 said (D76).
pub fn noLatestError(store: *Store, alloc: Allocator) error{ OutOfMemory, NoSavedSessions, NoReadableSessions } {
    const unreadable = v1_conversion.hasUnreadable(alloc, store.home) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => false,
    };
    return if (unreadable) error.NoReadableSessions else error.NoSavedSessions;
}

fn newestListed(store: *Store, alloc: Allocator, workspace: []const u8) !?[]u8 {
    var page = try listPage(store, alloc, workspace, null, 1);
    defer page.deinit(alloc);
    if (page.summaries.items.len == 0) return null;
    return try alloc.dupe(u8, page.summaries.items[0].id);
}

/// What `spark sessions convert` did (D61).
pub const ConvertReport = struct {
    converted: usize = 0,
    busy: usize = 0,
    unreadable: usize = 0,
    /// One per skipped session, in the order v1 lists its folders.
    skipped: std.ArrayList(Skipped) = .empty,
    /// Each file a converted family was converted without, which its v1
    /// folder keeps (D56, D62).
    left_out: std.ArrayList(LeftOutFile) = .empty,
    /// Each v1 subagent no conversion takes, kept as it is (D88).
    kept_children: []KeptChild = &.{},

    pub const LeftOutFile = struct {
        /// The family's root.
        id: []u8,
        file: LeftOut,
    };

    /// The largest side file a conversion keeps (D62).
    pub const file_limit_bytes: u64 = sm.max_blob_bytes;

    pub const Skipped = struct {
        id: []u8,
        /// `SessionBusy` or `InvalidSessionFormat`.
        code: []const u8,
        /// The file and the reason, for an unreadable one.
        reason: ?[]u8,
    };

    pub fn deinit(report: *ConvertReport, alloc: Allocator) void {
        for (report.skipped.items) |skipped| {
            alloc.free(skipped.id);
            if (skipped.reason) |reason| alloc.free(reason);
        }
        report.skipped.deinit(alloc);
        for (report.left_out.items) |entry| {
            alloc.free(entry.id);
            entry.file.deinit(alloc);
        }
        report.left_out.deinit(alloc);
        freeKeptChildren(alloc, report.kept_children);
        report.* = undefined;
    }

    /// Records `id` as skipped, `code` a static name, and traces it.
    fn skip(report: *ConvertReport, alloc: Allocator, id: []const u8, code: []const u8, reason: ?[]const u8) !void {
        debug_trace.logf("convert", "action=Skipped session={s} code={s} reason=\"{s}\"", .{ id, code, reason orelse "" });
        try report.skipped.ensureUnusedCapacity(alloc, 1);
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const owned_reason = if (reason) |text| try alloc.dupe(u8, text) else null;
        report.skipped.appendAssumeCapacity(.{ .id = owned_id, .code = code, .reason = owned_reason });
        if (std.mem.eql(u8, code, "SessionBusy")) report.busy += 1 else report.unreadable += 1;
    }
};

/// Converts every v1 family v2 does not hold, opening none (TLA
/// `Request("all")`), and cleans what an earlier conversion left of those
/// it does. A busy family is skipped at once, and one that cannot be
/// converted is skipped with its reason; only what would stop every other
/// family too stops the run. Caller owns the report.
pub fn convertAll(store: *Store, alloc: Allocator) !ConvertReport {
    io_mod.e2eFailIfDurableMutationAttempted();
    var report: ConvertReport = .{};
    errdefer report.deinit(alloc);
    const roots = try v1_conversion.rootIds(alloc, store.home);
    defer {
        for (roots) |root| root.deinit(alloc);
        alloc.free(roots);
    }
    var reason: [v1_conversion.Problem.capacity]u8 = undefined;
    for (roots) |root| {
        const id = root.id;
        // A session v2 holds is converted, whatever its leftover v1 folder
        // holds; `cleanLeftovers` keeps one it may not take (D61).
        if (store.manager.peek(alloc, id)) |peeked_value| {
            var peeked = peeked_value;
            defer peeked.deinit(alloc);
            cleanLeftovers(store, alloc, id, &peeked.state);
            continue;
        } else |err| switch (err) {
            error.NotFound, error.InvalidArgument => {},
            else => {
                try report.skip(alloc, id, "InvalidSessionFormat", std.mem.print(&reason, "the new store can't read its copy ({s})", .{@errorName(err)}) catch null);
                continue;
            },
        }
        if (root.unreadable) |why| {
            try report.skip(alloc, id, "InvalidSessionFormat", why);
            continue;
        }
        var conversion: Conversion = .{ .store = store, .alloc = alloc, .host = .ask, .started = io_mod.nanoTimestamp() };
        defer conversion.deinit();
        const outcome = conversion.family(id, 0) catch |err| switch (err) {
            error.OutOfMemory, error.NoSpaceLeft, error.ReadOnlyFileSystem => return err,
            error.SessionNotFound => continue,
            error.SessionBusy => {
                try report.skip(alloc, id, "SessionBusy", null);
                continue;
            },
            error.InvalidSessionFormat => {
                try report.skip(alloc, id, "InvalidSessionFormat", store.problem.text());
                continue;
            },
            else => {
                try report.skip(alloc, id, "InvalidSessionFormat", std.mem.print(&reason, "the conversion failed ({s})", .{@errorName(err)}) catch null);
                continue;
            },
        };
        if (outcome == .converted) {
            report.converted += 1;
            const ms = @as(f64, @floatFromInt(io_mod.nanoTimestamp() - conversion.started)) / std.time.ns_per_ms;
            debug_trace.logf("convert", "action=Converted session={s} members={d} turns={d} files={d} ms={d:.3}", .{ id, conversion.members, conversion.turns, conversion.files, ms });
            try report.left_out.ensureUnusedCapacity(alloc, conversion.left_out.items.len);
            for (conversion.left_out.items, 0..) |file, index| {
                const owned_root = alloc.dupe(u8, id) catch |err| {
                    // Those moved so far are the report's now.
                    const rest = conversion.left_out.items[index..];
                    @memmove(conversion.left_out.items[0..rest.len], rest);
                    conversion.left_out.shrinkRetainingCapacity(rest.len);
                    return err;
                };
                report.left_out.appendAssumeCapacity(.{ .id = owned_root, .file = file });
            }
            conversion.left_out.clearRetainingCapacity();
        }
    }
    // After every family converted, so a child its root left behind is named.
    report.kept_children = try keptChildren(store, alloc);
    return report;
}

/// A session an older spark saved as a subagent that no conversion takes, and
/// why no spark opens it (D88). Its v1 folder is kept as it is.
pub const KeptChild = struct {
    id: []u8,
    reason: []u8,
    /// Whether its converted copy left something out that its folder
    /// keeps (D62).
    keeps: bool = false,
};

pub fn freeKeptChildren(alloc: Allocator, kept: []KeptChild) void {
    for (kept) |child| {
        alloc.free(child.id);
        alloc.free(child.reason);
    }
    alloc.free(kept);
}

/// Each v1 child whose parent is not a v1 root, with why no spark opens it
/// (D88): one v2 already holds, whose folder a cleanup kept (D60), a child
/// of an earlier subagent, which v1 never let a subagent message, or one
/// whose parent is gone or does not list it. Reads only. Caller owns the
/// result; free it with `freeKeptChildren`.
fn keptChildren(store: *Store, alloc: Allocator) ![]KeptChild {
    var complete = true;
    return keptChildrenUntil(store, alloc, null, &complete);
}

/// `keptChildren`, ended early when `stop` says so; `complete` is then false.
fn keptChildrenUntil(store: *Store, alloc: Allocator, stop: ?sm.Stop, complete: *bool) ![]KeptChild {
    const strays = v1_conversion.strayChildren(alloc, store.home, stop, complete) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("convert", "action=ChildrenUnlisted err={s}", .{@errorName(err)});
            return &.{};
        },
    };
    defer {
        for (strays) |stray| stray.deinit(alloc);
        alloc.free(strays);
    }
    var kept: std.ArrayList(KeptChild) = .empty;
    errdefer {
        for (kept.items) |child| {
            alloc.free(child.id);
            alloc.free(child.reason);
        }
        kept.deinit(alloc);
    }
    try kept.ensureTotalCapacity(alloc, strays.len);
    for (strays) |stray| {
        const verdict = try strayReason(store, alloc, stray);
        errdefer alloc.free(verdict.reason);
        debug_trace.logf("convert", "action=KeptChild session={s} reason=\"{s}\"", .{ stray.id, verdict.reason });
        kept.appendAssumeCapacity(.{ .id = try alloc.dupe(u8, stray.id), .reason = verdict.reason, .keeps = verdict.keeps });
    }
    return kept.toOwnedSlice(alloc);
}

const StrayVerdict = struct { reason: []u8, keeps: bool = false };

/// Why no spark opens `stray`, for `keptChildren`, and whether its folder
/// keeps something its converted copy left out. Caller owns the reason.
fn strayReason(store: *Store, alloc: Allocator, stray: v1_conversion.Stray) !StrayVerdict {
    if (store.manager.peek(alloc, stray.id)) |peeked_value| {
        var peeked = peeked_value;
        defer peeked.deinit(alloc);
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const source = parseV1Source(scratch.allocator(), peeked.state.v1_source);
        return .{ .reason = try convertedReason(alloc, source), .keeps = if (source) |known| known.keeps() else false };
    } else |err| switch (err) {
        error.NotFound, error.InvalidArgument => {},
        error.OutOfMemory => return err,
        else => return .{ .reason = try alloc.print("spark can't read its converted copy ({s}), so this folder stays as it is", .{@errorName(err)}) },
    }
    const parent = stray.parent orelse return .{ .reason = try alloc.dupe(u8, "it names no parent session, so no spark opens it") };
    return .{ .reason = try switch (stray.parent_kind) {
        .child => alloc.print("it is a subagent of the earlier subagent {s}, which no spark opens", .{parent}),
        .unreadable => alloc.print("its parent session {s} can't be read, so it stays with it", .{parent}),
        .absent => if (store.manager.peek(alloc, parent)) |peeked_value| blk: {
            var peeked = peeked_value;
            defer peeked.deinit(alloc);
            break :blk switch (peeked.role) {
                .child => alloc.print("it is a subagent of the earlier subagent {s}, which no spark opens", .{parent}),
                .root => alloc.print("its parent {s} does not list it, so no spark opens it", .{parent}),
            };
        } else |_| alloc.print("its parent session {s} is gone, so no spark opens it", .{parent}),
    } };
}

/// Why a converted subagent's v1 folder stays, from its copy's `source`
/// (D62). Caller owns it.
fn convertedReason(alloc: Allocator, source: ?V1Source) ![]u8 {
    const known = source orelse V1Source{};
    const count = known.leftOutCount();
    if (count == 1 and known.left_out.len == 1) return alloc.print("spark converted it already without {s}, so this folder keeps it", .{known.left_out[0].file});
    if (count > 0) return alloc.print("spark converted it already without {d} of its files, so this folder keeps them", .{count});
    return alloc.dupe(u8, "spark converted it already, so anything an older spark added since stays only in this folder");
}

const ConversionStorageError = error{ NoSpaceLeft, AccessDenied, ReadOnlyFileSystem, FileTooBig, SessionStoreUnavailable };

/// A v2 store step of a conversion that failed: its storage cause when it
/// has one (D29), else `SessionStoreUnavailable`.
fn conversionStorageFailed(comptime step: []const u8, err: anyerror) ConversionStorageError {
    debug_trace.logf("convert", "action=StoreFailed step=" ++ step ++ " err={s}", .{@errorName(err)});
    return switch (err) {
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
        error.FileTooBig => error.FileTooBig,
        else => error.SessionStoreUnavailable,
    };
}

fn copyFailed(id: []const u8, err: anyerror) bool {
    debug_trace.logf("session", "event=sessions_v2_files_copy_incomplete session={s} err={s}", .{ id, @errorName(err) });
    return false;
}

/// Side folders are a few levels deep (a kind, then files); deeper trees
/// are not spark's and are left out.
const max_copy_depth = 8;

/// `openSource` opens each folder below `source`, never through a symlink.
fn copyTree(comptime openSource: anytype, source: *io_mod.VerifiedDir, target: *io_mod.VerifiedDir, depth: usize) bool {
    const io = io_mod.getIo();
    var complete = true;
    var it = source.dir.iterate();
    while (it.next(io) catch |err| return copyFailed("tree", err)) |entry| switch (entry.kind) {
        .directory => {
            if (depth + 1 == max_copy_depth) {
                complete = copyFailed(entry.name, error.TooDeep);
                continue;
            }
            var from = (openSource(source, entry.name) catch |err| {
                complete = copyFailed(entry.name, err);
                continue;
            }) orelse continue;
            defer from.close();
            var to = io_mod.openOrCreateVerifiedPrivateDir(target, entry.name) catch |err| {
                complete = copyFailed(entry.name, err);
                continue;
            };
            defer to.close();
            if (!copyTree(openSource, &from, &to, depth + 1)) complete = false;
        },
        .file => copyFile(source.dir, target.dir, entry.name) catch |err| {
            complete = copyFailed(entry.name, err);
        },
        else => complete = copyFailed(entry.name, error.NotAFile),
    };
    return complete;
}

fn copyFile(from: std.Io.Dir, to: std.Io.Dir, name: []const u8) !void {
    var source = try io_mod.openExistingReadOnlyRegularFile(from, name, .no_follow);
    defer source.close(io_mod.getIo());
    try copyOpenedFile(&source, to, name);
}

fn copyOpenedFile(source: *std.Io.File, to: std.Io.Dir, name: []const u8) !void {
    const io = io_mod.getIo();
    var target = try to.createFile(io, name, .{ .exclusive = true, .permissions = .fromMode(0o600), .resolve_beneath = true });
    defer target.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try source.readPositional(io, &.{&buffer}, offset);
        if (n == 0) break;
        try target.writePositionalAll(io, buffer[0..n], offset);
        offset += n;
    }
}

/// Where `restoreFrom` puts the number of the turn behind each history entry,
/// and what the history leaves out of its first kept turn.
const TurnNumbers = struct {
    alloc: Allocator,
    list: *std.ArrayList(?u64),
    trim: *Trim,
};

/// Rebuilds spark's history and settings from `state` and its log: the newest
/// compaction's summary, then every turn after it (or after the turn it
/// kept). A turn a crash or close ended has no `interruption` item and
/// comes back interrupted: `failed` after a crash, `cancelled` after a
/// close. Caller owns the result.
fn restoreFrom(src: Source, alloc: Allocator, sa: Allocator, state: sm.State, numbers: ?TurnNumbers) !Restored {
    var restored = try settingsFrom(alloc, sa, state);
    errdefer restored.deinit(alloc);

    var history: std.ArrayList(types.HistoryTurn) = .empty;
    errdefer {
        for (history.items) |turn| types.freeHistoryTurn(alloc, turn);
        history.deinit(alloc);
    }
    var from: sm.From = .start;
    var skip_offset: ?u64 = null;
    var covered: types.ContextHistoryCut = .{};
    if (state.compaction_offset) |offset| {
        const cursor: sm.Cursor = .{ .offset = offset, .seq = state.last_compaction_seq.? };
        var page = try src.read(sa, .{ .at = cursor }, 1);
        defer page.deinit();
        const data = compactedData(&page) orelse {
            debug_trace.logf("session", "event=sessions_v2_compaction_unreadable session={s} offset={d}", .{ src.id, offset });
            return error.InvalidSessionFormat;
        };
        const compacted = try json_decode.parseFromSliceLeaky(CompactedData, sa, data, .{});
        try history.ensureUnusedCapacity(alloc, 1);
        if (numbers) |n| try n.list.append(n.alloc, null);
        history.appendAssumeCapacity(.{ .compacted_summary = .{
            .summary = try alloc.dupe(u8, compacted.summary),
            .removed_turn_count = compacted.removed_turn_count,
            .compaction_count = compacted.compaction_count,
            .root_user_messages_complete = false,
            .permission_feedback_complete = false,
        } });
        skip_offset = offset;
        from = .{ .at = cursor };
        if (compacted.keep_from_turn) |turn| from = .{ .at = try src.findTurnStart(sa, cursor, turn) };
        covered = .{ .tool_steps = compacted.keep_tool_steps, .steering = compacted.keep_steering };
    }
    var sink: RestoreSink = .{ .alloc = alloc, .history = &history, .numbers = numbers };
    try replay(src, alloc, sa, from, skip_offset, ReplaySink.init(&sink));
    if (numbers) |n| n.trim.* = .{};
    if (covered.tool_steps != 0 or covered.steering != 0) {
        if (try trimFirstKept(alloc, sa, &history, covered, src.id)) {
            if (numbers) |n| n.trim.* = .{ .turn = n.list.items[1], .tool_steps = covered.tool_steps, .steering = covered.steering };
        }
    }
    restored.history = try history.toOwnedSlice(alloc);
    return restored;
}

/// Leaves out of the first kept turn the steps and steering messages a
/// compaction inside it summarized, as spark's history leaves them out when it
/// compacts (D87). A turn that does not have them stays whole, with a trace
/// line, so a resume is never refused for it. Returns whether it trimmed.
fn trimFirstKept(alloc: Allocator, sa: Allocator, history: *std.ArrayList(types.HistoryTurn), covered: types.ContextHistoryCut, id: []const u8) !bool {
    if (history.items.len < 2) return false;
    const kept = history_range.contextHistoryRange(sa, history.items[1..2], covered, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("session", "event=sessions_v2_compaction_cut_kept_whole session={s} tool_steps={d} steering={d} reason={s}", .{ id, covered.tool_steps, covered.steering, @errorName(err) });
            return false;
        },
    };
    const owned = try types.dupeHistoryTurn(alloc, kept[0]);
    types.freeHistoryTurn(alloc, history.items[1]);
    history.items[1] = owned;
    return true;
}

/// spark's settings from `state`, with an empty history. Caller owns the result.
fn settingsFrom(alloc: Allocator, sa: Allocator, state: sm.State) !Restored {
    const language = if (state.language) |raw| try decodeLanguage(sa, raw) else types.ConversationLanguage.default();
    var restored: Restored = .{
        .history = &.{},
        .language = language,
        .created_at_ms = std.math.cast(i64, state.created_ms) orelse 0,
        .updated_at_ms = std.math.cast(i64, state.updated_ms) orelse 0,
    };
    errdefer restored.deinit(alloc);
    if (state.title) |raw| restored.title = try alloc.dupe(u8, try json_decode.parseFromSliceLeaky([]const u8, sa, raw, .{}));
    if (state.prefs) |raw| restored.preferences = try decodePreferences(alloc, raw);
    return restored;
}

/// Every turn in the log, oldest first, with each compaction's summary where
/// its line sits, as v1's archive lists them for `spark session {id}` (D32).
/// Pages are freed as they are read. Caller owns the result.
fn detailHistory(src: Source, alloc: Allocator) ![]types.HistoryTurn {
    var history: std.ArrayList(types.HistoryTurn) = .empty;
    errdefer {
        for (history.items) |turn| types.freeHistoryTurn(alloc, turn);
        history.deinit(alloc);
    }
    var sink: DetailSink = .{ .alloc = alloc, .history = &history };
    try replay(src, alloc, alloc, .start, null, ReplaySink.init(&sink));
    return history.toOwnedSlice(alloc);
}

/// Keeps each turn for resume, with the number of the turn that holds it.
const RestoreSink = struct {
    alloc: Allocator,
    history: *std.ArrayList(types.HistoryTurn),
    numbers: ?TurnNumbers,

    fn turn(sink: *RestoreSink, value: types.HistoryTurn, number: ?u64) !void {
        errdefer types.freeHistoryTurn(sink.alloc, value);
        try sink.history.ensureUnusedCapacity(sink.alloc, 1);
        if (sink.numbers) |n| try n.list.append(n.alloc, number);
        sink.history.appendAssumeCapacity(value);
    }

    /// The newest summary already leads the history (`restoreFrom`).
    fn summary(_: *RestoreSink, _: []const u8) !void {}
};

/// Keeps every turn and each compaction's summary where its line sits,
/// counted as v1's archive counts them: the turns before the summary, and
/// its place among the compactions (D32).
const DetailSink = struct {
    alloc: Allocator,
    history: *std.ArrayList(types.HistoryTurn),
    turns: usize = 0,
    compactions: usize = 0,

    fn turn(sink: *DetailSink, value: types.HistoryTurn, _: ?u64) !void {
        errdefer types.freeHistoryTurn(sink.alloc, value);
        try sink.history.append(sink.alloc, value);
        sink.turns += 1;
    }

    fn summary(sink: *DetailSink, data: []const u8) !void {
        const parsed = try json_decode.parseFromSlice(CompactedData, sink.alloc, data, .{});
        defer parsed.deinit();
        const text = try sink.alloc.dupe(u8, parsed.value.summary);
        errdefer sink.alloc.free(text);
        try sink.history.append(sink.alloc, .{ .compacted_summary = .{
            .summary = text,
            .removed_turn_count = sink.turns,
            .compaction_count = sink.compactions + 1,
            .root_user_messages_complete = false,
            .permission_feedback_complete = false,
        } });
        sink.compactions += 1;
    }
};

/// Moves `restored` into v1's `DurableSessionState` with its stored title;
/// `restored` keeps only what it still owns. Caller owns the result.
fn resumedOf(alloc: Allocator, restored: *Restored, id: []const u8, workspace: []const u8) !Resumed {
    const id_copy = try alloc.dupe(u8, id);
    errdefer alloc.free(id_copy);
    const origin = try alloc.dupe(u8, workspace);
    errdefer alloc.free(origin);
    const workspace_copy = try alloc.dupe(u8, workspace);
    errdefer alloc.free(workspace_copy);
    // Every session starts with its preferences (`create`).
    const preferences = restored.preferences orelse return error.InvalidSessionFormat;
    restored.preferences = null;
    const resumed: Resumed = .{
        .state = .{
            .id = id_copy,
            .origin_workspace_root = origin,
            .workspace_root = workspace_copy,
            .created_at_ms = restored.created_at_ms,
            .updated_at_ms = restored.updated_at_ms,
            .conversation_language = restored.language,
            .preferences = preferences,
            .history = restored.history,
            // v1 reloads its totals as zero as well.
            .total_input_tokens = 0,
            .total_output_tokens = 0,
        },
        .title = restored.title,
    };
    restored.history = &.{};
    restored.title = null;
    return resumed;
}

fn lastStarted(entry: sm.Entry) ?u64 {
    return switch (entry.body.?) {
        .item => |piece| piece.turn,
        else => null,
    };
}

// Borrows its context for the synchronous replay call. Turn callbacks take
// ownership even on failure; summary bytes remain owned by the current page.
const ReplaySink = struct {
    context: *anyopaque,
    turn_fn: *const fn (*anyopaque, types.HistoryTurn, ?u64) anyerror!void,
    summary_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    /// Set when reading stopped at a damaged line, so the turns after it
    /// are missing. Null when the caller does not need to know.
    damaged: ?*bool = null,

    fn init(sink: anytype) ReplaySink {
        const SinkPtr = @TypeOf(sink);
        const Callbacks = struct {
            fn turn(context: *anyopaque, value: types.HistoryTurn, number: ?u64) anyerror!void {
                const typed: SinkPtr = @ptrCast(@alignCast(context));
                return typed.turn(value, number);
            }

            fn summary(context: *anyopaque, data: []const u8) anyerror!void {
                const typed: SinkPtr = @ptrCast(@alignCast(context));
                return typed.summary(data);
            }
        };
        return .{ .context = @ptrCast(sink), .turn_fn = Callbacks.turn, .summary_fn = Callbacks.summary };
    }

    fn turn(sink: ReplaySink, value: types.HistoryTurn, number: ?u64) anyerror!void {
        return sink.turn_fn(sink.context, value, number);
    }

    fn summary(sink: ReplaySink, data: []const u8) anyerror!void {
        return sink.summary_fn(sink.context, data);
    }
};

noinline fn replay(
    src: Source,
    alloc: Allocator,
    sa: Allocator,
    start: sm.From,
    skip_offset: ?u64,
    /// Takes each finished turn, even when it fails: `turn(value, number)`,
    /// and each compaction's stored data where its line sits: `summary(data)`.
    sink: ReplaySink,
) !void {
    var builder = session_log.ConversationTurnBuilder.init(alloc);
    defer builder.deinit();
    var interrupted_item = false;
    var superseded = false;
    var piece_arena = std.heap.ArenaAllocator.init(alloc);
    defer piece_arena.deinit();
    // The open turn's calls saved as running, and the call ids its pieces
    // already answer or hold (D28).
    var turn_arena = std.heap.ArenaAllocator.init(alloc);
    defer turn_arena.deinit();
    var running: std.ArrayList(session_event.ConversationToolCall) = .empty;
    var represented: std.ArrayList([]const u8) = .empty;
    // The text of the message whose calls are running, until a finished
    // step's own assistant piece supersedes it (D51).
    var running_text: ?[]const u8 = null;
    var from = start;
    while (true) {
        var page = try src.read(sa, from, replay_page_lines);
        defer page.deinit();
        for (page.entries) |entry| {
            _ = piece_arena.reset(.retain_capacity);
            const pa = piece_arena.allocator();
            if (skip_offset) |offset| if (entry.offset == offset) continue;
            const body = entry.body orelse continue;
            switch (body) {
                .turn_started => {
                    interrupted_item = false;
                    superseded = false;
                    _ = turn_arena.reset(.retain_capacity);
                    running = .empty;
                    represented = .empty;
                    running_text = null;
                },
                .item => |piece| {
                    if (std.mem.eql(u8, piece.type, superseded_type)) {
                        superseded = true;
                        continue;
                    }
                    // The recovery module's record, which only a launch reads.
                    if (std.mem.eql(u8, piece.type, recovery_type)) continue;
                    // A workspace capture, evidence beside the conversation (D98).
                    if (std.mem.eql(u8, piece.type, workspace_capture_type)) continue;
                    const ta = turn_arena.allocator();
                    if (std.mem.eql(u8, piece.type, running_type)) {
                        // Kept for the whole turn: copies, not views of the page.
                        const call = try decodePiece(ta, .tool_call, try src.pieceData(ta, piece), .alloc_always);
                        try running.append(ta, call.tool_call);
                        continue;
                    }
                    if (std.mem.eql(u8, piece.type, running_assistant_type)) {
                        const value = try decodePiece(ta, .assistant, try src.pieceData(ta, piece), .alloc_always);
                        running_text = value.assistant.text;
                        continue;
                    }
                    if (std.mem.eql(u8, piece.type, file_review_type)) {
                        try attachFileReview(src, pa, &builder, piece);
                        continue;
                    }
                    if (std.mem.eql(u8, piece.type, bridge_call_type)) {
                        try attachBridgeCall(src, pa, &builder, piece);
                        continue;
                    }
                    if (std.mem.eql(u8, piece.type, cancelled_command_type)) {
                        try noteCancelledCommand(src, pa, &builder, piece);
                        continue;
                    }
                    if (std.mem.eql(u8, piece.type, author_type)) {
                        try builder.setUserAuthor(decodeAuthor(pa, try src.pieceData(pa, piece)));
                        continue;
                    }
                    // A mark for `reportLines`, not part of the conversation.
                    if (std.mem.eql(u8, piece.type, child_report_type)) continue;
                    const kind = pieceKind(piece.type) orelse {
                        debug_trace.logf("session", "event=sessions_v2_unknown_item session={s} type={s} dropped=item", .{ src.id, piece.type });
                        continue;
                    };
                    const data = try src.pieceData(pa, piece);
                    // The builder copies what it keeps, as it does for v1's
                    // reader, so strings may point into the page.
                    if (kind == .user) {
                        try builder.begin(try src.withMovedImages(pa, try src.decodeUser(pa, data)));
                        // Its line says when it was sent, for Ctrl+O.
                        builder.user.?.sent_at_ms = std.math.cast(i64, entry.ts_ms) orelse 0;
                        continue;
                    }
                    // A call record only shows in Ctrl+O, so one spark can't
                    // read costs that record, never the session.
                    if (kind == .model_call) {
                        if (decodeModelCall(pa, data)) |record| {
                            try builder.appendModelCall(record);
                        } else {
                            debug_trace.logf("session", "event=sessions_v2_model_call_unreadable session={s} dropped=call_record", .{src.id});
                        }
                        continue;
                    }
                    switch (try decodePiece(pa, kind, data, .alloc_if_needed)) {
                        // Read above, with its images' blobs.
                        .user => unreachable,
                        // Read above, leaving out one that fails its checks.
                        .model_call => unreachable,
                        .assistant => |value| {
                            running_text = null;
                            try builder.appendAssistant(value);
                        },
                        .tool_call => |value| {
                            try builder.appendToolCall(value);
                            try represented.append(ta, try ta.dupe(u8, value.call_id));
                        },
                        .tool_result => |value| {
                            try builder.appendToolResult(value);
                            try represented.append(ta, try ta.dupe(u8, value.call_id));
                        },
                        .steering => |value| try builder.appendSteering(value.text),
                        .context_note => |value| try builder.appendContextNote(value.text, value.sources),
                        .runtime_context => |value| try builder.setRuntimeContext(value.messages),
                        .turn_completed => |value| try sink.turn(try presentStoredResults(src, alloc, try builder.finishAssistant(value)), lastStarted(entry)),
                        .interrupted => |value| {
                            interrupted_item = true;
                            try sink.turn(try presentStoredResults(src, alloc, try builder.finishInterrupted(value)), lastStarted(entry));
                        },
                        .context_checkpoint => return error.InvalidConversationFrame,
                    }
                },
                .turn_interrupted => |ended| {
                    if (superseded) {
                        debug_trace.logf("session", "event=sessions_v2_replay_superseded session={s} turn={d} dropped=stale_turn", .{ src.id, ended.turn });
                        builder.deinit();
                        builder = session_log.ConversationTurnBuilder.init(alloc);
                        superseded = false;
                        continue;
                    }
                    if (interrupted_item or builder.isIdle()) continue;
                    var turn = try builder.finishInterrupted(.{ .reason = switch (ended.reason) {
                        .cancel, .closed => .cancelled,
                        .failed, .crash => .failed,
                    } });
                    turn.interrupted.stopped_by_exit = switch (ended.reason) {
                        .crash, .closed => true,
                        .cancel, .failed => false,
                    };
                    const answered = answerRunning(alloc, &turn.interrupted, running.items, represented.items, running_text) catch |err| {
                        types.freeHistoryTurn(alloc, turn);
                        return err;
                    };
                    if (answered > 0) debug_trace.logf("session", "event=sessions_v2_replay_unfinished_tools session={s} turn={d} calls={d}", .{ src.id, ended.turn, answered });
                    try sink.turn(try presentStoredResults(src, alloc, turn), ended.turn);
                },
                .compacted => |line| try sink.summary(line.data),
                .session_created, .turn_committed, .set, .child_spawned, .child_finished, .snapshot, .closed => {},
            }
        }
        // Only a replay that reads past the last good line loses lines: one
        // that ends at a compaction first never reaches the damage.
        if (page.damaged) {
            debug_trace.logf("session", "event=sessions_v2_replay_damaged session={s} dropped=lines_after_damage", .{src.id});
            if (sink.damaged) |flag| flag.* = true;
        }
        from = .{ .at = page.next orelse break };
    }
    if (!builder.isIdle()) debug_trace.logf("session", "event=sessions_v2_replay_open_turn session={s} dropped=unfinished_pieces", .{src.id});
}

/// `turn` with each stored result shown as v1 showed it: one the model saw
/// cut keeps its preview, wrapped with its handle and stored size so the
/// model knows where the rest is; one it saw whole gets its whole body back
/// from its blob, or a note that the body is unavailable. A converted
/// session's result under its old name is left as saved when no open
/// session can name its blob. Takes `turn`, freeing it on failure.
fn presentStoredResults(src: Source, alloc: Allocator, turn: types.HistoryTurn) !types.HistoryTurn {
    var shown = turn;
    errdefer types.freeHistoryTurn(alloc, shown);
    const execution = switch (shown) {
        .assistant => |*entry| &entry.execution,
        .interrupted => |*entry| &entry.execution,
        .compacted_summary => return shown,
    };
    for (execution.tool_steps) |*step| for (step.tool_results) |*result| {
        const handle = result.output_handle orelse continue;
        if (!result.truncated and result.output.len == result.stored_output_bytes) continue;
        const body = if (result.truncated)
            try result_store.formatStoredResultOutput(alloc, handle, result.preview orelse "", result.stored_output_bytes)
        else
            (storedBody(src, alloc, handle, result.stored_output_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => blk: {
                    debug_trace.logf("session", "event=context_result_unavailable session={s} handle={s} err={s}; marking content unavailable", .{ src.id, handle, @errorName(err) });
                    result.truncated = true;
                    break :blk try alloc.dupe(u8, "Saved tool-result content is unavailable. The complete output could not be restored.");
                },
            }) orelse continue;
        alloc.free(result.output);
        result.output = body;
    };
    return shown;
}

/// A stored result's whole body, from the blob its handle names, or the
/// blob a converted session's map names for its old handle (D47). Null for
/// an old handle when no open session holds that map.
fn storedBody(src: Source, alloc: Allocator, handle: []const u8, len: usize) !?[]u8 {
    const hash: [artifact_digest.blob_hex_bytes]u8 = if (artifact_digest.blobHash(handle)) |named|
        named[0..artifact_digest.blob_hex_bytes].*
    else if (src.host) |host|
        try BlobHost.resolve(host, .tool_results, handle)
    else
        return null;
    const bytes = try src.store.manager.getBlob(alloc, src.id, &hash);
    if (bytes.len != len) {
        alloc.free(bytes);
        return error.StoredSizeMismatch;
    }
    return bytes;
}

/// Which of the two calls of `Session.streamedPrefix` a decision came from.
const StreamPhase = enum { stream, commit };

fn countResults(events: []const Event) usize {
    var count: usize = 0;
    for (events) |event| count += @intFromBool(event == .tool_result);
    return count;
}

/// How many of the open turn's pieces `samePiece` had to parse because the
/// rebuild changed their bytes, or null when one of them no longer stands.
/// A rebuild keeps each tool result's stamp, so this is 0 unless some path
/// lost it (`tests/tla/session/TurnStream.tla` NoReparseOfStamped).
fn reparsedPrefix(alloc: Allocator, streamed: []const []const u8, encoded: []const []const u8) ?usize {
    if (streamed.len > encoded.len) return null;
    var reparsed: usize = 0;
    for (streamed, encoded[0..streamed.len]) |held, bytes| {
        if (std.mem.eql(u8, held, bytes)) continue;
        if (!samePiece(alloc, held, bytes)) return null;
        reparsed += 1;
    }
    return reparsed;
}

/// Whether a streamed piece is the final one. A rebuild keeps each tool
/// result's `created_at_ms`, so the bytes match; a result whose message
/// carries no stamp is stamped again when rebuilt, so that field alone may
/// differ, and the streamed, earlier stamp stands.
fn samePiece(alloc: Allocator, streamed: []const u8, final: []const u8) bool {
    if (std.mem.eql(u8, streamed, final)) return true;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const x = withoutCreatedAt(a, streamed) catch return false;
    const y = withoutCreatedAt(a, final) catch return false;
    return std.mem.eql(u8, x, y);
}

fn withoutCreatedAt(a: Allocator, bytes: []const u8) ![]u8 {
    var value = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    if (value != .object) return error.NotAnObject;
    if (!value.object.swapRemove("created_at_ms")) return error.NoCreatedAt;
    return jsonValue(a, value);
}

/// Gives each call that was saved as running but that `represented` does not
/// name a failed result saying it may have partly run (D28), as one more
/// step of `turn`, so every call keeps its result. That step keeps `text`,
/// the text of the message that issued them (D51). Returns how many.
fn answerRunning(
    alloc: Allocator,
    turn: *types.InterruptedHistoryTurn,
    running: []const session_event.ConversationToolCall,
    represented: []const []const u8,
    text: ?[]const u8,
) !usize {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var calls: std.ArrayList(types.ToolCall) = .empty;
    var results: std.ArrayList(types.PersistedToolResult) = .empty;
    for (running) |call| {
        if (containsId(represented, call.call_id)) continue;
        try calls.append(a, historyToolCall(call));
        try results.append(a, .{
            .tool_call_id = @constCast(call.call_id),
            .tool_name = @constCast(call.tool_name),
            .status = .failure,
            .output = @constCast(unfinished_tool_output),
            .output_bytes = unfinished_tool_output.len,
            .stored_output_bytes = unfinished_tool_output.len,
        });
    }
    if (calls.items.len == 0) return 0;
    const owned_calls = try types.dupeToolCallSlice(alloc, calls.items);
    errdefer types.freeToolCallSlice(alloc, owned_calls);
    const owned_results = try types.dupePersistedToolResults(alloc, results.items);
    errdefer types.freePersistedToolResults(alloc, owned_results);
    const owned_text = if (text) |value| try alloc.dupe(u8, value) else null;
    errdefer if (owned_text) |value| alloc.free(value);
    const old = turn.execution.tool_steps;
    const steps = try alloc.alloc(types.ToolExecutionStep, old.len + 1);
    @memcpy(steps[0..old.len], old);
    steps[old.len] = .{ .assistant = owned_text, .tool_calls = owned_calls, .tool_results = owned_results };
    if (old.len > 0) alloc.free(old);
    turn.execution.tool_steps = steps;
    return calls.items.len;
}

fn containsId(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| if (std.mem.eql(u8, candidate, id)) return true;
    return false;
}

fn conversationToolCall(call: types.ToolCall) session_event.ConversationToolCall {
    return .{
        .call_id = call.id,
        .tool_name = call.name,
        .arguments_json = call.arguments_json,
        .argument_integrity = call.argument_integrity,
        .provisional_id = call.provisional_id,
        .provider_result = call.provider_result,
        .final_identity = call.final_identity,
        .provenance = call.provenance,
    };
}

fn historyToolCall(call: session_event.ConversationToolCall) types.ToolCall {
    return .{
        .id = call.call_id,
        .name = call.tool_name,
        .arguments_json = call.arguments_json,
        .argument_integrity = call.argument_integrity,
        .provisional_id = call.provisional_id,
        .provider_result = call.provider_result,
        .final_identity = call.final_identity,
        .provenance = call.provenance,
    };
}

// ---------------------------------------------------------------------------
// Listing

const list_page_size: usize = 256;

/// Every saved root session, newest first, as v1's picker summaries, leaving
/// out `active_id`. A saved session always has a turn (D2), so each one can
/// be resumed. Stops with `error.Cancelled` once `cancel` is set. Caller
/// owns the list and every summary; safe from any thread.
pub fn listSummaries(
    store: *Store,
    alloc: Allocator,
    active_id: ?[]const u8,
    cancel: *const std.atomic.Value(bool),
) !std.ArrayList(session_store.SessionSummary) {
    var list: std.ArrayList(session_store.SessionSummary) = .empty;
    errdefer {
        for (list.items) |*summary| summary.deinit(alloc);
        list.deinit(alloc);
    }
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    if (cancel.load(.acquire)) return error.Cancelled;
    {
        // One read of the index, not one per page of it (D62).
        var page = try store.manager.list(alloc, .all, null, std.math.maxInt(usize));
        defer page.deinit();
        try list.ensureTotalCapacity(alloc, page.items.len);
        for (page.items) |item| {
            if (item.role != .root) continue;
            if (active_id) |active| if (std.mem.eql(u8, active, item.id)) continue;
            list.appendAssumeCapacity(try summaryOf(alloc, scratch.allocator(), item));
        }
    }
    // And v1's roots not converted yet (D59), which v2 wins on an id.
    if (cancel.load(.acquire)) return error.Cancelled;
    var v1_roots = try v1_conversion.listRoots(alloc, store.home, active_id);
    defer v1_roots.deinit(alloc);
    var held: std.StringHashMapUnmanaged(void) = .empty;
    try held.ensureTotalCapacity(scratch.allocator(), @intCast(list.items.len));
    for (list.items) |summary| held.putAssumeCapacity(summary.id, {});
    try list.ensureUnusedCapacity(alloc, v1_roots.summaries.items.len);
    var kept: usize = 0;
    for (v1_roots.summaries.items) |summary| {
        if (held.contains(summary.id)) {
            v1_roots.summaries.items[kept] = summary;
            kept += 1;
        } else list.appendAssumeCapacity(summary);
    }
    v1_roots.summaries.shrinkRetainingCapacity(kept);
    // Newest first across both, as `listPage` orders them (D61).
    session_summary_codec.sortSummariesNewestFirst(list.items);
    return list;
}

fn summaryOf(alloc: Allocator, scratch: Allocator, item: sm.Summary) !session_store.SessionSummary {
    const id = try alloc.dupe(u8, item.id);
    errdefer alloc.free(id);
    const workspace = try alloc.dupe(u8, item.workspace);
    errdefer alloc.free(workspace);
    const origin = try alloc.dupe(u8, item.workspace);
    errdefer alloc.free(origin);
    const title: ?[]u8 = if (item.title) |raw|
        try alloc.dupe(u8, try json_decode.parseFromSliceLeaky([]const u8, scratch, raw, .{}))
    else
        null;
    errdefer if (title) |value| alloc.free(value);
    return .{
        .id = id,
        .workspace_root = workspace,
        .origin_workspace_root = origin,
        .title = title,
        .display_metadata_present = title != null,
        .created_at_ms = std.math.cast(i64, item.created_ms) orelse 0,
        .updated_at_ms = std.math.cast(i64, item.updated_ms) orelse 0,
        .conversation_language = if (item.language) |raw| try decodeLanguage(scratch, raw) else types.ConversationLanguage.default(),
        .history_len = std.math.cast(usize, @max(item.turns, 1)) orelse std.math.maxInt(usize),
    };
}

/// v1's error names for a failed resume, so every host reports the same
/// error whichever backend is on.
/// Whether a failed write may still have reached the log: after any I/O
/// fault, whatever its cause, durability is unknown (D29).
pub fn writeMayHaveLanded(err: anyerror) bool {
    inline for (comptime @typeInfo(sm.IoFault).error_set.error_names.?) |fault_name| {
        if (err == @field(sm.IoFault, fault_name)) return true;
    }
    return false;
}

const ResumeError = error{ SessionNotFound, NoSavedSessions, NoRememberedSession, SessionBusy, InvalidSessionFormat, UnsupportedSessionFormat, OneOffSessionNotResumable } || sm.OpenError;

fn resumeError(err: sm.OpenError, target: Target) ResumeError {
    return switch (err) {
        error.NotFound => switch (target) {
            .id => error.SessionNotFound,
            .last => error.NoSavedSessions,
            .last_opened => error.NoRememberedSession,
        },
        // A child is resumed only through its parent, and spark says so, as v1
        // did (D71).
        error.ChildSession => error.OneOffSessionNotResumable,
        error.Busy => error.SessionBusy,
        error.Corrupt => error.InvalidSessionFormat,
        error.UnsupportedVersion => error.UnsupportedSessionFormat,
        else => err,
    };
}

/// Item type of a turn closed because its streamed pieces did not match
/// the final turn; resume drops that turn.
const superseded_type = "superseded";
/// A tool call saved before it runs (D28); its data is a `tool_call` piece.
/// The item after a turn's user piece when someone other than the user
/// wrote that message, such as a subagent's report that woke its parent.
/// Older spark drops it as an unknown item and reads the turn as before.
const author_type = "author";

/// The item after a piece that carries a subagent's report into this
/// session's history, `{"child":…,"work_id":…}`: the opening message of a
/// turn the report started, or the steering a boundary took. It marks the
/// report taken (`reportLines`). Older spark drops it as an unknown item.
const child_report_type = "child_report";

const ChildReportData = struct { child: []const u8, work_id: []const u8 };

/// The `child_report` item's data for `event`, or null when the piece
/// carries no subagent report.
fn takenReportData(a: Allocator, event: Event, author: types.MessageAuthor) !?[]u8 {
    const text = switch (event) {
        .user => |user| if (author == .child) user.text else return null,
        .steering => |steering| steering.text,
        else => return null,
    };
    const sender = (try agent_frame.reportSender(a, text)) orelse return null;
    defer sender.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(ChildReportData{ .child = sender.value.child_id, .work_id = sender.value.work_id }, .{}, &out.writer);
    return out.written();
}

/// The `author` item's data: `{"by":"child"}`.
fn encodeAuthor(a: Allocator, author: types.MessageAuthor) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(.{ .by = author }, .{}, &out.writer);
    return out.written();
}

/// Who an `author` item names. Anything other than a readable `user` is
/// read as a subagent's, so no item a reader cannot read ever counts as the
/// user's words.
fn decodeAuthor(a: Allocator, data: []const u8) types.MessageAuthor {
    const Wire = struct { by: []const u8 };
    const wire = std.json.parseFromSliceLeaky(Wire, a, data, .{ .ignore_unknown_fields = true }) catch return .child;
    if (std.mem.eql(u8, wire.by, "user")) return .user;
    if (std.mem.eql(u8, wire.by, "parent")) return .parent;
    return .child;
}

/// Who wrote the message that opened `turn`.
fn openingAuthor(turn: types.HistoryTurn) types.MessageAuthor {
    return switch (turn) {
        .assistant => |entry| entry.user.author,
        .interrupted => |entry| entry.user.author,
        .compacted_summary => .user,
    };
}

const running_type = "tool_running";
/// The text of the message whose calls are running (D51).
const running_assistant_type = "assistant_running";
/// The recovery module's record for the turn's model request in flight,
/// `{"record":"<64 hex digits>"}`, or `{"record":null}` once the request's
/// response is complete. A launch that finds a turn a crash ended reads
/// the newest one (`interruptedRequest`). Older builds drop the piece as an
/// unknown item.
const recovery_type = "recovery";
/// The bytes of a `recovery` piece's record; null for a cleared one or one
/// that does not parse, which the recovery module treats as no record.
fn parseRecoveryRecord(data: []const u8) ?[32]u8 {
    const prefix = "{\"record\":\"";
    if (!std.mem.startsWith(u8, data, prefix)) return null;
    const rest = data[prefix.len..];
    if (rest.len != 64 + 2 or !std.mem.eql(u8, rest[64..], "\"}")) return null;
    var record: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&record, rest[0..64]) catch return null;
    return record;
}

/// One repository's workspace capture at a turn's start or end (D98): spark's
/// own JSON object, which no reader of the conversation reads. Older
/// builds drop the piece as an unknown item.
const workspace_capture_type = "workspace_capture";

fn capturePiece(data: []const u8) sm.Piece {
    return .{ .type = workspace_capture_type, .data = data };
}

/// A payload the log can take as one inline item: a JSON object with no
/// space around it, which the manager refuses, and no line break, which
/// would split its line.
fn checkWorkspaceCapture(alloc: Allocator, payload: []const u8) error{ OutOfMemory, InvalidWorkspaceCapture, WorkspaceCaptureTooLarge }!void {
    if (payload.len > max_workspace_capture_bytes) return error.WorkspaceCaptureTooLarge;
    if (payload.len < 2 or payload[0] != '{' or payload[payload.len - 1] != '}') return error.InvalidWorkspaceCapture;
    if (std.mem.findAny(u8, payload, "\r\n") != null) return error.InvalidWorkspaceCapture;
    if (!try std.json.validate(alloc, payload)) return error.InvalidWorkspaceCapture;
}

/// A call a command made through `spark mcp call`, saved in the open turn as it
/// ends, while its shell call still runs. Its data is a
/// `types.BridgeCallRecord`: the shell call's id, the request id, the tool's
/// name, and how the call ended, never its arguments or its result. Replay
/// gives it to the turn, and a resume shows its row in its shell call's
/// group (D99). Older spark drops it as an unknown item.
const bridge_call_type = "mcp_bridge_call";

/// The `mcp_bridge_call` item data for `record`, owned by `a`.
fn encodeBridgeCall(a: Allocator, record: types.BridgeCallRecord) ![]u8 {
    if (!types.validBridgeCallRecord(record)) return error.InvalidBridgeCall;
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try std.json.Stringify.value(record, .{}, &out.writer);
    return try out.toOwnedSlice();
}

/// A bridge call's record from the log, or null when it can't be parsed or
/// fails its checks, as a newer spark's outcome would. A newer spark's extra
/// fields are ignored. Strings are in `arena`.
fn decodeBridgeCall(arena: Allocator, data: []const u8) ?types.BridgeCallRecord {
    const record = json_decode.parseFromSliceLeaky(types.BridgeCallRecord, arena, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    return if (types.validBridgeCallRecord(record)) record else null;
}

/// Gives the turn the record an `mcp_bridge_call` item holds. One that can't
/// be read is logged and left out: it only draws a row, so it never fails
/// the session.
fn attachBridgeCall(src: Source, a: Allocator, builder: *session_log.ConversationTurnBuilder, piece: sm.Body.Piece) !void {
    const data = src.pieceData(a, piece) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("session", "event=sessions_v2_bridge_call_unreadable session={s} err={s} dropped=bridge_call_row", .{ src.id, @errorName(err) });
            return;
        },
    };
    const record = decodeBridgeCall(a, data) orelse {
        debug_trace.logf("session", "event=sessions_v2_bridge_call_invalid session={s} dropped=bridge_call_row", .{src.id});
        return;
    };
    try builder.appendBridgeCall(record);
}

/// The item right before an `interruption` piece when the turn cancelled a
/// command that saved no output, `{"call_id":…}`: the piece names neither a
/// command replay nor an artifact, so only this says the command ran, and a
/// resume shows its row (D100). Older spark versions reject an unknown field in
/// the piece but skip an unknown item, so they read the turn as before.
const cancelled_command_type = "cancelled_command";

const CancelledCommandData = struct { call_id: []const u8 };

/// The `cancelled_command` item data for `event`, or null when it needs
/// none. The data is owned by `a`.
fn encodeCancelledCommand(a: Allocator, event: Event) !?[]u8 {
    const interruption = switch (event) {
        .interrupted => |value| value,
        else => return null,
    };
    const call_id = interruption.cancelled_command_call_id orelse return null;
    if (call_id.len == 0 or call_id.len > session_event.max_conversation_identity_bytes) return error.InvalidConversationFrame;
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try std.json.Stringify.value(CancelledCommandData{ .call_id = call_id }, .{}, &out.writer);
    return try out.toOwnedSlice();
}

/// Gives the turn the cancelled command a `cancelled_command` item names.
/// One that can't be read is logged and left out, and the turn reads as it
/// did before the item existed.
fn noteCancelledCommand(src: Source, a: Allocator, builder: *session_log.ConversationTurnBuilder, piece: sm.Body.Piece) !void {
    const data = src.pieceData(a, piece) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("session", "event=sessions_v2_cancelled_command_unreadable session={s} err={s} dropped=cancelled_command_row", .{ src.id, @errorName(err) });
            return;
        },
    };
    const call_id = decodeCancelledCommand(a, data) orelse {
        debug_trace.logf("session", "event=sessions_v2_cancelled_command_invalid session={s} dropped=cancelled_command_row", .{src.id});
        return;
    };
    try builder.noteCancelledCommand(call_id);
}

/// The call id a `cancelled_command` item's data names, or null when the
/// data isn't one. Fields a newer spark adds are ignored.
fn decodeCancelledCommand(a: Allocator, data: []const u8) ?[]const u8 {
    const value = json_decode.parseFromSliceLeaky(CancelledCommandData, a, data, .{ .ignore_unknown_fields = true }) catch return null;
    if (value.call_id.len == 0 or value.call_id.len > session_event.max_conversation_identity_bytes) return null;
    return value.call_id;
}

/// An edit's full-diff rows, saved right after its `tool_result` item rather
/// than inside it. Older spark versions reject unknown fields in a piece but
/// skip unknown item types, so they still read the result and show the
/// edit's preview; its data is a `FileReview`.
const file_review_type = "file_review";

const FileReview = struct {
    call_id: []const u8,
    lifecycle_id: types.ToolLifecycleId,
    rows: []const types.CommittedFilePresentationLine,
};

/// `result` without its edit's rows and their lifecycle id, which
/// `encodeFileReview` saves beside it, so the piece has the shape older spark
/// versions read. Checks the whole result first.
fn withoutReviewLines(result: session_event.ConversationToolResult) !session_event.ConversationToolResult {
    var presentation = result.committed_file_presentation orelse return result;
    if (presentation.review_lines == null) return result;
    try session_event.validateConversationEventShape(.{ .tool_result = result }, session_event.conversation_schema_version);
    presentation.review_lines = null;
    presentation.lifecycle_id = null;
    var stripped = result;
    stripped.committed_file_presentation = presentation;
    return stripped;
}

/// The `file_review` item data for `event`'s edit rows, or null when it has
/// none. The data is owned by `a`.
fn encodeFileReview(a: Allocator, event: Event) !?[]u8 {
    const result = switch (event) {
        .tool_result => |value| value,
        else => return null,
    };
    const presentation = result.committed_file_presentation orelse return null;
    const rows = presentation.review_lines orelse return null;
    const lifecycle_id = presentation.lifecycle_id orelse return error.InvalidConversationFrame;
    try session_event.validateCommittedFileReview(result.call_id, lifecycle_id, rows);
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try std.json.Stringify.value(FileReview{ .call_id = result.call_id, .lifecycle_id = lifecycle_id, .rows = rows }, .{}, &out.writer);
    return try out.toOwnedSlice();
}

/// Gives a replayed edit the rows its `file_review` item holds. A review
/// that cannot be read, or matches no edit of the turn, is dropped and the
/// edit keeps its preview.
fn attachFileReview(src: Source, a: Allocator, builder: *session_log.ConversationTurnBuilder, piece: sm.Body.Piece) !void {
    const data = src.pieceData(a, piece) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("session", "event=sessions_v2_file_review_unreadable session={s} err={s} dropped=file_review", .{ src.id, @errorName(err) });
            return;
        },
    };
    const review = json_decode.parseFromSliceLeaky(FileReview, a, data, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("session", "event=sessions_v2_file_review_invalid session={s} err={s} dropped=file_review", .{ src.id, @errorName(err) });
            return;
        },
    };
    session_event.validateCommittedFileReview(review.call_id, review.lifecycle_id, review.rows) catch |err| {
        debug_trace.logf("session", "event=sessions_v2_file_review_invalid session={s} err={s} dropped=file_review", .{ src.id, @errorName(err) });
        return;
    };
    if (!try builder.attachReviewLines(review.call_id, review.lifecycle_id, review.rows)) {
        debug_trace.logf("session", "event=sessions_v2_file_review_unmatched session={s} call_id={s} dropped=file_review", .{ src.id, review.call_id });
    }
}
/// What the model reads for a call that was running when its turn ended.
pub const unfinished_tool_output = "spark stopped while this tool was running, so it may have partly run. Check its effects before running it again.";
const blob_ref_key = "$blob";
const blob_ref_prefix = "{\"" ++ blob_ref_key ++ "\":\"";

/// The blob a large piece's data refers to (`itemAs`), or null for a piece
/// held inline. Borrows from `data`.
fn blobRefOf(data: []const u8) ?[]const u8 {
    if (data.len != blob_ref_prefix.len + artifact_digest.blob_hex_bytes + 2) return null;
    if (!std.mem.startsWith(u8, data, blob_ref_prefix) or !std.mem.endsWith(u8, data, "\"}")) return null;
    return data[blob_ref_prefix.len..][0..artifact_digest.blob_hex_bytes];
}

const CompactedData = struct {
    summary: []const u8,
    removed_turn_count: usize,
    compaction_count: usize,
    /// The first turn the compaction kept, read back to on resume.
    keep_from_turn: ?u64 = null,
    /// The steps and steering messages of the first kept turn that the
    /// summary covers, which spark's history leaves out of that turn, as it
    /// does when it compacts inside a turn (D87). Older lines have neither,
    /// and keep the turn whole.
    keep_tool_steps: usize = 0,
    keep_steering: usize = 0,
};

/// What spark's history leaves out of its first kept turn (D87): none, or the
/// steps and steering messages of `turn` a compaction covers.
const Trim = struct {
    turn: ?u64 = null,
    tool_steps: usize = 0,
    steering: usize = 0,
};

/// The compaction line a page read at its cursor starts with, or null when
/// that line is damaged. Open reads only line 1, the newest snapshot and the
/// tail, and every compaction is followed by a snapshot, so damage to its
/// line shows only here.
fn compactedData(page: *const sm.Page) ?[]const u8 {
    if (page.entries.len == 0) return null;
    const body = page.entries[0].body orelse return null;
    return switch (body) {
        .compacted => |line| line.data,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Encodings (pure)

/// The item `type` of each v1 piece kind.
fn itemType(kind: PieceKind) ?[]const u8 {
    return switch (kind) {
        .user => "user",
        .assistant => "assistant",
        .tool_call => "tool_call",
        .tool_result => "tool_result",
        .steering => "steering",
        .turn_completed => "turn_end",
        .interrupted => "interruption",
        .context_checkpoint => null,
        // An older spark leaves out an item type it does not know (D17, D93, D94).
        .context_note => "context_note",
        .runtime_context => "runtime_context",
        .model_call => "model_call",
    };
}

fn pieceKind(item_type: []const u8) ?PieceKind {
    inline for (@typeInfo(PieceKind).@"enum".field_values) |field_value| {
        const kind: PieceKind = @fromBackingInt(@intCast(field_value));
        if (itemType(kind)) |name| {
            if (std.mem.eql(u8, name, item_type)) return kind;
        }
    }
    return null;
}

/// A piece's payload as v1 writes it inside its frame.
/// Whether committing `execution` stores a body: a result without its
/// output's handle, or with images but no image handle, as
/// `session_log.externalizeConversationTurnResults` decides.
fn storesBodies(execution: types.ExecutionMemory) bool {
    for (execution.tool_steps) |step| for (step.tool_results) |result| {
        if (result.output_handle == null) return true;
        if (result.tool_images.len > 0 and result.tool_image_handle == null) return true;
    };
    return false;
}

const ListedBatch = struct {
    events: []const sm.Event,
    /// The pending blobs are on the batch's first item.
    listed: bool,
};

/// `events` with every pending blob on its first item, in `a`; unchanged
/// when it has no item or nothing is pending. Only the move lists blobs on a
/// setting (D47).
fn listPending(a: Allocator, events: []const sm.Event, pending: []const BlobHost.Hash) !ListedBatch {
    if (pending.len == 0) return .{ .events = events, .listed = false };
    const at = for (events, 0..) |event, index| {
        if (event == .item) break index;
    } else return .{ .events = events, .listed = false };
    const copy = try a.dupe(sm.Event, events);
    var refs: std.ArrayList([]const u8) = .empty;
    try refs.appendSlice(a, copy[at].item.blobs);
    for (pending) |*hash| {
        const known = for (refs.items) |ref| {
            if (std.mem.eql(u8, ref, hash)) break true;
        } else false;
        if (!known) try refs.append(a, hash);
    }
    copy[at].item.blobs = refs.items;
    return .{ .events = copy, .listed = true };
}

fn encodePiece(alloc: Allocator, event: Event) ![]u8 {
    try session_event.validateConversationEventShape(event, session_event.conversation_schema_version);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    switch (event) {
        .user => |user| {
            var scratch = std.heap.ArenaAllocator.init(alloc);
            defer scratch.deinit();
            try std.json.Stringify.value(try WireUser.of(scratch.allocator(), user), .{}, &out.writer);
        },
        inline else => |payload| try std.json.Stringify.value(payload, .{}, &out.writer),
    }
    return out.toOwnedSlice();
}

/// A call record from the log, or null when it can't be parsed or fails its
/// checks. A newer spark's extra fields are ignored. Strings are in `arena`.
fn decodeModelCall(arena: Allocator, data: []const u8) ?types.ModelCallRecord {
    const record = json_decode.parseFromSliceLeaky(types.ModelCallRecord, arena, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    session_event.validateConversationEventShape(.{ .model_call = record }, session_event.conversation_schema_version) catch return null;
    return record;
}

/// Payload slices point into `arena` or `data`.
/// With `.alloc_if_needed`, strings may point into `data`.
fn decodePiece(arena: Allocator, kind: PieceKind, data: []const u8, allocate: std.json.AllocWhen) !Event {
    const event: Event = switch (kind) {
        .user => .{ .user = try (try json_decode.parseFromSliceLeaky(WireUser, arena, data, .{ .allocate = allocate })).toUser(arena) },
        inline else => |tag| @unionInit(Event, @tagName(tag), try json_decode.parseFromSliceLeaky(
            @FieldType(Event, @tagName(tag)),
            arena,
            data,
            .{ .allocate = allocate },
        )),
    };
    try session_event.validateConversationEventShape(event, session_event.conversation_schema_version);
    return event;
}

/// Reads the bytes as a piece of every kind, as replay does for a v2 item.
fn fuzzConversationPiece(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    inline for (@typeInfo(PieceKind).@"enum".field_names) |name| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        _ = decodePiece(arena_state.allocator(), @field(PieceKind, name), buffer[0..len], .alloc_always) catch {};
    }
    // Replay reads a model call record this way instead, and keeps one only
    // when every string is one Ctrl+O may show.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    if (decodeModelCall(arena_state.allocator(), buffer[0..len])) |record| {
        try std.testing.expect(types.validModelCallText(record.provider) and types.validModelCallText(record.model));
        inline for (.{ record.served_by, record.generation_id, record.finish, record.failure }) |text| {
            if (text) |value| try std.testing.expect(types.validModelCallText(value));
        }
    }
}

/// A user piece as v2 writes it: `session_event.ConversationUser` field for
/// field, so a prompt without inline images encodes as v1's does. An
/// image's inline bytes, which a v2 session keeps inside the turn (D44),
/// are base64 text, since a JSON string cannot hold raw bytes.
const WireUser = struct {
    text: []const u8,
    images: []const WireImage = &.{},
    work_id: ?[]const u8 = null,

    /// `types.ImageAttachment` field for field, with `inline_data` in base64,
    /// or the image's own blob (D89): `blob` names it by its digest, and the
    /// bytes, the digest, and the snapshot are not written again.
    const WireImage = struct {
        id: usize = 0,
        path: []const u8,
        media_type: []const u8,
        snapshot_path: ?[]const u8 = null,
        snapshot_sha256: ?[]const u8 = null,
        inline_data: ?[]const u8 = null,
        source_ref: ?[]const u8 = null,
        blob: ?[]const u8 = null,

        pub fn jsonStringify(self: WireImage, writer: *std.json.Stringify) !void {
            try writer.beginObject();
            inline for (@typeInfo(WireImage).@"struct".field_names) |field_name| {
                // Written only when set, so an image without them encodes
                // as it did before they existed.
                const optional = comptime std.mem.eql(u8, field_name, "source_ref") or std.mem.eql(u8, field_name, "blob");
                // An image in its blob has no bytes, digest or snapshot here.
                const in_blob = comptime std.mem.eql(u8, field_name, "snapshot_path") or
                    std.mem.eql(u8, field_name, "snapshot_sha256") or
                    std.mem.eql(u8, field_name, "inline_data");
                const write = if (optional) @field(self, field_name) != null else !(in_blob and self.blob != null);
                if (write) {
                    try writer.objectField(field_name);
                    try writer.write(@field(self, field_name));
                }
            }
            try writer.endObject();
        }
    };

    const codec = std.base64.standard;

    fn of(a: Allocator, user: session_event.ConversationUser) !WireUser {
        const images = try a.alloc(WireImage, user.images.len);
        for (user.images, images) |image, *wire| {
            if (image.source_ref) |value| {
                if (!image_data.validSourceRef(value)) return error.InvalidSessionFormat;
            }
            if (image.blob_path != null) {
                wire.* = .{
                    .id = image.id,
                    .path = image.path,
                    .media_type = image.media_type,
                    .source_ref = image.source_ref,
                    .blob = image.snapshot_sha256 orelse return error.InvalidSessionFormat,
                };
                continue;
            }
            wire.* = .{
                .id = image.id,
                .path = image.path,
                .media_type = image.media_type,
                .snapshot_path = image.snapshot_path,
                .snapshot_sha256 = image.snapshot_sha256,
                .inline_data = if (image.inline_data) |bytes| blk: {
                    const encoded = try a.alloc(u8, codec.Encoder.calcSize(bytes.len));
                    break :blk codec.Encoder.encode(encoded, bytes);
                } else null,
                .source_ref = image.source_ref,
            };
        }
        return .{ .text = user.text, .images = images, .work_id = user.work_id };
    }

    fn toUser(wire: WireUser, a: Allocator) !session_event.ConversationUser {
        return .{ .text = wire.text, .images = try wire.toImages(a), .work_id = wire.work_id };
    }

    /// The images, without the bytes of those in blobs: `Source.decodeUser`
    /// reads those.
    fn toImages(wire: WireUser, a: Allocator) ![]types.ImageAttachment {
        const images = try a.alloc(types.ImageAttachment, wire.images.len);
        for (wire.images, images) |image, *out| {
            if (image.source_ref) |value| {
                if (!image_data.validSourceRef(value)) return error.InvalidSessionFormat;
            }
            if (image.blob) |hash| {
                if (image.inline_data != null or image.snapshot_path != null or image.snapshot_sha256 != null) return error.InvalidSessionFormat;
                out.* = .{
                    .id = image.id,
                    .path = try a.dupe(u8, image.path),
                    .media_type = try a.dupe(u8, image.media_type),
                    .snapshot_sha256 = try a.dupe(u8, hash),
                    .source_ref = if (image.source_ref) |value| try a.dupe(u8, value) else null,
                };
                continue;
            }
            out.* = .{
                .id = image.id,
                .path = try a.dupe(u8, image.path),
                .media_type = try a.dupe(u8, image.media_type),
                .snapshot_path = if (image.snapshot_path) |value| try a.dupe(u8, value) else null,
                .snapshot_sha256 = if (image.snapshot_sha256) |value| try a.dupe(u8, value) else null,
                .inline_data = if (image.inline_data) |encoded| blk: {
                    const size = codec.Decoder.calcSizeForSlice(encoded) catch return error.InvalidSessionFormat;
                    const bytes = try a.alloc(u8, size);
                    codec.Decoder.decode(bytes, encoded) catch return error.InvalidSessionFormat;
                    break :blk bytes;
                } else null,
                .source_ref = if (image.source_ref) |value| try a.dupe(u8, value) else null,
            };
        }
        return images;
    }
};

fn jsonValue(alloc: Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn jsonString(alloc: Allocator, value: []const u8) ![]u8 {
    return jsonValue(alloc, value);
}

/// v1's shape, which `session_codec.parse_preferences` reads back: effort
/// as its label, the provider in its saved form.
/// A child's `prefs` also hold its instructions under this key (D34).
const instructions_key = "instructions";

fn encodePreferences(alloc: Allocator, preferences: session_codec.DurableSessionPreferences, instructions: ?[]const u8) ![]u8 {
    const Saved = struct {
        provider: model_provider.ProviderId,
        model: []const u8,
        effort: []const u8,
        fast_mode: bool,
        ultrafast_mode: ?bool,
        instructions: ?[]const u8,
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(Saved{
        .provider = preferences.provider,
        .model = preferences.model,
        .effort = preferences.effort.label(),
        .fast_mode = preferences.fast_mode,
        .ultrafast_mode = if (preferences.ultrafast_mode) true else null,
        .instructions = instructions,
    }, .{ .emit_null_optional_fields = false }, &out.writer);
    return out.toOwnedSlice();
}

fn decodePreferences(alloc: Allocator, raw: []const u8) !session_codec.DurableSessionPreferences {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    // v1's codec knows every field but a child's instructions.
    if (parsed.value == .object) _ = parsed.value.object.swapRemove(instructions_key);
    return session_codec.parse_preferences(alloc, parsed.value);
}

/// A child's instructions from its `prefs`, or null. Caller owns.
fn decodeInstructions(alloc: Allocator, raw: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSessionFormat;
    const value = parsed.value.object.get(instructions_key) orelse return null;
    if (value != .string) return error.InvalidSessionFormat;
    return try alloc.dupe(u8, value.string);
}

fn decodeLanguage(arena: Allocator, raw: []const u8) !types.ConversationLanguage {
    const tag = try json_decode.parseFromSliceLeaky([]const u8, arena, raw, .{});
    return session_codec.parseConversationLanguage(tag);
}

/// A fork's title: the source's, marked once as a fork (D58).
fn forkTitle(arena: Allocator, title: []const u8) ![]const u8 {
    const mark = " (fork)";
    if (std.mem.endsWith(u8, title, mark)) return title;
    return arena.print("{s}" ++ mark, .{title});
}

/// The title v1 derives from the first prompt of `history`, if any.
fn deriveTitle(arena: Allocator, history: []const types.HistoryTurn) !?[]const u8 {
    const display = session_display_metadata.deriveFromHistory(arena, history) catch return null;
    if (!display.present or std.mem.eql(u8, display.title, session_display_metadata.fallback_title)) return null;
    return display.title;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// A HOME in a temp folder with an adapter store over it.
const TestHome = struct {
    tmp: testing.TmpDir,
    home: []u8,
    store: Store,

    fn init(t: *TestHome) !void {
        // Iterable, so Linux gives a real descriptor that `fsync` accepts
        // when a test makes `.spark` here (`io_mod.syncVerifiedDir`).
        t.tmp = testing.tmpDir(.{ .iterate = true });
        errdefer t.tmp.cleanup();
        t.home = try io_mod.dirRealpathAlloc(testing.allocator, t.tmp.dir, ".");
        errdefer testing.allocator.free(t.home);
        t.store = try Store.open(testing.allocator, t.home);
    }

    fn deinit(t: *TestHome) void {
        t.store.deinit(testing.allocator);
        testing.allocator.free(t.home);
        t.tmp.cleanup();
    }
};

fn testSeed(model: []u8) Seed {
    return .{
        .preferences = .{ .model = model, .effort = .auto, .fast_mode = false },
        .language = types.ConversationLanguage.default(),
    };
}

fn assistantTurn(user: []const u8, reply: []const u8) types.HistoryTurn {
    return .{ .assistant = .{
        .user = .{ .text = @constCast(user) },
        .assistant = @constCast(reply),
    } };
}

fn childSeed(model: []u8, instructions: []const u8) Seed {
    var seed = testSeed(model);
    seed.instructions = instructions;
    return seed;
}

fn countItems(manager: *sm.Manager, id: []const u8, item_type: []const u8) !usize {
    var page = try manager.read(testing.allocator, id, .start, .forward, 1000);
    defer page.deinit();
    var n: usize = 0;
    for (page.entries) |entry| {
        const body = entry.body orelse continue;
        if (body == .item and std.mem.eql(u8, body.item.type, item_type)) n += 1;
    }
    return n;
}

/// The inline data of the first item of `item_type`. Caller owns it.
fn firstItemData(manager: *sm.Manager, id: []const u8, item_type: []const u8) ![]u8 {
    var page = try manager.read(testing.allocator, id, .start, .forward, 1000);
    defer page.deinit();
    for (page.entries) |entry| {
        const body = entry.body orelse continue;
        if (body == .item and std.mem.eql(u8, body.item.type, item_type)) return testing.allocator.dupe(u8, body.item.data);
    }
    return error.TestUnexpectedResult;
}

const capture_start_a = "{\"repo\":\"a\",\"phase\":\"start\"}";
const capture_start_b = "{\"repo\":\"b\",\"phase\":\"start\"}";
const capture_end_a = "{\"repo\":\"a\",\"phase\":\"end\"}";
const capture_end_b = "{\"repo\":\"b\",\"phase\":\"end\"}";

/// Session `id`'s turn lines in order, each as a short name: `capture
/// <data>` for a workspace capture, `item <type>` for any other item, and
/// the end lines with their reason. Settings, snapshots and `closed` are
/// left out. `a` owns the list.
fn turnLines(a: Allocator, manager: *sm.Manager, id: []const u8) ![]const []const u8 {
    var page = try manager.read(testing.allocator, id, .start, .forward, 1000);
    defer page.deinit();
    var lines: std.ArrayList([]const u8) = .empty;
    for (page.entries) |entry| {
        const body = entry.body orelse continue;
        const line: []const u8 = switch (body) {
            .item => |piece| if (std.mem.eql(u8, piece.type, workspace_capture_type))
                try a.print("capture {s}", .{piece.data})
            else
                try a.print("item {s}", .{piece.type}),
            .turn_interrupted => |ended| try a.print("turn_interrupted {t}", .{ended.reason}),
            .turn_started, .turn_committed => @tagName(body),
            .session_created, .compacted, .set, .child_spawned, .child_finished, .snapshot, .closed => continue,
        };
        try lines.append(a, line);
    }
    return lines.items;
}

fn expectLines(expected: []const []const u8, actual: []const []const u8) !void {
    const same = expected.len == actual.len and for (expected, actual) |want, got| {
        if (!std.mem.eql(u8, want, got)) break false;
    } else true;
    if (same) return;
    std.debug.print("expected lines:\n", .{});
    for (expected) |line| std.debug.print("  {s}\n", .{line});
    std.debug.print("actual lines:\n", .{});
    for (actual) |line| std.debug.print("  {s}\n", .{line});
    return error.TestExpectedEqual;
}

/// Saves a capture for `s`'s current capture turn, beginning one when none
/// is open, as a host does at a turn's start.
fn saveCapture(s: *Session, payload: []const u8, place: Session.CapturePlace) !bool {
    const turn: Session.CaptureTurn = if (s.capture_turn == 0) s.beginCaptureTurn() else @fromBackingInt(s.capture_turn);
    return s.saveWorkspaceCapture(turn, payload, place);
}

/// Commits `turn` with the current capture turn's token, as a host does
/// for the turn it began, or plainly when no capture turn is open.
fn commitCaptured(s: *Session, turn: types.HistoryTurn, language: types.ConversationLanguage) !void {
    if (s.capture_turn == 0) return s.commitTurn(turn, language);
    return s.commitTurnWithCaptures(turn, language, @fromBackingInt(s.capture_turn));
}

/// A finished turn whose one tool result has no stored body yet, so
/// `prepareTurn` stores it and allocates for it.
const TurnWithResult = struct {
    calls: [1]types.ToolCall = .{.{ .id = "call-1", .name = "read_file", .arguments_json = "{}" }},
    results: [1]types.PersistedToolResult = .{.{
        .tool_call_id = @constCast("call-1"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("file body"),
        .output_bytes = "file body".len,
        .stored_output_bytes = "file body".len,
    }},
    steps: [1]types.ToolExecutionStep = undefined,

    fn turn(self: *TurnWithResult, user: types.UserTurn) types.HistoryTurn {
        self.steps = .{.{ .tool_calls = &self.calls, .tool_results = &self.results }};
        return .{ .assistant = .{ .user = user, .assistant = @constCast("read"), .execution = .{ .tool_steps = &self.steps } } };
    }
};

/// How many of `lines` are `capture <payload>`.
fn countCaptureLines(lines: []const []const u8, payload: []const u8) usize {
    var n: usize = 0;
    for (lines) |line| {
        if (std.mem.startsWith(u8, line, "capture ") and std.mem.eql(u8, line["capture ".len..], payload)) n += 1;
    }
    return n;
}

/// The lines of the newest turn: from its `turn_started` on.
fn newestTurn(lines: []const []const u8) []const []const u8 {
    var from: usize = 0;
    for (lines, 0..) |line, i| {
        if (std.mem.eql(u8, line, "turn_started")) from = i;
    }
    return lines[from..];
}

/// Fails unless `got` and `want` give the model the same messages: the same
/// summaries, and each turn's pieces encoded alike.
fn expectSameHistory(a: Allocator, want: []const types.HistoryTurn, got: []const types.HistoryTurn) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |want_turn, got_turn| {
        if (want_turn == .compacted_summary) {
            try testing.expectEqualStrings(want_turn.compacted_summary.summary, got_turn.compacted_summary.summary);
            continue;
        }
        var want_events: std.ArrayList(Event) = .empty;
        var got_events: std.ArrayList(Event) = .empty;
        try session_event.appendHistoryTurnConversationEvents(a, &want_events, want_turn);
        try session_event.appendHistoryTurnConversationEvents(a, &got_events, got_turn);
        try testing.expectEqual(want_events.items.len, got_events.items.len);
        for (want_events.items, got_events.items) |want_event, got_event| {
            try testing.expectEqualStrings(try encodePiece(a, want_event), try encodePiece(a, got_event));
        }
    }
}

/// `{"x":"xx…x"}`, exactly `len` bytes long. `a` owns it.
fn objectOfLength(a: Allocator, len: usize) ![]u8 {
    const bytes = try a.alloc(u8, len);
    @memset(bytes, 'x');
    @memcpy(bytes[0..6], "{\"x\":\"");
    @memcpy(bytes[len - 2 ..], "\"}");
    return bytes;
}

/// Ends `s` as a killed process would: its lock and files let go with
/// nothing more written, and what it held only in memory gone.
fn crashSession(s: *Session) void {
    s.host.detach();
    s.handle.inner.abandon();
    s.destroyInner();
}

/// Leaves `s` with a failed turn open: a start capture on disk, a commit
/// that failed, and the next turn's token begun, which marks it stale.
fn leaveStaleTurn(s: *Session, failing: *std.testing.FailingAllocator) !void {
    const one: types.UserTurn = .{ .text = @constCast("one") };
    var extra: usize = 0;
    while (true) : (extra += 1) {
        const token = s.beginCaptureTurn();
        if (s.turn_open and s.turn_stale) return;
        try testing.expect(!try s.saveWorkspaceCapture(token, capture_start_a, .start));
        if (!s.turn_open) try s.appendProgress(one, .{}, .{});
        failing.fail_index = failing.alloc_index + extra;
        const result = s.commitTurnWithCaptures(.{ .assistant = .{ .user = one, .assistant = @constCast("done") } }, types.ConversationLanguage.default(), token);
        failing.fail_index = std.math.maxInt(usize);
        if (result) |_| return error.TestUnexpectedResult else |_| {}
    }
}

fn countTitleSets(manager: *sm.Manager, id: []const u8) !usize {
    var page = try manager.read(testing.allocator, id, .start, .forward, 1000);
    defer page.deinit();
    var n: usize = 0;
    for (page.entries) |entry| {
        const body = entry.body orelse continue;
        if (body == .set and body.set.key == .title) n += 1;
    }
    return n;
}

fn storedTitle(s: *Session) !?[]u8 {
    const shown = try s.info(testing.allocator);
    return shown.title;
}

fn commitPrompt(s: *Session, prompt: []const u8) !void {
    try s.commitTurn(.{ .assistant = .{ .user = .{ .text = @constCast(prompt) }, .assistant = @constCast("ok") } }, types.ConversationLanguage.default());
}

fn lineCount(manager: *sm.Manager, id: []const u8) !usize {
    var page = try manager.read(testing.allocator, id, .start, .forward, 1000);
    defer page.deinit();
    return page.entries.len;
}

fn resultEvent(call_id: []const u8, preview: []const u8, stamp: i64) Event {
    return .{ .tool_result = .{
        .call_id = call_id,
        .tool_name = "read_file",
        .status = .success,
        .artifact_ref = "result-read_file.txt",
        .stored_bytes = preview.len,
        .completeness = .complete,
        .preview = preview,
        .created_at_ms = stamp,
    } };
}

fn encodeAll(a: Allocator, events: []const Event) ![]const []const u8 {
    const encoded = try a.alloc([]const u8, events.len);
    for (events, encoded) |event, *bytes| bytes.* = try encodePiece(a, event);
    return encoded;
}

fn readResult(call_id: []const u8, output: []const u8, stamp: i64) types.PersistedToolResult {
    return .{
        .tool_call_id = @constCast(call_id),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast(output),
        .output_bytes = output.len,
        .stored_output_bytes = output.len,
        .created_at_ms = stamp,
    };
}

/// The stamp of the one tool result a session's only turn restores with.
fn restoredStamp(t: *TestHome, id: []const u8) !i64 {
    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), restored.history.len);
    const steps = restored.history[0].assistant.execution.tool_steps;
    try testing.expectEqual(@as(usize, 1), steps.len);
    try testing.expectEqual(@as(usize, 1), steps[0].tool_results.len);
    return steps[0].tool_results[0].created_at_ms;
}

/// Two shell steps whose results name their stored bodies.
const NoteTestSteps = struct {
    calls: [3]types.ToolCall = .{
        .{ .id = "call-1", .name = "shell", .arguments_json = "{}" },
        .{ .id = "call-2", .name = "shell", .arguments_json = "{}" },
        .{ .id = "call-3", .name = "shell", .arguments_json = "{}" },
    },
    results: [3]types.PersistedToolResult = .{
        ok("call-1", "result-shell-1.txt"),
        ok("call-2", "result-shell-2.txt"),
        ok("call-3", "result-shell-3.txt"),
    },
    steps: [3]types.ToolExecutionStep = undefined,

    fn ok(id: []const u8, handle: []const u8) types.PersistedToolResult {
        return .{ .tool_call_id = @constCast(id), .tool_name = @constCast("shell"), .status = .success, .output = @constCast("ok"), .output_bytes = 2, .output_handle = @constCast(handle), .stored_output_bytes = 2 };
    }

    fn init(self: *NoteTestSteps) void {
        for (&self.steps, 0..) |*step, i| step.* = .{ .tool_calls = self.calls[i .. i + 1], .tool_results = self.results[i .. i + 1] };
    }
};

fn pathExists(t: *TestHome, parts: []const []const u8) bool {
    const path = std.Io.Dir.path.join(testing.allocator, parts) catch return false;
    defer testing.allocator.free(path);
    t.tmp.dir.access(io_mod.getIo(), path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn countSettings(manager: *sm.Manager, id: []const u8, key: sm.SetKey) !usize {
    var page = try manager.read(testing.allocator, id, .start, .forward, 1000);
    defer page.deinit();
    var n: usize = 0;
    for (page.entries) |entry| {
        const body = entry.body orelse continue;
        if (body == .set and body.set.key == key) n += 1;
    }
    return n;
}

/// A turn with one step whose single result answers `call-1`.
fn toolTurn(user: []const u8, results: []types.PersistedToolResult, steps: []types.ToolExecutionStep) types.HistoryTurn {
    const calls = struct {
        var list = [_]types.ToolCall{.{ .id = "call-1", .name = "shell", .arguments_json = "{}" }};
    };
    steps[0] = .{ .tool_calls = &calls.list, .tool_results = results };
    return .{ .assistant = .{
        .user = .{ .text = @constCast(user) },
        .assistant = @constCast("done"),
        .execution = .{ .tool_steps = steps },
    } };
}

/// The side folder an older v2 session kept (D27), with one body of each
/// kind the move carries, the client's settings, and terminal state.
const OldSideFolder = struct {
    const result_handle = "result-shell-0011223344556677-8899aabbccddeeff.txt";
    const replay_handle = "spark-command-replay-00000000000000000000000000000000-0123456789abcdef.bin";
    const image_name = "image-1.png";
    const png = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1f, 0x15, 0xc4, 0x89 };

    fn write(t: *TestHome, id: []const u8) !void {
        const io = io_mod.getIo();
        var spark = try io_mod.openOrCreateVerifiedPrivateDirFromDir(t.tmp.dir, ".spark");
        defer spark.close();
        var files = try io_mod.openOrCreateVerifiedPrivateDir(&spark, files_dir_name);
        defer files.close();
        var side = try io_mod.openOrCreateVerifiedPrivateDir(&files, id);
        defer side.close();
        try side.dir.createDirPath(io, "tool-results");
        try side.dir.writeFile(io, .{ .sub_path = "tool-results/" ++ result_handle, .data = "an old result body" });
        try side.dir.writeFile(io, .{ .sub_path = "tool-results/compacted-T9.txt", .data = "T9 kept by the compactor before the move" });
        try side.dir.createDirPath(io, "logs/commands");
        try side.dir.writeFile(io, .{ .sub_path = "logs/commands/" ++ replay_handle, .data = "FXRPLY01" });
        try side.dir.createDirPath(io, "images");
        try side.dir.writeFile(io, .{ .sub_path = "images/" ++ image_name, .data = &png });
        try side.dir.createDirPath(io, "client");
        try side.dir.writeFile(io, .{ .sub_path = moved_client_prompt_file, .data = "You run inside Mini." });
        try side.dir.writeFile(io, .{ .sub_path = moved_tool_identities_file, .data = "{\"mcp_mini_read\":{\"server\":\"mini\",\"tool\":\"read\",\"title\":null}}" });
        try side.dir.createDirPath(io, "terminal/state");
        try side.dir.writeFile(io, .{ .sub_path = "terminal/state/terminal-1.json", .data = "{}" });
    }

    /// A turn whose user image and tool result point into the side folder.
    fn commitTurn(t: *TestHome, s: *Session) !void {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&png, &digest, .{});
        var digest_hex = std.fmt.bytesToHex(digest, .lower);
        const snapshot_path = try std.Io.Dir.path.join(testing.allocator, &.{ t.home, ".spark", files_dir_name, s.id(), "images", image_name });
        defer testing.allocator.free(snapshot_path);
        var images = [_]types.ImageAttachment{.{
            .id = 1,
            .path = @constCast("/Users/example/shot.png"),
            .media_type = @constCast("image/png"),
            .snapshot_path = snapshot_path,
            .snapshot_sha256 = &digest_hex,
        }};
        var results = [_]types.PersistedToolResult{.{
            .tool_call_id = @constCast("call-1"),
            .tool_name = @constCast("shell"),
            .status = .success,
            .output = @constCast("an old result body"),
            .output_bytes = 18,
            .stored_output_bytes = 18,
            .output_handle = @constCast(result_handle),
            .preview = @constCast("an old"),
        }};
        var steps: [1]types.ToolExecutionStep = undefined;
        var turn = toolTurn("look", &results, &steps);
        turn.assistant.user.images = &images;
        try s.commitTurn(turn, types.ConversationLanguage.default());
    }
};

/// Every `compaction_records` setting in session `id`'s log, as the count
/// of records each lists besides its own map, and how many records they
/// list in all. Fails when a setting leaves out its map or two list the same
/// record (D50). In `arena`.
fn recordListings(arena: Allocator, manager: *sm.Manager, id: []const u8) !struct { counts: []usize, records: usize } {
    var page = try manager.read(testing.allocator, id, .start, .forward, 10_000);
    defer page.deinit();
    var counts: std.ArrayList(usize) = .empty;
    var listed: std.array_hash_map.String(void) = .empty;
    for (page.entries) |entry| {
        const body = entry.body orelse continue;
        if (body != .set or body.set.key != .compaction_records) continue;
        const value = try std.json.parseFromSliceLeaky(struct { map: []const u8 }, arena, body.set.value, .{ .allocate = .alloc_always });
        var lists_map = false;
        var count: usize = 0;
        for (body.set.blobs) |hash| {
            if (std.mem.eql(u8, hash, value.map)) {
                lists_map = true;
                continue;
            }
            const slot = try listed.getOrPut(arena, try arena.dupe(u8, hash));
            try testing.expect(!slot.found_existing);
            count += 1;
        }
        try testing.expect(lists_map);
        try counts.append(arena, count);
    }
    return .{ .counts = counts.items, .records = listed.count() };
}

/// Holds the first write that takes due records until `go` is set, so a
/// test can run another write of the session, or keep a record, meanwhile.
const HeldWrite = struct {
    var held: std.Io.Event = .unset;
    var go: std.Io.Event = .unset;
    var calls = std.atomic.Value(u32).init(0);

    fn arm() void {
        held = .unset;
        go = .unset;
        calls.store(0, .seq_cst);
        write_test_controls.test_hold = hold;
    }

    fn disarm() void {
        write_test_controls.test_hold = null;
    }

    fn hold(_: usize) void {
        if (calls.fetchAdd(1, .seq_cst) != 0) return;
        held.set(io_mod.getIo());
        go.waitUncancelable(io_mod.getIo());
    }

    fn write(session: *Session, text: []const u8, done: *std.atomic.Value(bool), failed: *std.atomic.Value(bool)) void {
        session.setClientPrompt(text) catch failed.store(true, .seq_cst);
        done.store(true, .seq_cst);
    }

    /// A subagent's line, as when one is spawned or finishes: unlike
    /// `setClientPrompt`, it doesn't take `Session.mutex`, so only the write
    /// lock makes it wait.
    fn childLine(session: *Session, child: []const u8, done: *std.atomic.Value(bool), failed: *std.atomic.Value(bool)) void {
        session.appendChildLines(&.{.{ .spawned = .{ .child = child, .work_id = "w1", .data = "{\"kind\":\"persistent\"}" } }}) catch failed.store(true, .seq_cst);
        done.store(true, .seq_cst);
    }
};

/// Each byte is one step: keep a new record (0), keep a record again under
/// a name already kept (1), save a setting that cites nothing (2), or end
/// the turn and start the next (3). Every record kept must then be listed
/// by exactly one `compaction_records` setting, each setting lists its own
/// map too, and the session resumes with every name kept (D50).
fn fuzzRecordsListing(_: void, smith: *std.testing.Smith) !void {
    var steps: [24]u8 = undefined;
    const len: usize = @intCast(smith.slice(&steps));
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    var open = true;
    defer if (open) s.close();
    try s.beginTurn();
    const records = result_store.compactorStore(try s.childCapability());
    var kept: usize = 0;
    var puts: usize = 0;
    var name_buf: [32]u8 = undefined;
    var body_buf: [48]u8 = undefined;
    for (steps[0..len], 0..) |step, index| {
        switch (step % 4) {
            0, 1 => {
                const slot = if (step % 4 == 1 and kept > 0) (step / 4) % kept else blk: {
                    kept += 1;
                    break :blk kept - 1;
                };
                puts += 1;
                const name = try std.mem.print(&name_buf, "compacted-T{d}.txt", .{slot});
                const body = try std.mem.print(&body_buf, "T{d} result {d}\n", .{ slot, puts });
                try records.write(testing.allocator, name, body);
            },
            2 => try s.setClientPrompt(try std.mem.print(&body_buf, "prompt {d}", .{index})),
            else => {
                try s.commitTurn(assistantTurn("step", "done"), types.ConversationLanguage.default());
                try s.beginTurn();
            },
        }
    }
    try s.commitTurn(assistantTurn("last", "done"), types.ConversationLanguage.default());

    var listings_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer listings_arena.deinit();
    const listings = try recordListings(listings_arena.allocator(), t.store.manager, s.id());
    // Each put kept new bytes, so each is its own record.
    try testing.expectEqual(puts, listings.records);

    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();
    open = false;
    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const names = try result_store.compactorStore(try r.childCapability()).list(arena_state.allocator());
    try testing.expectEqual(kept, names.len);
}

/// Whether session `id`'s first user item lists blob `hash`.
fn userItemLists(t: *TestHome, id: []const u8, hash: []const u8) !bool {
    var page = try t.store.manager.read(testing.allocator, id, .start, .forward, 64);
    defer page.deinit();
    for (page.entries) |entry| {
        const body = entry.body orelse continue;
        if (body != .item or !std.mem.eql(u8, body.item.type, "user")) continue;
        for (body.item.blobs) |ref| if (std.mem.eql(u8, ref, hash)) return true;
        return false;
    }
    return error.TestUnexpectedResult;
}

/// Session `id`'s first `user` item, whether it lists blob `hash`, and how
/// many turns were superseded. The caller frees `data`.
const UserItem = struct { data: []u8, lists: bool, superseded: usize };

fn firstUserItem(manager: *sm.Manager, id: []const u8, hash: []const u8) !UserItem {
    var page = try manager.read(testing.allocator, id, .start, .forward, 1000);
    defer page.deinit();
    var found: ?UserItem = null;
    var superseded: usize = 0;
    for (page.entries) |entry| {
        const body = entry.body orelse continue;
        if (body != .item) continue;
        if (std.mem.eql(u8, body.item.type, superseded_type)) superseded += 1;
        if (found != null or !std.mem.eql(u8, body.item.type, itemType(.user).?)) continue;
        const lists = for (body.item.blobs) |ref| {
            if (std.mem.eql(u8, ref, hash)) break true;
        } else false;
        found = .{ .data = try testing.allocator.dupe(u8, body.item.data), .lists = lists, .superseded = 0 };
    }
    var item = found orelse return error.TestUnexpectedResult;
    item.superseded = superseded;
    return item;
}

/// Whether this process writes into `dir` whatever its mode, as root or a
/// process with `CAP_DAC_OVERRIDE` does. A test of a refused write can't
/// run then, so it skips.
fn writesWhateverTheMode(dir: std.Io.Dir) bool {
    const io = io_mod.getIo();
    dir.writeFile(io, .{ .sub_path = ".mode-probe", .data = "" }) catch return false;
    dir.deleteFile(io, ".mode-probe") catch {};
    return true;
}

/// v1's own store over a test home, which writes the v1 sessions the
/// conversion tests convert.
/// A test home's v1 sessions: copies of what the real v0.0.14 release saved
/// (`tests/fixtures/v1-sessions/generate.ts`), and raw files a test writes
/// over them.
const V1Home = struct {
    t: *TestHome,
    arena: std.heap.ArenaAllocator,
    /// Where the fixtures were saved, which v1 recorded; set by `fixture`.
    workspace: []const u8 = "",

    fn init(t: *TestHome) !V1Home {
        return .{ .t = t, .arena = .init(testing.allocator) };
    }

    fn deinit(v1: *V1Home) void {
        v1.arena.deinit();
    }

    /// Copies the first `count` sessions of the fixture `kind`, root first,
    /// into the home's `~/.spark`, private as v1 left them, with what the kind
    /// keeps outside its sessions, and returns their ids.
    fn fixture(v1: *V1Home, kind: []const u8, count: usize) ![]const []const u8 {
        const io = io_mod.getIo();
        const a = v1.arena.allocator();
        const root = try std.Io.Dir.path.join(a, &.{ @import("test_paths").source_root, "..", "tests", "fixtures", "v1-sessions" });
        // `source_root` is relative to the build root, where tests run.
        var fixtures = try std.Io.Dir.cwd().openDir(io, root, .{});
        defer fixtures.close(io);
        const manifest = try fixtures.readFileAlloc(io, "manifest.json", a, .limited(1 << 16));
        const Manifest = struct { workspace: []const u8, kinds: std.json.ArrayHashMap([]const []const u8) };
        const parsed = try json_decode.parseFromSliceLeaky(Manifest, a, manifest, .{ .ignore_unknown_fields = true });
        v1.workspace = parsed.workspace;
        const all = parsed.kinds.map.get(kind) orelse return error.FileNotFound;
        if (count > all.len) return error.TestUnexpectedResult;
        const ids = all[0..count];
        var source = try fixtures.openDir(io, kind, .{ .iterate = true });
        defer source.close(io);
        var spark = try io_mod.openOrCreateVerifiedPrivateDirFromDir(v1.t.tmp.dir, profile_paths.root_dir_name);
        defer spark.close();
        var walker = try source.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            // Leave out the sessions past `count`.
            var parts = std.mem.splitScalar(u8, entry.path, std.Io.Dir.path.sep);
            if (std.mem.eql(u8, parts.first(), profile_paths.sessions_dir_name)) if (parts.next()) |id| {
                const left_out = for (all[count..]) |other| {
                    if (std.mem.eql(u8, id, other)) break true;
                } else false;
                if (left_out) continue;
            };
            switch (entry.kind) {
                // Another kind may have made it.
                .directory => spark.dir.createDir(io, entry.path, .fromMode(0o700)) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                },
                .file => try spark.dir.writeFile(io, .{
                    .sub_path = entry.path,
                    .data = try source.readFileAlloc(io, entry.path, a, .limited(1 << 24)),
                    .flags = .{ .permissions = .fromMode(0o600) },
                }),
                else => return error.UnexpectedFixtureEntry,
            }
        }
        // A copy's log gets the time v1 left on it, its `session.json`'s:
        // v1 lists a session by the later of the two, and a copy's own time
        // would order the copies by when they were made.
        for (ids) |id| {
            const folder = try std.Io.Dir.path.join(a, &.{ profile_paths.sessions_dir_name, id });
            const saved_json = try spark.dir.readFileAlloc(io, try std.Io.Dir.path.join(a, &.{ folder, "session.json" }), a, .limited(1 << 20));
            const Saved = struct { updated_at_ms: ?i64 = null };
            const saved = (try json_decode.parseFromSliceLeaky(Saved, a, saved_json, .{ .ignore_unknown_fields = true })).updated_at_ms orelse continue;
            const at: std.Io.Timestamp = .{ .nanoseconds = @as(i96, saved) * std.time.ns_per_ms };
            const log = try std.Io.Dir.path.join(a, &.{ folder, "events.jsonl" });
            _ = spark.dir.statFile(io, log, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            try spark.dir.setTimestamps(io, log, .{ .modify_timestamp = .{ .new = at } });
        }
        return ids;
    }

    /// Writes `bytes` to `{folder}/{name}` in v1's folder of `id`, the
    /// folders and the file private as v1 makes them.
    fn put(v1: *V1Home, id: []const u8, folder: ?[]const u8, name: []const u8, bytes: []const u8) !void {
        var spark = try io_mod.openOrCreateVerifiedPrivateDirFromDir(v1.t.tmp.dir, profile_paths.root_dir_name);
        defer spark.close();
        var sessions = try io_mod.openOrCreateVerifiedPrivateDir(&spark, profile_paths.sessions_dir_name);
        defer sessions.close();
        var dir = try io_mod.openOrCreateVerifiedPrivateDir(&sessions, id);
        defer dir.close();
        var target = if (folder) |sub| try io_mod.openOrCreateVerifiedPrivateDir(&dir, sub) else null;
        defer if (target) |*value| value.close();
        try (if (target) |value| value.dir else dir.dir).writeFile(io_mod.getIo(), .{ .sub_path = name, .data = bytes, .flags = .{ .permissions = .fromMode(0o600) } });
    }

    /// Makes `ids`' v1 folders readable by others, as an old release left
    /// them (D61): every folder 0755 and every file 0644, lock files too.
    fn readableByOthers(v1: *V1Home, ids: []const []const u8) !void {
        const io = io_mod.getIo();
        const a = v1.arena.allocator();
        for (ids) |id| {
            var dir = try v1.t.tmp.dir.openDir(io, try v1.sessionPath(id, ""), .{ .iterate = true });
            defer dir.close(io);
            try dir.setPermissions(io, .fromMode(0o755));
            var walker = try dir.walk(a);
            defer walker.deinit();
            while (try walker.next(io)) |entry| switch (entry.kind) {
                .directory => try dir.setFilePermissions(io, entry.path, .fromMode(0o755), .{}),
                .file => try dir.setFilePermissions(io, entry.path, .fromMode(0o644), .{}),
                else => {},
            };
        }
    }

    /// v1's `session.json` of `id`. The arena's.
    fn metadata(v1: *V1Home, id: []const u8) !std.json.ObjectMap {
        const a = v1.arena.allocator();
        const path = try std.Io.Dir.path.join(a, &.{ ".spark", "sessions", id, "session.json" });
        const bytes = try v1.t.tmp.dir.readFileAlloc(io_mod.getIo(), path, a, .limited(1 << 20));
        return (try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{})).object;
    }

    /// When v1 logged each prompt of `id`: the times its turns start.
    fn promptTimes(v1: *V1Home, id: []const u8) ![]const u64 {
        const a = v1.arena.allocator();
        const path = try std.Io.Dir.path.join(a, &.{ ".spark", "sessions", id, "events.jsonl" });
        const bytes = try v1.t.tmp.dir.readFileAlloc(io_mod.getIo(), path, a, .limited(1 << 24));
        var times: std.ArrayList(u64) = .empty;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const event = (try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{})).object;
            if (event.get("event").?.object.get("user") != null) try times.append(a, @intCast(event.get("timestamp_ms").?.integer));
        }
        return times.items;
    }

    /// The one file in `folder` of v1's `id`. The arena's.
    fn only(v1: *V1Home, id: []const u8, folder: []const u8) ![]const u8 {
        const a = v1.arena.allocator();
        var dir = try v1.t.tmp.dir.openDir(io_mod.getIo(), try std.Io.Dir.path.join(a, &.{ ".spark", "sessions", id, folder }), .{ .iterate = true });
        defer dir.close(io_mod.getIo());
        var entries = dir.iterate();
        const first = (try entries.next(io_mod.getIo())) orelse return error.FileNotFound;
        if (try entries.next(io_mod.getIo())) |_| return error.TestUnexpectedResult;
        return a.dupe(u8, first.name);
    }

    /// The bytes of `{folder}/{name}` in v1's `id`. The arena's.
    fn file(v1: *V1Home, id: []const u8, folder: []const u8, name: []const u8) ![]const u8 {
        const a = v1.arena.allocator();
        return v1.t.tmp.dir.readFileAlloc(io_mod.getIo(), try std.Io.Dir.path.join(a, &.{ ".spark", "sessions", id, folder, name }), a, .limited(1 << 24));
    }

    /// Every file under `folder` of v1's `id`, by its path there, with its
    /// bytes. The arena's.
    fn tree(v1: *V1Home, id: []const u8, folder: []const u8) !std.array_hash_map.String([]const u8) {
        const io = io_mod.getIo();
        const a = v1.arena.allocator();
        var dir = try v1.t.tmp.dir.openDir(io, try std.Io.Dir.path.join(a, &.{ ".spark", "sessions", id, folder }), .{ .iterate = true });
        defer dir.close(io);
        var files: std.array_hash_map.String([]const u8) = .empty;
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| if (entry.kind == .file) {
            try files.put(a, try a.dupe(u8, entry.path), try dir.readFileAlloc(io, entry.path, a, .limited(1 << 24)));
        };
        return files;
    }

    /// `.spark/sessions/{id}/{rest}`, relative to the home. The arena's.
    fn sessionPath(v1: *V1Home, id: []const u8, rest: []const u8) ![]const u8 {
        return std.Io.Dir.path.join(v1.arena.allocator(), &.{ ".spark", "sessions", id, rest });
    }

    fn exists(t: *TestHome, id: []const u8) bool {
        var buffer: [64]u8 = undefined;
        const path = std.mem.print(&buffer, ".spark/sessions/{s}", .{id}) catch unreachable;
        _ = t.tmp.dir.statFile(io_mod.getIo(), path, .{}) catch return false;
        return true;
    }

    fn read(t: *TestHome, path: []const u8) ![]u8 {
        return t.tmp.dir.readFileAlloc(io_mod.getIo(), path, testing.allocator, .limited(1 << 20));
    }
};

fn openConverted(t: *TestHome, id: []const u8) !*Session {
    return Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
}

/// A v1 session's top-level files, to put back after its conversion as a
/// leftover a refused delete leaves.
const V1Copy = struct {
    names: std.ArrayList([]u8) = .empty,
    bytes: std.ArrayList([]u8) = .empty,

    fn take(t: *TestHome, id: []const u8) !V1Copy {
        const io = io_mod.getIo();
        var copy: V1Copy = .{};
        errdefer copy.deinit();
        var buffer: [64]u8 = undefined;
        var dir = try t.tmp.dir.openDir(io, try std.mem.print(&buffer, ".spark/sessions/{s}", .{id}), .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or std.mem.eql(u8, entry.name, "session.lock")) continue;
            try copy.names.append(testing.allocator, try testing.allocator.dupe(u8, entry.name));
            try copy.bytes.append(testing.allocator, try dir.readFileAlloc(io, entry.name, testing.allocator, .limited(1 << 20)));
        }
        return copy;
    }

    fn restore(copy: *const V1Copy, v1: *V1Home, id: []const u8) !void {
        for (copy.names.items, copy.bytes.items) |name, bytes| try v1.put(id, null, name, bytes);
    }

    fn deinit(copy: *V1Copy) void {
        for (copy.names.items, copy.bytes.items) |name, bytes| {
            testing.allocator.free(name);
            testing.allocator.free(bytes);
        }
        copy.names.deinit(testing.allocator);
        copy.bytes.deinit(testing.allocator);
    }
};

fn writeRecovery(v1: *V1Home, id: []const u8, seq: u64, user: []const u8, partial: []const u8) !void {
    const alloc = testing.allocator;
    const checkpoint: session_codec.RecoveryCheckpoint = .{
        .turn_id = 1,
        .user = .{ .text = @constCast(user) },
        .assistant_source = @constCast(partial),
        .cause = .response_interrupted,
        .action = .continuing_response,
        .authority = .{ .provider = .none, .model = @constCast("v1/model") },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 3,
        .consumed_provider_attempts = 1,
    };
    const encoded = try session_codec.encodeRecoveryCheckpoint(alloc, checkpoint);
    defer alloc.free(encoded);
    const bytes = try alloc.print("{{\"conversation_seq\":{d},\"checkpoint\":{s}}}\n", .{ seq, encoded });
    defer alloc.free(bytes);
    try v1.put(id, null, "recovery.json", bytes);
}

/// A legacy upgrade's pending authority fence for `id`, as v1 wrote it.
fn legacyFence(a: Allocator, id: []const u8) ![]const u8 {
    return std.mem.concat(a, u8, &.{ "{\"schema_version\":1,\"session_id\":\"", id, "\",\"operation_id\":\"11111111111111111111111111111111\",\"kind\":\"legacy_to_v3\",\"authority_id\":\"22222222222222222222222222222222\",\"prior\":{\"storage_format\":\"legacy_snapshot_v1\",\"primary_bytes\":1,\"primary_sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"},\"proposed\":{\"storage_format\":\"event_log_v1\",\"log_generation\":\"33333333333333333333333333333333\",\"through_seq\":1,\"through_event_id\":\"44444444444444444444444444444444\",\"through_event_log_bytes\":1}}" });
}

/// Makes `family`'s third member the second's own subagent, as spark made
/// them before a subagent lost the subagent tool.
fn nestThirdChild(v1: *V1Home, family: []const []const u8) !void {
    const a = v1.arena.allocator();
    var registry = try std.json.parseFromSliceLeaky(std.json.Value, a, try v1.file(family[0], "subagent", "children.json"), .{});
    const children = &registry.object.getPtr("children").?.array;
    for (children.items, 0..) |child, index| {
        if (std.mem.eql(u8, child.object.get("id").?.string, family[2])) {
            _ = children.orderedRemove(index);
            break;
        }
    } else return error.TestUnexpectedResult;
    try v1.put(family[0], "subagent", "children.json", try std.json.Stringify.valueAlloc(a, registry, .{}));
    try v1.put(family[2], "subagent", "owner.json", try a.print("{{\"schema_version\":1,\"parent_id\":\"{s}\"}}", .{family[1]}));
}

/// `t.store.problem` is exactly the reason spark gives when others can write
/// `id`'s v1 folder, or `entry` in it, naming the subagent when `child` is
/// set, with the command that makes the folder private (D61).
fn expectUnsafeProblem(t: *TestHome, child: []const u8, id: []const u8, entry: []const u8) !void {
    var buffer: [512]u8 = undefined;
    const expected = try std.mem.print(&buffer, "{s}{s}{s}others can write {s}{s}, so its files may not be the ones spark saved; make it private with `chmod -R go-w ~/.spark/sessions/{s}`", .{
        if (child.len > 0) "its subagent " else "",
        child,
        if (child.len > 0) ": " else "",
        entry,
        if (entry.len > 0) " in its folder" else "its folder",
        id,
    });
    try testing.expectEqualStrings(expected, t.store.problem.text());
}

/// A legacy relationship-index page naming `child` in its first slot.
fn relationshipPage(alloc: Allocator, child: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("FXRELP01");
    try w.writeInt(u32, 1, .little);
    try w.writeInt(u64, 0, .little);
    for (0..64) |slot| {
        try w.writeByte(if (slot == 0) 1 else 0);
        try w.writeInt(u64, std.math.maxInt(u64), .little);
        const name = if (slot == 0) child else "";
        try w.writeInt(u16, @intCast(name.len), .little);
        try w.writeAll(name);
    }
    return out.toOwnedSlice();
}
