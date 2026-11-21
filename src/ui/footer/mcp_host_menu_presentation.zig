//! Draws the `/mcp` menu as spark's picker: a
//! titled list, a server's facts, choices, and tools, and spark's hint line.
//! The logic is `core/mcp_host/menu.zig`; this only turns it into rows.

const std = @import("std");
const profile_paths = @import("../../core/shared/profile_paths.zig");
const display_width = @import("../../core/shared/display_width.zig");
const menu = @import("../../core/mcp_host/menu.zig");
const verbs = @import("../../core/mcp_host/verbs.zig");
const row_text = @import("row_text.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const Row = std.ArrayList(u8);

pub const max_inline_rows: u16 = menu.server_window + 1;
/// Where a server's facts start: after `http`, `runs`, `file`, `status`,
/// `protocol`, `error`.
const fact_col: usize = 12;

pub const Projection = struct {
    state: menu.State = .{},
    /// Every server, in config order.
    rows: []const menu.Row = &.{},
    /// What's typed in the composer, which filters the list, or the open
    /// server's tools on its screen.
    filter: []const u8 = "",
    tools: menu.Tools = .loading,
    /// What loading the config had to say, which `/mcp list` shows.
    notes: usize = 0,
    /// While the open server's sign-in waits for the browser, its address.
    sign_in_url: ?[]const u8 = null,
    /// The project config file, as shown. The profile file is named by
    /// `profile_paths.displayText`.
    project_file: []const u8 = ".mcp.json",
    /// The add form's fields so far.
    add_name: []const u8 = "",
    add_target: []const u8 = "",
    add_pairs: []const []const u8 = &.{},
    add_problem: ?[]const u8 = null,
    /// The field being typed and its cursor, the form's own, not the composer's.
    add_input: []const u8 = "",
    add_cursor: usize = 0,

    pub fn active(p: Projection) bool {
        return p.state.active;
    }

    /// The open server, found by name among all servers.
    pub fn openRow(p: Projection) ?menu.Row {
        return menu.viewOf(&p.state, p.rows, "", p.tools, &.{}).open;
    }

    pub fn layout(p: Projection, r: menu.Row) menu.Layout {
        return menu.serverLayout(r, p.tools, p.filter, menu.server_window);
    }

    /// The server's screen at `width`: its layout with the waiting address.
    fn screenLayout(p: Projection, r: menu.Row, width: u16) menu.Layout {
        var l = p.layout(r);
        l.waiting = p.waitingLines(r, width);
        return l;
    }

    /// The sign-in address while the open server waits for the browser; null
    /// once its tools load.
    fn waitingAddress(p: Projection, r: menu.Row) ?[]const u8 {
        const url = p.sign_in_url orelse return null;
        if (url.len == 0 or menu.toolsFor(r, p.tools) == .ready) return null;
        return url;
    }

    /// The address's own lines below the heading: none when the heading
    /// links it, else the whole address, wrapped.
    fn waitingLines(p: Projection, r: menu.Row, width: u16) usize {
        const url = p.waitingAddress(r) orelse return 0;
        if (headingLinks(url, width)) return 0;
        const w = addressWidth(width);
        return (url.len + w - 1) / w;
    }

    fn fileOf(p: Projection, r: menu.Row) []const u8 {
        return if (r.status.source == .workspace) p.project_file else profile_paths.displayText("~/.spark/mcp.json");
    }
};

/// The rows the panel needs, at most `budget`.
pub fn menuRowCount(p: Projection, width: u16, budget: u16) u16 {
    if (!p.active() or budget == 0) return 0;
    var confirm: Confirm = undefined;
    const wanted: usize = switch (p.state.screen) {
        .list => blk: {
            var buf: [256]menu.Row = undefined;
            const shown = @max(listLines(menu.viewOf(&p.state, p.rows, p.filter, p.tools, &buf)), 1);
            // The servers, then the "Add server" row.
            break :blk 1 + (if (p.rows.len == 0) 0 else shown) + 1 + @as(usize, @intFromBool(p.notes > 0));
        },
        .add => add_rows,
        .server => if (p.openRow()) |r| serverRows(p, r, width) else 1,
        .confirm => if (p.openRow()) |r| (if (asksInPlace(p))
            serverRows(p, r, width)
        else
            1 + confirmLines(p, r, width, &confirm).len) else 1,
    };
    return @intCast(@min(wanted, budget));
}

/// A server's screen: its title and lines, the panel's height, made taller
/// so a waiting sign-in's address is never cut off.
fn serverRows(p: Projection, r: menu.Row, width: u16) usize {
    const l = p.screenLayout(r, width);
    return 1 + @min(l.lines(), menu.server_window + l.waiting);
}

fn addressWidth(width: u16) usize {
    return @max(@as(usize, width) -| 4, 16);
}

/// The indent, the transcript's label, and its period.
const sign_in_link_width = 2 + menu.sign_in_link_label.len + 1;

/// Whether the heading links the address in one line, as the transcript
/// does: it can be a link target and the label fits. Otherwise the address
/// is shown whole below it.
fn headingLinks(url: []const u8, width: u16) bool {
    return text_utils.isLinkTarget(url) and width >= sign_in_link_width;
}

/// The waiting sign-in's one line, its label linking the whole address so a
/// long one never fills the screen. Narrow screens drop the lead first; the
/// bare label always fits, as `headingLinks` checked.
fn signInLinkRow(alloc: Allocator, url: []const u8, width: u16) !Row {
    const leads = [_][]const u8{ "Waiting for the browser. Didn't open? ", "Didn't open? ", "" };
    const lead = for (leads) |candidate| {
        if (sign_in_link_width + candidate.len <= width) break candidate;
    } else "";
    var row: Row = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, ui_render.dim_style);
    try row.appendSlice(alloc, lead);
    try row.appendSlice(alloc, ui_render.reset_style);
    try row.appendSlice(alloc, "\x1b]8;id=spark-mcp-sign-in;");
    try row.appendSlice(alloc, url);
    try row.appendSlice(alloc, "\x1b\\\x1b[4m" ++ menu.sign_in_link_label ++ "\x1b[24m\x1b]8;;\x1b\\");
    try row.appendSlice(alloc, ui_render.dim_style);
    try row.appendSlice(alloc, ".");
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

/// The list's lines below its title: a line per server, and before the
/// servers that need attention their heading, set apart by a blank line
/// when servers that work come first.
fn listLines(v: menu.View) usize {
    return v.rows.len + headingLines(v);
}

fn headingLines(v: menu.View) usize {
    const start = v.attention_start orelse return 0;
    return if (start > 0) 2 else 1;
}

/// The list line the `i`th row of `v` is on, after the heading.
fn lineOfRow(v: menu.View, i: usize) usize {
    const start = v.attention_start orelse return i;
    return if (i >= start) i + headingLines(v) else i;
}

pub fn composeRow(alloc: Allocator, p: Projection, index: u16, width: u16, row_count: u16) !Row {
    if (width == 0 or index >= row_count or !p.active()) return .empty;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    return switch (p.state.screen) {
        .list => listRow(alloc, arena, p, index, width, row_count),
        .server => serverRow(alloc, arena, p, index, width, row_count),
        .confirm => if (asksInPlace(p)) serverRow(alloc, arena, p, index, width, row_count) else confirmRow(alloc, arena, p, index, width),
        .add => addRow(alloc, arena, p, index, width),
    };
}

/// The add form: its title, one row per field, a blank or the problem with
/// the last typed value, and what to do on the current step.
const add_rows: usize = 9;

fn addRow(alloc: Allocator, arena: Allocator, p: Projection, index: u16, width: u16) !Row {
    const s = p.state;
    const step = s.add_step;
    const http = s.add_http;
    if (index == 0) return title(alloc, if (s.add_editing) "Edit MCP server" else "Add MCP server", try arena.print("step {d} of 6", .{@backingInt(step) + 1}), width);
    const Field = struct { at: menu.AddStep, label: []const u8, value: []const u8 };
    const pairs_text = if (p.add_pairs.len == 0) "none" else blk: {
        var keys: std.ArrayList(u8) = .empty;
        for (p.add_pairs, 0..) |pair, k| {
            if (k > 0) try keys.appendSlice(arena, ", ");
            try keys.appendSlice(arena, pair[0 .. std.mem.findScalar(u8, pair, '=') orelse pair.len]);
        }
        break :blk keys.items;
    };
    const fields = [_]Field{
        .{ .at = .name, .label = "Name", .value = p.add_name },
        .{ .at = .kind, .label = "Type", .value = if (http) "[HTTP]   Local command " else " HTTP   [Local command]" },
        .{ .at = .target, .label = if (http) "URL" else "Command", .value = p.add_target },
        .{ .at = .pairs, .label = if (http) "Headers" else "Env vars", .value = pairs_text },
        .{ .at = .scope, .label = "Save to", .value = if (s.add_project) " Global   [This project]" else "[Global]   This project " },
        .{ .at = .review, .label = "Sign in", .value = if (!http) "not needed" else if (s.add_login) "[Yes]   No " else " Yes   [No]" },
    };
    if (index <= fields.len) {
        const f = fields[index - 1];
        const current = f.at == step;
        const done = @backingInt(f.at) < @backingInt(step);
        const shown = if (done or !f.at.typed() or f.at == .pairs) f.value else "";
        var row: Row = .empty;
        errdefer row.deinit(alloc);
        try row.appendSlice(alloc, if (current) ui_render.selected_completion_style else ui_render.dim_style);
        try row.appendSlice(alloc, if (current) "› " else "  ");
        try row.appendSlice(alloc, f.label);
        try row_text.appendSpacesToColumn(alloc, &row, 2 + fact_col);
        // A choice's text is spark's own and keeps its spacing; typed values
        // are drawn terminal safe.
        if (current and f.at.typed()) {
            // The field shows what's being typed, with a cursor, as /provider does.
            const room = @as(usize, width) -| (3 + fact_col);
            try row.appendSlice(alloc, ui_render.reset_style);
            if (f.at == .pairs and p.add_pairs.len > 0) {
                try row_text.appendTerminalSafeSingleLine(alloc, &row, shown, room / 2);
                try row.appendSlice(alloc, "  + ");
            }
            const typed = p.add_input;
            const cursor = @min(p.add_cursor, typed.len);
            // Scroll so the cursor stays in view.
            var start: usize = if (cursor + 1 > room) cursor + 1 - room else 0;
            while (start < typed.len and typed[start] & 0xC0 == 0x80) start += 1;
            try row_text.appendTerminalSafeSingleLine(alloc, &row, typed[start..cursor], room);
            var after = cursor;
            if (after < typed.len) {
                after += 1;
                while (after < typed.len and typed[after] & 0xC0 == 0x80) after += 1;
                try row.appendSlice(alloc, "\x1b[7m");
                try row_text.appendTerminalSafeSingleLine(alloc, &row, typed[cursor..after], 1);
                try row.appendSlice(alloc, "\x1b[27m");
                const end = @min(typed.len, start + room);
                if (after < end) try row_text.appendTerminalSafeSingleLine(alloc, &row, typed[after..end], room);
            } else {
                try row.appendSlice(alloc, "\x1b[7m \x1b[27m");
            }
            if (typed.len == 0) {
                try row.appendSlice(alloc, ui_render.dim_style);
                try row.appendSlice(alloc, switch (f.at) {
                    .name => " e.g. github",
                    .target => if (http) " e.g. https://example.com/mcp" else " e.g. npx -y @scope/server",
                    else => if (http) " Authorization: Bearer …, or Enter to continue" else " KEY=VALUE, or Enter to continue",
                });
            }
        } else if (f.at.typed()) {
            try row_text.appendTerminalSafeSingleLine(alloc, &row, shown, @as(usize, width) -| (2 + fact_col));
        } else {
            try row.appendSlice(alloc, shown);
        }
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }
    if (index == fields.len + 1) {
        if (p.add_problem) |problem| return row_text.composeTextRow(alloc, problem, width, ui_render.hint_style, 4);
        return .empty;
    }
    const help: []const u8 = switch (step) {
        .name => "Type a name (letters, digits, - and _) and press Enter.",
        .kind => "←→ choose HTTP or a local command, Enter to continue.",
        .target => if (http) "Type the server's URL and press Enter." else "Type the command and its arguments, then Enter.",
        .pairs => if (s.add_editing)
            "Name: value adds or changes one, -Name removes one; Enter on an empty line continues."
        else if (http)
            "Type a header like Authorization: Bearer <token> and Enter; Enter on an empty line continues."
        else
            "Type a variable as KEY=VALUE and Enter; Enter on an empty line continues.",
        .scope => "←→ choose where to save it, Enter to continue.",
        .review => if (http) "←→ sign in after saving or not, Enter saves the server." else "Enter saves the server.",
    };
    return row_text.composeTextRow(alloc, help, width, ui_render.hint_style, 4);
}

fn title(alloc: Allocator, name: []const u8, meta: []const u8, width: u16) !Row {
    var row: Row = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, ui_render.subtitle_style);
    try row_text.appendTerminalSafeSingleLine(alloc, &row, name, @as(usize, width) / 2);
    try row.appendSlice(alloc, ui_render.reset_style);
    try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendTerminalSafeSingleLine(alloc, &row, meta, @as(usize, width) -| display_width.visibleWidthIgnoringAnsi(row.items));
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn listRow(alloc: Allocator, arena: Allocator, p: Projection, index: u16, width: u16, row_count: u16) !Row {
    var buf: [256]menu.Row = undefined;
    const view = menu.viewOf(&p.state, p.rows, p.filter, p.tools, &buf);
    const rows = view.rows;
    if (index == 0) {
        const meta = if (p.rows.len == 0)
            "none yet"
        else if (p.filter.len > 0)
            try arena.print("{d} of {d}", .{ rows.len, p.rows.len })
        else
            try arena.print("{d}", .{p.rows.len});
        return title(alloc, "MCP servers", meta, width);
    }
    const has_note = p.notes > 0;
    if (has_note and index == row_count - 1) {
        const note = try arena.print("{d} config note{s}: /mcp list shows {s}", .{ p.notes, if (p.notes == 1) "" else "s", if (p.notes == 1) "it" else "them" });
        return row_text.composeTextRow(alloc, note, width, ui_render.dim_style, 2);
    }
    const body = row_count - 2 - @as(u16, @intFromBool(has_note));
    if (index == body + 1 or p.rows.len == 0) {
        const on_add = p.state.on_add or p.rows.len == 0;
        return row_text.composeTextRow(alloc, if (on_add) "› + Add server" else "  + Add server", width, if (on_add) ui_render.selected_completion_style else ui_render.dim_style, 2);
    }
    if (rows.len == 0) {
        const none = try arena.print("No server matches \"{s}\"", .{p.filter});
        return row_text.composeTextRow(alloc, none, width, ui_render.dim_style, 2);
    }
    const selected = if (p.state.on_add) rows.len else p.state.selectedIndex(rows) orelse 0;
    // The window keeps the selection in view.
    const selected_line = lineOfRow(view, @min(selected, rows.len - 1));
    const start = if (selected_line < body) 0 else selected_line + 1 - body;
    const line = start + (index - 1);
    if (line >= listLines(view)) return .empty;
    if (view.attention_start) |first| {
        const heading = headingLines(view);
        if (line >= first and line < first + heading) {
            if (line + 1 < first + heading) return .empty;
            return title(alloc, "Needs attention", try arena.print("{d}", .{rows.len - first}), width);
        }
        const i = if (line > first) line - heading else line;
        return serverListRow(alloc, arena, rows[i], i == selected, width);
    }
    return serverListRow(alloc, arena, rows[line], line == selected, width);
}

fn serverListRow(alloc: Allocator, arena: Allocator, r: menu.Row, selected: bool, width: u16) !Row {
    const show_source = width >= 64;
    const name_width: usize = std.math.clamp(@as(usize, width) / 4, 12, 22);
    const status_col = 2 + name_width + 2;
    const source_col = status_col + 22 + 2;
    var row: Row = .empty;
    errdefer row.deinit(alloc);
    // Like spark's other pickers: dim rows, the selected one bright.
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row.appendSlice(alloc, if (selected) "› " else "  ");
    try row_text.appendTerminalSafeSingleLine(alloc, &row, r.status.name, name_width);
    try row.appendSlice(alloc, ui_render.reset_style);
    try row_text.appendSpacesToColumn(alloc, &row, status_col);
    const needs_you = r.status.needs_login or switch (r.status.state) {
        .failed, .retrying, .waiting_for_approval, .missing_env, .invalid_env => true,
        else => false,
    };
    // What needs the user stays bright so it stands out among dim rows.
    try row.appendSlice(alloc, if (needs_you) ui_render.hint_style else ui_render.dim_style);
    const status_width = if (show_source) 22 else @as(usize, width) -| status_col;
    try row_text.appendTerminalSafeSingleLine(alloc, &row, try verbs.statusText(arena, runState(r.status)), status_width);
    try row.appendSlice(alloc, ui_render.reset_style);
    if (show_source) {
        try row_text.appendSpacesToColumn(alloc, &row, source_col);
        try row.appendSlice(alloc, ui_render.dim_style);
        try row.appendSlice(alloc, if (r.status.source == .workspace) "project" else "profile");
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    return row;
}

/// The status without its saved login: the menu says how a server runs, and
/// its screen puts the login beside that.
fn runState(s: anytype) @TypeOf(s) {
    var out = s;
    out.signed_in = false;
    return out;
}

/// The status fact on a server's screen. Its tool count is beside its
/// tools' heading and its login is in its choices, so neither repeats here.
fn statusFact(arena: Allocator, s: menu.Row) ![]const u8 {
    if (s.status.state == .ready and !s.status.needs_login) return "ready";
    return verbs.statusText(arena, runState(s.status));
}

/// Line `line` of a server's screen below its title.
fn serverLine(alloc: Allocator, arena: Allocator, p: Projection, r: menu.Row, l: menu.Layout, line: usize, width: u16) !Row {
    if (line < l.lead) {
        const facts = l.lead - 1;
        if (line >= facts) return .empty;
        const protocol_lines: usize = @intFromBool(r.status.version != null);
        if (line == 0) return row_text.composeFactRow(alloc, if (r.status.transport == .stdio) "runs" else @tagName(r.status.transport), r.target orelse "", width, fact_col, "");
        if (line == 1) return row_text.composeFactRow(alloc, "file", p.fileOf(r), width, fact_col, "");
        if (line == 2) return row_text.composeFactRow(alloc, "status", try statusFact(arena, r), width, fact_col, "");
        if (line == 3 and protocol_lines == 1) return row_text.composeFactRow(alloc, "protocol", r.status.version.?, width, fact_col, "");
        return row_text.composeFactRow(alloc, "error", r.status.last_error orelse "", width, fact_col, ui_render.hint_style);
    }
    var buf: [menu.max_choices]menu.Choice = undefined;
    const cs = menu.choices(r, &buf);
    const at = line - l.lead;
    if (at < cs.len) {
        const selected = p.state.cursor == at;
        var row: Row = .empty;
        errdefer row.deinit(alloc);
        try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else "");
        try row.appendSlice(alloc, if (selected) "› " else "  ");
        // Remove and Reject ask on their own row, answers included: the
        // chosen one is bright, and ← → move between them.
        if (asksInPlace(p) and p.state.confirm.? == cs[at]) {
            const answers = "   yes  no";
            const no = p.state.answer_no;
            try row_text.appendTerminalSafeSingleLine(alloc, &row, try question(arena, p, r, cs[at]), @as(usize, width) -| 2 -| answers.len);
            try row.appendSlice(alloc, ui_render.reset_style);
            try row.appendSlice(alloc, "   ");
            try row.appendSlice(alloc, if (no) ui_render.dim_style else ui_render.selected_completion_style);
            try row.appendSlice(alloc, "yes");
            try row.appendSlice(alloc, ui_render.reset_style);
            try row.appendSlice(alloc, "  ");
            try row.appendSlice(alloc, if (no) ui_render.selected_completion_style else ui_render.dim_style);
            try row.appendSlice(alloc, "no");
            try row.appendSlice(alloc, ui_render.reset_style);
            return row;
        }
        try row.appendSlice(alloc, cs[at].label());
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }
    const after = at - cs.len;
    if (after == 0) return .empty;
    if (after == 1) {
        if (p.waitingAddress(r)) |url| {
            if (headingLinks(url, width)) return signInLinkRow(alloc, url, width);
            return row_text.composeTextRow(alloc, "Waiting for the browser. Didn't open? Go to:", width, ui_render.dim_style, 2);
        }
    }
    if (after >= 2 and after < 2 + l.waiting) {
        // Where the heading can't link it: the whole address, wrapped, never cut.
        const url = p.sign_in_url orelse return .empty;
        const w = addressWidth(width);
        const from = @min((after - 2) * w, url.len);
        var row: Row = .empty;
        errdefer row.deinit(alloc);
        try row.appendSlice(alloc, "    ");
        // One link on every row of it, so a click on any opens the whole
        // address; one that can't be a link target is shown unlinked.
        const linked = text_utils.isLinkTarget(url);
        if (linked) {
            try row.appendSlice(alloc, "\x1b]8;id=spark-mcp-sign-in;");
            try row.appendSlice(alloc, url);
            try row.appendSlice(alloc, "\x1b\\\x1b[4m");
        }
        try row_text.appendTerminalSafeSingleLine(alloc, &row, url[from..@min(from + w, url.len)], w);
        if (linked) try row.appendSlice(alloc, "\x1b[24m\x1b]8;;\x1b\\");
        return row;
    }
    // From Log in until the address comes, the requests before it can take seconds.
    if (after == 1 and r.status.signing_in and menu.toolsFor(r, p.tools) != .ready)
        return row_text.composeTextRow(alloc, "Signing in…", width, ui_render.dim_style, 2);
    if (after == 1) {
        const heading: []const u8 = switch (menu.toolsFor(r, p.tools)) {
            .loading => "Loading tools…",
            .needs_login => "Its tools show here once you log in.",
            .needs_approval => "Its tools show here once you approve it.",
            .failed => |reason| try arena.print("Its tools couldn't load: {s}", .{reason}),
            .ready => |t| if (t.len == 0)
                "It has no tools."
            else if (p.filter.len == 0)
                try arena.print("Tools {d}", .{t.len})
            else if (l.tools == 0)
                "No tools match."
            else
                try arena.print("Tools {d} of {d}", .{ l.tools, t.len }),
        };
        return row_text.composeTextRow(alloc, heading, width, ui_render.dim_style, 2);
    }
    const tools = switch (p.tools) {
        .ready => |t| t,
        else => return .empty,
    };
    const ti = after - 2 - l.waiting;
    const tool = menu.nthTool(tools, p.filter, ti) orelse return .empty;
    const selected = p.state.cursor == cs.len + ti;
    var row: Row = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else "");
    try row.appendSlice(alloc, if (selected) "› " else "  ");
    try row_text.appendTerminalSafeSingleLine(alloc, &row, tool.name, 20);
    try row.appendSlice(alloc, ui_render.reset_style);
    try row_text.appendSpacesToColumn(alloc, &row, 24);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendTerminalSafeSingleLine(alloc, &row, tool.description, @as(usize, width) -| 24);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn serverRow(alloc: Allocator, arena: Allocator, shown: Projection, index: u16, width: u16, row_count: u16) !Row {
    const r = shown.openRow() orelse return .empty;
    if (index == 0) return title(alloc, r.status.name, "", width);
    const l = shown.screenLayout(r, width);
    // A filter typed since the last key can leave fewer items than the
    // selection's place; draw it on the last one left.
    var p = shown;
    p.state.cursor = @min(p.state.cursor, l.selectable() -| 1);
    const window: usize = row_count - 1;
    if (l.lines() <= window) return serverLine(alloc, arena, p, r, l, index - 1, width);
    const v = scrolled(p.state, l, window);
    const slot: usize = index - 1;
    if (slot < v.lines) return serverLine(alloc, arena, p, r, l, v.top + slot, width);
    if (slot == v.lines and v.below > 0) return countRow(alloc, arena, v.below, "more below", width);
    return .empty;
}

const Scrolled = struct { top: usize, lines: usize, below: usize };

/// What a scrolled server screen shows in `window` rows: the menu's logic
/// keeps the selection in view for the full panel, and a shorter panel
/// moves the view itself.
fn scrolled(state: menu.State, l: menu.Layout, window: usize) Scrolled {
    const shown = @max(window -| 1, 1);
    var top = @min(state.top, l.lines() - shown);
    const at = l.line(state.cursor);
    if (at < top) top = at;
    if (at >= top + shown) top = at + 1 - shown;
    if (state.cursor == 0) top = 0;
    var lines = window;
    if (top + lines < l.lines()) lines -= 1;
    lines = @min(lines, l.lines() - top);
    return .{ .top = top, .lines = lines, .below = l.lines() - top - lines };
}

fn countRow(alloc: Allocator, arena: Allocator, n: usize, where: []const u8, width: u16) !Row {
    return row_text.composeTextRow(alloc, try arena.print("{d} {s}", .{ n, where }), width, ui_render.dim_style, 2);
}

const ConfirmLine = struct { text: []const u8, style: enum { question, detail, target } };

const Confirm = struct {
    lines: [24]ConfirmLine,
    question: [512]u8,
};

/// The confirmation's lines below the title: a blank, the question, and
/// what it means. An approval's target wraps, and is never cut.
fn confirmLines(p: Projection, r: menu.Row, width: u16, out: *Confirm) []const ConfirmLine {
    var n: usize = 0;
    const c = p.state.confirm orelse return out.lines[0..0];
    out.lines[n] = .{ .text = "", .style = .detail };
    n += 1;
    const name = r.status.name;
    const q = switch (c) {
        .remove => std.mem.print(&out.question, "Remove {s} from {s}?", .{ name, p.fileOf(r) }),
        .approve => std.mem.print(&out.question, "Approve {s} for this project? It {s}:", .{ name, if (r.status.transport == .stdio) "runs" else "connects to" }),
        .reject => std.mem.print(&out.question, "Reject {s}? spark won't start it in this project.", .{name}),
        .login, .logout, .enable, .disable, .edit => std.mem.print(&out.question, "{s} {s}?", .{ c.label(), name }),
    } catch "Are you sure?";
    out.lines[n] = .{ .text = q, .style = .question };
    n += 1;
    switch (c) {
        .remove => if (r.status.signed_in) {
            out.lines[n] = .{ .text = "Its saved login is deleted too.", .style = .detail };
            n += 1;
        },
        .approve => {
            var rest = r.target orelse "";
            const limit = @max(@as(usize, width) -| 4, 16);
            while (rest.len > 0 and n < out.lines.len) {
                var end = @min(rest.len, limit);
                if (end < rest.len) {
                    if (std.mem.findScalarLast(u8, rest[0..end], ' ')) |space| {
                        if (space > 0) end = space;
                    }
                    // Never inside a character.
                    while (end > 1 and end < rest.len and rest[end] & 0xC0 == 0x80) end -= 1;
                }
                out.lines[n] = .{ .text = rest[0..end], .style = .target };
                n += 1;
                rest = std.mem.trimStart(u8, rest[end..], " ");
            }
        },
        else => {},
    }
    return out.lines[0..n];
}

fn confirmRow(alloc: Allocator, arena: Allocator, p: Projection, index: u16, width: u16) !Row {
    const r = p.openRow() orelse return .empty;
    // The confirmation hides the server's facts, so its title keeps the status.
    if (index == 0) return title(alloc, r.status.name, try statusFact(arena, r), width);
    var confirm: Confirm = undefined;
    const lines = confirmLines(p, r, width, &confirm);
    if (index - 1 >= lines.len) return .empty;
    const line = lines[index - 1];
    return switch (line.style) {
        .question => row_text.composeTextRow(alloc, line.text, width, ui_render.subtitle_style, 2),
        .detail => row_text.composeTextRow(alloc, line.text, width, ui_render.dim_style, 2),
        .target => row_text.composeTextRow(alloc, line.text, width, "", 4),
    };
}

/// Remove and Reject ask on the server's own screen, on the choice's row, so
/// the panel keeps its size. An approval keeps its screen: it shows
/// everything it trusts, uncut.
fn asksInPlace(p: Projection) bool {
    const c = p.state.confirm orelse return false;
    return c.asksOnRow();
}

/// spark's hint line for where the menu is, widest first.
pub fn hintVariants(p: Projection) []const []const u8 {
    return switch (p.state.screen) {
        .add => &.{ "enter next     ↑ back     ←→ choose     esc back", "enter next  ↑ back  esc", "enter  ↑  esc" },
        .list => if (p.rows.len == 0) &.{ "enter add server     esc close", "enter  esc" } else &.{ "↑↓ navigate     enter open     esc close", "↑↓ move  enter open  esc", "enter open  esc close", "enter esc" },
        // A question asked in place leaves the server's hint line as it was;
        // the row shows its answers.
        .confirm => if (asksInPlace(p)) serverHints(p) else &.{ "enter confirm     esc cancel", "enter confirm  esc cancel", "enter esc" },
        .server => serverHints(p),
    };
}

fn serverHints(p: Projection) []const []const u8 {
    const r = p.openRow() orelse return &.{"esc back"};
    var buf: [menu.max_choices]menu.Choice = undefined;
    if (p.state.cursor >= menu.choices(r, &buf).len) return &.{ "↑↓ navigate     esc back", "↑↓ move  esc back", "esc" };
    return &.{ "↑↓ navigate     enter run     esc back", "↑↓ move  enter run  esc", "enter run  esc back", "enter esc" };
}

/// The question Remove or Reject asks on its row. The row draws it terminal
/// safe, so a name of any bytes stays inert.
fn question(arena: Allocator, p: Projection, r: menu.Row, c: menu.Choice) ![]const u8 {
    const name = r.status.name;
    return switch (c) {
        .remove => if (r.status.signed_in)
            arena.print("Remove {s} and its login from {s}?", .{ name, p.fileOf(r) })
        else
            arena.print("Remove {s} from {s}?", .{ name, p.fileOf(r) }),
        else => arena.print("Reject {s}? spark won't start it in this project.", .{name}),
    };
}

const testing = std.testing;

const host_runtime = @import("../../core/mcp_host/runtime.zig");

fn testStatus(name: []const u8, state: host_runtime.State) host_runtime.Status {
    return .{ .name = name, .source = .profile, .transport = .http, .state = state };
}

fn render(p: Projection, width: u16) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    const rows = menuRowCount(p, width, max_inline_rows);
    var i: u16 = 0;
    while (i < rows) : (i += 1) {
        var row = try composeRow(testing.allocator, p, i, width, rows);
        defer row.deinit(testing.allocator);
        try testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= width);
        try out.writer.print("{s}\n", .{try stripped(row.items)});
    }
    return out.toOwnedSlice();
}

var strip_buf: [4096]u8 = undefined;

fn stripped(styled: []const u8) ![]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < styled.len) {
        // A link: OSC up to its ST.
        if (std.mem.startsWith(u8, styled[i..], "\x1b]")) {
            i = if (std.mem.find(u8, styled[i..], "\x1b\\")) |end| i + end + 2 else styled.len;
            continue;
        }
        if (styled[i] == 0x1b) {
            while (i < styled.len and styled[i] != 'm') i += 1;
            i += 1;
            continue;
        }
        strip_buf[n] = styled[i];
        n += 1;
        i += 1;
    }
    return std.mem.trimEnd(u8, strip_buf[0..n], " ");
}

// The address is the server's: no byte of it may end the link, start another
// sequence, or push a row past the width.
fn fuzzWaitingAddress(_: void, smith: *testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buffer, &.{
        .rangeAtMost(u8, 0x21, 0x7e, 8),
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .value(u8, 0x1b, 2),
        .value(u8, 0x07, 1),
        .value(u8, '\\', 2),
        .value(u8, ']', 2),
    });
    const url = buffer[0..len];
    var linear = testStatus("linear", .idle);
    linear.needs_login = true;
    const rows = [_]menu.Row{.{ .status = linear, .target = "https://mcp.linear.app/mcp" }};
    var p: Projection = .{ .rows = &rows, .tools = .needs_login, .sign_in_url = url };
    menu.open(&p.state);
    _ = menu.press(&p.state, .{ .rows = &rows }, .enter);
    const width = smith.valueRangeAtMost(u16, 20, 140);
    const count = menuRowCount(p, width, max_inline_rows);
    const open = "\x1b]8;id=spark-mcp-sign-in;";
    const close = "\x1b]8;;\x1b\\";
    for (0..count) |i| {
        var row = try composeRow(testing.allocator, p, @intCast(i), width, count);
        defer row.deinit(testing.allocator);
        try testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= width);
        try testing.expect(std.mem.findScalar(u8, row.items, 0x07) == null);
        // Every OSC in a row is the link's, around an address that can't end it.
        var rest = row.items;
        while (std.mem.find(u8, rest, "\x1b]")) |at| {
            rest = rest[at..];
            if (std.mem.startsWith(u8, rest, close)) {
                rest = rest[close.len..];
                continue;
            }
            try testing.expect(text_utils.isLinkTarget(url));
            try testing.expect(std.mem.startsWith(u8, rest, open));
            try testing.expect(std.mem.startsWith(u8, rest[open.len..], url));
            try testing.expect(std.mem.startsWith(u8, rest[open.len + url.len ..], "\x1b\\"));
            rest = rest[open.len + url.len + 2 ..];
        }
    }
}
