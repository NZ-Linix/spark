const std = @import("std");
const types = @import("../shared/types.zig");
const model_provider = @import("model_provider.zig");
const image_route = @import("../images/image_route.zig");

/// The provider syntax for the cache markers on messages flagged with
/// `ChatMessage.cache_breakpoint`.
pub const CacheMarkers = enum { none, anthropic, openai, bedrock };

pub const ResolvedProviderOptions = struct {
    reasoning: ?types.ReasoningEffort = null,
    fast: bool = false,
    ultrafast: bool = false,
    parallel_tool_calls: ?bool = null,
    prompt_caching: bool = false,
    /// Marker syntax for flagged messages; written only with
    /// `prompt_caching`. `none` writes no markers.
    cache_markers: CacheMarkers = .none,
    /// Asks OpenAI GPT-5.6 and later to write no prompt-cache entries
    /// (explicit cache mode with no breakpoints), for a request whose prefix
    /// no later request shares. Such a model otherwise writes the whole
    /// prompt at the cache-write price on every call.
    skip_cache_writes: bool = false,
    /// The model takes one system message, at the start of the conversation,
    /// so the Gateway request joins the leading system messages into one.
    single_system_message: bool = false,
};

pub const ReasoningEffortOptions = struct {
    values: [types.ReasoningEffort.max_options]types.ReasoningEffort = undefined,
    len: usize = 0,

    pub fn fromSlice(source: []const types.ReasoningEffort) ReasoningEffortOptions {
        var result: ReasoningEffortOptions = .{};
        result.len = @min(source.len, result.values.len);
        for (source[0..result.len], 0..) |value, index| result.values[index] = value;
        return result;
    }

    pub fn slice(self: *const ReasoningEffortOptions) []const types.ReasoningEffort {
        return self.values[0..self.len];
    }
};

pub const ImageInputSupport = image_route.Support;

pub const GatewayMetadata = struct {
    supports_reasoning: bool = false,
    reasoning_efforts: ReasoningEffortOptions = .{},
    supports_fast_mode: bool = false,
    supports_ultrafast_mode: bool = false,
    supports_tool_use: bool = false,
    supports_vision: bool = false,
    supports_file_input: bool = false,
    supports_web_search: bool = false,
    supports_explicit_caching: bool = false,
    supports_implicit_caching: bool = false,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
};

pub const Capabilities = struct {
    supports_reasoning: bool = false,
    reasoning_efforts: ReasoningEffortOptions = .{},
    supports_fast_mode: bool = false,
    supports_ultrafast_mode: bool = false,
    intrinsic_fast: bool = false,
    supports_tool_use: bool = false,
    supports_vision: bool = false,
    supports_file_input: bool = false,
    image_input_support: ImageInputSupport = .unknown,
    supports_web_search: bool = false,
    supports_explicit_caching: bool = false,
    supports_implicit_caching: bool = false,
    parallel_tool_calls: ?bool = null,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
};

/// Compares two capabilities in a test. `reasoning_efforts.values` is
/// undefined past `len`, and `expectEqualDeep` on whole capabilities would
/// read it, so both copies get `.auto` there first.
pub fn expectCapabilitiesEqualForTest(expected: Capabilities, actual: Capabilities) !void {
    var defined = [2]Capabilities{ expected, actual };
    for (&defined) |*capabilities| {
        const efforts = &capabilities.reasoning_efforts;
        @memset(efforts.values[efforts.len..], .auto);
    }
    try std.testing.expectEqualDeep(defined[0], defined[1]);
}

pub const ResolveError = error{Cancelled};

pub const Resolver = struct {
    ctx: *anyopaque,
    resolve_fn: *const fn (
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        model: []const u8,
    ) ResolveError!Capabilities,

    pub fn resolve(self: Resolver, arena: std.mem.Allocator, model: []const u8) ResolveError!Capabilities {
        return self.resolve_fn(self.ctx, arena, model);
    }
};

pub fn mergeCapabilities(capabilities_value: Capabilities, gateway_metadata: ?GatewayMetadata) Capabilities {
    var capabilities = capabilities_value;
    if (gateway_metadata) |metadata| {
        capabilities.supports_reasoning = metadata.supports_reasoning or metadata.reasoning_efforts.len > 0;
        capabilities.reasoning_efforts = metadata.reasoning_efforts;
        capabilities.supports_fast_mode = metadata.supports_fast_mode;
        capabilities.supports_ultrafast_mode = metadata.supports_ultrafast_mode;
        capabilities.supports_tool_use = metadata.supports_tool_use;
        capabilities.supports_vision = metadata.supports_vision;
        capabilities.supports_file_input = metadata.supports_file_input;
        capabilities.image_input_support = image_route.supportFromCatalog(.{ .listed = .{
            .vision = metadata.supports_vision,
            .file_input = metadata.supports_file_input,
        } });
        capabilities.supports_web_search = metadata.supports_web_search;
        capabilities.supports_explicit_caching = metadata.supports_explicit_caching;
        capabilities.supports_implicit_caching = metadata.supports_implicit_caching;
        if (metadata.context_window) |window| capabilities.context_window = window;
        if (metadata.max_output_tokens) |tokens| capabilities.max_output_tokens = tokens;
    }
    return capabilities;
}

pub fn resolveCapabilities(model: []const u8, gateway_metadata: ?GatewayMetadata) Capabilities {
    return mergeCapabilities(capabilitiesForModel(model), gateway_metadata);
}

pub fn capabilitiesForModel(model: []const u8) Capabilities {
    return .{ .intrinsic_fast = std.mem.endsWith(u8, model, "-fast") };
}

pub fn resolveForApp(comptime App: type, app: *App, model: []const u8) Capabilities {
    const generic = capabilitiesForModel(model);
    var capabilities = if (comptime @hasDecl(App, "resolvedModelCapabilities"))
        app.resolvedModelCapabilities(model)
    else
        generic;
    capabilities.intrinsic_fast = capabilities.intrinsic_fast or generic.intrinsic_fast;
    return capabilities;
}

// A catalog output limit that fills the whole context window cannot bound a real request, and
// omitting the limit lets some providers stop replies at a few thousand tokens.
const full_window_output_tokens: u32 = 32_768;
const full_window_output_divisor: u32 = 8;

/// The output limit for the one retry of a reply the provider cut short before
/// any text, when the first request set no limit and the provider's default ran
/// out. A known context window bounds it as it bounds a full-window limit; null
/// when that leaves no room.
pub fn emptyLengthRetryOutputTokens(capabilities: Capabilities) ?u32 {
    const window = capabilities.context_window orelse return full_window_output_tokens;
    const bounded = @min(full_window_output_tokens, window / full_window_output_divisor);
    return if (bounded == 0) null else bounded;
}

test "empty length retry limit stays inside a known context window" {
    try std.testing.expectEqual(@as(?u32, 32_768), emptyLengthRetryOutputTokens(.{}));
    try std.testing.expectEqual(@as(?u32, 32_768), emptyLengthRetryOutputTokens(.{ .context_window = 1_000_000 }));
    try std.testing.expectEqual(@as(?u32, 8_192), emptyLengthRetryOutputTokens(.{ .context_window = 65_536 }));
    try std.testing.expectEqual(@as(?u32, null), emptyLengthRetryOutputTokens(.{ .context_window = 7 }));
}

/// The effort for the one resend of a reply that spent its whole output limit
/// with nothing usable: `low` when the model offers it below the effort the
/// request used, so the resend reasons less; null resends at the same effort.
/// An effort the model does not list was never sent, so that request used the
/// model's default.
pub fn lengthResendEffort(capabilities: Capabilities, current: types.ReasoningEffort) ?types.ReasoningEffort {
    const low = types.ReasoningEffort.literal("low");
    const low_index = reasoningEffortIndex(capabilities, low);
    if (low_index == 0) return null;
    const current_index = reasoningEffortIndex(capabilities, current);
    return if (current_index == 0 or low_index < current_index) low else null;
}

/// Output tokens to request and reserve for one model call, or null to leave the limit unset.
pub fn requestOutputTokens(capabilities: Capabilities) ?u32 {
    const advertised = capabilities.max_output_tokens orelse return null;
    const window = capabilities.context_window orelse return advertised;
    if (advertised < window) return advertised;
    return @min(full_window_output_tokens, window / full_window_output_divisor);
}

pub fn reasoningEffortSupported(capabilities: Capabilities, effort: types.ReasoningEffort) bool {
    if (effort.isDefault()) return true;
    for (capabilities.reasoning_efforts.slice()) |option| {
        if (option.eql(effort)) return true;
    }
    return false;
}

pub fn reasoningEffortIndex(capabilities: Capabilities, effort: types.ReasoningEffort) usize {
    if (effort.isDefault()) return 0;
    for (capabilities.reasoning_efforts.slice(), 0..) |option, i| {
        if (option.eql(effort)) return i + 1;
    }
    return 0;
}

pub fn reasoningEffortAtIndex(capabilities: Capabilities, index: usize) types.ReasoningEffort {
    if (index == 0 or capabilities.reasoning_efforts.len == 0) return .auto;
    return capabilities.reasoning_efforts.values[(index - 1) % capabilities.reasoning_efforts.len];
}

pub fn reasoningEffortLabelAtIndex(capabilities: *const Capabilities, index: usize) []const u8 {
    if (index == 0 or capabilities.reasoning_efforts.len == 0) return "default";
    return capabilities.reasoning_efforts.values[(index - 1) % capabilities.reasoning_efforts.len].displayLabel();
}

pub fn reasoningEffortOptionCount(capabilities: Capabilities) usize {
    return if (capabilities.reasoning_efforts.len == 0) 0 else capabilities.reasoning_efforts.len + 1;
}

/// The effort after `current` in the cycle `default`, then each level the
/// model declares in its order, then `default` again. The Gateway catalog
/// lists levels lowest first; a custom connection keeps the order of its
/// settings. Null when the model declares no levels.
///
/// A level the model does not declare, such as one saved for another model,
/// goes back to `default`. The `/settings` cycle reads such a level as
/// `default` and steps to the first level instead.
pub fn nextReasoningEffort(capabilities: Capabilities, current: types.ReasoningEffort) ?types.ReasoningEffort {
    const count = reasoningEffortOptionCount(capabilities);
    if (count == 0) return null;
    if (!reasoningEffortSupported(capabilities, current)) return .auto;
    return reasoningEffortAtIndex(capabilities, (reasoningEffortIndex(capabilities, current) + 1) % count);
}

pub fn resolveProviderOptionsForCapabilities(
    capabilities: Capabilities,
    effort: types.ReasoningEffort,
    fast_mode: bool,
) ResolvedProviderOptions {
    var resolved: ResolvedProviderOptions = .{
        .parallel_tool_calls = capabilities.parallel_tool_calls,
    };
    if (!effort.isDefault() and reasoningEffortSupported(capabilities, effort)) {
        resolved.reasoning = effort;
    }
    resolved.fast = fast_mode and capabilities.supports_fast_mode;
    return resolved;
}

/// Ultrafast is an explicit, catalog-verified OpenAI Gateway opt-in. Unlike Fast,
/// unsupported or unknown capabilities must not silently downgrade before sending.
pub fn resolveUltrafastProviderOptions(
    capabilities: Capabilities,
    provider: model_provider.ProviderId,
    model: []const u8,
    effort: types.ReasoningEffort,
    fast_mode: bool,
    ultrafast_mode: bool,
) error{UltrafastUnavailable}!ResolvedProviderOptions {
    var options = resolveProviderOptionsForCapabilities(capabilities, effort, fast_mode);
    if (!ultrafast_mode) return options;
    _ = provider;
    _ = model;
    if (!capabilities.supports_ultrafast_mode) {
        return error.UltrafastUnavailable;
    }
    options.fast = false;
    options.ultrafast = true;
    return options;
}
