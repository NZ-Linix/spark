const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const config_runtime = @import("../config/config_runtime.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_event = @import("session_event.zig");
const session_replay = @import("session_replay.zig");
const Allocator = std.mem.Allocator;

const authority_module = @import("session_authority.zig");
const paths = @import("session_store_paths.zig");
const types = @import("session_store_types.zig");

const openSessionFile = authority_module.openSessionFile;
const validateWorkspaceRoot = paths.validateWorkspaceRoot;
const StoreContext = types.StoreContext;

// The read path for v1's legacy and schema-3 formats, which the converter
// and salvage use. No release is set for its removal (D65), and nothing
// writes these formats.

pub const LegacyStoredSession = struct {
    id: []u8,
    workspace_root: ?[]u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64,
    conversation_language: session.ConversationLanguage,
    history: []session.HistoryTurn,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    total_web_search_requests: u64 = 0,

    /// Frees owned session fields and history turns.
    pub fn deinit(self: *LegacyStoredSession, alloc: Allocator) void {
        if (self.id.len > 0) alloc.free(self.id);
        if (self.workspace_root) |wr| alloc.free(wr);
        session.freeHistoryTurnSlice(alloc, self.history);
        self.* = undefined;
    }
};

/// Reads one valid schema-v3 committed prefix and converts it directly to the
/// current conversation format. The v3 log is an import source only; none of
/// its watermark, checkpoint, or replacement writers run.
pub const SchemaV3Import = struct {
    state: session_codec.DurableSessionState,
    source_bytes: u64,
    generation: session_event.Identifier,

    pub fn deinit(self: *SchemaV3Import, alloc: Allocator) void {
        self.state.deinit(alloc);
        self.* = undefined;
    }

    pub fn takeState(self: *SchemaV3Import) session_codec.DurableSessionState {
        const state = self.state;
        self.* = undefined;
        return state;
    }
};

/// Reads the schema-v3 watermark's committed prefix. The manifest is only a
/// derived projection and may lag an acknowledged commit or be absent.
pub fn loadSchemaV3ReadOnly(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !SchemaV3Import {
    var events = try openSessionFile(session_dir, "events.jsonl", .read_only);
    defer events.close(io_mod.getIo());
    const generation = try session_replay.readFirstGeneration(alloc, events);
    const watermark_name = try alloc.print("commit.{s}.json", .{
        std.fmt.bytesToHex(generation, .lower),
    });
    defer alloc.free(watermark_name);
    const watermark_bytes = try authority_module.readOptionalSessionFile(
        alloc,
        session_dir,
        watermark_name,
        16 * 1024,
    ) orelse return error.InvalidSessionFormat;
    defer alloc.free(watermark_bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, watermark_bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();
    const object = try authority_module.exactJsonObject(parsed.value, &.{
        "schema_version",   "session_id",              "log_generation", "through_seq",
        "through_event_id", "through_event_log_bytes",
    });
    const recorded_generation = try authority_module.parseIdentifier(
        try authority_module.objectString(object, "log_generation"),
    );
    if (try authority_module.jsonU64(object, "schema_version") != 1 or
        !std.mem.eql(u8, try authority_module.objectString(object, "session_id"), session_id) or
        !std.mem.eql(u8, &recorded_generation, &generation))
    {
        return error.InvalidSessionFormat;
    }
    const event_id = try authority_module.parseIdentifier(
        try authority_module.objectString(object, "through_event_id"),
    );
    const committed_bytes = try authority_module.jsonU64(object, "through_event_log_bytes");
    var replayed = try session_replay.replayCommittedPrefix(
        alloc,
        events,
        generation,
        try authority_module.jsonU64(object, "through_seq"),
        committed_bytes,
    );
    errdefer replayed.deinit(alloc);
    if (!std.mem.eql(u8, replayed.state.id, session_id) or
        !std.mem.eql(u8, &replayed.position.through_event_id, &event_id))
    {
        return error.InvalidSessionFormat;
    }
    if (try replayed.state.archive_legacy_recovery(alloc)) {
        @import("../shared/debug_trace.zig").logf("session", "legacy recovery archived session_id={s} reason=unverifiable_route_authority", .{session_id});
    }
    const state = replayed.takeState();
    return .{
        .state = state,
        .source_bytes = committed_bytes,
        .generation = generation,
    };
}

/// Converts a parsed legacy session into a validated `DurableSessionState`,
/// resolving the origin/current workspace roots and merging preferences from
/// the requested or preserved workspace. Consumes `legacy` (transfers its
/// owned id/history into the returned state).
pub fn legacyToDurableState(
    ctx: StoreContext,
    alloc: Allocator,
    legacy: *LegacyStoredSession,
) !session_codec.DurableSessionState {
    const root = legacy.workspace_root orelse ctx.workspace_root;
    try validateWorkspaceRoot(root);
    const origin = if (legacy.workspace_root != null)
        legacy.workspace_root.?
    else
        try alloc.dupe(u8, root);
    errdefer if (legacy.workspace_root == null) alloc.free(origin);
    const current = try alloc.dupe(u8, root);
    errdefer alloc.free(current);
    const preferences = try loadMigrationPreferences(ctx, alloc, root);
    errdefer {
        var owned = preferences;
        owned.deinit(alloc);
    }
    const state = session_codec.DurableSessionState{
        .id = legacy.id,
        .origin_workspace_root = origin,
        .workspace_root = current,
        .created_at_ms = legacy.created_at_ms,
        .updated_at_ms = legacy.updated_at_ms,
        .conversation_language = legacy.conversation_language,
        .preferences = preferences,
        .history = legacy.history,
        .total_input_tokens = legacy.total_input_tokens,
        .total_output_tokens = legacy.total_output_tokens,
    };
    legacy.id = &.{};
    legacy.workspace_root = null;
    legacy.history = &.{};
    try session_codec.validateState(state);
    return state;
}

fn loadMigrationPreferences(
    ctx: StoreContext,
    alloc: Allocator,
    workspace_root: []const u8,
) !session_codec.DurableSessionPreferences {
    var detailed = try config_runtime.loadMergedSettingsDetailedFromHome(
        alloc,
        ctx.home_dir,
        workspace_root,
    );
    defer detailed.deinit(alloc);
    return .{
        .model = try alloc.dupe(
            u8,
            detailed.settings.models.get(detailed.settings.provider orelse .none) orelse "",
        ),
        .effort = detailed.settings.effort orelse .auto,
        .fast_mode = detailed.settings.fast_mode orelse false,
        .ultrafast_mode = detailed.settings.ultrafast_mode orelse false,
    };
}
