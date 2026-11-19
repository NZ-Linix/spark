//! An inline list to pick from, with its own filter line, and an input line
//! for the one value an action needs, such as a folder to add. It never
//! touches the composer. `/prompt` opens one; the app decides what a picked
//! item's `value` does.

const std = @import("std");
const fuzzy_match = @import("../shared/fuzzy_match.zig");
const display_width = @import("../shared/display_width.zig");
const line_input = @import("line_input.zig");

const Allocator = std.mem.Allocator;

pub const max_items = 512;
/// Item rows shown at once; the list scrolls past them.
pub const window = 12;

pub const Item = struct {
    label: []const u8,
    /// Dim text after the label, such as a folder.
    detail: []const u8 = "",
    /// What the app gets back when the item is picked.
    value: []const u8,
    /// Drawn with a check mark, such as the active prompt.
    marked: bool = false,
    /// An action row, such as "+ Add folder", drawn apart from the items.
    action: bool = false,
    /// A section heading, such as "Starred". It cannot be selected and
    /// hides while a filter is typed.
    section: bool = false,
    /// Starred by the user; `/prompt` lists these in their own section.
    starred: bool = false,
};

/// Label columns are at least this wide, so a list of short names still
/// lines its details up where a list of long ones would.
const min_label_cols = 16;
/// Label columns never exceed this; longer labels are clipped.
pub const max_label_cols = 40;

pub const Purpose = enum { prompt, search };

pub const Mode = enum { pick, input };

pub const State = struct {
    active: bool = false,
    purpose: Purpose = .prompt,
    mode: Mode = .pick,
    title: []const u8 = "",
    /// In input mode: what the line is for, and why the last value failed.
    input_label: []const u8 = "",
    problem: ?[]const u8 = null,
    items: []const Item = &.{},
    arena: ?std.heap.ArenaAllocator = null,
    /// Index into the filtered list.
    selected: usize = 0,
    filter: line_input.LineInput = .{},
    input: line_input.LineInput = .{},
    /// Display width of the label column, measured over every item when
    /// the picker opens so filtering and scrolling never move the details.
    label_cols: usize = min_label_cols,

    /// Opens on `items`, copied into the picker's arena. The marked item is
    /// selected first.
    pub fn open(self: *State, alloc: Allocator, purpose: Purpose, title: []const u8, items: []const Item) Allocator.Error!void {
        self.close(alloc);
        var arena: std.heap.ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned = try a.alloc(Item, @min(items.len, max_items));
        var label_cols: usize = min_label_cols;
        for (owned, items[0..owned.len]) |*dst, src| {
            dst.* = .{
                .label = try a.dupe(u8, src.label),
                .detail = try a.dupe(u8, src.detail),
                .value = try a.dupe(u8, src.value),
                .marked = src.marked,
                .action = src.action,
                .section = src.section,
                .starred = src.starred,
            };
            if (!src.section) label_cols = @max(label_cols, display_width.visibleWidthIgnoringAnsi(src.label));
        }
        self.* = .{
            .active = true,
            .purpose = purpose,
            .title = try a.dupe(u8, title),
            .items = owned,
            .arena = arena,
            .label_cols = @min(label_cols, max_label_cols),
        };
        self.selected = for (owned, 0..) |item, i| {
            if (item.marked) break i;
        } else 0;
        self.skipSection(1);
    }

    /// Moves the selection to the visible item whose value is `value`, if
    /// the filter keeps one.
    pub fn selectValue(self: *State, value: []const u8) void {
        for (0..self.visibleCount()) |n| {
            const item = self.visible(n) orelse break;
            if (!item.section and std.mem.eql(u8, item.value, value)) {
                self.selected = n;
                return;
            }
        }
    }

    /// Rows the list takes in pick mode. It follows the whole list, not
    /// what the filter keeps, so typing never resizes the picker.
    pub fn listRows(self: *const State) usize {
        return @max(@min(self.items.len, window), 1);
    }

    /// Steps off a section heading in `direction`, or the other way at an end.
    fn skipSection(self: *State, direction: i2) void {
        const n = self.visibleCount();
        if (n == 0) return;
        self.selected = @min(self.selected, n - 1);
        for ([2]i2{ direction, -direction }) |step| {
            var i = self.selected;
            while (true) {
                if (!self.isSection(i)) {
                    self.selected = i;
                    return;
                }
                if (step > 0) {
                    if (i + 1 >= n) break;
                    i += 1;
                } else {
                    if (i == 0) break;
                    i -= 1;
                }
            }
        }
    }

    fn isSection(self: *const State, n: usize) bool {
        const item = self.visible(n) orelse return false;
        return item.section;
    }

    pub fn close(self: *State, alloc: Allocator) void {
        self.filter.deinit(alloc);
        self.input.deinit(alloc);
        if (self.arena) |*a| a.deinit();
        self.* = .{};
    }

    /// Switches to the input line for `label`.
    pub fn ask(self: *State, label: []const u8) void {
        self.mode = .input;
        self.input_label = label;
        self.problem = null;
        self.input.clear();
    }

    /// Back from the input line to the list.
    pub fn back(self: *State) void {
        self.mode = .pick;
        self.problem = null;
        self.input.clear();
    }

    /// The line typing goes to.
    pub fn line(self: *State) *line_input.LineInput {
        return if (self.mode == .input) &self.input else &self.filter;
    }

    /// Keeps the selection on a visible item after the filter changed.
    pub fn filterChanged(self: *State) void {
        self.selected = 0;
        self.skipSection(1);
    }

    pub fn move(self: *State, delta: i32) void {
        const n = self.visibleCount();
        if (n == 0) return;
        if (delta < 0) self.selected -|= @intCast(-delta) else self.selected = @min(self.selected + @as(usize, @intCast(delta)), n - 1);
        self.skipSection(if (delta < 0) -1 else 1);
    }

    pub fn visibleCount(self: *const State) usize {
        return self.matches().count();
    }

    /// The `n`th item the filter keeps.
    pub fn visible(self: *const State, n: usize) ?Item {
        return self.items[self.matches().at(n) orelse return null];
    }

    pub fn selectedItem(self: *const State) ?Item {
        return self.visible(@min(self.selected, self.visibleCount() -| 1));
    }

    /// The first row shown, so the selection stays in view.
    pub fn top(self: *const State) usize {
        return if (self.selected < window) 0 else self.selected + 1 - window;
    }

    const Matches = struct {
        items: []const Item,
        filter: []const u8,

        pub fn matchAt(self: Matches, position: usize) ?fuzzy_match.Match {
            const item = self.items[position];
            // Headings show only on the unfiltered list.
            if (item.section) return if (self.filter.len == 0) .{ .tier = .prefix, .field = 0 } else null;
            // Action rows stay whatever is typed.
            if (item.action) return .{ .tier = .prefix, .field = 0 };
            return fuzzy_match.match(self.filter, &.{ .{ .text = item.label }, .{ .text = item.detail, .kind = .text } });
        }
    };

    fn matches(self: *const State) fuzzy_match.Filter(Matches) {
        return .init(.{ .items = self.items, .filter = self.filter.items() }, self.items.len);
    }
};

test "list picker filters, keeps action rows, and selects the marked item" {
    const alloc = std.testing.allocator;
    var p: State = .{};
    defer p.close(alloc);
    try p.open(alloc, .prompt, "System prompts", &.{
        .{ .label = "Default", .value = "default" },
        .{ .label = "ENI Lite", .detail = "Claude", .value = "a", .marked = true },
        .{ .label = "glm flash", .value = "b" },
        .{ .label = "+ Add folder", .value = "+add", .action = true },
    });
    try std.testing.expectEqualStrings("a", p.selectedItem().?.value);
    for ("glm") |b| try p.filter.insert(alloc, b);
    p.filterChanged();
    try std.testing.expectEqual(@as(usize, 2), p.visibleCount());
    try std.testing.expectEqualStrings("b", p.selectedItem().?.value);
    p.move(1);
    try std.testing.expectEqualStrings("+add", p.selectedItem().?.value);
}

test "list picker skips section headings and keeps its size while filtering" {
    const alloc = std.testing.allocator;
    var p: State = .{};
    defer p.close(alloc);
    try p.open(alloc, .prompt, "System prompts", &.{
        .{ .label = "Starred", .value = "", .section = true },
        .{ .label = "beam", .value = "beam", .starred = true },
        .{ .label = "Prompts", .value = "", .section = true },
        .{ .label = "Default", .value = "default" },
        .{ .label = "a much longer prompt name", .value = "long" },
    });
    try std.testing.expectEqualStrings("beam", p.selectedItem().?.value);
    p.move(1);
    try std.testing.expectEqualStrings("default", p.selectedItem().?.value);
    p.move(-1);
    try std.testing.expectEqualStrings("beam", p.selectedItem().?.value);
    p.move(-1);
    try std.testing.expectEqualStrings("beam", p.selectedItem().?.value);
    try std.testing.expectEqual(@as(usize, 25), p.label_cols);
    const rows = p.listRows();
    for ("long") |b| try p.filter.insert(alloc, b);
    p.filterChanged();
    try std.testing.expectEqual(@as(usize, 1), p.visibleCount());
    try std.testing.expectEqual(rows, p.listRows());
    p.selectValue("long");
    try std.testing.expectEqualStrings("long", p.selectedItem().?.value);
}
