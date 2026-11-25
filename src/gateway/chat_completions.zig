const std = @import("std");
const codec = @import("chat_completions_protocol.zig");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const model_catalog_metadata = @import("../core/gateway/model_catalog_metadata.zig");
const gateway_step = @import("../core/agent/runtime/gateway_step.zig");
const types = @import("../core/shared/types.zig");
const model_provider = @import("../core/config/model_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const sse = @import("sse.zig");
const transport = @import("configured_transport.zig");
const responses = @import("configured_responses.zig");
const responses_protocol = @import("responses_protocol.zig");
const anthropic_messages = @import("anthropic_messages_protocol.zig");
const gemini = @import("gemini_code_assist_protocol.zig");
const plan_requests = @import("plan_requests.zig");
const request_fragment = @import("../core/config/request_fragment.zig");
const Allocator = std.mem.Allocator;

/// Every callback borrows the immutable definition from the owning profile runtime.
pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        // The image fallback asks the connection's own vision model, so it
        // is on only when the settings name one.
        .capabilities = .{ .vision_fallback = definition.vision_model != null, .vision_model = definition.vision_model },
        .title_model = definition.title_model,
        .agent_stream = .{ .context = context, .stream_fn = stream, .build_request_fn = build, .project_replay_fn = replay_projection(definition.protocol) },
        .model_catalog = model_catalog_provider(definition),
        .cli_model_catalog = .{ .context = context, .fetch_fn = fetch_cli_catalog },
    };
}

/// The models the definition declares, and the server's own when its
/// settings turn `fetch_models` on. Borrows the definition, which must
/// outlive the provider.
pub fn model_catalog_provider(definition: *const definitions.Definition) catalog.Provider {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        .context = context,
        .fetch_fn = fetch_catalog,
        .lookup_capabilities_fn = lookup_capabilities,
        .provider_id = bound_identity(definition),
        // A plan's catalog follows the account, which can change any time.
        .refresh_interval_ms = if (definition.auth.plan() != null) 60_000 else null,
    };
}

fn definition_at(raw: ?*anyopaque) *const definitions.Definition {
    return @ptrCast(@alignCast(raw.?));
}

fn bound_identity(definition: *const definitions.Definition) model_provider.ProviderId {
    var identity = model_provider.parse(definition.id).?;
    identity.configured.binding = definition.binding_identity();
    return identity;
}

fn build(raw: ?*anyopaque, alloc: Allocator, request: streams.RequestData) ![]u8 {
    return build_for(definition_at(raw), alloc, request);
}

/// The request body for `definition`, omitting replay parts recorded for
/// another endpoint. Caller owns the result.
pub fn build_for(definition: *const definitions.Definition, alloc: Allocator, request: streams.RequestData) ![]u8 {
    const identity = bound_identity(definition);
    for (request.messages) |message| if (message.provider_replay) |replay| {
        if (!replay.matches(.{ .provider = identity, .model = request.model })) {
            debug_trace.logf("gateway", "provider_replay_omitted reason=source_mismatch", .{});
            break;
        }
    };
    const metadata = definition.metadata_for(request.model);
    switch (definition.auth) {
        .claude_plan => return plan_requests.buildClaude(alloc, definition, &identity, request),
        .antigravity_plan => return plan_requests.buildAntigravity(alloc, definition, &identity, request),
        else => {},
    }
    if (definition.auth == .chatgpt_plan) {
        // The catalog may have updated since the login snapshot was saved.
        // The selected account's live catalog supplies the picker choices;
        // OpenAI validates the effort again when it receives the request.
        const effort = request.provider_options.reasoning;
        var buffer: [256]u8 = undefined;
        var json = std.Io.Writer.fixed(&buffer);
        var fields: [1]request_fragment.Field = undefined;
        if (effort) |value| {
            try json.writeAll("{\"effort\":");
            try std.json.Stringify.value(value.label(), .{}, &json);
            if (!std.mem.eql(u8, value.label(), "none")) try json.writeAll(",\"summary\":\"auto\"");
            try json.writeByte('}');
            fields[0] = .{ .key = "reasoning", .value_json = json.buffered() };
        }
        return responses.build_request(alloc, request, .{
            .provider = &identity,
            .chatgpt_plan = true,
            .effort_fields = if (effort != null) .{ .fields = &fields } else null,
            .include_reasoning = if (effort) |value| !std.mem.eql(u8, value.label(), "none") else declares_efforts(metadata),
        });
    }
    const request_fields: request_fragment.Fragment = if (metadata) |known| known.request orelse .{} else .{};
    const level = effort_fields(metadata, request.provider_options.reasoning);
    return switch (definition.protocol) {
        .@"openai-chat-completions" => codec.build_request(alloc, request, .{
            .tool_choice_mode = definition.tool_choice_mode,
            .provider = &identity,
            .output_limit_field = if (metadata) |known| known.output_limit_field orelse .max_tokens else .max_tokens,
            .request_fields = request_fields,
            .effort_fields = level,
        }),
        .@"openai-responses" => responses.build_request(alloc, request, .{
            .tool_choice_mode = definition.tool_choice_mode,
            .provider = &identity,
            .request_fields = request_fields,
            .effort_fields = level,
            .include_reasoning = declares_efforts(metadata),
        }),
        .@"anthropic-messages" => anthropic_messages.build_request(alloc, request, .{
            .tool_choice_mode = definition.tool_choice_mode,
            .provider = &identity,
            .request_fields = request_fields,
            .effort_fields = level,
            // Anthropic-compatible servers need not implement automatic caching.
            .automatic_cache = std.ascii.eqlIgnoreCase(definition.base_url, "https://api.anthropic.com/v1"),
        }),
        // Only an Antigravity account speaks it, and it returned above.
        .@"gemini-code-assist" => error.InvalidConfiguredProvider,
    };
}

/// How a connection's protocol reads a successful streamed reply.
fn consumer(protocol: definitions.Protocol) transport.ConsumeFn {
    return switch (protocol) {
        .@"openai-chat-completions" => consume,
        .@"openai-responses" => responses.consume,
        .@"anthropic-messages" => consume_messages,
        .@"gemini-code-assist" => consume_gemini,
    };
}

/// Which replay parts a connection's protocol keeps for a later request.
fn replay_projection(protocol: definitions.Protocol) *const fn (Allocator, ?types.ProviderReplay, []const types.ToolCall, bool, bool) anyerror!?types.ProviderReplay {
    return switch (protocol) {
        .@"openai-chat-completions" => project_replay,
        .@"openai-responses" => responses_protocol.selectReplayParts,
        .@"anthropic-messages" => anthropic_messages.project_replay,
        .@"gemini-code-assist" => gemini.project_replay,
    };
}

/// Whether the model's settings, its own or `model_defaults`, declare at
/// least one effort level: the settings' word that the model reasons.
fn declares_efforts(metadata: ?definitions.ModelMetadata) bool {
    const known = metadata orelse return false;
    const levels = known.reasoning_efforts orelse return false;
    return levels.len != 0;
}

/// The request fields of the level `effort` names, when the model declares it.
fn effort_fields(metadata: ?definitions.ModelMetadata, effort: ?types.ReasoningEffort) ?request_fragment.Fragment {
    const known = metadata orelse return null;
    const chosen = effort orelse return null;
    const level = known.effort(chosen.label()) orelse return null;
    return level.fields;
}

pub fn project_replay(alloc: Allocator, replay: ?types.ProviderReplay, calls: []const types.ToolCall, text: bool, reasoning: bool) !?types.ProviderReplay {
    const selected = try codec.project_replay(alloc, replay, calls, text, reasoning);
    if (replay != null and selected == null) debug_trace.logf("gateway", "provider_replay_omitted reason={s}", .{if (reasoning) "associated_calls_removed" else "reasoning_removed"});
    return selected;
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: streams.ModelRequest) !streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    _ = try transport.tokenOf(definition_at(raw), request);
    const payload = request.prepared_request_body orelse try build(raw, alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    const definition = definition_at(raw);
    return transport.send(alloc, definition, request, payload, consumer(definition.protocol));
}

/// Parses a successful streamed Chat Completions reply from `reader`,
/// telling `progress` about each event when it is set.
pub fn consume(alloc: Allocator, reader: *std.Io.Reader, request: streams.ModelRequest, progress: ?sse.Progress) !streams.Result {
    var limits: codec.Limits = .{};
    if (request.content_capture_limit) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    return codec.consume_stream(alloc, reader, request.data(), limits, request.events, request.cancel_flag, progress);
}

/// The same for an Anthropic Messages reply.
fn consume_messages(alloc: Allocator, reader: *std.Io.Reader, request: streams.ModelRequest, progress: ?sse.Progress) !streams.Result {
    var limits: anthropic_messages.Limits = .{};
    if (request.content_capture_limit) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    return anthropic_messages.consume_stream(alloc, reader, request.data(), limits, request.events, request.cancel_flag, progress);
}

/// The same for a Cloud Code reply.
fn consume_gemini(alloc: Allocator, reader: *std.Io.Reader, request: streams.ModelRequest, progress: ?sse.Progress) !streams.Result {
    var limits: gemini.Limits = .{};
    if (request.content_capture_limit) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    return gemini.consume_stream(alloc, reader, request.data(), limits, request.events, request.cancel_flag, progress);
}

/// The returned entry borrows its strings and lists no effort levels;
/// fetch_catalog replaces the strings with owned copies and adds the levels.
fn metadata_entry(metadata: definitions.ModelMetadata) catalog.ModelCatalogEntry {
    const vision = metadata.supports_vision orelse false;
    return .{
        .id = @constCast(metadata.id),
        .model_type = @constCast("language"),
        .has_reasoning = if (metadata.reasoning_efforts) |levels| levels.len > 0 else false,
        .has_tool_use = metadata.supports_tool_use orelse false,
        // Chat completions sends images as inline base64 content parts, so
        // vision support implies file input through the same path.
        .has_vision = vision,
        .has_file_input = vision,
        .context_window = metadata.context_window orelse 0,
        .max_tokens = metadata.max_output_tokens orelse 0,
        .default_effort = default_effort_of(metadata),
    };
}

/// The levels a model's settings declare, in their order.
fn effort_options(metadata: definitions.ModelMetadata) model_capabilities.ReasoningEffortOptions {
    var options: model_capabilities.ReasoningEffortOptions = .{};
    for (metadata.reasoning_efforts orelse return options) |level| {
        // The settings parser already holds names to this rule and count.
        options.values[options.len] = types.ReasoningEffort.parse(level.name) orelse continue;
        options.len += 1;
    }
    return options;
}

fn lookup_capabilities(raw: ?*anyopaque, model: []const u8) model_capabilities.Capabilities {
    const metadata = definition_at(raw).metadata_for(model) orelse return .{};
    return capabilities_of(metadata);
}

/// What `metadata` says the model can do, its default level included.
pub fn capabilities_of(metadata: definitions.ModelMetadata) model_capabilities.Capabilities {
    return model_capabilities.mergeCapabilities(.{}, gateway_metadata_of(metadata));
}

/// What `metadata` says, as a catalog would say it, with its levels.
pub fn gateway_metadata_of(metadata: definitions.ModelMetadata) model_capabilities.GatewayMetadata {
    var listed = model_catalog_metadata.fromCatalogEntry(metadata_entry(metadata));
    listed.reasoning_efforts = effort_options(metadata);
    return listed;
}

/// The model's default level, when its settings name one.
pub fn default_effort_of(metadata: definitions.ModelMetadata) ?types.ReasoningEffort {
    return types.ReasoningEffort.parse(metadata.default_effort orelse return null);
}

fn fetch_catalog(raw: ?*anyopaque, alloc: Allocator, input: catalog.FetchInput) Allocator.Error!catalog.ProviderResult {
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    const definition = definition_at(raw);
    var loaded = try load_models(definition, alloc, input.cancel_flag);
    if (definition.auth.plan() != null and loaded.failure == .credential) {
        catalog.freeModelCatalog(alloc, &loaded.entries);
        return .{ .failure = .{ .category = .authentication } };
    }
    if (loaded.failure == .cancelled) {
        catalog.freeModelCatalog(alloc, &loaded.entries);
        return .{ .failure = .{ .category = .cancellation } };
    }
    return .{ .catalog = loaded.entries };
}

const LoadedModels = struct {
    /// Owned entries: the declared models in the settings' order, then
    /// the ones only the server lists, in its order.
    entries: std.ArrayList(catalog.ModelCatalogEntry),
    /// Why the server's list is missing, when spark asked for it.
    failure: ?transport.ModelsFailure = null,
};

/// The declared models, with the server's after them when the settings turn
/// `fetch_models` on. A model only the server lists takes `model_defaults`.
/// A failed request leaves the declared models
/// (`tests/tla/configured_provider/ConfiguredCatalog.tla` FallbackIsDeclared).
fn load_models(definition: *const definitions.Definition, alloc: Allocator, cancel_flag: ?*std.atomic.Value(bool)) Allocator.Error!LoadedModels {
    var entries: std.ArrayList(catalog.ModelCatalogEntry) = .empty;
    errdefer catalog.freeModelCatalog(alloc, &entries);
    if (definition.auth.plan() != null) {
        var fresh = plan_requests.liveCatalog(alloc, definition, cancel_flag) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.Cancelled) return .{ .entries = entries, .failure = .cancelled };
            debug_trace.logf("gateway", "event=plan_models_unavailable connection={s} err={s}", .{ definition.id, @errorName(err) });
            for (definition.model_metadata) |declared| try append_entry(alloc, &entries, definition.with_overrides(declared));
            return .{ .entries = entries, .failure = if (plan_requests.signInRequired(err)) .credential else .transport };
        };
        defer fresh.deinit(alloc);
        for (fresh.definitions[0].model_metadata) |served| try append_entry(alloc, &entries, definition.with_overrides(served));
        return .{ .entries = entries };
    }
    for (definition.model_metadata) |declared| {
        try append_entry(alloc, &entries, definition.metadata_for(declared.id).?);
    }
    if (!definition.fetch_models) return .{ .entries = entries };
    var served = try transport.fetchModelIds(alloc, definition, cancel_flag);
    switch (served) {
        .failure => |failure| {
            debug_trace.logf("gateway", "event=configured_models_unavailable connection={s} reason={t}", .{ definition.id, failure });
            return .{ .entries = entries, .failure = failure };
        },
        .ids => |*ids| {
            defer transport.freeIds(alloc, ids);
            for (ids.items) |id| {
                if (definition.model(id) != null) continue;
                try append_entry(alloc, &entries, definition.metadata_for(id) orelse .{ .id = id });
            }
        },
    }
    return .{ .entries = entries };
}

/// Adds `metadata` to `entries` as an entry that owns its strings and levels.
fn append_entry(alloc: Allocator, entries: *std.ArrayList(catalog.ModelCatalogEntry), metadata: definitions.ModelMetadata) Allocator.Error!void {
    var entry = metadata_entry(metadata);
    entry.id = try alloc.dupe(u8, entry.id);
    errdefer alloc.free(entry.id);
    entry.model_type = try alloc.dupe(u8, entry.model_type);
    errdefer alloc.free(entry.model_type);
    entry.name = if (metadata.display_name) |name| try alloc.dupe(u8, name) else null;
    errdefer if (entry.name) |name| alloc.free(name);
    errdefer entry.reasoning_efforts.deinit(alloc);
    try entry.reasoning_efforts.appendSlice(alloc, effort_options(metadata).slice());
    try entries.append(alloc, entry);
}

fn fetch_cli_catalog(raw: ?*anyopaque, alloc: Allocator, input: gateway_provider.CliModelCatalogInput) gateway_provider.CliModelCatalogResult {
    const provenance = catalog.Provenance{ .access = catalog.AccessMetadata.init(input.access) };
    const exhausted: gateway_provider.CliModelCatalogResult = .{ .failure = .{ .access = provenance.access, .failure = .{ .category = .resource_exhausted } } };
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .access = provenance.access, .failure = .{ .category = .cancellation } } };
    const definition = definition_at(raw);
    var loaded = load_models(definition, alloc, input.cancel_flag) catch return exhausted;
    defer catalog.freeModelCatalog(alloc, &loaded.entries);
    if (loaded.failure == .cancelled) return .{ .failure = .{ .access = provenance.access, .failure = .{ .category = .cancellation } } };
    if (definition.auth.plan() != null and loaded.failure == .credential) return .{ .failure = .{ .access = provenance.access, .failure = .{ .category = .authentication } } };
    var ids = catalog.projectModelIds(alloc, loaded.entries.items) catch return exhausted;
    const notice = if (loaded.failure) |failure|
        alloc.print("could not get the model list of {s}: {s}; showing the models in settings", .{ definition.id, failure.text() }) catch {
            for (ids.items) |id| alloc.free(id);
            ids.deinit(alloc);
            return exhausted;
        }
    else
        null;
    return .{ .loaded = .{ .ids = ids, .provenance = provenance, .notice = notice } };
}
