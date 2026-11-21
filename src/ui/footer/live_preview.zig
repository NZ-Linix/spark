//! The live preview: the model's reasoning, or the paragraph of its reply
//! still being written, revealed a few words at a time where the transcript
//! will put it. It wraps the way the transcript does, so when the transcript
//! takes the text, as the thinking block or the finished paragraph, nothing
//! moves.

const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const Row = std.ArrayList(u8);

const fade_ms = 90;
const partial_word_ms = 40;
const fresh_style = "\x1b[0;2m";
/// A sanity bound only: the footer clamps the preview to the rows the
/// terminal has, so the preview grows like the block the transcript will
/// write and scrolls only once it is taller than the screen.
const max_rows: u16 = 1000;

const reset = "\x1b[0m";

pub const Kind = enum { reasoning, reply };

pub const Source = struct {
    text: []const u8,
    kind: Kind,
    generation: u32,
};

/// What the footer draws: the revealed text and the rows it needs,
/// including the gap row under the text.
pub const Preview = struct {
    text: []const u8,
    kind: Kind,
    rows: u16,
    /// Blank rows above the text, matching the gap the transcript leaves
    /// above the block when it writes it. Counted in `rows`.
    gap_above: u16 = 0,
    /// The newest words, drawn faint until they settle.
    fresh_words: u16 = 0,

    pub fn withGapAbove(self: Preview, gap: u16) Preview {
        var out = self;
        out.rows = self.rows - self.gap_above + gap;
        out.gap_above = gap;
        return out;
    }
};

/// Reveals a source as fast as it arrives. Each new piece shows faint for
/// a moment, then settles, so text flows in rather than popping.
pub const Pacer = struct {
    shown: usize = 0,
    kind: Kind = .reply,
    generation: u32 = 0,
    /// Where the newest piece starts, and when it appeared.
    fresh_from: usize = 0,
    fresh_ms: i64 = 0,
    fading: bool = false,
    /// The source's length when it last grew, and when.
    seen_len: usize = 0,
    seen_ms: i64 = 0,
    /// When text was last revealed. Between two pieces of a reply the
    /// footer keeps the activity row hidden for a moment.
    last_text_ms: i64 = 0,

    pub fn recentlyShown(self: *const Pacer, now_ms: i64) bool {
        return now_ms - self.last_text_ms < 600;
    }

    /// Reveals what arrived. Returns true when the preview changed, so the
    /// footer needs a redraw.
    pub fn tick(self: *Pacer, source: ?Source, now_ms: i64) bool {
        const src = source orelse {
            const had = self.shown > 0;
            self.shown = 0;
            return had;
        };
        if (src.kind != self.kind or src.generation != self.generation or self.shown > src.text.len) {
            self.kind = src.kind;
            self.generation = src.generation;
            self.shown = 0;
            self.seen_len = 0;
        }
        if (src.text.len != self.seen_len) {
            self.seen_len = src.text.len;
            self.seen_ms = now_ms;
        }
        // Whole words at once; a word still being written shows once the
        // stream pauses on it.
        const target = if (now_ms - self.seen_ms >= partial_word_ms) src.text.len else revealLimit(src.text);
        var changed = false;
        if (self.fading and now_ms - self.fresh_ms >= fade_ms) {
            self.fading = false;
            changed = true;
        }
        if (target > self.shown) {
            self.fresh_from = if (self.fading) self.fresh_from else self.shown;
            self.fresh_ms = now_ms;
            self.fading = true;
            self.shown = target;
            self.last_text_ms = now_ms;
            changed = true;
        }
        return changed;
    }

    pub fn preview(self: *const Pacer, source: ?Source, width: u16) ?Preview {
        const src = source orelse return null;
        if (src.kind != self.kind or src.generation != self.generation) return null;
        const end = @min(self.shown, src.text.len);
        const text = std.mem.trim(u8, src.text[0..end], " \t\r\n");
        if (text.len == 0) return null;
        const rows = @min(rowCount(text, src.kind, width), max_rows) + 1;
        const fresh: u16 = if (self.fading and self.fresh_from < end)
            @intCast(@min(countWords(src.text[self.fresh_from..end]), 64))
        else
            0;
        return .{ .text = text, .kind = src.kind, .rows = rows, .fresh_words = fresh };
    }
};

/// Picks what to preview: reasoning first, while it is being written.
pub fn pickSource(reasoning: []const u8, reasoning_visible: bool, reply_line: []const u8, generation: u32) ?Source {
    if (reasoning_visible and std.mem.trim(u8, reasoning, " \t\r\n").len > 0)
        return .{ .text = reasoning, .kind = .reasoning, .generation = generation };
    if (std.mem.trim(u8, reply_line, " \t").len > 0) return .{ .text = reply_line, .kind = .reply, .generation = generation };
    return null;
}

/// Only whole words are revealed: text up to the last whitespace.
fn revealLimit(text: []const u8) usize {
    var i = text.len;
    while (i > 0) : (i -= 1) {
        if (std.ascii.isWhitespace(text[i - 1])) return i;
    }
    return 0;
}

fn nextWordEnd(text: []const u8, from: usize, limit: usize) usize {
    var i = from;
    while (i < limit and std.ascii.isWhitespace(text[i])) i += 1;
    while (i < limit and !std.ascii.isWhitespace(text[i])) i += 1;
    return i;
}

fn countWords(text: []const u8) usize {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var n: usize = 0;
    while (it.next() != null) n += 1;
    return n;
}

/// The reply's raw markdown with the inline markers the transcript hides
/// removed, so words keep their final widths.
fn cleanReply(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = text;
    // A heading's hashes.
    const trimmed = std.mem.trimStart(u8, rest, " ");
    if (trimmed.len > 0 and trimmed[0] == '#') {
        rest = std.mem.trimStart(u8, std.mem.trimStart(u8, trimmed, "#"), " ");
    }
    var i: usize = 0;
    while (i < rest.len) {
        if (std.mem.startsWith(u8, rest[i..], "**") or std.mem.startsWith(u8, rest[i..], "__")) {
            i += 2;
            continue;
        }
        if (rest[i] == '`') {
            i += 1;
            continue;
        }
        try out.append(arena, rest[i]);
        i += 1;
    }
    return out.items;
}

/// Lays text out like the transcript: reasoning as a notice (`* ` then
/// rows indented by two), a reply indented by two. Each source line starts
/// a row. Returns the rows' text, without the indent.
fn layout(arena: Allocator, text: []const u8, kind: Kind, width: u16) ![]const []const u8 {
    const body = if (kind == .reply) try cleanReply(arena, text) else text;
    const avail: usize = @max(@as(usize, width) -| 2, 8);
    var rows: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) {
            try rows.append(arena, "");
            continue;
        }
        var current: std.ArrayList(u8) = .empty;
        var used: usize = 0;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        while (words.next()) |word| {
            const w = display_width.visibleWidth(word);
            if (current.items.len > 0 and used + 1 + w > avail) {
                try rows.append(arena, current.items);
                current = .empty;
                used = 0;
            }
            if (current.items.len > 0) {
                try current.append(arena, ' ');
                used += 1;
            }
            try current.appendSlice(arena, word);
            used += w;
        }
        try rows.append(arena, current.items);
    }
    return rows.items;
}

fn rowCount(text: []const u8, kind: Kind, width: u16) u16 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const rows = layout(arena_state.allocator(), text, kind, width) catch return 1;
    return @intCast(@min(rows.len, max_rows));
}

/// Row `index` of the preview. Long text shows its newest rows; the last
/// row is the gap above the composer.
pub fn composeRow(alloc: Allocator, preview: Preview, index_in: u16, width: u16) !Row {
    var row: Row = .empty;
    errdefer row.deinit(alloc);
    if (index_in < preview.gap_above) return row;
    const text_rows = preview.rows -| 1 -| preview.gap_above;
    const index = index_in - preview.gap_above;
    if (index >= text_rows or width < 12) return row;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const all = try layout(arena_state.allocator(), preview.text, preview.kind, width);
    const shown = @min(all.len, text_rows);
    const first = all.len - shown;
    const pad = text_rows - @as(u16, @intCast(shown));
    if (index < pad) return row;
    const line_index = first + (index - pad);
    const line = all[line_index];

    var total_words: usize = 0;
    var words_before: usize = 0;
    for (all, 0..) |l, li| {
        const n = countWords(l);
        if (li < line_index) words_before += n;
        total_words += n;
    }
    const fresh_start = total_words -| preview.fresh_words;
    // Reasoning is drawn in the thinking block's own colour from its first
    // word, with no fade, so nothing changes colour when the transcript
    // takes it over. A reply fades its newest words in.
    const reasoning = preview.kind == .reasoning;
    const fade = !reasoning and preview.fresh_words > 0;
    try row.appendSlice(alloc, reset);
    if (reasoning) try row.appendSlice(alloc, ui_render.system_notice_text_style);
    try row.appendSlice(alloc, if (reasoning and line_index == 0) "* " else "  ");
    var word_index = words_before;
    var in_word = false;
    var faint = false;
    // A word wider than the row is cut to fit.
    const avail: usize = @as(usize, width) -| 2;
    var used: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const end = @min(i + len, line.len);
        const w = display_width.visibleWidth(line[i..end]);
        if (used + w > avail) break;
        const space = line[i] == ' ';
        if (!space and !in_word) {
            if (!faint and fade and word_index >= fresh_start) {
                try row.appendSlice(alloc, fresh_style);
                faint = true;
            }
            word_index += 1;
        }
        in_word = !space;
        try row.appendSlice(alloc, line[i..end]);
        used += w;
        i = end;
    }
    try row.appendSlice(alloc, reset);
    return row;
}
