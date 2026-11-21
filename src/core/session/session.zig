const std = @import("std");
const agent_frame = @import("../shared/agent_frame.zig");
const recovery_prompt = @import("../shared/recovery_prompt.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const kernel_agent = @import("../agent/runtime/agent.zig");
const cache_warmer = @import("../agent/runtime/cache_warmer.zig");
const host_target = @import("../hosts/target.zig");
const core_types = @import("../shared/types.zig");
const history_range = @import("../shared/history_range.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const message = @import("../shared/message.zig");
const language_script = @import("../shared/language_script.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const image_attachments = @import("../images/image_attachments.zig");
const compactor = @import("../compactor/compactor.zig");
const web_fetch_artifacts = @import("web_fetch_artifacts.zig");
const command_replay_store = @import("command_replay_store.zig");
const session_child_store = @import("session_child_store.zig");
const command_contract = @import("../execution/command_contract.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const text_utils = @import("../shared/text_utils.zig");
const Allocator = std.mem.Allocator;

const compact_continuation_preamble = "This session is being continued from earlier compacted context. The summary below covers the earlier portion of the conversation.\n\n";
const compact_recent_messages_note = "Recent conversation turns are preserved verbatim.";
const compact_direct_resume_instruction = "Continue the conversation from where it left off without asking the user to repeat context. Resume directly.";

pub const interrupted_turn_notice: core_types.SemanticNotice = .{
    .topic = "system",
    .tone = .cancelled,
    .body = "cancelled",
};

pub const failed_turn_notice: core_types.SemanticNotice = .{
    .topic = "system",
    .tone = .@"error",
    .body = "failed",
};

/// A turn spark itself stopped, by crashing or closing, which the next launch
/// sends again.
pub const stopped_turn_notice: core_types.SemanticNotice = .{
    .topic = "system",
    .tone = .warning,
    .body = "spark stopped before this turn finished",
};

pub fn interruptedTurnNotice(entry: InterruptedHistoryTurn) core_types.SemanticNotice {
    if (entry.stopped_by_exit) return stopped_turn_notice;
    return switch (entry.terminal_reason) {
        .cancelled => interrupted_turn_notice,
        .failed => failed_turn_notice,
    };
}

pub const interrupted_turn_context =
    "<turn_aborted>\n" ++
    "The previous turn ended before completion. Any tools or commands may have partially executed. " ++
    "Do not continue this request unless the user explicitly asks to continue.\n" ++
    "</turn_aborted>";

/// What the model reads in place of a user message when the app resumes a
/// request a previous spark process left unfinished. The turn before it is the
/// interrupted one, and a tool that was running there is answered as
/// possibly run.
pub const resumed_request_prompt =
    "<session_resumed>\n" ++
    "spark stopped before the previous turn finished, because it crashed or its window was closed. " ++
    "A tool that was running may have partly run. Check what finished, rerun only what is safe to repeat, " ++
    "and continue the previous request.\n" ++
    "</session_resumed>";

/// What the model reads in place of `resumed_request_prompt` when the turn spark
/// stopped ran no tool: that turn is projected as the user's own message, so
/// there is nothing to check and nothing to say no to.
pub const resumed_request_note_no_tool =
    "<session_resumed>\n" ++
    "spark stopped before it answered the message above, because it crashed or its window was closed. " ++
    "Nothing ran. Answer that message now.\n" ++
    "</session_resumed>";

/// Whether an interrupted turn ran no tool at all. A tool spark stopped in the
/// middle of is not `tool_call`: the session repairs it into a step of its
/// own, answered as possibly run.
fn ranNothing(entry: core_types.InterruptedHistoryTurn) bool {
    return entry.tool_call == null and entry.completed_tool_names.len == 0 and entry.execution.tool_steps.len == 0;
}

/// Drops trailing interrupted turns that were themselves resumes and ran
/// nothing, so a request closed twice continues the turn spark stopped first.
pub fn withoutSupersededResumes(history: []const HistoryTurn) []const HistoryTurn {
    var end = history.len;
    while (end > 0) : (end -= 1) {
        switch (history[end - 1]) {
            .interrupted => |entry| if (ranNothing(entry) and std.mem.eql(u8, entry.user.text, resumed_request_prompt)) continue,
            else => {},
        }
        break;
    }
    return history[0..end];
}

/// Whether a turn is a resume spark sent for a request it stopped. Its saved
/// text is always `resumed_request_prompt`; the projection picks the note.
fn isResumeTurn(turn: HistoryTurn) bool {
    const text = switch (turn) {
        .assistant => |entry| entry.user.text,
        .interrupted => |entry| entry.user.text,
        .compacted_summary => return false,
    };
    return std.mem.eql(u8, text, resumed_request_prompt);
}

/// A resume that ran nothing before spark resumed the request again: the later
/// resume dropped it, so every later request drops it too.
fn isSupersededResume(history: []const HistoryTurn, index: usize) bool {
    if (index + 1 >= history.len) return false;
    return switch (history[index]) {
        .interrupted => |entry| ranNothing(entry) and isResumeTurn(history[index]) and isResumeTurn(history[index + 1]),
        else => false,
    };
}

/// Whether spark later resumed the request this interrupted turn left
/// unfinished. Such a turn reads as the resume request read it: with no
/// abort note, since the request went on.
fn isResumedLater(history: []const HistoryTurn, index: usize) bool {
    if (history[index] != .interrupted) return false;
    var next = index + 1;
    while (next < history.len and isSupersededResume(history, next)) next += 1;
    return next < history.len and isResumeTurn(history[next]);
}

/// The note a resumed request sends. A stopped turn that ran a tool keeps
/// the caveat that it may have partly run; one that ran nothing is the
/// user's message, still to answer.
pub fn resumedRequestNote(history: []const HistoryTurn) []const u8 {
    if (history.len == 0) return resumed_request_note_no_tool;
    return switch (history[history.len - 1]) {
        .interrupted => |entry| if (ranNothing(entry)) resumed_request_note_no_tool else resumed_request_prompt,
        else => resumed_request_note_no_tool,
    };
}

/// What the transcript shows in place of `resumed_request_prompt`, live and
/// when the session is replayed.
pub const resumed_request_notice: core_types.SemanticNotice = .{
    .topic = "session",
    .tone = .neutral,
    .body = "Resuming the interrupted request",
};

pub fn projectSnapshotLocator(buffer: []u8, path: []const u8) ![]const u8 {
    if (!std.Io.Dir.path.isAbsolute(path)) return path;
    return std.mem.print(buffer, "images/{s}", .{std.Io.Dir.path.basename(path)});
}

pub const interrupted_before_completion_output = "The previous response ended before completion.";
pub const aborted_tool_output = "aborted by user";

/// Conversation language tag stored in session records.
pub const ConversationLanguage = core_types.ConversationLanguage;
/// Image attachment metadata stored on user turns.
pub const ImageAttachment = core_types.ImageAttachment;
/// User-side text and image attachments for a stored history turn.
pub const UserTurn = core_types.UserTurn;
/// Gateway tool call metadata stored when an interrupted turn is cancelled during a tool call.
pub const ToolCall = core_types.ToolCall;
/// Stored assistant response paired with the user turn that produced it.
pub const AssistantHistoryTurn = core_types.AssistantHistoryTurn;
/// Stored background command metadata paired with the user turn that produced it.
pub const CancelledCommandPresentation = core_types.CancelledCommandPresentation;
/// Stored interrupted turn marker, optionally paired with the active tool call.
pub const InterruptedHistoryTurn = core_types.InterruptedHistoryTurn;
pub const InterruptedTerminalReason = core_types.InterruptedTerminalReason;

fn formatInterruptedToolOutput(
    alloc: Allocator,
    entry: InterruptedHistoryTurn,
) ![]u8 {
    const presentation = entry.cancelled_command orelse
        return alloc.dupe(u8, aborted_tool_output);
    const replay = presentation.output_replay orelse
        return alloc.dupe(u8, aborted_tool_output);
    const descriptor = switch (replay) {
        .available => |value| value,
        .unavailable => return alloc.dupe(u8, aborted_tool_output),
    };
    return command_replay_store.appendModelHandleNotice(
        alloc,
        aborted_tool_output,
        descriptor.handle,
    ) catch |err| switch (err) {
        error.InvalidReplayHandle => {
            debug_trace.logf(
                "session",
                "cancelled command replay handle omitted from model context handle_bytes={d}",
                .{descriptor.handle.len},
            );
            return alloc.dupe(u8, aborted_tool_output);
        },
        else => return err,
    };
}

/// Stored compacted context summary produced by core history compaction.
pub const CompactedSummaryHistoryTurn = core_types.CompactedSummaryHistoryTurn;
/// One persisted session history record.
pub const HistoryTurn = core_types.HistoryTurn;
pub const freeUserTurn = core_types.freeUserTurn;
pub const dupeUserTurn = core_types.dupeUserTurn;
pub const max_work_id_bytes: usize = 128;

pub const WorkIdAssociation = enum {
    none,
    copy_event,
    already_associated,
};

pub const WorkIdError = error{
    InvalidWorkId,
    ConflictingWorkId,
};

pub fn validateWorkId(work_id: []const u8) WorkIdError!void {
    if (work_id.len == 0 or work_id.len > max_work_id_bytes or
        !std.unicode.utf8ValidateSlice(work_id) or
        std.mem.findScalar(u8, work_id, 0) != null)
    {
        return error.InvalidWorkId;
    }
}

pub fn historyTurnWorkId(turn: HistoryTurn) ?[]const u8 {
    return switch (turn) {
        .assistant => |entry| entry.user.work_id,
        .interrupted => |entry| entry.user.work_id,
        .compacted_summary => null,
    };
}

/// Purely decides how authoritative event provenance relates to one turn.
pub fn decideWorkIdAssociation(
    turn: HistoryTurn,
    event_work_id: ?[]const u8,
) WorkIdError!WorkIdAssociation {
    const turn_work_id = historyTurnWorkId(turn);
    if (turn_work_id) |work_id| try validateWorkId(work_id);
    if (event_work_id) |work_id| try validateWorkId(work_id);

    if (event_work_id == null) {
        return if (turn_work_id == null) .none else error.ConflictingWorkId;
    }
    if (turn == .compacted_summary) return error.ConflictingWorkId;
    if (turn_work_id) |work_id| {
        return if (std.mem.eql(u8, work_id, event_work_id.?))
            .already_associated
        else
            error.ConflictingWorkId;
    }
    return .copy_event;
}

/// Installs a separately owned work ID after pure association succeeds.
pub fn copyWorkIdToTurn(
    alloc: Allocator,
    turn: *HistoryTurn,
    work_id: []const u8,
) (Allocator.Error || WorkIdError)!void {
    if (try decideWorkIdAssociation(turn.*, work_id) != .copy_event) return;
    const owned = try alloc.dupe(u8, work_id);
    switch (turn.*) {
        .assistant => |*entry| entry.user.work_id = owned,
        .interrupted => |*entry| entry.user.work_id = owned,
        .compacted_summary => unreachable,
    }
}

pub const freeHistoryTurn = core_types.freeHistoryTurn;
pub const dupeToolCall = core_types.dupeToolCall;
pub const freeToolCall = core_types.freeToolCall;
pub const freeCompletedToolNames = core_types.freeCompletedToolNames;
pub const ExecutionMemory = core_types.ExecutionMemory;
pub const ToolExecutionStep = core_types.ToolExecutionStep;
pub const PersistedToolResult = core_types.PersistedToolResult;
pub const PersistedToolStatus = core_types.PersistedToolStatus;
pub const FileEvidence = core_types.FileEvidence;
pub const FileEvidenceAction = core_types.FileEvidenceAction;
pub const freeExecutionMemory = core_types.freeExecutionMemory;
pub const freeToolCallSlice = core_types.freeToolCallSlice;
pub const freePersistedToolResults = core_types.freePersistedToolResults;

/// Builds a sorted, independently owned attachment catalog from complete
/// canonical history plus current-turn images. The caller frees the returned
/// slice with `core_types.freeImageAttachmentSlice` using the same allocator.
pub fn collect_image_catalog(
    alloc: Allocator,
    canonical_history: []const HistoryTurn,
    current_images: []const ImageAttachment,
) (Allocator.Error || error{
    ImageCatalogTooLarge,
    InvalidImageId,
    DuplicateImageId,
})![]ImageAttachment {
    var attachment_count = current_images.len;
    for (canonical_history) |turn| {
        attachment_count = std.math.add(
            usize,
            attachment_count,
            images_for_history_turn(turn).len,
        ) catch return error.ImageCatalogTooLarge;
    }
    if (attachment_count == 0) return &.{};

    const catalog = try alloc.alloc(ImageAttachment, attachment_count);
    errdefer alloc.free(catalog);
    var copied: usize = 0;
    errdefer for (catalog[0..copied]) |attachment| {
        core_types.freeImageAttachment(alloc, attachment);
    };

    for (canonical_history) |turn| {
        for (images_for_history_turn(turn)) |attachment| {
            catalog[copied] = try core_types.dupeImageAttachment(alloc, attachment);
            copied += 1;
        }
    }
    for (current_images) |attachment| {
        catalog[copied] = try core_types.dupeImageAttachment(alloc, attachment);
        copied += 1;
    }

    sort_utils.sort(ImageAttachment, catalog, {}, image_id_less_than);
    var previous_id: ?usize = null;
    for (catalog) |attachment| {
        if (attachment.id == 0) return error.InvalidImageId;
        if (previous_id == attachment.id) return error.DuplicateImageId;
        previous_id = attachment.id;
    }
    std.debug.assert(image_attachments.imageAttachmentsSortedById(catalog));
    return catalog;
}

/// Returns a new owned catalog containing any image authority introduced by a
/// completed history turn. Existing IDs must either match exactly or the
/// queued catalog is rejected as stale.
pub fn merge_image_catalog_history_turn(
    alloc: Allocator,
    catalog: []const ImageAttachment,
    turn: HistoryTurn,
) (Allocator.Error || error{
    ImageCatalogTooLarge,
    InvalidImageId,
    DuplicateImageId,
    StaleImageCatalog,
})![]ImageAttachment {
    try validate_image_catalog(catalog);
    const additions = images_for_history_turn(turn);
    var missing_count: usize = 0;
    for (additions, 0..) |addition, index| {
        if (addition.id == 0) return error.InvalidImageId;
        for (additions[0..index]) |prior| {
            if (prior.id == addition.id) return error.DuplicateImageId;
        }
        if (image_attachment_for_id(catalog, addition.id)) |existing| {
            if (!image_attachments_equal(existing, addition)) return error.StaleImageCatalog;
        } else {
            missing_count += 1;
        }
    }

    const attachment_count = std.math.add(usize, catalog.len, missing_count) catch
        return error.ImageCatalogTooLarge;
    if (attachment_count == 0) return &.{};
    const merged = try alloc.alloc(ImageAttachment, attachment_count);
    errdefer alloc.free(merged);
    var copied: usize = 0;
    errdefer for (merged[0..copied]) |attachment| {
        core_types.freeImageAttachment(alloc, attachment);
    };
    for (catalog) |attachment| {
        merged[copied] = try core_types.dupeImageAttachment(alloc, attachment);
        copied += 1;
    }
    for (additions) |attachment| {
        if (image_attachment_for_id(catalog, attachment.id) != null) continue;
        merged[copied] = try core_types.dupeImageAttachment(alloc, attachment);
        copied += 1;
    }
    sort_utils.sort(ImageAttachment, merged, {}, image_id_less_than);
    try validate_image_catalog(merged);
    return merged;
}

fn validate_image_catalog(catalog: []const ImageAttachment) error{
    InvalidImageId,
    DuplicateImageId,
}!void {
    var previous_id: ?usize = null;
    for (catalog) |attachment| {
        if (attachment.id == 0) return error.InvalidImageId;
        if (previous_id != null and previous_id.? >= attachment.id) {
            if (previous_id.? == attachment.id) return error.DuplicateImageId;
            return error.InvalidImageId;
        }
        previous_id = attachment.id;
    }
}

fn image_attachment_for_id(
    attachments: []const ImageAttachment,
    id: usize,
) ?ImageAttachment {
    for (attachments) |attachment| {
        if (attachment.id == id) return attachment;
    }
    return null;
}

fn image_attachments_equal(lhs: ImageAttachment, rhs: ImageAttachment) bool {
    return lhs.id == rhs.id and
        std.mem.eql(u8, lhs.path, rhs.path) and
        std.mem.eql(u8, lhs.media_type, rhs.media_type) and
        optionalBytesEqual(lhs.snapshot_path, rhs.snapshot_path) and
        optionalBytesEqual(lhs.snapshot_sha256, rhs.snapshot_sha256);
}

fn optionalBytesEqual(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null or rhs == null) return lhs == null and rhs == null;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn images_for_history_turn(turn: HistoryTurn) []const ImageAttachment {
    return switch (turn) {
        .compacted_summary => &.{},
        .assistant => |entry| entry.user.images,
        .interrupted => |entry| entry.user.images,
    };
}

fn mutable_images_for_history_turn(turn: *HistoryTurn) []ImageAttachment {
    return switch (turn.*) {
        .compacted_summary => &.{},
        .assistant => |*entry| entry.user.images,
        .interrupted => |*entry| entry.user.images,
    };
}

fn user_text_for_history_turn(turn: HistoryTurn) []const u8 {
    return switch (turn) {
        .compacted_summary => "",
        .assistant => |entry| entry.user.text,
        .interrupted => |entry| entry.user.text,
    };
}

const LegacyImagePlaceholderIterator = struct {
    text: []const u8,
    offset: usize = 0,

    const prefix = "[Image #";
    const Slot = struct {
        id: ?usize,
        start: usize,
        length: usize,
    };

    fn next(self: *@This()) ?Slot {
        const relative_start = std.mem.find(u8, self.text[self.offset..], prefix) orelse
            return null;
        const start = self.offset + relative_start;
        if (image_attachments.matchImagePlaceholder(self.text, start)) |match| {
            self.offset = start + match.length;
            return .{ .id = match.id, .start = start, .length = match.length };
        }

        const body_start = start + prefix.len;
        self.offset = if (std.mem.findScalar(u8, self.text[body_start..], ']')) |relative_end|
            body_start + relative_end + 1
        else
            body_start;
        return .{ .id = null, .start = start, .length = self.offset - start };
    }
};

const LegacyImageRepair = struct {
    turn_index: usize,
    image_index: usize,
    placeholder: ?LegacyImagePlaceholderIterator.Slot,
    assigned_id: usize = 0,
};

const LegacyTurnTextRepair = struct {
    turn_index: usize,
    text: []u8,
};

fn history_placeholder_id_count(history: []const HistoryTurn, id: usize) usize {
    var count: usize = 0;
    for (history) |turn| {
        var placeholders = LegacyImagePlaceholderIterator{
            .text = user_text_for_history_turn(turn),
        };
        while (placeholders.next()) |placeholder| {
            if (placeholder.id != null and placeholder.id.? == id) count += 1;
        }
    }
    return count;
}

fn legacy_placeholder_claim(
    history: []const HistoryTurn,
    placeholder: ?LegacyImagePlaceholderIterator.Slot,
) ?usize {
    const slot = placeholder orelse return null;
    const placeholder_id = slot.id orelse return null;
    if (placeholder_id == 0) return null;
    if (history_placeholder_id_count(history, placeholder_id) != 1) return null;
    if (history_contains_image_id(history, placeholder_id)) return null;
    return placeholder_id;
}

fn legacy_repairs_contain_id(repairs: []const LegacyImageRepair, id: usize) bool {
    for (repairs) |repair| {
        if (repair.assigned_id == id) return true;
    }
    return false;
}

fn assign_legacy_image_ids(
    history: []const HistoryTurn,
    repairs: []LegacyImageRepair,
) error{ImageIdOverflow}!void {
    for (repairs) |*repair| {
        repair.assigned_id = legacy_placeholder_claim(history, repair.placeholder) orelse 0;
    }

    var candidate: usize = 1;
    for (repairs) |*repair| {
        if (repair.assigned_id != 0) continue;
        while (history_contains_image_id(history, candidate) or
            legacy_repairs_contain_id(repairs, candidate))
        {
            candidate = std.math.add(usize, candidate, 1) catch
                return error.ImageIdOverflow;
        }
        repair.assigned_id = candidate;
    }
}

fn rebuilt_legacy_turn_text(
    alloc: Allocator,
    history: []const HistoryTurn,
    turn_index: usize,
    repairs: []const LegacyImageRepair,
) Allocator.Error!?[]u8 {
    const text = user_text_for_history_turn(history[turn_index]);
    var needs_rebuild = false;
    for (repairs) |repair| {
        if (repair.turn_index != turn_index) continue;
        const placeholder = repair.placeholder orelse continue;
        const legacy_id = placeholder.id orelse continue;
        if (legacy_id != repair.assigned_id) needs_rebuild = true;
    }
    if (!needs_rebuild) return null;

    var rebuilt: std.Io.Writer.Allocating = .init(alloc);
    errdefer rebuilt.deinit();
    var cursor: usize = 0;
    for (repairs) |repair| {
        if (repair.turn_index != turn_index) continue;
        const placeholder = repair.placeholder orelse continue;
        const legacy_id = placeholder.id orelse continue;
        if (legacy_id == repair.assigned_id) continue;

        std.debug.assert(placeholder.start >= cursor);
        std.debug.assert(placeholder.start + placeholder.length <= text.len);
        rebuilt.writer.writeAll(text[cursor..placeholder.start]) catch return error.OutOfMemory;
        image_attachments.writeImagePlaceholder(&rebuilt.writer, repair.assigned_id) catch return error.OutOfMemory;
        cursor = placeholder.start + placeholder.length;
    }
    rebuilt.writer.writeAll(text[cursor..]) catch return error.OutOfMemory;
    return rebuilt.toOwnedSlice() catch return error.OutOfMemory;
}

fn mutable_user_for_history_turn(turn: *HistoryTurn) ?*UserTurn {
    return switch (turn.*) {
        .compacted_summary => null,
        .assistant => |*entry| &entry.user,
        .interrupted => |*entry| &entry.user,
    };
}

/// Repairs image IDs omitted by the legacy session deep-copy path. This is
/// only for allocator-owned history loaded from durable storage. Rebuilt text
/// remains owned by its history turn. Returns whether any attachment changed.
pub fn repair_legacy_zero_image_ids(
    alloc: Allocator,
    history: []HistoryTurn,
) (Allocator.Error || error{ImageIdOverflow})!bool {
    var repairs: std.ArrayList(LegacyImageRepair) = .empty;
    defer repairs.deinit(alloc);
    for (history, 0..) |*turn, turn_index| {
        var placeholders = LegacyImagePlaceholderIterator{
            .text = user_text_for_history_turn(turn.*),
        };
        for (mutable_images_for_history_turn(turn), 0..) |attachment, image_index| {
            const placeholder = placeholders.next();
            if (attachment.id != 0) continue;
            try repairs.append(alloc, .{
                .turn_index = turn_index,
                .image_index = image_index,
                .placeholder = placeholder,
            });
        }
    }
    if (repairs.items.len == 0) return false;

    try assign_legacy_image_ids(history, repairs.items);

    var text_repairs: std.ArrayList(LegacyTurnTextRepair) = .empty;
    defer text_repairs.deinit(alloc);
    errdefer for (text_repairs.items) |repair| alloc.free(repair.text);
    for (history, 0..) |_, turn_index| {
        const rebuilt = try rebuilt_legacy_turn_text(
            alloc,
            history,
            turn_index,
            repairs.items,
        ) orelse continue;
        text_repairs.append(alloc, .{ .turn_index = turn_index, .text = rebuilt }) catch |err| {
            alloc.free(rebuilt);
            return err;
        };
    }

    for (repairs.items) |repair| {
        mutable_images_for_history_turn(&history[repair.turn_index])[repair.image_index].id =
            repair.assigned_id;
    }
    for (text_repairs.items) |repair| {
        const user = mutable_user_for_history_turn(&history[repair.turn_index]).?;
        alloc.free(user.text);
        user.text = repair.text;
    }
    return true;
}

fn make_owned_legacy_image_turn(
    alloc: Allocator,
    text: []const u8,
    assistant: []const u8,
    path: []const u8,
) !HistoryTurn {
    var turn = try makeAssistantTurn(alloc, text, assistant);
    errdefer freeHistoryTurn(alloc, turn);
    turn.assistant.user.images = try core_types.dupeImageAttachmentSlice(alloc, &.{.{
        .path = @constCast(path),
        .media_type = @constCast("image/png"),
    }});
    return turn;
}

test "a turn spark stopped by crashing or closing reads as stopped, not failed or cancelled" {
    const stopped: InterruptedHistoryTurn = .{ .user = .{ .text = @constCast("go") }, .terminal_reason = .failed, .stopped_by_exit = true };
    try std.testing.expectEqualStrings("spark stopped before this turn finished", interruptedTurnNotice(stopped).body);
    try std.testing.expectEqual(core_types.NoticeTone.warning, interruptedTurnNotice(stopped).tone);
    // Esc and a turn that failed keep their own notices.
    const cancelled: InterruptedHistoryTurn = .{ .user = .{ .text = @constCast("go") }, .terminal_reason = .cancelled };
    try std.testing.expectEqualStrings("cancelled", interruptedTurnNotice(cancelled).body);
    const failed: InterruptedHistoryTurn = .{ .user = .{ .text = @constCast("go") }, .terminal_reason = .failed };
    try std.testing.expectEqualStrings("failed", interruptedTurnNotice(failed).body);
}

fn history_contains_image_id(history: []const HistoryTurn, id: usize) bool {
    for (history) |turn| {
        for (images_for_history_turn(turn)) |attachment| {
            if (attachment.id == id) return true;
        }
    }
    return false;
}

fn image_id_less_than(_: void, lhs: ImageAttachment, rhs: ImageAttachment) bool {
    return lhs.id < rhs.id;
}

pub const PersistedToolArgumentsSource = enum {
    schema_v3,
    legacy,
};

pub fn repairPersistedToolArguments(
    alloc: Allocator,
    calls: []ToolCall,
    results: []PersistedToolResult,
    source: PersistedToolArgumentsSource,
) !void {
    for (calls) |call| {
        if (call.argument_integrity != .valid) {
            _ = try persistedResultForMalformedCall(calls, results, call);
        }
    }

    for (calls) |*call| {
        if (call.argument_integrity == .valid) continue;
        const result = try persistedResultForMalformedCall(calls, results, call.*);
        const integrity = call.argument_integrity;
        if (integrity == .non_object_json) {
            // Repair replay input without changing what the stored result says happened.
            if (call.provider_result != null or result.provider_native) {
                call.provenance = .provider_executed;
                call.argument_integrity = .valid;
                continue;
            }
            const safe_arguments = try alloc.dupe(u8, "{}");
            alloc.free(call.arguments_json);
            call.arguments_json = safe_arguments;
            call.argument_integrity = .valid;
            tracePersistedToolArgumentsRepair(call.*, source, true, integrity);
            continue;
        }
        const failure_output = try tool_result_errors.malformedToolArgumentsJson(alloc, call.name, null);

        alloc.free(result.output);
        if (result.output_handle) |handle| alloc.free(handle);
        if (result.preview) |preview| alloc.free(preview);
        result.status = .failure;
        result.output = failure_output;
        result.output_handle = null;
        result.preview = null;
        result.output_bytes = failure_output.len;
        result.stored_output_bytes = failure_output.len;
        result.truncated = false;
        result.provider_native = false;
        call.argument_integrity = .valid;
        tracePersistedToolArgumentsRepair(call.*, source, true, integrity);
    }
}

pub fn repairPersistedInterruptedToolArguments(
    alloc: Allocator,
    call: *ToolCall,
    source: PersistedToolArgumentsSource,
) Allocator.Error!void {
    if (call.argument_integrity == .valid) return;
    const integrity = call.argument_integrity;
    if (integrity == .non_object_json) {
        if (call.provider_result != null) {
            call.provenance = .provider_executed;
            call.argument_integrity = .valid;
            return;
        }
        const safe_arguments = try alloc.dupe(u8, "{}");
        alloc.free(call.arguments_json);
        call.arguments_json = safe_arguments;
    }
    call.argument_integrity = .valid;
    tracePersistedToolArgumentsRepair(call.*, source, false, integrity);
}

fn persistedResultForMalformedCall(
    calls: []ToolCall,
    results: []PersistedToolResult,
    call: ToolCall,
) !*PersistedToolResult {
    var matching_calls: usize = 0;
    for (calls) |candidate| {
        if (std.mem.eql(u8, candidate.id, call.id)) matching_calls += 1;
    }
    if (matching_calls != 1) return error.InvalidSessionFormat;

    var matched_result: ?*PersistedToolResult = null;
    for (results) |*result| {
        if (!std.mem.eql(u8, result.tool_call_id, call.id)) continue;
        if (matched_result != null) return error.InvalidSessionFormat;
        matched_result = result;
    }

    const result = matched_result orelse return error.InvalidSessionFormat;
    if (!std.mem.eql(u8, result.tool_name, call.name)) return error.InvalidSessionFormat;
    return result;
}

fn tracePersistedToolArgumentsRepair(
    call: ToolCall,
    source: PersistedToolArgumentsSource,
    paired_result: bool,
    integrity: core_types.ToolArgumentIntegrity,
) void {
    debug_trace.eventf(
        "session",
        "persisted_tool_arguments_repaired",
        .{},
        "source={s} call_id={s} tool={s} failure={s} paired_result={s}",
        .{ @tagName(source), call.id, call.name, @tagName(integrity), if (paired_result) "true" else "false" },
    );
}

pub const WebFetchArtifactState = union(enum) {
    none,
    store: web_fetch_artifacts.Store,
    unavailable: anyerror,
};

const shell_id_key_raw = "\"session_id\":\"shell-";
const shell_id_key_escaped = "\\\"session_id\\\":\\\"shell-";

/// Collect every shell execution id referenced by restored history turns into
/// `out` (deduplicated; slices borrow from the turns, so history must outlive
/// the list). Matches both raw and JSON-escaped tool result envelopes.
fn collectReferencedShellIds(
    alloc: Allocator,
    history: []const HistoryTurn,
    out: *std.ArrayList([]const u8),
) !void {
    for (history) |turn| {
        switch (turn) {
            .assistant => |entry| {
                if (entry.provider_replay) |replay|
                    try collectShellIdsFromText(alloc, replay.parts_json, out);
                try collectShellIdsFromExecution(alloc, entry.execution, out);
            },
            .interrupted => |entry| {
                if (entry.tool_call) |call| {
                    try collectShellIdsFromText(alloc, call.arguments_json, out);
                    if (call.provider_result) |result|
                        try collectShellIdsFromText(alloc, result, out);
                }
                try collectShellIdsFromExecution(alloc, entry.execution, out);
            },
            .compacted_summary => {},
        }
    }
}

fn collectShellIdsFromExecution(
    alloc: Allocator,
    execution: core_types.ExecutionMemory,
    out: *std.ArrayList([]const u8),
) !void {
    for (execution.tool_steps) |step| {
        for (step.tool_calls) |call| {
            try collectShellIdsFromText(alloc, call.arguments_json, out);
            if (call.provider_result) |result|
                try collectShellIdsFromText(alloc, result, out);
        }
        for (step.tool_results) |result| {
            try collectShellIdsFromText(alloc, result.output, out);
            if (result.preview) |preview|
                try collectShellIdsFromText(alloc, preview, out);
        }
        if (step.provider_replay) |replay|
            try collectShellIdsFromText(alloc, replay.parts_json, out);
    }
}

/// True when restored history references shell execution handles that `exec`
/// does not own. Registry membership, not the resume event, decides staleness:
/// in-process resumes share the registry with executions started by this
/// process, so those handles stay valid and stay quiet.
/// What the first turn after such a resume tells the model, as a context
/// note at the start of that turn (D93): the instructions stay as they were
/// cached.
pub const stale_shell_handles_note =
    "Runtime context: spark restarted since this session was last active, so earlier shell session_id handles no longer exist; stopping or interacting with them fails with ExecutionNotFound. Their processes are normally terminated when spark exits but can survive an unclean exit, so check for a survivor before starting a duplicate. Otherwise start fresh shell sessions instead of reusing earlier handles.";

pub fn detectStaleShellHandles(
    alloc: Allocator,
    history: []const HistoryTurn,
    exec: *managed_execution.Runtime,
) !bool {
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(alloc);
    try collectReferencedShellIds(alloc, history, &ids);
    for (ids.items) |id| {
        if (exec.stateFor(id) == null) return true;
    }
    return false;
}

fn collectShellIdsFromText(alloc: Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    try collectShellIdsWithKey(alloc, text, shell_id_key_raw, out);
    try collectShellIdsWithKey(alloc, text, shell_id_key_escaped, out);
}

fn collectShellIdsWithKey(alloc: Allocator, text: []const u8, key: []const u8, out: *std.ArrayList([]const u8)) !void {
    var from: usize = 0;
    while (std.mem.find(u8, text[from..], key)) |rel| {
        const at = from + rel;
        from = at + key.len;
        const id_start = at + key.len - "shell-".len;
        var id_end = id_start + "shell-".len;
        // Counter ids are digits; interactive terminal ids are base64url. Both
        // share the charset checked by validHistoricalSessionId.
        while (id_end < text.len) : (id_end += 1) {
            const byte = text[id_end];
            if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') break;
        }
        if (id_end == id_start + "shell-".len) continue;
        const id = text[id_start..id_end];
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, id)) break;
        } else try out.append(alloc, id);
    }
}

pub const SessionRuntime = struct {
    agent: kernel_agent.Agent = .{},
    /// Keeps this conversation's Claude prompt cache warm while it waits;
    /// created by its first use. Every history rewrite disarms it, since
    /// the next request no longer starts with the armed one.
    cache_warmer: ?*cache_warmer.Warmer = null,
    context_notice_hashes: std.AutoHashMapUnmanaged(u64, void) = .empty,
    context_notice_lock: std.Io.Mutex = .init,
    web_fetch_artifacts: WebFetchArtifactState = .none,
    language_lock: std.Io.Mutex = .init,
    conversation_language: ConversationLanguage = ConversationLanguage.default(),
    /// Count limit for owned model-context snapshots; canonical history is not truncated.
    max_history_turns: usize,
    /// In-memory boundary for handle-free history loaded without writer
    /// provenance. It is never persisted; accepted checkpoints move the model
    /// window beyond it.
    unversioned_history_len: usize = 0,
    /// True when restored history references shell execution handles that this
    /// process does not own. Resume seams set it once after restore, before the
    /// first agent turn of the resumed session, so no lock is required. The
    /// next prompt takes it with `takeStaleShellHandles`.
    has_stale_shell_handles: bool = false,

    pub fn init(max_history_turns: usize) SessionRuntime {
        return .{ .max_history_turns = max_history_turns };
    }

    /// `init` in place, for a runtime too large to build on the stack.
    pub fn initInto(self: *SessionRuntime, max_history_turns: usize) void {
        const session_runtime_info = @typeInfo(SessionRuntime).@"struct";
        inline for (session_runtime_info.field_names, session_runtime_info.field_types, session_runtime_info.field_attrs) |field_name, field_type, field_attrs| {
            if (comptime std.mem.eql(u8, field_name, "max_history_turns")) continue;
            @field(self.*, field_name) = field_attrs.defaultValue(field_type).?;
        }
        self.max_history_turns = max_history_turns;
    }

    pub fn deinit(self: *SessionRuntime, alloc: Allocator) void {
        self.closeCacheWarmer();
        self.clearWebFetchArtifacts();
        self.agent.deinit(alloc);
        self.context_notice_hashes.deinit(alloc);
    }

    /// Whether the prompt being queued should tell the model that earlier shell
    /// handles are gone. True once per resume: the turn that carries the note
    /// keeps it in the conversation, so later turns need no copy.
    pub fn takeStaleShellHandles(self: *SessionRuntime) bool {
        defer self.has_stale_shell_handles = false;
        return self.has_stale_shell_handles;
    }

    /// Gives the stale shell handles note back when the prompt that took it
    /// is dropped before its turn runs: removed from the queue, or refused
    /// at admission. The next prompt carries it instead.
    pub fn returnStaleShellHandles(self: *SessionRuntime, turn_id: u64) void {
        self.has_stale_shell_handles = true;
        debug_trace.logf("session", "stale shell handles note returned from dropped prompt turn_id={d}", .{turn_id});
    }

    /// The conversation's cache warmer, created on first use. Null on
    /// WebAssembly, which has no threads, or when it cannot be created.
    pub fn cacheWarmer(self: *SessionRuntime) ?*cache_warmer.Warmer {
        if (self.cache_warmer == null) {
            self.cache_warmer = cache_warmer.Warmer.create() catch |err| {
                debug_trace.logf("cache_warming", "event=unavailable err={s}", .{@errorName(err)});
                return null;
            };
        }
        return self.cache_warmer;
    }

    /// Stops the warmer and its pings. The warmer is created again if the
    /// conversation is used after this.
    pub fn closeCacheWarmer(self: *SessionRuntime) void {
        const warmer = self.cache_warmer orelse return;
        self.cache_warmer = null;
        warmer.destroy();
    }

    fn disarmCacheWarming(self: *SessionRuntime, why: []const u8) void {
        if (self.cache_warmer) |warmer| warmer.disarm(why);
    }

    pub fn reset(self: *SessionRuntime, alloc: Allocator) void {
        self.clearWebFetchArtifacts();
        self.clearHistory(alloc);
        self.clearContextNotices();
        self.setConversationLanguage(ConversationLanguage.default());
        self.has_stale_shell_handles = false;
    }

    pub fn restore(self: *SessionRuntime, alloc: Allocator, language: ConversationLanguage, history: []const HistoryTurn) !void {
        self.clearWebFetchArtifacts();
        self.clearHistory(alloc);
        self.clearContextNotices();
        self.setConversationLanguage(language);
        self.has_stale_shell_handles = false;

        for (history) |turn| {
            try self.appendHistoryEntry(alloc, turn);
        }
        self.unversioned_history_len = if (self.agent.history.items.len > 0 and
            isCurrentCompactionCheckpoint(self.agent.history.items[0]))
            0
        else
            self.agent.history.items.len;
    }

    /// Keeps a v2 session's web-fetch downloads as its blobs (D44, D49), or
    /// records why they can't be kept.
    pub fn configureWebFetchArtifactBlobs(
        self: *SessionRuntime,
        alloc: Allocator,
        capability: *const session_child_store.SessionChildCapability,
        session_id: []const u8,
    ) void {
        self.clearWebFetchArtifacts();
        const store = web_fetch_artifacts.Store.initBlobs(alloc, capability, session_id) catch |err| {
            self.web_fetch_artifacts = .{ .unavailable = err };
            return;
        };
        self.web_fetch_artifacts = .{ .store = store };
    }

    pub fn clearWebFetchArtifacts(self: *SessionRuntime) void {
        switch (self.web_fetch_artifacts) {
            .store => |*store| store.deinit(),
            .none, .unavailable => {},
        }
        self.web_fetch_artifacts = .none;
    }

    /// Returns true once for each distinct source-limit notice in this live
    /// session. Size and limit are part of the rendered notice, so either
    /// changing makes the updated condition visible again.
    pub fn claimContextNotice(self: *SessionRuntime, alloc: Allocator, notice: []const u8) !bool {
        self.context_notice_lock.lockUncancelable(io_mod.getIo());
        defer self.context_notice_lock.unlock(io_mod.getIo());
        const result = try self.context_notice_hashes.getOrPut(
            alloc,
            std.hash.Wyhash.hash(0, notice),
        );
        return !result.found_existing;
    }

    pub fn clearContextNotices(self: *SessionRuntime) void {
        self.context_notice_lock.lockUncancelable(io_mod.getIo());
        defer self.context_notice_lock.unlock(io_mod.getIo());
        self.context_notice_hashes.clearRetainingCapacity();
    }

    pub fn webFetchArtifactStore(self: *SessionRuntime) ?*web_fetch_artifacts.Store {
        return switch (self.web_fetch_artifacts) {
            .store => |*store| store,
            .none, .unavailable => null,
        };
    }

    pub fn webFetchArtifactError(self: *SessionRuntime) ?anyerror {
        return switch (self.web_fetch_artifacts) {
            .unavailable => |err| err,
            .none, .store => null,
        };
    }

    pub fn clearHistory(self: *SessionRuntime, alloc: Allocator) void {
        self.disarmCacheWarming("history_cleared");
        self.agent.clearHistory(alloc);
        self.unversioned_history_len = 0;
    }

    pub fn historyLen(self: *const SessionRuntime) usize {
        return self.agent.history.items.len;
    }

    pub fn unversionedHistoryEnd(self: *const SessionRuntime) usize {
        return @min(self.unversioned_history_len, self.agent.history.items.len);
    }

    pub fn hasContextToCompact(self: *const SessionRuntime) bool {
        for (self.agent.history.items) |turn| {
            if (turn != .compacted_summary) return true;
        }
        return false;
    }

    pub fn compactedTurnCount(self: *const SessionRuntime) usize {
        if (self.agent.history.items.len == 0) return 0;
        return switch (self.agent.history.items[0]) {
            .compacted_summary => |entry| entry.removed_turn_count,
            else => 0,
        };
    }

    pub fn compactionCount(self: *const SessionRuntime) usize {
        if (self.agent.history.items.len == 0) return 0;
        return switch (self.agent.history.items[0]) {
            .compacted_summary => |entry| entry.compaction_count,
            else => 0,
        };
    }

    pub fn snapshotHistory(self: *const SessionRuntime, alloc: Allocator) ![]HistoryTurn {
        return self.agent.snapshotHistory(alloc);
    }

    pub fn snapshotImageCatalog(
        self: *const SessionRuntime,
        alloc: Allocator,
        current_images: []const ImageAttachment,
    ) ![]ImageAttachment {
        return collect_image_catalog(alloc, self.agent.history.items, current_images);
    }

    pub fn snapshotContextHistory(self: *const SessionRuntime, alloc: Allocator) ![]HistoryTurn {
        return snapshotOwnedContextHistory(
            alloc,
            self.agent.history.items,
            0,
            self.max_history_turns,
        );
    }

    pub fn appendHistoryEntry(self: *SessionRuntime, alloc: Allocator, turn: HistoryTurn) !void {
        const prepared = try self.prepareHistoryEntry(alloc, turn);
        self.commitPreparedHistoryEntry(alloc, prepared);
    }

    pub fn prepareHistoryEntry(
        self: *SessionRuntime,
        alloc: Allocator,
        turn: HistoryTurn,
    ) !HistoryTurn {
        try self.agent.history.ensureUnusedCapacity(alloc, 1);
        return dupeHistoryTurn(alloc, turn);
    }

    pub fn commitPreparedHistoryEntry(
        self: *SessionRuntime,
        alloc: Allocator,
        turn: HistoryTurn,
    ) void {
        if (isCurrentCompactionCheckpoint(turn)) {
            self.disarmCacheWarming("history_compacted");
            // The conversation goes on after compacting: it keeps its toolbox
            // menu (`tests/tla/toolbox/Toolbox.tla` MenuFixed).
            self.agent.dropHistory(alloc);
            self.unversioned_history_len = 0;
        }
        self.agent.history.appendAssumeCapacity(turn);
        self.agent.fresh = false;
        if (turn == .compacted_summary and isCurrentCompactionCheckpoint(turn)) {
            self.unversioned_history_len = 0;
        }
    }

    /// Takes ownership of a fully prepared replacement only after durable commit.
    pub fn commitCompactedHistory(self: *SessionRuntime, alloc: Allocator, history: []HistoryTurn) void {
        const uncertain = self.unversioned_history_len != 0;
        self.disarmCacheWarming("history_compacted");
        self.agent.dropHistory(alloc);
        self.agent.history.deinit(alloc);
        self.agent.history = std.ArrayList(HistoryTurn).fromOwnedSlice(history);
        self.agent.fresh = false;
        self.unversioned_history_len = if (uncertain) history.len else 0;
    }

    pub fn appendAssistantHistoryTurn(self: *SessionRuntime, alloc: Allocator, user: []const u8, assistant: []const u8) !void {
        const turn = try makeAssistantTurn(alloc, user, assistant);
        var owns_turn = true;
        errdefer if (owns_turn) freeHistoryTurn(alloc, turn);

        try self.agent.history.append(alloc, turn);
        owns_turn = false;
    }

    pub fn appendHistoryMessages(
        alloc: Allocator,
        messages: *std.ArrayList(message.Message),
        history: []const HistoryTurn,
    ) !void {
        try appendHistoryMessagesImpl(alloc, messages, history);
    }

    pub fn appendHistoryChatMessages(
        alloc: Allocator,
        messages: *std.ArrayList(core_types.ChatMessage),
        history: []const HistoryTurn,
    ) !void {
        try appendHistoryChatMessagesImpl(alloc, messages, history, .closed);
    }

    pub fn setConversationLanguageFromUserMessage(self: *SessionRuntime, text: []const u8) void {
        const fallback = self.languageSnapshot();
        self.setConversationLanguage(inferConversationLanguage(text, fallback));
    }

    pub fn languageSnapshot(self: *const SessionRuntime) ConversationLanguage {
        const mutable: *SessionRuntime = @constCast(self);
        mutable.language_lock.lockUncancelable(io_mod.getIo());
        defer mutable.language_lock.unlock(io_mod.getIo());
        return mutable.conversation_language;
    }

    pub fn lastAssistantReply(self: *const SessionRuntime) ?[]const u8 {
        var i = self.agent.history.items.len;
        while (i > 0) {
            i -= 1;
            switch (self.agent.history.items[i]) {
                .assistant => |entry| {
                    if (entry.assistant.len > 0) return entry.assistant;
                },
                else => {},
            }
        }
        return null;
    }

    pub fn lastSummary(self: *const SessionRuntime) ?[]const u8 {
        var index = self.agent.history.items.len;
        while (index > 0) {
            index -= 1;
            if (self.agent.history.items[index] == .compacted_summary) {
                return self.agent.history.items[index].compacted_summary.summary;
            }
        }
        return null;
    }
    fn setConversationLanguage(self: *SessionRuntime, language: ConversationLanguage) void {
        self.language_lock.lockUncancelable(io_mod.getIo());
        defer self.language_lock.unlock(io_mod.getIo());
        self.conversation_language = language;
    }
};

fn appendHistoryCopies(
    alloc: Allocator,
    destination: *std.ArrayList(HistoryTurn),
    history: []const HistoryTurn,
) !void {
    try destination.ensureUnusedCapacity(alloc, history.len);
    for (history) |turn| {
        const copy = try dupeHistoryTurn(alloc, turn);
        destination.appendAssumeCapacity(copy);
    }
}

/// Builds an independently owned prompt-history snapshot from canonical history.
pub fn snapshotOwnedContextHistory(
    alloc: Allocator,
    canonical_history: []const HistoryTurn,
    _: usize,
    _: usize,
) ![]HistoryTurn {
    var copy: std.ArrayList(HistoryTurn) = .empty;
    errdefer {
        for (copy.items) |turn| freeHistoryTurn(alloc, turn);
        copy.deinit(alloc);
    }
    try appendHistoryCopies(alloc, &copy, canonical_history);
    return copy.toOwnedSlice(alloc);
}

pub fn prepareCompactedHistory(
    alloc: Allocator,
    history: []const HistoryTurn,
    summary: CompactedSummaryHistoryTurn,
    cut: core_types.ContextHistoryCut,
) ![]HistoryTurn {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const retained = try history_range.contextHistoryRange(arena_state.allocator(), history, cut, null);
    var next: std.ArrayList(HistoryTurn) = .empty;
    errdefer {
        for (next.items) |turn| freeHistoryTurn(alloc, turn);
        next.deinit(alloc);
    }
    try next.ensureTotalCapacity(alloc, retained.len + 1);
    next.appendAssumeCapacity(try dupeHistoryTurn(alloc, .{ .compacted_summary = summary }));
    for (retained) |turn| next.appendAssumeCapacity(try dupeHistoryTurn(alloc, turn));
    return next.toOwnedSlice(alloc);
}

/// Frees an owned image attachment slice and each attachment field.
pub fn freeImageAttachmentSlice(alloc: Allocator, attachments: []ImageAttachment) void {
    for (attachments) |attachment| {
        core_types.freeImageAttachment(alloc, attachment);
    }
    if (attachments.len > 0) alloc.free(attachments);
}
/// Frees an owned history slice; callers pass slices returned by session helpers.
pub fn freeHistoryTurnSlice(alloc: Allocator, turns: []HistoryTurn) void {
    for (turns) |turn| freeHistoryTurn(alloc, turn);
    if (turns.len > 0) alloc.free(turns);
}
/// Deep-copies an image attachment slice; caller owns the returned slice and frees with freeImageAttachmentSlice.
pub const dupeImageAttachmentSlice = core_types.dupeImageAttachmentSlice;
/// Deep-copies one history turn; caller owns the returned turn and frees with freeHistoryTurn.
pub const dupeHistoryTurn = core_types.dupeHistoryTurn;
pub fn appendAssistantTurnWithExecution(
    alloc: Allocator,
    current: []HistoryTurn,
    user_text: []const u8,
    assistant_text: []const u8,
    execution: *core_types.ExecutionMemory,
) ![]HistoryTurn {
    const user_copy = try alloc.dupe(u8, user_text);
    errdefer alloc.free(user_copy);
    const assistant_copy = try alloc.dupe(u8, assistant_text);
    errdefer alloc.free(assistant_copy);
    const next = try alloc.alloc(HistoryTurn, current.len + 1);
    errdefer alloc.free(next);

    @memmove(next[0..current.len], current);
    next[current.len] = .{ .assistant = .{
        .user = .{ .text = user_copy, .images = &.{} },
        .assistant = assistant_copy,
        .execution = execution.*,
    } };
    execution.* = .{};
    if (current.len > 0) alloc.free(current);
    return next;
}

/// Appends a finished turn to an owned prompt-context projection and reapplies its turn limit.
/// Builds one owned assistant history turn; caller frees with freeHistoryTurn.
pub fn makeAssistantTurn(alloc: Allocator, user_text: []const u8, assistant_text: []const u8) !HistoryTurn {
    const user_copy = try alloc.dupe(u8, user_text);
    errdefer alloc.free(user_copy);
    const assistant_copy = try alloc.dupe(u8, assistant_text);
    errdefer alloc.free(assistant_copy);
    return .{ .assistant = .{
        .user = .{ .text = user_copy, .images = &.{} },
        .assistant = assistant_copy,
    } };
}

/// Projects stored history into request messages while preserving stored turn order.
pub fn appendHistoryMessages(
    alloc: Allocator,
    messages: *std.ArrayList(message.Message),
    history: []const HistoryTurn,
) !void {
    try appendHistoryMessagesImpl(alloc, messages, history);
}

pub fn appendHistoryChatMessages(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
) (Allocator.Error || error{InvalidReplayHandle})!void {
    try appendHistoryChatMessagesImpl(alloc, messages, history, .closed);
}

fn isCurrentCompactionCheckpoint(turn: HistoryTurn) bool {
    return switch (turn) {
        .compacted_summary => |entry| compactor.replacesPriorContext(entry.summary),
        else => false,
    };
}

/// Projects the active model window from one complete canonical snapshot.
/// New checkpoints may retain raw turns immediately before the appended
/// checkpoint; those turns are emitted after the checkpoint without
/// duplicating them in canonical storage.
pub fn appendActiveContextHistoryChatMessages(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
    context_history_start: usize,
) !void {
    return appendActiveContextHistoryChatMessagesWithTrailingProjection(
        alloc,
        messages,
        history,
        context_history_start,
        .closed,
    );
}

pub fn appendSteeringActiveContextHistoryChatMessages(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
    context_history_start: usize,
) !void {
    return appendActiveContextHistoryChatMessagesWithTrailingProjection(
        alloc,
        messages,
        history,
        context_history_start,
        .steering_continuation,
    );
}

fn appendActiveContextHistoryChatMessagesWithTrailingProjection(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
    context_history_start: usize,
    interrupted_projection: InterruptedChatProjection,
) !void {
    if (context_history_start > history.len) {
        return error.InvalidContextHistoryStart;
    }
    if (context_history_start == 0) {
        return appendHistoryChatMessagesWithTrailingProjection(
            alloc,
            messages,
            history,
            interrupted_projection,
        );
    }
    if (context_history_start == history.len or
        history[context_history_start] != .compacted_summary)
    {
        return error.InvalidContextHistoryStart;
    }
    const checkpoint = history[context_history_start].compacted_summary;
    var raw_before: usize = 0;
    for (history[0..context_history_start]) |turn| {
        if (turn != .compacted_summary) raw_before += 1;
    }
    if (checkpoint.removed_turn_count > raw_before) {
        return error.InvalidContextHistoryStart;
    }
    const retained_count = raw_before - checkpoint.removed_turn_count;
    try appendHistoryChatMessagesImpl(
        alloc,
        messages,
        history[context_history_start .. context_history_start + 1],
        .closed,
    );
    if (retained_count > 0) {
        var retained_start = context_history_start;
        var remaining = retained_count;
        while (retained_start > 0 and remaining > 0) {
            retained_start -= 1;
            if (history[retained_start] != .compacted_summary) remaining -= 1;
        }
        if (remaining != 0) return error.InvalidContextHistoryStart;
        for (history[retained_start..context_history_start], retained_start..) |turn, index| {
            if (turn == .compacted_summary) continue;
            try appendHistoryRangeChatMessages(alloc, messages, history, index, index + 1, .closed);
        }
    }
    if (context_history_start + 1 < history.len) {
        try appendHistoryRangeChatMessages(
            alloc,
            messages,
            history,
            context_history_start + 1,
            history.len,
            interrupted_projection,
        );
    }
}

const InterruptedChatProjection = enum {
    closed,
    steering_continuation,
};

fn appendHistoryChatMessagesWithTrailingProjection(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
    trailing_interrupted_projection: InterruptedChatProjection,
) !void {
    if (history.len == 0 or trailing_interrupted_projection == .closed) {
        try appendHistoryChatMessagesImpl(alloc, messages, history, .closed);
        return;
    }

    try appendHistoryRangeChatMessages(alloc, messages, history, 0, history.len - 1, .closed);
    try appendHistoryRangeChatMessages(alloc, messages, history, history.len - 1, history.len, trailing_interrupted_projection);
}

fn appendHistoryMessagesImpl(
    alloc: Allocator,
    messages: *std.ArrayList(message.Message),
    history: []const HistoryTurn,
) !void {
    for (history) |turn| {
        switch (turn) {
            .compacted_summary => |entry| {
                const text = try formatCompactedContinuationMessage(alloc, entry.summary);
                errdefer alloc.free(text);
                try messages.append(alloc, message.Message.userOwned(text));
            },
            .assistant => |entry| {
                try messages.append(alloc, .{
                    .role = .user,
                    .content = .{ .text = entry.user.text },
                    .images = entry.user.images,
                });
                try appendExecutionMemoryMessages(alloc, messages, entry.execution);
                if (entry.assistant.len > 0) {
                    try messages.append(alloc, message.Message.assistantBorrowed(entry.assistant, &.{}));
                }
            },
            .interrupted => |entry| {
                try messages.append(alloc, .{
                    .role = .user,
                    .content = .{ .text = entry.user.text },
                    .images = entry.user.images,
                });
                try appendExecutionMemoryMessages(alloc, messages, entry.execution);
                if (entry.tool_call) |tool_call| {
                    const assistant_content = try formatInterruptedAssistantToolContent(alloc, entry);
                    var owns_assistant_content = assistant_content != null;
                    errdefer if (owns_assistant_content) {
                        if (assistant_content) |text| alloc.free(text);
                    };
                    const calls = try alloc.alloc(core_types.ToolCall, 1);
                    var owns_calls = true;
                    var calls_initialized = false;
                    errdefer if (owns_calls) {
                        if (calls_initialized) core_types.freeToolCall(alloc, calls[0]);
                        alloc.free(calls);
                    };
                    calls[0] = try core_types.dupeToolCall(alloc, tool_call);
                    calls_initialized = true;
                    try messages.append(alloc, .{
                        .role = .assistant,
                        .content = if (assistant_content) |text| .{ .text = text } else null,
                        .tool_calls = calls,
                        .owns_content = assistant_content != null,
                        .owns_tool_calls = true,
                    });
                    owns_assistant_content = false;
                    owns_calls = false;
                    const tool_output = try formatInterruptedToolOutput(alloc, entry);
                    var owns_tool_output = true;
                    errdefer if (owns_tool_output) alloc.free(tool_output);
                    try messages.append(alloc, .{
                        .role = .tool,
                        .content = .{ .text = tool_output },
                        .tool_call_id = tool_call.id,
                        .tool_name = tool_call.name,
                        .tool_result_status = .failure,
                        .owns_content = true,
                    });
                    owns_tool_output = false;
                } else {
                    const assistant_content = try formatInterruptedAssistantClosedContent(alloc, entry);
                    var owns_assistant_content = true;
                    errdefer if (owns_assistant_content) alloc.free(assistant_content);
                    try messages.append(alloc, message.Message.assistantOwned(assistant_content, &.{}));
                    owns_assistant_content = false;
                }
                const text = try formatInterruptedHistoryContext(alloc, entry);
                errdefer alloc.free(text);
                try messages.append(alloc, message.Message.userOwned(text));
            },
        }
    }
}

fn appendExecutionMemoryMessages(
    alloc: Allocator,
    messages: *std.ArrayList(message.Message),
    execution: core_types.ExecutionMemory,
) !void {
    var steering_index: usize = 0;
    for (execution.tool_steps, 0..) |step, step_index| {
        while (steering_index < execution.steering.len and
            execution.steering[steering_index].after_tool_step_count == step_index)
        {
            const steering = execution.steering[steering_index];
            if (steering.assistant_prefix) |prefix| {
                if (prefix.len > 0) {
                    try messages.append(alloc, message.Message.assistantBorrowed(prefix, &.{}));
                }
            }
            if (steering.text.len > 0) {
                try messages.append(alloc, message.Message.userText(steering.text));
            }
            steering_index += 1;
        }
        if (step.tool_calls.len == 0) continue;
        try messages.append(alloc, .{
            .role = .assistant,
            .content = if (step.assistant) |text| .{ .text = text } else null,
            .tool_calls = step.tool_calls,
        });
        for (step.tool_results) |result| {
            try messages.append(alloc, .{
                .role = .tool,
                .content = .{ .text = result.output },
                .tool_call_id = result.tool_call_id,
                .tool_name = result.tool_name,
                .tool_result_status = result.status,
            });
        }
        for (step.tool_results) |result| {
            for (result.permission_feedback) |feedback| {
                try messages.append(alloc, message.Message.userText(feedback));
            }
        }
    }
    while (steering_index < execution.steering.len) : (steering_index += 1) {
        const steering = execution.steering[steering_index];
        if (steering.assistant_prefix) |prefix| {
            if (prefix.len > 0) {
                try messages.append(alloc, message.Message.assistantBorrowed(prefix, &.{}));
            }
        }
        if (steering.text.len == 0) continue;
        try messages.append(alloc, message.Message.userText(steering.text));
    }
}

pub fn appendExecutionMemoryChatMessages(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    execution: core_types.ExecutionMemory,
) !void {
    var steering_index: usize = 0;
    var note_index: usize = 0;
    for (execution.tool_steps, 0..) |step, step_index| {
        try appendContextNoteChatMessages(alloc, messages, execution.context_notes, &note_index, step_index);
        while (steering_index < execution.steering.len and
            execution.steering[steering_index].after_tool_step_count == step_index)
        {
            const steering = execution.steering[steering_index];
            if (steering.assistant_prefix) |prefix| {
                if (prefix.len > 0) {
                    try messages.append(alloc, .{ .role = .assistant, .content = prefix });
                }
            }
            try messages.append(alloc, restoredSteeringChatMessage(steering.text));
            steering_index += 1;
        }
        if (step.tool_calls.len == 0 and step.provider_replay == null and step.assistant == null) continue;
        try messages.append(alloc, .{
            .role = .assistant,
            .content = step.assistant,
            .tool_calls = step.tool_calls,
            .provider_replay = step.provider_replay,
            .standalone_response = step.tool_calls.len == 0,
        });
        for (step.tool_results) |result| {
            try messages.append(alloc, .{
                .role = .tool,
                .content = result.output,
                .tool_call_id = result.tool_call_id,
                .tool_name = result.tool_name,
                .tool_result_status = result.status,
                .tool_result_memory = toolResultMemory(result),
                // A turn resumed from its checkpoint keeps each result's time.
                .tool_result_created_at_ms = if (result.created_at_ms > 0) result.created_at_ms else null,
            });
        }
        for (step.tool_results) |result| {
            for (result.permission_feedback) |feedback| {
                try messages.append(alloc, .{
                    .role = .user,
                    .content = feedback,
                    .permission_feedback = true,
                });
            }
        }
    }
    // Notes after the last step follow its results, as the turn sent them.
    // Nothing the turn never sent joins it here: a model that checks earlier
    // reasoning rejects a reply whose preceding messages changed.
    try appendContextNoteChatMessages(alloc, messages, execution.context_notes, &note_index, null);
    while (steering_index < execution.steering.len) : (steering_index += 1) {
        const steering = execution.steering[steering_index];
        if (steering.assistant_prefix) |prefix| {
            if (prefix.len > 0) {
                try messages.append(alloc, .{ .role = .assistant, .content = prefix });
            }
        }
        try messages.append(alloc, restoredSteeringChatMessage(steering.text));
    }
}

/// Appends, as flagged system messages, the notes saved after `step_index`
/// steps, or every remaining note when null (D93). Borrows their text.
fn appendContextNoteChatMessages(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    notes: []const core_types.PersistedContextNote,
    index: *usize,
    step_index: ?usize,
) !void {
    while (index.* < notes.len) : (index.* += 1) {
        const note = notes[index.*];
        if (step_index) |count| if (note.after_tool_step_count != count) break;
        try messages.append(alloc, .{ .role = .system, .content = note.text, .context_note = true, .context_note_sources = note.sources });
    }
}

/// Steering comes from whoever drives this session, so compaction keeps it as
/// user text rather than a generated notice. A subagent's report or message
/// a boundary took is not the user's, so it stays ordinary text in its own
/// frame. spark's own prompt to a stalled turn is steering the user never typed:
/// it comes back as the plain user text the turn sent, never as the user's
/// words. Empty entries only mark a checkpoint boundary. Borrows `text`.
fn restoredSteeringChatMessage(text: []const u8) core_types.ChatMessage {
    if (recovery_prompt.fromSaved(text)) |prompt| {
        return .{ .role = .user, .content = prompt, .recovery_prompt = true };
    }
    return .{
        .role = .user,
        .content = text,
        .restored_steering = true,
        .context_origin = if (text.len > 0 and !agent_frame.isFrame(text)) .user_turn else .ordinary,
    };
}

fn toolResultMemory(result: core_types.PersistedToolResult) core_types.ToolResultMemory {
    return .{
        .review_feedback = result.review_feedback,
        .tool_images = result.tool_images,
        .tool_image_handle = result.tool_image_handle,
        .output_handle = result.output_handle,
        .preview = result.preview,
        .output_bytes = result.output_bytes,
        .stored_output_bytes = result.stored_output_bytes,
        .truncated = result.truncated,
        .committed_file_presentation = result.committed_file_presentation,
        .command_output_replay = result.command_output_replay,
        .command_process_presentation = result.command_process_presentation,
        .terminal_action_presentation = result.terminal_action_presentation,
    };
}

fn appendHistoryChatMessagesImpl(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
    interrupted_projection: InterruptedChatProjection,
) !void {
    return appendHistoryRangeChatMessages(alloc, messages, history, 0, history.len, interrupted_projection);
}

/// Projects `history[start..end]`, reading the turns around it so every
/// request after a resume sees the conversation as the resume request did:
/// the stopped turn without its abort note, the resume with the note that
/// fits what ran, and no resume a later one replaced.
fn appendHistoryRangeChatMessages(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
    start: usize,
    end: usize,
    trailing_projection: InterruptedChatProjection,
) !void {
    for (history[start..end], start..) |turn, index| {
        if (isSupersededResume(history, index)) continue;
        const interrupted_projection: InterruptedChatProjection = if (isResumedLater(history, index))
            .steering_continuation
        else
            trailing_projection;
        const resume_note: ?[]const u8 = if (isResumeTurn(turn))
            resumedRequestNote(withoutSupersededResumes(history[0..index]))
        else
            null;
        switch (turn) {
            .compacted_summary => |entry| {
                const text = try formatCompactedContinuationMessage(alloc, entry.summary);
                errdefer alloc.free(text);
                try messages.append(alloc, .{
                    .role = .user,
                    .content = text,
                    .context_origin = .handoff,
                });
            },
            .assistant => |entry| {
                try messages.append(alloc, .{ .role = .user, .content = resume_note orelse entry.user.text, .images = entry.user.images, .context_origin = .user_turn });
                try appendExecutionMemoryChatMessages(alloc, messages, entry.execution);
                if (entry.assistant.len > 0 or entry.provider_replay != null) {
                    try messages.append(alloc, .{ .role = .assistant, .content = entry.assistant, .provider_replay = entry.provider_replay });
                }
            },
            .interrupted => |entry| {
                try messages.append(alloc, .{ .role = .user, .content = resume_note orelse entry.user.text, .images = entry.user.images, .context_origin = .user_turn });
                try appendExecutionMemoryChatMessages(alloc, messages, entry.execution);
                if (entry.tool_call) |tool_call| {
                    const assistant_content = try formatInterruptedAssistantToolContent(alloc, entry);
                    const calls = try alloc.alloc(core_types.ToolCall, 1);
                    calls[0] = try core_types.dupeToolCall(alloc, tool_call);
                    try messages.append(alloc, .{ .role = .assistant, .content = assistant_content, .tool_calls = calls });
                    const tool_output = try formatInterruptedToolOutput(alloc, entry);
                    try messages.append(alloc, .{
                        .role = .tool,
                        .content = tool_output,
                        .tool_call_id = tool_call.id,
                        .tool_name = tool_call.name,
                        .tool_result_status = .failure,
                        .tool_result_memory = .{
                            .output_bytes = tool_output.len,
                            .stored_output_bytes = tool_output.len,
                            .truncated = false,
                        },
                    });
                } else if (interrupted_projection == .steering_continuation) {
                    if (entry.assistant) |assistant| {
                        if (assistant.len > 0) {
                            try messages.append(alloc, .{ .role = .assistant, .content = assistant });
                        }
                    }
                } else {
                    const assistant_content = try formatInterruptedAssistantClosedContent(alloc, entry);
                    try messages.append(alloc, .{ .role = .assistant, .content = assistant_content });
                }
                if (interrupted_projection == .steering_continuation) continue;
                const text = try formatInterruptedHistoryContext(alloc, entry);
                errdefer alloc.free(text);
                try messages.append(alloc, .{ .role = .user, .content = text });
            },
        }
    }
}
/// Infers a conversation language tag from text using core's script-counting heuristic.
pub fn inferConversationLanguage(text: []const u8, fallback: ConversationLanguage) ConversationLanguage {
    const script = language_script.profile(text).script orelse return fallback;
    return switch (script) {
        .japanese => ConversationLanguage.literal("ja"),
        .hangul => ConversationLanguage.literal("ko"),
        .han => ConversationLanguage.literal("und-Hani"),
        .arabic => ConversationLanguage.literal("und-Arab"),
        .hebrew => ConversationLanguage.literal("und-Hebr"),
        .cyrillic => ConversationLanguage.literal("und-Cyrl"),
        .greek => ConversationLanguage.literal("und-Grek"),
        .devanagari => ConversationLanguage.literal("und-Deva"),
        .thai => ConversationLanguage.literal("und-Thai"),
        .latin => ConversationLanguage.literal("und-Latn"),
    };
}

pub fn formatCompactedContinuationMessage(alloc: Allocator, summary: []const u8) ![]u8 {
    if (try compactor.modelText(alloc, summary)) |text| return text;
    return alloc.print(
        "{s}{s}\n\n{s}\n{s}",
        .{ compact_continuation_preamble, summary, compact_recent_messages_note, compact_direct_resume_instruction },
    );
}

pub fn formatInterruptedHistoryContext(alloc: Allocator, entry: InterruptedHistoryTurn) ![]u8 {
    _ = entry;
    return alloc.dupe(u8, interrupted_turn_context);
}

pub fn formatCompletedToolSummary(alloc: Allocator, names: []const []u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    out.writer.print(
        "Interrupted by user after completing {d} tool call{s}: ",
        .{ names.len, if (names.len == 1) "" else "s" },
    ) catch return error.OutOfMemory;
    for (names, 0..) |name, i| {
        if (i > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.writeAll(name) catch return error.OutOfMemory;
    }
    out.writer.writeByte('.') catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn formatInterruptedAssistantToolContent(alloc: Allocator, entry: InterruptedHistoryTurn) Allocator.Error!?[]u8 {
    const assistant = entry.assistant;
    const has_assistant = assistant != null and assistant.?.len > 0;
    const has_completed_tools = entry.completed_tool_names.len > 0;
    if (!has_assistant and !has_completed_tools) return null;

    if (!has_completed_tools) return @as(?[]u8, try alloc.dupe(u8, assistant.?));

    const summary = try formatCompletedToolSummary(alloc, entry.completed_tool_names);
    var owns_summary = true;
    errdefer if (owns_summary) alloc.free(summary);
    if (!has_assistant) return @as(?[]u8, summary);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.print("{s}\n\n{s}", .{ assistant.?, summary }) catch return error.OutOfMemory;
    alloc.free(summary);
    owns_summary = false;
    return @as(?[]u8, out.toOwnedSlice() catch return error.OutOfMemory);
}

fn formatInterruptedAssistantClosedContent(alloc: Allocator, entry: InterruptedHistoryTurn) Allocator.Error![]u8 {
    if (entry.completed_tool_names.len > 0) {
        if (try formatInterruptedAssistantToolContent(alloc, entry)) |text| return text;
    }
    if (entry.assistant) |assistant| {
        if (assistant.len > 0) return formatInterruptedPartialAssistantClosedContent(alloc, assistant);
    }
    return alloc.dupe(u8, interrupted_before_completion_output);
}

fn formatInterruptedPartialAssistantClosedContent(alloc: Allocator, assistant: []const u8) Allocator.Error![]u8 {
    return alloc.print("{s}\n\n{s}", .{ assistant, interrupted_before_completion_output });
}

fn expectCanonicalHistoryFixtureUnchanged(
    canonical: []const HistoryTurn,
    context_history_start: usize,
) !void {
    try std.testing.expectEqual(@as(usize, 1), context_history_start);
    try std.testing.expectEqual(@as(usize, 3), canonical.len);
    try std.testing.expectEqualStrings(
        "canonical prefix",
        canonical[0].assistant.user.text,
    );
    try std.testing.expectEqualStrings(
        "prefix assistant",
        canonical[0].assistant.assistant,
    );
    try std.testing.expectEqual(@as(usize, 1), canonical[0].assistant.user.images.len);
    try std.testing.expectEqual(@as(usize, 1), canonical[0].assistant.user.images[0].id);
    try std.testing.expectEqualStrings(
        "/tmp/prefix.png",
        canonical[0].assistant.user.images[0].path,
    );
    try std.testing.expectEqualStrings(
        "image/png",
        canonical[0].assistant.user.images[0].media_type,
    );
    try std.testing.expectEqualStrings(
        "canonical background",
        canonical[1].assistant.user.text,
    );
    try std.testing.expectEqualStrings(
        "background assistant",
        canonical[1].assistant.assistant,
    );
    try std.testing.expectEqual(@as(usize, 1), canonical[1].assistant.execution.tool_steps.len);
    try std.testing.expectEqualStrings(
        "checking preserved evidence",
        canonical[1].assistant.execution.tool_steps[0].assistant.?,
    );
    try std.testing.expectEqual(@as(usize, 1), canonical[1].assistant.execution.tool_steps[0].tool_calls.len);
    try std.testing.expectEqualStrings(
        "call_preserved",
        canonical[1].assistant.execution.tool_steps[0].tool_calls[0].id,
    );
    try std.testing.expectEqualStrings(
        "read_file",
        canonical[1].assistant.execution.tool_steps[0].tool_calls[0].name,
    );
    try std.testing.expectEqualStrings(
        "{\"path\":\"fixture.txt\"}",
        canonical[1].assistant.execution.tool_steps[0].tool_calls[0].arguments_json,
    );
    try std.testing.expectEqual(@as(usize, 1), canonical[1].assistant.execution.tool_steps[0].tool_results.len);
    try std.testing.expectEqual(
        PersistedToolStatus.failure,
        canonical[1].assistant.execution.tool_steps[0].tool_results[0].status,
    );
    try std.testing.expectEqualStrings(
        "preserved failure",
        canonical[1].assistant.execution.tool_steps[0].tool_results[0].output,
    );
    try std.testing.expectEqualStrings(
        "result-call_preserved.txt",
        canonical[1].assistant.execution.tool_steps[0].tool_results[0].output_handle.?,
    );
    try std.testing.expectEqualStrings(
        "preserved preview",
        canonical[1].assistant.execution.tool_steps[0].tool_results[0].preview.?,
    );
    try std.testing.expectEqual(@as(usize, 17), canonical[1].assistant.execution.tool_steps[0].tool_results[0].output_bytes);
    try std.testing.expectEqual(@as(usize, 17), canonical[1].assistant.execution.tool_steps[0].tool_results[0].stored_output_bytes);
    try std.testing.expectEqual(@as(usize, 1), canonical[1].assistant.execution.files.len);
    try std.testing.expectEqualStrings(
        "src/preserved.zig",
        canonical[1].assistant.execution.files[0].path,
    );
    try std.testing.expectEqualStrings(
        "src/preserved-renamed.zig",
        canonical[1].assistant.execution.files[0].new_path.?,
    );
    try std.testing.expectEqualStrings(
        "call_preserved",
        canonical[1].assistant.execution.files[0].tool_call_id,
    );
    try std.testing.expectEqualStrings(
        "read_file",
        canonical[1].assistant.execution.files[0].tool_name,
    );
    try std.testing.expectEqual(
        FileEvidenceAction.rename,
        canonical[1].assistant.execution.files[0].action,
    );
    try std.testing.expectEqual(
        PersistedToolStatus.failure,
        canonical[1].assistant.execution.files[0].status,
    );
    try std.testing.expect(canonical[1].assistant.execution.files[0].model_view_covers_full_file);
    try std.testing.expect(canonical[1].assistant.execution.files[0].stale);
    try std.testing.expectEqualStrings(
        "canonical interrupted",
        canonical[2].interrupted.user.text,
    );
    try std.testing.expectEqualStrings(
        "partial assistant",
        canonical[2].interrupted.assistant.?,
    );
    try std.testing.expectEqualStrings(
        "call_interrupted",
        canonical[2].interrupted.tool_call.?.id,
    );
    try std.testing.expectEqualStrings(
        "browser_navigate",
        canonical[2].interrupted.tool_call.?.name,
    );
    try std.testing.expectEqualStrings(
        "{\"url\":\"http://localhost:3000\"}",
        canonical[2].interrupted.tool_call.?.arguments_json,
    );
    try std.testing.expectEqual(@as(usize, 1), canonical[2].interrupted.completed_tool_names.len);
    try std.testing.expectEqualStrings(
        "read_file",
        canonical[2].interrupted.completed_tool_names[0],
    );
}

fn checkPromptHistorySnapshotAllocationFailures(alloc: Allocator) !void {
    var prefix_images = [_]ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/prefix.png"),
        .media_type = @constCast("image/png"),
    }};
    var calls = [_]ToolCall{.{
        .id = "call_preserved",
        .name = "read_file",
        .arguments_json = "{\"path\":\"fixture.txt\"}",
    }};
    var results = [_]PersistedToolResult{.{
        .tool_call_id = @constCast("call_preserved"),
        .tool_name = @constCast("read_file"),
        .status = .failure,
        .output = @constCast("preserved failure"),
        .output_bytes = 17,
        .stored_output_bytes = 17,
        .output_handle = @constCast("result-call_preserved.txt"),
        .preview = @constCast("preserved preview"),
    }};
    var files = [_]FileEvidence{.{
        .path = @constCast("src/preserved.zig"),
        .new_path = @constCast("src/preserved-renamed.zig"),
        .tool_call_id = @constCast("call_preserved"),
        .tool_name = @constCast("read_file"),
        .action = .rename,
        .status = .failure,
        .model_view_covers_full_file = true,
        .stale = true,
    }};
    var steps = [_]ToolExecutionStep{.{
        .assistant = @constCast("checking preserved evidence"),
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    var completed_tool_names = [_][]u8{@constCast("read_file")};
    var canonical = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{
                .text = @constCast("canonical prefix"),
                .images = prefix_images[0..],
            },
            .assistant = @constCast("prefix assistant"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("canonical background") },
            .assistant = @constCast("background assistant"),
            .execution = .{
                .tool_steps = steps[0..],
                .files = files[0..],
            },
        } },
        .{ .interrupted = .{
            .user = .{ .text = @constCast("canonical interrupted") },
            .assistant = @constCast("partial assistant"),
            .tool_call = .{
                .id = "call_interrupted",
                .name = "browser_navigate",
                .arguments_json = "{\"url\":\"http://localhost:3000\"}",
            },
            .completed_tool_names = completed_tool_names[0..],
        } },
    };
    const context_history_start: usize = 1;

    const prompt_history = snapshotOwnedContextHistory(
        alloc,
        &canonical,
        context_history_start,
        8,
    ) catch |err| {
        try expectCanonicalHistoryFixtureUnchanged(
            &canonical,
            context_history_start,
        );
        return err;
    };
    defer freeHistoryTurnSlice(alloc, prompt_history);
    try expectCanonicalHistoryFixtureUnchanged(
        &canonical,
        context_history_start,
    );
}

fn checkPromptHistoryMessageProjectionAllocationFailures(
    alloc: Allocator,
    prompt_history: []const HistoryTurn,
) !void {
    var messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &messages);

    appendHistoryMessages(
        alloc,
        &messages,
        prompt_history,
    ) catch |err| {
        try std.testing.expectEqualStrings(
            "old user",
            prompt_history[0].assistant.user.text,
        );
        try std.testing.expectEqualStrings(
            "latest user",
            prompt_history[1].assistant.user.text,
        );
        try std.testing.expectEqual(
            PersistedToolStatus.failure,
            prompt_history[1].assistant.execution.tool_steps[0].tool_results[0].status,
        );
        return err;
    };

    try std.testing.expectEqual(@as(usize, 6), messages.items.len);
    try std.testing.expectEqualStrings(
        "latest user",
        messages.items[messages.items.len - 4].content.?.asText(),
    );
    try std.testing.expectEqual(
        PersistedToolStatus.failure,
        messages.items[messages.items.len - 2].tool_result_status.?,
    );
    try std.testing.expectEqualStrings(
        "latest assistant",
        messages.items[messages.items.len - 1].content.?.asText(),
    );
}

fn checkWorkProvenanceOwnershipFailures(alloc: Allocator) !void {
    var images = [_]ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/image.png"),
        .media_type = @constCast("image/png"),
    }};
    const copy = try dupeUserTurn(alloc, .{
        .text = @constCast("prompt"),
        .images = &images,
        .work_id = @constCast("work-owned"),
    });
    freeUserTurn(alloc, copy);
}

fn checkImageCatalogHistoryMergeAllocationFailures(alloc: Allocator) !void {
    const catalog = [_]ImageAttachment{.{
        .id = 2,
        .path = @constCast("/tmp/history.png"),
        .media_type = @constCast("image/png"),
    }};
    var added = [_]ImageAttachment{.{
        .id = 8,
        .path = @constCast("/tmp/completed.png"),
        .media_type = @constCast("image/png"),
    }};
    const turn: HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("completed"), .images = &added },
        .assistant = @constCast("done"),
    } };
    const merged = try merge_image_catalog_history_turn(alloc, &catalog, turn);
    defer core_types.freeImageAttachmentSlice(alloc, merged);
    try std.testing.expectEqual(@as(usize, 2), merged.len);
}

fn deinitMessages(alloc: Allocator, messages: *std.ArrayList(message.Message)) void {
    for (messages.items) |*msg| msg.deinit(alloc);
    messages.deinit(alloc);
}

fn projectedTexts(arena: Allocator, history: []const HistoryTurn) ![]const []const u8 {
    var messages: std.ArrayList(core_types.ChatMessage) = .empty;
    try appendActiveContextHistoryChatMessages(arena, &messages, history, 0);
    const texts = try arena.alloc([]const u8, messages.items.len);
    for (messages.items, texts) |chat, *text| text.* = chat.content orelse "";
    return texts;
}
