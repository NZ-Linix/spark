const std = @import("std");
const profile_paths = @import("../shared/profile_paths.zig");
const agents = @import("../agents/agents.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const session_display_metadata = @import("../session/session_display_metadata.zig");
const app_bootstrap_runtime = @import("app_bootstrap_runtime.zig");
const io_mod = @import("../shared/io.zig");
const shell_snapshot = @import("../terminal/shell_snapshot.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const host = @import("../hosts/host.zig");
const change_tracker_mod = @import("../workspace/change_tracker.zig");
const command_router = @import("../slash_commands/command_router.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const config_runtime = @import("../config/config_runtime.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const editor_state = @import("../input/editor_state.zig");
const settings_catalog = @import("../config/settings_catalog.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const feedback_runtime = @import("../feedback/runtime.zig");
const output_contracts = @import("../output/output_contracts.zig");
const workspace_commands = @import("../workspace/workspace_commands.zig");
const image_commands = @import("../images/image_commands.zig");
const app_mcp_runtime = @import("app_mcp_runtime.zig");
const model_cache_runtime = @import("model_cache_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");
const permissions = @import("../permissions/permissions.zig");
const skill_commands = @import("../skills/skill_commands.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const text_utils = @import("../shared/text_utils.zig");
const prompts = @import("../prompts/prompts.zig");
const trace_report = @import("trace_report.zig");
const session_commands = @import("../session/session_commands.zig");
const info_panel = @import("../input/info_panel.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");
const test_builtin_skills = if (@import("builtin").is_test)
    @import("../../builtins/skills.zig")
else
    struct {};

fn finish_trace_notice(app: anytype, entry_id: u32, tone: types.NoticeTone, body: []const u8) !void {
    const notice: types.SemanticNotice = .{
        .topic = "",
        .tone = tone,
        .body = body,
    };
    if (!try app.replaceDomainNotice(entry_id, notice)) {
        _ = try app.appendDomainNotice(notice);
    }
    app.shell.render_requests.request(.transcript);
}

const TraceReportDisposition = union(enum) {
    copied_file: []const u8,
    copy_failed: []const u8,
    saved: []const u8,
    unavailable,
};

/// Returns an owned trace notice whose bytes belong to the caller.
fn format_trace_notice(
    alloc: std.mem.Allocator,
    disposition: TraceReportDisposition,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    switch (disposition) {
        .copied_file => try out.writer.writeAll("Trace copied to clipboard. Review and redact it before sharing."),
        .copy_failed => |path| try out.writer.print("Clipboard copy failed. Trace saved at {s}. Review and redact it before sharing.", .{path}),
        .saved => |path| try out.writer.print("Trace saved at {s}. Review and redact it before sharing.", .{path}),
        .unavailable => try out.writer.writeAll("Could not create trace."),
    }
    return out.toOwnedSlice();
}

fn persistUserPreferences(
    app: anytype,
    label: []const u8,
    patch: config_runtime.UserSettingsPatch,
    runtime_changed: bool,
) !void {
    var attempt = config_runtime.attemptUserPreferences(app.alloc, patch);
    defer attempt.deinit(app.alloc);
    switch (attempt) {
        .failure => |failure| try session_commands.reportUserSettingsFailure(
            app,
            label,
            failure.err,
            failure.cleanup,
            runtime_changed,
        ),
        .outcome => |outcome| _ = try session_commands.reportUserSettingsCommit(
            app,
            label,
            patch,
            outcome,
            null,
            true,
        ),
    }
}

fn clearSessionForClearCommand(app: anytype) !void {
    try app.clearSession(agents.screenAgentOf(app));
}

noinline fn parseWorkspaceCommand(rest: []const u8) !?workspace_commands.Action {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "list")) return null;
    if (std.mem.eql(u8, trimmed, "clear")) return .clear;
    if (std.mem.startsWith(u8, trimmed, "add") and trimmed.len > "add".len and
        std.ascii.isWhitespace(trimmed["add".len]))
    {
        const path = std.mem.trim(u8, trimmed["add".len..], " \t");
        if (path.len == 0) return error.InvalidWorkspaceCommand;
        return .{ .add = path };
    }
    if (std.mem.startsWith(u8, trimmed, "remove") and trimmed.len > "remove".len and
        std.ascii.isWhitespace(trimmed["remove".len]))
    {
        const path = std.mem.trim(u8, trimmed["remove".len..], " \t");
        if (path.len == 0) return error.InvalidWorkspaceCommand;
        return .{ .remove = path };
    }
    return error.InvalidWorkspaceCommand;
}

noinline fn tryBeginWorkspaceMutation(app: anytype) bool {
    if (agents.screenAgentOf(app).stream.active) return false;
    return agents.screenAgentOf(app).worker.tryHoldTurnStart();
}

fn refreshWorkspaceAvailabilityForList(app: anytype) !void {
    if (!tryBeginWorkspaceMutation(app)) return;
    defer agents.screenAgentOf(app).worker.releaseTurnStartHold();
    if (comptime @hasDecl(@TypeOf(app.*), "refreshWorkspaceAccess")) {
        _ = try app.refreshWorkspaceAccess();
    }
}

fn handleShellCommand(app: anytype, rest: []const u8) !void {
    if (!std.mem.eql(u8, std.mem.trim(u8, rest, " \t"), "reload")) {
        try app.writeDomainNotice(.{ .topic = "", .tone = .@"error", .body = "usage: /shell reload" }, true);
        return;
    }
    shell_snapshot.processOwner().markDirty(.user_reload);
    try app.writeDomainNotice(.{
        .topic = "shell",
        .tone = .neutral,
        .body = "The next command reloads your shell startup files. Remembered command approvals were reset.",
    }, true);
}

fn promptNotice(app: anytype, tone: anytype, comptime fmt: []const u8, args: anytype) !void {
    const message = try app.alloc.print(fmt, args);
    defer app.alloc.free(message);
    try app.writeDomainNotice(.{ .topic = "prompt", .tone = tone, .body = message }, true);
}

/// `/prompt`: list, choose, or reset the agent's whole system prompt, and
/// manage the folders prompts come from (`src/core/prompts/prompts.zig`).
fn handlePromptCommand(app: anytype, rest: []const u8) !void {
    // Test apps without a full agent have no prompt to change.
    if (comptime !agents.hasAgentField(@TypeOf(app.*), "custom_prompt")) return;
    const parsed = prompts.parseCommand(rest);
    if (parsed == .invalid) return app.writeDomainNotice(.{ .topic = "", .tone = .@"error", .body = prompts.usage }, true);
    const home = io_mod.homeDir() orelse
        return app.writeDomainNotice(.{ .topic = "prompt", .tone = .@"error", .body = "No home folder, so there are no prompt folders." }, true);
    var arena_state = std.heap.ArenaAllocator.init(app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const agent = agents.screenAgentOf(app);
    if (comptime @hasField(@TypeOf(app.*), "prompt_completion")) app.prompt_completion.deinit();
    switch (parsed) {
        .invalid => return,
        .add_dir, .remove_dir => |raw| {
            var resolved: []const u8 = raw;
            const adding = parsed == .add_dir;
            const change = (if (adding) prompts.addDir(arena, home, raw, &resolved) else prompts.removeDir(arena, home, raw, &resolved)) catch |err| {
                return promptNotice(app, .@"error", "Could not {s} prompt folder {f}: {s}", .{ if (adding) "add" else "remove", text_utils.terminalSafe(raw), @errorName(err) });
            };
            switch (change) {
                .added => try promptNotice(app, .neutral, "Added prompt folder {f}", .{text_utils.terminalSafe(resolved)}),
                .removed => try promptNotice(app, .neutral, "Removed prompt folder {f}", .{text_utils.terminalSafe(resolved)}),
                .unchanged => try promptNotice(app, .neutral, "Prompt folder {f} was already {s}", .{ text_utils.terminalSafe(resolved), if (adding) "listed" else "absent" }),
            }
        },
        .select => |name| {
            if (std.mem.eql(u8, name, prompts.default_name)) {
                agent.custom_prompt.deinit();
                return promptNotice(app, .neutral, "Using spark's own system prompt.", .{});
            }
            const dirs = prompts.loadDirs(arena, home) catch |err|
                return promptNotice(app, .@"error", "Could not read prompt folders: {s}", .{@errorName(err)});
            const entry = prompts.find(try prompts.list(arena, dirs), name) orelse
                return promptNotice(app, .@"error", "No prompt named {f}. Type /prompt to list them.", .{text_utils.terminalSafe(name)});
            const text = prompts.read(arena, entry.path) catch |err|
                return promptNotice(app, .@"error", "Could not read {f}: {s}", .{ text_utils.terminalSafe(entry.path), @errorName(err) });
            try agent.custom_prompt.set(app.alloc, entry.name, text);
            const file = std.Io.Dir.path.basename(entry.path);
            const shown = file[0 .. std.mem.findScalarLast(u8, file, '.') orelse file.len];
            try promptNotice(app, .neutral, "System prompt is now {f}; spark sends it alone.", .{text_utils.terminalSafe(shown)});
        },
        .show => {
            // Bare `/prompt` opens the inline picker.
            if (comptime @hasField(@TypeOf(app.*), "input_runtime")) {
                if (comptime @hasField(@TypeOf(app.input_runtime), "list_picker")) return openPromptPicker(app);
            }
            const dirs = prompts.loadDirs(arena, home) catch |err|
                return promptNotice(app, .@"error", "Could not read prompt folders: {s}", .{@errorName(err)});
            const entries = try prompts.list(arena, dirs);
            var out: std.Io.Writer.Allocating = .init(arena);
            const w = &out.writer;
            try w.print("Active: {f}\n\nFolders:", .{text_utils.terminalSafe(agent.custom_prompt.name)});
            if (dirs.len == 0) try w.writeAll(" none. Add one with /prompt dir add PATH");
            for (dirs) |dir| try w.print("\n  {f}", .{text_utils.terminalSafe(dir)});
            try w.writeAll("\n\nPrompts:\n  default");
            for (entries) |entry| try w.print("\n  {f}", .{text_utils.terminalSafe(entry.name)});
            try app.writeDomainNotice(.{ .topic = "prompt", .tone = .neutral, .body = out.written() }, true);
        },
    }
}

/// Opens `/prompt`'s picker: spark's own prompt, every prompt in the
/// folders, then adding and removing folders.
pub fn openPromptPicker(app: anytype) !void {
    return reopenPromptPicker(app, null);
}

/// Builds `/prompt`'s picker. Starred prompts get their own section at the
/// top. With `keep`, the filter typed so far and the selection on the item
/// whose value is `keep` survive the rebuild, as after starring.
fn reopenPromptPicker(app: anytype, keep: ?[]const u8) !void {
    if (comptime !agents.hasAgentField(@TypeOf(app.*), "custom_prompt")) return;
    const list_picker = @import("../input/list_picker.zig");
    var arena_state = std.heap.ArenaAllocator.init(app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = io_mod.homeDir() orelse "";
    const config: prompts.Config = if (home.len > 0) prompts.loadConfig(arena, home) catch .{} else .{};
    const entries = try prompts.list(arena, config.dirs);
    const current = agents.screenAgentOf(app).custom_prompt.name;
    var starred_count: usize = 0;
    for (entries) |entry| starred_count += @intFromBool(prompts.isStarred(config.starred, entry.name));

    var items: std.ArrayList(list_picker.Item) = .empty;
    if (starred_count > 0) {
        try items.append(arena, .{ .label = "★ Starred", .value = "", .section = true });
        for (entries) |entry| if (prompts.isStarred(config.starred, entry.name)) {
            try items.append(arena, try promptPickerItem(arena, entry, current, true));
        };
        try items.append(arena, .{ .label = "All prompts", .value = "", .section = true });
    }
    try items.append(arena, .{ .label = "Default", .detail = "spark's own system prompt", .value = prompts.default_name, .marked = std.mem.eql(u8, current, prompts.default_name) });
    for (entries) |entry| if (!prompts.isStarred(config.starred, entry.name)) {
        try items.append(arena, try promptPickerItem(arena, entry, current, false));
    };
    try items.append(arena, .{ .label = "+ Add prompt folder", .detail = "", .value = "+add", .action = true });
    for (config.dirs) |dir| try items.append(arena, .{
        .label = try arena.print("- Remove {s}", .{std.Io.Dir.path.basename(dir)}),
        .detail = dir,
        .value = try arena.print("-dir:{s}", .{dir}),
        .action = true,
    });
    const title = if (config.dirs.len == 0) "System prompts · add a folder to list yours" else "System prompts";

    const picker = &app.input_runtime.list_picker;
    const filter = if (keep != null) try arena.dupe(u8, picker.filter.items()) else "";
    const cursor = picker.filter.cursor;
    try picker.open(app.alloc, .prompt, title, items.items);
    if (keep) |value| {
        for (filter) |byte| try picker.filter.insert(app.alloc, byte);
        picker.filter.cursor = @min(cursor, filter.len);
        picker.filterChanged();
        picker.selectValue(value);
    }
    app.shell.render_requests.request(.footer);
}

fn promptPickerItem(arena: std.mem.Allocator, entry: prompts.Entry, current: []const u8, starred: bool) !@import("../input/list_picker.zig").Item {
    const folder = std.Io.Dir.path.dirname(entry.path) orelse "";
    return .{
        .label = prompts.displayName(entry),
        .detail = std.Io.Dir.path.basename(folder),
        .value = try arena.dupe(u8, entry.name),
        .marked = std.mem.eql(u8, current, entry.name),
        .starred = starred,
    };
}

/// Tab in `/prompt`'s picker: stars or unstars the selected prompt and
/// keeps the selection on it.
pub fn promptPickerToggleStar(app: anytype) !void {
    const picker = &app.input_runtime.list_picker;
    if (picker.purpose != .prompt or picker.mode != .pick) return;
    const item = picker.selectedItem() orelse return;
    if (item.action or item.section or std.mem.eql(u8, item.value, prompts.default_name)) return;
    const home = io_mod.homeDir() orelse return;
    var arena_state = std.heap.ArenaAllocator.init(app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = try arena.dupe(u8, item.value);
    _ = prompts.toggleStar(arena, home, value) catch |err| {
        debug_trace.logf("prompts", "star toggle failed err={s}", .{@errorName(err)});
        return;
    };
    try reopenPromptPicker(app, value);
}

/// Enter in `/prompt`'s picker: on the list, the chosen item; on the input
/// line, the folder typed.
pub fn promptPickerEnter(app: anytype) !void {
    const picker = &app.input_runtime.list_picker;
    const home = io_mod.homeDir() orelse return picker.close(app.alloc);
    var arena_state = std.heap.ArenaAllocator.init(app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (picker.mode == .input) {
        const raw = std.mem.trim(u8, picker.input.items(), " \t");
        if (raw.len == 0) {
            picker.problem = "Type a folder's path, such as ~/Documents/Prompts.";
            return;
        }
        var resolved: []const u8 = raw;
        _ = prompts.addDir(arena, home, raw, &resolved) catch |err| {
            picker.problem = switch (err) {
                error.FileNotFound => "No folder at that path.",
                error.NotDir => "That path is a file, not a folder.",
                error.TooManyDirs => "That's the most folders spark lists.",
                else => "spark couldn't add that folder.",
            };
            return;
        };
        return openPromptPicker(app);
    }
    const item = picker.selectedItem() orelse return;
    if (std.mem.eql(u8, item.value, "+add")) return picker.ask("Add a prompt folder: type its path, Enter adds it");
    if (std.mem.startsWith(u8, item.value, "-dir:")) {
        var resolved: []const u8 = "";
        _ = prompts.removeDir(arena, home, item.value[5..], &resolved) catch {};
        return openPromptPicker(app);
    }
    const name = try arena.dupe(u8, item.value);
    picker.close(app.alloc);
    try handlePromptCommand(app, name);
}

fn handleWorkspaceCommand(app: anytype, rest: []const u8) !void {
    const maybe_action = parseWorkspaceCommand(rest) catch {
        try app.writeDomainNotice(.{
            .topic = "",
            .tone = .@"error",
            .body = "usage: /workspace [add PATH|remove PATH|clear]",
        }, true);
        return;
    };
    const action = maybe_action orelse {
        refreshWorkspaceAvailabilityForList(app) catch |err| {
            const reason = output_contracts.workspaceErrorMessage(err) orelse "workspace refresh failed";
            const message = try app.alloc.print("Workspace refresh rejected: {s}", .{reason});
            defer app.alloc.free(message);
            try app.writeDomainNotice(.{
                .topic = "workspace",
                .tone = .@"error",
                .body = message,
            }, true);
            return;
        };
        return writeWorkspaceSnapshot(app, null);
    };

    if (!tryBeginWorkspaceMutation(app)) {
        try app.writeDomainNotice(.{
            .topic = "workspace",
            .tone = .neutral,
            .body = "Workspace changes are unavailable until the active and queued work finishes.",
        }, true);
        return;
    }
    defer agents.screenAgentOf(app).worker.releaseTurnStartHold();

    var failure_phase: workspace_commands.FailurePhase = .stage;
    var result = workspace_commands.execute(
        app.alloc,
        app.workspace_root,
        app.workspaceAccess(),
        action,
        &failure_phase,
    ) catch |err| {
        const reason = output_contracts.workspaceErrorMessage(err) orelse "workspace update failed";
        const prefix: []const u8 = switch (failure_phase) {
            .stage => "Workspace update rejected",
            .commit => "Workspace settings were not changed",
            .reconcile => "Workspace settings are uncertain and could not be reloaded",
        };
        const message = try app.alloc.print("{s}: {s}", .{ prefix, reason });
        defer app.alloc.free(message);
        try app.writeDomainNotice(.{
            .topic = "workspace",
            .tone = .@"error",
            .body = message,
        }, true);
        return;
    };
    defer result.deinit(app.alloc);

    switch (result) {
        .updated => |*updated| {
            _ = app.installWorkspaceAccess(&updated.access);
            try writeWorkspaceSnapshot(app, updated.mutation);
        },
        .indeterminate => |*reconciliation| {
            const message: []const u8 = switch (reconciliation.*) {
                .intended => |*reconciled| blk: {
                    _ = app.installWorkspaceAccess(reconciled);
                    break :blk "Workspace settings durability is uncertain; reloaded settings match the requested update.";
                },
                .previous => |*reconciled| blk: {
                    _ = app.installWorkspaceAccess(reconciled);
                    break :blk "Workspace settings durability is uncertain; reloaded settings match the previous state, so the update is not active.";
                },
                .unconfirmed => "Workspace settings durability is uncertain; reloaded settings match neither the requested nor previous state, so runtime access is unchanged.",
            };
            try app.writeDomainNotice(.{
                .topic = "workspace",
                .tone = .warning,
                .body = message,
            }, true);
        },
    }
}

fn writeWorkspaceSnapshot(
    app: anytype,
    mutation: ?workspace_commands.Mutation,
) !void {
    var snapshot = output_contracts.WorkspaceSnapshot.fromAccess(app.workspace_root, app.workspaceAccess());
    snapshot.mutation = mutation;
    const body = try snapshot.renderInteractiveBody(app.alloc);
    defer app.alloc.free(body);
    try app.writeDomainNotice(.{
        .topic = "workspace",
        .tone = .neutral,
        .body = body,
    }, true);
}

fn requestResumeExit(app: anytype) void {
    const App = @TypeOf(app.*);
    app_session_runtime.Runtime(App).requestResumeHandoff(agents.screenAgentOf(app));
    app.should_exit = true;
}

pub fn Handlers(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        pub fn route(app: *App, cmd: []const u8) !void {
            const handlers = commandHandlers(app);
            try command_router.route(app.slashRegistry(), &handlers, cmd);
        }

        pub fn commandHandlers(app: *App) command_router.CommandHandlers {
            return .{
                .ctx = @ptrCast(app),
                .quit = commandQuit,
                .clear_screen = commandClearScreen,
                .new_session = commandNewSession,
                .launch_instance = commandLaunchInstance,
                .close_instance = commandCloseInstance,
                .show_agents = commandShowAgents,
                .reset_session = commandResetSession,
                .resume_session = commandResumeSession,
                .fork_session = commandForkSession,

                .show_help = commandShowHelp,
                .provider = commandProvider,
                .show_status = commandShowStatus,
                .attach_image = commandAttachImage,
                .manage_images = commandManageImages,
                .handle_model = commandHandleModel,
                .handle_effort = commandHandleEffort,
                .show_stats = commandShowStats,
                .undo_last = commandUndoLast,
                .handle_mcp = commandHandleMcp,
                .handle_skills = commandHandleSkills,
                .copy_last = commandCopyLast,
                .submit_feedback = commandSubmitFeedback,
                .create_trace = commandCreateTrace,
                .compact_history = commandCompactHistory,
                .handle_settings = commandHandleSettings,
                .paste_clipboard = commandPasteClipboard,
                .handle_fast = commandHandleFast,
                .handle_ultrafast = commandHandleUltrafast,
                .handle_statusline = commandHandleStatusline,
                .rename_session = commandRenameSession,
                .handle_notifications = commandHandleNotifications,
                .handle_workspace = commandHandleWorkspace,
                .handle_shell = commandHandleShell,
                .handle_prompt = commandHandlePrompt,
                .show_version = commandShowVersion,
                .check_update = commandCheckUpdate,
                .unknown = commandUnknown,
            };
        }

        /// What the MCP host and `/mcp` have to say, and the reload a `/mcp` change asked for.
        fn closeOtherMenusForMcp(app: *App, agent: *AppAgent) void {
            closeModelMenuIfPresent(app);
            closeHelpMenuIfPresent(app);
            closeInlineCommandMenusIfPresent(app);
            if (comptime @hasField(App, "skills")) app.skills.closeMenu();
            if (comptime @hasField(App, "input_runtime")) {
                if (comptime @hasField(@TypeOf(app.input_runtime), "settings_menu")) {
                    app.input_runtime.settings_menu.close();
                }
            }
            if (comptime agents.hasAgentField(App, "session_persistence")) {
                agent.session_persistence.session_picker.active = false;
            }
        }

        pub fn collectMcpHostFacts(app: *App, agent: *AppAgent) !void {
            if (comptime !@hasDecl(App, "takeMcpHostNotices")) return;
            // A reload that fails leaves its warning among the notices.
            app.applyMcpHostReload(agent);
            const notices = app.takeMcpHostNotices();
            defer {
                for (notices) |n| std.heap.c_allocator.free(n.text);
                std.heap.c_allocator.free(notices);
            }
            for (notices) |n| try app.writeDomainNotice(.{ .topic = "mcp", .tone = if (n.warning) .warning else .neutral, .body = n.text }, true);
            app.refreshMcpCompletion();
            app.refreshMcpHostMenu();
            app.refreshMcpHostStatus();
        }

        pub fn collectShellSnapshotFacts(app: *App) !void {
            var buffer: [shell_snapshot.max_notice_bytes]u8 = undefined;
            const notice = shell_snapshot.processOwner().takeUiNotice(&buffer) orelse return;
            try app.writeDomainNotice(.{ .topic = "shell", .tone = .warning, .body = notice }, true);
        }

        fn handleFeedback(app: *App) !void {
            try app.flushBeforeBlockingExternalWork();
            const opened = if (comptime @hasDecl(App, "urlOpener"))
                app.urlOpener().open(app.alloc, feedback_runtime.url) catch false
            else
                false;
            if (opened) {
                try app.writeDomainNotice(.{
                    .topic = "",
                    .tone = .neutral,
                    .body = "Opened https://github.com/NZ-Linix/spark/issues.",
                }, true);
                return;
            }
            try app.writeDomainNotice(.{
                .topic = "",
                .tone = .@"error",
                .body = "Could not open https://github.com/NZ-Linix/spark/issues. Open it manually.",
            }, true);
        }

        fn handleTraceReport(app: *App) !void {
            const progress_entry_id = try app.appendReplaceableDomainNotice(.{
                .topic = "",
                .tone = .neutral,
                .body = "Preparing trace...",
            });
            app.shell.render_requests.request(.transcript);
            try app.flushBeforeBlockingExternalWork();

            const report = trace_report.build(app) catch {
                try finish_trace_notice(app, progress_entry_id, .@"error", "Failed to build trace.");
                return;
            };
            defer app.alloc.free(report);

            const builtin = @import("builtin");
            const report_path: ?[]u8 = trace_report.writeFile(app.alloc, report) catch null;
            defer if (report_path) |path| app.alloc.free(path);
            const disposition: TraceReportDisposition = if (report_path) |path| blk: {
                const copied = if (comptime @hasDecl(App, "clipboard"))
                    app.clipboard().copy_file(app.alloc, path) catch false
                else
                    false;
                if (copied) break :blk .{ .copied_file = path };
                if (builtin.target.os.tag == .macos) break :blk .{ .copy_failed = path };
                break :blk .{ .saved = path };
            } else blk: {
                break :blk .unavailable;
            };
            const body = try format_trace_notice(app.alloc, disposition);
            defer app.alloc.free(body);
            const tone: types.NoticeTone = switch (disposition) {
                .copied_file, .saved => .neutral,
                .copy_failed, .unavailable => .@"error",
            };
            try finish_trace_notice(app, progress_entry_id, tone, body);
        }

        fn commandQuit(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasField(App, "terminal")) app.terminal.clear_screen_on_exit = true;
            requestResumeExit(app);
        }

        fn commandClearScreen(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try clearSessionForClearCommand(app);
        }

        fn commandResetSession(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.resetSession(agents.screenAgentOf(app));
        }

        fn commandNewSession(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.newSession(agents.screenAgentOf(app));
        }

        /// `/launch [profile]` starts another instance on the host with a
        /// fresh session, in `profile` or the launch profile, and shows it.
        fn commandLaunchInstance(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime !@hasDecl(App, "launchInstance")) return;
            const name = std.mem.trim(u8, rest, " \t\r\n");
            try app.launchInstance(if (name.len == 0) null else name);
        }

        /// `/close` closes the instance on screen; closing the last one ends
        /// spark.
        fn commandCloseInstance(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime !@hasDecl(App, "closeInstanceOnScreen")) return;
            try app.closeInstanceOnScreen();
        }

        /// `/agents` lists the open instances to switch to one; with one
        /// open it says how to start another.
        fn commandShowAgents(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime !@hasDecl(App, "openAgentsMenu")) return;
            try app.openAgentsMenu();
        }

        fn commandResumeSession(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_session_runtime.Runtime(App).openSessionPicker(app, agents.screenAgentOf(app));
        }

        fn commandForkSession(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_session_runtime.Runtime(App).openForkMenu(app, agents.screenAgentOf(app));
        }

        fn commandRenameSession(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try handleRenameCommand(app, rest);
        }

        fn commandShowHelp(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasField(App, "skills")) app.skills.closeMenu();
            if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
            app.input_runtime.help_menu.open();
            app.shell.render_requests.request(.footer);
        }

        /// `/provider` opens the form that adds, edits, or removes an
        /// OpenAI-compatible endpoint.
        fn commandProvider(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime !@hasField(App, "input_runtime") or !@hasDecl(App, "saveConnection")) {
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .@"error",
                    .body = "/provider is not available in this runtime",
                }, true);
                return;
            }
            if (comptime @hasField(App, "skills")) app.skills.closeMenu();
            if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
            closeHelpMenuIfPresent(app);
            app.input_runtime.settings_menu.close();
            app.input_runtime.effort_menu.close(app.alloc);
            closeInlineCommandMenusIfPresent(app);
            try @import("app_provider_menu_runtime.zig").Runtime(App).open(app);
            app.shell.render_requests.request(.footer);
        }

        /// `/status` opens its panel in the footer, and
        /// writes nothing to the transcript.
        fn commandShowStatus(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            openInfoPanel(app, try session_commands.Commands(App).openStatusSnapshot(app, agents.screenAgentOf(app)));
        }

        /// Shows `snapshot` in place of any other footer menu. Takes ownership.
        fn openInfoPanel(app: *App, snapshot: info_panel.Snapshot) void {
            closeFooterMenus(app);
            app.input_runtime.info_panel.open(snapshot);
            app.shell.render_requests.request(.footer);
        }

        /// Rebuilds the open `/status` panel when a running
        /// turn changed what it shows. Returns whether it did, so the footer
        /// repaints.
        pub fn collectInfoPanelFacts(app: *App) !bool {
            const panel = &app.input_runtime.info_panel;
            if (!panel.active) return false;
            const shown = if (panel.snapshot) |*snapshot| snapshot else return false;
            // The panel shows the agent on screen, so it refreshes from it.
            const agent = agents.screenAgentOf(app);
            const next = (switch (shown.kind()) {
                .status => try session_commands.Commands(App).refreshedStatusSnapshot(app, agent, shown),
            }) orelse return false;
            panel.replace(next);
            return true;
        }

        fn commandAttachImage(ctx: *anyopaque, path: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try image_commands.Commands(App).attachPath(app, path);
        }

        fn commandManageImages(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try image_commands.Commands(App).managePending(app, agents.screenAgentOf(app), rest);
        }

        fn commandHandleModel(ctx: *anyopaque, query: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try session_commands.Commands(App).handleModel(app, agents.screenAgentOf(app), query);
        }

        /// Bare `/effort` opens the menu of the current model's reasoning
        /// effort levels; `/effort <level>` applies one.
        fn commandHandleEffort(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            // `/effort` sets the agent on screen's effort, as `/model` sets its model.
            const agent = agents.screenAgentOf(app);
            switch (try session_commands.Commands(App).handleEffort(app, agent, rest)) {
                .done => {},
                .open_menu => |capabilities| {
                    if (comptime @hasField(App, "skills")) app.skills.closeMenu();
                    if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
                    closeHelpMenuIfPresent(app);
                    app.input_runtime.settings_menu.close();
                    closeInlineCommandMenusIfPresent(app);
                    try app.input_runtime.effort_menu.open(app.alloc, provider_runtime.modelOf(app, agent), capabilities, agent.effort);
                    app.shell.render_requests.request(.footer);
                },
            }
        }

        /// Bare `/permissions` opens its panel and writes nothing to the
        /// transcript; a subcommand changes the mode or a saved-session rule.
        fn commandShowStats(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            var buf: [256]u8 = undefined;
            const body = try std.mem.print(
                &buf,
                "ansi_bytes={d}, redraws={d}, debounced_resizes={d}, footer_updates={d}, stream_chunks={d}",
                .{ app.metrics.ansi_bytes, app.metrics.full_redraws, app.metrics.debounced_resizes, app.metrics.footer_line_updates, app.metrics.stream_chunks },
            );
            try app.writeDomainNotice(.{
                .topic = "stats",
                .tone = .neutral,
                .body = body,
            }, true);
        }

        fn commandUndoLast(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const result = agents.screenAgentOf(app).change_tracker.undoLast(std.heap.c_allocator);
            const msg = switch (result) {
                .restored => |path| blk: {
                    var display_path = try text_utils.encodeTerminalSafe(
                        app.alloc,
                        path,
                        std.Io.Dir.max_path_bytes,
                    );
                    defer display_path.deinit(app.alloc);
                    break :blk try app.alloc.print("Restored {s}", .{display_path.bytes});
                },
                .deleted => |path| blk: {
                    var display_path = try text_utils.encodeTerminalSafe(
                        app.alloc,
                        path,
                        std.Io.Dir.max_path_bytes,
                    );
                    defer display_path.deinit(app.alloc);
                    break :blk try app.alloc.print("Deleted {s} (was newly created)", .{display_path.bytes});
                },
                .unavailable => |path| blk: {
                    var display_path = try text_utils.encodeTerminalSafe(
                        app.alloc,
                        path,
                        std.Io.Dir.max_path_bytes,
                    );
                    defer display_path.deinit(app.alloc);
                    break :blk try app.alloc.print(
                        "Could not undo {s}",
                        .{display_path.bytes},
                    );
                },
                .empty => try app.alloc.dupe(u8, "Nothing to undo."),
            };
            defer app.alloc.free(msg);
            switch (result) {
                .restored => |path| std.heap.c_allocator.free(path),
                .deleted => |path| std.heap.c_allocator.free(path),
                .unavailable => |path| std.heap.c_allocator.free(path),
                .empty => {},
            }
            try app.writeDomainNotice(.{
                .topic = "undo",
                .tone = .neutral,
                .body = msg,
            }, true);
        }

        fn commandHandleMcp(ctx: *anyopaque, rest: []const u8) !void {
            if (comptime !@hasDecl(App, "runMcpVerbs")) return;
            const app: *App = @ptrCast(@alignCast(ctx));
            const command = std.mem.trim(u8, rest, " \t");
            // `/mcp` alone opens the menu, and `/mcp VERB` runs the verbs
            // `spark mcp` has.
            if (command.len > 0) return app.runMcpVerbs(command);
            closeOtherMenusForMcp(app, agents.screenAgentOf(app));
            app.openMcpHostMenu();
            app.shell.render_requests.request(.footer);
        }

        noinline fn commandHandleSkills(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const provider = app.skillsCommandProvider();
            const command = provider.parseCommand(rest);

            if (comptime @hasDecl(App, "requestSkillsRefresh")) switch (command) {
                .list => {
                    const generation = try app.requestSkillsRefresh();
                    try app.skills.queueRefreshAction(app.alloc, generation, .list);
                    try collectSkillsRefreshFacts(app, agents.screenAgentOf(app));
                    return;
                },
                .show => |name| {
                    const generation = try app.requestSkillsRefresh();
                    try app.skills.queueRefreshAction(
                        app.alloc,
                        generation,
                        .{ .show = name },
                    );
                    try collectSkillsRefreshFacts(app, agents.screenAgentOf(app));
                    return;
                },
                .install, .create, .remove, .path, .usage => {},
            };
            try executeSkillsCommand(app, agents.screenAgentOf(app), provider, command);
            try collectSkillsRefreshFacts(app, agents.screenAgentOf(app));
        }

        pub fn collectSkillsRefreshFacts(app: *App, agent: *AppAgent) !void {
            var ready = app.skills.takeReadyRefreshAction() orelse return;
            defer ready.deinit(app.alloc);
            if (!ready.succeeded) {
                try app.writeDomainNotice(.{
                    .topic = "skills",
                    .tone = .@"error",
                    .body = if (ready.action == .startup_notice)
                        "Skills could not be loaded. Run /skills to try again."
                    else
                        "Skills could not be refreshed. The previous catalog was not shown as current.",
                }, true);
                return;
            }
            switch (ready.action) {
                .startup_notice => try app_bootstrap_runtime.Runtime(App).writeSkillDiagnosticsNotice(app, agent),
                .list => try executeSkillsCommand(
                    app,
                    agent,
                    app.skillsCommandProvider(),
                    .list,
                ),
                .show => |name| try executeSkillsCommand(
                    app,
                    agent,
                    app.skillsCommandProvider(),
                    .{ .show = name },
                ),
                .notice => |body| try app.writeDomainNotice(.{
                    .topic = noticeTopicForBody("skills", body),
                    .tone = .neutral,
                    .body = body,
                }, true),
            }
        }

        fn executeSkillsCommand(
            app: *App,
            agent: *AppAgent,
            provider: skill_commands.Provider,
            command: skill_commands.Command,
        ) !void {
            try writeSkillDiagnosticNotice(app, agent);

            switch (command) {
                .install => |install| {
                    const install_notice = try app.alloc.print("Installing from {s}...", .{install.source});
                    defer app.alloc.free(install_notice);
                    try app.writeDomainNotice(.{
                        .topic = "skills",
                        .tone = .neutral,
                        .body = install_notice,
                    }, true);
                },
                .show => |name| switch (skill_runtime.resolveSkill(app.skills.items, name, null)) {
                    .ambiguous_name => {
                        closeModelMenuIfPresent(app);
                        closeHelpMenuIfPresent(app);
                        try app.input_runtime.textReplacementState().replace(app.alloc, name);
                        app.skills.openMenuWithQuery(.command, null, name);
                        app.shell.render_requests.request(.footer);
                        return;
                    },
                    .found, .not_found, .name_location_mismatch => {},
                },
                else => {},
            }

            var result = try provider.executeCommand(app.alloc, command, .{
                .skills_dir = app.skills.dir,
                .find_ctx = @ptrCast(app),
                .find_skill = findSkillForProvider,
            });
            defer result.deinit(app.alloc);

            try applySkillsCommandResult(app, &result);
        }

        /// Usage lines name the command; a topic tag would repeat it.
        fn noticeTopicForBody(comptime default: []const u8, body: []const u8) []const u8 {
            return if (std.mem.startsWith(u8, body, "usage:")) "" else default;
        }

        fn findSkillForProvider(ctx: *anyopaque, name: []const u8) ?skill_commands.SkillInfo {
            const app: *App = @ptrCast(@alignCast(ctx));
            var fallback: ?skill_runtime.Skill = null;
            for (app.skills.items) |skill| {
                if (!std.mem.eql(u8, skill.name, name)) continue;
                if (skill_runtime.isManagedInstallSkill(skill)) return skillInfoForProvider(skill);
                if (fallback == null) fallback = skill;
            }
            const skill = fallback orelse return null;
            return skillInfoForProvider(skill);
        }

        fn skillInfoForProvider(skill: skill_runtime.Skill) skill_commands.SkillInfo {
            return .{
                .path = skill.path,
                .source_label = skill_runtime.skillSourceLabel(skill.source),
                .managed_install = skill_runtime.isManagedInstallSkill(skill),
            };
        }

        fn writeSkillDiagnosticNotice(app: *App, agent: *AppAgent) !void {
            if (app.skills.diagnostics.len == 0) return;

            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            try skill_runtime.writeDiagnosticSummary(app.alloc, &out.writer, app.skills.diagnostics);
            const body = try out.toOwnedSlice();
            defer app.alloc.free(body);
            if (comptime agents.hasAgentField(App, "session") and @hasDecl(@TypeOf(agent.session), "claimContextNotice")) {
                _ = try agent.session.claimContextNotice(app.alloc, body);
            }
            try app.writeDomainNotice(.{
                .topic = "skills",
                .tone = .warning,
                .body = body,
                .visibility = .full_only,
            }, true);
        }

        fn applySkillsCommandResult(app: *App, result: *const skill_commands.CommandResult) !void {
            switch (result.*) {
                .open_menu => {
                    closeModelMenuIfPresent(app);
                    closeHelpMenuIfPresent(app);
                    app.skills.openMenu();
                    app.shell.render_requests.request(.footer);
                },
                .focus_menu => |name| {
                    closeModelMenuIfPresent(app);
                    closeHelpMenuIfPresent(app);
                    if (app.skills.openMenuFocusedByName(name)) {
                        app.shell.render_requests.request(.footer);
                    }
                },
                .notice => |notice| {
                    if (notice.reload and comptime @hasDecl(App, "requestSkillsRefresh")) {
                        try queueSkillsNoticeAfterRefresh(app, notice.text);
                    } else {
                        try app.writeDomainNotice(.{
                            .topic = noticeTopicForBody("skills", notice.text),
                            .tone = .neutral,
                            .body = notice.text,
                        }, true);
                    }
                },
                .installed => |install_result| {
                    var installed_notice: std.Io.Writer.Allocating = .init(app.alloc);
                    defer installed_notice.deinit();

                    for (install_result.installed.items) |name| {
                        try installed_notice.writer.print("Installed: {s}\n", .{name});
                    }

                    const msg = try installed_notice.toOwnedSlice();
                    defer app.alloc.free(msg);
                    if (comptime @hasDecl(App, "requestSkillsRefresh")) {
                        try queueSkillsNoticeAfterRefresh(
                            app,
                            std.mem.trimEnd(u8, msg, "\n"),
                        );
                    } else {
                        try app.writeDomainNotice(.{
                            .topic = "skills",
                            .tone = .neutral,
                            .body = std.mem.trimEnd(u8, msg, "\n"),
                        }, true);
                    }
                },
            }
        }

        fn queueSkillsNoticeAfterRefresh(app: *App, body: []const u8) !void {
            const generation = try app.requestSkillsRefresh();
            try app.skills.queueRefreshAction(
                app.alloc,
                generation,
                .{ .notice = body },
            );
        }

        fn closeModelMenuIfPresent(app: *App) void {
            if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
        }

        noinline fn closeHelpMenuIfPresent(app: *App) void {
            if (comptime @hasField(App, "input_runtime")) {
                if (comptime @hasField(@TypeOf(app.input_runtime), "help_menu")) {
                    app.input_runtime.help_menu.close();
                }
            }
        }

        /// Closes every footer menu and panel, so another can open in its place.
        pub fn closeFooterMenus(app: *App) void {
            if (comptime @hasField(App, "skills")) app.skills.closeMenu();
            if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
            closeHelpMenuIfPresent(app);
            app.input_runtime.settings_menu.close();
            closeInlineCommandMenusIfPresent(app);
        }

        fn closeInlineCommandMenusIfPresent(app: *App) void {
            if (comptime @hasDecl(App, "closeAgentsMenu")) app.closeAgentsMenu();
            if (comptime !@hasField(App, "input_runtime")) return;
            const InputRuntime = @TypeOf(app.input_runtime);
            if (comptime @hasField(InputRuntime, "statusline_menu")) app.input_runtime.statusline_menu.close();
            if (comptime @hasField(InputRuntime, "info_panel")) app.input_runtime.info_panel.close();
            if (comptime @hasField(InputRuntime, "workspace_menu")) app.input_runtime.workspace_menu.close();
            if (comptime @hasField(InputRuntime, "effort_menu")) app.input_runtime.effort_menu.close(app.alloc);
        }

        fn commandCopyLast(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const last_reply = agents.screenAgentOf(app).session.lastAssistantReply() orelse {
                try app.writeDomainNotice(.{
                    .topic = "clipboard",
                    .tone = .neutral,
                    .body = "No assistant reply to copy.",
                }, true);
                return;
            };
            const copied = app.clipboard().copy(last_reply) catch false;
            if (!copied) {
                try app.writeDomainNotice(.{
                    .topic = "clipboard",
                    .tone = .@"error",
                    .body = "Failed to copy to clipboard.",
                }, true);
                return;
            }
            try app.writeDomainNotice(.{
                .topic = "clipboard",
                .tone = .neutral,
                .body = "Copied to clipboard.",
            }, true);
        }

        fn commandSubmitFeedback(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try handleFeedback(app);
        }

        fn commandCreateTrace(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try handleTraceReport(app);
        }

        fn commandCompactHistory(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "request_context_compaction")) {
                return app.request_context_compaction(agents.screenAgentOf(app));
            }
            try app.writeDomainNotice(.{
                .topic = "context",
                .tone = .neutral,
                .body = "No context to compact.",
            }, true);
        }

        fn commandHandleSettings(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (std.mem.trim(u8, rest, " \t").len == 0) {
                var settings = config_runtime.loadMergedSettings(app.alloc, app.workspace_root) catch {
                    try session_commands.Commands(App).handleSettings(app, rest);
                    return;
                };
                defer settings.deinit(app.alloc);
                if (comptime @hasField(App, "skills")) app.skills.closeMenu();
                if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
                closeHelpMenuIfPresent(app);
                closeInlineCommandMenusIfPresent(app);
                app.input_runtime.settings_menu.openWithStartupScrollback(
                    settings.startup_scrollback orelse true,
                );
                app.shell.render_requests.request(.footer);
                return;
            }
            try session_commands.Commands(App).handleSettings(app, rest);
        }

        fn commandPasteClipboard(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try image_commands.Commands(App).attachClipboard(app);
        }

        fn commandHandleFast(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try session_commands.Commands(App).handleFast(app, agents.screenAgentOf(app), rest);
        }

        fn commandHandleUltrafast(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try session_commands.Commands(App).handleUltrafast(app, agents.screenAgentOf(app), rest);
        }

        fn commandHandleStatusline(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (std.mem.trim(u8, rest, " \t").len == 0) {
                if (comptime @hasField(App, "skills")) app.skills.closeMenu();
                if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
                closeHelpMenuIfPresent(app);
                app.input_runtime.settings_menu.close();
                closeInlineCommandMenusIfPresent(app);
                app.input_runtime.statusline_menu.open();
                app.shell.render_requests.request(.footer);
                return;
            }
            try handleStatuslineCommand(app, rest);
        }

        fn commandHandleNotifications(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try handleNotificationsCommand(app, rest);
        }

        fn commandHandleShell(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try handleShellCommand(app, rest);
        }

        fn commandHandlePrompt(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try handlePromptCommand(app, rest);
        }

        fn commandHandleWorkspace(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime !@hasDecl(App, "workspaceAccess")) {
                try app.writeDomainNotice(.{
                    .topic = "workspace",
                    .tone = .@"error",
                    .body = "Workspace access is unavailable in this runtime.",
                }, true);
                return;
            }
            if (std.mem.trim(u8, rest, " \t").len == 0) {
                refreshWorkspaceAvailabilityForList(app) catch |err| {
                    const reason = output_contracts.workspaceErrorMessage(err) orelse "workspace refresh failed";
                    const message = try app.alloc.print("Workspace refresh rejected: {s}", .{reason});
                    defer app.alloc.free(message);
                    try app.writeDomainNotice(.{
                        .topic = "workspace",
                        .tone = .@"error",
                        .body = message,
                    }, true);
                    return;
                };
                if (comptime @hasField(App, "skills")) app.skills.closeMenu();
                if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
                closeHelpMenuIfPresent(app);
                app.input_runtime.settings_menu.close();
                closeInlineCommandMenusIfPresent(app);
                app.input_runtime.workspace_menu.open();
                app.shell.render_requests.request(.footer);
                return;
            }
            try handleWorkspaceCommand(app, rest);
        }

        fn commandShowVersion(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.writeDomainNotice(.{
                .topic = "version",
                .tone = .neutral,
                .body = App.app_version,
            }, true);
        }

        fn commandCheckUpdate(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "requestManualUpdate")) {
                return app.requestManualUpdate(agents.screenAgentOf(app));
            }
            try app.writeDomainNotice(.{
                .topic = "update",
                .tone = .neutral,
                .body = "Run spark update from your shell.",
            }, true);
        }

        fn commandUnknown(ctx: *anyopaque, _: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.writeDomainNotice(.{
                .topic = "command",
                .tone = .@"error",
                .body = "Unknown command. Try /help.",
            }, true);
        }
    };
}

test "workspace slash parser preserves paths with spaces and rejects incomplete actions" {
    try std.testing.expect((try parseWorkspaceCommand("")) == null);
    try std.testing.expect((try parseWorkspaceCommand(" list ")) == null);
    switch ((try parseWorkspaceCommand("clear")).?) {
        .clear => {},
        else => return error.TestExpectedEqual,
    }
    switch ((try parseWorkspaceCommand(" add /tmp/shared project ")).?) {
        .add => |path| try std.testing.expectEqualStrings("/tmp/shared project", path),
        else => return error.TestExpectedEqual,
    }
    switch ((try parseWorkspaceCommand("remove\t/tmp/shared project")).?) {
        .remove => |path| try std.testing.expectEqualStrings("/tmp/shared project", path),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectError(error.InvalidWorkspaceCommand, parseWorkspaceCommand("add"));
    try std.testing.expectError(error.InvalidWorkspaceCommand, parseWorkspaceCommand("remove"));
    try std.testing.expectError(error.InvalidWorkspaceCommand, parseWorkspaceCommand("unknown"));
}

fn handleRenameCommand(app: anytype, rest: []const u8) !void {
    const App = @TypeOf(app.*);
    const SessionRuntime = app_session_runtime.Runtime(App);
    const agent = agents.screenAgentOf(app);
    // A rename to the current title is still saved, so it pins the title;
    // only the notice changes.
    const previous_title: ?[]u8 = if (SessionRuntime.cachedSessionTitle(agent)) |title|
        try app.alloc.dupe(u8, title)
    else
        null;
    defer if (previous_title) |title| app.alloc.free(title);
    SessionRuntime.renameActiveSession(app, agent, rest) catch |err| {
        if (err == error.EmptyTitle) {
            // Usage lines name the command; a topic tag would repeat it.
            try app.writeDomainNotice(
                .{ .topic = "", .tone = .@"error", .body = "usage: /rename <title>" },
                true,
            );
            return;
        }
        const body: []const u8 = switch (err) {
            error.EmptyTitle => unreachable,
            error.TitleTooLong => std.fmt.comptimePrint(
                "title is too long (at most {d} bytes)",
                .{session_display_metadata.max_title_bytes},
            ),
            error.MultilineTitle => "title must be one line",
            error.InvalidTitle => "title must be printable text",
            error.NoActiveSession => "no active session to rename",
            else => {
                const notice = try app.alloc.print(
                    "renamed for this process but not saved ({s})",
                    .{@errorName(err)},
                );
                defer app.alloc.free(notice);
                try app.writeDomainNotice(
                    .{ .topic = "session", .tone = .warning, .body = notice },
                    true,
                );
                app.shell.render_requests.request(.footer);
                return;
            },
        };
        try app.writeDomainNotice(
            .{ .topic = "session", .tone = .@"error", .body = body },
            true,
        );
        return;
    };

    app.shell.render_requests.request(.footer);
    const title = SessionRuntime.cachedSessionTitle(agent) orelse "";
    const unchanged = if (previous_title) |previous| std.mem.eql(u8, previous, title) else false;
    const msg = if (unchanged)
        try app.alloc.print("already named \"{s}\"", .{title})
    else
        try app.alloc.print("renamed to \"{s}\"", .{title});
    defer app.alloc.free(msg);
    try app.writeDomainNotice(.{ .topic = "session", .tone = .neutral, .body = msg }, true);
}

const StatuslineFeedback = enum { announce, silent };

fn parseStatuslineItem(raw: []const u8) ?config_runtime.StatuslineItem {
    const trimmed = std.mem.trim(u8, raw, " \t");
    const statusline_item_info = @typeInfo(config_runtime.StatuslineItem).@"enum";
    inline for (statusline_item_info.field_names, statusline_item_info.field_values) |field_name, field_value| {
        if (std.mem.eql(u8, trimmed, field_name)) return @fromBackingInt(@intCast(field_value));
    }
    return null;
}

fn statuslineItemForSetting(setting: settings_catalog.SettingId) ?config_runtime.StatuslineItem {
    return switch (setting) {
        .statusline_context => .context,
        .statusline_session => .session,
        .statusline_workspace => .workspace,
        else => null,
    };
}

fn statuslineItemEnabled(app: anytype, item: config_runtime.StatuslineItem) bool {
    const App = @TypeOf(app.*);
    return switch (item) {
        .context => app.statusline_context,
        .session => app.statusline_session,
        .workspace => if (comptime @hasField(App, "workspace_identity"))
            app.workspace_identity.enabled
        else
            false,
    };
}

fn assignStatuslineItem(app: anytype, item: config_runtime.StatuslineItem, enabled: bool) bool {
    const App = @TypeOf(app.*);
    const current = statuslineItemEnabled(app, item);
    switch (item) {
        .context => app.statusline_context = enabled,
        .session => app.statusline_session = enabled,
        .workspace => if (comptime @hasField(App, "workspace_identity")) {
            app.workspace_identity.enabled = enabled;
        },
    }
    return current != enabled;
}

fn applyStatuslineItem(
    app: anytype,
    item: config_runtime.StatuslineItem,
    enabled: bool,
    feedback: StatuslineFeedback,
) !void {
    const runtime_changed = assignStatuslineItem(app, item, enabled);
    const patch: config_runtime.UserSettingsPatch = .{
        .statusline_item = .{ .item = item, .enabled = enabled },
    };
    switch (feedback) {
        .announce => {
            try persistUserPreferences(app, "statusline", patch, runtime_changed);
            const message = try app.alloc.print(
                "{s}: {s}",
                .{ @tagName(item), if (enabled) "on" else "off" },
            );
            defer app.alloc.free(message);
            try app.writeDomainNotice(.{ .topic = "statusline", .tone = .neutral, .body = message }, true);
        },
        .silent => try persistUserPreferencesSilently(app, "statusline", patch, runtime_changed),
    }
    app.shell.render_requests.request(.footer);
}

fn handleStatuslineCommand(app: anytype, rest: []const u8) !void {
    const item = parseStatuslineItem(rest) orelse {
        try app.writeDomainNotice(.{
            .topic = "",
            .tone = .@"error",
            .body = "usage: /statusline [context|session|workspace]",
        }, true);
        return;
    };
    try applyStatuslineItem(app, item, !statuslineItemEnabled(app, item), .announce);
}

const SoundLevel = enum {
    off,
    on,
    max,

    fn label(self: SoundLevel) []const u8 {
        return @tagName(self);
    }
};

const ParsedSoundCommand = union(enum) {
    toggle,
    set: SoundLevel,
    invalid,
};

noinline fn parseSoundCommand(rest: []const u8) ParsedSoundCommand {
    var tokens = std.mem.tokenizeAny(u8, rest, " \t");
    const first = tokens.next() orelse return .toggle;
    const level = parseSoundLevel(first) orelse return .invalid;
    if (tokens.next() != null) return .invalid;
    return .{ .set = level };
}

fn parseSoundLevel(value: []const u8) ?SoundLevel {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "on")) return .on;
    if (std.mem.eql(u8, value, "max")) return .max;
    return null;
}

fn handleNotificationsCommand(app: anytype, rest: []const u8) !void {
    const current = app.notificationPreferences();
    const level: SoundLevel = switch (parseSoundCommand(rest)) {
        // Bare /sound toggles sound on/off; max is only ever explicit.
        .toggle => if (current.turn_end) .off else .on,
        .set => |value| value,
        .invalid => {
            try app.writeDomainNotice(.{
                .topic = "",
                .tone = .@"error",
                .body = "usage: /sound [on|off|max]",
            }, true);
            return;
        },
    };

    const sound_on = level != .off;
    const max = level == .max;
    const runtime_changed = sound_on != current.turn_end or
        sound_on != current.attention_required or
        max != current.max;
    app.setNotificationPreferences(sound_on, sound_on, max);

    const patch: config_runtime.UserSettingsPatch = .{
        .notification_turn_end = sound_on,
        .notification_attention_required = sound_on,
        .notification_max = max,
    };
    var attempt = config_runtime.attemptUserPreferences(app.alloc, patch);
    defer attempt.deinit(app.alloc);
    switch (attempt) {
        .failure => |failure| try session_commands.reportUserSettingsFailure(
            app,
            "sound",
            failure.err,
            failure.cleanup,
            runtime_changed,
        ),
        // announce_commit=false drops the routine "saved" line (the state
        // notice below covers it, matching /fast) but keeps warnings.
        .outcome => |outcome| _ = try session_commands.reportUserSettingsCommit(
            app,
            "sound",
            patch,
            outcome,
            null,
            false,
        ),
    }

    try app.writeDomainNotice(.{
        .topic = "sound",
        .tone = .neutral,
        .body = level.label(),
    }, true);
}

pub fn settingsCatalogSnapshot(app: anytype) settings_catalog.Snapshot {
    const App = @TypeOf(app.*);
    var snapshot: settings_catalog.Snapshot = .{};
    if (comptime provider_runtime.supported(App)) snapshot.model = provider_runtime.model(app);
    if (comptime agents.hasAgentField(App, "effort")) snapshot.effort = agents.screenAgentOf(app).effort.displayLabel();
    if (comptime @hasField(App, "fast_mode")) snapshot.fast_mode = app.fast_mode;
    if (comptime agents.hasAgentField(App, "worker") and
        @hasField(@TypeOf(agents.screenAgentOf(app).worker), "agent_turn_settings"))
    {
        snapshot.ultrafast_mode = agents.screenAgentOf(app).worker.agent_turn_settings.ultrafast_mode;
    }
    if (comptime @hasDecl(App, "resolvedModelCapabilities") and provider_runtime.supported(App)) {
        const capabilities = app.resolvedModelCapabilities(provider_runtime.model(app));
        snapshot.reasoning_efforts = capabilities.reasoning_efforts;
        snapshot.supports_fast_mode = capabilities.supports_fast_mode;
        snapshot.supports_ultrafast_mode = capabilities.supports_ultrafast_mode;
    }
    if (comptime @hasField(App, "input_runtime")) {
        snapshot.startup_scrollback = app.input_runtime.settings_menu.startup_scrollback;
        if (comptime @hasField(@TypeOf(app.input_runtime), "slash_menu_categories")) {
            snapshot.slash_menu_categories = app.input_runtime.slash_menu_categories;
        }
    }
    if (comptime @hasField(App, "shell") and @hasField(@TypeOf(app.shell), "collapse_tool_calls")) {
        snapshot.collapse_tool_calls = app.shell.collapse_tool_calls;
    }
    if (comptime @hasField(App, "statusline_context")) snapshot.statusline_context = app.statusline_context;
    if (comptime @hasField(App, "statusline_session")) snapshot.statusline_session = app.statusline_session;
    if (comptime @hasField(App, "session_title_generation")) snapshot.session_titles = app.session_title_generation;
    if (comptime @hasField(App, "workspace_identity")) snapshot.statusline_workspace = app.workspace_identity.enabled;
    if (comptime @hasField(App, "prompt_history")) snapshot.prompt_history = app.prompt_history.enabled;
    if (comptime @hasDecl(App, "notificationPreferences")) {
        const notifications = app.notificationPreferences();
        snapshot.sound_level = settings_catalog.notificationLevel(
            notifications.turn_end,
            notifications.attention_required,
            notifications.max,
        );
    }
    return snapshot;
}

pub fn applySettingsCatalogMenuChange(app: anytype, change: settings_catalog.Change) !void {
    switch (change.setting) {
        .statusline_context, .statusline_session, .statusline_workspace => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            try applyStatuslineItem(
                app,
                statuslineItemForSetting(change.setting).?,
                enabled,
                .silent,
            );
        },
        else => try applySettingsCatalogChange(app, change),
    }
    app.shell.render_requests.request(.footer);
}

fn persistUserPreferencesSilently(
    app: anytype,
    label: []const u8,
    patch: config_runtime.UserSettingsPatch,
    runtime_changed: bool,
) !void {
    var attempt = config_runtime.attemptUserPreferences(app.alloc, patch);
    defer attempt.deinit(app.alloc);
    switch (attempt) {
        .failure => |failure| try session_commands.reportUserSettingsFailure(
            app,
            label,
            failure.err,
            failure.cleanup,
            runtime_changed,
        ),
        .outcome => {},
    }
}

pub fn applySettingsCatalogChange(app: anytype, change: settings_catalog.Change) !void {
    switch (change.setting) {
        .model => unreachable,
        .statusline_context, .statusline_session, .statusline_workspace => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            const item = statuslineItemForSetting(change.setting).?;
            if (enabled != statuslineItemEnabled(app, item)) {
                try applyStatuslineItem(app, item, enabled, .announce);
            }
        },
        .collapse_tool_calls => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            const runtime_changed = enabled != app.shell.collapse_tool_calls;
            if (runtime_changed) {
                app.shell.collapse_tool_calls = enabled;
                app.shell.markTranscriptStructureDirty();
                app.shell.render_requests.request(.transcript);
            }
            try persistUserPreferences(
                app,
                "collapse tool calls",
                .{ .collapse_tool_calls = enabled },
                runtime_changed,
            );
        },
        .slash_menu_categories => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            const runtime_changed = enabled != app.input_runtime.slash_menu_categories;
            if (runtime_changed) {
                app.input_runtime.slash_menu_categories = enabled;
                app.shell.render_requests.request(.footer);
            }
            try persistUserPreferences(
                app,
                "slash menu categories",
                .{ .slash_menu_categories = enabled },
                runtime_changed,
            );
        },
        .session_titles => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            const ChangeApp = @TypeOf(app.*);
            const current = if (comptime @hasField(ChangeApp, "session_title_generation"))
                app.session_title_generation
            else
                true;
            const runtime_changed = enabled != current;
            if (comptime @hasField(ChangeApp, "session_title_generation")) {
                if (runtime_changed) app.session_title_generation = enabled;
            }
            try persistUserPreferences(
                app,
                "session titles",
                .{ .session_titles = enabled },
                runtime_changed,
            );
        },
        .effort => {
            const effort = types.ReasoningEffort.parseDisplayLabel(change.value) orelse
                return error.InvalidSettingsCatalogValue;
            const capabilities = app.resolvedModelCapabilities(provider_runtime.model(app));
            if (!model_capabilities.reasoningEffortSupported(capabilities, effort)) {
                const message = try app.alloc.print(
                    "{s} is not available for {s}",
                    .{ effort.displayLabel(), provider_runtime.model(app) },
                );
                defer app.alloc.free(message);
                try app.writeDomainNotice(.{ .topic = "effort", .tone = .neutral, .body = message }, true);
                return;
            }
            try session_commands.Commands(@TypeOf(app.*)).selectEffortFromSettings(app, agents.screenAgentOf(app), effort);
        },
        .fast_mode => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            if (enabled != app.fast_mode) try session_commands.Commands(@TypeOf(app.*)).toggleFast(app, agents.screenAgentOf(app));
        },
        .ultrafast_mode => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            if (enabled != agents.screenAgentOf(app).worker.agent_turn_settings.ultrafast_mode) {
                try session_commands.Commands(@TypeOf(app.*)).handleUltrafast(
                    app,
                    agents.screenAgentOf(app),
                    if (enabled) "on" else "off",
                );
            }
        },
        .sound_level => try handleNotificationsCommand(app, change.value),
        .startup_scrollback => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            try session_commands.Commands(@TypeOf(app.*)).handleSettings(
                app,
                if (enabled) "startup-scrollback on" else "startup-scrollback off",
            );
            var settings = config_runtime.loadMergedSettings(app.alloc, app.workspace_root) catch return;
            defer settings.deinit(app.alloc);
            app.input_runtime.settings_menu.startup_scrollback = settings.startup_scrollback orelse true;
        },
        .prompt_history => try session_commands.Commands(@TypeOf(app.*)).handleHistory(app, change.value),
    }
}

fn parseOnOff(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "on")) return true;
    if (std.mem.eql(u8, value, "off")) return false;
    return null;
}

const SurfaceOnlyApp = struct {};

const ClearCommandFakeApp = struct {
    main_agent: struct {} = .{},
    clear_count: usize = 0,
    new_count: usize = 0,
    reset_count: usize = 0,

    fn clearSession(self: *ClearCommandFakeApp, _: anytype) !void {
        self.clear_count += 1;
    }

    fn newSession(self: *ClearCommandFakeApp) !void {
        self.new_count += 1;
    }

    fn resetSession(self: *ClearCommandFakeApp) !void {
        self.reset_count += 1;
    }
    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

const QuitCommandFakeApp = struct {
    should_exit: bool = false,
    main_agent: struct {
        session_persistence: app_session_runtime.Persistence = .{},
    } = .{},

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

const ClipboardCommandFakeApp = struct {
    const CopyOutcome = enum {
        copied,
        unavailable,
        failed,
    };

    const Session = struct {
        reply: ?[]const u8 = null,

        fn lastAssistantReply(self: *const Session) ?[]const u8 {
            return self.reply;
        }
    };

    main_agent: struct {
        session: Session = .{},
    } = .{},
    copy_outcome: CopyOutcome = .copied,
    copy_calls: usize = 0,
    copied_text: ?[]const u8 = null,
    last_topic: ?[]const u8 = null,
    last_tone: ?types.NoticeTone = null,
    last_body: ?[]const u8 = null,

    pub fn clipboard(self: *ClipboardCommandFakeApp) host.Clipboard {
        return .{
            .context = self,
            .copy_fn = copy,
        };
    }

    fn copy(raw_context: ?*anyopaque, text: []const u8) host.ClipboardError!bool {
        const self: *ClipboardCommandFakeApp = @ptrCast(@alignCast(raw_context.?));
        self.copy_calls += 1;
        self.copied_text = text;
        return switch (self.copy_outcome) {
            .copied => true,
            .unavailable => false,
            .failed => error.CopyFailed,
        };
    }

    noinline fn writeDomainNotice(
        self: *ClipboardCommandFakeApp,
        notice: types.SemanticNotice,
        _: bool,
    ) !void {
        self.last_topic = notice.topic;
        self.last_tone = notice.tone;
        self.last_body = notice.body;
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

const SkillsInstallReplayApp = struct {
    const FakeInputRuntime = struct {
        const TextReplacementState = struct {
            edit: *editor_state.State,

            fn replace(self: TextReplacementState, alloc: std.mem.Allocator, text: []const u8) !void {
                try self.edit.setText(alloc, text);
            }
        };

        edit_state: editor_state.State = .{},
        help_menu: command_specs.HelpMenu = .{},

        fn deinit(self: *FakeInputRuntime, alloc: std.mem.Allocator) void {
            self.edit_state.deinit(alloc);
        }

        fn textReplacementState(self: *FakeInputRuntime) TextReplacementState {
            return .{ .edit = &self.edit_state };
        }
    };

    main_agent: struct {} = .{},
    alloc: std.mem.Allocator,
    input_runtime: FakeInputRuntime = .{},
    skills: skill_runtime.Runtime = .{},
    shell: transcript_runtime.TranscriptRuntime = .{},
    write_count: usize = 0,
    reload_count: usize = 0,
    last_tone: ?types.NoticeTone = null,

    fn skillsCommandProvider(_: *const SkillsInstallReplayApp) skill_commands.Provider {
        return test_builtin_skills.command_provider;
    }

    fn deinit(self: *SkillsInstallReplayApp) void {
        self.input_runtime.deinit(self.alloc);
        self.shell.deinit(self.alloc);
    }

    pub fn requestSkillsRefresh(self: *SkillsInstallReplayApp) !u64 {
        self.reload_count += 1;
        self.skills.fresh_through_generation = self.reload_count;
        return self.reload_count;
    }

    pub noinline fn writeDomainNotice(self: *SkillsInstallReplayApp, notice: types.SemanticNotice, _: bool) !void {
        self.write_count += 1;
        self.last_tone = notice.tone;
        _ = try self.shell.appendSemanticNotice(self.alloc, notice);
    }
    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

const ChangeCommandFakeApp = struct {
    alloc: std.mem.Allocator,
    main_agent: struct {
        change_tracker: change_tracker_mod.ChangeTracker = .{},
    } = .{},
    transcript: std.ArrayList(u8) = .empty,

    fn deinit(self: *ChangeCommandFakeApp) void {
        self.change_tracker.deinit(std.heap.c_allocator);
        self.transcript.deinit(self.alloc);
    }

    noinline fn writeDomainNotice(
        self: *ChangeCommandFakeApp,
        notice: types.SemanticNotice,
        _: bool,
    ) !void {
        try self.transcript.appendSlice(self.alloc, notice.body);
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

fn writeTempSkillFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

test {
    _ = trace_report;
}
