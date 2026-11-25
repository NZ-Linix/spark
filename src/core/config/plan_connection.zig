//! Adds, signs in again to, and removes the subscription plan accounts of
//! the profile (`src/core/auth/plan_kind.zig`): the sign-in itself, then
//! the account's connection in settings with its current catalog.
const std = @import("std");
const plan_kind = @import("../auth/plan_kind.zig");
const chatgpt_plan = @import("../auth/chatgpt_plan.zig");
const claude_plan = @import("../auth/claude_plan.zig");
const antigravity_plan = @import("../auth/antigravity_plan.zig");
const plan_store = @import("../auth/plan_store.zig");
const oauth = @import("../auth/oauth_transport.zig");
const chatgpt_catalog = @import("chatgpt_catalog.zig");
const claude_catalog = @import("claude_catalog.zig");
const antigravity_catalog = @import("antigravity_catalog.zig");
const plan_catalog = @import("plan_catalog.zig");
const configured = @import("configured_provider.zig");
const config = @import("config_runtime.zig");
const host = @import("../hosts/host.zig");
const model_provider = @import("model_provider.zig");
const Allocator = std.mem.Allocator;

pub const Kind = plan_kind.Kind;
pub const Operation = enum { connect, reconnect, remove };

pub fn newId(alloc: Allocator, kind: Kind) ![]u8 {
    return switch (kind) {
        .chatgpt => chatgpt_plan.newId(alloc),
        else => plan_store.newId(alloc, kind),
    };
}

/// The labels the plan's saved accounts other than `except` go by.
fn labelsOf(alloc: Allocator, kind: Kind, registry: configured.Registry, except: ?[]const u8) !std.ArrayList([]const u8) {
    var labels: std.ArrayList([]const u8) = .empty;
    errdefer labels.deinit(alloc);
    for (registry.definitions) |definition| {
        if (definition.auth.plan() != kind) continue;
        if (except) |id| if (std.mem.eql(u8, id, definition.id)) continue;
        const name = definition.display_name orelse "";
        const label = definition.account_label orelse if (plan_catalog.labelOf(name).len != name.len) plan_catalog.labelOf(name) else continue;
        try labels.append(alloc, label);
    }
    return labels;
}

/// The label of a new account: `input`, which no other account of the plan
/// may use, or without one the plan's first free number. Caller owns it.
/// Names carry the label only once the plan has a second account:
/// `Claude`, then `Claude (Work)` and `Claude (Personal)`, or `Claude (1)`
/// and `Claude (2)`.
pub fn chooseLabel(alloc: Allocator, kind: Kind, registry: configured.Registry, input: []const u8) ![]u8 {
    const label = std.mem.trim(u8, input, " \t");
    if (label.len != 0 and !plan_catalog.usableLabel(label, 48)) return error.InvalidPlanLabel;
    var labels = try labelsOf(alloc, kind, registry, null);
    defer labels.deinit(alloc);
    const taken = struct {
        fn in(list: []const []const u8, candidate: []const u8) bool {
            for (list) |used| if (std.ascii.eqlIgnoreCase(used, candidate)) return true;
            return false;
        }
    }.in;
    if (label.len != 0) {
        if (taken(labels.items, label)) return error.PlanLabelTaken;
        return alloc.dupe(u8, label);
    }
    for (1..labels.items.len + 2) |n| {
        const number = try alloc.print("{d}", .{n});
        if (!taken(labels.items, number)) return number;
        alloc.free(number);
    }
    unreachable;
}

/// Whether `text` can be an account's label.
pub fn usableLabel(text: []const u8) bool {
    return plan_catalog.usableLabel(text, 48);
}

/// Gives the saved account `id` the label `input`, which no other account
/// of its plan may use, and names it and its models for it.
pub fn relabel(alloc: Allocator, kind: Kind, registry: configured.Registry, id: []const u8, input: []const u8) !void {
    if (!kind.isId(id)) return error.InvalidPlanAccount;
    const label = std.mem.trim(u8, input, " \t");
    if (!usableLabel(label)) return error.InvalidPlanLabel;
    var labels = try labelsOf(alloc, kind, registry, id);
    defer labels.deinit(alloc);
    for (labels.items) |used| if (std.ascii.eqlIgnoreCase(used, label)) return error.PlanLabelTaken;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const settings = try config.loadUserSettingsJson(a);
    const providers = if (settings) |root| root.object.get("providers") else null;
    const saved = (if (providers) |all| (if (all == .object) all.object.get(id) else null) else null) orelse return error.InvalidPlanAccount;
    const value = try plan_catalog.presented(a, kind, saved, label, countOthers(kind, providers, id) >= 1);
    var result = try config.setUserPreferences(alloc, .{ .connection = .{ .id = id, .value = value } });
    result.deinit(alloc);
}

/// The saved label of the account `id`, for signing in to it again.
/// Caller owns it.
pub fn labelOfAccount(alloc: Allocator, definition: configured.Definition) ![]u8 {
    if (definition.account_label) |label| return alloc.dupe(u8, label);
    const name = definition.display_name orelse definition.id;
    const label = plan_catalog.labelOf(name);
    return alloc.dupe(u8, if (label.len != name.len) label else "1");
}

fn signIn(alloc: Allocator, kind: Kind, transport: oauth.Provider, opener: host.UrlOpener, id: []const u8, reconnect: bool, cancel: *std.atomic.Value(bool)) ![]u8 {
    return switch (kind) {
        .chatgpt => chatgpt_plan.signIn(alloc, transport, opener, id, reconnect, cancel),
        .claude => claude_plan.signIn(alloc, transport, opener, id, reconnect, cancel),
        .antigravity => antigravity_plan.signIn(alloc, transport, opener, id, reconnect, cancel),
    };
}

/// Returns whether the plan confirmed it revoked the tokens. Claude has no
/// revocation for this client, so its local removal is the whole of it.
fn removeAccount(alloc: Allocator, kind: Kind, transport: oauth.Provider, id: []const u8) !bool {
    return switch (kind) {
        .chatgpt => chatgpt_plan.remove(alloc, transport, id),
        .claude => claude_plan.remove(alloc, id),
        .antigravity => antigravity_plan.remove(alloc, transport, id),
    };
}

/// The fields of an account's settings that the person sets in `/provider`,
/// which signing in again keeps.
pub const personal_fields = [_][]const u8{ "custom_name", "context_limit", "model_overrides" };

pub fn catalogOf(arena: Allocator, kind: Kind, display_name: []const u8, models: []const u8) !std.json.Value {
    return switch (kind) {
        .chatgpt => chatgpt_catalog.connection(arena, display_name, models),
        .claude => claude_catalog.connection(arena, display_name, models),
        .antigravity => antigravity_catalog.connection(arena, display_name, models),
    };
}

/// The plan's other saved accounts, each renamed for `labeled`. Values
/// live in `arena`.
fn relabeled(arena: Allocator, kind: Kind, providers: ?std.json.Value, except: []const u8, labeled: bool) ![]config.ConnectionPatch {
    var patches: std.ArrayList(config.ConnectionPatch) = .empty;
    const saved = providers orelse return patches.items;
    if (saved != .object) return patches.items;
    var it = saved.object.iterator();
    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        if (std.mem.eql(u8, id, except) or !kind.isId(id)) continue;
        const label = plan_catalog.savedLabel(entry.value_ptr.*) orelse "1";
        try patches.append(arena, .{ .id = id, .value = try plan_catalog.presented(arena, kind, entry.value_ptr.*, label, labeled) });
    }
    return patches.items;
}

fn countOthers(kind: Kind, providers: ?std.json.Value, except: []const u8) usize {
    const saved = providers orelse return 0;
    if (saved != .object) return 0;
    var count: usize = 0;
    for (saved.object.keys()) |id| {
        if (!std.mem.eql(u8, id, except) and kind.isId(id)) count += 1;
    }
    return count;
}

/// Signs in to (`connect`, `reconnect`) or removes the account `id` with the
/// label `label`, and names every account of the plan for how many it has.
/// Returns whether the plan confirmed a removal's revocation; true otherwise.
pub fn change(alloc: Allocator, kind: Kind, transport: oauth.Provider, opener: host.UrlOpener, operation: Operation, id: []const u8, label: []const u8, cancel: *std.atomic.Value(bool)) !bool {
    if (!kind.isId(id)) return error.InvalidPlanAccount;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    if (operation == .remove) {
        const revoked = try removeAccount(alloc, kind, transport, id);
        const settings = try config.loadUserSettingsJson(a);
        const providers = if (settings) |root| root.object.get("providers") else null;
        var result = try config.setUserPreferences(alloc, .{
            .connection = .{ .id = id, .value = null },
            .other_connections = try relabeled(a, kind, providers, id, countOthers(kind, providers, id) >= 2),
        });
        result.deinit(alloc);
        return revoked;
    }
    var bounded: oauth.Cancellable = .{ .inner = transport, .cancel_flag = cancel };
    const models = try signIn(alloc, kind, bounded.provider(), opener, id, operation == .reconnect, cancel);
    defer alloc.free(models);
    errdefer if (operation == .connect) {
        _ = removeAccount(alloc, kind, transport, id) catch false;
    };
    const settings = try config.loadUserSettingsJson(a);
    const providers = if (settings) |root| root.object.get("providers") else null;
    const labeled = countOthers(kind, providers, id) >= 1;
    const name = try plan_catalog.accountName(a, kind, label, labeled);
    var value = try catalogOf(a, kind, name, models);
    try value.object.put(a, "account_label", .{ .string = label });
    // Signing in again refreshes the catalog but keeps what the person set.
    if (providers) |saved| if (saved == .object) if (saved.object.get(id)) |previous| if (previous == .object) {
        for (personal_fields) |field| if (previous.object.get(field)) |kept| try value.object.put(a, field, kept);
    };
    var providers_map: std.json.ObjectMap = .empty;
    try providers_map.put(a, id, value);
    var definition = try configured.Registry.parse(alloc, .{ .object = providers_map });
    defer definition.deinit(alloc);
    const target = model_provider.parse(id) orelse return error.InvalidPlanAccount;
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
        .other_connections = try relabeled(a, kind, providers, id, labeled),
        .provider = if (operation == .connect and active == null) target else null,
        .model_preference = .{ .provider = target, .model = selected },
    });
    result.deinit(alloc);
    return true;
}

pub const Job = struct {
    // Use a thread-safe allocator; neither the job nor its arguments borrow app state.
    const alloc = std.heap.c_allocator;
    kind: Kind,
    id: []u8,
    label: []u8,
    operation: Operation,
    transport: oauth.Provider,
    opener: host.UrlOpener,
    thread: std.Thread = undefined,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    result: anyerror!bool = undefined,

    pub fn start(kind: Kind, transport: oauth.Provider, opener: host.UrlOpener, operation: Operation, id: []const u8, label: []const u8) !*Job {
        const job = try alloc.create(Job);
        errdefer alloc.destroy(job);
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const owned_label = try alloc.dupe(u8, label);
        errdefer alloc.free(owned_label);
        job.* = .{ .kind = kind, .id = owned_id, .label = owned_label, .operation = operation, .transport = transport, .opener = opener };
        job.thread = try std.Thread.spawn(.{}, run, .{job});
        return job;
    }

    fn run(job: *Job) void {
        job.result = change(alloc, job.kind, job.transport, job.opener, job.operation, job.id, job.label, &job.cancel);
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

/// The notice after an account was removed.
pub fn removedText(kind: Kind, revoked: bool) []const u8 {
    return switch (kind) {
        .chatgpt => if (revoked) "Disconnected from ChatGPT." else "Removed the local account. Remote revocation could not be confirmed; disconnect Spark in ChatGPT settings.",
        .claude => "Removed the Claude account from this computer.",
        .antigravity => if (revoked) "Disconnected from Google." else "Removed the local account. Google could not confirm the revocation; remove access at https://myaccount.google.com/permissions.",
    };
}

/// The notice after an account was connected.
pub fn connectedText(kind: Kind) []const u8 {
    return switch (kind) {
        .chatgpt => "Using your ChatGPT plan. Manage usage at https://chatgpt.com/settings/usage.",
        .claude => "Using your Claude subscription. Manage usage at https://claude.ai/settings/usage.",
        .antigravity => "Using your Antigravity (Google AI) subscription.",
    };
}

pub fn errorText(kind: Kind, err: anyerror) []const u8 {
    return switch (err) {
        error.Cancelled => "Sign-in cancelled.",
        error.InvalidPlanLabel, error.InvalidChatGPTLabel => "Use a label of 48 bytes or fewer.",
        error.PlanLabelTaken, error.ChatGPTLabelTaken => "That account label is already in use.",
        error.ChatGPTBrowserUnavailable, error.PlanBrowserUnavailable => "Could not open a browser on this machine.",
        error.ChatGPTSignInTimedOut, error.PlanSignInTimedOut => "Sign-in timed out. Try again.",
        error.ChatGPTAuthorizationDenied, error.ChatGPTPlanPermissionMissing, error.PlanAuthorizationDenied, error.PlanPermissionMissing => switch (kind) {
            .chatgpt => "ChatGPT plan access wasn't granted.",
            .claude => "Claude access wasn't granted.",
            .antigravity => "Google access wasn't granted.",
        },
        error.ChatGPTAccountChanged, error.PlanAccountChanged => switch (kind) {
            .chatgpt => "Sign in with the original ChatGPT account and workspace.",
            .claude => "Sign in with the original Claude account.",
            .antigravity => "Sign in with the original Google account.",
        },
        error.ChatGPTSignInRequired, error.PlanSignInRequired => switch (kind) {
            .chatgpt => "ChatGPT refused the authorization. Try signing in again.",
            .claude => "Claude refused the authorization. Try signing in again.",
            .antigravity => "Google refused the authorization. Try signing in again.",
        },
        error.ChatGPTModelsUnavailable, error.NoChatGPTModels, error.PlanModelsUnavailable, error.NoPlanModels => switch (kind) {
            .chatgpt => "ChatGPT didn't return any models for this plan.",
            .claude => "Claude didn't return any models for this account.",
            .antigravity => "Antigravity didn't return any models for this account.",
        },
        error.PlanProjectUnavailable => "Google didn't set up Antigravity for this account. Open Antigravity once with it, then try again.",
        error.InvalidChatGPTIdentity, error.InvalidPlanIdentity => "Could not verify the signed-in account.",
        else => switch (kind) {
            .chatgpt => "Could not update the ChatGPT connection.",
            .claude => "Could not update the Claude connection.",
            .antigravity => "Could not update the Antigravity connection.",
        },
    };
}

test "plan account labels are unique within the plan and numbered without one" {
    const a = std.testing.allocator;
    var registry = try configured.Registry.parse_json(a,
        \\{"claude-plan-00000000000000000000000000000001":{"auth":{"type":"claude-plan"},"protocol":"anthropic-messages","base_url":"https://api.anthropic.com/v1","display_name":"Claude","account_label":"1"},
        \\ "chatgpt-plan-00000000000000000000000000000002":{"auth":{"type":"chatgpt-plan"},"protocol":"openai-responses","base_url":"https://api.openai.com/v1","display_name":"Codex (Work)"}}
    );
    defer registry.deinit(a);
    const numbered = try chooseLabel(a, .claude, registry, "");
    defer a.free(numbered);
    try std.testing.expectEqualStrings("2", numbered);
    const first = try chooseLabel(a, .antigravity, registry, "  Work ");
    defer a.free(first);
    try std.testing.expectEqualStrings("Work", first);
    try std.testing.expectError(error.PlanLabelTaken, chooseLabel(a, .claude, registry, "1"));
    // A Codex account saved before labels had a field keeps its name's.
    try std.testing.expectError(error.PlanLabelTaken, chooseLabel(a, .chatgpt, registry, "work"));
    const old = try labelOfAccount(a, registry.get("chatgpt-plan-00000000000000000000000000000002").?.*);
    defer a.free(old);
    try std.testing.expectEqualStrings("Work", old);
    try std.testing.expectEqualStrings("Sign-in cancelled.", errorText(.claude, error.Cancelled));
}
