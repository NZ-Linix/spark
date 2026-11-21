const std = @import("std");
const testing_allocator = @import("../../core/shared/testing_allocator.zig");
const build_checkpoint = @import("../render_engine/build_checkpoint.zig");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");
const types = @import("../../core/shared/types.zig");
const display_width = @import("../../core/shared/display_width.zig");
const mem_utils = @import("../../core/shared/mem_utils.zig");
const shared_theme = @import("../../core/shared/theme.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");
const ui_render = @import("../render.zig");
const code_highlight = @import("../../core/agent/presentation/code_highlight.zig");
const code_highlight_languages = @import("../../core/agent/presentation/code_highlight_languages.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const json_depth = @import("../../core/shared/json_depth.zig");
const command_lex = @import("../../core/shell_command/command_lex.zig");
const tooling_presentation = @import("../../core/tooling/tool_presentation.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const TranscriptEntry = transcript_blocks.TranscriptEntry;
const ToolDetailRecord = transcript_blocks.ToolDetailRecord;
const cancellation_follow_up = " · What can spark do differently?";

// The small helpers marked `noinline` below are called from many places in
// the rows and headers. LLVM would copy each into every caller, and those
// copies cost more code than the calls do.

pub const Projection = struct {
    entry_actions: std.ArrayList(transcript_blocks.EntryRenderAction) = .empty,
    owned_overrides: std.ArrayList(OwnedOverride) = .empty,

    pub fn deinit(self: *Projection, alloc: std.mem.Allocator) void {
        for (self.owned_overrides.items) |owned| {
            alloc.free(owned.bytes);
            alloc.free(owned.line_provenance);
        }
        self.owned_overrides.deinit(alloc);
        self.entry_actions.deinit(alloc);
        self.* = undefined;
    }

    fn setOwnedOverride(
        self: *Projection,
        alloc: std.mem.Allocator,
        entry_index: usize,
        kind: transcript_blocks.TranscriptBlockKind,
        bytes: []u8,
    ) !void {
        errdefer alloc.free(bytes);
        try self.owned_overrides.append(alloc, .{
            .entry_index = entry_index,
            .bytes = bytes,
        });
        self.entry_actions.items[entry_index] = .{ .override = .{
            .kind = kind,
            .bytes = bytes,
        } };
    }

    fn setOwnedGroup(self: *Projection, alloc: std.mem.Allocator, index: usize, group: GroupBlock) !void {
        errdefer alloc.free(group.lines);
        try self.setOwnedOverride(alloc, index, .tool_status, group.bytes);
        self.owned_overrides.items[self.owned_overrides.items.len - 1].line_provenance = group.lines;
        self.entry_actions.items[index].override.line_provenance = group.lines;
    }

    fn appendOwnedOverride(
        self: *Projection,
        alloc: std.mem.Allocator,
        kind: transcript_blocks.TranscriptBlockKind,
        bytes: []u8,
    ) !void {
        const entry_index = self.entry_actions.items.len;
        errdefer alloc.free(bytes);
        try self.entry_actions.ensureUnusedCapacity(alloc, 1);
        try self.owned_overrides.append(alloc, .{
            .entry_index = entry_index,
            .bytes = bytes,
        });
        self.entry_actions.appendAssumeCapacity(.{ .override = .{
            .kind = kind,
            .bytes = bytes,
        } });
    }

    pub fn replaceSuffix(
        self: *Projection,
        alloc: std.mem.Allocator,
        start_index: usize,
        suffix: *Projection,
    ) !void {
        std.debug.assert(start_index <= self.entry_actions.items.len);
        try self.entry_actions.ensureTotalCapacity(
            alloc,
            start_index + suffix.entry_actions.items.len,
        );
        var retained_owned_count: usize = 0;
        for (self.owned_overrides.items) |owned| {
            if (owned.entry_index < start_index) retained_owned_count += 1;
        }
        try self.owned_overrides.ensureTotalCapacity(
            alloc,
            retained_owned_count + suffix.owned_overrides.items.len,
        );

        var retained_index: usize = 0;
        for (self.owned_overrides.items) |owned| {
            if (owned.entry_index < start_index) {
                self.owned_overrides.items[retained_index] = owned;
                retained_index += 1;
            } else {
                alloc.free(owned.bytes);
                alloc.free(owned.line_provenance);
            }
        }
        self.owned_overrides.items.len = retained_index;
        self.entry_actions.items.len = start_index;
        for (suffix.entry_actions.items) |action| {
            self.entry_actions.appendAssumeCapacity(action);
        }
        for (suffix.owned_overrides.items) |owned| {
            self.owned_overrides.appendAssumeCapacity(.{
                .entry_index = start_index + owned.entry_index,
                .bytes = owned.bytes,
                .line_provenance = owned.line_provenance,
            });
        }
        suffix.entry_actions.items.len = 0;
        suffix.owned_overrides.items.len = 0;
    }
};

const OwnedOverride = struct {
    entry_index: usize,
    bytes: []u8,
    line_provenance: []const transcript_blocks.LineProvenance = &.{},
};

pub const SummaryStyle = struct {
    marker_style: []const u8 = "",
    text_style: []const u8 = "",
    reset_style: []const u8 = "",
    /// A failed call's ✗ and the words that say it failed.
    failure_style: []const u8 = "",
};

const BuildStats = struct {
    detail_lookups: usize = 0,
};

const ProjectionMode = enum { compact, expanded };

const category_labels = [_][]const u8{
    "read",
    "list",
    "write",
    "edit",
    "open",
    "command",
    "subagent call",
    "browser",
    "MCP call",
};
const command_category_index = 5;
const subagent_category_index = 6;
const mcp_category_index = 8;

const Summary = struct {
    total: usize = 0,
    categories: [category_labels.len]usize = @splat(0),
    failed: usize = 0,
    timed_out: usize = 0,
    denied: usize = 0,
    cancelled: usize = 0,
    completion_unreported: usize = 0,
    not_executed: usize = 0,
};

const PresentationGroup = struct {
    anchor_index: usize,
    /// How many user messages come before the group's first row.
    user_messages_before: usize = 0,
    status_indices: std.ArrayList(usize) = .empty,
    summary: Summary = .{},

    fn deinit(self: *PresentationGroup, alloc: std.mem.Allocator) void {
        self.status_indices.deinit(alloc);
        self.* = undefined;
    }
};

fn categoryIndex(kind: types.ToolActivityKind) ?usize {
    return switch (kind) {
        .read => 0,
        .list => 1,
        .write => 2,
        .edit => 3,
        .open => 4,
        .command => command_category_index,
        .subagent => subagent_category_index,
        .ask => null,
        .mcp => mcp_category_index,
    };
}

noinline fn detailForEntry(
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    entry_id: u32,
    stats: ?*BuildStats,
) ?*const ToolDetailRecord {
    if (stats) |value| value.detail_lookups += 1;
    const index = detail_indices.get(entry_id) orelse return null;
    return &details[index];
}

fn toolStatusEntryId(entry: TranscriptEntry) ?u32 {
    return switch (entry) {
        .raw_bytes => |raw| if (raw.class == .tool_status) raw.id else null,
        else => null,
    };
}

fn skipSgrSequence(text: []const u8, index: *usize) bool {
    if (index.* + 2 > text.len or text[index.*] != 0x1b or text[index.* + 1] != '[') {
        return false;
    }
    var end = index.* + 2;
    while (end < text.len and (text[end] < 0x40 or text[end] > 0x7e)) : (end += 1) {}
    if (end == text.len or text[end] != 'm') return false;
    index.* = end + 1;
    return true;
}

fn rawStatusNamesAskTool(text: []const u8) bool {
    var index: usize = 0;
    while (skipSgrSequence(text, &index)) {}
    const label = "● ask_user_question";
    if (!std.mem.startsWith(u8, text[index..], label)) return false;
    index += label.len;
    while (skipSgrSequence(text, &index)) {}
    return std.mem.eql(u8, text[index..], "") or
        std.mem.eql(u8, text[index..], "\n") or
        std.mem.eql(u8, text[index..], "\r\n");
}

fn statusNamesAsk(entry: TranscriptEntry, detail: ?*const ToolDetailRecord) bool {
    if (detail) |record| {
        return record.activity_kind == .ask or
            std.mem.eql(u8, record.tool_name, "ask_user_question");
    }
    return switch (entry) {
        .raw_bytes => |raw| rawStatusNamesAskTool(raw.bytes),
        else => false,
    };
}

/// Whether a row shows a subagent's report or message to main, which its
/// detail marks (src/core/subagent/reports.zig, Row). Live, main's calls
/// have a presentation group and this row has none, so it never joins their
/// group. Resumed rows have no presentation group, so a run of rows splits
/// where such rows start and end instead.
fn isSubagentUpdateRow(detail: ?*const ToolDetailRecord) bool {
    const record = detail orelse return false;
    return record.subagent_report;
}

fn isAttachedEntry(entry: TranscriptEntry) bool {
    return switch (entry) {
        .raw_bytes => |raw| raw.class == .command_output or raw.class == .diff_block,
        else => false,
    };
}

fn isTransparentCompactEntry(entry: TranscriptEntry) bool {
    if (!transcript_blocks.isEntryVisibleInCompactPresentation(entry)) return true;
    return switch (entry) {
        .assistant_turn => |assistant| assistant.segments.text.items.len == 0,
        else => false,
    };
}

fn commandProcessFailed(record: *const ToolDetailRecord) bool {
    if (record.activity_kind != .command) return false;
    const presentation = record.command_process_presentation orelse return false;
    return switch (presentation) {
        .exit_code => |code| code != 0,
        .signal, .timed_out, .output_capture_failed => true,
    };
}

fn commandProcessTimedOut(record: *const ToolDetailRecord) bool {
    if (record.activity_kind != .command) return false;
    const presentation = record.command_process_presentation orelse return false;
    return presentation == .timed_out;
}

fn observeTool(summary: *Summary, detail: ?*const ToolDetailRecord) void {
    summary.total += 1;
    const record = detail orelse return;
    if (record.activity_kind) |kind| {
        if (categoryIndex(kind)) |index| summary.categories[index] += 1;
    }
    if (record.fallback_disposition) |disposition| {
        switch (disposition) {
            .completion_unreported => summary.completion_unreported += 1,
            .not_executed => summary.not_executed += 1,
        }
        return;
    }
    const process_failed = commandProcessFailed(record);
    const process_timed_out = commandProcessTimedOut(record);
    if (record.outcome) |outcome| {
        switch (outcome) {
            .completed => {
                if (process_timed_out)
                    summary.timed_out += 1
                else if (process_failed)
                    summary.failed += 1;
            },
            .failed => {
                if (process_timed_out)
                    summary.timed_out += 1
                else
                    summary.failed += 1;
            },
            .denied => summary.denied += 1,
            .cancelled => summary.cancelled += 1,
            .deferred => {},
        }
    }
}

noinline fn appendSegment(writer: *std.Io.Writer, count: usize, label: []const u8) !void {
    if (count == 0) return;
    try writeCount(writer, " · ", count, " ");
    try writer.writeAll(label);
}

/// Writes `before`, `count`, then `after`, such as " +2 more". Every count
/// the rows and headers write goes through this one format, since each
/// format is code of its own.
noinline fn writeCount(writer: *std.Io.Writer, before: []const u8, count: usize, after: []const u8) !void {
    try writer.print("{s}{d}{s}", .{ before, count, after });
}

/// Core's label for a shell run that returned while its command ran on
/// (`still_running_label` in src/core/agent/runtime/tool_presentation.zig).
const still_running_label = "Still running";

/// Whether a command's row reads "Still running": its call returned before
/// the command ended, so it has no exit status yet.
fn commandStillRunning(scratch: std.mem.Allocator, entry: TranscriptEntry) !bool {
    const status = try entryStatus(scratch, entry) orelse return false;
    return std.mem.startsWith(u8, status, still_running_label ++ " ");
}

/// The status phrase of a tool's status line, or null for other entries.
fn entryStatus(scratch: std.mem.Allocator, entry: TranscriptEntry) !?[]const u8 {
    return switch (entry) {
        .raw_bytes => |raw| try normalizeCanonicalStatus(scratch, raw.bytes),
        else => null,
    };
}

fn normalizeCanonicalStatus(
    scratch: std.mem.Allocator,
    text: []const u8,
) !?[]const u8 {
    var index: usize = 0;
    while (skipSgrSequence(text, &index)) {}
    const marker = for (status_markers) |candidate| {
        if (std.mem.startsWith(u8, text[index..], candidate)) break candidate;
    } else return null;
    index += marker.len;
    while (skipSgrSequence(text, &index)) {}
    while (index < text.len and (text[index] == ' ' or text[index] == '\t')) : (index += 1) {}

    var out: std.Io.Writer.Allocating = .init(scratch);
    errdefer out.deinit();
    while (index < text.len) {
        if (skipSgrSequence(text, &index)) continue;
        const byte = text[index];
        if (byte == '\n' or byte == '\r') break;
        if (byte >= 0x20) try out.writer.writeByte(byte);
        index += 1;
    }
    const owned = try out.toOwnedSlice();
    var phrase = std.mem.trim(u8, owned, " \t");
    if (std.mem.endsWith(u8, phrase, cancellation_follow_up)) {
        phrase = std.mem.trimEnd(u8, phrase[0 .. phrase.len - cancellation_follow_up.len], " \t");
    }
    return if (phrase.len == 0) null else phrase;
}

/// The cancellation notice of a cancelled shell command's status line `raw`,
/// such as `▪ Cancelled touch .ready && sleep 60 · What can spark do
/// differently?`, with no command: `▪ Cancelled · What can spark do
/// differently?`, the notice a cancelled turn shows. The row above names the
/// command by its short form and Ctrl+O by its full line, so the notice
/// repeats neither. The line keeps its styles. Null when `raw` doesn't read
/// `Cancelled …` after its mark.
fn cancelledCommandNotice(scratch: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    var index: usize = 0;
    while (skipSgrSequence(raw, &index)) {}
    const marker = for (status_markers) |candidate| {
        if (std.mem.startsWith(u8, raw[index..], candidate)) break candidate;
    } else return null;
    index += marker.len;
    while (true) {
        if (skipSgrSequence(raw, &index)) continue;
        if (index < raw.len and raw[index] == ' ') {
            index += 1;
            continue;
        }
        break;
    }
    const label = "Cancelled";
    if (!std.mem.startsWith(u8, raw[index..], label)) return null;
    const kept_end = index + label.len;
    // The command ends at the follow-up, or at the line's end on a line
    // saved without one.
    const tail_at = std.mem.findLast(u8, raw[kept_end..], cancellation_follow_up) orelse
        std.mem.trimEnd(u8, raw[kept_end..], "\r\n").len;
    var out: std.Io.Writer.Allocating = .init(scratch);
    errdefer out.deinit();
    try out.writer.writeAll(raw[0..kept_end]);
    // The command's text goes, and its style codes stay, so every style the
    // line opens still closes.
    var cursor = kept_end;
    while (cursor < kept_end + tail_at) {
        const start = cursor;
        if (skipSgrSequence(raw, &cursor)) {
            try out.writer.writeAll(raw[start..cursor]);
        } else cursor += 1;
    }
    try out.writer.writeAll(raw[kept_end + tail_at ..]);
    return try out.toOwnedSlice();
}

// `■` is the cancelled marker older sessions recorded before `▪`.
const status_markers = [_][]const u8{ "●", "▪", "■", "⊘", "↻" };

/// The state mark a tool's status line opens with, in its own color, so a
/// denied or cancelled call keeps its mark in Ctrl+O. A line without one gets
/// a plain `●`.
fn statusMarker(entry: TranscriptEntry) []const u8 {
    const text = switch (entry) {
        .raw_bytes => |raw| raw.bytes,
        else => return "●",
    };
    var index: usize = 0;
    while (skipSgrSequence(text, &index)) {}
    const marker = for (status_markers) |candidate| {
        if (std.mem.startsWith(u8, text[index..], candidate)) break candidate;
    } else return "●";
    index += marker.len;
    while (skipSgrSequence(text, &index)) {}
    return text[0..index];
}

fn normalizeStatusPhrase(
    scratch: std.mem.Allocator,
    text: []const u8,
) !?[]const u8 {
    if (try normalizeCanonicalStatus(scratch, text)) |phrase| return phrase;
    var out: std.Io.Writer.Allocating = .init(scratch);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < text.len) {
        if (skipSgrSequence(text, &index)) continue;
        const byte = text[index];
        if (byte == '\n' or byte == '\r') break;
        if (byte >= 0x20) try out.writer.writeByte(byte);
        index += 1;
    }
    const owned = try out.toOwnedSlice();
    const phrase = std.mem.trim(u8, owned, " \t");
    return if (phrase.len == 0) null else phrase;
}

fn subagentStatusContinuation(
    entry: TranscriptEntry,
    detail: ?*const ToolDetailRecord,
) ?[]const u8 {
    const record = detail orelse return null;
    if (record.activity_kind != .subagent) return null;
    const text = switch (entry) {
        .raw_bytes => |raw| raw.bytes,
        else => return null,
    };
    const newline = findByte(text, '\n') orelse return null;
    const continuation = std.mem.trim(u8, text[newline + 1 ..], " \t\r\n");
    return if (continuation.len == 0) null else continuation;
}

fn clipSummary(
    alloc: std.mem.Allocator,
    text: []const u8,
    cols: u16,
) ![]u8 {
    if (display_width.visibleWidthIgnoringAnsi(text) <= cols) return try alloc.dupe(u8, text);
    if (cols == 0) return try alloc.dupe(u8, "");
    if (cols == 1) return try alloc.dupe(u8, "…");
    const prefix = display_width.prefixByWidthIgnoringAnsi(text, cols - 1);
    // A cut inside a file link closes it, so the rest of the screen does not
    // link to the file.
    const clipped = try std.mem.concat(alloc, u8, &.{ prefix, if (endsInsideLink(prefix)) link_close else "", "…" });
    // A cut inside a styled run can leave the final SGR open; close it so the
    // accent cannot bleed into whatever the terminal paints next.
    if (std.mem.find(u8, clipped, "\x1b") == null or std.mem.endsWith(u8, clipped, "\x1b[0m"))
        return clipped;
    defer alloc.free(clipped);
    return try std.mem.concat(alloc, u8, &.{ clipped, "\x1b[0m" });
}

const StatToken = struct {
    /// Index of the sign character.
    start: usize,
    added: bool,
};

/// Diff counts exist only on write_file/edit_file status lines; every other
/// phrase can end in a coincidental " +N" / "-N" (for example `head -80`).
noinline fn entryShowsDiffStats(detail: ?*const ToolDetailRecord) bool {
    const record = detail orelse return false;
    return std.mem.eql(u8, record.tool_name, "write_file") or
        std.mem.eql(u8, record.tool_name, "edit_file");
}

/// Matches a trailing " +N" or " -N" diff count in a plain status phrase, or
/// the "-M" of a row's "+N/-M".
fn trailingStatToken(text: []const u8) ?StatToken {
    var index = text.len;
    while (index > 0 and std.ascii.isDigit(text[index - 1])) : (index -= 1) {}
    if (index == text.len) return null;
    if (index < 2) return null;
    const sign = text[index - 1];
    if (sign != '+' and sign != '-') return null;
    const token: StatToken = .{ .start = index - 1, .added = sign == '+' };
    if (text[index - 2] == ' ') return token;
    // A row joins its two counts with a bare slash.
    if (sign == '-' and text[index - 2] == '/') if (trailingStatToken(text[0 .. index - 2])) |first| if (first.added) return token;
    return null;
}

/// The "+N" of a "+N / -M" or "+N/-M" pair that ends in `last`, if there is
/// one.
fn pairedAddedStat(text: []const u8, last: StatToken) ?StatToken {
    if (last.added or last.start < 2) return null;
    const before_slash = if (text[last.start - 1] == '/')
        text[0 .. last.start - 1]
    else if (text[last.start - 2] == '/')
        std.mem.trimEnd(u8, text[0 .. last.start - 2], " ")
    else
        return null;
    const first = trailingStatToken(before_slash) orelse return null;
    return if (first.added) first else null;
}

/// The index just past the digits of a stat token.
fn statEnd(text: []const u8, token: StatToken) usize {
    var end = token.start + 1;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    return end;
}

/// The number of a stat token.
fn statValue(text: []const u8, token: StatToken) usize {
    return std.fmt.parseInt(usize, text[token.start + 1 .. statEnd(text, token)], 10) catch 0;
}

/// Index of the space before the trailing "+N", "-N", "+N / -M", or "+N/-M"
/// diff counts of a plain status phrase, or null when it has none.
fn diffStatsSuffixStart(text: []const u8) ?usize {
    const last = trailingStatToken(text) orelse return null;
    const first = pairedAddedStat(text, last) orelse last;
    return first.start - 1;
}

/// Clips a write_file or edit_file row like clipSummary, but keeps its
/// trailing diff counts: the phrase before them ends in "…" and the counts
/// follow it. When the counts would take more than half the row, the row
/// clips from the right like any other. Caller owns the returned slice.
fn clipKeepingDiffStats(
    alloc: std.mem.Allocator,
    text: []const u8,
    cols: u16,
) ![]u8 {
    if (display_width.visibleWidthIgnoringAnsi(text) <= cols) return try alloc.dupe(u8, text);
    const suffix_start = diffStatsSuffixStart(text) orelse return clipSummary(alloc, text, cols);
    const suffix = text[suffix_start..];
    const suffix_width = display_width.visibleWidthIgnoringAnsi(suffix);
    if (suffix_width * 2 > cols) return clipSummary(alloc, text, cols);
    const phrase = try clipSummary(alloc, text[0..suffix_start], @intCast(cols - suffix_width));
    defer alloc.free(phrase);
    return try std.mem.concat(alloc, u8, &.{ phrase, suffix });
}

/// Re-applies the diff add/remove marker accents to the trailing "+N" / "-N"
/// counts of a normalized tool status phrase. Normalization strips SGR so
/// grouped lines stay uniform; the counts keep their green/red so file edits
/// stay scannable inside collapsed and expanded groups. `ambient_style` is
/// re-applied between the two counts so the " / " separator keeps the line's
/// surrounding style, whether it is core's " / " or a row's "/". Returns
/// `text` unchanged when no diff count suffix is present. Caller owns the
/// returned slice.
fn accentTrailingDiffStats(
    alloc: std.mem.Allocator,
    text: []const u8,
    ambient_style: []const u8,
) ![]u8 {
    const added_style = ui_render.diff_added_marker_style;
    const removed_style = ui_render.diff_removed_marker_style;
    if (added_style.len == 0 and removed_style.len == 0) return try alloc.dupe(u8, text);
    const reset = "\x1b[0m";

    const last = trailingStatToken(text) orelse return try alloc.dupe(u8, text);
    if (pairedAddedStat(text, last)) |first| {
        const first_end = statEnd(text, first);
        return try std.mem.concat(alloc, u8, &.{
            text[0..first.start],
            added_style,
            text[first.start..first_end],
            reset,
            ambient_style,
            text[first_end..last.start],
            removed_style,
            text[last.start..],
            reset,
        });
    }
    const style = if (last.added) added_style else removed_style;
    if (style.len == 0) return try alloc.dupe(u8, text);
    return try std.mem.concat(alloc, u8, &.{
        text[0..last.start],
        style,
        text[last.start..],
        reset,
    });
}

fn applySummaryStyle(
    alloc: std.mem.Allocator,
    text: []const u8,
    style: SummaryStyle,
) ![]u8 {
    if (style.marker_style.len == 0 and
        style.text_style.len == 0 and
        style.reset_style.len == 0)
    {
        return try alloc.dupe(u8, text);
    }

    const marker = "●";
    if (!std.mem.startsWith(u8, text, marker)) return try alloc.dupe(u8, text);
    var content_start = marker.len;
    const has_separator = content_start < text.len and text[content_start] == ' ';
    if (has_separator) content_start += 1;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(style.marker_style);
    try out.writer.writeAll(marker);
    try out.writer.writeAll(style.reset_style);
    if (content_start < text.len) {
        if (has_separator) try out.writer.writeByte(' ');
        try out.writer.writeAll(style.text_style);
        try out.writer.writeAll(text[content_start..]);
        try out.writer.writeAll(style.reset_style);
    }
    return try out.toOwnedSlice();
}

/// Compact group header: the summary clipped to one row and styled.
fn formatGroupHeader(
    alloc: std.mem.Allocator,
    summary: Summary,
    cols: u16,
    style: SummaryStyle,
) ![]u8 {
    const plain = try formatGroupSummary(alloc, summary);
    defer alloc.free(plain);
    const clipped = try clipSummary(alloc, plain, cols);
    defer alloc.free(clipped);
    return applySummaryStyle(alloc, clipped, style);
}

/// Unstyled, unclipped "● N tool calls · ..." summary row. Caller owns it.
fn formatGroupSummary(alloc: std.mem.Allocator, summary: Summary) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeCount(&out.writer, "● ", summary.total, if (summary.total == 1) " tool call" else " tool calls");
    var emitted: [category_labels.len]bool = @splat(false);
    for (0..category_labels.len) |_| {
        var next_index: ?usize = null;
        for (summary.categories, 0..) |count, index| {
            if (count == 0 or emitted[index]) continue;
            if (next_index == null or count > summary.categories[next_index.?]) {
                next_index = index;
            }
        }
        const index = next_index orelse break;
        emitted[index] = true;
        const count = summary.categories[index];
        const label = if (count == 1) category_labels[index] else switch (index) {
            command_category_index => "commands",
            subagent_category_index => "subagent calls",
            mcp_category_index => "MCP calls",
            else => category_labels[index],
        };
        try appendSegment(&out.writer, count, label);
    }
    try appendSegment(&out.writer, summary.completion_unreported, "unreported");
    try appendSegment(&out.writer, summary.not_executed, "not executed");
    try appendSegment(&out.writer, summary.timed_out, "timed out");
    try appendSegment(&out.writer, summary.failed, "failed");
    try appendSegment(&out.writer, summary.denied, "denied");
    try appendSegment(&out.writer, summary.cancelled, "cancelled");
    return out.toOwnedSlice();
}

// Story presentation. A group header names the main event of the group and
// how it ended. Calls that repeat one task share a row that shows their latest
// state. A failed call gets one reason line, and the turn summary leads with a
// recap of what the turn changed and ran.

/// Writes `text` terminal-safe, so a control byte or an invalid UTF-8 byte
/// shows as its visible escape.
noinline fn writeTerminalSafe(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try writer.print("{f}", .{text_utils.terminalSafe(text)});
}

/// `text` terminal-safe, in `scratch`, as `scratch.print` would make it.
fn terminalSafeText(scratch: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(scratch);
    writeTerminalSafe(&out.writer, text) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `std.mem.findScalar` for bytes. Its vector loop is a few hundred bytes of
/// code, and the rows search bytes in many places.
noinline fn findByte(text: []const u8, byte: u8) ?usize {
    return std.mem.findScalar(u8, text, byte);
}

/// Keeps printable text on one line: drops escape sequences and control
/// bytes, folds whitespace runs to one space, caps the length, and writes
/// what remains terminal-safe, so a C1 control or an invalid UTF-8 byte shows
/// as its visible escape.
fn storySafeLine(scratch: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(scratch);
    var index: usize = 0;
    var pending_space = false;
    while (index < text.len and out.written().len < max_bytes) {
        const byte = text[index];
        if (byte == 0x1b) {
            index += 1;
            if (index < text.len and text[index] == '[') {
                index += 1;
                while (index < text.len and (text[index] < 0x40 or text[index] > 0x7e)) : (index += 1) {}
            }
            index += 1;
            continue;
        }
        if (byte < 0x20 or byte == 0x7f or byte == ' ') {
            pending_space = out.written().len > 0;
            index += 1;
            continue;
        }
        if (pending_space) try out.writer.writeByte(' ');
        pending_space = false;
        try out.writer.writeByte(byte);
        index += 1;
    }
    var written = out.written();
    // Never end inside a UTF-8 sequence.
    var end = written.len;
    while (end > 0 and (written[end - 1] & 0xC0) == 0x80) end -= 1;
    if (end > 0 and written[end - 1] >= 0xC0) {
        const lead = written[end - 1];
        const need: usize = if (lead >= 0xF0) 4 else if (lead >= 0xE0) 3 else 2;
        if (written.len - (end - 1) < need) written = written[0 .. end - 1];
    }
    return terminalSafeText(scratch, written);
}

/// A string or whole-number field of a JSON object; `.other` for any other
/// value.
const JsonField = union(enum) { string: []const u8, integer: i64, other };

/// The value of `key` among the top-level fields of the JSON object `json`,
/// or, when it has a "request" field, among that object's fields only: a
/// call can wrap its fields in {"request": {...}}, or send that object as
/// JSON text, and core then reads nothing outside it, and nothing at all when
/// "request" is neither (`unwrapRequest` in src/core/tooling/tool_args.zig). It reads the top-level field
/// names to the end of the object, because a "request" field can come after
/// the key, and it skips each value by jumping from quote to quote. It
/// decodes only the key's own value, so a write_file call that holds a whole
/// file costs one quick scan on each render, not a parse. It does not check
/// the text after the object. error.NotObject when `json` is not an object; null when
/// it has no such key.
fn jsonObjectField(scratch: std.mem.Allocator, json: []const u8, key: []const u8) !?JsonField {
    const open = skipJsonSpace(json, 0);
    if (open >= json.len or json[open] != '{') return error.NotObject;
    return objectField(scratch, json, open + 1, key, true);
}

noinline fn jsonField(scratch: std.mem.Allocator, json: []const u8, key: []const u8) ?JsonField {
    return jsonObjectField(scratch, json, key) catch null;
}

/// Searches the fields of an object whose text starts at `start`, just after
/// its "{".
fn objectField(scratch: std.mem.Allocator, json: []const u8, start: usize, key: []const u8, top: bool) !?JsonField {
    var index = skipJsonSpace(json, start);
    var top_match: ?JsonField = null;
    while (index < json.len and json[index] != '}') {
        if (json[index] != '"') return error.SyntaxError;
        const name_end = skipJsonString(json, index) orelse return error.SyntaxError;
        const raw_name = json[index..name_end];
        const name = if (findByte(raw_name, '\\') == null)
            raw_name[1 .. raw_name.len - 1]
        else
            try std.json.parseFromSliceLeaky([]const u8, scratch, raw_name, .{});
        index = skipJsonSpace(json, name_end);
        if (index >= json.len or json[index] != ':') return error.SyntaxError;
        index = skipJsonSpace(json, index + 1);
        if (index >= json.len) return error.SyntaxError;
        if (top and std.mem.eql(u8, name, "request")) {
            if (json[index] == '{') return objectField(scratch, json, index + 1, key, false);
            if (json[index] != '"') return null;
            return switch (try fieldValue(scratch, json, index)) {
                .string => |text| try requestTextField(scratch, text, key),
                else => null,
            };
        }
        if (top_match == null and std.mem.eql(u8, name, key)) {
            top_match = try fieldValue(scratch, json, index);
            // At the top, a "request" field later in the object would take
            // its place, so the scan goes on over the other fields.
            if (!top) return top_match;
        }
        index = skipJsonSpace(json, skipJsonValue(json, index) orelse return error.SyntaxError);
        if (index < json.len and json[index] == ',') index = skipJsonSpace(json, index + 1);
    }
    return top_match;
}

/// The value of `key` in a "request" that a model sent as JSON text, read as
/// core reads it (`normalizeCompositeObjectValue` in
/// src/core/tooling/tool_args.zig): text that nests too deep, is not valid
/// JSON, or is not one object gives no fields.
fn requestTextField(scratch: std.mem.Allocator, text: []const u8, key: []const u8) std.mem.Allocator.Error!?JsonField {
    if (json_depth.exceeds(text)) return null;
    if (!try std.json.validate(scratch, text)) return null;
    const open = skipJsonSpace(text, 0);
    if (open >= text.len or text[open] != '{') return null;
    return objectField(scratch, text, open + 1, key, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

fn fieldValue(scratch: std.mem.Allocator, json: []const u8, start: usize) !JsonField {
    const end = skipJsonValue(json, start) orelse return error.SyntaxError;
    const raw = json[start..end];
    return switch (raw[0]) {
        '"' => .{ .string = if (findByte(raw, '\\') == null)
            raw[1 .. raw.len - 1]
        else
            try std.json.parseFromSliceLeaky([]const u8, scratch, raw, .{}) },
        '-', '0'...'9' => .{ .integer = std.fmt.parseInt(i64, raw, 10) catch return .other },
        else => .other,
    };
}

noinline fn skipJsonSpace(json: []const u8, start: usize) usize {
    var index = start;
    while (index < json.len and std.mem.findScalar(u8, " \t\r\n", json[index]) != null) index += 1;
    return index;
}

/// Where the string that starts with the quote at `start` ends, just after
/// its closing quote. It jumps from quote to quote, so a long string costs
/// little.
fn skipJsonString(json: []const u8, start: usize) ?usize {
    var from = start + 1;
    while (std.mem.findScalarPos(u8, json, from, '"')) |quote| {
        var slashes: usize = 0;
        while (quote - slashes > start + 1 and json[quote - slashes - 1] == '\\') slashes += 1;
        if (slashes % 2 == 0) return quote + 1;
        from = quote + 1;
    }
    return null;
}

/// Where the value that starts at `start` ends.
fn skipJsonValue(json: []const u8, start: usize) ?usize {
    switch (json[start]) {
        '"' => return skipJsonString(json, start),
        '{', '[' => {
            var depth: usize = 0;
            var index = start;
            while (index < json.len) {
                switch (json[index]) {
                    '"' => {
                        index = skipJsonString(json, index) orelse return null;
                        continue;
                    },
                    '{', '[' => depth += 1,
                    '}', ']' => {
                        depth -= 1;
                        if (depth == 0) return index + 1;
                    },
                    else => {},
                }
                index += 1;
            }
            return null;
        },
        else => {
            var index = start;
            while (index < json.len and std.mem.findScalar(u8, ",}] \t\r\n", json[index]) == null) index += 1;
            return if (index > start) index else null;
        },
    }
}

noinline fn storyArgString(scratch: std.mem.Allocator, record: *const ToolDetailRecord, key: []const u8) ?[]const u8 {
    const json = record.arguments_json orelse return null;
    return switch (jsonField(scratch, json, key) orelse return null) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    };
}

/// Whether a call saved its arguments as an object; old records keep none.
fn storyHasArgs(record: *const ToolDetailRecord) bool {
    const json = record.arguments_json orelse return false;
    const open = skipJsonSpace(json, 0);
    return open < json.len and json[open] == '{';
}

const DiffTotals = struct { added: usize = 0, removed: usize = 0 };

fn diffTotalsOfPhrase(phrase: []const u8) DiffTotals {
    var totals: DiffTotals = .{};
    const last = trailingStatToken(phrase) orelse return totals;
    const last_value = statValue(phrase, last);
    if (last.added) totals.added = last_value else totals.removed = last_value;
    if (pairedAddedStat(phrase, last)) |first| totals.added = statValue(phrase, first);
    return totals;
}

fn storyCommandFailed(record: *const ToolDetailRecord) bool {
    if (record.outcome) |outcome| if (outcome == .failed) return true;
    return commandProcessFailed(record);
}

const StoryTally = struct {
    changed_paths: std.ArrayList([]const u8) = .empty,
    change_calls: usize = 0,
    write_calls: usize = 0,
    /// Edits and writes that have not finished.
    changes_running: usize = 0,
    diff: DiffTotals = .{},
    read_paths: std.ArrayList([]const u8) = .empty,
    /// read_file calls whose saved arguments name no path, as in old records.
    unnamed_reads: usize = 0,
    /// Searches by tool and pattern, each once, so a pattern searched in
    /// two folders counts as one.
    search_keys: std.ArrayList([]const u8) = .empty,
    /// Searches that name no pattern, as in old records, and other listings.
    unkeyed_searches: usize = 0,
    web_searches: usize = 0,
    web_reads: usize = 0,
    commands: usize = 0,
    /// Sessions that later calls sent input to or stopped. Those calls are
    /// not new commands, so they count here instead.
    followed_sessions: std.ArrayList([]const u8) = .empty,
    unnamed_session_calls: usize = 0,
    commands_failed: usize = 0,
    /// Whether the latest command failed, so the result mark reports where
    /// the work ended rather than every retry on the way.
    last_command_failed: ?bool = null,
    /// Commands that have not finished, which hold back the ✓.
    commands_running: usize = 0,
    /// Commands whose call returned while they ran on, which core labels
    /// "Still running". They have no exit status, so they hold back the ✓
    /// too, while the header still says they ran.
    commands_still_running: usize = 0,
    /// Calls other than commands that failed, such as an edit that did not
    /// apply.
    other_failures: usize = 0,
    /// Those failed calls that their turn ended on, which a collapsed group's
    /// header counts, since no row shows them.
    turn_ending_failures: usize = 0,
    /// Calls held until spark reads the project instructions they reach.
    deferred: usize = 0,
    /// Rows whose latest command failed, other than the group's last
    /// command, whose result the mark already shows. A command that passed on
    /// a retry shares one row with its failures and does not count.
    earlier_command_failures: usize = 0,
    /// Whether the group's last command row failed after it ran: the one
    /// failure `earlier_command_failures` leaves out. A row still running or
    /// refused before it ran is not one, even when the command before it
    /// failed.
    last_command_row_failed: bool = false,
    /// toolbox calls that open a tool or search for one, which read no file.
    tool_opens: usize = 0,
    toolbox_searches: usize = 0,
    subagent_calls: usize = 0,
    subagent_names: std.ArrayList([]const u8) = .empty,
    /// The subagents main sent a message to, each once; a stop, close, or
    /// status names a subagent without starting it.
    subagents_messaged: std.ArrayList([]const u8) = .empty,
    /// Reports and messages from subagents, which show as subagent calls
    /// that their details mark (src/core/subagent/reports.zig, Row).
    subagent_updates: usize = 0,
    subagent_waits: usize = 0,
    mcp_calls: usize = 0,
    opens: usize = 0,
    /// Calls that core counts as commands but that ran no shell command, such
    /// as a call to a tool spark no longer has.
    other_calls: usize = 0,

    fn addDistinct(list: *std.ArrayList([]const u8), scratch: std.mem.Allocator, value: []const u8) !void {
        for (list.items) |existing| if (std.mem.eql(u8, existing, value)) return;
        try list.append(scratch, value);
    }

    /// Adds `value` once, as the newest: a value already there moves to the
    /// end, so the list's order is the order of each value's latest call.
    fn addLatest(list: *std.ArrayList([]const u8), scratch: std.mem.Allocator, value: []const u8) !void {
        for (list.items, 0..) |existing, index| if (std.mem.eql(u8, existing, value)) {
            _ = list.orderedRemove(index);
            break;
        };
        try list.append(scratch, value);
    }

    fn observe(
        self: *StoryTally,
        scratch: std.mem.Allocator,
        entry: TranscriptEntry,
        detail: ?*const ToolDetailRecord,
    ) !void {
        const record = detail orelse return;
        if (record.fallback_disposition != null) return;
        // A denied, cancelled, or deferred call did not run, so the story
        // does not count it as work.
        if (record.outcome) |outcome| switch (outcome) {
            .denied, .cancelled => return,
            .deferred => {
                self.deferred += 1;
                return;
            },
            else => {},
        };
        const name = record.tool_name;
        const kind = record.activity_kind orelse return;
        // Another call that failed did not do its work, so the header counts
        // it only as a failure.
        if (kind != .command) if (record.outcome) |outcome| if (outcome == .failed) {
            self.other_failures += 1;
            return;
        };
        switch (kind) {
            .edit, .write => {
                self.change_calls += 1;
                if (record.outcome == null) self.changes_running += 1;
                if (kind == .write) self.write_calls += 1;
                if (storyArgString(scratch, record, "path")) |path| try addDistinct(&self.changed_paths, scratch, path);
                const phrase = try entryStatus(scratch, entry) orelse "";
                const totals = diffTotalsOfPhrase(phrase);
                self.diff.added += totals.added;
                self.diff.removed += totals.removed;
            },
            .command => {
                if (!isShellCommandCall(scratch, record)) {
                    if (record.outcome == .failed) self.other_failures += 1 else self.other_calls += 1;
                    return;
                }
                // A request the shell refused ran no command, so it counts
                // as another call that failed, not as a command.
                if (shellCallNeverRan(scratch, record)) {
                    self.other_failures += 1;
                    return;
                }
                const follow_up = isSessionFollowUp(scratch, record);
                if (!follow_up) {
                    self.commands += 1;
                } else if (storyArgString(scratch, record, "session_id")) |id| {
                    try addDistinct(&self.followed_sessions, scratch, id);
                } else {
                    self.unnamed_session_calls += 1;
                }
                if (record.outcome == null and record.command_process_presentation == null) {
                    if (!follow_up) self.commands_running += 1;
                    return;
                }
                if (!follow_up and try commandStillRunning(scratch, entry)) {
                    self.commands_still_running += 1;
                    return;
                }
                const failed = storyCommandFailed(record);
                if (failed) self.commands_failed += 1;
                self.last_command_failed = failed;
            },
            .read, .list => {
                if (std.mem.eql(u8, name, "read_file")) {
                    if (storyArgString(scratch, record, "path")) |path| try addDistinct(&self.read_paths, scratch, path) else self.unnamed_reads += 1;
                } else if (std.mem.eql(u8, name, "toolbox")) {
                    if (storyArgString(scratch, record, "open") != null) self.tool_opens += 1 else self.toolbox_searches += 1;
                } else if (std.mem.eql(u8, name, "web_search") or isProviderSearchName(name)) {
                    self.web_searches += 1;
                } else if (std.mem.eql(u8, name, "web_fetch")) {
                    self.web_reads += 1;
                } else if (try storySearchKey(scratch, record)) |key| {
                    try addDistinct(&self.search_keys, scratch, key);
                } else {
                    self.unkeyed_searches += 1;
                }
            },
            .subagent => {
                self.subagent_calls += 1;
                if (record.subagent_report) {
                    self.subagent_updates += 1;
                    return;
                }
                // Old records keep no arguments, so they say nothing more.
                if (!storyHasArgs(record)) return;
                if (storyArgString(scratch, record, "agent")) |agent| {
                    try addDistinct(&self.subagent_names, scratch, agent);
                    const action = storyArgString(scratch, record, "action") orelse "message";
                    if (std.mem.eql(u8, action, "message")) try addDistinct(&self.subagents_messaged, scratch, agent);
                } else if (storyArgString(scratch, record, "action")) |action| {
                    if (std.mem.eql(u8, action, "wait") or std.mem.eql(u8, action, "status")) self.subagent_waits += 1;
                }
            },
            .mcp => self.mcp_calls += 1,
            .open => self.opens += 1,
            .ask => {},
        }
    }

    fn sessionsFollowed(self: StoryTally) usize {
        return self.followed_sessions.items.len + self.unnamed_session_calls;
    }

    fn reads(self: StoryTally) usize {
        return self.read_paths.items.len + self.unnamed_reads;
    }

    fn changedFiles(self: StoryTally) usize {
        return if (self.changed_paths.items.len > 0) self.changed_paths.items.len else self.change_calls;
    }
};

/// Whether a command call ran a shell command. Core treats a tool name it
/// does not know, such as a tool an old session used, as a command
/// (src/core/tooling/tool_dispatch.zig, unregisteredActivityKind), but such a
/// call names no command, so the story counts it as another call.
fn isShellCommandCall(scratch: std.mem.Allocator, record: *const ToolDetailRecord) bool {
    if (record.activity_kind != .command) return false;
    if (record.command_display != null) return true;
    if (std.mem.eql(u8, record.tool_name, "shell") or std.mem.eql(u8, record.tool_name, "run_command")) return true;
    return storyArgString(scratch, record, "command") != null or storyArgString(scratch, record, "session_id") != null;
}

/// A shell call that sends input to a running session or stops it, rather
/// than running a command.
fn isSessionFollowUp(scratch: std.mem.Allocator, record: *const ToolDetailRecord) bool {
    const action = storyArgString(scratch, record, "action") orelse return false;
    return std.mem.eql(u8, action, "interact") or std.mem.eql(u8, action, "stop");
}

fn isProviderSearchName(name: []const u8) bool {
    return std.mem.eql(u8, name, "web_search_preview") or std.mem.eql(u8, name, "google_search");
}

fn pluralWord(count: usize, singular: []const u8, plural_form: []const u8) []const u8 {
    return if (count == 1) singular else plural_form;
}

/// Writes " +N -M" with the same accents the rows' diff counts use, then
/// returns to the header's own style.
fn writeDiffTotals(writer: *std.Io.Writer, diff: DiffTotals, style: SummaryStyle) !void {
    if (diff.added > 0) try writeDiffCount(writer, "+", diff.added, ui_render.diff_added_marker_style, style);
    if (diff.removed > 0) try writeDiffCount(writer, "-", diff.removed, ui_render.diff_removed_marker_style, style);
}

/// " +2", or with an accent, " <accent>+2<reset><text style>".
fn writeDiffCount(writer: *std.Io.Writer, sign: []const u8, count: usize, accent: []const u8, style: SummaryStyle) !void {
    try writer.writeByte(' ');
    try writer.writeAll(accent);
    try writeCount(writer, sign, count, if (accent.len == 0) "" else "\x1b[0m");
    if (accent.len > 0) try writer.writeAll(style.text_style);
}

/// Where the group's commands ended: ✗ when the latest finished command
/// failed, and ✓ when it passed and every command finished, so a command that
/// passed on a retry still ends its group with ✓. Other calls that failed show
/// as " · N failed" instead, so the mark never blames a command for them.
fn writeResultMark(writer: *std.Io.Writer, tally: StoryTally, style: SummaryStyle) !void {
    const latest_failed = tally.last_command_failed orelse return;
    if (latest_failed) {
        try writeFailureMark(writer, style);
    } else if (tally.commands_running == 0 and tally.commands_still_running == 0) {
        try writer.writeAll(" ✓");
    }
}

/// " ✗" in the failure style, then the text style again.
fn writeFailureMark(writer: *std.Io.Writer, style: SummaryStyle) !void {
    try writer.writeByte(' ');
    try writeInFailureStyle(writer, "✗", style);
}

/// `text` in the failure style, then the text style again.
fn writeInFailureStyle(writer: *std.Io.Writer, text: []const u8, style: SummaryStyle) !void {
    if (style.failure_style.len == 0) return writer.writeAll(text);
    try writer.writeAll(style.failure_style);
    try writer.writeAll(text);
    try writer.writeAll(style.reset_style);
    try writer.writeAll(style.text_style);
}

/// `text` in the failure style, in `scratch`.
fn inFailureStyle(scratch: std.mem.Allocator, text: []const u8, style: SummaryStyle) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(scratch);
    writeInFailureStyle(&out.writer, text, style) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// A story header in parts: what the group did, as verbs with no counts,
/// then how its commands ended and its calls' states. Each part is
/// terminal-safe text.
const StoryHeader = struct {
    /// "● Read files", the first part.
    lead: []u8,
    /// ", searched", ", ran commands", and ", and more" when a group did more
    /// kinds of work than the header names.
    parts: []const []const u8,
    /// " ✓" or " ✗" for the commands, or "".
    mark: []const u8,
    /// The part that names the commands, so the mark shows only while that
    /// part does; null when the lead names them.
    mark_part: ?usize,
    /// " · 1 failed", " · 2 denied", and the other states.
    states: []const u8,
    /// The states for a header whose mark does not show: a last command that
    /// failed counts in " · N failed", so the failure still shows.
    states_without_mark: []const u8,
};

/// The kinds of work a header names, in the order that breaks a tie.
const WorkKind = enum {
    edits,
    subagents,
    commands,
    sessions,
    mcp,
    web_pages,
    web_searches,
    tool_opens,
    toolbox_searches,
    reads,
    searches,
    opens,
    other_calls,
};

/// The most kinds of work a header names before ", and more".
const header_max_parts = 3;

/// How much of `kind` the group did, which orders the header's parts.
fn workAmount(tally: StoryTally, kind: WorkKind) usize {
    return switch (kind) {
        .edits => tally.changedFiles(),
        .subagents => if (tally.subagent_calls == 0)
            0
        else if (tally.subagents_messaged.items.len > 0)
            tally.subagents_messaged.items.len
        else if (tally.subagent_updates > 0)
            tally.subagent_updates
        else if (tally.subagent_names.items.len > 0)
            tally.subagent_names.items.len
        else
            tally.subagent_calls,
        .commands => tally.commands,
        // Input to and stops of the group's own commands are part of those
        // commands, so a group with commands does not name them again.
        .sessions => if (tally.commands > 0) 0 else tally.sessionsFollowed(),
        .mcp => tally.mcp_calls,
        .web_pages => tally.web_reads,
        .web_searches => tally.web_searches,
        .tool_opens => tally.tool_opens,
        .toolbox_searches => tally.toolbox_searches,
        .reads => tally.reads(),
        .searches => tally.search_keys.items.len + tally.unkeyed_searches,
        .opens => tally.opens,
        .other_calls => tally.other_calls,
    };
}

/// What the group did of `kind`, such as "read files" or "ran a command":
/// "a" for one, the plural for more, and no number.
fn workPhrase(tally: StoryTally, kind: WorkKind) []const u8 {
    const one = workAmount(tally, kind) == 1;
    return switch (kind) {
        .edits => blk: {
            const writes_only = tally.write_calls == tally.change_calls;
            if (tally.changes_running > 0) {
                if (writes_only) break :blk if (one) "writing a file" else "writing files";
                break :blk if (one) "editing a file" else "editing files";
            }
            if (writes_only) break :blk if (one) "wrote a file" else "wrote files";
            break :blk if (one) "edited a file" else "edited files";
        },
        .subagents => if (tally.subagents_messaged.items.len > 0)
            (if (one) "started a subagent" else "started subagents")
        else if (tally.subagent_updates > 0)
            (if (one) "got a subagent update" else "got subagent updates")
        else if (tally.subagent_waits == tally.subagent_calls)
            "waited for subagents"
        else if (one) "used a subagent" else "used subagents",
        .commands => if (tally.commands_running == tally.commands)
            (if (one) "running a command" else "running commands")
        else if (one) "ran a command" else "ran commands",
        .sessions => if (one) "checked a shell session" else "checked shell sessions",
        .mcp => if (one) "used an MCP tool" else "used MCP tools",
        .web_pages => if (one) "read a web page" else "read web pages",
        .web_searches => "searched the web",
        .tool_opens => if (one) "opened a tool" else "opened tools",
        .toolbox_searches => "searched the toolbox",
        .reads => if (one) "read a file" else "read files",
        .searches => "searched",
        .opens => if (one) "opened a file" else "opened files",
        .other_calls => if (one) "used a tool" else "used tools",
    };
}

/// "● Edited a file, ran commands ✓": what the group did, like a short
/// sentence, with no counts; its rows show how much. Edits come first, since
/// they are the change the group made, then the kind of work with the most
/// calls, and a tie goes to the kind earlier in WorkKind. Up to three kinds
/// show, then ", and more". The result mark says how the commands ended.
/// With `collapsed`, for a group whose rows are collapsed, the edits keep the
/// lines they added and removed, and a failure the turn ended on counts,
/// since no row shows them. Returns null when
/// the group has nothing the story can name, so the caller keeps the count
/// summary. The parts live in `scratch`.
fn formatStoryHeader(scratch: std.mem.Allocator, tally: StoryTally, summary: Summary, style: SummaryStyle, collapsed: bool) !?StoryHeader {
    var kinds: std.ArrayList(WorkKind) = .empty;
    for (std.enums.values(WorkKind)) |kind| {
        const amount = workAmount(tally, kind);
        if (amount == 0) continue;
        // Edits stay first; the rest go before the first kind with less work,
        // so equal amounts keep WorkKind's order.
        var at = kinds.items.len;
        if (kind != .edits) {
            while (at > 0 and kinds.items[at - 1] != .edits and workAmount(tally, kinds.items[at - 1]) < amount) at -= 1;
        }
        try kinds.insert(scratch, at, kind);
    }

    var lead: std.Io.Writer.Allocating = .init(scratch);
    try lead.writer.writeAll("● ");
    var parts: std.ArrayList([]const u8) = .empty;
    var lead_says_failed = false;
    // The mark says how the commands ended, so it shows only beside them:
    // not when ", and more" folds them in.
    var mark_shown = true;
    var mark_part: ?usize = null;
    if (kinds.items.len > 0) {
        const first = workPhrase(tally, kinds.items[0]);
        try lead.writer.writeByte(std.ascii.toUpper(first[0]));
        try lead.writer.writeAll(first[1..]);
        if (collapsed and kinds.items[0] == .edits) try writeDiffTotals(&lead.writer, tally.diff, style);
        const named = @min(kinds.items.len, header_max_parts);
        for (kinds.items[1..named]) |kind| {
            if (kind == .commands) mark_part = parts.items.len;
            try parts.append(scratch, try std.mem.concat(scratch, u8, &.{ ", ", workPhrase(tally, kind) }));
        }
        if (kinds.items.len > named) try parts.append(scratch, ", and more");
        for (kinds.items[named..]) |kind| if (kind == .commands) {
            mark_shown = false;
        };
    } else if (tally.other_failures > 0) {
        try writeCount(&lead.writer, "", tally.other_failures, pluralWord(tally.other_failures, " call failed", " calls failed"));
        lead_says_failed = true;
    } else if (tally.deferred > 0) {
        try lead.writer.writeAll(std.mem.trimEnd(u8, types.context_deferred_tool_status_label, ":"));
    } else {
        return null;
    }

    var mark: std.Io.Writer.Allocating = .init(scratch);
    if (mark_shown) try writeResultMark(&mark.writer, tally, style);
    // A failed call that is not a command was most often the model's own
    // mistake, which it works past, so the header does not count it; its
    // row still says it failed. A collapsed group shows no rows, so its
    // header counts the failures its turn ended on.
    const turn_ending: usize = if (collapsed) tally.turn_ending_failures else 0;
    const failed = if (lead_says_failed) 0 else tally.earlier_command_failures + turn_ending;
    const last_failed: usize = if (tally.last_command_row_failed) 1 else 0;
    // A count that shows counts the last command's failure too, so it
    // matches the failed rows; a last failure alone shows only as the mark.
    const states = try formatHeaderStates(scratch, if (failed > 0) failed + last_failed else 0, summary);
    const states_without_mark = try formatHeaderStates(scratch, failed + last_failed, summary);
    return .{
        .lead = lead.written(),
        .parts = parts.items,
        .mark = mark.written(),
        .mark_part = mark_part,
        .states = if (mark_shown) states else states_without_mark,
        .states_without_mark = states_without_mark,
    };
}

/// " · 1 failed · 2 denied" and the other states a header ends with.
fn formatHeaderStates(scratch: std.mem.Allocator, failed: usize, summary: Summary) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(scratch);
    try appendSegment(&out.writer, failed, "failed");
    try appendSegment(&out.writer, summary.completion_unreported, "unreported");
    try appendSegment(&out.writer, summary.not_executed, "not executed");
    try appendSegment(&out.writer, summary.timed_out, "timed out");
    try appendSegment(&out.writer, summary.denied, "denied");
    try appendSegment(&out.writer, summary.cancelled, "cancelled");
    return out.written();
}

/// Fits a story header to `cols`. Parts that do not fit drop from the end,
/// and " …" says the header goes on, so the first part and the states,
/// failures first, always show; the mark shows while the part that names the
/// commands does. When the first part and states alone are too wide, the
/// first part clips and the states stay; when they would take more than half
/// the row, the header clips from the right like any other summary. The text
/// lives in `scratch`.
fn clipStoryHeader(scratch: std.mem.Allocator, header: StoryHeader, cols: u16) ![]const u8 {
    var kept = header.parts.len;
    while (true) {
        const mark_shows = if (header.mark_part) |part| part < kept else true;
        const line = try std.mem.concat(scratch, u8, &.{
            header.lead,
            try std.mem.concat(scratch, u8, header.parts[0..kept]),
            if (kept < header.parts.len) " …" else "",
            if (mark_shows) header.mark else "",
            if (mark_shows) header.states else header.states_without_mark,
        });
        if (display_width.visibleWidthIgnoringAnsi(line) <= cols) return line;
        if (kept == 0) break;
        kept -= 1;
    }
    const tail = if (header.mark_part == null)
        try std.mem.concat(scratch, u8, &.{ header.mark, header.states })
    else
        header.states_without_mark;
    return clipKeepingTail(scratch, header.lead, tail, cols, "");
}

/// Clips `body` so `tail` still fits after it in `cols`, the way a row keeps
/// its diff counts: a merge note such as " ×3 · passed on the 3rd run" or a
/// result mark stays when a long command clips. When the tail would take more
/// than half the row, the whole line clips from the right like any other.
/// A clip inside a highlight ends in a reset, so `restyle`, the row's own
/// style, comes back before the tail. The text lives in `scratch`.
fn clipKeepingTail(scratch: std.mem.Allocator, body: []const u8, tail: []const u8, cols: u16, restyle: []const u8) ![]const u8 {
    const whole = try std.mem.concat(scratch, u8, &.{ body, tail });
    if (display_width.visibleWidthIgnoringAnsi(whole) <= cols) return whole;
    const tail_width = display_width.visibleWidthIgnoringAnsi(tail);
    if (tail_width * 2 > cols) return try clipSummary(scratch, whole, cols);
    const clipped = try clipSummary(scratch, body, cols - @as(u16, @intCast(tail_width)));
    const reset = std.mem.endsWith(u8, clipped, "\x1b[0m") and !std.mem.endsWith(u8, body, "\x1b[0m");
    return try std.mem.concat(scratch, u8, &.{ clipped, if (reset) restyle else "", tail });
}

/// How a call joins the row of an earlier call that does the same task.
const StoryRowKind = enum {
    /// Its own row.
    single,
    /// The same command again, one call after the other.
    command,
    /// The same shell session: its run, input, and stop.
    session,
    /// Every read of a file in the group, wherever it is: one row that names
    /// each file once.
    read,
    /// The same subagent: its messages, status, and close.
    subagent,
    /// A subagent wait or status that names no agent, keyed by its action.
    subagent_wait,
    /// Every search with the same tool in the group, wherever it is: one row
    /// that names each pattern once, and a single pattern's folders.
    search,
    /// Every edit or write of the same file in the group, wherever it is: one
    /// row that adds up their counts.
    edit,
    /// Different commands, one after the other, that share a label such as
    /// "Ran" and did not fail: one row that names their steps.
    commands,
    /// Every call of the same MCP tool in the group, wherever it is: one row
    /// that counts them.
    mcp,
};

const StoryIdentity = struct {
    kind: StoryRowKind = .single,
    key: []const u8 = "",
};

const StoryRow = struct {
    entry: TranscriptEntry,
    entry_id: u32,
    detail: ?*const ToolDetailRecord,
    identity: StoryIdentity,
    count: usize = 1,
    /// How many of the calls that share the row failed.
    failures: usize = 0,
    /// The folders a search row looked in, each once, in the order of its
    /// calls; "" for a search that named none.
    search_paths: std.ArrayList([]const u8) = .empty,
    /// The calls of a `.commands` row, in order.
    combined: std.ArrayList(*const ToolDetailRecord) = .empty,
    /// The files a `.read` row read, or the patterns a `.search` row looked
    /// for, each once, in the order of their first call.
    names: std.ArrayList([]const u8) = .empty,
    /// The counts of an `.edit` row's calls, added up.
    diff: DiffTotals = .{},
    /// How many of an `.edit` row's calls were writes.
    writes: usize = 0,
    /// Which try the row's latest call was, when the model repeated a call
    /// that failed and this one completed; 0 otherwise.
    tries: usize = 0,
    /// Where the row's latest call is in the transcript's entries.
    status_index: usize = 0,
    /// Whether the row's latest call failed as the last call of a turn that
    /// has ended, so the turn ended on it.
    ends_turn: bool = false,
    /// The shell session a `.commands` row's run started, once a later call
    /// to the session joined the row; "" otherwise.
    session: []const u8 = "",
    /// The row's latest call that returned while its command ran on, which
    /// the first later call to its session joins; null when none did.
    background: ?*const ToolDetailRecord = null,
};

/// The name a call adds to a `.read` or `.search` row: the file's path, or
/// the pattern after the search key's tool name.
fn storyRowName(identity: StoryIdentity) ?[]const u8 {
    return switch (identity.kind) {
        .read => identity.key,
        .search => if (findByte(identity.key, 0)) |at| identity.key[at + 1 ..] else identity.key,
        else => null,
    };
}

/// The search tool of a `.search` row's key, which rows for the same tool
/// share.
fn storySearchTool(key: []const u8) []const u8 {
    return if (findByte(key, 0)) |at| key[0..at] else key;
}

/// Whether a row names several files or patterns, so its text lists them.
fn rowListsNames(row: *const StoryRow) bool {
    return (row.identity.kind == .read or row.identity.kind == .search) and row.names.items.len > 1;
}

/// The label a command row's phrase puts before its command, such as "Ran "
/// or "Running ". Null when the phrase does not end with the command.
fn commandRowLabel(scratch: std.mem.Allocator, entry: TranscriptEntry, detail: ?*const ToolDetailRecord) !?[]const u8 {
    const record = detail orelse return null;
    if (record.activity_kind != .command) return null;
    const display = record.command_display orelse return null;
    const status = try entryStatus(scratch, entry) orelse return null;
    const phrase = try reprojectTruncatedCommandPhrase(scratch, status, record) orelse status;
    if (display.len == 0 or phrase.len <= display.len or !std.mem.endsWith(u8, phrase, display)) return null;
    const label = phrase[0 .. phrase.len - display.len];
    return if (label[label.len - 1] == ' ') label else null;
}

/// Whether a command call joins the row before it as one more step: both
/// share a label, neither failed, and the row is not a repeat of one command,
/// so a failure, its reason line, and "×3" stay on rows of their own.
fn joinsCommandRow(scratch: std.mem.Allocator, last: *const StoryRow, entry: TranscriptEntry, detail: ?*const ToolDetailRecord) !bool {
    if (detail == null or storyCallFailed(detail)) return false;
    switch (last.identity.kind) {
        .commands => {},
        .command => if (last.count != 1 or last.failures != 0 or storyCallFailed(last.detail)) return false,
        else => return false,
    }
    const label = try commandRowLabel(scratch, entry, detail) orelse return false;
    const last_label = try commandRowLabel(scratch, last.entry, last.detail) orelse return false;
    // Commands that ran or still run share a row, so a call still running
    // does not show on a row of its own first and then fold into this one
    // when it ends. One that ran does not join a row whose latest command
    // returned while it ran on: the row's label and mark come from its latest
    // call, so the row would say that command ran.
    if (std.mem.eql(u8, label, last_label)) return true;
    if (!ranFamily(label) or !ranFamily(last_label)) return false;
    return !(std.mem.eql(u8, label, "Ran ") and std.mem.eql(u8, last_label, still_running_label ++ " "));
}

/// Whether `label` is what a command's row says while it runs, after its
/// call returned while it ran on, or once it ran. Under joinsCommandRow, two
/// calls with such labels that do not share a row never come to share one
/// as their labels change, so no call shows on a row of its own and then
/// folds into another.
fn ranFamily(label: []const u8) bool {
    return std.mem.eql(u8, label, "Ran ") or std.mem.eql(u8, label, "Running ") or
        std.mem.eql(u8, label, still_running_label ++ " ");
}

/// Whether `a` and `b` name the same file, where one may be the other's end
/// after a "/", such as "src/main.zig" and "/w/src/main.zig".
fn sameFilePath(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const long, const short = if (a.len > b.len) .{ a, b } else .{ b, a };
    return short.len > 0 and std.mem.endsWith(u8, long, short) and long[long.len - short.len - 1] == '/';
}

/// Whether a call of this tool joins a row by one of its arguments, such as
/// a read by its path or a subagent call by its agent or its wait, so a call
/// whose row is its own was still waiting for that argument.
fn joinsByArgument(record: *const ToolDetailRecord) bool {
    const names = [_][]const u8{ "read_file", "grep_files", "glob_files", "edit_file", "write_file", "subagent" };
    for (names) |name| if (std.mem.eql(u8, record.tool_name, name)) return true;
    return false;
}

/// Whether a streaming call's row would say nothing yet: its arguments
/// still stream in, and its status is a bare verb, such as "Reading" or
/// "Searching", with no target after it. A call that has started keeps its
/// row, whatever its status says.
fn saysNothingYet(scratch: std.mem.Allocator, entry: TranscriptEntry, record: *const ToolDetailRecord) !bool {
    if (!record.streaming or record.outcome != null or storyHasArgs(record)) return false;
    const phrase = std.mem.trim(u8, try entryStatus(scratch, entry) orelse return false, " ");
    return phrase.len > 0 and std.mem.findScalar(u8, phrase, ' ') == null;
}

/// The row a running call that does not have the arguments its row depends
/// on yet will most likely join, so it waits there instead of showing on a
/// row of its own that folds away when they arrive: the read row for a read,
/// the row of searches with its tool for a search, the row of its file for
/// an edit or write whose status names it, the latest row of its own tool
/// for a read, search, edit, or write that names nothing yet or a subagent
/// call whose status is a bare verb, the row of its agent for a subagent
/// call whose agent has streamed in, and the row right before it for a
/// command that follows commands. When it ends up on another row, that row
/// is new, so the group only grows. Null when it likely gets its own row.
fn pendingCallRow(scratch: std.mem.Allocator, rows: []StoryRow, entry: TranscriptEntry, record: *const ToolDetailRecord) !?*StoryRow {
    const name = record.tool_name;
    if (std.mem.eql(u8, name, "read_file")) {
        for (rows) |*row| if (row.identity.kind == .read) return row;
    } else if (std.mem.eql(u8, name, "grep_files") or std.mem.eql(u8, name, "glob_files")) {
        for (rows) |*row| if (row.identity.kind == .search and std.mem.eql(u8, storySearchTool(row.identity.key), name)) return row;
    } else if (std.mem.eql(u8, name, "subagent")) {
        // A call whose agent has streamed in, while its message still does,
        // waits in that agent's row. The first call to an agent shows on its
        // own row at the end, so the group only grows.
        if (tooling_presentation.subagentStreamedAgent(record.arguments_json orelse "")) |agent| {
            for (rows) |*row| if (row.identity.kind == .subagent and std.mem.eql(u8, row.identity.key, agent)) return row;
            return null;
        }
        // Otherwise only a bare verb, such as "Managing", says the call's
        // action or agent has not arrived. A status that says more, such as
        // "Subagent working · inspect auth", is its own row's.
        const phrase = std.mem.trim(u8, try entryStatus(scratch, entry) orelse "", " ");
        if (std.mem.findScalar(u8, phrase, ' ') != null) return null;
    } else if (std.mem.eql(u8, name, "edit_file") or std.mem.eql(u8, name, "write_file")) {
        // A status that already names its file, such as "Editing main.zig",
        // waits only in that file's row, so it shows which file it changes.
        const phrase = try entryStatus(scratch, entry) orelse "";
        if (std.mem.findScalar(u8, phrase, ' ')) |space| {
            const target = phrase[space + 1 ..];
            for (rows) |*row| if (row.identity.kind == .edit and sameFilePath(row.identity.key, target)) return row;
            return null;
        }
    }
    if (joinsByArgument(record)) {
        var index = rows.len;
        while (index > 0) {
            index -= 1;
            const row = &rows[index];
            const row_record = row.detail orelse continue;
            // A subagent call joins its agent's row even after a failed
            // call there, such as a retry, so it waits there too.
            if (std.mem.eql(u8, row_record.tool_name, name) and (!storyCallFailed(row.detail) or std.mem.eql(u8, name, "subagent"))) return row;
        }
        return null;
    }
    if (rows.len == 0) return null;
    const last = &rows[rows.len - 1];
    const last_record = last.detail orelse return null;
    if (!std.mem.eql(u8, last_record.tool_name, name) or storyCallFailed(last.detail)) return null;
    return switch (last.identity.kind) {
        .command, .commands => last,
        else => null,
    };
}

/// The steps of a `.commands` row's calls, each once where it last ran, in
/// that order. The newest few show and the older ones are counted before
/// them, so the last step is the newest call's, which may still run.
fn combinedCommandSteps(scratch: std.mem.Allocator, records: []const *const ToolDetailRecord) !ShortCommand {
    var all: std.ArrayList([]const u8) = .empty;
    for (records) |record| {
        const source = storyArgString(scratch, record, "command") orelse record.command_display orelse continue;
        var steps: std.ArrayList([]const u8) = .empty;
        var raw_steps: usize = 0;
        if (try collectShortSteps(scratch, source, &steps, &raw_steps, 0) and steps.items.len > 0) {
            for (steps.items) |step| try StoryTally.addLatest(&all, scratch, step);
        } else {
            const first = std.mem.trim(u8, source, " \t\r\n");
            if (first.len > 0) try StoryTally.addLatest(&all, scratch, first[0 .. std.mem.findAny(u8, first, " \t\r\n") orelse first.len]);
        }
    }
    const kept = @min(all.items.len, short_command_max_steps);
    return .{ .steps = all.items[all.items.len - kept ..], .more = 0, .earlier = all.items.len - kept };
}

const link_close = "\x1b]8;;\x1b\\";

/// Writes `path` as the path of a file URL: every byte outside the unreserved
/// set and "/" is percent-encoded, so the link carries no control bytes.
fn writeFileUrlPath(writer: *std.Io.Writer, path: []const u8) !void {
    for (path) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '/' or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try writer.writeByte(byte);
        } else {
            const hex = "0123456789ABCDEF";
            try writer.writeAll(&[_]u8{ '%', hex[byte >> 4], hex[byte & 0xf] });
        }
    }
}

/// Whether `text` ends inside a link: its last link sequence opens one.
fn endsInsideLink(text: []const u8) bool {
    const last = std.mem.findLast(u8, text, "\x1b]8;") orelse return false;
    return !std.mem.startsWith(u8, text[last..], link_close);
}

fn storyArgInt(scratch: std.mem.Allocator, record: *const ToolDetailRecord, key: []const u8) ?i64 {
    const json = record.arguments_json orelse return null;
    return switch (jsonField(scratch, json, key) orelse return null) {
        .integer => |value| value,
        else => null,
    };
}

fn withoutSuffix(text: []const u8, suffix: []const u8) ?[]const u8 {
    if (text.len <= suffix.len or !std.mem.endsWith(u8, text, suffix)) return null;
    return text[0 .. text.len - suffix.len];
}

/// One way core words a subagent row, and the story's words for it. A lead
/// that starts with `match`, for a `match` that ends with a space, or ends
/// with it, for one that starts with a space, reads as `reads` with the rest
/// of the lead, which names the subagent, in place of its "*". A table, so
/// every wording shares one piece of code.
const SubagentRewording = struct { match: []const u8, reads: []const u8 };

/// The rows of a message to a subagent, in the order they are tried.
const message_rewordings = [_]SubagentRewording{
    .{ .match = "sent to ", .reads = "Messaged *" },
    .{ .match = " busy; message not sent", .reads = "Couldn't message * (busy)" },
    .{ .match = " failed", .reads = "Couldn't message *" },
    .{ .match = " interrupted", .reads = "Cancelled message to *" },
    .{ .match = " feedback not applied", .reads = "Feedback to * not applied" },
    .{ .match = " feedback queued", .reads = "Sent feedback to *" },
    .{ .match = " feedback applied", .reads = "Sent feedback to *" },
};

/// The rows of a report or a message a subagent sent to main.
const report_rewordings = [_]SubagentRewording{
    .{ .match = "from ", .reads = "Message from *" },
    .{ .match = "report from ", .reads = "Report from *" },
    .{ .match = " completed", .reads = "* finished" },
    .{ .match = " cancelled", .reads = "* was cancelled" },
    .{ .match = " interrupted", .reads = "* was interrupted" },
    .{ .match = " lost", .reads = "* was lost" },
};

/// The first rewording in `rewordings` that fits `lead`, or null. A start
/// may leave no name; an end must leave one.
fn rewordSubagentLead(scratch: std.mem.Allocator, lead: []const u8, rewordings: []const SubagentRewording) !?[]const u8 {
    for (rewordings) |rewording| {
        const match = rewording.match;
        const name = if (match[match.len - 1] == ' ')
            (if (std.mem.startsWith(u8, lead, match)) lead[match.len..] else null)
        else
            withoutSuffix(lead, match);
        if (name) |agent| {
            const star = findByte(rewording.reads, '*').?;
            return try std.mem.concat(scratch, u8, &.{ rewording.reads[0..star], agent, rewording.reads[star + 1 ..] });
        }
    }
    return null;
}

/// A subagent row by its action and the subagent's name, such as
/// "Messaged reviewer" or "reviewer finished", without the message or the
/// reply, which Ctrl+O shows. It rewords core's row text, so a state core
/// adds later still shows, in core's words, without its message. Null for
/// other rows.
fn subagentRowPhrase(scratch: std.mem.Allocator, phrase: []const u8, record: *const ToolDetailRecord) !?[]const u8 {
    if (!std.mem.eql(u8, record.tool_name, "subagent")) return null;
    const lead = if (std.mem.find(u8, phrase, " · ")) |at| phrase[0..at] else phrase;
    if (lead.len == 0) return null;
    const action = storyArgString(scratch, record, "action");
    if (action) |name| if (std.mem.eql(u8, name, "message")) {
        // "reviewer working", "reviewer still running": the subagent works.
        return try rewordSubagentLead(scratch, lead, &message_rewordings) orelse lead;
    };
    // A report or a message a subagent sent to main.
    if (action == null) return try rewordSubagentLead(scratch, lead, &report_rewordings) orelse lead;
    // A wait, status, stop, or close leads with its verb, which takes a
    // capital like "Ran" and "Read".
    const verbs = [_][]const u8{ "waited ", "waiting ", "checked ", "checking ", "stopped ", "stopping ", "closed ", "closing ", "couldn't " };
    for (verbs) |verb| if (std.mem.startsWith(u8, lead, verb)) {
        const capital = try scratch.dupe(u8, lead);
        capital[0] = std.ascii.toUpper(capital[0]);
        return capital;
    };
    return lead;
}

/// A read row by the file's name and the lines it read, such as
/// "Read orchestrator.zig L15-200", in place of the whole path. An absolute
/// path makes the name a file link, so Cmd+click opens the file. Null when
/// the phrase does not end with the path the call read.
fn readRowPhrase(scratch: std.mem.Allocator, phrase: []const u8, row: *const StoryRow, merged: bool) !?[]const u8 {
    const record = row.detail orelse return null;
    if (!std.mem.eql(u8, record.tool_name, "read_file")) return null;
    const path = storyArgString(scratch, record, "path") orelse return try pendingPathPhrase(scratch, phrase, record);
    // Core writes the path terminal-safe, so a control byte in it shows
    // escaped.
    const shown = try terminalSafeText(scratch, path);
    if (phrase.len <= shown.len or !std.mem.endsWith(u8, phrase, shown)) return null;
    const label = phrase[0 .. phrase.len - shown.len];
    if (label[label.len - 1] != ' ') return null;
    if (std.Io.Dir.path.basename(path).len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(scratch);
    try out.writer.writeAll(label);
    try writeFileName(&out.writer, path);
    if (!merged) {
        // "L15-200" for a start and a count, "L15+" for a start alone, and
        // "L1-200" for a count alone.
        const start = storyArgInt(scratch, record, "start_line") orelse 0;
        const count = storyArgInt(scratch, record, "line_count") orelse 0;
        if (start > 1 or count > 0) {
            const first = if ((start > 0 and count > 0) or start > 1) start else 1;
            try out.writer.print(" L{d}", .{first});
            // The model chooses both numbers, so their sum saturates.
            if (count > 0) try out.writer.print("-{d}", .{first +| (count - 1)}) else try out.writer.writeByte('+');
        }
    }
    return out.written();
}

/// An edit or write row by the file's name and its counts, such as
/// "Edited main.zig +10/-3", in place of the whole path. The name links to
/// the file like a read row's. A row for several changes to one file adds up
/// their counts, even when core names the file another way, such as a long
/// path cut short. Null for a row of one call whose phrase does not end with
/// the path it changed and its counts.
fn editRowPhrase(scratch: std.mem.Allocator, phrase: []const u8, row: *const StoryRow) !?[]const u8 {
    if (!entryShowsDiffStats(row.detail)) return null;
    const path = storyArgString(scratch, row.detail.?, "path") orelse return try pendingPathPhrase(scratch, phrase, row.detail.?);
    // Core writes the path terminal-safe, so a control byte in it shows
    // escaped.
    const shown = try terminalSafeText(scratch, path);
    const named = if (diffStatsSuffixStart(phrase)) |at| phrase[0..at] else phrase;
    const merged = row.identity.kind == .edit and row.count > 1;
    const label = if (named.len > shown.len and std.mem.endsWith(u8, named, shown) and named[named.len - shown.len - 1] == ' ')
        named[0 .. named.len - shown.len]
    else if (merged)
        // The row's calls are completed or running changes, whose verb is
        // one word, such as "Edited".
        if (findByte(named, ' ')) |space| named[0 .. space + 1] else return null
    else
        return null;
    const totals = if (merged) row.diff else diffTotalsOfPhrase(phrase);
    var out: std.Io.Writer.Allocating = .init(scratch);
    try out.writer.writeAll(label);
    try writeFileName(&out.writer, path);
    if (totals.added > 0) try out.writer.print(" +{d}", .{totals.added});
    if (totals.removed > 0) try out.writer.print("{s}-{d}", .{ if (totals.added > 0) "/" else " ", totals.removed });
    return out.written();
}

/// A running read, edit, or write row by the file's name before the call's
/// arguments arrive, as while the model still streams them: its phrase
/// already names the path after its one-word verb, such as "Reading
/// /src/main.zig". Null once the call has arguments, which name the path
/// instead, or an outcome, whose phrase can end in counts, and when the
/// phrase names no folder to leave out.
fn pendingPathPhrase(scratch: std.mem.Allocator, phrase: []const u8, record: *const ToolDetailRecord) !?[]const u8 {
    if (record.outcome != null or storyHasArgs(record)) return null;
    const space = findByte(phrase, ' ') orelse return null;
    const path = phrase[space + 1 ..];
    if (findByte(path, '/') == null or std.Io.Dir.path.basename(path).len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(scratch);
    try out.writer.writeAll(phrase[0 .. space + 1]);
    try writeFileName(&out.writer, path);
    return out.written();
}

/// Extensions of files that macOS runs, installs, or follows when one is
/// opened, so a Cmd+click on a link to one would act on it.
const runnable_extensions = [_][]const u8{
    ".app",     ".command", ".tool",   ".terminal", ".workflow",    ".action",
    ".pkg",     ".mpkg",    ".scpt",   ".scptd",    ".applescript", ".jar",
    ".fileloc", ".inetloc", ".webloc", ".prefpane", ".saver",       ".kext",
};

/// Whether a link may open `name`. A file with no extension can be a
/// program, which opens in Terminal and runs, and the transcript cannot tell
/// which files are programs, so only a file whose extension is not a
/// runnable kind gets a link.
fn linkOpensSafely(name: []const u8) bool {
    const extension = std.Io.Dir.path.extension(name);
    if (extension.len == 0) return false;
    for (runnable_extensions) |runnable| if (std.ascii.eqlIgnoreCase(extension, runnable)) return false;
    return true;
}

/// A file by its name, in place of its whole path. An absolute path to a
/// file that opens safely makes the name a file link, so Cmd+click opens
/// the file. A path with no name shows whole. The text is terminal-safe.
fn writeFileName(writer: *std.Io.Writer, path: []const u8) !void {
    const base = std.Io.Dir.path.basename(path);
    const name = if (base.len == 0) path else base;
    const link = base.len > 0 and std.Io.Dir.path.isAbsolute(path) and linkOpensSafely(base);
    if (link) {
        try writer.writeAll("\x1b]8;;file://");
        try writeFileUrlPath(writer, path);
        try writer.writeAll("\x1b\\");
    }
    try writeTerminalSafe(writer, name);
    if (link) try writer.writeAll(link_close);
}

/// The text of a row that names several files or patterns: its past verb,
/// how many older names do not fit, then the newest names that fit in `cols`
/// after the row's two-column connector, oldest first, such as
/// "Read +3, c.zig, d.zig". The last name is the newest call's, which may
/// still run. At least one name shows; the row clips it when even that one
/// is too wide. Ctrl+O shows every call.
fn nameListRowText(scratch: std.mem.Allocator, row: *const StoryRow, cols: u16) !StoryRowText {
    const is_read = row.identity.kind == .read;
    const tool = if (is_read) "read_file" else storySearchTool(row.identity.key);
    // The row stands for every call it names, so it says what they did, even
    // while the newest still runs.
    const verb = if (is_read) "Read" else if (std.mem.eql(u8, tool, "glob_files")) "Matched" else "Searched";

    const budget: usize = if (cols > 2) cols - 2 else 1;
    const names = row.names.items;
    const pieces = try scratch.alloc([]const u8, names.len);
    for (names, pieces) |name, *piece| {
        var text: std.Io.Writer.Allocating = .init(scratch);
        if (is_read) try writeFileName(&text.writer, name) else try writeTerminalSafe(&text.writer, name);
        piece.* = text.written();
    }
    // The most names, counted from the newest, whose row fits.
    const head_width = verb.len + 1;
    var shown: usize = 0;
    var names_width: usize = 0;
    while (shown < names.len) {
        const piece_width = display_width.visibleWidthIgnoringAnsi(pieces[names.len - shown - 1]) + @as(usize, if (shown > 0) 2 else 0);
        const left_out = names.len - shown - 1;
        const count_width: usize = if (left_out == 0) 0 else display_width.visibleWidthIgnoringAnsi(try countNote(scratch, "+", left_out, ", "));
        if (shown > 0 and head_width + count_width + names_width + piece_width > budget) break;
        names_width += piece_width;
        shown += 1;
    }

    var body: std.Io.Writer.Allocating = .init(scratch);
    try body.writer.writeAll(verb);
    try body.writer.writeByte(' ');
    if (shown < names.len) try writeCount(&body.writer, "+", names.len - shown, ", ");
    for (pieces[names.len - shown ..], 0..) |piece, position| {
        if (position > 0) try body.writer.writeAll(", ");
        try body.writer.writeAll(piece);
    }
    return .{ .display = body.written(), .body = body.written(), .suffix = "" };
}

/// The key that joins searches for the same pattern with the same tool,
/// wherever they look. Null for other calls.
fn storySearchKey(scratch: std.mem.Allocator, record: *const ToolDetailRecord) !?[]const u8 {
    const name = record.tool_name;
    if (!std.mem.eql(u8, name, "grep_files") and !std.mem.eql(u8, name, "glob_files")) return null;
    const pattern = storyArgString(scratch, record, "pattern") orelse return null;
    return try std.mem.concat(scratch, u8, &.{ name, "\x00", pattern });
}

fn addSearchPath(scratch: std.mem.Allocator, row: *StoryRow, detail: ?*const ToolDetailRecord) !void {
    if (row.identity.kind != .search) return;
    const record = detail orelse return;
    const path = storyArgString(scratch, record, "path") orelse "";
    const trimmed = std.mem.trimEnd(u8, path, "/");
    try StoryTally.addLatest(&row.search_paths, scratch, if (trimmed.len == 0 and path.len > 0) "/" else trimmed);
}

/// How many leading parts two paths share, split at "/".
fn sharedPathParts(a: []const u8, b: []const u8) usize {
    var a_parts = std.mem.splitScalar(u8, a, '/');
    var b_parts = std.mem.splitScalar(u8, b, '/');
    var count: usize = 0;
    while (a_parts.next()) |a_part| {
        const b_part = b_parts.next() orelse break;
        if (!std.mem.eql(u8, a_part, b_part)) break;
        count += 1;
    }
    return count;
}

/// A folder by the part of its path after the `shared` leading parts. The
/// shared folder itself shows by its last part, and no path shows as ".".
fn folderName(path: []const u8, shared: usize) []const u8 {
    if (path.len == 0) return ".";
    var rest = path;
    var skipped: usize = 0;
    while (skipped < shared) : (skipped += 1) {
        const slash = findByte(rest, '/') orelse {
            rest = "";
            break;
        };
        rest = rest[slash + 1 ..];
    }
    if (rest.len > 0) return rest;
    const last = std.mem.findScalarLast(u8, path, '/') orelse return path;
    return if (last + 1 < path.len) path[last + 1 ..] else path;
}

/// Names the folders of a search row by the part of each path that differs
/// from the others, so "/w/reviews" and "/w/docs" are "reviews, docs". The
/// newest three show, after how many older ones do not, such as
/// "+2, c, d, e". Every name is terminal-safe.
fn searchFolderNames(scratch: std.mem.Allocator, paths: []const []const u8) ![]const u8 {
    var shared: usize = std.math.maxInt(usize);
    for (paths[1..]) |path| shared = @min(shared, sharedPathParts(paths[0], path));
    var out: std.Io.Writer.Allocating = .init(scratch);
    const shown = @min(paths.len, short_command_max_steps);
    if (paths.len > shown) try writeCount(&out.writer, "+", paths.len - shown, ", ");
    for (paths[paths.len - shown ..], 0..) |path, position| {
        if (position > 0) try out.writer.writeAll(", ");
        try writeTerminalSafe(&out.writer, folderName(path, shared));
    }
    return out.written();
}

noinline fn storyRowCallFailed(scratch: std.mem.Allocator, detail: ?*const ToolDetailRecord) bool {
    const record = detail orelse return false;
    return isShellCommandCall(scratch, record) and storyCallFailed(detail) and !shellCallNeverRan(scratch, record);
}

/// Whether a shell call failed before it ran its command because its request
/// was wrong, such as one that set both a profile and a shell. That is the
/// model's own mistake, not a command that failed, and it reads as one.
fn shellCallNeverRan(scratch: std.mem.Allocator, record: *const ToolDetailRecord) bool {
    if (record.outcome != .failed or !isShellCommandCall(scratch, record)) return false;
    const result = record.result orelse return false;
    const correction = tool_result_errors.inspectTerminalActionFieldCorrection(scratch, result) catch return false;
    return correction != null;
}

/// Why a shell call never ran, as core's status says it, such as
/// "2 invalid fields". Null when its result names no wrong field.
fn neverRanReason(scratch: std.mem.Allocator, record: *const ToolDetailRecord) !?[]const u8 {
    const result = record.result orelse return null;
    const correction = tool_result_errors.inspectTerminalActionFieldCorrection(scratch, result) catch return null;
    const count = (correction orelse return null).invalid_field_count;
    if (count == 0) return null;
    return try countNote(scratch, "", count, if (count == 1) " invalid field" else " invalid fields");
}

/// The key under which a shell call repeats one that never ran: the short
/// form of its command, so a fixed request for the same steps counts as its
/// retry even when the model also reworded the command.
fn shellRetryKey(scratch: std.mem.Allocator, record: *const ToolDetailRecord) !?[]const u8 {
    const command = storyArgString(scratch, record, "command") orelse record.command_display orelse return null;
    if (std.mem.trim(u8, command, " \t\r\n").len == 0) return null;
    const short = try shortCommand(scratch, command) orelse command;
    return try std.mem.concat(scratch, u8, &.{ "shell\x00", short });
}

/// A running toolbox call's identity by the MCP tool its status names, such
/// as "Running MCP mcp_x", while its arguments, which name the tool, have
/// not arrived, so it joins that tool's row at once instead of showing on a
/// row of its own that folds into it later.
fn streamingToolboxIdentity(scratch: std.mem.Allocator, entry: TranscriptEntry, detail: ?*const ToolDetailRecord, identity: StoryIdentity) !StoryIdentity {
    if (identity.kind != .mcp) return identity;
    const record = detail orelse return identity;
    if (record.outcome != null or !std.mem.eql(u8, record.tool_name, "toolbox")) return identity;
    if (storyArgString(scratch, record, "run") != null) return identity;
    const phrase = try entryStatus(scratch, entry) orelse return identity;
    const prefix = tooling_presentation.mcp_running_label ++ " ";
    if (!std.mem.startsWith(u8, phrase, prefix)) return identity;
    const name = std.mem.trim(u8, phrase[prefix.len..], " \t\r\n");
    if (name.len == 0) return identity;
    return .{ .kind = .mcp, .key = name };
}

/// A running subagent call's identity by the agent its status names, such
/// as "Managing reviewer", while its arguments, which name the agent, have
/// not arrived or do not parse yet, so a second message to an agent joins
/// that agent's row at once instead of showing on a row of its own that
/// folds into it later. Only a status of one verb and one name counts, so
/// "Subagent working · inspect auth" keeps its own row.
fn streamingSubagentIdentity(scratch: std.mem.Allocator, entry: TranscriptEntry, detail: ?*const ToolDetailRecord, identity: StoryIdentity) !StoryIdentity {
    if (identity.kind != .single) return identity;
    const record = detail orelse return identity;
    if (record.outcome != null or !std.mem.eql(u8, record.tool_name, "subagent")) return identity;
    if (storyArgString(scratch, record, "agent") != null) return identity;
    const phrase = std.mem.trim(u8, try entryStatus(scratch, entry) orelse return identity, " \t\r\n");
    const space = std.mem.findScalar(u8, phrase, ' ') orelse return identity;
    const name = phrase[space + 1 ..];
    if (name.len == 0 or std.mem.findAny(u8, name, " \t") != null) return identity;
    return .{ .kind = .subagent, .key = name };
}

fn storyIdentity(scratch: std.mem.Allocator, detail: ?*const ToolDetailRecord) !StoryIdentity {
    const record = detail orelse return .{};
    // A deferred call waits for project instructions and has not run, so it
    // keeps its own row instead of counting as a run of the same command.
    if (record.outcome == .deferred) return .{};
    const kind = record.activity_kind orelse return .{};
    switch (kind) {
        .command => {
            // A denied or cancelled command did not run, so it keeps its own
            // row instead of counting as a run of the same command. A failed
            // run still joins, so a row can say "passed on the 3rd run".
            if (record.outcome) |outcome| if (outcome == .denied or outcome == .cancelled) return .{};
            if (shellCallNeverRan(scratch, record)) return .{};
            if (storyArgString(scratch, record, "session_id")) |id| return .{ .kind = .session, .key = id };
            if (record.result) |result| if (jsonField(scratch, result, "session_id")) |field| switch (field) {
                .string => |id| if (id.len > 0) return .{ .kind = .session, .key = id },
                else => {},
            };
            const command = storyArgString(scratch, record, "command") orelse record.command_display orelse "";
            if (command.len > 0) return .{ .kind = .command, .key = command };
            return .{};
        },
        .read, .list => {
            // A read or search that failed, was denied, or was cancelled
            // keeps its own row, so what happened to it shows. One still
            // running joins the row it shares.
            if (storyCallFailed(detail)) return .{};
            if (record.outcome) |outcome| if (outcome != .completed) return .{};
            if (try storySearchKey(scratch, record)) |key| return .{ .kind = .search, .key = key };
            if (kind != .read or !std.mem.eql(u8, record.tool_name, "read_file")) return .{};
            const path = storyArgString(scratch, record, "path") orelse return .{};
            return .{ .kind = .read, .key = path };
        },
        .edit, .write => {
            // A change that failed, was denied, or was cancelled keeps its
            // own row, so what happened to it shows. One still running joins
            // the file's row, where it stays when it completes.
            if (record.outcome) |outcome| if (outcome != .completed) return .{};
            if (!entryShowsDiffStats(detail)) return .{};
            const path = storyArgString(scratch, record, "path") orelse return .{};
            return .{ .kind = .edit, .key = path };
        },
        .mcp => {
            // A call that failed, was denied, or was cancelled keeps its own
            // row, so what happened to it shows. One still running joins the
            // row it shares.
            if (storyCallFailed(detail)) return .{};
            if (record.outcome) |outcome| if (outcome != .completed) return .{};
            return .{ .kind = .mcp, .key = storyArgString(scratch, record, "run") orelse record.tool_name };
        },
        .subagent => {
            if (storyArgString(scratch, record, "agent")) |agent| return .{ .kind = .subagent, .key = agent };
            // A report row carries no call; only a bare wait or status
            // joins other subagent rows.
            const action = storyArgString(scratch, record, "action") orelse return .{};
            if (std.mem.eql(u8, action, "wait") or std.mem.eql(u8, action, "status")) return .{ .kind = .subagent_wait, .key = action };
            return .{};
        },
        else => return .{},
    }
}

/// The failed calls of a group that the model fixed at once, and the call
/// that fixed each run of them.
const StoryRetries = struct {
    /// Failed calls that the next call repeated and completed. They get no
    /// row and no count; Ctrl+O still shows them.
    fixed: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// The call that completed after such failures, by entry id, and which
    /// try it was.
    tries: std.AutoHashMapUnmanaged(u32, usize) = .empty,
};

fn collectStoryRetries(
    scratch: std.mem.Allocator,
    entries: []const TranscriptEntry,
    status_indices: []const usize,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
) !StoryRetries {
    var retries: StoryRetries = .{};
    var failed_run: std.ArrayList(u32) = .empty;
    var run_key: []const u8 = "";
    for (status_indices) |status_index| {
        const entry = entries[status_index];
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null);
        if (statusNamesAsk(entry, detail)) continue;
        const record = detail orelse {
            failed_run.clearRetainingCapacity();
            continue;
        };
        // A call held for project instructions has no row.
        if (record.outcome == .deferred) continue;
        // A shell call repeats by its steps, and only one that never ran
        // starts a run of failures: a command that ran and failed stays, as
        // "passed on the 3rd run".
        const shell = isShellCommandCall(scratch, record);
        const key = (if (shell) try shellRetryKey(scratch, record) else try retryKey(scratch, record)) orelse {
            failed_run.clearRetainingCapacity();
            continue;
        };
        if (failed_run.items.len > 0 and !std.mem.eql(u8, key, run_key)) failed_run.clearRetainingCapacity();
        const outcome = record.outcome orelse {
            failed_run.clearRetainingCapacity();
            continue;
        };
        switch (outcome) {
            .failed => if (!shell or shellCallNeverRan(scratch, record)) {
                try failed_run.append(scratch, entry_id);
                run_key = key;
            } else failed_run.clearRetainingCapacity(),
            .completed => if (failed_run.items.len > 0) {
                for (failed_run.items) |id| try retries.fixed.put(scratch, id, {});
                try retries.tries.put(scratch, entry_id, failed_run.items.len + 1);
                failed_run.clearRetainingCapacity();
            },
            else => failed_run.clearRetainingCapacity(),
        }
    }
    return retries;
}

/// The tool and target a call acts on, which a retry of it repeats: the
/// tool's name and the first argument that names a target. A skill or tool
/// to open or run counts by its base name, so one opened by its path repeats
/// one opened by its name; a path counts whole, so another file with the
/// same name is not a retry. Null for a shell command, which repeats as
/// "passed on the 3rd run" instead, and for a call that names no target,
/// such as an MCP tool's: its next call may do other work, so its failure
/// stays.
fn retryKey(scratch: std.mem.Allocator, record: *const ToolDetailRecord) !?[]const u8 {
    if (isShellCommandCall(scratch, record)) return null;
    const fields = [_][]const u8{ "path", "open", "run", "search", "agent", "pattern", "url", "query" };
    for (fields) |field| if (storyArgString(scratch, record, field)) |value| {
        const by_name = std.mem.eql(u8, field, "open") or std.mem.eql(u8, field, "run");
        const target = if (by_name) std.Io.Dir.path.basename(value) else value;
        return try std.mem.concat(scratch, u8, &.{ record.tool_name, "\x00", target });
    };
    return null;
}

/// The rows of a group after calls for the same task share one row. Rows
/// keep the position of their first call and show their latest call.
fn collectStoryRows(
    scratch: std.mem.Allocator,
    entries: []const TranscriptEntry,
    status_indices: []const usize,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    focused_entry_id: ?u32,
    retries: *const StoryRetries,
    unshown: *std.AutoHashMapUnmanaged(u32, void),
) !std.ArrayList(StoryRow) {
    var rows: std.ArrayList(StoryRow) = .empty;
    calls: for (status_indices) |status_index| {
        const entry = entries[status_index];
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null);
        if (statusNamesAsk(entry, detail) or focused_entry_id == entry_id) continue;
        // A failure the model fixed at once shows as the try that worked.
        if (retries.fixed.contains(entry_id)) continue;
        // A call held for project instructions has not run. The call that
        // runs once they load shows instead, so the hold gets no row; Ctrl+O
        // still shows it.
        if (detail) |record| if (record.outcome == .deferred) continue;
        const identity = try streamingSubagentIdentity(scratch, entry, detail, try streamingToolboxIdentity(scratch, entry, detail, try storyIdentity(scratch, detail)));
        // A call whose arguments have not arrived yet waits in the row it
        // will most likely join, and shows once they arrive.
        if (identity.kind == .single) if (detail) |record| if (record.outcome == null and (!storyHasArgs(record) or joinsByArgument(record))) {
            if (try pendingCallRow(scratch, rows.items, entry, record) != null) continue :calls;
            // With no row to wait in, a call that names nothing yet, a bare
            // verb such as "Reading", has nothing to show: its row shows once
            // its target or the call itself arrives.
            if (try saysNothingYet(scratch, entry, record)) {
                try unshown.put(scratch, entry_id, {});
                continue :calls;
            }
        };

        // A repeated command joins only the row right before it; the other
        // kinds join the first row they share, wherever it is.
        const candidates: []StoryRow = switch (identity.kind) {
            .single, .commands => rows.items[0..0],
            .command => rows.items[rows.items.len -| 1..],
            else => rows.items,
        };
        const target = for (candidates) |*row| {
            if (sharesStoryRow(row.identity, identity)) break row;
            if (identity.kind == .session and std.mem.eql(u8, row.session, identity.key)) break row;
        } else new: {
            // A run's record keeps its output but not the session it started,
            // so a session's first input or stop joins the run in the group
            // that still goes on, which is the one that started it.
            if (identity.kind == .session) if (sessionRunRow(rows.items, detail.?)) |run_row| {
                // A row of several commands keeps naming their steps.
                if (run_row.identity.kind == .commands) {
                    run_row.session = identity.key;
                    // The session's command is the newest step the row ran.
                    try run_row.combined.append(scratch, detail.?);
                } else run_row.identity = identity;
                break :new run_row;
            };
            // A different command right after one with the same label joins
            // its row as one more step.
            if (identity.kind == .command and rows.items.len > 0) {
                const last = &rows.items[rows.items.len - 1];
                if (try joinsCommandRow(scratch, last, entry, detail)) {
                    if (last.identity.kind == .command) {
                        last.identity = .{ .kind = .commands };
                        try last.combined.append(scratch, last.detail.?);
                    }
                    try last.combined.append(scratch, detail.?);
                    last.entry = entry;
                    last.entry_id = entry_id;
                    last.detail = detail;
                    last.status_index = status_index;
                    if (try commandStillRunning(scratch, entry)) last.background = detail;
                    continue :calls;
                }
            }
            try rows.append(scratch, .{ .entry = entry, .entry_id = entry_id, .detail = detail, .identity = identity, .count = 0, .status_index = status_index });
            break :new &rows.items[rows.items.len - 1];
        };
        target.count += 1;
        if (storyRowCallFailed(scratch, detail)) target.failures += 1;
        target.entry = entry;
        target.entry_id = entry_id;
        target.detail = detail;
        target.status_index = status_index;
        if (try commandStillRunning(scratch, entry)) target.background = detail;
        target.tries = retries.tries.get(entry_id) orelse 0;
        try addSearchPath(scratch, target, detail);
        if (storyRowName(identity)) |name| try StoryTally.addLatest(&target.names, scratch, name);
        if (identity.kind == .edit) {
            const totals = diffTotalsOfPhrase(try entryStatus(scratch, entry) orelse "");
            target.diff.added +|= totals.added;
            target.diff.removed +|= totals.removed;
            if (std.mem.eql(u8, detail.?.tool_name, "write_file")) target.writes += 1;
        }
    }
    return rows;
}

/// The latest row with a run that returned while its command went on, for a
/// session's first follow-up to join, though later calls may have joined
/// that row too. When both calls show the command, it must be the same one,
/// so input to one session never joins another's run.
fn sessionRunRow(rows: []StoryRow, follow_up: *const ToolDetailRecord) ?*StoryRow {
    var index = rows.len;
    while (index > 0) {
        index -= 1;
        const row = &rows[index];
        if (row.identity.kind != .command and row.identity.kind != .commands) continue;
        if (row.session.len > 0) continue;
        const run = row.background orelse continue;
        if (follow_up.command_display) |shown| if (run.command_display) |run_shown| {
            if (!std.mem.eql(u8, shown, run_shown)) continue;
        };
        return row;
    }
    return null;
}

/// Whether a call with `identity` joins the row of an earlier call with
/// `row`. Every read shares one row, and every search with the same tool.
/// A bare subagent wait or status says what main did while its subagents
/// worked, so it keeps a row of its own; later calls with the same action
/// join it with their latest state, and a status and a wait stay apart, so
/// neither hides the other.
fn sharesStoryRow(row: StoryIdentity, identity: StoryIdentity) bool {
    if (row.kind != identity.kind) return false;
    return switch (identity.kind) {
        .read => true,
        .search => std.mem.eql(u8, storySearchTool(row.key), storySearchTool(identity.key)),
        else => std.mem.eql(u8, row.key, identity.key),
    };
}

const StoryRowText = struct {
    /// The phrase and the merge note together.
    display: []const u8,
    /// The phrase alone, which clips first when the row is too wide.
    body: []const u8,
    /// How many calls share the row, such as " ×3" or " · 2 calls".
    suffix: []const u8,
    /// Why the row's latest call failed, in one short line, or "".
    reason: []const u8 = "",
};

/// One row's phrase: the recorded status of its latest call, then how many
/// calls share the row. A command that passed after failing says so, so the
/// earlier failures stay in the story.
fn storyRowText(scratch: std.mem.Allocator, row: *const StoryRow, style: SummaryStyle, cols: u16) !StoryRowText {
    if (rowListsNames(row)) return nameListRowText(scratch, row, cols);
    if (row.identity.kind == .commands) {
        const label = try commandRowLabel(scratch, row.entry, row.detail) orelse "Ran ";
        var steps = try combinedCommandSteps(scratch, row.combined.items);
        var display = try std.mem.concat(scratch, u8, &.{ label, try formatShortCommand(scratch, steps, style.text_style) });
        // A narrow row leaves out its oldest steps first, so the newest stays
        // in view. The budget leaves room for the connector and the mark.
        const budget: usize = if (cols > 4) cols - 4 else 1;
        while (steps.steps.len > 1 and display_width.visibleWidthIgnoringAnsi(display) > budget) {
            steps.steps = steps.steps[1..];
            steps.earlier += 1;
            display = try std.mem.concat(scratch, u8, &.{ label, try formatShortCommand(scratch, steps, style.text_style) });
        }
        return .{ .display = display, .body = display, .suffix = "" };
    }
    const merged_read = row.identity.kind == .read and row.count > 1;
    const status_phrase = if (merged_read)
        try std.mem.concat(scratch, u8, &.{ "Read ", try terminalSafeText(scratch, row.identity.key) })
    else
        try entryStatus(scratch, row.entry) orelse if (row.detail) |record| record.tool_name else "tool activity";
    // A shell call that never ran says so by its command's steps, like any
    // call the model got wrong, and leaves why to Ctrl+O, unless the turn
    // ended on it, as for any failure a turn ends on.
    if (row.detail) |record| if (shellCallNeverRan(scratch, record)) {
        const command = storyArgString(scratch, record, "command") orelse record.command_display orelse record.tool_name;
        const short = try shortCommand(scratch, command) orelse try terminalSafeText(scratch, command);
        const phrase = try inFailureStyle(scratch, try std.mem.concat(scratch, u8, &.{ "Couldn't run ", short }), style);
        const reason = if (row.ends_turn) try neverRanReason(scratch, record) orelse "" else "";
        return .{ .display = phrase, .body = phrase, .suffix = "", .reason = reason };
    };
    const split_failure = splitFailedPhrase(status_phrase, row.detail);
    const raw_phrase = if (split_failure) |split| split.row else status_phrase;
    const full_phrase = try reprojectTruncatedCommandPhrase(scratch, raw_phrase, row.detail) orelse raw_phrase;
    const agent_phrase = if (row.detail) |record| try subagentRowPhrase(scratch, full_phrase, record) else null;
    const named_phrase = if (try readRowPhrase(scratch, full_phrase, row, merged_read)) |read|
        read
    else if (try editRowPhrase(scratch, full_phrase, row)) |edit|
        edit
    else if (agent_phrase) |agent|
        agent
    else if (try shortenCommandPhrase(scratch, full_phrase, row.detail, style.text_style)) |short|
        short
    else
        try highlightCommandPhrase(scratch, full_phrase, row.detail, style.text_style) orelse full_phrase;
    // A failed call says what it tried, whether its reason came in its
    // status or in its result. A command keeps core's label, such as
    // "Exited 1", which says how it ended.
    const phrase = if (row.detail) |record| if (storyCallFailed(row.detail) and !isShellCommandCall(scratch, record))
        try inFailureStyle(scratch, try couldNotPhrase(scratch, named_phrase, record), style)
    else
        named_phrase else named_phrase;
    // Why a call failed is for the model, which most often fixes it in its
    // next call, so the row says only that it failed; Ctrl+O shows the
    // error. A command or a subagent says why, since how it ended is part of
    // the story, and so does a failure the turn ended on.
    const says_why = if (row.detail) |record|
        isShellCommandCall(scratch, record) or record.activity_kind == .subagent or row.ends_turn
    else
        false;
    const reason = if (!says_why)
        ""
    else if (split_failure) |split|
        try storySafeLine(scratch, firstSentence(split.reason), story_reason_max_bytes)
    else
        try storyFailureReason(scratch, row.detail) orelse "";
    // A pattern searched in several folders names them, so its calls do not
    // look like one search made twice.
    const many_folders = row.identity.kind == .search and row.search_paths.items.len > 1;
    const display = if (many_folders)
        try std.mem.concat(scratch, u8, &.{ phrase, " in ", try searchFolderNames(scratch, row.search_paths.items) })
    else
        phrase;
    const passed_after_failing = row.failures > 0 and row.detail != null and
        row.detail.?.outcome != null and !storyCallFailed(row.detail);
    // A call that completed after the model repeated it says which try it was.
    const suffix: []const u8 = if (row.count < 2) (if (row.tries > 1) try countNote(scratch, " · ", row.tries, ordinalEnding(row.tries, " try")) else "") else switch (row.identity.kind) {
        .command => if (passed_after_failing)
            // " ×3 · passed on the 3rd run".
            try countNote(scratch, try countNote(scratch, " ×", row.count, " · passed on the "), row.count, ordinalEnding(row.count, " run"))
        else
            try countNote(scratch, " ×", row.count, ""),
        .session => try countNote(scratch, " · ", row.count, " calls"),
        .mcp => try countNote(scratch, " ×", row.count, ""),
        .read => try countNote(scratch, " · ", row.count, " parts"),
        .search => if (many_folders) "" else try countNote(scratch, " ×", row.count, ""),
        .edit => try countNote(scratch, " · ", row.count, if (row.writes == 0) " edits" else if (row.writes == row.count) " writes" else " changes"),
        .single, .subagent, .subagent_wait, .commands => "",
    };
    return .{
        .display = if (suffix.len == 0) display else try std.mem.concat(scratch, u8, &.{ display, suffix }),
        .body = display,
        .suffix = suffix,
        .reason = reason,
    };
}

/// `before`, `count`, then `after`, such as " ×3" or " +2 more", in
/// `scratch`. It writes through writeCount, so every count shares one format.
fn countNote(scratch: std.mem.Allocator, before: []const u8, count: usize, after: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(scratch);
    writeCount(&out.writer, before, count, after) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// A phrase that still says the call is running, such as the status line
/// `spark ask` prints when a command starts and never rewrites, or core's
/// "Still running" for a run that returned before its command ended.
fn phraseShowsProgress(phrase: []const u8) bool {
    return std.mem.startsWith(u8, phrase, "Running ") or
        std.mem.startsWith(u8, phrase, still_running_label ++ " ");
}

/// Whether a row's own status already says it failed, as an old record with
/// no exit code can ("Exited 1 make"), so it never gets a ✓.
fn phraseNamesFailure(phrase: []const u8) bool {
    const labels = [_][]const u8{ "Exited ", "Failed", "Couldn't ", "Timed out", "Killed", "Denied", "Cancelled" };
    for (labels) |label| if (std.mem.startsWith(u8, phrase, label)) return true;
    return false;
}

/// The ordinal ending of `number` and the word after it, such as the
/// "rd run" of "3rd run" or the "nd try" of "2nd try".
fn ordinalEnding(number: usize, comptime word: []const u8) []const u8 {
    if (number % 100 >= 11 and number % 100 <= 13) return "th" ++ word;
    return switch (number % 10) {
        1 => "st" ++ word,
        2 => "nd" ++ word,
        3 => "rd" ++ word,
        else => "th" ++ word,
    };
}

/// Command output kept in its escaped form, where text_utils.encodeTerminalSafe
/// writes every control byte, line feeds included, as "\xNN", gets its escaped
/// line feeds back as line breaks, so the reason line can pick one line of it.
/// Text with real line breaks is returned as is.
fn storyOutputLines(scratch: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (findByte(text, '\n') != null) return text;
    if (std.mem.find(u8, text, "\\x0a") == null) return text;
    return std.mem.replaceOwned(u8, scratch, text, "\\x0a", "\n");
}

/// The line of command output that says what went wrong: the first line that
/// reports an error or a failure, such as "Error: timed out" or
/// "main.c:3: error: ...", else the last line where one of `programs`, the
/// programs the command ran, or its shell reports, such as "sed: 1: ...",
/// else the first line that names an error or a failure, else the last line.
/// "error" or "fail" inside a longer name, such as "error_code", counts as
/// neither, so a command that prints code does not read as its own error.
fn verdictLine(text: []const u8, programs: []const []const u8) ?[]const u8 {
    var named: ?[]const u8 = null;
    var reported: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        switch (failureWord(trimmed)) {
            .reports => return trimmed,
            .names => if (named == null) {
                named = trimmed;
            },
            .none => {},
        }
        if (programReports(trimmed, programs)) reported = trimmed;
    }
    return reported orelse named orelse lastNonEmptyLine(text);
}

const FailureWord = enum { none, names, reports };

/// Whether `line` holds "error" or "fail" as a word of its own, such as
/// "errors", "failed", or the end of "TypeError", and whether that word
/// reports, starting the line or right before a colon.
fn failureWord(line: []const u8) FailureWord {
    var found: FailureWord = .none;
    for ([_][]const u8{ "error", "fail" }) |stem| {
        var start: usize = 0;
        while (start + stem.len <= line.len) : (start += 1) {
            if (!std.ascii.eqlIgnoreCase(line[start .. start + stem.len], stem)) continue;
            var end = start + stem.len;
            for ([_][]const u8{ "ures", "ure", "ing", "ed", "s" }) |ending| {
                if (end + ending.len <= line.len and std.ascii.eqlIgnoreCase(line[end .. end + ending.len], ending)) {
                    end += ending.len;
                    break;
                }
            }
            const before_ok = start == 0 or !isNameByte(line[start - 1]) or
                (std.ascii.isUpper(line[start]) and (std.ascii.isLower(line[start - 1]) or std.ascii.isDigit(line[start - 1])));
            const after_ok = end == line.len or (!isNameByte(line[end]) and
                !(line[end] == '.' and end + 1 < line.len and std.ascii.isAlphanumeric(line[end + 1])));
            if (!before_ok or !after_ok) continue;
            if (start == 0 or (end < line.len and line[end] == ':')) return .reports;
            found = .names;
        }
    }
    return found;
}

fn isNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// Whether `line` is a program speaking for itself, as in "sed: 1: ..." or
/// "/bin/sh: line 1: ...": its first word before a colon names one of
/// `programs` or a shell.
fn programReports(line: []const u8, programs: []const []const u8) bool {
    const colon = std.mem.findScalar(u8, line, ':') orelse return false;
    if (colon == 0 or colon + 1 >= line.len) return false;
    const speaker = line[0..colon];
    if (std.mem.findAny(u8, speaker, " \t") != null) return false;
    const name = std.Io.Dir.path.basenamePosix(speaker);
    for ([_][]const u8{ "sh", "bash", "zsh", "dash", "ksh" }) |shell| if (std.mem.eql(u8, name, shell)) return true;
    for (programs) |program| if (std.mem.eql(u8, name, program)) return true;
    return false;
}

/// The programs a command runs, by name, such as "sed" and "git" for
/// "sed -n 2p f && git status", so its output can tell their own messages.
fn commandPrograms(scratch: std.mem.Allocator, record: *const ToolDetailRecord) ![]const []const u8 {
    const command = storyArgString(scratch, record, "command") orelse record.command_display orelse return &.{};
    var steps: std.ArrayList([]const u8) = .empty;
    var raw_steps: usize = 0;
    if (!try collectShortSteps(scratch, command, &steps, &raw_steps, 0)) return &.{};
    var programs: std.ArrayList([]const u8) = .empty;
    for (steps.items) |step| {
        const word = step[0 .. std.mem.findScalar(u8, step, ' ') orelse step.len];
        try programs.append(scratch, std.Io.Dir.path.basenamePosix(word));
    }
    return programs.items;
}

fn lastNonEmptyLine(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

fn firstNonEmptyLine(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

noinline fn storyCallFailed(detail: ?*const ToolDetailRecord) bool {
    const record = detail orelse return false;
    if (record.fallback_disposition != null) return false;
    const failed = if (record.outcome) |outcome| outcome == .failed else false;
    return failed or commandProcessFailed(record);
}

/// A failed non-command row reads "Failed <target>: <error>". Splits it so the
/// row keeps "Failed <target>" and the error moves to the reason line.
const SplitFailure = struct { row: []const u8, reason: []const u8 };

fn splitFailedPhrase(phrase: []const u8, detail: ?*const ToolDetailRecord) ?SplitFailure {
    const record = detail orelse return null;
    if (record.activity_kind == .command or !storyCallFailed(detail)) return null;
    const colon = std.mem.find(u8, phrase, ": ") orelse return null;
    // "Failed: <action>: <error>", as `spark ask` writes it, names no target
    // before its first colon, so the row keeps the whole phrase.
    if (std.mem.eql(u8, std.mem.trim(u8, phrase[0..colon], " "), "Failed")) return null;
    const reason = std.mem.trim(u8, phrase[colon + 2 ..], " ");
    if (reason.len == 0) return null;
    return .{ .row = phrase[0..colon], .reason = reason };
}

/// One plain line that says why a call failed, such as
/// "exit 1 · 1 failed: backoff adds 500ms". Null for calls that did not fail
/// and for failures whose output has no line to show.
/// The most bytes of a failure's reason line, before the row clips it.
const story_reason_max_bytes = 160;

fn storyFailureReason(scratch: std.mem.Allocator, detail: ?*const ToolDetailRecord) !?[]const u8 {
    const record = detail orelse return null;
    if (!storyCallFailed(detail)) return null;

    const is_command = record.activity_kind == .command;
    const line: ?[]const u8 = if (record.result) |result| blk: {
        // Command details keep the plain output, where the line that names
        // the error says the most; other tools lead with their error.
        const programs = if (is_command) try commandPrograms(scratch, record) else &.{};
        const plain_line = if (is_command) verdictLine(try storyOutputLines(scratch, result), programs) else firstNonEmptyLine(result);
        const fields = [_][]const u8{ "output_delta", "error", "message" };
        for (fields) |field_name| {
            const field = jsonObjectField(scratch, result, field_name) catch break :blk plain_line;
            if (field) |value| switch (value) {
                .string => |text| break :blk if (std.mem.eql(u8, field_name, "output_delta")) verdictLine(text, programs) else firstNonEmptyLine(text),
                else => {},
            };
        }
        break :blk null;
    } else null;
    // The row's own status already says how a command ended, such as
    // "Exited 2" or "Timed out", so the reason is only its line of output,
    // by its message alone and short; Ctrl+O shows the whole output.
    const text = line orelse return null;
    const safe = try storySafeLine(scratch, if (is_command) commandMessage(text) else firstSentence(text), story_reason_max_bytes);
    if (safe.len == 0) return null;
    return if (is_command) try clipSummary(scratch, safe, command_reason_max_cols) else safe;
}

/// The text after the first "error" or "fatal" label in `line`, such as
/// "error: ", "error[E0308]: " or "error TS2554: ", when text follows it. A
/// label starts the line or follows ": " or " - ", as in compiler output,
/// so "connection error: timeout" inside a message is no label.
fn afterErrorLabel(line: []const u8) ?[]const u8 {
    for ([_][]const u8{ "error", "fatal" }) |label| {
        var start: usize = 0;
        while (start + label.len <= line.len) : (start += 1) {
            if (!std.ascii.eqlIgnoreCase(line[start .. start + label.len], label)) continue;
            if (start > 0 and !std.mem.endsWith(u8, line[0..start], ": ") and !std.mem.endsWith(u8, line[0..start], " - ")) continue;
            var end = start + label.len;
            // A code after the label: "[E0308]" right after it, or one word
            // after a space, such as "TS2554".
            if (end < line.len and line[end] == '[') {
                end = (std.mem.findScalarPos(u8, line, end, ']') orelse continue) + 1;
            } else if (end < line.len and line[end] == ' ') {
                var code_end = end + 1;
                while (code_end < line.len and isNameByte(line[code_end])) code_end += 1;
                if (code_end > end + 1 and std.mem.startsWith(u8, line[code_end..], ": ")) end = code_end;
            }
            if (!std.mem.startsWith(u8, line[end..], ": ")) continue;
            const message = std.mem.trimStart(u8, line[end + 2 ..], " \t");
            if (message.len > 0) return message;
        }
    }
    return null;
}

/// The most columns a failed command's reason takes on its row.
const command_reason_max_cols = 40;

/// An error line's message without the words before it that say who spoke
/// and where, so "ls: missing-file: No such file or directory" is "No such
/// file or directory" and "src/main.zig:3:5: error: expected type" is
/// "expected type". The message starts after an "error" or "fatal" with its
/// code, as in "src/main.ts:14:15 - error TS2554: Expected 1 arguments", and
/// after each word with no space that ends in ": " while the text after it
/// has a space. The line stays whole when nothing would be left.
fn commandMessage(line: []const u8) []const u8 {
    var rest = std.mem.trim(u8, line, " \t");
    if (afterErrorLabel(rest)) |message| rest = message;
    while (std.mem.find(u8, rest, ": ")) |colon| {
        const prefix = rest[0..colon];
        if (prefix.len == 0 or std.mem.findAny(u8, prefix, " \t") != null) break;
        const after = std.mem.trimStart(u8, rest[colon + 2 ..], " \t");
        // A word before text with no space is the message's own, as in
        // "undefined: foo" or "KeyError: 'key'", so it stays.
        if (after.len == 0 or std.mem.findAny(u8, after, " \t") == null) break;
        rest = after;
    }
    return rest;
}

/// The first sentence of an error, which says what went wrong. What follows
/// it, such as how to retry, is for the model.
fn firstSentence(text: []const u8) []const u8 {
    var index: usize = 0;
    while (index + 1 < text.len) : (index += 1) {
        if ((text[index] == '.' or text[index] == '!' or text[index] == '?') and text[index + 1] == ' ') return text[0..index];
    }
    return std.mem.trimEnd(u8, text, ".");
}

/// A failed call's row, "Couldn't edit main.zig", from core's "Failed
/// main.zig". A call that names no target says the tool, as in "Couldn't
/// run mcp_tool". The phrase stays as it is when it does not start with
/// "Failed " or the tool's row says it another way.
fn couldNotPhrase(scratch: std.mem.Allocator, phrase: []const u8, record: *const ToolDetailRecord) ![]const u8 {
    const failed = "Failed ";
    if (!std.mem.startsWith(u8, phrase, failed) or phrase.len == failed.len) return phrase;
    const verb = failedVerb(scratch, record) orelse return phrase;
    const target = phrase[failed.len..];
    return std.mem.concat(scratch, u8, &.{ "Couldn't ", if (std.mem.eql(u8, target, record.tool_name)) "run" else verb, " ", target });
}

/// What a failed call tried to do, as in "Couldn't edit". Null for a
/// subagent, whose rows say it in their own words.
fn failedVerb(scratch: std.mem.Allocator, record: *const ToolDetailRecord) ?[]const u8 {
    const verbs = [_]struct { tool: []const u8, verb: []const u8 }{
        .{ .tool = "read_file", .verb = "read" },
        .{ .tool = "read_tool_result", .verb = "read" },
        .{ .tool = "write_file", .verb = "write" },
        .{ .tool = "edit_file", .verb = "edit" },
        .{ .tool = "glob_files", .verb = "match" },
        .{ .tool = "grep_files", .verb = "search" },
        .{ .tool = "web_fetch", .verb = "fetch" },
        .{ .tool = "web_search", .verb = "search" },
        .{ .tool = "vision", .verb = "inspect" },
        .{ .tool = "install_skill", .verb = "install" },
        .{ .tool = "ask_user_question", .verb = "ask" },
    };
    for (verbs) |entry| if (std.mem.eql(u8, record.tool_name, entry.tool)) return entry.verb;
    if (std.mem.eql(u8, record.tool_name, "subagent")) return null;
    if (std.mem.eql(u8, record.tool_name, "toolbox")) {
        for ([_][]const u8{ "open", "run", "search" }) |action| if (storyArgString(scratch, record, action) != null) return action;
        return "use";
    }
    return "run";
}

/// The recap a turn summary leads with: "1 file changed +2 -1 · ran 4
/// commands · ". It has no result mark, since the group headers show how
/// each command ended. Empty when the turn changed and ran nothing.
fn formatTurnRecap(scratch: std.mem.Allocator, tally: StoryTally) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(scratch);
    const w = &out.writer;
    const changed = tally.changedFiles();
    if (changed > 0) {
        try writeCount(w, "", changed, pluralWord(changed, " file changed", " files changed"));
        if (tally.diff.added > 0) try writeCount(w, " +", tally.diff.added, "");
        if (tally.diff.removed > 0) try writeCount(w, " -", tally.diff.removed, "");
        try w.writeAll(" · ");
    }
    if (tally.commands > 0) {
        try writeCount(w, "ran ", tally.commands, pluralWord(tally.commands, " command · ", " commands · "));
    }
    // A turn that handed its work to subagents did more than explore.
    if (changed == 0 and tally.commands == 0 and tally.subagent_calls == 0 and tally.read_paths.items.len > 0) {
        const reads = tally.read_paths.items.len;
        try writeCount(w, "explored ", reads, pluralWord(reads, " file · ", " files · "));
    }
    const recap = out.written();
    if (recap.len > 0) recap[0] = std.ascii.toUpper(recap[0]);
    return recap;
}

/// Inserts the turn recap before the first visible character of a turn
/// summary row, after its indent and any leading style. Null when the turn
/// has nothing to recap or the longer row would not fit `cols`, since the
/// painter shows a turn summary as it is and never wraps it. Caller owns it.
fn recapTurnSummary(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    summary_index: usize,
    cols: u16,
) !?[]u8 {
    const summary_bytes = switch (entries[summary_index]) {
        .raw_bytes => |raw| raw.bytes,
        else => return null,
    };
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();

    var turn_start = summary_index;
    while (turn_start > 0) {
        const entry = entries[turn_start - 1];
        const boundary = switch (entry) {
            .user_turn => true,
            .raw_bytes => |raw| raw.class == .turn_summary or raw.class == .turn_cancellation,
            else => false,
        };
        if (boundary) break;
        turn_start -= 1;
    }
    var tally: StoryTally = .{};
    for (entries[turn_start..summary_index]) |entry| {
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null);
        if (statusNamesAsk(entry, detail)) continue;
        try tally.observe(scratch, entry, detail);
    }
    const recap = try formatTurnRecap(scratch, tally);
    if (recap.len == 0) return null;

    var insert_at: usize = 0;
    while (insert_at < summary_bytes.len) {
        if (skipSgrSequence(summary_bytes, &insert_at)) continue;
        if (summary_bytes[insert_at] != ' ') break;
        insert_at += 1;
    }
    const recapped = try std.mem.concat(scratch, u8, &.{ summary_bytes[0..insert_at], recap, summary_bytes[insert_at..] });
    if (display_width.visibleWidthIgnoringAnsi(std.mem.trimEnd(u8, recapped, "\n")) > cols) return null;
    return try alloc.dupe(u8, recapped);
}

const GroupBlock = struct { bytes: []u8, lines: []const transcript_blocks.LineProvenance };

fn formatGroupBlock(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    status_indices: []const usize,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    summary: Summary,
    focused_entry_id: ?u32,
    collapse_tool_calls: bool,
    cols: u16,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
) !GroupBlock {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    var lines: std.ArrayList(transcript_blocks.LineProvenance) = .empty;
    errdefer lines.deinit(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    // writeGroupBlock has no cleanup of its own, so its many failure points
    // share this one; each `try` here would repeat the cleanup in the binary.
    const header = try writeGroupBlock(alloc, scratch_state.allocator(), &out.writer, &lines, entries, status_indices, details, detail_indices, summary, focused_entry_id, collapse_tool_calls, cols, style, styles);
    const bytes = if (collapse_tool_calls) try alloc.dupe(u8, header) else try out.toOwnedSlice();
    errdefer alloc.free(bytes);
    return .{ .bytes = bytes, .lines = try lines.toOwnedSlice(alloc) };
}

/// Writes a group's header and, unless `collapse_tool_calls`, its rows to
/// `out`, and their provenance to `lines`. Returns the header, which lives in
/// `scratch`.
fn writeGroupBlock(
    alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.Io.Writer,
    lines: *std.ArrayList(transcript_blocks.LineProvenance),
    entries: []const TranscriptEntry,
    status_indices: []const usize,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    summary: Summary,
    focused_entry_id: ?u32,
    collapse_tool_calls: bool,
    cols: u16,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
) ![]const u8 {
    const retries = try collectStoryRetries(scratch, entries, status_indices, details, detail_indices);
    var unshown: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const rows = try collectStoryRows(scratch, entries, status_indices, details, detail_indices, focused_entry_id, &retries, &unshown);
    // A group whose only calls name nothing yet shows nothing until they do.
    if (rows.items.len == 0 and unshown.count() > 0) return "";
    var tally: StoryTally = .{};
    var focused_in_group = false;
    for (status_indices) |status_index| {
        const entry = entries[status_index];
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null);
        if (statusNamesAsk(entry, detail)) continue;
        if (focused_entry_id == entry_id) focused_in_group = true;
        // A failure the model fixed at once is not counted as a failure, and
        // a call with no row yet is not counted at all.
        if (retries.fixed.contains(entry_id) or unshown.contains(entry_id)) continue;
        try tally.observe(scratch, entry, detail);
    }
    for (rows.items) |*row| {
        if (!storyCallFailed(row.detail)) continue;
        row.ends_turn = callEndsTurn(entries, row.status_index);
        if (row.ends_turn and (!isShellCommandCall(scratch, row.detail.?) or shellCallNeverRan(scratch, row.detail.?))) tally.turn_ending_failures += 1;
    }
    var last_command_row: ?usize = null;
    for (rows.items, 0..) |*row, index| {
        if (row.detail) |record| if (isShellCommandCall(scratch, record)) {
            last_command_row = index;
        };
    }
    for (rows.items, 0..) |*row, index| {
        if (index != last_command_row and storyRowCallFailed(scratch, row.detail)) tally.earlier_command_failures += 1;
    }
    if (last_command_row) |index| {
        const row = &rows.items[index];
        tally.last_command_row_failed = storyRowCallFailed(scratch, row.detail) and !shellCallNeverRan(scratch, row.detail.?);
    }

    // A group left with one row needs no summary above it: the row is the
    // header, so nothing is said twice. That holds for a row that names
    // several commands' steps, files, or patterns too, since the header
    // would only repeat its verb; collapsed groups keep their header, which
    // leaves those names out.
    const lone = if (rows.items.len == 1) &rows.items[0] else null;
    const single_row: ?*const StoryRow = if (lone) |row|
        if (!focused_in_group and (!collapse_tool_calls or (row.identity.kind != .commands and !rowListsNames(row)))) row else null
    else
        null;
    const single_text: ?StoryRowText = if (single_row) |row| try storyRowText(scratch, row, style, cols) else null;

    const header = if (single_row) |row| blk: {
        const text = single_text.?;
        const succeeded_command = if (row.detail) |record|
            isShellCommandCall(scratch, record) and record.outcome == .completed and
                !storyCallFailed(row.detail) and !phraseNamesFailure(text.display) and
                !phraseShowsProgress(text.display)
        else
            false;
        // A failure the phrase does not name, such as a status line `spark ask`
        // never rewrites, still shows on the header.
        const unnamed_failure = storyCallFailed(row.detail) and !phraseNamesFailure(text.display);
        const mark = if (succeeded_command) " ✓" else if (unnamed_failure) try std.mem.concat(scratch, u8, &.{ " ", try inFailureStyle(scratch, "✗", style) }) else "";
        break :blk try applySummaryStyle(scratch, try clipStoryRow(scratch, "● ", row, &text, mark, cols, style), style);
    } else if (try formatStoryHeader(scratch, tally, summary, style, collapse_tool_calls)) |story|
        try applySummaryStyle(scratch, try clipStoryHeader(scratch, story, cols), style)
    else
        try formatGroupHeader(scratch, summary, cols, style);
    const header_entry_id = if (single_row) |row| row.entry_id else entries[status_indices[0]].id();
    try lines.append(alloc, .{ .entry = .{ .entry_id = header_entry_id, .entry_class = .tool_status, .projection_part = .group_header } });
    if (collapse_tool_calls) return header;
    try out.writeAll(header);

    if (single_row) |row| {
        try writeRowDetails(alloc, scratch, out, lines, row, "  ", cols, style);
    } else for (rows.items, 0..) |*row, row_index| {
        const text = try storyRowText(scratch, row, style, cols);
        const last_static_row = !focused_in_group and row_index + 1 == rows.items.len;
        const clipped = try clipStoryRow(scratch, if (last_static_row) "└ " else "├ ", row, &text, "", cols, style);
        try writeChildLine(alloc, out, lines, row.entry_id, style.text_style, clipped, childLineClose(style));
        try writeRowDetails(alloc, scratch, out, lines, row, if (last_static_row) "  " else "│ ", cols, style);
    }

    for (status_indices) |status_index| {
        const entry = entries[status_index];
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null) orelse continue;
        if (detail.outcome != .cancelled) continue;

        // A cancelled command's notice names no command; its row does.
        var shown = entry;
        if (isShellCommandCall(scratch, detail)) {
            if (try cancelledCommandNotice(scratch, entry.raw_bytes.bytes)) |notice| shown.raw_bytes.bytes = notice;
        }
        const terminal = try transcript_blocks.renderEntryToBlock(scratch, shown, cols, styles);
        if (terminal.bytes.len > 0) {
            try lines.append(alloc, .block_separator);
            const count = std.mem.count(u8, std.mem.trimEnd(u8, terminal.bytes, "\n"), "\n") + 1;
            try lines.appendNTimes(alloc, .{ .entry = .{ .entry_id = entry_id, .entry_class = .tool_status, .projection_part = .group_cancel } }, count);
            try out.writeAll("\n\n");
            try out.writeAll(terminal.bytes);
        }
        terminal.deinit(scratch);
    }
    return header;
}

/// A row clipped to `cols` behind `lead`, such as "● " or "├ ", with `mark`
/// after it, accented like the status line it stands for. The merge note and
/// the mark stay when the phrase is clipped, like the diff counts.
fn clipStoryRow(scratch: std.mem.Allocator, lead: []const u8, row: *const StoryRow, text: *const StoryRowText, mark: []const u8, cols: u16, style: SummaryStyle) ![]const u8 {
    if (text.reason.len == 0) return clipStoryPhrase(scratch, lead, row, text, mark, cols, style);
    // A failed row says why after its phrase, in the failure style, and
    // before its mark.
    // The reason clips first, and a row with no room for it drops it;
    // Ctrl+O still shows the call's whole error.
    const mark_width = display_width.visibleWidthIgnoringAnsi(mark);
    if (cols <= mark_width * 2) return clipStoryPhrase(scratch, lead, row, text, mark, cols, style);
    const phrase = try clipStoryPhrase(scratch, lead, row, text, "", @intCast(cols - mark_width), style);
    const used = display_width.visibleWidthIgnoringAnsi(phrase) + mark_width;
    const separator = " · ";
    if (used + separator.len + story_reason_min_cols > cols) return std.mem.concat(scratch, u8, &.{ phrase, mark });
    const reason = try clipSummary(scratch, text.reason, @intCast(cols - used - display_width.visibleWidthIgnoringAnsi(separator)));
    return std.mem.concat(scratch, u8, &.{ phrase, style.text_style, separator, try inFailureStyle(scratch, reason, style), mark });
}

/// The fewest cells a failed row gives its reason; with less room the row
/// leaves the reason out.
const story_reason_min_cols = 8;

/// A row's phrase and merge note clipped to `cols` behind `lead`, with
/// `mark` after them, as clipStoryRow writes a row with no reason.
fn clipStoryPhrase(scratch: std.mem.Allocator, lead: []const u8, row: *const StoryRow, text: *const StoryRowText, mark: []const u8, cols: u16, style: SummaryStyle) ![]const u8 {
    const tail = try std.mem.concat(scratch, u8, &.{ text.suffix, mark });
    if (!entryShowsDiffStats(row.detail))
        return clipKeepingTail(scratch, try std.mem.concat(scratch, u8, &.{ lead, text.body }), tail, cols, style.text_style);
    const tail_width = display_width.visibleWidthIgnoringAnsi(tail);
    const phrase_cols: u16 = if (cols > tail_width * 2) @intCast(cols - tail_width) else cols;
    const clipped_phrase = try clipKeepingDiffStats(scratch, try std.mem.concat(scratch, u8, &.{ lead, text.body }), phrase_cols);
    const accented = try accentTrailingDiffStats(scratch, clipped_phrase, style.text_style);
    // The counts end their color, so the tail takes the row's style again.
    return if (phrase_cols == cols or tail.len == 0) accented else try std.mem.concat(scratch, u8, &.{ accented, style.text_style, tail });
}

/// Whether the call at `status_index` was the last call of a turn that has
/// ended: no other call follows it before the turn's summary.
fn callEndsTurn(entries: []const TranscriptEntry, status_index: usize) bool {
    for (entries[status_index + 1 ..]) |entry| {
        if (toolStatusEntryId(entry) != null) return false;
        switch (entry) {
            .raw_bytes => |raw| if (raw.class == .turn_summary or raw.class == .turn_cancellation) return true,
            else => {},
        }
    }
    return false;
}

/// The lines under a row: a subagent's model line and the reason its latest
/// call failed, each behind `indent`.
fn writeRowDetails(
    alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,
    writer: *std.Io.Writer,
    lines: *std.ArrayList(transcript_blocks.LineProvenance),
    row: *const StoryRow,
    indent: []const u8,
    cols: u16,
    style: SummaryStyle,
) !void {
    if (subagentStatusContinuation(row.entry, row.detail)) |continuation| {
        const clipped_continuation = try clipSummary(scratch, try std.mem.concat(scratch, u8, &.{ indent, continuation }), cols);
        try writeChildLine(alloc, writer, lines, row.entry_id, style.text_style, clipped_continuation, childLineClose(style));
    }
}

/// The style that ends a child line in the row text style: a reset, but only
/// when that style sets something.
fn childLineClose(style: SummaryStyle) []const u8 {
    return if (style.text_style.len > 0) style.reset_style else "";
}

/// Writes one line under a group's header: `open`, the text, then `close`.
fn writeChildLine(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    lines: *std.ArrayList(transcript_blocks.LineProvenance),
    entry_id: u32,
    open: []const u8,
    text: []const u8,
    close: []const u8,
) !void {
    try lines.append(alloc, .{ .entry = .{ .entry_id = entry_id, .entry_class = .tool_status, .projection_part = .group_child } });
    try writer.writeByte('\n');
    try writer.writeAll(open);
    try writer.writeAll(text);
    try writer.writeAll(close);
}

/// The minimum tail length accepted as an identity match in
/// reprojectTruncatedCommandPhrase. Genuinely truncated command phrases carry
/// roughly 116 bytes of command prefix (the compact activity bound), so a long
/// threshold cannot reject a real row; it exists to stop a short coincidental
/// tail from rewriting an unrelated one.
const min_reclip_tail_bytes = 16;

/// Returns the longest suffix of `text` that is also a prefix of `base`, when
/// it is long enough to prove the two share a command. O(n^2) over a frozen
/// phrase of at most ~120 bytes; the loop count is bounded and tiny.
fn commandTailMatch(text: []const u8, base: []const u8) ?[]const u8 {
    var len: usize = @min(text.len, base.len);
    while (len >= min_reclip_tail_bytes) : (len -= 1) {
        const tail = text[text.len - len ..];
        if (std.mem.startsWith(u8, base, tail)) return tail;
    }
    return null;
}

/// Substitutes the stored full command for a status phrase that was truncated
/// to the compact activity bound at generation time. Records carry the full
/// display whenever the command is known — captured runs, tty runs, and
/// terminal-session actions — so the phrase can be reclipped to the live
/// terminal width instead of keeping the frozen "..." marker.
///
/// The row's own leading label is preserved ("Running", "Ran", "Exited 1"):
/// the stored action label is a start-time prediction that cannot know the
/// settled outcome, and an active row must never be rewritten to the
/// completed label. Identity is proven by the command itself — the frozen
/// tail is a generation-time prefix of the stored display — which is a
/// stronger guard than comparing the predicted label against the row.
fn reprojectTruncatedCommandPhrase(
    scratch: std.mem.Allocator,
    phrase: []const u8,
    detail: ?*const ToolDetailRecord,
) !?[]const u8 {
    const record = detail orelse return null;
    if (!std.mem.endsWith(u8, phrase, "...")) return null;
    const command = record.command_display orelse return null;
    if (command.len == 0) return null;
    const body = phrase[0 .. phrase.len - "...".len];
    const tail = commandTailMatch(body, command) orelse return null;
    const label = body[0 .. body.len - tail.len];
    if (label.len == 0 or label[label.len - 1] != ' ') return null;
    return try std.mem.concat(scratch, u8, &.{ label, command });
}

/// A one-step command up to this many bytes keeps its full text in a row.
const short_command_max_len = 60;

/// What a word means to the short form, from the lists below. A word can be
/// in several, such as `sh`, a shell and an interpreter.
const WordRoles = packed struct {
    shell_setup: bool = false,
    leading_keyword: bool = false,
    step_keyword: bool = false,
    wrapper: bool = false,
    output_filter: bool = false,
    plain: bool = false,
    shell: bool = false,
    interpreter: bool = false,
    command_operator: bool = false,
    redirection: bool = false,
};

/// Every word of the lists below with its roles. One table, so a token costs
/// one lookup and the binary holds one lookup's code.
const word_roles = blk: {
    const lists = .{
        .{ "shell_setup", shell_setup_programs },
        .{ "leading_keyword", leading_keywords },
        .{ "step_keyword", step_keywords },
        .{ "wrapper", wrapper_programs },
        .{ "output_filter", output_filter_programs },
        .{ "plain", plain_programs },
        .{ "shell", shell_programs },
        .{ "interpreter", interpreter_programs },
        .{ "command_operator", command_operators },
        .{ "redirection", redirection_operators },
    };
    @setEvalBranchQuota(100_000);
    var words: [256][]const u8 = undefined;
    var roles: [256]WordRoles = undefined;
    var count: usize = 0;
    for (lists) |list| {
        for (list[1]) |word| {
            const index = for (words[0..count], 0..) |known, at| {
                if (std.mem.eql(u8, known, word)) break at;
            } else added: {
                words[count] = word;
                roles[count] = .{};
                count += 1;
                break :added count - 1;
            };
            @field(roles[index], list[0]) = true;
        }
    }
    var entries: [count]struct { []const u8, WordRoles } = undefined;
    for (&entries, words[0..count], roles[0..count]) |*entry, word, role| entry.* = .{ word, role };
    const final = entries;
    break :blk std.StaticStringMap(WordRoles).initComptime(&final);
};

noinline fn wordRoles(word: []const u8) WordRoles {
    return word_roles.get(word) orelse .{};
}

/// Programs that change the shell's own state rather than run work, so a
/// step that starts with one says nothing about what the command did.
const shell_setup_programs = [_][]const u8{
    "cd",     "pushd", "popd",  "export",   "set",    "unset",
    "source", ".",     "true",  ":",        "exit",   "wait",
    "trap",   "shopt", "alias", "ulimit",   "umask",  "[",
    "[[",     "test",  "break", "continue", "return",
};

/// Shell words that lead into the command after them.
const leading_keywords = [_][]const u8{
    "if", "then", "else", "elif", "do", "while", "until", "!",
};

/// Shell words whose whole step runs no program of its own, such as a loop's
/// header or its end.
const step_keywords = [_][]const u8{
    "for", "select", "case", "esac", "done", "fi", "in", "function",
};

/// Programs that run the program after them.
const wrapper_programs = [_][]const u8{
    "sudo", "time",    "nohup", "exec",    "command",
    "env",  "builtin", "nice",  "timeout",
};

/// Programs that only reshape the output of the step before a pipe.
const output_filter_programs = [_][]const u8{
    "head",   "tail", "grep", "rg",   "egrep", "fgrep",
    "jq",     "sed",  "awk",  "sort", "uniq",  "wc",
    "cut",    "tr",   "tee",  "less", "more",  "cat",
    "column", "fold", "nl",
};

/// Programs whose next words are arguments, not subcommands.
const plain_programs = [_][]const u8{
    "echo",     "printf",   "cat",   "ls",    "grep",     "rg",
    "find",     "fd",       "sed",   "awk",   "head",     "tail",
    "sleep",    "rm",       "cp",    "mv",    "mkdir",    "rmdir",
    "touch",    "chmod",    "chown", "ln",    "wc",       "sort",
    "uniq",     "cut",      "tr",    "tee",   "xargs",    "which",
    "test",     "pwd",      "date",  "curl",  "wget",     "jq",
    "diff",     "stat",     "du",    "df",    "ps",       "kill",
    "pkill",    "pgrep",    "open",  "tar",   "unzip",    "zip",
    "ssh",      "scp",      "rsync", "file",  "basename", "dirname",
    "realpath", "readlink", "seq",   "watch", "uname",    "whoami",
};

/// Shells whose `-c` flag runs the script that follows it.
const shell_programs = [_][]const u8{
    "sh", "bash", "zsh", "dash", "ksh",
};

/// How deep the short form looks into `sh -c` scripts inside `sh -c` scripts.
const short_command_max_depth = 2;

/// Programs that run a script named by their first argument.
const interpreter_programs = [_][]const u8{
    "sh",      "bash", "zsh", "dash", "fish", "python",
    "python3", "node", "bun", "deno", "ruby", "perl",
    "php",     "tsx",
};

const command_operators = [_][]const u8{
    ";", "(", ")", "{", "}", "|", "||", "&", "&&",
};

const redirection_operators = [_][]const u8{
    "<",  ">",  ">>", "<<",  "<<<", "<&", "<>",
    ">|", ">&", "&>", "&>>",
};

/// One step of a shell command as the short form shows it.
const ShortStep = struct {
    program: []const u8 = "",
    /// The roles of `program`, once it names one.
    program_roles: WordRoles = .{},
    words: [2][]const u8 = .{ "", "" },
    word_count: usize = 0,
    /// The step's own words are done: a flag, a path, or quoted text ended
    /// them, or its program takes none.
    closed: bool = false,
    /// A wrapper such as `timeout` came first, so its flags and its number
    /// are skipped until the program it runs.
    after_wrapper: bool = false,
    /// git's `-C <dir>` and `-c <key=value>` take the next token.
    skip_next: bool = false,
    after_pipe: bool = false,
    /// A loop header or a block's end, which the short form leaves out.
    dropped: bool = false,
    /// A shell's `-c` came, so the next token is the script it runs.
    script_flag: bool = false,
    /// The script a `sh -c` step runs, whose own steps the short form shows.
    inline_script: ?[]const u8 = null,
};

fn isWordToken(token: command_lex.ArgvToken) bool {
    if (token.quoted or token.value.len == 0) return false;
    if (!std.ascii.isLower(token.value[0])) return false;
    for (token.value) |byte| {
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-' or byte == '_' or byte == ':')) return false;
    }
    return true;
}

fn looksLikeWrapperArgument(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value[0] == '-') return true;
    // A duration or a count: "30", "5m", "1.5s".
    if (!std.ascii.isDigit(value[0])) return false;
    for (value) |byte| if (!(std.ascii.isDigit(byte) or byte == '.' or std.ascii.isLower(byte))) return false;
    return true;
}

/// A program as the short form names it: the base name of a path, except a
/// script in the current folder ("./build.sh"), which stays as written.
fn shortProgramName(value: []const u8) []const u8 {
    const slash = std.mem.findScalarLast(u8, value, '/') orelse return value;
    if (std.mem.startsWith(u8, value, "./") and slash == 1) return value;
    return value[slash + 1 ..];
}

/// Adds `token`, whose value has `roles`, to `step`.
fn addShortToken(step: *ShortStep, token: command_lex.ArgvToken, roles: WordRoles) void {
    const value = token.value;
    if (step.program.len == 0) {
        if (command_lex.is_safe_env_assignment(value) or isEnvAssignment(value)) return;
        // The `$` of a leading `$( ... )`, whose program comes after it.
        if (!token.quoted and std.mem.eql(u8, value, "$")) return;
        if (step.after_wrapper and looksLikeWrapperArgument(value)) return;
        if (roles.wrapper) {
            step.after_wrapper = true;
            return;
        }
        if (!token.quoted and roles.leading_keyword) return;
        if (!token.quoted and roles.step_keyword) {
            step.program = value;
            step.dropped = true;
            step.closed = true;
            return;
        }
        step.program = shortProgramName(value);
        step.program_roles = wordRoles(step.program);
        if (step.program_roles.plain) step.closed = true;
        return;
    }
    if (step.closed) return;
    if (step.script_flag) {
        step.inline_script = value;
        step.closed = true;
        return;
    }
    // `sh -c`, `bash -lc`: the next token is the script the shell runs.
    if (step.word_count == 0 and step.program_roles.shell and !token.quoted and
        value.len > 1 and value[0] == '-' and value[1] != '-' and findByte(value, 'c') != null)
    {
        step.script_flag = true;
        return;
    }
    if (step.skip_next) {
        step.skip_next = false;
        return;
    }
    if (step.word_count == 0 and std.mem.eql(u8, step.program, "git") and token.value.len > 0 and value[0] == '-') {
        step.skip_next = std.mem.eql(u8, value, "-C") or std.mem.eql(u8, value, "-c");
        return;
    }
    if (isWordToken(token)) {
        step.words[step.word_count] = value;
        step.word_count += 1;
        if (step.word_count == step.words.len) step.closed = true;
        return;
    }
    // An interpreter's first argument names the script it runs, quoted or not.
    if (step.word_count == 0 and step.program_roles.interpreter and value.len > 0 and value[0] != '-') {
        step.words[0] = shortProgramName(value);
        if (std.mem.startsWith(u8, step.words[0], "./")) step.words[0] = step.words[0][2..];
        step.word_count = 1;
    }
    step.closed = true;
}

fn isEnvAssignment(value: []const u8) bool {
    const eq = findByte(value, '=') orelse return false;
    if (eq == 0) return false;
    for (value[0..eq], 0..) |byte, index| {
        const ok = byte == '_' or std.ascii.isAlphabetic(byte) or (index > 0 and std.ascii.isDigit(byte));
        if (!ok) return false;
    }
    return true;
}

/// The errors of the short-form step walk, which recurses into `sh -c`
/// scripts and so cannot infer them.
const ShortStepError = std.mem.Allocator.Error || std.Io.Writer.Error;

fn finishShortStep(
    scratch: std.mem.Allocator,
    steps: *std.ArrayList([]const u8),
    raw_steps: *usize,
    step: ShortStep,
    depth: usize,
    defined: []const []const u8,
) ShortStepError!void {
    if (step.program.len == 0 and !step.after_wrapper) return;
    // A `sh -c` step shows the steps of its script, when they lex.
    if (step.inline_script) |script| if (depth < short_command_max_depth) {
        const before = steps.items.len;
        if (try collectShortSteps(scratch, script, steps, raw_steps, depth + 1) and steps.items.len > before) return;
    };
    raw_steps.* += 1;
    if (step.dropped or step.program.len == 0 or step.program_roles.shell_setup) return;
    // A call to a function the command defined runs its body, which shows.
    for (defined) |name| if (std.mem.eql(u8, step.program, name)) return;
    if (step.after_pipe and step.program_roles.output_filter) return;
    // Words past `word_count` are empty, so they add nothing.
    try steps.append(scratch, try std.mem.concat(scratch, u8, &.{
        step.program,
        if (step.word_count > 0) " " else "",
        step.words[0],
        if (step.word_count > 1) " " else "",
        step.words[1],
    }));
}

/// The closing byte of the expansion that the token at `index` opens: `)`
/// for the `(` of a `$(`, and `}` for a `{` right after a `$` or with no
/// space after it, as in `${name}` and `{1..80}`. A `{ cmd; }` group has the
/// space, so it opens no expansion. Null for other tokens.
fn expansionClose(command: []const u8, tokens: []const command_lex.ArgvToken, index: usize) ?u8 {
    const token = tokens[index];
    if (token.quoted or token.value.len != 1) return null;
    const after_dollar = token.start > 0 and command[token.start - 1] == '$';
    return switch (token.value[0]) {
        '(' => if (after_dollar) ')' else null,
        '{' => if (after_dollar or (token.end < command.len and !std.ascii.isWhitespace(command[token.end]))) '}' else null,
        else => null,
    };
}

/// Whether the tokens at `index` are the `()` of a function definition.
fn isFunctionParens(tokens: []const command_lex.ArgvToken, index: usize) bool {
    if (index + 1 >= tokens.len) return false;
    const open = tokens[index];
    const close = tokens[index + 1];
    return !open.quoted and !close.quoted and std.mem.eql(u8, open.value, "(") and std.mem.eql(u8, close.value, ")");
}

/// Whether the token at `index` is the file descriptor of a redirection
/// right after it, as the `2` in `2>&1`.
fn isRedirectionFd(tokens: []const command_lex.ArgvToken, index: usize) bool {
    const token = tokens[index];
    if (token.quoted or token.value.len == 0 or index + 1 >= tokens.len) return false;
    for (token.value) |byte| if (!std.ascii.isDigit(byte)) return false;
    const next = tokens[index + 1];
    return !next.quoted and next.start == token.end and wordRoles(next.value).redirection;
}

fn expansionOpen(close: u8) u8 {
    return if (close == ')') '(' else '{';
}

fn gapHasNewline(command: []const u8, from: usize, to: usize) bool {
    if (from >= to) return false;
    return findByte(command[from..to], '\n') != null;
}

/// A shell command's short form: the first steps it runs, and how many more.
const ShortCommand = struct {
    steps: []const []const u8,
    /// How many steps after `steps` the form leaves out.
    more: usize,
    /// How many steps before `steps` the form leaves out.
    earlier: usize = 0,
};

const short_command_max_steps = 3;

/// The short form as plain text, such as "npm ci, npm run build".
fn shortCommand(scratch: std.mem.Allocator, command: []const u8) !?[]const u8 {
    const short = try shortCommandSteps(scratch, command, command) orelse return null;
    return try formatShortCommand(scratch, short, null);
}

/// Writes a short form, with every step made terminal-safe. With a style,
/// each step takes the shell palette on its own, so every step's program
/// shows in the same color, and the ", " between them stays plain.
fn formatShortCommand(scratch: std.mem.Allocator, short: ShortCommand, base_style: ?[]const u8) ![]const u8 {
    const profile = if (base_style != null) code_highlight_languages.resolve("sh") else null;
    const variant: code_highlight.Theme = if (shared_theme.current().light) .light else .dark;
    var out: std.Io.Writer.Allocating = .init(scratch);
    if (short.earlier > 0) try writeCount(&out.writer, "+", short.earlier, ", ");
    for (short.steps, 0..) |step, position| {
        if (position > 0) try out.writer.writeAll(", ");
        const safe = try terminalSafeText(scratch, step);
        if (profile) |shell| {
            const style = base_style.?;
            try out.writer.writeAll(try code_highlight.highlight(scratch, safe, shell, variant, if (style.len > 0) style else null));
        } else try out.writer.writeAll(safe);
    }
    if (short.more > 0) try writeCount(&out.writer, " +", short.more, " more");
    return out.written();
}

/// The steps a shell command runs, by program and subcommand, without flags,
/// arguments, `cd`, variables, wrappers, and output filters, so
/// "cd desktop && npm ci --no-audit && npm run build -- --mode production"
/// is "npm ci, npm run build". A one-step command whose `shown` text, the
/// command as its row shows it, is at most short_command_max_len bytes keeps
/// that text. Null when the command keeps its text or does not lex. The steps
/// live in `scratch`.
fn shortCommandSteps(scratch: std.mem.Allocator, command: []const u8, shown_text: []const u8) !?ShortCommand {
    var steps: std.ArrayList([]const u8) = .empty;
    var raw_steps: usize = 0;
    if (!try collectShortSteps(scratch, command, &steps, &raw_steps, 0)) return null;
    // The same step twice in a row shows once.
    var shown: std.ArrayList([]const u8) = .empty;
    for (steps.items) |text| {
        if (shown.items.len > 0 and std.mem.eql(u8, shown.items[shown.items.len - 1], text)) continue;
        try shown.append(scratch, text);
    }
    if (shown.items.len == 0) return null;
    if (raw_steps <= 1 and shown_text.len <= short_command_max_len) return null;
    // A command that is already its own short form keeps its text.
    if (shown.items.len == 1 and (std.mem.eql(u8, shown.items[0], command) or std.mem.eql(u8, shown.items[0], shown_text))) return null;
    const kept = @min(shown.items.len, short_command_max_steps);
    return .{ .steps = shown.items[0..kept], .more = shown.items.len - kept };
}

/// Appends the steps `command` runs to `steps`, and counts every step it has,
/// shown or not, in `raw_steps`. False when the command does not lex.
fn collectShortSteps(
    scratch: std.mem.Allocator,
    command: []const u8,
    steps: *std.ArrayList([]const u8),
    raw_steps: *usize,
    depth: usize,
) ShortStepError!bool {
    // A here-document's body is text for the program, not shell words, so
    // an apostrophe in it does not stop the command from lexing.
    const here_docs = try withoutHereDocBodies(scratch, command);
    const source = here_docs.text;
    const argv = command_lex.tokenize_argv(scratch, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const tokens = argv.tokens;

    var step: ShortStep = .{};
    // Functions the command defines, such as `p() { sed -n "$1"p f; }`.
    var defined: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index <= tokens.len) : (index += 1) {
        const at_end = index == tokens.len;
        const token: ?command_lex.ArgvToken = if (at_end) null else tokens[index];
        // A comment runs to the end of its line.
        if (!at_end and !tokens[index].quoted and std.mem.startsWith(u8, tokens[index].raw, "#")) {
            while (index + 1 < tokens.len and !gapHasNewline(source, tokens[index].end, tokens[index + 1].start)) index += 1;
            continue;
        }
        // A command substitution, `$( ... )`, and an expansion such as
        // `{1..80}` or `${name}` belong to the word around them.
        if (!at_end) if (expansionClose(source, tokens, index)) |close| {
            var nesting: usize = 0;
            while (index < tokens.len) : (index += 1) {
                const inner = tokens[index];
                if (inner.quoted or inner.value.len != 1) continue;
                if (inner.value[0] == expansionOpen(close)) nesting += 1;
                if (inner.value[0] == close) {
                    nesting -= 1;
                    if (nesting == 0) break;
                }
            }
            continue;
        };
        // `name() { ...; }` defines a function: its body shows, and calls to
        // it are not steps of their own.
        if (!at_end and step.program.len > 0 and step.word_count == 0 and !step.dropped and isFunctionParens(tokens, index)) {
            try defined.append(scratch, step.program);
            step.dropped = true;
            index += 1;
            continue;
        }
        const roles: WordRoles = if (token) |t| wordRoles(t.value) else .{};
        const operator = if (token) |t| !t.quoted and roles.command_operator else false;
        const new_line = if (token) |t| index > 0 and gapHasNewline(source, tokens[index - 1].end, t.start) else false;
        if (at_end or operator or new_line) {
            try finishShortStep(scratch, steps, raw_steps, step, depth, defined.items);
            step = .{ .after_pipe = operator and std.mem.eql(u8, token.?.value, "|") };
            if (operator or at_end) continue;
        }
        const t = token.?;
        if (isRedirectionFd(tokens, index)) continue;
        // A here-document's operator and delimiter, whose body and closing
        // line `source` no longer has, are like a redirection: neither is a
        // word of the step. A command whose lines core folded into one still
        // has its body and closing delimiter on this line, and the step ends
        // at that delimiter.
        if (!t.quoted and std.mem.startsWith(u8, t.value, "<<") and !std.mem.eql(u8, t.value, "<<<")) {
            const joined = t.value.len > 2;
            if (!joined and index + 1 < tokens.len) index += 1;
            const delimiter = std.mem.trimStart(u8, if (joined) t.value[2..] else tokens[index].value, "-");
            var end = index + 1;
            const closing: ?usize = if (!here_docs.open) null else while (end < tokens.len and !gapHasNewline(source, tokens[end - 1].end, tokens[end].start)) : (end += 1) {
                if (delimiter.len > 0 and std.mem.eql(u8, tokens[end].value, delimiter)) break end;
            } else null;
            if (closing) |at| {
                index = at;
                try finishShortStep(scratch, steps, raw_steps, step, depth, defined.items);
                step = .{};
            }
            continue;
        }
        if (step.program.len == 0 and !t.quoted and std.mem.eql(u8, t.value, "function") and index + 1 < tokens.len) {
            try defined.append(scratch, tokens[index + 1].value);
            step.program = "function";
            step.dropped = true;
            step.closed = true;
            index += 1;
            continue;
        }
        if (!t.quoted and roles.redirection) {
            // A redirection's target is not a word of the step.
            index += 1;
            continue;
        }
        addShortToken(&step, t, roles);
    }
    return true;
}

/// A command's text without its here-document bodies.
const HereDocText = struct {
    text: []const u8,
    /// Whether a here-document's body is still in `text`, as in a command
    /// whose lines core folded into one.
    open: bool = false,
};

/// `command` without the bodies of its here-documents and their closing
/// lines, such as the lines after `cat > notes.md <<'EOF'` up to and with
/// `EOF`, so the line that opened them ends their step. A command with no
/// `<<` is returned as is; `<<<` and a shift inside `$(( ))` open no
/// here-document. The text lives in `scratch`.
fn withoutHereDocBodies(scratch: std.mem.Allocator, command: []const u8) std.mem.Allocator.Error!HereDocText {
    if (std.mem.find(u8, command, "<<") == null) return .{ .text = command };
    const HereDoc = struct { delimiter: []const u8, strip_tabs: bool };
    var out: std.ArrayList(u8) = .empty;
    var pending: std.ArrayList(HereDoc) = .empty;
    var quote: u8 = 0;
    var arithmetic: usize = 0;
    var index: usize = 0;
    while (index < command.len) {
        const byte = command[index];
        if (quote == '\'') {
            if (byte == '\'') quote = 0;
            try out.append(scratch, byte);
            index += 1;
            continue;
        }
        if (byte == '\\' and index + 1 < command.len) {
            try out.appendSlice(scratch, command[index .. index + 2]);
            index += 2;
            continue;
        }
        if (quote == '"') {
            if (byte == '"') quote = 0;
            try out.append(scratch, byte);
            index += 1;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            try out.append(scratch, byte);
            index += 1;
            continue;
        }
        // A comment runs to the end of its line.
        if (byte == '#' and (index == 0 or std.mem.findScalar(u8, " \t\n;&|(", command[index - 1]) != null)) {
            const line_end = std.mem.findScalarPos(u8, command, index, '\n') orelse command.len;
            try out.appendSlice(scratch, command[index..line_end]);
            index = line_end;
            continue;
        }
        if (std.mem.startsWith(u8, command[index..], "$((")) {
            arithmetic += 1;
            try out.appendSlice(scratch, "$((");
            index += 3;
            continue;
        }
        if (arithmetic > 0 and std.mem.startsWith(u8, command[index..], "))")) {
            arithmetic -= 1;
            try out.appendSlice(scratch, "))");
            index += 2;
            continue;
        }
        // A here-string's `<<<` opens no here-document, at any of its bytes.
        if (std.mem.startsWith(u8, command[index..], "<<<")) {
            try out.appendSlice(scratch, "<<<");
            index += 3;
            continue;
        }
        if (arithmetic == 0 and std.mem.startsWith(u8, command[index..], "<<")) {
            var scan = index + 2;
            const strip_tabs = scan < command.len and command[scan] == '-';
            if (strip_tabs) scan += 1;
            while (scan < command.len and (command[scan] == ' ' or command[scan] == '\t')) scan += 1;
            // The delimiter is one word, with its quotes and escapes taken out.
            var delimiter: std.ArrayList(u8) = .empty;
            var delimiter_quote: u8 = 0;
            while (scan < command.len) : (scan += 1) {
                const c = command[scan];
                if (delimiter_quote != 0) {
                    if (c == delimiter_quote) delimiter_quote = 0 else try delimiter.append(scratch, c);
                    continue;
                }
                if (c == '\'' or c == '"') {
                    delimiter_quote = c;
                    continue;
                }
                if (c == '\\') continue;
                if (std.ascii.isWhitespace(c) or std.mem.findScalar(u8, ";&|<>()", c) != null) break;
                try delimiter.append(scratch, c);
            }
            if (delimiter.items.len > 0) try pending.append(scratch, .{ .delimiter = delimiter.items, .strip_tabs = strip_tabs });
            try out.appendSlice(scratch, command[index..scan]);
            index = scan;
            continue;
        }
        try out.append(scratch, byte);
        index += 1;
        if (byte != '\n' or pending.items.len == 0) continue;
        // The lines after the one that opened here-documents are their
        // bodies, one after another, each up to its delimiter line.
        for (pending.items, 0..) |here_doc, position| {
            // The next body starts after the line that closed the last one.
            if (position > 0 and index < command.len) index += 1;
            while (index < command.len) {
                const line_end = std.mem.findScalarPos(u8, command, index, '\n') orelse command.len;
                var line = std.mem.trimEnd(u8, command[index..line_end], "\r");
                if (here_doc.strip_tabs) line = std.mem.trimStart(u8, line, "\t");
                index = line_end;
                if (std.mem.eql(u8, line, here_doc.delimiter)) break;
                if (index < command.len) index += 1;
            }
        }
        pending.clearRetainingCapacity();
        // The newline after the last closing line follows the opening line.
        if (index < command.len) index += 1;
    }
    return .{ .text = out.items, .open = pending.items.len > 0 };
}

/// Replaces the command a command row ends with by its short form, so a long
/// command does not fill the row, and colors each step. `base_style` is the
/// row's text style, as for highlightCommandPhrase. The full command stays in
/// Ctrl+O and in approval prompts. Null when the row keeps its full command.
fn shortenCommandPhrase(
    scratch: std.mem.Allocator,
    phrase: []const u8,
    detail: ?*const ToolDetailRecord,
    base_style: []const u8,
) !?[]const u8 {
    const record = detail orelse return null;
    if (record.activity_kind != .command) return null;
    const display = record.command_display orelse return null;
    if (display.len == 0 or phrase.len <= display.len or !std.mem.endsWith(u8, phrase, display)) return null;
    const label = phrase[0 .. phrase.len - display.len];
    if (label[label.len - 1] != ' ') return null;
    // Lex the command as the model sent it. The display folds its lines into
    // one, which would turn a comment line into a comment over the whole
    // command.
    const source = storyArgString(scratch, record, "command") orelse display;
    const short = try shortCommandSteps(scratch, source, display) orelse return null;
    return try std.mem.concat(scratch, u8, &.{ label, try formatShortCommand(scratch, short, base_style) });
}

/// Shell-highlight the command portion of a command phrase ("Running <cmd>",
/// "Ran <cmd>"). The leading action word and connector stay in the row's
/// ambient style; only the command's syntax tokens pick up palette colors.
/// `base_style` (the row's text style, when any) is re-established after every
/// token close so untokenized text keeps the row's color.
/// Multi-word status labels that can lead a command row when no label was
/// recorded. Mirrors the terminal-outcome labels composed in
/// tool_admission.permissionDeniedStatusLabel and the lifecycle rows.
const known_multiword_labels = [_][]const u8{
    "Denied by auto agent",
    "Review evidence incomplete",
    "Permission required",
    "Safety caution",
    "Review unavailable",
    "Timed out",
    still_running_label,
};

fn knownLabelPrefix(phrase: []const u8) ?usize {
    for (known_multiword_labels) |label| {
        if (std.mem.startsWith(u8, phrase, label) and phrase.len > label.len and phrase[label.len] == ' ')
            return label.len;
    }
    return null;
}

fn highlightCommandPhrase(
    scratch: std.mem.Allocator,
    phrase: []const u8,
    detail: ?*const ToolDetailRecord,
    base_style: []const u8,
) !?[]const u8 {
    const record = detail orelse return null;
    if (record.activity_kind != .command) return null;
    // Prefer the recorded action label so multi-word labels ("Timed out")
    // split at the true boundary. Otherwise trust the stored command text:
    // prose-prefixed rows ("Reading project instructions before continuing:
    // <cmd>") end with it. Then known multi-word labels, then first space.
    const label_end = if (record.command_action_label) |action|
        if (std.mem.startsWith(u8, phrase, action) and phrase.len > action.len and phrase[action.len] == ' ')
            action.len
        else
            null
    else
        null;
    const display_end = if (record.command_display) |display| blk: {
        if (display.len == 0 or phrase.len <= display.len + 1) break :blk null;
        if (!std.mem.endsWith(u8, phrase, display)) break :blk null;
        const split_at = phrase.len - display.len - 1;
        break :blk if (phrase[split_at] == ' ') split_at else null;
    } else null;
    const split = label_end orelse display_end orelse knownLabelPrefix(phrase) orelse findByte(phrase, ' ') orelse return null;
    const command = phrase[split + 1 ..];
    if (command.len == 0) return null;
    const theme = shared_theme.current();
    const profile = code_highlight_languages.resolve("sh") orelse return null;
    const variant: code_highlight.Theme = if (theme.light) .light else .dark;
    // Commands without tokens keep their exact plain bytes.
    const plain = try code_highlight.highlight(scratch, command, profile, variant, null);
    if (std.mem.eql(u8, plain, command)) return null;
    const highlighted = try code_highlight.highlight(
        scratch,
        command,
        profile,
        variant,
        if (base_style.len > 0) base_style else null,
    );
    return try std.mem.concat(scratch, u8, &.{ phrase[0..split], " ", highlighted });
}

/// One expanded child as complete logical rows. Expanded rows are never
/// clipped; materializeExpandedOverride wraps them to the live width.
/// Ctrl+O's line for one tool call: its state mark, then its phrase at the
/// two-column indent responses use, with no tree marks, and any status
/// continuation under the four-column detail indent.
fn formatExpandedChild(
    alloc: std.mem.Allocator,
    entry: TranscriptEntry,
    detail: ?*const ToolDetailRecord,
) ![]u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();
    const raw_phrase = switch (entry) {
        .raw_bytes => |raw| try normalizeStatusPhrase(scratch, raw.bytes),
        else => null,
    } orelse if (detail) |record| record.tool_name else "tool activity";
    const phrase = try reprojectTruncatedCommandPhrase(
        scratch,
        raw_phrase,
        detail,
    ) orelse raw_phrase;
    // Expanded rows carry no ambient text style, so tokens highlight over the
    // terminal default foreground.
    const display_phrase = try highlightCommandPhrase(scratch, phrase, detail, "") orelse phrase;
    const marker = statusMarker(entry);
    // A colored mark ends its color before the phrase.
    const marker_reset = if (findByte(marker, 0x1b) != null and
        !std.mem.endsWith(u8, marker, ui_render.reset_style))
        ui_render.reset_style
    else
        "";
    const child = try std.mem.concat(scratch, u8, &.{ marker, marker_reset, " ", display_phrase });
    const accented = if (entryShowsDiffStats(detail))
        try accentTrailingDiffStats(scratch, child, "")
    else
        child;
    const continuation = subagentStatusContinuation(entry, detail) orelse return alloc.dupe(u8, accented);
    return std.mem.concat(alloc, u8, &.{ accented, "\n    ", continuation });
}

test "expanded subagent row preserves status continuation" {
    const alloc = std.testing.allocator;
    const entry = TranscriptEntry{ .raw_bytes = .{
        .id = 7,
        .bytes = "● reviewer working · inspect auth\n  gpt-5.5 · high · 12k/256k 4%\n",
        .class = .tool_status,
    } };
    const detail = ToolDetailRecord{
        .entry_id = 7,
        .tool_name = @constCast("subagent"),
        .activity_kind = .subagent,
    };
    const row = try formatExpandedChild(alloc, entry, &detail);
    defer alloc.free(row);

    try std.testing.expectEqualStrings(
        "● reviewer working · inspect auth\n    gpt-5.5 · high · 12k/256k 4%",
        row,
    );
}

/// Every call of a group gets its own line in Ctrl+O, in order, with no
/// group header: the main screen's summary would only repeat them.
fn installExpandedGroup(
    alloc: std.mem.Allocator,
    projection: *Projection,
    entries: []const TranscriptEntry,
    status_indices: []const usize,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !void {
    for (status_indices) |status_index| {
        try build_checkpoint.tick(checkpoint);
        const entry = entries[status_index];
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null);
        // The projection owns the line from here, and frees it on failure.
        try projection.setOwnedOverride(alloc, status_index, .tool_status, try formatExpandedChild(alloc, entry, detail));
    }
}

fn presentationGroupId(
    detail: ?*const ToolDetailRecord,
) ?types.ToolPresentationGroupId {
    const record = detail orelse return null;
    return record.presentation_group_id;
}

fn sortedDetailForEntry(
    details: []const ToolDetailRecord,
    entry_id: u32,
) ?*const ToolDetailRecord {
    var low: usize = 0;
    var high = details.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (details[middle].entry_id < entry_id) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return if (low < details.len and details[low].entry_id == entry_id)
        &details[low]
    else
        null;
}

pub fn incrementalRebuildStart(
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    dirty_entry_index: usize,
) ?usize {
    if (dirty_entry_index >= entries.len) return null;
    var first = dirty_entry_index;
    const dirty_entry_id = entries[first].id();

    const dirty_group = presentationGroupId(sortedDetailForEntry(details, dirty_entry_id));
    if (dirty_group) |group_id| {
        for (entries, 0..) |entry, index| {
            const detail = sortedDetailForEntry(details, entry.id()) orelse continue;
            const candidate = detail.presentation_group_id orelse continue;
            if (candidate.turn_id != group_id.turn_id or
                candidate.anchor_step_id != group_id.anchor_step_id) continue;
            first = @min(first, index);
        }
    }

    const first_entry = entries[first];
    if (toolStatusEntryId(first_entry) == null and
        !isAttachedEntry(first_entry) and
        !isTransparentCompactEntry(first_entry)) return first;

    while (first > 0) {
        const previous = entries[first - 1];
        if (toolStatusEntryId(previous) == null and
            !isAttachedEntry(previous) and
            !isTransparentCompactEntry(previous)) break;
        first -= 1;
    }
    return first;
}

fn statusIndexLessThan(
    entries: []const TranscriptEntry,
    lhs: usize,
    rhs: usize,
) bool {
    return toolStatusEntryId(entries[lhs]).? < toolStatusEntryId(entries[rhs]).?;
}

fn hideAttachedRows(
    entries: []const TranscriptEntry,
    entry_actions: []transcript_blocks.EntryRenderAction,
    status_index: usize,
) void {
    var index = status_index + 1;
    while (index < entries.len) : (index += 1) {
        if (toolStatusEntryId(entries[index]) != null) break;
        if (isAttachedEntry(entries[index])) {
            entry_actions[index] = .hide;
            continue;
        }
        if (!isTransparentCompactEntry(entries[index])) break;
    }
}

fn build(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
) !Projection {
    return buildWithStyleAndStats(alloc, entries, details, cols, null, false, .{}, .{}, .compact, null, null) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn buildStyled(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
) !Projection {
    return buildWithStyleAndStats(alloc, entries, details, cols, null, false, style, styles, .compact, null, null) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

/// Full-transcript tool rows fitted to `cols`. Builds the same relationships
/// the live full transcript caches and materializes them, so every
/// full-transcript build shares one width policy.
pub fn buildExpandedStyledInterruptible(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !Projection {
    var relationships = try buildExpandedRelationshipsInterruptible(alloc, entries, details, checkpoint);
    defer relationships.deinit(alloc);
    return materializeExpandedRelationshipsRangeInterruptible(alloc, &relationships, 0, cols, checkpoint);
}

pub fn buildExpandedRelationshipsInterruptible(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !Projection {
    return buildWithStyleAndStats(
        alloc,
        entries,
        details,
        std.math.maxInt(u16),
        null,
        false,
        .{},
        .{},
        .expanded,
        null,
        checkpoint,
    );
}

pub fn materializeExpandedRelationshipsRangeInterruptible(
    alloc: std.mem.Allocator,
    relationships: *const Projection,
    start_index: usize,
    cols: u16,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !Projection {
    std.debug.assert(start_index <= relationships.entry_actions.items.len);
    var projection: Projection = .{};
    errdefer projection.deinit(alloc);
    try projection.entry_actions.ensureTotalCapacity(
        alloc,
        relationships.entry_actions.items.len - start_index,
    );
    for (relationships.entry_actions.items[start_index..]) |action| {
        try build_checkpoint.tick(checkpoint);
        switch (action) {
            .keep => projection.entry_actions.appendAssumeCapacity(.keep),
            .hide => projection.entry_actions.appendAssumeCapacity(.hide),
            .override => |override| {
                const bytes = try materializeExpandedOverride(alloc, override.bytes, cols);
                try projection.appendOwnedOverride(alloc, override.kind, bytes);
            },
        }
    }
    return projection;
}

/// Fits one expanded override to `cols` without hiding any of it. The full
/// transcript exists to show everything, so rows word-wrap instead of
/// clipping, and each wrapped row continues under the detail indent.
fn materializeExpandedOverride(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    cols: u16,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.writer.writeByte('\n');
        first = false;
        const wrapped = try transcript_blocks.wrapFullToolStatus(alloc, line, cols, "    ");
        defer alloc.free(wrapped);
        try out.writer.writeAll(wrapped);
    }
    return out.toOwnedSlice();
}

pub fn buildStyledFocused(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    focused_entry_id: ?u32,
    collapse_tool_calls: bool,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
) !Projection {
    return buildStyledFocusedInterruptible(
        alloc,
        entries,
        details,
        cols,
        focused_entry_id,
        collapse_tool_calls,
        style,
        styles,
        null,
    ) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn buildStyledFocusedInterruptible(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    focused_entry_id: ?u32,
    collapse_tool_calls: bool,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !Projection {
    return buildWithStyleAndStats(
        alloc,
        entries,
        details,
        cols,
        focused_entry_id,
        collapse_tool_calls,
        style,
        styles,
        .compact,
        null,
        checkpoint,
    );
}

fn buildWithStats(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    stats: ?*BuildStats,
) !Projection {
    return buildWithStyleAndStats(alloc, entries, details, cols, null, false, .{}, .{}, .compact, stats, null);
}

fn buildWithStyleAndStats(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    focused_entry_id: ?u32,
    collapse_tool_calls: bool,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
    mode: ProjectionMode,
    stats: ?*BuildStats,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !Projection {
    var projection: Projection = .{};
    errdefer projection.deinit(alloc);
    var detail_indices: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    defer detail_indices.deinit(alloc);
    const presentation_group_indices = try alloc.alloc(?usize, entries.len);
    defer alloc.free(presentation_group_indices);
    var presentation_groups: std.ArrayList(PresentationGroup) = .empty;
    defer {
        for (presentation_groups.items) |*group| group.deinit(alloc);
        presentation_groups.deinit(alloc);
    }
    var presentation_group_by_id: std.AutoHashMapUnmanaged(
        types.ToolPresentationGroupId,
        usize,
    ) = .empty;
    defer presentation_group_by_id.deinit(alloc);
    // fillProjection has no cleanup of its own, so its many failure points,
    // such as each checkpoint tick, share this one; each `try` here would
    // repeat the cleanup in the binary.
    try fillProjection(alloc, &projection, &detail_indices, presentation_group_indices, &presentation_groups, &presentation_group_by_id, entries, details, cols, focused_entry_id, collapse_tool_calls, style, styles, mode, stats, checkpoint);
    return projection;
}

/// Fills `projection` with every entry's action. The caller owns the state
/// it works in and frees it.
fn fillProjection(
    alloc: std.mem.Allocator,
    projection: *Projection,
    detail_indices: *std.AutoHashMapUnmanaged(u32, usize),
    presentation_group_indices: []?usize,
    presentation_groups: *std.ArrayList(PresentationGroup),
    presentation_group_by_id: *std.AutoHashMapUnmanaged(types.ToolPresentationGroupId, usize),
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    focused_entry_id: ?u32,
    collapse_tool_calls: bool,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
    mode: ProjectionMode,
    stats: ?*BuildStats,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !void {
    try projection.entry_actions.appendNTimes(alloc, .keep, entries.len);
    if (mode == .compact) {
        for (entries, projection.entry_actions.items) |entry, *action| {
            switch (entry) {
                .raw_bytes => |raw| if (raw.class == .command_output) {
                    action.* = .hide;
                },
                else => {},
            }
        }
    }

    for (details, 0..) |detail, detail_index| {
        try build_checkpoint.tick(checkpoint);
        const result = try detail_indices.getOrPut(alloc, detail.entry_id);
        if (!result.found_existing) result.value_ptr.* = detail_index;
    }

    @memset(presentation_group_indices, null);

    // A message the user sends while a turn runs joins that turn, so the
    // calls after it share the turn's group. Their rows belong after the
    // message, not above it, so they start a new group.
    var user_messages: usize = 0;
    for (entries, 0..) |entry, entry_index| {
        try build_checkpoint.tick(checkpoint);
        if (entry == .user_turn) user_messages += 1;
        if (mode == .compact and !transcript_blocks.isEntryVisibleInCompactPresentation(entry)) continue;
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, stats);
        if (statusNamesAsk(entry, detail)) continue;
        const group_id = presentationGroupId(detail) orelse continue;

        const result = try presentation_group_by_id.getOrPut(alloc, group_id);
        if (!result.found_existing or presentation_groups.items[result.value_ptr.*].user_messages_before != user_messages) {
            result.value_ptr.* = presentation_groups.items.len;
            try presentation_groups.append(alloc, .{ .anchor_index = entry_index, .user_messages_before = user_messages });
        }
        const group_index = result.value_ptr.*;
        const group = &presentation_groups.items[group_index];
        try group.status_indices.append(alloc, entry_index);
        observeTool(&group.summary, detail);
        presentation_group_indices[entry_index] = group_index;
    }
    for (presentation_groups.items) |*group| {
        try build_checkpoint.tick(checkpoint);
        sort_utils.sort(
            usize,
            group.status_indices.items,
            entries,
            statusIndexLessThan,
        );
    }

    if (mode == .expanded) {
        for (presentation_groups.items) |*group| {
            try build_checkpoint.tick(checkpoint);
            try installExpandedGroup(
                alloc,
                projection,
                entries,
                group.status_indices.items,
                details,
                detail_indices,
                checkpoint,
            );
        }

        var expanded_index: usize = 0;
        while (expanded_index < entries.len) {
            try build_checkpoint.tick(checkpoint);
            if (presentation_group_indices[expanded_index] != null) {
                expanded_index += 1;
                continue;
            }
            const entry_id = toolStatusEntryId(entries[expanded_index]) orelse {
                expanded_index += 1;
                continue;
            };
            const detail = detailForEntry(details, detail_indices, entry_id, stats);
            if (statusNamesAsk(entries[expanded_index], detail)) {
                expanded_index += 1;
                continue;
            }

            var status_indices: std.ArrayList(usize) = .empty;
            defer status_indices.deinit(alloc);
            while (expanded_index < entries.len) : (expanded_index += 1) {
                try build_checkpoint.tick(checkpoint);
                if (presentation_group_indices[expanded_index] != null) break;
                if (toolStatusEntryId(entries[expanded_index])) |group_entry_id| {
                    const group_detail = detailForEntry(details, detail_indices, group_entry_id, stats);
                    if (statusNamesAsk(entries[expanded_index], group_detail)) break;
                    try status_indices.append(alloc, expanded_index);
                    continue;
                }
                if (!isAttachedEntry(entries[expanded_index]) and
                    !isTransparentCompactEntry(entries[expanded_index])) break;
            }
            try installExpandedGroup(
                alloc,
                projection,
                entries,
                status_indices.items,
                details,
                detail_indices,
                checkpoint,
            );
        }
        return;
    }

    var index: usize = 0;
    while (index < entries.len) {
        try build_checkpoint.tick(checkpoint);
        // Hidden entries keep their action, but grouping below skips them, so
        // they must not anchor a group either.
        if (projection.entry_actions.items[index] != .keep or
            !transcript_blocks.isEntryVisibleInCompactPresentation(entries[index]))
        {
            index += 1;
            continue;
        }
        const entry_id = toolStatusEntryId(entries[index]) orelse {
            index += 1;
            continue;
        };

        if (presentation_group_indices[index]) |group_index| {
            const group = &presentation_groups.items[group_index];
            if (index != group.anchor_index) {
                projection.entry_actions.items[index] = .hide;
                index += 1;
                continue;
            }
            for (group.status_indices.items) |status_index| {
                projection.entry_actions.items[status_index] = .hide;
                hideAttachedRows(
                    entries,
                    projection.entry_actions.items,
                    status_index,
                );
            }

            const bytes = try formatGroupBlock(
                alloc,
                entries,
                group.status_indices.items,
                details,
                detail_indices,
                group.summary,
                focused_entry_id,
                collapse_tool_calls,
                cols,
                style,
                styles,
            );
            if (bytes.bytes.len == 0) {
                // Its calls name nothing yet, so the group shows nothing.
                alloc.free(bytes.bytes);
                alloc.free(bytes.lines);
            } else try projection.setOwnedGroup(alloc, index, bytes);
            index += 1;
            continue;
        }

        const detail = detailForEntry(details, detail_indices, entry_id, stats);
        if (statusNamesAsk(entries[index], detail)) {
            index += 1;
            continue;
        }

        const first_index = index;
        const updates_run = isSubagentUpdateRow(detail);
        var status_indices: std.ArrayList(usize) = .empty;
        defer status_indices.deinit(alloc);
        var summary: Summary = .{};

        while (index < entries.len) : (index += 1) {
            try build_checkpoint.tick(checkpoint);
            if (!transcript_blocks.isEntryVisibleInCompactPresentation(entries[index])) continue;
            if (presentation_group_indices[index] != null) break;
            if (toolStatusEntryId(entries[index])) |group_entry_id| {
                const group_detail = detailForEntry(details, detail_indices, group_entry_id, stats);
                if (statusNamesAsk(entries[index], group_detail)) break;
                if (isSubagentUpdateRow(group_detail) != updates_run) break;
                observeTool(&summary, group_detail);
                try status_indices.append(alloc, index);
                projection.entry_actions.items[index] = .hide;
                continue;
            }
            if (isAttachedEntry(entries[index])) {
                projection.entry_actions.items[index] = .hide;
                continue;
            }
            if (!isTransparentCompactEntry(entries[index])) break;
        }

        const bytes = try formatGroupBlock(
            alloc,
            entries,
            status_indices.items,
            details,
            detail_indices,
            summary,
            focused_entry_id,
            collapse_tool_calls,
            cols,
            style,
            styles,
        );
        if (bytes.bytes.len == 0) {
            alloc.free(bytes.bytes);
            alloc.free(bytes.lines);
        } else try projection.setOwnedGroup(alloc, first_index, bytes);
    }

    try recapTurnSummaries(alloc, projection, entries, details, detail_indices, cols, checkpoint);
}

/// Leads each visible turn summary with its turn's recap. A function of its
/// own, so its failure points share one of the caller's cleanup paths.
fn recapTurnSummaries(
    alloc: std.mem.Allocator,
    projection: *Projection,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    cols: u16,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !void {
    for (entries, 0..) |entry, entry_index| {
        try build_checkpoint.tick(checkpoint);
        const raw = switch (entry) {
            .raw_bytes => |value| value,
            else => continue,
        };
        if (raw.class != .turn_summary or projection.entry_actions.items[entry_index] != .keep) continue;
        if (!transcript_blocks.isEntryVisibleInCompactPresentation(entry)) continue;
        const recapped = try recapTurnSummary(alloc, entries, details, detail_indices, entry_index, cols) orelse continue;
        try projection.setOwnedOverride(alloc, entry_index, .turn_summary, recapped);
    }
}

/// Visible width of a row once the "[G]" and "[R]" stand-ins for the diff
/// marker styles are removed, since the stand-ins are visible text.
fn widthWithoutTestMarkersForTest(alloc: std.mem.Allocator, row: []const u8) !usize {
    const without_added = try std.mem.replaceOwned(u8, alloc, row, "[G]", "");
    defer alloc.free(without_added);
    const plain = try std.mem.replaceOwned(u8, alloc, without_added, "[R]", "");
    defer alloc.free(plain);
    return display_width.visibleWidthIgnoringAnsi(plain);
}

/// Paints expanded rows through the terminal engine so tests assert what the
/// full transcript shows. Each row must already fit `cols`.
fn paintExpandedRowsForTest(alloc: std.mem.Allocator, bytes: []const u8, cols: u16) !vt_emulator.Grid {
    var rows: u16 = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| : (rows += 1) {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
    }
    var grid = try vt_emulator.Grid.init(alloc, cols, rows);
    errdefer grid.deinit();
    try grid.feed(bytes);
    return grid;
}

/// Visible text of grid rows `first..last` with tree glyphs and spaces
/// removed, so a wrapped row compares equal to its source wherever the wrap
/// fell. The caller owns the result.
fn paintedTreeTextForTest(
    alloc: std.mem.Allocator,
    grid: *const vt_emulator.Grid,
    first: u16,
    last: u16,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(alloc);
    var row = first;
    while (row <= last) : (row += 1) {
        row_text.clearRetainingCapacity();
        try grid.rowTextTrimmed(row, &row_text);
        var text: []const u8 = row_text.items;
        for ([_][]const u8{ "├", "└", "│" }) |glyph| {
            if (std.mem.startsWith(u8, text, glyph)) {
                text = text[glyph.len..];
                break;
            }
        }
        for (text) |byte| {
            if (byte != ' ') try out.append(alloc, byte);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// The visible text of the group `build` makes from `entries`, one line per
/// row, without colors. The caller owns the result.
fn groupTextForTest(alloc: std.mem.Allocator, entries: []const TranscriptEntry, details: []const ToolDetailRecord) ![]u8 {
    var group = try build(alloc, entries, details, 120);
    defer group.deinit(alloc);
    var painted: std.ArrayList(u8) = .empty;
    defer painted.deinit(alloc);
    for (group.entry_actions.items) |action| switch (action) {
        .override => |override| {
            try painted.appendSlice(alloc, override.bytes);
            try painted.append(alloc, '\n');
        },
        else => {},
    };
    return visibleLinesForTest(alloc, painted.items, 120);
}

/// The first line of `text`, after its leading newlines.
fn firstLineForTest(text: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, text, "\n");
    return if (std.mem.findScalar(u8, trimmed, '\n')) |at| trimmed[0..at] else trimmed;
}

/// The visible text of `bytes` as the terminal paints it, one line per row,
/// without colors. The caller owns the result.
fn visibleLinesForTest(alloc: std.mem.Allocator, bytes: []const u8, cols: u16) ![]u8 {
    var grid = try paintExpandedRowsForTest(alloc, bytes, cols);
    defer grid.deinit();
    const rows: u16 = @intCast(std.mem.countScalar(u8, bytes, '\n') + 1);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(alloc);
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        row_text.clearRetainingCapacity();
        try grid.rowTextTrimmed(row, &row_text);
        if (row > 0) try out.append(alloc, '\n');
        try out.appendSlice(alloc, row_text.items);
    }
    return out.toOwnedSlice(alloc);
}

fn withoutSpacesForTest(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (text) |byte| {
        if (byte != ' ') try out.append(alloc, byte);
    }
    return out.toOwnedSlice(alloc);
}

fn lastContentCellForTest(grid: *const vt_emulator.Grid, row: u16) vt_emulator.Cell {
    var col = grid.cols;
    while (col > 1) : (col -= 1) {
        const cell = grid.cellAt(row, col).?;
        if (cell.width > 0 and cell.codepoint != ' ') return cell;
    }
    return grid.cellAt(row, 1).?;
}

fn checkPresentationGroupingAllocationFailures(alloc: std.mem.Allocator) !void {
    var entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Running second", .class = .tool_status } },
        .{ .assistant_turn = .{ .id = 3, .segments = .{} } },
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Running first", .class = .tool_status } },
    };
    try entries[1].assistant_turn.segments.text.appendSlice(alloc, "provider bridge");
    defer entries[1].assistant_turn.segments.deinit(alloc);
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("run_command"),
            .activity_kind = .command,
            .lifecycle_id = .{ .turn_id = 7, .call_id = @constCast("first") },
            .presentation_group_id = .{ .turn_id = 7, .anchor_step_id = 11 },
        },
        .{
            .entry_id = 2,
            .tool_name = @constCast("run_command"),
            .activity_kind = .command,
            .lifecycle_id = .{ .turn_id = 7, .call_id = @constCast("second") },
            .presentation_group_id = .{ .turn_id = 7, .anchor_step_id = 11 },
        },
    };

    var projection = build(alloc, &entries, &details, 120) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer projection.deinit(alloc);
    try std.testing.expectEqualStrings(
        "● Running commands\n" ++
            "├ Running \x1b[38;5;252mfirst\x1b[39m\n" ++
            "└ Running \x1b[38;5;252msecond\x1b[39m",
        projection.entry_actions.items[0].override.bytes,
    );
}

fn storyCommandDetail(
    entry_id: u32,
    arguments_json: []const u8,
    exit_code: i64,
    result: ?[]const u8,
) ToolDetailRecord {
    return .{
        .entry_id = entry_id,
        .tool_name = @constCast("shell"),
        .activity_kind = .command,
        .arguments_json = @constCast(arguments_json),
        .result = if (result) |text| @constCast(text) else null,
        .outcome = .completed,
        .command_process_presentation = .{ .exit_code = exit_code },
    };
}

fn storySearchDetail(entry_id: u32, tool_name: []const u8, kind: types.ToolActivityKind, arguments_json: []const u8) ToolDetailRecord {
    return .{
        .entry_id = entry_id,
        .tool_name = @constCast(tool_name),
        .activity_kind = kind,
        .arguments_json = @constCast(arguments_json),
        .outcome = .completed,
    };
}

fn storyReadDetailForTest(entry_id: u32, comptime path: []const u8) ToolDetailRecord {
    return .{
        .entry_id = entry_id,
        .tool_name = @constCast("read_file"),
        .activity_kind = .read,
        .arguments_json = @constCast("{\"path\":\"" ++ path ++ "\"}"),
        .outcome = .completed,
    };
}

/// Reads a fuzz input one choice at a time; past its end every byte is 0.
const StoryFuzzBytes = struct {
    bytes: []const u8,
    index: usize = 0,

    fn byte(self: *StoryFuzzBytes) u8 {
        if (self.index >= self.bytes.len) return 0;
        defer self.index += 1;
        return self.bytes[self.index];
    }

    fn chunk(self: *StoryFuzzBytes, max: usize) []const u8 {
        const wanted = self.byte() % (max + 1);
        const len = @min(wanted, self.bytes.len -| self.index);
        defer self.index += len;
        return self.bytes[self.index..][0..len];
    }

    /// Any i64, from the next eight bytes, so the ends of the range come up.
    fn int(self: *StoryFuzzBytes) i64 {
        var bits: u64 = 0;
        for (0..8) |_| bits = (bits << 8) | self.byte();
        return @bitCast(bits);
    }
};

/// Builds one compact group and its turn summary from fuzz bytes: core status
/// lines from a fixed set, with model arguments and command output taken from
/// the input, and checks that every line fits the width and carries no
/// control byte but a style's escape.
fn checkStoryRows(input: []const u8) !void {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fuzz: StoryFuzzBytes = .{ .bytes = input };

    const statuses = [_][]const u8{
        "● Ran sh test.sh\n",
        "● Exited 1 sh test.sh\n",
        "● Read desktop/src/main.ts\n",
        "● Edited main.zig +2 / -1\n",
        "● Failed main.zig: old_string not found\n",
        "● sent to reviewer · review\n",
        "▪ Cancelled sleep 30 · What can spark do differently?",
        "⊘ Denied by auto agent rm -rf build\n",
        "● Searched createWindow(\n",
    };
    const Tool = struct { name: []const u8, kind: types.ToolActivityKind, key: []const u8 };
    const tools = [_]Tool{
        .{ .name = "shell", .kind = .command, .key = "command" },
        .{ .name = "read_file", .kind = .read, .key = "path" },
        .{ .name = "grep_files", .kind = .read, .key = "pattern" },
        .{ .name = "glob_files", .kind = .list, .key = "pattern" },
        .{ .name = "edit_file", .kind = .edit, .key = "path" },
        .{ .name = "write_file", .kind = .write, .key = "path" },
        .{ .name = "subagent", .kind = .subagent, .key = "agent" },
        .{ .name = "web_search", .kind = .read, .key = "query" },
    };
    const outcomes = [_]?types.ToolOutcomeKind{ null, .completed, .failed, .denied, .cancelled, .deferred };

    const max_calls = 12;
    var entries: [max_calls + 1]TranscriptEntry = undefined;
    var details: [max_calls]ToolDetailRecord = undefined;
    const count = 1 + fuzz.byte() % max_calls;
    for (0..count) |index| {
        const entry_id: u32 = @intCast(index + 1);
        const tool = tools[fuzz.byte() % tools.len];
        entries[index] = .{ .raw_bytes = .{
            .id = entry_id,
            .bytes = statuses[fuzz.byte() % statuses.len],
            .class = .tool_status,
        } };
        const arguments_json: ?[]u8 = switch (fuzz.byte() % 5) {
            0 => null,
            4 => blk: {
                // A read of a fuzzed path at fuzzed lines, any whole numbers
                // the model could send.
                var out: std.Io.Writer.Allocating = .init(arena);
                try out.writer.writeAll("{\"path\":");
                const path = try arena.print("/w/{s}", .{fuzz.chunk(24)});
                std.json.Stringify.value(path, .{}, &out.writer) catch try out.writer.writeAll("\"\"");
                try out.writer.print(",\"start_line\":{d},\"line_count\":{d}}}", .{ fuzz.int(), fuzz.int() });
                break :blk out.written();
            },
            1 => try arena.dupe(u8, fuzz.chunk(64)),
            2 => blk: {
                var out: std.Io.Writer.Allocating = .init(arena);
                try out.writer.print("{{\"action\":\"run\",\"{s}\":", .{tool.key});
                std.json.Stringify.value(fuzz.chunk(48), .{}, &out.writer) catch try out.writer.writeAll("\"\"");
                try out.writer.writeByte('}');
                break :blk out.written();
            },
            else => try arena.dupe(u8, "{}"),
        };
        const result = fuzz.chunk(160);
        details[index] = .{
            .entry_id = entry_id,
            .tool_name = @constCast(tool.name),
            .activity_kind = tool.kind,
            .arguments_json = arguments_json,
            .result = if (result.len == 0) null else try arena.dupe(u8, result),
            .outcome = outcomes[fuzz.byte() % outcomes.len],
            .command_process_presentation = switch (fuzz.byte() % 5) {
                0 => null,
                1 => .{ .exit_code = 0 },
                2 => .{ .exit_code = fuzz.byte() },
                3 => .timed_out,
                else => .{ .signal = 9 },
            },
        };
    }
    entries[count] = .{ .raw_bytes = .{ .id = @intCast(count + 1), .bytes = "  2s (↑1 ↓2)", .class = .turn_summary } };
    const cols: u16 = 1 + @as(u16, fuzz.byte()) % 160;

    // Some shell calls get a recorded command, which the row can show in
    // short form. Inputs that end before here keep every row as it was.
    const pieces = [_][]const u8{
        "cd desktop",    "&&",            "git status",     "--short",    "|",        "head -5",
        "'quoted && x'", "npm run build", ";",              "FOO=1",      "sudo",     "<<EOF",
        "EOF",           "\n",            "2>&1",           "timeout 30", "./run.sh", "echo done",
        "gh issue list", "-R",            "NZ-Linix/spark", "\"",         "\\",       "git -C x fetch",
    };
    for (0..count) |index| {
        if (details[index].activity_kind != .command or fuzz.byte() % 2 != 1) continue;
        var raw: std.Io.Writer.Allocating = .init(arena);
        const piece_count = 1 + fuzz.byte() % 12;
        for (0..piece_count) |piece| {
            if (piece > 0) try raw.writer.writeByte(' ');
            if (fuzz.byte() % 4 == 0) try raw.writer.writeAll(fuzz.chunk(12)) else try raw.writer.writeAll(pieces[fuzz.byte() % pieces.len]);
        }
        const display = try arena.print("{f}", .{text_utils.terminalSafe(raw.written())});
        details[index].command_display = display;
        entries[index] = .{ .raw_bytes = .{
            .id = @intCast(index + 1),
            .bytes = try arena.print("● Ran {s}\n", .{display}),
            .class = .tool_status,
        } };
    }

    var projection = try build(alloc, entries[0 .. count + 1], details[0..count], cols);
    defer projection.deinit(alloc);
    for (projection.entry_actions.items) |action| {
        if (action != .override) continue;
        var lines = std.mem.splitScalar(u8, action.override.bytes, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
            // Apart from the styles and file links spark writes, every byte is
            // terminal-safe.
            var plain: std.Io.Writer.Allocating = .init(arena);
            var index: usize = 0;
            var link_open = false;
            while (index < line.len) {
                if (skipSgrSequence(line, &index)) continue;
                switch (skipFileLink(line, &index)) {
                    .none => {},
                    // Links never nest, and each one closes on its line.
                    .open => {
                        try std.testing.expect(!link_open);
                        link_open = true;
                        continue;
                    },
                    .close => {
                        link_open = false;
                        continue;
                    },
                }
                try plain.writer.writeByte(line[index]);
                index += 1;
            }
            try std.testing.expect(!link_open);
            try std.testing.expect(text_utils.isTerminalSafe(plain.written()));
        }
    }
}

/// Skips a file link sequence spark writes, and says which it was: its close,
/// or an open whose URL holds only percent-encoded path bytes.
fn skipFileLink(text: []const u8, index: *usize) enum { none, open, close } {
    const rest = text[index.*..];
    if (std.mem.startsWith(u8, rest, link_close)) {
        index.* += link_close.len;
        return .close;
    }
    const open = "\x1b]8;;file://";
    if (!std.mem.startsWith(u8, rest, open)) return .none;
    const end = std.mem.find(u8, rest, "\x1b\\") orelse return .none;
    for (rest[open.len..end]) |byte| {
        const url_byte = std.ascii.isAlphanumeric(byte) or byte == '/' or byte == '-' or byte == '.' or byte == '_' or byte == '~' or byte == '%';
        if (!url_byte) return .none;
    }
    index.* += end + 2;
    return .open;
}

fn fuzzStoryRows(_: void, smith: *std.testing.Smith) !void {
    var buffer: [2048]u8 = undefined;
    const len = smith.slice(&buffer);
    try checkStoryRows(buffer[0..len]);
}
