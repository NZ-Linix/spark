//! The private folder of a subscription plan in the Spark profile, and the
//! account files in it: one JSON file per account, readable only by the
//! owner, replaced durably, and changed under the folder's lock.
const std = @import("std");
const io = @import("../shared/io.zig");
const paths = @import("../shared/profile_paths.zig");
const secret = @import("secret.zig");
const plan_kind = @import("plan_kind.zig");
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
    const home = io.homeDir() orelse return error.HomeNotSet;
    const root = try paths.rootDir(alloc, home);
    defer alloc.free(root);
    if (create) try io.makeDirRecursive(root);
    // Canonicalize the parent (e.g. macOS /var -> /private/var), not the
    // final profile directory. Never follow a link standing in for the profile.
    var base = try std.Io.Dir.openDirAbsolute(io.getIo(), paths.rootParent(home), .{});
    defer base.close(io.getIo());
    var parent: io.VerifiedDir = .{ .dir = try base.openDir(io.getIo(), paths.rootName(), .{ .iterate = true, .follow_symlinks = false }) };
    defer parent.close();
    return if (create) io.openOrCreateVerifiedPrivateDir(&parent, kind.storeName()) else (try io.openVerifiedPrivateDirIfPresent(&parent, kind.storeName())) orelse error.FileNotFound;
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
