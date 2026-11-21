//! Agent profiles: named, saved settings for what an agent may do. Main runs
//! in one profile, `main` unless `spark --profile` names another, and each
//! subagent starts in the profile main names for it, `main` by default.
//!
//! A profile is a folder, `<name>/profile.json` with an optional
//! `<name>/prompt.md`. A name resolves from the user's `~/.spark/agents/` first,
//! then the repository's `.spark/agents/`, then spark's own `main` and `agent`.
//! A repository's profile never sets the permission mode, so a cloned
//! repository cannot grant itself access, and its files never resolve
//! outside the repository, so it cannot read the user's other files.

const std = @import("std");
const toolbox = @import("../tooling/toolbox.zig");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");
const pathing = @import("../workspace/pathing.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const Allocator = std.mem.Allocator;

pub const max_name_bytes = 64;
pub const max_settings_bytes = 64 * 1024;
pub const max_prompt_bytes = 256 * 1024;
pub const max_list_entry_bytes = 256;

pub const settings_file_name = "profile.json";
pub const prompt_file_name = "prompt.md";
pub const main_name = "main";
pub const agent_name = "agent";

const subagent_tool = "subagent";
const wildcard = "*";

pub const Source = enum { home, project, builtin };
/// Whether an agent is main or a subagent.
pub const Role = enum { main, subagent };
pub const PromptMode = enum { append, replace };

pub const IgnoredReason = enum {
    unknown_key,
    project_cannot_set_permissions,
};

/// A key a profile set that spark did not apply.
pub const Ignored = struct {
    key: []const u8,
    reason: IgnoredReason,
};

/// A loaded profile. Its slices belong to the arena it was parsed with.
pub const Profile = struct {
    name: []const u8,
    description: []const u8,
    source: Source,
    model: ?[]const u8 = null,
    effort: ?types.ReasoningEffort = null,
    /// Null means the agent runs under its parent's mode.
    permission_mode: ?types.PermissionMode = null,
    /// Tool names. `*` means every tool spark has and `!name` removes one.
    /// Set, it decides the agent's tools, even ones its parent lacks;
    /// null, the agent has its parent's.
    tools: ?[]const []const u8 = null,
    /// MCP server names, matched and inherited the same way as `tools`.
    mcp_servers: ?[]const []const u8 = null,
    prompt: []const u8 = "",
    prompt_mode: PromptMode = .append,
    ignored: []const Ignored = &.{},
};

/// A profile's name, description, and where it resolved from, for the list
/// main picks from.
pub const Entry = struct {
    name: []const u8,
    description: []const u8,
    source: Source,
    /// The profile's own model, effort, and tools; null keeps the ones spark
    /// runs with.
    model: ?[]const u8 = null,
    effort: ?types.ReasoningEffort = null,
    tools: ?[]const []const u8 = null,
};

pub const ParseError = error{ OutOfMemory, InvalidProfile };
pub const LoadError = error{ OutOfMemory, InvalidProfile, ProfileNotFound, ReadFailed };

/// Where profiles are saved. Either may be absent.
pub const Roots = struct {
    /// `~/.spark/agents`.
    home: ?[]const u8 = null,
    /// `<workspace>/.spark/agents`.
    project: ?[]const u8 = null,
    /// The workspace itself, which a repository's profile files must stay
    /// inside. Without it they must stay inside `project`.
    repository: ?[]const u8 = null,

    /// Builds both roots from the spark home and the workspace. Caller owns the
    /// result through `arena`.
    pub fn init(arena: Allocator, home: ?[]const u8, workspace_root: ?[]const u8) !Roots {
        return .{
            .home = if (home) |path| try profile_paths.agentsDir(arena, path) else null,
            .project = if (workspace_root) |root|
                try std.Io.Dir.path.join(arena, &.{ root, profile_paths.root_dir_name, profile_paths.agents_dir_name })
            else
                null,
            .repository = workspace_root,
        };
    }

    /// The folder a profile saved in `dir` must keep its files in: the
    /// repository for a repository's profile. The user's own profiles may
    /// link anywhere, so theirs is null.
    fn fileRoot(self: Roots, source: Source, dir: []const u8) ?[]const u8 {
        return switch (source) {
            .project => self.repository orelse dir,
            .home, .builtin => null,
        };
    }
};

/// The profile an agent runs in, with the memory it was loaded into. Starts as
/// spark's `main`.
pub const Held = struct {
    arena: ?std.heap.ArenaAllocator = null,
    profile: Profile = builtin(main_name).?,
    /// The system prompt with the profile's prompt applied, or null to use
    /// spark's own.
    system_prompt: ?[]const u8 = null,

    /// Replaces the current profile with `name` from `roots`, applying its
    /// prompt to `base_prompt`. On failure, the current profile stays and
    /// `failure` holds a message that `alloc` owns.
    pub fn replace(
        self: *Held,
        alloc: Allocator,
        roots_home: ?[]const u8,
        workspace_root: ?[]const u8,
        name: []const u8,
        base_prompt: []const u8,
        failure: *?[]u8,
    ) LoadError!void {
        var next = std.heap.ArenaAllocator.init(alloc);
        errdefer next.deinit();
        const arena = next.allocator();
        const roots = try Roots.init(arena, roots_home, workspace_root);
        var message: ?[]const u8 = null;
        const profile = load_profile: {
            break :load_profile load(arena, roots, name, &message) catch |err| {
                if (message) |text| failure.* = alloc.dupe(u8, text) catch null;
                return err;
            };
        };
        const prompt = try systemPrompt(arena, &profile, base_prompt);
        self.deinit();
        self.* = .{
            .arena = next,
            .profile = profile,
            .system_prompt = if (prompt.ptr == base_prompt.ptr) null else prompt,
        };
    }

    pub fn deinit(self: *Held) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    for (name) |byte| switch (byte) {
        'a'...'z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// spark's own profiles: `main` and `agent`. Neither sets tools, MCP servers,
/// or a mode, so an agent in either is a copy of the one that started it,
/// and an instance in `main` has every tool spark has.
pub fn builtin(name: []const u8) ?Profile {
    if (std.mem.eql(u8, name, main_name)) return .{
        .name = main_name,
        .description = "spark itself, with every tool",
        .source = .builtin,
    };
    if (std.mem.eql(u8, name, agent_name)) return .{
        .name = agent_name,
        .description = "A copy of the agent that starts it",
        .source = .builtin,
    };
    return null;
}

/// Parses a profile's `profile.json` and `prompt.md` text. On failure,
/// `failure` holds a message naming the profile and the problem. Every slice
/// of the result, and the message, belong to `arena`.
pub fn parse(
    arena: Allocator,
    name: []const u8,
    source: Source,
    settings_json: []const u8,
    prompt: []const u8,
    failure: *?[]const u8,
) ParseError!Profile {
    if (!validName(name)) return fail(arena, failure, "profile name '{s}' must use lowercase letters, digits, '-', or '_'", .{name});
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, settings_json, .{}) catch
        return fail(arena, failure, "profile '{s}': {s} is not valid JSON", .{ name, settings_file_name });
    if (root != .object) return fail(arena, failure, "profile '{s}': {s} must be a JSON object", .{ name, settings_file_name });

    var profile: Profile = .{ .name = name, .description = "", .source = source, .prompt = prompt };
    var ignored: std.ArrayList(Ignored) = .empty;
    var it = root.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "description")) {
            profile.description = try stringField(arena, failure, name, key, value);
        } else if (std.mem.eql(u8, key, "model")) {
            profile.model = try stringField(arena, failure, name, key, value);
        } else if (std.mem.eql(u8, key, "effort")) {
            const raw = try stringField(arena, failure, name, key, value);
            profile.effort = types.ReasoningEffort.parse(raw) orelse
                return fail(arena, failure, "profile '{s}': unknown effort '{s}'", .{ name, raw });
        } else if (std.mem.eql(u8, key, "permission_mode")) {
            if (source == .project) {
                try ignored.append(arena, .{ .key = key, .reason = .project_cannot_set_permissions });
                continue;
            }
            const raw = try stringField(arena, failure, name, key, value);
            profile.permission_mode = types.PermissionMode.parse(raw) orelse
                return fail(arena, failure, "profile '{s}': unknown permission_mode '{s}'", .{ name, raw });
        } else if (std.mem.eql(u8, key, "tools")) {
            profile.tools = try nameList(arena, failure, name, key, value);
        } else if (std.mem.eql(u8, key, "mcp_servers")) {
            profile.mcp_servers = try nameList(arena, failure, name, key, value);
        } else if (std.mem.eql(u8, key, "prompt")) {
            const raw = try stringField(arena, failure, name, key, value);
            profile.prompt_mode = std.meta.stringToEnum(PromptMode, raw) orelse
                return fail(arena, failure, "profile '{s}': prompt must be 'append' or 'replace'", .{name});
        } else {
            try ignored.append(arena, .{ .key = key, .reason = .unknown_key });
        }
    }
    if (profile.description.len == 0) return fail(arena, failure, "profile '{s}' needs a description", .{name});
    profile.ignored = ignored.items;
    return profile;
}

/// Whether `profile` lets an agent use `tool`. `*` covers every tool,
/// `subagent` included, for main and subagents alike. A profile that sets
/// no tools allows every one, leaving its parent's in place. `behind` names
/// the built-in tools the agent's run offers through toolbox.
pub fn allowsTool(profile: *const Profile, tool: []const u8, behind: []const []const u8) bool {
    const tools = profile.tools orelse return true;
    if (listAllows(tools, tool, false)) return true;
    // A profile written for the tools toolbox replaces keeps what they gave:
    // toolbox reaches its skills and MCP tools now. One that lists a tool
    // the run keeps behind toolbox reaches it there. What toolbox runs is
    // still decided against the profile, call by call.
    if (std.mem.eql(u8, tool, toolbox.tool_name)) {
        // Leaving toolbox out by name leaves it out, whatever else is kept.
        if (listDenies(tools, toolbox.tool_name)) return false;
        for (toolbox.replaced) |name| if (listAllows(tools, name, false)) return true;
        for (behind) |name| if (listAllows(tools, name, false)) return true;
    }
    // Opening a skill, opening an MCP tool, and searching are each named for
    // the tool they replaced; a profile that lists toolbox itself allows all
    // three, apart from one it leaves out by name.
    if (toolbox.isReplaced(tool)) return !listDenies(tools, tool) and listAllows(tools, toolbox.tool_name, false);
    return false;
}

/// Whether `entries` leaves `name` out with a `!name` entry.
fn listDenies(entries: []const []const u8, name: []const u8) bool {
    for (entries) |entry| {
        if (entry.len > 1 and entry[0] == '!' and std.mem.eql(u8, entry[1..], name)) return true;
    }
    return false;
}

pub fn allowsMcpServer(profile: *const Profile, server: []const u8) bool {
    const servers = profile.mcp_servers orelse return true;
    return listAllows(servers, server, false);
}

/// Whether `profile` decides its agent's tools rather than inheriting its
/// parent's.
pub fn setsTools(profile: *const Profile) bool {
    return profile.tools != null;
}

/// Whether `profile` decides its agent's MCP servers rather than inheriting
/// its parent's.
pub fn setsMcpServers(profile: *const Profile) bool {
    return profile.mcp_servers != null;
}

/// The mode an agent in `profile` runs under: the profile's own, or its
/// parent's when it sets none. Main's parent is the user's own setting.
pub fn permissionMode(profile: *const Profile, parent: types.PermissionMode) types.PermissionMode {
    return profile.permission_mode orelse parent;
}

/// The system prompt for an agent in `profile`: `base` with the profile's
/// prompt added, or the profile's prompt alone when it says `replace`. A
/// profile without a prompt keeps `base`. The result may borrow `base` or the
/// profile, or belong to `arena`.
pub fn systemPrompt(arena: Allocator, profile: *const Profile, base: []const u8) ![]const u8 {
    const own = std.mem.trim(u8, profile.prompt, " \t\r\n");
    if (own.len == 0) return base;
    return switch (profile.prompt_mode) {
        .replace => own,
        .append => try arena.print("{s}\n\n{s}", .{ base, own }),
    };
}

/// Loads the profile named `name`: the user's own, then the repository's,
/// then spark's. `main` is always spark's own. On failure, `failure` holds a message
/// for the user. The result belongs to `arena`.
pub fn load(arena: Allocator, roots: Roots, name: []const u8, failure: *?[]const u8) LoadError!Profile {
    if (!validName(name)) return fail(arena, failure, "profile name '{s}' must use lowercase letters, digits, '-', or '_'", .{name});
    if (std.mem.eql(u8, name, main_name)) return builtin(main_name).?;
    // The profile keeps its name, so it is `arena`'s like the rest of it,
    // not the caller's.
    const owned = try arena.dupe(u8, name);
    if (roots.home) |dir| if (try readProfile(arena, dir, owned, .home, roots.fileRoot(.home, dir), failure)) |profile| return profile;
    if (roots.project) |dir| if (try readProfile(arena, dir, owned, .project, roots.fileRoot(.project, dir), failure)) |profile| return profile;
    if (builtin(name)) |profile| return profile;
    const names = try listNames(arena, roots);
    failure.* = try arena.print("no profile named '{s}'. Profiles: {s}", .{ name, names });
    return error.ProfileNotFound;
}

/// Every profile main can pick, by name, with the user's own over the
/// repository's over spark's. A profile that fails to load is left out. The
/// result belongs to `arena` and is sorted by name.
pub fn list(arena: Allocator, roots: Roots) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    const sources = [_]struct { dir: ?[]const u8, source: Source }{
        .{ .dir = roots.home, .source = .home },
        .{ .dir = roots.project, .source = .project },
    };
    for (sources) |root| {
        const dir_path = root.dir orelse continue;
        var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io_mod.getIo());
        var it = dir.iterate();
        while (it.next(io_mod.getIo()) catch null) |item| {
            if (item.kind != .directory or !validName(item.name)) continue;
            if (std.mem.eql(u8, item.name, main_name)) continue;
            if (hasEntry(entries.items, item.name)) continue;
            const name = try arena.dupe(u8, item.name);
            var failure: ?[]const u8 = null;
            const profile = (readProfile(arena, dir_path, name, root.source, roots.fileRoot(root.source, dir_path), &failure) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            }) orelse continue;
            try entries.append(arena, .{ .name = profile.name, .description = profile.description, .source = profile.source, .model = profile.model, .effort = profile.effort, .tools = profile.tools });
        }
    }
    for ([_][]const u8{ main_name, agent_name }) |name| {
        if (hasEntry(entries.items, name)) continue;
        const profile = builtin(name).?;
        try entries.append(arena, .{ .name = profile.name, .description = profile.description, .source = .builtin, .model = profile.model, .effort = profile.effort, .tools = profile.tools });
    }
    sort_utils.sort(Entry, entries.items, {}, entryLessThan);
    return entries.items;
}

fn listNames(arena: Allocator, roots: Roots) ![]const u8 {
    const entries = try list(arena, roots);
    var out: std.ArrayList(u8) = .empty;
    for (entries, 0..) |entry, index| {
        if (index > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, entry.name);
    }
    return out.items;
}

fn hasEntry(entries: []const Entry, name: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.name, name)) return true;
    return false;
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Folder entries `listForCompletion` reads across both roots, counting every
/// one, profile or not.
const max_completion_dir_entries = 128;
/// `profile.json` bytes `listForCompletion` reads across every profile.
const max_completion_settings_bytes = 1024 * 1024;

/// Profiles to offer as completions. `limited` says the scan stopped at a
/// bound or skipped a file too large to read, so profiles may be missing.
pub const CompletionList = struct {
    entries: []Entry,
    limited: bool,

    /// Frees what `listForCompletion` returned, for an `alloc` that is not an
    /// arena.
    pub fn deinit(self: CompletionList, alloc: Allocator) void {
        freeEntries(alloc, self.entries);
        alloc.free(self.entries);
    }
};

/// Like `list`, but bounded for completion: it reads at most
/// `max_completion_dir_entries` folder entries and
/// `max_completion_settings_bytes` of settings, and never reads `prompt.md`.
/// The user's own still win over the repository's, spark's `main` and `agent`
/// are always there, and the entries are sorted by name. Every slice of the
/// result belongs to `alloc`.
pub fn listForCompletion(alloc: Allocator, roots: Roots) Allocator.Error!CompletionList {
    const io = io_mod.getIo();
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        freeEntries(alloc, entries.items);
        entries.deinit(alloc);
    }
    // Holds one profile's paths, settings, parsed JSON, and failure message,
    // reset before the next so a scan of failing profiles stays bounded.
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    var visited: usize = 0;
    var budget: usize = max_completion_settings_bytes;
    var limited = false;
    const sources = [_]struct { dir: ?[]const u8, source: Source }{
        .{ .dir = roots.home, .source = .home },
        .{ .dir = roots.project, .source = .project },
    };
    scan: for (sources) |root| {
        const dir_path = root.dir orelse continue;
        var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch {
            limited = true;
            break :scan;
        }) |item| {
            visited += 1;
            if (visited > max_completion_dir_entries) {
                limited = true;
                break :scan;
            }
            if (item.kind != .directory or !validName(item.name)) continue;
            if (std.mem.eql(u8, item.name, main_name)) continue;
            if (hasEntry(entries.items, item.name)) continue;
            _ = scratch_state.reset(.retain_capacity);
            const read = try readCompletionProfile(scratch_state.allocator(), dir_path, item.name, root.source, roots.fileRoot(root.source, dir_path), budget);
            budget -= read.bytes;
            switch (read.outcome) {
                .missing, .invalid => {},
                .too_large => limited = true,
                // A profile left unread may outrank a later one of the same
                // name, so the scan stops rather than offer the wrong one.
                .over_budget => {
                    limited = true;
                    break :scan;
                },
                .loaded => |profile| {
                    try entries.ensureUnusedCapacity(alloc, 1);
                    entries.appendAssumeCapacity(try cloneEntry(alloc, profile));
                },
            }
        }
    }
    for ([_][]const u8{ main_name, agent_name }) |name| {
        if (hasEntry(entries.items, name)) continue;
        try entries.ensureUnusedCapacity(alloc, 1);
        entries.appendAssumeCapacity(try cloneEntry(alloc, builtin(name).?));
    }
    sort_utils.sort(Entry, entries.items, {}, entryLessThan);
    return .{ .entries = try entries.toOwnedSlice(alloc), .limited = limited };
}

const CompletionRead = struct {
    /// Settings bytes read, counted against the budget whether or not they
    /// parsed.
    bytes: usize = 0,
    outcome: union(enum) {
        missing,
        invalid,
        /// Larger than `max_settings_bytes`, which `load` refuses too.
        too_large,
        /// Larger than what was left of the budget.
        over_budget,
        loaded: Profile,
    },
};

/// Reads and parses `<dir>/<name>/profile.json` alone into `scratch`, reading
/// no more than `budget` bytes.
fn readCompletionProfile(
    scratch: Allocator,
    dir: []const u8,
    name: []const u8,
    source: Source,
    within: ?[]const u8,
    budget: usize,
) Allocator.Error!CompletionRead {
    const limit = @min(max_settings_bytes, budget);
    if (limit == 0) return .{ .outcome = .over_budget };
    const settings_path = try std.Io.Dir.path.join(scratch, &.{ dir, name, settings_file_name });
    const settings = readFile(scratch, settings_path, limit, within) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => .{ .outcome = .missing },
        error.StreamTooLong => .{
            .bytes = limit,
            .outcome = if (limit < max_settings_bytes) .over_budget else .too_large,
        },
        else => .{ .outcome = .invalid },
    };
    var failure: ?[]const u8 = null;
    const profile = parse(scratch, name, source, settings, "", &failure) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidProfile => .{ .bytes = settings.len, .outcome = .invalid },
    };
    return .{ .bytes = settings.len, .outcome = .{ .loaded = profile } };
}

/// Copies the parts of `profile` an `Entry` keeps into `alloc`.
fn cloneEntry(alloc: Allocator, profile: Profile) Allocator.Error!Entry {
    const name = try alloc.dupe(u8, profile.name);
    errdefer alloc.free(name);
    const description = try alloc.dupe(u8, profile.description);
    errdefer alloc.free(description);
    const model = if (profile.model) |text| try alloc.dupe(u8, text) else null;
    errdefer if (model) |text| alloc.free(text);
    const tools = if (profile.tools) |names| try cloneNames(alloc, names) else null;
    return .{ .name = name, .description = description, .source = profile.source, .model = model, .effort = profile.effort, .tools = tools };
}

/// A copy of `names` that `alloc` owns, each name and the list itself.
pub fn cloneNames(alloc: Allocator, names: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try alloc.alloc([]const u8, names.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |text| alloc.free(text);
        alloc.free(out);
    }
    for (names, out) |text, *slot| {
        slot.* = try alloc.dupe(u8, text);
        done += 1;
    }
    return out;
}

fn freeEntries(alloc: Allocator, entries: []const Entry) void {
    for (entries) |entry| {
        alloc.free(entry.name);
        alloc.free(entry.description);
        if (entry.model) |text| alloc.free(text);
        if (entry.tools) |names| {
            for (names) |text| alloc.free(text);
            alloc.free(names);
        }
    }
}

/// Reads `<dir>/<name>/profile.json` and its optional `prompt.md`. Returns null
/// when the profile is not saved there. With `within`, both files must
/// resolve inside that folder (`Roots.fileRoot`).
fn readProfile(
    arena: Allocator,
    dir: []const u8,
    name: []const u8,
    source: Source,
    within: ?[]const u8,
    failure: *?[]const u8,
) LoadError!?Profile {
    const settings_path = try std.Io.Dir.path.join(arena, &.{ dir, name, settings_file_name });
    const settings = readFile(arena, settings_path, max_settings_bytes, within) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(arena, failure, "profile '{s}': cannot read {s}: {s}", .{ name, settings_path, try readFailure(arena, err, max_settings_bytes) }),
    };
    const prompt_path = try std.Io.Dir.path.join(arena, &.{ dir, name, prompt_file_name });
    const prompt = readFile(arena, prompt_path, max_prompt_bytes, within) catch |err| switch (err) {
        error.FileNotFound => "",
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(arena, failure, "profile '{s}': cannot read {s}: {s}", .{ name, prompt_path, try readFailure(arena, err, max_prompt_bytes) }),
    };
    return parse(arena, name, source, settings, prompt, failure) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidProfile => error.InvalidProfile,
    };
}

/// Why a profile file couldn't be read, in words, with the error's name when
/// there are none for it. The result belongs to `arena`.
fn readFailure(arena: Allocator, err: anyerror, max_bytes: usize) Allocator.Error![]const u8 {
    return switch (err) {
        error.StreamTooLong => if (max_bytes == max_prompt_bytes)
            "it is larger than the 256 KiB a profile file may hold"
        else
            "it is larger than the 64 KiB a profile file may hold",
        error.AccessDenied, error.PermissionDenied => "spark isn't allowed to read it",
        error.IsDir => "it is a folder, not a file",
        error.NotRegularFile => "it isn't a regular file",
        error.OutsideRepository => "it links outside the repository, and a repository's profile may read only its own files",
        else => try arena.print("the file couldn't be read ({s})", .{@errorName(err)}),
    };
}

test "profile read failures name the limit or the cause instead of an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(std.mem.find(u8, try readFailure(arena, error.StreamTooLong, max_prompt_bytes), "256 KiB") != null);
    try std.testing.expect(std.mem.find(u8, try readFailure(arena, error.StreamTooLong, max_settings_bytes), "64 KiB") != null);
    try std.testing.expectEqualStrings("it is a folder, not a file", try readFailure(arena, error.IsDir, max_prompt_bytes));
    try std.testing.expectEqualStrings("the file couldn't be read (SymLinkLoop)", try readFailure(arena, error.SymLinkLoop, max_prompt_bytes));
}

fn fuzzProfileParse(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var settings_buffer: [4096]u8 = undefined;
    const settings = settings_buffer[0..@intCast(smith.slice(&settings_buffer))];
    var prompt_buffer: [512]u8 = undefined;
    const prompt = prompt_buffer[0..@intCast(smith.slice(&prompt_buffer))];
    var failure: ?[]const u8 = null;
    const profile = parse(arena.allocator(), "fuzz", .project, settings, prompt, &failure) catch |err| switch (err) {
        // A refused profile always says why.
        error.InvalidProfile => return std.testing.expect(failure != null),
        error.OutOfMemory => return err,
    };
    try std.testing.expectEqualStrings("fuzz", profile.name);
}

/// Reads the profile file at `path`, up to `max_bytes`, into `arena`. It
/// reads only a regular file, so a link to a terminal, a pipe, or a device
/// can neither hang spark nor feed it. With `within`, the file's real path must
/// lie inside that folder, so a link can't hand a repository's profile a
/// file from elsewhere on the machine.
fn readFile(arena: Allocator, path: []const u8, max_bytes: usize, within: ?[]const u8) ![]u8 {
    const io = io_mod.getIo();
    const target = try io_mod.realpathAlloc(arena, path);
    if (within) |root_path| {
        const root = try io_mod.realpathAlloc(arena, root_path);
        if (!pathing.pathInside(root, target)) return error.OutsideRepository;
    }
    // Checked before opening: opening a pipe waits for a writer.
    const stat = try std.Io.Dir.cwd().statFile(io, target, .{ .follow_symlinks = false });
    switch (stat.kind) {
        .file => {},
        .directory => return error.IsDir,
        else => return error.NotRegularFile,
    }
    var file = try std.Io.Dir.openFileAbsolute(io, target, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io);
    // The path may have changed since the check.
    if ((try file.stat(io)).kind != .file) return error.NotRegularFile;
    return io_mod.readFileToEnd(arena, &file, max_bytes);
}

/// Saves `target` at `sub_path` as a link, creating its folders.
fn linkTestFile(dir: std.Io.Dir, target: []const u8, sub_path: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| try dir.createDirPath(io_mod.getIo(), parent);
    try dir.symLink(io_mod.getIo(), target, sub_path, .{ .is_directory = false });
}

/// Saves `bytes` at `sub_path`, creating its folders. For tests, here and in
/// other files.
pub fn writeTestFile(dir: std.Io.Dir, sub_path: []const u8, bytes: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| try dir.createDirPath(io_mod.getIo(), parent);
    var file = try dir.createFile(io_mod.getIo(), sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), bytes);
}

fn listAllows(entries: []const []const u8, name: []const u8, wildcard_skips: bool) bool {
    var allowed = false;
    for (entries) |entry| {
        if (entry.len > 1 and entry[0] == '!') {
            if (std.mem.eql(u8, entry[1..], name)) return false;
        } else if (std.mem.eql(u8, entry, wildcard)) {
            if (!wildcard_skips) allowed = true;
        } else if (std.mem.eql(u8, entry, name)) {
            allowed = true;
        }
    }
    return allowed;
}

fn stringField(arena: Allocator, failure: *?[]const u8, name: []const u8, key: []const u8, value: std.json.Value) ParseError![]const u8 {
    if (value != .string or value.string.len == 0)
        return fail(arena, failure, "profile '{s}': {s} must be a non-empty string", .{ name, key });
    return value.string;
}

/// The text of one entry of a `tools` or `mcp_servers` list: a non-empty string
/// of at most `max_list_entry_bytes`, or null for anything else. A profile
/// file and a saved copy of its lists (`started_with.zig`) both take entries
/// by this rule.
pub fn listEntry(value: std.json.Value) ?[]const u8 {
    if (value != .string or value.string.len == 0 or value.string.len > max_list_entry_bytes) return null;
    return value.string;
}

fn nameList(arena: Allocator, failure: *?[]const u8, name: []const u8, key: []const u8, value: std.json.Value) ParseError![]const []const u8 {
    if (value != .array) return fail(arena, failure, "profile '{s}': {s} must be a list of names", .{ name, key });
    const out = try arena.alloc([]const u8, value.array.items.len);
    for (value.array.items, out) |item, *slot| {
        slot.* = listEntry(item) orelse
            return fail(arena, failure, "profile '{s}': {s} must be a list of names", .{ name, key });
    }
    return out;
}

fn fail(arena: Allocator, failure: *?[]const u8, comptime fmt: []const u8, args: anytype) error{ OutOfMemory, InvalidProfile } {
    failure.* = try arena.print(fmt, args);
    return error.InvalidProfile;
}

const testing = std.testing;

fn testParse(arena: Allocator, source: Source, json: []const u8, prompt: []const u8) !Profile {
    var failure: ?[]const u8 = null;
    return parse(arena, "reviewer", source, json, prompt, &failure);
}

fn writeTestProfile(dir: std.Io.Dir, sub_path: []const u8, json: []const u8) !void {
    try dir.createDirPath(io_mod.getIo(), sub_path);
    const file_path = try std.Io.Dir.path.join(testing.allocator, &.{ sub_path, settings_file_name });
    defer testing.allocator.free(file_path);
    var file = try dir.createFile(io_mod.getIo(), file_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), json);
}

fn findEntry(entries: []const Entry, name: []const u8) ?Entry {
    for (entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;
    return null;
}
