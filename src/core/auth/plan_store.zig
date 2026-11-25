//! The private folder of a subscription plan in the Spark profile, and the
//! account files in it: one JSON file per account, readable only by the
//! owner, replaced durably, and changed under the folder's lock.
const std = @import("std");
const io = @import("../shared/io.zig");
const paths = @import("../shared/profile_paths.zig");
const secret = @import("secret.zig");
const plan_kind = @import("plan_kind.zig");
const http = @import("oauth_transport.zig");
const Allocator = std.mem.Allocator;

pub const Kind = plan_kind.Kind;

/// The longest account file name: the longest prefix, 32 hex digits, `.json`.
pub const max_filename = 64;

pub const Filename = struct {
    buf: [max_filename]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Filename) []const u8 {
        return self.buf[0..self.len];
    }
};

pub fn filename(kind: Kind, id: []const u8) error{InvalidPlanAccount}!Filename {
    if (!kind.isId(id)) return error.InvalidPlanAccount;
    var name: Filename = .{};
    const written = std.fmt.bufPrint(&name.buf, "{s}.json", .{id}) catch return error.InvalidPlanAccount;
    name.len = written.len;
    return name;
}

pub fn newId(alloc: Allocator, kind: Kind) ![]u8 {
    var random: [16]u8 = undefined;
    try io.getIo().randomSecure(&random);
    return alloc.print("{s}{s}", .{ kind.idPrefix(), std.fmt.bytesToHex(random, .lower) });
}

/// Opens the plan's folder, creating it only when `create` is set. A missing
/// folder fails with `FileNotFound`.
pub fn open(alloc: Allocator, kind: Kind, create: bool) !io.VerifiedDir {
    const root = if (io.getenv("SPARK_PLAN_HOME")) |shared| try alloc.dupe(u8, shared) else try paths.rootDir(alloc, io.homeDir() orelse return error.HomeNotSet);
    defer alloc.free(root);
    if (!std.Io.Dir.path.isAbsolute(root) or std.mem.eql(u8, root, "/")) return error.InvalidPlanHome;
    if (create) try io.makeDirRecursive(root);
    var parent = try openRoot(root);
    defer parent.close();
    return if (create) io.openOrCreateVerifiedPrivateDir(&parent, kind.storeName()) else (try io.openVerifiedPrivateDirIfPresent(&parent, kind.storeName())) orelse error.FileNotFound;
}

fn openRoot(root: []const u8) !io.VerifiedDir {
    // Canonicalize the parent (e.g. macOS /var -> /private/var), not the final directory.
    var base = try std.Io.Dir.openDirAbsolute(io.getIo(), std.Io.Dir.path.dirname(root) orelse "/", .{});
    defer base.close(io.getIo());
    return .{ .dir = try base.openDir(io.getIo(), std.Io.Dir.path.basename(root), .{ .iterate = true, .follow_symlinks = false }) };
}

/// Paired Macs use the relay when a shared credential expires. The relay is the only
/// place that refreshes it, so two devices never spend the same rotating refresh token.
/// Null means this account is local and should refresh normally.
pub fn remoteToken(alloc: Allocator, transport: http.Provider, name: []const u8) !?[]u8 {
    if (io.getenv("SPARK_PLAN_HOME") != null) return null;
    const root = try paths.rootDir(alloc, io.homeDir() orelse return null);
    defer alloc.free(root);
    var dir = openRoot(root) catch |err| return if (err == error.FileNotFound) null else err;
    defer dir.close();
    const bytes = readPrivate(alloc, dir, "shared-plan-accounts.json") catch |err| return if (err == error.FileNotFound) null else err;
    defer secret.zeroAndFree(alloc, bytes);
    const parsed = try std.json.parseFromSlice(struct { relay: []const u8, token: []const u8, accounts: []const []const u8 }, alloc, bytes, .{});
    defer parsed.deinit();
    const id = name[0 .. name.len - ".json".len];
    for (parsed.value.accounts) |account| {
        if (std.mem.eql(u8, account, id)) break;
    } else return null;
    const relay = std.mem.trimEnd(u8, parsed.value.relay, "/");
    const uri = std.Uri.parse(relay) catch return error.InvalidPlanRelay;
    const hostname = switch (uri.host orelse return error.InvalidPlanRelay) {
        .raw, .percent_encoded => |text| text,
    };
    const secure = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    const loopback = std.ascii.eqlIgnoreCase(uri.scheme, "http") and (std.mem.eql(u8, hostname, "127.0.0.1") or std.mem.eql(u8, hostname, "localhost") or std.mem.eql(u8, hostname, "[::1]"));
    if ((!secure and !loopback) or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null or !validToken(parsed.value.token)) return error.InvalidPlanRelay;
    const url = try alloc.print("{s}/api/plan-token/{s}", .{ relay, id });
    defer alloc.free(url);
    const auth = try alloc.print("Bearer {s}", .{parsed.value.token});
    defer secret.zeroAndFree(alloc, auth);
    const limit: std.Io.Clock.Duration = .{ .raw = .fromSeconds(35), .clock = .awake };
    var response = transport.execute(alloc, .{
        .method = .post_json,
        .url = url,
        .payload = "{}",
        .authorization = auth,
        .deadline = std.Io.Clock.Timestamp.fromNow(io.getIo(), limit),
    }) catch return error.PlanRelayUnavailable;
    defer response.deinit(alloc);
    if (response.status == 404) return error.PlanSignInRequired;
    if (response.disposition != .accepted) return error.PlanRelayUnavailable;
    const result = try std.json.parseFromSlice(struct { access_token: []const u8 }, alloc, response.body, .{});
    defer result.deinit();
    if (!validToken(result.value.access_token)) return error.InvalidPlanToken;
    return try alloc.dupe(u8, result.value.access_token);
}

/// Updates from the relay must use the same lock as a running cloud session's renewal.
pub fn update(alloc: Allocator, id: []const u8, bytes: ?[]const u8) !void {
    const kind = Kind.ofId(id) orelse return error.InvalidPlanAccount;
    const name = try filename(kind, id);
    var dir = open(alloc, kind, bytes != null) catch |err| {
        if (bytes == null and err == error.FileNotFound) return;
        return err;
    };
    defer dir.close();
    var held = try lock(&dir);
    defer held.release();
    if (bytes) |data| {
        try io.durableReplaceVerified(alloc, &dir, name.slice(), data);
    } else {
        delete(&dir, name.slice()) catch |err| if (err != error.FileNotFound) return err;
    }
}

/// A file of the folder, only when it is a single private regular file.
pub fn readPrivate(alloc: Allocator, dir: io.VerifiedDir, name: []const u8) ![]u8 {
    var file = try dir.dir.openFile(io.getIo(), name, .{ .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true });
    defer file.close(io.getIo());
    const stat = try file.stat(io.getIo());
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o777 != 0o600) return error.DurablePathUnsafe;
    return io.readFileToEnd(alloc, &file, 64 * 1024);
}

pub fn deadline(wait_ms: u64) u64 {
    return @as(u64, @intCast(@max(io.milliTimestamp(), 0))) + wait_ms;
}

/// Held while an account file is read for a change and written back.
pub fn lock(dir: *io.VerifiedDir) !io.TimedAdvisoryLock {
    return io.acquireTimedAdvisoryLock(dir, "accounts.lock", deadline(17_000));
}

/// A parsed account file. `deinit` wipes the bytes it was read from.
pub fn Stored(comptime Account: type) type {
    return struct {
        bytes: []u8,
        parsed: std.json.Parsed(Account),

        pub fn deinit(self: @This(), alloc: Allocator) void {
            self.parsed.deinit();
            secret.zeroAndFree(alloc, self.bytes);
        }
    };
}

pub fn load(comptime Account: type, alloc: Allocator, dir: io.VerifiedDir, name: []const u8) !Stored(Account) {
    const bytes = try readPrivate(alloc, dir, name);
    errdefer secret.zeroAndFree(alloc, bytes);
    const parsed = std.json.parseFromSlice(Account, alloc, bytes, .{ .ignore_unknown_fields = true }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidPlanAccount,
    };
    return .{ .bytes = bytes, .parsed = parsed };
}

pub fn save(alloc: Allocator, dir: *io.VerifiedDir, name: []const u8, account: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(alloc, account, .{});
    defer secret.zeroAndFree(alloc, bytes);
    try io.durableReplaceVerified(alloc, dir, name, bytes);
}

pub fn delete(dir: *io.VerifiedDir, name: []const u8) !void {
    try dir.dir.deleteFile(io.getIo(), name);
    try io.syncVerifiedDir(dir.dir);
}

/// A token that can travel in a header and a JSON string unchanged.
pub fn validToken(token: []const u8) bool {
    if (token.len == 0 or token.len > 16 * 1024) return false;
    for (token) |c| if (c <= 0x20 or c >= 0x7f) return false;
    return true;
}

pub const Pair = [2][]const u8;

/// An `application/x-www-form-urlencoded` body. Caller owns it.
pub fn form(alloc: Allocator, fields: []const Pair) ![]u8 {
    const oauth = @import("oauth.zig");
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var encoder: oauth.FormBody = .{};
    for (fields) |field| try encoder.append(&out.writer, field[0], field[1]);
    return out.toOwnedSlice();
}

test "account files are named after valid IDs only" {
    const name = try filename(.claude, "claude-plan-0123456789abcdef0123456789abcdef");
    try std.testing.expectEqualStrings("claude-plan-0123456789abcdef0123456789abcdef.json", name.slice());
    try std.testing.expectError(error.InvalidPlanAccount, filename(.claude, "claude-plan-../../x"));
    try std.testing.expectError(error.InvalidPlanAccount, filename(.antigravity, "claude-plan-0123456789abcdef0123456789abcdef"));
    const id = try newId(std.testing.allocator, .antigravity);
    defer std.testing.allocator.free(id);
    try std.testing.expect(Kind.antigravity.isId(id));
}
