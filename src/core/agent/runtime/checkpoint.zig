const std = @import("std");
const types = @import("../../shared/types.zig");
const text_utils = @import("../../shared/text_utils.zig");
const session_codec = @import("../../session/session_codec.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const magic = "FXCP";
/// Version 2 stores inline image bytes raw in a blob section after the JSON.
/// Its little-endian payload is:
///   u32 json_len | json | u32 blob_count | (u32 blob_len | blob)*
const version: u16 = 2;
/// Version 3 has version 2's layout, and its JSON may name images instead of
/// holding their bytes: ones the host stored (`inline_ref`), or ones the
/// session dropped. Only a checkpoint that names one is version 3, so an spark
/// that reads only version 2 reports a newer checkpoint instead of an
/// invalid one.
const naming_version: u16 = 3;
/// Version 4 has version 3's layout, and its history holds a turn with
/// context notes or a saved runtime context (D93, D94), so an spark that reads
/// only up to version 3 reports a newer checkpoint instead of an invalid one.
const notes_version: u16 = 4;
/// Version 1 embedded inline image bytes as base64 inside a JSON-only payload.
const json_only_version: u16 = 1;
const header_bytes: usize = 4 + 2 + 2 + 4 + Sha256.digest_length;
const length_bytes: usize = 4;
pub const max_checkpoint_bytes: usize = 4 * 1024 * 1024;
pub const max_history_turns: usize = 1024;

pub const Error = Allocator.Error || error{
    CheckpointTooLarge,
    CorruptCheckpoint,
    InvalidCheckpoint,
    UnsupportedCheckpointVersion,
};

/// What a checkpoint records about the agent that saved it, so a resume can
/// tell when it continues with another libfx, other tools, or another model.
/// Each field is the host's opaque text, at most `max_meta_field_bytes`;
/// empty when it gave none. Older checkpoints carry none, and readers that
/// predate it ignore it.
pub const Meta = struct {
    libfx_version: []const u8 = "",
    tool_schema_hash: []const u8 = "",
    model: []const u8 = "",

    pub fn isEmpty(self: Meta) bool {
        return self.libfx_version.len == 0 and self.tool_schema_hash.len == 0 and self.model.len == 0;
    }

    pub fn fits(self: Meta) bool {
        return self.libfx_version.len <= max_meta_field_bytes and
            self.tool_schema_hash.len <= max_meta_field_bytes and
            self.model.len <= max_meta_field_bytes;
    }

    /// A copy owned by `alloc`, for `free`.
    pub fn dupe(self: Meta, alloc: Allocator) Allocator.Error!Meta {
        const libfx_version = try alloc.dupe(u8, self.libfx_version);
        errdefer alloc.free(libfx_version);
        const tool_schema_hash = try alloc.dupe(u8, self.tool_schema_hash);
        errdefer alloc.free(tool_schema_hash);
        return .{ .libfx_version = libfx_version, .tool_schema_hash = tool_schema_hash, .model = try alloc.dupe(u8, self.model) };
    }

    /// Frees a `Meta` that `dupe` or `decode` returned.
    pub fn free(self: Meta, alloc: Allocator) void {
        alloc.free(self.libfx_version);
        alloc.free(self.tool_schema_hash);
        alloc.free(self.model);
    }

    /// Writes it as the JSON object `fromJson` reads.
    pub fn writeJson(self: Meta, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("{\"libfxVersion\":");
        try std.json.Stringify.value(self.libfx_version, .{}, writer);
        try writer.writeAll(",\"toolSchemaHash\":");
        try std.json.Stringify.value(self.tool_schema_hash, .{}, writer);
        try writer.writeAll(",\"model\":");
        try std.json.Stringify.value(self.model, .{}, writer);
        try writer.writeByte('}');
    }
};
/// As long as the longest model id a host may give.
pub const max_meta_field_bytes: usize = 1024;

pub const Decoded = struct {
    history: []types.HistoryTurn,
    usage: types.Usage,
    /// Owned by the decoding allocator.
    meta: Meta,

    pub fn deinit(self: *Decoded, alloc: Allocator) void {
        types.freeHistoryTurnSlice(alloc, self.history);
        self.meta.free(alloc);
        self.* = undefined;
    }
};

/// `meta` is recorded when any of its fields is set; each must fit
/// `max_meta_field_bytes`. The checkpoint holds every image's bytes.
pub fn encode(
    alloc: Allocator,
    history: []const types.HistoryTurn,
    usage: types.Usage,
    meta: Meta,
) Error![]u8 {
    return encodeWith(alloc, history, usage, meta, null);
}

/// Like `encode`, but names the images `stored` holds instead of holding
/// their bytes.
pub fn encodeNamingImages(
    alloc: Allocator,
    history: []const types.HistoryTurn,
    usage: types.Usage,
    meta: Meta,
    stored: *const session_codec.StoredImages,
) Error![]u8 {
    return encodeWith(alloc, history, usage, meta, stored);
}

fn encodeWith(
    alloc: Allocator,
    history: []const types.HistoryTurn,
    usage: types.Usage,
    meta: Meta,
    stored: ?*const session_codec.StoredImages,
) Error![]u8 {
    std.debug.assert(meta.fits());
    if (history.len > max_history_turns) return error.CheckpointTooLarge;
    const payload_limit = max_checkpoint_bytes - header_bytes;
    var json: std.Io.Writer.Allocating = .init(alloc);
    defer json.deinit();
    var blobs: std.ArrayList([]const u8) = .empty;
    defer blobs.deinit(alloc);
    const image_blobs: session_codec.ImageBlobs = .{ .alloc = alloc, .items = &blobs };
    var blob_section_bytes: usize = 0;
    var names_images = false;
    var uses_notes = false;

    json.writer.writeAll("{\"history\":[") catch return error.OutOfMemory;
    for (history, 0..) |turn, index| {
        if (index > 0) json.writer.writeByte(',') catch return error.OutOfMemory;
        const first_new_blob = blobs.items.len;
        names_images = names_images or session_codec.turnNamesImages(turn, stored);
        uses_notes = uses_notes or session_codec.turnUsesNotesSchema(turn);
        const written = if (stored) |names|
            session_codec.writeHistoryTurnNamingImages(&json.writer, turn, .{ .stored = names, .blobs = image_blobs })
        else
            session_codec.writeHistoryTurnWithImageBlobs(&json.writer, turn, image_blobs);
        written catch |err| switch (err) {
            error.InvalidSessionFormat => return error.InvalidCheckpoint,
            else => return error.OutOfMemory,
        };
        for (blobs.items[first_new_blob..]) |blob| blob_section_bytes +|= length_bytes +| blob.len;
        if (payloadBytes(json.written().len, blob_section_bytes) > payload_limit) {
            return error.CheckpointTooLarge;
        }
    }
    json.writer.writeAll("],\"usage\":") catch return error.OutOfMemory;
    std.json.Stringify.value(usage, .{}, &json.writer) catch return error.OutOfMemory;
    if (!meta.isEmpty()) {
        json.writer.writeAll(",\"meta\":") catch return error.OutOfMemory;
        meta.writeJson(&json.writer) catch return error.OutOfMemory;
    }
    json.writer.writeByte('}') catch return error.OutOfMemory;
    const payload_len = payloadBytes(json.written().len, blob_section_bytes);
    if (payload_len > payload_limit) return error.CheckpointTooLarge;

    // Every length below is bounded by payload_limit, so each fits in a u32.
    const out = try alloc.alloc(u8, header_bytes + payload_len);
    var cursor: usize = header_bytes;
    writeSection(out, &cursor, json.written());
    writeLength(out, &cursor, blobs.items.len);
    for (blobs.items) |blob| writeSection(out, &cursor, blob);
    std.debug.assert(cursor == out.len);

    @memcpy(out[0..magic.len], magic);
    std.mem.writeInt(u16, out[4..6], if (uses_notes) notes_version else if (names_images) naming_version else version, .little);
    std.mem.writeInt(u16, out[6..8], 0, .little);
    std.mem.writeInt(u32, out[8..12], @intCast(payload_len), .little);
    Sha256.hash(out[header_bytes..], out[12..header_bytes], .{});
    return out;
}

fn payloadBytes(json_len: usize, blob_section_bytes: usize) usize {
    return length_bytes +| json_len +| length_bytes +| blob_section_bytes;
}

fn writeLength(out: []u8, cursor: *usize, value: usize) void {
    std.mem.writeInt(u32, out[cursor.*..][0..length_bytes], @intCast(value), .little);
    cursor.* += length_bytes;
}

fn writeSection(out: []u8, cursor: *usize, bytes: []const u8) void {
    writeLength(out, cursor, bytes.len);
    @memcpy(out[cursor.*..][0..bytes.len], bytes);
    cursor.* += bytes.len;
}

pub fn decode(alloc: Allocator, bytes: []const u8) Error!Decoded {
    return decodeWithImages(alloc, bytes, null);
}

/// Like `decode`, but resolves named images through `names`. Without it a
/// checkpoint that names images is invalid. A name `names` cannot resolve is
/// recorded there, and the decoded images it names have no bytes.
pub fn decodeWithImages(alloc: Allocator, bytes: []const u8, names: ?*session_codec.ImageResolver) Error!Decoded {
    if (bytes.len < header_bytes or bytes.len > max_checkpoint_bytes) {
        return error.CorruptCheckpoint;
    }
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.CorruptCheckpoint;
    const checkpoint_version = std.mem.readInt(u16, bytes[4..6], .little);
    if (checkpoint_version != version and checkpoint_version != json_only_version and
        checkpoint_version != naming_version and checkpoint_version != notes_version)
    {
        return error.UnsupportedCheckpointVersion;
    }
    if (std.mem.readInt(u16, bytes[6..8], .little) != 0) {
        return error.CorruptCheckpoint;
    }
    const payload_len: usize = std.mem.readInt(u32, bytes[8..12], .little);
    if (payload_len != bytes.len - header_bytes) return error.CorruptCheckpoint;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes[header_bytes..], &digest, .{});
    if (!std.crypto.timing_safe.eql([Sha256.digest_length]u8, digest, bytes[12..header_bytes].*)) {
        return error.CorruptCheckpoint;
    }
    const payload = bytes[header_bytes..];
    if (checkpoint_version == json_only_version) return decodeJson(alloc, payload, .{});

    var reader: PayloadReader = .{ .bytes = payload };
    const json = reader.section() orelse return error.CorruptCheckpoint;
    const blob_count = reader.length() orelse return error.CorruptCheckpoint;
    // Every blob needs at least its length prefix.
    if (blob_count > reader.remaining() / length_bytes) return error.CorruptCheckpoint;
    const blobs = try alloc.alloc([]const u8, blob_count);
    defer alloc.free(blobs);
    for (blobs) |*blob| blob.* = reader.section() orelse return error.CorruptCheckpoint;
    if (reader.remaining() != 0) return error.CorruptCheckpoint;
    var blob_reader: session_codec.ImageBlobReader = .{ .blobs = blobs };
    // Only a version 3 or 4 checkpoint names images.
    return decodeJson(alloc, json, .{
        .blobs = &blob_reader,
        .names = if (checkpoint_version == naming_version or checkpoint_version == notes_version) names else null,
    });
}

/// Reads length-prefixed sections from a version 2 payload. Returned slices
/// borrow from `bytes`.
const PayloadReader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn remaining(self: PayloadReader) usize {
        return self.bytes.len - self.offset;
    }

    fn length(self: *PayloadReader) ?usize {
        if (self.remaining() < length_bytes) return null;
        const value = std.mem.readInt(u32, self.bytes[self.offset..][0..length_bytes], .little);
        self.offset += length_bytes;
        return value;
    }

    fn section(self: *PayloadReader) ?[]const u8 {
        const len = self.length() orelse return null;
        if (len > self.remaining()) return null;
        const bytes = self.bytes[self.offset..][0..len];
        self.offset += len;
        return bytes;
    }
};

fn decodeJson(alloc: Allocator, json: []const u8, images: session_codec.ImageSources) Error!Decoded {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        json,
        .{},
    ) catch return error.InvalidCheckpoint;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCheckpoint;
    const history_value = parsed.value.object.get("history") orelse
        return error.InvalidCheckpoint;
    const usage_value = parsed.value.object.get("usage") orelse
        return error.InvalidCheckpoint;
    if (history_value != .array or history_value.array.items.len > max_history_turns) {
        return error.InvalidCheckpoint;
    }
    const history = try alloc.alloc(types.HistoryTurn, history_value.array.items.len);
    var decoded_count: usize = 0;
    errdefer {
        for (history[0..decoded_count]) |turn| types.freeHistoryTurn(alloc, turn);
        alloc.free(history);
    }
    for (history_value.array.items, 0..) |turn_value, index| {
        history[index] = session_codec.parseHistoryTurnWithImages(alloc, turn_value, images) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidCheckpoint,
        };
        decoded_count += 1;
    }
    if (images.blobs) |blobs| {
        if (!blobs.consumedAll()) return error.InvalidCheckpoint;
    }
    const usage = std.json.parseFromValueLeaky(types.Usage, alloc, usage_value, .{}) catch
        return error.InvalidCheckpoint;
    const meta = try decodeMeta(alloc, parsed.value.object.get("meta"));
    return .{ .history = history, .usage = usage, .meta = meta };
}

fn decodeMeta(alloc: Allocator, value: ?std.json.Value) Error!Meta {
    const borrowed = if (value) |found| metaFromJson(found) catch return error.InvalidCheckpoint else Meta{};
    return borrowed.dupe(alloc);
}

/// Reads the object `Meta.writeJson` writes; fields it does not know are
/// left alone. The result borrows from `value`.
pub fn metaFromJson(value: std.json.Value) error{InvalidMeta}!Meta {
    if (value != .object) return error.InvalidMeta;
    var meta: Meta = .{};
    inline for (.{ .{ "libfxVersion", "libfx_version" }, .{ "toolSchemaHash", "tool_schema_hash" }, .{ "model", "model" } }) |field| {
        if (value.object.get(field[0])) |text| {
            if (text != .string) return error.InvalidMeta;
            @field(meta, field[1]) = text.string;
        }
    }
    if (!meta.fits()) return error.InvalidMeta;
    return meta;
}

test "kernel checkpoint round trips history and usage" {
    const alloc = std.testing.allocator;
    const history = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("hello") },
        .assistant = @constCast("world"),
    } }};
    const bytes = try encode(alloc, &history, .{ .input_tokens = 3, .output_tokens = 2 }, .{});
    defer alloc.free(bytes);
    var decoded = try decode(alloc, bytes);
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), decoded.history.len);
    try std.testing.expectEqualStrings("hello", decoded.history[0].assistant.user.text);
    try std.testing.expectEqualStrings("world", decoded.history[0].assistant.assistant);
    try std.testing.expectEqual(@as(?u64, 3), decoded.usage.input_tokens);
}

fn resealForTest(bytes: []u8) void {
    std.mem.writeInt(u32, bytes[8..12], @intCast(bytes.len - header_bytes), .little);
    Sha256.hash(bytes[header_bytes..], bytes[12..header_bytes], .{});
}

const TestImageHistory = struct {
    digest_hex: [Sha256.digest_length * 2]u8,
    images: [1]types.ImageAttachment,
    history: [1]types.HistoryTurn,

    fn init(self: *TestImageHistory, png: []const u8) void {
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(png, &digest, .{});
        self.digest_hex = std.fmt.bytesToHex(digest, .lower);
        self.images = .{.{
            .id = 2,
            .path = @constCast("inline://image-2"),
            .media_type = @constCast("image/png"),
            .snapshot_sha256 = &self.digest_hex,
            .inline_data = @constCast(png),
        }};
        self.history = .{.{ .assistant = .{
            .user = .{ .text = @constCast("[Image #2]"), .images = &self.images },
            .assistant = @constCast("ok"),
        } }};
    }
};

/// A history of one turn whose one tool call returned one image, held as
/// base64 and named as the host stored it.
const TestToolImageHistory = struct {
    digest_hex: [Sha256.digest_length * 2]u8,
    encoded: [64]u8,
    images: [1]types.ToolImage,
    calls: [1]types.ToolCall,
    results: [1]types.PersistedToolResult,
    steps: [1]types.ToolExecutionStep,
    history: [1]types.HistoryTurn,

    fn init(self: *TestToolImageHistory, png: []const u8) void {
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(png, &digest, .{});
        self.digest_hex = std.fmt.bytesToHex(digest, .lower);
        const data = std.base64.standard.Encoder.encode(&self.encoded, png);
        self.images = .{.{ .data = @constCast(data), .mime_type = @constCast("image/png"), .name = self.digest_hex }};
        self.calls = .{.{ .id = "call-1", .name = "screenshot", .arguments_json = "{}" }};
        self.results = .{.{
            .tool_images = &self.images,
            .tool_call_id = @constCast("call-1"),
            .tool_name = @constCast("screenshot"),
            .status = .success,
            .output = @constCast("took it"),
            .output_bytes = 7,
            .stored_output_bytes = 7,
        }};
        self.steps = .{.{ .tool_calls = &self.calls, .tool_results = &self.results }};
        self.history = .{.{ .assistant = .{
            .user = .{ .text = @constCast("look") },
            .assistant = @constCast("seen"),
            .execution = .{ .tool_steps = &self.steps },
        } }};
    }
};
