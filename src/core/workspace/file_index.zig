//! Background workspace file index for the @-mention picker.
//!
//! Each generation owns immutable parallel buffers. The loader publishes complete
//! prefixes with release stores; readers acquire `ready_count` before scanning.
//! Replacement generations remain private until the main thread adopts them.
//! Search uses pre-lowercased paths and a per-path ASCII bitmap to reject
//! impossible subsequence matches before scoring. Each remaining path is
//! ranked by its best query placement (`alignBest`), and highlights show that
//! same placement.

const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const file_picker_path = @import("../input/file_picker_path.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const display_width = @import("../shared/display_width.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const unicode_simple_fold = @import("unicode_simple_fold.zig");
const pathing = @import("pathing.zig");
const workspace_access = @import("workspace_access.zig");
const indexer = @import("../indexer/indexer.zig");

const Allocator = std.mem.Allocator;

pub const max_indexed_files: usize = 100_000;
pub const max_path_len: u32 = 2048;

const sha256_digest_len = std.crypto.hash.sha2.Sha256.digest_length;

fn rootsDigest(roots: []const []const u8) [sha256_digest_len]u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    for (roots) |root| {
        digest.update(root);
        digest.update(&.{0});
    }
    var sum: [sha256_digest_len]u8 = undefined;
    digest.final(&sum);
    return sum;
}

pub const CandidateKind = enum(u8) {
    file,
    directory,
};

pub const Candidate = struct {
    path: []const u8,
    kind: CandidateKind,
};

pub const MatchSpan = struct {
    byte_start: u16,
    byte_end: u16,
};

pub const SearchResult = struct {
    path: []const u8,
    kind: CandidateKind,
    matched_spans: []const MatchSpan,
};

pub const SearchError = error{ NoSpaceLeft, InvalidIndexData };

pub const State = enum(u8) {
    idle = 0,
    loading = 1,
    ready = 2,
    failed = 3,
};

const GenerationState = enum(u8) {
    loading,
    ready,
    failed,
    canceled,
};

const LoaderFailureStage = enum {
    discovery,
    storage,
};

const LoaderFailure = struct {
    stage: LoaderFailureStage,
    err: anyerror,
};

const LoaderOutcome = union(enum) {
    ready,
    failed: LoaderFailure,
    canceled,

    fn terminalState(self: LoaderOutcome) GenerationState {
        return switch (self) {
            .ready => .ready,
            .failed => .failed,
            .canceled => .canceled,
        };
    }
};

/// Value-only identity of one readable prefix; it grants no borrowed lifetime.
pub const ReadableRevision = struct {
    scope_epoch: u64 = 0,
    generation: usize = 0,
    count: usize = 0,
    state: State = .idle,
};

const Generation = struct {
    id: usize,
    scope_epoch: u64 = 0,
    /// Cache-sourced generations publish fast from the persisted index and
    /// always trigger one real scan behind them.
    from_cache: bool = false,
    paths_buf: []u8 = &.{},
    lower_buf: []u8 = &.{},
    offsets: []u32 = &.{},
    basename_starts: []u32 = &.{},
    kinds: []CandidateKind = &.{},
    /// One `u32` per path; bit `n` is set iff the lower-cased path contains
    /// the letter `'a' + n`. Used as an O(1) reject: a query mask can only
    /// match if `(path_mask & query_mask) == query_mask`, since every letter
    /// in the query must appear somewhere in the path for a subsequence match.
    char_masks: []u32 = &.{},
    /// The loader publishes an immutable prefix with release stores after
    /// every parallel-buffer entry is complete. Search pairs this with an
    /// acquire load before reading that prefix.
    ready_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// A release store publishes the terminal outcome after all generation
    /// writes. The main thread performs an acquire load before deciding
    /// whether joining and adoption are permitted.
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@backingInt(GenerationState.loading)),

    fn create(alloc: Allocator, id: usize) !*Generation {
        const generation = try alloc.create(Generation);
        generation.* = .{ .id = id };
        return generation;
    }

    fn destroy(self: *Generation, alloc: Allocator) void {
        self.freeBuffers(alloc);
        alloc.destroy(self);
    }

    fn currentState(self: *const Generation) GenerationState {
        return @fromBackingInt(@intCast(self.state.load(.acquire)));
    }

    fn finish(self: *Generation, state: GenerationState) void {
        self.state.store(@backingInt(state), .release);
    }

    fn count(self: *const Generation) usize {
        return self.ready_count.load(.acquire);
    }

    fn pathAt(self: *const Generation, index: usize) []const u8 {
        const start = self.offsets[index];
        const end = self.offsets[index + 1];
        return self.paths_buf[start..end];
    }

    fn kindAt(self: *const Generation, index: usize) CandidateKind {
        return self.kinds[index];
    }

    fn lowerPathAt(self: *const Generation, index: u32) []const u8 {
        const start = self.offsets[index];
        const end = self.offsets[index + 1];
        return self.lower_buf[start..end];
    }

    /// Allocates this generation's complete storage before publishing any
    /// entry. Cancellation retains the published prefix until the main thread
    /// discards the generation after its loader reaches a terminal state.
    fn fillProgressive(
        self: *Generation,
        alloc: Allocator,
        source: CandidateSource,
        stop_requested: ?*std.atomic.Value(bool),
    ) !void {
        if (isStopRequested(stop_requested)) return error.Canceled;

        const totals = countAndSize(source);

        try self.allocateBuffers(alloc, totals);
        if (totals.n == 0) return;

        self.offsets[0] = 0;

        var iterator = source.iterator();
        var candidate_index: u32 = 0;
        var buffer_position: u32 = 0;
        while (iterator.next()) |candidate| {
            if (isStopRequested(stop_requested)) return error.Canceled;
            if (candidate_index >= totals.n) break;
            const accepted = acceptedCandidate(candidate) orelse continue;
            const path = accepted.path;

            const start = buffer_position;
            const len: u32 = @intCast(path.len);
            @memcpy(self.paths_buf[start .. start + len], path);

            var mask: u32 = 0;
            var contains_non_ascii = false;
            for (path, 0..) |byte, byte_index| {
                const lower = asciiToLower(byte);
                self.lower_buf[start + @as(u32, @intCast(byte_index))] = lower;
                if (byte >= 0x80) contains_non_ascii = true;
                if (lower >= 'a' and lower <= 'z') {
                    mask |= @as(u32, 1) << @intCast(lower - 'a');
                }
            }

            const slash = std.mem.findScalarLast(u8, path, '/');
            self.basename_starts[candidate_index] = if (slash) |index|
                start + @as(u32, @intCast(index + 1))
            else
                start;
            if (contains_non_ascii) mask |= non_ascii_mask;
            self.char_masks[candidate_index] = mask;
            self.kinds[candidate_index] = accepted.kind;
            buffer_position += len;
            self.offsets[candidate_index + 1] = buffer_position;

            self.ready_count.store(candidate_index + 1, .release);
            candidate_index += 1;
        }

        if (isStopRequested(stop_requested)) return error.Canceled;
    }

    /// Transfers complete parallel-buffer ownership only after every
    /// allocation succeeds. Later population failure leaves cleanup with the
    /// generation rather than the allocation errdefers in this scope.
    fn allocateBuffers(self: *Generation, alloc: Allocator, totals: RawTotals) !void {
        const paths_buf = try alloc.alloc(u8, totals.bytes);
        errdefer alloc.free(paths_buf);
        const lower_buf = try alloc.alloc(u8, totals.bytes);
        errdefer alloc.free(lower_buf);
        const offsets = try alloc.alloc(u32, totals.n + 1);
        errdefer alloc.free(offsets);
        const basename_starts = try alloc.alloc(u32, totals.n);
        errdefer alloc.free(basename_starts);
        const char_masks = try alloc.alloc(u32, totals.n);
        errdefer alloc.free(char_masks);
        const kinds = try alloc.alloc(CandidateKind, totals.n);
        errdefer alloc.free(kinds);

        self.paths_buf = paths_buf;
        self.lower_buf = lower_buf;
        self.offsets = offsets;
        self.basename_starts = basename_starts;
        self.char_masks = char_masks;
        self.kinds = kinds;
    }

    fn freeBuffers(self: *Generation, alloc: Allocator) void {
        if (self.paths_buf.len > 0) alloc.free(self.paths_buf);
        if (self.lower_buf.len > 0) alloc.free(self.lower_buf);
        if (self.offsets.len > 0) alloc.free(self.offsets);
        if (self.basename_starts.len > 0) alloc.free(self.basename_starts);
        if (self.char_masks.len > 0) alloc.free(self.char_masks);
        if (self.kinds.len > 0) alloc.free(self.kinds);
        self.paths_buf = &.{};
        self.lower_buf = &.{};
        self.offsets = &.{};
        self.basename_starts = &.{};
        self.char_masks = &.{};
        self.kinds = &.{};
        self.ready_count.store(0, .release);
    }
};

pub const FileIndex = struct {
    const PendingScope = struct { roots: [][]u8, epoch: u64 };

    /// The main thread is the sole owner allowed to replace or reclaim these
    /// generation pointers. The loader writes only `loading_generation`.
    active_generation: ?*Generation = null,
    loading_generation: ?*Generation = null,
    /// Owned roots for the current generation. The primary root is first;
    /// active additional roots follow in configured order.
    roots: [][]u8 = &.{},
    scope_epoch: u64 = 0,
    /// Roots and their installed-scope identity transfer together.
    pending_scope: ?PendingScope = null,

    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    generation: usize = 0,
    initial_failed: bool = false,
    /// Digest of the roots whose persisted cache this process already consumed.
    /// A scope switch to different roots may load its own cache.
    cache_attempted_digest: ?[sha256_digest_len]u8 = null,

    pub fn requestStop(self: *FileIndex) void {
        self.stop_requested.store(true, .seq_cst);
        debug_trace.logf("core", "file index shutdown requested generation={d} loader={s} active={} loading={} queued={}", .{
            self.generation,
            if (self.thread == null) "none" else "owned",
            self.active_generation != null,
            self.loading_generation != null,
            self.pending_scope != null,
        });
    }

    pub fn deinit(self: *FileIndex, alloc: Allocator) void {
        self.requestStop();
        if (self.thread) |handle| {
            handle.join();
            self.thread = null;
            debug_trace.logf("core", "file index shutdown joined generation={d}", .{self.generation});
        }
        if (self.loading_generation) |generation| {
            debug_trace.logf("core", "file index generation discarded generation={d} state={s}", .{ generation.id, @tagName(generation.currentState()) });
            generation.destroy(alloc);
        }
        self.loading_generation = null;
        if (self.active_generation) |generation| {
            debug_trace.logf("core", "file index shutdown reclaiming generation={d}", .{generation.id});
            generation.destroy(alloc);
        }
        self.active_generation = null;
        freeRoots(alloc, self.roots);
        self.roots = &.{};
        if (self.pending_scope) |pending| freeRoots(alloc, pending.roots);
        self.pending_scope = null;
        debug_trace.logf("core", "file index shutdown complete generation={d}", .{self.generation});
    }

    pub fn currentState(self: *const FileIndex) State {
        if (self.active_generation != null) return .ready;
        const loading = self.loading_generation orelse return if (self.initial_failed) .failed else .idle;
        return switch (loading.currentState()) {
            .loading => .loading,
            .ready => .ready,
            .failed, .canceled => .failed,
        };
    }

    /// Number of path entries currently searchable. During load this grows
    /// as the loader thread publishes more entries; once the build finishes
    /// it holds steady at the final count.
    pub fn count(self: *const FileIndex) usize {
        const generation = self.searchableGeneration() orelse return 0;
        return generation.count();
    }

    /// Kick off one background generation from an immutable access scope.
    pub fn ensureScope(self: *FileIndex, alloc: Allocator, scope: workspace_access.AccessScope) void {
        self.ensureScopeEpoch(alloc, scope, 0);
    }

    pub fn ensureScopeEpoch(self: *FileIndex, alloc: Allocator, scope: workspace_access.AccessScope, epoch: u64) void {
        if (self.currentState() != .idle) return;
        if (scope.primary_directory.len == 0) return;

        self.roots = activeRootsAlloc(alloc, scope) catch return;
        self.scope_epoch = epoch;
        _ = self.startLoad(alloc);
    }

    fn startLoad(self: *FileIndex, alloc: Allocator) bool {
        if (self.roots.len == 0 or
            self.thread != null or
            self.loading_generation != null or
            self.stop_requested.load(.seq_cst)) return false;

        // The persisted cache is consumed at most once per scope: the first
        // generation paints from disk, then a real scan replaces it.
        const roots_digest = rootsDigest(self.roots);
        const allow_cache = if (self.cache_attempted_digest) |attempted|
            !std.mem.eql(u8, &attempted, &roots_digest)
        else
            true;
        if (allow_cache) self.cache_attempted_digest = roots_digest;

        const generation_id = self.generation + 1;
        const loading = Generation.create(alloc, generation_id) catch |err| {
            if (self.active_generation == null) self.initial_failed = true;
            debug_trace.logf("core", "file index generation allocation failed generation={d} err={s}", .{ generation_id, @errorName(err) });
            return false;
        };
        loading.scope_epoch = self.scope_epoch;
        self.loading_generation = loading;
        self.generation = generation_id;
        self.initial_failed = false;
        self.thread = std.Thread.spawn(.{}, loaderThreadMain, .{
            loading,
            alloc,
            self.roots,
            &self.stop_requested,
            allow_cache,
        }) catch |err| {
            self.loading_generation = null;
            loading.destroy(alloc);
            if (self.active_generation == null) self.initial_failed = true;
            debug_trace.logf("core", "file index generation spawn failed generation={d} err={s}", .{ generation_id, @errorName(err) });
            return false;
        };
        debug_trace.logf("core", "file index generation started generation={d} caller_thread={d} from_cache={}", .{ generation_id, std.Thread.getCurrentId(), allow_cache });
        return true;
    }

    /// Reaps one terminal loader without waiting for incomplete work. Returns
    /// whether candidate or initial-status facts changed and need rendering.
    pub fn joinThreadIfDone(self: *FileIndex, alloc: Allocator) bool {
        const handle = self.thread orelse return false;
        const loading = self.loading_generation orelse return false;
        const terminal_state = loading.currentState();
        if (terminal_state == .loading) return false;

        handle.join();
        self.thread = null;
        debug_trace.logf("core", "file index generation joined generation={d} state={s}", .{ loading.id, @tagName(terminal_state) });

        var visible_changed = false;
        const adopted_from_cache = terminal_state == .ready and loading.from_cache;
        switch (terminal_state) {
            .loading => unreachable,
            .ready => {
                const previous = self.active_generation;
                self.active_generation = loading;
                self.loading_generation = null;
                self.initial_failed = false;
                debug_trace.logf("core", "file index generation adopted generation={d} count={d} from_cache={}", .{ loading.id, loading.count(), loading.from_cache });
                if (previous) |generation| generation.destroy(alloc);
                visible_changed = true;
            },
            .failed, .canceled => {
                self.loading_generation = null;
                if (self.active_generation == null and terminal_state == .failed) {
                    self.initial_failed = true;
                    visible_changed = true;
                }
                debug_trace.logf("core", "file index generation discarded generation={d} state={s}", .{ loading.id, @tagName(terminal_state) });
                loading.destroy(alloc);
            },
        }

        if (!self.stop_requested.load(.seq_cst)) {
            if (self.pending_scope) |pending| {
                self.pending_scope = null;
                freeRoots(alloc, self.roots);
                self.roots = pending.roots;
                self.scope_epoch = pending.epoch;
                _ = self.startLoad(alloc);
            }
        }
        // A cache-painted generation is a preview only: one real scan follows
        // it and replaces it, unless a pending scope already started that load.
        if (adopted_from_cache and
            !self.stop_requested.load(.seq_cst) and
            self.thread == null)
        {
            _ = self.startLoad(alloc);
        }
        return visible_changed;
    }

    /// Requests one replacement generation. A current loader retains its
    /// immutable scope and coalesces only the latest owned replacement scope.
    pub fn refresh(self: *FileIndex, alloc: Allocator) void {
        const epoch = if (self.pending_scope) |pending| pending.epoch else self.scope_epoch;
        const roots = cloneRoots(alloc, if (self.pending_scope) |pending| pending.roots else self.roots) catch |err| {
            debug_trace.logf("core", "file index refresh snapshot failed generation={d} err={s}", .{ self.generation, @errorName(err) });
            return;
        };
        self.refreshOwnedRoots(alloc, roots, epoch);
    }

    /// Refreshes from the latest active scope. A loading generation keeps its
    /// immutable roots and receives one owned, coalesced replacement snapshot.
    pub fn refreshScope(self: *FileIndex, alloc: Allocator, scope: workspace_access.AccessScope) void {
        self.refreshScopeEpoch(alloc, scope, 0);
    }

    pub fn refreshScopeEpoch(self: *FileIndex, alloc: Allocator, scope: workspace_access.AccessScope, epoch: u64) void {
        const roots = activeRootsAlloc(alloc, scope) catch |err| {
            debug_trace.logf("core", "file index scope snapshot failed generation={d} err={s}", .{ self.generation, @errorName(err) });
            return;
        };
        self.refreshOwnedRoots(alloc, roots, epoch);
    }

    fn refreshOwnedRoots(self: *FileIndex, alloc: Allocator, roots: [][]u8, epoch: u64) void {
        if (self.stop_requested.load(.seq_cst)) {
            freeRoots(alloc, roots);
            debug_trace.logf("core", "file index refresh discarded during shutdown generation={d}", .{self.generation});
            return;
        }
        if (self.thread != null) {
            self.replacePendingRoots(alloc, roots, epoch);
            return;
        }

        if (self.loading_generation != null) {
            freeRoots(alloc, roots);
            debug_trace.logf("core", "file index refresh discarded with unowned loading generation={d}", .{self.generation});
            return;
        }
        freeRoots(alloc, self.roots);
        self.roots = roots;
        self.scope_epoch = epoch;
        const started = self.startLoad(alloc);
        if (!started) debug_trace.logf("core", "file index refresh not started generation={d}", .{self.generation});
    }

    fn replacePendingRoots(self: *FileIndex, alloc: Allocator, roots: [][]u8, epoch: u64) void {
        if (self.pending_scope) |pending| {
            if (pending.epoch == epoch and rootsEqual(pending.roots, roots)) {
                freeRoots(alloc, roots);
                debug_trace.logf("core", "file index refresh coalesced generation={d} identical=true", .{self.generation});
                return;
            }
            freeRoots(alloc, pending.roots);
            debug_trace.logf("core", "file index pending refresh superseded generation={d}", .{self.generation});
        }
        self.pending_scope = .{ .roots = roots, .epoch = epoch };
        debug_trace.logf("core", "file index refresh coalesced generation={d} identical=false", .{self.generation});
    }

    pub fn isCurrentCandidateKind(self: *const FileIndex, path: []const u8, expected_kind: CandidateKind) bool {
        const current_roots = if (self.pending_scope) |pending| pending.roots else self.roots;
        if (!text_utils.isTerminalSafe(path) or current_roots.len == 0) return false;
        const root_path, const relative = if (std.Io.Dir.path.isAbsolute(path)) resolved: {
            for (current_roots) |root| {
                if (!pathing.pathInside(root, path)) continue;
                const rel = pathing.workspaceRelativePath(std.heap.c_allocator, root, path) catch return false;
                break :resolved .{ root, rel };
            }
            return false;
        } else .{ current_roots[0], path };
        defer if (std.Io.Dir.path.isAbsolute(path)) std.heap.c_allocator.free(relative);
        var root = std.Io.Dir.openDirAbsolute(io_mod.getIo(), root_path, .{}) catch return false;
        defer root.close(io_mod.getIo());
        const stat = root.statFile(io_mod.getIo(), relative, .{ .follow_symlinks = false }) catch return false;
        return candidateKindMatchesStat(expected_kind, stat.kind);
    }

    /// Builds a ready index synchronously from NUL- or newline-delimited paths.
    pub fn buildFromRaw(self: *FileIndex, alloc: Allocator, raw_list: []const u8) !void {
        try self.buildFromSource(alloc, .{ .file_raw = raw_list });
    }

    /// Build synchronously from typed candidates. Candidate paths are
    /// borrowed for this call and copied into the index. Repeated path-kind
    /// identities are retained once in their first input position.
    pub fn buildFromCandidates(self: *FileIndex, alloc: Allocator, candidates: []const Candidate) !void {
        const indices = try candidateIndicesAlloc(alloc, candidates);
        defer if (indices.len > 0) alloc.free(indices);
        try self.buildFromSource(alloc, .{ .typed = .{
            .candidates = candidates,
            .indices = indices,
        } });
    }

    /// Writes typed, ranked results into caller-owned output. Path bytes
    /// borrow this index generation; result records and `matched_spans` borrow
    /// the caller's buffers. Callers must disregard output after an error.
    pub fn searchTyped(
        self: *const FileIndex,
        query: []const u8,
        out: []SearchResult,
        match_spans: []MatchSpan,
    ) SearchError!usize {
        return self.searchAtRevision(self.readableRevision(), query, out, match_spans);
    }

    pub fn readableRevision(self: *const FileIndex) ReadableRevision {
        const generation = self.searchableGeneration() orelse return .{
            .scope_epoch = self.scope_epoch,
            .state = self.currentState(),
        };
        return .{
            .scope_epoch = generation.scope_epoch,
            .generation = generation.id,
            .count = generation.count(),
            .state = self.currentState(),
        };
    }

    /// Main-thread-only search of the captured prefix. Results retain the same
    /// borrowing contract as searchTyped; this revision is not a generation lease.
    pub fn searchAtRevision(
        self: *const FileIndex,
        revision: ReadableRevision,
        query: []const u8,
        out: []SearchResult,
        match_spans: []MatchSpan,
    ) SearchError!usize {
        if (out.len == 0 or revision.count == 0) return 0;
        const generation = self.searchableGeneration() orelse return error.InvalidIndexData;
        if (generation.id != revision.generation or generation.scope_epoch != revision.scope_epoch or
            revision.count > generation.kinds.len) return error.InvalidIndexData;
        const total = revision.count;
        if (query.len > max_path_len) return 0;

        if (query.len == 0) {
            const result_count = @min(total, out.len);
            for (out[0..result_count], 0..) |*result, index| {
                result.* = .{
                    .path = generation.pathAt(index),
                    .kind = generation.kindAt(index),
                    .matched_spans = match_spans[0..0],
                };
            }
            return result_count;
        }

        var query_scratch: QueryScratch = undefined;
        const prepared = prepareQuery(query, &query_scratch) orelse return 0;
        var indices: [max_search_results]u32 = undefined;
        var align_scratch: AlignScratch = undefined;
        const result_count = rankTopN(generation, total, prepared, indices[0..@min(out.len, max_search_results)], &align_scratch);

        var path_scratch: FoldedPathScratch = undefined;
        var matched_offsets: [max_path_len]u16 = undefined;
        var span_scratch: [max_path_len]MatchSpan = undefined;
        var spans_used: usize = 0;
        for (indices[0..result_count], 0..) |index, result_index| {
            const path = generation.pathAt(index);
            const base_start = generation.basename_starts[index] - generation.offsets[index];
            const span_count = reconstructMatchSpans(
                path,
                base_start,
                prepared.folded,
                &path_scratch,
                &align_scratch,
                &matched_offsets,
                &span_scratch,
            ) orelse return error.InvalidIndexData;
            if (span_count > match_spans.len -| spans_used) return error.NoSpaceLeft;
            @memcpy(match_spans[spans_used..][0..span_count], span_scratch[0..span_count]);
            out[result_index] = .{
                .path = path,
                .kind = generation.kindAt(index),
                .matched_spans = match_spans[spans_used..][0..span_count],
            };
            spans_used += span_count;
        }
        return result_count;
    }

    fn searchableGeneration(self: *const FileIndex) ?*const Generation {
        if (self.active_generation) |active| return active;
        const loading = self.loading_generation orelse return null;
        return switch (loading.currentState()) {
            .loading, .ready => loading,
            .failed, .canceled => null,
        };
    }

    fn pathAt(self: *const FileIndex, i: usize) []const u8 {
        return self.searchableGeneration().?.pathAt(i);
    }

    fn kindAt(self: *const FileIndex, i: usize) CandidateKind {
        return self.searchableGeneration().?.kindAt(i);
    }

    fn lowerPathAt(self: *const FileIndex, i: u32) []const u8 {
        return self.searchableGeneration().?.lowerPathAt(i);
    }

    fn buildFromSource(self: *FileIndex, alloc: Allocator, source: CandidateSource) !void {
        if (self.thread != null or self.loading_generation != null) return error.LoadInProgress;
        const generation_id = self.generation + 1;
        const generation = try Generation.create(alloc, generation_id);
        errdefer generation.destroy(alloc);
        try generation.fillProgressive(alloc, source, null);
        generation.finish(.ready);

        const previous = self.active_generation;
        self.active_generation = generation;
        self.generation = generation_id;
        self.initial_failed = false;
        if (previous) |active| active.destroy(alloc);
    }
};

const TypedCandidateSource = struct {
    candidates: []const Candidate,
    indices: ?[]const usize,
};

const CandidateSource = union(enum) {
    file_raw: []const u8,
    typed: TypedCandidateSource,

    fn iterator(self: CandidateSource) CandidateIterator {
        return switch (self) {
            .file_raw => |raw_list| .{ .file_raw = .{
                .separator = rawPathSeparator(raw_list),
                .iterator = std.mem.splitScalar(u8, raw_list, rawPathSeparator(raw_list)),
            } },
            .typed => |typed| .{ .typed = .{
                .candidates = typed.candidates,
                .indices = typed.indices,
            } },
        };
    }
};

const RawFileCandidateIterator = struct {
    separator: u8,
    iterator: std.mem.SplitIterator(u8, .scalar),

    fn next(self: *RawFileCandidateIterator) ?Candidate {
        while (self.iterator.next()) |raw| {
            const path = acceptedRawPath(self.separator, raw) orelse continue;
            return .{ .path = path, .kind = .file };
        }
        return null;
    }
};

const TypedCandidateIterator = struct {
    candidates: []const Candidate,
    indices: ?[]const usize,
    position: usize = 0,

    fn next(self: *TypedCandidateIterator) ?Candidate {
        const candidate_index = if (self.indices) |indices| index: {
            if (self.position >= indices.len) return null;
            break :index indices[self.position];
        } else index: {
            if (self.position >= self.candidates.len) return null;
            break :index self.position;
        };
        const candidate = self.candidates[candidate_index];
        self.position += 1;
        return candidate;
    }
};

const CandidateIterator = union(enum) {
    file_raw: RawFileCandidateIterator,
    typed: TypedCandidateIterator,

    fn next(self: *CandidateIterator) ?Candidate {
        return switch (self.*) {
            .file_raw => |*iterator| iterator.next(),
            .typed => |*iterator| iterator.next(),
        };
    }
};

fn candidateIndicesAlloc(alloc: Allocator, candidates: []const Candidate) ![]usize {
    var indices: std.ArrayList(usize) = .empty;
    errdefer indices.deinit(alloc);
    var seen: std.StringHashMapUnmanaged(u2) = .empty;
    defer seen.deinit(alloc);

    for (candidates, 0..) |candidate, index| {
        if (acceptedCandidate(candidate) == null) continue;
        if (indices.items.len >= max_indexed_files) break;

        const kind_mask: u2 = switch (candidate.kind) {
            .file => 0b01,
            .directory => 0b10,
        };
        const entry = try seen.getOrPut(alloc, candidate.path);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        if ((entry.value_ptr.* & kind_mask) != 0) continue;
        entry.value_ptr.* |= kind_mask;
        try indices.append(alloc, index);
    }

    return indices.toOwnedSlice(alloc);
}

fn candidateKindMatchesStat(expected: CandidateKind, actual: std.Io.File.Kind) bool {
    return switch (expected) {
        .file => actual == .file or actual == .sym_link,
        .directory => actual == .directory,
    };
}

fn loaderThreadMain(
    generation: *Generation,
    alloc: Allocator,
    roots: []const []const u8,
    stop_requested: *std.atomic.Value(bool),
    allow_cache: bool,
) void {
    debug_trace.logf("core", "file index loader entered generation={d} worker_thread={d}", .{ generation.id, std.Thread.getCurrentId() });
    const outcome = loadGeneration(generation, alloc, roots, stop_requested, allow_cache);
    publishLoaderOutcomeAfterCleanup(generation, outcome);
}

fn loadGeneration(
    generation: *Generation,
    alloc: Allocator,
    roots: []const []const u8,
    stop_requested: *std.atomic.Value(bool),
    allow_cache: bool,
) LoaderOutcome {
    if (isStopRequested(stop_requested)) return .canceled;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const snapshot_path = snapshotPath(arena, roots) catch |err| return .{ .failed = .{ .stage = .discovery, .err = err } };
    var previous = if (snapshot_path) |path|
        indexer.loadSnapshot(alloc, path, roots) catch |err| return .{ .failed = .{ .stage = .discovery, .err = err } }
    else
        null;
    defer if (previous) |*snapshot| snapshot.deinit();

    if (allow_cache) {
        if (previous) |*snapshot| {
            const candidates = candidatesFromTrees(arena, roots, snapshot.trees, stop_requested) catch |err| {
                if (err == error.Canceled or isStopRequested(stop_requested)) return .canceled;
                return .{ .failed = .{ .stage = .discovery, .err = err } };
            };
            generation.from_cache = true;
            generation.fillProgressive(alloc, .{ .typed = .{
                .candidates = candidates,
                .indices = null,
            } }, stop_requested) catch |err| {
                if (err == error.Canceled or isStopRequested(stop_requested)) return .canceled;
                return .{ .failed = .{ .stage = .storage, .err = err } };
            };
            if (isStopRequested(stop_requested)) return .canceled;
            debug_trace.logf("core", "file index cache painted generation={d} count={d}", .{ generation.id, generation.count() });
            return .ready;
        }
    }

    var refreshed = refreshTrees(alloc, roots, if (previous) |*snapshot| snapshot.trees else &.{}, stop_requested) catch |err| {
        if (err == error.Canceled or isStopRequested(stop_requested)) return .canceled;
        return .{ .failed = .{ .stage = .discovery, .err = err } };
    };
    defer refreshed.deinit(alloc);

    // Persist before the fill so even a canceled publish leaves a warm
    // snapshot. A scope with an unavailable root is not saved, so its next
    // load scans again.
    if (snapshot_path) |path| {
        if (refreshed.scans.len > 0 and refreshed.trees.len == roots.len) {
            indexer.saveSnapshot(arena, path, refreshed.trees) catch |err| {
                debug_trace.logf("core", "file index cache not saved generation={d} err={s}", .{ generation.id, @errorName(err) });
            };
        }
    }

    const candidates = candidatesFromTrees(arena, roots, refreshed.trees, stop_requested) catch |err| {
        if (err == error.Canceled or isStopRequested(stop_requested)) return .canceled;
        return .{ .failed = .{ .stage = .discovery, .err = err } };
    };
    generation.fillProgressive(alloc, .{ .typed = .{
        .candidates = candidates,
        .indices = null,
    } }, stop_requested) catch |err| {
        if (err == error.Canceled or isStopRequested(stop_requested)) return .canceled;
        return .{ .failed = .{ .stage = .storage, .err = err } };
    };
    if (isStopRequested(stop_requested)) return .canceled;
    return .ready;
}

/// `<home>/.spark/file-index/<sha256>.idx`, or null without an absolute home
/// directory. The digest covers the roots and every variable that locates git
/// config, so a listing built under one config is never reused under another.
pub fn snapshotPath(alloc: Allocator, roots: []const []const u8) Allocator.Error!?[]const u8 {
    const home = io_mod.homeDir() orelse return null;
    var config_environment: [indexer.config_environment_names.len]?[]const u8 = undefined;
    for (indexer.config_environment_names, &config_environment) |name, *value| value.* = io_mod.getenv(name);
    return try snapshotPathIn(alloc, home, roots, &config_environment);
}

fn snapshotPathIn(
    alloc: Allocator,
    home: []const u8,
    roots: []const []const u8,
    config_environment: []const ?[]const u8,
) Allocator.Error![]const u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update(&rootsDigest(roots));
    for (config_environment) |value| {
        if (value) |bytes| {
            digest.update(&.{1});
            digest.update(bytes);
            digest.update(&.{0});
        } else digest.update(&.{0});
    }
    var sum: [sha256_digest_len]u8 = undefined;
    digest.final(&sum);
    const hex = std.fmt.bytesToHex(sum, .lower);
    return alloc.print("{s}/.spark/file-index/{s}.idx", .{ home, &hex });
}

/// The trees for the available roots of a scope, in root order. Trees reused
/// from a snapshot borrow its memory; `scans` owns the rest.
const RefreshedTrees = struct {
    trees: []indexer.Tree,
    scans: []indexer.ScanResult,

    fn deinit(self: *RefreshedTrees, alloc: Allocator) void {
        for (self.scans) |*result| result.deinit();
        alloc.free(self.scans);
        alloc.free(self.trees);
        self.* = undefined;
    }
};

/// Reuses each saved tree that is still current and scans every other root.
/// `previous` is empty or holds one tree per root in order. An unavailable
/// root is left out; a scope with no available root fails.
fn refreshTrees(
    alloc: Allocator,
    roots: []const []const u8,
    previous: []const indexer.Tree,
    stop_requested: *std.atomic.Value(bool),
) (indexer.ScanError || error{FileNotFound})!RefreshedTrees {
    std.debug.assert(previous.len == 0 or previous.len == roots.len);
    var trees: std.ArrayList(indexer.Tree) = .empty;
    defer trees.deinit(alloc);
    var scans: std.ArrayList(indexer.ScanResult) = .empty;
    defer {
        for (scans.items) |*result| result.deinit();
        scans.deinit(alloc);
    }
    try trees.ensureTotalCapacity(alloc, roots.len);
    try scans.ensureTotalCapacity(alloc, roots.len);

    for (roots, 0..) |root, root_index| {
        if (isStopRequested(stop_requested)) return error.Canceled;
        if (previous.len > 0 and indexer.isCurrent(&previous[root_index], root, &indexer.default_skipped_names, null)) {
            debug_trace.logf("core", "file index root reused root={d} entries={d} thread={d}", .{ root_index, previous[root_index].entries.len, std.Thread.getCurrentId() });
            trees.appendAssumeCapacity(previous[root_index]);
            continue;
        }
        const result = indexer.scan(alloc, root, .{ .candidate_cap = max_indexed_files }, stop_requested) catch |err| switch (err) {
            error.RootUnavailable => {
                debug_trace.logf("core", "file index root discovery omitted root={d} err={s}", .{ root_index, @errorName(err) });
                continue;
            },
            else => |e| return e,
        };
        scans.appendAssumeCapacity(result);
        trees.appendAssumeCapacity(result.tree);
        debug_trace.logf("core", "file index root scanned root={d} entries={d} incomplete={} thread={d}", .{ root_index, result.tree.entries.len, result.tree.incomplete, std.Thread.getCurrentId() });
    }
    if (trees.items.len == 0 and roots.len > 0) return error.FileNotFound;

    const owned_trees = try trees.toOwnedSlice(alloc);
    errdefer alloc.free(owned_trees);
    return .{ .trees = owned_trees, .scans = try scans.toOwnedSlice(alloc) };
}

/// Converts trees into candidates in root order: primary-root paths stay
/// relative, added-root paths become absolute, overlapping roots appear once,
/// and at most `max_indexed_files` are kept. Paths may borrow tree memory.
fn candidatesFromTrees(
    arena: Allocator,
    roots: []const []const u8,
    trees: []const indexer.Tree,
    stop_requested: *std.atomic.Value(bool),
) (Allocator.Error || error{Canceled})![]const Candidate {
    if (trees.len == 1 and roots.len > 0 and std.mem.eql(u8, trees[0].root, roots[0])) {
        return primaryTreeCandidates(arena, &trees[0], stop_requested);
    }
    var candidates: std.ArrayList(Candidate) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (trees) |*tree| {
        const root_index: usize = if (roots.len > 0 and std.mem.eql(u8, tree.root, roots[0])) 0 else 1;
        for (tree.entries) |entry| {
            if (isStopRequested(stop_requested)) return error.Canceled;
            if (candidates.items.len >= max_indexed_files) return candidates.toOwnedSlice(arena);
            if (!isPlainRelativePath(entry.path)) continue;
            if (!text_utils.isTerminalSafe(entry.path)) {
                debug_trace.logf("core", "file index omitted unsafe candidate bytes={d} kind={s}", .{ entry.path.len, @tagName(entry.kind) });
                continue;
            }
            const kind: CandidateKind = switch (entry.kind) {
                .file => .file,
                .directory => .directory,
            };
            _ = try appendDiscoveredCandidate(arena, &candidates, &seen, tree.root, root_index, entry.path, kind);
        }
    }
    return candidates.toOwnedSlice(arena);
}

/// The primary root alone: its entries are unique and already relative, so
/// each one is checked once and kept as is, with no absolute path or
/// overlap check per entry. This runs on every `@` paint.
fn primaryTreeCandidates(
    arena: Allocator,
    tree: *const indexer.Tree,
    stop_requested: *std.atomic.Value(bool),
) (Allocator.Error || error{Canceled})![]const Candidate {
    var candidates: std.ArrayList(Candidate) = .empty;
    try candidates.ensureTotalCapacity(arena, @min(tree.entries.len, max_indexed_files));
    for (tree.entries) |entry| {
        if (isStopRequested(stop_requested)) return error.Canceled;
        if (candidates.items.len >= max_indexed_files) break;
        if (!isPlainRelativePath(entry.path)) continue;
        if (!text_utils.isTerminalSafe(entry.path)) {
            debug_trace.logf("core", "file index omitted unsafe candidate bytes={d} kind={s}", .{ entry.path.len, @tagName(entry.kind) });
            continue;
        }
        const kind: CandidateKind = switch (entry.kind) {
            .file => .file,
            .directory => .directory,
        };
        const accepted = acceptedSafeCandidate(.{ .path = entry.path, .kind = kind }) orelse continue;
        candidates.appendAssumeCapacity(accepted);
    }
    return candidates.toOwnedSlice(arena);
}

/// A relative `/`-separated path that stays inside its root and avoids
/// `.git`: no empty, `.`, `..` or `.git` component.
fn isPlainRelativePath(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".git")) return false;
    }
    return true;
}

/// Publishes the loader's terminal outcome only after its caller has released
/// every worker-owned temporary. The release store is deliberately the final
/// action so an acquire observer may join without waiting for worker cleanup.
fn publishLoaderOutcomeAfterCleanup(generation: *Generation, outcome: LoaderOutcome) void {
    switch (outcome) {
        .ready => debug_trace.logf("core", "file index generation ready generation={d} count={d} worker_cleanup=complete", .{ generation.id, generation.count() }),
        .failed => |failure| debug_trace.logf("core", "file index generation failed generation={d} stage={s} err={s} worker_cleanup=complete", .{ generation.id, @tagName(failure.stage), @errorName(failure.err) }),
        .canceled => debug_trace.logf("core", "file index generation canceled generation={d} worker_cleanup=complete", .{generation.id}),
    }
    generation.finish(outcome.terminalState());
}

fn activeRootsAlloc(alloc: Allocator, scope: workspace_access.AccessScope) ![][]u8 {
    var roots: std.ArrayList([]u8) = .empty;
    errdefer {
        for (roots.items) |root| alloc.free(root);
        roots.deinit(alloc);
    }

    try roots.append(alloc, try alloc.dupe(u8, scope.primary_directory));
    for (scope.additional_directories) |entry| {
        if (!entry.active) continue;
        var duplicate = false;
        for (roots.items) |root| {
            if (std.mem.eql(u8, root, entry.path)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) try roots.append(alloc, try alloc.dupe(u8, entry.path));
    }
    return roots.toOwnedSlice(alloc);
}

fn cloneRoots(alloc: Allocator, source: []const []const u8) ![][]u8 {
    var roots: std.ArrayList([]u8) = .empty;
    errdefer {
        for (roots.items) |root| alloc.free(root);
        roots.deinit(alloc);
    }
    for (source) |root| try roots.append(alloc, try alloc.dupe(u8, root));
    return roots.toOwnedSlice(alloc);
}

fn freeRoots(alloc: Allocator, roots: []const []u8) void {
    for (roots) |root| alloc.free(root);
    if (roots.len > 0) alloc.free(roots);
}

fn rootsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn appendDiscoveredCandidate(
    alloc: Allocator,
    candidates: *std.ArrayList(Candidate),
    seen: *std.StringHashMapUnmanaged(void),
    root_path: []const u8,
    root_index: usize,
    relative: []const u8,
    kind: CandidateKind,
) !bool {
    const absolute = try std.Io.Dir.path.resolveAlloc(alloc, &.{ root_path, relative });
    if (!pathing.pathInside(root_path, absolute)) return false;

    const display = if (root_index == 0) relative else absolute;
    if (acceptedCandidate(.{ .path = display, .kind = kind }) == null) return false;

    const seen_entry = try seen.getOrPut(alloc, absolute);
    if (seen_entry.found_existing) return false;
    try candidates.append(alloc, .{ .path = display, .kind = kind });
    return true;
}

fn isStopRequested(stop_requested: ?*std.atomic.Value(bool)) bool {
    return if (stop_requested) |flag| flag.load(.seq_cst) else false;
}

const RawTotals = struct {
    /// Number of entries in `raw_list` that pass the filters and fit under
    /// `max_indexed_files`.
    n: u32,
    /// Sum of byte lengths of every kept path. The loader pre-allocates
    /// `paths_buf` and `lower_buf` to exactly this size.
    bytes: u32,
};

fn rawPathSeparator(raw_list: []const u8) u8 {
    return if (std.mem.findScalar(u8, raw_list, 0) != null) 0 else '\n';
}

fn acceptedRawPath(sep: u8, raw: []const u8) ?[]const u8 {
    const path = if (sep == '\n') std.mem.trimEnd(u8, raw, "\r") else raw;
    if (path.len == 0) return null;
    if (path.len > max_path_len) return null;
    if (!text_utils.isTerminalSafe(path)) return null;
    return path;
}

fn acceptedCandidate(candidate: Candidate) ?Candidate {
    if (!text_utils.isTerminalSafe(candidate.path)) return null;
    return acceptedSafeCandidate(candidate);
}

/// `acceptedCandidate` for a path already known to be terminal-safe.
fn acceptedSafeCandidate(candidate: Candidate) ?Candidate {
    if (candidate.path.len == 0) return null;
    if (candidate.path.len > max_path_len) return null;
    if (!file_picker_path.isRepresentable(candidate.path)) return null;
    if (candidate.kind == .directory and std.Io.Dir.path.isSep(candidate.path[candidate.path.len - 1])) return null;
    return candidate;
}

/// Applies fill-pass filters to size generation buffers before publication.
fn countAndSize(source: CandidateSource) RawTotals {
    var n: u32 = 0;
    var bytes: u32 = 0;

    var iter = source.iterator();
    while (iter.next()) |candidate| {
        const accepted = acceptedCandidate(candidate) orelse continue;
        if (n >= max_indexed_files) break;

        n += 1;
        bytes += @intCast(accepted.path.len);
    }

    return .{ .n = n, .bytes = bytes };
}

/// Returns an a-z presence bitmap. Non-ASCII input cannot cause false rejection.
fn alphaMask(bytes: []const u8) u32 {
    var m: u32 = 0;
    for (bytes) |b| {
        const lower = asciiToLower(b);
        if (lower >= 'a' and lower <= 'z') {
            m |= @as(u32, 1) << @intCast(lower - 'a');
        }
    }
    return m;
}

const non_ascii_mask: u32 = @as(u32, 1) << 31;
pub const max_search_results: usize = 64;

fn asciiToLower(b: u8) u8 {
    return if (b >= 'A' and b <= 'Z') b + 32 else b;
}

fn foldUtf8Into(bytes: []const u8, out: []u21) ?[]const u21 {
    var byte_index: usize = 0;
    var scalar_index: usize = 0;
    while (byte_index < bytes.len) {
        if (scalar_index >= out.len) return null;
        const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[byte_index]) catch return null;
        const end = byte_index + sequence_len;
        if (end > bytes.len) return null;
        const codepoint = display_width.decodeUtf8Sequence(bytes[byte_index..end]) catch return null;
        out[scalar_index] = unicode_simple_fold.fold(codepoint);
        scalar_index += 1;
        byte_index = end;
    }
    return out[0..scalar_index];
}

const QueryScratch = struct {
    folded: [max_path_len]u21,
    ascii: [max_path_len]u8,
};

const PreparedQuery = struct {
    folded: []const u21,
    ascii: ?[]const u8,
};

fn prepareQuery(query: []const u8, scratch: *QueryScratch) ?PreparedQuery {
    const folded = foldUtf8Into(query, &scratch.folded) orelse return null;
    for (folded, 0..) |scalar, index| {
        if (scalar > 0x7f) return .{ .folded = folded, .ascii = null };
        scratch.ascii[index] = @intCast(scalar);
    }
    return .{ .folded = folded, .ascii = scratch.ascii[0..folded.len] };
}

const FoldedPathScratch = struct {
    scalars: [max_path_len]u21,
    byte_offsets: [max_path_len + 1]u16,
};

const DecodedFoldedPath = struct {
    scalar_count: usize,
    basename_scalar_start: usize,
};

fn decodeFoldedPath(
    path: []const u8,
    basename_byte_start: usize,
    scratch: *FoldedPathScratch,
) ?DecodedFoldedPath {
    var byte_index: usize = 0;
    var scalar_index: usize = 0;
    var basename_scalar_start: ?usize = null;
    while (byte_index < path.len) {
        if (byte_index == basename_byte_start) basename_scalar_start = scalar_index;
        const sequence_len = std.unicode.utf8ByteSequenceLength(path[byte_index]) catch return null;
        const end = byte_index + sequence_len;
        if (end > path.len or scalar_index >= scratch.scalars.len) return null;
        const codepoint = display_width.decodeUtf8Sequence(path[byte_index..end]) catch return null;
        scratch.byte_offsets[scalar_index] = std.math.cast(u16, byte_index) orelse return null;
        scratch.scalars[scalar_index] = unicode_simple_fold.fold(codepoint);
        scalar_index += 1;
        byte_index = end;
    }
    if (byte_index == basename_byte_start) basename_scalar_start = scalar_index;
    scratch.byte_offsets[scalar_index] = std.math.cast(u16, path.len) orelse return null;
    return .{
        .scalar_count = scalar_index,
        .basename_scalar_start = basename_scalar_start orelse return null,
    };
}

const MatchScore = struct {
    exact_fit: bool,
    /// The scored placement ends in the file or folder name rather than in a
    /// parent folder.
    name_fit: bool,
    /// Additive score of the chosen placement, including `name_bonus` when it
    /// lies inside the name.
    quality: i32,
    /// Scalar index of the first matched character, relative to the scored range.
    first_position: u32,
};

/// Owns its prepared query without interior pointers. Names are borrowed only
/// during each call; scoring and highlighting share the indexed-search rules.
pub const NameQuery = struct {
    scratch: QueryScratch,
    len: usize,
    ascii: bool,
    ascii_mask: u32,

    pub const Score = MatchScore;

    pub fn init(query: []const u8) ?NameQuery {
        if (query.len > max_path_len) return null;
        var result: NameQuery = undefined;
        const prepared = prepareQuery(query, &result.scratch) orelse return null;
        result.len = prepared.folded.len;
        result.ascii = prepared.ascii != null;
        result.ascii_mask = if (prepared.ascii) |bytes| alphaMask(bytes) else 0;
        return result;
    }

    pub fn score(self: *const NameQuery, name: []const u8) ?Score {
        if (name.len == 0 or name.len > max_path_len) return null;
        if (self.len == 0) return .{ .exact_fit = false, .name_fit = false, .quality = 0, .first_position = 0 };
        var align_scratch: AlignScratch = undefined;
        for (name) |byte| {
            if (byte >= 0x80) {
                var scratch: FoldedPathScratch = undefined;
                return scoreFoldedMatchWith(&align_scratch, name, 0, self.scratch.folded[0..self.len], &scratch, .{});
            }
        }
        if (!self.ascii or alphaMask(name) & self.ascii_mask != self.ascii_mask) return null;
        var lower: [max_path_len]u8 = undefined;
        for (name, lower[0..name.len]) |byte, *folded| folded.* = asciiToLower(byte);
        return scoreAsciiMatchWith(&align_scratch, name, lower[0..name.len], 0, self.scratch.ascii[0..self.len], .{});
    }

    pub fn better(self: *const NameQuery, left: Score, left_path: []const u8, right: Score, right_path: []const u8) bool {
        if (self.len > 0) {
            if (scoreBetter(left, right)) return true;
            if (scoreBetter(right, left)) return false;
            if (left_path.len != right_path.len) return left_path.len < right_path.len;
        }
        return std.mem.order(u8, left_path, right_path) == .lt;
    }

    /// Writes name-relative byte spans into caller-owned storage.
    pub fn match_spans(self: *const NameQuery, name: []const u8, out: []MatchSpan) SearchError!usize {
        if (self.len == 0) return 0;
        var scratch: FoldedPathScratch = undefined;
        var align_scratch: AlignScratch = undefined;
        var offsets: [max_path_len]u16 = undefined;
        var spans: [max_path_len]MatchSpan = undefined;
        const count = reconstructMatchSpans(name, 0, self.scratch.folded[0..self.len], &scratch, &align_scratch, &offsets, &spans) orelse return error.InvalidIndexData;
        if (count > out.len) return error.NoSpaceLeft;
        @memcpy(out[0..count], spans[0..count]);
        return count;
    }
};

const RankedCandidate = struct {
    score: MatchScore,
    index: u32,
};

fn rankTopN(generation: *const Generation, total: usize, query: PreparedQuery, out: []u32, align_scratch: *AlignScratch) usize {
    const top_cap = @min(out.len, max_search_results);
    if (top_cap == 0) return 0;

    var ranked: [max_search_results]RankedCandidate = undefined;
    var filled: usize = 0;
    var worst_slot: usize = 0;

    const query_ascii = query.ascii;
    const query_mask = if (query_ascii) |ascii| alphaMask(ascii) else 0;
    const max_crossing = maxCrossingQuality(u21, query.folded);
    const max_name = maxNameQuality(query.folded.len);
    var scalar_scratch: FoldedPathScratch = undefined;

    var candidate_index: u32 = 0;
    while (candidate_index < total) : (candidate_index += 1) {
        const path_mask = generation.char_masks[candidate_index];
        const base_start = generation.basename_starts[candidate_index] - generation.offsets[candidate_index];
        // Once the worst kept result has the best score a non-exact match can
        // reach, only an exact match or a shorter path can still enter, so
        // longer paths are not scored. Once every kept result is exact, only
        // exact matches can enter.
        const length_limit: ?usize = if (filled < top_cap) null else limit: {
            const worst = ranked[worst_slot];
            if (worst.score.exact_fit) break :limit 0;
            if (worst.score.name_fit and worst.score.quality == max_name and worst.score.first_position == 0) {
                break :limit generation.pathAt(worst.index).len;
            }
            break :limit null;
        };
        // Skip the placements that can no longer enter the kept results; the
        // results stay those of scoring every path.
        const needed: Needed = if (filled < top_cap) .{} else needed: {
            const worst = ranked[worst_slot].score;
            break :needed .{
                // A placement ending in a folder ranks below every name match.
                .folder = !(worst.exact_fit or worst.name_fit),
                // A placement starting in a folder scores at most `max_crossing`.
                .crossing = !(worst.exact_fit or (worst.name_fit and worst.quality > max_crossing)),
            };
        };
        const score = if ((path_mask & non_ascii_mask) == 0) ascii_path: {
            const ascii = query_ascii orelse continue;
            if ((path_mask & query_mask) != query_mask) continue;
            if (length_limit) |limit| {
                const path_lower = generation.lowerPathAt(candidate_index);
                if (path_lower.len > limit and !exactFit(u8, path_lower, path_lower[base_start..], ascii)) continue;
            }
            break :ascii_path scoreAsciiMatchWith(
                align_scratch,
                generation.pathAt(candidate_index),
                generation.lowerPathAt(candidate_index),
                base_start,
                ascii,
                needed,
            );
        } else scoreFoldedMatchWith(align_scratch, generation.pathAt(candidate_index), base_start, query.folded, &scalar_scratch, needed);
        const match_score = score orelse continue;
        const candidate: RankedCandidate = .{ .score = match_score, .index = candidate_index };

        if (filled < top_cap) {
            ranked[filled] = candidate;
            filled += 1;
            if (filled == top_cap) worst_slot = findWorstSlot(generation, ranked[0..filled]);
        } else if (rankedCandidateBetter(generation, candidate, ranked[worst_slot])) {
            ranked[worst_slot] = candidate;
            worst_slot = findWorstSlot(generation, ranked[0..filled]);
        }
    }

    sortRanked(generation, ranked[0..filled]);
    for (ranked[0..filled], 0..) |candidate, result_index| out[result_index] = candidate.index;
    return filled;
}

// Best-alignment scoring with fzf's v2 path-scheme score. A placement's score
// is defined by `scoreAlignment`; `alignBest` returns the placement with the
// highest score and, among those, the earliest first position. The dynamic
// program is exact because its state carries the run bonus that fzf's
// consecutive rule depends on, normalized to one of four values.
const max_align_cells: usize = 4096;
const run_slot_count: usize = 4;
const run_slot_bonus = [run_slot_count]i32{ 4, 7, 8, 9 };
const score_match: i32 = 16;
const score_gap_start: i32 = -3;
const score_gap_extension: i32 = -1;
const bonus_boundary: i32 = score_match / 2;
const bonus_non_word: i32 = score_match / 2;
const bonus_camel_123: i32 = bonus_boundary + score_gap_extension;
const bonus_consecutive: i32 = -(score_gap_start + score_gap_extension);
const bonus_first_char_multiplier: i32 = 2;
const bonus_boundary_white: i32 = bonus_boundary;
const bonus_boundary_delimiter: i32 = bonus_boundary + 1;
const invalid_score: i32 = std.math.minInt(i32);

/// One search's alignment workspace. Callers create it once and reuse it for
/// every candidate; nothing in it survives between calls.
const AlignScratch = struct {
    scores: [max_align_cells * run_slot_count]i32,
    starts: [max_align_cells * run_slot_count]u16,
    pred_entries: [max_align_cells * run_slot_count]u16,
    pred_slots: [max_align_cells * run_slot_count]u8,
    /// Text position of each sparse cell, row by row.
    columns: [max_align_cells]u16,
    row_offsets: [max_path_len + 1]u16,
    forward: [max_path_len]u16,
    backward: [max_path_len]u16,
    positions: [max_path_len]u16,
};

const Alignment = struct {
    quality: i32,
    first_position: u32,
};

const CharClass = enum { white, non_word, delimiter, lower, upper, letter, number };

fn charClassOf(byte: u8) CharClass {
    return switch (byte) {
        'a'...'z' => .lower,
        'A'...'Z' => .upper,
        '0'...'9' => .number,
        ' ', '\t', '\n', '\r' => .white,
        '/' => .delimiter,
        0x80...0xff => .letter,
        else => .non_word,
    };
}

fn bonusFor(prev: CharClass, class: CharClass) i32 {
    switch (class) {
        .lower, .upper, .letter, .number => switch (prev) {
            .white => return bonus_boundary_white,
            .delimiter => return bonus_boundary_delimiter,
            .non_word => return bonus_boundary,
            else => {},
        },
        else => {},
    }
    if ((prev == .lower and class == .upper) or (prev != .number and class == .number)) return bonus_camel_123;
    return switch (class) {
        .non_word, .delimiter => bonus_non_word,
        .white => bonus_boundary_white,
        else => 0,
    };
}

fn bonusAt(path: []const u8, byte_offsets: ?[]const u16, position: usize) i32 {
    const byte_index: usize = if (byte_offsets) |offsets| offsets[position] else position;
    const prev: CharClass = if (byte_index == 0) .delimiter else charClassOf(path[byte_index - 1]);
    return bonusFor(prev, charClassOf(path[byte_index]));
}

fn runSlot(run_bonus: i32) usize {
    return switch (@max(run_bonus, bonus_consecutive)) {
        4 => 0,
        7 => 1,
        8 => 2,
        9 => 3,
        else => unreachable,
    };
}

fn consecutiveBonus(bonus: i32, run_bonus: i32) struct { bonus: i32, run: i32 } {
    if (bonus >= bonus_boundary and bonus > run_bonus) return .{ .bonus = bonus, .run = bonus };
    return .{ .bonus = @max(bonus, @max(run_bonus, bonus_consecutive)), .run = run_bonus };
}

/// Pure: the score of one fixed placement. This defines the ranking score.
fn scoreAlignment(path: []const u8, byte_offsets: ?[]const u16, range_start: usize, positions: []const u16) Alignment {
    var total: i32 = 0;
    var run: i32 = 0;
    for (positions, 0..) |position, index| {
        const bonus = bonusAt(path, byte_offsets, position);
        if (index == 0) {
            total = score_match + bonus * bonus_first_char_multiplier;
            run = bonus;
            continue;
        }
        const previous = positions[index - 1];
        if (position == previous + 1) {
            const step = consecutiveBonus(bonus, run);
            total += score_match + step.bonus;
            run = step.run;
        } else {
            const gap: i32 = @intCast(position - previous - 1);
            total += score_match + bonus + score_gap_start + (gap - 1) * score_gap_extension;
            run = bonus;
        }
    }
    return .{ .quality = total, .first_position = @intCast(positions[0] - range_start) };
}

inline fn betterCandidate(score: i32, start: u16, best_score: i32, best_start: u16) bool {
    return score > best_score or (score == best_score and start < best_start);
}

/// Pure: finds the best placement of `query` in `text[range_start..]` whose
/// last letter lands at or after `end_min`, and writes its text positions to
/// `scratch.positions[0..query.len]`. When the search would need more than
/// `max_align_cells` cells, the leftmost greedy such placement is scored
/// instead.
fn alignBest(
    comptime T: type,
    text: []const T,
    path: []const u8,
    byte_offsets: ?[]const u16,
    range_start: usize,
    end_min: usize,
    query: []const T,
    scratch: *AlignScratch,
) ?Alignment {
    const m = query.len;
    if (m == 0 or range_start > text.len or m > text.len - range_start) return null;
    std.debug.assert(end_min >= range_start);

    if (m == 1 and text.len - end_min <= max_align_cells) {
        // The earliest occurrence with the highest bonus, in one scan: the
        // window fits the cell budget, and no bonus beats the one after `/`.
        var best_position: ?usize = null;
        var best_bonus: i32 = 0;
        var j = end_min;
        while (j < text.len) : (j += 1) {
            if (text[j] != query[0]) continue;
            const bonus = bonusAt(path, byte_offsets, j);
            if (best_position == null or bonus > best_bonus) {
                best_position = j;
                best_bonus = bonus;
                if (bonus == bonus_boundary_delimiter) break;
            }
        }
        const only = best_position orelse return null;
        scratch.positions[0] = @intCast(only);
        return .{ .quality = score_match + best_bonus * bonus_first_char_multiplier, .first_position = @intCast(only - range_start) };
    }

    var query_index: usize = 0;
    var position = range_start;
    while (position < text.len and query_index < m) : (position += 1) {
        if (text[position] != query[query_index]) continue;
        scratch.forward[query_index] = @intCast(position);
        query_index += 1;
    }
    if (query_index < m) return null;

    var back_index: usize = m;
    var back_position: usize = text.len;
    while (back_index > 0) {
        back_position -= 1;
        if (text[back_position] != query[back_index - 1]) continue;
        back_index -= 1;
        scratch.backward[back_index] = @intCast(back_position);
    }
    if (scratch.backward[m - 1] < end_min) return null;
    if (scratch.forward[m - 1] < end_min) {
        // Still after forward[m - 2], which lies before the old forward[m - 1].
        var last = end_min;
        while (text[last] != query[m - 1]) last += 1;
        scratch.forward[m - 1] = @intCast(last);
    }

    // Both greedy scans agree only when a single placement exists.
    if (std.mem.eql(u16, scratch.forward[0..m], scratch.backward[0..m])) {
        @memcpy(scratch.positions[0..m], scratch.forward[0..m]);
        return scoreAlignment(path, byte_offsets, range_start, scratch.positions[0..m]);
    }

    // Row r may only place query[r] in forward[r]..backward[r]. The cell budget
    // is defined on those window widths.
    var cells: usize = 0;
    for (scratch.forward[0..m], scratch.backward[0..m]) |first, last| cells += @as(usize, last) - first + 1;
    if (cells > max_align_cells) {
        @memcpy(scratch.positions[0..m], scratch.forward[0..m]);
        return scoreAlignment(path, byte_offsets, range_start, scratch.positions[0..m]);
    }

    // Sparse rows: one cell per position where query[r] matches inside its window.
    var entries: usize = 0;
    for (0..m) |row| {
        scratch.row_offsets[row] = @intCast(entries);
        var j: usize = scratch.forward[row];
        while (j <= scratch.backward[row]) : (j += 1) {
            if (text[j] != query[row]) continue;
            scratch.columns[entries] = @intCast(j);
            entries += 1;
        }
    }
    scratch.row_offsets[m] = @intCast(entries);

    for (0..m) |row| {
        const row_begin: usize = scratch.row_offsets[row];
        const row_end: usize = scratch.row_offsets[row + 1];
        const prev_begin: usize = if (row > 0) scratch.row_offsets[row - 1] else 0;
        const prev_end: usize = if (row > 0) scratch.row_offsets[row] else 0;
        var best_gap: i32 = invalid_score;
        var best_gap_start: u16 = 0;
        var best_gap_entry: u16 = 0;
        var best_gap_slot: u8 = 0;
        var next_gap = prev_begin;
        var diag = prev_begin;

        for (row_begin..row_end) |entry| {
            const j: usize = scratch.columns[entry];
            const cell = entry * run_slot_count;
            @memset(scratch.scores[cell..][0..run_slot_count], invalid_score);
            const bonus = bonusAt(path, byte_offsets, j);
            if (row == 0) {
                const slot = runSlot(bonus);
                scratch.scores[cell + slot] = score_match + bonus * bonus_first_char_multiplier;
                scratch.starts[cell + slot] = @intCast(j);
                continue;
            }
            // Fold in every predecessor at least two positions back.
            while (next_gap < prev_end and @as(usize, scratch.columns[next_gap]) + 2 <= j) : (next_gap += 1) {
                const prev_cell = next_gap * run_slot_count;
                const shift: i32 = scratch.columns[next_gap];
                for (0..run_slot_count) |slot| {
                    const value = scratch.scores[prev_cell + slot];
                    if (value == invalid_score) continue;
                    const start = scratch.starts[prev_cell + slot];
                    if (betterCandidate(value + shift, start, best_gap, best_gap_start)) {
                        best_gap = value + shift;
                        best_gap_start = start;
                        best_gap_entry = @intCast(next_gap);
                        best_gap_slot = @intCast(slot);
                    }
                }
            }
            while (diag < prev_end and @as(usize, scratch.columns[diag]) + 1 < j) diag += 1;
            if (diag < prev_end and @as(usize, scratch.columns[diag]) + 1 == j) {
                const prev_cell = diag * run_slot_count;
                for (0..run_slot_count) |prev_slot| {
                    const value = scratch.scores[prev_cell + prev_slot];
                    if (value == invalid_score) continue;
                    const step = consecutiveBonus(bonus, run_slot_bonus[prev_slot]);
                    const slot = runSlot(step.run);
                    const candidate = value + score_match + step.bonus;
                    const start = scratch.starts[prev_cell + prev_slot];
                    if (betterCandidate(candidate, start, scratch.scores[cell + slot], scratch.starts[cell + slot])) {
                        scratch.scores[cell + slot] = candidate;
                        scratch.starts[cell + slot] = start;
                        scratch.pred_entries[cell + slot] = @intCast(diag);
                        scratch.pred_slots[cell + slot] = @intCast(prev_slot);
                    }
                }
            }
            if (best_gap != invalid_score) {
                const slot = runSlot(bonus);
                const candidate = best_gap - @as(i32, @intCast(j)) - 1 + score_match + bonus;
                if (betterCandidate(candidate, best_gap_start, scratch.scores[cell + slot], scratch.starts[cell + slot])) {
                    scratch.scores[cell + slot] = candidate;
                    scratch.starts[cell + slot] = best_gap_start;
                    scratch.pred_entries[cell + slot] = best_gap_entry;
                    scratch.pred_slots[cell + slot] = best_gap_slot;
                }
            }
        }
    }

    var best_score: i32 = invalid_score;
    var best_start: u16 = 0;
    var best_entry: usize = 0;
    var best_slot: usize = 0;
    for (scratch.row_offsets[m - 1]..scratch.row_offsets[m]) |entry| {
        for (0..run_slot_count) |slot| {
            const value = scratch.scores[entry * run_slot_count + slot];
            if (value == invalid_score) continue;
            if (betterCandidate(value, scratch.starts[entry * run_slot_count + slot], best_score, best_start)) {
                best_score = value;
                best_start = scratch.starts[entry * run_slot_count + slot];
                best_entry = entry;
                best_slot = slot;
            }
        }
    }
    if (best_score == invalid_score) return null;

    var row = m - 1;
    var entry = best_entry;
    var slot = best_slot;
    while (true) {
        scratch.positions[row] = scratch.columns[entry];
        if (row == 0) break;
        const cell = entry * run_slot_count + slot;
        entry = scratch.pred_entries[cell];
        slot = scratch.pred_slots[cell];
        row -= 1;
    }
    std.debug.assert(scratch.positions[0] == best_start);
    return .{ .quality = best_score, .first_position = @intCast(@as(usize, best_start) - range_start) };
}

/// Points a placement inside the file or folder name earns over one that
/// starts in the folder holding the name. A close call favors the name, so
/// for `abcd`, `src/x/ab-cd.ts` stays above `src/ab/cd.ts`, while a clean
/// folder-plus-name match such as `vercle` for `vercel-json/clean-urls.mdx`
/// can still beat letters scattered through a name.
const name_bonus: i32 = 4;

comptime {
    // `maxCrossingQuality` assumes no character earns more than this bonus.
    for ([_]i32{ bonus_boundary, bonus_non_word, bonus_camel_123, bonus_consecutive, bonus_boundary_white }) |bonus| {
        std.debug.assert(bonus <= bonus_boundary_delimiter);
    }
}

/// The highest score of a placement that starts in a parent folder and ends
/// in the name. Without a `/` in the query such a placement skips the `/`
/// before the name, which costs at least one gap.
fn maxCrossingQuality(comptime T: type, query: []const T) i32 {
    const m: i32 = @intCast(query.len);
    const ceiling = score_match * m + bonus_boundary_delimiter * (m + 1);
    return if (std.mem.findScalar(T, query, '/') == null) ceiling + score_gap_start else ceiling;
}

/// The highest score a non-exact match can reach: the query as a run at the
/// start of the name, right after its `/`, plus `name_bonus`. Its first
/// position is 0, because only the first letter of a name follows a `/`.
fn maxNameQuality(query_len: usize) i32 {
    const m: i32 = @intCast(query_len);
    return score_match * m + bonus_boundary_delimiter * (m + 1) + name_bonus;
}

/// A query that spells the whole path, the name, or the name up to a dot,
/// such as `main` for `main.zig`, is an exact match.
fn exactFit(comptime T: type, whole: []const T, name: []const T, query: []const T) bool {
    return std.mem.eql(T, whole, query) or std.mem.eql(T, name, query) or
        (name.len > query.len and std.mem.startsWith(T, name, query) and name[query.len] == '.');
}

/// Which placements a candidate may still need. Ranking turns a kind off only
/// once it can no longer enter the kept results.
const Needed = struct {
    /// Placements that end in a parent folder.
    folder: bool = true,
    /// Placements that start in the folder holding the name and end in the name.
    crossing: bool = true,
};

const Placement = struct {
    name_fit: bool,
    alignment: Alignment,
    range_start: usize,
    end_min: usize,
};

/// Pure: picks the placement that defines a candidate's score. A placement
/// ending in the file or folder name ranks above one ending in a parent
/// folder. Among those, the best placement inside the name, plus
/// `name_bonus`, competes with the best one that starts in the folder that
/// holds the name, as in `vercle` for `vercel-json/clean-urls.mdx`. Crossing
/// placements start no higher than that folder, so their search covers only
/// the folder and the name.
fn choosePlacement(
    comptime T: type,
    text: []const T,
    path: []const u8,
    byte_offsets: ?[]const u16,
    base_start: usize,
    query: []const T,
    scratch: *AlignScratch,
    needed: Needed,
) ?Placement {
    var best: ?Placement = null;
    if (alignBest(T, text, path, byte_offsets, base_start, base_start, query, scratch)) |inside| {
        best = .{
            .name_fit = true,
            .alignment = .{ .quality = inside.quality + name_bonus, .first_position = inside.first_position },
            .range_start = base_start,
            .end_min = base_start,
        };
    }
    // Without a placement in the name, a path that does not hold the letters
    // in order has no other placement either; one scan settles it.
    if (best == null and query.len > 1 and !isSubsequence(T, text, query)) return null;
    const crossing_can_win = if (best) |inside| inside.alignment.quality < maxCrossingQuality(T, query) else true;
    if (needed.crossing and base_start > 0 and query.len > 1 and crossing_can_win) {
        // text[base_start - 1] is the `/` before the name.
        const folder_start = if (std.mem.findScalarLast(T, text[0 .. base_start - 1], '/')) |slash| slash + 1 else 0;
        if (alignBest(T, text, path, byte_offsets, folder_start, base_start, query, scratch)) |crossing| {
            if (best == null or crossing.quality > best.?.alignment.quality) {
                best = .{ .name_fit = true, .alignment = crossing, .range_start = folder_start, .end_min = base_start };
            }
        }
    }
    if (best != null) return best;
    if (!needed.folder) return null;
    const anywhere = alignBest(T, text, path, byte_offsets, 0, 0, query, scratch) orelse return null;
    return .{ .name_fit = false, .alignment = anywhere, .range_start = 0, .end_min = 0 };
}

fn isSubsequence(comptime T: type, text: []const T, query: []const T) bool {
    var query_index: usize = 0;
    for (text) |item| {
        if (item != query[query_index]) continue;
        query_index += 1;
        if (query_index == query.len) return true;
    }
    return false;
}

fn scoreOf(exact_fit: bool, placement: Placement) MatchScore {
    return .{
        .exact_fit = exact_fit,
        .name_fit = placement.name_fit,
        .quality = placement.alignment.quality,
        .first_position = placement.alignment.first_position,
    };
}

fn scoreAsciiMatch(
    path: []const u8,
    path_lower: []const u8,
    basename_start: u32,
    query: []const u8,
) ?MatchScore {
    var scratch: AlignScratch = undefined;
    return scoreAsciiMatchWith(&scratch, path, path_lower, basename_start, query, .{});
}

fn scoreAsciiMatchWith(
    scratch: *AlignScratch,
    path: []const u8,
    path_lower: []const u8,
    basename_start: u32,
    query: []const u8,
    needed: Needed,
) ?MatchScore {
    if (query.len == 0 or path.len == 0) return null;
    const base_start: usize = basename_start;
    const exact_fit = exactFit(u8, path_lower, path_lower[base_start..], query);
    // An exact match always enters, so it is always scored in full.
    const placement = choosePlacement(u8, path_lower, path, null, base_start, query, scratch, if (exact_fit) .{} else needed) orelse return null;
    return scoreOf(exact_fit, placement);
}

fn scoreFoldedMatchWith(
    align_scratch: *AlignScratch,
    path: []const u8,
    basename_byte_start: u32,
    query: []const u21,
    scratch: *FoldedPathScratch,
    needed: Needed,
) ?MatchScore {
    if (query.len == 0 or path.len == 0) return null;
    const base_start: usize = basename_byte_start;
    const decoded = decodeFoldedPath(path, base_start, scratch) orelse return null;
    const scalars = scratch.scalars[0..decoded.scalar_count];
    const exact_fit = exactFit(u21, scalars, scalars[decoded.basename_scalar_start..], query);
    const byte_offsets = scratch.byte_offsets[0 .. decoded.scalar_count + 1];
    const placement = choosePlacement(u21, scalars, path, byte_offsets, decoded.basename_scalar_start, query, align_scratch, if (exact_fit) .{} else needed) orelse return null;
    return scoreOf(exact_fit, placement);
}

inline fn scoreBetter(left: MatchScore, right: MatchScore) bool {
    if (left.exact_fit != right.exact_fit) return left.exact_fit;
    if (left.name_fit != right.name_fit) return left.name_fit;
    if (left.quality != right.quality) return left.quality > right.quality;
    if (left.first_position != right.first_position) return left.first_position < right.first_position;
    return false;
}

fn rankedCandidateBetter(generation: *const Generation, left: RankedCandidate, right: RankedCandidate) bool {
    if (scoreBetter(left.score, right.score)) return true;
    if (scoreBetter(right.score, left.score)) return false;
    const left_path = generation.pathAt(left.index);
    const right_path = generation.pathAt(right.index);
    if (left_path.len != right_path.len) return left_path.len < right_path.len;
    return std.mem.order(u8, left_path, right_path) == .lt;
}

fn findWorstSlot(generation: *const Generation, ranked: []const RankedCandidate) usize {
    var worst_slot: usize = 0;
    for (ranked[1..], 1..) |candidate, candidate_index| {
        if (rankedCandidateBetter(generation, ranked[worst_slot], candidate)) worst_slot = candidate_index;
    }
    return worst_slot;
}

fn sortRanked(generation: *const Generation, ranked: []RankedCandidate) void {
    var candidate_index: usize = 1;
    while (candidate_index < ranked.len) : (candidate_index += 1) {
        const candidate = ranked[candidate_index];
        var insertion_index = candidate_index;
        while (insertion_index > 0 and rankedCandidateBetter(generation, candidate, ranked[insertion_index - 1])) : (insertion_index -= 1) {
            ranked[insertion_index] = ranked[insertion_index - 1];
        }
        ranked[insertion_index] = candidate;
    }
}

fn reconstructMatchSpans(
    path: []const u8,
    basename_byte_start: u32,
    query: []const u21,
    path_scratch: *FoldedPathScratch,
    align_scratch: *AlignScratch,
    matched_offsets: *[max_path_len]u16,
    span_scratch: *[max_path_len]MatchSpan,
) ?usize {
    const decoded = decodeFoldedPath(path, basename_byte_start, path_scratch) orelse return null;
    const scalars = path_scratch.scalars[0..decoded.scalar_count];
    const byte_offsets = path_scratch.byte_offsets[0 .. decoded.scalar_count + 1];
    const placement = choosePlacement(u21, scalars, path, byte_offsets, decoded.basename_scalar_start, query, align_scratch, .{}) orelse return null;
    // Rerun the chosen search: a later search in the choice reuses the positions.
    _ = alignBest(u21, scalars, path, byte_offsets, placement.range_start, placement.end_min, query, align_scratch) orelse return null;
    for (align_scratch.positions[0..query.len], matched_offsets[0..query.len]) |position, *offset| {
        offset.* = byte_offsets[position];
    }
    return spansFromMatchedOffsets(path, matched_offsets[0..query.len], span_scratch);
}

fn spansFromMatchedOffsets(
    path: []const u8,
    matched_offsets: []const u16,
    out: *[max_path_len]MatchSpan,
) ?usize {
    var matched_index: usize = 0;
    var span_count: usize = 0;
    var cursor: usize = 0;
    while (cursor < path.len and matched_index < matched_offsets.len) {
        const cluster_start = cursor;
        const first = display_width.displayUnitAt(path, cursor);
        if (first.byte_len == 0) return null;
        cursor += first.byte_len;
        while (cursor < path.len) {
            const continuation = display_width.displayUnitAt(path, cursor);
            if (continuation.byte_len == 0) return null;
            if (continuation.cell_width != 0) break;
            cursor += continuation.byte_len;
        }
        const cluster_end = cursor;

        var cluster_matched = false;
        while (matched_index < matched_offsets.len and matched_offsets[matched_index] < cluster_end) {
            if (matched_offsets[matched_index] < cluster_start) return null;
            cluster_matched = true;
            matched_index += 1;
        }
        if (!cluster_matched) continue;

        if (span_count > 0 and out[span_count - 1].byte_end == cluster_start) {
            out[span_count - 1].byte_end = std.math.cast(u16, cluster_end) orelse return null;
            continue;
        }
        out[span_count] = .{
            .byte_start = std.math.cast(u16, cluster_start) orelse return null,
            .byte_end = std.math.cast(u16, cluster_end) orelse return null,
        };
        span_count += 1;
    }
    if (matched_index != matched_offsets.len) return null;
    return span_count;
}

test "filename fuzzy matcher shares indexed ordering and Unicode highlight spans" {
    const alloc = std.testing.allocator;
    const names = [_][]const u8{ "Desktop", "desktop-tools", "myDesktop", "Desk top", "dusk-top", "Ärger-file.txt", "Kelvin", "cafe\u{301}.txt" };
    var candidates: [names.len]Candidate = undefined;
    for (names, &candidates) |name, *candidate| candidate.* = .{ .path = name, .kind = .file };
    var index: FileIndex = .{};
    defer index.deinit(alloc);
    try index.buildFromCandidates(alloc, &candidates);
    const RankedName = struct { name: []const u8, score: NameQuery.Score };
    for ([_][]const u8{ "ktop", "dsktp", "desk", "ärf", "klv", "ce", "nomatch" }) |query| {
        const matcher = NameQuery.init(query).?;
        var results: [names.len]SearchResult = undefined;
        var spans: [names.len * max_path_len]MatchSpan = undefined;
        const count = try index.searchTyped(query, &results, &spans);
        var ranked: [names.len]RankedName = undefined;
        var matched: usize = 0;
        for (names) |name| {
            if (matcher.score(name)) |score| {
                ranked[matched] = .{ .name = name, .score = score };
                matched += 1;
            }
        }
        std.mem.sort(RankedName, ranked[0..matched], &matcher, struct {
            fn less(ctx: *const NameQuery, left: RankedName, right: RankedName) bool {
                return ctx.better(left.score, left.name, right.score, right.name);
            }
        }.less);
        try std.testing.expectEqual(count, matched);
        for (ranked[0..matched], results[0..count]) |name, result| {
            try std.testing.expectEqualStrings(result.path, name.name);
            var name_spans: [max_path_len]MatchSpan = undefined;
            const span_count = try matcher.match_spans(name.name, &name_spans);
            try std.testing.expectEqualSlices(MatchSpan, result.matched_spans, name_spans[0..span_count]);
        }
    }
}

fn expectValidSearchSpans(result: SearchResult) !void {
    var previous_end: usize = 0;
    for (result.matched_spans) |span| {
        try std.testing.expect(span.byte_start < span.byte_end);
        try std.testing.expect(span.byte_start >= previous_end);
        try std.testing.expect(span.byte_end <= result.path.len);
        try std.testing.expect(std.unicode.utf8ValidateSlice(result.path[span.byte_start..span.byte_end]));
        previous_end = span.byte_end;
    }
}

fn TestSearchBuffer(comptime capacity: usize) type {
    return struct {
        results: [capacity]SearchResult = undefined,
        spans: [capacity * max_path_len]MatchSpan = undefined,

        fn run(self: *@This(), index: *const FileIndex, query: []const u8) SearchError![]const SearchResult {
            const count = try index.searchTyped(query, &self.results, &self.spans);
            return self.results[0..count];
        }
    };
}

fn expectFirstSearchPath(raw: []const u8, query: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, raw);

    var search: TestSearchBuffer(8) = .{};
    const results = try search.run(&index, query);
    try std.testing.expect(results.len > 0);
    try std.testing.expectEqualStrings(expected, results[0].path);
}

fn containsCandidate(candidates: []const Candidate, path: []const u8, kind: CandidateKind) bool {
    for (candidates) |candidate| {
        if (candidate.kind == kind and std.mem.eql(u8, candidate.path, path)) return true;
    }
    return false;
}

fn runGitForFileIndexTest(alloc: Allocator, cwd: []const u8, argv: []const []const u8) !void {
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        .signal, .stopped, .unknown => return error.TestUnexpectedResult,
    }
}

/// Scans `roots` without a snapshot and keeps the trees alive while the
/// caller inspects candidates that borrow their memory.
const TestScope = struct {
    refreshed: RefreshedTrees,
    candidates: []const Candidate,

    fn init(arena: Allocator, roots: []const []const u8) !TestScope {
        var stop_requested = std.atomic.Value(bool).init(false);
        var refreshed = try refreshTrees(std.testing.allocator, roots, &.{}, &stop_requested);
        errdefer refreshed.deinit(std.testing.allocator);
        return .{ .refreshed = refreshed, .candidates = try candidatesFromTrees(arena, roots, refreshed.trees, &stop_requested) };
    }

    fn deinit(self: *TestScope) void {
        self.refreshed.deinit(std.testing.allocator);
    }
};

const BruteForce = struct {
    best: ?Alignment = null,
    /// Highest score among placements that start before `end_min`.
    crossing_peak: ?i32 = null,
};

fn bruteForceAlignment(path: []const u8, lower: []const u8, range_start: usize, end_min: usize, query: []const u8) BruteForce {
    var positions: [8]u16 = undefined;
    var result: BruteForce = .{};
    bruteForceVisit(path, lower, range_start, end_min, query, 0, range_start, &positions, &result);
    return result;
}

fn bruteForceVisit(
    path: []const u8,
    lower: []const u8,
    range_start: usize,
    end_min: usize,
    query: []const u8,
    depth: usize,
    from: usize,
    positions: *[8]u16,
    result: *BruteForce,
) void {
    if (depth == query.len) {
        if (positions[query.len - 1] < end_min) return;
        const alignment = scoreAlignment(path, null, range_start, positions[0..query.len]);
        if (positions[0] < end_min) result.crossing_peak = @max(result.crossing_peak orelse alignment.quality, alignment.quality);
        if (result.best) |current| {
            if (alignment.quality < current.quality or
                (alignment.quality == current.quality and alignment.first_position >= current.first_position)) return;
        }
        result.best = alignment;
        return;
    }
    var position = from;
    while (position < lower.len) : (position += 1) {
        if (lower[position] != query[depth]) continue;
        positions[depth] = @intCast(position);
        bruteForceVisit(path, lower, range_start, end_min, query, depth + 1, position + 1, positions, result);
    }
}

fn expectPrunedRankingMatchesFullScoring(raw: []const u8, query: []const u8) ![]const u8 {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, raw);
    var search: TestSearchBuffer(max_search_results) = .{};
    const results = try search.run(&index, query);

    const Scored = struct { path: []const u8, score: MatchScore };
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(alloc);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |path| {
        if (path.len == 0) continue;
        var lower: [max_path_len]u8 = undefined;
        for (path, lower[0..path.len]) |byte, *folded| folded.* = asciiToLower(byte);
        const basename_start: u32 = if (std.mem.findScalarLast(u8, path, '/')) |slash| @intCast(slash + 1) else 0;
        if (scoreAsciiMatch(path, lower[0..path.len], basename_start, query)) |score| try scored.append(alloc, .{ .path = path, .score = score });
    }
    std.mem.sort(Scored, scored.items, {}, struct {
        fn less(_: void, left: Scored, right: Scored) bool {
            if (scoreBetter(left.score, right.score)) return true;
            if (scoreBetter(right.score, left.score)) return false;
            if (left.path.len != right.path.len) return left.path.len < right.path.len;
            return std.mem.order(u8, left.path, right.path) == .lt;
        }
    }.less);
    try std.testing.expectEqual(@min(scored.items.len, max_search_results), results.len);
    for (results, scored.items[0..results.len]) |result, expected| try std.testing.expectEqualStrings(expected.path, result.path);
    // The first result's path lives in `raw`, which the caller owns.
    const first = scored.items[0].path;
    return first;
}

const TestLoaderGate = struct {
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cleanup_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cleanup_release: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    cleanup_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    publish_count: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    outcome: GenerationState,
};

fn testLoaderThread(generation: *Generation, gate: *TestLoaderGate) void {
    gate.started.store(true, .release);
    while (!gate.release.load(.acquire)) std.atomic.spinLoopHint();
    gate.cleanup_started.store(true, .release);
    while (!gate.cleanup_release.load(.acquire)) std.atomic.spinLoopHint();
    gate.cleanup_finished.store(true, .release);
    _ = gate.publish_count.fetchAdd(1, .seq_cst);
    const outcome: LoaderOutcome = switch (gate.outcome) {
        .loading => unreachable,
        .ready => .ready,
        .failed => .{ .failed = .{ .stage = .storage, .err = error.TestLoaderFailure } },
        .canceled => .canceled,
    };
    publishLoaderOutcomeAfterCleanup(generation, outcome);
}

fn waitForTestFlag(flag: *const std.atomic.Value(bool)) !void {
    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    while (!flag.load(.acquire)) {
        if (started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds() > 5000) {
            return error.TestUnexpectedResult;
        }
        sleepBlocking(1);
    }
}

fn waitForGenerationState(generation: *const Generation, expected: GenerationState) !void {
    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    while (generation.currentState() != expected) {
        if (started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds() > 5000) {
            return error.TestUnexpectedResult;
        }
        sleepBlocking(1);
    }
}

const TestReapAttempt = struct {
    index: *FileIndex,
    alloc: Allocator,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    visible_changed: bool = false,
};

fn testReapThread(attempt: *TestReapAttempt) void {
    attempt.started.store(true, .release);
    attempt.visible_changed = attempt.index.joinThreadIfDone(attempt.alloc);
    attempt.finished.store(true, .release);
}

fn expectReapReturnsDuringCleanup(index: *FileIndex, alloc: Allocator, gate: *TestLoaderGate) !void {
    var attempt: TestReapAttempt = .{ .index = index, .alloc = alloc };
    const thread = try std.Thread.spawn(.{}, testReapThread, .{&attempt});
    waitForTestFlag(&attempt.started) catch |err| {
        gate.cleanup_release.store(true, .release);
        thread.join();
        return err;
    };
    waitForTestFlag(&attempt.finished) catch |err| {
        gate.cleanup_release.store(true, .release);
        thread.join();
        return err;
    };
    thread.join();
    try std.testing.expect(!attempt.visible_changed);
    try std.testing.expect(!gate.cleanup_release.load(.acquire));
}

fn installTestLoader(
    index: *FileIndex,
    alloc: Allocator,
    raw_list: []const u8,
    gate: *TestLoaderGate,
) !*Generation {
    const generation_id = index.generation + 1;
    const generation = try Generation.create(alloc, generation_id);
    errdefer generation.destroy(alloc);
    try generation.fillProgressive(alloc, .{ .file_raw = raw_list }, null);

    index.loading_generation = generation;
    index.generation = generation_id;
    index.thread = std.Thread.spawn(.{}, testLoaderThread, .{ generation, gate }) catch |err| {
        index.loading_generation = null;
        return err;
    };
    waitForTestFlag(&gate.started) catch |err| {
        gate.release.store(true, .release);
        index.thread.?.join();
        index.thread = null;
        index.loading_generation = null;
        return err;
    };
    return generation;
}

fn checkBuildFromRawAllocationFailures(alloc: Allocator) !void {
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "one.txt\x00two.txt\x00");
}

fn checkBuildFromCandidatesAllocationFailures(alloc: Allocator) !void {
    const candidates = [_]Candidate{
        .{ .path = "src", .kind = .directory },
        .{ .path = "src/main.zig", .kind = .file },
        .{ .path = "src", .kind = .directory },
    };
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromCandidates(alloc, &candidates);
}

fn fuzzRawListAndQuery(_: void, smith: *std.testing.Smith) !void {
    var bytes: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&bytes));
    const split = len / 2;

    var index = FileIndex{};
    defer index.deinit(std.testing.allocator);
    try index.buildFromRaw(std.testing.allocator, bytes[0..split]);

    var typed_results: [8]SearchResult = undefined;
    var span_storage: [8 * max_path_len]MatchSpan = undefined;
    const typed_count = try index.searchTyped(bytes[split..len], &typed_results, &span_storage);
    for (typed_results[0..typed_count]) |typed| {
        try std.testing.expect(typed.path.len <= max_path_len);
        try std.testing.expect(text_utils.isTerminalSafe(typed.path));
        try std.testing.expectEqual(CandidateKind.file, typed.kind);
        try expectValidSearchSpans(typed);
    }
}

fn sleepBlocking(milliseconds: u64) void {
    var sleep_io_backend: std.Io.Threaded = .init_single_threaded;
    sleep_io_backend.io().sleep(.fromMilliseconds(@intCast(milliseconds)), .real) catch {};
}
