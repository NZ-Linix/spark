//! What the subagent tool tells its model when it refuses a call. A refusal
//! has a code, which the transcript row reads, and one or two short sentences
//! that say what happened and what to try next, which only the model reads.
//!
//! Every refusal is a variant of `Refusal`, never a string at the call site.
//! The `switch` in `sentence` does not compile for a variant without a
//! sentence, and the tests walk every variant, so a code cannot reach the
//! model bare. A code that two causes can return takes the cause as its
//! payload, since the advice for each differs. Outcomes that carry their own
//! text, such as `feedback_capacity` and `ambiguous_model`, are not refusals
//! of this kind and stay with the code that builds them.

const std = @import("std");
const agent_frame = @import("../shared/agent_frame.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const model_contract = @import("model_contract.zig");
const profiles = @import("../profiles/profiles.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// How many open subagents a sentence names; it counts the rest.
const max_named_open: usize = 8;

pub const Refusal = union(enum) {
    // A call that does not decode or validate.
    /// Not reached by a call a model makes. The agent runtime answers arguments
    /// that are not a JSON object before the decoder runs
    /// (`argument_integrity` in `src/core/agent/runtime/orchestrator.zig`),
    /// and a toolbox run's arguments are rebuilt from a parsed object
    /// (`carriedCall` in `src/core/tooling/toolbox.zig`). Only a direct call of
    /// `decode` gets here, so that a parse failure never answers with a bare code.
    invalid_json,
    invalid_agent: AgentFault,
    invalid_message,
    invalid_instructions,
    invalid_report,
    invalid_model,
    invalid_effort,
    invalid_profile,
    invalid_parent_message,
    // A call this host cannot take.
    host_unavailable,
    caller_unavailable: CallerFault,
    wait_unavailable,
    // A message the named subagent cannot take now.
    child_busy,
    override_after_create,
    child_closing,
    child_unavailable: Unavailable,
    child_not_persistent,
    child_cancelled,
    state_unavailable,
    operation_conflict,
    queue_full: QueueFault,
    // A message to the agent that started the caller.
    no_parent: ParentFault,
    // A call the host could not carry out.
    host_failure: HostFault,

    /// The `error_code` the model and the transcript row read.
    pub fn code(self: Refusal) []const u8 {
        return @tagName(self);
    }

    /// Writes the sentences the model reads.
    fn sentence(self: Refusal, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .invalid_json => try writer.writeAll("The arguments are not valid JSON. Send one JSON object with \"action\" and the fields that action takes."),
            .invalid_agent => |fault| try writer.writeAll(switch (fault) {
                .name => agent_name_rule,
                .parent_target => "stop and close take the name of a subagent you started. \"parent\" is the agent that started you and works only with message.",
            }),
            .invalid_message => try writer.writeAll(message_rule),
            .invalid_instructions => try writer.writeAll(instructions_rule),
            .invalid_report => try writer.writeAll("report must be \"final\", \"every_turn\", or \"never\". Leave the field out to keep the rule it has, which is final until you change it."),
            .invalid_model => try writer.writeAll(model_rule),
            .invalid_effort => try writer.writeAll(effort_rule),
            .invalid_profile => try writer.writeAll(profile_rule),
            .invalid_parent_message => try writer.writeAll("A message to \"parent\" takes only message. Send it without instructions, report, model, effort or profile."),
            .host_unavailable => try writer.writeAll("Subagents are not available in this session. Do the work yourself."),
            .caller_unavailable => |fault| try writer.writeAll(switch (fault) {
                .not_owner => "Only the agent that started the subagents can message, stop, close or list them. You can still send a message to \"parent\".",
                .unidentified => "spark could not tell which agent made this call, so it was refused. Continue without it.",
            }),
            .wait_unavailable => try writer.writeAll("wait is not available here. A subagent's report arrives on its own when its work ends, so keep working or end your turn."),
            .child_busy => try writer.writeAll("The subagent is busy, and instructions can only be set while it is idle. Send the message again without instructions, or wait for its report and then send it with them."),
            .override_after_create => try writer.writeAll("model, effort and profile are fixed when a subagent is created, so this one keeps its own: send the message again without them. To change them, close it and start a new one, which loses its conversation."),
            .child_closing => try writer.writeAll("The subagent is being closed and takes no message. Once it is gone, a message to its name starts a new one, or use another name."),
            .child_unavailable => |unavailable| switch (unavailable) {
                .not_open => |named| try writeNotOpen(writer, named.agent, named.open),
                .finished => try writer.writeAll("That subagent has finished and takes no more messages. Message a new name to start another."),
            },
            .child_not_persistent => try writer.writeAll("That subagent comes from an older session and takes no messages. Message a new name to start another."),
            .child_cancelled => try writer.writeAll("The subagent's turn was cancelled before it took the message, so it was not sent. Call status, then send it again."),
            .state_unavailable => try writer.writeAll("spark could not reach the subagent's turn, so the message was not sent. Call status, then send it again."),
            .operation_conflict => try writer.writeAll("This call reuses the id of an earlier call that carried different content, so nothing was sent. Send the message again."),
            .queue_full => |fault| try writer.writeAll(switch (fault) {
                .subagent => subagent_queue_full,
                .parent => parent_queue_full,
            }),
            .no_parent => |fault| try writer.writeAll(switch (fault) {
                .none => "You have no parent agent, because you are the main agent. Say it in your reply to the user.",
                .unreachable_now => "Your parent cannot take a message now. Put it in your final reply instead.",
            }),
            .host_failure => |fault| try writer.writeAll(switch (fault) {
                .subagent_limit => subagent_limit,
                .internal => "spark hit an internal error before it could finish this call. Call status to see where your subagents stand, then try again; if it fails again, do the work yourself.",
            }),
        }
    }

    /// The refusal as the result the model reads: not ok, the sentences, and
    /// the code. Caller owns the result.
    pub fn body(self: Refusal, alloc: Allocator) Allocator.Error![]u8 {
        var text: std.Io.Writer.Allocating = .init(alloc);
        defer text.deinit();
        // An allocating writer fails only when it cannot grow.
        self.sentence(&text.writer) catch return error.OutOfMemory;
        return model_contract.encodeResultAlloc(alloc, .{
            .ok = false,
            .result = text.written(),
            .error_code = self.code(),
        }) catch return error.OutOfMemory;
    }
};

const AgentFault = enum {
    /// The name breaks the rule for subagent names.
    name,
    /// `stop` or `close` named "parent", which is no subagent of the caller's.
    parent_target,
};

const CallerFault = enum {
    /// A subagent called for what only the agent that started it may do.
    not_owner,
    /// The host could not tell who called.
    unidentified,
};

const Unavailable = union(enum) {
    /// `stop`, `close`, or `status` named a subagent that is not open.
    /// `open` is every open subagent, in the order `status` lists them.
    not_open: struct { agent: []const u8, open: []const []const u8 },
    /// A message to a subagent that has finished.
    finished,
};

const QueueFault = enum {
    /// The subagent already has as many messages waiting for its next turn as
    /// the host queues for one subagent. Only the agent that started the
    /// subagent can message it, so they are all the caller's own.
    subagent,
    /// The caller's parent already has as many messages from its subagents
    /// waiting as its queue takes. The cap counts every subagent's messages,
    /// not the caller's alone.
    parent,
};

const ParentFault = enum {
    /// The caller has no parent: it is the main agent.
    none,
    /// The caller has a parent that cannot take a message now.
    unreachable_now,
};

const HostFault = enum {
    /// A new subagent would be one more than a session holds open.
    subagent_limit,
    /// Any other failure of the host, whose cause only the trace names.
    internal,
};

const agent_name_rule = std.fmt.comptimePrint(
    "agent must be a name of 1 to {d} characters: lowercase letters, digits, \"_\" or \"-\", starting with a letter or digit.",
    .{domain.max_agent_name_bytes},
);
const message_rule = std.fmt.comptimePrint(
    "message must be 1 to {d} bytes of valid text with no NUL character. Send it again within that limit.",
    .{domain.max_message_bytes},
);
const instructions_rule = std.fmt.comptimePrint(
    "instructions must be 1 to {d} bytes of valid text with no NUL character. Leave the field out if you have none.",
    .{domain.max_instructions_bytes},
);
const model_rule = std.fmt.comptimePrint(
    "model must be 1 to {d} bytes of valid text with no NUL character. Leave the field out to use the default.",
    .{domain.max_model_bytes},
);
const effort_rule = std.fmt.comptimePrint(
    "effort must be one word of up to {d} letters, digits, \"-\", \"_\" or \".\", such as low, medium or high. Leave the field out to use the default.",
    .{types.ReasoningEffort.max_name_bytes},
);
const profile_rule = std.fmt.comptimePrint(
    "profile must be 1 to {d} characters: lowercase letters, digits, \"-\" or \"_\". Leave the field out to start in the main profile.",
    .{profiles.max_name_bytes},
);
const subagent_limit = std.fmt.comptimePrint(
    "This session already has {d} open subagents, the most it holds. Close one you are done with, or send a message to one that exists.",
    .{child_state.max_children},
);
const subagent_queue_full = std.fmt.comptimePrint(
    "The subagent already has {d} of your messages waiting. Call wait for its report, then send this one again.",
    .{agent_frame.queue_cap},
);
const parent_queue_full = std.fmt.comptimePrint(
    "Your parent already has {d} messages from its subagents waiting, the most it holds. Put the rest in your final reply.",
    .{agent_frame.queue_cap},
);

/// "No open subagent is named X.", then the open ones up to `max_named_open`
/// and a count of the rest. `agent` passed the name rule, so it is quotable.
fn writeNotOpen(writer: *std.Io.Writer, agent: []const u8, open: []const []const u8) std.Io.Writer.Error!void {
    try writer.print("No open subagent is named \"{s}\".", .{agent});
    if (open.len == 0) return writer.writeAll(" You have no open subagents.");
    try writer.writeAll(" Open subagents: ");
    const named = @min(open.len, max_named_open);
    for (open[0..named], 0..) |name, index| {
        if (index > 0) try writer.writeAll(", ");
        try writer.writeAll(name);
    }
    if (open.len > named) try writer.print(", and {d} more; status lists every one", .{open.len - named});
    try writer.writeByte('.');
}

/// The refusal for a request that failed `model_contract.validateRequest`.
/// An `OutOfMemory` is no refusal, so it stays an error for the caller.
pub fn fromValidation(err: model_contract.ValidationError) Allocator.Error!Refusal {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidAgent => .{ .invalid_agent = .name },
        error.InvalidParentTarget => .{ .invalid_agent = .parent_target },
        error.InvalidReport => .invalid_report,
        error.InvalidParentMessage => .invalid_parent_message,
        error.InvalidInstructions => .invalid_instructions,
        error.InvalidMessage => .invalid_message,
        error.InvalidModel => .invalid_model,
        error.InvalidEffort => .invalid_effort,
        error.InvalidProfile => .invalid_profile,
    };
}

/// The refusal for a message `model_contract.plan` turns away.
pub fn fromReject(code: model_contract.RejectCode) Refusal {
    return switch (code) {
        .child_busy => .child_busy,
        .child_unavailable => .{ .child_unavailable = .finished },
        .child_not_persistent => .child_not_persistent,
    };
}

/// One refusal for each variant and each cause, which the tests walk.
const samples = [_]Refusal{
    .invalid_json,
    .{ .invalid_agent = .name },
    .{ .invalid_agent = .parent_target },
    .invalid_message,
    .invalid_instructions,
    .invalid_report,
    .invalid_model,
    .invalid_effort,
    .invalid_profile,
    .invalid_parent_message,
    .host_unavailable,
    .{ .caller_unavailable = .not_owner },
    .{ .caller_unavailable = .unidentified },
    .wait_unavailable,
    .child_busy,
    .override_after_create,
    .child_closing,
    .{ .child_unavailable = .{ .not_open = .{ .agent = "ghost", .open = &.{ "reviewer", "fixer" } } } },
    .{ .child_unavailable = .{ .not_open = .{ .agent = "ghost", .open = &.{} } } },
    .{ .child_unavailable = .finished },
    .child_not_persistent,
    .child_cancelled,
    .state_unavailable,
    .operation_conflict,
    .{ .queue_full = .subagent },
    .{ .queue_full = .parent },
    .{ .no_parent = .none },
    .{ .no_parent = .unreachable_now },
    .{ .host_failure = .subagent_limit },
    .{ .host_failure = .internal },
};
