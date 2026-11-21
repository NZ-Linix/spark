const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const file_picker_path = @import("file_picker_path.zig");
const file_completion_state = @import("file_completion_state.zig");
const editor_state = @import("editor_state.zig");
const fuzzy_match = @import("../shared/fuzzy_match.zig");

const Allocator = std.mem.Allocator;

pub const ModelPickerStage = enum {
    model,
    effort,
    fast,
};

pub const InlinePickerKind = enum {
    slash,
    model,
    file,
    skill,
};

const InlinePickerSuppression = union(enum) {
    dismissed_until_trigger_change: InlinePickerKind,
    history_slash_recall_until_edit,

    fn kind(self: InlinePickerSuppression) InlinePickerKind {
        return switch (self) {
            .dismissed_until_trigger_change => |suppressed_kind| suppressed_kind,
            .history_slash_recall_until_edit => .slash,
        };
    }
};

pub const model_picker_speed_options = [_][]const u8{ "normal", "fast", "ultrafast" };

/// The composer text that opens the effort column for the current model.
pub const effort_prefix = "/effort ";

/// The command a model picker query belongs to. `/effort ` opens the effort
/// column of `/model` on its own, for the current model.
pub const ModelPickerCommand = enum { model, effort };

pub const ModelPickerQuery = struct {
    stage: ModelPickerStage,
    query: []const u8,
    token_start: usize,
    command: ModelPickerCommand = .model,
};

pub const FilePickerQuery = file_picker_path.Query;

pub const InlineSkillQuery = struct {
    /// Bytes between `$` and the cursor, without the leading `$`.
    query: []const u8,
    /// Byte offset of the `$` in the composer text.
    dollar_offset: usize,
    /// Byte offset where `query` begins.
    token_start: usize,
};

pub const InlineSlashQuery = struct {
    /// Slash command prefix through the cursor, including the leading `/`.
    prefix: []const u8,
};

/// Paces the frame for a keystroke that started a folder listing. Most folders
/// list well within one event-loop tick, so that frame waits for the rows and
/// the keystroke paints together with them instead of over an empty
/// "indexing files..." list. Times are monotonic milliseconds. Modeled in
/// `tests/tla/indexer/ListingWait.tla`.
const FileListingWait = struct {
    const hold_ms: i64 = 8;

    started_ms: ?i64 = null,
    // The previous listing outlasted the wait, so the next keystroke paints at
    // once instead of paying the wait again on a slow folder.
    last_outlasted_hold: bool = false,

    /// Returns true while the next frame should wait for an in-flight listing.
    /// Keystrokes during one listing share its wait.
    pub fn hold(self: *FileListingWait, listing_in_flight: bool, now_ms: i64) bool {
        if (!listing_in_flight) {
            if (self.started_ms) |started| self.last_outlasted_hold = !withinHold(started, now_ms);
            self.started_ms = null;
            return false;
        }
        if (self.started_ms == null) self.started_ms = now_ms;
        return self.active(now_ms);
    }

    pub fn active(self: FileListingWait, now_ms: i64) bool {
        return !self.last_outlasted_hold and self.measuring(now_ms);
    }

    /// True during the first tick of every listing, waited for or not, so a
    /// listing that finishes in time is seen at once and waiting turns back on.
    pub fn measuring(self: FileListingWait, now_ms: i64) bool {
        const started = self.started_ms orelse return false;
        return withinHold(started, now_ms);
    }

    fn withinHold(started_ms: i64, now_ms: i64) bool {
        // A clock that steps backwards ends the wait instead of extending it.
        return now_ms >= started_ms and now_ms - started_ms < hold_ms;
    }
};

/// Owns layout-independent composer picker state. Call `deinit` with the
/// allocator used by `beginModelPickerFlow`.
pub const State = struct {
    slash_completion_index: usize = 0,
    slash_completion_window_start: usize = 0,
    inline_picker_suppression: ?InlinePickerSuppression = null,
    model_completion_index: usize = 0,
    model_completion_window_start: usize = 0,
    model_completion_anchor_current: bool = false,
    model_picker_stage: ModelPickerStage = .model,
    model_picker_pending_model: std.ArrayList(u8) = .empty,
    model_picker_effort_index: usize = 0,
    model_picker_effort_window_start: usize = 0,
    model_picker_fast_index: usize = 0,
    model_picker_fast_window_start: usize = 0,
    file_completion: file_completion_state.State = .{},
    // The ordinal is meaningful only within file_completion's presented rows.
    file_completion_index: usize = 0,
    file_completion_window_start: usize = 0,
    file_picker_episode_seen: bool = false,
    file_listing_wait: FileListingWait = .{},

    pub fn initInto(self: *State) void {
        const state_info = @typeInfo(State).@"struct";
        inline for (state_info.field_names, state_info.field_types, state_info.field_attrs) |field_name, field_type, field_attrs| {
            if (comptime std.mem.eql(u8, field_name, "file_completion")) continue;
            @field(self.*, field_name) = field_attrs.defaultValue(field_type).?;
        }
        self.file_completion.initInto();
    }

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.file_completion.deinit(alloc);
        self.model_picker_pending_model.deinit(alloc);
        const state_info = @typeInfo(State).@"struct";
        inline for (state_info.field_names, state_info.field_types, state_info.field_attrs) |field_name, field_type, field_attrs| {
            // The child's owner already restored its defaults.
            if (comptime std.mem.eql(u8, field_name, "file_completion")) continue;
            @field(self.*, field_name) = field_attrs.defaultValue(field_type).?;
        }
    }

    pub fn resetInlinePickerEpisode(self: *State) void {
        self.file_completion.invalidate();
        self.slash_completion_index = 0;
        self.slash_completion_window_start = 0;
        self.inline_picker_suppression = null;
    }

    pub fn resetInlinePickerForHistoryRecall(self: *State, editor: *const editor_state.State) void {
        self.resetInlinePickerEpisode();
        self.inline_picker_suppression = suppressionForHistoryRecall(
            self.inlinePickerTriggerKind(editor),
        );
    }

    pub fn dismissInlinePicker(self: *State, kind: InlinePickerKind) void {
        if (kind == .file) self.file_completion.invalidate();
        self.inline_picker_suppression = .{ .dismissed_until_trigger_change = kind };
    }

    pub fn isInlinePickerDismissed(self: *const State, kind: InlinePickerKind) bool {
        const suppression = self.inline_picker_suppression orelse return false;
        return switch (suppression) {
            .dismissed_until_trigger_change => |dismissed| dismissed == kind,
            .history_slash_recall_until_edit => false,
        };
    }

    pub fn isInlinePickerSuppressed(self: *const State, kind: InlinePickerKind) bool {
        const suppression = self.inline_picker_suppression orelse return false;
        return suppression.kind() == kind;
    }

    pub fn reconcileInlinePickerAfterEdit(self: *State, editor: *const editor_state.State) void {
        self.slash_completion_index = 0;
        self.slash_completion_window_start = 0;
        self.inline_picker_suppression = suppressionAfterEdit(
            self.inline_picker_suppression,
            self.inlinePickerTriggerKind(editor),
        );
    }

    pub fn resetFilePickerIndex(self: *State) void {
        self.file_completion_index = 0;
        self.file_completion_window_start = 0;
    }

    pub fn activeFilePickerQuery(self: *const State, editor: *const editor_state.State) ?FilePickerQuery {
        if (self.isInlinePickerSuppressed(.file)) return null;
        return self.rawFilePickerQuery(editor);
    }

    pub fn activeModelPickerQuery(self: *const State, editor: *const editor_state.State) ?ModelPickerQuery {
        if (self.isInlinePickerSuppressed(.model)) return null;
        return self.rawModelPickerQuery(editor);
    }

    pub fn activeInlineSkillQuery(self: *const State, editor: *const editor_state.State) ?InlineSkillQuery {
        if (self.isInlinePickerSuppressed(.skill)) return null;
        return findInlineSkillQuery(editor.input.items, editor.cursor);
    }

    pub fn activeInlineSlashQuery(self: *const State, editor: *const editor_state.State) ?InlineSlashQuery {
        if (self.isInlinePickerSuppressed(.slash)) return null;
        return findInlineSlashQuery(editor.input.items, editor.cursor);
    }

    fn rawFilePickerQuery(self: *const State, editor: *const editor_state.State) ?FilePickerQuery {
        if (self.rawModelPickerQuery(editor) != null) return null;
        const command_text = std.mem.trimStart(u8, editor.input.items, " \t\r\n");
        if (tokenMatchesAt(command_text, 0, "/mcp")) return null;
        return findFilePickerQuery(editor.input.items, editor.cursor);
    }

    pub fn inlinePickerTriggerKind(self: *const State, editor: *const editor_state.State) ?InlinePickerKind {
        if (self.rawModelPickerQuery(editor) != null) return .model;
        if (self.rawFilePickerQuery(editor) != null) return .file;
        if (findInlineSkillQuery(editor.input.items, editor.cursor) != null) return .skill;
        if (findInlineSlashQuery(editor.input.items, editor.cursor) != null) return .slash;
        const trimmed = std.mem.trimStart(u8, editor.input.items, " \t\r\n");
        if (trimmed.len > 0 and trimmed[0] == '/') return .slash;
        return null;
    }

    fn rawModelPickerQuery(self: *const State, editor: *const editor_state.State) ?ModelPickerQuery {
        const items = editor.input.items;
        const trim_start = leadingWhitespaceLen(items);
        const trimmed = items[trim_start..];
        if (trimmed.len >= effort_prefix.len and std.ascii.eqlIgnoreCase(trimmed[0..effort_prefix.len], effort_prefix)) return .{
            .stage = .effort,
            .command = .effort,
            .query = trimmed[effort_prefix.len..],
            .token_start = trim_start + effort_prefix.len,
        };
        const prefix = "/model ";
        if (trimmed.len < prefix.len or !std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) return null;

        switch (self.model_picker_stage) {
            .model => return .{
                .stage = .model,
                .query = trimmed[prefix.len..],
                .token_start = trim_start + prefix.len,
            },
            .effort => {
                const token_start = modelPickerTokenStart(trimmed, self.model_picker_pending_model.items, .effort) orelse return null;
                return .{
                    .stage = .effort,
                    .query = trimmed[token_start..],
                    .token_start = trim_start + token_start,
                };
            },
            .fast => {
                const token_start = modelPickerTokenStart(trimmed, self.model_picker_pending_model.items, .fast) orelse return null;
                return .{
                    .stage = .fast,
                    .query = trimmed[token_start..],
                    .token_start = trim_start + token_start,
                };
            },
        }
    }

    /// The composer text changed, so whichever column is open no longer has a
    /// trustworthy highlighted row.
    pub fn resetActiveCompletionIndex(self: *State) void {
        self.resetActiveModelPickerIndex();
    }

    pub fn isModelShapedInput(self: *const State, editor: *const editor_state.State) bool {
        return isBareModelCommandAtCursor(editor) or self.rawModelPickerQuery(editor) != null;
    }

    fn resetActiveModelPickerIndex(self: *State) void {
        switch (self.model_picker_stage) {
            .model => {
                self.model_completion_index = 0;
                self.model_completion_window_start = 0;
                self.model_completion_anchor_current = false;
                // The `/effort ` column reads the effort highlight with no
                // `/model` flow open; `/model` sets it again on its effort stage.
                self.model_picker_effort_index = 0;
                self.model_picker_effort_window_start = 0;
            },
            .effort => {
                self.model_picker_effort_index = 0;
                self.model_picker_effort_window_start = 0;
            },
            .fast => {
                self.model_picker_fast_index = 0;
                self.model_picker_fast_window_start = 0;
            },
        }
    }

    pub fn beginModelPickerFlow(
        self: *State,
        alloc: Allocator,
        model: []const u8,
        effort_index: usize,
        fast_mode: bool,
        ultrafast_mode: bool,
        stage: ModelPickerStage,
    ) Allocator.Error!void {
        const stable_model = try alloc.dupe(u8, model);
        defer alloc.free(stable_model);

        try self.model_picker_pending_model.ensureTotalCapacity(alloc, stable_model.len);
        self.model_picker_pending_model.clearRetainingCapacity();
        self.model_picker_pending_model.appendSliceAssumeCapacity(stable_model);
        self.model_picker_stage = stage;
        self.model_picker_effort_index = effort_index;
        self.model_picker_effort_window_start = 0;
        self.model_picker_fast_index = if (ultrafast_mode) 2 else if (fast_mode) 1 else 0;
        self.model_picker_fast_window_start = 0;
    }

    pub fn clearModelPickerFlow(self: *State) void {
        self.model_picker_stage = .model;
        self.model_picker_pending_model.clearRetainingCapacity();
        self.model_picker_effort_index = 0;
        self.model_picker_effort_window_start = 0;
        self.model_picker_fast_index = 0;
        self.model_picker_fast_window_start = 0;
        self.model_completion_index = 0;
        self.model_completion_window_start = 0;
        self.model_completion_anchor_current = false;
    }

    pub fn hasPendingModelPickerSelection(self: *const State) bool {
        return self.model_picker_pending_model.items.len > 0;
    }

    pub fn selectedModelPickerEffortIndex(self: *const State) usize {
        return self.model_picker_effort_index;
    }

    pub fn selectedModelPickerSpeed(self: *const State) []const u8 {
        return model_picker_speed_options[self.model_picker_fast_index % model_picker_speed_options.len];
    }

    pub fn selectedModelPickerFast(self: *const State) bool {
        return std.mem.eql(u8, self.selectedModelPickerSpeed(), "fast");
    }
};

fn suppressionForHistoryRecall(trigger: ?InlinePickerKind) ?InlinePickerSuppression {
    if (trigger != .slash) return null;
    return .history_slash_recall_until_edit;
}

fn suppressionAfterEdit(
    current: ?InlinePickerSuppression,
    trigger: ?InlinePickerKind,
) ?InlinePickerSuppression {
    const suppression = current orelse return null;
    return switch (suppression) {
        .dismissed_until_trigger_change => |dismissed| if (trigger == dismissed)
            suppression
        else
            null,
        .history_slash_recall_until_edit => null,
    };
}

pub fn isBareModelCommandAtCursor(editor: *const editor_state.State) bool {
    if (editor.cursor != editor.input.items.len) return false;
    const trimmed = std.mem.trimStart(u8, editor.input.items, " \t");
    return std.ascii.eqlIgnoreCase(trimmed, "/model");
}

pub fn isBareEffortCommandAtCursor(editor: *const editor_state.State) bool {
    if (editor.cursor != editor.input.items.len) return false;
    const trimmed = std.mem.trimStart(u8, editor.input.items, " \t");
    return std.ascii.eqlIgnoreCase(trimmed, effort_prefix[0 .. effort_prefix.len - 1]);
}

/// Copies the options `query` keeps into `out`, in order, as every spark menu
/// filters (`fuzzy_match.Filter`).
pub fn filterCompletionLabels(query: []const u8, options: []const []const u8, out: [][]const u8) usize {
    const kept: fuzzy_match.Filter(fuzzy_match.LabelMatches) = .init(.{ .labels = options, .query = query }, options.len);
    var count: usize = 0;
    for (options, 0..) |option, position| {
        if (count >= out.len) break;
        if (kept.keeps(position)) {
            out[count] = option;
            count += 1;
        }
    }
    return count;
}

/// Compacts `labels` and its parallel `annotations` in place to the entries
/// matching `query`, keeping the two arrays aligned.
pub fn filterAnnotatedLabels(
    query: []const u8,
    labels: [][]const u8,
    annotations: [][]const u8,
    count: usize,
) usize {
    // `init` reads every label before any moves, and the loop only writes
    // at or below the label it reads next.
    const keep: fuzzy_match.Filter(fuzzy_match.LabelMatches) = .init(.{ .labels = labels[0..count], .query = query }, count);
    var kept: usize = 0;
    for (0..count) |i| {
        if (!keep.keeps(i)) continue;
        labels[kept] = labels[i];
        annotations[kept] = annotations[i];
        kept += 1;
    }
    return kept;
}

pub fn isFilePickerTerminator(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn leadingWhitespaceLen(bytes: []const u8) usize {
    var index: usize = 0;
    while (index < bytes.len and (bytes[index] == ' ' or bytes[index] == '\t')) : (index += 1) {}
    return index;
}

fn findFilePickerQuery(items: []const u8, cursor: usize) ?FilePickerQuery {
    return file_picker_path.query_at(items, cursor);
}

fn findInlineSkillQuery(items: []const u8, cursor: usize) ?InlineSkillQuery {
    if (cursor != items.len) return null;

    var index = cursor;
    while (index > 0) {
        const byte = items[index - 1];
        if (isFilePickerTerminator(byte)) return null;
        index -= 1;
        if (byte != '$') continue;
        if (file_picker_path.contains_position(items, index)) return null;
        return .{
            .query = items[index + 1 .. cursor],
            .dollar_offset = index,
            .token_start = index + 1,
        };
    }
    return null;
}

fn findInlineSlashQuery(items: []const u8, cursor: usize) ?InlineSlashQuery {
    if (cursor != items.len) return null;

    var token_start = cursor;
    while (token_start > 0 and !isFilePickerTerminator(items[token_start - 1])) {
        token_start -= 1;
    }
    if (token_start == 0 or token_start + 1 >= cursor or items[token_start] != '/') return null;
    if (std.mem.trim(u8, items[0..token_start], " \t\r\n").len == 0) return null;

    return .{ .prefix = items[token_start..cursor] };
}

fn modelPickerTokenStart(trimmed: []const u8, model: []const u8, stage: ModelPickerStage) ?usize {
    const prefix = "/model ";
    if (trimmed.len < prefix.len or !std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) return null;
    if (model.len == 0) return null;

    const after_prefix = trimmed[prefix.len..];
    if (after_prefix.len < model.len or !std.mem.eql(u8, after_prefix[0..model.len], model)) return null;

    const after_model = prefix.len + model.len;
    if (stage == .effort) return skipPickerSpaces(trimmed, after_model);

    const effort_start = skipPickerSpaces(trimmed, after_model);
    if (effort_start >= trimmed.len) return null;

    var effort_end = effort_start;
    while (effort_end < trimmed.len and trimmed[effort_end] != ' ' and trimmed[effort_end] != '\t') : (effort_end += 1) {}
    return skipPickerSpaces(trimmed, effort_end);
}

/// True when `token` sits at `start` as a whole word.
fn tokenMatchesAt(bytes: []const u8, start: usize, token: []const u8) bool {
    if (bytes.len - start < token.len) return false;
    if (!std.mem.eql(u8, bytes[start..][0..token.len], token)) return false;
    const end = start + token.len;
    return end == bytes.len or bytes[end] == ' ' or bytes[end] == '\t';
}

fn skipPickerSpaces(bytes: []const u8, start: usize) usize {
    var index = start;
    while (index < bytes.len and (bytes[index] == ' ' or bytes[index] == '\t')) : (index += 1) {}
    return index;
}

test "picker deinit releases owned text and restores declared defaults" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.model_picker_pending_model.appendSlice(alloc, "model");
    state.model_picker_stage = .fast;
    state.slash_completion_index = 7;
    state.inline_picker_suppression = .history_slash_recall_until_edit;
    state.file_completion.active = true;
    state.file_completion.episode = 51;
    state.deinit(alloc);
    const state_info = @typeInfo(State).@"struct";
    inline for (state_info.field_names, state_info.field_types, state_info.field_attrs) |field_name, field_type, field_attrs| {
        if (comptime std.mem.eql(u8, field_name, "file_completion")) {
            const child_info = @typeInfo(file_completion_state.State).@"struct";
            inline for (child_info.field_names, child_info.field_types, child_info.field_attrs) |child_name, child_type, child_attrs| {
                if (comptime std.mem.eql(u8, child_name, "raw_query") or std.mem.eql(u8, child_name, "lookup_query")) continue;
                try std.testing.expectEqualDeep(child_attrs.defaultValue(child_type).?, @field(state.file_completion, child_name));
            }
        } else {
            try std.testing.expectEqualDeep(field_attrs.defaultValue(field_type).?, @field(state, field_name));
        }
    }
    state.deinit(alloc);
}
