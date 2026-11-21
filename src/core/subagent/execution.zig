const std = @import("std");
const managed_execution = @import("../execution/managed_execution.zig");
const runtime_deps = @import("../agent/runtime/deps.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const agents = @import("../agents/agents.zig");
const authority_mod = @import("authority.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const live_metrics = @import("live_metrics.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("../session/session.zig");
const session_adapter = @import("../session/session_adapter.zig");
const turn_capture = @import("../workspace/turn_capture.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const types = @import("../shared/types.zig");
const history_range = @import("../shared/history_range.zig");

const Allocator = std.mem.Allocator;

/// The MCP view a subagent may use now, taken from its freshly resolved live
/// authority, which this consumes. The subagent engine and child agents both
/// use it.
pub fn liveMcpViewFrom(
    alloc: Allocator,
    authority: *authority_mod.Snapshot,
) !tool_mcp_runtime.ResolvedLiveView {
    defer authority.deinit(alloc);
    const view = authority.mcp_view orelse return error.McpRuntimeUnavailable;
    authority.mcp_view = null;
    return .{
        .authority_generation = mcp_access.authorityGeneration(view),
        .action_authority_generation = authority.generation,
        .view = view,
    };
}

/// Decides one tool call against a subagent's live authority, resolved fresh
/// from `resolver` for `child_id`. The child engine and child agents both use
/// it, so a subagent is held to its admission's tools and integrations
/// whichever runs its turn: a name outside them, such as `subagent`, is
/// unavailable.
/// `user_mode` decides a turn no work of main's started (`Resolver.resolveForUser`).
pub fn resolveLiveToolActionFor(
    resolver: *authority_mod.Resolver,
    child_id: []const u8,
    user_mode: ?types.PermissionMode,
    alloc: Allocator,
    call: types.ToolCall,
    workspace_root: []const u8,
    target: []const u8,
    target_kind: tool_dispatch.PermissionTargetKind,
) !runtime_deps.ResolvedLiveToolAuthority {
    const snapshot = if (user_mode) |mode|
        try resolver.resolveForUser(alloc, child_id, mode)
    else
        try resolver.resolve(alloc, child_id);
    const decision = try authority_mod.decideToolAuthority(
        alloc,
        snapshot.view(),
        workspace_root,
        call.name,
        target,
        target_kind,
    );
    return .{
        .authority = .{
            .generation = snapshot.generation,
            .root_id = snapshot.root_id,
            .tools = snapshot.tools,
            .integrations = snapshot.integrations,
            .permission_mode = snapshot.permission_mode,
        },
        .decision = switch (decision) {
            .allow => .allow,
            .ask => .ask,
            .deny => .deny,
            .unavailable => .unavailable,
        },
    };
}

pub const TurnPreferences = struct {
    provider: @import("../config/model_provider.zig").ProviderId = .none,
    model: []const u8,
    effort: types.ReasoningEffort,
    /// The durable child preference wins when work resumes. Parent defaults are
    /// used only while creating a new child session.
    ultrafast_mode: bool = false,
};

pub const CaptureRequest = struct {
    child_id: []const u8,
    parent_id: []const u8,
    source_id: []const u8,
    preferences: TurnPreferences,
};

pub const RunOutcome = enum { completed, awaiting_approval, paused };

pub const ServiceError = error{
    OutOfMemory,
    AdmissionFailed,
    ProviderFailed,
    Cancelled,
};

pub const Services = struct {
    context: ?*anyopaque = null,
    /// Binds a run's turn to the child agent that will run it, setting its
    /// `hosted_worker` and `hosted_release`. Absent where the host runs turns
    /// itself. Blocks until bound.
    bind_fn: ?*const fn (
        ?*anyopaque,
        *TurnContext,
        *std.atomic.Value(bool),
    ) ServiceError!void = null,
    capture_fn: *const fn (
        ?*anyopaque,
        Allocator,
        CaptureRequest,
    ) ServiceError!domain.AdmissionSnapshot,
    run_fn: *const fn (
        ?*anyopaque,
        *TurnContext,
        domain.QueuedMessage,
        domain.AdmissionSnapshot,
        *std.atomic.Value(bool),
    ) ServiceError!RunOutcome,

    /// Binds `turn` to its child agent's worker, where the host has one.
    pub fn bind(self: Services, turn: *TurnContext, cancel: *std.atomic.Value(bool)) ServiceError!void {
        const bind_fn = self.bind_fn orelse return;
        return bind_fn(self.context, turn, cancel);
    }

    pub fn capture(
        self: Services,
        alloc: Allocator,
        request: CaptureRequest,
    ) ServiceError!domain.AdmissionSnapshot {
        return self.capture_fn(self.context, alloc, request);
    }

    pub fn run(
        self: Services,
        turn: *TurnContext,
        message: domain.QueuedMessage,
        admission: domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) ServiceError!RunOutcome {
        return self.run_fn(self.context, turn, message, admission, cancel);
    }
};

pub const CommitError = error{
    OutOfMemory,
    InvalidWorkId,
    TurnAlreadyCommitted,
    SessionCommitFailed,
};

/// Counts the slot-thread turns that hold a child agent's worker, so the
/// main loop frees the agent only once none is left, and wakes the main loop
/// when the last one lets go.
pub const HostedRelease = struct {
    count: std.atomic.Value(u32) = .init(0),
    released: std.Io.Event = .unset,

    pub fn hold(self: *HostedRelease) void {
        _ = self.count.fetchAdd(1, .acq_rel);
    }

    /// Lets go of one hold. Wakes the waiter before the count drops: once it
    /// reads zero it may free this, so nothing touches it afterwards.
    pub fn release(self: *HostedRelease) void {
        self.released.set(io_mod.getIo());
        _ = self.count.fetchSub(1, .release);
    }

    pub fn held(self: *const HostedRelease) bool {
        return self.count.load(.acquire) > 0;
    }

    /// Blocks until no hold is left, or `timeout_ms` passes. False on the
    /// timeout, when a slot thread still holds the agent.
    pub fn waitReleased(self: *HostedRelease, timeout_ms: i64) bool {
        const deadline = io_mod.milliTimestamp() + timeout_ms;
        while (true) {
            if (!self.held()) return true;
            if (io_mod.milliTimestamp() >= deadline) return false;
            self.released.reset();
            // A release between the check and the reset is not lost.
            if (!self.held()) return true;
            self.released.waitTimeout(io_mod.getIo(), .{ .duration = .{
                .raw = .fromMilliseconds(50),
                .clock = .awake,
            } }) catch {};
        }
    }
};

pub const TurnContext = struct {
    alloc: Allocator,
    runtime: session.SessionRuntime,
    worker: worker_runtime.WorkerRuntime = .{},
    /// In the interactive app, the child agent's own worker runs the turn, so
    /// approvals, cancel, and steering go to it instead of `worker`.
    hosted_worker: ?*worker_runtime.WorkerRuntime = null,
    /// Counts this turn as using its child agent until `deinit`, so the agent
    /// is not freed while a slot thread still holds its worker.
    hosted_release: ?*HostedRelease = null,
    managed_executions: managed_execution.Runtime,
    /// The child session the turn writes, through the adapter. Null
    /// for a hosted run, whose child's own agent saves its turns.
    child: ?*session_adapter.Session,
    live_authority: ?*authority_mod.Resolver = null,
    child_id: ?[]const u8 = null,
    /// The name the parent gave the child, such as `reviewer`, or null for a
    /// one-off. Borrowed for the turn.
    child_name: ?[]const u8 = null,
    /// What the child is for (`Child.purpose`), or null when it has none.
    /// Borrowed for the turn.
    child_purpose: ?[]const u8 = null,
    active_work_id: ?[]const u8 = null,
    phase_context: ?*anyopaque = null,
    phase_fn: ?*const fn (
        *anyopaque,
        []const u8,
        []const u8,
        child_state.Phase,
    ) anyerror!void = null,
    live_metrics: ?*live_metrics.LiveMetrics = null,
    /// This child's event queue, which only the main loop drains.
    /// Borrowed from the subagent host for the turn.
    failure_diagnostic: ?types.ModelFailureDiagnostic = null,
    committed: bool = false,
    /// Where the child's workspace captures go while
    /// `experimental.workspace_capture` is on; null when it is off. A hosted
    /// run's own agent captures instead (D98).
    workspace_capture: ?turn_capture.Target = null,
    /// The run's cancel flag, which ends the child's capture in flight;
    /// borrowed for the turn.
    capture_cancel: ?*const std.atomic.Value(bool) = null,
    turn_capture: turn_capture.TurnCapture = .{},
    /// Orders capture saves with each other; the child's commits run on the
    /// turn's own thread.
    capture_lock: std.Io.Mutex = .init,

    /// A turn over a child, restored from its log.
    pub fn init(
        alloc: Allocator,
        child: *session_adapter.Session,
        max_history_turns: usize,
    ) !TurnContext {
        var restored = try child.restore(alloc);
        defer restored.deinit(alloc);
        var runtime = session.SessionRuntime{ .max_history_turns = max_history_turns };
        errdefer runtime.deinit(alloc);
        try runtime.restore(
            alloc,
            restored.language,
            restored.history,
        );
        return .{
            .alloc = alloc,
            .runtime = runtime,
            .managed_executions = managed_execution.Runtime.init(alloc),
            .child = child,
        };
    }

    /// A run whose child's own agent holds the session: the host keeps
    /// the run's admission, approvals, phases, and result, and the agent saves
    /// its turns itself, so nothing here touches the session.
    pub fn initHosted(alloc: Allocator, max_history_turns: usize) TurnContext {
        return .{
            .alloc = alloc,
            .runtime = .{ .max_history_turns = max_history_turns },
            .managed_executions = managed_execution.Runtime.init(alloc),
            .child = null,
        };
    }

    fn workspaceCaptureContext(self: *TurnContext) ?turn_capture.Context {
        if (comptime !turn_capture.supported) return null;
        const target = self.workspace_capture orelse return null;
        return target.context(self.child orelse return null, self.capture_cancel);
    }

    /// Whether the child's turns capture its workspace.
    pub fn capturesWorkspace(self: *TurnContext) bool {
        return self.workspaceCaptureContext() != null;
    }

    /// The child's turn starts: its start capture (D98).
    pub fn startWorkspaceCapture(self: *TurnContext, fresh: bool, step: runtime_deps.AgentRuntimeDeps.WorkspaceCaptureStep) void {
        if (comptime !turn_capture.supported) return;
        const context = self.workspaceCaptureContext() orelse return;
        switch (step) {
            .begin => self.turn_capture.begin(context, fresh),
            .capture => self.turn_capture.start(context, &self.capture_lock),
        }
    }

    /// A child's tool is about to act in `dir` (D98).
    pub fn reachWorkspace(self: *TurnContext, dir: []const u8, tool_name: []const u8) void {
        if (comptime !turn_capture.supported) return;
        const context = self.workspaceCaptureContext() orelse return;
        self.turn_capture.reach(context, dir, tool_name, &self.capture_lock);
    }

    /// True when the child's own agent holds the session.
    pub fn isHosted(self: *const TurnContext) bool {
        return self.child == null;
    }

    pub fn deinit(self: *TurnContext) void {
        if (self.hosted_release) |hosted| hosted.release();
        self.managed_executions.deinit();
        self.worker.deinit(self.alloc);
        self.runtime.deinit(self.alloc);
        self.turn_capture.deinit();
        self.* = undefined;
    }

    pub fn setFailureDiagnostic(
        self: *TurnContext,
        code: []const u8,
        detail: []const u8,
    ) void {
        if (self.failure_diagnostic != null) return;
        self.failure_diagnostic = failureDiagnosticValue(code, detail);
    }

    pub fn failureDiagnostic(self: *const TurnContext) ?types.ModelFailureDiagnostic {
        return self.failure_diagnostic;
    }

    pub fn sessionRuntime(self: *TurnContext) *session.SessionRuntime {
        return &self.runtime;
    }

    /// Opens the child's turn on disk as its work starts, so a body its
    /// tools store is a blob of a session on disk (D44).
    pub fn beginTurn(self: *TurnContext) !void {
        // A hosted run's turns are opened by the child's own agent.
        const child = self.child orelse return;
        try child.beginTurn();
    }

    pub fn childCapability(
        self: *TurnContext,
    ) !*session_child_store.SessionChildCapability {
        const child = self.child orelse return error.ChildCapabilityUnavailable;
        return child.childCapability();
    }

    pub fn workerRuntime(self: *TurnContext) *worker_runtime.WorkerRuntime {
        return self.hosted_worker orelse &self.worker;
    }

    pub fn managedExecutionRuntime(self: *TurnContext) *managed_execution.Runtime {
        return &self.managed_executions;
    }

    pub fn appendLiveText(_: *TurnContext, _: []const u8) void {}

    pub fn appendLiveEvent(
        _: *TurnContext,
        _: worker_runtime.WorkerEvent,
    ) void {}

    pub fn resolveLiveAuthority(
        self: *TurnContext,
        alloc: Allocator,
    ) authority_mod.Error!authority_mod.Snapshot {
        const resolver = self.live_authority orelse
            return error.HostAuthorityUnavailable;
        return resolver.resolve(
            alloc,
            self.child_id orelse return error.ChildNotAttached,
        );
    }

    pub fn liveToolAuthorityProvider(
        self: *TurnContext,
    ) runtime_deps.LiveToolAuthorityProvider {
        return .{ .context = self, .resolve_fn = resolveLiveToolAction };
    }

    pub fn toolActivityRecorder(self: *TurnContext) runtime_deps.ToolActivityRecorder {
        return .{ .context = self, .record_fn = recordToolActivity };
    }

    fn resolveLiveToolAction(
        raw: *anyopaque,
        alloc: Allocator,
        call: types.ToolCall,
        workspace_root: []const u8,
        target: []const u8,
        target_kind: tool_dispatch.PermissionTargetKind,
    ) !runtime_deps.ResolvedLiveToolAuthority {
        const self: *TurnContext = @ptrCast(@alignCast(raw));
        const resolver = self.live_authority orelse return error.HostAuthorityUnavailable;
        return resolveLiveToolActionFor(
            resolver,
            self.child_id orelse return error.ChildNotAttached,
            null,
            alloc,
            call,
            workspace_root,
            target,
            target_kind,
        );
    }

    fn recordToolActivity(
        _: *anyopaque,
        _: []const u8,
        _: []const u8,
        _: runtime_deps.ToolActivityPhase,
    ) !void {}

    pub fn commit(self: *TurnContext, work_id: []const u8, turn: types.HistoryTurn) CommitError!void {
        // The child's own agent saves a hosted run's turns.
        if (self.child == null) return error.SessionCommitFailed;
        if (self.committed) return error.TurnAlreadyCommitted;
        try self.appendCommittedHistory(work_id, turn);
        self.committed = true;
    }

    fn appendCommittedHistory(self: *TurnContext, work_id: []const u8, turn: types.HistoryTurn) CommitError!void {
        var committed_turn = session.dupeHistoryTurn(self.alloc, turn) catch
            return error.OutOfMemory;
        defer session.freeHistoryTurn(self.alloc, committed_turn);
        session.copyWorkIdToTurn(self.alloc, &committed_turn, work_id) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidWorkId, error.ConflictingWorkId => error.InvalidWorkId,
            };
        };
        var prepared = self.runtime.prepareHistoryEntry(self.alloc, committed_turn) catch
            return error.OutOfMemory;
        var prepared_owned = true;
        defer if (prepared_owned) session.freeHistoryTurn(self.alloc, prepared);
        // The work id rides on the turn.
        const child = self.child orelse return error.SessionCommitFailed;
        // The repository as the child's turn left it, saved with the commit
        // that uses the turn's token.
        if (comptime turn_capture.supported) {
            if (self.workspaceCaptureContext()) |context| _ = self.turn_capture.end(context, &self.capture_lock);
        }
        child.prepareTurn(&prepared) catch |err| return commitFailed(child, work_id, "prepare", err);
        const capture_token = self.turn_capture.token();
        const committed = if (capture_token) |token|
            child.commitTurnWithCaptures(prepared, self.runtime.languageSnapshot(), token)
        else
            child.commitTurn(prepared, self.runtime.languageSnapshot());
        committed catch |err| return commitFailed(child, work_id, "commit", err);
        self.turn_capture.committed(capture_token);
        self.runtime.commitPreparedHistoryEntry(self.alloc, prepared);
        prepared_owned = false;
    }

    pub fn commitContextCompaction(
        self: *TurnContext,
        summary: types.CompactedSummaryHistoryTurn,
        active_prefix: ?types.AssistantHistoryTurn,
        retained_from: ?types.ContextHistoryCut,
    ) !void {
        // The child's own agent compacts a hosted run's session.
        const child = self.child orelse return error.SessionCommitFailed;
        var prefix: ?types.HistoryTurn = if (active_prefix) |value|
            try session.dupeHistoryTurn(self.alloc, .{ .assistant = value })
        else
            null;
        defer if (prefix) |value| session.freeHistoryTurn(self.alloc, value);
        if (prefix) |*value| {
            try session.copyWorkIdToTurn(self.alloc, value, self.active_work_id orelse return error.InvalidWorkId);
        }
        const prepared = try session.prepareCompactedHistory(self.alloc, self.runtime.agent.history.items, summary, retained_from orelse .{ .turns = history_range.rawHistoryTurnCount(self.runtime.agent.history.items) });
        errdefer types.freeHistoryTurnSlice(self.alloc, prepared);
        // The active prefix reaches the log with the turn's commit.
        try child.commitCompaction(summary, prefix != null, retained_from);
        self.runtime.commitCompactedHistory(self.alloc, prepared);
    }
};

/// A v2 child's turn that did not reach its log is dropped; the trace names
/// the cause the commit error hides.
fn commitFailed(child: *session_adapter.Session, work_id: []const u8, stage: []const u8, err: anyerror) CommitError {
    debug_trace.logf("subagent", "child turn dropped child_id={s} work_id={s} stage={s} err={s}", .{ child.id(), work_id, stage, @errorName(err) });
    return if (err == error.OutOfMemory) error.OutOfMemory else error.SessionCommitFailed;
}

pub fn failureDiagnosticValue(code: []const u8, detail: []const u8) types.ModelFailureDiagnostic {
    const max_bytes = types.ModelFailureDiagnostic.max_bytes;
    const prefix = text_utils.utf8PrefixByBytes(code, max_bytes);
    const safe_detail = if (text_utils.isTerminalSafe(detail))
        text_utils.utf8PrefixByBytes(detail, max_bytes -| prefix.len -| 2)
    else
        "";
    if (safe_detail.len == 0) return types.ModelFailureDiagnostic.init(prefix);
    var buffer: [max_bytes]u8 = undefined;
    const text = buffer[0 .. prefix.len + 2 + safe_detail.len];
    @memcpy(text[0..prefix.len], prefix);
    @memcpy(text[prefix.len..][0..2], ": ");
    @memcpy(text[prefix.len + 2 ..], safe_detail);
    return types.ModelFailureDiagnostic.init(text);
}
