//! The authorization code flow's data, pure: PKCE and state, the
//! authorization request, reading and checking
//! the authorization response, registration,
//! token requests with each client authentication method, token responses,
//! and scope sets as the bits `core/auth.zig` keeps.

const std = @import("std");
const wire = @import("../protocol/wire.zig");
const http_headers = @import("../protocol/http_headers.zig");
const discovery = @import("discovery.zig");
const core = @import("../core/auth.zig");

const Allocator = std.mem.Allocator;
const b64 = std.base64.url_safe_no_pad.Encoder;

/// PKCE with S256 (RFC 7636): the verifier is 32 random bytes in base64url,
/// and the challenge the base64url SHA-256 of it.
pub const Pkce = struct {
    verifier: [43]u8,
    challenge: [43]u8,

    pub fn init(random: [32]u8) Pkce {
        var p: Pkce = undefined;
        _ = b64.encode(&p.verifier, &random);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&p.verifier, &digest, .{});
        _ = b64.encode(&p.challenge, &digest);
        return p;
    }
};

/// The state: 32 random bytes in base64url, as long as the PKCE verifier;
/// a bridge such as spark.sh's Slack sign-in takes no shorter one.
pub fn state(random: [32]u8) [43]u8 {
    var out: [43]u8 = undefined;
    _ = b64.encode(&out, &random);
    return out;
}

// ---- Form encoding ----

fn writeEscaped(w: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try w.writeByte(c);
        } else try w.print("%{X:0>2}", .{c});
    }
}

/// One `name=value` pair of a form or query, with `&` before all but the first.
pub fn writeParam(w: *std.Io.Writer, first: *bool, name: []const u8, value: []const u8) std.Io.Writer.Error!void {
    if (!first.*) try w.writeByte('&');
    first.* = false;
    try writeEscaped(w, name);
    try w.writeByte('=');
    try writeEscaped(w, value);
}

/// Decodes a form or query component: `+` is a space, and `%XX` a byte.
fn unescape(a: Allocator, value: []const u8) error{ OutOfMemory, Malformed }![]const u8 {
    if (std.mem.findAny(u8, value, "%+") == null) return value;
    const out = try a.alloc(u8, value.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        out[n] = switch (value[i]) {
            '+' => ' ',
            '%' => blk: {
                if (i + 2 >= value.len) return error.Malformed;
                const byte = std.fmt.parseInt(u8, value[i + 1 .. i + 3], 16) catch return error.Malformed;
                i += 2;
                break :blk byte;
            },
            else => |c| c,
        };
        n += 1;
    }
    return out[0..n];
}

// ---- The authorization request ----

pub const AuthorizationRequest = struct {
    endpoint: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    /// Space-separated; left out when null.
    scope: ?[]const u8,
    state: []const u8,
    challenge: []const u8,
    /// The canonical server URI.
    resource: []const u8,
};

pub fn writeAuthorizationUrl(w: *std.Io.Writer, r: AuthorizationRequest) std.Io.Writer.Error!void {
    try w.writeAll(r.endpoint);
    try w.writeByte(if (std.mem.findScalar(u8, r.endpoint, '?') == null) '?' else '&');
    var first = true;
    try writeParam(w, &first, "response_type", "code");
    try writeParam(w, &first, "client_id", r.client_id);
    try writeParam(w, &first, "redirect_uri", r.redirect_uri);
    if (r.scope) |s| try writeParam(w, &first, "scope", s);
    try writeParam(w, &first, "state", r.state);
    try writeParam(w, &first, "code_challenge", r.challenge);
    try writeParam(w, &first, "code_challenge_method", "S256");
    try writeParam(w, &first, "resource", r.resource);
}

// ---- The authorization response ----

pub const Response = struct {
    code: ?[]const u8 = null,
    state: ?[]const u8 = null,
    iss: ?[]const u8 = null,
    /// `error`, `error_description`: shown only after the checks pass.
    err: ?[]const u8 = null,
    err_description: ?[]const u8 = null,
};

/// Reads the URL the authorization server redirected to. Its scheme, host,
/// port, and path must be the redirect URI's.
pub fn parseResponse(a: Allocator, callback: []const u8, redirect_uri: []const u8) error{ OutOfMemory, WrongRedirect, Malformed }!Response {
    const got = discovery.parseUrl(callback) orelse return error.WrongRedirect;
    const want = discovery.parseUrl(redirect_uri) orelse return error.WrongRedirect;
    if (!discovery.sameOrigin(got, want) or !std.mem.eql(u8, got.path, want.path)) return error.WrongRedirect;
    var r: Response = .{};
    const q = std.mem.findScalar(u8, got.rest, '?') orelse return r;
    var it = std.mem.splitScalar(u8, got.rest[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse continue;
        const name = try unescape(a, pair[0..eq]);
        const value = try unescape(a, pair[eq + 1 ..]);
        const slot: *?[]const u8 = if (std.mem.eql(u8, name, "code"))
            &r.code
        else if (std.mem.eql(u8, name, "state"))
            &r.state
        else if (std.mem.eql(u8, name, "iss"))
            &r.iss
        else if (std.mem.eql(u8, name, "error"))
            &r.err
        else if (std.mem.eql(u8, name, "error_description"))
            &r.err_description
        else
            continue;
        // A parameter given twice can't be trusted (RFC 6749 §3.1).
        if (slot.* != null) return error.Malformed;
        slot.* = value;
    }
    return r;
}

/// The facts the flow core checks before anything in the response is used:
/// the state against the flow's, and iss against the issuer recorded, both as
/// exact strings.
pub fn checkResponse(r: Response, expected_state: []const u8, issuer: []const u8, advertised: bool) @FieldType(core.FlowEvent, "responded") {
    return .{
        .state_ok = if (r.state) |s| std.mem.eql(u8, s, expected_state) else false,
        .iss = if (r.iss) |i| (if (std.mem.eql(u8, i, issuer)) .match else .wrong) else .none,
        .advertised = advertised,
        .err = r.err != null or r.code == null,
    };
}

// ---- Registration ----

pub const Method = enum { none, client_secret_basic, client_secret_post };

/// A Dynamic Client Registration request for a native public client,
/// asking for refresh tokens.
pub fn writeRegistration(w: *std.Io.Writer, client_name: []const u8, redirect_uri: []const u8) std.Io.Writer.Error!void {
    var json: std.json.Stringify = .{ .writer = w };
    try json.write(.{
        .client_name = client_name,
        .redirect_uris = &[_][]const u8{redirect_uri},
        .grant_types = &[_][]const u8{ "authorization_code", "refresh_token" },
        .response_types = &[_][]const u8{"code"},
        .token_endpoint_auth_method = "none",
        .application_type = "native",
    });
}

pub const Registration = struct {
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    method: ?Method = null,
};

pub fn parseRegistration(a: Allocator, raw: []const u8) error{ OutOfMemory, Malformed }!Registration {
    var f: [3]?[]const u8 = undefined;
    wire.objectFields(raw, &.{ "client_id", "client_secret", "token_endpoint_auth_method" }, &f) catch return error.Malformed;
    var r: Registration = .{ .client_id = (try wire.decodeString(a, f[0] orelse return error.Malformed)) orelse return error.Malformed };
    if (f[1]) |v| r.client_secret = try wire.decodeString(a, v);
    if (f[2]) |v| r.method = std.meta.stringToEnum(Method, wire.plainString(v) orelse "") orelse return error.Malformed;
    return r;
}

/// The token endpoint's client authentication: the registration's when it
/// named one; else none without a secret; else basic or post, as the server
/// lists them, basic when it lists neither (RFC 8414 §2).
pub fn chooseMethod(registered: ?Method, has_secret: bool, supported: ?[]const u8) Method {
    if (registered) |m| return m;
    if (!has_secret) return .none;
    const list = supported orelse return .client_secret_basic;
    if (wire.arrayHasString(list, "client_secret_basic") catch false) return .client_secret_basic;
    if (wire.arrayHasString(list, "client_secret_post") catch false) return .client_secret_post;
    return .client_secret_basic;
}

// ---- Token requests and responses ----

pub const Client = struct {
    id: []const u8,
    secret: ?[]const u8 = null,
    method: Method = .none,
};

pub const Grant = union(enum) {
    code: struct { code: []const u8, verifier: []const u8, redirect_uri: []const u8 },
    refresh: []const u8,
    /// RFC 7009 revocation: the token, and which kind it is.
    revoke: struct { token: []const u8, hint: []const u8 },
};

/// A token request's form body, with `resource` and the client's
/// id and secret as its method puts them in the body.
pub fn writeTokenRequest(w: *std.Io.Writer, grant: Grant, resource: []const u8, client: Client) std.Io.Writer.Error!void {
    var first = true;
    switch (grant) {
        .code => |c| {
            try writeParam(w, &first, "grant_type", "authorization_code");
            try writeParam(w, &first, "code", c.code);
            try writeParam(w, &first, "redirect_uri", c.redirect_uri);
            try writeParam(w, &first, "code_verifier", c.verifier);
        },
        .refresh => |token| {
            try writeParam(w, &first, "grant_type", "refresh_token");
            try writeParam(w, &first, "refresh_token", token);
        },
        .revoke => |r| {
            try writeParam(w, &first, "token", r.token);
            try writeParam(w, &first, "token_type_hint", r.hint);
        },
    }
    if (grant != .revoke) try writeParam(w, &first, "resource", resource);
    switch (client.method) {
        .none => try writeParam(w, &first, "client_id", client.id),
        .client_secret_post => {
            try writeParam(w, &first, "client_id", client.id);
            try writeParam(w, &first, "client_secret", client.secret orelse "");
        },
        .client_secret_basic => {},
    }
}

/// `Authorization: Basic`, with the id and secret form-encoded first (RFC 6749
/// §2.3.1). Null unless the method is basic.
pub fn basicAuthorization(a: Allocator, client: Client) Allocator.Error!?[]const u8 {
    if (client.method != .client_secret_basic) return null;
    var pair: std.Io.Writer.Allocating = .init(a);
    writeEscaped(&pair.writer, client.id) catch return error.OutOfMemory;
    pair.writer.writeByte(':') catch return error.OutOfMemory;
    writeEscaped(&pair.writer, client.secret orelse "") catch return error.OutOfMemory;
    const plain = pair.written();
    const out = try a.alloc(u8, 6 + std.base64.standard.Encoder.calcSize(plain.len));
    @memcpy(out[0..6], "Basic ");
    _ = std.base64.standard.Encoder.encode(out[6..], plain);
    return out;
}

pub const Token = struct {
    access: []const u8,
    /// Not always issued; when it comes with a refresh, it replaces
    /// the one held.
    refresh: ?[]const u8 = null,
    expires_in: ?u64 = null,
    scope: ?[]const u8 = null,
};

/// Token types that can't be sent as a bearer token: bound to a key (DPoP,
/// RFC 9449; PoP; MAC) or not an access token at all (N_A, RFC 8693). Any
/// other, such as Slack's `user`, is sent as Bearer, as MCP requires.
fn unsendable(kind: []const u8) bool {
    for ([_][]const u8{ "dpop", "pop", "mac", "n_a" }) |k| if (std.ascii.eqlIgnoreCase(kind, k)) return true;
    return false;
}

/// Whether `access` is an access token as RFC 6749 appendix A.12 spells one,
/// 1*VSCHAR (0x20..0x7E). It goes in the `Authorization` header, where any
/// other byte could break the request.
pub fn validToken(access: []const u8) bool {
    return access.len != 0 and http_headers.printable(access);
}

/// Reads a token response. Every token is sent as Bearer; a type that
/// can't be is refused, and so is an access token that isn't valid.
pub fn parseToken(a: Allocator, raw: []const u8) error{ OutOfMemory, Malformed }!Token {
    var f: [5]?[]const u8 = undefined;
    wire.objectFields(raw, &.{ "access_token", "token_type", "refresh_token", "expires_in", "scope" }, &f) catch return error.Malformed;
    const access = (try wire.decodeString(a, f[0] orelse return error.Malformed)) orelse return error.Malformed;
    const kind = wire.plainString(f[1] orelse return error.Malformed) orelse return error.Malformed;
    if (!validToken(access) or unsendable(kind)) return error.Malformed;
    var t: Token = .{ .access = access };
    if (f[2]) |v| t.refresh = try wire.decodeString(a, v);
    if (f[3]) |v| t.expires_in = std.fmt.parseInt(u64, v, 10) catch null;
    if (f[4]) |v| t.scope = try wire.decodeString(a, v);
    return t;
}

/// Why a token endpoint's answer gave no token, to show the person signing
/// in: its own `error` and `error_description` (RFC 6749 §5.2), at any
/// status since some answer 200 with one (Slack's `ok:false`), or what a
/// 200 answer lacked. Owned by `a`; never any part of a token.
pub fn tokenFailure(a: Allocator, status: u16, raw: []const u8) Allocator.Error![]const u8 {
    var f: [4]?[]const u8 = .{ null, null, null, null };
    const json = if (wire.objectFields(raw, &.{ "error", "error_description", "token_type", "access_token" }, &f)) true else |_| false;
    if (!json) f = .{ null, null, null, null };
    if (f[0]) |raw_code| if (wire.plainString(raw_code)) |code| {
        const text = if (f[1]) |v| try wire.decodeString(a, v) else null;
        return if (text) |t| a.print("{s}: {s}", .{ code, t }) else a.dupe(u8, code);
    };
    if (status != 200) return a.print("its token endpoint answered HTTP {d}", .{status});
    if (!json) return a.dupe(u8, "its token endpoint's answer isn't a JSON object");
    const kind = wire.plainString(f[2] orelse return a.dupe(u8, "its token response has no token_type")) orelse
        return a.dupe(u8, "its token response has no token_type");
    if (unsendable(kind)) return a.print("its token is of type {s}, which can't be sent as a Bearer token", .{kind});
    if (f[3]) |v| if (try wire.decodeString(a, v)) |access| if (access.len != 0 and !validToken(access))
        return a.dupe(u8, "its token has characters OAuth doesn't allow");
    return a.dupe(u8, "its token response has no access_token");
}

/// The errors that refuse a refresh for good: RFC 6749 §5.2's for a grant or
/// client the server no longer accepts, and Slack's for a dead refresh token.
const refresh_refusals = [_][]const u8{ "invalid_grant", "invalid_client", "unauthorized_client", "invalid_refresh_token" };

/// A refresh the token endpoint refused for good: its HTTP status and the
/// error it named. `code` is one of `refresh_refusals`, never the server's
/// own bytes, so it can be logged anywhere.
pub const Refusal = struct { status: u16, code: []const u8 };

/// Whether a token endpoint's answer to a refresh refuses it for good, so
/// the refresh token is dropped: an answer at 200 or a 4xx other than 429
/// that names one of `refresh_refusals`. RFC 6749 sends its errors with 400
/// or 401, and Slack sends its own with 200 and `ok:false`. Any other error,
/// such as Slack's `internal_error`, a 429, a 5xx, or an answer naming no
/// error may pass on a retry, so the tokens stay: null.
pub fn refreshRefusal(status: u16, raw: []const u8) ?Refusal {
    if (status != 200 and (status < 400 or status >= 500 or status == 429)) return null;
    var f: [1]?[]const u8 = undefined;
    wire.objectFields(raw, &.{"error"}, &f) catch return null;
    const code = wire.plainString(f[0] orelse return null) orelse return null;
    for (refresh_refusals) |refusal| if (std.mem.eql(u8, code, refusal)) return .{ .status = status, .code = refusal };
    return null;
}

// ---- Scopes ----

/// At most 31 scope names, so every mask fits TLC's integers in the traces;
/// more are dropped, and a step-up for a dropped one ends at the bound.
pub const max_scopes = 31;

/// Scope names, each a bit of the masks `core/auth.zig` keeps. The names are
/// copied into the set's allocator.
pub const ScopeSet = struct {
    names: [max_scopes][]const u8 = undefined,
    count: u8 = 0,

    pub fn bit(s: *ScopeSet, a: Allocator, name: []const u8) Allocator.Error!u32 {
        for (s.names[0..s.count], 0..) |n, i| if (std.mem.eql(u8, n, name)) return @as(u32, 1) << @intCast(i);
        if (s.count == s.names.len) return 0;
        s.names[s.count] = try a.dupe(u8, name);
        s.count += 1;
        return @as(u32, 1) << @intCast(s.count - 1);
    }

    /// The bits for a space-separated list.
    pub fn ofList(s: *ScopeSet, a: Allocator, names: []const u8) Allocator.Error!u32 {
        var mask: u32 = 0;
        var it = std.mem.tokenizeScalar(u8, names, ' ');
        while (it.next()) |name| mask |= try s.bit(a, name);
        return mask;
    }

    /// The bits for a JSON array of strings; others are skipped.
    pub fn ofArray(s: *ScopeSet, a: Allocator, raw: []const u8) Allocator.Error!u32 {
        var mask: u32 = 0;
        var elements: wire.Elements = undefined;
        elements.init(raw) catch return 0;
        while (elements.next() catch null) |e| {
            if (try wire.decodeString(a, e)) |name| mask |= try s.bit(a, name);
        }
        return mask;
    }

    /// The names in `mask`, kept in `buf`.
    pub fn namesOf(s: *const ScopeSet, mask: u32, buf: *[max_scopes][]const u8) []const []const u8 {
        var n: usize = 0;
        for (s.names[0..s.count], 0..) |name, i| if (mask & (@as(u32, 1) << @intCast(i)) != 0) {
            buf[n] = name;
            n += 1;
        };
        return buf[0..n];
    }

    /// The names in `mask`, space-separated, with `offline_access` added when
    /// `offline`. Null when that leaves none.
    pub fn list(s: *const ScopeSet, a: Allocator, mask: u32, offline: bool) Allocator.Error!?[]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var has_offline = false;
        for (s.names[0..s.count], 0..) |n, i| if (mask & (@as(u32, 1) << @intCast(i)) != 0) {
            if (out.items.len > 0) try out.append(a, ' ');
            try out.appendSlice(a, n);
            has_offline = has_offline or std.mem.eql(u8, n, "offline_access");
        };
        if (offline and !has_offline) {
            if (out.items.len > 0) try out.append(a, ' ');
            try out.appendSlice(a, "offline_access");
        }
        return if (out.items.len == 0) null else out.items;
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "PKCE S256 and the state (RFC 7636 appendix B)" {
    // The RFC's example: its verifier is the base64url of these 32 bytes.
    const random = [32]u8{ 116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186, 22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121 };
    const p: Pkce = .init(random);
    try testing.expectEqualStrings("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", &p.verifier);
    try testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &p.challenge);
    // As long as the verifier: a bridge such as spark.sh's takes no shorter one.
    try testing.expectEqual(@as(usize, 43), state(@splat(7)).len);
}
