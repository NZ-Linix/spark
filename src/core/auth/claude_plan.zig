//! Signs in to a Claude subscription (Pro or Max) with the OAuth client
//! Claude Code uses, and keeps the account's tokens in the private
//! `claude-plan` folder of the Spark profile. Requests then go straight to
//! the Messages API with Spark's own prompt and tools; Claude Code itself is
//! never run.
const std = @import("std");
const oauth = @import("oauth.zig");
const browser = @import("browser_callback.zig");
const http = @import("oauth_transport.zig");
const io = @import("../shared/io.zig");
const host = @import("../hosts/host.zig");
const secret = @import("secret.zig");
const store = @import("plan_store.zig");
const Allocator = std.mem.Allocator;

const kind: store.Kind = .claude;
pub const api = "https://api.anthropic.com/v1";
pub const client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const authorize_url = "https://claude.com/cai/oauth/authorize";
const token_url = "https://platform.claude.com/v1/oauth/token";
/// The scopes Claude Code asks for when it signs in with a claude.ai account.
const scopes = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";
/// A refresh asks again for every scope but the API-key one, as Claude Code does.
const refresh_scopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";
const usage_scope = "user:inference";
const redirect_path = "/callback";

/// The Claude Code release whose client identity requests carry. The API
/// accepts subscription tokens only from that client.
pub const cli_version = "2.1.332";
pub const user_agent = "claude-cli/" ++ cli_version ++ " (external, cli)";
pub const beta_header = "claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14";
/// The one system block a subscription token must start with. Spark's own
/// prompt follows it unchanged.
pub const identity = "You are Claude Code, Anthropic's official CLI for Claude.";
const fingerprint_salt = "59cf53e54c78";

/// Headers every API request made with an account's token carries.
pub const api_headers = [_]std.http.Header{
    .{ .name = "anthropic-version", .value = "2023-06-01" },
    .{ .name = "anthropic-beta", .value = beta_header },
    .{ .name = "x-app", .value = "cli" },
};

/// The billing marker Claude Code puts first in its system prompt: its
/// version, with three hex digits derived from the first user message.
/// Caller owns the result.
pub fn billingHeader(alloc: Allocator, first_user_text: []const u8) ![]u8 {
    var picked: [3]u8 = undefined;
    for ([_]usize{ 4, 7, 20 }, 0..) |at, i| picked[i] = if (at < first_user_text.len) first_user_text[at] else '0';
    var digest: [32]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(fingerprint_salt);
    hash.update(&picked);
    hash.update(cli_version);
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.print("x-anthropic-billing-header: cc_version={s}.{s}; cc_entrypoint=cli; cch=00000;", .{ cli_version, hex[0..3] });
}

const Account = struct {
    subject: []const u8,
    email: []const u8 = "",
    scope: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    expires_at_ms: i64,
};

fn valid(account: Account) bool {
    return store.validToken(account.access_token) and store.validToken(account.refresh_token) and account.subject.len != 0;
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
        .{ "code", "true" },                  .{ "client_id", client_id },
        .{ "response_type", "code" },         .{ "redirect_uri", redirect },
        .{ "scope", scopes },                 .{ "code_challenge", challenge },
        .{ "code_challenge_method", "S256" }, .{ "state", state },
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
    account: ?struct { uuid: []const u8, email_address: ?[]const u8 = null } = null,
};

fn postToken(alloc: Allocator, transport: http.Provider, payload: []const u8, renewal: bool) !http.Response {
    var response = try transport.execute(alloc, .{ .method = .post_json, .url = token_url, .payload = payload, .outlives_cancel = renewal, .user_agent = user_agent });
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

fn toAccount(token: Token, subject: []const u8, email: []const u8, previous: ?Account) !Account {
    const scope = token.scope orelse if (previous) |old| old.scope else "";
    if (oauth.missingGrantedScope(usage_scope, scope) != null) return error.PlanPermissionMissing;
    return .{
        .subject = subject,
        .email = email,
        .scope = scope,
        .access_token = token.access_token,
        .refresh_token = token.refresh_token orelse if (previous) |old| old.refresh_token else return error.InvalidPlanToken,
        .expires_at_ms = try oauth.expiryTimestampMs(io.milliTimestamp(), token.expires_in),
    };
}

/// Opens the browser at Claude's consent page, waits up to five minutes for
/// the redirect, and saves the account under `id`. Returns the account's model
/// list as the API sent it; caller owns it. `reconnect` refuses a different
/// Claude account than the one saved.
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
    // Claude's client allows `localhost` redirects, as Claude Code sends them.
    const redirect = try alloc.print("http://localhost:{d}" ++ redirect_path, .{listener.socket.address.getPort()});
    defer alloc.free(redirect);
    const url = try authorization(alloc, redirect, state, challenge);
    defer secret.zeroAndFree(alloc, url);
    if (!try opener.open(alloc, url)) return error.PlanBrowserUnavailable;
    const until = io.awakeMilliTimestamp() + 5 * 60 * 1000;
    while (io.awakeMilliTimestamp() < until) {
        var received = (try browser.await(Callback, takeCallback, alloc, &listener, &pending, cancel, null)) orelse continue;
        defer received.deinit();
        defer secret.zeroAndFree(alloc, received.callback.code);
        const result = finishSignIn(alloc, transport, &dir, name.slice(), received.callback.code, verifier, redirect, state, if (saved) |old| old.parsed.value.subject else null, cancel);
        received.respond(if (result) |_| .ok else |_| .failed) catch {};
        return result;
    }
    return error.PlanSignInTimedOut;
}

fn finishSignIn(alloc: Allocator, transport: http.Provider, dir: *io.VerifiedDir, name: []const u8, returned_code: []const u8, verifier: []const u8, redirect: []const u8, state: []const u8, prior_subject: ?[]const u8, cancel: *const std.atomic.Value(bool)) ![]u8 {
    // Claude's page shows `code#state` when it can't redirect; the part
    // before `#` is the code either way.
    const code = if (std.mem.findScalar(u8, returned_code, '#')) |at| returned_code[0..at] else returned_code;
    const payload = try std.json.Stringify.valueAlloc(alloc, .{
        .grant_type = "authorization_code",
        .code = code,
        .redirect_uri = redirect,
        .client_id = client_id,
        .code_verifier = verifier,
        .state = state,
    }, .{});
    defer secret.zeroAndFree(alloc, payload);
    var response = try postToken(alloc, transport, payload, false);
    defer response.deinit(alloc);
    const parsed = try parseToken(alloc, response.body);
    defer parsed.deinit();
    const who = parsed.value.account orelse return error.InvalidPlanIdentity;
    if (who.uuid.len == 0) return error.InvalidPlanIdentity;
    if (prior_subject) |prior| if (!std.mem.eql(u8, who.uuid, prior)) return error.PlanAccountChanged;
    const account = try toAccount(parsed.value, who.uuid, who.email_address orelse "", null);
    const models = try fetchModels(alloc, transport, account.access_token, null);
    errdefer alloc.free(models);
    if (cancel.load(.acquire)) return error.Cancelled;
    var held = try store.lock(dir);
    defer held.release();
    if (prior_subject != null) {
        const latest = try load(alloc, dir.*, name);
        defer latest.deinit(alloc);
        if (!std.mem.eql(u8, latest.parsed.value.subject, who.uuid)) return error.PlanAccountChanged;
    }
    try store.save(alloc, dir, name, account);
    return models;
}

/// The account's model list, `GET /v1/models`, as the API sent it. Caller owns it.
pub fn fetchModels(alloc: Allocator, transport: http.Provider, token: []const u8, cancel: ?*std.atomic.Value(bool)) ![]u8 {
    const auth = try alloc.print("Bearer {s}", .{token});
    defer secret.zeroAndFree(alloc, auth);
    var result = try transport.execute(alloc, .{
        .method = .get,
        .url = api ++ "/models?limit=1000",
        .authorization = auth,
        .cancel_flag = cancel,
        .max_response_bytes = 4 * 1024 * 1024,
        .user_agent = user_agent,
        .extra_headers = &api_headers,
    });
    defer result.deinit(alloc);
    if (result.disposition != .accepted) return if (result.status == 401) error.PlanSignInRequired else error.PlanModelsUnavailable;
    return result.takeBody();
}

/// A current access token for the account, renewed when it is about to
/// expire. Caller owns it and wipes it.
pub fn accessToken(alloc: Allocator, transport: http.Provider, id: []const u8) ![]u8 {
    const name = try store.filename(kind, id);
    var dir = store.open(alloc, kind, false) catch |err| return if (err == error.FileNotFound) error.PlanSignInRequired else err;
    defer dir.close();
    return readOrRefresh(alloc, transport, &dir, name.slice());
}

fn readOrRefresh(alloc: Allocator, transport: http.Provider, dir: *io.VerifiedDir, name: []const u8) ![]u8 {
    {
        const saved = load(alloc, dir.*, name) catch |err| return if (err == error.FileNotFound) error.PlanSignInRequired else err;
        defer saved.deinit(alloc);
        if (saved.parsed.value.expires_at_ms > io.milliTimestamp() + 60_000) return alloc.dupe(u8, saved.parsed.value.access_token);
    }
    var held = try store.lock(dir);
    defer held.release();
    const latest = load(alloc, dir.*, name) catch |err| return if (err == error.FileNotFound) error.PlanSignInRequired else err;
    defer latest.deinit(alloc);
    const old = latest.parsed.value;
    // Another process may have renewed it while this one waited.
    if (old.expires_at_ms > io.milliTimestamp() + 60_000) return alloc.dupe(u8, old.access_token);
    const payload = try std.json.Stringify.valueAlloc(alloc, .{
        .grant_type = "refresh_token",
        .refresh_token = old.refresh_token,
        .client_id = client_id,
        .scope = refresh_scopes,
    }, .{});
    defer secret.zeroAndFree(alloc, payload);
    var response = try postToken(alloc, transport, payload, true);
    defer response.deinit(alloc);
    const parsed = try parseToken(alloc, response.body);
    defer parsed.deinit();
    const replacement = try toAccount(parsed.value, old.subject, old.email, old);
    try store.save(alloc, dir, name, replacement);
    return alloc.dupe(u8, replacement.access_token);
}

/// Deletes the saved account. Claude has no public revocation endpoint for
/// this client, so the tokens simply stop being used; returns false when no
/// account was saved.
pub fn remove(alloc: Allocator, id: []const u8) !bool {
    const name = try store.filename(kind, id);
    var dir = store.open(alloc, kind, false) catch |err| return if (err == error.FileNotFound) false else err;
    defer dir.close();
    var held = try store.lock(&dir);
    defer held.release();
    store.delete(&dir, name.slice()) catch |err| return if (err == error.FileNotFound) false else err;
    return true;
}

test "Claude callback checks state and reports denied consent" {
    const a = std.testing.allocator;
    var pending: Attempt = .{ .state = "expected" };
    try std.testing.expect(takeCallback(&pending, a, "/callback?state=wrong&code=code") == .unrelated);
    try std.testing.expect(takeCallback(&pending, a, "/other?state=expected&code=code") == .unrelated);
    try std.testing.expectEqual(error.PlanAuthorizationDenied, takeCallback(&pending, a, "/callback?state=expected&error=access_denied").failed);
    const callback = takeCallback(&pending, a, "/callback?code=a%2Bb&state=expected").accepted;
    defer a.free(callback.code);
    try std.testing.expectEqualStrings("a+b", callback.code);
}

test "Claude authorization URL asks for a PKCE code with Claude Code's client" {
    const a = std.testing.allocator;
    const url = try authorization(a, "http://localhost:4000/callback", "st", "ch");
    defer a.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, authorize_url ++ "?code=true&client_id=" ++ client_id ++ "&"));
    try std.testing.expect(std.mem.find(u8, url, "redirect_uri=http%3A%2F%2Flocalhost%3A4000%2Fcallback") != null);
    try std.testing.expect(std.mem.find(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.find(u8, url, "user%3Ainference") != null);
}

test "Claude billing marker matches Claude Code's fingerprint" {
    const a = std.testing.allocator;
    const marker = try billingHeader(a, "hello world, this is a test");
    defer a.free(marker);
    // The salt, the characters at 4, 7 and 20 ("o", "o", " "), the version.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("59cf53e54c78oo 2.1.332", &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const expected = try std.fmt.allocPrint(a, "x-anthropic-billing-header: cc_version=2.1.332.{s}; cc_entrypoint=cli; cch=00000;", .{hex[0..3]});
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, marker);
}

const TestAuth = struct {
    calls: usize = 0,
    subject: []const u8 = "account-1",

    fn execute(raw: ?*anyopaque, alloc: Allocator, request: http.Request) !http.Response {
        const self: *TestAuth = @ptrCast(@alignCast(raw.?));
        const expect = std.testing.expectEqualStrings;
        const step = self.calls;
        self.calls += 1;
        try expect(user_agent, request.user_agent.?);
        const body = switch (step) {
            0 => blk: {
                try expect(token_url, request.url);
                try std.testing.expectEqual(http.Method.post_json, request.method);
                const sent = try std.json.parseFromSlice(std.json.Value, alloc, request.payload.?, .{});
                defer sent.deinit();
                try expect("authorization_code", sent.value.object.get("grant_type").?.string);
                try expect("auth-code", sent.value.object.get("code").?.string);
                try expect("pkce-verifier", sent.value.object.get("code_verifier").?.string);
                try expect(client_id, sent.value.object.get("client_id").?.string);
                break :blk try std.json.Stringify.valueAlloc(alloc, .{ .access_token = "access-1", .refresh_token = "refresh-1", .expires_in = 1, .token_type = "Bearer", .scope = "user:profile user:inference", .account = .{ .uuid = self.subject, .email_address = "me@example.com" } }, .{});
            },
            1 => blk: {
                try expect(api ++ "/models?limit=1000", request.url);
                try expect("Bearer access-1", request.authorization.?);
                try expect("anthropic-beta", request.extra_headers[1].name);
                break :blk try alloc.dupe(u8, "{\"data\":[{\"id\":\"claude-example\",\"display_name\":\"Claude Example\"}]}");
            },
            2 => blk: {
                try expect(token_url, request.url);
                try std.testing.expect(request.outlives_cancel);
                const sent = try std.json.parseFromSlice(std.json.Value, alloc, request.payload.?, .{});
                defer sent.deinit();
                try expect("refresh_token", sent.value.object.get("grant_type").?.string);
                try expect("refresh-1", sent.value.object.get("refresh_token").?.string);
                // Anthropic may keep the refresh token: the saved one stays.
                break :blk try alloc.dupe(u8, "{\"access_token\":\"access-2\",\"expires_in\":3600,\"token_type\":\"Bearer\"}");
            },
            else => return error.UnexpectedRequest,
        };
        return .{ .disposition = .accepted, .body = body, .status = 200 };
    }
};

test "Claude sign-in saves a private, renewable account and refuses another account on reconnect" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir = try io.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "claude-plan");
    defer dir.close();
    var server: TestAuth = .{};
    const transport: http.Provider = .{ .execute_fn = TestAuth.execute, .context = &server };
    var cancel: std.atomic.Value(bool) = .init(false);
    const models = try finishSignIn(a, transport, &dir, "account.json", "auth-code#state", "pkce-verifier", "http://localhost:1/callback", "state", null, &cancel);
    defer a.free(models);
    try std.testing.expect(std.mem.find(u8, models, "claude-example") != null);
    const token = try readOrRefresh(a, transport, &dir, "account.json");
    defer secret.zeroAndFree(a, token);
    try std.testing.expectEqualStrings("access-2", token);
    const saved = try load(a, dir, "account.json");
    defer saved.deinit(a);
    try std.testing.expectEqualStrings("refresh-1", saved.parsed.value.refresh_token);
    try std.testing.expectEqualStrings("me@example.com", saved.parsed.value.email);
    const again = try readOrRefresh(a, transport, &dir, "account.json");
    defer secret.zeroAndFree(a, again);
    try std.testing.expectEqual(@as(usize, 3), server.calls);
    server.calls = 0;
    server.subject = "account-2";
    try std.testing.expectError(error.PlanAccountChanged, finishSignIn(a, transport, &dir, "account.json", "auth-code", "pkce-verifier", "http://localhost:1/callback", "state", "account-1", &cancel));
}
