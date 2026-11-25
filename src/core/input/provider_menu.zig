//! State of the `/provider` form. It opens on a list of saved connections
//! with "Add connection" at the end. A connection opens on its fields, one
//! row each: display name, ID, base URL, API key, each model, and "Add
//! model". Enter on a row edits only that field, and Enter again saves it
//! and returns to the list; a model opens on its own fields the same way.
//! A new connection takes its ID first, then the same list with "Create
//! connection". The focused field's text lives here, not in the composer, so
//! the API key never reaches composer history.

const std = @import("std");
const configured_provider = @import("../config/configured_provider.zig");
const plans = @import("../config/plan_connection.zig");

const Allocator = std.mem.Allocator;

pub const max_models = 32;
pub const max_connections = 32;
const max_field_bytes = 2048;
const max_display_name_bytes = 80;

pub const Field = enum {
    /// The list of connections.
    pick,
    /// The fields of one connection.
    overview,
    /// The fields of one model.
    model,
    display_name,
    name,
    base_url,
    api_key,
    model_id,
    model_name,
    model_context,
    model_efforts,
    /// The label of a new subscription account (`State.plan` says which plan).
    plan_label,
    /// What to do with a saved subscription account.
    plan_account,

    pub fn label(self: Field) []const u8 {
        return switch (self) {
            .pick => "Connections",
            .overview => "Connection",
            .model => "Model",
            .display_name => "Display name",
            .name => "ID",
            .base_url => "Base URL",
            .api_key => "API key",
            .model_id => "Model ID",
            .model_name => "Display name",
            .model_context => "Context window",
            .model_efforts => "Reasoning levels",
            .plan_label => "Account label",
            .plan_account => "Subscription",
        };
    }

    pub fn isList(self: Field) bool {
        return self == .pick or self == .overview or self == .model or self == .plan_account;
    }
};

/// A row of the connection's field list.
pub const OverviewRow = union(enum) {
    field: Field,
    model: usize,
    add_model,
    create,
    delete,
    back,
};

/// A row of a model's field list.
pub const ModelRow = union(enum) {
    field: Field,
    delete,
    back,
};

const connection_fields = [_]Field{ .display_name, .name, .base_url, .api_key };
const model_fields = [_]Field{ .model_id, .model_name, .model_context, .model_efforts };

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
pub const Advance = enum {
    next,
    invalid,
    /// A saved connection changed: save it and stay in the form.
    save,
    /// "Create connection" on a new one: save it, close, and switch to it.
    create,
    /// A saved connection was picked: load its fields.
    edit,
    delete,
    plan_connect,
    plan_use,
    plan_reconnect,
    plan_remove,
    plan_usage,
    /// The form has nothing left to go back to.
    close,
};

/// Call `close` with the allocator passed to `open`.
pub const State = struct {
    active: bool = false,
    field: Field = .name,
    input: std.ArrayList(u8) = .empty,
    /// Byte offset of the cursor in `input`, on a UTF-8 boundary.
    cursor: usize = 0,
    display_name: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    base_url: std.ArrayList(u8) = .empty,
    api_key: std.ArrayList(u8) = .empty,
    /// The environment variable an edited connection reads its key from;
    /// kept while the key field stays empty.
    key_env: ?[]u8 = null,
    models: std.ArrayList(Model) = .empty,
    /// The model `.model` and the model fields describe; `models.len` while
    /// a new model's ID is typed.
    model_index: usize = 0,
    /// Saved connection names for the list.
    connections: std.ArrayList([]u8) = .empty,
    /// Each connection's display name, in `connections` order, or null.
    labels: std.ArrayList(?[]u8) = .empty,
    /// The highlighted row of a list.
    selected: usize = 0,
    /// The saved name of the connection being edited, or null for a new one.
    editing: ?[]u8 = null,
    /// Why the last Enter was refused; static text.
    problem: ?[]const u8 = null,
    /// Set after a field was saved; cleared by the next key.
    saved: bool = false,
    /// The subscription plan the plan fields are about.
    plan: plans.Kind = .chatgpt,
    plan_job: ?*plans.Job = null,

    /// Opens on the list of available connections and connection types.
    pub fn open(self: *State, alloc: Allocator, names: []const []const u8) Allocator.Error!void {
        self.close(alloc);
        self.active = true;
        for (names[0..@min(names.len, max_connections)]) |name| {
            const copy = try alloc.dupe(u8, name);
            errdefer alloc.free(copy);
            try self.connections.append(alloc, copy);
        }
        self.field = .pick;
    }

    /// Sets the display names shown beside the connections `open` listed.
    pub fn setLabels(self: *State, alloc: Allocator, labels: []const ?[]const u8) Allocator.Error!void {
        for (self.labels.items) |label| if (label) |text| alloc.free(text);
        self.labels.clearRetainingCapacity();
        for (labels[0..@min(labels.len, self.connections.items.len)]) |label| {
            const copy: ?[]u8 = if (label) |text| try alloc.dupe(u8, text) else null;
            errdefer if (copy) |text| alloc.free(text);
            try self.labels.append(alloc, copy);
        }
    }

    /// The text a list row shows for connection `index`.
    pub fn connectionLabel(self: *const State, index: usize) ?[]const u8 {
        return if (index < self.labels.items.len) self.labels.items[index] else null;
    }

    pub fn close(self: *State, alloc: Allocator) void {
        if (self.plan_job) |job| job.close();
        self.clearInput();
        self.input.deinit(alloc);
        self.display_name.deinit(alloc);
        self.name.deinit(alloc);
        std.crypto.secureZero(u8, self.api_key.items);
        self.api_key.deinit(alloc);
        self.base_url.deinit(alloc);
        if (self.key_env) |env| alloc.free(env);
        self.clearModels(alloc);
        self.models.deinit(alloc);
        for (self.connections.items) |name| alloc.free(name);
        self.connections.deinit(alloc);
        for (self.labels.items) |label| if (label) |text| alloc.free(text);
        self.labels.deinit(alloc);
        if (self.editing) |name| alloc.free(name);
        self.* = .{};
    }

    fn clearModels(self: *State, alloc: Allocator) void {
        for (self.models.items) |model| freeModel(alloc, model);
        self.models.clearRetainingCapacity();
    }

    /// The plan whose "Continue with" row of the connection list is `row`.
    pub fn planAt(self: *const State, row: usize) ?plans.Kind {
        const first = self.connections.items.len + 1;
        if (row < first or row - first >= plans.Kind.all.len) return null;
        return plans.Kind.all[row - first];
    }

    pub fn planRow(self: *const State, kind: plans.Kind) usize {
        return self.connections.items.len + 1 + @backingInt(kind);
    }

    /// Rows of the current list.
    pub fn listLen(self: *const State) usize {
        return switch (self.field) {
            // Connections, Add connection, then a row for each plan.
            .pick => self.connections.items.len + 1 + plans.Kind.all.len,
            .plan_account => 5,
            // Fields, models, Add model, Create or Delete, Back.
            .overview => connection_fields.len + self.models.items.len + 3,
            .model => model_fields.len + 2,
            else => 0,
        };
    }

    pub fn overviewRow(self: *const State, index: usize) OverviewRow {
        if (index < connection_fields.len) return .{ .field = connection_fields[index] };
        const at = index - connection_fields.len;
        const count = self.models.items.len;
        if (at < count) return .{ .model = at };
        return switch (at - count) {
            0 => .add_model,
            1 => if (self.editing == null) .create else .delete,
            else => .back,
        };
    }

    pub fn modelRow(index: usize) ModelRow {
        if (index < model_fields.len) return .{ .field = model_fields[index] };
        return if (index == model_fields.len) .delete else .back;
    }

    pub fn move(self: *State, delta: i32) void {
        const len = self.listLen();
        if (len == 0) return;
        const count: i64 = @intCast(len);
        self.selected = @intCast(@mod(@as(i64, @intCast(self.selected)) + delta, count));
        self.problem = null;
        self.saved = false;
    }

    /// The connection picked in the list.
    pub fn pickedName(self: *const State) ?[]const u8 {
        return self.editing;
    }

    /// Fills the form from a saved connection and shows its fields.
    pub fn beginEdit(self: *State, alloc: Allocator, definition: *const configured_provider.Definition) Allocator.Error!void {
        try replace(alloc, &self.name, definition.id);
        try replace(alloc, &self.display_name, definition.display_name orelse "");
        try replace(alloc, &self.base_url, definition.base_url);
        std.crypto.secureZero(u8, self.api_key.items);
        self.api_key.clearRetainingCapacity();
        if (self.key_env) |env| alloc.free(env);
        self.key_env = null;
        switch (definition.auth) {
            .chatgpt_plan, .claude_plan, .antigravity_plan => {
                self.clearModels(alloc);
                self.plan = definition.auth.plan().?;
                self.field = .plan_account;
                self.selected = 0;
                self.clearInput();
                self.problem = null;
                return;
            },
            .none => {},
            .key => |key| try replace(alloc, &self.api_key, key),
            .bearer => |env| self.key_env = try alloc.dupe(u8, env),
        }
        self.clearModels(alloc);
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
            try self.models.append(alloc, model);
        }
        self.field = .overview;
        self.selected = 0;
        self.clearInput();
        self.problem = null;
    }

    /// Records that the connection was saved under its current name.
    pub fn markSaved(self: *State, alloc: Allocator) Allocator.Error!void {
        const name = try alloc.dupe(u8, self.name.items);
        if (self.editing) |old| {
            for (self.connections.items) |*entry| if (std.mem.eql(u8, entry.*, old)) {
                const copy = try alloc.dupe(u8, name);
                alloc.free(entry.*);
                entry.* = copy;
            };
            alloc.free(old);
        }
        self.editing = name;
        for (self.models.items) |*model| {
            if (model.original_efforts) |was| alloc.free(was);
            model.original_efforts = if (model.efforts) |now| try alloc.dupe(u8, now) else null;
        }
        self.saved = true;
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

    /// Leaves the field or list without saving. Returns false when there is
    /// nowhere to go back to.
    pub fn back(self: *State, alloc: Allocator) Allocator.Error!bool {
        _ = alloc;
        self.problem = null;
        self.saved = false;
        switch (self.field) {
            .pick => return false,
            .plan_label, .plan_account => {
                self.selected = self.connectionIndex() orelse self.planRow(self.plan);
                self.field = .pick;
            },
            .overview => {
                if (self.connections.items.len == 0) return false;
                self.field = .pick;
                self.selected = self.connectionIndex() orelse 0;
            },
            .model => {
                self.field = .overview;
                self.selected = connection_fields.len + self.model_index;
            },
            .name => {
                // A new connection's first step.
                if (self.editing == null and self.models.items.len == 0 and self.base_url.items.len == 0) {
                    self.field = .pick;
                    self.selected = self.connections.items.len;
                } else self.returnToOverview(.name);
            },
            .display_name, .base_url, .api_key => self.returnToOverview(self.field),
            .model_id => if (self.model_index >= self.models.items.len) {
                self.field = .overview;
                self.selected = connection_fields.len + self.models.items.len;
            } else self.returnToModel(.model_id),
            .model_name, .model_context, .model_efforts => self.returnToModel(self.field),
        }
        self.clearInput();
        return true;
    }

    fn connectionIndex(self: *const State) ?usize {
        const name = self.editing orelse return null;
        for (self.connections.items, 0..) |entry, index| if (std.mem.eql(u8, entry, name)) return index;
        return null;
    }

    fn returnToOverview(self: *State, from: Field) void {
        self.field = .overview;
        self.selected = for (connection_fields, 0..) |field, index| {
            if (field == from) break index;
        } else 0;
    }

    fn returnToModel(self: *State, from: Field) void {
        self.field = .model;
        self.selected = for (model_fields, 0..) |field, index| {
            if (field == from) break index;
        } else 0;
    }

    /// Opens a field for typing with its current value.
    fn focus(self: *State, alloc: Allocator, field: Field) Allocator.Error!void {
        self.field = field;
        self.problem = null;
        self.saved = false;
        var buf: [16]u8 = undefined;
        const model: ?*Model = if (self.model_index < self.models.items.len) &self.models.items[self.model_index] else null;
        const value: []const u8 = switch (field) {
            .display_name => self.display_name.items,
            .name => self.name.items,
            .base_url => self.base_url.items,
            .api_key => self.api_key.items,
            .model_id => if (model) |m| m.id else "",
            .model_name => if (model) |m| m.name orelse "" else "",
            .model_context => if (model) |m| (if (m.context) |tokens| std.mem.print(&buf, "{d}", .{tokens}) catch "" else "") else "",
            .model_efforts => if (model) |m| m.efforts orelse "" else "",
            else => "",
        };
        try self.load(alloc, value);
    }

    /// After a field is committed: a saved connection saves at once, a new
    /// one waits for "Create connection".
    fn committed(self: *const State) Advance {
        return if (self.editing != null) .save else .next;
    }

    /// Enter: opens the highlighted row, or commits the field being typed.
    pub fn submit(self: *State, alloc: Allocator) Allocator.Error!Advance {
        const text = std.mem.trim(u8, self.input.items, " \t");
        self.saved = false;
        switch (self.field) {
            .pick => {
                if (self.planAt(self.selected)) |kind| {
                    if (self.editing) |old| alloc.free(old);
                    self.editing = null;
                    self.name.clearRetainingCapacity();
                    self.display_name.clearRetainingCapacity();
                    self.plan = kind;
                    try self.focus(alloc, .plan_label);
                    return .next;
                }
                if (self.selected == self.connections.items.len) {
                    self.clearModels(alloc);
                    self.display_name.clearRetainingCapacity();
                    self.base_url.clearRetainingCapacity();
                    self.api_key.clearRetainingCapacity();
                    if (self.key_env) |env| alloc.free(env);
                    self.key_env = null;
                    if (self.editing) |old| alloc.free(old);
                    self.editing = null;
                    try self.focus(alloc, .name);
                    self.input.clearRetainingCapacity();
                    self.cursor = 0;
                    return .next;
                }
                if (self.editing) |old| alloc.free(old);
                self.editing = try alloc.dupe(u8, self.connections.items[self.selected]);
                return .edit;
            },
            .plan_label => return .plan_connect,
            .plan_account => switch (self.selected) {
                0 => return .plan_use,
                1 => return .plan_reconnect,
                2 => return .plan_usage,
                3 => return .plan_remove,
                else => return if (try self.back(alloc)) .next else .close,
            },
            .overview => switch (self.overviewRow(self.selected)) {
                .field => |field| {
                    try self.focus(alloc, field);
                    return .next;
                },
                .model => |index| {
                    self.model_index = index;
                    self.field = .model;
                    self.selected = 0;
                    return .next;
                },
                .add_model => {
                    if (self.models.items.len >= max_models) return self.refuse("that's as many models as one connection holds");
                    self.model_index = self.models.items.len;
                    try self.focus(alloc, .model_id);
                    return .next;
                },
                .create => {
                    if (self.base_url.items.len == 0) return self.refuse("set the base URL first");
                    if (self.models.items.len == 0) return self.refuse("add at least one model first");
                    return .create;
                },
                .delete => return .delete,
                .back => return if (try self.back(alloc)) .next else .close,
            },
            .model => switch (modelRow(self.selected)) {
                .field => |field| {
                    try self.focus(alloc, field);
                    return .next;
                },
                .delete => {
                    if (self.models.items.len <= 1 and self.editing != null) return self.refuse("a connection needs at least one model");
                    freeModel(alloc, self.models.orderedRemove(self.model_index));
                    self.field = .overview;
                    self.selected = connection_fields.len + @min(self.model_index, self.models.items.len);
                    return self.committed();
                },
                .back => {
                    _ = try self.back(alloc);
                    return .next;
                },
            },
            .display_name => {
                if (text.len > max_display_name_bytes) return self.refuse("a display name is at most 80 bytes");
                try replace(alloc, &self.display_name, text);
                self.returnToOverview(.display_name);
            },
            .name => {
                configured_provider.validate_id(text) catch |err| return self.refuse(switch (err) {
                    error.ReservedProviderId => "that ID is reserved",
                    else => "an ID starts with a letter and uses letters, digits, - and _",
                });
                const taken = for (self.connections.items) |existing| {
                    if (std.mem.eql(u8, existing, text) and !(self.editing != null and std.mem.eql(u8, self.editing.?, text))) break true;
                } else false;
                if (taken) return self.refuse("another connection has that ID");
                try replace(alloc, &self.name, text);
                self.returnToOverview(.name);
                // A new connection goes on to its endpoint.
                if (self.editing == null and self.base_url.items.len == 0) self.selected = 2;
            },
            .base_url => {
                const normalized = configured_provider.validate_url(text) catch |err| return self.refuse(switch (err) {
                    error.InsecureBaseUrl => "use https, or http only for localhost",
                    else => "enter an http or https URL with no query",
                });
                try replace(alloc, &self.base_url, normalized);
                self.returnToOverview(.base_url);
            },
            .api_key => {
                for (text) |byte| if (byte <= 0x20 or byte >= 0x7f) return self.refuse("the key has a character a header can't carry");
                try replace(alloc, &self.api_key, text);
                if (text.len > 0) if (self.key_env) |env| {
                    alloc.free(env);
                    self.key_env = null;
                };
                self.returnToOverview(.api_key);
            },
            .model_id => {
                if (text.len == 0) return self.refuse("enter the id the server expects");
                configured_provider.validate_model_id(text) catch return self.refuse("a model id has no control characters");
                for (self.models.items, 0..) |model, index| {
                    if (index != self.model_index and std.mem.eql(u8, model.id, text)) return self.refuse("that model is already added");
                }
                const id = try alloc.dupe(u8, text);
                if (self.model_index < self.models.items.len) {
                    const model = &self.models.items[self.model_index];
                    alloc.free(model.id);
                    model.id = id;
                    self.returnToModel(.model_id);
                } else {
                    self.models.append(alloc, .{ .id = id }) catch |err| {
                        alloc.free(id);
                        return err;
                    };
                    self.model_index = self.models.items.len - 1;
                    self.field = .model;
                    self.selected = 1;
                }
            },
            .model_name => {
                if (text.len > max_display_name_bytes) return self.refuse("a display name is at most 80 bytes");
                const model = &self.models.items[self.model_index];
                const name: ?[]u8 = if (text.len > 0) try alloc.dupe(u8, text) else null;
                if (model.name) |old| alloc.free(old);
                model.name = name;
                self.returnToModel(.model_name);
            },
            .model_context => {
                const model = &self.models.items[self.model_index];
                if (text.len > 0) {
                    model.context = parseTokens(text) orelse return self.refuse("enter a number of tokens, like 128000 or 128k");
                } else model.context = null;
                self.returnToModel(.model_context);
            },
            .model_efforts => {
                var names = std.mem.tokenizeAny(u8, text, ", ");
                var count: usize = 0;
                while (names.next()) |level| : (count += 1) {
                    configured_provider.validate_effort_name(level) catch return self.refuse("levels use letters, digits, - _ and ., like low, medium, high");
                }
                if (count > configured_provider.max_effort_levels) return self.refuse("that's more levels than a model can offer");
                const model = &self.models.items[self.model_index];
                const efforts: ?[]u8 = if (count > 0) try alloc.dupe(u8, text) else null;
                if (model.efforts) |old| alloc.free(old);
                model.efforts = efforts;
                self.returnToModel(.model_efforts);
            },
        }
        self.clearInput();
        return self.committed();
    }

    /// The connection as a `providers.<name>` settings value, allocated in
    /// `arena`. `base` is the saved value being edited: fields the form does
    /// not show, such as headers or a model's request fields, are kept.
    pub fn toJson(self: *const State, arena: Allocator, base: ?std.json.Value) Allocator.Error!std.json.Value {
        var root: std.json.ObjectMap = if (base) |value| (if (value == .object) try value.object.clone(arena) else .empty) else .empty;
        if (!root.contains("protocol")) try root.put(arena, "protocol", .{ .string = "openai-chat-completions" });
        if (self.display_name.items.len > 0)
            try root.put(arena, "display_name", .{ .string = try arena.dupe(u8, self.display_name.items) })
        else
            _ = root.orderedRemove("display_name");
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
            .pick, .overview, .model, .plan_account => "",
            .plan_label => "optional, e.g. Work or Personal",
            .display_name => "optional, e.g. OpenCode Go",
            .name => "letters, digits, - and _, e.g. openrouter",
            .base_url => "e.g. https://openrouter.ai/api/v1",
            .api_key => if (self.key_env != null) "empty keeps the environment variable" else "leave empty for none",
            .model_id => "the id the server expects",
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

test "a new connection takes its ID, then each field from the list" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.close(alloc);
    try state.open(alloc, &.{});
    try std.testing.expectEqual(Field.pick, state.field);
    try std.testing.expectEqual(Advance.next, try state.submit(alloc));
    try std.testing.expectEqual(Field.name, state.field);
    try std.testing.expectEqual(Advance.next, try typeAndSubmit(&state, alloc, "oc-go"));
    try std.testing.expectEqual(Field.overview, state.field);
    // Create is refused until the connection has an endpoint and a model.
    state.selected = state.listLen() - 2;
    try std.testing.expectEqual(OverviewRow.create, state.overviewRow(state.selected));
    try std.testing.expectEqual(Advance.invalid, try state.submit(alloc));
    state.selected = 2;
    _ = try state.submit(alloc);
    try std.testing.expectEqual(Field.base_url, state.field);
    try std.testing.expectEqual(Advance.next, try typeAndSubmit(&state, alloc, "https://example.com/v1"));
    try std.testing.expectEqual(Field.overview, state.field);
    state.selected = 4;
    try std.testing.expectEqual(OverviewRow.add_model, state.overviewRow(state.selected));
    _ = try state.submit(alloc);
    try std.testing.expectEqual(Advance.next, try typeAndSubmit(&state, alloc, "m1"));
    try std.testing.expectEqual(Field.model, state.field);
    try std.testing.expect(try state.back(alloc));
    state.selected = state.listLen() - 2;
    try std.testing.expectEqual(Advance.create, try state.submit(alloc));
}

test "editing a saved connection changes one field and saves" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.close(alloc);
    try state.open(alloc, &.{"oc"});
    try std.testing.expectEqual(Advance.edit, try state.submit(alloc));
    const definition: configured_provider.Definition = .{
        .id = "oc",
        .protocol = .@"openai-chat-completions",
        .base_url = "https://example.com/v1",
        .auth = .none,
        .model_metadata = &.{.{ .id = "m1" }},
    };
    try state.beginEdit(alloc, &definition);
    try std.testing.expectEqual(Field.overview, state.field);
    state.selected = 0;
    _ = try state.submit(alloc);
    try std.testing.expectEqual(Field.display_name, state.field);
    try std.testing.expectEqual(Advance.save, try typeAndSubmit(&state, alloc, "OpenCode Go"));
    try std.testing.expectEqual(Field.overview, state.field);
    try std.testing.expectEqualStrings("OpenCode Go", state.display_name.items);
    // The only model can't be deleted from a saved connection.
    state.selected = 4;
    _ = try state.submit(alloc);
    try std.testing.expectEqual(Field.model, state.field);
    state.selected = 4;
    try std.testing.expectEqual(ModelRow.delete, State.modelRow(state.selected));
    try std.testing.expectEqual(Advance.invalid, try state.submit(alloc));
}
