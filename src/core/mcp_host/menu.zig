//! The `/mcp` menu's logic: spark's picker
//! showing servers. A server's actions are choices that run the `/mcp`
//! verbs, so the menu adds nothing of its own. Pure: the shell's state owns
//! one, and the footer draws it.
//!
//! TLA+ model: `tests/tla/mcp_host/HostLifecycle.tla`.

const std = @import("std");
const fuzzy_match = @import("../shared/fuzzy_match.zig");
const text_utils = @import("../shared/text_utils.zig");
const runtime = @import("runtime.zig");
const login_words = @import("login_words.zig");

pub const Screen = enum { list, server, confirm, add };

/// The add-server form's steps, in order. Text steps read the composer;
/// the others choose with the arrow keys.
pub const AddStep = enum {
    name,
    kind,
    target,
    pairs,
    scope,
    review,

    pub fn typed(step: AddStep) bool {
        return switch (step) {
            .name, .target, .pairs => true,
            .kind, .scope, .review => false,
        };
    }
};

pub const Choice = enum {
    login,
    logout,
    approve,
    reject,
    remove,
    enable,
    disable,
    edit,

    pub fn label(c: Choice) []const u8 {
        return switch (c) {
            .login => "Log in",
            .logout => "Log out",
            .approve => "Approve",
            .reject => "Reject",
            .remove => "Remove",
            .enable => "Enable",
            .disable => "Disable",
            .edit => "Edit",
        };
    }

    /// The `/mcp` verb it runs.
    pub fn verb(c: Choice) []const u8 {
        return @tagName(c);
    }

    /// Remove, approve, and reject ask first; login and logout are quick to undo.
    pub fn asks(c: Choice) bool {
        return switch (c) {
            .remove, .approve, .reject => true,
            .login, .logout, .enable, .disable, .edit => false,
        };
    }

    /// Remove and Reject ask on the choice's own row, with yes and no. An
    /// approval keeps its own screen: it shows everything it trusts.
    pub fn asksOnRow(c: Choice) bool {
        return c == .remove or c == .reject;
    }
};

/// One server as the menu shows it; borrowed from the host's snapshot.
pub const Row = struct {
    status: runtime.Status,
    /// What it connects to or runs: what an approval trusts.
    target: ?[]const u8 = null,
};

pub const max_choices = 6;

/// The choices a server offers: its next step first, Remove last.
pub fn choices(row: Row, out: *[max_choices]Choice) []const Choice {
    const s = row.status;
    const project = s.source == .workspace;
    var n: usize = 0;
    if (s.state == .waiting_for_approval or s.state == .rejected) {
        out[n] = .approve;
        n += 1;
    } else if (s.needs_login) {
        out[n] = .login;
        n += 1;
    }
    if (s.signed_in and s.state != .waiting_for_approval and s.state != .rejected) {
        out[n] = .logout;
        n += 1;
    }
    if (project and s.state != .rejected) {
        out[n] = .reject;
        n += 1;
    }
    if (s.state == .disabled) {
        // A disabled server offers only turning it back on and removing it.
        out[0] = .enable;
        out[1] = .edit;
        out[2] = .remove;
        return out[0..3];
    }
    out[n] = .edit;
    n += 1;
    if (!project) {
        out[n] = .disable;
        n += 1;
    }
    out[n] = .remove;
    n += 1;
    return out[0..n];
}

/// Servers match by name, as spark's other menus match, and the list keeps its
/// own order (`fuzzy_match.Filter`); an empty filter keeps everything.
const ServerMatches = struct {
    rows: []const Row,
    filter: []const u8,

    pub fn matchAt(self: ServerMatches, position: usize) ?fuzzy_match.Match {
        return fuzzy_match.match(self.filter, &.{.{ .text = self.rows[position].status.name }});
    }
};

/// What the menu knows of the open server's tools.
pub const Tools = union(enum) {
    loading,
    needs_login,
    needs_approval,
    failed: []const u8,
    ready: []const Tool,
};

pub const Tool = struct { name: []const u8, description: []const u8 };

/// A tool matches by its name or by the words of what it says it does, so a
/// terse name is still found.
const ToolMatches = struct {
    tools: []const Tool,
    filter: []const u8,

    pub fn matchAt(self: ToolMatches, position: usize) ?fuzzy_match.Match {
        const t = self.tools[position];
        return fuzzy_match.match(self.filter, &.{ .{ .text = t.name }, .{ .text = t.description, .kind = .text } });
    }
};

fn toolFilter(tools: []const Tool, filter: []const u8) fuzzy_match.Filter(ToolMatches) {
    return .init(.{ .tools = tools, .filter = filter }, tools.len);
}

/// How many tools `filter` keeps.
pub fn toolCount(tools: Tools, filter: []const u8) usize {
    const all = switch (tools) {
        .ready => |t| t,
        else => return 0,
    };
    return toolFilter(all, filter).count();
}

/// The `n`th tool `filter` keeps.
pub fn nthTool(tools: []const Tool, filter: []const u8, n: usize) ?Tool {
    return tools[toolFilter(tools, filter).at(n) orelse return null];
}

/// A server's screen below its title: its facts and a blank, its choices,
/// then a blank and either the tools' heading and the tools, or one line
/// saying why there are none.
pub const Layout = struct {
    lead: usize,
    choices: usize,
    gap: usize,
    tools: usize,
    /// Lines the screen shows below its title.
    window: usize,
    /// While a sign-in waits for the browser: its address, wrapped, after
    /// the heading. Nothing there is selectable.
    waiting: usize = 0,

    pub fn lines(l: Layout) usize {
        return l.lead + l.choices + l.gap + l.waiting + l.tools;
    }

    pub fn selectable(l: Layout) usize {
        return l.choices + l.tools;
    }

    /// The line the `cursor`th selectable item is on.
    pub fn line(l: Layout, cursor: usize) usize {
        return if (cursor < l.choices) l.lead + cursor else l.lead + l.choices + l.gap + l.waiting + (cursor - l.choices);
    }

    /// Content lines shown; when everything doesn't fit, a row goes to the
    /// count of what's below.
    pub fn shown(l: Layout) usize {
        return if (l.lines() <= l.window) l.lines() else @max(l.window -| 1, 1);
    }
};

/// Whether a server's screen shows its last error; a login it needs is
/// already its status.
pub fn showsError(row: Row) bool {
    return row.status.last_error != null and !row.status.needs_login;
}

/// The tools as the screen tells them: a server that needs a login or an
/// approval says so, rather than as a failure, even while a load is still on
/// its way.
pub fn toolsFor(row: Row, tools: Tools) Tools {
    if (tools == .ready) return tools;
    if (row.status.state == .waiting_for_approval) return .needs_approval;
    return if (row.status.needs_login) .needs_login else tools;
}

/// A server's screen with `filter` typed, which narrows its tools.
pub fn serverLayout(row: Row, tools: Tools, filter: []const u8, window: usize) Layout {
    var buf: [max_choices]Choice = undefined;
    return .{
        // http or runs, file, status, protocol when known, and error when
        // there is one; then a blank.
        .lead = 3 + @as(usize, @intFromBool(row.status.version != null)) + @intFromBool(showsError(row)) + 1,
        .choices = choices(row, &buf).len,
        // A blank, then the heading or the reason there are no tools.
        .gap = 2,
        .tools = toolCount(tools, filter),
        .window = window,
    };
}

pub const name_capacity = 256;

pub const State = struct {
    active: bool = false,
    screen: Screen = .list,
    selected_len: usize = 0,
    selected_buf: [name_capacity]u8 = undefined,
    /// On a server's screen: the selected item (its choices, then its
    /// tools), and the first line shown.
    cursor: usize = 0,
    top: usize = 0,
    confirm: ?Choice = null,
    /// On a question asked on its row: "no" is chosen instead of "yes".
    answer_no: bool = false,
    /// The list's filter, kept while a server's screen filters its tools.
    list_filter_len: usize = 0,
    list_filter_buf: [name_capacity]u8 = undefined,
    /// On the list: the "Add server" row is selected instead of a server.
    on_add: bool = false,
    add_step: AddStep = .name,
    /// The form's choices: HTTP or a local command, the profile or the
    /// project's file, and whether to sign in after saving.
    add_http: bool = true,
    add_project: bool = false,
    add_login: bool = true,
    /// The form edits the open server instead of adding one.
    add_editing: bool = false,

    /// The selected server, kept by name so a reload doesn't move it.
    pub fn selectedName(s: *const State) []const u8 {
        return s.selected_buf[0..s.selected_len];
    }

    pub fn listFilter(s: *const State) []const u8 {
        return s.list_filter_buf[0..s.list_filter_len];
    }

    /// Keeps the list's filter, up to `name_capacity` bytes and never
    /// inside a character.
    pub fn keepListFilter(s: *State, filter: []const u8) void {
        var n = @min(filter.len, name_capacity);
        while (n > 0 and n < filter.len and filter[n] & 0xC0 == 0x80) n -= 1;
        s.list_filter_len = n;
        @memcpy(s.list_filter_buf[0..n], filter[0..n]);
    }

    fn select(s: *State, name: []const u8) void {
        s.selected_len = @min(name.len, name_capacity);
        @memcpy(s.selected_buf[0..s.selected_len], name[0..s.selected_len]);
    }

    /// Where the selection is in `rows`; the first row when it isn't there.
    pub fn selectedIndex(s: *const State, rows: []const Row) ?usize {
        if (rows.len == 0) return null;
        for (rows, 0..) |r, i| if (std.mem.eql(u8, r.status.name, s.selectedName())) return i;
        return 0;
    }
};

/// ← and → only choose between yes and no on a question asked on its row.
pub const Key = enum { up, down, left, right, enter, escape };

pub const Effect = union(enum) {
    none,
    close,
    /// A server opened: load its tools.
    open: []const u8,
    /// Back to the list: its tools aren't needed any more.
    back,
    run: struct { choice: Choice, server: []const u8 },
    /// The add form opened: the app clears its fields.
    add_start,
    /// Enter on a text step: the app takes the composer's text for it and
    /// calls `addAdvance` when it's valid.
    add_text: AddStep,
    /// Enter on the last step: save the server.
    add_save,
};

/// The form's next step after `step`.
/// Opens the form on the open server, its fields filled in by the app.
pub fn startEdit(s: *State, http: bool, project: bool) void {
    s.screen = .add;
    // An edit opens on Save with every field in view: ↑ picks the one to change.
    s.add_step = .review;
    s.add_http = http;
    s.add_project = project;
    s.add_login = false;
    s.add_editing = true;
}

/// Back to a step the form found wrong on save.
pub fn addGoTo(s: *State, step: AddStep) void {
    s.add_step = step;
}

/// After a field is entered: the next step, or Save when editing, so an
/// edit changes one field without walking the others.
pub fn addAdvance(s: *State) void {
    if (s.add_editing) {
        s.add_step = .review;
        return;
    }
    addNext(s);
}

fn addNext(s: *State) void {
    s.add_step = switch (s.add_step) {
        .name => .kind,
        .kind => .target,
        .target => .pairs,
        .pairs => .scope,
        .scope => .review,
        .review => .review,
    };
}

fn addBack(s: *State) void {
    s.add_step = switch (s.add_step) {
        .name => {
            if (s.add_editing) return;
            s.screen = .list;
            return;
        },
        .kind => .name,
        .target => .kind,
        .pairs => .target,
        .scope => .pairs,
        .review => .scope,
    };
}

pub const View = struct {
    /// The servers the list shows, after the filter: the ones that work,
    /// then the ones that need attention, each by name.
    rows: []const Row,
    /// Where the servers that need attention start in `rows`; null when the
    /// list shows none.
    attention_start: ?usize = null,
    /// The open server, found by name among all servers; null once it's gone.
    open: ?Row = null,
    layout: Layout = .{ .lead = 0, .choices = 0, .gap = 0, .tools = 0, .window = 1 },
};

/// The lines a server's screen has below its title: the inline panel's 13
/// rows less the title. That fits `http`, `file`, `status`, a blank, two
/// choices, a blank, and a waiting sign-in's heading with four rows of
/// address. A shorter panel moves its own view to keep the selection.
pub const server_window: usize = 12;

/// What `s` shows of `rows` with `filter` typed, the list's rows going into
/// `buf`. On a server's screen `filter` narrows its tools instead.
pub fn viewOf(s: *const State, rows: []const Row, filter: []const u8, tools: Tools, buf: []Row) View {
    var n: usize = 0;
    var open_row: ?Row = null;
    var attention_start: usize = 0;
    const servers: fuzzy_match.Filter(ServerMatches) = .init(.{ .rows = rows, .filter = filter }, rows.len);
    // The servers that work first, then the ones that need attention, each
    // group by name.
    for ([_]bool{ false, true }) |attention_pass| {
        if (attention_pass) attention_start = n;
        const group_start = n;
        for (rows, 0..) |r, position| {
            if (needsAttention(r.status) != attention_pass) continue;
            if (s.screen != .list and std.mem.eql(u8, r.status.name, s.selectedName())) open_row = r;
            if (n == buf.len or !servers.keeps(position)) continue;
            buf[n] = r;
            n += 1;
        }
        std.sort.insertion(Row, buf[group_start..n], {}, byName);
    }
    var v: View = .{ .rows = buf[0..n], .attention_start = if (attention_start < n) attention_start else null, .open = open_row };
    if (open_row) |r| v.layout = serverLayout(r, tools, filter, server_window);
    return v;
}

/// Alphabetical, ignoring case, like a directory listing.
fn byName(_: void, a: Row, b: Row) bool {
    return std.ascii.lessThanIgnoreCase(a.status.name, b.status.name);
}

/// A new tool filter on a server's screen selects the first tool it keeps,
/// so Enter can't run a choice by surprise; with no filter, or no tool
/// left, the selection goes back to the first choice.
pub fn filterChanged(s: *State, view: View, filtering: bool) void {
    if (s.screen != .server) return;
    const l = view.layout;
    s.cursor = if (filtering and l.tools > 0) l.choices else 0;
    s.top = 0;
    keepVisible(s, l);
}

pub fn open(s: *State) void {
    s.* = .{ .active = true };
}

/// Keeps a server's screen valid after its choices or tools changed, or
/// after the server went away.
pub fn settle(s: *State, view: View) Effect {
    if (s.screen == .list or s.screen == .add) return .none;
    if (view.open == null) {
        s.screen = .list;
        s.confirm = null;
        s.cursor = 0;
        s.top = 0;
        return .back;
    }
    const l = view.layout;
    if (l.selectable() > 0) s.cursor = @min(s.cursor, l.selectable() - 1) else s.cursor = 0;
    keepVisible(s, l);
    return .none;
}

pub fn press(s: *State, view: View, key: Key) Effect {
    switch (s.screen) {
        .list => {
            const on_add = s.on_add or view.rows.len == 0;
            if (on_add) switch (key) {
                .up => {
                    if (view.rows.len > 0) {
                        s.on_add = false;
                        s.select(view.rows[view.rows.len - 1].status.name);
                    }
                    return .none;
                },
                .enter, .right => {
                    s.on_add = false;
                    s.screen = .add;
                    s.add_step = .name;
                    s.add_http = true;
                    s.add_project = false;
                    s.add_login = true;
                    s.add_editing = false;
                    return .add_start;
                },
                .escape => return .close,
                .down, .left => return .none,
            };
            const i = s.selectedIndex(view.rows) orelse return if (key == .escape) .close else .none;
            switch (key) {
                .up => s.select(view.rows[i -| 1].status.name),
                .down => if (i + 1 >= view.rows.len) {
                    s.on_add = true;
                } else s.select(view.rows[i + 1].status.name),
                .left, .right => {},
                .enter => {
                    const name = view.rows[i].status.name;
                    s.select(name);
                    s.screen = .server;
                    s.cursor = 0;
                    s.top = 0;
                    return .{ .open = name };
                },
                .escape => return .close,
            }
            return .none;
        },
        .server => {
            const r = view.open orelse return settle(s, view);
            const l = view.layout;
            switch (key) {
                .up => s.cursor -|= 1,
                .down => if (s.cursor + 1 < l.selectable()) {
                    s.cursor += 1;
                },
                .left, .right => {},
                .enter => {
                    var buf: [max_choices]Choice = undefined;
                    const cs = choices(r, &buf);
                    if (s.cursor >= cs.len) return .none;
                    const c = cs[s.cursor];
                    if (!c.asks()) return .{ .run = .{ .choice = c, .server = r.status.name } };
                    s.screen = .confirm;
                    s.confirm = c;
                    s.answer_no = false;
                    return .none;
                },
                .escape => {
                    s.screen = .list;
                    s.cursor = 0;
                    s.top = 0;
                    return .back;
                },
            }
            keepVisible(s, l);
            return .none;
        },
        .add => switch (key) {
            .escape => {
                // Esc leaves an edit for the server's screen at once.
                if (s.add_editing) {
                    s.screen = .server;
                    return .none;
                }
                addBack(s);
                return if (s.screen == .list) .back else .none;
            },
            .enter => {
                if (s.add_step.typed()) return .{ .add_text = s.add_step };
                if (s.add_step == .review) return .add_save;
                addAdvance(s);
                return .none;
            },
            // ↑ goes back a step, like /provider; ↓ moves on from a choice.
            .up => {
                addBack(s);
                return if (s.screen == .list) .back else .none;
            },
            // ↓ moves on without checking; the app keeps what was typed and
            // checks every field on save. The last step never saves by surprise.
            .down => {
                if (s.add_step != .review) addNext(s);
                return .none;
            },
            .left, .right => {
                switch (s.add_step) {
                    .kind => s.add_http = !s.add_http,
                    .scope => s.add_project = !s.add_project,
                    .review => if (s.add_http) {
                        s.add_login = !s.add_login;
                    },
                    else => {},
                }
                return .none;
            },
        },
        // Only the answer moves while a confirmation is open: ← chooses yes
        // and → no, and Enter on no is Esc.
        .confirm => {
            const r = view.open orelse return settle(s, view);
            const c = s.confirm.?;
            switch (key) {
                .left => if (c.asksOnRow()) {
                    s.answer_no = false;
                },
                .right => if (c.asksOnRow()) {
                    s.answer_no = true;
                },
                .enter => if (c.asksOnRow() and s.answer_no) {
                    s.screen = .server;
                    s.confirm = null;
                    s.answer_no = false;
                } else {
                    // A removed server has no screen to come back to.
                    s.screen = if (c == .remove) .list else .server;
                    s.confirm = null;
                    if (c == .remove) {
                        s.cursor = 0;
                        s.top = 0;
                    }
                    return .{ .run = .{ .choice = c, .server = r.status.name } };
                },
                .escape => {
                    s.screen = .server;
                    s.confirm = null;
                    s.answer_no = false;
                },
                .up, .down => {},
            }
            return .none;
        },
    }
}

fn keepVisible(s: *State, l: Layout) void {
    if (l.lines() <= l.window or s.cursor == 0) {
        s.top = 0;
        return;
    }
    const at = l.line(s.cursor);
    const shown = l.shown();
    if (at < s.top) s.top = at;
    if (at >= s.top + shown) s.top = at + 1 - shown;
    s.top = @min(s.top, l.lines() - shown);
}

/// How long news of a sign-in stays on the status line.
pub const news_ms: i64 = 5000;

/// The link a waiting sign-in offers when the browser didn't open, in the
/// transcript and on the server's screen alike.
pub const sign_in_link_label = "Open the sign-in page";

/// The longest the status line waits for servers to finish starting.
pub const startup_quiet_ms: i64 = 10_000;

/// Whether servers started `since_start_ms` ago are done starting: none is
/// still idle, connecting, or retrying, or `startup_quiet_ms` passed. Until
/// then the count of servers that need the user would climb while they
/// report in, so the status line waits and shows the total once.
pub fn startupSettled(statuses: []const runtime.Status, since_start_ms: i64) bool {
    if (since_start_ms >= startup_quiet_ms) return true;
    for (statuses) |s| switch (s.state) {
        .idle, .connecting, .retrying => if (!needsAttention(s)) return false,
        else => {},
    };
    return true;
}

/// The servers the user already saw needing attention, by name, so the
/// status line can stop repeating them once they've sent a prompt.
pub const Seen = struct {
    pub const capacity = 128;
    hashes: [capacity]u64 = undefined,
    len: usize = 0,
    /// More servers needed attention than fit; every one counts as seen.
    overflowed: bool = false,

    /// Remembers every server in `statuses` that needs attention now.
    pub fn record(seen: *Seen, statuses: []const runtime.Status) void {
        seen.* = .{};
        for (statuses) |s| {
            if (!needsAttention(s)) continue;
            if (seen.len == capacity) {
                seen.overflowed = true;
                return;
            }
            seen.hashes[seen.len] = nameHash(s.name);
            seen.len += 1;
        }
    }

    pub fn contains(seen: *const Seen, name: []const u8) bool {
        if (seen.overflowed) return true;
        const h = nameHash(name);
        for (seen.hashes[0..seen.len]) |x| if (x == h) return true;
        return false;
    }

    fn nameHash(name: []const u8) u64 {
        return std.hash.Wyhash.hash(0, name);
    }
};

/// The servers in `statuses` that need attention and aren't in `seen`,
/// copied into `out`: what the status line still has to say.
pub fn unseen(statuses: []const runtime.Status, seen: *const Seen, out: []runtime.Status) []runtime.Status {
    var n: usize = 0;
    for (statuses) |s| {
        if (n == out.len) break;
        if (!needsAttention(s) or seen.contains(s.name)) continue;
        out[n] = s;
        n += 1;
    }
    return out[0..n];
}

/// What the status line says about MCP, written into `buf`: fresh news,
/// else the sign-in waiting for the browser, else what needs the user until
/// it's handled. Empty when nothing does: `/mcp` lists every server.
/// `notes` counts config problems, which `/mcp list` shows.
pub fn statusLine(buf: []u8, statuses: []const runtime.Status, signing_in: ?[]const u8, news: ?[]const u8, notes: usize) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (news) |text| {
        writeSafe(&w, text);
        return whole(w.buffered());
    }
    if (signing_in) |name| {
        w.writeAll("Signing in to ") catch {};
        writeSafe(&w, name);
        w.writeAll(" · /mcp") catch {};
        return whole(w.buffered());
    }
    var needs: usize = 0;
    var first: ?runtime.Status = null;
    for (statuses) |s| {
        if (!needsAttention(s)) continue;
        if (needs == 0) first = s;
        needs += 1;
    }
    if (needs == 1) {
        writeSafe(&w, first.?.name);
        w.print(" {s} · /mcp", .{attention(first.?).?}) catch {};
    } else if (needs > 1) {
        w.print("{d} MCP need attention · /mcp", .{needs}) catch {};
    } else if (notes > 0) {
        w.print("MCP config has {d} problem{s} · /mcp list", .{ notes, if (notes == 1) "" else "s" }) catch {};
    }
    return whole(w.buffered());
}

/// Whether a server waits on the user: the servers the status line counts,
/// and the list's "Needs attention" group. A disabled or rejected server
/// was the user's choice, so it doesn't.
pub fn needsAttention(s: runtime.Status) bool {
    return s.state != .disabled and s.state != .rejected and attention(s) != null;
}

/// What a server needs from the user, if anything.
fn attention(s: runtime.Status) ?[]const u8 {
    if (s.needs_login) return login_words.attention(s.reason);
    return switch (s.state) {
        .waiting_for_approval => "is waiting for approval",
        .failed => "failed",
        .missing_env => "needs a variable",
        .invalid_env => "can't use a variable",
        else => null,
    };
}

/// Names and reasons come from config and servers: control characters,
/// C1 included, become `?`.
fn writeSafe(w: *std.Io.Writer, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        const c1 = c == 0xc2 and i + 1 < text.len and text[i + 1] >= 0x80 and text[i + 1] <= 0x9f;
        if (c < 0x20 or c == 0x7f or c1) {
            w.writeByte('?') catch return;
            if (c1) i += 1;
        } else w.writeByte(c) catch return;
    }
}

/// A full buffer may end inside a character; drop the partial one.
fn whole(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and !std.unicode.utf8ValidateSlice(bytes[0..end])) end -= 1;
    return bytes[0..end];
}

const testing = std.testing;

test "the status line puts news first, then what needs the user, and is quiet when nothing does" {
    var buf: [96]u8 = undefined;
    const plain: runtime.Status = .{ .name = "plain", .source = .profile, .transport = .http, .state = .idle, .needs_login = true };
    const ready: runtime.Status = .{ .name = "linear", .source = .profile, .transport = .http, .state = .ready };
    const off: runtime.Status = .{ .name = "old", .source = .profile, .transport = .stdio, .state = .disabled };
    const proj: runtime.Status = .{ .name = "proj", .source = .workspace, .transport = .stdio, .state = .waiting_for_approval };
    try testing.expectEqualStrings("Signed in to plain", statusLine(&buf, &.{ plain, ready }, null, "Signed in to plain", 0));
    try testing.expectEqualStrings("Signing in to plain · /mcp", statusLine(&buf, &.{ plain, ready }, "plain", null, 0));
    try testing.expectEqualStrings("plain needs login · /mcp", statusLine(&buf, &.{ plain, ready, off }, null, null, 0));
    try testing.expectEqualStrings("2 MCP need attention · /mcp", statusLine(&buf, &.{ plain, proj, ready }, null, null, 3));
    try testing.expectEqualStrings("MCP config has 2 problems · /mcp list", statusLine(&buf, &.{ready}, null, null, 2));
    // All is well, starting included: nothing to say.
    const starting: runtime.Status = .{ .name = "web", .source = .profile, .transport = .http, .state = .connecting };
    try testing.expectEqualStrings("", statusLine(&buf, &.{ ready, off, starting }, null, null, 0));
    try testing.expectEqualStrings("", statusLine(&buf, &.{}, null, null, 0));
}

fn testRow(name: []const u8, state: runtime.State, extra: struct {
    source: @FieldType(runtime.Status, "source") = .profile,
    transport: @FieldType(runtime.Status, "transport") = .http,
    needs_login: bool = false,
    signed_in: bool = false,
}) Row {
    return .{ .status = .{
        .name = name,
        .source = extra.source,
        .transport = extra.transport,
        .state = state,
        .needs_login = extra.needs_login,
        .signed_in = extra.signed_in,
    } };
}

fn choiceList(r: Row, buf: *[max_choices]Choice) []const Choice {
    return choices(r, buf);
}
