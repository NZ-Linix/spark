//! Requests of subscription plan accounts (`src/core/auth/plan_kind.zig`):
//! each account's live model list, and how a Claude or Antigravity request
//! carries its effort level and the client identity its plan requires.
//! Spark's own prompt and tools are sent unchanged after that identity.
const std = @import("std");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const model_provider = @import("../core/config/model_provider.zig");
const request_fragment = @import("../core/config/request_fragment.zig");
const secret = @import("../core/auth/secret.zig");
const oauth_http = @import("../builtins/oauth_http.zig");
const chatgpt_plan = @import("../core/auth/chatgpt_plan.zig");
const claude_plan = @import("../core/auth/claude_plan.zig");
const antigravity_plan = @import("../core/auth/antigravity_plan.zig");
const chatgpt_catalog = @import("../core/config/chatgpt_catalog.zig");
const claude_catalog = @import("../core/config/claude_catalog.zig");
const antigravity_catalog = @import("../core/config/antigravity_catalog.zig");
const anthropic_messages = @import("anthropic_messages_protocol.zig");
const gemini = @import("gemini_code_assist_protocol.zig");
const plan_kind = @import("../core/auth/plan_kind.zig");
const io = @import("../core/shared/io.zig");
const Allocator = std.mem.Allocator;

/// The account's catalog as Spark would save it now. Caller owns it.
pub fn liveCatalog(alloc: Allocator, definition: *const definitions.Definition, cancel: ?*std.atomic.Value(bool)) !definitions.Registry {
    const kind = definition.auth.plan() orelse return error.NotAPlanAccount;
    const transport = oauth_http.provider;
    const body = switch (kind) {
        .chatgpt => blk: {
            const token = try chatgpt_plan.accessToken(alloc, transport, definition.id);
            defer secret.zeroAndFree(alloc, token);
            break :blk try chatgpt_plan.fetchModels(alloc, transport, token, cancel);
        },
        .claude => blk: {
            const token = try claude_plan.accessToken(alloc, transport, definition.id);
            defer secret.zeroAndFree(alloc, token);
            break :blk try claude_plan.fetchModels(alloc, transport, token, cancel);
        },
        .antigravity => try antigravity_plan.fetchAccountModels(alloc, transport, definition.id, cancel),
    };
    defer alloc.free(body);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const name = definition.display_name orelse definition.id;
    var map: std.json.ObjectMap = .empty;
    try map.put(a, definition.id, switch (kind) {
        .chatgpt => try chatgpt_catalog.connection(a, name, body),
        .claude => try claude_catalog.connection(a, name, body),
        .antigravity => try antigravity_catalog.connection(a, name, body),
    });
    return definitions.Registry.parse(alloc, .{ .object = map });
}

/// Whether `err` means the account has to sign in again.
pub fn signInRequired(err: anyerror) bool {
    return err == error.ChatGPTSignInRequired or err == error.PlanSignInRequired;
}

/// The fields of `level` as a fragment, from the catalog's own builder for
/// a level the saved catalog doesn't name.
fn fragmentOf(arena: Allocator, value: std.json.Value) !request_fragment.Fragment {
    return request_fragment.parse(arena, value, &.{});
}

fn field(fragment: ?request_fragment.Fragment, key: []const u8) ?[]const u8 {
    for ((fragment orelse return null).fields) |entry| if (std.mem.eql(u8, entry.key, key)) return entry.value_json;
    return null;
}

fn firstUserText(messages: []const types.ChatMessage) []const u8 {
    for (messages) |message| if (message.role == .user) return message.content orelse "";
    return "";
}

/// A Claude account's request: Messages API with Claude Code's client
/// identity first in `system`, then Spark's prompt.
pub fn buildClaude(alloc: Allocator, definition: *const definitions.Definition, identity: *const model_provider.ProviderId, request: streams.RequestData) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const metadata = definition.metadata_for(request.model);
    var level: ?request_fragment.Fragment = null;
    if (request.provider_options.reasoning) |effort| {
        const saved = if (metadata) |known| known.effort(effort.label()) else null;
        level = if (saved) |found| found.fields else try fragmentOf(a, try claude_catalog.levelFields(a, .adaptive, true, effort.label()));
    }
    const billing = try claude_plan.billingHeader(a, firstUserText(request.messages));
    const limit: u32 = if (metadata) |known| @min(known.max_output_tokens orelse 32_000, 64_000) else 32_000;
    return anthropic_messages.build_request(alloc, request, .{
        .provider = identity,
        .effort_fields = level,
        .automatic_cache = true,
        .system_prefix = &.{ billing, claude_plan.identity },
        .default_max_tokens = limit,
    });
}

/// An Antigravity account's request: the tier's model and thinking
/// settings of the chosen level, else the model's own defaults.
pub fn buildAntigravity(alloc: Allocator, definition: *const definitions.Definition, identity: *const model_provider.ProviderId, request: streams.RequestData) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const metadata = definition.metadata_for(request.model);
    var chosen: ?request_fragment.Fragment = if (metadata) |known| known.request else null;
    if (request.provider_options.reasoning) |effort| {
        const saved = if (metadata) |known| known.effort(effort.label()) else null;
        chosen = if (saved) |found| found.fields else try fragmentOf(a, try antigravity_catalog.fallbackFields(a, request.model, effort.label()));
    }
    const model: ?[]const u8 = if (field(chosen, "model")) |json| try std.json.parseFromSliceLeaky([]const u8, a, json, .{}) else null;
    var thinking = field(chosen, "thinkingConfig");
    // A model that thinks shows its thoughts even when no level was picked.
    if (thinking == null) if (metadata) |known| if (known.reasoning_efforts) |levels| if (levels.len != 0) {
        thinking = "{\"includeThoughts\":true}";
    };
    return gemini.build_request(alloc, request, .{
        .provider = identity,
        .model = model,
        .thinking_json = thinking,
        .default_max_tokens = if (metadata) |known| known.max_output_tokens else null,
    });
}

/// The key a plan's server keeps the session's cached prompt under. Codex
/// and Antigravity route a request to the cache of an earlier one by it; a
/// long session ID is hashed to the length they accept.
fn cacheKey(buf: *[64]u8, session_id: []const u8) []const u8 {
    if (session_id.len <= 64) return session_id;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(session_id, &digest, .{});
    buf.* = std.fmt.bytesToHex(digest, .lower);
    return buf;
}

/// The cache key of requests without a session (`spark ask --no-save`): one
/// per process, so a run's requests still share their cached prompt.
var process_key: [32]u8 = undefined;
var process_key_state: std.atomic.Value(u8) = .init(0);

fn processKey() []const u8 {
    if (process_key_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        var random: [16]u8 = undefined;
        io.getIo().random(&random);
        process_key = std.fmt.bytesToHex(random, .lower);
        process_key_state.store(2, .release);
    }
    while (process_key_state.load(.acquire) != 2) std.atomic.spinLoopHint();
    return &process_key;
}

/// The body a plan account sends: an Antigravity account's Cloud Code
/// project put in place, and the session's prompt-cache key added for Codex
/// (`prompt_cache_key`) and Antigravity (`request.sessionId`). Null when
/// `payload` goes as it is. Caller owns the result.
pub fn sendBody(alloc: Allocator, kind: plan_kind.Kind, payload: []const u8, project: ?[]const u8, session_id: ?[]const u8) !?[]u8 {
    var buf: [64]u8 = undefined;
    const key: []const u8 = if (session_id) |id| if (id.len != 0) cacheKey(&buf, id) else processKey() else processKey();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    switch (kind) {
        .claude => return null,
        .chatgpt => {
            const value = key;
            if (!std.mem.startsWith(u8, payload, "{\"")) return error.InvalidPlanRequest;
            try out.writer.writeAll("{\"prompt_cache_key\":");
            try std.json.Stringify.value(value, .{}, &out.writer);
            try out.writer.writeByte(',');
            try out.writer.writeAll(payload[1..]);
        },
        .antigravity => {
            if (!std.mem.startsWith(u8, payload, gemini.project_placeholder)) return error.InvalidPlanRequest;
            try out.writer.writeAll("{\"project\":");
            try std.json.Stringify.value(project orelse return error.InvalidPlanRequest, .{}, &out.writer);
            var rest = payload[gemini.project_placeholder.len..];
            {
                const value = key;
                // The model ID before it is a JSON string, so this is the
                // request object's opening.
                const opening = ",\"request\":{";
                const at = std.mem.find(u8, rest, opening) orelse return error.InvalidPlanRequest;
                try out.writer.writeAll(rest[0 .. at + opening.len]);
                try out.writer.writeAll("\"sessionId\":");
                try std.json.Stringify.value(value, .{}, &out.writer);
                try out.writer.writeByte(',');
                rest = rest[at + opening.len ..];
            }
            try out.writer.writeAll(rest);
        },
    }
    return try out.toOwnedSlice();
}

test "Claude requests open the system prompt with the client identity and pick the saved level" {
    const a = std.testing.allocator;
    const id = "claude-plan-00000000000000000000000000000001";
    var registry = try definitions.Registry.parse_json(a,
        \\{"claude-plan-00000000000000000000000000000001":{"auth":{"type":"claude-plan"},"protocol":"anthropic-messages","base_url":"https://api.anthropic.com/v1",
        \\ "display_name":"Claude (Work)","model_metadata":{"claude-sonnet-5-5":{"max_output_tokens":128000,
        \\ "reasoning_efforts":{"xhigh":{"thinking":{"type":"adaptive","display":"summarized"},"output_config":{"effort":"xhigh"}}}}}}}
    );
    defer registry.deinit(a);
    const definition = registry.get(id).?;
    var identity = model_provider.parse(id).?;
    identity.configured.binding = definition.binding_identity();
    var request: streams.RequestData = .{
        .model = "claude-sonnet-5-5",
        .instructions = &.{.{ .role = .system, .content = "Spark's prompt", .cache_breakpoint = true }},
        .messages = &.{.{ .role = .user, .content = "hello world, this is a test" }},
        .tool_choice = .auto,
        .provider_options = .{},
    };
    request.provider_options.reasoning = .literal("xhigh");
    const body = try buildClaude(a, definition, &identity, request);
    defer a.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const system = root.get("system").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), system.len);
    try std.testing.expect(std.mem.startsWith(u8, system[0].object.get("text").?.string, "x-anthropic-billing-header: cc_version=" ++ claude_plan.cli_version ++ "."));
    try std.testing.expectEqualStrings(claude_plan.identity, system[1].object.get("text").?.string);
    try std.testing.expectEqualStrings("Spark's prompt", system[2].object.get("text").?.string);
    try std.testing.expectEqual(@as(i64, 64_000), root.get("max_tokens").?.integer);
    try std.testing.expectEqualStrings("adaptive", root.get("thinking").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("xhigh", root.get("output_config").?.object.get("effort").?.string);
    // A level the saved catalog doesn't name comes from the live catalog's rule.
    request.provider_options.reasoning = .literal("low");
    const fallback = try buildClaude(a, definition, &identity, request);
    defer a.free(fallback);
    try std.testing.expect(std.mem.find(u8, fallback, "\"output_config\":{\"effort\":\"low\"}") != null);
}

test "Antigravity requests send a tier's model and the account's project" {
    const a = std.testing.allocator;
    const id = "antigravity-plan-00000000000000000000000000000001";
    var registry = try definitions.Registry.parse_json(a,
        \\{"antigravity-plan-00000000000000000000000000000001":{"auth":{"type":"antigravity-plan"},"protocol":"gemini-code-assist","base_url":"https://daily-cloudcode-pa.googleapis.com",
        \\ "display_name":"Antigravity (1)","model_metadata":{"gemini-3.8-flash":{"max_output_tokens":65536,
        \\ "request":{"model":"gemini-3.8-flash-high","thinkingConfig":{"includeThoughts":true,"thinkingLevel":"high"}},
        \\ "reasoning_efforts":{"low":{"model":"gemini-3.8-flash-low","thinkingConfig":{"includeThoughts":true,"thinkingLevel":"low"}}}}}}}
    );
    defer registry.deinit(a);
    const definition = registry.get(id).?;
    var identity = model_provider.parse(id).?;
    identity.configured.binding = definition.binding_identity();
    var request: streams.RequestData = .{
        .model = "gemini-3.8-flash",
        .messages = &.{.{ .role = .user, .content = "hi" }},
        .tool_choice = .auto,
        .provider_options = .{},
    };
    const plain = try buildAntigravity(a, definition, &identity, request);
    defer a.free(plain);
    try std.testing.expect(std.mem.find(u8, plain, "\"model\":\"gemini-3.8-flash-high\"") != null);
    request.provider_options.reasoning = .literal("low");
    const low = try buildAntigravity(a, definition, &identity, request);
    defer a.free(low);
    try std.testing.expect(std.mem.find(u8, low, "\"model\":\"gemini-3.8-flash-low\"") != null);
    try std.testing.expect(std.mem.find(u8, low, "\"thinkingLevel\":\"low\"") != null);
    const sent = (try sendBody(a, .antigravity, low, "proj-1", "session-1")).?;
    defer a.free(sent);
    try std.testing.expect(std.mem.startsWith(u8, sent, "{\"project\":\"proj-1\",\"model\":"));
    const parsed = try std.json.parseFromSlice(std.json.Value, a, sent, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("session-1", parsed.value.object.get("request").?.object.get("sessionId").?.string);
    try std.testing.expect(parsed.value.object.get("request").?.object.get("contents") != null);
    // Without a session, the process's own key, the same for each request.
    const first = (try sendBody(a, .antigravity, low, "proj-1", null)).?;
    defer a.free(first);
    const again = (try sendBody(a, .antigravity, low, "proj-1", "")).?;
    defer a.free(again);
    const unsaved = try std.json.parseFromSlice(std.json.Value, a, first, .{});
    defer unsaved.deinit();
    const key = unsaved.value.object.get("request").?.object.get("sessionId").?.string;
    try std.testing.expectEqual(@as(usize, 32), key.len);
    try std.testing.expect(std.mem.find(u8, again, key) != null);
}

test "Codex requests carry the session's prompt-cache key and Claude's go as built" {
    const a = std.testing.allocator;
    const body = (try sendBody(a, .chatgpt, "{\"model\":\"gpt\",\"stream\":true}", null, "session-1")).?;
    defer a.free(body);
    try std.testing.expectEqualStrings("{\"prompt_cache_key\":\"session-1\",\"model\":\"gpt\",\"stream\":true}", body);
    const long: [100]u8 = @splat('s');
    const hashed = (try sendBody(a, .chatgpt, "{\"model\":\"gpt\"}", null, &long)).?;
    defer a.free(hashed);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, hashed, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 64), parsed.value.object.get("prompt_cache_key").?.string.len);
    try std.testing.expect(try sendBody(a, .claude, "{\"model\":\"claude\"}", null, "session-1") == null);
}
