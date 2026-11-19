//! Draws `core/input/list_picker.zig`: a title with the filter typed so
//! far, the items with the selection bright, and in input mode the one line
//! being typed with its cursor.

const std = @import("std");
const list_picker = @import("../../core/input/list_picker.zig");
const line_input = @import("../../core/input/line_input.zig");
const row_text = @import("row_text.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const Row = std.ArrayList(u8);
const State = list_picker.State;

/// The title, the items, and a row saying how many more there are.
pub const max_inline_rows: u16 = 2 + list_picker.window;
const label_col = 4;

pub const pick_hints = [_][]const u8{
    "↑↓ navigate     enter choose     type to filter     esc close",
    "↑↓ move  enter choose  esc close",
    "enter  esc",
};

pub const prompt_pick_hints = [_][]const u8{
    "↑↓ navigate     enter choose     tab star     type to filter     esc close",
    "↑↓ move  enter choose  tab star  esc close",
    "enter  tab  esc",
};

pub const input_hints = [_][]const u8{
    "enter save     esc back",
    "enter  esc",
};

pub fn hintVariants(state: *const State) []const []const u8 {
    if (state.mode == .input) return &input_hints;
    return if (state.purpose == .prompt) &prompt_pick_hints else &pick_hints;
}

/// The title, the list rows, and a scroll row when the whole list is longer
/// than the window. None of it follows the filter, so the picker keeps one
/// height while the user types.
fn rowCount(state: *const State) usize {
    if (state.mode == .input) return 4;
    return 1 + state.listRows() + @intFromBool(state.items.len > list_picker.window);
}

pub fn menuRowCount(state: *const State, budget: u16) u16 {
    return @intCast(@min(rowCount(state), budget));
}

pub fn composeRow(alloc: Allocator, state: *const State, index: u16, width: u16) !Row {
    var row: Row = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;
    if (state.mode == .input) return inputRow(alloc, state, index, width);
    if (index == 0) {
        try row.appendSlice(alloc, "  ");
        try row.appendSlice(alloc, ui_render.subtitle_style);
        try row_text.appendClipped(alloc, &row, state.title, width / 2);
        try row.appendSlice(alloc, ui_render.reset_style);
        try row.appendSlice(alloc, "  ");
        if (state.filter.items().len == 0) {
            try row.appendSlice(alloc, ui_render.dim_style);
            try row.appendSlice(alloc, "type to filter");
            try row.appendSlice(alloc, ui_render.reset_style);
        } else {
            try appendLine(alloc, &row, &state.filter, @as(usize, width) -| (row.items.len));
        }
        return row;
    }
    const n = state.visibleCount();
    if (n == 0) {
        if (index == 1) {
            try row.appendSlice(alloc, "  ");
            try row.appendSlice(alloc, ui_render.dim_style);
            try row.appendSlice(alloc, "Nothing matches.");
            try row.appendSlice(alloc, ui_render.reset_style);
        }
        return row;
    }
    const top = state.top();
    const line = top + index - 1;
    if (index == state.listRows() + 1) {
        const above = top;
        const below = n -| (top + list_picker.window);
        if (above > 0 or below > 0) {
            var buf: [64]u8 = undefined;
            try row.appendSlice(alloc, "  ");
            try row.appendSlice(alloc, ui_render.dim_style);
            const text = if (above > 0 and below > 0)
                std.mem.print(&buf, "↑ {d} more above · ↓ {d} more below", .{ above, below })
            else if (above > 0)
                std.mem.print(&buf, "↑ {d} more above", .{above})
            else
                std.mem.print(&buf, "↓ {d} more below", .{below});
            try row.appendSlice(alloc, text catch "");
            try row.appendSlice(alloc, ui_render.reset_style);
        }
        return row;
    }
    const item = state.visible(line) orelse return row;
    if (item.section) {
        try row.appendSlice(alloc, "  ");
        try row.appendSlice(alloc, ui_render.subtitle_style);
        try row_text.appendTerminalSafeSingleLine(alloc, &row, item.label, @as(usize, width) -| 2);
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }
    const selected = line == @min(state.selected, n - 1);
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else if (item.action) ui_render.hint_style else ui_render.dim_style);
    try row.appendSlice(alloc, if (selected) "› " else "  ");
    try row.appendSlice(alloc, if (item.marked) "✓ " else "  ");
    const label_room: usize = @min(@as(usize, width) -| label_col, state.label_cols);
    try row_text.appendTerminalSafeSingleLine(alloc, &row, item.label, label_room);
    if (item.starred) try row.appendSlice(alloc, " ★");
    try row.appendSlice(alloc, ui_render.reset_style);
    // The star sits in the gap before the detail column, so it never moves it.
    if (item.detail.len > 0 and width > label_col + label_room + 4) {
        try row_text.appendSpacesToColumn(alloc, &row, label_col + label_room + 3);
        try row.appendSlice(alloc, ui_render.dim_style);
        try row_text.appendTerminalSafeSingleLine(alloc, &row, item.detail, @as(usize, width) -| (label_col + label_room + 3));
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    return row;
}

fn inputRow(alloc: Allocator, state: *const State, index: u16, width: u16) !Row {
    var row: Row = .empty;
    errdefer row.deinit(alloc);
    switch (index) {
        0 => {
            try row.appendSlice(alloc, "  ");
            try row.appendSlice(alloc, ui_render.subtitle_style);
            try row_text.appendClipped(alloc, &row, state.input_label, width -| 2);
            try row.appendSlice(alloc, ui_render.reset_style);
        },
        1 => {
            try row.appendSlice(alloc, ui_render.selected_completion_style);
            try row.appendSlice(alloc, "› ");
            try row.appendSlice(alloc, ui_render.reset_style);
            try appendLine(alloc, &row, &state.input, @as(usize, width) -| 3);
        },
        2 => if (state.problem) |problem| {
            try row.appendSlice(alloc, "  ");
            try row.appendSlice(alloc, ui_render.warning_style);
            try row_text.appendClipped(alloc, &row, problem, width -| 2);
            try row.appendSlice(alloc, ui_render.reset_style);
        },
        else => {},
    }
    return row;
}

/// The line with its cursor drawn in reverse video, scrolled to keep it in view.
fn appendLine(alloc: Allocator, row: *Row, in: *const line_input.LineInput, room: usize) !void {
    if (room == 0) return;
    const text = in.items();
    const cursor = @min(in.cursor, text.len);
    var start: usize = if (cursor + 1 > room) cursor + 1 - room else 0;
    while (start < text.len and text[start] & 0xC0 == 0x80) start += 1;
    try row_text.appendTerminalSafeSingleLine(alloc, row, text[start..cursor], room);
    if (cursor < text.len) {
        var after = cursor + 1;
        while (after < text.len and text[after] & 0xC0 == 0x80) after += 1;
        try row.appendSlice(alloc, "\x1b[7m");
        try row_text.appendTerminalSafeSingleLine(alloc, row, text[cursor..after], 1);
        try row.appendSlice(alloc, "\x1b[27m");
        const end = @min(text.len, start + room);
        if (after < end) try row_text.appendTerminalSafeSingleLine(alloc, row, text[after..end], room);
    } else {
        try row.appendSlice(alloc, "\x1b[7m \x1b[27m");
    }
    _ = text_utils;
}
