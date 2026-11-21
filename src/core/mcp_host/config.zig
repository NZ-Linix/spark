//! spark's MCP servers as the engine runs them. Each config from `builtins/mcp.zig`
//! `loadNativeConfigs` (profile first, then the project's) becomes an
//! `mcp.engine.Config`, or is held back with the reason, which spark shows.

const std = @import("std");
const credentials = @import("credentials.zig");
const mcp = @import("../../mcp/mcp.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const slack = @import("slack.zig");

const Allocator = std.mem.Allocator;
const McpServerConfig = mcp_contract.McpServerConfig;

/// Why a configured server is not given to the engine.
pub const Held = enum {
    /// `"enabled": false`.
    disabled,
    /// A project server nobody approved yet.
    waiting_for_approval,
    /// A project server the user rejected.
    rejected,
    /// `"type": "sse"`: HTTP+SSE is deprecated and the engine doesn't speak it.
    /// `"type": "acp"` from an editor: a draft that ACP v1 doesn't define.
    unsupported,
    /// A header, token, or client secret names an environment variable that isn't set.
    missing_env,
    /// A header or token names an environment variable whose value a header
    /// can't carry: a line break or another control character.
    invalid_env,
};

pub const Server = struct {
    name: []const u8,
    source: mcp_contract.ConfigSource,
    scope: mcp_contract.ConfigScope,
    transport: mcp_contract.McpTransport,
    /// An HTTP server's URL, which also keys its credential; null for stdio.
    url: ?[]const u8,
    /// What a stdio server runs, to show what is trusted.
    command: ?[]const u8,
    callback_port: ?u16,
    /// Signs in as spark's Slack app, whose redirect says `localhost`.
    slack_app: bool = false,
    held: ?Held = null,
    /// An editor's server whose tools go to the model every turn (ACP
    /// `_meta.spark.alwaysLoaded`).
    always_loaded: bool = false,
    /// The variable a `missing_env` or `invalid_env` server names.
    missing: ?[]const u8 = null,
    /// The workspace a `.mcp.json` server comes from: its saved login is that
    /// workspace's own. Null for every other server.
    workspace: ?[]const u8 = null,

    /// What an HTTP server's login is saved under.
    pub fn credentialKey(s: Server) credentials.Key {
        return .{ .name = s.name, .url = s.url.?, .workspace = s.workspace };
    }
};

pub const Resolved = struct {
    servers: []Server,
    /// What the engine runs, in order: `engine[i]` is `servers[engine_server[i]]`.
    engine: []mcp.engine.Config,
    engine_server: []usize,
};

/// The command and its arguments as one line, quoting what a shell would split.
fn commandLine(arena: Allocator, command: []const u8, args: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..args.len + 1) |k| {
        const word = if (k == 0) command else args[k - 1];
        if (k > 0) try out.append(arena, ' ');
        const plain = word.len > 0 and std.mem.findAny(u8, word, " \t\n'\"$`\\") == null;
        if (plain) {
            try out.appendSlice(arena, word);
            continue;
        }
        try out.append(arena, '\'');
        for (word) |b| if (b == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, b);
        try out.append(arena, '\'');
    }
    return out.items;
}

/// Allocates everything with `arena`; the engine copies what it keeps. Saved
/// sign-in credentials are not read here: the runtime hands them to the
/// engine from its own thread.
pub fn resolve(
    arena: Allocator,
    configs: []const McpServerConfig,
    inherited: *const std.process.Environ.Map,
    /// The workspace whose `.mcp.json` servers these are.
    workspace_root: []const u8,
) Allocator.Error!Resolved {
    const servers = try arena.alloc(Server, configs.len);
    var engine: std.ArrayList(mcp.engine.Config) = .empty;
    var engine_server: std.ArrayList(usize) = .empty;
    for (configs, servers, 0..) |*c, *s, i| {
        s.* = .{
            .name = try arena.dupe(u8, c.name),
            .source = c.source,
            .scope = c.scope,
            .transport = c.transport,
            .url = if (c.url) |u| try arena.dupe(u8, u) else null,
            .command = if (c.command) |command| try commandLine(arena, command, c.args) else null,
            .callback_port = if (c.auth) |a| a.callback_port else null,
            .always_loaded = c.always_loaded,
            .workspace = if (c.source == .workspace) try arena.dupe(u8, workspace_root) else null,
        };
        s.held = heldFor(c);
        if (s.held != null) continue;
        const transport = (try transportFor(arena, c, inherited, s)) orelse continue;
        var auth: @FieldType(mcp.engine.Config, "auth") = .{};
        if (c.auth) |a| {
            auth.client_id = a.client_id;
            auth.client_metadata_url = a.client_metadata_url;
            auth.resource = a.resource;
            // `oauth.scopes` stand in for the server's own list; a challenge's still win.
            if (a.scopes.len > 0) auth.scopes = try std.mem.join(arena, " ", a.scopes);
            if (a.client_secret_env) |variable| {
                auth.client_secret = inherited.get(variable) orelse {
                    s.held = .missing_env;
                    s.missing = try arena.dupe(u8, variable);
                    continue;
                };
            }
        }
        // Slack registers no clients: without an app of the user's own, spark's
        // Slack app signs in.
        if (auth.client_id == null and slack.isSlack(s.url)) auth.client_id = slack.client_id;
        // Only Slack's own server signs in as spark's app, with the redirect
        // and scopes the app has: another server that names spark's app signs
        // in on its own, with a redirect Slack refuses.
        const spark_slack_app = if (auth.client_id) |id| std.mem.eql(u8, id, slack.client_id) else false;
        s.slack_app = spark_slack_app and slack.appServer(s.url);
        if (s.slack_app) {
            if (s.callback_port == null) s.callback_port = slack.callback_port;
            if (auth.scopes == null) auth.scopes = slack.scopes;
            // Slack's tokens are for its origin with a trailing slash; the engine
            // takes it only if it is the server's own.
            if (auth.resource == null) if (s.url) |url| {
                auth.resource = try arena.print("{s}/", .{origin(url)});
            };
        }
        // Where spark keeps logins, it decides each refresh.
        if (s.url != null) auth.refresh_via_host = true;
        // The server's own limits: how long its start may take, and how long a
        // request may go without an answer.
        var timeouts: @FieldType(mcp.engine.Options, "timeouts") = .{};
        timeouts.start_ms = c.startup_timeout_ms;
        timeouts.idle_ms = c.operation_timeout_ms;
        timeouts.hard_ms = @max(timeouts.hard_ms, c.operation_timeout_ms);
        try engine.append(arena, .{ .name = s.name, .transport = transport, .auth = auth, .timeouts = timeouts });
        try engine_server.append(arena, i);
    }
    return .{ .servers = servers, .engine = engine.items, .engine_server = engine_server.items };
}

/// `servers` copied into `arena`, which outlives them: a server's strings
/// that equal the ones its namesake in `prior` has are shared, so taking a
/// config that changed little again costs little more than the list.
pub fn keepServers(arena: Allocator, servers: []const Server, prior: []const Server) Allocator.Error![]Server {
    const out = try arena.alloc(Server, servers.len);
    for (servers, out) |s, *o| {
        const old: ?Server = for (prior) |p| {
            if (std.mem.eql(u8, p.name, s.name)) break p;
        } else null;
        o.* = s;
        o.name = if (old) |p| p.name else try arena.dupe(u8, s.name);
        inline for (.{ "url", "command", "missing", "workspace" }) |field| {
            @field(o, field) = try reuse(arena, @field(s, field), if (old) |p| @field(p, field) else null);
        }
    }
    return out;
}

fn reuse(arena: Allocator, value: ?[]const u8, old: ?[]const u8) Allocator.Error!?[]const u8 {
    const v = value orelse return null;
    if (old) |o| if (std.mem.eql(u8, o, v)) return o;
    return try arena.dupe(u8, v);
}

/// `url`'s scheme and authority, such as `https://mcp.slack.com`.
fn origin(url: []const u8) []const u8 {
    const authority = (std.mem.find(u8, url, "://") orelse return url) + 3;
    return url[0 .. std.mem.findScalarPos(u8, url, authority, '/') orelse url.len];
}

fn heldFor(c: *const McpServerConfig) ?Held {
    if (!c.enabled) return .disabled;
    if (c.source == .workspace) if (c.workspace_admission) |admission| switch (admission) {
        .pending => return .waiting_for_approval,
        .rejected => return .rejected,
        .approved => {},
    };
    if (c.transport == .sse or c.acp_server_id != null) return .unsupported;
    return null;
}

/// What a stdio server gets of spark's environment, as the MCP SDKs give it:
/// these, then its config's `env`. Never spark's credentials or the rest.
const inherited_names = [_][]const u8{ "HOME", "LOGNAME", "PATH", "SHELL", "TERM", "USER" };

/// The engine's transport, or null when the server must be held back (and
/// `s` says why).
fn transportFor(
    arena: Allocator,
    c: *const McpServerConfig,
    inherited: *const std.process.Environ.Map,
    s: *Server,
) Allocator.Error!?mcp.engine.Transport {
    switch (c.transport) {
        .stdio => {
            const argv = try arena.alloc([]const u8, 1 + c.args.len);
            argv[0] = c.command orelse return null;
            @memcpy(argv[1..], c.args);
            // An editor's project server starts in its project.
            const cwd = if (c.cwd) |dir| try arena.dupe(u8, dir) else null;
            const map = try arena.create(std.process.Environ.Map);
            map.* = .init(arena);
            for (inherited_names) |name| if (inherited.get(name)) |value| {
                // An exported shell function isn't passed on.
                if (!std.mem.startsWith(u8, value, "()")) try map.put(name, value);
            };
            for (c.env) |e| try map.put(e.key, e.value);
            return .{ .stdio = .{ .argv = argv, .environ_map = map, .cwd = cwd } };
        },
        .http => {
            var headers: std.ArrayList(std.http.Header) = .empty;
            for (c.headers) |h| try headers.append(arena, .{ .name = h.name, .value = h.value });
            for (c.header_env) |h| {
                const value = inherited.get(h.env) orelse return hold(arena, s, .missing_env, h.env);
                try headers.append(arena, .{ .name = h.name, .value = value });
                if (!mcp.http_headers.sendable(headers.items[headers.items.len - 1 ..])) return hold(arena, s, .invalid_env, h.env);
            }
            if (c.bearer_token_env) |variable| {
                const token = inherited.get(variable) orelse return hold(arena, s, .missing_env, variable);
                try headers.append(arena, .{ .name = "Authorization", .value = try arena.print("Bearer {s}", .{token}) });
                if (!mcp.http_headers.sendable(headers.items[headers.items.len - 1 ..])) return hold(arena, s, .invalid_env, variable);
            }
            return .{ .http = .{ .url = s.url orelse return null, .headers = headers.items } };
        },
        .sse => return null,
    }
}

fn hold(arena: Allocator, s: *Server, why: Held, variable: []const u8) Allocator.Error!?mcp.engine.Transport {
    s.held = why;
    s.missing = try arena.dupe(u8, variable);
    return null;
}

const testing = std.testing;

fn envVar(comptime key: []const u8, comptime value: []const u8) mcp_contract.McpEnvVar {
    return .{ .key = @constCast(key), .value = @constCast(value) };
}

test "an approved .mcp.json server keeps its login under its own workspace, never the profile's" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    const configs = [_]McpServerConfig{
        .{ .name = "linear", .transport = .http, .url = "https://mcp.linear.app/mcp" },
        .{ .name = "team", .transport = .http, .url = "https://mcp.linear.app/mcp", .source = .workspace, .scope = .workspace, .workspace_admission = .approved },
    };
    const r = try resolve(arena, &configs, &inherited, "/Users/example/repo");
    try testing.expectEqual(@as(?[]const u8, null), r.servers[0].workspace);
    try testing.expectEqual(@as(?[]const u8, null), r.servers[0].credentialKey().workspace);
    try testing.expectEqualStrings("/Users/example/repo", r.servers[1].workspace.?);
    try testing.expectEqualStrings("/Users/example/repo", r.servers[1].credentialKey().workspace.?);
}
