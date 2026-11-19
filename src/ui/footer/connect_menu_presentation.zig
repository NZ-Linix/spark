//! The `/connect` form in the footer. On the list it shows saved
//! connections and "Add connection", then Edit, Delete, or Back for the one
//! picked. In the form it shows a title with the step, the fields already
//! entered, the focused field with a cursor, and a line that says why Enter
//! was refused. The API key is always masked.

const std = @import("std");
const connect_menu = @import("../../core/input/connect_menu.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const State = connect_menu.State;

pub const max_inline_rows: u16 = 7 + connect_menu.max_models + connect_menu.max_connections;
const label_width = 18;

pub const hint_variants = [_][]const u8{
    "enter next     ↑ back     ←→ move     esc cancel",
    "enter next  ↑ back  esc cancel",
    "enter  ↑  esc",
};

pub const list_hint_variants = [_][]const u8{
    "↑↓ navigate     enter open     ← back     esc close",
    "↑↓ move  enter open  esc",
    "enter  esc",
};

fn step(state: *const State) []const u8 {
    return switch (state.field) {
        .pick => "saved connections",
        .action => state.editing orelse "",
        .name => "step 1 of 4 · name",
        .base_url => "step 2 of 4 · endpoint",
        .api_key => "step 3 of 4 · API key",
        .model_id, .model_name, .model_context, .model_efforts => "step 4 of 4 · models",
    };
}

fn filledFieldCount(state: *const State) usize {
    return switch (state.field) {
        .pick, .action, .name => 0,
        .base_url => 1,
        .api_key => 2,
        else => 3,
    };
}

/// Title, then the list rows; or title, filled fields, finished models, the
/// focused field, and the problem line.
/// The steps still ahead, shown dimmed below the current one so the whole
/// form is in view.
fn upcoming(state: *const State) []const []const u8 {
    const all = [_][]const u8{ "Endpoint URL", "API key", "Models" };
    return switch (state.field) {
        .name => all[0..],
        .base_url => all[1..],
        .api_key => all[2..],
        else => all[0..0],
    };
}

fn fullRowCount(state: *const State) u16 {
    if (state.field.isList()) return @intCast(1 + state.listLen());
    const listed = state.models.items.len - @intFromBool(describing(state));
    return @intCast(3 + filledFieldCount(state) + listed + upcoming(state).len);
}

fn describing(state: *const State) bool {
    return switch (state.field) {
        .model_name, .model_context, .model_efforts => true,
        else => false,
    };
}

pub fn menuRowCount(state: *const State, row_budget: u16) u16 {
    return @min(fullRowCount(state), row_budget);
}

pub fn composeConnectMenuRow(
    alloc: Allocator,
    state: *const State,
    row_index: u16,
    width: u16,
    row_budget: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0) return row;
    const total = fullRowCount(state);
    const shown = @min(total, row_budget);
    // A short footer keeps the bottom rows: the field being typed and its help.
    const index = row_index + (total - shown);
    if (index == 0) {
        try row.appendSlice(alloc, ui_render.selected_completion_style);
        try row_text.appendClipped(alloc, &row, if (state.editing != null) "Edit connection" else if (state.field.isList()) "Model connections" else "Add model connection", width);
        try row.appendSlice(alloc, ui_render.reset_style);
        if (width > 10) {
            try row.appendSlice(alloc, "  ");
            try row.appendSlice(alloc, ui_render.dim_style);
            try row_text.appendClipped(alloc, &row, step(state), width -| 24);
            try row.appendSlice(alloc, ui_render.reset_style);
        }
        return row;
    }
    if (state.field.isList()) {
        try appendListRow(alloc, &row, state, index - 1, width);
        return row;
    }
    var line: usize = index - 1;
    const filled = filledFieldCount(state);
    if (line < filled) {
        const field: connect_menu.Field = switch (line) {
            0 => .name,
            1 => .base_url,
            else => .api_key,
        };
        const value = switch (field) {
            .name => state.name.items,
            .base_url => state.base_url.items,
            else => if (state.api_key.items.len > 0) "••••••••" else if (state.key_env) |env| env else "none",
        };
        try appendLabeled(alloc, &row, field.label(), value, width);
        return row;
    }
    line -= filled;
    const models = state.models.items;
    const listed = models.len - @intFromBool(describing(state));
    if (line < listed) {
        try appendModel(alloc, &row, models[line], width);
        return row;
    }
    line -= listed;
    if (line == 0) {
        var label_buf: [80]u8 = undefined;
        const label = if (describing(state))
            std.mem.print(&label_buf, "{s} · {s}", .{ state.field.label(), models[models.len - 1].id }) catch state.field.label()
        else if (state.field == .model_id and state.pending.items.len > 0)
            "Model ID (saved)"
        else
            state.field.label();
        try appendFocused(alloc, &row, state, label, width);
        return row;
    }
    if (line >= 2) {
        const ahead = upcoming(state);
        if (line - 2 < ahead.len) {
            try row.appendSlice(alloc, "  ");
            try row.appendSlice(alloc, ui_render.dim_style);
            try row_text.appendClipped(alloc, &row, ahead[line - 2], width -| 2);
            try row.appendSlice(alloc, ui_render.reset_style);
        }
        return row;
    }
    if (line == 1) {
        if (state.problem) |problem| {
            try row.appendNTimes(alloc, ' ', @min(@as(usize, width), label_width + 2));
            try row.appendSlice(alloc, ui_render.warning_style);
            try row_text.appendClipped(alloc, &row, problem, width -| (label_width + 2));
            try row.appendSlice(alloc, ui_render.reset_style);
        } else if (state.input.items.len > 0) {
            try row.appendNTimes(alloc, ' ', @min(@as(usize, width), label_width + 2));
            try row.appendSlice(alloc, ui_render.dim_style);
            try row_text.appendClipped(alloc, &row, state.hint(), width -| (label_width + 2));
            try row.appendSlice(alloc, ui_render.reset_style);
        }
    }
    return row;
}

fn appendListRow(alloc: Allocator, row: *std.ArrayList(u8), state: *const State, item: usize, width: u16) !void {
    const selected = item == state.selected;
    const label: []const u8 = switch (state.field) {
        .pick => if (item < state.connections.items.len) state.connections.items[item] else "+ Add connection",
        else => connect_menu.actions[item],
    };
    try row.appendSlice(alloc, if (selected) "› " else "  ");
    const delete_row = state.field == .action and item == 1;
    try row.appendSlice(alloc, if (selected) (if (delete_row) ui_render.warning_style else ui_render.selected_completion_style) else ui_render.dim_style);
    try row_text.appendClipped(alloc, row, label, width -| 2);
    try row.appendSlice(alloc, ui_render.reset_style);
}

const bullets = "••••••••••••••••••••••••••••••••";

fn masked(len: usize) []const u8 {
    const bullet_bytes = "•".len;
    return bullets[0 .. @min(len, bullets.len / bullet_bytes) * bullet_bytes];
}

fn appendLabeled(alloc: Allocator, row: *std.ArrayList(u8), label: []const u8, value: []const u8, width: u16) !void {
    try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, row, label, @min(@as(usize, width) -| 2, label_width - 1));
    try row.appendSlice(alloc, ui_render.reset_style);
    try row_text.appendSpacesToColumn(alloc, row, label_width + 2);
    const room = @as(usize, width) -| (label_width + 3);
    try row_text.appendSingleLineEllipsized(alloc, row, value, room);
}

/// The field being typed: its text with a block cursor at the cursor, a
/// masked key, or the field's hint as a dim placeholder while it is empty.
fn appendFocused(alloc: Allocator, row: *std.ArrayList(u8), state: *const State, label: []const u8, width: u16) !void {
    try row.appendSlice(alloc, "› ");
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    try row_text.appendClipped(alloc, row, label, @min(@as(usize, width) -| 2, label_width - 1));
    try row.appendSlice(alloc, ui_render.reset_style);
    try row_text.appendSpacesToColumn(alloc, row, label_width + 2);
    const room = @as(usize, width) -| (label_width + 3);
    if (room == 0) return;

    const text = state.input.items;
    if (text.len == 0) {
        try row.appendSlice(alloc, "\x1b[7m \x1b[27m");
        try row.appendSlice(alloc, ui_render.dim_style);
        try row_text.appendSingleLineEllipsized(alloc, row, state.hint(), room -| 2);
        try row.appendSlice(alloc, ui_render.reset_style);
        return;
    }
    if (state.field == .api_key) {
        // Show the cursor's place among the bullets without the key itself.
        const chars = @min(text.len, room - 1);
        const at = @min(state.cursor, chars);
        try row.appendSlice(alloc, masked(at));
        try row.appendSlice(alloc, if (at < chars) "\x1b[7m•\x1b[27m" else "\x1b[7m \x1b[27m");
        if (at + 1 < chars) try row.appendSlice(alloc, masked(chars - at - 1));
        return;
    }
    // Scroll so the cursor stays in view on a long URL.
    var start: usize = 0;
    if (state.cursor + 1 > room) start = state.cursor + 1 - room;
    while (start < text.len and text[start] & 0xC0 == 0x80) start += 1;
    var end = @min(text.len, start + room);
    while (end < text.len and end > start and text[end] & 0xC0 == 0x80) end -= 1;
    // Typed text has no control bytes (`State.appendByte` drops them).
    try row.appendSlice(alloc, text[start..state.cursor]);
    if (state.cursor < text.len) {
        var next = state.cursor + 1;
        while (next < text.len and text[next] & 0xC0 == 0x80) next += 1;
        try row.appendSlice(alloc, "\x1b[7m");
        try row.appendSlice(alloc, text[state.cursor..next]);
        try row.appendSlice(alloc, "\x1b[27m");
        if (next < end) try row.appendSlice(alloc, text[next..end]);
    } else {
        try row.appendSlice(alloc, "\x1b[7m \x1b[27m");
    }
}

fn appendModel(alloc: Allocator, row: *std.ArrayList(u8), model: connect_menu.Model, width: u16) !void {
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    writer.writeAll(model.id) catch {};
    if (model.name) |name| writer.print(" ({s})", .{name}) catch {};
    if (model.context) |tokens| writer.print(" · {d} tokens", .{tokens}) catch {};
    if (model.efforts) |levels| writer.print(" · {s}", .{levels}) catch {};
    try appendLabeled(alloc, row, "Model", writer.buffered(), width);
}
