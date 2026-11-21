//! How spark-compactor asks a model for the summary: the conversation's own
//! model, with the least reasoning it accepts. If that call fails, refuses,
//! or returns nothing, the gateway tries once more with another model family.
//! A request right after the conversation instead keeps the agent's own
//! settings, reasoning too: the provider reuses its cache only for the same
//! settings. The caller of spark-compactor hands in the `ModelCaller` that
//! reaches them.

const std = @import("std");
const summarize = @import("summarize.zig");
const progress = @import("progress.zig");
const trace = @import("trace.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// A summary larger than this is not a summary; it only bounds memory.
const max_summary_bytes = 8 * 1024 * 1024;

/// Reaches the conversation's model, and other models through the same
/// provider and credential.
pub const ModelCaller = struct {
    context: *anyopaque,
    vtable: *const VTable,
    /// The conversation's model.
    model: []const u8,
    provider: model_provider.ProviderId,
    credential_source: ?types.CredentialSource,
    /// The caller can send a request right after the conversation, exactly
    /// as the agent was about to send it, so the provider can reuse what it
    /// cached of it.
    sends_after_conversation: bool = false,
    /// The model to retry the summary with when the conversation's model
    /// cannot write it, chosen by the caller, such as a model the same plan
    /// pays for. Null lets the compactor choose another model family.
    fallback_model: ?[]const u8 = null,

    pub const VTable = struct {
        /// What `model` accepts.
        capabilities: *const fn (context: *anyopaque, model: []const u8) model_capabilities.Capabilities,
        /// Sends one request and waits for the whole reply.
        send: *const fn (context: *anyopaque, alloc: Allocator, call: Call) CallError!Reply,
    };
};

/// One request: a system message and one user message, no tools. Or, with
/// `after_conversation`, the conversation as the agent sends it, with the
/// agent's own settings, then `user` as one more user message; `system` and
/// `reasoning` are not used.
pub const Call = struct {
    model: []const u8,
    reasoning: ?types.ReasoningEffort,
    system: []const u8,
    user: []const u8,
    after_conversation: bool = false,
    /// Longest reply kept; a longer one counts as truncated.
    max_bytes: usize,
    cancel_flag: *std.atomic.Value(bool),
    trace_ctx: debug_trace.TraceContext,
    /// Receives the reply's text as it arrives, so the notes can be
    /// counted while the model writes them.
    on_text: ?progress.TextSink = null,
};

pub const CallError = error{ Cancelled, OutOfMemory };

/// `overflow`: the provider refused the request as longer than the model's
/// context window.
pub const FailureReason = enum { transport, provider, overflow, tool_call, incomplete, truncated };

pub const Reply = union(enum) {
    /// Allocated with the `alloc` given to `send`.
    text: []u8,
    /// No usable text. `detail` names the cause in `key=value` form for the
    /// trace; allocated with the `alloc` given to `send`.
    failed: struct { reason: FailureReason, detail: []u8 },
};

/// The least reasoning a model accepts: `none` when it can turn reasoning
/// off, otherwise its lowest level (levels are listed lowest first). Null
/// when the model offers no levels to choose from.
fn lowestReasoningEffort(capabilities: model_capabilities.Capabilities) ?types.ReasoningEffort {
    const options = capabilities.reasoning_efforts.slice();
    for (options) |option| {
        if (option.eql(types.ReasoningEffort.literal("none"))) return option;
    }
    return if (options.len > 0) options[0] else null;
}

/// The model the summary step calls, remembering how many summaries it
/// wrote and whether it fell back.
pub const Summarizer = struct {
    caller: ModelCaller,
    cancel_flag: *std.atomic.Value(bool),
    trace_ctx: debug_trace.TraceContext,
    summaries: usize = 0,
    fallback_used: ?[]const u8 = null,
    /// Receives each reply as it streams in.
    on_text: ?progress.TextSink = null,

    pub fn model(self: *Summarizer) summarize.Model {
        return .{ .context = self, .summarize_fn = summarizeWith };
    }

    fn summarizeWith(context: *anyopaque, alloc: Allocator, prompt: summarize.Prompt) summarize.ModelError![]u8 {
        const self: *Summarizer = @ptrCast(@alignCast(context));
        self.summaries += 1;
        // Only the conversation's own model has it cached; when it fails,
        // the summary step writes the turns out instead.
        if (prompt.after_conversation) return self.ask(alloc, prompt, prompt.model);
        var primary_error: ?summarize.ModelError = null;
        if (self.ask(alloc, prompt, prompt.model)) |text| {
            if (std.mem.trim(u8, text, " \t\r\n").len > 0) return text;
            alloc.free(text);
        } else |err| {
            if (err == error.Cancelled or err == error.OutOfMemory) return err;
            primary_error = err;
        }
        // Without a fallback model, an empty reply becomes the summary
        // step's EmptySummary error.
        const fallback = self.caller.fallback_model orelse {
            if (primary_error) |err| return err;
            return alloc.dupe(u8, "");
        };
        trace.info(self.trace_ctx, .log, "fallback model={s} after={s}", .{
            fallback,
            if (primary_error) |err| @errorName(err) else "empty_summary",
        });
        self.fallback_used = fallback;
        return self.ask(alloc, prompt, fallback) catch |err| switch (err) {
            error.Cancelled, error.OutOfMemory => err,
            // A smaller request can still fit the conversation's own model.
            else => if (primary_error != null and primary_error.? == error.SummaryTooLong) error.SummaryTooLong else err,
        };
    }

    /// One summary request to `model_name`, at its lowest reasoning.
    fn ask(self: *Summarizer, alloc: Allocator, prompt: summarize.Prompt, model_name: []const u8) summarize.ModelError![]u8 {
        const caller = self.caller;
        // Each reply starts on a line of its own, whatever the one before
        // it left.
        if (self.on_text) |sink| sink.write("\n");
        const reply = try caller.vtable.send(caller.context, alloc, .{
            .model = model_name,
            .reasoning = if (prompt.after_conversation) null else lowestReasoningEffort(caller.vtable.capabilities(caller.context, model_name)),
            .system = prompt.system,
            .user = prompt.user,
            .after_conversation = prompt.after_conversation,
            .max_bytes = max_summary_bytes,
            .cancel_flag = self.cancel_flag,
            .trace_ctx = self.trace_ctx,
            .on_text = self.on_text,
        });
        const failure = switch (reply) {
            .text => |text| return text,
            .failed => |failure| failure,
        };
        defer alloc.free(failure.detail);
        switch (failure.reason) {
            .transport, .provider => trace.failure(self.trace_ctx, .summary_transport_failed, "model={s} {s}", .{ model_name, failure.detail }),
            .overflow => {
                trace.failure(self.trace_ctx, .summary_too_long, "model={s} {s}", .{ model_name, failure.detail });
                return error.SummaryTooLong;
            },
            .tool_call => trace.failure(self.trace_ctx, .summary_tool_call_rejected, "model={s}", .{model_name}),
            .incomplete => {
                trace.failure(self.trace_ctx, .summary_incomplete, "model={s} {s}", .{ model_name, failure.detail });
                return error.SummaryIncomplete;
            },
            .truncated => trace.failure(self.trace_ctx, .summary_truncated, "model={s} {s}", .{ model_name, failure.detail }),
        }
        return error.ModelFailed;
    }
};

test "lowest reasoning effort turns reasoning off when the model allows it" {
    const none = types.ReasoningEffort.literal("none");
    const low = types.ReasoningEffort.literal("low");
    const Options = model_capabilities.ReasoningEffortOptions;
    const with_off = [_]types.ReasoningEffort{ none, types.ReasoningEffort.literal("minimal"), low, types.ReasoningEffort.literal("xhigh") };
    const without_off = [_]types.ReasoningEffort{ low, types.ReasoningEffort.literal("medium"), types.ReasoningEffort.literal("xhigh"), types.ReasoningEffort.literal("max") };
    try std.testing.expect(lowestReasoningEffort(.{ .reasoning_efforts = Options.fromSlice(&with_off) }).?.eql(none));
    try std.testing.expect(lowestReasoningEffort(.{ .reasoning_efforts = Options.fromSlice(&without_off) }).?.eql(low));
    try std.testing.expect(lowestReasoningEffort(.{}) == null);
}

/// Answers from a script, recording what it was asked.
const ScriptedCaller = struct {
    replies: []const ?[]const u8,
    /// Which failed calls the provider refused as too long.
    overflow: []const bool = &.{},
    calls: std.ArrayList(Call) = .empty,

    fn caller(self: *ScriptedCaller, provider: model_provider.ProviderId) ModelCaller {
        return .{
            .context = self,
            .vtable = &.{ .capabilities = capabilities, .send = send },
            .model = "anthropic/claude-opus-5.5",
            .provider = provider,
            .credential_source = null,
        };
    }

    fn capabilities(_: *anyopaque, model_name: []const u8) model_capabilities.Capabilities {
        const levels = [_]types.ReasoningEffort{ types.ReasoningEffort.literal("low"), types.ReasoningEffort.literal("xhigh") };
        const off = [_]types.ReasoningEffort{ types.ReasoningEffort.literal("none"), types.ReasoningEffort.literal("high") };
        return .{ .reasoning_efforts = .fromSlice(if (std.mem.startsWith(u8, model_name, "openai/")) &off else &levels) };
    }

    fn send(context: *anyopaque, alloc: Allocator, call: Call) CallError!Reply {
        const self: *ScriptedCaller = @ptrCast(@alignCast(context));
        try self.calls.append(std.testing.allocator, call);
        const index = self.calls.items.len - 1;
        const too_long = index < self.overflow.len and self.overflow[index];
        const text = self.replies[index] orelse
            return .{ .failed = .{ .reason = if (too_long) .overflow else .provider, .detail = try alloc.dupe(u8, "kind=bad_request detail=refused") } };
        return .{ .text = try alloc.dupe(u8, text) };
    }
};
