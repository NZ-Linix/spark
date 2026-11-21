const std = @import("std");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const permissions = @import("../permissions/permissions.zig");
const session_store = @import("../session/session_store.zig");
const types = @import("../shared/types.zig");
const profiles = @import("../profiles/profiles.zig");
const started_with_mod = @import("../profiles/started_with.zig");
const tool_placement = @import("../config/tool_placement.zig");
const toolbox = @import("../tooling/toolbox.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");

const Allocator = std.mem.Allocator;

pub const PermissionAdmissionError = error{PermissionEscalation};

fn permissionRank(mode: types.PermissionMode) u2 {
    return switch (mode) {
        .ask => 0,
        .auto => 1,
        .yolo => 2,
    };
}

pub fn admitChildPermission(
    parent: types.PermissionMode,
    requested: ?types.PermissionMode,
) PermissionAdmissionError!types.PermissionMode {
    const child = requested orelse parent;
    if (permissionRank(child) > permissionRank(parent)) {
        return error.PermissionEscalation;
    }
    return child;
}

pub const Error = error{
    OutOfMemory,
    ChildNotAttached,
    InvalidControlRecord,
    StoreUnavailable,
    HostAuthorityUnavailable,
};

pub const HostAuthority = struct {
    generation: u64,
    tools: [][]u8,
    integrations: [][]u8,
    mcp_view: ?mcp_access.View = null,

    pub fn capture(
        alloc: Allocator,
        tools: []const []const u8,
        integrations: []const []const u8,
    ) !HostAuthority {
        return captureWithMcpView(
            alloc,
            tools,
            integrations,
            null,
        );
    }

    pub fn captureWithMcpView(
        alloc: Allocator,
        tools: []const []const u8,
        integrations: []const []const u8,
        mcp_view: ?*const mcp_access.View,
    ) !HostAuthority {
        const owned_tools = try cloneStrings(alloc, tools);
        errdefer freeStrings(alloc, owned_tools);
        const owned_integrations = try cloneStrings(alloc, integrations);
        errdefer freeStrings(alloc, owned_integrations);
        var owned_mcp_view = if (mcp_view) |view| try view.clone(alloc) else null;
        errdefer if (owned_mcp_view) |*view| view.deinit(alloc);
        return .{
            .generation = hostGeneration(
                tools,
                integrations,
                mcp_view,
            ),
            .tools = owned_tools,
            .integrations = owned_integrations,
            .mcp_view = owned_mcp_view,
        };
    }

    pub fn deinit(self: *HostAuthority, alloc: Allocator) void {
        freeStrings(alloc, self.tools);
        freeStrings(alloc, self.integrations);
        if (self.mcp_view) |*mcp_view| mcp_view.deinit(alloc);
        self.* = undefined;
    }
};

pub const HostResolver = struct {
    context: ?*anyopaque = null,
    resolve_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
    ) HostResolveError!HostAuthority,
    /// The permission mode the user chose on a child's own screen, if any.
    /// It wins over the child's profile and the work's mode, as main's
    /// choice wins over its launch profile.
    child_permission_mode_fn: ?*const fn (?*anyopaque, []const u8) ?types.PermissionMode = null,
    /// The permission mode agent `parent_id` works in now: an instance's
    /// own, or a subagent's as the host that started it resolves it. A
    /// child with no mode of its own or from its profile follows it on each
    /// tool call. Without it, or when it returns null, a child keeps the mode
    /// its work was sent under.
    parent_permission_mode_fn: ?*const fn (?*anyopaque, Allocator, []const u8) ?types.PermissionMode = null,
    /// spark's own tools, MCP integrations, and MCP view for root `root_id`,
    /// before any profile: what a profile that sets tools or MCP servers
    /// chooses from, even past its parent's. Without it, such a profile
    /// narrows its parent's instead.
    base_fn: ?*const fn (?*anyopaque, Allocator, []const u8) HostResolveError!HostAuthority = null,

    fn resolveBase(self: HostResolver, alloc: Allocator, root_id: []const u8) Error!?HostAuthority {
        const base_fn = self.base_fn orelse return null;
        return try base_fn(self.context, alloc, root_id);
    }

    fn childPermissionMode(self: HostResolver, child_id: []const u8) ?types.PermissionMode {
        const mode_fn = self.child_permission_mode_fn orelse return null;
        return mode_fn(self.context, child_id);
    }

    fn parentPermissionMode(self: HostResolver, alloc: Allocator, parent_id: []const u8) ?types.PermissionMode {
        const mode_fn = self.parent_permission_mode_fn orelse return null;
        return mode_fn(self.context, alloc, parent_id);
    }

    fn resolve(
        self: HostResolver,
        alloc: Allocator,
        root_id: []const u8,
    ) Error!HostAuthority {
        return self.resolve_fn(self.context, alloc, root_id);
    }
};

pub const HostResolveError = error{
    OutOfMemory,
    HostAuthorityUnavailable,
};

pub const LiveAuthority = struct {
    generation: u64,
    root_id: []const u8,
    tools: []const []const u8,
    integrations: []const []const u8,
    permission_mode: types.PermissionMode,
};

pub const Snapshot = struct {
    child_id: []u8,
    root_id: []u8,
    generation: u64,
    tools: [][]u8,
    integrations: [][]u8,
    permission_mode: types.PermissionMode,
    mcp_view: ?mcp_access.View = null,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.child_id);
        alloc.free(self.root_id);
        freeStrings(alloc, self.tools);
        freeStrings(alloc, self.integrations);
        if (self.mcp_view) |*mcp_view| mcp_view.deinit(alloc);
        self.* = undefined;
    }

    pub fn view(self: *const Snapshot) LiveAuthority {
        return .{
            .generation = self.generation,
            .root_id = self.root_id,
            .tools = self.tools,
            .integrations = self.integrations,
            .permission_mode = self.permission_mode,
        };
    }
};

/// The profile each child started in, kept for the life of the process, so a
/// running child keeps it whatever is saved later. A child saved with what its
/// profile set (`started_with`) takes that, whatever the profile files say now;
/// only the profile's prompt is read again, by name. A child saved with only a
/// name loads it the first time its authority is resolved, from the spark home
/// and the session's workspace root, as `spark --profile` does in the directory
/// it runs in.
pub const ProfileCache = struct {
    /// Where profiles load from: the spark home, and the workspace root of the
    /// session whose children these are, which the child registry holds
    /// (`child_state.V2Children.workspace`). Both borrowed.
    pub const LoadRoots = struct { home: ?[]const u8, workspace_root: ?[]const u8 };

    alloc: Allocator,
    roots: LoadRoots,
    mutex: std.Io.Mutex = .init,
    /// Keyed by child id, owned. Entries live until `deinit`.
    entries: std.array_hash_map.String(*profiles.Held) = .empty,
    /// Why the profile of a child could not be loaded the last time it was
    /// tried, keyed by child id, owned. A later load that works removes it.
    failures: std.array_hash_map.String([]u8) = .empty,

    /// The profile `child_id` runs in, taking `saved` or else loading `name`
    /// the first time. A profile that cannot be loaded fails closed: the child
    /// gets no authority at all rather than more than its profile gives.
    pub fn get(self: *ProfileCache, child_id: []const u8, name: []const u8, saved: ?started_with_mod.StartedWith) Error!*const profiles.Profile {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.entries.get(child_id)) |held| return &held.profile;
        const held = try self.alloc.create(profiles.Held);
        errdefer self.alloc.destroy(held);
        held.* = .{};
        if (saved) |facts| {
            try self.restore(held, child_id, self.roots.home, self.roots.workspace_root, name, facts);
        } else {
            var failure: ?[]u8 = null;
            defer if (failure) |message| self.alloc.free(message);
            held.replace(self.alloc, self.roots.home, self.roots.workspace_root, name, "", &failure) catch |err| {
                const reason = failure orelse @errorName(err);
                debug_trace.eventf("profile", "profile_failed", .{}, "child={s} name={s} reason={s}", .{ child_id, name, reason });
                if (err == error.OutOfMemory) return error.OutOfMemory;
                self.noteFailure(child_id, reason);
                return error.HostAuthorityUnavailable;
            };
            debug_trace.eventf("profile", "profile_reloaded", .{}, "child={s} name={s} source={s} reason=no_saved_copy", .{ child_id, name, @tagName(held.profile.source) });
            self.clearFailure(child_id);
        }
        errdefer held.deinit();
        const key = try self.alloc.dupe(u8, child_id);
        errdefer self.alloc.free(key);
        try self.entries.put(self.alloc, key, held);
        return &held.profile;
    }

    /// Builds into `held` the profile `saved` describes for `name`. Its prompt
    /// is not saved: it is read again by name from the folder of the saved
    /// source alone, the spark home for a profile of the user's own and the
    /// session's workspace root for a repository's, so a profile of the same
    /// name in the other can neither take the prompt away nor supply its own.
    /// Without the file there, or for a built-in profile, the child has no
    /// profile prompt.
    fn restore(
        self: *ProfileCache,
        held: *profiles.Held,
        child_id: []const u8,
        home: ?[]const u8,
        workspace_root: ?[]const u8,
        name: []const u8,
        saved: started_with_mod.StartedWith,
    ) Allocator.Error!void {
        var next = std.heap.ArenaAllocator.init(self.alloc);
        errdefer next.deinit();
        const arena = next.allocator();
        const facts = try started_with_mod.dupe(arena, saved);
        var profile = started_with_mod.toProfile(facts, try arena.dupe(u8, name));
        var prompt: []const u8 = "none";
        if (saved.source != .builtin) {
            const roots = try profiles.Roots.init(
                arena,
                if (saved.source == .home) home else null,
                if (saved.source == .project) workspace_root else null,
            );
            var failure: ?[]const u8 = null;
            if (profiles.load(arena, roots, name, &failure)) |loaded| {
                // With one folder to look in, only a built-in of the same name can answer instead.
                if (loaded.source == saved.source) {
                    profile.prompt = loaded.prompt;
                    profile.prompt_mode = loaded.prompt_mode;
                    prompt = "read";
                } else prompt = "not_in_source";
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => prompt = "not_loaded",
            }
        }
        held.* = .{ .arena = next, .profile = profile };
        self.clearFailure(child_id);
        debug_trace.eventf("profile", "profile_restored", .{}, "child={s} name={s} source={s} prompt={s}", .{ child_id, name, @tagName(saved.source), prompt });
    }

    /// Under the mutex.
    fn noteFailure(self: *ProfileCache, child_id: []const u8, message: []const u8) void {
        const text = self.alloc.dupe(u8, message) catch return self.failureNoteDropped(child_id);
        if (self.failures.getPtr(child_id)) |known| {
            self.alloc.free(known.*);
            known.* = text;
            return;
        }
        const key = self.alloc.dupe(u8, child_id) catch {
            self.alloc.free(text);
            return self.failureNoteDropped(child_id);
        };
        self.failures.put(self.alloc, key, text) catch {
            self.alloc.free(key);
            self.alloc.free(text);
            self.failureNoteDropped(child_id);
        };
    }

    /// The parent then sees the failure without the profile's name.
    fn failureNoteDropped(_: *ProfileCache, child_id: []const u8) void {
        debug_trace.logf("profile", "profile failure note dropped child={s} reason=out_of_memory", .{child_id});
    }

    /// Under the mutex.
    fn clearFailure(self: *ProfileCache, child_id: []const u8) void {
        const removed = self.failures.fetchSwapRemove(child_id) orelse return;
        self.alloc.free(removed.key);
        self.alloc.free(removed.value);
    }

    /// Why the profile of `child_id` could not be loaded, if the last try
    /// failed, in `alloc`, which names the profile.
    pub fn failureOf(self: *ProfileCache, alloc: Allocator, child_id: []const u8) Allocator.Error!?[]u8 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const message = self.failures.get(child_id) orelse return null;
        return try alloc.dupe(u8, message);
    }

    /// The profile `child_id` was given, if its authority was resolved.
    pub fn find(self: *ProfileCache, child_id: []const u8) ?*const profiles.Profile {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const held = self.entries.get(child_id) orelse return null;
        return &held.profile;
    }

    pub fn deinit(self: *ProfileCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.entries.deinit(self.alloc);
        var failed = self.failures.iterator();
        while (failed.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.failures.deinit(self.alloc);
        self.* = undefined;
    }
};

pub const Resolver = struct {
    children: *child_state.V2Children,
    root_id: []const u8 = "",
    host: HostResolver,

    /// Where a child's stored profile is loaded. A child with a profile and
    /// no cache gets no authority.
    profiles: ?*ProfileCache = null,

    /// Whether these children may start subagents of their own. spark nests
    /// two levels, an agent's subagents and theirs, so a subagent's own
    /// host clears it and its children are never given `subagent`.
    children_nest: bool = true,

    /// The host's tools behind toolbox, read when a child's tools are
    /// decided, so a profile that lists one keeps toolbox to reach it.
    /// Unset, they are toolbox's defaults.
    toolbox_behind: ?*const tool_placement.Behind = null,

    /// The authority of the work main started on child `child_id`, which
    /// must still be active.
    pub fn resolve(
        self: *Resolver,
        alloc: Allocator,
        child_id: []const u8,
    ) Error!Snapshot {
        return self.resolveWith(alloc, child_id, .work);
    }

    /// The authority of a turn on child `child_id` that no work of main's
    /// started, such as one the user typed on its screen: the same as
    /// a run's, with `permission_mode` in place of the work's where the host
    /// can't say the parent's current mode. The child's profile still
    /// narrows its tools, and its own mode still wins.
    pub fn resolveForUser(
        self: *Resolver,
        alloc: Allocator,
        child_id: []const u8,
        permission_mode: types.PermissionMode,
    ) Error!Snapshot {
        return self.resolveWith(alloc, child_id, .{ .user = permission_mode });
    }

    const Basis = union(enum) { work, user: types.PermissionMode };

    /// The permission mode child `child_id` works in now, whatever its work
    /// was sent under: the mode chosen on its own screen, else its
    /// profile's, else the one its parent works in now. Its tool calls are
    /// decided in this mode, and the host that started it asks here for
    /// the mode its own subagents follow. Reads the registry without the
    /// store lock, so the main loop can call it while a save runs.
    pub fn currentMode(self: *Resolver, alloc: Allocator, child_id: []const u8) Error!types.PermissionMode {
        domain.validateId(child_id) catch return error.ChildNotAttached;
        domain.validateId(self.root_id) catch return error.ChildNotAttached;
        const parent_mode = self.host.parentPermissionMode(alloc, self.root_id);
        const store = child_state.Store{ .children = self.children, .parent_id = self.root_id };
        var registry = store.load(alloc) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.StoreUnavailable,
        };
        defer registry.deinit(alloc);
        const child = registry.findById(child_id) orelse return error.ChildNotAttached;
        // Without its parent's mode it keeps the one its work was sent
        // under, or full access with no work.
        const sent: types.PermissionMode = if (child.active) |work| work.permission_mode else .yolo;
        return self.modeFor(child_id, try self.profileOf(child_id, child.*), parent_mode orelse sent);
    }

    /// The profile child `child` runs in, from what it saved or else loaded by
    /// its name the first time. A child with a profile and no cache gets no
    /// authority.
    fn profileOf(self: *Resolver, child_id: []const u8, child: child_state.Child) Error!?*const profiles.Profile {
        const name = child.profile orelse return null;
        const cache = self.profiles orelse return error.HostAuthorityUnavailable;
        return try cache.get(child_id, name, child.started_with);
    }

    /// Why the profile of child `child_id` could not be loaded the last time
    /// its authority was resolved, in `alloc`, or null when it could, or the
    /// child has none. The message names the profile.
    pub fn profileFailure(self: *Resolver, alloc: Allocator, child_id: []const u8) Allocator.Error!?[]u8 {
        const cache = self.profiles orelse return null;
        return cache.failureOf(alloc, child_id);
    }

    /// Child `child_id`'s mode, given the one it would otherwise follow:
    /// the mode chosen on its own screen, else its profile's, which wins
    /// even when looser than `inherited`, else `inherited`.
    fn modeFor(
        self: *Resolver,
        child_id: []const u8,
        profile: ?*const profiles.Profile,
        inherited: types.PermissionMode,
    ) types.PermissionMode {
        if (self.host.childPermissionMode(child_id)) |own| return own;
        return if (profile) |value| profiles.permissionMode(value, inherited) else inherited;
    }

    fn resolveWith(
        self: *Resolver,
        alloc: Allocator,
        child_id: []const u8,
        basis: Basis,
    ) Error!Snapshot {
        domain.validateId(child_id) catch return error.ChildNotAttached;
        domain.validateId(self.root_id) catch return error.ChildNotAttached;
        const store = child_state.Store{ .children = self.children, .parent_id = self.root_id };
        const work_generation = blk: {
            var lock = store.acquireLock();
            defer lock.release();
            var registry = store.load(alloc) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.StoreUnavailable,
            };
            defer registry.deinit(alloc);
            const child = registry.findById(child_id) orelse return error.ChildNotAttached;
            if (basis == .work and child.active == null) return error.ChildNotAttached;
            break :blk child.work_generation;
        };

        // Host resolution may connect MCP servers; parent state observation must remain available.
        var host = try self.host.resolve(alloc, self.root_id);
        defer host.deinit(alloc);
        // The parent's current mode, resolved outside the store lock: the
        // host's hook takes the authority lock, and a subagent parent's
        // reads its own parent's registry.
        const parent_mode = self.host.parentPermissionMode(alloc, self.root_id);

        const current = blk: {
            var lock = store.acquireLock();
            defer lock.release();
            var registry = store.load(alloc) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.StoreUnavailable,
            };
            defer registry.deinit(alloc);
            const child = registry.findById(child_id) orelse return error.ChildNotAttached;
            const sent = switch (basis) {
                .work => (child.active orelse return error.ChildNotAttached).permission_mode,
                .user => |value| value,
            };
            // Work replaced since the first read is no longer this run's. A
            // user's turn belongs to no work.
            if (basis == .work and child.work_generation != work_generation) return error.ChildNotAttached;
            const profile = try self.profileOf(child_id, child.*);
            break :blk .{
                .generation = registry.generation,
                // It follows its parent's current mode, and keeps the one its
                // work was sent under only where the host can't say it.
                .permission_mode = self.modeFor(child_id, profile, parent_mode orelse sent),
                .profile = profile,
            };
        };

        // A profile that sets tools or MCP servers decides them from spark's
        // own, even past what the parent has; what it leaves unset is the
        // parent's.
        const sets_tools = if (current.profile) |profile| profiles.setsTools(profile) else false;
        const sets_mcp = if (current.profile) |profile| profiles.setsMcpServers(profile) else false;
        var base: ?HostAuthority = if (sets_tools or sets_mcp) try self.host.resolveBase(alloc, self.root_id) else null;
        defer if (base) |*value| value.deinit(alloc);
        const tool_source = if (sets_tools) if (base) |*value| value.tools else host.tools else host.tools;
        const integration_source = if (sets_mcp) if (base) |*value| value.integrations else host.integrations else host.integrations;
        const view_source: ?*const mcp_access.View = view: {
            if (sets_mcp) if (base) |*value| break :view if (value.mcp_view) |*view| view else null;
            break :view if (host.mcp_view) |*view| view else null;
        };
        const host_generation = if (base) |value| host.generation ^ std.math.rotl(u64, value.generation, 1) else host.generation;

        const owned_child_id = try alloc.dupe(u8, child_id);
        errdefer alloc.free(owned_child_id);
        const owned_root_id = try alloc.dupe(u8, self.root_id);
        errdefer alloc.free(owned_root_id);
        const behind = if (self.toolbox_behind) |value| value.slice() else &toolbox.default_behind;
        const tools = try cloneKeptTools(alloc, tool_source, current.profile, self.children_nest, behind);
        errdefer freeStrings(alloc, tools);
        // The profile's server scope.
        const integrations = try cloneIntegrations(alloc, integration_source, current.profile, view_source);
        errdefer freeStrings(alloc, integrations);
        var mcp_view = if (view_source) |view| try view.clone(alloc) else null;
        errdefer if (mcp_view) |*view| view.deinit(alloc);
        if (mcp_view) |*view| {
            try rebindMcpViewOwnership(alloc, view, child_id, self.root_id);
            if (current.profile) |profile| try narrowMcpView(alloc, view, profile);
        }
        return .{
            .child_id = owned_child_id,
            .root_id = owned_root_id,
            .generation = authorityGeneration(
                child_id,
                self.root_id,
                current.generation,
                host_generation,
            ),
            .tools = tools,
            .integrations = integrations,
            .permission_mode = current.permission_mode,
            .mcp_view = mcp_view,
        };
    }
};

pub const ToolAuthorityDecision = enum { allow, ask, deny, unavailable };

pub fn decideToolAuthority(
    alloc: Allocator,
    live: LiveAuthority,
    workspace_root: []const u8,
    tool_name: []const u8,
    target: []const u8,
    target_kind: permissions.PermissionTargetKind,
) !ToolAuthorityDecision {
    if (!contains(live.tools, tool_name) and
        !contains(live.integrations, tool_name))
    {
        return .unavailable;
    }
    _ = alloc;
    _ = workspace_root;
    _ = target;
    _ = target_kind;
    return .allow;
}

fn rebindMcpViewOwnership(
    alloc: Allocator,
    view: *mcp_access.View,
    child_id: []const u8,
    parent_id: []const u8,
) !void {
    const owner = try alloc.dupe(u8, child_id);
    errdefer alloc.free(owner);
    const parent = try alloc.dupe(u8, parent_id);
    alloc.free(view.owner_id);
    alloc.free(view.parent_id);
    view.owner_id = owner;
    view.parent_id = parent;
}

fn hostGeneration(
    tools: []const []const u8,
    integrations: []const []const u8,
    mcp_view: ?*const mcp_access.View,
) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("spark.subagent.host-authority.v3\x00");
    for (tools) |tool| hashString(&hash, tool);
    for (integrations) |integration| hashString(&hash, integration);
    if (mcp_view) |view| {
        hashU64(&hash, view.runtime_generation);
        hashString(&hash, view.owner_id);
        hashString(&hash, view.parent_id);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .little);
}

fn authorityGeneration(
    child_id: []const u8,
    root_id: []const u8,
    child_generation: u64,
    host_generation: u64,
) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("spark.subagent.live-authority.v2\x00");
    hashString(&hash, child_id);
    hashString(&hash, root_id);
    hashU64(&hash, child_generation);
    hashU64(&hash, host_generation);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const value = std.mem.readInt(u64, digest[0..8], .little);
    return if (value == 0) 1 else value;
}

fn contains(values: []const []const u8, value: []const u8) bool {
    for (values) |candidate| {
        if (std.mem.eql(u8, candidate, value)) return true;
    }
    return false;
}

fn cloneStrings(alloc: Allocator, values: []const []const u8) ![][]u8 {
    const out = try alloc.alloc([]u8, values.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |value| alloc.free(value);
        alloc.free(out);
    }
    for (values) |value| {
        out[copied] = try alloc.dupe(u8, value);
        copied += 1;
    }
    return out;
}

/// The host's tools a child may use: all of them, or with a profile only
/// those it allows, `behind` naming the ones the run keeps behind toolbox.
/// `subagent` is among them only when the child `nests`.
fn cloneKeptTools(
    alloc: Allocator,
    values: []const []const u8,
    profile: ?*const profiles.Profile,
    nests: bool,
    behind: []const []const u8,
) ![][]u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(alloc);
    for (values) |name| {
        if (!nests and std.mem.eql(u8, name, "subagent")) continue;
        if (profile) |value| if (!profiles.allowsTool(value, name, behind)) continue;
        try kept.append(alloc, name);
    }
    return cloneStrings(alloc, kept.items);
}

/// The host's MCP integrations a child may use: with a profile, only the
/// servers it allows.
/// Keeps only the MCP servers `profile` allows, and their tools, so a
/// profiled child cannot even find the others, as its integrations cannot
/// name them.
/// Narrows `host`'s MCP integrations and view to the servers `profile` sets,
/// as an instance's own profile narrows what its tree starts from. A profile
/// that sets none leaves them.
pub fn narrowHostToMcpServers(alloc: Allocator, host: *HostAuthority, profile: *const profiles.Profile) !void {
    if (!profiles.setsMcpServers(profile)) return;
    const integrations = try cloneIntegrations(alloc, host.integrations, profile, if (host.mcp_view) |*view| view else null);
    freeStrings(alloc, host.integrations);
    host.integrations = integrations;
    if (host.mcp_view) |*view| try narrowMcpView(alloc, view, profile);
}

fn narrowMcpView(alloc: Allocator, view: *mcp_access.View, profile: *const profiles.Profile) !void {
    // Both kept lists are allocated before anything in `view` moves or is
    // freed, so a failed allocation leaves `view` whole for its owner to free.
    var server_count: usize = 0;
    for (view.servers) |server| {
        if (profiles.allowsMcpServer(profile, server.name)) server_count += 1;
    }
    var tool_count: usize = 0;
    for (view.tools) |tool| {
        if (profiles.allowsMcpServer(profile, tool.server_name)) tool_count += 1;
    }
    const servers = try alloc.alloc(mcp_access.ServerIdentity, server_count);
    errdefer alloc.free(servers);
    const tools = try alloc.alloc(mcp_access.ToolIdentity, tool_count);

    var kept: usize = 0;
    for (view.servers) |*server| {
        if (profiles.allowsMcpServer(profile, server.name)) {
            servers[kept] = server.*;
            kept += 1;
        } else server.deinit(alloc);
    }
    kept = 0;
    for (view.tools) |*tool| {
        if (profiles.allowsMcpServer(profile, tool.server_name)) {
            tools[kept] = tool.*;
            kept += 1;
        } else tool.deinit(alloc);
    }
    alloc.free(view.servers);
    alloc.free(view.tools);
    view.servers = servers;
    view.tools = tools;
}

/// The MCP integrations in `values` that `profile` keeps. Each is an MCP
/// tool's name, kept when its server, as `view` names it, is one the profile
/// allows; a name `view` doesn't know is taken as a server's own name.
fn cloneIntegrations(
    alloc: Allocator,
    values: []const []const u8,
    profile: ?*const profiles.Profile,
    view: ?*const mcp_access.View,
) ![][]u8 {
    const value = profile orelse return cloneStrings(alloc, values);
    if (!profiles.setsMcpServers(value)) return cloneStrings(alloc, values);
    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(alloc);
    for (values) |name| {
        const server = if (view) |known| if (known.tool(name)) |tool| tool.server_name else name else name;
        if (profiles.allowsMcpServer(value, server)) try kept.append(alloc, name);
    }
    return cloneStrings(alloc, kept.items);
}

fn freeStrings(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

fn hashString(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hashU64(hash, value.len);
    hash.update(value);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

/// A host whose tools, MCP servers, and mode the tests change while children
/// run, to tell what a child follows live from what it keeps.
const LiveHost = struct {
    parent_mode: ?types.PermissionMode = .yolo,
    own_mode: ?types.PermissionMode = null,
    tools: []const []const u8 = &.{ "read_file", "write_file", "subagent" },
    integrations: []const []const u8 = &.{ "github_issue", "slack_post" },

    fn resolver(self: *LiveHost, children: *child_state.V2Children, root_id: []const u8, cache: *ProfileCache) Resolver {
        return .{
            .children = children,
            .root_id = root_id,
            .host = .{
                .context = self,
                .resolve_fn = resolve,
                .parent_permission_mode_fn = parentMode,
                .child_permission_mode_fn = ownMode,
                .base_fn = resolve,
            },
            .profiles = cache,
        };
    }

    fn resolve(raw: ?*anyopaque, alloc: Allocator, root_id: []const u8) HostResolveError!HostAuthority {
        const self: *const LiveHost = @ptrCast(@alignCast(raw.?));
        var servers = [_]mcp_access.ServerIdentity{
            .{ .name = @constCast("github"), .source = .profile, .scope = .profile, .connection_generation = 1, .catalog_generation = 1, .auth_generation = 1 },
            .{ .name = @constCast("slack"), .source = .profile, .scope = .profile, .connection_generation = 1, .catalog_generation = 1, .auth_generation = 1 },
        };
        var tools = [_]mcp_access.ToolIdentity{
            .{ .name = @constCast("github_issue"), .server_name = @constCast("github") },
            .{ .name = @constCast("slack_post"), .server_name = @constCast("slack") },
        };
        const view = mcp_access.View{
            .runtime_generation = 1,
            .owner_id = @constCast(root_id),
            .parent_id = @constCast(root_id),
            .servers = &servers,
            .tools = &tools,
        };
        return HostAuthority.captureWithMcpView(alloc, self.tools, self.integrations, &view) catch
            return error.OutOfMemory;
    }

    fn parentMode(raw: ?*anyopaque, _: Allocator, _: []const u8) ?types.PermissionMode {
        const self: *const LiveHost = @ptrCast(@alignCast(raw.?));
        return self.parent_mode;
    }

    fn ownMode(raw: ?*anyopaque, _: []const u8) ?types.PermissionMode {
        const self: *const LiveHost = @ptrCast(@alignCast(raw.?));
        return self.own_mode;
    }
};

/// What the profile `name` in `roots` set, as a child that starts in it saves.
fn startedIn(arena: Allocator, roots: profiles.Roots, name: []const u8) !started_with_mod.StartedWith {
    var failure: ?[]const u8 = null;
    const loaded = try profiles.load(arena, roots, name, &failure);
    return started_with_mod.of(&loaded);
}
