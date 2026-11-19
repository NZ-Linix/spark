//! `/connect`: routes keys to the connection form, saves the finished
//! connection under `providers` in the profile settings, reloads the
//! connection list, and switches to the new connection.

const std = @import("std");
const agents = @import("../agents/agents.zig");
const config_runtime = @import("../config/config_runtime.zig");
const configured_provider = @import("../config/configured_provider.zig");
const model_provider = @import("../config/model_provider.zig");
const settings_store = @import("../config/settings_store.zig");
const app_auth_runtime = @import("app_auth_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};

        /// Takes every byte while the form is open. Returns false when it is
        /// closed.
        pub fn routeByte(app: *App, agent: *AppAgent, byte: u8) !bool {
            const form = &app.input_runtime.connect_menu;
            if (!form.active) return false;
            // Escape starts an arrow key, a paste, or Esc itself; the input
            // decoder turns it into an action for `routeAction`.
            if (byte == 0x1b) return false;
            switch (byte) {
                3 => form.close(app.alloc),
                '\r', '\n' => try submit(app, agent),
                8, 127 => form.deleteByte(),
                1 => form.moveHome(),
                5 => form.moveEnd(),
                21 => form.clearLine(),
                '\t' => try submit(app, agent),
                else => try form.appendByte(app.alloc, byte),
            }
            app.shell.render_requests.request(.footer);
            return true;
        }

        /// Takes decoded keys while the form is open: arrows move the cursor
        /// or between fields. Returns false for actions the form leaves to
        /// the rest of the input path, such as Esc and pastes.
        pub fn routeAction(app: *App, agent: *AppAgent, action: anytype) !bool {
            const form = &app.input_runtime.connect_menu;
            if (!form.active) return false;
            switch (action) {
                .escape, .paste_start, .paste_end, .remapped_byte => return false,
                .word_left => form.moveLeft(),
                .cursor_right, .word_right => form.moveRight(),
                .home => form.moveHome(),
                .end => form.moveEnd(),
                .delete_next => form.deleteNext(),
                .delete_to_line_start, .clear_line => form.clearLine(),
                .cursor_up, .history_up => if (form.field.isList()) form.move(-1) else {
                    _ = try form.back(app.alloc);
                },
                .cursor_down, .history_down => if (form.field.isList()) form.move(1) else try submit(app, agent),
                .cursor_left => if (form.field.isList()) {
                    _ = try form.back(app.alloc);
                } else form.moveLeft(),
                else => {},
            }
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn submit(app: *App, agent: *AppAgent) !void {
            const form = &app.input_runtime.connect_menu;
            switch (try form.submit(app.alloc)) {
                .next, .invalid => {},
                .finished => try saveConnection(app, agent),
                .edit => {
                    const name = form.editing orelse return;
                    const definition = app.provider_selection.definitions.get(name) orelse {
                        form.problem = "that connection is no longer in the settings";
                        return;
                    };
                    try form.beginEdit(app.alloc, definition);
                },
                .delete => try deleteConnection(app, agent),
            }
        }

        /// Opens the form on the saved connections.
        pub fn open(app: *App) !void {
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(app.alloc);
            for (app.provider_selection.definitions.definitions) |definition| try names.append(app.alloc, definition.id);
            try app.input_runtime.connect_menu.open(app.alloc, names.items);
        }

        /// Closes the form without saving. Returns whether it was open.
        pub fn cancel(app: *App) bool {
            const form = &app.input_runtime.connect_menu;
            if (!form.active) return false;
            form.close(app.alloc);
            return true;
        }

        fn writeError(form: anytype, err: anyerror) void {
            form.problem = switch (err) {
                error.HomeNotSet => "HOME is not set, so there is no settings file",
                else => "could not write the settings file",
            };
        }

        /// Rereads the connections after the settings changed. False when
        /// the file could not be read back.
        fn reloadConnections(app: *App) !bool {
            const registry = config_runtime.loadConfiguredProviders(app.provider_selection.alloc) catch {
                try app.writeDomainNotice(.{
                    .topic = "connect",
                    .tone = .warning,
                    .body = "The settings were saved, but could not be read back. Restart spark to use them.",
                }, true);
                return false;
            };
            app.provider_selection.definitions.deinit(app.provider_selection.alloc);
            app.provider_selection.definitions = registry;
            return true;
        }

        fn deleteConnection(app: *App, agent: *AppAgent) !void {
            const form = &app.input_runtime.connect_menu;
            const name = form.editing orelse return;
            if (agent.stream.active) {
                form.problem = "wait for the current turn to finish";
                return;
            }
            var arena: std.heap.ArenaAllocator = .init(app.alloc);
            defer arena.deinit();
            const owned = try arena.allocator().dupe(u8, name);
            var outcome = config_runtime.setUserPreferences(app.alloc, .{
                .connection = .{ .id = owned, .value = null },
            }) catch |err| return writeError(form, err);
            outcome.deinit(app.alloc);
            form.close(app.alloc);
            const was_active = std.mem.eql(u8, provider_runtime.providerOf(app, agent).label(), owned);
            if (!try reloadConnections(app)) return;

            var body_buf: [256]u8 = undefined;
            try app.writeDomainNotice(.{
                .topic = "connect",
                .tone = .neutral,
                .body = std.mem.print(&body_buf, "Deleted connection {s}.", .{owned}) catch "Deleted the connection.",
            }, true);
            if (!was_active) return;
            const definitions = app.provider_selection.definitions.definitions;
            if (definitions.len == 0) {
                try app.writeDomainNotice(.{ .topic = "connect", .tone = .warning, .body = "No connection is left. Run /connect to add one." }, true);
                return;
            }
            const next = model_provider.parse(definitions[0].id) orelse return;
            try app_auth_runtime.Runtime(App).switchToConnection(app, agent, next.bind(app.provider_selection.definitions) catch next);
        }

        pub fn saveConnection(app: *App, agent: *AppAgent) !void {
            const form = &app.input_runtime.connect_menu;
            if (agent.stream.active) {
                form.problem = "wait for the current turn to finish, then press enter";
                return;
            }
            var arena: std.heap.ArenaAllocator = .init(app.alloc);
            defer arena.deinit();
            const a = arena.allocator();
            const previous: ?[]const u8 = if (form.editing) |old| try a.dupe(u8, old) else null;
            const base = if (previous) |old| config_runtime.loadConnectionJson(a, old) catch null else null;
            const value = try form.toJson(a, base);
            const name = try a.dupe(u8, form.name.items);

            // Keep the model in use when the edited connection still has it.
            const current = provider_runtime.providerOf(app, agent);
            const current_model = provider_runtime.modelOf(app, agent);
            const was_active = previous != null and std.mem.eql(u8, current.label(), previous.?);
            var model = try a.dupe(u8, form.models.items[0].id);
            if (was_active) for (form.models.items) |entry| {
                if (std.mem.eql(u8, entry.id, current_model)) model = try a.dupe(u8, current_model);
            };

            // The settings parser is the authority on what a connection may hold.
            var check: std.json.ObjectMap = .empty;
            try check.put(a, name, value);
            var checked = configured_provider.Registry.parse(app.alloc, .{ .object = check }) catch |err| {
                form.problem = configured_provider.failure_advice(err) orelse "the connection could not be saved";
                return;
            };
            checked.deinit(app.alloc);

            const target = model_provider.parse(name) orelse {
                form.problem = "that name can't be used";
                return;
            };
            var outcome = config_runtime.setUserPreferences(app.alloc, .{
                .connection = .{ .id = name, .value = value, .previous_id = previous },
                .model_preference = .{ .provider = target, .model = model },
            }) catch |err| return writeError(form, err);
            outcome.deinit(app.alloc);
            form.close(app.alloc);
            if (!try reloadConnections(app)) return;
            // A session saves a connection with its binding, so bind it to
            // the definition just loaded before switching.
            const bound = target.bind(app.provider_selection.definitions) catch target;

            var body_buf: [256]u8 = undefined;
            const body = std.mem.print(&body_buf, "Saved connection {s}. Switching to it.", .{name}) catch "Saved the connection.";
            try app.writeDomainNotice(.{ .topic = "connect", .tone = .neutral, .body = body }, true);
            try app_auth_runtime.Runtime(App).switchToConnection(app, agent, bound);
        }
    };
}
