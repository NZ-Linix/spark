const std = @import("std");
const agents = @import("../agents/agents.zig");
const profiles = @import("../profiles/profiles.zig");
const agent_runtime = @import("../agent/agent_runtime.zig");
const runtime_deps = @import("../agent/runtime/deps.zig");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const compaction_activity = @import("../output/compaction_activity.zig");
const command_admission = @import("../permissions/command_admission.zig");
const shared_theme = @import("../shared/theme.zig");
const code_highlight = @import("../agent/presentation/code_highlight.zig");
const code_highlight_languages = @import("../agent/presentation/code_highlight_languages.zig");
const app_callbacks = @import("app_callbacks.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const host = @import("../hosts/host.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const change_tracker = @import("../workspace/change_tracker.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const hooks = @import("../hooks/hooks.zig");
const io_mod = @import("../shared/io.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const mcp_elicitation_interaction = @import("../mcp/elicitation_interaction.zig");
const permissions = @import("../permissions/permissions.zig");
const prompt_policy_contract = @import("../config/prompt_policy.zig");
const model_provider = @import("../config/model_provider.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const session_runtime = @import("../session/session.zig");
const result_store = @import("../session/result_store.zig");
const session_child_store = @import("../session/session_child_store.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const subagent_agent_adapter = @import("../subagent/agent_adapter.zig");
const app_agents_runtime = @import("app_agents_runtime.zig");
const subagent_domain = @import("../subagent/domain.zig");
const subagent_execution = @import("../subagent/execution.zig");
const subagent_authority = @import("../subagent/authority.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");
const diff = @import("../output/diff.zig");
const tool_args = @import("../tooling/tool_args.zig");
const tool_admission = @import("../tooling/tool_admission.zig");
const tool_projection_mod = @import("../tooling/tool_projection.zig");
const model_tool_schema = @import("../tooling/model_tool_schema.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const context_contract = @import("../workspace/context_contract.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_set = @import("../gateway/provider_set.zig");
const test_builtin_tools = if (@import("builtin").is_test)
    @import("../../builtins/tools.zig")
else
    struct {};
const tool_presentation = @import("../tooling/tool_presentation.zig");
const tool_runtime = @import("../tooling/tool_runtime.zig");
const skill_invocation = @import("../skills/skill_invocation.zig");
const web_fetch_runtime = @import("../tooling/web_fetch_runtime.zig");
const web_search_runtime = @import("../tooling/web_search_runtime.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const js_host_workspace = @import("../hosts/js_host_workspace.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const PermissionMode = types.PermissionMode;
const ToolCall = types.ToolCall;
const ToolPermissionDecision = types.ToolPermissionDecision;

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        const ToolAuthorityView = struct {
            mode: PermissionMode,
        };

        fn appAccessScope(app: *const App) ?workspace_access.AccessScope {
            if (comptime @hasDecl(App, "workspaceAccessScope")) {
                return app.workspaceAccessScope();
            }
            return null;
        }

        fn appHostWorkspaceInfo(app: *const App) ?*const js_host_workspace.Info {
            if (comptime @hasDecl(App, "workspaceHostInfo")) {
                return app.workspaceHostInfo();
            }
            return null;
        }

        const TurnWorkspace = struct {
            root: []const u8,
            access_scope: ?workspace_access.AccessScope,
        };

        /// A host workspace owns the root that tools, turns, and project
        /// context use; otherwise the app's local workspace does.
        fn turnWorkspace(app: *const App) TurnWorkspace {
            if (appHostWorkspaceInfo(app)) |info| return .{
                .root = info.root(),
                .access_scope = workspace_access.AccessScope.primaryOnly(info.root()),
            };
            return .{ .root = app.workspace_root, .access_scope = appAccessScope(app) };
        }

        fn modelVisibleProjectContext(app: *App, agent: *AppAgent) []const u8 {
            if (comptime @hasField(App, "context_enabled")) {
                if (!app.context_enabled) return "";
            }
            if (agent.worker.active_context_snapshot) |snapshot| return snapshot.modelVisibleBytes();
            return agent.context_snapshot.modelVisibleBytes();
        }

        fn childToolContext(root_context: tool_runtime.Context) tool_runtime.Context {
            var child_context = root_context;
            child_context.tracker = null;
            return child_context;
        }

        pub fn toolContext(
            app: *App,
            agent: *AppAgent,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) tool_runtime.Context {
            return toolContextWithAuthority(
                app,
                agent,
                ignored_list_entries,
                max_list_entries,
                max_read_file_bytes,
                max_read_file_lines,
                max_read_file_line_len,
                max_command_output_bytes,
                gateway_retry_count,
                gateway_chat_url,
                childToolAuthority(agent),
            );
        }

        /// The current run of the agent this thread works for, when it is a
        /// subagent.
        /// The tools a turn may be shown. A subagent's come from its
        /// admission's permission mode and rules, fixed when it was admitted;
        /// in its own context it has no subagent host, so `subagent` is left
        /// out. Main's come from the job's permission mode.
        fn turnToolProjection(
            app: *App,
            agent: *AppAgent,
            alloc: Allocator,
            permission_mode: types.PermissionMode,
        ) !tool_projection_mod.EffectiveToolProjection {
            if (comptime @hasDecl(App, "snapshotSubagentModelToolProjection")) {
                if (childRun(agent)) |run| return app.snapshotSubagentModelToolProjection(
                    agent,
                    alloc,
                    run.admission.permission_mode,
                );
            }
            return app.snapshotModelToolProjection(agent, alloc, permission_mode);
        }

        fn admittedTool(run: *const agents.ChildRun, name: []const u8) bool {
            for (run.admission.tool_names) |tool| if (std.mem.eql(u8, tool, name)) return true;
            return false;
        }

        fn childRun(agent: *AppAgent) ?*agents.ChildRun {
            if (comptime !agents.hasAgentField(App, "child_run")) return null;
            return if (agent.child_run) |*run| run else null;
        }

        /// A subagent's tools work under its run's admission, never main's
        /// permission engine.
        fn childToolAuthority(agent: *AppAgent) ?ToolAuthorityView {
            const run = childRun(agent) orelse return null;
            return .{
                .mode = (if (comptime agents.hasAgentField(App, "permission_mode")) agent.permission_mode else null) orelse
                    run.admission.permission_mode,
            };
        }

        /// Narrows a tool context to a subagent's run: its own provider, model,
        /// and credential, web search only when its provider has it, and no
        /// subagent host, so a subagent never starts subagents. Its auto-mode
        /// reviewer runs as main's does, on the user's requests the run
        /// carries, never on main's messages to it. Hiding a tool from the model does
        /// not stop a call to it; `childLiveToolAuthority` refuses any tool
        /// outside the admission.
        fn applyChildToolContext(app: *App, ctx: *tool_runtime.Context, run: *agents.ChildRun) void {
            ctx.advertised_dynamic_tool_names = run.admission.integration_names;
            ctx.mcp_access = if (run.admission.mcp_view) |*view|
                .{ .scoped = .{
                    .captured = view,
                    .admission_authority_generation = run.admission.authority_generation,
                    .live = .{ .context = run, .resolve_fn = resolveChildLiveMcpView },
                } }
            else
                .disabled;
            // A child's `subagent` calls go to its own host, which the tool
            // context already holds, as main's go to main's.
            // A child's approvals and questions go to its own worker, as
            // main's do, for main's runs and the user's alike; main's screen
            // borrows them while the child is hidden.
            ctx.interactive = false;
            ctx.ask_user_questions = true;
            ctx.provider = run.admission.provider;
            ctx.model = run.admission.model;
            if (comptime @hasDecl(App, "providerSet")) {
                const bundle = app.providerSet().select(run.admission.provider);
                ctx.provider_capabilities = bundle.capabilities;
                ctx.agent_stream_provider = bundle.agent_stream_or_unavailable();
            }
            if (run.credential) |credential| {
                ctx.api_key = credential.token;
                ctx.credential_source = credential.source;
            }
        }

        /// A subagent turn's live tool authority: every tool call is decided
        /// against the child's admission, resolved fresh for each call.
        fn childLiveToolAuthority(run: *agents.ChildRun) runtime_deps.LiveToolAuthorityProvider {
            return .{ .context = run, .resolve_fn = resolveChildLiveToolAction };
        }

        /// The permission mode a turn on the child decides its tools with when
        /// no work of main's is in flight: a turn the user typed, or steering
        /// left over after main's run ended. Null while main's run is in
        /// flight, whose own work decides. The admission's mode already went
        /// through the child's profile, which gives the same mode again.
        fn userPermissionMode(run: *const agents.ChildRun) ?types.PermissionMode {
            return if (run.inFlight()) null else run.admission.permission_mode;
        }

        fn resolveChildLiveMcpView(raw: *anyopaque, alloc: Allocator) !tool_mcp_runtime.ResolvedLiveView {
            const run: *agents.ChildRun = @ptrCast(@alignCast(raw));
            var authority = if (userPermissionMode(run)) |mode|
                try run.authority_resolver.resolveForUser(alloc, run.child_id, mode)
            else
                try run.authority_resolver.resolve(alloc, run.child_id);
            return subagent_execution.liveMcpViewFrom(alloc, &authority);
        }

        fn resolveChildLiveToolAction(
            raw: *anyopaque,
            alloc: Allocator,
            call: ToolCall,
            workspace_root: []const u8,
            target: []const u8,
            target_kind: tool_dispatch.PermissionTargetKind,
        ) !runtime_deps.ResolvedLiveToolAuthority {
            const run: *agents.ChildRun = @ptrCast(@alignCast(raw));
            return subagent_execution.resolveLiveToolActionFor(
                run.authority_resolver,
                run.child_id,
                userPermissionMode(run),
                alloc,
                call,
                workspace_root,
                target,
                target_kind,
            );
        }

        pub fn toolContextForSubagent(
            app: *App,
            agent: *AppAgent,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            admission: subagent_domain.AdmissionSnapshot,
        ) tool_runtime.Context {
            return toolContextWithAuthority(
                app,
                agent,
                ignored_list_entries,
                max_list_entries,
                max_read_file_bytes,
                max_read_file_lines,
                max_read_file_line_len,
                max_command_output_bytes,
                gateway_retry_count,
                gateway_chat_url,
                .{
                    .mode = admission.permission_mode,
                },
            );
        }

        fn toolContextWithAuthority(
            app: *App,
            agent: *AppAgent,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            authority: ?ToolAuthorityView,
        ) tool_runtime.Context {
            const host_workspace = appHostWorkspaceInfo(app);
            const workspace = turnWorkspace(app);
            const agent_settings = agent.worker.effectiveAgentTurnSettings();
            const permission_snapshot = if (authority) |snapshot|
                worker_runtime.PermissionSnapshot{
                    .mode = snapshot.mode,
                }
            else
                worker_runtime.PermissionSnapshot{ .mode = .yolo };
            const child_capability =
                if (comptime agents.hasAgentField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).childCapability(agent)
                else
                    null;
            const selected_provider = provider_runtime.providerOf(app, agent);
            const provider_capabilities = if (comptime @hasDecl(App, "providerSet"))
                app.providerSet().select(selected_provider).capabilities
            else
                provider_set.Bundle.Capabilities{};
            var ctx: tool_runtime.Context = .{
                .workspace_root = workspace.root,
                .access_scope = workspace.access_scope,
                .ignored_list_entries = ignored_list_entries,
                .max_list_entries = max_list_entries,
                .max_read_file_bytes = max_read_file_bytes,
                .max_read_file_lines = max_read_file_lines,
                .max_read_file_line_len = max_read_file_line_len,
                .max_command_output_bytes = max_command_output_bytes,
                .max_tool_result_bytes = agent_settings.max_tool_result_bytes,
                .auto_compact_percent = agent_settings.auto_compact_percent,
                .api_key = app.auth.apiKey(),
                .agent_stream_provider = if (comptime @hasDecl(App, "agentStreamProvider"))
                    app.agentStreamProvider()
                else
                    agent_stream_provider.unavailable_provider,
                .credential_source = app.auth.credentialSource(),
                .provider = selected_provider,
                .provider_capabilities = provider_capabilities,
                .secret_store = if (comptime @hasDecl(@TypeOf(app.auth), "secretStore"))
                    app.auth.secretStore()
                else
                    host.unavailable_secret_store,
                .model = provider_runtime.modelOf(app, agent),
                .gateway_retry_count = gateway_retry_count,
                .gateway_chat_url = gateway_chat_url,
                .agent_step_limit = app.agent_step_limit,
                .fast_mode = agent_settings.fast_mode,
                .ultrafast_mode = agent_settings.ultrafast_mode,
                .effort = agent_settings.effort,
                .first_call_tool_choice = agent_settings.first_call_tool_choice,
                .tool_registry = if (comptime @hasDecl(App, "toolRegistry")) app.toolRegistry(agent) else .{},
                .subagent_host = if (comptime agents.hasAgentField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).ownSubagentHost(agent)
                else
                    null,
                .subagent_caller_id = if (comptime agents.hasAgentField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).activeSessionId(agent)
                else
                    null,
                .permission_mode = permission_snapshot.mode,
                .worker = &agent.worker,
                .cancel_flag = &agent.worker.worker_cancel_requested,
                .session_child_capability = child_capability,
                .terminal_client = if (comptime @hasField(App, "terminal_client"))
                    &app.terminal_client
                else
                    null,
                .managed_executions = if (comptime agents.hasAgentField(App, "managed_executions"))
                    &agent.managed_executions
                else
                    null,
                .ephemeral_command_replay = if (comptime agents.hasAgentField(App, "managed_executions"))
                    agent.managed_executions.replayStore()
                else
                    null,
                .session = &agent.session,
                .session_allocator = app.alloc,
                .skills_dir = app.skills.dir,
                .context_limits = if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
                .context_enabled = if (comptime @hasField(App, "context_enabled")) app.context_enabled else true,
                .context_registry = app.contextRegistry(),
                .output_chunk_ctx = @ptrCast(agent),
                .on_output_chunk = app_callbacks.Bindings(App).onCommandOutputChunk,
                .workspace_executor = if (comptime @hasDecl(App, "workspaceExecutor")) app.workspaceExecutor() else null,
                .host_sandbox_default = if (host_workspace) |info| switch (info.permission) {
                    .allow_sandboxed => .allow_sandboxed,
                    .prompt => .prompt,
                } else .none,
                .tracker = &agent.change_tracker,
                .mcp_ctx = @ptrCast(app),
                .mcp_has_tool = if (comptime runtime_profile.allows(App, .mcp)) mcpHasTool else null,
                .mcp_validate_tool = if (comptime runtime_profile.allows(App, .mcp)) validateMcpTool else null,
                .mcp_call_tool = if (comptime runtime_profile.allows(App, .mcp)) callMcpTool else null,
                .mcp_search_tools = if (comptime runtime_profile.allows(App, .mcp)) searchMcpTools else null,
                .mcp_tool_schema = if (comptime runtime_profile.allows(App, .mcp)) mcpToolSchemaJson else null,
                .mcp_snapshot_tool = if (comptime runtime_profile.allows(App, .mcp)) mcpSnapshotTool else null,
                .mcp_progress_ctx = @ptrCast(agent),
                .on_mcp_progress = app_callbacks.Bindings(App).onMcpProgress,
                .tool_progress_ctx = @ptrCast(agent),
                .on_tool_progress = app_callbacks.Bindings(App).onToolProgress,
                .nested_tool_lifecycle = .{
                    .context = @ptrCast(agent),
                    .push_fn = app_callbacks.Bindings(App).pushNestedToolLifecycle,
                    .save_bridge_call_fn = app_callbacks.Bindings(App).saveNestedBridgeCall,
                },
                .subagent_status_renderer = app_callbacks.Bindings(App).subagentStatusRenderer(agent),
                .lifecycle_view = app.lifecycle_view,
                .lifecycle_scope = lifecycleContext(app, agent).scope,
            };
            if (comptime @hasField(App, "web_fetch_runtime")) {
                ctx.web_fetch_runtime = &app.web_fetch_runtime;
                ctx.web_fetch_artifact_store = agent.session.webFetchArtifactStore();
                ctx.web_fetch_artifact_error = agent.session.webFetchArtifactError();
                ctx.web_fetch_progress_ctx = @ptrCast(agent);
                ctx.on_web_fetch_progress = app_callbacks.Bindings(App).onWebFetchProgress;
            }
            if (comptime @hasField(App, "web_search_runtime")) {
                ctx.web_search_runtime_ready = false;
                ctx.web_search_progress_ctx = @ptrCast(agent);
                ctx.on_web_search_progress = app_callbacks.Bindings(App).onWebSearchProgress;
            }
            if (comptime runtime_profile.allows(App, .mcp) and
                @hasDecl(@TypeOf(agent.worker), "requestMcpElicitationAnswerBlocking") and
                @hasDecl(App, "urlOpener"))
            {
                ctx.mcp_input_responder = .{
                    .context = @ptrCast(agent),
                    .capabilities = .{ .form = true, .url = true },
                    .legacy_url_manual_completion = true,
                    .callback = respondToMcpInput,
                };
            }
            ctx.model_capability_resolver = app_callbacks.Bindings(App).modelCapabilityResolver(agent);
            ctx.model_override_resolver = app_callbacks.Bindings(App).modelOverrideResolver(agent);
            // An instance whose profile names its MCP servers uses only those.
            // A subagent's run replaces this with its own view below.
            if (instanceMcpProfile(agent)) |profile| {
                ctx.mcp_access = .{ .servers = .{ .context = @ptrCast(profile), .allows_fn = profileAllowsMcpServer } };
            }
            if (childRun(agent)) |run| applyChildToolContext(app, &ctx, run);
            return ctx;
        }

        /// The profile of an instance that names its MCP servers; null otherwise.
        fn instanceMcpProfile(agent: *const AppAgent) ?*const profiles.Profile {
            if (comptime !(agents.hasAgentField(App, "profile") and agents.hasAgentField(App, "role"))) return null;
            if (agent.role != .instance or !profiles.setsMcpServers(&agent.profile.profile)) return null;
            return &agent.profile.profile;
        }

        /// The servers in `names` that `profile` allows; all of them without one.
        fn allowedMcpServers(arena: Allocator, names: []const []const u8, profile: ?*const profiles.Profile) ![]const []const u8 {
            const value = profile orelse return names;
            var kept: std.ArrayList([]const u8) = .empty;
            for (names) |name| if (profiles.allowsMcpServer(value, name)) try kept.append(arena, name);
            return kept.items;
        }

        /// Whether the instance profile at `raw` allows MCP server `server`.
        /// The profile is fixed once the instance launches, so worker threads
        /// read it as it is.
        fn profileAllowsMcpServer(raw: *const anyopaque, server: []const u8) bool {
            const profile: *const profiles.Profile = @ptrCast(@alignCast(raw));
            return profiles.allowsMcpServer(profile, server);
        }

        fn respondToMcpInput(
            raw_ctx: *anyopaque,
            alloc: Allocator,
            origin: tool_mcp_runtime.InputOrigin,
            required: tool_mcp_runtime.InputRequired,
        ) anyerror![]const u8 {
            return mcp_elicitation_interaction.respond(alloc, origin, required, .{
                .questioner = .{ .context = raw_ctx, .ask_fn = askMcpQuestion },
                .browser = .{ .context = raw_ctx, .open_fn = openMcpUrl },
                .compact_forms = true,
                .capabilities = .{ .form = true, .url = true },
            });
        }

        fn askMcpQuestion(
            raw_ctx: *anyopaque,
            alloc: Allocator,
            entries: []const types.QuestionBatchEntry,
            deadline_ms: i64,
            lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
        ) anyerror!?[][]u8 {
            const agent: *AppAgent = @ptrCast(@alignCast(raw_ctx));
            var watch = DeadlineWatch{
                .agent = agent,
                .deadline_ms = deadline_ms,
                .lifecycle_cancel_flag = lifecycle_cancel_flag,
            };
            const watcher = try std.Thread.spawn(.{}, DeadlineWatch.run, .{&watch});
            defer {
                watch.done.store(true, .release);
                watcher.join();
            }

            const c_alloc = std.heap.c_allocator;
            const answers = try agent.worker.requestMcpElicitationAnswerBlocking(c_alloc, entries) orelse {
                if (watch.timed_out.load(.acquire)) return error.McpInputTimedOut;
                return null;
            };
            defer freeMcpAnswers(c_alloc, answers);
            const copy = try alloc.alloc([]u8, answers.len);
            errdefer alloc.free(copy);
            var copied: usize = 0;
            errdefer for (copy[0..copied]) |answer| alloc.free(answer);
            while (copied < answers.len) : (copied += 1) {
                copy[copied] = try alloc.dupe(u8, answers[copied]);
            }
            return copy;
        }

        fn openMcpUrl(
            raw_ctx: ?*anyopaque,
            alloc: Allocator,
            url: []const u8,
        ) anyerror!bool {
            const agent: *AppAgent = @ptrCast(@alignCast(raw_ctx.?));
            return app_agents_runtime.appOf(App, agent).urlOpener().open(alloc, url);
        }

        fn freeMcpAnswers(alloc: Allocator, answers: [][]u8) void {
            for (answers) |answer| alloc.free(answer);
            alloc.free(answers);
        }

        /// Watches one agent's cancel flag while its MCP question waits. It
        /// runs on its own thread, so it holds the agent it watches.
        const DeadlineWatch = struct {
            agent: *AppAgent,
            deadline_ms: i64,
            lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
            done: std.atomic.Value(bool) = .init(false),
            timed_out: std.atomic.Value(bool) = .init(false),

            fn run(self: *DeadlineWatch) void {
                while (!self.done.load(.acquire)) {
                    const cancelled = self.agent.worker.worker_cancel_requested.load(.acquire);
                    const lifecycle_cancelled = if (self.lifecycle_cancel_flag) |flag|
                        flag.load(.acquire)
                    else
                        false;
                    const timed_out = currentAwakeMillis() >= self.deadline_ms;
                    if (cancelled or lifecycle_cancelled or timed_out) {
                        if (timed_out and !cancelled and !lifecycle_cancelled) {
                            self.timed_out.store(true, .release);
                        }
                        if (self.agent.worker.cancelPendingQuestionBatch()) return;
                    }
                    io_mod.sleep(20 * std.time.ns_per_ms);
                }
            }
        };

        fn currentAwakeMillis() i64 {
            const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
            const milliseconds = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
            return std.math.cast(i64, milliseconds) orelse if (milliseconds < 0)
                std.math.minInt(i64)
            else
                std.math.maxInt(i64);
        }

        fn mcpHasTool(raw_ctx: *anyopaque, name: []const u8, access: tool_mcp_runtime.Access) bool {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            return app.hasMcpTool(name, access);
        }

        fn validateMcpTool(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, access: tool_mcp_runtime.Access) anyerror!tool_mcp_runtime.ValidationResult {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            if (comptime @hasDecl(App, "validateMcpTool")) {
                return app.validateMcpTool(arena, name, arguments_json, access);
            }
            return .not_available;
        }

        fn callMcpTool(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, max_tool_result_bytes: usize, options: tool_mcp_runtime.CallOptions) anyerror!?tool_mcp_runtime.CallResult {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            return app.callMcpTool(arena, name, arguments_json, max_tool_result_bytes, options);
        }

        fn searchMcpTools(raw_ctx: *anyopaque, arena: Allocator, request: tool_mcp_runtime.SearchRequest, _: @import("../config/context_limits.zig").Values, access: tool_mcp_runtime.Access, cancel_flag: ?*std.atomic.Value(bool)) anyerror!tool_mcp_runtime.SearchResult {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            if (comptime @hasDecl(App, "searchMcpTools")) {
                return app.searchMcpTools(arena, request, access, cancel_flag);
            }
            return .{ .model_output = try arena.dupe(u8, "{\"tools\":[],\"count\":0}") };
        }

        fn mcpSnapshotTool(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, known: tool_mcp_runtime.Binding, limits: @import("../config/context_limits.zig").Values, access: tool_mcp_runtime.Access) anyerror!tool_mcp_runtime.DefinitionSnapshot {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            if (comptime @hasField(App, "mcp")) {
                return app.mcp.snapshotToolDefinition(arena, name, known, limits, access);
            }
            return .unavailable;
        }

        fn mcpToolSchemaJson(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, _: @import("../config/context_limits.zig").Values, access: tool_mcp_runtime.Access, cancel_flag: ?*std.atomic.Value(bool)) anyerror!?tool_mcp_runtime.ToolSchemaResult {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            if (comptime @hasDecl(App, "mcpToolSchemaJson")) {
                return app.mcpToolSchemaJson(arena, name, access, cancel_flag);
            }
            return null;
        }

        pub fn resolveToolActionDisplayTarget(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !?[]const u8 {
            const ctx = toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url);
            // A wait, or a status that names no agent, concerns every
            // subagent this agent runs, so its row names them as its host
            // lists them now: `waiting for reviewer, builder`.
            if (try tool_presentation.subagentRoster(arena, call)) |roster| {
                const subagent_host = ctx.subagent_host orelse return null;
                return subagent_host.rosterNames(arena, roster == .working) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => blk: {
                        debug_trace.logf("subagent", "roster unavailable for row call_id={s} err={s}", .{ call.id, @errorName(err) });
                        break :blk null;
                    },
                };
            }
            return tool_presentation.resolveTerminalDisplayTarget(
                arena,
                ctx.tool_registry,
                ctx.workspace_root,
                ctx.terminal_client,
                ctx.managed_executions,
                call,
            );
        }

        pub fn releaseAgentTerminalLease(
            app: *App,
            agent: *AppAgent,
            session_id: []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !void {
            return tool_runtime.release_agent_terminal_lease(
                toolContext(
                    app,
                    agent,
                    ignored_list_entries,
                    max_list_entries,
                    max_read_file_bytes,
                    max_read_file_lines,
                    max_read_file_line_len,
                    max_command_output_bytes,
                    gateway_retry_count,
                    gateway_chat_url,
                ),
                session_id,
            );
        }

        pub fn stopSteeringDetachedCommands(
            app: *App,
            agent: *AppAgent,
            turn_id: u64,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !void {
            return tool_runtime.stop_steering_detached_commands(
                toolContext(
                    app,
                    agent,
                    ignored_list_entries,
                    max_list_entries,
                    max_read_file_bytes,
                    max_read_file_lines,
                    max_read_file_line_len,
                    max_command_output_bytes,
                    gateway_retry_count,
                    gateway_chat_url,
                ),
                turn_id,
            );
        }

        pub fn describeToolAction(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            display_target: ?[]const u8,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            return formatToolAction(ctx, arena, call, display_target, .active, null);
        }

        pub fn describeToolActionCompleted(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            display_target: ?[]const u8,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            return formatToolAction(ctx, arena, call, display_target, .completed, null);
        }

        pub fn describeToolActionDenied(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            display_target: ?[]const u8,
            label: []const u8,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            return formatToolAction(ctx, arena, call, display_target, .denied, label);
        }

        pub fn requestToolPermissionSync(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            live_authority: ?agent_runtime.LiveToolAuthority,
            revalidation: ?command_admission.ToolExecutionAuthority,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !command_admission.PermissionOutcome {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            const admission = ctx.admissionInputWithLiveAuthority(live_authority);
            if (revalidation) |authority| return tool_admission.revalidateLiveActionPermissionOutcome(admission, arena, call, authority);
            return tool_admission.requestPermissionOutcome(admission, arena, call);
        }

        pub fn requestPreparedFileMutationPermissionSync(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            prepared: *tool_admission.PreparedFileMutationCall,
            live_authority: ?agent_runtime.LiveToolAuthority,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !command_admission.PermissionOutcome {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            return tool_admission.requestPreparedFileMutationPermissionOutcome(ctx.admissionInputWithLiveAuthority(live_authority), arena, call, prepared);
        }

        pub fn validateToolCall(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !agent_runtime.ToolCallValidationResult {
            return tool_runtime.validateToolCall(toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), arena, call);
        }

        /// The current definition of a live MCP tool the model called without
        /// loading it this turn, or null when no permitted tool has that name.
        pub fn resolveUnselectedMcpTool(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            name: []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !?tool_mcp_runtime.SelectedTool {
            return tool_runtime.resolveUnselectedMcpTool(toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), arena, name);
        }

        pub fn checkToolAvailability(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !?[]const u8 {
            return tool_runtime.checkToolAvailability(toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), arena, call);
        }

        pub fn permissionTargetForCall(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            return tool_admission.permissionTargetForCall(ctx.admissionInput(), arena, call);
        }

        pub fn executeToolCall(
            app: *App,
            agent: *AppAgent,
            request: agent_runtime.ToolExecutionRequest,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !agent_runtime.ToolExecutionResult {
            var ctx = toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url);
            applyCredentialLease(&ctx, request.credential);
            ctx.root_user_intent_context = request.root_user_intent_context;
            ctx.root_user_messages = request.root_user_messages;
            ctx.root_user_evidence_complete = request.root_user_evidence_complete;
            ctx.advertised_dynamic_tool_names = request.advertised_dynamic_tool_names;
            ctx.max_tool_result_bytes = request.max_tool_result_bytes;
            return tool_runtime.executeToolCallAuthorized(ctx, request);
        }

        fn applyCredentialLease(ctx: *tool_runtime.Context, credential: types.CredentialLease) void {
            const credential_secret = credential.secret() orelse return;
            const credential_source = credential.credentialSource();
            ctx.api_key = credential_secret;
            ctx.credential_source = credential_source;
        }

        pub fn appendStaticContextMessage(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            messages: *std.ArrayList(ChatMessage),
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !void {
            _ = ignored_list_entries;
            _ = max_list_entries;
            _ = max_read_file_bytes;
            _ = max_read_file_lines;
            _ = max_read_file_line_len;
            _ = max_command_output_bytes;
            _ = gateway_retry_count;
            _ = gateway_chat_url;
            try app.contextRegistry().appendDefaultStatic(.{
                .project_context = modelVisibleProjectContext(app, agent),
            }, arena, messages);
            // The toolbox menu lists the MCP servers (config.toolbox_mcp_servers),
            // so there is no MCP block here, and no per-request status that
            // would change what earlier requests sent.
        }

        pub fn appendTransientRuntimeContextMessage(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            messages: *std.ArrayList(ChatMessage),
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !void {
            _ = ignored_list_entries;
            _ = max_list_entries;
            _ = max_read_file_bytes;
            _ = max_read_file_lines;
            _ = max_read_file_line_len;
            _ = max_command_output_bytes;
            _ = gateway_retry_count;
            _ = gateway_chat_url;
            const permission_snapshot = worker_runtime.PermissionSnapshot{ .mode = .yolo };
            const host_workspace = appHostWorkspaceInfo(app);
            const workspace = turnWorkspace(app);
            // The agent's own subagents, as its turn started with them.
            const subagents: ?[]const u8 = if (comptime agents.hasAgentField(App, "session_persistence"))
                if (app_session_runtime.Runtime(App).ownSubagentHost(agent)) |team_host| try team_host.teamNote(arena, agent.worker.activeTurnId()) else null
            else
                null;
            try app.contextRegistry().appendDefaultTransient(.{
                .workspace_root = workspace.root,
                .host_workspace = if (host_workspace) |info| .{
                    .root = info.root(),
                    .cwd = info.cwd(),
                    .home = info.home(),
                } else null,
                .access_scope = workspace.access_scope,
                .interactive = true,
                .permission_mode = permission_snapshot.mode,
                .subagents = subagents,
            }, arena, messages);
        }

        /// Gathers the instructions' project context for the next turn. It
        /// names no target: rules for a folder a turn reaches arrive as notes
        /// in the conversation, never here, so the instructions do not change
        /// from turn to turn.
        pub fn refreshProjectContext(app: *App, agent: *AppAgent) context_contract.ProviderError!void {
            agent.context_snapshot.deinit(app.alloc);
            if (!app.context_enabled) return;

            const workspace = turnWorkspace(app);
            agent.context_snapshot = app.contextRegistry().gatherDefaultSnapshot(app.alloc, .{
                .workspace_root = workspace.root,
                .access_scope = workspace.access_scope,
                .context_limits = if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
            }) catch |err| {
                debug_trace.logf("context", "gather failed err={s}", .{@errorName(err)});
                return err;
            };
            if (comptime @hasDecl(App, "writeDomainNotice")) {
                for (agent.context_snapshot.notices) |notice| {
                    const should_emit = if (comptime @hasDecl(@TypeOf(agent.session), "claimContextNotice"))
                        try agent.session.claimContextNotice(app.alloc, notice)
                    else
                        true;
                    if (should_emit) {
                        const body = try types.renderContextNoticeBody(app.alloc, notice);
                        defer app.alloc.free(body);
                        app.writeDomainNotice(.{
                            .topic = "context",
                            .tone = .warning,
                            .body = body,
                            .visibility = .full_only,
                        }, true) catch return error.WriteFailed;
                    }
                }
            }
        }

        pub fn fetchModelIds(
            app: *App,
            provider: model_catalog.Provider,
            catalog_endpoint: []const u8,
        ) !std.ArrayList([]u8) {
            const result = model_catalog.fetchTraced(provider, app.alloc, .{
                .access = app.auth.modelCatalogAccess(),
                .endpoint = catalog_endpoint,
            });
            var catalog = switch (result) {
                .loaded => |loaded| loaded.catalog,
                .failed => |failed| return failed.failure.asError(),
            };
            defer model_catalog.freeModelCatalog(app.alloc, &catalog);
            return model_catalog.projectModelIds(app.alloc, catalog.items);
        }

        pub fn processQueuedPrompt(
            app: *App,
            agent: *AppAgent,
            queued_job: worker_runtime.QueuedPrompt,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            failure_provenance: ?*?compaction_activity.ErrorProvenance,
        ) !void {
            if (failure_provenance) |out| out.* = null;
            var job = queued_job;
            var snapshot_ownership = worker_runtime.ActivePromptSnapshotOwnership.init(job.images);
            agent.worker.beginActivePromptSnapshots(&snapshot_ownership);
            defer agent.worker.endActivePromptSnapshots(&snapshot_ownership);
            agent.worker.active_context_snapshot = &job.context_snapshot;
            defer agent.worker.active_context_snapshot = null;
            agent.worker.setActiveAgentTurnSettings(job.agent_settings);
            defer agent.worker.clearActiveAgentTurnSettings();
            var preflight_context_notices: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
            defer preflight_context_notices.deinit();
            for (job.context_snapshot.notices) |notice| {
                try appendClaimedContextNotice(agent, &preflight_context_notices.writer, notice);
            }

            var skill_catalog = app.skills.acquireCatalog();
            defer skill_catalog.deinit();
            const explicit_bindings = try std.heap.c_allocator.alloc(skill_invocation.ExplicitBinding, job.skill_bindings.len);
            defer std.heap.c_allocator.free(explicit_bindings);
            for (job.skill_bindings, 0..) |binding, index| {
                explicit_bindings[index] = .{ .name = binding.name, .path = binding.path };
            }
            if (preflight_context_notices.written().len > 0) {
                try app_worker_runtime.Runtime(App).pushSemanticNotice(app, agent, .{
                    .topic = "context",
                    .tone = .warning,
                    .body = preflight_context_notices.written(),
                    .visibility = .full_only,
                });
            }
            var tool_projection = try turnToolProjection(app, agent, std.heap.c_allocator, job.permission_mode);
            defer tool_projection.deinit(std.heap.c_allocator);
            const session_child_capability =
                if (comptime agents.hasAgentField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).childCapability(agent)
                else
                    null;

            var deps = app_callbacks.Bindings(App).agentRuntimeDeps(app, agent);
            if (comptime @hasDecl(App, "providerSet")) deps.agent_stream_provider = app.providerSet().select(job.provider).agent_stream_or_unavailable();
            deps.cache_warmer = cacheWarmerFor(app, agent);
            deps.compaction_failure = failure_provenance;
            // Hiding a tool does not stop a call to it: a subagent's calls are
            // decided against its admission, so `subagent` and any tool or
            // integration outside it are refused.
            if (childRun(agent)) |run| deps.live_tool_authority = childLiveToolAuthority(run);
            const semantic_presentation = app_callbacks.Bindings(App).semanticPresentationSink(agent);
            var config = buildQueuedPromptConfig(
                app,
                agent,
                job,
                .{ .skills = skill_catalog.items, .diagnostics = skill_catalog.diagnostics },
                explicit_bindings,
                gateway_retry_count,
                gateway_chat_url,
                &tool_projection,
                session_child_capability,
            );
            // The toolbox menu lists the MCP servers the agent may call, by name.
            var toolbox_arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer toolbox_arena_state.deinit();
            if (comptime @hasDecl(App, "mcpServerNames")) {
                const toolbox_arena = toolbox_arena_state.allocator();
                config.toolbox_mcp_servers = try allowedMcpServers(toolbox_arena, try app.mcpServerNames(toolbox_arena), instanceMcpProfile(agent));
            }
            if (comptime @hasField(App, "toolbox_behind")) config.toolbox_behind = app.toolbox_behind.slice();
            // A subagent is shown only the built-in tools its run was admitted
            // with, the ones its live authority lets it call.
            var child_tools = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer child_tools.deinit();
            if (childRun(agent)) |run| {
                const shown: subagent_agent_adapter.Shown = .{ .admitted = .{
                    .tools = run.admission.tool_names,
                    .starts_subagents = app_session_runtime.Runtime(App).ownSubagentHost(agent) != null,
                } };
                config.advertised_tool_names = try subagent_agent_adapter.childToolNames(
                    child_tools.allocator(),
                    config.advertised_tool_names,
                    deps.tool_registry,
                    shown,
                );
                config.advertised_functions = try subagent_agent_adapter.childFunctions(
                    child_tools.allocator(),
                    config.advertised_functions,
                    deps.tool_registry,
                    shown,
                );
                // The vision fallback is offered as a tool, so a run not
                // admitted with `vision` is not offered it.
                if (!admittedTool(run, "vision")) config.provider_capabilities.vision_fallback = false;
            }
            const process_result = agent_runtime.processAgentPrompt(&agent.session.agent, &deps, semantic_presentation, lifecycleContext(app, agent), config, job);
            try process_result;
        }

        /// `agent`'s session's cache warmer, when the profile keeps it on.
        /// Unit tests share the real provider bundles and never ping.
        fn cacheWarmerFor(app: *App, agent: *AppAgent) ?*@import("../agent/runtime/cache_warmer.zig").Warmer {
            if (comptime @import("builtin").is_test or !@hasField(App, "cache_warming")) return null;
            if (!app.cache_warming) return null;
            return agent.session.cacheWarmer();
        }

        pub fn processContextCompaction(
            app: *App,
            agent: *AppAgent,
            job: worker_runtime.ContextCompactionTask,
            gateway_retry_count: usize,
            failure_provenance: ?*?compaction_activity.ErrorProvenance,
        ) anyerror!void {
            if (failure_provenance) |out| out.* = null;
            const operation_id = job.operation_id orelse agent.worker.beginCompactionActivity(.manual, job.turn_id);
            agent.worker.runCompactionActivity(operation_id, .preparation);
            // Covers early cancellation before compaction starts; acknowledged settlement wins.
            defer if (agent.worker.isCancelRequested()) {
                agent.worker.settleCompactionActivity(operation_id, .{ .outcome = .cancelled });
            };
            compactWithActivity(app, agent, job, gateway_retry_count, operation_id) catch |err| {
                agent.worker.settleCompactionActivity(operation_id, compaction_activity.failure(err, .preparation, agent.worker.isCancelRequested()));
                if (failure_provenance) |out| out.* = .{ .operation_id = operation_id, .turn_id = job.turn_id, .err = err };
                return err;
            };
        }

        fn compactWithActivity(
            app: *App,
            agent: *AppAgent,
            job: worker_runtime.ContextCompactionTask,
            gateway_retry_count: usize,
            operation_id: compaction_activity.OperationId,
        ) anyerror!void {
            var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            var deps = app_callbacks.Bindings(App).agentRuntimeDeps(app, agent);
            if (comptime @hasDecl(App, "providerSet")) {
                deps.agent_stream_provider = app.providerSet().select(job.provider).agent_stream_or_unavailable();
            }
            const capabilities = deps.available_model_capabilities(deps.ctx, job.model);
            const settings = agent.worker.effectiveAgentTurnSettings();
            const provider_options = model_capabilities.resolveProviderOptionsForCapabilities(capabilities, settings.effort, settings.fast_mode);
            var summary_model: agent_runtime.CompactorCaller = .{
                .stream_provider = deps.agent_stream_provider,
                .cooperative_transport_pulse = deps.cooperative_transport_pulse,
                .provider = job.provider,
                .model = job.model,
                .api_key = job.api_key,
                .credential_source = job.credential_source,
                .account_id = job.account_id,
                .gateway_team = job.gateway_team,
                .session_id = app_session_runtime.Runtime(App).activeSessionId(agent),
                .retry_count = gateway_retry_count,
                .provider_options = provider_options,
                .max_output_tokens = model_capabilities.requestOutputTokens(capabilities),
                .capabilities_context = deps.ctx,
                .capabilities_fn = deps.available_model_capabilities,
                // A sign-in another spark process renewed since `/compact`
                // started gets one more send, as an agent turn does.
                .renewal_deps = &deps,
            };
            defer summary_model.deinit();
            const result = agent_runtime.compactContext(arena, &deps, .{
                .operation_id = operation_id,
                .activity_origin = .manual,
                .compactor = .{
                    .history = job.history,
                    .append_messages = session_runtime.appendHistoryChatMessages,
                    .size = agent_runtime.compactionSize(&agent.session.agent, capabilities, settings.auto_compact_percent, job.model),
                    .caller = summary_model.caller(),
                    .records = if (app_session_runtime.Runtime(App).childCapability(agent)) |capability| result_store.compactorStore(capability) else null,
                    .cancel_flag = &agent.worker.worker_cancel_requested,
                    .trace_ctx = .{ .turn_id = job.turn_id },
                },
            }) catch |err| {
                if (err == error.Cancelled and agent.worker.worker_cancel_requested.load(.seq_cst)) return;
                return @as(anyerror!void, err);
            };
            if (result == null) agent.worker.settleCompactionActivity(operation_id, .{ .outcome = .no_op });
        }

        fn lifecycleContext(app: *App, agent: *AppAgent) agent_runtime.LifecycleContext {
            if (childRun(agent)) |run| return .{
                .view = app.lifecycle_view,
                .scope = .{
                    .kind = .subagent,
                    .workspace_root = app.workspace_root,
                    .session_id = run.child_id,
                    .subagent_id = run.subagent_id,
                },
                .outcome_allocator = app.alloc,
            };
            return .{
                .view = app.lifecycle_view,
                .scope = .{
                    .kind = .interactive,
                    .workspace_root = app.workspace_root,
                    .session_id = if (comptime agents.hasAgentField(App, "session_persistence"))
                        app_session_runtime.Runtime(App).activeSessionId(agent)
                    else
                        null,
                },
                .outcome_allocator = app.alloc,
            };
        }

        /// Binds a child's run to the child's own agent, started on first use,
        /// so its turn runs on that agent's worker. Runs on the run's slot
        /// thread and waits for the main loop.
        pub fn bindSubagentWorker(
            raw: ?*anyopaque,
            turn: *subagent_execution.TurnContext,
            cancel: *std.atomic.Value(bool),
        ) subagent_execution.ServiceError!void {
            const app: *App = @ptrCast(@alignCast(raw.?));
            var post = app_agents_runtime.Post{ .turn = turn };
            app_agents_runtime.postAndWait(&app.child_handoffs, &post, cancel) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Cancelled => error.Cancelled,
                error.Failed => error.ProviderFailed,
            };
        }

        /// Runs one child turn on the child's own agent, which runs main's
        /// code: the run is handed to the main loop, which sends the message
        /// to the agent as if typed, and this waits until its turn is saved to
        /// the child's log or ends. Runs on the run's slot thread, after
        /// `bindSubagentWorker`.
        pub fn runSubagentChild(
            raw: ?*anyopaque,
            turn: *subagent_execution.TurnContext,
            message: subagent_domain.QueuedMessage,
            admission: subagent_domain.AdmissionSnapshot,
            cancel: *std.atomic.Value(bool),
        ) subagent_execution.ServiceError!subagent_execution.RunOutcome {
            const app: *App = @ptrCast(@alignCast(raw.?));
            if (turn.hosted_worker == null) return error.ProviderFailed;
            var run = try prepareChildRun(app, turn, message, admission);
            var completion: agents.ChildRunCompletion = .{};
            run.completion = &completion;
            var post = app_agents_runtime.Post{ .turn = turn, .run = run, .message = message.content };
            defer if (post.run) |*unsent| {
                unsent.completion = null;
                unsent.turn = null;
                unsent.deinit(app.alloc);
            };
            app_agents_runtime.postAndWait(&app.child_handoffs, &post, cancel) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Cancelled => error.Cancelled,
                error.Failed => error.ProviderFailed,
            };
            return switch (app_agents_runtime.waitForCompletion(&completion, cancel, turn.workerRuntime())) {
                .completed => .completed,
                .cancelled => error.Cancelled,
                .failed => error.ProviderFailed,
            };
        }

        /// What a child's run takes from its admission alone: the admission,
        /// the system prompt with the child's profile and `overlay`, and the
        /// credential for the admission's provider when main's does not
        /// authorize it. A run's turn context, when there is one, records why
        /// a credential could not be had.
        const ChildRunBase = struct {
            admission: subagent_domain.AdmissionSnapshot,
            system_prompt: []u8,
            credential: ?credentials.Credential,
        };

        fn prepareChildRunBase(
            app: *App,
            child_id: []const u8,
            resolver: *subagent_authority.Resolver,
            overlay: []const u8,
            admission: subagent_domain.AdmissionSnapshot,
            turn: ?*subagent_execution.TurnContext,
        ) subagent_execution.ServiceError!ChildRunBase {
            const alloc = app.alloc;
            // The tool context and prompt are those of the instance at the
            // top of the child's tree, so a launched instance's subagents use
            // its provider and approvals, not the first instance's.
            const root = rootInstanceOfChild(app, child_id);
            const base_context = app.subagentToolContextForAdmission(root, admission);
            var credential: ?credentials.Credential = null;
            errdefer if (credential) |*value| value.deinit(alloc);
            if (admission.provider == .configured or
                !model_provider.authorizesCredential(admission.provider, base_context.credential_source))
            {
                credential = auth_runtime.prepareCredential(alloc, admission.provider) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    if (turn) |value| value.setFailureDiagnostic("model_credential_resolution_failed", @errorName(err));
                    return error.ProviderFailed;
                };
                if (credential == null) {
                    if (turn) |value| value.setFailureDiagnostic("model_credential_missing", admission.model);
                    return error.ProviderFailed;
                }
            }
            var prompt_arena = std.heap.ArenaAllocator.init(alloc);
            defer prompt_arena.deinit();
            const system_prompt = try alloc.dupe(u8, try subagent_agent_adapter.childSystemPrompt(
                prompt_arena.allocator(),
                subagent_agent_adapter.childProfile(resolver, child_id),
                app.promptPolicy(root).system_prompt,
                try childRole(app, prompt_arena.allocator(), child_id, resolver, turn),
                overlay,
            ));
            errdefer alloc.free(system_prompt);
            const owned_admission = admission.clone(alloc) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.AdmissionFailed,
            };
            return .{ .admission = owned_admission, .system_prompt = system_prompt, .credential = credential };
        }

        /// The instance at the top of child `child_id`'s tree, or the first
        /// instance while the child is not yet bound to the host that
        /// started it. Takes the authority lock, which guards the list.
        /// A subagent's name and its parent's, for its system prompt. The
        /// parent is the agent whose own subagent host has `resolver`: `main`
        /// for main or an instance, otherwise that subagent. Names belong to
        /// `arena`.
        fn childRole(
            app: *App,
            arena: Allocator,
            child_id: []const u8,
            resolver: *subagent_authority.Resolver,
            turn: ?*subagent_execution.TurnContext,
        ) Allocator.Error!subagent_agent_adapter.Role {
            var role: subagent_agent_adapter.Role = .{
                .name = if (turn) |value| value.child_name orelse child_id else child_id,
                .parent = profiles.main_name,
            };
            if (comptime !@hasField(App, "child_agents")) return role;
            app.authority_mutex.lockUncancelable(io_mod.getIo());
            defer app.authority_mutex.unlock(io_mod.getIo());
            for (app.child_agents.items) |child| {
                if (std.mem.eql(u8, child.id, child_id) and child.name.len > 0) role.name = try arena.dupe(u8, child.name);
                if (child.agent.role != .subagent) continue;
                const own_host = child.agent.session_persistence.subagent_host orelse continue;
                if (own_host.authorityResolver() == resolver) role.parent = try arena.dupe(u8, child.displayName());
            }
            return role;
        }

        fn rootInstanceOfChild(app: *App, child_id: []const u8) *AppAgent {
            if (comptime !@hasField(App, "child_agents")) return &app.main_agent;
            app.authority_mutex.lockUncancelable(io_mod.getIo());
            defer app.authority_mutex.unlock(io_mod.getIo());
            for (app.child_agents.items) |child| {
                if (std.mem.eql(u8, child.id, child_id)) return child.agent.root_instance orelse &app.main_agent;
            }
            return &app.main_agent;
        }

        fn freeChildRunBase(alloc: Allocator, base: *ChildRunBase) void {
            base.admission.deinit(alloc);
            alloc.free(base.system_prompt);
            if (base.credential) |*value| value.deinit(alloc);
        }

        /// Everything a child agent's turns read from this run, prepared off
        /// the main loop: its admission, system prompt, and credential
        /// (`prepareChildRunBase`), and the root user's request for the
        /// permission reviewer.
        fn prepareChildRun(
            app: *App,
            turn: *subagent_execution.TurnContext,
            message: subagent_domain.QueuedMessage,
            admission: subagent_domain.AdmissionSnapshot,
        ) subagent_execution.ServiceError!agents.ChildRun {
            const alloc = app.alloc;
            const child_id = turn.child_id orelse return error.AdmissionFailed;
            const work_id = turn.active_work_id orelse return error.AdmissionFailed;
            const resolver = turn.live_authority orelse return error.AdmissionFailed;
            var base = try prepareChildRunBase(app, child_id, resolver, message.system_prompt_overlay, admission, turn);
            errdefer freeChildRunBase(alloc, &base);
            const owned_child_id = try alloc.dupe(u8, child_id);
            errdefer alloc.free(owned_child_id);
            const owned_work_id = try alloc.dupe(u8, work_id);
            errdefer alloc.free(owned_work_id);
            const intent = try alloc.dupe(u8, message.root_user_intent_context);
            errdefer alloc.free(intent);
            const messages = try alloc.alloc([]u8, message.root_user_messages.len);
            var copied: usize = 0;
            errdefer {
                for (messages[0..copied]) |value| alloc.free(value);
                alloc.free(messages);
            }
            for (message.root_user_messages) |value| {
                messages[copied] = try alloc.dupe(u8, value);
                copied += 1;
            }
            return .{
                .child_id = owned_child_id,
                .admission = base.admission,
                .authority_resolver = resolver,
                .system_prompt = base.system_prompt,
                .credential = base.credential,
                .root_user_intent_context = intent,
                .root_user_messages = messages,
                .root_user_evidence_complete = message.root_user_evidence_complete,
                .work_id = owned_work_id,
                .turn = turn,
            };
        }

        /// The run the turns the user starts on a subagent's own screen read:
        /// built as main's runs are, from `admission`, with the child's
        /// `instructions` as its overlay. It has no work id, since no request
        /// of main's started it. The caller owns the run.
        pub fn prepareOwnTurnRun(
            app: *App,
            child_id: []const u8,
            resolver: *subagent_authority.Resolver,
            instructions: []const u8,
            admission: subagent_domain.AdmissionSnapshot,
        ) subagent_execution.ServiceError!agents.ChildRun {
            var base = try prepareChildRunBase(app, child_id, resolver, instructions, admission, null);
            errdefer freeChildRunBase(app.alloc, &base);
            return .{
                .child_id = try app.alloc.dupe(u8, child_id),
                .admission = base.admission,
                .authority_resolver = resolver,
                .system_prompt = base.system_prompt,
                .credential = base.credential,
            };
        }

        fn appendClaimedContextNotice(agent: *AppAgent, writer: *std.Io.Writer, notice: []const u8) !void {
            const should_emit = if (comptime @hasDecl(@TypeOf(agent.session), "claimContextNotice"))
                try agent.session.claimContextNotice(std.heap.c_allocator, notice)
            else
                true;
            if (!should_emit) return;
            if (writer.buffered().len > 0 and !std.mem.endsWith(u8, writer.buffered(), "\n")) {
                try writer.writeByte('\n');
            }
            const body = try types.renderContextNoticeBody(std.heap.c_allocator, notice);
            defer std.heap.c_allocator.free(body);
            try writer.writeAll(body);
        }

        fn buildQueuedPromptConfig(
            app: *App,
            agent: *AppAgent,
            job: worker_runtime.QueuedPrompt,
            catalog: skill_invocation.Catalog,
            bindings: []const skill_invocation.ExplicitBinding,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            tool_projection: *const tool_projection_mod.EffectiveToolProjection,
            session_child_capability: ?*session_child_store.SessionChildCapability,
        ) agent_runtime.Config {
            const prompt_policy = app.promptPolicy(agent);
            const workspace = turnWorkspace(app);
            const child_run = childRun(agent);
            // Work the parent started runs as a subagent turn, as it does
            // without a child agent: the parent's steering is labeled as
            // its feedback, and the reviewer judges it against the root
            // user's requests.
            const parent_run: ?*agents.ChildRun = if (child_run) |run| (if (run.startedByParent()) run else null) else null;
            return .{
                .system_prompt = if (child_run) |run|
                    if (run.system_prompt.len > 0) run.system_prompt else prompt_policy.system_prompt
                else
                    prompt_policy.system_prompt,
                .exclusive_system_prompt = child_run == null and prompt_policy.exclusive,
                .model_prompt_overlay = prompt_policy.modelPromptOverlay(job.model),
                .skill_catalog = catalog,
                .skill_bindings = bindings,
                .gateway_retry_count = gateway_retry_count,
                .gateway_chat_url = gateway_chat_url,
                .advertised_tool_names = tool_projection.advertised_names,
                .advertised_functions = tool_projection.advertised_functions,
                .provider_capabilities = if (comptime @hasDecl(App, "providerSet"))
                    app.providerSet().select(job.provider).capabilities
                else
                    .{},
                .custom_tool_guidance = tool_projection.custom_guidance,
                .agent_step_limit = app.agent_step_limit,
                .max_tool_result_bytes = job.agent_settings.max_tool_result_bytes,
                .auto_compact_percent = job.agent_settings.auto_compact_percent,
                .cancel_flag = &agent.worker.worker_cancel_requested,
                .recovery_continue_flag = &agent.worker.recovery_continue_requested,
                .recovery_sign_in_closed_flag = &agent.worker.recovery_sign_in_closed,
                .review_enabled = false,
                .fast_mode = job.agent_settings.fast_mode,
                .ultrafast_mode = job.agent_settings.ultrafast_mode,
                .effort = job.agent_settings.effort,
                .first_call_tool_choice = job.agent_settings.first_call_tool_choice,
                .workspace_root = workspace.root,
                .access_scope = workspace.access_scope,
                .session_child_capability = session_child_capability,
                .context_limits = if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
                .origin = if (parent_run != null) .subagent else .root,
                .root_user_intent_context = if (parent_run) |run| run.root_user_intent_context else "",
                .root_user_messages = if (parent_run) |run| run.root_user_messages else &.{},
                .root_user_evidence_complete = if (parent_run) |run| run.root_user_evidence_complete else false,
                .subagent_id = if (parent_run) |run| run.subagent_id else 0,
            };
        }
    };
}

const ToolActionState = enum { active, completed, denied };

fn formatToolAction(
    ctx: tool_runtime.Context,
    arena: Allocator,
    call: ToolCall,
    display_target: ?[]const u8,
    state: ToolActionState,
    denied_label: ?[]const u8,
) ![]const u8 {
    if (std.mem.eql(u8, call.name, "web_search") or tool_presentation.isProviderSearchAlias(call.name)) {
        return formatWebSearchAction(arena, call, state, denied_label);
    }
    const spec = ctx.tool_registry.lookup(call.name) orelse {
        if (dynamicMcpActionLabel(state)) |label| {
            if (mcpToolAvailable(ctx, call.name)) {
                return formatToolActionValue(arena, label, call.name);
            }
        }
        return formatMissingSpecToolAction(arena, state, denied_label, call.name);
    };
    if (try tool_presentation.formatRunCommandActivity(arena, ctx.tool_registry, ctx.workspace_root, call)) |activity| {
        defer arena.free(activity.detail);
        const label = if (activity.compatibility_tool) |compatibility_tool|
            specLabel(compatibility_tool, state, denied_label)
        else switch (state) {
            .active => "Running",
            .completed => "Ran",
            .denied => denied_label.?,
        };
        return formatCommandActionValue(
            arena,
            label,
            activity.detail,
        );
    }
    if (std.mem.eql(u8, call.name, "write_file") or
        std.mem.eql(u8, call.name, "edit_file"))
    {
        return formatToolActionValue(
            arena,
            specLabel(spec, state, denied_label),
            display_target orelse try mutationPathFromArgs(arena, ctx.workspace_root, call) orelse spec.label_arg_default,
        );
    }
    // The subagents a call that concerns them all names reach its row as
    // the call's resolved target.
    var subagent_call = call;
    if (display_target) |target| subagent_call.resolved_display_target = target;
    if (try tool_presentation.subagentAction(arena, subagent_call, switch (state) {
        .active => .active,
        .completed => .completed,
        .denied => .{ .stopped = denied_label.? },
    })) |action| {
        defer action.deinit(arena);
        return formatToolActionValue(arena, action.label, action.detail);
    }
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch {
        return formatInvalidArgsToolAction(arena, state, denied_label);
    };

    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
    const value = display_target orelse
        call.resolved_display_target orelse
        tool_dispatch.presentationLabelValue(presentation, args) orelse
        presentation.label_arg_default;
    return formatToolActionValue(arena, presentationLabel(presentation, state, denied_label), value);
}

/// The path a write or edit call names, as its live row names it: relative
/// to the workspace when it is inside it, and terminal-safe. A live call
/// brings this as its display target; a saved call, as on resume, brings
/// only its arguments. Null when they name no path.
fn mutationPathFromArgs(arena: Allocator, workspace_root: []const u8, call: ToolCall) !?[]const u8 {
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch return null;
    const path = tool_args.optionalStringArg(args, "path") orelse return null;
    if (path.len == 0) return null;
    const shown = try permissions.displayTargetForPolicy(arena, workspace_root, path, .path_create_parent);
    return (try text_utils.encodeTerminalSafe(arena, shown, diff.max_encoded_label_bytes)).bytes;
}

fn formatWebSearchAction(arena: Allocator, call: ToolCall, state: ToolActionState, denied_label: ?[]const u8) ![]const u8 {
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch {
        return formatInvalidArgsToolAction(arena, state, denied_label);
    };
    const label = switch (state) {
        .active => "Searching",
        .completed => "Searched",
        .denied => denied_label.?,
    };
    return formatToolActionValue(arena, label, try tool_presentation.formatWebSearchActionDetail(arena, args));
}

fn formatMissingSpecToolAction(arena: Allocator, state: ToolActionState, denied_label: ?[]const u8, name: []const u8) ![]const u8 {
    return switch (state) {
        .active => formatToolActionValue(arena, "Working", name),
        .completed => formatToolActionValue(arena, "Completed", name),
        .denied => formatToolActionValue(arena, denied_label.?, name),
    };
}

fn formatInvalidArgsToolAction(arena: Allocator, state: ToolActionState, denied_label: ?[]const u8) ![]const u8 {
    return switch (state) {
        .active => arena.print("● Working…\x1b[0m", .{}),
        .completed => formatToolActionValue(arena, "Completed", "tool call"),
        .denied => formatToolActionValue(arena, denied_label.?, "tool call"),
    };
}

fn formatToolActionValue(arena: Allocator, label: []const u8, value: []const u8) ![]const u8 {
    return tool_presentation.formatToolActionValue(arena, label, value);
}

/// Command rows keep the muted tool-text base and add shell syntax colors for
/// quoted strings, numbers, comments, and keywords.
fn formatCommandActionValue(arena: Allocator, label: []const u8, command: []const u8) ![]const u8 {
    const theme = shared_theme.current();
    const profile = code_highlight_languages.resolve("sh") orelse
        return formatToolActionValue(arena, label, command);
    const highlighted = try code_highlight.highlight(
        arena,
        command,
        profile,
        if (theme.light) .light else .dark,
        theme.tool_stdout_style,
    );
    return arena.print("● {s}\x1b[0m {s}\x1b[0m", .{ label, highlighted });
}

fn specLabel(spec: *const tool_dispatch.Tool, state: ToolActionState, denied_label: ?[]const u8) []const u8 {
    return switch (state) {
        .active => spec.action_label,
        .completed => spec.completed_action_label,
        .denied => denied_label.?,
    };
}

fn presentationLabel(presentation: tool_dispatch.CallPresentation, state: ToolActionState, denied_label: ?[]const u8) []const u8 {
    return switch (state) {
        .active => presentation.action_label,
        .completed => presentation.completed_action_label,
        .denied => denied_label.?,
    };
}

fn dynamicMcpActionLabel(state: ToolActionState) ?[]const u8 {
    return switch (state) {
        .active => tool_presentation.mcp_running_label,
        .completed => tool_presentation.mcp_ran_label,
        .denied => null,
    };
}

fn mcpToolAvailable(ctx: tool_runtime.Context, name: []const u8) bool {
    var advertised = false;
    for (ctx.advertised_dynamic_tool_names) |advertised_name| {
        if (std.mem.eql(u8, advertised_name, name)) {
            advertised = true;
            break;
        }
    }
    if (!advertised) return false;
    const raw_ctx = ctx.mcp_ctx orelse return false;
    const has_tool = ctx.mcp_has_tool orelse return false;
    return has_tool(raw_ctx, name, ctx.mcp_access);
}

const test_ignored_list_entries = [_][]const u8{ ".git", "zig-out" };
const test_gateway_chat_url = "https://gateway.test/chat";
const test_tools = [_]tool_dispatch.Tool{
    test_builtin_tools.web_search,
    test_builtin_tools.shell,
    test_builtin_tools.grep_files,
    test_builtin_tools.install_skill,
    test_builtin_tools.subagent,
};
const test_tool_registry = tool_dispatch.Registry{ .tools = test_tools[0..] };
const custom_label_tool = tool_dispatch.Tool{
    .name = "custom_registered_tool",
    .description = "Custom registered test tool.",
    .model_schema = .{
        .name = "custom_registered_tool",
        .description = "Custom registered test tool.",
    },
    .action_label = "Custom running",
    .completed_action_label = "Custom ran",
    .label_arg_kind = .name,
    .label_arg_default = "custom fallback",
    .decode = test_builtin_tools.read_file.decode,
    .call = test_builtin_tools.read_file.call,
    .reads_only_fn = test_builtin_tools.read_file.reads_only_fn,
    .irreversible_fn = test_builtin_tools.read_file.irreversible_fn,
};
const custom_registry_tools = [_]tool_dispatch.Tool{custom_label_tool};
const custom_tool_registry = tool_dispatch.Registry{ .tools = custom_registry_tools[0..] };

fn gatherTestProjectContext(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    return .{};
}

fn appendTestStaticContext(input: context_contract.StaticContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
    const content = try alloc.print("provider static:{s}", .{input.project_context});
    try messages.append(alloc, .{ .role = .system, .content = content });
}

fn appendTestTransientContext(input: context_contract.TransientContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
    const content = try alloc.print(
        "provider transient:{s}:{s}",
        .{ input.workspace_root, @tagName(input.permission_mode) },
    );
    try messages.append(alloc, .{ .role = .system, .content = content });
}

const test_context_provider = context_contract.Provider{
    .id = "test.default_context",
    .gather_project_context_fn = gatherTestProjectContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendTestStaticContext,
    .append_transient_fn = appendTestTransientContext,
};
const test_context_registry = context_contract.Registry{ .default_provider = test_context_provider };
const test_prompt_policy = prompt_policy_contract.Policy{
    .system_prompt = "test system prompt",
    .model_prompt_overlay_fn = struct {
        fn overlay(model: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, model, "test-model")) "test model overlay" else null;
        }
    }.overlay,
};

var refresh_gather_calls: usize = 0;
var refresh_gather_error: context_contract.ProviderError = error.WriteFailed;

fn gatherFreshProjectContext(alloc: Allocator, input: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    refresh_gather_calls += 1;
    const content = try alloc.print("fresh:{s}", .{input.workspace_root});
    errdefer alloc.free(content);
    const notices = try alloc.alloc([]u8, 1);
    errdefer alloc.free(notices);
    notices[0] = try alloc.dupe(u8, "fresh context notice");
    return .{ .content = content, .notices = notices };
}

fn gatherFailingProjectContext(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    refresh_gather_calls += 1;
    return refresh_gather_error;
}

fn appendNoopStaticContext(_: context_contract.StaticContextInput, _: Allocator, _: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {}

fn appendNoopTransientContext(_: context_contract.TransientContextInput, _: Allocator, _: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {}

const fresh_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.fresh_context",
    .gather_project_context_fn = gatherFreshProjectContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendNoopStaticContext,
    .append_transient_fn = appendNoopTransientContext,
} };
const failing_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.failing_context",
    .gather_project_context_fn = gatherFailingProjectContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendNoopStaticContext,
    .append_transient_fn = appendNoopTransientContext,
} };

const RefreshContextApp = struct {
    alloc: Allocator,
    workspace_root: []const u8 = "/tmp/workspace",
    context_enabled: bool,
    main_agent: struct {
        context_snapshot: context_contract.GatheredContextSnapshot,
        session: session_runtime.SessionRuntime = .{ .max_history_turns = 8 },
    },
    context_registry: context_contract.Registry,
    context_notices: std.ArrayList(u8) = .empty,
    context_notice_tone: ?types.NoticeTone = null,
    context_notice_visibility: ?types.NoticeVisibility = null,
    host_info: ?js_host_workspace.Info = null,

    fn contextRegistry(self: *const RefreshContextApp) context_contract.Registry {
        return self.context_registry;
    }

    pub fn workspaceHostInfo(self: *const RefreshContextApp) ?*const js_host_workspace.Info {
        return if (self.host_info) |*info| info else null;
    }

    fn deinit(self: *RefreshContextApp) void {
        self.agent().context_snapshot.deinit(self.alloc);
        self.context_notices.deinit(self.alloc);
        self.agent().session.deinit(self.alloc);
    }

    pub fn writeDomainNotice(self: *RefreshContextApp, notice: types.SemanticNotice, _: bool) !void {
        self.context_notice_tone = notice.tone;
        self.context_notice_visibility = notice.visibility;
        try self.context_notices.appendSlice(self.alloc, notice.body);
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

fn makeTestContextSnapshot(alloc: Allocator, provider_id: []const u8, content: []const u8) !context_contract.GatheredContextSnapshot {
    const owned_provider_id = try alloc.dupe(u8, provider_id);
    errdefer alloc.free(owned_provider_id);
    return .{ .contribution = .{
        .provider_id = owned_provider_id,
        .content = try alloc.dupe(u8, content),
    } };
}

fn testToolContext(app: *FakeApp) tool_runtime.Context {
    return Runtime(FakeApp).toolContext(app, app.agent(), &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
}

const ProjectionBarrier = struct {
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),

    fn wait(self: *ProjectionBarrier) void {
        self.entered.store(true, .release);
        while (!self.release.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
    }
};

const FakeApp = struct {
    alloc: Allocator,
    agent_stream_provider: agent_stream_provider.Provider = agent_stream_provider.unavailable_provider,
    workspace_root: []const u8 = "/tmp/workspace",
    auth: auth_runtime.Runtime = .{},
    selected_model: std.ArrayList(u8) = .empty,
    selected_provider: model_provider.ProviderId = .none,
    agent_step_limit: usize = 8,
    fast_mode: bool = true,
    main_agent: struct {
        effort: types.ReasoningEffort = types.ReasoningEffort.literal("high"),
        context_snapshot: context_contract.GatheredContextSnapshot,
        change_tracker: change_tracker.ChangeTracker = .{},
        total_input_tokens: u64 = 0,
        total_output_tokens: u64 = 0,
        total_web_search_requests: u64 = 0,
        session: session_runtime.SessionRuntime = .{ .max_history_turns = 4 },
        session_persistence: app_session_runtime.Persistence = .{},
        worker: worker_runtime.WorkerRuntime = .{},
        child_run: ?agents.ChildRun = null,
    },
    skills_dir: []const u8 = "/tmp/skills",
    authority_mutex: std.Io.Mutex = .init,
    skills: skill_runtime.Runtime = .{},
    append_context_count: usize = 0,
    snapshot_tools_count: usize = 0,
    snapshot_permission_mode: ?PermissionMode = null,
    snapshot_barrier: ?*ProjectionBarrier = null,
    snapshot_tools_error: ?anyerror = null,
    snapshot_custom_guidance: []const u8 = "",
    mcp_name: []const u8 = "mcp_lookup",
    mcp_has_tool_calls: usize = 0,
    mcp_result: []const u8 = "{\"ok\":true}",
    diff_blocks: usize = 0,
    web_fetch_runtime: web_fetch_runtime.Runtime = web_fetch_runtime.Runtime.init(.{}),
    web_search_runtime: web_search_runtime.Runtime = web_search_runtime.Runtime.init(.{}),
    lifecycle_runtime: hooks.Runtime,
    lifecycle_view: hooks.RuntimeView,
    tool_registry: tool_dispatch.Registry = test_tool_registry,
    context_registry: context_contract.Registry = test_context_registry,

    fn init(alloc: Allocator) !FakeApp {
        var lifecycle_runtime = hooks.Runtime.init(alloc);
        const lifecycle_view = lifecycle_runtime.freeze();
        var app = FakeApp{
            .alloc = alloc,
            .lifecycle_runtime = lifecycle_runtime,
            .lifecycle_view = lifecycle_view,
            .main_agent = .{ .context_snapshot = try makeTestContextSnapshot(alloc, "test.default_context", "project context") },
        };
        errdefer app.agent().context_snapshot.deinit(alloc);
        const credential = credentials.Credential{
            .token = try alloc.dupe(u8, "api-key"),
            .source = .configured,
        };
        app.auth.adoptCredential(alloc, credential);
        errdefer app.auth.deinit(alloc);
        try app.selected_model.appendSlice(alloc, "test-model");
        return app;
    }

    pub fn toolRegistry(self: *const FakeApp, _: anytype) tool_dispatch.Registry {
        return self.tool_registry;
    }

    fn contextRegistry(self: *const FakeApp) context_contract.Registry {
        return self.context_registry;
    }

    pub fn mcpServerNames(_: *FakeApp, _: Allocator) ![]const []const u8 {
        return &.{};
    }

    fn promptPolicy(_: *const FakeApp, _: anytype) prompt_policy_contract.Policy {
        return test_prompt_policy;
    }

    pub fn agentStreamProvider(self: *const FakeApp) agent_stream_provider.Provider {
        return self.agent_stream_provider;
    }

    fn deinit(self: *FakeApp) void {
        self.auth.deinit(self.alloc);
        self.selected_model.deinit(self.alloc);
        self.agent().context_snapshot.deinit(self.alloc);
        self.agent().worker.deinit(std.heap.c_allocator);
        self.web_fetch_runtime.deinit(self.alloc);
        self.web_search_runtime.deinit();
        self.agent().session.deinit(self.alloc);
        self.agent().change_tracker.deinit(self.alloc);
        self.lifecycle_runtime.deinit();
    }

    fn hasMcpTool(self: *FakeApp, name: []const u8, _: tool_mcp_runtime.Access) bool {
        self.mcp_has_tool_calls += 1;
        return std.mem.eql(u8, name, self.mcp_name);
    }

    fn callMcpTool(self: *FakeApp, arena: Allocator, name: []const u8, arguments_json: []const u8, _: usize, _: tool_mcp_runtime.CallOptions) !?tool_mcp_runtime.CallResult {
        _ = arguments_json;
        if (!self.hasMcpTool(name, .unrestricted)) return null;
        return .{ .model_output = try arena.dupe(u8, self.mcp_result) };
    }

    fn subagentToolContextForAdmission(
        self: *FakeApp,
        _: anytype,
        admission: subagent_domain.AdmissionSnapshot,
    ) tool_runtime.Context {
        return Runtime(FakeApp).toolContextForSubagent(
            self,
            self.agent(),
            &test_ignored_list_entries,
            100,
            1024,
            40,
            120,
            2048,
            2,
            test_gateway_chat_url,
            admission,
        );
    }

    fn snapshotModelToolProjection(
        self: *FakeApp,
        _: anytype,
        alloc: Allocator,
        permission_mode: PermissionMode,
    ) !tool_projection_mod.EffectiveToolProjection {
        self.snapshot_tools_count += 1;
        self.snapshot_permission_mode = permission_mode;
        if (self.snapshot_barrier) |barrier| barrier.wait();
        if (self.snapshot_tools_error) |err| return err;
        const advertised_names = try alloc.alloc([]const u8, 0);
        errdefer alloc.free(advertised_names);
        const advertised_functions = try alloc.alloc(model_tool_schema.FunctionSchema, 0);
        errdefer alloc.free(advertised_functions);
        return .{
            .advertised_names = advertised_names,
            .advertised_functions = advertised_functions,
            .custom_guidance = try alloc.dupe(u8, self.snapshot_custom_guidance),
        };
    }

    pub fn snapshotSubagentModelToolProjection(
        self: *FakeApp,
        _: anytype,
        alloc: Allocator,
        permission_mode: PermissionMode,
    ) !tool_projection_mod.EffectiveToolProjection {
        self.snapshot_tools_count += 1;
        self.snapshot_permission_mode = permission_mode;
        if (self.snapshot_barrier) |barrier| barrier.wait();
        if (self.snapshot_tools_error) |err| return err;
        const advertised_names = try alloc.alloc([]const u8, 0);
        errdefer alloc.free(advertised_names);
        const advertised_functions = try alloc.alloc(model_tool_schema.FunctionSchema, 0);
        errdefer alloc.free(advertised_functions);
        return .{
            .advertised_names = advertised_names,
            .advertised_functions = advertised_functions,
            .custom_guidance = try alloc.dupe(u8, self.snapshot_custom_guidance),
        };
    }

    pub fn appendRuntimeContextMessage(self: *FakeApp, _: anytype, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
        self.append_context_count += 1;
        try Runtime(FakeApp).appendTransientRuntimeContextMessage(self, self.agent(), arena, messages, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn requestToolPermissionSyncWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, live_authority: ?agent_runtime.LiveToolAuthority, revalidation: ?command_admission.ToolExecutionAuthority, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
        return Runtime(FakeApp).requestToolPermissionSync(self, self.agent(), arena, call, live_authority, revalidation, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn requestPreparedFileMutationPermissionSyncWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, live_authority: ?agent_runtime.LiveToolAuthority, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
        return Runtime(FakeApp).requestPreparedFileMutationPermissionSync(self, self.agent(), arena, call, prepared, live_authority, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn validateToolCall(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
        return Runtime(FakeApp).validateToolCall(self, self.agent(), arena, call, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn checkToolAvailability(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall) !?[]const u8 {
        return Runtime(FakeApp).checkToolAvailability(self, self.agent(), arena, call, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolAction(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall) ![]const u8 {
        return Runtime(FakeApp).describeToolAction(self, self.agent(), arena, call, null, &.{}, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return Runtime(FakeApp).describeToolAction(self, self.agent(), arena, call, display_target, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionCompleted(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall) ![]const u8 {
        return Runtime(FakeApp).describeToolActionCompleted(self, self.agent(), arena, call, null, &.{}, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionCompletedWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return Runtime(FakeApp).describeToolActionCompleted(self, self.agent(), arena, call, display_target, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionDenied(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, label: []const u8) ![]const u8 {
        return Runtime(FakeApp).describeToolActionDenied(self, self.agent(), arena, call, null, label, &.{}, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionDeniedWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return Runtime(FakeApp).describeToolActionDenied(self, self.agent(), arena, call, display_target, label, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn permissionTargetForCall(self: *FakeApp, arena: Allocator, call: ToolCall) ![]const u8 {
        return Runtime(FakeApp).permissionTargetForCall(self, self.agent(), arena, call, &.{}, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn permissionTargetForCallWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return Runtime(FakeApp).permissionTargetForCall(self, self.agent(), arena, call, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn executeToolCall(self: *FakeApp, _: anytype, request: agent_runtime.ToolExecutionRequest) !agent_runtime.ToolExecutionResult {
        return Runtime(FakeApp).executeToolCall(self, self.agent(), request, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn executeToolCallWithAdvertised(self: *FakeApp, _: anytype, request: agent_runtime.ToolExecutionRequest) !agent_runtime.ToolExecutionResult {
        return self.executeToolCall(&self.main_agent, request);
    }

    pub fn registerAndEmitDiffBlock(self: *FakeApp, payload: agent_runtime.DiffEntryPayload) !void {
        _ = payload;
        self.diff_blocks += 1;
    }

    pub fn formatToolExecutionErrorForAgent(self: *FakeApp, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
        _ = self;
        return arena.print("Tool {s} failed: {s}", .{ tool_name, @errorName(err) });
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

fn testAgentStreamProvider(stream_fn: agent_stream_provider.StreamFn) agent_stream_provider.Provider {
    return .{ .stream_fn = stream_fn };
}

const TestCatalogProvider = struct {
    saw_expected_input: bool = false,

    fn appendEntry(
        alloc: Allocator,
        catalog: *std.ArrayList(model_catalog.ModelCatalogEntry),
        id_text: []const u8,
    ) !void {
        const id = try alloc.dupe(u8, id_text);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try catalog.append(alloc, .{ .id = id, .model_type = model_type });
    }

    fn fetch(
        raw_context: ?*anyopaque,
        alloc: Allocator,
        input: model_catalog.FetchInput,
    ) Allocator.Error!model_catalog.ProviderResult {
        const self: *TestCatalogProvider = @ptrCast(@alignCast(raw_context.?));
        self.saw_expected_input =
            input.access == .public_only and
            std.mem.eql(u8, input.endpoint, "/catalog") and
            input.cancel_flag == null and
            input.view == .full;

        var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
        errdefer model_catalog.freeModelCatalog(alloc, &catalog);
        try appendEntry(alloc, &catalog, "provider/first");
        try appendEntry(alloc, &catalog, "provider/second");
        return .{ .catalog = catalog };
    }
};

test "app model id loading uses the injected catalog provider" {
    const alloc = std.testing.allocator;
    var app = try FakeApp.init(alloc);
    defer app.deinit();
    var test_provider = TestCatalogProvider{};

    var ids = try Runtime(FakeApp).fetchModelIds(
        &app,
        .{
            .context = @ptrCast(&test_provider),
            .fetch_fn = TestCatalogProvider.fetch,
        },
        "/catalog",
    );
    defer {
        for (ids.items) |id| alloc.free(id);
        ids.deinit(alloc);
    }

    try std.testing.expect(test_provider.saw_expected_input);
    try std.testing.expectEqual(@as(usize, 2), ids.items.len);
    try std.testing.expectEqualStrings("provider/first", ids.items[0]);
    try std.testing.expectEqualStrings("provider/second", ids.items[1]);
}

const TestHostWorkspace = struct {
    pub fn workspaceAvailable() i32 {
        return 1;
    }

    pub fn workspaceInfo(out_ptr: [*]u8, out_cap: usize) i32 {
        const json = "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"allow-sandboxed\"}";
        if (json.len > out_cap) return -3;
        @memcpy(out_ptr[0..json.len], json);
        return json.len;
    }
};

fn makeQueuedPrompt(alloc: Allocator) !worker_runtime.QueuedPrompt {
    return .{
        .prompt = try alloc.dupe(u8, "draft an issue"),
        .images = &.{},
        .model = try alloc.dupe(u8, "test-model"),
        .api_key = try alloc.dupe(u8, "api-key"),
        .permission_mode = .yolo,
        .history = try alloc.alloc(types.HistoryTurn, 0),
    };
}
