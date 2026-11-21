const std = @import("std");
const testing_allocator = @import("../core/shared/testing_allocator.zig");
const managed_execution = @import("../core/execution/managed_execution.zig");
const acp_runner = @import("../core/cli/acp_runner.zig");
const config_runtime = @import("../core/config/config_runtime.zig");
const io_mod = @import("../core/shared/io.zig");
const host_target = @import("../core/hosts/target.zig");
const jsonrpc = @import("jsonrpc.zig");
const acp_types = @import("types.zig");
const sessions = @import("sessions.zig");
const prompt_handler = @import("prompt.zig");
const prompt_test_controls = @import("prompt_test_controls.zig");
const app_lifecycle = @import("../core/app/app_lifecycle.zig");
const app_runtime_setup = @import("../core/app/app_runtime_setup.zig");
const compactor = @import("../core/compactor/compactor.zig");
const builtin_skills = @import("../builtins/skills.zig");
const builtin_tools = @import("../builtins/tools.zig");
const credentials = @import("../core/auth/credentials.zig");
const secret = @import("../core/auth/secret.zig");
const auth_runtime = @import("../core/auth/auth_runtime.zig");
const oauth_transport = @import("../core/auth/oauth_transport.zig");
const model_provider = @import("../core/config/model_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const hooks = @import("../core/hooks/hooks.zig");
const mcp_host = @import("../core/mcp_host/host.zig");
const mode_registry = @import("../core/modes/mode_registry.zig");
const skill_runtime = @import("../core/skills/skill_runtime.zig");
const session_codec = @import("../core/session/session_codec.zig");
const session_log = @import("../core/session/session_log.zig");
const session_store = @import("../core/session/session_store.zig");
const session_adapter = @import("../core/session/session_adapter.zig");
const turn_capture = @import("../core/workspace/turn_capture.zig");
const session_runtime = @import("../core/session/session.zig");
const session_title_generation = @import("../core/session/session_title_generation.zig");
const worker_runtime = @import("../core/agent/worker_runtime.zig");
const terminal_client_runtime = @import("../core/terminal/client.zig");
const subagent_tool_host = @import("../core/subagent/tool_host.zig");
const subagent_reports = @import("../core/subagent/reports.zig");
const subagent_child_state = @import("../core/subagent/child_state.zig");
const subagent_authority = @import("../core/subagent/authority.zig");
const types = @import("../core/shared/types.zig");
const context_contract = @import("../core/workspace/context_contract.zig");
const workspace_access = @import("../core/workspace/workspace_access.zig");
const web_fetch_runtime = @import("../core/tooling/web_fetch_runtime.zig");
const web_search_runtime = @import("../core/tooling/web_search_runtime.zig");
const elicitation = @import("../core/mcp/elicitation.zig");
const tool_mcp_runtime = @import("../core/tooling/tool_mcp_runtime.zig");
const permissions = @import("../core/permissions/permissions.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const agent_checkpoint = @import("../core/agent/runtime/checkpoint.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const steering = @import("steering.zig");
const tool_call_identities = @import("tool_call_identities.zig");

const Allocator = std.mem.Allocator;
const ErrorCode = jsonrpc.ErrorCode;
const writeJsonStr = jsonrpc.writeJsonStr;
const legacy_url_completion_timeout_ms: i64 = 10 * 60 * 1000;

const AcpMethod = enum {
    request_cancel,
    initialize,
    session_cancel,
    session_new,
    session_load,
    session_resume,
    session_close,
    session_list,
    session_remove,
    /// `_spark/session/rename`: a title the user chose for the loaded session.
    session_rename,
    session_prompt,
    session_set_config_option,
    session_set_mode,
    mcp_message,
    unknown,

    fn parse(method: []const u8) AcpMethod {
        if (std.mem.eql(u8, method, "$/cancel_request")) return .request_cancel;
        if (std.mem.eql(u8, method, "initialize")) return .initialize;
        if (std.mem.eql(u8, method, "session/cancel")) return .session_cancel;
        if (std.mem.eql(u8, method, "session/new")) return .session_new;
        if (std.mem.eql(u8, method, "session/load")) return .session_load;
        if (std.mem.eql(u8, method, "session/resume")) return .session_resume;
        if (std.mem.eql(u8, method, "session/close")) return .session_close;
        if (std.mem.eql(u8, method, "session/list")) return .session_list;
        if (std.mem.eql(u8, method, "session/remove")) return .session_remove;
        if (std.mem.eql(u8, method, "_spark/session/rename")) return .session_rename;
        if (std.mem.eql(u8, method, "session/prompt")) return .session_prompt;
        if (std.mem.eql(u8, method, "session/set_config_option")) return .session_set_config_option;
        if (std.mem.eql(u8, method, "session/set_mode")) return .session_set_mode;
        if (std.mem.eql(u8, method, "mcp/message")) return .mcp_message;
        return .unknown;
    }

    fn waitsForActivePrompt(self: AcpMethod) bool {
        return switch (self) {
            .initialize,
            .request_cancel,
            .session_cancel,
            .session_set_mode,
            .session_new,
            .session_load,
            .session_resume,
            .session_close,
            // a title can change while a turn runs: Session.rename takes the session's lock
            .session_rename,
            => false,
            .session_list,
            .session_remove,
            .session_prompt,
            .session_set_config_option,
            .mcp_message,
            .unknown,
            => true,
        };
    }
};

const SessionTargetDecision = enum {
    exact,
    missing,
    inactive,
    mismatch,
};

fn decideSessionTarget(active_session_id: ?[]const u8, supplied: ?std.json.Value) SessionTargetDecision {
    const active = active_session_id orelse return .inactive;
    const value = supplied orelse return .missing;
    if (value != .string or value.string.len == 0) return .missing;
    return if (std.mem.eql(u8, active, value.string)) .exact else .mismatch;
}

pub const Config = acp_runner.Config;

pub const OutboundKind = enum {
    permission,
    elicitation,
    /// MCP over ACP request to a client-served MCP server.
    mcp_message,
};

pub const OutboundResponse = struct {
    result_json: ?[]u8 = null,
    error_json: ?[]u8 = null,
    cancelled: bool = false,

    pub fn deinit(self: *OutboundResponse, alloc: Allocator) void {
        if (self.result_json) |value| alloc.free(value);
        if (self.error_json) |value| alloc.free(value);
        self.* = undefined;
    }
};

const PendingOutbound = struct {
    kind: OutboundKind,
    response: ?OutboundResponse = null,
};

const max_pending_outbound = 32;

const PendingLegacyUrl = struct {
    server_name: []u8,
    source_id: []u8,
    acp_id: []u8,
    session_id: []u8,
    tool_call_id: []u8,
    binding: elicitation.Binding,
    accepted: bool = false,
    completed: bool = false,

    fn deinit(self: *PendingLegacyUrl, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.source_id);
        alloc.free(self.acp_id);
        alloc.free(self.session_id);
        alloc.free(self.tool_call_id);
        self.* = undefined;
    }
};

pub const ActiveSessionState = struct {
    observer_hooks: ?@import("observer_hooks.zig").Config = null,
    session_id: []u8,
    /// The saved session.
    v2: ?*session_adapter.Session = null,
    /// The home of the session store while workspace captures are on, set
    /// as each prompt starts; null when they are off (D98).
    capture_home: ?[]const u8 = null,
    /// The current turn's workspace captures.
    turn_capture: turn_capture.TurnCapture = .{},
    session_write_mutex: std.Io.Mutex = .init,
    /// Input plus output tokens of the latest main-model completion, the
    /// context `usage_update` reports; 0 until a completion reports both.
    context_used: std.atomic.Value(usize) = .init(0),
    model: []u8,
    provider: model_provider.ProviderId = .none,
    mode: []const u8,
    workspace_root: []const u8,
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    agent_step_limit: usize,
    max_tool_result_bytes: usize,
    fast_mode: bool,
    ultrafast_mode: bool = false,
    effort: types.ReasoningEffort,
    first_call_tool_choice: types.ToolChoice,
    permission_mode: types.PermissionMode,
    session_rt: session_runtime.SessionRuntime,
    title_task: ?*session_title_generation.Task = null,
    /// The session's MCP servers; null when it has none.
    mcp_host: ?*mcp_host.Host = null,
    /// Session-scoped client system prompt, appended after spark's instructions.
    /// Owned by the server allocator; empty when the client supplied none.
    client_system_prompt: []u8 = &.{},
    /// MCP identities shown for earlier tool calls, for session/load replay.
    tool_identities: tool_call_identities.Record = .{},
    cancel_flag: std.atomic.Value(bool),
    /// Set with `cancel_flag` only by a cancel that stops the turn: the
    /// client's `session/cancel`, its closed steering, or a host tool it
    /// cancelled. A steer that cuts the reply short sets `cancel_flag` alone,
    /// so the turn's workspace captures, which watch this, keep running (D98).
    /// Cleared as each prompt starts.
    turn_cancel: std.atomic.Value(bool) = .init(false),
    pending_prompt_id: ?jsonrpc.RequestId,
    steering: steering.Runtime = .{},
};

const ActivePrompt = struct {
    state: *ServerState,
    alloc: Allocator,
    msg: jsonrpc.Message,
    /// Mode and permission policy captured when the prompt was dispatched.
    /// Mid-turn mode changes apply to the next prompt, never the running one.
    mode: []const u8,
    permission_mode: types.PermissionMode,
    /// The usage of every turn the prompt ran, its own and each report turn
    /// after it. The response reports it. Written by the prompt's own thread.
    usage: types.Usage = .{},
    thread: std.Thread = undefined,
    reapable: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const ServerState = struct {
    configured_providers: @import("../core/config/configured_provider.zig").Registry = .{},
    alloc: Allocator,
    cfg: Config,
    writer: jsonrpc.Writer,
    initialized: bool = false,
    /// Selects spark's terminal or embedded base prompt for this connection.
    terminal_ui: bool = true,
    client_fs_read: bool = false,
    client_fs_write: bool = false,
    client_terminal: bool = false,
    /// The client shows ACP v1 Session Notices (`session.notices`).
    client_notices: bool = false,
    client_elicitation: elicitation.Capabilities = .{},
    workspace_root: []u8 = &.{},
    workspace_access: workspace_access.WorkspaceAccess = .{},
    api_key: []u8 = &.{},
    credential_source: ?types.CredentialSource = null,
    selected_model: []u8 = &.{},
    provider: model_provider.ProviderId = .none,
    configured_model: []u8 = &.{},
    process_model_override: bool = false,
    process_provider_override: bool = false,
    permission_mode: types.PermissionMode = .yolo,
    agent_step_limit: usize = 0,
    max_tool_result_bytes: usize = 64 * 1024,
    auto_compact_percent: u8 = compactor.default_percent,
    context_limits: config_runtime.context_limits.Values = .{},
    /// The built-in tools offered through toolbox, fixed for the server.
    toolbox_behind: config_runtime.tool_placement.Behind = config_runtime.tool_placement.behindToolbox(.{}, &.{}),
    fast_mode: bool = false,
    ultrafast_mode: bool = false,
    configured_ultrafast_mode: bool = false,
    process_ultrafast_override: ?bool = null,
    effort: types.ReasoningEffort = .auto,
    first_call_tool_choice: types.ToolChoice = .auto,
    context_enabled: bool = true,
    session_titles: bool = true,
    cache_warming: bool = true,
    /// `experimental.workspace_capture`, from startup.
    workspace_capture: bool = false,
    active_session: ?ActiveSessionState = null,
    active_prompt: ?*ActivePrompt = null,
    subagent_authority_mutex: std.Io.Mutex = .init,
    skills: skill_runtime.Runtime = .{},
    context_snapshot: context_contract.GatheredContextSnapshot = .{},
    worker: worker_runtime.WorkerRuntime = .{},
    /// What each report queued in `worker` answers, oldest first, so the
    /// prompt can show it on the subagent call that sent the work (decision
    /// 26). Guarded by `report_mutex`, which also covers posting the report,
    /// so both stay in the same order.
    report_calls: std.ArrayList(ReportCall) = .empty,
    report_mutex: std.Io.Mutex = .init,
    terminal_client: terminal_client_runtime.Runtime = .{},
    managed_executions: managed_execution.Runtime = managed_execution.Runtime.init(std.heap.c_allocator),
    /// A v2 session's children (D22), borrowed by `subagent_host`.
    subagent_v2_children: ?*subagent_child_state.V2Children = null,
    subagent_host: ?*subagent_tool_host.Runtime = null,
    /// Open for the whole connection.
    sessions_v2: ?session_adapter.Store = null,
    capability_resolver: gateway_provider.CapabilityResolver = .{},
    terminate_connection: bool = false,
    web_fetch_runtime: web_fetch_runtime.Runtime = web_fetch_runtime.Runtime.init(.{}),
    web_search_runtime: web_search_runtime.Runtime = web_search_runtime.Runtime.init(.{}),
    lifecycle_runtime: hooks.Runtime = hooks.Runtime.init(std.heap.c_allocator),
    lifecycle_view: hooks.RuntimeView = hooks.RuntimeView.empty(),
    outbound_mutex: std.Io.Mutex = .init,
    outbound_cond: std.Io.Condition = .init,
    next_outbound_request_id: u64 = 1,
    pending_outbound: std.AutoHashMapUnmanaged(u64, PendingOutbound) = .empty,
    legacy_url_mutex: std.Io.Mutex = .init,
    pending_legacy_urls: std.ArrayList(PendingLegacyUrl) = .empty,

    pub fn deinit(self: *ServerState) void {
        // Terminals end with this process. Ending them first also releases
        // an active prompt waiting on one.
        self.terminal_client.closeOwnedTerminals();
        reapActivePrompt(self, true);
        // A subagent inside a command uses `managed_executions` until it stops. Ended first, the runtime
        // leaves that subagent waiting for ever on the ended runtime's mutex while `closeActiveSession` waits
        // for it, or fails the assert that no operation is in flight. So the subagents stop first, as in
        // `spark ask`. A prompt that is still running, or a `session/cancel` that left one at work, can leave a
        // subagent inside a command here.
        disableSubagentHost(self);
        self.managed_executions.deinit();
        self.terminal_client.deinit();
        closeActiveSession(self) catch |err| {
            debug_trace.logf(
                "session",
                "failed to flush ACP session usage during shutdown err={s}",
                .{@errorName(err)},
            );
        };
        // A host `session/load` replaced may still be stopping its servers;
        // they end before this process does.
        mcp_host.waitRetired();
        // Retention's maintenance, if one runs, ends with the server.
        if (comptime turn_capture.supported) turn_capture.finishMaintenance();
        if (self.sessions_v2) |*store| store.deinit(self.alloc);
        self.workspace_access.deinit(self.alloc);
        if (self.workspace_root.len > 0) self.alloc.free(self.workspace_root);
        if (self.api_key.len > 0) secret.zeroAndFree(self.alloc, self.api_key);
        if (self.selected_model.len > 0) self.alloc.free(self.selected_model);
        if (self.configured_model.len > 0) self.alloc.free(self.configured_model);
        self.skills.deinit(self.alloc);
        self.context_snapshot.deinit(self.alloc);
        self.worker.deinit(std.heap.c_allocator);
        for (self.report_calls.items) |*call| call.deinit(std.heap.c_allocator);
        self.report_calls.deinit(std.heap.c_allocator);
        self.web_fetch_runtime.deinit(self.alloc);
        self.web_search_runtime.deinit();
        self.lifecycle_runtime.deinit();
        self.capability_resolver.deinit(self.alloc);
        var pending = self.pending_outbound.valueIterator();
        while (pending.next()) |entry| {
            if (entry.response) |*response| response.deinit(self.alloc);
        }
        self.pending_outbound.deinit(self.alloc);
        clearPendingLegacyUrls(self);
        self.pending_legacy_urls.deinit(self.alloc);
        self.configured_providers.deinit(self.alloc);
    }
};

/// A tokenless credential that marks a route as authorized by the host.
fn hostManagedCredential() credentials.Credential {
    return .{ .token = &.{}, .source = .host_managed };
}

/// True when requests on a configured provider's route carry no credential from
/// this server because the host authorizes them at its fetch edge.
fn hostManagesRoute(cfg: Config, provider: model_provider.ProviderId) bool {
    return provider == .configured and cfg.provider_auth_mode == .host_managed;
}

/// Stages the credential `provider`'s requests carry without changing any
/// in-flight credential storage. The caller owns a non-null credential; null
/// means the host authorizes every request of this process.
pub fn prepareCredentialForProvider(state: *ServerState, provider: model_provider.ProviderId) !?credentials.Credential {
    if (state.cfg.auth_mode == .host_managed) return null;
    if (hostManagesRoute(state.cfg, provider)) return hostManagedCredential();
    const credential = (try auth_runtime.prepareCredential(state.alloc, provider)) orelse return error.ProviderCredentialUnavailable;
    return credential;
}

/// Ensures the process and active ACP session use the credential `provider`
/// needs. Returns false when that provider has no credential spark can read.
pub fn selectCredentialForProvider(
    state: *ServerState,
    provider: model_provider.ProviderId,
) !bool {
    if (state.cfg.auth_mode == .host_managed) {
        state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        defer state.subagent_authority_mutex.unlock(io_mod.getIo());
        state.credential_source = .host_managed;
        if (state.active_session) |*active| {
            active.credential_source = .host_managed;
            active.api_key = &.{};
        }
        return true;
    }
    var prepared = prepareCredentialForProvider(state, provider) catch |err| {
        if (err == error.ProviderCredentialUnavailable) return false;
        return err;
    };
    defer if (prepared) |*credential| credential.deinit(state.alloc);
    if (prepared) |*credential| {
        state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        defer state.subagent_authority_mutex.unlock(io_mod.getIo());
        adoptServerCredential(state, credential);
    }
    return true;
}

/// Transfers credential storage after the caller has stopped its prior borrowers.
/// Makes `credential` the server's and the active session's. It frees the
/// credential it replaces, which a subagent's turn reads from its own copy
/// (`ModelRoute` in prompt.zig); call it with `subagent_authority_mutex` held.
pub fn adoptServerCredential(state: *ServerState, credential: *credentials.Credential) void {
    const previous_key = state.api_key;
    if (state.active_session) |*active| active.api_key = &.{};

    state.api_key = credential.token;
    credential.token = &.{};
    state.credential_source = credential.source;
    if (state.active_session) |*active| {
        active.api_key = state.api_key;
        active.credential_source = state.credential_source;
    }
    if (previous_key.len > 0) secret.zeroAndFree(state.alloc, previous_key);
}

test "ACP provider routes are host-managed only for configured providers under host policy" {
    const alloc = std.testing.allocator;
    var state: ServerState = undefined;
    state.alloc = alloc;
    state.subagent_authority_mutex = .init;
    state.cfg.auth_mode = .local;
    state.cfg.provider_auth_mode = .host_managed;
    state.active_session = null;
    state.api_key = &.{};

    // The host adds the configured provider's key, if any, so the process
    // holds no token of its own.
    const configured = model_provider.parse("local").?;
    var custom = (try prepareCredentialForProvider(&state, configured)).?;
    defer custom.deinit(alloc);
    try std.testing.expectEqual(types.CredentialSource.host_managed, custom.source);
    try std.testing.expectEqual(@as(usize, 0), custom.token.len);
    adoptServerCredential(&state, &custom);
    try std.testing.expectEqual(types.CredentialSource.host_managed, state.credential_source.?);

    // A process with no chosen provider has no route, even under host policy.
    try std.testing.expectError(error.ProviderCredentialUnavailable, prepareCredentialForProvider(&state, .none));

    // Without the policy a configured provider needs its own credential.
    state.cfg.provider_auth_mode = .local;
    try std.testing.expect(!hostManagesRoute(state.cfg, configured));
}

pub fn streamProviderFor(
    state: *const ServerState,
    provider: model_provider.ProviderId,
) @import("../core/agent/stream_provider.zig").Provider {
    return state.cfg.provider_set.select(provider).agent_stream_or_unavailable();
}

pub fn catalogProviderFor(
    state: *const ServerState,
    provider: model_provider.ProviderId,
) ?@import("../core/gateway/model_catalog.zig").Provider {
    return state.cfg.provider_set.select(provider).model_catalog;
}

/// The session store; null when it could not open (no `HOME`).
pub fn sessionsStore(state: *ServerState) ?*session_adapter.Store {
    return if (state.sessions_v2) |*store| store else null;
}

pub fn releaseActiveSession(state: *ServerState) !void {
    clearPendingLegacyUrls(state);
    if (state.active_session == null) return;
    disableSubagentHost(state);
    destroyActiveSession(state);
}

fn closeActiveSession(state: *ServerState) !void {
    if (state.active_session == null) return;
    disableSubagentHost(state);
    destroyActiveSession(state);
}

/// The client leaves the active session for another, or closes it: its
/// subagents stop as cancelled and owe no report, and nothing they posted for
/// it stays for the session that follows (D41, D97; the app does the same in
/// `stopSet`). The tree closes first, so no work the stop ends owes a report,
/// and the host is joined before the queue is dropped, so nothing posts after
/// it. A quit leaves reports owed and loses no queue it could keep, so it calls
/// neither this nor `stopSubagentsForReopen`. A reload of the same session
/// under the same `cwd` keeps what the session holds and opens nothing again,
/// so it calls neither either. Call this before `releaseActiveSession` or
/// `closeActiveSession`.
pub fn stopSubagentsForSwitch(state: *ServerState) void {
    const active = if (state.active_session) |*session| session else return;
    if (state.subagent_host) |host| host.closeTree();
    disableSubagentHost(state);
    dropQueuedMail(state, active.session_id, .all, "session_switch");
}

/// The client loads the active session again under another `cwd`: the session
/// is released and opened again from its log. It is the same session, so its
/// subagents stop as a quit stops them, and what they owe stays owed. The
/// open log hands each owed report out once, as a restart's does, so the
/// reports the host queued, before the load or while it stopped, are dropped
/// once the host is joined, and each runs once. A message or notice a child
/// sent is in no log, so it stays queued, in its order, and runs as a turn of
/// the reopened session. Call this before `releaseActiveSession`.
pub fn stopSubagentsForReopen(state: *ServerState) void {
    const active = if (state.active_session) |*session| session else return;
    disableSubagentHost(state);
    dropQueuedMail(state, active.session_id, .owed_reports, "session_reload");
}

/// What a drop takes of the mail `postAcpReport` queued.
const DropScope = enum {
    /// Every item: the session goes, and its mail with it.
    all,
    /// The reports the session's log still owes, those with a work id. A
    /// message or notice, and a report with no work id, is in no log.
    owed_reports,

    fn takes(scope: DropScope, call: ?*const ReportCall) bool {
        return switch (scope) {
            .all => true,
            .owed_reports => if (call) |value| value.outcome != null and value.work_id.len > 0 else false,
        };
    }
};

/// Drops the mail `postAcpReport` queued for `session_id` that no prompt took
/// and `scope` names, and names each item in the trace with `reason`. A
/// report that was owed stays owed in the session's log, which posts it again
/// when the session opens. A message a child sent is in no log of the parent,
/// so a drop of it leaves only the child's own log and the trace line.
fn dropQueuedMail(state: *ServerState, session_id: []const u8, scope: DropScope, reason: []const u8) void {
    const alloc = std.heap.c_allocator;
    state.report_mutex.lockUncancelable(io_mod.getIo());
    defer state.report_mutex.unlock(io_mod.getIo());
    const Drop = struct {
        state: *ServerState,
        session_id: []const u8,
        scope: DropScope,
        reason: []const u8,

        fn decide(self: *@This(), place: usize, queued: *const worker_runtime.QueuedPrompt) bool {
            const call: ?*const ReportCall = if (place < self.state.report_calls.items.len) &self.state.report_calls.items[place] else null;
            if (!self.scope.takes(call)) return false;
            debug_trace.logf("acp", "event=subagent_mail_dropped session={s} kind={s} child={s} work={s} reason={s}", .{
                self.session_id,
                @tagName(queued.mail),
                if (call) |value| value.child_id else "",
                if (call) |value| value.work_id else "",
                self.reason,
            });
            return true;
        }
    };
    var drop: Drop = .{ .state = state, .session_id = session_id, .scope = scope, .reason = reason };
    _ = state.worker.discardQueuedWhere(alloc, &drop, Drop.decide);
    // The calls of the mail that stays keep their places, one for one.
    var kept: usize = 0;
    for (state.report_calls.items) |*call| {
        if (scope.takes(call)) {
            call.deinit(alloc);
        } else {
            state.report_calls.items[kept] = call.*;
            kept += 1;
        }
    }
    state.report_calls.shrinkRetainingCapacity(kept);
}

fn destroyActiveSession(state: *ServerState) void {
    const active = if (state.active_session) |*session| session else return;
    if (active.title_task) |task| {
        debug_trace.logf("session", "event=title_generation_dropped reason=session_release", .{});
        task.destroy();
    }
    state.alloc.free(active.session_id);
    state.alloc.free(active.model);
    if (active.client_system_prompt.len > 0) state.alloc.free(active.client_system_prompt);
    active.tool_identities.deinit(state.alloc);
    active.steering.deinit(state.alloc);
    if (active.mcp_host) |h| h.destroy();
    active.session_rt.deinit(state.alloc);
    if (active.v2) |v2| v2.close();
    active.turn_capture.deinit();
    state.active_session = null;
}

pub fn enableSubagentHost(state: *ServerState) void {
    disableSubagentHost(state);
    const active = if (state.active_session) |*session| session else return;
    const v2 = active.v2 orelse return;
    enableSubagentHostV2(state, active, v2);
}

/// Subagents on v2 keep their state in the session's log (D22). A host that
/// cannot start leaves them off and says why, as on v1.
fn enableSubagentHostV2(state: *ServerState, active: *ActiveSessionState, v2: *session_adapter.Session) void {
    const children = state.alloc.create(subagent_child_state.V2Children) catch |err| {
        debug_trace.logf("acp", "subagent host unavailable session={s} err={s}", .{ active.session_id, @errorName(err) });
        return;
    };
    children.* = subagent_child_state.V2Children.init(state.alloc, v2, active.workspace_root);
    state.subagent_host = subagent_tool_host.Runtime.create(
        state.alloc,
        children,
        .{ .context = state, .resolve_fn = resolveSubagentAuthority },
        .{ .context = state, .run_fn = prompt_handler.runSubagentChild },
    ) catch |err| {
        debug_trace.logf("acp", "subagent host unavailable session={s} err={s}", .{ active.session_id, @errorName(err) });
        children.deinit();
        state.alloc.destroy(children);
        return;
    };
    // A child whose profile lists a tool kept behind toolbox keeps toolbox.
    state.subagent_host.?.authority_resolver.toolbox_behind = &state.toolbox_behind;
    state.subagent_host.?.report_sink = .{ .context = state, .post_fn = postAcpReport };
    state.subagent_v2_children = children;
    // What a restart left owed reaches the session as its next turns.
    state.subagent_host.?.resumeReports(v2);
}

/// The host's report sink: queues the report or message for the prompt,
/// which runs it as the session's next turn once its own turn ends.
fn postAcpReport(
    raw: ?*anyopaque,
    _: *subagent_tool_host.Runtime,
    delivery: subagent_tool_host.Delivery,
) subagent_tool_host.PostReportError!void {
    const state: *ServerState = @ptrCast(@alignCast(raw.?));
    const alloc = std.heap.c_allocator;
    const text = switch (delivery) {
        .report => |report| try subagent_reports.message(alloc, report, state.max_tool_result_bytes),
        .message => |message| try subagent_reports.messageText(alloc, message.agent, message.child_id, message.text, state.max_tool_result_bytes, null, message.user_typed),
    };
    var owns_text = true;
    defer if (owns_text) alloc.free(text);
    var call = try ReportCall.init(alloc, delivery);
    var owns_call = true;
    defer if (owns_call) call.deinit(alloc);
    state.report_mutex.lockUncancelable(io_mod.getIo());
    defer state.report_mutex.unlock(io_mod.getIo());
    try state.report_calls.append(alloc, call);
    owns_call = false;
    state.worker.postMail(alloc, .{
        .prompt = text,
        .images = &.{},
        .model = &.{},
        .api_key = &.{},
        .permission_mode = .yolo,
        .history = &.{},
        .author = .child,
        .mail = if (delivery == .report) .report else .message,
    }) catch |err| {
        var dropped = state.report_calls.pop().?;
        dropped.deinit(alloc);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.QueueFull => error.QueueFull,
            else => error.AgentGone,
        };
    };
    owns_text = false;
}

/// What a queued report answers. All strings are owned (`std.heap.c_allocator`).
pub const ReportCall = struct {
    /// The subagent call that sent the work; empty for a message a child sent.
    call_id: []u8,
    child_id: []u8,
    work_id: []u8,
    /// How the work ended; null for a message.
    outcome: ?subagent_child_state.Outcome,

    fn init(alloc: Allocator, delivery: subagent_tool_host.Delivery) !ReportCall {
        const call_id = try alloc.dupe(u8, switch (delivery) {
            .report => |report| report.call_id,
            .message => "",
        });
        errdefer alloc.free(call_id);
        const child_id = try alloc.dupe(u8, switch (delivery) {
            .report => |report| report.child_id,
            .message => |message| message.child_id,
        });
        errdefer alloc.free(child_id);
        const work_id = try alloc.dupe(u8, switch (delivery) {
            .report => |report| report.work_id,
            .message => "",
        });
        return .{ .call_id = call_id, .child_id = child_id, .work_id = work_id, .outcome = switch (delivery) {
            .report => |report| report.outcome,
            .message => null,
        } };
    }

    pub fn deinit(self: *ReportCall, alloc: Allocator) void {
        alloc.free(self.call_id);
        alloc.free(self.child_id);
        alloc.free(self.work_id);
    }
};

/// What the oldest queued report answers, owned by the caller. Null when
/// the queue holds none.
pub fn takeReportCall(state: *ServerState) ?ReportCall {
    state.report_mutex.lockUncancelable(io_mod.getIo());
    defer state.report_mutex.unlock(io_mod.getIo());
    if (state.report_calls.items.len == 0) return null;
    return state.report_calls.orderedRemove(0);
}

fn resolveSubagentAuthority(
    raw: ?*anyopaque,
    alloc: Allocator,
    root_id: []const u8,
) subagent_authority.HostResolveError!subagent_authority.HostAuthority {
    const state: *ServerState = @ptrCast(@alignCast(raw.?));
    const active = if (state.active_session) |*value| value else return error.HostAuthorityUnavailable;
    if (!std.mem.eql(u8, active.session_id, root_id)) {
        return error.HostAuthorityUnavailable;
    }
    state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
    defer state.subagent_authority_mutex.unlock(io_mod.getIo());
    const integrations = if (active.mcp_host) |h|
        h.catalog.snapshotToolNames(alloc)
    else
        alloc.alloc([]u8, 0);
    const owned_integrations = integrations catch return error.OutOfMemory;
    defer {
        for (owned_integrations) |name| alloc.free(name);
        alloc.free(owned_integrations);
    }
    var mcp_view = if (active.mcp_host) |h|
        try h.catalog.snapshotAccessView(alloc, root_id, root_id)
    else
        null;
    defer if (mcp_view) |*view| view.deinit(alloc);
    return subagent_tool_host.captureHostAuthorityWithMcpView(
        alloc,
        .{
            .tool_set = builtin_tools.advertisement_set,
            .mode = .{
                .active = .{
                    .registry = state.cfg.mode_registry,
                    .id = active.mode,
                },
            },
        },
        owned_integrations,
        if (mcp_view) |*view| view else null,
    );
}

/// Joins the child threads before the session they append to can close
/// (`tests/tla/session_manager/Wiring.tla` ParentOutlivesChildren).
pub fn disableSubagentHost(state: *ServerState) void {
    if (state.subagent_host) |host| {
        host.deinit();
        state.subagent_host = null;
    }
    if (state.subagent_v2_children) |children| {
        children.deinit();
        state.alloc.destroy(children);
        state.subagent_v2_children = null;
    }
}

pub fn run(alloc: Allocator, cfg: Config) !void {
    return runWithTransport(alloc, cfg, jsonrpc.Reader.init(), jsonrpc.Writer.init());
}

pub fn runWithTransport(
    alloc: Allocator,
    cfg: Config,
    reader_value: jsonrpc.Reader,
    writer_value: jsonrpc.Writer,
) !void {
    if (cfg.log_file) |path| {
        try debug_trace.configure(.{ .file_path = path });
    }

    var lifecycle_runtime = hooks.Runtime.init(alloc);
    const lifecycle_view = lifecycle_runtime.freeze();
    var state = ServerState{
        .alloc = alloc,
        .cfg = cfg,
        .writer = writer_value,
        .web_search_runtime = web_search_runtime.Runtime.init(.{}),
        .terminal_client = terminal_client_runtime.Runtime.init(
            cfg.process_provider,
        ),
        .managed_executions = managed_execution.Runtime.init(alloc),
        .lifecycle_runtime = lifecycle_runtime,
        .lifecycle_view = lifecycle_view,
    };
    defer state.deinit();
    state.sessions_v2 = (if (cfg.home_override) |home|
        session_adapter.Store.open(alloc, home)
    else
        session_adapter.Store.openFromEnv(alloc)) catch |err| blk: {
        debug_trace.logf("acp", "event=sessions_v2_store_unavailable err={s}", .{@errorName(err)});
        break :blk null;
    };

    var reader = reader_value;
    while (!state.terminate_connection) {
        reapActivePrompt(&state, false);
        const line_result = reader.readLine(alloc) catch break;
        if (line_result == null) break;
        const line = switch (line_result.?) {
            .overflow => {
                state.writer.writeError(alloc, null, .{
                    .code = ErrorCode.request_frame_too_large,
                    .message = "Request frame too large",
                }) catch break;
                continue;
            },
            .line => |value| value,
        };
        defer alloc.free(line);

        var msg = jsonrpc.parseMessage(alloc, line) catch |err| {
            const code = switch (err) {
                error.ParseError => ErrorCode.parse_error,
                else => ErrorCode.invalid_request,
            };
            state.writer.writeError(alloc, null, .{ .code = code, .message = "Parse error" }) catch break;
            continue;
        };
        defer jsonrpc.freeMessage(alloc, &msg);

        if (msg.isResponse()) {
            handleClientResponse(&state, alloc, &msg);
            continue;
        }

        if (!shouldRespondToMessage(&msg)) {
            dispatchNotification(&state, alloc, &msg) catch {};
            if (state.terminate_connection) break;
            continue;
        }

        dispatch(&state, alloc, &msg) catch |err| {
            const credential_notice: ?[]const u8 = if (err == error.ProviderCredentialUnavailable)
                auth_runtime.missingCredentialText(state.provider)
            else
                null;
            state.writer.writeError(alloc, msg.id, .{
                .code = if (credential_notice != null) ErrorCode.invalid_request else ErrorCode.internal_error,
                .message = credential_notice orelse @errorName(err),
            }) catch break;
        };
        if (state.terminate_connection) break;
    }
    // Release any prompt thread parked on a pending approval before
    // state.deinit() joins it, or shutdown deadlocks.
    handleCancel(&state, false);
}

fn shouldRespondToMessage(msg: *const jsonrpc.Message) bool {
    return !msg.isResponse() and msg.id != null;
}

fn handleClientResponse(state: *ServerState, alloc: Allocator, msg: *const jsonrpc.Message) void {
    const id = msg.id orelse return;
    const numeric_id: u64 = switch (id) {
        .integer => |value| if (value > 0) @intCast(value) else return,
        else => return,
    };
    const result_copy = if (msg.result_raw) |raw| alloc.dupe(u8, raw) catch return else null;
    const error_copy = if (msg.error_raw) |raw| alloc.dupe(u8, raw) catch {
        if (result_copy) |value| alloc.free(value);
        return;
    } else null;

    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    defer state.outbound_mutex.unlock(io_mod.getIo());
    const pending = state.pending_outbound.getPtr(numeric_id) orelse {
        if (result_copy) |value| alloc.free(value);
        if (error_copy) |value| alloc.free(value);
        return;
    };
    if (pending.response != null) {
        if (result_copy) |value| alloc.free(value);
        if (error_copy) |value| alloc.free(value);
        return;
    }
    pending.response = .{
        .result_json = result_copy,
        .error_json = error_copy,
    };
    state.outbound_cond.broadcast(io_mod.getIo());
}

fn parsePermissionDecision(root: std.json.Value) ?types.ToolPermissionDecision {
    if (root != .object) return null;
    const outcome = root.object.get("outcome") orelse return null;
    if (outcome != .object) return null;
    const kind = outcome.object.get("outcome") orelse return null;
    if (kind != .string) return null;
    if (std.mem.eql(u8, kind.string, "cancelled")) return .deny;
    if (!std.mem.eql(u8, kind.string, "selected")) return null;
    const option = outcome.object.get("optionId") orelse return null;
    if (option != .string) return null;
    if (std.mem.eql(u8, option.string, "allow_once")) return .once;
    if (std.mem.eql(u8, option.string, "allow_always")) return .always;
    if (std.mem.eql(u8, option.string, "reject_once")) return .deny;
    return null;
}

pub fn beginOutboundRequest(state: *ServerState, kind: OutboundKind) !?u64 {
    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    defer state.outbound_mutex.unlock(io_mod.getIo());
    if (state.pending_outbound.count() >= max_pending_outbound or
        state.next_outbound_request_id > @as(u64, @intCast(std.math.maxInt(i64))))
    {
        return null;
    }
    const id = state.next_outbound_request_id;
    state.next_outbound_request_id += 1;
    try state.pending_outbound.put(state.alloc, id, .{ .kind = kind });
    return id;
}

pub fn awaitOutboundResponse(state: *ServerState, id: u64, kind: OutboundKind) ?OutboundResponse {
    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    defer state.outbound_mutex.unlock(io_mod.getIo());
    while (true) {
        const pending = state.pending_outbound.getPtr(id) orelse return null;
        if (pending.kind != kind) return null;
        if (pending.response) |response| {
            _ = state.pending_outbound.remove(id);
            return response;
        }
        state.outbound_cond.wait(io_mod.getIo(), &state.outbound_mutex) catch {
            _ = cancelOutboundRequestLocked(state, id);
        };
    }
}

/// Takes the event of an `awaitOutboundResponse` task in `select` after
/// `cancelOutboundRequest` made it return, and frees any response. Call when
/// that event is the only one outstanding; `select` then has nothing left to
/// cancel. `select` must hold a `response: ?OutboundResponse` event.
pub fn takeCancelledResponse(state: *ServerState, select: anytype) void {
    const item = select.queue.getOneUncancelable(select.io) catch |err| switch (err) {
        // Only Select.cancel and cancelDiscard close the queue, and they leave
        // nothing outstanding.
        error.Closed => return,
    };
    switch (item) {
        .response => |maybe_response| if (maybe_response) |owned| {
            var response = owned;
            response.deinit(state.alloc);
        },
        else => {},
    }
    std.debug.assert(select.cancel() == null);
}

/// Forgets a request that was never written to the client.
pub fn discardOutboundRequest(state: *ServerState, id: u64) void {
    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    defer state.outbound_mutex.unlock(io_mod.getIo());
    if (state.pending_outbound.fetchRemove(id)) |entry| {
        if (entry.value.response) |response| {
            var owned = response;
            owned.deinit(state.alloc);
        }
    }
}

pub fn cancelOutboundRequest(state: *ServerState, id: u64) void {
    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    const changed = cancelOutboundRequestLocked(state, id);
    state.outbound_mutex.unlock(io_mod.getIo());
    if (changed) publishRequestCancellation(state, id);
}

fn cancelOutboundRequestLocked(state: *ServerState, id: u64) bool {
    const pending = state.pending_outbound.getPtr(id) orelse return false;
    if (pending.response != null) return false;
    pending.response = .{ .cancelled = true };
    state.outbound_cond.broadcast(io_mod.getIo());
    return true;
}

fn cancelPendingOutbound(state: *ServerState, notify_client: bool) void {
    var cancelled_ids: [max_pending_outbound]u64 = undefined;
    var cancelled_count: usize = 0;
    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    var pending = state.pending_outbound.iterator();
    while (pending.next()) |entry| {
        if (entry.value_ptr.response != null) continue;
        entry.value_ptr.response = .{ .cancelled = true };
        cancelled_ids[cancelled_count] = entry.key_ptr.*;
        cancelled_count += 1;
    }
    state.outbound_cond.broadcast(io_mod.getIo());
    state.outbound_mutex.unlock(io_mod.getIo());

    if (!notify_client) return;
    for (cancelled_ids[0..cancelled_count]) |id| publishRequestCancellation(state, id);
}

fn publishRequestCancellation(state: *ServerState, id: u64) void {
    var params: std.Io.Writer.Allocating = .init(state.alloc);
    defer params.deinit();
    params.writer.print("{{\"requestId\":{d}}}", .{id}) catch |err| {
        debug_trace.logf("acp", "request cancellation serialization failed id={d} err={s}", .{ id, @errorName(err) });
        return;
    };
    state.writer.writeNotification(
        state.alloc,
        "$/cancel_request",
        params.writer.buffered(),
    ) catch |err| {
        debug_trace.logf("acp", "request cancellation publication failed id={d} err={s}", .{ id, @errorName(err) });
    };
}

pub fn reserveLegacyUrl(
    state: *ServerState,
    origin: tool_mcp_runtime.InputOrigin,
    source_id: []const u8,
    acp_id: []const u8,
    session_id: []const u8,
    tool_call_id: []const u8,
) !bool {
    state.legacy_url_mutex.lockUncancelable(io_mod.getIo());
    defer state.legacy_url_mutex.unlock(io_mod.getIo());
    const now_ms = serverAwakeMillis();
    var pending_index: usize = 0;
    while (pending_index < state.pending_legacy_urls.items.len) {
        const pending = &state.pending_legacy_urls.items[pending_index];
        const stale_generation = std.mem.eql(u8, pending.server_name, origin.server_name) and
            (pending.binding.runtime_generation != origin.runtime_generation or
                pending.binding.connection_generation != origin.connection_generation or
                pending.binding.client_generation != origin.client_generation or
                pending.binding.auth_generation != origin.auth_generation);
        if (pending.binding.deadline_ms >= now_ms and !stale_generation) {
            pending_index += 1;
            continue;
        }
        var expired = state.pending_legacy_urls.swapRemove(pending_index);
        expired.deinit(state.alloc);
    }
    if (state.pending_legacy_urls.items.len >= max_pending_outbound) return false;
    for (state.pending_legacy_urls.items) |pending| {
        if (std.mem.eql(u8, pending.server_name, origin.server_name) and
            std.mem.eql(u8, pending.source_id, source_id)) return false;
    }

    const server_name = try state.alloc.dupe(u8, origin.server_name);
    errdefer state.alloc.free(server_name);
    const owned_source_id = try state.alloc.dupe(u8, source_id);
    errdefer state.alloc.free(owned_source_id);
    const owned_acp_id = try state.alloc.dupe(u8, acp_id);
    errdefer state.alloc.free(owned_acp_id);
    const owned_session_id = try state.alloc.dupe(u8, session_id);
    errdefer state.alloc.free(owned_session_id);
    const owned_tool_call_id = try state.alloc.dupe(u8, tool_call_id);
    errdefer state.alloc.free(owned_tool_call_id);
    try state.pending_legacy_urls.append(state.alloc, .{
        .server_name = server_name,
        .source_id = owned_source_id,
        .acp_id = owned_acp_id,
        .session_id = owned_session_id,
        .tool_call_id = owned_tool_call_id,
        .binding = .{
            .server_name = server_name,
            .scope = .{ .acp_session = .{
                .session_id = owned_session_id,
                .tool_call_id = owned_tool_call_id,
            } },
            .runtime_generation = origin.runtime_generation,
            .connection_generation = origin.connection_generation,
            .client_generation = origin.client_generation,
            .catalog_generation = origin.catalog_generation,
            .request_generation = origin.request_generation,
            .auth_generation = origin.auth_generation,
            .deadline_ms = std.math.add(i64, now_ms, legacy_url_completion_timeout_ms) catch
                std.math.maxInt(i64),
        },
    });
    return true;
}

pub fn removeLegacyUrl(
    state: *ServerState,
    acp_id: []const u8,
) void {
    state.legacy_url_mutex.lockUncancelable(io_mod.getIo());
    defer state.legacy_url_mutex.unlock(io_mod.getIo());
    for (state.pending_legacy_urls.items, 0..) |pending, index| {
        if (!std.mem.eql(u8, pending.acp_id, acp_id)) continue;
        var removed = state.pending_legacy_urls.swapRemove(index);
        removed.deinit(state.alloc);
        return;
    }
}

pub fn acceptLegacyUrl(
    state: *ServerState,
    origin: tool_mcp_runtime.InputOrigin,
    acp_id: []const u8,
) tool_mcp_runtime.LegacyUrlAcceptTransition {
    var owned_acp_id: ?[]u8 = null;
    state.legacy_url_mutex.lockUncancelable(io_mod.getIo());
    const result = result: for (state.pending_legacy_urls.items, 0..) |*pending, index| {
        if (!std.mem.eql(u8, pending.acp_id, acp_id)) continue;
        if (pending.binding.runtime_generation != origin.runtime_generation or
            pending.binding.connection_generation != origin.connection_generation or
            pending.binding.client_generation != origin.client_generation or
            pending.binding.catalog_generation != origin.catalog_generation or
            pending.binding.request_generation != origin.request_generation or
            pending.binding.auth_generation != origin.auth_generation)
        {
            break :result tool_mcp_runtime.LegacyUrlAcceptTransition.missing;
        }
        pending.accepted = true;
        if (!pending.completed) {
            break :result tool_mcp_runtime.LegacyUrlAcceptTransition.awaiting_completion;
        }
        var removed = state.pending_legacy_urls.swapRemove(index);
        owned_acp_id = removed.acp_id;
        removed.acp_id = &.{};
        removed.deinit(state.alloc);
        break :result tool_mcp_runtime.LegacyUrlAcceptTransition{ .completed = owned_acp_id.? };
    } else tool_mcp_runtime.LegacyUrlAcceptTransition.missing;
    state.legacy_url_mutex.unlock(io_mod.getIo());
    return result;
}

fn clearPendingLegacyUrls(state: *ServerState) void {
    state.legacy_url_mutex.lockUncancelable(io_mod.getIo());
    defer state.legacy_url_mutex.unlock(io_mod.getIo());
    for (state.pending_legacy_urls.items) |*pending| pending.deinit(state.alloc);
    state.pending_legacy_urls.clearRetainingCapacity();
}

pub fn legacyUrlCompletionSink(state: *ServerState) tool_mcp_runtime.LegacyUrlCompletionSink {
    return .{
        .context = @ptrCast(state),
        .accept = acceptLegacyUrlFromSink,
        .consume = consumeLegacyUrlCompletion,
        .publish = publishLegacyUrlCompletionFromSink,
    };
}

fn acceptLegacyUrlFromSink(
    raw_context: *anyopaque,
    origin: tool_mcp_runtime.InputOrigin,
    acp_id: []const u8,
) tool_mcp_runtime.LegacyUrlAcceptTransition {
    const state: *ServerState = @ptrCast(@alignCast(raw_context));
    return acceptLegacyUrl(state, origin, acp_id);
}

fn consumeLegacyUrlCompletion(
    raw_context: *anyopaque,
    completion: tool_mcp_runtime.LegacyUrlCompletion,
) tool_mcp_runtime.LegacyUrlConsumeTransition {
    const state: *ServerState = @ptrCast(@alignCast(raw_context));
    var acp_id: ?[]u8 = null;
    var matched = false;
    state.legacy_url_mutex.lockUncancelable(io_mod.getIo());
    for (state.pending_legacy_urls.items, 0..) |*pending, index| {
        if (!std.mem.eql(u8, pending.server_name, completion.server_name) or
            !std.mem.eql(u8, pending.source_id, completion.elicitation_id)) continue;
        if (pending.binding.runtime_generation != completion.runtime_generation or
            pending.binding.connection_generation != completion.connection_generation or
            pending.binding.client_generation != completion.client_generation or
            pending.binding.auth_generation != completion.auth_generation) break;
        const transition = elicitation.decideTransition(
            .pending,
            pending.binding,
            .{
                .server_name = completion.server_name,
                .scope = pending.binding.scope,
                .runtime_generation = completion.runtime_generation,
                .connection_generation = completion.connection_generation,
                .client_generation = completion.client_generation,
                .catalog_generation = pending.binding.catalog_generation,
                .request_generation = pending.binding.request_generation,
                .auth_generation = completion.auth_generation,
            },
            serverAwakeMillis(),
            true,
        );
        matched = true;
        switch (transition) {
            .consume => {
                if (pending.accepted) {
                    var removed = state.pending_legacy_urls.swapRemove(index);
                    acp_id = removed.acp_id;
                    removed.acp_id = &.{};
                    removed.deinit(state.alloc);
                } else {
                    pending.completed = true;
                }
            },
            .reject => {
                var removed = state.pending_legacy_urls.swapRemove(index);
                removed.deinit(state.alloc);
            },
        }
        break;
    }
    state.legacy_url_mutex.unlock(io_mod.getIo());

    return if (matched)
        .{ .consumed = acp_id }
    else
        .missing;
}

fn publishLegacyUrlCompletionFromSink(raw_context: *anyopaque, id: []u8) void {
    const state: *ServerState = @ptrCast(@alignCast(raw_context));
    publishLegacyUrlCompletion(state, id);
}

fn publishLegacyUrlCompletion(state: *ServerState, id: []u8) void {
    defer state.alloc.free(id);
    var params: std.Io.Writer.Allocating = .init(state.alloc);
    defer params.deinit();
    params.writer.writeAll("{\"elicitationId\":") catch return;
    std.json.Stringify.value(id, .{}, &params.writer) catch return;
    params.writer.writeByte('}') catch return;
    state.writer.writeNotification(
        state.alloc,
        "elicitation/complete",
        params.writer.buffered(),
    ) catch {};
}

fn serverAwakeMillis() i64 {
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const milliseconds = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(i64, milliseconds) orelse if (milliseconds < 0)
        std.math.minInt(i64)
    else
        std.math.maxInt(i64);
}

/// Permission compatibility wrapper over the shared outbound registry.
pub fn beginPermissionRequest(state: *ServerState) ?u64 {
    return beginOutboundRequest(state, .permission) catch null;
}

pub fn awaitPermissionDecision(state: *ServerState, id: u64) types.ToolPermissionDecision {
    var response = awaitOutboundResponse(state, id, .permission) orelse return .deny;
    defer response.deinit(state.alloc);
    if (response.cancelled or response.error_json != null) return .deny;
    const raw = response.result_json orelse return .deny;
    const parsed = std.json.parseFromSlice(std.json.Value, state.alloc, raw, .{}) catch return .deny;
    defer parsed.deinit();
    return parsePermissionDecision(parsed.value) orelse .deny;
}

pub fn cancelPermissionRequest(state: *ServerState, id: u64) void {
    cancelOutboundRequest(state, id);
}

fn dispatchNotification(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    reapActivePrompt(state, false);
    if (!state.initialized) return;
    switch (AcpMethod.parse(msg.method)) {
        .request_cancel => handleRequestCancellation(state, alloc, msg.params_raw),
        .session_cancel => {
            if (notificationTargetsActiveSession(state, alloc, msg.params_raw)) {
                handleCancel(state, true);
            }
        },
        .mcp_message => {
            // Request-scoped MCP notifications, such as progress, are not
            // delivered to the running operation yet.
            debug_trace.logf("acp", "dropped mcp/message notification bytes={d}", .{if (msg.params_raw) |raw| raw.len else 0});
        },
        else => {},
    }
}

fn dispatch(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    reapActivePrompt(state, false);
    const method = AcpMethod.parse(msg.method);

    if (method == .initialize) {
        return handleInitialize(state, alloc, msg);
    }

    if (!state.initialized) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Not initialized. Call initialize first.",
        });
    }

    if (method == .session_cancel) {
        if (!try requireActiveSessionTarget(state, alloc, msg)) return;
        handleCancel(state, true);
        return state.writer.writeResponse(alloc, msg.id, "null");
    }

    if (method == .session_prompt and state.active_prompt != null) {
        return handleSteeringPrompt(state, alloc, msg);
    }

    if (method.waitsForActivePrompt() and state.active_prompt != null) {
        return writePromptInProgress(state, alloc, msg.id);
    }

    return switch (method) {
        .session_new => sessions.handleNewSession(state, alloc, msg),
        .session_load => sessions.handleLoadSession(state, alloc, msg),
        .session_resume => sessions.handleResumeSession(state, alloc, msg),
        .session_close => handleCloseSession(state, alloc, msg),
        .session_list => sessions.handleListSessions(state, alloc, msg),
        .session_remove => sessions.handleRemoveSession(state, alloc, msg),
        .session_rename => sessions.handleRenameSession(state, alloc, msg),
        .session_prompt => startPrompt(state, alloc, msg),
        .session_set_config_option => handleSetConfigOption(state, alloc, msg),
        .session_set_mode => handleSetMode(state, alloc, msg),
        .initialize,
        .request_cancel,
        .session_cancel,
        .mcp_message,
        .unknown,
        => state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.method_not_found,
            .message = "Method not found",
        }),
    };
}

fn requestIdsEqual(lhs: jsonrpc.RequestId, rhs: jsonrpc.RequestId) bool {
    return switch (lhs) {
        .integer => |value| switch (rhs) {
            .integer => |other| value == other,
            else => false,
        },
        .string => |value| switch (rhs) {
            .string => |other| std.mem.eql(u8, value, other),
            else => false,
        },
        .null => rhs == .null,
    };
}

fn requestIdFromValue(value: std.json.Value) ?jsonrpc.RequestId {
    return switch (value) {
        .integer => |id| .{ .integer = id },
        .string => |id| .{ .string = id },
        .null => .null,
        else => null,
    };
}

fn handleRequestCancellation(
    state: *ServerState,
    alloc: Allocator,
    params: ?[]const u8,
) void {
    const raw = params orelse return;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const value = parsed.value.object.get("requestId") orelse return;
    const requested = requestIdFromValue(value) orelse return;
    const active = state.active_prompt orelse return;
    const active_id = active.msg.id orelse return;
    if (!requestIdsEqual(active_id, requested)) return;
    handleCancel(state, true);
}

pub fn takeSteering(
    state: *ServerState,
    result_alloc: Allocator,
    close_if_empty: bool,
) Allocator.Error!steering.Drained {
    const active = if (state.active_session) |*session| session else return .{ .texts = &.{}, .request_ids = &.{} };
    return active.steering.takeAll(state.alloc, result_alloc, close_if_empty);
}

fn writePromptInProgress(state: *ServerState, alloc: Allocator, id: ?jsonrpc.RequestId) !void {
    return state.writer.writeError(alloc, id, .{
        .code = ErrorCode.invalid_request,
        .message = "Prompt already in progress",
    });
}

/// Joins a `session/prompt` that sets `_meta.spark.steer` to the running turn at
/// its next safe boundary. The response is deferred until that turn ends. A
/// prompt without the opt-in keeps the in-progress rejection. Steering closes
/// only after the turn has fully returned, so joining the finishing worker
/// here never waits on work that needs this reader.
fn handleSteeringPrompt(state: *ServerState, alloc: Allocator, msg: *const jsonrpc.Message) !void {
    const params = msg.params_raw orelse return writePromptInProgress(state, alloc, msg.id);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return writePromptInProgress(state, alloc, msg.id);
    defer parsed.deinit();
    if (parsed.value != .object or !(acp_types.fxMetaBool(parsed.value.object, "steer") orelse false)) {
        return writePromptInProgress(state, alloc, msg.id);
    }
    if (!try requireParsedActiveSessionTarget(state, alloc, msg.id, parsed.value)) return;
    const text = steeringPromptText(alloc, parsed.value.object) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedSteeringContent => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Steering prompts accept text content blocks only",
        }),
    };
    defer alloc.free(text);
    const session = if (state.active_session) |*active| active else unreachable;
    session.steering.enqueueRequest(state.alloc, text, msg.id) catch |err| switch (err) {
        error.SteeringNotActive => {
            // The running turn already stopped taking input. Let it answer,
            // then run this prompt as the next turn instead of rejecting it.
            debug_trace.logf("acp", "steering prompt arrived after the turn closed input; starting next turn", .{});
            reapActivePrompt(state, true);
            return startPrompt(state, alloc, msg);
        },
        error.OutOfMemory => return error.OutOfMemory,
        error.EmptySteeringMessage => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Steering prompt text cannot be empty",
        }),
        error.SteeringMessageTooLarge => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Steering prompt text exceeds the 64 KiB limit",
        }),
        error.SteeringQueueFull => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Steering queue is full",
        }),
    };
    debug_trace.logf("acp", "queued steering prompt bytes={d}", .{text.len});
}

/// Joins the text blocks of a steering prompt. Caller owns the result.
fn steeringPromptText(
    alloc: Allocator,
    params: std.json.ObjectMap,
) (Allocator.Error || error{UnsupportedSteeringContent})![]u8 {
    const prompt = params.get("prompt") orelse return error.UnsupportedSteeringContent;
    if (prompt != .array) return error.UnsupportedSteeringContent;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    for (prompt.array.items) |block| {
        if (block != .object) return error.UnsupportedSteeringContent;
        const kind = block.object.get("type") orelse return error.UnsupportedSteeringContent;
        const value = block.object.get("text") orelse return error.UnsupportedSteeringContent;
        if (kind != .string or !std.mem.eql(u8, kind.string, "text") or value != .string) {
            return error.UnsupportedSteeringContent;
        }
        if (text.items.len > 0) try text.append(alloc, '\n');
        try text.appendSlice(alloc, value.string);
    }
    return text.toOwnedSlice(alloc);
}

fn startPrompt(state: *ServerState, alloc: Allocator, msg: *const jsonrpc.Message) !void {
    if (!try requireActiveSessionTarget(state, alloc, msg)) return;
    const session = if (state.active_session) |*active| active else unreachable;
    const active = try alloc.create(ActivePrompt);
    errdefer alloc.destroy(active);
    active.* = .{
        .state = state,
        .alloc = alloc,
        .msg = try cloneMessage(alloc, msg),
        .mode = session.mode,
        .permission_mode = session.permission_mode,
    };
    errdefer jsonrpc.freeMessage(alloc, &active.msg);

    session.turn_cancel.store(false, .seq_cst);
    session.cancel_flag.store(false, .seq_cst);
    session.steering.open(state.alloc);
    active.thread = try std.Thread.spawn(.{}, promptWorkerMain, .{active});
    state.active_prompt = active;
}

fn parsedSessionTargetDecision(state: *const ServerState, root: std.json.Value) SessionTargetDecision {
    const active_id = if (state.active_session) |session| session.session_id else null;
    const supplied = if (root == .object) root.object.get("sessionId") else null;
    return decideSessionTarget(active_id, supplied);
}

fn writeSessionTargetError(
    state: *ServerState,
    alloc: Allocator,
    id: ?jsonrpc.RequestId,
    decision: SessionTargetDecision,
) !void {
    const message: []const u8 = switch (decision) {
        .exact => return,
        .inactive => "No active session",
        .missing => "Missing sessionId",
        .mismatch => "Session is not active",
    };
    try state.writer.writeError(alloc, id, .{
        .code = ErrorCode.invalid_params,
        .message = message,
    });
}

fn requireParsedActiveSessionTarget(
    state: *ServerState,
    alloc: Allocator,
    id: ?jsonrpc.RequestId,
    root: std.json.Value,
) !bool {
    const decision = parsedSessionTargetDecision(state, root);
    if (decision == .exact) return true;
    try writeSessionTargetError(state, alloc, id, decision);
    return false;
}

fn requireActiveSessionTarget(
    state: *ServerState,
    alloc: Allocator,
    msg: *const jsonrpc.Message,
) !bool {
    const params = msg.params_raw orelse {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing params",
        });
        return false;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid params",
        });
        return false;
    };
    defer parsed.deinit();
    return requireParsedActiveSessionTarget(state, alloc, msg.id, parsed.value);
}

fn notificationTargetsActiveSession(
    state: *const ServerState,
    alloc: Allocator,
    params: ?[]const u8,
) bool {
    const raw = params orelse return false;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return false;
    defer parsed.deinit();
    const decision = parsedSessionTargetDecision(state, parsed.value);
    if (decision != .exact) {
        debug_trace.logf("acp", "ignored session notification target reason={s}", .{@tagName(decision)});
        return false;
    }
    return true;
}

fn promptWorkerMain(active: *ActivePrompt) void {
    const outcome: prompt_handler.TerminalOutcome = prompt_handler.handlePrompt(
        active.state,
        active.alloc,
        &active.msg,
        active.mode,
        active.permission_mode,
        &active.usage,
    ) catch |err| .{
        .rpc_error = .{
            .code = ErrorCode.internal_error,
            // A storage fault is named (D29).
            .message = if (active.state.sessions_v2 != null)
                sessions.v2StorageFaultMessage("Session could not be saved", err) orelse @errorName(err)
            else
                @errorName(err),
        },
    };
    const finished_steering: ?steering.Finished = if (active.state.active_session) |*session|
        session.steering.finishTurn(active.state.alloc, active.alloc, "turn_finished") catch |err| blk: {
            debug_trace.logf("acp", "failed to collect steering prompts at turn end err={s}", .{@errorName(err)});
            break :blk null;
        }
    else
        null;
    defer if (finished_steering) |finished| finished.deinit(active.alloc);
    active.reapable.store(true, .seq_cst);
    publishPromptOutcome(active, outcome) catch {};
    if (finished_steering) |finished| publishSteeringOutcomes(active, outcome, finished) catch {};
    prompt_test_controls.pauseAfterTerminalWrite();
}

fn publishPromptOutcome(active: *ActivePrompt, outcome: prompt_handler.TerminalOutcome) !void {
    switch (outcome) {
        .stop_reason => |stop_reason| {
            var response: std.Io.Writer.Allocating = .init(active.alloc);
            defer response.deinit();
            try acp_types.writePromptResponseWithUsage(
                &response.writer,
                stop_reason,
                active.usage,
            );
            try active.state.writer.writeResponse(active.alloc, active.msg.id, response.writer.buffered());
        },
        .rpc_error => |rpc_error| {
            try active.state.writer.writeError(active.alloc, active.msg.id, rpc_error);
        },
    }
}

/// Answers steering prompts once the turn that received them has answered.
/// Delivered steering shares the turn's outcome. Undelivered steering is
/// reported as cancelled when the turn was cancelled, otherwise as an error
/// so the client can send it again.
fn publishSteeringOutcomes(
    active: *ActivePrompt,
    outcome: prompt_handler.TerminalOutcome,
    finished: steering.Finished,
) !void {
    const cancelled = outcome == .stop_reason and outcome.stop_reason == .cancelled;
    for (finished.absorbed) |id| try writeSteeringOutcome(active, id, outcome, .absorbed);
    for (finished.dropped) |id| {
        if (cancelled) {
            try writeSteeringOutcome(active, id, outcome, .dropped);
        } else {
            try active.state.writer.writeError(active.alloc, id, .{
                .code = ErrorCode.invalid_request,
                .message = "Steering prompt was not delivered because the turn ended first; send it as a new prompt",
            });
        }
    }
}

fn writeSteeringOutcome(
    active: *ActivePrompt,
    id: jsonrpc.RequestId,
    outcome: prompt_handler.TerminalOutcome,
    delivery: acp_types.SteeringDelivery,
) !void {
    switch (outcome) {
        .stop_reason => |stop_reason| {
            var response: std.Io.Writer.Allocating = .init(active.alloc);
            defer response.deinit();
            try acp_types.writeSteeringPromptResponse(&response.writer, stop_reason, delivery);
            try active.state.writer.writeResponse(active.alloc, id, response.written());
        },
        .rpc_error => |rpc_error| try active.state.writer.writeError(active.alloc, id, rpc_error),
    }
}

fn reapActivePrompt(state: *ServerState, wait: bool) void {
    const active = state.active_prompt orelse return;
    if (!wait and !active.reapable.load(.seq_cst)) return;
    prompt_test_controls.noteReapBeforeJoin();
    active.thread.join();
    jsonrpc.freeMessage(active.alloc, &active.msg);
    active.alloc.destroy(active);
    state.active_prompt = null;
}

fn cloneMessage(alloc: Allocator, msg: *const jsonrpc.Message) !jsonrpc.Message {
    var copy = jsonrpc.Message{
        .method = try alloc.dupe(u8, msg.method),
    };
    errdefer jsonrpc.freeMessage(alloc, &copy);
    if (msg.params_raw) |params| copy.params_raw = try alloc.dupe(u8, params);
    if (msg.id) |id| {
        copy.id = switch (id) {
            .integer => |value| .{ .integer = value },
            .string => |value| .{ .string = try alloc.dupe(u8, value) },
            .null => .null,
        };
    }
    return copy;
}

const InitializeRequest = struct {
    /// False when the client presents spark inside an application rather than a
    /// terminal, set through `_meta.spark.terminal`.
    terminal_ui: bool = true,
    client_fs_read: bool = false,
    client_fs_write: bool = false,
    client_terminal: bool = false,
    /// The client shows ACP v1 Session Notices (`session.notices`).
    client_notices: bool = false,
    client_elicitation: elicitation.Capabilities = .{},
};

fn parseInitializeRequest(
    alloc: Allocator,
    params: ?[]const u8,
) !InitializeRequest {
    const raw = params orelse return error.InvalidInitializeParams;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch
        return error.InvalidInitializeParams;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidInitializeParams;

    const version = parsed.value.object.get("protocolVersion") orelse
        return error.InvalidInitializeParams;
    if (version != .integer) return error.InvalidInitializeParams;
    if (version.integer < 0 or version.integer > std.math.maxInt(u16))
        return error.InvalidInitializeParams;

    var request = InitializeRequest{
        .terminal_ui = acp_types.fxMetaBool(parsed.value.object, "terminal") orelse true,
    };
    const capabilities = parsed.value.object.get("clientCapabilities") orelse
        return request;
    if (capabilities != .object) return request;
    if (capabilities.object.get("fs")) |fs| {
        if (fs == .object) {
            if (fs.object.get("readTextFile")) |value| {
                request.client_fs_read = value == .bool and value.bool;
            }
            if (fs.object.get("writeTextFile")) |value| {
                request.client_fs_write = value == .bool and value.bool;
            }
        }
    }
    if (capabilities.object.get("session")) |session| {
        // ACP v1 advertises notices with an object, `{}`. Omitted, null,
        // and any value v1 doesn't define, such as `false`, all mean no.
        if (session == .object) if (session.object.get("notices")) |notices| {
            request.client_notices = notices == .object;
        };
    }
    if (capabilities.object.get("terminal")) |value| {
        request.client_terminal = value == .bool and value.bool;
    }
    request.client_elicitation = elicitation.parseAcpCapabilities(capabilities);
    return request;
}

fn loadConfiguredStartupState(state: *const ServerState, alloc: Allocator) !app_lifecycle.StartupState {
    if (state.cfg.home_override) |home_dir| {
        if (state.cfg.workspace_root_override) |workspace_root| {
            var startup = try app_lifecycle.loadEmbeddedStartupState(
                alloc,
                home_dir,
                workspace_root,
                state.cfg.default_model,
                state.cfg.default_agent_step_limit,
                state.cfg.model_override,
            );
            startup.auth_mode = state.cfg.auth_mode;
            return startup;
        }
    }
    return app_lifecycle.loadStartupStateForRun(
        alloc,
        oauth_transport.unavailable_provider,
        state.cfg.secret_store,
        state.cfg.default_model,
        state.cfg.default_agent_step_limit,
        state.cfg.auth_mode,
        null,
        state.cfg.model_override,
    );
}

fn configureUltrafastStartup(state: *ServerState, startup: *const app_lifecycle.StartupState) void {
    state.configured_ultrafast_mode = startup.configured_ultrafast_mode;
    state.process_ultrafast_override = state.cfg.ultrafast_override orelse startup.ultrafast_process_override;
    state.ultrafast_mode = state.process_ultrafast_override orelse state.configured_ultrafast_mode;
}

fn handleInitialize(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    if (state.initialized) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Already initialized",
        });
    }

    const request = parseInitializeRequest(
        alloc,
        msg.params_raw,
    ) catch {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid initialize params",
        });
    };

    var startup = loadConfiguredStartupState(state, alloc) catch |err| {
        const model_message = config_runtime.modelNotSelectedMessage(err);
        const settings_message = if (model_message == null) try config_runtime.configuredProviderMessage(alloc, err) else null;
        defer if (settings_message) |message| alloc.free(message);
        return state.writer.writeError(alloc, msg.id, .{
            .code = if (model_message != null or settings_message != null) ErrorCode.invalid_request else ErrorCode.internal_error,
            .message = model_message orelse settings_message orelse "Failed to load startup state",
        });
    };
    defer startup.deinit(alloc);
    try app_lifecycle.applyWorkspaceLaunch(
        &startup,
        alloc,
        state.cfg.additional_directories,
        state.cfg.saved_directories_suppressed,
    );
    for (startup.config_diagnostics) |diagnostic| {
        if (diagnostic.recovery_path != null) {
            debug_trace.logf("config", "acp startup diagnostic layer={s} cause={s} recovery_available=true", .{
                @tagName(diagnostic.layer),
                @tagName(diagnostic.cause),
            });
        } else {
            debug_trace.logf("config", "acp startup diagnostic layer={s} cause={s}", .{
                @tagName(diagnostic.layer),
                @tagName(diagnostic.cause),
            });
        }
    }

    state.workspace_root = startup.takeWorkspaceRoot();
    state.workspace_access = startup.takeWorkspaceAccess();

    if (state.cfg.model_override) |override| {
        state.selected_model = try alloc.dupe(u8, override);
        alloc.free(startup.takeSelectedModel());
        state.process_model_override = true;
    } else {
        state.selected_model = startup.takeSelectedModel();
        state.process_model_override = startup.model_source == .process_override;
    }
    if (state.cfg.provider_override) |override| {
        state.provider = override;
        state.process_provider_override = true;
    } else {
        state.provider = startup.provider;
        state.process_provider_override = config_runtime.providerEnvOverride() != null;
    }
    state.configured_providers.deinit(alloc);
    state.configured_providers = startup.configured_providers;
    startup.configured_providers = .{};
    state.cfg.provider_set.definitions = state.configured_providers.definitions;
    state.configured_model = try alloc.dupe(u8, startup.configured_model);

    if (state.cfg.auth_mode == .host_managed or hostManagesRoute(state.cfg, state.provider)) {
        state.api_key = &.{};
        state.credential_source = .host_managed;
    } else if (state.provider == .none) {
        // Nothing can answer until a provider is added with /provider.
        state.api_key = &.{};
        state.credential_source = null;
    } else if (!try selectCredentialForProvider(state, state.provider)) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = auth_runtime.missingCredentialText(state.provider),
        });
    }

    state.permission_mode = startup.permission_mode;
    state.agent_step_limit = startup.agent_step_limit;
    state.max_tool_result_bytes = startup.max_tool_result_bytes;
    state.auto_compact_percent = startup.auto_compact_percent;
    state.context_limits = startup.context_limits;
    state.context_limits.applyCommandLine(state.cfg.context_limit_overrides);
    state.toolbox_behind = config_runtime.tool_placement.behindToolbox(startup.tool_placement, state.cfg.tool_placement_overrides);
    state.fast_mode = startup.fast_mode and
        (state.cfg.model_override == null or startup.fast_mode_source != .compiled_default);
    configureUltrafastStartup(state, &startup);
    state.effort = startup.effort;
    state.first_call_tool_choice = startup.first_call_tool_choice;
    state.context_enabled = startup.context_enabled;
    state.session_titles = startup.session_title_generation;
    state.cache_warming = startup.cache_warming;
    state.workspace_capture = startup.workspace_capture;

    var loaded_skills = try app_runtime_setup.loadSkills(alloc, state.workspace_root, builtin_skills.root_policy);
    errdefer loaded_skills.deinit(alloc);
    skill_runtime.traceDiagnostics("acp_startup", loaded_skills.diagnostics);
    try state.skills.replaceLoaded(alloc, loaded_skills.dir, loaded_skills.skills, loaded_skills.diagnostics);
    loaded_skills = .{};

    if (state.provider != .none) {
        const startup_catalog = catalogProviderFor(state, state.provider) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_request,
                .message = "Selected provider is unavailable in this host",
            });
        _ = try resolveSelectedModelCapabilities(state, startup_catalog);
    }

    if (state.cfg.effort_override) |raw| {
        const effort = types.ReasoningEffort.parse(raw) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Invalid reasoning effort",
            });
        if (!try applyEffortOverride(state, alloc, msg, effort)) return;
    }

    if (state.cfg.fast_override) |fast| {
        if (!try applyFastOverride(state, alloc, msg, fast)) return;
    }
    if (!try applyUltrafastOverride(state, alloc, msg, state.ultrafast_mode)) return;

    state.terminal_ui = request.terminal_ui;
    state.client_fs_read = request.client_fs_read;
    state.client_fs_write = request.client_fs_write;
    state.client_terminal = request.client_terminal;
    state.client_notices = request.client_notices;
    state.client_elicitation = request.client_elicitation;
    state.initialized = true;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try acp_types.writeInitializeResponse(&out.writer, .{
        .image_prompts = true,
        .mcp_servers = state.cfg.allow_acp_mcp,
        .steering = true,
        .system_prompt = true,
        // spark takes only what ACP v1 defines and spark's MCP engine speaks: stdio and
        // HTTP.
        .mcp_over_acp = false,
        .mcp_sse = false,
    });
    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());
}

/// The selected model's capabilities from `provider`'s catalog, loading it
/// first if needed. A first load whose request cannot connect gives up after
/// `gateway_provider.catalog_connect_wait_ms`, as `spark ask`'s does, so a
/// dead network doesn't hold up the reply for the 20 to 30 seconds its DNS
/// lookup or connect takes to fail (`CapabilityResolver.resolveWithin`).
fn resolveSelectedModelCapabilities(
    state: *ServerState,
    provider: model_catalog.Provider,
) model_capabilities.ResolveError!model_capabilities.Capabilities {
    var cancel_flag = std.atomic.Value(bool).init(false);
    return state.capability_resolver.resolveWithin(
        state.alloc,
        provider,
        .{
            .access = if (state.cfg.auth_mode == .host_managed)
                .host_managed
            else
                credentials.catalogAccessFor(state.credential_source),
            .endpoint = "",
            .cancel_flag = &cancel_flag,
        },
        state.selected_model,
        state.cfg.provider_set.select(state.provider).fallbackModelCapabilities(state.selected_model),
        gateway_provider.catalog_connect_wait_ms,
    );
}

/// Applies a host-supplied reasoning effort override to sessions created after
/// initialize. A non-default effort must be one of the selected model's
/// advertised efforts whenever the catalog resolves; a catalog outage leaves
/// the override in place, matching turn-time capability fallback. Returns
/// false after writing the rejection response.
fn applyEffortOverride(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message, effort: types.ReasoningEffort) !bool {
    state.effort = effort;
    if (effort.isDefault()) return true;

    const bundle = state.cfg.provider_set.select(state.provider);
    const fallback = bundle.fallbackModelCapabilities(state.selected_model);
    var capabilities: model_capabilities.Capabilities = undefined;
    capabilities = state.capability_resolver.available(state.selected_model, fallback);
    // A failed catalog lookup cannot name the supported set; the turn-time
    // capability check remains the backstop.
    if (state.capability_resolver.state == .failed) return true;

    const rejection = effortOverrideRejection(alloc, capabilities, effort, state.selected_model) catch {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to validate reasoning effort",
        });
        return false;
    };
    if (rejection) |message| {
        defer alloc.free(message);
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = message,
            .data = .{
                .code = "LIBFX_MODEL_UNSUPPORTED_EFFORT",
                .model = state.selected_model,
                .capability = "effort",
            },
        });
        return false;
    }
    return true;
}

/// Pure decision for a host-supplied effort override: returns an owned
/// rejection message naming the model's advertised efforts, or null when the
/// effort is usable. Caller frees the returned slice.
fn effortOverrideRejection(
    alloc: Allocator,
    capabilities: model_capabilities.Capabilities,
    effort: types.ReasoningEffort,
    model: []const u8,
) Allocator.Error!?[]u8 {
    if (model_capabilities.reasoningEffortSupported(capabilities, effort)) return null;
    if (capabilities.reasoning_efforts.len == 0) {
        return try alloc.dupe(u8, "Reasoning effort is unavailable for the active model");
    }
    var set: std.ArrayList(u8) = .empty;
    defer set.deinit(alloc);
    for (capabilities.reasoning_efforts.slice(), 0..) |option, index| {
        if (index > 0) try set.appendSlice(alloc, ", ");
        try set.appendSlice(alloc, option.label());
    }
    return try alloc.print(
        "Reasoning effort \"{s}\" is not available for model \"{s}\" (available: {s})",
        .{ effort.label(), model, set.items },
    );
}

/// Applies a host-supplied fast-lane override to sessions created after
/// initialize. Enabling fast mode requires the selected model to offer a fast
/// path whenever the catalog resolves; a catalog outage leaves the override in
/// place, matching turn-time capability fallback. Disabling is always
/// accepted. Returns false after writing the rejection response.
fn applyFastOverride(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message, fast: bool) !bool {
    state.fast_mode = fast;
    if (!fast) return true;

    const bundle = state.cfg.provider_set.select(state.provider);
    const fallback = bundle.fallbackModelCapabilities(state.selected_model);
    var capabilities: model_capabilities.Capabilities = undefined;
    capabilities = state.capability_resolver.available(state.selected_model, fallback);
    // A failed catalog lookup cannot confirm a fast path; the turn-time
    // capability gate remains the backstop.
    if (state.capability_resolver.state == .failed) return true;

    const rejection = fastOverrideRejection(alloc, capabilities, state.selected_model) catch {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to validate fast mode",
        });
        return false;
    };
    if (rejection) |message| {
        defer alloc.free(message);
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = message,
            .data = .{
                .code = "LIBFX_MODEL_UNSUPPORTED_FAST",
                .model = state.selected_model,
                .capability = "fast",
            },
        });
        return false;
    }
    return true;
}

/// Pure decision for a host-supplied fast override: returns an owned rejection
/// message naming the model, or null when the model offers a fast path. An
/// intrinsically fast model already satisfies the request. Caller frees the
/// returned slice.
fn fastOverrideRejection(
    alloc: Allocator,
    capabilities: model_capabilities.Capabilities,
    model: []const u8,
) Allocator.Error!?[]u8 {
    if (capabilities.supports_fast_mode or capabilities.intrinsic_fast) return null;
    return try alloc.print("Fast mode is not available for model \"{s}\"", .{model});
}

/// Applies a host-supplied ultrafast override before session creation. Unlike
/// fast mode, enabling it requires a verified Gateway catalog capability; a
/// catalog failure cannot silently send an unverified ultrafast request.
fn applyUltrafastOverride(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message, ultrafast: bool) !bool {
    if (!ultrafast) {
        state.ultrafast_mode = false;
        return true;
    }
    const catalog_provider = catalogProviderFor(state, state.provider) orelse
        return writeUltrafastOverrideFailure(state, alloc, msg, "Ultrafast mode is unavailable for the selected provider");
    const capabilities = try resolveSelectedModelCapabilities(state, catalog_provider);
    if (state.capability_resolver.state == .failed) {
        return writeUltrafastOverrideFailure(state, alloc, msg, "Ultrafast mode requires a verified model catalog");
    }
    const rejection = try ultrafastOverrideRejection(alloc, capabilities, state.selected_model);
    if (rejection) |message| {
        defer alloc.free(message);
        return writeUltrafastOverrideFailure(state, alloc, msg, message);
    }
    state.ultrafast_mode = true;
    return true;
}

fn writeUltrafastOverrideFailure(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message, message: []const u8) !bool {
    try state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = message,
        .data = .{
            .code = "LIBFX_MODEL_UNSUPPORTED_ULTRAFAST",
            .model = state.selected_model,
            .capability = "ultrafast",
        },
    });
    return false;
}

/// Pure capability policy: ultrafast needs a model whose catalog offers it.
/// Caller frees a non-null rejection message.
fn ultrafastOverrideRejection(
    alloc: Allocator,
    capabilities: model_capabilities.Capabilities,
    model: []const u8,
) Allocator.Error!?[]u8 {
    if (capabilities.supports_ultrafast_mode) return null;
    return try alloc.print("Ultrafast mode is not available for model \"{s}\"", .{model});
}

const provider_set = @import("../core/gateway/provider_set.zig");
const configured_provider = @import("../core/config/configured_provider.zig");
const catalog_test_provider_json = "{\"local\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"http://localhost:11434/v1\",\"auth\":{\"type\":\"none\"}}}";

/// A provider set whose only configured provider serves `configured_context`,
/// a `model_catalog.Provider`, as its catalog.
fn catalogOnlyBundle(raw: ?*anyopaque, _: *const @import("../core/config/configured_provider.zig").Definition) provider_set.Bundle {
    const catalog: *const model_catalog.Provider = @ptrCast(@alignCast(raw.?));
    return .{ .model_catalog = catalog.* };
}

fn handleCancel(state: *ServerState, notify_client: bool) void {
    if (state.active_session) |*session| {
        debug_trace.eventf("interrupt", "cancel_requested", .{}, "source=acp active_tool_known=false", .{});
        session.turn_cancel.store(true, .seq_cst);
        session.cancel_flag.store(true, .seq_cst);
        // A prompt waiting for its subagents' reports stops waiting.
        state.worker.nudgeWaiter();
    }
    cancelPendingOutbound(state, notify_client);
    clearPendingLegacyUrls(state);
}

pub fn cancelAndReapActivePrompt(state: *ServerState) void {
    handleCancel(state, true);
    reapActivePrompt(state, true);
}

fn handleCloseSession(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid params",
        });
    defer parsed.deinit();
    const requested_id = if (parsed.value == .object)
        if (parsed.value.object.get("sessionId")) |value|
            if (value == .string and value.string.len > 0) value.string else null
        else
            null
    else
        null;
    const session_id = requested_id orelse
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing sessionId",
        });
    const active = if (state.active_session) |*session| session else return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Session is not active",
    });
    if (!std.mem.eql(u8, active.session_id, session_id)) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Session is not active",
        });
    }

    cancelAndReapActivePrompt(state);
    stopSubagentsForSwitch(state);
    closeActiveSession(state) catch |err| {
        debug_trace.logf(
            "session",
            "failed to flush ACP session usage during close session_id={s} err={s}",
            .{ session_id, @errorName(err) },
        );
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to close session cleanly",
        });
    };
    try state.writer.writeResponse(alloc, msg.id, "{}");
}

/// Handles `session/set_config_option`. The `mode` option is modeled in
/// `tests/tla/acp/AcpPermissionModes.tla`, and `fast` and `ultrafast` in
/// `tests/tla/acp/AcpSpeed.tla`.
fn handleSetConfigOption(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid params" });
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Params must be object" });
    if (!try requireParsedActiveSessionTarget(state, alloc, msg.id, root)) return;

    const config_id = blk: {
        if (root.object.get("configId")) |v| {
            if (v == .string) break :blk v.string;
        }
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing configId" });
    };

    const value = blk: {
        if (root.object.get("value")) |v| {
            if (v == .string) break :blk v.string;
        }
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing value" });
    };

    if (std.mem.eql(u8, config_id, "model")) {
        const session = if (state.active_session) |*active| active else return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "No active session",
        });
        session_codec.validateModelPreference(value) catch
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Invalid session model",
            });
        if (session.provider != .none) {
            if (!try selectCredentialForProvider(state, session.provider)) {
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = auth_runtime.missingCredentialText(session.provider),
                });
            }
        }
        // A subagent's turn reads the session's model route under this lock, from its own copy.
        state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        defer state.subagent_authority_mutex.unlock(io_mod.getIo());
        commitActiveSessionModel(
            alloc,
            session,
            value,
        ) catch |err| {
            return state.writer.writeError(alloc, msg.id, .{
                .code = if (err == error.InvalidDurableField)
                    ErrorCode.invalid_params
                else
                    ErrorCode.internal_error,
                .message = if (err == error.InvalidDurableField)
                    "Invalid session model"
                else
                    "Failed to persist session model",
            });
        };
        if (!try dropUnsupportedSpeeds(state, alloc, msg, session)) return;
    } else if (std.mem.eql(u8, config_id, "provider")) {
        const parsed_provider = model_provider.parse(value) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Invalid provider",
            });
        const target = parsed_provider.bind(state.configured_providers) catch
            return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Unknown or changed configured provider" });
        const session = if (state.active_session) |*active| active else return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "No active session",
        });
        if (!target.eql(session.provider)) {
            var staged_credential: ?credentials.Credential = prepareCredentialForProvider(state, target) catch |err| switch (err) {
                error.ProviderCredentialUnavailable => return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = auth_runtime.missingCredentialText(target),
                }),
                else => return err,
            };
            defer if (staged_credential) |*credential| credential.deinit(alloc);
            if (staged_credential) |credential| if (!model_provider.authorizesCredential(target, credential.source)) {
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = "Credential cannot authorize the selected provider",
                });
            };
            const catalog_provider = catalogProviderFor(state, target) orelse
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = "Selected provider is unavailable in this host",
                });
            const access: credentials.CatalogAccess = if (state.cfg.auth_mode == .host_managed)
                .host_managed
            else
                credentials.catalogAccessFor(staged_credential.?.source);
            // Provider selection is independent of earlier prompt cancellation.
            var catalog_cancel_flag = std.atomic.Value(bool).init(false);
            const fetched = try catalog_provider.fetch(alloc, .{
                .access = access,
                .endpoint = "",
                .cancel_flag = &catalog_cancel_flag,
                .view = .picker,
            });
            var catalog = switch (fetched) {
                .catalog => |catalog| catalog,
                .failure => return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = "Failed to load provider model catalog",
                }),
            };
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            var settings = if (state.cfg.home_override) |home|
                try config_runtime.loadMergedSettingsFromHome(alloc, home, state.workspace_root)
            else
                try config_runtime.loadMergedSettings(alloc, state.workspace_root);
            defer settings.deinit(alloc);
            const selected_model = settings.models.get(target) orelse
                return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_request, .message = "Configure a model for the selected provider" });
            // A subagent's turn copies the session's model route under this lock when it starts,
            // so what the switch frees here is nobody's but the server's.
            state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
            defer state.subagent_authority_mutex.unlock(io_mod.getIo());
            commitActiveSessionProvider(
                alloc,
                session,
                target,
                selected_model,
            ) catch {
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.internal_error,
                    .message = "Failed to persist session provider",
                });
            };
            state.capability_resolver.adoptOwnedCatalog(alloc, catalog_provider, access, &catalog);
            if (staged_credential) |*credential| {
                adoptServerCredential(state, credential);
            } else {
                state.credential_source = .host_managed;
                session.credential_source = .host_managed;
                session.api_key = &.{};
            }
            if (!try dropUnsupportedSpeeds(state, alloc, msg, session)) return;
        }
    } else if (std.mem.eql(u8, config_id, "mode")) {
        const session = if (state.active_session) |*active| active else return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "No active session",
        });
        if (!try selectSessionMode(state, alloc, msg, session, value)) return;
    } else if (std.mem.eql(u8, config_id, "ultrafast")) {
        const session = if (state.active_session) |*active| active else return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "No active session",
        });
        const ultrafast = parseConfigBool(value) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Ultrafast mode must be true or false",
            });
        state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        defer state.subagent_authority_mutex.unlock(io_mod.getIo());
        if (!try applyActiveSessionUltrafast(state, alloc, msg, session, ultrafast)) return;
    } else if (std.mem.eql(u8, config_id, "fast")) {
        const session = if (state.active_session) |*active| active else return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "No active session",
        });
        const fast = parseConfigBool(value) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Fast mode must be true or false",
            });
        state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        defer state.subagent_authority_mutex.unlock(io_mod.getIo());
        if (!try applyActiveSessionFast(state, alloc, msg, session, fast)) return;
    } else if (std.mem.eql(u8, config_id, "effort")) {
        const session = if (state.active_session) |*active| active else return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "No active session",
        });
        const effort = types.ReasoningEffort.parse(value) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Invalid reasoning effort",
            });
        const config = sessions.effortConfigState(state) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Reasoning effort is unavailable for the active model",
            });
        if (!sessions.effortSupportedBy(config.efforts, effort)) {
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Reasoning effort is not available for the active model",
            });
        }
        state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        defer state.subagent_authority_mutex.unlock(io_mod.getIo());
        commitActiveSessionEffort(session, effort) catch {
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.internal_error,
                .message = "Failed to persist session effort",
            });
        };
    } else {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Unknown config option",
        });
    }

    try refreshModelCatalogForOptions(state);
    const current_model = if (state.active_session) |s| s.model else state.selected_model;
    const current_mode: []const u8 = if (state.active_session) |s| s.mode else state.cfg.mode_registry.default_mode_id;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"configOptions\":[");
    try sessions.writeProviderConfigOption(
        &out.writer,
        if (state.active_session) |session| session.provider else state.provider,
        state.configured_providers.definitions,
    );
    try out.writer.writeAll(",");
    try sessions.writeModelConfigOption(
        &out.writer,
        current_model,
        state.capability_resolver.catalogEntries(),
    );
    try out.writer.writeAll(",");
    try sessions.writeModeConfigOption(&out.writer, state.cfg.mode_registry, current_mode);
    if (sessions.effortConfigState(state)) |config| {
        try out.writer.writeAll(",");
        try sessions.writeEffortConfigOption(&out.writer, config.efforts, config.current);
    }
    if (sessions.fastConfigState(state)) |current| {
        try out.writer.writeAll(",");
        try sessions.writeFastConfigOption(&out.writer, current);
    }
    if (sessions.ultrafastConfigState(state)) |current| {
        try out.writer.writeAll(",");
        try sessions.writeUltrafastConfigOption(&out.writer, current);
    }
    try out.writer.writeAll("]}");
    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());
}

/// Loads the catalog when it is due, before a reply that lists its models. A
/// due load whose request cannot connect gives up after
/// `gateway_provider.catalog_connect_wait_ms` and keeps the catalog spark
/// already has (`CapabilityResolver.refreshWithin`), so a dead network does
/// not hold up the reply, or the prompt sent after it, for the 20 to 30
/// seconds its DNS lookup or connect takes to fail.
pub fn refreshModelCatalogForOptions(state: *ServerState) !void {
    const active = if (state.active_session) |*session| session else return;
    const provider = catalogProviderFor(state, active.provider) orelse return;
    std.debug.assert(state.active_prompt == null);
    // A refresh replaces the catalog's entries. A working subagent reads its
    // own copy of the catalog (`ModelRoute` in prompt.zig), so a refresh frees
    // nothing it reads. The refresh is skipped while a subagent works, so that
    // a reload and a model option leave the catalog as it is for the run. It
    // is not run again when the subagent ends: a refresh that was due stays
    // due, and the next call that finds no subagent working makes it. A
    // switch of the provider, which must replace the catalog, does it under
    // `subagent_authority_mutex` in `handleSetConfigOption`.
    if (state.subagent_host) |subagents| if (!subagents.quiet()) {
        debug_trace.logf("acp", "event=model_catalog_refresh_skipped session={s} reason=subagents_working", .{active.session_id});
        return;
    };
    // Restoring the same session can leave its previous cancellation flag set.
    var cancel_flag = std.atomic.Value(bool).init(false);
    try state.capability_resolver.refreshWithin(state.alloc, provider, .{
        .access = if (state.cfg.auth_mode == .host_managed)
            .host_managed
        else
            credentials.catalogAccessFor(active.credential_source),
        .endpoint = "",
        .cancel_flag = &cancel_flag,
    }, gateway_provider.catalog_connect_wait_ms);
}

fn commitActiveSessionProvider(
    alloc: Allocator,
    session: *ActiveSessionState,
    provider: model_provider.ProviderId,
    model: []const u8,
) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const staged_model = try alloc.dupe(u8, model);
    errdefer alloc.free(staged_model);
    const v2 = session.v2 orelse return error.SessionPersistenceUnavailable;
    try setV2Preferences(v2, session, provider, model, session.effort);
    alloc.free(session.model);
    session.model = staged_model;
    session.provider = provider;
}

/// A v2 session stores its preferences as one value, so every change
/// writes the whole set.
fn setV2Preferences(
    v2: *session_adapter.Session,
    session: *const ActiveSessionState,
    provider: model_provider.ProviderId,
    model: []const u8,
    effort: types.ReasoningEffort,
) !void {
    var durable = try v2.currentPreferences(v2.alloc);
    defer durable.deinit(v2.alloc);
    try v2.setPreferences(.{
        .provider = provider,
        .model = @constCast(model),
        .effort = effort,
        .fast_mode = session.fast_mode,
        .ultrafast_mode = durable.ultrafast_mode,
    });
}

fn commitActiveSessionModel(
    alloc: Allocator,
    session: *ActiveSessionState,
    value: []const u8,
) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    if (session.v2) |v2| {
        const staged_model = try alloc.dupe(u8, value);
        errdefer alloc.free(staged_model);
        try setV2Preferences(v2, session, session.provider, value, session.effort);
        alloc.free(session.model);
        session.model = staged_model;
        return;
    }
    return error.SessionPersistenceUnavailable;
}

fn commitActiveSessionEffort(
    session: *ActiveSessionState,
    effort: types.ReasoningEffort,
) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const v2 = session.v2 orelse return error.SessionPersistenceUnavailable;
    try setV2Preferences(v2, session, session.provider, session.model, effort);
    session.effort = effort;
}

fn parseConfigBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

/// Applies a strict ultrafast-mode transition to the active session. Every
/// enabled request is admitted against its current provider/model capability.
fn applyActiveSessionUltrafast(
    state: *ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    session: *ActiveSessionState,
    ultrafast: bool,
) !bool {
    if (ultrafast) {
        const bundle = state.cfg.provider_set.select(session.provider);
        const capabilities = state.capability_resolver.available(
            session.model,
            bundle.fallbackModelCapabilities(session.model),
        );
        const rejection = try ultrafastOverrideRejection(alloc, capabilities, session.model);
        if (rejection) |message| {
            defer alloc.free(message);
            try state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = message,
                .data = .{
                    .code = "LIBFX_MODEL_UNSUPPORTED_ULTRAFAST",
                    .model = session.model,
                    .capability = "ultrafast",
                },
            });
            return false;
        }
        // Fast and Ultrafast are exclusive, as in the CLI.
        if (session.fast_mode and !try storeSessionFast(state, alloc, msg, session, false)) return false;
    }
    return storeSessionUltrafast(state, alloc, msg, session, ultrafast);
}

/// Saves the session's ultrafast preference without admission checks.
/// Returns false after writing the error response.
fn storeSessionUltrafast(
    state: *ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    session: *ActiveSessionState,
    ultrafast: bool,
) !bool {
    commitActiveSessionUltrafast(alloc, session, ultrafast) catch {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to persist session ultrafast preference",
        });
        return false;
    };
    return true;
}

/// Applies a Fast-mode transition to the active session, mirroring the CLI's
/// `/fast`: enabling requires the model's Fast lane and turns Ultrafast off;
/// disabling always succeeds. Returns false after writing the error response.
fn applyActiveSessionFast(
    state: *ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    session: *ActiveSessionState,
    fast: bool,
) !bool {
    if (fast) {
        if (!activeSessionCapabilities(state, session).supports_fast_mode) {
            const message = try alloc.print("Fast mode is not available for model \"{s}\"", .{session.model});
            defer alloc.free(message);
            try state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = message,
                .data = .{
                    .code = "LIBFX_MODEL_UNSUPPORTED_FAST",
                    .model = session.model,
                    .capability = "fast",
                },
            });
            return false;
        }
        if (session.ultrafast_mode and !try storeSessionUltrafast(state, alloc, msg, session, false)) return false;
    }
    return storeSessionFast(state, alloc, msg, session, fast);
}

/// Saves the session's fast preference without admission checks.
/// Returns false after writing the error response.
fn storeSessionFast(
    state: *ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    session: *ActiveSessionState,
    fast: bool,
) !bool {
    commitActiveSessionFast(alloc, session, fast) catch {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to persist session fast preference",
        });
        return false;
    };
    return true;
}

fn commitActiveSessionFast(alloc: Allocator, session: *ActiveSessionState, fast: bool) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const v2 = session.v2 orelse return error.SessionPersistenceUnavailable;
    var preferences = try v2.currentPreferences(alloc);
    defer preferences.deinit(alloc);
    preferences.fast_mode = fast;
    try v2.setPreferences(preferences);
    session.fast_mode = fast;
}

fn activeSessionCapabilities(state: *ServerState, session: *const ActiveSessionState) model_capabilities.Capabilities {
    const bundle = state.cfg.provider_set.select(session.provider);
    return state.capability_resolver.available(session.model, bundle.fallbackModelCapabilities(session.model));
}

const SessionSpeed = struct {
    fast: bool,
    ultrafast: bool,
};

/// Pure policy: the lanes a session keeps after switching to a model with
/// `capabilities`.
fn speedSupportedBy(
    speed: SessionSpeed,
    capabilities: model_capabilities.Capabilities,
) SessionSpeed {
    return .{
        .fast = speed.fast and capabilities.supports_fast_mode,
        .ultrafast = speed.ultrafast and capabilities.supports_ultrafast_mode,
    };
}

/// After a model or provider switch, turns off any lane the new model lacks,
/// like the CLI model picker. A hidden lane would otherwise stay on: Ultrafast
/// would fail the next prompt and Fast would return on a later switch back.
/// Returns false after writing the error response.
fn dropUnsupportedSpeeds(
    state: *ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    session: *ActiveSessionState,
) !bool {
    const kept = speedSupportedBy(
        .{ .fast = session.fast_mode, .ultrafast = session.ultrafast_mode },
        activeSessionCapabilities(state, session),
    );
    if (session.ultrafast_mode and !kept.ultrafast) {
        debug_trace.logf("acp", "ultrafast mode turned off: model={s} does not offer it", .{session.model});
        if (!try storeSessionUltrafast(state, alloc, msg, session, false)) return false;
    }
    if (session.fast_mode and !kept.fast) {
        debug_trace.logf("acp", "fast mode turned off: model={s} does not offer it", .{session.model});
        if (!try storeSessionFast(state, alloc, msg, session, false)) return false;
    }
    return true;
}

fn commitActiveSessionUltrafast(
    alloc: Allocator,
    session: *ActiveSessionState,
    ultrafast: bool,
) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const v2 = session.v2 orelse return error.SessionPersistenceUnavailable;
    var preferences = try v2.currentPreferences(alloc);
    defer preferences.deinit(alloc);
    preferences.ultrafast_mode = ultrafast;
    try v2.setPreferences(preferences);
    session.ultrafast_mode = ultrafast;
}

/// Handles the older `session/set_mode`, modeled with the `mode` option in
/// `tests/tla/acp/AcpPermissionModes.tla`.
fn handleSetMode(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid params" });
    defer parsed.deinit();

    if (!try requireParsedActiveSessionTarget(state, alloc, msg.id, parsed.value)) return;

    const mode_id = modeId: {
        if (parsed.value != .object) break :modeId null;
        const value = parsed.value.object.get("modeId") orelse break :modeId null;
        break :modeId if (value == .string) value.string else null;
    } orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing modeId",
    });
    const session = if (state.active_session) |*active| active else return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_request,
        .message = "No active session",
    });
    if (!try selectSessionMode(state, alloc, msg, session, mode_id)) return;

    try state.writer.writeResponse(alloc, msg.id, "null");
}

/// Switches the session to a registered mode. Returns null and leaves the
/// session unchanged when `id` is not registered.
pub fn applySessionMode(registry: mode_registry.Registry, session: *ActiveSessionState, id: []const u8) ?*const mode_registry.ModeSpec {
    const mode = registry.lookup(id) orelse return null;
    session.mode = mode.id;
    session.permission_mode = mode.permission_mode;
    return mode;
}

/// Applies a client's mode choice to the active session and saves it as the
/// profile's permission mode, like the CLI's /permissions. Writes an error
/// and returns false for a mode the registry does not list.
fn selectSessionMode(
    state: *ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    session: *ActiveSessionState,
    id: []const u8,
) !bool {
    const applied = blk: {
        state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        defer state.subagent_authority_mutex.unlock(io_mod.getIo());
        break :blk applySessionMode(state.cfg.mode_registry, session, id);
    };
    const mode = applied orelse {
        try state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Unknown mode" });
        return false;
    };
    saveSessionPermissionMode(state, alloc, mode.permission_mode);
    return true;
}

/// Saves a chosen permission mode to the profile so new sessions, here and
/// in other spark processes, start in it. Hosts without a profile keep it for
/// this process only.
fn saveSessionPermissionMode(state: *ServerState, alloc: Allocator, mode: types.PermissionMode) void {
    state.permission_mode = mode;
    const label = permissions.permissionModeLabel(mode);
    const home = state.cfg.home_override orelse io_mod.homeDir() orelse {
        debug_trace.logf("acp", "permission_mode_save_failed mode={s} err=HomeNotSet", .{label});
        return;
    };
    var attempt = config_runtime.attemptUserPreferencesInHome(alloc, home, .{ .permission_mode = mode });
    defer attempt.deinit(alloc);
    switch (attempt) {
        .outcome => |outcome| debug_trace.logf("acp", "permission_mode_saved mode={s} outcome={s}", .{ label, @tagName(outcome) }),
        .failure => |failure| debug_trace.logf("acp", "permission_mode_save_failed mode={s} err={s}", .{ label, @errorName(failure.err) }),
    }
}

/// The mode a session starts in and the permission mode it enforces.
pub const StartingMode = struct {
    id: []const u8,
    permission_mode: types.PermissionMode,
};

/// Reads the saved permission mode as it is now, so a running process
/// follows a mode another spark process saved, and returns the registered mode
/// that applies it, or the default mode when none does.
pub fn loadStartingMode(state: *ServerState, alloc: Allocator) StartingMode {
    if (state.workspace_root.len > 0) {
        if (app_lifecycle.loadSavedPermissionMode(alloc, state.cfg.home_override, state.workspace_root)) |saved| {
            state.permission_mode = saved;
        } else |err| {
            debug_trace.logf("acp", "permission_mode_reload_failed kept={s} err={s}", .{
                permissions.permissionModeLabel(state.permission_mode),
                @errorName(err),
            });
        }
    }
    // `spark acp --permission-mode` beats the saved mode, as SPARK_PERMISSION_MODE does.
    if (state.cfg.permission_override) |mode| state.permission_mode = mode;
    return .{
        .id = state.cfg.mode_registry.startingModeId(state.permission_mode),
        .permission_mode = state.permission_mode,
    };
}
