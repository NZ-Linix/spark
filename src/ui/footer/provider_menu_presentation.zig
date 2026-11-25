//! The `/provider` form in the footer. It shows saved connections and "Add
//! connection", then the picked connection's fields with their values, or a
//! model's fields. Editing a field shows only that field with a cursor and
//! a line that says why Enter was refused. The API key is always masked.

const std = @import("std");
const provider_menu = @import("../../core/input/provider_menu.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const State = provider_menu.State;

pub const max_inline_rows: u16 = 8 + provider_menu.max_models + provider_menu.max_connections;
const label_width = 18;

pub const hint_variants = [_][]const u8{
    "enter save     esc back     ←→ move",
    "enter save  esc back",
    "enter  esc",
};

pub const list_hint_variants = [_][]const u8{
    "↑↓ navigate     enter edit     esc back",
    "↑↓ move  enter edit  esc",
    "enter  esc",
};

fn subtitle(state: *const State, buf: []u8) []const u8 {
    return switch (state.field) {
        .pick => "saved connections",
        .plan_account => switch (state.plan) {
            .chatgpt => "uses a ChatGPT plan",
            .claude => "uses a Claude subscription",
            .antigravity => "uses an Antigravity (Google AI) subscription",
        },
        .plan_settings => if (state.saved) "account settings · saved" else "account settings",
        .plan_model => blk: {
            const id = if (state.model_index < state.models.items.len) state.models.items[state.model_index].id else "";
            break :blk std.mem.print(buf, "model {s}{s}", .{ id, if (state.saved) " · saved" else "" }) catch id;
        },
        .plan_label => switch (state.plan) {
            .chatgpt => "uses a ChatGPT plan, no API key",
            .claude => "uses a Claude Pro or Max subscription, no API key",
            .antigravity => "uses an Antigravity (Google AI) subscription, no API key",
        },
        .overview => if (state.saved) "saved" else if (state.editing == null) "new · choose a field" else "choose a field",
        .model => blk: {
            const id = if (state.model_index < state.models.items.len) state.models.items[state.model_index].id else "";
            break :blk std.mem.print(buf, "model {s}{s}", .{ id, if (state.saved) " · saved" else "" }) catch id;
        },
        else => state.field.label(),
    };
}

/// Title, then the list rows; or title, the field being typed, and a line
/// with the problem or hint.
fn fullRowCount(state: *const State) u16 {
    if (state.field.isList()) return @intCast(2 + state.listLen());
    return 3;
}

pub fn menuRowCount(state: *const State, row_budget: u16) u16 {
    return @min(fullRowCount(state), row_budget);
}

pub fn composeProviderMenuRow(
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
    // A short footer keeps the bottom rows: the list end or the field being typed.
    var index = row_index + (total - shown);
    if (state.field.isList() and shown < total and state.selected + 2 >= shown) {
        // Keep the highlighted row in view.
        index = row_index + @as(u16, @intCast(@min(@as(usize, total - shown), state.selected + 3 - shown)));
    }
    if (index == 0) {
        var title_buf: [96]u8 = undefined;
        const title: []const u8 = if (state.field == .pick)
            "Model connections"
        else if (state.editing) |_|
            (std.mem.print(&title_buf, "{s}", .{if (state.custom_name.items.len > 0 and state.isPlanAccount())
                state.custom_name.items
            else if (state.display_name.items.len > 0)
                state.display_name.items
            else
                state.name.items}) catch "Edit connection")
        else if (state.field == .plan_label)
            continueLabel(state.plan)
        else if (state.name.items.len > 0)
            (std.mem.print(&title_buf, "New connection {s}", .{state.name.items}) catch "New connection")
        else
            "New connection";
        try row.appendSlice(alloc, ui_render.selected_completion_style);
        try row_text.appendClipped(alloc, &row, title, width);
        try row.appendSlice(alloc, ui_render.reset_style);
        if (width > 10) {
            var buf: [128]u8 = undefined;
            try row.appendSlice(alloc, "  ");
            try row.appendSlice(alloc, ui_render.dim_style);
            try row_text.appendClipped(alloc, &row, subtitle(state, &buf), width -| 24);
            try row.appendSlice(alloc, ui_render.reset_style);
        }
        return row;
    }
    if (state.field.isList()) {
        if (index - 1 < state.listLen()) {
            try appendListRow(alloc, &row, state, index - 1, width);
        } else if (state.problem) |problem| {
            try row.appendSlice(alloc, "  ");
            try row.appendSlice(alloc, ui_render.warning_style);
            try row_text.appendClipped(alloc, &row, problem, width -| 2);
            try row.appendSlice(alloc, ui_render.reset_style);
        }
        return row;
    }
    if (index == 1) {
        try appendFocused(alloc, &row, state, state.field.label(), width);
        return row;
    }
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
    return row;
}

fn appendListRow(alloc: Allocator, row: *std.ArrayList(u8), state: *const State, item: usize, width: u16) !void {
    const selected = item == state.selected;
    try row.appendSlice(alloc, if (selected) "› " else "  ");
    var buf: [512]u8 = undefined;
    switch (state.field) {
        .pick => {
            const label = if (item < state.connections.items.len)
                (state.connectionLabel(item) orelse state.connections.items[item])
            else if (state.planAt(item)) |kind|
                continueLabel(kind)
            else
                "+ Add connection";
            try appendAction(alloc, row, label, selected, false, width);
        },
        .plan_account => try appendAction(alloc, row, switch (State.planAction(item)) {
            .use => "Use this account",
            .edit => "Edit account",
            .reconnect => "Sign in again",
            .usage => switch (state.plan) {
                .chatgpt => "Manage ChatGPT usage",
                .claude => "Manage Claude usage",
                .antigravity => "Open Antigravity",
            },
            .remove => "Disconnect account",
            .back => "Back",
        }, selected, State.planAction(item) == .remove, width),
        .plan_settings => switch (state.planSettingsRow(item)) {
            .field => |field| {
                var tokens_buf: [16]u8 = undefined;
                const value: []const u8 = switch (field) {
                    .account_label => state.account_label.items,
                    .account_name => state.custom_name.items,
                    else => if (state.context_limit) |tokens| std.mem.print(&tokens_buf, "{d}", .{tokens}) catch "" else "",
                };
                try appendValueRow(alloc, row, field.label(), value, selected, width);
            },
            .model => |index| try appendValueRow(alloc, row, "Model", planModelSummary(state.models.items[index], state.context_limit, &buf), selected, width),
            .back => try appendAction(alloc, row, "Back", selected, false, width),
        },
        .plan_model => switch (State.planModelRow(item)) {
            .field => |field| {
                const model = state.models.items[state.model_index];
                var tokens_buf: [32]u8 = undefined;
                const value: []const u8 = switch (field) {
                    .model_name => model.name orelse model.served_name orelse "",
                    .model_context => if (model.context orelse model.served_context) |tokens| std.mem.print(&tokens_buf, "{d}{s}", .{ tokens, if (model.context == null) " (plan)" else "" }) catch "" else "",
                    else => model.default_effort orelse "",
                };
                try appendValueRow(alloc, row, field.label(), value, selected, width);
            },
            else => try appendAction(alloc, row, "Back", selected, false, width),
        },
        .overview => switch (state.overviewRow(item)) {
            .field => |field| try appendValueRow(alloc, row, field.label(), fieldValue(state, field), selected, width),
            .model => |index| try appendValueRow(alloc, row, "Model", modelSummary(state.models.items[index], &buf), selected, width),
            .add_model => try appendAction(alloc, row, "+ Add model", selected, false, width),
            .create => try appendAction(alloc, row, "Create connection", selected, false, width),
            .delete => try appendAction(alloc, row, "Delete connection", selected, true, width),
            .back => try appendAction(alloc, row, "Back", selected, false, width),
        },
        .model => switch (State.modelRow(item)) {
            .field => |field| {
                const model = state.models.items[state.model_index];
                var tokens_buf: [16]u8 = undefined;
                const value: []const u8 = switch (field) {
                    .model_id => model.id,
                    .model_name => model.name orelse "",
                    .model_context => if (model.context) |tokens| std.mem.print(&tokens_buf, "{d}", .{tokens}) catch "" else "",
                    .model_default_effort => model.default_effort orelse "",
                    else => model.efforts orelse "",
                };
                try appendValueRow(alloc, row, field.label(), value, selected, width);
            },
            .delete => try appendAction(alloc, row, "Delete model", selected, true, width),
            .back => try appendAction(alloc, row, "Back", selected, false, width),
        },
        else => {},
    }
}

fn fieldValue(state: *const State, field: provider_menu.Field) []const u8 {
    return switch (field) {
        .display_name => state.display_name.items,
        .name => state.name.items,
        .base_url => state.base_url.items,
        .api_key => if (state.api_key.items.len > 0) "••••••••" else if (state.key_env) |env| env else "none",
        else => "",
    };
}

fn modelSummary(model: provider_menu.Model, buf: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    writer.writeAll(model.name orelse model.id) catch {};
    if (model.name != null) writer.print(" ({s})", .{model.id}) catch {};
    if (model.context) |tokens| writer.print(" · {d} tokens", .{tokens}) catch {};
    if (model.efforts) |levels| writer.print(" · {s}", .{levels}) catch {};
    if (model.default_effort) |level| writer.print(" · default {s}", .{level}) catch {};
    return writer.buffered();
}

/// A subscription model's row: its name with what the person set.
fn planModelSummary(model: provider_menu.Model, limit: ?u32, buf: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    writer.writeAll(model.name orelse model.served_name orelse model.id) catch {};
    const window = model.context orelse model.served_context;
    if (if (limit) |cap| @min(window orelse cap, cap) else window) |tokens| writer.print(" · {d} tokens", .{tokens}) catch {};
    if (model.default_effort) |level| writer.print(" · default {s}", .{level}) catch {};
    return writer.buffered();
}

fn appendAction(alloc: Allocator, row: *std.ArrayList(u8), label: []const u8, selected: bool, destructive: bool, width: u16) !void {
    try row.appendSlice(alloc, if (selected) (if (destructive) ui_render.warning_style else ui_render.selected_completion_style) else ui_render.dim_style);
    try row_text.appendClipped(alloc, row, label, width -| 2);
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn appendValueRow(alloc: Allocator, row: *std.ArrayList(u8), label: []const u8, value: []const u8, selected: bool, width: u16) !void {
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendClipped(alloc, row, label, @min(@as(usize, width) -| 2, label_width - 1));
    try row.appendSlice(alloc, ui_render.reset_style);
    try row_text.appendSpacesToColumn(alloc, row, label_width + 2);
    const room = @as(usize, width) -| (label_width + 3);
    if (value.len == 0) {
        try row.appendSlice(alloc, ui_render.dim_style);
        try row_text.appendSingleLineEllipsized(alloc, row, "not set", room);
        try row.appendSlice(alloc, ui_render.reset_style);
    } else try row_text.appendSingleLineEllipsized(alloc, row, value, room);
}

const bullets = "••••••••••••••••••••••••••••••••";

fn masked(len: usize) []const u8 {
    const bullet_bytes = "•".len;
    return bullets[0 .. @min(len, bullets.len / bullet_bytes) * bullet_bytes];
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

/// The connection list's row that signs in to a plan.
fn continueLabel(kind: @import("../../core/auth/plan_kind.zig").Kind) []const u8 {
    return switch (kind) {
        .chatgpt => "Continue with ChatGPT",
        .claude => "Continue with Claude",
        .antigravity => "Continue with Antigravity (Google)",
    };
}
