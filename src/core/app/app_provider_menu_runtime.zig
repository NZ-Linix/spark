//! `/provider`: routes keys to the connection form and saves under
//! `providers` in the profile settings. An edit to a saved connection saves
//! as soon as its field is committed and keeps the form open; a new
//! connection saves on "Create connection" and becomes the one in use.

const std = @import("std");
const agents = @import("../agents/agents.zig");
const config_runtime = @import("../config/config_runtime.zig");
const configured_provider = @import("../config/configured_provider.zig");
const model_provider = @import("../config/model_provider.zig");
const settings_store = @import("../config/settings_store.zig");
const app_auth_runtime = @import("app_auth_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");
const chatgpt = @import("../config/chatgpt_connection.zig");
const plan = @import("../auth/chatgpt_plan.zig");

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};

        /// Takes every byte while the form is open. Returns false when it is
        /// closed.
        pub fn routeByte(app: *App, agent: *AppAgent, byte: u8) !bool {
            const form = &app.input_runtime.provider_menu;
            if (!form.active) return false;
            // Escape starts an arrow key, a paste, or Esc itself; the input
            // decoder turns it into an action for `routeAction`.
            if (byte == 0x1b) return false;
            if (form.chatgpt_job) |job| {
                if (byte == 3) job.cancel.store(true, .release);
                return true;
            }
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
            const form = &app.input_runtime.provider_menu;
            if (!form.active) return false;
            if (form.chatgpt_job) |job| {
                if (action == .escape) job.cancel.store(true, .release);
                return true;
            }
            switch (action) {
                .paste_start, .paste_end, .remapped_byte => return false,
                // Esc leaves a field or a list; on the connection list it
                // closes the form.
                .escape => if (!try form.back(app.alloc)) return false,
                .word_left => form.moveLeft(),
                .cursor_right => if (form.field.isList()) try submit(app, agent) else form.moveRight(),
                .word_right => form.moveRight(),
                .home => form.moveHome(),
                .end => form.moveEnd(),
                .delete_next => form.deleteNext(),
                .delete_to_line_start, .clear_line => form.clearLine(),
                .cursor_up, .history_up => if (form.field.isList()) form.move(-1),
                .cursor_down, .history_down => if (form.field.isList()) form.move(1),
                .cursor_left => if (form.field.isList()) {
                    if (!try form.back(app.alloc)) form.close(app.alloc);
                } else form.moveLeft(),
                else => {},
            }
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn submit(app: *App, agent: *AppAgent) !void {
            const form = &app.input_runtime.provider_menu;
            switch (try form.submit(app.alloc)) {
                .next, .invalid => {},
                .close => form.close(app.alloc),
                .create => try saveConnection(app, agent),
                .save => try saveEdit(app, agent),
                .edit => {
                    const name = form.editing orelse return;
                    const definition = app.provider_selection.definitions.get(name) orelse {
                        form.problem = "that connection is no longer in the settings";
                        return;
                    };
                    try form.beginEdit(app.alloc, definition);
                },
                .delete => try deleteConnection(app, agent),
                .chatgpt_connect => try startChatGPT(app, agent, .connect),
                .chatgpt_use => {
                    const target = model_provider.parse(form.editing orelse return) orelse return;
                    form.close(app.alloc);
                    try app_auth_runtime.Runtime(App).switchToConnection(app, agent, try target.bind(app.provider_selection.definitions));
                },
                .chatgpt_reconnect => try startChatGPT(app, agent, .reconnect),
                .chatgpt_remove => try startChatGPT(app, agent, .remove),
                .chatgpt_usage => if (comptime @hasDecl(App, "chatgptBrowser")) {
                    if (!try app.chatgptBrowser().open(app.alloc, "https://chatgpt.com/settings/usage")) form.problem = "Open https://chatgpt.com/settings/usage to review your plan.";
                },
            }
        }

        fn startChatGPT(app: *App, agent: *AppAgent, operation: chatgpt.Operation) !void {
            const form = &app.input_runtime.provider_menu;
            if (comptime !@hasDecl(App, "chatgptBrowser")) {
                form.problem = "ChatGPT sign-in is only available in the local terminal app.";
                return;
            } else {
                if (agent.stream.active or agent.worker.queuedPromptCount() > 0) {
                    form.problem = "Wait for the active and queued work to finish.";
                    return;
                }
                const id = if (operation == .connect) try plan.newId(app.alloc) else try app.alloc.dupe(u8, form.editing orelse return);
                defer app.alloc.free(id);
                if (operation == .connect and form.connections.items.len >= 32) {
                    form.problem = "The profile already has 32 connections.";
                    return;
                }
                const display_name = if (operation == .connect)
                    chatgpt.displayName(app.alloc, app.provider_selection.definitions, form.input.items) catch |err| {
                        form.problem = chatgpt.errorText(err);
                        return;
                    }
                else
                    try app.alloc.dupe(u8, form.display_name.items);
                defer app.alloc.free(display_name);
                form.chatgpt_job = try chatgpt.Job.start(app.chatgptTransport(), app.chatgptBrowser(), operation, id, display_name);
                form.problem = if (operation == .remove) "Disconnecting from ChatGPT…" else "Finish sign-in in your browser. Esc cancels.";
            }
        }

        pub fn collectChatGPT(app: *App, agent: *AppAgent) !void {
            const form = &app.input_runtime.provider_menu;
            const job = form.chatgpt_job orelse return;
            if (!job.done.load(.acquire)) return;
            form.chatgpt_job = null;
            defer job.close();
            app.shell.render_requests.request(.footer);
            const confirmed = job.result catch |err| {
                form.problem = chatgpt.errorText(err);
                return;
            };
            form.close(app.alloc);
            if (!try reloadConnections(app)) return;
            if (job.operation == .remove) {
                if (std.mem.eql(u8, provider_runtime.providerOf(app, agent).label(), job.id)) {
                    const definitions = app.provider_selection.definitions.definitions;
                    if (definitions.len > 0) {
                        const target = model_provider.parse(definitions[0].id).?;
                        try app_auth_runtime.Runtime(App).switchToConnection(app, agent, try target.bind(app.provider_selection.definitions));
                    } else {
                        try app.provider_selection.replaceSelection(.none, provider_runtime.modelOf(app, agent));
                        app.auth.clearCredential(app.alloc);
                        app.model_cache.resetForProviderChange();
                    }
                }
                try app.writeDomainNotice(.{ .topic = "connect", .tone = if (confirmed) .neutral else .warning, .body = if (confirmed) "Disconnected from ChatGPT." else "Removed the local account. Remote revocation could not be confirmed; disconnect Spark in ChatGPT settings." }, true);
                return;
            }
            const target = try model_provider.parse(job.id).?.bind(app.provider_selection.definitions);
            if (!provider_runtime.providerOf(app, agent).same_authority(target)) {
                try app_auth_runtime.Runtime(App).switchToConnection(app, agent, target);
            } else app.model_cache.resetForProviderChange();
            try app.writeDomainNotice(.{ .topic = "connect", .tone = .neutral, .body = "Using your ChatGPT plan. Manage usage at https://chatgpt.com/settings/usage." }, true);
        }

        /// Opens the form on the saved connections.
        pub fn open(app: *App) !void {
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(app.alloc);
            var labels: std.ArrayList(?[]const u8) = .empty;
            defer labels.deinit(app.alloc);
            for (app.provider_selection.definitions.definitions) |definition| {
                try names.append(app.alloc, definition.id);
                try labels.append(app.alloc, definition.display_name);
            }
            try app.input_runtime.provider_menu.open(app.alloc, names.items);
            try app.input_runtime.provider_menu.setLabels(app.alloc, labels.items);
        }

        /// Closes the form without saving. Returns whether it was open.
        pub fn cancel(app: *App) bool {
            const form = &app.input_runtime.provider_menu;
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
            // The in-flight catalog callback borrows the current definition.
            app.model_cache.resetForProviderChange();
            app.provider_selection.definitions.deinit(app.provider_selection.alloc);
            app.provider_selection.definitions = registry;
            return true;
        }

        fn deleteConnection(app: *App, agent: *AppAgent) !void {
            const form = &app.input_runtime.provider_menu;
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
                try app.writeDomainNotice(.{ .topic = "connect", .tone = .warning, .body = "No connection is left. Run /provider to add one." }, true);
                return;
            }
            const next = model_provider.parse(definitions[0].id) orelse return;
            try app_auth_runtime.Runtime(App).switchToConnection(app, agent, next.bind(app.provider_selection.definitions) catch next);
        }

        /// Saves a field changed on a saved connection and keeps the form
        /// open on its list.
        fn saveEdit(app: *App, agent: *AppAgent) !void {
            const form = &app.input_runtime.provider_menu;
            const previous_name = form.editing orelse return;
            if (agent.stream.active) {
                form.problem = "wait for the current turn to finish; the change is not saved yet";
                return;
            }
            var arena: std.heap.ArenaAllocator = .init(app.alloc);
            defer arena.deinit();
            const a = arena.allocator();
            const previous = try a.dupe(u8, previous_name);
            const base = config_runtime.loadConnectionJson(a, previous) catch null;
            const value = try form.toJson(a, base);
            const name = try a.dupe(u8, form.name.items);

            var check: std.json.ObjectMap = .empty;
            try check.put(a, name, value);
            var checked = configured_provider.Registry.parse(app.alloc, .{ .object = check }) catch |err| {
                form.problem = configured_provider.failure_advice(err) orelse "the connection could not be saved";
                return;
            };
            checked.deinit(app.alloc);

            const was_active = std.mem.eql(u8, provider_runtime.providerOf(app, agent).label(), previous);
            const renamed = !std.mem.eql(u8, name, previous);
            // Keep the saved model when the connection still has it.
            const current_model = provider_runtime.modelOf(app, agent);
            var model: ?[]const u8 = null;
            if (was_active) {
                model = form.models.items[0].id;
                for (form.models.items) |entry| if (std.mem.eql(u8, entry.id, current_model)) {
                    model = entry.id;
                };
            }
            const target = model_provider.parse(name) orelse {
                form.problem = "that ID can't be used";
                return;
            };
            var outcome = config_runtime.setUserPreferences(app.alloc, .{
                .connection = .{ .id = name, .value = value, .previous_id = previous },
                .model_preference = if (model) |m| .{ .provider = target, .model = try a.dupe(u8, m) } else null,
            }) catch |err| return writeError(form, err);
            outcome.deinit(app.alloc);
            try form.markSaved(app.alloc);
            if (!try reloadConnections(app)) return;
            var labels: std.ArrayList(?[]const u8) = .empty;
            defer labels.deinit(app.alloc);
            for (form.connections.items) |entry| {
                const definition = app.provider_selection.definitions.get(entry);
                try labels.append(app.alloc, if (definition) |d| d.display_name else null);
            }
            try form.setLabels(app.alloc, labels.items);
            if (was_active and renamed) {
                const bound = target.bind(app.provider_selection.definitions) catch target;
                try app_auth_runtime.Runtime(App).switchToConnection(app, agent, bound);
            }
        }

        pub fn saveConnection(app: *App, agent: *AppAgent) !void {
            const form = &app.input_runtime.provider_menu;
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
