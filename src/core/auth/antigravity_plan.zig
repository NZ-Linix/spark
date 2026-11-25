//! Signs in to Google with the OAuth client the Antigravity app uses, so an
//! Antigravity (Google AI) subscription serves Spark's own prompts and tools
//! through Google's Cloud Code Assist API. The account's tokens, its Cloud
//! Code project and the Antigravity release it identifies as stay in the
//! private `antigravity-plan` folder of the Spark profile.
const std = @import("std");
const oauth = @import("oauth.zig");
const browser = @import("browser_callback.zig");
const http = @import("oauth_transport.zig");
const io = @import("../shared/io.zig");
const host = @import("../hosts/host.zig");
const secret = @import("secret.zig");
const store = @import("plan_store.zig");
const Allocator = std.mem.Allocator;

const kind: store.Kind = .antigravity;
pub const endpoint = "https://daily-cloudcode-pa.googleapis.com";
/// Antigravity's desktop OAuth client. Google treats a desktop client's
/// secret as public; the PKCE verifier protects the exchange.
const client_id = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com";
const client_secret = "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";
const authorize_url = "https://accounts.google.com/o/oauth2/v2/auth";
const token_url = "https://oauth2.googleapis.com/token";
const revoke_url = "https://oauth2.googleapis.com/revoke";
const userinfo_url = "https://www.googleapis.com/oauth2/v1/userinfo?alt=json";
const manifest_url = "https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest/latest-arm64-mac.yml";
const scopes = "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/cclog https://www.googleapis.com/auth/experimentsandconfigs";
const usage_scope = "https://www.googleapis.com/auth/cloud-platform";
const redirect_path = "/oauth-callback";
/// The release identified as when the update manifest can't be read. Cloud
/// Code serves its newest models only to recent releases.
pub const fallback_version = "2.35.1";
/// The project Antigravity itself falls back to for accounts Cloud Code
/// doesn't assign one.
const default_project = "rising-fact-p41fc";

const Account = struct {
    subject: []const u8,
    email: []const u8 = "",
    scope: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    expires_at_ms: i64,
    project: []const u8,
    version: []const u8 = fallback_version,
};

/// What a request needs besides the token: the account's Cloud Code project
/// and the Antigravity release to identify as. Owned; free with `deinit`.
pub const Session = struct {
    token: []u8,
    project: []u8,
    user_agent: []u8,

    pub fn deinit(self: *Session, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.token);
        alloc.free(self.project);
        alloc.free(self.user_agent);
        self.* = undefined;
    }
};

/// The User-Agent of the Antigravity release `version`. Caller owns it.
pub fn userAgent(alloc: Allocator, version: []const u8) ![]u8 {
    return alloc.print("antigravity/hub/{s} (aidev_client; os_type=darwin; arch=arm64)", .{version});
}

fn validVersion(version: []const u8) bool {
    if (version.len == 0 or version.len > 20) return false;
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, version, '.');
    while (it.next()) |part| {
        parts += 1;
        if (part.len == 0 or part.len > 6) return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return parts == 3;
}

fn validProject(project: []const u8) bool {
    if (project.len == 0 or project.len > 128) return false;
    for (project) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.' and c != ':') return false;
    return true;
}

fn valid(account: Account) bool {
    return store.validToken(account.access_token) and store.validToken(account.refresh_token) and account.subject.len != 0 and validProject(account.project) and validVersion(account.version);
}

fn load(alloc: Allocator, dir: io.VerifiedDir, name: []const u8) !store.Stored(Account) {
    const saved = try store.load(Account, alloc, dir, name);
    errdefer saved.deinit(alloc);
    if (!valid(saved.parsed.value)) return error.InvalidPlanAccount;
    return saved;
}

const Callback = struct { code: []u8 };
const Attempt = struct { state: []const u8 };

fn takeCallback(raw: ?*anyopaque, alloc: Allocator, target: []const u8) browser.ParseResult(Callback) {
    const attempt: *const Attempt = @ptrCast(@alignCast(raw.?));
    const query = if (std.mem.startsWith(u8, target, redirect_path ++ "?")) target[redirect_path.len + 1 ..] else return .unrelated;
    const state = oauth.queryValueNonEmptyAlloc(alloc, query, "state") catch return .unrelated;
    defer alloc.free(state);
    if (!std.mem.eql(u8, state, attempt.state)) return .unrelated;
    const denial: ?[]u8 = oauth.queryValueAlloc(alloc, query, "error") catch |err| switch (err) {
        error.MissingQueryParameter => null,
        else => return .{ .failed = err },
    };
    if (denial) |value| {
        alloc.free(value);
        return .{ .failed = error.PlanAuthorizationDenied };
    }
    const code = oauth.queryValueNonEmptyAlloc(alloc, query, "code") catch |err| return .{ .failed = err };
    return .{ .accepted = .{ .code = code } };
}

fn authorization(alloc: Allocator, redirect: []const u8, state: []const u8, challenge: []const u8) ![]u8 {
    const query = try store.form(alloc, &.{
        .{ "client_id", client_id },      .{ "response_type", "code" },
        .{ "redirect_uri", redirect },    .{ "scope", scopes },
        .{ "code_challenge", challenge }, .{ "code_challenge_method", "S256" },
        .{ "state", state },              .{ "access_type", "offline" },
        .{ "prompt", "consent" },
    });
    defer alloc.free(query);
    return alloc.print(authorize_url ++ "?{s}", .{query});
}

const Token = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    token_type: []const u8 = "Bearer",
    expires_in: i64,
    scope: ?[]const u8 = null,
};

fn postToken(alloc: Allocator, transport: http.Provider, fields: []const store.Pair, renewal: bool) !http.Response {
    const payload = try store.form(alloc, fields);
    defer secret.zeroAndFree(alloc, payload);
    var response = try transport.execute(alloc, .{ .method = .post_form, .url = token_url, .payload = payload, .outlives_cancel = renewal });
    errdefer response.deinit(alloc);
    if (response.disposition != .accepted) return if (response.status == 400 or response.status == 401) error.PlanSignInRequired else error.PlanTokenRequestFailed;
    return response;
}

fn parseToken(alloc: Allocator, bytes: []const u8) !std.json.Parsed(Token) {
    var parsed = std.json.parseFromSlice(Token, alloc, bytes, .{ .ignore_unknown_fields = true }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidPlanToken,
    };
    errdefer parsed.deinit();
    const token = parsed.value;
    if (!std.ascii.eqlIgnoreCase(token.token_type, "Bearer") or !store.validToken(token.access_token)) return error.InvalidPlanToken;
    if (token.refresh_token) |refresh| if (!store.validToken(refresh)) return error.InvalidPlanToken;
    return parsed;
}

/// Opens the browser at Google's consent page, waits up to five minutes for
/// the redirect, finds the account's Cloud Code project, and saves the
/// account under `id`. Returns the account's model list as Cloud Code sent
/// it; caller owns it.
pub fn signIn(alloc: Allocator, transport: http.Provider, opener: host.UrlOpener, id: []const u8, reconnect: bool, cancel: *std.atomic.Value(bool)) ![]u8 {
    const name = try store.filename(kind, id);
    var dir = try store.open(alloc, kind, true);
    defer dir.close();
    const saved = if (reconnect) try load(alloc, dir, name.slice()) else null;
    defer if (saved) |old| old.deinit(alloc);
    const state = try oauth.randomUrlSafeSecret(alloc);
    defer secret.zeroAndFree(alloc, state);
    var pending: Attempt = .{ .state = state };
    const verifier = try oauth.randomUrlSafeSecret(alloc);
    defer secret.zeroAndFree(alloc, verifier);
    const challenge = try oauth.pkceChallengeAlloc(alloc, verifier);
    defer alloc.free(challenge);
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io.getIo(), .{});
    defer listener.deinit(io.getIo());
    // A desktop client may redirect to any loopback port.
    const redirect = try alloc.print("http://127.0.0.1:{d}" ++ redirect_path, .{listener.socket.address.getPort()});
    defer alloc.free(redirect);
    const url = try authorization(alloc, redirect, state, challenge);
    defer secret.zeroAndFree(alloc, url);
    if (!try opener.open(alloc, url)) return error.PlanBrowserUnavailable;
    const until = io.awakeMilliTimestamp() + 5 * 60 * 1000;
    while (io.awakeMilliTimestamp() < until) {
        var received = (try browser.await(Callback, takeCallback, alloc, &listener, &pending, cancel, null)) orelse continue;
        defer received.deinit();
        defer secret.zeroAndFree(alloc, received.callback.code);
        const result = finishSignIn(alloc, transport, &dir, name.slice(), received.callback.code, verifier, redirect, if (saved) |old| old.parsed.value.subject else null, cancel);
        received.respond(if (result) |_| .ok else |_| .failed) catch {};
        return result;
    }
    return error.PlanSignInTimedOut;
}

fn finishSignIn(alloc: Allocator, transport: http.Provider, dir: *io.VerifiedDir, name: []const u8, code: []const u8, verifier: []const u8, redirect: []const u8, prior_subject: ?[]const u8, cancel: *const std.atomic.Value(bool)) ![]u8 {
    var response = try postToken(alloc, transport, &.{
        .{ "client_id", client_id },   .{ "client_secret", client_secret },
        .{ "code", code },             .{ "grant_type", "authorization_code" },
        .{ "redirect_uri", redirect }, .{ "code_verifier", verifier },
    }, false);
    defer response.deinit(alloc);
    const parsed = try parseToken(alloc, response.body);
    defer parsed.deinit();
    const token = parsed.value;
    const scope = token.scope orelse "";
    if (oauth.missingGrantedScope(usage_scope, scope) != null) return error.PlanPermissionMissing;
    const refresh = token.refresh_token orelse return error.InvalidPlanToken;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const who = try identity(a, transport, token.access_token);
    if (prior_subject) |prior| if (!std.mem.eql(u8, who.id, prior)) return error.PlanAccountChanged;
    const version = latestVersion(a, transport);
    const agent = try userAgent(a, version);
    const project = try findProject(a, transport, token.access_token, agent, version, cancel);
    const models = try fetchModels(alloc, transport, token.access_token, project, agent, null);
    errdefer alloc.free(models);
    if (cancel.load(.acquire)) return error.Cancelled;
    const account: Account = .{
        .subject = who.id,
        .email = who.email orelse "",
        .scope = scope,
        .access_token = token.access_token,
        .refresh_token = refresh,
        .expires_at_ms = try oauth.expiryTimestampMs(io.milliTimestamp(), token.expires_in),
        .project = project,
        .version = version,
    };
    var held = try store.lock(dir);
    defer held.release();
    if (prior_subject != null) {
        const latest = try load(alloc, dir.*, name);
        defer latest.deinit(alloc);
        if (!std.mem.eql(u8, latest.parsed.value.subject, who.id)) return error.PlanAccountChanged;
    }
    try store.save(alloc, dir, name, account);
    return models;
}

const Identity = struct { id: []const u8, email: ?[]const u8 = null };

fn identity(arena: Allocator, transport: http.Provider, token: []const u8) !Identity {
    const auth = try arena.print("Bearer {s}", .{token});
    const result = try transport.execute(arena, .{ .method = .get, .url = userinfo_url, .authorization = auth });
    if (result.disposition != .accepted) return error.InvalidPlanIdentity;
    const who = std.json.parseFromSliceLeaky(Identity, arena, result.body, .{ .ignore_unknown_fields = true }) catch return error.InvalidPlanIdentity;
    if (who.id.len == 0) return error.InvalidPlanIdentity;
    return who;
}

/// The current Antigravity release from its update manifest, or the
/// fallback when the manifest can't be read or names an older release.
fn latestVersion(arena: Allocator, transport: http.Provider) []const u8 {
    const result = transport.execute(arena, .{ .method = .get, .url = manifest_url, .user_agent = "electron-builder", .max_response_bytes = 16 * 1024 }) catch return fallback_version;
    if (result.disposition != .accepted) return fallback_version;
    return manifestVersion(result.body) orelse fallback_version;
}

fn manifestVersion(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, "version:")) continue;
        const value = std.mem.trim(u8, std.mem.trim(u8, line["version:".len..], " \t"), "'\"");
        if (!validVersion(value) or newer(fallback_version, value)) return null;
        return value;
    }
    return null;
}

/// Whether release `a` is newer than `b`; both are valid versions.
fn newer(a: []const u8, b: []const u8) bool {
    var left = std.mem.splitScalar(u8, a, '.');
    var right = std.mem.splitScalar(u8, b, '.');
    for (0..3) |_| {
        const x = std.fmt.parseInt(u32, left.next().?, 10) catch return false;
        const y = std.fmt.parseInt(u32, right.next().?, 10) catch return false;
        if (x != y) return x > y;
    }
    return false;
}

fn post(arena: Allocator, transport: http.Provider, method: []const u8, token: []const u8, agent: []const u8, body: []const u8, cancel: ?*std.atomic.Value(bool)) !http.Response {
    const auth = try arena.print("Bearer {s}", .{token});
    const url = try arena.print(endpoint ++ "/v1internal:{s}", .{method});
    return transport.execute(arena, .{ .method = .post_json, .url = url, .payload = body, .authorization = auth, .user_agent = agent, .cancel_flag = cancel, .max_response_bytes = 4 * 1024 * 1024 });
}

const LoadResponse = struct {
    cloudaicompanionProject: ?std.json.Value = null,
    allowedTiers: ?[]const struct { id: ?[]const u8 = null, isDefault: ?bool = null } = null,
    currentTier: ?struct { id: ?[]const u8 = null } = null,
};

fn projectOf(value: ?std.json.Value) ?[]const u8 {
    const project = value orelse return null;
    const id = switch (project) {
        .string => |text| text,
        .object => |fields| if (fields.get("id")) |inner| (if (inner == .string) inner.string else return null) else return null,
        else => return null,
    };
    const trimmed = std.mem.trim(u8, id, " ");
    return if (validProject(trimmed)) trimmed else null;
}

/// The account's Cloud Code project: the one `loadCodeAssist` names, else one
/// `onboardUser` makes for its default tier, else Antigravity's own fallback.
fn findProject(arena: Allocator, transport: http.Provider, token: []const u8, agent: []const u8, version: []const u8, cancel: *const std.atomic.Value(bool)) ![]const u8 {
    const loaded = try post(arena, transport, "loadCodeAssist", token, agent, "{\"metadata\":{\"ideType\":\"ANTIGRAVITY\"}}", null);
    if (loaded.disposition != .accepted) return if (loaded.status == 401) error.PlanSignInRequired else error.PlanProjectUnavailable;
    const payload = std.json.parseFromSliceLeaky(LoadResponse, arena, loaded.body, .{ .ignore_unknown_fields = true }) catch return error.PlanProjectUnavailable;
    if (projectOf(payload.cloudaicompanionProject)) |project| return project;
    var tier: []const u8 = "free-tier";
    if (payload.currentTier) |current| if (current.id) |id| {
        tier = id;
    };
    if (payload.allowedTiers) |tiers| {
        if (tiers.len != 0) if (tiers[0].id) |id| {
            tier = id;
        };
        for (tiers) |candidate| if (candidate.isDefault orelse false) if (candidate.id) |id| {
            tier = id;
            break;
        };
    }
    const body = try std.json.Stringify.valueAlloc(arena, .{ .tier_id = tier, .metadata = .{ .ide_type = "ANTIGRAVITY", .ide_version = version, .ide_name = "antigravity" } }, .{});
    for (0..10) |attempt| {
        if (cancel.load(.acquire)) return error.Cancelled;
        const onboarded = post(arena, transport, "onboardUser", token, agent, body, null) catch break;
        if (onboarded.disposition != .accepted) break;
        const Operation = struct { done: ?bool = null, response: ?struct { cloudaicompanionProject: ?std.json.Value = null } = null };
        const operation = std.json.parseFromSliceLeaky(Operation, arena, onboarded.body, .{ .ignore_unknown_fields = true }) catch break;
        if (operation.done orelse false) {
            if (operation.response) |done| if (projectOf(done.cloudaicompanionProject)) |project| return project;
            break;
        }
        if (attempt != 9) io.sleep(2 * std.time.ns_per_s);
    }
    return default_project;
}

/// The account's model list, `fetchAvailableModels`, as Cloud Code sent it.
/// Caller owns it.
pub fn fetchModels(alloc: Allocator, transport: http.Provider, token: []const u8, project: []const u8, agent: []const u8, cancel: ?*std.atomic.Value(bool)) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const body = try std.json.Stringify.valueAlloc(arena.allocator(), .{ .project = project }, .{});
    const result = try post(arena.allocator(), transport, "fetchAvailableModels", token, agent, body, cancel);
    if (result.disposition != .accepted) return if (result.status == 401) error.PlanSignInRequired else error.PlanModelsUnavailable;
    return alloc.dupe(u8, result.body);
}

/// The account's model list with its saved token, project and release.
pub fn fetchAccountModels(alloc: Allocator, transport: http.Provider, id: []const u8, cancel: ?*std.atomic.Value(bool)) ![]u8 {
    var current = try open(alloc, transport, id);
    defer current.deinit(alloc);
    return fetchModels(alloc, transport, current.token, current.project, current.user_agent, cancel);
}

/// A current token for the account, renewed when it is about to expire, with
/// its project and User-Agent.
pub fn open(alloc: Allocator, transport: http.Provider, id: []const u8) !Session {
    const name = try store.filename(kind, id);
    var dir = store.open(alloc, kind, false) catch |err| return if (err == error.FileNotFound) error.PlanSignInRequired else err;
    defer dir.close();
    return readOrRefresh(alloc, transport, &dir, name.slice());
}

fn sessionOf(alloc: Allocator, account: Account) !Session {
    const token = try alloc.dupe(u8, account.access_token);
    errdefer secret.zeroAndFree(alloc, token);
    const project = try alloc.dupe(u8, account.project);
    errdefer alloc.free(project);
    return .{ .token = token, .project = project, .user_agent = try userAgent(alloc, account.version) };
}

fn readOrRefresh(alloc: Allocator, transport: http.Provider, dir: *io.VerifiedDir, name: []const u8) !Session {
    {
        const saved = load(alloc, dir.*, name) catch |err| return if (err == error.FileNotFound) error.PlanSignInRequired else err;
        defer saved.deinit(alloc);
        var account = saved.parsed.value;
        if (account.expires_at_ms > io.milliTimestamp() + 60_000) return sessionOf(alloc, account);
        if (try store.remoteToken(alloc, transport, name)) |token| {
            defer secret.zeroAndFree(alloc, token);
            account.access_token = token;
            return sessionOf(alloc, account);
        }
    }
    var held = try store.lock(dir);
    defer held.release();
    const latest = load(alloc, dir.*, name) catch |err| return if (err == error.FileNotFound) error.PlanSignInRequired else err;
    defer latest.deinit(alloc);
    var account = latest.parsed.value;
    if (account.expires_at_ms > io.milliTimestamp() + 60_000) return sessionOf(alloc, account);
    var response = try postToken(alloc, transport, &.{
        .{ "client_id", client_id },        .{ "client_secret", client_secret },
        .{ "grant_type", "refresh_token" }, .{ "refresh_token", account.refresh_token },
    }, true);
    defer response.deinit(alloc);
    const parsed = try parseToken(alloc, response.body);
    defer parsed.deinit();
    account.access_token = parsed.value.access_token;
    if (parsed.value.refresh_token) |refresh| account.refresh_token = refresh;
    if (parsed.value.scope) |scope| account.scope = scope;
    account.expires_at_ms = try oauth.expiryTimestampMs(io.milliTimestamp(), parsed.value.expires_in);
    try store.save(alloc, dir, name, account);
    return sessionOf(alloc, account);
}

/// Revokes the refresh token at Google and deletes the saved account.
/// Returns whether Google confirmed the revocation.
pub fn remove(alloc: Allocator, transport: http.Provider, id: []const u8) !bool {
    const name = try store.filename(kind, id);
    var dir = store.open(alloc, kind, false) catch |err| return if (err == error.FileNotFound) false else err;
    defer dir.close();
    var held = try store.lock(&dir);
    defer held.release();
    const saved = load(alloc, dir, name.slice()) catch |err| return if (err == error.FileNotFound) false else err;
    defer saved.deinit(alloc);
    const revoked = blk: {
        const payload = store.form(alloc, &.{.{ "token", saved.parsed.value.refresh_token }}) catch break :blk false;
        defer secret.zeroAndFree(alloc, payload);
        var result = transport.execute(alloc, .{ .method = .post_form, .url = revoke_url, .payload = payload }) catch break :blk false;
        defer result.deinit(alloc);
        break :blk result.status == 200;
    };
    try store.delete(&dir, name.slice());
    return revoked;
}

test "Antigravity callback checks state and reports denied consent" {
    const a = std.testing.allocator;
    var pending: Attempt = .{ .state = "expected" };
    try std.testing.expect(takeCallback(&pending, a, "/oauth-callback?state=wrong&code=code") == .unrelated);
    try std.testing.expectEqual(error.PlanAuthorizationDenied, takeCallback(&pending, a, "/oauth-callback?state=expected&error=access_denied").failed);
    const callback = takeCallback(&pending, a, "/oauth-callback?state=expected&code=4%2F0A").accepted;
    defer a.free(callback.code);
    try std.testing.expectEqualStrings("4/0A", callback.code);
}

test "Antigravity reads its release from the update manifest, never an older one" {
    try std.testing.expectEqualStrings("2.40.0", manifestVersion("version: 2.40.0\nfiles:\n  - url: x\n").?);
    try std.testing.expectEqualStrings("3.0.1", manifestVersion("version: '3.0.1'\r\n").?);
    try std.testing.expect(manifestVersion("version: 2.1.0\n") == null);
    try std.testing.expect(manifestVersion("version: 2.40.0-beta\n") == null);
    try std.testing.expect(manifestVersion("files: []\n") == null);
    const a = std.testing.allocator;
    const agent = try userAgent(a, "2.35.1");
    defer a.free(agent);
    try std.testing.expectEqualStrings("antigravity/hub/2.35.1 (aidev_client; os_type=darwin; arch=arm64)", agent);
}

const TestGoogle = struct {
    calls: usize = 0,
    assigned_project: bool = true,

    fn execute(raw: ?*anyopaque, alloc: Allocator, request: http.Request) !http.Response {
        const self: *TestGoogle = @ptrCast(@alignCast(raw.?));
        const expect = std.testing.expectEqualStrings;
        const step = self.calls;
        self.calls += 1;
        const agent = "antigravity/hub/2.99.0 (aidev_client; os_type=darwin; arch=arm64)";
        const body: []u8 = switch (step) {
            0 => blk: {
                try expect(token_url, request.url);
                try std.testing.expect(std.mem.find(u8, request.payload.?, "client_secret=GOCSPX-") != null);
                try std.testing.expect(std.mem.find(u8, request.payload.?, "code_verifier=pkce-verifier") != null);
                break :blk try std.json.Stringify.valueAlloc(alloc, .{ .access_token = "ya29.one", .refresh_token = "1//refresh", .expires_in = 1, .token_type = "Bearer", .scope = scopes }, .{});
            },
            1 => blk: {
                try expect(userinfo_url, request.url);
                try expect("Bearer ya29.one", request.authorization.?);
                break :blk try alloc.dupe(u8, "{\"id\":\"1234\",\"email\":\"me@gmail.com\"}");
            },
            2 => blk: {
                try expect(manifest_url, request.url);
                break :blk try alloc.dupe(u8, "version: 2.99.0\nfiles: []\n");
            },
            3 => blk: {
                try expect(endpoint ++ "/v1internal:loadCodeAssist", request.url);
                try expect(agent, request.user_agent.?);
                break :blk try alloc.dupe(u8, if (self.assigned_project) "{\"cloudaicompanionProject\":\"proj-1\"}" else "{\"allowedTiers\":[{\"id\":\"legacy\"},{\"id\":\"free-tier\",\"isDefault\":true}]}");
            },
            4 => blk: {
                if (!self.assigned_project) {
                    try expect(endpoint ++ "/v1internal:onboardUser", request.url);
                    try std.testing.expect(std.mem.find(u8, request.payload.?, "\"tier_id\":\"free-tier\"") != null);
                    break :blk try alloc.dupe(u8, "{\"done\":true,\"response\":{\"cloudaicompanionProject\":{\"id\":\"proj-2\"}}}");
                }
                try expect(endpoint ++ "/v1internal:fetchAvailableModels", request.url);
                try expect("{\"project\":\"proj-1\"}", request.payload.?);
                break :blk try alloc.dupe(u8, "{\"models\":{\"gemini-example\":{\"displayName\":\"Gemini Example\"}}}");
            },
            5 => blk: {
                if (!self.assigned_project) {
                    try expect("{\"project\":\"proj-2\"}", request.payload.?);
                    break :blk try alloc.dupe(u8, "{\"models\":{}}");
                }
                try expect(token_url, request.url);
                try std.testing.expect(request.outlives_cancel);
                try std.testing.expect(std.mem.find(u8, request.payload.?, "grant_type=refresh_token") != null);
                break :blk try alloc.dupe(u8, "{\"access_token\":\"ya29.two\",\"expires_in\":3600,\"token_type\":\"Bearer\"}");
            },
            else => return error.UnexpectedRequest,
        };
        return .{ .disposition = .accepted, .body = body, .status = 200 };
    }
};

test "Antigravity sign-in finds the Cloud Code project and keeps a renewable account" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir = try io.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "antigravity-plan");
    defer dir.close();
    var server: TestGoogle = .{};
    const transport: http.Provider = .{ .execute_fn = TestGoogle.execute, .context = &server };
    var cancel: std.atomic.Value(bool) = .init(false);
    const models = try finishSignIn(a, transport, &dir, "account.json", "code", "pkce-verifier", "http://127.0.0.1:1/oauth-callback", null, &cancel);
    defer a.free(models);
    try std.testing.expect(std.mem.find(u8, models, "gemini-example") != null);
    var current = try readOrRefresh(a, transport, &dir, "account.json");
    defer current.deinit(a);
    try std.testing.expectEqualStrings("ya29.two", current.token);
    try std.testing.expectEqualStrings("proj-1", current.project);
    try std.testing.expectEqualStrings("antigravity/hub/2.99.0 (aidev_client; os_type=darwin; arch=arm64)", current.user_agent);
    const saved = try load(a, dir, "account.json");
    defer saved.deinit(a);
    try std.testing.expectEqualStrings("1//refresh", saved.parsed.value.refresh_token);
    try std.testing.expectEqualStrings("me@gmail.com", saved.parsed.value.email);
    try std.testing.expectEqual(@as(usize, 6), server.calls);
    // An account without a project gets one for its default tier.
    server = .{ .assigned_project = false };
    const fresh = try finishSignIn(a, transport, &dir, "second.json", "code", "pkce-verifier", "http://127.0.0.1:1/oauth-callback", null, &cancel);
    defer a.free(fresh);
    const second = try load(a, dir, "second.json");
    defer second.deinit(a);
    try std.testing.expectEqualStrings("proj-2", second.parsed.value.project);
    server.calls = 0;
    try std.testing.expectError(error.PlanAccountChanged, finishSignIn(a, transport, &dir, "second.json", "code", "pkce-verifier", "http://127.0.0.1:1/oauth-callback", "someone-else", &cancel));
}
