const std = @import("std");
const agents = @import("../agents/agents.zig");
const app_agents_runtime = @import("app_agents_runtime.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const agent_runtime = @import("../agent/agent_runtime.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const command_admission = @import("../permissions/command_admission.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const secret = @import("../auth/secret.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const input_completion_runtime = @import("input_completion_runtime.zig");
const composer_stash = @import("../input/composer_stash.zig");
const provider_runtime = @import("provider_runtime.zig");
const core_input_runtime = @import("../input/runtime.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const turn_capture = @import("../workspace/turn_capture.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const change_tracker_mod = @import("../workspace/change_tracker.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation = @import("../tooling/file_mutation.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const tool_admission = @import("../tooling/tool_admission.zig");
const tool_presentation = @import("../tooling/tool_presentation.zig");
const gateway_error_format = @import("../shared/gateway_error_format.zig");
const execution_memory = @import("../agent/execution_memory.zig");
const io_mod = @import("../shared/io.zig");
const session_runtime = @import("../session/session.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const subagent_model_contract = @import("../subagent/model_contract.zig");
const result_store = @import("../session/result_store.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const assistant_presentation = @import("../agent/assistant_presentation.zig");
const activity_runtime = @import("../output/activity_runtime.zig");
const compaction_activity = @import("../output/compaction_activity.zig");
const activity_status = @import("../output/activity_status.zig");
const assistant_pacer = @import("../../ui/assistant/pacer.zig");
const ui_render = @import("../../ui/render.zig");
const render_request = @import("../../ui/render_request.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;
const PermissionMode = types.PermissionMode;
const ToolCall = types.ToolCall;
const ToolExecutionResult = agent_runtime.ToolExecutionResult;
const WorkerEvent = worker_runtime.WorkerEvent;

const reset_style = ui_render.reset_style;

fn preparedDiffPayload(
    alloc: Allocator,
    handoff: file_mutation.CommittedFileHandoff,
) !diff_mod.DiffEntryPayload {
    return preparedDiffPayloadWithFullAllocator(alloc, alloc, handoff);
}

fn preparedDiffPayloadWithFullAllocator(
    alloc: Allocator,
    full_alloc: Allocator,
    handoff: file_mutation.CommittedFileHandoff,
) !diff_mod.DiffEntryPayload {
    return diff_mod.formatFileChangePayload(
        alloc,
        full_alloc,
        handoff.preview,
        handoff.tracker.previous_content,
        if (handoff.full_view) |snapshot| .{
            .after_content = snapshot.after_content,
            .lifecycle_id = snapshot.lifecycle_id,
        } else null,
        .{
            .added_fg = ui_render.diff_added_style,
            .removed_fg = ui_render.diff_removed_style,
            .context_fg = ui_render.dim_style,
            .added_marker_fg = ui_render.diff_added_marker_style,
            .removed_marker_fg = ui_render.diff_removed_marker_style,
            .reset = ui_render.reset_style,
        },
    );
}

test "prepared preview formatter preserves context and informative elision" {
    const preview: diff_mod.FileChangePreview = .{
        .path = "note.txt",
        .lines = &.{
            .{
                .op = .context,
                .old_line = 1,
                .new_line = 1,
                .text = "alpha",
            },
            .{
                .op = .deletion,
                .old_line = 2,
                .text = "before",
            },
            .{
                .op = .addition,
                .new_line = 2,
                .text = "after",
            },
            .{
                .op = .elision,
                .text = "⋯ +2 -1 omitted",
            },
        },
        .additions = 3,
        .deletions = 2,
        .truncated = true,
    };
    const formatted = try diff_mod.formatFileChangePreview(
        std.testing.allocator,
        preview,
        .{
            .added_fg = "",
            .removed_fg = "",
            .context_fg = "",
            .reset = "",
        },
    );
    defer std.testing.allocator.free(formatted);

    try std.testing.expect(std.mem.find(u8, formatted, "alpha") != null);
    try std.testing.expect(
        std.mem.find(u8, formatted, "⋯ +2 -1 omitted") != null,
    );
}

pub fn Bindings(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        fn appOf(agent: *AppAgent) *App {
            return app_agents_runtime.appOf(App, agent);
        }

        pub fn finishPromptPresentation(app: *App, agent: *AppAgent, finished: types.FinishedPrompt) !assistant_pacer.FinishResult {
            try app_session_runtime.Runtime(App).appendFinishedPrompt(app, agent, finished);
            if (finished.summary) |summary| {
                _ = app.shell.appendTurnSummaryEntry(app.alloc, summary) catch |err| {
                    return .{ .presentation_failed = err };
                };
            }
            return .committed;
        }

        pub fn agentRuntimeDeps(app: *App, agent: *AppAgent) agent_runtime.AgentRuntimeDeps {
            var deps: agent_runtime.AgentRuntimeDeps = .{
                .ctx = @ptrCast(agent),
                .agent_stream_provider = if (comptime @hasDecl(App, "agentStreamProvider"))
                    app.agentStreamProvider()
                else
                    agent_stream_provider.unavailable_provider,
                .cooperative_transport_pulse = if (comptime @hasDecl(App, "cooperativeTransportPulse")) .{
                    .ctx = @ptrCast(agent),
                    .run = cooperativeTransportPulse,
                } else null,
                .tool_registry = if (comptime @hasDecl(App, "toolRegistry")) app.toolRegistry(agent) else .{},
                .context_registry = if (comptime @hasDecl(App, "contextRegistry")) app.contextRegistry() else null,
                .context_enabled = if (comptime @hasField(App, "context_enabled")) app.context_enabled else false,
                .image_folder_rules = comptime agents.hasAgentField(App, "pending_images"),
                .snapshot_root_permission_mode = if (comptime @hasField(App, "authority_mutex"))
                    agentSnapshotRootPermissionMode
                else
                    null,
                .finalize_turn = agentFinalizeTurn,
                .take_steering_boundary = if (comptime @hasDecl(@TypeOf(agent.worker), "takeSteeringBoundary")) agentTakeSteeringBoundary else null,
                .append_runtime_context = agentAppendRuntimeContext,
                .append_static_context = agentAppendStaticContext,
                .validate_tool_call = agentValidateToolCall,
                .snapshot_mcp_definition = agentSnapshotMcpDefinition,
                .resolve_unselected_mcp_tool = if (comptime @hasDecl(App, "resolveUnselectedMcpTool")) agentResolveUnselectedMcpTool else null,
                .check_tool_availability = agentCheckToolAvailability,
                .request_tool_permission = agentRequestToolPermission,
                .request_prepared_file_mutation_permission = agentRequestPreparedFileMutationPermission,
                .resolve_tool_action_display_target = if (comptime @hasDecl(App, "resolveToolActionDisplayTarget"))
                    agentResolveToolActionDisplayTarget
                else
                    null,
                .describe_tool_action = agentDescribeToolAction,
                .describe_tool_action_completed = agentDescribeToolActionCompleted,
                .describe_tool_action_denied = agentDescribeToolActionDenied,
                .subagent_status_renderer = subagentStatusRenderer(agent),
                .permission_target_for_call = agentPermissionTargetForCall,
                .execute_tool_call = agentExecuteToolCall,
                .publish_committed_file_handoff = agentPublishCommittedFileHandoff,
                .propagate_history_turn = agentPropagateHistoryTurn,
                .commit_context_compaction = .{ .commit = agentCommitContextCompaction },
                .compaction_activity = if (comptime @hasDecl(@TypeOf(agent.worker), "beginCompactionActivity")) .{
                    .begin = beginCompactionActivity,
                    .running = runCompactionActivity,
                    .settle = settleCompactionActivity,
                    .written = if (comptime @hasDecl(@TypeOf(agent.worker), "writtenCompactionActivity")) writtenCompactionActivity else null,
                } else null,
                .append_turn_piece = if (comptime agents.hasAgentField(App, "session_persistence"))
                    if (agent.session_persistence.v2 != null) agentAppendTurnPiece else null
                else
                    null,
                .record_usage = if (comptime agents.hasAgentField(App, "session_persistence"))
                    if (agent.session_persistence.v2 != null) agentRecordUsage else null
                else
                    null,
                .save_prompt_images = if (comptime agents.hasAgentField(App, "session_persistence"))
                    if (agent.session_persistence.v2 != null) agentSavePromptImages else null
                else
                    null,
                .start_workspace_capture = if (comptime agents.hasAgentField(App, "session_persistence") and turn_capture.supported)
                    if (agent.session_persistence.v2 != null and agent.session_persistence.workspace_capture) agentStartWorkspaceCapture else null
                else
                    null,
                .reach_workspace = if (comptime agents.hasAgentField(App, "session_persistence") and turn_capture.supported)
                    if (agent.session_persistence.v2 != null and agent.session_persistence.workspace_capture) agentReachWorkspace else null
                else
                    null,
                .save_recovery_record = if (comptime agents.hasAgentField(App, "session_persistence"))
                    if (agent.session_persistence.v2 != null) agentSaveRecoveryRecord else null
                else
                    null,
                .push_event = agentPushEvent,
                .push_text = agentPushText,
                .push_reasoning_delta = agentPushReasoningDelta,
                .push_tool_lifecycle = agentPushToolLifecycle,
                .push_diff_block = agentPushDiffBlock,
                .push_system_notice = agentPushSystemNotice,
                .push_interactive_notice = agentPushInteractiveNotice,
                .push_context_notice = agentPushContextNotice,
                .push_session_notice = agentPushSessionNotice,
                .push_route_recovery_status = agentPushRouteRecoveryStatus,
                .restore_failed_prompt = agentRestoreFailedPrompt,
                .push_command_output_complete = agentPushCommandOutputComplete,
                .push_http_error = agentPushHttpError,
                .ask_out_of_credits = if (comptime @hasDecl(@TypeOf(agent.worker), "requestRouteRecoveryAnswerBlocking"))
                    agentAskOutOfCredits
                else
                    null,
                .available_model_capabilities = agentAvailableModelCapabilities,
                .resolve_model_capabilities = agentResolveModelCapabilities,
                .model_catalog_failure = agentModelCatalogFailure,
                .format_tool_execution_error = agentFormatToolExecutionError,
                .record_tool_call_rejected = agentRecordToolCallRejected,
                .record_tool_call_failed = agentRecordToolCallFailed,
                .report_usage = agentReportUsage,
                .report_inner_tool_usage = agentReportInnerToolUsage,
                .diff_marker_styles = .{
                    .added = ui_render.diff_added_marker_style,
                    .removed = ui_render.diff_removed_marker_style,
                },
            };
            if (comptime @hasDecl(App, "releaseAgentTerminalLease")) {
                deps.release_agent_terminal_lease = agentReleaseTerminalLease;
            }
            if (comptime @hasDecl(App, "stopSteeringDetachedCommands")) {
                deps.turn_ends_by_explicit_cancel = agentTurnEndsByExplicitCancel;
                deps.stop_steering_detached_commands = agentStopSteeringDetachedCommands;
            }
            return deps;
        }

        fn agentReleaseTerminalLease(ctx: *anyopaque, session_id: []const u8) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            return app.releaseAgentTerminalLease(agent, session_id);
        }

        /// Main's and each subagent's turns end here. Only an explicit
        /// cancel stops what steering detached; a turn steering ended keeps
        /// its commands.
        fn agentTurnEndsByExplicitCancel(ctx: *anyopaque, turn_id: u64) bool {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            return agent.worker.turnEndsByExplicitCancel(turn_id);
        }

        fn agentStopSteeringDetachedCommands(ctx: *anyopaque, turn_id: u64) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            return appOf(agent).stopSteeringDetachedCommands(agent, turn_id);
        }

        /// Resolves models for `agent`, under its own turn settings.
        pub fn modelCapabilityResolver(agent: *AppAgent) model_capabilities.Resolver {
            return .{
                .ctx = @ptrCast(agent),
                .resolve_fn = agentResolveModelCapabilities,
            };
        }

        /// Resolves a subagent's model override for the agent starting it.
        pub fn modelOverrideResolver(agent: *AppAgent) subagent_tool_host.ModelOverrideResolver {
            return .{
                .context = @ptrCast(agent),
                .resolve_fn = resolveSubagentModelOverride,
            };
        }

        pub fn semanticPresentationSink(agent: *AppAgent) agent_runtime.SemanticPresentationSink {
            return .{
                .ctx = @ptrCast(agent),
                .table = agentPushTable,
                .code_block = agentPushCodeBlock,
                .thematic_rule = agentPushThematicRule,
            };
        }

        pub fn workerEventHandlers(agent: *AppAgent) app_worker_runtime.WorkerEventHandlers {
            return .{
                .ctx = @ptrCast(agent),
                .tool_lifecycle = worker_tool_lifecycle_presenter(agent),
                .write_user_prompt = workerBridgeWriteUserPrompt,
                .write_user_prompt_with_skill_bindings = workerBridgeWriteUserPromptWithSkillBindings,
                .append_text = workerBridgeAppendText,
                .append_table = workerBridgeAppendTable,
                .append_code_block = workerBridgeAppendCodeBlock,
                .append_thematic_rule = workerBridgeAppendThematicRule,
                .drain_assistant_text = workerBridgeDrainAssistantText,
                .hold_model_call = workerBridgeHoldModelCall,
                .open_model_picker = workerBridgeOpenModelPicker,
                .semantic_notice = workerBridgeSemanticNotice,
                .command_output = workerBridgeCommandOutput,
                .command_output_complete = workerBridgeCommandOutputComplete,
                .diff_block = workerBridgeDiffBlock,
                .context_compaction = workerBridgeContextCompaction,
                .append_history_turn = workerBridgeAppendHistoryTurn,
                .error_text = workerBridgeErrorText,
            };
        }

        pub fn worker_tool_lifecycle_presenter(
            agent: *AppAgent,
        ) activity_runtime.LifecyclePresenter {
            return .{
                .ctx = @ptrCast(agent),
                .snapshot_fn = worker_tool_lifecycle_snapshot,
                .record_fn = worker_tool_lifecycle_record,
                .apply_fn = worker_apply_tool_lifecycle,
                .finish_batch_fn = worker_finish_tool_lifecycle_batch,
            };
        }

        fn worker_tool_lifecycle_snapshot(
            raw_ctx: *anyopaque,
        ) activity_runtime.LifecycleSnapshot {
            const agent: *AppAgent = @ptrCast(@alignCast(raw_ctx));
            const app = appOf(agent);
            return .{
                .finalized_turn_watermark = app.shell.finalizedToolTurnWatermark(),
                .active_tool_count = app.shell.activeToolActivityCount(),
                .focused_entry_id = app.shell.focusedToolEntryId(),
                .focused_activity_kind = app.shell.focusedToolActivityKind(),
                .activity = app.shell.activityProjection(),
            };
        }

        fn worker_tool_lifecycle_record(
            raw_ctx: *anyopaque,
            id: types.ToolLifecycleId,
        ) ?activity_runtime.ToolPresentationRecord {
            const agent: *AppAgent = @ptrCast(@alignCast(raw_ctx));
            const app = appOf(agent);
            return app.shell.toolActivityRecord(id);
        }

        fn worker_apply_tool_lifecycle(
            raw_ctx: *anyopaque,
            alloc: std.mem.Allocator,
            event: types.ToolLifecycleEvent,
        ) !activity_runtime.LifecycleTransition {
            const agent: *AppAgent = @ptrCast(@alignCast(raw_ctx));
            const app = appOf(agent);
            const previous_focused_entry_id = app.shell.focusedToolEntryId();
            const preserve_normal_buffer_anchor = if (comptime @hasField(App, "terminal"))
                app.terminal.alternate_screen_owner != .none
            else
                false;
            const applied_activity_kind = if (preserve_normal_buffer_anchor)
                try app.shell.applyToolLifecyclePreservingNormalBufferAnchor(alloc, event)
            else
                try app.shell.applyToolLifecycle(alloc, event);
            if (comptime @hasField(App, "workspace_root")) switch (event) {
                .authoritative_started => |started| if (started.arguments_json) |arguments_json| {
                    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch |err| {
                        debug_trace.logf(
                            "ui_activity",
                            "command metadata parse failed turn_id={d} err={s}",
                            .{ started.id.turn_id, @errorName(err) },
                        );
                        return .{
                            .previous_focused_entry_id = previous_focused_entry_id,
                            .snapshot = worker_tool_lifecycle_snapshot(raw_ctx),
                            .applied_activity_kind = applied_activity_kind,
                            .terminal_record = null,
                        };
                    };
                    defer parsed.deinit();
                    if (parsed.value == .object) {
                        if (parsed.value.object.get("command")) |command_value| {
                            if (command_value == .string) {
                                const workspace_root = if (comptime @hasDecl(App, "workspaceHostInfo"))
                                    if (app.workspaceHostInfo()) |info| info.root() else app.workspace_root
                                else
                                    app.workspace_root;
                                const display = tool_presentation.formatRunCommandDetailBounded(
                                    alloc,
                                    command_value.string,
                                    workspace_root,
                                    tool_presentation.max_run_command_reflow_bytes,
                                ) catch |err| blk: {
                                    debug_trace.logf(
                                        "ui_activity",
                                        "command display unavailable turn_id={d} err={s}",
                                        .{ started.id.turn_id, @errorName(err) },
                                    );
                                    break :blk null;
                                };
                                defer if (display) |bytes| alloc.free(bytes);
                                if (display == null) debug_trace.logf(
                                    "ui_activity",
                                    "command display withheld turn_id={d}",
                                    .{started.id.turn_id},
                                );
                                const action_label = tool_presentation.runCommandCompletedActionLabel(
                                    alloc,
                                    app.toolRegistry(agent),
                                    .{
                                        .id = started.id.call_id,
                                        .name = started.tool_name,
                                        .arguments_json = arguments_json,
                                    },
                                ) catch |err| blk: {
                                    debug_trace.logf(
                                        "ui_activity",
                                        "command action label unavailable turn_id={d} err={s}",
                                        .{ started.id.turn_id, @errorName(err) },
                                    );
                                    break :blk null;
                                };
                                if (action_label == null) debug_trace.logf(
                                    "ui_activity",
                                    "command action label withheld turn_id={d}",
                                    .{started.id.turn_id},
                                );
                                if (display != null and action_label != null) {
                                    app.shell.setToolCommandMetadata(
                                        alloc,
                                        started.id,
                                        display.?,
                                        action_label.?,
                                    ) catch |err| debug_trace.logf(
                                        "ui_activity",
                                        "command metadata unavailable turn_id={d} err={s}",
                                        .{ started.id.turn_id, @errorName(err) },
                                    );
                                }
                            }
                        } else if (comptime @hasField(App, "terminal_client") and agents.hasAgentField(App, "managed_executions")) {
                            // Terminal-session actions (interact, stop) carry no
                            // command argument; their status line shows the launch
                            // command resolved from the session registry, truncated
                            // to the compact activity bound. Store the reflow-bound
                            // display so group projection can reclip the phrase to
                            // the live terminal width like any other command.
                            if (app.toolRegistry(agent).lookup(started.tool_name)) |spec| {
                                if (spec.executor_kind == .terminal) {
                                    const workspace_root = if (comptime @hasDecl(App, "workspaceHostInfo"))
                                        if (app.workspaceHostInfo()) |info| info.root() else app.workspace_root
                                    else
                                        app.workspace_root;
                                    const session_call: ToolCall = .{
                                        .id = started.id.call_id,
                                        .name = started.tool_name,
                                        .arguments_json = arguments_json,
                                    };
                                    const session_display = tool_presentation.resolveTerminalDisplayTargetBounded(
                                        alloc,
                                        app.toolRegistry(agent),
                                        workspace_root,
                                        &app.terminal_client,
                                        &agent.managed_executions,
                                        session_call,
                                        tool_presentation.max_run_command_reflow_bytes,
                                    ) catch |err| blk: {
                                        debug_trace.logf(
                                            "ui_activity",
                                            "session command display unavailable turn_id={d} err={s}",
                                            .{ started.id.turn_id, @errorName(err) },
                                        );
                                        break :blk null;
                                    };
                                    defer if (session_display) |bytes| alloc.free(bytes);
                                    const session_label = tool_presentation.terminalSessionCompletedActionLabel(
                                        alloc,
                                        app.toolRegistry(agent),
                                        session_call,
                                    ) catch |err| blk: {
                                        debug_trace.logf(
                                            "ui_activity",
                                            "session command action label unavailable turn_id={d} err={s}",
                                            .{ started.id.turn_id, @errorName(err) },
                                        );
                                        break :blk null;
                                    };
                                    if (session_display != null and session_label != null) {
                                        app.shell.setToolCommandMetadata(
                                            alloc,
                                            started.id,
                                            session_display.?,
                                            session_label.?,
                                        ) catch |err| debug_trace.logf(
                                            "ui_activity",
                                            "command metadata unavailable turn_id={d} err={s}",
                                            .{ started.id.turn_id, @errorName(err) },
                                        );
                                    }
                                }
                            }
                        }
                    }
                },
                else => {},
            };
            return .{
                .previous_focused_entry_id = previous_focused_entry_id,
                .snapshot = worker_tool_lifecycle_snapshot(raw_ctx),
                .applied_activity_kind = applied_activity_kind,
                .terminal_record = switch (event) {
                    .terminal => |terminal| app.shell.toolActivityRecord(terminal.id),
                    .provisional, .authoritative_started, .progress, .turn_finished => null,
                },
            };
        }

        fn worker_finish_tool_lifecycle_batch(
            raw_ctx: *anyopaque,
            alloc: std.mem.Allocator,
        ) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(raw_ctx));
            const app = appOf(agent);
            try app.shell.finishLifecycleBatch(alloc);
        }

        pub fn onCommandOutputChunk(ctx: *anyopaque, lifecycle_id: ?types.ToolLifecycleId, stream: command_output_content.Stream, chunk: []const u8) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            if (agent.worker.worker_cancel_requested.load(.seq_cst)) return;
            try app_worker_runtime.Runtime(App).pushCommandOutput(app, agent, lifecycle_id, stream, chunk);
        }

        pub fn onMcpProgress(ctx: *anyopaque, lifecycle_id: types.ToolLifecycleId, text: []const u8) void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            var label_buf: [512]u8 = undefined;
            const label = std.mem.print(
                &label_buf,
                "{s}● {s}{s}",
                .{ ui_render.bold_style, text, reset_style },
            ) catch ui_render.bold_style ++ "● MCP progress" ++ reset_style;
            app_worker_runtime.Runtime(App).pushToolLifecycle(app, agent, .{ .progress = .{
                .id = lifecycle_id,
                .text = label,
            } }) catch |err| {
                debug_trace.logf("mcp", "failed to publish MCP tool progress err={s}", .{@errorName(err)});
                return;
            };
            debug_trace.logf("mcp", "queued MCP tool progress turn_id={d}", .{lifecycle_id.turn_id});
        }

        pub fn onToolProgress(ctx: *anyopaque, lifecycle_id: types.ToolLifecycleId, text: []const u8) void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            app_worker_runtime.Runtime(App).pushToolLifecycle(app, agent, .{ .progress = .{
                .id = lifecycle_id,
                .text = text,
            } }) catch |err| {
                debug_trace.logf("subagent", "failed to publish subagent progress err={s}", .{@errorName(err)});
            };
        }

        /// Shows a row a running tool call adds for a call of its own
        /// (`tool_runtime` `nested_tool_lifecycle`).
        pub fn pushNestedToolLifecycle(ctx: *anyopaque, event: types.ToolLifecycleEvent) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).pushToolLifecycle(appOf(agent), agent, event);
        }

        /// Keeps the row of a call made through `spark mcp call` in the
        /// agent's session, so a resume shows it again
        /// (`tool_runtime.ToolLifecyclePublisher`).
        pub fn saveNestedBridgeCall(ctx: *anyopaque, record: types.BridgeCallRecord) !void {
            if (comptime !agents.hasAgentField(App, "session_persistence")) return;
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            try app_session_runtime.Runtime(App).saveBridgeCall(agent, record);
        }

        fn renderSubagentStatusLine(ctx: *anyopaque, buf: []u8, status: types.SubagentStatus) []const u8 {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            const show_context = if (comptime @hasField(App, "statusline_context")) app.statusline_context else false;
            const show_session = if (comptime @hasField(App, "statusline_session")) app.statusline_session else false;
            var items: ui_render.StatuslineItems = .{
                .context_used = if (show_context) status.input_tokens else 0,
                .context_total = if (show_context) status.context_window else null,
                .session_title = if (show_session) status.session_title else null,
            };
            if (comptime @hasField(App, "workspace_identity")) {
                if (app.workspace_identity.enabled) {
                    const identity = app.workspace_identity.snapshot();
                    items.workspace_label = identity.workspace_label;
                    items.git_branch = identity.git_branch;
                }
            }
            // Under the provider of the agent whose subagent this is.
            const caps = if (comptime @hasDecl(App, "resolvedModelCapabilitiesOf"))
                app.resolvedModelCapabilitiesOf(agent, status.model)
            else
                model_capabilities.resolveForApp(App, app, status.model);
            return ui_render.buildSessionStatusLine(
                status.model,
                status.effort,
                caps.supports_reasoning,
                items,
                ui_render.subagent_status_width,
                buf,
            );
        }

        /// Renders a subagent's status line for the agent whose subagent it is.
        pub fn subagentStatusRenderer(agent: *AppAgent) types.SubagentStatusRenderer {
            return .{ .ctx = agent, .render_fn = renderSubagentStatusLine };
        }

        pub fn onWebSearchProgress(ctx: *anyopaque, call_id: []const u8, progress: types.WebSearchProgress) void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            app_worker_runtime.Runtime(App).pushWebSearchProgress(app, agent, call_id, progress) catch {};
        }

        pub fn onWebFetchProgress(ctx: *anyopaque, call_id: []const u8, progress: types.WebFetchProgress) void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            app_worker_runtime.Runtime(App).pushWebFetchProgress(app, agent, call_id, progress) catch {};
        }

        pub fn onInnerToolUsage(ctx: *anyopaque, tool_name: []const u8, usage: types.ToolUsage) void {
            agentReportInnerToolUsage(ctx, tool_name, usage);
        }

        fn agentAppendRuntimeContext(ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app.appendRuntimeContextMessage(agent, arena, messages);
        }

        fn cooperativeTransportPulse(ctx: *anyopaque) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app.cooperativeTransportPulse(agent);
        }

        fn agentFinalizeTurn(ctx: *anyopaque, turn_id: u64, outcome: types.TurnPresentationOutcome, _: ?types.ProviderCompletionDisposition) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            try agent.worker.pushTurnFinished(std.heap.c_allocator, .{
                .turn_id = turn_id,
                .outcome = outcome,
            });
        }

        fn agentTakeSteeringBoundary(
            ctx: *anyopaque,
            arena: std.mem.Allocator,
            turn_id: u64,
            kind: worker_runtime.SteeringBoundaryKind,
        ) !worker_runtime.SteeringBoundaryResult {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const result = try agent.worker.takeSteeringBoundary(
                std.heap.c_allocator,
                turn_id,
                kind,
            );
            return switch (result) {
                .continue_turn => |owned| .{
                    .continue_turn = try copyOwnedSteering(arena, owned),
                },
                .none => .none,
                .handoff => .handoff,
                .interrupt => .interrupt,
            };
        }

        fn copyOwnedSteering(arena: std.mem.Allocator, owned: []worker_runtime.SteeringMessage) ![]worker_runtime.SteeringMessage {
            if (owned.len == 0) return &.{};
            defer worker_runtime.freeSteeringMessages(std.heap.c_allocator, owned);
            const result = try arena.alloc(worker_runtime.SteeringMessage, owned.len);
            for (owned, result) |message, *dest| dest.* = .{ .text = try arena.dupe(u8, message.text), .author = message.author };
            return result;
        }

        fn agentAppendStaticContext(ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            if (comptime @hasDecl(App, "appendStaticContextMessage")) {
                try app.appendStaticContextMessage(agent, arena, messages);
            }
        }

        fn agentModelCatalogFailure(ctx: *anyopaque) ?model_catalog.FailureCategory {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            if (comptime @hasDecl(App, "modelCacheFailure")) {
                return app.modelCacheFailure();
            }
            return null;
        }

        fn resolveSubagentModelOverride(ctx: ?*anyopaque, alloc: Allocator, raw_model: []const u8) Allocator.Error!subagent_model_contract.ModelCatalogMatch {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx.?));
            const app = appOf(agent);
            if (comptime @hasDecl(App, "resolveModelCapabilitiesForRequest")) {
                // Wait out a still-loading catalog so early delegation does not
                // skip matching. Only cancellation maps to passthrough.
                _ = app.resolveModelCapabilitiesForRequest(agent, raw_model) catch return .no_catalog;
            }
            if (comptime @hasDecl(App, "snapshotCachedModelIds")) {
                var ids = (try app.snapshotCachedModelIds(alloc)) orelse return .no_catalog;
                defer {
                    for (ids.items) |id| alloc.free(id);
                    ids.deinit(alloc);
                }
                return subagent_model_contract.matchCatalogModel(alloc, ids.items, raw_model);
            }
            return .no_catalog;
        }

        fn agentResolveModelCapabilities(ctx: *anyopaque, _: Allocator, model: []const u8) model_capabilities.ResolveError!model_capabilities.Capabilities {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            if (comptime runtime_profile.allows(App, .cooperative_agent)) {
                const settings = agent.worker.effectiveAgentTurnSettings();
                if (settings.fast_mode or settings.ultrafast_mode) {
                    if (agent.worker.isCancelRequested()) return error.Cancelled;
                    app.ensureModelCache();
                    // A host abort can settle the fetch before queued input reaches the worker.
                    app.cooperativeTransportPulse(agent) catch |err| {
                        debug_trace.logf("gateway", "model catalog transport pulse failed err={s}", .{@errorName(err)});
                        return error.Cancelled;
                    };
                    if (agent.worker.isCancelRequested()) return error.Cancelled;
                }
            }
            if (comptime @hasDecl(App, "resolveModelCapabilitiesForRequest")) {
                return app.resolveModelCapabilitiesForRequest(agent, model);
            }
            if (comptime @hasDecl(App, "resolvedModelCapabilitiesOf")) {
                return app.resolvedModelCapabilitiesOf(agent, model);
            }
            if (comptime @hasDecl(App, "resolvedModelCapabilities")) {
                return app.resolvedModelCapabilities(model);
            }
            if (comptime @hasDecl(App, "providerSet")) {
                return app.providerSet().select(provider_runtime.providerOf(app, agent)).fallbackModelCapabilities(model);
            }
            return model_capabilities.capabilitiesForModel(model);
        }

        fn agentAvailableModelCapabilities(ctx: *anyopaque, model: []const u8) model_capabilities.Capabilities {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            if (comptime @hasDecl(App, "resolvedModelCapabilitiesOf")) {
                return app.resolvedModelCapabilitiesOf(agent, model);
            }
            if (comptime @hasDecl(App, "resolvedModelCapabilities")) {
                return app.resolvedModelCapabilities(model);
            }
            if (comptime @hasDecl(App, "providerSet")) {
                return app.providerSet().select(provider_runtime.providerOf(app, agent)).fallbackModelCapabilities(model);
            }
            return model_capabilities.capabilitiesForModel(model);
        }

        fn agentRequestToolPermission(ctx: *anyopaque, arena: Allocator, call: ToolCall, live_authority: ?agent_runtime.LiveToolAuthority, revalidation: ?command_admission.ToolExecutionAuthority, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            return app.requestToolPermissionSyncWithAdvertised(agent, arena, call, live_authority, revalidation, advertised_dynamic_tool_names);
        }

        fn agentSnapshotRootPermissionMode(_: *anyopaque) PermissionMode {
            return .yolo;
        }

        fn agentRequestPreparedFileMutationPermission(ctx: *anyopaque, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, live_authority: ?agent_runtime.LiveToolAuthority, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            return app.requestPreparedFileMutationPermissionSyncWithAdvertised(agent, arena, call, prepared, live_authority, advertised_dynamic_tool_names);
        }

        fn agentSnapshotMcpDefinition(ctx: *anyopaque, arena: Allocator, name: []const u8, known: tool_mcp_runtime.Binding) !tool_mcp_runtime.DefinitionSnapshot {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            if (comptime @hasDecl(App, "snapshotMcpDefinition")) {
                return app.snapshotMcpDefinition(arena, name, known, .yolo);
            }
            return .unavailable;
        }

        fn agentResolveUnselectedMcpTool(ctx: *anyopaque, arena: Allocator, name: []const u8) !?tool_mcp_runtime.SelectedTool {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            return app.resolveUnselectedMcpTool(agent, arena, name);
        }

        fn agentValidateToolCall(ctx: *anyopaque, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            return app.validateToolCall(agent, arena, call);
        }

        fn agentCheckToolAvailability(ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            return app.checkToolAvailability(agent, arena, call);
        }

        fn agentResolveToolActionDisplayTarget(ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            return app.resolveToolActionDisplayTarget(agent, arena, call);
        }

        fn agentDescribeToolAction(ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            return app.describeToolActionWithAdvertised(agent, arena, call, display_target, advertised_dynamic_tool_names);
        }

        fn agentDescribeToolActionCompleted(ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            return app.describeToolActionCompletedWithAdvertised(agent, arena, call, display_target, advertised_dynamic_tool_names);
        }

        fn agentDescribeToolActionDenied(ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            return app.describeToolActionDeniedWithAdvertised(agent, arena, call, display_target, label, advertised_dynamic_tool_names);
        }

        fn agentPermissionTargetForCall(ctx: *anyopaque, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            return app.permissionTargetForCallWithAdvertised(agent, arena, call, advertised_dynamic_tool_names);
        }

        fn agentExecuteToolCall(
            ctx: *anyopaque,
            request: agent_runtime.ToolExecutionRequest,
        ) !ToolExecutionResult {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            return app.executeToolCallWithAdvertised(agent, request);
        }

        fn agentRecordToolCallRejected(
            ctx: *anyopaque,
            _: Allocator,
            call: ToolCall,
            model_output: []const u8,
            _: ?[]const u8,
        ) !void {
            _ = ctx;
            diagnostics.recordToolCallResult(.{
                .name = call.name,
                .arguments_json = call.arguments_json,
                .model_output = model_output,
                .outcome = .rejected,
                .started_at_ms = io_mod.milliTimestamp(),
                .call_id = call.id,
            });
        }

        fn agentRecordToolCallFailed(
            ctx: *anyopaque,
            _: Allocator,
            call: ToolCall,
            model_output: []const u8,
            _: ?[]const u8,
        ) !void {
            _ = ctx;
            diagnostics.recordToolCallResult(.{
                .name = call.name,
                .arguments_json = call.arguments_json,
                .model_output = model_output,
                .outcome = .tool_failed,
                .started_at_ms = io_mod.milliTimestamp(),
                .call_id = call.id,
            });
        }

        fn agentPublishCommittedFileHandoff(
            ctx: *anyopaque,
            handoff: file_mutation.CommittedFileHandoff,
        ) agent_runtime.SecondaryPublicationReport {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            return .{
                .diff = publishCommittedDiff(app, agent, handoff),
                .tracker = publishCommittedTracker(app, agent, handoff),
            };
        }

        fn publishCommittedDiff(
            app: *App,
            agent: *AppAgent,
            handoff: file_mutation.CommittedFileHandoff,
        ) agent_runtime.SecondarySinkOutcome {
            const payload = preparedDiffPayload(
                std.heap.c_allocator,
                handoff,
            ) catch |err| {
                debug_trace.logf(
                    "tool",
                    "committed file diff projection failed err={s}",
                    .{@errorName(err)},
                );
                return .failed;
            };
            app_worker_runtime.Runtime(App).pushDiffBlock(app, agent, payload) catch |err| {
                diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
                debug_trace.logf(
                    "tool",
                    "committed file diff publication failed err={s}",
                    .{@errorName(err)},
                );
                return .failed;
            };
            return .published;
        }

        fn publishCommittedTracker(
            app: *App,
            agent: *AppAgent,
            handoff: file_mutation.CommittedFileHandoff,
        ) agent_runtime.SecondarySinkOutcome {
            if (comptime !agents.hasAgentField(App, "change_tracker")) return .skipped;

            const path = app.alloc.dupe(u8, handoff.tracker.raw_path) catch |err| {
                debug_trace.logf(
                    "tool",
                    "committed file tracker path clone failed err={s}",
                    .{@errorName(err)},
                );
                return .failed;
            };
            const previous_content = if (handoff.tracker.previous_content) |content|
                app.alloc.dupe(u8, content) catch |err| {
                    app.alloc.free(path);
                    debug_trace.logf(
                        "tool",
                        "committed file tracker preimage clone failed err={s}",
                        .{@errorName(err)},
                    );
                    return .failed;
                }
            else
                null;
            agent.change_tracker.pushOperation(app.alloc, .{
                .kind = switch (handoff.tracker.kind) {
                    .write => change_tracker_mod.OperationKind.write,
                    .edit => change_tracker_mod.OperationKind.edit,
                },
                .path = path,
                .previous_content = previous_content,
                .timestamp_ms = handoff.tracker.committed_at_ms,
            }) catch |err| {
                app.alloc.free(path);
                if (previous_content) |content| app.alloc.free(content);
                debug_trace.logf(
                    "tool",
                    "committed file tracker publication failed err={s}",
                    .{@errorName(err)},
                );
                return .failed;
            };
            return .published;
        }

        fn agentPropagateHistoryTurn(ctx: *anyopaque, turn: HistoryTurn) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app_worker_runtime.Runtime(App).propagateHistoryTurn(app, agent, turn, agent.session.max_history_turns);
        }

        fn beginCompactionActivity(ctx: *anyopaque, origin: compaction_activity.Origin, turn_id: ?u64) compaction_activity.OperationId {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            return agent.worker.beginCompactionActivity(origin, turn_id);
        }

        fn runCompactionActivity(ctx: *anyopaque, id: compaction_activity.OperationId, stage: compaction_activity.Stage) void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            agent.worker.runCompactionActivity(id, stage);
        }

        fn writtenCompactionActivity(ctx: *anyopaque, id: compaction_activity.OperationId, percent: u8) void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            agent.worker.writtenCompactionActivity(id, percent);
        }

        fn settleCompactionActivity(ctx: *anyopaque, id: compaction_activity.OperationId, feedback: compaction_activity.Feedback) void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            agent.worker.settleCompactionActivity(id, feedback);
            if (feedback.outcome == .succeeded) pushCompactionDoneNotice(agent, id);
        }

        /// Leaves `Context compacted (2m10s)` in the transcript once the
        /// compaction `id` has succeeded, with the time its row showed last.
        fn pushCompactionDoneNotice(agent: *AppAgent, id: compaction_activity.OperationId) void {
            if (comptime !@hasDecl(@TypeOf(agent.worker), "compactionActivitySnapshot")) return;
            const op = agent.worker.compactionActivitySnapshot().operation orelse {
                debug_trace.logf("compaction", "event=compaction_notice_dropped reason=no_operation", .{});
                return;
            };
            if (op.id != id) {
                debug_trace.logf("compaction", "event=compaction_notice_dropped reason=superseded", .{});
                return;
            }
            var buf: [64]u8 = undefined;
            const body = activity_status.compactionDoneNotice(&buf, op) orelse {
                debug_trace.logf("compaction", "event=compaction_notice_dropped reason=no_line", .{});
                return;
            };
            // No topic, so the line reads `✓ Context compacted (2m10s)`.
            app_worker_runtime.Runtime(App).pushSemanticNotice(appOf(agent), agent, .{
                .topic = "",
                .tone = .success,
                .body = body,
            }) catch |err| debug_trace.logf("compaction", "event=compaction_notice_dropped reason={t}", .{err});
        }

        fn agentCommitContextCompaction(
            ctx: *anyopaque,
            summary: types.CompactedSummaryHistoryTurn,
            active_prefix: ?types.AssistantHistoryTurn,
            retained_from: ?types.ContextHistoryCut,
        ) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            if (comptime runtime_profile.allows(App, .cooperative_agent)) {
                // The bridge's context is the agent, as for every other
                // worker bridge callback.
                try agent.worker.publishContextCompaction(std.heap.c_allocator, .{
                    .summary = summary,
                    .active_prefix = active_prefix,
                    .retained_from = retained_from,
                    .max_history_turns = agent.session.max_history_turns,
                }, @ptrCast(agent), workerBridgeContextCompaction);
                return;
            }
            try app_worker_runtime.Runtime(App).commitContextCompaction(
                agent,
                summary,
                active_prefix,
                retained_from,
                agent.session.max_history_turns,
            );
        }

        fn agentAppendTurnPiece(ctx: *anyopaque, progress: agent_runtime.TurnProgress) anyerror!void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            try app_session_runtime.Runtime(App).appendTurnPiece(agent, progress);
        }

        fn agentSaveRecoveryRecord(ctx: *anyopaque, record: types.RecoveryRecordWrite) anyerror!bool {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            return app_session_runtime.Runtime(App).saveRecoveryRecord(agent, record);
        }

        fn agentRecordUsage(ctx: *anyopaque, usage: types.Usage) anyerror!void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            try app_session_runtime.Runtime(App).recordUsage(agent, usage);
        }

        fn agentSavePromptImages(ctx: *anyopaque, alloc: std.mem.Allocator, images: []types.ImageAttachment) anyerror!void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            try app_session_runtime.Runtime(App).savePromptImages(agent, alloc, images);
        }

        fn agentStartWorkspaceCapture(ctx: *anyopaque, fresh: bool, step: agent_runtime.AgentRuntimeDeps.WorkspaceCaptureStep) void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            app_session_runtime.Runtime(App).startWorkspaceCapture(appOf(agent), agent, fresh, step);
        }

        fn agentReachWorkspace(ctx: *anyopaque, dir: []const u8, tool_name: []const u8) void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            app_session_runtime.Runtime(App).reachWorkspace(appOf(agent), agent, dir, tool_name);
        }

        fn agentPushEvent(ctx: *anyopaque, event: WorkerEvent) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            var owned_event = event;
            if (event == .finish_prompt) {
                var finished = event.finish_prompt;
                // The turn's end capture runs here, on the agent's worker,
                // before the finished prompt reaches the UI that commits it,
                // and the prompt carries the turn's token so that commit
                // writes only this turn's captures, however late (D98).
                if (comptime agents.hasAgentField(App, "session_persistence") and turn_capture.supported) {
                    if (app_session_runtime.Runtime(App).endWorkspaceCapture(app, agent)) |token| finished.capture_turn = @backingInt(token);
                }
                if (comptime @hasDecl(@TypeOf(agent.worker), "handoffActivePromptSnapshots")) {
                    finished.snapshot_file_ownership =
                        try agent.worker.handoffActivePromptSnapshots(std.heap.c_allocator);
                }
                owned_event = .{ .finish_prompt = finished };
            }
            defer worker_runtime.freeWorkerEvent(std.heap.c_allocator, owned_event);
            try app_worker_runtime.Runtime(App).pushEvent(app, agent, owned_event);
        }

        fn agentPushText(ctx: *anyopaque, emission: agent_runtime.TextEmission) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            switch (emission) {
                .assistant_started => try app_worker_runtime.Runtime(App).pushEvent(app, agent, .{
                    .assistant_presentation = .attempt_start,
                }),
                .assistant_source => {},
                .assistant_pending => |text| try app_worker_runtime.Runtime(App).pushEvent(app, agent, .{ .live_text = @constCast(text) }),
                .assistant_rendered => |text| try app_worker_runtime.Runtime(App).pushText(app, agent, text),
                // pushEvent copies the payload into the queue's ownership.
                .assistant_restarted => |text| try app_worker_runtime.Runtime(App).pushEvent(app, agent, .{
                    .assistant_presentation = .{ .attempt_restart = @constCast(text) },
                }),
                .operational => |text| try app_worker_runtime.Runtime(App).pushText(app, agent, text),
            }
        }

        fn agentPushTable(ctx: *anyopaque, table: assistant_presentation.TablePayload) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app_worker_runtime.Runtime(App).pushTable(app, agent, table);
            var owned = table;
            owned.deinit(std.heap.c_allocator);
        }

        fn agentPushCodeBlock(ctx: *anyopaque, block: assistant_presentation.CodeBlockPayload) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app_worker_runtime.Runtime(App).pushCodeBlock(app, agent, block);
            var owned = block;
            owned.deinit(std.heap.c_allocator);
        }

        fn agentPushThematicRule(ctx: *anyopaque) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app_worker_runtime.Runtime(App).pushThematicRule(app, agent);
        }

        fn agentPushToolLifecycle(
            ctx: *anyopaque,
            event: types.ToolLifecycleEvent,
        ) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app_worker_runtime.Runtime(App).pushToolLifecycle(app, agent, event);
        }

        fn agentPushDiffBlock(ctx: *anyopaque, payload: agent_runtime.DiffEntryPayload) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            errdefer diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
            try app_worker_runtime.Runtime(App).pushDiffBlock(app, agent, payload);
        }

        fn agentPushReasoningDelta(ctx: *anyopaque, delta: []const u8) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            // pushEvent copies the payload into the queue's ownership.
            try app_worker_runtime.Runtime(App).pushEvent(appOf(agent), agent, .{ .reasoning_delta = @constCast(delta) });
        }

        fn agentPushSystemNotice(ctx: *anyopaque, text: []const u8) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app_worker_runtime.Runtime(App).pushSemanticNotice(app, agent, .{
                .topic = "system",
                .tone = .neutral,
                .body = text,
            });
        }

        fn agentPushInteractiveNotice(ctx: *anyopaque, notice: types.SemanticNotice) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app_worker_runtime.Runtime(App).pushSemanticNotice(app, agent, notice);
        }

        fn agentPushContextNotice(ctx: *anyopaque, text: []const u8) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            if (comptime @hasDecl(@TypeOf(agent.session), "claimContextNotice")) {
                if (!try agent.session.claimContextNotice(std.heap.c_allocator, text)) return;
            }
            const body = try types.renderContextNoticeBody(std.heap.c_allocator, text);
            defer std.heap.c_allocator.free(body);
            try app_worker_runtime.Runtime(App).pushSemanticNotice(app, agent, .{
                .topic = "context",
                .tone = .warning,
                .body = body,
                .visibility = .full_only,
            });
        }

        fn agentPushSessionNotice(ctx: *anyopaque, text: []const u8) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            if (comptime @hasDecl(@TypeOf(agent.session), "claimContextNotice")) {
                if (!try agent.session.claimContextNotice(std.heap.c_allocator, text)) return;
            }
            try app_worker_runtime.Runtime(App).pushSemanticNotice(app, agent, .{
                .topic = "effort",
                .tone = .neutral,
                .body = text,
            });
        }

        fn agentPushRouteRecoveryStatus(ctx: *anyopaque, status: types.RouteRecoveryStatus) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app_worker_runtime.Runtime(App).pushEvent(app, agent, .{ .route_recovery_status = status });
        }

        fn agentRestoreFailedPrompt(ctx: *anyopaque, prompt: []const u8) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            // pushEvent copies the payload into the queue's ownership.
            try app_worker_runtime.Runtime(App).pushEvent(app, agent, .{ .restore_failed_prompt = @constCast(prompt) });
        }

        fn agentPushCommandOutputComplete(ctx: *anyopaque, lifecycle_id: ?types.ToolLifecycleId) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app_worker_runtime.Runtime(App).pushCommandOutputComplete(app, agent, lifecycle_id);
        }

        fn agentPushHttpError(ctx: *anyopaque, status: std.http.Status, detail: []const u8, credential_source: ?types.CredentialSource) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            const auth_failure = auth_runtime.FailureSnapshot.fromHttp(status, credential_source);
            const message = if (auth_failure) |failure|
                try failure.renderText(std.heap.c_allocator)
            else
                try gateway_error_format.formatHttpErrorMessage(std.heap.c_allocator, status, detail);
            defer std.heap.c_allocator.free(message);
            // A subagent's parent is told why its turn failed. This runs on
            // the subagent's worker before its turn finishes, and the slot
            // thread reads it only after the main loop ends the run.
            if (comptime agents.hasAgentField(App, "child_run")) {
                if (agent.child_run) |*run| if (run.turn) |turn| {
                    const masked = try execution_memory.maskTextForDisplay(std.heap.c_allocator, message);
                    defer std.heap.c_allocator.free(masked);
                    turn.setFailureDiagnostic("provider_http_error", masked);
                };
            }
            const label = if (auth_failure) |failure|
                try std.heap.c_allocator.print(
                    "⚠ {s} · {s}",
                    .{
                        message,
                        switch (failure.source) {
                            .host_managed => credentials.host_managed_auth_message,
                            .configured => "Check the configured provider auth environment variable.",
                        },
                    },
                )
            else
                try std.heap.c_allocator.print("⚠ {s}", .{message});
            defer std.heap.c_allocator.free(label);
            try app_worker_runtime.Runtime(App).pushEvent(app, agent, .{ .api_status_text = label });
        }

        /// Asks what to do when the account is out of credits. Esc on the
        /// picker cancels.
        fn agentAskOutOfCredits(ctx: *anyopaque) !agent_runtime.OutOfCreditsChoice {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const options = [_]types.QuestionOption{
                .{ .label = "I added credits, retry", .description = "Send the request again." },
                .{ .label = "Switch to another model", .description = "Open the model picker with your message back in the composer." },
                .{ .label = "Cancel this turn", .description = "Stop this request." },
            };
            const entry = types.QuestionBatchEntry{
                .question = "Out of credits. What should spark do?",
                .options = &options,
            };
            const answers = try agent.worker.requestRouteRecoveryAnswerBlocking(std.heap.c_allocator, &.{entry});
            defer if (answers) |owned| {
                for (owned) |label| std.heap.c_allocator.free(label);
                std.heap.c_allocator.free(owned);
            };
            const label = if (answers) |owned| (if (owned.len > 0) owned[0] else "") else "";
            if (std.mem.eql(u8, label, options[0].label)) return .retry;
            if (std.mem.eql(u8, label, options[1].label)) return .switch_model;
            return .cancel;
        }

        fn agentFormatToolExecutionError(ctx: *anyopaque, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            return app.formatToolExecutionErrorForAgent(arena, tool_name, err);
        }

        fn agentReportUsage(ctx: *anyopaque, usage: types.Usage) void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            if (usage.input_tokens) |input| agents.storeTotal(&agent.total_input_tokens, input);
            if (usage.output_tokens) |output| agents.storeTotal(&agent.total_output_tokens, output);
        }

        fn agentReportInnerToolUsage(ctx: *anyopaque, tool_name: []const u8, usage: types.ToolUsage) void {
            if (!std.mem.eql(u8, tool_name, "web_search") and
                !tool_presentation.isProviderSearchAlias(tool_name)) return;
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            agents.addTotal(&agent.total_web_search_requests, @as(u64, usage.web_search_requests));
        }

        fn workerBridgeWriteUserPrompt(ctx: *anyopaque, prompt: types.UserTurn) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app.writeUserPromptCard(agent, prompt);
        }

        fn workerBridgeWriteUserPromptWithSkillBindings(
            ctx: *anyopaque,
            prompt: types.UserTurn,
            skill_bindings: []const worker_runtime.SkillBinding,
            skill_display_spans: []const worker_runtime.SkillDisplaySpan,
        ) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            if (comptime @hasDecl(App, "writeUserPromptCardWithSkillBindings")) {
                try app.writeUserPromptCardWithSkillBindings(agent, prompt, skill_bindings, skill_display_spans);
            } else {
                try app.writeUserPromptCard(agent, prompt);
            }
        }

        fn workerBridgeAppendText(ctx: *anyopaque, text: []const u8) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app.pacer.enqueue(app.alloc, text);
        }

        fn workerBridgeAppendTable(ctx: *anyopaque, table: assistant_presentation.TablePayload) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            var owned = table;
            var handed_off = false;
            errdefer if (!handed_off) owned.deinit(app.alloc);
            if (comptime @hasDecl(App, "appendAssistantTable")) {
                try app.appendAssistantTable(owned);
                handed_off = true;
                return;
            }
            owned.deinit(app.alloc);
            handed_off = true;
        }

        fn workerBridgeAppendCodeBlock(ctx: *anyopaque, block: assistant_presentation.CodeBlockPayload) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            var owned = block;
            var handed_off = false;
            errdefer if (!handed_off) owned.deinit(app.alloc);
            if (comptime @hasDecl(App, "appendAssistantCodeBlock")) {
                try app.appendAssistantCodeBlock(owned);
                handed_off = true;
                return;
            }
            owned.deinit(app.alloc);
            handed_off = true;
        }

        fn workerBridgeAppendThematicRule(ctx: *anyopaque) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            if (comptime @hasDecl(App, "appendAssistantThematicRule")) {
                try app.appendAssistantThematicRule();
            }
        }

        fn workerBridgeDrainAssistantText(ctx: *anyopaque) !app_worker_runtime.AssistantTextDrainResult {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app.pacer.flushPresentationAtBoundary(
                app.alloc,
                io_mod.nanoTimestamp(),
                app.pacerCallbacks(),
            );
            return .drained;
        }

        fn workerBridgeHoldModelCall(ctx: *anyopaque, record: types.ModelCallRecord) !bool {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            if (comptime @hasDecl(@TypeOf(app.pacer), "holdModelCall")) {
                return app.pacer.holdModelCall(app.alloc, record);
            }
            return false;
        }

        fn workerBridgeOpenModelPicker(ctx: *anyopaque) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            if (comptime @hasField(App, "input_runtime") and
                provider_runtime.supported(App) and
                @hasDecl(App, "modelCompletions"))
            {
                // The Ctrl+P picker owns the borrowed composer while a draft
                // is stashed; seeding the inline "/model " flow there would
                // overwrite the catalog query or the effort and fast stages.
                const InputRuntime = @TypeOf(app.input_runtime);
                if (comptime @hasField(InputRuntime, "model_picker_draft")) {
                    if (app.input_runtime.model_picker_draft != null) return;
                }
                try input_completion_runtime.CompletionRuntime(App).openCurrentModelPicker(app);
            }
        }

        fn workerBridgeSemanticNotice(ctx: *anyopaque, notice: types.SemanticNotice) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app.writeDomainNotice(notice, true);
        }

        fn workerBridgeCommandOutput(
            ctx: *anyopaque,
            lifecycle_id: ?types.ToolLifecycleId,
            stream: command_output_content.Stream,
            text: []const u8,
        ) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            if (comptime @hasDecl(App, "writeCommandOutputChunkForLifecycle")) {
                try app.writeCommandOutputChunkForLifecycle(lifecycle_id, stream, text, true);
                return;
            }
            try app.writeCommandOutputChunk(stream, text, true);
        }

        fn workerBridgeCommandOutputComplete(ctx: *anyopaque, lifecycle_id: ?types.ToolLifecycleId) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            if (comptime @hasDecl(App, "flushCommandOutputSummaryForLifecycle")) {
                try app.flushCommandOutputSummaryForLifecycle(lifecycle_id, true);
                return;
            }
            try app.flushCommandOutputSummary(true);
        }

        fn workerBridgeDiffBlock(ctx: *anyopaque, payload: diff_mod.DiffEntryPayload) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app.registerAndEmitDiffBlock(agent, payload);
        }

        fn workerBridgeContextCompaction(ctx: *anyopaque, value: worker_runtime.ContextCompaction) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app_session_runtime.Runtime(App).commitContextCompaction(app, agent, value.summary, value.active_prefix, value.retained_from);
        }

        fn workerBridgeAppendHistoryTurn(ctx: *anyopaque, finished: types.FinishedPrompt) !app_worker_runtime.HistoryDelivery {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            if (try app_worker_runtime.Runtime(App).deferFinish(app, agent, finished)) return .retained;
            return .{ .settled = try appendHistoryTurn(app, agent, finished) };
        }

        fn workerBridgeErrorText(ctx: *anyopaque, notice: types.SemanticNotice) !void {
            const agent: *AppAgent = @ptrCast(@alignCast(ctx));
            const app = appOf(agent);
            try app.writeDomainNotice(notice, true);
        }

        fn appendHistoryTurn(app: *App, agent: *AppAgent, finished: types.FinishedPrompt) !assistant_pacer.FinishResult {
            if (comptime @hasDecl(App, "finishPromptPresentation")) {
                return app.finishPromptPresentation(agent, finished);
            }
            if (comptime @hasDecl(App, "appendFinishedPrompt")) {
                try app.appendFinishedPrompt(finished);
                return .committed;
            }
            if (comptime @hasDecl(App, "appendHistoryTurn")) {
                try app.appendHistoryTurn(agent, finished.turn);
                if (finished.snapshot_file_ownership) |ownership| ownership.transfer();
                return .committed;
            }
            try app_session_runtime.Runtime(App).appendFinishedPrompt(app, agent, finished);
            return .committed;
        }
    };
}

const FakeWorker = struct {
    worker_cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    events: std.ArrayList(WorkerEvent) = .empty,
    propagated_history_turns: usize = 0,
    active_snapshot_transfers: usize = 0,
    active_turn_id: u64 = 1,
    fail_diff_push: bool = false,
    fail_semantic_push: bool = false,
    fail_command_output_push: bool = false,

    fn deinit(self: *FakeWorker) void {
        for (self.events.items) |event| worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
        self.events.deinit(std.heap.c_allocator);
    }

    pub fn pushEvent(self: *FakeWorker, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        const owned = try worker_runtime.dupeWorkerEvent(alloc, event);
        errdefer worker_runtime.freeWorkerEvent(alloc, owned);
        try self.pushOwnedEvent(alloc, owned);
    }

    pub fn pushOwnedEvent(self: *FakeWorker, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        if (self.fail_diff_push) {
            switch (event) {
                .diff_block => return error.TestDiffPublicationFailure,
                else => {},
            }
        }
        if (self.fail_semantic_push) {
            switch (event) {
                .assistant_presentation => |presentation| switch (presentation) {
                    .table, .code_block => return error.TestSemanticPresentationPublicationFailure,
                    .text, .thematic_rule, .attempt_start, .attempt_restart => {},
                },
                else => {},
            }
        }
        if (self.fail_command_output_push) {
            switch (event) {
                .command_output => return error.OutOfMemory,
                else => {},
            }
        }
        try self.events.append(alloc, event);
    }

    pub fn pushTurnFinished(self: *FakeWorker, alloc: std.mem.Allocator, event: types.TurnFinished) !void {
        try self.events.append(alloc, .{ .tool_lifecycle = .{
            .turn_finished = event,
        } });
    }

    pub fn propagateHistoryTurn(self: *FakeWorker, alloc: std.mem.Allocator, turn: HistoryTurn, max_history_turns: usize) !void {
        _ = alloc;
        _ = turn;
        _ = max_history_turns;
        self.propagated_history_turns += 1;
    }

    pub fn transferActivePromptSnapshots(self: *FakeWorker) void {
        self.active_snapshot_transfers += 1;
    }

    pub fn activeTurnId(self: *FakeWorker) u64 {
        return self.active_turn_id;
    }
};

const FakeSession = struct {
    max_history_turns: usize = 8,
    history_appends: usize = 0,
    agent: struct { history: std.ArrayList(types.HistoryTurn) = .empty } = .{},

    pub fn commitCompactedHistory(self: *FakeSession, alloc: std.mem.Allocator, history: []types.HistoryTurn) void {
        self.history_appends += 1;
        types.freeHistoryTurnSlice(alloc, history);
    }

    pub fn unversionedHistoryEnd(_: *FakeSession) usize {
        return 0;
    }

    pub fn prepareHistoryEntry(_: *FakeSession, alloc: std.mem.Allocator, turn: types.HistoryTurn) !types.HistoryTurn {
        return types.dupeHistoryTurn(alloc, turn);
    }

    pub fn commitPreparedHistoryEntry(self: *FakeSession, alloc: std.mem.Allocator, turn: types.HistoryTurn) void {
        self.history_appends += 1;
        types.freeHistoryTurn(alloc, turn);
    }

    fn languageSnapshot(self: *FakeSession) types.ConversationLanguage {
        _ = self;
        return types.ConversationLanguage.default();
    }

    pub fn appendHistoryEntry(self: *FakeSession, alloc: std.mem.Allocator, turn: types.HistoryTurn) !void {
        _ = alloc;
        _ = turn;
        self.history_appends += 1;
    }
};

const FakePacer = struct {
    text: std.ArrayList(u8) = .empty,
    defer_history: bool = false,
    enqueue_count: usize = 0,
    flush_count: usize = 0,

    fn deinit(self: *FakePacer, alloc: std.mem.Allocator) void {
        self.text.deinit(alloc);
    }

    fn enqueue(self: *FakePacer, alloc: std.mem.Allocator, text: []const u8) !void {
        self.enqueue_count += 1;
        try self.text.appendSlice(alloc, text);
    }

    pub fn deferFinish(self: *FakePacer, alloc: std.mem.Allocator, finished: types.FinishedPrompt) !bool {
        _ = alloc;
        _ = finished;
        return self.defer_history;
    }

    pub fn flushPresentationAtBoundary(
        self: *FakePacer,
        alloc: std.mem.Allocator,
        now_ns: i128,
        callbacks: anytype,
    ) !void {
        _ = alloc;
        _ = now_ns;
        _ = callbacks;
        self.flush_count += 1;
        self.text.clearRetainingCapacity();
    }
};

const FakeShell = struct {
    last_class: transcript_runtime.RawEntryClass = .unknown_raw,
    render_requests: render_request.RenderRequestState = .{},
    lifecycle: transcript_runtime.TranscriptRuntime = .{},
    preserved_anchor_apply_count: usize = 0,

    pub fn replaceableEntryId(self: *FakeShell) ?u32 {
        _ = self;
        return null;
    }

    pub fn setRawEntryClass(self: *FakeShell, entry_id: u32, class: transcript_runtime.RawEntryClass) bool {
        _ = entry_id;
        self.last_class = class;
        return true;
    }

    pub fn applyToolLifecycle(
        self: *FakeShell,
        alloc: std.mem.Allocator,
        event: types.ToolLifecycleEvent,
    ) !?types.ToolActivityKind {
        return self.lifecycle.applyToolLifecycle(alloc, event);
    }

    pub fn applyToolLifecyclePreservingNormalBufferAnchor(
        self: *FakeShell,
        alloc: std.mem.Allocator,
        event: types.ToolLifecycleEvent,
    ) !?types.ToolActivityKind {
        self.preserved_anchor_apply_count += 1;
        return self.lifecycle.applyToolLifecyclePreservingNormalBufferAnchor(alloc, event);
    }

    pub fn finishLifecycleBatch(
        self: *FakeShell,
        alloc: std.mem.Allocator,
    ) !void {
        return self.lifecycle.finishLifecycleBatch(alloc);
    }

    pub fn activityProjection(
        self: *const FakeShell,
    ) activity_runtime.ActivityProjection {
        return self.lifecycle.activityProjection();
    }

    pub fn focusedToolEntryId(self: *const FakeShell) ?u32 {
        return self.lifecycle.focusedToolEntryId();
    }

    pub fn focusedToolActivityKind(
        self: *const FakeShell,
    ) ?types.ToolActivityKind {
        return self.lifecycle.focusedToolActivityKind();
    }

    pub fn activeToolActivityCount(self: *const FakeShell) usize {
        return self.lifecycle.activeToolActivityCount();
    }

    pub fn toolActivityRecord(
        self: *const FakeShell,
        id: types.ToolLifecycleId,
    ) ?activity_runtime.ToolPresentationRecord {
        return self.lifecycle.toolActivityRecord(id);
    }

    pub fn finalizedToolTurnWatermark(self: *const FakeShell) u64 {
        return self.lifecycle.finalizedToolTurnWatermark();
    }
};

const FakeApp = struct {
    alloc: std.mem.Allocator,
    input_runtime: core_input_runtime.Runtime = .{},
    selected_model: std.ArrayList(u8) = .empty,
    model_completion_values: []const []const u8 = &.{},
    main_agent: struct {
        change_tracker: change_tracker_mod.ChangeTracker = .{},
        total_input_tokens: u64 = 0,
        total_output_tokens: u64 = 0,
        total_web_search_requests: u64 = 0,
        session: FakeSession = .{},
        worker: FakeWorker = .{},
    } = .{},
    shell: FakeShell = .{},
    terminal: struct {
        alternate_screen_owner: enum { none, active } = .none,
    } = .{},
    pacer: FakePacer = .{},
    transcript: std.ArrayList(u8) = .empty,
    user_prompt_count: usize = 0,
    command_output_count: usize = 0,
    command_output_complete_count: usize = 0,
    last_command_output_lifecycle_turn_id: ?u64 = null,
    last_command_output_lifecycle_call_id: []const u8 = "",
    last_command_output_complete_lifecycle_turn_id: ?u64 = null,
    last_command_output_complete_lifecycle_call_id: []const u8 = "",
    history_append_count: usize = 0,
    summary_append_count: usize = 0,
    last_summary: ?types.TurnSummary = null,
    grant_count: usize = 0,
    diff_register_count: usize = 0,
    replaceable_count: usize = 0,
    replaceable_silent_count: usize = 0,
    replace_count: usize = 0,
    replace_silent_count: usize = 0,
    last_class: transcript_runtime.RawEntryClass = .unknown_raw,
    last_notice_topic: std.ArrayList(u8) = .empty,
    last_notice_tone: types.NoticeTone = .information,
    last_notice_visibility: types.NoticeVisibility = .compact_and_full,
    last_notice_record: bool = false,
    capability_request_count: usize = 0,

    fn init(alloc: std.mem.Allocator) FakeApp {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *FakeApp) void {
        self.agent().worker.deinit();
        self.input_runtime.deinit(self.alloc);
        self.selected_model.deinit(self.alloc);
        self.agent().change_tracker.deinit(self.alloc);
        self.shell.lifecycle.deinit(self.alloc);
        self.pacer.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.last_notice_topic.deinit(self.alloc);
    }

    pub fn modelCompletions(self: *FakeApp, _: []const u8, out: *[32][]const u8) usize {
        const count = @min(self.model_completion_values.len, out.len);
        for (self.model_completion_values[0..count], 0..) |value, index| {
            out[index] = value;
        }
        return count;
    }

    pub fn resolveModelCapabilitiesForRequest(
        self: *FakeApp,
        _: anytype,
        model: []const u8,
    ) !model_capabilities.Capabilities {
        self.capability_request_count += 1;
        const efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("future-tier")};
        return model_capabilities.resolveCapabilities(
            model,
            .{ .reasoning_efforts = .fromSlice(&efforts) },
        );
    }

    fn storeLifecycleId(
        turn_id: *?u64,
        call_id: *[]const u8,
        lifecycle_id: ?types.ToolLifecycleId,
    ) void {
        if (lifecycle_id) |id| {
            turn_id.* = id.turn_id;
            call_id.* = id.call_id;
        } else {
            turn_id.* = null;
            call_id.* = "";
        }
    }

    fn appendRuntimeContextMessage(self: *FakeApp, _: anytype, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
        _ = self;
        try messages.append(arena, .{ .role = .system, .content = "runtime" });
    }

    fn requestToolPermissionSyncWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, _: ?agent_runtime.LiveToolAuthority, _: ?command_admission.ToolExecutionAuthority, _: []const []const u8) !command_admission.PermissionOutcome {
        _ = self;
        _ = arena;
        _ = call;
        return .{
            .decision = .once,
            .execution_authority = .ordinary,
        };
    }

    fn requestPreparedFileMutationPermissionSyncWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, _: ?agent_runtime.LiveToolAuthority, _: []const []const u8) !command_admission.PermissionOutcome {
        _ = self;
        _ = call;
        prepared.deinit(arena);
        return .{
            .decision = .once,
            .execution_authority = .ordinary,
        };
    }

    fn validateToolCall(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
        _ = self;
        return .{ .failure = try arena.print("invalid {s}", .{call.name}) };
    }

    fn checkToolAvailability(self: *FakeApp, _: anytype, _: Allocator, _: ToolCall) !?[]const u8 {
        _ = self;
        return null;
    }

    fn describeToolActionWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, _: ?[]const u8, _: []const []const u8) ![]const u8 {
        _ = self;
        return arena.print("run {s}", .{call.name});
    }

    fn describeToolActionCompletedWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, _: ?[]const u8, _: []const []const u8) ![]const u8 {
        _ = self;
        return arena.print("done {s}", .{call.name});
    }

    fn describeToolActionDeniedWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, _: ?[]const u8, label: []const u8, _: []const []const u8) ![]const u8 {
        _ = self;
        return arena.print("denied {s} {s}", .{ call.name, label });
    }

    fn permissionTargetForCallWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, _: []const []const u8) ![]const u8 {
        _ = self;
        return arena.print("target:{s}", .{call.id});
    }

    fn executeToolCallWithAdvertised(
        self: *FakeApp,
        _: anytype,
        request: agent_runtime.ToolExecutionRequest,
    ) !ToolExecutionResult {
        _ = self;
        _ = request;
        return .{ .model_output = "tool output" };
    }

    fn registerAndEmitDiffBlock(self: *FakeApp, _: anytype, payload: agent_runtime.DiffEntryPayload) !void {
        defer diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
        self.diff_register_count += 1;
        try self.transcript.appendSlice(self.alloc, payload.preview);
    }

    fn formatToolExecutionErrorForAgent(self: *FakeApp, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
        _ = self;
        return arena.print("{s}:{s}", .{ tool_name, @errorName(err) });
    }

    fn writeUserPromptCard(self: *FakeApp, _: anytype, prompt: types.UserTurn) !void {
        _ = prompt;
        self.user_prompt_count += 1;
    }

    pub fn writeDomainNotice(self: *FakeApp, notice: types.SemanticNotice, record: bool) !void {
        self.last_notice_topic.clearRetainingCapacity();
        try self.last_notice_topic.appendSlice(self.alloc, notice.topic);
        self.last_notice_tone = notice.tone;
        self.last_notice_visibility = notice.visibility;
        self.last_notice_record = record;
        try self.transcript.appendSlice(self.alloc, notice.body);
    }

    fn pacerCallbacks(self: *FakeApp) void {
        _ = self;
    }

    fn writeCommandOutputChunk(self: *FakeApp, stream: command_output_content.Stream, text: []const u8, record: bool) !void {
        _ = stream;
        _ = text;
        _ = record;
        self.command_output_count += 1;
    }

    pub fn writeCommandOutputChunkForLifecycle(self: *FakeApp, lifecycle_id: ?types.ToolLifecycleId, stream: command_output_content.Stream, text: []const u8, record: bool) !void {
        storeLifecycleId(
            &self.last_command_output_lifecycle_turn_id,
            &self.last_command_output_lifecycle_call_id,
            lifecycle_id,
        );
        try self.writeCommandOutputChunk(stream, text, record);
    }

    fn flushCommandOutputSummary(self: *FakeApp, record: bool) !void {
        try self.flushCommandOutputSummaryForLifecycle(null, record);
    }

    pub fn flushCommandOutputSummaryForLifecycle(self: *FakeApp, lifecycle_id: ?types.ToolLifecycleId, record: bool) !void {
        _ = record;
        storeLifecycleId(
            &self.last_command_output_complete_lifecycle_turn_id,
            &self.last_command_output_complete_lifecycle_call_id,
            lifecycle_id,
        );
        self.command_output_complete_count += 1;
    }

    pub fn appendHistoryTurn(self: *FakeApp, turn: types.HistoryTurn) !void {
        _ = turn;
        self.history_append_count += 1;
    }

    pub fn appendFinishedPrompt(self: *FakeApp, finished: types.FinishedPrompt) !void {
        _ = finished.turn;
        self.history_append_count += 1;
        if (finished.snapshot_file_ownership) |ownership| ownership.transfer();
        if (finished.summary) |summary| {
            self.summary_append_count += 1;
            self.last_summary = summary;
        }
    }

    fn allowToolForSession(self: *FakeApp, _: anytype, tool_name: []const u8, target_path: []const u8) !void {
        _ = tool_name;
        _ = target_path;
        self.grant_count += 1;
    }

    pub fn writeTranscript(self: *FakeApp, text: []const u8, record: bool) !void {
        _ = record;
        try self.transcript.appendSlice(self.alloc, text);
    }

    pub fn writeTranscriptClassified(self: *FakeApp, text: []const u8, record: bool, class: transcript_runtime.RawEntryClass) !void {
        self.last_class = class;
        try self.writeTranscript(text, record);
    }

    pub fn appendReplaceableTranscriptLine(self: *FakeApp, text: []const u8) !u32 {
        self.replaceable_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_count);
    }

    pub fn appendReplaceableTranscriptLineClassified(self: *FakeApp, text: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_class = class;
        return self.appendReplaceableTranscriptLine(text);
    }

    pub fn appendReplaceableTranscriptLineSilent(self: *FakeApp, text: []const u8) !u32 {
        self.replaceable_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_silent_count);
    }

    pub fn appendReplaceableTranscriptLineSilentClassified(self: *FakeApp, text: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_class = class;
        return self.appendReplaceableTranscriptLineSilent(text);
    }

    pub fn replaceTrailingTranscriptLine(self: *FakeApp, text: []const u8) !bool {
        self.replace_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }

    pub fn replaceTrailingTranscriptLineSilent(self: *FakeApp, text: []const u8) !bool {
        self.replace_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

const NoOverridePersistentApp = struct {
    alloc: Allocator,
    shell: FakeShell = .{},
    pacer: FakePacer = .{},
    transcript: std.ArrayList(u8) = .empty,
    main_agent: struct {
        total_input_tokens: u64 = 0,
        total_output_tokens: u64 = 0,
        total_web_search_requests: u64 = 0,
        session: session_runtime.SessionRuntime = .{ .max_history_turns = 8 },
    } = .{},
    replaceable_count: usize = 0,
    replaceable_silent_count: usize = 0,
    replace_count: usize = 0,
    replace_silent_count: usize = 0,
    fn deinit(self: *NoOverridePersistentApp) void {
        self.shell.lifecycle.deinit(self.alloc);
        self.pacer.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.agent().session.deinit(self.alloc);
        self.* = undefined;
    }

    fn writeUserPromptCard(self: *NoOverridePersistentApp, _: anytype, prompt: types.UserTurn) !void {
        _ = self;
        _ = prompt;
    }

    fn writeDomainNotice(self: *NoOverridePersistentApp, notice: types.SemanticNotice, record: bool) !void {
        _ = self;
        _ = notice;
        _ = record;
    }

    fn pacerCallbacks(self: *NoOverridePersistentApp) void {
        _ = self;
    }

    fn writeCommandOutputChunk(self: *NoOverridePersistentApp, stream: command_output_content.Stream, text: []const u8, record: bool) !void {
        _ = self;
        _ = stream;
        _ = text;
        _ = record;
    }

    fn flushCommandOutputSummary(self: *NoOverridePersistentApp, record: bool) !void {
        _ = self;
        _ = record;
    }

    fn allowToolForSession(self: *NoOverridePersistentApp, _: anytype, tool_name: []const u8, target_path: []const u8) !void {
        _ = self;
        _ = tool_name;
        _ = target_path;
    }

    fn writeTranscript(self: *NoOverridePersistentApp, text: []const u8, record: bool) !void {
        _ = record;
        try self.transcript.appendSlice(self.alloc, text);
    }

    fn writeTranscriptClassified(self: *NoOverridePersistentApp, text: []const u8, record: bool, class: transcript_runtime.RawEntryClass) !void {
        _ = class;
        try self.writeTranscript(text, record);
    }

    fn registerAndEmitDiffBlock(self: *NoOverridePersistentApp, _: anytype, payload: agent_runtime.DiffEntryPayload) !void {
        _ = self;
        diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
    }

    fn appendReplaceableTranscriptLine(self: *NoOverridePersistentApp, text: []const u8) !u32 {
        self.replaceable_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_count);
    }

    fn appendReplaceableTranscriptLineSilent(self: *NoOverridePersistentApp, text: []const u8) !u32 {
        self.replaceable_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_silent_count);
    }

    fn replaceTrailingTranscriptLine(self: *NoOverridePersistentApp, text: []const u8) !bool {
        self.replace_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }

    fn replaceTrailingTranscriptLineSilent(self: *NoOverridePersistentApp, text: []const u8) !bool {
        self.replace_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

const committed_preview_lines = [_]diff_mod.PreviewLine{
    .{
        .op = .deletion,
        .old_line = 1,
        .text = "before",
    },
    .{
        .op = .addition,
        .new_line = 1,
        .text = "after",
    },
};

fn testCommittedFileHandoff() file_mutation.CommittedFileHandoff {
    return file_mutation.CommittedFileHandoff.init(
        .{
            .path = "tracked.txt",
            .lines = &committed_preview_lines,
            .additions = 1,
            .deletions = 1,
            .truncated = false,
        },
        .{
            .kind = .edit,
            .raw_path = "/tmp/workspace/tracked.txt",
            .previous_content = "before\n",
            .committed_at_ms = 42,
        },
    );
}
