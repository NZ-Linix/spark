const std = @import("std");
const agents = @import("core/agents/agents.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const io_mod = @import("core/shared/io.zig");
const profile_paths = @import("core/shared/profile_paths.zig");
const terminal_env = @import("core/shared/terminal_env.zig");
const env_settings = @import("core/config/env_settings.zig");

pub const version = "26.11.25";

const app_lifecycle = @import("core/app/app_lifecycle.zig");
const provider_runtime = @import("core/app/provider_runtime.zig");
const auth_runtime = @import("core/auth/auth_runtime.zig");
const oauth_transport = @import("core/auth/oauth_transport.zig");
const builtin_oauth_http = @import("builtins/oauth_http.zig");
const credentials = @import("core/auth/credentials.zig");
const secret = @import("core/auth/secret.zig");
const model_cache_runtime = @import("core/app/model_cache_runtime.zig");
const app_auth_runtime = @import("core/app/app_auth_runtime.zig");
const app_provider_menu_runtime = @import("core/app/app_provider_menu_runtime.zig");
const app_entry_runtime = @import("core/app/app_entry_runtime.zig");
const acp_runner = @import("core/cli/acp_runner.zig");
const acp_server = @import("acp/server.zig");
const app_input_runtime = @import("core/app/app_input_runtime.zig");
const input_full_transcript_runtime = @import("core/app/input_full_transcript_runtime.zig");
const input_submit_runtime = @import("core/app/input_submit_runtime.zig");
const core_input_runtime = @import("core/input/runtime.zig");
const app_bootstrap_runtime = @import("core/app/app_bootstrap_runtime.zig");
const app_notification_runtime = @import("core/app/app_notification_runtime.zig");
const app_process_runtime = @import("core/app/app_process_runtime.zig");
const managed_execution = @import("core/execution/managed_execution.zig");
const prompt_history_runtime = @import("core/app/prompt_history_runtime.zig");
const app_agent_runtime = @import("core/app/app_agent_runtime.zig");
const app_runtime_setup = @import("core/app/app_runtime_setup.zig");
const app_render_runtime = @import("core/app/app_render_runtime.zig");
const app_session_runtime = @import("core/app/app_session_runtime.zig");
const app_upgrade_runtime = @import("core/app/app_upgrade_runtime.zig");
const app_worker_runtime = @import("core/app/app_worker_runtime.zig");
const app_agents_runtime = @import("core/app/app_agents_runtime.zig");
const render_input = @import("ui/footer/render_input.zig");
const app_profile_runtime = @import("core/app/app_profile_runtime.zig");
const app_instances_runtime = @import("core/app/app_instances_runtime.zig");
const profiles = @import("core/profiles/profiles.zig");
const app_workspace_runtime = @import("core/app/app_workspace_runtime.zig");
const app_callbacks = @import("core/app/app_callbacks.zig");
const app_commands = @import("core/app/app_commands.zig");
const change_tracker_mod = @import("core/workspace/change_tracker.zig");
const context_contract = @import("core/workspace/context_contract.zig");
const statusline_identity = @import("core/workspace/statusline_identity.zig");
const collections = @import("core/shared/collections.zig");
const agent_steps = @import("core/config/agent_steps.zig");
const config_runtime = @import("core/config/config_runtime.zig");
const model_provider = @import("core/config/model_provider.zig");
const model_capabilities = @import("core/config/model_capabilities.zig");
const prompt_policy = @import("core/config/prompt_policy.zig");
const splash_mod = @import("ui/footer/splash.zig");
const live_preview_mod = @import("ui/footer/live_preview.zig");
const convo = @import("core/session/convo.zig");
const prompts = @import("core/prompts/prompts.zig");
const builtin_commands = @import("builtins/commands.zig");
const command_specs = @import("core/slash_commands/command_specs.zig");
const builtin_context = @import("builtins/context.zig");
const builtin_providers = @import("builtins/providers.zig");
const gateway_provider = @import("core/gateway/gateway_provider.zig");
const provider_set = @import("core/gateway/provider_set.zig");
const model_catalog = @import("core/gateway/model_catalog.zig");
const agent_stream_provider = @import("core/agent/stream_provider.zig");
const builtin_hooks = @import("builtins/hooks.zig");
const builtin_mcp = @import("builtins/mcp.zig");
const builtin_modes = @import("builtins/modes.zig");
const builtin_skills = @import("builtins/skills.zig");
const host = @import("core/hosts/host.zig");
const native_host = @import("core/hosts/native.zig");
const debug_trace = @import("core/shared/debug_trace.zig");
const display_width = @import("core/shared/display_width.zig");
const file_index_mod = @import("core/workspace/file_index.zig");
const mcp_host = @import("core/mcp_host/host.zig");
const mcp_access_policy = @import("core/mcp/access_policy.zig");
const app_mcp_runtime = @import("core/app/app_mcp_runtime.zig");
const skill_commands = @import("core/skills/skill_commands.zig");
const skill_runtime = @import("core/skills/skill_runtime.zig");
const cli_surface = @import("core/cli/cli_surface.zig");
const hooks = @import("core/hooks/hooks.zig");
const github_publish = @import("core/github/github_publish.zig");
const subagent_domain = @import("core/subagent/domain.zig");
const subagent_execution = @import("core/subagent/execution.zig");
const subagent_reports = @import("core/subagent/reports.zig");
const agent_frame = @import("core/shared/agent_frame.zig");
const subagent_tool_host = @import("core/subagent/tool_host.zig");
const types = @import("core/shared/types.zig");
const image_attachments = @import("core/images/image_attachments.zig");
const permissions = @import("core/permissions/permissions.zig");
const command_runner = @import("core/execution/command_runner.zig");
const command_admission = @import("core/permissions/command_admission.zig");
const agent_runtime = @import("core/agent/agent_runtime.zig");
const assistant_presentation = @import("core/agent/assistant_presentation.zig");
const auto_upgrade = @import("core/upgrade/auto_upgrade.zig");
const update_target = @import("core/upgrade/update_target.zig");

const compiled_update_channel = update_target.Channel.parse(build_options.update_channel) orelse
    @compileError("invalid compiled update channel");
const shell_process_provider = @import("tools/shell/process_provider.zig");
const process_provider = @import("core/execution/process_provider.zig");
const terminal_client_runtime = @import("core/terminal/client.zig");
const terminal_native_session = @import("core/terminal/native_session.zig");
const session_runtime = @import("core/session/session.zig");
const session_codec = @import("core/session/session_codec.zig");
const session_child_store = @import("core/session/session_child_store.zig");
const session_log = @import("core/session/session_log.zig");
const builtin_tools = @import("builtins/tools.zig");
const tool_admission = @import("core/tooling/tool_admission.zig");
const tool_projection = @import("core/tooling/tool_projection.zig");
const command_output_content = @import("core/tooling/command_output_content.zig");
const tool_dispatch = @import("core/tooling/tool_dispatch.zig");
const tool_set_contract = @import("core/tooling/tool_set.zig");
const tool_mcp_runtime = @import("core/tooling/tool_mcp_runtime.zig");
const tool_runtime = @import("core/tooling/tool_runtime.zig");
const web_fetch_runtime = @import("core/tooling/web_fetch_runtime.zig");
const web_search_runtime = @import("core/tooling/web_search_runtime.zig");
const worker_runtime = @import("core/agent/worker_runtime.zig");
const question_prompt = @import("core/agent/question_prompt.zig");
const gateway_client = @import("gateway/client.zig");
const url_opener = @import("core/hosts/url_opener.zig");
const event_loop = @import("ui/event_loop.zig");
const terminal_remote = @import("core/app/terminal_remote.zig");
const footer_runtime = @import("ui/footer/runtime.zig");
const question_ui = @import("ui/footer/question_ui.zig");
const ui_input = @import("ui/input/runtime.zig");
const input_action = @import("core/input/input_action.zig");
const paste_framing = @import("core/input/paste_framing.zig");
const registered_entities = @import("core/input/registered_entities.zig");
const ui_render = @import("ui/render.zig");
const shell_runtime = @import("ui/shell_runtime.zig");
const ui_terminal = @import("ui/terminal/terminal.zig");
const cursor_probe = @import("ui/terminal/cursor_probe.zig");
const ui_program_status = @import("ui/terminal/program_status.zig");
const transcript_runtime = @import("ui/transcript/runtime.zig");
const resume_projection = @import("ui/transcript/resume_projection.zig");
const assistant_pacer = @import("ui/assistant/pacer.zig");

const Allocator = std.mem.Allocator;
const Layout = types.Layout;
const Metrics = types.Metrics;
const StreamState = types.StreamState;
const ToolCall = types.ToolCall;
const ChatMessage = types.ChatMessage;
const PermissionMode = types.PermissionMode;
const ReasoningEffort = types.ReasoningEffort;
const ToolPermissionDecision = types.ToolPermissionDecision;
const QueuedPrompt = worker_runtime.QueuedPrompt;
const WorkItem = worker_runtime.WorkItem;
const WorkerRuntime = worker_runtime.WorkerRuntime;
const SessionRuntime = session_runtime.SessionRuntime;
const PromptHistoryRuntime = prompt_history_runtime.PromptHistoryRuntime;
const ToolExecutionResult = agent_runtime.ToolExecutionResult;
const QuestionPrompt = question_prompt.QuestionPrompt;
const InputRuntime = core_input_runtime.Runtime;
const TerminalInputRuntime = ui_input.Runtime;
const TerminalState = shell_runtime.TerminalState;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;
const ResumeProjection = resume_projection.ResumeProjection;
const RawEnviron = io_mod.RawEnviron;

const footer_rows: u16 = 4;
const active_poll_timeout_ms: i32 = 8;
const focused_ui_worker_poll_timeout_ms: i32 = 1;
const resize_debounce_ms: i64 = 100;
const max_transcript_bytes: usize = 256 * 1024;
const default_max_agent_steps: usize = agent_steps.default_max_agent_steps;
/// How many times a model request is retried after a transient failure.
const model_retry_count: usize = 3;
const max_history_turns = agents.max_history_turns;
const max_list_entries: usize = 100;
const max_read_file_bytes: usize = 50 * 1024;
const max_read_file_lines: usize = 400;
const max_read_file_line_len: usize = 2000;
const max_command_output_bytes: usize = 64 * 1024;
const input_escape_timeout_ms: i64 = 30;

/// The first frame counts as focused work: an idle wait before it would only
/// delay the launch.
fn nativeLoopPollTimeoutMs(
    default_timeout_ms: i32,
    first_frame_pending: bool,
    skills_refresh_active: bool,
    transcript_page_work_active: bool,
    file_listing_hold_pending: bool,
    /// A time-bounded drain put events back: run the next iteration without
    /// waiting for input.
    next_iteration_due: bool,
) i32 {
    if (next_iteration_due) return 0;
    return if (first_frame_pending or
        skills_refresh_active or
        transcript_page_work_active or
        file_listing_hold_pending)
        @min(default_timeout_ms, focused_ui_worker_poll_timeout_ms)
    else
        default_timeout_ms;
}

const max_prompt_history: usize = 100;

const ignored_list_entries = [_][]const u8{
    ".git",
    ".zig-cache",
    "zig-out",
    "node_modules",
    ".next",
    "dist",
    "build",
    "coverage",
};

fn dupeUniqueSkillBindingsFromTokens(
    alloc: Allocator,
    skill_tokens: []const registered_entities.SkillTokenSpan,
) ![]worker_runtime.SkillBinding {
    if (skill_tokens.len == 0) return &.{};

    var bindings: std.ArrayList(worker_runtime.SkillBinding) = .empty;
    errdefer {
        for (bindings.items) |binding| {
            alloc.free(binding.name);
            alloc.free(binding.path);
        }
        bindings.deinit(alloc);
    }

    for (skill_tokens) |token| {
        if (token.name.len == 0 or token.path.len == 0) continue;
        if (skillBindingPathSeen(bindings.items, token.path)) continue;

        const name_copy = try alloc.dupe(u8, token.name);
        var path_copy: []u8 = &.{};
        var appended = false;
        errdefer if (!appended) {
            alloc.free(name_copy);
            if (path_copy.len > 0) alloc.free(path_copy);
        };

        path_copy = try alloc.dupe(u8, token.path);
        try bindings.append(alloc, .{
            .name = name_copy,
            .path = path_copy,
        });
        appended = true;
    }

    if (bindings.items.len == 0) {
        bindings.deinit(alloc);
        return &.{};
    }
    return try bindings.toOwnedSlice(alloc);
}

fn skillBindingPathSeen(bindings: []const worker_runtime.SkillBinding, path: []const u8) bool {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.path, path)) return true;
    }
    return false;
}

fn dupeSkillDisplaySpansFromTokens(
    alloc: Allocator,
    skill_tokens: []const registered_entities.SkillTokenSpan,
) ![]worker_runtime.SkillDisplaySpan {
    if (skill_tokens.len == 0) return &.{};

    var spans: std.ArrayList(worker_runtime.SkillDisplaySpan) = .empty;
    errdefer {
        for (spans.items) |span| {
            alloc.free(span.name);
            alloc.free(span.path);
        }
        spans.deinit(alloc);
    }

    for (skill_tokens) |token| {
        if (token.name.len == 0 or token.path.len == 0) continue;

        const name_copy = try alloc.dupe(u8, token.name);
        var path_copy: []u8 = &.{};
        var appended = false;
        errdefer if (!appended) {
            alloc.free(name_copy);
            if (path_copy.len > 0) alloc.free(path_copy);
        };

        path_copy = try alloc.dupe(u8, token.path);
        try spans.append(alloc, .{
            .raw_start = token.raw_start,
            .raw_end = token.raw_end,
            .name = name_copy,
            .path = path_copy,
            .display_source = token.display_source,
            .owns_trailing_separator = token.owns_trailing_separator,
        });
        appended = true;
    }

    if (spans.items.len == 0) {
        spans.deinit(alloc);
        return &.{};
    }
    return try spans.toOwnedSlice(alloc);
}

fn promptCardSkillTokensFromDisplaySpans(
    alloc: Allocator,
    skill_display_spans: []const worker_runtime.SkillDisplaySpan,
) ![]registered_entities.SkillTokenSpan {
    if (skill_display_spans.len == 0) return &.{};
    const tokens = try alloc.alloc(registered_entities.SkillTokenSpan, skill_display_spans.len);
    errdefer alloc.free(tokens);
    for (skill_display_spans, 0..) |span, i| {
        tokens[i] = .{
            .raw_start = span.raw_start,
            .raw_end = span.raw_end,
            .name = span.name,
            .path = span.path,
            .display_source = span.display_source,
            .owns_trailing_separator = span.owns_trailing_separator,
        };
    }
    return tokens;
}

test "skill submit snapshot keeps display spans exact while agent bindings dedupe" {
    const alloc = std.testing.allocator;
    const tokens = [_]registered_entities.SkillTokenSpan{
        .{
            .raw_start = "raw $review then ".len,
            .raw_end = "raw $review then $review".len,
            .name = "review",
            .path = "/tmp/.codex/skills/review",
        },
        .{
            .raw_start = "raw $review then $review and ".len,
            .raw_end = "raw $review then $review and $review".len,
            .name = "review",
            .path = "/tmp/.codex/skills/review",
        },
    };

    const bindings = try dupeUniqueSkillBindingsFromTokens(alloc, &tokens);
    defer worker_runtime.freeSkillBindings(alloc, bindings);
    const display_spans = try dupeSkillDisplaySpansFromTokens(alloc, &tokens);
    defer worker_runtime.freeSkillDisplaySpans(alloc, display_spans);

    try std.testing.expectEqual(@as(usize, 1), bindings.len);
    try std.testing.expectEqualStrings("review", bindings[0].name);
    try std.testing.expectEqual(@as(usize, 2), display_spans.len);
    try std.testing.expectEqual(tokens[0].raw_start, display_spans[0].raw_start);
    try std.testing.expectEqual(tokens[1].raw_start, display_spans[1].raw_start);
}

var resize_interlock = shell_runtime.ResizeApprovalInterlock{};
const default_context_registry = context_contract.Registry{ .default_provider = builtin_context.provider };
fn currentBuild() update_target.CurrentBuild {
    return .{
        .channel = compiled_update_channel,
        .version = version,
        .revision = build_options.git_commit,
    };
}

const App = struct {
    pub const app_version = version;
    pub const input_limits = paste_framing.default_input_limits;
    pub const build_update_channel = compiled_update_channel;
    pub const build_revision = build_options.git_commit;
    const Self = @This();
    const AgentAppRuntime = app_agent_runtime.Runtime(Self);
    const AuthAppRuntime = app_auth_runtime.Runtime(Self);
    const BootstrapAppRuntime = app_bootstrap_runtime.Runtime(Self);
    const ProfileAppRuntime = app_profile_runtime.Runtime(Self);
    const InputAppRuntime = app_input_runtime.Runtime(Self);
    const InputFullTranscriptRuntime = input_full_transcript_runtime.Runtime(Self);
    const InputSubmitRuntime = input_submit_runtime.SubmitRuntime(Self);
    const NotificationAppRuntime = app_notification_runtime.Runtime(
        Self,
        builtin_hooks.notifications.provider(Self),
    );
    const HerdrAppRuntime = builtin_hooks.Runtime(Self);
    const RenderAppRuntime = app_render_runtime.Runtime(Self);
    const SessionAppRuntime = app_session_runtime.Runtime(Self);
    const UpgradeAppRuntime = app_upgrade_runtime.Runtime(Self);
    const WorkerAppRuntime = app_worker_runtime.Runtime(Self);
    const AgentsAppRuntime = app_agents_runtime.Runtime(Self);
    const InstancesAppRuntime = app_instances_runtime.Runtime(Self);
    const WorkspaceAppRuntime = app_workspace_runtime.Runtime(Self);

    pub fn contextRegistry(_: *const Self) context_contract.Registry {
        return default_context_registry;
    }

    pub fn promptPolicy(_: *const Self, agent: *const agents.Agent) prompt_policy.Policy {
        var policy = builtin_context.prompt_policy;
        if (agent.profile.system_prompt) |system_prompt| policy.system_prompt = system_prompt;
        if (agent.custom_prompt.text) |text| {
            policy.system_prompt = text;
            policy.embedded_system_prompt = null;
            policy.model_prompt_overlay_fn = null;
            policy.exclusive = true;
        }
        return policy;
    }

    pub fn slashRegistry(self: *const Self) command_specs.SlashRegistry {
        var registry = builtin_commands.slash_registry;
        registry.argument_groups = .{ self.mcp.host_completion, self.launch_completion.entries, self.prompt_completion.entries };
        return registry;
    }

    pub fn skillsCommandProvider(_: *const Self) skill_commands.Provider {
        return builtin_skills.command_provider;
    }

    pub fn urlOpener(_: *const Self) host.UrlOpener {
        return url_opener.native_opener;
    }

    pub fn creditsProvider(self: *const Self) gateway_provider.CreditsProvider {
        return self.providerSet()
            .select(self.provider_selection.selection().provider)
            .credits orelse gateway_provider.unavailable_credits_provider;
    }

    pub fn agentStreamProvider(self: *const Self) agent_stream_provider.Provider {
        return self.providerSet()
            .select(self.provider_selection.selection().provider)
            .agent_stream_or_unavailable();
    }

    /// Fixed low-cost model the active provider uses for session title
    /// generation; null when the provider does not support generated titles.
    pub fn sessionTitleModel(self: *const Self) ?[]const u8 {
        return self.providerSet()
            .select(self.provider_selection.selection().provider)
            .title_model;
    }

    pub fn providerCatalog(self: *Self, provider: model_provider.ProviderId) ?model_catalog.Provider {
        return self.providerSet().select(provider).model_catalog;
    }

    pub fn secretStore(self: *const Self) host.SecretStore {
        return self.auth.secretStore();
    }

    pub fn clipboard(_: *const Self) host.Clipboard {
        return native_host.clipboard;
    }

    pub fn terminalTitle(self: *const Self) host.TerminalTitle {
        return ui_render.terminalTitleFor(&self.shell.stdout_file);
    }

    pub fn writeProgramStatus(self: *Self, report: []const u8) void {
        self.shell.writeProgramStatus(&self.metrics, report);
    }

    alloc: Allocator,
    terminal: TerminalState = .{},

    auth: auth_runtime.Runtime = .{},
    provider_selection: provider_runtime.Runtime = provider_runtime.Runtime.init(std.heap.c_allocator),
    model_cache: model_cache_runtime.Runtime = model_cache_runtime.Runtime.init(std.heap.c_allocator),
    workspace_root: []u8 = &.{},
    workspace_identity: statusline_identity.Runtime = .{},
    workspace: app_workspace_runtime.State = .{},
    authority_mutex: std.Io.Mutex = .init,
    agent_step_limit: usize = default_max_agent_steps,
    web_fetch_runtime: web_fetch_runtime.Runtime = web_fetch_runtime.Runtime.init(.{}),
    web_search_runtime: web_search_runtime.Runtime = web_search_runtime.Runtime.init(.{}),
    lifecycle_runtime: hooks.Runtime = hooks.Runtime.init(std.heap.c_allocator),
    lifecycle_view: hooks.RuntimeView = hooks.RuntimeView.empty(),
    notifications: builtin_hooks.notifications.State = .{},
    herdr: builtin_hooks.Client = .{},
    program_status: ui_program_status.Reporter = .{},

    prompt_history: PromptHistoryRuntime = .{},
    requested_resume: ?cli_surface.ResumeTarget = null,

    should_exit: bool = false,
    input_runtime: InputRuntime = .{},
    terminal_input_runtime: TerminalInputRuntime = .{},
    /// The main conversation's own state.
    main_agent: agents.Agent = .{},
    /// The agent the main loop is working for. Null means main, so `App` can
    /// move by value before the loop starts; a visit to main while a
    /// subagent is on screen points it at `main_agent`. Read only through
    /// `screenAgent`.
    screen_owner: ?*agents.Agent = null,
    /// Every agent the app runs besides the first instance: the other
    /// instances, in launch order, and the subagents, in the order they
    /// started, each marked by its role. Owned by
    /// `app_agents_runtime`.
    child_agents: std.ArrayList(*app_agents_runtime.ChildAgent) = .empty,
    /// What every instance starts from, and how many startup opens. Owned
    /// by `app_instances_runtime`.
    instances: app_instances_runtime.State = .{},
    /// The subagent on screen, or null while main is. Owned by
    /// `app_agents_runtime.zig`, which moves screens between agents.
    agent_on_screen: ?*app_agents_runtime.ChildAgent = null,
    /// Main's transcript, paced text, and draft while a subagent is on screen.
    main_screen: app_agents_runtime.ScreenSlot = .{},
    /// The subagent whose question main's prompt holds, while main is on
    /// screen. Owned by `app_agents_runtime.zig`.
    question_lender: ?*app_agents_runtime.ChildAgent = null,
    /// The subagent whose approval main's prompt holds, while main is on
    /// screen. Owned by `app_agents_runtime.zig`.
    /// How many subagent prompts have been asked, which orders them for the
    /// instance's screen. Owned by `app_agents_runtime.zig`.
    prompt_order: u64 = 0,
    /// Runs the subagent host hands to child agents. Owned by
    /// `app_agents_runtime`.
    child_handoffs: app_agents_runtime.Handoffs = .{},
    shell: TranscriptRuntime = .{},
    pacer: assistant_pacer.AssistantPacer = .{},

    terminal_client: terminal_client_runtime.Runtime = .{},

    upgrader: auto_upgrade.AutoUpgrade = .{},
    mcp: app_mcp_runtime.State = .{},
    /// The profiles `/launch` completes.
    launch_completion: app_profile_runtime.LaunchCompletion = .{},
    prompt_completion: prompts.Completion = .{},
    /// Whether thinking blocks show their reasoning (Ctrl+O). Off: each is
    /// one "Thought for 3s" line, and the status line counts the thinking.
    show_reasoning: bool = false,
    /// The launch animation under the composer; gone after the first keystroke.
    splash: splash_mod.State = .{},
    /// Reveals reasoning and the reply's line in progress word by word.
    live_pacer: live_preview_mod.Pacer = .{},
    skills: skill_runtime.Runtime = .{},
    file_index: file_index_mod.FileIndex = .{},
    context_enabled: bool = true,
    context_limits: config_runtime.context_limits.Values = .{},
    /// Where built-in tools are offered, from the settings files.
    tool_placement: config_runtime.tool_placement.Overrides = .{},
    /// The built-in tools offered through toolbox, fixed for the process, so
    /// a conversation's tools never change while it runs.
    toolbox_behind: config_runtime.tool_placement.Behind = config_runtime.tool_placement.behindToolbox(.{}, &.{}),
    fast_mode: bool = false,
    auto_upgrade_enabled: bool = true,
    /// `/update` is waiting for its check: it reports the result, or
    /// restarts into the update once it is installed.
    manual_update: app_upgrade_runtime.ManualUpdate = .{},

    statusline_context: bool = false,
    remote: terminal_remote.State = .{},
    statusline_session: bool = false,
    /// Resolved `session_titles` preference: generate a model-written session
    /// title from the first prompt of a fresh session.
    session_title_generation: bool = true,
    /// Resolved `cache_warming` preference: ping a waiting Claude
    /// conversation's prompt cache so it stays alive.
    cache_warming: bool = true,

    metrics: Metrics = .{},
    pub fn screenAgent(self: anytype) @TypeOf(&self.main_agent) {
        agents.assertLoopThread(@returnAddress());
        return self.screen_owner orelse &self.main_agent;
    }

    pub fn init(
        alloc: Allocator,
        launch: *cli_surface.InteractiveLaunch,
        auth_mode: credentials.AuthMode,
    ) !Self {
        var app = Self{
            .alloc = alloc,
            .auth = .{
                .mode = auth_mode,
                .oauth = builtin_oauth_http.provider,
                .secrets = native_host.secret_store,
            },
            .input_runtime = undefined,
            .shell = TranscriptRuntime.init(),
            .lifecycle_runtime = hooks.Runtime.init(alloc),
            .terminal_client = terminal_client_runtime.Runtime.init(shell_process_provider.provider),

            .main_agent = .{ .session_persistence = undefined, .session = undefined },
        };
        app_session_runtime.Persistence.initInto(&app.main_agent.session_persistence);
        InputRuntime.initInto(&app.input_runtime);
        SessionRuntime.initInto(&app.main_agent.session, max_history_turns);
        app.main_agent.worker.trace_agent = "main";
        app.shell.notebook.max_transcript_bytes = max_transcript_bytes;
        if (launch.requested_resume) |target| {
            app.requested_resume = target;
            launch.requested_resume = null;
        }
        errdefer if (app.requested_resume) |*target| target.deinit(alloc);
        // The `spark "<prompt>"` prompt is the first instance's.
        app.main_agent.submission.launch_prompt = launch.initial_prompt;
        launch.initial_prompt = null;
        errdefer if (app.main_agent.submission.launch_prompt) |prompt| alloc.free(prompt);

        if (launch.modifiers.profile_name) |name| {
            try ProfileAppRuntime.applyLaunchProfile(&app, name, builtin_context.prompt_policy.system_prompt, builtin_tools.advertisement_set);
        }
        const launch_profile = &app.main_agent.profile.profile;
        const launch_model = app_profile_runtime.launchModel(
            launch.modifiers.model_override,
            launch.modifiers.provider_override != null,
            config_runtime.modelEnvOverride(),
            launch_profile.model,
        );
        try BootstrapAppRuntime.bootstrap(
            &app,
            &app.main_agent,
            footer_rows,
            "",
            default_max_agent_steps,
            handle_sigwinch,
            .{
                .load_mcp_host = builtin_mcp.loadHost,
                .skill_root_policy = builtin_skills.root_policy,
                .terminal_title = app.terminalTitle(),
            },
            .{
                .provider = launch.modifiers.provider_override,
                .model = launch_model,
                .effort = launch.modifiers.effort_override orelse launch_profile.effort,
                .model_from_profile = launch.modifiers.model_override == null and launch_model != null,
                .effort_from_profile = launch.modifiers.effort_override == null and launch_profile.effort != null,
                .fast = launch.modifiers.fast_override,
                .ultrafast = launch.modifiers.ultrafast_override,
                .permission_mode = launch.modifiers.permission_override,
                .upgrade_relaunch = launch.upgrade_relaunch != null,
            },
        );
        errdefer app.deinit();
        if (launch.modifiers.profile_name != null) try ProfileAppRuntime.applyLaunchMode(&app);
        // The first instance is launched; startup opens the rest once the
        // app has its final address.
        try app.instances.seed.captureProfile(alloc, launch.modifiers.profile_name);
        app.instances.launched = 1;
        app.instances.startup_count = launch.modifiers.instances orelse app_instances_runtime.testHookCount();
        try WorkspaceAppRuntime.applyLaunch(
            &app,
            launch.modifiers.additional_directories,
            launch.modifiers.saved_directories_suppressed,
        );
        app.provider_selection.ensureGatewayHttpPool();
        app.context_limits.applyCommandLine(launch.modifiers.context_limit_overrides);
        app.toolbox_behind = config_runtime.tool_placement.behindToolbox(app.tool_placement, launch.modifiers.tool_placement_overrides);
        // The launch profile narrowed main's tools before the tools behind
        // toolbox were placed; a tool it lists that now sits there needs
        // toolbox.
        if (launch.modifiers.profile_name != null) {
            try ProfileAppRuntime.narrowProfileTools(&app, &app.main_agent, builtin_tools.advertisement_set);
        }
        if (app.requested_resume != null) {
            const picks = app.requested_resume.? == .pick;
            const resumed = if (launch.upgrade_relaunch != null)
                SessionAppRuntime.resumeRequestedSessionAfterUpgrade(
                    &app,
                    &app.main_agent,
                    app_version,
                    build_update_channel,
                    launch.upgrade_relaunch.?.previous_revision orelse "",
                    build_revision,
                )
            else
                SessionAppRuntime.resumeRequestedSession(&app, &app.main_agent);
            resumed catch |err| {
                // Why a v1 session could not be converted, for the exit message (D61).
                launch.resume_refusal = SessionAppRuntime.conversionRefusal(&app.main_agent, alloc, err);
                return err;
            };
            // Resuming brings the session's whole host back:
            // with the startup instances, or once the picker has chosen.
            if (picks) app.instances.restore_on_pick = true else app.instances.restore_pending = true;
            SessionAppRuntime.syncTerminalTitle(&app, &app.main_agent);
        } else if (launch.upgrade_relaunch) |relaunch| {
            SessionAppRuntime.writeUpgradeNotice(&app, app_version, build_update_channel, relaunch.previous_revision orelse "", build_revision) catch |err|
                debug_trace.logf("session", "event=upgrade_notice_unavailable err={s}", .{@errorName(err)});
        } else {
            SessionAppRuntime.queueInterruptedTurnHint(&app);
        }
        const env_disabled = if (io_mod.getenv("SPARK_AUTO_UPGRADE")) |val| env_settings.autoUpgradeOff(val) else false;
        if (env_disabled or !auto_upgrade.shouldEnableForCurrentExecutable()) {
            app.auto_upgrade_enabled = false;
        }
        SessionAppRuntime.syncTerminalTitle(&app, &app.main_agent);
        return app;
    }

    pub fn configureNotifications(self: *App, agent: *agents.Agent) !void {
        // Register herdr hooks before NotificationAppRuntime.configure freezes
        // the lifecycle runtime (its call to freeze() is the sole freeze site).
        try HerdrAppRuntime.configure(self, SessionAppRuntime.activeSessionId(agent));
        try NotificationAppRuntime.configure(self);
    }

    pub fn rebindAfterInit(self: *App, agent: *agents.Agent) void {
        SessionAppRuntime.rebindAfterMove(self, agent);
    }

    pub fn setNotificationPreferences(
        self: *App,
        turn_end: bool,
        attention_required: bool,
        max: bool,
    ) void {
        NotificationAppRuntime.setPreferences(self, .{
            .turn_end = turn_end,
            .attention_required = attention_required,
            .max = max,
        });
    }

    pub fn notificationPreferences(self: *const App) app_notification_runtime.Preferences {
        return NotificationAppRuntime.preferences(self);
    }

    pub fn soundMaxEnabled(self: *const App) bool {
        return NotificationAppRuntime.maxEnabled(self);
    }

    pub fn queueNotification(
        self: *App,
        notification: app_notification_runtime.Notification,
    ) void {
        NotificationAppRuntime.queue(self, notification);
    }

    pub fn notificationPresentationFinished(self: *App) void {
        NotificationAppRuntime.presentationFinished(self);
    }

    pub fn flushNotifications(self: *App) void {
        NotificationAppRuntime.flush(self);
    }

    pub fn playStartupSound(self: *App) void {
        NotificationAppRuntime.playCue(self, .bloom);
    }

    pub fn playCancelSound(self: *App) void {
        NotificationAppRuntime.playCue(self, .press);
    }

    pub fn playInteractionSound(self: *App) void {
        NotificationAppRuntime.playCue(self, .click);
    }

    pub fn playInputClearedSound(self: *App) void {
        NotificationAppRuntime.playMaxCue(self, .release);
    }

    pub fn playSlashMenuSound(self: *App) void {
        NotificationAppRuntime.playMaxCue(self, .toggle);
    }

    /// What the busiest open agent is doing, for herdr's pane state.
    pub fn agentsBusiest(self: *App) app_agents_runtime.Busiest {
        return AgentsAppRuntime.busiest(self);
    }

    /// An agent other than the one on screen that an upgrade's restart
    /// would stop. Its name may use `buf`.
    pub fn busyAgentElsewhere(self: *App, buf: []u8) ?app_agents_runtime.BusyAgent {
        return AgentsAppRuntime.busyAgentElsewhere(self, buf);
    }

    /// `agent`'s turn needs the user: an approval or a question.
    pub fn dispatchAttentionRequired(
        self: *App,
        agent: *agents.Agent,
        turn_id: u64,
        kind: hooks.AttentionKind,
    ) void {
        NotificationAppRuntime.dispatchAttentionRequired(self, SessionAppRuntime.activeSessionId(agent), turn_id, kind);
    }

    /// Must be called after init() returns so the AutoUpgrade thread
    /// captures a pointer to the final App location (not a temporary).
    pub fn startAutoUpgrade(self: *App) void {
        if (self.auto_upgrade_enabled) {
            self.upgrader.start(self.alloc, currentBuild());
        }
    }

    pub fn applyReadyUpgradeShortcut(self: *App, agent: *agents.Agent) !void {
        try UpgradeAppRuntime.applyReadyUpgrade(self, agent);
    }

    /// `/update`: restarts into an update that is ready, or checks GitHub now.
    pub fn requestManualUpdate(self: *App, agent: *agents.Agent) !void {
        try UpgradeAppRuntime.requestManualUpdate(self, agent);
    }

    pub fn prepareResumeHandoffForUpgrade(_: *App, agent: *agents.Agent) !void {
        try SessionAppRuntime.prepareResumeHandoff(agent);
    }

    pub fn requestUpgradeRelaunch(
        self: *App,
        executable_path: []const u8,
    ) !void {
        try self.upgrader.requestRelaunch(executable_path);
    }

    pub fn requestResumeHandoffForUpgrade(_: *App, agent: *agents.Agent) void {
        SessionAppRuntime.requestUpgradeResumeHandoff(agent);
    }

    pub fn takeUpgradeRelaunchRequest(
        self: *App,
    ) ?auto_upgrade.RelaunchRequest {
        return self.upgrader.takeRelaunchRequest();
    }

    /// Native interactive exit. Runs only the work whose effects outlive the
    /// process: restoring the terminal, persisting the session, finishing
    /// durable credential saves, and terminating child processes. Memory and
    /// threads that hold no durable state are left for process exit, so a
    /// thread blocked on the network or a disk scan cannot hold the prompt.
    /// The caller must end the process without further teardown; the returned
    /// handoff is owned by the caller.
    pub fn shutdownForProcessExit(self: *App) app_session_runtime.ShutdownOutcome {
        // Shutdown is main's own; its subagents stop in stopChildren and
        // shutdownChildren. Main is named here, not found as the agent on
        // screen, so quitting from a subagent's screen stops main.
        const main_agent = &self.main_agent;
        var shutdown_trace = app_lifecycle.ShutdownStageTrace.init();
        // Failed startups (no TTY, too small) never earn a shutdown report.
        const was_interactive = self.terminal.raw_enabled or self.terminal.signal_handler_installed;
        // Hand the terminal back first; nothing below renders.
        self.releaseTerminal();
        shutdown_trace.mark("terminal_released");

        // Client.deinit releases the herdr pane (clear agent + label) when enabled.
        self.herdr.deinit();
        self.stopStream(main_agent);
        main_agent.worker.requestShutdown();
        SessionAppRuntime.requestPersistenceShutdown(main_agent);
        self.upgrader.stopForProcessExit();
        self.file_index.requestStop();
        WorkspaceAppRuntime.requestStop(self);
        main_agent.managed_executions.terminateForProcessExit();
        shutdown_trace.mark("background_stops_requested");
        // Terminals belong to this process and end with it, with no prompt.
        // Subagents share this client, so theirs end here too. Ending them
        // also releases a worker waiting on one.
        self.terminal_client.closeOwnedTerminals();
        shutdown_trace.mark("terminals_ended");
        // Main's worker can be waiting on a subagent call.
        AgentsAppRuntime.stopChildren(self, .force);

        // The worker mutates session state, so it stops before persistence.
        if (main_agent.worker_thread) |thread| thread.join();
        shutdown_trace.mark("worker_thread_joined");
        WorkerAppRuntime.settleFinishedPromptsForShutdown(self, main_agent) catch |err| {
            SessionAppRuntime.recordShutdownFailure(main_agent, err);
        };
        InputSubmitRuntime.clearPendingSubmission(self, main_agent, "shutdown");
        InputSubmitRuntime.discardLaunchPrompt(self, "shutdown");
        // Quitting from a subagent's screen resumes its instance.
        AgentsAppRuntime.liftResumeIntent(self);
        // Children close first: they borrow main's session store.
        AgentsAppRuntime.shutdownChildren(self);
        // The resume command is the first instance's, or the launched
        // instance's the user quit from, which its teardown kept.
        const resume_handoff = SessionAppRuntime.finalizePersistenceWithResumeHandoff(self, main_agent) orelse
            self.instances.takeExitHandoff();
        const shutdown_failure = main_agent.session_persistence.shutdown_failure;
        // These delete image snapshots and log discarded drafts.
        main_agent.worker.deinit(std.heap.c_allocator);
        self.clearPendingImages(main_agent);
        // Full-detail loads read saved results through the session store,
        // so their threads end before it closes.
        self.shell.stopBackgroundLoads();
        shutdown_trace.mark("transcript_loads_stopped");
        SessionAppRuntime.deinitPersistenceForProcessExit(self, main_agent);
        main_agent.question_prompt.deinit(self.alloc);
        shutdown_trace.mark("persistence_finalized");

        // Waits for an in-flight API key or credential save to land.
        self.auth.deinit(self.alloc);
        shutdown_trace.mark("credentials_saved");
        self.mcp.deinitForProcessExit();
        shutdown_trace.mark("mcp_children_terminated");
        self.remote.deinit(self.alloc);
        shutdown_trace.mark("complete");
        if (was_interactive) app_lifecycle.writeLastShutdownReport(self.alloc, &shutdown_trace);
        return .{ .handoff = resume_handoff, .failure = shutdown_failure };
    }

    pub fn formatResumeHandoff(buffer: []u8, session_id: []const u8) ![]const u8 {
        return ui_render.formatResumeHandoff(buffer, session_id);
    }

    /// Full teardown for hosts that keep running after the shell ends. Native
    /// interactive exit uses `shutdownForProcessExit`.
    pub fn planBrowser(_: *App) host.UrlOpener {
        return url_opener.native_opener;
    }

    pub fn planTransport(_: *App) oauth_transport.Provider {
        return builtin_oauth_http.provider;
    }

    pub fn deinit(self: *App) void {
        // Shutdown is main's own; its subagents stop in stopChildren and
        // shutdownChildren. Main is named here, not found as the agent on
        // screen, so quitting from a subagent's screen stops main.
        const main_agent = &self.main_agent;
        var shutdown_trace = app_lifecycle.ShutdownStageTrace.init();
        // Only real interactive sessions earn a shutdown report; failed
        // startups (no TTY, too small) reach deinit through errdefer and must
        // not write to the profile directory.
        const was_interactive = self.terminal.raw_enabled or self.terminal.signal_handler_installed;
        // Client.deinit releases the herdr pane (clear agent + label) when enabled.
        self.herdr.deinit();
        self.stopStream(main_agent);
        shutdown_trace.mark("stop_stream");

        main_agent.worker.requestShutdown();
        SessionAppRuntime.requestPersistenceShutdown(main_agent);
        main_agent.managed_executions.shutdown();
        self.terminal_client.closeOwnedTerminals();
        self.upgrader.stop();
        self.file_index.requestStop();
        WorkspaceAppRuntime.requestStop(self);
        shutdown_trace.mark("background_stops_requested");

        self.releaseTerminal();
        // Main's worker can be waiting on a subagent call.
        AgentsAppRuntime.stopChildren(self, .cooperative);
        if (main_agent.worker_thread) |thread| thread.join();
        shutdown_trace.mark("worker_thread_joined");
        self.remote.deinit(self.alloc);
        // No agent turn can arm the warmer now, and its pings must stop
        // before the providers they use are released below. Each other
        // agent's session closed its own warmer with it.
        main_agent.session.closeCacheWarmer();
        WorkerAppRuntime.settleFinishedPromptsForShutdown(self, main_agent) catch |err| {
            SessionAppRuntime.recordShutdownFailure(main_agent, err);
        };
        self.terminal_client.deinit();
        main_agent.managed_executions.deinit();
        self.model_cache.deinit();
        InputSubmitRuntime.clearPendingSubmission(self, main_agent, "shutdown");
        InputSubmitRuntime.discardLaunchPrompt(self, "shutdown");
        // Children close first: they borrow main's session store.
        AgentsAppRuntime.shutdownChildren(self);
        SessionAppRuntime.finalizePersistence(self, main_agent);
        shutdown_trace.mark("persistence_finalized");
        main_agent.worker.deinit(std.heap.c_allocator);
        self.web_fetch_runtime.deinit(self.alloc);
        self.web_search_runtime.deinit();
        self.prompt_history.deinit(self.alloc);
        self.clearPendingImages(main_agent);
        main_agent.pending_images.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.terminal_input_runtime.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        AgentsAppRuntime.deinitChildren(self);
        self.instances.deinit(self.alloc);
        self.pacer.deinit(self.alloc);
        main_agent.session_title.deinit(self.alloc);
        SessionAppRuntime.deinitPersistence(self, main_agent);
        self.provider_selection.deinit();
        if (self.requested_resume) |*target| {
            target.deinit(self.alloc);
            self.requested_resume = null;
        }
        main_agent.session.deinit(self.alloc);
        main_agent.question_prompt.deinit(self.alloc);

        main_agent.change_tracker.deinit(std.heap.c_allocator);
        for (main_agent.diff_entries.items) |*entry| entry.deinit(std.heap.c_allocator);
        main_agent.diff_entries.deinit(std.heap.c_allocator);
        self.mcp.deinit();
        shutdown_trace.mark("mcp_deinit");
        self.launch_completion.deinit();
        self.prompt_completion.deinit();
        self.skills.deinit(std.heap.c_allocator);
        main_agent.context_snapshot.deinit(self.alloc);
        self.main_agent.profile.deinit();
        self.file_index.deinit(std.heap.c_allocator);
        self.lifecycle_runtime.deinit();

        self.auth.deinit(self.alloc);
        WorkspaceAppRuntime.deinit(self);
        self.workspace_identity.deinit(self.alloc);
        if (self.workspace_root.len > 0) self.alloc.free(self.workspace_root);
        shutdown_trace.mark("complete");
        if (was_interactive) app_lifecycle.writeLastShutdownReport(self.alloc, &shutdown_trace);
    }

    /// Ends spark as a closed window while the main conversation's turn runs
    /// (`app_lifecycle.closeOnHangup`); returns when no turn is running.
    pub fn closeOnHangup(self: *App) void {
        app_lifecycle.closeOnHangup(self.main_agent.worker.isProcessing());
    }

    pub fn releaseTerminal(self: *App) void {
        if (!self.terminal.raw_enabled and !self.terminal.signal_handler_installed) return;
        app_lifecycle.shutdownInteractiveShell(
            &self.terminal,
            &self.shell,
            &self.metrics,
            self.terminalTitle(),
        );
    }

    pub fn flushBeforeBlockingExternalWork(self: *App) !void {
        try self.flushRequestedFrame();
    }

    pub fn suspendToJobControl(self: *App) !void {
        try self.flushBeforeBlockingExternalWork();
        // Suspending clears spark's program status record; report it again on resume.
        defer self.program_status.invalidate();
        try SessionAppRuntime.suspendToJobControl(self, footer_rows);
        // The suspend restore turned theme notifications off, and the theme
        // may have changed while spark was stopped.
        self.terminal_input_runtime.terminal_theme_monitor.requestRearm();
    }

    pub fn ensurePromptCredential(self: *App, agent: *agents.Agent) !bool {
        return AuthAppRuntime.admitPromptCredential(self, agent);
    }

    pub fn admitQueuedPromptCredential(self: *App, agent: *agents.Agent) !bool {
        return AuthAppRuntime.admitQueuedPromptCredential(self, agent);
    }

    pub fn restoreSessionCredential(self: *App, previous_provider: model_provider.ProviderId) !void {
        try AuthAppRuntime.restoreSessionCredential(self, previous_provider);
    }

    pub fn collectPendingPromptCredential(
        self: *App,
        agent: *agents.Agent,
    ) !app_auth_runtime.PendingPromptCredentialReadiness {
        return AuthAppRuntime.collectPendingPromptCredential(self, agent);
    }

    pub fn retryPendingPromptCredential(
        self: *App,
        agent: *agents.Agent,
    ) !app_auth_runtime.PendingPromptCredentialReadiness {
        return AuthAppRuntime.retryPendingPromptCredential(self, agent);
    }

    pub fn requestPromptRetryAfterAuth(_: *App, agent: *agents.Agent) void {
        InputSubmitRuntime.requestPromptRetryAfterAuth(agent);
    }

    pub fn cancelPromptRetryAfterAuth(self: *App, agent: *agents.Agent) void {
        InputSubmitRuntime.cancelPromptRetryAfterAuth(self, agent);
    }

    pub fn resumePromptAfterAuth(self: *App, agent: *agents.Agent) !void {
        try InputSubmitRuntime.resumePromptAfterAuth(self, agent, max_prompt_history);
    }

    pub fn saveConnection(self: *App, agent: *agents.Agent) !void {
        try app_provider_menu_runtime.Runtime(App).saveConnection(self, agent);
    }

    pub fn run(self: *App) !void {
        const callbacks = RenderAppRuntime.eventLoopCallbacks(self);
        while (true) {
            const exit_cause = try event_loop.run(
                self.terminal,
                &self.should_exit,
                active_poll_timeout_ms,
                callbacks,
            );
            switch (exit_cause) {
                .requested_exit => return,
                .input_closed => return error.TerminalInputClosed,
            }
        }
    }

    pub fn loopPollTimeoutMs(ctx: *anyopaque, default_timeout_ms: i32) i32 {
        const self: *App = @ptrCast(@alignCast(ctx));
        return nativeLoopPollTimeoutMs(
            default_timeout_ms,
            self.shell.render_requests.hasReason(.first_frame),
            self.skills.refreshActive(),
            self.fullTranscriptFocusedWorkActive(),
            InputAppRuntime.fileListingHoldPending(self, io_mod.awakeMilliTimestamp()),
            self.takeDrainContinuationDue(),
        );
    }

    /// Whether any agent's budgeted drain put events back for the loop's next
    /// turn, which then polls without waiting. Takes every agent's flag.
    fn takeDrainContinuationDue(self: *App) bool {
        var due = self.main_agent.worker.takeDrainContinuationDue();
        for (self.child_agents.items) |child| {
            if (child.agent.worker.takeDrainContinuationDue()) due = true;
        }
        return due;
    }

    fn fullTranscriptFocusedWorkActive(self: *App) bool {
        return self.shell.fullTranscriptFocusedWorkActive() or
            (self.shell.fullTranscriptOpenOrOpening() and
                self.screenAgent().session_persistence.transcript_archive_read.busy());
    }

    fn flushRequestedFrame(self: *App) !void {
        try RenderAppRuntime.flushRequestedFrame(self, self.screenAgent());
    }

    pub fn handleCommand(self: *App, cmd: []const u8) !void {
        try app_commands.Handlers(App).route(self, cmd);
    }

    pub fn clearPendingImages(self: *App, agent: *agents.Agent) void {
        InputAppRuntime.clearPendingImages(self, agent);
    }

    pub fn releasePendingImages(self: *App, agent: *agents.Agent) void {
        InputAppRuntime.releasePendingImages(self, agent);
    }

    pub fn nextImageId(_: *App, agent: *agents.Agent) usize {
        return image_attachments.allocateImageId(&agent.next_image_id);
    }

    pub fn peekNextImageId(_: *const App, agent: *const agents.Agent) usize {
        return agent.next_image_id;
    }

    pub fn captureImageAttachment(self: *App, agent: *agents.Agent, attachment: *types.ImageAttachment) !void {
        try SessionAppRuntime.captureImageAttachment(self, agent, attachment);
    }

    pub fn enqueuePrompt(self: *App, agent: *agents.Agent, prompt: []const u8) !bool {
        return self.enqueuePromptWithSkillBindings(agent, prompt, &.{});
    }

    pub fn enqueuePromptWithSkillBindings(self: *App, agent: *agents.Agent, prompt: []const u8, skill_tokens: []const registered_entities.SkillTokenSpan) !bool {
        return self.admitInteractiveText(agent, prompt, skill_tokens, null);
    }

    fn admitInteractiveText(self: *App, agent: *agents.Agent, prompt: []const u8, skill_tokens: []const registered_entities.SkillTokenSpan, images: ?[]const types.ImageAttachment) !bool {
        try AgentAppRuntime.refreshProjectContext(self, agent);
        self.noteModelCatalogActivity();
        agent.session.setConversationLanguageFromUserMessage(prompt);

        debug_trace.logf(
            "prompt",
            "enqueue bytes={d} stream_active={s} queued_before={d} preview=\"{s}\"",
            .{
                prompt.len,
                if (agent.stream.active) "true" else "false",
                agent.worker.queuedPromptCount(),
                debug_trace.preview(prompt, 120),
            },
        );
        const queued = try self.snapshotPrompt(agent, prompt, skill_tokens, null, images, 0, false);
        agent.worker.admitInteractivePrompt(std.heap.c_allocator, queued) catch |err| {
            releaseUnadmittedPrompt(agent, queued);
            return err;
        };
        WorkerAppRuntime.syncState(
            self,
            agent,
            app_callbacks.Bindings(App).worker_tool_lifecycle_presenter(agent),
        );
        return true;
    }

    /// A prompt the user submitted is activity, so a stale or failed model
    /// catalog refetches in the background. Only these submission paths call
    /// it: a recovery continuation can queue during startup, before the App
    /// reaches the address a fetch thread may hold.
    fn noteModelCatalogActivity(self: *App) void {
        self.startModelCacheWarmup();
    }

    pub fn adoptPendingUserPrompt(
        self: *App,
        agent: *agents.Agent,
        draft: *const input_submit_runtime.PendingPromptDraft,
    ) !void {
        try self.writeUserPromptCardWithSkillBindings(
            agent,
            .{ .text = draft.prompt, .images = draft.images },
            &.{},
            draft.skill_display_spans,
        );
    }

    pub fn finalizePendingSubmission(
        self: *App,
        agent: *agents.Agent,
        draft: *const input_submit_runtime.PendingPromptDraft,
    ) !void {
        try AgentAppRuntime.refreshProjectContext(self, agent);
        self.noteModelCatalogActivity();
        agent.session.setConversationLanguageFromUserMessage(draft.prompt);

        const skill_tokens = try promptCardSkillTokensFromDisplaySpans(
            self.alloc,
            draft.skill_display_spans,
        );
        defer if (skill_tokens.len > 0) self.alloc.free(skill_tokens);
        if (!try self.snapshotAndQueuePrompt(
            agent,
            draft.prompt,
            skill_tokens,
            null,
            draft.images,
            draft.turn_id,
            true,
        )) return error.PendingPromptQueueRejected;
        WorkerAppRuntime.syncState(
            self,
            agent,
            app_callbacks.Bindings(App).worker_tool_lifecycle_presenter(agent),
        );
    }

    pub fn notePendingFrameCommitted(self: *App, agent: *agents.Agent) void {
        InputSubmitRuntime.noteCommittedFrame(self, agent);
    }

    pub fn acceptPresentedPrompt(self: *App, agent: *agents.Agent, turn_id: u64) !void {
        if (agent.submission.pending) |pending| {
            if (pending.draft.turn_id == turn_id) self.remoteUser(agent, pending.draft.prompt);
        }
        try InputSubmitRuntime.acceptPresentedPrompt(self, agent, turn_id);
    }

    pub fn cancelPendingSubmission(self: *App, agent: *agents.Agent) bool {
        return InputSubmitRuntime.cancelPendingSubmission(self, agent);
    }

    pub fn clearPendingSubmission(self: *App, agent: *agents.Agent, reason: []const u8) void {
        InputSubmitRuntime.clearPendingSubmission(self, agent, reason);
    }

    pub fn clearPendingSubmissionForSessionTransition(self: *App, agent: *agents.Agent) void {
        InputSubmitRuntime.clearPendingSubmissionForSessionTransition(self, agent);
    }

    pub fn writeUserPromptCard(self: *App, agent: *agents.Agent, user: types.UserTurn) !void {
        try self.endSplash();
        try self.writeUserPromptCardWithSpacing(user, agent.session.historyLen() > 0);
    }

    pub fn writeUserPromptCardWithSkillBindings(
        self: *App,
        agent: *agents.Agent,
        user: types.UserTurn,
        skill_bindings: []const worker_runtime.SkillBinding,
        skill_display_spans: []const worker_runtime.SkillDisplaySpan,
    ) !void {
        _ = skill_bindings;
        const skill_tokens = try promptCardSkillTokensFromDisplaySpans(self.alloc, skill_display_spans);
        defer if (skill_tokens.len > 0) self.alloc.free(skill_tokens);
        try self.writeUserPromptCardWithSpacingAndSkillTokens(user, agent.session.historyLen() > 0, skill_tokens);
    }

    pub fn writeUserPromptCardWithSpacing(self: *App, user: types.UserTurn, has_prior_turns: bool) !void {
        try self.endSplash();
        try self.writeUserPromptCardWithSpacingAndSkillTokens(user, has_prior_turns, &.{});
    }

    fn writeUserPromptCardWithSpacingAndSkillTokens(
        self: *App,
        user: types.UserTurn,
        has_prior_turns: bool,
        skill_tokens: []const registered_entities.SkillTokenSpan,
    ) !void {
        // A turn a subagent's report or message started is not the user's
        // words, so it shows as a finished subagent call, as the parent's
        // own calls do.
        if (try subagent_reports.row(self.alloc, user)) |shown| {
            defer shown.deinit(self.alloc);
            const entry_id = try self.writeCompletedToolStatusReturningEntryId(shown.outcome, shown.status, true);
            try self.shell.attachSubagentReportDetail(self.alloc, entry_id, subagent_reports.Row.call, shown.result(io_mod.milliTimestamp()));
            return;
        }
        _ = try self.shell.writeUserPromptCard(
            self.alloc,
            &self.metrics,
            user,
            has_prior_turns,
            skill_tokens,
        );
    }

    pub fn stopStream(self: *App, agent: *agents.Agent) void {
        agent.stream = .{};
        self.shell.resetCommandOutputDisplay(self.alloc, "stream stopped");
        self.shell.render_requests.request(.footer);
    }

    pub fn clearSession(self: *App, agent: *agents.Agent) !void {
        try SessionAppRuntime.clearSession(self, agent);
    }

    pub fn newSession(self: *App, agent: *agents.Agent) !void {
        try SessionAppRuntime.newSession(self, agent);
    }

    pub fn resetSession(self: *App, agent: *agents.Agent) !void {
        try SessionAppRuntime.resetSession(self, agent);
    }

    pub fn prepareLiveSessionResume(self: *App, agent: *agents.Agent) !void {
        try SessionAppRuntime.prepareLiveSessionResume(self, agent);
    }

    pub fn finishLiveSessionResume(self: *App) !void {
        try SessionAppRuntime.finishLiveSessionResume(self);
    }

    pub fn startResumedSessionWarmup(self: *App) void {
        SessionAppRuntime.startResumedSessionWarmup(self);
    }

    /// Sends the request a resumed session left unfinished, once the worker
    /// runs.
    pub fn startPendingResume(self: *App, agent: *agents.Agent) void {
        SessionAppRuntime.startPendingResume(self, agent);
    }

    /// Queues the turn that resumes a request a previous spark process left
    /// unfinished. `note` is what the model reads; the transcript shows a
    /// resume line instead of a user card.
    pub fn queueResumedRequest(self: *App, agent: *agents.Agent, note: []const u8, resumed: types.RecoveryResume) !bool {
        var queued = try self.snapshotPrompt(agent, note, &.{}, null, null, 0, false);
        errdefer releaseUnadmittedPrompt(agent, queued);
        queued.recovery_resume = resumed;
        try agent.worker.enqueuePrompt(std.heap.c_allocator, queued);
        WorkerAppRuntime.syncState(
            self,
            agent,
            app_callbacks.Bindings(App).worker_tool_lifecycle_presenter(agent),
        );
        return true;
    }

    pub fn resumeSelectedSession(self: *App, agent: *agents.Agent) !bool {
        // The startup picker resumes a whole host; an in-app
        // `/resume` brings back only the session chosen.
        const startup_pick = self.instances.restore_on_pick and agent == &self.main_agent and
            SessionAppRuntime.activeSessionId(agent) == null;
        if (agent == &self.main_agent) self.instances.restore_on_pick = false;
        const resumed = try SessionAppRuntime.resumeSelectedSession(self, agent);
        if (resumed and startup_pick) InstancesAppRuntime.restoreGroup(self);
        return resumed;
    }

    pub fn submitForkMenu(self: *App, agent: *agents.Agent, bring: ?bool) !?[]u8 {
        return SessionAppRuntime.submitForkMenu(self, agent, bring);
    }

    pub fn loadMoreSessionPicker(self: *App, agent: *agents.Agent) !bool {
        return SessionAppRuntime.loadMoreSessionPicker(self, agent);
    }

    pub fn beginResumeProjection(self: *App, agent: *agents.Agent) !ResumeProjection {
        return ResumeProjection.init(
            self.alloc,
            &self.shell,
            io_mod.milliTimestamp(),
            agent.next_diff_id,
        );
    }

    pub fn installResumeProjection(
        self: *App,
        agent: *agents.Agent,
        projection: *ResumeProjection,
        holds_previous_cycle: bool,
    ) !void {
        return self.installResumeProjectionInto(agent, projection, &self.shell, holds_previous_cycle);
    }

    /// `installResumeProjection` into `target`: the agent in context takes
    /// the projection's diffs, and `target` its transcript.
    /// `holds_previous_cycle` when the replayed turns are the cycle before
    /// the newest compaction.
    pub fn installResumeProjectionInto(
        self: *App,
        agent: *agents.Agent,
        projection: *ResumeProjection,
        target: *TranscriptRuntime,
        holds_previous_cycle: bool,
    ) !void {
        const c_alloc = std.heap.c_allocator;
        try agent.diff_entries.ensureUnusedCapacity(
            c_alloc,
            projection.pending_diffs.items.len,
        );
        for (projection.pending_diffs.items) |entry| {
            agent.diff_entries.appendAssumeCapacity(entry);
        }
        projection.pending_diffs.clearRetainingCapacity();
        agent.next_diff_id = projection.next_diff_id;
        projection.install(target);
        try target.transcriptWindowResumed(self.alloc, holds_previous_cycle);
    }

    pub fn historicalToolActivityKind(
        self: *App,
        agent: *agents.Agent,
        call: types.ToolCall,
    ) types.ToolActivityKind {
        return tool_dispatch.toolActivityKindForCall(self.alloc, self.toolRegistry(agent), call);
    }

    pub fn commitStartupResumeReplayAnchor(self: *App) !void {
        try self.flushRequestedFrame();
    }

    pub fn flushDirectTerminalShutdownOutcome(self: *App) !void {
        try RenderAppRuntime.flushRequestedFrame(@as(*Self, self), self.screenAgent());
    }

    fn snapshotAndQueuePrompt(
        self: *App,
        agent: *agents.Agent,
        prompt: []const u8,
        skill_tokens: []const registered_entities.SkillTokenSpan,
        recovery_checkpoint: ?*const session_codec.RecoveryCheckpoint,
        prompt_images: ?[]const types.ImageAttachment,
        turn_id: u64,
        user_prompt_already_presented: bool,
    ) !bool {
        const queued = try self.snapshotPrompt(
            agent,
            prompt,
            skill_tokens,
            recovery_checkpoint,
            prompt_images,
            turn_id,
            user_prompt_already_presented,
        );
        errdefer releaseUnadmittedPrompt(agent, queued);
        try agent.worker.enqueuePrompt(std.heap.c_allocator, queued);
        return true;
    }

    /// Frees a prompt the worker refused, giving back the stale shell handles
    /// note it took so the next prompt carries it.
    fn releaseUnadmittedPrompt(agent: *agents.Agent, queued: worker_runtime.QueuedPrompt) void {
        if (queued.stale_shell_handles) agent.session.returnStaleShellHandles(queued.turn_id);
        worker_runtime.freeQueuedPrompt(std.heap.c_allocator, queued);
    }

    // Caller owns the returned prompt until worker admission succeeds.
    fn snapshotPrompt(
        self: *App,
        agent: *agents.Agent,
        prompt: []const u8,
        skill_tokens: []const registered_entities.SkillTokenSpan,
        recovery_checkpoint: ?*const session_codec.RecoveryCheckpoint,
        prompt_images: ?[]const types.ImageAttachment,
        turn_id: u64,
        user_prompt_already_presented: bool,
    ) !worker_runtime.QueuedPrompt {
        // A subagent's turn runs under its run's admission: its model,
        // provider, permissions, and credential, never main's. One that runs
        // on main's credential has its first task titled as main's first
        // prompt is; one with a credential of its own keeps the title its
        // task gives it. An instance's turn uses its own model and provider:
        // the app's selection for the first, a launched one's own session
        // choice.
        const child_run = agent.child_run;
        const titled_like_main = if (child_run) |current| current.credential == null else true;
        if (recovery_checkpoint == null and titled_like_main) {
            SessionAppRuntime.maybeStartSessionTitleGeneration(self, agent, prompt);
        }
        const source_images = if (recovery_checkpoint) |checkpoint|
            checkpoint.user.images
        else if (prompt_images) |images|
            images
        else
            agent.pending_images.items;

        const prompt_copy = try std.heap.c_allocator.dupe(u8, prompt);
        errdefer std.heap.c_allocator.free(prompt_copy);

        const model_copy = try std.heap.c_allocator.dupe(u8, if (child_run) |active_run|
            active_run.admission.model
        else
            provider_runtime.modelOf(self, agent));
        errdefer std.heap.c_allocator.free(model_copy);

        const prompt_credential: auth_runtime.PromptCredential = if (child_run) |active_run| routed: {
            const credential = active_run.credential orelse break :routed self.auth.promptCredential() orelse return error.MissingApiKey;
            break :routed .{ .api_key = credential.token, .source = credential.source };
        } else self.auth.promptCredential() orelse return error.MissingApiKey;
        const api_key_copy = if (prompt_credential.api_key) |api_key|
            try std.heap.c_allocator.dupe(u8, api_key)
        else
            @constCast(&[_]u8{});
        errdefer secret.zeroAndFree(std.heap.c_allocator, api_key_copy);

        const authorized_image_catalog = if (recovery_checkpoint) |checkpoint| blk: {
            const history_catalog = try agent.session.snapshotImageCatalog(std.heap.c_allocator, &.{});
            defer types.freeImageAttachmentSlice(std.heap.c_allocator, history_catalog);
            break :blk try session_runtime.merge_image_catalog_history_turn(
                std.heap.c_allocator,
                history_catalog,
                checkpoint.interruptedTurn(),
            );
        } else try agent.session.snapshotImageCatalog(std.heap.c_allocator, source_images);
        errdefer types.freeImageAttachmentSlice(std.heap.c_allocator, authorized_image_catalog);

        const history_copy = try agent.session.snapshotHistory(std.heap.c_allocator);
        errdefer types.freeHistoryTurnSlice(std.heap.c_allocator, history_copy);
        const root_user_intent_context = if (child_run) |active_run|
            try std.heap.c_allocator.dupe(u8, active_run.root_user_intent_context)
        else
            try std.heap.c_allocator.dupe(u8, "");
        errdefer std.heap.c_allocator.free(root_user_intent_context);

        const images_copy = try types.dupeImageAttachmentSlice(
            std.heap.c_allocator,
            source_images,
        );
        errdefer types.freeImageAttachmentSlice(std.heap.c_allocator, images_copy);

        var recovery_checkpoint_copy = if (recovery_checkpoint) |checkpoint|
            try checkpoint.dupe(std.heap.c_allocator)
        else
            null;
        errdefer if (recovery_checkpoint_copy) |*checkpoint|
            checkpoint.deinit(std.heap.c_allocator);

        var context_snapshot_copy = if (self.context_enabled)
            try agent.context_snapshot.dupe(std.heap.c_allocator)
        else
            context_contract.GatheredContextSnapshot{};
        errdefer context_snapshot_copy.deinit(std.heap.c_allocator);

        const skill_bindings = try dupeUniqueSkillBindingsFromTokens(std.heap.c_allocator, skill_tokens);
        errdefer worker_runtime.freeSkillBindings(std.heap.c_allocator, skill_bindings);

        const skill_display_spans = try dupeSkillDisplaySpansFromTokens(std.heap.c_allocator, skill_tokens);
        errdefer worker_runtime.freeSkillDisplaySpans(std.heap.c_allocator, skill_display_spans);

        const work_id_copy: ?[]u8 = if (agent.prompt_work_id) |id| try std.heap.c_allocator.dupe(u8, id) else null;
        errdefer if (work_id_copy) |id| std.heap.c_allocator.free(id);

        return .{
            .turn_id = if (recovery_checkpoint) |checkpoint| checkpoint.turn_id else turn_id,
            .work_id = work_id_copy,
            .prompt = prompt_copy,
            .images = images_copy,
            .authorized_image_catalog = authorized_image_catalog,
            .model = model_copy,
            .provider = if (child_run) |active_run| active_run.admission.provider else provider_runtime.providerOf(self, agent),
            .api_key = api_key_copy,
            .credential_source = prompt_credential.source,
            .permission_mode = if (child_run) |active_run| active_run.admission.permission_mode else .yolo,
            .history = history_copy,
            .unversioned_history_count = agent.session.unversionedHistoryEnd(),
            .root_user_intent_context = root_user_intent_context,
            .skill_bindings = skill_bindings,
            .skill_display_spans = skill_display_spans,
            .context_snapshot = context_snapshot_copy,
            .recovery_checkpoint = recovery_checkpoint_copy,
            .recovery_source_already_presented = recovery_checkpoint != null,
            .user_prompt_already_presented = user_prompt_already_presented,
            .stale_shell_handles = agent.session.takeStaleShellHandles(),
        };
    }

    pub fn request_context_compaction(self: *App, agent: *agents.Agent) !void {
        try InputSubmitRuntime.request_context_compaction(self, agent);
    }

    pub fn enqueueContextCompaction(self: *App, agent: *agents.Agent, operation_id: @import("core/output/compaction_activity.zig").OperationId) !bool {
        if (agent.worker.isProcessing() or agent.worker.queuedPromptCount() > 0) return false;
        const model = try std.heap.c_allocator.dupe(u8, provider_runtime.modelOf(self, agent));
        errdefer std.heap.c_allocator.free(model);
        const credential = self.auth.promptCredential() orelse return error.MissingApiKey;
        const api_key = if (credential.api_key) |value|
            try std.heap.c_allocator.dupe(u8, value)
        else
            @constCast(&[_]u8{});
        errdefer secret.zeroAndFree(std.heap.c_allocator, api_key);
        const history = try agent.session.snapshotHistory(std.heap.c_allocator);
        errdefer types.freeHistoryTurnSlice(std.heap.c_allocator, history);

        try agent.worker.enqueueContextCompaction(.{
            .operation_id = operation_id,
            .model = model,
            .provider = provider_runtime.providerOf(self, agent),
            .api_key = api_key,
            .credential_source = credential.source,
            .history = history,
            .unversioned_history_count = agent.session.unversionedHistoryEnd(),
        });
        return true;
    }

    pub fn hasContextToCompact(_: *const App, agent: *const agents.Agent) bool {
        return agent.session.hasContextToCompact();
    }

    pub fn loadMcpHost(self: *App, agent: *agents.Agent, load: mcp_host.LoadFn) !void {
        try self.mcp.loadHost(load, self.alloc, io_mod.homeDir(), self.workspace_root, self.toolRegistry(agent), .{ .form = true, .url = true });
    }

    /// Before a `/mcp` command runs: what changed outside this session is
    /// loaded first, so `/mcp login NAME` finds a server `spark mcp add` added
    /// in a shell.
    pub fn runMcpVerbs(self: *App, rest: []const u8) !void {
        _ = self.refreshMcpHostFromFiles(self.screenAgent());
        try self.mcp.runVerbs(io_mod.homeDir() orelse "", self.workspace_root, rest);
    }

    pub fn takeMcpHostNotices(self: *App) []app_mcp_runtime.State.HostNotice {
        return self.mcp.takeHostNotices();
    }

    pub fn refreshMcpCompletion(self: *App) void {
        self.mcp.refreshCompletion();
    }

    pub fn openMcpHostMenu(self: *App) void {
        _ = self.refreshMcpHostFromFiles(self.screenAgent());
        self.mcp.openHostMenu();
    }

    /// The composer's text is the menu's filter.
    pub fn mcpHostMenuKey(self: *App, key: mcp_host.menu.Key) !void {
        const was = self.mcp.host_menu.screen;
        try self.mcp.hostMenuKey(key, self.input_runtime.edit_state.input.items, io_mod.homeDir() orelse "", self.workspace_root);
        try self.mcp.swapHostMenuFilter(was, self.alloc, &self.input_runtime.edit_state);
        self.shell.render_requests.request(.footer);
    }

    pub fn mcpHostStatuses(self: *App, alloc: Allocator) Allocator.Error!?[]mcp_host.Status {
        return self.mcp.hostStatuses(alloc);
    }

    pub fn mcpHostStatusesNow(self: *App, alloc: Allocator) Allocator.Error!?[]mcp_host.Status {
        return self.mcp.hostStatusesNow(alloc);
    }

    pub fn refreshMcpHostStatus(self: *App) void {
        if (self.mcp.refreshHostStatus(io_mod.milliTimestamp())) RenderAppRuntime.requestActiveSurfaceFrame(self, .footer);
    }

    pub fn startMcpHostServers(self: *App) void {
        self.mcp.startHostServers();
    }

    pub fn refreshMcpHostMenu(self: *App) void {
        const was = self.mcp.host_menu.screen;
        const changed = self.mcp.refreshHostMenu(self.input_runtime.edit_state.input.items);
        self.mcp.swapHostMenuFilter(was, self.alloc, &self.input_runtime.edit_state) catch |err|
            debug_trace.logf("mcp", "MCP menu kept the tool filter in the composer err={s}", .{@errorName(err)});
        if (changed) self.shell.render_requests.request(.footer);
    }

    pub fn applyMcpHostReload(self: *App, agent: *agents.Agent) void {
        _ = self.mcp.refreshHost(self.alloc, io_mod.homeDir(), self.workspace_root, self.toolRegistry(agent), .requested);
        self.mcp.signInAfterAdd();
    }

    fn refreshMcpHostFromFiles(self: *App, agent: *agents.Agent) bool {
        return self.mcp.refreshHost(self.alloc, io_mod.homeDir(), self.workspace_root, self.toolRegistry(agent), .files);
    }

    /// Before `agent`'s prompt: loads the MCP config again when it changed
    /// outside this session, such as through `spark mcp add` in a shell or
    /// another spark. Every agent uses the same servers, so a running or queued
    /// turn of any of them keeps the servers it has; the next prompt after
    /// it picks the change up. True when it loaded.
    pub fn refreshMcpHostForPrompt(self: *App, agent: *agents.Agent) bool {
        if (AgentsAppRuntime.anyWorkGoing(self)) return false;
        return self.refreshMcpHostFromFiles(agent);
    }

    pub fn mcpServerNames(self: *App, alloc: Allocator) ![]const []const u8 {
        return self.mcp.serverNames(alloc);
    }

    fn effectiveToolSet(self: *const App, agent: *const agents.Agent) tool_set_contract.ToolSet {
        _ = self;
        return agent.profile_tools orelse builtin_tools.advertisement_set;
    }

    pub fn toolRegistry(self: *const App, agent: *const agents.Agent) tool_dispatch.Registry {
        return self.effectiveToolSet(agent).registry;
    }

    pub fn toolAdvertisementSet(self: *const App, agent: *const agents.Agent) tool_set_contract.ToolSet {
        return self.effectiveToolSet(agent);
    }

    /// spark's tools before any agent profile narrows them: what a profile that
    /// sets tools chooses from.
    pub fn baseToolSet(_: *const App) tool_set_contract.ToolSet {
        return builtin_tools.advertisement_set;
    }

    pub fn hasMcpTool(self: *App, name: []const u8, access: tool_mcp_runtime.Access) bool {
        return self.mcp.hasTool(name, access);
    }

    pub fn validateMcpTool(
        self: *App,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        access: tool_mcp_runtime.Access,
    ) !tool_mcp_runtime.ValidationResult {
        return self.mcp.validateTool(arena, name, arguments_json, access);
    }

    pub fn callMcpTool(
        self: *App,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        max_tool_result_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
    ) !?tool_mcp_runtime.CallResult {
        return self.mcp.callTool(arena, name, arguments_json, max_tool_result_bytes, options);
    }

    pub fn searchMcpTools(self: *App, arena: Allocator, request: tool_mcp_runtime.SearchRequest, access: tool_mcp_runtime.Access, cancel_flag: ?*std.atomic.Value(bool)) !tool_mcp_runtime.SearchResult {
        return self.mcp.searchTools(arena, request, self.context_limits, access, cancel_flag);
    }

    pub fn mcpToolSchemaJson(self: *App, arena: Allocator, name: []const u8, access: tool_mcp_runtime.Access, cancel_flag: ?*std.atomic.Value(bool)) !?tool_mcp_runtime.ToolSchemaResult {
        return self.mcp.toolSchema(arena, name, self.context_limits, access, cancel_flag);
    }

    pub fn addMcpSlack(self: *App) !void {
        return app_commands.Handlers(App).addSlack(self);
    }

    pub fn snapshotMcpDefinition(self: *App, alloc: Allocator, name: []const u8, known: tool_mcp_runtime.Binding, _: types.PermissionMode) !tool_mcp_runtime.DefinitionSnapshot {
        return self.mcp.snapshotToolDefinition(alloc, name, known, self.context_limits, .unrestricted);
    }

    pub fn snapshotMcpToolNames(self: *App, alloc: Allocator) ![][]u8 {
        return self.mcp.snapshotToolNames(alloc);
    }

    pub fn snapshotMcpAccessView(
        self: *App,
        alloc: Allocator,
        owner_id: []const u8,
        parent_id: []const u8,
    ) !?mcp_access_policy.View {
        return self.mcp.snapshotAccessView(alloc, owner_id, parent_id);
    }

    pub fn snapshotModelToolProjection(
        self: *App,
        agent: *agents.Agent,
        alloc: Allocator,
        permission_mode: types.PermissionMode,
    ) !tool_projection.EffectiveToolProjection {
        self.authority_mutex.lockUncancelable(io_mod.getIo());
        defer self.authority_mutex.unlock(io_mod.getIo());
        return self.snapshotModelToolProjectionForRules(
            agent,
            alloc,
            permission_mode,
        );
    }

    pub fn snapshotSubagentModelToolProjection(
        self: *App,
        agent: *agents.Agent,
        alloc: Allocator,
        permission_mode: types.PermissionMode,
    ) !tool_projection.EffectiveToolProjection {
        return self.snapshotModelToolProjectionForRules(
            agent,
            alloc,
            permission_mode,
        );
    }

    fn snapshotModelToolProjectionForRules(
        self: *App,
        agent: *agents.Agent,
        alloc: Allocator,
        permission_mode: types.PermissionMode,
    ) !tool_projection.EffectiveToolProjection {
        const subagent_available = agent.session_persistence.subagent_host != null;
        // Listed fresh for each turn, so a profile saved during the session shows.
        var profile_arena = std.heap.ArenaAllocator.init(alloc);
        defer profile_arena.deinit();
        const subagent_profiles: []const profiles.Entry = if (subagent_available) listed: {
            const workspace_root = io_mod.realpathAlloc(profile_arena.allocator(), ".") catch null;
            const roots = try profiles.Roots.init(profile_arena.allocator(), io_mod.homeDir(), workspace_root);
            break :listed try profiles.list(profile_arena.allocator(), roots);
        } else &.{};
        return tool_projection.buildModelToolProjectionForSet(alloc, self.toolAdvertisementSet(agent), .{
            .permission_mode = permission_mode,
            .subagent_available = subagent_available,
            .subagent_profiles = subagent_profiles,
            .behind_toolbox = self.toolbox_behind.slice(),
        });
    }

    pub fn subagentToolContextForAdmission(
        self: *App,
        agent: *agents.Agent,
        admission: subagent_domain.AdmissionSnapshot,
    ) tool_runtime.Context {
        return AgentAppRuntime.toolContextForSubagent(self, agent, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, model_retry_count, "", admission);
    }

    pub fn bindSubagentWorker(
        raw: ?*anyopaque,
        turn: *subagent_execution.TurnContext,
        cancel: *std.atomic.Value(bool),
    ) subagent_execution.ServiceError!void {
        return AgentAppRuntime.bindSubagentWorker(raw, turn, cancel);
    }

    pub fn runSubagentChild(
        raw: ?*anyopaque,
        turn: *subagent_execution.TurnContext,
        message: subagent_domain.QueuedMessage,
        admission: subagent_domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) subagent_execution.ServiceError!subagent_execution.RunOutcome {
        return AgentAppRuntime.runSubagentChild(raw, turn, message, admission, cancel);
    }

    /// The subagent host's report sink (`subagent_tool_host.ReportSink`):
    /// queues the delivery for the main loop, which gives it to its agent.
    pub fn postSubagentReport(
        raw: ?*anyopaque,
        reporting_host: *subagent_tool_host.Runtime,
        delivery: subagent_tool_host.Delivery,
    ) subagent_tool_host.PostReportError!void {
        const self: *App = @ptrCast(@alignCast(raw.?));
        // A message needs room where it goes; a report never does.
        const from_owner = delivery == .message and delivery.message.to == .owners_parent;
        if (delivery == .message) try AgentsAppRuntime.reserveMessagePlace(self, reporting_host, from_owner);
        app_agents_runtime.postDelivery(&self.child_handoffs, reporting_host, delivery) catch |err| {
            if (delivery == .message) AgentsAppRuntime.releaseMessagePlace(self, reporting_host, from_owner);
            return err;
        };
    }

    /// The user stopped `agent`'s turn on its own screen.
    pub fn noteUserStop(self: *App, agent: *agents.Agent) void {
        AgentsAppRuntime.noteUserStop(self, agent);
    }

    /// `agent`'s worker began a turn with `author`'s prompt; a subagent's
    /// turn the parent didn't start opens its work in the parent's log.
    pub fn noteChildTurnBegun(self: *App, agent: *agents.Agent, author: types.MessageAuthor) void {
        AgentsAppRuntime.noteChildTurnBegun(self, agent, author);
    }

    /// Sends `agent` a message another agent wrote, such as its subagent's
    /// report. It joins a running turn when nothing older waits, or starts
    /// the agent's next turn, and never interrupts the model. That turn
    /// trusts the user's last request as root context, never the message,
    /// and takes none of the images waiting in the composer.
    /// `mail` names what it is; a `.message` uses the place
    /// `reserveMessagePlace` held for it.
    pub fn postAgentMessage(self: *App, agent: *agents.Agent, text: []const u8, author: types.MessageAuthor, mail: agent_frame.MailKind) !void {
        std.debug.assert(author != .user);
        // Until the worker takes it, a message still holds its place.
        var place_held = mail == .message;
        defer if (place_held) agent.worker.releaseAgentMessage();
        var prompt = try self.snapshotPrompt(agent, text, &.{}, null, &.{}, debug_trace.nextTurnId(), false);
        var owned = true;
        defer if (owned) worker_runtime.freeQueuedPrompt(std.heap.c_allocator, prompt);
        prompt.author = author;
        prompt.mail = mail;
        if (mail == .message) {
            place_held = false;
            try agent.worker.postReservedMail(std.heap.c_allocator, prompt);
        } else {
            try agent.worker.postMail(std.heap.c_allocator, prompt);
        }
        owned = false;
        WorkerAppRuntime.syncState(self, agent, app_callbacks.Bindings(App).worker_tool_lifecycle_presenter(agent));
    }

    pub fn requestSkillsRefresh(self: *App) !u64 {
        const home = try app_runtime_setup.resolveSkillsHome(std.heap.c_allocator);
        defer if (home) |value| std.heap.c_allocator.free(value);
        return self.skills.requestRefresh(
            std.heap.c_allocator,
            self.workspace_root,
            home,
            builtin_skills.root_policy,
        );
    }

    pub fn collectPendingSkillRefresh(
        self: *App,
        pending: *input_submit_runtime.PendingSubmission,
    ) !input_submit_runtime.PendingSkillRefresh {
        const generation = pending.skill_refresh_generation orelse blk: {
            const requested = try self.requestSkillsRefresh();
            pending.skill_refresh_generation = requested;
            break :blk requested;
        };
        return switch (self.skills.generationStatus(generation)) {
            .pending => .pending,
            .current => .current,
            .failed => error.SkillCatalogRefreshFailed,
        };
    }

    fn pollSkillsRefresh(self: *App) !skill_runtime.RefreshCompletion {
        const completion = try self.skills.pollRefresh(
            std.heap.c_allocator,
            self.workspace_root,
            builtin_skills.root_policy,
        );
        if (completion == .adopted) {
            skill_runtime.traceDiagnostics(
                "interactive_refresh",
                self.skills.diagnostics,
            );
        }
        return completion;
    }

    pub fn providerSet(self: *const App) provider_set.Set {
        if (self.provider_selection.model_requests_blocked) return .{};
        var providers = builtin_providers.native;
        providers.definitions = self.provider_selection.definitions.definitions;
        return providers;
    }

    pub fn describeToolAction(self: *App, agent: *agents.Agent, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return AgentAppRuntime.describeToolAction(self, agent, arena, call, display_target, advertised_dynamic_tool_names, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, model_retry_count, "");
    }

    pub fn resolveToolActionDisplayTarget(self: *App, agent: *agents.Agent, arena: Allocator, call: ToolCall) !?[]const u8 {
        return AgentAppRuntime.resolveToolActionDisplayTarget(self, agent, arena, call, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, model_retry_count, "");
    }

    pub fn describeToolActionWithAdvertised(self: *App, agent: *agents.Agent, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return self.describeToolAction(agent, arena, call, display_target, advertised_dynamic_tool_names);
    }

    pub fn describeToolActionCompleted(self: *App, agent: *agents.Agent, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return AgentAppRuntime.describeToolActionCompleted(self, agent, arena, call, display_target, advertised_dynamic_tool_names, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, model_retry_count, "");
    }

    pub fn describeToolActionCompletedWithAdvertised(self: *App, agent: *agents.Agent, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return self.describeToolActionCompleted(agent, arena, call, display_target, advertised_dynamic_tool_names);
    }

    pub fn describeToolActionDenied(self: *App, agent: *agents.Agent, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return AgentAppRuntime.describeToolActionDenied(self, agent, arena, call, display_target, label, advertised_dynamic_tool_names, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, model_retry_count, "");
    }

    pub fn describeToolActionDeniedWithAdvertised(self: *App, agent: *agents.Agent, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return self.describeToolActionDenied(agent, arena, call, display_target, label, advertised_dynamic_tool_names);
    }

    pub fn requestToolPermissionSyncWithAdvertised(self: *App, agent: *agents.Agent, arena: Allocator, call: ToolCall, live_authority: ?agent_runtime.LiveToolAuthority, revalidation: ?command_admission.ToolExecutionAuthority, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
        return AgentAppRuntime.requestToolPermissionSync(self, agent, arena, call, live_authority, revalidation, advertised_dynamic_tool_names, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, model_retry_count, "");
    }

    pub fn requestPreparedFileMutationPermissionSyncWithAdvertised(self: *App, agent: *agents.Agent, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, live_authority: ?agent_runtime.LiveToolAuthority, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
        return AgentAppRuntime.requestPreparedFileMutationPermissionSync(self, agent, arena, call, prepared, live_authority, advertised_dynamic_tool_names, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, model_retry_count, "");
    }

    pub fn validateToolCall(self: *App, agent: *agents.Agent, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
        return AgentAppRuntime.validateToolCall(self, agent, arena, call, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, model_retry_count, "");
    }

    pub fn resolveUnselectedMcpTool(self: *App, agent: *agents.Agent, arena: Allocator, name: []const u8) !?tool_mcp_runtime.SelectedTool {
        return AgentAppRuntime.resolveUnselectedMcpTool(self, agent, arena, name, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, model_retry_count, "");
    }

    pub fn checkToolAvailability(self: *App, agent: *agents.Agent, arena: Allocator, call: ToolCall) !?[]const u8 {
        return AgentAppRuntime.checkToolAvailability(self, agent, arena, call, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, model_retry_count, "");
    }

    pub fn permissionTargetForCall(self: *App, agent: *agents.Agent, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return AgentAppRuntime.permissionTargetForCall(self, agent, arena, call, advertised_dynamic_tool_names, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, model_retry_count, "");
    }

    pub fn permissionTargetForCallWithAdvertised(self: *App, agent: *agents.Agent, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return self.permissionTargetForCall(agent, arena, call, advertised_dynamic_tool_names);
    }

    pub fn fetchModelIds(self: *App) !std.ArrayList([]u8) {
        return AgentAppRuntime.fetchModelIds(
            self,
            self.providerSet().select(provider_runtime.provider(self)).model_catalog orelse return error.ModelCatalogUnavailable,
            self.model_cache.models_path,
        );
    }

    pub fn startModelCacheWarmup(self: *App) void {
        self.loadModelCatalog(.activity);
    }

    /// Opening the model picker revalidates the catalog in the background;
    /// the picker lists the cached models until the refresh lands.
    pub fn revalidateModelCache(self: *App) void {
        self.loadModelCatalog(.picker_open);
    }

    fn loadModelCatalog(self: *App, trigger: model_cache_runtime.LoadTrigger) void {
        const provider = self.providerSet().select(provider_runtime.provider(self)).model_catalog orelse return;
        self.model_cache.startWarmup(provider, self.auth.modelCatalogAccess(), trigger);
    }

    pub fn ensureModelCache(self: *App) void {
        self.startModelCacheWarmup();
    }

    pub fn isModelCacheLoading(self: *App) bool {
        return self.model_cache.isLoading();
    }

    pub fn isModelCacheFailed(self: *App) bool {
        return self.model_cache.isFailed();
    }

    pub fn modelCacheFailure(self: *App) ?model_catalog.FailureCategory {
        return self.model_cache.downFailure();
    }

    pub fn snapshotCachedModelIds(self: *App, alloc: Allocator) !?std.ArrayList([]u8) {
        return self.model_cache.snapshotCachedModelIds(alloc);
    }

    /// The capabilities of `model` under the screen's provider, for main-loop
    /// screen code.
    pub fn resolvedModelCapabilities(self: *App, model: []const u8) model_capabilities.Capabilities {
        return self.resolvedModelCapabilitiesOf(self.screenAgent(), model);
    }

    /// The capabilities of `model` under `agent`'s provider.
    pub fn resolvedModelCapabilitiesOf(self: *App, agent: *agents.Agent, model: []const u8) model_capabilities.Capabilities {
        const provider = provider_runtime.providerOf(self, agent);
        const bundle = self.providerSet().select(provider);
        var capabilities = model_capabilities.mergeCapabilities(
            bundle.fallbackModelCapabilities(model),
            self.model_cache.metadataForModel(model),
        );
        // A connection's settings change at runtime through /provider, so its
        // declared levels and window come from the current definitions, not
        // the catalog fetched at startup.
        if (provider == .configured) if (self.provider_selection.definitions.get(provider.label())) |definition| {
            if (definition.auth.plan() != null) return capabilities; // its live catalog takes precedence over the sign-in snapshot
            if (definition.metadata_for(model)) |metadata| {
                capabilities.reasoning_efforts = .{};
                for (metadata.reasoning_efforts orelse &.{}) |level| {
                    const effort = types.ReasoningEffort.parse(level.name) orelse continue;
                    if (capabilities.reasoning_efforts.len >= capabilities.reasoning_efforts.values.len) break;
                    capabilities.reasoning_efforts.values[capabilities.reasoning_efforts.len] = effort;
                    capabilities.reasoning_efforts.len += 1;
                }
                capabilities.supports_reasoning = capabilities.reasoning_efforts.len > 0;
                if (metadata.context_window) |window| capabilities.context_window = window;
            }
        };
        return capabilities;
    }

    pub fn resolveModelCapabilitiesForRequest(self: *App, agent: *agents.Agent, model: []const u8) model_capabilities.ResolveError!model_capabilities.Capabilities {
        _ = try self.model_cache.resolveForRequest(model, &agent.worker.worker_cancel_requested);
        return self.resolvedModelCapabilitiesOf(agent, model);
    }

    /// Must be called after init() returns so the loader thread captures
    /// a pointer to the final App location (not a temporary). Same hazard
    /// as `startAutoUpgrade` above.
    pub fn startFileIndex(self: *App) void {
        WorkspaceAppRuntime.startFileIndex(self);
    }

    pub fn fileCompletions(
        self: *App,
        query: []const u8,
        out: []file_index_mod.SearchResult,
        match_spans: []file_index_mod.MatchSpan,
        path_storage: []u8,
    ) app_workspace_runtime.FileCompletionError!usize {
        return WorkspaceAppRuntime.fileCompletions(self, query, out, match_spans, path_storage);
    }

    pub fn fileCompletionsAtRevision(
        self: *App,
        revision: file_index_mod.ReadableRevision,
        query: []const u8,
        out: []file_index_mod.SearchResult,
        match_spans: []file_index_mod.MatchSpan,
        path_storage: []u8,
    ) app_workspace_runtime.FileCompletionError!usize {
        return WorkspaceAppRuntime.fileCompletionsAtRevision(self, revision, query, out, match_spans, path_storage);
    }

    pub fn reconcileDirectoryCompletion(self: *App, eligible: bool) void {
        WorkspaceAppRuntime.reconcileDirectoryCompletion(self, eligible);
    }

    pub fn prepareDirectoryCompletion(self: *App) void {
        WorkspaceAppRuntime.prepareDirectoryCompletion(self);
    }

    pub fn harvestDirectoryCompletion(self: *App, eligible: bool) void {
        WorkspaceAppRuntime.harvestDirectoryCompletion(self, eligible);
    }

    pub fn fileCompletionRevision(self: *const App) file_index_mod.ReadableRevision {
        return WorkspaceAppRuntime.fileCompletionRevision(self);
    }

    pub fn fileCompletionScopeEpoch(self: *const App) u64 {
        return WorkspaceAppRuntime.fileCompletionScopeEpoch(self);
    }

    pub fn fileCompletionsDependOnIndex(self: *const App, query: []const u8) bool {
        return WorkspaceAppRuntime.fileCompletionsDependOnIndex(self, query);
    }

    pub fn isFileIndexLoading(self: *App) bool {
        return self.file_index.currentState() == .loading;
    }

    pub fn isFileIndexFailed(self: *App) bool {
        return self.file_index.currentState() == .failed;
    }

    pub fn refreshFileIndex(self: *App) void {
        WorkspaceAppRuntime.refreshFileIndex(self);
    }

    pub fn workspaceAccess(self: *App) *app_workspace_runtime.Access {
        return WorkspaceAppRuntime.access(self);
    }

    pub fn workspaceAccessScope(self: *const App) app_workspace_runtime.AccessScope {
        return WorkspaceAppRuntime.scope(self);
    }

    pub fn adoptWorkspaceAccess(self: *App, access: app_workspace_runtime.Access) void {
        WorkspaceAppRuntime.adopt(self, access);
    }

    pub fn installWorkspaceAccess(self: *App, access: *app_workspace_runtime.Access) bool {
        return WorkspaceAppRuntime.install(self, access);
    }

    pub fn refreshWorkspaceAccess(self: *App) app_workspace_runtime.Error!bool {
        return WorkspaceAppRuntime.refreshAvailability(self);
    }

    pub fn isCurrentFileCompletion(
        self: *App,
        query: []const u8,
        path: []const u8,
        kind: file_index_mod.CandidateKind,
    ) bool {
        return WorkspaceAppRuntime.isCurrentFileCompletion(self, query, path, kind);
    }

    pub fn modelCompletions(self: *App, query: []const u8, out: [][]const u8) usize {
        self.ensureModelCache();
        return self.model_cache.modelCompletions(query, out);
    }

    pub fn catalogModelCompletion(self: *App, model: []const u8) ?[]const u8 {
        self.ensureModelCache();
        return self.model_cache.catalogModelCompletion(model);
    }

    pub fn pushText(_: *App, agent: *agents.Agent, text: []const u8) !void {
        try agent.worker.pushEvent(std.heap.c_allocator, .{ .assistant_presentation = .{
            .text = @constCast(text),
        } });
    }

    pub fn processQueuedWork(self: *App, agent: *agents.Agent, work: WorkItem, failure_provenance: *?@import("core/output/compaction_activity.zig").ErrorProvenance) !void {
        const result = switch (work) {
            .prompt => |job| AgentAppRuntime.processQueuedPrompt(
                self,
                agent,
                job,
                model_retry_count,
                "",
                failure_provenance,
            ),
            .compact_context => |task| AgentAppRuntime.processContextCompaction(
                self,
                agent,
                task,
                model_retry_count,
                failure_provenance,
            ),
        };
        result catch |err| {
            if (err == error.TurnFinalizationDeliveryFailed) return;
            return err;
        };
    }

    pub fn executeToolCall(self: *App, agent: *agents.Agent, request: agent_runtime.ToolExecutionRequest) !ToolExecutionResult {
        return AgentAppRuntime.executeToolCall(self, agent, request, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, model_retry_count, "");
    }

    pub fn executeToolCallWithAdvertised(self: *App, agent: *agents.Agent, request: agent_runtime.ToolExecutionRequest) !ToolExecutionResult {
        return self.executeToolCall(agent, request);
    }

    pub fn releaseAgentTerminalLease(self: *App, agent: *agents.Agent, session_id: []const u8) !void {
        return AgentAppRuntime.releaseAgentTerminalLease(
            self,
            agent,
            session_id,
            &ignored_list_entries,
            max_list_entries,
            max_read_file_bytes,
            max_read_file_lines,
            max_read_file_line_len,
            max_command_output_bytes,
            model_retry_count,
            "",
        );
    }

    pub fn stopSteeringDetachedCommands(self: *App, agent: *agents.Agent, turn_id: u64) !void {
        return AgentAppRuntime.stopSteeringDetachedCommands(
            self,
            agent,
            turn_id,
            &ignored_list_entries,
            max_list_entries,
            max_read_file_bytes,
            max_read_file_lines,
            max_read_file_line_len,
            max_command_output_bytes,
            model_retry_count,
            "",
        );
    }

    pub fn formatToolExecutionErrorForAgent(self: *App, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
        _ = self;
        return app_process_runtime.Runtime(App).formatToolExecutionError(arena, tool_name, err);
    }

    pub fn appendRuntimeContextMessage(self: *App, agent: *agents.Agent, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
        try AgentAppRuntime.appendTransientRuntimeContextMessage(self, agent, arena, messages, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, model_retry_count, "");
    }

    pub fn appendStaticContextMessage(self: *App, agent: *agents.Agent, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
        try AgentAppRuntime.appendStaticContextMessage(self, agent, arena, messages, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, model_retry_count, "");
    }

    pub fn writeTranscript(self: *App, text: []const u8, record: bool) !void {
        try self.endSplash();
        try self.shell.writeTranscript(self.alloc, &self.metrics, text, record);
    }

    pub fn writeTranscriptClassified(self: *App, text: []const u8, record: bool, class: transcript_runtime.RawEntryClass) !void {
        try self.endSplash();
        try self.shell.writeTranscriptClassified(self.alloc, &self.metrics, text, record, class);
    }

    fn liveSource(self: *App, agent: *agents.Agent) ?live_preview_mod.Source {
        if (!agent.stream.active) return null;
        return live_preview_mod.pickSource(agent.reasoning.items, self.show_reasoning, agent.live_text.items, agent.live_generation);
    }

    /// Applies `show_reasoning` to the transcript and reprints it, so the
    /// thinking blocks already written expand or collapse too.
    pub fn redrawForThinkingToggle(self: *App) !void {
        ui_render.expand_thinking = self.show_reasoning;
        self.shell.setCommandOutputRenderPolicy(RenderAppRuntime.shellStyles());
        // A mutation may not land while the transcript hands rows to the
        // terminal's scrollback; the next paint then picks up the styles.
        self.shell.rerenderEntries(self.alloc, "thinking toggle") catch |err| {
            debug_trace.logf("render", "thinking_toggle_rerender_failed err={s}", .{@errorName(err)});
        };
        try self.shell.requestTerminalReset(&self.metrics);
        self.shell.render_requests.request(.transcript);
        self.shell.render_requests.request(.footer);
    }

    pub fn livePreview(self: *App, agent: *agents.Agent) ?live_preview_mod.Preview {
        const preview = self.live_pacer.preview(self.liveSource(agent), self.shell.layout.cols) orelse return null;
        // The transcript puts a gap above the thinking block when it writes
        // it; the preview leaves the same one.
        if (preview.kind == .reasoning) {
            var shown = preview.withGapAbove(@min(1, self.shell.transientAssistantGapRows()));
            const now_ms = io_mod.milliTimestamp();
            if (agent.reasoning_started_ms > 0 and now_ms > agent.reasoning_started_ms)
                shown.thinking_ms = @intCast(now_ms - agent.reasoning_started_ms);
            return shown;
        }
        return preview;
    }

    /// Ends the launch splash: writes the version line it held back to the
    /// transcript, first, so it stays above everything after it.
    pub fn endSplash(self: *App) !void {
        if (!self.splash.active and !self.splash.welcome_pending) return;
        self.splash.dismiss();
        if (!self.splash.welcome_pending) return;
        self.splash.welcome_pending = false;
        const welcome = try ui_render.welcomeMessage(self.alloc);
        defer self.alloc.free(welcome);
        try self.shell.writeTranscriptClassified(self.alloc, &self.metrics, welcome, true, .welcome);
        RenderAppRuntime.requestActiveSurfaceFrame(self, .footer);
    }

    pub fn writeCompletedToolStatus(
        self: *App,
        kind: types.ToolOutcomeKind,
        text: []const u8,
        record: bool,
    ) !void {
        try self.shell.writeCompletedToolStatus(self.alloc, &self.metrics, kind, text, record);
    }

    pub fn writeCompletedToolStatusReturningEntryId(
        self: *App,
        kind: types.ToolOutcomeKind,
        text: []const u8,
        record: bool,
    ) !u32 {
        return self.shell.writeCompletedToolStatusReturningEntryId(
            self.alloc,
            &self.metrics,
            kind,
            text,
            record,
        );
    }

    pub fn attachHistoricalToolDetail(
        self: *App,
        agent: *agents.Agent,
        entry_id: u32,
        call: types.ToolCall,
        result: types.PersistedToolResult,
    ) !void {
        const activity_kind = tool_dispatch.toolActivityKindForCall(self.alloc, self.toolRegistry(agent), call);
        try self.shell.attachHistoricalToolDetail(self.alloc, entry_id, call, activity_kind, result);
    }

    pub fn attachHistoricalToolDetailWithLifecycle(
        self: *App,
        agent: *agents.Agent,
        entry_id: u32,
        call: types.ToolCall,
        result: types.PersistedToolResult,
        lifecycle_id: types.ToolLifecycleId,
    ) !void {
        const activity_kind = tool_dispatch.toolActivityKindForCall(self.alloc, self.toolRegistry(agent), call);
        try self.shell.attachHistoricalToolDetailWithLifecycle(
            self.alloc,
            entry_id,
            call,
            activity_kind,
            result,
            lifecycle_id,
        );
    }

    pub fn attachHistoricalToolDetailAfterCommandOutput(
        self: *App,
        agent: *agents.Agent,
        entry_id: u32,
        call: types.ToolCall,
        result: types.PersistedToolResult,
    ) !void {
        const activity_kind = tool_dispatch.toolActivityKindForCall(self.alloc, self.toolRegistry(agent), call);
        try self.shell.attachHistoricalToolDetailAfterCommandOutput(
            self.alloc,
            entry_id,
            call,
            activity_kind,
            result,
        );
    }

    pub fn writeHistoricalQuestionResolution(
        self: *App,
        answers: []const types.QuestionAnswer,
    ) !u32 {
        const text = try question_ui.composeResolvedQuestionAnswers(
            self.alloc,
            answers,
            self.shell.layout.cols,
        );
        defer self.alloc.free(text);
        return self.appendReplaceableTranscriptLine(text);
    }

    pub fn prepareHistoricalQuestionResolution(
        self: *App,
        answers: []const types.QuestionAnswer,
    ) ![]u8 {
        return question_ui.composeResolvedQuestionAnswers(
            self.alloc,
            answers,
            self.shell.layout.cols,
        );
    }

    pub fn attachHistoricalToolCallWithoutResult(
        self: *App,
        entry_id: u32,
        call: types.ToolCall,
    ) !void {
        try self.shell.attachHistoricalToolCallWithoutResult(self.alloc, entry_id, call);
    }

    pub fn attachHistoricalBridgeCall(
        self: *App,
        entry_id: u32,
        tool: []const u8,
        outcome: types.ToolOutcomeKind,
    ) !void {
        try self.shell.attachHistoricalBridgeCall(self.alloc, entry_id, tool, outcome);
    }

    pub fn attachHistoricalCommandOutput(self: *App, entry_id: u32) void {
        self.shell.attachHistoricalCommandOutput(self.alloc, entry_id);
    }

    pub fn attachHistoricalCancelledCommandDetail(
        self: *App,
        entry_id: u32,
        call: types.ToolCall,
        command_artifact_handle: ?[]const u8,
        replayed_output: bool,
    ) !void {
        try self.shell.attachHistoricalCancelledCommandDetail(
            self.alloc,
            entry_id,
            call,
            command_artifact_handle,
            replayed_output,
        );
    }

    pub fn appendReplaceableTranscriptLine(self: *App, text: []const u8) !u32 {
        return self.shell.appendReplaceableTranscriptLine(self.alloc, &self.metrics, text);
    }

    pub fn appendReplaceableTranscriptLineClassified(self: *App, text: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        return self.shell.appendReplaceableTranscriptLineClassified(self.alloc, &self.metrics, text, class);
    }

    pub fn appendReplaceableTranscriptLineSilent(self: *App, text: []const u8) !u32 {
        return self.shell.appendReplaceableTranscriptLineSilent(self.alloc, text);
    }

    pub fn appendReplaceableTranscriptLineSilentClassified(self: *App, text: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        return self.shell.appendReplaceableTranscriptLineSilentClassified(self.alloc, text, class);
    }

    pub fn replaceTrailingTranscriptLine(self: *App, text: []const u8) !bool {
        return self.shell.replaceTrailingTranscriptLine(self.alloc, &self.metrics, text);
    }

    pub fn replaceTrailingTranscriptLineSilent(self: *App, text: []const u8) !bool {
        return self.shell.replaceTrailingTranscriptLineSilent(self.alloc, text);
    }

    pub fn writeDomainNotice(self: *App, notice: types.SemanticNotice, record: bool) !void {
        // A notice only the full transcript shows leaves the splash up.
        if (notice.visibility != .full_only) try self.endSplash();
        try self.shell.writeNotice(self.alloc, &self.metrics, notice, record);
    }

    pub fn appendDomainNotice(self: *App, notice: types.SemanticNotice) !u32 {
        return self.shell.appendSemanticNotice(self.alloc, notice);
    }

    pub fn appendReplaceableDomainNotice(self: *App, notice: types.SemanticNotice) !u32 {
        return self.shell.appendReplaceableSemanticNotice(self.alloc, notice);
    }

    pub fn replaceDomainNotice(self: *App, entry_id: u32, notice: types.SemanticNotice) !bool {
        return self.shell.replaceSemanticNotice(self.alloc, entry_id, notice);
    }

    pub fn writeCommandOutputChunk(self: *App, stream: command_output_content.Stream, text: []const u8, record: bool) !void {
        try self.shell.writeCommandOutputChunk(self.alloc, &self.metrics, RenderAppRuntime.shellStyles(), stream, text, record);
    }

    pub fn writeCommandOutputChunkForLifecycle(
        self: *App,
        lifecycle_id: ?types.ToolLifecycleId,
        stream: command_output_content.Stream,
        text: []const u8,
        record: bool,
    ) !void {
        try self.shell.writeCommandOutputChunkForLifecycle(
            self.alloc,
            &self.metrics,
            RenderAppRuntime.shellStyles(),
            lifecycle_id,
            stream,
            text,
            record,
        );
    }

    pub fn flushCommandOutputSummary(self: *App, record: bool) !void {
        try self.shell.flushCommandOutputSummary(self.alloc, &self.metrics, RenderAppRuntime.shellStyles(), record);
    }

    pub fn flushCommandOutputSummaryForLifecycle(self: *App, lifecycle_id: ?types.ToolLifecycleId, record: bool) !void {
        try self.shell.flushCommandOutputSummaryForLifecycle(
            self.alloc,
            &self.metrics,
            RenderAppRuntime.shellStyles(),
            lifecycle_id,
            record,
        );
    }

    pub fn preparePersistedFileDiff(
        self: *App,
        presentation: types.CommittedFilePresentation,
    ) !agent_runtime.DiffEntryPayload {
        _ = self;
        const diff_mod = @import("core/output/diff.zig");
        return diff_mod.formatPersistedFileChangePayload(
            std.heap.c_allocator,
            presentation,
            persistedDiffStyles(),
        );
    }

    /// Reads the active theme, so it is evaluated at each use.
    fn persistedDiffStyles() @import("core/output/diff.zig").FormatStyles {
        return .{
            .added_fg = ui_render.diff_added_style,
            .removed_fg = ui_render.diff_removed_style,
            .context_fg = ui_render.dim_style,
            .added_marker_fg = ui_render.diff_added_marker_style,
            .removed_marker_fg = ui_render.diff_removed_marker_style,
            .reset = ui_render.reset_style,
        };
    }

    pub fn registerAndEmitDiffBlock(self: *App, agent: *agents.Agent, payload: agent_runtime.DiffEntryPayload) !void {
        const diff_mod = @import("core/output/diff.zig");
        const c_alloc = std.heap.c_allocator;

        const id = agent.next_diff_id;
        var appended = false;
        errdefer if (!appended) diff_mod.freeDiffEntryPayload(c_alloc, payload);

        try agent.diff_entries.append(c_alloc, .{
            .id = id,
            .full = payload.full,
            .deferred = payload.deferred,
        });
        appended = true;
        agent.next_diff_id += 1;

        defer c_alloc.free(payload.preview);
        const wrapped = try diff_mod.wrapWithMarkers(c_alloc, id, payload.preview);
        defer c_alloc.free(wrapped);
        try self.writeTranscriptClassified(wrapped, true, .diff_block);
    }

    pub fn fullTranscriptDiffResolver(self: *App) @import("ui/full_transcript_screen.zig").FullDiffResolver {
        return .{
            .context = self,
            .full_for_marker = fullDiffForMarker,
            .has_full_for_lifecycle = hasFullDiffForLifecycle,
        };
    }

    fn fullDiffForMarker(ctx: *anyopaque, id: u32) ?[]const u8 {
        const self: *App = @ptrCast(@alignCast(ctx));
        for (self.screenAgent().diff_entries.items) |*entry| {
            if (entry.id != id) continue;
            SessionAppRuntime.materializeDeferredDiff(self, self.screenAgent(), entry, persistedDiffStyles());
            const full = entry.full orelse return null;
            return full.content;
        }
        return null;
    }

    /// Builds a matching deferred resumed edit first, so the answer stays
    /// exact when its saved snapshots are missing.
    fn hasFullDiffForLifecycle(
        ctx: *anyopaque,
        lifecycle_id: types.ToolLifecycleId,
    ) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        for (self.screenAgent().diff_entries.items) |*entry| {
            if (entry.deferred) |deferred| {
                if (!deferred.matches(lifecycle_id)) continue;
                SessionAppRuntime.materializeDeferredDiff(self, self.screenAgent(), entry, persistedDiffStyles());
            }
            const full = entry.full orelse continue;
            if (full.lifecycle_id.turn_id != lifecycle_id.turn_id) continue;
            if (std.mem.eql(u8, full.lifecycle_id.call_id, lifecycle_id.call_id)) return true;
        }
        return false;
    }

    pub fn fullTranscriptSidecarCapability(_: *App, agent: *agents.Agent) ?*session_child_store.SessionChildCapability {
        return SessionAppRuntime.childCapability(agent);
    }

    pub fn pacerEmit(ctx: *anyopaque, text: []const u8) anyerror!void {
        const self: *App = @ptrCast(@alignCast(ctx));
        _ = try self.shell.streamAssistantChunk(self.alloc, &self.metrics, text);
    }

    pub fn appendAssistantTable(self: *App, table: assistant_presentation.TablePayload) !void {
        _ = try self.shell.appendAssistantTableOwned(self.alloc, table);
    }

    pub fn appendAssistantCodeBlock(self: *App, block: assistant_presentation.CodeBlockPayload) !void {
        _ = try self.shell.appendAssistantCodeBlockOwned(self.alloc, block);
    }

    pub fn appendAssistantThematicRule(self: *App) !void {
        _ = try self.shell.appendAssistantThematicRule(self.alloc);
    }

    pub fn appendHistoryTurn(self: *App, agent: *agents.Agent, turn: types.HistoryTurn) !void {
        try SessionAppRuntime.appendHistoryTurn(self, agent, turn);
    }

    pub fn persistRuntimePreferences(
        self: *App,
        agent: *agents.Agent,
        patch: app_session_runtime.SessionPreferencePatch,
    ) app_session_runtime.PreferenceCommitResult {
        return SessionAppRuntime.commitRuntimePreferences(self, agent, patch);
    }

    pub fn fastModeModelBound(self: *const App, agent: *const agents.Agent) bool {
        return SessionAppRuntime.fastModeModelBound(self, agent);
    }

    pub fn finishPromptPresentation(self: *App, agent: *agents.Agent, finished: types.FinishedPrompt) !assistant_pacer.FinishResult {
        return app_callbacks.Bindings(App).finishPromptPresentation(self, agent, finished);
    }

    pub fn pacerFinish(ctx: *anyopaque, finished: types.FinishedPrompt) anyerror!assistant_pacer.FinishResult {
        const self: *App = @ptrCast(@alignCast(ctx));
        const result = try app_callbacks.Bindings(App).finishPromptPresentation(self, self.screenAgent(), finished);
        if (result == .committed) self.notificationPresentationFinished();
        return result;
    }

    /// Writes a call's Ctrl+O line that the pacer held until its text was
    /// shown.
    pub fn pacerModelCall(ctx: *anyopaque, record: types.ModelCallRecord) anyerror!void {
        try app_worker_runtime.writeModelCallNotice(ctx, App.pacerNotice, record);
    }

    fn pacerNotice(ctx: *anyopaque, notice: types.SemanticNotice) anyerror!void {
        const self: *App = @ptrCast(@alignCast(ctx));
        try self.writeDomainNotice(notice, true);
    }

    pub fn pacerCallbacks(self: *App) assistant_pacer.TickCallbacks {
        return .{
            .emit_ctx = self,
            .emit_fn = App.pacerEmit,
            .finish_ctx = self,
            .finish_fn = App.pacerFinish,
            .model_call_fn = App.pacerModelCall,
        };
    }

    fn nativeClearProbeEligible(self: *const App, agent: *const agents.Agent, byte: u8) bool {
        if (byte < 32 or byte == 127) return false;
        if (io_mod.getenv("TMUX") != null) return false;
        // An alternate-screen surface (full transcript, approval review,
        // catalog menu) owns the terminal cursor. The probe compares against
        // the main-grid footer row, so any response from the alternate screen
        // is a guaranteed false mismatch; never begin while one is active.
        if (self.terminal.alternate_screen_owner != .none) return false;
        if (self.terminal_input_runtime.native_clear_probe.disabled() or
            self.terminal_input_runtime.native_clear_probe.active() or
            self.input_runtime.paste.active() or
            self.terminal_input_runtime.hasPendingTerminalAction() or
            agent.question_prompt.isActive() or
            false or
            !self.shell.has_committed_frame or
            !self.shell.footer_viewport.has_frame or
            self.shell.footer_viewport.cursor.row == 0 or
            self.shell.layout.cols < cursor_probe.confirmation_tag_column or
            !shell_runtime.resizeLifecycleIdle(&self.shell) or
            resize_interlock.resizePending() or
            !self.terminal_input_runtime.terminal_cursor_probe.canBegin())
        {
            return false;
        }
        return true;
    }

    pub fn prepareApiKeyInputBoundary(self: *App) void {
        if (self.terminal_input_runtime.native_clear_probe.active()) {
            const discarded = self.terminal_input_runtime.native_clear_probe.settle().len;
            self.terminal_input_runtime.native_clear_probe.clearSettledInput();
            debug_trace.logf(
                "auth",
                "api key stage discarded native-clear probe input bytes={d}",
                .{discarded},
            );
        }

        self.terminal_input_runtime.terminal_cursor_probe.cancel();
        var discarded: usize = 0;
        while (self.terminal_input_runtime.terminal_cursor_probe.takeDeferredByte()) |byte| {
            _ = byte;
            std.debug.assert(self.terminal_input_runtime.terminal_cursor_probe.consumeDeferredInputDispatch());
            discarded += 1;
        }
        if (discarded > 0) {
            debug_trace.logf(
                "auth",
                "api key stage discarded cursor-probe input bytes={d}",
                .{discarded},
            );
        }
    }

    fn replayNativeClearProbeInput(self: *App) !void {
        const retained = self.terminal_input_runtime.native_clear_probe.settle();
        defer self.terminal_input_runtime.native_clear_probe.clearSettledInput();
        for (retained) |retained_byte| {
            try self.handleTerminalInputByte(retained_byte);
            if (self.should_exit) return;
        }
    }

    fn handleTerminalInputByte(self: *App, byte: u8) !void {
        try InputAppRuntime.handleTerminalByteAcrossSessionTransition(
            self,
            byte,
            input_limits,
            max_prompt_history,
        );
    }

    fn routeTerminalInputIngress(
        self: *App,
        initial_ingress: input_action.TerminalInputIngress,
    ) !void {
        var ingress = initial_ingress;
        while (true) {
            const replay_byte = try InputAppRuntime.handleTerminalInputIngressWithLimits(
                self,
                ingress,
                input_limits,
                max_prompt_history,
            );
            const replay = replay_byte orelse return;
            const context = try InputAppRuntime.prepareTerminalDecode(self, self.screenAgent()) orelse return;
            ingress = self.terminal_input_runtime.decodeTerminalByte(replay, context);
        }
    }

    fn finishNativeClearProbe(self: *App, reset_visual_epoch: bool) !void {
        if (reset_visual_epoch) {
            _ = try RenderAppRuntime.resetVisualEpoch(self, .native_clear_probe);
        }
        try self.replayNativeClearProbeInput();
    }

    fn retainDeferredNativeClearProbeInput(self: *App) !bool {
        while (self.terminal_input_runtime.terminal_cursor_probe.takeDeferredByte()) |deferred| {
            if (!self.terminal_input_runtime.native_clear_probe.canRetainBytes(1)) {
                std.debug.assert(self.terminal_input_runtime.terminal_cursor_probe.consumeDeferredInputDispatch());
                try self.finishNativeClearProbe(false);
                try self.handleTerminalInputByte(deferred);
                while (self.terminal_input_runtime.terminal_cursor_probe.takeDeferredByte()) |remaining| {
                    std.debug.assert(self.terminal_input_runtime.terminal_cursor_probe.consumeDeferredInputDispatch());
                    try self.handleTerminalInputByte(remaining);
                    if (self.should_exit) break;
                }
                return false;
            }
            try self.terminal_input_runtime.native_clear_probe.retainBytes(self.alloc, &.{deferred});
            std.debug.assert(self.terminal_input_runtime.terminal_cursor_probe.consumeDeferredInputDispatch());
        }
        return true;
    }

    fn beginNativeClearProbe(self: *App, byte: u8) !bool {
        if (!self.nativeClearProbeEligible(self.screenAgent(), byte)) return false;

        const expected_row = self.shell.footer_viewport.cursor.row;
        try self.terminal_input_runtime.native_clear_probe.begin(self.alloc, expected_row, byte);
        self.terminal_input_runtime.terminal_cursor_probe.begin(
            .ansi_tagged,
            io_mod.milliTimestamp() + cursor_probe.response_idle_timeout_ms,
        ) catch {
            try self.replayNativeClearProbeInput();
            return true;
        };
        self.terminal.requestResizeCursorPosition(.ansi_tagged) catch |err| {
            self.terminal_input_runtime.terminal_cursor_probe.cancel();
            self.terminal_input_runtime.native_clear_probe.disable(false);
            debug_trace.logf("native_clear", "native_clear_probe_write_failed err={s}", .{@errorName(err)});
            try self.replayNativeClearProbeInput();
            return true;
        };
        debug_trace.logf(
            "native_clear",
            "native_clear_probe requested expected_row={d}",
            .{expected_row},
        );
        return true;
    }

    fn handleNativeClearProbeInput(self: *App, byte: u8) !void {
        self.terminal_input_runtime.terminal_cursor_probe.noteInputActivity(io_mod.milliTimestamp());
        switch (self.terminal_input_runtime.terminal_cursor_probe.feed(byte)) {
            .pending => {},
            .position => |position| {
                const expected_row = self.terminal_input_runtime.native_clear_probe.expectedRow();
                const reset_visual_epoch = position.row != expected_row;
                debug_trace.logf(
                    "native_clear",
                    "native_clear_probe {s} expected_row={d} observed_row={d}",
                    .{ if (reset_visual_epoch) "mismatch" else "match", expected_row, position.row },
                );
                try self.finishNativeClearProbe(reset_visual_epoch);
            },
            .late_response => {
                debug_trace.logf("native_clear", "native_clear_probe_late_response_discarded", .{});
            },
            .forward => |forwarded| {
                if (self.terminal_input_runtime.native_clear_probe.canRetainBytes(forwarded.slice().len)) {
                    try self.terminal_input_runtime.native_clear_probe.retainBytes(self.alloc, forwarded.slice());
                    return;
                }

                _ = self.terminal_input_runtime.terminal_cursor_probe.expire(io_mod.milliTimestamp());
                self.terminal_input_runtime.native_clear_probe.disable(true);
                debug_trace.logf("native_clear", "native_clear_probe_overflow", .{});
                if (try self.retainDeferredNativeClearProbeInput()) {
                    try self.finishNativeClearProbe(false);
                }
                for (forwarded.slice()) |forwarded_byte| {
                    try self.handleTerminalInputByte(forwarded_byte);
                    if (self.should_exit) return;
                }
            },
        }
    }

    fn collectNativeClearProbeFacts(self: *App) !void {
        switch (self.terminal_input_runtime.terminal_cursor_probe.poll(io_mod.milliTimestamp())) {
            .none => {},
            .probe_timed_out => {
                self.terminal_input_runtime.native_clear_probe.disable(true);
                debug_trace.logf("native_clear", "native_clear_probe_timeout", .{});
                if (!try self.retainDeferredNativeClearProbeInput()) {
                    debug_trace.logf("native_clear", "native_clear_probe_overflow", .{});
                    return;
                }
                try self.finishNativeClearProbe(false);
            },
            .late_window_expired => {
                self.terminal_input_runtime.native_clear_probe.finishLateResponse();
                debug_trace.logf("native_clear", "native_clear_probe_late_window_expired", .{});
            },
        }
    }

    fn collectThemeFacts(self: *App) !void {
        const now_ms = io_mod.milliTimestamp();
        self.terminal_input_runtime.terminal_theme_monitor.poll(now_ms);

        // A configured light|dark pin (SPARK_THEME or the settings "theme" key)
        // locks the variant; keep owning protocol bytes (monitor started) but
        // never query or apply live theme updates. Custom theme files stay
        // live: updates re-resolve the theme pair.
        if (ui_render.themeInputLocked()) {
            _ = self.terminal_input_runtime.terminal_theme_monitor.takeSettledUpdate();
            return;
        }

        if (self.terminal_input_runtime.terminal_theme_monitor.takeSettledUpdate()) |update| {
            debug_trace.logf("theme", "theme_update_settled light={s} rgb={s}", .{
                if (update.light) "true" else "false",
                if (update.rgb == null) "fallback" else "terminal",
            });
            try RenderAppRuntime.applyThemeUpdate(self, update.light, update.rgb);
        }
        if (InputAppRuntime.terminalPasteActive(self) or
            self.terminal_input_runtime.native_clear_probe.active() or
            self.terminal_input_runtime.native_clear_probe.awaitingLateResponse())
        {
            return;
        }
        if (self.terminal_input_runtime.terminal_theme_monitor.takeQueryRequest(now_ms)) |request| {
            debug_trace.logf("theme", "theme_query_requested kind={s}", .{@tagName(request)});
            const query_result = switch (request) {
                .response_fence => self.terminal.requestThemeResponseFence(),
                .background => self.terminal.requestThemeBackground(),
            };
            query_result catch |err| {
                self.terminal_input_runtime.terminal_theme_monitor.failQuery(now_ms);
                debug_trace.logf("theme", "theme_query_failed kind={s} err={s}", .{
                    @tagName(request),
                    @errorName(err),
                });
            };
        }
        if (self.terminal_input_runtime.terminal_theme_monitor.takeRearmRequest(now_ms)) {
            debug_trace.logf("theme", "theme_notifications_rearmed", .{});
            self.terminal.enableThemeNotifications() catch |err| {
                debug_trace.logf("theme", "theme_notification_enable_failed err={s}", .{@errorName(err)});
            };
            self.terminal.requestThemeColorScheme() catch |err| {
                debug_trace.logf("theme", "theme_color_scheme_query_failed err={s}", .{@errorName(err)});
            };
        }
    }

    fn collectBracketedPasteFacts(self: *App) void {
        if (!self.terminal_input_runtime.bracketed_paste_rearm.take(io_mod.milliTimestamp())) return;
        self.terminal.enableBracketedPaste() catch |err| {
            debug_trace.logf("input", "bracketed_paste_rearm_failed err={s}", .{@errorName(err)});
        };
    }

    pub fn remoteUser(self: *App, agent: *agents.Agent, text: []const u8) void {
        if (agent != &self.main_agent) return;
        const v2 = agent.session_persistence.v2 orelse return;
        if (!std.mem.eql(u8, v2.id(), self.remote.session) and !self.remote.poll(self.alloc, v2.id(), io_mod.milliTimestamp())) return;
        self.remote.user(self.alloc, v2.terminalTurnPosition().current, text) catch {};
    }

    fn pollRemote(self: *App) void {
        const agent = &self.main_agent;
        const now = io_mod.milliTimestamp();
        if (!self.remote.poll(self.alloc, SessionAppRuntime.activeSessionId(agent), now)) return;
        const v2 = agent.session_persistence.v2 orelse return;
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        if (self.remote.read(scratch.allocator(), now)) |request| {
            const result = self.applyRemote(agent, request);
            self.remote.ack(request.ticket, result);
        }
        const active = agent.stream.active or agent.worker.isProcessing() or agent.worker.queuedPromptCount() > 0;
        self.remote.publish(now, v2.terminalTurnPosition().committed, active);
    }

    fn applyRemote(self: *App, agent: *agents.Agent, request: terminal_remote.Request) ?[]const u8 {
        switch (request.op) {
            .prompt => {
                const text = std.mem.trim(u8, request.text, " \t\r\n");
                if (text.len == 0 or text.len > 16 * 1024) return "Send a message between 1 byte and 16 KB.";
                if (self.screenAgent() != agent) return "Switch to the main chat in the Mac terminal first.";
                if (agent.worker.queuedPromptCount() >= 8) return "Too many messages are queued.";
                const accepted = self.admitInteractiveText(agent, text, &.{}, &.{}) catch return "spark couldn't accept the message on the Mac.";
                if (!accepted) return "spark couldn't accept the message on the Mac.";
            },
            .cancel => {
                if (self.screenAgent() != agent) return "Switch to the main chat in the Mac terminal first.";
                @import("core/app/input_interrupt_runtime.zig").InterruptRuntime(App).cancelActiveOperation(self, agent) catch return "spark couldn't stop the turn on the Mac.";
            },
        }
        return null;
    }

    pub fn loopCollectFacts(ctx: *anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (!try WorkerAppRuntime.authorizeInteractiveAdmission(self, self.screenAgent())) return;

        if (self.file_index.joinThreadIfDone(std.heap.c_allocator)) {
            self.shell.render_requests.request(.footer);
        }
        switch (try self.pollSkillsRefresh()) {
            .none, .unchanged => {},
            .adopted, .failed => self.shell.render_requests.request(.footer),
        }
        try app_commands.Handlers(App).collectSkillsRefreshFacts(self, self.screenAgent());
        SessionAppRuntime.collectInterruptedTurnHint(self);
        InputSubmitRuntime.collectPendingSubmissionFacts(self, self.screenAgent());
        try InputSubmitRuntime.collectLaunchPromptFacts(self, max_prompt_history);
        InputAppRuntime.collectFilePickerFacts(self, self.screenAgent());

        try self.collectThemeFacts();
        self.collectBracketedPasteFacts();

        UpgradeAppRuntime.collectUpgradeFacts(self);
        InstancesAppRuntime.syncRecord(self);

        if (try self.model_cache.pollLoadTransition()) {
            RenderAppRuntime.requestActiveSurfaceFrame(self, .footer);
        }
        if (try app_commands.Handlers(App).collectInfoPanelFacts(self)) {
            RenderAppRuntime.requestActiveSurfaceFrame(self, .footer);
        }
        try app_commands.Handlers(App).collectMcpHostFacts(self, self.screenAgent());
        try app_provider_menu_runtime.Runtime(App).collectPlan(self, self.screenAgent());
        if (self.launch_completion.refresh(self.alloc, self.input_runtime.edit_state.input.items, io_mod.homeDir(), self.workspace_root, self.instances.seed.launchDefaults())) {
            RenderAppRuntime.requestActiveSurfaceFrame(self, .footer);
        }
        if (self.prompt_completion.refresh(self.alloc, self.input_runtime.edit_state.input.items, io_mod.homeDir(), self.screenAgent().custom_prompt.name)) {
            RenderAppRuntime.requestActiveSurfaceFrame(self, .footer);
        }
        if (self.live_pacer.tick(self.liveSource(self.screenAgent()), io_mod.milliTimestamp())) {
            RenderAppRuntime.requestActiveSurfaceFrame(self, .footer);
        }
        if (self.splash.active) {
            // The splash leaves for good at the first keystroke or turn.
            if (self.input_runtime.edit_state.input.items.len > 0 or self.screenAgent().stream.active or self.input_runtime.list_picker.active) {
                try self.endSplash();
            } else if (self.splash.tick(io_mod.milliTimestamp())) {
                RenderAppRuntime.requestActiveSurfaceFrame(self, .footer);
            }
        }
        try app_commands.Handlers(App).collectShellSnapshotFacts(self);

        const cols_before_resize = self.shell.layout.cols;
        if (self.terminal_input_runtime.native_clear_probe.active() or
            self.terminal_input_runtime.native_clear_probe.awaitingLateResponse())
        {
            try self.collectNativeClearProbeFacts();
        } else {
            shell_runtime.collectResizeFacts(
                self.terminal,
                &self.shell,
                &self.metrics,
                &self.terminal_input_runtime.terminal_cursor_probe,
                &resize_interlock,
                footer_rows,
                resize_debounce_ms,
                !InputAppRuntime.terminalPasteActive(self),
            ) catch |err| {
                if (err != error.TerminalTooSmall and err != error.UnableToReadTerminalSize) {
                    return err;
                }
            };
        }
        // Terminal width changed with the modal open, so the footer
        // panel needs to re-wrap labels and descriptions.
        if (self.screenAgent().question_prompt.isActive() and cols_before_resize != self.shell.layout.cols) {
            self.shell.render_requests.request(.modal);
        }
        if (cols_before_resize != self.shell.layout.cols) {
            self.input_runtime.vertical_navigation.reset();
        }

        try SessionAppRuntime.pollSessionPicker(self, self.screenAgent());
        if (try AgentsAppRuntime.pollSessionTitles(self)) {
            RenderAppRuntime.requestActiveSurfaceFrame(self, .footer);
        }
        // A parent's `close` leaves its subagent's agent for the loop to drop.
        const dropped = AgentsAppRuntime.dropClosedSubagents(self) catch |err| blk: {
            debug_trace.logf("host", "closed subagents not dropped err={s}", .{@errorName(err)});
            break :blk false;
        };
        if (dropped) RenderAppRuntime.requestActiveSurfaceFrame(self, .footer);
        if (self.shell.transcript_archive_request) |back| {
            // A Ctrl+O page needs an older compaction cycle from the log,
            // which a background thread reads.
            SessionAppRuntime.loadTranscriptArchive(self, self.screenAgent(), back) catch |err| {
                debug_trace.logf("full_transcript_cache", "archive_load_failed back={d} err={s}", .{ back, @errorName(err) });
                if (err == error.TranscriptArchiveDamaged) self.shell.damageTranscriptArchive() else self.shell.failTranscriptArchive();
                RenderAppRuntime.requestActiveSurfaceFrame(self, .modal);
            };
        }
        const archive_installed = SessionAppRuntime.pollTranscriptArchive(self, self.screenAgent()) catch |err| blk: {
            debug_trace.logf("full_transcript_cache", "archive_load_failed err={s}", .{@errorName(err)});
            if (err == error.TranscriptArchiveDamaged) self.shell.damageTranscriptArchive() else self.shell.failTranscriptArchive();
            break :blk true;
        };
        if (archive_installed and self.shell.fullTranscriptActive()) {
            RenderAppRuntime.requestActiveSurfaceFrame(self, .modal);
        }
        try self.shell.prewarmFullTranscriptPage(
            self.fullTranscriptSidecarCapability(self.screenAgent()),
            self.fullTranscriptDiffResolver(),
        );
        if (try self.shell.pollFullTranscriptPageLoad()) {
            RenderAppRuntime.requestActiveSurfaceFrame(self, .modal);
        }
        if (!self.shell.fullTranscriptActive() and
            self.shell.takeReadyFullTranscriptOpen() and
            self.terminal.alternate_screen_owner == .none and
            true)
        {
            try app_lifecycle.openFullTranscript(
                self.alloc,
                &self.terminal,
                &self.shell,
                &self.metrics,
            );
            debug_trace.logf(
                "full_transcript",
                "depth_transition from=inline to=full route=root trigger=ctrl_o",
                .{},
            );
            RenderAppRuntime.requestActiveSurfaceFrame(self, .modal);
        }
        if (self.shell.takeFullTranscriptPreparationFailure()) {
            if (self.shell.fullTranscriptActive()) {
                try app_lifecycle.closeFullTranscript(
                    self.alloc,
                    &self.terminal,
                    &self.shell,
                    &self.metrics,
                );
            }
            try self.writeDomainNotice(.{
                .topic = "transcript",
                .tone = .@"error",
                .body = "Full transcript preparation failed. The reader was closed instead of showing stale content.",
            }, true);
        }
        const input_now_ms = io_mod.milliTimestamp();
        InputAppRuntime.expireTerminalInputGestures(self, self.screenAgent(), input_now_ms);
        const terminal_input = self.terminal_input_runtime.flushTerminalAction(
            input_now_ms,
            input_escape_timeout_ms,
            InputAppRuntime.terminalPasteActive(self),
        );
        try self.routeTerminalInputIngress(terminal_input);
        try tickAgentInContext({}, self, self.screenAgent());
        // Every other agent keeps working while it is hidden, each handled in
        // its own context.
        AgentsAppRuntime.takePosts(self);
        try AgentsAppRuntime.tickChildren(self, {}, tickAgentInContext);
        AgentsAppRuntime.noteFinishedTurns(self);
        AgentsAppRuntime.settleChildRuns(self);
        AgentsAppRuntime.settleLentQuestion(self);
        AgentsAppRuntime.lendPrompt(self);
        HerdrAppRuntime.reconcile(self);
        self.pollRemote();
    }

    /// Gives a subagent's question lent to main's prompt back to it, before
    /// main's own question or session change takes the prompt.
    pub fn returnLentQuestion(self: *App) void {
        _ = AgentsAppRuntime.returnQuestion(self);
    }

    /// True while main's prompt holds a subagent's question.
    pub fn questionLentToMain(self: *const App) bool {
        return self.question_lender != null;
    }

    /// Runs an answer or cancel of the question on main's screen in the
    /// context of the subagent that asked it. False for main's own question.
    pub fn answerLentQuestion(self: *App, comptime body: fn (*App, *agents.Agent) anyerror!void) !bool {
        return AgentsAppRuntime.answerLentQuestion(self, body);
    }

    /// Readies the subagent on screen, if any, for a turn the user starts
    /// there, which then runs as main's does. True when it admitted one.
    pub fn prepareSubagentOnScreen(self: *App, agent: *agents.Agent) !bool {
        return AgentsAppRuntime.prepareOwnTurn(self, agent);
    }

    /// Opens the work for the turn `prepareSubagentOnScreen` admitted, once
    /// the user's text is queued.
    pub fn openSubagentTurnWork(self: *App) void {
        AgentsAppRuntime.openOwnTurnWork(self);
    }

    /// `/launch`: another instance on the host, shown.
    pub fn launchInstance(self: *App, profile_name: ?[]const u8) !void {
        try InstancesAppRuntime.launchAndShow(self, profile_name);
    }

    /// The instances startup was asked for after the first one.
    pub fn launchStartupInstances(self: *App) void {
        InstancesAppRuntime.launchStartupInstances(self);
    }

    /// `/close`: the instance on screen and its subagents.
    pub fn closeInstanceOnScreen(self: *App) !void {
        try InstancesAppRuntime.closeOnScreen(self);
    }

    /// ↓, Ctrl+X, and `/agents`: opens the agent list in place of any other
    /// footer menu or panel.
    pub fn openAgentsMenu(self: *App) !void {
        app_commands.Handlers(App).closeFooterMenus(self);
        try AgentsAppRuntime.openMenu(self);
    }

    pub fn closeAgentsMenu(self: *App) void {
        _ = AgentsAppRuntime.closeMenu(self);
    }

    /// The instance list as the footer draws it now.
    pub fn agentsMenuProjection(self: *App) render_input.AgentsMenuProjection {
        return AgentsAppRuntime.menuProjection(self);
    }

    /// Applies profile `name` to instance `agent`.
    pub fn applyInstanceProfile(self: *App, agent: *agents.Agent, name: []const u8) !void {
        try ProfileAppRuntime.applyProfile(self, agent, name, builtin_context.prompt_policy.system_prompt, builtin_tools.advertisement_set);
        try ProfileAppRuntime.reportProfile(self, agent, "instance");
    }

    /// Puts the first instance in profile `name` after startup, as
    /// `--profile` would have: its tools, prompt, and permission mode.
    pub fn applyFirstInstanceProfile(self: *App, name: []const u8) !void {
        try ProfileAppRuntime.applyLaunchProfile(self, name, builtin_context.prompt_policy.system_prompt, builtin_tools.advertisement_set);
        try ProfileAppRuntime.applyLaunchMode(self);
    }

    /// Instance `agent`'s permission mode: its profile's own, else `parent`.
    pub fn instanceProfileMode(_: *App, agent: *agents.Agent, parent: PermissionMode) PermissionMode {
        return ProfileAppRuntime.profileMode(agent, "instance", parent);
    }

    /// The footer's agent indicator, such as "spark 2/3 ↓".
    pub fn footerAgentLabel(self: *App) []const u8 {
        return AgentsAppRuntime.footerIndicator(self);
    }

    /// True while a subagent, not an instance, is on screen.
    pub fn subagentOnScreen(self: *const App) bool {
        const on_screen = self.agent_on_screen orelse return false;
        return on_screen.agent.role == .subagent;
    }

    /// The instance a notice on a subagent's screen points back to.
    pub fn subagentHome(self: *App, name_buf: []u8) ?AgentsAppRuntime.Home {
        return AgentsAppRuntime.homeOfScreen(self, name_buf);
    }

    /// The trace name of the agent on screen: `main` or the subagent's id.
    pub fn screenAgentId(self: *const App) []const u8 {
        return if (self.agent_on_screen) |child| child.id else "main";
    }

    /// The session id of subagent `agent`, or null for an instance.
    pub fn subagentIdOf(self: *App, agent: *const agents.Agent) ?[]const u8 {
        if (agent.role != .subagent) return null;
        for (self.child_agents.items) |child| {
            if (&child.agent == agent) return child.id;
        }
        return null;
    }

    /// Notes that subagent `agent`'s approval or question just showed, so
    /// the instance's screen shows its tree's prompts oldest first.
    pub fn notePromptAsked(self: *App, agent: *const agents.Agent, kind: AgentsAppRuntime.PromptKind) void {
        AgentsAppRuntime.notePromptAsked(self, agent, kind);
    }

    pub fn subagentDisplayName(self: *App, id: []const u8) []const u8 {
        const child = AgentsAppRuntime.findChild(self, id) orelse return id;
        return child.displayName();
    }

    /// The footer note for a hidden agent waiting on the user.
    pub fn hiddenAgentWaitingNote(self: *App, buf: []u8) []const u8 {
        return AgentsAppRuntime.waitingNote(self, buf);
    }

    /// The footer note for hidden subagents working, such as
    /// "1 subagent working".
    pub fn hiddenAgentWorkingNote(self: *App, buf: []u8) []const u8 {
        return AgentsAppRuntime.workingNote(self, buf);
    }

    /// The activity row while the agent on screen waits on its subagents.
    pub fn subagentWaitStatus(self: *App) app_agents_runtime.SubagentWait {
        return AgentsAppRuntime.subagentWaitStatus(self);
    }

    /// How many subagents the agent on screen waits on while idle.
    pub fn subagentWaitCount(self: *App) usize {
        return AgentsAppRuntime.subagentWaitCount(self);
    }

    /// Handles the events and paced text of the agent in context.
    fn tickAgentInContext(_: void, self: *App, agent: *agents.Agent) anyerror!void {
        // An agent's session can start while another's transcript is on
        // screen; its transcript window starts the first time its own is.
        SessionAppRuntime.ensureTranscriptWindow(self, agent);
        const handlers = app_callbacks.Bindings(App).workerEventHandlers(agent);
        // Past the budget the drain puts the rest back, so the loop reads
        // keys and paints before applying them.
        try WorkerAppRuntime.tickWithinBudget(self, agent, handlers, app_worker_runtime.interactive_drain_budget_ns);
        const now_ns = io_mod.nanoTimestamp();
        if (!agent.question_prompt.isActive()) {
            try self.pacer.tick(self.alloc, now_ns, self.pacerCallbacks());
        } else {
            self.pacer.pause(now_ns);
            WorkerAppRuntime.flushPacerForHeldMail(self, agent, now_ns);
        }
    }

    pub fn loopCommitFrame(ctx: *anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(ctx));
        defer SessionAppRuntime.finishDeferredSessionInputReplay(self, self.screenAgent());
        if (!try WorkerAppRuntime.authorizeInteractiveAdmission(self, self.screenAgent())) return;
        if (self.terminal_input_runtime.native_clear_probe.active()) return;
        _ = self.admitPendingResizeSignal("post_input");
        InputAppRuntime.prepareFilePicker(self, self.screenAgent());
        if (self.shell.sessionScrollbackHandoffPending()) {
            try SessionAppRuntime.settlePendingLiveSessionTransition(self, self.screenAgent());
            if (self.shell.sessionScrollbackHandoffPending()) return;
        }
        _ = try InputAppRuntime.flushDeferredSessionInput(self, input_limits, max_prompt_history);
        if (self.should_exit) return;
        if (!InputAppRuntime.holdFrameForFileListing(self, self.screenAgent(), io_mod.awakeMilliTimestamp())) try self.flushRequestedFrame();
        try SessionAppRuntime.settlePendingLiveSessionTransition(self, self.screenAgent());
        if (try InputAppRuntime.flushDeferredSessionInput(self, input_limits, max_prompt_history)) try self.flushRequestedFrame();
    }

    pub fn admitPendingApprovalResize(self: *App) bool {
        return self.admitPendingResizeSignal("approval_input");
    }

    pub fn claimApprovalAffirmative(_: *App) bool {
        return resize_interlock.claimAffirmative();
    }

    pub fn releaseApprovalAffirmative(_: *App) void {
        resize_interlock.releaseAffirmative();
    }

    pub fn admitPendingResizeSignal(self: *App, source: []const u8) bool {
        return shell_runtime.admitResizeSignal(
            &self.shell,
            &resize_interlock,
            io_mod.milliTimestamp(),
            resize_debounce_ms,
            source,
        );
    }

    fn handleCursorDeferredInputByte(self: *App, byte: u8) !void {
        if (self.terminal_input_runtime.native_clear_probe.active()) {
            if (self.terminal_input_runtime.native_clear_probe.canRetainBytes(1)) {
                try self.terminal_input_runtime.native_clear_probe.retainBytes(self.alloc, &.{byte});
                return;
            }

            _ = self.terminal_input_runtime.terminal_cursor_probe.expire(io_mod.milliTimestamp());
            self.terminal_input_runtime.native_clear_probe.disable(true);
            debug_trace.logf("native_clear", "native_clear_probe_overflow", .{});
            try self.finishNativeClearProbe(false);
        }
        try self.handleTerminalInputByte(byte);
    }

    fn routeActivePasteTransportByte(self: *App, byte: u8) !bool {
        return InputAppRuntime.routeActivePasteIngressByteWithLimits(
            self,
            byte,
            input_limits,
            max_prompt_history,
        );
    }

    fn handleAfterThemeMonitorByte(self: *App, byte: u8) !void {
        if (try self.routeActivePasteTransportByte(byte)) return;
        if (!self.terminal_input_runtime.terminal_cursor_probe.interceptsInput()) {
            if (try self.beginNativeClearProbe(byte)) return;
            try self.handleTerminalInputByte(byte);
            return;
        }

        if (self.terminal_input_runtime.native_clear_probe.active()) {
            try self.handleNativeClearProbeInput(byte);
            return;
        }

        self.terminal_input_runtime.terminal_cursor_probe.noteInputActivity(io_mod.milliTimestamp());
        switch (self.terminal_input_runtime.terminal_cursor_probe.feed(byte)) {
            .pending => {},
            .position => |position| {
                shell_runtime.completeResizeCursorProbe(&self.shell, position);
            },
            .late_response => {
                if (self.terminal_input_runtime.native_clear_probe.awaitingLateResponse()) {
                    self.terminal_input_runtime.native_clear_probe.finishLateResponse();
                    debug_trace.logf("native_clear", "native_clear_probe_late_response_discarded", .{});
                } else {
                    debug_trace.logf("resize", "cursor_measure_late_response_discarded", .{});
                }
            },
            .forward => |forwarded| {
                for (forwarded.slice()) |forwarded_byte| {
                    try self.handleTerminalInputByte(forwarded_byte);
                    if (self.should_exit) return;
                }
            },
        }
    }

    fn handleThemeMonitorByte(self: *App, byte: u8) !void {
        switch (self.terminal_input_runtime.terminal_theme_monitor.feed(
            byte,
            io_mod.milliTimestamp(),
        )) {
            .pending, .consumed => {},
            .forward => |forwarded| {
                for (forwarded.slice()) |forwarded_byte| {
                    try self.handleAfterThemeMonitorByte(forwarded_byte);
                    if (self.should_exit) return;
                }
            },
        }
    }

    pub fn loopHandleByte(ctx: *anyopaque, byte: u8) !void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (!try WorkerAppRuntime.authorizeInteractiveAdmission(self, self.screenAgent())) return;
        const deferred_source = self.terminal_input_runtime.consumeDeferredTerminalInputDispatch();

        if (deferred_source) |source| {
            switch (source) {
                .cursor_probe => {
                    if (try self.routeActivePasteTransportByte(byte)) return;
                    try self.handleCursorDeferredInputByte(byte);
                },
                .theme_monitor => try self.handleAfterThemeMonitorByte(byte),
            }
            return;
        }

        switch (ui_input.terminalInputOwner(
            &self.terminal_input_runtime.terminal_theme_monitor,
            InputAppRuntime.terminalPasteActive(self),
        )) {
            .theme_monitor => {
                try self.handleThemeMonitorByte(byte);
                return;
            },
            .paste => {
                const routed = try self.routeActivePasteTransportByte(byte);
                std.debug.assert(routed);
                return;
            },
            .spark_input => {},
        }

        if (self.terminal_input_runtime.terminal_theme_monitor.enabled) {
            try self.handleThemeMonitorByte(byte);
            return;
        }
        try self.handleAfterThemeMonitorByte(byte);
    }

    pub fn loopSettleInputDeliveryEpoch(ctx: *anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(ctx));
        try self.terminal_input_runtime.markDeferredSessionDeliveryEpoch(self.alloc);
        if (!InputAppRuntime.terminalPasteActive(self)) return;
        try InputAppRuntime.settleTerminalPasteDeliveryEpochWithLimits(
            self,
            self.screenAgent(),
            input_limits,
        );
    }

    pub fn loopNextCollectedByte(ctx: *anyopaque) ?u8 {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.terminal_input_runtime.takeDeferredTerminalInputByte();
    }
};

comptime {
    if (!builtin.is_test) {
        @export(&main, .{ .name = "main" });
    }
    _ = @import("core/shared/i386_syscall_fallbacks.zig");
}

pub fn main(c_argc: c_int, c_argv: [*][*:0]c_char, c_envp: [*:null]?[*:0]c_char) callconv(.c) c_int {
    io_mod.reserveClosedStandardStreams();
    mainC(c_argc, c_argv, c_envp) catch return 1;
    return 0;
}

fn mainC(c_argc: c_int, c_argv: [*][*:0]c_char, c_envp: [*:null]?[*:0]c_char) !void {
    const raw_args = rawArgs(c_argc, c_argv);
    const raw_env: RawEnviron = @ptrCast(c_envp);
    // Before any mode runs, since terminal helpers write under spark's folder too.
    try useFxHomeFromEnv(raw_env);

    if (comptime terminal_native_session.isSupported()) {
        if (terminal_native_session.isControlModeRaw(raw_args)) {
            io_mod.setRawEnviron(raw_env);
            const process_args = argsFromRaw(raw_args);
            var threaded = std.Io.Threaded.init(processAllocator(), processIoOptions(process_args, environBlockFromRaw(raw_env)));
            defer threaded.deinit();
            io_mod.setIo(threaded.io());
            try terminal_native_session.runControlMarker(raw_args);
            return;
        }
        if (terminal_native_session.isLauncherModeRaw(raw_args)) {
            io_mod.setRawEnviron(raw_env);
            const process_args = argsFromRaw(raw_args);
            var threaded = std.Io.Threaded.init(processAllocator(), processIoOptions(process_args, environBlockFromRaw(raw_env)));
            defer threaded.deinit();
            io_mod.setIo(threaded.io());
            try terminal_native_session.runLauncher(processAllocator());
            return;
        }
    }

    if (shouldRunBenchmarkNoArgRaw(raw_args, raw_env)) {
        switch (cli_surface.parse(builtin_commands.top_level_registry, &.{})) {
            .interactive => exitFast(0),
            else => exitFast(1),
        }
    }

    var cli_arg_buf: [64][:0]const u8 = undefined;
    const cli_args = if (raw_args.len <= 1) &.{} else try cliArgsFromRaw(raw_args, &cli_arg_buf);
    if (command_runner.isForegroundSessionInvocation(cli_args)) {
        io_mod.setRawEnviron(raw_env);
        const process_args = argsFromRaw(raw_args);
        var threaded = std.Io.Threaded.init(processAllocator(), processIoOptions(process_args, environBlockFromRaw(raw_env)));
        defer threaded.deinit();
        io_mod.setIo(threaded.io());
        try command_runner.runForegroundSessionBootstrap(cli_args);
        return;
    }
    if (cli_args.len > 0 and isTopLevelHelp(cli_args)) {
        try writeTopLevelHelpFast(raw_env);
        exitFast(0);
    }
    var convo_arg_buf: [66][:0]const u8 = undefined;
    var convo_arg_len: usize = 0;
    const convo_file = convo.takeFlag(cli_args, &convo_arg_buf, &convo_arg_len) catch {
        try writeStderrFast("spark: --convo needs a file, such as spark --convo chat.spark\n");
        exitFast(2);
    };
    if (convo_file) |file| return runConvo(raw_args, raw_env, file, &convo_arg_buf, convo_arg_len);
    try runNonBenchmark(raw_args, raw_env, cli_args);
}

/// `SPARK_HOME` replaces `~/.spark` for the whole process. A bad value stops
/// spark before it reads or writes anything there.
fn useFxHomeFromEnv(raw_env: RawEnviron) !void {
    const value = rawEnvValue(raw_env, "SPARK_HOME") orelse return;
    profile_paths.useFxHome(value, rawEnvValue(raw_env, "HOME")) catch |err| {
        try writeStderrFast(switch (err) {
            error.SparkHomeNotAbsolute => "spark: SPARK_HOME must be an absolute path\n",
            error.SparkHomeIsRoot => "spark: SPARK_HOME can't be the root folder\n",
            error.SparkHomeIsHome => "spark: SPARK_HOME can't be your home folder; spark keeps its folder private\n",
        });
        exitFast(1);
    };
    if (namesNonFolderRaw(value)) {
        try writeStderrFast("spark: SPARK_HOME must name a folder, but it or a folder above it is a file\n");
        exitFast(1);
    }
    // spark creates its own folder on first use, but opens the folder that holds
    // it directly, so that one has to exist.
    if (profile_paths.fxHomeParent()) |parent| createFolderPathRaw(parent);
}

/// Whether `path` is a file, or a path through one, rather than a folder or
/// nothing yet. Asking for `path/` makes the system resolve it as a folder.
/// This runs before spark's I/O is set up, so it calls libc.
fn namesNonFolderRaw(path: []const u8) bool {
    var buffer: [std.Io.Dir.max_path_bytes + 2]u8 = undefined;
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0 or trimmed.len + 2 > buffer.len) return false;
    @memcpy(buffer[0..trimmed.len], trimmed);
    buffer[trimmed.len] = '/';
    buffer[trimmed.len + 1] = 0;
    const rc = std.c.access(@ptrCast(&buffer), std.c.F_OK);
    return rc != 0 and std.posix.errno(rc) == .NOTDIR;
}

/// Creates `path` and every folder above it that is missing. This runs before
/// spark's I/O is set up, so it calls libc; a folder that already exists, or
/// one spark can't create, is left for the first use to report.
fn createFolderPathRaw(path: []const u8) void {
    var buffer: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (path.len == 0 or path.len >= buffer.len) return;
    var end: usize = 1;
    while (end <= path.len) : (end += 1) {
        if (end != path.len and path[end] != '/') continue;
        @memcpy(buffer[0..end], path[0..end]);
        buffer[end] = 0;
        _ = std.c.mkdir(@ptrCast(&buffer), 0o755);
    }
}

fn writeTopLevelHelpFast(raw_env: RawEnviron) !void {
    const columns = topLevelHelpColumns(raw_env);
    const style = topLevelHelpStyle(raw_env);
    var buffer: [builtin_commands.top_level_help_fast_buffer_bytes]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const text = try command_specs.renderTopLevelHelpWithStyle(
        fixed.allocator(),
        builtin_commands.top_level_registry,
        columns,
        version,
        style,
    );
    try writeStdoutFast(text);
}

/// `spark --convo FILE`: unpacks FILE into a private session store, resumes
/// the session it holds or starts a new one, and writes it back as it goes.
fn runConvo(raw_args: []const [*:0]const u8, raw_env: RawEnviron, file: []const u8, args: *[66][:0]const u8, len: usize) !void {
    io_mod.setRawEnviron(raw_env);
    const alloc = processAllocator();
    var threaded = std.Io.Threaded.init(alloc, processIoOptions(argsFromRaw(raw_args), environBlockFromRaw(raw_env)));
    io_mod.setIo(threaded.io());
    const home = io_mod.homeDir() orelse {
        try writeStderrFast("spark: --convo needs a home folder\n");
        exitFast(1);
    };
    const session = convo.start(alloc, home, file) catch |err| {
        var buf: [512]u8 = undefined;
        try writeStderrFast(std.mem.print(&buf, "spark: can't open {s} as a conversation: {s}\n", .{ file, @errorName(err) }) catch "spark: can't open that conversation\n");
        exitFast(1);
    };
    var n = len;
    if (session) |id| {
        if (n + 2 > args.len) exitFast(2);
        args[n] = "--resume";
        args[n + 1] = try alloc.dupeSentinel(u8, id, 0);
        n += 2;
    }
    runConvoInner(raw_env, args[0..n]) catch |err| {
        convo.finish();
        return err;
    };
    convo.finish();
}

fn runConvoInner(raw_env: RawEnviron, cli_args: []const [:0]const u8) !void {
    const alloc = processAllocator();
    const auth_mode = credentials.parseAuthMode(rawEnvValue(raw_env, "SPARK_AUTH_MODE")) catch {
        try writeStderrFast("spark: SPARK_AUTH_MODE must be local or host-managed\n");
        return error.BadAuthMode;
    };
    const cfg = if (cli_args.len == 0) emptyEntryConfig(auth_mode) else fullEntryConfig(auth_mode);
    const before = try app_entry_runtime.runBeforeInteractive(alloc, cli_args, cfg);
    switch (before) {
        .interactive => |launch| {
            var owned_launch = launch;
            var app: App = undefined;
            const outcome = app_entry_runtime.runInteractive(App, &app, alloc, &owned_launch, auth_mode) catch return error.InteractiveFailed;
            convo.finish();
            exitFast(switch (outcome) {
                .returned => 0,
                .exit => |code| code,
            });
        },
        .returned => {},
        .exit => |code| {
            convo.finish();
            exitFast(code);
        },
    }
}

fn runNonBenchmark(raw_args: []const [*:0]const u8, raw_env: RawEnviron, cli_args: []const [:0]const u8) !void {
    io_mod.setRawEnviron(raw_env);

    const alloc = processAllocator();
    const auth_mode = credentials.parseAuthMode(rawEnvValue(raw_env, "SPARK_AUTH_MODE")) catch {
        try writeStderrFast("spark: SPARK_AUTH_MODE must be local or host-managed\n");
        exitFast(1);
    };
    const cfg = if (cli_args.len == 0)
        emptyEntryConfig(auth_mode)
    else if (needsFullEntryConfig(cli_args))
        fullEntryConfig(auth_mode)
    else
        localEntryConfig(auth_mode);

    var early_threaded: ?std.Io.Threaded = null;
    defer if (early_threaded) |*threaded| threaded.deinit();
    if (needsEarlyThreadedIo(cli_args)) {
        const env_block = environBlockFromRaw(raw_env);
        const process_args = argsFromRaw(raw_args);
        early_threaded = std.Io.Threaded.init(alloc, processIoOptions(process_args, env_block));
        if (early_threaded) |*threaded| io_mod.setIo(threaded.io());
    }

    const before = try app_entry_runtime.runBeforeInteractive(alloc, cli_args, cfg);
    switch (before) {
        .interactive => |launch| {
            const env_block = environBlockFromRaw(raw_env);
            const process_args = argsFromRaw(raw_args);
            var threaded = std.Io.Threaded.init(alloc, processIoOptions(process_args, env_block));
            io_mod.setIo(threaded.io());

            var owned_launch = launch;
            // Interactive shutdown has already persisted the session and
            // terminated child processes. What remains is freeing memory and
            // joining threads that can still be waiting on DNS, the network,
            // or a disk scan, so end the process here. The app is declared in
            // this scope because those threads still reference it.
            var app: App = undefined;
            const outcome = app_entry_runtime.runInteractive(App, &app, alloc, &owned_launch, auth_mode) catch exitFast(1);
            exitFast(switch (outcome) {
                .returned => 0,
                .exit => |code| code,
            });
        },
        .returned => exitFast(0),
        .exit => |code| exitFast(code),
    }
}

fn rawArgs(c_argc: c_int, c_argv: [*][*:0]c_char) []const [*:0]const u8 {
    const argc: usize = @intCast(c_argc);
    const argv: [*][*:0]const u8 = @ptrCast(c_argv);
    return argv[0..argc];
}

fn argsFromRaw(raw_args: []const [*:0]const u8) std.process.Args {
    return .{ .vector = raw_args };
}

/// Options for every process Io. spark starts its own tasks with `io.concurrent`,
/// and they count against the capacity that limits `io.async`. Once spark holds
/// that many tasks, std runs each `io.async` call inline, so
/// `HostName.connect` tries a host's addresses one at a time and waits on an
/// unreachable address instead of returning the reachable one.
fn processIoOptions(process_args: std.process.Args, env_block: std.process.Environ.Block) std.Io.Threaded.InitOptions {
    return .{
        .argv0 = .init(process_args),
        .environ = .{ .block = env_block },
        .async_limit = .unlimited,
    };
}

fn environBlockFromRaw(raw_env: RawEnviron) std.process.Environ.Block {
    var count: usize = 0;
    while (raw_env[count] != null) : (count += 1) {}
    return .{ .slice = raw_env[0..count :null] };
}

fn shouldRunBenchmarkNoArgRaw(raw_args: []const [*:0]const u8, raw_env: RawEnviron) bool {
    return raw_args.len <= 1 and benchmarkEnvPresent(raw_env);
}

fn benchmarkEnvPresent(raw_env: RawEnviron) bool {
    if (comptime builtin.link_libc) {
        if (std.c.getenv("SPARK_BENCH") != null) return true;
    }
    return rawEnvHas(raw_env, "SPARK_BENCH");
}

fn rawEnvHas(raw_env: RawEnviron, comptime key: []const u8) bool {
    return rawEnvValue(raw_env, key) != null;
}

fn rawEnvValue(raw_env: RawEnviron, comptime key: []const u8) ?[]const u8 {
    @setRuntimeSafety(false);
    var i: usize = 0;
    while (raw_env[i]) |entry_z| : (i += 1) {
        const entry = std.mem.sliceTo(entry_z, 0);
        if (entry.len <= key.len or entry[key.len] != '=') continue;
        if (std.mem.eql(u8, entry[0..key.len], key)) return entry[key.len + 1 ..];
    }
    return null;
}

fn topLevelHelpColumns(raw_env: RawEnviron) usize {
    if (terminal_env.stdoutColumns()) |columns| return columns;
    if (rawEnvValue(raw_env, "COLUMNS")) |value| {
        if (parseColumnCount(value)) |columns| return columns;
    }
    if (comptime builtin.link_libc) {
        if (std.c.getenv("COLUMNS")) |value_z| {
            if (parseColumnCount(std.mem.sliceTo(value_z, 0))) |columns| return columns;
        }
    }
    return command_specs.top_level_help_default_width;
}

fn topLevelHelpStyle(raw_env: RawEnviron) command_specs.HelpStyle {
    const no_color = terminal_env.noColorValue(rawEnvValue(raw_env, "NO_COLOR"));
    const dumb_terminal = terminal_env.dumbTerminalValue(rawEnvValue(raw_env, "TERM"));
    return topLevelHelpStyleForValues(terminal_env.stdoutIsTerminal(), no_color, dumb_terminal);
}

fn topLevelHelpStyleForValues(is_terminal: bool, no_color: bool, dumb_terminal: bool) command_specs.HelpStyle {
    return if (is_terminal and !no_color and !dumb_terminal) .ansi else .plain;
}

fn parseColumnCount(value: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return null;
    const columns = std.fmt.parseUnsigned(usize, trimmed, 10) catch return null;
    return if (columns == 0) null else columns;
}

fn cliArgsFromRaw(raw_args: []const [*:0]const u8, stack_buf: [][:0]const u8) ![]const [:0]const u8 {
    @setRuntimeSafety(false);
    if (comptime hasPosixArgVector()) {
        if (raw_args.len <= 1) return &.{};
        const cli_len = raw_args.len - 1;
        if (cli_len <= stack_buf.len) {
            for (raw_args[1..], 0..) |arg, i| {
                stack_buf[i] = std.mem.sliceTo(arg, 0);
            }
            return stack_buf[0..cli_len];
        }
    }

    const args = try argsFromRaw(raw_args).toSlice(processAllocator());
    return if (args.len > 0) args[1..] else args[0..0];
}

fn isTopLevelHelp(args: []const [:0]const u8) bool {
    if (args.len == 0) return false;
    return command_specs.matchesTopLevel(builtin_commands.top_level_registry, args[0], .help);
}

fn processAllocator() Allocator {
    if (comptime builtin.link_libc) return std.heap.c_allocator;
    return std.heap.page_allocator;
}

fn writeStdoutFast(text: []const u8) !void {
    @setRuntimeSafety(false);
    if (comptime builtin.target.os.tag != .windows) {
        var remaining = text;
        while (remaining.len > 0) {
            const written = std.c.write(std.posix.STDOUT_FILENO, remaining.ptr, remaining.len);
            if (written <= 0) return error.WriteFailed;
            remaining = remaining[@intCast(written)..];
        }
        return;
    }
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

fn writeStderrFast(text: []const u8) !void {
    @setRuntimeSafety(false);
    if (comptime builtin.target.os.tag != .windows) {
        var remaining = text;
        while (remaining.len > 0) {
            const written = std.c.write(std.posix.STDERR_FILENO, remaining.ptr, remaining.len);
            if (written <= 0) return error.WriteFailed;
            remaining = remaining[@intCast(written)..];
        }
        return;
    }
    try std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), text);
}

fn exitFast(code: u8) noreturn {
    if (comptime builtin.link_libc and builtin.target.os.tag != .windows and builtin.target.os.tag != .wasi) {
        std.c._exit(@intCast(code));
    }
    std.process.exit(code);
}

fn hasPosixArgVector() bool {
    return switch (builtin.target.os.tag) {
        .windows, .freestanding, .other => false,
        .wasi => builtin.link_libc,
        else => true,
    };
}

fn needsFullEntryConfig(args: []const [:0]const u8) bool {
    const command = cli_surface.commandAfterGlobalLaunchArgs(args) orelse return false;
    return std.mem.eql(u8, command, "ask") or
        std.mem.eql(u8, command, "acp") or
        std.mem.eql(u8, command, "pr") or
        std.mem.eql(u8, command, "issue");
}

fn needsEarlyThreadedIo(args: []const [:0]const u8) bool {
    if (needsFullEntryConfig(args)) return true;
    const effective_args = cli_surface.argsAfterGlobalLaunchArgs(args);
    if (effective_args.len == 0) return false;
    const command = effective_args[0];
    if (std.mem.eql(u8, command, "mcp")) {
        if (effective_args.len < 2) return false;
        // `add` connects to a new HTTP server to sign in when it needs a login.
        return (effective_args.len >= 3 and std.mem.eql(u8, effective_args[1], "add")) or
            std.mem.eql(u8, effective_args[1], "auth") or
            std.mem.eql(u8, effective_args[1], "list") or
            std.mem.eql(u8, effective_args[1], "logout") or
            // The MCP verbs start a host or delete a stored login.
            std.mem.eql(u8, effective_args[1], "show") or
            std.mem.eql(u8, effective_args[1], "login") or
            std.mem.eql(u8, effective_args[1], "remove") or
            std.mem.eql(u8, effective_args[1], "approve") or
            std.mem.eql(u8, effective_args[1], "reject");
    }
    return std.mem.eql(u8, command, "slack") or
        std.mem.eql(u8, command, "login") or
        std.mem.eql(u8, command, "logout") or
        std.mem.eql(u8, command, "teams") or
        std.mem.eql(u8, command, "provider") or
        std.mem.eql(u8, command, "setup") or
        std.mem.eql(u8, command, "upgrade") or
        std.mem.eql(u8, command, "update") or
        // Resolve a stored credential, which reads the platform key store out of process.
        std.mem.eql(u8, command, "status") or
        std.mem.eql(u8, command, "doctor") or
        std.mem.eql(u8, command, "models") or
        std.mem.eql(u8, command, "credits") or
        std.mem.eql(u8, command, "balance") or
        // Reads AI Gateway usage reports over HTTP with a deadline.
        std.mem.eql(u8, command, "usage");
}

fn fullEntryConfig(auth_mode: credentials.AuthMode) app_entry_runtime.Config {
    return .{
        .version = version,
        .revision = build_options.git_commit,
        .build_channel = compiled_update_channel,
        .auth_mode = auth_mode,
        .command_catalog = builtin_commands.top_level_registry,
        .default_model = "",
        .default_agent_step_limit = default_max_agent_steps,
        .models_path = "/models",
        .gateway_retry_count = model_retry_count,
        .gateway_chat_url = "",
        .provider_set = builtin_providers.native,
        .oauth_transport = builtin_oauth_http.provider,
        .process_provider = shell_process_provider.provider,
        .url_opener = url_opener.native_opener,
        .secret_store = native_host.secret_store,
        .prompt_policy = builtin_context.prompt_policy,
        .skill_root_policy = builtin_skills.root_policy,
        .ignored_list_entries = &ignored_list_entries,
        .max_list_entries = max_list_entries,
        .max_read_file_bytes = max_read_file_bytes,
        .max_read_file_lines = max_read_file_lines,
        .max_read_file_line_len = max_read_file_line_len,
        .max_command_output_bytes = max_command_output_bytes,
        .max_tool_result_bytes = @import("core/tooling/tool_result_limits.zig").default_max_tool_result_bytes,
        .max_history_turns = max_history_turns,
        .context_registry = default_context_registry,
        .mode_registry = builtin_modes.registry,
        .tool_set = builtin_tools.advertisement_set,
        .inspect_mcp_profile_config = builtin_mcp.inspectProfileConfig,
        .inspect_mcp_local_config = builtin_mcp.inspectLocalConfig,
        .load_mcp_host = builtin_mcp.loadHost,
        .acp_runner = .{ .run_fn = runAcpServer },
    };
}

fn localEntryConfig(auth_mode: credentials.AuthMode) app_entry_runtime.Config {
    return .{
        .version = version,
        .revision = build_options.git_commit,
        .build_channel = compiled_update_channel,
        .auth_mode = auth_mode,
        .command_catalog = builtin_commands.top_level_registry,
        .default_model = "",
        .default_agent_step_limit = default_max_agent_steps,
        .models_path = "/models",
        .gateway_retry_count = model_retry_count,
        .gateway_chat_url = "",
        .provider_set = builtin_providers.native,
        .oauth_transport = builtin_oauth_http.provider,
        .process_provider = shell_process_provider.provider,
        .url_opener = url_opener.native_opener,
        .secret_store = native_host.secret_store,
        .prompt_policy = .{ .system_prompt = "" },
        .skill_root_policy = builtin_skills.root_policy,
        .ignored_list_entries = &.{},
        .max_list_entries = 0,
        .max_read_file_bytes = 0,
        .max_read_file_lines = 0,
        .max_read_file_line_len = 0,
        .max_command_output_bytes = 0,
        .max_tool_result_bytes = 0,
        .max_history_turns = 0,
        .context_registry = default_context_registry,
        .mode_registry = builtin_modes.registry,
        .tool_set = builtin_tools.advertisement_set,
        .inspect_mcp_profile_config = builtin_mcp.inspectProfileConfig,
        .inspect_mcp_local_config = builtin_mcp.inspectLocalConfig,
        .load_mcp_host = builtin_mcp.loadHost,
        .acp_runner = .{ .run_fn = runAcpServer },
    };
}

fn emptyEntryConfig(auth_mode: credentials.AuthMode) app_entry_runtime.Config {
    return .{
        .version = version,
        .revision = build_options.git_commit,
        .build_channel = compiled_update_channel,
        .auth_mode = auth_mode,
        .command_catalog = builtin_commands.top_level_registry,
        .default_model = "",
        .default_agent_step_limit = 0,
        .models_path = "",
        .gateway_retry_count = 0,
        .gateway_chat_url = "",
        .provider_set = builtin_providers.native,
        .oauth_transport = builtin_oauth_http.provider,
        .process_provider = shell_process_provider.provider,
        .url_opener = url_opener.native_opener,
        .secret_store = native_host.secret_store,
        .prompt_policy = .{ .system_prompt = "" },
        .skill_root_policy = builtin_skills.root_policy,
        .ignored_list_entries = &.{},
        .max_list_entries = 0,
        .max_read_file_bytes = 0,
        .max_read_file_lines = 0,
        .max_read_file_line_len = 0,
        .max_command_output_bytes = 0,
        .max_tool_result_bytes = 0,
        .max_history_turns = 0,
        .context_registry = default_context_registry,
        .mode_registry = builtin_modes.registry,
        .tool_set = builtin_tools.advertisement_set,
        .inspect_mcp_profile_config = builtin_mcp.inspectProfileConfig,
        .inspect_mcp_local_config = builtin_mcp.inspectLocalConfig,
        .load_mcp_host = builtin_mcp.loadHost,
        .acp_runner = .{ .run_fn = runAcpServer },
    };
}

fn runAcpServer(_: ?*anyopaque, alloc: Allocator, cfg: acp_runner.Config) anyerror!void {
    return acp_server.run(alloc, cfg);
}

fn handleSigWinchNative(_: std.posix.SIG) callconv(.c) void {
    resize_interlock.noteResizeSignal();
}

const handle_sigwinch: app_lifecycle.ResizeHandler = handleSigWinchNative;

test {
    _ = @import("mcp/mcp.zig");
    _ = @import("core/mcp_host/runtime.zig");
    _ = @import("core/mcp_host/wire_tests.zig");
    _ = @import("core/mcp_host/mcp_call.zig");
    _ = @import("core/mcp_host/mcp_call_wire.zig");
    _ = @import("core/mcp_host/mcp_call_bridge.zig");
    _ = @import("core/mcp_host/mcp_call_client.zig");
    _ = @import("core/mcp_host/verbs.zig");
    _ = @import("core/mcp_host/login_words.zig");
    _ = @import("core/mcp/tool_lookup.zig");
    _ = @import("core/recovery/recovery.zig");
    _ = @import("core/config/model_provider.zig");
    _ = @import("core/config/configured_provider.zig");
    _ = @import("gateway/chat_completions_protocol.zig");
    _ = @import("gateway/function_tools.zig");
    _ = @import("core/shared/json_depth.zig");
    _ = provider_runtime;
    _ = @import("acp/prompt.zig");
    _ = @import("acp/server.zig");
    _ = @import("acp/types.zig");
    _ = @import("core/mcp_host/model.zig");
    _ = @import("core/output/activity_status.zig");
    _ = @import("core/agent/agent_runtime.zig");
    _ = @import("core/agent/execution_memory.zig");
    _ = @import("core/agent/runtime/assistant_stream.zig");
    _ = @import("core/agent/runtime/execution_memory.zig");
    _ = @import("core/agent/runtime/tool_admission.zig");
    _ = @import("core/agent/runtime/prompt_context.zig");
    _ = @import("core/agent/runtime/runtime_context.zig");
    _ = @import("core/app/app_agent_runtime.zig");
    _ = @import("core/app/app_auth_runtime.zig");
    _ = auth_runtime;
    _ = @import("core/auth/auth_transition.zig");
    _ = @import("core/workspace/context_contract.zig");
    _ = @import("core/workspace/subagent_turn_metrics.zig");
    _ = @import("core/workspace/workspace_access.zig");
    _ = @import("core/workspace/tool_call_metrics.zig");
    _ = @import("core/workspace/workspace_commands.zig");
    _ = @import("core/workspace/auto_review_metrics.zig");
    _ = @import("core/app/app_workspace_runtime.zig");
    _ = @import("core/app/app_bootstrap_runtime.zig");
    _ = @import("core/app/app_callbacks.zig");
    _ = @import("core/app/app_commands.zig");
    _ = @import("core/app/app_entry_runtime.zig");
    _ = @import("core/app/app_input_runtime.zig");
    _ = input_submit_runtime;
    _ = @import("core/app/app_lifecycle.zig");
    _ = @import("core/app/model_cache_runtime.zig");
    _ = @import("core/app/app_process_runtime.zig");
    _ = @import("core/app/app_render_runtime.zig");
    _ = @import("core/app/input_interrupt_runtime.zig");
    _ = @import("ui/footer/render_input.zig");
    _ = @import("ui/footer/surface_frame.zig");
    _ = @import("ui/footer/paint_plan.zig");
    _ = @import("ui/render_request.zig");
    _ = @import("core/app/app_runtime_setup.zig");
    _ = @import("core/app/app_session_runtime.zig");
    _ = @import("core/app/session_persistence.zig");
    _ = @import("core/app/app_upgrade_runtime.zig");
    _ = @import("core/app/app_worker_runtime.zig");
    _ = @import("ui/event_loop.zig");
    _ = @import("ui/resize_tests.zig");
    _ = @import("ui/transcript/transcript_window_fuzz.zig");
    _ = @import("ui/transcript/frozen_prefix_tests.zig");
    _ = @import("ui/transcript/transcript_window_shell.zig");
    _ = @import("ui/transcript/transcript_window_runtime_tests.zig");
    _ = @import("ui/transcript/frozen_prefix.zig");
    _ = @import("ui/assistant/pacer.zig");
    _ = @import("ui/render_engine/assistant_wrap.zig");
    _ = @import("ui/render_engine/transcript_blocks.zig");
    _ = @import("ui/render_engine/transcript_measure.zig");
    _ = @import("ui/render_engine/viewport_selection.zig");
    _ = @import("core/agent/assistant_presentation.zig");
    _ = @import("core/agent/presentation/inline_render.zig");
    _ = @import("core/upgrade/auto_upgrade.zig");
    _ = @import("core/cli/cli_ask.zig");
    _ = @import("core/cli/cli_replay.zig");
    _ = @import("core/cli/cli_surface.zig");
    _ = @import("core/slack/install.zig");
    _ = @import("core/workspace/change_tracker.zig");
    _ = @import("core/shared/collections.zig");
    _ = @import("core/slash_commands/command_router.zig");
    _ = @import("core/slash_commands/command_specs.zig");
    _ = @import("core/config/config_runtime.zig");
    _ = @import("core/config/settings_store.zig");
    _ = @import("core/session/session_title_generation.zig");
    _ = @import("ui/footer/agents_menu_presentation.zig");
    _ = @import("ui/footer/compact_command_menu_presentation.zig");
    _ = @import("ui/footer/settings_menu_presentation.zig");
    _ = @import("builtins/context.zig");
    _ = @import("core/shared/debug_trace.zig");
    _ = @import("core/output/diff.zig");
    _ = @import("core/output/full_transcript_metadata.zig");
    _ = @import("core/shared/display_width.zig");
    _ = @import("core/shared/gateway_error_format.zig");
    _ = @import("core/shared/history_range.zig");
    _ = @import("core/cli/doctor_runtime.zig");
    _ = @import("core/cli/doctor_probes.zig");
    _ = @import("core/cli/doctor_child_status.zig");
    _ = @import("gateway/responses_protocol.zig");
    _ = credentials;
    _ = @import("core/auth/oauth.zig");
    _ = @import("core/auth/pending_revocation.zig");
    _ = @import("core/mcp_host/kept_sign_outs.zig");
    _ = @import("core/workspace/file_index.zig");
    _ = @import("core/workspace/workspace_capture.zig");
    _ = @import("core/workspace/capture_store.zig");
    _ = @import("core/agent/runtime/deps.zig");
    _ = @import("core/workspace/capture_retention.zig");
    _ = @import("core/workspace/turn_capture.zig");
    _ = @import("core/shared/repo_path.zig");
    _ = @import("core/workspace/path_completion.zig");
    _ = @import("core/workspace/directory_completion_job.zig");
    _ = @import("core/indexer/indexer.zig");
    _ = @import("core/agents/agents.zig");
    _ = @import("core/app/app_agents_runtime.zig");
    _ = @import("core/app/host_record.zig");
    _ = @import("core/profiles/profiles.zig");
    _ = @import("core/prompts/prompts.zig");
    _ = @import("core/profiles/started_with.zig");
    _ = @import("core/input/file_completion_state.zig");
    _ = @import("gateway/vercel_protocol.zig");
    _ = @import("core/gateway/provider_set.zig");
    _ = @import("core/gateway/model_catalog.zig");
    _ = @import("core/gateway/gateway_provider.zig");
    _ = @import("gateway/chat_completions.zig");
    _ = @import("core/github/git_context.zig");
    _ = @import("core/github/github_publish.zig");
    _ = @import("core/github/github_workflows.zig");
    _ = @import("core/hosts/host.zig");
    _ = @import("core/hooks/common.zig");
    _ = @import("core/hooks/definitions.zig");
    _ = @import("core/hooks/prompt.zig");
    _ = @import("core/hooks/runtime.zig");
    _ = @import("core/images/image_attachments.zig");
    _ = @import("core/images/image_commands.zig");
    _ = @import("core/shared/input_loop_guard.zig");
    _ = @import("core/shared/io.zig");
    _ = @import("core/shared/leased_lock.zig");
    _ = @import("core/shared/message.zig");
    _ = @import("core/shared/token_estimate.zig");
    _ = @import("core/shell_command/command_effect.zig");
    _ = @import("core/shell_command/safe_git.zig");
    _ = @import("core/execution/router.zig");
    _ = @import("core/execution/command_runner.zig");
    _ = @import("core/permissions/direct_command.zig");
    _ = @import("core/permissions/command_admission.zig");
    _ = @import("core/mcp/tool_result.zig");
    _ = @import("core/mcp/tool_search.zig");
    _ = @import("core/mcp/http_config.zig");
    _ = @import("core/mcp/elicitation_interaction.zig");
    _ = @import("core/config/model_capabilities.zig");
    _ = @import("core/output/output_contracts.zig");
    _ = @import("core/output/session_list_text.zig");
    _ = @import("core/output/thinking_label.zig");
    _ = @import("core/workspace/pathing.zig");
    _ = @import("core/workspace/current_branch.zig");
    _ = @import("core/workspace/repo_root.zig");
    _ = @import("core/workspace/statusline_identity.zig");
    _ = @import("core/permissions/permission_gate.zig");
    _ = @import("core/permissions/permissions.zig");
    _ = @import("core/execution/process_identity.zig");
    _ = @import("core/execution/process_provider.zig");
    _ = @import("core/execution/managed_execution_contract.zig");
    _ = @import("core/execution/managed_execution.zig");
    _ = @import("core/execution/process_tree.zig");
    _ = @import("core/config/prompt_policy.zig");
    _ = @import("core/workspace/record_tape.zig");
    _ = @import("core/session/session.zig");
    _ = @import("core/session/session_commands.zig");
    _ = @import("core/session/session_json.zig");
    _ = @import("core/session/session_store.zig");
    _ = @import("core/session/session_adapter.zig");
    _ = @import("core/session/v1_conversion.zig");
    _ = @import("core/session/session_catalog_cache.zig");
    _ = @import("core/session/session_layout.zig");
    _ = @import("core/session/prompt_history_store.zig");
    _ = @import("core/app/prompt_history_runtime.zig");
    _ = @import("core/session/web_fetch_artifacts.zig");
    _ = @import("core/skills/skill_runtime.zig");
    _ = @import("core/subagent/domain.zig");
    _ = @import("core/subagent/child_state.zig");
    _ = @import("core/subagent/managed_owner.zig");
    _ = @import("core/subagent/execution.zig");
    _ = @import("core/subagent/agent_adapter.zig");
    _ = @import("core/subagent/tool_host.zig");
    _ = @import("core/subagent/authority.zig");
    _ = @import("core/subagent/reports.zig");
    _ = @import("core/shared/agent_frame.zig");
    _ = @import("core/terminal/contracts.zig");
    _ = @import("core/terminal/operation.zig");
    _ = @import("core/terminal/shell_resolver.zig");
    _ = @import("core/terminal/shell_snapshot.zig");
    _ = @import("core/terminal/native_session.zig");
    _ = @import("core/terminal/recovery.zig");
    _ = @import("core/terminal/store.zig");
    _ = @import("core/terminal/client.zig");
    _ = @import("core/terminal/managed_observer.zig");
    _ = @import("tools/shell/shell.zig");
    _ = @import("tools/shell/process_provider.zig");
    _ = @import("acp/sessions.zig");
    _ = @import("core/shared/text_utils.zig");
    _ = @import("core/shared/testing_listener.zig");
    _ = @import("core/tooling/tool_projection.zig");
    _ = @import("core/tooling/tool_dispatch.zig");
    _ = @import("core/tooling/tool_set.zig");
    _ = @import("core/tooling/tool_args.zig");
    _ = @import("core/tooling/tool_result_errors.zig");
    _ = @import("core/tooling/tool_runtime.zig");
    _ = @import("core/tooling/tool_specs.zig");
    _ = @import("core/tooling/toolbox.zig");
    _ = @import("builtins/commands.zig");
    _ = @import("builtins/mcp.zig");
    _ = @import("builtins/modes.zig");
    _ = @import("builtins/tools.zig");
    _ = @import("tools/agent/ask_user_question.zig");
    _ = @import("core/tooling/model_request_budget.zig");
    _ = @import("core/tooling/web_fetch_runtime.zig");
    _ = @import("core/tooling/web_search_policy.zig");
    _ = @import("core/tooling/web_search_runtime.zig");
    _ = @import("gateway/web_search.zig");
    _ = @import("gateway/web_search_types.zig");
    _ = @import("tools/web/http_fetch.zig");
    _ = @import("tools/web/content.zig");
    _ = @import("tools/web/html_to_markdown.zig");
    _ = @import("tools/filesystem/read_file.zig");
    _ = @import("tools/session/read_tool_result.zig");
    _ = @import("tools/skills/install_skill.zig");
    _ = @import("tools/skills/skill.zig");
    _ = @import("tools/skills/skill_search.zig");
    _ = @import("tools/capabilities/capability_search.zig");
    _ = @import("tools/capabilities/toolbox.zig");
    _ = @import("core/upgrade/upgrade_helpers.zig");
    _ = @import("core/upgrade/upgrade_runtime.zig");
    _ = @import("core/shared/types.zig");
    _ = @import("core/input/composer_history.zig");
    _ = @import("core/input/kill_ring.zig");
    _ = @import("core/input/horizontal_navigation.zig");
    _ = @import("core/input/edit_history.zig");
    _ = @import("core/input/vertical_navigation.zig");
    _ = @import("core/app/input_selection_runtime.zig");
    _ = @import("ui/input/native_clear_probe.zig");
    _ = @import("ui/input/terminal_action_decoder.zig");
    _ = @import("ui/input/visual_layout.zig");
    _ = @import("ui/input/runtime.zig");
    _ = @import("ui/ask_presentation.zig");
    _ = @import("ui/footer/surface_invalidation.zig");
    _ = @import("ui/full_transcript_screen.zig");
    _ = @import("ui/render_engine/frame_fixed_point.zig");
    _ = @import("ui/render_engine/terminal_diff.zig");
    _ = @import("ui/transcript/runtime.zig");
    _ = @import("ui/transcript/runtime_tests.zig");
    _ = @import("ui/transcript/painter.zig");
    _ = @import("core/agent/worker_runtime.zig");
    _ = @import("gateway/client.zig");
    _ = @import("gateway/host_stream_provider.zig");
    _ = @import("gateway/open_job.zig");
}

fn addTestChildAgent(app: *App, id: []const u8) !*app_agents_runtime.ChildAgent {
    const child = try app.alloc.create(app_agents_runtime.ChildAgent);
    errdefer app.alloc.destroy(child);
    child.* = .{ .id = try app.alloc.dupe(u8, id), .agent = .{ .app = @ptrCast(app), .role = .subagent } };
    errdefer app.alloc.free(child.id);
    try app.child_agents.append(app.alloc, child);
    return child;
}

/// A scrollback handoff that still has rows to write, for tests.
const test_pending_handoff: @FieldType(TranscriptRuntime, "pending_session_scrollback_handoff") = .{
    .remaining_rows = 1,
    .total_rows = 2,
    .terminal_cols = 80,
    .terminal_rows = 24,
};

/// Records each agent the tick visits and the assistant text of every event
/// it takes, in order. Events live in the C allocator, as the worker's own
/// teardown frees what is left in its queue with it.
const HiddenWorkVisits = struct {
    seen: std.ArrayList(*agents.Agent) = .empty,
    texts: std.ArrayList([]u8) = .empty,

    fn record(self: *HiddenWorkVisits, a: *App, agent: *agents.Agent) anyerror!void {
        try self.seen.append(a.alloc, agent);
        var events = agent.worker.takeEvents();
        defer {
            for (events.items) |event| worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
            events.deinit(std.heap.c_allocator);
        }
        for (events.items) |event| switch (event) {
            .assistant_presentation => |presentation| {
                const text = try a.alloc.dupe(u8, presentation.text);
                errdefer a.alloc.free(text);
                try self.texts.append(a.alloc, text);
            },
            else => {},
        };
    }

    fn deinit(self: *HiddenWorkVisits, alloc: Allocator) void {
        for (self.texts.items) |text| alloc.free(text);
        self.texts.deinit(alloc);
        self.seen.deinit(alloc);
    }
};

fn pushTestText(agent: *agents.Agent, comptime fmt: []const u8, args: anytype) !void {
    var buf: [64]u8 = undefined;
    const text = try std.mem.print(&buf, fmt, args);
    try agent.worker.pushEvent(std.heap.c_allocator, .{ .assistant_presentation = .{ .text = text } });
}

/// What main's "waiting on N subagents" row counts, with `children` owned by
/// main. The host is only compared, never read, so it is set for this call
/// alone: the list reads a host it is given.
fn waitCountOwnedByMain(app: *App, children: []const *app_agents_runtime.ChildAgent) usize {
    var owner_host: subagent_tool_host.Runtime = undefined;
    app.main_agent.session_persistence.subagent_host = &owner_host;
    for (children) |child| child.parent_host = &owner_host;
    defer {
        app.main_agent.session_persistence.subagent_host = null;
        for (children) |child| child.parent_host = null;
    }
    return App.AgentsAppRuntime.subagentWaitCount(app);
}

/// The state the agent list shows for the row named `name`. The list puts an
/// agent that waits for the user first, so a row's place does not name it.
fn menuRowState(projection: anytype, name: []const u8) ![]const u8 {
    for (projection.rows) |row| if (std.mem.eql(u8, row.name, name)) return row.state;
    return error.RowNotListed;
}

/// Sends `bytes` to `app` one at a time, as the terminal does, so each goes
/// through the decoder and the open list's key routing.
fn sendTerminalBytes(app: *App, bytes: []const u8) !void {
    for (bytes) |byte| try App.InputAppRuntime.handleTerminalByteWithLimits(app, byte, App.input_limits, max_prompt_history);
}

/// Sends `key`, a whole key's bytes, `count` times.
fn sendTerminalKey(app: *App, key: []const u8, count: usize) !void {
    for (0..count) |_| try sendTerminalBytes(app, key);
}

/// Fails, saying after which step, unless the list has armed a close for
/// `expected`, or for nothing when it is null.
fn expectArmedFor(app: *App, expected: ?*app_agents_runtime.ChildAgent, step: []const u8) !void {
    const armed: ?*app_agents_runtime.ChildAgent = if (app.instances.agents_menu.close_armed) |listed| listed.agent else null;
    if (armed == expected) return;
    const alloc = std.testing.allocator;
    const want = try alloc.print("after {s}: a close is armed for {s}", .{
        step,
        if (expected) |child| child.displayName() else "nothing",
    });
    defer alloc.free(want);
    const got = try alloc.print("after {s}: a close is armed for {s}", .{
        step,
        if (armed) |child| child.displayName() else "nothing",
    });
    defer alloc.free(got);
    try std.testing.expectEqualStrings(want, got);
    return error.TestUnexpectedResult;
}

/// One fuzzed run of the agent list over the real runtime, as
/// tests/tla/agents_menu/spec/AgentsMenu.tla models it. Each input byte is a
/// step, its low three bits naming it: open the list, move its highlight
/// down or up, press Enter or Esc, start a subagent, drop one (showing the
/// row above it first when it is on screen, as a close does), or reorder
/// two. A step with the top bit set first switches screens with the list
/// closed. The bytes after a drop, a reorder, or a switch pick the agents.
/// After every step, while the list is open, the highlight is on the agent it
/// was on, or on the agent on screen once that one was dropped, and that
/// agent is the one on screen (PreviewOnMove). The agent on screen changed
/// only on a move, Enter, Esc, a switch, or a drop of the agent on screen. Up
/// on the first row closed the list and kept it (UpOnTopCloses). Esc showed
/// the agent the list opened on, or kept the agent shown once that one was
/// dropped, even when a new agent took the dropped one's address
/// (BackToOrigin).
fn fuzzAgentsMenu(_: void, smith: *std.testing.Smith) !void {
    var input: [96]u8 = undefined;
    const bytes = input[0..smith.slice(&input)];
    var at: usize = 0;
    const alloc = std.testing.allocator;
    var sink = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());
    var app = App{ .alloc = alloc, .shell = .{ .stdout_file = sink } };
    defer app.shell.deinit(alloc);
    defer app.pacer.deinit(alloc);
    defer app.input_runtime.deinit(alloc);
    defer App.AgentsAppRuntime.deinitChildren(&app);
    defer app.instances.agents_menu.deinit(alloc);
    const runtime = App.AgentsAppRuntime;
    const ChildAgent = app_agents_runtime.ChildAgent;
    var order: std.ArrayList(?*ChildAgent) = .empty;
    defer order.deinit(alloc);
    // The agent the highlight must be on while the list is open.
    var expected: ?*ChildAgent = null;
    // The agent the list opened on, while it is open and not dropped.
    var origin: ?*ChildAgent = null;
    var origin_open = false;
    var ids: usize = 0;
    while (at < bytes.len) {
        const step = bytes[at];
        at += 1;
        const screen_before = app.agent_on_screen;
        var screen_may_change = false;
        // With the list closed, the person can still switch another way.
        if (step & 0x80 != 0 and !runtime.menuActive(&app) and app.child_agents.items.len > 0) {
            try runtime.show(&app, app.child_agents.items[pickIndex(bytes, &at, app.child_agents.items.len)]);
            screen_may_change = true;
        }
        const open = runtime.menuActive(&app);
        switch (step & 0x07) {
            0 => if (!open) {
                try runtime.openMenu(&app);
                expected = app.agent_on_screen;
                origin = app.agent_on_screen;
                origin_open = true;
            },
            1, 2 => |key| if (open) {
                order.clearRetainingCapacity();
                try runtime.switchList(&app, &order);
                const from = indexOfAgent(order.items, expected).?;
                _ = try runtime.moveMenu(&app, if (key == 1) 1 else -1, 10);
                if (key == 2 and from == 0) {
                    try std.testing.expect(!runtime.menuActive(&app));
                } else {
                    expected = order.items[if (key == 1) @min(from + 1, order.items.len - 1) else from - 1];
                    try std.testing.expect(app.agent_on_screen == expected);
                    screen_may_change = true;
                }
            },
            3 => if (open) {
                _ = try runtime.submitMenu(&app);
                try std.testing.expect(app.agent_on_screen == expected);
            },
            4 => if (open) {
                _ = try runtime.backMenu(&app);
                if (origin_open) {
                    try std.testing.expect(app.agent_on_screen == origin);
                    screen_may_change = true;
                }
            },
            5 => if (app.child_agents.items.len < 6) {
                var buf: [16]u8 = undefined;
                ids += 1;
                _ = try addTestChildAgent(&app, try std.fmt.bufPrint(&buf, "agent-{d}", .{ids}));
            },
            6 => if (app.child_agents.items.len > 0) {
                const child = app.child_agents.items[pickIndex(bytes, &at, app.child_agents.items.len)];
                if (app.agent_on_screen == child) {
                    // Main's row is first, so a subagent always has a row above it.
                    order.clearRetainingCapacity();
                    try runtime.switchList(&app, &order);
                    try runtime.show(&app, order.items[indexOfAgent(order.items, child).? - 1]);
                    screen_may_change = true;
                }
                runtime.dropHosted(&app, child);
                if (expected == child) expected = app.agent_on_screen;
                if (origin == child) origin_open = false;
            },
            7 => if (app.child_agents.items.len > 1) {
                const from = pickIndex(bytes, &at, app.child_agents.items.len);
                const to = pickIndex(bytes, &at, app.child_agents.items.len);
                const child = app.child_agents.orderedRemove(from);
                app.child_agents.insertAssumeCapacity(to, child);
            },
            else => unreachable,
        }
        if (!runtime.menuActive(&app)) origin_open = false;
        if (!screen_may_change) try std.testing.expect(app.agent_on_screen == screen_before);
        if (runtime.menuActive(&app)) {
            order.clearRetainingCapacity();
            try runtime.switchList(&app, &order);
            try std.testing.expect(app.instances.agents_menu.selected < order.items.len);
            try std.testing.expect(order.items[app.instances.agents_menu.selected] == expected);
            try std.testing.expect(app.agent_on_screen == expected);
        }
    }
}

/// The next input byte as an index below `len`, or 0 past the input's end.
fn pickIndex(bytes: []const u8, at: *usize, len: usize) usize {
    if (at.* >= bytes.len) return 0;
    defer at.* += 1;
    return bytes[at.*] % len;
}

fn indexOfAgent(order: []const ?*app_agents_runtime.ChildAgent, agent: ?*app_agents_runtime.ChildAgent) ?usize {
    for (order, 0..) |entry, index| if (entry == agent) return index;
    return null;
}

/// What the tests of a subagent's end build: an app that writes its tab title
/// to /dev/null, and the cleanup its parts need, in the order they need it.
/// Its children point at its `app`, so it stays where `init` built it.
const EndsFixture = struct {
    sink: std.Io.File,
    app: App,

    fn init(self: *EndsFixture) !void {
        // A switch writes the tab title, so keep it off the test runner's stdout.
        self.sink = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .write_only });
        self.app = .{ .alloc = std.testing.allocator, .shell = .{ .stdout_file = self.sink } };
    }

    fn deinit(self: *EndsFixture) void {
        const alloc = std.testing.allocator;
        self.app.instances.agents_menu.deinit(alloc);
        App.AgentsAppRuntime.deinitChildren(&self.app);
        self.app.input_runtime.deinit(alloc);
        self.app.pacer.deinit(alloc);
        self.app.shell.deinit(alloc);
        self.sink.close(std.testing.io);
    }
};

fn testChildRun(
    alloc: Allocator,
    resolver: *@import("core/subagent/authority.zig").Resolver,
    ultrafast_mode: bool,
    credential: ?credentials.Credential,
) !agents.ChildRun {
    return .{
        .child_id = try alloc.dupe(u8, "child-1"),
        .admission = .{
            .parent_id = try alloc.dupe(u8, "main-session"),
            .source_id = try alloc.dupe(u8, "main-session"),
            .model = try alloc.dupe(u8, "child/model"),
            .effort = types.ReasoningEffort.literal("high"),
            .ultrafast_mode = ultrafast_mode,
            .permission_mode = .yolo,
            .tool_names = try alloc.alloc([]u8, 0),
            .integration_names = try alloc.alloc([]u8, 0),
        },
        .authority_resolver = resolver,
        .system_prompt = try alloc.dupe(u8, "SYSTEM_WITH_CHILD_INSTRUCTIONS"),
        .root_user_intent_context = try alloc.dupe(u8, "ROOT_REQUEST"),
        .credential = credential,
    };
}

/// An `App` for a test of session approvals. `deinit` stops the subagents the
/// test added, frees the approvals, and tears the `App` down in the order it
/// needs.
const ApprovalsFixture = struct {
    app: App,

    fn deinit(self: *ApprovalsFixture) void {
        App.AgentsAppRuntime.shutdownChildren(&self.app);
        App.AgentsAppRuntime.deinitChildren(&self.app);
        self.app.pacer.deinit(self.app.alloc);
        self.app.shell.deinit(self.app.alloc);
    }
};

/// A subagent that owns the host `reporter`, with a run installed so that a
/// report for it can build its turn. Clear `session_persistence.subagent_host`
/// before the app is torn down.
fn addReportTarget(
    app: *App,
    id: []const u8,
    reporter: *subagent_tool_host.Runtime,
    resolver: *@import("core/subagent/authority.zig").Resolver,
) !*app_agents_runtime.ChildAgent {
    const child = try addTestChildAgent(app, id);
    const credential = credentials.Credential{
        .token = try app.alloc.dupe(u8, "CHILD_TOKEN"),
        .source = .configured,
    };
    App.AgentsAppRuntime.installChildRun(app, child, try testChildRun(app.alloc, resolver, false, credential));
    child.agent.session_persistence.subagent_host = reporter;
    return child;
}

fn postTestReport(app: *App, reporter: *subagent_tool_host.Runtime, output: []const u8) !void {
    try app_agents_runtime.postDelivery(&app.child_handoffs, reporter, .{ .report = .{
        .agent = "worker",
        .child_id = "c1",
        .work_id = "w1",
        .outcome = .completed,
        .output = output,
    } });
}

/// The lines of a saved session's log that hold `needle`.
fn countLogLines(alloc: Allocator, tp: *@import("core/subagent/child_state.zig").TestParent, needle: []const u8) !usize {
    const log_path = try std.Io.Dir.path.join(alloc, &.{ ".spark", "sessions", "v2", tp.parent.id(), "log.jsonl" });
    defer alloc.free(log_path);
    const bytes = try tp.tmp.dir.readFileAlloc(io_mod.getIo(), log_path, alloc, .limited(1 << 20));
    defer alloc.free(bytes);
    return std.mem.count(u8, bytes, needle);
}

/// Turn N, streamed to `tp.parent` the way an agent's worker writes it, has
/// finished and the loop has not committed it. A report that missed the turn
/// is then posted to the agent. `gated` is whether the agent's worker has
/// the commit gate on, as the app's threads do. The loop commits turn N
/// through the app's own path, which acknowledges it. `spawn_child` makes a
/// subagent during turn N.
fn runReportBetweenFinishAndCommit(
    alloc: Allocator,
    tp: *@import("core/subagent/child_state.zig").TestParent,
    gated: bool,
    spawn_child: bool,
) !void {
    const session = tp.parent;
    var app = App{ .alloc = alloc };
    defer app.shell.deinit(alloc);
    defer app.pacer.deinit(alloc);
    defer App.AgentsAppRuntime.deinitChildren(&app);
    var reporter: subagent_tool_host.Runtime = undefined;
    var resolver: @import("core/subagent/authority.zig").Resolver = undefined;
    const child = try addReportTarget(&app, "child-1", &reporter, &resolver);
    defer App.AgentsAppRuntime.shutdownChildren(&app);
    defer child.agent.session_persistence.subagent_host = null;
    child.agent.session_persistence.v2 = session;
    defer child.agent.session_persistence.v2 = null;
    if (gated) child.agent.worker.enableCommitGate();

    const user_n: types.UserTurn = .{ .text = @constCast("turn N") };
    const turn_n: types.HistoryTurn = .{ .assistant = .{ .user = user_n, .assistant = @constCast("answer N") } };
    const user_report: types.UserTurn = .{ .text = @constCast("report turn") };
    const turn_report: types.HistoryTurn = .{ .assistant = .{ .user = user_report, .assistant = @constCast("answer report") } };
    const language = types.ConversationLanguage.default();

    // The worker streamed turn N and finished it. Its finish waits for the loop.
    try session.appendProgress(user_n, .{}, .{});
    if (spawn_child) try session.appendChildLines(&.{.{ .spawned = .{ .child = "late", .work_id = "w-late", .data = "{\"kind\":\"persistent\"}" } }});
    try child.agent.worker.pushEvent(std.heap.c_allocator, .{ .finish_prompt = .{ .turn = turn_n } });
    try postTestReport(&app, &reporter, "SECOND_CHILD_REPORT");
    App.AgentsAppRuntime.takePosts(&app);
    try std.testing.expectEqual(@as(usize, 1), child.agent.worker.queuedPromptCount());

    const early = try child.agent.worker.tryTakeNextWork(std.heap.c_allocator);
    if (early) |work| {
        // Without the gate the report's turn begins before the commit.
        defer worker_runtime.freeWorkItem(std.heap.c_allocator, work);
        try std.testing.expect(!gated);
        try session.appendProgress(user_report, .{}, .{});
        try session.commitTurn(turn_n, language);
        try session.commitTurn(turn_report, language);
        return;
    }
    try std.testing.expect(gated);
    // The loop applies the finish: the app's own commit, which acknowledges it.
    var events = child.agent.worker.takeEvents();
    for (events.items) |event| worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
    events.deinit(std.heap.c_allocator);
    try std.testing.expect((try child.agent.worker.tryTakeNextWork(std.heap.c_allocator)) == null);
    try App.SessionAppRuntime.appendFinishedPrompt(&app, &child.agent, .{ .turn = turn_n });
    // The worker begins the report's turn and finishes it.
    const work = (try child.agent.worker.tryTakeNextWork(std.heap.c_allocator)).?;
    defer worker_runtime.freeWorkItem(std.heap.c_allocator, work);
    try std.testing.expect(std.mem.find(u8, work.prompt.prompt, "SECOND_CHILD_REPORT") != null);
    try session.appendProgress(user_report, .{}, .{});
    try session.commitTurn(turn_report, language);
}
