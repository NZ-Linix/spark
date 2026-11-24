const std = @import("std");
const agents = @import("../agents/agents.zig");
const question_prompt = @import("../agent/question_prompt.zig");
const input_completion_runtime = @import("input_completion_runtime.zig");
const app_commands = @import("app_commands.zig");
const app_lifecycle = @import("app_lifecycle.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const terminal_ui_projection = @import("../terminal/ui_projection.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const session_context = @import("../config/session_context.zig");
const picker_state = @import("../input/picker_state.zig");
const core_input_runtime = @import("../input/runtime.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const model_cache_runtime = @import("model_cache_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diff_mod = @import("../output/diff.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const types = @import("../shared/types.zig");
const file_index = @import("../workspace/file_index.zig");
const statusline_identity = @import("../workspace/statusline_identity.zig");
const activity_runtime = @import("../output/activity_runtime.zig");
const transcript_presentation = @import("../output/transcript_presentation.zig");
const event_loop = @import("../../ui/event_loop.zig");
const surface_frame = @import("../../ui/footer/surface_frame.zig");
const surface_invalidation = @import("../../ui/footer/surface_invalidation.zig");
const render_input = @import("../../ui/footer/render_input.zig");
const picker_presentation = @import("../../ui/footer/picker_presentation.zig");
const input_presentation = @import("../../ui/footer/input_presentation.zig");
const footer_viewport = @import("../../ui/footer/viewport.zig");
const render_request = @import("../../ui/render_request.zig");
const ui_input = @import("../../ui/input/runtime.zig");
const input_visual_layout = @import("../../ui/input/visual_layout.zig");
const registered_entities = @import("../input/registered_entities.zig");
const full_transcript_screen = @import("../../ui/full_transcript_screen.zig");
const session_child_store = @import("../session/session_child_store.zig");
const render_engine = @import("../../ui/render_engine.zig");
const build_checkpoint = @import("../../ui/render_engine/build_checkpoint.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const shimmer_runtime = @import("../../ui/transcript/shimmer_runtime.zig");
const ui_terminal = @import("../../ui/terminal/terminal.zig");
const vt_emulator = @import("../terminal/engine.zig");
const transcript_painter = @import("../../ui/transcript/painter.zig");
const command_output_runtime = @import("../../ui/transcript/command_output_runtime.zig");
const resume_projection = @import("../../ui/transcript/resume_projection.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");
const ui_render = @import("../../ui/render.zig");
const shared_theme = @import("../shared/theme.zig");
const assistant_pacer = @import("../../ui/assistant/pacer.zig");
const user_message_card = @import("../../ui/assistant/user_message_card.zig");

fn set_transcript_assistant_tail_writable(
    runtime: *transcript_runtime.TranscriptRuntime,
    writable: bool,
) void {
    if (runtime.notebook.transcript_release.assistant_tail_writable == writable) return;
    runtime.notebook.transcript_release = runtime.notebook.transcript_release.with_assistant_tail_writable(writable);
    debug_trace.logf(
        "scroll",
        "assistant tail writability changed writable={s}",
        .{if (writable) "true" else "false"},
    );
}

pub const VisualEpochResetTrigger = enum {
    native_clear_probe,
    ctrl_l,
};

const FrameAttemptResult = struct {
    shadow_state: render_engine.terminal_diff.ShadowCommitState,
    animation_visible: bool,
    pending_prompt_presented: bool = false,
    file_picker_receipt: ?input_completion_runtime.FilePickerReceipt = null,

    fn is_committed(self: FrameAttemptResult) bool {
        return self.shadow_state.is_committed();
    }
};

const InlineRenderReconciliation = struct {
    alternate_screen_owns_rendering: bool = false,
    terminal_transition: render_engine.terminal_diff.FrameTerminalTransition = .none,
};

/// Couples the physical terminal buffer with the logical presentation that
/// owns retry invalidations.
const SurfaceFrameShell = struct {
    output: *transcript_runtime.TranscriptRuntime,
    invalidation_owner: *transcript_runtime.TranscriptRuntime,
    shadow_vt: ?*vt_emulator.Grid,
    committed_frame_layout: render_engine.frame_layout.CommittedLayoutSnapshot,
    history_reset_uses_ris: bool,

    fn init(
        output: *transcript_runtime.TranscriptRuntime,
        invalidation_owner: *transcript_runtime.TranscriptRuntime,
        committed_frame_layout: render_engine.frame_layout.CommittedLayoutSnapshot,
    ) SurfaceFrameShell {
        return .{
            .output = output,
            .invalidation_owner = invalidation_owner,
            .shadow_vt = output.shadow_vt,
            .committed_frame_layout = committed_frame_layout,
            .history_reset_uses_ris = output.history_reset_uses_ris,
        };
    }

    pub fn frameSink(
        self: *SurfaceFrameShell,
    ) render_engine.terminal_diff.FrameSink {
        return self.output.frameSink();
    }

    pub fn recordFrameInvalidation(
        self: *SurfaceFrameShell,
        range: render_engine.paint_plan.FrameInvalidationRange,
    ) !void {
        try self.invalidation_owner.recordFrameInvalidation(range);
    }
};

const RenderReconciliation = union(enum) {
    inline_render: InlineRenderReconciliation,
    frame_result: FrameAttemptResult,
};

const SteeringProjection = struct {
    messages: [][]u8 = &.{},
    pending_feedback: [][]u8 = &.{},
    waits_for_boundary: bool = false,

    fn deinit(self: *SteeringProjection, alloc: std.mem.Allocator) void {
        for (self.messages) |message| alloc.free(message);
        if (self.messages.len > 0) alloc.free(self.messages);
        for (self.pending_feedback) |message| alloc.free(message);
        if (self.pending_feedback.len > 0) alloc.free(self.pending_feedback);
        self.* = .{};
    }
};

const PendingCardProjection = struct {
    bytes: []u8,
    row_count: u16,
    paint_row_count: u16,
    leading_advance_rows: u16,

    fn overlaps_flow_endpoint(self: PendingCardProjection, cursor_col: u16) bool {
        return self.leading_advance_rows == 0 and cursor_col > 1;
    }

    fn deinit(self: *PendingCardProjection, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
        self.* = undefined;
    }
};

const PendingCardPaintContext = struct {
    bytes: []const u8,
    row: u16,
    max_rows: u16,

    fn init(
        card: PendingCardProjection,
        band: render_engine.paint_plan.FrameBand,
        canonical_cursor_row: ?u16,
        activity_visible: bool,
    ) ?PendingCardPaintContext {
        if (band.isEmpty()) return null;
        const row = if (canonical_cursor_row) |base|
            @max(base +| card.leading_advance_rows, band.top)
        else
            band.top;
        if (row > band.bottom) return null;
        const blank_rows: u16 = @intFromBool(activity_visible and band.bottom > row);
        const bottom = band.bottom - blank_rows;
        const max_rows = @min(card.paint_row_count, bottom - row + 1);
        if (max_rows == 0) return null;
        var lines = std.mem.splitScalar(u8, card.bytes, '\n');
        for (0..card.paint_row_count - max_rows) |_| _ = lines.next();
        return .{ .bytes = lines.rest(), .row = row, .max_rows = max_rows };
    }

    fn paint(
        raw: *anyopaque,
        surface: *render_engine.frame_surface.FrameSurface,
    ) anyerror!void {
        const self: *PendingCardPaintContext = @ptrCast(@alignCast(raw));
        _ = try surface.writeAnsiBandNoWrap(
            self.row,
            self.max_rows,
            self.bytes,
            .transcript,
            .same_owner,
        );
    }
};

// A mid-line flow endpoint always takes the canonical user-turn separator,
// even at the content bottom: the frame scrolls to reserve the card rows, so
// the preview starts on a fresh row instead of overwriting the endpoint.
fn pendingCardLeadingAdvanceRows(cursor_col: u16) u16 {
    if (cursor_col == 1) return 0;
    return render_engine.transcript_blocks.blockSeparatorNewlineCount(
        .unknown_raw,
        .user_turn,
    );
}

fn buildPendingCardProjection(
    comptime App: type,
    app: *App,
    presentation_shell: *const transcript_runtime.TranscriptRuntime,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !?PendingCardProjection {
    if (comptime !agents.hasAgentField(App, "submission")) return null;
    const pending = agents.screenAgentOf(app).submission.pending orelse return null;
    switch (pending.phase) {
        .awaiting_frame, .awaiting_adoption => {},
        .adopted, .awaiting_auth, .queued => return null,
    }

    const spans = pending.draft.skill_display_spans;
    const skill_tokens: []registered_entities.SkillTokenSpan = if (spans.len == 0)
        &.{}
    else
        try app.alloc.alloc(registered_entities.SkillTokenSpan, spans.len);
    defer if (skill_tokens.len > 0) app.alloc.free(skill_tokens);
    for (spans, 0..) |span, index| {
        skill_tokens[index] = .{
            .raw_start = span.raw_start,
            .raw_end = span.raw_end,
            .name = span.name,
            .path = span.path,
            .display_source = span.display_source,
            .owns_trailing_separator = span.owns_trailing_separator,
        };
    }

    const cursor_row = @min(
        @max(presentation_shell.cursor_row, 1),
        presentation_shell.layout.content_bottom,
    );
    const leading_advance_rows = pendingCardLeadingAdvanceRows(presentation_shell.cursor_col);
    const available_rows = presentation_shell.layout.content_bottom - cursor_row + 1 -| leading_advance_rows;
    const card = try user_message_card.buildUserPromptCardTailForTerminalPresentationInterruptible(
        app.alloc,
        pending.draft.prompt,
        pending.draft.images,
        presentation_shell.layout.cols,
        skill_tokens,
        @max(available_rows, 1),
        checkpoint,
    );
    defer app.alloc.free(card);
    if (card.len == 0) return null;
    const bytes = try pendingCardTerminalWireBytes(app.alloc, card);
    const rendered_line_count: u16 = @intCast(@min(
        std.mem.count(u8, card, "\n"),
        @as(usize, std.math.maxInt(u16)),
    ));
    const paint_row_count = rendered_line_count;
    const row_count = rendered_line_count +| leading_advance_rows;
    if (row_count == 0) {
        app.alloc.free(bytes);
        return error.EmptyPendingPromptCard;
    }
    return .{
        .bytes = bytes,
        .row_count = row_count,
        .paint_row_count = paint_row_count,
        .leading_advance_rows = leading_advance_rows,
    };
}

fn pendingPromptActivityVisible(app: anytype) bool {
    if (comptime !agents.hasAgentField(@TypeOf(app.*), "submission")) return false;
    const pending = agents.screenAgentOf(app).submission.pending orelse return false;
    return pending.phase != .awaiting_auth;
}

fn buildPendingSteeringCardProjection(
    alloc: std.mem.Allocator,
    shell: *const transcript_runtime.TranscriptRuntime,
    steering: SteeringProjection,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !?PendingCardProjection {
    const queued_count = if (steering.waits_for_boundary) 0 else steering.messages.len;
    var index = steering.pending_feedback.len + queued_count;
    if (index == 0) return null;

    var card_bytes: std.ArrayList(u8) = .empty;
    defer card_bytes.deinit(alloc);
    var row_count: u16 = 0;
    const row_limit = @max(shell.layout.content_bottom, 1);
    while (index > 0 and row_count < row_limit) {
        index -= 1;
        const message = if (index < steering.pending_feedback.len)
            steering.pending_feedback[index]
        else
            steering.messages[index - steering.pending_feedback.len];
        const gap: u16 = @intFromBool(card_bytes.items.len > 0);
        const remaining_rows = row_limit - row_count -| gap;
        if (remaining_rows == 0) break;
        const card = try user_message_card.buildUserPromptCardTailForTerminalPresentationInterruptible(
            alloc,
            message,
            &.{},
            shell.layout.cols,
            &.{},
            remaining_rows,
            checkpoint,
        );
        defer alloc.free(card);
        if (card.len == 0) continue;
        if (gap > 0) try card_bytes.insert(alloc, 0, '\n');
        try card_bytes.insertSlice(alloc, 0, card);
        row_count += @as(u16, @intCast(std.mem.count(u8, card, "\n"))) + gap;
    }
    if (row_count == 0) return null;
    const leading_rows = pendingCardLeadingAdvanceRows(shell.cursor_col);
    return .{
        .bytes = try pendingCardTerminalWireBytes(alloc, card_bytes.items),
        .row_count = row_count +| leading_rows,
        .paint_row_count = row_count,
        .leading_advance_rows = leading_rows,
    };
}

fn pendingCardTerminalWireBytes(
    alloc: std.mem.Allocator,
    logical: []const u8,
) ![]u8 {
    var logical_end = logical.len;
    if (logical_end > 0 and logical[logical_end - 1] == '\n') logical_end -= 1;
    if (logical_end > 0 and logical[logical_end - 1] == '\r') logical_end -= 1;
    const source = logical[0..logical_end];
    var missing_carriage_returns: usize = 0;
    for (source, 0..) |byte, index| {
        if (byte == '\n' and (index == 0 or source[index - 1] != '\r')) {
            missing_carriage_returns += 1;
        }
    }
    const wire_len = try std.math.add(
        usize,
        source.len,
        missing_carriage_returns,
    );
    const wire = try alloc.alloc(u8, wire_len);
    var written: usize = 0;
    for (source, 0..) |byte, index| {
        if (byte == '\n' and (index == 0 or source[index - 1] != '\r')) {
            wire[written] = '\r';
            written += 1;
        }
        wire[written] = byte;
        written += 1;
    }
    std.debug.assert(written == wire.len);
    return wire;
}

fn previewWithPendingCard(
    preview: render_engine.frame_layout.TranscriptFlowPreview,
    pending: ?PendingCardProjection,
) render_engine.frame_layout.TranscriptFlowPreview {
    const card = pending orelse return preview;
    var next = preview;
    next.natural_visual_rows +|= card.row_count;
    next.cursor_row +|= card.row_count;
    next.cursor_col = 1;
    next.replaceable_row = next.cursor_row;
    next.tail_kind = .user_turn;
    next.replaceable_active = false;
    next.trailing_boundary_blank_rows = 0;
    next.footer_boundary_gap_rows = 0;
    return next;
}

// Every steering slice in the result is owned for one render frame.
fn buildSteeringProjection(comptime App: type, app: *App) !SteeringProjection {
    var projection: SteeringProjection = .{};
    errdefer projection.deinit(app.alloc);
    if (comptime @hasDecl(@TypeOf(agents.screenAgentOf(app).worker), "snapshotSteeringPresentation")) {
        var snapshot = try agents.screenAgentOf(app).worker.snapshotSteeringPresentation(app.alloc);
        defer snapshot.deinit(app.alloc);
        projection.waits_for_boundary = snapshot.waits_for_boundary;
        projection.messages = snapshot.messages;
        snapshot.messages = &.{};
        projection.pending_feedback = snapshot.pending_feedback;
        snapshot.pending_feedback = &.{};
    }
    return projection;
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        fn appendDeferredHistoryForVisualEpoch(
            ctx: *anyopaque,
            finished: *const types.FinishedPrompt,
        ) anyerror!assistant_pacer.DeferredFinishCommit {
            const app: *App = @ptrCast(@alignCast(ctx));
            return switch (try app_session_runtime.Runtime(App).appendFinishedPromptForVisualEpoch(
                app,
                agents.screenAgentOf(app),
                finished.*,
            )) {
                .uncommitted => .uncommitted,
                .committed => .committed,
            };
        }

        pub fn resetVisualEpoch(
            app: *App,
            trigger: VisualEpochResetTrigger,
        ) !bool {
            const welcome = try ui_render.welcomeMessage(app.alloc);
            defer app.alloc.free(welcome);

            const committed = try app.pacer.discardDeferredPresentationForVisualEpoch(
                app.alloc,
                .{
                    .ctx = app,
                    .append_history = appendDeferredHistoryForVisualEpoch,
                },
            );
            if (!committed) {
                switch (trigger) {
                    .native_clear_probe => debug_trace.logf(
                        "native_clear",
                        "native_clear_recovery_skipped reason=history_uncommitted",
                        .{},
                    ),
                    .ctrl_l => debug_trace.logf(
                        "render",
                        "visual_epoch_reset_skipped trigger=ctrl_l reason=history_uncommitted",
                        .{},
                    ),
                }
                return false;
            }

            try app.shell.resetVisualEpoch(app.alloc, welcome);
            try app.shell.requestTerminalReset(&app.metrics);
            switch (trigger) {
                .native_clear_probe => debug_trace.logf(
                    "native_clear",
                    "native_clear_recovery_requested",
                    .{},
                ),
                .ctrl_l => debug_trace.logf(
                    "render",
                    "visual_epoch_reset_requested trigger=ctrl_l",
                    .{},
                ),
            }
            return true;
        }

        pub fn applyThemeUpdate(app: *App, light: bool, rgb: ?ui_render.TerminalRgb) !void {
            if (!ui_render.themeNeedsUpdate(light, rgb)) return;

            // Resolve the target first so the retint rewrites the old theme's
            // escapes into the new theme's, custom pairs included.
            const prior_theme = shared_theme.current();
            var resolved_target: ?shared_theme.Theme = null;
            if (shared_theme.sourceName() orelse ui_render.explicitThemeName()) |name| {
                // Custom themes re-resolve on live flips: sibling swap or
                // builtin fallback, same rule as startup.
                resolved_target = shared_theme.resolveNamed(app.alloc, name, light, .{ .truecolor = ui_render.truecolorIsEnabled() }) catch |err| blk: {
                    debug_trace.logf("theme", "live_theme_resolve_failed name={s} err={s}", .{ name, @errorName(err) });
                    break :blk null;
                };
            }
            const target = resolved_target orelse shared_theme.builtin(light);

            app.shell.retintEntriesForTheme(app.alloc, prior_theme, target) catch |err| {
                debug_trace.logf("theme", "theme_transcript_retint_failed err={s}", .{@errorName(err)});
                return;
            };
            app.pacer.retintForTheme(app.alloc, prior_theme, target) catch |err| {
                debug_trace.logf("theme", "theme_pending_retint_failed err={s} kept=old_colors", .{@errorName(err)});
            };
            // Each hidden agent keeps its own transcript and paced text.
            if (comptime @hasField(App, "child_agents") and @hasField(App, "main_screen")) {
                @import("app_agents_runtime.zig").Runtime(App).retintHiddenScreens(app, prior_theme, target);
            }
            if (resolved_target) |resolved| {
                ui_render.applyTheme(resolved, rgb);
            } else {
                ui_render.initTheme(light, rgb);
            }
            app.shell.setCommandOutputRenderPolicy(shellStyles());
            debug_trace.logf("theme", "event=theme_change_redraw dropped=terminal_screen_and_scrollback reason=transcript_redrawn_in_new_theme", .{});
            try app.shell.requestTerminalReset(&app.metrics);
            app.shell.render_requests.request(.transcript);
        }

        pub fn shellStyles() transcript_runtime.Styles {
            return .{
                .system_notice_label_style = ui_render.system_notice_label_style,
                .system_notice_text_style = ui_render.system_notice_text_style,
                .reset_style = ui_render.reset_style,
                .dim_style = ui_render.dim_style,
                .red_style = ui_render.red_style,
                .notice_information_style = ui_render.system_notice_label_style,
                .notice_success_style = ui_render.green_style,
                .notice_warning_style = ui_render.warning_style,
                .notice_error_style = ui_render.red_style,
                .notice_cancelled_style = ui_render.dim_style,
                .code_highlight_theme = if (ui_render.is_light) .light else .dark,
                .expand_thinking = ui_render.expand_thinking,
            };
        }

        var model_completions_buf: [32][]const u8 = undefined;
        var effort_picker_values_buf: [types.ReasoningEffort.max_options + 1]types.ReasoningEffort = undefined;
        var effort_picker_labels_buf: [types.ReasoningEffort.max_options + 1][]const u8 = undefined;
        var fast_picker_labels_buf: [3][]const u8 = undefined;
        noinline fn footerContext(
            app: *App,
            agent: *AppAgent,
            upgrade_status_buf: *[64]u8,
            waiting_note_buf: *[128]u8,
            shimmer_pos: i16,
            steering: *const SteeringProjection,
        ) render_input.RenderContext {
            const model_query = app.input_runtime.picker.activeModelPickerQuery(&app.input_runtime.edit_state);
            // `/effort ` lists the current model's levels, whatever a `/model`
            // flow left pending.
            const effort_command = if (model_query) |query| query.command == .effort else false;
            const pending_model = if (!effort_command and app.input_runtime.picker.hasPendingModelPickerSelection()) app.input_runtime.picker.model_picker_pending_model.items else null;
            // The level the `/effort ` column highlights, which the status line
            // shows until the column applies or closes.
            var effort_command_preview: ?types.ReasoningEffort = null;
            // A model with no levels, or none loaded yet, shows no `/effort `
            // column, as `/model` skips its effort column; Enter runs the
            // command, which says why.
            var effort_command_without_levels = false;
            var model_picker_stage: picker_state.ModelPickerStage = .model;
            var picker_items: []const []const u8 = &.{};
            var picker_index: usize = 0;
            var picker_window_start: usize = 0;
            var picker_anchor: usize = 0;

            if (model_query) |picker_query| {
                model_picker_stage = picker_query.stage;
                picker_anchor = picker_query.token_start;
                switch (picker_query.stage) {
                    .model => {
                        const count = input_completion_runtime.CompletionRuntime(App).modelPickerCompletions(app, picker_query.query, &model_completions_buf);
                        picker_items = model_completions_buf[0..count];
                        picker_index = input_completion_runtime.CompletionRuntime(App).modelPickerIndex(app, picker_items);
                        picker_window_start = input_completion_runtime.CompletionRuntime(App).modelPickerWindowStart(app, count, picker_index);
                    },
                    .effort => {
                        const target = pending_model orelse provider_runtime.modelOf(app, agent);
                        const capabilities = model_capabilities.resolveForApp(App, app, target);
                        const effort_count = model_capabilities.reasoningEffortOptionCount(capabilities);
                        effort_command_without_levels = effort_command and effort_count == 0;
                        for (0..effort_count) |i| {
                            effort_picker_values_buf[i] = model_capabilities.reasoningEffortAtIndex(capabilities, i);
                            effort_picker_labels_buf[i] = effort_picker_values_buf[i].displayLabel();
                        }
                        const count = picker_state.filterCompletionLabels(picker_query.query, effort_picker_labels_buf[0..effort_count], effort_picker_labels_buf[0..]);
                        picker_items = effort_picker_labels_buf[0..count];
                        picker_index = app.input_runtime.picker.model_picker_effort_index;
                        picker_window_start = app.input_runtime.picker.model_picker_effort_window_start;
                        if (effort_command and count > 0) {
                            effort_command_preview = types.ReasoningEffort.parseDisplayLabel(picker_items[picker_index % count]);
                        }
                    },
                    .fast => {
                        const count = input_completion_runtime.CompletionRuntime(App).speedPickerLabels(
                            app,
                            picker_query.query,
                            &fast_picker_labels_buf,
                        );
                        picker_items = fast_picker_labels_buf[0..count];
                        picker_index = input_completion_runtime.CompletionRuntime(App).speedPickerIndex(
                            app,
                            picker_items,
                        );
                        picker_window_start = app.input_runtime.picker.model_picker_fast_window_start;
                    },
                }
            }

            const completion_rt = input_completion_runtime.CompletionRuntime(App);
            const file_query = if (model_query == null and completion_rt.hasFileQuery(app))
                app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state)
            else
                null;
            const file_view = completion_rt.filePickerView(app);
            const file_anchor = if (file_query) |fq| fq.at_offset else 0;
            const file_selection = if (file_view.receipt) |receipt| receipt.selected else null;
            const file_status: ?[]const u8 = switch (file_view.status) {
                .unavailable => if (app.input_runtime.picker.file_completion.indexed)
                    "Files unavailable. tab to retry; esc to dismiss."
                else
                    "Directory unavailable. tab to retry; esc to dismiss.",
                .stale => "Selection unavailable. navigate to choose; tab to retry.",
                .loading, .ready, .empty => null,
            };
            const inline_completion =
                input_completion_runtime.CompletionRuntime(App).visibleInlineCompletion(app, agent);

            const visible_model = pending_model orelse provider_runtime.modelOf(app, agent);
            const visible_capabilities = model_capabilities.resolveForApp(App, app, visible_model);
            const active_capabilities_pending = pending_model == null and app.isModelCacheLoading();
            const model_supports_fast = visible_capabilities.supports_fast_mode;
            const model_supports_effort = visible_capabilities.reasoning_efforts.len > 0 or
                (active_capabilities_pending and !agent.effort.isDefault());
            const visible_effort = if (effort_command_preview) |effort|
                effort
            else if (pending_model != null and model_supports_effort)
                pendingPickerEffort(app, visible_model, model_query, app.input_runtime.picker.model_picker_effort_index)
            else if (active_capabilities_pending or model_capabilities.reasoningEffortSupported(visible_capabilities, agent.effort))
                agent.effort
            else
                .auto;
            const active_fast_mode_model_bound = if (comptime @hasDecl(App, "fastModeModelBound"))
                app.fastModeModelBound(agent)
            else
                true;
            const fast_indicator_active = if (pending_model != null)
                visible_capabilities.intrinsic_fast or
                    (model_supports_fast and pendingPickerFastMode(model_query, app.input_runtime.picker.model_picker_fast_index))
            else
                visible_capabilities.intrinsic_fast or
                    (app.fast_mode and active_fast_mode_model_bound);

            const upgrade_label = app.upgrader.statusLabel(upgrade_status_buf);
            const settings_snapshot = app_commands.settingsCatalogSnapshot(app);
            const now_ms = io_mod.milliTimestamp();
            var visible_stream = agent.stream;
            if (visible_stream.active) {
                const cancel_requested = if (comptime agents.hasAgentField(App, "worker"))
                    if (comptime @hasDecl(@TypeOf(agent.worker), "isCancelRequested"))
                        agent.worker.isCancelRequested()
                    else
                        false
                else
                    false;
                if (cancel_requested) {
                    const stops_turn = if (comptime @hasDecl(
                        @TypeOf(agent.worker),
                        "cancellationStopsTurn",
                    ))
                        agent.worker.cancellationStopsTurn()
                    else
                        true;
                    if (stops_turn) visible_stream.active = false;
                }
            }
            if (!visible_stream.active) {
                if (app.pacer.completedAssistantPresentationTokenProgress()) |progress| {
                    visible_stream.token_progress = progress;
                }
            }

            var statusline = buildStatuslineItems(app, agent, visible_model);
            statusline.ultrafast_indicator_active = if (pending_model != null)
                visible_capabilities.supports_ultrafast_mode and std.mem.eql(u8, pendingPickerSpeed(model_query, app.input_runtime.picker.model_picker_fast_index), "ultrafast")
            else if (comptime @hasField(@TypeOf(agent.worker), "agent_turn_settings"))
                agent.worker.agent_turn_settings.ultrafast_mode
            else
                false;

            const waiting_note: []const u8 = if (comptime @hasDecl(App, "hiddenAgentWaitingNote"))
                app.hiddenAgentWaitingNote(waiting_note_buf)
            else
                "";
            const subagent_wait = if (comptime @hasDecl(App, "subagentWaitStatus"))
                app.subagentWaitStatus()
            else
                @import("app_agents_runtime.zig").SubagentWait{};
            // Shares the buffer: the footer shows it only without a waiting note.
            const working_note: []const u8 = if (comptime @hasDecl(App, "hiddenAgentWorkingNote"))
                (if (waiting_note.len == 0) app.hiddenAgentWorkingNote(waiting_note_buf) else "")
            else
                "";
            return .{
                .slash_registry = app.slashRegistry(),
                .stream = visible_stream,
                .compaction = if (comptime @hasDecl(@TypeOf(agent.worker), "compactionActivitySnapshot")) agent.worker.compactionActivitySnapshot() else .{},
                .pending_prompt_activity = pendingPromptActivityVisible(app),
                .completed_assistant_presentation_tail = app.pacer.hasCompletedAssistantPresentationTail(),
                .writing_response = app.pacer.hasPending(),
                // A launch credential still loading must not flash "run /provider".
                .has_api_key = app.auth.credentialSource() != null or
                    (if (comptime @hasDecl(@TypeOf(app.auth), "startupCredentialPending")) app.auth.startupCredentialPending() else false),
                .model = visible_model,
                .pending_images = agent.pending_images.items,
                // The agent on screen's own mode.
                .permission_mode = .yolo,
                .steering_messages = steering.messages,
                .steering_waits_for_boundary = steering.waits_for_boundary,
                .fast_indicator_active = fast_indicator_active,
                .effort = visible_effort,
                .model_supports_effort = model_supports_effort,
                .ctrl_c_pending = app.input_runtime.gestures.ctrlCExitArmed(),
                .shimmer_pos = shimmer_pos,
                .now_ms = now_ms,
                .model_query_active = model_query != null and !effort_command_without_levels,
                .model_picker_stage = model_picker_stage,
                .model_completions_loading = if (model_query != null and model_picker_stage == .model) app.isModelCacheLoading() else false,
                .model_completions_failed = if (model_query != null and model_picker_stage == .model) app.isModelCacheFailed() else false,
                .model_completions = picker_items,
                .model_completion_index = picker_index,
                .model_completion_window_start = picker_window_start,
                .model_completion_anchor = picker_anchor,
                .file_query_active = file_query != null,
                .file_completions = file_view.items,
                .file_completion_index = file_selection orelse 0,
                .file_completion_has_selection = file_selection != null,
                .file_completion_status = file_status,
                .file_completion_window_start = app.input_runtime.picker.file_completion_window_start,
                .file_completion_anchor = file_anchor,
                .file_completions_loading = file_view.status == .loading,
                .file_completions_failed = file_view.status == .unavailable,
                .inline_completion_suffix = if (inline_completion) |completion|
                    completion.suffix()
                else
                    "",
                .skills_menu = if (comptime @hasField(App, "skills"))
                    render_input.skillsMenuProjection(&app.skills)
                else
                    .{},
                .mcp_host_menu = if (comptime @hasField(App, "mcp")) .{
                    .state = app.mcp.host_menu,
                    .rows = app.mcp.host_menu_rows,
                    .filter = app.input_runtime.edit_state.input.items,
                    .tools = app.mcp.host_menu_tools,
                    .notes = app.mcp.host_menu_notes,
                    .sign_in_url = app.mcp.hostMenuSignInUrl(),
                    .add_name = app.mcp.add_form.name,
                    .add_target = app.mcp.add_form.target,
                    .add_pairs = app.mcp.add_form.pairs.items,
                    .add_problem = app.mcp.add_form.problem,
                    .add_input = app.mcp.add_form.input.items(),
                    .add_cursor = app.mcp.add_form.input.cursor,
                } else .{},
                .help_menu = render_input.helpMenuProjection(
                    &app.input_runtime.help_menu,
                    app.slashRegistry(),
                    app.input_runtime.edit_state.input.items,
                ),
                .settings_menu = blk: {
                    var projection = render_input.settingsMenuProjection(
                        &app.input_runtime.settings_menu,
                        settings_snapshot,
                        app.input_runtime.edit_state.input.items,
                    );
                    if (comptime @hasField(App, "model_cache")) {
                        projection.models = render_input.modelMenuProjection(&app.model_cache);
                    }
                    break :blk projection;
                },
                .model_menu = if (comptime @hasField(App, "model_cache"))
                    render_input.modelMenuProjection(&app.model_cache)
                else
                    .{},
                .session_menu = if (comptime agents.hasAgentField(App, "session_persistence")) .{
                    .active = agent.session_persistence.session_picker.active,
                    .load_state = agent.session_persistence.session_picker.load_state,
                    .summaries = agent.session_persistence.session_picker.summaries.items,
                    .has_more = agent.session_persistence.session_picker.has_more,
                    .loading_more = agent.session_persistence.session_picker.loading_more,
                    .scope = agent.session_persistence.session_picker.scope,
                    .selected_index = agent.session_persistence.session_picker.selected,
                    .window_start = agent.session_persistence.session_picker.window_start,
                    .query = agent.session_persistence.session_picker.query(),
                    .now_ms = now_ms,
                    .selection_failure = agent.session_persistence.session_picker.selection_failure,
                } else .{},
                .fork_menu = if (comptime agents.hasAgentField(App, "session_persistence"))
                    app_session_runtime.forkMenuProjection(&agent.session_persistence.fork_menu)
                else
                    .{},
                .effort_menu = render_input.effortMenuProjection(&app.input_runtime.effort_menu),
                .provider_menu = if (app.input_runtime.provider_menu.active) &app.input_runtime.provider_menu else null,
                .list_picker = if (app.input_runtime.list_picker.active) &app.input_runtime.list_picker else null,
                .splash = if (comptime @hasField(App, "splash")) (if (app.splash.active) &app.splash else null) else null,
                .live_preview = if (comptime @hasDecl(App, "livePreview")) app.livePreview(agent) else null,
                .live_preview_recent = if (comptime @hasField(App, "live_pacer")) agent.stream.active and app.live_pacer.recentlyShown(io_mod.milliTimestamp()) else false,
                .agents_menu = if (comptime @hasDecl(App, "agentsMenuProjection")) app.agentsMenuProjection() else .{},
                .statusline_menu = render_input.statuslineMenuProjection(
                    &app.input_runtime.statusline_menu,
                    settings_snapshot,
                ),
                .info_panel = render_input.infoPanelProjection(
                    &app.input_runtime.info_panel,
                    app.shell.layout.cols,
                    app.shell.layout.rows,
                ),
                .workspace_menu = if (comptime @hasDecl(App, "workspaceAccess"))
                    render_input.workspaceMenuProjection(
                        &app.input_runtime.workspace_menu,
                        app.workspace_root,
                        app.workspaceAccess(),
                    )
                else
                    .{},
                .upgrade_status = upgrade_label,
                .agent_label = if (comptime @hasDecl(App, "footerAgentLabel")) app.footerAgentLabel() else "",
                .waiting_note = waiting_note,
                .working_note = working_note,
                .subagent_wait = subagent_wait.label,
                .subagent_wait_since_ms = subagent_wait.since_ms,
                .mcp_status = if (comptime @hasField(App, "mcp")) app.mcp.hostStatusText() else "",
                .esc_clear_armed = app.input_runtime.gestures.escapeClearArmed(),
                .esc_interrupt_armed = app.input_runtime.gestures.escapeInterruptArmed(),
                .question = shownQuestion(app, agent),
                .statusline = statusline,
                .activity = activityProjection(app),
                .input = &app.input_runtime,
            };
        }

        fn pendingPickerEffort(app: *App, model: []const u8, query: ?picker_state.ModelPickerQuery, effort_index: usize) types.ReasoningEffort {
            const capabilities = model_capabilities.resolveForApp(App, app, model);
            if (query) |picker_query| {
                if (picker_query.stage == .effort) {
                    const typed = std.mem.trim(u8, picker_query.query, " \t");
                    if (types.ReasoningEffort.parseDisplayLabel(typed)) |effort| {
                        if (model_capabilities.reasoningEffortSupported(capabilities, effort)) return effort;
                    }
                }
            }
            return model_capabilities.reasoningEffortAtIndex(capabilities, effort_index);
        }

        fn buildStatuslineItems(
            app: *App,
            agent: *AppAgent,
            visible_model: []const u8,
        ) ui_render.StatuslineItems {
            var items: ui_render.StatuslineItems = .{};
            if (comptime @hasField(App, "workspace_identity") and
                @hasField(App, "workspace_root"))
            {
                const identity = app.workspace_identity.refresh(
                    app.alloc,
                    app.workspace_root,
                ) catch app.workspace_identity.snapshot();
                items.workspace_label = identity.workspace_label;
                items.git_branch = identity.git_branch;
            }
            if (app.statusline_context) {
                items.context_used = agents.loadTotal(&agent.total_input_tokens) +| agents.loadTotal(&agent.total_output_tokens);
                const advertised = model_capabilities.resolveForApp(App, app, visible_model).context_window;
                const limit = if (comptime @hasField(@TypeOf(agent.worker), "agent_turn_settings")) agent.worker.agent_turn_settings.context_limit else null;
                items.context_total = session_context.window(advertised, limit);
                if (comptime @hasField(AppAgent, "status_usage")) {
                    items.usage = .{
                        .input = agents.loadTotal(&agent.status_usage.input),
                        .output = agents.loadTotal(&agent.status_usage.output),
                        .read = agents.loadTotal(&agent.status_usage.read),
                        .write = agents.loadTotal(&agent.status_usage.write),
                        .cacheable = agents.loadTotal(&agent.status_usage.cacheable),
                    };
                }
            }
            if (comptime @hasField(App, "statusline_session")) {
                if (app.statusline_session) {
                    items.session_title = app_session_runtime.Runtime(App).cachedSessionTitle(agent);
                }
            }
            return items;
        }

        fn pendingPickerSpeed(query: ?picker_state.ModelPickerQuery, speed_index: usize) []const u8 {
            if (query) |picker_query| {
                if (picker_query.stage == .fast) {
                    const typed = std.mem.trim(u8, picker_query.query, " \t");
                    for (picker_state.model_picker_speed_options) |speed| {
                        if (std.ascii.eqlIgnoreCase(typed, speed)) return speed;
                    }
                }
            }
            return picker_state.model_picker_speed_options[speed_index % picker_state.model_picker_speed_options.len];
        }

        fn pendingPickerFastMode(query: ?picker_state.ModelPickerQuery, speed_index: usize) bool {
            return std.mem.eql(u8, pendingPickerSpeed(query, speed_index), "fast");
        }

        pub fn flushRequestedFrame(app: *App, agent: *AppAgent) !void {
            if (comptime @hasDecl(@TypeOf(app.shell), "sessionScrollbackHandoffPending")) {
                if (app.shell.sessionScrollbackHandoffPending()) return;
            }
            if (app.shell.terminal_dimensions_invalid or app.shell.layout.rows == 0 or app.shell.layout.cols == 0) return;
            const has_resize_lifecycle =
                @hasField(@TypeOf(app.shell), "pending_resize_observation");
            if (comptime has_resize_lifecycle) {
                if (shell_runtime.resizeBlocksFrameCommit(&app.shell)) return;
            }
            const render_requests = activeRenderRequests(app);
            var attempt = (try render_requests.beginAttempt()) orelse return;
            const snapshot = attempt.snapshot;
            var reason_buf: [128]u8 = undefined;
            const reason_names = renderReasonNames(snapshot.reasons, &reason_buf);
            debug_trace.logf(
                "frame_schedule",
                "attempt_begin reasons={s} reason_count={d} invalidations={d} resize_blocked={s} animation_phase={d} animation_generation={d} animation_deadline_ms={d}",
                .{
                    reason_names,
                    snapshot.reasons.count(),
                    snapshot.invalidations.len,
                    if (render_requests.blocksFrameCommit()) "true" else "false",
                    render_requests.visibleAnimationPhase(),
                    if (snapshot.animation_candidate) |candidate| candidate.generation else 0,
                    render_requests.animation_next_deadline_ms,
                },
            );
            defer attempt.deinit();

            const resize_commit = if (comptime has_resize_lifecycle)
                shell_runtime.pendingResizeFrameCommit(
                    &app.shell,
                    snapshot.reasons.contains(.resize),
                )
            else
                shell_runtime.ResizeFrameCommit.none;
            const attempted = attemptRequestedFrame(app, agent, snapshot) catch |err| {
                attempt.restore();
                if (comptime @hasField(App, "terminal")) {
                    _ = app_lifecycle.closeFullTranscriptIfActive(
                        app.alloc,
                        &app.terminal,
                        &app.shell,
                        &app.metrics,
                    ) catch {};
                }
                debug_trace.logf(
                    "frame_schedule",
                    "attempt_restore outcome=error err={s} reasons={s} reason_count={d} invalidations={d} pending_reason_count={d} animation_phase={d} animation_deadline_ms={d}",
                    .{
                        @errorName(err),
                        reason_names,
                        snapshot.reasons.count(),
                        snapshot.invalidations.len,
                        render_requests.pendingReasonCount(),
                        render_requests.visibleAnimationPhase(),
                        render_requests.animation_next_deadline_ms,
                    },
                );
                return err;
            };
            const result = attempted orelse {
                attempt.restore();
                render_requests.noteInputPendingAbort();
                debug_trace.logf(
                    "frame_schedule",
                    "attempt_restore outcome=input_pending reasons={s} reason_count={d} invalidations={d} consecutive_aborts={d}",
                    .{
                        reason_names,
                        snapshot.reasons.count(),
                        snapshot.invalidations.len,
                        render_requests.consecutive_input_pending_aborts,
                    },
                );
                return;
            };

            if (!result.is_committed()) {
                input_completion_runtime.CompletionRuntime(App).distrustFilePicker(app);
                render_requests.resetInputPendingAbortStreak();
                attempt.restore();
                debug_trace.logf(
                    "frame_schedule",
                    "attempt_restore outcome={s} reasons={s} reason_count={d} invalidations={d} pending_reason_count={d} animation_phase={d} animation_deadline_ms={d}",
                    .{
                        @tagName(result.shadow_state),
                        reason_names,
                        snapshot.reasons.count(),
                        snapshot.invalidations.len,
                        render_requests.pendingReasonCount(),
                        render_requests.visibleAnimationPhase(),
                        render_requests.animation_next_deadline_ms,
                    },
                );
                return;
            }

            if (result.file_picker_receipt) |receipt| {
                input_completion_runtime.CompletionRuntime(App).acknowledgeFilePicker(app, agent, receipt);
            } else {
                input_completion_runtime.CompletionRuntime(App).distrustFilePicker(app);
            }
            const committed_at_ms = io_mod.milliTimestamp();
            attempt.commit(
                committed_at_ms,
                render_request.animation_interval_ms,
                result.animation_visible,
            );
            if (comptime @hasDecl(App, "startPromptCredentialPrewarm")) {
                if (snapshot.reasons.contains(.first_frame)) {
                    App.startPromptCredentialPrewarm(app);
                }
            }
            // MCP servers start once the first frame is on screen, never before.
            if (comptime @hasDecl(App, "startMcpHostServers")) {
                if (snapshot.reasons.contains(.first_frame)) App.startMcpHostServers(app);
            }
            if (comptime @hasDecl(App, "notePendingFrameCommitted")) {
                if (result.pending_prompt_presented) {
                    App.notePendingFrameCommitted(app, agent);
                }
            }
            if (comptime has_resize_lifecycle) {
                shell_runtime.acknowledgeResizeFrameCommit(&app.shell, resize_commit);
            }
            if (comptime @hasDecl(App, "flushNotifications")) {
                if (snapshot.reasons.contains(.notification)) {
                    app.flushNotifications();
                }
            }
            if (comptime @hasField(@TypeOf(app.shell), "resize_history_row_delta")) {
                if (snapshot.reasons.contains(.resize) and
                    !app.shell.render_requests.hasReason(.resize))
                {
                    app.shell.resize_history_row_delta = null;
                }
            }
            debug_trace.logf(
                "frame_schedule",
                "attempt_end outcome=committed reasons={s} reason_count={d} invalidations={d} pending_reason_count={d} animation_phase={d} animation_deadline_ms={d}",
                .{
                    reason_names,
                    snapshot.reasons.count(),
                    snapshot.invalidations.len,
                    render_requests.pendingReasonCount(),
                    render_requests.visibleAnimationPhase(),
                    render_requests.animation_next_deadline_ms,
                },
            );
        }

        fn attemptRequestedFrame(
            app: *App,
            agent: *AppAgent,
            snapshot: render_request.AttemptSnapshot,
        ) !?FrameAttemptResult {
            const result = (if (comptime @hasDecl(App, "renderFrameAttemptForTest"))
                App.renderFrameAttemptForTest(app, snapshot)
            else
                renderFrameAttempt(app, agent, snapshot)) catch |err| {
                if (err == error.InputPending) return null;
                return err;
            };
            return result;
        }

        fn transcriptInputPending(context: *anyopaque) bool {
            const app: *App = @ptrCast(@alignCast(context));
            if (app.terminal_input_runtime.hasPendingTerminalInput()) return true;
            const state = app.terminal.pollInput(0) catch |err| {
                debug_trace.logf(
                    "frame_schedule",
                    "input_poll_failed err={s}",
                    .{@errorName(err)},
                );
                return true;
            };
            return state.readable or state.closed();
        }

        fn transcriptBuildCheckpoint(app: *App) ?build_checkpoint.BuildCheckpoint {
            if (comptime !@hasField(App, "terminal")) return null;
            if (comptime @hasField(App, "shell")) {
                const render_requests = activeRenderRequests(app);
                if (!render_requests.permitsInputPendingAbort()) {
                    debug_trace.logf(
                        "frame_schedule",
                        "input_cancellation_suppressed consecutive_aborts={d} bound={d}",
                        .{
                            render_requests.consecutive_input_pending_aborts,
                            render_request.max_consecutive_input_pending_aborts,
                        },
                    );
                    return null;
                }
            }
            return .init(app, transcriptInputPending);
        }

        fn reconcileBeforeFrameRender(app: *App, agent: *AppAgent) !RenderReconciliation {
            if (comptime !@hasField(App, "terminal")) return .{ .inline_render = .{} };

            if (try app_lifecycle.recoverFullTranscriptDriftBeforeRender(
                app.alloc,
                &app.terminal,
                &app.shell,
                &app.metrics,
            )) {
                try requestNormalViewportRecovery(app);
            }

            const question_active = shownQuestion(app, agent) != null;
            if (question_active) {
                if (try app_lifecycle.closeFullTranscriptIfActive(
                    app.alloc,
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                )) {
                    try requestNormalViewportRecovery(app);
                }
                if (app.terminal.catalogMenuScreenActive()) {
                    try app_lifecycle.leaveCatalogMenuScreen(&app.terminal, &app.shell, &app.metrics);
                    try requestNormalViewportRecovery(app);
                }
            }

            const terminal_transition = app_lifecycle.approvalInlineRestoreTransition(
                &app.terminal,
            );
            switch (terminal_transition) {
                .none => {},
                .restore_normal_screen => {
                    if (!question_active and
                        (settingsMenuActive(app) or helpMenuActive(app) or
                            skillsMenuActive(app) or modelMenuActive(app) or
                            sessionMenuActive(app, agent) or forkMenuActive(app, agent) or effortMenuActive(app) or agentsMenuActive(app)))
                    {
                        app.shell.render_requests.request(.footer);
                    }
                    return .{ .inline_render = .{
                        .terminal_transition = terminal_transition,
                    } };
                },
            }

            if (!question_active and (settingsMenuActive(app) or helpMenuActive(app) or skillsMenuActive(app) or modelMenuActive(app) or sessionMenuActive(app, agent) or forkMenuActive(app, agent) or effortMenuActive(app) or agentsMenuActive(app))) {
                if (try app_lifecycle.closeFullTranscriptIfActive(
                    app.alloc,
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                )) {
                    try requestNormalViewportRecovery(app);
                }
            }

            if (app.terminal.catalogMenuScreenActive()) {
                try app_lifecycle.leaveCatalogMenuScreen(&app.terminal, &app.shell, &app.metrics);
                try requestNormalViewportRecovery(app);
            }

            return .{ .inline_render = .{
                .alternate_screen_owns_rendering = app.terminal.alternate_screen_owner != .none,
            } };
        }

        fn renderFrameAttempt(app: *App, agent: *AppAgent, snapshot: render_request.AttemptSnapshot) !FrameAttemptResult {
            var checkpoint_storage = transcriptBuildCheckpoint(app);
            const checkpoint = if (checkpoint_storage) |*value| value else null;
            // Frame-fresh producer fact for the finality floor: the trailing
            // assistant entry stays non-final while the stream is open or
            // the pacer still holds undelivered output.
            set_transcript_assistant_tail_writable(
                &app.shell,
                agent.stream.active or app.pacer.hasPending(),
            );
            // A terminal reset clears the screen and replays the transcript,
            // so the entries the transcript window kept only because a row of
            // theirs was on screen go before the replay, unless the replay is
            // a resumed transcript's first paint (`transcriptWindowScreenCleared`).
            if (comptime @hasDecl(@TypeOf(app.shell), "transcriptWindowScreenCleared")) {
                if (app.shell.terminal_reset_pending) try app.shell.transcriptWindowScreenCleared(app.alloc);
            }
            const presentation_shell: *transcript_runtime.TranscriptRuntime = &app.shell;
            const render_requests = activeRenderRequests(app);
            var upgrade_status_buf: [64]u8 = undefined;
            var waiting_note_buf: [128]u8 = undefined;
            var steering = try buildSteeringProjection(App, app);
            defer steering.deinit(app.alloc);
            const shimmer_pos = if (snapshot.animation_candidate) |candidate|
                candidate.phase
            else
                render_requests.visibleAnimationPhase();
            const main_footer_ctx = footerContext(
                app,
                agent,
                &upgrade_status_buf,
                &waiting_note_buf,
                shimmer_pos,
                &steering,
            );
            const file_picker_receipt = input_completion_runtime.CompletionRuntime(App).filePickerView(app).receipt;
            var footer_ctx = main_footer_ctx;
            const render_reconciliation = switch (try reconcileBeforeFrameRender(app, agent)) {
                .inline_render => |inline_render| inline_render,
                .frame_result => |result| return result,
            };
            const presentation_commits_transcript = !render_reconciliation.alternate_screen_owns_rendering;
            const active_committed_layout = if (render_reconciliation.alternate_screen_owns_rendering)
                app.terminal.alternate_frame_layout
            else
                app.shell.committed_frame_layout;
            var pending_card = if (!render_reconciliation.alternate_screen_owns_rendering)
                try buildPendingCardProjection(App, app, presentation_shell, checkpoint)
            else
                null;
            const pending_submission_card = pending_card != null;
            if (pending_card == null and !render_reconciliation.alternate_screen_owns_rendering) {
                pending_card = try buildPendingSteeringCardProjection(app.alloc, presentation_shell, steering, checkpoint);
            }
            defer if (pending_card) |*card| card.deinit(app.alloc);

            var attempt_invalidations = snapshot.invalidations;
            presentation_shell.normalizeFrameInvalidations(&attempt_invalidations);
            var frame_redraw = snapshot.reasons.count() > 0 or !attempt_invalidations.isEmpty();

            const body_rows: usize = if (presentation_shell.fullTranscriptActive())
                presentation_shell.fullTranscriptPageBottom()
            else
                presentation_shell.layout.content_bottom;

            var prepared_transcript: ?transcript_painter.PreparedTranscriptSurfacePaint = null;
            defer if (prepared_transcript) |*prepared| prepared.deinit(app.alloc);
            var owned_transcript_source: ?transcript_runtime.TranscriptPreparationSource = null;
            defer if (owned_transcript_source) |*source| source.deinit(app.alloc);
            var transcript_source: ?*transcript_runtime.TranscriptPreparationSource = null;
            var full_transcript_projection: ?*full_transcript_screen.Projection = null;
            var full_transcript_capability: ?*session_child_store.SessionChildCapability = if (comptime @hasDecl(
                App,
                "fullTranscriptSidecarCapability",
            ))
                app.fullTranscriptSidecarCapability(agent)
            else
                null;
            var transcript_transition: ?transcript_runtime.TranscriptTransition = null;
            defer if (transcript_transition) |*transition| transition.deinit(app.alloc);
            var footer_measurement: ?surface_frame.SurfaceFooterMeasurement = null;
            defer if (footer_measurement) |*measurement| measurement.deinit(app.alloc);
            const extra_input_rows_before_footer_prepare = presentation_shell.extra_input_rows;
            const footer_reserved_base_rows_before_footer_prepare = presentation_shell.footer_reserved_base_rows;
            var restore_footer_prepare_state = true;
            defer {
                if (restore_footer_prepare_state) {
                    presentation_shell.extra_input_rows = extra_input_rows_before_footer_prepare;
                    presentation_shell.footer_reserved_base_rows = footer_reserved_base_rows_before_footer_prepare;
                }
            }
            {
                footer_ctx.transcript_depth = presentation_shell.transcriptPresentationDepth();
                if (presentation_shell.fullTranscriptActive()) {
                    const full_diff_resolver: ?full_transcript_screen.FullDiffResolver =
                        if (comptime @hasDecl(App, "fullTranscriptDiffResolver"))
                            app.fullTranscriptDiffResolver()
                        else
                            null;
                    full_transcript_projection = try presentation_shell.preparedFullTranscriptPageProjectionInterruptible(
                        full_diff_resolver,
                        full_transcript_capability,
                        checkpoint,
                    );
                    if (presentation_shell.preparedFullTranscriptPageCapability()) |capability| {
                        full_transcript_capability = capability;
                    }
                }
                footer_measurement = try surface_frame.measureSurfaceFooter(
                    app.alloc,
                    presentation_shell,
                    footer_ctx,
                );
                const omitted_entry_id: ?u32 = if (!presentation_shell.fullTranscriptActive() and footer_measurement != null) switch (footer_measurement.?.activity_projection) {
                    .tool_slot => |slot| if (slot.active) slot.entry_id else null,
                    .none, .turn_thinking => null,
                } else null;
                if (!presentation_shell.fullTranscriptActive()) {
                    if (try presentation_shell.pendingResumeSourceInterruptible(
                        app.alloc,
                        checkpoint,
                    )) |source| {
                        transcript_source = source;
                    } else if (omitted_entry_id) |entry_id| {
                        owned_transcript_source = try presentation_shell.prepareTranscriptSourceForFrameInterruptible(
                            app.alloc,
                            entry_id,
                            null,
                            checkpoint,
                        );
                    } else {
                        owned_transcript_source = try presentation_shell.cachedTranscriptSourceInterruptible(
                            app.alloc,
                            checkpoint,
                        );
                    }
                    if (transcript_source == null) {
                        transcript_source = &owned_transcript_source.?;
                    }
                }
            }
            const footer_reservation_changed = if (footer_measurement) |*measurement|
                measurement.changesFooterReservation(presentation_shell)
            else
                false;
            const replay_displaced_footer_history = if (footer_measurement) |*measurement|
                measurement.replaysDisplacedTranscriptHistory(presentation_shell)
            else
                false;

            var footer_frame: surface_frame.SurfaceFooterFrame = undefined;
            var footer_frame_initialized = false;
            defer if (footer_frame_initialized) footer_frame.deinit(app.alloc);
            var solved_layout: ?render_engine.frame_layout.FrameLayout = null;
            var resolved_transcript_target: ?transcript_runtime.TranscriptRuntime.ResolvedTranscriptTarget = null;
            var scroll_plan = render_engine.frame_scroll_plan.FrameScrollPlan.none(
                presentation_shell.layout.rows,
                presentation_shell.owned_top_row,
            );
            var planned_scroll_next_start_line: usize = 0;
            {
                const canonical_transcript_preview = if (transcript_source) |source|
                    source.preview
                else
                    render_engine.frame_layout.TranscriptFlowPreview{
                        .natural_visual_rows = @intCast(@min(body_rows, @as(usize, std.math.maxInt(u16)))),
                        .cursor_row = presentation_shell.cursor_row,
                        .cursor_col = presentation_shell.cursor_col,
                        .replaceable_row = presentation_shell.replaceable_row,
                    };
                const transcript_preview = previewWithPendingCard(
                    canonical_transcript_preview,
                    pending_card,
                );
                const neutral_footer = if (footer_measurement) |*measurement|
                    measurement.frameLayoutMeasurement()
                else
                    footerMeasurementFromRows(footer_frame.paint.footer);
                var frame_activity = if (footer_measurement) |*measurement|
                    frameActivityStateFromMeasurement(presentation_shell, measurement)
                else
                    activityStateFromPlacement(footer_frame.paint.activity);
                if (pending_card != null and frame_activity == .thinking) {
                    // The pending tail already includes the transcript cursor's blank row.
                    frame_activity.thinking.gap_above_activity = render_engine.transcript_blocks.blockGapRowsBetween(
                        .user_turn,
                        .assistant_turn,
                    ) -| 1;
                }
                const target_activity_projection: activity_runtime.ActivityProjection = if (footer_measurement) |*measurement|
                    measurement.activity_projection
                else
                    .{ .turn_thinking = .{ .label = footer_frame.label() } };
                const prompt_turn_reservation = promptTurnReservation(
                    app,
                    presentation_shell,
                    canonical_transcript_preview,
                    pending_card,
                    if (footer_measurement) |*measurement| measurement else null,
                    frame_activity,
                );
                var fixed_point_ctx = FixedPointTranscriptContext(App){
                    .app = app,
                    .presentation_shell = presentation_shell,
                    .prepare_transcript = !presentation_shell.fullTranscriptActive(),
                    .source = transcript_source,
                    .prepared_transcript = &prepared_transcript,
                    .resolved_target = &resolved_transcript_target,
                    .footer_reservation_changed = footer_reservation_changed,
                    .replay_displaced_footer_history = replay_displaced_footer_history,
                    .footer_measurement = if (footer_measurement) |*measurement| measurement else null,
                    .fallback_footer_rows = if (footer_measurement == null)
                        footer_frame.paint.footer
                    else
                        null,
                    .activity_projection = target_activity_projection,
                    .frame_activity = frame_activity,
                    .base_invalidation = if (footer_measurement != null)
                        render_engine.paint_plan.FrameInvalidationSet.empty()
                    else
                        footer_frame.paint.invalidation,
                    .attempt_invalidations = attempt_invalidations,
                    .pending_tail_rows = if (pending_card) |card| card.row_count else 0,
                };
                const fixed_point = try render_engine.frame_fixed_point.solve(
                    FixedPointTranscriptContext(App),
                    &fixed_point_ctx,
                    .{
                        .terminal = presentation_shell.layout,
                        .owned_top = presentation_shell.owned_top_row,
                        .footer = neutral_footer,
                        .transcript = transcript_preview,
                        .activity = frame_activity,
                        .prompt_turn = prompt_turn_reservation,
                        .body_mode = .transcript,
                        .prior = active_committed_layout,
                    },
                    FixedPointTranscriptContext(App).prepareCandidate,
                    FixedPointTranscriptContext(App).resolveCandidate,
                );
                const solved = fixed_point.layout;
                solved_layout = solved;
                scroll_plan = fixed_point.scroll_plan;
                debug_trace.logf(
                    "frame_layout",
                    "layout_id={x} solved_frame_height={d} footer_height={d} footer_top={d} owned_top={d} owned_bottom={d} prompt_turn_transcript_rows={d} prompt_turn_active={s} scroll_rows={d}",
                    .{
                        solved.layout_id,
                        solved.solved_frame_height,
                        solved.footer_area.height(),
                        solved.footer_area.top,
                        solved.owned_top,
                        solved.owned_band.bottom,
                        prompt_turn_reservation.transcript_rows,
                        if (prompt_turn_reservation.active()) "true" else "false",
                        scroll_plan.terminal_scroll_rows,
                    },
                );
                const solved_footer_rows = if (footer_measurement) |*measurement|
                    measurement.frameLayoutRows(presentation_shell.layout.rows, solved.footer_area.top)
                else
                    footer_frame.paint.footer;
                const solved_viewport = if (resolved_transcript_target) |target|
                    target.selection()
                else if (prepared_transcript) |*prepared|
                    prepared.selection
                else if (footer_measurement != null)
                    surface_frame.currentSurfaceFooterTranscriptState(presentation_shell).selection
                else
                    footer_frame.paint.viewport;
                const solved_projection = if (footer_measurement) |*measurement|
                    measurement.activity_projection
                else
                    .none;
                const solved_activity = if (footer_measurement != null)
                    render_engine.activity_placement.resolve(
                        solved_projection,
                        frame_activity,
                        solved,
                    )
                else
                    render_engine.activity_placement.resolve(
                        .{ .turn_thinking = .{ .label = footer_frame.label() } },
                        frame_activity,
                        solved,
                    );
                const solved_cursor_visible = if (footer_measurement) |*measurement|
                    measurement.input_visible
                else switch (solved_activity) {
                    .transient_row => false,
                    .none, .overlay_entry => true,
                };
                const solved_cursor_target = if (resolved_transcript_target) |target|
                    render_engine.paint_plan.FrameCursorTarget{
                        .row = target.cursorRow(),
                        .col = target.cursorCol(),
                        .visible = solved_cursor_visible,
                    }
                else if (prepared_transcript) |*prepared|
                    render_engine.paint_plan.FrameCursorTarget{
                        .row = prepared.cursor.cursor_row,
                        .col = prepared.cursor.cursor_col,
                        .visible = solved_cursor_visible,
                    }
                else if (footer_measurement != null)
                    render_engine.paint_plan.FrameCursorTarget{
                        .row = solved_footer_rows.input_base,
                        .col = 1,
                        .visible = solved_cursor_visible,
                    }
                else
                    footer_frame.paint.cursor_target;
                const solved_plan = solved.toPaintPlan(.{
                    .footer_rows = solved_footer_rows,
                    .viewport = solved_viewport,
                    .activity = solved_activity,
                    .invalidation = if (footer_measurement != null)
                        render_engine.paint_plan.FrameInvalidationSet.empty()
                    else
                        footer_frame.paint.invalidation,
                    .synchronized_update = app.shell.sync_updates_enabled,
                    .cursor_target = solved_cursor_target,
                    .preserve_scrollback = if (footer_measurement != null)
                        !presentation_shell.pending_scroll_compact
                    else
                        footer_frame.paint.preserve_scrollback,
                    .reset_terminal = shouldResetPhysicalTerminal(
                        render_reconciliation.alternate_screen_owns_rendering,
                        app.shell.terminal_reset_pending,
                    ),
                });
                if (footer_measurement) |*measurement| {
                    footer_frame = try surface_frame.prepareMeasuredSurfaceFooterFrameForPlan(
                        app.alloc,
                        presentation_shell,
                        &frame_redraw,
                        footer_ctx,
                        measurement,
                        solved_plan,
                        attempt_invalidations,
                    );
                    footer_frame_initialized = true;
                } else {
                    surface_frame.retargetSurfaceFooterFrame(&footer_frame, solved_plan);
                }
                if (!framePlanBandsEqual(footer_frame.paint, solved_plan)) {
                    debug_trace.logf(
                        "frame_layout",
                        "migration_mismatch old_transcript={d}..{d} old_activity={d}..{d} old_footer={d}..{d} solved_transcript={d}..{d} solved_activity={d}..{d} solved_footer={d}..{d}",
                        .{
                            footer_frame.paint.transcript_band.top,
                            footer_frame.paint.transcript_band.bottom,
                            footer_frame.paint.activity_band.top,
                            footer_frame.paint.activity_band.bottom,
                            footer_frame.paint.footer_band.top,
                            footer_frame.paint.footer_band.bottom,
                            solved_plan.transcript_band.top,
                            solved_plan.transcript_band.bottom,
                            solved_plan.activity_band.top,
                            solved_plan.activity_band.bottom,
                            solved_plan.footer_band.top,
                            solved_plan.footer_band.bottom,
                        },
                    );
                }
                try footer_frame.paint.validate();
                if (prepared_transcript) |*prepared| {
                    try validatePreparedTranscriptFitsPlan(prepared, footer_frame.paint);
                    planned_scroll_next_start_line = if (resolved_transcript_target) |target|
                        target.selection().start_line
                    else
                        prepared.selection.start_line;
                }
                if (full_transcript_projection) |projection| {
                    const area = footer_frame.paint.transcript_band;
                    if (!area.isEmpty()) {
                        const staged = try presentation_shell.prepareFullTranscriptSurfacePaintInterruptible(
                            app.alloc,
                            &app.metrics,
                            projection,
                            full_transcript_capability,
                            .{ .top = area.top, .bottom = area.bottom },
                            checkpoint,
                        );
                        if (staged.owned_source) |source| {
                            owned_transcript_source = source;
                            transcript_source = &owned_transcript_source.?;
                        } else {
                            transcript_source = staged.borrowed_source.?;
                        }
                        prepared_transcript = staged.prepared;
                        footer_frame.paint.viewport = prepared_transcript.?.selection;
                        try validatePreparedTranscriptFitsPlan(&prepared_transcript.?, footer_frame.paint);
                    }
                }
            }
            if (presentation_commits_transcript) {
                if (transcript_source) |source| {
                    if (prepared_transcript) |*prepared| {
                        if (presentation_shell.fullTranscriptActive()) {
                            return error.InvalidFullTranscriptRoute;
                        } else {
                            const target = resolved_transcript_target orelse
                                return error.MissingResolvedTranscriptTarget;
                            transcript_transition = try presentation_shell.sealTranscriptTransition(
                                app.alloc,
                                source,
                                prepared,
                                &footer_frame.paint,
                                target,
                            );
                        }
                    }
                }
            }
            const committed_layout = solved_layout orelse return error.MissingSolvedFrameLayout;
            const commit_diagnostic = presentation_shell.transcriptCommitDiagnostic();
            debug_trace.logf(
                "scroll",
                "frame_builder_scroll terminal_scroll_rows={d} source_state={s} previous_committed_start_line={d} next_start_line={d}",
                .{
                    scroll_plan.terminal_scroll_rows,
                    @tagName(commit_diagnostic.state),
                    commit_diagnostic.stable_start_line orelse 0,
                    planned_scroll_next_start_line,
                },
            );

            const observation_activity: activity_runtime.ActivityProjection =
                if (footer_measurement) |*measurement|
                    measurement.activity_projection
                else
                    .{ .turn_thinking = .{ .label = footer_frame.label() } };
            var frame_ctx = FramePaintContext(App){
                .app = app,
                .presentation_shell = presentation_shell,
                .body = .transcript,
                .prepared_transcript = if (prepared_transcript) |*prepared| prepared else null,
                .footer_frame = &footer_frame,
                .activity_style = switch (observation_activity) {
                    .tool_slot => |slot| if (slot.thinking_label != null) .thinking else .tool_marker,
                    .turn_thinking => |thinking| switch (thinking.tone) {
                        .thinking => .thinking,
                        .live => .live,
                        .neutral => .neutral,
                        .warning => .warning,
                        .success => .success,
                        .danger => .danger,
                    },
                    .none => .thinking,
                },
                .activity_result = .{ .painted = false, .row = 0, .overlay = false },
            };
            const document_append = if (transcript_transition) |*transition|
                transition.document_append
            else
                render_engine.frame_scroll_plan.FrameDocumentAppend{};
            var transcript_body: render_engine.frame_builder.TranscriptBodyDisposition =
                if (transcript_transition) |*transition| switch (transition.body_disposition) {
                    .paint => .paint,
                    .retain_committed => |retained| .{ .retain = retained },
                } else .paint;
            const pending_preview_overlaps_flow = pending_submission_card and if (prepared_transcript) |prepared|
                pending_card.?.overlaps_flow_endpoint(prepared.cursor.cursor_col)
            else
                false;
            // A queued-message card took its separator from the shell's
            // cursor, which a terminal reset puts back at 1,1 while this frame
            // reprints a transcript that can end mid-row, as when a switch
            // shows another agent. It starts below this frame's endpoint
            // instead, so it never paints over the endpoint's row.
            if (!pending_submission_card) if (pending_card) |*card| if (prepared_transcript) |*prepared| {
                card.leading_advance_rows = pendingCardLeadingAdvanceRows(prepared.cursor.cursor_col);
            };
            var pending_paint_ctx = if (pending_preview_overlaps_flow) null else if (pending_card) |card|
                PendingCardPaintContext.init(
                    card,
                    footer_frame.paint.transcript_band,
                    if (prepared_transcript) |*prepared| prepared.cursor.cursor_row else null,
                    !footer_frame.paint.activity_band.isEmpty(),
                )
            else
                null;
            // A band too short for the preview below the flow endpoint defers it
            // the same way: adoption writes the real card.
            const pending_preview_deferred = pending_submission_card and
                prepared_transcript != null and pending_paint_ctx == null;
            if (pending_paint_ctx) |paint_ctx| switch (transcript_body) {
                .paint => {},
                .retain => |retained_source| {
                    const first_changed_row = paint_ctx.row;
                    if (first_changed_row <= retained_source.source_area.top) {
                        transcript_body = .paint;
                    } else if (first_changed_row <= retained_source.source_area.bottom) {
                        var narrowed = retained_source;
                        narrowed.source_area.bottom = first_changed_row - 1;
                        narrowed.occupied_last_row = @min(
                            narrowed.occupied_last_row,
                            narrowed.source_area.bottom,
                        );
                        transcript_body = .{ .retain = narrowed };
                    }
                },
            };
            if (pending_paint_ctx) |paint_ctx| {
                debug_trace.logf(
                    "frame_plan",
                    "pending_prompt_tail start={d} paint_rows={d} layout_rows={d} bytes={d} transcript={d}..{d} body={s}",
                    .{
                        paint_ctx.row,
                        paint_ctx.max_rows,
                        pending_card.?.row_count,
                        paint_ctx.bytes.len,
                        footer_frame.paint.transcript_band.top,
                        footer_frame.paint.transcript_band.bottom,
                        @tagName(transcript_body),
                    },
                );
            }
            const observation_rows = if (transcript_transition) |*transition|
                switch (transition.body_disposition) {
                    .paint => transition.row_provenance,
                    .retain_committed => presentation_shell.committedRowProvenance(),
                }
            else
                presentation_shell.committedRowProvenance();
            var counters: render_engine.frame_builder.TraceCounters = .{};
            try build_checkpoint.poll(checkpoint);
            if (footer_frame.paint.reset_terminal) {
                if (comptime @hasField(App, "terminal")) {
                    if (app.terminal.alternate_screen_owner == .none) {
                        app.terminal.clearTmuxScreenAndHistory(app.alloc);
                    }
                }
            }
            var frame_shell = SurfaceFrameShell.init(
                &app.shell,
                presentation_shell,
                active_committed_layout,
            );
            const result = try render_engine.frame_builder.buildAndFlushFrame(
                app.alloc,
                &frame_shell,
                &app.metrics,
                .{
                    .plan = footer_frame.paint,
                    .committed_layout = active_committed_layout,
                    .body = frame_ctx.body,
                    .transcript_body = transcript_body,
                    .scroll_plan = scroll_plan,
                    .document_append = document_append,
                    .terminal_transition = render_reconciliation.terminal_transition,
                    .body_painter = .{ .ctx = &frame_ctx, .paint = FramePaintContext(App).paintBody },
                    .transcript_tail_painter = if (pending_paint_ctx) |*paint_ctx| .{
                        .ctx = paint_ctx,
                        .paint = PendingCardPaintContext.paint,
                    } else null,
                    .footer_painter = .{ .ctx = &frame_ctx, .paint = FramePaintContext(App).paintFooter },
                    .activity_painter = .{ .ctx = &frame_ctx, .paint = FramePaintContext(App).paintActivity },
                    .trace_counters = &counters,
                    .observation = .{
                        .observer = &presentation_shell.ui_observer,
                        .row_provenance = observation_rows,
                        .activity = observation_activity,
                        .stream_active = footer_ctx.stream.active,
                        .completed_assistant_presentation_tail = footer_ctx.completed_assistant_presentation_tail,
                    },
                },
            );
            const scroll_commit = result.scrollCommit(scroll_plan);
            debug_trace.logf(
                "frame_diff",
                "attempt_result transcript_body={s} body_paints={d} retained_changed_cells={d} document_append_bytes={d} planned_scroll_rows={d} committed_scroll_rows={d} accepted_scroll_rows={d} unplanned_scroll_rows={d} changed_cells={d} shadow_state={s}",
                .{
                    @tagName(transcript_body),
                    counters.body_paints,
                    counters.retained_transcript_changed_cells,
                    document_append.bytes.len,
                    scroll_commit.planned_terminal_scroll_rows,
                    scroll_commit.physical_terminal_scroll_rows,
                    scroll_commit.accepted_terminal_scroll_rows,
                    scroll_commit.unplanned_terminal_scroll_rows,
                    result.changed_cells,
                    @tagName(result.state()),
                },
            );

            if (presentation_commits_transcript) {
                const transition_ptr: ?*transcript_runtime.TranscriptTransition =
                    if (transcript_transition) |*transition| transition else null;
                presentation_shell.consumeFrameScrollCommit(
                    app.alloc,
                    scroll_plan,
                    result,
                    transition_ptr,
                );
            }
            if (result.is_committed() and render_reconciliation.alternate_screen_owns_rendering) {
                app.terminal.alternate_frame_layout =
                    render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(committed_layout);
            }
            if (result.is_committed()) {
                switch (render_reconciliation.terminal_transition) {
                    .none => {},
                    .restore_normal_screen => app_lifecycle.commitApprovalInlineRestore(
                        &app.terminal,
                    ),
                }
            }
            if (result.is_committed() and presentation_commits_transcript) {
                restore_footer_prepare_state = false;
                presentation_shell.has_committed_frame = true;
                presentation_shell.terminal_reset_pending = false;
                if (footer_frame.paint.reset_terminal) {
                    app.shell.terminal_reset_pending = false;
                }
                if (transcript_transition == null) {
                    presentation_shell.committed_frame_layout = render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(committed_layout);
                    presentation_shell.invalidateTranscriptAnchor("empty_transcript_commit");
                }
                surface_frame.commitSurfaceFooterFrame(
                    app.alloc,
                    presentation_shell,
                    &footer_frame,
                    if (footer_measurement) |*measurement| measurement else null,
                );
                presentation_shell.shimmer_active = frame_ctx.activity_result.painted;
                presentation_shell.shimmer_is_overlay = frame_ctx.activity_result.overlay;
                if (scroll_plan.remaining_inline_advance_rows > 0) {
                    presentation_shell.markTranscriptDirty();
                } else if (!render_requests.hasReason(.transcript)) {
                    presentation_shell.transcript_band_dirty = false;
                }
                if (!render_requests.hasReason(.external_damage)) {
                    presentation_shell.footer_viewport.clearExternalInvalidation();
                }
            }
            return .{
                .shadow_state = result.state(),
                .animation_visible = frame_ctx.activity_result.painted,
                // The committed pending UI permits adoption even when its preview
                // would overwrite the flow endpoint. Adoption writes the real card.
                .pending_prompt_presented = pending_submission_card and (pending_paint_ctx != null or pending_preview_deferred),
                .file_picker_receipt = if (result.is_committed() and presentation_commits_transcript and
                    footer_measurement != null and footer_measurement.?.show_picker and
                    footer_measurement.?.picker_kind == .file and footer_measurement.?.picker_rows > 0)
                    paintedFilePickerReceipt(file_picker_receipt, footer_measurement.?.picker_rows, footer_ctx.file_completion_status != null)
                else
                    null,
            };
        }

        pub noinline fn requestNormalViewportRecovery(app: *App) !void {
            if (comptime @hasField(App, "terminal")) {
                if (app.terminal.alternate_screen_owner != .none) return;
                try shell_runtime.requestRedraw(&app.shell, &app.metrics, .replay_viewport);
            }
        }

        fn skillsMenuActive(app: *const App) bool {
            if (comptime @hasField(App, "skills")) return app.skills.menuVisible();
            return false;
        }

        fn modelMenuActive(app: *const App) bool {
            if (comptime @hasField(App, "model_cache")) return app.model_cache.menu.active;
            return false;
        }

        fn sessionMenuActive(_: *const App, agent: *const AppAgent) bool {
            if (comptime agents.hasAgentField(App, "session_persistence")) return agent.session_persistence.session_picker.active;
            return false;
        }

        fn agentsMenuActive(app: *const App) bool {
            if (comptime !@hasField(App, "instances")) return false;
            return app.instances.agents_menu.open;
        }

        // The open agent list takes the footer from the shown agent's
        // question, so the list stays visible while it previews a waiting
        // agent. The prompt itself is untouched and returns when it closes.
        fn shownQuestion(app: *const App, agent: *AppAgent) ?question_prompt.Projection {
            if (agentsMenuActive(app)) return null;
            return agent.question_prompt.projection();
        }

        fn forkMenuActive(_: *const App, agent: *const AppAgent) bool {
            if (comptime agents.hasAgentField(App, "session_persistence")) return agent.session_persistence.fork_menu.active();
            return false;
        }

        fn helpMenuActive(app: *const App) bool {
            if (comptime @hasField(App, "input_runtime")) return app.input_runtime.help_menu.active;
            return false;
        }

        fn effortMenuActive(app: *const App) bool {
            if (comptime @hasField(App, "input_runtime")) return app.input_runtime.effort_menu.active;
            return false;
        }

        fn settingsMenuActive(app: *const App) bool {
            if (comptime @hasField(App, "input_runtime")) return app.input_runtime.settings_menu.active;
            return false;
        }

        fn catalogMenuActive(app: *const App) bool {
            return modelMenuActive(app) and !settingsMenuActive(app);
        }

        fn activityProjection(app: *const App) activity_runtime.ActivityProjection {
            return shell_runtime.activityProjection(&app.shell);
        }

        fn activeRenderRequests(app: *App) *render_request.RenderRequestState {
            return &app.shell.render_requests;
        }

        pub fn requestActiveSurfaceFrame(
            app: *App,
            reason: render_request.Reason,
        ) void {
            activeRenderRequests(app).request(reason);
        }

        pub fn eventLoopCallbacks(app: *App) event_loop.EventLoopCallbacks {
            return .{
                .ctx = @ptrCast(app),
                .collect_facts = App.loopCollectFacts,
                .next_collected_byte = App.loopNextCollectedByte,
                .handle_byte = App.loopHandleByte,
                .settle_delivery_epoch = App.loopSettleInputDeliveryEpoch,
                .commit_frame = App.loopCommitFrame,
                .poll_timeout_ms = if (comptime @hasDecl(App, "loopPollTimeoutMs")) App.loopPollTimeoutMs else null,
            };
        }
    };
}

fn renderReasonNames(
    reasons: render_request.ReasonSet,
    buf: *[128]u8,
) []const u8 {
    var len: usize = 0;
    for (std.meta.tags(render_request.Reason)) |reason| {
        if (!reasons.contains(reason)) continue;
        if (len > 0) {
            if (len == buf.len) break;
            buf[len] = ',';
            len += 1;
        }
        const name = @tagName(reason);
        const copy_len = @min(name.len, buf.len - len);
        @memcpy(buf[len..][0..copy_len], name[0..copy_len]);
        len += copy_len;
        if (copy_len < name.len) break;
    }
    if (len == 0) return "none";
    return buf[0..len];
}

fn FixedPointTranscriptContext(comptime App: type) type {
    return struct {
        app: *App,
        presentation_shell: *transcript_runtime.TranscriptRuntime,
        prepare_transcript: bool,
        source: ?*const transcript_runtime.TranscriptPreparationSource,
        prepared_transcript: *?transcript_painter.PreparedTranscriptSurfacePaint,
        resolved_target: *?transcript_runtime.TranscriptRuntime.ResolvedTranscriptTarget,
        footer_reservation_changed: bool,
        replay_displaced_footer_history: bool,
        footer_measurement: ?*const surface_frame.SurfaceFooterMeasurement,
        fallback_footer_rows: ?render_engine.footer_layout.FooterRows,
        activity_projection: activity_runtime.ActivityProjection,
        frame_activity: render_engine.frame_layout.ActivityState,
        base_invalidation: render_engine.paint_plan.FrameInvalidationSet,
        attempt_invalidations: render_engine.paint_plan.FrameInvalidationSet,
        pending_tail_rows: u16 = 0,
        scroll_facts: ?transcript_runtime.TranscriptScrollFacts = null,

        fn prepareCandidate(
            self: *@This(),
            candidate: render_engine.frame_layout.FrameLayout,
        ) !render_engine.frame_fixed_point.CandidatePreparation {
            if (self.prepared_transcript.*) |*prepared| {
                prepared.deinit(self.app.alloc);
                self.prepared_transcript.* = null;
            }
            self.resolved_target.* = null;
            self.scroll_facts = null;
            if (!self.prepare_transcript or candidate.transcript_area.isEmpty()) return .{
                .inline_advance_rows = 0,
                .occupied_transcript_rows = candidate.transcript_area.height(),
            };
            const source = self.source orelse return error.MissingTranscriptPreparationSource;
            const canonical_area = transcriptAreaBeforePendingTail(
                candidate.transcript_area,
                self.pending_tail_rows,
            );

            self.prepared_transcript.* = try self.presentation_shell.prepareTranscriptSurfacePaintFromSourceForFrame(
                self.app.alloc,
                &self.app.metrics,
                source,
                canonical_area,
                self.footer_reservation_changed,
            );
            const prepared = &self.prepared_transcript.*.?;
            const scroll_facts = try self.presentation_shell.prepareTranscriptScrollFactsForFrame(
                self.app.alloc,
                source,
                prepared,
                self.footer_reservation_changed,
                self.replay_displaced_footer_history,
            );
            self.scroll_facts = scroll_facts;
            const canonical_occupied_rows = if (prepared.selection.last_visible_row >= canonical_area.top)
                prepared.selection.last_visible_row - canonical_area.top + 1
            else
                0;
            return .{
                .inline_advance_rows = scroll_facts.planned_rows,
                .occupied_transcript_rows = @min(
                    canonical_occupied_rows +| self.pending_tail_rows,
                    candidate.transcript_area.height(),
                ),
            };
        }

        fn resolveCandidate(
            self: *@This(),
            candidate: render_engine.frame_layout.FrameLayout,
            scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
        ) !render_engine.frame_fixed_point.CandidateResolution {
            const candidate_rows = candidate.transcript_area.height();
            if (!self.prepare_transcript or candidate.transcript_area.isEmpty()) {
                return .{ .occupied_transcript_rows = candidate_rows };
            }
            const source = self.source orelse return error.MissingTranscriptPreparationSource;
            const prepared = if (self.prepared_transcript.*) |*value| value else return error.MissingTranscriptPaint;
            const scroll_facts = self.scroll_facts orelse return error.MissingTranscriptScrollFacts;
            const footer_rows = if (self.footer_measurement) |measurement|
                measurement.frameLayoutRows(
                    self.presentation_shell.layout.rows,
                    candidate.footer_area.top,
                )
            else
                self.fallback_footer_rows orelse return error.MissingFooterRows;
            const activity = render_engine.activity_placement.resolve(
                self.activity_projection,
                self.frame_activity,
                candidate,
            );
            var candidate_plan = candidate.toPaintPlan(.{
                .footer_rows = footer_rows,
                .viewport = prepared.selection,
                .activity = activity,
                .invalidation = self.base_invalidation,
                .cursor_target = .{
                    .row = prepared.cursor.cursor_row,
                    .col = prepared.cursor.cursor_col,
                    .visible = true,
                },
            });
            candidate_plan.invalidation = try surface_invalidation.resolveCandidateFrameInvalidations(
                self.presentation_shell,
                candidate_plan,
                if (self.footer_measurement) |measurement|
                    measurement.frameInvalidationUpdate()
                else
                    null,
                self.attempt_invalidations,
            );
            const destructive_invalidation = render_engine.frame_retention.transcriptAreaHasDestructiveInvalidation(
                self.presentation_shell.committed_frame_layout.transcript_area,
                candidate_plan.invalidation,
            );
            const target = try self.presentation_shell.resolveTranscriptTransitionTargetForFrameInArea(
                self.app.alloc,
                source,
                prepared,
                render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(candidate),
                transcriptAreaBeforePendingTail(
                    candidate.transcript_area,
                    self.pending_tail_rows,
                ),
                scroll_plan,
                scroll_facts,
                destructive_invalidation,
                activity == .overlay_entry,
            );
            self.resolved_target.* = target;
            return .{ .occupied_transcript_rows = @min(
                target.occupiedTranscriptRows() +| self.pending_tail_rows,
                candidate.transcript_area.height(),
            ) };
        }
    };
}

fn transcriptAreaBeforePendingTail(
    area: render_engine.frame_layout.FrameRect,
    tail_rows: u16,
) render_engine.frame_layout.FrameRect {
    if (area.isEmpty() or tail_rows == 0) return area;
    // A tail taller than the band still leaves the flow endpoint row. Without
    // it the frame seals no transcript transition, and adoption would rebase
    // onto rows that never reached scrollback.
    const canonical_rows = @max(area.height() -| tail_rows, 1);
    return .{ .top = area.top, .bottom = area.top + canonical_rows - 1 };
}

fn FramePaintContext(comptime App: type) type {
    return struct {
        app: *App,
        presentation_shell: *transcript_runtime.TranscriptRuntime,
        body: render_engine.frame_builder.FrameBody,
        prepared_transcript: ?*const transcript_painter.PreparedTranscriptSurfacePaint,
        footer_frame: *const surface_frame.SurfaceFooterFrame,
        activity_style: shimmer_runtime.ActivityPaintStyle,
        activity_result: render_engine.paint_plan.ActivityPaintResult,

        fn paintBody(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (self.body) {
                .transcript => {
                    if (surface.plan.transcript_band.isEmpty()) return;
                    if (self.prepared_transcript) |prepared| {
                        _ = try self.presentation_shell.paintPreparedTranscriptIntoSurface(self.app.alloc, surface, prepared);
                    }
                },
                .subagent_panel => |text| {
                    if (surface.plan.transcript_band.isEmpty() or text.len == 0) return;
                    const rows = surface.plan.transcript_band.bottom - surface.plan.transcript_band.top + 1;
                    _ = try surface.writeAnsiBand(surface.plan.transcript_band.top, rows, text, .transcript, .same_owner);
                },
                .none => {},
            }
        }

        fn paintFooter(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = try footer_viewport.paintFooterIntoSurface(surface, &self.footer_frame.composed);
        }

        fn paintActivity(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.activity_result = try shimmer_runtime.paintActivityIntoSurface(surface, .{
                .label = self.footer_frame.label(),
                .tool_label = self.footer_frame.toolLabel(),
                .shimmer_pos = self.footer_frame.shimmer_pos,
                .style = self.activity_style,
                .thinking_blink = self.footer_frame.thinking_blink,
            });
        }
    };
}

fn validatePreparedTranscriptFitsPlan(
    prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
    plan: render_engine.paint_plan.PaintPlan,
) !void {
    const selection = prepared.selection;
    const has_prepared_rows = prepared.total_lines > 0 or selection.last_visible_row > 0;
    if (!has_prepared_rows) return;

    if (plan.transcript_band.isEmpty() or
        selection.top_row < plan.transcript_band.top or
        selection.bottom_row > plan.transcript_band.bottom or
        selection.last_visible_row > plan.transcript_band.bottom)
    {
        debug_trace.logf(
            "frame_plan",
            "prepared_transcript_outside_band selection={d}..{d} last_visible={d} transcript_band={d}..{d} total_lines={d}",
            .{
                selection.top_row,
                selection.bottom_row,
                selection.last_visible_row,
                plan.transcript_band.top,
                plan.transcript_band.bottom,
                prepared.total_lines,
            },
        );
        return error.InvalidPaintPlan;
    }
}

fn promptTurnReservation(
    app: anytype,
    shell: *const transcript_runtime.TranscriptRuntime,
    canonical_preview: render_engine.frame_layout.TranscriptFlowPreview,
    pending_card: ?PendingCardProjection,
    footer_measurement: ?*const surface_frame.SurfaceFooterMeasurement,
    frame_activity: render_engine.frame_layout.ActivityState,
) render_engine.frame_layout.PromptTurnReservation {
    if (frame_activity != .none) return .{};
    const measurement = footer_measurement orelse return .{};
    if (!measurement.input_visible or
        measurement.show_picker or
        measurement.picker_rows > 0 or
        measurement.banner_active or
        measurement.footer_gap_active or
        agents.screenAgentOf(app).stream.active or
        shell.fullTranscriptActive()) return .{};
    if (comptime @hasField(@TypeOf(app.*), "skills")) {
        if (comptime @hasDecl(@TypeOf(app.skills), "menuVisible")) {
            if (app.skills.menuVisible()) return .{};
        }
    }

    const future_activity = render_engine.frame_layout.ActivityState.thinkingAfterUserTurn();
    const pending_submission_active = if (comptime agents.hasAgentField(@TypeOf(app.*), "submission"))
        agents.screenAgentOf(app).submission.pending != null
    else
        false;
    if (pending_card != null or pending_submission_active) {
        const canonical_rows = if (pending_card) |card|
            canonical_preview.natural_visual_rows +| (card.row_count -| 1)
        else
            canonical_preview.natural_visual_rows;
        return .{ .transcript_rows = canonical_rows, .activity = future_activity };
    }
    return .{};
}

/// Records how many file rows the frame painted, so keyboard navigation
/// scrolls the same window the user sees.
fn paintedFilePickerReceipt(receipt: ?input_completion_runtime.FilePickerReceipt, picker_rows: u16, has_status: bool) ?input_completion_runtime.FilePickerReceipt {
    var painted = receipt orelse return null;
    painted.visible_rows = picker_presentation.filePickerItemRows(picker_rows, has_status);
    return painted;
}

fn footerMeasurementFromRows(rows: render_engine.footer_layout.FooterRows) render_engine.frame_layout.FooterMeasurement {
    return .{
        .natural_rows = rows.total_rows,
        .min_rows = 1,
        .max_rows = rows.total_rows,
        .input_rows = 1,
        .picker_rows = if (rows.picker_start <= rows.bottom_divider and rows.bottom_divider > rows.picker_divider)
            rows.bottom_divider - rows.picker_divider - 1
        else
            0,
        .banner_rows = rows.banner_rows,
    };
}

fn activityStateFromPlacement(activity: render_engine.activity_overlay.ActivityPlacement) render_engine.frame_layout.ActivityState {
    return switch (activity) {
        .transient_row => |transient| .{ .thinking = .{
            .gap_above_activity = transient.gap_above_rows,
            .activity_rows = transient.row_count,
            .footer_gap_after_activity = transient.footer_clearance_rows,
            .tool_before_activity = transient.tool_row != null,
        } },
        .overlay_entry => |row| .{ .overlay_entry = row },
        .none => .none,
    };
}

noinline fn frameActivityStateFromMeasurement(
    shell: *const transcript_runtime.TranscriptRuntime,
    measurement: *const surface_frame.SurfaceFooterMeasurement,
) render_engine.frame_layout.ActivityState {
    return switch (measurement.activity_projection) {
        .none => .none,
        .tool_slot => |slot| if (slot.active)
            transientActivityState(shell, measurement.activity_projection, slot.thinking_label != null)
        else
            .none,
        .turn_thinking => transientActivityState(shell, measurement.activity_projection, false),
    };
}

fn transientActivityState(
    shell: *const transcript_runtime.TranscriptRuntime,
    projection: activity_runtime.ActivityProjection,
    tool_before_activity: bool,
) render_engine.frame_layout.ActivityState {
    return .{ .thinking = .{
        .gap_above_activity = render_input.transientActivityGapRows(shell, tool_before_activity),
        .activity_rows = render_input.activityProjectionRows(projection, shell.layout.cols),
        .footer_gap_after_activity = render_engine.transcript_blocks.footerBoundaryGapRowsForTail(.turn_summary),
        .tool_before_activity = tool_before_activity,
    } };
}

fn framePlanBandsEqual(
    old: render_engine.paint_plan.PaintPlan,
    solved: render_engine.paint_plan.PaintPlan,
) bool {
    return frameBandsEqual(old.transcript_band, solved.transcript_band) and
        frameBandsEqual(old.blank_band, solved.blank_band) and
        frameBandsEqual(old.activity_band, solved.activity_band) and
        frameBandsEqual(old.footer_gap_band, solved.footer_gap_band) and
        frameBandsEqual(old.footer_band, solved.footer_band);
}

noinline fn frameBandsEqual(
    a: render_engine.paint_plan.FrameBand,
    b: render_engine.paint_plan.FrameBand,
) bool {
    return a.top == b.top and a.bottom == b.bottom and a.owner == b.owner;
}

const FixedPointTestContext = struct {
    inline_advance_rows: u16 = 0,
    prepared_occupied_rows: ?u16 = null,

    fn prepareCandidate(
        self: *FixedPointTestContext,
        layout: render_engine.frame_layout.FrameLayout,
    ) !render_engine.frame_fixed_point.CandidatePreparation {
        return .{
            .inline_advance_rows = self.inline_advance_rows,
            .occupied_transcript_rows = layout.transcript_area.height(),
        };
    }

    fn resolveCandidate(
        self: *FixedPointTestContext,
        layout: render_engine.frame_layout.FrameLayout,
        scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
    ) !render_engine.frame_fixed_point.CandidateResolution {
        _ = scroll_plan;
        return .{
            .occupied_transcript_rows = self.prepared_occupied_rows orelse layout.transcript_area.height(),
        };
    }
};

fn fixedPointTestInput(
    terminal_rows: u16,
    owned_top: u16,
    transcript_rows: u16,
    footer_rows: u16,
    body_mode: render_engine.frame_layout.BodyMode,
) render_engine.frame_layout.SolveInput {
    return .{
        .terminal = .{
            .rows = terminal_rows,
            .cols = 80,
            .content_bottom = terminal_rows -| 4,
            .divider_top_row = terminal_rows -| 3,
            .input_row = terminal_rows -| 2,
            .divider_bottom_row = terminal_rows -| 1,
            .hint_row = terminal_rows,
        },
        .owned_top = owned_top,
        .footer = .{
            .natural_rows = footer_rows,
            .min_rows = footer_rows,
            .max_rows = footer_rows,
        },
        .transcript = .{ .natural_visual_rows = transcript_rows },
        .body_mode = body_mode,
    };
}

fn solveFixedPointForTest(
    ctx: *FixedPointTestContext,
    input: render_engine.frame_layout.SolveInput,
) !render_engine.frame_fixed_point.FramePlan {
    return render_engine.frame_fixed_point.solve(
        FixedPointTestContext,
        ctx,
        input,
        FixedPointTestContext.prepareCandidate,
        FixedPointTestContext.resolveCandidate,
    );
}

test "pending prompt projection waits for a paintable terminal width" {
    const alloc = std.testing.allocator;
    const input_submit_runtime = @import("input_submit_runtime.zig");
    const TestApp = struct {
        alloc: std.mem.Allocator,
        main_agent: struct {
            submission: input_submit_runtime.State,
        },

        pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
            return &self.main_agent;
        }
    };
    const prompt = try alloc.dupe(u8, "visible prompt");
    var app = TestApp{
        .alloc = alloc,
        .main_agent = .{ .submission = .{ .pending = .{ .draft = .{
            .turn_id = 1,
            .prompt = prompt,
            .images = &.{},
            .skill_display_spans = &.{},
        } } } },
    };
    defer app.agent().submission.pending.?.deinit(alloc);

    for ([_]u16{ 1, 2 }) |cols| {
        var shell = transcript_runtime.TranscriptRuntime{
            .layout = .{
                .rows = 4,
                .cols = cols,
                .content_bottom = 1,
                .divider_top_row = 2,
                .input_row = 2,
                .divider_bottom_row = 3,
                .hint_row = 4,
            },
            .cursor_row = 1,
            .cursor_col = 1,
        };
        defer shell.deinit(alloc);

        try std.testing.expect((try buildPendingCardProjection(
            TestApp,
            &app,
            &shell,
            null,
        )) == null);
        try std.testing.expectEqual(
            input_submit_runtime.PendingPhase.awaiting_frame,
            app.agent().submission.pending.?.phase,
        );
    }

    var resized_shell = transcript_runtime.TranscriptRuntime{
        .layout = .{
            .rows = 4,
            .cols = 80,
            .content_bottom = 1,
            .divider_top_row = 2,
            .input_row = 2,
            .divider_bottom_row = 3,
            .hint_row = 4,
        },
        .cursor_row = 1,
        .cursor_col = 1,
    };
    defer resized_shell.deinit(alloc);
    var projection = (try buildPendingCardProjection(
        TestApp,
        &app,
        &resized_shell,
        null,
    )).?;
    defer projection.deinit(alloc);
    try std.testing.expect(projection.paint_row_count > 0);
}

fn currentCompactSource(shell: *transcript_runtime.TranscriptRuntime) ?*transcript_runtime.TranscriptPreparationSource {
    for (&shell.notebook.compact_transcript_source_cache.entries) |*entry| {
        if (entry.*) |*cached| {
            if (cached.content_revision == shell.notebook.full_transcript_content_revision and
                cached.cols == shell.layout.cols and
                cached.has_committed_frame == shell.has_committed_frame)
            {
                return &cached.source;
            }
        }
    }
    return null;
}

const compact_source_cache_capacity = @typeInfo(@FieldType(
    @FieldType(transcript_runtime.TranscriptNotebook, "compact_transcript_source_cache"),
    "entries",
)).array.len;

fn compactSourceCacheSlots(shell: *const transcript_runtime.TranscriptRuntime) [compact_source_cache_capacity]?[*]const u8 {
    var slots: [compact_source_cache_capacity]?[*]const u8 = undefined;
    for (shell.notebook.compact_transcript_source_cache.entries, &slots) |entry, *slot| {
        slot.* = if (entry) |cached| cached.source.bytes.ptr else null;
    }
    return slots;
}

fn findGridRow(alloc: std.mem.Allocator, physical: *vt_emulator.Grid, needle: []const u8) !?u16 {
    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(alloc);
    for (1..physical.rows + 1) |row| {
        row_text.clearRetainingCapacity();
        try physical.rowTextTrimmed(@intCast(row), &row_text);
        if (std.mem.find(u8, row_text.items, needle) != null) return @intCast(row);
    }
    return null;
}

fn expectTallPendingPromptReachesScrollback(rows: u16, preview_tail: usize) !void {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "pending-banner-paste.log", .{ .read = true });
    defer file.close(std.testing.io);
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{ .stdout_file = file, .layout = .{ .cols = 80, .rows = rows, .content_bottom = rows - 4, .divider_top_row = rows - 3, .input_row = rows - 2, .divider_bottom_row = rows - 1, .hint_row = rows } },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    var physical = try vt_emulator.Grid.init(alloc, 80, rows);
    defer physical.deinit();
    physical.defer_sync_updates = false;
    var history: std.ArrayList(u8) = .empty;
    defer history.deinit(alloc);
    var offset: u64 = 0;
    const banner = "BANNER_ROW · Run /help for commands";
    _ = try app.shell.appendRawTranscriptEntryClassified(alloc, banner, .unknown_raw);
    app.shell.render_requests.request(.first_frame);
    app.shell.render_requests.consecutive_input_pending_aborts = render_request.max_consecutive_input_pending_aborts;
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app, (&app).agent());
    const first = try readCoordinatorFrameBytes(alloc, file, &offset);
    defer alloc.free(first);
    try feedRewritePublicationFrame(alloc, &physical, &history, first);
    try std.testing.expectEqual(@as(u16, 1), app.shell.cursor_row);
    try std.testing.expect(app.shell.cursor_col > 1);

    const first_line = "FIRST_PROMPT_LINE";
    const last_line = "LAST_PROMPT_LINE";
    const prompt = first_line ++ "\n" ++ text_utils.repeat("PASTE_BODY\n", 60) ++ last_line;
    app.agent().submission.pending = .{ .draft = .{
        .turn_id = 1,
        .prompt = try alloc.dupe(u8, prompt),
        .images = &.{},
        .skill_display_spans = &.{},
    } };
    _ = try flushRebasedPublicationFrame(&app, file, &physical, &history, &offset);
    try std.testing.expectEqual(@as(usize, 1), app.pending_frame_commits);
    try std.testing.expect(app.shell.transcript_commit_state == .stable);
    const preview = try rewritePublicationText(alloc, &physical, history.items);
    defer alloc.free(preview);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, preview, banner));
    try std.testing.expectEqual(preview_tail, std.mem.count(u8, preview, last_line));

    app.agent().submission.pending.?.phase = .adopted;
    _ = try app.shell.writeUserPromptCard(alloc, &app.metrics, .{ .text = app.agent().submission.pending.?.draft.prompt }, true, &.{});
    try std.testing.expect(try flushRebasedPublicationFrame(&app, file, &physical, &history, &offset) > 0);
    const adopted = try rewritePublicationText(alloc, &physical, history.items);
    defer alloc.free(adopted);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, adopted, banner));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, adopted, first_line));
    try std.testing.expectEqual(@as(usize, 60), std.mem.count(u8, adopted, "PASTE_BODY"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, adopted, last_line));
    try std.testing.expect(std.mem.find(u8, adopted, banner).? < std.mem.find(u8, adopted, first_line).?);
}

noinline fn shouldResetPhysicalTerminal(
    alternate_screen_active: bool,
    main_reset_pending: bool,
) bool {
    return !alternate_screen_active and main_reset_pending;
}

const CoordinatorFault = enum {
    committed,
    preparation_error,
    input_pending,
    terminal_partial_write,
    shadow_feed_failed,
};

const BufferedInputCheckpointTestApp = struct {
    const PollState = struct {
        readable: bool = false,

        fn closed(_: PollState) bool {
            return false;
        }
    };

    const Terminal = struct {
        fn pollInput(_: *Terminal, _: i32) !PollState {
            return .{};
        }
    };

    terminal: Terminal = .{},
    input_runtime: core_input_runtime.Runtime = .{},
    terminal_input_runtime: ui_input.Runtime = .{},
};

const CoordinatorFaultTestApp = struct {
    main_agent: struct {} = .{},
    alloc: std.mem.Allocator = std.testing.allocator,
    input_runtime: core_input_runtime.Runtime = .{},
    shell: struct {
        terminal_dimensions_invalid: bool = false,
        terminal_reset_pending: bool = false,
        resize_history_row_delta: ?i32 = null,
        pending_resize_observation: ?transcript_runtime.ResizeObservation = null,
        layout: struct {
            rows: u16 = 24,
            cols: u16 = 80,
        } = .{},
        render_requests: render_request.RenderRequestState = .{},
    } = .{},
    fault: CoordinatorFault = .committed,
    attempts: usize = 0,
    injected_reason: ?render_request.Reason = null,
    inject_animation_reset: bool = false,
    animation_visible: bool = false,
    notification_flushes: usize = 0,
    file_picker_receipt: ?input_completion_runtime.FilePickerReceipt = null,
    last_snapshot: ?render_request.AttemptSnapshot = null,

    pub fn flushNotifications(self: *CoordinatorFaultTestApp) void {
        self.notification_flushes += 1;
    }

    pub fn renderFrameAttemptForTest(
        self: *CoordinatorFaultTestApp,
        snapshot: render_request.AttemptSnapshot,
    ) !FrameAttemptResult {
        self.attempts += 1;
        self.last_snapshot = snapshot;
        if (self.injected_reason) |reason| {
            self.shell.render_requests.request(reason);
        }
        if (self.inject_animation_reset) {
            self.shell.render_requests.requestAnimationReset();
        }

        return switch (self.fault) {
            .committed => blk: {
                self.shell.terminal_reset_pending = false;
                break :blk .{
                    .shadow_state = .committed,
                    .animation_visible = self.animation_visible,
                    .file_picker_receipt = self.file_picker_receipt,
                };
            },
            .preparation_error => error.TestPreparationFailure,
            .input_pending => error.InputPending,
            .terminal_partial_write => .{
                .shadow_state = .terminal_partial_write,
                .animation_visible = self.animation_visible,
            },
            .shadow_feed_failed => .{
                .shadow_state = .shadow_feed_failed,
                .animation_visible = self.animation_visible,
            },
        };
    }
    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

const CoordinatorTestWorker = struct {
    cancel_requested: bool = false,
    cancel_continues_turn: bool = false,
    steering_messages: []const []const u8 = &.{},
    compaction: @import("../output/compaction_activity.zig").State = .{},

    pub fn compactionActivitySnapshot(self: *const @This()) @import("../output/compaction_activity.zig").Snapshot {
        return self.compaction.snapshot;
    }

    pub fn snapshotSteeringPresentation(
        self: *const @This(),
        alloc: std.mem.Allocator,
    ) !@import("../agent/worker_runtime.zig").SteeringPresentationSnapshot {
        var snapshot: @import("../agent/worker_runtime.zig").SteeringPresentationSnapshot = .{};
        errdefer snapshot.deinit(alloc);
        if (self.steering_messages.len == 0) return snapshot;
        snapshot.messages = try alloc.alloc([]u8, self.steering_messages.len);
        for (snapshot.messages) |*message| message.* = &.{};
        for (self.steering_messages, 0..) |message, index| {
            snapshot.messages[index] = try alloc.dupe(u8, message);
        }
        return snapshot;
    }

    pub fn isCancelRequested(self: *const @This()) bool {
        return self.cancel_requested;
    }

    pub fn cancellationStopsTurn(self: *const @This()) bool {
        return self.cancel_requested and !self.cancel_continues_turn;
    }
};

const CoordinatorTestUpgrader = struct {
    fn statusLabel(_: *@This(), _: []u8) []const u8 {
        return "";
    }
};

const CoordinatorTestPacer = struct {
    pending: bool = false,
    completed_token_progress: ?types.TurnTokenProgress = null,

    fn hasCompletedAssistantPresentationTail(self: *const CoordinatorTestPacer) bool {
        return self.completed_token_progress != null;
    }

    fn hasPending(self: *const CoordinatorTestPacer) bool {
        return self.pending;
    }

    fn completedAssistantPresentationTokenProgress(self: *const CoordinatorTestPacer) ?types.TurnTokenProgress {
        return self.completed_token_progress;
    }
};

const coordinator_test_slash_specs = [_]command_specs.SlashSpec{.{
    .kind = .help,
    .command = "/help",
    .help_entry = "/help",
    .completion_description = "show available slash commands",
    .presentation_category = .general,
}};
const coordinator_test_slash_registry = command_specs.SlashRegistry{
    .commands = coordinator_test_slash_specs[0..],
};

const CoordinatorTestTerminalClient = struct {
    snapshot_alloc: std.mem.Allocator = std.testing.allocator,
    snapshot_count: usize = 0,
    source_running: bool = false,

    fn terminalProjection(
        self: *CoordinatorTestTerminalClient,
        _: std.mem.Allocator,
    ) std.mem.Allocator.Error!terminal_ui_projection.Snapshot {
        self.snapshot_count += 1;
        const rows = try self.snapshot_alloc.alloc(
            terminal_ui_projection.Row,
            @intFromBool(self.source_running),
        );
        errdefer self.snapshot_alloc.free(rows);
        if (self.source_running) {
            const session_id = try self.snapshot_alloc.dupe(u8, "terminal-test");
            errdefer self.snapshot_alloc.free(session_id);
            rows[0] = .{
                .session_id = session_id,
                .label = try self.snapshot_alloc.dupe(u8, "test command"),
                .lifecycle = .running,
                .attention = .{},
                .backend = .native,
            };
        }
        self.source_running = false;
        return .{ .alloc = self.snapshot_alloc, .rows = rows };
    }
};

const CoordinatorTestApp = struct {
    alloc: std.mem.Allocator,
    terminal: shell_runtime.TerminalState = .{},
    shell: transcript_runtime.TranscriptRuntime,
    metrics: types.Metrics = .{},
    input_runtime: core_input_runtime.Runtime = .{},
    terminal_input_runtime: ui_input.Runtime = .{},
    selected_model: std.ArrayList(u8) = .empty,
    workspace_root: []const u8 = "",
    workspace_identity: statusline_identity.Runtime = .{},
    pacer: CoordinatorTestPacer = .{},
    auth: auth_runtime.Runtime = .{},
    main_agent: struct {
        pending_images: std.ArrayList(types.ImageAttachment) = .empty,
        effort: types.ReasoningEffort = .auto,
        total_input_tokens: u64 = 0,
        question_prompt: question_prompt.QuestionPrompt = .{},
        submission: @import("input_submit_runtime.zig").State = .{},
        session_persistence: app_session_runtime.Persistence = .{},
        worker: CoordinatorTestWorker = .{},
        stream: types.StreamState = .{},
    } = .{},
    skills: skill_runtime.Runtime = .{},
    model_cache: model_cache_runtime.Runtime = model_cache_runtime.Runtime.init(std.testing.allocator),
    model_cache_loading: bool = false,
    fast_mode: bool = false,
    statusline_context: bool = false,
    intrinsic_fast_model: ?[]const u8 = null,
    gateway_metadata_model: ?[]const u8 = null,
    gateway_metadata: model_capabilities.GatewayMetadata = .{},
    authority_mutex: std.Io.Mutex = .init,
    upgrader: CoordinatorTestUpgrader = .{},
    terminal_client: CoordinatorTestTerminalClient = .{},
    file_completion_values: []const file_index.SearchResult = &.{},
    file_completion_calls: usize = 0,
    pending_frame_commits: usize = 0,

    pub fn notePendingFrameCommitted(self: *CoordinatorTestApp, _: anytype) void {
        self.pending_frame_commits += 1;
    }

    pub fn slashRegistry(_: *const CoordinatorTestApp) command_specs.SlashRegistry {
        return coordinator_test_slash_registry;
    }

    fn deinit(self: *CoordinatorTestApp) void {
        if (self.agent().submission.pending) |*pending| pending.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.terminal_input_runtime.deinit(self.alloc);
        self.agent().question_prompt.deinit(self.alloc);
        self.selected_model.deinit(self.alloc);
        self.workspace_identity.deinit(self.alloc);
        self.agent().pending_images.deinit(self.alloc);
        self.model_cache.deinit();
    }

    pub fn prepareDirectoryCompletion(self: *CoordinatorTestApp) void {
        const completion = @import("../input/file_completion_state.zig");
        const state = &self.input_runtime.picker.file_completion;
        const rows = completion.Rows.copy(self.alloc, self.file_completion_values) catch {
            state.stage(self.alloc, .{ .state = .ready }, .unavailable, null);
            return;
        };
        self.file_completion_calls += 1;
        state.stage(self.alloc, .{ .state = .ready }, if (rows.results.len == 0) .empty else .ready, rows);
    }

    pub fn modelCompletions(_: *CoordinatorTestApp, _: []const u8, _: [][]const u8) usize {
        return 0;
    }

    pub fn fileCompletions(
        self: *CoordinatorTestApp,
        _: []const u8,
        out: []file_index.SearchResult,
        _: []file_index.MatchSpan,
        _: []u8,
    ) file_index.SearchError!usize {
        self.file_completion_calls += 1;
        const count = @min(out.len, self.file_completion_values.len);
        @memcpy(out[0..count], self.file_completion_values[0..count]);
        return count;
    }

    pub fn writeDomainNotice(_: *CoordinatorTestApp, _: types.SemanticNotice, _: bool) !void {}

    fn isModelCacheLoading(self: *CoordinatorTestApp) bool {
        return self.model_cache_loading;
    }

    fn isModelCacheFailed(_: *CoordinatorTestApp) bool {
        return false;
    }

    pub fn resolvedModelCapabilities(self: *CoordinatorTestApp, model: []const u8) model_capabilities.Capabilities {
        var fallback = model_capabilities.Capabilities{
            .context_window = 1_000_000,
        };
        if (self.intrinsic_fast_model) |intrinsic_model| {
            fallback.intrinsic_fast = std.mem.eql(u8, intrinsic_model, model);
        }
        if (self.gateway_metadata_model) |metadata_model| {
            if (std.mem.eql(u8, metadata_model, model)) {
                return model_capabilities.mergeCapabilities(
                    fallback,
                    self.gateway_metadata,
                );
            }
        }
        return fallback;
    }

    fn isFileIndexLoading(_: *CoordinatorTestApp) bool {
        return false;
    }

    fn isFileIndexFailed(_: *CoordinatorTestApp) bool {
        return false;
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

fn initCoordinatorProjectionTestApp(
    alloc: std.mem.Allocator,
    file: std.Io.File,
) !CoordinatorTestApp {
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{
            .stdout_file = file,
            .layout = .{
                .rows = 12,
                .cols = 80,
                .content_bottom = 8,
                .divider_top_row = 9,
                .input_row = 10,
                .divider_bottom_row = 11,
                .hint_row = 12,
            },
            .owned_top_row = 1,
            .viewport_top_row = 1,
        },
        .terminal_client = .{
            .source_running = true,
        },
    };
    errdefer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    return app;
}

noinline fn readCoordinatorFrameBytes(alloc: std.mem.Allocator, file: std.Io.File, read_offset: *u64) ![]u8 {
    const total = try file.length(io_mod.getIo());
    const want: usize = @intCast(total - read_offset.*);
    const bytes = try alloc.alloc(u8, want);
    errdefer alloc.free(bytes);
    const n = try file.readPositionalAll(io_mod.getIo(), bytes, read_offset.*);
    try std.testing.expectEqual(want, n);
    read_offset.* += n;
    return bytes;
}

noinline fn coordinatorGridContains(grid: vt_emulator.Grid, needle: []const u8) !bool {
    var row: u16 = 1;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(grid.alloc);

    while (row <= grid.rows) : (row += 1) {
        buf.clearRetainingCapacity();
        try grid.rowTextTrimmed(row, &buf);
        if (std.mem.find(u8, buf.items, needle) != null) return true;
    }
    return false;
}

fn feedRewritePublicationFrame(
    alloc: std.mem.Allocator,
    physical: *vt_emulator.Grid,
    exported: *std.ArrayList(u8),
    bytes: []const u8,
) !void {
    var rows: std.ArrayList(u8) = .empty;
    defer rows.deinit(alloc);
    const starts = try alloc.alloc(usize, @as(usize, physical.rows) + 1);
    defer alloc.free(starts);
    for (bytes) |byte| {
        rows.clearRetainingCapacity();
        for (0..physical.rows) |index| {
            starts[index] = rows.items.len;
            try physical.rowTextTrimmed(@intCast(index + 1), &rows);
            try rows.append(alloc, '\n');
        }
        starts[physical.rows] = rows.items.len;
        const normal_buffer = physical.saved_normal_screen == null;
        var stats: vt_emulator.FeedStats = .{};
        try physical.feedWithStats(&.{byte}, &stats);
        if (normal_buffer and stats.scroll_rows > 0) {
            try exported.appendSlice(alloc, rows.items[0..starts[@min(stats.scroll_rows, physical.rows)]]);
            try exported.appendNTimes(alloc, '\n', stats.scroll_rows -| physical.rows);
        }
    }
}

fn publicationLineCount(text: []const u8, label: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (std.mem.eql(u8, std.mem.trim(u8, line, " \r"), label)) {
        count += 1;
    };
    return count;
}

fn rewritePublicationText(alloc: std.mem.Allocator, physical: *vt_emulator.Grid, exported: []const u8) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    try text.appendSlice(alloc, exported);
    for (0..physical.rows) |index| {
        try physical.rowTextTrimmed(@intCast(index + 1), &text);
        try text.append(alloc, '\n');
    }
    return text.toOwnedSlice(alloc);
}

fn flushRebasedPublicationFrame(app: *CoordinatorTestApp, file: std.Io.File, physical: *vt_emulator.Grid, history: *std.ArrayList(u8), offset: *u64) !u32 {
    const before = app.shell.transcriptCommitDiagnostic().history_visual_offset;
    const rows_before = std.mem.count(u8, history.items, "\n");
    app.shell.render_requests.request(.transcript);
    app.shell.render_requests.consecutive_input_pending_aborts = render_request.max_consecutive_input_pending_aborts;
    try Runtime(CoordinatorTestApp).flushRequestedFrame(app, agents.screenAgentOf(app));
    const bytes = try readCoordinatorFrameBytes(app.alloc, file, offset);
    defer app.alloc.free(bytes);
    try feedRewritePublicationFrame(app.alloc, physical, history, bytes);
    const accepted = app.shell.transcriptCommitDiagnostic().history_visual_offset - before;
    try std.testing.expectEqual(@as(usize, accepted), std.mem.count(u8, history.items, "\n") - rows_before);
    return accepted;
}

fn checkRebasedNoticePublication(cols: u16, rows: u16) !void {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "notice-publication.log", .{ .read = true });
    defer file.close(std.testing.io);
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{ .stdout_file = file, .layout = .{ .cols = cols, .rows = rows, .content_bottom = rows - 4, .divider_top_row = rows - 3, .input_row = rows - 2, .divider_bottom_row = rows - 1, .hint_row = rows } },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    var physical = try vt_emulator.Grid.init(alloc, cols, rows);
    defer physical.deinit();
    physical.defer_sync_updates = false;
    var history: std.ArrayList(u8) = .empty;
    defer history.deinit(alloc);
    var offset: u64 = 0;
    if (cols == 24) try app.input_runtime.textReplacementState().replace(alloc, "draft one\ndraft two\ndraft three\ndraft four");
    for (0..4) |index| {
        var line: [48]u8 = undefined;
        _ = try app.shell.appendRawTranscriptEntry(alloc, try std.mem.print(&line, "NOTICE_HISTORY_{d:0>2}\n", .{index}));
        _ = try flushRebasedPublicationFrame(&app, file, &physical, &history, &offset);
    }
    _ = try flushRebasedPublicationFrame(&app, file, &physical, &history, &offset);
    const notice_id = try app.shell.appendReplaceableSemanticNotice(alloc, .{
        .topic = "feedback",
        .tone = .neutral,
        .body = "Preparing feedback report while external work is blocking",
    });
    for (0..6) |index| {
        var line: [48]u8 = undefined;
        _ = try app.shell.appendRawTranscriptEntry(alloc, try std.mem.print(&line, "NOTICE_LATER_{d:0>2}\n", .{index}));
    }
    _ = try flushRebasedPublicationFrame(&app, file, &physical, &history, &offset);
    const held = app.shell.transcriptCommitDiagnostic().history_visual_offset;
    var pinned = try app.shell.prepareTranscriptSource(alloc, null);
    defer pinned.deinit(alloc);
    try std.testing.expect(pinned.finality.mutation_pin_start != null);
    const blocked_history = try alloc.dupe(u8, history.items);
    defer alloc.free(blocked_history);
    for (0..3) |_| {
        try std.testing.expectEqual(@as(u32, 0), try flushRebasedPublicationFrame(&app, file, &physical, &history, &offset));
        try std.testing.expectEqual(held, app.shell.transcriptCommitDiagnostic().history_visual_offset);
        try std.testing.expectEqualStrings(blocked_history, history.items);
        try std.testing.expect(std.mem.find(u8, history.items, "Preparing") == null);
        try std.testing.expect(std.mem.find(u8, history.items, "NOTICE_LATER_") == null);
    }
    const before_replacement = try file.length(std.testing.io);
    try std.testing.expect(try app.shell.replaceSemanticNotice(alloc, notice_id, .{
        .topic = "feedback",
        .tone = .success,
        .body = "Feedback report ready",
    }));
    try std.testing.expectEqual(before_replacement, try file.length(std.testing.io));
    try std.testing.expectEqualStrings(blocked_history, history.items);
    var finished = try app.shell.prepareTranscriptSource(alloc, null);
    defer finished.deinit(alloc);
    try std.testing.expect(finished.finality.mutation_pin_start == null);
    var released: u32 = 0;
    for (0..4) |_| released += try flushRebasedPublicationFrame(&app, file, &physical, &history, &offset);
    try std.testing.expect(released > 0);
    const text = try rewritePublicationText(alloc, &physical, history.items);
    defer alloc.free(text);
    var previous: usize = 0;
    for (0..10) |index| {
        var label_buffer: [48]u8 = undefined;
        const label = try std.mem.print(&label_buffer, "NOTICE_{s}_{d:0>2}", .{ if (index < 4) "HISTORY" else "LATER", if (index < 4) index else index - 4 });
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, label));
        const at = std.mem.find(u8, text, label).?;
        try std.testing.expect(at >= previous);
        previous = at + label.len;
    }
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "Feedback"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "report ready"));
    try std.testing.expect(std.mem.find(u8, text, "Preparing") == null);
    try std.testing.expectEqual(@as(u32, 0), try flushRebasedPublicationFrame(&app, file, &physical, &history, &offset));
    const quiet = try rewritePublicationText(alloc, &physical, history.items);
    defer alloc.free(quiet);
    try std.testing.expectEqualStrings(text, quiet);
}

const RewritePublicationCase = enum { command_retention, status_retention, status_shrink, removed_conversation };

const PublicationRetry = struct {
    accepted_bytes: ?usize = null,
    mutate_before_frame: bool = false,
    mutate_before_retry: bool = false,
    resize_cols: ?u16 = null,
    drain: bool = false,
    drain_frames: usize = 24,
    update_status: bool = false,
    invalidate: bool = false,
    cancel: bool = false,
    viewer: bool = false,
    utf8: bool = false,
    reset: enum { none, clear, session_resume } = .none,
};

const PublicationFaultSink = struct {
    file: std.Io.File,
    remaining: usize,
    calls: usize = 0,
    failed: bool = false,
    fn write(ctx: *anyopaque, _: *types.Metrics, bytes: []const u8) render_engine.terminal_diff.FrameSinkWriteResult {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const count = if (self.failed) bytes.len else @min(self.remaining, bytes.len);
        var written: usize = 0;
        while (written < count) {
            const n = self.file.writeStreaming(std.testing.io, &.{}, &.{bytes[written..count]}, 1) catch return .{ .partial = .{ .accepted_bytes = written, .err = error.WriteFailed } };
            if (n == 0) break;
            written += n;
        }
        if (!self.failed) self.remaining -= written;
        if (written == bytes.len) return .complete;
        self.failed = true;
        return .{ .partial = .{ .accepted_bytes = written, .err = error.WriteFailed } };
    }
};

fn checkRewritePublicationThroughCoordinator(case: RewritePublicationCase) !void {
    return checkRewritePublicationRetry(case, .{});
}

fn checkRewritePublicationRetry(case: RewritePublicationCase, retry: PublicationRetry) !void {
    const store = @import("../../ui/transcript/store.zig");
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "rewrite-publication.log", .{ .read = true });
    defer file.close(std.testing.io);
    const rows: u16 = if (retry.utf8) 18 else 16;
    var app = CoordinatorTestApp{
        .alloc = alloc,
        .shell = .{ .stdout_file = file, .layout = .{ .rows = rows, .cols = 80, .content_bottom = rows - 4, .divider_top_row = rows - 3, .input_row = rows - 2, .divider_bottom_row = rows - 1, .hint_row = rows } },
    };
    defer app.deinit();
    try app.selected_model.appendSlice(alloc, "test-model");
    try app.shell.initBacking(alloc);
    try app.shell.enableShadowVt(alloc);
    const prefix_id = try app.shell.appendRawTranscriptEntryClassified(alloc, text_utils.repeat("\x1b[0m", 256) ++ text_utils.repeat("prefix padding\n", 2), .subagent_status);
    const text = "1. earlier context\n2. earlier context\n3. earlier context\n4. earlier context\n5. RW_OLD_00\n6. RW_OLD_01\n7. RW_OLD_02\n8. RW_OLD_03\n9. RW_OLD_04\n10. RW_OLD_05\n\n";
    const assistant_id = try app.shell.streamAssistantChunk(alloc, &app.metrics, if (retry.utf8) text ++ text_utils.repeat("界é", 48) ++ "\n\nRW_ARTIFACTS\n" else text ++ "RW_ARTIFACTS\n");
    const status_id = if (retry.cancel) blk: {
        const id: types.ToolLifecycleId = .{ .turn_id = 41, .call_id = "publication-cancel" };
        _ = try app.shell.applyToolLifecycle(alloc, .{ .authoritative_started = .{ .id = id, .reconciles_provisional_call_id = null, .tool_name = "run_command", .activity_kind = .command } });
        break :blk app.shell.toolActivityRecord(id).?.entry_id;
    } else try store.appendPinnedToolStatusAtomic(&app.shell, alloc, "phase one\nphase two\nphase three\n");
    var physical = try vt_emulator.Grid.init(alloc, 80, rows);
    defer physical.deinit();
    physical.defer_sync_updates = false;
    var exported: std.ArrayList(u8) = .empty;
    defer exported.deinit(alloc);
    var read_offset: u64 = 0;
    app.shell.render_requests.consecutive_input_pending_aborts = render_request.max_consecutive_input_pending_aborts;
    app.shell.render_requests.request(.first_frame);
    try Runtime(CoordinatorTestApp).flushRequestedFrame(&app, (&app).agent());
    const first = try readCoordinatorFrameBytes(alloc, file, &read_offset);
    defer alloc.free(first);
    try feedRewritePublicationFrame(alloc, &physical, &exported, first);
    var initial_screen: std.ArrayList(u8) = .empty;
    defer initial_screen.deinit(alloc);
    try physical.snapshot(&initial_screen);
    for (0..6) |index| {
        var label_buffer: [32]u8 = undefined;
        const label = try std.mem.print(&label_buffer, "RW_OLD_{d:0>2}", .{index});
        const initial_count = std.mem.count(u8, exported.items, label) + std.mem.count(u8, initial_screen.items, label);
        if (initial_count != 1) std.debug.print("initial {s} {s} count={d}\nexported:\n{s}\nscreen:\n{s}\n", .{ @tagName(case), label, initial_count, exported.items, initial_screen.items });
        try std.testing.expectEqual(@as(usize, 1), initial_count);
    }
    const before_text = try rewritePublicationText(alloc, &physical, exported.items);
    defer alloc.free(before_text);
    const before_gap_start = std.mem.find(u8, before_text, "RW_OLD_05").? + "RW_OLD_05".len;
    const gap_anchor = if (retry.utf8) "界" else "RW_ARTIFACTS";
    if (retry.utf8) {
        try std.testing.expectEqual(@as(usize, 48), std.mem.count(u8, before_text, "界"));
        try std.testing.expectEqual(@as(usize, 48), std.mem.count(u8, before_text, "é"));
        var wrapped_rows: usize = 0;
        var lines = std.mem.splitScalar(u8, before_text, '\n');
        while (lines.next()) |line| if (std.mem.find(u8, line, "界") != null) {
            wrapped_rows += 1;
        };
        try std.testing.expect(wrapped_rows > 1);
    }
    const before_gap_end = std.mem.find(u8, before_text, gap_anchor).?;
    const before_gap = before_text[before_gap_start..before_gap_end];
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, before_gap, "\n"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, exported.items, "RW_OLD_00"));
    try std.testing.expectEqual(.stable, app.shell.transcriptCommitDiagnostic().state);
    try std.testing.expect(app.shell.transcriptCommitDiagnostic().history_visual_offset > 0);
    if (retry.viewer) {
        try std.testing.expectEqual(@as(usize, 0), app.shell.committedRetentionIdentity().?.publication_entries.len);
        try app_lifecycle.openFullTranscript(alloc, &app.terminal, &app.shell, &app.metrics);
        app.shell.render_requests.consecutive_input_pending_aborts = render_request.max_consecutive_input_pending_aborts;
        try Runtime(CoordinatorTestApp).flushRequestedFrame(&app, (&app).agent());
        const opened = try readCoordinatorFrameBytes(alloc, file, &read_offset);
        defer alloc.free(opened);
        try feedRewritePublicationFrame(alloc, &physical, &exported, opened);
        try std.testing.expect(app.terminal.fullTranscriptScreenActive());
        try std.testing.expect(physical.saved_normal_screen != null);
    }
    switch (case) {
        .command_retention => try app.shell.writeCommandOutputChunk(alloc, &app.metrics, .{}, .stdout, "NEW_COMMAND_OUTPUT\n", true),
        .status_retention => try std.testing.expect(try store.replacePinnedToolStatusAtomic(&app.shell, alloc, status_id, "phase replacement\nsecond phase\nthird phase\nfourth phase\nfifth phase\n")),
        .status_shrink => try std.testing.expect(try store.replacePinnedToolStatusAtomic(&app.shell, alloc, status_id, "ok\n")),
        .removed_conversation => if (retry.viewer) {
            try std.testing.expect(try store.replacePinnedToolStatusAtomic(&app.shell, alloc, status_id, "viewer status replacement\n"));
        } else {
            _ = try store.writeRecordedTranscriptClassifiedAtomic(&app.shell, alloc, &app.metrics, "NEW_NOTICE\n", .unknown_raw);
        },
    }
    // The transcript window drops the closed cycle after the rewrite: the
    // prefix, and for a removed conversation the answer too. The pinned
    // status always stays.
    switch (case) {
        .status_shrink => {},
        .command_retention, .status_retention => try std.testing.expect(try store.dropEntriesAtomic(&app.shell, alloc, &.{prefix_id})),
        .removed_conversation => try std.testing.expect(try store.dropEntriesAtomic(&app.shell, alloc, &.{ prefix_id, assistant_id })),
    }
    const prefix_survives = for (app.shell.notebook.entries.items) |entry| {
        if (entry.id() == prefix_id) break true;
    } else false;
    try std.testing.expectEqual(case == .status_shrink, prefix_survives);
    try std.testing.expectEqual(case != .removed_conversation, app.shell.lookupAssistantSegments(assistant_id) != null);
    if (case == .status_retention) {
        app.agent().stream.active = true;
        app.agent().stream.phase = .running;
    }
    if (retry.viewer) {
        try std.testing.expect(app.terminal.fullTranscriptScreenActive());
        try std.testing.expect(std.mem.findScalar(u32, app.shell.committedRetentionIdentity().?.publication_entries, assistant_id) != null);
        if (retry.resize_cols) |cols| {
            try physical.resize(cols, physical.rows);
            app.shell.layout.cols = cols;
            app.shell.render_requests.request(.resize);
            app.shell.render_requests.consecutive_input_pending_aborts = render_request.max_consecutive_input_pending_aborts;
            try Runtime(CoordinatorTestApp).flushRequestedFrame(&app, (&app).agent());
        }
        try app_lifecycle.closeFullTranscript(alloc, &app.terminal, &app.shell, &app.metrics);
        const closed = try readCoordinatorFrameBytes(alloc, file, &read_offset);
        defer alloc.free(closed);
        try feedRewritePublicationFrame(alloc, &physical, &exported, closed);
        try std.testing.expect(physical.saved_normal_screen == null);
    }
    if (retry.invalidate) {
        app.shell.invalidateTranscriptAnchor("external_projection_damage");
        try std.testing.expect(app.shell.committedRetentionIdentity().?.publication_entries.len > 0);
        try app.shell.recordFrameInvalidation(.{ .reason = .external_clear, .top = app.shell.owned_top_row, .bottom = app.shell.layout.content_bottom });
        try physical.feed("\x1b[2J");
    }
    if (retry.reset != .none) {
        try std.testing.expect(app.shell.committedRetentionIdentity().?.publication_entries.len > 0);
        if (retry.reset == .clear) {
            app.shell.clearTranscript(alloc);
            try app.shell.writeTranscript(alloc, &app.metrics, "RESET_SENTINEL\n", true);
        } else {
            var projection = try resume_projection.ResumeProjection.initEmpty(alloc, &app.shell, 0, 1);
            defer projection.deinit();
            _ = try projection.appendRawClassified("RESET_SENTINEL\n", .unknown_raw);
            try projection.finalize();
            projection.install(&app.shell);
        }
        try std.testing.expect(app.shell.committedRetentionIdentity() == null);
        app.shell.render_requests.consecutive_input_pending_aborts = render_request.max_consecutive_input_pending_aborts;
        try Runtime(CoordinatorTestApp).flushRequestedFrame(&app, (&app).agent());
        const frame = try readCoordinatorFrameBytes(alloc, file, &read_offset);
        defer alloc.free(frame);
        try feedRewritePublicationFrame(alloc, &physical, &exported, frame);
        try std.testing.expect(try coordinatorGridContains(physical, "RESET_SENTINEL"));
        try std.testing.expect(!try coordinatorGridContains(physical, "RW_OLD_00"));
        return;
    }
    if (retry.update_status) {
        try std.testing.expect(try store.replacePinnedToolStatusAtomic(&app.shell, alloc, status_id, "phase new\nphase two\nphase end\n"));
        try std.testing.expectEqualStrings("phase new\nphase two\nphase end", store.toolStatusEntryLabel(&app.shell, status_id).?);
        try std.testing.expect(std.mem.findScalar(u32, app.shell.committedRetentionIdentity().?.publication_entries, status_id) == null);
    }
    if (retry.mutate_before_frame) {
        const held_bytes = app.shell.transcriptCommitDiagnostic().source_bytes;
        for (0..32) |_| {
            _ = try store.writeRecordedTranscriptClassifiedAtomic(&app.shell, alloc, &app.metrics, "P2\n", .unknown_raw);
            var committed = (try app.shell.prepareCommittedRetentionSource(alloc)).?;
            defer committed.deinit(alloc);
            try std.testing.expect(std.mem.find(u8, committed.bytes, "P2") == null);
            try std.testing.expectEqual(held_bytes, committed.bytes.len);
        }
    }
    if (retry.accepted_bytes) |cut| {
        const before_attempt = app.shell.transcriptCommitDiagnostic();
        const exported_before_attempt = exported.items.len;
        var sink = PublicationFaultSink{ .file = file, .remaining = cut };
        app.shell.test_frame_sink = .{ .ctx = &sink, .write_frame = PublicationFaultSink.write };
        app.shell.render_requests.consecutive_input_pending_aborts = render_request.max_consecutive_input_pending_aborts;
        Runtime(CoordinatorTestApp).flushRequestedFrame(&app, (&app).agent()) catch |err| {
            if (err != error.WriteFailed and err != error.DocumentAppendInterrupted) return err;
        };
        app.shell.test_frame_sink = null;
        try std.testing.expect(sink.calls > 0 and sink.failed);
        const partial = try readCoordinatorFrameBytes(alloc, file, &read_offset);
        defer alloc.free(partial);
        try feedRewritePublicationFrame(alloc, &physical, &exported, partial);
        if (cut == 0) try std.testing.expectEqual(before_attempt.history_visual_offset, app.shell.transcriptCommitDiagnostic().history_visual_offset);
        if (cut >= 64) {
            try std.testing.expect(app.shell.transcriptCommitDiagnostic().history_visual_offset > before_attempt.history_visual_offset);
            try std.testing.expect(exported.items.len > exported_before_attempt);
        }
        if (retry.cancel) {
            app.agent().worker.cancel_requested = true;
            app.agent().stream.active = false;
            _ = try app.shell.applyToolLifecycle(alloc, .{ .turn_finished = .{ .turn_id = 41, .outcome = .interrupted } });
            try std.testing.expectEqual(.terminal, app.shell.toolActivityRecord(.{ .turn_id = 41, .call_id = "publication-cancel" }).?.phase);
            try app.shell.finishLifecycleBatch(alloc);
            try std.testing.expectEqual(@as(usize, 0), app.shell.lifecyclePinCount());
        }
        if (retry.mutate_before_retry) _ = try store.writeRecordedTranscriptClassifiedAtomic(&app.shell, alloc, &app.metrics, "P3\n", .unknown_raw);
    }
    if (retry.resize_cols) |cols| {
        try physical.resize(cols, physical.rows);
        app.shell.layout.cols = cols;
        app.shell.render_requests.request(.resize);
    }
    for (0..8) |_| {
        app.shell.render_requests.consecutive_input_pending_aborts = render_request.max_consecutive_input_pending_aborts;
        try Runtime(CoordinatorTestApp).flushRequestedFrame(&app, (&app).agent());
        const next = try readCoordinatorFrameBytes(alloc, file, &read_offset);
        defer alloc.free(next);
        try feedRewritePublicationFrame(alloc, &physical, &exported, next);
        if (app.shell.transcript_commit_state == .stable and
            !app.shell.transcript_commit_state.stable.normal_buffer_recovery_pending and
            !app.shell.transcript_commit_state.stable.history_catchup_pending) break;
    }
    if (retry.drain) {
        const seen = try alloc.alloc(bool, retry.drain_frames);
        defer alloc.free(seen);
        @memset(seen, false);
        for (0..retry.drain_frames) |index| {
            var buffer: [32]u8 = undefined;
            const line = try std.mem.print(&buffer, "N{d}\n", .{index});
            _ = try store.writeRecordedTranscriptClassifiedAtomic(&app.shell, alloc, &app.metrics, line, .unknown_raw);
            app.shell.render_requests.consecutive_input_pending_aborts = render_request.max_consecutive_input_pending_aborts;
            try Runtime(CoordinatorTestApp).flushRequestedFrame(&app, (&app).agent());
            const next = try readCoordinatorFrameBytes(alloc, file, &read_offset);
            defer alloc.free(next);
            try feedRewritePublicationFrame(alloc, &physical, &exported, next);
            const visible = try rewritePublicationText(alloc, &physical, exported.items);
            defer alloc.free(visible);
            for (0..index + 1) |prior| {
                var label_buffer: [32]u8 = undefined;
                const label = try std.mem.print(&label_buffer, "N{d}", .{prior});
                const count = publicationLineCount(visible, label);
                if (seen[prior] or count > 0) {
                    try std.testing.expectEqual(@as(usize, 1), count);
                    seen[prior] = true;
                }
            }
            // Below a status that stays pinned, rows past the screen wait for
            // the pin to end (the in-place region, as on main), so stop once
            // the dropped rows are out and released. A finished turn drains on.
            if (!retry.cancel and std.mem.findScalar(u32, app.shell.committedRetentionIdentity().?.publication_entries, assistant_id) == null) break;
        }
        try std.testing.expect(std.mem.findScalar(bool, seen, true) != null);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, exported.items, "RW_ARTIFACTS"));
        try std.testing.expect(std.mem.find(u8, exported.items, "phase one") == null);
        try std.testing.expect(std.mem.findScalar(u32, app.shell.committedRetentionIdentity().?.publication_entries, assistant_id) == null);
    }
    var screen: std.ArrayList(u8) = .empty;
    defer screen.deinit(alloc);
    try physical.snapshot(&screen);
    for (0..6) |index| {
        var label_buffer: [32]u8 = undefined;
        const label = try std.mem.print(&label_buffer, "RW_OLD_{d:0>2}", .{index});
        const count = std.mem.count(u8, exported.items, label) + std.mem.count(u8, screen.items, label);
        if (count != 1) std.debug.print("rewrite publication {s}: {s} count={d} cut={?d} resize={?d}\nexported:\n{s}\nscreen:\n{s}\n", .{ @tagName(case), label, count, retry.accepted_bytes, retry.resize_cols, exported.items, screen.items });
        try std.testing.expectEqual(@as(usize, 1), count);
    }
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, exported.items, "RW_ARTIFACTS") + std.mem.count(u8, screen.items, "RW_ARTIFACTS"));
    const after_text = try rewritePublicationText(alloc, &physical, exported.items);
    defer alloc.free(after_text);
    const after_gap_start = std.mem.find(u8, after_text, "RW_OLD_05").? + "RW_OLD_05".len;
    const after_gap_end = std.mem.find(u8, after_text, gap_anchor).?;
    try std.testing.expectEqualStrings(before_gap, after_text[after_gap_start..after_gap_end]);
    if (retry.utf8) {
        try std.testing.expectEqual(@as(usize, 48), std.mem.count(u8, after_text, "界"));
        try std.testing.expectEqual(@as(usize, 48), std.mem.count(u8, after_text, "é"));
        const before_end = std.mem.findLast(u8, before_text, "é").? + "é".len;
        const after_end = std.mem.findLast(u8, after_text, "é").? + "é".len;
        try std.testing.expectEqualStrings(before_text[before_end..std.mem.find(u8, before_text, "RW_ARTIFACTS").?], after_text[after_end..std.mem.find(u8, after_text, "RW_ARTIFACTS").?]);
    }
}

fn coordinatorRowHasText(grid: vt_emulator.Grid, row: u16) !bool {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(grid.alloc);
    try grid.rowTextTrimmed(row, &buf);
    return std.mem.trim(u8, buf.items, " \t\r\n").len > 0;
}
