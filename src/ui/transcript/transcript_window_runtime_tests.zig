//! The transcript window driving a real transcript runtime
//! (`transcript_window_shell.zig`): what a compaction leaves in memory, and
//! what stays while it is still on screen.

const std = @import("std");
const runtime_mod = @import("runtime.zig");
const transcript_store = @import("store.zig");
const source_preparation = @import("source_preparation.zig");
const frozen_prefix = @import("frozen_prefix.zig");
const types = @import("../../core/shared/types.zig");
const render_engine = @import("../render_engine.zig");

const TranscriptRuntime = runtime_mod.TranscriptRuntime;
const Allocator = std.mem.Allocator;

fn testRuntime(alloc: Allocator) TranscriptRuntime {
    return .{
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
        .owned_top_row = 1,
        .has_committed_frame = true,
        .detached_commit_alloc = alloc,
        .committed_frame_layout = .{ .terminal_cols = 80, .terminal_rows = 24 },
    };
}

fn runTurn(alloc: Allocator, runtime: *TranscriptRuntime, metrics: *types.Metrics, prompt: []const u8, answer: []const u8) !void {
    const text = try alloc.dupe(u8, prompt);
    defer alloc.free(text);
    _ = try runtime.writeUserPromptCard(alloc, metrics, .{ .text = text }, runtime.notebook.entries.items.len > 0, &.{});
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "● Read notes.txt\n", .tool_status);
    _ = try runtime.appendAssistantTurnEntry(alloc);
    _ = try runtime.streamAssistantChunk(alloc, metrics, answer);
    _ = try runtime.appendTurnSummaryEntry(alloc, .{ .turn_duration_ms = 1200 });
}

fn holds(runtime: *const TranscriptRuntime, needle: []const u8) bool {
    for (runtime.notebook.entries.items) |entry| switch (entry) {
        .user_turn => |value| if (std.mem.find(u8, value.turn.text, needle) != null) return true,
        .assistant_turn => |value| if (std.mem.find(u8, value.segments.text.items, needle) != null) return true,
        .raw_bytes => |value| if (std.mem.find(u8, value.bytes, needle) != null) return true,
        else => {},
    };
    return false;
}

/// The runtime's prepared source equals a full render of what it holds.
fn expectPreparedMatchesFull(alloc: Allocator, runtime: *TranscriptRuntime) !void {
    var resumed = try source_preparation.prepareTranscriptSource(runtime, alloc, null);
    defer resumed.deinit(alloc);
    var empty: frozen_prefix.FrozenPrefix = .{};
    defer empty.deinit();
    const previous = runtime.frozen_prefix_source;
    runtime.frozen_prefix_source = &empty;
    defer runtime.frozen_prefix_source = previous;
    var full = try source_preparation.prepareTranscriptSource(runtime, alloc, null);
    defer full.deinit(alloc);
    try std.testing.expectEqualDeep(full, resumed);
}

/// The window and the runtime agree on what is held.
fn expectWindowMatchesEntries(runtime: *const TranscriptRuntime) !void {
    const window = &runtime.transcript_window.?;
    try std.testing.expectEqual(runtime.notebook.entries.items.len, window.finished.items.len + window.pending_drops.items.len);
    var index: usize = 0;
    for (runtime.notebook.entries.items) |entry| {
        if (std.mem.findScalar(u32, window.pending_drops.items, entry.id()) != null) continue;
        try std.testing.expectEqual(window.finished.items[index], entry.id());
        index += 1;
    }
}

/// Commits the runtime's current transcript as a stable frame with no row
/// released into terminal history yet.
fn commitStableFrame(alloc: Allocator, runtime: *TranscriptRuntime) !void {
    std.debug.assert(runtime.transcript_commit_state == .invalid);
    var metrics: types.Metrics = .{};
    var flow = try source_preparation.prepareRetentionSource(runtime, alloc);
    defer flow.deinit(alloc);
    try flow.ensureLineIndex(alloc);
    var identity = try source_preparation.RetentionIdentity.capture(runtime, alloc, &flow);
    errdefer identity.deinit(alloc);
    const total = flow.transcript_visual_row_offsets[flow.transcript_visual_row_offsets.len - 1];
    var prepared = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(alloc, &metrics, &flow, .{ .top = 1, .bottom = 20 });
    defer prepared.deinit(alloc);
    const owned_flow = try alloc.dupe(u8, flow.bytes);
    errdefer alloc.free(owned_flow);
    runtime.transcript_commit_state = .{ .stable = .{
        .selection = prepared.selection,
        .visual_offset = total,
        .history_visual_offset = 0,
        .total_visual_rows = total,
        .flow = owned_flow,
        .retention_identity = identity,
        .cursor_row = prepared.cursor.cursor_row,
        .cursor_col = prepared.cursor.cursor_col,
        .occupied_last_row = prepared.selection.last_visible_row,
        .occupied_last_row_blank = prepared.selection.last_visible_row_blank,
        .layout_id = 1,
    } };
}

/// A frame the terminal accepted without scrolling.
fn committedFrameResult() render_engine.terminal_diff.FrameCommitResult {
    return .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = false,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = 1,
        .committed_cursor_col = 1,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    };
}

/// How many of a frame's rows the terminal history holds after it.
const ReleasedRows = enum { none, all };

/// A frame that paints the runtime's entries. It paints `resume_flow`, the
/// pending resume source it borrows, or with null the entries' own flow.
fn transcriptFrame(
    alloc: Allocator,
    runtime: *TranscriptRuntime,
    resume_flow: ?[]u8,
    released: ReleasedRows,
) !runtime_mod.TranscriptTransition {
    var metrics: types.Metrics = .{};
    var flow = try source_preparation.prepareRetentionSource(runtime, alloc);
    defer flow.deinit(alloc);
    try flow.ensureLineIndex(alloc);
    const total = flow.transcript_visual_row_offsets[flow.transcript_visual_row_offsets.len - 1];
    var prepared = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(alloc, &metrics, &flow, .{ .top = 1, .bottom = 20 });
    defer prepared.deinit(alloc);
    var transition: runtime_mod.TranscriptTransition = .{
        .scroll_plan = render_engine.frame_scroll_plan.FrameScrollPlan.none(24, 1),
        .document_append = .{},
        .materialized_without_append = .{},
        .target_flow = &.{},
        .target_cache = .empty,
        .target_cache_unchanged = true,
        .folded_summary_indices = &.{},
        .target_layout = .{ .terminal_rows = 24, .terminal_cols = 80 },
        .selection = prepared.selection,
        .visual_offset = total,
        .history_visual_offset = switch (released) {
            .none => 0,
            .all => total,
        },
        .total_visual_rows = total,
        .cursor_row = prepared.cursor.cursor_row,
        .cursor_col = prepared.cursor.cursor_col,
        .replaceable_last_line = false,
        .replaceable_start = 0,
        .replaceable_row = 1,
        .trace_transcript_frame = false,
        .trace_visible_rows = 1,
    };
    if (resume_flow) |bytes| {
        transition.target_flow = bytes;
        transition.target_flow_owned = false;
        return transition;
    }
    transition.target_flow = try alloc.dupe(u8, flow.bytes);
    errdefer alloc.free(transition.target_flow);
    transition.retention_identity = try source_preparation.RetentionIdentity.capture(runtime, alloc, &flow);
    return transition;
}

test "the transcript window removes a compaction's closed cycle at the next turn end, once the session log holds it" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);

    try runTurn(alloc, &runtime, &metrics, "FIRST_PROMPT", "FIRST_ANSWER\n");
    try runTurn(alloc, &runtime, &metrics, "SECOND_PROMPT", "SECOND_ANSWER\n");
    try std.testing.expect(holds(&runtime, "FIRST_PROMPT") and holds(&runtime, "SECOND_ANSWER"));
    try expectPreparedMatchesFull(alloc, &runtime);
    try expectWindowMatchesEntries(&runtime);

    // Between turns, with both turns saved and nothing on screen, the closed
    // cycle still waits for the next turn end, so a resize before it
    // reprints it.
    try runtime.transcriptWindowCompacted(alloc);
    try std.testing.expect(runtime.transcriptWindowHoldsPreviousCycle());
    try std.testing.expect(holds(&runtime, "FIRST_PROMPT") and holds(&runtime, "SECOND_ANSWER"));
    try expectWindowMatchesEntries(&runtime);

    try runTurn(alloc, &runtime, &metrics, "THIRD_PROMPT", "THIRD_ANSWER\n");
    try std.testing.expect(!runtime.transcriptWindowHoldsPreviousCycle());
    try std.testing.expect(!holds(&runtime, "FIRST_PROMPT") and !holds(&runtime, "SECOND_ANSWER"));
    try std.testing.expect(holds(&runtime, "THIRD_PROMPT") and holds(&runtime, "THIRD_ANSWER"));
    try std.testing.expect(std.mem.find(u8, runtime.notebook.transcript.items, "FIRST_ANSWER") == null);
    try std.testing.expect(std.mem.find(u8, runtime.notebook.transcript.items, "THIRD_ANSWER") != null);
    try expectPreparedMatchesFull(alloc, &runtime);
    try expectWindowMatchesEntries(&runtime);
}

const full_transcript_page = @import("../../core/output/full_transcript_page.zig");

fn rawEntries(alloc: Allocator, runtime: *TranscriptRuntime, texts: []const []const u8) !void {
    for (texts) |text| _ = try runtime.appendRawTranscriptEntryClassified(alloc, text, .tool_status);
}

fn archivedCycle(alloc: Allocator, back: u32, texts: []const []const u8) !TranscriptRuntime {
    var archived = testRuntime(alloc);
    archived.notebook.next_entry_id = runtime_mod.archiveEntryIdBase(back);
    try rawEntries(alloc, &archived, texts);
    return archived;
}

fn pageTexts(alloc: Allocator, runtime: *TranscriptRuntime, anchor: full_transcript_page.Anchor) ![]const u8 {
    var source = try runtime.snapshotFullTranscriptPage(.{ .anchor = anchor, .content_revision = 0, .cols = 80 }, null, null);
    defer source.deinit(std.heap.c_allocator);
    var text: std.ArrayList(u8) = .empty;
    for (source.entries.items) |entry| try text.appendSlice(alloc, entry.raw_bytes.bytes);
    return text.toOwnedSlice(alloc);
}

const io_mod = @import("../../core/shared/io.zig");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");
const command_output_runtime = @import("command_output_runtime.zig");

/// An older cycle of `count` entries, `older 0` first.
fn numberedCycle(alloc: Allocator, count: usize) !TranscriptRuntime {
    var archived = testRuntime(alloc);
    errdefer archived.deinit(alloc);
    archived.notebook.next_entry_id = runtime_mod.archiveEntryIdBase(1);
    var buf: [32]u8 = undefined;
    for (0..count) |index| {
        _ = try archived.appendRawTranscriptEntryClassified(alloc, try std.mem.print(&buf, "older {d}\n", .{index}), .tool_status);
    }
    return archived;
}
