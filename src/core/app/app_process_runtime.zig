const std = @import("std");
const agents = @import("../agents/agents.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const image_attachments = @import("../images/image_attachments.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const types = @import("../shared/types.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const config_runtime = @import("../config/config_runtime.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const compaction_activity = @import("../output/compaction_activity.zig");
const compactor = @import("../compactor/compactor.zig");

fn compactionErrorHandled(work: worker_runtime.WorkItem, provenance: ?compaction_activity.ErrorProvenance, err: anyerror) bool {
    const failure = provenance orelse return false;
    if (failure.err != err) return false;
    return switch (work) {
        .prompt => |job| failure.turn_id == job.turn_id,
        .compact_context => |task| failure.turn_id == task.turn_id and task.operation_id == failure.operation_id,
    };
}

fn settleCompactionWorkFailure(worker: *worker_runtime.WorkerRuntime, work: worker_runtime.WorkItem, err: anyerror) void {
    switch (work) {
        .compact_context => |task| if (task.operation_id) |id| {
            worker.settleCompactionActivity(id, compaction_activity.failure(err, .preparation, worker.isCancelRequested()));
        },
        .prompt => {},
    }
}

/// Whether `App` runs its agent on the main loop, without worker threads.
pub fn cooperativeHost(comptime App: type) bool {
    return @hasDecl(App, "host_profile") and App.host_profile.cooperative_agent;
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        pub fn startWorkerThread(app: *App, agent: *AppAgent) !void {
            enableCommitGate(agent);
            agent.worker_thread = try std.Thread.spawn(.{}, workerThreadMain, .{app});
        }

        /// The main loop commits each finished turn of a threaded agent
        /// (`app_session_runtime.zig` appendFinishedPrompt) and says so, so
        /// the agent's next turn from mail waits for that commit
        /// (`WorkerRuntime.enableCommitGate`). A cooperative host starts no
        /// thread here and keeps the old order.
        fn enableCommitGate(agent: anytype) void {
            if (comptime @hasField(@TypeOf(agent.*), "worker") and
                @hasDecl(@TypeOf(agent.worker), "enableCommitGate"))
            {
                agent.worker.enableCommitGate();
            }
        }

        /// Starts `agent`'s own worker thread, which runs main's worker loop
        /// for that agent's conversation. A cooperative host runs no agent
        /// threads, so it hosts only its first agent.
        pub fn startAgentWorkerThread(app: *App, agent: *agents.Agent) !void {
            if (comptime cooperativeHost(App)) return error.AgentThreadsUnavailable;
            enableCommitGate(agent);
            agent.worker_thread = try std.Thread.spawn(.{}, agentWorkerThreadMain, .{ app, agent });
        }

        /// Starts one queued prompt on a single-threaded host. Prompt admission
        /// is presented before agent work can suspend on host transport.
        pub fn processNextCooperativePrompt(
            app: *App,
            agent: *AppAgent,
            event_handlers: app_worker_runtime.WorkerEventHandlers,
            flush_frame: *const fn (*App) anyerror!void,
        ) !void {
            const work = (try agent.worker.tryTakeNextWork(std.heap.c_allocator)) orelse return;
            defer worker_runtime.freeWorkItem(std.heap.c_allocator, work);
            defer agent.worker.finishProcessing();
            processCooperativeWork(app, agent, event_handlers, flush_frame, work) catch |err| {
                settleCompactionWorkFailure(&agent.worker, work, err);
                return err;
            };
        }

        fn processCooperativeWork(
            app: *App,
            agent: *AppAgent,
            event_handlers: app_worker_runtime.WorkerEventHandlers,
            flush_frame: *const fn (*App) anyerror!void,
            work: worker_runtime.WorkItem,
        ) !void {
            try app_worker_runtime.Runtime(App).tick(
                app,
                agent,
                event_handlers,
            );
            try flush_frame(app);

            var failure_provenance: ?compaction_activity.ErrorProvenance = null;
            app.processQueuedWork(agent, work, &failure_provenance) catch |err| {
                settleCompactionWorkFailure(&agent.worker, work, err);
                if (compactionErrorHandled(work, failure_provenance, err)) {
                    compactor.traceLog(true, "interactive error retained err={s}", .{@errorName(err)});
                } else if (err != error.RouteRecoveryStopped) {
                    const body = try formatErrorBody(std.heap.c_allocator, "request failed", err);
                    defer std.heap.c_allocator.free(body);
                    try agent.worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
                        .topic = "system",
                        .tone = .@"error",
                        .body = body,
                    } });
                }
            };
        }

        pub fn formatToolExecutionError(alloc: std.mem.Allocator, tool_name: []const u8, err: anyerror) ![]u8 {
            const error_detail = detailedErrorSummary(err);
            const details: []const tool_result_errors.Detail = if (error_detail) |detail|
                &[_]tool_result_errors.Detail{
                    .{ .name = "error", .value = .{ .string = @errorName(err) } },
                    .{ .name = "detail", .value = .{ .string = detail } },
                }
            else
                &[_]tool_result_errors.Detail{
                    .{ .name = "error", .value = .{ .string = @errorName(err) } },
                };

            return tool_result_errors.toolExecutionFailureJson(alloc, .{
                .tool_name = tool_name,
                .message = if (error_detail != null) "Tool execution failed while parsing or preparing data" else "Tool execution failed",
                .details = details,
                .suggestion = suggestionForError(err),
            });
        }

        fn detailedErrorSummary(err: anyerror) ?[]const u8 {
            return switch (err) {
                error.StreamInterrupted => "provider response ended before completion",
                error.UnexpectedEndOfInput => "incomplete JSON or internal response while parsing data",
                error.SyntaxError => "invalid JSON syntax while parsing data",
                error.MissingField => "required field missing while parsing data",
                error.InvalidEnumTag => "invalid enum value while parsing data",
                error.UnknownField => "unexpected field while parsing data",
                error.ImageTooLarge => image_attachments.image_too_large_notice,
                error.McpInputTimedOut => tool_result_errors.executionErrorMessage(err),
                else => null,
            };
        }

        fn suggestionForError(err: anyerror) ?[]const u8 {
            return switch (err) {
                error.UnexpectedEndOfInput, error.SyntaxError => "Check that the tool arguments are valid JSON and retry with corrected input.",
                error.MissingField => "Add the required input field named by the tool schema, then retry.",
                error.InvalidEnumTag, error.UnknownField => "Compare the input fields with the tool schema and retry with supported values.",
                error.ImageTooLarge => "Use a smaller image or reduce the image before retrying.",
                error.McpInputTimedOut => tool_result_errors.executionErrorSuggestion(err),
                else => null,
            };
        }

        /// The notice for an error, in plain words. The raw error name goes
        /// only to the trace.
        fn formatErrorBody(alloc: std.mem.Allocator, context: []const u8, err: anyerror) ![]u8 {
            debug_trace.logf("worker", "error notice context={s} err={s}", .{ context, @errorName(err) });
            switch (err) {
                error.ConnectionSetupTimedOut => return alloc.dupe(u8, "Connection setup timed out after 30 seconds."),
                error.TlsInitializationFailed => return alloc.dupe(u8, "Couldn't make a secure connection."),
                error.ModelImageCapabilityUnavailable => return alloc.dupe(u8, image_attachments.model_image_capability_unavailable_notice),
                else => {},
            }
            if (try config_runtime.configuredProviderMessage(alloc, err)) |message| {
                defer alloc.free(message);
                return alloc.print("{s}: {s}", .{ context, message });
            }
            if (detailedErrorSummary(err)) |detail| {
                return alloc.print("{s}: {s}", .{ context, detail });
            }
            var words: [128]u8 = undefined;
            return alloc.print("{s}: {s}", .{ context, types.plainErrorText(@errorName(err), &words) });
        }

        fn workerThreadMain(app: *App) void {
            // This thread runs main's turns.
            runWorkerLoop(app, &app.main_agent);
        }

        fn agentWorkerThreadMain(app: *App, agent: *agents.Agent) void {
            runWorkerLoop(app, agent);
        }

        fn runWorkerLoop(app: *App, agent: *AppAgent) void {
            workerLoop(app, agent) catch |err| {
                const body = formatErrorBody(std.heap.c_allocator, "worker loop crashed", err) catch return;
                defer std.heap.c_allocator.free(body);
                agent.worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
                    .topic = "system",
                    .tone = .@"error",
                    .body = body,
                } }) catch return;
            };
        }

        fn workerLoop(app: *App, agent: *AppAgent) !void {
            while (true) {
                const work = (try agent.worker.waitAndTakeNextWork(std.heap.c_allocator)) orelse return;

                defer worker_runtime.freeWorkItem(std.heap.c_allocator, work);
                defer agent.worker.finishProcessing();
                var failure_provenance: ?compaction_activity.ErrorProvenance = null;
                app.processQueuedWork(agent, work, &failure_provenance) catch |err| {
                    settleCompactionWorkFailure(&agent.worker, work, err);
                    if (compactionErrorHandled(work, failure_provenance, err)) {
                        compactor.traceLog(true, "interactive error retained err={s}", .{@errorName(err)});
                    } else if (err != error.RouteRecoveryStopped) {
                        const body = try formatErrorBody(std.heap.c_allocator, "request failed", err);
                        defer std.heap.c_allocator.free(body);
                        try agent.worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
                            .topic = "system",
                            .tone = .@"error",
                            .body = body,
                        } });
                    }
                };
            }
        }
    };
}

test "compaction activity error routing requires exact operation and turn provenance" {
    const id: compaction_activity.OperationId = @fromBackingInt(@intCast(1));
    const task: worker_runtime.WorkItem = .{ .compact_context = .{
        .operation_id = id,
        .turn_id = 7,
        .model = @constCast("model"),
        .api_key = @constCast("fixture"),
        .history = &.{},
    } };
    const provenance: compaction_activity.ErrorProvenance = .{ .operation_id = id, .turn_id = 7, .err = error.ModelFailed };
    try std.testing.expect(compactionErrorHandled(task, provenance, error.ModelFailed));
    try std.testing.expect(!compactionErrorHandled(task, null, error.ModelFailed));
    try std.testing.expect(!compactionErrorHandled(task, provenance, error.OutOfMemory));
    var stale = provenance;
    stale.operation_id = @fromBackingInt(@intCast(2));
    try std.testing.expect(!compactionErrorHandled(task, stale, provenance.err));
    stale = provenance;
    stale.turn_id = 8;
    try std.testing.expect(!compactionErrorHandled(task, stale, provenance.err));
    const prompt: worker_runtime.WorkItem = .{ .prompt = .{
        .turn_id = 7,
        .prompt = @constCast("next"),
        .images = &.{},
        .model = @constCast("model"),
        .api_key = @constCast("fixture"),
        .permission_mode = .yolo,
        .history = &.{},
    } };
    try std.testing.expect(compactionErrorHandled(prompt, provenance, provenance.err));
    try std.testing.expect(!compactionErrorHandled(prompt, stale, provenance.err));
    // An unrelated error of even the same error set has no call-scoped provenance.
    try std.testing.expect(!compactionErrorHandled(prompt, null, provenance.err));
}

const DummyApp = struct {
    main_agent: struct {
        worker: ?void = null,
        worker_thread: ?std.Thread = null,
    } = .{},

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

const TestWorkerApp = struct {
    main_agent: struct {
        worker: worker_runtime.WorkerRuntime = .{},
        worker_thread: ?std.Thread = null,
    } = .{},
    first_process_error: ?anyerror = null,
    shutdown_after_count: usize = 1,
    processed_count: usize = 0,
    successful_count: usize = 0,
    saw_recovery_prompt: bool = false,

    fn deinit(self: *TestWorkerApp) void {
        if (self.agent().worker_thread) |thread| {
            self.agent().worker.requestShutdown();
            thread.join();
            self.agent().worker_thread = null;
        }
        self.agent().worker.deinit(std.heap.c_allocator);
    }

    fn processQueuedWork(self: *TestWorkerApp, _: anytype, work: worker_runtime.WorkItem, _: *?compaction_activity.ErrorProvenance) !void {
        self.processed_count += 1;
        if (self.processed_count >= self.shutdown_after_count) self.agent().worker.requestShutdown();
        if (self.processed_count == 1) {
            if (self.first_process_error) |err| return err;
        }
        self.successful_count += 1;
        self.saw_recovery_prompt = switch (work) {
            .prompt => |job| std.mem.eql(u8, job.prompt, "recovery"),
            .compact_context => false,
        };
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

fn makeQueuedPrompt(alloc: std.mem.Allocator, text: []const u8) !worker_runtime.QueuedPrompt {
    return .{
        .prompt = try alloc.dupe(u8, text),
        .images = &.{},
        .model = try alloc.dupe(u8, "test-model"),
        .api_key = try alloc.dupe(u8, "test-key"),
        .permission_mode = .yolo,
        .history = try alloc.alloc(types.HistoryTurn, 0),
    };
}

fn queuePrompt(app: *TestWorkerApp, text: []const u8) !void {
    const prompt = try makeQueuedPrompt(std.heap.c_allocator, text);
    errdefer worker_runtime.freeQueuedPrompt(std.heap.c_allocator, prompt);
    try app.agent().worker.enqueuePrompt(std.heap.c_allocator, prompt);
}
