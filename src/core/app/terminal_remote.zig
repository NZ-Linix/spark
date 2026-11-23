const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const types = @import("../shared/types.zig");

const Role = enum { user, assistant, thought, tool };
const Item = struct {
    id: []const u8,
    role: Role,
    text: []const u8 = "",
    name: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    status: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    output: ?[]const u8 = null,
};

pub const Request = struct {
    owner: []const u8,
    ticket: []const u8,
    expires: i64,
    op: enum { prompt, cancel },
    text: []const u8 = "",
};

const Ack = struct { ticket: []const u8, error_message: ?[]const u8 };
const max_turn_bytes = 512 * 1024;

// The bridge creates this private mailbox. The terminal still owns the writer lock and
// consumes only fresh requests addressed to this particular process, on its UI thread.
pub const State = struct {
    dir: ?io_mod.VerifiedDir = null,
    enabled: std.atomic.Value(bool) = .init(false),
    session: []const u8 = "",
    owner: [32]u8 = undefined,
    turn: u64 = 0,
    rows: std.ArrayList(Item) = .empty,
    chunk: std.ArrayList(u8) = .empty,
    arena: ?std.heap.ArenaAllocator = null,
    bytes: usize = 0,
    answers: u32 = 0,
    last_poll: i64 = 0,
    last_write: i64 = 0,
    dirty: bool = true,
    was_running: bool = false,

    pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
        self.detach(alloc);
        if (self.dir) |*dir| dir.close();
        self.* = .{};
    }

    fn detach(self: *State, alloc: std.mem.Allocator) void {
        if (self.session.len != 0) {
            self.remove("view");
            self.remove("request");
            self.remove("ack");
            alloc.free(self.session);
            self.session = "";
        }
        self.resetTurn();
        self.dirty = true;
    }

    fn resetTurn(self: *State) void {
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
        self.rows = .empty;
        self.chunk = .empty;
        self.turn = 0;
        self.bytes = 0;
        self.answers = 0;
    }

    fn path(self: *State, buf: []u8, suffix: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}.{s}", .{ self.session, suffix }) catch unreachable;
    }

    fn remove(self: *State, suffix: []const u8) void {
        var buf: [192]u8 = undefined;
        if (self.dir) |d| d.dir.deleteFile(io_mod.getIo(), self.path(&buf, suffix)) catch {};
    }

    pub fn poll(self: *State, alloc: std.mem.Allocator, session: ?[]const u8, now: i64) bool {
        const id = session orelse "";
        if ((self.dir == null or std.mem.eql(u8, self.session, id)) and now - self.last_poll < 200) return false;
        self.last_poll = now;
        if (!std.mem.eql(u8, self.session, id)) self.detach(alloc);
        if (self.dir == null) {
            const root = (profile_paths.activeRoot(alloc, io_mod.homeDir()) catch return false) orelse return false;
            defer alloc.free(root);
            var parent: io_mod.VerifiedDir = .{ .dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), root, .{}) catch return false };
            defer parent.close();
            self.dir = (io_mod.openVerifiedPrivateDirIfPresent(&parent, "terminal-live") catch return false) orelse return false;
            self.enabled.store(true, .monotonic);
        }
        if (id.len == 0 or id.len > 128) return false;
        for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
        if (self.session.len == 0) {
            self.session = alloc.dupe(u8, id) catch return false;
            var bytes: [16]u8 = undefined;
            io_mod.getIo().random(&bytes);
            self.owner = std.fmt.bytesToHex(bytes, .lower);
        }
        return true;
    }

    pub fn read(self: *State, alloc: std.mem.Allocator, now: i64) ?Request {
        var buf: [192]u8 = undefined;
        const body = self.dir.?.dir.readFileAlloc(io_mod.getIo(), self.path(&buf, "request"), alloc, .limited(128 * 1024)) catch |err| {
            if (err != error.FileNotFound) self.remove("request");
            return null;
        };
        self.remove("request");
        const r = std.json.parseFromSliceLeaky(Request, alloc, body, .{}) catch return null;
        if (!std.mem.eql(u8, r.owner, &self.owner) or r.expires < now or r.expires > now + 6_000) return null;
        return r;
    }

    pub fn ack(self: *State, ticket: []const u8, error_message: ?[]const u8) void {
        self.write("ack", Ack{ .ticket = ticket, .error_message = error_message }) catch {};
    }

    pub fn publish(self: *State, now: i64, committed: u64, running: bool) void {
        if (self.turn != 0 and (self.turn <= committed or !running)) {
            self.resetTurn();
            self.dirty = true;
        }
        if (!self.dirty and running == self.was_running and now - self.last_write < 2_000) return;
        self.write("view", .{
            .owner = &self.owner,
            .running = running,
            .committed = committed,
            .turn = self.turn,
            .items = self.rows.items,
        }) catch return;
        self.last_write = now;
        self.was_running = running;
        self.dirty = false;
    }

    fn write(self: *State, suffix: []const u8, payload: anytype) !void {
        const a = std.heap.page_allocator;
        const body = try std.json.Stringify.valueAlloc(a, payload, .{ .emit_null_optional_fields = false });
        defer a.free(body);
        const dir = self.dir.?.dir;
        const io = io_mod.getIo();
        var tmp_buf: [192]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.{s}.tmp", .{ self.session, &self.owner });
        defer dir.deleteFile(io, tmp) catch {};
        try dir.writeFile(io, .{ .sub_path = tmp, .data = body, .flags = .{ .exclusive = true, .permissions = .fromMode(0o600) } });
        var buf: [192]u8 = undefined;
        try dir.rename(tmp, dir, self.path(&buf, suffix), io);
    }

    pub fn user(self: *State, alloc: std.mem.Allocator, turn: u64, text: []const u8) !void {
        if (self.session.len == 0) return;
        if (turn != self.turn) {
            self.resetTurn();
            self.arena = .init(alloc);
            self.turn = turn;
        }
        const a = self.arena.?.allocator();
        const suffix: []const u8 = if (self.rows.items.len == 0) "u" else try std.fmt.allocPrint(a, "s{d}", .{self.rows.items.len});
        try self.row(a, .user, suffix, text);
    }

    fn row(self: *State, a: std.mem.Allocator, role: Role, suffix: []const u8, text: []const u8) !void {
        if (self.rows.items.len >= 512 or text.len > max_turn_bytes - self.bytes) return;
        const id = try std.fmt.allocPrint(a, "h{d}:{s}", .{ self.turn, suffix });
        const owned = try a.dupe(u8, text);
        try self.rows.append(a, .{ .id = id, .role = role, .text = owned });
        self.chunk = .empty;
        self.bytes += owned.len;
        self.dirty = true;
    }

    pub fn appendText(self: *State, role: Role, delta: []const u8) !void {
        if (delta.len == 0 or delta.len > max_turn_bytes - self.bytes) return;
        const a = if (self.arena) |*arena| arena.allocator() else return;
        if (self.rows.getLastOrNull() == null or self.rows.getLast().role != role) {
            if (self.rows.items.len >= 512) return;
            const suffix = if (role == .assistant)
                try std.fmt.allocPrint(a, "a{d}", .{self.answers})
            else
                try std.fmt.allocPrint(a, "r{d}", .{self.rows.items.len});
            try self.row(a, role, suffix, "");
            if (role == .assistant) self.answers += 1;
        }
        try self.chunk.appendSlice(a, delta);
        self.rows.items[self.rows.items.len - 1].text = self.chunk.items;
        self.bytes += delta.len;
        self.dirty = true;
    }

    pub fn tool(self: *State, event: types.ToolLifecycleEvent) !void {
        const a = if (self.arena) |*arena| arena.allocator() else return;
        switch (event) {
            .authoritative_started => |start| {
                if (self.rows.items.len >= 512 or start.tool_name.len > 512 or start.id.call_id.len > 512) return;
                try self.rows.append(a, .{
                    .id = try a.dupe(u8, start.id.call_id),
                    .role = .tool,
                    .name = try a.dupe(u8, start.tool_name),
                    .kind = switch (start.activity_kind) {
                        .read, .list => "read",
                        .write, .edit => "edit",
                        .open => "fetch",
                        .command => "execute",
                        .mcp => "mcp",
                        else => "other",
                    },
                    .detail = try a.dupe(u8, utf8Prefix(start.resolved_display_target orelse "", 600)),
                    .status = "in_progress",
                });
                self.chunk = .empty;
            },
            .terminal => |terminal| for (self.rows.items) |*item| {
                if (item.role != .tool or !std.mem.eql(u8, item.id, terminal.id.call_id)) continue;
                item.status = if (terminal.outcome.kind == .completed) "completed" else "failed";
                item.output = try a.dupe(u8, utf8Prefix(terminal.result orelse terminal.outcome.summary, 4_096));
                break;
            },
            else => return,
        }
        self.dirty = true;
    }
};

fn utf8Prefix(text: []const u8, cap: usize) []const u8 {
    if (text.len <= cap) return text;
    var end = cap;
    while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}
