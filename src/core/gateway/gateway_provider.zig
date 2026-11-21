const std = @import("std");
const builtin = @import("builtin");
const credentials = @import("../auth/credentials.zig");
const secret = @import("../auth/secret.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const model_catalog = @import("model_catalog.zig");
const model_catalog_metadata = @import("model_catalog_metadata.zig");

const Allocator = std.mem.Allocator;

pub const ResolveChatUrlFn = *const fn (?*anyopaque, []const u8) []const u8;

pub const ChatUrlProvider = struct {
    /// When set, context must remain valid until every in-flight `resolve` returns.
    context: ?*anyopaque = null,
    resolve_fn: ResolveChatUrlFn,

    pub fn resolve(self: ChatUrlProvider, fallback: []const u8) []const u8 {
        return self.resolve_fn(self.context, fallback);
    }
};

pub const CliModelCatalogInput = struct {
    access: credentials.CatalogAccess = .public_only,
    endpoint: []const u8,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

pub const CliModelCatalogResult = union(enum) {
    loaded: struct {
        /// Owned model id strings; the caller frees them with `collections.freeStringList`.
        ids: std.ArrayList([]u8),
        /// Owned catalog entries behind `ids`, from a provider whose catalog carries model
        /// metadata; empty otherwise. The caller frees them with `model_catalog.freeModelCatalog`.
        entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty,
        provenance: model_catalog.Provenance,
        /// Owned text for one line on stderr, such as why part of the list is
        /// missing, or null. The caller frees it.
        notice: ?[]u8 = null,
    },
    failure: model_catalog.FailedOutcome,
};

pub const FetchCliModelCatalogFn = *const fn (
    ?*anyopaque,
    Allocator,
    CliModelCatalogInput,
) CliModelCatalogResult;

pub const CliModelCatalogProvider = struct {
    /// When set, context must remain valid until every in-flight `fetch` returns.
    context: ?*anyopaque = null,
    fetch_fn: FetchCliModelCatalogFn,

    pub fn fetch(
        self: CliModelCatalogProvider,
        alloc: Allocator,
        input: CliModelCatalogInput,
    ) CliModelCatalogResult {
        return self.fetch_fn(self.context, alloc, input);
    }
};

const CapabilityResolverState = enum {
    idle,
    ready,
    failed,
};

pub const CapabilityResolver = struct {
    catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty,
    state: CapabilityResolverState = .idle,
    last_attempt_ms: i64 = 0,
    requested_access: ?model_catalog.AccessMetadata = null,
    provider_id: ?model_provider.ProviderId = null,
    /// A load `resolveWithin` or `refreshWithin` started whose wait was
    /// cancelled, kept for the next call to wait on.
    pending_load: ?*CatalogLoad = null,
    /// Loads given up on before they connected. Each runs until its own
    /// deadline; a later load frees the ones that ended, and `deinit` waits
    /// for the rest.
    abandoned_loads: ?*CatalogLoad = null,
    /// Why the last refresh failed, until one loads.
    last_failure: ?model_catalog.FailureCategory = null,

    pub fn deinit(self: *CapabilityResolver, alloc: Allocator) void {
        if (self.pending_load) |load| load.discard(alloc);
        self.pending_load = null;
        while (self.abandoned_loads) |load| {
            self.abandoned_loads = load.next;
            load.discard(alloc);
        }
        model_catalog.freeModelCatalog(alloc, &self.catalog);
    }

    /// A copy of this resolver that a reader owns: it shares no memory with
    /// this one, so an adoption or refresh here leaves the copy as it was.
    /// A load in flight is not copied. The copy loads for itself if it is
    /// asked before anything loaded. Free it with `deinit`.
    pub fn snapshot(self: *const CapabilityResolver, alloc: Allocator) Allocator.Error!CapabilityResolver {
        return .{
            .catalog = try model_catalog.cloneModelCatalog(alloc, self.catalog.items),
            .state = self.state,
            .last_attempt_ms = self.last_attempt_ms,
            .requested_access = self.requested_access,
            .provider_id = self.provider_id,
            .last_failure = self.last_failure,
        };
    }

    /// Why the catalog is down, or null while it has entries or has not been
    /// asked yet.
    pub fn downFailure(self: *const CapabilityResolver) ?model_catalog.FailureCategory {
        if (self.state != .failed) return null;
        return self.last_failure orelse .runtime;
    }

    /// The owner must exclude capability readers during refresh. Borrowed
    /// catalog entries stay valid until the next exclusive refresh or adoption.
    pub fn refreshIfDue(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
    ) model_capabilities.ResolveError!void {
        const now = model_catalog.clockMs();
        const requested = model_catalog.AccessMetadata.init(input.access);
        if (!self.loadDue(provider, requested, now)) return;

        try self.adopt(alloc, provider, requested, now, model_catalog.fetchTraced(provider, alloc, input));
    }

    /// Whether the catalog needs a load for `requested` access at `now`: it
    /// never loaded, its access changed, or its refresh interval passed.
    fn loadDue(
        self: *const CapabilityResolver,
        provider: model_catalog.Provider,
        requested: model_catalog.AccessMetadata,
        now: i64,
    ) bool {
        const expired = if (provider.refresh_interval_ms) |interval|
            now < self.last_attempt_ms or now - self.last_attempt_ms >= interval
        else
            false;
        return self.state == .idle or self.accessChanged(provider, requested) or expired;
    }

    fn accessChanged(
        self: *const CapabilityResolver,
        provider: model_catalog.Provider,
        requested: model_catalog.AccessMetadata,
    ) bool {
        return !std.meta.eql(self.provider_id, provider.provider_id) or
            self.requested_access == null or !std.meta.eql(self.requested_access.?, requested);
    }

    /// Takes ownership of `result`, a fetch for `requested` access that
    /// started at `attempt_ms`.
    fn adopt(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        requested: model_catalog.AccessMetadata,
        attempt_ms: i64,
        result: model_catalog.FetchResult,
    ) model_capabilities.ResolveError!void {
        const access_changed = self.accessChanged(provider, requested);
        const loaded = switch (result) {
            .loaded => |loaded| loaded,
            .failed => |failed| {
                if (failed.failure.category == .cancellation) return error.Cancelled;
                self.last_attempt_ms = attempt_ms;
                self.requested_access = requested;
                self.provider_id = provider.provider_id;
                self.last_failure = failed.failure.category;
                if (access_changed) {
                    if (self.catalog.items.len > 0) debug_trace.logf("gateway", "dropping model catalog after access changed entries={d}", .{self.catalog.items.len});
                    model_catalog.freeModelCatalog(alloc, &self.catalog);
                    self.catalog = .empty;
                }
                if (self.catalog.items.len == 0) self.state = .failed;
                debug_trace.logf("gateway", "model catalog refresh failed category={t} retained={}", .{ failed.failure.category, self.state == .ready });
                return;
            },
        };
        model_catalog.freeModelCatalog(alloc, &self.catalog);
        self.catalog = loaded.catalog;
        self.state = .ready;
        self.last_attempt_ms = attempt_ms;
        self.requested_access = requested;
        self.provider_id = provider.provider_id;
        self.last_failure = null;
    }

    /// `resolve` for a caller that must not wait out a first load that cannot
    /// reach the catalog. The load runs as `loadWithin` describes; when it is
    /// given up on, the catalog counts as failed and `fallback` answers, as
    /// after any failed load.
    pub fn resolveWithin(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
        model: []const u8,
        fallback: model_capabilities.Capabilities,
        wait_ms: i64,
    ) model_capabilities.ResolveError!model_capabilities.Capabilities {
        if (self.state == .idle) try self.loadWithin(alloc, provider, input, wait_ms);
        return self.resolve(alloc, provider, input, model, fallback);
    }

    /// `refreshIfDue` for a caller that must not wait out a refresh that
    /// cannot reach the catalog. A due load runs as `loadWithin` describes;
    /// one given up on fails as any failed refresh does, so the catalog
    /// already loaded for the same access stays in use until the next
    /// refresh is due.
    pub fn refreshWithin(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
        wait_ms: i64,
    ) model_capabilities.ResolveError!void {
        if (!self.loadDue(provider, .init(input.access), model_catalog.clockMs())) return;
        try self.loadWithin(alloc, provider, input, wait_ms);
    }

    /// Loads the catalog on a thread of its own, because on a dead network
    /// the load can sit in a DNS lookup that std.Io cannot cut short until
    /// the system resolver gives up. When its request still has no
    /// connection `wait_ms` after the load started, the load counts as a
    /// transport failure; it is cancelled, never adopted, and freed once it
    /// ends. A load whose request has connected is waited for until it ends,
    /// within its own deadline, so a slow link still gets the catalog. A
    /// provider that does not report its connection loads inline, as
    /// `refreshIfDue` does. A cancelled wait leaves the load running for the
    /// next call. A cancelled load's request walks away from a lookup that
    /// still hangs (`gateway_client.openRequestOnJob`), so freeing the load
    /// at shutdown does not wait the lookup out.
    fn loadWithin(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
        wait_ms: i64,
    ) model_capabilities.ResolveError!void {
        if (comptime builtin.single_threaded) return self.refreshIfDue(alloc, provider, input);
        if (!provider.reports_connection) return self.refreshIfDue(alloc, provider, input);
        self.freeEndedAbandonedLoads(alloc);
        const kind: []const u8 = if (self.state == .idle) "first load" else "refresh";
        const load = self.pending_load orelse started: {
            const started = CatalogLoad.start(alloc, provider, input) catch |err| {
                debug_trace.logf("gateway", "model catalog {s} runs inline err={s}", .{ kind, @errorName(err) });
                return self.refreshIfDue(alloc, provider, input);
            };
            self.pending_load = started;
            break :started started;
        };
        while (!load.finished.load(.acquire)) {
            if (input.cancel_flag) |flag| {
                if (flag.load(.seq_cst)) return error.Cancelled;
            }
            const waited_ms = model_catalog.clockMs() - load.started_ms;
            if (waited_ms >= wait_ms and !load.connected.load(.acquire)) {
                load.cancel_requested.store(true, .seq_cst);
                self.pending_load = null;
                load.next = self.abandoned_loads;
                self.abandoned_loads = load;
                debug_trace.logf("gateway", "model catalog {s} abandoned before it connected waited_ms={d}", .{ kind, waited_ms });
                const requested = model_catalog.AccessMetadata.init(load.input.access);
                return self.adopt(alloc, provider, requested, load.started_ms, .{ .failed = .{
                    .access = requested,
                    .failure = .{ .category = .transport },
                } });
            }
            io_mod.sleep(load_poll_ns);
        }
        self.pending_load = null;
        const requested = model_catalog.AccessMetadata.init(load.input.access);
        const started_ms = load.started_ms;
        try self.adopt(alloc, provider, requested, started_ms, load.finish(alloc));
    }

    fn freeEndedAbandonedLoads(self: *CapabilityResolver, alloc: Allocator) void {
        var link = &self.abandoned_loads;
        while (link.*) |load| {
            if (load.finished.load(.acquire)) {
                link.* = load.next;
                load.discard(alloc);
            } else {
                link = &load.next;
            }
        }
    }

    pub fn resolve(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
        model: []const u8,
        fallback: model_capabilities.Capabilities,
    ) model_capabilities.ResolveError!model_capabilities.Capabilities {
        if (self.state == .idle) {
            try self.refreshIfDue(alloc, provider, input);
        }

        if (self.state == .failed) {
            debug_trace.logf(
                "gateway",
                "model catalog lookup outcome=cache_failed model={s}",
                .{model},
            );
            return fallback;
        }
        for (self.catalog.items) |entry| {
            if (std.mem.eql(u8, entry.id, model)) {
                debug_trace.logf(
                    "gateway",
                    "model catalog lookup outcome=ready_hit model={s}",
                    .{model},
                );
                return model_capabilities.mergeCapabilities(
                    fallback,
                    model_catalog_metadata.fromCatalogEntry(entry),
                );
            }
        }
        debug_trace.logf(
            "gateway",
            "model catalog lookup outcome=missing_entry model={s}",
            .{model},
        );
        return fallback;
    }

    pub fn available(
        self: *const CapabilityResolver,
        model: []const u8,
        fallback: model_capabilities.Capabilities,
    ) model_capabilities.Capabilities {
        if (self.state == .ready) {
            for (self.catalog.items) |entry| {
                if (std.mem.eql(u8, entry.id, model)) {
                    return model_capabilities.mergeCapabilities(
                        fallback,
                        model_catalog_metadata.fromCatalogEntry(entry),
                    );
                }
            }
        }
        return fallback;
    }

    pub fn catalogEntries(self: *const CapabilityResolver) ?[]const model_catalog.ModelCatalogEntry {
        if (self.state != .ready) return null;
        return self.catalog.items;
    }

    pub fn adoptOwnedCatalog(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        access: credentials.CatalogAccess,
        owned_catalog: *std.ArrayList(model_catalog.ModelCatalogEntry),
    ) void {
        model_catalog.freeModelCatalog(alloc, &self.catalog);
        self.catalog = owned_catalog.*;
        owned_catalog.* = .empty;
        self.state = .ready;
        self.last_attempt_ms = model_catalog.clockMs();
        self.requested_access = .init(access);
        self.provider_id = provider.provider_id;
    }
};

/// How long a request waits for a model catalog load to connect, for
/// `CapabilityResolver.resolveWithin` and `refreshWithin`. A healthy network
/// connects well within this, and a connected load is waited for until it
/// ends. On a dead network the load would hold the request until its DNS
/// lookup or connect timed out, 20 to 30 seconds, before the request could
/// go on.
pub const catalog_connect_wait_ms: i64 = 2_000;

/// How often `CapabilityResolver.loadWithin` checks on a load.
const load_poll_ns = 2 * std.time.ns_per_ms;

/// A catalog load on a thread of its own. It owns copies of the access and
/// endpoint, because the caller's credential can be replaced while the load
/// runs, and its own cancel and connection flags.
const CatalogLoad = struct {
    provider: model_catalog.Provider,
    input: model_catalog.FetchInput,
    started_ms: i64,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    /// Set by the provider once the load's request has a connection.
    connected: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    /// Set before `finished`; owns any loaded catalog.
    result: model_catalog.FetchResult = undefined,
    thread: std.Thread = undefined,
    /// The next load in `CapabilityResolver.abandoned_loads`.
    next: ?*CatalogLoad = null,

    fn start(alloc: Allocator, provider: model_catalog.Provider, input: model_catalog.FetchInput) !*CatalogLoad {
        const load = try alloc.create(CatalogLoad);
        errdefer alloc.destroy(load);
        const endpoint = try alloc.dupe(u8, input.endpoint);
        errdefer alloc.free(endpoint);
        const access = input.access;
        load.* = .{
            .provider = provider,
            .input = .{
                .access = access,
                .endpoint = endpoint,
                .cancel_flag = &load.cancel_requested,
                .view = input.view,
                .connected = &load.connected,
            },
            .started_ms = model_catalog.clockMs(),
        };
        load.thread = try std.Thread.spawn(.{}, run, .{ load, alloc });
        return load;
    }

    fn run(self: *CatalogLoad, alloc: Allocator) void {
        self.result = model_catalog.fetchTraced(self.provider, alloc, self.input);
        self.finished.store(true, .release);
    }

    /// Joins a finished load, frees it, and returns its result.
    fn finish(self: *CatalogLoad, alloc: Allocator) model_catalog.FetchResult {
        self.thread.join();
        const result = self.result;
        self.destroy(alloc);
        return result;
    }

    /// Cancels the load, waits for it, and frees it with anything it loaded.
    fn discard(self: *CatalogLoad, alloc: Allocator) void {
        self.cancel_requested.store(true, .seq_cst);
        self.thread.join();
        switch (self.result) {
            .loaded => |loaded| {
                var catalog = loaded.catalog;
                debug_trace.logf("gateway", "model catalog load discarded entries={d}", .{catalog.items.len});
                model_catalog.freeModelCatalog(alloc, &catalog);
            },
            .failed => {},
        }
        self.destroy(alloc);
    }

    fn destroy(self: *CatalogLoad, alloc: Allocator) void {
        alloc.free(self.input.endpoint);
        alloc.destroy(self);
    }
};

inline fn failCapabilities(err: anytype) @TypeOf(err)!model_capabilities.Capabilities {
    return @errorCast(failCapabilitiesDynamic(err));
}

noinline fn failCapabilitiesDynamic(err: anyerror) anyerror!model_capabilities.Capabilities {
    return err;
}

test "capability failure writer preserves exact error type and identity" {
    const failure = failCapabilities(error.Cancelled);
    try std.testing.expect(
        @TypeOf(failure) == error{Cancelled}!model_capabilities.Capabilities,
    );
    try std.testing.expectError(error.Cancelled, failure);
}

const FakeCatalog = struct {
    outcome: enum {
        cancelled,
        unavailable,
        ready,
    },
    calls: usize = 0,

    fn fetch(
        raw: ?*anyopaque,
        alloc: Allocator,
        _: model_catalog.FetchInput,
    ) Allocator.Error!model_catalog.ProviderResult {
        const self: *FakeCatalog = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        switch (self.outcome) {
            .cancelled => return .{ .failure = .{ .category = .cancellation } },
            .unavailable => return .{ .failure = .{ .category = .transport } },
            .ready => {
                var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
                errdefer model_catalog.freeModelCatalog(alloc, &entries);
                const id = try alloc.dupe(u8, "provider/model");
                errdefer alloc.free(id);
                const model_type = try alloc.dupe(u8, "language");
                errdefer alloc.free(model_type);
                const entry = model_catalog.ModelCatalogEntry{
                    .id = id,
                    .model_type = model_type,
                    .has_vision = true,
                    .has_file_input = true,
                    .context_window = 256_000,
                    .max_tokens = 32_000,
                };
                try entries.append(alloc, entry);
                return .{ .catalog = entries };
            },
        }
    }

    fn provider(self: *FakeCatalog) model_catalog.Provider {
        return .{
            .context = self,
            .fetch_fn = fetch,
        };
    }
};

fn testCatalogOf(alloc: Allocator, ids: []const []const u8) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    for (ids) |id| {
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try entries.append(alloc, .{ .id = owned_id, .model_type = model_type, .has_vision = true, .context_window = 1000 });
    }
    return entries;
}

const FakeChatUrl = struct {
    resolved: []const u8,

    fn resolve(raw: ?*anyopaque, fallback: []const u8) []const u8 {
        const self: *FakeChatUrl = @ptrCast(@alignCast(raw.?));
        _ = fallback;
        return self.resolved;
    }
};

/// A catalog that answers like `FakeCatalog.ready` once released, and fails
/// as cancelled once its fetch is cancelled, like a lookup on a dead network.
/// It reports its connection, at once when `connects` is set.
const GatedCatalog = struct {
    connects: bool = false,
    /// False for a fetch that cannot be cut short, which answers only once
    /// released.
    honors_cancel: bool = true,
    reports_connection: bool = true,
    released: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(usize) = .init(0),
    saw_cancel: std.atomic.Value(bool) = .init(false),
    saw_credential: std.atomic.Value(bool) = .init(false),

    fn fetch(
        raw: ?*anyopaque,
        alloc: Allocator,
        input: model_catalog.FetchInput,
    ) Allocator.Error!model_catalog.ProviderResult {
        const self: *GatedCatalog = @ptrCast(@alignCast(raw.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        if (self.connects) input.connected.?.store(true, .release);
        if (input.access == .host_managed) {
            self.saw_credential.store(true, .seq_cst);
        }
        while (!self.released.load(.seq_cst)) {
            if (self.honors_cancel) if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) {
                self.saw_cancel.store(true, .seq_cst);
                return .{ .failure = .{ .category = .cancellation } };
            };
            io_mod.sleep(std.time.ns_per_ms);
        }
        var ready = FakeCatalog{ .outcome = .ready };
        return FakeCatalog.fetch(&ready, alloc, input);
    }

    fn provider(self: *GatedCatalog) model_catalog.Provider {
        return .{ .context = self, .fetch_fn = fetch, .reports_connection = self.reports_connection };
    }

    /// Releases the catalog after `delay_ms` from a thread of its own.
    fn releaseAfter(self: *GatedCatalog, delay_ms: u64) !std.Thread {
        const Release = struct {
            fn run(gated: *GatedCatalog, ms: u64) void {
                io_mod.sleep(ms * std.time.ns_per_ms);
                gated.released.store(true, .seq_cst);
            }
        };
        return std.Thread.spawn(.{}, Release.run, .{ self, delay_ms });
    }
};

fn reportingProvider(fake: *FakeCatalog) model_catalog.Provider {
    var provider = fake.provider();
    provider.reports_connection = true;
    return provider;
}

/// Loads `gated`'s catalog once through a provider with a refresh interval,
/// then lets the interval pass, so the next `refreshWithin` is due.
fn loadRefreshableCatalogForTest(
    alloc: Allocator,
    resolver: *CapabilityResolver,
    gated: *GatedCatalog,
) !model_catalog.Provider {
    var provider = gated.provider();
    provider.refresh_interval_ms = 60_000;
    gated.connects = true;
    gated.released.store(true, .seq_cst);
    try resolver.refreshWithin(alloc, provider, .{ .endpoint = "/v1/models" }, 60_000);
    try std.testing.expectEqual(CapabilityResolverState.ready, resolver.state);
    gated.released.store(false, .seq_cst);
    resolver.last_attempt_ms -= 60_000;
    return provider;
}
