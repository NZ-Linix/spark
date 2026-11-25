const std = @import("std");
const command_specs = @import("../slash_commands/command_specs.zig");
const agents = @import("../agents/agents.zig");
const build_options = @import("build_options");
const app_session_runtime = @import("../app/app_session_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const collections = @import("../shared/collections.zig");
const config_runtime = @import("../config/config_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const fuzzy_match = @import("../shared/fuzzy_match.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const model_cache_runtime = @import("../app/model_cache_runtime.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const output_contracts = @import("../output/output_contracts.zig");
const permissions = @import("../permissions/permissions.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const prompt_history_runtime = @import("../app/prompt_history_runtime.zig");
const provider_runtime = @import("../app/provider_runtime.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const render_request = @import("../../ui/render_request.zig");
const info_panel = @import("../input/info_panel.zig");

const freeStringList = collections.freeStringList;
const containsIgnoreCase = text_utils.containsIgnoreCase;

pub fn reportUserSettingsCommit(
    app: anytype,
    label: []const u8,
    patch: config_runtime.UserSettingsPatch,
    outcome: config_runtime.CommitOutcome,
    session_error: ?anyerror,
    // False when the caller announces state; drops the redundant "saved" line.
    announce_commit: bool,
) !?config_runtime.ConfigSources {
    var detailed = loadDetailedSettingsForNotice(app) catch |err| {
        debug_trace.logf(
            "config",
            "{s} post-commit source resolution failed err={s}",
            .{ label, @errorName(err) },
        );
        try writeUserSettingsCommitUnknownSource(
            app,
            label,
            outcome,
            session_error,
            err,
        );
        return null;
    };
    defer detailed.deinit(app.alloc);
    if (postCommitResolutionError(detailed)) |err| {
        debug_trace.logf(
            "config",
            "{s} post-commit source resolution diagnostic err={s}",
            .{ label, @errorName(err) },
        );
        try writeUserSettingsCommitUnknownSource(
            app,
            label,
            outcome,
            session_error,
            err,
        );
        return null;
    }

    var out: std.Io.Writer.Allocating = .init(app.alloc);
    defer out.deinit();

    const benign_commit = "saved to global settings (scope=global)";
    try out.writer.writeAll(benign_commit);
    try appendShadowedUserSources(&out.writer, patch, detailed.sources);
    try appendCommitCleanup(&out.writer, outcome);
    if (session_error) |err| {
        try out.writer.print("; current-session recovery degraded ({s})", .{@errorName(err)});
    }
    const text = try out.toOwnedSlice();
    defer app.alloc.free(text);
    // Keep the line when any warning suffix was appended.
    if (announce_commit or !std.mem.eql(u8, text, benign_commit)) {
        try app.writeDomainNotice(.{ .topic = label, .tone = .neutral, .body = text }, true);
    }
    return detailed.sources;
}

fn writeUserSettingsCommitUnknownSource(
    app: anytype,
    label: []const u8,
    outcome: config_runtime.CommitOutcome,
    session_error: ?anyerror,
    resolution_error: anyerror,
) !void {
    var out: std.Io.Writer.Allocating = .init(app.alloc);
    defer out.deinit();

    try out.writer.print(
        "saved to global settings (scope=global); next-startup source unknown ({s})",
        .{@errorName(resolution_error)},
    );
    try appendCommitCleanup(&out.writer, outcome);
    if (session_error) |err| {
        try out.writer.print("; current-session recovery degraded ({s})", .{@errorName(err)});
    }
    const text = try out.toOwnedSlice();
    defer app.alloc.free(text);
    try app.writeDomainNotice(.{ .topic = label, .tone = .warning, .body = text }, true);
}

pub fn reportUserSettingsFailure(
    app: anytype,
    label: []const u8,
    err: anyerror,
    cleanup: config_runtime.LegacyCleanup,
    runtime_changed: bool,
) !void {
    var out: std.Io.Writer.Allocating = .init(app.alloc);
    defer out.deinit();

    if (err == error.SettingsCommitIndeterminate) {
        try out.writer.print(
            "global settings persistence uncertain (scope=global, error={s})",
            .{@errorName(err)},
        );
    } else {
        try out.writer.print(
            "{s}not saved to global settings ({s})",
            .{ if (runtime_changed) "active for this process but " else "", @errorName(err) },
        );
    }
    try appendLegacyCleanup(&out.writer, cleanup);
    const text = try out.toOwnedSlice();
    defer app.alloc.free(text);
    try app.writeDomainNotice(.{ .topic = label, .tone = .@"error", .body = text }, true);
}

fn loadDetailedSettingsForNotice(app: anytype) !config_runtime.DetailedSettings {
    if (comptime @hasDecl(@TypeOf(app.*), "loadDetailedSettingsForNotice")) {
        return app.loadDetailedSettingsForNotice();
    }
    return config_runtime.loadMergedSettingsDetailed(app.alloc, app.workspace_root);
}

fn postCommitResolutionError(
    detailed: config_runtime.DetailedSettings,
) ?anyerror {
    for (detailed.diagnostics) |diagnostic| {
        if (diagnostic.layer != .user) continue;
        switch (diagnostic.cause) {
            .malformed_settings => return error.InvalidSettingsFormat,
            .settings_too_large => return error.SettingsPrimaryTooLarge,
            .durable_path_unsafe => return error.DurablePathUnsafe,
            .private_state_permissions_unsupported => return error.PrivateStatePermissionsUnsupported,
            .invalid_model_id => return error.InvalidModelValue,
            .retired_skill_match_fuzzy => return error.InvalidSettingsFormat,
            .invalid_context_limits => return error.InvalidSettingsFormat,
            .invalid_tool_placement => return error.InvalidSettingsFormat,
            .invalid_additional_directories => return error.InvalidSettingsFormat,
            .invalid_skill_symlink_authorities,
            .invalid_ultrafast_mode_override,
            => return error.InvalidSettingsFormat,
            .ignored_project_user_only_setting,
            .legacy_workspace_preferences,
            .manual_backup_available,
            .private_state_permissions_tightened,
            => {},
        }
    }
    return null;
}

fn appendShadowedUserSources(
    writer: *std.Io.Writer,
    patch: config_runtime.UserSettingsPatch,
    sources: config_runtime.ConfigSources,
) !void {
    var wrote_header = false;
    const model_source = if (patch.model_preference) |preference|
        sources.models.get(model_provider.NameKey.fromProvider(preference.provider))
    else
        .compiled_default;
    try appendShadowedUserSource(writer, "model", patch.model_preference != null, model_source, &wrote_header);
    try appendShadowedUserSource(writer, "permission_mode", patch.permission_mode != null, sources.permission_mode, &wrote_header);
    try appendShadowedUserSource(writer, "effort", patch.effort != null, sources.effort, &wrote_header);
    try appendShadowedUserSource(writer, "fast_mode", patch.fast_mode != null, sources.fast_mode, &wrote_header);
    try appendShadowedUserSource(writer, "ultrafast_mode", patch.ultrafast_mode != null, sources.ultrafast_mode, &wrote_header);
    try appendShadowedUserSource(writer, "startup_scrollback", patch.startup_scrollback != null, sources.startup_scrollback, &wrote_header);
    try appendShadowedUserSource(writer, "prompt_history", patch.prompt_history_enabled != null, sources.prompt_history_enabled, &wrote_header);
    if (patch.statusline_item) |item| {
        const source: ?config_runtime.ConfigSource = switch (item.item) {
            .context => sources.statusline_context,
            .session => sources.statusline_session,
            .workspace => null,
        };
        if (source) |resolved| {
            const field = switch (item.item) {
                .context => "statusLine.context",
                .session => "statusLine.session",
                .workspace => unreachable,
            };
            try appendShadowedUserSource(writer, field, true, resolved, &wrote_header);
        }
    }
    try appendShadowedUserSource(
        writer,
        "notifications.turn_end",
        patch.notification_turn_end != null,
        sources.notification_turn_end,
        &wrote_header,
    );
    try appendShadowedUserSource(
        writer,
        "notifications.attention_required",
        patch.notification_attention_required != null,
        sources.notification_attention_required,
        &wrote_header,
    );
    try appendShadowedUserSource(
        writer,
        "notifications.max",
        patch.notification_max != null,
        sources.notification_max,
        &wrote_header,
    );
}

fn appendShadowedUserSource(
    writer: *std.Io.Writer,
    field: []const u8,
    present: bool,
    source: config_runtime.ConfigSource,
    wrote_header: *bool,
) !void {
    if (!present or source == .user_global) return;
    if (!wrote_header.*) {
        try writer.writeAll("; fresh sessions here use higher-precedence ");
        wrote_header.* = true;
    } else {
        try writer.writeAll(", ");
    }
    try writer.print("{s}={s}", .{ field, @tagName(source) });
}

fn appendCommitCleanup(writer: *std.Io.Writer, outcome: config_runtime.CommitOutcome) !void {
    switch (outcome) {
        .unchanged => {},
        .committed => |committed| try appendLegacyCleanup(writer, committed.cleanup),
    }
}

fn appendLegacyCleanup(writer: *std.Io.Writer, cleanup: config_runtime.LegacyCleanup) !void {
    if (cleanup.fields_removed > 0) {
        try writer.print(
            "; normalized {d} legacy value{s} across {d} workspace{s}",
            .{
                cleanup.fields_removed,
                if (cleanup.fields_removed == 1) "" else "s",
                cleanup.workspaces_changed,
                if (cleanup.workspaces_changed == 1) "" else "s",
            },
        );
    }
    for (cleanup.recovery_paths) |path| {
        try writer.print("; recovery={s}", .{path});
    }
}

pub fn Commands(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        fn update_channel_label(app: *App) []const u8 {
            if (comptime @hasField(App, "upgrader")) {
                const Upgrader = @TypeOf(app.upgrader);
                if (comptime @hasDecl(Upgrader, "channel")) {
                    return app.upgrader.channel().label();
                }
            }
            return "stable";
        }

        /// The rows the `/status` panel opens with.
        pub fn openStatusSnapshot(app: *App, agent: *AppAgent) !info_panel.Snapshot {
            return statusSnapshot(app, agent, null, null);
        }

        /// New rows for the open `/status` panel when a running turn changed
        /// what `shown` was built from; null while nothing did. Reads no file.
        pub fn refreshedStatusSnapshot(app: *App, agent: *AppAgent, shown: *const info_panel.Snapshot) !?info_panel.Snapshot {
            if (std.meta.eql(statusFacts(app, agent, shellSession(agent)), shown.facts)) return null;
            const inputs = shown.inputs.status;
            return try statusSnapshot(app, agent, inputs.preferred, inputs.settings_error);
        }

        fn statusSnapshot(app: *App, agent: *AppAgent, preferred: ?types.CredentialSource, settings_error: ?[]const u8) !info_panel.Snapshot {
            const provider = provider_runtime.providerOf(app, agent);
            const spark_home = try profile_paths.activeRoot(app.alloc, io_mod.homeDir());
            defer if (spark_home) |path| app.alloc.free(path);
            const session = shellSession(agent);
            const status: output_contracts.StatusSnapshot = .{
                .model = provider_runtime.modelOf(app, agent),
                .provider = provider,
                .provider_endpoint = if (comptime @hasField(App, "provider_selection"))
                    if (app.provider_selection.definitions.get(provider.label())) |definition| definition.base_url else null
                else
                    null,
                .update_channel = update_channel_label(app),
                .build_channel = if (@hasDecl(App, "build_update_channel")) App.build_update_channel.label() else "stable",
                .build_revision = if (@hasDecl(App, "build_revision")) App.build_revision else "",
                .permission_mode = .yolo,
                .workspace_root = app.workspace_root,
                .session = session,
                .settings_error = settings_error,
                .spark_home = spark_home,
                .history_turns = agent.session.historyLen(),
                .agent_step_limit = app.agent_step_limit,
                .ultrafast_requested = agent.worker.agent_turn_settings.ultrafast_mode,
            };
            var arena = std.heap.ArenaAllocator.init(app.alloc);
            errdefer arena.deinit();
            const rows = try status.panelRows(arena.allocator());
            return .{
                .arena = arena,
                .rows = rows,
                .facts = statusFacts(app, agent, session),
                .inputs = .{ .status = .{ .preferred = preferred, .settings_error = settings_error } },
            };
        }

        fn statusFacts(_: *App, agent: *AppAgent, session: ?output_contracts.StatusSnapshot.ShellSession) info_panel.Facts {
            return .{ .status = .{
                .history_turns = agent.session.historyLen(),
                .session_saved = if (session) |shown| switch (shown) {
                    .unavailable => null,
                    .open => |open| open.saved,
                } else null,
            } };
        }

        /// The open session as `/status` shows it, so its id can be copied
        /// before quitting. Saved means a resume opens it
        /// (`tests/tla/session/ShellSession.tla` StatusSavedIsOnDisk).
        fn shellSession(agent: *AppAgent) ?output_contracts.StatusSnapshot.ShellSession {
            if (comptime !agents.hasAgentField(App, "session_persistence")) return null;
            const v2 = agent.session_persistence.v2 orelse return .unavailable;
            return .{ .open = .{ .id = v2.id(), .saved = v2.saved() } };
        }

        pub fn handleSettings(app: *App, rest: []const u8) !void {
            const trimmed = std.mem.trim(u8, rest, " \t");
            if (trimmed.len == 0) {
                try writeSettingsStatus(app);
                return;
            }

            const first = splitFirstWord(trimmed) orelse {
                try writeSettingsUsage(app);
                return;
            };
            if (!std.ascii.eqlIgnoreCase(first.word, "startup-scrollback")) {
                try writeSettingsUsage(app);
                return;
            }

            const value_split = splitFirstWord(first.rest);
            if (value_split) |split| {
                if (split.rest.len != 0) {
                    try writeSettingsUsage(app);
                    return;
                }
                if (std.ascii.eqlIgnoreCase(split.word, "on")) {
                    try saveStartupScrollbackSetting(app, true);
                    return;
                }
                if (std.ascii.eqlIgnoreCase(split.word, "off")) {
                    try saveStartupScrollbackSetting(app, false);
                    return;
                }
                try writeSettingsUsage(app);
                return;
            }

            var settings = config_runtime.loadMergedSettings(app.alloc, app.workspace_root) catch |err| {
                try writeSettingsLoadError(app, err);
                return;
            };
            defer settings.deinit(app.alloc);

            try saveStartupScrollbackSetting(app, !(settings.startup_scrollback orelse true));
        }

        pub fn handleModel(app: *App, agent: *AppAgent, query: []const u8) !void {
            if (query.len == 0) {
                try app.writeDomainNotice(.{ .topic = "model", .tone = .neutral, .body = provider_runtime.modelOf(app, agent) }, true);
                return;
            }

            const resolved = try resolveModelQuery(app, query);
            defer app.alloc.free(resolved);
            try setResolvedModel(app, agent, resolved, true);
        }

        pub fn handleHistory(app: *App, rest: []const u8) !void {
            const trimmed = std.mem.trim(u8, rest, " \t");
            if (std.ascii.eqlIgnoreCase(trimmed, "off")) {
                app.prompt_history.disable();
                var attempt = config_runtime.attemptUserPreferences(
                    app.alloc,
                    .{ .prompt_history_enabled = false },
                );
                defer attempt.deinit(app.alloc);
                switch (attempt) {
                    .failure => |failure| {
                        try reportUserSettingsFailure(
                            app,
                            "history",
                            failure.err,
                            failure.cleanup,
                            true,
                        );
                        return;
                    },
                    .outcome => |outcome| _ = try reportUserSettingsCommit(
                        app,
                        "history",
                        .{ .prompt_history_enabled = false },
                        outcome,
                        null,
                        true,
                    ),
                }
                return;
            }

            if (std.ascii.eqlIgnoreCase(trimmed, "on")) {
                var attempt = config_runtime.attemptUserPreferences(
                    app.alloc,
                    .{ .prompt_history_enabled = true },
                );
                defer attempt.deinit(app.alloc);
                switch (attempt) {
                    .failure => |failure| {
                        app.prompt_history.disable();
                        try reportUserSettingsFailure(
                            app,
                            "history",
                            failure.err,
                            failure.cleanup,
                            false,
                        );
                        return;
                    },
                    .outcome => |outcome| {
                        app.prompt_history.enable();
                        _ = try reportUserSettingsCommit(
                            app,
                            "history",
                            .{ .prompt_history_enabled = true },
                            outcome,
                            null,
                            true,
                        );
                    },
                }
                return;
            }

            try app.writeDomainNotice(.{ .topic = "history", .tone = .@"error", .body = "prompt history options: on, off" }, true);
        }

        pub fn toggleFast(app: *App, agent: *AppAgent) !void {
            try toggleFastForModel(app, agent, provider_runtime.modelOf(app, agent), true);
        }

        /// `/fast` toggles; `/fast on` and `/fast off` set the mode and are
        /// idempotent. Turning it on still checks that the model supports it.
        pub fn handleFast(app: *App, agent: *AppAgent, rest: []const u8) !void {
            const command = std.mem.trim(u8, rest, " \t");
            if (command.len == 0) return toggleFast(app, agent);
            if (std.ascii.eqlIgnoreCase(command, "on")) {
                if (app.fast_mode) return applyFastMode(app, agent, true, true, true);
                return toggleFast(app, agent);
            }
            if (std.ascii.eqlIgnoreCase(command, "off")) {
                return applyFastMode(app, agent, false, true, true);
            }
            try app.writeDomainNotice(.{
                .topic = "",
                .tone = .@"error",
                .body = "usage: /fast [on|off]",
            }, true);
        }

        pub fn handleUltrafast(app: *App, agent: *AppAgent, rest: []const u8) !void {
            const command = std.mem.trim(u8, rest, " \t");
            if (command.len == 0 or std.ascii.eqlIgnoreCase(command, "status")) {
                try writeUltrafastStatus(app, agent);
                return;
            }
            if (std.ascii.eqlIgnoreCase(command, "on")) {
                try applyUltrafastMode(app, agent, true, true, true);
                return;
            }
            if (std.ascii.eqlIgnoreCase(command, "off")) {
                try applyUltrafastMode(app, agent, false, true, true);
                return;
            }
            try app.writeDomainNotice(.{
                .topic = "",
                .tone = .@"error",
                .body = "usage: /ultrafast [on|off|status]",
            }, true);
        }

        fn writeUltrafastStatus(app: *App, agent: *AppAgent) !void {
            try app.writeDomainNotice(.{
                .topic = "ultrafast",
                .tone = .neutral,
                .body = if (agent.worker.agent_turn_settings.ultrafast_mode) "requested: on" else "requested: off",
            }, true);
        }

        fn toggleFastForModel(app: *App, agent: *AppAgent, model: []const u8, announce: bool) !void {
            if (app.fast_mode) {
                try applyFastMode(app, agent, false, announce, true);
                return;
            }
            if (!model_capabilities.resolveForApp(App, app, model).supports_fast_mode) {
                if (announce) {
                    try app.writeDomainNotice(.{
                        .topic = "fast",
                        .tone = .neutral,
                        .body = "This model does not come with a fast mode.",
                    }, true);
                }
                app.shell.render_requests.request(.footer);
                return;
            }

            try applyFastMode(app, agent, !app.fast_mode, announce, true);
        }

        fn applyFastMode(app: *App, agent: *AppAgent, enabled: bool, announce: bool, persist: bool) !void {
            const previous = app.fast_mode;
            const previous_ultrafast = agent.worker.agent_turn_settings.ultrafast_mode;
            app.fast_mode = enabled;
            if (enabled) {
                agent.worker.agent_turn_settings.ultrafast_mode = false;
                if (comptime agents.hasAgentField(App, "session_persistence")) {
                    agent.session_persistence.process_ultrafast_override = false;
                }
            }
            agent.worker.syncQueuedPromptFastMode(app.fast_mode);
            if (previous_ultrafast != agent.worker.agent_turn_settings.ultrafast_mode) {
                agent.worker.syncQueuedPromptUltrafastMode(agent.worker.agent_turn_settings.ultrafast_mode);
            }
            debug_trace.logf(
                "session",
                "fast mode changed old={s} new={s} ultrafast_old={s} ultrafast_new={s} model={s} supports_fast={s}",
                .{
                    if (previous) "true" else "false",
                    if (app.fast_mode) "true" else "false",
                    if (previous_ultrafast) "true" else "false",
                    if (agent.worker.agent_turn_settings.ultrafast_mode) "true" else "false",
                    provider_runtime.modelOf(app, agent),
                    if (model_capabilities.resolveForApp(App, app, provider_runtime.modelOf(app, agent)).supports_fast_mode) "true" else "false",
                },
            );

            if (persist and savesModeChange(app, agent, "fast")) {
                try persistPreferenceTargets(
                    app,
                    agent,
                    .{
                        .provider = provider_runtime.providerOf(app, agent),
                        .model = provider_runtime.modelOf(app, agent),
                        .fast_mode = app.fast_mode,
                        .ultrafast_mode = agent.worker.agent_turn_settings.ultrafast_mode,
                    },
                    "fast",
                    !announce,
                );
            }

            if (announce) {
                const label = if (app.fast_mode) "on" else "off";
                try app.writeDomainNotice(.{ .topic = "fast", .tone = .neutral, .body = label }, true);
                if (comptime @hasDecl(App, "playInteractionSound")) app.playInteractionSound();
            }
            app.shell.render_requests.request(.footer);
        }

        fn applyUltrafastMode(app: *App, agent: *AppAgent, enabled: bool, announce: bool, persist: bool) !void {
            const capabilities = model_capabilities.resolveForApp(App, app, provider_runtime.modelOf(app, agent));
            if (enabled and !capabilities.supports_ultrafast_mode) {
                if (announce) {
                    try app.writeDomainNotice(.{
                        .topic = "ultrafast",
                        .tone = .warning,
                        .body = "Ultrafast mode is unavailable for this model and may increase cost.",
                    }, true);
                }
                app.shell.render_requests.request(.footer);
                return;
            }

            const previous_ultrafast = agent.worker.agent_turn_settings.ultrafast_mode;
            const previous_fast = app.fast_mode;
            agent.worker.agent_turn_settings.ultrafast_mode = enabled;
            if (comptime agents.hasAgentField(App, "session_persistence")) {
                agent.session_persistence.process_ultrafast_override = enabled;
            }
            if (enabled) app.fast_mode = false;
            agent.worker.syncQueuedPromptUltrafastMode(agent.worker.agent_turn_settings.ultrafast_mode);
            if (previous_fast != app.fast_mode) agent.worker.syncQueuedPromptFastMode(app.fast_mode);
            debug_trace.logf(
                "session",
                "ultrafast mode changed old={s} new={s} fast_old={s} fast_new={s} model={s} supports_ultrafast={s}",
                .{
                    if (previous_ultrafast) "true" else "false",
                    if (agent.worker.agent_turn_settings.ultrafast_mode) "true" else "false",
                    if (previous_fast) "true" else "false",
                    if (app.fast_mode) "true" else "false",
                    provider_runtime.modelOf(app, agent),
                    if (capabilities.supports_ultrafast_mode) "true" else "false",
                },
            );

            if (persist and savesModeChange(app, agent, "ultrafast")) {
                try persistPreferenceTargets(
                    app,
                    agent,
                    .{
                        .provider = provider_runtime.providerOf(app, agent),
                        .model = provider_runtime.modelOf(app, agent),
                        .fast_mode = app.fast_mode,
                        .ultrafast_mode = agent.worker.agent_turn_settings.ultrafast_mode,
                    },
                    "ultrafast",
                    !announce,
                );
            }

            if (announce) {
                try app.writeDomainNotice(.{
                    .topic = "ultrafast",
                    .tone = .neutral,
                    .body = if (agent.worker.agent_turn_settings.ultrafast_mode) "requested on" else "requested off",
                }, true);
                if (comptime @hasDecl(App, "playInteractionSound")) app.playInteractionSound();
            }
            app.shell.render_requests.request(.footer);
        }

        /// What the transcript says about an applied effort.
        const EffortReport = enum {
            /// One line naming the level and the model.
            named,
            /// The settings line saying where the level was saved.
            saved,
            /// Nothing unless saving failed or left a warning: the caller
            /// reports the change, or the status line alone names the level.
            none,
        };

        fn applyEffort(app: *App, agent: *AppAgent, effort: types.ReasoningEffort, report: EffortReport, persist: bool) !void {
            agent.effort = effort;
            agent.worker.syncQueuedPromptEffort(agent.effort);

            if (persist) {
                try persistPreferenceTargets(
                    app,
                    agent,
                    .{ .effort = agent.effort },
                    "effort",
                    report == .saved,
                );
            }

            if (report == .named) try announceEffortSelection(app, agent);
            app.shell.render_requests.request(.footer);
        }

        /// Names the effort now in use, as `/model` names the model it
        /// switched to. A running turn keeps the effort it started with.
        fn announceEffortSelection(app: *App, agent: *AppAgent) !void {
            const active_response = if (comptime agents.hasAgentField(App, "stream")) agent.stream.active else false;
            const prefix: []const u8 = if (active_response) "Next turn will use reasoning effort " else "Reasoning effort set to ";
            const line = try app.alloc.print("{s}{s} for {s}", .{ prefix, agent.effort.displayLabel(), provider_runtime.modelOf(app, agent) });
            defer app.alloc.free(line);
            try app.writeDomainNotice(.{ .topic = "", .tone = .neutral, .body = line }, true);
            if (comptime @hasDecl(App, "playInteractionSound")) app.playInteractionSound();
        }

        pub fn selectEffortFromSettings(app: *App, agent: *AppAgent, effort: types.ReasoningEffort) !void {
            try applyEffort(app, agent, effort, .saved, true);
        }

        /// Applies `effort` to `agent`'s model, saves it, and names it.
        pub fn selectEffort(app: *App, agent: *AppAgent, effort: types.ReasoningEffort) !void {
            try applyEffort(app, agent, effort, .named, true);
        }

        /// Ctrl+T: moves `agent`'s model to the next effort in the cycle
        /// `default`, then each level the model lists in its order, then
        /// `default` again (`model_capabilities.nextReasoningEffort`). Saves
        /// the effort as `/effort` does and, unless saving fails or leaves a
        /// warning, writes nothing to the transcript, as Shift+Tab does for
        /// the permission mode: the status line names the level in use. A
        /// running turn keeps the effort it started with. A model without
        /// levels gets a notice saying so.
        pub fn cycleEffort(app: *App, agent: *AppAgent) !void {
            const model = provider_runtime.modelOf(app, agent);
            const capabilities = model_capabilities.resolveForApp(App, app, model);
            const next = model_capabilities.nextReasoningEffort(capabilities, agent.effort) orelse {
                try writeNoEffortLevelsNotice(app, model, "ctrl+t");
                return;
            };
            try applyEffort(app, agent, next, .none, true);
        }

        /// Says why `model` offers no levels: it has none, or its catalog
        /// entry has not loaded, in which case `retry` names what to try again.
        fn writeNoEffortLevelsNotice(app: *App, model: []const u8, retry: []const u8) !void {
            const loading = if (comptime @hasDecl(App, "isModelCacheLoading")) app.isModelCacheLoading() else false;
            const message = if (loading)
                try app.alloc.print("levels for {s} are still loading; try {s} again in a moment", .{ model, retry })
            else
                try app.alloc.print("{s} has no levels to choose from", .{model});
            defer app.alloc.free(message);
            try app.writeDomainNotice(.{ .topic = "effort", .tone = .neutral, .body = message }, true);
        }

        /// What `/effort` asks of the shell once its arguments are handled.
        pub const EffortRequest = union(enum) {
            /// Nothing more: a level was applied, or a notice said why not.
            done,
            /// Open the menu of these levels for the current model.
            open_menu: model_capabilities.Capabilities,
        };

        /// `/effort` with no arguments asks for the menu of the current
        /// model's levels; `/effort <level>` applies that level. A model
        /// without levels, or a level it does not offer, gets a notice.
        pub fn handleEffort(app: *App, agent: *AppAgent, rest: []const u8) !EffortRequest {
            const model = provider_runtime.modelOf(app, agent);
            const capabilities = model_capabilities.resolveForApp(App, app, model);
            if (capabilities.reasoning_efforts.len == 0) {
                try writeNoEffortLevelsNotice(app, model, "/effort");
                return .done;
            }
            const level = std.mem.trim(u8, rest, " \t\r\n");
            if (level.len == 0) return .{ .open_menu = capabilities };
            const parsed = types.ReasoningEffort.parse(level);
            if (parsed) |effort| {
                if (model_capabilities.reasoningEffortSupported(capabilities, effort)) {
                    try selectEffort(app, agent, effort);
                    return .done;
                }
            }
            var offered: std.ArrayList(u8) = .empty;
            defer offered.deinit(app.alloc);
            try offered.appendSlice(app.alloc, "default");
            for (capabilities.reasoning_efforts.slice()) |*option| {
                try offered.appendSlice(app.alloc, ", ");
                try offered.appendSlice(app.alloc, option.displayLabel());
            }
            // Only a well-formed level name is repeated back.
            const message = if (parsed) |effort|
                try app.alloc.print("{s} is not available for {s}; levels: {s}", .{ effort.label(), model, offered.items })
            else
                try app.alloc.print("levels for {s}: {s}", .{ model, offered.items });
            defer app.alloc.free(message);
            try app.writeDomainNotice(.{ .topic = "effort", .tone = .neutral, .body = message }, true);
            return .done;
        }

        pub fn selectModelFromPicker(
            app: *App,
            agent: *AppAgent,
            model: []const u8,
            effort: types.ReasoningEffort,
            fast_mode: bool,
            ultrafast_mode: bool,
        ) !void {
            try setResolvedModelRuntime(app, agent, model);
            settleStartModel(app);
            var patch = app_session_runtime.SessionPreferencePatch{
                .provider = provider_runtime.providerOf(app, agent),
                .model = model,
            };
            const capabilities = model_capabilities.resolveForApp(App, app, model);
            if (capabilities.reasoning_efforts.len > 0) {
                try applyEffort(app, agent, effort, .none, false);
                patch.effort = effort;
            }
            const selected_ultrafast_mode = capabilities.supports_ultrafast_mode and ultrafast_mode;
            const selected_fast_mode = capabilities.supports_fast_mode and fast_mode and !selected_ultrafast_mode;
            if (selected_fast_mode != app.fast_mode) {
                try applyFastMode(app, agent, selected_fast_mode, false, false);
            }
            if (selected_ultrafast_mode != agent.worker.agent_turn_settings.ultrafast_mode) {
                try applyUltrafastMode(app, agent, selected_ultrafast_mode, false, false);
            }
            patch.fast_mode = app.fast_mode;
            patch.ultrafast_mode = agent.worker.agent_turn_settings.ultrafast_mode;
            try announceModelSelection(app, agent);
            try persistPreferenceTargets(app, agent, patch, "model picker", false);
        }

        fn writeSettingsStatus(app: *App) !void {
            var detailed = config_runtime.loadMergedSettingsDetailed(app.alloc, app.workspace_root) catch |err| {
                try writeSettingsLoadError(app, err);
                return;
            };
            defer detailed.deinit(app.alloc);
            const settings = &detailed.settings;

            const startup_scrollback_label = if (settings.startup_scrollback orelse true) "on" else "off";
            const msg = try app.alloc.print("model: {s}\nmodel_config_source: {s}\npermission_mode: {s}\nworkspace: {s}\nstep_limit: {d}\nstartup_scrollback: {s}", .{
                provider_runtime.model(app),
                @tagName(detailed.sources.models.get(model_provider.NameKey.fromProvider(provider_runtime.providerOf(app, agents.screenAgentOf(app))))),
                permissions.permissionModeDisplayLabel(.yolo),
                app.workspace_root,
                app.agent_step_limit,
                startup_scrollback_label,
            });
            defer app.alloc.free(msg);
            try app.writeDomainNotice(.{ .topic = "settings", .tone = .neutral, .body = msg }, true);
        }

        fn saveStartupScrollbackSetting(app: *App, enabled: bool) !void {
            var attempt = config_runtime.attemptUserPreferences(
                app.alloc,
                .{ .startup_scrollback = enabled },
            );
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .failure => |failure| {
                    try reportUserSettingsFailure(
                        app,
                        "startup-scrollback",
                        failure.err,
                        failure.cleanup,
                        false,
                    );
                    return;
                },
                .outcome => |outcome| {
                    const sources = try reportUserSettingsCommit(
                        app,
                        "startup-scrollback",
                        .{ .startup_scrollback = enabled },
                        outcome,
                        null,
                        false,
                    );
                    const label = if (enabled) "on" else "off";
                    var out: std.Io.Writer.Allocating = .init(app.alloc);
                    defer out.deinit();
                    try out.writer.print("startup_scrollback: {s} ", .{label});
                    if (sources) |resolved| {
                        switch (resolved.startup_scrollback) {
                            .user_global => try out.writer.writeAll(
                                "(applies on next launch)",
                            ),
                            else => try out.writer.print(
                                "(saved user default; current source={s})",
                                .{@tagName(resolved.startup_scrollback)},
                            ),
                        }
                    } else {
                        try out.writer.writeAll(
                            "(saved user default; next-launch source unknown)",
                        );
                    }
                    const msg = try out.toOwnedSlice();
                    defer app.alloc.free(msg);
                    try app.writeDomainNotice(.{ .topic = "settings", .tone = .neutral, .body = msg }, true);
                    return;
                },
            }
        }

        fn writeSettingsUsage(app: *App) !void {
            try app.writeDomainNotice(.{
                .topic = "",
                .tone = .@"error",
                .body = "usage: /settings [startup-scrollback [on|off]]",
            }, true);
        }

        fn writeSettingsLoadError(app: *App, err: anyerror) !void {
            const msg = try app.alloc.print("Failed to load settings: {s}", .{@errorName(err)});
            defer app.alloc.free(msg);
            try app.writeDomainNotice(.{ .topic = "settings", .tone = .@"error", .body = msg }, true);
        }

        fn fetchModelIds(app: *App) !std.ArrayList([]u8) {
            return app.fetchModelIds();
        }

        fn resolveModelQuery(app: *App, query: []const u8) ![]u8 {
            if (try app.snapshotCachedModelIds(app.alloc)) |snapshot| {
                var ids = snapshot;
                defer freeStringList(app.alloc, &ids);
                if (try resolveModelQueryFromIds(app.alloc, ids.items, query)) |resolved| {
                    return resolved;
                }
            }

            var ids = fetchModelIds(app) catch {
                return app.alloc.dupe(u8, query);
            };
            defer freeStringList(app.alloc, &ids);

            if (try resolveModelQueryFromIds(app.alloc, ids.items, query)) |resolved| {
                return resolved;
            }

            return app.alloc.dupe(u8, query);
        }

        fn setResolvedModel(app: *App, agent: *AppAgent, resolved: []const u8, announce: bool) !void {
            const model_changed = !std.mem.eql(u8, provider_runtime.modelOf(app, agent), resolved);
            try setResolvedModelRuntime(app, agent, resolved);
            settleStartModel(app);
            if (model_changed and app.fast_mode) {
                try applyFastMode(app, agent, false, false, false);
            }
            if (model_changed and agent.worker.agent_turn_settings.ultrafast_mode) {
                try applyUltrafastMode(app, agent, false, false, false);
            }
            if (announce) try announceModelSelection(app, agent);
            try persistPreferenceTargets(
                app,
                agent,
                .{
                    .provider = provider_runtime.providerOf(app, agent),
                    .model = resolved,
                    .fast_mode = app.fast_mode,
                    .ultrafast_mode = agent.worker.agent_turn_settings.ultrafast_mode,
                },
                "model",
                !announce,
            );
        }

        /// Whether a `/fast` or `/ultrafast` change is saved. Each saves the
        /// model it is bound to, so while `agent` runs the model a run flag
        /// chose, the change lasts for this run only.
        fn savesModeChange(app: *App, agent: *AppAgent, label: []const u8) bool {
            if (!provider_runtime.runsProcessModel(app, agent)) return true;
            debug_trace.logf(
                "session",
                "{s} mode not saved: model={s} is this run's --model, --provider, or SPARK_MODEL choice",
                .{ label, provider_runtime.modelOf(app, agent) },
            );
            return false;
        }

        fn persistPreferenceTargets(
            app: *App,
            agent: *AppAgent,
            patch: app_session_runtime.SessionPreferencePatch,
            label: []const u8,
            // False when the caller announces state; failures still report.
            announce_commit: bool,
        ) !void {
            var result = if (comptime @hasDecl(App, "persistRuntimePreferences")) blk: {
                break :blk app.persistRuntimePreferences(agent, patch);
            } else blk: {
                var committed = app_session_runtime.PreferenceCommitResult{};
                const attempt = config_runtime.attemptUserPreferences(
                    app.alloc,
                    patch.userSettingsPatch(),
                );
                switch (attempt) {
                    .outcome => |outcome| committed.settings_outcome = outcome,
                    .failure => |failure| {
                        committed.settings_error = failure.err;
                        committed.settings_failure_cleanup = failure.cleanup;
                    },
                }
                break :blk committed;
            };
            defer result.deinit(app.alloc);

            if (result.settings_error) |err| {
                debug_trace.logf(
                    "session",
                    "{s} settings persistence failed err={s}",
                    .{ label, @errorName(err) },
                );
                try reportUserSettingsFailure(
                    app,
                    label,
                    err,
                    result.settings_failure_cleanup,
                    true,
                );
            } else if (result.settings_outcome) |outcome| {
                _ = try reportUserSettingsCommit(
                    app,
                    label,
                    patch.userSettingsPatch(),
                    outcome,
                    result.session_error,
                    announce_commit,
                );
            }
            if (result.session_error) |err| {
                debug_trace.logf(
                    "session",
                    "{s} session persistence failed err={s}",
                    .{ label, @errorName(err) },
                );
                if (result.settings_outcome == null) {
                    try app.writeDomainNotice(.{
                        .topic = label,
                        .tone = .@"error",
                        .body = "failed to persist current session",
                    }, true);
                }
            }
        }

        fn setResolvedModelRuntime(app: *App, agent: *AppAgent, resolved: []const u8) !void {
            if (!std.mem.eql(u8, provider_runtime.modelOf(app, agent), resolved)) {
                try provider_runtime.replaceModel(app, resolved);
            }
            const selected = provider_runtime.modelOf(app, agent);
            try agent.worker.syncQueuedPromptModel(std.heap.c_allocator, selected);
            app_session_runtime.Runtime(App).syncTerminalTitle(app, agent);
        }

        /// A model the user chose keeps its place: the Token Pass check no
        /// longer picks the start model (`src/core/app/token_pass_check.zig`).
        fn settleStartModel(app: *App) void {
            if (comptime @hasField(App, "token_pass_check")) app.token_pass_check.settle("model_choice");
        }

        /// Puts `agent` on `model` at `fast_mode` for this run, without a
        /// notice and without saving either: the model a new session starts
        /// on for its team (`src/core/app/token_pass_check.zig`).
        pub fn adoptStartModel(app: *App, agent: *AppAgent, model: []const u8, fast_mode: bool) !void {
            try setResolvedModelRuntime(app, agent, model);
            if (app.fast_mode != fast_mode) try applyFastMode(app, agent, fast_mode, false, false);
        }

        fn announceModelSelection(app: *App, agent: *AppAgent) !void {
            const selected = provider_runtime.modelOf(app, agent);
            const active_response = if (comptime agents.hasAgentField(App, "stream")) agent.stream.active else false;
            const prefix: []const u8 = if (active_response) "Next turn will use " else "Switched to ";
            const speed: []const u8 = if (agent.worker.agent_turn_settings.ultrafast_mode)
                "ultrafast"
            else if (app.fast_mode or model_capabilities.resolveForApp(App, app, selected).intrinsic_fast)
                "fast"
            else
                "normal";
            const effective = model_capabilities.resolveForApp(App, app, selected).effectiveEffort(agent.effort);
            const default_note: []const u8 = if (agent.effort.isDefault() and !effective.isDefault()) " (model default)" else "";
            const line = try app.alloc.print("{s}{s} (effort: {s}{s}, speed: {s})", .{ prefix, selected, effective.displayLabel(), default_note, speed });
            defer app.alloc.free(line);
            try app.writeDomainNotice(.{ .topic = "", .tone = .neutral, .body = line }, true);
            if (comptime @hasDecl(App, "playInteractionSound")) app.playInteractionSound();
        }

        /// The model `/model <query>` switches to: the one the Models menu
        /// and the inline suggestions list first for the same query.
        fn resolveModelQueryFromIds(alloc: std.mem.Allocator, ids: []const []u8, query: []const u8) !?[]u8 {
            if (std.mem.trim(u8, query, " \t\r\n").len == 0) return null;
            const ranking: fuzzy_match.Ranking(ModelIdMatches) = .{
                .context = .{ .ids = ids, .query = query },
                .len = ids.len,
            };
            const position = ranking.at(0) orelse return null;
            return try alloc.dupe(u8, ids[position]);
        }
    };
}

/// Model ids in catalog order, matched as the Models menu matches them.
const ModelIdMatches = struct {
    ids: []const []u8,
    query: []const u8,

    pub fn matchAt(self: ModelIdMatches, position: usize) ?fuzzy_match.Match {
        return model_cache_runtime.modelIdMatch(self.query, self.ids[position]);
    }
};

const WordSplit = struct {
    word: []const u8,
    rest: []const u8,
};

fn splitFirstWord(text: []const u8) ?WordSplit {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;
    for (trimmed, 0..) |c, idx| {
        if (c == ' ' or c == '\t') {
            return .{
                .word = trimmed[0..idx],
                .rest = std.mem.trimStart(u8, trimmed[idx + 1 ..], " \t"),
            };
        }
    }
    return .{ .word = trimmed, .rest = "" };
}

pub fn fuzzyModelScore(id: []const u8, query: []const u8) i32 {
    if (query.len == 0) return 0;
    if (id.len == 0) return 0;

    if (containsIgnoreCase(id, query)) {
        const bonus: i32 = @intCast(@min(query.len, 50));
        if (std.mem.startsWith(u8, id, query) or
            (id.len > query.len and id[id.len - query.len - 1] == '/' and
                std.ascii.eqlIgnoreCase(id[id.len - query.len ..], query)))
        {
            return 120 + bonus;
        }
        return 100 + bonus;
    }

    var tokens_buf: [16][]const u8 = undefined;
    const token_count = splitQueryTokens(query, &tokens_buf);
    if (token_count > 1) {
        var all_present = true;
        for (tokens_buf[0..token_count]) |token| {
            if (!containsIgnoreCase(id, token)) {
                all_present = false;
                break;
            }
        }
        if (all_present) {
            return 80 + @as(i32, @intCast(token_count)) * 5;
        }
    }

    var qi: usize = 0;
    var matched: usize = 0;
    for (id) |c| {
        if (qi < query.len and std.ascii.toLower(c) == std.ascii.toLower(query[qi])) {
            qi += 1;
            matched += 1;
        }
    }
    if (qi == query.len) {
        return 40 + @as(i32, @intCast(@min(matched, 20)));
    }

    if (token_count >= 1) {
        var any_match = false;
        for (tokens_buf[0..token_count]) |token| {
            if (containsIgnoreCase(id, token)) {
                any_match = true;
                break;
            }
        }
        if (any_match) return 20;
    }

    return 0;
}

fn splitQueryTokens(query: []const u8, out: *[16][]const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < query.len and count < 16) {
        while (i < query.len and isSplitter(query[i])) : (i += 1) {}
        const start = i;
        while (i < query.len and !isSplitter(query[i])) : (i += 1) {}
        if (i > start) {
            out[count] = query[start..i];
            count += 1;
        }
    }
    return count;
}

fn isSplitter(c: u8) bool {
    return c == ' ' or c == '-' or c == '/' or c == '_';
}

const FakeSession = struct {
    history_len: usize = 0,

    fn historyLen(self: *FakeSession) usize {
        return self.history_len;
    }
};

const FakeWorker = struct {
    synced_model: ?[]u8 = null,
    synced_model_alloc: ?std.mem.Allocator = null,
    synced_fast_mode: ?bool = null,
    fast_sync_count: usize = 0,
    agent_turn_settings: struct {
        ultrafast_mode: bool = false,
    } = .{},
    synced_ultrafast_mode: ?bool = null,
    ultrafast_sync_count: usize = 0,
    synced_effort: ?types.ReasoningEffort = null,
    effort_sync_count: usize = 0,

    fn deinit(self: *FakeWorker) void {
        if (self.synced_model) |model| self.synced_model_alloc.?.free(model);
        self.* = .{};
    }

    fn syncQueuedPromptModel(self: *FakeWorker, alloc: std.mem.Allocator, model: []const u8) !void {
        if (self.synced_model) |old| {
            self.synced_model_alloc.?.free(old);
            self.synced_model = null;
            self.synced_model_alloc = null;
        }
        self.synced_model = try alloc.dupe(u8, model);
        self.synced_model_alloc = alloc;
    }

    fn syncQueuedPromptFastMode(self: *FakeWorker, enabled: bool) void {
        self.synced_fast_mode = enabled;
        self.fast_sync_count += 1;
    }

    fn syncQueuedPromptUltrafastMode(self: *FakeWorker, enabled: bool) void {
        self.synced_ultrafast_mode = enabled;
        self.ultrafast_sync_count += 1;
    }

    fn syncQueuedPromptEffort(self: *FakeWorker, effort: types.ReasoningEffort) void {
        self.synced_effort = effort;
        self.effort_sync_count += 1;
    }
};

const FakeHistoryCommandApp = struct {
    alloc: std.mem.Allocator,
    workspace_root: []u8,
    prompt_history: prompt_history_runtime.PromptHistoryRuntime = .{},
    transcript: std.ArrayList(u8) = .empty,
    last_tone: ?types.NoticeTone = null,

    fn init(
        alloc: std.mem.Allocator,
        home: []const u8,
        workspace_root: []const u8,
    ) !FakeHistoryCommandApp {
        var app = FakeHistoryCommandApp{
            .alloc = alloc,
            .workspace_root = try alloc.dupe(u8, workspace_root),
        };
        errdefer app.deinit();
        _ = try app.prompt_history.initialize(alloc, home, true, true);
        return app;
    }

    fn deinit(self: *FakeHistoryCommandApp) void {
        self.prompt_history.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.alloc.free(self.workspace_root);
        self.* = undefined;
    }

    fn writeDomainNotice(self: *FakeHistoryCommandApp, notice: types.SemanticNotice, _: bool) !void {
        self.last_tone = notice.tone;
        try self.transcript.appendSlice(self.alloc, notice.body);
        try self.transcript.append(self.alloc, '\n');
    }
};

const FakeApp = struct {
    alloc: std.mem.Allocator,
    workspace_root: []u8,
    tool_registry: tool_dispatch.Registry = .{},
    selected_model: std.ArrayList(u8) = .empty,
    selected_provider: model_provider.ProviderId = .none,
    auth: auth_runtime.Runtime = .{},
    authority_mutex: std.Io.Mutex = .init,
    shell: struct {
        render_requests: render_request.RenderRequestState = .{},
    } = .{},
    transcript: std.ArrayList(u8) = .empty,
    agent_step_limit: usize = 24,
    fast_mode: bool = false,
    main_agent: struct {
        effort: types.ReasoningEffort = .auto,
        session: FakeSession = .{},
        worker: FakeWorker = .{},
    } = .{},
    cached_ids: ?[]const []const u8 = null,
    gateway_metadata_model: ?[]const u8 = null,
    gateway_metadata: model_capabilities.GatewayMetadata = .{},
    fetch_ids: []const []const u8 = &.{},
    fail_fetch: bool = false,
    last_tone: ?types.NoticeTone = null,
    model_cache_loading: bool = false,
    preference_commit_count: usize = 0,
    last_preference_model: std.ArrayList(u8) = .empty,
    last_preference_provider: ?model_provider.ProviderId = null,
    last_preference_effort: ?types.ReasoningEffort = null,
    last_preference_fast_mode: ?bool = null,
    last_preference_ultrafast_mode: ?bool = null,
    preference_settings_error: ?anyerror = null,
    preference_session_error: ?anyerror = null,
    preference_failure_cleanup: config_runtime.LegacyCleanup = .{},
    post_commit_resolution_error: ?anyerror = null,
    post_commit_resolution_diagnostic: ?config_runtime.ConfigDiagnosticCause = null,
    post_commit_resolution_count: usize = 0,
    permission_mode_preference_commit_count: usize = 0,
    last_preference_permission_mode: ?types.PermissionMode = null,
    semantic_write_count: usize = 0,
    terminal_title_label: [128]u8 = undefined,
    terminal_title_label_len: usize = 0,

    fn init(alloc: std.mem.Allocator, workspace_root: []const u8, model: []const u8) !FakeApp {
        var app = FakeApp{
            .alloc = alloc,
            .workspace_root = try alloc.dupe(u8, workspace_root),
        };
        errdefer app.deinit();
        try app.selected_model.appendSlice(alloc, model);
        return app;
    }

    fn deinit(self: *FakeApp) void {
        self.selected_model.deinit(self.alloc);
        self.auth.deinit(self.alloc);
        self.agent().worker.deinit();
        self.transcript.deinit(self.alloc);
        self.last_preference_model.deinit(self.alloc);
        self.preference_failure_cleanup.deinit(self.alloc);
        self.alloc.free(self.workspace_root);
        self.* = undefined;
    }

    fn writeDomainNotice(self: *FakeApp, notice: types.SemanticNotice, _: bool) !void {
        self.semantic_write_count += 1;
        self.last_tone = notice.tone;
        const rendered = if (notice.topic.len > 0)
            try self.alloc.print("{s} {s}: {s}\n", .{
                types.noticeGlyph(notice.tone),
                notice.topic,
                notice.body,
            })
        else
            try self.alloc.print("{s} {s}\n", .{ types.noticeGlyph(notice.tone), notice.body });
        defer self.alloc.free(rendered);
        try self.transcript.appendSlice(self.alloc, rendered);
    }

    fn text(self: *const FakeApp) []const u8 {
        return self.transcript.items;
    }

    fn clearTranscript(self: *FakeApp) void {
        self.transcript.clearRetainingCapacity();
    }

    fn toolRegistry(self: *const FakeApp, _: anytype) tool_dispatch.Registry {
        return self.tool_registry;
    }

    // Public so `@hasDecl` sees it from the session runtime, which is where
    // the terminal title is now resolved.
    pub fn terminalTitle(self: *FakeApp) host.TerminalTitle {
        return .{
            .context = self,
            .set_fn = setTerminalTitleLabelForTest,
            .clear_fn = clearTerminalTitleForTest,
        };
    }

    fn setTerminalTitleLabelForTest(raw: ?*anyopaque, label: []const u8) void {
        const self: *FakeApp = @ptrCast(@alignCast(raw.?));
        self.terminal_title_label_len = @min(label.len, self.terminal_title_label.len);
        @memcpy(
            self.terminal_title_label[0..self.terminal_title_label_len],
            label[0..self.terminal_title_label_len],
        );
    }

    fn clearTerminalTitleForTest(raw: ?*anyopaque) void {
        const self: *FakeApp = @ptrCast(@alignCast(raw.?));
        self.terminal_title_label_len = 0;
    }

    fn terminalTitleLabelText(self: *const FakeApp) []const u8 {
        return self.terminal_title_label[0..self.terminal_title_label_len];
    }

    fn snapshotCachedModelIds(self: *FakeApp, alloc: std.mem.Allocator) !?std.ArrayList([]u8) {
        if (self.cached_ids) |ids| return try makeStringList(alloc, ids);
        return null;
    }

    pub fn persistPermissionModePreference(self: *FakeApp, mode: types.PermissionMode) !void {
        self.permission_mode_preference_commit_count += 1;
        self.last_preference_permission_mode = mode;
    }

    pub fn resolvedModelCapabilities(self: *FakeApp, model: []const u8) model_capabilities.Capabilities {
        if (self.gateway_metadata_model) |metadata_model| {
            if (std.mem.eql(u8, metadata_model, model)) {
                return model_capabilities.resolveCapabilities(model, self.gateway_metadata);
            }
        }
        return model_capabilities.capabilitiesForModel(model);
    }

    pub fn isModelCacheLoading(self: *const FakeApp) bool {
        return self.model_cache_loading;
    }

    fn setGatewayControls(
        self: *FakeApp,
        model: []const u8,
        efforts: []const types.ReasoningEffort,
        supports_fast_mode: bool,
    ) void {
        self.gateway_metadata_model = model;
        self.gateway_metadata = .{
            .reasoning_efforts = .fromSlice(efforts),
            .supports_fast_mode = supports_fast_mode,
        };
    }

    fn fetchModelIds(self: *FakeApp) !std.ArrayList([]u8) {
        if (self.fail_fetch) return error.FetchFailed;
        return makeStringList(self.alloc, self.fetch_ids);
    }

    pub fn loadDetailedSettingsForNotice(self: *FakeApp) !config_runtime.DetailedSettings {
        self.post_commit_resolution_count += 1;
        if (self.post_commit_resolution_error) |err| return err;
        if (self.post_commit_resolution_diagnostic) |cause| {
            const diagnostics = try self.alloc.alloc(config_runtime.ConfigDiagnostic, 1);
            diagnostics[0] = .{ .layer = .user, .cause = cause };
            return .{
                .settings = .{},
                .diagnostics = diagnostics,
            };
        }
        return config_runtime.loadMergedSettingsDetailed(self.alloc, self.workspace_root);
    }

    pub fn persistRuntimePreferences(
        self: *FakeApp,
        _: anytype,
        patch: app_session_runtime.SessionPreferencePatch,
    ) app_session_runtime.PreferenceCommitResult {
        self.preference_commit_count += 1;
        self.last_preference_provider = patch.provider;
        self.last_preference_model.clearRetainingCapacity();
        if (patch.model) |model| {
            self.last_preference_model.appendSlice(self.alloc, model) catch
                return .{ .settings_error = error.OutOfMemory };
        }
        self.last_preference_effort = patch.effort;
        self.last_preference_fast_mode = patch.fast_mode;
        self.last_preference_ultrafast_mode = patch.ultrafast_mode;
        if (self.preference_settings_error == null) {
            const attempt = config_runtime.attemptUserPreferences(
                self.alloc,
                patch.userSettingsPatch(),
            );
            return switch (attempt) {
                .outcome => |outcome| .{
                    .settings_outcome = outcome,
                    .session_error = self.preference_session_error,
                },
                .failure => |failure| .{
                    .settings_error = failure.err,
                    .settings_failure_cleanup = failure.cleanup,
                    .session_error = self.preference_session_error,
                },
            };
        }
        const cleanup = self.preference_failure_cleanup;
        self.preference_failure_cleanup = .{};
        return .{
            .settings_error = self.preference_settings_error,
            .settings_failure_cleanup = cleanup,
            .session_error = self.preference_session_error,
        };
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

fn makeStringList(alloc: std.mem.Allocator, ids: []const []const u8) !std.ArrayList([]u8) {
    var list: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(alloc, &list);
    for (ids) |id| {
        try list.append(alloc, try alloc.dupe(u8, id));
    }
    return list;
}

fn expectTranscriptContains(app: *const FakeApp, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, app.text(), needle) != null);
}

const SessionCommandTestHome = struct {
    alloc: std.mem.Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: std.mem.Allocator, home: ?[]const u8) !*SessionCommandTestHome {
        const self = try alloc.create(SessionCommandTestHome);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        if (home) |value| {
            try self.map.put("HOME", value);
        }
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *SessionCommandTestHome) void {
        io_mod.resetEnvironForTest();
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn writeFixtureFile(dir: std.Io.Dir, sub_path: []const u8, text: []const u8) !void {
    var file = try dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}

fn expectStatusRow(snapshot: info_panel.Snapshot, label: []const u8, value: []const u8) !void {
    for (snapshot.rows) |row| {
        if (std.mem.eql(u8, row.label, label)) return std.testing.expectEqualStrings(value, row.value);
    }
    return error.TestExpectedEqual;
}

test "session_commands history setting toggles durable input history" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const workspace_root = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace",
    );
    defer alloc.free(workspace_root);

    const env = try SessionCommandTestHome.install(alloc, home_root);
    defer env.deinit();
    var app = try FakeHistoryCommandApp.init(
        alloc,
        home_root,
        workspace_root,
    );
    defer app.deinit();
    try Commands(FakeHistoryCommandApp).handleHistory(&app, "off");
    try std.testing.expect(!app.prompt_history.enabled);
    var disabled = try config_runtime.loadMergedSettings(
        alloc,
        workspace_root,
    );
    defer disabled.deinit(alloc);
    try std.testing.expectEqual(false, disabled.prompt_history_enabled.?);

    try Commands(FakeHistoryCommandApp).handleHistory(&app, "on");
    try std.testing.expect(app.prompt_history.enabled);
    var enabled = try config_runtime.loadMergedSettings(
        alloc,
        workspace_root,
    );
    defer enabled.deinit(alloc);
    try std.testing.expectEqual(true, enabled.prompt_history_enabled.?);
}
