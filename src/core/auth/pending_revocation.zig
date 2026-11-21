//! Sign-outs that a provider did not confirm, kept so that spark can revoke
//! their tokens later.
//!
//! A logout keeps the tokens here before it sends the revocation and forgets
//! them once the provider confirms it, so a refused, unanswered, or
//! interrupted revocation leaves them kept. The next `spark login` or
//! `spark logout` for the same provider sends them again (`retry`), and so does
//! every TUI start, on a worker. A sign-out kept longer than `max_age_ms` is
//! dropped without a request.
//!
//! MCP logins keep theirs the same way, with what their revocation needs
//! (`mcp_host/kept_sign_outs.zig`), and `spark mcp login` and `spark mcp logout`
//! retry them.
//!
//! Codex and Grok keep theirs in a private file in the profile folder, next to
//! their logins. The spark login keeps its in the macOS Keychain when its login is
//! there, and MCP logins keep theirs where their credential store is
//! (`mcpPlace`), each with a marker file that holds no token, so that a start
//! with nothing kept reads no Keychain item; otherwise in a private profile
//! file. Each source's record changes only under its own lock file, which is
//! held for one read and one write but never across a request to the
//! provider.
//!
//! The spark that sends a sign-out leases it for as long as that can take, so
//! another spark's retry at the same time does not send it again. A lease whose
//! process is gone, killed during the request, no longer holds it back.

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const native_keychain = @import("../hosts/native_keychain.zig");
const io_mod = @import("../shared/io.zig");
const leased_lock = @import("../shared/leased_lock.zig");
const process_tree = @import("../execution/process_tree.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const oauth = @import("oauth.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");
const session_presence = @import("session_presence.zig");

const Allocator = std.mem.Allocator;

pub const Source = enum {
    mcp,

    fn files(self: Source) Files {
        return switch (self) {
            .mcp => .{ .record = "mcp-revocations.json", .lock = "mcp-revocations.lock", .label = "MCP kept sign-outs", .keychain_marker = "mcp-revocations.keychain" },
        };
    }
};

const Files = struct {
    record: []const u8,
    lock: []const u8,
    /// Names the lock in debug trace lines.
    label: []const u8,
    /// The marker file while the record is in the Keychain. Empty for a
    /// source that never keeps it there.
    keychain_marker: []const u8 = "",
};

/// What a warning adds when a sign-out's tokens are kept to revoke later.
pub const retry_later = "spark will try again later";

/// How long a sign-out stays kept. Its tokens have most likely expired at the
/// provider by then.
pub const max_age_ms: i64 = 30 * std.time.ms_per_day;
/// The most sign-outs kept for one source. Keeping one more drops the oldest.
pub const max_entries: usize = 8;
/// One sign-out always fits: its nine fields, each escaped six bytes for one
/// at most, take under 220 KiB.
pub const max_record_bytes: usize = 256 * 1024;
const max_field_bytes: usize = 4 * 1024;
const schema_version: i64 = 1;
/// The lock is held for one read and one write, a Keychain call at most each,
/// and its holder stamps it before each (`leased_lock`).
const lock_wait_ms: i64 = native_keychain.keychain_call_ms + leased_lock.slack_ms;

/// The tokens of one sign-out, and what sending its revocation again takes.
/// Borrowed. A field its source does not use is empty.
pub const Tokens = struct {
    /// Identifies the sign-out. For an MCP login, the token its revocation
    /// sends: the refresh token when it has one, else the access token.
    refresh_token: []const u8,
    /// The spark login's access token and issuer, and the client id of the spark
    /// login and of an MCP login.
    access_token: []const u8 = "",
    issuer: []const u8 = "",
    client_id: []const u8 = "",
    /// An MCP login's revocation (`mcp_host/kept_sign_outs.zig`): the kind of
    /// token `refresh_token` is, where it goes, how the client authenticates,
    /// and the server signed in to, which decides the endpoints it may use.
    token_type_hint: []const u8 = "",
    revocation_endpoint: []const u8 = "",
    client_secret: []const u8 = "",
    client_auth: []const u8 = "",
    server_url: []const u8 = "",

    fn valid(self: Tokens) bool {
        if (self.refresh_token.len == 0) return false;
        inline for (field_names) |name| {
            if (@field(self, name).len > max_field_bytes) return false;
        }
        return true;
    }
};

/// Every field of `Tokens`, in the order a record writes them.
const field_names = .{ "refresh_token", "access_token", "issuer", "client_id", "token_type_hint", "revocation_endpoint", "client_secret", "client_auth", "server_url" };
/// The fields after `refresh_token`, which a record leaves out when empty.
const optional_field_names = .{ "access_token", "issuer", "client_id", "token_type_hint", "revocation_endpoint", "client_secret", "client_auth", "server_url" };

comptime {
    std.debug.assert(field_names.len == @typeInfo(Tokens).@"struct".field_names.len);
    std.debug.assert(optional_field_names.len + 1 == field_names.len);
}

/// The spark that is sending a sign-out now, until `until_ms` on the wall clock.
const Lease = struct {
    pid: i64,
    until_ms: i64,

    /// A lease for this process, for as long as sending one sign-out of
    /// `source` can take.
    fn mine(source: Source, now_ms: i64) Lease {
        return .{ .pid = processId(), .until_ms = now_ms +| sendBudgetMs(source) };
    }
};

/// How long sending one sign-out can take: each of its requests within the
/// transport's limit, plus the lock's slack.
fn sendBudgetMs(_: Source) i64 {
    return oauth_transport.default_request_timeout_ms + leased_lock.slack_ms;
}

fn processId() i64 {
    if (comptime builtin.target.os.tag == .windows) return 0;
    return std.c.getpid();
}

/// A zombie, an spark that exited before its parent reaped it, counts as gone.
/// A check that fails counts as alive, so the lease still ends at its time.
fn processAlive(alloc: Allocator, pid: i64) bool {
    if (comptime builtin.target.os.tag == .windows) return false;
    if (pid <= 0 or pid > std.math.maxInt(std.posix.pid_t)) return false;
    return process_tree.processIsAlive(alloc, @intCast(pid)) catch true;
}

/// One kept sign-out. Every field is owned and zeroed when released; release
/// it with `deinit`.
const Entry = struct {
    saved_at_ms: i64,
    /// The fields of `Tokens`, by the same names.
    refresh_token: []u8 = &.{},
    access_token: []u8 = &.{},
    issuer: []u8 = &.{},
    client_id: []u8 = &.{},
    token_type_hint: []u8 = &.{},
    revocation_endpoint: []u8 = &.{},
    client_secret: []u8 = &.{},
    client_auth: []u8 = &.{},
    server_url: []u8 = &.{},
    /// Who is sending it now, when anyone is.
    lease: ?Lease = null,

    fn clone(self: Entry, alloc: Allocator) !Entry {
        var copy = try init(alloc, self.saved_at_ms, self.asTokens());
        copy.lease = self.lease;
        return copy;
    }

    /// Whether a live spark, this one included, is sending it now.
    fn beingSent(self: Entry, alloc: Allocator, now_ms: i64) bool {
        const lease = self.lease orelse return false;
        return lease.until_ms > now_ms and processAlive(alloc, lease.pid);
    }

    fn init(alloc: Allocator, saved_at_ms: i64, tokens: Tokens) !Entry {
        var entry: Entry = .{ .saved_at_ms = saved_at_ms };
        // A field not copied yet is empty, which `deinit` skips.
        errdefer entry.deinit(alloc);
        inline for (field_names) |name| {
            const value = @field(tokens, name);
            if (value.len != 0) @field(entry, name) = try alloc.dupe(u8, value);
        }
        return entry;
    }

    fn deinit(self: *Entry, alloc: Allocator) void {
        inline for (field_names) |name| secret.zeroAndFree(alloc, @field(self, name));
        self.* = undefined;
    }

    fn asTokens(self: Entry) Tokens {
        var tokens: Tokens = .{ .refresh_token = self.refresh_token };
        inline for (optional_field_names) |name| @field(tokens, name) = @field(self, name);
        return tokens;
    }
};

/// The kept sign-outs of one source, oldest first.
const List = struct {
    entries: std.ArrayList(Entry) = .empty,

    fn deinit(self: *List, alloc: Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(alloc);
        self.entries.deinit(alloc);
        self.* = undefined;
    }

    fn find(self: List, refresh_token: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.refresh_token, refresh_token)) return index;
        }
        return null;
    }

    fn removeAt(self: *List, alloc: Allocator, index: usize) void {
        var removed = self.entries.orderedRemove(index);
        removed.deinit(alloc);
    }

    /// Drops every sign-out kept longer than `max_age_ms` and returns whether
    /// the list changed. A saved time after `now_ms`, from a clock that was
    /// set back, becomes `now_ms`, so that sign-out still expires.
    fn expire(self: *List, alloc: Allocator, source: Source, now_ms: i64) bool {
        var changed = false;
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = &self.entries.items[index];
            if (entry.saved_at_ms > now_ms) {
                entry.saved_at_ms = now_ms;
                changed = true;
            }
            const age_ms = now_ms -| entry.saved_at_ms;
            if (age_ms > max_age_ms) {
                debug_trace.logf("auth", "kept sign-out dropped reason=expired source={t} age_ms={d}", .{ source, age_ms });
                self.removeAt(alloc, index);
                changed = true;
                continue;
            }
            index += 1;
        }
        return changed;
    }

    /// Adds a sign-out unless its refresh token is already kept, with
    /// `lease` when its sender is about to send it. Past `max_entries`,
    /// drops the oldest.
    fn add(self: *List, alloc: Allocator, source: Source, tokens: Tokens, now_ms: i64, lease: ?Lease) !void {
        if (self.find(tokens.refresh_token)) |index| {
            if (lease != null) self.entries.items[index].lease = lease;
            return;
        }
        var entry = try Entry.init(alloc, now_ms, tokens);
        errdefer entry.deinit(alloc);
        entry.lease = lease;
        try self.entries.append(alloc, entry);
        while (self.entries.items.len > max_entries) {
            debug_trace.logf("auth", "kept sign-out dropped reason=limit source={t} limit={d}", .{ source, max_entries });
            self.removeAt(alloc, 0);
        }
    }

    fn remove(self: *List, alloc: Allocator, refresh_token: []const u8) bool {
        const index = self.find(refresh_token) orelse return false;
        self.removeAt(alloc, index);
        return true;
    }
};

/// Reads a record that `stringify` wrote. A sign-out whose refresh token came
/// earlier is skipped, and past `max_entries` the oldest are dropped.
fn parse(alloc: Allocator, bytes: []const u8) !List {
    if (bytes.len > max_record_bytes) return error.InvalidKeptSignOuts;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidKeptSignOuts,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidKeptSignOuts;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidKeptSignOuts;
    if (version != .integer or version.integer != schema_version) return error.InvalidKeptSignOuts;
    const entries = object.get("entries") orelse return error.InvalidKeptSignOuts;
    if (entries != .array) return error.InvalidKeptSignOuts;

    var list: List = .{};
    errdefer list.deinit(alloc);
    for (entries.array.items) |item| {
        if (item != .object) return error.InvalidKeptSignOuts;
        const saved_at = item.object.get("saved_at_ms") orelse return error.InvalidKeptSignOuts;
        if (saved_at != .integer) return error.InvalidKeptSignOuts;
        var tokens: Tokens = .{ .refresh_token = try field(item.object, "refresh_token", .required) };
        inline for (optional_field_names) |name| @field(tokens, name) = try field(item.object, name, .optional);
        if (!tokens.valid()) return error.InvalidKeptSignOuts;
        const pid = try integerField(item.object, "sender_pid");
        const until_ms = try integerField(item.object, "sending_until_ms");
        if (list.find(tokens.refresh_token) != null) continue;
        var entry = try Entry.init(alloc, saved_at.integer, tokens);
        errdefer entry.deinit(alloc);
        if (pid != 0) entry.lease = .{ .pid = pid, .until_ms = until_ms };
        try list.entries.append(alloc, entry);
    }
    while (list.entries.items.len > max_entries) list.removeAt(alloc, 0);
    return list;
}

/// An optional integer field, 0 when it is absent.
fn integerField(object: std.json.ObjectMap, name: []const u8) !i64 {
    const value = object.get(name) orelse return 0;
    if (value != .integer) return error.InvalidKeptSignOuts;
    return value.integer;
}

fn field(object: std.json.ObjectMap, name: []const u8, presence: enum { required, optional }) ![]const u8 {
    const value = object.get(name) orelse return if (presence == .required) error.InvalidKeptSignOuts else "";
    if (value != .string) return error.InvalidKeptSignOuts;
    return value.string;
}

/// The record's text. The caller owns it and releases it with
/// `secret.zeroAndFree`.
fn stringify(alloc: Allocator, list: List) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{{\"version\":{d},\"entries\":[", .{schema_version});
    for (list.entries.items, 0..) |entry, index| {
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.print("{{\"saved_at_ms\":{d},\"refresh_token\":", .{entry.saved_at_ms});
        try std.json.Stringify.value(entry.refresh_token, .{}, &out.writer);
        inline for (optional_field_names) |name| {
            const value = @field(entry, name);
            if (value.len != 0) {
                try out.writer.writeAll(",\"" ++ name ++ "\":");
                try std.json.Stringify.value(value, .{}, &out.writer);
            }
        }
        if (entry.lease) |lease| {
            try out.writer.print(",\"sender_pid\":{d},\"sending_until_ms\":{d}", .{ lease.pid, lease.until_ms });
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}\n");
    return out.toOwnedSlice();
}

/// The record's text, after dropping the oldest sign-outs until it fits
/// `max_record_bytes`. One sign-out always fits (`Tokens.valid`).
fn fittedText(alloc: Allocator, source: Source, list: *List) ![]u8 {
    while (true) {
        const text = try stringify(alloc, list.*);
        if (text.len <= max_record_bytes or list.entries.items.len <= 1) return text;
        secret.zeroAndFree(alloc, text);
        debug_trace.logf("auth", "kept sign-out dropped reason=size source={t} limit={d}", .{ source, max_record_bytes });
        list.removeAt(alloc, 0);
    }
}

/// Holds the spark login's record in the Keychain.
const KeychainBackend = struct {
    context: ?*anyopaque = null,
    /// Null when there is no item.
    load_fn: *const fn (?*anyopaque, Allocator) anyerror!?[]u8,
    store_fn: *const fn (?*anyopaque, []const u8) anyerror!void,
    delete_fn: *const fn (?*anyopaque, Allocator) anyerror!void,
};

const native_keychain_backend: KeychainBackend = .{
    .load_fn = nativeKeychainLoad,
    .store_fn = nativeKeychainStore,
    .delete_fn = nativeKeychainDelete,
};

fn nativeKeychainLoad(_: ?*anyopaque, alloc: Allocator) anyerror!?[]u8 {
    return native_keychain.loadOAuthPendingRevocations(alloc) catch |err| switch (err) {
        error.KeychainItemNotFound => null,
        else => err,
    };
}

fn nativeKeychainStore(_: ?*anyopaque, value: []const u8) anyerror!void {
    return native_keychain.storeOAuthPendingRevocations(value);
}

fn nativeKeychainDelete(_: ?*anyopaque, alloc: Allocator) anyerror!void {
    _ = try native_keychain.deleteOAuthPendingRevocations(alloc);
}

/// MCP logins' record, in its own Keychain item.
const mcp_keychain_backend: KeychainBackend = .{
    .load_fn = mcpKeychainLoad,
    .store_fn = mcpKeychainStore,
    .delete_fn = mcpKeychainDelete,
};

fn mcpKeychainLoad(_: ?*anyopaque, alloc: Allocator) anyerror!?[]u8 {
    return native_keychain.loadMcpPendingRevocations(alloc) catch |err| switch (err) {
        error.KeychainItemNotFound => null,
        else => err,
    };
}

fn mcpKeychainStore(_: ?*anyopaque, value: []const u8) anyerror!void {
    return native_keychain.storeMcpPendingRevocations(value);
}

fn mcpKeychainDelete(_: ?*anyopaque, alloc: Allocator) anyerror!void {
    _ = try native_keychain.deleteMcpPendingRevocations(alloc);
}

/// Whether opening a record may create the profile folder.
const Open = enum { existing, create };

/// Where a source's record is.
pub const Place = struct {
    source: Source,
    /// Set for the spark login when its login is in the Keychain, and for MCP
    /// logins when their credential store is.
    keychain: ?KeychainBackend = null,
    /// The home folder whose profile folder holds the record; null for the
    /// process's own.
    home: ?[]const u8 = null,
    /// The folder that holds the profile folder, in place of `home`'s, set
    /// by tests.
    parent: ?std.Io.Dir = null,

    fn of(source: Source) Place {
        // libfx hosts keep logins themselves; the Keychain code is macOS-only.
        return .{ .source = source };
    }

    /// The profile folder, or null when there is none and `open` is `.existing`.
    fn openProfile(self: Place, open: Open) !?io_mod.VerifiedDir {
        var opened: ?std.Io.Dir = null;
        defer if (opened) |dir| dir.close(io_mod.getIo());
        const parent = self.parent orelse blk: {
            const home = self.home orelse io_mod.homeDir() orelse return null;
            opened = std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(home), .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => return err,
            };
            break :blk opened.?;
        };
        if (open == .create) return try io_mod.openOrCreateVerifiedPrivateDirFromDir(parent, profile_paths.rootName());
        var verified_parent: io_mod.VerifiedDir = .{ .dir = parent };
        return openExistingPrivateFxDir(&verified_parent) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    /// Whether a record seems to exist, checked without the lock: a record
    /// that another spark writes at the same time waits for the next retry.
    fn recordExists(self: Place) !bool {
        var spark_dir = (try self.openProfile(.existing)) orelse return false;
        defer spark_dir.close();
        const files = self.source.files();
        const name = if (self.keychain != null) files.keychain_marker else files.record;
        var current = (try session_presence.openCurrent(spark_dir.dir, name)) orelse return false;
        current.file.close(io_mod.getIo());
        return true;
    }
};

fn openExistingPrivateFxDir(home_dir: *io_mod.VerifiedDir) !io_mod.VerifiedDir {
    var dir = try home_dir.dir.openDir(io_mod.getIo(), profile_paths.rootName(), .{
        .iterate = true,
        .follow_symlinks = false,
    });
    errdefer dir.close(io_mod.getIo());
    const initial_stat = try dir.stat(io_mod.getIo());
    if (initial_stat.kind != .directory) return error.DurablePathUnsafe;
    if (initial_stat.permissions.toMode() & 0o200 == 0) return error.PrivateStatePermissionsUnsupported;
    dir.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(0o700)) catch {
        return error.PrivateStatePermissionsUnsupported;
    };
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory or stat.permissions.toMode() & 0o777 != 0o700) {
        return error.PrivateStatePermissionsUnsupported;
    }
    return .{ .dir = dir };
}

/// A source's record, read and written under its lock.
const Mutation = struct {
    place: Place,
    spark_dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,
    /// The lease's last stamp, on the awake clock.
    stamp_ms: i64,
    /// Set by `load` when it dropped a record it could not read.
    dropped_unreadable: bool = false,

    fn begin(place: Place, open: Open) !?Mutation {
        var spark_dir = (try place.openProfile(open)) orelse return null;
        errdefer spark_dir.close();
        const files = place.source.files();
        const taken = try leased_lock.acquire(&spark_dir, files.lock, io_mod.awakeMilliTimestamp(), lock_wait_ms, .{}, "auth", files.label);
        return .{ .place = place, .spark_dir = spark_dir, .lock = taken.lock, .stamp_ms = taken.stamp_ms };
    }

    fn deinit(self: *Mutation) void {
        self.lock.release();
        self.spark_dir.close();
        self.* = undefined;
    }

    /// Stamps the lease again before a Keychain call.
    fn restamp(self: *Mutation) void {
        self.stamp_ms = leased_lock.restamp(self.lock.file, "auth", self.place.source.files().label);
    }

    /// The kept sign-outs. A record that is unsafe or does not parse can never
    /// be revoked from, so it is dropped with a trace line; a record that
    /// cannot be read now returns the error, so nothing overwrites it.
    fn load(self: *Mutation, alloc: Allocator) !List {
        const bytes = (self.readRecord(alloc) catch |err| switch (err) {
            error.InsecureKeptSignOuts, error.StreamTooLong => return self.dropUnreadable(err),
            else => return err,
        }) orelse return .{};
        defer secret.zeroAndFree(alloc, bytes);
        return parse(alloc, bytes) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return self.dropUnreadable(err),
        };
    }

    fn dropUnreadable(self: *Mutation, err: anyerror) List {
        debug_trace.logf("auth", "kept sign-outs dropped reason=unreadable source={t} err={s}", .{ self.place.source, @errorName(err) });
        self.dropped_unreadable = true;
        return .{};
    }

    fn readRecord(self: *Mutation, alloc: Allocator) !?[]u8 {
        if (self.place.keychain) |keychain| {
            self.restamp();
            return keychain.load_fn(keychain.context, alloc);
        }
        var current = (try session_presence.openCurrent(self.spark_dir.dir, self.place.source.files().record)) orelse return null;
        defer current.file.close(io_mod.getIo());
        const stat = current.stat;
        if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) return error.InsecureKeptSignOuts;
        return try io_mod.readFileToEnd(alloc, &current.file, max_record_bytes + 1);
    }

    /// Writes `list`, or removes the record when it is empty.
    fn save(self: *Mutation, alloc: Allocator, list: *List) !void {
        if (list.entries.items.len == 0) return self.clear(alloc);
        const text = try fittedText(alloc, self.place.source, list);
        defer secret.zeroAndFree(alloc, text);
        if (self.place.keychain) |keychain| {
            self.restamp();
            try keychain.store_fn(keychain.context, text);
            try io_mod.durableReplaceVerified(alloc, &self.spark_dir, self.place.source.files().keychain_marker, "1\n");
            return;
        }
        try io_mod.durableReplaceVerified(alloc, &self.spark_dir, self.place.source.files().record, text);
    }

    fn clear(self: *Mutation, alloc: Allocator) !void {
        if (self.place.keychain) |keychain| {
            self.restamp();
            try keychain.delete_fn(keychain.context, alloc);
            return self.deleteFile(self.place.source.files().keychain_marker);
        }
        try self.deleteFile(self.place.source.files().record);
    }

    fn deleteFile(self: *Mutation, name: []const u8) !void {
        self.spark_dir.dir.deleteFile(io_mod.getIo(), name) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        const durable: io_mod.DurableOps = .{};
        durable.sync_dir(durable.ctx, self.spark_dir.dir) catch |err| {
            debug_trace.logf("auth", "kept sign-outs removal not durable source={t} err={s}", .{ self.place.source, @errorName(err) });
        };
    }
};

/// Where MCP logins keep their sign-outs: beside their credential store, in
/// the profile folder under `home`, or in the Keychain when `keychain` says
/// the store is there (`mcp_host/credentials.zig`). `home` is borrowed.
pub fn mcpPlace(home: []const u8, keychain: bool) Place {
    return .{ .source = .mcp, .home = home, .keychain = if (keychain) mcp_keychain_backend else null };
}

/// Whether MCP logins may have sign-outs kept under `home`, in the Keychain
/// or a file, checked by the file or marker alone, without the lock.
pub fn mcpMayHaveKept(home: []const u8) bool {
    for ([_]bool{ false, true }) |keychain| {
        const exists = mcpPlace(home, keychain).recordExists() catch |err| blk: {
            debug_trace.logf("auth", "kept sign-outs not looked for source=mcp err={s}", .{@errorName(err)});
            break :blk false;
        };
        if (exists) return true;
    }
    return false;
}

/// Keeps a sign-out's tokens before its revocation is sent, leased to this
/// process while it sends them. Returns whether they were kept; when they
/// were not, the debug trace says why. Not for `.mcp`, which uses `keepIn`.
pub fn keep(alloc: Allocator, source: Source, tokens: Tokens) bool {
    return keepIn(alloc, .of(source), tokens);
}

/// `keep`, at `place`.
pub fn keepIn(alloc: Allocator, place: Place, tokens: Tokens) bool {
    const now_ms = io_mod.milliTimestamp();
    keepAt(alloc, place, tokens, now_ms, .mine(place.source, now_ms)) catch |err| {
        debug_trace.logf("auth", "sign-out not kept source={t} err={s}", .{ place.source, @errorName(err) });
        return false;
    };
    return true;
}

fn keepAt(alloc: Allocator, place: Place, tokens: Tokens, now_ms: i64, lease: ?Lease) !void {
    if (!tokens.valid()) return error.InvalidKeptSignOut;
    var mutation = (try Mutation.begin(place, .create)) orelse return error.KeptSignOutsUnavailable;
    defer mutation.deinit();
    var list = try mutation.load(alloc);
    defer list.deinit(alloc);
    _ = list.expire(alloc, place.source, now_ms);
    try list.add(alloc, place.source, tokens, now_ms, lease);
    try mutation.save(alloc, &list);
}

/// Forgets a kept sign-out once its provider confirmed the revocation, or
/// when its login turned out not to be removed. A sign-out that cannot be
/// forgotten stays kept, and a later retry revokes it again, which is
/// harmless.
pub fn forget(alloc: Allocator, source: Source, refresh_token: []const u8) void {
    forgetIn(alloc, .of(source), refresh_token);
}

/// `forget`, at `place`.
pub fn forgetIn(alloc: Allocator, place: Place, refresh_token: []const u8) void {
    forgetAt(alloc, place, refresh_token) catch |err| {
        debug_trace.logf("auth", "kept sign-out not forgotten source={t} err={s}", .{ place.source, @errorName(err) });
    };
}

fn forgetAt(alloc: Allocator, place: Place, refresh_token: []const u8) !void {
    var mutation = (try Mutation.begin(place, .existing)) orelse return;
    defer mutation.deinit();
    var list = try mutation.load(alloc);
    defer list.deinit(alloc);
    if (!list.remove(alloc, refresh_token) and !mutation.dropped_unreadable) return;
    try mutation.save(alloc, &list);
}

/// Whether a failed revocation could succeed later. One that never can, such
/// as an issuer without a revocation endpoint, is not kept: a retry would only
/// repeat the request.
pub fn retryable(err: anyerror) bool {
    return switch (err) {
        error.RevocationEndpointMissing,
        error.InvalidE2EOAuthEndpoint,
        error.InvalidE2EOAuthIssuer,
        error.KeptSignOutUnusable,
        => false,
        else => true,
    };
}

/// Revokes one kept sign-out at its provider. An error that is not
/// `retryable`, such as `error.KeptSignOutUnusable`, means it can never be
/// revoked, and `retry` drops it.
pub const Revoker = struct {
    context: *const anyopaque,
    run: *const fn (context: *const anyopaque, alloc: Allocator, tokens: Tokens) anyerror!void,
};

pub const RetryOutcome = struct {
    /// Sign-outs the provider confirmed.
    revoked: usize = 0,
    /// A revocation failed; it and the ones after it stay kept.
    failed: bool = false,
};

/// Revokes every sign-out kept for `source`, oldest first, and forgets each
/// one that its provider confirms. It leaves alone the ones another live spark
/// is sending, and leases the rest while it sends them. A failure leaves the
/// rest of that provider's sign-outs for the next retry, since it is likely
/// down: for an MCP login, the rest of that server's, so the other servers'
/// still go. Runs `before` once, before the first request.
pub fn retry(alloc: Allocator, source: Source, revoker: Revoker, before: ?oauth.BeforeRevocation) RetryOutcome {
    return retryIn(alloc, .of(source), revoker, before);
}

/// `retry`, at `place`.
pub fn retryIn(alloc: Allocator, place: Place, revoker: Revoker, before: ?oauth.BeforeRevocation) RetryOutcome {
    return retryAt(alloc, place, io_mod.milliTimestamp(), revoker, before) catch |err| {
        debug_trace.logf("auth", "kept sign-outs not retried source={t} err={s}", .{ place.source, @errorName(err) });
        return .{ .failed = true };
    };
}

fn retryAt(alloc: Allocator, place: Place, now_ms: i64, revoker: Revoker, before: ?oauth.BeforeRevocation) !RetryOutcome {
    if (!try place.recordExists()) return .{};
    var kept = blk: {
        var mutation = (try Mutation.begin(place, .existing)) orelse return .{};
        defer mutation.deinit();
        var list = try mutation.load(alloc);
        defer list.deinit(alloc);
        var changed = list.expire(alloc, place.source, now_ms) or mutation.dropped_unreadable;
        var claimed: List = .{};
        errdefer claimed.deinit(alloc);
        const lease: Lease = .mine(place.source, now_ms);
        for (list.entries.items) |*entry| {
            if (entry.beingSent(alloc, now_ms)) continue;
            entry.lease = lease;
            try claimed.entries.append(alloc, try entry.clone(alloc));
            changed = true;
        }
        if (changed) try mutation.save(alloc, &list);
        break :blk claimed;
    };
    defer kept.deinit(alloc);

    var outcome: RetryOutcome = .{};
    if (kept.entries.items.len == 0) return outcome;
    if (before) |notice| notice.run(notice.context);
    // The servers that failed this retry, by `server_url`: each one is likely
    // down, so its later sign-outs wait for the next retry. Codex, Grok, and
    // the spark login keep no server URL, so their first failure stops the
    // retry; one MCP server that fails leaves the others to go on.
    var failed_servers: std.ArrayList([]const u8) = .empty;
    defer failed_servers.deinit(alloc);
    for (kept.entries.items) |entry| {
        const skipped = for (failed_servers.items) |url| {
            if (std.mem.eql(u8, url, entry.server_url)) break true;
        } else false;
        if (skipped) continue;
        revoker.run(revoker.context, alloc, entry.asTokens()) catch |err| switch (retryable(err)) {
            false => {
                debug_trace.logf("auth", "kept sign-out dropped reason=unusable source={t} err={s}", .{ place.source, @errorName(err) });
                forgetAt(alloc, place, entry.refresh_token) catch |forget_err| {
                    debug_trace.logf("auth", "kept sign-out not forgotten source={t} err={s}", .{ place.source, @errorName(forget_err) });
                };
                continue;
            },
            true => {
                debug_trace.logf("auth", "kept sign-out retry failed source={t} err={s}; it and its server's later ones stay kept", .{ place.source, @errorName(err) });
                outcome.failed = true;
                try failed_servers.append(alloc, entry.server_url);
                continue;
            },
        };
        outcome.revoked += 1;
        forgetAt(alloc, place, entry.refresh_token) catch |err| {
            debug_trace.logf("auth", "kept sign-out not forgotten source={t} err={s}", .{ place.source, @errorName(err) });
        };
    }
    return outcome;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const day_ms = std.time.ms_per_day;
/// The spark login's marker file while its record is in the Keychain.
const keychain_marker = Source.mcp.files().keychain_marker;

fn testPlace(tmp: *testing.TmpDir, source: Source) Place {
    return .{ .source = source, .parent = tmp.dir };
}

/// The refresh tokens kept at `place`, oldest first. The caller frees the
/// outer slice and each token.
fn keptTokens(alloc: Allocator, place: Place) ![][]u8 {
    var mutation = (try Mutation.begin(place, .existing)) orelse return &.{};
    defer mutation.deinit();
    var list = try mutation.load(alloc);
    defer list.deinit(alloc);
    const out = try alloc.alloc([]u8, list.entries.items.len);
    for (list.entries.items, 0..) |entry, index| out[index] = try alloc.dupe(u8, entry.refresh_token);
    return out;
}

fn freeTokens(alloc: Allocator, tokens: [][]u8) void {
    for (tokens) |token| alloc.free(token);
    alloc.free(tokens);
}

fn expectKept(place: Place, expected: []const []const u8) !void {
    const alloc = testing.allocator;
    const kept = try keptTokens(alloc, place);
    defer freeTokens(alloc, kept);
    try testing.expectEqual(expected.len, kept.len);
    for (expected, kept) |want, got| try testing.expectEqualStrings(want, got);
}

/// A revoker that refuses the tokens in `refuse`, records the ones it was
/// sent, and runs `during` once, before its first answer, as another spark can.
const FakeRevoker = struct {
    refuse: []const []const u8 = &.{},
    unusable: []const []const u8 = &.{},
    sent: std.ArrayList([]u8) = .empty,
    during: ?*const fn (*FakeRevoker) anyerror!void = null,
    place: ?Place = null,

    fn revoker(self: *FakeRevoker) Revoker {
        return .{ .context = self, .run = run };
    }

    fn deinit(self: *FakeRevoker) void {
        for (self.sent.items) |token| testing.allocator.free(token);
        self.sent.deinit(testing.allocator);
    }

    fn run(context: *const anyopaque, alloc: Allocator, tokens: Tokens) anyerror!void {
        _ = alloc;
        const self: *FakeRevoker = @ptrCast(@alignCast(@constCast(context)));
        try self.sent.append(testing.allocator, try testing.allocator.dupe(u8, tokens.refresh_token));
        if (self.during) |during| {
            self.during = null;
            try during(self);
        }
        for (self.unusable) |token| if (std.mem.eql(u8, token, tokens.refresh_token)) return error.KeptSignOutUnusable;
        for (self.refuse) |token| if (std.mem.eql(u8, token, tokens.refresh_token)) return error.RevocationRefused;
    }
};

fn writeRecord(tmp: *testing.TmpDir, name: []const u8, bytes: []const u8, mode: u32) !void {
    var spark_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, profile_paths.rootName());
    defer spark_dir.close();
    try io_mod.durableReplaceVerified(testing.allocator, &spark_dir, name, bytes);
    if (mode != 0o600) {
        var file = try spark_dir.dir.openFile(io_mod.getIo(), name, .{ .mode = .read_only });
        defer file.close(io_mod.getIo());
        try file.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(@intCast(mode)));
    }
}

/// How many times `needle` occurs in the record file itself, before the
/// parser drops duplicates or old sign-outs.
fn countInRecord(tmp: *testing.TmpDir, name: []const u8, needle: []const u8) !usize {
    var spark_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, profile_paths.rootName());
    defer spark_dir.close();
    var file = try spark_dir.dir.openFile(io_mod.getIo(), name, .{ .mode = .read_only });
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(testing.allocator, &file, max_record_bytes + 1);
    defer testing.allocator.free(bytes);
    return std.mem.count(u8, bytes, needle);
}

fn recordMode(tmp: *testing.TmpDir, name: []const u8) !?u32 {
    var spark_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, profile_paths.rootName());
    defer spark_dir.close();
    var file = spark_dir.dir.openFile(io_mod.getIo(), name, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    return @intCast(stat.permissions.toMode() & 0o777);
}

test "a kept sign-out is a private record that a confirmed retry removes" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const place = testPlace(&tmp, .mcp);
    try keepAt(testing.allocator, place, .{ .refresh_token = "refresh-1" }, 10 * day_ms, null);
    try testing.expectEqual(@as(?u32, 0o600), try recordMode(&tmp, "mcp-revocations.json"));
    try expectKept(place, &.{"refresh-1"});

    var fake: FakeRevoker = .{};
    defer fake.deinit();
    const outcome = try retryAt(testing.allocator, place, 10 * day_ms, fake.revoker(), null);
    try testing.expectEqual(@as(usize, 1), outcome.revoked);
    try testing.expect(!outcome.failed);
    try testing.expectEqual(@as(usize, 1), fake.sent.items.len);
    try testing.expectEqualStrings("refresh-1", fake.sent.items[0]);
    try testing.expectEqual(@as(?u32, null), try recordMode(&tmp, "mcp-revocations.json"));
}

fn keepAnother(fake: *FakeRevoker) anyerror!void {
    try keepAt(testing.allocator, fake.place.?, .{ .refresh_token = "added-meanwhile" }, 5, null);
}

/// An in-memory Keychain item for the spark login's record.
const MemoryKeychain = struct {
    value: ?[]u8 = null,
    loads: usize = 0,
    fail_store: bool = false,

    fn backend(self: *MemoryKeychain) KeychainBackend {
        return .{ .context = self, .load_fn = load, .store_fn = store, .delete_fn = delete };
    }

    fn deinit(self: *MemoryKeychain) void {
        if (self.value) |value| testing.allocator.free(value);
    }

    fn load(context: ?*anyopaque, alloc: Allocator) anyerror!?[]u8 {
        const self: *MemoryKeychain = @ptrCast(@alignCast(context.?));
        self.loads += 1;
        const value = self.value orelse return null;
        return try alloc.dupe(u8, value);
    }

    fn store(context: ?*anyopaque, value: []const u8) anyerror!void {
        const self: *MemoryKeychain = @ptrCast(@alignCast(context.?));
        if (self.fail_store) return error.KeychainWriteFailed;
        if (self.value) |old| testing.allocator.free(old);
        self.value = try testing.allocator.dupe(u8, value);
    }

    fn delete(context: ?*anyopaque, alloc: Allocator) anyerror!void {
        _ = alloc;
        const self: *MemoryKeychain = @ptrCast(@alignCast(context.?));
        if (self.value) |old| testing.allocator.free(old);
        self.value = null;
    }
};

fn fuzzRecord(_: void, smith: *testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    const alloc = testing.allocator;
    var list = parse(alloc, buffer[0..len]) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidKeptSignOuts => return,
    };
    defer list.deinit(alloc);
    try testing.expect(list.entries.items.len <= max_entries);

    // What parses writes back the same.
    const text = try stringify(alloc, list);
    defer secret.zeroAndFree(alloc, text);
    var again = try parse(alloc, text);
    defer again.deinit(alloc);
    try testing.expectEqual(list.entries.items.len, again.entries.items.len);
    for (list.entries.items, again.entries.items) |want, got| {
        try testing.expectEqual(want.saved_at_ms, got.saved_at_ms);
        inline for (field_names) |name| try testing.expectEqualStrings(@field(want, name), @field(got, name));
    }

    // Any saved time expires without overflow, at any clock reading.
    for ([_]i64{ std.math.minInt(i64), 0, std.math.maxInt(i64) }) |now| {
        _ = again.expire(alloc, .mcp, now);
    }
}
