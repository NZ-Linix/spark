const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const credentials = @import("../auth/credentials.zig");
const collections = @import("../shared/collections.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const model_catalog_metadata = @import("../gateway/model_catalog_metadata.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const io_mod = @import("../shared/io.zig");
const list_window = @import("../shared/list_window.zig");
const fuzzy_match = @import("../shared/fuzzy_match.zig");
const types = @import("../shared/types.zig");
const Allocator = std.mem.Allocator;

/// What asked for a catalog load. Every trigger is user activity, so an idle
/// session never polls the models endpoint.
pub const LoadTrigger = enum {
    /// Refetches a loaded catalog only after the provider's refresh interval.
    activity,
    /// The model picker opened. Revalidates unless a fetch is in flight or
    /// one started less than `picker_revalidate_floor_ms` ago.
    picker_open,
};

/// Reopening the picker within this window reuses the catalog it just fetched.
const picker_revalidate_floor_ms: i64 = 5_000;

/// After consecutive failures no trigger fetches again for 5 s, then 10 s,
/// 20 s, and so on, up to five minutes, so an outage is never hammered.
const failure_backoff_base_ms: i64 = 5_000;
const failure_backoff_cap_ms: i64 = 5 * std.time.ms_per_min;

/// How long a request waits for a failed catalog's retry before it goes out
/// without the catalog's limits.
const failed_catalog_retry_wait_ms: i64 = 2_000;

fn failureBackoffMs(failure_streak: u32) i64 {
    var delay = failure_backoff_base_ms;
    var step: u32 = 1;
    while (step < failure_streak and delay < failure_backoff_cap_ms) : (step += 1) delay *= 2;
    return @min(delay, failure_backoff_cap_ms);
}

const ModelCacheState = enum {
    idle,
    loading,
    ready,
    failed,
};

const CatalogOutcome = struct {
    loaded: ?model_catalog.Provenance = null,
    last_failure: ?model_catalog.FailedOutcome = null,
};

/// What publishing one fetch result did, for the /trace report.
const AppliedFetch = union(enum) {
    ready: struct {
        entries: usize,
        reused_previous: bool,
        provenance: model_catalog.Provenance,
    },
    failed: struct {
        outcome: model_catalog.FailedOutcome,
        kept_previous: bool,
    },

    fn record(self: AppliedFetch) void {
        switch (self) {
            .ready => |ready| diagnostics.recordModelCatalogEvent(false, .load, "outcome=ready entries={d} reused_previous={s}", .{
                ready.entries,
                boolLabel(ready.reused_previous),
            }),
            .failed => |failed| diagnostics.recordModelCatalogEvent(true, .load, "outcome=failed category={s} status={d} retryable={s} kept_previous_catalog={s}", .{
                @tagName(failed.outcome.failure.category),
                if (failed.outcome.failure.http_status) |status| @backingInt(status) else 0,
                boolLabel(failed.outcome.failure.retryable),
                boolLabel(failed.kept_previous),
            }),
        }
    }
};

pub const ModelMenuLoadState = enum {
    loading,
    ready,
    failed,
};

pub const ModelMenuCatalogState = struct {
    source: ?credentials.Source = null,
    from_profile_settings: bool = false,
    failure: ?Failure = null,

    pub const Failure = struct {
        category: model_catalog.FailureCategory,
        retryable: bool,
    };
};

pub const ModelProviderFilter = enum {
    all,
    anthropic,
    openai,
    xai,
    zai,
    others,
};

pub const model_provider_filter_count = @typeInfo(ModelProviderFilter).@"enum".field_names.len;

pub const ModelMenuItem = struct {
    id: []u8,
    /// The display name a connection gives the model, shown in place of `id`.
    name: ?[]u8 = null,
    provider: []const u8,
    capabilities: model_capabilities.Capabilities,

    pub fn label(self: ModelMenuItem) []const u8 {
        return self.name orelse self.id;
    }

    fn deinit(self: ModelMenuItem, alloc: Allocator) void {
        alloc.free(self.id);
        if (self.name) |name| alloc.free(name);
    }
};

pub const ModelMenu = struct {
    active: bool = false,
    load_state: ModelMenuLoadState = .loading,
    catalog_state: ModelMenuCatalogState = .{},
    items: std.ArrayList(ModelMenuItem) = .empty,
    provider_index: usize = 0,
    selected_index: usize = 0,
    window_start: usize = 0,
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,

    pub fn deinit(self: *ModelMenu, alloc: Allocator) void {
        self.clearSnapshot(alloc);
        self.* = .{};
    }

    pub fn query(self: *const ModelMenu) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    pub fn setQuery(self: *ModelMenu, query_text: []const u8) void {
        const len = @min(query_text.len, self.query_buf.len);
        if (len > 0) @memmove(self.query_buf[0..len], query_text[0..len]);
        self.query_len = len;
        self.selected_index = 0;
        self.window_start = 0;
    }

    pub fn providerFilter(self: *const ModelMenu) ModelProviderFilter {
        return @fromBackingInt(@intCast(@min(self.provider_index, model_provider_filter_count - 1)));
    }

    pub fn filteredItemCount(self: *const ModelMenu) usize {
        return modelMenuFilteredItemCount(self.items.items, self.providerFilter(), self.query());
    }

    pub fn itemAt(self: *const ModelMenu, display_index: usize) ?*const ModelMenuItem {
        return modelMenuItemAt(self.items.items, self.providerFilter(), self.query(), display_index);
    }

    pub fn moveVisibleItems(self: *ModelMenu, delta: i32, visible_items: u16) bool {
        const item_count = self.filteredItemCount();
        if (!self.active or self.load_state != .ready or item_count == 0) return false;

        const current: i32 = @intCast(self.selected_index % item_count);
        var next = current + delta;
        if (next < 0) next = @as(i32, @intCast(item_count)) - 1;
        if (next >= @as(i32, @intCast(item_count))) next = 0;
        self.selected_index = @intCast(next);
        self.window_start = list_window.updateEdgeStart(
            self.window_start,
            item_count,
            self.selected_index,
            @max(visible_items, 1),
        );
        return true;
    }

    pub fn moveProvider(self: *ModelMenu, delta: i32) bool {
        if (!self.active or self.load_state != .ready or delta == 0) return false;
        const filter_count = model_provider_filter_count;
        if (filter_count <= 1) return false;

        const current = @min(self.provider_index, filter_count - 1);
        const direction: i32 = if (delta < 0) -1 else 1;
        var next: i32 = @intCast(current);
        for (0..filter_count) |_| {
            next += direction;
            if (next < 0) next = @as(i32, @intCast(filter_count)) - 1;
            if (next >= @as(i32, @intCast(filter_count))) next = 0;
            const filter: ModelProviderFilter = @fromBackingInt(@intCast(next));
            if (!modelProviderFilterAvailable(self.items.items, filter)) continue;
            if (next == current) return false;
            self.provider_index = @intCast(next);
            self.selected_index = 0;
            self.window_start = 0;
            return true;
        }
        return false;
    }

    pub fn selectedModelAlloc(self: *const ModelMenu, alloc: Allocator) !?[]u8 {
        if (!self.active or self.load_state != .ready) return null;
        const item = self.itemAt(self.selected_index) orelse return null;
        return try alloc.dupe(u8, item.id);
    }

    fn clearSnapshot(self: *ModelMenu, alloc: Allocator) void {
        for (self.items.items) |item| item.deinit(alloc);
        self.items.deinit(alloc);
        self.items = .empty;
        self.provider_index = 0;
        self.selected_index = 0;
        self.window_start = 0;
    }
};

pub fn modelMenuFilteredItemCount(
    items: []const ModelMenuItem,
    provider_filter: ModelProviderFilter,
    query: []const u8,
) usize {
    return modelMenuRanking(items, provider_filter, query).count();
}

/// Returns the row at `display_index`. Better matches list first, and rows
/// that match equally well keep catalog order.
pub fn modelMenuItemAt(
    items: []const ModelMenuItem,
    provider_filter: ModelProviderFilter,
    query: []const u8,
    display_index: usize,
) ?*const ModelMenuItem {
    const position = modelMenuRanking(items, provider_filter, query).at(display_index) orelse return null;
    return &items[position];
}

/// The inverse of `modelMenuItemAt` for the first item with `id`.
fn modelMenuDisplayIndex(
    items: []const ModelMenuItem,
    provider_filter: ModelProviderFilter,
    query: []const u8,
    id: []const u8,
) ?usize {
    const position = for (items, 0..) |item, position| {
        if (std.mem.eql(u8, item.id, id)) break position;
    } else return null;
    return modelMenuRanking(items, provider_filter, query).rankOf(position);
}

/// Matches a model on its full id, provider prefix included, so one query
/// can name both the provider and the model, and on the model's own name
/// after the last `/`, so typing that name exactly lists it first:
/// `gpt-4o` finds `openai/gpt-4o` before `openai/gpt-4o-mini`.
pub fn modelIdMatch(query: []const u8, id: []const u8) ?fuzzy_match.Match {
    const slash = std.mem.findScalarLast(u8, id, '/') orelse return fuzzy_match.match(query, &.{.{ .text = id }});
    return fuzzy_match.match(query, &.{ .{ .text = id }, .{ .text = id[slash + 1 ..] } });
}

/// The Models menu in catalog order, without the rows outside the provider
/// tab.
const ModelMenuMatches = struct {
    items: []const ModelMenuItem,
    provider_filter: ModelProviderFilter,
    query: []const u8,

    pub fn matchAt(self: ModelMenuMatches, position: usize) ?fuzzy_match.Match {
        const item = self.items[position];
        if (!providerMatchesFilter(item.provider, self.provider_filter)) return null;
        return modelIdMatch(self.query, item.id) orelse if (item.name) |name| modelIdMatch(self.query, name) else null;
    }
};

fn modelMenuRanking(
    items: []const ModelMenuItem,
    provider_filter: ModelProviderFilter,
    query: []const u8,
) fuzzy_match.Ranking(ModelMenuMatches) {
    return .{
        .context = .{ .items = items, .provider_filter = provider_filter, .query = query },
        .len = items.len,
    };
}

/// The catalog's ids matched the same way, for inline `/model` suggestions.
const CatalogIdMatches = struct {
    entries: []const model_catalog.ModelCatalogEntry,
    query: []const u8,

    pub fn matchAt(self: CatalogIdMatches, position: usize) ?fuzzy_match.Match {
        return modelIdMatch(self.query, self.entries[position].id);
    }
};

fn providerFilter(provider: []const u8) ModelProviderFilter {
    return if (std.ascii.eqlIgnoreCase(provider, "anthropic"))
        .anthropic
    else if (std.ascii.eqlIgnoreCase(provider, "openai"))
        .openai
    else if (std.ascii.eqlIgnoreCase(provider, "xai"))
        .xai
    else if (std.ascii.eqlIgnoreCase(provider, "zai"))
        .zai
    else
        .others;
}

pub fn modelProviderFilterAvailable(items: []const ModelMenuItem, filter: ModelProviderFilter) bool {
    if (filter == .all) return true;
    var seen: [model_provider_filter_count]bool = @splat(false);
    for (items) |item| seen[@backingInt(providerFilter(item.provider))] = true;

    var specific_count: usize = 0;
    for (seen[1..]) |available| specific_count += @intFromBool(available);
    return specific_count > 1 and seen[@backingInt(filter)];
}

fn providerMatchesFilter(provider: []const u8, filter: ModelProviderFilter) bool {
    return filter == .all or providerFilter(provider) == filter;
}

/// Whether the provider tab `filter` lists `item`, whatever is typed.
pub fn modelProviderFilterKeeps(item: ModelMenuItem, filter: ModelProviderFilter) bool {
    return providerMatchesFilter(item.provider, filter);
}

pub const Runtime = struct {
    const Self = @This();

    alloc: Allocator,
    /// Configured providers read their own models URL from their settings.
    models_path: []const u8 = "/models",
    catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty,
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    state: ModelCacheState = .idle,
    /// A fetch is running. Only the first load for an access shows as
    /// `.loading`; a revalidation or retry leaves the state readers see alone.
    /// A request waits up to `failed_catalog_retry_wait_ms` for a failed
    /// catalog's retry, and on nothing else but a first load.
    fetch_in_flight: bool = false,
    /// Consecutive failed fetches. A success or reset clears it.
    failure_streak: u32 = 0,
    /// After a failure, no fetch starts before this time, whatever the trigger.
    retry_not_before_ms: i64 = 0,
    /// A finished revalidation waiting for `pollLoadTransition` to adopt it.
    /// Owns any loaded catalog.
    staged: ?model_catalog.FetchResult = null,
    completion_pending: bool = false,
    last_attempt_ms: i64 = 0,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    requested_access: ?model_catalog.AccessMetadata = null,
    outcome: CatalogOutcome = .{},
    from_profile_settings: bool = false,
    menu: ModelMenu = .{},

    pub fn init(alloc: Allocator) Self {
        return .{
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Self) void {
        self.cancelAndJoin();
        self.discardStagedLocked();
        self.menu.deinit(self.alloc);
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
    }

    /// Starts a background fetch of `provider`'s catalog for `access`.
    pub fn startWarmup(
        self: *Self,
        provider: model_catalog.Provider,
        access: credentials.CatalogAccess,
        trigger: LoadTrigger,
    ) void {
        self.from_profile_settings = provider.provider_id == .configured;
        if (!self.beginLoad(access, provider.refresh_interval_ms, trigger)) return;

        const thread = std.Thread.spawn(.{}, preloadThreadMain, .{ self, provider, access }) catch {
            self.completeFetch(.{ .failed = .{
                .access = .init(access),
                .failure = .{ .category = .runtime, .retryable = true },
            } });
            return;
        };
        self.mutex.lockUncancelable(io_mod.getIo());
        self.thread = thread;
        self.mutex.unlock(io_mod.getIo());
    }

    /// Loads the catalog inline for cooperative single-threaded hosts.
    pub fn loadCooperative(
        self: *Self,
        provider: model_catalog.Provider,
        access: credentials.CatalogAccess,
    ) void {
        self.from_profile_settings = provider.provider_id == .configured;
        if (!self.beginLoad(access, provider.refresh_interval_ms, .activity)) return;

        self.completeFetch(model_catalog.fetchTraced(provider, self.alloc, .{
            .access = access,
            .endpoint = self.models_path,
            .cancel_flag = &self.cancel_requested,
            .view = .picker,
        }));
    }

    fn beginLoad(
        self: *Self,
        access: credentials.CatalogAccess,
        refresh_interval_ms: ?i64,
        trigger: LoadTrigger,
    ) bool {
        self.finishThreadIfDone();

        const requested_access = model_catalog.AccessMetadata.init(access);
        self.mutex.lockUncancelable(io_mod.getIo());
        const access_changed = self.state != .idle and
            (self.requested_access == null or
                !std.meta.eql(self.requested_access.?, requested_access));
        self.mutex.unlock(io_mod.getIo());
        if (access_changed) self.reset();

        const now = model_catalog.clockMs();
        self.mutex.lockUncancelable(io_mod.getIo());
        // A clock that moved backwards makes every elapsed check due.
        const elapsed = if (now < self.last_attempt_ms) std.math.maxInt(i64) else now - self.last_attempt_ms;
        const expired = if (refresh_interval_ms) |interval| elapsed >= interval else false;
        const picker_due = trigger == .picker_open and elapsed >= picker_revalidate_floor_ms;
        // A retained catalog whose refresh failed retries once its backoff ends.
        const retry_due = if (self.outcome.last_failure) |failed| failed.failure.retryable else false;
        const backoff_over = now < self.last_attempt_ms or now >= self.retry_not_before_ms;
        // A staged revalidation is newer than anything a fetch would start now.
        // A fetch that finished after the join above still holds its thread;
        // the next trigger joins it before starting another.
        const should_load = !self.fetch_in_flight and self.staged == null and self.thread == null and backoff_over and switch (self.state) {
            .idle, .failed => true,
            .ready => expired or picker_due or retry_due,
            .loading => false,
        };
        if (!should_load) {
            self.mutex.unlock(io_mod.getIo());
            return false;
        }
        // A first load blocks request resolution, and a failed catalog's retry
        // holds it for at most `failed_catalog_retry_wait_ms`. A revalidation
        // runs behind the state readers already see.
        const first_load = self.state == .idle;
        if (first_load) self.state = .loading;
        self.fetch_in_flight = true;
        self.last_attempt_ms = now;
        self.requested_access = requested_access;
        const failure_streak = self.failure_streak;
        self.mutex.unlock(io_mod.getIo());
        self.cancel_requested.store(false, .seq_cst);
        debug_trace.logf("catalog", "model catalog load begin trigger={s} first_load={s} expired={s} failure_streak={d}", .{
            @tagName(trigger),
            boolLabel(first_load),
            boolLabel(expired),
            failure_streak,
        });
        return true;
    }

    pub fn reset(self: *Self) void {
        self.cancelAndJoin();

        self.mutex.lockUncancelable(io_mod.getIo());
        self.discardStagedLocked();
        self.menu.deinit(self.alloc);
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
        self.catalog = .empty;
        self.outcome = .{};
        self.state = .idle;
        self.completion_pending = false;
        self.last_attempt_ms = 0;
        // A new credential or provider deserves an immediate load.
        self.failure_streak = 0;
        self.retry_not_before_ms = 0;
        self.requested_access = null;
        self.mutex.unlock(io_mod.getIo());
        self.cancel_requested.store(false, .seq_cst);
    }

    pub fn resetForProviderChange(self: *Self) void {
        debug_trace.logf("catalog", "model catalog reset reason=provider_changed", .{});
        self.reset();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
        self.catalog = .empty;
        self.outcome = .{};
        self.from_profile_settings = false;
    }

    /// Installs a catalog that was completely fetched and validated before the
    /// caller's publication boundary. Ownership transfers without allocation.
    pub fn adoptOwnedCatalog(
        self: *Self,
        access: credentials.CatalogAccess,
        owned_catalog: *std.ArrayList(model_catalog.ModelCatalogEntry),
    ) void {
        self.cancelAndJoin();

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.discardStagedLocked();
        self.menu.deinit(self.alloc);
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
        self.catalog = owned_catalog.*;
        owned_catalog.* = .empty;
        self.outcome = .{ .loaded = .{
            .access = model_catalog.AccessMetadata.init(access),
        } };
        self.from_profile_settings = false;
        self.state = .ready;
        self.completion_pending = true;
        self.last_attempt_ms = model_catalog.clockMs();
        self.failure_streak = 0;
        self.retry_not_before_ms = 0;
        self.requested_access = model_catalog.AccessMetadata.init(access);
        self.cancel_requested.store(false, .seq_cst);
        const entries = self.catalog.items.len;
        diagnostics.recordModelCatalogEvent(false, .load, "outcome=adopted entries={d}", .{entries});
    }

    pub fn isLoading(self: *Self) bool {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.state == .loading;
    }

    pub fn openMenu(self: *Self) !void {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());

        var next: ModelMenu = .{ .active = true };
        errdefer next.deinit(self.alloc);
        try self.refreshMenuLocked(&next);
        self.menu.deinit(self.alloc);
        self.menu = next;
    }

    pub fn closeMenu(self: *Self) void {
        self.menu.deinit(self.alloc);
    }

    pub fn setMenuQuery(self: *Self, query: []const u8) void {
        self.menu.setQuery(query);
    }

    /// The owner's publication boundary: adopts a staged revalidation and
    /// refreshes an open menu. Call it where no borrowed catalog id is held.
    pub fn pollLoadTransition(self: *Self) !bool {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.staged) |staged| {
            self.staged = null;
            self.applyFetchLocked(staged).record();
        }
        if (!self.completion_pending) return false;

        if (self.menu.active) try self.refreshMenuLocked(&self.menu);
        self.completion_pending = false;
        return true;
    }

    pub fn isFailed(self: *Self) bool {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.state == .failed;
    }

    /// Why the catalog is down, or null while it loads, after it loaded, or
    /// when a failed refresh kept the earlier catalog.
    pub fn downFailure(self: *Self) ?model_catalog.FailureCategory {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .failed) return null;
        const failed = self.outcome.last_failure orelse return .runtime;
        return failed.failure.category;
    }

    pub fn snapshotCachedModelIds(self: *Self, alloc: Allocator) !?std.ArrayList([]u8) {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .ready or self.catalog.items.len == 0) return null;

        return try model_catalog.projectModelIds(alloc, self.catalog.items);
    }

    pub fn metadataForModel(self: *Self, model: []const u8) ?model_capabilities.GatewayMetadata {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .ready) return null;

        const entry = findCatalogModel(self.catalog.items, model) orelse return null;
        return model_catalog_metadata.fromCatalogEntry(entry.*);
    }

    pub const TraceSnapshot = struct {
        state: []const u8,
        entries: usize,
        /// Null before the first fetch for the current access.
        last_attempt_age_ms: ?i64,
        failure_category: ?[]const u8,
        failure_http_status: ?std.http.Status,
        failure_retryable: bool,
    };

    /// Point-in-time catalog state for the /trace report; the returned struct
    /// owns no memory and stays valid after the lock is released.
    pub fn snapshotForTrace(self: *Self) TraceSnapshot {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const failure = self.outcome.last_failure;
        return .{
            .state = @tagName(self.state),
            .entries = self.catalog.items.len,
            .last_attempt_age_ms = if (self.last_attempt_ms > 0) model_catalog.clockMs() - self.last_attempt_ms else null,
            .failure_category = if (failure) |failed| @tagName(failed.failure.category) else null,
            .failure_http_status = if (failure) |failed| failed.failure.http_status else null,
            .failure_retryable = if (failure) |failed| failed.failure.retryable else false,
        };
    }

    pub fn resolveForRequest(
        self: *Self,
        model: []const u8,
        cancel_flag: *std.atomic.Value(bool),
    ) model_capabilities.ResolveError!model_capabilities.Capabilities {
        var retry_wait_until_ms: ?i64 = null;
        while (true) {
            self.finishThreadIfDone();
            self.mutex.lockUncancelable(io_mod.getIo());
            const state = self.state;
            if (state == .ready) {
                const metadata = if (findCatalogModel(self.catalog.items, model)) |entry|
                    model_catalog_metadata.fromCatalogEntry(entry.*)
                else
                    null;
                self.mutex.unlock(io_mod.getIo());
                debug_trace.logf(
                    "gateway",
                    "interactive model catalog lookup outcome={s} model={s}",
                    .{ if (metadata != null) "ready_hit" else "missing_entry", model },
                );
                if (metadata == null) {
                    diagnostics.recordModelCatalogEvent(false, .lookup, "outcome=missing_entry model={s}", .{model});
                }
                return model_capabilities.resolveCapabilities(model, metadata);
            }
            // A request waits a moment for a failed catalog's retry, such as
            // the one a submitted prompt starts, so a retry that lands quickly
            // gives this request its limits. A slow retry never holds it.
            const retry_in_flight = state == .failed and self.fetch_in_flight;
            self.mutex.unlock(io_mod.getIo());
            const wait_for_retry = retry_in_flight and wait: {
                const now = model_catalog.clockMs();
                const until = retry_wait_until_ms orelse now + failed_catalog_retry_wait_ms;
                retry_wait_until_ms = until;
                break :wait now < until;
            };

            switch (if (wait_for_retry) .loading else state) {
                .loading => {
                    if (cancel_flag.load(.seq_cst)) {
                        debug_trace.logf(
                            "gateway",
                            "interactive model catalog lookup outcome=cancelled model={s}",
                            .{model},
                        );
                        diagnostics.recordModelCatalogEvent(false, .lookup, "outcome=cancelled model={s}", .{model});
                        return error.Cancelled;
                    }
                    io_mod.sleep(std.time.ns_per_ms);
                },
                .failed, .idle => {
                    debug_trace.logf(
                        "gateway",
                        "interactive model catalog lookup outcome={s} model={s}",
                        .{ if (state == .failed) "cache_failed" else "cache_unavailable", model },
                    );
                    diagnostics.recordModelCatalogEvent(true, .lookup, "outcome={s} model={s}", .{
                        if (state == .failed) "cache_failed" else "cache_unavailable",
                        model,
                    });
                    return model_capabilities.capabilitiesForModel(model);
                },
                .ready => unreachable,
            }
        }
    }

    pub fn catalogModelCompletion(self: *Self, model: []const u8) ?[]const u8 {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .ready) return null;

        const entry = findCatalogModel(self.catalog.items, model) orelse return null;
        return entry.id;
    }

    /// Fills `out` with catalog ids that match `query`, ranked like the model
    /// menu, and returns how many it wrote. The ids borrow catalog storage.
    pub fn modelCompletions(self: *Self, query: []const u8, out: [][]const u8) usize {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .ready) return 0;

        const ranking: fuzzy_match.Ranking(CatalogIdMatches) = .{
            .context = .{ .entries = self.catalog.items, .query = query },
            .len = self.catalog.items.len,
        };
        var matches = ranking.iterator();
        var count: usize = 0;
        while (count < out.len) : (count += 1) {
            const position = matches.next() orelse break;
            out[count] = self.catalog.items[position].id;
        }
        return count;
    }

    fn preloadThreadMain(
        self: *Self,
        provider: model_catalog.Provider,
        access: credentials.CatalogAccess,
    ) void {
        self.completeFetch(model_catalog.fetchTraced(provider, self.alloc, .{
            .access = access,
            .endpoint = self.models_path,
            .cancel_flag = &self.cancel_requested,
            .view = .picker,
        }));
    }

    /// Publishes a finished fetch and takes ownership of its catalog. A first
    /// load lands at once: readers return nothing until the cache is ready, so
    /// none holds catalog memory. A revalidation waits in `staged` for
    /// `pollLoadTransition`, because UI readers borrow entry ids across calls
    /// within one frame.
    fn completeFetch(self: *Self, result: model_catalog.FetchResult) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.fetch_in_flight = false;
        self.completion_pending = true;
        switch (result) {
            .loaded => {
                self.failure_streak = 0;
                self.retry_not_before_ms = 0;
            },
            // Cancellation comes only from a reset or shutdown, which
            // discards this result, so it is not a failure to back off from.
            .failed => |failed| if (failed.failure.category != .cancellation) {
                self.failure_streak +|= 1;
                const delay_ms = failureBackoffMs(self.failure_streak);
                self.retry_not_before_ms = model_catalog.clockMs() + delay_ms;
                debug_trace.logf("catalog", "model catalog fetch failed category={s} failure_streak={d} retry_in_ms={d}", .{
                    @tagName(failed.failure.category),
                    self.failure_streak,
                    delay_ms,
                });
            },
        }
        if (self.state == .ready) {
            std.debug.assert(self.staged == null);
            self.staged = result;
            return;
        }
        self.applyFetchLocked(result).record();
    }

    /// Installs a fetch result, keeping the previous catalog when the new one
    /// failed or came back empty. Takes ownership of a loaded catalog.
    fn applyFetchLocked(self: *Self, result: model_catalog.FetchResult) AppliedFetch {
        switch (result) {
            .failed => |failure| {
                self.outcome.last_failure = failure;
                self.state = if (self.outcome.loaded != null and self.catalog.items.len > 0) .ready else .failed;
                return .{ .failed = .{ .outcome = failure, .kept_previous = self.state == .ready } };
            },
            .loaded => |loaded| {
                var catalog = loaded.catalog;
                const reuse_previous = catalog.items.len == 0 and self.outcome.loaded != null and self.catalog.items.len > 0;
                if (reuse_previous) {
                    model_catalog.freeModelCatalog(self.alloc, &catalog);
                    self.outcome.last_failure = null;
                } else {
                    model_catalog.freeModelCatalog(self.alloc, &self.catalog);
                    self.catalog = catalog;
                    self.outcome = .{ .loaded = loaded.provenance };
                }
                self.state = .ready;
                return .{ .ready = .{
                    .entries = self.catalog.items.len,
                    .reused_previous = reuse_previous,
                    .provenance = loaded.provenance,
                } };
            },
        }
    }

    fn discardStagedLocked(self: *Self) void {
        const staged = self.staged orelse return;
        self.staged = null;
        switch (staged) {
            .loaded => |loaded| {
                var catalog = loaded.catalog;
                debug_trace.logf("catalog", "model catalog dropped staged revalidation reason=superseded entries={d}", .{catalog.items.len});
                model_catalog.freeModelCatalog(self.alloc, &catalog);
            },
            .failed => {},
        }
    }

    fn cancelAndJoin(self: *Self) void {
        self.cancel_requested.store(true, .seq_cst);
        // The worker thread can join through `finishThreadIfDone`, so the
        // handle changes hands only under the mutex.
        self.mutex.lockUncancelable(io_mod.getIo());
        const thread = self.thread;
        self.thread = null;
        self.mutex.unlock(io_mod.getIo());
        if (thread) |handle| handle.join();
    }

    fn finishThreadIfDone(self: *Self) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        const should_join = !self.fetch_in_flight and self.thread != null;
        const thread = if (should_join) self.thread.? else null;
        if (should_join) self.thread = null;
        self.mutex.unlock(io_mod.getIo());
        if (thread) |handle| {
            handle.join();
            self.mutex.lockUncancelable(io_mod.getIo());
            self.completion_pending = true;
            self.mutex.unlock(io_mod.getIo());
        }
    }

    fn refreshMenuLocked(self: *Self, menu: *ModelMenu) !void {
        if (!menu.active) return;
        switch (self.state) {
            .idle, .loading => {
                menu.clearSnapshot(self.alloc);
                menu.load_state = .loading;
            },
            .failed => {
                menu.clearSnapshot(self.alloc);
                // A retry runs behind the failed state; the picker shows it.
                menu.load_state = if (self.fetch_in_flight) .loading else .failed;
            },
            .ready => try hydrateMenuSnapshot(self.alloc, menu, self.catalog.items),
        }
        menu.catalog_state = modelMenuCatalogState(self.outcome, self.from_profile_settings);
    }
};

fn boolLabel(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn modelMenuCatalogState(outcome: CatalogOutcome, from_profile_settings: bool) ModelMenuCatalogState {
    const access = if (outcome.last_failure) |failed|
        if (outcome.loaded == null) failed.access else outcome.loaded.?.access
    else if (outcome.loaded) |loaded|
        loaded.access
    else
        return .{};
    const failure = if (outcome.last_failure) |failed| failed.failure else null;
    return .{
        .source = access.source,
        .from_profile_settings = from_profile_settings,
        .failure = if (failure) |failed| .{
            .category = failed.category,
            .retryable = failed.retryable,
        } else null,
    };
}

fn appendMenuItem(alloc: Allocator, items: *std.ArrayList(ModelMenuItem), entry: model_catalog.ModelCatalogEntry) !void {
    const id = try alloc.dupe(u8, entry.id);
    const name: ?[]u8 = if (entry.name) |n| alloc.dupe(u8, n) catch |err| {
        alloc.free(id);
        return err;
    } else null;
    const item: ModelMenuItem = .{
        .id = id,
        .name = name,
        .provider = modelProvider(id),
        .capabilities = model_capabilities.resolveCapabilities(
            id,
            model_catalog_metadata.fromCatalogEntry(entry),
        ),
    };
    items.append(alloc, item) catch |err| {
        item.deinit(alloc);
        return err;
    };
}

/// Fills `menu` from `catalog`, in catalog order. A model that Fast mode on
/// another listed model runs gets no row; see `model_catalog.foldsIntoFastMode`.
fn hydrateMenuSnapshot(
    alloc: Allocator,
    menu: *ModelMenu,
    catalog: []const model_catalog.ModelCatalogEntry,
) !void {
    var items: std.ArrayList(ModelMenuItem) = .empty;
    errdefer {
        for (items.items) |item| item.deinit(alloc);
        items.deinit(alloc);
    }
    try items.ensureTotalCapacity(alloc, catalog.len);

    for (catalog) |entry| {
        // Fast mode on the base model's row already selects this model.
        if (model_catalog.foldsIntoFastMode(entry, catalog)) continue;
        try appendMenuItem(alloc, &items, entry);
    }

    // A revalidated catalog replaces rows under an open menu; keep the
    // provider tab and the selected model so the cursor does not jump.
    const previous_ready = menu.load_state == .ready;
    const filter = if (previous_ready and modelProviderFilterAvailable(items.items, menu.providerFilter()))
        menu.providerFilter()
    else
        .all;
    const selected_index = if (!previous_ready) 0 else selected: {
        const previous = menu.itemAt(menu.selected_index) orelse break :selected 0;
        if (modelMenuDisplayIndex(items.items, filter, menu.query(), previous.id)) |index| break :selected index;
        const match_count = modelMenuFilteredItemCount(items.items, filter, menu.query());
        break :selected @min(menu.selected_index, match_count -| 1);
    };
    // Shift the window with the selection so its row stays put on screen.
    const window_start = if (previous_ready)
        (menu.window_start + selected_index) -| menu.selected_index
    else
        0;

    menu.clearSnapshot(alloc);
    menu.items = items;
    menu.load_state = .ready;
    menu.provider_index = @backingInt(filter);
    menu.selected_index = selected_index;
    menu.window_start = window_start;
}

fn modelProvider(model: []const u8) []const u8 {
    const slash = std.mem.findScalar(u8, model, '/') orelse return "";
    if (slash == 0) return "";
    return model[0..slash];
}

fn findCatalogModel(catalog: []const model_catalog.ModelCatalogEntry, model: []const u8) ?*const model_catalog.ModelCatalogEntry {
    for (catalog) |*entry| {
        if (std.mem.eql(u8, entry.id, model)) return entry;
    }
    return null;
}

fn waitForFetchToSettle(runtime: *Runtime) !void {
    var remaining_ms: u64 = 5000;
    while (fetchInFlight(runtime) and remaining_ms > 0) : (remaining_ms -= 1) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(!fetchInFlight(runtime));
}

/// Waits for the running fetch, then crosses the publication boundary the UI
/// tick crosses, so a staged revalidation lands too.
fn waitForWarmup(runtime: *Runtime) !void {
    try waitForFetchToSettle(runtime);
    _ = try runtime.pollLoadTransition();
    try std.testing.expect(!runtime.isLoading());
    try std.testing.expect(!runtime.isFailed());
}

fn fetchInFlight(runtime: *Runtime) bool {
    runtime.mutex.lockUncancelable(io_mod.getIo());
    defer runtime.mutex.unlock(io_mod.getIo());
    return runtime.fetch_in_flight;
}

fn modelIdListContains(ids: []const []u8, needle: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, needle)) return true;
    }
    return false;
}

fn testCatalog(alloc: Allocator, model_id: []const u8) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    const id = try alloc.dupe(u8, model_id);
    errdefer alloc.free(id);
    const model_type = try alloc.dupe(u8, "language");
    errdefer alloc.free(model_type);
    try entries.append(alloc, .{ .id = id, .model_type = model_type });
    return entries;
}

const RefreshCatalog = struct {
    first_failure: ?model_catalog.Failure = null,
    fallback_model: ?[]const u8 = null,
    calls: usize = 0,

    fn fetch(raw: ?*anyopaque, alloc: Allocator, _: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
        const self: *RefreshCatalog = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls == 1) {
            if (self.first_failure) |failure| return .{ .failure = failure };
        }
        if (self.fallback_model) |model| return .{ .catalog = try testCatalog(alloc, model) };
        return .{ .catalog = .empty };
    }

    fn provider(self: *RefreshCatalog) model_catalog.Provider {
        return .{ .context = self, .fetch_fn = fetch };
    }
};

const AuthChangeCatalog = struct {
    model_id: []const u8 = "",
    calls: usize = 0,

    fn fetch(raw: ?*anyopaque, alloc: Allocator, _: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
        const self: *AuthChangeCatalog = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        return .{ .catalog = try testCatalog(alloc, self.model_id) };
    }

    fn provider(self: *AuthChangeCatalog) model_catalog.Provider {
        return .{ .context = self, .fetch_fn = fetch };
    }
};

const StaleCatalog = struct {
    started: std.atomic.Value(bool) = .init(false),
    observed_cancel: std.atomic.Value(bool) = .init(false),

    fn fetch(raw: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
        const self: *StaleCatalog = @ptrCast(@alignCast(raw.?));
        const cancel_flag = input.cancel_flag orelse return .{ .failure = .{ .category = .runtime } };
        self.started.store(true, .seq_cst);
        while (!cancel_flag.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
        self.observed_cancel.store(true, .seq_cst);
        return .{ .catalog = try testCatalog(alloc, "public/stale") };
    }

    fn provider(self: *StaleCatalog) model_catalog.Provider {
        return .{ .context = self, .fetch_fn = fetch };
    }
};

test "model cache expires successful catalogs only when the provider requests refresh" {
    for ([_]bool{ false, true }) |expires| {
        var runtime = Runtime.init(std.testing.allocator);
        defer runtime.deinit();
        var source = AuthChangeCatalog{ .model_id = "first" };
        var provider = source.provider();
        provider.refresh_interval_ms = if (expires) 60_000 else null;
        runtime.loadCooperative(provider, .public_only);
        source.model_id = "new-release";
        runtime.loadCooperative(provider, .public_only);
        try std.testing.expectEqual(@as(usize, 1), source.calls);
        runtime.last_attempt_ms -= 60_000;
        runtime.loadCooperative(provider, .public_only);
        try std.testing.expectEqual(@as(usize, if (expires) 2 else 1), source.calls);
        // The refreshed catalog lands at the owner's publication boundary.
        try std.testing.expectEqualStrings("first", runtime.catalog.items[0].id);
        _ = try runtime.pollLoadTransition();
        try std.testing.expectEqualStrings(if (expires) "new-release" else "first", runtime.catalog.items[0].id);
    }
}

fn testCatalogIds(alloc: Allocator, ids: []const []const u8) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    for (ids) |model_id| {
        var one = try testCatalog(alloc, model_id);
        defer one.deinit(alloc);
        entries.append(alloc, one.items[0]) catch |err| {
            model_catalog.freeModelCatalogEntry(alloc, one.items[0]);
            return err;
        };
    }
    return entries;
}

/// Holds each fetch until released so a test can observe a revalidation in flight.
const GatedCatalog = struct {
    model_id: []const u8 = "first",
    fail: bool = false,
    refresh_interval_ms: ?i64 = 60_000,
    calls: std.atomic.Value(usize) = .init(0),
    open: std.atomic.Value(bool) = .init(true),

    fn fetch(raw: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
        const self: *GatedCatalog = @ptrCast(@alignCast(raw.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        while (!self.open.load(.seq_cst)) {
            if (input.cancel_flag) |flag| {
                if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
            }
            io_mod.sleep(std.time.ns_per_ms);
        }
        if (self.fail) return .{ .failure = .{
            .category = .gateway_unavailable,
            .http_status = .service_unavailable,
            .retryable = true,
        } };
        return .{ .catalog = try testCatalog(alloc, self.model_id) };
    }

    fn provider(self: *GatedCatalog) model_catalog.Provider {
        return .{ .context = self, .fetch_fn = fetch, .refresh_interval_ms = self.refresh_interval_ms };
    }
};
