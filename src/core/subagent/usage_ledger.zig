//! What each subagent used during one run of its host, kept in memory for the
//! `subagents` field of `spark ask --json`.
//!
//! The host owns one ledger. `agent_adapter` feeds it: `begin` when a child
//! opens a turn, `add` for each reply's usage, from the thread that runs the
//! child. The command that reports it reads `snapshot` once its run is over.
//! The ledger is off until `enable`, so a host that never reports it, such as
//! the interactive app or ACP, keeps nothing.
//!
//! The counts are this run's. A child's saved `usage` setting is its total
//! over its whole life; the ledger starts empty with the host, so a child that
//! worked in an earlier run shows only what it used since.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Entry = struct {
    /// The child's session id.
    id: []u8,
    /// The name its parent gave it. Null for a child saved with no name, which
    /// this version cannot start or message: the subagent tool has no `run`
    /// action and `message` needs a valid agent name. The type keeps the case
    /// so an unnamed child never breaks the result.
    name: ?[]u8,
    /// A count no reply reported stays null, as in a result's own `usage`.
    usage: types.Usage = .{},

    /// A copy whose strings the caller owns and frees with `deinit`.
    fn clone(self: Entry, alloc: Allocator) Allocator.Error!Entry {
        const id = try alloc.dupe(u8, self.id);
        errdefer alloc.free(id);
        const name: ?[]u8 = if (self.name) |value| try alloc.dupe(u8, value) else null;
        return .{ .id = id, .name = name, .usage = self.usage };
    }

    fn deinit(self: Entry, alloc: Allocator) void {
        alloc.free(self.id);
        if (self.name) |name| alloc.free(name);
    }
};

/// Frees entries `Ledger.snapshot` returned, with the allocator it was given.
pub fn freeEntries(alloc: Allocator, entries: []Entry) void {
    for (entries) |entry| entry.deinit(alloc);
    alloc.free(entries);
}

pub const Ledger = struct {
    /// A leaf lock: nothing else is taken or called while it is held, so a
    /// child's thread can note its usage from inside a model call.
    mutex: std.Io.Mutex = .init,
    enabled: bool = false,
    /// In the order each child first ran. Guarded by `mutex`.
    entries: std.ArrayList(Entry) = .empty,

    /// `alloc` is the one every `begin` used.
    pub fn deinit(self: *Ledger, alloc: Allocator) void {
        for (self.entries.items) |entry| entry.deinit(alloc);
        self.entries.deinit(alloc);
    }

    /// Starts keeping entries. Call before any child runs.
    pub fn enable(self: *Ledger) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.enabled = true;
    }

    /// Child `id` opened a turn, so it did work in this run: it has an entry
    /// from now on, after every child that began before it. A child that
    /// began already, in an earlier turn of this run, keeps its place.
    pub fn begin(self: *Ledger, alloc: Allocator, id: []const u8, name: ?[]const u8) Allocator.Error!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.enabled or self.find(id) != null) return;
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const owned_name: ?[]u8 = if (name) |value| try alloc.dupe(u8, value) else null;
        errdefer if (owned_name) |value| alloc.free(value);
        try self.entries.append(alloc, .{ .id = owned_id, .name = owned_name });
    }

    /// Adds one reply's usage to child `id`. A child with no entry gets none:
    /// the ledger is off, or the child never began a turn here. On a ledger
    /// that is on, that drops a count, so it is traced.
    pub fn add(self: *Ledger, id: []const u8, usage: types.Usage) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const entry = self.find(id) orelse {
            if (self.enabled) debug_trace.logf("subagent", "usage_ledger dropped a reply's usage: child={s} has no entry", .{id});
            return;
        };
        entry.usage.add(usage);
    }

    /// A copy of the entries as they are now, owned by the caller, in the
    /// order the children first ran. Children still at work keep adding to
    /// the ledger, not to the copy.
    pub fn snapshot(self: *Ledger, alloc: Allocator) Allocator.Error![]Entry {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const copy = try alloc.alloc(Entry, self.entries.items.len);
        var copied: usize = 0;
        errdefer {
            for (copy[0..copied]) |entry| entry.deinit(alloc);
            alloc.free(copy);
        }
        for (self.entries.items) |entry| {
            copy[copied] = try entry.clone(alloc);
            copied += 1;
        }
        return copy;
    }

    fn find(self: *Ledger, id: []const u8) ?*Entry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }
};

/// A ledger that child `child_a`, named `alpha`, has begun a turn in. It keeps
/// the entry only when `enabled`. The caller deinits it.
fn testLedger(alloc: Allocator, enabled: bool) !Ledger {
    var ledger: Ledger = .{};
    errdefer ledger.deinit(alloc);
    if (enabled) ledger.enable();
    try ledger.begin(alloc, "child_a", "alpha");
    return ledger;
}
