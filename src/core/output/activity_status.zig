const std = @import("std");
const types = @import("../shared/types.zig");

pub const StreamState = types.StreamState;
const compaction_activity = @import("compaction_activity.zig");
const turn_clock = @import("turn_clock.zig");
const ActivityProjection = @import("activity_runtime.zig").ActivityProjection;

/// A compaction's own clock, which starts at zero whatever started it. The
/// turn clock holds still meanwhile (`syncWaitingClock`), so the turn goes on
/// from the time it showed before compaction began.
pub fn compactionClock(operation: compaction_activity.Operation) StreamState {
    return .{ .turn_started_ms = turn_clock.compactionMarks(operation).started_ms };
}

/// How far a running compaction has come: nothing of the summary while it
/// prepares, the share of its notes the model has written while it
/// summarizes, and all of it while spark saves them
/// (`tests/tla/turn_clock/TurnClock.tla` FullOnlyWhenSaving).
fn compactionPercent(op: compaction_activity.Operation, stage: compaction_activity.Stage) u8 {
    return switch (stage) {
        .preparation => 0,
        .summary => op.written_percent,
        .publication => 100,
    };
}

/// Borrows either static feedback or the caller's label buffer.
pub fn compactionProjection(
    buf: []u8,
    snapshot: compaction_activity.Snapshot,
    now_ms: i64,
) ActivityProjection {
    const op = snapshot.operation orelse return .none;
    if (!op.visible(now_ms)) return .none;
    const label: []const u8, const percent: ?u8 = switch (op.phase) {
        .preparing => .{ "• Compacting", compactionPercent(op, .preparation) },
        .running => |stage| .{ "• Compacting", compactionPercent(op, stage) },
        .stopping => .{ "• Stopping compaction", null },
        .terminal => |feedback| return .{ .turn_thinking = .{
            .label = compactionFeedbackLabel(feedback),
            .tone = switch (feedback.outcome) {
                .failed => .danger,
                .busy => .warning,
                .succeeded, .no_op, .cancelled => .neutral,
            },
        } },
    };
    var out: std.Io.Writer = .fixed(buf);
    out.writeAll(label) catch return .{ .turn_thinking = .{ .label = label } };
    if (percent) |value| out.print(" {d}%", .{value}) catch return .{ .turn_thinking = .{ .label = label } };
    appendTurnElapsedSuffix(&out, compactionClock(op), now_ms) catch return .{ .turn_thinking = .{ .label = out.buffered() } };
    return .{ .turn_thinking = .{ .label = out.buffered() } };
}

/// The transcript line a successful compaction leaves, with the time its row
/// showed last, such as `Context compacted (2m10s)`. Null for any other
/// outcome, and when `buf` cannot hold the whole line.
pub fn compactionDoneNotice(buf: []u8, op: compaction_activity.Operation) ?[]const u8 {
    const feedback = switch (op.phase) {
        .terminal => |value| value,
        .preparing, .running, .stopping => return null,
    };
    if (feedback.outcome != .succeeded) return null;
    const seconds = turn_clock.seconds(turn_clock.compactionMarks(op), op.settled_at_ms) orelse return null;
    var out: std.Io.Writer = .fixed(buf);
    out.writeAll("Context compacted (") catch return null;
    writeElapsed(&out, seconds) catch return null;
    out.writeByte(')') catch return null;
    return out.buffered();
}

fn compactionFeedbackLabel(feedback: compaction_activity.Feedback) []const u8 {
    if (feedback.publication == .uncertain)
        return "Compaction could not confirm saved context. Reopen the session before retrying.";
    if (feedback.publication == .committed)
        return "Compaction saved context, but could not finish. Reopen the session before retrying.";
    if (feedback.outcome == .failed) {
        if (feedback.err) |err| {
            switch (err) {
                error.CompactionAuthenticationRejected => return "Compaction was not started. Check authentication and try /compact again.",
                error.ContextCapacityExceeded => return "Context is too large to compact. Choose a model with a larger context window.",
                else => {},
            }
        }
    }
    return switch (feedback.outcome) {
        .succeeded => "",
        .no_op => "No context to compact.",
        .busy => "Wait for the active work to finish before compacting context.",
        .cancelled => "Compaction cancelled. Try /compact again when ready.",
        .failed => if (feedback.stage == .preparation)
            "Compaction was not started. Try /compact again."
        else
            "Compaction failed. Try /compact again.",
    };
}

test "compaction feedback distinguishes authentication and capacity from other setup failures" {
    try std.testing.expectEqualStrings(
        "Compaction was not started. Check authentication and try /compact again.",
        compactionFeedbackLabel(compaction_activity.failure(error.CompactionAuthenticationRejected, .preparation, false)),
    );
    try std.testing.expectEqualStrings(
        "Context is too large to compact. Choose a model with a larger context window.",
        compactionFeedbackLabel(compaction_activity.failure(error.ContextCapacityExceeded, .preparation, false)),
    );
    try std.testing.expectEqualStrings(
        "Compaction was not started. Try /compact again.",
        compactionFeedbackLabel(compaction_activity.failure(error.OutOfMemory, .preparation, false)),
    );
}

const ActivityPart = struct {
    count: usize,
    singular: []const u8,
    plural: []const u8,
    verb: []const u8,
};

fn streamStatusVerb(stream: StreamState) []const u8 {
    return switch (stream.last_activity_kind orelse return "thinking") {
        .list => "listing",
        .read => "reading",
        .write => "writing",
        .edit => "editing",
        .command => "running",
        .subagent => "delegating",
        .open => "opening",
        .ask => "asking",
        .mcp => "calling",
    };
}

fn markedTurnPhaseLabel(phase: types.TurnPhase) []const u8 {
    return switch (phase) {
        .thinking => "• Thinking",
        .generating => "• Generating",
        .running, .waiting_for_subagent => "• Running",
    };
}

pub fn buildTurnLabel(buf: []u8, stream: StreamState, now_ms: i64) ?[]const u8 {
    if (stream.last_activity_kind != null) return null;
    var out: std.Io.Writer = .fixed(buf);
    const marked_phase = markedTurnPhaseLabel(stream.phase);
    out.writeAll(marked_phase) catch return marked_phase;
    appendTurnElapsedSuffix(&out, stream, now_ms) catch return out.buffered();
    appendTurnTokenSuffix(&out, stream) catch return out.buffered();
    return out.buffered();
}

pub const activity_blink_half_period_ms: i64 = 500;
/// One displayed second of an activity clock spans exactly one on/off blink
/// period, so the marker relights when the seconds digit advances.
pub const activity_clock_ms_per_second: i64 = 2 * activity_blink_half_period_ms;
comptime {
    // The turn and compaction clocks count seconds in `turn_clock.zig`.
    std.debug.assert(activity_clock_ms_per_second == std.time.ms_per_s);
}

fn turnMarks(stream: StreamState) turn_clock.Marks {
    return .{ .started_ms = stream.turn_started_ms, .waiting_since_ms = stream.waiting_since_ms };
}

/// Marker visibility locked to the elapsed counter's clock: on for the first
/// half of every elapsed second, so the marker relights exactly when the
/// seconds digit advances. Steady on while waiting on user input (a frozen
/// clock would otherwise strand the marker dark). Null when no turn is being
/// timed.
pub fn activityBlinkVisible(stream: StreamState, now_ms: i64) ?bool {
    if (stream.turn_started_ms <= 0 or now_ms < stream.turn_started_ms) return null;
    if (stream.waiting_since_ms > 0) return true;
    const half_periods = @divTrunc(now_ms - stream.turn_started_ms, activity_blink_half_period_ms);
    return @mod(half_periods, 2) == 0;
}

fn appendTurnElapsedSuffix(writer: *std.Io.Writer, stream: StreamState, now_ms: i64) !void {
    const seconds = turn_clock.seconds(turnMarks(stream), now_ms) orelse return;
    try writer.writeAll(" (");
    try writeElapsed(writer, seconds);
    try writer.writeByte(')');
}

/// Formats an elapsed duration as `1h2m3s`, dropping leading units that are
/// zero so short turns stay `5s` while long ones read `18m0s` instead of a
/// wall of seconds.
pub fn writeElapsed(writer: *std.Io.Writer, seconds: i64) !void {
    const secs = @mod(seconds, 60);
    const total_minutes = @divTrunc(seconds, 60);
    const mins = @mod(total_minutes, 60);
    const hours = @divTrunc(total_minutes, 60);
    if (hours > 0) {
        try writer.print("{d}h{d}m{d}s", .{ hours, mins, secs });
    } else if (mins > 0) {
        try writer.print("{d}m{d}s", .{ mins, secs });
    } else {
        try writer.print("{d}s", .{secs});
    }
}

/// Keeps the turn clock honest while the turn waits, on user input (an
/// approval or a question) or on a compaction (`turn_clock.waits`): the clock
/// freezes when the wait begins, and when it ends the whole wait is excluded
/// by moving turn_started_ms forward. Call whenever the waiting state may
/// have changed.
pub fn syncWaitingClock(stream: *StreamState, waiting: bool, now_ms: i64) void {
    const marks = turn_clock.sync(turnMarks(stream.*), stream.active, waiting, now_ms);
    stream.turn_started_ms = marks.started_ms;
    stream.waiting_since_ms = marks.waiting_since_ms;
}

// Width of the "• " marker every other activity row carries.
const marker_indent = "  ";

// The completed turn summary occupies the same marker column without retaining
// the active phase label or blink.
pub fn buildCompletedTurnLabel(buf: []u8, stream: StreamState) []const u8 {
    const progress = stream.token_progress;
    if (progress.input_tokens == 0 and progress.output_tokens == 0) return marker_indent;
    var out: std.Io.Writer = .fixed(buf);
    out.writeAll(marker_indent) catch return marker_indent;
    writeTokenProgress(&out, progress) catch return out.buffered();
    return out.buffered();
}

pub fn buildProgressLabel(buf: []u8, stream: StreamState) ?[]const u8 {
    if (!stream.active) return null;
    return buildThinkingLabelFull(buf, stream);
}

fn buildThinkingLabelFull(buf: []u8, stream: StreamState) []const u8 {
    var out: std.Io.Writer = .fixed(buf);
    out.writeAll(streamStatusVerb(stream)) catch return streamStatusVerb(stream);

    const parts = activityParts(stream);
    if (!hasActivityParts(&parts)) {
        appendTurnTokenSuffix(&out, stream) catch return out.buffered();
        return out.buffered();
    }

    out.writeAll(" | ") catch return out.buffered();

    var first = true;
    for (parts) |part| {
        if (part.count == 0) continue;
        writeActivityPart(&out, &first, part) catch return out.buffered();
    }

    appendTurnTokenSuffix(&out, stream) catch return out.buffered();
    return out.buffered();
}

fn activityParts(stream: StreamState) [8]ActivityPart {
    return .{
        .{ .count = stream.read_count, .singular = "file", .plural = "files", .verb = "read" },
        .{ .count = stream.list_count, .singular = "directory", .plural = "directories", .verb = "listed" },
        .{ .count = stream.write_count, .singular = "file", .plural = "files", .verb = "wrote" },
        .{ .count = stream.edit_count, .singular = "file", .plural = "files", .verb = "edited" },
        .{ .count = stream.command_count, .singular = "command", .plural = "commands", .verb = "started" },
        .{ .count = stream.subagent_count, .singular = "subagent", .plural = "subagents", .verb = "created" },
        .{ .count = stream.open_count, .singular = "file", .plural = "files", .verb = "opened" },
        .{ .count = stream.mcp_count, .singular = "MCP call", .plural = "MCP calls", .verb = "made" },
    };
}

fn hasActivityParts(parts: []const ActivityPart) bool {
    for (parts) |part| {
        if (part.count > 0) return true;
    }
    return false;
}

fn writeActivityPart(writer: *std.Io.Writer, first: *bool, part: ActivityPart) !void {
    if (!first.*) try writer.writeAll(", ");
    first.* = false;
    try writer.print("{d} {s} {s}", .{ part.count, if (part.count == 1) part.singular else part.plural, part.verb });
}

pub fn formatTokenCountCompact(buf: []u8, tokens: u64) []const u8 {
    if (tokens < 1000) return std.mem.print(buf, "{d}", .{tokens}) catch "0";

    const whole = tokens / 1000;
    const tenths = (tokens % 1000) / 100;
    if (whole < 10 and tenths > 0) {
        return std.mem.print(buf, "{d}.{d}k", .{ whole, tenths }) catch "1k";
    }
    return std.mem.print(buf, "{d}k", .{whole}) catch "1k";
}

fn writeTokenProgress(writer: *std.Io.Writer, progress: types.TurnTokenProgress) !void {
    var input_buf: [24]u8 = undefined;
    var output_buf: [24]u8 = undefined;
    try writer.print("(↑{s} ↓{s})", .{
        formatTokenCountCompact(&input_buf, progress.input_tokens),
        formatTokenCountCompact(&output_buf, progress.output_tokens),
    });
}

pub fn appendTokenProgressSuffix(writer: *std.Io.Writer, progress: types.TurnTokenProgress) !void {
    if (progress.input_tokens == 0 and progress.output_tokens == 0) return;
    try writer.writeByte(' ');
    try writeTokenProgress(writer, progress);
}

pub fn appendTurnTokenSuffix(writer: *std.Io.Writer, stream: StreamState) !void {
    try appendTokenProgressSuffix(writer, stream.token_progress);
}
