const std = @import("std");
const testing_allocator = @import("../../../shared/testing_allocator.zig");
const builtin = @import("builtin");
const builtin_context = @import("../../../../builtins/context.zig");
const builtin_tools = @import("../../../../builtins/tools.zig");
const types = @import("../../../shared/types.zig");
const worker_runtime = @import("../../worker_runtime.zig");
const session_runtime = @import("../../../session/session.zig");
const session_codec = @import("../../../session/session_codec.zig");
const session_child_store = @import("../../../session/session_child_store.zig");
const result_store = @import("../../../session/result_store.zig");
const debug_trace = @import("../../../shared/debug_trace.zig");
const image_attachments = @import("../../../images/image_attachments.zig");
const io_mod = @import("../../../shared/io.zig");
const diff = @import("../../../output/diff.zig");
const file_mutation = @import("../../../tooling/file_mutation.zig");
const command_result_mapping = @import("../../../tooling/command_result_mapping.zig");
const tool_dispatch = @import("../../../tooling/tool_dispatch.zig");
const model_tool_schema = @import("../../../tooling/model_tool_schema.zig");
const tool_specs = @import("../../../tooling/tool_specs.zig");
const tool_result_errors = @import("../../../tooling/tool_result_errors.zig");
const context_contract = @import("../../../workspace/context_contract.zig");
const diagnostics = @import("../../../workspace/diagnostics.zig");
const lifecycle_hooks = @import("../../../hooks/hooks.zig");
const runtime_parallel_execution = @import("../parallel_execution.zig");
const runtime_config = @import("../config.zig");
const runtime_lifecycle = @import("../lifecycle.zig");
const runtime_deps = @import("../deps.zig");
const runtime_orchestrator = @import("../orchestrator.zig");
const runtime_tool_admission = @import("../tool_admission.zig");
const runtime_tool_batch = @import("../tool_batch.zig");
const runtime_tool_contracts = @import("../tool_contracts.zig");
const runtime_tool_presentation = @import("../tool_presentation.zig");
const runtime_telemetry = @import("../telemetry.zig");
const command_admission = @import("../../../permissions/command_admission.zig");
const permissions = @import("../../../permissions/permissions.zig");

const test_support = @import("support.zig");
const text_utils = @import("../../../shared/text_utils.zig");

const ChatMessage = types.ChatMessage;
const ToolCall = types.ToolCall;

const FakeCompletion = test_support.FakeCompletion;
const FakeGateway = test_support.FakeGateway;
const FakeAgentRuntimeDeps = test_support.FakeAgentRuntimeDeps;
const PreToolUseTestHandler = test_support.PreToolUseTestHandler;
const PromptFixture = test_support.PromptFixture;

const runFakePrompt = test_support.runFakePrompt;
const runFakePromptWithLifecycle = test_support.runFakePromptWithLifecycle;
const registerPreToolUseTestHandler = test_support.registerPreToolUseTestHandler;
const testLifecycleContext = test_support.testLifecycleContext;
const prepareToolCallForLifecycle = runtime_lifecycle.prepareToolCallForLifecycle;
const expectBodyContains = test_support.expectBodyContains;
const expectBodyNotContains = test_support.expectBodyNotContains;
const expectBodyContainsInOrder = test_support.expectBodyContainsInOrder;
const countText = test_support.countText;
const countNeedle = test_support.countNeedle;
const readTraceFile = test_support.readTraceFile;
const logIndex = test_support.logIndex;
const textContains = test_support.textContains;
const toolCall = test_support.toolCall;

const vision_agent_test_tools = test_support.vision_agent_test_tools;
const VisionAgentToolRuntime = test_support.VisionAgentToolRuntime;

const PostEffectTerminalFailure = struct {
    effect_count: usize = 0,

    fn execute(
        raw: *anyopaque,
        _: runtime_tool_contracts.ToolExecutionRequest,
    ) !runtime_tool_contracts.ToolExecutionResult {
        const self: *PostEffectTerminalFailure = @ptrCast(@alignCast(raw));
        self.effect_count += 1;
        return error.OutOfMemory;
    }
};

const terminal_advertised_names = [_][]const u8{"shell"};
const terminal_advertised_functions = [_]model_tool_schema.FunctionSchema{builtin_tools.shell.model_schema};

fn makeOwnedVisionCatalog(
    alloc: std.mem.Allocator,
    dir: std.Io.Dir,
    image_id: usize,
) ![]types.ImageAttachment {
    try dir.writeFile(io_mod.getIo(), .{ .sub_path = "vision.png", .data = "\x89PNG\r\n\x1a\nimage bytes" });
    const catalog = try alloc.alloc(types.ImageAttachment, 1);
    errdefer alloc.free(catalog);
    const path = try io_mod.dirRealpathAlloc(alloc, dir, "vision.png");
    var path_owned = true;
    errdefer if (path_owned) alloc.free(path);
    const media_type = try alloc.dupe(u8, "image/png");
    var media_type_owned = true;
    errdefer if (media_type_owned) alloc.free(media_type);
    catalog[0] = .{ .id = image_id, .path = path, .media_type = media_type };
    path_owned = false;
    media_type_owned = false;
    errdefer types.freeImageAttachment(alloc, catalog[0]);
    const root = try io_mod.dirRealpathAlloc(alloc, dir, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.Io.Dir.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);
    try image_attachments.captureImageSnapshot(alloc, &catalog[0], snapshot_dir);
    return catalog;
}

const BlockingPromptRun = struct {
    gateway: *FakeGateway,
    hooks: *FakeAgentRuntimeDeps,
    config: runtime_config.Config,
    job: worker_runtime.QueuedPrompt,
    finished: *std.atomic.Value(bool),
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        runFakePrompt(self.gateway, self.hooks, self.config, self.job) catch |err| {
            self.failure = err;
        };
        self.finished.store(true, .seq_cst);
    }
};

fn waitForPermissionBarrier(
    waiting: *const std.atomic.Value(bool),
    finished: *const std.atomic.Value(bool),
) bool {
    while (!waiting.load(.seq_cst) and !finished.load(.seq_cst)) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    return waiting.load(.seq_cst);
}

fn executedToolCount(hooks: *FakeAgentRuntimeDeps) usize {
    hooks.execute_mutex.lockUncancelable(io_mod.getIo());
    defer hooks.execute_mutex.unlock(io_mod.getIo());
    return hooks.executed_names.items.len;
}

fn logContains(hooks: *const FakeAgentRuntimeDeps, needle: []const u8) bool {
    for (hooks.log.items) |entry| {
        if (std.mem.find(u8, entry, needle) != null) return true;
    }
    return false;
}

const FailingApplicableContext = struct {
    const Failure = enum {
        out_of_memory,
        no_space_left,
        write_failed,
    };

    var failure: Failure = .out_of_memory;
    var expected_target: []const u8 = "";
    var select_calls: usize = 0;
    var saw_expected_input = false;

    fn reset(next_failure: Failure, target: []const u8) void {
        failure = next_failure;
        expected_target = target;
        select_calls = 0;
        saw_expected_input = false;
    }

    fn gather(
        _: std.mem.Allocator,
        _: context_contract.InitialContextInput,
    ) context_contract.ProviderError!context_contract.ProviderContext {
        return .{};
    }

    fn select(
        _: std.mem.Allocator,
        input: context_contract.LaterContextInput,
    ) context_contract.ProviderError!context_contract.ProviderContext {
        select_calls += 1;
        saw_expected_input = input.targets.len == 1 and
            input.targets[0].kind == .file and
            std.mem.eql(u8, input.targets[0].path, expected_target) and
            input.delivered_sources.len == 0 and
            input.evaluated_endpoints.len == 0;
        return switch (failure) {
            .out_of_memory => error.OutOfMemory,
            .no_space_left => error.NoSpaceLeft,
            .write_failed => error.WriteFailed,
        };
    }

    fn appendStatic(
        _: context_contract.StaticContextInput,
        _: std.mem.Allocator,
        _: *std.ArrayList(ChatMessage),
    ) context_contract.ProviderError!void {}

    fn appendTransient(
        _: context_contract.TransientContextInput,
        _: std.mem.Allocator,
        _: *std.ArrayList(ChatMessage),
    ) context_contract.ProviderError!void {}

    const registry = context_contract.Registry{ .default_provider = .{
        .id = "test.failing_applicable_context",
        .gather_project_context_fn = gather,
        .select_applicable_project_context_fn = select,
        .append_static_fn = appendStatic,
        .append_transient_fn = appendTransient,
    } };
};

const ApplicableContextDelta = struct {
    const content = "SCOPED_CONTEXT_DELTA";
    const source = "/test/scoped/AGENTS.md";
    const endpoint = "/test/scoped";

    var expected_target: []const u8 = "";
    var cancel_flag: ?*std.atomic.Value(bool) = null;
    var select_calls: usize = 0;
    var saw_expected_input = false;

    fn reset(target: []const u8, maybe_cancel_flag: ?*std.atomic.Value(bool)) void {
        expected_target = target;
        cancel_flag = maybe_cancel_flag;
        select_calls = 0;
        saw_expected_input = false;
    }

    fn gather(
        _: std.mem.Allocator,
        _: context_contract.InitialContextInput,
    ) context_contract.ProviderError!context_contract.ProviderContext {
        if (cancel_flag) |flag| flag.store(true, .seq_cst);
        return .{};
    }

    fn select(
        alloc: std.mem.Allocator,
        input: context_contract.LaterContextInput,
    ) context_contract.ProviderError!context_contract.ProviderContext {
        select_calls += 1;
        saw_expected_input = input.targets.len == 1 and
            input.targets[0].kind == .file and
            std.mem.eql(u8, input.targets[0].path, expected_target) and
            input.delivered_sources.len == 0 and
            input.evaluated_endpoints.len == 0;
        if (cancel_flag) |flag| flag.store(true, .seq_cst);

        var selected: context_contract.ProviderContext = .{};
        errdefer selected.deinit(alloc);
        selected.content = try alloc.dupe(u8, content);
        selected.delivered_sources = try dupeStrings(alloc, &.{source});
        selected.evaluated_endpoints = try dupeStrings(alloc, &.{endpoint});
        return selected;
    }

    fn appendStatic(
        _: context_contract.StaticContextInput,
        _: std.mem.Allocator,
        _: *std.ArrayList(ChatMessage),
    ) context_contract.ProviderError!void {}

    fn appendTransient(
        _: context_contract.TransientContextInput,
        _: std.mem.Allocator,
        _: *std.ArrayList(ChatMessage),
    ) context_contract.ProviderError!void {}

    fn dupeStrings(
        alloc: std.mem.Allocator,
        strings: []const []const u8,
    ) std.mem.Allocator.Error![][]u8 {
        if (strings.len == 0) return &.{};
        const owned = try alloc.alloc([]u8, strings.len);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |string| alloc.free(string);
            alloc.free(owned);
        }
        for (strings, 0..) |string, index| {
            owned[index] = try alloc.dupe(u8, string);
            initialized += 1;
        }
        return owned;
    }

    const registry = context_contract.Registry{ .default_provider = .{
        .id = "test.applicable_context_delta",
        .gather_project_context_fn = gather,
        .select_applicable_project_context_fn = select,
        .append_static_fn = appendStatic,
        .append_transient_fn = appendTransient,
    } };
};

const EmptyApplicableContext = struct {
    var select_calls: usize = 0;
    var last_target_count: usize = 0;

    fn reset() void {
        select_calls = 0;
        last_target_count = 0;
    }

    fn gather(
        _: std.mem.Allocator,
        _: context_contract.InitialContextInput,
    ) context_contract.ProviderError!context_contract.ProviderContext {
        return .{};
    }

    fn select(
        _: std.mem.Allocator,
        input: context_contract.LaterContextInput,
    ) context_contract.ProviderError!context_contract.ProviderContext {
        select_calls += 1;
        last_target_count = input.targets.len;
        return .{};
    }

    fn appendStatic(
        _: context_contract.StaticContextInput,
        _: std.mem.Allocator,
        _: *std.ArrayList(ChatMessage),
    ) context_contract.ProviderError!void {}

    fn appendTransient(
        _: context_contract.TransientContextInput,
        _: std.mem.Allocator,
        _: *std.ArrayList(ChatMessage),
    ) context_contract.ProviderError!void {}

    const registry = context_contract.Registry{ .default_provider = .{
        .id = "test.empty_applicable_context",
        .gather_project_context_fn = gather,
        .select_applicable_project_context_fn = select,
        .append_static_fn = appendStatic,
        .append_transient_fn = appendTransient,
    } };
};

const FreshnessApplicableContext = struct {
    const content = "NEW_SCOPED_CONTEXT";
    const source = "/test/new/AGENTS.md";
    const endpoint = "/test/new";

    var old_target: []const u8 = "";
    var new_target: []const u8 = "";
    var select_calls: usize = 0;
    var first_saw_old_target = false;
    var first_saw_new_target = false;
    var reissue_saw_new_target = false;
    var execution_reissue_saw_new_target = false;

    fn reset(old: []const u8, new: []const u8) void {
        old_target = old;
        new_target = new;
        select_calls = 0;
        first_saw_old_target = false;
        first_saw_new_target = false;
        reissue_saw_new_target = false;
        execution_reissue_saw_new_target = false;
    }

    fn gather(
        _: std.mem.Allocator,
        _: context_contract.InitialContextInput,
    ) context_contract.ProviderError!context_contract.ProviderContext {
        return .{};
    }

    fn select(
        alloc: std.mem.Allocator,
        input: context_contract.LaterContextInput,
    ) context_contract.ProviderError!context_contract.ProviderContext {
        select_calls += 1;
        for (input.targets) |target| {
            if (select_calls == 1 and std.mem.eql(u8, target.path, old_target)) {
                first_saw_old_target = true;
            }
            if (select_calls == 1 and std.mem.eql(u8, target.path, new_target)) {
                first_saw_new_target = true;
            }
            if (select_calls == 2 and std.mem.eql(u8, target.path, new_target)) {
                reissue_saw_new_target = true;
            }
            if (select_calls == 3 and std.mem.eql(u8, target.path, new_target)) {
                execution_reissue_saw_new_target = true;
            }
        }
        if (select_calls == 2 and reissue_saw_new_target) {
            var selected: context_contract.ProviderContext = .{};
            errdefer selected.deinit(alloc);
            selected.content = try alloc.dupe(u8, content);
            selected.delivered_sources = try ApplicableContextDelta.dupeStrings(alloc, &.{source});
            selected.evaluated_endpoints = try ApplicableContextDelta.dupeStrings(alloc, &.{endpoint});
            return selected;
        }
        return .{};
    }

    fn appendStatic(
        _: context_contract.StaticContextInput,
        _: std.mem.Allocator,
        _: *std.ArrayList(ChatMessage),
    ) context_contract.ProviderError!void {}

    fn appendTransient(
        _: context_contract.TransientContextInput,
        _: std.mem.Allocator,
        _: *std.ArrayList(ChatMessage),
    ) context_contract.ProviderError!void {}

    const registry = context_contract.Registry{ .default_provider = .{
        .id = "test.freshness_applicable_context",
        .gather_project_context_fn = gather,
        .select_applicable_project_context_fn = select,
        .append_static_fn = appendStatic,
        .append_transient_fn = appendTransient,
    } };
};

fn expectPermissionDeniedToolResult(gateway: *const FakeGateway, index: usize, tool_name: []const u8, reason: types.ToolPermissionDenialReason) !void {
    return expectPermissionDeniedToolResultAs(gateway, index, tool_name, tool_name, reason);
}

/// `history_tool_name` is the result's tool in the replayed request, which can
/// differ from the denied tool when legacy history is projected onto shell.
fn expectPermissionDeniedToolResultAs(gateway: *const FakeGateway, index: usize, history_tool_name: []const u8, tool_name: []const u8, reason: types.ToolPermissionDenialReason) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();

    const prompt = parsed.value.object.get("prompt").?.array.items;
    for (prompt) |entry| {
        if (entry != .object) continue;
        const role = entry.object.get("role") orelse continue;
        if (role != .string or !std.mem.eql(u8, role.string, "tool")) continue;
        const content = entry.object.get("content") orelse continue;
        if (content != .array) continue;
        for (content.array.items) |part| {
            if (part != .object) continue;
            const part_tool_name = part.object.get("toolName") orelse continue;
            if (part_tool_name != .string or !std.mem.eql(u8, part_tool_name.string, history_tool_name)) continue;
            const output = part.object.get("output") orelse continue;
            if (output != .object) continue;
            const output_type = output.object.get("type") orelse continue;
            if (output_type != .string or !std.mem.eql(u8, output_type.string, "execution-denied")) continue;
            try std.testing.expect(output.object.get("value") == null);
            const reason_value = output.object.get("reason") orelse continue;
            if (reason_value != .string) continue;

            try std.testing.expect(tool_result_errors.isToolPermissionDeniedOutput(reason_value.string));
            var payload = try std.json.parseFromSlice(std.json.Value, alloc, reason_value.string, .{});
            defer payload.deinit();
            const error_obj = payload.value.object.get("error").?.object;
            try std.testing.expectEqualStrings("tool_permission_denied", error_obj.get("type").?.string);
            try std.testing.expectEqualStrings(tool_name, error_obj.get("tool_name").?.string);
            if (expectedPermissionDeniedMessage(reason)) |message| {
                try std.testing.expectEqualStrings(message, error_obj.get("message").?.string);
            }
            try std.testing.expectEqualStrings(@tagName(reason), error_obj.get("reason").?.string);
            try std.testing.expect(error_obj.get("denied").?.bool);
            try std.testing.expect(error_obj.get("suggestion") != null);
            return;
        }
    }

    return error.TestExpectedToolResultMissing;
}

fn expectedPermissionDeniedMessage(reason: types.ToolPermissionDenialReason) ?[]const u8 {
    return switch (reason) {
        .user_denied => "Permission denied by user",
        .auto_denied => "Blocked by automatic safety policy",
        .review_caution => "Action held after safety review",
        .review_evidence_incomplete => "Safety review evidence incomplete; action held",
        .review_unavailable => "Safety reviewer unavailable; action held",
        .policy_denied, .permission_required => null,
    };
}

fn expectMalformedArgumentToolPair(
    gateway: *const FakeGateway,
    index: usize,
    tool_call_id: []const u8,
    tool_name: []const u8,
) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();

    var call_count: usize = 0;
    var result_count: usize = 0;
    const prompt = parsed.value.object.get("prompt").?.array.items;
    for (prompt) |entry| {
        if (entry != .object) continue;
        const role = entry.object.get("role") orelse continue;
        if (role != .string) continue;
        const content = entry.object.get("content") orelse continue;
        if (content != .array) continue;

        for (content.array.items) |part| {
            if (part != .object) continue;
            const part_type = part.object.get("type") orelse continue;
            if (part_type != .string) continue;
            const part_call_id = part.object.get("toolCallId") orelse continue;
            const part_tool_name = part.object.get("toolName") orelse continue;
            if (part_call_id != .string or part_tool_name != .string) continue;
            if (!std.mem.eql(u8, part_call_id.string, tool_call_id) or
                !std.mem.eql(u8, part_tool_name.string, tool_name))
            {
                continue;
            }

            if (std.mem.eql(u8, role.string, "assistant") and
                std.mem.eql(u8, part_type.string, "tool-call"))
            {
                const input = part.object.get("input") orelse return error.TestExpectedToolCallInputMissing;
                try std.testing.expect(input == .object);
                try std.testing.expectEqual(@as(usize, 0), input.object.count());
                call_count += 1;
                continue;
            }

            if (std.mem.eql(u8, role.string, "tool") and
                std.mem.eql(u8, part_type.string, "tool-result"))
            {
                const output = part.object.get("output") orelse return error.TestExpectedToolResultMissing;
                if (output != .object) return error.TestExpectedToolResultMissing;
                const value = output.object.get("value") orelse return error.TestExpectedToolResultMissing;
                if (value != .string) return error.TestExpectedToolResultMissing;
                try std.testing.expect(tool_result_errors.isToolExecutionFailedOutput(value.string));

                var failure = try std.json.parseFromSlice(std.json.Value, alloc, value.string, .{});
                defer failure.deinit();
                const error_obj = failure.value.object.get("error").?.object;
                try std.testing.expectEqualStrings("tool_execution_failed", error_obj.get("type").?.string);
                try std.testing.expectEqualStrings(tool_name, error_obj.get("tool_name").?.string);
                try std.testing.expect(std.mem.find(u8, error_obj.get("suggestion").?.string, "tool schema") != null);
                result_count += 1;
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 1), call_count);
    try std.testing.expectEqual(@as(usize, 1), result_count);
}

fn logIndexContaining(hooks: *const FakeAgentRuntimeDeps, needle: []const u8) ?usize {
    for (hooks.log.items, 0..) |entry, i| {
        if (std.mem.find(u8, entry, needle) != null) return i;
    }
    return null;
}
test "same completion duplicate toolbox opens both execute for explicit rereads" {
    const alloc = std.testing.allocator;
    var session: session_runtime.SessionRuntime = .{ .max_history_turns = 8 };
    defer session.deinit(alloc);

    const calls = [_]ToolCall{
        .{
            .id = "call_1",
            .name = "toolbox",
            .arguments_json = "{\"open\":\"/tmp/skills/workflow\"}",
        },
        .{
            .id = "call_2",
            .name = "toolbox",
            .arguments_json = "{\"open\":\"/tmp/skills/workflow\"}",
        },
    };

    var fixture = PromptFixture{};
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.context_enabled = true;
    hooks.context_registry = EmptyApplicableContext.registry;
    hooks.session_context = &session;
    hooks.exec_plans = &.{
        .{ .result = .{ .model_output = "loaded skill" } },
        .{ .result = .{ .model_output = "loaded skill" } },
    };

    var gateway = FakeGateway.init(alloc, &.{
        .{ .tool_calls = &calls },
        .{ .content = "final" },
    });
    defer gateway.deinit();

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 2), hooks.validated_names.items.len);
    try std.testing.expectEqual(@as(usize, 2), hooks.availability_checked_names.items.len);
    try std.testing.expectEqual(@as(usize, 2), hooks.permission_names.items.len);
    try std.testing.expectEqualStrings("call_1", hooks.permission_call_ids.items[0]);
    try std.testing.expectEqual(@as(usize, 2), hooks.executed_names.items.len);
    try std.testing.expectEqualStrings("call_1", hooks.executed_call_ids.items[0]);
    try std.testing.expect(!logContains(&hooks, "skip:toolbox"));
    try expectLifecycleCallIds(
        hooks.lifecycle_events.items,
        &.{ "call_1", "call_1", "call_1", "call_2", "call_2", "call_2" },
    );

    const results = hooks.history_turns.items[0].assistant.execution.tool_steps[0].tool_results;
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("loaded skill", results[0].output);
    try std.testing.expectEqualStrings("loaded skill", results[1].output);
}

fn expectRejectedPrompt(completion: FakeCompletion, expected_error: anyerror) !void {
    if (comptime !builtin.is_test) return;
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{completion};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try std.testing.expectError(
        expected_error,
        runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job()),
    );
    try std.testing.expectEqual(@as(usize, 0), hooks.history_turns.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.permission_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.lifecycle_events.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.system_notices.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.texts.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.finish_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.finalization_count);
    try std.testing.expectEqual(types.TurnPresentationOutcome.failed, hooks.finalized_outcome.?);
    try std.testing.expect(logContains(&hooks, "event:turn_finished"));
}

fn lifecycleCallId(event: types.ToolLifecycleEvent) ?[]const u8 {
    return switch (event) {
        .provisional => |value| value.id.call_id,
        .authoritative_started => |value| value.id.call_id,
        .progress => |value| value.id.call_id,
        .terminal => |value| value.id.call_id,
        .turn_finished => null,
    };
}

fn expectLifecycleCallIds(
    events: []const types.ToolLifecycleEvent,
    expected: []const []const u8,
) !void {
    try std.testing.expectEqual(expected.len, events.len);
    for (events, expected) |event, call_id| {
        try std.testing.expectEqualStrings(call_id, lifecycleCallId(event).?);
    }
}

fn expectSingleTerminalOutcome(
    events: []const types.ToolLifecycleEvent,
    call_id: []const u8,
    expected_kind: types.ToolOutcomeKind,
) !void {
    var matches: usize = 0;
    for (events) |event| {
        if (event != .terminal) continue;
        const terminal = event.terminal;
        if (!std.mem.eql(u8, terminal.id.call_id, call_id)) continue;
        matches += 1;
        try std.testing.expectEqual(expected_kind, terminal.outcome.kind);
    }
    try std.testing.expectEqual(@as(usize, 1), matches);
}

/// The leading system messages of a Gateway request body: the instructions.
fn leadingSystemContents(alloc: std.mem.Allocator, body: []const u8) !std.ArrayList([]const u8) {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{});
    var contents: std.ArrayList([]const u8) = .empty;
    for (parsed.object.get("prompt").?.array.items) |message| {
        if (!std.mem.eql(u8, message.object.get("role").?.string, "system")) break;
        try contents.append(alloc, message.object.get("content").?.string);
    }
    return contents;
}

fn expectSameInstructions(alloc: std.mem.Allocator, a: []const u8, b: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const first = try leadingSystemContents(arena_state.allocator(), a);
    const second = try leadingSystemContents(arena_state.allocator(), b);
    try std.testing.expectEqual(first.items.len, second.items.len);
    for (first.items, second.items) |x, y| try std.testing.expectEqualStrings(x, y);
}

/// The request ends with a tool result whose text ends with a rules block
/// holding `rule`, and no system message follows the instructions (D93).
fn expectRulesOnLastToolResult(alloc: std.mem.Allocator, body: []const u8, rule: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), body, .{});
    const prompt = parsed.object.get("prompt").?.array.items;
    var in_conversation = false;
    for (prompt) |message| {
        const is_system = std.mem.eql(u8, message.object.get("role").?.string, "system");
        if (!is_system) in_conversation = true;
        try std.testing.expect(!(is_system and in_conversation));
    }
    const last = prompt[prompt.len - 1].object;
    try std.testing.expectEqualStrings("tool", last.get("role").?.string);
    const parts = last.get("content").?.array.items;
    const output = parts[parts.len - 1].object.get("output").?.object.get("value").?.string;
    try std.testing.expect(std.mem.find(u8, output, rule) != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "</scoped-rules>"));
}

/// The request ends with a tool result whose text ends with the reminder
/// line for `rules` in `scope`, and no system message follows the
/// instructions.
fn expectReminderOnLastToolResult(alloc: std.mem.Allocator, body: []const u8, rules: []const u8, scope: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const prompt = parsed.object.get("prompt").?.array.items;
    var in_conversation = false;
    for (prompt) |message| {
        const is_system = std.mem.eql(u8, message.object.get("role").?.string, "system");
        if (!is_system) in_conversation = true;
        try std.testing.expect(!(is_system and in_conversation));
    }
    const last = prompt[prompt.len - 1].object;
    try std.testing.expectEqualStrings("tool", last.get("role").?.string);
    const parts = last.get("content").?.array.items;
    const output = parts[parts.len - 1].object.get("output").?.object.get("value").?.string;
    const line = try arena.print("<scoped-rules-reminder from=\"{s}\" scope=\"{s}\">The rules spark added earlier for this folder still apply.</scoped-rules-reminder>", .{ rules, scope });
    try std.testing.expect(std.mem.endsWith(u8, output, line));
}

/// The text of each user message in a Gateway request body, in order.
fn userMessageTexts(alloc: std.mem.Allocator, body: []const u8) !std.ArrayList([]const u8) {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{});
    var texts: std.ArrayList([]const u8) = .empty;
    for (parsed.object.get("prompt").?.array.items) |message| {
        if (!std.mem.eql(u8, message.object.get("role").?.string, "user")) continue;
        const content = message.object.get("content").?;
        var text: std.ArrayList(u8) = .empty;
        switch (content) {
            .string => |value| try text.appendSlice(alloc, value),
            .array => |parts| for (parts.items) |part| {
                if (part.object.get("text")) |value| try text.appendSlice(alloc, value.string);
            },
            else => {},
        }
        try texts.append(alloc, text.items);
    }
    return texts;
}

fn failContextGateCommit() std.mem.Allocator.Error!void {
    return error.OutOfMemory;
}

fn expectLogOrder(
    hooks: *const FakeAgentRuntimeDeps,
    earlier: []const u8,
    later_prefix: []const u8,
) !void {
    var earlier_index: ?usize = null;
    var later_index: ?usize = null;
    for (hooks.log.items, 0..) |entry, index| {
        if (earlier_index == null and std.mem.eql(u8, entry, earlier)) earlier_index = index;
        if (later_index == null and std.mem.startsWith(u8, entry, later_prefix)) later_index = index;
    }
    if (earlier_index == null) return error.MissingEarlierLogEvent;
    if (later_index == null) return error.MissingLaterLogEvent;
    if (earlier_index.? >= later_index.?) return error.LogEventOutOfOrder;
}
