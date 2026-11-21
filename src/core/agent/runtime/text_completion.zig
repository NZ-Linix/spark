//! Asks a model once for text: one system message and one user message, no
//! tools, or one more user message after a conversation sent exactly as the
//! agent was about to send it. Also offers a conversation's connection to
//! spark-compactor as its model caller.

const std = @import("std");
const observation = @import("observation.zig");
const model_call_record = @import("model_call_record.zig");
const agent_stream_provider = @import("../stream_provider.zig");
const runtime_gateway_step = @import("gateway_step.zig");
const compactor = @import("../../compactor/compactor.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const model_provider = @import("../../config/model_provider.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const text_utils = @import("../../shared/text_utils.zig");
const types = @import("../../shared/types.zig");
const io_mod = @import("../../shared/io.zig");
const secret = @import("../../auth/secret.zig");
const runtime_deps = @import("deps.zig");
const credential_renewal = @import("credential_renewal.zig");

const Allocator = std.mem.Allocator;

pub const Request = struct {
    observer: ?*observation.Observer = null,
    purpose: observation.ModelPurpose = .auxiliary,
    stream_provider: agent_stream_provider.Provider,
    cooperative_pulse: ?agent_stream_provider.CooperativePulse = null,
    credential: agent_stream_provider.CredentialLease,
    session_id: ?[]const u8 = null,
    model: []const u8,
    retry_count: usize,
    cancel_flag: *std.atomic.Value(bool),
    provider_options: model_capabilities.ResolvedProviderOptions = .{},
    max_output_tokens: ?u32 = null,
    /// Longest text kept; a longer reply counts as truncated.
    max_bytes: usize,
    trace_ctx: debug_trace.TraceContext,
    /// Receives the text kept, chunk by chunk, as it arrives.
    on_text: ?compactor.TextSink = null,
    system: []const u8,
    user: []const u8,
    /// When set, `user` follows this request's messages, sent with its
    /// instructions, tools and tool choice unchanged, so the provider can
    /// reuse what it cached of them; `system` is not sent. Borrowed.
    conversation: ?agent_stream_provider.RequestData = null,
    /// Receives what the provider reported the request used.
    usage_out: ?*types.Usage = null,
    /// Takes the request's record once it settles, for Ctrl+O.
    model_calls: ?model_call_record.Sink = null,
};

pub const Reason = enum {
    /// The request did not complete.
    transport,
    /// The provider answered with an error.
    provider,
    /// The model called a tool instead of answering.
    tool_call,
    /// The model stopped before finishing, for example at its output limit.
    incomplete,
    /// The reply was longer than `max_bytes`, or not valid UTF-8.
    truncated,
};

pub const Outcome = union(enum) {
    /// Allocated with the caller's allocator.
    text: []u8,
    /// No usable text. `detail` names the cause in `key=value` form, safe to
    /// trace; allocated with the caller's allocator. `unauthorized` when the
    /// provider rejected the credential with 401, `context_overflow` when it
    /// refused the request as longer than the model's context window.
    failed: struct { reason: Reason, detail: []u8, unauthorized: bool = false, context_overflow: bool = false },
};

pub const Error = error{ Cancelled, OutOfMemory };

/// What a request was for, as its call record names it. Only the
/// compactor reports its requests (`CompactorCaller`).
fn callPurpose(purpose: observation.ModelPurpose) types.ModelCallPurpose {
    return if (purpose == .compaction) .compaction else .turn;
}

/// Sends `request` and waits for the whole reply.
pub fn complete(alloc: Allocator, request: Request) Error!Outcome {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const instructions = [_]types.ChatMessage{.{ .role = .system, .content = request.system }};
    const user: types.ChatMessage = .{ .role = .user, .content = request.user };
    const alone = [_]types.ChatMessage{user};
    const conversation = request.conversation;
    const messages: []const types.ChatMessage = if (conversation) |sent| joined: {
        const all = try alloc.alloc(types.ChatMessage, sent.messages.len + 1);
        @memcpy(all[0..sent.messages.len], sent.messages);
        all[sent.messages.len] = user;
        break :joined all;
    } else &alone;
    defer if (conversation != null) alloc.free(messages);
    var capture = StreamCapture{ .alloc = alloc, .max_bytes = request.max_bytes, .on_text = request.on_text };
    defer capture.deinit();
    var delivery = runtime_gateway_step.DeliveryCertainty.init();
    var attempt_evidence: agent_stream_provider.AttemptEvidence = .{};
    const started_ms = io_mod.milliTimestamp();
    var streamed = runtime_gateway_step.streamModelCompletion(
        request.stream_provider,
        alloc,
        .{
            .observer = request.observer,
            .purpose = request.purpose,
            .credential = request.credential,
            .session_id = request.session_id,
            .model = request.model,
            .retry_count = request.retry_count,
            .instructions = if (conversation) |sent| sent.instructions else &instructions,
            .messages = messages,
            .tools = if (conversation) |sent| sent.tools else .{},
            .tool_choice = if (conversation) |sent| sent.tool_choice else .none,
            .vision_mode = if (conversation) |sent| sent.vision_mode else .unavailable,
            .verified_images = if (conversation) |sent| sent.verified_images else null,
            .provider_options = request.provider_options,
            .max_output_tokens = request.max_output_tokens,
            .budget = .{ .cancel_flag = request.cancel_flag },
            .content_capture_limit = request.max_bytes,
            .delivery = &delivery,
            .attempt_evidence = &attempt_evidence,
            .events = .{ .context = &capture, .emit_fn = onEvent },
            .admission = .{},
            .cancel_flag = request.cancel_flag,
            .trace_ctx = request.trace_ctx,
            .cooperative_pulse = request.cooperative_pulse,
        },
    ) catch |err| {
        if (request.model_calls) |sink| sink.record(model_call_record.ofError(
            sink.provider,
            request.model,
            callPurpose(request.purpose),
            started_ms,
            io_mod.milliTimestamp(),
            err == error.Cancelled,
            err,
        ));
        return switch (err) {
            error.Cancelled => error.Cancelled,
            error.OutOfMemory => error.OutOfMemory,
            else => failed(alloc, .transport, "err={s}", .{@errorName(err)}),
        };
    };
    defer streamed.deinit(alloc);
    if (request.model_calls) |sink| sink.record(model_call_record.ofResult(
        sink.provider,
        request.model,
        callPurpose(request.purpose),
        started_ms,
        io_mod.milliTimestamp(),
        &streamed,
        request.cancel_flag.load(.seq_cst),
    ));
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const completion = switch (streamed) {
        .failed => |failure| {
            // Provider error bodies are third-party text: mask secrets and
            // neutralize control bytes before the detail reaches /trace.
            const detail = failure.detail orelse "";
            const masked = text_utils.maskSecrets(alloc, detail) catch return error.OutOfMemory;
            // `maskSecrets` returns `detail` itself when it masks nothing, and
            // `streamed` frees that.
            defer if (masked.ptr != detail.ptr) alloc.free(masked);
            var detail_buf: [512]u8 = undefined;
            const safe_detail = debug_trace.preview(debug_trace.terminalPreview(&detail_buf, masked), 240);
            var outcome = try failed(alloc, .provider, "kind={s} detail={s}", .{ @tagName(failure.kind), safe_detail });
            outcome.failed.unauthorized = failure.kind == .unauthorized;
            outcome.failed.context_overflow = agent_stream_provider.isContextOverflow(failure);
            return outcome;
        },
        .completed => |completed| completed.completion,
    };
    if (request.usage_out) |usage| usage.* = completion.usage;
    if (capture.failed) return error.OutOfMemory;
    if (!capture.saw_content) if (completion.content) |content| capture.append(content) catch return error.OutOfMemory;
    if (capture.saw_tool_call or completion.tool_calls.len > 0) return failed(alloc, .tool_call, "", .{});
    if (completion.finish_reason != .stop) {
        return failed(alloc, .incomplete, "finish_reason={s} bytes={d}", .{ if (completion.finish_reason) |reason| @tagName(reason) else "missing", capture.text.items.len });
    }
    if (capture.observed_bytes > capture.text.items.len or !std.unicode.utf8ValidateSlice(capture.text.items)) {
        return failed(alloc, .truncated, "bytes={d}", .{capture.observed_bytes});
    }
    return .{ .text = try alloc.dupe(u8, capture.text.items) };
}

fn failed(alloc: Allocator, reason: Reason, comptime fmt: []const u8, args: anytype) Error!Outcome {
    return .{ .failed = .{ .reason = reason, .detail = try alloc.print(fmt, args) } };
}

const StreamCapture = struct {
    alloc: Allocator,
    max_bytes: usize,
    text: std.ArrayList(u8) = .empty,
    observed_bytes: usize = 0,
    saw_content: bool = false,
    saw_tool_call: bool = false,
    failed: bool = false,
    on_text: ?compactor.TextSink = null,

    fn deinit(self: *StreamCapture) void {
        self.text.deinit(self.alloc);
    }

    fn append(self: *StreamCapture, chunk: []const u8) !void {
        self.saw_content = self.saw_content or chunk.len > 0;
        self.observed_bytes +|= chunk.len;
        const room = self.max_bytes -| self.text.items.len;
        const kept = chunk[0..@min(chunk.len, room)];
        try self.text.appendSlice(self.alloc, kept);
        if (self.on_text) |sink| if (kept.len > 0) sink.write(kept);
    }
};

fn onEvent(raw: *anyopaque, event: agent_stream_provider.Event) void {
    const capture: *StreamCapture = @ptrCast(@alignCast(raw));
    switch (event) {
        .content_delta => |chunk| capture.append(chunk) catch {
            capture.failed = true;
        },
        .tool_started => capture.saw_tool_call = true,
        .reasoning_delta, .tool_input_delta, .tool_input_progress => {},
    }
}

/// A conversation's connection to its model, offered to spark-compactor. Its own
/// options and output limit apply to its own model; another model keeps the
/// provider routing and prompt caching but gets only the reasoning asked for
/// and its own output limit. A request after the conversation keeps the
/// conversation's options except Ultrafast, which is reserved for agent turns.
pub const CompactorCaller = struct {
    observer: ?*observation.Observer = null,
    stream_provider: agent_stream_provider.Provider,
    cooperative_transport_pulse: ?agent_stream_provider.CooperativePulse = null,
    provider: model_provider.ProviderId,
    /// The conversation's model.
    model: []const u8,
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]const u8 = null,
    gateway_team: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    retry_count: usize,
    provider_options: model_capabilities.ResolvedProviderOptions = .{},
    max_output_tokens: ?u32 = null,
    /// What each model accepts.
    capabilities_context: *anyopaque,
    capabilities_fn: *const fn (context: *anyopaque, model: []const u8) model_capabilities.Capabilities,
    /// The request the agent was about to send. A request after the
    /// conversation repeats it unchanged before its own message. Borrowed.
    conversation: ?agent_stream_provider.RequestData = null,
    /// Takes each request's record once it settles, for Ctrl+O.
    model_calls: ?model_call_record.Sink = null,
    /// Renews the credential once after the provider rejects it with 401, as
    /// an agent turn does (`credential_renewal.renewRejected`). Null when the
    /// caller cannot renew it. Must outlive the compaction.
    renewal_deps: ?*const runtime_deps.AgentRuntimeDeps = null,
    /// The renewed credential `api_key` and `gateway_team` point to once
    /// renewed, in `std.heap.c_allocator`, and how it was renewed. `deinit`
    /// frees it unless `takeRenewed` took it.
    renewed: ?Renewed = null,
    renewal_tried: bool = false,

    pub const Renewed = struct {
        credential: runtime_deps.RefreshedGatewayCredential,
        mode: runtime_deps.CredentialRefreshMode,
    };

    pub fn deinit(self: *CompactorCaller) void {
        if (self.renewed) |renewed| credential_renewal.free(std.heap.c_allocator, renewed.credential);
        self.renewed = null;
    }

    /// The renewed credential, now the caller's, in `std.heap.c_allocator`:
    /// an agent turn sends it from then on. `api_key` and `gateway_team` still
    /// point to it, so call this once the compaction is over.
    pub fn takeRenewed(self: *CompactorCaller) ?Renewed {
        const renewed = self.renewed orelse return null;
        self.renewed = null;
        return renewed;
    }

    /// Borrows `self`, which must outlive the compaction.
    pub fn caller(self: *CompactorCaller) compactor.ModelCaller {
        return .{
            .context = self,
            .vtable = &.{ .capabilities = capabilities, .send = send },
            .model = self.model,
            .provider = self.provider,
            .credential_source = self.credential_source,
            .sends_after_conversation = self.conversation != null,
            .fallback_model = null,
        };
    }

    fn capabilities(context: *anyopaque, model: []const u8) model_capabilities.Capabilities {
        const self: *CompactorCaller = @ptrCast(@alignCast(context));
        return self.capabilities_fn(self.capabilities_context, model);
    }

    fn completeCall(
        self: *CompactorCaller,
        alloc: Allocator,
        call: compactor.Call,
        conversation: ?agent_stream_provider.RequestData,
        options: model_capabilities.ResolvedProviderOptions,
        usage: *types.Usage,
    ) Error!Outcome {
        const own = std.mem.eql(u8, call.model, self.model);
        return complete(alloc, .{
            .observer = self.observer,
            .purpose = .compaction,
            .stream_provider = self.stream_provider,
            .cooperative_pulse = self.cooperative_transport_pulse,
            .credential = if (self.credential_source == .host_managed) .host_managed else .{ .direct = .{
                .secret_bytes = self.api_key,
                .source = self.credential_source,
                .account_id = self.account_id,
                .tenant_context = self.gateway_team,
            } },
            .session_id = self.session_id,
            .model = call.model,
            .retry_count = self.retry_count,
            .cancel_flag = call.cancel_flag,
            .provider_options = options,
            .max_output_tokens = if (own) self.max_output_tokens else model_capabilities.requestOutputTokens(self.capabilities_fn(self.capabilities_context, call.model)),
            .max_bytes = call.max_bytes,
            .trace_ctx = call.trace_ctx,
            .on_text = call.on_text,
            .system = call.system,
            .user = call.user,
            .conversation = conversation,
            .usage_out = usage,
            .model_calls = self.model_calls,
        });
    }

    /// After a 401: the stored credential, or a forced refresh while the store
    /// still holds the rejected one. Once per compaction. Returns whether the
    /// call can be sent again.
    fn renewCredential(self: *CompactorCaller, trace_ctx: debug_trace.TraceContext) Error!bool {
        const deps = self.renewal_deps orelse return false;
        if (self.renewal_tried) return false;
        self.renewal_tried = true;
        const alloc = std.heap.c_allocator;
        const rejected = try alloc.dupe(u8, self.api_key);
        defer secret.zeroAndFree(alloc, rejected);
        const renewal = try credential_renewal.renewRejected(deps, alloc, .{ .source = self.credential_source, .account_id = self.account_id }, rejected, trace_ctx);
        // Only the newest credential is kept. It is kept even when it is the
        // rejected token, as an agent turn keeps it: the host's reload can
        // free the credential this caller borrowed, as ACP's does, so a later
        // send must use bytes of its own.
        if (renewal.forced != null) if (renewal.stored) |stored| credential_renewal.free(alloc, stored);
        const newest = renewal.newest() orelse return false;
        self.renewed = .{ .credential = newest, .mode = if (renewal.forced != null) .force else .reload };
        self.api_key = newest.token;
        // A team the host now sends with the login, such as one the user
        // picked, goes with the next send too.
        if (newest.gateway_team) |team| self.gateway_team = team;
        return renewal.resend;
    }

    fn send(context: *anyopaque, alloc: Allocator, call: compactor.Call) compactor.CallError!compactor.Reply {
        const self: *CompactorCaller = @ptrCast(@alignCast(context));
        const own = std.mem.eql(u8, call.model, self.model);
        // Only the conversation's own model reads it; the request is built
        // for that model.
        var conversation: ?agent_stream_provider.RequestData = null;
        if (call.after_conversation) {
            if (!own or self.conversation == null) return .{ .failed = .{ .reason = .provider, .detail = try alloc.dupe(u8, "kind=no_conversation") } };
            conversation = self.conversation;
        }
        // After the conversation, the agent's own options, reasoning too: the
        // provider reuses its cache only for the same settings. Another model
        // keeps the user's provider routing but none of the options chosen
        // for this one.
        var options: model_capabilities.ResolvedProviderOptions = if (conversation) |sent| sent.provider_options else if (own) self.provider_options else .{
            .prompt_caching = self.provider_options.prompt_caching,
        };
        if (conversation == null) options.reasoning = call.reasoning;
        options.ultrafast = false;
        var usage: types.Usage = .{};
        var outcome = try self.completeCall(alloc, call, conversation, options, &usage);
        // Another spark process may have renewed the sign-in since the compaction
        // read it: one more send with the renewed credential.
        if (outcome == .failed and outcome.failed.unauthorized and try self.renewCredential(call.trace_ctx)) {
            alloc.free(outcome.failed.detail);
            usage = .{};
            outcome = try self.completeCall(alloc, call, conversation, options, &usage);
        }
        compactor.traceLog(false, "compaction model call model={s} after_conversation={} input_tokens={any} cache_read_tokens={any} cache_write_tokens={any} output_tokens={any}", .{
            call.model,               call.after_conversation, usage.input_tokens, usage.cache_read_tokens,
            usage.cache_write_tokens, usage.output_tokens,
        });
        return switch (outcome) {
            .text => |text| .{ .text = text },
            .failed => |failure| .{ .failed = .{
                .reason = if (failure.context_overflow) .overflow else switch (failure.reason) {
                    .transport => .transport,
                    .provider => .provider,
                    .tool_call => .tool_call,
                    .incomplete => .incomplete,
                    .truncated => .truncated,
                },
                .detail = failure.detail,
            } },
        };
    }
};
