const std = @import("std");
const agents = @import("../agents/agents.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const file_picker_path = @import("../input/file_picker_path.zig");
const question_prompt = @import("../agent/question_prompt.zig");
const app_agents_runtime = @import("app_agents_runtime.zig");
const app_auth_runtime = @import("app_auth_runtime.zig");
const app_provider_menu_runtime = @import("app_provider_menu_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const app_workspace_runtime = @import("app_workspace_runtime.zig");
const app_commands = @import("app_commands.zig");
const project_config = @import("../mcp/project_config.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const app_render_runtime = @import("app_render_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const host = @import("../hosts/host.zig");
const composer_insertion = @import("../input/composer_insertion.zig");
const composer_stash = @import("../input/composer_stash.zig");
const gesture_state = @import("../input/gesture_state.zig");
const horizontal_navigation = @import("../input/horizontal_navigation.zig");
const input_action = @import("../input/input_action.zig");
const transcript_presentation = @import("../output/transcript_presentation.zig");
const core_input_runtime = @import("../input/runtime.zig");
const input_limit_rejection = @import("../input/input_limit_rejection.zig");
const input_reset = @import("../input/input_reset.zig");
const picker_state = @import("../input/picker_state.zig");
const paste_framing = @import("../input/paste_framing.zig");
const text_scalar = @import("../input/text_scalar.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const config_runtime = @import("../config/config_runtime.zig");
const text_utils = @import("../shared/text_utils.zig");
const image_attachments = @import("../images/image_attachments.zig");
const image_commands = @import("../images/image_commands.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_cache_runtime = @import("model_cache_runtime.zig");
const permissions = @import("../permissions/permissions.zig");
const session_commands = @import("../session/session_commands.zig");
const session_catalog = @import("../session/session_catalog.zig");
const session_runtime = @import("../session/session.zig");
const session_adapter = @import("../session/session_adapter.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const file_index = @import("../workspace/file_index.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const auto_upgrade = @import("../upgrade/auto_upgrade.zig");
const upgrade_helpers = @import("../upgrade/upgrade_helpers.zig");
const test_ui_input = @import("../../ui/input/runtime.zig");
const visual_layout = @import("../../ui/input/visual_layout.zig");
const picker_presentation = @import("../../ui/footer/picker_presentation.zig");
const compact_command_menu_presentation = @import("../../ui/footer/compact_command_menu_presentation.zig");
const render_input = @import("../../ui/footer/render_input.zig");
const info_panel_presentation = @import("../../ui/footer/info_panel_presentation.zig");
const paste_blocks = @import("../input/pasted_blocks.zig");
const registered_entities = @import("../input/registered_entities.zig");
const prompt_history_runtime = @import("prompt_history_runtime.zig");
const prompt_history_store = @import("../session/prompt_history_store.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const render_request = @import("../../ui/render_request.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");
const input_interrupt_runtime = @import("input_interrupt_runtime.zig");
const input_history_runtime = @import("input_history_runtime.zig");
const input_completion_runtime = @import("input_completion_runtime.zig");
const input_paste_runtime = @import("input_paste_runtime.zig");
const input_submit_runtime = @import("input_submit_runtime.zig");
const input_question_runtime = @import("input_question_runtime.zig");
const input_full_transcript_runtime = @import("input_full_transcript_runtime.zig");
const input_selection_runtime = @import("input_selection_runtime.zig");
const input_limit_feedback = @import("input_limit_feedback.zig");
const app_upgrade_runtime = @import("app_upgrade_runtime.zig");

test {
    _ = file_picker_path;
    _ = picker_state;
    _ = input_completion_runtime;
}

const ModelPickerStage = picker_state.ModelPickerStage;
const ToolPermissionDecision = types.ToolPermissionDecision;

pub const file_picker_completion_cap = input_completion_runtime.file_picker_completion_cap;
const ctrl_g_upgrade_byte: u8 = 7;

fn classifyResumeFailure(err: anyerror) session_catalog.ResumeFailure {
    return switch (err) {
        error.SessionBusy => .open_elsewhere,
        error.SessionAuthorityBoundaryUnavailable,
        error.SessionCommitBoundaryUnavailable,
        => .being_updated,
        error.ConfiguredProviderChanged => .connection_changed,
        error.ConfiguredProviderRemoved => .connection_removed,
        else => .unavailable,
    };
}

const ExplicitModelSelection = struct {
    model: []const u8,
    effort: types.ReasoningEffort,
    fast_mode: bool,
    ultrafast_mode: bool = false,
    has_fast_mode_token: bool = false,
};

const ExplicitModelSelectionParse = union(enum) {
    none,
    invalid,
    selection: ExplicitModelSelection,
};

fn parseExplicitModelSelection(input: []const u8) ExplicitModelSelectionParse {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "/model")) return .none;
    if (trimmed.len == "/model".len) return .none;
    if (trimmed["/model".len] != ' ' and trimmed["/model".len] != '\t') return .none;

    var tokens: [4][]const u8 = undefined;
    var token_count: usize = 0;
    var iterator = std.mem.tokenizeAny(u8, trimmed["/model".len..], " \t\r\n");
    while (iterator.next()) |token| {
        if (token_count == tokens.len) return .invalid;
        tokens[token_count] = token;
        token_count += 1;
    }
    if (token_count < 2) return .none;

    const effort = types.ReasoningEffort.parse(tokens[1]) orelse return .none;

    if (token_count == 2) {
        return .{ .selection = .{
            .model = tokens[0],
            .effort = effort,
            .fast_mode = false,
            .has_fast_mode_token = false,
        } };
    }

    if (token_count != 3) return .invalid;
    const fast_mode = std.ascii.eqlIgnoreCase(tokens[2], "fast");
    const ultrafast_mode = std.ascii.eqlIgnoreCase(tokens[2], "ultrafast");
    if (!fast_mode and !ultrafast_mode and !std.ascii.eqlIgnoreCase(tokens[2], "normal")) {
        return .invalid;
    }
    return .{ .selection = .{
        .model = tokens[0],
        .effort = effort,
        .fast_mode = fast_mode,
        .ultrafast_mode = ultrafast_mode,
        .has_fast_mode_token = true,
    } };
}

fn validateExplicitModelSelection(selection: ExplicitModelSelection, capabilities: model_capabilities.Capabilities) ExplicitModelSelectionParse {
    if (!model_capabilities.reasoningEffortSupported(capabilities, selection.effort)) return .invalid;
    if (!selection.has_fast_mode_token) return .{ .selection = selection };
    if (selection.ultrafast_mode and !capabilities.supports_ultrafast_mode) return .invalid;
    if (selection.fast_mode and !capabilities.supports_fast_mode) return .invalid;
    if (!selection.fast_mode and !selection.ultrafast_mode and
        !capabilities.supports_fast_mode and !capabilities.supports_ultrafast_mode)
    {
        return .invalid;
    }
    return .{ .selection = selection };
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        const history_rt = input_history_runtime.HistoryRuntime(App);
        const completion_rt = input_completion_runtime.CompletionRuntime(App);
        const paste_rt = input_paste_runtime.PasteEditRuntime(App);
        const submit_rt = input_submit_runtime.SubmitRuntime(App);
        const question_rt = input_question_runtime.QuestionRuntime(App);
        const interrupt_rt = input_interrupt_runtime.InterruptRuntime(App);
        const full_transcript_rt = input_full_transcript_runtime.Runtime(App);

        const ctrl_c_exit_window_ms = gesture_state.ctrl_c_exit_window_ms;
        const ResolvedEscapeRoute = union(enum) {
            done,
            remapped_byte: u8,
        };

        const routeSlashCompletionMove = completion_rt.routeSlashCompletionMove;
        const advanceModelPickerOnSpace = completion_rt.advanceModelPickerOnSpace;
        const routeModifiedHistory = completion_rt.routeModifiedHistory;
        const routePlainVertical = completion_rt.routePlainVertical;
        const routeVisiblePickerMove = completion_rt.routeVisiblePickerMove;
        const navigateModelPicker = completion_rt.navigateModelPicker;
        const routeQuestionEscapeAction = question_rt.routeQuestionEscapeAction;
        const submitQuestionBatch = question_rt.submitQuestionBatch;
        pub const rerenderQuestionBlock = question_rt.rerenderQuestionBlock;
        const finishPaste = paste_rt.finishPaste;
        const finalizePastedBlock = paste_rt.finalizePastedBlock;
        const handlePastedBytes = paste_rt.handlePastedBytes;
        const submit = submit_rt.submit;
        pub const installPromptHistory = history_rt.installPromptHistory;
        pub const loadAndInstallPromptHistory = history_rt.loadAndInstallPromptHistory;

        fn insertComposerSliceBounded(
            app: *App,
            agent: *AppAgent,
            bytes: []const u8,
            max_input_len: usize,
            preserve_model_picker: bool,
        ) !composer_insertion.InsertResult {
            const picker_policy: composer_insertion.PickerPolicy = if (preserve_model_picker)
                .preserve
            else
                .clear;
            return app.input_runtime.replacementState(&agent.pending_images).replaceSelectionOrInsertSliceBounded(
                app.alloc,
                bytes,
                max_input_len,
                picker_policy,
            );
        }

        pub fn clearPendingImages(app: *App, agent: *AppAgent) void {
            app.input_runtime.vertical_navigation.reset();
            app.input_runtime.entities.image_tokens.clearRetainingCapacity();
            image_attachments.discardImageSnapshots(app.alloc, agent.pending_images.items);
            for (agent.pending_images.items) |image| {
                types.freeImageAttachment(app.alloc, image);
            }
            agent.pending_images.clearRetainingCapacity();
        }

        pub fn releasePendingImages(app: *App, agent: *AppAgent) void {
            app.input_runtime.vertical_navigation.reset();
            app.input_runtime.entities.image_tokens.clearRetainingCapacity();
            for (agent.pending_images.items) |image| {
                types.freeImageAttachment(app.alloc, image);
            }
            agent.pending_images.clearRetainingCapacity();
        }

        fn routeComposerShortcutAction(app: *App, agent: *AppAgent, action: input_action.ShortcutAction, max_input_len: usize) !void {
            switch (action) {
                .move => |intent| {
                    switch (intent.kind) {
                        .character_left => {
                            app.input_runtime.vertical_navigation.reset();
                            if (!intent.extend_selection and
                                app.input_runtime.edit_state.selectionRange() == null)
                            {
                                if (try completion_rt.stepBackModelPicker(app, agent)) {
                                    app.shell.render_requests.request(.footer);
                                    return;
                                }
                            }
                            _ = app.input_runtime.moveInputCursor(intent);
                        },
                        .character_right => {
                            app.input_runtime.vertical_navigation.reset();
                            if (!intent.extend_selection and
                                app.input_runtime.edit_state.selectionRange() == null)
                            {
                                switch (try completion_rt.autocompleteInlineCompletion(app, agent, max_input_len)) {
                                    .inserted => {
                                        app.shell.render_requests.request(.footer);
                                        return;
                                    },
                                    .inactive => {},
                                    .limit_exceeded => {
                                        try input_limit_feedback.report(App, app, .composer, 1);
                                        app.shell.render_requests.request(.footer);
                                        return;
                                    },
                                }
                            }
                            _ = app.input_runtime.moveInputCursor(intent);
                        },
                        .word_left,
                        .word_right,
                        .line_start,
                        .line_end,
                        .draft_start,
                        .draft_end,
                        .paragraph_up,
                        .paragraph_down,
                        => {
                            completion_rt.abandonModelPickerOptions(app);
                            _ = app.input_runtime.moveInputCursor(intent);
                        },
                        .visual_up,
                        .visual_down,
                        .page_up,
                        .page_down,
                        => {
                            const direction: visual_layout.Direction = switch (intent.kind) {
                                .visual_up, .page_up => .up,
                                .visual_down, .page_down => .down,
                                else => unreachable,
                            };
                            const delta: i32 = if (direction == .up) -1 else 1;
                            try completion_rt.routeComposerVertical(
                                app,
                                agent,
                                direction,
                                delta,
                                intent.extend_selection,
                                intent.kind == .page_up or intent.kind == .page_down,
                            );
                        },
                    }
                    app.shell.render_requests.request(.footer);
                },
                .select_all => {
                    dismissActiveMenusThenRedraw(app, agent);
                    if (app.input_runtime.selectionState().selectAll()) {
                        app.shell.render_requests.request(.footer);
                    }
                },
                .copy_selection => {
                    if (comptime @hasDecl(App, "clipboard")) {
                        if (input_selection_runtime.copySelection(
                            &app.input_runtime.edit_state,
                            app.clipboard(),
                        ) == .copy_failed) {
                            debug_trace.logf(
                                "input",
                                "composer selection copy preserved reason=clipboard_copy_failed",
                                .{},
                            );
                        }
                    }
                },
                .cut_selection => {
                    if (comptime @hasDecl(App, "clipboard")) {
                        switch (input_selection_runtime.cutSelection(
                            app.alloc,
                            app.input_runtime.selectionState(),
                            &agent.pending_images,
                            app.clipboard(),
                        )) {
                            .cut => {
                                dismissActiveMenusThenRedraw(app, agent);
                                syncCatalogMenus(app, agent);
                                app.shell.render_requests.request(.footer);
                            },
                            .copy_failed => debug_trace.logf(
                                "input",
                                "composer selection cut preserved reason=clipboard_copy_failed",
                                .{},
                            ),
                            .delete_failed => debug_trace.logf(
                                "input",
                                "composer selection cut delete skipped reason=delete_failed",
                                .{},
                            ),
                            .inactive, .copied => {},
                        }
                    }
                },
                .undo => {
                    dismissActiveMenusThenRedraw(app, agent);
                    if (try app.input_runtime.undoState().undo(app.alloc)) {
                        syncCatalogMenus(app, agent);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .redo => {
                    dismissActiveMenusThenRedraw(app, agent);
                    if (try app.input_runtime.undoState().redo(app.alloc)) {
                        syncCatalogMenus(app, agent);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .redraw => {
                    if (!composerPickerSurfaceVisible(app, agent) or
                        activeCatalogMenuOwnsByte(app, agent, 12)) return;
                    if (comptime @hasField(App, "pacer") and
                        @hasField(App, "metrics") and
                        @hasDecl(@TypeOf(app.pacer), "discardDeferredPresentationForVisualEpoch"))
                    {
                        _ = try app_render_runtime.Runtime(App).resetVisualEpoch(app, .ctrl_l);
                    }
                },
                .history_next => {
                    try completion_rt.navigatePromptHistory(app, agent, 1);
                    syncCatalogMenus(app, agent);
                    app.shell.render_requests.request(.footer);
                },
                .delete_backward => {
                    if (app.input_runtime.edit_state.input.items.len > 0) {
                        const picker_policy: composer_insertion.PickerPolicy =
                            if (completion_rt.shouldPreserveModelPickerBackspace(app))
                                .preserve
                            else
                                .clear;
                        const changed = app.input_runtime.deletionState(
                            &agent.pending_images,
                        ).delete(app.alloc, .character_left, picker_policy);
                        if (changed) {
                            app.input_runtime.picker.resetFilePickerIndex();
                            syncCatalogMenus(app, agent);
                            app.shell.render_requests.request(.footer);
                        }
                    }
                },
                .delete_forward => {
                    dismissActiveMenusThenRedraw(app, agent);
                    if (app.input_runtime.deletionState(&agent.pending_images).delete(
                        app.alloc,
                        .character_right,
                        .clear,
                    )) {
                        syncCatalogMenus(app, agent);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_word_left => {
                    dismissActiveMenusThenRedraw(app, agent);
                    completion_rt.abandonModelPickerOptions(app);
                    if (app.input_runtime.deletionState(&agent.pending_images).delete(
                        app.alloc,
                        .word_left,
                        .clear,
                    )) {
                        syncCatalogMenus(app, agent);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_whitespace_word_left => {
                    if (try app.input_runtime.killRingState(&agent.pending_images).delete(
                        app.alloc,
                        .whitespace_word_left,
                    )) {
                        syncCatalogMenus(app, agent);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_word_right => {
                    dismissActiveMenusThenRedraw(app, agent);
                    completion_rt.abandonModelPickerOptions(app);
                    if (app.input_runtime.deletionState(&agent.pending_images).delete(
                        app.alloc,
                        .word_right,
                        .clear,
                    )) {
                        syncCatalogMenus(app, agent);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_to_line_start => {
                    dismissActiveMenusThenRedraw(app, agent);
                    if (try app.input_runtime.killRingState(&agent.pending_images).delete(
                        app.alloc,
                        .line_start,
                    )) {
                        syncCatalogMenus(app, agent);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_to_line_end => {
                    dismissActiveMenusThenRedraw(app, agent);
                    if (try app.input_runtime.killRingState(&agent.pending_images).delete(
                        app.alloc,
                        .line_end,
                    )) {
                        syncCatalogMenus(app, agent);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .yank => {
                    const first_image_id = app.peekNextImageId(agent);
                    switch (try app.input_runtime.killRingState(&agent.pending_images).yank(
                        app.alloc,
                        first_image_id,
                        max_input_len,
                    )) {
                        .inserted => |image_count| {
                            for (0..image_count) |offset| {
                                const committed_id = app.nextImageId(agent);
                                std.debug.assert(committed_id == first_image_id + offset);
                            }
                            syncCatalogMenus(app, agent);
                            app.shell.render_requests.request(.footer);
                        },
                        .inactive => {},
                        .limit_exceeded => |attempted_bytes| try input_limit_feedback.report(
                            App,
                            app,
                            .composer,
                            attempted_bytes,
                        ),
                    }
                },
                .insert_newline => {
                    if (commandSkillsMenuActive(app) or modelMenuActive(app) or sessionMenuActive(agent)) return;
                    dismissActiveMenusThenRedraw(app, agent);
                    switch (try insertComposerSliceBounded(app, agent, "\n", max_input_len, false)) {
                        .inserted => app.shell.render_requests.request(.footer),
                        .inactive => unreachable,
                        .limit_exceeded => try input_limit_feedback.report(App, app, .composer, 1),
                    }
                },
            }
        }

        fn routePrimaryComposerPointerAction(
            app: *App,
            agent: *AppAgent,
            pointer: input_action.MousePointer,
        ) bool {
            if (pointer.kind != .press or pointer.shift or pointer.alt or pointer.ctrl) return false;
            if (!app.shell.footer_viewport.has_frame) return false;

            const prefix_cells: u16 = @intCast(visual_layout.inputPrefix(0).cell_width);
            const position = app.shell.footer_viewport.geometry.inputPointerPosition(
                pointer.row,
                pointer.column,
                prefix_cells,
            ) orelse return false;
            const point = visual_layout.cursorPointAtPosition(.{
                .input = app.input_runtime.edit_state.input.items,
                .cursor = app.input_runtime.edit_state.cursor,
                .terminal_cols = app.shell.layout.cols,
                .pasted_blocks = app.input_runtime.entities.pasted_blocks.items,
                .skill_tokens = app.input_runtime.entities.skill_tokens.items,
            }, position.row_index, position.content_column) orelse return false;

            dismissActiveMenusThenRedraw(app, agent);
            app.input_runtime.vertical_navigation.reset();
            if (app.input_runtime.edit_state.setCursor(point.raw_offset)) {
                app.shell.render_requests.request(.footer);
            }
            return true;
        }

        pub fn expireTerminalInputGestures(app: *App, agent: *AppAgent, now: i64) void {
            expireCtrlCExitArm(app, now);
            expireEscClearArm(app, now);
            expireEscapeInterruptArm(app, agent, now);
        }

        fn terminalDecodeContext(
            app: *App,
            agent: *AppAgent,
            paste_active: bool,
        ) input_action.TerminalDecodeContext {
            if (paste_active) {
                return .{
                    .now_ms = 0,
                    .paste_active = true,
                    .cancel_pending = false,
                    .question_freeform_selected = false,
                };
            }
            return .{
                .now_ms = io_mod.milliTimestamp(),
                .paste_active = false,
                .cancel_pending = interrupt_rt.hasActiveOperation(app, agent),
                .question_freeform_selected = agent.question_prompt.isFreeformSelected(),
            };
        }

        pub fn prepareTerminalDecode(app: *App, agent: *AppAgent) !?input_action.TerminalDecodeContext {
            if (!try app_worker_runtime.Runtime(App).authorizeInteractiveAdmission(app, agent)) return null;
            const paste_active = terminalPasteActive(app);
            return terminalDecodeContext(app, agent, paste_active);
        }

        pub fn handleTerminalInputIngressWithLimits(
            app: *App,
            ingress: input_action.TerminalInputIngress,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !?u8 {
            if (!ingress.has_routing_work()) return null;
            if (terminalIngressCancelsPendingFullTranscriptOpen(ingress)) {
                _ = full_transcript_rt.cancelPendingOpenForInput(app);
            }

            defer completion_rt.reconcileFilePicker(app, agents.screenAgentOf(app));
            // Runs first so the file picker reconciles against a restored draft.
            defer settleModelPickerDraft(app);

            const paste_was_active = terminalPasteActive(app);
            defer {
                const paste_is_active = terminalPasteActive(app);
                if (!paste_was_active and paste_is_active) {
                    shell_runtime.suspendResizeCursorProbeForPaste(&app.terminal_input_runtime.terminal_cursor_probe);
                } else if (paste_was_active and !paste_is_active) {
                    shell_runtime.resumeResizeCursorProbeAfterPaste(
                        &app.terminal_input_runtime.terminal_cursor_probe,
                        io_mod.milliTimestamp(),
                    );
                }
            }

            if (ingress.interrupts_pending_text and
                text_scalar.hasPending(app.input_runtime.text_scalar))
            {
                input_reset.resetPendingTextScalarWithTrace(
                    &app.input_runtime.text_scalar,
                    "interrupted_by_non_text_input",
                );
            }

            // The open agent list takes every key first: the agent it shows
            // is a preview.
            if (ingress.event) |event| {
                if (try routeAgentsMenuInput(app, event)) return ingress.replay_byte_after_routing;
            }

            var replay_byte = ingress.replay_byte_after_routing;
            if (ingress.event) |event| {
                switch (event) {
                    .paste_byte => |byte| {
                        const routed = try routeActivePasteByte(app, byte);
                        std.debug.assert(routed);
                    },
                    .raw => |raw| try handleRawTerminalInputWithLimits(
                        app,
                        agents.screenAgentOf(app),
                        raw,
                        input_limits,
                        max_prompt_history,
                    ),
                    .action => |decoded| {
                        switch (try routeResolvedEscapeAction(
                            app,
                            decoded.action,
                            decoded.composer_shortcut,
                            decoded.question_action,
                            decoded.cancel_pending,
                            input_limits.composer_bytes,
                        )) {
                            .done => {},
                            .remapped_byte => |byte| {
                                std.debug.assert(replay_byte == null);
                                replay_byte = byte;
                            },
                        }
                    },
                }
            }
            return replay_byte;
        }

        pub fn flushPendingEscape(app: *App, agent: *AppAgent, input_escape_timeout_ms: i64) !void {
            const now = io_mod.milliTimestamp();
            expireTerminalInputGestures(app, agent, now);
            const ingress = app.terminal_input_runtime.flushTerminalAction(
                now,
                input_escape_timeout_ms,
                terminalPasteActive(app),
            );
            if (ingress.event) |event| {
                switch (event) {
                    .action => |decoded| {
                        std.debug.assert(decoded.action == .escape);
                        disarmCtrlCExit(app, "semantic_action");
                        defer settleModelPickerDraft(app);
                        try resolveEscape(app, agent, decoded.cancel_pending, now);
                    },
                    .paste_byte, .raw => unreachable,
                }
            }
        }

        pub fn handleTerminalByteAcrossSessionTransition(
            app: *App,
            byte: u8,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !void {
            const session_rt = app_session_runtime.Runtime(App);
            defer session_rt.finishDeferredSessionInputReplay(app, agents.screenAgentOf(app));
            while (true) {
                if (agents.screenAgentOf(app).session_persistence.pending_live_session_policy != null or
                    app.terminal_input_runtime.hasDeferredSessionInput())
                {
                    if (try app.terminal_input_runtime.deferSessionInputByte(app.alloc, byte, input_limits.composer_bytes)) return;
                    if (agents.screenAgentOf(app).session_persistence.pending_live_session_policy != null) {
                        try session_rt.cancelPendingLiveSessionForInputLimit(app, agents.screenAgentOf(app));
                    }
                    app.terminal_input_runtime.allowCurrentDeferredSessionInputForReplay();
                }
                _ = try flushDeferredSessionInput(app, input_limits, max_prompt_history);
                if (app.should_exit) return;
                if (agents.screenAgentOf(app).session_persistence.pending_live_session_policy == null and
                    !app.terminal_input_runtime.hasDeferredSessionInput()) break;
            }
            try handleTerminalByteWithLimits(app, byte, input_limits, max_prompt_history);
        }

        pub fn flushDeferredSessionInput(
            app: *App,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !bool {
            var delivered = false;
            while (!app.should_exit and agents.screenAgentOf(app).session_persistence.pending_live_session_policy == null) {
                const item = app.terminal_input_runtime.takeDeferredSessionInput() orelse break;
                delivered = true;
                switch (item) {
                    .byte => |byte| try handleTerminalByteWithLimits(app, byte, input_limits, max_prompt_history),
                    .delivery_epoch => try settleTerminalPasteDeliveryEpochWithLimits(app, agents.screenAgentOf(app), input_limits),
                }
            }
            if (app.should_exit) {
                const dropped = app.terminal_input_runtime.discardDeferredSessionInput();
                if (dropped > 0) debug_trace.logf("input", "deferred session input dropped bytes={d} reason=quit", .{dropped});
            }
            return delivered;
        }

        pub fn handleTerminalByte(app: *App, byte: u8, max_input_len: usize, max_prompt_history: usize) !void {
            return handleTerminalByteWithLimits(
                app,
                byte,
                paste_framing.InputLimits.single(max_input_len),
                max_prompt_history,
            );
        }

        pub fn handleTerminalByteWithLimits(
            app: *App,
            byte: u8,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !void {
            var context = try prepareTerminalDecode(app, agents.screenAgentOf(app)) orelse return;
            var ingress = app.terminal_input_runtime.decodeTerminalByte(
                byte,
                context,
            );
            while (true) {
                const replay_byte = try handleTerminalInputIngressWithLimits(
                    app,
                    ingress,
                    input_limits,
                    max_prompt_history,
                );
                const replay = replay_byte orelse return;
                context = try prepareTerminalDecode(app, agents.screenAgentOf(app)) orelse return;
                ingress = app.terminal_input_runtime.decodeTerminalByte(replay, context);
            }
        }

        pub fn terminalPasteActive(app: *const App) bool {
            return app.input_runtime.paste.active();
        }

        fn terminalIngressCancelsPendingFullTranscriptOpen(
            ingress: input_action.TerminalInputIngress,
        ) bool {
            const event = ingress.event orelse return false;
            return switch (event) {
                .paste_byte, .raw => true,
                .action => |decoded| decoded.action != .toggle_full_transcript,
            };
        }

        pub fn routeActivePasteIngressByteWithLimits(
            app: *App,
            byte: u8,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !bool {
            if (!terminalPasteActive(app)) return false;
            const replay_byte = try handleTerminalInputIngressWithLimits(
                app,
                .{ .event = .{ .paste_byte = byte } },
                input_limits,
                max_prompt_history,
            );
            std.debug.assert(replay_byte == null);
            return true;
        }

        pub fn settleTerminalPasteDeliveryEpochWithLimits(
            app: *App,
            agent: *AppAgent,
            input_limits: paste_framing.InputLimits,
        ) !void {
            const paste_was_active = terminalPasteActive(app);
            if (!paste_was_active) return;
            defer if (!terminalPasteActive(app)) {
                shell_runtime.resumeResizeCursorProbeAfterPaste(
                    &app.terminal_input_runtime.terminal_cursor_probe,
                    io_mod.milliTimestamp(),
                );
            };

            if (app.input_runtime.paste.active()) {
                const settled = try paste_rt.settlePasteDeliveryEpoch(
                    app,
                    agent,
                    input_limits.forOwner(app.input_runtime.paste.owner),
                );
                if (settled and !app.input_runtime.paste.active()) {
                    syncCatalogMenus(app, agent);
                    settleModelPickerDraft(app);
                }
            }
        }

        pub const prepareFilePicker = completion_rt.prepareFilePicker;
        pub const collectFilePickerFacts = completion_rt.collectFilePickerFacts;
        pub const holdFrameForFileListing = completion_rt.holdFrameForFileListing;
        pub const fileListingHoldPending = completion_rt.fileListingHoldPending;

        pub fn handleByte(app: *App, byte: u8, max_input_len: usize, max_prompt_history: usize) !void {
            return handleTerminalByteWithLimits(
                app,
                byte,
                paste_framing.InputLimits.single(max_input_len),
                max_prompt_history,
            );
        }

        fn routeActivePasteByte(
            app: *App,
            byte: u8,
        ) !bool {
            if (app.input_runtime.paste.active()) {
                try paste_rt.handleActivePasteByte(app, byte);
                return true;
            }
            return false;
        }

        fn handleRawTerminalInputWithLimits(
            app: *App,
            agent: *AppAgent,
            raw: input_action.RawTerminalInput,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !void {
            const byte = raw.byte;
            const max_input_len = input_limits.composer_bytes;
            // Fire the max-level cue only when the slash menu becomes visible.
            const slash_menu_was_visible = slashMenuVisibleForCue(app, agent);
            defer announceSlashMenuOpened(app, agent, slash_menu_was_visible);
            if (try routeActivePasteByte(app, byte)) return;

            if (byte != 3 and byte != 0x1b) disarmCtrlCExit(app, "raw_input");

            // Non-escape input disarms the pending double-Escape clear.
            if (byte != 0x1b) {
                if (disarmEscapeClear(app)) {
                    app.shell.render_requests.request(.footer);
                }
                _ = disarmEscapeInterrupt(app, "raw_input");
            }

            // Ctrl-Z arrives as raw byte 26 (ISIG disabled); kitty remaps here too.
            if (byte == 26) {
                try app.suspendToJobControl();
                return;
            }

            if (comptime @hasDecl(App, "saveConnection")) {
                if (try app_provider_menu_runtime.Runtime(App).routeByte(app, agent, byte)) return;
            }
            // An open list picker takes typing for its filter or input line.
            if (app.input_runtime.list_picker.active and byte != 0x1b) {
                const picker = &app.input_runtime.list_picker;
                switch (byte) {
                    3 => picker.close(app.alloc),
                    '\r', '\n' => try app_commands.promptPickerEnter(app),
                    8, 127 => {
                        picker.line().deleteBack();
                        if (picker.mode == .pick) picker.filterChanged() else picker.problem = null;
                    },
                    21 => {
                        picker.line().clear();
                        if (picker.mode == .pick) picker.filterChanged() else picker.problem = null;
                    },
                    '\t' => try app_commands.promptPickerToggleStar(app),
                    else => {
                        try picker.line().insert(app.alloc, byte);
                        if (picker.mode == .pick) picker.filterChanged() else picker.problem = null;
                    },
                }
                app.shell.render_requests.request(.footer);
                return;
            }
            // The `/mcp` form edits its field in place; the composer stays out of it.
            if (comptime @hasDecl(App, "mcpHostMenuKey")) {
                if (app.mcp.formTyping() and byte != 0x1b and byte != 3) {
                    if (byte == '\r' or byte == '\n' or byte == '\t') {
                        try app.mcpHostMenuKey(.enter);
                    } else {
                        try app.mcp.formByte(byte);
                    }
                    app.shell.render_requests.request(.footer);
                    return;
                }
            }
            if (try full_transcript_rt.routeByte(app, agent, byte)) return;
            if (try routeActiveModalInput(app, agent, raw, input_limits.decision_bytes)) return;
            if (byte >= 0x80) {
                try handleTextByte(app, agent, .composer, byte, max_input_len);
                return;
            }
            if (try routeUpgradeShortcut(app, agent, byte)) return;
            if (try routePickerControlByte(app, agent, byte)) return;

            if (isComposerEditingByte(byte, raw.composer_shortcut) and
                !activeCatalogMenuOwnsByte(app, agent, byte) and
                dismissActiveMenusForComposerEdit(app, agent))
            {
                app.shell.render_requests.request(.footer);
            }
            try handleComposerByte(
                app,
                agent,
                byte,
                raw.composer_shortcut,
                max_input_len,
                max_prompt_history,
            );
        }

        fn routeResolvedEscapeAction(
            app: *App,
            decoded: input_action.Action,
            composer_shortcut: ?input_action.ShortcutAction,
            question_action: ?question_prompt.Action,
            was_cancel_pending: bool,
            max_input_len: usize,
        ) !ResolvedEscapeRoute {
            const resolved = decoded;
            switch (resolved) {
                .remapped_byte, .paste_start, .paste_end, .ignore => {},
                else => disarmCtrlCExit(app, "semantic_action"),
            }
            // Any other semantic key stands down an armed interrupt.
            switch (resolved) {
                .remapped_byte, .paste_start, .paste_end, .ignore, .escape => {},
                else => _ = disarmEscapeInterrupt(app, "semantic_action"),
            }

            if (app.input_runtime.list_picker.active) {
                const picker = &app.input_runtime.list_picker;
                const handled = switch (resolved) {
                    .escape => blk: {
                        if (picker.mode == .input) picker.back() else picker.close(app.alloc);
                        break :blk true;
                    },
                    .cursor_up, .history_up => blk: {
                        if (picker.mode == .pick) picker.move(-1);
                        break :blk true;
                    },
                    .cursor_down, .history_down => blk: {
                        if (picker.mode == .pick) picker.move(1);
                        break :blk true;
                    },
                    .cursor_left, .word_left => blk: {
                        picker.line().left();
                        break :blk true;
                    },
                    .cursor_right, .word_right => blk: {
                        picker.line().right();
                        break :blk true;
                    },
                    .home => blk: {
                        picker.line().home();
                        break :blk true;
                    },
                    .end => blk: {
                        picker.line().end();
                        break :blk true;
                    },
                    .delete_next => blk: {
                        picker.line().deleteForward();
                        break :blk true;
                    },
                    else => false,
                };
                if (handled) {
                    app.shell.render_requests.request(.footer);
                    return .done;
                }
            }
            if (resolved == .escape) {
                if (try full_transcript_rt.routeAction(app, agents.screenAgentOf(app), resolved)) {
                    _ = disarmEscapeInterrupt(app, "full_transcript");
                    return .done;
                }
                // Esc in the `/provider` form leaves the field or list it is on.
                if (comptime @hasDecl(App, "saveConnection")) {
                    if (try app_provider_menu_runtime.Runtime(App).routeAction(app, agents.screenAgentOf(app), resolved)) return .done;
                }
                const now = io_mod.milliTimestamp();
                expireEscClearArm(app, now);
                try resolveEscape(app, agents.screenAgentOf(app), was_cancel_pending, now);
                return .done;
            }

            // The `/mcp` form moves its own cursor.
            if (comptime @hasDecl(App, "mcpHostMenuKey")) {
                if (app.mcp.formTyping()) {
                    const in = &app.mcp.add_form.input;
                    const handled = switch (resolved) {
                        .cursor_left, .word_left => blk: {
                            in.left();
                            break :blk true;
                        },
                        .cursor_right, .word_right => blk: {
                            in.right();
                            break :blk true;
                        },
                        .home => blk: {
                            in.home();
                            break :blk true;
                        },
                        .end => blk: {
                            in.end();
                            break :blk true;
                        },
                        .delete_next => blk: {
                            in.deleteForward();
                            break :blk true;
                        },
                        .delete_to_line_start, .clear_line => blk: {
                            in.clear();
                            break :blk true;
                        },
                        .cursor_up, .history_up => blk: {
                            try app.mcpHostMenuKey(.up);
                            break :blk true;
                        },
                        .cursor_down, .history_down => blk: {
                            try app.mcpHostMenuKey(.down);
                            break :blk true;
                        },
                        else => false,
                    };
                    if (handled) {
                        app.shell.render_requests.request(.footer);
                        return .done;
                    }
                }
            }
            // The `/provider` form takes arrows and editing keys itself.
            if (comptime @hasDecl(App, "saveConnection")) {
                if (try app_provider_menu_runtime.Runtime(App).routeAction(app, agents.screenAgentOf(app), resolved)) return .done;
            }
            if (try full_transcript_rt.routeAction(app, agents.screenAgentOf(app), resolved)) return .done;

            // Ctrl+X opens the agent list whatever the composer holds. It
            // works while a prompt is open: the prompt belongs to the agent
            // on screen, and comes back with it. The open list takes the key
            // first, as Esc, in `routeAgentsMenuInput`.
            if (resolved == .toggle_reasoning) {
                if (comptime @hasField(App, "show_reasoning")) {
                    app.show_reasoning = !app.show_reasoning;
                    try app.writeDomainNotice(.{
                        .topic = "thinking",
                        .tone = .neutral,
                        .body = if (app.show_reasoning) "Reasoning is shown. Cmd+O hides it." else "Reasoning is hidden; ctrl+o still shows it. Cmd+O shows it again.",
                    }, true);
                    app.shell.render_requests.request(.footer);
                }
                return .done;
            }
            if (resolved == .open_agent_list) {
                if (comptime @hasDecl(App, "openAgentsMenu")) {
                    if (app.shell.fullTranscriptActive()) return .done;
                    if (!app_agents_runtime.Runtime(App).hasAnotherAgent(app)) return .done;
                    dismissActiveMenusThenRedraw(app, agents.screenAgentOf(app));
                    // The list sets the draft aside itself, so the model
                    // picker's goes back to the composer first.
                    restoreModelPickerDraft(app);
                    try app.openAgentsMenu();
                }
                return .done;
            }

            if (resolved == .paste_start) {
                dismissActiveMenusThenRedraw(app, agents.screenAgentOf(app));
                paste_rt.beginPaste(app, agents.screenAgentOf(app), max_input_len);
                return .done;
            }

            if (resolved == .paste_end) {
                return .done;
            }

            switch (resolved) {
                .remapped_byte => |byte| return .{ .remapped_byte = byte },
                else => {},
            }

            // The open agent list covers the prompt, and its search box
            // takes the keys it passes on.
            if (agents.screenAgentOf(app).question_prompt.isActive() and !agentsMenuActive(app)) {
                try question_rt.routeQuestionEscapeAction(
                    app,
                    agents.screenAgentOf(app),
                    resolved,
                    question_action,
                );
                return .done;
            }

            if (resolved == .mouse_pointer and
                routePrimaryComposerPointerAction(app, agents.screenAgentOf(app), resolved.mouse_pointer))
            {
                return .done;
            }

            if (activeCompactCommandMenu(app)) |menu| {
                try routeCompactCommandMenuEscapeAction(app, menu, resolved);
                return .done;
            }

            if (settingsMenuActive(app) and
                (resolved == .cursor_left or resolved == .cursor_right))
            {
                try changeSettingsMenuSelection(
                    app,
                    agents.screenAgentOf(app),
                    if (resolved == .cursor_left) -1 else 1,
                );
                return .done;
            }

            if (resolved == .cursor_left and try backMcpHostMenuScreen(app)) return .done;
            if (resolved == .cursor_right and try enterMcpHostMenuItem(app)) return .done;

            if (try full_transcript_rt.routeComposerAction(app, agents.screenAgentOf(app), resolved)) return .done;

            if (composer_shortcut) |action| {
                try routeComposerShortcutAction(app, agents.screenAgentOf(app), action, max_input_len);
                return .done;
            }

            switch (resolved) {
                .history_up => {
                    try completion_rt.routeModifiedHistory(app, agents.screenAgentOf(app), .up, -1);
                    app.shell.render_requests.request(.footer);
                },
                .history_down => {
                    try completion_rt.routeModifiedHistory(app, agents.screenAgentOf(app), .down, 1);
                    app.shell.render_requests.request(.footer);
                },
                .cursor_up => {
                    try completion_rt.routePlainVertical(app, agents.screenAgentOf(app), .up, -1);
                    app.shell.render_requests.request(.footer);
                },
                .cursor_down => {
                    try completion_rt.routePlainVertical(app, agents.screenAgentOf(app), .down, 1);
                    app.shell.render_requests.request(.footer);
                },
                .cursor_left,
                .cursor_right,
                .word_left,
                .word_right,
                .home,
                .end,
                .delete_next,
                .delete_word_left,
                .delete_word_right,
                .delete_to_line_start,
                .delete_to_line_end,
                .insert_newline,
                .composer_shortcut,
                .toggle_full_transcript,
                .toggle_reasoning,
                .open_agent_list,
                => unreachable,
                .page_up,
                .page_down,
                .mouse_wheel,
                .mouse_pointer,
                => {},
                .clear_line => {
                    dismissActiveMenusThenRedraw(app, agents.screenAgentOf(app));
                    if (draftHasState(app, agents.screenAgentOf(app))) {
                        clearDraftState(app, agents.screenAgentOf(app), "clear_line");
                        app.shell.render_requests.request(.footer);
                    }
                },
                .back_tab => {
                    if (cycleHelpMenuCategory(app, -1) or cycleSettingsMenuCategory(app, -1)) {
                        app.shell.render_requests.request(.footer);
                    } else if (try toggleSessionPickerScopeIfActive(app, agents.screenAgentOf(app))) {
                        app.shell.render_requests.request(.footer);
                    } else if (cycleModelMenuProvider(app, -1) or cycleSkillsMenuSource(app, -1)) {
                        app.shell.render_requests.request(.footer);
                    }
                    // Outside menus Shift+Tab does nothing.
                },
                .open_all_sessions => {
                    if (comptime agents.hasAgentField(App, "session_persistence") and
                        true)
                    {
                        if (settingsMenuActive(app) or helpMenuActive(app) or skillsMenuActive(app) or modelMenuActive(app)) return .done;
                        if (try refuseSessionActionWithDraft(app, agents.screenAgentOf(app), "submit or clear the draft before switching sessions")) return .done;
                        dismissActiveMenusThenRedraw(app, agents.screenAgentOf(app));
                        try app_session_runtime.Runtime(App).openAllSessionPicker(app, agents.screenAgentOf(app));
                        app.shell.render_requests.request(.footer);
                    }
                },
                .open_model_catalog => {
                    if (comptime @hasField(App, "model_cache")) {
                        // A second Ctrl+P backs out of the shortcut's flow
                        // from the catalog or its inline effort and fast stages.
                        if (exitModelPickerShortcutIfActive(app)) return .done;
                        if (modelMenuActive(app)) {
                            _ = closeModelMenu(app, true);
                            app.shell.render_requests.request(.footer);
                            return .done;
                        }
                        if (modelPickerShortcutBlocked(app, agents.screenAgentOf(app))) return .done;
                        try openModelPickerShortcut(app);
                    }
                },
                .cycle_effort => {
                    // Ctrl+T sets the effort of the agent on screen, as
                    // `/effort` does.
                    const agent = agents.screenAgentOf(app);
                    if (effortCycleShortcutBlocked(app, agent)) return .done;
                    // The `/effort` menu marks the level that was in use
                    // when it opened.
                    if (cancelEffortMenu(app)) {
                        debug_trace.logf("input", "effort menu closed without applying its highlight reason=ctrl_t_cycle", .{});
                    }
                    try session_commands.Commands(App).cycleEffort(app, agent);
                    app.shell.render_requests.request(.footer);
                },
                .paste_start => dismissActiveMenusThenRedraw(app, agents.screenAgentOf(app)),
                .paste_end => {},
                .remapped_byte => unreachable,
                .escape => unreachable,
                .ignore => {},
            }
            return .done;
        }

        fn routePickerControlByte(app: *App, agent: *AppAgent, byte: u8) !bool {
            if (!composerPickerSurfaceVisible(app, agent)) return false;
            const delta = pickerControlDelta(byte) orelse return false;
            if (!try routeVisiblePickerMove(app, agent, delta)) return false;
            app.input_runtime.vertical_navigation.reset();
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn pickerControlDelta(byte: u8) ?i32 {
            return switch (byte) {
                10 => 1,
                11 => -1,
                else => null,
            };
        }

        fn composerPickerSurfaceVisible(app: *App, agent: *AppAgent) bool {
            if (agent.question_prompt.isActive()) return false;
            if (comptime @hasField(App, "terminal")) {
                if (app.terminal.fullTranscriptScreenActive()) return false;
            }
            return true;
        }

        fn routeUpgradeShortcut(app: *App, agent: *AppAgent, byte: u8) !bool {
            if (byte != ctrl_g_upgrade_byte) return false;
            if (comptime @hasDecl(App, "applyReadyUpgradeShortcut")) {
                try app.applyReadyUpgradeShortcut(agent);
            }
            return true;
        }

        fn routeActiveModalInput(
            app: *App,
            agent: *AppAgent,
            raw: input_action.RawTerminalInput,
            max_input_len: usize,
        ) !bool {
            const byte = raw.byte;
            // The open agent list covers the prompt; its search box takes the
            // bytes it passes on.
            if (agentsMenuActive(app)) return false;
            if (agent.question_prompt.isActive() and byte == ctrl_g_upgrade_byte) {
                _ = try routeUpgradeShortcut(app, agent, byte);
                return true;
            }
            if (agent.question_prompt.isActive()) {
                if (byte >= 0x80) {
                    if (agent.question_prompt.isFreeformSelected()) {
                        try handleTextByte(app, agent, .question_freeform, byte, max_input_len);
                    } else {
                        input_reset.resetPendingTextScalarWithTrace(
                            &app.input_runtime.text_scalar,
                            "question_decision_active",
                        );
                    }
                    return true;
                }
                if (raw.question_action) |action| {
                    switch (try question_rt.handleQuestionActionBounded(
                        app,
                        agent,
                        action,
                        max_input_len,
                    )) {
                        .consumed => app.input_runtime.input_limit_rejection = input_limit_rejection.clear(),
                        .ignored => {},
                        .limit_exceeded => try input_limit_feedback.report(App, app, .question_freeform, 1),
                    }
                }
                return true;
            }
            if (try routeMcpHostMenuByte(app, byte)) return true;
            if (try routeForkQuestionByte(app, agent, byte)) return true;
            if (activeCompactCommandMenu(app)) |menu| {
                if (byte >= 0x80) {
                    input_reset.resetPendingTextScalarWithTrace(
                        &app.input_runtime.text_scalar,
                        "compact_command_menu_active",
                    );
                    return true;
                }
                switch (byte) {
                    '\r' => try submitCompactCommandMenuSelection(app, menu, max_input_len),
                    10 => {
                        _ = moveCompactCommandMenu(app, menu, 1);
                        app.shell.render_requests.request(.footer);
                    },
                    11 => {
                        _ = moveCompactCommandMenu(app, menu, -1);
                        app.shell.render_requests.request(.footer);
                    },
                    else => {},
                }
                return true;
            }
            return false;
        }

        fn handleTextByte(app: *App, agent: *AppAgent, owner: text_scalar.Owner, byte: u8, max_input_len: usize) !void {
            const transition = text_scalar.advance(app.input_runtime.text_scalar, owner, byte);
            app.input_runtime.text_scalar = transition.next;
            const step = transition.step;
            if (step.dropped) |drop| {
                debug_trace.logf(
                    "input",
                    "text scalar dropped owner={s} bytes={d} reason={s}",
                    .{ @tagName(drop.owner), drop.bytes, @tagName(drop.reason) },
                );
            }
            const scalar = step.scalar orelse return;
            const bytes = scalar.slice();
            switch (scalar.owner) {
                .question_freeform => switch (try agent.question_prompt.insertFreeformSlice(app.alloc, bytes, max_input_len)) {
                    .inserted => {
                        app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
                        app.shell.render_requests.request(.modal);
                    },
                    .inactive => {},
                    .limit_exceeded => try input_limit_feedback.report(App, app, .question_freeform, bytes.len),
                },
                .composer => {
                    if (!app.input_runtime.replacementState(&agent.pending_images).canReplaceSelectionOrInsert(
                        bytes.len,
                        max_input_len,
                    )) {
                        try input_limit_feedback.report(App, app, .composer, bytes.len);
                        return;
                    }
                    if (dismissActiveMenusForComposerEdit(app, agent)) {
                        app.shell.render_requests.request(.footer);
                    }
                    switch (try insertComposerSliceBounded(
                        app,
                        agent,
                        bytes,
                        max_input_len,
                        completion_rt.shouldPreserveModelPickerInsert(app),
                    )) {
                        .inserted => {},
                        .inactive => unreachable,
                        .limit_exceeded => {
                            try input_limit_feedback.report(App, app, .composer, bytes.len);
                            return;
                        },
                    }
                    app.input_runtime.picker.resetFilePickerIndex();
                    syncCatalogMenus(app, agent);
                    app.shell.render_requests.request(.footer);
                },
            }
        }

        fn handleComposerByte(
            app: *App,
            agent: *AppAgent,
            byte: u8,
            composer_shortcut: ?input_action.ShortcutAction,
            max_input_len: usize,
            max_prompt_history: usize,
        ) !void {
            switch (byte) {
                3 => {
                    try handleSemanticCtrlC(app, agent);
                },
                4 => {
                    try handleSemanticCtrlD(app, agent, max_input_len);
                },
                '\t' => {
                    if (cycleHelpMenuCategory(app, 1) or cycleSettingsMenuCategory(app, 1)) {
                        app.shell.render_requests.request(.footer);
                    } else if (try toggleSessionPickerScopeIfActive(app, agent)) {
                        app.shell.render_requests.request(.footer);
                    } else if (cycleModelMenuProvider(app, 1) or cycleSkillsMenuSource(app, 1)) {
                        app.shell.render_requests.request(.footer);
                    } else if (picker_state.isBareModelCommandAtCursor(&app.input_runtime.edit_state)) {
                        try completion_rt.openCurrentModelPicker(app);
                    } else if (picker_state.isBareEffortCommandAtCursor(&app.input_runtime.edit_state)) {
                        try completion_rt.openCurrentEffortPicker(app);
                    } else if (completion_rt.hasFileQuery(app)) {
                        if ((try completion_rt.autocompleteFilePickerSelection(app, agent, max_input_len)) == .limit_exceeded) {
                            try input_limit_feedback.report(App, app, .composer, 1);
                        }
                        app.shell.render_requests.request(.footer);
                    } else if (!commandSkillsMenuActive(app) and completion_rt.hasModelQuery(app)) {
                        try completion_rt.autocompleteModelPickerSelection(app);
                    } else if (completion_rt.visibleInlineCompletion(app, agent) != null) {
                        if ((try completion_rt.autocompleteInlineCompletion(app, agent, max_input_len)) == .limit_exceeded) {
                            try input_limit_feedback.report(App, app, .composer, 1);
                        }
                        app.shell.render_requests.request(.footer);
                    } else if (!(agent.stream.active and app.input_runtime.picker.isModelShapedInput(&app.input_runtime.edit_state))) {
                        const count = completion_rt.visibleSlashCompletionCount(app, agent);
                        if (count > 0) {
                            const items = app.input_runtime.edit_state.input.items;
                            const prefix = command_specs.slashCompletionPrefix(
                                app.slashRegistry(),
                                items,
                            ) orelse return;
                            const idx = app.input_runtime.picker.slash_completion_index % count;
                            if (try bindSelectedSlashSkill(app, idx)) {
                                app.shell.render_requests.request(.footer);
                            } else if (command_specs.nthSlashCompletion(app.slashRegistry(), prefix, idx)) |completion| {
                                if (command_specs.slashCompletionHasArgs(app.slashRegistry(), completion)) {
                                    try typeCommandAwaitingArgument(app, completion);
                                } else {
                                    try app.input_runtime.textReplacementState().replace(app.alloc, completion);
                                    app.shell.render_requests.request(.footer);
                                }
                            }
                        }
                    }
                },
                ' ' => {
                    dismissMentionSkillsMenuForSpace(app);
                    if (app.input_runtime.edit_state.selectionRange() == null and
                        !commandSkillsMenuActive(app) and
                        completion_rt.hasModelQuery(app))
                    {
                        if (try completion_rt.advanceModelPickerOnSpace(app, agent)) {
                            app.shell.render_requests.request(.footer);
                        }
                    } else {
                        switch (try insertComposerSliceBounded(app, agent, " ", max_input_len, false)) {
                            .inserted => {
                                syncCatalogMenus(app, agent);
                                app.shell.render_requests.request(.footer);
                            },
                            .inactive => unreachable,
                            .limit_exceeded => try input_limit_feedback.report(App, app, .composer, 1),
                        }
                    }
                },
                22 => {
                    if (paste_rt.modelPickerBorrowsComposer(app)) {
                        debug_trace.logf("input", "image attach skipped reason=model_picker_borrows_composer", .{});
                        return;
                    }
                    try image_commands.Commands(App).attachClipboard(app);
                },
                24 => {
                    return;
                },
                '\r' => {
                    if (try submitEffortMenuSelection(app, agent)) return;
                    if (try submitAgentsMenuSelection(app)) return;
                    if (try submitSettingsMenuSelection(app, agent)) return;
                    if (try submitHelpMenuSelection(app, max_input_len, max_prompt_history)) return;
                    if (try submitMcpHostMenu(app)) return;
                    if (try submitModelMenuSelection(app, agent)) return;
                    if (try submitSkillsMenuSelection(app, max_input_len)) return;
                    if (try submitSlashPickerSelection(app, agent)) return;
                    if (try submitSessionPickerSelection(app, agent)) return;
                    if (try submitForkMenuSelection(app, agent, null, max_input_len)) return;
                    if (try completion_rt.submitFilePickerOnEnter(app, agent, max_input_len)) |result| {
                        if (result == .limit_exceeded) {
                            try input_limit_feedback.report(App, app, .composer, 1);
                        }
                        app.shell.render_requests.request(.footer);
                        return;
                    }
                    if (picker_state.isBareModelCommandAtCursor(&app.input_runtime.edit_state)) {
                        try openModelBrowseCatalog(app);
                        return;
                    }
                    if (completion_rt.hasModelQuery(app)) {
                        if (try completion_rt.submitModelPicker(app, agent)) return;
                    }
                    if (try submitExplicitModelSelection(
                        app,
                        agent,
                        resolveExplicitModelSelection(app, app.input_runtime.edit_state.input.items),
                    )) return;
                    // A Ctrl+P flow's borrowed composer holds only a picker
                    // query. Submitting it as a prompt or command would act
                    // on the stashed draft's pending images.
                    if (app.input_runtime.model_picker_draft != null) {
                        debug_trace.logf("input", "submit skipped reason=model_picker_borrows_composer", .{});
                        app.shell.render_requests.request(.footer);
                        return;
                    }
                    if (app.input_runtime.lineContinuationState().replaceBackslashBeforeCursorWithNewline(app.alloc)) {
                        app.shell.render_requests.request(.footer);
                        return;
                    }
                    // Enter on an empty composer answers a request that waits
                    // for the user, which resends it.
                    if (comptime @hasDecl(@TypeOf(agent.worker), "requestRecoveryContinue")) {
                        if (recoveryWaitsForUser(app) and
                            std.mem.trim(u8, app.input_runtime.edit_state.input.items, " \t\r\n").len == 0)
                        {
                            agent.worker.requestRecoveryContinue();
                            debug_trace.logf("input", "event=recovery_continue", .{});
                            app.shell.render_requests.request(.footer);
                            return;
                        }
                    }
                    // With no connection there is no model to send a prompt
                    // to. Slash commands still run, so /provider stays reachable.
                    if (comptime @hasDecl(@TypeOf(app.auth), "credentialSource")) {
                        const typed = std.mem.trimStart(u8, app.input_runtime.edit_state.input.items, " \t\r\n");
                        if (app.auth.credentialSource() == null and !std.mem.startsWith(u8, typed, "/")) {
                            debug_trace.logf("input", "submit skipped reason=no_model", .{});
                            app.shell.render_requests.request(.footer);
                            return;
                        }
                    }
                    debug_trace.logf("input", "submit requested stream_active={s} queued={d} input_bytes={d}", .{ if (agent.stream.active) "true" else "false", agent.worker.queuedPromptCount(), app.input_runtime.edit_state.input.items.len });
                    try submit_rt.submit(app, max_prompt_history);
                },
                else => {
                    if (composer_shortcut) |action| {
                        try routeComposerShortcutAction(app, agent, action, max_input_len);
                        return;
                    }
                    if (byte >= 32 and byte != 127) {
                        const insertion_start = if (app.input_runtime.edit_state.selectionRange()) |selection|
                            selection.start
                        else
                            app.input_runtime.edit_state.cursor;
                        if (byte == '$' and !file_picker_path.contains_position(app.input_runtime.edit_state.input.items, insertion_start) and !helpMenuActive(app) and !commandSkillsMenuActive(app) and !modelMenuActive(app)) {
                            if ((try insertComposerSliceBounded(app, agent, &.{byte}, max_input_len, false)) == .limit_exceeded) {
                                try input_limit_feedback.report(App, app, .composer, 1);
                                return;
                            }
                            app.input_runtime.picker.resetInlinePickerEpisode();
                            if (comptime @hasField(App, "skills")) {
                                app.skills.openMenuWithQuery(.dollar, .{ .start = insertion_start, .end = insertion_start + 1 }, "");
                            }
                            app.input_runtime.picker.resetFilePickerIndex();
                            app.shell.render_requests.request(.footer);
                            return;
                        }
                        const result = try insertComposerSliceBounded(
                            app,
                            agent,
                            &.{byte},
                            max_input_len,
                            completion_rt.shouldPreserveModelPickerInsert(app),
                        );
                        if (result == .limit_exceeded) {
                            try input_limit_feedback.report(App, app, .composer, 1);
                            return;
                        }
                        app.input_runtime.picker.resetFilePickerIndex();
                        syncCatalogMenus(app, agent);
                        app.shell.render_requests.request(.footer);
                    }
                },
            }
        }

        /// While the picker borrows the composer, destructive global gestures
        /// back out of the picker and restore the draft instead of acting on
        /// the empty borrowed composer (clearing draft state would free the
        /// stashed draft's pending image payloads; exiting would hand off an
        /// empty composer). The restore also covers the inline effort and
        /// fast stages, which borrow the composer after the menu closes.
        fn exitModelPickerShortcutIfActive(app: *App) bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            if (app.input_runtime.model_picker_draft == null) return false;
            _ = closeModelMenu(app, true);
            restoreModelPickerDraft(app);
            app.shell.render_requests.request(.footer);
            return true;
        }

        /// Ctrl+C closes the MCP menu from any screen instead of arming the
        /// exit; its filter lives in the composer, so that goes too, as when
        /// Esc closes the list.
        fn exitMcpHostMenuIfActive(app: *App) bool {
            if (comptime !@hasDecl(App, "mcpHostMenuKey")) return false;
            if (!mcpHostMenuActive(app)) return false;
            app.mcp.closeHostMenu();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn handleSemanticCtrlC(app: *App, agent: *AppAgent) !void {
            if (exitModelPickerShortcutIfActive(app)) return;
            if (exitMcpHostMenuIfActive(app)) return;
            if (agent.stream.active and draftHasState(app, agent)) {
                clearDraftState(app, agent, "ctrl_c");
                app.shell.render_requests.request(.footer);
                return;
            }

            const now = io_mod.milliTimestamp();
            const transition = gesture_state.pressCtrlCExit(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.result == .activated) {
                debug_trace.logf("shutdown", "ctrl_c_exit_activated", .{});
                app_session_runtime.Runtime(App).requestResumeHandoff(agent);
                app.should_exit = true;
                return;
            }

            debug_trace.logf("input", "ctrl_c_exit_hint_armed", .{});

            if (interrupt_rt.hasActiveOperation(app, agent)) {
                try interrupt_rt.cancelActiveOperation(app, agent);
                app.shell.render_requests.request(.footer);
                return;
            }

            if (comptime @hasDecl(App, "cancelPendingSubmission")) {
                if (App.cancelPendingSubmission(app, agent)) return;
            }

            if (draftHasState(app, agent)) clearDraftState(app, agent, "ctrl_c");
            app.shell.render_requests.request(.footer);
        }

        fn draftHasState(app: *App, agent: *AppAgent) bool {
            return app.input_runtime.edit_state.input.items.len > 0 or
                app.input_runtime.entities.pasted_blocks.items.len > 0 or
                agent.pending_images.items.len > 0;
        }

        fn refuseSessionActionWithDraft(app: *App, agent: *AppAgent, body: []const u8) !bool {
            if (!draftHasState(app, agent)) return false;
            try app.writeDomainNotice(.{
                .topic = "session",
                .tone = .neutral,
                .body = body,
            }, true);
            return true;
        }

        fn clearDraftState(app: *App, agent: *AppAgent, reason: []const u8) void {
            debug_trace.logf(
                "input",
                "draft cleared reason={s} input_bytes={d} pasted_blocks={d} images={d}",
                .{
                    reason,
                    app.input_runtime.edit_state.input.items.len,
                    app.input_runtime.entities.pasted_blocks.items.len,
                    agent.pending_images.items.len,
                },
            );
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.clearPendingImages(agent);
            syncCatalogMenus(app, agent);
        }

        fn handleSemanticCtrlD(app: *App, agent: *AppAgent, max_input_len: usize) !void {
            if (exitModelPickerShortcutIfActive(app)) return;
            if (app.input_runtime.edit_state.input.items.len > 0) {
                try routeComposerShortcutAction(app, agent, .delete_forward, max_input_len);
                return;
            }
            if (agent.stream.active) return;
            app_session_runtime.Runtime(App).requestResumeHandoff(agent);
            app.should_exit = true;
        }

        fn isComposerEditingByte(
            byte: u8,
            composer_shortcut: ?input_action.ShortcutAction,
        ) bool {
            if (composer_shortcut) |shortcut| {
                return switch (shortcut) {
                    .redraw => false,
                    else => true,
                };
            }
            return switch (byte) {
                ' ', 22 => true,
                else => byte >= 32 and byte != 127,
            };
        }

        fn activeCatalogMenuOwnsByte(app: *App, agent: *AppAgent, byte: u8) bool {
            if (settingsMenuActive(app)) return true;
            // Typing filters its list.
            if (mcpHostMenuActive(app)) return true;
            if (helpMenuActive(app)) return true;
            if (modelMenuActive(app)) return true;
            if (sessionMenuActive(agent)) return true;
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menu.active) return false;
            return byte == ' ' or commandSkillsMenuActive(app);
        }

        fn submitSessionPickerSelection(app: *App, agent: *AppAgent) !bool {
            if (comptime !agents.hasAgentField(App, "session_persistence")) return false;
            if (!agent.session_persistence.session_picker.active) return false;

            if (app.loadMoreSessionPicker(agent) catch |err| {
                const notice = try app.alloc.print(
                    "unable to load more saved sessions: {s}",
                    .{@errorName(err)},
                );
                defer app.alloc.free(notice);
                try app.writeDomainNotice(.{ .topic = "session", .tone = .@"error", .body = notice }, true);
                app.shell.render_requests.request(.footer);
                return true;
            }) return true;

            if (agent.session_persistence.session_picker.selectedId() == null) return true;

            _ = app.resumeSelectedSession(agent) catch |err| {
                const picker = &agent.session_persistence.session_picker;
                debug_trace.logf(
                    "session",
                    "picker resume failed err={s} picker_active={s}",
                    .{ @errorName(err), if (picker.active) "true" else "false" },
                );
                if (picker.active) {
                    picker.selection_failure = classifyResumeFailure(err);
                } else {
                    try app.writeDomainNotice(.{
                        .topic = "session",
                        .tone = .@"error",
                        .body = config_runtime.sessionConnectionNotice(err) orelse "Unable to resume selected session.",
                    }, true);
                }
                app.shell.render_requests.request(.footer);
                return true;
            };
            return true;
        }

        /// Shows the instance the list has selected.
        fn submitAgentsMenuSelection(app: *App) !bool {
            if (comptime !@hasDecl(App, "openAgentsMenu")) return false;
            return app_agents_runtime.Runtime(App).submitMenu(app);
        }

        fn agentsMenuActive(app: *App) bool {
            if (comptime !@hasDecl(App, "openAgentsMenu")) return false;
            return app_agents_runtime.Runtime(App).menuActive(app);
        }

        /// Closes the agent list, keeping the agent it shows.
        fn cancelAgentsMenu(app: *App) bool {
            if (comptime !@hasDecl(App, "openAgentsMenu")) return false;
            return app_agents_runtime.Runtime(App).closeMenu(app);
        }

        /// Closes the agent list and shows again the agent it opened on.
        fn backAgentsMenu(app: *App) !bool {
            if (comptime !@hasDecl(App, "openAgentsMenu")) return false;
            return app_agents_runtime.Runtime(App).backMenu(app);
        }

        /// A close key on an empty search in the agent list: arms, then
        /// closes, the selected row, unless its run edited the search.
        fn pressAgentsMenuClose(app: *App, key: app_agents_runtime.CloseKey) !bool {
            if (comptime !@hasDecl(App, "openAgentsMenu")) return false;
            return app_agents_runtime.Runtime(App).pressCloseKey(app, key);
        }

        /// The close key `event` is, or null for any other event. Backspace is
        /// the bytes 127 and 8, as a terminal sends them or as Kitty's
        /// `ESC[127u` is replayed; Delete is the forward Delete key.
        fn agentsMenuCloseKey(event: input_action.TerminalInputEvent) ?app_agents_runtime.CloseKey {
            return switch (event) {
                .raw => |raw| if (raw.byte == 127 or raw.byte == 8) .backspace else null,
                .action => |decoded| switch (decoded.action) {
                    .remapped_byte => |byte| if (byte == 127 or byte == 8) .backspace else null,
                    .delete_next => .delete,
                    else => null,
                },
                else => null,
            };
        }

        /// Whether `event` is a key press. A mouse report, a sequence spark
        /// ignores, and a paste's byte are not, so none of them ends a run of
        /// a close key that a stray report would otherwise break.
        fn agentsMenuKeyPress(event: input_action.TerminalInputEvent) bool {
            return switch (event) {
                .paste_byte => false,
                .raw => true,
                .action => |decoded| switch (decoded.action) {
                    .ignore, .mouse_wheel, .mouse_pointer => false,
                    else => true,
                },
            };
        }

        fn noteAgentsMenuKeyPress(app: *App, pressed: ?app_agents_runtime.CloseKey) void {
            if (comptime !@hasDecl(App, "openAgentsMenu")) return;
            app_agents_runtime.Runtime(App).noteKeyPress(app, pressed);
        }

        fn noteAgentsMenuSearchEdit(app: *App, key: app_agents_runtime.CloseKey) void {
            if (comptime !@hasDecl(App, "openAgentsMenu")) return;
            app_agents_runtime.Runtime(App).noteSearchEditKey(app, key);
        }

        /// The composer, the open agent list's search box, holds a search.
        fn agentsMenuSearching(app: *App) bool {
            return app.input_runtime.edit_state.input.items.len > 0;
        }

        fn clearAgentsMenuSearch(app: *App) void {
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            syncAgentsMenu(app);
        }

        fn syncAgentsMenu(app: *App) void {
            if (comptime !@hasDecl(App, "openAgentsMenu")) return;
            app_agents_runtime.Runtime(App).searchChanged(app);
        }

        fn disarmAgentsMenuClose(app: *App) void {
            if (comptime !@hasDecl(App, "openAgentsMenu")) return;
            app_agents_runtime.Runtime(App).disarmClose(app);
        }

        /// While the agent list is open it takes every key, ahead of the
        /// prompts and composer of the agent it shows, which is a preview: ↑
        /// and ↓ move and show the agent they land on, ↑ on the first row
        /// closes the list, Enter keeps the agent shown, Backspace or Delete
        /// arms and then closes it, and Esc, Ctrl+X, and Ctrl+C go back to
        /// the agent the list opened on. The composer is its search box, with
        /// the agent's draft set aside: typing, Left, and Right edit it, and
        /// the list shows the match the highlight moves to; while it holds a
        /// search, Backspace and Delete edit it too and Esc clears it. A run
        /// of presses of one of them that edited the search never arms a
        /// close, however many go on past the emptied search, until a key
        /// other than it is pressed. A paste closes the list, keeping the
        /// agent shown, and lands in its draft; mouse input passes through.
        /// Any other key does nothing, so none answers the prompt behind the
        /// list. Returns whether the list took `event`.
        fn routeAgentsMenuInput(app: *App, event: input_action.TerminalInputEvent) !bool {
            if (!agentsMenuActive(app)) return false;
            const agent = agents.screenAgentOf(app);
            const close_key = agentsMenuCloseKey(event);
            if (close_key == null) disarmAgentsMenuClose(app);
            if (agentsMenuKeyPress(event)) noteAgentsMenuKeyPress(app, close_key);
            switch (event) {
                // A paste closes the list before its bytes arrive.
                .paste_byte => return false,
                .raw => |raw| switch (raw.byte) {
                    '\r' => _ = try submitAgentsMenuSelection(app),
                    127, 8 => if (agentsMenuSearching(app)) {
                        noteAgentsMenuSearchEdit(app, .backspace);
                        return false;
                    } else {
                        _ = try pressAgentsMenuClose(app, .backspace);
                    },
                    3, 24 => _ = try backAgentsMenu(app),
                    ' '...'~' => return false,
                    10 => _ = try completion_rt.routeAgentsMenuMove(app, agent, 1),
                    11 => _ = try completion_rt.routeAgentsMenuMove(app, agent, -1),
                    else => if (raw.byte >= 0x80) return false,
                },
                .action => |decoded| switch (decoded.action) {
                    .cursor_up, .history_up => _ = try completion_rt.routeAgentsMenuMove(app, agent, -1),
                    .cursor_down, .history_down => _ = try completion_rt.routeAgentsMenuMove(app, agent, 1),
                    .delete_next => if (agentsMenuSearching(app)) {
                        noteAgentsMenuSearchEdit(app, .delete);
                        return false;
                    } else {
                        _ = try pressAgentsMenuClose(app, .delete);
                    },
                    .cursor_left, .cursor_right => return false,
                    .escape => {
                        if (agentsMenuSearching(app)) clearAgentsMenuSearch(app) else _ = try backAgentsMenu(app);
                        _ = disarmEscapeClear(app);
                    },
                    .open_agent_list => {
                        _ = try backAgentsMenu(app);
                        _ = disarmEscapeClear(app);
                    },
                    // A paste closes the list on the agent shown and lands in
                    // its draft.
                    .paste_start => {
                        _ = cancelAgentsMenu(app);
                        return false;
                    },
                    // Replayed as the byte it stands for, which comes back here.
                    .remapped_byte, .mouse_wheel, .mouse_pointer => return false,
                    else => {},
                },
            }
            return true;
        }

        /// Forks before the selected prompt and puts its text in the composer.
        /// Enter on `/fork`'s prompts (`bring` null), or the answer to its
        /// question whether the fork takes copies of the subagents (D97).
        fn submitForkMenuSelection(app: *App, agent: *AppAgent, bring: ?bool, max_input_len: usize) !bool {
            if (comptime !@hasDecl(App, "submitForkMenu")) return false;
            if (!forkMenuActive(agent)) return false;
            const forked = app.submitForkMenu(agent, bring) catch |err| {
                debug_trace.logf("session", "fork failed err={s}", .{@errorName(err)});
                try app.writeDomainNotice(.{
                    .topic = "session",
                    .tone = .@"error",
                    .body = "Unable to fork the session.",
                }, true);
                app.shell.render_requests.request(.footer);
                return true;
            };
            // The menu asks its question first.
            const prompt = forked orelse {
                app.shell.render_requests.request(.footer);
                return true;
            };
            defer app.alloc.free(prompt);
            if (prompt.len > max_input_len) {
                debug_trace.logf("input", "fork prompt not restored bytes={d} reason=input_limit", .{prompt.len});
                return true;
            }
            try app.input_runtime.textReplacementState().replace(app.alloc, prompt);
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn commandSkillsMenuActive(app: *App) bool {
            if (comptime !@hasField(App, "skills")) return false;
            return app.skills.menu.active and !app.skills.menu.origin.isMention();
        }

        fn skillsMenuActive(app: *App) bool {
            if (comptime !@hasField(App, "skills")) return false;
            return app.skills.menuVisible();
        }

        fn modelMenuActive(app: *App) bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            return app.model_cache.menu.active;
        }

        fn sessionMenuActive(agent: *AppAgent) bool {
            if (comptime !agents.hasAgentField(App, "session_persistence")) return false;
            return agent.session_persistence.session_picker.active;
        }

        /// While `/fork` asks whether the fork takes copies of the session's
        /// subagents (D97), Enter or y answers yes and n answers no; Esc
        /// also answers no (`answerForkQuestionOnEscape`). Other printable
        /// bytes are dropped with a trace line, so a stray key never forks;
        /// control bytes pass, so Ctrl+C still works.
        fn routeForkQuestionByte(app: *App, agent: *AppAgent, byte: u8) !bool {
            if (comptime !agents.hasAgentField(App, "session_persistence")) return false;
            if (!agent.session_persistence.fork_menu.asking()) return false;
            const bring: ?bool = switch (byte) {
                '\r', 'y', 'Y' => true,
                'n', 'N' => false,
                else => null,
            };
            if (bring) |yes| {
                _ = try submitForkMenuSelection(app, agent, yes, forkPromptLimit());
                return true;
            }
            if (byte < 0x20) return false;
            if (byte >= 0x80) input_reset.resetPendingTextScalarWithTrace(&app.input_runtime.text_scalar, "fork_question");
            debug_trace.logf("input", "fork question ignored byte=0x{x} reason=not_an_answer", .{byte});
            return true;
        }

        fn answerForkQuestionOnEscape(app: *App, agent: *AppAgent) !bool {
            if (comptime !agents.hasAgentField(App, "session_persistence")) return false;
            if (!agent.session_persistence.fork_menu.asking()) return false;
            return submitForkMenuSelection(app, agent, false, forkPromptLimit());
        }

        /// The composer's limit, which the fork's restored prompt keeps.
        fn forkPromptLimit() usize {
            return if (comptime @hasDecl(App, "input_limits"))
                App.input_limits.composer_bytes
            else
                std.math.maxInt(usize);
        }

        fn forkMenuActive(agent: *AppAgent) bool {
            if (comptime !agents.hasAgentField(App, "session_persistence")) return false;
            return agent.session_persistence.fork_menu.active();
        }

        fn helpMenuActive(app: *App) bool {
            return app.input_runtime.help_menu.active;
        }

        fn settingsMenuActive(app: *App) bool {
            return app.input_runtime.settings_menu.active;
        }

        /// The `/mcp` menu.
        fn mcpHostMenuActive(app: *App) bool {
            if (comptime !@hasDecl(App, "mcpHostMenuKey")) return false;
            return app.mcp.hostMenuActive();
        }

        fn cancelMcpHostMenu(app: *App) !bool {
            if (comptime !@hasDecl(App, "mcpHostMenuKey")) return false;
            if (!mcpHostMenuActive(app)) return false;
            // Back a screen; closing the list clears its filter too.
            try app.mcpHostMenuKey(.escape);
            if (!mcpHostMenuActive(app)) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            }
            return true;
        }

        /// Whether the menu asks Remove or Reject on the choice's row, where
        /// ← and → choose between yes and no.
        fn mcpHostMenuAsksOnRow(app: *App) bool {
            const menu_state = &app.mcp.host_menu;
            if (menu_state.screen != .confirm) return false;
            const c = menu_state.confirm orelse return false;
            return c.asksOnRow();
        }

        /// ← goes back a screen, like Esc, from a server's screen or an
        /// approval; on a question asked on its row it chooses yes. With a
        /// filter typed it moves the composer's cursor, and on the list there
        /// is nothing to go back to.
        fn backMcpHostMenuScreen(app: *App) !bool {
            if (comptime !@hasDecl(App, "mcpHostMenuKey")) return false;
            if (!mcpHostMenuActive(app) or app.mcp.host_menu.screen == .list) return false;
            if (app.mcp.host_menu.screen == .add) {
                if (!app.mcp.host_menu.add_step.typed()) {
                    try app.mcpHostMenuKey(.left);
                    return true;
                }
                if (app.input_runtime.edit_state.input.items.len > 0) return false;
                try app.mcpHostMenuKey(.escape);
                return true;
            }
            if (mcpHostMenuAsksOnRow(app)) {
                try app.mcpHostMenuKey(.left);
                return true;
            }
            if (app.input_runtime.edit_state.input.items.len > 0) return false;
            try app.mcpHostMenuKey(.escape);
            return true;
        }

        /// → acts like Enter on the list and on a server's screen: it opens
        /// the server or runs the selected choice. On a question asked on its
        /// row it chooses no, and an approval still takes Enter, so → never
        /// confirms by accident. With the cursor inside a typed filter, →
        /// moves it instead.
        fn enterMcpHostMenuItem(app: *App) !bool {
            if (comptime !@hasDecl(App, "mcpHostMenuKey")) return false;
            if (!mcpHostMenuActive(app)) return false;
            if (app.mcp.host_menu.screen == .add) {
                if (app.mcp.host_menu.add_step.typed()) return false;
                try app.mcpHostMenuKey(.right);
                return true;
            }
            if (mcpHostMenuAsksOnRow(app)) {
                try app.mcpHostMenuKey(.right);
                return true;
            }
            if (app.mcp.host_menu.screen == .confirm) return false;
            const edit = &app.input_runtime.edit_state;
            if (edit.cursor != edit.input.items.len) return false;
            try app.mcpHostMenuKey(.enter);
            return true;
        }

        /// On the list and on a server's screen, typing goes to the composer,
        /// which filters the servers or the server's tools. On a
        /// confirmation any printable byte means no, like `[y/N]`. Control
        /// bytes pass, so Ctrl+C and Ctrl+J/K still work.
        fn routeMcpHostMenuByte(app: *App, byte: u8) !bool {
            if (comptime !@hasDecl(App, "mcpHostMenuKey")) return false;
            if (!mcpHostMenuActive(app) or app.mcp.host_menu.screen == .list) return false;
            if (app.mcp.host_menu.screen == .add) {
                if (byte == '\r') {
                    try app.mcpHostMenuKey(.enter);
                    return true;
                }
                // Typed steps take text in the composer; choice steps ignore it.
                return !app.mcp.host_menu.add_step.typed() and byte >= 0x20;
            }
            if (app.mcp.host_menu.screen == .server and byte != '\r') return false;
            if (byte == '\r') {
                try app.mcpHostMenuKey(.enter);
                return true;
            }
            if (byte < 0x20) return false;
            if (byte >= 0x80) input_reset.resetPendingTextScalarWithTrace(&app.input_runtime.text_scalar, "mcp_host_menu");
            if (app.mcp.host_menu.screen == .confirm) try app.mcpHostMenuKey(.escape);
            return true;
        }

        fn submitMcpHostMenu(app: *App) !bool {
            if (comptime !@hasDecl(App, "mcpHostMenuKey")) return false;
            if (!mcpHostMenuActive(app)) return false;
            try app.mcpHostMenuKey(.enter);
            return true;
        }

        const CompactCommandMenuKind = enum {
            statusline,
            info_panel,
            workspace,
        };

        fn activeCompactCommandMenu(app: *App) ?CompactCommandMenuKind {
            if (app.input_runtime.statusline_menu.active) return .statusline;
            if (app.input_runtime.info_panel.active) return .info_panel;
            if (app.input_runtime.workspace_menu.active) return .workspace;
            return null;
        }

        // A space never extends a mention token, so it ends the mention and
        // inserts through the normal composer path.
        fn dismissMentionSkillsMenuForSpace(app: *App) void {
            if (comptime !@hasField(App, "skills")) return;
            if (!app.skills.menu.active) return;
            if (!app.skills.menu.origin.isMention()) return;
            app.skills.closeMenu();
            app.shell.render_requests.request(.footer);
        }

        fn closeSkillsMenu(app: *App) bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menu.active) return false;
            app.skills.closeMenu();
            return true;
        }

        fn closeHelpMenu(app: *App, clear_query: bool) bool {
            if (!app.input_runtime.help_menu.active) return false;
            app.input_runtime.help_menu.close();
            if (clear_query) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            }
            return true;
        }

        fn closeSettingsMenu(app: *App, clear_query: bool) bool {
            if (!app.input_runtime.settings_menu.active) return false;
            app.input_runtime.settings_menu.close();
            if (clear_query) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            }
            return true;
        }

        fn closeModelMenu(app: *App, clear_query: bool) bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            if (!app.model_cache.menu.active) return false;
            app.model_cache.closeMenu();
            if (clear_query) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            }
            restoreModelPickerDraft(app);
            return true;
        }

        /// Opens the model picker on the cached catalog and revalidates it in
        /// the background, so models released mid-session appear once it lands.
        fn openModelMenu(app: *App) !void {
            if (comptime @hasDecl(App, "revalidateModelCache")) app.revalidateModelCache();
            try app.model_cache.openMenu();
        }

        fn openModelBrowseCatalog(app: *App) !void {
            if (comptime !@hasField(App, "model_cache")) return;
            if (comptime @hasField(App, "skills")) app.skills.closeMenu();
            try openModelMenu(app);
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.shell.render_requests.request(.footer);
        }

        /// Ctrl+P opens the same catalog `/model` opens, but the composer is
        /// only lent to the menu: the draft moves into a stash and comes back
        /// verbatim when the picker closes, whether a model was picked or not.
        fn openModelPickerShortcut(app: *App) !void {
            if (comptime !@hasField(App, "model_cache")) return;
            if (app.input_runtime.model_picker_draft != null) {
                // Unreachable through the keyboard (Ctrl+P backs out of an
                // active flow first); recover a stranded draft rather than
                // overwrite it.
                debug_trace.logf("input", "model picker draft stashed with menu closed; restoring before reopen", .{});
                restoreModelPickerDraft(app);
            }
            app.input_runtime.model_picker_draft = composer_stash.State.capture(
                app.input_runtime.composerStashView(),
            );
            openModelBrowseCatalog(app) catch |err| {
                restoreModelPickerDraft(app);
                return err;
            };
        }

        fn restoreModelPickerDraft(app: *App) void {
            if (app.input_runtime.model_picker_draft) |*draft| {
                // The flow's picker stage and query belong to the borrowed
                // composer, not to the draft coming back.
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                draft.restore(app.alloc, app.input_runtime.composerStashView());
                app.input_runtime.model_picker_draft = null;
                app.shell.render_requests.request(.footer);
            }
        }

        /// Ctrl+P lends the composer to the whole model picker flow: the
        /// catalog, then the inline effort and fast stages. Once neither owns
        /// it (a model was applied, Esc dismissed a stage, or an edit left the
        /// `/model` query), the stashed draft comes back.
        fn settleModelPickerDraft(app: *App) void {
            if (app.input_runtime.model_picker_draft == null) return;
            if (modelMenuActive(app) or completion_rt.hasModelQuery(app)) return;
            const leftover_bytes = app.input_runtime.edit_state.input.items.len;
            if (leftover_bytes > 0) {
                debug_trace.logf(
                    "input",
                    "model picker flow ended; discarding borrowed composer bytes={d} to restore the draft",
                    .{leftover_bytes},
                );
            }
            restoreModelPickerDraft(app);
        }

        /// Surfaces that own the keyboard make Ctrl+P a no-op instead of
        /// borrowing a composer they are already using.
        fn modelPickerShortcutBlocked(app: *App, agent: *AppAgent) bool {
            if (settingsMenuActive(app) or helpMenuActive(app) or
                skillsMenuActive(app) or sessionMenuActive(agent) or forkMenuActive(agent) or mcpHostMenuActive(app) or
                agentsMenuActive(app)) return true;
            if (comptime @hasField(App, "terminal")) {
                if (app.terminal.fullTranscriptScreenActive()) return true;
            }
            return false;
        }

        /// Ctrl+T is a no-op while another surface owns the keyboard, and
        /// while the model picker or an `/effort ` query previews a level in
        /// the status line that is not the one in use.
        fn effortCycleShortcutBlocked(app: *App, agent: *AppAgent) bool {
            const reason: []const u8 = if (modelPickerShortcutBlocked(app, agent))
                "surface_owns_input"
            else if (modelMenuActive(app) or app.input_runtime.model_picker_draft != null)
                "model_picker_open"
            else if (completion_rt.hasModelQuery(app))
                "model_query"
            else
                return false;
            debug_trace.logf("input", "ctrl+t effort cycle ignored reason={s}", .{reason});
            return true;
        }

        fn toggleSessionPickerScopeIfActive(app: *App, agent: *AppAgent) !bool {
            if (comptime !agents.hasAgentField(App, "session_persistence")) return false;
            if (!agent.session_persistence.session_picker.active) return false;
            return try app_session_runtime.Runtime(App).toggleSessionPickerScope(app, agent);
        }

        fn dismissActiveMenusForComposerEdit(app: *App, agent: *AppAgent) bool {
            // The fork and effort menus read no query from the composer, so an
            // edit closes them. The agent list searches with it instead.
            const fork_menu_closed = cancelForkMenu(app, agent);
            const effort_menu_closed = cancelEffortMenu(app);
            return fork_menu_closed or effort_menu_closed;
        }

        fn dismissActiveMenusThenRedraw(app: *App, agent: *AppAgent) void {
            if (dismissActiveMenusForComposerEdit(app, agent)) {
                app.shell.render_requests.request(.footer);
            }
        }

        fn submitSkillsMenuSelection(app: *App, max_input_len: usize) !bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menu.active) return false;
            // Captured before the sync: a stale $ anchor makes the sync close
            // the menu, and close() resets origin to .command.
            const origin = app.skills.menu.origin;
            syncSkillsMenu(app);
            // A mention menu that is not shown offers nothing to take, so
            // Enter sends the prompt as typed.
            const shown = !origin.isMention() or app.skills.menuVisible();
            const skill = (if (shown) app.skills.selectedMenuSkill() else null) orelse {
                if (origin.isMention()) {
                    app.skills.closeMenu();
                    app.shell.render_requests.request(.footer);
                    return false;
                }
                return true;
            };
            const target = if (!origin.isMention())
                skill_runtime.SkillMenuTarget{ .start = 0, .end = app.input_runtime.edit_state.input.items.len }
            else
                app.skills.menu.target orelse skill_runtime.SkillMenuTarget{
                    .start = app.input_runtime.edit_state.cursor,
                    .end = app.input_runtime.edit_state.cursor,
                };
            const raw_len = app.input_runtime.entities.skillTokenInsertedLen(
                app.input_runtime.edit_state.input.items,
                target.end,
                skill.name,
            );
            if (!app.input_runtime.insertionState().canReplaceRange(
                target.start,
                target.end,
                raw_len,
                max_input_len,
            )) {
                app.skills.closeMenu();
                app.shell.render_requests.request(.footer);
                try input_limit_feedback.report(App, app, .composer, raw_len);
                return true;
            }

            try app.input_runtime.skillBindingState().bindSkillToken(
                app.alloc,
                target.start,
                target.end,
                skill.name,
                skill.path,
                skill_runtime.skillDisplaySource(app.skills.items, skill),
            );
            app.skills.closeMenu();
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn changeSettingsMenuSelection(app: *App, agent: *AppAgent, delta: i32) !void {
            const menu = &app.input_runtime.settings_menu;
            if (comptime @hasField(App, "model_cache")) {
                if (app.model_cache.menu.active) {
                    if (delta < 0) try applyInlineSettingsModelSelection(app, agent);
                    return;
                }
            }

            const snapshot = app_commands.settingsCatalogSnapshot(app);
            const query = app.input_runtime.edit_state.input.items;
            const item = menu.selectedItem(&snapshot, query) orelse return;
            if (item.id == .model) {
                if (delta > 0 and comptime @hasField(App, "model_cache")) {
                    try openModelMenu(app);
                    app.shell.render_requests.request(.footer);
                }
                return;
            }

            const change = menu.changeSelectedOption(&snapshot, query, delta) orelse return;
            if (comptime @hasDecl(App, "notificationPreferences")) {
                try app_commands.applySettingsCatalogChange(app, change);
            }
            app.shell.render_requests.request(.footer);
        }

        fn applyInlineSettingsModelSelection(app: *App, agent: *AppAgent) !void {
            const selected = (try app.model_cache.menu.selectedModelAlloc(app.alloc)) orelse return;
            defer app.alloc.free(selected);
            try session_commands.Commands(App).selectModelFromPicker(
                app,
                agent,
                selected,
                agent.effort,
                app.fast_mode,
                false,
            );
            app.model_cache.closeMenu();
            app.shell.render_requests.request(.footer);
        }

        fn submitSettingsMenuSelection(app: *App, agent: *AppAgent) !bool {
            if (!settingsMenuActive(app)) return false;
            if (comptime @hasField(App, "model_cache")) {
                if (app.model_cache.menu.active) {
                    try applyInlineSettingsModelSelection(app, agent);
                    return true;
                }

                const snapshot = app_commands.settingsCatalogSnapshot(app);
                const selected = app.input_runtime.settings_menu.selectedItem(
                    &snapshot,
                    app.input_runtime.edit_state.input.items,
                ) orelse return true;
                if (selected.id == .model) {
                    try openModelMenu(app);
                    app.shell.render_requests.request(.footer);
                }
            }
            return true;
        }

        fn submitCompactCommandMenuSelection(
            app: *App,
            menu: CompactCommandMenuKind,
            max_input_len: usize,
        ) !void {
            if (menu == .workspace) {
                try prepareWorkspaceMenuCommand(app, max_input_len);
                return;
            }
            // The panel only shows; Enter closes it as Esc does.
            if (menu == .info_panel) {
                app.input_runtime.info_panel.close();
                app.shell.render_requests.request(.footer);
                return;
            }
            const snapshot = app_commands.settingsCatalogSnapshot(app);
            const change = switch (menu) {
                .statusline => app.input_runtime.statusline_menu.selectedChange(snapshot),
                .info_panel, .workspace => unreachable,
            } orelse return;
            if (comptime @hasDecl(App, "notificationPreferences")) {
                try app_commands.applySettingsCatalogMenuChange(app, change);
            }
            app.shell.render_requests.request(.footer);
        }

        fn prepareWorkspaceMenuCommand(app: *App, max_input_len: usize) !void {
            if (comptime !@hasDecl(App, "workspaceAccess")) return;
            const entries = app.workspaceAccess().entries;
            const action = app.input_runtime.workspace_menu.selectedAction(entries) orelse return;

            var command: std.Io.Writer.Allocating = .init(app.alloc);
            defer command.deinit();
            switch (action) {
                .add => try command.writer.writeAll("/workspace add "),
                .remove => |index| {
                    if (index >= entries.len) return;
                    try command.writer.print("/workspace remove {s}", .{entries[index].path});
                },
                .clear => try command.writer.writeAll("/workspace clear"),
            }
            const text = command.written();
            if (text.len > max_input_len) return;
            var prepared_input = try app.input_runtime.textReplacementState().prepare(
                app.alloc,
                text,
            );
            defer prepared_input.deinit(app.alloc);

            app.input_runtime.workspace_menu.close();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.input_runtime.textReplacementState().commit(app.alloc, &prepared_input);
            app.input_runtime.picker.dismissInlinePicker(.slash);
            app.shell.render_requests.request(.footer);
        }

        fn moveCompactCommandMenu(app: *App, menu: CompactCommandMenuKind, delta: i32) bool {
            return switch (menu) {
                .statusline => app.input_runtime.statusline_menu.move(delta),
                .info_panel => scrollInfoPanel(app, delta),
                .workspace => if (comptime @hasDecl(App, "workspaceAccess"))
                    app.input_runtime.workspace_menu.move(
                        delta,
                        app.workspaceAccess().entries,
                    )
                else
                    false,
            };
        }

        /// ↑↓ in a read-only panel, over the lines the footer shows it.
        fn scrollInfoPanel(app: *App, delta: i32) bool {
            const cols = app.shell.layout.cols;
            const projection = render_input.infoPanelProjection(&app.input_runtime.info_panel, cols, app.shell.layout.rows);
            const visible_rows = info_panel_presentation.footerRows(projection, cols, app.shell.layout.rows);
            return app.input_runtime.info_panel.scrollBy(
                delta,
                info_panel_presentation.lineCount(projection.rows, cols),
                info_panel_presentation.visibleLineCount(visible_rows),
            );
        }

        fn routeCompactCommandMenuEscapeAction(
            app: *App,
            menu: CompactCommandMenuKind,
            resolved: input_action.Action,
        ) !void {
            if (menu == .statusline and
                (resolved == .cursor_left or resolved == .cursor_right))
            {
                const snapshot = app_commands.settingsCatalogSnapshot(app);
                const delta: i32 = if (resolved == .cursor_left) -1 else 1;
                const change = switch (menu) {
                    .statusline => app.input_runtime.statusline_menu.changeSelectedOption(&snapshot, delta),
                    .info_panel, .workspace => unreachable,
                } orelse return;
                if (comptime @hasDecl(App, "notificationPreferences")) {
                    try app_commands.applySettingsCatalogMenuChange(app, change);
                }
                return;
            }
            const delta: i32 = switch (resolved) {
                .cursor_up => -1,
                .cursor_down => 1,
                else => return,
            };
            _ = moveCompactCommandMenu(app, menu, delta);
            app.shell.render_requests.request(.footer);
        }

        fn submitHelpMenuSelection(app: *App, max_input_len: usize, max_prompt_history: usize) !bool {
            if (!app.input_runtime.help_menu.active) return false;
            if (app.slashRegistry().matchExact(app.input_runtime.edit_state.input.items) != null) {
                app.input_runtime.help_menu.close();
                return false;
            }
            const selected = app.input_runtime.help_menu.selectedSpec(
                app.slashRegistry(),
                app.input_runtime.edit_state.input.items,
            ) orelse {
                app.shell.render_requests.request(.footer);
                return true;
            };
            const inserted_len = selected.command.len + @intFromBool(selected.has_args);
            if (inserted_len > max_input_len) return true;
            var prepared_input = try app.input_runtime.textReplacementState().prepare(
                app.alloc,
                selected.command,
            );
            defer prepared_input.deinit(app.alloc);

            app.input_runtime.help_menu.close();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.input_runtime.textReplacementState().commit(app.alloc, &prepared_input);
            if (selected.has_args) {
                try app.input_runtime.insertionState().insertByte(app.alloc, ' ', .clear);
                app.shell.render_requests.request(.footer);
                return true;
            }
            try submit_rt.submit(app, max_prompt_history);
            return true;
        }

        fn submitModelMenuSelection(app: *App, agent: *AppAgent) !bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            if (!app.model_cache.menu.active) return false;
            const selected = (try app.model_cache.menu.selectedModelAlloc(app.alloc)) orelse {
                app.shell.render_requests.request(.footer);
                return true;
            };
            defer app.alloc.free(selected);

            // Ctrl+P and `/model` both continue into the inline effort and
            // fast stages. A Ctrl+P draft stays stashed while those stages
            // borrow the composer; settleModelPickerDraft hands it back once
            // the flow ends, and a failure here hands it back immediately.
            errdefer restoreModelPickerDraft(app);
            app.model_cache.closeMenu();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            try completion_rt.beginExactModelSelection(app, agent, selected);
            return true;
        }

        fn submitSlashPickerSelection(app: *App, agent: *AppAgent) !bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (nonSlashPickerOwnsEnter(app, agent)) return false;
            const items = app.input_runtime.edit_state.input.items;
            const prefix = command_specs.slashCompletionPrefix(
                app.slashRegistry(),
                items,
            ) orelse return false;
            const count = completion_rt.visibleSlashCompletionCount(app, agent);
            if (app.slashRegistry().matchExact(prefix)) |exact| {
                // `/rename` typed in full waits for its title, as when it is
                // picked from a prefix below. `/rename ` with nothing after
                // it is sent on purpose, so it runs and says how to use it.
                if (count == 0 or !exact.command.requires_args) return false;
                if (std.mem.trimEnd(u8, prefix, " \t").len != prefix.len) return false;
                try typeCommandAwaitingArgument(app, prefix);
                return true;
            }
            if (count == 0) return false;
            const idx = app.input_runtime.picker.slash_completion_index % count;
            if (!picker_presentation.mixedSlashCompletionIsSkill(
                app.slashRegistry(),
                prefix,
                app.skills.items,
                idx,
            )) {
                const selected = picker_presentation.nthMixedSlashCompletionText(
                    app.slashRegistry(),
                    prefix,
                    app.skills.items,
                    idx,
                ) orelse return false;
                const spec = app.slashRegistry().matchExact(selected) orelse return false;
                if (spec.command.requires_args) {
                    // Only while the name is still being typed: text after it
                    // is the argument, and Enter sends it as it is.
                    if (std.mem.findAny(u8, prefix, " \t") != null) return false;
                    try typeCommandAwaitingArgument(app, selected);
                    return true;
                }
                if (spec.command.kind != .model) return false;
                try openModelBrowseCatalog(app);
                return true;
            }
            return try bindSelectedSlashSkill(app, idx);
        }

        /// Replaces the composer text with `command` and a space, so the
        /// command waits for its argument.
        fn typeCommandAwaitingArgument(app: *App, command: []const u8) !void {
            var buf: [128]u8 = undefined;
            const with_space = std.mem.print(&buf, "{s} ", .{command}) catch command;
            try app.input_runtime.textReplacementState().replace(app.alloc, with_space);
            app.shell.render_requests.request(.footer);
        }

        fn nonSlashPickerOwnsEnter(app: *App, agent: *AppAgent) bool {
            if (completion_rt.filePickerOwnsSurface(app, agent)) return true;
            // Bare `/model` and `/model …` own Enter over slash/skill bind. Mid-turn
            // commit is gated separately when the model list stays hidden.
            if (app.input_runtime.picker.isModelShapedInput(&app.input_runtime.edit_state)) return true;
            if (comptime agents.hasAgentField(App, "stream")) {
                if (agent.stream.active) return false;
            }
            if (comptime agents.hasAgentField(App, "session_persistence")) {
                if (agent.session_persistence.session_picker.active) return true;
            }
            return false;
        }

        fn resolveExplicitModelSelection(app: *App, input: []const u8) ExplicitModelSelectionParse {
            return switch (parseExplicitModelSelection(input)) {
                .selection => |selection| validateExplicitModelSelection(selection, model_capabilities.resolveForApp(App, app, selection.model)),
                .none => .none,
                .invalid => .invalid,
            };
        }

        fn submitExplicitModelSelection(
            app: *App,
            agent: *AppAgent,
            parsed: ExplicitModelSelectionParse,
        ) !bool {
            switch (parsed) {
                .none => return false,
                .invalid => {
                    try app.writeDomainNotice(.{
                        .topic = "",
                        .tone = .@"error",
                        .body = "usage: /model <id> <effort> [normal|fast|ultrafast]",
                    }, true);
                },
                .selection => |selection| {
                    try session_commands.Commands(App).selectModelFromPicker(
                        app,
                        agent,
                        selection.model,
                        selection.effort,
                        selection.fast_mode,
                        selection.ultrafast_mode,
                    );
                    app.input_runtime.inputResetState().clearCurrent(app.alloc);
                },
            }
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn bindSelectedSlashSkill(app: *App, selected_index: usize) !bool {
            if (comptime !@hasField(App, "skills")) return false;
            const items = app.input_runtime.edit_state.input.items;
            const prefix = command_specs.slashCompletionPrefix(
                app.slashRegistry(),
                items,
            ) orelse return false;
            const skill = picker_presentation.nthMixedSlashCompletionSkill(
                app.slashRegistry(),
                prefix,
                app.skills.items,
                selected_index,
            ) orelse return false;
            const leading_ws = items.len - prefix.len;
            debug_trace.logf(
                "skills",
                "slash menu replaced composer text with skill={s} dropped_bytes={d}",
                .{ skill.name, prefix.len },
            );
            try app.input_runtime.skillBindingState().bindSkillToken(
                app.alloc,
                leading_ws,
                leading_ws + prefix.len,
                skill.name,
                skill.path,
                skill_runtime.skillDisplaySource(app.skills.items, skill),
            );
            app.input_runtime.picker.resetInlinePickerEpisode();
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn syncCatalogMenus(app: *App, agent: *AppAgent) void {
            syncAgentsMenu(app);
            syncSettingsMenu(app);
            syncHelpMenu(app);
            syncSkillsMenu(app);
            syncModelMenu(app);
            syncSessionMenu(app, agent);
            syncMcpHostMenu(app);
        }

        fn syncMcpHostMenu(app: *App) void {
            if (comptime !@hasDecl(App, "mcpHostMenuKey")) return;
            app.mcp.hostMenuFilterChanged(app.input_runtime.edit_state.input.items);
        }

        fn syncSettingsMenu(app: *App) void {
            if (!app.input_runtime.settings_menu.active) return;
            app.input_runtime.settings_menu.resetForQuery();
        }

        fn syncHelpMenu(app: *App) void {
            if (!app.input_runtime.help_menu.active) return;
            app.input_runtime.help_menu.resetForQuery();
        }

        fn syncSkillsMenu(app: *App) void {
            if (comptime !@hasField(App, "skills")) return;
            if (!app.skills.menu.active) return;
            if (!app.skills.menu.origin.isMention()) {
                app.skills.setMenuQuery(
                    app.alloc,
                    app.input_runtime.edit_state.input.items,
                );
                return;
            }
            const target = app.skills.menu.target orelse return;
            const items = app.input_runtime.edit_state.input.items;
            if (target.start >= items.len or items[target.start] != '$') {
                app.skills.closeMenu();
                return;
            }
            const end = skillTokenEnd(items, target.start + 1);
            app.skills.menu.target = .{ .start = target.start, .end = end };
            app.skills.setMenuQuery(app.alloc, items[target.start + 1 .. end]);
        }

        fn syncModelMenu(app: *App) void {
            if (comptime !@hasField(App, "model_cache")) return;
            if (!app.model_cache.menu.active) return;
            app.model_cache.setMenuQuery(app.input_runtime.edit_state.input.items);
        }

        fn syncSessionMenu(app: *App, agent: *AppAgent) void {
            if (comptime !agents.hasAgentField(App, "session_persistence")) return;
            const picker = &agent.session_persistence.session_picker;
            if (!picker.active) return;
            app_session_runtime.Runtime(App).searchSessionPicker(app, agent) catch |err| {
                debug_trace.logf(
                    "session",
                    "session picker search dropped the listed sessions err={s}",
                    .{@errorName(err)},
                );
            };
        }

        fn skillTokenEnd(items: []const u8, start: usize) usize {
            var end = start;
            while (end < items.len) : (end += 1) {
                const byte = items[end];
                if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == ':')) break;
            }
            return end;
        }

        fn cycleSkillsMenuSource(app: *App, delta: i32) bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menuVisible()) return false;
            return app.skills.moveMenuSourceFilter(delta);
        }

        fn slashMenuVisibleForCue(app: *App, agent: *AppAgent) bool {
            if (comptime !@hasDecl(App, "playSlashMenuSound")) return false;
            if (comptime @hasDecl(App, "soundMaxEnabled")) {
                if (!app.soundMaxEnabled()) return false;
            }
            return completion_rt.slashCompletionCount(app, agent) > 0;
        }

        fn announceSlashMenuOpened(app: *App, agent: *AppAgent, was_visible: bool) void {
            if (comptime !@hasDecl(App, "playSlashMenuSound")) return;
            if (comptime @hasDecl(App, "soundMaxEnabled")) {
                if (!app.soundMaxEnabled()) return;
            }
            if (was_visible) return;
            if (completion_rt.slashCompletionCount(app, agent) == 0) return;
            app.playSlashMenuSound();
        }

        fn cycleModelMenuProvider(app: *App, delta: i32) bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            if (!app.model_cache.menu.active) return false;
            _ = app.model_cache.menu.moveProvider(delta);
            return true;
        }

        fn cycleSettingsMenuCategory(app: *App, delta: i32) bool {
            if (!app.input_runtime.settings_menu.cycleCategory(delta)) return false;
            if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
            return true;
        }

        fn cycleHelpMenuCategory(app: *App, delta: i32) bool {
            return app.input_runtime.help_menu.cycleCategory(delta);
        }

        fn expireEscClearArm(app: *App, now: i64) void {
            const transition = gesture_state.expireEscapeClear(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.cleared) {
                app.shell.render_requests.request(.footer);
            }
        }

        fn expireEscapeInterruptArm(app: *App, agent: *AppAgent, now: i64) void {
            // An armed interrupt guards one active operation. When that
            // operation settles on its own, the arm must not carry into
            // whatever work starts next.
            if (app.input_runtime.gestures.escapeInterruptArmed() and
                !interrupt_rt.hasActiveOperation(app, agent))
            {
                _ = disarmEscapeInterrupt(app, "operation_settled");
                return;
            }
            const transition = gesture_state.expireEscapeInterrupt(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.cleared) {
                debug_trace.logf(
                    "input",
                    "event=esc_interrupt_disarmed reason=timeout",
                    .{},
                );
                app.shell.render_requests.request(.footer);
            }
        }

        fn expireCtrlCExitArm(app: *App, now: i64) void {
            const transition = gesture_state.expireCtrlCExit(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.cleared) {
                debug_trace.logf(
                    "input",
                    "event=ctrl_c_exit_disarmed reason=timeout",
                    .{},
                );
                app.shell.render_requests.request(.footer);
            }
        }

        fn disarmCtrlCExit(app: *App, reason: []const u8) void {
            const transition = gesture_state.disarmCtrlCExit(
                app.input_runtime.gestures,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.cleared) {
                debug_trace.logf(
                    "input",
                    "event=ctrl_c_exit_disarmed reason={s}",
                    .{reason},
                );
                app.shell.render_requests.request(.footer);
            }
        }

        fn disarmEscapeClear(app: *App) bool {
            const transition = gesture_state.disarmEscapeClear(
                app.input_runtime.gestures,
            );
            app.input_runtime.gestures = transition.next;
            return transition.cleared;
        }

        fn disarmEscapeInterrupt(app: *App, reason: []const u8) bool {
            const transition = gesture_state.disarmEscapeInterrupt(
                app.input_runtime.gestures,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.cleared) {
                debug_trace.logf(
                    "input",
                    "event=esc_interrupt_disarmed reason={s}",
                    .{reason},
                );
                app.shell.render_requests.request(.footer);
            }
            return transition.cleared;
        }

        fn resolveEscape(app: *App, agent: *AppAgent, was_cancel_pending: bool, now: i64) !void {
            if (try full_transcript_rt.routeAction(app, agent, .escape)) return;
            // Ahead of the prompts: the open agent list shows `agent` only as
            // a preview, and Esc goes back from it.
            if (try backAgentsMenu(app)) {
                _ = disarmEscapeClear(app);
                _ = disarmEscapeInterrupt(app, "menu");
                return;
            }
            // Esc answers `/fork`'s question: fork without the subagents (D97).
            if (try answerForkQuestionOnEscape(app, agent)) {
                _ = disarmEscapeClear(app);
                _ = disarmEscapeInterrupt(app, "fork_question");
                return;
            }
            if (was_cancel_pending) {
                if (agent.question_prompt.isActive()) {
                    // Freeform answers mirror the composer's Esc contract:
                    // Esc on a non-empty draft arms, a second press within
                    // the window clears it, and only an empty field lets
                    // Esc cancel the batch.
                    _ = disarmEscapeInterrupt(app, "question_prompt");
                    if (agent.question_prompt.freeformDraftLen() > 0) {
                        const transition = gesture_state.pressEscapeClear(
                            app.input_runtime.gestures,
                            now,
                        );
                        app.input_runtime.gestures = transition.next;
                        if (transition.result == .activated) {
                            agent.question_prompt.clearFreeformDraft("escape_clear");
                        }
                        app.shell.render_requests.request(.modal);
                        app.shell.render_requests.request(.footer);
                        return;
                    }
                    try question_rt.cancelQuestionPrompt(app, agent);
                    return;
                }
                if (cancelConnectMenu(app) or cancelCompactCommandMenu(app) or (try cancelMcpHostMenu(app)) or cancelSettingsMenu(app) or cancelHelpMenu(app) or cancelModelMenu(app) or cancelSkillsMenu(app) or cancelSessionMenu(app, agent) or cancelForkMenu(app, agent) or cancelEffortMenu(app)) {
                    _ = disarmEscapeClear(app);
                    _ = disarmEscapeInterrupt(app, "menu");
                    app.shell.render_requests.request(.footer);
                    return;
                }
                if (completion_rt.dismissVisibleInlinePicker(app, agent)) {
                    _ = disarmEscapeClear(app);
                    _ = disarmEscapeInterrupt(app, "inline_picker");
                    app.shell.render_requests.request(.footer);
                    return;
                }
                if (interrupt_rt.dismissCompactionFeedback(app, agent)) {
                    _ = disarmEscapeClear(app);
                    _ = disarmEscapeInterrupt(app, "compaction_feedback");
                    return;
                }
                // A request that waits for the user ends on one Esc.
                if (recoveryWaitsForUser(app)) {
                    try interrupt_rt.cancelActiveOperation(app, agent);
                    _ = disarmEscapeClear(app);
                    _ = disarmEscapeInterrupt(app, "recovery_need_user");
                    app.shell.render_requests.request(.footer);
                    return;
                }
                // Interrupting active work requires a confirming second Esc
                // within the gesture window. The first press only arms.
                const transition = gesture_state.pressEscapeInterrupt(
                    app.input_runtime.gestures,
                    now,
                );
                app.input_runtime.gestures = transition.next;
                if (transition.result == .activated) {
                    try interrupt_rt.cancelActiveOperation(app, agent);
                } else {
                    debug_trace.logf(
                        "input",
                        "event=esc_interrupt_armed target=active_operation",
                        .{},
                    );
                }
                _ = disarmEscapeClear(app);
                app.shell.render_requests.request(.footer);
                return;
            }

            if (cancelConnectMenu(app) or cancelCompactCommandMenu(app) or (try cancelMcpHostMenu(app)) or cancelSettingsMenu(app) or cancelHelpMenu(app) or cancelModelMenu(app) or cancelSkillsMenu(app) or cancelSessionMenu(app, agent) or cancelForkMenu(app, agent) or cancelEffortMenu(app)) {
                _ = disarmEscapeClear(app);
                app.shell.render_requests.request(.footer);
                return;
            }
            if (completion_rt.dismissVisibleInlinePicker(app, agent)) {
                _ = disarmEscapeClear(app);
                app.shell.render_requests.request(.footer);
                return;
            }
            if (interrupt_rt.dismissCompactionFeedback(app, agent)) {
                _ = disarmEscapeClear(app);
                return;
            }
            if (!draftHasState(app, agent)) {
                _ = disarmEscapeClear(app);
                return;
            }
            const transition = gesture_state.pressEscapeClear(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.result == .activated) {
                clearDraftState(app, agent, "double_escape");
                app.shell.render_requests.request(.footer);
                if (comptime @hasDecl(App, "playInputClearedSound")) app.playInputClearedSound();
            } else {
                app.shell.render_requests.request(.footer);
            }
        }

        /// Whether the status row shows a request that waits for the user.
        fn recoveryWaitsForUser(app: *App) bool {
            if (comptime !@hasDecl(@TypeOf(app.shell), "worker_status_state")) return false;
            return app.shell.worker_status_state().waitsForUser();
        }

        fn cancelSkillsMenu(app: *App) bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menuVisible()) return false;
            const mention = app.skills.menu.origin.isMention();
            const clear_query = !mention;
            app.skills.closeMenu();
            if (mention) app.input_runtime.picker.dismissInlinePicker(.skill);
            if (clear_query) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            }
            return true;
        }

        fn cancelCompactCommandMenu(app: *App) bool {
            if (app.input_runtime.statusline_menu.active) {
                app.input_runtime.statusline_menu.close();
                return true;
            }
            if (app.input_runtime.info_panel.active) {
                app.input_runtime.info_panel.close();
                return true;
            }
            if (app.input_runtime.workspace_menu.active) {
                app.input_runtime.workspace_menu.close();
                return true;
            }
            return false;
        }

        fn cancelHelpMenu(app: *App) bool {
            return closeHelpMenu(app, true);
        }

        fn cancelSettingsMenu(app: *App) bool {
            return closeSettingsMenu(app, true);
        }

        fn cancelModelMenu(app: *App) bool {
            return closeModelMenu(app, true);
        }

        fn cancelSessionMenu(app: *App, agent: *AppAgent) bool {
            if (comptime !agents.hasAgentField(App, "session_persistence")) return false;
            if (!agent.session_persistence.session_picker.active) return false;
            app_session_runtime.Runtime(App).cancelSessionPickerToComposer(app, agent);
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            return true;
        }

        fn cancelForkMenu(app: *App, agent: *AppAgent) bool {
            if (comptime !agents.hasAgentField(App, "session_persistence")) return false;
            if (!forkMenuActive(agent)) return false;
            agent.session_persistence.fork_menu.close(app.alloc);
            return true;
        }

        fn cancelConnectMenu(app: *App) bool {
            if (comptime !@hasDecl(App, "saveConnection")) return false;
            return app_provider_menu_runtime.Runtime(App).cancel(app);
        }

        fn cancelEffortMenu(app: *App) bool {
            if (!app.input_runtime.effort_menu.active) return false;
            app.input_runtime.effort_menu.close(app.alloc);
            return true;
        }

        /// Applies the level highlighted in the `/effort` menu and closes it.
        fn submitEffortMenuSelection(app: *App, agent: *AppAgent) !bool {
            const menu = &app.input_runtime.effort_menu;
            const effort = menu.selectedEffort() orelse return false;
            menu.close(app.alloc);
            try session_commands.Commands(App).selectEffort(app, agent, effort);
            app.shell.render_requests.request(.footer);
            return true;
        }
    };
}
const ApprovalCancelEvent = enum {
    request_cancel,
};

const FakeApprovalCancelWorker = struct {
    cancel_requested: bool = false,
    order: [1]ApprovalCancelEvent = undefined,
    order_len: usize = 0,

    fn record(self: *FakeApprovalCancelWorker, event: ApprovalCancelEvent) void {
        if (self.order_len < self.order.len) {
            self.order[self.order_len] = event;
            self.order_len += 1;
        }
    }

    pub fn isCancelRequested(self: *const FakeApprovalCancelWorker) bool {
        return self.cancel_requested;
    }

    pub fn queuedPromptCount(_: *const FakeApprovalCancelWorker) usize {
        return 0;
    }

    pub fn requestCancel(self: *FakeApprovalCancelWorker) void {
        self.cancel_requested = true;
        self.record(.request_cancel);
    }

    pub fn submitQuestionBatchAnswer(_: *FakeApprovalCancelWorker, _: std.mem.Allocator, _: ?[]const []const u8, _: ?worker_runtime.QuestionResumeObserver) !void {}
};

const FakeApprovalPacer = struct {
    cleared: bool = false,

    pub fn clear(self: *FakeApprovalPacer, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.cleared = true;
    }
};

const FakeInactiveSubagents = struct {
    fn isViewActive(_: *const FakeInactiveSubagents) bool {
        return false;
    }
};

const FakeApprovalShell = struct {
    render_requests: render_request.RenderRequestState = .{},
    layout: types.Layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    },
    transcript: std.ArrayList(u8) = .empty,

    fn deinit(self: *FakeApprovalShell, alloc: std.mem.Allocator) void {
        self.transcript.deinit(alloc);
    }

    fn updateRawBytesEntry(_: *FakeApprovalShell, _: std.mem.Allocator, _: u32, _: []const u8) !bool {
        return false;
    }

    fn appendRawTranscriptEntry(_: *FakeApprovalShell, _: std.mem.Allocator, _: []const u8) !u32 {
        return 1;
    }

    pub fn scrollFullTranscript(
        _: *FakeApprovalShell,
        _: input_action.MouseWheel,
        _: transcript_runtime.TranscriptRuntime.FullTranscriptScrollUnit,
    ) void {}
};

const routing_test_slash_specs = [_]command_specs.SlashSpec{
    .{ .kind = .help, .command = "/help", .help_entry = "/help", .completion_description = "show available slash commands", .presentation_category = .general },
    .{ .kind = .copy, .command = "/clear", .help_entry = "/clear", .completion_description = "clear the terminal transcript", .presentation_category = .general },
    .{ .kind = .image, .command = "/image", .aliases = &.{"/img"}, .help_entry = "/image <path> (/img)", .completion_description = "attach an image by path", .presentation_category = .media, .has_args = true, .accepts_payload = true },
    .{ .kind = .images, .command = "/images", .help_entry = "/images [clear]", .completion_description = "manage pending image attachments", .presentation_category = .media, .has_args = true, .accepts_payload = true },
    .{ .kind = .model, .command = "/model", .help_entry = "/model <id-or-query>", .completion_description = "choose a model", .presentation_category = .model, .has_args = true, .accepts_payload = true, .requires_prompt_credential = true },
    .{ .kind = .skills, .command = "/skills", .help_entry = "/skills", .completion_description = "browse and manage skills", .presentation_category = .extensions, .has_args = true, .accepts_payload = true },
    .{ .kind = .status, .command = "/workspace", .help_entry = "/workspace [list|add PATH|remove PATH|clear]", .completion_description = "manage additional workspace directories", .presentation_category = .workspace, .has_args = true, .accepts_payload = true },
};
const routing_test_slash_registry = command_specs.SlashRegistry{ .commands = routing_test_slash_specs[0..] };

const FakeApprovalCancelApp = struct {
    alloc: std.mem.Allocator,
    subagents: FakeInactiveSubagents = .{},
    input_runtime: core_input_runtime.Runtime = .{},
    terminal_input_runtime: test_ui_input.Runtime = .{},
    main_agent: struct {
        pending_images: std.ArrayList(types.ImageAttachment) = .empty,
        question_prompt: question_prompt.QuestionPrompt = .{},
        worker: FakeApprovalCancelWorker = .{},
        stream: types.StreamState = .{ .active = true },
    } = .{},
    shell: FakeApprovalShell = .{},
    pacer: FakeApprovalPacer = .{},
    transcript: std.ArrayList(u8) = .empty,
    last_class: transcript_runtime.RawEntryClass = .unknown_raw,
    notice_topic: std.ArrayList(u8) = .empty,
    notice_body: std.ArrayList(u8) = .empty,
    notice_tone: types.NoticeTone = .information,

    pub fn slashRegistry(_: *const FakeApprovalCancelApp) command_specs.SlashRegistry {
        return routing_test_slash_registry;
    }

    fn deinit(self: *FakeApprovalCancelApp) void {
        self.agent().question_prompt.deinit(self.alloc);
        self.clearPendingImages(&self.main_agent);
        self.agent().pending_images.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.terminal_input_runtime.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.notice_topic.deinit(self.alloc);
        self.notice_body.deinit(self.alloc);
    }

    fn clearPendingImages(self: *FakeApprovalCancelApp, _: anytype) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        for (self.agent().pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.agent().pending_images.clearRetainingCapacity();
    }

    fn ensureTrailingBlankRow(self: *FakeApprovalCancelApp) !void {
        try self.transcript.appendSlice(self.alloc, "\n\n");
    }

    fn writeTranscript(self: *FakeApprovalCancelApp, content: []const u8, redraw: bool) !void {
        _ = redraw;
        try self.transcript.appendSlice(self.alloc, content);
    }

    pub fn writeTranscriptClassified(self: *FakeApprovalCancelApp, content: []const u8, redraw: bool, class: transcript_runtime.RawEntryClass) !void {
        self.last_class = class;
        try self.writeTranscript(content, redraw);
    }

    pub fn writeDomainNotice(self: *FakeApprovalCancelApp, notice: types.SemanticNotice, _: bool) !void {
        self.notice_topic.clearRetainingCapacity();
        self.notice_body.clearRetainingCapacity();
        try self.notice_topic.appendSlice(self.alloc, notice.topic);
        try self.notice_body.appendSlice(self.alloc, notice.body);
        self.notice_tone = notice.tone;
    }

    pub fn stopStream(self: *FakeApprovalCancelApp, _: anytype) void {
        self.agent().stream = .{};
    }

    pub fn appendReplaceableTranscriptLine(self: *FakeApprovalCancelApp, content: []const u8) !u32 {
        try self.shell.transcript.appendSlice(self.alloc, content);
        return 1;
    }

    pub fn appendReplaceableTranscriptLineClassified(self: *FakeApprovalCancelApp, content: []const u8, _: transcript_runtime.RawEntryClass) !u32 {
        return self.appendReplaceableTranscriptLine(content);
    }

    pub fn fileCompletions(
        _: *FakeApprovalCancelApp,
        _: []const u8,
        out: []file_index.SearchResult,
        _: []file_index.MatchSpan,
        _: []u8,
    ) file_index.SearchError!usize {
        if (out.len == 0) return 0;
        out[0] = .{ .path = "file.zig", .kind = .file, .matched_spans = &.{} };
        return 1;
    }

    pub fn modelCompletions(_: *FakeApprovalCancelApp, _: []const u8, out: [][]const u8) usize {
        if (out.len == 0) return 0;
        out[0] = "openai/gpt-5";
        return 1;
    }

    pub fn transitionFullTranscriptProjection(
        _: *FakeApprovalCancelApp,
        event: transcript_presentation.Event,
    ) !transcript_presentation.Depth {
        return transcript_presentation.Depth.inline_mode.transition(
            event,
        );
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

const RoutingSubagents = struct {
    active: bool = false,
    main_approval_presented: bool = false,
    handled_keys: usize = 0,
    toggle_view_calls: usize = 0,
    manager_paste: core_input_runtime.Runtime = .{},

    fn deinit(self: *RoutingSubagents, alloc: std.mem.Allocator) void {
        self.manager_paste.deinit(alloc);
    }

    pub fn isViewActive(self: *const RoutingSubagents) bool {
        return self.active;
    }

    pub fn mainApprovalPresented(self: *const RoutingSubagents) bool {
        return self.main_approval_presented;
    }

    pub fn count(_: *const RoutingSubagents) usize {
        return 0;
    }

    pub fn panelText(_: *RoutingSubagents, alloc: std.mem.Allocator, _: u16, _: u16, _: transcript_runtime.Styles) ![]u8 {
        return alloc.dupe(u8, "");
    }

    pub fn managerPasteActive(self: *const RoutingSubagents) bool {
        return self.active and self.manager_paste.paste.active();
    }

    pub fn beginManagerPaste(self: *RoutingSubagents) void {
        self.manager_paste.paste.begin(.decision_prompt, std.math.maxInt(usize));
    }

    pub fn consumeManagerPasteByte(
        self: *RoutingSubagents,
        alloc: std.mem.Allocator,
        byte: u8,
    ) !bool {
        if (!self.managerPasteActive()) return false;
        try self.manager_paste.paste.consumeByte(alloc, byte);
        return true;
    }

    pub fn settleManagerPasteDeliveryEpoch(
        self: *RoutingSubagents,
        _: std.mem.Allocator,
    ) bool {
        switch (self.manager_paste.paste.settleDeliveryEpoch()) {
            .none => return false,
            .finish => self.manager_paste.paste.resetWithTrace(.decision_prompt_active),
        }
        return true;
    }
};

const RoutingUpgradeStatus = struct {
    state: auto_upgrade.State = .ready,
    stop_count: usize = 0,

    pub fn getState(self: *const RoutingUpgradeStatus) auto_upgrade.State {
        return self.state;
    }

    pub fn stop(self: *RoutingUpgradeStatus) void {
        self.stop_count += 1;
    }

    pub fn statusLabel(_: *const RoutingUpgradeStatus, _: []u8) []const u8 {
        return "";
    }
};

const RoutingWorker = struct {
    compaction: @import("../output/compaction_activity.zig").State = .{},

    active_permission_request_id: ?u64 = null,
    permission_response: ?ToolPermissionDecision = null,
    resize_signal_on_submit: ?*shell_runtime.ResizeApprovalInterlock = null,
    question_cancelled: bool = false,
    cancel_requested_when_question_cancelled: bool = false,
    submitted_question_answer: [64]u8 = undefined,
    submitted_question_answer_len: usize = 0,
    submitted_question_answers: [2][64]u8 = undefined,
    submitted_question_answer_lens: [2]usize = .{ 0, 0 },
    submitted_question_count: usize = 0,
    question_submission_fails: bool = false,
    cancel_requested: bool = false,
    question_source: worker_runtime.QuestionPromptSource = .agent_question,
    admission_snapshot: worker_runtime.InteractiveAdmissionSnapshot = .open,
    queued_count: usize = 0,
    queued_steer_text: ?[]const u8 = null,
    synced_permission_mode: ?types.PermissionMode = null,
    permission_mode_sync_count: usize = 0,
    agent_turn_settings: worker_runtime.AgentTurnSettings = .{},

    pub fn compactionActivitySnapshot(self: *RoutingWorker) @import("../output/compaction_activity.zig").Snapshot {
        return self.compaction.snapshot;
    }

    pub fn dismissCompactionActivity(self: *RoutingWorker, id: @import("../output/compaction_activity.zig").OperationId, revision: u64) bool {
        return self.compaction.dismiss(id, revision);
    }

    pub fn queuedPromptCount(self: *const RoutingWorker) usize {
        return self.queued_count;
    }

    pub fn popQueuedSteerForEdit(self: *RoutingWorker, alloc: std.mem.Allocator) !?[]u8 {
        const text = self.queued_steer_text orelse return null;
        self.queued_steer_text = null;
        return try alloc.dupe(u8, text);
    }

    pub fn activeTurnId(_: *const RoutingWorker) u64 {
        return 1;
    }

    pub fn isCancelRequested(self: *const RoutingWorker) bool {
        return self.cancel_requested;
    }

    pub fn requestCancel(self: *RoutingWorker) void {
        self.cancel_requested = true;
    }

    pub fn requestInteractiveCancel(self: *RoutingWorker) void {
        self.cancel_requested = true;
    }

    pub fn interactiveAdmissionSnapshot(self: *RoutingWorker) worker_runtime.InteractiveAdmissionSnapshot {
        return self.admission_snapshot;
    }

    pub fn submitQuestionBatchAnswer(self: *RoutingWorker, _: std.mem.Allocator, answers: ?[]const []const u8, on_resume: ?worker_runtime.QuestionResumeObserver) !void {
        if (self.question_submission_fails) return error.OutOfMemory;
        if (answers == null) {
            self.cancel_requested_when_question_cancelled = self.cancel_requested;
            self.question_cancelled = true;
            return;
        }
        const submitted = answers.?;
        self.submitted_question_count = submitted.len;
        for (submitted[0..@min(submitted.len, self.submitted_question_answers.len)], 0..) |answer, index| {
            const len = @min(answer.len, self.submitted_question_answers[index].len);
            @memcpy(self.submitted_question_answers[index][0..len], answer[0..len]);
            self.submitted_question_answer_lens[index] = len;
            if (index == 0) {
                self.submitted_question_answer_len = len;
                @memcpy(self.submitted_question_answer[0..len], answer[0..len]);
            }
        }
        if (on_resume) |observer| observer.run(observer.ctx);
    }

    pub fn pendingQuestionBatchSource(self: *RoutingWorker) worker_runtime.QuestionPromptSource {
        return self.question_source;
    }

    pub fn syncQueuedPromptModel(_: *RoutingWorker, _: std.mem.Allocator, _: []const u8) !void {}

    pub fn syncQueuedPromptFastMode(_: *RoutingWorker, _: bool) void {}

    pub fn syncQueuedPromptUltrafastMode(self: *RoutingWorker, enabled: bool) void {
        self.agent_turn_settings.ultrafast_mode = enabled;
    }

    pub fn syncQueuedPromptEffort(_: *RoutingWorker, _: types.ReasoningEffort) void {}

    pub fn clearQueuedPrompts(
        self: *RoutingWorker,
        _: std.mem.Allocator,
        _: []const types.ImageAttachment,
    ) void {
        self.queued_count = 0;
    }

    pub fn removeQueuedPrompt(
        self: *RoutingWorker,
        _: std.mem.Allocator,
        _: u64,
        _: []const types.ImageAttachment,
    ) bool {
        if (self.queued_count == 0) return false;
        self.queued_count -= 1;
        return true;
    }
};

const RoutingPacer = struct {
    pub fn clear(_: *RoutingPacer, _: std.mem.Allocator) void {}
};

fn routingFullTranscriptStyles() transcript_runtime.Styles {
    return .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
}

fn armCtrlCExitForTest(input_runtime: *core_input_runtime.Runtime, armed_ms: i64) void {
    input_runtime.gestures = gesture_state.disarmCtrlCExit(
        input_runtime.gestures,
    ).next;
    input_runtime.gestures = gesture_state.pressCtrlCExit(
        input_runtime.gestures,
        armed_ms,
    ).next;
}

fn armEscapeClearForTest(input_runtime: *core_input_runtime.Runtime, armed_ms: i64) void {
    input_runtime.gestures = gesture_state.disarmEscapeClear(
        input_runtime.gestures,
    ).next;
    input_runtime.gestures = gesture_state.pressEscapeClear(
        input_runtime.gestures,
        armed_ms,
    ).next;
}

const RoutingFakeApp = struct {
    pub const input_byte_limit: usize = 4096;

    alloc: std.mem.Allocator,
    metrics: types.Metrics = .{},
    input_runtime: core_input_runtime.Runtime = .{},
    terminal_input_runtime: test_ui_input.Runtime = .{},
    shell: transcript_runtime.TranscriptRuntime = .{},
    terminal: shell_runtime.TerminalState = .{},
    subagents: RoutingSubagents = .{},
    upgrader: RoutingUpgradeStatus = .{},
    main_agent: struct {
        pending_images: std.ArrayList(types.ImageAttachment) = .empty,
        effort: types.ReasoningEffort = .auto,
        total_input_tokens: u64 = 0,
        question_prompt: question_prompt.QuestionPrompt = .{},
        session_persistence: app_session_runtime.Persistence = .{},
        worker: RoutingWorker = .{},
        stream: types.StreamState = .{},
    } = .{},
    next_image_id_counter: usize = 1,
    selected_model: std.ArrayList(u8) = .empty,
    workspace_root: []const u8 = "",
    skills: skill_runtime.Runtime = .{},
    pacer: RoutingPacer = .{},
    transcript: std.ArrayList(u8) = .empty,
    notice_topic: std.ArrayList(u8) = .empty,
    notice_body: std.ArrayList(u8) = .empty,
    notice_tone: types.NoticeTone = .information,
    notice_visibility: types.NoticeVisibility = .compact_and_full,
    notice_write_count: usize = 0,
    last_replaceable_class: transcript_runtime.RawEntryClass = .unknown_raw,
    auth: auth_runtime.Runtime = .{},
    fast_mode: bool = false,
    should_exit: bool = false,
    statusline_context: bool = false,
    authority_mutex: std.Io.Mutex = .init,
    last_command: ?[]u8 = null,
    input_len_at_command: usize = 0,
    pasted_block_count_at_command: usize = 0,
    preference_commit_count: usize = 0,
    last_preference_model: std.ArrayList(u8) = .empty,
    last_preference_effort: ?types.ReasoningEffort = null,
    last_preference_fast_mode: ?bool = null,
    permission_mode_preference_commit_count: usize = 0,
    last_preference_permission_mode: ?types.PermissionMode = null,
    model_completion_values: []const []const u8 = &.{},
    gateway_metadata_model: ?[]const u8 = null,
    gateway_metadata: model_capabilities.GatewayMetadata = .{},
    model_cache_loading: bool = false,
    model_cache: model_cache_runtime.Runtime,
    file_completion_values: []const file_index.Candidate = &.{},
    file_completion_current: bool = true,
    expected_file_completion_kind: ?file_index.CandidateKind = null,
    validated_file_completion_kind: ?file_index.CandidateKind = null,
    file_completion_error: ?file_index.SearchError = null,
    file_completions_depend_on_index: bool = true,
    file_index_refresh_count: usize = 0,
    file_index_loading: bool = false,
    file_index_failed: bool = false,
    submitted_prompt_count: usize = 0,
    submitted_prompt: [128]u8 = undefined,
    submitted_prompt_len: usize = 0,
    approval_resize_interlock: shell_runtime.ResizeApprovalInterlock = .{},
    inject_resize_before_affirmative_claim: bool = false,
    affirmative_claim_count: usize = 0,
    affirmative_release_count: usize = 0,
    resume_selected_count: usize = 0,
    resume_selected_error: anyerror = error.SessionStoreUnavailable,
    resume_selected_closes_picker: bool = false,
    load_more_session_count: usize = 0,
    selected_auth_team: ?usize = null,
    prompt_retry_after_auth: bool = false,
    upgrade_apply_count: usize = 0,
    upgrade_denied_count: usize = 0,
    suspend_count: usize = 0,
    workspace_access: app_workspace_runtime.Access = .{},

    pub fn slashRegistry(_: *const RoutingFakeApp) command_specs.SlashRegistry {
        return routing_test_slash_registry;
    }

    pub fn urlOpener(_: *const RoutingFakeApp) host.UrlOpener {
        return .{ .open_fn = routingOpenUrl };
    }

    fn init(alloc: std.mem.Allocator) !RoutingFakeApp {
        var app = RoutingFakeApp{
            .alloc = alloc,
            .model_cache = model_cache_runtime.Runtime.init(alloc),
        };
        try app.selected_model.appendSlice(alloc, "test/model");
        app.shell.layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        };
        app.shell.owned_top_row = 1;
        app.shell.viewport_top_row = 1;
        app.shell.cursor_row = 10;
        app.shell.cursor_col = 1;
        return app;
    }

    fn deinit(self: *RoutingFakeApp) void {
        self.auth.deinit(self.alloc);
        self.agent().question_prompt.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.terminal_input_runtime.deinit(self.alloc);
        self.subagents.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        self.agent().pending_images.deinit(self.alloc);
        self.selected_model.deinit(self.alloc);
        self.agent().session_persistence.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.notice_topic.deinit(self.alloc);
        self.notice_body.deinit(self.alloc);
        self.last_preference_model.deinit(self.alloc);
        self.model_cache.deinit();
        self.workspace_access.deinit(self.alloc);
        if (self.last_command) |command| self.alloc.free(command);
    }

    pub fn workspaceAccess(self: *RoutingFakeApp) *app_workspace_runtime.Access {
        return &self.workspace_access;
    }

    pub fn flushBeforeBlockingExternalWork(_: *RoutingFakeApp) !void {}

    pub fn suspendToJobControl(self: *RoutingFakeApp) !void {
        self.suspend_count += 1;
    }

    pub fn modelCompletions(self: *RoutingFakeApp, query: []const u8, out: *[32][]const u8) usize {
        if (self.model_cache_loading) return 0;
        var count: usize = 0;
        for (self.model_completion_values) |value| {
            if (count == out.len) break;
            if (query.len > 0 and std.ascii.findIgnoreCase(value, query) == null) continue;
            out[count] = value;
            count += 1;
        }
        return count;
    }

    pub fn catalogModelCompletion(self: *RoutingFakeApp, model: []const u8) ?[]const u8 {
        if (self.model_cache_loading) return null;
        for (self.model_completion_values) |value| {
            if (std.mem.eql(u8, value, model)) return value;
        }
        return null;
    }

    pub fn fileCompletions(
        self: *RoutingFakeApp,
        _: []const u8,
        out: []file_index.SearchResult,
        _: []file_index.MatchSpan,
        _: []u8,
    ) file_index.SearchError!usize {
        if (self.file_completion_error) |err| return err;
        const count = @min(self.file_completion_values.len, out.len);
        for (self.file_completion_values[0..count], 0..) |value, index| {
            out[index] = .{ .path = value.path, .kind = value.kind, .matched_spans = &.{} };
        }
        return count;
    }

    pub fn prepareDirectoryCompletion(self: *RoutingFakeApp) void {
        const completion = @import("../input/file_completion_state.zig");
        const state = &self.input_runtime.picker.file_completion;
        if (self.file_completion_error != null) {
            state.stage(self.alloc, .{ .state = .ready }, .unavailable, null);
            return;
        }
        var results: [completion.capacity]file_index.SearchResult = undefined;
        for (self.file_completion_values, 0..) |value, i| results[i] = .{ .path = value.path, .kind = value.kind, .matched_spans = &.{} };
        const rows = completion.Rows.copy(self.alloc, results[0..self.file_completion_values.len]) catch {
            state.stage(self.alloc, .{ .state = .ready }, .unavailable, null);
            return;
        };
        state.stage(self.alloc, .{ .state = .ready }, if (rows.results.len == 0) .empty else .ready, rows);
    }

    pub fn refreshFileIndex(self: *RoutingFakeApp) void {
        self.file_index_refresh_count += 1;
    }

    pub fn fileCompletionsDependOnIndex(self: *const RoutingFakeApp, _: []const u8) bool {
        return self.file_completions_depend_on_index;
    }

    pub fn isCurrentFileCompletion(self: *RoutingFakeApp, _: []const u8, _: []const u8, kind: file_index.CandidateKind) bool {
        self.validated_file_completion_kind = kind;
        return self.file_completion_current and
            (self.expected_file_completion_kind == null or self.expected_file_completion_kind.? == kind);
    }

    pub fn isModelCacheLoading(self: *const RoutingFakeApp) bool {
        return self.model_cache_loading;
    }

    pub fn isModelCacheFailed(_: *const RoutingFakeApp) bool {
        return false;
    }

    pub fn resolvedModelCapabilities(self: *RoutingFakeApp, model: []const u8) model_capabilities.Capabilities {
        if (self.gateway_metadata_model) |metadata_model| {
            if (std.mem.eql(u8, metadata_model, model)) {
                return model_capabilities.resolveCapabilities(model, self.gateway_metadata);
            }
        }
        return model_capabilities.capabilitiesForModel(model);
    }

    fn setGatewayControls(
        self: *RoutingFakeApp,
        model: []const u8,
        efforts: []const types.ReasoningEffort,
        supports_fast_mode: bool,
    ) void {
        self.gateway_metadata_model = model;
        self.gateway_metadata = .{
            .reasoning_efforts = .fromSlice(efforts),
            .supports_fast_mode = supports_fast_mode,
        };
    }

    pub fn isFileIndexLoading(self: *const RoutingFakeApp) bool {
        return self.file_index_loading;
    }

    pub fn isFileIndexFailed(self: *const RoutingFakeApp) bool {
        return self.file_index_failed;
    }

    pub fn appendReplaceableTranscriptLine(self: *RoutingFakeApp, content: []const u8) !u32 {
        try self.transcript.appendSlice(self.alloc, content);
        return 1;
    }

    pub fn appendReplaceableTranscriptLineClassified(self: *RoutingFakeApp, content: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_replaceable_class = class;
        return self.appendReplaceableTranscriptLine(content);
    }

    pub fn writeTranscriptClassified(self: *RoutingFakeApp, content: []const u8, _: bool, _: transcript_runtime.RawEntryClass) !void {
        try self.transcript.appendSlice(self.alloc, content);
    }

    pub fn writeDomainNotice(self: *RoutingFakeApp, notice: types.SemanticNotice, _: bool) !void {
        self.notice_write_count += 1;
        self.notice_topic.clearRetainingCapacity();
        self.notice_body.clearRetainingCapacity();
        try self.notice_topic.appendSlice(self.alloc, notice.topic);
        try self.notice_body.appendSlice(self.alloc, notice.body);
        self.notice_tone = notice.tone;
        self.notice_visibility = notice.visibility;
        const rendered = if (notice.topic.len > 0)
            try self.alloc.print("{s} {s}: {s}", .{
                types.noticeGlyph(notice.tone),
                notice.topic,
                notice.body,
            })
        else
            try self.alloc.print("{s} {s}", .{ types.noticeGlyph(notice.tone), notice.body });
        defer self.alloc.free(rendered);
        try self.transcript.appendSlice(self.alloc, rendered);
    }

    pub fn appendDomainNotice(self: *RoutingFakeApp, notice: types.SemanticNotice) !u32 {
        return self.shell.appendSemanticNotice(self.alloc, notice);
    }

    pub fn appendReplaceableDomainNotice(self: *RoutingFakeApp, notice: types.SemanticNotice) !u32 {
        return self.shell.appendReplaceableSemanticNotice(self.alloc, notice);
    }

    pub fn replaceDomainNotice(self: *RoutingFakeApp, entry_id: u32, notice: types.SemanticNotice) !bool {
        return self.shell.replaceSemanticNotice(self.alloc, entry_id, notice);
    }

    pub fn writeUserPromptCard(self: *RoutingFakeApp, user: types.UserTurn) !void {
        try self.transcript.appendSlice(self.alloc, user.text);
    }

    pub fn stopStream(self: *RoutingFakeApp, _: anytype) void {
        self.agent().stream = .{};
    }

    pub fn prepareLiveSessionResume(_: *RoutingFakeApp) !void {}

    pub fn finishLiveSessionResume(_: *RoutingFakeApp) !void {}

    pub fn resumeSelectedSession(self: *RoutingFakeApp, _: anytype) !bool {
        self.resume_selected_count += 1;
        if (self.resume_selected_closes_picker) {
            self.agent().session_persistence.session_picker.active = false;
        }
        return self.resume_selected_error;
    }

    pub fn loadMoreSessionPicker(self: *RoutingFakeApp, _: anytype) !bool {
        const picker = &self.agent().session_persistence.session_picker;
        if (!picker.active or picker.load_state != .ready or !picker.has_more or
            picker.selected != picker.filteredItemCount()) return false;
        self.load_more_session_count += 1;
        return true;
    }

    pub fn prepareResumeHandoffForUpgrade(_: *RoutingFakeApp, _: anytype) !void {}

    pub fn requestUpgradeRelaunch(
        self: *RoutingFakeApp,
        _: []const u8,
    ) !void {
        self.upgrade_apply_count += 1;
    }

    pub fn requestResumeHandoffForUpgrade(_: *RoutingFakeApp, _: anytype) void {}

    pub fn applyReadyUpgradeShortcut(self: *RoutingFakeApp, _: anytype) !void {
        const outcome = try app_upgrade_runtime.Runtime(RoutingFakeApp).applyReadyUpgradeWithDeps(
            self,
            self.agent(),
            .{
                .ctx = self,
                .current_executable_path = currentExecutablePathForRouting,
            },
        );
        if (outcome != .relaunch_requested) {
            self.upgrade_denied_count += 1;
        }
    }

    pub fn nextImageId(self: *RoutingFakeApp, _: anytype) usize {
        return image_attachments.allocateImageId(&self.next_image_id_counter);
    }

    pub fn captureImageAttachment(_: *RoutingFakeApp, _: anytype, _: *types.ImageAttachment) !void {
        return error.MissingImageSnapshot;
    }

    pub fn peekNextImageId(self: *const RoutingFakeApp, _: anytype) usize {
        return self.next_image_id_counter;
    }

    pub fn transitionFullTranscriptProjection(
        self: *RoutingFakeApp,
        event: transcript_presentation.Event,
    ) !transcript_presentation.Depth {
        self.shell.setCommandOutputRenderPolicy(
            routingFullTranscriptStyles(),
        );
        const depth = self.shell.transcriptPresentationDepth().transition(event);
        _ = try self.shell.setTranscriptPresentationDepth(self.alloc, depth);
        return depth;
    }

    pub fn writeSubagentSnapshot(self: *RoutingFakeApp) !void {
        self.subagents.toggle_view_calls += 1;
    }

    pub fn admitPendingApprovalResize(self: *RoutingFakeApp) bool {
        if (!self.approval_resize_interlock.takeResizePending()) return false;
        self.shell.render_requests.observeResizeSignal(100, 80);
        return true;
    }

    pub fn beforeApprovalAffirmativeClaim(self: *RoutingFakeApp) void {
        if (!self.inject_resize_before_affirmative_claim) return;
        self.inject_resize_before_affirmative_claim = false;
        self.approval_resize_interlock.noteResizeSignal();
    }

    pub fn claimApprovalAffirmative(self: *RoutingFakeApp) bool {
        self.affirmative_claim_count += 1;
        return self.approval_resize_interlock.claimAffirmative();
    }

    pub fn releaseApprovalAffirmative(self: *RoutingFakeApp) void {
        self.affirmative_release_count += 1;
        self.approval_resize_interlock.releaseAffirmative();
    }

    pub fn enqueuePrompt(self: *RoutingFakeApp, text: []const u8) !bool {
        self.submitted_prompt_len = @min(text.len, self.submitted_prompt.len);
        @memcpy(self.submitted_prompt[0..self.submitted_prompt_len], text[0..self.submitted_prompt_len]);
        self.submitted_prompt_count += 1;
        return true;
    }

    pub fn handleCommand(self: *RoutingFakeApp, command: []const u8) !void {
        if (self.last_command) |previous| self.alloc.free(previous);
        self.last_command = try self.alloc.dupe(u8, command);
        self.input_len_at_command = self.input_runtime.edit_state.input.items.len;
        self.pasted_block_count_at_command = self.input_runtime.entities.pasted_blocks.items.len;
    }

    pub fn persistRuntimePreferences(
        self: *RoutingFakeApp,
        _: anytype,
        patch: app_session_runtime.SessionPreferencePatch,
    ) app_session_runtime.PreferenceCommitResult {
        self.preference_commit_count += 1;
        self.last_preference_model.clearRetainingCapacity();
        if (patch.model) |model| {
            self.last_preference_model.appendSlice(self.alloc, model) catch
                return .{ .settings_error = error.OutOfMemory };
        }
        self.last_preference_effort = patch.effort;
        self.last_preference_fast_mode = patch.fast_mode;
        return .{};
    }

    pub fn persistPermissionModePreference(
        self: *RoutingFakeApp,
        mode: types.PermissionMode,
    ) !void {
        self.permission_mode_preference_commit_count += 1;
        self.last_preference_permission_mode = mode;
    }

    pub fn clearPendingImages(self: *RoutingFakeApp, _: anytype) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        image_attachments.discardImageSnapshots(self.alloc, self.agent().pending_images.items);
        for (self.agent().pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.agent().pending_images.clearRetainingCapacity();
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

fn routingOpenUrl(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
) host.UrlOpenError!bool {
    return false;
}

fn currentExecutablePathForRouting(
    _: ?*anyopaque,
    executable_buf: []u8,
) upgrade_helpers.ExecutablePathError![]const u8 {
    const executable_path = "/tmp/spark-routing-upgraded";
    if (executable_path.len > executable_buf.len) return error.PathTooLong;
    @memcpy(executable_buf[0..executable_path.len], executable_path);
    return executable_buf[0..executable_path.len];
}

fn readTraceFileForTest(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 8192);
}

fn activateFullTranscriptForRoutingTest(app: *RoutingFakeApp) void {
    app.terminal.alternate_screen_owner = .full_transcript;
    app.terminal.alternate_mouse_tracking_active = false;
    app.shell.full_transcript = .{ .depth = .full, .follow_tail = true };
}

fn appendRoutingSessionPickerSummary(
    alloc: std.mem.Allocator,
    picker: *app_session_runtime.SessionPicker,
    index: usize,
) !void {
    const id = try alloc.print("session-{d}", .{index});
    errdefer alloc.free(id);
    const workspace_root = try alloc.print("/tmp/workspace-{d}", .{index});
    errdefer alloc.free(workspace_root);
    const title = try alloc.print("session {d}", .{index});
    errdefer alloc.free(title);
    const preview = try alloc.print("session {d} preview", .{index});
    errdefer alloc.free(preview);
    try picker.summaries.append(alloc, .{
        .id = id,
        .workspace_root = workspace_root,
        .title = title,
        .preview = preview,
        .display_metadata_present = true,
        .created_at_ms = 0,
        .updated_at_ms = 0,
        .conversation_language = session_runtime.ConversationLanguage.literal("en"),
        .history_len = 1,
    });
}

test "app_input_runtime slash completion movement works while stream is active" {
    const alloc = std.testing.allocator;
    var app = FakeApprovalCancelApp{ .alloc = alloc };
    defer app.deinit();

    try app.input_runtime.edit_state.input.appendSlice(alloc, "/");
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;

    const count = command_specs.slashCompletionCount(app.slashRegistry(), app.input_runtime.edit_state.input.items);
    try std.testing.expect(count > 1);
    try std.testing.expect(app.agent().stream.active);

    try std.testing.expect(Runtime(FakeApprovalCancelApp).routeSlashCompletionMove(&app, (&app).agent(), 1));

    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.picker.slash_completion_index);
    try std.testing.expectEqual(app.input_runtime.edit_state.input.items.len, app.input_runtime.edit_state.cursor);

    try std.testing.expect(Runtime(FakeApprovalCancelApp).routeSlashCompletionMove(&app, (&app).agent(), -1));

    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.picker.slash_completion_index);
    try std.testing.expectEqual(app.input_runtime.edit_state.input.items.len, app.input_runtime.edit_state.cursor);

    app.input_runtime.picker.dismissInlinePicker(.slash);
    try std.testing.expect(!Runtime(FakeApprovalCancelApp).routeSlashCompletionMove(&app, (&app).agent(), 1));
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.picker.slash_completion_index);
}

fn presentRoutingFilePicker(app: *RoutingFakeApp) void {
    const rt = input_completion_runtime.CompletionRuntime(RoutingFakeApp);
    rt.prepareFilePicker(app, agents.screenAgentOf(app));
    if (rt.filePickerView(app).receipt) |receipt| rt.acknowledgeFilePicker(app, agents.screenAgentOf(app), receipt);
}

fn currentQuestionChoiceForRoutingTest(prompt: *const question_prompt.QuestionPrompt) u8 {
    return prompt.entries.items[prompt.current_index].choice_index;
}

fn feedRoutingBytes(app: *RoutingFakeApp, bytes: []const u8) !void {
    return feedRoutingBytesWithLimit(app, bytes, RoutingFakeApp.input_byte_limit);
}

fn feedRoutingBytesWithLimit(app: *RoutingFakeApp, bytes: []const u8, max_input_len: usize) !void {
    for (bytes) |byte| {
        try Runtime(RoutingFakeApp).handleByte(app, byte, max_input_len, 100);
    }
    try Runtime(RoutingFakeApp).settleTerminalPasteDeliveryEpochWithLimits(
        app,
        agents.screenAgentOf(app),
        paste_framing.InputLimits.single(max_input_len),
    );
}

fn primeComposerHistoryForTest(comptime App: type, app: *App, draft: []const u8) !void {
    try app.input_runtime.composer_history.installTextEntries(
        app.alloc,
        &.{"history entry"},
    );
    try app.input_runtime.textReplacementState().replace(app.alloc, draft);
    try input_completion_runtime.CompletionRuntime(App).navigatePromptHistory(app, agents.screenAgentOf(app), -1);
}

fn openRoutingModelMenu(app: *RoutingFakeApp, model_ids: []const []const u8) !void {
    const menu = &app.model_cache.menu;
    menu.active = true;
    menu.load_state = .ready;
    for (model_ids) |model_id| {
        const owned_id = try app.alloc.dupe(u8, model_id);
        var item_owns_id = false;
        errdefer if (!item_owns_id) app.alloc.free(owned_id);
        const provider_end = std.mem.findScalar(u8, owned_id, '/') orelse owned_id.len;
        const provider = owned_id[0..provider_end];
        try menu.items.append(app.alloc, .{
            .id = owned_id,
            .provider = provider,
            .capabilities = app.resolvedModelCapabilities(owned_id),
        });
        item_owns_id = true;
    }
}

fn setRoutingModelMenuReady(app: *RoutingFakeApp, model_ids: []const []const u8) !void {
    app.model_cache.menu.load_state = .ready;
    for (model_ids) |model_id| {
        const owned_id = try app.alloc.dupe(u8, model_id);
        errdefer app.alloc.free(owned_id);
        const provider_end = std.mem.findScalar(u8, owned_id, '/') orelse owned_id.len;
        try app.model_cache.menu.items.append(app.alloc, .{
            .id = owned_id,
            .provider = owned_id[0..provider_end],
            .capabilities = app.resolvedModelCapabilities(owned_id),
        });
    }
}

/// Fixture model that offers both effort and Fast mode choices.
const routing_staged_model = "test/staged-model";
const routing_staged_efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("future-tier")};

/// Stashes `draft` behind the Ctrl+P catalog and picks the staged fixture
/// model, leaving its inline effort stage open in the borrowed composer.
fn enterRoutingShortcutEffortStage(app: *RoutingFakeApp, draft: []const u8, cursor: usize) !void {
    app.setGatewayControls(routing_staged_model, &routing_staged_efforts, true);
    try app.input_runtime.textReplacementState().replace(app.alloc, draft);
    app.input_runtime.edit_state.cursor = cursor;
    try feedRoutingBytes(app, "\x10");
    try setRoutingModelMenuReady(app, &.{routing_staged_model});
    try Runtime(RoutingFakeApp).handleByte(app, '\r', 4096, 100);
}

const routing_cycle_efforts = [_]types.ReasoningEffort{
    types.ReasoningEffort.literal("low"),
    types.ReasoningEffort.literal("medium"),
    types.ReasoningEffort.literal("high"),
};

const RoutingDraftKind = enum {
    text,
    paste,
    image,
};

fn seedRoutingDraftForGuard(app: *RoutingFakeApp, kind: RoutingDraftKind) !void {
    switch (kind) {
        .text => try app.input_runtime.textReplacementState().replace(app.alloc, "guarded draft"),
        .paste => try app.input_runtime.entities.pasted_blocks.append(app.alloc, .{
            .id = 1,
            .text = try app.alloc.dupe(u8, "guarded pasted text"),
            .line_count = 1,
        }),
        .image => try agents.screenAgentOf(app).pending_images.append(app.alloc, .{
            .id = 1,
            .path = try app.alloc.dupe(u8, "/tmp/guarded-image.png"),
            .media_type = try app.alloc.dupe(u8, "image/png"),
        }),
    }
}

fn expectRoutingDraftForGuard(app: *const RoutingFakeApp, kind: RoutingDraftKind) !void {
    switch (kind) {
        .text => try std.testing.expectEqualStrings("guarded draft", app.input_runtime.edit_state.input.items),
        .paste => {
            try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
            try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.pasted_blocks.items.len);
            try std.testing.expectEqualStrings("guarded pasted text", app.input_runtime.entities.pasted_blocks.items[0].text);
        },
        .image => {
            try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
            try std.testing.expectEqual(@as(usize, 1), agents.screenAgentOf(app).pending_images.items.len);
            try std.testing.expectEqualStrings("/tmp/guarded-image.png", agents.screenAgentOf(app).pending_images.items[0].path);
        },
    }
}

const FakeSubmitApp = struct {
    pub const input_byte_limit: usize = 4096;

    alloc: std.mem.Allocator,
    workspace_root: []const u8 = "/tmp/workspace",
    input_runtime: core_input_runtime.Runtime = .{},
    prompt_history: prompt_history_runtime.PromptHistoryRuntime = .{},
    main_agent: struct {
        pending_images: std.ArrayList(types.ImageAttachment) = .empty,
        submission: input_submit_runtime.State = .{},
        stream: types.StreamState = .{},
        worker: struct {
            hold_available: bool = false,
            held: bool = false,
            queued_turn_id: ?u64 = null,
            queued_images: []types.ImageAttachment = &.{},
            queued_images_alloc: ?std.mem.Allocator = null,

            pub fn queuedPromptCount(_: *@This()) usize {
                return 0;
            }

            pub fn tryHoldTurnStart(self: *@This()) bool {
                if (!self.hold_available or self.held) return false;
                self.held = true;
                return true;
            }

            pub fn releaseTurnStartHold(self: *@This()) void {
                self.held = false;
            }

            pub fn removeQueuedPrompt(
                self: *@This(),
                _: std.mem.Allocator,
                turn_id: u64,
                retained_images: []const types.ImageAttachment,
            ) bool {
                if (self.queued_turn_id != turn_id) return false;
                image_attachments.deleteUnreferencedImageSnapshots(
                    self.queued_images,
                    retained_images,
                );
                self.freeQueuedImageMetadata();
                self.queued_turn_id = null;
                return true;
            }

            pub fn clearQueuedPrompts(
                self: *@This(),
                _: std.mem.Allocator,
                retained_images: []const types.ImageAttachment,
            ) void {
                image_attachments.deleteUnreferencedImageSnapshots(
                    self.queued_images,
                    retained_images,
                );
                self.freeQueuedImageMetadata();
                self.queued_turn_id = null;
            }

            fn freeQueuedImageMetadata(self: *@This()) void {
                if (self.queued_images_alloc) |alloc| {
                    types.freeImageAttachmentSlice(alloc, self.queued_images);
                }
                self.queued_images = &.{};
                self.queued_images_alloc = null;
            }

            pub fn clearQueuedPromptsForSessionTransition(
                self: *@This(),
                alloc: std.mem.Allocator,
                _: u64,
                retained_images: []const types.ImageAttachment,
            ) void {
                self.clearQueuedPrompts(alloc, retained_images);
            }

            pub fn activeTurnId(_: *const @This()) u64 {
                return 0;
            }

            pub fn requestCancel(_: *@This()) void {}
        } = .{},
    } = .{},
    pacer: struct {
        pending: bool = false,
        completed_assistant_presentation_tail: bool = false,

        pub fn hasPending(self: *const @This()) bool {
            return self.pending;
        }

        pub fn hasCompletedAssistantPresentationTail(self: *const @This()) bool {
            return self.completed_assistant_presentation_tail;
        }
    } = .{},
    shell: struct {
        render_requests: render_request.RenderRequestState = .{},
        full_transcript_active: bool = false,
        layout: types.Layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },

        pub fn fullTranscriptActive(self: *const @This()) bool {
            return self.full_transcript_active;
        }
    } = .{},
    next_image_id_counter: usize = 1,
    transcript: std.ArrayList(u8) = .empty,
    last_command: ?[]u8 = null,
    last_prompt: ?[]u8 = null,
    last_images: []types.ImageAttachment = &.{},
    last_skill_tokens: std.ArrayList(registered_entities.SkillTokenSpan) = .empty,
    notice_topic: std.ArrayList(u8) = .empty,
    notice_body: std.ArrayList(u8) = .empty,
    notice_tone: types.NoticeTone = .information,
    notice_visibility: types.NoticeVisibility = .compact_and_full,
    input_len_at_command: usize = 0,
    command_count: usize = 0,
    fail_notice: bool = false,
    prompt_admitted: bool = true,
    queue_admitted: bool = true,
    queue_accept_count: usize = 0,
    /// Every credential admission, blocking or queued.
    preflight_count: usize = 0,
    /// Admissions through `ensurePromptCredential`, which may refresh inline.
    blocking_preflight_count: usize = 0,
    notice_count: usize = 0,
    capture_count: usize = 0,
    capture_error_id: ?usize = null,
    capture_error: ?anyerror = null,
    fail_enqueue_after_snapshot: bool = false,
    fail_pending_finalization: bool = false,
    fail_command_after_pending_clear: bool = false,
    snapshot_dir: ?[]const u8 = null,
    /// Submits land on a subagent's screen, whose turns open a work in the
    /// parent's log.
    on_subagent_screen: bool = false,
    /// Works those submits opened.
    opened_turn_works: usize = 0,

    pub fn slashRegistry(_: *const FakeSubmitApp) command_specs.SlashRegistry {
        return routing_test_slash_registry;
    }

    pub fn prepareSubagentOnScreen(self: *FakeSubmitApp, _: anytype) !bool {
        return self.on_subagent_screen;
    }

    pub fn openSubagentTurnWork(self: *FakeSubmitApp) void {
        self.opened_turn_works += 1;
    }

    pub fn screenAgentId(self: *const FakeSubmitApp) []const u8 {
        return if (self.on_subagent_screen) "reviewer" else "main";
    }

    fn deinit(self: *FakeSubmitApp) void {
        if (self.agent().submission.pending) |*pending| pending.deinit(self.alloc);
        self.agent().submission.pending = null;
        self.prompt_history.deinit(self.alloc);
        self.clearPendingImages(&self.main_agent);
        self.agent().pending_images.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.notice_topic.deinit(self.alloc);
        self.notice_body.deinit(self.alloc);
        if (self.last_command) |text| self.alloc.free(text);
        if (self.last_prompt) |text| self.alloc.free(text);
        types.freeImageAttachmentSlice(self.alloc, self.last_images);
        self.clearLastSkillTokens();
        self.last_skill_tokens.deinit(self.alloc);
        self.agent().worker.freeQueuedImageMetadata();
    }

    pub fn writeDomainNotice(self: *FakeSubmitApp, notice: types.SemanticNotice, _: bool) !void {
        if (self.fail_notice) return error.InjectedTranscriptFailure;
        self.notice_count += 1;
        self.notice_topic.clearRetainingCapacity();
        self.notice_body.clearRetainingCapacity();
        try self.notice_topic.appendSlice(self.alloc, notice.topic);
        try self.notice_body.appendSlice(self.alloc, notice.body);
        self.notice_tone = notice.tone;
        self.notice_visibility = notice.visibility;
    }

    pub fn clearPendingImages(self: *FakeSubmitApp, _: anytype) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        image_attachments.discardImageSnapshots(self.alloc, self.agent().pending_images.items);
        for (self.agent().pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.agent().pending_images.clearRetainingCapacity();
    }

    pub fn releasePendingImages(self: *FakeSubmitApp, _: anytype) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        for (self.agent().pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.agent().pending_images.clearRetainingCapacity();
    }

    pub fn captureImageAttachment(self: *FakeSubmitApp, _: anytype, attachment: *types.ImageAttachment) !void {
        self.capture_count += 1;
        if (self.capture_error_id == attachment.id) {
            return self.capture_error orelse error.ImageTooLarge;
        }
        const snapshot_dir = self.snapshot_dir orelse return;
        try image_attachments.captureImageSnapshot(self.alloc, attachment, snapshot_dir);
    }

    pub fn handleCommand(self: *FakeSubmitApp, text: []const u8) !void {
        if (self.last_command) |old| self.alloc.free(old);
        self.last_command = try self.alloc.dupe(u8, text);
        self.command_count += 1;
        self.input_len_at_command = self.input_runtime.edit_state.input.items.len;
        if (std.mem.eql(u8, text, "/images clear")) {
            self.clearPendingImages(&self.main_agent);
            if (self.fail_command_after_pending_clear) return error.InjectedCommandFailure;
        }
        // Attach through the production handler so routing tests observe real placeholder
        // insertion, id allocation, and snapshot capture rather than a stub.
        const attach_prefix: ?[]const u8 = if (std.mem.startsWith(u8, text, "/image "))
            "/image "
        else if (std.mem.startsWith(u8, text, "/img "))
            "/img "
        else
            null;
        if (attach_prefix) |prefix| {
            try image_commands.Commands(FakeSubmitApp).attachPath(self, text[prefix.len..]);
        }
    }

    pub fn ensurePromptCredential(self: *FakeSubmitApp, _: anytype) !bool {
        self.preflight_count += 1;
        self.blocking_preflight_count += 1;
        return self.prompt_admitted;
    }

    pub fn admitQueuedPromptCredential(self: *FakeSubmitApp, _: anytype) !bool {
        self.preflight_count += 1;
        return self.prompt_admitted;
    }

    pub fn adoptPendingUserPrompt(
        _: *FakeSubmitApp,
        _: anytype,
        _: *const input_submit_runtime.PendingPromptDraft,
    ) !void {}

    pub fn finalizePendingSubmission(
        self: *FakeSubmitApp,
        _: anytype,
        draft: *const input_submit_runtime.PendingPromptDraft,
    ) !void {
        if (self.fail_pending_finalization) {
            return error.InjectedPendingFinalizationFailure;
        }
        self.agent().worker.freeQueuedImageMetadata();
        self.agent().worker.queued_images = try types.dupeImageAttachmentSlice(
            self.alloc,
            draft.images,
        );
        self.agent().worker.queued_images_alloc = self.alloc;
        self.agent().worker.queued_turn_id = draft.turn_id;
    }

    pub fn enqueuePrompt(self: *FakeSubmitApp, text: []const u8) !bool {
        return self.enqueuePromptWithSkillBindings(text, &.{});
    }

    pub fn enqueuePromptWithSkillBindings(
        self: *FakeSubmitApp,
        _: anytype,
        text: []const u8,
        skill_tokens: []const registered_entities.SkillTokenSpan,
    ) !bool {
        if (!self.queue_admitted) return false;
        const prompt_copy = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(prompt_copy);
        const images_copy = try types.dupeImageAttachmentSlice(self.alloc, self.agent().pending_images.items);
        errdefer types.freeImageAttachmentSlice(self.alloc, images_copy);
        if (self.fail_enqueue_after_snapshot) return error.InjectedEnqueueFailure;
        if (self.last_prompt) |old| self.alloc.free(old);
        self.last_prompt = prompt_copy;
        types.freeImageAttachmentSlice(self.alloc, self.last_images);
        self.last_images = images_copy;
        self.clearLastSkillTokens();
        errdefer self.clearLastSkillTokens();
        try self.last_skill_tokens.ensureTotalCapacity(self.alloc, skill_tokens.len);
        for (skill_tokens) |token| {
            const name = try self.alloc.dupe(u8, token.name);
            var appended = false;
            errdefer if (!appended) self.alloc.free(name);
            const path = try self.alloc.dupe(u8, token.path);
            errdefer if (!appended) self.alloc.free(path);
            self.last_skill_tokens.appendAssumeCapacity(.{
                .raw_start = token.raw_start,
                .raw_end = token.raw_end,
                .name = name,
                .path = path,
            });
            appended = true;
        }
        self.queue_accept_count += 1;
        return true;
    }

    pub fn nextImageId(self: *FakeSubmitApp, _: anytype) usize {
        return image_attachments.allocateImageId(&self.next_image_id_counter);
    }

    pub fn peekNextImageId(self: *const FakeSubmitApp, _: anytype) usize {
        return self.next_image_id_counter;
    }

    fn clearLastSkillTokens(self: *FakeSubmitApp) void {
        for (self.last_skill_tokens.items) |token| {
            self.alloc.free(@constCast(token.name));
            self.alloc.free(@constCast(token.path));
        }
        self.last_skill_tokens.clearRetainingCapacity();
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

const FrameSubmitApp = struct {
    alloc: std.mem.Allocator,
    workspace_root: []const u8 = "/tmp/workspace",
    input_runtime: core_input_runtime.Runtime = .{},
    main_agent: struct {
        pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    } = .{},
    next_image_id_counter: usize = 1,
    shell: transcript_runtime.TranscriptRuntime,
    metrics: types.Metrics = .{},
    command_seen: bool = false,

    pub fn slashRegistry(_: *const FrameSubmitApp) command_specs.SlashRegistry {
        return routing_test_slash_registry;
    }

    fn deinit(self: *FrameSubmitApp) void {
        self.clearPendingImages(&self.main_agent);
        self.agent().pending_images.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.shell.deinit(self.alloc);
    }

    pub fn clearPendingImages(self: *FrameSubmitApp, _: anytype) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        for (self.agent().pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.agent().pending_images.clearRetainingCapacity();
    }

    pub fn handleCommand(self: *FrameSubmitApp, _: []const u8) !void {
        self.command_seen = true;
        try self.writeDomainNotice(.{
            .topic = "system",
            .tone = .information,
            .body = "command result",
        }, true);
    }

    pub fn writeDomainNotice(self: *FrameSubmitApp, notice: types.SemanticNotice, record: bool) !void {
        try self.shell.writeNotice(self.alloc, &self.metrics, notice, record);
    }

    pub fn enqueuePrompt(_: *FrameSubmitApp, _: []const u8) !bool {
        return true;
    }

    pub fn nextImageId(self: *FrameSubmitApp, _: anytype) usize {
        return image_attachments.allocateImageId(&self.next_image_id_counter);
    }

    pub fn peekNextImageId(self: *const FrameSubmitApp, _: anytype) usize {
        return self.next_image_id_counter;
    }

    pub fn captureImageAttachment(_: *FrameSubmitApp, _: anytype, _: *types.ImageAttachment) !void {
        return error.MissingImageSnapshot;
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

fn writeTestImage(tmp: *std.testing.TmpDir, name: []const u8) !void {
    var file = try tmp.dir.createFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\nrest");
}

fn realTmpPath(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, name);
}

fn countTestSnapshotFiles(path: []const u8) !usize {
    var dir = std.Io.Dir.openDirAbsolute(std.testing.io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind == .file or entry.kind == .sym_link) count += 1;
    }
    return count;
}

fn appendOwnedPendingImage(app: *FakeSubmitApp, id: usize, path: []const u8) !void {
    const path_copy = try app.alloc.dupe(u8, path);
    errdefer app.alloc.free(path_copy);
    const media_type = try app.alloc.dupe(u8, "image/png");
    errdefer app.alloc.free(media_type);
    try agents.screenAgentOf(app).pending_images.append(app.alloc, .{
        .id = id,
        .path = path_copy,
        .media_type = media_type,
    });
}

fn appendImageTokenForPlaceholderAt(
    app: *FakeSubmitApp,
    id: usize,
    raw_start: usize,
) !void {
    var placeholder_buf: [32]u8 = undefined;
    const placeholder = try image_attachments.formatImagePlaceholder(
        &placeholder_buf,
        id,
    );
    try app.input_runtime.entities.image_tokens.append(app.alloc, .{
        .id = id,
        .span = .{
            .raw_start = raw_start,
            .raw_end = raw_start + placeholder.len,
        },
    });
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.find(u8, haystack[start..], needle)) |relative| {
        count += 1;
        start += relative + needle.len;
    }
    return count;
}

fn runRepeatedImageCommand(alloc: std.mem.Allocator, input: []const u8) !void {
    var app = FakeSubmitApp{ .alloc = alloc, .prompt_admitted = false, .queue_admitted = false };
    defer app.deinit();
    try appendOwnedPendingImage(&app, 1, "/tmp/first.png");
    app.next_image_id_counter = 2;
    try app.input_runtime.edit_state.input.appendSlice(alloc, input);
    try appendImageTokenForPlaceholderAt(&app, 1, 0);
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    try Runtime(FakeSubmitApp).submit(&app, 100);
}

fn checkAcceptedPromptCleanupAcrossAllocationFailures(failing: *std.testing.FailingAllocator) !void {
    const alloc = failing.allocator();
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendSlice(alloc, "accepted prompt");
    app.input_runtime.edit_state.cursor = "accepted prompt".len;

    Runtime(FakeSubmitApp).submit(&app, 100) catch |err| {
        if (app.queue_accept_count > 0) return error.AcceptedPromptReturnedError;
        return err;
    };

    if (app.queue_accept_count > 0) {
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
        try std.testing.expectEqual(@as(usize, 0), app.agent().pending_images.items.len);
    }
}

fn check_inline_image_edit_allocation_failure(failing: *std.testing.FailingAllocator, root: []const u8, snapshot_dir: []const u8) !void {
    const alloc = failing.allocator();
    const input = " \t[Image #8]\n@./first.png $review  \r\n";
    var app = FakeSubmitApp{
        .alloc = alloc,
        .workspace_root = root,
        .snapshot_dir = snapshot_dir,
        .next_image_id_counter = 9,
        .queue_admitted = false,
    };
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendSlice(alloc, input);
    app.input_runtime.edit_state.cursor = input.len;
    try appendOwnedPendingImage(&app, 8, "/tmp/retained.png");
    try appendImageTokenForPlaceholderAt(&app, 8, 2);
    const skill_start = std.mem.find(u8, input, "$review").?;
    try app.input_runtime.entities.skill_tokens.ensureUnusedCapacity(alloc, 1);
    const name = try alloc.dupe(u8, "review");
    const path = alloc.dupe(u8, "/tmp/review/SKILL.md") catch |err| {
        alloc.free(name);
        return err;
    };
    app.input_runtime.entities.skill_tokens.appendAssumeCapacity(.{ .raw_start = skill_start, .raw_end = skill_start + "$review".len, .name = name, .path = path });
    const result = Runtime(FakeSubmitApp).submit(&app, 100);
    try std.testing.expectEqualStrings(input, app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(input.len, app.input_runtime.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 9), app.next_image_id_counter);
    try std.testing.expectEqual(@as(usize, 1), app.agent().pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 8), app.agent().pending_images.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.skill_tokens.items.len);
    try std.testing.expectEqual(skill_start, app.input_runtime.entities.skill_tokens.items[0].raw_start);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.composer_history.count());
    try std.testing.expectEqual(@as(usize, 0), app.queue_accept_count);
    try std.testing.expectEqual(@as(usize, 0), try countTestSnapshotFiles(snapshot_dir));
    try result;
}

const PromptHistoryBusyLockState = struct {
    now_ms: i64 = 0,

    fn tryLock(_: ?*anyopaque, _: std.Io.File) anyerror!bool {
        return false;
    }

    fn now(ctx: ?*anyopaque) i64 {
        const self: *PromptHistoryBusyLockState =
            @ptrCast(@alignCast(ctx.?));
        return self.now_ms;
    }

    fn sleep(ctx: ?*anyopaque, millis: u64) void {
        const self: *PromptHistoryBusyLockState =
            @ptrCast(@alignCast(ctx.?));
        self.now_ms += @intCast(millis);
    }
};

fn checkImagePathPasteAllocationFailureIsAtomic(
    failing: *std.testing.FailingAllocator,
    path: []const u8,
) !void {
    const alloc = failing.allocator();
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    app.next_image_id_counter = 7;

    Runtime(FakeSubmitApp).handlePastedBytes(
        &app,
        (&app).agent(),
        path,
        FakeSubmitApp.input_byte_limit,
    ) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.cursor);
        try std.testing.expectEqual(@as(usize, 0), app.agent().pending_images.items.len);
        try std.testing.expectEqual(@as(usize, 7), app.next_image_id_counter);
        return err;
    };

    try std.testing.expectEqualStrings("[Image #7]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.agent().pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 7), app.agent().pending_images.items[0].id);
    try std.testing.expectEqual(@as(usize, 8), app.next_image_id_counter);
}
