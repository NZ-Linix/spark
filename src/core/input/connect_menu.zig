//! State of the `/connect` form. It opens on a list of saved connections
//! with "Add connection" at the end; a connection opens Edit or Delete. The
//! form then takes one OpenAI-compatible connection a field at a time: its
//! name, base URL, API key, and models, each with an optional display name,
//! context window, and reasoning levels. The focused field's text lives here,
//! not in the composer, so the API key never reaches composer history.

const std = @import("std");
const configured_provider = @import("../config/configured_provider.zig");

const Allocator = std.mem.Allocator;

pub const max_models = 32;
pub const max_connections = 32;
const max_field_bytes = 2048;

pub const Field = enum {
    /// The list of connections.
    pick,
    /// Edit, Delete, or Back for the picked connection.
    action,
    name,
    base_url,
    api_key,
    model_id,
    model_name,
    model_context,
    model_efforts,

    pub fn label(self: Field) []const u8 {
        return switch (self) {
            .pick => "Connections",
            .action => "Connection",
            .name => "Name",
            .base_url => "Base URL",
            .api_key => "API key",
            .model_id => "Model ID",
            .model_name => "Display name",
            .model_context => "Context window",
            .model_efforts => "Reasoning levels",
        };
    }

    pub fn isList(self: Field) bool {
        return self == .pick or self == .action;
    }
};

pub const actions = [_][]const u8{ "Edit", "Delete", "Back" };

pub const Model = struct {
    id: []u8,
    name: ?[]u8 = null,
    context: ?u32 = null,
    /// Level names as typed, such as `low, medium, high`.
    efforts: ?[]u8 = null,
    /// `efforts` when the edit began, so unchanged levels keep the request
    /// fields the settings give them.
    original_efforts: ?[]u8 = null,
};

/// What Enter did.
pub const Advance = enum { next, invalid, finished, edit, delete };

/// Call `close` with the allocator passed to `open`.
pub const State = struct {
    active: bool = false,
    field: Field = .name,
    input: std.ArrayList(u8) = .empty,
    /// Byte offset of the cursor in `input`, on a UTF-8 boundary.
    cursor: usize = 0,
    name: std.ArrayList(u8) = .empty,
    base_url: std.ArrayList(u8) = .empty,
    api_key: std.ArrayList(u8) = .empty,
    /// The environment variable an edited connection reads its key from;
    /// kept while the key field stays empty.
    key_env: ?[]u8 = null,
    models: std.ArrayList(Model) = .empty,
    /// An edited connection's models not walked through yet, in order.
    pending: std.ArrayList(Model) = .empty,
    /// Saved connection names for the list.
    connections: std.ArrayList([]u8) = .empty,
    /// The highlighted row of `pick` or `action`.
    selected: usize = 0,
    /// The name of the connection being edited, before any rename.
    editing: ?[]u8 = null,
    /// Why the last Enter was refused; static text.
    problem: ?[]const u8 = null,

    /// Opens on the list when `names` has connections, else on a new one.
    pub fn open(self: *State, alloc: Allocator, names: []const []const u8) Allocator.Error!void {
        self.close(alloc);
        self.active = true;
        for (names[0..@min(names.len, max_connections)]) |name| {
            const copy = try alloc.dupe(u8, name);
            errdefer alloc.free(copy);
            try self.connections.append(alloc, copy);
        }
        self.field = if (self.connections.items.len > 0) .pick else .name;
    }

    pub fn close(self: *State, alloc: Allocator) void {
        self.input.deinit(alloc);
        self.name.deinit(alloc);
        std.crypto.secureZero(u8, self.api_key.items);
        self.api_key.deinit(alloc);
        self.base_url.deinit(alloc);
        if (self.key_env) |env| alloc.free(env);
        for (self.models.items) |model| freeModel(alloc, model);
        self.models.deinit(alloc);
        for (self.pending.items) |model| freeModel(alloc, model);
        self.pending.deinit(alloc);
        for (self.connections.items) |name| alloc.free(name);
        self.connections.deinit(alloc);
        if (self.editing) |name| alloc.free(name);
        self.* = .{};
    }

    /// Rows of the current list: the connections and "Add connection", or
    /// the actions.
    pub fn listLen(self: *const State) usize {
        return switch (self.field) {
            .pick => self.connections.items.len + 1,
            .action => actions.len,
            else => 0,
        };
    }

    pub fn move(self: *State, delta: i32) void {
        const len = self.listLen();
        if (len == 0) return;
        const count: i64 = @intCast(len);
        self.selected = @intCast(@mod(@as(i64, @intCast(self.selected)) + delta, count));
        self.problem = null;
    }

    /// The connection picked in the list.
    pub fn pickedName(self: *const State) ?[]const u8 {
        if (self.editing) |name| return name;
        return null;
    }

    /// Fills the form from a saved connection for editing.
    pub fn beginEdit(self: *State, alloc: Allocator, definition: *const configured_provider.Definition) Allocator.Error!void {
        try replace(alloc, &self.name, definition.id);
        try replace(alloc, &self.base_url, definition.base_url);
        switch (definition.auth) {
            .none => {},
            .key => |key| try replace(alloc, &self.api_key, key),
            .bearer => |env| self.key_env = try alloc.dupe(u8, env),
        }
        for (definition.model_metadata) |metadata| {
            var model: Model = .{ .id = try alloc.dupe(u8, metadata.id) };
            errdefer freeModel(alloc, model);
            if (metadata.display_name) |name| model.name = try alloc.dupe(u8, name);
            model.context = metadata.context_window;
            if (metadata.reasoning_efforts) |levels| {
                var text: std.ArrayList(u8) = .empty;
                defer text.deinit(alloc);
                for (levels, 0..) |level, index| {
                    if (index > 0) try text.appendSlice(alloc, ", ");
                    try text.appendSlice(alloc, level.name);
                }
                model.efforts = try alloc.dupe(u8, text.items);
                model.original_efforts = try alloc.dupe(u8, text.items);
            }
            try self.pending.append(alloc, model);
        }
        self.field = .name;
        try self.load(alloc, self.name.items);
    }

    /// Inserts at the cursor.
    pub fn appendByte(self: *State, alloc: Allocator, byte: u8) Allocator.Error!void {
        if (self.field.isList()) return;
        if (byte < 0x20 or byte == 0x7f) return;
        if (self.input.items.len >= max_field_bytes) return;
        try self.input.insert(alloc, self.cursor, byte);
        self.cursor += 1;
        self.problem = null;
    }

    /// Deletes the character before the cursor.
    pub fn deleteByte(self: *State) void {
        if (self.cursor == 0) return;
        const start = self.previousBoundary(self.cursor);
        self.removeRange(start, self.cursor);
        self.cursor = start;
        self.problem = null;
    }

    /// Deletes the character after the cursor.
    pub fn deleteNext(self: *State) void {
        if (self.cursor >= self.input.items.len) return;
        self.removeRange(self.cursor, self.nextBoundary(self.cursor));
        self.problem = null;
    }

    pub fn moveLeft(self: *State) void {
        self.cursor = self.previousBoundary(self.cursor);
    }

    pub fn moveRight(self: *State) void {
        self.cursor = self.nextBoundary(self.cursor);
    }

    pub fn moveHome(self: *State) void {
        self.cursor = 0;
    }

    pub fn moveEnd(self: *State) void {
        self.cursor = self.input.items.len;
    }

    pub fn clearLine(self: *State) void {
        self.clearInput();
        self.problem = null;
    }

    /// Goes back one step and loads what was entered there. Returns false
    /// when there is nowhere to go back to.
    pub fn back(self: *State, alloc: Allocator) Allocator.Error!bool {
        var buf: [16]u8 = undefined;
        const previous: []const u8 = switch (self.field) {
            .pick => return false,
            .action => {
                self.field = .pick;
                self.selected = 0;
                return true;
            },
            .name => return false,
            .base_url => blk: {
                self.field = .name;
                break :blk self.name.items;
            },
            .api_key => blk: {
                self.field = .base_url;
                break :blk self.base_url.items;
            },
            .model_id => blk: {
                if (self.models.items.len == 0) {
                    self.field = .api_key;
                    break :blk self.api_key.items;
                }
                self.field = .model_efforts;
                break :blk self.lastModel().efforts orelse "";
            },
            .model_name => {
                // The model goes back to the front of the walk, details kept.
                const model = self.models.pop().?;
                self.pending.insert(alloc, 0, model) catch |err| {
                    freeModel(alloc, model);
                    return err;
                };
                self.field = .model_id;
                try self.load(alloc, model.id);
                return true;
            },
            .model_context => blk: {
                self.field = .model_name;
                break :blk self.lastModel().name orelse "";
            },
            .model_efforts => blk: {
                self.field = .model_context;
                const tokens = self.lastModel().context orelse break :blk "";
                break :blk std.mem.print(&buf, "{d}", .{tokens}) catch "";
            },
        };
        try self.load(alloc, previous);
        return true;
    }

    /// Commits the focused field and moves to the next one.
    pub fn submit(self: *State, alloc: Allocator) Allocator.Error!Advance {
        const text = std.mem.trim(u8, self.input.items, " \t");
        switch (self.field) {
            .pick => {
                if (self.selected >= self.connections.items.len) {
                    self.field = .name;
                    self.selected = 0;
                    try self.load(alloc, "");
                    return .next;
                }
                if (self.editing) |old| alloc.free(old);
                self.editing = try alloc.dupe(u8, self.connections.items[self.selected]);
                self.field = .action;
                self.selected = 0;
                return .next;
            },
            .action => {
                const choice = self.selected;
                self.selected = 0;
                return switch (choice) {
                    0 => .edit,
                    1 => .delete,
                    else => blk: {
                        self.field = .pick;
                        break :blk .next;
                    },
                };
            },
            .name => {
                configured_provider.validate_id(text) catch |err| return self.refuse(switch (err) {
                    error.ReservedProviderId => "that name is reserved",
                    else => "a name starts with a letter and uses letters, digits, - and _",
                });
                const renamed_onto_other = for (self.connections.items) |existing| {
                    if (std.mem.eql(u8, existing, text) and !(self.editing != null and std.mem.eql(u8, self.editing.?, text))) break true;
                } else false;
                if (renamed_onto_other) return self.refuse("another connection has that name");
                try replace(alloc, &self.name, text);
                self.field = .base_url;
            },
            .base_url => {
                const normalized = configured_provider.validate_url(text) catch |err| return self.refuse(switch (err) {
                    error.InsecureBaseUrl => "use https, or http only for localhost",
                    else => "enter an http or https URL with no query",
                });
                try replace(alloc, &self.base_url, normalized);
                self.field = .api_key;
            },
            .api_key => {
                for (text) |byte| if (byte <= 0x20 or byte >= 0x7f) return self.refuse("the key has a character a header can't carry");
                try replace(alloc, &self.api_key, text);
                if (text.len > 0) if (self.key_env) |env| {
                    alloc.free(env);
                    self.key_env = null;
                };
                self.field = .model_id;
            },
            .model_id => {
                const walking = self.pending.items.len > 0;
                if (text.len == 0) {
                    if (walking) {
                        // An emptied ID deletes the model being walked.
                        freeModel(alloc, self.pending.orderedRemove(0));
                        try self.load(alloc, if (self.pending.items.len > 0) self.pending.items[0].id else "");
                        return .next;
                    }
                    if (self.models.items.len == 0) return self.refuse("add at least one model");
                    self.clearInput();
                    return .finished;
                }
                configured_provider.validate_model_id(text) catch return self.refuse("a model id has no control characters");
                for (self.models.items) |model| {
                    if (std.mem.eql(u8, model.id, text)) return self.refuse("that model is already added");
                }
                if (self.models.items.len >= max_models) return self.refuse("that's as many models as one connection holds");
                const id = try alloc.dupe(u8, text);
                errdefer alloc.free(id);
                var model: Model = if (walking) self.pending.orderedRemove(0) else .{ .id = undefined };
                if (walking) alloc.free(model.id);
                model.id = id;
                self.models.append(alloc, model) catch |err| {
                    if (walking) freeModelDetails(alloc, model);
                    return err;
                };
                self.field = .model_name;
            },
            .model_name => {
                const model = self.lastModel();
                const name: ?[]u8 = if (text.len > 0) try alloc.dupe(u8, text) else null;
                if (model.name) |old| alloc.free(old);
                model.name = name;
                self.field = .model_context;
            },
            .model_context => {
                if (text.len > 0) {
                    const tokens = parseTokens(text) orelse return self.refuse("enter a number of tokens, like 128000 or 128k");
                    self.lastModel().context = tokens;
                } else self.lastModel().context = null;
                self.field = .model_efforts;
            },
            .model_efforts => {
                var names = std.mem.tokenizeAny(u8, text, ", ");
                var count: usize = 0;
                while (names.next()) |level| : (count += 1) {
                    configured_provider.validate_effort_name(level) catch return self.refuse("levels use letters, digits, - _ and ., like low, medium, high");
                }
                if (count > configured_provider.max_effort_levels) return self.refuse("that's more levels than a model can offer");
                const model = self.lastModel();
                const efforts: ?[]u8 = if (count > 0) try alloc.dupe(u8, text) else null;
                if (model.efforts) |old| alloc.free(old);
                model.efforts = efforts;
                self.field = .model_id;
            },
        }
        // Moving forward shows what was already entered in the next field.
        var buf: [16]u8 = undefined;
        const kept: []const u8 = switch (self.field) {
            .base_url => self.base_url.items,
            .api_key => self.api_key.items,
            .model_id => if (self.pending.items.len > 0) self.pending.items[0].id else "",
            .model_name => self.lastModel().name orelse "",
            .model_context => if (self.lastModel().context) |tokens| std.mem.print(&buf, "{d}", .{tokens}) catch "" else "",
            .model_efforts => self.lastModel().efforts orelse "",
            else => "",
        };
        try self.load(alloc, kept);
        return .next;
    }

    pub fn lastModel(self: *State) *Model {
        return &self.models.items[self.models.items.len - 1];
    }

    /// The connection as a `providers.<name>` settings value, allocated in
    /// `arena`. `base` is the saved value being edited: fields the form does
    /// not show, such as headers or a model's request fields, are kept.
    pub fn toJson(self: *const State, arena: Allocator, base: ?std.json.Value) Allocator.Error!std.json.Value {
        var root: std.json.ObjectMap = if (base) |value| (if (value == .object) try value.object.clone(arena) else .empty) else .empty;
        if (!root.contains("protocol")) try root.put(arena, "protocol", .{ .string = "openai-chat-completions" });
        try root.put(arena, "base_url", .{ .string = try arena.dupe(u8, self.base_url.items) });
        var auth: std.json.ObjectMap = .empty;
        if (self.api_key.items.len > 0) {
            try auth.put(arena, "type", .{ .string = "key" });
            try auth.put(arena, "key", .{ .string = try arena.dupe(u8, self.api_key.items) });
        } else if (self.key_env) |env| {
            try auth.put(arena, "type", .{ .string = "bearer" });
            try auth.put(arena, "env", .{ .string = try arena.dupe(u8, env) });
        } else {
            try auth.put(arena, "type", .{ .string = "none" });
        }
        try root.put(arena, "auth", .{ .object = auth });

        const old_metadata: ?std.json.ObjectMap = if (root.get("model_metadata")) |value| (if (value == .object) value.object else null) else null;
        var metadata: std.json.ObjectMap = .empty;
        for (self.models.items) |model| {
            var entry: std.json.ObjectMap = .empty;
            if (old_metadata) |old| if (old.get(model.id)) |value| if (value == .object) {
                entry = try value.object.clone(arena);
            };
            if (model.name) |name|
                try entry.put(arena, "display_name", .{ .string = try arena.dupe(u8, name) })
            else
                _ = entry.orderedRemove("display_name");
            if (model.context) |tokens|
                try entry.put(arena, "context_window", .{ .integer = tokens })
            else
                _ = entry.orderedRemove("context_window");
            if (!entry.contains("supports_tool_use")) try entry.put(arena, "supports_tool_use", .{ .bool = true });
            const unchanged = if (model.efforts) |now| (if (model.original_efforts) |was| std.mem.eql(u8, now, was) else false) else model.original_efforts == null;
            if (!unchanged or !entry.contains("reasoning_efforts")) {
                _ = entry.orderedRemove("reasoning_efforts");
                if (model.efforts) |text| {
                    var levels: std.json.ObjectMap = .empty;
                    var names = std.mem.tokenizeAny(u8, text, ", ");
                    while (names.next()) |level| {
                        var fields: std.json.ObjectMap = .empty;
                        try fields.put(arena, "reasoning_effort", .{ .string = try arena.dupe(u8, level) });
                        try levels.put(arena, try arena.dupe(u8, level), .{ .object = fields });
                    }
                    try entry.put(arena, "reasoning_efforts", .{ .object = levels });
                }
            }
            try metadata.put(arena, try arena.dupe(u8, model.id), .{ .object = entry });
        }
        try root.put(arena, "model_metadata", .{ .object = metadata });
        return .{ .object = root };
    }

    /// The field's hint, shown as a placeholder while it is empty.
    pub fn hint(self: *const State) []const u8 {
        return switch (self.field) {
            .pick, .action => "",
            .name => "letters, digits, - and _, e.g. openrouter",
            .base_url => "e.g. https://openrouter.ai/api/v1",
            .api_key => if (self.key_env != null) "empty keeps the environment variable" else "leave empty for none",
            .model_id => if (self.pending.items.len > 0) "empty deletes this model" else "the id the server expects; empty to save",
            .model_name => "optional",
            .model_context => "optional, e.g. 128k",
            .model_efforts => "optional, e.g. low, medium, high",
        };
    }

    /// Replaces the field's text with `text`, cursor at the end.
    fn load(self: *State, alloc: Allocator, text: []const u8) Allocator.Error!void {
        self.clearInput();
        try self.input.appendSlice(alloc, text);
        self.cursor = self.input.items.len;
        self.problem = null;
    }

    fn removeRange(self: *State, start: usize, end: usize) void {
        const items = self.input.items;
        const tail = items.len - end;
        @memmove(items[start..][0..tail], items[end..]);
        self.input.items.len -= end - start;
    }

    fn previousBoundary(self: *const State, at: usize) usize {
        var i = at;
        while (i > 0) {
            i -= 1;
            if (self.input.items[i] & 0xC0 != 0x80) break;
        }
        return i;
    }

    fn nextBoundary(self: *const State, at: usize) usize {
        var i = at;
        if (i >= self.input.items.len) return i;
        i += 1;
        while (i < self.input.items.len and self.input.items[i] & 0xC0 == 0x80) i += 1;
        return i;
    }

    fn refuse(self: *State, why: []const u8) Advance {
        self.problem = why;
        return .invalid;
    }

    fn clearInput(self: *State) void {
        std.crypto.secureZero(u8, self.input.items);
        self.input.clearRetainingCapacity();
        self.cursor = 0;
    }
};

fn replace(alloc: Allocator, list: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    list.clearRetainingCapacity();
    try list.appendSlice(alloc, text);
}

fn freeModel(alloc: Allocator, model: Model) void {
    alloc.free(model.id);
    freeModelDetails(alloc, model);
}

fn freeModelDetails(alloc: Allocator, model: Model) void {
    if (model.name) |name| alloc.free(name);
    if (model.efforts) |text| alloc.free(text);
    if (model.original_efforts) |text| alloc.free(text);
}

/// `128000`, `128k`, or `1m`.
pub fn parseTokens(text: []const u8) ?u32 {
    if (text.len == 0) return null;
    const last = std.ascii.toLower(text[text.len - 1]);
    const scale: u64 = switch (last) {
        'k' => 1000,
        'm' => 1_000_000,
        else => 1,
    };
    const digits = if (scale == 1) text else text[0 .. text.len - 1];
    const value = std.fmt.parseInt(u64, digits, 10) catch return null;
    const total = std.math.mul(u64, value, scale) catch return null;
    if (total == 0 or total > std.math.maxInt(u32)) return null;
    return @intCast(total);
}

fn typeAndSubmit(state: *State, alloc: Allocator, text: []const u8) !Advance {
    state.clearLine();
    for (text) |byte| try state.appendByte(alloc, byte);
    return state.submit(alloc);
}

test "connect form walks every field and builds a connection" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.close(alloc);
    try state.open(alloc, &.{});
    const steps = [_][]const u8{ "local", "http://localhost:1234/v1/", "sk-test", "qwen", "Qwen 3", "32k", "low, high", "" };
    for (steps, 0..) |text, index| {
        const advance = try typeAndSubmit(&state, alloc, text);
        try std.testing.expectEqual(if (index == steps.len - 1) Advance.finished else Advance.next, advance);
    }
    try std.testing.expectEqualStrings("http://localhost:1234/v1", state.base_url.items);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var providers: std.json.ObjectMap = .empty;
    try providers.put(arena.allocator(), "local", try state.toJson(arena.allocator(), null));
    var registry = try configured_provider.Registry.parse(alloc, .{ .object = providers });
    defer registry.deinit(alloc);
    const definition = registry.get("local").?;
    try std.testing.expectEqualStrings("sk-test", definition.auth.key);
    const model = definition.model("qwen").?;
    try std.testing.expectEqualStrings("Qwen 3", model.display_name.?);
    try std.testing.expectEqual(@as(?u32, 32000), model.context_window);
    try std.testing.expectEqual(@as(usize, 2), model.reasoning_efforts.?.len);
    try std.testing.expectEqualStrings("high", model.reasoning_efforts.?[1].name);
}

test "editing walks saved models, deletes an emptied one, and keeps unshown fields" {
    const alloc = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const saved =
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"bearer","env":"LOCAL_KEY"},
        \\"headers":{"X-Team":{"env":"TEAM"}},
        \\"model_metadata":{"a":{"display_name":"A","max_output_tokens":100,"reasoning_efforts":{"hi":{"reasoning":{"effort":"high"}}}},"b":{}}}}
    ;
    var registry = try configured_provider.Registry.parse_json(alloc, saved);
    defer registry.deinit(alloc);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), saved, .{});

    var state: State = .{};
    defer state.close(alloc);
    try state.open(alloc, &.{"local"});
    try std.testing.expectEqual(Field.pick, state.field);
    try std.testing.expectEqual(Advance.next, try state.submit(alloc));
    try std.testing.expectEqual(Advance.edit, try state.submit(alloc));
    try state.beginEdit(alloc, registry.get("local").?);

    // Keep the name, URL, and key; keep model a as it was; delete model b.
    try std.testing.expectEqualStrings("local", state.input.items);
    _ = try state.submit(alloc);
    _ = try state.submit(alloc);
    _ = try state.submit(alloc);
    try std.testing.expectEqualStrings("a", state.input.items);
    _ = try state.submit(alloc);
    try std.testing.expectEqualStrings("A", state.input.items);
    _ = try state.submit(alloc);
    _ = try state.submit(alloc);
    try std.testing.expectEqualStrings("hi", state.input.items);
    _ = try state.submit(alloc);
    try std.testing.expectEqualStrings("b", state.input.items);
    try std.testing.expectEqual(Advance.next, try typeAndSubmit(&state, alloc, ""));
    try std.testing.expectEqual(Advance.finished, try state.submit(alloc));

    const value = try state.toJson(arena.allocator(), parsed.object.get("local"));
    const object = value.object;
    try std.testing.expectEqualStrings("LOCAL_KEY", object.get("auth").?.object.get("env").?.string);
    try std.testing.expect(object.get("headers") != null);
    const models = object.get("model_metadata").?.object;
    try std.testing.expectEqual(@as(usize, 1), models.count());
    const a = models.get("a").?.object;
    try std.testing.expectEqual(@as(i64, 100), a.get("max_output_tokens").?.integer);
    try std.testing.expect(a.get("reasoning_efforts").?.object.get("hi").?.object.get("reasoning") != null);
}

test "connect form refuses a bad name and an empty model list" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.close(alloc);
    try state.open(alloc, &.{});
    try std.testing.expectEqual(Advance.invalid, try typeAndSubmit(&state, alloc, "9"));
    try std.testing.expect(state.problem != null);
    _ = try typeAndSubmit(&state, alloc, "ok");
    _ = try typeAndSubmit(&state, alloc, "https://x.example/v1");
    _ = try typeAndSubmit(&state, alloc, "");
    try std.testing.expectEqual(Advance.invalid, try typeAndSubmit(&state, alloc, ""));
}

test "parseTokens" {
    try std.testing.expectEqual(@as(?u32, 128000), parseTokens("128k"));
    try std.testing.expectEqual(@as(?u32, 1_000_000), parseTokens("1M"));
    try std.testing.expectEqual(@as(?u32, 4096), parseTokens("4096"));
    try std.testing.expectEqual(@as(?u32, null), parseTokens("0"));
    try std.testing.expectEqual(@as(?u32, null), parseTokens("abc"));
}
