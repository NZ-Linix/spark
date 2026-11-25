const std = @import("std");
const credentials = @import("../auth/credentials.zig");
const model_provider = @import("../config/model_provider.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const collections = @import("../shared/collections.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const View = enum {
    full,
    picker,
};

pub const FetchInput = struct {
    access: credentials.CatalogAccess = .public_only,
    endpoint: []const u8,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    view: View = .full,
    /// A provider with `reports_connection` sets this once its request has a
    /// connection: the DNS lookup, connect, and any TLS handshake are done.
    connected: ?*std.atomic.Value(bool) = null,
};

pub const FailureCategory = enum {
    authentication,
    rate_limited,
    gateway_unavailable,
    cancellation,
    transport,
    malformed_response,
    http_status,
    resource_exhausted,
    runtime,
};

pub const Failure = struct {
    category: FailureCategory,
    http_status: ?std.http.Status = null,
    retryable: bool = false,

    pub fn asError(self: Failure) error{
        AuthenticationRejected,
        Cancelled,
        GatewayUnavailable,
        MalformedResponse,
        OutOfMemory,
        RateLimited,
        TransportFailure,
        Unavailable,
    } {
        return switch (self.category) {
            .authentication => error.AuthenticationRejected,
            .rate_limited => error.RateLimited,
            .gateway_unavailable => error.GatewayUnavailable,
            .cancellation => error.Cancelled,
            .transport => error.TransportFailure,
            .malformed_response => error.MalformedResponse,
            .resource_exhausted => error.OutOfMemory,
            .http_status, .runtime => error.Unavailable,
        };
    }
};

/// Who serves a model catalog, as a message about a connection spark could
/// not make names it.
pub fn serviceName(_: model_provider.ProviderId) []const u8 {
    return "the model provider";
}

/// Milliseconds on the clock that times catalog refreshes. Natively it keeps
/// counting while the machine sleeps, so a catalog goes stale overnight, and
/// ignores wall-clock changes. The libfx wasm host backs it with wall time, so
/// callers treat a reading earlier than a stored one as due.
pub fn clockMs() i64 {
    const timestamp = std.Io.Clock.boot.now(io_mod.getIo());
    return @intCast(@divFloor(timestamp.nanoseconds, std.time.ns_per_ms));
}

pub fn failureForHttpStatus(status: std.http.Status) Failure {
    if (status == .unauthorized or status == .forbidden) {
        return .{ .category = .authentication, .http_status = status };
    }
    if (status == .too_many_requests) {
        return .{ .category = .rate_limited, .http_status = status, .retryable = true };
    }

    const code = @backingInt(status);
    if (code >= 500 and code < 600) {
        return .{
            .category = .gateway_unavailable,
            .http_status = status,
            .retryable = types.isRetryableServerStatus(code),
        };
    }
    return .{ .category = .http_status, .http_status = status };
}

pub const AccessMetadata = struct {
    source: ?credentials.Source,

    pub fn init(access: credentials.CatalogAccess) AccessMetadata {
        return .{ .source = access.credentialSource() };
    }
};

pub const Provenance = struct {
    access: AccessMetadata,
};

pub const FailedOutcome = struct {
    access: AccessMetadata,
    failure: Failure,
};

pub const ProviderResult = union(enum) {
    catalog: std.ArrayList(ModelCatalogEntry),
    failure: Failure,
};

pub const FetchFn = *const fn (
    ?*anyopaque,
    Allocator,
    FetchInput,
) Allocator.Error!ProviderResult;

pub const Provider = struct {
    /// When set, context must outlive every in-flight fetch and capability lookup.
    context: ?*anyopaque = null,
    fetch_fn: FetchFn,
    /// Reads already-owned metadata without allocation, I/O, or waiting.
    lookup_capabilities_fn: ?*const fn (?*anyopaque, []const u8) model_capabilities.Capabilities = null,
    provider_id: model_provider.ProviderId = .none,
    refresh_interval_ms: ?i64 = null,
    /// The fetch sets `FetchInput.connected` once its request has a connection.
    reports_connection: bool = false,

    /// Returns owned catalog entries; the caller frees them with `freeModelCatalog`.
    pub fn fetch(self: Provider, alloc: Allocator, input: FetchInput) Allocator.Error!ProviderResult {
        return self.fetch_fn(self.context, alloc, input);
    }

    /// Null means lookup is unsupported, not that the model is unknown.
    pub fn lookupCapabilities(self: Provider, model: []const u8) ?model_capabilities.Capabilities {
        const lookup = self.lookup_capabilities_fn orelse return null;
        return lookup(self.context, model);
    }
};

fn cloneModelCatalogEntry(alloc: std.mem.Allocator, entry: ModelCatalogEntry) !ModelCatalogEntry {
    const id = try alloc.dupe(u8, entry.id);
    errdefer alloc.free(id);
    const name = if (entry.name) |value| try alloc.dupe(u8, value) else null;
    errdefer if (name) |value| alloc.free(value);
    const model_type = try alloc.dupe(u8, entry.model_type);
    errdefer alloc.free(model_type);
    var reasoning_efforts: std.ArrayList(types.ReasoningEffort) = .empty;
    errdefer reasoning_efforts.deinit(alloc);
    try reasoning_efforts.appendSlice(alloc, entry.reasoning_efforts.items);

    var cloned = ModelCatalogEntry{
        .id = id,
        .name = name,
        .model_type = model_type,
        .released = entry.released,
        .has_tool_use = entry.has_tool_use,
        .has_reasoning = entry.has_reasoning,
        .reasoning_efforts = reasoning_efforts,
        .supports_fast_mode = entry.supports_fast_mode,
        .supports_ultrafast_mode = entry.supports_ultrafast_mode,
        .has_vision = entry.has_vision,
        .has_file_input = entry.has_file_input,
        .has_web_search = entry.has_web_search,
        .has_explicit_caching = entry.has_explicit_caching,
        .has_implicit_caching = entry.has_implicit_caching,
        .context_window = entry.context_window,
        .max_tokens = entry.max_tokens,
        .web_search_price = null,
        .default_effort = entry.default_effort,
    };
    errdefer if (cloned.web_search_price) |price| alloc.free(price);
    if (entry.web_search_price) |price| {
        cloned.web_search_price = try alloc.dupe(u8, price);
    }
    if (entry.fast_variant_of) |base| {
        cloned.fast_variant_of = try alloc.dupe(u8, base);
    }
    return cloned;
}

test "catalog capability lookup distinguishes unsupported and unknown without fetching" {
    const Fixture = struct {
        fetches: usize = 0,
        limit: u32 = 512,

        fn fetch(raw: ?*anyopaque, _: Allocator, _: FetchInput) Allocator.Error!ProviderResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.fetches += 1;
            return .{ .failure = .{ .category = .runtime } };
        }

        fn lookup(raw: ?*anyopaque, model: []const u8) model_capabilities.Capabilities {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return if (std.mem.eql(u8, model, "known")) .{ .max_output_tokens = self.limit } else .{};
        }
    };
    var fixture: Fixture = .{};
    var provider = Provider{ .context = &fixture, .fetch_fn = Fixture.fetch };
    try std.testing.expect(provider.lookupCapabilities("known") == null);
    provider.lookup_capabilities_fn = Fixture.lookup;
    try std.testing.expectEqual(@as(?u32, 512), provider.lookupCapabilities("known").?.max_output_tokens);
    try model_capabilities.expectCapabilitiesEqualForTest(.{}, provider.lookupCapabilities("unknown").?);
    try std.testing.expectEqual(@as(usize, 0), fixture.fetches);
}

pub const FetchResult = union(enum) {
    loaded: struct {
        /// Owned catalog entries; the caller frees them with `freeModelCatalog`.
        catalog: std.ArrayList(ModelCatalogEntry),
        provenance: Provenance,
    },
    failed: FailedOutcome,
};

/// Fetches the catalog once and traces how it went.
pub fn fetchTraced(
    provider: Provider,
    alloc: Allocator,
    input: FetchInput,
) FetchResult {
    const access = AccessMetadata.init(input.access);
    const result: FetchResult = if (provider.fetch(alloc, input)) |fetched| switch (fetched) {
        .catalog => |catalog| .{ .loaded = .{ .catalog = catalog, .provenance = .{ .access = access } } },
        .failure => |failure| .{ .failed = .{ .access = access, .failure = failure } },
    } else |_| .{ .failed = .{ .access = access, .failure = .{ .category = .resource_exhausted } } };
    traceCatalogLoad(access, &result);
    return result;
}

fn traceCatalogLoad(access: AccessMetadata, result: *const FetchResult) void {
    const credential_source = if (access.source) |source| @tagName(source) else "none";
    const failure: ?Failure = switch (result.*) {
        .loaded => null,
        .failed => |failed| failed.failure,
    };
    const outcome: []const u8 = if (failure == null) "loaded" else "failed";
    const failure_category = if (failure) |detail| @tagName(detail.category) else "none";
    const http_status: u16 = if (failure) |detail| if (detail.http_status) |status| @backingInt(status) else 0 else 0;
    debug_trace.eventf(
        "catalog",
        "model_catalog_load",
        .{},
        "credential_source={s} outcome={s} failure_category={s} http_status={d}",
        .{ credential_source, outcome, failure_category, http_status },
    );
}

pub const ModelCatalogEntry = struct {
    id: []u8,
    /// The catalog's display name, trimmed; null when the catalog has none.
    name: ?[]u8 = null,
    model_type: []u8,
    released: i64 = 0,
    has_tool_use: bool = false,
    has_reasoning: bool = false,
    reasoning_efforts: std.ArrayList(types.ReasoningEffort) = .empty,
    supports_fast_mode: bool = false,
    supports_ultrafast_mode: bool = false,
    has_vision: bool = false,
    has_file_input: bool = false,
    has_web_search: bool = false,
    has_explicit_caching: bool = false,
    has_implicit_caching: bool = false,
    context_window: u32 = 0,
    max_tokens: u32 = 0,
    web_search_price: ?[]u8 = null,
    /// The id of the model whose Fast mode runs this one; null when the
    /// catalog names none.
    fast_variant_of: ?[]u8 = null,
    /// The level a request uses while the session's effort is `default`,
    /// as a connection's settings choose it for the model.
    default_effort: ?types.ReasoningEffort = null,
};

pub fn freeModelCatalog(alloc: std.mem.Allocator, entries: *std.ArrayList(ModelCatalogEntry)) void {
    for (entries.items) |entry| freeModelCatalogEntry(alloc, entry);
    entries.deinit(alloc);
}

pub fn freeModelCatalogEntry(alloc: std.mem.Allocator, entry: ModelCatalogEntry) void {
    alloc.free(entry.id);
    if (entry.name) |name| alloc.free(name);
    alloc.free(entry.model_type);
    var reasoning_efforts = entry.reasoning_efforts;
    reasoning_efforts.deinit(alloc);
    if (entry.web_search_price) |price| alloc.free(price);
    if (entry.fast_variant_of) |base| alloc.free(base);
}

/// An owned copy of `entries`, which shares nothing with them. Free it with `freeModelCatalog`.
pub fn cloneModelCatalog(alloc: std.mem.Allocator, entries: []const ModelCatalogEntry) !std.ArrayList(ModelCatalogEntry) {
    var copy: std.ArrayList(ModelCatalogEntry) = .empty;
    errdefer freeModelCatalog(alloc, &copy);
    try copy.ensureTotalCapacity(alloc, entries.len);
    for (entries) |entry| try appendClonedModelCatalogEntry(alloc, &copy, entry);
    return copy;
}

/// Returns owned model id strings in catalog order; caller frees with `collections.freeStringList`.
pub fn projectModelIds(alloc: std.mem.Allocator, candidates: []const ModelCatalogEntry) !std.ArrayList([]u8) {
    var ids: std.ArrayList([]u8) = .empty;
    errdefer collections.freeStringList(alloc, &ids);
    try ids.ensureTotalCapacity(alloc, candidates.len);
    for (candidates) |candidate| {
        try ids.append(alloc, try alloc.dupe(u8, candidate.id));
    }
    return ids;
}

fn appendClonedModelCatalogEntry(alloc: std.mem.Allocator, entries: *std.ArrayList(ModelCatalogEntry), entry: ModelCatalogEntry) !void {
    const cloned = try cloneModelCatalogEntry(alloc, entry);
    entries.append(alloc, cloned) catch |err| {
        freeModelCatalogEntry(alloc, cloned);
        return err;
    };
}

/// Whether the Models menu leaves `entry` out: the catalog says Fast mode on
/// another model runs it, and that model is in `catalog` and offers Fast mode.
/// The entry stays in the catalog, so a session that names it still runs.
pub fn foldsIntoFastMode(entry: ModelCatalogEntry, catalog: []const ModelCatalogEntry) bool {
    const base_id = entry.fast_variant_of orelse return false;
    for (catalog) |candidate| {
        if (std.mem.eql(u8, candidate.id, base_id)) return candidate.supports_fast_mode;
    }
    return false;
}

pub fn compareModelCatalogEntries(_: void, a: ModelCatalogEntry, b: ModelCatalogEntry) bool {
    if (a.has_tool_use != b.has_tool_use) return a.has_tool_use;

    const a_tier = modelTierRank(a.id);
    const b_tier = modelTierRank(b.id);
    if (a_tier != b_tier) return a_tier < b_tier;

    const a_provider = modelProviderRank(a.id);
    const b_provider = modelProviderRank(b.id);
    if (a_provider != b_provider) return a_provider < b_provider;

    if (a.released != b.released) return a.released > b.released;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn modelProviderRank(id: []const u8) u8 {
    if (std.mem.startsWith(u8, id, "anthropic/")) return 0;
    if (std.mem.startsWith(u8, id, "openai/")) return 1;
    if (std.mem.startsWith(u8, id, "google/")) return 2;
    if (std.mem.startsWith(u8, id, "xai/")) return 3;
    if (std.mem.startsWith(u8, id, "deepseek/")) return 4;
    if (std.mem.startsWith(u8, id, "meta/")) return 5;
    if (std.mem.startsWith(u8, id, "mistral/")) return 6;
    if (std.mem.startsWith(u8, id, "alibaba/")) return 7;
    return 8;
}

fn modelTierRank(id: []const u8) u8 {
    if (text_utils.containsIgnoreCase(id, "preview") or text_utils.containsIgnoreCase(id, "beta")) return 4;
    if (text_utils.containsIgnoreCase(id, "haiku") or text_utils.containsIgnoreCase(id, "mini") or text_utils.containsIgnoreCase(id, "lite")) return 3;
    if (text_utils.containsIgnoreCase(id, "flash")) return 2;
    if (text_utils.containsIgnoreCase(id, "opus") or
        text_utils.containsIgnoreCase(id, "sonnet") or
        text_utils.hasMajorVersionAtLeast(id, "gpt-", 5) or
        text_utils.containsIgnoreCase(id, "o1") or
        text_utils.containsIgnoreCase(id, "o3") or
        text_utils.containsIgnoreCase(id, "o4") or
        text_utils.containsIgnoreCase(id, "pro") or
        text_utils.hasMajorVersionAtLeast(id, "grok-", 4))
    {
        return 0;
    }
    return 1;
}

const picker_provider_limit: usize = 2;
const extended_picker_provider_limit: usize = 3;

const FeaturedPickerFamily = struct {
    family: []const u8,
    count: usize,
};

// These are product preferences, but the model version in each slot always
// comes from the live Gateway catalog instead of a pinned model ID.
const featured_picker_families = [_]FeaturedPickerFamily{
    .{ .family = "anthropic/claude-fable", .count = 1 },
    .{ .family = "openai/gpt", .count = 1 },
    .{ .family = "xai/grok-build", .count = 1 },
    .{ .family = "anthropic/claude-opus", .count = 1 },
    .{ .family = "zai/glm", .count = 1 },
    .{ .family = "deepseek/deepseek", .count = 1 },
    .{ .family = "minimax/minimax", .count = 1 },
};

pub fn projectPickerModelCatalog(alloc: std.mem.Allocator, candidates: []const ModelCatalogEntry) !std.ArrayList(ModelCatalogEntry) {
    var selected: std.ArrayList(ModelCatalogEntry) = .empty;
    errdefer freeModelCatalog(alloc, &selected);
    try selected.ensureTotalCapacity(alloc, candidates.len);

    for (featured_picker_families) |featured| {
        var remaining = featured.count;
        while (remaining > 0) : (remaining -= 1) {
            const candidate = newestUnselectedPickerCandidate(candidates, featured.family, selected.items) orelse break;
            try appendClonedModelCatalogEntry(alloc, &selected, candidate.*);
        }
    }

    var providers: std.ArrayList([]const u8) = .empty;
    defer providers.deinit(alloc);
    for (candidates) |candidate| {
        if (!isPickerCandidate(candidate)) continue;
        const provider = modelPickerProvider(candidate.id);
        if (pickerIdsContain(providers.items, provider)) continue;
        try providers.append(alloc, provider);
    }
    sort_utils.sort([]const u8, providers.items, {}, lessThanStrings);

    // After the product highlights, scan providers alphabetically. Each
    // provider contributes its current models, rather than inheriting the
    // Gateway's global quality ranking.
    for (providers.items) |provider| {
        while (pickerProviderSelectionCount(selected.items, provider) < pickerProviderLimit(provider)) {
            const candidate = newestUnselectedPickerProviderCandidate(candidates, provider, selected.items) orelse break;
            try appendClonedModelCatalogEntry(alloc, &selected, candidate.*);
        }
    }

    // Highlights stay on top; the rest of the catalog follows so any model is selectable.
    for (candidates) |candidate| {
        if (pickerCatalogContains(selected.items, candidate.id)) continue;
        try appendClonedModelCatalogEntry(alloc, &selected, candidate);
    }

    return selected;
}

fn newestUnselectedPickerCandidate(candidates: []const ModelCatalogEntry, family: []const u8, selected: []const ModelCatalogEntry) ?*const ModelCatalogEntry {
    var newest: ?*const ModelCatalogEntry = null;
    for (candidates) |*candidate| {
        if (!isPickerCandidate(candidate.*)) continue;
        if (!std.mem.eql(u8, modelPickerFamily(candidate.id), family)) continue;
        if (pickerCatalogContains(selected, candidate.id)) continue;

        if (newest == null or featuredPickerModelIsNewer(family, candidate.*, newest.?.*)) newest = candidate;
    }
    return newest;
}

fn newestUnselectedPickerProviderCandidate(candidates: []const ModelCatalogEntry, provider: []const u8, selected: []const ModelCatalogEntry) ?*const ModelCatalogEntry {
    var newest: ?*const ModelCatalogEntry = null;
    for (candidates) |*candidate| {
        if (!isPickerCandidate(candidate.*)) continue;
        if (!std.mem.eql(u8, modelPickerProvider(candidate.id), provider)) continue;
        if (!isPickerProviderCandidate(provider, candidate.*, candidates)) continue;
        if (pickerCatalogContains(selected, candidate.id)) continue;

        if (newest == null or pickerModelIsNewer(candidate.*, newest.?.*)) newest = candidate;
    }
    return newest;
}

fn isPickerCandidate(candidate: ModelCatalogEntry) bool {
    if (text_utils.containsIgnoreCase(candidate.id, "claude-sonnet")) return false;
    // A model that Fast mode on another model runs never takes a highlight slot.
    if (candidate.fast_variant_of != null) return false;
    if (isGlmFastVariant(candidate.id)) return false;

    const excluded_variants = [_][]const u8{ "-mini", "-nano", "-oss", "-safeguard" };
    inline for (excluded_variants) |variant| {
        if (text_utils.containsIgnoreCase(candidate.id, variant)) return false;
    }
    return true;
}

fn isGlmFastVariant(id: []const u8) bool {
    return std.mem.startsWith(u8, id, "zai/glm-") and
        std.mem.endsWith(u8, id, "-fast");
}

fn isWithinPickerFamilyLimit(candidate: ModelCatalogEntry, candidates: []const ModelCatalogEntry) bool {
    if (!isPickerCandidate(candidate)) return false;

    const family = modelPickerFamily(candidate.id);
    var newer_count: usize = 0;
    for (candidates) |other| {
        if (!isPickerCandidate(other)) continue;
        if (!std.mem.eql(u8, modelPickerFamily(other.id), family)) continue;
        if (!pickerModelIsNewer(other, candidate)) continue;

        newer_count += 1;
        if (newer_count >= pickerFamilyLimit(family)) return false;
    }
    return true;
}

fn modelPickerFamily(id: []const u8) []const u8 {
    if (std.mem.startsWith(u8, id, "openai/gpt-") and text_utils.containsIgnoreCase(id, "-codex")) {
        return "openai/gpt-codex";
    }
    if (std.mem.startsWith(u8, id, "deepseek/deepseek-")) {
        return "deepseek/deepseek";
    }
    if (std.mem.startsWith(u8, id, "minimax/minimax-")) {
        return "minimax/minimax";
    }

    const slash = std.mem.findScalar(u8, id, '/') orelse return id;
    var index = slash + 1;
    while (index + 1 < id.len) : (index += 1) {
        if (id[index] == '-' and std.ascii.isDigit(id[index + 1])) return id[0..index];
    }
    return id;
}

fn modelPickerProvider(id: []const u8) []const u8 {
    const slash = std.mem.findScalar(u8, id, '/') orelse return id;
    return id[0..slash];
}

fn pickerProviderLimit(provider: []const u8) usize {
    if (std.mem.eql(u8, provider, "anthropic") or std.mem.eql(u8, provider, "openai")) {
        return extended_picker_provider_limit;
    }
    return picker_provider_limit;
}

fn pickerProviderSelectionCount(entries: []const ModelCatalogEntry, provider: []const u8) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (std.mem.eql(u8, modelPickerProvider(entry.id), provider)) count += 1;
    }
    return count;
}

fn isPickerProviderCandidate(provider: []const u8, candidate: ModelCatalogEntry, candidates: []const ModelCatalogEntry) bool {
    const family = modelPickerFamily(candidate.id);
    if (std.mem.eql(u8, provider, "anthropic")) {
        return std.mem.eql(u8, family, "anthropic/claude-opus") and
            isWithinPickerFamilyLimit(candidate, candidates);
    }
    if (std.mem.eql(u8, provider, "openai")) {
        const is_gpt = std.mem.eql(u8, family, "openai/gpt");
        const is_codex = std.mem.eql(u8, family, "openai/gpt-codex");
        return (is_gpt or is_codex) and isWithinPickerFamilyLimit(candidate, candidates);
    }
    return true;
}

fn pickerFamilyLimit(family: []const u8) usize {
    // Let the picker show two general models next to one coding-focused model.
    if (std.mem.eql(u8, family, "openai/gpt")) return 2;
    if (std.mem.eql(u8, family, "openai/gpt-codex")) return 1;
    return extended_picker_provider_limit;
}

fn pickerModelIsNewer(a: ModelCatalogEntry, b: ModelCatalogEntry) bool {
    if (a.released != b.released) return a.released > b.released;
    if (a.id.len != b.id.len) return a.id.len < b.id.len;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn featuredPickerModelIsNewer(family: []const u8, a: ModelCatalogEntry, b: ModelCatalogEntry) bool {
    if (a.released != b.released) return a.released > b.released;
    if (std.mem.eql(u8, family, "deepseek/deepseek")) {
        const a_quality = deepseekFeaturedQualityRank(a.id);
        const b_quality = deepseekFeaturedQualityRank(b.id);
        if (a_quality != b_quality) return a_quality < b_quality;
    }
    return pickerModelIsNewer(a, b);
}

fn deepseekFeaturedQualityRank(id: []const u8) u8 {
    if (std.mem.endsWith(u8, id, "-pro")) return 0;
    if (text_utils.containsIgnoreCase(id, "-thinking") or
        text_utils.containsIgnoreCase(id, "-reasoning")) return 1;
    if (text_utils.containsIgnoreCase(id, "-flash")) return 3;
    return 2;
}

fn lessThanStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn pickerIdsContain(ids: []const []const u8, needle: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, needle)) return true;
    }
    return false;
}

fn pickerCatalogContains(entries: []const ModelCatalogEntry, needle: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, needle)) return true;
    }
    return false;
}

const FallbackProbe = struct {
    failures: [2]?Failure,
    calls: usize = 0,
    anonymous_retry: bool = false,

    fn fetch(raw: ?*anyopaque, _: Allocator, input: FetchInput) Allocator.Error!ProviderResult {
        const self: *FallbackProbe = @ptrCast(@alignCast(raw.?));
        const index = self.calls;
        self.calls += 1;
        if (index == 1) {
            self.anonymous_retry = input.access.authorizationCredential() == null and
                input.access.teamContext() == null;
        }
        if (self.failures[index]) |failure| return .{ .failure = failure };
        return .{ .catalog = .empty };
    }

    fn provider(self: *FallbackProbe) Provider {
        return .{ .context = self, .fetch_fn = fetch };
    }
};

/// Rejects every token but `accepted` with `status`, and records each token.
const TokenProbe = struct {
    accepted: []const u8,
    status: std.http.Status = .unauthorized,
    tokens: [3][]const u8 = .{ "", "", "" },
    calls: usize = 0,

    fn fetch(raw: ?*anyopaque, _: Allocator, input: FetchInput) Allocator.Error!ProviderResult {
        const self: *TokenProbe = @ptrCast(@alignCast(raw.?));
        const token = input.access.authorizationCredential() orelse "";
        self.tokens[self.calls] = token;
        self.calls += 1;
        if (token.len == 0 or std.mem.eql(u8, token, self.accepted)) return .{ .catalog = .empty };
        return .{ .failure = failureForHttpStatus(self.status) };
    }

    fn provider(self: *TokenProbe) Provider {
        return .{ .context = self, .fetch_fn = fetch };
    }
};
