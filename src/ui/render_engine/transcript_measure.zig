const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const assistant_wrap = @import("assistant_wrap.zig");
const text_utils = @import("../../core/shared/text_utils.zig");

pub const WalkResult = struct {
    end_row: u32,
    end_col: u16,
};

/// Walks visual rows without capping the result to the viewport. Under
/// DECAWM-OFF, glyphs wrap only when they exceed the right margin.
pub fn walkText(start_row: u32, start_col: u16, bytes: []const u8, cols: u16) WalkResult {
    if (bytes.len == 0 or cols == 0) return .{ .end_row = start_row, .end_col = start_col };

    var row: u32 = start_row;
    var col: u16 = start_col;
    var i: usize = 0;
    while (i < bytes.len) {
        const ch = bytes[i];

        // A run of printable ASCII is one cell per byte: advance it a row at
        // a time with the wrap rule below.
        if (ch >= 0x20 and ch <= 0x7e) {
            const end = asciiRunEnd(bytes, i);
            if (end > i) {
                advanceCells(&row, &col, end - i, cols);
                i = end;
                continue;
            }
        }

        if (ch == 0x1b) {
            i = display_width.ansiSequenceEnd(bytes, i);
            continue;
        }

        switch (ch) {
            '\r' => {
                col = 1;
                i += 1;
                continue;
            },
            '\n' => {
                col = 1;
                row += 1;
                i += 1;
                continue;
            },
            else => {},
        }

        if (ch == '\t') {
            col = display_width.nextTabStopColumn(col, cols);
            i += 1;
            continue;
        }

        if (ch < 32) {
            i += 1;
            continue;
        }

        const unit = display_width.displayUnitAt(bytes, i);
        const w_usize = unit.cell_width;
        if (w_usize == 0) {
            i += unit.byte_len;
            continue;
        }

        const w: u16 = @intCast(w_usize);
        if (display_width.shouldWrapAt(col, w, cols)) {
            col = 1;
            row += 1;
        }
        col += w;
        i += unit.byte_len;
    }
    return .{ .end_row = row, .end_col = col };
}

/// The end of the run of printable ASCII that starts at `start`. A rune after
/// the run may join its last byte into one cluster, so that byte is left out
/// and goes the slow way.
fn asciiRunEnd(bytes: []const u8, start: usize) usize {
    var end = start + 1;
    while (end < bytes.len and bytes[end] >= 0x20 and bytes[end] <= 0x7e) end += 1;
    if (end < bytes.len and bytes[end] >= 0x80) end -= 1;
    return end;
}

/// Advances the cursor over `cells` one-cell glyphs, a row at a time, with
/// `walkText`'s wrap rule.
fn advanceCells(row: *u32, col: *u16, cells: usize, cols: u16) void {
    var remaining = cells;
    while (remaining > 0) {
        if (display_width.shouldWrapAt(col.*, 1, cols)) {
            col.* = 1;
            row.* += 1;
        }
        const room: usize = @as(usize, cols) + 1 - col.*;
        const take = @min(remaining, room);
        col.* += @intCast(take);
        remaining -= take;
    }
}

// Transcript rows can carry SGR + OSC-8 + other escape sequences (image
// badges, the user-message bar). ANSI-aware walking skips escape bytes so
// terminal position tracking stays correct whether a row is plain text or styled.
pub fn nextCursorColForLine(line: []const u8, cols: u16) u16 {
    if (cols == 0) return 1;
    return @min(cols, walkText(1, 1, line, cols).end_col);
}

/// Returns the byte offset of visual row `skip_rows + 1` using the same
/// ANSI-aware wrapping rules as `visualRowsForLine`.
pub fn skipVisualRowsInLine(text: []const u8, cols: u16, skip_rows: u16) usize {
    if (skip_rows == 0 or cols == 0 or text.len == 0) return 0;

    var col: u16 = 1;
    var rows_skipped: u16 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == 0x1b) {
            i = display_width.ansiSequenceEnd(text, i);
            continue;
        }
        if (ch == '\r') {
            col = 1;
            i += 1;
            continue;
        }
        if (ch == '\n') {
            col = 1;
            rows_skipped += 1;
            i += 1;
            if (rows_skipped >= skip_rows) return i;
            continue;
        }
        if (ch == '\t') {
            col = display_width.nextTabStopColumn(col, cols);
            i += 1;
            continue;
        }
        if (ch < 32) {
            i += 1;
            continue;
        }

        const unit = display_width.displayUnitAt(text, i);
        const w_usize = unit.cell_width;
        if (w_usize == 0) {
            i += unit.byte_len;
            continue;
        }
        const w: u16 = @intCast(w_usize);

        if (display_width.shouldWrapAt(col, w, cols)) {
            col = 1;
            rows_skipped += 1;
            if (rows_skipped >= skip_rows) return i;
        }
        col += w;
        i += unit.byte_len;
    }
    return text.len;
}

pub fn visualRowsForLine(text: []const u8, cols: u16) u16 {
    if (cols == 0) return 1;
    if (text.len == 0) return 1;

    var col: u16 = 1;
    var rows: u16 = 1;
    var rows_with_content: u16 = 0;
    var wrote_on_current_row = false;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == 0x1b) {
            i = display_width.ansiSequenceEnd(text, i);
            continue;
        }
        switch (ch) {
            '\r' => {
                col = 1;
                i += 1;
                continue;
            },
            '\n' => {
                if (wrote_on_current_row) rows_with_content = rows;
                col = 1;
                rows += 1;
                wrote_on_current_row = false;
                i += 1;
                continue;
            },
            else => {},
        }
        if (ch == '\t') {
            col = display_width.nextTabStopColumn(col, cols);
            i += 1;
            continue;
        }
        if (ch < 32) {
            i += 1;
            continue;
        }

        const unit = display_width.displayUnitAt(text, i);
        i += unit.byte_len;
        const w_usize = unit.cell_width;
        if (w_usize == 0) continue;
        const w: u16 = @intCast(w_usize);

        if (display_width.shouldWrapAt(col, w, cols)) {
            col = 1;
            rows += 1;
            wrote_on_current_row = false;
        }
        col += w;
        wrote_on_current_row = true;
    }

    if (wrote_on_current_row) rows_with_content = rows;
    return if (rows_with_content == 0) 1 else rows_with_content;
}

test "skipVisualRowsInLine skips hard newlines" {
    const offset = skipVisualRowsInLine("a\nb\nc\nd", 80, 2);
    try std.testing.expectEqual(@as(usize, 4), offset);
}

/// The walk before ASCII runs were batched, kept as the oracle for `walkText`.
fn walkTextByteWise(start_row: u32, start_col: u16, bytes: []const u8, cols: u16) WalkResult {
    if (bytes.len == 0 or cols == 0) return .{ .end_row = start_row, .end_col = start_col };
    var row: u32 = start_row;
    var col: u16 = start_col;
    var i: usize = 0;
    while (i < bytes.len) {
        const ch = bytes[i];
        if (ch == 0x1b) {
            i = display_width.ansiSequenceEnd(bytes, i);
            continue;
        }
        switch (ch) {
            '\r' => {
                col = 1;
                i += 1;
                continue;
            },
            '\n' => {
                col = 1;
                row += 1;
                i += 1;
                continue;
            },
            else => {},
        }
        if (ch == '\t') {
            col = display_width.nextTabStopColumn(col, cols);
            i += 1;
            continue;
        }
        if (ch < 32) {
            i += 1;
            continue;
        }
        const unit = display_width.displayUnitAt(bytes, i);
        if (unit.cell_width == 0) {
            i += unit.byte_len;
            continue;
        }
        const w: u16 = @intCast(unit.cell_width);
        if (display_width.shouldWrapAt(col, w, cols)) {
            col = 1;
            row += 1;
        }
        col += w;
        i += unit.byte_len;
    }
    return .{ .end_row = row, .end_col = col };
}
