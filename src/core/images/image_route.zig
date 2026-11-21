//! How images reach the model on one request.
//!
//! `step` is the whole decision: given the turn's state and one event, it
//! returns the next state and the effects to run. It performs no I/O and reads
//! no clock, environment, or global. The orchestrator is its shell: it runs
//! each effect and feeds the result back as an event.
//!
//! `tests/tla/image_route/spec/ImageRoute.tla` models `step` action for
//! action, and `abstract` maps a state onto that model's variables. The laws
//! below are the model's properties; `tests/tla/image_route/design/DESIGN.md`
//! lists where each one is enforced.
//!
//! Outside its tests, this file imports only `std`, so the JSON-lines
//! harness in `tests/tla/drivers/image_route/` can build it on its own.
const std = @import("std");

/// Whether the selected model takes images inline.
pub const Support = enum {
    /// The catalog was unavailable or did not list the model.
    unknown,
    /// The catalog lists the model without vision.
    non_native,
    /// The catalog lists the model with vision.
    native,
};

/// What the model catalog said about one model.
pub const CatalogView = union(enum) {
    /// The catalog could not be read: unreachable, refused, or malformed.
    down,
    /// The catalog was read and does not list the model.
    missing,
    listed: Tags,

    pub const Tags = struct {
        vision: bool,
        file_input: bool,
    };
};

/// Images reach the model inline exactly when the catalog lists `vision`.
///
/// spark sends every image, user or tool, in an AI SDK `file` part with an
/// `image/*` media type, which is the AI Gateway's vision input. The
/// catalog's `file-input` tag covers documents such as PDFs and says nothing
/// about images, so it plays no part here.
pub fn supportFromCatalog(view: CatalogView) Support {
    return switch (view) {
        .down, .missing => .unknown,
        .listed => |tags| if (tags.vision) .native else .non_native,
    };
}

/// Where the turn's user images go.
pub const Route = enum {
    /// Inline, as file parts.
    native,
    /// Through the vision tool, as text.
    fallback,
    /// Nowhere: a request with user images fails.
    unavailable,
};

/// How the request offers the vision tool.
pub const VisionMode = enum {
    unavailable,
    optional,
    required,
};

/// What happens to the images already in the request's history: tool
/// images, and user images from earlier turns, which follow the same rule.
pub const ToolImages = enum {
    /// The history has none.
    none,
    /// They go inline.
    attached,
    /// Withheld; the model is told to call the vision tool.
    withheld_fallback,
    /// Withheld; the model is told no image path exists.
    withheld_dead_end,
    /// Withheld; the model is told support could not be confirmed.
    withheld_unknown,
};

pub const FailReason = enum {
    /// Images attached this turn, and the catalog could not confirm image input.
    capability_unknown,
    /// Images attached this turn, a model without vision, and no vision tool.
    no_native_image,
};

/// What the shell knows about the request it is about to send. Only flags:
/// image bytes never enter the core.
pub const Request = struct {
    /// The user attached images this turn. Only these can fail a request.
    user_images: bool,
    /// The history holds user images from earlier turns that the session
    /// still has. They are attached or withheld like tool images, so an old
    /// image never blocks a new turn.
    earlier_images: bool,
    /// Some images attached this turn still wait for the model's first look.
    pending_images: bool,
    /// The request history holds tool images the session still has.
    tool_images: bool,
    /// The vision tool is configured and registered.
    fallback: bool,
    /// The catalog is known to be unreachable right now.
    catalog_down: bool,
};

pub const State = struct {
    /// The turn's one capability snapshot. Every decision reads it.
    support: Support = .unknown,
    /// This turn already asked for capabilities.
    resolved: bool = false,
    /// This turn already told the user the catalog is down.
    notified: bool = false,
    /// The request waiting for the capability reply.
    pending: ?Request = null,
};

pub const Event = union(enum) {
    /// A turn starts with the capabilities the shell holds. It also ends
    /// whatever the previous turn left: a reply still owed is dropped.
    turn_started: Support,
    /// The shell has built a request's history and is about to send it.
    request_ready: Request,
    /// The reply to `resolve_capabilities`.
    capabilities_resolved: Support,
};

/// One request's image handling, all read from one support value.
pub const Decision = struct {
    route: Route,
    mode: VisionMode,
    tool_images: ToolImages,
    earlier_images: ToolImages,
};

pub const Effect = union(enum) {
    /// Ask the catalog again, then send `capabilities_resolved`.
    resolve_capabilities,
    /// Tell the user once that tool images wait on the catalog.
    notify_catalog_down,
    /// Send the request as decided.
    send: Decision,
    /// Fail the turn without sending.
    fail: FailReason,
};

pub const max_effects = 2;

pub const Output = struct {
    state: State,
    buffer: [max_effects]Effect = undefined,
    len: usize = 0,

    pub fn effects(self: *const Output) []const Effect {
        return self.buffer[0..self.len];
    }
};

pub fn step(state: State, event: Event) Output {
    return switch (event) {
        .turn_started => |support| .{ .state = .{ .support = support } },
        .request_ready => |request| onRequest(state, request),
        .capabilities_resolved => |support| onResolved(state, support),
    };
}

fn onRequest(state: State, request: Request) Output {
    if (state.pending != null) {
        // Delivered while a reply is owed: the reply answers the newest
        // request, and nothing runs twice.
        var next = state;
        next.pending = request;
        return .{ .state = next };
    }
    if (state.support == .unknown and !state.resolved and hasImages(request)) {
        var next = state;
        next.resolved = true;
        next.pending = request;
        return withEffects(next, &.{.resolve_capabilities});
    }
    return decide(state, request);
}

fn onResolved(state: State, support: Support) Output {
    // A reply nothing waits for, stale or duplicated, changes nothing.
    const request = state.pending orelse return .{ .state = state };
    var next = state;
    next.support = support;
    next.pending = null;
    return decide(next, request);
}

fn decide(state: State, request: Request) Output {
    const chosen = decision(state.support, request);
    if (request.user_images and chosen.route == .unavailable) {
        const reason: FailReason = if (state.support == .unknown) .capability_unknown else .no_native_image;
        return withEffects(state, &.{.{ .fail = reason }});
    }
    if (withholdsUnknown(chosen) and request.catalog_down and !state.notified) {
        var next = state;
        next.notified = true;
        return withEffects(next, &.{ .notify_catalog_down, .{ .send = chosen } });
    }
    return withEffects(state, &.{.{ .send = chosen }});
}

fn hasImages(request: Request) bool {
    return request.user_images or request.earlier_images or request.tool_images;
}

fn withholdsUnknown(chosen: Decision) bool {
    return chosen.tool_images == .withheld_unknown or chosen.earlier_images == .withheld_unknown;
}

/// The image handling `support` implies for `request`.
pub fn decision(support: Support, request: Request) Decision {
    const route: Route = switch (support) {
        .native => .native,
        .unknown => .unavailable,
        .non_native => if (request.fallback) .fallback else .unavailable,
    };
    const mode: VisionMode = if (route != .fallback)
        .unavailable
    else if (request.pending_images)
        .required
    else
        .optional;
    return .{
        .route = route,
        .mode = mode,
        .tool_images = held(request.tool_images, support, route),
        .earlier_images = held(request.earlier_images, support, route),
    };
}

/// How images already in the history travel when `present`: inline only to
/// a model the catalog lists with vision, and otherwise withheld with the
/// reason the model needs to act on.
fn held(present: bool, support: Support, route: Route) ToolImages {
    if (!present) return .none;
    return switch (support) {
        .native => .attached,
        .unknown => .withheld_unknown,
        .non_native => if (route == .fallback) .withheld_fallback else .withheld_dead_end,
    };
}

fn withEffects(state: State, list: []const Effect) Output {
    var out: Output = .{ .state = state, .len = list.len };
    @memcpy(out.buffer[0..list.len], list);
    return out;
}

/// The spec's view of a state: `support`, `resolved`, `notified`, and
/// `pending` as a sequence of at most one request.
pub const Abstract = struct {
    support: Support,
    resolved: bool,
    notified: bool,
    pending: []const Request,
};

/// Maps `state` onto the variables of `ImageRoute.tla`. The result borrows
/// `state`.
pub fn abstract(state: *const State) Abstract {
    return .{
        .support = state.support,
        .resolved = state.resolved,
        .notified = state.notified,
        .pending = if (state.pending) |*request| request[0..1] else &.{},
    };
}

fn eachRequest(comptime body: anytype) !void {
    for (0..64) |bits| {
        const request: Request = .{
            .user_images = bits & 1 != 0,
            .pending_images = bits & 2 != 0,
            .tool_images = bits & 4 != 0,
            .fallback = bits & 8 != 0,
            .catalog_down = bits & 16 != 0,
            .earlier_images = bits & 32 != 0,
        };
        if (request.pending_images and !request.user_images) continue;
        try body(request);
    }
}

const all_support = [_]Support{ .unknown, .non_native, .native };

test "a catalog that lists vision makes image input native with or without file input" {
    for ([_]bool{ false, true }) |file_input| {
        try std.testing.expectEqual(Support.native, supportFromCatalog(.{ .listed = .{ .vision = true, .file_input = file_input } }));
        try std.testing.expectEqual(Support.non_native, supportFromCatalog(.{ .listed = .{ .vision = false, .file_input = file_input } }));
    }
    try std.testing.expectEqual(Support.unknown, supportFromCatalog(.down));
    try std.testing.expectEqual(Support.unknown, supportFromCatalog(.missing));
}

/// The request a step decided: the event's own request, or the one a reply
/// answered.
fn decidedRequest(before: State, event: Event) ?Request {
    return switch (event) {
        .turn_started => null,
        .request_ready => |request| if (before.pending == null) request else null,
        .capabilities_resolved => before.pending,
    };
}

/// The laws of `tests/tla/image_route/spec/ImageRoute.tla` that one step
/// shows, checked on what `step` returned for `event` from `before`. The
/// fuzz target and the seeded test run every step through it, so
/// `zig build test` holds the core to the model where TLC does not run.
fn expectLaws(before: State, event: Event, out: Output) !void {
    const after = out.state;
    const effects = out.effects();
    const decided = decidedRequest(before, event);
    // Bounded: at most a notice, then one answer.
    try std.testing.expect(effects.len <= max_effects);
    if (effects.len == 2) try std.testing.expect(effects[0] == .notify_catalog_down and effects[1] == .send);
    for (effects) |effect| switch (effect) {
        // ResolveOnlyWhenNeeded, ResolveOncePerTurn, and PendingWaitsForReply.
        .resolve_capabilities => {
            try std.testing.expect(event == .request_ready and before.pending == null);
            try std.testing.expect(before.support == .unknown and !before.resolved and hasImages(event.request_ready));
            try std.testing.expect(after.resolved and after.pending != null);
        },
        // NotifyOnlyWhenDown and NotifyOncePerTurn.
        .notify_catalog_down => {
            const request = decided orelse return error.TestUnexpectedResult;
            try std.testing.expect(effects.len == 2 and withholdsUnknown(effects[1].send));
            try std.testing.expect(request.catalog_down and !before.notified and after.notified);
        },
        .send => |chosen| {
            const request = decided orelse return error.TestUnexpectedResult;
            // DecideOnlyWhenReady.
            try std.testing.expect(after.pending == null);
            // OneSnapshot and NativeExcludesFallback.
            try std.testing.expectEqual(after.support == .native, chosen.route == .native);
            const kinds = [_]struct { bool, ToolImages }{
                .{ request.tool_images, chosen.tool_images },
                .{ request.earlier_images, chosen.earlier_images },
            };
            for (kinds) |kind| {
                const present, const images = kind;
                // NoSilentWithhold: attached or withheld with a notice, never neither.
                try std.testing.expectEqual(present, images != .none);
                // UnknownNeverInline, OneSnapshot, and AskedBeforeUnknown.
                switch (images) {
                    .none => {},
                    .attached => try std.testing.expectEqual(Support.native, after.support),
                    .withheld_unknown => try std.testing.expect(after.support == .unknown and after.resolved),
                    .withheld_fallback => try std.testing.expect(after.support == .non_native and chosen.route == .fallback),
                    .withheld_dead_end => try std.testing.expect(after.support == .non_native and chosen.route == .unavailable),
                }
            }
            // RouteModeCoherent and RequiredWhenPending.
            try std.testing.expectEqual(chosen.route == .fallback, chosen.mode != .unavailable);
            if (chosen.route == .fallback) try std.testing.expectEqual(request.pending_images, chosen.mode == .required);
            // FailExactlyWhenUnroutable: images attached this turn always have a route.
            if (request.user_images) try std.testing.expect(chosen.route != .unavailable);
        },
        .fail => |reason| {
            const request = decided orelse return error.TestUnexpectedResult;
            try std.testing.expect(after.pending == null);
            // FailExactlyWhenUnroutable: only images attached this turn fail
            // a request, so an earlier image never blocks one.
            try std.testing.expect(request.user_images);
            switch (reason) {
                // AskedBeforeUnknown.
                .capability_unknown => try std.testing.expect(after.support == .unknown and after.resolved),
                .no_native_image => try std.testing.expect(after.support == .non_native and !request.fallback),
            }
        },
    };
    switch (event) {
        // TurnResets.
        .turn_started => try std.testing.expect(effects.len == 0 and !after.resolved and !after.notified and after.pending == null),
        // DuplicateRequestIsQuiet, and every other request is asked about or answered.
        .request_ready => try std.testing.expectEqual(before.pending != null, effects.len == 0),
        // StaleReplyIsQuiet.
        .capabilities_resolved => if (before.pending == null) {
            try std.testing.expectEqual(@as(usize, 0), effects.len);
            try std.testing.expectEqualDeep(before, after);
        },
    }
}

/// Draws for `driveCore` from a fuzzer. Each draw site passes its own hash,
/// so the fuzzer tells the draws apart.
const FuzzDraws = struct {
    smith: *std.testing.Smith,

    fn below(self: FuzzDraws, n: usize, site: u32) usize {
        return self.smith.indexWithHash(n, site);
    }

    fn flag(self: FuzzDraws, site: u32) bool {
        return self.smith.valueWithHash(bool, site);
    }
};

/// Draws for `driveCore` from a seeded generator.
const SeededDraws = struct {
    random: std.Random,

    fn below(self: SeededDraws, n: usize, _: u32) usize {
        return self.random.uintLessThan(usize, n);
    }

    fn flag(self: SeededDraws, _: u32) bool {
        return self.random.boolean();
    }
};

/// Drives the core through up to 64 events that `draws` chooses, crashes
/// included, and checks every step against the model's laws.
fn driveCore(draws: anytype) !void {
    var state: State = .{};
    const steps = 1 + draws.below(64, 1);
    for (0..steps) |_| {
        const event: Event = switch (draws.below(4, 2)) {
            0 => .{ .turn_started = all_support[draws.below(all_support.len, 3)] },
            1 => ready: {
                const user_images = draws.flag(4);
                const earlier_images = draws.flag(5);
                // Pending images are some of the images attached this turn.
                const pending_images = user_images and draws.flag(6);
                break :ready .{ .request_ready = .{
                    .user_images = user_images,
                    .earlier_images = earlier_images,
                    .pending_images = pending_images,
                    .tool_images = draws.flag(7),
                    .fallback = draws.flag(8),
                    .catalog_down = draws.flag(9),
                } };
            },
            2 => .{ .capabilities_resolved = all_support[draws.below(all_support.len, 10)] },
            else => {
                // A crash: the next process starts from the core's zero state.
                state = .{};
                continue;
            },
        };
        const out = step(state, event);
        try expectLaws(state, event, out);
        state = out.state;
    }
}

fn fuzzCore(_: void, smith: *std.testing.Smith) !void {
    try driveCore(FuzzDraws{ .smith = smith });
}

/// A fuzz corpus entry: the draws `driveCore` reads, one little-endian u64
/// each, as the fuzzer's input format holds them.
fn corpusOf(comptime values: []const u64) []const u8 {
    comptime {
        var bytes: [values.len * 8]u8 = undefined;
        for (values, 0..) |value, index| std.mem.writeInt(u64, bytes[index * 8 ..][0..8], value, .little);
        const final = bytes;
        return &final;
    }
}
