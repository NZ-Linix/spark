//! Sign-in credentials the engine hands spark to keep (AUTH-21): one opaque blob per
//! server name and URL, so a changed URL never gets an old token. They live in
//! the macOS Keychain, or in a private file under `~/.spark/mcp-credentials/`.
//! Either way the directory's advisory lock is held while the store is read
//! and rewritten, so two spark processes don't overwrite each other's entries.
//! A store this spark can't read, damaged or saved by a newer spark, is never
//! written over. One spark refreshes a login at a time, under that login's
//! refresh lock.
//!
//! Older stores are never read or taken over: v1's `credentials.json`, and
//! `credentials-v2.json` (Keychain item `SPARK_MCP_OAUTH_CREDENTIALS_V2`). Builds
//! from before version 2 of the document read a version-2 store as empty and
//! write it back, erasing every login in it, and spark processes still running
//! those builds keep refreshing the logins they hold in memory. A login
//! shared with them would be refreshed apart and signed out, so this store
//! starts empty, in files and a Keychain item no older spark opens, and each
//! server signs in once.
//!
//! TLA+ models: `tests/tla/mcp_host/Credentials.tla`; for logins shared between
//! processes, `tests/tla/mcp_host/SharedLogins.tla`; for processes running
//! older builds beside this one, `tests/tla/mcp_host/MixedBuilds.tla`; for how
//! long the Keychain store's lock is held and waited for,
//! `tests/tla/mcp_host/StoreLockBudget.tla`; and for how long another spark waits
//! for a login's refresh, `tests/tla/mcp_host/RefreshLease.tla`.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const native_keychain = @import("../hosts/native_keychain.zig");
const leased_lock = @import("../shared/leased_lock.zig");
const secret = @import("../auth/secret.zig");
const json_decode = @import("../shared/json_decode.zig");

const Allocator = std.mem.Allocator;

const file_name = "credentials-v3.json";
/// Not `credentials.lock`, which older builds hold while they read and
/// rewrite their own stores: nothing here waits on them.
const lock_file_name = "credentials-v3.lock";
/// How long the file store waits for its lock: its work under it takes
/// milliseconds.
const lock_deadline_ms: u64 = 2_000;
/// The Keychain store's lock is leased (`Store.lock`): its holder stamps it
/// before each Keychain call, and the call ends within `call_budget_ms`, its
/// own timeout; a waiting spark gives up only `hold_slack_ms` after that.
const call_budget_ms: i64 = native_keychain.keychain_call_ms;
const hold_slack_ms: i64 = leased_lock.slack_ms;
const max_store_bytes: usize = 1024 * 1024;

pub const Backend = enum { keychain, file };

/// What a credential is saved under. A server from a workspace's `.mcp.json`
/// has its own, kept apart from the profile's and from other workspaces'
///: `workspace` is that workspace's root, null for every other server.
pub const Key = struct {
    name: []const u8,
    url: []const u8,
    workspace: ?[]const u8 = null,

    fn matches(k: Key, e: Entry) bool {
        const same_workspace = if (k.workspace) |w| (if (e.workspace) |ew| std.mem.eql(u8, w, ew) else false) else e.workspace == null;
        return same_workspace and std.mem.eql(u8, e.name, k.name) and std.mem.eql(u8, e.url, k.url);
    }
};

pub const Store = struct {
    /// The user's home directory, borrowed for the store's lifetime.
    home: []const u8,
    backend: Backend,

    /// The Keychain on macOS unless it is turned off or unusable, else the file.
    pub fn detect(alloc: Allocator, home: []const u8) Store {
        const keychain = builtin.target.os.tag == .macos and !native_keychain.isDisabled() and
            (native_keychain.userDefaultKeychainAvailable(alloc) catch false);
        return .{ .home = home, .backend = if (keychain) .keychain else .file };
    }

    /// Where the store is, for a message about one that can't be read.
    pub fn place(s: Store) []const u8 {
        return switch (s.backend) {
            .file => "~/" ++ profile_paths.root_dir_name ++ "/" ++ profile_paths.mcp_credentials_dir_name ++ "/" ++ file_name,
            .keychain => "the Keychain item " ++ native_keychain.mcp_host_credentials_service_name,
        };
    }

    /// Why the store couldn't be written, for a notice: "<place> couldn't be
    /// written: <why>", held in `buffer`.
    pub fn writeFailure(s: Store, buffer: []u8, err: anyerror) []const u8 {
        return std.mem.print(buffer, "{s} couldn't be written: {s}", .{ s.place(), cause(err, "write") }) catch "the saved MCP sign-ins couldn't be written";
    }

    /// Why the store couldn't be read, for a server's status: "<place>
    /// couldn't be read: <why>", held in `buffer`.
    pub fn readFailure(s: Store, buffer: []u8, err: anyerror) []const u8 {
        return std.mem.print(buffer, "{s} couldn't be read: {s}", .{ s.place(), cause(err, "read") }) catch "the saved MCP sign-ins couldn't be read";
    }

    /// A store error in words, for an attempt to `verb` the store.
    fn cause(err: anyerror, comptime verb: []const u8) []const u8 {
        return switch (err) {
            // A store over spark's size limit is one spark can't read either.
            error.CredentialStoreUnreadable, error.StreamTooLong => "a newer spark saved it, or it's damaged",
            error.LockBusy => "another spark kept it busy",
            error.AccessDenied => "spark isn't allowed to " ++ verb ++ " it",
            error.PrivateStatePermissionsUnsupported => "its permissions let others read it, or spark can't make them private",
            error.DurablePathUnsafe => "it isn't a plain file",
            error.NoSpaceLeft, error.DiskQuota => "the disk is full",
            error.ReadOnlyFileSystem => "its disk is read-only",
            error.KeychainReadFailed, error.KeychainWriteFailed, error.KeychainDeleteFailed => "the Keychain refused it or didn't answer",
            else => @errorName(err),
        };
    }

    /// The credential saved under `key`, or null, also when the store can't be
    /// read. The caller owns it and frees it with `secret.zeroAndFree`.
    pub fn get(s: Store, alloc: Allocator, key: Key) !?[]u8 {
        return s.lookup(alloc, key) catch |err| switch (err) {
            error.CredentialStoreUnreadable => null,
            else => err,
        };
    }

    /// `get`, except that a store it can't read fails with
    /// `error.CredentialStoreUnreadable`, so null means none is saved.
    pub fn lookup(s: Store, alloc: Allocator, key: Key) !?[]u8 {
        var locked = try s.lock();
        defer locked.release();
        var doc = try s.read(alloc, &locked);
        defer doc.deinit(alloc);
        const i = doc.find(key) orelse return null;
        return try alloc.dupe(u8, doc.entries.items[i].credential);
    }

    /// Every saved credential from one read of the store, so a host with
    /// many servers reads the Keychain once, not once per server. The
    /// caller frees it with `Snapshot.deinit`.
    pub fn snapshot(s: Store, alloc: Allocator) !Snapshot {
        var locked = try s.lock();
        defer locked.release();
        return .{ .doc = try s.read(alloc, &locked) };
    }

    /// Fails with `error.CredentialStoreUnreadable` when the store can't be
    /// read, so a sign-in can stop before it starts.
    pub fn check(s: Store, alloc: Allocator) !void {
        var locked = try s.lock();
        defer locked.release();
        var doc = try s.read(alloc, &locked);
        doc.deinit(alloc);
    }

    /// Saves `credential` under `key`, replacing any earlier one; an
    /// unreadable store fails with `error.CredentialStoreUnreadable`.
    pub fn put(s: Store, alloc: Allocator, key: Key, credential: []const u8) !void {
        var locked = try s.lock();
        defer locked.release();
        var doc = try s.read(alloc, &locked);
        defer doc.deinit(alloc);
        if (doc.find(key)) |i| {
            const entry = &doc.entries.items[i];
            const copy = try alloc.dupe(u8, credential);
            secret.zeroAndFree(alloc, entry.credential);
            entry.credential = copy;
        } else {
            try doc.entries.ensureUnusedCapacity(alloc, 1);
            doc.entries.appendAssumeCapacity(try Entry.of(alloc, key, credential));
        }
        try s.write(alloc, &locked, doc);
    }

    /// Deletes the credential saved under `key`; false when there was none.
    /// An unreadable store fails with `error.CredentialStoreUnreadable`.
    pub fn remove(s: Store, alloc: Allocator, key: Key) !bool {
        var locked = try s.lock();
        defer locked.release();
        var doc = try s.read(alloc, &locked);
        defer doc.deinit(alloc);
        const i = doc.find(key) orelse return false;
        var entry = doc.entries.orderedRemove(i);
        entry.deinit(alloc);
        try s.write(alloc, &locked, doc);
        return true;
    }

    /// Deletes the credential saved under `key` only if it is `own`, the
    /// digest of the one this process had, so one another spark saved since
    /// stays. False when none was deleted.
    pub fn removeIfSame(s: Store, alloc: Allocator, key: Key, own: [32]u8) !bool {
        var locked = try s.lock();
        defer locked.release();
        var doc = try s.read(alloc, &locked);
        defer doc.deinit(alloc);
        const i = doc.find(key) orelse return false;
        if (!std.mem.eql(u8, &digest(doc.entries.items[i].credential), &own)) return false;
        var entry = doc.entries.orderedRemove(i);
        entry.deinit(alloc);
        try s.write(alloc, &locked, doc);
        return true;
    }

    /// The refresh lock of the login saved under `key`, or null while another
    /// spark holds it: one spark refreshes a login at a time, and the others take
    /// what it saved. The lock goes with `release`, or with the process. It
    /// is leased: its holder stamps it now, and again with `restamp` before
    /// each step of the refresh (`refreshHolderStopped`).
    pub fn tryRefreshLock(s: Store, key: Key) !?Locked {
        var dir = try s.openDir();
        errdefer dir.close();
        const name = refreshLockName(key);
        const advisory = io_mod.acquireTimedAdvisoryLock(&dir, &name, 0) catch |err| switch (err) {
            error.LockBusy => {
                dir.close();
                return null;
            },
            else => return err,
        };
        const now = io_mod.awakeMilliTimestamp();
        leased_lock.writeStamp(advisory.file, now, "mcp");
        debug_trace.logf("mcp", "MCP refresh lock taken stamp={d}", .{now});
        return .{ .dir = dir, .lock = advisory, .lease = .{ .kind = .refresh, .stamp_ms = now } };
    }

    /// Whether an spark that began waiting at `started_ms` for the refresh lock
    /// of the login under `key` goes ahead without it: `hold_slack_ms` after
    /// both the holder's step, at most `step_ms` from its stamp, and the
    /// store's lease ran out. A holder waiting its turn for the store, or in
    /// a Keychain call, keeps the store's stamp fresh; one that gives up on
    /// the store stamps the refresh lock before the slack is over
    /// (`tests/tla/mcp_host/RefreshLease.tla` NoGoAheadPastLiveRefresher).
    pub fn refreshHolderStopped(s: Store, key: Key, started_ms: i64, step_ms: i64) bool {
        var dir = s.openDir() catch return true;
        defer dir.close();
        const name = refreshLockName(key);
        return refreshWaitExpired(leased_lock.readStamp(&dir, &name), leased_lock.readStamp(&dir, lock_file_name), started_ms, io_mod.awakeMilliTimestamp(), step_ms);
    }

    pub const Locked = struct {
        dir: io_mod.VerifiedDir,
        lock: io_mod.TimedAdvisoryLock,
        /// The lease and its last stamp, on the awake clock: the Keychain
        /// store's lock and refresh locks have one, the file store's doesn't.
        lease: ?Lease = null,

        pub const Lease = struct { kind: enum { store, refresh }, stamp_ms: i64 };

        /// Stamps a leased lock again, before the next step its holder takes.
        pub fn restamp(l: *Locked) void {
            const lease = if (l.lease) |*lease| lease else return;
            lease.stamp_ms = leased_lock.restamp(l.lock.file, "mcp", switch (lease.kind) {
                .store => "MCP store",
                .refresh => "MCP refresh",
            });
        }

        pub fn release(l: *Locked) void {
            if (l.lease) |lease| debug_trace.logf("mcp", "MCP {s} lock released stamp={d} at={d}", .{
                @tagName(lease.kind),
                lease.stamp_ms,
                io_mod.awakeMilliTimestamp(),
            });
            l.lock.release();
            l.dir.close();
        }
    };

    fn openDir(s: Store) !io_mod.VerifiedDir {
        var home = io_mod.VerifiedDir{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(s.home), .{ .iterate = true }) };
        defer home.close();
        var root = try io_mod.openOrCreateVerifiedPrivateDir(&home, profile_paths.rootName());
        defer root.close();
        return io_mod.openOrCreateVerifiedPrivateDir(&root, profile_paths.mcp_credentials_dir_name);
    }

    /// The file store's lock waits `lock_deadline_ms`. The Keychain store's
    /// work under its lock is two calls to `osascript` that can each take
    /// seconds, so that lock is leased (`leased_lock`, `tests/tla/mcp_host/StoreLockBudget.tla`):
    /// the spark that takes it writes the time, on the awake clock, into the lock
    /// file, and again before each Keychain call (`read`, `write`), and each
    /// call ends within `call_budget_ms` of its stamp. A waiting spark gives up
    /// only when the stamp, or its own start if later, is
    /// `call_budget_ms + hold_slack_ms` old, so a live holder is never given
    /// up on however many calls it makes or spark take the lock in turn; one
    /// frozen holding it (ctrl+z) costs a waiter 12 s. A stamp from the
    /// future, a damaged one, or none, as from an older spark, counts as the
    /// waiter's start.
    fn lock(s: Store) !Locked {
        var dir = try s.openDir();
        errdefer dir.close();
        if (s.backend == .file) return .{
            .dir = dir,
            .lock = try io_mod.acquireTimedAdvisoryLock(&dir, lock_file_name, lock_deadline_ms),
        };
        const taken = try leased_lock.acquire(&dir, lock_file_name, io_mod.awakeMilliTimestamp(), call_budget_ms + hold_slack_ms, .{}, "mcp", "MCP store");
        return .{ .dir = dir, .lock = taken.lock, .lease = .{ .kind = .store, .stamp_ms = taken.stamp_ms } };
    }

    /// The store as saved, empty when there is none. One that doesn't parse or
    /// has another version fails with `error.CredentialStoreUnreadable`.
    fn read(s: Store, alloc: Allocator, locked: *Locked) !Doc {
        // The Keychain call has its whole budget from a fresh stamp.
        locked.restamp();
        const bytes = (switch (s.backend) {
            .keychain => native_keychain.loadMcpHostCredentials(alloc) catch |err| switch (err) {
                error.KeychainItemNotFound => null,
                else => return err,
            },
            .file => try readFile(alloc, &locked.dir),
        }) orelse return .{};
        defer secret.zeroAndFree(alloc, bytes);
        return Doc.parse(alloc, bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                debug_trace.logf("mcp", "MCP credential store unreadable, left as it is err={s}", .{@errorName(err)});
                return error.CredentialStoreUnreadable;
            },
        };
    }

    fn write(s: Store, alloc: Allocator, locked: *Locked, doc: Doc) !void {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer {
            std.crypto.secureZero(u8, out.writer.buffer);
            out.deinit();
        }
        try doc.encode(&out.writer);
        locked.restamp();
        switch (s.backend) {
            .keychain => try native_keychain.storeMcpHostCredentials(out.written()),
            .file => try io_mod.durableReplaceVerified(alloc, &locked.dir, file_name, out.written()),
        }
    }
};

/// Pure: whether a waiter for a refresh lock goes ahead at `now_ms`, with the
/// refresh lock's stamp `refresh_ms` and the store lock's `store_ms`
/// (`Store.refreshHolderStopped`).
fn refreshWaitExpired(refresh_ms: ?i64, store_ms: ?i64, started_ms: i64, now_ms: i64, step_ms: i64) bool {
    const step_over = leased_lock.stampFrom(refresh_ms, started_ms, now_ms) +| step_ms;
    const lease_over = leased_lock.stampFrom(store_ms, started_ms, now_ms) +| (call_budget_ms + hold_slack_ms);
    return now_ms >= @max(step_over, lease_over) +| hold_slack_ms;
}

/// What tells two saved credentials apart, without keeping either.
pub fn digest(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

/// Older builds lock `refresh-<digest>.lock` for the same login in their own
/// store, and its tokens are not this store's.
const refresh_lock_prefix = "refresh-v3-";
const refresh_lock_suffix = ".lock";
const RefreshLockName = [refresh_lock_prefix.len + 16 + refresh_lock_suffix.len]u8;

/// The prefix and 16 hex digits of the key's digest: one file per login.
fn refreshLockName(key: Key) RefreshLockName {
    var h: std.crypto.hash.sha2.Sha256 = .init(.{});
    for ([_][]const u8{ key.name, key.url, key.workspace orelse "" }) |part| {
        h.update(part);
        h.update(&.{0});
    }
    var d: [32]u8 = undefined;
    h.final(&d);
    var name: RefreshLockName = undefined;
    @memcpy(name[0..refresh_lock_prefix.len], refresh_lock_prefix);
    @memcpy(name[refresh_lock_prefix.len..][0..16], &std.fmt.bytesToHex(d[0..8].*, .lower));
    @memcpy(name[refresh_lock_prefix.len + 16 ..], refresh_lock_suffix);
    return name;
}

/// The saved credentials as one read of the store found them.
pub const Snapshot = struct {
    doc: Doc,

    /// The credential saved under `key`, or null. Borrowed from the
    /// snapshot until `deinit`.
    pub fn get(s: *const Snapshot, key: Key) ?[]const u8 {
        const i = s.doc.find(key) orelse return null;
        return s.doc.entries.items[i].credential;
    }

    /// Zeroes the credentials and frees them.
    pub fn deinit(s: *Snapshot, alloc: Allocator) void {
        s.doc.deinit(alloc);
        s.* = undefined;
    }
};

/// The store file's bytes, or null when there is none. A path that isn't a
/// regular file, such as a fifo, fails with `error.CredentialStoreUnreadable`
/// instead of waiting for a writer.
fn readFile(alloc: Allocator, dir: *io_mod.VerifiedDir) !?[]u8 {
    var file = io_mod.openExistingReadOnlyRegularFile(dir.dir, file_name, .no_follow) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.DurablePathUnsafe => {
            debug_trace.logf("mcp", "MCP credential store isn't a regular file, left as it is", .{});
            return error.CredentialStoreUnreadable;
        },
        else => return err,
    };
    defer file.close(io_mod.getIo());
    return try io_mod.readFileToEnd(alloc, &file, max_store_bytes);
}

const Entry = struct {
    name: []u8,
    url: []u8,
    /// The workspace a `.mcp.json` server's credential belongs to; null for others.
    workspace: ?[]u8 = null,
    credential: []u8,

    /// Copies of `key` and `credential`, owned by `alloc`.
    fn of(alloc: Allocator, key: Key, credential: []const u8) Allocator.Error!Entry {
        const name = try alloc.dupe(u8, key.name);
        errdefer alloc.free(name);
        const url = try alloc.dupe(u8, key.url);
        errdefer alloc.free(url);
        const workspace = if (key.workspace) |w| try alloc.dupe(u8, w) else null;
        errdefer if (workspace) |w| alloc.free(w);
        return .{ .name = name, .url = url, .workspace = workspace, .credential = try alloc.dupe(u8, credential) };
    }

    fn deinit(e: *Entry, alloc: Allocator) void {
        alloc.free(e.name);
        alloc.free(e.url);
        if (e.workspace) |w| alloc.free(w);
        secret.zeroAndFree(alloc, e.credential);
    }
};

const Doc = struct {
    entries: std.ArrayList(Entry) = .empty,

    fn deinit(d: *Doc, alloc: Allocator) void {
        for (d.entries.items) |*e| e.deinit(alloc);
        d.entries.deinit(alloc);
    }

    /// The document as `Store.write` saves it. Version 2, the format
    /// `credentials-v2.json` holds. No build that reads only version 1 opens
    /// this store: those read a version-2 document as empty and write over
    /// it. A profile server's entry has no workspace field.
    fn encode(d: *const Doc, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try std.json.Stringify.value(.{ .version = 2, .servers = d.entries.items }, .{ .emit_null_optional_fields = false }, w);
    }

    fn find(d: *const Doc, key: Key) ?usize {
        for (d.entries.items, 0..) |e, i| if (key.matches(e)) return i;
        return null;
    }

    fn parse(alloc: Allocator, bytes: []const u8) !Doc {
        // An older spark's `imported_v1` flag is ignored.
        const Saved = struct {
            version: u32,
            servers: []const struct { name: []const u8, url: []const u8, workspace: ?[]const u8 = null, credential: []const u8 },
        };
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const saved = try json_decode.parseFromSliceLeaky(Saved, arena.allocator(), bytes, .{ .ignore_unknown_fields = true });
        if (saved.version != 1 and saved.version != 2) return error.UnsupportedVersion;
        var doc: Doc = .{};
        errdefer doc.deinit(alloc);
        try doc.entries.ensureTotalCapacity(alloc, saved.servers.len);
        for (saved.servers) |entry| {
            doc.entries.appendAssumeCapacity(try Entry.of(alloc, .{ .name = entry.name, .url = entry.url, .workspace = entry.workspace }, entry.credential));
            std.crypto.secureZero(u8, @constCast(entry.credential));
        }
        return doc;
    }
};

const testing = std.testing;

fn testHome(tmp: *testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, ".");
}

test "one snapshot holds every server's credential" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(&tmp);
    defer testing.allocator.free(home);
    const store: Store = .{ .home = home, .backend = .file };
    const repo: Key = .{ .name = "linear", .url = "https://mcp.linear.app/mcp", .workspace = "/Users/example/repo" };
    try store.put(testing.allocator, .{ .name = "linear", .url = "https://mcp.linear.app/mcp" }, "{\"access\":\"l1\"}");
    try store.put(testing.allocator, .{ .name = "plain", .url = "https://mcp.plain.com/mcp" }, "{\"access\":\"p1\"}");
    try store.put(testing.allocator, repo, "{\"access\":\"r1\"}");

    var saved = try store.snapshot(testing.allocator);
    defer saved.deinit(testing.allocator);
    try testing.expectEqualStrings("{\"access\":\"l1\"}", saved.get(.{ .name = "linear", .url = "https://mcp.linear.app/mcp" }).?);
    try testing.expectEqualStrings("{\"access\":\"p1\"}", saved.get(.{ .name = "plain", .url = "https://mcp.plain.com/mcp" }).?);
    // A workspace's server has its own, apart from the profile's.
    try testing.expectEqualStrings("{\"access\":\"r1\"}", saved.get(repo).?);
    // A credential is kept per name and URL.
    try testing.expectEqual(@as(?[]const u8, null), saved.get(.{ .name = "plain", .url = "https://mcp.linear.app/mcp" }));
    try testing.expectEqual(@as(?[]const u8, null), saved.get(.{ .name = "slack", .url = "https://mcp.slack.com/mcp" }));
}

/// v1's store with a login for linear, and one the engine can't use.
fn writeV1(home: []const u8) !void {
    var home_dir = io_mod.VerifiedDir{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) };
    defer home_dir.close();
    var root = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name);
    defer root.close();
    var dir = try io_mod.openOrCreateVerifiedPrivateDir(&root, profile_paths.mcp_credentials_dir_name);
    defer dir.close();
    const entry =
        \\"endpoint":"https://mcp.linear.app/mcp","resource":"https://mcp.linear.app/mcp","issuer":"https://linear.app",
        \\"client_id":"c1","client_secret":null,"access_token":"v1-access","refresh_token":"v1-refresh","scope":"read",
        \\"token_endpoint_auth_method":"none","authorization_endpoint":"https://linear.app/oauth/authorize",
        \\"token_endpoint":"https://linear.app/oauth/token","revocation_endpoint":null,"expires_at_ms":null
    ;
    try io_mod.durableReplaceVerified(testing.allocator, &dir, profile_paths.mcp_credentials_file_name, "{\"version\":1,\"credentials\":[" ++
        "{\"server_identity\":\"linear\",\"token_type\":\"Bearer\"," ++ entry ++ "}," ++
        "{\"server_identity\":\"bound\",\"token_type\":\"DPoP\"," ++ entry ++ "}]}");
}

/// A document that parses is saved as version 2 and reads back the same, so
/// a write never leaves a store this spark can't read.
fn fuzzStoreDocument(_: void, smith: *std.testing.Smith) !void {
    var buffer: [2048]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buffer, &.{
        .rangeAtMost(u8, 0x20, 0x7e, 8),
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .value(u8, '{', 4),
        .value(u8, '}', 4),
        .value(u8, '[', 3),
        .value(u8, ']', 3),
        .value(u8, '"', 4),
        .value(u8, '\\', 2),
        .value(u8, ':', 3),
        .value(u8, ',', 3),
    });
    var doc = Doc.parse(testing.allocator, buffer[0..len]) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer doc.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try doc.encode(&out.writer);
    var again = try Doc.parse(testing.allocator, out.written());
    defer again.deinit(testing.allocator);
    try testing.expectEqual(doc.entries.items.len, again.entries.items.len);
    for (doc.entries.items, again.entries.items) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expectEqualStrings(a.url, b.url);
        try testing.expectEqualStrings(a.credential, b.credential);
        try testing.expectEqualStrings(a.workspace orelse "", b.workspace orelse "");
        try testing.expectEqual(a.workspace == null, b.workspace == null);
    }
}

/// For any stamp in the lock file and any time a waiter checks, it gives up
/// no sooner than 12 s after its start, never within 12 s of a stamp written
/// since it started, and always once both are 12 s old. A refresh lock's
/// waiter, with that stamp as the store's and another as the refresh lock's,
/// goes ahead no sooner than both rules allow from its start, never while
/// either stamp is fresh, and always once both are old.
fn fuzzLockWait(_: void, smith: *std.testing.Smith) !void {
    const started = smith.valueRangeAtMost(i64, 0, 1 << 40);
    const now = started + smith.valueRangeAtMost(i64, 0, 4 * (call_budget_ms + hold_slack_ms));
    const stamp: ?i64 = switch (smith.valueRangeAtMost(u8, 0, 3)) {
        0 => null,
        1 => smith.value(i64),
        2 => started + smith.valueRangeAtMost(i64, -2 * call_budget_ms, 4 * call_budget_ms),
        else => now - smith.valueRangeAtMost(i64, 0, 2 * (call_budget_ms + hold_slack_ms)),
    };
    // The stamp as the lock file holds it, read back.
    var bytes: [8]u8 = undefined;
    if (stamp) |t| std.mem.writeInt(i64, &bytes, t, .little);
    const read_back: ?i64 = if (stamp != null) std.mem.readInt(i64, &bytes, .little) else null;
    try testing.expectEqual(stamp, read_back);

    const wait = call_budget_ms + hold_slack_ms;
    const expired = leased_lock.expired(read_back, started, now, wait);
    if (expired) try testing.expect(now - started >= wait);
    const live = if (read_back) |t| t > started and t <= now else false;
    if (live and now - read_back.? < wait) try testing.expect(!expired);
    const from = if (live) read_back.? else started;
    if (now - from >= wait) try testing.expect(expired);

    const step = smith.valueRangeAtMost(i64, 0, 60_000);
    const refresh: ?i64 = switch (smith.valueRangeAtMost(u8, 0, 3)) {
        0 => null,
        1 => smith.value(i64),
        2 => started + smith.valueRangeAtMost(i64, -2 * step, 4 * step),
        else => now - smith.valueRangeAtMost(i64, 0, 2 * (step + hold_slack_ms)),
    };
    const ahead = refreshWaitExpired(refresh, read_back, started, now, step);
    if (ahead) try testing.expect(now - started >= @max(step, wait) + hold_slack_ms);
    const refresh_live = if (refresh) |t| t > started and t <= now else false;
    if (refresh_live and now - refresh.? < step + hold_slack_ms) try testing.expect(!ahead);
    if (live and now - read_back.? < wait + hold_slack_ms) try testing.expect(!ahead);
    const refresh_from = if (refresh_live) refresh.? else started;
    if (now - refresh_from >= step + hold_slack_ms and now - from >= wait + hold_slack_ms) try testing.expect(ahead);
}

const test_path = ".spark/" ++ profile_paths.mcp_credentials_dir_name ++ "/" ++ file_name;

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
