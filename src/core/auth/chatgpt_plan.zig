//! OpenAI's public Sign in with ChatGPT flow for local open-source clients.
const std = @import("std");
const oauth = @import("oauth.zig");
const browser = @import("browser_callback.zig");
const http = @import("oauth_transport.zig");
const io = @import("../shared/io.zig");
const store = @import("plan_store.zig");
const host = @import("../hosts/host.zig");
const secret = @import("secret.zig");
const Allocator = std.mem.Allocator;

pub const resource = "https://api.openai.com/v1";
const issuer = "https://auth.openai.com";
const authorize_url = issuer ++ "/api/accounts/authorize";
const token_url = issuer ++ "/api/accounts/oauth/token";
const jwks_url = issuer ++ "/.well-known/jwks.json";
const discovery_url = issuer ++ "/.well-known/openid-configuration";
const usage_scope = "resource.invoke chatgpt.tokens.use.direct";
const scopes = "openid profile email offline_access " ++ usage_scope;
const redirect_path = "/auth/callback";
const dynamic_client = "dynamic_agent_client";
pub const id_prefix = "chatgpt-plan-";

const Account = struct {
    client_id: []const u8,
    subject: []const u8,
    scope: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    expires_at_ms: i64,
};

pub fn isId(id: []const u8) bool {
    if (!std.mem.startsWith(u8, id, id_prefix) or id.len != id_prefix.len + 32) return false;
    for (id[id_prefix.len..]) |c| if (std.mem.findScalar(u8, "0123456789abcdef", c) == null) return false;
    return true;
}

pub fn newId(alloc: Allocator) ![]u8 {
    var random: [16]u8 = undefined;
    try io.getIo().randomSecure(&random);
    return alloc.print(id_prefix ++ "{s}", .{std.fmt.bytesToHex(random, .lower)});
}

fn openStore(alloc: Allocator, create: bool) !io.VerifiedDir {
    return store.open(alloc, .chatgpt, create);
}

fn readPrivate(alloc: Allocator, dir: io.VerifiedDir, name: []const u8) ![]u8 {
    var file = try dir.dir.openFile(io.getIo(), name, .{ .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true });
    defer file.close(io.getIo());
    const stat = try file.stat(io.getIo());
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o777 != 0o600) return error.DurablePathUnsafe;
    return io.readFileToEnd(alloc, &file, 64 * 1024);
}

fn lockDeadline(wait_ms: u64) u64 {
    return @as(u64, @intCast(@max(io.milliTimestamp(), 0))) + wait_ms;
}

fn getHostId(alloc: Allocator, dir: *io.VerifiedDir) ![]u8 {
    var lock = try io.acquireTimedAdvisoryLock(dir, "host.lock", lockDeadline(2000));
    defer lock.release();
    return readPrivate(alloc, dir.*, "host-id") catch |err| switch (err) {
        error.FileNotFound => blk: {
            var bytes: [16]u8 = undefined;
            try io.getIo().randomSecure(&bytes);
            bytes[6] = (bytes[6] & 0x0f) | 0x40;
            bytes[8] = (bytes[8] & 0x3f) | 0x80;
            const hex = std.fmt.bytesToHex(bytes, .lower);
            const id = try alloc.print("urn:uuid:{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
            errdefer alloc.free(id);
            try io.durableReplaceVerified(alloc, dir, "host-id", id);
            break :blk id;
        },
        else => return err,
    };
}

fn accountFilename(id: []const u8) ![id_prefix.len + 32 + 5]u8 {
    if (!isId(id)) return error.InvalidChatGPTAccount;
    return id[0 .. id_prefix.len + 32].* ++ ".json".*;
}

const Stored = struct {
    bytes: []u8,
    parsed: std.json.Parsed(Account),

    fn deinit(self: Stored, alloc: Allocator) void {
        self.parsed.deinit();
        secret.zeroAndFree(alloc, self.bytes);
    }
};

fn load(alloc: Allocator, dir: io.VerifiedDir, filename: []const u8) !Stored {
    const bytes = try readPrivate(alloc, dir, filename);
    errdefer secret.zeroAndFree(alloc, bytes);
    const parsed = try std.json.parseFromSlice(Account, alloc, bytes, .{});
    errdefer parsed.deinit();
    if (!validClient(parsed.value.client_id) or !validToken(parsed.value.access_token) or !validToken(parsed.value.refresh_token) or parsed.value.subject.len == 0) return error.InvalidChatGPTAccount;
    if (oauth.missingGrantedScope(usage_scope, parsed.value.scope) != null) return error.ChatGPTPlanPermissionMissing;
    return .{ .bytes = bytes, .parsed = parsed };
}

fn save(alloc: Allocator, dir: *io.VerifiedDir, filename: []const u8, account: Account) !void {
    const bytes = try std.json.Stringify.valueAlloc(alloc, account, .{});
    defer secret.zeroAndFree(alloc, bytes);
    try io.durableReplaceVerified(alloc, dir, filename, bytes);
}

fn validClient(client: []const u8) bool {
    if (!std.mem.startsWith(u8, client, "oaiapp_") or client.len <= "oaiapp_".len or client.len > 256) return false;
    for (client) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}

fn validToken(token: []const u8) bool {
    if (token.len == 0 or token.len > 16 * 1024) return false;
    for (token) |c| if (c <= 0x20 or c >= 0x7f) return false;
    return true;
}

const Pair = [2][]const u8;

fn form(alloc: Allocator, fields: []const Pair) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var encoder: oauth.FormBody = .{};
    for (fields) |field| try encoder.append(&out.writer, field[0], field[1]);
    return out.toOwnedSlice();
}

fn authorization(alloc: Allocator, client: []const u8, host_id: []const u8, redirect: []const u8, state: []const u8, nonce: []const u8, challenge: []const u8) ![]u8 {
    var fields = [_]Pair{
        .{ "client_id", client },         .{ "ext_agent_host_id", host_id }, .{ "response_type", "code" },
        .{ "redirect_uri", redirect },    .{ "scope", scopes },              .{ "resource", resource },
        .{ "state", state },              .{ "nonce", nonce },               .{ "code_challenge_method", "S256" },
        .{ "code_challenge", challenge }, .{ "agent_name_hint", "Spark" },
    };
    const query = try form(alloc, fields[0 .. fields.len - @intFromBool(!std.mem.eql(u8, client, dynamic_client))]);
    defer alloc.free(query);
    return alloc.print(authorize_url ++ "?{s}", .{query});
}

const Callback = struct { code: []u8, client_id: []u8 };
const Attempt = struct { state: []const u8, client_id: ?[]const u8 };

fn takeCallback(raw: ?*anyopaque, alloc: Allocator, target: []const u8) browser.ParseResult(Callback) {
    const attempt: *const Attempt = @ptrCast(@alignCast(raw.?));
    const query = if (std.mem.startsWith(u8, target, redirect_path ++ "?")) target[redirect_path.len + 1 ..] else return .unrelated;
    const state = oauth.queryValueNonEmptyAlloc(alloc, query, "state") catch return .unrelated;
    defer alloc.free(state);
    if (!std.mem.eql(u8, state, attempt.state)) return .unrelated;
    return .{ .accepted = callbackFields(alloc, query, attempt.client_id) catch |err| return .{ .failed = err } };
}

fn callbackFields(alloc: Allocator, query: []const u8, expected_client: ?[]const u8) !Callback {
    const denial: ?[]u8 = oauth.queryValueAlloc(alloc, query, "error") catch |err| switch (err) {
        error.MissingQueryParameter => null,
        else => return err,
    };
    if (denial) |value| {
        alloc.free(value);
        return error.ChatGPTAuthorizationDenied;
    }
    const returned: ?[]u8 = oauth.queryValueNonEmptyAlloc(alloc, query, "client_id") catch |err| switch (err) {
        error.MissingQueryParameter => null,
        else => return err,
    };
    defer if (returned) |value| alloc.free(value);
    const client = returned orelse expected_client orelse return error.InvalidChatGPTCallback;
    if (!validClient(client)) return error.InvalidChatGPTCallback;
    if (expected_client) |expected| if (!std.mem.eql(u8, expected, client)) return error.InvalidChatGPTCallback;
    const code = try oauth.queryValueNonEmptyAlloc(alloc, query, "code");
    errdefer secret.zeroAndFree(alloc, code);
    return .{ .code = code, .client_id = try alloc.dupe(u8, client) };
}

const Token = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    token_type: []const u8,
    expires_in: i64,
    scope: ?[]const u8 = null,
    id_token: ?[]const u8 = null,
};

fn postToken(alloc: Allocator, transport: http.Provider, fields: []const Pair, renewal: bool) !http.Response {
    const payload = try form(alloc, fields);
    defer secret.zeroAndFree(alloc, payload);
    var response = try transport.execute(alloc, .{ .method = .post_form, .url = token_url, .payload = payload, .outlives_cancel = renewal });
    errdefer response.deinit(alloc);
    if (response.disposition != .accepted) return if (response.status == 400 or response.status == 401) error.ChatGPTSignInRequired else error.ChatGPTTokenRequestFailed;
    return response;
}

fn parseToken(alloc: Allocator, bytes: []const u8) !std.json.Parsed(Token) {
    var parsed = try std.json.parseFromSlice(Token, alloc, bytes, .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    const token = parsed.value;
    if (!std.ascii.eqlIgnoreCase(token.token_type, "Bearer") or !validToken(token.access_token) or !validToken(token.refresh_token)) return error.InvalidChatGPTToken;
    return parsed;
}

fn toAccount(token: Token, client: []const u8, subject: []const u8, previous_scope: []const u8) !Account {
    const scope = token.scope orelse previous_scope;
    if (oauth.missingGrantedScope(usage_scope, scope) != null) return error.ChatGPTPlanPermissionMissing;
    return .{
        .client_id = client,
        .subject = subject,
        .scope = scope,
        .access_token = token.access_token,
        .refresh_token = token.refresh_token,
        .expires_at_ms = try oauth.expiryTimestampMs(io.milliTimestamp(), token.expires_in),
    };
}

fn decode(alloc: Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const bytes = try alloc.alloc(u8, try decoder.calcSizeForSlice(encoded));
    errdefer alloc.free(bytes);
    try decoder.decode(bytes, encoded);
    return bytes;
}

fn verifyIdentity(alloc: Allocator, jwt: []const u8, jwks: []const u8, client: []const u8, nonce: []const u8, now: i64) ![]const u8 {
    var parts = std.mem.splitScalar(u8, jwt, '.');
    const head = parts.next() orelse return error.InvalidChatGPTIdentity;
    const payload = parts.next() orelse return error.InvalidChatGPTIdentity;
    const sig = parts.next() orelse return error.InvalidChatGPTIdentity;
    if (parts.next() != null) return error.InvalidChatGPTIdentity;
    const header = try std.json.parseFromSliceLeaky(struct { alg: []const u8, kid: []const u8 }, alloc, try decode(alloc, head), .{ .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, header.alg, "RS256") or header.kid.len == 0) return error.InvalidChatGPTIdentity;
    const Jwk = struct { kty: []const u8, kid: []const u8, n: ?[]const u8 = null, e: ?[]const u8 = null, alg: ?[]const u8 = null, use: ?[]const u8 = null };
    const keys = try std.json.parseFromSliceLeaky(struct { keys: []Jwk }, alloc, jwks, .{ .ignore_unknown_fields = true });
    var key: ?Jwk = null;
    for (keys.keys) |candidate| {
        if (!std.mem.eql(u8, candidate.kid, header.kid)) continue;
        if (key != null) return error.InvalidChatGPTIdentity;
        key = candidate;
    }
    const jwk = key orelse return error.InvalidChatGPTIdentity;
    if (!std.mem.eql(u8, jwk.kty, "RSA") or !std.mem.eql(u8, jwk.alg orelse "RS256", "RS256") or !std.mem.eql(u8, jwk.use orelse "sig", "sig")) return error.InvalidChatGPTIdentity;
    const modulus = try decode(alloc, jwk.n orelse return error.InvalidChatGPTIdentity);
    const exponent = try decode(alloc, jwk.e orelse return error.InvalidChatGPTIdentity);
    const signature = try decode(alloc, sig);
    const rsa = std.crypto.Certificate.rsa;
    if (signature.len != modulus.len or modulus.len == 0 or modulus[0] < 128) return error.InvalidChatGPTIdentity;
    const message = jwt[0 .. head.len + 1 + payload.len];
    switch (modulus.len) {
        inline 256, 384, 512 => |len| {
            const public = try rsa.PublicKey.fromBytes(exponent, modulus);
            try rsa.PKCS1v1_5Signature.verify(len, signature[0..len], message, public, std.crypto.hash.sha2.Sha256);
        },
        else => return error.InvalidChatGPTIdentity,
    }
    const Claims = struct { iss: []const u8, aud: std.json.Value, exp: i64, nonce: []const u8, sub: []const u8, azp: ?[]const u8 = null };
    const claims = try std.json.parseFromSliceLeaky(Claims, alloc, try decode(alloc, payload), .{ .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, claims.iss, issuer) or !std.mem.eql(u8, claims.nonce, nonce) or claims.exp <= now or claims.sub.len == 0) return error.InvalidChatGPTIdentity;
    const audience = switch (claims.aud) {
        .string => claims.aud.string,
        .array => blk: {
            const values = claims.aud.array.items;
            if (values.len != 1 or values[0] != .string) return error.InvalidChatGPTIdentity;
            break :blk values[0].string;
        },
        else => return error.InvalidChatGPTIdentity,
    };
    if (!std.mem.eql(u8, audience, client) or !std.mem.eql(u8, claims.azp orelse client, client)) return error.InvalidChatGPTIdentity;
    return claims.sub;
}

pub fn signIn(alloc: Allocator, transport: http.Provider, opener: host.UrlOpener, id: []const u8, reconnect: bool, cancel: *std.atomic.Value(bool)) ![]u8 {
    const filename = try accountFilename(id);
    var dir = try openStore(alloc, true);
    defer dir.close();
    const saved = if (reconnect) try load(alloc, dir, &filename) else null;
    defer if (saved) |old| old.deinit(alloc);
    var pending: Attempt = .{ .state = try oauth.randomUrlSafeSecret(alloc), .client_id = if (saved) |old| old.parsed.value.client_id else null };
    defer secret.zeroAndFree(alloc, @constCast(pending.state));
    const verifier = try oauth.randomUrlSafeSecret(alloc);
    defer secret.zeroAndFree(alloc, verifier);
    const challenge = try oauth.pkceChallengeAlloc(alloc, verifier);
    defer alloc.free(challenge);
    const nonce = try oauth.randomUrlSafeSecret(alloc);
    defer alloc.free(nonce);
    const host_id = try getHostId(alloc, &dir);
    defer alloc.free(host_id);
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io.getIo(), .{});
    defer listener.deinit(io.getIo());
    const redirect = try alloc.print("http://127.0.0.1:{d}" ++ redirect_path, .{listener.socket.address.getPort()});
    defer alloc.free(redirect);
    const url = try authorization(alloc, pending.client_id orelse dynamic_client, host_id, redirect, pending.state, nonce, challenge);
    defer secret.zeroAndFree(alloc, url);
    if (!try opener.open(alloc, url)) return error.ChatGPTBrowserUnavailable;
    const deadline = io.awakeMilliTimestamp() + 5 * 60 * 1000;
    while (io.awakeMilliTimestamp() < deadline) {
        var received = (try browser.await(Callback, takeCallback, alloc, &listener, &pending, cancel, null)) orelse continue;
        defer received.deinit();
        defer secret.zeroAndFree(alloc, received.callback.code);
        defer alloc.free(received.callback.client_id);
        const result = finishSignIn(alloc, transport, &dir, &filename, received.callback, verifier, redirect, nonce, if (saved) |old| old.parsed.value.subject else null, cancel);
        received.respond(if (result) |_| .ok else |_| .failed) catch {};
        return result;
    }
    return error.ChatGPTSignInTimedOut;
}

fn finishSignIn(alloc: Allocator, transport: http.Provider, dir: *io.VerifiedDir, filename: []const u8, callback: Callback, verifier: []const u8, redirect: []const u8, nonce: []const u8, prior_subject: ?[]const u8, cancel: *const std.atomic.Value(bool)) ![]u8 {
    var response = try postToken(alloc, transport, &.{
        .{ "grant_type", "authorization_code" }, .{ "client_id", callback.client_id }, .{ "code", callback.code },
        .{ "code_verifier", verifier },          .{ "redirect_uri", redirect },        .{ "resource", resource },
    }, false);
    defer response.deinit(alloc);
    const parsed = try parseToken(alloc, response.body);
    defer parsed.deinit();
    var jwks = try transport.execute(alloc, .{ .method = .get, .url = jwks_url });
    defer jwks.deinit(alloc);
    if (jwks.disposition != .accepted) return error.ChatGPTIdentityUnavailable;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const subject = try verifyIdentity(arena.allocator(), parsed.value.id_token orelse return error.InvalidChatGPTIdentity, jwks.body, callback.client_id, nonce, @divFloor(io.milliTimestamp(), 1000));
    if (prior_subject) |prior| if (!std.mem.eql(u8, subject, prior)) return error.ChatGPTAccountChanged;
    const account = try toAccount(parsed.value, callback.client_id, subject, "");
    const models = try fetchModels(alloc, transport, account.access_token, null);
    errdefer alloc.free(models);
    if (cancel.load(.acquire)) return error.Cancelled;
    var lock = try io.acquireTimedAdvisoryLock(dir, "accounts.lock", lockDeadline(17_000));
    defer lock.release();
    if (prior_subject != null) {
        const latest = try load(alloc, dir.*, filename);
        defer latest.deinit(alloc);
        if (!std.mem.eql(u8, latest.parsed.value.subject, subject) or !std.mem.eql(u8, latest.parsed.value.client_id, account.client_id)) return error.ChatGPTAccountChanged;
    }
    try save(alloc, dir, filename, account);
    return models;
}

pub fn fetchModels(alloc: Allocator, transport: http.Provider, token: []const u8, cancel: ?*std.atomic.Value(bool)) ![]u8 {
    const auth = try alloc.print("Bearer {s}", .{token});
    defer secret.zeroAndFree(alloc, auth);
    var result = try transport.execute(alloc, .{ .method = .get, .url = resource ++ "/models", .authorization = auth, .cancel_flag = cancel, .max_response_bytes = 4 * 1024 * 1024 });
    defer result.deinit(alloc);
    if (result.disposition != .accepted) return if (result.status == 401) error.ChatGPTSignInRequired else error.ChatGPTModelsUnavailable;
    return result.takeBody();
}

pub fn accessToken(alloc: Allocator, transport: http.Provider, id: []const u8) ![]u8 {
    const filename = try accountFilename(id);
    var dir = openStore(alloc, false) catch |err| return if (err == error.FileNotFound) error.ChatGPTSignInRequired else err;
    defer dir.close();
    return readOrRefresh(alloc, transport, &dir, &filename);
}

fn readOrRefresh(alloc: Allocator, transport: http.Provider, dir: *io.VerifiedDir, filename: []const u8) ![]u8 {
    const saved = load(alloc, dir.*, filename) catch |err| return if (err == error.FileNotFound) error.ChatGPTSignInRequired else err;
    defer saved.deinit(alloc);
    if (saved.parsed.value.expires_at_ms > io.milliTimestamp() + 60_000) return alloc.dupe(u8, saved.parsed.value.access_token);
    if (try store.remoteToken(alloc, transport, filename)) |token| return token;
    var lock = try io.acquireTimedAdvisoryLock(dir, "accounts.lock", lockDeadline(17_000));
    defer lock.release();
    const latest = load(alloc, dir.*, filename) catch |err| return if (err == error.FileNotFound) error.ChatGPTSignInRequired else err;
    defer latest.deinit(alloc);
    const old = latest.parsed.value;
    if (old.expires_at_ms > io.milliTimestamp() + 60_000) return alloc.dupe(u8, old.access_token);
    var response = try postToken(alloc, transport, &.{
        .{ "grant_type", "refresh_token" }, .{ "client_id", old.client_id }, .{ "refresh_token", old.refresh_token }, .{ "resource", resource },
    }, true);
    defer response.deinit(alloc);
    const parsed = try parseToken(alloc, response.body);
    defer parsed.deinit();
    const replacement = try toAccount(parsed.value, old.client_id, old.subject, old.scope);
    try save(alloc, dir, filename, replacement);
    return alloc.dupe(u8, replacement.access_token);
}

fn revoke(alloc: Allocator, transport: http.Provider, account: Account) !bool {
    var metadata = try transport.execute(alloc, .{ .method = .get, .url = discovery_url });
    defer metadata.deinit(alloc);
    if (metadata.disposition != .accepted) return false;
    const parsed = try std.json.parseFromSlice(struct { issuer: []const u8, revocation_endpoint: []const u8 }, alloc, metadata.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    // Refuse to post a refresh token to another origin or through a redirect.
    if (!std.mem.eql(u8, parsed.value.issuer, issuer) or !std.mem.eql(u8, parsed.value.revocation_endpoint, issuer ++ "/api/accounts/oauth/revoke")) return false;
    const payload = try form(alloc, &.{ .{ "token", account.refresh_token }, .{ "token_type_hint", "refresh_token" }, .{ "client_id", account.client_id } });
    defer secret.zeroAndFree(alloc, payload);
    var result = try transport.execute(alloc, .{ .method = .post_form, .url = parsed.value.revocation_endpoint, .payload = payload });
    defer result.deinit(alloc);
    return result.disposition == .accepted;
}

pub fn remove(alloc: Allocator, transport: http.Provider, id: []const u8) !bool {
    const filename = try accountFilename(id);
    var dir = openStore(alloc, false) catch |err| return if (err == error.FileNotFound) false else err;
    defer dir.close();
    var lock = try io.acquireTimedAdvisoryLock(&dir, "accounts.lock", lockDeadline(17_000));
    defer lock.release();
    const saved = load(alloc, dir, &filename) catch |err| return if (err == error.FileNotFound) false else err;
    defer saved.deinit(alloc);
    const revoked = revoke(alloc, transport, saved.parsed.value) catch false;
    try dir.dir.deleteFile(io.getIo(), &filename);
    try io.syncVerifiedDir(dir.dir);
    return revoked;
}

test "ChatGPT callback rejects wrong state, account substitution and denied consent" {
    const a = std.testing.allocator;
    var pending: Attempt = .{ .state = "expected", .client_id = "oaiapp_returning" };
    try std.testing.expect(takeCallback(&pending, a, "/auth/callback?state=wrong&code=code") == .unrelated);
    try std.testing.expectEqual(error.InvalidChatGPTCallback, takeCallback(&pending, a, "/auth/callback?state=expected&code=code&client_id=oaiapp_other").failed);
    try std.testing.expectEqual(error.ChatGPTAuthorizationDenied, takeCallback(&pending, a, "/auth/callback?state=expected&error=access_denied").failed);
    const callback = takeCallback(&pending, a, "/auth/callback?state=expected&code=other%2Bcode").accepted;
    defer a.free(callback.code);
    defer a.free(callback.client_id);
    try std.testing.expectEqualStrings("other+code", callback.code);
    try std.testing.expectEqualStrings("oaiapp_returning", callback.client_id);
    pending.client_id = null;
    try std.testing.expectEqual(error.InvalidChatGPTCallback, takeCallback(&pending, a, "/auth/callback?state=expected&code=code").failed);
}

const fixture_jwks =
    \\{"keys":[{"kty":"RSA","kid":"test","e":"AQAB","n":"tUBIxEsLorRH_d81SyhNpVsqS3n8xmved_HR1211FAboOB78_NSuDL2WtMg9sEn30dU01x_sNWGWuMpH2BTYNbg8w0wx41RJ1uU255FxJKgh5zMssKqd0An9422FSovN6s5Uxzy8Nlrsqw7pYVFuUiGnU1kHRirCzp4GGBGbSEsVV17xm84jx4ZdR1iOtQHJDgCcyNJKqLDemHtbqBM9iHZ8hHLxA7p4hLIUQvjJ21B_8se7Pc-nsbrgL63W5DPyzk3V6oPX9v1AZLlPkMeGYjUkgoTmJW0g4OXz7MfGUIGzpxZR7w6tSTVhIA8copL1mprzxMj2Up02UG8-pfe69Q"}]}
;
const fixture_jwt = "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3QifQ.eyJpc3MiOiJodHRwczovL2F1dGgub3BlbmFpLmNvbSIsImF1ZCI6Im9haWFwcF90ZXN0IiwiZXhwIjo0MDAwMDAwMDAwLCJub25jZSI6ImZpeHR1cmUtbm9uY2UiLCJzdWIiOiJmaXh0dXJlLWFjY291bnQifQ.EBL9onpxlMBFbJSR9YEBXfrjNi-Jp8cYMFv2ktl1F5CUqApStWBnE9QolixsEoNYiq_Ww8wxhZYkx7rsgNCK4H8W8aGJgQKkONTauKZD70qj1Psq1GSO4EWTNyCY3K2TpeQ5KpjfDDR3hAPlWtKsR0_tjiN0EbAmxJfB-O2JF5QwCUxH9hc-NZ0k1jpdFUKfOkz1FSPFf3L5RsIYCUEp0tuyNeaRmFw6Ed0UIleiOCuR7y_w4c-SiTKgmpS6PmBlh-9T0VkzMr7FqbW9ycUCl8-OGwiWTwxGT9SBXI6nMgauvET-C5bvCiqYU13LyCRivkrZ0vJMWVoGmFJAgSku4w";

test "ChatGPT identity requires the correct signature, audience, nonce and expiry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("fixture-account", try verifyIdentity(a, fixture_jwt, fixture_jwks, "oaiapp_test", "fixture-nonce", 1));
    try std.testing.expectError(error.InvalidChatGPTIdentity, verifyIdentity(a, fixture_jwt, fixture_jwks, "oaiapp_wrong", "fixture-nonce", 1));
    try std.testing.expectError(error.InvalidChatGPTIdentity, verifyIdentity(a, fixture_jwt, fixture_jwks, "oaiapp_test", "wrong", 1));
    try std.testing.expectError(error.InvalidChatGPTIdentity, verifyIdentity(a, fixture_jwt, fixture_jwks, "oaiapp_test", "fixture-nonce", 4000000000));
    var changed = fixture_jwt.*;
    const start = std.mem.lastIndexOfScalar(u8, &changed, '.').?;
    changed[start + 2] = 'A';
    try std.testing.expectError(error.InvalidSignature, verifyIdentity(a, &changed, fixture_jwks, "oaiapp_test", "fixture-nonce", 1));
}

const TestAuth = struct {
    calls: usize = 0,
    deny_scope: bool = false,
    test_redirect: []const u8 = "http://127.0.0.1:14250/auth/callback",

    fn execute(raw: ?*anyopaque, alloc: Allocator, request: http.Request) !http.Response {
        const self: *TestAuth = @ptrCast(@alignCast(raw.?));
        const expect = std.testing.expectEqualStrings;
        const step = self.calls;
        self.calls += 1;
        const body = switch (step) {
            0 => blk: {
                try expect(token_url, request.url);
                try std.testing.expectEqual(http.Method.post_form, request.method);
                const encoding = try form(alloc, &.{ .{ "grant_type", "authorization_code" }, .{ "client_id", "oaiapp_test" }, .{ "code", "auth-code" }, .{ "code_verifier", "pkce-verifier" }, .{ "redirect_uri", self.test_redirect }, .{ "resource", resource } });
                defer alloc.free(encoding);
                try expect(encoding, request.payload.?);
                break :blk try std.json.Stringify.valueAlloc(alloc, .{ .access_token = "access-1", .refresh_token = "refresh-1", .expires_in = 1, .token_type = "Bearer", .scope = if (self.deny_scope) "openid" else scopes, .id_token = fixture_jwt }, .{});
            },
            1 => blk: {
                try expect(jwks_url, request.url);
                break :blk try alloc.dupe(u8, fixture_jwks);
            },
            2 => blk: {
                try expect(resource ++ "/models", request.url);
                try expect("Bearer access-1", request.authorization.?);
                break :blk try alloc.dupe(u8, "{\"models\":[{\"slug\":\"gpt-example\",\"visibility\":\"list\"}]}");
            },
            3 => blk: {
                try expect(token_url, request.url);
                try std.testing.expect(request.outlives_cancel);
                const encoding = try form(alloc, &.{ .{ "grant_type", "refresh_token" }, .{ "client_id", "oaiapp_test" }, .{ "refresh_token", "refresh-1" }, .{ "resource", resource } });
                defer alloc.free(encoding);
                try expect(encoding, request.payload.?);
                break :blk try alloc.dupe(u8, "{\"access_token\":\"access-2\",\"refresh_token\":\"refresh-2\",\"expires_in\":3600,\"token_type\":\"Bearer\"}");
            },
            else => return error.UnexpectedRequest,
        };
        return .{ .disposition = .accepted, .body = body, .status = 200 };
    }
};

test "ChatGPT authorization exchanges the issued code for a private, renewable account" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir = try io.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "credentials");
    defer dir.close();
    try std.testing.expectEqual(@as(u32, 0o700), (try dir.dir.stat(io.getIo())).permissions.toMode() & 0o777);
    const host_id = try getHostId(a, &dir);
    defer a.free(host_id);
    const same_host = try getHostId(a, &dir);
    defer a.free(same_host);
    try std.testing.expectEqualStrings(host_id, same_host);
    try std.testing.expect(std.mem.startsWith(u8, host_id, "urn:uuid:"));
    const grant = try authorization(a, dynamic_client, host_id, "http://127.0.0.1:14250/auth/callback", "state", "nonce", "challenge");
    defer a.free(grant);
    try std.testing.expect(std.mem.startsWith(u8, grant, authorize_url ++ "?client_id=dynamic_agent_client&"));
    try std.testing.expect(std.mem.find(u8, grant, "code_challenge_method=S256") != null);
    const callback: Callback = .{ .code = @constCast("auth-code"), .client_id = @constCast("oaiapp_test") };
    var server: TestAuth = .{};
    const transport: http.Provider = .{ .execute_fn = TestAuth.execute, .context = &server };
    var cancel: std.atomic.Value(bool) = .init(false);
    const models = try finishSignIn(a, transport, &dir, "account.json", callback, "pkce-verifier", server.test_redirect, "fixture-nonce", null, &cancel);
    defer a.free(models);
    try std.testing.expect(std.mem.find(u8, models, "gpt-example") != null);
    const token = try readOrRefresh(a, transport, &dir, "account.json");
    defer secret.zeroAndFree(a, token);
    try std.testing.expectEqualStrings("access-2", token);
    const saved = try load(a, dir, "account.json");
    defer saved.deinit(a);
    try std.testing.expectEqualStrings("refresh-2", saved.parsed.value.refresh_token);
    const again = try readOrRefresh(a, transport, &dir, "account.json");
    defer secret.zeroAndFree(a, again);
    try std.testing.expectEqualStrings(token, again);
    try std.testing.expectEqual(@as(usize, 4), server.calls);
    server.calls = 0;
    server.deny_scope = true;
    try std.testing.expectError(error.ChatGPTPlanPermissionMissing, finishSignIn(a, transport, &dir, "denied.json", callback, "pkce-verifier", server.test_redirect, "fixture-nonce", null, &cancel));
    try std.testing.expectError(error.FileNotFound, readPrivate(a, dir, "denied.json"));
}
