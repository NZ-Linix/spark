const std = @import("std");
const observation = @import("runtime/observation.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const image_attachments = @import("../images/image_attachments.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const model_tool_schema = @import("../tooling/model_tool_schema.zig");
const model_provider = @import("../config/model_provider.zig");
const credential_authority = @import("../auth/credential_authority.zig");
const model_context_encoding = @import("../shared/model_context_encoding.zig");

const Allocator = std.mem.Allocator;

/// Transport parser callback shapes. Provider boundaries expose `EventSink`;
/// concrete reducers may use these adapters internally.
pub const StreamCallback = *const fn (ctx: *anyopaque, chunk: []const u8) void;
/// A streamed tool call's id and its arguments so far, which may stop
/// anywhere. Both are borrowed for the call only.
pub const ToolInputProgressCallback = *const fn (ctx: *anyopaque, id: []const u8, arguments: []const u8) void;
pub const ToolStartCallback = *const fn (
    ctx: *anyopaque,
    tool_id: []const u8,
    tool_name: []const u8,
    label_value: ?[]const u8,
    arguments_json: ?[]const u8,
) void;

pub const Event = union(enum) {
    content_delta: []const u8,
    reasoning_delta: []const u8,
    tool_started: struct {
        id: []const u8,
        name: []const u8,
        label: ?[]const u8 = null,
        /// Complete arguments borrowed only for synchronous event delivery.
        arguments_json: ?[]const u8 = null,
    },
    tool_input_delta: []const u8,
    /// The arguments a streamed tool call has so far, by its id, so a row
    /// can name what the call is for before it is complete. Borrowed only
    /// for synchronous event delivery.
    tool_input_progress: struct {
        id: []const u8,
        arguments: []const u8,
    },
};

pub const EventSink = struct {
    context: *anyopaque,
    emit_fn: *const fn (context: *anyopaque, event: Event) void,

    pub fn emit(self: EventSink, event: Event) void {
        self.emit_fn(self.context, event);
    }

    // `StreamCallback` and `ToolStartCallback` adapters for transport parsers
    // whose callback context is a `*EventSink`.

    pub fn onContentChunk(context: *anyopaque, chunk: []const u8) void {
        fromContext(context).emit(.{ .content_delta = chunk });
    }

    pub fn onReasoningChunk(context: *anyopaque, chunk: []const u8) void {
        fromContext(context).emit(.{ .reasoning_delta = chunk });
    }

    pub fn onToolInputChunk(context: *anyopaque, chunk: []const u8) void {
        fromContext(context).emit(.{ .tool_input_delta = chunk });
    }

    pub fn onToolInputProgress(context: *anyopaque, id: []const u8, arguments: []const u8) void {
        fromContext(context).emit(.{ .tool_input_progress = .{ .id = id, .arguments = arguments } });
    }

    pub fn onToolStart(
        context: *anyopaque,
        id: []const u8,
        name: []const u8,
        label: ?[]const u8,
        arguments_json: ?[]const u8,
    ) void {
        fromContext(context).emit(.{ .tool_started = .{ .id = id, .name = name, .label = label, .arguments_json = arguments_json } });
    }

    fn fromContext(context: *anyopaque) *EventSink {
        return @ptrCast(@alignCast(context));
    }
};

pub const Admission = struct {
    context: ?*anyopaque = null,
    admit_fn: ?*const fn (context: *anyopaque) anyerror!void = null,

    /// Providers call this exactly once after request serialization and
    /// validation succeed, immediately before delivery can become possible.
    pub fn admit(self: Admission) !void {
        const admit_fn = self.admit_fn orelse return error.ProviderAdmissionMissing;
        try admit_fn(self.context orelse return error.ProviderAdmissionMissing);
    }
};

/// Monotonic evidence for whether a request could have reached its provider.
/// Core uses it to distinguish safe retries from potentially billed delivery.
pub const DeliveryCertainty = struct {
    state: std.atomic.Value(State) = .init(.definitely_unsent),

    pub const State = enum(u8) {
        definitely_unsent,
        possibly_sent,
    };

    pub fn init() DeliveryCertainty {
        return .{};
    }

    pub fn markPossiblySent(self: *DeliveryCertainty) void {
        self.state.store(.possibly_sent, .seq_cst);
    }

    pub fn load(self: *const DeliveryCertainty) State {
        return self.state.load(.seq_cst);
    }
};

/// Selects the layer that owns retries for a provider request.
/// Agent-owned model attempts must not be retried again by the transport.
pub const ProviderAttemptOwner = enum {
    transport,
    agent,
};

pub const NetworkFailureCause = enum {
    transport_interrupted,
    /// The network path is provably down (refused, unreachable, DNS). Nothing
    /// was sent; probing it costs nothing and never consumes a provider
    /// attempt.
    connectivity_lost,
    /// The stream produced no bytes past the stall threshold. Positive
    /// evidence that this exchange is dead; restarting it is the recovery.
    stream_stalled,
    /// The server answered, but an event in its stream was not JSON, as if
    /// damaged on the way. Resent a few times; a server that keeps sending
    /// one ends the turn.
    unreadable_reply,
};

/// Stable native transport evidence consumed by model recovery policy.
/// Providers that cannot distinguish failure stages leave this unset.
pub const NetworkFailureEvidence = struct {
    cause: NetworkFailureCause,
    delivery: DeliveryCertainty.State,
};

pub const AttemptEvidence = struct {
    provider_admitted: bool = false,
    network_failure: ?NetworkFailureEvidence = null,
};

/// Gives a cooperative single-threaded host a chance to publish UI and runtime
/// state while provider transport remains pending.
pub const CooperativePulse = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque) anyerror!void,

    pub fn pulse(self: CooperativePulse) anyerror!void {
        try self.run(self.ctx);
    }
};

pub const VisionMode = enum {
    unavailable,
    optional,
    required,
};

pub const BuildBudget = struct {
    deadline: ?std.Io.Clock.Timestamp = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

pub const StructuredResponseFormat = struct {
    name: []const u8,
    description: []const u8,
    schema: std.json.Value,
};

pub const DynamicFunctionTool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: std.json.Value,
    mcp_binding: ?types.McpToolBinding = null,
};

pub const ToolSelection = struct {
    registry: tool_dispatch.Registry = .{},
    advertised_names: []const []const u8 = &.{},
    advertised_functions: []const model_tool_schema.FunctionSchema = &.{},
    additional_functions: []const model_tool_schema.FunctionSchema = &.{},
    selected_dynamic: []const DynamicFunctionTool = &.{},

    pub fn advertisedFunction(self: ToolSelection, name: []const u8) ?model_tool_schema.FunctionSchema {
        for (self.advertised_functions) |function| {
            if (std.mem.eql(u8, function.name, name)) return function;
        }
        return null;
    }
};

pub const CredentialLease = types.CredentialLease;

test "host-managed credential lease exposes no secret or account metadata" {
    const lease: CredentialLease = .host_managed;
    try std.testing.expect(lease.secret() == null);
    try std.testing.expect(lease.accountId() == null);
    try std.testing.expect(lease.tenant() == null);
    try std.testing.expectEqual(types.CredentialSource.host_managed, lease.credentialSource().?);
}

/// Pure provider input used by request serializers and permission reviewers.
/// Every slice and JSON value is borrowed for the call.
pub const RequestData = struct {
    model: []const u8,
    instructions: []const types.ChatMessage = &.{},
    messages: []const types.ChatMessage,
    tools: ToolSelection = .{},
    tool_choice: types.ToolChoice,
    vision_mode: VisionMode = .unavailable,
    provider_options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: ?u32 = null,
    budget: ?BuildBudget = null,
    verified_images: ?[]const image_attachments.VerifiedSnapshot = null,
    response_format: ?StructuredResponseFormat = null,

    pub fn validatePrompt(self: RequestData) error{InvalidProviderPrompt}!void {
        try validate_prompt_lanes(self.instructions, self.messages);
    }
};

pub fn validate_prompt_lanes(
    instructions: []const types.ChatMessage,
    messages: []const types.ChatMessage,
) error{InvalidProviderPrompt}!void {
    for (instructions) |instruction| {
        if (instruction.role != .system or
            instruction.content == null or
            instruction.images.len != 0 or
            instruction.tool_call_id != null or
            instruction.tool_name != null or
            instruction.tool_calls.len != 0 or
            instruction.provider_replay != null or
            instruction.tool_result_status != null or
            instruction.tool_result_memory != null or
            instruction.permission_feedback or
            instruction.context_note)
        {
            return error.InvalidProviderPrompt;
        }
    }
    for (messages) |message| {
        // Context notes ride on a tool result by the time a request is sent
        // (`carryContextNotes`), so the messages lane has no system message (D93).
        if (message.role == .system or message.context_note) return error.InvalidProviderPrompt;
    }
}

/// `messages` as every provider gets them (D93). Each context note joins the
/// end of the last tool result of the step before it, past that step's
/// permission feedback, so the rules ride on the message that reached them
/// and no provider sees a system message inside the conversation. Every
/// carried tag in tool output (`model_context_encoding.writeCarriedEscaped`)
/// starts with `&lt;` instead, so only spark can open those blocks there. The
/// note itself is not escaped: its writers escape the text they take in. A note with no tool result before it joins the user
/// message right before it: the note a resumed turn starts with joins that
/// turn's own message, and a saved turn rebuilds the same order, so a resume
/// sends the same bytes. After any other message, which only a compaction that
/// removed the note's step leaves, it is sent as a user message of its own, so
/// its rules stay in view.
/// Returns `messages` when nothing changes, otherwise a copy in `arena`.
pub fn carryContextNotes(arena: Allocator, messages: []const types.ChatMessage) Allocator.Error![]const types.ChatMessage {
    const changes = for (messages) |message| {
        if (message.context_note) break true;
        if (message.role == .tool) if (message.content) |content| if (model_context_encoding.hasCarriedTag(content)) break true;
    } else false;
    if (!changes) return messages;
    var carried: std.ArrayList(types.ChatMessage) = try .initCapacity(arena, messages.len);
    // Index in `carried` of the tool result a note at this point joins.
    var carrier: ?usize = null;
    for (messages) |message| {
        if (message.context_note) {
            const index = carrier orelse joins: {
                if (carried.items.len > 0) {
                    const previous = carried.items[carried.items.len - 1];
                    if (previous.role == .user and !previous.permission_feedback) break :joins carried.items.len - 1;
                }
                const bytes = if (message.content) |content| content.len else 0;
                debug_trace.logf("agent", "context_note_sent_alone reason=no_tool_result_or_user_message_before_it bytes={d}", .{bytes});
                carried.appendAssumeCapacity(.{ .role = .user, .content = message.content });
                continue;
            };
            const result = &carried.items[index];
            const note = message.content orelse "";
            result.content = if (result.content) |output| try std.mem.concat(arena, u8, &.{ output, "\n\n", note }) else note;
            continue;
        }
        var sent = message;
        if (message.role == .tool) {
            if (message.content) |content| sent.content = try model_context_encoding.escapeCarried(arena, content);
            carrier = carried.items.len;
        } else if (!(message.role == .user and message.permission_feedback)) {
            carrier = null;
        }
        carried.appendAssumeCapacity(sent);
    }
    return carried.items;
}

/// Borrowed typed request. Providers own validation, wire serialization,
/// endpoint selection, headers, HTTP, and stream reduction.
pub const ModelRequest = struct {
    observer: ?*observation.Observer = null,
    parent_call_id: ?[]const u8 = null,
    purpose: observation.ModelPurpose = .agent,
    credential: types.CredentialLease,
    session_id: ?[]const u8 = null,
    model: []const u8,
    retry_count: usize,
    instructions: []const types.ChatMessage = &.{},
    messages: []const types.ChatMessage,
    tools: ToolSelection = .{},
    tool_choice: types.ToolChoice,
    vision_mode: VisionMode = .unavailable,
    provider_options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: ?u32 = null,
    budget: ?BuildBudget = null,
    verified_images: ?[]const image_attachments.VerifiedSnapshot = null,
    response_format: ?StructuredResponseFormat = null,
    /// Exact provider body already built for capacity measurement. Borrowed
    /// for this call and valid until `stream` returns.
    prepared_request_body: ?[]const u8 = null,
    trace_ctx: debug_trace.TraceContext,
    content_capture_limit: ?usize,
    /// Optional absolute provider deadline. Transports that support bounded
    /// execution must stop in-flight I/O before returning `error.Timeout`.
    deadline: ?std.Io.Clock.Timestamp = null,
    cooperative_pulse: ?CooperativePulse = null,
    delivery: *DeliveryCertainty,
    attempt_evidence: *AttemptEvidence,
    events: EventSink,
    admission: Admission = .{},
    cancel_flag: *std.atomic.Value(bool),
    provider_attempt_owner: ProviderAttemptOwner = .transport,

    pub fn data(self: ModelRequest) RequestData {
        return .{
            .model = self.model,
            .instructions = self.instructions,
            .messages = self.messages,
            .tools = self.tools,
            .tool_choice = self.tool_choice,
            .vision_mode = self.vision_mode,
            .provider_options = self.provider_options,
            .max_output_tokens = self.max_output_tokens,
            .budget = self.budget,
            .verified_images = self.verified_images,
            .response_format = self.response_format,
        };
    }
};

pub const ResultOwnership = enum {
    borrowed,
    owned,
};

pub const FailureKind = enum {
    invalid_request,
    unauthorized,
    forbidden,
    request_too_large,
    rate_limited,
    /// A 429 whose body names a used-up quota or spend cap: waiting does not
    /// restore it, so spark does not resend.
    quota_exhausted,
    server_error,
    bad_gateway,
    unavailable,
    gateway_timeout,
    provider_error,

    /// Classifies a provider's HTTP error status.
    pub fn fromHttpStatus(status: std.http.Status) FailureKind {
        return switch (status) {
            .bad_request => .invalid_request,
            .unauthorized => .unauthorized,
            .forbidden => .forbidden,
            .payload_too_large => .request_too_large,
            .too_many_requests => .rate_limited,
            .internal_server_error => .server_error,
            .bad_gateway => .bad_gateway,
            .service_unavailable => .unavailable,
            .gateway_timeout => .gateway_timeout,
            else => if (types.isRetryableServerStatus(@backingInt(status))) .server_error else .provider_error,
        };
    }
};

pub const FailureDiagnostics = struct {
    schema: ?[]u8 = null,
    request_shape: ?[]u8 = null,
};

pub const Completed = struct {
    completion: types.ModelCompletion = .{},
    ownership: ResultOwnership = .borrowed,
};

pub const Failure = struct {
    kind: FailureKind,
    detail: ?[]u8 = null,
    diagnostics: FailureDiagnostics = .{},
    retry_after_seconds: ?u64 = null,
    /// The response's own status, so messages name the code it sent.
    http_status: ?std.http.Status = null,
    ownership: ResultOwnership = .borrowed,
};

/// Whether the provider refused the request as longer than the model's
/// context window, in any family's wording.
///
/// The phrases match anywhere in the detail, because only OpenAI-style bodies
/// carry `code: "context_length_exceeded"`. Gateway, Anthropic and xAI send
/// only text, and a Gateway multi-attempt body holds it only under
/// `providerAttempts[].error`. So a rare refusal for another cause that quotes
/// one of these phrases counts as an overflow: the main request compacts once
/// and retries, and the compactor sends up to three smaller requests.
pub fn isContextOverflow(failure: Failure) bool {
    if (failure.kind == .request_too_large) return true;
    if (failure.kind != .invalid_request) return false;
    const detail = failure.detail orelse return false;
    inline for (.{
        "context_length_exceeded",
        "exceeds the context window",
        "exceeded the context window",
        "maximum context length",
        "maximum prompt length",
        "input is too long",
        "prompt is too long",
        "too many input tokens",
    }) |needle| {
        if (text_utils.containsIgnoreCase(detail, needle)) return true;
    }
    return false;
}

pub const Result = union(enum) {
    completed: Completed,
    failed: Failure,

    /// Returns a fully owned copy, including diagnostics.
    /// The caller releases it with deinit using the same allocator.
    pub fn dupe(self: Result, alloc: Allocator) Allocator.Error!Result {
        switch (self) {
            .failed => |failure| {
                var copy = Result{ .failed = failure };
                copy.failed.ownership = .owned;
                copy.failed.detail = null;
                copy.failed.diagnostics = .{};
                errdefer copy.deinit(alloc);
                if (failure.detail) |value| copy.failed.detail = try alloc.dupe(u8, value);
                if (failure.diagnostics.schema) |value| copy.failed.diagnostics.schema = try alloc.dupe(u8, value);
                if (failure.diagnostics.request_shape) |value| copy.failed.diagnostics.request_shape = try alloc.dupe(u8, value);
                return copy;
            },
            .completed => |completed| {
                var copy = Result{ .completed = completed };
                copy.completed.ownership = .owned;
                const dst = &copy.completed.completion;
                const src = completed.completion;
                const strings = .{ "content", "generation_id", "resolved_provider", "provider_failure_detail", "provider_state_json" };
                inline for (strings) |field| @field(dst, field) = null;
                dst.tool_calls = &.{};
                errdefer copy.deinit(alloc);
                inline for (strings) |field| {
                    if (@field(src, field)) |value| @field(dst, field) = try alloc.dupe(u8, value);
                }
                dst.tool_calls = try types.dupeToolCallSlice(alloc, src.tool_calls);
                return copy;
            },
        }
    }

    /// Providers mark allocated response fields as `owned`; test and embedded
    /// providers may return stable borrowed fields instead.
    pub fn deinit(self: *Result, alloc: Allocator) void {
        switch (self.*) {
            .completed => |completed| if (completed.ownership == .owned) {
                if (completed.completion.content) |content| alloc.free(@constCast(content));
                if (completed.completion.generation_id) |id| alloc.free(@constCast(id));
                if (completed.completion.resolved_provider) |provider| alloc.free(@constCast(provider));
                types.freeToolCallSlice(alloc, @constCast(completed.completion.tool_calls));
                if (completed.completion.provider_failure_detail) |detail| alloc.free(@constCast(detail));
                if (completed.completion.provider_state_json) |state| alloc.free(@constCast(state));
            },
            .failed => |failure| if (failure.ownership == .owned) {
                if (failure.detail) |detail| alloc.free(detail);
                if (failure.diagnostics.schema) |schema| alloc.free(schema);
                if (failure.diagnostics.request_shape) |shape| alloc.free(shape);
            },
        }
        self.* = undefined;
    }
};

pub inline fn failResult(err: anytype) @TypeOf(err)!Result {
    return @errorCast(failResultDynamic(err));
}

noinline fn failResultDynamic(err: anyerror) anyerror!Result {
    return err;
}

pub const StreamFn = *const fn (
    context: ?*anyopaque,
    alloc: Allocator,
    request: ModelRequest,
) anyerror!Result;

pub const BuildRequestFn = *const fn (
    context: ?*anyopaque,
    alloc: Allocator,
    request: RequestData,
) anyerror![]u8;

pub const Provider = struct {
    /// When set, context must remain valid until every in-flight `stream` returns.
    context: ?*anyopaque = null,
    stream_fn: StreamFn,
    /// Optional exact provider serializer used for request-capacity decisions.
    build_request_fn: ?BuildRequestFn = null,
    /// Pure provider-owned slicing when one reply becomes separate history units.
    project_replay_fn: ?*const fn (Allocator, ?types.ProviderReplay, []const types.ToolCall, bool, bool) anyerror!?types.ProviderReplay = null,
    /// The largest request body this provider's transport can carry, when it
    /// has its own limit below any provider's.
    max_request_bytes: ?usize = null,
    /// Borrows unchanged payloads; projected payloads live in the caller's arena.
    pub fn projectReplay(self: Provider, arena: Allocator, replay: ?types.ProviderReplay, calls: []const types.ToolCall, text: bool, reasoning: bool) !?types.ProviderReplay {
        if (replay == null) return null;
        const project = self.project_replay_fn orelse return error.ProviderReplayProjectionUnavailable;
        return project(arena, replay, calls, text, reasoning);
    }

    pub fn stream(self: Provider, alloc: Allocator, request: ModelRequest) !Result {
        try request.data().validatePrompt();
        return self.stream_fn(self.context, alloc, request);
    }

    /// Returns an owned provider request body when this provider exposes its
    /// serializer. The caller owns the returned allocation.
    pub fn buildRequest(
        self: Provider,
        alloc: Allocator,
        request: RequestData,
    ) !?[]u8 {
        try request.validatePrompt();
        const build = self.build_request_fn orelse return null;
        return try build(self.context, alloc, request);
    }
};

fn unavailableStream(_: ?*anyopaque, _: Allocator, _: ModelRequest) anyerror!Result {
    return failResult(error.AgentStreamProviderUnavailable);
}

pub const unavailable_provider = Provider{
    .stream_fn = unavailableStream,
};
