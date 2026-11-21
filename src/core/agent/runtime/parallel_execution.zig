const std = @import("std");
const builtin = @import("builtin");
const testing_allocator = @import("../../shared/testing_allocator.zig");
const skill_contract = @import("../../skills/skill_contract.zig");
const types = @import("../../shared/types.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const io_mod = @import("../../shared/io.zig");

const runtime_deps = @import("deps.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;
const json_decode = @import("../../shared/json_decode.zig");
const ChatMessage = types.ChatMessage;
const ToolCall = types.ToolCall;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

pub fn isReadOnlyCall(registry: tool_dispatch.Registry, call: ToolCall) bool {
    if (call.provider_result != null) return false;

    const tool = registry.lookup(call.name) orelse return false;
    return switch (tool.executor_kind) {
        .glob_files => tool.activity_kind == .list,
        .read_file,
        .read_tool_result,
        .grep_files,
        .web_fetch,
        .web_search,
        => tool.activity_kind == .read,
        else => false,
    };
}

pub fn parallelReadOnlyPrefixLen(registry: tool_dispatch.Registry, calls: []const ToolCall) usize {
    var len: usize = 0;
    while (len < calls.len and isReadOnlyCall(registry, calls[len])) : (len += 1) {}
    return len;
}

fn isSubagentCall(registry: tool_dispatch.Registry, call: ToolCall) bool {
    if (call.provider_result != null) return false;
    const tool = registry.lookup(call.name) orelse return false;
    return tool.executor_kind == .subagent and tool.activity_kind == .subagent;
}

/// The subagent a subagent call goes to: `none` for a call that names none,
/// such as a wait, and `unknown` when its arguments can't be read.
const SubagentTarget = union(enum) { none, named: []const u8, unknown };

fn subagentTarget(arena: Allocator, call: ToolCall) SubagentTarget {
    if (call.argument_integrity != .valid) return .unknown;
    const Arguments = struct { request: ?struct { agent: ?[]const u8 = null } = null };
    const parsed = json_decode.parseFromSliceLeaky(Arguments, arena, call.arguments_json, .{ .ignore_unknown_fields = true }) catch return .unknown;
    const request = parsed.request orelse return .unknown;
    // An empty name is no name. A status or a wait reads an empty `agent` as
    // none, and any other call with one is refused before it acts.
    const agent = request.agent orelse return .none;
    return if (agent.len == 0) .none else .{ .named = agent };
}

/// Leading subagent calls that may run together. Calls to one subagent run
/// in the order written, so the group ends before a call to a subagent
/// already in it, and a call whose subagent can't be read runs alone
/// (`tests/tla/subagent/StopMessage.tla` StopRunsFirst). `alloc` holds the
/// names only while the group is formed.
fn parallelSubagentPrefixLen(alloc: Allocator, registry: tool_dispatch.Registry, calls: []const ToolCall) usize {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var named: std.ArrayList([]const u8) = .empty;
    var len: usize = 0;
    while (len < calls.len and isSubagentCall(registry, calls[len])) : (len += 1) {
        switch (subagentTarget(arena, calls[len])) {
            .none => {},
            .unknown => return if (len == 0) 1 else len,
            .named => |name| {
                for (named.items) |seen| if (std.mem.eql(u8, seen, name)) return len;
                named.append(arena, name) catch return if (len == 0) 1 else len;
            },
        }
    }
    return len;
}

/// Host tool calls that may run together, up to the first writer. A build
/// without threads runs them one at a time.
fn isConcurrentHostCall(registry: tool_dispatch.Registry, call: ToolCall) bool {
    if (builtin.single_threaded) return false;
    if (call.provider_result != null) return false;
    const tool = registry.lookup(call.name) orelse return false;
    return tool.executor_kind == .host and tool.host_concurrent;
}

/// Each running host call holds one of the host's pending requests, which
/// journal barriers and permission prompts share, so a group stays well
/// below that limit. Later calls form the next group.
const max_parallel_host_calls = 16;

fn parallelHostPrefixLen(registry: tool_dispatch.Registry, calls: []const ToolCall) usize {
    var len: usize = 0;
    while (len < calls.len and len < max_parallel_host_calls and isConcurrentHostCall(registry, calls[len])) : (len += 1) {}
    return len;
}

pub const GroupKind = enum { none, read_only, subagent, host };

pub const LeadingGroup = struct {
    kind: GroupKind = .none,
    len: usize = 0,
};

pub fn leadingParallelGroup(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    calls: []const ToolCall,
) LeadingGroup {
    const read_only_len = parallelReadOnlyPrefixLen(registry, calls);
    if (read_only_len > 0) return .{ .kind = .read_only, .len = read_only_len };
    const subagent_len = parallelSubagentPrefixLen(alloc, registry, calls);
    if (subagent_len > 0) return .{ .kind = .subagent, .len = subagent_len };
    const host_len = parallelHostPrefixLen(registry, calls);
    if (host_len > 0) return .{ .kind = .host, .len = host_len };
    return .{};
}

pub const ParallelToolResult = struct {
    call_id: []const u8,
    tool_name: []const u8,
    execution: ToolExecutionResult,
};

pub const ParallelToolAttempt = union(enum) {
    completed: ParallelToolResult,
    cancelled,
};

pub const ParallelRunResult = struct {
    attempts: []ParallelToolAttempt,
    first_cancelled_index: ?usize = null,

    pub fn deinit(self: *ParallelRunResult, alloc: Allocator) void {
        for (self.attempts) |attempt| freeParallelToolAttempt(alloc, attempt);
        alloc.free(self.attempts);
        self.* = undefined;
    }
};

pub const ParallelHookExecContext = struct {
    skill_locations: ?*const skill_contract.Locations = null,
    hooks: *const AgentRuntimeDeps,
    turn_id: u64,
    root_user_intent_context: []const u8,
    current_turn_messages: []const ChatMessage,
    permission_mode: types.PermissionMode,
    advertised_dynamic_tool_names: []const []const u8,
    max_tool_result_bytes: usize,
    toolbox_behind: []const []const u8 = &.{},
    toolbox_mcp_servers: []const []const u8 = &.{},
    classification_complete: []const bool = &.{},
    presentation_group_id: ?types.ToolPresentationGroupId = null,
};

const ParallelExecuteFn = *const fn (*anyopaque, Allocator, ToolCall, usize) anyerror!ToolExecutionResult;
const ParallelFormatErrorFn = *const fn (*anyopaque, Allocator, []const u8, anyerror) anyerror![]const u8;
const ParallelAttemptObserverFn = *const fn (*anyopaque, Allocator, ToolCall, ParallelToolAttempt, usize) void;

pub const ParallelAttemptObserver = struct {
    ctx: *anyopaque,
    notify: ParallelAttemptObserverFn,
};

pub const ParallelRunOptions = struct {
    exec_ctx: *anyopaque,
    execute: ParallelExecuteFn,
    format_ctx: *anyopaque,
    format_error: ParallelFormatErrorFn,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    attempt_observer: ?ParallelAttemptObserver = null,
};

const ParallelCompletionState = struct {
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
};

const ParallelWorkerSlot = struct {
    arena_state: std.heap.ArenaAllocator,
    thread: ?std.Thread = null,
    result: ?ToolExecutionResult = null,
    err: ?anyerror = null,
    owner_cancelled_at_error: bool = false,
    completed: bool = false,
    observed: bool = false,
};

pub fn runSequentialCalls(
    alloc: Allocator,
    calls: []const ToolCall,
    options: ParallelRunOptions,
) Allocator.Error!ParallelRunResult {
    const attempts = try alloc.alloc(ParallelToolAttempt, calls.len);
    var initialized: usize = 0;
    errdefer {
        for (attempts[0..initialized]) |attempt| freeParallelToolAttempt(alloc, attempt);
        alloc.free(attempts);
    }

    var first_cancelled_index: ?usize = null;
    for (calls, 0..) |call, index| {
        const attempt: ParallelToolAttempt = if (cancelRequested(options.cancel_flag)) cancelled: {
            if (first_cancelled_index == null) first_cancelled_index = index;
            break :cancelled .cancelled;
        } else completed: {
            const execution = options.execute(options.exec_ctx, alloc, call, index) catch |err| blk: {
                const output = options.format_error(options.format_ctx, alloc, call.name, err) catch
                    try alloc.print("Tool execution failed: {s}", .{@errorName(err)});
                defer alloc.free(output);
                break :blk ToolExecutionResult{
                    .status = .failure,
                    .model_output = output,
                };
            };
            break :completed .{
                .completed = try duplicateParallelToolResult(alloc, call, execution),
            };
        };
        attempts[index] = attempt;
        initialized += 1;
        observeParallelAttempt(options, alloc, call, attempt, index);
    }
    return .{ .attempts = attempts, .first_cancelled_index = first_cancelled_index };
}

pub fn runParallelCalls(
    alloc: Allocator,
    calls: []const ToolCall,
    options: ParallelRunOptions,
) Allocator.Error!ParallelRunResult {
    var completion_state = ParallelCompletionState{};
    const slots = try alloc.alloc(ParallelWorkerSlot, calls.len);
    defer alloc.free(slots);
    for (slots) |*slot| {
        slot.* = .{ .arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator) };
    }
    defer {
        for (slots) |*slot| {
            if (slot.thread) |thread| thread.join();
            slot.arena_state.deinit();
        }
    }

    const initialized = try alloc.alloc(bool, calls.len);
    defer alloc.free(initialized);
    @memset(initialized, false);
    const attempts = try alloc.alloc(ParallelToolAttempt, calls.len);
    errdefer {
        for (attempts, initialized) |attempt, is_initialized| {
            if (is_initialized) freeParallelToolAttempt(alloc, attempt);
        }
        alloc.free(attempts);
    }

    var started: usize = 0;
    for (calls, 0..) |call, index| {
        slots[index].thread = std.Thread.spawn(.{}, parallelWorkerMain, .{ &completion_state, &slots[index], options, call, index }) catch |err| {
            for (slots[0..started]) |*slot| {
                if (slot.thread) |thread| thread.join();
                slot.thread = null;
            }
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.OutOfMemory,
            };
        };
        started += 1;
    }

    var completed_count: usize = 0;
    var first_cancelled_index: ?usize = null;
    while (completed_count < started) : (completed_count += 1) {
        const index = waitForCompletedSlot(&completion_state, slots);
        const slot = &slots[index];
        if (slot.thread) |thread| {
            thread.join();
            slot.thread = null;
        }
        const attempt = try materializeParallelAttempt(alloc, calls[index], slot, options);
        attempts[index] = attempt;
        initialized[index] = true;
        if (attempt == .cancelled) {
            first_cancelled_index = if (first_cancelled_index) |current|
                @min(current, index)
            else
                index;
        }
        observeParallelAttempt(options, alloc, calls[index], attempt, index);
    }

    return .{
        .attempts = attempts,
        .first_cancelled_index = first_cancelled_index,
    };
}

fn parallelWorkerMain(
    completion_state: *ParallelCompletionState,
    slot: *ParallelWorkerSlot,
    options: ParallelRunOptions,
    call: ToolCall,
    index: usize,
) void {
    defer markParallelWorkerCompleted(completion_state, slot);
    if (cancelRequested(options.cancel_flag)) {
        slot.err = error.Cancelled;
        slot.owner_cancelled_at_error = true;
        return;
    }
    const worker_alloc = slot.arena_state.allocator();
    slot.result = options.execute(options.exec_ctx, worker_alloc, call, index) catch |err| {
        slot.err = err;
        slot.owner_cancelled_at_error =
            err == error.Cancelled and cancelRequested(options.cancel_flag);
        return;
    };
}

fn markParallelWorkerCompleted(state: *ParallelCompletionState, slot: *ParallelWorkerSlot) void {
    const io = io_mod.getIo();
    state.mutex.lockUncancelable(io);
    slot.completed = true;
    state.changed.broadcast(io);
    state.mutex.unlock(io);
}

fn waitForCompletedSlot(state: *ParallelCompletionState, slots: []ParallelWorkerSlot) usize {
    const io = io_mod.getIo();
    state.mutex.lockUncancelable(io);
    defer state.mutex.unlock(io);
    while (true) {
        for (slots, 0..) |*slot, index| {
            if (!slot.completed or slot.observed) continue;
            slot.observed = true;
            return index;
        }
        state.changed.waitUncancelable(io, &state.mutex);
    }
}

fn materializeParallelAttempt(
    alloc: Allocator,
    call: ToolCall,
    slot: *const ParallelWorkerSlot,
    options: ParallelRunOptions,
) !ParallelToolAttempt {
    if (slot.err) |err| {
        if (err == error.Cancelled and slot.owner_cancelled_at_error) return .cancelled;
    }

    var formatted_failure: ?[]const u8 = null;
    defer if (formatted_failure) |output| alloc.free(output);
    const execution: ToolExecutionResult = if (slot.err) |err| .{
        .status = .failure,
        .model_output = blk: {
            const output = options.format_error(options.format_ctx, alloc, call.name, err) catch |format_err| try alloc.print(
                "Tool execution failed: {s}; additionally failed to format error: {s}",
                .{ @errorName(err), @errorName(format_err) },
            );
            formatted_failure = output;
            break :blk output;
        },
    } else slot.result.?;
    return .{ .completed = try duplicateParallelToolResult(alloc, call, execution) };
}

fn observeParallelAttempt(
    options: ParallelRunOptions,
    alloc: Allocator,
    call: ToolCall,
    attempt: ParallelToolAttempt,
    index: usize,
) void {
    const observer = options.attempt_observer orelse return;
    observer.notify(observer.ctx, alloc, call, attempt, index);
}

fn cancelRequested(cancel_flag: ?*std.atomic.Value(bool)) bool {
    return if (cancel_flag) |flag| flag.load(.seq_cst) else false;
}

pub fn parallelHookExecute(ctx: *anyopaque, alloc: Allocator, call: ToolCall, index: usize) !ToolExecutionResult {
    const exec_ctx: *ParallelHookExecContext = @ptrCast(@alignCast(ctx));
    return exec_ctx.hooks.executeToolCall(.{
        .skill_locations = exec_ctx.skill_locations,
        .call_allocator = alloc,
        .result_allocator = alloc,
        .call = call,
        .authority = .ordinary,
        .permission_mode = exec_ctx.permission_mode,
        .root_user_intent_context = exec_ctx.root_user_intent_context,
        .current_turn_messages = exec_ctx.current_turn_messages,
        .advertised_dynamic_tool_names = exec_ctx.advertised_dynamic_tool_names,
        .max_tool_result_bytes = exec_ctx.max_tool_result_bytes,
        .toolbox_behind = exec_ctx.toolbox_behind,
        .toolbox_mcp_servers = exec_ctx.toolbox_mcp_servers,
        .classification_complete = index < exec_ctx.classification_complete.len and
            exec_ctx.classification_complete[index],
        .lifecycle_id = .{ .turn_id = exec_ctx.turn_id, .call_id = call.id },
        .presentation_group_id = exec_ctx.presentation_group_id,
    });
}

pub fn parallelHookFormatError(ctx: *anyopaque, alloc: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
    const exec_ctx: *ParallelHookExecContext = @ptrCast(@alignCast(ctx));
    return exec_ctx.hooks.format_tool_execution_error(exec_ctx.hooks.ctx, alloc, tool_name, err);
}

fn duplicateParallelToolResult(alloc: Allocator, call: ToolCall, execution: ToolExecutionResult) Allocator.Error!ParallelToolResult {
    const call_id = try alloc.dupe(u8, call.id);
    errdefer alloc.free(call_id);
    const tool_name = try alloc.dupe(u8, call.name);
    errdefer alloc.free(tool_name);

    if (execution.diff_entry != null or
        execution.finish_turn or
        execution.selected_dynamic_tools.len != 0 or
        execution.retired_dynamic_tool_names.len != 0 or
        execution.tool_result_memory_prepared or
        execution.committed_file_handoff != null or
        execution.deferred_tool_completion != null)
    {
        return .{
            .call_id = call_id,
            .tool_name = tool_name,
            .execution = .{
                .status = .failure,
                .model_output = try alloc.dupe(u8, "Parallel tool returned an unsupported side-effect payload."),
            },
        };
    }
    var duplicated_execution: ToolExecutionResult = .{
        .model_content_kind = execution.model_content_kind,
        .status = execution.status,
        .model_output = try alloc.dupe(u8, execution.model_output),
        .web_search_completion = execution.web_search_completion,
        .web_fetch_completion = execution.web_fetch_completion,
        .inner_usage = execution.inner_usage,
    };
    errdefer freeOwnedToolExecutionResult(alloc, duplicated_execution);
    if (execution.status_detail) |detail| {
        duplicated_execution.status_detail = try alloc.dupe(u8, detail);
    }
    if (execution.system_notice) |notice| {
        duplicated_execution.system_notice = try alloc.dupe(u8, notice);
    }
    if (execution.interactive_notice) |notice| {
        duplicated_execution.interactive_notice = try types.dupeSemanticNotice(alloc, notice);
    }
    duplicated_execution.context_notices = try duplicateContextNotices(alloc, execution.context_notices);
    if (execution.command_result_json) |json| {
        duplicated_execution.command_result_json = try alloc.dupe(u8, json);
    }
    duplicated_execution.tool_result_memory = try duplicateToolResultMemory(
        alloc,
        execution.tool_result_memory,
    );
    if (execution.subagent_completion) |status| {
        duplicated_execution.subagent_completion = try duplicateSubagentStatus(alloc, status);
    }

    return .{
        .call_id = call_id,
        .tool_name = tool_name,
        .execution = duplicated_execution,
    };
}

fn duplicateToolResultMemory(
    alloc: Allocator,
    source: ?types.ToolResultMemory,
) Allocator.Error!?types.ToolResultMemory {
    const memory = source orelse return null;
    return try types.dupeToolResultMemory(alloc, memory);
}

fn duplicateSubagentStatus(
    alloc: Allocator,
    status: types.SubagentStatus,
) Allocator.Error!types.SubagentStatus {
    const model = try alloc.dupe(u8, status.model);
    errdefer alloc.free(model);
    const session_title = if (status.session_title) |title|
        try alloc.dupe(u8, title)
    else
        null;
    return .{
        .session_title = session_title,
        .model = model,
        .effort = status.effort,
        .input_tokens = status.input_tokens,
        .context_window = status.context_window,
    };
}

pub fn reportInnerToolUsage(hooks: *const AgentRuntimeDeps, tool_name: []const u8, execution: ToolExecutionResult) void {
    const usage = execution.inner_usage orelse return;
    const report = hooks.report_inner_tool_usage orelse return;
    report(hooks.ctx, tool_name, usage);
}

fn freeParallelToolAttempt(alloc: Allocator, attempt: ParallelToolAttempt) void {
    switch (attempt) {
        .completed => |result| freeParallelToolResult(alloc, result),
        .cancelled => {},
    }
}

fn freeParallelToolResult(alloc: Allocator, result: ParallelToolResult) void {
    alloc.free(result.call_id);
    alloc.free(result.tool_name);
    freeOwnedToolExecutionResult(alloc, result.execution);
}

fn freeOwnedToolExecutionResult(alloc: Allocator, result: ToolExecutionResult) void {
    alloc.free(result.model_output);
    if (result.status_detail) |value| alloc.free(value);
    if (result.system_notice) |value| alloc.free(value);
    if (result.interactive_notice) |notice| types.freeSemanticNotice(alloc, notice);
    freeContextNotices(alloc, result.context_notices);
    if (result.command_result_json) |value| alloc.free(value);
    if (result.tool_result_memory) |memory| types.freeToolResultMemory(alloc, memory);
    if (result.subagent_completion) |status| {
        alloc.free(status.model);
        if (status.session_title) |title| alloc.free(title);
    }
}

fn duplicateContextNotices(alloc: Allocator, notices: []const []const u8) Allocator.Error![]const []const u8 {
    if (notices.len == 0) return &.{};

    const duplicated = try alloc.alloc([]const u8, notices.len);
    var copied: usize = 0;
    errdefer {
        for (duplicated[0..copied]) |notice| alloc.free(notice);
        alloc.free(duplicated);
    }
    for (notices, 0..) |notice, i| {
        duplicated[i] = try alloc.dupe(u8, notice);
        copied += 1;
    }
    return duplicated;
}

fn freeContextNotices(alloc: Allocator, notices: []const []const u8) void {
    for (notices) |notice| alloc.free(notice);
    if (notices.len > 0) alloc.free(notices);
}

const ParallelTestPlan = struct {
    output: []const u8 = "",
    err: ?anyerror = null,
    delay_ms: u64 = 0,
    gate: ?*std.Io.Event = null,
    cancel: bool = false,
};

const ParallelTestFixture = struct {
    plans: []const ParallelTestPlan,
    cancel_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    in_flight: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    max_in_flight: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

fn runParallelCallsForTest(
    alloc: Allocator,
    calls: []const ToolCall,
    fixture: *ParallelTestFixture,
) Allocator.Error!ParallelRunResult {
    return runParallelCalls(alloc, calls, .{
        .exec_ctx = fixture,
        .execute = parallelTestExecute,
        .format_ctx = fixture,
        .format_error = parallelTestFormatError,
        .cancel_flag = &fixture.cancel_flag,
    });
}

fn parallelTestExecute(ctx: *anyopaque, alloc: Allocator, call: ToolCall, index: usize) !ToolExecutionResult {
    _ = call;
    const fixture: *ParallelTestFixture = @ptrCast(@alignCast(ctx));
    const in_flight = fixture.in_flight.fetchAdd(1, .seq_cst) + 1;
    updateMaxInFlight(&fixture.max_in_flight, in_flight);
    defer _ = fixture.in_flight.fetchSub(1, .seq_cst);

    const plan = fixture.plans[index];
    if (plan.delay_ms > 0) io_mod.sleep(plan.delay_ms * std.time.ns_per_ms);
    if (plan.gate) |gate| {
        try gate.waitTimeout(io_mod.getIo(), .{ .duration = .{
            .clock = .awake,
            .raw = .fromSeconds(5),
        } });
    }
    if (plan.cancel) fixture.cancel_flag.store(true, .seq_cst);
    if (plan.err) |err| return err;
    return .{ .status = .success, .model_output = try alloc.dupe(u8, plan.output) };
}

fn updateMaxInFlight(max_in_flight: *std.atomic.Value(usize), candidate: usize) void {
    var current = max_in_flight.load(.seq_cst);
    while (candidate > current) {
        const result = max_in_flight.cmpxchgWeak(current, candidate, .seq_cst, .seq_cst);
        if (result == null) return;
        current = result.?;
    }
}

fn parallelTestFormatError(_: *anyopaque, alloc: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
    return alloc.print("{s} failed with {s}", .{ tool_name, @errorName(err) });
}

fn toolCall(id: []const u8, name: []const u8, args: []const u8) ToolCall {
    return .{ .id = id, .name = name, .arguments_json = args };
}

const ParallelObserverCapture = struct {
    indices: [2]usize = undefined,
    count: usize = 0,
    fast_observed: std.Io.Event = .unset,

    fn notify(raw: *anyopaque, _: Allocator, _: ToolCall, _: ParallelToolAttempt, index: usize) void {
        const self: *ParallelObserverCapture = @ptrCast(@alignCast(raw));
        std.debug.assert(self.count < self.indices.len);
        self.indices[self.count] = index;
        self.count += 1;
        if (index == 1) self.fast_observed.set(io_mod.getIo());
    }
};

const ParallelObserverRun = struct {
    calls: []const ToolCall,
    fixture: *ParallelTestFixture,
    capture: *ParallelObserverCapture,
    result: ?ParallelRunResult = null,
    err: ?anyerror = null,

    fn run(self: *ParallelObserverRun) void {
        self.result = runParallelCalls(std.testing.allocator, self.calls, .{
            .exec_ctx = self.fixture,
            .execute = parallelTestExecute,
            .format_ctx = self.fixture,
            .format_error = parallelTestFormatError,
            .cancel_flag = &self.fixture.cancel_flag,
            .attempt_observer = .{ .ctx = self.capture, .notify = ParallelObserverCapture.notify },
        }) catch |err| {
            self.err = err;
            return;
        };
    }
};

test "parallel classifier uses active registry metadata" {
    const builtin_tools = @import("../../../builtins/tools.zig");
    const calls = [_]ToolCall{toolCall("read", "read_file", "{\"path\":\"README.md\"}")};
    const tools = [_]tool_dispatch.Tool{builtin_tools.read_file};
    const active_registry = tool_dispatch.Registry{ .tools = &tools };
    const empty_registry = tool_dispatch.Registry{};
    var mislabeled_read = builtin_tools.read_file;
    mislabeled_read.activity_kind = .write;
    const mislabeled_tools = [_]tool_dispatch.Tool{mislabeled_read};
    const mislabeled_registry = tool_dispatch.Registry{ .tools = &mislabeled_tools };

    try std.testing.expectEqual(@as(usize, 1), parallelReadOnlyPrefixLen(active_registry, &calls));
    try std.testing.expectEqual(@as(usize, 0), parallelReadOnlyPrefixLen(empty_registry, &calls));
    try std.testing.expectEqual(@as(usize, 0), parallelReadOnlyPrefixLen(mislabeled_registry, &calls));
}

fn checkParallelRunAllocationFailures(alloc: Allocator) !void {
    const calls = [_]ToolCall{
        toolCall("first", "read_file", "{\"path\":\"a\"}"),
        toolCall("second", "grep_files", "{\"pattern\":\"b\"}"),
    };
    const plans = [_]ParallelTestPlan{
        .{ .output = "first output" },
        .{ .output = "second output" },
    };
    var fixture = ParallelTestFixture{ .plans = &plans };
    var run = try runParallelCallsForTest(alloc, &calls, &fixture);
    defer run.deinit(alloc);
}

fn checkParallelResultDuplicationAllocationFailures(alloc: Allocator) !void {
    const call = toolCall(
        "call_read",
        "read_file",
        "{\"path\":\"notes.txt\"}",
    );
    const execution: ToolExecutionResult = .{
        .model_content_kind = .complete_skill,
        .model_output = "contents",
        .status_detail = "detail",
        .system_notice = "notice",
        .interactive_notice = .{
            .topic = "background",
            .tone = .information,
            .body = "Command #7 started. Log: /tmp/run.log",
        },
        .context_notices = &.{ "first context notice", "second context notice" },
        .command_result_json = "{}",
        .subagent_completion = .{
            .session_title = "Reviewer",
            .model = "openai/gpt-5.5",
            .effort = types.ReasoningEffort.literal("high"),
            .input_tokens = 12_000,
            .context_window = 100_000,
        },
        .tool_result_memory = .{
            .tool_images = &.{.{ .data = @constCast("cG5n"), .mime_type = @constCast("image/png") }},
            .tool_image_handle = "image-result-handle",
            .output_handle = "result-handle",
            .preview = "preview",
            .output_bytes = 8,
            .stored_output_bytes = 8,
            .model_view_covers_full_file = true,
        },
    };
    const duplicated = try duplicateParallelToolResult(
        alloc,
        call,
        execution,
    );
    defer freeParallelToolResult(alloc, duplicated);
    try std.testing.expectEqual(execution.model_content_kind, duplicated.execution.model_content_kind);
    const memory = duplicated.execution.tool_result_memory.?;
    try std.testing.expectEqualStrings("image-result-handle", memory.tool_image_handle.?);
    try std.testing.expectEqual(@as(usize, 1), memory.tool_images.len);
    try std.testing.expectEqualStrings("cG5n", memory.tool_images[0].data);
    try std.testing.expectEqualStrings("image/png", memory.tool_images[0].mime_type);
    try std.testing.expectEqualStrings("notice", duplicated.execution.system_notice.?);
    const interactive_notice = duplicated.execution.interactive_notice.?;
    try std.testing.expectEqualStrings("background", interactive_notice.topic);
    try std.testing.expectEqual(types.NoticeTone.information, interactive_notice.tone);
    try std.testing.expectEqualStrings("Command #7 started. Log: /tmp/run.log", interactive_notice.body);
    try std.testing.expectEqual(@as(usize, 2), duplicated.execution.context_notices.len);
    try std.testing.expectEqualStrings("first context notice", duplicated.execution.context_notices[0]);
    try std.testing.expectEqualStrings("second context notice", duplicated.execution.context_notices[1]);
    const subagent = duplicated.execution.subagent_completion.?;
    try std.testing.expectEqualStrings("Reviewer", subagent.session_title.?);
    try std.testing.expectEqualStrings("openai/gpt-5.5", subagent.model);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), subagent.effort);
    try std.testing.expectEqual(@as(u64, 12_000), subagent.input_tokens);
    try std.testing.expectEqual(@as(?u32, 100_000), subagent.context_window);
}

/// Each byte is one call of a step. Its low two bits pick a message (0) or a
/// stop (1) to agent `a0`..`a3` named by the next two bits, a wait (2) that
/// names no agent, or an empty one when the third bit is set, or (3) one of:
/// arguments that aren't JSON, a message to `a1` spelled with
/// a JSON escape, a message to the parent, or a read_file call. The leading
/// subagent group must stop before a call to an agent already in it, and a
/// call whose agent can't be read runs alone, so calls to one subagent run
/// in the order written (`tests/tla/subagent/StopMessage.tla` StopRunsFirst).
fn fuzzSubagentGroups(_: void, smith: *std.testing.Smith) anyerror!void {
    const builtin_tools = @import("../../../builtins/tools.zig");
    const tools = [_]tool_dispatch.Tool{ builtin_tools.subagent, builtin_tools.read_file };
    const registry = tool_dispatch.Registry{ .tools = &tools };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var calls: std.ArrayList(ToolCall) = .empty;
    const Target = union(enum) { none, named: []const u8, unknown, other };
    var targets: std.ArrayList(Target) = .empty;
    var bytes: [64]u8 = undefined;
    const len: usize = @intCast(smith.slice(&bytes));
    const input = bytes[0..len];
    for (input, 0..) |byte, index| {
        const agent = try arena.print("a{d}", .{(byte >> 2) & 3});
        const id = try arena.print("call_{d}", .{index});
        const call: ToolCall, const target: Target = switch (byte & 3) {
            0 => .{ toolCall(id, "subagent", try arena.print("{{\"request\":{{\"action\":\"message\",\"agent\":\"{s}\",\"message\":\"m\"}}}}", .{agent})), .{ .named = agent } },
            1 => .{ toolCall(id, "subagent", try arena.print("{{\"request\":{{\"action\":\"stop\",\"agent\":\"{s}\"}}}}", .{agent})), .{ .named = agent } },
            2 => .{ toolCall(id, "subagent", if (byte & 4 == 0) "{\"request\":{\"action\":\"wait\"}}" else "{\"request\":{\"action\":\"wait\",\"agent\":\"\"}}"), .none },
            else => switch ((byte >> 2) & 3) {
                0 => .{ toolCall(id, "subagent", "{\"request\":"), .unknown },
                1 => .{ toolCall(id, "subagent", "{\"request\":{\"action\":\"message\",\"agent\":\"a\\u0031\",\"message\":\"m\"}}"), .{ .named = "a1" } },
                2 => .{ toolCall(id, "subagent", "{\"request\":{\"action\":\"message\",\"agent\":\"parent\",\"message\":\"m\"}}"), .{ .named = "parent" } },
                else => .{ toolCall(id, "read_file", "{\"path\":\"README.md\"}"), .other },
            },
        };
        try calls.append(arena, call);
        try targets.append(arena, target);
    }
    if (calls.items.len == 0 or targets.items[0] == .other) return;
    var expected: usize = 0;
    var named: std.ArrayList([]const u8) = .empty;
    group: for (targets.items, 0..) |target, index| {
        switch (target) {
            .other => break,
            .none => {},
            .unknown => {
                if (index == 0) expected = 1;
                break;
            },
            .named => |name| {
                for (named.items) |seen| if (std.mem.eql(u8, seen, name)) break :group;
                try named.append(arena, name);
            },
        }
        expected = index + 1;
    }
    const group = leadingParallelGroup(std.testing.allocator, registry, calls.items);
    try std.testing.expectEqual(GroupKind.subagent, group.kind);
    try std.testing.expectEqual(expected, group.len);
}
