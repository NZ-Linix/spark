const std = @import("std");
const builtin = @import("builtin");
const command_admission = @import("../../permissions/command_admission.zig");
const permissions = @import("../../permissions/permissions.zig");
const shell_snapshot = @import("../../terminal/shell_snapshot.zig");
const types = @import("../../shared/types.zig");
const pathing = @import("../../workspace/pathing.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const file_mutation_contract = @import("../../tooling/file_mutation_contract.zig");
const tooling_tool_admission = @import("../../tooling/tool_admission.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");
const test_builtin_tools = if (builtin.is_test)
    @import("../../../builtins/tools.zig")
else
    struct {};
const io_mod = @import("../../shared/io.zig");

const runtime_deps = @import("deps.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;
const PermissionMode = types.PermissionMode;
const ToolCall = types.ToolCall;
const ToolPermissionDecision = types.ToolPermissionDecision;
const TraceContext = debug_trace.TraceContext;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

const TerminalValidationDigest = [std.crypto.hash.sha2.Sha256.digest_length]u8;
const max_consecutive_malformed_argument_batches: usize = 3;

const TerminalValidationDigestDecision = struct {
    append_current: bool,
    repeated: bool,
};

fn containsTerminalValidationDigest(
    digests: []const TerminalValidationDigest,
    wanted: TerminalValidationDigest,
) bool {
    for (digests) |digest| {
        if (std.mem.eql(u8, digest[0..], wanted[0..])) return true;
    }
    return false;
}

fn terminalValidationDigestDecision(
    previous: []const TerminalValidationDigest,
    current: []const TerminalValidationDigest,
    digest: TerminalValidationDigest,
) TerminalValidationDigestDecision {
    return .{
        .append_current = !containsTerminalValidationDigest(current, digest),
        .repeated = containsTerminalValidationDigest(previous, digest),
    };
}

pub const TerminalValidationRetryState = struct {
    previous: std.ArrayList(TerminalValidationDigest) = .empty,
    current: std.ArrayList(TerminalValidationDigest) = .empty,
    stop_after_batch: bool = false,

    pub fn deinit(self: *TerminalValidationRetryState, alloc: Allocator) void {
        self.previous.deinit(alloc);
        self.current.deinit(alloc);
        self.* = .{};
    }

    pub fn beginBatch(self: *TerminalValidationRetryState) void {
        self.current.clearRetainingCapacity();
        self.stop_after_batch = false;
    }

    pub fn observe(
        self: *TerminalValidationRetryState,
        alloc: Allocator,
        call: ToolCall,
        model_output: []const u8,
    ) Allocator.Error!void {
        if (!std.mem.eql(u8, call.name, "shell")) return;
        if (try tool_result_errors.inspectTerminalActionFieldCorrection(
            alloc,
            model_output,
        ) == null) return;

        var digest: TerminalValidationDigest = undefined;
        std.crypto.hash.sha2.Sha256.hash(model_output, &digest, .{});
        const decision = terminalValidationDigestDecision(
            self.previous.items,
            self.current.items,
            digest,
        );
        if (decision.append_current) try self.current.append(alloc, digest);
        self.stop_after_batch = self.stop_after_batch or decision.repeated;
    }

    pub fn finishBatch(self: *TerminalValidationRetryState) bool {
        if (self.stop_after_batch) return true;
        const previous = self.previous;
        self.previous = self.current;
        self.current = previous;
        self.current.clearRetainingCapacity();
        return false;
    }
};

/// Model steps in a row in which the same shell call fails, with no file
/// changed in between, before the turn ends. From the second identical
/// failure on, the model is told not to retry unchanged
/// (`appendToolResultContent` in tool_batch.zig), so the third means it
/// ignored that.
const max_unchanged_shell_failure_steps: u32 = 3;

/// Ends a turn when the same shell call keeps failing while nothing changes.
/// A shell call is the same when its arguments are. A step that changes a
/// file starts every streak over, because rerunning a command after an edit
/// is a new attempt, not a repeat
/// (`tests/tla/shell_command/FailureStreak.tla` EditedRetryContinues,
/// BlindLoopBounded).
pub const ShellExecutionFailureRetryState = struct {
    const Streak = struct {
        digest: TerminalValidationDigest,
        steps: u32,
    };

    /// The previous step's failed shell calls, with their streaks.
    previous: std.ArrayList(Streak) = .empty,
    /// This step's failed shell calls; `steps` is set by `finishBatch`.
    current: std.ArrayList(Streak) = .empty,

    pub fn deinit(self: *ShellExecutionFailureRetryState, alloc: Allocator) void {
        self.previous.deinit(alloc);
        self.current.deinit(alloc);
        self.* = .{};
    }

    pub fn beginBatch(self: *ShellExecutionFailureRetryState) void {
        self.current.clearRetainingCapacity();
    }

    pub fn observe(
        self: *ShellExecutionFailureRetryState,
        alloc: Allocator,
        call: ToolCall,
        execution: ToolExecutionResult,
    ) Allocator.Error!void {
        if (!std.mem.eql(u8, call.name, "shell") or execution.status != .failure) {
            return;
        }
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("spark.shell-execution-failure.v1\x00");
        hash.update(call.arguments_json);
        const digest = hash.finalResult();
        if (findStreak(self.current.items, digest) != null) return;
        try self.current.append(alloc, .{ .digest = digest, .steps = 0 });
    }

    /// Ends the step and returns whether the turn should end. `files_changed`
    /// is whether the step wrote or edited a file successfully.
    pub fn finishBatch(self: *ShellExecutionFailureRetryState, files_changed: bool) bool {
        var stop = false;
        for (self.current.items) |*streak| {
            const before: u32 = if (files_changed)
                0
            else if (findStreak(self.previous.items, streak.digest)) |previous|
                previous.steps
            else
                0;
            streak.steps = before +| 1;
            stop = stop or streak.steps >= max_unchanged_shell_failure_steps;
        }
        std.mem.swap(std.ArrayList(Streak), &self.previous, &self.current);
        self.current.clearRetainingCapacity();
        return stop;
    }

    fn findStreak(streaks: []const Streak, digest: TerminalValidationDigest) ?Streak {
        for (streaks) |streak| {
            if (std.mem.eql(u8, &streak.digest, &digest)) return streak;
        }
        return null;
    }
};

/// Turn-scoped tracker that detects the same tool call (name + arguments)
/// failing repeatedly. The batch-scoped retry states above cannot see
/// degenerate loops that alternate single-call steps (a read between two
/// identical failing edits never produces an all-failed batch), so repeat
/// detection for content failures lives at turn scope.
pub const IdenticalFailureEscalationState = struct {
    const FailureCount = struct {
        digest: [32]u8,
        count: u32,
    };

    counts: std.ArrayList(FailureCount) = .empty,

    pub fn deinit(self: *IdenticalFailureEscalationState, alloc: Allocator) void {
        self.counts.deinit(alloc);
        self.* = .{};
    }

    fn failureDigest(call: ToolCall) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("spark.identical-failure.v1\x00");
        hash.update(call.name);
        hash.update("\x00");
        hash.update(call.arguments_json);
        return hash.finalResult();
    }

    /// Records a failed execution and returns how many times this exact call
    /// has failed this turn, including the current one. Successes and
    /// provider-supplied results return 0: they never escalate and never
    /// disturb an existing count.
    pub fn observe(
        self: *IdenticalFailureEscalationState,
        alloc: Allocator,
        call: ToolCall,
        failed: bool,
    ) Allocator.Error!u32 {
        if (call.provider_result != null) return 0;
        if (!failed) return 0;
        const digest = failureDigest(call);
        for (self.counts.items) |*item| {
            if (std.mem.eql(u8, item.digest[0..], digest[0..])) {
                item.count += 1;
                return item.count;
            }
        }
        try self.counts.append(alloc, .{ .digest = digest, .count = 1 });
        return 1;
    }
};

/// Appends escalation guidance to a repeated identical failure's
/// model-visible output. Guidance only: the tool already ran, and the model
/// keeps authority for retrying with changed arguments.
pub fn appendIdenticalFailureEscalation(
    alloc: Allocator,
    model_output: []const u8,
    failure_count: u32,
) Allocator.Error![]const u8 {
    return alloc.print(
        "{s}\n\nThis exact call has already failed {d} times this turn with the same arguments. Do not retry it unchanged.",
        .{ model_output, failure_count },
    );
}

pub const MalformedArgumentsRetryState = struct {
    consecutive_malformed_batches: usize = 0,
    current_call_count: usize = 0,
    current_malformed_count: usize = 0,

    pub fn beginBatch(self: *MalformedArgumentsRetryState) void {
        self.current_call_count = 0;
        self.current_malformed_count = 0;
    }

    pub fn observe(self: *MalformedArgumentsRetryState, call: ToolCall) void {
        self.current_call_count += 1;
        if (call.argument_integrity == .valid) return;
        self.current_malformed_count += 1;
    }

    pub fn finishBatch(self: *MalformedArgumentsRetryState) bool {
        const all_malformed = self.current_call_count > 0 and
            self.current_call_count == self.current_malformed_count;
        if (!all_malformed) {
            self.consecutive_malformed_batches = 0;
            return false;
        }
        if (self.consecutive_malformed_batches < max_consecutive_malformed_argument_batches) {
            self.consecutive_malformed_batches += 1;
        }
        return self.consecutive_malformed_batches == max_consecutive_malformed_argument_batches;
    }
};

test "non-object arguments use the existing bounded invalid-argument retry budget" {
    var state = MalformedArgumentsRetryState{};
    const call: ToolCall = .{ .id = "bad", .name = "read_file", .arguments_json = "{}", .argument_integrity = .non_object_json };
    for (0..3) |index| {
        state.beginBatch();
        state.observe(call);
        try std.testing.expectEqual(index == 2, state.finishBatch());
    }
    state.beginBatch();
    state.observe(.{ .id = "good", .name = "read_file", .arguments_json = "{}" });
    try std.testing.expect(!state.finishBatch());
}

pub fn deferVisibleLifecycleUntilAfterPermission(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "web_fetch") or
        file_mutation_contract.isToolName(tool_name);
}

pub fn requestToolPermissionTraced(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
    live_authority: ?runtime_tool_contracts.LiveToolAuthority,
    revalidation: ?command_admission.ToolExecutionAuthority,
    advertised_dynamic_tool_names: []const []const u8,
    ctx: TraceContext,
) !command_admission.PermissionOutcome {
    if (hooks.observer) |observer| observer.emit(.{ .permission_start = call });
    const outcome = hooks.request_tool_permission(hooks.ctx, arena, call, live_authority, revalidation, advertised_dynamic_tool_names) catch |err| {
        if (hooks.observer) |observer| observer.emit(.{ .permission_end = .{ .call = call, .error_name = @errorName(err) } });
        return admissionErrorOutcome(arena, call, err, ctx);
    };
    if (hooks.observer) |observer| observer.emit(.{ .permission_end = .{ .call = call, .decision = outcome.decision } });
    return outcome;
}

pub fn requestPreparedFileMutationPermissionTraced(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
    prepared: *tooling_tool_admission.PreparedFileMutationCall,
    live_authority: ?runtime_tool_contracts.LiveToolAuthority,
    advertised_dynamic_tool_names: []const []const u8,
    ctx: TraceContext,
) !command_admission.PermissionOutcome {
    const request = hooks.request_prepared_file_mutation_permission orelse {
        return admissionErrorOutcome(arena, call, error.PreparedFileMutationPermissionUnavailable, ctx);
    };
    if (hooks.observer) |observer| observer.emit(.{ .permission_start = call });
    const outcome = request(hooks.ctx, arena, call, prepared, live_authority, advertised_dynamic_tool_names) catch |err| {
        if (hooks.observer) |observer| observer.emit(.{ .permission_end = .{ .call = call, .error_name = @errorName(err) } });
        return admissionErrorOutcome(arena, call, err, ctx);
    };
    if (hooks.observer) |observer| observer.emit(.{ .permission_end = .{ .call = call, .decision = outcome.decision } });
    return outcome;
}

fn admissionErrorOutcome(
    arena: Allocator,
    call: ToolCall,
    err: anyerror,
    ctx: TraceContext,
) anyerror!command_admission.PermissionOutcome {
    if (try tooling_tool_admission.permissionTargetResolutionFailureMessage(arena, call, err)) |failure| {
        debug_trace.eventf("permission", "target_resolution_error", ctx, "call_id={s} tool_name={s} err={s}", .{ call.id, call.name, @errorName(err) });
        return .{ .tool_failure = failure };
    }
    debug_trace.eventf("permission", "admission_error", ctx, "call_id={s} tool_name={s} err={s}", .{ call.id, call.name, @errorName(err) });
    return err;
}

pub noinline fn permissionDeniedStatusLabel(reason: types.ToolPermissionDenialReason) []const u8 {
    return switch (reason) {
        .user_denied => "Denied",
        .policy_denied => "Denied",
        .permission_required => "Permission required",
    };
}

pub fn registeredToolValidationFailure(hooks: *const AgentRuntimeDeps, arena: Allocator, call: ToolCall) !?ToolExecutionResult {
    return switch (try toolCallValidation(hooks, arena, call)) {
        .not_registered => null,
        .valid => null,
        .failure => |reason| .{ .model_output = reason, .status = .failure },
    };
}

pub fn toolCallValidation(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
) !runtime_tool_contracts.ToolCallValidationResult {
    if (call.provider_result != null) return .{ .valid = .{} };
    const validate = hooks.validate_tool_call orelse return .{ .valid = .{} };
    return validate(hooks.ctx, arena, call);
}

pub fn toolAvailabilityFailure(hooks: *const AgentRuntimeDeps, arena: Allocator, call: ToolCall) !?ToolExecutionResult {
    if (call.provider_result != null) return null;
    const check = hooks.check_tool_availability orelse return null;
    const reason = try check(hooks.ctx, arena, call) orelse return null;
    return .{ .model_output = reason, .status = .failure };
}

pub noinline fn recordRejectedToolCall(
    deps: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
    model_output: []const u8,
    command_result_json: ?[]const u8,
) !void {
    const record = deps.record_tool_call_rejected orelse return;
    try record(deps.ctx, arena, call, model_output, command_result_json);
}

/// Records a call that failed the tool's own preflight or content checks
/// (for example a file-mutation prepare that found no matching old_string).
/// These are tool failures in diagnostics, not permission rejections.
pub noinline fn recordFailedToolCall(
    deps: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
    model_output: []const u8,
    command_result_json: ?[]const u8,
) !void {
    const record = deps.record_tool_call_failed orelse return;
    try record(deps.ctx, arena, call, model_output, command_result_json);
}
