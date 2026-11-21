const std = @import("std");
const testing_allocator = @import("../../../shared/testing_allocator.zig");
const types = @import("../../../shared/types.zig");
const debug_trace = @import("../../../shared/debug_trace.zig");
const io_mod = @import("../../../shared/io.zig");
const tool_result_errors = @import("../../../tooling/tool_result_errors.zig");
const lifecycle_hooks = @import("../../../hooks/hooks.zig");
const session_runtime = @import("../../../session/session.zig");
const worker_runtime = @import("../../worker_runtime.zig");

const test_support = @import("support.zig");
const runtime_finalization = @import("../finalization.zig");
const runtime_orchestrator = @import("../orchestrator.zig");
const runtime_telemetry = @import("../telemetry.zig");

const ChatMessage = types.ChatMessage;
const ToolCall = types.ToolCall;
const TurnFinalizationGuard = runtime_finalization.TurnFinalizationGuard;
const PromptFinishTrace = runtime_finalization.PromptFinishTrace;
const TurnSummaryAccumulator = runtime_telemetry.TurnSummaryAccumulator;
const CommonStopState = runtime_orchestrator.CommonStopState;
const copyLatestStopPartial = runtime_orchestrator.copyLatestStopPartial;

const FakeCompletion = test_support.FakeCompletion;
const FakeGateway = test_support.FakeGateway;
const FakeAgentRuntimeDeps = test_support.FakeAgentRuntimeDeps;
const FakeExecPlan = test_support.FakeExecPlan;
const PromptFixture = test_support.PromptFixture;
const StopTestHandler = test_support.StopTestHandler;

const runFakePrompt = test_support.runFakePrompt;
const runFakePromptWithLifecycle = test_support.runFakePromptWithLifecycle;
const registerStopTestHandler = test_support.registerStopTestHandler;
const testLifecycleContext = test_support.testLifecycleContext;
const finishCommonAssistantTerminal = runtime_orchestrator.finishCommonAssistantTerminal;
const expectBodyContains = test_support.expectBodyContains;
const expectBodyContainsInOrder = test_support.expectBodyContainsInOrder;
const expectBodyNotContains = test_support.expectBodyNotContains;
const countText = test_support.countText;
const countNeedle = test_support.countNeedle;
const readTraceFile = test_support.readTraceFile;
const textContains = test_support.textContains;
const logIndex = test_support.logIndex;
const toolCall = test_support.toolCall;

const PostTurnEndFinalizationCapture = struct {
    calls: usize = 0,
    turn_ids: [8]u64 = undefined,
    scope_kinds: [8]lifecycle_hooks.ScopeKind = undefined,
    workspace_matches: [8]bool = undefined,
    outcomes: [8]types.TurnPresentationOutcome = undefined,
    dispositions: [8]?types.ProviderCompletionDisposition = undefined,
    finish_event_attempts: [8]usize = undefined,
    deps: ?*FakeAgentRuntimeDeps = null,

    fn run(raw: *anyopaque, input: lifecycle_hooks.PostTurnEndInput) lifecycle_hooks.HandlerError!void {
        const self: *PostTurnEndFinalizationCapture = @ptrCast(@alignCast(raw));
        const index = self.calls;
        self.calls += 1;
        self.turn_ids[index] = input.invocation.turn_id orelse 0;
        self.scope_kinds[index] = input.invocation.scope.kind;
        self.workspace_matches[index] = std.mem.eql(
            u8,
            input.invocation.scope.workspace_root,
            "/tmp/workspace",
        );
        self.outcomes[index] = input.outcome;
        self.dispositions[index] = input.provider_disposition;
        self.finish_event_attempts[index] = if (self.deps) |deps|
            deps.finish_event_attempt_count
        else
            0;
    }
};

test "processQueuedPrompt preserves original final history before finish event" {
    const alloc = std.testing.allocator;
    const chunks = [_][]const u8{" **Hello** "};
    const completions = [_]FakeCompletion{.{
        .chunks = &chunks,
        .content = " **Hello** ",
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqualStrings(" **Hello** ", hooks.history_assistant_text.?);
    try std.testing.expectEqualStrings(" **Hello** ", hooks.finish_assistant_text.?);
    try std.testing.expectEqual(@as(?types.TurnPresentationOutcome, .completed), hooks.finish_terminal_outcome);
    const newline_idx = logIndex(&hooks, "text:newline").?;
    const finish_idx = logIndex(&hooks, "event:finish_prompt").?;
    try std.testing.expect(newline_idx < finish_idx);
    try expectBodyNotContains(&gateway, 0, "<turn_aborted>");
}

/// A prompt the worker owns, allocated the way its queue frees it.
fn ownedWorkerPrompt(alloc: std.mem.Allocator, text: []const u8) !worker_runtime.QueuedPrompt {
    return .{
        .prompt = try alloc.dupe(u8, text),
        .images = &.{},
        .model = try alloc.dupe(u8, "provider/model"),
        .api_key = try alloc.dupe(u8, "key"),
        .permission_mode = .yolo,
        .history = try alloc.alloc(types.HistoryTurn, 0),
    };
}

/// A Stop hook during whose first run the user submits a steer, admitted the
/// way the terminal admits a prompt typed while a turn runs.
const SteerDuringStop = struct {
    alloc: std.mem.Allocator,
    worker: *worker_runtime.WorkerRuntime,
    calls: usize = 0,

    fn run(
        raw: *anyopaque,
        _: lifecycle_hooks.StopInput,
    ) lifecycle_hooks.HandlerError!lifecycle_hooks.StopAction {
        const self: *SteerDuringStop = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.calls == 1) {
            const steer = ownedWorkerPrompt(self.alloc, "also check the docs") catch return error.Failed;
            self.worker.admitInteractivePrompt(self.alloc, steer) catch {
                worker_runtime.freeQueuedPrompt(self.alloc, steer);
                return error.Failed;
            };
        }
        return .allow;
    }
};
