//! The libfx journal: one session as the ordered events a host stores.
//!
//! A host passes a `persistence` store to `createFxEngine`; spark appends an
//! event for each state change and rebuilds the session from the stored
//! events. This file
//! only encodes and folds events. Sending them is the ACP layer's job.
//!
//! Each event is one JSON object:
//!
//!   {"v":1,"seq":N,"turn":T,"type":"...","data":...}
//!
//! `seq` counts from 1 with no gaps. `turn` is the turn the event belongs to:
//! one more than the number of turns committed before it. `data` uses the
//! session codecs spark already persists, so its shape is spark's to change.
//!
//! - `turn_committed`: a finished turn, as one history entry
//! - `turn_progress`: the open turn so far, before each model request
//! - `tool_intent`: the tool calls about to run, before any of them starts
//! - `turn_progress_cleared`: the open turn ended without a history entry
//! - `history_replaced`: the whole history, after compaction
//! - `input_accepted`: a steer or follow-up the host handed in, before the
//!   model sees it
//! - `input_withdrawn`: a steer the host took back before it was placed, or
//!   a follow-up whose turn ended before its first progress
//! - `turn_yielded`: the open turn stopped before its next model request at
//!   the time the host gave it, to continue later without being told it was
//!   interrupted
//! - `tool_result`: one call of the running batch finished, with what the
//!   model sees, so a crash before the next progress leaves it answered
//!
//! A `turn_progress` after the turn's first may carry only what is new since
//! the one before it, named by its `seq` in `base`: `data` then leaves out
//! the user's turn, and its execution lists only the items after the base's,
//! while `steps` counts all of the turn's tool steps. The first progress of a
//! turn carries everything, and so does one after anything earlier changed,
//! such as a compaction during the turn. Events that use `base` or are a
//! `tool_result` are version 2; every other event stays version 1, so an spark
//! that reads only version 1 still loads a journal without them.
//! An event that names an image instead of holding its bytes, one the host
//! stored or one the session dropped, is version 3, so an spark that reads only
//! up to version 2 refuses it as newer.
//!
//! A `turn_progress` event lists the inputs its model request carries for
//! the first time in `inputs`, so placement is stored with the text it
//! places, and names the model the request goes to in `model`. A turn's
//! first progress carries the host's id for the turn in `turnId`. A steer
//! belongs to the turn it arrives in; a follow-up waits for the turn that
//! runs it.
const std = @import("std");
const types = @import("../../shared/types.zig");
const testing_allocator = @import("../../shared/testing_allocator.zig");
const session_codec = @import("../../session/session_codec.zig");
const image_data = @import("../../images/image_data.zig");
const checkpoint_codec = @import("checkpoint.zig");
const compactor = @import("../../compactor/compactor.zig");

const Allocator = std.mem.Allocator;

/// The newest event version this spark reads and writes.
pub const version: u8 = 4;
/// The version of an event that needs none of the later additions.
const plain_version: u8 = 1;
/// The version of a `tool_result` and of a progress that extends another.
const delta_version: u8 = 2;
/// The version of an event that names an image instead of holding its
/// bytes, one the host stored (`inline_ref`) or one the session dropped, so an
/// spark that reads only up to version 2 reports a newer journal instead of an
/// invalid one.
const naming_version: u8 = 3;
/// The version of an event that holds a turn with context notes or a saved
/// runtime context (D93, D94), whatever else it holds, so an spark that reads
/// only up to version 3 reports a newer journal instead of an invalid one.
const notes_version: u8 = 4;
/// The most event bytes one load accepts, and the most bytes one snapshot
/// holds: each travels as one host attachment, and an attachment holds at
/// most one kernel checkpoint. Longer sessions need snapshots.
pub const max_load_bytes: usize = checkpoint_codec.max_checkpoint_bytes;
pub const max_snapshot_bytes: usize = checkpoint_codec.max_checkpoint_bytes;
/// The largest `seq` or turn a host can carry: hosts in JavaScript hold them
/// as numbers.
const max_safe_position: u64 = (1 << 53) - 1;
pub const max_history_turns = checkpoint_codec.max_history_turns;

const EventType = enum {
    turn_committed,
    turn_progress,
    tool_intent,
    turn_progress_cleared,
    history_replaced,
    input_accepted,
    input_withdrawn,
    turn_yielded,
    tool_result,
};

const InputKind = enum { steer, follow_up };

/// A steer or follow-up the host handed in.
pub const Input = struct {
    id: []const u8,
    text: []const u8,
    kind: InputKind = .steer,
};

/// The open turn so far, before a model request, the inputs that request
/// carries for the first time, and the model it goes to.
pub const Progress = struct {
    checkpoint: session_codec.RecoveryCheckpoint,
    placed: []const []const u8 = &.{},
    model: ?[]const u8 = null,
    /// The host's id for the turn, on the turn's first progress only.
    turn_id: ?[]const u8 = null,
    /// Set to write only what is new since an earlier progress of the turn.
    delta: ?Delta = null,
};

/// What a progress that carries only what is new extends: the earlier
/// progress, by `seq`, and how many execution items it holds.
pub const Delta = struct {
    base_seq: u64,
    from: session_codec.ExecutionCounts,
};

/// One call of the running batch, finished: what the model sees of it.
pub const ToolResult = struct {
    id: []const u8,
    name: []const u8,
    failed: bool,
    output: []const u8,
    /// The images the result returned, which a reopened turn gives back to
    /// the call with its output.
    images: []const types.ToolImage = &.{},
};

/// The longest turn id a host may give.
pub const max_turn_id_bytes = 128;

/// Borrows its payload only for `Cursor.write`.
pub const Event = union(EventType) {
    turn_committed: types.HistoryTurn,
    turn_progress: Progress,
    tool_intent: []const types.ToolCall,
    turn_progress_cleared,
    history_replaced: []const types.HistoryTurn,
    input_accepted: Input,
    /// The withdrawn input's id.
    input_withdrawn: []const u8,
    turn_yielded,
    tool_result: ToolResult,

    /// The version `Cursor.write` gives the event: `notes_version` when it
    /// holds a turn with context notes or a saved runtime context, and
    /// `naming_version` when it names an image, one `stored` holds or one the
    /// session dropped.
    fn eventVersion(self: Event, stored: ?*const session_codec.StoredImages) u8 {
        if (eventUsesNotesSchema(self)) return notes_version;
        if (eventNamesImages(self, stored)) return naming_version;
        return switch (self) {
            .tool_result => delta_version,
            .turn_progress => |progress| if (progress.delta != null) delta_version else plain_version,
            else => plain_version,
        };
    }
};

/// An input the open turn accepted and has not placed or withdrawn.
pub const PendingInput = struct {
    id: []u8,
    text: []u8,
};

/// Where the next event goes. A copy advances only when its caller stores
/// the cursor `write` returns, so an event that fails to send leaves no gap.
pub const Cursor = struct {
    next_seq: u64 = 1,
    turn: u64 = 1,

    /// Writes `event` as one JSON object and returns the cursor after it.
    pub fn write(self: Cursor, writer: *std.Io.Writer, event: Event) !Cursor {
        return self.writeWith(writer, event, null);
    }

    /// Like `write`, but names the images `stored` holds instead of writing
    /// their bytes.
    pub fn writeNamingImages(self: Cursor, writer: *std.Io.Writer, event: Event, stored: *const session_codec.StoredImages) !Cursor {
        return self.writeWith(writer, event, stored);
    }

    fn writeWith(self: Cursor, writer: *std.Io.Writer, event: Event, stored: ?*const session_codec.StoredImages) !Cursor {
        try writer.print("{{\"v\":{d},\"seq\":{d},\"turn\":{d},\"type\":\"{s}\"", .{
            event.eventVersion(stored),
            self.next_seq,
            self.turn,
            @tagName(event),
        });
        switch (event) {
            .turn_committed => |turn| {
                try writer.writeAll(",\"data\":");
                if (stored) |names|
                    try session_codec.writeHistoryTurnNamingImages(writer, turn, .{ .stored = names })
                else
                    try session_codec.writeHistoryTurn(writer, turn);
            },
            .turn_progress => |progress| {
                try writer.writeAll(",\"data\":");
                if (progress.delta) |delta| {
                    if (delta.base_seq >= self.next_seq) return error.InvalidDurableField;
                    if (stored) |names|
                        try session_codec.writeRecoveryCheckpointDeltaNamingImages(writer, progress.checkpoint, delta.from, .{ .stored = names })
                    else
                        try session_codec.writeRecoveryCheckpointDelta(writer, progress.checkpoint, delta.from);
                    try writer.print(",\"base\":{d},\"steps\":{d}", .{ delta.base_seq, progress.checkpoint.execution.tool_steps.len });
                } else if (stored) |names| {
                    try session_codec.writeRecoveryCheckpointNamingImages(writer, progress.checkpoint, .{ .stored = names });
                } else {
                    try session_codec.writeRecoveryCheckpoint(writer, progress.checkpoint);
                }
                if (progress.placed.len > 0) {
                    try writer.writeAll(",\"inputs\":");
                    try std.json.Stringify.value(progress.placed, .{}, writer);
                }
                if (progress.model) |model| {
                    try writer.writeAll(",\"model\":");
                    try std.json.Stringify.value(model, .{}, writer);
                }
                if (progress.turn_id) |id| {
                    try writer.writeAll(",\"turnId\":");
                    try std.json.Stringify.value(id, .{}, writer);
                }
            },
            .tool_intent => |calls| {
                try writer.writeAll(",\"data\":");
                try session_codec.writeToolCalls(writer, calls);
            },
            .turn_progress_cleared => {},
            .history_replaced => |history| {
                if (history.len > max_history_turns) return error.JournalTooLarge;
                try writer.writeAll(",\"data\":[");
                for (history, 0..) |turn, index| {
                    if (index > 0) try writer.writeByte(',');
                    if (stored) |names|
                        try session_codec.writeHistoryTurnNamingImages(writer, turn, .{ .stored = names })
                    else
                        try session_codec.writeHistoryTurn(writer, turn);
                }
                try writer.writeByte(']');
            },
            .input_accepted => |input| {
                try writer.writeAll(",\"data\":");
                try std.json.Stringify.value(.{ .id = input.id, .kind = @tagName(input.kind), .text = input.text }, .{}, writer);
            },
            .input_withdrawn => |id| {
                try writer.writeAll(",\"data\":");
                try std.json.Stringify.value(.{ .id = id }, .{}, writer);
            },
            .turn_yielded => {},
            .tool_result => |result| {
                try writer.writeAll(",\"data\":{\"id\":");
                try std.json.Stringify.value(result.id, .{}, writer);
                try writer.writeAll(",\"name\":");
                try std.json.Stringify.value(result.name, .{}, writer);
                try writer.print(",\"status\":\"{s}\",\"output\":", .{if (result.failed) "failure" else "success"});
                try std.json.Stringify.value(result.output, .{}, writer);
                if (result.images.len > 0) {
                    try writer.writeAll(",\"images\":");
                    try session_codec.writeToolImages(writer, result.images, stored != null);
                }
                try writer.writeByte('}');
            },
        }
        try writer.writeByte('}');
        return .{
            .next_seq = self.next_seq + 1,
            .turn = if (event == .turn_committed) self.turn + 1 else self.turn,
        };
    }
};

/// Whether `event` holds a turn that `session_codec` writes as execution
/// schema 11 or 12.
fn eventUsesNotesSchema(event: Event) bool {
    return switch (event) {
        .turn_committed => |turn| session_codec.turnUsesNotesSchema(turn),
        .turn_progress => |progress| session_codec.executionUsesNotesSchema(progress.checkpoint.execution),
        .history_replaced => |history| for (history) |turn| {
            if (session_codec.turnUsesNotesSchema(turn)) break true;
        } else false,
        .tool_result, .tool_intent, .turn_progress_cleared, .input_accepted, .input_withdrawn, .turn_yielded => false,
    };
}

/// Whether writing `event` names an image: one `stored` holds, or one the
/// session dropped.
fn eventNamesImages(event: Event, stored: ?*const session_codec.StoredImages) bool {
    return switch (event) {
        .turn_committed => |turn| session_codec.turnNamesImages(turn, stored),
        // A delta leaves out the user's turn: it names only what its new
        // tool results do.
        .turn_progress => |progress| session_codec.checkpointNamesImages(progress.checkpoint, if (progress.delta) |delta| delta.from else null, stored),
        .history_replaced => |history| for (history) |turn| {
            if (session_codec.turnNamesImages(turn, stored)) break true;
        } else false,
        .tool_result => |result| session_codec.toolImagesNameImages(result.images, stored),
        .tool_intent, .turn_progress_cleared, .input_accepted, .input_withdrawn, .turn_yielded => false,
    };
}

/// A snapshot of a quiet prefix: `FXSN`, a version byte, the last `seq` it
/// covers and the turn after it (each a little-endian u64), the id of the
/// last turn (a length byte, zero for none, then its bytes), then a
/// checkpoint of the history. Version 2, a snapshot taken where a turn
/// yielded, adds the open turn before the checkpoint: a little-endian u32
/// length, then the JSON `writeOpenTurn` writes. A quiet snapshot stays
/// version 1, so an spark that reads only version 1 still loads it. Hosts store
/// it as opaque bytes.
const snapshot_magic = "FXSN";
const snapshot_version_quiet: u8 = 1;
const snapshot_version: u8 = 2;
/// Version 2's layout, with an open turn that names images: ones the host
/// stored, or ones the session dropped.
const snapshot_naming_version: u8 = 3;
/// Version 2's layout, with an open turn that has context notes or a saved
/// runtime context (D93, D94), whether or not it names images.
const snapshot_notes_version: u8 = 4;
const snapshot_header_bytes = snapshot_magic.len + 1 + 8 + 8 + 1;

pub const Snapshot = struct {
    /// The last event the snapshot covers; the tail starts after it.
    seq: u64,
    turn: u64,
    /// The last turn's id. Borrowed from the snapshot bytes.
    last_turn_id: ?[]const u8,
    /// The turn that yielded, as `writeOpenTurn` wrote it, or null for a
    /// quiet prefix. Borrowed from the snapshot bytes.
    open_turn: ?[]const u8 = null,
    /// Borrowed from the snapshot bytes.
    checkpoint: []const u8,
};

/// Returns caller-owned snapshot bytes for a checkpoint taken after `seq`,
/// with `open_turn` from `writeOpenTurn` when a turn yielded there.
/// `last_turn_id` is at most `max_turn_id_bytes` long.
pub fn encodeSnapshot(
    alloc: Allocator,
    seq: u64,
    turn: u64,
    last_turn_id: ?[]const u8,
    open_turn: ?[]const u8,
    checkpoint: []const u8,
) error{ OutOfMemory, SnapshotTooLarge }![]u8 {
    return encodeSnapshotWith(alloc, seq, turn, last_turn_id, open_turn, checkpoint, snapshot_version);
}

/// Like `encodeSnapshot`, for an `open_turn` that names at least one image
/// (`session_codec.namesImages`).
pub fn encodeSnapshotNamingImages(
    alloc: Allocator,
    seq: u64,
    turn: u64,
    last_turn_id: ?[]const u8,
    open_turn: []const u8,
    checkpoint: []const u8,
) error{ OutOfMemory, SnapshotTooLarge }![]u8 {
    return encodeSnapshotWith(alloc, seq, turn, last_turn_id, open_turn, checkpoint, snapshot_naming_version);
}

/// Like `encodeSnapshot`, for an `open_turn` whose progress has context notes
/// or a saved runtime context (`session_codec.executionUsesNotesSchema`),
/// whether or not it names images.
pub fn encodeSnapshotWithNotes(
    alloc: Allocator,
    seq: u64,
    turn: u64,
    last_turn_id: ?[]const u8,
    open_turn: []const u8,
    checkpoint: []const u8,
) error{ OutOfMemory, SnapshotTooLarge }![]u8 {
    return encodeSnapshotWith(alloc, seq, turn, last_turn_id, open_turn, checkpoint, snapshot_notes_version);
}

/// `open_turn_version` is the version a snapshot with an open turn gets.
fn encodeSnapshotWith(
    alloc: Allocator,
    seq: u64,
    turn: u64,
    last_turn_id: ?[]const u8,
    open_turn: ?[]const u8,
    checkpoint: []const u8,
    open_turn_version: u8,
) error{ OutOfMemory, SnapshotTooLarge }![]u8 {
    const id = last_turn_id orelse "";
    std.debug.assert(id.len <= max_turn_id_bytes);
    const open_bytes: usize = if (open_turn) |open| 4 + open.len else 0;
    if (open_turn) |open| if (open.len > std.math.maxInt(u32)) return error.SnapshotTooLarge;
    const bytes = try alloc.alloc(u8, snapshot_header_bytes + id.len + open_bytes + checkpoint.len);
    @memcpy(bytes[0..snapshot_magic.len], snapshot_magic);
    bytes[snapshot_magic.len] = if (open_turn == null) snapshot_version_quiet else open_turn_version;
    std.mem.writeInt(u64, bytes[snapshot_magic.len + 1 ..][0..8], seq, .little);
    std.mem.writeInt(u64, bytes[snapshot_magic.len + 9 ..][0..8], turn, .little);
    bytes[snapshot_header_bytes - 1] = @intCast(id.len);
    @memcpy(bytes[snapshot_header_bytes..][0..id.len], id);
    var at = snapshot_header_bytes + id.len;
    if (open_turn) |open| {
        std.mem.writeInt(u32, bytes[at..][0..4], @intCast(open.len), .little);
        @memcpy(bytes[at + 4 ..][0..open.len], open);
        at += open_bytes;
    }
    @memcpy(bytes[at..], checkpoint);
    return bytes;
}

pub fn parseSnapshot(bytes: []const u8) LoadError!Snapshot {
    if (bytes.len < snapshot_header_bytes or !std.mem.eql(u8, bytes[0..snapshot_magic.len], snapshot_magic)) {
        return error.InvalidJournal;
    }
    const found_version = bytes[snapshot_magic.len];
    if (found_version > snapshot_notes_version) return error.UnsupportedJournalVersion;
    if (found_version == 0) return error.InvalidJournal;
    const has_open_turn = found_version != snapshot_version_quiet;
    const seq = std.mem.readInt(u64, bytes[snapshot_magic.len + 1 ..][0..8], .little);
    const turn = std.mem.readInt(u64, bytes[snapshot_magic.len + 9 ..][0..8], .little);
    if (seq == 0 or turn == 0 or seq > max_safe_position or turn > max_safe_position) return error.InvalidJournal;
    const id_len = bytes[snapshot_header_bytes - 1];
    if (id_len > max_turn_id_bytes or bytes.len - snapshot_header_bytes < id_len) return error.InvalidJournal;
    var at: usize = snapshot_header_bytes + id_len;
    var open_turn: ?[]const u8 = null;
    if (has_open_turn) {
        if (bytes.len - at < 4) return error.InvalidJournal;
        const open_len = std.mem.readInt(u32, bytes[at..][0..4], .little);
        at += 4;
        if (open_len == 0 or bytes.len - at < open_len) return error.InvalidJournal;
        open_turn = bytes[at..][0..open_len];
        at += open_len;
    }
    return .{
        .seq = seq,
        .turn = turn,
        .last_turn_id = if (id_len == 0) null else bytes[snapshot_header_bytes..][0..id_len],
        .open_turn = open_turn,
        .checkpoint = bytes[at..],
    };
}

/// Writes the turn that yielded, for a version 2 snapshot: its id, when the
/// host gave one, and its progress as a `turn_progress` carries it.
pub fn writeOpenTurn(writer: *std.Io.Writer, turn_id: ?[]const u8, progress: session_codec.RecoveryCheckpoint) !void {
    return writeOpenTurnWith(writer, turn_id, progress, null);
}

/// Like `writeOpenTurn`, but names the images `stored` holds instead of
/// writing their bytes. Returns whether it named any, a dropped one too,
/// which makes the snapshot version 3 (`encodeSnapshotNamingImages`).
pub fn writeOpenTurnNamingImages(
    writer: *std.Io.Writer,
    turn_id: ?[]const u8,
    progress: session_codec.RecoveryCheckpoint,
    stored: *const session_codec.StoredImages,
) !bool {
    try writeOpenTurnWith(writer, turn_id, progress, stored);
    return session_codec.checkpointNamesImages(progress, null, stored);
}

fn writeOpenTurnWith(
    writer: *std.Io.Writer,
    turn_id: ?[]const u8,
    progress: session_codec.RecoveryCheckpoint,
    stored: ?*const session_codec.StoredImages,
) !void {
    try writer.writeByte('{');
    if (turn_id) |id| {
        std.debug.assert(id.len > 0 and id.len <= max_turn_id_bytes);
        try writer.writeAll("\"turnId\":");
        try std.json.Stringify.value(id, .{}, writer);
        try writer.writeByte(',');
    }
    try writer.writeAll("\"progress\":");
    if (stored) |names|
        try session_codec.writeRecoveryCheckpointNamingImages(writer, progress, .{ .stored = names })
    else
        try session_codec.writeRecoveryCheckpoint(writer, progress);
    try writer.writeByte('}');
}

pub const LoadError = Allocator.Error || error{
    /// An event is not the shape this version writes.
    InvalidJournal,
    /// An event was written by a newer spark.
    UnsupportedJournalVersion,
    /// A `seq` or `turn` is missing, repeated, or out of order.
    OutOfOrderJournalEvent,
    /// The events are more than one load holds.
    JournalTooLarge,
    /// The history is longer than a session restores.
    JournalTooManyTurns,
};

/// A session rebuilt from its events. Owns every slice.
pub const Folded = struct {
    history: []types.HistoryTurn,
    /// The turn a crash left open: progress with no commit or clear after it.
    open_turn: ?session_codec.RecoveryCheckpoint,
    /// Calls the open turn announced that no progress answers. Some may have
    /// started; the ones `finished` names ran to the end.
    running_calls: []types.ToolCall = &.{},
    /// What each finished call of `running_calls` returned, by call id.
    finished: []Finished = &.{},
    /// Steers the open turn accepted and has not placed or withdrawn, in the
    /// order they arrived.
    pending_inputs: []PendingInput = &.{},
    /// Follow-ups no turn has run yet, in the order they arrived.
    pending_follow_ups: []PendingInput = &.{},
    /// The host's id for the open turn, when it gave one.
    open_turn_id: ?[]u8 = null,
    /// The host's id for the last turn that ended, when it gave one.
    last_turn_id: ?[]u8 = null,
    /// The open turn stopped at the time the host gave it, with nothing
    /// after: it continues without being told it was interrupted.
    yielded: bool = false,
    cursor: Cursor,

    pub fn deinit(self: *Folded, alloc: Allocator) void {
        types.freeHistoryTurnSlice(alloc, self.history);
        if (self.open_turn) |*checkpoint| checkpoint.deinit(alloc);
        types.freeToolCallSlice(alloc, self.running_calls);
        freeFinished(alloc, self.finished);
        freePendingInputs(alloc, self.pending_inputs);
        freePendingInputs(alloc, self.pending_follow_ups);
        if (self.open_turn_id) |id| alloc.free(id);
        if (self.last_turn_id) |id| alloc.free(id);
        self.* = undefined;
    }
};

/// A running call's recorded result. Owns its strings.
pub const Finished = struct {
    id: []u8,
    failed: bool,
    output: []u8,
    /// Owned. An image the host has yet to stage has no bytes, and the
    /// fold's resolver records it as missing.
    images: []types.ToolImage = &.{},
};

fn freeFinished(alloc: Allocator, finished: []Finished) void {
    freeFinishedEntries(alloc, finished);
    alloc.free(finished);
}

fn freeFinishedEntries(alloc: Allocator, finished: []const Finished) void {
    for (finished) |entry| {
        alloc.free(entry.id);
        alloc.free(entry.output);
        types.freeToolImages(alloc, entry.images);
    }
}

pub fn freePendingInputs(alloc: Allocator, inputs: []PendingInput) void {
    for (inputs) |input| {
        alloc.free(input.id);
        alloc.free(input.text);
    }
    alloc.free(inputs);
}

/// The current turn's inputs as the fold sees them. Borrows from the parse.
const InputState = struct {
    id: []const u8,
    text: []const u8,
    kind: InputKind,
    placed: bool = false,
    withdrawn: bool = false,

    fn pending(self: InputState, kind: InputKind) bool {
        return self.kind == kind and !self.placed and !self.withdrawn;
    }
};

/// At a turn's end its steers are gone; follow-ups still waiting stay.
fn endTurnInputs(inputs: *std.ArrayList(InputState)) void {
    var kept: usize = 0;
    for (inputs.items) |input| {
        if (!input.pending(.follow_up)) continue;
        inputs.items[kept] = input;
        kept += 1;
    }
    inputs.shrinkRetainingCapacity(kept);
}

fn findInput(inputs: []InputState, id: []const u8) ?*InputState {
    for (inputs) |*input| if (std.mem.eql(u8, input.id, id)) return input;
    return null;
}

fn announcedCall(calls: []const std.json.Value, id: []const u8) bool {
    for (calls) |call| {
        if (call != .object) continue;
        const call_id = call.object.get("id") orelse continue;
        if (call_id == .string and std.mem.eql(u8, call_id.string, id)) return true;
    }
    return false;
}

/// Owned copies of the newest recorded result of each call in `calls`, with
/// the images each names resolved through `sources`.
fn finishedOf(alloc: Allocator, calls: []const types.ToolCall, results: []const std.json.Value, sources: session_codec.ImageSources) LoadError![]Finished {
    var finished: std.ArrayList(Finished) = .empty;
    errdefer {
        freeFinishedEntries(alloc, finished.items);
        finished.deinit(alloc);
    }
    for (calls) |call| {
        var newest: ?std.json.Value = null;
        for (results) |result| {
            if (std.mem.eql(u8, result.object.get("id").?.string, call.id)) newest = result;
        }
        const result = newest orelse continue;
        const id = try alloc.dupe(u8, call.id);
        errdefer alloc.free(id);
        const output = try alloc.dupe(u8, result.object.get("output").?.string);
        errdefer alloc.free(output);
        const images: []types.ToolImage = if (result.object.get("images")) |list|
            session_codec.parseToolImages(alloc, list.array.items, sources) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidJournal,
            }
        else
            &.{};
        errdefer types.freeToolImages(alloc, images);
        try finished.append(alloc, .{
            .id = id,
            .failed = std.mem.eql(u8, result.object.get("status").?.string, "failure"),
            .output = output,
            .images = images,
        });
    }
    return finished.toOwnedSlice(alloc);
}

fn stringField(value: std.json.Value, name: []const u8) LoadError![]const u8 {
    if (value != .object) return error.InvalidJournal;
    const field = value.object.get(name) orelse return error.InvalidJournal;
    if (field != .string or field.string.len == 0) return error.InvalidJournal;
    return field.string;
}

/// Where a fold starts: an empty session, or a snapshot and the cursor after
/// it. A snapshot has no follow-up waiting; it is a quiet prefix, or a turn
/// that yielded with no input waiting for it.
pub const Base = struct {
    history: []const types.HistoryTurn = &.{},
    cursor: Cursor = .{},
    /// The id of the prefix's last turn.
    last_turn_id: ?[]const u8 = null,
    /// The turn that yielded, as `writeOpenTurn` wrote it.
    open_turn: ?[]const u8 = null,
    /// Resolves the images events name. Without it an event that names one
    /// is invalid; a name it cannot resolve is recorded there, and the fold
    /// is then only good for learning which images the host must stage.
    images: ?*session_codec.ImageResolver = null,
};

/// Rebuilds a session from `events_json`, a JSON array of events in order.
pub fn fold(alloc: Allocator, events_json: []const u8) LoadError!Folded {
    return foldFrom(alloc, events_json, .{});
}

/// Rebuilds a session from `base` and the events after it.
pub fn foldFrom(alloc: Allocator, events_json: []const u8, base: Base) LoadError!Folded {
    if (events_json.len > max_load_bytes) return error.JournalTooLarge;
    if (base.history.len > max_history_turns) return error.JournalTooManyTurns;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), events_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJournal,
    };
    if (parsed != .array) return error.InvalidJournal;

    var history: std.ArrayList(types.HistoryTurn) = .empty;
    defer {
        for (history.items) |turn| types.freeHistoryTurn(alloc, turn);
        history.deinit(alloc);
    }
    try history.ensureTotalCapacity(alloc, base.history.len);
    for (base.history) |turn| history.appendAssumeCapacity(try types.dupeHistoryTurn(alloc, turn));
    var open: ?std.json.Value = null;
    // The `seq` of the progress `open` came from; null for a snapshot's.
    var open_seq: ?u64 = null;
    // The open turn's announced calls; the ones its progress answers are
    // dropped at the end.
    var running: std.ArrayList(std.json.Value) = .empty;
    defer running.deinit(alloc);
    // The results its calls recorded as each finished.
    var results: std.ArrayList(std.json.Value) = .empty;
    defer results.deinit(alloc);
    var inputs: std.ArrayList(InputState) = .empty;
    defer inputs.deinit(alloc);
    var open_id: ?[]const u8 = null;
    var last_id: ?[]const u8 = base.last_turn_id;
    var yielded = false;
    var cursor = base.cursor;
    if (base.open_turn) |text| {
        // The snapshot's turn stays open and yielded until the events after
        // it say otherwise.
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJournal,
        };
        if (value != .object) return error.InvalidJournal;
        const progress = value.object.get("progress") orelse return error.InvalidJournal;
        if (progress != .object) return error.InvalidJournal;
        open = progress;
        open_id = try turnIdOf(value.object.get("turnId"));
        yielded = true;
    }
    for (parsed.array.items) |value| {
        const event = try envelope(value, cursor);
        // A yield stands only until the turn does anything more.
        if (event.kind != .turn_yielded) yielded = false;
        switch (event.kind) {
            .turn_committed => {
                const turn = try parseTurn(alloc, event.data orelse return error.InvalidJournal, base.images);
                // The same rule the session applies when it commits the turn.
                if (replacesHistory(turn)) {
                    for (history.items) |old| types.freeHistoryTurn(alloc, old);
                    history.clearRetainingCapacity();
                }
                history.append(alloc, turn) catch |err| {
                    types.freeHistoryTurn(alloc, turn);
                    return err;
                };
                open = null;
                open_seq = null;
                last_id = open_id;
                open_id = null;
                running.clearRetainingCapacity();
                results.clearRetainingCapacity();
                endTurnInputs(&inputs);
            },
            .turn_progress => {
                // A host may leave out a superseded progress's state as
                // `null`: a later progress in the turn, or its end, replaces
                // it. A progress that carries only what is new extends the
                // turn's progress right before it, which must have its state.
                const data = event.data orelse return error.InvalidJournal;
                if (data != .object and data != .null) return error.InvalidJournal;
                const seq = cursor.next_seq;
                if (event.base) |extended| {
                    if (open == null or open_seq != extended) return error.InvalidJournal;
                    // A superseded delta's state may be left out like any
                    // other's; one that has it needs its base's.
                    open = if (data == .null) data else try mergeDelta(arena_state.allocator(), open.?, data);
                } else {
                    // A turn's first progress names it.
                    if (open == null) open_id = try turnIdOf(event.turn_id);
                    open = data;
                }
                open_seq = seq;
                // Each placed input was accepted in this turn and is placed once.
                if (event.inputs) |placed| {
                    if (placed != .array) return error.InvalidJournal;
                    for (placed.array.items) |id| {
                        if (id != .string) return error.InvalidJournal;
                        const input = findInput(inputs.items, id.string) orelse return error.InvalidJournal;
                        if (input.placed or input.withdrawn) return error.InvalidJournal;
                        input.placed = true;
                    }
                }
            },
            .tool_intent => {
                const data = event.data orelse return error.InvalidJournal;
                if (data != .array or data.array.items.len == 0) return error.InvalidJournal;
                // An intent belongs to an open turn.
                if (open == null) return error.InvalidJournal;
                try running.appendSlice(alloc, data.array.items);
            },
            .turn_progress_cleared => {
                if (event.data != null) return error.InvalidJournal;
                open = null;
                open_seq = null;
                last_id = open_id;
                open_id = null;
                running.clearRetainingCapacity();
                results.clearRetainingCapacity();
                endTurnInputs(&inputs);
            },
            .tool_result => {
                const data = event.data orelse return error.InvalidJournal;
                // A result belongs to a call the open turn announced.
                if (open == null) return error.InvalidJournal;
                // A host may leave out the state of one a later progress
                // answers, as `null`.
                if (data != .null) {
                    const id = try stringField(data, "id");
                    _ = try stringField(data, "name");
                    const status = try stringField(data, "status");
                    if (!std.mem.eql(u8, status, "success") and !std.mem.eql(u8, status, "failure")) return error.InvalidJournal;
                    const output = data.object.get("output") orelse return error.InvalidJournal;
                    if (output != .string) return error.InvalidJournal;
                    if (data.object.get("images")) |images| if (images != .array) return error.InvalidJournal;
                    // One for a call no intent announced answers nothing.
                    if (announcedCall(running.items, id)) try results.append(alloc, data);
                }
            },
            .input_accepted => {
                const data = event.data orelse return error.InvalidJournal;
                const id = try stringField(data, "id");
                const text = try stringField(data, "text");
                const kind: InputKind = if (data.object.get("kind")) |kind_value| parsed_kind: {
                    if (kind_value != .string) return error.InvalidJournal;
                    break :parsed_kind std.meta.stringToEnum(InputKind, kind_value.string) orelse return error.InvalidJournal;
                } else .steer;
                if (findInput(inputs.items, id) != null) return error.InvalidJournal;
                try inputs.append(alloc, .{ .id = id, .text = text, .kind = kind });
            },
            .input_withdrawn => {
                const data = event.data orelse return error.InvalidJournal;
                const input = findInput(inputs.items, try stringField(data, "id")) orelse return error.InvalidJournal;
                if (input.placed or input.withdrawn) return error.InvalidJournal;
                input.withdrawn = true;
            },
            .turn_yielded => {
                if (event.data != null) return error.InvalidJournal;
                // Only an open turn yields.
                if (open == null) return error.InvalidJournal;
                yielded = true;
            },
            .history_replaced => {
                const data = event.data orelse return error.InvalidJournal;
                if (data != .array) return error.InvalidJournal;
                if (data.array.items.len > max_history_turns) return error.JournalTooManyTurns;
                var replacement: std.ArrayList(types.HistoryTurn) = .empty;
                errdefer {
                    for (replacement.items) |turn| types.freeHistoryTurn(alloc, turn);
                    replacement.deinit(alloc);
                }
                try replacement.ensureTotalCapacity(alloc, data.array.items.len);
                for (data.array.items) |item| replacement.appendAssumeCapacity(try parseTurn(alloc, item, base.images));
                for (history.items) |turn| types.freeHistoryTurn(alloc, turn);
                history.deinit(alloc);
                history = replacement;
            },
        }
        if (history.items.len > max_history_turns) return error.JournalTooManyTurns;
        cursor = .{
            .next_seq = cursor.next_seq + 1,
            .turn = if (event.kind == .turn_committed) cursor.turn + 1 else cursor.turn,
        };
    }

    var open_turn: ?session_codec.RecoveryCheckpoint = null;
    if (open) |data| open_turn = if (data == .null) return error.InvalidJournal else session_codec.parseRecoveryCheckpointWithImages(alloc, data, .{ .names = base.images }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJournal,
    };
    errdefer if (open_turn) |*checkpoint| checkpoint.deinit(alloc);
    const announced = session_codec.parseToolCalls(alloc, .{
        .array = std.json.Array.fromOwnedSlice(alloc, running.items),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJournal,
    };
    const execution: types.ExecutionMemory = if (open_turn) |checkpoint| checkpoint.execution else .{};
    const unanswered = dropAnswered(alloc, announced, execution) catch |err| {
        types.freeToolCallSlice(alloc, announced);
        return err;
    };
    errdefer types.freeToolCallSlice(alloc, unanswered);
    const finished = try finishedOf(alloc, unanswered, results.items, .{ .names = base.images });
    errdefer freeFinished(alloc, finished);
    const pending = try pendingInputsOf(alloc, if (open_turn != null) inputs.items else &.{}, .steer);
    errdefer freePendingInputs(alloc, pending);
    const follow_ups = try pendingInputsOf(alloc, inputs.items, .follow_up);
    errdefer freePendingInputs(alloc, follow_ups);
    const open_turn_id = if (open_id) |id| try alloc.dupe(u8, id) else null;
    errdefer if (open_turn_id) |id| alloc.free(id);
    const last_turn_id = if (last_id) |id| try alloc.dupe(u8, id) else null;
    errdefer if (last_turn_id) |id| alloc.free(id);
    const owned = try history.toOwnedSlice(alloc);
    return .{
        .history = owned,
        .open_turn = open_turn,
        .running_calls = unanswered,
        .finished = finished,
        .pending_inputs = pending,
        .pending_follow_ups = follow_ups,
        .open_turn_id = open_turn_id,
        .last_turn_id = last_turn_id,
        .yielded = yielded and open_turn != null,
        .cursor = cursor,
    };
}

/// Owned copies of the `kind` inputs neither placed nor withdrawn.
fn pendingInputsOf(alloc: Allocator, inputs: []const InputState, kind: InputKind) Allocator.Error![]PendingInput {
    var count: usize = 0;
    for (inputs) |input| {
        if (input.pending(kind)) count += 1;
    }
    const pending = try alloc.alloc(PendingInput, count);
    var filled: usize = 0;
    errdefer {
        for (pending[0..filled]) |input| {
            alloc.free(input.id);
            alloc.free(input.text);
        }
        alloc.free(pending);
    }
    for (inputs) |input| {
        if (!input.pending(kind)) continue;
        const id = try alloc.dupe(u8, input.id);
        errdefer alloc.free(id);
        pending[filled] = .{ .id = id, .text = try alloc.dupe(u8, input.text) };
        filled += 1;
    }
    return pending;
}

/// Returns the calls in `calls` with no result in `execution`, each id once,
/// in announcement order. On success it takes `calls`, freeing the rest and
/// the slice; on failure the caller still owns `calls`.
fn dropAnswered(alloc: Allocator, calls: []types.ToolCall, execution: types.ExecutionMemory) Allocator.Error![]types.ToolCall {
    var count: usize = 0;
    for (calls, 0..) |_, index| {
        if (keepCall(calls, index, execution)) count += 1;
    }
    const kept = try alloc.alloc(types.ToolCall, count);
    var next: usize = 0;
    for (calls, 0..) |call, index| {
        if (!keepCall(calls, index, execution)) continue;
        kept[next] = call;
        next += 1;
    }
    // Each decision reads only earlier calls, so freeing from the end keeps
    // every call a later decision reads alive.
    var index = calls.len;
    while (index > 0) {
        index -= 1;
        if (!keepCall(calls, index, execution)) types.freeToolCall(alloc, calls[index]);
    }
    alloc.free(calls);
    return kept;
}

fn keepCall(calls: []const types.ToolCall, index: usize, execution: types.ExecutionMemory) bool {
    for (calls[0..index]) |prior| if (std.mem.eql(u8, prior.id, calls[index].id)) return false;
    return !hasResult(execution, calls[index].id);
}

fn hasResult(execution: types.ExecutionMemory, call_id: []const u8) bool {
    for (execution.tool_steps) |step| {
        for (step.tool_results) |result| if (std.mem.eql(u8, result.tool_call_id, call_id)) return true;
    }
    return false;
}

const Envelope = struct {
    kind: EventType,
    data: ?std.json.Value,
    /// The inputs a `turn_progress` places.
    inputs: ?std.json.Value,
    /// The host's id for the turn a first `turn_progress` starts.
    turn_id: ?std.json.Value,
    /// The `seq` of the progress a `turn_progress` extends, when it carries
    /// only what is new.
    base: ?u64,
};

/// Checks one event's envelope against the cursor it must continue.
fn envelope(value: std.json.Value, cursor: Cursor) LoadError!Envelope {
    if (value != .object) return error.InvalidJournal;
    const object = value.object;
    const event_version = try integerField(object, "v");
    if (event_version > version) return error.UnsupportedJournalVersion;
    if (event_version < plain_version) return error.InvalidJournal;
    if (try integerField(object, "seq") != cursor.next_seq) return error.OutOfOrderJournalEvent;
    if (try integerField(object, "turn") != cursor.turn) return error.OutOfOrderJournalEvent;
    const kind_value = object.get("type") orelse return error.InvalidJournal;
    if (kind_value != .string) return error.InvalidJournal;
    const kind = std.meta.stringToEnum(EventType, kind_value.string) orelse return error.InvalidJournal;
    const base: ?u64 = if (object.get("base") != null) try integerField(object, "base") else null;
    // Version 1 has neither a delta progress nor a call's result.
    if (event_version == plain_version and (base != null or kind == .tool_result)) return error.InvalidJournal;
    if (base != null and kind != .turn_progress) return error.InvalidJournal;
    return .{ .kind = kind, .data = object.get("data"), .inputs = object.get("inputs"), .turn_id = object.get("turnId"), .base = base };
}

/// `delta`'s fields over `base`'s, a progress's state that `delta` extends:
/// `base`'s user turn, and each execution list as `base`'s items then
/// `delta`'s. Allocates in `arena` and borrows from both.
fn mergeDelta(arena: Allocator, base: std.json.Value, delta: std.json.Value) LoadError!std.json.Value {
    if (base != .object or delta != .object) return error.InvalidJournal;
    if (delta.object.get("user") != null) return error.InvalidJournal;
    const user = base.object.get("user") orelse return error.InvalidJournal;
    const base_execution = base.object.get("execution") orelse return error.InvalidJournal;
    const delta_execution = delta.object.get("execution") orelse return error.InvalidJournal;
    if (base_execution != .object or delta_execution != .object) return error.InvalidJournal;
    var execution = try delta_execution.object.clone(arena);
    for ([_][]const u8{ "tool_steps", "files", "steering" }) |name| {
        const earlier = base_execution.object.get(name) orelse return error.InvalidJournal;
        const later = delta_execution.object.get(name) orelse return error.InvalidJournal;
        if (earlier != .array or later != .array) return error.InvalidJournal;
        var items = try std.json.Array.initCapacity(arena, earlier.array.items.len + later.array.items.len);
        items.appendSliceAssumeCapacity(earlier.array.items);
        items.appendSliceAssumeCapacity(later.array.items);
        try execution.put(arena, name, .{ .array = items });
    }
    var merged = try delta.object.clone(arena);
    try merged.put(arena, "user", user);
    try merged.put(arena, "execution", .{ .object = execution });
    return .{ .object = merged };
}

/// A progress's `turnId`, if it has one. Borrows from the parse.
fn turnIdOf(value: ?std.json.Value) LoadError!?[]const u8 {
    const id = value orelse return null;
    if (id != .string or id.string.len == 0 or id.string.len > max_turn_id_bytes) return error.InvalidJournal;
    return id.string;
}

fn integerField(object: std.json.ObjectMap, name: []const u8) LoadError!u64 {
    const value = object.get(name) orelse return error.InvalidJournal;
    if (value != .integer or value.integer < 0) return error.InvalidJournal;
    return @intCast(value.integer);
}

/// A current compaction summary stands for every turn before it.
fn replacesHistory(turn: types.HistoryTurn) bool {
    return switch (turn) {
        .compacted_summary => |entry| compactor.replacesPriorContext(entry.summary),
        else => false,
    };
}

fn parseTurn(alloc: Allocator, value: std.json.Value, images: ?*session_codec.ImageResolver) LoadError!types.HistoryTurn {
    return session_codec.parseHistoryTurnWithImages(alloc, value, .{ .names = images }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJournal,
    };
}

fn testTurn(alloc: Allocator, prompt: []const u8, answer: []const u8) !types.HistoryTurn {
    return .{ .assistant = .{
        .user = .{ .text = try alloc.dupe(u8, prompt) },
        .assistant = try alloc.dupe(u8, answer),
    } };
}

fn testProgress(alloc: Allocator, prompt: []const u8) !session_codec.RecoveryCheckpoint {
    return .{
        .turn_id = 7,
        .user = .{ .text = try alloc.dupe(u8, prompt) },
        .assistant_source = try alloc.dupe(u8, ""),
        .cause = .network_interrupted,
        .action = .retrying_request,
        .authority = .{ .provider = .none, .model = try alloc.dupe(u8, "fake/model") },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 3,
        .consumed_provider_attempts = 0,
    };
}

/// Writes `events` as a journal array, the way a host hands them back.
fn testJournal(alloc: Allocator, events: []const Event) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var cursor: Cursor = .{};
    try out.writer.writeByte('[');
    for (events, 0..) |event, index| {
        if (index > 0) try out.writer.writeByte(',');
        cursor = try cursor.write(&out.writer, event);
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

test "a journal folds back into the history it recorded" {
    const alloc = std.testing.allocator;
    const first = try testTurn(alloc, "list files", "two files");
    defer types.freeHistoryTurn(alloc, first);
    const second = try testTurn(alloc, "read one", "it says hi");
    defer types.freeHistoryTurn(alloc, second);
    var progress = try testProgress(alloc, "read one");
    defer progress.deinit(alloc);

    const bytes = try testJournal(alloc, &.{
        .{ .turn_progress = .{ .checkpoint = progress } },
        .{ .turn_committed = first },
        .{ .turn_progress = .{ .checkpoint = progress } },
        .{ .turn_committed = second },
    });
    defer alloc.free(bytes);

    var folded = try fold(alloc, bytes);
    defer folded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), folded.history.len);
    try std.testing.expectEqualStrings("list files", folded.history[0].assistant.user.text);
    try std.testing.expectEqualStrings("it says hi", folded.history[1].assistant.assistant);
    try std.testing.expect(folded.open_turn == null);
    try std.testing.expectEqual(Cursor{ .next_seq = 5, .turn = 3 }, folded.cursor);
}

/// The open turn of `bytes`, folded, as a progress writes it.
fn foldedOpenTurn(alloc: Allocator, bytes: []const u8) ![]u8 {
    var folded = try fold(alloc, bytes);
    defer folded.deinit(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try session_codec.writeRecoveryCheckpoint(&out.writer, folded.open_turn.?);
    return out.toOwnedSlice();
}

fn foldAndFree(alloc: Allocator, bytes: []const u8) !void {
    var folded = try fold(alloc, bytes);
    folded.deinit(alloc);
}

fn testImageUser(alloc: Allocator, png: []const u8) !types.UserTurn {
    const name = session_codec.imageNameOf(png);
    const images = try alloc.alloc(types.ImageAttachment, 1);
    images[0] = .{
        .id = 1,
        .path = try alloc.dupe(u8, "inline://image-1"),
        .media_type = try alloc.dupe(u8, "image/png"),
        .snapshot_sha256 = try alloc.dupe(u8, &name),
        .inline_data = try alloc.dupe(u8, png),
    };
    return .{ .text = try alloc.dupe(u8, "[Image #1]"), .images = images };
}

fn testImageTurn(alloc: Allocator, png: []const u8) !types.HistoryTurn {
    return .{ .assistant = .{ .user = try testImageUser(alloc, png), .assistant = try alloc.dupe(u8, "seen") } };
}
