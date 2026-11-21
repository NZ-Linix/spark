const std = @import("std");
const toolbox = @import("toolbox.zig");
const observation = @import("../agent/runtime/observation.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const builtin = @import("builtin");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const host_mod = @import("../hosts/host.zig");
const command_contract = @import("../execution/command_contract.zig");
const command_environment = @import("../execution/command_environment.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const tool_contracts = @import("../agent/runtime/tool_contracts.zig");
const result_commit = @import("result_commit.zig");
const vision_executor = @import("../agent/runtime/vision_executor.zig");
const image_provider = @import("../agent/runtime/image_provider.zig");
const change_tracker = @import("../workspace/change_tracker.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation = @import("file_mutation.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const hooks = @import("../hooks/hooks.zig");
const model_context_encoding = @import("../shared/model_context_encoding.zig");
const permissions = @import("../permissions/permissions.zig");
const glob_pattern = @import("../workspace/glob_pattern.zig");
const command_admission = @import("../permissions/command_admission.zig");
const pathing = @import("../workspace/pathing.zig");
const execution_router = @import("../execution/router.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const subagent_model_contract = @import("../subagent/model_contract.zig");
const subagent_refusal = @import("../subagent/refusal.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const subagent_tool_provider = @import("../subagent/tool_provider.zig");
const session_runtime = @import("../session/session.zig");
const session_child_store = @import("../session/session_child_store.zig");
const command_replay_store = @import("../session/command_replay_store.zig");
const session_store = @import("../session/session_store.zig");
const text_utils = @import("../shared/text_utils.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const mcp_access_policy = @import("../mcp/access_policy.zig");
const tool_admission = @import("tool_admission.zig");
const tool_args = @import("tool_args.zig");
const command_result_mapping = @import("command_result_mapping.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_specs = @import("tool_specs.zig");
const tool_result_errors = @import("tool_result_errors.zig");
const tool_result_limits = @import("tool_result_limits.zig");
const compactor = @import("../compactor/compactor.zig");
const file_mutation_execution = @import("file_mutation_execution.zig");
const tool_mcp_registry = @import("tool_mcp_registry.zig");
const tool_mcp_runtime = @import("tool_mcp_runtime.zig");
const mcp_call_capability = @import("mcp_call_capability.zig");
const model_tool_schema = @import("model_tool_schema.zig");
const capability_retrieval = @import("capability_retrieval.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const lexical_relevance = @import("../shared/lexical_relevance.zig");
const mcp_tool_lookup = @import("../mcp/tool_lookup.zig");
const tool_presentation = @import("tool_presentation.zig");
const shell_impl = @import("../../tools/shell/shell.zig");
const shell_resolver = @import("../terminal/shell_resolver.zig");
const web_fetch_runtime = @import("web_fetch_runtime.zig");
const web_search_contract = @import("web_search_contract.zig");
const web_fetch_artifacts = @import("../session/web_fetch_artifacts.zig");
const types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");
const provider_set = @import("../gateway/provider_set.zig");
const credential_authority = @import("../auth/credential_authority.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const context_contract = @import("../workspace/context_contract.zig");
const test_builtin_tools = if (builtin.is_test)
    @import("../../builtins/tools.zig")
else
    struct {};

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const ChatMessage = types.ChatMessage;

const PermissionMode = types.PermissionMode;
const ToolPermissionDecision = types.ToolPermissionDecision;
const ToolExecutionResult = tool_contracts.ToolExecutionResult;
const SessionRuntime = session_runtime.SessionRuntime;
const WorkerRuntime = worker_runtime.WorkerRuntime;

const helpers = struct {
    const requiredStringArg = tool_args.requiredStringArg;
    const parseToolArgsObject = tool_args.parseToolArgsObject;
};

const parseToolArgsObject = helpers.parseToolArgsObject;
const context_limits = @import("../config/context_limits.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const host_capabilities = @import("../hosts/host.zig");
const terminal_client_runtime = @import("../terminal/client.zig");
const terminal_managed_observer = @import("../terminal/managed_observer.zig");

test {
    _ = tool_admission;
    _ = command_result_mapping;
    _ = @import("../session/command_replay_store.zig");
    _ = @import("../session/result_store.zig");
    _ = file_mutation_execution;
    _ = tool_presentation;
}

/// Shows tool rows: a host's push of tool lifecycle events, and where it
/// keeps the row of a call made through `spark mcp call`, so a resume shows it
/// again. Null keeps none.
pub const ToolLifecyclePublisher = struct {
    context: *anyopaque,
    push_fn: *const fn (*anyopaque, types.ToolLifecycleEvent) anyerror!void,
    save_bridge_call_fn: ?*const fn (*anyopaque, types.BridgeCallRecord) anyerror!void = null,

    pub fn push(self: ToolLifecyclePublisher, event: types.ToolLifecycleEvent) anyerror!void {
        return self.push_fn(self.context, event);
    }

    pub fn saveBridgeCall(self: ToolLifecyclePublisher, record: types.BridgeCallRecord) anyerror!void {
        const save = self.save_bridge_call_fn orelse return;
        return save(self.context, record);
    }
};

pub const Context = struct {
    observer: ?*observation.Observer = null,
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
    ignored_list_entries: []const []const u8,
    max_list_entries: usize,
    max_read_file_bytes: usize,
    max_read_file_lines: usize,
    max_read_file_line_len: usize,
    max_command_output_bytes: usize,
    max_tool_result_bytes: usize = tool_result_limits.default_max_tool_result_bytes,
    /// Passed to subagent turns. See `Config.auto_compact_percent`.
    auto_compact_percent: u8 = compactor.default_percent,
    api_key: []const u8,
    agent_stream_provider: agent_stream_provider.Provider = agent_stream_provider.unavailable_provider,
    gateway_team: ?[]const u8 = null,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]const u8 = null,
    provider: model_provider.ProviderId = .none,
    provider_capabilities: provider_set.Bundle.Capabilities = .{
        .vision_fallback = true,
    },
    oauth_transport: oauth_transport.Provider = oauth_transport.unavailable_provider,
    secret_store: host_mod.SecretStore = host_mod.unavailable_secret_store,
    model: []const u8,
    root_user_intent_context: []const u8 = "",
    root_user_messages: []const []const u8 = &.{},
    root_user_evidence_complete: bool = false,
    current_turn_messages: []const ChatMessage = &.{},
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    gateway_models_path: []const u8 = "/v1/models",
    agent_step_limit: usize,
    fast_mode: bool = false,
    ultrafast_mode: bool = false,
    effort: types.ReasoningEffort = .auto,
    /// Borrowed gateway provider routing inherited by subagent turns. Never
    /// applied to tool-internal provider requests (vision, web search), which
    /// keep gateway-default routing.
    first_call_tool_choice: types.ToolChoice = .auto,
    tool_registry: tool_dispatch.Registry = .{},
    host_tool_provider: ?tool_dispatch.HostToolProvider = null,
    subagent_host: ?*subagent_tool_host.Runtime = null,
    subagent_caller_id: ?[]const u8 = null,
    permission_mode: PermissionMode,
    worker: *WorkerRuntime,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    session: *SessionRuntime,
    session_allocator: Allocator = std.heap.c_allocator,
    skills_dir: []const u8 = "",
    skill_locations: ?*const skill_contract.Locations = null,
    context_limits: context_limits.Values = .{},
    context_registry: context_contract.Registry,
    context_enabled: bool = true,
    output_chunk_lifecycle_id: ?types.ToolLifecycleId = null,
    /// The row group of the call `output_chunk_lifecycle_id` names.
    output_chunk_presentation_group_id: ?types.ToolPresentationGroupId = null,
    output_chunk_ctx: *anyopaque,
    on_output_chunk: command_contract.CommandOutputCallback,
    command_artifact_dir: ?[]const u8 = null,
    tool_result_dir: ?[]const u8 = null,
    session_child_capability: ?*session_child_store.SessionChildCapability = null,
    ephemeral_command_replay: ?*command_replay_store.EphemeralStore = null,
    terminal_client: ?*terminal_client_runtime.Runtime = null,
    managed_executions: ?*managed_execution.Runtime = null,
    command_timeout_ms: ?usize = null,
    command_timeout_started_ms: ?i64 = null,
    command_replay_capture: ?*command_replay_store.Capture = null,
    command_replay_unavailable: bool = false,
    tracker: ?*change_tracker.ChangeTracker = null,
    mcp_ctx: ?*anyopaque = null,
    mcp_has_tool: ?tool_mcp_runtime.HasToolFn = null,
    mcp_access_changed: ?tool_mcp_runtime.AccessChangedFn = null,
    mcp_validate_tool: ?tool_mcp_runtime.ValidateToolFn = null,
    mcp_call_tool: ?tool_mcp_runtime.CallToolFn = null,
    mcp_search_tools: ?tool_mcp_runtime.SearchToolsFn = null,
    mcp_tool_schema: ?tool_mcp_runtime.ToolSchemaFn = null,
    mcp_snapshot_tool: ?tool_mcp_runtime.SnapshotToolFn = null,
    expected_mcp_runtime_generation: ?u64 = null,
    expected_mcp_binding: ?types.McpToolBinding = null,
    mcp_access: tool_mcp_runtime.Access = .unrestricted,
    mcp_input_responder: ?tool_mcp_runtime.InputResponder = null,
    mcp_progress_ctx: ?*anyopaque = null,
    on_mcp_progress: ?*const fn (*anyopaque, types.ToolLifecycleId, []const u8) void = null,
    tool_progress_ctx: ?*anyopaque = null,
    on_tool_progress: ?*const fn (*anyopaque, types.ToolLifecycleId, []const u8) void = null,
    /// Where a tool call shows rows for tool calls it makes itself: the MCP
    /// calls of an `spark mcp call` its command runs. Null shows none.
    nested_tool_lifecycle: ?ToolLifecyclePublisher = null,
    subagent_status_renderer: ?types.SubagentStatusRenderer = null,
    advertised_dynamic_tool_names: []const []const u8 = &.{},
    /// The built-in tools this agent offers through toolbox.
    toolbox_behind: []const []const u8 = &.{},
    /// The MCP servers the toolbox menu lists.
    toolbox_mcp_servers: []const []const u8 = &.{},
    web_fetch_runtime: ?*web_fetch_runtime.Runtime = null,
    web_fetch_artifact_store: ?*web_fetch_artifacts.Store = null,
    web_fetch_artifact_error: ?anyerror = null,
    web_search_runtime_ready: bool = false,
    web_search_backend: ?tool_dispatch.WebSearchBackend = null,
    web_search_progress_ctx: ?*anyopaque = null,
    on_web_search_progress: ?tool_dispatch.WebSearchProgressFn = null,
    web_fetch_progress_ctx: ?*anyopaque = null,
    on_web_fetch_progress: ?tool_dispatch.WebFetchProgressFn = null,
    host_sandbox_default: tool_admission.HostSandboxDefault = .none,
    model_capability_resolver: ?model_capabilities.Resolver = null,
    model_override_resolver: ?subagent_tool_host.ModelOverrideResolver = null,
    /// False when running outside an interactive TUI (e.g. ACP). Tools
    /// that require a live user (like `ask_user_question`) short-circuit
    /// in that case.
    interactive: bool = true,
    /// Lets a turn that is not interactive still ask the user questions: a
    /// subagent's, whose questions show on its own screen and on main's.
    ask_user_questions: bool = false,
    lifecycle_view: hooks.RuntimeView = hooks.RuntimeView.empty(),
    lifecycle_scope: hooks.Scope = .{
        .kind = .interactive,
        .workspace_root = "",
    },

    /// Projects only the borrowed capabilities consumed by admission.
    pub fn admissionInput(self: Context) tool_admission.Input {
        return .{
            .workspace_root = self.workspace_root,
            .access_scope = self.access_scope,
            .tool_registry = self.tool_registry,
            .advertised_dynamic_tool_names = self.advertised_dynamic_tool_names,
            .mcp_runtime = mcpRuntimeCapabilities(self),
            .context_limits = self.context_limits,
        };
    }

    pub fn admissionInputWithLiveAuthority(
        self: Context,
        authority: ?tool_contracts.LiveToolAuthority,
    ) tool_admission.Input {
        var input = self.admissionInput();
        if (authority) |live| input.advertised_dynamic_tool_names = live.integrations;
        return input;
    }
};

fn registeredToolSpec(ctx: Context, name: []const u8) ?*const tool_specs.ToolSpec {
    return ctx.tool_registry.lookup(name);
}

fn providerDisablesTool(capabilities: provider_set.Bundle.Capabilities, name: []const u8) bool {
    return std.mem.eql(u8, name, "vision") and
        !capabilities.vision_fallback;
}

pub fn validateToolCall(ctx: Context, arena: Allocator, call: ToolCall) !tool_contracts.ToolCallValidationResult {
    if (providerDisablesTool(ctx.provider_capabilities, call.name)) {
        return .{ .failure = try arena.dupe(u8, "Unsupported tool: vision") };
    }
    const spec = registeredToolSpec(ctx, call.name) orelse {
        return switch (try tool_mcp_runtime.validateAdvertisedDynamicTool(.{
            .is_registered_tool = false,
            .advertised_dynamic_tool_names = ctx.advertised_dynamic_tool_names,
            .runtime = mcpRuntimeCapabilities(ctx),
        }, arena, call.name, call.arguments_json)) {
            .valid => |generation| .{ .valid = .{ .mcp_runtime_generation = generation } },
            .invalid => |reason| .{ .failure = reason },
            .not_available => .not_registered,
        };
    };
    switch (spec.executor_kind) {
        // An MCP tool's server checks its arguments when it runs.
        .mcp_tool => return .{ .valid = .{} },
        // File mutation arguments are decoded once by shared permission preflight.
        .write_file, .edit_file => return .{ .valid = .{} },
        else => {},
    }

    var dispatch_ctx = typedDispatchContext(ctx, arena);
    dispatch_ctx.captured_command_host = spec.captured_command_host;
    return switch (try tool_dispatch.validateRegisteredToolCall(dispatch_ctx, ctx.tool_registry, call)) {
        .not_registered => .not_registered,
        .valid => .{ .valid = .{} },
        .failure => |reason| .{ .failure = reason },
    };
}

pub fn checkToolAvailability(ctx: Context, arena: Allocator, call: ToolCall) !?[]const u8 {
    if (providerDisablesTool(ctx.provider_capabilities, call.name)) {
        return try arena.dupe(u8, "Unsupported tool: vision");
    }
    return tool_dispatch.localToolAvailabilityFailureForCall(
        typedDispatchContext(ctx, arena),
        ctx.tool_registry,
        call,
    );
}

pub fn executeToolCallAuthorized(
    ctx: Context,
    request: tool_contracts.ToolExecutionRequest,
) !ToolExecutionResult {
    var replay_continuation_transferred = request.command_replay_capture == null;
    defer if (!replay_continuation_transferred) {
        request.command_replay_capture.?.abort(request.result_allocator);
    };
    var execution_ctx = ctx;
    execution_ctx.observer = request.observer orelse ctx.observer;
    execution_ctx.toolbox_behind = request.toolbox_behind;
    execution_ctx.toolbox_mcp_servers = request.toolbox_mcp_servers;
    execution_ctx.skill_locations = request.skill_locations orelse ctx.skill_locations;
    if (request.permission_mode) |permission_mode| {
        execution_ctx.permission_mode = permission_mode;
    }
    if (request.live_authority) |authority| {
        if (!containsName(authority.tools, request.call.name) and
            !containsName(authority.integrations, request.call.name))
        {
            return tool_contracts.failToolExecutionResult(
                error.LiveToolAuthorityUnavailable,
            );
        }
        execution_ctx.permission_mode = authority.permission_mode;
        execution_ctx.advertised_dynamic_tool_names = authority.integrations;
        execution_ctx.mcp_access = rebindMcpAuthorityGeneration(
            execution_ctx.mcp_access,
            authority.generation,
        );
    } else {
        execution_ctx.advertised_dynamic_tool_names =
            request.advertised_dynamic_tool_names;
    }
    execution_ctx.max_tool_result_bytes = request.max_tool_result_bytes;
    execution_ctx.expected_mcp_runtime_generation = request.expected_mcp_runtime_generation;
    execution_ctx.expected_mcp_binding = request.expected_mcp_binding;
    execution_ctx.current_turn_messages = request.current_turn_messages;
    execution_ctx.output_chunk_lifecycle_id = request.lifecycle_id;
    execution_ctx.output_chunk_presentation_group_id = request.presentation_group_id;
    execution_ctx.command_timeout_started_ms = request.command_timeout_started_ms;
    execution_ctx.command_replay_capture = request.command_replay_capture;
    execution_ctx.command_replay_unavailable = request.command_replay_unavailable;

    const started_at_ms = io_mod.milliTimestamp();
    const call_dir = workspace_access.AccessScope.primaryDirectoryOf(
        execution_ctx.access_scope,
        execution_ctx.workspace_root,
    );
    const uses_file_mutation_contract = if (registeredToolSpec(
        execution_ctx,
        request.call.name,
    )) |spec|
        spec.take_file_mutation_input_fn != null
    else
        false;
    const result = (if (comptime builtin.target.os.tag == .wasi)
        executeWorkspaceToolCallInner(
            execution_ctx,
            request.result_allocator,
            request.call,
            request.authority,
            request.classification_complete,
        )
    else if (uses_file_mutation_contract)
        file_mutation_execution.execute(.{
            .call_allocator = request.call_allocator,
            .result_allocator = request.result_allocator,
            .call = request.call,
            .authorization = switch (request.authority) {
                .file_mutation => |value| value,
                else => null,
            },
            .maybe_cancel_flag = execution_ctx.cancel_flag,
            .lifecycle_id = request.lifecycle_id,
        })
    else
        executeToolCallInner(
            execution_ctx,
            request.result_allocator,
            request.call,
            request.authority,
            request.classification_complete,
            request.authorized_image_catalog,
        )) catch |err| {
        diagnostics.recordToolCallResult(.{
            .name = request.call.name,
            .arguments_json = request.call.arguments_json,
            .model_output = "",
            .outcome = classifyToolExecutionError(err),
            .started_at_ms = started_at_ms,
            .subagent_id = execution_ctx.lifecycle_scope.subagent_id orelse 0,
            .call_id = request.call.id,
            .dir = call_dir,
            // The tool returned no result, so nothing shows that a command
            // ran: a run cancelled or out of time before it started ends here,
            // as does a shell that could not start.
            .reads_startup_files = false,
        });
        return if (err == error.CancelledBeforeExecution) error.Cancelled else err;
    };
    const outcome = classifyReturnedToolCallOutcome(result);
    diagnostics.recordToolCallResult(.{
        .name = request.call.name,
        .arguments_json = request.call.arguments_json,
        .model_output = result.model_output,
        .outcome = outcome,
        .started_at_ms = started_at_ms,
        .subagent_id = execution_ctx.lifecycle_scope.subagent_id orelse 0,
        .call_id = request.call.id,
        .dir = call_dir,
        // Only a command that ran leaves a command result, which makes the call
        // `command_failed`; a call refused before its command started, and one
        // that succeeded, are not resolved again.
        .reads_startup_files = outcome == .command_failed and
            callReadsStartupFiles(execution_ctx, request.call_allocator, request.call),
    });
    if (request.command_replay_capture) |continued| {
        replay_continuation_transferred = result.command_replay_capture == continued;
    }
    return result;
}

/// Whether `call` is a run whose command reads the startup files the shell
/// snapshot holds: one that admission's `runCommandContext` resolves to the
/// `user` environment, as its routine-command rule does, in the login shell
/// the snapshot captures. `interact` and `stop` calls, a `clean` profile, a
/// clean start, a tty run in another shell, and a call that does not resolve
/// read none of them.
fn callReadsStartupFiles(ctx: Context, alloc: Allocator, call: ToolCall) bool {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const command = tool_admission.runCommandContext(ctx.admissionInput(), arena, call) catch return false;
    const shell = switch (command.environment) {
        .user => |path| path,
        else => return false,
    };
    var login_shell_buffer: [4096]u8 = undefined;
    const configured = shell_resolver.configuredLoginShellInto(&login_shell_buffer);
    const login = switch (shell_resolver.environment(arena, configured, null) catch return false) {
        .user => |path| path,
        else => return false,
    };
    return sameShellPath(arena, shell, login);
}

/// Whether two shell paths name one file, as `/bin/bash` and `/usr/bin/bash`
/// do where `/bin` links to `/usr/bin`. A path that does not resolve matches
/// only itself.
fn sameShellPath(arena: Allocator, a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const real_a = io_mod.realpathAlloc(arena, a) catch return false;
    const real_b = io_mod.realpathAlloc(arena, b) catch return false;
    return std.mem.eql(u8, real_a, real_b);
}

fn classifyToolExecutionError(err: anyerror) diagnostics.ToolCallOutcome {
    return switch (err) {
        error.CancelledBeforeExecution => .rejected,
        error.Cancelled => .tool_failed,
        else => .runtime_failed,
    };
}

fn classifyReturnedToolCallOutcome(
    result: ToolExecutionResult,
) diagnostics.ToolCallOutcome {
    if (result.status == .success) return .succeeded;
    if (result.command_result_json != null) return .command_failed;
    // Only an explicit denial records a rejection. An authorized execution
    // that failed — with or without a declared kind — is a tool failure, so
    // a producer that forgets to declare a kind cannot silently masquerade
    // as a rejection in diagnostics.
    return switch (result.failure_kind) {
        .denied => .rejected,
        .none, .preflight, .apply => .tool_failed,
    };
}

test "returned tool results retain diagnostic outcome identity" {
    const success = ToolExecutionResult{ .model_output = "ok" };
    const rejection = ToolExecutionResult{
        .model_output = "rejected",
        .status = .failure,
        .failure_kind = .denied,
    };
    const command_failure = ToolExecutionResult{
        .model_output = "exit 7",
        .status = .failure,
        .command_result_json = "{\"exit_code\":7}",
    };
    const tool_failure = ToolExecutionResult{ .model_output = "missing", .status = .failure };

    try std.testing.expectEqual(
        diagnostics.ToolCallOutcome.succeeded,
        classifyReturnedToolCallOutcome(success),
    );
    try std.testing.expectEqual(
        diagnostics.ToolCallOutcome.rejected,
        classifyReturnedToolCallOutcome(rejection),
    );
    try std.testing.expectEqual(
        diagnostics.ToolCallOutcome.command_failed,
        classifyReturnedToolCallOutcome(command_failure),
    );
    try std.testing.expectEqual(
        diagnostics.ToolCallOutcome.tool_failed,
        classifyReturnedToolCallOutcome(tool_failure),
    );
    try std.testing.expectEqual(
        diagnostics.ToolCallOutcome.rejected,
        classifyToolExecutionError(error.CancelledBeforeExecution),
    );
    try std.testing.expectEqual(
        diagnostics.ToolCallOutcome.tool_failed,
        classifyToolExecutionError(error.Cancelled),
    );
    try std.testing.expectEqual(
        diagnostics.ToolCallOutcome.runtime_failed,
        classifyToolExecutionError(error.Unexpected),
    );
}

fn rebindMcpAuthorityGeneration(
    access: tool_mcp_runtime.Access,
    authority_generation: u64,
) tool_mcp_runtime.Access {
    return switch (access) {
        .scoped => |scope| .{ .scoped = .{
            .captured = scope.captured,
            .admission_authority_generation = scope.admission_authority_generation,
            .live = scope.live,
            .action_authority_generation = authority_generation,
        } },
        else => access,
    };
}

fn containsName(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

pub fn executeToolCall(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
) !ToolExecutionResult {
    return executeToolCallAuthorized(ctx, .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = call,
        .authority = .ordinary,
        .current_turn_messages = ctx.current_turn_messages,
        .advertised_dynamic_tool_names = ctx.advertised_dynamic_tool_names,
        .max_tool_result_bytes = ctx.max_tool_result_bytes,
    });
}

const ToolDispatchPrelude = union(enum) {
    completed: ToolExecutionResult,
    registered_static,
    registered_dynamic: tool_dispatch.Tool,
};

fn executeToolCallInner(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
    authority: command_admission.ToolExecutionAuthority,
    classification_complete: bool,
    authorized_image_catalog: []const types.ImageAttachment,
) !ToolExecutionResult {
    return switch (try resolveToolDispatchPrelude(
        ctx,
        arena,
        call,
        classification_complete,
    )) {
        .completed => |result| return result,
        .registered_static => try executeRegisteredTool(
            ctx,
            arena,
            call,
            authority,
            authorized_image_catalog,
            ctx.tool_registry,
        ),
        .registered_dynamic => |dynamic_tool| blk: {
            const tools = [_]tool_dispatch.Tool{dynamic_tool};
            break :blk try executeRegisteredTool(
                ctx,
                arena,
                call,
                authority,
                authorized_image_catalog,
                .{ .tools = tools[0..] },
            );
        },
    };
}

fn executeWorkspaceToolCallInner(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
    authority: command_admission.ToolExecutionAuthority,
    classification_complete: bool,
) !ToolExecutionResult {
    if (!classification_complete) {
        if (try checkToolAvailability(ctx, arena, call)) |reason| {
            return semanticFailure(reason);
        }
    }
    const spec = registeredToolSpec(ctx, call.name) orelse
        return semanticFailure(try arena.print("Unsupported tool: {f}", .{model_context_encoding.scalar(call.name)}));
    if (ctx.tool_registry.tools.len != 1 or
        !std.mem.eql(u8, spec.name, "shell") or
        spec.executor_kind != .run_command or
        spec.runtime_provider != .run_command)
    {
        return semanticFailure(try arena.print("Unsupported tool: {f}", .{model_context_encoding.scalar(call.name)}));
    }

    var command_backend = RunCommandBackendState{ .runtime = ctx };
    var dispatch_metadata: DispatchMetadata = .{};
    var dispatch_ctx = typedDispatchContextForCall(ctx, arena, call);
    dispatch_metadata.attach(&dispatch_ctx);
    dispatch_ctx.execution_authority = authority;
    dispatch_ctx.captured_command_host = spec.captured_command_host;
    dispatch_ctx.run_command_backend = .{
        .ctx = &command_backend,
        .execute_fn = executeRunCommandBackend,
    };
    const dispatched = try tool_dispatch.dispatchAuthorizedToolCall(
        dispatch_ctx,
        ctx.tool_registry,
        call,
    );
    if (command_backend.execution_error) |err| {
        dispatched.deinit(arena);
        return err;
    }
    var execution = command_backend.completion orelse
        toolExecutionResultFromDispatch(dispatched, dispatch_metadata);
    execution.model_output = dispatched.body;
    return execution;
}

fn resolveToolDispatchPrelude(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
    classification_complete: bool,
) !ToolDispatchPrelude {
    if (!classification_complete) {
        if (try checkToolAvailability(ctx, arena, call)) |reason| {
            return .{ .completed = semanticFailure(reason) };
        }
    }
    if (registeredToolSpec(ctx, call.name) != null) return .registered_static;
    const mcp_runtime = mcpRuntimeCapabilities(ctx);
    return switch (tool_mcp_registry.resolve(
        ctx.advertised_dynamic_tool_names,
        mcp_runtime,
        call.name,
    )) {
        .registered => |tool| .{ .registered_dynamic = tool },
        .not_selected => .{ .completed = semanticFailure(
            try tool_mcp_runtime.notSelectedOutput(arena, call.name),
        ) },
        .unsupported => .{ .completed = semanticFailure(
            try tool_mcp_registry.unsupportedOutput(arena, call.name, call.carried_by),
        ) },
    };
}

const McpProgressBridge = struct {
    ctx: Context,
};

fn emitMcpProgress(raw_context: *anyopaque, progress: tool_mcp_runtime.Progress) void {
    const bridge: *McpProgressBridge = @ptrCast(@alignCast(raw_context));
    var clipped_buf: [256]u8 = undefined;
    var generated_buf: [96]u8 = undefined;
    const text = if (progress.message) |message|
        text_utils.clippedLabel(&clipped_buf, message, clipped_buf.len)
    else if (progress.total) |total|
        std.mem.print(
            &generated_buf,
            "MCP progress {d:.2}/{d:.2}",
            .{ progress.progress, total },
        ) catch "MCP progress"
    else
        std.mem.print(
            &generated_buf,
            "MCP progress {d:.2}",
            .{progress.progress},
        ) catch "MCP progress";
    if (bridge.ctx.on_mcp_progress) |publish| {
        if (bridge.ctx.output_chunk_lifecycle_id) |lifecycle_id| {
            publish(
                bridge.ctx.mcp_progress_ctx orelse bridge.ctx.output_chunk_ctx,
                lifecycle_id,
                text,
            );
            return;
        }
    }
    bridge.ctx.on_output_chunk(
        bridge.ctx.output_chunk_ctx,
        bridge.ctx.output_chunk_lifecycle_id,
        .stdout,
        text,
    ) catch |err| {
        debug_trace.logf("mcp", "failed to publish MCP progress err={s}", .{@errorName(err)});
    };
}

fn executeRegisteredTool(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
    authority: command_admission.ToolExecutionAuthority,
    authorized_image_catalog: []const types.ImageAttachment,
    registry: tool_dispatch.Registry,
) !ToolExecutionResult {
    var context_notice_sink = ContextNoticeSinkState{ .allocator = arena };
    var command_backend = RunCommandBackendState{ .runtime = ctx };
    var vision_provider = VisionProviderState{
        .runtime = ctx,
        .authorized_image_catalog = authorized_image_catalog,
    };
    var mcp_progress_bridge = McpProgressBridge{ .ctx = ctx };
    var mcp_call_status: ?tool_mcp_runtime.CallStatus = null;
    var mcp_execution_error: ?anyerror = null;
    var dispatch_metadata: DispatchMetadata = .{};
    var subagent_provider = SubagentProviderState{
        .runtime = ctx,
        .call = call,
        .completion_sink = &dispatch_metadata.subagent_completion,
    };
    var mcp_call_bridge = McpCallBridgeState{ .runtime = ctx };
    var toolbox_run = ToolboxRunState{ .runtime = ctx };
    var dispatch_ctx = typedDispatchContextForCall(ctx, arena, call);
    dispatch_metadata.attach(&dispatch_ctx);
    var result_commit_token: ?result_commit.Token = null;
    dispatch_ctx.result_commit_sink = &result_commit_token;
    dispatch_ctx.execution_authority = authority;
    dispatch_ctx.mcp_call_options = .{
        .observer = ctx.observer,
        .call_id = call.id,
        .expected_runtime_generation = ctx.expected_mcp_runtime_generation,
        .expected_binding = ctx.expected_mcp_binding,
        .cancel_flag = dispatch_ctx.cancel_flag,
        .progress = .{
            .context = @ptrCast(&mcp_progress_bridge),
            .callback = emitMcpProgress,
        },
        .input_responder = ctx.mcp_input_responder,
        .access = ctx.mcp_access,
    };
    dispatch_ctx.mcp_call_status_sink = &mcp_call_status;
    if (ctx.mcp_ctx != null and ctx.mcp_call_tool != null) {
        dispatch_ctx.mcp_call_capability = mcp_call_bridge.capability();
    }
    dispatch_ctx.toolbox_run = toolbox_run.capability();
    const runtime_provider = if (registry.lookup(call.name)) |tool|
        tool.runtime_provider
    else
        .none;
    if (registry.lookup(call.name)) |tool| {
        dispatch_ctx.captured_command_host = tool.captured_command_host;
    }
    switch (runtime_provider) {
        .none => {},
        .run_command => dispatch_ctx.run_command_backend = .{
            .ctx = &command_backend,
            .execute_fn = executeRunCommandBackend,
        },
        .vision => dispatch_ctx.vision_provider = .{
            .ctx = &vision_provider,
            .execute_fn = executeVisionProvider,
        },
        .subagent => dispatch_ctx.subagent_provider = .{
            .context = &subagent_provider,
            .execute_fn = executeSubagentProvider,
        },
    }
    dispatch_ctx.mcp_execution_error_sink = &mcp_execution_error;
    attachContextNoticeSink(&dispatch_ctx, &context_notice_sink);
    const dispatched = try tool_dispatch.dispatchAuthorizedToolCall(
        dispatch_ctx,
        registry,
        call,
    );
    if (command_backend.execution_error) |err| {
        dispatched.deinit(arena);
        return err;
    }
    if (vision_provider.execution_error) |err| {
        dispatched.deinit(arena);
        return err;
    }
    if (mcp_execution_error) |err| {
        dispatched.deinit(arena);
        if (err == error.McpAdvertisedToolChanged) return refreshChangedMcpTool(ctx, arena, call);
        return err;
    }

    var execution = if (command_backend.completion) |completion|
        completion
    else if (vision_provider.completion) |completion|
        completion
    else
        toolExecutionResultFromDispatch(dispatched, dispatch_metadata);
    execution.model_output = dispatched.body;
    if (mcp_call_status == .input_required) {
        execution.finish_turn = true;
        execution.status_detail = "McpInputRequired";
    }
    execution.context_notices = context_notice_sink.notices.items;
    execution.result_commit = result_commit_token;
    if (dispatch_ctx.cancel_flag) |cancel_flag| {
        if (cancel_flag.load(.seq_cst) and
            tool_dispatch.toolActivityKind(registry, call.name) == .command)
        {
            execution.cancelled = true;
        }
    }
    return execution;
}

/// Lends this tool call's permission check and MCP call to the `spark mcp call`
/// bridge while the call runs (`mcp_call_capability.zig`).
const McpCallBridgeState = struct {
    runtime: Context,

    fn capability(self: *McpCallBridgeState) mcp_call_capability.Capability {
        return .{ .context = @ptrCast(self), .authorize_fn = authorizeBridgeCall, .call_fn = runBridgeCall, .lookup_fn = lookupBridge };
    }
};

/// Checks a bridge call as the agent's own call of an MCP tool it never
/// selected: the tool must resolve for this agent, and the call then meets
/// the configured and saved rules, the prompt, and automatic review, which
/// sees exactly this call.
fn authorizeBridgeCall(
    raw: *anyopaque,
    arena: Allocator,
    request_id: []const u8,
    tool: []const u8,
    arguments_json: []const u8,
) anyerror!mcp_call_capability.Authorization {
    const state: *McpCallBridgeState = @ptrCast(@alignCast(raw));
    const ctx = state.runtime;
    if (ctx.tool_registry.lookup(tool) != null) {
        return .{ .deny = try arena.print("{f} is a built-in tool; spark mcp call runs MCP tools only.", .{text_utils.terminalSafe(tool)}) };
    }
    const resolved = (try resolveUnselectedMcpTool(ctx, arena, tool)) orelse {
        return .{ .deny = try arena.print("No MCP tool named {f} is available to this agent. Find tool names with toolbox search.", .{text_utils.terminalSafe(tool)}) };
    };
    const call: ToolCall = .{ .id = request_id, .name = tool, .arguments_json = arguments_json };
    return switch (try checkNestedCall(ctx, arena, call, resolved)) {
        .allow => .{ .allow = .{ .binding = resolved.mcp_binding } },
        .deny => |why| .{ .deny = why },
    };
}

const NestedCheck = union(enum) {
    /// The context the call runs in.
    allow: Context,
    /// Why not, for the model.
    deny: []const u8,
};

/// The permission check of a call the agent makes through another tool, a
/// shell command's `spark mcp call` or `toolbox {run}`: it is checked as the
/// agent's own direct call of `call.name`, and the configured and saved
/// rules, the prompt, and automatic review see exactly this call. An MCP
/// tool the agent never selected, `mcp`, joins the names the check knows,
/// with its definition for the review.
fn checkNestedCall(ctx: Context, arena: Allocator, call: ToolCall, mcp: ?tool_mcp_runtime.SelectedTool) !NestedCheck {
    var check = ctx;
    if (mcp) |resolved| {
        const names = try arena.alloc([]const u8, ctx.advertised_dynamic_tool_names.len + 1);
        @memcpy(names[0..ctx.advertised_dynamic_tool_names.len], ctx.advertised_dynamic_tool_names);
        names[names.len - 1] = call.name;
        check.advertised_dynamic_tool_names = names;
        check.expected_mcp_binding = resolved.mcp_binding;
    }
    const outcome = try tool_admission.requestPermissionOutcome(check.admissionInput(), arena, call);
    if (!outcome.decision.isDenied() and outcome.tool_failure == null) return .{ .allow = check };
    if (outcome.tool_failure orelse outcome.feedback) |message| return .{ .deny = message };
    const reason = outcome.denial_reason orelse outcome.decision.denialReason() orelse .user_denied;
    return .{ .deny = try tool_result_errors.permissionDenialText(arena, call.name, reason) };
}

/// Lends this tool call's permission check and execution to `toolbox {run}`
/// while the call runs (`tool_dispatch.ToolboxRun`).
const ToolboxRunState = struct {
    runtime: Context,

    fn capability(self: *ToolboxRunState) tool_dispatch.ToolboxRun {
        return .{ .context = @ptrCast(self), .explain_fn = explainToolboxRun, .describe_fn = describeToolboxTool, .search_fn = searchToolboxBuiltins };
    }
};

/// The definition `toolbox {open}` gives a tool: a built-in's own, or for an
/// MCP tool the one its selection would have sent, with its full input
/// schema and its server's instructions.
fn describeToolboxTool(raw: *anyopaque, arena: Allocator, tool: []const u8) anyerror!?tool_dispatch.ToolboxDescription {
    const state: *ToolboxRunState = @ptrCast(@alignCast(raw));
    if (std.mem.eql(u8, tool, toolbox.tool_name)) return null;
    const spec = state.runtime.tool_registry.lookup(tool) orelse return switch (try lookupToolboxMcpTool(state.runtime, arena, tool)) {
        .found => |found| .{ .definition = .{ .json = found.tool.schema_json, .notice = found.notice } },
        .rejected => |why| .{ .unavailable = why },
        .missing => if (types.isMcpToolName(tool) and mcpAccessChanged(state.runtime))
            .{ .unavailable = try staleViewRefusal(arena, tool) }
        else
            null,
    };
    if (!spec.model_visible) return null;
    return .{ .definition = .{ .json = try model_tool_schema.builtinFunctionSchemaJsonAlloc(arena, spec.model_schema) } };
}

/// The built-in tools behind toolbox that match `query`, best first, by
/// name and description, as the menu lists them.
fn searchToolboxBuiltins(raw: *anyopaque, arena: Allocator, query: *const lexical_relevance.PreparedQuery) anyerror![]const tool_dispatch.ToolboxMatch {
    const state: *ToolboxRunState = @ptrCast(@alignCast(raw));
    const Scored = struct {
        match: tool_dispatch.ToolboxMatch,
        score: lexical_relevance.Score,

        fn better(_: void, a: @This(), b: @This()) bool {
            return lexical_relevance.order(a.score, b.score) == .gt;
        }
    };
    var scored: std.ArrayList(Scored) = .empty;
    for (state.runtime.toolbox_behind) |name| {
        const spec = state.runtime.tool_registry.lookup(name) orelse continue;
        const score = lexical_relevance.score(query, &.{name}, &.{name}, &.{spec.description}) orelse continue;
        try scored.append(arena, .{
            .match = .{ .name = name, .description = toolbox.shortLine(spec.description, 100).text },
            .score = score,
        });
    }
    sort_utils.sort(Scored, scored.items, {}, Scored.better);
    debug_trace.logf("toolbox", "search builtins behind={d} matches={d}", .{ state.runtime.toolbox_behind.len, scored.items.len });
    const matches = try arena.alloc(tool_dispatch.ToolboxMatch, scored.items.len);
    for (scored.items, matches) |item, *match| match.* = item.match;
    return matches;
}

/// Why `toolbox {run}` didn't run `tool`. The agent loop runs every tool a
/// run can carry as its own direct call of it, so what reaches here is
/// toolbox itself, a host's own tool, or one spark can't find or can't use now.
fn explainToolboxRun(raw: *anyopaque, arena: Allocator, tool: []const u8) anyerror![]const u8 {
    const state: *ToolboxRunState = @ptrCast(@alignCast(raw));
    const ctx = state.runtime;
    if (std.mem.eql(u8, tool, toolbox.tool_name)) return "toolbox can't run toolbox.";
    if (ctx.tool_registry.lookup(tool)) |spec| {
        if (!toolbox.runs(spec.*)) return arena.print("{f} is one of this host's tools; call it directly.", .{model_context_encoding.scalar(tool)});
        return arena.print("{f} didn't run: toolbox runs a tool only as part of the agent's turn.", .{model_context_encoding.scalar(tool)});
    }
    if (!types.isMcpToolName(tool) and containsName(ctx.advertised_dynamic_tool_names, tool)) {
        return arena.print("{f} is one of this host's tools; call it directly.", .{model_context_encoding.scalar(tool)});
    }
    return switch (try lookupToolboxMcpTool(ctx, arena, tool)) {
        .rejected => |why| why,
        .found => arena.print("{f} is available now; run it again with toolbox.", .{model_context_encoding.scalar(tool)}),
        .missing => if (mcpAccessChanged(ctx))
            staleViewRefusal(arena, tool)
        else
            arena.print("No tool named {f} is in the toolbox. Use toolbox search to find it.", .{model_context_encoding.scalar(tool)}),
    };
}

/// What a subagent hears for an MCP tool its view of the session's servers no
/// longer holds: the cause, not that the tool is missing.
fn staleViewRefusal(arena: Allocator, tool: []const u8) Allocator.Error![]const u8 {
    return arena.print("{f} is not available to this work: {s}", .{ model_context_encoding.scalar(tool), tool_mcp_runtime.servers_changed_reason });
}

/// Whether this run's MCP view is one the session's servers have changed
/// under since it was given.
fn mcpAccessChanged(ctx: Context) bool {
    const changed = ctx.mcp_access_changed orelse return false;
    const runtime_context = ctx.mcp_ctx orelse return false;
    return changed(runtime_context, ctx.mcp_access);
}

fn runBridgeCall(
    raw: *anyopaque,
    arena: Allocator,
    request_id: []const u8,
    tool: []const u8,
    arguments_json: []const u8,
    allowed: @FieldType(mcp_call_capability.Authorization, "allow"),
    cancel: *std.atomic.Value(bool),
) anyerror!mcp_call_capability.CallOutcome {
    const state: *McpCallBridgeState = @ptrCast(@alignCast(raw));
    const row = BridgeCallRow.start(state.runtime, arena, request_id, tool, arguments_json);
    const outcome = callBridgeTool(state.runtime, arena, request_id, tool, arguments_json, allowed, cancel) catch |err| {
        if (row) |value| value.finish(arena, if (cancel.load(.acquire)) .cancelled else .failed);
        return err;
    };
    if (row) |value| value.finish(arena, if (cancel.load(.acquire)) .cancelled else switch (outcome.status) {
        .ok => .completed,
        .tool_error, .failed => .failed,
    });
    return outcome;
}

/// The row a bridge call shows in its shell call's group: the row a direct
/// call of the same MCP tool shows, `Running MCP` and then `Ran MCP`. Only a
/// host that set `nested_tool_lifecycle` shows it, and keeps its tool name
/// and outcome for a resume when the call ends. A row it could not show or
/// keep is logged, never a reason to fail the call.
const BridgeCallRow = struct {
    publisher: ToolLifecyclePublisher,
    id: types.ToolLifecycleId,
    /// The shell call whose command made the call.
    shell_call_id: []const u8,
    tool: []const u8,

    /// Arguments larger than this stay out of the row's details.
    const max_argument_bytes = 16 * 1024;

    fn start(ctx: Context, arena: Allocator, request_id: []const u8, tool: []const u8, arguments_json: []const u8) ?BridgeCallRow {
        const publisher = ctx.nested_tool_lifecycle orelse return null;
        const parent = ctx.output_chunk_lifecycle_id orelse return null;
        const row: BridgeCallRow = .{
            .publisher = publisher,
            .id = .{ .turn_id = parent.turn_id, .call_id = request_id },
            .shell_call_id = parent.call_id,
            .tool = tool,
        };
        row.begin(ctx, arena, arguments_json) catch |err| {
            debug_trace.logf("mcp-call", "request={s} row not shown err={s}", .{ request_id, @errorName(err) });
            return null;
        };
        return row;
    }

    fn begin(self: BridgeCallRow, ctx: Context, arena: Allocator, arguments_json: []const u8) !void {
        try self.publisher.push(.{ .authoritative_started = .{
            .id = self.id,
            .presentation_group_id = ctx.output_chunk_presentation_group_id,
            .reconciles_provisional_call_id = null,
            .tool_name = self.tool,
            .activity_kind = .mcp,
            .arguments_json = if (arguments_json.len <= max_argument_bytes) try text_utils.maskSecrets(arena, arguments_json) else null,
        } });
        try self.publisher.push(.{ .progress = .{
            .id = self.id,
            .text = try tool_presentation.formatToolActionValue(arena, tool_presentation.mcp_running_label, self.tool),
        } });
    }

    fn finish(self: BridgeCallRow, arena: Allocator, outcome: types.BridgeCallOutcome) void {
        const kind = outcome.toolOutcome();
        const summary = tool_presentation.bridgeCallRowSummary(arena, self.tool, outcome) catch
            tool_presentation.bridgeCallRowLabel(outcome);
        self.publisher.push(.{ .terminal = .{ .id = self.id, .outcome = .{ .kind = kind, .summary = summary } } }) catch |err| {
            // The worker's turn end closes a row whose end was lost.
            debug_trace.logf("mcp-call", "request={s} row end not shown err={s}", .{ self.id.call_id, @errorName(err) });
        };
        self.publisher.saveBridgeCall(.{
            .call_id = self.shell_call_id,
            .request_id = self.id.call_id,
            .tool = self.tool,
            .outcome = outcome,
        }) catch |err| {
            debug_trace.logf("mcp-call", "request={s} row not saved err={s} dropped=saved_bridge_row", .{ self.id.call_id, @errorName(err) });
        };
    }
};

fn callBridgeTool(
    ctx: Context,
    arena: Allocator,
    request_id: []const u8,
    tool: []const u8,
    arguments_json: []const u8,
    allowed: @FieldType(mcp_call_capability.Authorization, "allow"),
    cancel: *std.atomic.Value(bool),
) anyerror!mcp_call_capability.CallOutcome {
    const runtime = ctx.mcp_ctx orelse return .{ .status = .failed, .bytes = "MCP is not available in this session." };
    const call_tool = ctx.mcp_call_tool orelse return .{ .status = .failed, .bytes = "MCP is not available in this session." };
    const result = (call_tool(runtime, arena, tool, arguments_json, mcp_call_capability.max_result_bytes, .{
        .observer = ctx.observer,
        .call_id = request_id,
        .expected_binding = allowed.binding,
        .cancel_flag = cancel,
        .input_responder = ctx.mcp_input_responder,
        .access = ctx.mcp_access,
    }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .status = .failed, .bytes = try arena.print("The MCP call to {f} failed: {s}", .{ text_utils.terminalSafe(tool), @errorName(err) }) };
    }) orelse return .{ .status = .failed, .bytes = try arena.print("No MCP tool named {f} is available.", .{text_utils.terminalSafe(tool)}) };
    return switch (result.status) {
        .success => .{ .status = .ok, .bytes = try bridgeResultData(arena, result.model_output) },
        .tool_failure => .{ .status = .tool_error, .bytes = try bridgeResultData(arena, result.model_output) },
        .protocol_failure => .{ .status = .failed, .bytes = result.model_output },
        .input_required => .{ .status = .failed, .bytes = "This tool asked for input that spark mcp call cannot give. Call the tool directly instead." },
    };
}

/// Just the data of an MCP result envelope: its structured content as JSON
/// when it has some, otherwise its text content. A result the envelope cut
/// short, or any other text that is not an envelope, passes through as is.
fn bridgeResultData(arena: Allocator, envelope: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, envelope, .{}) catch return envelope;
    if (parsed != .object) return envelope;
    const result = parsed.object.get("result") orelse return envelope;
    if (result != .object) return envelope;
    var out: std.Io.Writer.Allocating = .init(arena);
    if (result.object.get("structuredContent")) |structured| {
        if (wrappedResultText(structured)) |text| {
            try out.writer.writeAll(text);
            if (!std.mem.endsWith(u8, text, "\n")) try out.writer.writeByte('\n');
            return out.written();
        }
        if (structured != .null) {
            try std.json.Stringify.value(structured, .{}, &out.writer);
            try out.writer.writeByte('\n');
            return out.written();
        }
    }
    if (result.object.get("content")) |content| if (content == .array) {
        for (content.array.items) |item| {
            if (item != .object) continue;
            const text = item.object.get("text") orelse continue;
            if (text != .string) continue;
            try out.writer.writeAll(text.string);
            if (!std.mem.endsWith(u8, text.string, "\n")) try out.writer.writeByte('\n');
        }
        if (out.written().len > 0) return out.written();
    };
    try std.json.Stringify.value(result, .{}, &out.writer);
    try out.writer.writeByte('\n');
    return out.written();
}

/// The text of a structured result that holds nothing else,
/// `{"result": "..."}`: how some servers, FastMCP's among them, wrap a tool
/// that returns text. A command saving it wants the text, not the wrapper.
fn wrappedResultText(structured: std.json.Value) ?[]const u8 {
    if (structured != .object or structured.object.count() != 1) return null;
    const value = structured.object.get("result") orelse return null;
    return if (value == .string) value.string else null;
}

/// The most search pages one `list` reads: 2,000 tools.
const max_bridge_list_pages = 100;
/// A search page for a command goes to its stdout, not to the model, so it
/// may hold a whole page of tools.
const bridge_search_page_bytes = 256 * 1024;

/// Answers `spark mcp call list`, `search`, and `help` with the tools this agent
/// may use: the same search and schemas as its own `toolbox` search, with
/// the same access and permission rules.
fn lookupBridge(
    raw: *anyopaque,
    arena: Allocator,
    question: mcp_call_capability.Lookup,
    cancel: *std.atomic.Value(bool),
) anyerror!mcp_call_capability.CallOutcome {
    const state: *McpCallBridgeState = @ptrCast(@alignCast(raw));
    const ctx = state.runtime;
    var out: std.Io.Writer.Allocating = .init(arena);
    switch (question) {
        .help => |tool| {
            if (ctx.tool_registry.lookup(tool) != null) {
                return .{ .status = .failed, .bytes = try arena.print("{f} is a built-in tool; spark mcp call runs MCP tools only.", .{text_utils.terminalSafe(tool)}) };
            }
            const resolved = (try resolveUnselectedMcpTool(ctx, arena, tool)) orelse {
                return .{ .status = .failed, .bytes = try arena.print("No MCP tool named {f} is available to this agent. Find tool names with spark mcp call search.", .{text_utils.terminalSafe(tool)}) };
            };
            mcp_tool_lookup.writeHelp(arena, &out.writer, resolved.schema_json) catch |err| switch (err) {
                error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
                error.InvalidToolSchema => return .{ .status = .failed, .bytes = try arena.print("The schema of {f} could not be read.", .{text_utils.terminalSafe(tool)}) },
            };
        },
        .list, .search => |text| {
            const runtime = ctx.mcp_ctx orelse return .{ .status = .failed, .bytes = "MCP is not available in this session." };
            const search = ctx.mcp_search_tools orelse return .{ .status = .failed, .bytes = "MCP is not available in this session." };
            const query = try arena.create(lexical_relevance.PreparedQuery);
            query.* = lexical_relevance.prepare(if (question == .list) "" else text) catch |err| {
                return .{ .status = .failed, .bytes = try arena.print("spark can't search for that: {s}.", .{@errorName(err)}) };
            };
            var limits = ctx.context_limits;
            limits.mcp_search_result_bytes.value = .{ .bytes = bridge_search_page_bytes };
            var cursor: ?[]const u8 = null;
            for (0..max_bridge_list_pages) |_| {
                const request: capability_retrieval.Request = .{
                    .query = query,
                    .kind = .mcp,
                    .server = if (question == .list) text else null,
                    .limit = capability_retrieval.max_limit,
                    .cursor = cursor,
                };
                request.validate() catch |err| {
                    return .{ .status = .failed, .bytes = try arena.print("spark can't search for that: {s}.", .{@errorName(err)}) };
                };
                const result = try search(runtime, arena, request, limits, ctx.mcp_access, cancel);
                const page = mcp_tool_lookup.writeToolLines(arena, &out.writer, result.model_output) catch |err| switch (err) {
                    error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
                    error.InvalidSearchPage => return .{ .status = .failed, .bytes = "The MCP search returned a page spark could not read." },
                };
                if (page.problem) |problem| if (out.written().len == 0) return .{ .status = .failed, .bytes = problem };
                if (question == .search) break;
                const next = page.next_cursor orelse break;
                // A page that holds no tool would only repeat itself.
                if (page.tools == 0) break;
                cursor = next;
            } else debug_trace.logf("mcp-call", "list server={s} stopped after {d} pages", .{ text, max_bridge_list_pages });
        },
    }
    return .{ .status = .ok, .bytes = out.written() };
}

/// The bridge's messages carry the tool name a command typed. They go to the
/// command's output, so a control byte in the name must show as an escape.
fn expectBridgeNameQuoted(message: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, message, "mcp_s_\\x1b]0;x\\x07\\x00t") != null);
    for (message) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
}

const RunCommandBackendState = struct {
    runtime: Context,
    completion: ?ToolExecutionResult = null,
    execution_error: ?anyerror = null,
};

fn executeRunCommandBackend(
    maybe_ctx: ?*anyopaque,
    dispatch_ctx: tool_dispatch.DispatchContext,
    request: tool_dispatch.RunCommandRequest,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const raw_ctx = maybe_ctx orelse unreachable;
    const state: *RunCommandBackendState = @ptrCast(@alignCast(raw_ctx));
    const authority = switch (dispatch_ctx.execution_authority orelse {
        state.execution_error = error.InvalidRunCommandExecutionAuthority;
        return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
    }) {
        .run_command => |command_authority| command_authority,
        .ordinary, .file_mutation, .vision_paths => {
            state.execution_error = error.InvalidRunCommandExecutionAuthority;
            return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
        },
    };
    const execution = toolRunCommand(
        state.runtime,
        dispatch_ctx.allocator,
        request,
        authority,
    ) catch |err| {
        state.execution_error = err;
        return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
    };
    state.completion = execution;
    return switch (execution.status) {
        .success => .{ .success = @constCast(execution.model_output) },
        .failure => .{ .failure = @constCast(execution.model_output) },
    };
}

const DispatchMetadata = struct {
    model_content_kind: tool_dispatch.ModelContentKind = .ordinary,
    inner_usage: ?types.ToolUsage = null,
    web_search_completion: ?types.WebSearchCompletion = null,
    web_fetch_completion: ?types.WebFetchCompletion = null,
    subagent_completion: ?types.SubagentStatus = null,
    tool_result_memory: ?types.ToolResultMemory = null,
    command_result_json: ?[]const u8 = null,

    fn attach(self: *DispatchMetadata, ctx: *tool_dispatch.DispatchContext) void {
        ctx.model_content_kind_sink = &self.model_content_kind;
        ctx.inner_usage_sink = &self.inner_usage;
        ctx.web_search_completion_sink = &self.web_search_completion;
        ctx.web_fetch_completion_sink = &self.web_fetch_completion;
        ctx.tool_result_memory_sink = &self.tool_result_memory;
        ctx.command_result_json_sink = &self.command_result_json;
    }
};

fn toolExecutionResultFromDispatch(
    result: tool_dispatch.AuthorizedDispatchResult,
    metadata: DispatchMetadata,
) ToolExecutionResult {
    var memory = metadata.tool_result_memory;
    if (result.images.len > 0) {
        var rich_memory = memory orelse types.ToolResultMemory{};
        rich_memory.tool_images = result.images;
        memory = rich_memory;
    }
    return switch (result.status) {
        .success => .{
            .model_content_kind = metadata.model_content_kind,
            .model_output = result.body,
            .inner_usage = metadata.inner_usage,
            .web_search_completion = metadata.web_search_completion,
            .web_fetch_completion = metadata.web_fetch_completion,
            .subagent_completion = metadata.subagent_completion,
            .tool_result_memory = memory,
            .command_result_json = metadata.command_result_json,
        },
        .failure => .{
            .status = .failure,
            .model_output = result.body,
            .inner_usage = metadata.inner_usage,
            .web_search_completion = metadata.web_search_completion,
            .web_fetch_completion = metadata.web_fetch_completion,
            .subagent_completion = metadata.subagent_completion,
            .tool_result_memory = memory,
            .command_result_json = metadata.command_result_json,
        },
    };
}

pub fn snapshotMcpDefinition(ctx: Context, arena: Allocator, name: []const u8, known: tool_mcp_runtime.Binding) !tool_mcp_runtime.DefinitionSnapshot {
    const runtime = ctx.mcp_ctx orelse return .unavailable;
    const snapshot = ctx.mcp_snapshot_tool orelse return .unavailable;
    return snapshot(runtime, arena, name, known, ctx.context_limits, ctx.mcp_access);
}

/// Resolves the exact exposed name of a live MCP tool the model called
/// without selecting it. Returns null for unknown, denied, inaccessible, or
/// oversized definitions. The result is allocated in `arena`.
pub fn resolveUnselectedMcpTool(ctx: Context, arena: Allocator, name: []const u8) !?tool_mcp_runtime.SelectedTool {
    const runtime_context = ctx.mcp_ctx orelse return null;
    const schema_fn = ctx.mcp_tool_schema orelse return null;
    const projection = (schema_fn(
        runtime_context,
        arena,
        name,
        ctx.context_limits,
        ctx.mcp_access,
        runtimeCancelFlag(ctx),
    ) catch |err| switch (err) {
        error.OutOfMemory, error.Cancelled => return err,
        else => return null,
    }) orelse return null;
    return switch (projection) {
        .selected => |payload| .{
            .name = name,
            .schema_json = payload.model_output,
            .mcp_binding = payload.mcp_binding,
        },
        .rejected => null,
    };
}

const ToolboxMcpLookup = union(enum) {
    found: struct {
        tool: tool_mcp_runtime.SelectedTool,
        /// What a context limit cut from its schema.
        notice: ?[]const u8,
    },
    /// Why the tool can't be used now, such as its server being unavailable.
    rejected: []const u8,
    missing,
};

/// An MCP tool for toolbox, with the reason when it exists but can't be used
/// now, which `resolveUnselectedMcpTool` leaves out.
fn lookupToolboxMcpTool(ctx: Context, arena: Allocator, name: []const u8) !ToolboxMcpLookup {
    const runtime_context = ctx.mcp_ctx orelse return .missing;
    const schema_fn = ctx.mcp_tool_schema orelse return .missing;
    const projection = (schema_fn(
        runtime_context,
        arena,
        name,
        ctx.context_limits,
        ctx.mcp_access,
        runtimeCancelFlag(ctx),
    ) catch |err| switch (err) {
        error.OutOfMemory, error.Cancelled => return err,
        else => return .missing,
    }) orelse return .missing;
    return switch (projection) {
        .selected => |payload| .{ .found = .{ .tool = .{ .name = name, .schema_json = payload.model_output, .mcp_binding = payload.mcp_binding }, .notice = payload.notice } },
        .rejected => |payload| .{ .rejected = payload.model_output },
    };
}

/// The result of an MCP call refused because the tool's definition changed
/// between admission and execution. A sent tool gets its current schema in
/// the next request; a toolbox run's (`call.carried_by`) schema never joins
/// the tools, so its result says how to see the current arguments instead. The
/// name is the model's, so a run's result writes it as visible text.
fn refreshChangedMcpTool(ctx: Context, arena: Allocator, call: ToolCall) !ToolExecutionResult {
    const name = call.name;
    const toolbox_run = call.carried_by != null;
    const shown = model_context_encoding.scalar(name);
    var unavailable_output: []const u8 = if (toolbox_run)
        try arena.print("{f}'s definition changed before it ran, and it is no longer available. Use toolbox search to find current tools.", .{shown})
    else
        "MCP tool definition changed before execution and is no longer available. Search for current tools.";
    var notice: ?[]const u8 = null;
    if (ctx.mcp_ctx) |runtime_context| if (ctx.mcp_tool_schema) |schema_fn| {
        const current = schema_fn(runtime_context, arena, name, ctx.context_limits, ctx.mcp_access, runtimeCancelFlag(ctx)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        if (current) |projection| switch (projection) {
            .selected => |payload| {
                const selected = try arena.alloc(tool_mcp_runtime.SelectedTool, 1);
                selected[0] = .{ .name = name, .schema_json = payload.model_output, .mcp_binding = payload.mcp_binding };
                return .{
                    .status = .failure,
                    .model_output = if (toolbox_run)
                        try arena.print("{f}'s definition changed before it ran, so it didn't run. Open it with toolbox to see its current arguments, then call toolbox with run: \"{f}\" and those arguments.", .{ shown, shown })
                    else
                        "MCP tool definition changed before execution. Its current schema is loaded; review it before issuing a new call.",
                    .selected_dynamic_tools = selected,
                    .context_notices = if (payload.notice) |value| notices: {
                        const values = try arena.alloc([]const u8, 1);
                        values[0] = value;
                        break :notices values;
                    } else &.{},
                };
            },
            .rejected => |payload| {
                unavailable_output = payload.model_output;
                notice = payload.notice;
            },
        };
    };
    const retired = try arena.alloc([]const u8, 1);
    retired[0] = name;
    return .{
        .status = .failure,
        .model_output = unavailable_output,
        .retired_dynamic_tool_names = retired,
        .context_notices = if (notice) |value| notices: {
            const values = try arena.alloc([]const u8, 1);
            values[0] = value;
            break :notices values;
        } else &.{},
    };
}

fn changedMcpSchema(_: *anyopaque, arena: Allocator, _: []const u8, _: context_limits.Values, _: tool_mcp_runtime.Access, _: ?*std.atomic.Value(bool)) anyerror!?tool_mcp_runtime.ToolSchemaResult {
    return .{ .selected = .{ .model_output = try arena.dupe(u8, "{\"type\":\"function\",\"name\":\"mcp_fixture_echo\"}") } };
}

fn goneMcpSchema(_: *anyopaque, _: Allocator, _: []const u8, _: context_limits.Values, _: tool_mcp_runtime.Access, _: ?*std.atomic.Value(bool)) anyerror!?tool_mcp_runtime.ToolSchemaResult {
    return null;
}

fn accessAlwaysChanged(_: *anyopaque, _: tool_mcp_runtime.Access) bool {
    return true;
}

const ContextNoticeSinkState = struct {
    allocator: Allocator,
    notices: std.ArrayList([]const u8) = .empty,
};

fn attachContextNoticeSink(dispatch_ctx: *tool_dispatch.DispatchContext, state: *ContextNoticeSinkState) void {
    dispatch_ctx.context_notice_ctx = state;
    dispatch_ctx.on_context_notice = recordContextNoticeForDispatch;
}

fn recordContextNoticeForDispatch(raw_ctx: ?*anyopaque, notice: []const u8) error{OutOfMemory}!void {
    const state_ptr = raw_ctx orelse return;
    const state: *ContextNoticeSinkState = @ptrCast(@alignCast(state_ptr));
    const duplicate = try state.allocator.dupe(u8, notice);
    errdefer state.allocator.free(duplicate);
    try state.notices.append(state.allocator, duplicate);
}

fn typedDispatchContext(ctx: Context, arena: Allocator) tool_dispatch.DispatchContext {
    var capabilities = tool_dispatch.ToolCapabilities.for_host(
        host_capabilities.current(),
    );
    // Web search runs on Firecrawl, which works with any model provider.
    capabilities.web_search_runtime_ready = true;
    return .{
        .allocator = arena,
        .observer = ctx.observer,
        .permission_mode = ctx.permission_mode,
        .workspace_root = ctx.workspace_root,
        .access_scope = ctx.access_scope,
        .change_tracker = ctx.tracker,
        .skills_dir = ctx.skills_dir,
        .skill_locations = ctx.skill_locations,
        .toolbox_mcp_servers = ctx.toolbox_mcp_servers,
        .toolbox_behind = ctx.toolbox_behind,
        .context_limits = ctx.context_limits,
        .ignored_list_entries = ctx.ignored_list_entries,
        .max_list_entries = ctx.max_list_entries,
        .max_read_file_bytes = ctx.max_read_file_bytes,
        .max_read_file_lines = ctx.max_read_file_lines,
        .max_read_file_line_len = ctx.max_read_file_line_len,
        .max_tool_result_bytes = ctx.max_tool_result_bytes,
        .tool_result_dir = ctx.tool_result_dir,
        .session_child_capability = ctx.session_child_capability,
        .ephemeral_command_replay = ctx.ephemeral_command_replay,
        .terminal_client = ctx.terminal_client,
        .managed_executions = ctx.managed_executions,
        .command_artifact_dir = ctx.command_artifact_dir,
        .terminal_owner_session_id = ctx.lifecycle_scope.session_id,
        .terminal_transport_role = switch (ctx.lifecycle_scope.kind) {
            .interactive, .subagent => .interactive,
            .ask => .headless,
            .acp => .acp,
        },
        .lifecycle_allocator = ctx.session_allocator,
        .cancel_flag = runtimeCancelFlag(ctx),
        .tool_yield_flag = &ctx.worker.tool_yield_requested,
        .output_chunk_lifecycle_id = ctx.output_chunk_lifecycle_id,
        .output_chunk_ctx = ctx.output_chunk_ctx,
        .on_output_chunk = ctx.on_output_chunk,
        .command_timeout_ms = ctx.command_timeout_ms,
        .ask_question_ctx = if (ctx.interactive or ctx.ask_user_questions) ctx.worker else null,
        .ask_question_batch = if (ctx.interactive or ctx.ask_user_questions) requestQuestionBatchWithWorker else null,
        .web_fetch_runtime = ctx.web_fetch_runtime,
        .web_fetch_artifact_store = ctx.web_fetch_artifact_store,
        .web_fetch_artifact_error = ctx.web_fetch_artifact_error,
        .tool_capabilities = capabilities,
        .web_search_backend = ctx.web_search_backend,
        .web_search_progress_ctx = ctx.web_search_progress_ctx,
        .on_web_search_progress = ctx.on_web_search_progress,
        .web_fetch_progress_ctx = ctx.web_fetch_progress_ctx,
        .on_web_fetch_progress = ctx.on_web_fetch_progress,
        .host_tool_provider = ctx.host_tool_provider,
        .mcp_ctx = ctx.mcp_ctx,
        .mcp_call_tool = ctx.mcp_call_tool,
        .mcp_search_tools = ctx.mcp_search_tools,
        .mcp_tool_schema = ctx.mcp_tool_schema,
        .mcp_access = ctx.mcp_access,
        .mcp_access_changed = ctx.mcp_access_changed,
        .mcp_input_responder = ctx.mcp_input_responder,
    };
}

fn terminal_lease_cleanup_dispatch_context(
    ctx: Context,
    arena: Allocator,
) tool_dispatch.DispatchContext {
    var dispatch = typedDispatchContext(ctx, arena);
    dispatch.cancel_flag = null;
    dispatch.tool_yield_flag = null;
    return dispatch;
}

/// Stops the shell commands that steering moved to the background during
/// turn `turn_id`, after the user cancelled that turn. The stop ignores the
/// turn's cancel flag, which is set by then.
pub fn stop_steering_detached_commands(ctx: Context, turn_id: u64) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.session_allocator);
    defer arena_state.deinit();
    return shell_impl.stopSteeringDetached(
        terminal_lease_cleanup_dispatch_context(ctx, arena_state.allocator()),
        turn_id,
    );
}

pub fn release_agent_terminal_lease(ctx: Context, session_id: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.session_allocator);
    defer arena_state.deinit();
    return shell_impl.releaseAgentWriteLease(
        terminal_lease_cleanup_dispatch_context(ctx, arena_state.allocator()),
        session_id,
    );
}

fn requestQuestionBatchWithWorker(
    raw_ctx: ?*anyopaque,
    response_alloc: Allocator,
    entries: []const types.QuestionBatchEntry,
) Allocator.Error!?[][]u8 {
    const worker: *WorkerRuntime = @ptrCast(@alignCast(raw_ctx.?));
    const worker_alloc = std.heap.c_allocator;
    const worker_answers = try worker.requestQuestionBatchAnswerBlocking(worker_alloc, entries);
    defer freeQuestionAnswers(worker_alloc, worker_answers);

    const answers = worker_answers orelse return null;
    const copied_answers = try dupeQuestionAnswers(response_alloc, answers);
    return copied_answers;
}

fn dupeQuestionAnswers(alloc: Allocator, answers: []const []const u8) Allocator.Error![][]u8 {
    const copy = try alloc.alloc([]u8, answers.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        for (copy[0..copied]) |answer| alloc.free(answer);
    }
    while (copied < answers.len) : (copied += 1) {
        copy[copied] = try alloc.dupe(u8, answers[copied]);
    }
    return copy;
}

fn freeQuestionAnswers(alloc: Allocator, maybe_answers: ?[][]u8) void {
    const answers = maybe_answers orelse return;
    for (answers) |answer| alloc.free(answer);
    alloc.free(answers);
}

fn runtimeCancelFlag(ctx: Context) *std.atomic.Value(bool) {
    return ctx.cancel_flag orelse &ctx.worker.worker_cancel_requested;
}

fn typedDispatchContextForCall(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
) tool_dispatch.DispatchContext {
    var dispatch = typedDispatchContext(ctx, arena);
    dispatch.tool_call_id = call.id;
    dispatch.tool_call_name = call.name;
    dispatch.tool_call_carried_by = call.carried_by;
    return dispatch;
}

const VisionProviderState = struct {
    runtime: Context,
    authorized_image_catalog: []const types.ImageAttachment,
    completion: ?ToolExecutionResult = null,
    execution_error: ?anyerror = null,
};

fn executeVisionProvider(
    maybe_ctx: ?*anyopaque,
    dispatch_ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const raw_ctx = maybe_ctx orelse unreachable;
    const state: *VisionProviderState = @ptrCast(@alignCast(raw_ctx));
    const request = input.as(tool_contracts.vision.VisionRequest);
    const execution = executeVisionRequest(
        state,
        dispatch_ctx.allocator,
        request.*,
        dispatch_ctx.execution_authority orelse {
            state.execution_error = error.InvalidVisionExecutionAuthority;
            return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
        },
    ) catch |err| {
        state.execution_error = err;
        return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
    };
    state.completion = execution;
    return switch (execution.status) {
        .success => .{ .success = @constCast(execution.model_output) },
        .failure => .{ .failure = @constCast(execution.model_output) },
    };
}

fn executeVisionRequest(
    state: *VisionProviderState,
    alloc: Allocator,
    request: tool_contracts.vision.VisionRequest,
    authority: command_admission.ToolExecutionAuthority,
) !ToolExecutionResult {
    const config: vision_executor.Config = .{
        .observer = state.runtime.observer,
        .parent_call_id = if (state.runtime.output_chunk_lifecycle_id) |id| id.call_id else null,
        .stream_provider = state.runtime.agent_stream_provider,
        .api_key = state.runtime.api_key,
        .credential_source = state.runtime.credential_source,
        .gateway_team = state.runtime.gateway_team,
        .session_id = state.runtime.lifecycle_scope.session_id,
        .retry_count = state.runtime.gateway_retry_count,
        .cancel_flag = state.runtime.cancel_flag,
        .trace_ctx = .{},
        .output_limit = state.runtime.context_limits.image_adapter_output_bytes,
        // A connection reads images with its own vision_model.
        .model = state.runtime.provider_capabilities.vision_model orelse image_provider.default_model,
    };
    if (request.image_ids() != null) {
        if (authority != .ordinary) return error.InvalidVisionExecutionAuthority;
        return vision_executor.executeRequest(
            alloc,
            request,
            state.authorized_image_catalog,
            config,
        );
    }

    const approved_targets = switch (authority) {
        .vision_paths => |vision_authority| vision_authority.targets,
        .ordinary, .run_command, .file_mutation => return error.InvalidVisionExecutionAuthority,
    };
    const raw_paths = request.paths() orelse return error.InvalidVisionExecutionAuthority;
    if (raw_paths.len != approved_targets.len) return error.InvalidVisionExecutionAuthority;
    return executeVisionPathRequest(state, alloc, request, approved_targets, config);
}

fn executeVisionPathRequest(
    state: *VisionProviderState,
    alloc: Allocator,
    request: tool_contracts.vision.VisionRequest,
    approved_targets: []const command_admission.VisionPathExecutionTarget,
    config: vision_executor.Config,
) !ToolExecutionResult {
    const catalog = try alloc.alloc(types.ImageAttachment, approved_targets.len);
    defer alloc.free(catalog);
    var initialized: usize = 0;

    const snapshot_dir = image_attachments.createTempSnapshotDir(alloc) catch |err|
        return visionPathPreparationFailure(alloc, err);
    defer alloc.free(snapshot_dir);
    defer image_attachments.cleanupSnapshotDir(snapshot_dir);
    defer {
        image_attachments.discardImageSnapshots(alloc, catalog[0..initialized]);
        for (catalog[0..initialized]) |image| types.freeImageAttachment(alloc, image);
    }

    for (approved_targets, 0..) |target, index| {
        const image = image_attachments.captureBoundImageAttachment(
            alloc,
            target.canonical_path,
            target.identity,
            index + 1,
            snapshot_dir,
            .{ .cancel_flag = state.runtime.cancel_flag },
        ) catch |err| return visionPathPreparationFailure(alloc, err);
        catalog[index] = image;
        initialized += 1;
    }

    const image_ids = try alloc.alloc(usize, catalog.len);
    defer alloc.free(image_ids);
    for (image_ids, 0..) |*image_id, index| image_id.* = index + 1;
    const id_request: tool_contracts.vision.VisionRequest = .{
        .source = .{ .image_ids = image_ids },
        .focus = request.focus,
    };
    return vision_executor.executeRequest(alloc, id_request, catalog, config);
}

fn visionPathFailure(alloc: Allocator, err: anyerror) Allocator.Error!ToolExecutionResult {
    const details = [_]tool_result_errors.Detail{
        .{ .name = "error", .value = .{ .string = @errorName(err) } },
    };
    return .{
        .status = .failure,
        .status_detail = @errorName(err),
        .model_output = try tool_result_errors.toolExecutionFailureJson(alloc, .{
            .tool_name = "vision",
            .message = "Vision could not load an approved image path.",
            .details = &details,
            .suggestion = "Use an existing supported image under 20 MiB, or choose another image.",
        }),
    };
}

fn visionPathImagePreparationFailure(alloc: Allocator) Allocator.Error!ToolExecutionResult {
    const details = [_]tool_result_errors.Detail{
        .{ .name = "error", .value = .{ .string = "ImagePreparationFailed" } },
    };
    return .{
        .status = .failure,
        .status_detail = "ImagePreparationFailed",
        .model_output = try tool_result_errors.toolExecutionFailureJson(alloc, .{
            .tool_name = "vision",
            .message = "Vision could not prepare an approved image path.",
            .details = &details,
            .suggestion = image_attachments.image_preparation_failed_notice,
        }),
    };
}

fn visionPathPreparationFailure(
    alloc: Allocator,
    err: anyerror,
) !ToolExecutionResult {
    return switch (err) {
        error.OutOfMemory, error.Cancelled, error.TimedOut => err,
        error.ImagePreparationFailed => visionPathImagePreparationFailure(alloc),
        else => visionPathFailure(alloc, err),
    };
}

fn semanticFailure(output: []const u8) ToolExecutionResult {
    return .{ .status = .failure, .model_output = output };
}

fn mcpRuntimeCapabilities(ctx: Context) tool_mcp_runtime.RuntimeCapabilities {
    return .{
        .context = ctx.mcp_ctx,
        .has_tool = ctx.mcp_has_tool,
        .validate_tool = ctx.mcp_validate_tool,
        .call_tool = ctx.mcp_call_tool,
        .access = ctx.mcp_access,
    };
}

pub fn withAdvertisedDynamicToolNames(ctx: Context, advertised_dynamic_tool_names: []const []const u8) Context {
    var copy = ctx;
    copy.advertised_dynamic_tool_names = advertised_dynamic_tool_names;
    return copy;
}

const EffectiveCommandTimeout = struct {
    timeout_ms: usize,
    started_ms: i64,
};

fn effectiveCommandTimeout(
    request_timeout_ms: u64,
    ambient_timeout_ms: ?usize,
    ambient_started_ms: ?i64,
    now_ms: i64,
) !EffectiveCommandTimeout {
    const requested = std.math.cast(usize, request_timeout_ms) orelse
        return error.InvalidToolArguments;
    const ambient = ambient_timeout_ms orelse return .{
        .timeout_ms = requested,
        .started_ms = now_ms,
    };
    const ambient_started = ambient_started_ms orelse now_ms;
    const elapsed: usize = if (now_ms <= ambient_started)
        0
    else
        std.math.cast(usize, now_ms - ambient_started) orelse std.math.maxInt(usize);
    return .{
        .timeout_ms = @min(requested, ambient -| elapsed),
        .started_ms = now_ms,
    };
}

fn commandReplayPolicy(
    environment: command_environment.Environment,
    has_replay_capability: bool,
    interactive: bool,
    continued: ?command_replay_store.CapturePolicy,
) ?command_replay_store.CapturePolicy {
    if (continued) |policy| return policy;
    return switch (environment) {
        .workspace_clean => null,
        .legacy => if (has_replay_capability or interactive)
            .best_effort
        else
            null,
        .clean, .user => if (has_replay_capability)
            .required
        else if (interactive)
            .best_effort
        else
            null,
    };
}

fn toolRunCommand(
    ctx: Context,
    arena: Allocator,
    request: tool_dispatch.RunCommandRequest,
    authority: command_admission.CommandExecutionAuthority,
) !ToolExecutionResult {
    const command = request.command;
    const cwd = request.resolved_cwd;
    const command_ctx = command_admission.CommandContext{
        .command = command,
        .resolved_cwd = cwd,
        .target_os = builtin.target.os.tag,
        .environment = request.environment,
    };
    const timeout = try effectiveCommandTimeout(
        request.timeout_ms,
        ctx.command_timeout_ms,
        ctx.command_timeout_started_ms,
        io_mod.milliTimestamp(),
    );
    const replay_policy = commandReplayPolicy(
        request.environment,
        ctx.session_child_capability != null or
            ctx.ephemeral_command_replay != null,
        ctx.interactive,
        if (ctx.command_replay_capture) |capture| capture.policy() else null,
    );

    try execution_router.validateConfigContext(.{
        .max_command_output_bytes = ctx.max_command_output_bytes,
    }, command_ctx);
    var route = try execution_router.prepareAuthorizedRoute(arena, command_ctx, authority);
    defer route.deinit(arena);

    const compatibility_result = try tool_dispatch.dispatchRunCommandCompatibility(
        typedDispatchContext(ctx, arena),
        ctx.tool_registry,
        request,
    );
    if (compatibility_result) |compatibility| {
        if (route != .approved_shell) return error.CommandAdmissionChanged;
        const intercepted_replay = try initCommandReplayCapture(
            arena,
            replay_policy,
            ctx.max_command_output_bytes,
            ctx.max_command_output_bytes,
            ctx.session_child_capability,
            ctx.ephemeral_command_replay,
            ctx.command_replay_capture,
            ctx.command_replay_unavailable,
        );
        const capture = intercepted_replay.capture;
        var transferred = false;
        defer if (!transferred) {
            if (capture) |candidate| candidate.abort(arena);
        };
        var callback = CommandReplayCaptureCallback{
            .alloc = arena,
            .capture = capture,
        };
        const output = switch (compatibility) {
            .success => |body| body,
            .failure => |body| body,
            .rich => {
                compatibility.deinit(arena);
                return error.RichCommandOutputUnsupported;
            },
        };
        if (compatibility == .success and capture != null and output.len > 0) {
            callback.accept(
                ctx.output_chunk_lifecycle_id,
                .stdout,
                output,
            ) catch |err| {
                if (err != error.CommandOutputCaptureFailed) return err;
                return finishCommandToolResult(
                    arena,
                    capture,
                    false,
                    &transferred,
                    null,
                    try command_result_mapping.Command.outputCaptureFailure(arena),
                );
            };
        }
        if (compatibility == .success and ctx.interactive and output.len > 0) {
            try ctx.on_output_chunk(
                ctx.output_chunk_ctx,
                ctx.output_chunk_lifecycle_id,
                .stdout,
                output,
            );
        }
        return finishCommandToolResult(
            arena,
            capture,
            intercepted_replay.unavailable and
                (ctx.command_replay_unavailable or callback.had_accepted_output),
            &transferred,
            null,
            .{
                .status = switch (compatibility) {
                    .success => .success,
                    .failure => .failure,
                    .rich => unreachable,
                },
                .model_output = output,
            },
        );
    }

    const replay_init = try initCommandReplayCapture(
        arena,
        replay_policy,
        ctx.max_command_output_bytes,
        execution_router.foregroundResultComparisonLimit(
            route,
            ctx.max_command_output_bytes,
        ),
        ctx.session_child_capability,
        ctx.ephemeral_command_replay,
        ctx.command_replay_capture,
        ctx.command_replay_unavailable,
    );
    const replay_capture = replay_init.capture;
    var replay_transferred = false;
    defer if (!replay_transferred) {
        if (replay_capture) |capture| capture.abort(arena);
    };
    var replay_callback = CommandReplayCaptureCallback{
        .alloc = arena,
        .capture = replay_capture,
    };

    const routed = execution_router.executePreparedRoute(.{
        .max_command_output_bytes = ctx.max_command_output_bytes,
        .cancel_flag = runtimeCancelFlag(ctx),
        .output_chunk_lifecycle_id = ctx.output_chunk_lifecycle_id,
        .output_chunk_ctx = ctx.output_chunk_ctx,
        .on_output_chunk = ctx.on_output_chunk,
        .accepted_output_chunk_ctx = if (replay_capture != null) @ptrCast(&replay_callback) else null,
        .on_accepted_output_chunk = if (replay_capture != null) CommandReplayCaptureCallback.onChunk else null,
        .callback_projection = if (ctx.interactive) .raw else .model_safe,
        .timeout_ms = timeout.timeout_ms,
        .timeout_started_ms = timeout.started_ms,
        .command_artifact_capability = ctx.session_child_capability,
        .command_artifact_dir = ctx.command_artifact_dir,
    }, arena, route) catch |err| {
        if (err == error.TimeoutExpired) {
            return finishCommandToolResult(
                arena,
                replay_capture,
                replay_init.unavailable and
                    (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
                &replay_transferred,
                null,
                try command_result_mapping.Command.timeoutFailure(
                    arena,
                    command,
                    cwd,
                    timeout.timeout_ms,
                    timeout.started_ms,
                ),
            );
        }
        if (err == error.CommandOutputCaptureFailed) return finishCommandToolResult(
            arena,
            replay_capture,
            false,
            &replay_transferred,
            null,
            try command_result_mapping.Command.outputCaptureFailure(arena),
        );
        if (err == error.Cancelled and runtimeCancelFlag(ctx).load(.seq_cst)) {
            return finishCommandToolResult(
                arena,
                replay_capture,
                replay_init.unavailable and
                    (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
                &replay_transferred,
                null,
                .{
                    .status = .failure,
                    .cancelled = true,
                    .model_output = "command cancelled\n",
                },
            );
        }
        return err;
    };
    const result = routed.result;

    if (try command_result_mapping.Command.cancelledFailure(arena, result)) |cancelled| {
        return finishCommandToolResult(
            arena,
            replay_capture,
            replay_init.unavailable and
                (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
            &replay_transferred,
            result,
            cancelled,
        );
    }

    if (try command_result_mapping.Command.nonZeroFailure(arena, result)) |failure| {
        return finishCommandToolResult(
            arena,
            replay_capture,
            replay_init.unavailable and
                (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
            &replay_transferred,
            result,
            failure,
        );
    }

    return finishCommandToolResult(
        arena,
        replay_capture,
        replay_init.unavailable and
            (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
        &replay_transferred,
        result,
        .{
            .model_output = result.output,
            .command_result_json = if (result.command_result) |command_result| try command_result.toJson(arena) else null,
        },
    );
}

const CommandReplayCaptureCallback = struct {
    alloc: Allocator,
    capture: ?*command_replay_store.Capture,
    had_accepted_output: bool = false,

    fn onChunk(
        raw_ctx: *anyopaque,
        lifecycle_id: ?types.ToolLifecycleId,
        stream: command_contract.CommandOutputStream,
        chunk: []const u8,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        return self.accept(lifecycle_id, stream, chunk);
    }

    fn accept(
        self: *@This(),
        lifecycle_id: ?types.ToolLifecycleId,
        stream: command_contract.CommandOutputStream,
        chunk: []const u8,
    ) !void {
        _ = lifecycle_id;
        if (chunk.len == 0) return;
        self.had_accepted_output = true;
        if (self.capture) |capture| {
            switch (capture.policy()) {
                .required => try capture.appendAcceptedRequired(
                    self.alloc,
                    stream,
                    chunk,
                ),
                .best_effort => capture.appendAccepted(self.alloc, stream, chunk),
            }
        }
    }
};

const CommandReplayCaptureInit = struct {
    capture: ?*command_replay_store.Capture = null,
    unavailable: bool = false,
};

fn initCommandReplayCapture(
    arena: Allocator,
    replay_policy: ?command_replay_store.CapturePolicy,
    inline_limit: usize,
    comparison_limit: usize,
    capability: ?*session_child_store.SessionChildCapability,
    ephemeral_store: ?*command_replay_store.EphemeralStore,
    continued_capture: ?*command_replay_store.Capture,
    continued_unavailable: bool,
) !CommandReplayCaptureInit {
    const policy = replay_policy orelse return .{};
    if (continued_unavailable) {
        if (policy == .required) return error.CommandOutputCaptureFailed;
        return .{ .unavailable = true };
    }
    if (continued_capture) |capture| {
        capture.setComparisonLimit(comparison_limit);
        return .{ .capture = capture };
    }
    const capture_inline_limit = if (policy == .required) 0 else inline_limit;
    const capture = (if (capability) |saved|
        command_replay_store.Capture.create(arena, capture_inline_limit, saved)
    else if (ephemeral_store) |ephemeral|
        command_replay_store.Capture.createEphemeral(arena, capture_inline_limit, ephemeral)
    else
        command_replay_store.Capture.create(arena, capture_inline_limit, null)) catch |err| {
        if (policy == .required) return err;
        debug_trace.logf(
            "session",
            "command replay capture initialization unavailable err={s}",
            .{@errorName(err)},
        );
        return .{ .unavailable = true };
    };
    capture.setPolicyBeforeCapture(policy);
    capture.setComparisonLimit(comparison_limit);
    return .{ .capture = capture };
}

fn finishCommandToolResult(
    arena: Allocator,
    capture: ?*command_replay_store.Capture,
    replay_unavailable: bool,
    replay_transferred: *bool,
    process_result: ?command_contract.RunCommandResult,
    result: ToolExecutionResult,
) !ToolExecutionResult {
    var owned = result;
    if (capture) |candidate| switch (candidate.policy()) {
        .required => candidate.sealRequired(arena) catch {
            owned = try command_result_mapping.Command.outputCaptureFailure(arena);
        },
        .best_effort => {},
    };
    if (process_result) |command_result| {
        if (commandProcessPresentation(command_result)) |presentation| {
            var memory = owned.tool_result_memory orelse types.ToolResultMemory{};
            memory.command_process_presentation = presentation;
            owned.tool_result_memory = memory;
        }
    }
    if (replay_unavailable) {
        var memory = owned.tool_result_memory orelse types.ToolResultMemory{};
        memory.command_output_replay = .unavailable;
        owned.tool_result_memory = memory;
    }
    owned.command_replay_capture = capture;
    if (capture != null) replay_transferred.* = true;
    return owned;
}

fn commandProcessPresentation(
    result: command_contract.RunCommandResult,
) ?types.CommandProcessPresentation {
    const command_result = result.command_result orelse return null;
    const foreground = command_result;
    if (foreground.timed_out) return .timed_out;
    if (foreground.signal) |signal| return .{ .signal = signal };
    if (foreground.exit_code) |exit_code| {
        if (exit_code != 0) return .{ .exit_code = exit_code };
    }
    return null;
}

const SubagentProviderState = struct {
    runtime: Context,
    call: ToolCall,
    completion_sink: *?types.SubagentStatus,
};

fn requestDerivedSubagentSessionTitle(alloc: Allocator, call: ToolCall) Allocator.Error!?[]u8 {
    const action = try tool_presentation.subagentAction(alloc, call, .identity) orelse return null;
    alloc.free(action.detail);
    return action.label;
}

const SubagentProgressBridge = struct {
    alloc: Allocator,
    call: ToolCall,
    renderer: types.SubagentStatusRenderer,
    progress_ctx: *anyopaque,
    progress_fn: *const fn (*anyopaque, types.ToolLifecycleId, []const u8) void,
    lifecycle_id: types.ToolLifecycleId,

    fn init(alloc: Allocator, ctx: Context, call: ToolCall) ?SubagentProgressBridge {
        return .{
            .alloc = alloc,
            .call = call,
            .renderer = ctx.subagent_status_renderer orelse return null,
            .progress_ctx = ctx.tool_progress_ctx orelse return null,
            .progress_fn = ctx.on_tool_progress orelse return null,
            .lifecycle_id = ctx.output_chunk_lifecycle_id orelse return null,
        };
    }

    fn sink(self: *SubagentProgressBridge) subagent_tool_host.ProgressSink {
        return .{ .context = self, .publish_fn = publish };
    }

    fn publish(raw: *anyopaque, status: types.SubagentStatus) void {
        const self: *SubagentProgressBridge = @ptrCast(@alignCast(raw));
        var rendered_status = status;
        const session_title = requestDerivedSubagentSessionTitle(self.alloc, self.call) catch null;
        defer if (session_title) |title| self.alloc.free(title);
        rendered_status.session_title = session_title;
        var status_buf: [256]u8 = undefined;
        const status_line = self.renderer.render(&status_buf, rendered_status);
        if (status_line.len == 0) return;
        const first_line = (tool_presentation.formatSubagentPlainAction(self.alloc, self.call, .active) catch return) orelse return;
        defer self.alloc.free(first_line);
        const row = self.alloc.print("● {s}\n  {s}", .{ first_line, status_line }) catch return;
        defer self.alloc.free(row);
        self.progress_fn(self.progress_ctx, self.lifecycle_id, row);
    }
};

fn subagentProviderRefusal(
    alloc: Allocator,
    why: subagent_refusal.Refusal,
) Allocator.Error!subagent_tool_provider.Result {
    return .{ .status = .failure, .body = try why.body(alloc) };
}

fn executeSubagentProvider(
    raw_context: ?*anyopaque,
    arena: Allocator,
    request: *subagent_model_contract.Request,
    invocation_id: []const u8,
) subagent_tool_provider.ExecuteError!subagent_tool_provider.Result {
    const state: *SubagentProviderState = @ptrCast(@alignCast(raw_context.?));
    const ctx = state.runtime;
    const host = ctx.subagent_host orelse
        return subagentProviderRefusal(arena, .host_unavailable);
    const caller_id = ctx.subagent_caller_id orelse
        return subagentProviderRefusal(arena, .{ .caller_unavailable = .unidentified });
    const identity_epoch = host.issueOperationIdentity(invocation_id);
    var progress_bridge = SubagentProgressBridge.init(arena, ctx, state.call);
    const output = host.executeManaged(arena, request, .{
        .observer = ctx.observer,
        .caller_id = caller_id,
        .invocation_id = invocation_id,
        .parent_permission_mode = ctx.permission_mode,
        .root_user_intent_context = ctx.root_user_intent_context,
        .root_user_messages = ctx.root_user_messages,
        .root_user_evidence_complete = ctx.root_user_evidence_complete,
        .defaults = .{
            .provider = ctx.provider,
            .model = ctx.model,
            .effort = ctx.effort,
            .fast_mode = ctx.fast_mode,
            .ultrafast_mode = ctx.ultrafast_mode,
            .conversation_language = ctx.session.languageSnapshot(),
        },
        .max_result_bytes = ctx.max_tool_result_bytes,
        .timestamp_ms = io_mod.milliTimestamp(),
        .identity_epoch = identity_epoch,
        .cancel_flag = runtimeCancelFlag(ctx),
        .caller_worker = ctx.worker,
        .progress = if (progress_bridge) |*bridge| bridge.sink() else null,
        .model_capability_resolver = ctx.model_capability_resolver,
        .model_override_resolver = ctx.model_override_resolver,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) return error.Cancelled;
        debug_trace.logf("subagent", "host failure err={s}", .{@errorName(err)});
        return subagentProviderRefusal(arena, .{ .host_failure = .internal });
    };
    if (output.final_status) |status_value| {
        var status = status_value;
        status.session_title = requestDerivedSubagentSessionTitle(arena, state.call) catch null;
        state.completion_sink.* = status;
    }
    return .{
        .status = if (output.success) .success else .failure,
        .body = output.body,
    };
}
