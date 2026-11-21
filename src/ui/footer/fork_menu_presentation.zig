const std = @import("std");
const input_presentation = @import("input_presentation.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const ForkMenuProjection = render_input.ForkMenuProjection;

/// Each prompt shows as at most this many wrapped lines.
const max_prompt_lines = render_input.max_message_layout_rows;
/// Six prompts of three lines.
pub const max_inline_rows: u16 = 6 * max_prompt_lines;

fn indentWidth(width: u16) u16 {
    return if (width > 4) 2 else 0;
}

fn promptLayout(prompt: []const u8, width: u16) render_input.SteeringMessageLayout {
    return render_input.steering_message_layout(prompt, width - indentWidth(width), false, max_prompt_lines);
}

/// The menu's lines, every prompt's in order, and where the selected one sits.
const Lines = struct {
    total: usize = 0,
    selected_start: usize = 0,
    selected_end: usize = 0,

    fn measure(projection: ForkMenuProjection, width: u16) Lines {
        var lines: Lines = .{};
        for (projection.points, 0..) |point, index| {
            if (index == projection.selected) lines.selected_start = lines.total;
            lines.total += promptLayout(point.prompt, width).row_count;
            if (index == projection.selected) lines.selected_end = lines.total;
        }
        return lines;
    }
};

pub fn menuRowCount(projection: ForkMenuProjection, width: u16, row_budget: u16) u16 {
    if (projection.question != null) return @intCast(@min(row_budget, questionRows(projection, width)));
    return @intCast(@min(row_budget, Lines.measure(projection, width).total));
}

/// The question's rows: the chosen prompt, then the question (D97).
fn questionRows(projection: ForkMenuProjection, width: u16) usize {
    return promptLayout(projection.points[projection.selected].prompt, width).row_count + 1;
}

/// The keys the question takes, widest first.
pub const question_hint_variants = [_][]const u8{
    "enter yes     n or esc no",
    "enter yes  n or esc no",
    "enter y  esc n",
    "enter esc",
};

/// The question after a prompt is chosen where the session had subagents.
fn questionText(buf: []u8, count: usize) []const u8 {
    if (count == 1) return "Bring 1 subagent into the fork?";
    return std.mem.print(buf, "Bring {d} subagents into the fork?", .{count}) catch "Bring the subagents into the fork?";
}

/// Row `row_index` of the question: the chosen prompt, dim, then the
/// question. A short budget drops prompt lines first.
fn composeQuestionRow(alloc: Allocator, row: *std.ArrayList(u8), projection: ForkMenuProjection, count: usize, row_index: u16, width: u16, row_budget: u16) !void {
    const layout = promptLayout(projection.points[projection.selected].prompt, width);
    const total = layout.row_count + 1;
    const line = total - @min(row_budget, total) + row_index;
    try row.appendNTimes(alloc, ' ', indentWidth(width));
    if (line < layout.row_count) {
        try row.appendSlice(alloc, ui_render.dim_style);
        try input_presentation.appendMessageLayoutRow(alloc, row, layout, line);
    } else {
        var buf: [64]u8 = undefined;
        try row.appendSlice(alloc, ui_render.selected_completion_style);
        try row_text.appendClipped(alloc, row, questionText(&buf, count), width - indentWidth(width));
    }
    try row.appendSlice(alloc, ui_render.reset_style);
}

/// The first line shown: `projection.window_start`, moved only as far as it
/// takes to show the whole selected prompt, so the list scrolls at its edges.
pub fn windowStart(projection: ForkMenuProjection, width: u16, row_budget: u16) usize {
    const lines = Lines.measure(projection, width);
    const height: usize = @min(row_budget, lines.total);
    var start = @min(projection.window_start, lines.total - height);
    if (lines.selected_start < start) start = lines.selected_start;
    if (lines.selected_end > start + height) start = @min(lines.selected_start, lines.selected_end - height);
    return start;
}

pub fn composeForkMenuRow(
    alloc: Allocator,
    projection: ForkMenuProjection,
    row_index: u16,
    width: u16,
    row_budget: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0 or row_index >= row_budget) return row;
    if (projection.question) |count| {
        try composeQuestionRow(alloc, &row, projection, count, row_index, width, row_budget);
        return row;
    }
    const line = windowStart(projection, width, row_budget) + row_index;
    var first: usize = 0;
    for (projection.points, 0..) |point, index| {
        const layout = promptLayout(point.prompt, width);
        if (line < first + layout.row_count) {
            try row.appendNTimes(alloc, ' ', indentWidth(width));
            try row.appendSlice(alloc, if (index == projection.selected) ui_render.selected_completion_style else ui_render.dim_style);
            try input_presentation.appendMessageLayoutRow(alloc, &row, layout, line - first);
            try row.appendSlice(alloc, ui_render.reset_style);
            return row;
        }
        first += layout.row_count;
    }
    return row;
}

const ForkPoint = std.meta.Child(@FieldType(ForkMenuProjection, "points"));

/// The visible text of row `row_index`, and whether it is selected. Caller owns the text.
fn testRow(projection: ForkMenuProjection, row_index: u16, width: u16, row_budget: u16) !struct { text: []u8, selected: bool } {
    const alloc = std.testing.allocator;
    var row = try composeForkMenuRow(alloc, projection, row_index, width, row_budget);
    defer row.deinit(alloc);
    const selected = std.mem.find(u8, row.items, ui_render.selected_completion_style) != null;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    var index: usize = 0;
    while (index < row.items.len) {
        if (row.items[index] == 0x1b) {
            index = std.mem.findScalarPos(u8, row.items, index, 'm').? + 1;
            continue;
        }
        try text.append(alloc, row.items[index]);
        index += 1;
    }
    return .{ .text = try text.toOwnedSlice(alloc), .selected = selected };
}
