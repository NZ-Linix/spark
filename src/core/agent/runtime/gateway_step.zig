const std = @import("std");
const agent_stream_provider = @import("../stream_provider.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const image_route = @import("../../images/image_route.zig");
const types = @import("../../shared/types.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const gateway_error_format = @import("../../shared/gateway_error_format.zig");
const text_utils = @import("../../shared/text_utils.zig");
const io_mod = @import("../../shared/io.zig");
const runtime_telemetry = @import("telemetry.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");
const observation = @import("observation.zig");

const Allocator = std.mem.Allocator;
const TraceContext = debug_trace.TraceContext;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

pub const DeliveryCertainty = agent_stream_provider.DeliveryCertainty;
pub const AttemptEvidence = agent_stream_provider.AttemptEvidence;

pub const StreamResult = agent_stream_provider.Result;

/// A provider admits a request exactly once, before it can be sent.
const InvocationAdmission = struct {
    attempt_evidence: *AttemptEvidence,
    trace_ctx: TraceContext,
    model: []const u8,
    caller_admission: agent_stream_provider.Admission,
    admitted: bool = false,
    observed: ?*observation.ModelCall = null,

    fn admit(raw: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.admitted) return error.ProviderAdmissionRepeated;
        self.admitted = true;
        if (self.caller_admission.admit_fn != null) {
            try self.caller_admission.admit();
        }
        self.attempt_evidence.provider_admitted = true;
        if (self.observed) |observed| observed.emit(.{ .model_admitted = observed.id });
        debug_trace.eventf(
            "agent",
            "provider_admitted",
            self.trace_ctx,
            "model={s}",
            .{self.model},
        );
    }
};

pub fn streamModelCompletion(
    provider: agent_stream_provider.Provider,
    alloc: Allocator,
    request_value: agent_stream_provider.ModelRequest,
) !StreamResult {
    if (request_value.cancel_flag.load(.seq_cst)) {
        return agent_stream_provider.failResult(error.Cancelled);
    }
    const started_at_ms = io_mod.milliTimestamp();
    var observed = if (request_value.observer) |observer| observer.beginModelForTool(request_value.data(), request_value.purpose, request_value.parent_call_id) else null;
    var observed_events = ObservedEvents{ .upstream = request_value.events, .observed = if (observed) |*call| call else null };
    var admission = InvocationAdmission{
        .attempt_evidence = request_value.attempt_evidence,
        .trace_ctx = request_value.trace_ctx,
        .model = request_value.model,
        .caller_admission = request_value.admission,
        .observed = if (observed) |*call| call else null,
    };
    var request = request_value;
    if (observed != null) request.events = .{ .context = &observed_events, .emit_fn = ObservedEvents.emit };
    request.admission = .{ .context = &admission, .admit_fn = InvocationAdmission.admit };
    // Only the owned result escapes. HTTP and parser scratch is released after
    // every attempt, including transport failure and cancellation.
    var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer scratch.deinit();
    const request_alloc = scratch.allocator();
    var result = provider.stream(request_alloc, request) catch |err| {
        if (observed) |call| call.emit(.{ .model_end = .{ .id = call.id, .error_name = @errorName(err), .cancelled = err == error.Cancelled or request.cancel_flag.load(.seq_cst) } });
        runtime_telemetry.recordGatewayCallMetric(request.model, started_at_ms, 0, 0, 0, 0, request.trace_ctx.turn_id, request.trace_ctx.step_id, request.trace_ctx.subagent_id, @errorName(err), "");
        return err;
    };
    defer result.deinit(request_alloc);
    if (!admission.admitted) {
        if (observed) |call| call.emit(.{ .model_end = .{ .id = call.id, .error_name = "ProviderAdmissionMissing" } });
        return agent_stream_provider.failResult(error.ProviderAdmissionMissing);
    }
    if (observed) |call| call.emit(.{ .model_end = switch (result) {
        .completed => |value| .{ .id = call.id, .completion = value.completion, .cancelled = request.cancel_flag.load(.seq_cst) },
        .failed => |value| .{ .id = call.id, .error_name = @tagName(value.kind), .cancelled = request.cancel_flag.load(.seq_cst) },
    } });

    recordProviderResultMetric(request.model, started_at_ms, result, request.trace_ctx, request.credential.secret());
    return switch (result) {
        .completed => |value| if (value.ownership == .borrowed) result else try result.dupe(alloc),
        .failed => |value| if (value.ownership == .borrowed) result else try result.dupe(alloc),
    };
}

const ObservedEvents = struct {
    upstream: agent_stream_provider.EventSink,
    observed: ?*observation.ModelCall,
    fn emit(raw: *anyopaque, event: agent_stream_provider.Event) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.observed) |call| switch (event) {
            .content_delta, .reasoning_delta => |chunk| if (chunk.len > 0) {
                call.output();
            },
            .tool_started => call.output(),
            .tool_input_delta, .tool_input_progress => {},
        };
        self.upstream.emit(event);
    }
};

fn recordProviderResultMetric(
    model: []const u8,
    started_at_ms: i64,
    result: agent_stream_provider.Result,
    trace_ctx: TraceContext,
    credential: ?[]const u8,
) void {
    const completion: types.ModelCompletion = switch (result) {
        .completed => |value| value.completion,
        .failed => .{},
    };
    const failure = switch (result) {
        .completed => null,
        .failed => |value| value,
    };
    var response_bytes: u64 = 0;
    if (completion.content) |content| response_bytes += content.len;
    if (completion.provider_state_json) |state| response_bytes += state.len;
    for (completion.tool_calls) |call| {
        response_bytes += call.id.len + call.name.len + call.arguments_json.len;
        if (call.provider_result) |pr| response_bytes += pr.len;
    }
    if (failure) |value| {
        if (value.detail) |detail| response_bytes += detail.len;
    }
    const truncated_bytes: u32 = @intCast(@min(response_bytes, std.math.maxInt(u32)));
    const input_tokens = clampTokenCount(completion.usage.input_tokens);
    const output_tokens = clampTokenCount(completion.usage.output_tokens);
    const terminal_stop_reason = if (completion.finish_reason) |reason| reason.label() else "";
    const error_message: ?[]u8 = if (failure) |value| if (value.http_status) |status| if (value.detail) |detail|
        traceErrorMessage(std.heap.c_allocator, status, detail, credential) catch null
    else
        null else null else null;
    defer if (error_message) |message| std.heap.c_allocator.free(message);

    runtime_telemetry.recordGatewayCallMetricWithDiagnostics(
        model,
        started_at_ms,
        if (failure) |value| if (value.http_status) |status| @backingInt(status) else failureMetricCode(value.kind) else 200,
        truncated_bytes,
        input_tokens,
        output_tokens,
        trace_ctx.turn_id,
        trace_ctx.step_id,
        trace_ctx.subagent_id,
        "",
        terminal_stop_reason,
        .{
            .schema = if (failure) |value| value.diagnostics.schema orelse "" else "",
            .request_shape = if (failure) |value| value.diagnostics.request_shape orelse "" else "",
            .provider_stop_reason = completion.finish_reason_raw.slice(),
            .error_message = error_message orelse "",
        },
    );
}

test "gateway request scratch is released across success failure cancellation and retries" {
    const Fake = struct {
        mode: usize = 0,
        observed_starts: usize = 0,
        observed_ends: usize = 0,

        fn observe(raw: *anyopaque, _: usize, event: observation.Event) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (event) {
                .model_start => self.observed_starts += 1,
                .model_end => self.observed_ends += 1,
                else => {},
            }
        }

        fn stream(raw: ?*anyopaque, alloc: Allocator, request: agent_stream_provider.ModelRequest) !StreamResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try request.admission.admit();
            const payload = try alloc.alloc(u8, 64 * 1024);
            defer alloc.free(payload);
            @memset(payload, 'x');
            const content = try alloc.dupe(u8, "owned response");
            if (self.mode == 1 or self.mode == 2) {
                defer alloc.free(content);
                return if (self.mode == 1) error.ConnectionResetByPeer else error.Cancelled;
            }
            if (self.mode == 3) return .{ .failed = .{ .kind = .server_error, .detail = content, .ownership = .owned } };
            return .{ .completed = .{ .completion = .{ .content = content }, .ownership = .owned } };
        }

        fn emit(_: *anyopaque, _: agent_stream_provider.Event) void {}
    };
    var turn = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer turn.deinit();
    var fake: Fake = .{};
    var observer = observation.Observer{ .sink = .{ .context = &fake, .emit_fn = Fake.observe } };
    var cancel: std.atomic.Value(bool) = .init(false);
    for (0..1000) |attempt| {
        fake.mode = attempt % 4;
        var delivery = DeliveryCertainty.init();
        var evidence: AttemptEvidence = .{};
        const result = streamModelCompletion(.{ .context = &fake, .stream_fn = Fake.stream }, turn.allocator(), .{
            .observer = &observer,
            .credential = .{ .direct = .{ .secret_bytes = "fixture-key", .source = .configured } },
            .model = "fixture-model",
            .retry_count = 1,
            .messages = &.{},
            .tool_choice = .auto,
            .provider_options = .{},
            .trace_ctx = .{},
            .content_capture_limit = null,
            .delivery = &delivery,
            .attempt_evidence = &evidence,
            .events = .{ .context = &fake, .emit_fn = Fake.emit },
            .cancel_flag = &cancel,
            .provider_attempt_owner = .agent,
        });
        if (fake.mode == 1) {
            try std.testing.expectError(error.ConnectionResetByPeer, result);
        } else if (fake.mode == 2) {
            try std.testing.expectError(error.Cancelled, result);
        } else {
            var owned = try result;
            defer owned.deinit(turn.allocator());
            const content = switch (owned) {
                .completed => |completed| completed.completion.content.?,
                .failed => |failure| failure.detail.?,
            };
            try std.testing.expectEqualStrings("owned response", content);
        }
        try std.testing.expect(turn.queryCapacity() < 128 * 1024);
    }
    try std.testing.expectEqual(@as(usize, 1000), fake.observed_starts);
    try std.testing.expectEqual(fake.observed_starts, fake.observed_ends);
}

/// The provider's words for `/trace`, clipped the way spark shows them, with
/// the credential this call sent masked. Not every provider masks its error
/// body, a provider can quote the request's key back, and trace output gets
/// pasted into chats, so this masks it for every provider: in the body, and
/// again after decoding, which can undo a JSON escape. The caller owns the
/// result.
fn traceErrorMessage(alloc: Allocator, status: std.http.Status, detail: []const u8, credential: ?[]const u8) ![]u8 {
    const masked = try alloc.dupe(u8, detail);
    defer alloc.free(masked);
    if (credential) |secret| text_utils.maskLiteral(masked, secret);
    const message = try gateway_error_format.formatHttpRecoveryDiagnostic(alloc, status, masked);
    if (credential) |secret| text_utils.maskLiteral(message, secret);
    return message;
}

fn failureMetricCode(kind: agent_stream_provider.FailureKind) u16 {
    return switch (kind) {
        .invalid_request => 400,
        .unauthorized => 401,
        .forbidden => 403,
        .request_too_large => 413,
        .rate_limited, .quota_exhausted => 429,
        .server_error => 500,
        .bad_gateway => 502,
        .unavailable => 503,
        .gateway_timeout => 504,
        .provider_error => 520,
    };
}

fn clampTokenCount(value: ?u64) u32 {
    const t = value orelse return 0;
    return @intCast(@min(t, std.math.maxInt(u32)));
}

pub const VisionToolMode = agent_stream_provider.VisionMode;

pub const ToolImageProjection = struct {
    messages: []const types.ChatMessage,
    /// True when at least one stored tool image was withheld from the request.
    stripped: bool,
};

/// Projects stored tool images into the request as `disposition` says, which
/// the image route core decided (`src/core/images/image_route.zig`). Withheld
/// images stay in the session image store, and each tool message that held
/// one says why and what the model can do instead, so the next step is never
/// a dead end.
pub fn projectToolImageMessages(
    alloc: Allocator,
    messages: []const types.ChatMessage,
    disposition: image_route.ToolImages,
    text_limit: usize,
) !ToolImageProjection {
    const notice: []const u8 = switch (disposition) {
        .none, .attached => return .{ .messages = messages, .stripped = false },
        .withheld_fallback => "[Tool images were retained but not sent: this model receives image input through the vision tool, not inline. Call vision with the image file's local path to inspect it.]\n",
        .withheld_dead_end => "[Tool images were retained but not sent: this model does not accept inline images and no vision fallback is available. Ask the user to attach the image directly or switch to a vision-capable model.]\n",
        .withheld_unknown => "[Tool images were retained but not sent: spark could not confirm image input support for this model (the model is not listed in the model catalog, or the catalog is unavailable). This can recover later in the session, so a retry may succeed; otherwise ask the user to attach the image directly.]\n",
    };
    var projected: ?[]types.ChatMessage = null;
    for (messages, 0..) |message, index| {
        var memory = message.tool_result_memory orelse continue;
        if (memory.tool_images.len == 0 and memory.tool_image_handle == null) continue;
        const out = projected orelse try alloc.dupe(types.ChatMessage, messages);
        projected = out;
        memory.tool_images = &.{};
        const content = message.content orelse "";
        const keep = @import("../../config/context_limits.zig").utf8PrefixLength(content, text_limit -| notice.len);
        memory.truncated = memory.truncated or keep < content.len;
        out[index].tool_result_memory = memory;
        out[index].content = try std.mem.concat(alloc, u8, &.{ notice[0..@min(notice.len, text_limit)], content[0..keep] });
    }
    return .{ .messages = projected orelse messages, .stripped = projected != null };
}

fn freeProjection(alloc: Allocator, projection: ToolImageProjection) void {
    if (!projection.stripped) return;
    for (projection.messages) |message| alloc.free(message.content.?);
    alloc.free(projection.messages);
}

const shot_messages = [_]types.ChatMessage{.{
    .role = .tool,
    .content = "shot",
    .tool_result_memory = .{ .tool_image_handle = @constCast("image-result-x") },
}};

pub fn snapshotDynamicTools(alloc: Allocator, deps: *const @import("deps.zig").AgentRuntimeDeps, selected: *std.ArrayList(agent_stream_provider.DynamicFunctionTool)) ![]const agent_stream_provider.DynamicFunctionTool {
    var offered: std.ArrayList(agent_stream_provider.DynamicFunctionTool) = .empty;
    errdefer offered.deinit(alloc);
    const count = selected.items.len;
    for (0..count) |index| {
        const tool = selected.items[index];
        if (tool.mcp_binding) |binding| {
            const snapshot = deps.snapshot_mcp_definition orelse continue;
            switch (try snapshot(deps.ctx, alloc, tool.name, binding)) {
                .current => {},
                .unavailable => continue,
                .updated => |definition| {
                    if (!std.mem.eql(u8, definition.name, tool.name) or definition.mcp_binding == null) return error.InvalidToolSchema;
                    try recordSelectedDynamicTool(alloc, selected, definition);
                    try offered.append(alloc, selected.items[index]);
                    continue;
                },
            }
        }
        try offered.append(alloc, tool);
    }
    return offered.toOwnedSlice(alloc);
}

pub fn recordSelectedDynamicTools(alloc: Allocator, tools: *std.ArrayList(agent_stream_provider.DynamicFunctionTool), execution: ToolExecutionResult) !void {
    for (execution.retired_dynamic_tool_names) |name| {
        for (tools.items, 0..) |tool, index| {
            if (std.mem.eql(u8, name, tool.name)) {
                _ = tools.orderedRemove(index);
                break;
            }
        }
    }
    for (execution.selected_dynamic_tools) |selected| try recordSelectedDynamicTool(alloc, tools, selected);
}

/// Adds or replaces one selected MCP definition. The parsed schema is
/// allocated in `alloc`, which must outlive every step that advertises it.
pub fn recordSelectedDynamicTool(alloc: Allocator, tools: *std.ArrayList(agent_stream_provider.DynamicFunctionTool), selected: @import("../../tooling/tool_mcp_runtime.zig").SelectedTool) !void {
    const name = selected.name;
    const schema_json = selected.schema_json;
    const schema = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        schema_json,
        .{},
    );
    if (schema != .object) return error.InvalidToolSchema;
    const schema_name = schema.object.get("name") orelse return error.InvalidToolSchema;
    const description = schema.object.get("description") orelse return error.InvalidToolSchema;
    const input_schema = schema.object.get("inputSchema") orelse return error.InvalidToolSchema;
    if (schema_name != .string or description != .string or input_schema != .object or
        !std.mem.eql(u8, schema_name.string, name))
    {
        return error.InvalidToolSchema;
    }
    for (tools.items) |*existing| {
        if (std.mem.eql(u8, existing.name, name)) {
            existing.description = description.string;
            existing.input_schema = input_schema;
            existing.mcp_binding = selected.mcp_binding;
            return;
        }
    }
    try tools.append(alloc, .{ .name = name, .description = description.string, .input_schema = input_schema, .mcp_binding = selected.mcp_binding });
}

pub fn gatewayHttpErrorDetail(
    alloc: Allocator,
    status: std.http.Status,
    detail: []const u8,
    model: []const u8,
    capabilities: model_capabilities.Capabilities,
) ![]const u8 {
    if (@backingInt(status) != 413) return detail;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (detail.len > 0) try out.writer.print("{s}\n\n", .{detail});
    try out.writer.print("prompt_too_long=true\nmodel={s}\n", .{model});
    if (capabilities.context_window) |context_window| {
        try out.writer.print("context_window_tokens={d}\n", .{context_window});
    }
    if (capabilities.max_output_tokens) |max_output_tokens| {
        try out.writer.print("max_output_tokens={d}\n", .{max_output_tokens});
    }
    try out.writer.writeAll("Provider rejected the prompt as too large. Latest local tool evidence remains in session history/result handles; no local tool actions were replayed.");
    return out.toOwnedSlice();
}
