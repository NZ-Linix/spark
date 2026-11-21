const std = @import("std");
const session_notices = @import("../session/session.zig");
const agents = @import("../agents/agents.zig");
const credentials = @import("../auth/credentials.zig");
const activity_status = @import("../output/activity_status.zig");
const compaction_activity = @import("../output/compaction_activity.zig");
const turn_clock = @import("../output/turn_clock.zig");
const convo = @import("../session/convo.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const app_agents_runtime = @import("app_agents_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const shared_theme = @import("../shared/theme.zig");
const types = @import("../shared/types.zig");
const full_transcript_metadata = @import("../output/full_transcript_metadata.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const assistant_presentation = @import("../agent/assistant_presentation.zig");
const assistant_pacer = @import("../../ui/assistant/pacer.zig");
const ui_render = @import("../../ui/render.zig");
const activity_runtime = @import("../output/activity_runtime.zig");
const worker_status = @import("../output/worker_status.zig");
const core_input_runtime = @import("../input/runtime.zig");
const render_input = @import("../../ui/footer/render_input.zig");
const render_request = @import("../../ui/render_request.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");
const program_status = @import("../../ui/terminal/program_status.zig");

const WorkerEvent = worker_runtime.WorkerEvent;
const HeadSegmentScan = worker_runtime.HeadSegmentScan;

/// How long one interactive drain applies worker events before it lets the
/// loop read keys and paint. Late in a long session an event costs several
/// milliseconds, and hundreds can be queued at once. Every slice costs a
/// frame, so a shorter budget makes the whole turn slower.
pub const interactive_drain_budget_ns: i128 = 32 * std.time.ns_per_ms;
const InputRuntime = core_input_runtime.Runtime;

const CancelledEventAdmission = enum {
    admit,
    drop,
    defer_until_closure,
};

const reset_style = ui_render.reset_style;

test {
    _ = activity_runtime;
}

fn discardTable(_: *anyopaque, table: assistant_presentation.TablePayload) !void {
    var owned = table;
    owned.deinit(std.heap.c_allocator);
}

fn discardCodeBlock(_: *anyopaque, block: assistant_presentation.CodeBlockPayload) !void {
    var owned = block;
    owned.deinit(std.heap.c_allocator);
}

fn discardThematicRule(_: *anyopaque) !void {}
fn discardContextCompaction(_: *anyopaque, _: worker_runtime.ContextCompaction) !void {}
fn discardCredentialRefresh(_: *anyopaque, _: credentials.Credential) !void {}
fn holdNoModelCall(_: *anyopaque, _: types.ModelCallRecord) !bool {
    return false;
}

/// A retained delivery owns its own payload; a settled delivery acknowledges history.
pub const HistoryDelivery = union(enum) {
    retained,
    settled: assistant_pacer.FinishResult,
};

pub const WorkerEventHandlers = struct {
    ctx: *anyopaque,
    tool_lifecycle: activity_runtime.LifecyclePresenter,
    write_user_prompt: *const fn (*anyopaque, types.UserTurn) anyerror!void,
    write_user_prompt_with_skill_bindings: ?*const fn (*anyopaque, types.UserTurn, []const worker_runtime.SkillBinding, []const worker_runtime.SkillDisplaySpan) anyerror!void = null,
    append_text: *const fn (*anyopaque, []const u8) anyerror!void,
    append_table: *const fn (*anyopaque, assistant_presentation.TablePayload) anyerror!void = discardTable,
    append_code_block: *const fn (*anyopaque, assistant_presentation.CodeBlockPayload) anyerror!void = discardCodeBlock,
    append_thematic_rule: *const fn (*anyopaque) anyerror!void = discardThematicRule,
    drain_assistant_text: *const fn (*anyopaque) anyerror!AssistantTextDrainResult,
    /// Holds a call's Ctrl+O line until the paced text before it is shown;
    /// false when nothing is pending and the line is written now.
    hold_model_call: *const fn (*anyopaque, types.ModelCallRecord) anyerror!bool = holdNoModelCall,
    open_model_picker: *const fn (*anyopaque) anyerror!void,
    semantic_notice: *const fn (*anyopaque, types.SemanticNotice) anyerror!void,
    credential_refreshed: *const fn (*anyopaque, credentials.Credential) anyerror!void = discardCredentialRefresh,
    command_output: *const fn (*anyopaque, ?types.ToolLifecycleId, command_output_content.Stream, []const u8) anyerror!void,
    command_output_complete: *const fn (*anyopaque, ?types.ToolLifecycleId) anyerror!void,
    diff_block: *const fn (*anyopaque, diff_mod.DiffEntryPayload) anyerror!void,
    context_compaction: worker_runtime.ContextCompactionHandler = discardContextCompaction,
    append_history_turn: *const fn (*anyopaque, types.FinishedPrompt) anyerror!HistoryDelivery,
    error_text: *const fn (*anyopaque, types.SemanticNotice) anyerror!void,
};

pub const AssistantTextDrainResult = enum {
    drained,
    blocked,
};

/// Writes the full-only notice for a terminal route recovery outcome, which
/// keeps the failure in Ctrl+O where it happened. The recovery module's
/// statuses live only in the status row and refresh every second, so they
/// are never recorded.
fn recordRouteRecoveryNotice(app: anytype, status: types.RouteRecoveryStatus) !void {
    if (status.fromModule() or status.kind == .recovered or status.kind == .failed) return;
    var body: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer body.deinit();
    try writeRouteRecoveryBody(&body.writer, status);
    try app.writeDomainNotice(.{
        .topic = "recovery",
        .tone = routeRecoveryNoticeTone(status),
        .body = body.written(),
        .visibility = .full_only,
    }, true);
}

/// One settled model call as the full-only notice Ctrl+O shows where it
/// happened; a failed call shows as an error.
pub fn writeModelCallNotice(
    ctx: *anyopaque,
    write: *const fn (*anyopaque, types.SemanticNotice) anyerror!void,
    record: types.ModelCallRecord,
) !void {
    var body: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer body.deinit();
    try full_transcript_metadata.writeModelCallText(&body.writer, record);
    try write(ctx, .{
        .topic = full_transcript_metadata.model_call_topic,
        .tone = if (record.outcome == .failed) .@"error" else .neutral,
        .body = body.written(),
        .visibility = .full_only,
    });
}

fn routeRecoveryNoticeTone(status: types.RouteRecoveryStatus) types.NoticeTone {
    return switch (status.tone()) {
        .live => .neutral,
        .warning => .warning,
        .success => .success,
        .danger => .@"error",
    };
}

/// Pure formatter for the recovery record body: footer label, then the
/// structured facts the label cannot carry.
fn writeRouteRecoveryBody(
    writer: *std.Io.Writer,
    status: types.RouteRecoveryStatus,
) !void {
    var label_buf: [types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
    try writer.writeAll(status.label(&label_buf));
    try writer.print("\nkind: {s}", .{@tagName(status.kind)});
    if (status.cause) |cause| try writer.print(" · cause: {s}", .{@tagName(cause)});
    if (status.attempt > 0) try writer.print(" · attempt: {d}", .{status.attempt});
    if (status.diagnostic) |diagnostic| {
        try writer.print(" · diagnostic: {s}", .{diagnostic.view()});
    }
}

test "shutdown settles queued and pacer-owned finishes exactly once" {
    const session_runtime = @import("../session/session.zig");
    const session_adapter = @import("../session/session_adapter.zig");
    const ShutdownApp = struct {
        alloc: std.mem.Allocator,
        pacer: assistant_pacer.AssistantPacer = .{},
        main_agent: struct {
            total_input_tokens: u64 = 7,
            total_output_tokens: u64 = 11,
            session: session_runtime.SessionRuntime = .{ .max_history_turns = 8 },
            session_persistence: app_session_runtime.Persistence = .{},
            worker: worker_runtime.WorkerRuntime = .{},
        } = .{},

        pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
            return &self.main_agent;
        }
    };
    const Ownership = struct {
        references: usize = 0,
        transfers: usize = 0,

        fn retain(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.references += 1;
        }
        fn release(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.references -= 1;
        }
        fn transfer(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.transfers += 1;
        }
        fn handle(self: *@This()) types.SnapshotFileOwnership {
            return .{ .ctx = self, .retain_fn = retain, .release_fn = release, .transfer_fn = transfer };
        }
    };
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |pacer_owned| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        defer alloc.free(root);
        var app: ShutdownApp = .{ .alloc = alloc };
        defer app.agent().session.deinit(alloc);
        defer app.agent().session_persistence.deinit(alloc);
        defer app.agent().worker.deinit(std.heap.c_allocator);
        defer app.pacer.deinit(alloc);
        _ = try app.agent().session_persistence.adoptStore(alloc, try session_adapter.Store.open(alloc, root));
        var model = "test-model".*;
        app.agent().session_persistence.v2 = try session_adapter.Session.create(alloc, app.agent().session_persistence.v2_store.?, root, .app, .{
            .preferences = .{ .model = &model, .effort = .auto, .fast_mode = false },
            .language = .literal("en"),
        });

        var ownership: Ownership = .{};
        const summary: types.TurnSummary = .{ .token_progress = .{ .input_tokens = 7, .output_tokens = 11 } };
        const finished: types.FinishedPrompt = .{
            .turn = .{ .interrupted = .{
                .user = .{ .text = @constCast("cancel this response") },
                .assistant = @constCast("partial response"),
                .terminal_reason = .failed,
            } },
            .summary = summary,
            .terminal_outcome = .interrupted,
            .snapshot_file_ownership = ownership.handle(),
        };
        if (pacer_owned) {
            try app.pacer.enqueue(alloc, "unrendered tail");
            try std.testing.expect(try app.pacer.deferFinish(alloc, finished));
        } else {
            try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .finish_prompt = finished });
        }
        // A later queued finish must follow the pacer-owned turn. Neither a
        // begin nor a presentation event may invoke UI or admit another prompt.
        try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .begin_prompt = .{ .text = @constCast("later prompt") } });
        try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .assistant_presentation = .{ .text = @constCast("do not render") } });
        try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .finish_prompt = .{ .turn = .{ .assistant = .{
            .user = .{ .text = @constCast("later prompt") },
            .assistant = @constCast("later answer"),
        } } } });
        app.agent().worker.requestShutdown();
        app_session_runtime.Runtime(ShutdownApp).recordShutdownFailure((&app).agent(), error.PreviousSessionSaveFailed);
        try std.testing.expectEqual(@as(usize, 0), app.agent().session.historyLen());

        try Runtime(ShutdownApp).settleFinishedPromptsForShutdown(&app, (&app).agent());
        try Runtime(ShutdownApp).settleFinishedPromptsForShutdown(&app, (&app).agent());
        try std.testing.expectEqual(@as(usize, 2), app.agent().session.historyLen());
        try std.testing.expectEqual(@as(usize, 1), ownership.transfers);
        try std.testing.expectEqual(@as(usize, 0), ownership.references);
        try std.testing.expectEqual(@as(usize, 0), app.agent().worker.worker_events.items.len);
        try std.testing.expect(app.pacer.deferred_turn == null);
        // Close the session before reloading so only what it saved can pass.
        const id = try alloc.dupe(u8, app.agent().session_persistence.v2.?.id());
        defer alloc.free(id);
        app.agent().session_persistence.v2.?.close();
        app.agent().session_persistence.v2 = null;
        const resumed = try session_adapter.Session.resumeSession(alloc, app.agent().session_persistence.v2_store.?, .{ .id = id }, root, .app);
        defer resumed.close();
        var loaded = try resumed.restore(alloc);
        defer loaded.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 2), loaded.history.len);
        try std.testing.expectEqualStrings("partial response", loaded.history[0].interrupted.assistant.?);
        try std.testing.expectEqualDeep(summary, types.historyTurnSummary(loaded.history[0]).?);
        try std.testing.expectEqualStrings("later answer", loaded.history[1].assistant.assistant);
    }
}

const DetachedWorkerEventBatch = struct {
    alloc: std.mem.Allocator,
    events: std.ArrayList(WorkerEvent),
    next_unvisited: usize = 0,

    fn init(
        alloc: std.mem.Allocator,
        events: std.ArrayList(WorkerEvent),
    ) DetachedWorkerEventBatch {
        return .{
            .alloc = alloc,
            .events = events,
        };
    }

    fn claim(self: *DetachedWorkerEventBatch) ?WorkerEvent {
        if (self.next_unvisited >= self.events.items.len) return null;
        const event = self.events.items[self.next_unvisited];
        self.next_unvisited += 1;
        return event;
    }

    fn claimedAndRemaining(self: *const DetachedWorkerEventBatch) []const WorkerEvent {
        std.debug.assert(self.next_unvisited > 0);
        return self.events.items[self.next_unvisited - 1 ..];
    }

    fn markClaimedAndRemainingTransferred(self: *DetachedWorkerEventBatch) void {
        self.next_unvisited = self.events.items.len;
    }

    fn deinit(self: *DetachedWorkerEventBatch) void {
        while (self.next_unvisited < self.events.items.len) : (self.next_unvisited += 1) {
            debug_trace.logf("worker", "undelivered worker event discarded kind={s}", .{@tagName(self.events.items[self.next_unvisited])});
            worker_runtime.freeWorkerEvent(self.alloc, self.events.items[self.next_unvisited]);
        }
        self.events.deinit(self.alloc);
        self.* = undefined;
    }
};

fn batchContainsTerminalClosure(
    events: []const WorkerEvent,
    id: types.ToolLifecycleId,
) bool {
    for (events) |event| {
        const lifecycle = switch (event) {
            .tool_lifecycle => |value| value,
            else => continue,
        };
        switch (lifecycle) {
            .terminal => |terminal| {
                if (terminal.id.turn_id == id.turn_id and
                    std.mem.eql(u8, terminal.id.call_id, id.call_id)) return true;
            },
            .turn_finished => |finished| {
                if (finished.turn_id == id.turn_id) return true;
            },
            .provisional, .authoritative_started, .progress => {},
        }
    }
    return false;
}

fn batchSegmentIsInterrupted(events: []const WorkerEvent, cancelled_turn_id: ?u64) bool {
    return segmentInterrupted(scanSegment(.fresh, events), cancelled_turn_id);
}

/// Whether `event` begins a new prompt, and so a new segment.
fn startsSegment(event: WorkerEvent) bool {
    return switch (event) {
        .begin_prompt, .begin_prompt_with_skill_bindings, .begin_presented_prompt, .begin_resumed_prompt => true,
        else => false,
    };
}

/// Whether a time-bounded drain has passed its deadline; never for an
/// unbounded one.
fn budgetSpent(deadline_ns: ?i128) bool {
    const deadline = deadline_ns orelse return false;
    return io_mod.nanoTimestamp() >= deadline;
}

/// Continues `state` over `events`, which carry on the segment `state`
/// describes, stopping where the next prompt begins.
fn scanSegment(state: HeadSegmentScan, events: []const WorkerEvent) HeadSegmentScan {
    var scan = state;
    for (events, 0..) |event, index| {
        if (index > 0 and startsSegment(event)) break;
        scan = scanSegmentEvent(scan, event);
        if (scan == .settled) break;
    }
    return scan;
}

fn scanSegmentEvent(state: HeadSegmentScan, event: WorkerEvent) HeadSegmentScan {
    if (state == .settled) return state;
    return switch (event) {
        .begin_presented_prompt, .begin_resumed_prompt => |id| .{ .turn = id },
        .turn_phase_update => |phase| .{ .turn = phase.turn_id },
        .tool_lifecycle => |lifecycle| switch (lifecycle) {
            .turn_finished => |finished| .{ .settled = finished.outcome == .interrupted },
            .provisional => |value| .{ .turn = value.id.turn_id },
            .authoritative_started => |value| .{ .turn = value.id.turn_id },
            .progress => |value| .{ .turn = value.id.turn_id },
            .terminal => |value| .{ .turn = value.id.turn_id },
        },
        else => state,
    };
}

fn segmentInterrupted(state: HeadSegmentScan, cancelled_turn_id: ?u64) bool {
    return switch (state) {
        .settled => |interrupted| interrupted,
        .turn => |turn_id| {
            const cancelled = cancelled_turn_id orelse return false;
            return turn_id == null or turn_id.? == cancelled;
        },
    };
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        fn cancelledToolStartAdmission(
            presenter: activity_runtime.LifecyclePresenter,
            id: types.ToolLifecycleId,
            batch_events: []const WorkerEvent,
        ) CancelledEventAdmission {
            if (batchContainsTerminalClosure(batch_events, id)) return .admit;
            if (id.turn_id <= presenter.snapshot().finalized_turn_watermark) return .drop;
            return .defer_until_closure;
        }

        fn cancelledEventAdmission(
            presenter: activity_runtime.LifecyclePresenter,
            event: WorkerEvent,
            batch_events: []const WorkerEvent,
        ) CancelledEventAdmission {
            return switch (event) {
                .assistant_presentation,
                .open_model_picker,
                .semantic_notice,
                .command_output,
                .turn_token_update,
                .turn_phase_update,
                .diff_block,
                .restore_failed_prompt,
                => .drop,
                .route_recovery_status => .drop,
                // A stopped turn's calls still show where they happened.
                .model_call => .admit,
                .command_output_complete => |lifecycle_id| if (cancelledCommandCompletionMatches(presenter, lifecycle_id))
                    .admit
                else
                    .drop,
                .tool_lifecycle => |lifecycle| switch (lifecycle) {
                    .provisional => |started| cancelledToolStartAdmission(presenter, started.id, batch_events),
                    .authoritative_started => |started| cancelledToolStartAdmission(presenter, started.id, batch_events),
                    .progress => .drop,
                    .terminal => |terminal| if (presenter.record(terminal.id) == null)
                        .drop
                    else
                        .admit,
                    .turn_finished => .admit,
                },
                .begin_prompt,
                .begin_prompt_with_skill_bindings,
                .begin_presented_prompt,
                .begin_resumed_prompt,
                .append_user_feedback,
                .append_agent_message,
                .notification,
                .question_requested,
                .clear_route_recovery_status,
                .provider_resolved,
                .api_status_text,
                .reasoning_delta,
                .live_text,
                .context_compaction,
                .credential_refreshed,
                .finish_prompt,
                .error_text,
                => .admit,
            };
        }

        fn cancelledCommandCompletionMatches(
            presenter: activity_runtime.LifecyclePresenter,
            lifecycle_id: ?types.ToolLifecycleId,
        ) bool {
            const id = lifecycle_id orelse return false;
            const record = presenter.record(id) orelse return false;
            return record.phase == .terminal and record.activity_kind == .command;
        }

        /// After the worker joins, persist finished turns without presenting output
        /// or admitting work. The pacer owns the finish preceding queued events.
        pub fn settleFinishedPromptsForShutdown(app: *App, agent: *AppAgent) !void {
            try settleDeferredFinish(app, agent);

            var batch = DetachedWorkerEventBatch.init(
                std.heap.c_allocator,
                agent.worker.takeEvents(),
            );
            defer batch.deinit();
            while (batch.claim()) |event| {
                defer worker_runtime.freeWorkerEvent(batch.alloc, event);
                switch (event) {
                    .finish_prompt => |finished| try persistFinishedPrompt(app, agent, finished),
                    else => debug_trace.logf("worker", "shutdown worker event dropped kind={s}", .{@tagName(event)}),
                }
            }
        }

        fn persistFinishedPrompt(app: *App, agent: *AppAgent, finished: types.FinishedPrompt) !void {
            const appended = if (comptime agents.hasAgentField(App, "session"))
                app_session_runtime.Runtime(App).appendFinishedPrompt(app, agent, finished)
            else
                app.appendFinishedPrompt(finished);
            appended catch |err| {
                app_session_runtime.Runtime(App).recordShutdownFailure(agent, err);
                return err;
            };
            // `spark --convo FILE` writes the conversation back after each turn.
            if (comptime agents.hasAgentField(App, "session_persistence")) {
                if (agent.session_persistence.v2) |v2| convo.save(v2.id());
            }
        }

        fn settleDeferredFinish(app: *App, agent: *AppAgent) !void {
            if (comptime !@hasField(@TypeOf(app.pacer), "deferred_turn")) return;
            if (app.pacer.deferred_turn) |finished| {
                app.pacer.deferred_turn = null;
                app.pacer.deferred_started_ns = null;
                defer types.freeFinishedPrompt(app.alloc, finished);
                try persistFinishedPrompt(app, agent, finished);
            }
        }

        /// Tells `agent`'s worker that a finished turn it pushed is gone
        /// without a commit, so its commit gate stops waiting for it
        /// (`WorkerRuntime.acknowledgeFinishDropped`). Every place that frees
        /// a finished turn unsaved calls this or goes through `clearPacer` or
        /// `deferFinish`; a turn that is saved is acknowledged by
        /// `appendFinishedPrompt`.
        pub fn acknowledgeDroppedFinish(agent: *AppAgent, reason: []const u8) void {
            if (comptime @hasField(AppAgent, "worker") and
                @hasDecl(@TypeOf(agent.worker), "acknowledgeFinishDropped"))
            {
                agent.worker.acknowledgeFinishDropped(reason);
            }
        }

        fn pacerHoldsFinish(app: *App) bool {
            if (comptime !@hasField(@TypeOf(app.pacer), "deferred_turn")) return false;
            return app.pacer.deferred_turn != null;
        }

        /// Shows the finished turn that the pacer of `agent`, the agent in
        /// context, keeps behind an open prompt, and commits it, when the
        /// worker holds mail for that commit. The loop does not tick a pacer
        /// under a prompt, so the commit waits for the prompt to close; and
        /// the mail's turn, whose start flushes the pacer
        /// (`workerBridgeDrainAssistantText`), waits for the commit. Without
        /// this the worker's time limit is all that ends the hold, and the
        /// mail's turn then starts before the commit and cuts the finished
        /// turn off in the session. It runs on the loop's thread, which owns
        /// the pacer. A flush that fails is logged and not tried again until
        /// the hold is over: the finished turn stays in the pacer, and the
        /// worker's time limit ends the hold as it did before.
        pub fn flushPacerForHeldMail(app: *App, agent: *AppAgent, now_ns: i128) void {
            if (comptime !(@hasField(AppAgent, "worker") and
                @hasDecl(@TypeOf(agent.worker), "commitGateWaitsForCommit")))
            {
                return;
            }
            if (!pacerHoldsFinish(app)) return;
            if (!agent.worker.commitGateWaitsForCommit()) return;
            debug_trace.logf("worker", "commit gate flushes the pacer behind a prompt for held mail", .{});
            app.pacer.flushPresentationAtBoundary(app.alloc, now_ns, app.pacerCallbacks()) catch |err| {
                debug_trace.logf("worker", "commit gate flush failed err={s}; the time limit ends the hold dropped=none", .{@errorName(err)});
                agent.worker.noteCommitGateFlushFailed();
            };
        }

        /// Clears the pacer of `agent`, the agent in context: the text it had
        /// not shown, and a finished turn it deferred, which is never saved
        /// then. A cancel and a session switch clear it. `reason` names which.
        pub fn clearPacer(app: *App, agent: *AppAgent, reason: []const u8) void {
            const held_finish = pacerHoldsFinish(app);
            app.pacer.clear(app.alloc);
            if (held_finish) {
                debug_trace.logf("worker", "pacer cleared a deferred finished turn unsaved reason={s}", .{reason});
                acknowledgeDroppedFinish(agent, reason);
            }
        }

        /// Defers `finished` in the pacer of `agent` while text is still being
        /// shown. A finished turn the pacer already held is replaced and never
        /// saved, so that one is acknowledged as dropped.
        pub fn deferFinish(app: *App, agent: *AppAgent, finished: types.FinishedPrompt) !bool {
            const replaced = pacerHoldsFinish(app);
            const retained = app.pacer.deferFinish(app.alloc, finished) catch |err| {
                if (replaced and !pacerHoldsFinish(app)) acknowledgeDroppedFinish(agent, "pacer_replaced");
                return err;
            };
            if (retained and replaced) {
                debug_trace.logf("worker", "pacer replaced a deferred finished turn unsaved", .{});
                acknowledgeDroppedFinish(agent, "pacer_replaced");
            }
            return retained;
        }

        fn preserveFinishedAfterDrainFailure(app: *App, agent: *AppAgent, batch: *DetachedWorkerEventBatch, may_persist: bool) void {
            var can_persist = may_persist;
            if (can_persist) settleDeferredFinish(app, agent) catch {
                can_persist = false;
            };
            while (batch.claim()) |event| {
                defer worker_runtime.freeWorkerEvent(batch.alloc, event);
                switch (event) {
                    .finish_prompt => |finished| {
                        if (can_persist) {
                            persistFinishedPrompt(app, agent, finished) catch {
                                can_persist = false;
                            };
                        } else {
                            debug_trace.logf("worker", "finished turn not persisted after earlier save failure", .{});
                            acknowledgeDroppedFinish(agent, "not_persisted");
                        }
                    },
                    else => debug_trace.logf("worker", "presentation failure discarded worker event kind={s}", .{@tagName(event)}),
                }
            }
        }

        pub fn authorizeInteractiveAdmission(app: *App, agent: *AppAgent) !bool {
            if (comptime @hasDecl(@TypeOf(agent.worker), "interactiveAdmissionSnapshot")) {
                switch (agent.worker.interactiveAdmissionSnapshot()) {
                    .open => return true,
                    .stopped => return false,
                    .finalization_failed => {
                        if (comptime @hasField(App, "should_exit")) {
                            app.should_exit = true;
                        }
                        return error.TurnFinalizationDeliveryFailed;
                    },
                }
            }
            return true;
        }

        pub fn syncQueuedPromptModel(agent: *AppAgent, model: []const u8) !void {
            try agent.worker.syncQueuedPromptModel(std.heap.c_allocator, model);
        }

        pub fn propagateHistoryTurn(app: *App, agent: *AppAgent, turn: types.HistoryTurn, max_history_turns: usize) !void {
            if (comptime @hasDecl(App, "propagateHistoryTurn")) {
                try app.propagateHistoryTurn(turn);
                return;
            }
            try agent.worker.propagateHistoryTurn(std.heap.c_allocator, turn, max_history_turns);
        }

        pub fn commitContextCompaction(
            agent: *AppAgent,
            summary: types.CompactedSummaryHistoryTurn,
            active_prefix: ?types.AssistantHistoryTurn,
            retained_from: ?types.ContextHistoryCut,
            max_history_turns: usize,
        ) !void {
            if (comptime @hasDecl(@TypeOf(agent.worker), "commitContextCompaction")) {
                try agent.worker.commitContextCompaction(
                    std.heap.c_allocator,
                    summary,
                    active_prefix,
                    retained_from,
                    max_history_turns,
                );
                return;
            }
            return error.ContextCompactionPersistenceUnavailable;
        }

        /// Writes the reasoning gathered since the last block as a thinking
        /// block: in the transcript when reasoning is shown, otherwise only
        /// in the full transcript (ctrl+o).
        fn flushReasoning(app: *App, agent: *AppAgent, handlers: anytype) !void {
            if (comptime !agents.hasAgentField(App, "reasoning")) return;
            defer agent.reasoning.clearRetainingCapacity();
            if (agent.reasoning.items.len > 0) agent.live_generation +%= 1;
            const text = std.mem.trim(u8, agent.reasoning.items, " \t\r\n");
            if (text.len == 0) return;
            const shown = if (comptime @hasField(App, "show_reasoning")) app.show_reasoning else true;
            try handlers.semantic_notice(handlers.ctx, .{
                .topic = "",
                .tone = .neutral,
                .body = text,
                .visibility = if (shown) .compact_and_full else .full_only,
            });
        }

        pub fn pushEvent(app: *App, agent: *AppAgent, event: WorkerEvent) !void {
            if (comptime @hasDecl(App, "pushWorkerEvent")) {
                const owned = try worker_runtime.dupeWorkerEvent(std.heap.c_allocator, event);
                errdefer worker_runtime.freeWorkerEvent(std.heap.c_allocator, owned);
                try app.pushWorkerEvent(owned);
                return;
            }
            try agent.worker.pushEvent(std.heap.c_allocator, event);
        }

        pub fn pushOwnedEvent(app: *App, agent: *AppAgent, event: WorkerEvent) !void {
            if (comptime @hasDecl(App, "pushWorkerEvent")) {
                try app.pushWorkerEvent(event);
                return;
            }
            try agent.worker.pushOwnedEvent(std.heap.c_allocator, event);
        }

        pub fn pushText(app: *App, agent: *AppAgent, text: []const u8) !void {
            if (comptime @hasDecl(App, "pushText")) {
                try app.pushText(agent, text);
            } else {
                try pushEvent(app, agent, .{ .assistant_presentation = .{
                    .text = @constCast(text),
                } });
            }
            debug_trace.eventf(
                "worker",
                "assistant_chunk_received",
                .{},
                "chunk_bytes={d}",
                .{text.len},
            );
        }

        pub fn pushTable(app: *App, agent: *AppAgent, table: assistant_presentation.TablePayload) !void {
            try pushEvent(app, agent, .{ .assistant_presentation = .{ .table = table } });
        }

        pub fn pushCodeBlock(app: *App, agent: *AppAgent, block: assistant_presentation.CodeBlockPayload) !void {
            try pushEvent(app, agent, .{ .assistant_presentation = .{ .code_block = block } });
        }

        pub fn pushThematicRule(app: *App, agent: *AppAgent) !void {
            try pushEvent(app, agent, .{ .assistant_presentation = .thematic_rule });
        }

        pub fn pushCommandOutput(
            app: *App,
            agent: *AppAgent,
            lifecycle_id: ?types.ToolLifecycleId,
            stream: command_output_content.Stream,
            chunk: []const u8,
        ) !void {
            if (chunk.len == 0) return;
            if (comptime @hasDecl(App, "pushCommandOutputWithLifecycle")) {
                try app.pushCommandOutputWithLifecycle(lifecycle_id, stream, chunk);
                return;
            }
            if (comptime @hasDecl(App, "pushCommandOutput")) {
                try app.pushCommandOutput(stream, stream.agent(), chunk);
                return;
            }
            try pushEvent(app, agent, .{ .command_output = .{
                .lifecycle_id = lifecycle_id,
                .stream = stream,
                .text = @constCast(chunk),
            } });
        }

        pub fn pushCommandOutputComplete(app: *App, agent: *AppAgent, lifecycle_id: ?types.ToolLifecycleId) !void {
            try pushEvent(app, agent, .{ .command_output_complete = lifecycle_id });
        }

        pub fn pushToolLifecycle(
            app: *App,
            agent: *AppAgent,
            event: types.ToolLifecycleEvent,
        ) !void {
            try pushEvent(app, agent, .{ .tool_lifecycle = event });
        }

        pub fn pushWebSearchProgress(app: *App, agent: *AppAgent, call_id: []const u8, progress: types.WebSearchProgress) !void {
            const turn_id = agent.worker.activeTurnId();
            if (turn_id == 0 or call_id.len == 0) {
                debug_trace.logf(
                    "ui_activity",
                    "web search progress missing active lifecycle identity",
                    .{},
                );
                return;
            }
            const label = try formatWebSearchProgress(std.heap.c_allocator, progress);
            defer std.heap.c_allocator.free(label);
            try pushToolLifecycle(app, agent, .{ .progress = .{
                .id = .{ .turn_id = turn_id, .call_id = call_id },
                .text = label,
            } });
        }

        pub fn pushWebFetchProgress(app: *App, agent: *AppAgent, call_id: []const u8, progress: types.WebFetchProgress) !void {
            const turn_id = agent.worker.activeTurnId();
            if (turn_id == 0 or call_id.len == 0) {
                debug_trace.logf(
                    "ui_activity",
                    "web fetch progress missing active lifecycle identity",
                    .{},
                );
                return;
            }
            const label = try formatWebFetchProgress(std.heap.c_allocator, progress);
            defer std.heap.c_allocator.free(label);
            try pushToolLifecycle(app, agent, .{ .progress = .{
                .id = .{ .turn_id = turn_id, .call_id = call_id },
                .text = label,
            } });
        }

        pub fn pushSemanticNotice(app: *App, agent: *AppAgent, notice: types.SemanticNotice) !void {
            try pushEvent(app, agent, .{ .semantic_notice = notice });
        }

        pub fn pushDiffBlock(app: *App, agent: *AppAgent, payload: diff_mod.DiffEntryPayload) !void {
            try pushOwnedEvent(app, agent, .{ .diff_block = payload });
        }

        pub fn syncState(
            app: *App,
            agent: *AppAgent,
            presenter: activity_runtime.LifecyclePresenter,
        ) void {
            const snapshot = agent.worker.snapshotState(app.alloc) catch return;
            defer snapshot.deinit(app.alloc);

            // A subagent's question lent to main's prompt is its worker's, not
            // main's; the agents runtime ends it when that worker stops asking.
            const lent_question = if (comptime @hasDecl(App, "questionLentToMain"))
                app.questionLentToMain() and !isSubagent(app, agent)
            else
                false;
            if (agent.question_prompt.isActive() and !lent_question) {
                if (agent.worker.snapshotPendingQuestionBatch(app.alloc) catch return) |question_snapshot| {
                    question_snapshot.deinit(app.alloc);
                } else {
                    agent.question_prompt.discard(app.alloc, "worker_cleared");
                    app.shell.render_requests.request(.modal);
                }
            }

            const modal_active = agent.question_prompt.isActive();
            const worker_events_pending = if (comptime @hasField(@TypeOf(snapshot), "pending_event_count"))
                snapshot.pending_event_count > 0
            else
                false;
            const cancellation_stops_turn = snapshot.cancel_requested and
                !snapshot.cancel_continues_turn;
            const visible_worker_active = agent.stream.active and
                !cancellation_stops_turn and
                (snapshot.processing or
                    worker_events_pending or
                    snapshot.queued_count > 0);
            const awaiting_tool_terminal = snapshot.cancel_requested and
                activeToolStatusCount(presenter) > 0;
            if (!modal_active and
                !visible_worker_active and
                !awaiting_tool_terminal and
                agent.stream.active)
            {
                // The worker can become idle before its final UI events reach
                // this thread. Keep any open command block until the queued
                // turn boundary finalizes it instead of discarding output.
                agent.stream = .{};
                app.shell.render_requests.request(.footer);
            } else if (modal_active and !agent.stream.active) {
                agent.stream.active = true;
                agent.stream.turn_started_ms = io_mod.milliTimestamp();
                app.shell.render_requests.request(.footer);
            }
            // Waiting on an approval, a question, or a compaction is not the
            // turn's work: freeze the elapsed clock for the duration of the
            // wait. A compaction shows a clock of its own meanwhile.
            const compaction: compaction_activity.Snapshot = if (comptime @hasDecl(@TypeOf(agent.worker), "compactionActivitySnapshot"))
                agent.worker.compactionActivitySnapshot()
            else
                .{};
            activity_status.syncWaitingClock(&agent.stream, turn_clock.waits(modal_active, compaction), io_mod.milliTimestamp());

            if (comptime @hasField(App, "program_status")) {
                reportProgramStatus(app, agent, !cancellation_stops_turn and
                    (agent.stream.active or snapshot.processing or snapshot.queued_count > 0), compaction);
            }
        }

        /// The session id of subagent `agent`, or null for main.
        fn subagentIdOf(app: *App, agent: *AppAgent) ?[]const u8 {
            if (comptime !@hasDecl(App, "subagentIdOf")) return null;
            return app.subagentIdOf(agent);
        }

        /// True when `agent` is a subagent's, on screen or not.
        fn isSubagent(_: *const App, agent: *const AppAgent) bool {
            if (comptime !@hasField(App, "screen_owner")) return false;
            return agent.role == .subagent;
        }

        /// True when `agent` is not the one on screen. What spark shows app-wide,
        /// such as the terminal's program status, follows the agent on screen.
        fn offScreen(app: *const App, agent: *const AppAgent) bool {
            if (comptime !@hasField(App, "agent_on_screen")) return false;
            const on_screen: *const agents.Agent = if (app.agent_on_screen) |child| &child.agent else &app.main_agent;
            return agent != on_screen;
        }

        /// Tells the terminal what the user would see: a decision prompt,
        /// running work, or the result of the last turn.
        fn reportProgramStatus(app: *App, agent: *AppAgent, busy: bool, compaction: compaction_activity.Snapshot) void {
            if (offScreen(app, agent)) return;
            app.program_status.noteCompaction(compaction);
            const activity: program_status.Activity = if (agent.question_prompt.isActive())
                .{ .blocked = .{ .kind = .question, .message = activeQuestionText(app, agent) } }
            else if (busy)
                .working
            else
                .settled;
            const report = app.program_status.update(activity) orelse return;
            debug_trace.logf("program_status", "report activity={s} settled={s}", .{
                @tagName(activity),
                @tagName(app.program_status.settled),
            });
            app.writeProgramStatus(report);
        }

        fn activeQuestionText(_: *const App, agent: *const AppAgent) []const u8 {
            const projection = agent.question_prompt.projection() orelse return "";
            const entry = projection.current_entry orelse return "";
            return entry.question;
        }

        /// A turn began with `author`'s prompt.
        fn noteTurnStarted(app: *App, agent: *AppAgent, author: types.MessageAuthor) void {
            if (comptime @hasDecl(App, "noteChildTurnBegun")) App.noteChildTurnBegun(app, agent, author);
            if (offScreen(app, agent)) return;
            if (comptime @hasField(App, "program_status")) app.program_status.noteTurnStarted();
        }

        fn activeToolStatusCount(
            presenter: activity_runtime.LifecyclePresenter,
        ) usize {
            return presenter.snapshot().active_tool_count;
        }

        pub fn tick(
            app: *App,
            agent: *AppAgent,
            event_handlers: WorkerEventHandlers,
        ) !void {
            try tickWithDrainBudget(app, agent, event_handlers, null);
        }

        /// `tick` for the interactive loop: once `budget_ns` has passed, the
        /// drain stops before its next event and puts the rest back, so the
        /// loop reads keys and paints before applying them.
        pub fn tickWithinBudget(
            app: *App,
            agent: *AppAgent,
            event_handlers: WorkerEventHandlers,
            budget_ns: i128,
        ) !void {
            try tickWithDrainBudget(app, agent, event_handlers, budget_ns);
        }

        fn tickWithDrainBudget(
            app: *App,
            agent: *AppAgent,
            event_handlers: WorkerEventHandlers,
            budget_ns: ?i128,
        ) !void {
            if (!try authorizeInteractiveAdmission(app, agent)) return;
            try drainEvents(app, agent, event_handlers, budget_ns);
            syncState(app, agent, event_handlers.tool_lifecycle);

            const now_ms = io_mod.milliTimestamp();
            _ = advanceVisibleAnimation(
                app,
                agent,
                event_handlers.tool_lifecycle,
                now_ms,
            );
        }

        fn advanceVisibleAnimation(
            app: *App,
            agent: *AppAgent,
            presenter: activity_runtime.LifecyclePresenter,
            now_ms: i64,
        ) bool {
            const compaction: @import("../output/compaction_activity.zig").Snapshot = if (comptime @hasDecl(@TypeOf(agent.worker), "compactionActivitySnapshot")) agent.worker.compactionActivitySnapshot() else .{};
            app.shell.render_requests.observeCompactionRevision(compaction.revision);
            if (comptime @hasDecl(@TypeOf(agent.worker), "expireCompactionActivity")) {
                if (compaction.operation) |op| {
                    if (agent.worker.expireCompactionActivity(op.id, compaction.revision, now_ms)) app.shell.render_requests.request(.footer);
                }
            }
            const compaction_active = if (compaction.operation) |op| op.active() and op.visible(now_ms) else false;
            if (!compaction_active and !agent.stream.active and !app.pacer.hasCompletedAssistantPresentationTail()) {
                return advanceSubagentWaitBlink(app, agent, now_ms);
            }
            if (agent.question_prompt.isActive() or
                !app.shell.shimmer_active)
            {
                return false;
            }

            var label_buf: [256]u8 = undefined;
            _ = activityShimmerLabel(app, agent, presenter, compaction, now_ms, &label_buf) orelse return false;
            const previous_deadline = app.shell.render_requests.animation_next_deadline_ms;
            if (!app.shell.render_requests.requestAnimationDue(now_ms)) return false;
            debug_trace.logf(
                "frame_schedule",
                "animation_due previous_ms={d} now_ms={d} interval_ms={d}",
                .{ previous_deadline, now_ms, render_request.animation_interval_ms },
            );
            return true;
        }

        /// Keeps frames coming while the idle agent on screen shows "waiting
        /// on N subagents", so its bullet blinks like a turn's.
        fn advanceSubagentWaitBlink(app: *App, agent: *AppAgent, now_ms: i64) bool {
            if (comptime !@hasDecl(App, "subagentWaitCount")) return false;
            if (offScreen(app, agent)) return false;
            if (agent.question_prompt.isActive() or !app.shell.shimmer_active) return false;
            // A worker status, such as a failed request, shows in its place.
            switch (app.shell.activityProjection()) {
                .turn_thinking => |thinking| if (thinking.tone != .thinking) return false,
                .none, .tool_slot => {},
            }
            // Counting walks every subagent, so wait until a frame is due.
            if (!app.shell.render_requests.animationDue(now_ms)) return false;
            if (app.subagentWaitCount() == 0) return false;
            return app.shell.render_requests.requestAnimationDue(now_ms);
        }

        fn activityShimmerLabel(
            app: *App,
            agent: *AppAgent,
            presenter: activity_runtime.LifecyclePresenter,
            compaction: @import("../output/compaction_activity.zig").Snapshot,
            now_ms: i64,
            buf: []u8,
        ) ?[]const u8 {
            switch (app.shell.activityProjection()) {
                .turn_thinking => |thinking| if (thinking.tone != .thinking) return null,
                .none, .tool_slot => {},
            }
            switch (activity_status.compactionProjection(buf, compaction, now_ms)) {
                .turn_thinking => |thinking| return if (thinking.tone == .thinking) thinking.label else null,
                .none, .tool_slot => {},
            }
            // Existence guard only: pass no clock so the label skips the counter.
            if (!agent.stream.active and app.pacer.hasCompletedAssistantPresentationTail()) {
                return activity_status.buildTurnLabel(buf, .{ .active = true }, 0);
            }
            if (activity_status.buildTurnLabel(buf, agent.stream, 0)) |label| return label;
            if (agent.stream.last_activity_kind == .ask) return ui_render.ask_activity_label;
            switch (presenter.snapshot().activity) {
                .tool_slot => |slot| return slot.fallback_label,
                .none, .turn_thinking => {},
            }
            return activity_status.buildProgressLabel(buf, agent.stream);
        }

        /// Logs a `host` trace line for one of main's events. Only a worker
        /// the app named logs anything.
        fn traceMainEvent(app: *App, comptime line: []const u8, event: WorkerEvent, reason: ?[]const u8) void {
            if (comptime !@hasField(@TypeOf(agents.screenAgentOf(app).worker), "trace_agent")) return;
            const agent = agents.screenAgentOf(app).worker.trace_agent orelse return;
            if (reason) |why| {
                debug_trace.eventf("host", line, .{}, "agent={s} kind={s} reason={s}", .{ agent, worker_runtime.traceKind(event), why });
            } else {
                debug_trace.eventf("host", line, .{}, "agent={s} kind={s}", .{ agent, worker_runtime.traceKind(event) });
            }
        }

        fn drainEvents(app: *App, agent: *AppAgent, handlers: WorkerEventHandlers, budget_ns: ?i128) !void {
            errdefer if (comptime @hasDecl(@TypeOf(agent.worker), "failPendingHistoryPublication")) {
                agent.worker.failPendingHistoryPublication(error.HistoryPublicationDeliveryFailed);
            };
            const taken = agent.worker.takeEventBatch();
            var batch = DetachedWorkerEventBatch.init(
                std.heap.c_allocator,
                taken.events,
            );
            app.shell.render_requests.beginFrameAdmissionBlock();
            defer app.shell.render_requests.endFrameAdmissionBlock();

            var lifecycle_cleanup_attempted = false;
            errdefer if (!lifecycle_cleanup_attempted) {
                handlers.tool_lifecycle.finish_batch(app.alloc) catch |err| {
                    debug_trace.logf(
                        "ui_activity",
                        "lifecycle cleanup after drain failure err={s}",
                        .{@errorName(err)},
                    );
                };
            };
            defer batch.deinit();

            var can_persist_finished = true;
            errdefer preserveFinishedAfterDrainFailure(app, agent, &batch, can_persist_finished);

            // A take's cancellation snapshot stays with the events taken under
            // it, so a batch that carries one is never split.
            const deadline_ns: ?i128 = if (budget_ns) |budget|
                if (taken.cancelled_turn_id == null) io_mod.nanoTimestamp() + budget else null
            else
                null;
            var segment_scan: HeadSegmentScan = taken.head_segment orelse .fresh;
            var interrupted_segment = segmentInterrupted(
                scanSegment(segment_scan, batch.events.items),
                taken.cancelled_turn_id,
            );
            var first_event = true;

            events: while (batch.claim()) |event| {
                if (!first_event) {
                    const starts_segment = startsSegment(event);
                    if (budgetSpent(deadline_ns)) {
                        try retainClaimedEventAndSuffixForBudget(
                            agent,
                            &batch,
                            if (starts_segment) null else segment_scan,
                        );
                        break :events;
                    }
                    if (starts_segment) {
                        interrupted_segment = batchSegmentIsInterrupted(batch.claimedAndRemaining(), taken.cancelled_turn_id);
                        segment_scan = .fresh;
                    }
                }
                segment_scan = scanSegmentEvent(segment_scan, event);
                first_event = false;
                var drain_owns_current = true;
                defer if (drain_owns_current) {
                    worker_runtime.freeWorkerEvent(batch.alloc, event);
                };
                if (interrupted_segment) {
                    switch (cancelledEventAdmission(
                        handlers.tool_lifecycle,
                        event,
                        batch.claimedAndRemaining(),
                    )) {
                        .admit => {},
                        .drop => {
                            debug_trace.logf(
                                "worker",
                                "cancelled worker event dropped kind={s}",
                                .{@tagName(event)},
                            );
                            traceMainEvent(app, "agent_event_dropped", event, "cancelled");
                            continue;
                        },
                        .defer_until_closure => {
                            try retainClaimedEventAndSuffix(
                                agent,
                                &batch,
                                "cancelled_tool_closure_pending",
                            );
                            drain_owns_current = false;
                            break :events;
                        },
                    }
                }

                switch (event) {
                    .begin_prompt => |prompt| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        resetStream(app, agent, true);
                        noteTurnStarted(app, agent, prompt.author);
                        agent.stream.active = true;
                        agent.stream.turn_started_ms = io_mod.milliTimestamp();
                        app.shell.render_requests.request(.footer);
                        try handlers.write_user_prompt(handlers.ctx, prompt);
                    },
                    .begin_prompt_with_skill_bindings => |begin| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        resetStream(app, agent, true);
                        noteTurnStarted(app, agent, begin.prompt.author);
                        agent.stream.active = true;
                        agent.stream.turn_started_ms = io_mod.milliTimestamp();
                        app.shell.render_requests.request(.footer);
                        if (handlers.write_user_prompt_with_skill_bindings) |write_bound_prompt| {
                            try write_bound_prompt(handlers.ctx, begin.prompt, begin.skill_bindings, begin.skill_display_spans);
                        } else {
                            try handlers.write_user_prompt(handlers.ctx, begin.prompt);
                        }
                    },
                    .begin_presented_prompt => |turn_id| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        resetStream(app, agent, true);
                        noteTurnStarted(app, agent, .user);
                        agent.stream.active = true;
                        agent.stream.turn_started_ms = io_mod.milliTimestamp();
                        app.shell.render_requests.request(.footer);
                        if (comptime @hasDecl(App, "acceptPresentedPrompt")) {
                            try App.acceptPresentedPrompt(app, agent, turn_id);
                        } else {
                            return error.PresentedPromptUnsupported;
                        }
                    },
                    .begin_resumed_prompt => {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        resetStream(app, agent, true);
                        // A resumed request is the user's own, resent on resume.
                        noteTurnStarted(app, agent, .user);
                        agent.stream.active = true;
                        agent.stream.turn_started_ms = io_mod.milliTimestamp();
                        app.shell.render_requests.request(.footer);
                        try handlers.semantic_notice(handlers.ctx, session_notices.resumed_request_notice);
                    },
                    .append_user_feedback, .append_agent_message => |text| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        // A subagent's message draws as its card.
                        const author: types.MessageAuthor = if (event == .append_agent_message) .child else .user;
                        try handlers.write_user_prompt(handlers.ctx, .{ .text = text, .author = author });
                        if (agent.stream.active and agent.stream.phase != .thinking) {
                            agent.stream.phase = .thinking;
                            app.shell.render_requests.request(.footer);
                        }
                    },
                    .assistant_presentation => |presentation| {
                        if (presentation.requiresTextDrain() and !try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        try flushReasoning(app, agent, handlers);
                        switch (presentation) {
                            .text => |text| {
                                try handlers.append_text(handlers.ctx, text);
                                debug_trace.eventf(
                                    "worker",
                                    "assistant_chunk_applied",
                                    .{},
                                    "chunk_bytes={d}",
                                    .{text.len},
                                );
                            },
                            .table => |table| {
                                drain_owns_current = false;
                                try handlers.append_table(handlers.ctx, table);
                            },
                            .code_block => |block| {
                                drain_owns_current = false;
                                try handlers.append_code_block(handlers.ctx, block);
                            },
                            .thematic_rule => {
                                drain_owns_current = false;
                                try handlers.append_thematic_rule(handlers.ctx);
                            },
                            .attempt_start => {
                                // Earlier text has shown, so the transcript
                                // ends where this attempt's output begins.
                                if (comptime @hasDecl(@TypeOf(app.shell), "markAssistantAttemptStart")) {
                                    app.shell.markAssistantAttemptStart();
                                }
                            },
                            .attempt_restart => |fallback| {
                                if (!try replaceRestartedAttempt(app)) {
                                    try handlers.append_text(handlers.ctx, fallback);
                                }
                            },
                        }
                        traceMainEvent(app, "agent_event_applied", event, null);
                    },
                    .notification => |notification| {
                        if (comptime @hasDecl(App, "queueNotification")) {
                            app.queueNotification(notification);
                        }
                    },
                    .question_requested => {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        const pending_question = agent.worker.snapshotPendingQuestionBatch(app.alloc) catch |err| {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            return err;
                        };
                        if (pending_question) |question_snapshot| {
                            defer question_snapshot.deinit(app.alloc);
                            if (comptime @hasDecl(App, "returnLentQuestion")) {
                                if (!isSubagent(app, agent)) app.returnLentQuestion();
                            }
                            const was_active = agent.question_prompt.isActive();
                            agent.question_prompt.syncFrom(app.alloc, question_snapshot.entries) catch |err| {
                                try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                                drain_owns_current = false;
                                return err;
                            };
                            if (!was_active and agent.question_prompt.isActive()) {
                                if (comptime @hasDecl(App, "notePromptAsked")) {
                                    if (isSubagent(app, agent)) app.notePromptAsked(agent, .question);
                                }
                                app.shell.render_requests.request(.modal);
                                if (comptime @hasDecl(App, "dispatchAttentionRequired")) {
                                    app.dispatchAttentionRequired(
                                        agent,
                                        agent.worker.activeTurnId(),
                                        switch (question_snapshot.source) {
                                            .agent_question, .mcp_elicitation => .question,
                                            .route_recovery => .route_recovery,
                                        },
                                    );
                                }
                            }
                        }
                        traceMainEvent(app, "agent_event_applied", event, null);
                    },
                    .open_model_picker => {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        try handlers.open_model_picker(handlers.ctx);
                        app.shell.render_requests.request(.modal);
                    },
                    .semantic_notice => |notice| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        try handlers.semantic_notice(handlers.ctx, notice);
                    },
                    .model_call => |record| {
                        // After the text the call wrote. The line shows only
                        // in Ctrl+O, so it waits for text still being paced
                        // out instead of showing that text early, as in
                        // front of an approval.
                        if (!try handlers.hold_model_call(handlers.ctx, record)) {
                            try writeModelCallNotice(handlers.ctx, handlers.semantic_notice, record);
                        }
                    },
                    .route_recovery_status => |status| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        // The TUI shows nothing for how a request ended,
                        // recovered or failed; the error itself arrives on
                        // its own. The status line returns to normal activity.
                        const was_waiting_for_sign_in = app.shell.worker_status_state().waitsForSignIn();
                        const was_waiting = app.shell.worker_status_state().waitsForUser();
                        if (status.kind == .recovered or status.kind == .failed) {
                            _ = app.shell.worker_status_state().clear_route_recovery();
                        } else {
                            app.shell.worker_status_state().set_route_recovery(status);
                        }
                        // A request that starts waiting for a sign-in opens it,
                        // once; signing in continues the request. Only the
                        // agent on screen opens it: the sign-in shows on the
                        // screen and continues the request of the agent there.
                        if (!was_waiting_for_sign_in and app.shell.worker_status_state().waitsForSignIn()) {
                            if (comptime @hasDecl(App, "beginRecoverySignIn")) {
                                if (agent == app.screenAgent()) try app.beginRecoverySignIn(agent);
                            }
                        }
                        app.shell.render_requests.request(.footer);
                        try recordRouteRecoveryNotice(app, status);
                        if (comptime agents.hasAgentField(App, "child_run")) {
                            app_agents_runtime.Runtime(App).noteChildFailure(app, agent, status);
                            const waiting = app.shell.worker_status_state().waitsForUser();
                            if (!was_waiting and waiting) app_agents_runtime.Runtime(App).noteChildWaiting(app, agent, status);
                            // A wait the user ended leaves nothing for the parent to answer.
                            if (!waiting) agent.worker.parent_may_continue.store(false, .seq_cst);
                        }
                    },
                    .clear_route_recovery_status => {
                        if (app.shell.worker_status_state().clear_route_recovery()) {
                            app.shell.render_requests.request(.footer);
                        }
                        if (comptime agents.hasAgentField(App, "child_run")) agent.worker.parent_may_continue.store(false, .seq_cst);
                    },
                    // The serving provider already appears on the ctrl+o
                    // network record; nothing interactive consumes the event
                    // today. The batch drain frees the payload.
                    .provider_resolved => {},
                    .reasoning_delta => |text| {
                        if (comptime agents.hasAgentField(App, "reasoning")) {
                            if (agent.reasoning.items.len < 256 * 1024) try agent.reasoning.appendSlice(std.heap.c_allocator, text);
                            app.shell.render_requests.request(.footer);
                        }
                    },
                    .live_text => |text| {
                        if (comptime agents.hasAgentField(App, "live_text")) {
                            if (!std.mem.startsWith(u8, text, agent.live_text.items)) agent.live_generation +%= 1;
                            agent.live_text.clearRetainingCapacity();
                            try agent.live_text.appendSlice(std.heap.c_allocator, text);
                            app.shell.render_requests.request(.footer);
                        }
                    },
                    .api_status_text => |text| {
                        resetStream(app, agent, false);
                        app.shell.worker_status_state().set_api(text, .danger);
                        app.shell.render_requests.request(.footer);
                    },
                    .credential_refreshed => |credential| {
                        // During a wait for a sign-in, a credential comes only
                        // from a login another spark process saved, which the
                        // request now sends instead of this session's own
                        // sign-in.
                        const waited_for_sign_in = app.shell.worker_status_state().waitsForSignIn();
                        try handlers.credential_refreshed(handlers.ctx, credential);
                        if (waited_for_sign_in) if (comptime @hasDecl(App, "closeRecoverySignInForStoredLogin")) {
                            if (agent == app.screenAgent()) try app.closeRecoverySignInForStoredLogin(credential.source);
                        };
                    },
                    .command_output => |chunk| {
                        try handlers.command_output(handlers.ctx, chunk.lifecycle_id, chunk.stream, chunk.text);
                    },
                    .command_output_complete => |lifecycle_id| {
                        try handlers.command_output_complete(handlers.ctx, lifecycle_id);
                    },
                    .turn_token_update => |update| {
                        applyTurnTokenProgress(app, agent, update);
                    },
                    .turn_phase_update => |update| {
                        applyTurnPhase(app, agent, update);
                    },
                    .diff_block => |payload| {
                        drain_owns_current = false;
                        try handlers.diff_block(handlers.ctx, payload);
                    },
                    .context_compaction => |value| {
                        if (comptime @hasDecl(@TypeOf(agent.worker), "resolveContextCompaction")) {
                            agent.worker.resolveContextCompaction(
                                std.heap.c_allocator,
                                value,
                                handlers.ctx,
                                handlers.context_compaction,
                            );
                        } else {
                            try handlers.context_compaction(handlers.ctx, value);
                        }
                    },
                    .tool_lifecycle => |lifecycle| {
                        switch (lifecycle) {
                            .provisional, .authoritative_started => {
                                if (!try requireAssistantTextDrain(handlers)) {
                                    try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                                    drain_owns_current = false;
                                    break :events;
                                }
                            },
                            .progress, .terminal, .turn_finished => {},
                        }
                        switch (lifecycle) {
                            .provisional, .authoritative_started, .turn_finished => {
                                try flushReasoning(app, agent, handlers);
                                if (comptime agents.hasAgentField(App, "live_text")) agent.live_text.clearRetainingCapacity();
                            },
                            else => {},
                        }
                        if (comptime agents.hasAgentField(App, "child_run")) {
                            app_agents_runtime.Runtime(App).noteChildToolLifecycle(app, agent, lifecycle);
                        }
                        try applyToolLifecycle(app, agent, handlers.tool_lifecycle, lifecycle);
                    },
                    .finish_prompt => |finished| {
                        try flushReasoning(app, agent, handlers);
                        if (comptime agents.hasAgentField(App, "live_text")) agent.live_text.clearRetainingCapacity();
                        var accepted = false;
                        errdefer if (!accepted) {
                            settleDeferredFinish(app, agent) catch {
                                can_persist_finished = false;
                            };
                            if (can_persist_finished) {
                                persistFinishedPrompt(app, agent, finished) catch {
                                    can_persist_finished = false;
                                };
                            } else {
                                debug_trace.logf("worker", "finished turn not persisted after earlier save failure", .{});
                                acknowledgeDroppedFinish(agent, "not_persisted");
                            }
                        };
                        try flushPendingCommandOutputAtTurnBoundary(app, handlers);
                        resetStream(app, agent, false);
                        app.shell.render_requests.request(.footer);
                        const delivery = try handlers.append_history_turn(handlers.ctx, finished);
                        accepted = true;
                        switch (delivery) {
                            .retained => {},
                            .settled => |result| switch (result) {
                                .committed => {},
                                .presentation_failed => |err| return err,
                            },
                        }
                    },
                    .error_text => |notice| {
                        if (!try requireAssistantTextDrain(handlers)) {
                            try retainClaimedEventAndSuffix(agent, &batch, "assistant_text_drain_blocked");
                            drain_owns_current = false;
                            break :events;
                        }
                        resetStream(app, agent, false);
                        if (comptime @hasField(App, "program_status")) {
                            if (notice.tone == .@"error" and !offScreen(app, agent)) app.program_status.noteFailure();
                        }
                        app.shell.render_requests.request(.footer);
                        try handlers.error_text(handlers.ctx, notice);
                    },
                    .restore_failed_prompt => |prompt| {
                        // Never clobber a draft the user typed while the doomed
                        // turn was still retrying; only an empty composer gets
                        // the failed prompt back.
                        if (app.input_runtime.edit_state.input.items.len == 0) {
                            try app.input_runtime.textReplacementState().replace(app.alloc, prompt);
                            app.shell.render_requests.request(.footer);
                        } else {
                            debug_trace.logf(
                                "worker",
                                "event=restore_failed_prompt_skipped reason=composer_occupied",
                                .{},
                            );
                        }
                    },
                }
            }

            lifecycle_cleanup_attempted = true;
            try handlers.tool_lifecycle.finish_batch(app.alloc);
        }

        /// Replaces what the TUI showed of an answer attempt that restarts:
        /// the transcript gives back what the attempt added, and its unshown
        /// text is dropped, so the new answer streams in its place. Returns
        /// false, changing nothing, when part of the attempt is final.
        fn replaceRestartedAttempt(app: *App) !bool {
            if (comptime !@hasDecl(@TypeOf(app.shell), "discardAssistantAttempt")) return false;
            if (!try app.shell.discardAssistantAttempt(app.alloc)) return false;
            if (comptime @hasField(App, "pacer")) app.pacer.discardPendingText();
            debug_trace.logf("worker", "restarted answer replaces the broken-off attempt", .{});
            return true;
        }

        fn flushPendingCommandOutputAtTurnBoundary(
            app: *App,
            handlers: WorkerEventHandlers,
        ) !void {
            const Shell = @TypeOf(app.shell);
            if (comptime !@hasDecl(Shell, "openCommandOutputLifecycleId")) return;
            const lifecycle_id = app.shell.openCommandOutputLifecycleId() orelse return;
            debug_trace.logf(
                "command_output",
                "finalizing open command output at turn boundary",
                .{},
            );
            try handlers.command_output_complete(handlers.ctx, lifecycle_id);
        }

        fn requireAssistantTextDrain(handlers: WorkerEventHandlers) !bool {
            return switch (try handlers.drain_assistant_text(handlers.ctx)) {
                .drained => true,
                .blocked => false,
            };
        }

        fn retainClaimedEventAndSuffix(
            agent: *AppAgent,
            batch: *DetachedWorkerEventBatch,
            reason: []const u8,
        ) !void {
            const retained = batch.claimedAndRemaining();
            try agent.worker.prependOwnedEvents(batch.alloc, retained);
            batch.markClaimedAndRemainingTransferred();
            debug_trace.logf(
                "worker",
                "retained detached worker events reason={s} count={d}",
                .{ reason, retained.len },
            );
        }

        /// Puts the claimed event and the rest back for the next drain, with
        /// the scan of the segment they continue (null when the claimed event
        /// starts one).
        fn retainClaimedEventAndSuffixForBudget(
            agent: *AppAgent,
            batch: *DetachedWorkerEventBatch,
            head_segment: ?HeadSegmentScan,
        ) !void {
            const retained = batch.claimedAndRemaining();
            try agent.worker.prependOwnedEventsForBudget(batch.alloc, retained, head_segment);
            batch.markClaimedAndRemainingTransferred();
            debug_trace.logf(
                "worker",
                "retained detached worker events reason=drain_time_budget count={d}",
                .{retained.len},
            );
        }

        fn applyToolLifecycle(
            app: *App,
            agent: *AppAgent,
            presenter: activity_runtime.LifecyclePresenter,
            lifecycle: types.ToolLifecycleEvent,
        ) !void {
            const tool_work_active = switch (lifecycle) {
                .provisional, .authoritative_started, .progress => true,
                .terminal, .turn_finished => false,
            };
            const transition = try presenter.apply(
                app.alloc,
                lifecycle,
            );
            if (comptime @hasField(App, "program_status")) {
                if (lifecycle == .turn_finished and !offScreen(app, agent)) app.program_status.noteTurnFinished(lifecycle.turn_finished.outcome);
            }
            if (comptime agents.hasAgentField(App, "child_run")) {
                if (lifecycle == .turn_finished) app_agents_runtime.Runtime(App).noteChildTurnFinished(app, agent, lifecycle.turn_finished);
            }
            if (transition.applied_activity_kind) |kind| {
                applyToolActivity(&agent.stream, kind);
            }
            if (comptime agents.hasAgentField(App, "session_persistence")) {
                switch (lifecycle) {
                    .terminal => {
                        if (transition.terminal_record) |record| {
                            app_session_runtime.Runtime(App).recordToolTerminal(
                                app,
                                agent,
                                lifecycle,
                                record.captured_command,
                            );
                        }
                    },
                    .provisional, .authoritative_started, .progress, .turn_finished => {},
                }
            }

            const focused_activity_kind = transition.snapshot.focused_activity_kind;
            if (tool_work_active) agent.stream.phase = .running;
            agent.stream.last_activity_kind = focused_activity_kind;
            if (transition.focus_changed()) {
                app.shell.render_requests.requestAnimationReset();
            }
            app.shell.render_requests.request(.footer);
        }

        fn resetStream(app: *App, agent: *AppAgent, clear_route_recovery: bool) void {
            agent.stream = .{};
            if (clear_route_recovery and app.shell.worker_status_state().clear()) {
                app.shell.render_requests.request(.footer);
            }
            app.shell.resetCommandOutputDisplay(app.alloc, "worker inactive");
        }

        fn applyToolActivity(stream: *types.StreamState, kind: types.ToolActivityKind) void {
            stream.chunks += 1;
            stream.last_activity_kind = kind;
            switch (kind) {
                .read => stream.read_count += 1,
                .list => stream.list_count += 1,
                .write => stream.write_count += 1,
                .edit => stream.edit_count += 1,
                .open => stream.open_count += 1,
                .command => stream.command_count += 1,
                .subagent => stream.subagent_count += 1,
                .mcp => stream.mcp_count += 1,
                .ask => {},
            }
        }

        fn applyTurnTokenProgress(app: *App, agent: *AppAgent, update: types.TurnTokenProgress) void {
            if (!agent.stream.active) return;

            const changed = !std.meta.eql(agent.stream.token_progress, update);
            agent.stream.token_progress = update;

            // An armed animation tick already repaints the label within 50ms.
            const animation_armed = app.shell.render_requests.animation_visible and
                app.shell.render_requests.animation_next_deadline_ms != 0;
            if (changed and !animation_armed) app.shell.render_requests.request(.footer);
        }

        fn applyTurnPhase(app: *App, agent: *AppAgent, update: types.TurnPhaseUpdate) void {
            if (!agent.stream.active or update.turn_id != agent.worker.activeTurnId()) return;
            if (update.step_id < agent.stream.phase_step_id) return;

            const changed = agent.stream.phase != update.phase;
            agent.stream.phase = update.phase;
            agent.stream.phase_step_id = update.step_id;
            if (changed) app.shell.render_requests.request(.footer);
        }
    };
}

fn formatWebSearchProgress(alloc: std.mem.Allocator, progress: types.WebSearchProgress) ![]u8 {
    var query_buf: [160]u8 = undefined;
    return switch (progress) {
        .query_started => |query| alloc.print(
            "● Searching\x1b[0m {s}{s}\x1b[0m",
            .{ shared_theme.current().tool_stdout_style, text_utils.clippedLabel(&query_buf, query, 120) },
        ),
        .results_received => |entry| alloc.print(
            "● Found {d} result{s}\x1b[0m {s}{s}\x1b[0m",
            .{ entry.result_count, if (entry.result_count == 1) "" else "s", shared_theme.current().tool_stdout_style, text_utils.clippedLabel(&query_buf, entry.query, 120) },
        ),
    };
}

fn formatWebFetchProgress(alloc: std.mem.Allocator, progress: types.WebFetchProgress) ![]u8 {
    var url_buf: [types.WebFetchCompletion.max_url_len]u8 = undefined;
    return switch (progress) {
        .fetching => |url| alloc.print(
            "● Fetching\x1b[0m {s}{s}\x1b[0m",
            .{ shared_theme.current().tool_stdout_style, text_utils.clippedLabel(&url_buf, url, 120) },
        ),
        .converting => |url| alloc.print(
            "● Converting\x1b[0m {s}{s}\x1b[0m",
            .{ shared_theme.current().tool_stdout_style, text_utils.clippedLabel(&url_buf, url, 120) },
        ),
    };
}

const FakeSnapshot = struct {
    processing: bool = false,
    active_turn_id: u64 = 0,
    queued_count: usize = 0,
    pending_event_count: usize = 0,
    cancel_requested: bool = false,
    cancel_continues_turn: bool = false,

    fn deinit(_: FakeSnapshot, _: std.mem.Allocator) void {}
};

const FakeQuestionSnapshot = struct {
    entries: []const u8 = "",
    source: worker_runtime.QuestionPromptSource = .agent_question,

    fn deinit(self: FakeQuestionSnapshot, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};

const FakeWorker = struct {
    compaction: @import("../output/compaction_activity.zig").State = .{},
    compaction_reads: usize = 0,

    worker_cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    events: std.ArrayList(WorkerEvent) = .empty,
    head_segment: ?HeadSegmentScan = null,
    drain_continuation_due: bool = false,
    queued_count: usize = 0,
    processing: bool = false,
    cancel_continues_turn: bool = false,
    pending_question: bool = false,
    pending_question_source: worker_runtime.QuestionPromptSource = .agent_question,
    active_turn_id: u64 = 1,
    propagated_history_turns: usize = 0,
    reset_cancel_after_take_events: bool = false,
    admission_snapshot: worker_runtime.InteractiveAdmissionSnapshot = .open,
    /// Finished turns the app told this worker it dropped without saving.
    dropped_finishes: usize = 0,

    pub fn acknowledgeFinishDropped(self: *FakeWorker, _: []const u8) void {
        self.dropped_finishes += 1;
    }

    pub fn compactionActivitySnapshot(self: *FakeWorker) @import("../output/compaction_activity.zig").Snapshot {
        self.compaction_reads += 1;
        return self.compaction.snapshot;
    }

    pub fn expireCompactionActivity(self: *FakeWorker, id: @import("../output/compaction_activity.zig").OperationId, revision: u64, now_ms: i64) bool {
        return self.compaction.expire(id, revision, now_ms);
    }

    fn deinit(self: *FakeWorker) void {
        for (self.events.items) |event| worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
        self.events.deinit(std.heap.c_allocator);
    }

    fn pushEvent(self: *FakeWorker, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        const owned = try worker_runtime.dupeWorkerEvent(alloc, event);
        errdefer worker_runtime.freeWorkerEvent(alloc, owned);
        try self.pushOwnedEvent(alloc, owned);
    }

    fn pushOwnedEvent(self: *FakeWorker, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        try self.events.append(alloc, event);
    }

    fn prependOwnedEvents(
        self: *FakeWorker,
        alloc: std.mem.Allocator,
        events: []const WorkerEvent,
    ) !void {
        try self.events.insertSlice(alloc, 0, events);
    }

    fn prependOwnedEventsForBudget(
        self: *FakeWorker,
        alloc: std.mem.Allocator,
        events: []const WorkerEvent,
        head_segment: ?HeadSegmentScan,
    ) !void {
        try self.events.insertSlice(alloc, 0, events);
        self.head_segment = head_segment;
        self.drain_continuation_due = true;
    }

    fn takeDrainContinuationDue(self: *FakeWorker) bool {
        defer self.drain_continuation_due = false;
        return self.drain_continuation_due;
    }

    fn takeEvents(self: *FakeWorker) std.ArrayList(WorkerEvent) {
        const events = self.events;
        self.events = .empty;
        if (self.reset_cancel_after_take_events) {
            self.reset_cancel_after_take_events = false;
            self.worker_cancel_requested.store(false, .seq_cst);
        }
        return events;
    }

    fn takeEventBatch(self: *FakeWorker) worker_runtime.WorkerEventBatch {
        const cancel_requested = self.worker_cancel_requested.load(.seq_cst);
        defer self.head_segment = null;
        return .{
            .events = self.takeEvents(),
            .cancelled_turn_id = if (cancel_requested and self.active_turn_id != 0) self.active_turn_id else null,
            .head_segment = self.head_segment,
        };
    }

    fn snapshotState(self: *FakeWorker, _: std.mem.Allocator) !FakeSnapshot {
        return .{
            .processing = self.processing,
            .active_turn_id = self.active_turn_id,
            .queued_count = self.queued_count,
            .pending_event_count = self.events.items.len,
            .cancel_requested = self.worker_cancel_requested.load(.seq_cst),
            .cancel_continues_turn = self.cancel_continues_turn,
        };
    }

    pub fn interactiveAdmissionSnapshot(self: *FakeWorker) worker_runtime.InteractiveAdmissionSnapshot {
        return self.admission_snapshot;
    }

    fn snapshotPendingQuestionBatch(self: *FakeWorker, alloc: std.mem.Allocator) !?FakeQuestionSnapshot {
        _ = alloc;
        return if (self.pending_question) FakeQuestionSnapshot{
            .source = self.pending_question_source,
        } else null;
    }

    fn syncQueuedPromptModel(self: *FakeWorker, alloc: std.mem.Allocator, model: []const u8) !void {
        _ = self;
        _ = alloc;
        _ = model;
    }

    fn activeTurnId(self: *FakeWorker) u64 {
        return self.active_turn_id;
    }

    pub fn propagateHistoryTurn(self: *FakeWorker, alloc: std.mem.Allocator, turn: types.HistoryTurn, max_history_turns: usize) !void {
        _ = alloc;
        _ = turn;
        _ = max_history_turns;
        self.propagated_history_turns += 1;
    }
};

const FakeQuestionPrompt = struct {
    active: bool = false,
    activate_on_sync: bool = true,
    sync_count: usize = 0,
    clear_count: usize = 0,
    question: []const u8 = "",

    fn projection(self: *const FakeQuestionPrompt) ?struct { current_entry: ?struct { question: []const u8 } } {
        if (!self.active) return null;
        return .{ .current_entry = .{ .question = self.question } };
    }

    fn syncFrom(self: *FakeQuestionPrompt, alloc: std.mem.Allocator, entries: anytype) !void {
        _ = alloc;
        _ = entries;
        self.sync_count += 1;
        self.active = self.activate_on_sync;
    }

    fn discard(
        self: *FakeQuestionPrompt,
        alloc: std.mem.Allocator,
        reason: []const u8,
    ) void {
        _ = alloc;
        _ = reason;
        self.clear_count += 1;
        self.active = false;
    }

    fn isActive(self: FakeQuestionPrompt) bool {
        return self.active;
    }
};

const FakeCommandOutputDisplay = struct {
    touched: bool = false,
};

const FakeShell = struct {
    command_output_display: FakeCommandOutputDisplay = .{},
    shimmer_active: bool = false,
    native_history_active: bool = false,
    render_requests: render_request.RenderRequestState = .{},
    lifecycle: transcript_runtime.TranscriptRuntime = .{
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
    },
    raw_entries: std.ArrayList([]u8) = .empty,
    updated_entries: usize = 0,
    last_class: transcript_runtime.RawEntryClass = .unknown_raw,
    trim_calls: usize = 0,
    fail_next_update: bool = false,

    fn deinit(self: *FakeShell, alloc: std.mem.Allocator) void {
        self.lifecycle.deinit(alloc);
        for (self.raw_entries.items) |entry| alloc.free(entry);
        self.raw_entries.deinit(alloc);
    }

    fn nativeHistoryActive(self: *const FakeShell) bool {
        return self.native_history_active;
    }

    fn trimTrailingBlankLines(self: *FakeShell) void {
        self.trim_calls += 1;
    }

    fn appendRawTranscriptEntry(self: *FakeShell, alloc: std.mem.Allocator, line: []const u8) !u32 {
        try self.raw_entries.append(alloc, try alloc.dupe(u8, line));
        return @intCast(self.raw_entries.items.len);
    }

    fn appendRawTranscriptEntryClassified(self: *FakeShell, alloc: std.mem.Allocator, line: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_class = class;
        return self.appendRawTranscriptEntry(alloc, line);
    }

    fn updateRawBytesEntry(self: *FakeShell, alloc: std.mem.Allocator, entry_id: u32, line: []const u8) !bool {
        const index = entry_id - 1;
        alloc.free(self.raw_entries.items[index]);
        self.raw_entries.items[index] = try alloc.dupe(u8, line);
        self.updated_entries += 1;
        return true;
    }

    fn setRawEntryClass(self: *FakeShell, entry_id: u32, class: transcript_runtime.RawEntryClass) bool {
        _ = entry_id;
        self.last_class = class;
        return true;
    }

    pub fn applyToolLifecycle(
        self: *FakeShell,
        alloc: std.mem.Allocator,
        event: types.ToolLifecycleEvent,
    ) !?types.ToolActivityKind {
        if (self.fail_next_update) {
            switch (event) {
                .progress, .terminal, .turn_finished => {
                    self.fail_next_update = false;
                    return error.InjectedTranscriptUpdateFailure;
                },
                .provisional, .authoritative_started => {},
            }
        }
        return self.lifecycle.applyToolLifecycle(alloc, event);
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

    pub fn worker_status_state(self: *FakeShell) *worker_status.State {
        return self.lifecycle.worker_status_state();
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

    fn toolActivityRecord(
        self: *const FakeShell,
        id: types.ToolLifecycleId,
    ) ?activity_runtime.ToolPresentationRecord {
        return self.lifecycle.toolActivityRecord(id);
    }

    fn toolActivityRecordCount(self: *const FakeShell) usize {
        return self.lifecycle.toolActivityRecordCount();
    }

    fn toolStatusEntryLabel(self: *const FakeShell, entry_id: u32) ?[]const u8 {
        return self.lifecycle.toolStatusEntryLabel(entry_id);
    }

    fn finalizedToolTurnWatermark(self: *const FakeShell) u64 {
        return self.lifecycle.finalizedToolTurnWatermark();
    }

    fn lifecyclePinCount(self: *const FakeShell) usize {
        return self.lifecycle.lifecyclePinCount();
    }

    fn replaceableEntryId(self: *FakeShell) ?u32 {
        _ = self;
        return null;
    }

    fn resetCommandOutputDisplay(self: *FakeShell, alloc: std.mem.Allocator, reason: []const u8) void {
        _ = alloc;
        _ = reason;
        self.command_output_display = .{};
    }

    pub fn openCommandOutputLifecycleId(self: *const FakeShell) ?types.ToolLifecycleId {
        return self.lifecycle.openCommandOutputLifecycleId();
    }
};

const FakePacer = struct {
    flushed: usize = 0,
    completed_assistant_presentation_tail: bool = false,
    deferred_turn: ?types.FinishedPrompt = null,
    deferred_started_ns: ?i128 = null,

    fn flushPendingText(self: *FakePacer, callbacks: anytype) !void {
        _ = callbacks;
        self.flushed += 1;
    }

    fn hasCompletedAssistantPresentationTail(self: *const FakePacer) bool {
        return self.completed_assistant_presentation_tail;
    }
};

const FakeSubagents = struct {
    view_active: bool = false,
    child_busy: bool = false,
    child_shell: FakeShell = .{},
    child_render_requests: render_request.RenderRequestState = .{},

    fn isViewActive(self: FakeSubagents) bool {
        return self.view_active;
    }

    fn childConversationRuntime(self: *FakeSubagents) ?*FakeShell {
        if (!self.view_active) return null;
        return &self.child_shell;
    }

    fn activeRenderRequests(self: *FakeSubagents) *render_request.RenderRequestState {
        return &self.child_render_requests;
    }

    fn deinit(self: *FakeSubagents, alloc: std.mem.Allocator) void {
        self.child_shell.deinit(alloc);
    }
};

const FakeApp = struct {
    alloc: std.mem.Allocator,
    main_agent: struct {
        question_prompt: FakeQuestionPrompt = .{},
        session_persistence: app_session_runtime.Persistence = .{},
        worker: FakeWorker = .{},
        stream: types.StreamState = .{},
    } = .{},
    input_runtime: InputRuntime = .{},
    shell: FakeShell = .{},
    pacer: FakePacer = .{},
    subagents: FakeSubagents = .{},
    should_exit: bool = false,
    frame_commits: usize = 0,
    transcript: std.ArrayList(u8) = .empty,
    replaceable_count: usize = 0,
    replaceable_silent_count: usize = 0,
    replace_count: usize = 0,
    replace_silent_count: usize = 0,
    last_class: transcript_runtime.RawEntryClass = .unknown_raw,
    attention_count: usize = 0,
    last_attention_turn_id: u64 = 0,
    last_attention_kind: ?@import("../hooks/hooks.zig").AttentionKind = null,
    persisted_finishes: std.ArrayList(types.FinishedPrompt) = .empty,
    finish_persistence_error: ?anyerror = null,
    program_status: program_status.Reporter = .{},
    program_status_reports: std.ArrayList(u8) = .empty,
    program_status_capture_failed: bool = false,

    fn init(alloc: std.mem.Allocator) FakeApp {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *FakeApp) void {
        if (self.pacer.deferred_turn) |finished| types.freeFinishedPrompt(self.alloc, finished);
        for (self.persisted_finishes.items) |finished| types.freeFinishedPrompt(self.alloc, finished);
        self.persisted_finishes.deinit(self.alloc);
        self.program_status_reports.deinit(self.alloc);
        self.agent().session_persistence.deinit(self.alloc);
        self.agent().worker.deinit();
        self.input_runtime.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        self.subagents.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
    }

    fn pacerCallbacks(self: *FakeApp) void {
        _ = self;
    }

    pub fn appendFinishedPrompt(self: *FakeApp, finished: types.FinishedPrompt) !void {
        if (self.finish_persistence_error) |err| return err;
        const owned = try types.dupeFinishedPrompt(self.alloc, finished);
        errdefer types.freeFinishedPrompt(self.alloc, owned);
        try self.persisted_finishes.append(self.alloc, owned);
        if (finished.snapshot_file_ownership) |ownership| ownership.transfer();
    }

    fn writeTranscript(self: *FakeApp, text: []const u8, record: bool) !void {
        _ = record;
        try self.transcript.appendSlice(self.alloc, text);
    }

    fn writeDomainNotice(self: *FakeApp, notice: types.SemanticNotice, _: bool) !void {
        try self.transcript.appendSlice(self.alloc, notice.topic);
        try self.transcript.appendSlice(self.alloc, ":");
        try self.transcript.appendSlice(self.alloc, notice.body);
    }

    fn writeTranscriptClassified(self: *FakeApp, text: []const u8, record: bool, class: transcript_runtime.RawEntryClass) !void {
        self.last_class = class;
        try self.writeTranscript(text, record);
    }

    fn appendReplaceableTranscriptLine(self: *FakeApp, text: []const u8) !u32 {
        self.replaceable_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_count);
    }

    fn appendReplaceableTranscriptLineClassified(self: *FakeApp, text: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_class = class;
        return self.appendReplaceableTranscriptLine(text);
    }

    fn appendReplaceableTranscriptLineSilent(self: *FakeApp, text: []const u8) !u32 {
        self.replaceable_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_silent_count);
    }

    fn appendReplaceableTranscriptLineSilentClassified(self: *FakeApp, text: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_class = class;
        return self.appendReplaceableTranscriptLineSilent(text);
    }

    fn replaceTrailingTranscriptLine(self: *FakeApp, text: []const u8) !bool {
        self.replace_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }

    fn replaceTrailingTranscriptLineSilent(self: *FakeApp, text: []const u8) !bool {
        self.replace_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }

    pub fn dispatchAttentionRequired(
        self: *FakeApp,
        _: anytype,
        turn_id: u64,
        kind: @import("../hooks/hooks.zig").AttentionKind,
    ) void {
        self.attention_count += 1;
        self.last_attention_turn_id = turn_id;
        self.last_attention_kind = kind;
    }

    fn writeProgramStatus(self: *FakeApp, report: []const u8) void {
        self.program_status_reports.appendSlice(self.alloc, report) catch {
            self.program_status_capture_failed = true;
        };
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

fn expectProgramStatusReports(app: *FakeApp, expected: []const u8) !void {
    try std.testing.expect(!app.program_status_capture_failed);
    const reports = try app.program_status_reports.toOwnedSlice(app.alloc);
    defer app.alloc.free(reports);
    try std.testing.expectEqualStrings(expected, reports);
}

const NoopBridge = struct {
    fn user(_: *anyopaque, _: types.UserTurn) !void {}
    fn text(_: *anyopaque, _: []const u8) !void {}
    fn drain(_: *anyopaque) !AssistantTextDrainResult {
        return .drained;
    }
    fn openModelPicker(_: *anyopaque) !void {}
    fn notice(_: *anyopaque, _: types.SemanticNotice) !void {}
    fn output(_: *anyopaque, _: ?types.ToolLifecycleId, _: command_output_content.Stream, _: []const u8) !void {}
    fn outputComplete(_: *anyopaque, _: ?types.ToolLifecycleId) !void {}
    fn diff(_: *anyopaque, payload: @import("../output/diff.zig").DiffEntryPayload) !void {
        @import("../output/diff.zig").freeDiffEntryPayload(std.heap.c_allocator, payload);
    }
    fn history(_: *anyopaque, _: types.FinishedPrompt) !HistoryDelivery {
        return .{ .settled = .committed };
    }
    fn err(_: *anyopaque, _: types.SemanticNotice) !void {}

    fn lifecycleSnapshot(raw: *anyopaque) activity_runtime.LifecycleSnapshot {
        const app: *FakeApp = @ptrCast(@alignCast(raw));
        return .{
            .finalized_turn_watermark = app.shell.finalizedToolTurnWatermark(),
            .active_tool_count = app.shell.activeToolActivityCount(),
            .focused_entry_id = app.shell.focusedToolEntryId(),
            .focused_activity_kind = app.shell.focusedToolActivityKind(),
            .activity = app.shell.activityProjection(),
        };
    }

    fn lifecycleRecord(
        raw: *anyopaque,
        id: types.ToolLifecycleId,
    ) ?activity_runtime.ToolPresentationRecord {
        const app: *FakeApp = @ptrCast(@alignCast(raw));
        return app.shell.toolActivityRecord(id);
    }

    fn applyLifecycle(
        raw: *anyopaque,
        alloc: std.mem.Allocator,
        event: types.ToolLifecycleEvent,
    ) !activity_runtime.LifecycleTransition {
        const app: *FakeApp = @ptrCast(@alignCast(raw));
        const previous_focused_entry_id = app.shell.focusedToolEntryId();
        const applied_activity_kind = try app.shell.applyToolLifecycle(alloc, event);
        return .{
            .previous_focused_entry_id = previous_focused_entry_id,
            .snapshot = lifecycleSnapshot(raw),
            .applied_activity_kind = applied_activity_kind,
            .terminal_record = switch (event) {
                .terminal => |terminal| app.shell.toolActivityRecord(terminal.id),
                .provisional, .authoritative_started, .progress, .turn_finished => null,
            },
        };
    }

    fn finishLifecycleBatch(raw: *anyopaque, alloc: std.mem.Allocator) !void {
        const app: *FakeApp = @ptrCast(@alignCast(raw));
        try app.shell.finishLifecycleBatch(alloc);
    }

    fn lifecyclePresenter(app: *FakeApp) activity_runtime.LifecyclePresenter {
        return .{
            .ctx = @ptrCast(app),
            .snapshot_fn = lifecycleSnapshot,
            .record_fn = lifecycleRecord,
            .apply_fn = applyLifecycle,
            .finish_batch_fn = finishLifecycleBatch,
        };
    }

    fn handlers(app: *FakeApp) WorkerEventHandlers {
        return .{
            .ctx = undefined,
            .tool_lifecycle = lifecyclePresenter(app),
            .write_user_prompt = user,
            .append_text = text,
            .drain_assistant_text = drain,
            .open_model_picker = openModelPicker,
            .semantic_notice = notice,
            .command_output = output,
            .command_output_complete = outputComplete,
            .diff_block = diff,
            .append_history_turn = history,
            .error_text = err,
        };
    }
};

const PacedTranscriptBridge = struct {
    app: *FakeApp,
    pacer: assistant_pacer.AssistantPacer = .{},
    metrics: types.Metrics = .{},
    drain_count: usize = 0,
    user_prompt_count: usize = 0,
    pacer_pending_when_user_prompt_written: bool = false,
    assistant_present_when_user_prompt_written: bool = false,
    notice_count: usize = 0,
    history_count: usize = 0,
    finish_count: usize = 0,
    order: [8]u8 = undefined,
    order_len: usize = 0,
    emitted_bytes: usize = 0,
    held_call_lines: usize = 0,
    emitted_when_call_written: usize = 0,
    entries_when_call_written: usize = 0,

    fn init(app: *FakeApp) PacedTranscriptBridge {
        return .{ .app = app };
    }

    fn deinit(self: *PacedTranscriptBridge) void {
        self.pacer.deinit(self.app.alloc);
    }

    fn callbacks(self: *PacedTranscriptBridge) assistant_pacer.TickCallbacks {
        return .{
            .emit_ctx = @ptrCast(self),
            .emit_fn = emit,
            .finish_ctx = @ptrCast(self),
            .finish_fn = finish,
            .model_call_fn = writeHeldCall,
        };
    }

    fn handlers(self: *PacedTranscriptBridge) WorkerEventHandlers {
        var bridge = NoopBridge.handlers(self.app);
        bridge.ctx = @ptrCast(self);
        bridge.write_user_prompt = writeUserPrompt;
        bridge.append_text = appendText;
        bridge.drain_assistant_text = drainAssistantText;
        bridge.hold_model_call = holdModelCall;
        bridge.semantic_notice = semanticNotice;
        bridge.append_history_turn = appendHistoryTurn;
        return bridge;
    }

    fn tickPacer(self: *PacedTranscriptBridge, now_ns: i128) !void {
        try self.pacer.tick(self.app.alloc, now_ns, self.callbacks());
    }

    fn record(self: *PacedTranscriptBridge, value: u8) void {
        if (self.order_len < self.order.len) {
            self.order[self.order_len] = value;
            self.order_len += 1;
        }
    }

    fn orderSlice(self: *const PacedTranscriptBridge) []const u8 {
        return self.order[0..self.order_len];
    }

    fn appendText(raw: *anyopaque, text: []const u8) !void {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        try self.pacer.enqueue(self.app.alloc, text);
    }

    fn writeUserPrompt(raw: *anyopaque, _: types.UserTurn) !void {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        self.user_prompt_count += 1;
        self.record('U');
        self.pacer_pending_when_user_prompt_written = self.pacer.hasPending();
        self.assistant_present_when_user_prompt_written =
            self.app.shell.lifecycle.notebook.entries.items.len > 0 and
            self.app.shell.lifecycle.notebook.entries.items[self.app.shell.lifecycle.notebook.entries.items.len - 1] == .assistant_turn;
    }

    fn drainAssistantText(raw: *anyopaque) !AssistantTextDrainResult {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        self.drain_count += 1;
        try self.pacer.flushPresentationAtBoundary(
            self.app.alloc,
            0,
            self.callbacks(),
        );
        return .drained;
    }

    fn semanticNotice(raw: *anyopaque, _: types.SemanticNotice) !void {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        self.notice_count += 1;
    }

    fn appendHistoryTurn(raw: *anyopaque, finished: types.FinishedPrompt) !HistoryDelivery {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        self.history_count += 1;
        if (try self.pacer.deferFinish(self.app.alloc, finished)) return .retained;
        self.finish_count += 1;
        return .{ .settled = .committed };
    }

    fn holdModelCall(raw: *anyopaque, call: types.ModelCallRecord) !bool {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        return self.pacer.holdModelCall(self.app.alloc, call);
    }

    fn writeHeldCall(raw: *anyopaque, _: types.ModelCallRecord) !void {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        self.held_call_lines += 1;
        self.emitted_when_call_written = self.emitted_bytes;
        self.entries_when_call_written = self.app.shell.lifecycle.notebook.entries.items.len;
    }

    fn emit(raw: *anyopaque, text: []const u8) !void {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        self.emitted_bytes += text.len;
        _ = try self.app.shell.lifecycle.streamAssistantChunk(
            self.app.alloc,
            &self.metrics,
            text,
        );
    }

    fn finish(raw: *anyopaque, _: types.FinishedPrompt) !assistant_pacer.FinishResult {
        const self: *PacedTranscriptBridge = @ptrCast(@alignCast(raw));
        self.finish_count += 1;
        self.record('F');
        return .committed;
    }
};

fn tickNoop(app: *FakeApp) !void {
    try Runtime(FakeApp).tick(app, app.agent(), NoopBridge.handlers(app));
}

const testRecoveryText = types.testRecoveryText;

fn testWaitingStatus(attempt: usize) types.RouteRecoveryStatus {
    return .{
        .kind = .waiting,
        .text = testRecoveryText("Connection lost · next try in 4s · attempt 1 · 3s"),
        .attempt = attempt,
    };
}

fn queueLifecycle(app: *FakeApp, event: types.ToolLifecycleEvent) !void {
    try app.agent().worker.pushEvent(std.heap.c_allocator, .{ .tool_lifecycle = event });
}

fn queueToolStart(
    app: *FakeApp,
    turn_id: u64,
    call_id: []const u8,
    tool_name: []const u8,
) !void {
    try queueLifecycle(app, .{ .authoritative_started = .{
        .id = .{ .turn_id = turn_id, .call_id = call_id },
        .reconciles_provisional_call_id = null,
        .tool_name = tool_name,
        .activity_kind = if (std.mem.eql(u8, tool_name, "read_file"))
            .read
        else if (std.mem.eql(u8, tool_name, "write_file"))
            .write
        else
            .command,
    } });
}

fn queueToolTerminal(
    app: *FakeApp,
    turn_id: u64,
    call_id: []const u8,
    kind: types.ToolOutcomeKind,
    summary: []const u8,
) !void {
    try queueLifecycle(app, .{ .terminal = .{
        .id = .{ .turn_id = turn_id, .call_id = call_id },
        .outcome = .{ .kind = kind, .summary = summary },
    } });
}

fn queueTurnFinished(
    app: *FakeApp,
    turn_id: u64,
    outcome: types.TurnPresentationOutcome,
) !void {
    try queueLifecycle(app, .{ .turn_finished = .{
        .turn_id = turn_id,
        .outcome = outcome,
    } });
}

const test_held_call: types.ModelCallRecord = .{
    .at_ms = 1_000,
    .elapsed_ms = 900,
    .provider = "gateway",
    .model = "openai/gpt-5.4",
    .generation_id = "gen_held",
};

const BudgetCapture = struct {
    texts: std.ArrayList([]const u8) = .empty,
    prompts: usize = 0,

    fn deinit(self: *BudgetCapture) void {
        for (self.texts.items) |shown| std.testing.allocator.free(shown);
        self.texts.deinit(std.testing.allocator);
    }

    fn text(raw: *anyopaque, value: []const u8) !void {
        const self: *BudgetCapture = @ptrCast(@alignCast(raw));
        try self.texts.append(std.testing.allocator, try std.testing.allocator.dupe(u8, value));
    }

    fn prompt(raw: *anyopaque, _: types.UserTurn) !void {
        const self: *BudgetCapture = @ptrCast(@alignCast(raw));
        self.prompts += 1;
    }

    fn handlers(self: *BudgetCapture, app: *FakeApp) WorkerEventHandlers {
        var value = NoopBridge.handlers(app);
        value.ctx = @ptrCast(self);
        value.append_text = text;
        value.write_user_prompt = prompt;
        return value;
    }

    fn joined(self: *const BudgetCapture) ![]u8 {
        return std.mem.join(std.testing.allocator, ",", self.texts.items);
    }
};

const BudgetEvent = union(enum) {
    phase: u64,
    text: []const u8,
    prompt: []const u8,
    finished: struct { turn_id: u64, outcome: types.TurnPresentationOutcome },
};

fn queueBudgetEvents(app: *FakeApp, events: []const BudgetEvent) !void {
    for (events) |event| switch (event) {
        .phase => |turn_id| try app.main_agent.worker.pushEvent(std.heap.c_allocator, .{ .turn_phase_update = .{
            .turn_id = turn_id,
            .step_id = 1,
            .phase = .generating,
        } }),
        .text => |value| try app.main_agent.worker.pushEvent(std.heap.c_allocator, .{ .assistant_presentation = .{
            .text = @constCast(value),
        } }),
        .prompt => |value| try app.main_agent.worker.pushEvent(std.heap.c_allocator, .{ .begin_prompt = .{ .text = @constCast(value) } }),
        .finished => |finished| try queueTurnFinished(app, finished.turn_id, finished.outcome),
    };
}

/// Drains `events` once unbounded and once one event per tick (budget 0),
/// returning both texts shown so a test can compare them.
fn expectBudgetMatchesUnbounded(
    events: []const BudgetEvent,
    cancelled_active_turn: ?u64,
    expected_texts: []const u8,
) !void {
    var results: [2][]u8 = undefined;
    var filled: usize = 0;
    defer for (results[0..filled]) |value| std.testing.allocator.free(value);
    for ([_]bool{ false, true }) |bounded| {
        var app = FakeApp.init(std.testing.allocator);
        defer app.deinit();
        if (cancelled_active_turn) |turn_id| {
            app.main_agent.worker.active_turn_id = turn_id;
            app.main_agent.worker.worker_cancel_requested.store(true, .seq_cst);
        }
        var capture = BudgetCapture{};
        defer capture.deinit();
        try queueBudgetEvents(&app, events);
        if (bounded) {
            var ticks: usize = 0;
            while (app.main_agent.worker.events.items.len > 0) : (ticks += 1) {
                try std.testing.expect(ticks < events.len * 2 + 2);
                try Runtime(FakeApp).tickWithinBudget(&app, (&app).agent(), capture.handlers(&app), 0);
            }
        } else {
            try Runtime(FakeApp).tick(&app, (&app).agent(), capture.handlers(&app));
        }
        results[filled] = try capture.joined();
        filled += 1;
    }
    try std.testing.expectEqualStrings(expected_texts, results[0]);
    try std.testing.expectEqualStrings(results[0], results[1]);
}

const GateApp = struct {
    alloc: std.mem.Allocator,
    pacer: assistant_pacer.AssistantPacer = .{},
    main_agent: struct {
        total_input_tokens: u64 = 0,
        total_output_tokens: u64 = 0,
        session: @import("../session/session.zig").SessionRuntime = .{ .max_history_turns = 8 },
        session_persistence: app_session_runtime.Persistence = .{},
        worker: worker_runtime.WorkerRuntime = .{},
    } = .{},

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }

    fn pushFinish(self: *GateApp, answer: []const u8) !void {
        const turn: types.HistoryTurn = .{ .assistant = .{ .user = .{ .text = @constCast("prompt") }, .assistant = @constCast(answer) } };
        try self.agent().worker.pushEvent(std.heap.c_allocator, .{ .finish_prompt = .{ .turn = turn } });
    }

    /// What the loop does with the events it took: applies them, here by dropping them.
    fn takeAndDrop(self: *GateApp) void {
        var events = self.agent().worker.takeEvents();
        for (events.items) |event| worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
        events.deinit(std.heap.c_allocator);
    }
};

/// An app whose pacer shows text into `emitted`, and whose finish callback
/// acknowledges the commit the way `appendFinishedPrompt` does.
const FlushApp = struct {
    alloc: std.mem.Allocator,
    pacer: assistant_pacer.AssistantPacer = .{},
    main_agent: struct {
        total_input_tokens: u64 = 0,
        total_output_tokens: u64 = 0,
        session: @import("../session/session.zig").SessionRuntime = .{ .max_history_turns = 8 },
        session_persistence: app_session_runtime.Persistence = .{},
        worker: worker_runtime.WorkerRuntime = .{},
    } = .{},
    emitted: std.ArrayList(u8) = .empty,
    emit_attempts: usize = 0,
    fail_emit: bool = false,
    /// The commit acknowledges, as `appendFinishedPrompt` does in a `defer`,
    /// and then fails.
    fail_commit: bool = false,
    commits: usize = 0,

    const finished_turn: types.HistoryTurn = .{ .assistant = .{ .user = .{ .text = @constCast("prompt") }, .assistant = @constCast("answer") } };

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }

    fn deinit(self: *FlushApp) void {
        self.agent().session_persistence.deinit(self.alloc);
        self.agent().session.deinit(self.alloc);
        self.agent().worker.deinit(std.heap.c_allocator);
        self.pacer.deinit(self.alloc);
        self.emitted.deinit(self.alloc);
    }

    fn pacerCallbacks(self: *FlushApp) assistant_pacer.TickCallbacks {
        return .{ .emit_ctx = self, .emit_fn = FlushApp.emit, .finish_ctx = self, .finish_fn = FlushApp.finish };
    }

    fn emit(ctx: *anyopaque, text: []const u8) anyerror!void {
        const self: *FlushApp = @ptrCast(@alignCast(ctx));
        self.emit_attempts += 1;
        if (self.fail_emit) return error.BrokenPipe;
        try self.emitted.appendSlice(self.alloc, text);
    }

    fn finish(ctx: *anyopaque, _: types.FinishedPrompt) anyerror!assistant_pacer.FinishResult {
        const self: *FlushApp = @ptrCast(@alignCast(ctx));
        self.commits += 1;
        self.agent().worker.acknowledgeFinishCommitted();
        if (self.fail_commit) return error.OutOfMemory;
        return .committed;
    }

    /// The request of a report or of typed text, as the worker queues it.
    fn queuedRequest(gpa: std.mem.Allocator, prompt: []const u8) !worker_runtime.QueuedPrompt {
        return .{
            .prompt = try gpa.dupe(u8, prompt),
            .images = &.{},
            .model = try gpa.dupe(u8, "test-model"),
            .api_key = try gpa.dupe(u8, "test-key"),
            .permission_mode = .yolo,
            .history = try gpa.alloc(types.HistoryTurn, 0),
        };
    }

    /// The pacer is still showing `shown` of a turn, and keeps that turn's
    /// finish behind it, as an open prompt makes it.
    fn pacerHoldsFinishedTurn(self: *FlushApp, shown: []const u8) !void {
        try self.pacer.enqueue(self.alloc, shown);
        try std.testing.expect(try Runtime(FlushApp).deferFinish(self, self.agent(), .{ .turn = finished_turn }));
    }

    /// The worker finished a turn that a report missed, and the loop took the
    /// finish into its pacer, which a prompt keeps from showing it.
    fn finishedTurnWithMailBehindOpenPrompt(self: *FlushApp, shown: []const u8) !void {
        const gpa = std.heap.c_allocator;
        const worker = &self.agent().worker;
        worker.enableCommitGate();
        worker.worker_processing = true;
        worker.active_turn_id = 9;
        worker.direct_steering_closed = true;
        try worker.pushEvent(gpa, .{ .finish_prompt = .{ .turn = finished_turn } });
        try worker.postMail(gpa, try queuedRequest(gpa, "a report"));
        try std.testing.expect(worker.queued_prompts.items[0].delivery.isContinuation());
        worker.finishProcessing();
        self.dropWorkerEvents();
        try self.pacerHoldsFinishedTurn(shown);
    }

    /// The loop took the worker's events, as its pass does before it hands a
    /// finish to the pacer.
    fn dropWorkerEvents(self: *FlushApp) void {
        const gpa = std.heap.c_allocator;
        var events = self.agent().worker.takeEvents();
        for (events.items) |event| worker_runtime.freeWorkerEvent(gpa, event);
        events.deinit(gpa);
    }

    /// The next turn's finish: the pacer's old text is gone, the worker has a
    /// second finish, and the loop takes it into the pacer behind the prompt.
    fn secondFinishBehindPacer(self: *FlushApp, shown: []const u8) !void {
        self.pacer.clear(self.alloc);
        try self.agent().worker.pushEvent(std.heap.c_allocator, .{ .finish_prompt = .{ .turn = finished_turn } });
        self.dropWorkerEvents();
        try self.pacerHoldsFinishedTurn(shown);
    }
};
