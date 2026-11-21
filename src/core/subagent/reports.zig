//! Which ends of a child's turn owe its parent a report, and the message the
//! parent receives. Pure: the host decides with these and owns every effect.

const std = @import("std");
const child_state = @import("child_state.zig");
const session_adapter = @import("../session/session_adapter.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const types = @import("../shared/types.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const agent_frame = @import("../shared/agent_frame.zig");
const json_decode = @import("../shared/json_decode.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_presentation = @import("../tooling/tool_presentation.zig");

const Allocator = std.mem.Allocator;

/// When a child reports back on its own. Failures always report.
pub const Rule = enum {
    /// When work its parent, or its own child, gave it ends. The default.
    final,
    /// After every turn, including turns the user started on its screen.
    every_turn,
    /// Only when its work fails.
    never,
};

/// Who started the turn that ended.
pub const StartedBy = enum {
    /// The user, typing on the child's screen.
    user,
    /// The child's parent, by messaging it.
    parent,
    /// The child's own child, whose report woke it. That turn works for the
    /// parent, as one the parent sent would.
    child,
};

/// Whether a child's turn that ended with `outcome` owes its parent a
/// report. A stop the parent made itself never reports: the parent's stop
/// call already answers it.
pub fn reportable(rule: Rule, started_by: StartedBy, outcome: child_state.Outcome, stopped_by_parent: bool) bool {
    if (stopped_by_parent) return false;
    return switch (outcome) {
        .failed, .interrupted, .lost => true,
        .completed, .cancelled => switch (started_by) {
            .parent, .child => rule != .never,
            .user => rule == .every_turn,
        },
    };
}

/// A report a subagent owes its parent that the parent has not taken.
/// Strings borrow from the report lines it was folded from.
pub const Pending = struct {
    child_id: []const u8,
    work_id: []const u8,
    outcome: child_state.Outcome,
    end: child_state.EndFacts = .{},
};

/// Folds a parent's report lines, oldest first, into the reports it is
/// still owed. A finish owes one when its
/// line says so, or when crash repair closed a work this spark started as
/// interrupted or lost: repair writes no spark data, and `Repair` always
/// reports. A finish older spark wrote owes nothing, so an upgrade wakes no
/// parent. The parent's `child_report` takes a report. Reports stay in the
/// order they became owed, the order resume posts them (`Resumed`).
pub const PendingFold = struct {
    /// Works this spark started that have not finished.
    started: std.ArrayList(Key) = .empty,
    pending: std.ArrayList(Pending) = .empty,

    const Key = struct { child_id: []const u8, work_id: []const u8, started_by: StartedBy };

    pub fn deinit(self: *PendingFold, alloc: Allocator) void {
        self.started.deinit(alloc);
        self.pending.deinit(alloc);
    }

    /// Takes one more line. Its strings must outlive the fold.
    pub fn step(self: *PendingFold, alloc: Allocator, line: session_adapter.ReportLine) error{OutOfMemory}!void {
        switch (line) {
            .spawned => |spawned| if (child_state.spawnNamesRule(spawned.data)) {
                try self.started.append(alloc, .{
                    .child_id = spawned.child,
                    .work_id = spawned.work_id,
                    .started_by = child_state.spawnStartedBy(spawned.data),
                });
            },
            .finished => |finished| {
                const started = self.takeStarted(finished.child, finished.work_id);
                const repaired = finished.outcome == .interrupted or finished.outcome == .lost;
                const owed = child_state.finishOwesFlag(finished.data) orelse (started != null and repaired);
                var end = child_state.finishEndFacts(finished.data);
                // Repair writes no spark data, so who started the work is read
                // from its spawn, and the report still names the user's turn.
                if (finished.data == null) if (started) |by| {
                    end.started_by = by;
                };
                if (owed and self.findPending(finished.child, finished.work_id) == null) try self.pending.append(alloc, .{
                    .child_id = finished.child,
                    .work_id = finished.work_id,
                    .outcome = child_state.fxOutcome(finished.outcome),
                    .end = end,
                });
            },
            .taken => |taken| if (self.findPending(taken.child, taken.work_id)) |index| {
                _ = self.pending.orderedRemove(index);
            },
        }
    }

    /// Who started the work this spark opened, forgotten once taken; null for
    /// one it didn't open.
    fn takeStarted(self: *PendingFold, child_id: []const u8, work_id: []const u8) ?StartedBy {
        for (self.started.items, 0..) |key, index| {
            if (std.mem.eql(u8, key.child_id, child_id) and std.mem.eql(u8, key.work_id, work_id)) {
                return self.started.swapRemove(index).started_by;
            }
        }
        return null;
    }

    fn findPending(self: *const PendingFold, child_id: []const u8, work_id: []const u8) ?usize {
        for (self.pending.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.child_id, child_id) and std.mem.eql(u8, item.work_id, work_id)) return index;
        }
        return null;
    }
};

/// The reports `lines` still owe, oldest first. Caller frees the slice;
/// its strings borrow from `lines`.
pub fn pendingReports(alloc: Allocator, lines: []const session_adapter.ReportLine) error{OutOfMemory}![]Pending {
    var fold: PendingFold = .{};
    defer fold.started.deinit(alloc);
    errdefer fold.pending.deinit(alloc);
    for (lines) |line| try fold.step(alloc, line);
    return fold.pending.toOwnedSlice(alloc);
}

/// A report a child owes its parent.
pub const Report = struct {
    /// The child's name, or its id when it has none.
    agent: []const u8,
    child_id: []const u8,
    work_id: []const u8,
    /// The tool call that sent the work, so a client can show the report on
    /// it. Empty when the host no longer knows it.
    call_id: []const u8 = "",
    outcome: child_state.Outcome,
    /// The child's last reply for the work, as it wrote it.
    output: []const u8,
    /// How many of the parent's messages waiting for the child the user's
    /// stop dropped. A report with no `work_id` is the notice
    /// of that drop when the stopped work owed no report.
    dropped: usize = 0,
    /// Who started the work and why it was cancelled, so the parent
    /// needn't guess.
    end: child_state.EndFacts = .{},
    /// Whether the child is idle once the report goes, so the report tells
    /// the parent to send it related work or close it.
    idle: bool = false,
};

const header = agent_frame.report_header;
const message_header = agent_frame.message_header;

/// A subagent's message to its parent, sent with `message{agent: "parent"}`.
pub const Message = struct {
    /// Where it goes: the host's owner when a child of that host sent it,
    /// or the owner's own parent when the owner sent it.
    to: enum { owner, owners_parent },
    /// The sender's name. Empty when the owner sent it, and its runtime
    /// names it.
    agent: []const u8,
    child_id: []const u8,
    text: []const u8,
    /// What the user typed in the turn that sent it, newest last, which spark
    /// adds and the sender can't write (`WorkerRuntime.typedThisTurn`).
    user_typed: []const []const u8 = &.{},
};

/// The text the parent receives for a subagent's message, framed as a
/// report is. `started_by` is who started the sender's turn that sent it,
/// when the host knows, and `user_typed` what the user typed in that turn, which
/// spark writes in its own field, so the sender's text can't add one. Caller
/// owns the result.
pub fn messageText(alloc: Allocator, agent: []const u8, child_id: []const u8, text: []const u8, max_output_bytes: usize, started_by: ?StartedBy, user_typed: []const []const u8) error{OutOfMemory}![]u8 {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const body = try tool_result_limits.prepareModelOutput(scratch.allocator(), "subagent", text, max_output_bytes);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.writeAll(message_header) catch return error.OutOfMemory;
    std.json.Stringify.value(.{
        .agent = agent,
        .child_id = child_id,
        .message = body,
        // As in a report, only the user's turns are named. The words are
        // still the sender's, not the user's.
        .started_by = if (started_by == .user) @as(?[]const u8, "user") else null,
        // The user's own words, so the parent can check what the sender
        // says the user asked.
        .user_typed = if (user_typed.len > 0) @as(?[]const []const u8, user_typed) else null,
    }, .{ .emit_null_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The message the parent receives for `report`: a fixed header and one
/// JSON line, so the child's output can never pass as the frame or as the
/// user's words. The output is sanitized and capped at `max_output_bytes`,
/// as a tool result is. Caller owns the result.
pub fn message(alloc: Allocator, report: Report, max_output_bytes: usize) error{OutOfMemory}![]u8 {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const output = try tool_result_limits.prepareModelOutput(scratch.allocator(), "subagent", report.output, max_output_bytes);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    // An allocating writer fails only when it cannot grow.
    out.writer.writeAll(header) catch return error.OutOfMemory;
    std.json.Stringify.value(.{
        .agent = report.agent,
        .child_id = report.child_id,
        .work_id = report.work_id,
        .outcome = @tagName(report.outcome),
        .output = output,
        .dropped = if (report.dropped > 0) @as(?usize, report.dropped) else null,
        // A turn the child's own child woke works for the parent, as one
        // the parent sent would, so only the user's turns are named.
        .started_by = if (report.end.started_by == .user) @as(?[]const u8, "user") else null,
        .cause = if (report.end.cause) |cause| @as(?[]const u8, @tagName(cause)) else null,
        // A parent tends to start a new subagent for each task and leave
        // the finished ones idle; this keeps the one it has in view, and
        // asks for its judgment on it.
        .next = if (report.idle) @as(?[]const u8, try idleNote(scratch.allocator(), report.agent)) else null,
    }, .{ .emit_null_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// A report's `next` when its subagent is idle. Caller owns the result.
fn idleNote(alloc: Allocator, agent: []const u8) error{OutOfMemory}![]const u8 {
    return alloc.print("{s} is idle now and keeps this conversation. Keep it if related work may follow, close it if its work is done, or ask the user if you cannot tell.", .{agent});
}

test "a report says its subagent is idle only when it is" {
    const alloc = std.testing.allocator;
    const idle = try message(alloc, .{ .agent = "reviewer", .child_id = "c1", .work_id = "w1", .outcome = .failed, .output = "boom", .idle = true }, 4096);
    defer alloc.free(idle);
    try std.testing.expect(std.mem.endsWith(u8, idle, ",\"next\":\"reviewer is idle now and keeps this conversation. Keep it if related work may follow, close it if its work is done, or ask the user if you cannot tell.\"}\n"));
    // Readers that take only the sender still read it.
    const sender = (try agent_frame.reportSender(alloc, idle)).?;
    defer sender.deinit();
    try std.testing.expectEqualStrings("w1", sender.value.work_id);
    // A screen shows the same row with or without the note.
    var with_note = (try row(alloc, .{ .text = idle, .author = .child })).?;
    defer with_note.deinit(alloc);
    const busy = try message(alloc, .{ .agent = "reviewer", .child_id = "c1", .work_id = "w1", .outcome = .failed, .output = "boom" }, 4096);
    defer alloc.free(busy);
    try std.testing.expect(std.mem.find(u8, busy, "\"next\"") == null);
    var without_note = (try row(alloc, .{ .text = busy, .author = .child })).?;
    defer without_note.deinit(alloc);
    try std.testing.expectEqualStrings(without_note.status, with_note.status);
    try std.testing.expectEqualStrings(without_note.text, with_note.text);
}

/// Traces a report when the agent it was sent to takes it into its history:
/// a turn starts with it, or a step boundary takes it. That is when it is
/// delivered; reaching the agent's queue is not.
pub fn traceTaken(alloc: Allocator, ctx: debug_trace.TraceContext, text: []const u8) void {
    if (!debug_trace.isEnabled()) return;
    const parsed = (agent_frame.reportSender(alloc, text) catch return) orelse return;
    defer parsed.deinit();
    debug_trace.eventf("mailbox", "deliver", ctx, "from={s} kind=report work={s}", .{ parsed.value.child_id, parsed.value.work_id });
}

/// How a screen shows a turn a subagent's report or message started, live
/// or resumed: as a finished `subagent` tool row, like the parent's own
/// calls, with the text as its full detail. Free with `deinit`.
pub const Row = struct {
    outcome: types.ToolOutcomeKind,
    /// What the row says, such as "from reviewer · need the schema" or
    /// "reviewer completed · found two bugs". Owned.
    status: []u8,
    /// The message, or the report's output: the row's full detail. Owned.
    text: []u8,

    /// The call the row shows as: a subagent call with no arguments, so its
    /// detail is the text alone.
    pub const call: types.ToolCall = .{ .id = "", .name = "subagent", .arguments_json = "{}" };

    /// The row's detail as a finished tool result. Borrows `text`.
    pub fn result(self: Row, created_at_ms: i64) types.PersistedToolResult {
        return .{
            .tool_call_id = @constCast(""),
            .tool_name = @constCast("subagent"),
            .status = if (self.outcome == .completed) .success else .failure,
            .output = self.text,
            .output_bytes = self.text.len,
            .stored_output_bytes = self.text.len,
            .created_at_ms = created_at_ms,
        };
    }

    pub fn deinit(self: Row, alloc: Allocator) void {
        alloc.free(self.status);
        alloc.free(self.text);
    }
};

/// The row for a turn whose prompt is `user`, or null when the user wrote it
/// or it is not a report or message. `user.text` is borrowed.
pub fn row(alloc: Allocator, user: types.UserTurn) error{OutOfMemory}!?Row {
    if (user.author != .child) return null;
    const is_report = std.mem.startsWith(u8, user.text, header);
    if (!is_report and !std.mem.startsWith(u8, user.text, message_header)) return null;
    const header_len: usize = if (is_report) header.len else message_header.len;
    const json_line = std.mem.trimEnd(u8, user.text[header_len..], "\n");
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const Fields = struct { agent: []const u8 = "", outcome: []const u8 = "", output: []const u8 = "", message: []const u8 = "" };
    const fields = json_decode.parseFromSliceLeaky(Fields, scratch, json_line, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const agent = (try text_utils.encodeTerminalSafe(scratch, if (fields.agent.len > 0) fields.agent else "a subagent", 64)).bytes;
    const outcome = if (is_report) std.meta.stringToEnum(child_state.Outcome, fields.outcome) else null;
    // Worded as the parent's own subagent rows are: "sent to reviewer",
    // "reviewer failed".
    const lead = if (!is_report)
        try scratch.print("from {s}", .{agent})
    else if (outcome) |ended|
        try scratch.print("{s} {s}", .{ agent, @tagName(ended) })
    else
        try scratch.print("report from {s}", .{agent});
    const body = if (is_report) fields.output else fields.message;
    const preview = try tool_presentation.subagentPreview(scratch, body);
    const status = if (preview.len == 0) try alloc.dupe(u8, lead) else try alloc.print("{s} · {s}", .{ lead, preview });
    errdefer alloc.free(status);
    const failed = if (outcome) |ended| switch (ended) {
        .completed, .cancelled => false,
        .failed, .interrupted, .lost => true,
    } else false;
    return .{ .outcome = if (failed) .failed else .completed, .status = status, .text = try alloc.dupe(u8, body) };
}

/// A message frame's JSON, as the parent reads it.
const ParsedMessage = struct {
    agent: []const u8,
    child_id: []const u8,
    message: []const u8,
    started_by: ?[]const u8 = null,
    user_typed: ?[]const []const u8 = null,
};

const marked_spawn = "{\"fingerprint\":\"ab\",\"report\":\"final\"}";
const older_spawn = "{\"fingerprint\":\"ab\"}";

/// Pending reports by another route: per work, counters instead of the
/// fold's lists. A work is pending when its last owed finish came after its
/// last take, and it is listed in the order that finish came.
fn pendingOracle(alloc: Allocator, lines: []const session_adapter.ReportLine) ![]Pending {
    const State = struct { child_id: []const u8, work_id: []const u8, marked: usize = 0, used: usize = 0, since: ?usize = null, outcome: child_state.Outcome = .completed };
    var works: std.ArrayList(State) = .empty;
    defer works.deinit(alloc);
    for (lines, 0..) |line, index| {
        const child_id, const work_id = switch (line) {
            inline else => |value| .{ value.child, value.work_id },
        };
        const state = for (works.items) |*state| {
            if (std.mem.eql(u8, state.child_id, child_id) and std.mem.eql(u8, state.work_id, work_id)) break state;
        } else blk: {
            try works.append(alloc, .{ .child_id = child_id, .work_id = work_id });
            break :blk &works.items[works.items.len - 1];
        };
        switch (line) {
            .spawned => |spawned| state.marked += @intFromBool(child_state.spawnNamesRule(spawned.data)),
            .finished => |finished| {
                const started = state.marked > state.used;
                if (started) state.used += 1;
                const repaired = finished.outcome == .interrupted or finished.outcome == .lost;
                const owed = child_state.finishOwesFlag(finished.data) orelse (started and repaired);
                if (owed and state.since == null) {
                    state.since = index;
                    state.outcome = child_state.fxOutcome(finished.outcome);
                }
            },
            .taken => state.since = null,
        }
    }
    var out: std.ArrayList(Pending) = .empty;
    errdefer out.deinit(alloc);
    for (lines, 0..) |_, index| {
        for (works.items) |state| if (state.since == index) {
            try out.append(alloc, .{ .child_id = state.child_id, .work_id = state.work_id, .outcome = state.outcome });
        };
    }
    return out.toOwnedSlice(alloc);
}

fn expectSamePending(want: []const Pending, got: []const Pending) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| {
        try std.testing.expectEqualStrings(a.child_id, b.child_id);
        try std.testing.expectEqualStrings(a.work_id, b.work_id);
        try std.testing.expectEqual(a.outcome, b.outcome);
    }
}

fn fuzzPendingReports(_: void, smith: *std.testing.Smith) !void {
    const alloc = std.testing.allocator;
    const children = [_][]const u8{ "c0", "c1" };
    const works = [_][]const u8{ "w0", "w1", "w2" };
    const spawns = [_]?[]const u8{ null, older_spawn, marked_spawn, "not json" };
    const finishes = [_]?[]const u8{ null, "{\"report\":true}", "{\"failure\":\"x\"}", "{\"failure\":\"x\",\"report\":true}", "{\"report\":false}", "not json" };
    const outcomes = [_]session_adapter.ChildOutcome{ .ok, .failed, .cancelled, .interrupted, .lost };
    var lines: [48]session_adapter.ReportLine = undefined;
    var count: usize = 0;
    while (count < lines.len and !smith.eos()) : (count += 1) {
        const child = children[smith.valueRangeAtMost(u8, 0, children.len - 1)];
        const work = works[smith.valueRangeAtMost(u8, 0, works.len - 1)];
        lines[count] = switch (smith.valueRangeAtMost(u8, 0, 2)) {
            0 => .{ .spawned = .{ .child = child, .work_id = work, .data = spawns[smith.valueRangeAtMost(u8, 0, spawns.len - 1)] } },
            1 => .{ .finished = .{
                .child = child,
                .work_id = work,
                .outcome = outcomes[smith.valueRangeAtMost(u8, 0, outcomes.len - 1)],
                .data = finishes[smith.valueRangeAtMost(u8, 0, finishes.len - 1)],
            } },
            else => .{ .taken = .{ .child = child, .work_id = work } },
        };
    }
    const all = try pendingReports(alloc, lines[0..count]);
    defer alloc.free(all);

    // It matches the counting oracle.
    const oracle = try pendingOracle(alloc, lines[0..count]);
    defer alloc.free(oracle);
    try expectSamePending(oracle, all);

    // Fold law: a prefix's fold, continued over the rest, is the whole fold.
    const split = smith.valueRangeAtMost(u8, 0, @intCast(count));
    var fold: PendingFold = .{};
    defer fold.deinit(alloc);
    for (lines[0..split]) |line| try fold.step(alloc, line);
    for (lines[split..count]) |line| try fold.step(alloc, line);
    try expectSamePending(all, fold.pending.items);

    // Taking every pending report leaves none.
    var taken: PendingFold = .{};
    defer taken.deinit(alloc);
    for (lines[0..count]) |line| try taken.step(alloc, line);
    for (all) |item| try taken.step(alloc, .{ .taken = .{ .child = item.child_id, .work_id = item.work_id } });
    try std.testing.expectEqual(@as(usize, 0), taken.pending.items.len);
}
