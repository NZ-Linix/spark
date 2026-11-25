const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const list_window = @import("../../core/shared/list_window.zig");
const model_cache_runtime = @import("../../core/app/model_cache_runtime.zig");
const model_capabilities = @import("../../core/config/model_capabilities.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");
const ui_render = @import("../render.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");

const Allocator = std.mem.Allocator;
const ModelMenuProjection = render_input.ModelMenuProjection;

const header_rows: u16 = 1;
const roomy_top_gap_rows: u16 = 1;
const item_rows: u16 = 1;
const status_gap_rows: u16 = 1;
pub const max_visible_items: u16 = 20;
pub const max_inline_rows: u16 = header_rows + roomy_top_gap_rows + max_visible_items + status_gap_rows + 1;

const ModelMenuLayout = struct {
    match_count: usize = 0,
    selected: usize = 0,
    /// The models the window keeps in view, which navigation pages by.
    visible_items: u16 = 0,
    /// The rows the list takes below the gap: one per model.
    body_rows: u16 = 0,
    first_item_row: u16 = header_rows,
    item_stride: u16 = item_rows,
    show_header: bool = true,
    state_row: ?u16 = null,
    status_row: ?u16 = null,
    row_count: u16 = 0,

    fn build(projection: ModelMenuProjection, row_budget: u16) ModelMenuLayout {
        if (row_budget == 0) return .{};

        const match_count = projection.filteredItemCount();
        const selected = if (match_count > 0) projection.selected_index % match_count else 0;
        if (projection.load_state != .ready or match_count == 0) {
            const state_row: u16 = if (row_budget == 1)
                0
            else if (row_budget == 2)
                1
            else
                header_rows + roomy_top_gap_rows;
            var row_count = state_row + 1;
            const show_status = projection.load_state == .ready and
                loadedCatalogStatusText(projection.catalog_state) != null and
                row_budget >= row_count + status_gap_rows + 1;
            const status_row = if (show_status) row_count + status_gap_rows else null;
            if (status_row) |row| row_count = row + 1;
            return .{
                .match_count = match_count,
                .selected = selected,
                .show_header = row_budget > 1,
                .state_row = state_row,
                .status_row = status_row,
                .row_count = row_count,
            };
        }
        if (row_budget == 1) {
            return .{
                .match_count = match_count,
                .selected = selected,
                .visible_items = 1,
                .body_rows = 1,
                .first_item_row = 0,
                .show_header = false,
                .row_count = 1,
            };
        }
        if (row_budget == 2) {
            return .{
                .match_count = match_count,
                .selected = selected,
                .visible_items = 1,
                .body_rows = 1,
                .first_item_row = 1,
                .row_count = 2,
            };
        }
        const first_item_row = header_rows + roomy_top_gap_rows;
        const item_budget = @max(row_budget - first_item_row, 1);
        const body_rows: u16 = @intCast(@min(match_count, item_budget, max_visible_items));
        const show_status = loadedCatalogStatusText(projection.catalog_state) != null and item_budget - body_rows >= status_gap_rows + 1;
        const status_row = if (show_status) first_item_row + body_rows + status_gap_rows else null;
        return .{
            .match_count = match_count,
            .selected = selected,
            .visible_items = body_rows,
            .body_rows = body_rows,
            .first_item_row = first_item_row,
            .item_stride = item_rows,
            .status_row = status_row,
            .row_count = first_item_row + body_rows + @intFromBool(show_status) * (status_gap_rows + 1),
        };
    }
};

pub fn menuRowCount(projection: ModelMenuProjection, _: u16, max_rows: u16) u16 {
    return ModelMenuLayout.build(projection, max_rows).row_count;
}

pub fn visibleNavigationItemsForBudget(projection: ModelMenuProjection, row_budget: u16) u16 {
    return ModelMenuLayout.build(projection, row_budget).visible_items;
}

pub inline fn composeModelMenuRow(
    alloc: Allocator,
    projection: ModelMenuProjection,
    row_index: u16,
    width: u16,
    row_count: u16,
) !std.ArrayList(u8) {
    const row: std.ArrayList(u8) = .empty;
    if (width == 0 or row_index >= row_count) return row;

    const layout = ModelMenuLayout.build(projection, row_count);
    if (layout.show_header and row_index == 0) return composeHeaderRow(alloc, projection, width);
    if (projection.load_state != .ready or layout.match_count == 0) {
        if (layout.state_row == row_index) return composeStateRow(alloc, projection, width);
        if (layout.status_row == row_index) {
            const text = loadedCatalogStatusText(projection.catalog_state) orelse return row;
            return composeDimmedRow(alloc, text, width);
        }
        return row;
    }
    if (layout.status_row) |status_row| {
        if (row_index == status_row) {
            const text = loadedCatalogStatusText(projection.catalog_state) orelse return row;
            return composeDimmedRow(alloc, text, width);
        }
    }
    if (row_index < layout.first_item_row) return row;

    const body_offset = row_index - layout.first_item_row;
    if (body_offset >= layout.body_rows) return row;
    const window_start = list_window.updateEdgeStart(
        projection.window_start,
        layout.match_count,
        layout.selected,
        layout.visible_items,
    );
    const item_row = body_offset % layout.item_stride;
    const display_index = window_start + body_offset / layout.item_stride;
    const item = projection.itemAt(display_index) orelse return row;

    if (item_row == 0) {
        return composeTitleRow(
            alloc,
            item.*,
            display_index == layout.selected,
            FactColumns.build(projection, width),
            width,
        );
    }
    return row;
}

fn composeHeaderRow(alloc: Allocator, projection: ModelMenuProjection, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try appendHeaderTitle(alloc, &row, projection.filteredItemCount());

    const tabs = ProviderTabs.build(projection.items);
    const active_position = tabs.activePosition(projection.provider_index);
    const active_index = tabs.indices[active_position];
    const title_width = display_width.visibleWidthIgnoringAnsi(row.items);
    if (title_width + 2 + providerTabWidth(active_index, active_index) > width) {
        try row.appendSlice(alloc, "  ");
        try appendProviderTabAt(alloc, &row, active_index, active_index);
        return cloneClippedRow(alloc, row.items, width);
    }

    var start = active_position;
    var end = active_position + 1;
    while (true) {
        var expanded = false;
        if (end < tabs.len and title_width + 2 + providerRangeWidth(tabs, start, end + 1, active_index) <= width) {
            end += 1;
            expanded = true;
        }
        if (start > 0 and title_width + 2 + providerRangeWidth(tabs, start - 1, end, active_index) <= width) {
            start -= 1;
            expanded = true;
        }
        if (!expanded) break;
    }

    try row.appendSlice(alloc, "  ");
    if (start > 0) {
        try appendProviderOverflowMarker(alloc, &row);
        try row.appendSlice(alloc, "  ");
    }
    for (start..end) |position| {
        if (position > start) try row.appendSlice(alloc, "  ");
        try appendProviderTabAt(alloc, &row, tabs.indices[position], active_index);
    }
    if (end < tabs.len) {
        try row.appendSlice(alloc, "  ");
        try appendProviderOverflowMarker(alloc, &row);
    }
    return cloneClippedRow(alloc, row.items, width);
}

const ProviderTabs = struct {
    indices: [model_cache_runtime.model_provider_filter_count]usize = undefined,
    len: usize = 0,

    fn build(items: []const model_cache_runtime.ModelMenuItem) ProviderTabs {
        var tabs: ProviderTabs = .{};
        for (0..model_cache_runtime.model_provider_filter_count) |index| {
            const filter: model_cache_runtime.ModelProviderFilter = @fromBackingInt(@intCast(index));
            if (!model_cache_runtime.modelProviderFilterAvailable(items, filter)) continue;
            tabs.indices[tabs.len] = index;
            tabs.len += 1;
        }
        return tabs;
    }

    fn activePosition(self: ProviderTabs, active_index: usize) usize {
        for (self.indices[0..self.len], 0..) |index, position| {
            if (index == active_index) return position;
        }
        return 0;
    }
};

fn appendHeaderTitle(alloc: Allocator, row: *std.ArrayList(u8), count: usize) !void {
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    var buf: [48]u8 = undefined;
    const title = std.mem.print(&buf, "Models {d}", .{count}) catch "Models";
    try row.appendSlice(alloc, title);
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn appendProviderTab(alloc: Allocator, row: *std.ArrayList(u8), label: []const u8, active: bool) !void {
    try row.appendSlice(alloc, if (active) ui_render.selected_completion_style else ui_render.dim_style);
    if (active) try row.append(alloc, '[');
    try row.appendSlice(alloc, label);
    if (active) try row.append(alloc, ']');
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn appendProviderTabAt(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    index: usize,
    active_index: usize,
) !void {
    try appendProviderTab(alloc, row, providerTabLabel(index), index == active_index);
}

fn appendProviderOverflowMarker(alloc: Allocator, row: *std.ArrayList(u8)) !void {
    try row.appendSlice(alloc, ui_render.dim_style);
    try row.appendSlice(alloc, "…");
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn providerTabLabel(index: usize) []const u8 {
    const filter: model_cache_runtime.ModelProviderFilter = @fromBackingInt(@intCast(index));
    return switch (filter) {
        .all => "All",
        .anthropic => "Anthropic",
        .openai => "OpenAI",
        .xai => "xAI",
        .zai => "Z.AI",
        .others => "Others",
    };
}

fn providerTabWidth(index: usize, active_index: usize) usize {
    const active_padding: usize = if (index == active_index) 2 else 0;
    return display_width.visibleWidth(providerTabLabel(index)) + active_padding;
}

fn providerRangeWidth(
    tabs: ProviderTabs,
    start: usize,
    end: usize,
    active_index: usize,
) usize {
    var width: usize = if (start > 0) 3 else 0;
    for (start..end) |position| {
        if (position > start) width += 2;
        width += providerTabWidth(tabs.indices[position], active_index);
    }
    if (end < tabs.len) width += 3;
    return width;
}

/// The spaces between a model's id and its first fact, and between facts.
const fact_gap: usize = 3;
/// A model id keeps at least this many cells before facts take the rest.
const min_id_width: usize = 20;
/// The widest a connection's name gets beside its models.
const max_connection_width: usize = 24;

/// The facts beside each model, in columns that line up down the list: the
/// connection that serves it while the menu lists more than one, the
/// context window, the output limit, and the speed options. The widths come
/// from every model in the open tab, so the columns stay put while the user
/// scrolls or types a search. A row that is too narrow drops whole columns
/// from the right.
const FactColumns = struct {
    /// The cell where the first column starts.
    start: usize = 0,
    connection: usize = 0,
    context_digits: usize = 0,
    output_digits: usize = 0,
    speed: usize = 0,

    const context_label = " context";
    const output_label = " output";

    fn build(projection: ModelMenuProjection, row_width: u16) ?FactColumns {
        const indent: usize = if (row_width <= 2) 0 else 2;
        const filter = projection.providerFilter();
        var columns: FactColumns = .{};
        var longest_id: usize = 8;
        for (projection.items) |item| {
            if (!model_cache_runtime.modelProviderFilterKeeps(item, filter)) continue;
            longest_id = @max(longest_id, display_width.visibleWidth(item.label()));
            if (item.connection_label) |label| columns.connection = @min(max_connection_width, @max(columns.connection, display_width.visibleWidth(label)));
            var buf: [32]u8 = undefined;
            if (item.capabilities.context_window) |tokens| {
                const text: []const u8 = formatTokenCount(&buf, tokens) catch "";
                columns.context_digits = @max(columns.context_digits, text.len);
            }
            if (item.capabilities.max_output_tokens) |tokens| {
                const text: []const u8 = formatTokenCount(&buf, tokens) catch "";
                columns.output_digits = @max(columns.output_digits, text.len);
            }
            columns.speed = @max(columns.speed, speedFacts(&buf, item.capabilities).len);
        }

        const id_floor = @min(longest_id, min_id_width);
        while (columns.width() > 0 and indent + id_floor + fact_gap + columns.width() > row_width) columns.dropLast();
        if (columns.width() == 0) return null;
        columns.start = @min(indent + longest_id + fact_gap, @as(usize, row_width) - columns.width());
        return columns;
    }

    fn width(self: FactColumns) usize {
        var total: usize = 0;
        var count: usize = 0;
        if (self.connection > 0) {
            total += self.connection;
            count += 1;
        }
        if (self.context_digits > 0) {
            total += self.context_digits + context_label.len;
            count += 1;
        }
        if (self.output_digits > 0) {
            total += self.output_digits + output_label.len;
            count += 1;
        }
        if (self.speed > 0) {
            total += self.speed;
            count += 1;
        }
        return total + fact_gap * (count -| 1);
    }

    fn dropLast(self: *FactColumns) void {
        if (self.speed > 0) {
            self.speed = 0;
        } else if (self.output_digits > 0) {
            self.output_digits = 0;
        } else if (self.context_digits > 0) {
            self.context_digits = 0;
        } else if (self.connection > 0) {
            self.connection = 0;
        }
    }

    /// Writes `item`'s cells, each padded to its column. Spaces are written
    /// only before a fact, so a row never ends in padding.
    fn appendCells(self: FactColumns, alloc: Allocator, out: *std.ArrayList(u8), item: model_cache_runtime.ModelMenuItem) !void {
        var cells: CellWriter = .{ .alloc = alloc, .out = out };
        var buf: [32]u8 = undefined;
        if (self.connection > 0) {
            var label: std.ArrayList(u8) = .empty;
            defer label.deinit(alloc);
            if (item.connection_label) |text| try row_text.appendSingleLineEllipsized(alloc, &label, text, self.connection);
            try cells.cell(label.items, self.connection);
        }
        if (self.context_digits > 0) {
            try cells.cell(try tokenCell(&buf, item.capabilities.context_window, self.context_digits, context_label), self.context_digits + context_label.len);
        }
        if (self.output_digits > 0) {
            try cells.cell(try tokenCell(&buf, item.capabilities.max_output_tokens, self.output_digits, output_label), self.output_digits + output_label.len);
        }
        if (self.speed > 0) try cells.cell(speedFacts(&buf, item.capabilities), self.speed);
    }
};

const CellWriter = struct {
    alloc: Allocator,
    out: *std.ArrayList(u8),
    /// Spaces owed before the next fact: gaps and the padding of cells so far.
    pending: usize = 0,
    started: bool = false,

    fn cell(self: *CellWriter, text: []const u8, cell_width: usize) !void {
        if (self.started) self.pending += fact_gap;
        self.started = true;
        if (text.len > 0) {
            try self.out.appendNTimes(self.alloc, ' ', self.pending);
            try self.out.appendSlice(self.alloc, text);
            self.pending = 0;
        }
        self.pending += cell_width -| display_width.visibleWidth(text);
    }
};

/// A token count right-aligned in `digits` cells and followed by `label`,
/// or nothing when the catalog does not say.
fn tokenCell(buf: *[32]u8, tokens: ?u32, digits: usize, label: []const u8) ![]const u8 {
    const count = tokens orelse return "";
    var count_buf: [16]u8 = undefined;
    const text = try formatTokenCount(&count_buf, count);
    const pad = digits -| text.len;
    @memset(buf[0..pad], ' ');
    @memcpy(buf[pad..][0..text.len], text);
    @memcpy(buf[pad + text.len ..][0..label.len], label);
    return buf[0 .. pad + text.len + label.len];
}

/// The speed options a model has, as one cell: `Fast` for a model that
/// always runs fast, and `Fast mode` or `Ultrafast mode` for options it offers.
fn speedFacts(buf: *[32]u8, capabilities: model_capabilities.Capabilities) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    const facts = [_]struct { on: bool, text: []const u8 }{
        .{ .on = capabilities.intrinsic_fast, .text = fast_fact },
        .{ .on = capabilities.supports_fast_mode, .text = fast_mode_fact },
        .{ .on = capabilities.supports_ultrafast_mode, .text = ultrafast_mode_fact },
    };
    var any = false;
    for (facts) |fact| {
        if (!fact.on) continue;
        if (any) writer.writeAll(", ") catch break;
        writer.writeAll(fact.text) catch break;
        any = true;
    }
    return writer.buffered();
}

/// Writes a token count the way model providers write it. A size that is a
/// multiple of 1,024 counts 1,024 per K, so 131072 reads 128K and 1048576
/// reads 1M; other sizes count 1,000 per K, so 128000 reads 128K and 1050000
/// reads 1.05M. Thousands round to a whole number, millions to two places.
fn formatTokenCount(buf: []u8, tokens: u32) ![]const u8 {
    if (tokens < 1000) return std.mem.print(buf, "{d}", .{tokens});
    const unit: u64 = if (tokens % 1024 == 0 and tokens % 1000 != 0) 1024 else 1000;
    const thousands = (@as(u64, tokens) + unit / 2) / unit;
    if (thousands < 1000) return std.mem.print(buf, "{d}K", .{thousands});
    const hundredths = (@as(u64, tokens) * 100 + unit * unit / 2) / (unit * unit);
    const whole = hundredths / 100;
    const fraction = hundredths % 100;
    if (fraction == 0) return std.mem.print(buf, "{d}M", .{whole});
    if (fraction % 10 == 0) return std.mem.print(buf, "{d}.{d}M", .{ whole, fraction / 10 });
    return std.mem.print(buf, "{d}.{d:0>2}M", .{ whole, fraction });
}

fn composeTitleRow(
    alloc: Allocator,
    item: model_cache_runtime.ModelMenuItem,
    selected: bool,
    columns: ?FactColumns,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const indent_width: usize = if (width <= 2) 0 else 2;
    if (indent_width > 0) try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);

    var cells: std.ArrayList(u8) = .empty;
    defer cells.deinit(alloc);
    if (columns) |c| try c.appendCells(alloc, &cells, item);

    const id_budget = if (columns) |c| c.start - indent_width - fact_gap else @as(usize, width) -| indent_width;
    try row_text.appendSingleLineMiddleEllipsized(alloc, &row, item.label(), id_budget);
    if (selected) try row.appendSlice(alloc, ui_render.reset_style);

    if (cells.items.len > 0) {
        try row_text.appendSpacesToColumn(alloc, &row, columns.?.start);
        try row.appendSlice(alloc, ui_render.dim_style);
        try row.appendSlice(alloc, cells.items);
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    return row;
}

// A `-fast` model always runs fast, so it reads "Fast". "Fast mode" and "Ultrafast mode"
// name speed options the model offers, so they are not mistaken for a fast model.
const fast_fact = "Fast";
const fast_mode_fact = "Fast mode";
const ultrafast_mode_fact = "Ultrafast mode";

fn composeStateRow(alloc: Allocator, projection: ModelMenuProjection, width: u16) !std.ArrayList(u8) {
    const text = switch (projection.load_state) {
        .loading => "Loading models…",
        .failed => retryableFailureText(projection.catalog_state.failure) orelse "Unable to load models.",
        .ready => if (projection.items.len == 0) "No models available." else "No models found.",
    };
    return composeDimmedRow(alloc, text, width);
}

fn loadedCatalogStatusText(state: model_cache_runtime.ModelMenuCatalogState) ?[]const u8 {
    if (retryableFailureText(state.failure)) |text| return text;
    if (state.from_profile_settings) return "Models from settings and, with fetch_models, the server; explicit model IDs need no catalog.";
    if (state.source) |source| {
        if (source == .host_managed) return "Provider catalog: authentication is managed by the host.";
    }
    return null;
}

fn retryableFailureText(failure: ?model_cache_runtime.ModelMenuCatalogState.Failure) ?[]const u8 {
    const value = failure orelse return null;
    if (!value.retryable) return null;
    return switch (value.category) {
        .rate_limited => "The model server rate limited model discovery; spark retries automatically.",
        .transport, .gateway_unavailable => "Could not reach the model server; spark retries automatically.",
        else => "Could not refresh model catalog; spark retries automatically.",
    };
}

fn composeDimmedRow(alloc: Allocator, text: []const u8, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, text, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn cloneClippedRow(alloc: Allocator, text: []const u8, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row_text.appendClipped(alloc, &row, text, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

test "model menu renders provider tabs and compact model facts" {
    const alloc = std.testing.allocator;
    const items = [_]model_cache_runtime.ModelMenuItem{
        .{
            .id = @constCast("anthropic/claude-opus-4.8"),
            .provider = "anthropic",
            .capabilities = .{
                .supports_reasoning = true,
                .supports_tool_use = true,
                .supports_vision = true,
                .supports_file_input = true,
                .supports_web_search = true,
                .supports_fast_mode = true,
                .supports_ultrafast_mode = true,
                .context_window = 1_000_000,
                .max_output_tokens = 128_000,
            },
        },
        .{
            .id = @constCast("openai/gpt-5"),
            .provider = "openai",
            .capabilities = .{},
        },
    };
    const projection: ModelMenuProjection = .{
        .active = true,
        .load_state = .ready,
        .items = &items,
    };
    const rows = menuRowCount(projection, 120, 20);
    try std.testing.expectEqual(@as(u16, 4), rows);

    var header = try composeModelMenuRow(alloc, projection, 0, 120, rows);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, header.items, "Models 2") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "[All]") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "Anthropic") != null);

    var title = try composeModelMenuRow(alloc, projection, 2, 120, rows);
    defer title.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, title.items, "anthropic/claude-opus-4.8") != null);
    try std.testing.expect(std.mem.find(u8, title.items, "●") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "○") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "1M context   128K output   Fast mode, Ultrafast mode") != null);
    try std.testing.expect(std.mem.find(u8, title.items, "Anthropic") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Current") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Reasoning") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Vision") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Tools") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Files") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Web") == null);
}

/// Draws every row of the menu into a VT grid of `width` columns, as the
/// terminal would show it.
fn renderMenuGrid(alloc: Allocator, projection: ModelMenuProjection, width: u16, max_rows: u16) !vt_emulator.Grid {
    const rows = menuRowCount(projection, width, max_rows);
    var grid = try vt_emulator.Grid.init(alloc, width, @max(rows, 1));
    errdefer grid.deinit();
    var row_index: u16 = 0;
    while (row_index < rows) : (row_index += 1) {
        var row = try composeModelMenuRow(alloc, projection, row_index, width, rows);
        defer row.deinit(alloc);
        var cursor_buf: [32]u8 = undefined;
        try grid.feed(try std.mem.print(&cursor_buf, "\x1b[{d};1H", .{row_index + 1}));
        try grid.feed(row.items);
    }
    return grid;
}

/// The cell where `needle` starts on grid row `row`, or null.
fn gridColumnOf(alloc: Allocator, grid: *vt_emulator.Grid, row: u16, needle: []const u8) !?usize {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    try grid.rowTextTrimmed(row, &text);
    const at = std.mem.find(u8, text.items, needle) orelse return null;
    return display_width.visibleWidth(text.items[0..at]);
}

const column_test_items = [_]model_cache_runtime.ModelMenuItem{
    .{ .id = @constCast("moonshotai/kimi-k3"), .provider = "moonshotai", .capabilities = .{ .context_window = 1_000_000, .max_output_tokens = 131_072, .supports_fast_mode = true } },
    .{ .id = @constCast("zai/glm-5.3-flash"), .provider = "zai", .capabilities = .{ .context_window = 1_000_000, .max_output_tokens = 131_000 } },
    .{ .id = @constCast("openai/gpt-6.1-terra"), .provider = "openai", .capabilities = .{ .context_window = 1_050_000, .max_output_tokens = 128_000, .supports_fast_mode = true } },
    .{ .id = @constCast("amazon/nova-pro"), .provider = "amazon", .capabilities = .{ .context_window = 300_000, .max_output_tokens = 8_192 } },
    .{ .id = @constCast("anthropic/claude-opus-5.5-fast"), .provider = "anthropic", .capabilities = .{ .context_window = 1_000_000, .max_output_tokens = 128_000, .intrinsic_fast = true } },
};
