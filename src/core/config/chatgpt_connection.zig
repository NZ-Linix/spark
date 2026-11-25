const std = @import("std");
const plan = @import("../auth/chatgpt_plan.zig");
const oauth = @import("../auth/oauth_transport.zig");
const catalog = @import("chatgpt_catalog.zig");
const configured = @import("configured_provider.zig");
const config = @import("config_runtime.zig");
const host = @import("../hosts/host.zig");
const model_provider = @import("model_provider.zig");
const Allocator = std.mem.Allocator;

pub const Operation = enum { connect, reconnect, remove };

pub fn displayName(alloc: Allocator, registry: configured.Registry, input: []const u8) ![]u8 {
    const label = std.mem.trim(u8, input, " \t");
    if (label.len != 0 and !catalog.usableLabel(label, 48)) return error.InvalidChatGPTLabel;
    const numbers = if (label.len == 0) registry.definitions.len + 1 else 1;
    for (1..numbers + 1) |n| {
        const name = if (label.len == 0) try alloc.print("Codex ({d})", .{n}) else try alloc.print("Codex ({s})", .{label});
        const used = for (registry.definitions) |definition| {
            if (std.ascii.eqlIgnoreCase(definition.display_name orelse "", name)) break true;
        } else false;
        if (!used) return name;
        alloc.free(name);
    }
    return error.ChatGPTLabelTaken;
}

pub fn change(alloc: Allocator, transport: oauth.Provider, opener: host.UrlOpener, operation: Operation, id: []const u8, label: []const u8, cancel: *std.atomic.Value(bool)) !bool {
    if (!plan.isId(id)) return error.InvalidChatGPTAccount;
    if (operation == .remove) {
        const revoked = try plan.remove(alloc, transport, id);
        var result = try config.setUserPreferences(alloc, .{ .connection = .{ .id = id, .value = null } });
        result.deinit(alloc);
        return revoked;
    }
    var bounded: oauth.Cancellable = .{ .inner = transport, .cancel_flag = cancel };
    const models = try plan.signIn(alloc, bounded.provider(), opener, id, operation == .reconnect, cancel);
    defer alloc.free(models);
    errdefer if (operation == .connect) {
        _ = plan.remove(alloc, transport, id) catch false;
    };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try catalog.connection(a, label, models);
    var providers: std.json.ObjectMap = .empty;
    try providers.put(a, id, value);
    var definition = try configured.Registry.parse(alloc, .{ .object = providers });
    defer definition.deinit(alloc);
    const target = model_provider.parse(id) orelse return error.InvalidChatGPTAccount;
    const settings = try config.loadUserSettingsJson(a);
    const active = if (settings) |root| root.object.get("provider") else null;
    const prior_model = if (settings) |root| blk: {
        const models_by_provider = root.object.get("models") orelse break :blk null;
        if (models_by_provider != .object) break :blk null;
        const model = models_by_provider.object.get(id) orelse break :blk null;
        break :blk if (model == .string) model.string else null;
    } else null;
    const info = definition.definitions[0];
    const selected = if (prior_model) |previous| if (info.model(previous) != null) previous else info.model_metadata[0].id else info.model_metadata[0].id;
    var result = try config.setUserPreferences(alloc, .{
        .connection = .{ .id = id, .value = value },
        .provider = if (operation == .connect and active == null) target else null,
        .model_preference = .{ .provider = target, .model = selected },
    });
    result.deinit(alloc);
    return true;
}

pub const Job = struct {
    // Use a thread-safe allocator; neither the job nor its arguments borrow app state.
    const alloc = std.heap.c_allocator;
    id: []u8,
    label: []u8,
    operation: Operation,
    transport: oauth.Provider,
    opener: host.UrlOpener,
    thread: std.Thread = undefined,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    result: anyerror!bool = undefined,

    pub fn start(transport: oauth.Provider, opener: host.UrlOpener, operation: Operation, id: []const u8, label: []const u8) !*Job {
        const job = try alloc.create(Job);
        errdefer alloc.destroy(job);
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const owned_label = try alloc.dupe(u8, label);
        errdefer alloc.free(owned_label);
        job.* = .{ .id = owned_id, .label = owned_label, .operation = operation, .transport = transport, .opener = opener };
        job.thread = try std.Thread.spawn(.{}, run, .{job});
        return job;
    }

    fn run(job: *Job) void {
        job.result = change(alloc, job.transport, job.opener, job.operation, job.id, job.label, &job.cancel);
        job.done.store(true, .release);
    }

    pub fn close(job: *Job) void {
        job.cancel.store(true, .release);
        job.thread.join();
        alloc.free(job.label);
        alloc.free(job.id);
        alloc.destroy(job);
    }
};

pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.Cancelled => "Sign-in cancelled.",
        error.InvalidChatGPTLabel => "Use a label of 48 bytes or fewer.",
        error.ChatGPTLabelTaken => "That account label is already in use.",
        error.ChatGPTBrowserUnavailable => "Could not open a browser on this machine.",
        error.ChatGPTAuthorizationDenied, error.ChatGPTPlanPermissionMissing => "ChatGPT plan access wasn't granted.",
        error.ChatGPTSignInTimedOut => "Sign-in timed out. Try again.",
        error.ChatGPTAccountChanged => "Sign in with the original ChatGPT account and workspace.",
        error.ChatGPTSignInRequired => "ChatGPT refused the authorization. Try signing in again.",
        error.ChatGPTModelsUnavailable, error.NoChatGPTModels => "ChatGPT didn't return any models for this plan.",
        error.InvalidChatGPTIdentity => "Could not verify the signed-in ChatGPT account.",
        else => "Could not update the ChatGPT connection.",
    };
}
