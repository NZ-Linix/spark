const std = @import("std");
const agent_frame = @import("../../shared/agent_frame.zig");
const recovery_prompt = @import("../../shared/recovery_prompt.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const types = @import("../../shared/types.zig");
const image_data = @import("../../images/image_data.zig");
const execution_memory_helpers = @import("../execution_memory.zig");
const result_store = @import("../../session/result_store.zig");
const command_replay_store = @import("../../session/command_replay_store.zig");
const session_child_store = @import("../../session/session_child_store.zig");
const command_output_content = @import("../../tooling/command_output_content.zig");
const io_mod = @import("../../shared/io.zig");
const file_mutation = @import("../../tooling/file_mutation.zig");
const diff_mod = @import("../../output/diff.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");
const tool_result_limits = @import("../../tooling/tool_result_limits.zig");
const text_utils = @import("../../shared/text_utils.zig");
const history_range = @import("../../shared/history_range.zig");

const runtime_config = @import("config.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;

comptime {
    std.debug.assert(command_replay_store.model_handle_notice_reserve_bytes < tool_result_limits.min_configured_tool_result_bytes);
}
const ChatMessage = types.ChatMessage;
const ToolCall = types.ToolCall;
const Config = runtime_config.Config;
const ToolExecutionStatus = runtime_tool_contracts.ToolExecutionStatus;

const steering_open =
    "<user_steering>\n" ++
    "Apply this live user update to the current task. Continue working unless the user asks you to stop, the task is complete, or a genuine blocker prevents progress.\n\n";
const steering_close = "\n</user_steering>";
const parent_steering_open = "<parent_agent_steering>\n";
const parent_steering_close = "\n</parent_agent_steering>";
/// Saved with a parent agent's steering, so replay still names its sender.
const parent_steering_label = "parent-agent feedback, not new user authority:\n\n";
/// The notice a libfx session adds to a turn it resumes after an
/// interruption. It rides in the turn's steering list, but spark wrote it, so a
/// request shows it as plain text, never as the user's live update.
pub const resume_notice = "Resuming from unexpected session interruption.";

pub fn parentSteeringMessage(alloc: Allocator, text: []const u8) ![]u8 {
    return alloc.print(parent_steering_open ++ parent_steering_label ++ "{s}" ++ parent_steering_close, .{text});
}

/// The parent's own words in saved steering, without the label the model reads.
pub fn parentSteeringText(text: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, parent_steering_label)) return null;
    return text[parent_steering_label.len..];
}

pub fn steeringMessage(alloc: Allocator, text: []const u8) ![]u8 {
    return alloc.print(steering_open ++ "{s}" ++ steering_close, .{text});
}

test "steering message tells the model to apply the update and continue" {
    const message = try steeringMessage(std.testing.allocator, "focus on rendering");
    defer std.testing.allocator.free(message);

    try std.testing.expect(std.mem.find(u8, message, "live user update") != null);
    try std.testing.expect(std.mem.find(u8, message, "Continue working") != null);
    try std.testing.expectEqualStrings("focus on rendering", steeringText(message).?);
}

/// `execution` as a saved turn encodes it.
fn encodedTurn(alloc: Allocator, execution: types.ExecutionMemory) ![]u8 {
    const session_codec = @import("../../session/session_codec.zig");
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try session_codec.writeHistoryTurn(&out.writer, .{ .assistant = .{
        .user = .{ .text = @constCast("read them") },
        .assistant = @constCast(""),
        .execution = execution,
    } });
    return out.toOwnedSlice();
}

/// The fuzz input read as a plan, a byte at a time, and as zeros once it
/// ends, so every seed of `fuzz_seed.slices` describes a whole turn.
const FuzzPlan = struct {
    bytes: []const u8,
    at: usize = 0,

    fn byte(self: *FuzzPlan) u8 {
        if (self.at >= self.bytes.len) return 0;
        defer self.at += 1;
        return self.bytes[self.at];
    }

    fn below(self: *FuzzPlan, n: u8) u8 {
        return self.byte() % n;
    }

    /// A positive time from the next eight bytes.
    fn time(self: *FuzzPlan) i64 {
        var value: u64 = 0;
        for (0..8) |_| value = (value << 8) | self.byte();
        return @intCast(@max(1, value >> 1));
    }

    /// A piece of the input itself, as a result's text.
    fn text(self: *FuzzPlan) []const u8 {
        const start = self.byte() % (self.bytes.len + 1);
        const end = start + self.byte() % (self.bytes.len - start + 1);
        return self.bytes[start..end];
    }
};

/// Builds a turn of fuzzed tool steps whose results carry fuzzed stamps,
/// some missing or not a time, and requires each of two rebuilds, and the
/// rebuild of the turn resumed from its own execution as a checkpoint
/// resumes it, to give every result the stamp its message carries. A turn
/// whose every result carries one encodes the same bytes each time.
fn fuzzStableStamps(_: void, smith: *std.testing.Smith) !void {
    const session = @import("../../session/session.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var input: [512]u8 = undefined;
    var plan: FuzzPlan = .{ .bytes = input[0..smith.slice(&input)] };

    var messages: std.ArrayList(ChatMessage) = .empty;
    try messages.append(a, .{ .role = .user, .content = "read them" });
    var expected: std.ArrayList(?i64) = .empty;
    var all_stamped = true;
    for (0..plan.below(6)) |step| {
        const calls = try a.alloc(ToolCall, 1 + plan.below(3));
        for (calls, 0..) |*call, index| call.* = toolCall(try a.print("call-{d}-{d}", .{ step, index }), "read_file", "{}");
        try messages.append(a, .{ .role = .assistant, .tool_calls = calls });
        for (calls) |call| {
            const stamp: ?i64 = switch (plan.below(6)) {
                0 => null,
                1 => 0,
                2 => -plan.time(),
                else => plan.time(),
            };
            const usable: ?i64 = if (stamp) |value| (if (value > 0) value else null) else null;
            all_stamped = all_stamped and usable != null;
            try expected.append(a, usable);
            const flags = plan.byte();
            const content = plan.text();
            try messages.append(a, .{
                .role = .tool,
                .content = content,
                .tool_call_id = call.id,
                .tool_name = call.name,
                .tool_result_status = if (flags & 1 == 0) .success else .failure,
                .tool_result_memory = if (flags & 2 == 0) null else .{ .output_bytes = content.len, .stored_output_bytes = content.len },
                .tool_result_created_at_ms = stamp,
            });
        }
    }

    const first = try buildExecutionMemory(a, messages.items);
    const second = try buildExecutionMemory(a, messages.items);
    var index: usize = 0;
    for (first.tool_steps, second.tool_steps) |one, two| {
        for (one.tool_results, two.tool_results) |x, y| {
            if (expected.items[index]) |stamp| {
                try std.testing.expectEqual(stamp, x.created_at_ms);
                try std.testing.expectEqual(stamp, y.created_at_ms);
            }
            index += 1;
        }
    }
    try std.testing.expectEqual(expected.items.len, index);
    if (all_stamped) try std.testing.expectEqualStrings(try encodedTurn(a, first), try encodedTurn(a, second));

    var resumed: std.ArrayList(ChatMessage) = .empty;
    try resumed.append(a, .{ .role = .user, .content = "read them" });
    try session.appendExecutionMemoryChatMessages(a, &resumed, first);
    const third = try buildExecutionMemory(a, resumed.items);
    try std.testing.expectEqual(first.tool_steps.len, third.tool_steps.len);
    for (first.tool_steps, third.tool_steps) |one, three| {
        try std.testing.expectEqual(one.tool_results.len, three.tool_results.len);
        for (one.tool_results, three.tool_results) |x, z| try std.testing.expectEqual(x.created_at_ms, z.created_at_ms);
    }
}

pub fn persistedStatusForCurrentFxLocalResult(
    status: ToolExecutionStatus,
    output: []const u8,
) types.PersistedToolStatus {
    if (status == .failure) return .failure;
    return if (tool_result_errors.isToolOutputError(output)) .failure else .success;
}

pub fn classifyProviderExecutedResultStatus(output: []const u8) types.PersistedToolStatus {
    return if (tool_result_errors.isToolOutputError(output)) .failure else .success;
}

pub const CompactedExecutionBoundary = struct {
    tool_steps: usize = 0,
    steering: usize = 0,

    /// Borrows execution payloads; only the rebased steering and context note
    /// slices use arena.
    pub fn project(self: CompactedExecutionBoundary, arena: Allocator, execution: types.ExecutionMemory) !types.ExecutionMemory {
        std.debug.assert(self.tool_steps <= execution.tool_steps.len);
        std.debug.assert(self.steering <= execution.steering.len);
        var projected = execution;
        projected.tool_steps = execution.tool_steps[self.tool_steps..];
        projected.steering = execution.steering[self.steering..];
        const covered_notes = history_range.coveredContextNotes(execution, self.tool_steps, self.steering);
        projected.context_notes = try history_range.rebasedContextNotes(arena, execution.context_notes[covered_notes..], self.tool_steps);
        if (self.tool_steps > 0 and projected.steering.len > 0) {
            projected.steering = try arena.dupe(types.PersistedSteering, projected.steering);
            for (projected.steering) |*item| {
                std.debug.assert(item.after_tool_step_count >= self.tool_steps);
                item.after_tool_step_count -= self.tool_steps;
            }
        }
        projected.model_calls = try history_range.rebasedModelCalls(arena, execution.model_calls, self.tool_steps, self.steering, std.math.maxInt(usize));
        return projected;
    }
};

pub fn buildExecutionMemory(alloc: Allocator, within_turn_suffix: []const ChatMessage) !types.ExecutionMemory {
    var execution = try execution_memory_helpers.buildNormalChatExecutionMemory(
        alloc,
        within_turn_suffix,
    );
    errdefer types.freeExecutionMemory(alloc, execution);

    var steering: std.ArrayList(types.PersistedSteering) = .empty;
    errdefer {
        for (steering.items) |item| {
            alloc.free(item.text);
            if (item.assistant_prefix) |prefix| alloc.free(prefix);
        }
        steering.deinit(alloc);
    }
    var context_notes: std.ArrayList(types.PersistedContextNote) = .empty;
    errdefer {
        for (context_notes.items) |item| types.freePersistedContextNote(alloc, item);
        context_notes.deinit(alloc);
    }
    var tool_step_count: usize = 0;
    var assistant_prefix: ?[]const u8 = null;
    for (within_turn_suffix, 0..) |message, index| {
        if (startsPersistedToolStep(within_turn_suffix, index)) {
            tool_step_count += 1;
            assistant_prefix = null;
        } else if (message.role == .assistant) {
            assistant_prefix = message.content;
        }
        if (isContextNote(message)) {
            // spark places a note only at a step boundary, so the steps before
            // it are complete (D93). A note saves the text it sent, so later
            // turns send it unchanged (D95).
            const copy = try alloc.dupe(u8, message.content orelse "");
            errdefer alloc.free(copy);
            const sources = try types.dupeNoteSources(alloc, message.context_note_sources);
            context_notes.append(alloc, .{ .text = copy, .after_tool_step_count = tool_step_count, .sources = sources }) catch |err| {
                types.freeNoteSources(alloc, sources);
                return err;
            };
            continue;
        }
        if (message.role != .user) continue;
        const content = message.content orelse continue;
        const copy = if (message.recovery_prompt)
            // spark's own prompt to a stalled turn is steering the user never
            // typed, so it is saved inside its marker.
            try recovery_prompt.saved(alloc, content)
        else copy: {
            const text = if (message.restored_steering)
                content
            else
                steeringText(content) orelse {
                    assistant_prefix = null;
                    continue;
                };
            break :copy try alloc.dupe(u8, text);
        };
        const prefix_copy = if (assistant_prefix) |prefix|
            alloc.dupe(u8, prefix) catch |err| {
                alloc.free(copy);
                return err;
            }
        else
            null;
        steering.append(alloc, .{
            .text = copy,
            .assistant_prefix = prefix_copy,
            .after_tool_step_count = tool_step_count,
        }) catch |err| {
            alloc.free(copy);
            if (prefix_copy) |prefix| alloc.free(prefix);
            return err;
        };
        assistant_prefix = null;
    }
    std.debug.assert(tool_step_count == execution.tool_steps.len);
    execution.steering = try steering.toOwnedSlice(alloc);
    execution.context_notes = try context_notes.toOwnedSlice(alloc);
    return execution;
}

fn isContextNote(message: ChatMessage) bool {
    return message.role == .system and message.context_note;
}

fn startsPersistedToolStep(messages: []const ChatMessage, assistant_index: usize) bool {
    const assistant = messages[assistant_index];
    if (assistant.role != .assistant) return false;
    if (assistant.tool_calls.len == 0) return assistant.provider_replay != null or assistant.standalone_response;
    var result_index = assistant_index + 1;
    // A note never ends a step's results (D93).
    while (result_index < messages.len and (messages[result_index].role == .tool or isContextNote(messages[result_index]))) : (result_index += 1) {
        const result_call_id = messages[result_index].tool_call_id orelse continue;
        for (assistant.tool_calls) |call| {
            if (std.mem.eql(u8, call.id, result_call_id)) return true;
        }
    }
    return false;
}

/// Locate the same complete-exchange cut in the original wire messages. Do not
/// rebuild retained tool results: their content and metadata remain untouched.
pub fn retainedMessageOffset(messages: []const ChatMessage, cut: CompactedExecutionBoundary) !usize {
    if (cut.tool_steps == 0 and cut.steering == 0) return 0;
    var steps: usize = 0;
    var steering: usize = 0;
    var prefix_start: usize = 0;
    for (messages, 0..) |message, index| {
        if (startsPersistedToolStep(messages, index)) {
            if (steps == cut.tool_steps and steering == cut.steering) return prefix_start;
            steps += 1;
            // Keep following continuation prompts, but not the completed reply.
            if (message.tool_calls.len == 0) prefix_start = index + 1;
        } else if (message.role == .user and message.content != null and
            (message.restored_steering or message.recovery_prompt or steeringText(message.content.?) != null))
        {
            if (steps == cut.tool_steps and steering == cut.steering) return prefix_start;
            steering += 1;
            prefix_start = index + 1;
        }
        if (message.role == .tool) prefix_start = index + 1;
    }
    if (steps != cut.tool_steps or steering != cut.steering) return error.InvalidContextHistoryStart;
    // The notes that end the messages sit at the cut's own boundary with no
    // steering after them, so the cut keeps them, as
    // `history_range.coveredContextNotes` counts for the saved turn (D93).
    var kept_notes_start = messages.len;
    while (kept_notes_start > 0 and isContextNote(messages[kept_notes_start - 1])) kept_notes_start -= 1;
    return kept_notes_start;
}

/// The request copy of `messages`, with each steering message a saved turn
/// restored back in the envelope the model saw when the turn took it. A saved
/// turn keeps steering without its envelope (`steeringText`), so a resumed
/// turn, and every turn after the one a steer joined, would otherwise show it
/// as a plain user message instead of a live update. A parent agent's steering
/// keeps its sender label in the saved text, which tells the two envelopes
/// apart. Empty entries only mark a checkpoint boundary, and an entry already
/// in its envelope and spark's own `resume_notice` stay as they are. Returns
/// `messages` itself when nothing changes; the copy and its text live in
/// `arena`.
pub fn rewrapRestoredSteering(arena: Allocator, messages: []const ChatMessage) Allocator.Error![]const ChatMessage {
    var result: ?[]ChatMessage = null;
    for (messages, 0..) |message, index| {
        if (!message.restored_steering) continue;
        const text = message.content orelse continue;
        if (text.len == 0 or steeringText(text) != null or std.mem.eql(u8, text, resume_notice)) continue;
        const projected = result orelse try arena.dupe(ChatMessage, messages);
        result = projected;
        projected[index].content = if (std.mem.startsWith(u8, text, parent_steering_label))
            try std.mem.concat(arena, u8, &.{ parent_steering_open, text, parent_steering_close })
        else
            try steeringMessage(arena, text);
    }
    return result orelse messages;
}

/// Steering the user typed during the turn, and spark's own prompt to a stalled
/// turn, which a cancelled turn keeps: its last request ended with them.
fn isSteering(message: ChatMessage) bool {
    if (message.restored_steering or message.recovery_prompt) return true;
    const content = message.content orelse return false;
    return steeringText(content) != null;
}

/// Where the notes that join `messages` at the next step boundary go. A saved
/// turn restores a boundary's notes before its steering (D93), so a note joins
/// before the steering the last step ended with, such as a continuation prompt,
/// the empty-reply nudge, review mode's message, or steering taken after a
/// reply, and never after it. That steering is the longest tail of steering
/// messages, each with the plain assistant message before it that the save keeps
/// as its prefix. With none, the notes join at the end.
///
/// spark marks every message it sends on its own (`recovery_prompt`), a Stop
/// hook's message and a tool's notice, such as Vision's outage notice, among
/// them, so each is steering and a note joins before it. A user message with
/// no marker would be none of that, and the save would drop it.
pub fn boundaryNotesStart(messages: []const ChatMessage) usize {
    var start = messages.len;
    while (start > 0) {
        const message = messages[start - 1];
        if (message.role != .user or message.content == null or !isSteering(message)) break;
        start -= 1;
        if (start > 0 and messages[start - 1].role == .assistant and !startsPersistedToolStep(messages, start - 1)) start -= 1;
    }
    return start;
}

fn steeringText(content: []const u8) ?[]const u8 {
    // A subagent's report or message a boundary took keeps its frame, which
    // names it as untrusted agent output wherever it is replayed.
    if (agent_frame.isFrame(content)) return content;
    if (std.mem.startsWith(u8, content, parent_steering_open) and std.mem.endsWith(u8, content, parent_steering_close)) {
        // Keep the sender label in persisted text and ordinary history replay.
        return content[parent_steering_open.len .. content.len - parent_steering_close.len];
    }
    if (!std.mem.startsWith(u8, content, steering_open) or !std.mem.endsWith(u8, content, steering_close)) return null;
    return content[steering_open.len .. content.len - steering_close.len];
}

/// Which steering and feedback a cancelled turn keeps is modeled in
/// `tests/tla/session_manager/rollout/pr-1092/PR1092Steering.tla`.
pub fn buildInterruptedExecutionMemory(
    alloc: Allocator,
    current_turn_messages: []const ChatMessage,
    active_tool_call: ?ToolCall,
) !types.ExecutionMemory {
    var filtered: std.ArrayList(ChatMessage) = .empty;
    defer filtered.deinit(alloc);
    try filtered.ensureTotalCapacity(alloc, current_turn_messages.len);
    var allocated_call_slices: std.ArrayList([]ToolCall) = .empty;
    defer {
        for (allocated_call_slices.items) |calls| alloc.free(calls);
        allocated_call_slices.deinit(alloc);
    }

    var active_group_index: ?usize = null;
    if (active_tool_call) |active| {
        for (current_turn_messages, 0..) |message, index| {
            for (message.tool_calls) |call| {
                if (std.mem.eql(u8, call.id, active.id)) active_group_index = index;
            }
        }
    }
    var i: usize = 0;
    while (i < current_turn_messages.len) {
        const item = current_turn_messages[i];
        if (item.role != .assistant or item.tool_calls.len == 0) {
            try filtered.append(alloc, item);
            i += 1;
            continue;
        }

        var result_end = i + 1;
        while (result_end < current_turn_messages.len and
            current_turn_messages[result_end].role == .tool) : (result_end += 1)
        {}
        const result_messages = current_turn_messages[i + 1 .. result_end];
        var user_tail_end = result_end;
        // A note at the step's boundary does not end the feedback after it.
        while (user_tail_end < current_turn_messages.len and
            (current_turn_messages[user_tail_end].role == .user or isContextNote(current_turn_messages[user_tail_end]))) : (user_tail_end += 1)
        {}
        const user_tail = current_turn_messages[result_end..user_tail_end];

        var completed_count: usize = 0;
        for (item.tool_calls) |call| {
            if (active_tool_call) |active| {
                if (active_group_index == i and std.mem.eql(u8, call.id, active.id)) continue;
            }
            if (hasToolResultForCall(result_messages, call.id)) {
                completed_count += 1;
            }
        }

        if (item.provider_replay != null and completed_count != item.tool_calls.len) {
            debug_trace.logf("session", "provider replay omitted reason=interrupted_incomplete_association source_calls={d} completed_calls={d}", .{ item.tool_calls.len, completed_count });
        }
        if (completed_count > 0) {
            const calls = try alloc.alloc(ToolCall, completed_count);
            errdefer alloc.free(calls);
            try allocated_call_slices.append(alloc, calls);

            var completed_index: usize = 0;
            for (item.tool_calls) |call| {
                if (active_tool_call) |active| {
                    if (active_group_index == i and std.mem.eql(u8, call.id, active.id)) continue;
                }
                if (!hasToolResultForCall(result_messages, call.id)) continue;
                calls[completed_index] = call;
                completed_index += 1;
            }

            var projected = item;
            projected.tool_calls = calls;
            if (completed_count != item.tool_calls.len) projected.provider_replay = null;
            filtered.appendAssumeCapacity(projected);
            for (result_messages) |result| {
                const result_call_id = result.tool_call_id orelse continue;
                if (execution_memory_helpers.findToolCallById(
                    calls,
                    result_call_id,
                ) != null) {
                    filtered.appendAssumeCapacity(result);
                }
            }
            for (user_tail) |entry| {
                if (isContextNote(entry)) {
                    filtered.appendAssumeCapacity(entry);
                    continue;
                }
                if (!entry.permission_feedback and !isSteering(entry)) continue;
                if (entry.tool_call_id) |source_tool_call_id| {
                    if (execution_memory_helpers.findToolCallById(calls, source_tool_call_id) == null) {
                        continue;
                    }
                }
                filtered.appendAssumeCapacity(entry);
            }
        } else for (user_tail) |entry| {
            // The step leaves without a result; a note after it stays, at
            // the boundary before that step.
            if (isContextNote(entry)) filtered.appendAssumeCapacity(entry);
        }
        i = user_tail_end;
    }

    return buildExecutionMemory(alloc, filtered.items);
}

pub fn retainCancelledCommandReplay(
    arena: Allocator,
    result_memory: ?types.ToolResultMemory,
    capture: ?*command_replay_store.Capture,
) ?types.CancelledCommandPresentation {
    if (capture) |candidate| {
        const replay: ?types.CommandOutputReplay = switch (candidate.policy()) {
            .required => blk: {
                const descriptor = candidate.retainRequired(arena) catch |err| {
                    debug_trace.logf(
                        "session",
                        "cancelled command replay retention unavailable err={s}",
                        .{@errorName(err)},
                    );
                    break :blk .unavailable;
                } orelse break :blk null;
                break :blk .{ .available = descriptor };
            },
            .best_effort => candidate.retain(arena),
        };
        if (replay) |retained| return .{ .output_replay = retained };
    }
    const replay = if (result_memory) |memory|
        memory.command_output_replay
    else
        null;
    return if (replay) |value| .{ .output_replay = value } else null;
}

fn hasToolResultForCall(
    result_messages: []const ChatMessage,
    call_id: []const u8,
) bool {
    for (result_messages) |result| {
        if (result.tool_call_id) |result_call_id| {
            if (std.mem.eql(u8, result_call_id, call_id)) return true;
        }
    }
    return false;
}

pub fn prepareToolExecutionOutput(
    arena: Allocator,
    config: Config,
    tool_call: ToolCall,
    execution: runtime_tool_contracts.ToolExecutionResult,
    capture: ?*command_replay_store.Capture,
) !result_store.PreparedResult {
    if (execution.model_content_kind != .complete_skill or execution.status != .success) {
        return prepareCapturedToolModelOutput(arena, config, tool_call, execution.model_output, capture);
    }
    if (capture != null) return error.InvalidSkillContentResult;
    const full = try tool_result_limits.prepareSanitizedOutput(arena, execution.model_output);
    errdefer arena.free(full);
    if (full.len > config.max_tool_result_bytes) return error.SkillContentLimitExceeded;
    var prepared = try prepareCapturedToolModelOutput(arena, config, tool_call, full, null);
    arena.free(prepared.model_output);
    prepared.model_output = full;
    prepared.memory.truncated = false;
    return prepared;
}

pub fn prepareToolModelOutput(
    arena: Allocator,
    config: Config,
    tool_call: ToolCall,
    raw_output: []const u8,
) !result_store.PreparedResult {
    return prepareCapturedToolModelOutput(
        arena,
        config,
        tool_call,
        raw_output,
        null,
    );
}

pub fn prepareCapturedToolModelOutput(
    arena: Allocator,
    config: Config,
    tool_call: ToolCall,
    raw_output: []const u8,
    capture: ?*command_replay_store.Capture,
) !result_store.PreparedResult {
    if (std.mem.eql(u8, tool_call.name, "read_tool_result")) {
        const prepared = try tool_result_limits.prepareModelOutputWithTruncation(
            arena,
            tool_call.name,
            raw_output,
            config.max_tool_result_bytes,
        );
        errdefer arena.free(prepared.model_output);
        var memory: types.ToolResultMemory = .{
            .output_bytes = raw_output.len,
            .stored_output_bytes = prepared.model_output.len,
            .truncated = prepared.truncated,
        };
        if (prepared.truncated and
            (config.session_child_capability != null or config.tool_result_dir != null))
        {
            const complete_output = try text_utils.sanitizeModelText(arena, raw_output);
            defer if (complete_output.ptr != raw_output.ptr) arena.free(complete_output);
            memory.output_handle = if (config.session_child_capability) |capability|
                try result_store.storeLargeResultManaged(arena, capability, tool_call.id, tool_call.name, complete_output)
            else
                try result_store.storeLargeResult(arena, config.tool_result_dir.?, tool_call.id, tool_call.name, complete_output);
            memory.stored_output_bytes = complete_output.len;
        }
        return .{
            .model_output = prepared.model_output,
            .memory = memory,
        };
    }
    const required_command_replay = if (capture) |candidate|
        candidate.policy() == .required
    else
        false;
    if (!required_command_replay and
        (config.session_child_capability != null or config.tool_result_dir != null))
    {
        const sanitized_output = try tool_result_limits.prepareSanitizedOutput(
            arena,
            raw_output,
        );
        if (config.session_child_capability != null) {
            return result_store.prepareManaged(
                arena,
                config.session_child_capability,
                tool_call.id,
                tool_call.name,
                raw_output.len,
                sanitized_output,
                config.max_tool_result_bytes,
            );
        }
        return result_store.prepare(
            arena,
            config.tool_result_dir,
            tool_call.id,
            tool_call.name,
            raw_output.len,
            sanitized_output,
            config.max_tool_result_bytes,
        );
    }
    const model_output_budget = if (required_command_replay)
        config.max_tool_result_bytes -| command_replay_store.model_handle_notice_reserve_bytes
    else
        config.max_tool_result_bytes;
    const prepared = try tool_result_limits.prepareModelOutputWithTruncation(
        arena,
        tool_call.name,
        raw_output,
        model_output_budget,
    );
    return .{
        .model_output = prepared.model_output,
        .memory = .{
            .output_bytes = raw_output.len,
            .stored_output_bytes = prepared.model_output.len,
            .truncated = prepared.truncated,
        },
    };
}

/// Retains the original tool images so later requests can project a safe view.
pub fn retainToolImages(arena: Allocator, config: Config, call: ToolCall, prepared: *result_store.PreparedResult) !void {
    const memory = &prepared.memory;
    if (memory.tool_images.len == 0 or memory.tool_image_handle != null) return;
    const capability = config.session_child_capability orelse return;
    const handle = result_store.storeToolImages(arena, capability, call.id, call.name, memory.tool_images) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("session", "tool images remain inline because artifact storage failed call_id={s} err={s}", .{ call.id, @errorName(err) });
        return;
    };
    memory.tool_image_handle = handle;
    const notice = try arena.print("Saved images: {s}. Use read_tool_result with this handle to load them again.\n", .{handle});
    const limit = config.max_tool_result_bytes -| notice.len;
    const keep = @import("../../config/context_limits.zig").utf8PrefixLength(prepared.model_output, limit);
    if (keep < prepared.model_output.len) memory.truncated = true;
    prepared.model_output = try std.mem.concat(arena, u8, &.{ notice, prepared.model_output[0..keep] });
}

fn needsImageMaterialization(messages: []const ChatMessage) bool {
    for (messages) |message| {
        const memory = message.tool_result_memory orelse continue;
        if (memory.tool_images.len == 0 and memory.tool_image_handle != null) return true;
    }
    return false;
}

/// Loads stored tool images for a request without changing session history.
pub fn materializeToolImages(arena: Allocator, config: Config, messages: []const ChatMessage) ![]const ChatMessage {
    if (!needsImageMaterialization(messages)) return messages;
    const materialized = try arena.dupe(ChatMessage, messages);
    for (materialized) |*message| {
        if (message.tool_result_memory) |*memory| {
            if (memory.tool_images.len == 0) {
                const handle = memory.tool_image_handle orelse continue;
                const capability = config.session_child_capability orelse {
                    message.content = try prependImageNotice(arena, "[Stored tool image is unavailable in this session.]\n", message.content orelse "", config.max_tool_result_bytes);
                    continue;
                };
                memory.tool_images = result_store.loadToolImages(arena, capability, handle) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    const notice = try arena.print("[Stored tool image unavailable: {s}]\n", .{@errorName(err)});
                    message.content = try prependImageNotice(arena, notice, message.content orelse "", config.max_tool_result_bytes);
                    continue;
                };
            }
        }
    }
    return materialized;
}

fn requestToolImageFits(image: types.ToolImage, max_dimension: u32) bool {
    const dimensions = image_data.encodedImageDimensions(image.data) orelse return false;
    return !dimensions.exceeds(max_dimension) and
        image.data.len <= image_data.max_encoded_image_bytes and
        image_data.supportedMediaType(image.mime_type);
}

/// Builds a safe request view without changing the tool images saved in history.
pub fn withholdRequestToolImages(arena: Allocator, messages: []const ChatMessage, max_dimension: u32, text_limit: usize) ![]const ChatMessage {
    var projected: ?[]ChatMessage = null;
    for (messages, 0..) |message, index| {
        const memory = message.tool_result_memory orelse continue;
        const has_unsafe = for (memory.tool_images) |image| {
            if (!requestToolImageFits(image, max_dimension)) break true;
        } else false;
        if (!has_unsafe) continue;
        var kept: std.ArrayList(types.ToolImage) = try .initCapacity(arena, memory.tool_images.len);
        var notice: std.Io.Writer.Allocating = .init(arena);
        for (memory.tool_images) |image| {
            if (requestToolImageFits(image, max_dimension)) {
                kept.appendAssumeCapacity(image);
                continue;
            }
            const dimensions = image_data.encodedImageDimensions(image.data);
            if (dimensions) |size| {
                try notice.writer.print("[Image not sent: {s} is {d}x{d} pixels; this request permits at most {d} per side and 5 MiB encoded per image. ", .{ image.mime_type, size.width, size.height, max_dimension });
            } else if (image.source_ref != null and image.data.len == 0) {
                try notice.writer.print("[Image not sent: only a host source reference was supplied; this request permits at most {d} per side and 5 MiB encoded per image. ", .{max_dimension});
            } else {
                try notice.writer.writeAll("[Image not sent: its dimensions could not be verified. ");
            }
            if (image.source_ref) |source_ref| {
                try image_data.writeHostImageRecoveryNotice(&notice.writer, source_ref, max_dimension);
            } else {
                try notice.writer.writeAll("If this tool result names a local file, use an available image tool to save a smaller copy, then read_file the copy. If no tool or path is available, ask the user; ask before installing software.]\n");
            }
        }
        if (kept.items.len == memory.tool_images.len) continue;
        const output = projected orelse try arena.dupe(ChatMessage, messages);
        projected = output;
        output[index].tool_result_memory.?.tool_images = kept.items;
        output[index].content = try prependImageNotice(arena, notice.written(), message.content orelse "", text_limit);
    }
    return projected orelse messages;
}

fn prependImageNotice(alloc: Allocator, notice: []const u8, content: []const u8, limit: usize) Allocator.Error![]u8 {
    const utf8_prefix_length = @import("../../config/context_limits.zig").utf8PrefixLength;
    const notice_keep = utf8_prefix_length(notice, limit);
    const keep = utf8_prefix_length(content, limit -| notice.len);
    return std.mem.concat(alloc, u8, &.{ notice[0..notice_keep], content[0..keep] });
}

fn testEncodedToolImage(arena: Allocator, bytes: []const u8, mime_type: []const u8) !types.ToolImage {
    const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return .{ .data = encoded, .mime_type = try arena.dupe(u8, mime_type) };
}

fn testPngHeaderToolImage(arena: Allocator, width: u32, height: u32) !types.ToolImage {
    return testEncodedToolImage(arena, &image_data.testPngHeader(width, height), "image/png");
}

fn testJpegHeaderToolImage(arena: Allocator, width: u16, height: u16) !types.ToolImage {
    return testEncodedToolImage(arena, &image_data.testJpeg(width, height), "image/jpeg");
}

fn testImageConfig(cancel: *std.atomic.Value(bool)) Config {
    return .{
        .system_prompt = "",
        .gateway_retry_count = 0,
        .gateway_chat_url = "",
        .agent_step_limit = 1,
        .max_tool_result_bytes = tool_result_limits.min_configured_tool_result_bytes,
        .cancel_flag = cancel,
    };
}

pub fn applyToolResultMemory(
    prepared: *types.ToolResultMemory,
    source: ?types.ToolResultMemory,
) void {
    const source_memory = source orelse return;
    prepared.review_feedback = source_memory.review_feedback;
    prepared.tool_images = source_memory.tool_images;
    prepared.tool_image_handle = source_memory.tool_image_handle;
    prepared.command_output_replay = source_memory.command_output_replay;
    prepared.command_process_presentation = source_memory.command_process_presentation;
    prepared.terminal_action_presentation = source_memory.terminal_action_presentation;
    prepared.quiet_crossing = source_memory.quiet_crossing;
    const source_covers_full_file =
        source_memory.model_view_covers_full_file orelse return;
    prepared.model_view_covers_full_file =
        source_covers_full_file and
        !source_memory.truncated and
        source_memory.output_handle == null and
        !prepared.truncated;
}

/// Finalizes tentative command capture after bounded model output is prepared.
/// Required native exec always retains one authoritative replay and publishes
/// its handle; legacy exact round trips keep the existing discard optimization.
pub fn finalizeCommandReplay(
    arena: Allocator,
    tool_call: ToolCall,
    prepared: *result_store.PreparedResult,
    session_child_capability: ?*session_child_store.SessionChildCapability,
    capture: ?*command_replay_store.Capture,
) !void {
    const candidate = capture orelse return;
    if (!candidate.hasOutput()) {
        candidate.discard(arena);
        return;
    }
    if (candidate.policy() == .required) {
        const descriptor = (try candidate.retainRequired(arena)) orelse return;
        prepared.memory.command_output_replay = .{ .available = descriptor };
        prepared.model_output = try command_replay_store.appendModelHandleNotice(
            arena,
            prepared.model_output,
            descriptor.handle,
        );
        prepared.memory.stored_output_bytes = prepared.model_output.len;
        return;
    }
    var captured = candidate.canonicalizeForComparison(arena) catch |err| {
        debug_trace.logf(
            "session",
            "command replay comparison unavailable call_id_bytes={d} err={s}",
            .{ tool_call.id.len, @errorName(err) },
        );
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    } orelse {
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    };
    defer captured.deinit(arena);

    const source = selectedCommandSource(
        arena,
        prepared.*,
        session_child_capability,
        candidate.comparisonLimit(),
    ) catch |err| {
        debug_trace.logf(
            "session",
            "command replay source comparison failed call_id_bytes={d} err={s}",
            .{ tool_call.id.len, @errorName(err) },
        );
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    } orelse {
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    };
    defer arena.free(source);
    var ordinary = (command_output_content.canonicalizeForegroundResult(
        arena,
        source,
    ) catch |err| {
        debug_trace.logf(
            "session",
            "command replay envelope comparison failed call_id_bytes={d} err={s}",
            .{ tool_call.id.len, @errorName(err) },
        );
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    }) orelse {
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    };
    defer ordinary.deinit(arena);

    if (command_output_content.eql(captured, ordinary)) {
        candidate.discard(arena);
        return;
    }
    retainCommandReplay(arena, candidate, &prepared.memory);
}

fn selectedCommandSource(
    arena: Allocator,
    prepared: result_store.PreparedResult,
    session_child_capability: ?*session_child_store.SessionChildCapability,
    comparison_limit: usize,
) !?[]u8 {
    const source_limit = std.math.add(
        usize,
        comparison_limit,
        command_output_content.max_foreground_result_envelope_bytes,
    ) catch return null;
    if (prepared.memory.output_handle) |handle| {
        const capability = session_child_capability orelse return null;
        var reader = try result_store.openReaderManaged(arena, capability, handle);
        defer reader.deinit();
        if (reader.size != prepared.memory.stored_output_bytes or
            reader.size > source_limit) return null;

        const source = try arena.alloc(u8, reader.size);
        errdefer arena.free(source);
        var offset: usize = 0;
        while (offset < source.len) {
            const page_len = @min(source.len - offset, 4 * 1024);
            const page = try reader.readPage(arena, offset, page_len);
            defer arena.free(page);
            if (page.len != page_len) return error.UnexpectedEndOfResult;
            @memcpy(source[offset..][0..page.len], page);
            offset += page.len;
        }
        return source;
    }
    if (prepared.model_output.len > source_limit) return null;
    const source = try arena.dupe(u8, prepared.model_output);
    if (source.len > source_limit) {
        arena.free(source);
        return null;
    }
    return source;
}

fn retainCommandReplay(
    arena: Allocator,
    candidate: *command_replay_store.Capture,
    memory: *types.ToolResultMemory,
) void {
    memory.command_output_replay = candidate.retain(arena);
}

/// Text budget for the full-diff rows a committed file presentation keeps for
/// a resumed session. Every history copy, recovery checkpoint, and saved turn
/// carries these rows, and they grow with the change, not the file. The
/// budget only bounds diffs as large as a whole rewritten file: 4 MiB keeps
/// every row of any write the former 4 MiB file limit allowed.
const max_captured_review_bytes: usize = 4 * 1024 * 1024;

/// The full-diff rows a resumed session shows for `handoff`, or null when
/// the handoff has no full view or the review cannot be indexed. Caller owns
/// the rows.
fn captureReviewLines(
    alloc: Allocator,
    handoff: file_mutation.CommittedFileHandoff,
) Allocator.Error!?[]types.CommittedFilePresentationLine {
    const full_view = handoff.full_view orelse return null;
    const captured = diff_mod.captureReviewLines(
        alloc,
        handoff.tracker.previous_content,
        full_view.after_content,
        max_captured_review_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ArithmeticOverflow => {
            debug_trace.logf(
                "session",
                "committed file review rows unavailable call_id={s} err={s}; resumed view keeps the preview",
                .{ full_view.lifecycle_id.call_id, @errorName(err) },
            );
            return null;
        },
    };
    if (captured.omitted_rows > 0) {
        debug_trace.logf(
            "session",
            "committed file review rows truncated call_id={s} kept_rows={d} omitted_rows={d} budget_bytes={d}",
            .{ full_view.lifecycle_id.call_id, captured.rows.len - 1, captured.omitted_rows, max_captured_review_bytes },
        );
    }
    return captured.rows;
}

/// Projects a committed file change for history and resume. The full diff is
/// kept as its rendered rows, never as the file snapshots behind them.
pub fn captureCommittedFilePresentation(
    alloc: Allocator,
    handoff: file_mutation.CommittedFileHandoff,
) !types.CommittedFilePresentation {
    const path = try alloc.dupe(u8, handoff.preview.path);
    errdefer alloc.free(path);
    const lines = try alloc.alloc(types.CommittedFilePresentationLine, handoff.preview.lines.len);
    errdefer alloc.free(lines);
    var copied_lines: usize = 0;
    errdefer {
        for (lines[0..copied_lines]) |line| alloc.free(@constCast(line.text));
    }
    for (handoff.preview.lines, 0..) |line, index| {
        lines[index] = .{
            .kind = diff_mod.presentationLineKind(line.op),
            .old_line = line.old_line,
            .new_line = line.new_line,
            // Saved text must be valid UTF-8; see `text_utils.dupeValidUtf8`.
            .text = try text_utils.dupeValidUtf8(alloc, line.text),
        };
        copied_lines += 1;
    }
    const review_lines = try captureReviewLines(alloc, handoff);
    errdefer if (review_lines) |rows| types.freeCommittedFilePresentationLines(alloc, rows);
    // The lifecycle id names the full diff, so it exists only with the rows.
    const lifecycle_id: ?types.ToolLifecycleId = if (review_lines != null) .{
        .turn_id = handoff.full_view.?.lifecycle_id.turn_id,
        .call_id = try alloc.dupe(u8, handoff.full_view.?.lifecycle_id.call_id),
    } else null;
    errdefer if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));
    return .{
        .path = path,
        .kind = switch (handoff.tracker.kind) {
            .write => .added,
            .edit => .edited,
        },
        .lines = lines,
        .additions = handoff.preview.additions,
        .deletions = handoff.preview.deletions,
        .truncated = handoff.preview.truncated,
        .lifecycle_id = lifecycle_id,
        .review_lines = review_lines,
    };
}

fn testCommittedEditHandoff(
    previous_content: []const u8,
    after_content: []const u8,
) file_mutation.CommittedFileHandoff {
    return .{
        .preview = .{
            .path = "pnpm-lock.yaml",
            .lines = &.{
                .{ .op = .deletion, .old_line = 1, .text = "before" },
                .{ .op = .addition, .new_line = 1, .text = "after" },
            },
            .additions = 1,
            .deletions = 1,
            .truncated = false,
        },
        .tracker = .{
            .kind = .edit,
            .raw_path = "pnpm-lock.yaml",
            .previous_content = previous_content,
            .committed_at_ms = 1,
        },
        .full_view = .{
            .after_content = after_content,
            .lifecycle_id = .{ .turn_id = 7, .call_id = "edit_1" },
        },
    };
}

fn testLockfile(alloc: Allocator, line_count: usize, changed: ?usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (0..line_count) |index| {
        if (changed == index) {
            try out.print(alloc, "  resolution: {{integrity: sha512-{d}}}\n", .{index});
        } else {
            try out.print(alloc, "  resolution: {{tarball: https://example.com/{d}.tgz}}\n", .{index});
        }
    }
    return out.toOwnedSlice(alloc);
}

fn toolCall(id: []const u8, name: []const u8, args: []const u8) ToolCall {
    return .{ .id = id, .name = name, .arguments_json = args };
}

fn contextNote(text: []const u8) ChatMessage {
    return .{ .role = .system, .content = text, .context_note = true };
}
