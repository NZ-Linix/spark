const std = @import("std");
const toolbox = @import("../../tooling/toolbox.zig");
const testing_allocator = @import("../../shared/testing_allocator.zig");
const command_admission = @import("../../permissions/command_admission.zig");
const managed_execution = @import("../../execution/managed_execution.zig");
const types = @import("../../shared/types.zig");
const shared_theme = @import("../../shared/theme.zig");
const text_utils = @import("../../shared/text_utils.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const tool_args = @import("../../tooling/tool_args.zig");
const tool_specs = @import("../../tooling/tool_specs.zig");
const tooling_presentation = @import("../../tooling/tool_presentation.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const mcp_tool_result = @import("../../mcp/tool_result.zig");
const diff = @import("../../output/diff.zig");
const file_mutation_contract = @import("../../tooling/file_mutation_contract.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");
const read_result_presentation = @import("../../tooling/read_tool_result_presentation.zig");
const command_result_mapping = if (@import("builtin").is_test)
    @import("../../tooling/command_result_mapping.zig")
else
    struct {};
const test_builtin_tools = if (@import("builtin").is_test)
    @import("../../../builtins/tools.zig")
else
    struct {};

const runtime_deps = @import("deps.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const DiffEntryPayload = runtime_tool_contracts.DiffEntryPayload;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

pub fn isProviderSearchAlias(tool_name: []const u8) bool {
    return tooling_presentation.isProviderSearchAlias(tool_name);
}

pub fn streamStartMayHaveExecutedAtProvider(
    registry: tool_dispatch.Registry,
    tool_name: []const u8,
) bool {
    if (isProviderSearchAlias(tool_name)) return true;
    const spec = registry.lookup(tool_name) orelse return false;
    return spec.provider_executed;
}

/// Whether a tool that may run at the provider only reads, as a search does,
/// so running it again after a failed attempt is safe.
pub fn providerToolOnlyReads(
    registry: tool_dispatch.Registry,
    tool_name: []const u8,
) bool {
    if (isProviderSearchAlias(tool_name)) return true;
    const spec = registry.lookup(tool_name) orelse return false;
    return spec.provider_executed and spec.activity_kind == .read;
}

fn fallbackToolDisplay(
    registry: tool_dispatch.Registry,
    tool_name: []const u8,
) []const u8 {
    // Provider-executed search backends are never registered locally; their
    // stream names (exa_search, ...) are internal identifiers, not display copy.
    if (tooling_presentation.isProviderSearchAlias(tool_name)) return "web search";
    const lookup_name = if (std.mem.eql(u8, tool_name, "run_command"))
        "shell"
    else
        tool_name;
    return if (registry.lookup(lookup_name) != null) "tool call" else tool_name;
}

pub const ProvisionalToolStatuses = struct {
    const TrackedStatus = struct {
        id: []u8,
        tool_name: []u8,
        label_value: ?[]u8,
        /// Whether the call's row was published. A toolbox call's row waits,
        /// hidden, until its arguments name what it does.
        shown: bool = true,

        fn deinit(self: *TrackedStatus, alloc: Allocator) void {
            alloc.free(self.id);
            alloc.free(self.tool_name);
            if (self.label_value) |value| alloc.free(value);
            self.* = undefined;
        }
    };

    tracked: std.ArrayList(TrackedStatus) = .empty,
    terminal_ids: std.ArrayList([]u8) = .empty,
    presentation_group_id: ?types.ToolPresentationGroupId = null,

    pub const StartPreflight = union(enum) {
        ineligible,
        eligible: struct {
            action_label: []const u8,
            activity_kind: types.ToolActivityKind,
        },
    };

    pub fn deinit(self: *ProvisionalToolStatuses, alloc: Allocator) void {
        for (self.tracked.items) |*status| status.deinit(alloc);
        self.tracked.deinit(alloc);
        for (self.terminal_ids.items) |id| alloc.free(id);
        self.terminal_ids.deinit(alloc);
    }

    pub fn preflight(registry: tool_dispatch.Registry, tool_name: []const u8) ?StartPreflight {
        if (tooling_presentation.isProviderSearchAlias(tool_name)) {
            return .{ .eligible = .{
                .action_label = "Searching",
                .activity_kind = .read,
            } };
        }
        const lookup_name = if (std.mem.eql(u8, tool_name, "run_command"))
            "shell"
        else
            tool_name;
        const spec = registry.lookup(lookup_name) orelse return null;
        if (spec.executor_kind == .terminal) return .ineligible;
        return switch (spec.activity_kind) {
            .ask, .write, .edit => .ineligible,
            else => .{ .eligible = .{
                .action_label = spec.action_label,
                .activity_kind = spec.activity_kind,
            } },
        };
    }

    pub fn publish(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        turn_id: u64,
        tool_id: []const u8,
        tool_name: []const u8,
        activity_kind: types.ToolActivityKind,
        action_label: []const u8,
        label_value: ?[]const u8,
        arguments_json: ?[]const u8,
    ) !void {
        if (tool_id.len == 0) {
            debug_trace.logf(
                "ui_activity",
                "suppressed provisional lifecycle with missing identity turn_id={d}",
                .{turn_id},
            );
            return;
        }

        var buf: [512]u8 = undefined;
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        // A toolbox call's row, once its arguments arrive, reads as what it
        // opens, runs, or searches, since the first string in them may be
        // any of those.
        const is_toolbox = std.mem.eql(u8, tool_name, toolbox.tool_name);
        var observed_label = if (is_toolbox) null else label_value;
        var observed_kind = activity_kind;
        const argument_label: ?[]const u8 = if (is_toolbox) resource: {
            const json = arguments_json orelse break :resource null;
            // While the arguments stream in they do not parse yet, but the
            // action and the whole name after it already say what the call
            // does, so its row does not read as a bare "Using" until they end.
            const args = tool_args.parseToolArgsObject(scratch.allocator(), json) catch streamed: {
                const action = tooling_presentation.toolboxStreamedAction(scratch.allocator(), json) catch break :resource null;
                break :streamed tool_args.parseToolArgsObject(scratch.allocator(), action orelse break :resource null) catch break :resource null;
            };
            const spec = hooks.tool_registry.lookup(tool_name) orelse break :resource null;
            const presentation = tool_dispatch.presentationForArgs(spec.*, args);
            const value = tool_dispatch.presentationLabelValue(presentation, args) orelse break :resource null;
            const encoded = text_utils.encodeTerminalSafe(scratch.allocator(), value, buf.len) catch break :resource null;
            if (encoded.truncated) break :resource null;
            const formatted = formatProvisionalProgressLabel(&buf, presentation.action_label, encoded.bytes) catch break :resource null;
            observed_label = value;
            observed_kind = presentation.activity_kind;
            break :resource formatted;
        } else null;
        // A subagent call's row names its subagent once its arguments hold
        // the name, while they stream in or once complete, and keeps a name
        // it already shows; the first string in them is its action.
        const is_subagent = std.mem.eql(u8, tool_name, "subagent");
        if (is_subagent) {
            observed_label = tooling_presentation.subagentStreamedAgent(arguments_json orelse "") orelse self.trackedLabel(tool_id);
        }
        // Any other builtin call's row names its target, such as the file a
        // read opens, once that value streams in.
        const builtin = hooks.tool_registry.lookup(tool_name);
        const streamed_value = if (builtin) |spec| if (!is_toolbox and !is_subagent and observed_label == null)
            tooling_presentation.streamedLabelValue(spec.label_arg_kind, arguments_json orelse "")
        else
            null else null;
        if (streamed_value) |value| observed_label = value;
        const shown_label = if (is_subagent and observed_label != null)
            (try text_utils.encodeTerminalSafe(scratch.allocator(), observed_label.?, 64)).bytes
        else if (streamed_value) |value|
            (try text_utils.encodeTerminalSafe(scratch.allocator(), value, 240)).bytes
        else
            observed_label;
        const label = argument_label orelse try formatProvisionalProgressLabel(&buf, action_label, shown_label);
        const recorded = try self.recordTracked(
            alloc,
            tool_id,
            tool_name,
            observed_label,
        );
        const index = self.findTracked(tool_id).?;
        // A toolbox call says nothing about itself until its arguments name
        // what it opens, runs, or searches, so its row never reads a bare
        // "Using": it stays hidden until that name streams in, or until the
        // call itself starts.
        if (is_toolbox and argument_label == null) {
            if (recorded) self.tracked.items[index].shown = false;
            return;
        }
        self.tracked.items[index].shown = true;
        hooks.push_tool_lifecycle(hooks.ctx, .{
            .provisional = .{
                .id = .{ .turn_id = turn_id, .call_id = tool_id },
                .presentation_group_id = self.presentation_group_id,
                .tool_name = tool_name,
                .activity_kind = observed_kind,
            },
        }) catch |err| {
            if (recorded) self.forget(alloc, tool_id);
            return err;
        };
        hooks.push_tool_lifecycle(hooks.ctx, .{
            .progress = .{
                .id = .{ .turn_id = turn_id, .call_id = tool_id },
                .text = label,
            },
        }) catch {};
    }

    /// Names a streaming call's row as soon as its arguments so far say what
    /// it is for, while the rest of the call streams in: the subagent a
    /// `subagent` call is for once its whole name is in, so the row reads
    /// `Managing reviewer`, and what a `toolbox` call runs, searches, or
    /// opens once that whole value is in, so the row reads
    /// `Running glob_files`. A row already named stays as it is.
    pub fn observeArguments(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        turn_id: u64,
        tool_id: []const u8,
        arguments: []const u8,
    ) !void {
        const index = self.findTracked(tool_id) orelse return;
        const status = self.tracked.items[index];
        if (status.label_value != null) return;
        if (std.mem.eql(u8, status.tool_name, "subagent")) {
            if (tooling_presentation.subagentStreamedAgent(arguments) == null) return;
        } else if (std.mem.eql(u8, status.tool_name, toolbox.tool_name)) {
            const action = try tooling_presentation.toolboxStreamedAction(alloc, arguments) orelse return;
            alloc.free(action);
        } else {
            const spec = hooks.tool_registry.lookup(status.tool_name) orelse return;
            if (tooling_presentation.streamedLabelValue(spec.label_arg_kind, arguments) == null) return;
        }
        const metadata = switch (preflight(hooks.tool_registry, status.tool_name) orelse return) {
            .ineligible => return,
            .eligible => |metadata| metadata,
        };
        try self.publish(hooks, alloc, turn_id, status.id, status.tool_name, metadata.activity_kind, metadata.action_label, null, arguments);
    }

    fn trackedLabel(self: *const ProvisionalToolStatuses, id: []const u8) ?[]const u8 {
        const index = self.findTracked(id) orelse return null;
        return self.tracked.items[index].label_value;
    }

    pub fn finishMalformedToolArguments(
        self: *const ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
    ) !void {
        const call_id = self.visibleId(call) orelse return;
        const summary = try arena.print(
            "{s} failed: {s}",
            .{ fallbackToolDisplay(hooks.tool_registry, call.name), if (call.argument_integrity == .non_object_json) "non-object arguments" else "invalid JSON arguments" },
        );
        try hooks.push_tool_lifecycle(hooks.ctx, .{
            .terminal = .{
                .id = .{ .turn_id = turn_id, .call_id = call_id },
                .outcome = .{ .kind = .failed, .summary = summary },
            },
        });
    }

    pub fn finishMalformedProviderToolArguments(
        self: *const ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        arena: Allocator,
        turn_id: u64,
        calls: []const ToolCall,
    ) !void {
        for (calls) |call| {
            if (call.provenance != .provider_executed or call.argument_integrity != .malformed_json) continue;
            try self.finishMalformedToolArguments(hooks, arena, turn_id, call);
        }
    }

    pub fn finishRejectedCompletions(
        self: *const ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        arena: Allocator,
        turn_id: u64,
        calls: []const ToolCall,
        advertised_dynamic_tool_names: []const []const u8,
    ) !void {
        for (calls) |call| {
            if (!self.has(call.id)) continue;
            try finishDeniedToolStatus(
                hooks,
                arena,
                turn_id,
                call,
                true,
                null,
                "Failed",
                advertised_dynamic_tool_names,
            );
        }
    }

    /// Settles one admitted call against its tracked final or provisional id.
    /// The tracked id is consumed only after terminal publication succeeds.
    pub fn settleAdmittedCall(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
        label: []const u8,
        advertised_dynamic_tool_names: []const []const u8,
    ) !bool {
        return self.finishDeniedCall(
            hooks,
            alloc,
            arena,
            turn_id,
            call,
            false,
            null,
            label,
            advertised_dynamic_tool_names,
        );
    }

    pub fn settleDeferredCall(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
        advertised_dynamic_tool_names: []const []const u8,
    ) !bool {
        const recorded_terminal = try self.recordTerminal(alloc, call.id);
        if (!recorded_terminal) return false;
        errdefer self.forgetTerminal(alloc, call.id);
        const target = try self.ensureTerminalTarget(
            hooks,
            arena,
            turn_id,
            call,
            false,
            null,
            advertised_dynamic_tool_names,
        ) orelse {
            self.forgetTerminal(alloc, call.id);
            return false;
        };
        try finishDeferredToolStatus(
            hooks,
            arena,
            turn_id,
            target.call,
            advertised_dynamic_tool_names,
        );
        if (target.tracked_id) |tracked_id| self.forget(alloc, tracked_id);
        return true;
    }

    pub fn finishDeniedCall(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
        authoritative_started: bool,
        display_target: ?[]const u8,
        label: []const u8,
        advertised_dynamic_tool_names: []const []const u8,
    ) !bool {
        const recorded_terminal = try self.recordTerminal(alloc, call.id);
        if (!recorded_terminal) return false;
        errdefer self.forgetTerminal(alloc, call.id);
        const target = try self.ensureTerminalTarget(
            hooks,
            arena,
            turn_id,
            call,
            authoritative_started,
            display_target,
            advertised_dynamic_tool_names,
        ) orelse {
            self.forgetTerminal(alloc, call.id);
            return false;
        };
        try finishDeniedToolStatus(
            hooks,
            arena,
            turn_id,
            target.call,
            true,
            display_target,
            label,
            advertised_dynamic_tool_names,
        );
        if (target.tracked_id) |tracked_id| self.forget(alloc, tracked_id);
        return true;
    }

    pub fn finishExecutedCall(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
        authoritative_started: bool,
        display_target: ?[]const u8,
        result: ToolExecutionResult,
        safe_result: []const u8,
        result_memory: types.ToolResultMemory,
        diff_entry: ?DiffEntryPayload,
        advertised_dynamic_tool_names: []const []const u8,
    ) !bool {
        const recorded_terminal = try self.recordTerminal(alloc, call.id);
        if (!recorded_terminal) return false;
        errdefer self.forgetTerminal(alloc, call.id);
        const target = try self.ensureTerminalTarget(
            hooks,
            arena,
            turn_id,
            call,
            authoritative_started,
            display_target,
            advertised_dynamic_tool_names,
        ) orelse {
            self.forgetTerminal(alloc, call.id);
            return false;
        };
        try finishExecutedToolStatus(
            hooks,
            arena,
            turn_id,
            target.call,
            true,
            display_target,
            result,
            safe_result,
            result_memory,
            diff_entry,
            advertised_dynamic_tool_names,
        );
        if (target.tracked_id) |tracked_id| self.forget(alloc, tracked_id);
        return true;
    }

    pub fn finishCancelledCall(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
        authoritative_started: bool,
        display_target: ?[]const u8,
        result: ToolExecutionResult,
        advertised_dynamic_tool_names: []const []const u8,
    ) !bool {
        const recorded_terminal = try self.recordTerminal(alloc, call.id);
        if (!recorded_terminal) return false;
        errdefer self.forgetTerminal(alloc, call.id);
        const target = try self.ensureTerminalTarget(
            hooks,
            arena,
            turn_id,
            call,
            authoritative_started,
            display_target,
            advertised_dynamic_tool_names,
        ) orelse {
            self.forgetTerminal(alloc, call.id);
            return false;
        };
        try finishCancelledToolStatus(
            hooks,
            arena,
            turn_id,
            target.call,
            true,
            display_target,
            result,
            advertised_dynamic_tool_names,
        );
        if (target.tracked_id) |tracked_id| self.forget(alloc, tracked_id);
        return true;
    }

    pub fn finishTrackedCancelled(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
    ) !void {
        while (self.tracked.items.len > 0) {
            const status = &self.tracked.items[self.tracked.items.len - 1];
            if (self.hasTerminal(status.id)) {
                self.forget(alloc, status.id);
                continue;
            }
            const recorded_terminal = try self.recordTerminal(alloc, status.id);
            if (!recorded_terminal) {
                self.forget(alloc, status.id);
                continue;
            }
            errdefer self.forgetTerminal(alloc, status.id);
            const detail = status.label_value orelse
                fallbackToolDisplay(hooks.tool_registry, status.tool_name);
            const encoded = try text_utils.encodeTerminalSafe(
                arena,
                detail,
                diff.max_encoded_label_bytes,
            );
            const summary = try arena.print("Cancelled {s}", .{encoded.bytes});
            try hooks.push_tool_lifecycle(hooks.ctx, .{ .terminal = .{
                .id = .{ .turn_id = turn_id, .call_id = status.id },
                .outcome = .{ .kind = .cancelled, .summary = summary },
            } });
            self.forget(alloc, status.id);
        }
    }

    /// Settles provisional starts from an interrupted, proven-unexecuted
    /// stream unless the recovered completion retained their identity.
    pub fn finishUnmatchedRecoveryStarts(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        recovered_calls: []const ToolCall,
    ) !void {
        var index = self.tracked.items.len;
        while (index > 0) {
            index -= 1;
            const status = &self.tracked.items[index];
            if (trackedStatusMatchesCalls(status.*, recovered_calls)) continue;
            if (streamStartMayHaveExecutedAtProvider(
                hooks.tool_registry,
                status.tool_name,
            )) continue;
            if (self.hasTerminal(status.id)) {
                self.forget(alloc, status.id);
                continue;
            }
            const recorded_terminal = try self.recordTerminal(alloc, status.id);
            if (!recorded_terminal) {
                self.forget(alloc, status.id);
                continue;
            }
            errdefer self.forgetTerminal(alloc, status.id);
            const detail = status.label_value orelse
                fallbackToolDisplay(hooks.tool_registry, status.tool_name);
            const encoded = try text_utils.encodeTerminalSafe(
                arena,
                detail,
                diff.max_encoded_label_bytes,
            );
            const summary = try arena.print(
                "Connection interrupted before {s} ran",
                .{encoded.bytes},
            );
            try hooks.push_tool_lifecycle(hooks.ctx, .{ .terminal = .{
                .id = .{ .turn_id = turn_id, .call_id = status.id },
                .outcome = .{ .kind = .failed, .summary = summary },
            } });
            self.forget(alloc, status.id);
        }
    }

    pub fn visibleId(self: *const ProvisionalToolStatuses, call: ToolCall) ?[]const u8 {
        if (self.has(call.id)) return call.id;
        if (call.provisional_id) |provisional_id| {
            if (self.has(provisional_id)) return provisional_id;
        }
        return null;
    }

    fn record(self: *ProvisionalToolStatuses, alloc: Allocator, id: []const u8) !bool {
        return self.recordTracked(alloc, id, "", null);
    }

    fn recordTracked(
        self: *ProvisionalToolStatuses,
        alloc: Allocator,
        id: []const u8,
        tool_name: []const u8,
        label_value: ?[]const u8,
    ) !bool {
        if (id.len == 0) return false;
        if (self.findTracked(id)) |index| {
            const status = &self.tracked.items[index];
            if (label_value) |value| {
                const owned_value = try alloc.dupe(u8, value);
                if (status.label_value) |prior| alloc.free(prior);
                status.label_value = owned_value;
            }
            return false;
        }
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const owned_tool_name = try alloc.dupe(u8, tool_name);
        errdefer alloc.free(owned_tool_name);
        const owned_label_value = if (label_value) |value| try alloc.dupe(u8, value) else null;
        errdefer if (owned_label_value) |value| alloc.free(value);
        try self.tracked.append(alloc, .{
            .id = owned_id,
            .tool_name = owned_tool_name,
            .label_value = owned_label_value,
        });
        return true;
    }

    /// Whether the call's row was published. A hidden call has no row to
    /// settle, so the call's own start shows it.
    fn has(self: *const ProvisionalToolStatuses, id: []const u8) bool {
        const index = self.findTracked(id) orelse return false;
        return self.tracked.items[index].shown;
    }

    fn findTracked(self: *const ProvisionalToolStatuses, id: []const u8) ?usize {
        for (self.tracked.items, 0..) |status, i| {
            if (std.mem.eql(u8, status.id, id)) return i;
        }
        return null;
    }

    fn trackedStatusMatchesCalls(
        status: TrackedStatus,
        calls: []const ToolCall,
    ) bool {
        for (calls) |call| {
            if (std.mem.eql(u8, status.id, call.id)) return true;
            if (call.provisional_id) |provisional_id| {
                if (std.mem.eql(u8, status.id, provisional_id)) return true;
            }
        }
        return false;
    }

    fn recordTerminal(self: *ProvisionalToolStatuses, alloc: Allocator, id: []const u8) !bool {
        if (id.len == 0 or self.hasTerminal(id)) return false;
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        try self.terminal_ids.append(alloc, owned_id);
        return true;
    }

    fn hasTerminal(self: *const ProvisionalToolStatuses, id: []const u8) bool {
        for (self.terminal_ids.items) |existing| {
            if (std.mem.eql(u8, existing, id)) return true;
        }
        return false;
    }

    const TerminalTarget = struct {
        call: ToolCall,
        tracked_id: ?[]const u8,
    };

    fn terminalTarget(
        self: *const ProvisionalToolStatuses,
        call: ToolCall,
        authoritative_started: bool,
    ) ?TerminalTarget {
        const visible_id = self.visibleId(call);
        if (authoritative_started) {
            return .{ .call = call, .tracked_id = visible_id };
        }
        const provisional_id = visible_id orelse return null;
        var visible_call = call;
        visible_call.id = provisional_id;
        return .{ .call = visible_call, .tracked_id = provisional_id };
    }

    fn ensureTerminalTarget(
        self: *const ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
        authoritative_started: bool,
        display_target: ?[]const u8,
        advertised_dynamic_tool_names: []const []const u8,
    ) !?TerminalTarget {
        if (self.terminalTarget(call, authoritative_started)) |target| return target;
        const started = try startToolVisibleLifecycle(
            hooks,
            arena,
            turn_id,
            self.presentation_group_id,
            call,
            display_target,
            advertised_dynamic_tool_names,
        );
        if (!started) return null;
        return .{ .call = call, .tracked_id = null };
    }

    fn forget(self: *ProvisionalToolStatuses, alloc: Allocator, id: []const u8) void {
        const index = self.findTracked(id) orelse return;
        self.tracked.items[index].deinit(alloc);
        _ = self.tracked.swapRemove(index);
    }

    fn forgetTerminal(self: *ProvisionalToolStatuses, alloc: Allocator, id: []const u8) void {
        for (self.terminal_ids.items, 0..) |existing, i| {
            if (!std.mem.eql(u8, existing, id)) continue;
            alloc.free(existing);
            _ = self.terminal_ids.swapRemove(i);
            return;
        }
    }
};

pub const ToolPresentationGroupObservation = struct {
    has_visible_tool_calls: bool,
    has_visible_text: bool,
    saw_tool_start: bool,
    saw_visible_text_after_tool_start: bool,
};

pub const ToolPresentationGroupTransition = struct {
    tool_group_id: ?types.ToolPresentationGroupId,
    active_group_id: ?types.ToolPresentationGroupId,
};

pub fn presentationGroupForStep(
    active_group_id: ?types.ToolPresentationGroupId,
    turn_id: u64,
    step_id: u64,
) types.ToolPresentationGroupId {
    if (active_group_id) |group_id| {
        if (group_id.turn_id == turn_id) return group_id;
    }
    return .{ .turn_id = turn_id, .anchor_step_id = step_id };
}

pub fn transitionPresentationGroup(
    active_group_id: ?types.ToolPresentationGroupId,
    tool_group_id: ?types.ToolPresentationGroupId,
    turn_id: u64,
    step_id: u64,
    observation: ToolPresentationGroupObservation,
) ToolPresentationGroupTransition {
    var resolved_tool_group_id = tool_group_id;
    if (observation.has_visible_tool_calls and
        (resolved_tool_group_id == null or
            (!observation.saw_tool_start and observation.has_visible_text)))
    {
        resolved_tool_group_id = .{
            .turn_id = turn_id,
            .anchor_step_id = step_id,
        };
    }

    var next_active_group_id = active_group_id;
    if (observation.has_visible_tool_calls) {
        next_active_group_id = resolved_tool_group_id;
    }
    if (observation.saw_visible_text_after_tool_start or
        (observation.has_visible_text and !observation.has_visible_tool_calls))
    {
        next_active_group_id = null;
    }
    return .{
        .tool_group_id = resolved_tool_group_id,
        .active_group_id = next_active_group_id,
    };
}

pub fn activityKind(registry: tool_dispatch.Registry, tool_name: []const u8) types.ToolActivityKind {
    if (tooling_presentation.isProviderSearchAlias(tool_name)) return .read;
    return tool_dispatch.toolActivityKind(registry, tool_name);
}

pub fn activityKindForCall(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) types.ToolActivityKind {
    if (tooling_presentation.isProviderSearchAlias(call.name)) return .read;
    return tool_dispatch.toolActivityKindForCall(alloc, registry, call);
}

fn formatProvisionalProgressLabel(
    buf: []u8,
    action_label: []const u8,
    label_value: ?[]const u8,
) ![]const u8 {
    if (label_value) |value| {
        return std.mem.print(buf, "● {s}\x1b[0m {s}{s}\x1b[0m", .{ action_label, shared_theme.current().tool_stdout_style, value });
    }
    return std.mem.print(buf, "● {s}\x1b[0m", .{action_label});
}

pub fn fileMutationDisplayPath(
    arena: Allocator,
    authority: command_admission.ToolExecutionAuthority,
) !?[]const u8 {
    return switch (authority) {
        .file_mutation => |file_authority| if (file_authority.prepared) |prepared|
            prepared.display_path
        else blk: {
            const encoded = try text_utils.encodeTerminalSafe(
                arena,
                file_authority.input.path(),
                diff.max_encoded_label_bytes,
            );
            break :blk encoded.bytes;
        },
        else => null,
    };
}

/// The handles under which a tool result keeps its full output or images.
fn savedOutputHandles(
    output_handle: ?[]const u8,
    tool_image_handle: ?[]const u8,
    command_output_replay: ?types.CommandOutputReplay,
) [3]?[]const u8 {
    return .{
        output_handle,
        tool_image_handle,
        if (command_output_replay) |replay| switch (replay) {
            .available => |descriptor| descriptor.handle,
            .unavailable => null,
        } else null,
    };
}

/// Finds which call saved an output among a running prompt's messages: the
/// newest tool result that keeps the handle, and the call that produced it.
pub const TurnSavedOutputSources = struct {
    registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    /// Message lists in conversation order, searched newest first.
    turns: []const []const types.ChatMessage,

    /// Returns the terminal-safe name of the call that saved `handle`, or null
    /// when no message still holds it. The arena owns the returned text.
    pub fn find(self: TurnSavedOutputSources, arena: Allocator, handle: []const u8) !?[]const u8 {
        var turn_index = self.turns.len;
        while (turn_index > 0) {
            turn_index -= 1;
            const messages = self.turns[turn_index];
            var message_index = messages.len;
            while (message_index > 0) {
                message_index -= 1;
                const message = messages[message_index];
                if (message.role != .tool) continue;
                const memory = message.tool_result_memory orelse continue;
                if (!holdsHandle(savedOutputHandles(memory.output_handle, memory.tool_image_handle, memory.command_output_replay), handle)) continue;
                const source = self.findCall(message.tool_call_id orelse return null) orelse return null;
                return tooling_presentation.savedOutputSourceLabel(arena, self.registry, self.workspace_root, source);
            }
        }
        return null;
    }

    fn findCall(self: TurnSavedOutputSources, call_id: []const u8) ?ToolCall {
        var turn_index = self.turns.len;
        while (turn_index > 0) {
            turn_index -= 1;
            const messages = self.turns[turn_index];
            var message_index = messages.len;
            while (message_index > 0) {
                message_index -= 1;
                const message = messages[message_index];
                if (message.role != .assistant) continue;
                for (message.tool_calls) |call| {
                    if (std.mem.eql(u8, call.id, call_id)) return call;
                }
            }
        }
        return null;
    }
};

/// Names of the calls whose saved output later `read_tool_result` calls read,
/// recorded while a saved conversation replays in order and keyed by output
/// handle. Owns its keys and names; free them with `deinit`.
pub const ReplayedSavedOutputSources = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *ReplayedSavedOutputSources, alloc: Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.map.deinit(alloc);
    }

    /// Records `call` under each handle that keeps `result`'s output. A later
    /// call saving the same handle wins.
    pub fn record(
        self: *ReplayedSavedOutputSources,
        alloc: Allocator,
        registry: tool_dispatch.Registry,
        workspace_root: []const u8,
        call: ToolCall,
        result: types.PersistedToolResult,
    ) Allocator.Error!void {
        const handles = savedOutputHandles(result.output_handle, result.tool_image_handle, result.command_output_replay);
        for (handles) |maybe_handle| {
            if (maybe_handle != null) break;
        } else return;
        const label = (try tooling_presentation.savedOutputSourceLabel(alloc, registry, workspace_root, call)) orelse return;
        defer alloc.free(label);
        for (handles) |maybe_handle| {
            const handle = maybe_handle orelse continue;
            const owned_handle = try alloc.dupe(u8, handle);
            errdefer alloc.free(owned_handle);
            const owned_label = try alloc.dupe(u8, label);
            errdefer alloc.free(owned_label);
            const gop = try self.map.getOrPut(alloc, owned_handle);
            if (gop.found_existing) {
                alloc.free(owned_handle);
                alloc.free(gop.value_ptr.*);
            }
            gop.value_ptr.* = owned_label;
        }
    }

    /// The name of the call that saved `handle`, borrowed from the map, for
    /// `readToolResultDisplayTarget`.
    pub fn find(self: *const ReplayedSavedOutputSources, _: Allocator, handle: []const u8) error{}!?[]const u8 {
        return self.map.get(handle);
    }
};

fn holdsHandle(handles: [3]?[]const u8, handle: []const u8) bool {
    for (handles) |candidate| {
        if (std.mem.eql(u8, candidate orelse continue, handle)) return true;
    }
    return false;
}

/// Row text for a `read_tool_result` call: what it reads, and the earlier
/// call whose output that is when `sources.find(arena, handle)` still knows
/// it. Returns null for other tools. The arena owns the returned text.
pub fn readToolResultDisplayTarget(
    arena: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
    sources: anytype,
) !?[]const u8 {
    const spec = registry.lookup(call.name) orelse return null;
    if (spec.executor_kind != .read_tool_result) return null;
    const source = if (try read_result_presentation.requestedHandle(arena, call.arguments_json)) |handle|
        try sources.find(arena, handle)
    else
        null;
    return try read_result_presentation.displayTarget(arena, call.arguments_json, source);
}

test "read_tool_result rows name the earlier call whose output they read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const registry = test_builtin_tools.advertisement_set.registry;
    const replay = "spark-command-replay-0123.bin";
    const earlier_turn = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &.{.{
            .id = "read-1",
            .name = "read_file",
            .arguments_json = "{\"path\":\"src/main.zig\"}",
        }} },
        .{ .role = .tool, .tool_call_id = "read-1", .tool_result_memory = .{ .output_handle = "result-read_file-1.txt" } },
    };
    const current_turn = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &.{.{
            .id = "run-1",
            .name = "shell",
            .arguments_json = "{\"action\":\"run\",\"command\":\"zig build test\"}",
        }} },
        .{ .role = .tool, .tool_call_id = "run-1", .tool_result_memory = .{
            .command_output_replay = .{ .available = .{ .handle = replay, .framed_bytes = 64 } },
        } },
    };
    const sources: TurnSavedOutputSources = .{
        .registry = registry,
        .workspace_root = "/workspace",
        .turns = &.{ earlier_turn[0..], current_turn[0..] },
    };
    const cases = [_]struct { arguments_json: []const u8, expected: ?[]const u8 }{
        .{ .arguments_json = "{\"request\":{\"handle\":\"" ++ replay ++ "\",\"start_byte\":9}}", .expected = "more output from zig build test" },
        .{ .arguments_json = "{\"request\":{\"handle\":\"" ++ replay ++ "\",\"query\":\"error:\"}}", .expected = "zig build test output for \"error:\"" },
        // The model may drop the `.txt` that `validate` restores.
        .{ .arguments_json = "{\"request\":{\"handle\":\"result-read_file-1\"}}", .expected = "more output from src/main.zig" },
        .{ .arguments_json = "{\"request\":{\"handle\":\"spark-command-replay-ffff.bin\"}}", .expected = null },
        .{ .arguments_json = "{\"request\":{\"handle\":\"T5\"}}", .expected = "earlier tool call T5" },
    };
    for (cases) |case| {
        const call: ToolCall = .{ .id = "page", .name = "read_tool_result", .arguments_json = case.arguments_json };
        const target = try readToolResultDisplayTarget(arena, registry, call, sources);
        if (case.expected) |expected| {
            try std.testing.expectEqualStrings(expected, target orelse return error.TestExpectedDisplayTarget);
        } else {
            try std.testing.expect(target == null);
        }
    }
    const other: ToolCall = .{ .id = "grep", .name = "grep_files", .arguments_json = "{\"pattern\":\"x\"}" };
    try std.testing.expect(try readToolResultDisplayTarget(arena, registry, other, sources) == null);
}

pub noinline fn startToolVisibleLifecycle(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    presentation_group_id: ?types.ToolPresentationGroupId,
    call: ToolCall,
    display_target: ?[]const u8,
    advertised_dynamic_tool_names: []const []const u8,
) !bool {
    const activity_kind = activityKindForCall(arena, hooks.tool_registry, call);
    if (activity_kind == .ask) return false;
    const redacted_arguments = try text_utils.maskSecrets(arena, call.arguments_json);
    const activity_line = if (call.argument_integrity == .valid) try hooks.describe_tool_action(
        hooks.ctx,
        arena,
        call,
        display_target,
        advertised_dynamic_tool_names,
    ) else null;
    try hooks.push_tool_lifecycle(hooks.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = turn_id, .call_id = call.id },
        .presentation_group_id = presentation_group_id,
        .reconciles_provisional_call_id = call.provisional_id,
        .tool_name = call.name,
        .activity_kind = activity_kind,
        .arguments_json = redacted_arguments,
        .place_after_current_transcript = false,
        .resolved_display_target = call.resolved_display_target,
    } });
    if (activity_line) |line| {
        try hooks.push_tool_lifecycle(hooks.ctx, .{ .progress = .{
            .id = .{ .turn_id = turn_id, .call_id = call.id },
            .text = line,
        } });
    }
    return true;
}

pub fn finishDeniedToolStatus(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    status_started: bool,
    display_target: ?[]const u8,
    label: []const u8,
    advertised_dynamic_tool_names: []const []const u8,
) !void {
    return finishDeniedToolStatusInternal(
        hooks,
        arena,
        turn_id,
        call,
        status_started,
        display_target,
        label,
        advertised_dynamic_tool_names,
        null,
        null,
        null,
    );
}

fn finishDeferredToolStatus(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    advertised_dynamic_tool_names: []const []const u8,
) !void {
    const line = try hooks.describe_tool_action_denied(
        hooks.ctx,
        arena,
        call,
        null,
        types.context_deferred_tool_status_label,
        advertised_dynamic_tool_names,
    );
    try hooks.push_tool_lifecycle(hooks.ctx, .{ .terminal = .{
        .id = .{ .turn_id = turn_id, .call_id = call.id },
        .outcome = .{
            .kind = .deferred,
            .summary = line,
        },
    } });
}

fn finishDeniedToolStatusInternal(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    status_started: bool,
    display_target: ?[]const u8,
    label: []const u8,
    advertised_dynamic_tool_names: []const []const u8,
    safe_result: ?[]const u8,
    result_memory: ?types.ToolResultMemory,
    command_result_json: ?[]const u8,
) !void {
    if (!status_started) return;
    const denied_line = try hooks.describe_tool_action_denied(
        hooks.ctx,
        arena,
        call,
        display_target,
        label,
        advertised_dynamic_tool_names,
    );
    const command_artifact_handle = if (activityKindForCall(arena, hooks.tool_registry, call) == .command)
        try commandArtifactHandle(arena, command_result_json)
    else
        null;
    try hooks.push_tool_lifecycle(hooks.ctx, .{
        .terminal = .{
            .id = .{ .turn_id = turn_id, .call_id = call.id },
            .outcome = .{
                .kind = if (std.mem.eql(u8, label, "Cancelled"))
                    .cancelled
                else if (std.mem.eql(u8, label, "Failed"))
                    .failed
                else
                    .denied,
                .summary = denied_line,
            },
            .result = safe_result,
            .result_memory = result_memory,
            .command_artifact_handle = command_artifact_handle,
        },
    });
}

pub fn finishCancelledToolStatus(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    status_started: bool,
    display_target: ?[]const u8,
    result: ToolExecutionResult,
    advertised_dynamic_tool_names: []const []const u8,
) !void {
    if (!status_started) return;
    const label = if (try isShellWaitCall(arena, call))
        "Stopped waiting for"
    else
        "Cancelled";
    const line = try hooks.describe_tool_action_denied(
        hooks.ctx,
        arena,
        call,
        display_target,
        label,
        advertised_dynamic_tool_names,
    );
    const command_activity = activityKindForCall(
        arena,
        hooks.tool_registry,
        call,
    ) == .command;
    const shell_command = command_activity and std.mem.eql(u8, call.name, "shell");
    const command_artifact_handle = if (command_activity and !shell_command)
        commandArtifactHandle(arena, result.command_result_json) catch |err| blk: {
            debug_trace.logf("tool", "cancelled command artifact handle omitted err={s}", .{@errorName(err)});
            break :blk null;
        }
    else
        null;
    try hooks.push_tool_lifecycle(hooks.ctx, .{ .terminal = .{
        .id = .{ .turn_id = turn_id, .call_id = call.id },
        .outcome = .{
            .kind = .cancelled,
            .summary = line,
        },
        .result_memory = result.tool_result_memory,
        .command_artifact_handle = command_artifact_handle,
    } });
}

fn isShellWaitCall(arena: Allocator, call: ToolCall) Allocator.Error!bool {
    if (!std.mem.eql(u8, call.name, "shell")) return false;
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        arena,
        call.arguments_json,
        .{},
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => false,
    };
    defer parsed.deinit();
    const outer = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const object = (try tool_args.unwrapRequest(parsed.arena.allocator(), outer)) orelse return false;
    const action = switch (object.get("action") orelse return false) {
        .string => |value| value,
        else => return false,
    };
    return std.mem.eql(u8, action, "wait");
}

pub fn publishSubagentCompletionPreview(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    result: ToolExecutionResult,
    advertised_dynamic_tool_names: []const []const u8,
) !bool {
    if (!std.mem.eql(u8, call.name, "subagent")) return false;
    const base_line = if (try tooling_presentation.subagentStatusLine(
        arena,
        call,
        result.model_output,
    )) |line|
        try arena.print("● {s}", .{line})
    else switch (result.status) {
        .success => try hooks.describe_tool_action_completed(
            hooks.ctx,
            arena,
            call,
            null,
            advertised_dynamic_tool_names,
        ),
        .failure => try hooks.describe_tool_action_denied(
            hooks.ctx,
            arena,
            call,
            null,
            try tooling_presentation.subagentFailureLabel(
                arena,
                call,
                result.model_output,
            ),
            advertised_dynamic_tool_names,
        ),
    };
    const line = if (result.subagent_completion) |status|
        renderedSubagentSummary(hooks, arena, base_line, status)
    else
        base_line;
    try hooks.push_tool_lifecycle(hooks.ctx, .{ .progress = .{
        .id = .{ .turn_id = turn_id, .call_id = call.id },
        .text = line,
    } });
    return true;
}

pub fn finishExecutedToolStatus(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    status_started: bool,
    display_target: ?[]const u8,
    result: ToolExecutionResult,
    safe_result: []const u8,
    result_memory: types.ToolResultMemory,
    diff_entry: ?DiffEntryPayload,
    advertised_dynamic_tool_names: []const []const u8,
) !void {
    if (!status_started) return;
    const activity_kind = activityKindForCall(arena, hooks.tool_registry, call);
    const command_decision = if (activity_kind == .command)
        (try commandOutcomeDecision(arena, result_memory.command_process_presentation)) orelse
            try runningCommandDecision(arena, call, result.model_output)
    else
        null;
    const terminal_action_decision = if (std.mem.eql(u8, call.name, "shell"))
        try terminalActionOutcomeDecision(arena, result_memory.terminal_action_presentation)
    else
        null;
    const outcome_decision = command_decision orelse terminal_action_decision;
    const base_line = if (try tooling_presentation.subagentStatusLine(arena, call, result.model_output)) |line|
        line
    else if (outcome_decision) |decision| blk: {
        const base = try hooks.describe_tool_action_denied(
            hooks.ctx,
            arena,
            call,
            display_target,
            decision.label,
            advertised_dynamic_tool_names,
        );
        break :blk if (decision.detail) |detail|
            try arena.print("{s}: {s}", .{ base, detail })
        else
            base;
    } else switch (result.status) {
        .success => if (file_mutation_contract.resultIsNoop(call.name, result.model_output))
            result.model_output
        else
            try hooks.describe_tool_action_completed(
                hooks.ctx,
                arena,
                call,
                display_target,
                advertised_dynamic_tool_names,
            ),
        .failure => blk: {
            const base = try hooks.describe_tool_action_denied(
                hooks.ctx,
                arena,
                call,
                display_target,
                try tooling_presentation.subagentFailureLabel(arena, call, safe_result),
                advertised_dynamic_tool_names,
            );
            if (std.mem.eql(u8, call.name, "shell")) {
                if (try tool_result_errors.isTerminalEndedFailure(arena, safe_result)) {
                    break :blk try arena.print("{s} · ended when spark exited", .{base});
                }
                if (try tool_result_errors.inspectTerminalActionFieldCorrection(
                    arena,
                    safe_result,
                )) |correction| {
                    break :blk try arena.print(
                        "{s} · {d} invalid field{s}",
                        .{
                            base,
                            correction.invalid_field_count,
                            if (correction.invalid_field_count == 1) "" else "s",
                        },
                    );
                }
            }
            const detail = (try failureStatusDetail(
                arena,
                call,
                result,
                safe_result,
                advertised_dynamic_tool_names,
            )) orelse break :blk base;
            if (detail.len == 0) break :blk base;
            break :blk try arena.print("{s}: {s}", .{ base, detail });
        },
    };
    const summary_line = if (result.web_fetch_completion) |completion|
        try formatWebFetchCompletion(arena, base_line, completion)
    else if (result.web_search_completion) |completion|
        try formatWebSearchCompletion(arena, base_line, completion)
    else if (result.subagent_completion) |status|
        renderedSubagentSummary(hooks, arena, base_line, status)
    else
        base_line;
    const line = if (diff_entry) |payload| blk: {
        break :blk try formatToolStatusWithStats(arena, summary_line, payload.additions, payload.deletions, hooks.diff_marker_styles);
    } else summary_line;
    const shell_command = activity_kind == .command and
        std.mem.eql(u8, call.name, "shell");
    const presentation_result = try presentedToolResult(
        arena,
        call,
        activity_kind,
        if (shell_command) result.model_output else safe_result,
    );
    var presentation_memory = result_memory;
    if (shell_command) {
        presentation_memory.output_handle = null;
        presentation_memory.preview = presentation_result;
    }
    const command_artifact_handle = if (activity_kind == .command and
        !shell_command)
        try commandArtifactHandle(arena, result.command_result_json)
    else
        null;
    try hooks.push_tool_lifecycle(hooks.ctx, .{
        .terminal = .{
            .id = .{ .turn_id = turn_id, .call_id = call.id },
            .outcome = .{
                .kind = if (outcome_decision) |decision|
                    decision.outcome
                else if (result.status == .success)
                    .completed
                else
                    .failed,
                .summary = line,
            },
            .result = presentation_result,
            .result_memory = presentation_memory,
            .command_artifact_handle = command_artifact_handle,
        },
    });
}

fn presentedToolResult(
    arena: Allocator,
    call: ToolCall,
    activity_kind: types.ToolActivityKind,
    safe_result: []const u8,
) Allocator.Error![]const u8 {
    if (activity_kind != .command or !std.mem.eql(u8, call.name, "shell")) {
        return safe_result;
    }
    return try managed_execution.modelOutputDelta(arena, safe_result) orelse
        safe_result;
}

pub const ToolOutcomeDecision = struct {
    outcome: types.ToolOutcomeKind,
    label: []const u8,
    detail: ?[]const u8 = null,
};

pub fn commandOutcomeDecision(
    arena: Allocator,
    presentation: ?types.CommandProcessPresentation,
) !?ToolOutcomeDecision {
    const value = presentation orelse return null;
    return switch (value) {
        .exit_code => |code| if (code == 0)
            .{ .outcome = .completed, .label = "Ran" }
        else
            .{
                .outcome = .failed,
                .label = try arena.print("Exited {d}", .{code}),
            },
        .signal => |signal| .{
            .outcome = .failed,
            .label = try arena.print("Signaled {d}", .{signal}),
        },
        .timed_out => .{ .outcome = .failed, .label = "Timed out" },
        .output_capture_failed => .{
            .outcome = .failed,
            .label = "Output capture failed",
        },
    };
}

/// The label of a shell `run` whose command was still running when the call
/// returned, such as when steering moved it to the background or its
/// `yield_time_ms` ran out. It has no exit status, so it must not read "Ran".
pub const still_running_label = "Still running";

/// The outcome of a shell `run` call whose result `output` reports
/// `"state":"running"`, or null for any other call or result.
pub fn runningCommandDecision(
    arena: Allocator,
    call: ToolCall,
    output: []const u8,
) !?ToolOutcomeDecision {
    if (!std.mem.eql(u8, call.name, "shell")) return null;
    if (std.mem.find(u8, output, "\"running\"") == null) return null;
    // Only text that is not JSON gives no decision; running out of memory is
    // reported, so the row does not read "Ran" for a command that still runs.
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const action = tool_args.optionalStringArg(args, "action") orelse "run";
    if (!std.mem.eql(u8, action, "run")) return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, output, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parsed != .object) return null;
    const state = parsed.object.get("state") orelse return null;
    if (state != .string or !std.mem.eql(u8, state.string, "running")) return null;
    return .{ .outcome = .completed, .label = still_running_label };
}

fn checkRunningCommandDecisionAllocationFailures(alloc: Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const run = ToolCall{ .id = "run", .name = "shell", .arguments_json = "{\"action\":\"run\",\"command\":\"sleep 30\"}" };
    const running = "{\"session_id\":\"shell-1\",\"state\":\"running\"}";
    const decision = (try runningCommandDecision(arena_state.allocator(), run, running)).?;
    try std.testing.expectEqualStrings(still_running_label, decision.label);
}

pub fn terminalActionOutcomeDecision(
    arena: Allocator,
    presentation: ?types.TerminalActionPresentation,
) !?ToolOutcomeDecision {
    const value = presentation orelse return null;
    return switch (value) {
        .returned => |returned| switch (returned) {
            .started => .{ .outcome = .completed, .label = "Started" },
            .condition_met => .{ .outcome = .completed, .label = "Condition met for" },
            .safety_ceiling => .{ .outcome = .completed, .label = "Wait limit reached for" },
            .cancelled => .{ .outcome = .cancelled, .label = "Cancelled" },
            .exited => |code| .{
                .outcome = if (code == 0) .completed else .failed,
                .label = try arena.print("Exited {d}", .{code}),
            },
            .signal => |signal| .{
                .outcome = .failed,
                .label = try arena.print("Terminated by signal {d}", .{signal}),
            },
        },
        .failed => |failed| if (failed == .cancelled)
            .{ .outcome = .cancelled, .label = "Cancelled" }
        else
            .{
                .outcome = .failed,
                .label = "Failed",
                .detail = failed.detail(),
            },
    };
}

fn failureStatusDetail(
    arena: Allocator,
    call: ToolCall,
    result: ToolExecutionResult,
    safe_result: []const u8,
    advertised_dynamic_tool_names: []const []const u8,
) !?[]const u8 {
    switch (call.argument_integrity) {
        .malformed_json => return "invalid JSON arguments",
        .non_object_json => return "non-object arguments",
        .valid => {},
    }
    if (result.status_detail) |detail| {
        if (!std.mem.eql(u8, detail, "preflight failed")) return detail;

        if (file_mutation_contract.isToolName(call.name) and
            std.mem.startsWith(u8, safe_result, call.name))
        {
            const failure_prefix = " failed: ";
            const remainder = safe_result[call.name.len..];
            if (std.mem.startsWith(u8, remainder, failure_prefix)) {
                // Lines after the first carry detail for the model, such as
                // the text a failed edit most likely meant.
                const reason = remainder[failure_prefix.len..];
                const actionable = reason[0 .. std.mem.findScalar(u8, reason, '\n') orelse reason.len];
                if (actionable.len > 0 and
                    std.mem.findScalar(u8, actionable, '\r') == null)
                {
                    const masked = try text_utils.maskSecrets(arena, actionable);
                    const encoded = try text_utils.encodeTerminalSafeInline(arena, masked, 256);
                    return if (encoded.bytes.len == 0) detail else encoded.bytes;
                }
            }
        }

        if (safe_result.len == 0) return detail;
        const masked = try text_utils.maskSecrets(arena, safe_result);
        const encoded = try text_utils.encodeTerminalSafeInline(arena, masked, 256);
        return if (encoded.bytes.len == 0) detail else encoded.bytes;
    }

    // An MCP call shows why it failed, made directly or through toolbox.
    const mcp_call = containsName(advertised_dynamic_tool_names, call.name) or
        if (try toolbox.carriedCall(arena, call.name, call.arguments_json)) |run| types.isMcpToolName(run.name) else false;
    if (safe_result.len == 0 or !mcp_call) return null;
    const server_text = try mcpFailureEnvelopeText(arena, safe_result) orelse safe_result;
    // A refused call's parameters read as which fields and types, not as the
    // start of a protocol dump; the model still gets the server's own words.
    const detail = try mcp_tool_result.invalidParamsCause(arena, server_text) orelse server_text;
    const masked_detail = try text_utils.maskSecrets(arena, detail);
    const encoded = try text_utils.encodeTerminalSafeInline(arena, masked_detail, 256);
    return if (encoded.bytes.len == 0) null else encoded.bytes;
}

fn mcpFailureEnvelopeText(
    arena: Allocator,
    safe_result: []const u8,
) Allocator.Error!?[]const u8 {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        arena,
        safe_result,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    const envelope = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const payload = envelope.get("result") orelse envelope.get("error") orelse
        return null;
    const payload_object = switch (payload) {
        .object => |object| object,
        else => return null,
    };
    if (payload_object.get("content")) |content| {
        if (content == .array) {
            for (content.array.items) |item| {
                if (item != .object) continue;
                const text = item.object.get("text") orelse continue;
                if (text == .string and text.string.len > 0) {
                    const owned: []const u8 = try arena.dupe(u8, text.string);
                    return owned;
                }
            }
        }
    }
    const message = payload_object.get("message") orelse return null;
    if (message != .string or message.string.len == 0) return null;
    const owned: []const u8 = try arena.dupe(u8, message.string);
    return owned;
}

fn containsName(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn commandArtifactHandle(
    arena: Allocator,
    command_result_json: ?[]const u8,
) !?[]const u8 {
    const json = command_result_json orelse return null;
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return null,
    };
    const kind = switch (object.get("kind") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    if (!std.mem.eql(u8, kind, "command") and
        !std.mem.eql(u8, kind, "foreground")) return null;
    const output_file = switch (object.get("output_file") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    const handle = std.Io.Dir.path.basename(output_file);
    if (!std.mem.startsWith(u8, handle, "spark-command-") or
        !std.mem.endsWith(u8, handle, ".log") or
        std.mem.endsWith(u8, handle, ".stdout.log") or
        std.mem.endsWith(u8, handle, ".stderr.log")) return null;
    const owned: []const u8 = try arena.dupe(u8, handle);
    return owned;
}

pub fn finishCommittedFileStatus(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    status_started: bool,
    display_target: ?[]const u8,
    preview: diff.FileChangePreview,
    advertised_dynamic_tool_names: []const []const u8,
) !void {
    if (!status_started) return;
    const base_line = try hooks.describe_tool_action_completed(
        hooks.ctx,
        arena,
        call,
        display_target,
        advertised_dynamic_tool_names,
    );
    const line = try formatToolStatusWithStats(
        arena,
        base_line,
        preview.additions,
        preview.deletions,
        hooks.diff_marker_styles,
    );
    try hooks.push_tool_lifecycle(hooks.ctx, .{
        .terminal = .{
            .id = .{ .turn_id = turn_id, .call_id = call.id },
            .outcome = .{
                .kind = .completed,
                .summary = line,
            },
        },
    });
}

fn renderedSubagentSummary(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    base: []const u8,
    status: types.SubagentStatus,
) []const u8 {
    const renderer = hooks.subagent_status_renderer orelse return base;
    var buf: [256]u8 = undefined;
    const status_line = renderer.render(&buf, status);
    if (status_line.len == 0) return base;
    return arena.print("{s}\n  {s}", .{ base, status_line }) catch base;
}

fn formatWebSearchCompletion(arena: Allocator, base: []const u8, completion: types.WebSearchCompletion) ![]const u8 {
    return arena.print(
        "{s} \x1b[38;5;245m| {d} search{s} | {d}ms\x1b[0m",
        .{ base, completion.searches, if (completion.searches == 1) "" else "es", completion.duration_ms },
    );
}

fn formatWebFetchCompletion(arena: Allocator, base: []const u8, completion: types.WebFetchCompletion) ![]const u8 {
    const cache = if (completion.cache_hit) "cache hit" else "fetched";
    const artifact = switch (completion.artifact_state) {
        .none => "",
        .stored => " | artifact stored",
        .unavailable => " | artifact unavailable",
    };
    return arena.print(
        "{s} \x1b[38;5;245m| {s} | {d} bytes | HTTP {d} | {d}ms | {s}{s}\x1b[0m",
        .{ base, completion.url(), completion.bytes, completion.status, completion.duration_ms, cache, artifact },
    );
}

pub fn formatToolStatusWithStats(
    arena: Allocator,
    base: []const u8,
    additions: usize,
    deletions: usize,
    markers: runtime_deps.DiffMarkerStyles,
) ![]const u8 {
    const accent = "\x1b[38;5;252m";
    const dim = "\x1b[38;5;245m";
    const reset = "\x1b[0m";
    // Fall back to the neutral accent when no marker color is supplied.
    const add_style = if (markers.added.len != 0) markers.added else accent;
    const rem_style = if (markers.removed.len != 0) markers.removed else accent;
    if (additions > 0 and deletions > 0) {
        return arena.print("{s} {s}+{d}{s} {s}/{s} {s}-{d}{s}", .{ base, add_style, additions, reset, dim, reset, rem_style, deletions, reset });
    } else if (additions > 0) {
        return arena.print("{s} {s}+{d}{s}", .{ base, add_style, additions, reset });
    } else if (deletions > 0) {
        return arena.print("{s} {s}-{d}{s}", .{ base, rem_style, deletions, reset });
    }
    return base;
}

const test_tools = [_]tool_dispatch.Tool{
    test_builtin_tools.glob_files,
    test_builtin_tools.read_file,
    test_builtin_tools.write_file,
    test_builtin_tools.edit_file,
    test_builtin_tools.shell,
    test_builtin_tools.ask_user_question,
    test_builtin_tools.toolbox,
    test_builtin_tools.subagent,
};
const test_tool_registry = tool_dispatch.Registry{ .tools = test_tools[0..] };
const custom_activity_tool = blk: {
    var tool = test_builtin_tools.read_file;
    tool.name = "custom_activity";
    tool.action_label = "Custom activity";
    tool.activity_kind = .open;
    break :blk tool;
};
const custom_activity_registry = tool_dispatch.Registry{ .tools = &.{custom_activity_tool} };

const ProvisionalStatusTestCapture = struct {
    alloc: Allocator,
    tool_registry: tool_dispatch.Registry = test_tool_registry,
    events: std.ArrayList(types.ToolLifecycleEvent) = .empty,
    fail_provisional: bool = false,
    fail_progress: bool = false,
    fail_terminal: bool = false,
    retain_events: bool = true,

    fn deinit(self: *ProvisionalStatusTestCapture) void {
        const worker_runtime = @import("../worker_runtime.zig");
        for (self.events.items) |event| worker_runtime.freeToolLifecycleEvent(self.alloc, event);
        self.events.deinit(self.alloc);
    }

    fn hooks(self: *ProvisionalStatusTestCapture) AgentRuntimeDeps {
        return .{
            .ctx = self,
            .tool_registry = self.tool_registry,
            .append_runtime_context = noopAppendRuntimeContext,
            .request_tool_permission = noopRequestPermission,
            .describe_tool_action = describeToolAction,
            .describe_tool_action_completed = describeToolAction,
            .describe_tool_action_denied = describeDeniedToolAction,
            .permission_target_for_call = noopPermissionTarget,
            .execute_tool_call = noopExecuteToolCall,
            .publish_committed_file_handoff = noopPublishCommittedFileHandoff,
            .propagate_history_turn = noopPropagateHistoryTurn,
            .push_event = noopPushEvent,
            .push_text = noopPushText,
            .push_tool_lifecycle = captureToolLifecycle,
            .push_diff_block = noopPushDiffBlock,
            .push_system_notice = noopPushSystemNotice,
            .push_command_output_complete = noopPushCommandOutputComplete,
            .push_http_error = noopPushHttpError,
            .format_tool_execution_error = noopFormatToolExecutionError,
        };
    }

    fn noopAppendRuntimeContext(_: *anyopaque, _: Allocator, _: *std.ArrayList(types.ChatMessage)) !void {}
    fn noopRequestPermission(_: *anyopaque, _: Allocator, _: ToolCall, _: ?runtime_tool_contracts.LiveToolAuthority, _: ?command_admission.ToolExecutionAuthority, _: []const []const u8) !command_admission.PermissionOutcome {
        return .{ .decision = .once, .execution_authority = .ordinary };
    }
    fn describeToolAction(_: *anyopaque, arena: Allocator, call: ToolCall, _: ?[]const u8, _: []const []const u8) ![]const u8 {
        return arena.print("started {s}", .{call.name});
    }
    fn describeDeniedToolAction(_: *anyopaque, arena: Allocator, call: ToolCall, _: ?[]const u8, label: []const u8, _: []const []const u8) ![]const u8 {
        return arena.print("{s} {s}", .{ label, call.name });
    }
    fn noopPermissionTarget(_: *anyopaque, arena: Allocator, _: ToolCall, _: []const []const u8) ![]const u8 {
        return arena.dupe(u8, "");
    }
    fn noopExecuteToolCall(_: *anyopaque, _: runtime_tool_contracts.ToolExecutionRequest) !ToolExecutionResult {
        return .{ .model_output = "" };
    }
    fn noopPublishCommittedFileHandoff(_: *anyopaque, _: @import("../../tooling/file_mutation.zig").CommittedFileHandoff) runtime_tool_contracts.SecondaryPublicationReport {
        return .{ .diff = .skipped, .tracker = .skipped };
    }
    fn noopPropagateHistoryTurn(_: *anyopaque, _: types.HistoryTurn) !void {}
    fn noopPushEvent(_: *anyopaque, _: @import("../worker_runtime.zig").WorkerEvent) !void {}
    fn noopPushText(_: *anyopaque, _: runtime_deps.TextEmission) !void {}
    fn noopPushDiffBlock(_: *anyopaque, _: DiffEntryPayload) !void {}
    fn noopPushSystemNotice(_: *anyopaque, _: []const u8) !void {}
    fn noopPushCommandOutputComplete(_: *anyopaque, _: ?types.ToolLifecycleId) !void {}
    fn noopPushHttpError(_: *anyopaque, _: std.http.Status, _: []const u8, _: ?types.CredentialSource) !void {}
    fn noopFormatToolExecutionError(_: *anyopaque, arena: Allocator, _: []const u8, err: anyerror) ![]const u8 {
        return arena.print("{s}", .{@errorName(err)});
    }

    fn captureToolLifecycle(raw: *anyopaque, event: types.ToolLifecycleEvent) !void {
        const self: *ProvisionalStatusTestCapture = @ptrCast(@alignCast(raw));
        switch (event) {
            .provisional => if (self.fail_provisional) return error.TestProvisionalPublicationFailure,
            .progress => if (self.fail_progress) return error.TestProgressPublicationFailure,
            .terminal => if (self.fail_terminal) return error.TestTerminalPublicationFailure,
            else => {},
        }
        if (!self.retain_events) return;

        const worker_runtime = @import("../worker_runtime.zig");
        const owned = try worker_runtime.dupeToolLifecycleEvent(self.alloc, event);
        errdefer worker_runtime.freeToolLifecycleEvent(self.alloc, owned);
        try self.events.append(self.alloc, owned);
    }
};

fn testToolCall(id: []const u8, name: []const u8) ToolCall {
    return .{ .id = id, .name = name, .arguments_json = "{}" };
}

fn eligibleActionLabel(tool_name: []const u8) []const u8 {
    return switch (ProvisionalToolStatuses.preflight(test_tool_registry, tool_name) orelse unreachable) {
        .eligible => |metadata| metadata.action_label,
        .ineligible => unreachable,
    };
}

fn checkProvisionalLifecycleAllocationFailures(alloc: Allocator) !void {
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc, .retain_events = false };
    defer capture.deinit();
    const hooks = capture.hooks();
    var statuses = ProvisionalToolStatuses{};
    defer statuses.deinit(alloc);

    try statuses.publish(&hooks, alloc, 1, "read_1", "read_file", activityKind(hooks.tool_registry, "read_file"), eligibleActionLabel("read_file"), null, null);
    try std.testing.expect(statuses.has("read_1"));
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try std.testing.expect(try statuses.finishExecutedCall(
        &hooks,
        alloc,
        arena_state.allocator(),
        1,
        .{ .id = "read_1", .name = "read_file", .arguments_json = "{}", .argument_integrity = .malformed_json },
        false,
        null,
        .{ .status = .failure, .model_output = "diagnostic" },
        "diagnostic",
        .{},
        null,
        &.{},
    ));
}
