//! State of the `/provider` form. It opens on a list of saved connections
//! with "Add connection" at the end. A connection opens on its fields, one
//! row each: display name, ID, base URL, API key, each model, and "Add
//! model". Enter on a row edits only that field, and Enter again saves it
//! and returns to the list; a model opens on its own fields the same way.
//! A new connection takes its ID first, then the same list with "Create
//! connection". The focused field's text lives here, not in the composer, so
//! the API key never reaches composer history. A subscription account opens
//! on what to do with it; "Edit account" lists its label, name, largest
//! context window, and models, whose name, window, and default reasoning
//! level the person can set over what the plan serves.

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
    /// The level a request uses while the session's effort is `default`.
    model_default_effort,
    /// The label of a new subscription account (`State.plan` says which plan).
    plan_label,
    /// What to do with a saved subscription account.
    plan_account,
    /// The fields of a saved subscription account.
    plan_settings,
    /// The fields of one model of a subscription account.
    plan_model,
    /// A saved subscription account's label, as `Work` in `Claude (Work)`.
    account_label,
    /// The name a subscription account shows in place of its plan's.
    account_name,
    /// The largest context window any model of the account gets.
    context_limit,

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
            .model_default_effort => "Default effort",
            .plan_label, .account_label => "Account label",
            .plan_account => "Subscription",
            .plan_settings => "Account",
            .plan_model => "Model",
            .account_name => "Display name",
            .context_limit => "Max context",
        };
    }

    pub fn isList(self: Field) bool {
        return switch (self) {
            .pick, .overview, .model, .plan_account, .plan_settings, .plan_model => true,
            else => false,
        };
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

/// A row of a subscription account's field list.
pub const PlanRow = union(enum) {
    field: Field,
    model: usize,
    back,
};

/// A row of the action list of a saved subscription account.
pub const PlanAction = enum { use, edit, reconnect, usage, remove, back };

const connection_fields = [_]Field{ .display_name, .name, .base_url, .api_key };
const model_fields = [_]Field{ .model_id, .model_name, .model_context, .model_efforts, .model_default_effort };
const plan_fields = [_]Field{ .account_label, .account_name, .context_limit };
const plan_model_fields = [_]Field{ .model_name, .model_context, .model_default_effort };

pub const Model = struct {
    id: []u8,
    name: ?[]u8 = null,
    context: ?u32 = null,
    /// Level names as typed, such as `low, medium, high`.
    efforts: ?[]u8 = null,
    /// `efforts` when the edit began, so unchanged levels keep the request
    /// fields the settings give them.
    original_efforts: ?[]u8 = null,
    /// The level a request uses while the session's effort is `default`.
    default_effort: ?[]u8 = null,
    /// A subscription model's name and window as its plan serves them. For
    /// such a model `name` and `context` hold only what the person set, and
    /// `efforts` the plan's levels, which the form does not change.
    served_name: ?[]u8 = null,
    served_context: ?u32 = null,
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
    /// A subscription account's label changed: rename it and its models.
    plan_relabel,
    /// Another field of a subscription account changed: save it.
    plan_save,
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
    /// A subscription account's own name, empty for none.
    custom_name: std.ArrayList(u8) = .empty,
    /// A subscription account's label; the typed one waits here for
    /// `plan_relabel` while the saved one stays in the settings.
    account_label: std.ArrayList(u8) = .empty,
    /// The largest context window any of the account's models gets.
    context_limit: ?u32 = null,
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
        self.custom_name.deinit(alloc);
        self.account_label.deinit(alloc);
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
            .plan_account => @typeInfo(PlanAction).@"enum".field_names.len,
            // Fields, models, Add model, Create or Delete, Back.
            .overview => connection_fields.len + self.models.items.len + 3,
            .model => model_fields.len + 2,
            .plan_settings => plan_fields.len + self.models.items.len + 1,
            .plan_model => plan_model_fields.len + 1,
            else => 0,
        };
    }

    pub fn planAction(index: usize) PlanAction {
        return @fromBackingInt(@intCast(@min(index, @typeInfo(PlanAction).@"enum".field_names.len - 1)));
    }

    pub fn planSettingsRow(self: *const State, index: usize) PlanRow {
        if (index < plan_fields.len) return .{ .field = plan_fields[index] };
        const at = index - plan_fields.len;
        return if (at < self.models.items.len) .{ .model = at } else .back;
    }

    pub fn planModelRow(index: usize) PlanRow {
        return if (index < plan_model_fields.len) .{ .field = plan_model_fields[index] } else .back;
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
                try self.loadPlanAccount(alloc, definition);
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
            if (metadata.default_effort) |level| model.default_effort = try alloc.dupe(u8, level);
            try self.models.append(alloc, model);
        }
        self.field = .overview;
        self.selected = 0;
        self.clearInput();
        self.problem = null;
    }

    /// Fills the account fields and its models, with what the person set
    /// apart from what the plan serves.
    fn loadPlanAccount(self: *State, alloc: Allocator, definition: *const configured_provider.Definition) Allocator.Error!void {
        self.clearModels(alloc);
        try replace(alloc, &self.custom_name, definition.custom_name orelse "");
        try replace(alloc, &self.account_label, definition.account_label orelse "");
        self.context_limit = definition.context_limit;
        for (definition.model_metadata[0..@min(definition.model_metadata.len, max_models)]) |metadata| {
            var model: Model = .{ .id = try alloc.dupe(u8, metadata.id) };
            errdefer freeModel(alloc, model);
            if (metadata.display_name) |name| model.served_name = try alloc.dupe(u8, name);
            model.served_context = metadata.context_window;
            if (metadata.reasoning_efforts) |levels| {
                var text: std.ArrayList(u8) = .empty;
                defer text.deinit(alloc);
                for (levels, 0..) |level, index| {
                    if (index > 0) try text.appendSlice(alloc, ", ");
                    try text.appendSlice(alloc, level.name);
                }
                model.efforts = try alloc.dupe(u8, text.items);
            }
            if (definition.override(metadata.id)) |set| {
                if (set.display_name) |name| model.name = try alloc.dupe(u8, name);
                model.context = set.context_window;
                if (set.default_effort) |level| model.default_effort = try alloc.dupe(u8, level);
            }
            try self.models.append(alloc, model);
        }
    }

    /// Refills the account's fields from its saved settings, staying on the
    /// same row.
    pub fn reloadPlanAccount(self: *State, alloc: Allocator, definition: *const configured_provider.Definition) Allocator.Error!void {
        try self.loadPlanAccount(alloc, definition);
        if (self.model_index >= self.models.items.len) self.model_index = 0;
    }

    /// Whether the connection being edited is a subscription account.
    pub fn isPlanAccount(self: *const State) bool {
        const name = self.editing orelse return false;
        for (plans.Kind.all) |kind| if (kind.isId(name)) return true;
        return false;
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
            .plan_settings => {
                self.field = .plan_account;
                self.selected = @backingInt(PlanAction.edit);
            },
            .plan_model => {
                self.field = .plan_settings;
                self.selected = plan_fields.len + self.model_index;
            },
            .account_label, .account_name, .context_limit => self.returnToPlan(self.field),
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
            .model_name, .model_context, .model_default_effort => if (self.isPlanAccount()) self.returnToPlanModel(self.field) else self.returnToModel(self.field),
            .model_efforts => self.returnToModel(self.field),
        }
        self.clearInput();
        return true;
    }

    fn returnToPlan(self: *State, from: Field) void {
        self.field = .plan_settings;
        self.selected = for (plan_fields, 0..) |field, index| {
            if (field == from) break index;
        } else 0;
    }

    fn returnToPlanModel(self: *State, from: Field) void {
        self.field = .plan_model;
        self.selected = for (plan_model_fields, 0..) |field, index| {
            if (field == from) break index;
        } else 0;
    }

    /// Returns to the list the model field `from` belongs to.
    fn returnFromModelField(self: *State, from: Field) void {
        if (self.isPlanAccount()) self.returnToPlanModel(from) else self.returnToModel(from);
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
            .model_default_effort => if (model) |m| m.default_effort orelse "" else "",
            .account_label => self.account_label.items,
            .account_name => self.custom_name.items,
            .context_limit => if (self.context_limit) |tokens| std.mem.print(&buf, "{d}", .{tokens}) catch "" else "",
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
            .plan_account => switch (planAction(self.selected)) {
                .use => return .plan_use,
                .edit => {
                    self.field = .plan_settings;
                    self.selected = 0;
                    return .next;
                },
                .reconnect => return .plan_reconnect,
                .usage => return .plan_usage,
                .remove => return .plan_remove,
                .back => return if (try self.back(alloc)) .next else .close,
            },
            .plan_settings => switch (self.planSettingsRow(self.selected)) {
                .field => |field| {
                    try self.focus(alloc, field);
                    return .next;
                },
                .model => |index| {
                    self.model_index = index;
                    self.field = .plan_model;
                    self.selected = 0;
                    return .next;
                },
                .back => {
                    _ = try self.back(alloc);
                    return .next;
                },
            },
            .plan_model => switch (planModelRow(self.selected)) {
                .field => |field| {
                    try self.focus(alloc, field);
                    return .next;
                },
                else => {
                    _ = try self.back(alloc);
                    return .next;
                },
            },
            .account_label => {
                if (!plans.usableLabel(text)) return self.refuse("a label is 1 to 48 characters, like Work or Personal");
                try replace(alloc, &self.account_label, text);
                self.returnToPlan(.account_label);
                self.clearInput();
                return .plan_relabel;
            },
            .account_name => {
                if (text.len > max_display_name_bytes) return self.refuse("a display name is at most 80 bytes");
                try replace(alloc, &self.custom_name, text);
                self.returnToPlan(.account_name);
                self.clearInput();
                return .plan_save;
            },
            .context_limit => {
                if (text.len > 0) {
                    self.context_limit = parseTokens(text) orelse return self.refuse("enter a number of tokens, like 200000 or 200k");
                } else self.context_limit = null;
                self.returnToPlan(.context_limit);
                self.clearInput();
                return .plan_save;
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
                self.returnFromModelField(.model_name);
            },
            .model_context => {
                const model = &self.models.items[self.model_index];
                if (text.len > 0) {
                    model.context = parseTokens(text) orelse return self.refuse("enter a number of tokens, like 128000 or 128k");
                } else model.context = null;
                self.returnFromModelField(.model_context);
            },
            .model_default_effort => {
                const model = &self.models.items[self.model_index];
                if (text.len > 0) {
                    configured_provider.validate_effort_name(text) catch return self.refuse("a level uses letters, digits, - _ and ., like high");
                    if (model.efforts) |levels| if (!listsLevel(levels, text)) return self.refuse("pick one of the model's reasoning levels");
                }
                const level: ?[]u8 = if (text.len > 0) try alloc.dupe(u8, text) else null;
                if (model.default_effort) |old| alloc.free(old);
                model.default_effort = level;
                self.returnFromModelField(.model_default_effort);
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
                // A default the new levels no longer list goes with them.
                if (model.default_effort) |level| if (efforts != null and !listsLevel(efforts.?, level)) {
                    alloc.free(level);
                    model.default_effort = null;
                };
                self.returnToModel(.model_efforts);
            },
        }
        const plan_field = self.isPlanAccount();
        self.clearInput();
        return if (plan_field) .plan_save else self.committed();
    }

    /// The subscription account's settings value with what the form sets:
    /// its name, largest window, and each model's overrides. `base` is the
    /// saved value; everything else in it is kept. Allocated in `arena`.
    pub fn planToJson(self: *const State, arena: Allocator, base: std.json.Value) Allocator.Error!std.json.Value {
        var root: std.json.ObjectMap = if (base == .object) try base.object.clone(arena) else .empty;
        if (self.custom_name.items.len > 0)
            try root.put(arena, "custom_name", .{ .string = try arena.dupe(u8, self.custom_name.items) })
        else
            _ = root.orderedRemove("custom_name");
        if (self.context_limit) |tokens|
            try root.put(arena, "context_limit", .{ .integer = tokens })
        else
            _ = root.orderedRemove("context_limit");
        // Overrides of models the form does not list stay as they were.
        var overrides: std.json.ObjectMap = if (root.get("model_overrides")) |value| (if (value == .object) try value.object.clone(arena) else .empty) else .empty;
        for (self.models.items) |model| {
            var entry: std.json.ObjectMap = .empty;
            if (model.name) |name| try entry.put(arena, "display_name", .{ .string = try arena.dupe(u8, name) });
            if (model.context) |tokens| try entry.put(arena, "context_window", .{ .integer = tokens });
            if (model.default_effort) |level| try entry.put(arena, "default_effort", .{ .string = try arena.dupe(u8, level) });
            if (entry.count() > 0)
                try overrides.put(arena, try arena.dupe(u8, model.id), .{ .object = entry })
            else
                _ = overrides.orderedRemove(model.id);
        }
        if (overrides.count() > 0)
            try root.put(arena, "model_overrides", .{ .object = overrides })
        else
            _ = root.orderedRemove("model_overrides");
        return .{ .object = root };
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
            if (model.default_effort) |level|
                try entry.put(arena, "default_effort", .{ .string = try arena.dupe(u8, level) })
            else
                _ = entry.orderedRemove("default_effort");
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
            .pick, .overview, .model, .plan_account, .plan_settings, .plan_model => "",
            .plan_label => "optional, e.g. Work or Personal",
            .account_label => "e.g. Work or Personal",
            .account_name => "optional, shown in place of the plan's name",
            .context_limit => "optional, e.g. 200k; caps every model",
            .model_default_effort => if (self.model_index < self.models.items.len) (self.models.items[self.model_index].efforts orelse "optional, e.g. high") else "optional, e.g. high",
            .display_name => "optional, e.g. OpenCode Go",
            .name => "letters, digits, - and _, e.g. openrouter",
            .base_url => "e.g. https://openrouter.ai/api/v1",
            .api_key => if (self.key_env != null) "empty keeps the environment variable" else "leave empty for none",
            .model_id => "the id the server expects",
            .model_name => if (self.isPlanAccount()) "empty keeps the plan's name" else "optional",
            .model_context => if (self.isPlanAccount()) "empty keeps the plan's window, e.g. 200k" else "optional, e.g. 128k",
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
    if (model.default_effort) |text| alloc.free(text);
    if (model.served_name) |text| alloc.free(text);
}

/// Whether the typed levels `levels`, like `low, high`, include `level`.
fn listsLevel(levels: []const u8, level: []const u8) bool {
    var names = std.mem.tokenizeAny(u8, levels, ", ");
    while (names.next()) |name| if (std.mem.eql(u8, name, level)) return true;
    return false;
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
    state.selected = 5;
    try std.testing.expectEqual(ModelRow.delete, State.modelRow(state.selected));
    try std.testing.expectEqual(Advance.invalid, try state.submit(alloc));
}

test "a subscription account edits its name, largest window, and a model's default effort" {
    const alloc = std.testing.allocator;
    const id = "claude-plan-00000000000000000000000000000001";
    var state: State = .{};
    defer state.close(alloc);
    try state.open(alloc, &.{id});
    try std.testing.expectEqual(Advance.edit, try state.submit(alloc));
    const levels = [_]configured_provider.EffortLevel{ .{ .name = "low", .fields = .{} }, .{ .name = "high", .fields = .{} } };
    const definition: configured_provider.Definition = .{
        .id = id,
        .protocol = .@"anthropic-messages",
        .base_url = "https://api.anthropic.com/v1",
        .auth = .claude_plan,
        .display_name = "Claude",
        .account_label = "1",
        .model_metadata = &.{.{ .id = "m1", .display_name = "M1", .context_window = 1_000_000, .reasoning_efforts = &levels }},
    };
    try state.beginEdit(alloc, &definition);
    try std.testing.expectEqual(Field.plan_account, state.field);
    state.selected = @backingInt(PlanAction.edit);
    try std.testing.expectEqual(Advance.next, try state.submit(alloc));
    try std.testing.expectEqual(Field.plan_settings, state.field);
    try std.testing.expectEqual(PlanRow{ .model = 0 }, state.planSettingsRow(plan_fields.len));

    state.selected = 1;
    _ = try state.submit(alloc);
    try std.testing.expectEqual(Field.account_name, state.field);
    try std.testing.expectEqual(Advance.plan_save, try typeAndSubmit(&state, alloc, "Main"));
    state.selected = 2;
    _ = try state.submit(alloc);
    try std.testing.expectEqual(Advance.invalid, try typeAndSubmit(&state, alloc, "lots"));
    try std.testing.expectEqual(Advance.plan_save, try typeAndSubmit(&state, alloc, "200k"));
    try std.testing.expectEqual(Field.plan_settings, state.field);

    state.selected = plan_fields.len;
    _ = try state.submit(alloc);
    try std.testing.expectEqual(Field.plan_model, state.field);
    state.selected = 2;
    _ = try state.submit(alloc);
    try std.testing.expectEqual(Field.model_default_effort, state.field);
    try std.testing.expectEqual(Advance.invalid, try typeAndSubmit(&state, alloc, "max"));
    try std.testing.expectEqual(Advance.plan_save, try typeAndSubmit(&state, alloc, "high"));
    try std.testing.expectEqual(Field.plan_model, state.field);
    try std.testing.expect(try state.back(alloc));
    try std.testing.expectEqual(Field.plan_settings, state.field);

    state.selected = 0;
    _ = try state.submit(alloc);
    try std.testing.expectEqual(Advance.plan_relabel, try typeAndSubmit(&state, alloc, "Work"));
    try std.testing.expectEqualStrings("Work", state.account_label.items);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var base: std.json.ObjectMap = .empty;
    try base.put(arena.allocator(), "display_name", .{ .string = "Claude" });
    const value = try state.planToJson(arena.allocator(), .{ .object = base });
    try std.testing.expectEqualStrings("Claude", value.object.get("display_name").?.string);
    try std.testing.expectEqualStrings("Main", value.object.get("custom_name").?.string);
    try std.testing.expectEqual(@as(i64, 200_000), value.object.get("context_limit").?.integer);
    const override = value.object.get("model_overrides").?.object.get("m1").?.object;
    try std.testing.expectEqualStrings("high", override.get("default_effort").?.string);
    try std.testing.expect(override.get("display_name") == null);
}

test "a custom model's default effort follows its levels" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.close(alloc);
    try state.open(alloc, &.{"oc"});
    _ = try state.submit(alloc);
    const levels = [_]configured_provider.EffortLevel{ .{ .name = "low", .fields = .{} }, .{ .name = "high", .fields = .{} } };
    const definition: configured_provider.Definition = .{
        .id = "oc",
        .protocol = .@"openai-chat-completions",
        .base_url = "https://example.com/v1",
        .auth = .none,
        .model_metadata = &.{.{ .id = "m1", .reasoning_efforts = &levels, .default_effort = "high" }},
    };
    try state.beginEdit(alloc, &definition);
    try std.testing.expectEqualStrings("high", state.models.items[0].default_effort.?);
    state.selected = connection_fields.len;
    _ = try state.submit(alloc);
    try std.testing.expectEqual(Field.model, state.field);
    state.selected = 3;
    _ = try state.submit(alloc);
    try std.testing.expectEqual(Field.model_efforts, state.field);
    // Levels without the default drop it.
    try std.testing.expectEqual(Advance.save, try typeAndSubmit(&state, alloc, "low, medium"));
    try std.testing.expect(state.models.items[0].default_effort == null);
    state.selected = 4;
    _ = try state.submit(alloc);
    try std.testing.expectEqual(Field.model_default_effort, state.field);
    try std.testing.expectEqual(Advance.save, try typeAndSubmit(&state, alloc, "medium"));
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const value = try state.toJson(arena.allocator(), null);
    const model = value.object.get("model_metadata").?.object.get("m1").?.object;
    try std.testing.expectEqualStrings("medium", model.get("default_effort").?.string);
}
