const std = @import("std");
const command_specs = @import("command_specs.zig");

const SlashKind = command_specs.SlashKind;
const SlashRegistry = command_specs.SlashRegistry;

pub const ParsedCommand = union(enum) {
    quit,
    clear_screen,
    new_session,
    launch_instance: []const u8,
    close_instance,
    show_agents,
    reset_session,
    resume_session,
    rename_session: []const u8,
    fork_session,
    help,
    provider,
    status,
    image: []const u8,
    images: []const u8,
    model: []const u8,
    effort: []const u8,
    stats,
    undo,
    mcp: []const u8,
    skills: []const u8,
    copy,
    feedback,
    trace,
    compact,
    settings: []const u8,
    paste,
    fast: []const u8,
    ultrafast: []const u8,
    statusline: []const u8,
    notifications: []const u8,
    workspace: []const u8,
    shell: []const u8,
    prompt: []const u8,
    version,
    update,
    unknown,
};

pub const CommandHandlers = struct {
    ctx: *anyopaque,
    quit: *const fn (ctx: *anyopaque) anyerror!void,
    clear_screen: *const fn (ctx: *anyopaque) anyerror!void,
    new_session: *const fn (ctx: *anyopaque) anyerror!void,
    launch_instance: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    close_instance: *const fn (ctx: *anyopaque) anyerror!void,
    show_agents: *const fn (ctx: *anyopaque) anyerror!void,
    reset_session: *const fn (ctx: *anyopaque) anyerror!void,
    resume_session: *const fn (ctx: *anyopaque) anyerror!void,
    fork_session: *const fn (ctx: *anyopaque) anyerror!void,
    show_help: *const fn (ctx: *anyopaque) anyerror!void,
    /// `/provider`: the form that adds, edits, or removes an OpenAI-compatible endpoint.
    provider: *const fn (ctx: *anyopaque) anyerror!void,
    show_status: *const fn (ctx: *anyopaque) anyerror!void,
    attach_image: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
    manage_images: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_model: *const fn (ctx: *anyopaque, query: []const u8) anyerror!void,
    handle_effort: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    show_stats: *const fn (ctx: *anyopaque) anyerror!void,
    undo_last: *const fn (ctx: *anyopaque) anyerror!void,
    handle_mcp: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_skills: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    copy_last: *const fn (ctx: *anyopaque) anyerror!void,
    submit_feedback: *const fn (ctx: *anyopaque) anyerror!void,
    create_trace: *const fn (ctx: *anyopaque) anyerror!void,
    compact_history: *const fn (ctx: *anyopaque) anyerror!void,
    handle_settings: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    paste_clipboard: *const fn (ctx: *anyopaque) anyerror!void,
    handle_fast: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_ultrafast: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_statusline: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    rename_session: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_notifications: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_workspace: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_shell: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_prompt: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    show_version: *const fn (ctx: *anyopaque) anyerror!void,
    check_update: *const fn (ctx: *anyopaque) anyerror!void,
    unknown: *const fn (ctx: *anyopaque, cmd: []const u8) anyerror!void,
};

fn command_payload(cmd: []const u8, prefix: []const u8) []const u8 {
    return std.mem.trim(u8, cmd[prefix.len..], " \t");
}

fn parsedCommand(kind: SlashKind, payload: []const u8) ParsedCommand {
    return switch (kind) {
        .quit => .quit,
        .new_session => .new_session,
        .resume_session => .resume_session,
        .rename_session => .{ .rename_session = payload },
        .fork_session => .fork_session,
        .help => .help,
        .provider => .provider,
        .status => .status,
        .images => .{ .images = payload },
        .image => .{ .image = payload },
        .model => .{ .model = payload },
        .effort => .{ .effort = payload },
        .mcp => .{ .mcp = payload },
        .skills => .{ .skills = payload },
        .copy => .copy,
        .compact => .compact,
        .settings => .{ .settings = payload },
        .paste => .paste,
        .fast => .{ .fast = payload },
        .ultrafast => .{ .ultrafast = payload },
        .prompt => .{ .prompt = payload },
        .version => .version,
        .update => .update,
    };
}

pub fn parse(registry: SlashRegistry, cmd: []const u8) ParsedCommand {
    for (registry.commands) |spec| {
        if (spec.accepts_payload) {
            if (command_specs.matchedSlashPrefix(registry, cmd, spec.kind)) |prefix| {
                return parsedCommand(spec.kind, command_payload(cmd, prefix));
            }
        } else if (command_specs.matchesSlashExact(registry, cmd, spec.kind)) {
            return parsedCommand(spec.kind, "");
        }
    }
    return .unknown;
}

pub fn route(registry: SlashRegistry, handlers: *const CommandHandlers, cmd: []const u8) !void {
    switch (parse(registry, cmd)) {
        .quit => try handlers.quit(handlers.ctx),
        .clear_screen => try handlers.clear_screen(handlers.ctx),
        .new_session => try handlers.new_session(handlers.ctx),
        .launch_instance => |rest| try handlers.launch_instance(handlers.ctx, rest),
        .close_instance => try handlers.close_instance(handlers.ctx),
        .show_agents => try handlers.show_agents(handlers.ctx),
        .reset_session => try handlers.reset_session(handlers.ctx),
        .resume_session => try handlers.resume_session(handlers.ctx),
        .rename_session => |rest| try handlers.rename_session(handlers.ctx, rest),
        .fork_session => try handlers.fork_session(handlers.ctx),
        .help => try handlers.show_help(handlers.ctx),
        .provider => try handlers.provider(handlers.ctx),
        .status => try handlers.show_status(handlers.ctx),
        .image => |path| try handlers.attach_image(handlers.ctx, path),
        .images => |rest| try handlers.manage_images(handlers.ctx, rest),
        .model => |query| try handlers.handle_model(handlers.ctx, query),
        .effort => |rest| try handlers.handle_effort(handlers.ctx, rest),
        .stats => try handlers.show_stats(handlers.ctx),
        .undo => try handlers.undo_last(handlers.ctx),
        .mcp => |rest| try handlers.handle_mcp(handlers.ctx, rest),
        .skills => |rest| try handlers.handle_skills(handlers.ctx, rest),
        .copy => try handlers.copy_last(handlers.ctx),
        .feedback => try handlers.submit_feedback(handlers.ctx),
        .trace => try handlers.create_trace(handlers.ctx),
        .compact => try handlers.compact_history(handlers.ctx),
        .settings => |rest| try handlers.handle_settings(handlers.ctx, rest),
        .paste => try handlers.paste_clipboard(handlers.ctx),
        .fast => |rest| try handlers.handle_fast(handlers.ctx, rest),
        .ultrafast => |rest| try handlers.handle_ultrafast(handlers.ctx, rest),
        .statusline => |rest| try handlers.handle_statusline(handlers.ctx, rest),
        .notifications => |rest| try handlers.handle_notifications(handlers.ctx, rest),
        .workspace => |rest| try handlers.handle_workspace(handlers.ctx, rest),
        .shell => |rest| try handlers.handle_shell(handlers.ctx, rest),
        .prompt => |rest| try handlers.handle_prompt(handlers.ctx, rest),
        .version => try handlers.show_version(handlers.ctx),
        .update => try handlers.check_update(handlers.ctx),
        .unknown => try handlers.unknown(handlers.ctx, cmd),
    }
}

fn testSlashRegistry() SlashRegistry {
    const builtin_commands = @import("../../builtins/commands.zig");
    return builtin_commands.slash_registry;
}

test "parse extracts model command payload" {
    const parsed = parse(testSlashRegistry(), "/model claude-opus");
    switch (parsed) {
        .model => |query| try std.testing.expectEqualStrings("claude-opus", query),
        else => return error.TestExpectedEqual,
    }
}

fn parsedIsUnknown(parsed: ParsedCommand) bool {
    return switch (parsed) {
        .unknown => true,
        else => false,
    };
}

const TestContext = struct {
    called: []const u8 = "",
    payload: []const u8 = "",
};

fn testContext(ctx: *anyopaque) *TestContext {
    return @ptrCast(@alignCast(ctx));
}

fn unexpectedNoPayload(ctx: *anyopaque) anyerror!void {
    _ = ctx;
    return error.UnexpectedCallback;
}

fn unexpectedPayload(ctx: *anyopaque, value: []const u8) anyerror!void {
    _ = ctx;
    _ = value;
    return error.UnexpectedCallback;
}

fn recordShell(ctx: *anyopaque, value: []const u8) anyerror!void {
    testContext(ctx).called = "shell";
    testContext(ctx).payload = value;
}

fn recordCopy(ctx: *anyopaque) anyerror!void {
    testContext(ctx).called = "copy";
}

fn recordResumeSession(ctx: *anyopaque) anyerror!void {
    testContext(ctx).called = "resume";
}

fn recordForkSession(ctx: *anyopaque) anyerror!void {
    testContext(ctx).called = "fork";
}

fn recordModel(ctx: *anyopaque, value: []const u8) anyerror!void {
    const test_context = testContext(ctx);
    test_context.called = "model";
    test_context.payload = value;
}

fn recordSettings(ctx: *anyopaque, value: []const u8) anyerror!void {
    const test_context = testContext(ctx);
    test_context.called = "settings";
    test_context.payload = value;
}

fn recordNotifications(ctx: *anyopaque, value: []const u8) anyerror!void {
    const test_context = testContext(ctx);
    test_context.called = "notifications";
    test_context.payload = value;
}

fn recordUnknown(ctx: *anyopaque, value: []const u8) anyerror!void {
    const test_context = testContext(ctx);
    test_context.called = "unknown";
    test_context.payload = value;
}

fn failStatus(ctx: *anyopaque) anyerror!void {
    _ = ctx;
    return error.TestRouteFailure;
}

fn testHandlers(ctx: *TestContext) CommandHandlers {
    return .{
        .ctx = ctx,
        .quit = unexpectedNoPayload,
        .clear_screen = unexpectedNoPayload,
        .new_session = unexpectedNoPayload,
        .launch_instance = unexpectedPayload,
        .close_instance = unexpectedNoPayload,
        .show_agents = unexpectedNoPayload,
        .reset_session = unexpectedNoPayload,
        .resume_session = unexpectedNoPayload,
        .fork_session = unexpectedNoPayload,
        .show_help = unexpectedNoPayload,
        .provider = unexpectedNoPayload,
        .show_status = unexpectedNoPayload,
        .attach_image = unexpectedPayload,
        .manage_images = unexpectedPayload,
        .handle_model = unexpectedPayload,
        .handle_effort = unexpectedPayload,
        .show_stats = unexpectedNoPayload,
        .undo_last = unexpectedNoPayload,
        .handle_mcp = unexpectedPayload,
        .handle_skills = unexpectedPayload,
        .copy_last = unexpectedNoPayload,
        .submit_feedback = unexpectedNoPayload,
        .create_trace = unexpectedNoPayload,
        .compact_history = unexpectedNoPayload,
        .handle_settings = unexpectedPayload,
        .paste_clipboard = unexpectedNoPayload,
        .handle_fast = unexpectedPayload,
        .handle_ultrafast = unexpectedPayload,
        .handle_statusline = unexpectedPayload,
        .rename_session = unexpectedPayload,
        .handle_notifications = unexpectedPayload,
        .handle_workspace = unexpectedPayload,
        .handle_shell = unexpectedPayload,
        .handle_prompt = unexpectedPayload,
        .show_version = unexpectedNoPayload,
        .check_update = unexpectedNoPayload,
        .unknown = unexpectedPayload,
    };
}
