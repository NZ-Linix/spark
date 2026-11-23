const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const credentials = @import("../auth/credentials.zig");
const secret = @import("../auth/secret.zig");
const io_mod = @import("../shared/io.zig");
const testing_event = @import("../shared/testing_event.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const image_attachments = @import("../images/image_attachments.zig");
const context_contract = @import("../workspace/context_contract.zig");
const notification_contract = @import("../notifications/notification_contract.zig");
const session_runtime = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const compactor = @import("../compactor/compactor.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const types = @import("../shared/types.zig");
const agent_frame = @import("../shared/agent_frame.zig");
const model_provider = @import("../config/model_provider.zig");
const assistant_presentation = @import("assistant_presentation.zig");
const compaction_activity = @import("../output/compaction_activity.zig");
const text_utils = @import("../shared/text_utils.zig");

pub const AgentTurnSettings = struct {
    max_tool_result_bytes: usize = tool_result_limits.default_max_tool_result_bytes,
    auto_compact_percent: u8 = compactor.default_percent,
    first_call_tool_choice: types.ToolChoice = .auto,
    fast_mode: bool = false,
    ultrafast_mode: bool = false,
    effort: types.ReasoningEffort = .auto,
};

pub const SkillBinding = struct {
    name: []u8,
    path: []u8,
};

pub const SkillDisplaySpan = struct {
    raw_start: usize,
    raw_end: usize,
    name: []u8,
    path: []u8,
    display_source: ?skill_contract.SkillSource = null,
    owns_trailing_separator: bool = false,
};

pub const BeginPromptWithSkillBindings = struct {
    prompt: types.UserTurn,
    skill_bindings: []SkillBinding = &.{},
    skill_display_spans: []SkillDisplaySpan = &.{},
};

pub const PromptDelivery = union(enum) {
    ordinary,
    active_turn: u64,
    continuation,

    pub fn activeTurnId(self: PromptDelivery) ?u64 {
        return switch (self) {
            .active_turn => |turn_id| turn_id,
            .ordinary, .continuation => null,
        };
    }

    pub fn isSteering(self: PromptDelivery) bool {
        return switch (self) {
            .ordinary => false,
            .active_turn, .continuation => true,
        };
    }

    pub fn isContinuation(self: PromptDelivery) bool {
        return self == .continuation;
    }
};

pub const SteeringBoundaryKind = enum {
    model,
    cancelled,
    finalizing,
};

const SteeringDelivery = types.SteeringDelivery;

/// Borrowed by the queue. Its owner outlives worker teardown.
pub const SteeringReceipt = struct {
    operation_id: []const u8 = "",
    state: std.atomic.Value(SteeringDelivery) = .init(.queued),
};

pub const MessageAuthor = types.MessageAuthor;

/// One message a turn takes at a steering boundary, with who wrote it.
pub const SteeringMessage = struct {
    text: []u8,
    author: MessageAuthor = .user,
};

/// Frees boundary messages and the slice, all from `alloc`.
fn typedLineDropped(turn_id: u64, text: []const u8) void {
    debug_trace.eventf("worker", "typed_line_dropped", .{ .turn_id = turn_id }, "bytes={d} reason=out_of_memory", .{text.len});
}

pub fn freeSteeringMessages(alloc: std.mem.Allocator, messages: []SteeringMessage) void {
    for (messages) |message| alloc.free(message.text);
    alloc.free(messages);
}

pub const SteeringBoundaryResult = union(enum) {
    none,
    continue_turn: []SteeringMessage,
    handoff,
    interrupt,
};

pub const QueuedPrompt = struct {
    turn_id: u64 = 0,
    /// The work id of main's message this prompt brings to a subagent. Its
    /// turn is saved with it, and main finds the answer by it. Owned.
    work_id: ?[]u8 = null,
    steering_receipt: ?*SteeringReceipt = null,
    /// Who wrote the prompt, which decides how the turn frames it.
    author: MessageAuthor = .user,
    /// Another agent's report or message, which `agent_frame.queue_cap`
    /// counts (messages only).
    mail: agent_frame.MailKind = .none,
    /// Runtime-derived delivery state. The worker retains ownership in every state.
    delivery: PromptDelivery = .ordinary,
    prompt: []u8,
    images: []types.ImageAttachment,
    authorized_image_catalog: []types.ImageAttachment = &.{},
    model: []u8,
    provider: model_provider.ProviderId = .none,
    api_key: []u8,
    gateway_team: ?[]u8 = null,
    /// The team's slug, which spark shows the user. Null when the login has no
    /// slug; spark then names the team by `gateway_team`.
    gateway_team_label: ?[]u8 = null,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]u8 = null,
    permission_mode: types.PermissionMode,
    history: []types.HistoryTurn,
    /// Absolute end of the leading canonical-history range loaded without
    /// corrected result provenance. The conservative default protects callers
    /// that do not own a SessionRuntime snapshot.
    unversioned_history_count: usize = std.math.maxInt(usize),
    root_user_intent_context: []u8 = &.{},
    skill_bindings: []SkillBinding = &.{},
    skill_display_spans: []SkillDisplaySpan = &.{},
    context_snapshot: context_contract.GatheredContextSnapshot = .{},
    /// The files this turn's attachments name by workspace path, and the
    /// sources that were no files. The runtime delivers their folders' rules
    /// as a note on the turn's own message. Borrowed from the host for the
    /// turn: `freeQueuedPrompt` leaves it alone, so a prompt handed to the
    /// worker queue carries none, and a turn that continues an earlier one
    /// clears it.
    attached_files: context_contract.AttachedFiles = .{},
    agent_settings: AgentTurnSettings = .{},
    snapshot_file_ownerships: []types.SnapshotFileOwnership = &.{},
    /// Present only when an explicit host action resumes a durable paused
    /// model turn. The same ownership rules as the other queued fields apply.
    recovery_checkpoint: ?session_codec.RecoveryCheckpoint = null,
    /// The request a previous spark process left unfinished, which this turn's
    /// first model request resumes.
    recovery_resume: ?types.RecoveryResume = null,
    /// True when this output surface already contains the checkpoint's
    /// assistant source. Recovery still restores the source for overlap and
    /// persistence, but publishes only novel continuation text.
    recovery_source_already_presented: bool = false,
    /// The interactive transcript already contains this exact user turn.
    /// Worker begin publishes only its identity so the UI can consume the
    /// pending owner without painting a duplicate card.
    user_prompt_already_presented: bool = false,
    /// The first turn after a resume whose history names shell handles this
    /// process does not own. The turn starts with a note saying so (D93).
    stale_shell_handles: bool = false,
};

pub const ContextCompactionTask = struct {
    turn_id: u64 = 0,
    operation_id: ?compaction_activity.OperationId = null,
    model: []u8,
    provider: model_provider.ProviderId = .none,
    api_key: []u8,
    gateway_team: ?[]u8 = null,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]u8 = null,
    history: []types.HistoryTurn,
    unversioned_history_count: usize = std.math.maxInt(usize),
};

pub const ContextCompactionStatus = enum {
    idle,
    queued,
    running,
};

pub const WorkItem = union(enum) {
    prompt: QueuedPrompt,
    compact_context: ContextCompactionTask,
};

pub const ActivePromptSnapshotOwnership = struct {
    /// Owns snapshot deletion until the files are transferred to accepted
    /// history or handed to a reference-counted finished-turn owner.
    images: []const types.ImageAttachment,
    state: enum {
        active,
        handed_off,
        preserved,
        discarded,
    } = .active,
    shared_ownership: ?types.SnapshotFileOwnership = null,

    pub fn init(images: []const types.ImageAttachment) ActivePromptSnapshotOwnership {
        return .{ .images = images };
    }

    fn ensureSharedOwnership(
        self: *ActivePromptSnapshotOwnership,
        alloc: std.mem.Allocator,
    ) !?types.SnapshotFileOwnership {
        if (self.images.len == 0) return null;
        if (self.state == .preserved or self.state == .discarded) return null;
        if (self.shared_ownership) |ownership| return ownership;
        const ownership = (try SnapshotFileOwnershipState.create(alloc, self.images)).handle();
        self.shared_ownership = ownership;
        return ownership;
    }

    fn handoff(
        self: *ActivePromptSnapshotOwnership,
        alloc: std.mem.Allocator,
    ) !?types.SnapshotFileOwnership {
        if (self.state != .active or self.images.len == 0) return null;
        const ownership = (try self.ensureSharedOwnership(alloc)).?;
        self.state = .handed_off;
        return ownership;
    }

    fn preserve(self: *ActivePromptSnapshotOwnership) bool {
        if (self.images.len == 0) return false;
        switch (self.state) {
            .active => {
                if (self.shared_ownership) |ownership| {
                    ownership.transfer();
                    ownership.release();
                    self.shared_ownership = null;
                }
                self.state = .preserved;
                return true;
            },
            .handed_off => {
                if (self.shared_ownership) |ownership| ownership.transfer();
                return true;
            },
            .preserved => return true,
            .discarded => return false,
        }
    }

    fn deinit(self: *ActivePromptSnapshotOwnership) void {
        if (self.state == .active) {
            if (self.shared_ownership) |ownership| {
                ownership.release();
            } else {
                image_attachments.deleteUnreferencedImageSnapshots(self.images, &.{});
            }
            self.state = .discarded;
        }
    }
};

const SnapshotFileOwnershipState = struct {
    alloc: std.mem.Allocator,
    images: []types.ImageAttachment,
    references: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    transferred: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn create(
        alloc: std.mem.Allocator,
        images: []const types.ImageAttachment,
    ) !*SnapshotFileOwnershipState {
        const owned_images = try types.dupeImageAttachmentSlice(alloc, images);
        errdefer types.freeImageAttachmentSlice(alloc, owned_images);
        const state = try alloc.create(SnapshotFileOwnershipState);
        state.* = .{
            .alloc = alloc,
            .images = owned_images,
        };
        return state;
    }

    fn handle(self: *SnapshotFileOwnershipState) types.SnapshotFileOwnership {
        return .{
            .ctx = self,
            .retain_fn = retain,
            .release_fn = release,
            .transfer_fn = transfer,
        };
    }

    fn retain(raw: *anyopaque) void {
        const self: *SnapshotFileOwnershipState = @ptrCast(@alignCast(raw));
        _ = self.references.fetchAdd(1, .seq_cst);
    }

    fn release(raw: *anyopaque) void {
        const self: *SnapshotFileOwnershipState = @ptrCast(@alignCast(raw));
        if (self.references.fetchSub(1, .seq_cst) != 1) return;
        if (!self.transferred.load(.seq_cst)) {
            image_attachments.deleteUnreferencedImageSnapshots(self.images, &.{});
        }
        const alloc = self.alloc;
        types.freeImageAttachmentSlice(alloc, self.images);
        alloc.destroy(self);
    }

    fn transfer(raw: *anyopaque) void {
        const self: *SnapshotFileOwnershipState = @ptrCast(@alignCast(raw));
        self.transferred.store(true, .seq_cst);
    }
};

fn historyTurnImages(turn: types.HistoryTurn) []const types.ImageAttachment {
    return switch (turn) {
        .assistant => |value| value.user.images,
        .interrupted => |value| value.user.images,
        .compacted_summary => &.{},
    };
}

fn sameImageSnapshots(
    left: []const types.ImageAttachment,
    right: []const types.ImageAttachment,
) bool {
    if (left.len == 0 or left.len != right.len) return false;
    for (left) |image| {
        const other = image_attachments.findById(right, image.id) orelse return false;
        if (!optionalBytesEqual(image.snapshot_path, other.snapshot_path) or
            !optionalBytesEqual(image.snapshot_sha256, other.snapshot_sha256))
        {
            return false;
        }
    }
    return true;
}

fn optionalBytesEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

pub const PermissionSnapshot = struct {
    mode: types.PermissionMode,
};

pub const CommandOutputChunk = struct {
    lifecycle_id: ?types.ToolLifecycleId = null,
    stream: command_output_content.Stream,
    text: []u8,
};

pub const SteeringPresentationSnapshot = struct {
    messages: [][]u8 = &.{},
    pending_feedback: [][]u8 = &.{},
    waits_for_boundary: bool = false,

    pub fn deinit(self: *SteeringPresentationSnapshot, alloc: std.mem.Allocator) void {
        for (self.messages) |message| alloc.free(message);
        if (self.messages.len > 0) alloc.free(self.messages);
        for (self.pending_feedback) |message| alloc.free(message);
        if (self.pending_feedback.len > 0) alloc.free(self.pending_feedback);
        self.* = .{};
    }
};

const PreparedHistoryPropagation = struct {
    root_user_intent_context: []u8,
    authorized_image_catalog: []types.ImageAttachment,
    snapshot_file_ownerships: ?[]types.SnapshotFileOwnership,
    added_snapshot_ownership: ?types.SnapshotFileOwnership,

    fn deinit(self: PreparedHistoryPropagation, alloc: std.mem.Allocator) void {
        alloc.free(self.root_user_intent_context);
        types.freeImageAttachmentSlice(alloc, self.authorized_image_catalog);
        if (self.added_snapshot_ownership) |ownership| ownership.release();
        if (self.snapshot_file_ownerships) |ownerships| alloc.free(ownerships);
    }
};

pub const StateSnapshot = struct {
    processing: bool = false,
    active_turn_id: u64 = 0,
    queued_count: usize = 0,
    pending_event_count: usize = 0,
    cancel_requested: bool = false,
    cancel_continues_turn: bool = false,

    pub fn deinit(_: StateSnapshot, _: std.mem.Allocator) void {}
};

pub const FinalizationFailure = struct {
    turn_id: u64,
    outcome: types.TurnPresentationOutcome,
};

pub const InteractiveAdmissionSnapshot = union(enum) {
    open,
    stopped,
    finalization_failed: FinalizationFailure,
};

const OwnedQuestionOption = struct {
    label: []u8,
    description: ?[]u8 = null,
};

const OwnedQuestionEntry = struct {
    question: []u8,
    markdown: bool = false,
    options: []OwnedQuestionOption,
    submission: @FieldType(types.QuestionBatchEntry, "submission") = .none,
};

/// Runs with the worker mutex held after an answer is accepted and before the
/// worker can resume. The callback must not call back into the worker.
pub const QuestionResumeObserver = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque) void,
};

pub const QuestionPromptSource = enum {
    agent_question,
    route_recovery,
    mcp_elicitation,
};

const OwnedQuestionBatch = struct {
    entries: []OwnedQuestionEntry,
    source: QuestionPromptSource = .agent_question,
};

const QuestionResponse = union(enum) {
    pending,
    cancelled,
    answered: [][]u8,
};

pub const PendingQuestionBatchSnapshot = struct {
    entries: []types.QuestionBatchEntry,
    source: QuestionPromptSource = .agent_question,

    pub fn deinit(self: PendingQuestionBatchSnapshot, alloc: std.mem.Allocator) void {
        for (self.entries) |entry| {
            alloc.free(@constCast(entry.question));
            for (entry.options) |opt| {
                alloc.free(@constCast(opt.label));
                if (opt.description) |desc| alloc.free(@constCast(desc));
            }
            alloc.free(@constCast(entry.options));
        }
        alloc.free(self.entries);
    }
};

pub const ContextCompaction = struct {
    turn_id: u64 = 0,
    summary: types.CompactedSummaryHistoryTurn,
    active_prefix: ?types.AssistantHistoryTurn = null,
    retained_from: ?types.ContextHistoryCut = null,
    max_history_turns: usize = 0,
};

pub const ContextCompactionHandler = *const fn (*anyopaque, ContextCompaction) anyerror!void;

const HistoryPublication = struct {
    ctx: *anyopaque,
    commit_fn: *const fn (*anyopaque) anyerror!void,
    retained_from: ?types.ContextHistoryCut = null,

    fn commit(self: HistoryPublication) !void {
        try self.commit_fn(self.ctx);
    }
};

const ContextCompactionPublication = struct {
    ctx: *anyopaque,
    handler: ContextCompactionHandler,
    event: ContextCompaction,

    fn commit(raw: *anyopaque) !void {
        const self: *ContextCompactionPublication = @ptrCast(@alignCast(raw));
        try self.handler(self.ctx, self.event);
    }
};

const HistoryPublicationResponse = union(enum) {
    idle,
    waiting: u64,
    committed,
    failed: anyerror,
};

pub const WorkerEvent = union(enum) {
    begin_prompt: types.UserTurn,
    begin_prompt_with_skill_bindings: BeginPromptWithSkillBindings,
    begin_presented_prompt: u64,
    /// A turn that resumes a request a previous spark process left unfinished.
    /// Its prompt is spark's note to the model, so no user card is written.
    begin_resumed_prompt: u64,
    append_user_feedback: []u8,
    /// A subagent's report or message a boundary took into the running
    /// turn. The screen shows it as the subagent's card, never as the user's.
    append_agent_message: []u8,
    assistant_presentation: assistant_presentation.Event,
    notification: notification_contract.Notification,
    question_requested,
    open_model_picker,
    semantic_notice: types.SemanticNotice,
    /// One settled model call, which Ctrl+O shows where it happened. Its
    /// strings are owned like the rest of the event.
    model_call: types.ModelCallRecord,
    route_recovery_status: types.RouteRecoveryStatus,
    clear_route_recovery_status,
    /// The gateway provider that served a request in this turn (display-only,
    /// last value wins). Owned by the event; the consumer frees it.
    provider_resolved: []u8,
    api_status_text: []u8,
    /// A piece of the model's reasoning, shown as a thinking block.
    reasoning_delta: []u8,
    remote_assistant_source: []u8,
    /// The reply's line in progress, for the live preview; empty when done.
    live_text: []u8,
    credential_refreshed: credentials.Credential,
    command_output: CommandOutputChunk,
    command_output_complete: ?types.ToolLifecycleId,
    tool_lifecycle: types.ToolLifecycleEvent,
    turn_token_update: types.TurnTokenProgress,
    turn_phase_update: types.TurnPhaseUpdate,
    diff_block: diff_mod.DiffEntryPayload,
    context_compaction: ContextCompaction,
    finish_prompt: types.FinishedPrompt,
    error_text: types.SemanticNotice,
    /// A turn that can never recover hands the prompt back to the composer.
    /// Owned by the event; the consumer frees it.
    restore_failed_prompt: []u8,
};

pub const WorkerEventBatch = struct {
    events: std.ArrayList(WorkerEvent),
    cancelled_turn_id: ?u64,
    /// Where a time-bounded drain stopped scanning the turn segment that the
    /// first events continue; null when they start a fresh scan.
    head_segment: ?HeadSegmentScan = null,
};

/// How far a scan of one turn segment has got: the turn its events named so
/// far, or the interrupted answer a `turn_finished` already settled.
pub const HeadSegmentScan = union(enum) {
    turn: ?u64,
    settled: bool,

    pub const fresh: HeadSegmentScan = .{ .turn = null };
};

pub const WorkerRuntime = struct {
    worker_mutex: std.Io.Mutex = .init,
    worker_cond: std.Io.Condition = .init,
    /// Agent name for `host` trace lines. Only the app's main agent sets
    /// it; other workers log nothing.
    trace_agent: ?[]const u8 = null,
    /// Set once the first event logged this agent's registration. Startup
    /// tracing is configured only after the app is built, so registration
    /// waits for the first event, which always precedes any subagent.
    trace_registered: bool = false,
    /// One admission-ordered queue for ordinary prompts and steering. Steering
    /// remains in place until its target turn consumes or demotes it.
    queued_prompts: std.ArrayList(QueuedPrompt) = .empty,
    /// One immutable conversation snapshot shared by every queued prompt.
    /// It is transferred or copied only when a prompt actually begins.
    queued_history: []types.HistoryTurn = &.{},
    queued_context_compaction: ?ContextCompactionTask = null,
    active_context_compaction: bool = false,
    history_publication_response: HistoryPublicationResponse = .idle,
    worker_events: std.ArrayList(WorkerEvent) = .empty,
    /// Scan state for the queue head after a time-bounded drain put events
    /// back mid-segment; the next take hands it over. Guarded by `worker_mutex`.
    head_segment: ?HeadSegmentScan = null,
    /// Set by a time-bounded put-back so the main loop runs its next
    /// iteration without waiting; read once. Guarded by `worker_mutex`.
    drain_continuation_due: bool = false,
    worker_processing: bool = false,
    active_turn_id: u64 = 0,
    active_tool_calls: std.StringHashMapUnmanaged(void) = .empty,
    /// Allocator used for active call IDs. Allocator handles are capabilities,
    /// not comparable identities; callers guarantee compatible ownership.
    active_tool_allocator: ?std.mem.Allocator = null,
    /// Retains the tool-producing step so later text from that same step cannot
    /// reopen immediate steering before authoritative lifecycle IDs exist.
    tool_phase_step_id: ?u64 = null,
    worker_stop_requested: bool = false,
    finalization_failure: ?FinalizationFailure = null,
    worker_cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set with `worker_cancel_requested` only by a cancel that stops the
    /// turn: the user's, an approval turn's, a running compaction's, or a
    /// failed finalization. A steer or a subagent's report that interrupts
    /// the model, or an image or `$skill` handed off to run next, never sets
    /// it, so a turn's workspace captures, which watch it, stop only when the
    /// turn is cancelled (D98). Cleared as each turn starts.
    turn_cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set when the user answers a request that waits for them; the request's
    /// recovery reads and clears it (`RequestRecovery.continue_flag`).
    recovery_continue_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set when the sign-in spark opened for a waiting request closes without
    /// a new login; the request's recovery reads and clears it
    /// (`RequestRecovery.sign_in_closed_flag`).
    recovery_sign_in_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set while the request waits for a follow-up the parent may give
    /// (`noteChildWaiting`); the parent's next message takes it.
    parent_may_continue: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// The active turn whose text steering admission owns the cancel flag.
    /// Guarded by `worker_mutex`; explicit cancellation clears this ownership.
    steering_cancel_turn_id: ?u64 = null,
    /// Set while steering waits for the active turn behind a running tool.
    /// A shell call that sees it stops waiting for its command and returns
    /// the command running, under the same `session_id`, so the turn reaches
    /// its next steering boundary without stopping the command. Cleared when
    /// the turn takes its steering and when a turn starts or ends. Written
    /// under `worker_mutex`; tools read it without the lock.
    tool_yield_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    direct_steering_closed: bool = false,
    /// Set by `nudgeWaiter` and cleared by `waitForPostOrNudge`, so a nudge
    /// sent before the wait starts still ends it. Guarded by `worker_mutex`.
    mail_nudged: bool = false,
    /// Places held for other agents' messages on their way to this queue
    /// (`reserveAgentMessage`), which the cap counts as waiting.
    reserved_agent_messages: usize = 0,
    /// The last turn a boundary ended so a waiting image or `$skill` could
    /// run as the next turn (`handedOff`).
    handed_off_turn_id: u64 = 0,
    /// When true, queued work will not start.
    turn_start_held: bool = false,
    /// Set once by a host that applies each `finish_prompt` this worker
    /// pushes, and then calls `acknowledgeFinishCommitted` (the app's worker
    /// threads). While a finished turn's commit is unacknowledged, mail that
    /// missed the turn does not start the next one (`commitGateRemainingMsLocked`).
    /// Off for every other host, which keeps the order it always had.
    commit_gate: bool = false,
    /// `finish_prompt` events pushed and not yet acknowledged. Guarded by
    /// `worker_mutex`; counted only while `commit_gate` is on.
    unacknowledged_finishes: u32 = 0,
    /// When this spell of holding mail began, in awake milliseconds: the first
    /// time `commitGateRemainingMsLocked` found mail to hold for the commits
    /// owed. Not when the finish was pushed, so mail that comes late still
    /// waits for its own limit. Guarded by `worker_mutex`.
    commit_gate_since_ms: i64 = 0,
    /// Whether this spell of holding mail has begun and been logged
    /// (`commit_gate_since_ms` is set).
    commit_gate_logged: bool = false,
    /// How many of the finished turns that `unacknowledged_finishes` counts are
    /// missing from `queued_history`. A queue that was empty took the history
    /// its first prompt was posted with (`enqueuePromptLocked`), which the
    /// loop took before it committed those turns. Each acknowledgement lowers
    /// it, and a commit that carries its turn adds the turn to the queue
    /// (`acknowledgeFinishCommittedTurn`). Guarded by `worker_mutex`.
    ///
    /// The post that adopts a base sets it, and it means something only while
    /// the queue holds that base. A call that empties the queue frees the base
    /// and leaves the count as it was: the next post sets it again, and a
    /// commit with no queued prompt adds nothing, so nothing reads a stale
    /// count.
    queued_history_owed: u32 = 0,
    /// Set when the loop's flush of its pacer for the held mail failed
    /// (`noteCommitGateFlushFailed`), so it does not try again, and log again,
    /// on every pass. Guarded by `worker_mutex`; cleared with the count.
    commit_gate_flush_failed: bool = false,
    /// Independent of a pending submission's turn-start hold; protects queued
    /// work until a fresh-session scrollback handoff succeeds or is cancelled.
    session_transition_held: bool = false,
    /// How many tool calls of the running turn wait for the user right now: for
    /// the answer to a question the agent or an MCP server asked, or the out-of-credits picker, which only the user can
    /// answer. A failed request that waits for the user in another way (a
    /// sign-in, or a refused one) is no question and is not counted. Changed
    /// under `worker_mutex` and read with no lock (`userWait`), so a reader
    /// that holds other locks cannot deadlock with a wait that is ending.
    question_waits: std.atomic.Value(u32) = .init(0),
    /// Set for a subagent's agent. Feedback main steered into a turn, which
    /// carries a receipt, is set aside when the turn ends without taking it,
    /// and the subagent's owner takes it back (`takeLeftoverMessages`) to run
    /// as new work. Any other steering left over, such as the user's, runs
    /// as the next turn, as it does on main.
    hands_back_leftover_feedback: bool = false,
    /// The feedback `hands_back_leftover_feedback` set aside, oldest first,
    /// until the owner takes it.
    held_back_feedback: std.ArrayList(QueuedPrompt) = .empty,
    /// What the user typed in turn `typed_turn_id`: its prompt when the user
    /// wrote it, then each of the user's lines that joined it, newest last.
    /// A subagent's message to its parent carries them (`typedThisTurn`), so
    /// the parent sees the user's own words. Owned by the queue's allocator,
    /// under `worker_mutex`: the newest `typed_line_cap`, each cut to
    /// `typed_line_bytes`.
    typed_this_turn: std.ArrayList([]u8) = .empty,
    typed_turn_id: u64 = 0,
    pending_question_shared: ?OwnedQuestionBatch = null,
    pending_question_response: QuestionResponse = .pending,
    agent_turn_settings: AgentTurnSettings = .{},
    active_agent_turn_settings: ?AgentTurnSettings = null,
    active_context_snapshot: ?*const context_contract.GatheredContextSnapshot = null,
    active_prompt_snapshot_ownership: ?*ActivePromptSnapshotOwnership = null,
    preserve_prompt_snapshot_turn_id: ?u64 = null,

    /// Presentation metadata only; all access is protected by worker_mutex.
    compaction_presentation: compaction_activity.State = .{},

    pub fn beginCompactionActivity(self: *WorkerRuntime, origin: compaction_activity.Origin, turn_id: ?u64) compaction_activity.OperationId {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.compaction_presentation.begin(origin, turn_id, io_mod.milliTimestamp());
    }

    /// A rejected intent must not hide an already-running compaction.
    pub fn rejectCompactionActivity(self: *WorkerRuntime, outcome: compaction_activity.Outcome) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.compaction_presentation.snapshot.operation) |op| if (op.active()) return;
        const now = io_mod.milliTimestamp();
        const id = self.compaction_presentation.begin(.manual, null, now);
        self.compaction_presentation.settle(id, .{ .outcome = outcome }, now);
    }

    pub fn runCompactionActivity(self: *WorkerRuntime, id: compaction_activity.OperationId, stage: compaction_activity.Stage) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.compaction_presentation.running(id, stage);
    }

    pub fn writtenCompactionActivity(self: *WorkerRuntime, id: compaction_activity.OperationId, percent: u8) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.compaction_presentation.written(id, percent);
    }

    pub fn settleCompactionActivity(self: *WorkerRuntime, id: compaction_activity.OperationId, feedback: compaction_activity.Feedback) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.compaction_presentation.settle(id, feedback, io_mod.milliTimestamp());
    }

    /// Cheap by-value read; does not clone permissions or allocate.
    pub fn compactionActivitySnapshot(self: *WorkerRuntime) compaction_activity.Snapshot {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.compaction_presentation.snapshot;
    }

    pub fn dismissCompactionActivity(self: *WorkerRuntime, id: compaction_activity.OperationId, revision: u64) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.compaction_presentation.dismiss(id, revision);
    }

    pub fn expireCompactionActivity(self: *WorkerRuntime, id: compaction_activity.OperationId, revision: u64, now_ms: i64) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.compaction_presentation.expire(id, revision, now_ms);
    }

    fn stopCompactionActivityLocked(self: *WorkerRuntime) void {
        const op = self.compaction_presentation.snapshot.operation orelse return;
        if (op.turn_id != self.active_turn_id or !self.worker_processing) return;
        self.compaction_presentation.stopping(op.id);
    }

    fn finishCompactionActivityLocked(self: *WorkerRuntime, turn_id: u64) void {
        const op = self.compaction_presentation.snapshot.operation orelse return;
        if (op.turn_id != turn_id or !op.active()) return;
        compactor.traceLog(true, "unsettled operation at worker finish turn_id={d}", .{turn_id});
        var feedback = compaction_activity.failure(
            if (self.isCancelRequested()) error.Cancelled else error.CompactionInterrupted,
            op.stage(),
            self.isCancelRequested(),
        );
        // No transaction acknowledgement survived this fallback; do not promise rollback.
        if (op.stage() == .publication) feedback.publication = .uncertain;
        self.compaction_presentation.settle(op.id, feedback, io_mod.milliTimestamp());
    }

    fn queuedWorkCountLocked(self: *const WorkerRuntime) usize {
        return self.queued_prompts.items.len +
            @intFromBool(self.queued_context_compaction != null);
    }

    pub fn deinit(self: *WorkerRuntime, alloc: std.mem.Allocator) void {
        freeOwnedQuestionBatchOpt(alloc, self.pending_question_shared);
        self.pending_question_shared = null;
        freeQuestionResponse(alloc, self.pending_question_response);
        self.pending_question_response = .pending;

        for (self.queued_prompts.items) |prompt| discardQueuedPrompt(alloc, prompt, &.{});
        self.queued_prompts.deinit(alloc);
        for (self.held_back_feedback.items) |prompt| freeQueuedPrompt(alloc, prompt);
        self.held_back_feedback.deinit(alloc);
        for (self.typed_this_turn.items) |line| alloc.free(line);
        self.typed_this_turn.deinit(alloc);
        types.freeHistoryTurnSlice(alloc, self.queued_history);
        if (self.queued_context_compaction) |task| freeContextCompactionTask(alloc, task);

        self.clearActiveToolCallsLocked();

        for (self.worker_events.items) |event| freeWorkerEvent(alloc, event);
        self.worker_events.deinit(alloc);
    }

    pub fn requestStop(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        self.worker_stop_requested = true;
        if (self.queued_context_compaction) |task| {
            if (task.operation_id) |id| self.compaction_presentation.settle(id, .{ .outcome = .cancelled }, io_mod.milliTimestamp());
        }
        self.stopCompactionActivityLocked();
        self.worker_cond.broadcast(io_mod.getIo());
        self.worker_mutex.unlock(io_mod.getIo());
    }

    pub fn requestShutdown(self: *WorkerRuntime) void {
        self.markExplicitCancellation();
        self.requestStop();
    }

    /// Cancels the turn in flight without stopping the worker, which goes on
    /// to run later turns, as a subagent's agent does: every wait wakes to
    /// see the cancel, and a question it is waiting on is cancelled.
    pub fn requestTurnCancel(self: *WorkerRuntime) void {
        self.requestCancel();
        if (self.cancelPendingQuestionBatch()) {
            debug_trace.logf("worker", "pending question cancelled reason=turn_cancel", .{});
        }
    }

    pub fn requestCancel(self: *WorkerRuntime) void {
        // The worker sets `worker_processing` under this lock as it takes and
        // ends turns, so the trace reads it under the lock too.
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const processing = if (self.worker_processing) "true" else "false";
        const queued = self.queuedWorkCountLocked();
        debug_trace.logf("worker", "cancel requested processing={s} queued={d}", .{ processing, queued });
        debug_trace.eventf("interrupt", "cancel_requested", .{}, "processing={s} queued={d} active_tool_known=false", .{ processing, queued });
        self.markExplicitCancellationLocked();
    }

    fn markExplicitCancellation(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.markExplicitCancellationLocked();
    }

    fn markExplicitCancellationLocked(self: *WorkerRuntime) void {
        self.steering_cancel_turn_id = null;
        self.clearHandoffLocked();
        self.turn_cancel_requested.store(true, .seq_cst);
        self.worker_cancel_requested.store(true, .seq_cst);
        self.stopCompactionActivityLocked();
        self.worker_cond.broadcast(io_mod.getIo());
    }

    /// An explicit cancel of the running turn ends it as cancelled, even if
    /// it was ending for an image or `$skill`. A cancel of the next turn
    /// leaves the hand-off before it alone.
    fn clearHandoffLocked(self: *WorkerRuntime) void {
        if (self.handed_off_turn_id == self.active_turn_id) self.handed_off_turn_id = 0;
    }

    pub fn requestInteractiveCancel(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        const steering_pending = for (self.queued_prompts.items) |prompt| {
            if (prompt.delivery.activeTurnId() == self.active_turn_id or
                prompt.delivery.isContinuation()) break true;
        } else false;
        debug_trace.logf("worker", "cancel requested processing={s} queued={d} steering_pending={s}", .{
            if (self.worker_processing) "true" else "false",
            self.queuedWorkCountLocked(),
            if (steering_pending) "true" else "false",
        });
        debug_trace.eventf("interrupt", "cancel_requested", .{}, "processing={s} queued={d} steering_pending={s} active_tool_known=false", .{
            if (self.worker_processing) "true" else "false",
            self.queuedWorkCountLocked(),
            if (steering_pending) "true" else "false",
        });
        self.steering_cancel_turn_id = null;
        self.clearHandoffLocked();
        self.turn_cancel_requested.store(true, .seq_cst);
        self.worker_cancel_requested.store(true, .seq_cst);
        self.stopCompactionActivityLocked();
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn isCancelRequested(self: *const WorkerRuntime) bool {
        return self.worker_cancel_requested.load(.seq_cst);
    }

    /// Whether a cancel that stops the turn was requested, as opposed to a
    /// steer's interrupt of the model (`turn_cancel_requested`).
    pub fn isTurnCancelRequested(self: *const WorkerRuntime) bool {
        return self.turn_cancel_requested.load(.seq_cst);
    }

    /// The user answered a request that waits for them, for example with
    /// Enter. A request that is not waiting ignores it.
    pub fn requestRecoveryContinue(self: *WorkerRuntime) void {
        self.recovery_continue_requested.store(true, .seq_cst);
    }

    /// The sign-in spark opened for a request that waits for one closed without
    /// a new login, for example because its code expired. The request tries
    /// its saved login once more; a request that does not wait for a sign-in
    /// ignores it.
    pub fn requestRecoverySignInClosed(self: *WorkerRuntime) void {
        self.recovery_sign_in_closed.store(true, .seq_cst);
    }

    pub fn cancellationStopsTurn(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.worker_cancel_requested.load(.seq_cst) and
            self.steering_cancel_turn_id != self.active_turn_id;
    }

    /// Whether the running turn `turn_id` ends because it was explicitly
    /// cancelled, as by Escape, rather than because steering ended it to
    /// hand off to an image or `$skill`.
    pub fn turnEndsByExplicitCancel(self: *WorkerRuntime, turn_id: u64) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return turn_id != 0 and
            turn_id == self.active_turn_id and
            self.worker_cancel_requested.load(.seq_cst) and
            self.steering_cancel_turn_id != turn_id and
            self.handed_off_turn_id != turn_id;
    }

    pub fn pushEvent(self: *WorkerRuntime, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        const owned = try dupeWorkerEvent(alloc, event);
        errdefer freeWorkerEvent(alloc, owned);
        try self.pushOwnedEvent(alloc, owned);
    }

    /// Transfers an already-owned event into the queue on success.
    /// Every heap payload in `event` must have been allocated by `alloc`.
    pub fn pushOwnedEvent(self: *WorkerRuntime, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        try self.worker_events.ensureUnusedCapacity(alloc, 1);
        var tool_transition = try self.prepareActiveToolTransitionLocked(alloc, event);
        errdefer tool_transition.deinit(alloc);
        self.worker_events.appendAssumeCapacity(event);
        if (self.commit_gate and event == .finish_prompt) self.noteFinishPushedLocked();
        // Logged under the lock the main loop drains with, so this line
        // always comes before the line that applies the event.
        if (self.trace_agent) |agent| {
            if (!self.trace_registered) {
                self.trace_registered = true;
                debug_trace.eventf("host", "agent_registered", .{}, "agent={s} parent=none", .{agent});
            }
            debug_trace.eventf("host", "agent_event_queued", .{}, "agent={s} kind={s}", .{ agent, traceKind(event) });
        }
        self.applyActiveToolTransitionLocked(tool_transition);
        self.applyToolBoundaryPhaseLocked(event);
        self.worker_cond.broadcast(io_mod.getIo());
    }

    /// Transfers already-owned events to the front of the queue on success.
    /// Every heap payload must have been allocated by `alloc`.
    pub fn prependOwnedEvents(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        events: []const WorkerEvent,
    ) !void {
        if (events.len == 0) return;
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        try self.worker_events.insertSlice(alloc, 0, events);
        self.worker_cond.broadcast(io_mod.getIo());
    }

    /// Puts back the events a time-bounded drain did not reach, ahead of newer
    /// ones, with the scan state of the segment they continue (null when the
    /// first of them starts a segment). Takes ownership on success.
    pub fn prependOwnedEventsForBudget(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        events: []const WorkerEvent,
        head_segment: ?HeadSegmentScan,
    ) !void {
        if (events.len == 0) return;
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        try self.worker_events.insertSlice(alloc, 0, events);
        self.head_segment = head_segment;
        self.drain_continuation_due = true;
        self.worker_cond.broadcast(io_mod.getIo());
    }

    /// True once after each time-bounded put-back.
    pub fn takeDrainContinuationDue(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        defer self.drain_continuation_due = false;
        return self.drain_continuation_due;
    }

    pub fn pushTurnFinished(self: *WorkerRuntime, alloc: std.mem.Allocator, event: types.TurnFinished) !void {
        std.debug.assert(event.turn_id != 0);

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.worker_events.append(alloc, .{ .tool_lifecycle = .{
            .turn_finished = event,
        } }) catch {
            self.latchFinalizationFailureLocked(.{
                .turn_id = event.turn_id,
                .outcome = event.outcome,
            });
            return error.TurnFinalizationDeliveryFailed;
        };
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn latchFinalizationFailure(self: *WorkerRuntime, failure: FinalizationFailure) void {
        std.debug.assert(failure.turn_id != 0);

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.latchFinalizationFailureLocked(failure);
    }

    fn latchFinalizationFailureLocked(self: *WorkerRuntime, failure: FinalizationFailure) void {
        if (self.finalization_failure == null) {
            self.finalization_failure = failure;
        } else {
            debug_trace.logf(
                "worker",
                "duplicate finalization failure ignored turn_id={d} first_turn_id={d}",
                .{ failure.turn_id, self.finalization_failure.?.turn_id },
            );
        }
        self.worker_stop_requested = true;
        self.steering_cancel_turn_id = null;
        self.turn_cancel_requested.store(true, .seq_cst);
        self.worker_cancel_requested.store(true, .seq_cst);
        self.stopCompactionActivityLocked();
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn interactiveAdmissionSnapshot(self: *WorkerRuntime) InteractiveAdmissionSnapshot {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        if (self.finalization_failure) |failure| {
            return .{ .finalization_failed = failure };
        }
        if (self.worker_stop_requested) return .stopped;
        return .open;
    }

    pub fn takeEventBatch(self: *WorkerRuntime) WorkerEventBatch {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const events = self.worker_events;
        self.worker_events = .empty;
        defer self.head_segment = null;
        return .{
            .events = events,
            .cancelled_turn_id = if (self.worker_cancel_requested.load(.seq_cst) and
                self.active_turn_id != 0 and
                self.steering_cancel_turn_id != self.active_turn_id)
                self.active_turn_id
            else
                null,
            .head_segment = self.head_segment,
        };
    }

    /// True when events wait for the main loop. Safe from any thread.
    pub fn hasPendingEvents(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.worker_events.items.len > 0;
    }

    pub fn takeEvents(self: *WorkerRuntime) std.ArrayList(WorkerEvent) {
        return self.takeEventBatch().events;
    }

    pub fn enqueuePrompt(self: *WorkerRuntime, alloc: std.mem.Allocator, prompt: QueuedPrompt) !void {
        try self.admitPrompt(alloc, prompt, false);
    }

    pub fn admitInteractivePrompt(self: *WorkerRuntime, alloc: std.mem.Allocator, prompt: QueuedPrompt) !void {
        try self.admitPrompt(alloc, prompt, true);
    }

    /// Takes prompt ownership only on true. Does not cancel an in-flight operation
    /// or fall back to the ordinary FIFO of an ephemeral direct worker. Refuses
    /// while older work or a message for a later turn waits, so it never joins
    /// the running turn past them.
    pub fn admitActiveSteering(self: *WorkerRuntime, alloc: std.mem.Allocator, prompt: QueuedPrompt) !bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (!self.worker_processing or self.active_turn_id == 0 or
            self.direct_steering_closed or self.worker_stop_requested or
            self.worker_cancel_requested.load(.seq_cst) or self.olderMailWaitsLocked()) return false;
        var queued = prompt;
        queued.delivery = .{ .active_turn = self.active_turn_id };
        try self.enqueuePromptLocked(alloc, queued);
        self.requestToolYieldForLocked(queued);
        return true;
    }

    /// Asks a running shell command to return running, under its session,
    /// when `queued` is steering that would otherwise wait behind it.
    fn requestToolYieldForLocked(self: *WorkerRuntime, queued: QueuedPrompt) void {
        if (queued.delivery.activeTurnId() != self.active_turn_id) return;
        if (!yieldsRunningTools(queued)) return;
        if (!self.hasActiveToolBoundaryLocked() or self.compactionInFlightLocked()) return;
        self.tool_yield_requested.store(true, .seq_cst);
        debug_trace.eventf("worker", "steering_tool_yield_requested", .{ .turn_id = self.active_turn_id }, "queued_turn_id={d} author={s} active_tools={d}", .{ queued.turn_id, @tagName(queued.author), self.active_tool_calls.count() });
    }

    /// Posts a message from another agent. It joins the running turn when
    /// nothing older waits, and otherwise waits for the next turn, which
    /// takes it in when it starts; an idle worker starts that turn. It never
    /// interrupts the model. Another agent's message past
    /// `agent_frame.queue_cap` is refused with `error.QueueFull`; a report
    /// never is. Takes ownership of `prompt` on success.
    pub fn postMail(self: *WorkerRuntime, alloc: std.mem.Allocator, prompt: QueuedPrompt) !void {
        return self.postMailWith(alloc, prompt, false);
    }

    /// As `postMail`, for a message whose place `reserveAgentMessage` held:
    /// it takes that place, and the place is spent whatever happens.
    pub fn postReservedMail(self: *WorkerRuntime, alloc: std.mem.Allocator, prompt: QueuedPrompt) !void {
        return self.postMailWith(alloc, prompt, true);
    }

    fn postMailWith(self: *WorkerRuntime, alloc: std.mem.Allocator, prompt: QueuedPrompt, reserved: bool) !void {
        var queued = prompt;
        if (queued.turn_id == 0) queued.turn_id = debug_trace.nextTurnId();
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (reserved and self.reserved_agent_messages > 0) self.reserved_agent_messages -= 1;
        if (self.finalization_failure != null) return error.TurnFinalizationDeliveryFailed;
        if (self.worker_stop_requested) return error.WorkerStopped;
        if (!reserved and queued.mail == .message and self.agentMessageCountLocked() >= agent_frame.queue_cap) {
            return error.QueueFull;
        }
        const joins = self.worker_processing and self.active_turn_id != 0 and
            !self.direct_steering_closed and !self.worker_cancel_requested.load(.seq_cst) and
            !self.olderMailWaitsLocked();
        queued.delivery = if (joins) .{ .active_turn = self.active_turn_id } else .continuation;
        queued.agent_settings = self.agent_turn_settings;
        try self.enqueuePromptLocked(alloc, queued);
        // Under the lock, so the trace orders it against the turn's takes
        // (`tests/tla/drivers/subagent/main-mail.test.ts`).
        debug_trace.eventf("worker", "mail_posted", .{ .turn_id = self.active_turn_id }, "worker={x} mail={s} delivery={s}", .{ @intFromPtr(self), @tagName(queued.mail), if (joins) "joined" else "waits" });
    }

    /// Whether mail waiting in this queue joins the running turn at its next
    /// boundary. False between turns and in a turn the worker was not told
    /// of, as ACP's, whose mail starts the next turn
    /// (`tests/tla/subagent/MainMail.tla` WaitHonest).
    pub fn queuedMailJoinsTurn(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const joins = joins: {
            if (!self.worker_processing or self.active_turn_id == 0) break :joins false;
            for (self.queued_prompts.items) |prompt| {
                if (prompt.delivery.activeTurnId() == self.active_turn_id) break :joins true;
            }
            break :joins false;
        };
        debug_trace.eventf("worker", "mail_joins_checked", .{ .turn_id = self.active_turn_id }, "worker={x} joins={}", .{ @intFromPtr(self), joins });
        return joins;
    }

    /// Holds a place in this queue for another agent's message that is on
    /// its way, so the sender can be told at once.
    /// False when the queue already holds `agent_frame.queue_cap` of them,
    /// waiting or on their way. `postMail` of that message uses the place;
    /// `releaseAgentMessage` gives it back when the message never comes.
    pub fn reserveAgentMessage(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.agentMessageCountLocked() >= agent_frame.queue_cap) return false;
        self.reserved_agent_messages += 1;
        return true;
    }

    pub fn releaseAgentMessage(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.reserved_agent_messages > 0) self.reserved_agent_messages -= 1;
    }

    /// Other agents' messages waiting in this queue or on their way to it.
    /// Reports and notices don't count.
    fn agentMessageCountLocked(self: *const WorkerRuntime) usize {
        var count = self.reserved_agent_messages;
        for (self.queued_prompts.items) |prompt| count += @intFromBool(prompt.mail == .message);
        return count;
    }

    /// Whether turn `turn_id` ended by handing off to a waiting image or
    /// `$skill`, rather than by a cancel. A subagent's work then ends as
    /// done, as an instance's turn does.
    pub fn handedOff(self: *WorkerRuntime, turn_id: u64) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return turn_id != 0 and self.handed_off_turn_id == turn_id;
    }

    pub const PostWake = enum { posted, nudged, stopped };

    /// Takes the oldest queued prompt, for a host that runs turns itself
    /// rather than on a worker thread, as `spark ask` does. Null when none
    /// waits. The caller owns it (`freeQueuedPrompt`) and gives the turn its
    /// own history.
    pub fn takeQueuedPrompt(self: *WorkerRuntime, alloc: std.mem.Allocator) ?QueuedPrompt {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.queued_prompts.items.len == 0) return null;
        const prompt = self.queued_prompts.orderedRemove(0);
        if (self.queued_prompts.items.len == 0) {
            types.freeHistoryTurnSlice(alloc, self.queued_history);
            self.queued_history = &.{};
        }
        debug_trace.eventf("worker", "queued_prompt_taken", .{ .turn_id = prompt.turn_id }, "worker={x} mail={s} remaining={d}", .{ @intFromPtr(self), @tagName(prompt.mail), self.queued_prompts.items.len });
        return prompt;
    }

    /// Drops the queued prompts for which `drop` answers true, oldest first,
    /// and keeps the others in their order. `drop` gets each prompt's place in
    /// the queue as it stood on entry. It runs under the queue's lock, so it
    /// must not call into this worker. Returns how many it dropped. A host
    /// that gives up some of the mail it queued uses this, where
    /// `takeQueuedPrompt` takes only the oldest.
    pub fn discardQueuedWhere(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        context: anytype,
        comptime drop: fn (@TypeOf(context), usize, *const QueuedPrompt) bool,
    ) usize {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        var dropped: usize = 0;
        var index: usize = 0;
        var place: usize = 0;
        while (index < self.queued_prompts.items.len) : (place += 1) {
            if (!drop(context, place, &self.queued_prompts.items[index])) {
                index += 1;
                continue;
            }
            const prompt = self.queued_prompts.orderedRemove(index);
            debug_trace.eventf("worker", "queued_prompt_discarded", .{ .turn_id = prompt.turn_id }, "worker={x} mail={s} remaining={d}", .{ @intFromPtr(self), @tagName(prompt.mail), self.queued_prompts.items.len });
            discardQueuedPrompt(alloc, prompt, &.{});
            dropped += 1;
        }
        if (dropped > 0 and self.queued_prompts.items.len == 0) {
            types.freeHistoryTurnSlice(alloc, self.queued_history);
            self.queued_history = &.{};
        }
        return dropped;
    }

    /// As `takeQueuedPrompt`, and marks turn `turn_id`, which runs the
    /// prompt, in the same step, as `beginDirectProcessing` does: mail posted
    /// from the take on joins that turn (`tests/tla/subagent/MainMail.tla`
    /// NextTurn). Null, and nothing marked, when no prompt waits or the
    /// worker is busy or stopped. The caller pairs a prompt with
    /// `finishProcessing`.
    pub fn takeQueuedPromptForTurn(self: *WorkerRuntime, alloc: std.mem.Allocator, turn_id: u64) ?QueuedPrompt {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.queued_prompts.items.len == 0 or self.worker_processing or self.worker_stop_requested) return null;
        const prompt = self.queued_prompts.orderedRemove(0);
        if (self.queued_prompts.items.len == 0) {
            types.freeHistoryTurnSlice(alloc, self.queued_history);
            self.queued_history = &.{};
        }
        self.direct_steering_closed = false;
        self.turn_cancel_requested.store(false, .seq_cst);
        self.worker_cancel_requested.store(false, .seq_cst);
        self.worker_processing = true;
        self.active_turn_id = turn_id;
        self.tool_phase_step_id = null;
        self.clearToolYieldLocked();
        debug_trace.eventf("worker", "queued_prompt_taken", .{ .turn_id = turn_id }, "worker={x} mail={s} remaining={d} marked=true", .{ @intFromPtr(self), @tagName(prompt.mail), self.queued_prompts.items.len });
        return prompt;
    }

    /// Ends a `waitForPostOrNudge` without queueing anything: the host's
    /// call when a child's turn ends with nothing to post, so a wait on that
    /// child can return.
    pub fn nudgeWaiter(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.mail_nudged = true;
        self.worker_cond.broadcast(io_mod.getIo());
    }

    /// Blocks until a prompt is queued for this worker, whatever it carries,
    /// a nudge arrives, or a stop or cancel is requested. A nudge sent
    /// before the wait starts still ends it.
    pub fn waitForPostOrNudge(self: *WorkerRuntime) PostWake {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        while (self.queued_prompts.items.len == 0) {
            if (self.worker_stop_requested or self.worker_cancel_requested.load(.seq_cst)) return .stopped;
            if (self.mail_nudged) {
                self.mail_nudged = false;
                return .nudged;
            }
            self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch return .stopped;
        }
        self.mail_nudged = false;
        return .posted;
    }

    /// As `waitForPostOrNudge`, but returns null once `timeout` passes with
    /// nothing to report, so the caller can recheck a flag that a signal
    /// handler sets and cannot wake this for.
    pub fn waitForPostOrNudgeTimeout(self: *WorkerRuntime, timeout: std.Io.Timeout) ?PostWake {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        while (self.queued_prompts.items.len == 0) {
            if (self.worker_stop_requested or self.worker_cancel_requested.load(.seq_cst)) return .stopped;
            if (self.mail_nudged) {
                self.mail_nudged = false;
                return .nudged;
            }
            self.worker_cond.waitTimeout(io_mod.getIo(), &self.worker_mutex, timeout) catch |err| return switch (err) {
                error.Timeout => null,
                else => .stopped,
            };
        }
        self.mail_nudged = false;
        return .posted;
    }

    pub fn enqueueContextCompaction(
        self: *WorkerRuntime,
        task: ContextCompactionTask,
    ) !void {
        var queued = task;
        if (queued.turn_id == 0) queued.turn_id = debug_trace.nextTurnId();

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.finalization_failure != null) return error.TurnFinalizationDeliveryFailed;
        if (self.worker_stop_requested) return error.WorkerStopped;
        if (self.worker_processing or self.queued_prompts.items.len > 0 or
            self.queued_context_compaction != null)
        {
            return error.WorkerBusy;
        }
        if (queued.operation_id == null) queued.operation_id = self.compaction_presentation.begin(.manual, queued.turn_id, io_mod.milliTimestamp());
        self.compaction_presentation.queued(queued.operation_id.?, queued.turn_id, io_mod.milliTimestamp());
        self.queued_context_compaction = queued;
        debug_trace.eventf(
            "worker",
            "context_compaction_enqueue",
            .{ .turn_id = queued.turn_id },
            "queue_depth=1",
            .{},
        );
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn contextCompactionStatus(self: *WorkerRuntime) ContextCompactionStatus {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.active_context_compaction) return .running;
        if (self.queued_context_compaction != null) return .queued;
        return .idle;
    }

    pub fn cancelContextCompaction(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
    ) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        if (self.queued_context_compaction) |task| {
            self.queued_context_compaction = null;
            if (task.operation_id) |id| self.compaction_presentation.settle(id, .{ .outcome = .cancelled }, io_mod.milliTimestamp());
            self.worker_cond.broadcast(io_mod.getIo());
            self.worker_mutex.unlock(io_mod.getIo());
            freeContextCompactionTask(alloc, task);
            debug_trace.eventf(
                "context_compaction",
                "cancelled",
                .{},
                "phase=queued",
                .{},
            );
            return true;
        }
        if (self.active_context_compaction) {
            self.turn_cancel_requested.store(true, .seq_cst);
            self.worker_cancel_requested.store(true, .seq_cst);
            self.stopCompactionActivityLocked();
            self.worker_cond.broadcast(io_mod.getIo());
            self.worker_mutex.unlock(io_mod.getIo());
            debug_trace.eventf(
                "context_compaction",
                "cancel_requested",
                .{},
                "phase=running",
                .{},
            );
            return true;
        }
        self.worker_mutex.unlock(io_mod.getIo());
        return false;
    }

    /// Transfers `prompt` to the active turn when steering is requested, the
    /// turn still accepts guidance, and nothing older waits. Behind older
    /// waiting work, a plain message rides into the next turn after it
    /// instead of passing it; otherwise it enters the ordinary FIFO.
    /// A steer interrupts the model stream immediately only when no wait
    /// boundary is active; a running tool or an in-flight compaction defers
    /// delivery to the next steering boundary instead of being cancelled.
    fn admitPrompt(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        prompt: QueuedPrompt,
        steer_if_active: bool,
    ) !void {
        var queued = prompt;
        if (queued.turn_id == 0) queued.turn_id = debug_trace.nextTurnId();

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.finalization_failure != null) return error.TurnFinalizationDeliveryFailed;
        if (self.worker_stop_requested) return error.WorkerStopped;
        if (queued.recovery_checkpoint != null and
            !recoveryContinuationAdmission(
                self.worker_processing,
                self.queuedWorkCountLocked(),
            ))
        {
            return error.RecoveryBusy;
        }
        queued.agent_settings = self.agent_turn_settings;
        var interrupt_after_admission = false;
        const explicitly_cancelled = self.worker_cancel_requested.load(.seq_cst) and
            self.steering_cancel_turn_id != self.active_turn_id;
        const older_waits = self.olderMailWaitsLocked();
        if (steer_if_active and self.worker_processing and self.active_turn_id != 0 and
            !explicitly_cancelled and !older_waits)
        {
            queued.delivery = .{ .active_turn = self.active_turn_id };
            interrupt_after_admission = !self.hasSteeringWaitBoundaryLocked();
            if (!interrupt_after_admission) self.requestToolYieldForLocked(queued);
        } else if (steer_if_active and older_waits and sameTurnSteeringEligible(queued)) {
            queued.delivery = .continuation;
            debug_trace.eventf("worker", "steering_behind_waiting", .{ .turn_id = self.active_turn_id }, "queued_turn_id={d} queue_depth={d}", .{ queued.turn_id, self.queuedWorkCountLocked() });
        }
        try self.enqueuePromptLocked(alloc, queued);
        if (steer_if_active and self.worker_processing) {
            debug_trace.eventf("worker", "steering_admission", .{ .turn_id = self.active_turn_id }, "queued_turn_id={d} targeted={} plain={} tool_boundary={} compaction_active={} interrupt_model={}", .{ queued.turn_id, queued.delivery.activeTurnId() == self.active_turn_id, sameTurnSteeringEligible(queued), self.hasActiveToolBoundaryLocked(), self.compactionInFlightLocked(), interrupt_after_admission });
        }
        if (interrupt_after_admission) {
            const joins = sameTurnSteeringEligible(queued);
            self.steering_cancel_turn_id = if (joins) self.active_turn_id else null;
            // An image or `$skill` ends the turn so it can run next.
            if (!joins) self.handed_off_turn_id = self.active_turn_id;
            self.worker_cancel_requested.store(true, .seq_cst);
        }
    }

    /// Whether the steering preview shows `prompt` while it waits for the
    /// running turn. A subagent's report or message joins the turn as
    /// steering too, but once the turn takes it the transcript shows it as
    /// that subagent's row (`subagent/reports.zig`), so the preview never
    /// draws it as a message the user typed.
    fn previewsAsSteering(prompt: QueuedPrompt) bool {
        return prompt.delivery.isSteering() and prompt.author != .child;
    }

    /// Whether steering `prompt` moves a running shell command to the
    /// background so the turn takes it at once. The user's and a parent
    /// agent's steering do; a subagent's report waits for the tool, so a
    /// stream of reports does not detach every command main runs.
    fn yieldsRunningTools(prompt: QueuedPrompt) bool {
        return prompt.author != .child;
    }

    /// Clears a pending tool yield; the caller holds `worker_mutex`.
    fn clearToolYieldLocked(self: *WorkerRuntime) void {
        self.tool_yield_requested.store(false, .seq_cst);
    }

    fn sameTurnSteeringEligible(prompt: QueuedPrompt) bool {
        return prompt.images.len == 0 and
            prompt.skill_bindings.len == 0 and
            prompt.skill_display_spans.len == 0;
    }

    /// Whether a prompt waits that isn't the running turn's own: queued work,
    /// or a message waiting for a later turn. A new message never joins the
    /// running turn past one, so messages arrive in the order they were sent.
    fn olderMailWaitsLocked(self: *const WorkerRuntime) bool {
        for (self.queued_prompts.items) |prompt| {
            if (prompt.delivery.activeTurnId() != self.active_turn_id) return true;
        }
        return false;
    }

    fn enqueuePromptLocked(self: *WorkerRuntime, alloc: std.mem.Allocator, queued_value: QueuedPrompt) !void {
        var queued = queued_value;
        // A queued prompt owns its fields; attached files are the host's.
        std.debug.assert(queued.attached_files.isEmpty());
        // Feedback the last turn left goes back to the host before a run's
        // prompt is queued, so that prompt heads the queue with its own
        // history.
        if (self.hands_back_leftover_feedback and !queued.delivery.isSteering()) self.handBackLeftoverFeedbackLocked(alloc);
        try self.queued_prompts.ensureUnusedCapacity(alloc, 1);
        const supplied_history = queued.history;
        queued.history = &.{};
        if (self.queued_prompts.items.len == 0) {
            std.debug.assert(self.queued_history.len == 0);
            self.queued_history = supplied_history;
            // Mail that waits for a commit was posted after the worker finished
            // that turn, so the history it brought lacks the turn.
            self.queued_history_owed = if (queued.delivery.isContinuation()) self.unacknowledged_finishes else 0;
        } else {
            types.freeHistoryTurnSlice(alloc, supplied_history);
        }
        self.queued_prompts.appendAssumeCapacity(queued);
        debug_trace.logf(
            "worker",
            "queued prompt bytes={d} queue_depth={d} fast_mode={s} effort={s}",
            .{ queued.prompt.len, self.queuedWorkCountLocked(), if (queued.agent_settings.fast_mode) "true" else "false", queued.agent_settings.effort.label() },
        );
        debug_trace.eventf(
            "worker",
            "prompt_enqueue",
            .{ .turn_id = queued.turn_id },
            "prompt_bytes={d} queue_depth={d} fast_mode={s} effort={s}",
            .{ queued.prompt.len, self.queuedWorkCountLocked(), if (queued.agent_settings.fast_mode) "true" else "false", queued.agent_settings.effort.label() },
        );
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn hasPendingPlainSteering(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (!self.worker_processing or self.active_turn_id == 0 or self.worker_stop_requested) return false;
        var pending = false;
        for (self.queued_prompts.items) |prompt| {
            if (prompt.delivery.activeTurnId() != self.active_turn_id) continue;
            if (!sameTurnSteeringEligible(prompt)) return false;
            pending = true;
        }
        return pending;
    }

    /// Classifies and drains steering at one observed agent boundary. Returned
    /// text is allocator-owned; handoff leaves the queued prompt worker-owned.
    pub fn takeSteeringBoundary(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        turn_id: u64,
        kind: SteeringBoundaryKind,
    ) !SteeringBoundaryResult {
        return self.takeSteeringBoundaryInto(alloc, alloc, turn_id, kind);
    }

    /// Queue/event storage uses alloc; returned guidance uses result_alloc.
    pub fn takeSteeringBoundaryInto(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        result_alloc: std.mem.Allocator,
        turn_id: u64,
        kind: SteeringBoundaryKind,
    ) !SteeringBoundaryResult {
        const result = try self.takeSteeringBoundaryIntoInner(alloc, result_alloc, turn_id, kind);
        debug_trace.eventf("worker", "steering_boundary_check", .{ .turn_id = turn_id }, "kind={s} outcome={s}", .{ @tagName(kind), @tagName(result) });
        return result;
    }

    fn takeSteeringBoundaryIntoInner(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        result_alloc: std.mem.Allocator,
        turn_id: u64,
        kind: SteeringBoundaryKind,
    ) !SteeringBoundaryResult {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const cancel_requested = self.worker_cancel_requested.load(.seq_cst);
        if (!self.worker_processing or self.active_turn_id != turn_id) {
            return if (kind == .cancelled and cancel_requested) .interrupt else .none;
        }

        switch (kind) {
            .cancelled => {
                if (!cancel_requested) return .none;
                if (self.steering_cancel_turn_id != turn_id) return .interrupt;
                const messages = try self.takeSteeringLocked(alloc, result_alloc, turn_id);
                if (messages.len == 0) return .interrupt;
                self.steering_cancel_turn_id = null;
                self.worker_cancel_requested.store(false, .seq_cst);
                return .{ .continue_turn = messages };
            },
            .model, .finalizing => {
                if (cancel_requested) return .none;
                for (self.queued_prompts.items) |prompt| {
                    if (prompt.delivery.activeTurnId() == turn_id and !sameTurnSteeringEligible(prompt)) {
                        self.handed_off_turn_id = turn_id;
                        self.clearToolYieldLocked();
                        return .handoff;
                    }
                }
                const messages = try self.takeSteeringLocked(alloc, result_alloc, turn_id);
                if (messages.len != 0) self.clearToolYieldLocked();
                if (kind == .finalizing and messages.len == 0) self.direct_steering_closed = true;
                debug_trace.eventf("worker", "steering_taken", .{ .turn_id = turn_id }, "worker={x} kind={s} count={d} closed={}", .{ @intFromPtr(self), @tagName(kind), messages.len, self.direct_steering_closed });
                return if (messages.len == 0)
                    .none
                else
                    .{ .continue_turn = messages };
            },
        }
    }

    /// Whether the user typed `prompt` on this agent's screen. Main's
    /// messages to a subagent are queued as the user's too, but carry the
    /// work id of main's request; another agent's report or steering has its
    /// own author.
    fn typedByUser(prompt: QueuedPrompt) bool {
        return prompt.author == .user and prompt.work_id == null;
    }

    pub const typed_line_cap = 8;
    pub const typed_line_bytes = 2048;

    /// A copy of what the user typed in the turn going now
    /// (`typed_this_turn`), for a subagent's message to its parent; empty
    /// while no turn is going. The caller owns the lines and the slice.
    pub fn typedThisTurn(self: *WorkerRuntime, alloc: std.mem.Allocator) ![]const []const u8 {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (!self.worker_processing or self.typed_turn_id != self.active_turn_id) return &.{};
        const lines = try alloc.alloc([]const u8, self.typed_this_turn.items.len);
        var copied: usize = 0;
        errdefer {
            for (lines[0..copied]) |line| alloc.free(line);
            alloc.free(lines);
        }
        for (self.typed_this_turn.items) |line| {
            lines[copied] = try alloc.dupe(u8, line);
            copied += 1;
        }
        return lines;
    }

    /// Adds `text`, which the user typed, to turn `turn_id`'s lines, after
    /// dropping another turn's. Never fails: a line it can't copy is left
    /// out.
    fn noteTypedLocked(self: *WorkerRuntime, alloc: std.mem.Allocator, turn_id: u64, text: []const u8) void {
        if (self.typed_turn_id != turn_id) {
            for (self.typed_this_turn.items) |line| alloc.free(line);
            self.typed_this_turn.clearRetainingCapacity();
            self.typed_turn_id = turn_id;
        }
        if (text.len == 0) return;
        if (self.typed_this_turn.items.len == typed_line_cap) alloc.free(self.typed_this_turn.orderedRemove(0));
        self.typed_this_turn.ensureUnusedCapacity(alloc, 1) catch return typedLineDropped(turn_id, text);
        const line = alloc.dupe(u8, text[0..text_utils.utf8BackwardBoundary(text, typed_line_bytes)]) catch return typedLineDropped(turn_id, text);
        self.typed_this_turn.appendAssumeCapacity(line);
    }

    fn takeSteeringLocked(self: *WorkerRuntime, alloc: std.mem.Allocator, result_alloc: std.mem.Allocator, turn_id: u64) ![]SteeringMessage {
        var steering_count: usize = 0;
        for (self.queued_prompts.items) |prompt| {
            if (prompt.delivery.activeTurnId() != turn_id) continue;
            if (!sameTurnSteeringEligible(prompt)) return &.{};
            steering_count += 1;
        }
        if (steering_count == 0) return &.{};

        const messages = try result_alloc.alloc(SteeringMessage, steering_count);
        var copied: usize = 0;
        errdefer {
            for (messages[0..copied]) |message| result_alloc.free(message.text);
            result_alloc.free(messages);
        }
        const events = try alloc.alloc(WorkerEvent, steering_count);
        var event_count: usize = 0;
        errdefer {
            for (events[0..event_count]) |event| freeWorkerEvent(alloc, event);
            alloc.free(events);
        }
        for (self.queued_prompts.items) |prompt| {
            if (prompt.delivery.activeTurnId() != turn_id) continue;
            messages[copied] = .{ .text = try result_alloc.dupe(u8, prompt.prompt), .author = prompt.author };
            copied += 1;
            // Every steer the turn takes gets its card, a parent's too, so the screen shows what the model read.
            const text = try alloc.dupe(u8, prompt.prompt);
            events[event_count] = if (prompt.author == .child)
                .{ .append_agent_message = text }
            else
                .{ .append_user_feedback = text };
            event_count += 1;
        }
        try self.worker_events.ensureUnusedCapacity(alloc, event_count);
        for (events[0..event_count]) |event| self.worker_events.appendAssumeCapacity(event);
        alloc.free(events);

        // One stable pass takes this turn's prompts and keeps the rest in
        // order, so a boundary costs the same however many wait.
        var kept: usize = 0;
        for (self.queued_prompts.items) |prompt| {
            if (prompt.delivery.activeTurnId() != turn_id) {
                self.queued_prompts.items[kept] = prompt;
                kept += 1;
                continue;
            }
            if (prompt.steering_receipt) |receipt| {
                receipt.state.store(.applied, .seq_cst);
                debug_trace.eventf("subagent", "feedback_applied", .{}, "operation={s}", .{receipt.operation_id});
            }
            if (typedByUser(prompt)) self.noteTypedLocked(alloc, turn_id, prompt.prompt);
            freeQueuedPrompt(alloc, prompt);
        }
        self.queued_prompts.shrinkRetainingCapacity(kept);
        if (self.queued_prompts.items.len == 0) {
            types.freeHistoryTurnSlice(alloc, self.queued_history);
            self.queued_history = &.{};
        }
        debug_trace.eventf("worker", "prompt_steering_consumed", .{ .turn_id = turn_id }, "count={d}", .{messages.len});
        self.worker_cond.broadcast(io_mod.getIo());
        return messages;
    }

    pub fn holdSessionTransition(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.session_transition_held = true;
    }

    pub fn releaseSessionTransitionHold(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (!self.session_transition_held) return;
        self.session_transition_held = false;
        self.worker_cond.broadcast(io_mod.getIo());
    }

    /// Hold turn admission only when no turn is active or queued.
    pub fn tryHoldTurnStart(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.worker_processing or self.queuedWorkCountLocked() > 0 or
            self.turn_start_held or self.session_transition_held)
        {
            return false;
        }
        self.turn_start_held = true;
        debug_trace.logf("worker", "turn start hold acquired", .{});
        return true;
    }

    pub fn releaseTurnStartHold(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (!self.turn_start_held) return;
        self.turn_start_held = false;
        debug_trace.logf("worker", "turn start hold released", .{});
        self.worker_cond.broadcast(io_mod.getIo());
    }

    /// The longest mail that missed a turn waits for that turn's commit,
    /// counted from the first time the gate holds it (`commit_gate_since_ms`),
    /// not from the moment the turn finished.
    pub const commit_gate_limit_ms: i64 = 5000;

    /// Opts this worker into the commit gate. Only a host that applies the
    /// finish events it takes from this worker, and then calls
    /// `acknowledgeFinishCommitted` for each it commits and
    /// `acknowledgeFinishDropped` for each it drops unsaved, may call it: the
    /// gate waits for those calls, and a host that never makes them only loses
    /// `commit_gate_limit_ms` per spell. A host that does not call this, as
    /// libfx and ACP do not, never counts a finish and never holds mail.
    pub fn enableCommitGate(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.commit_gate = true;
    }

    /// The main loop's note that it committed a finished turn to the session,
    /// or failed to: either way nothing more of that turn is open, so the next
    /// turn may begin. Wakes the worker held for it.
    pub fn acknowledgeFinishCommitted(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.releaseFinishesLocked(1, "committed");
    }

    /// As `acknowledgeFinishCommitted`, for a turn the loop added to the
    /// history it snapshots mail from. Mail that was queued after the worker
    /// finished the turn, and before this commit, took its history without the
    /// turn (`queued_history_owed`). The turn goes into the queue's history
    /// now, and into what each queued prompt keeps from it, as it does for mail
    /// that was queued when the turn finished (`propagateHistoryTurn`), so the
    /// mail's turn starts with it. `ownership` is the turn's snapshot files,
    /// which the loop has handed to history; each queued prompt keeps them
    /// until it ends. A turn that does not go in is logged, and the mail runs
    /// without it as it did before.
    pub fn acknowledgeFinishCommittedTurn(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        turn: types.HistoryTurn,
        ownership: ?types.SnapshotFileOwnership,
        max_history_turns: usize,
    ) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.commit_gate and self.unacknowledged_finishes > 0 and self.queued_history_owed > 0) {
            self.propagateHistoryTurnToQueue(alloc, turn, max_history_turns, null, .{ .given = ownership }) catch |err| {
                debug_trace.logf("worker", "queued mail misses a committed turn err={s} dropped=turn_in_queued_history", .{@errorName(err)});
            };
        }
        self.releaseFinishesLocked(1, "committed");
    }

    /// The main loop's note that it dropped a finished turn without
    /// committing it, as a cancel or a session switch drops the one the pacer
    /// held. Nothing of that turn is open and no commit is coming, so the
    /// gate must not wait for it: it lowers the count as a commit does, and
    /// logs the drop with `reason`.
    pub fn acknowledgeFinishDropped(self: *WorkerRuntime, reason: []const u8) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (!self.commit_gate) return;
        debug_trace.eventf("worker", "commit_gate_finish_dropped", .{ .turn_id = self.active_turn_id }, "worker={x} count=1 unacknowledged={d} reason={s}", .{ @intFromPtr(self), self.unacknowledged_finishes, reason });
        self.releaseFinishesLocked(1, reason);
    }

    fn releaseFinishesLocked(self: *WorkerRuntime, count: u32, reason: []const u8) void {
        if (!self.commit_gate or self.unacknowledged_finishes == 0) return;
        self.unacknowledged_finishes -|= count;
        self.queued_history_owed -|= count;
        if (self.unacknowledged_finishes > 0) return;
        self.commit_gate_flush_failed = false;
        if (self.commit_gate_logged) {
            debug_trace.eventf("worker", "commit_gate_released", .{ .turn_id = self.active_turn_id }, "worker={x} waited_ms={d} reason={s}", .{ @intFromPtr(self), self.commitGateWaitedMsLocked(), reason });
        }
        self.commit_gate_logged = false;
        self.worker_cond.broadcast(io_mod.getIo());
    }

    fn noteFinishPushedLocked(self: *WorkerRuntime) void {
        self.unacknowledged_finishes +|= 1;
    }

    fn commitGateNowMs() i64 {
        const timestamp = std.Io.Clock.awake.now(io_mod.getIo());
        return @intCast(@divFloor(timestamp.nanoseconds, 1_000_000));
    }

    fn commitGateWaitedMsLocked(self: *WorkerRuntime) i64 {
        return @max(0, commitGateNowMs() - self.commit_gate_since_ms);
    }

    /// The mail the gate holds while a finished turn's commit is
    /// unacknowledged: the head of the queue when it is a continuation and no
    /// compaction is queued. Null when the gate holds nothing.
    fn commitGateHeldHeadLocked(self: *const WorkerRuntime) ?*const QueuedPrompt {
        if (!self.commit_gate or self.unacknowledged_finishes == 0) return null;
        if (self.queued_context_compaction != null or self.queued_prompts.items.len == 0) return null;
        const head = &self.queued_prompts.items[0];
        if (!head.delivery.isContinuation()) return null;
        return head;
    }

    /// Whether the gate holds mail for a commit the loop has not made, and a
    /// flush of the loop's pacer has not failed for it. The main loop asks
    /// while a prompt keeps its pacer from showing the finished turn that
    /// commit waits for, which the next turn's own start would show; that
    /// start is the work the gate holds back.
    pub fn commitGateWaitsForCommit(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.commitGateHeldHeadLocked() != null and !self.commit_gate_flush_failed;
    }

    /// The main loop's note that its flush of the pacer for the held mail
    /// failed. The gate's time limit still ends the hold; the loop does not
    /// try again until the count has reached zero. A flush whose commit failed
    /// has acknowledged it already (`appendFinishedPrompt` does in a `defer`),
    /// so the count may be zero by now: that hold is over, and a mark set for
    /// it would outlive it, since nothing clears a mark at a count of zero.
    pub fn noteCommitGateFlushFailed(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.unacknowledged_finishes > 0) self.commit_gate_flush_failed = true;
    }

    /// Null when the gate lets the next work begin; otherwise how many
    /// milliseconds remain before it gives up. The gate holds only the mail
    /// that missed the turn that just finished (a continuation) while that
    /// turn's commit is unacknowledged: a turn that starts before the commit
    /// writes its first piece into the log while the finished turn is still
    /// open, which supersedes both
    /// (`tests/tla/subagent/MainMail.tla` CommitBeforeNextTurn). Prompts a user
    /// typed, and compaction, are not held.
    ///
    /// What ends the hold: the main loop's acknowledgement (a cancelled turn
    /// still finishes, a failed commit still acknowledges, and a finish the
    /// loop drops unsaved is acknowledged as dropped); a stop of this
    /// worker, which the wait loops check on their own; and
    /// `commit_gate_limit_ms` after the gate first held the mail, when it logs
    /// `commit_gate_expired`, forgets the unacknowledged count, and lets the
    /// mail begin as it did before the gate.
    ///
    /// The limit counts from the first hold, not from the finish push, so
    /// mail that comes later than the limit after the turn ended is held for
    /// the same time as mail that comes at once: the loop's flush for a prompt
    /// that keeps the pacer from showing the turn runs while the hold stands.
    /// `waited_ms` in the trace lines `commit_gate_released` and
    /// `commit_gate_expired` is how long the mail was held in this spell, and
    /// no longer how long ago the finish was pushed.
    fn commitGateRemainingMsLocked(self: *WorkerRuntime) ?i64 {
        const head = self.commitGateHeldHeadLocked() orelse return null;
        if (!self.commit_gate_logged) {
            self.commit_gate_logged = true;
            self.commit_gate_since_ms = commitGateNowMs();
            debug_trace.eventf("worker", "commit_gate_held", .{ .turn_id = head.turn_id }, "worker={x} mail={s} unacknowledged={d}", .{ @intFromPtr(self), @tagName(head.mail), self.unacknowledged_finishes });
        }
        const waited = self.commitGateWaitedMsLocked();
        if (waited >= commit_gate_limit_ms) {
            debug_trace.eventf("worker", "commit_gate_expired", .{ .turn_id = head.turn_id }, "worker={x} unacknowledged={d} waited_ms={d} mail={s} reason=timeout", .{ @intFromPtr(self), self.unacknowledged_finishes, waited, @tagName(head.mail) });
            if (self.queued_history_owed > 0) {
                debug_trace.logf("worker", "queued mail starts without finished turns turns={d} reason=gate_expired dropped=turns_in_queued_history", .{self.queued_history_owed});
            }
            self.unacknowledged_finishes = 0;
            self.queued_history_owed = 0;
            self.commit_gate_logged = false;
            self.commit_gate_flush_failed = false;
            return null;
        }
        return commit_gate_limit_ms - waited;
    }

    /// Waits for a change, at most `remaining_ms`, with `worker_mutex` held.
    /// False when the wait itself failed, as `std.Io.Condition.wait` does when
    /// cancelled.
    fn waitCommitGateLocked(self: *WorkerRuntime, remaining_ms: i64) bool {
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(remaining_ms), .clock = .awake } };
        self.worker_cond.waitTimeout(io_mod.getIo(), &self.worker_mutex, timeout) catch |err| switch (err) {
            error.Timeout => {},
            else => return false,
        };
        return true;
    }

    /// Whether the queued prompt for `turn_id` carries the stale shell
    /// handles note, so a caller that removes it can give the note back.
    pub fn queuedPromptCarriesStaleShellHandles(self: *WorkerRuntime, turn_id: u64) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        for (self.queued_prompts.items) |queued| {
            if (queued.turn_id == turn_id) return queued.stale_shell_handles;
        }
        return false;
    }

    /// What a user's stop on a subagent's screen dropped from its queue.
    pub const MessageDrop = struct { from_parent: usize = 0, total: usize = 0 };

    /// A user's stop on this subagent's own screen: drops the
    /// other agents' messages still waiting in its queue, also the parent's
    /// waiting to join the turn the stop ends, whose receipt then reads not
    /// applied. Reports stay, since they are owed, and so do the user's own
    /// prompts, as on main. `alloc` is the queue's.
    pub fn dropAgentMessages(self: *WorkerRuntime, alloc: std.mem.Allocator) MessageDrop {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        var drop: MessageDrop = .{};
        for (self.held_back_feedback.items) |prompt| {
            debug_trace.eventf("worker", "agent_message_dropped", .{ .turn_id = prompt.turn_id }, "author={s} reason=stopped_by_user", .{@tagName(prompt.author)});
            drop.total += 1;
            if (prompt.author == .parent) drop.from_parent += 1;
            freeQueuedPrompt(alloc, prompt);
        }
        self.held_back_feedback.clearRetainingCapacity();
        var index: usize = 0;
        while (index < self.queued_prompts.items.len) {
            const queued = self.queued_prompts.items[index];
            if (queued.mail != .message and queued.author != .parent) {
                index += 1;
                continue;
            }
            const prompt = self.queued_prompts.orderedRemove(index);
            debug_trace.eventf("worker", "agent_message_dropped", .{ .turn_id = prompt.turn_id }, "author={s} reason=stopped_by_user", .{@tagName(prompt.author)});
            drop.total += 1;
            if (prompt.author == .parent) drop.from_parent += 1;
            freeQueuedPrompt(alloc, prompt);
        }
        if (drop.total > 0 and self.queued_prompts.items.len == 0) {
            types.freeHistoryTurnSlice(alloc, self.queued_history);
            self.queued_history = &.{};
        }
        return drop;
    }

    /// How many of the parent's messages still wait to join the running
    /// turn. Counted after a stop's cancel, it is what the stop drops: the
    /// cancelled turn reads no more of them.
    pub fn queuedParentSteering(self: *WorkerRuntime) usize {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        var count: usize = 0;
        for (self.held_back_feedback.items) |prompt| {
            if (prompt.author == .parent) count += 1;
        }
        for (self.queued_prompts.items) |prompt| {
            if (prompt.author == .parent and prompt.steering_receipt != null) count += 1;
        }
        return count;
    }

    /// A message main steered into a turn that the turn never took.
    pub const LeftoverMessage = struct {
        operation_id: []u8,
        text: []u8,

        pub fn deinit(self: LeftoverMessage, alloc: std.mem.Allocator) void {
            alloc.free(self.operation_id);
            alloc.free(self.text);
        }
    };

    /// Takes the feedback main steered into the turn that just ended and the
    /// turn never took, oldest first: what `hands_back_leftover_feedback` set
    /// aside, then what still waits in the queue. Their receipts read
    /// not_applied. A message it can't copy is dropped and traced. Caller
    /// owns the result.
    pub fn takeLeftoverMessages(self: *WorkerRuntime, alloc: std.mem.Allocator) []LeftoverMessage {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        var taken: std.ArrayList(LeftoverMessage) = .empty;
        for (self.held_back_feedback.items) |prompt| {
            keepLeftover(alloc, &taken, prompt);
            freeQueuedPrompt(alloc, prompt);
        }
        self.held_back_feedback.clearRetainingCapacity();
        var index: usize = 0;
        var removed = false;
        while (index < self.queued_prompts.items.len) {
            const prompt = self.queued_prompts.items[index];
            if (!prompt.delivery.isSteering() or prompt.steering_receipt == null) {
                index += 1;
                continue;
            }
            keepLeftover(alloc, &taken, prompt);
            freeQueuedPrompt(alloc, self.queued_prompts.orderedRemove(index));
            removed = true;
        }
        if (removed and self.queued_prompts.items.len == 0) {
            types.freeHistoryTurnSlice(alloc, self.queued_history);
            self.queued_history = &.{};
        }
        return taken.toOwnedSlice(alloc) catch {
            for (taken.items) |item| {
                debug_trace.eventf("worker", "leftover_steering_dropped", .{}, "operation={s} reason=out_of_memory", .{item.operation_id});
                item.deinit(alloc);
            }
            taken.deinit(alloc);
            return &.{};
        };
    }

    pub fn removeQueuedPrompt(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        turn_id: u64,
        retained_images: []const types.ImageAttachment,
    ) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        var removed: ?QueuedPrompt = null;
        for (self.queued_prompts.items, 0..) |queued, index| {
            if (queued.turn_id != turn_id) continue;
            removed = self.queued_prompts.orderedRemove(index);
            break;
        }
        if (removed != null and self.queued_prompts.items.len == 0) {
            types.freeHistoryTurnSlice(alloc, self.queued_history);
            self.queued_history = &.{};
        }
        const remaining = self.queuedWorkCountLocked();
        self.worker_mutex.unlock(io_mod.getIo());

        const prompt = removed orelse return false;
        discardQueuedPrompt(alloc, prompt, retained_images);
        debug_trace.eventf(
            "worker",
            "queued_prompt_removed",
            .{ .turn_id = turn_id },
            "remaining={d}",
            .{remaining},
        );
        return true;
    }

    /// Removes the newest queued text-only steering prompt that still waits for
    /// a tool or compaction boundary and returns an allocator-owned copy of its
    /// text so the composer can restore it for editing. Returns null when
    /// nothing is safely retractable: no active turn, no wait boundary (an
    /// immediate steer is already committed to its interrupt), a cancel
    /// already in flight, only handoff-class steers with images or skill
    /// bindings, or only steers the user didn't write.
    pub fn popQueuedSteerForEdit(self: *WorkerRuntime, alloc: std.mem.Allocator) !?[]u8 {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (!self.worker_processing or self.active_turn_id == 0) return null;
        if (!self.hasSteeringWaitBoundaryLocked()) return null;
        if (self.worker_cancel_requested.load(.seq_cst)) return null;

        var retractable: ?usize = null;
        var index: usize = self.queued_prompts.items.len;
        while (index > 0) {
            index -= 1;
            const prompt = self.queued_prompts.items[index];
            if (prompt.delivery.activeTurnId() != self.active_turn_id) continue;
            if (!sameTurnSteeringEligible(prompt)) continue;
            // A subagent's report or the parent's message isn't the user's to
            // edit, and taking it back would keep it from the turn.
            if (prompt.author != .user) continue;
            retractable = index;
            break;
        }
        const remove_index = retractable orelse return null;

        const text = try alloc.dupe(u8, self.queued_prompts.items[remove_index].prompt);
        const prompt = self.queued_prompts.orderedRemove(remove_index);
        if (self.queued_prompts.items.len == 0) {
            types.freeHistoryTurnSlice(alloc, self.queued_history);
            self.queued_history = &.{};
        }
        // A tool yield stands only for steering that still waits for the turn.
        const yield_still_wanted = for (self.queued_prompts.items) |queued| {
            if (queued.delivery.activeTurnId() == self.active_turn_id and yieldsRunningTools(queued)) break true;
        } else false;
        if (!yield_still_wanted) self.clearToolYieldLocked();
        const turn_id = prompt.turn_id;
        const remaining = self.queuedWorkCountLocked();
        freeQueuedPrompt(alloc, prompt);
        debug_trace.eventf(
            "worker",
            "prompt_steering_retracted",
            .{ .turn_id = turn_id },
            "remaining={d}",
            .{remaining},
        );
        self.worker_cond.broadcast(io_mod.getIo());
        return text;
    }

    pub fn waitAndTakeNextPrompt(self: *WorkerRuntime, alloc: std.mem.Allocator) !?QueuedPrompt {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        while (true) {
            // Leftover steering is not work: with only that queued, wait on.
            if (self.hands_back_leftover_feedback) self.handBackLeftoverFeedbackLocked(alloc);
            const gate_ms = self.commitGateRemainingMsLocked();
            if (!((self.queued_prompts.items.len == 0 or self.turn_start_held or self.session_transition_held or gate_ms != null) and
                !self.worker_stop_requested)) break;
            self.worker_processing = false;
            self.active_turn_id = 0;
            self.tool_phase_step_id = null;
            if (gate_ms) |ms| {
                if (!self.waitCommitGateLocked(ms)) break;
            } else {
                self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch break;
            }
        }
        return self.takeNextPromptLocked(alloc);
    }

    pub fn waitAndTakeNextWork(self: *WorkerRuntime, alloc: std.mem.Allocator) !?WorkItem {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        while (true) {
            // Leftover steering is not work: with only that queued, wait on.
            if (self.hands_back_leftover_feedback) self.handBackLeftoverFeedbackLocked(alloc);
            const gate_ms = self.commitGateRemainingMsLocked();
            if (!(((self.queued_prompts.items.len == 0 and
                self.queued_context_compaction == null) or self.turn_start_held or
                self.session_transition_held or gate_ms != null) and !self.worker_stop_requested)) break;
            self.worker_processing = false;
            self.active_turn_id = 0;
            self.tool_phase_step_id = null;
            if (gate_ms) |ms| {
                if (!self.waitCommitGateLocked(ms)) break;
            } else {
                self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch break;
            }
        }
        return self.takeNextWorkLocked(alloc);
    }

    /// Hands back main's feedback whose turn has ended, for
    /// `hands_back_leftover_feedback`. Steering a turn takes in is consumed at
    /// its steering boundaries, so feedback still queued when a turn is about
    /// to start or a run's prompt is queued outlived its own. Dropping it
    /// settles its receipt as not applied, and the host sends it again as new
    /// work. Steering without a receipt stays, to run as the next turn.
    fn handBackLeftoverFeedbackLocked(self: *WorkerRuntime, alloc: std.mem.Allocator) void {
        var index: usize = 0;
        var dropped = false;
        while (index < self.queued_prompts.items.len) {
            const prompt = self.queued_prompts.items[index];
            if (!prompt.delivery.isSteering() or prompt.steering_receipt == null) {
                index += 1;
                continue;
            }
            const held = self.queued_prompts.orderedRemove(index);
            dropped = true;
            self.held_back_feedback.append(alloc, held) catch {
                debug_trace.eventf("worker", "leftover_steering_dropped", .{ .turn_id = held.turn_id }, "bytes={d} reason=out_of_memory", .{held.prompt.len});
                freeQueuedPrompt(alloc, held);
                continue;
            };
            debug_trace.eventf("worker", "leftover_steering_held", .{ .turn_id = held.turn_id }, "bytes={d} reason=turn_ended", .{held.prompt.len});
        }
        // The queue's history belongs to its first prompt. With none left the
        // next prompt queued supplies its own; otherwise it stays with the
        // prompt now first.
        if (dropped and self.queued_prompts.items.len == 0) {
            types.freeHistoryTurnSlice(alloc, self.queued_history);
            self.queued_history = &.{};
        }
    }

    /// Nonblocking queue take for single-threaded hosts. Returns null while the
    /// queue is empty, held, or stopped.
    fn tryTakeNextPrompt(self: *WorkerRuntime, alloc: std.mem.Allocator) !?QueuedPrompt {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.hands_back_leftover_feedback) self.handBackLeftoverFeedbackLocked(alloc);
        if (self.queued_prompts.items.len == 0 or
            self.turn_start_held or self.session_transition_held or
            self.worker_stop_requested or self.commitGateRemainingMsLocked() != null)
        {
            return null;
        }
        return self.takeNextPromptLocked(alloc);
    }

    pub fn tryTakeNextWork(self: *WorkerRuntime, alloc: std.mem.Allocator) !?WorkItem {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.hands_back_leftover_feedback) self.handBackLeftoverFeedbackLocked(alloc);
        if ((self.queued_prompts.items.len == 0 and
            self.queued_context_compaction == null) or self.turn_start_held or
            self.session_transition_held or self.worker_stop_requested or
            self.commitGateRemainingMsLocked() != null)
        {
            return null;
        }
        return self.takeNextWorkLocked(alloc);
    }

    fn takeNextWorkLocked(self: *WorkerRuntime, alloc: std.mem.Allocator) !?WorkItem {
        if (self.worker_stop_requested) return null;
        if (self.queued_context_compaction) |task| {
            self.queued_context_compaction = null;
            self.turn_cancel_requested.store(false, .seq_cst);
            self.worker_cancel_requested.store(false, .seq_cst);
            self.worker_processing = true;
            self.active_turn_id = task.turn_id;
            self.tool_phase_step_id = null;
            self.clearToolYieldLocked();
            self.active_context_compaction = true;
            if (task.operation_id) |id| self.compaction_presentation.running(id, .preparation);
            debug_trace.eventf(
                "worker",
                "context_compaction_begin",
                .{ .turn_id = task.turn_id },
                "remaining_queue={d} cancel_reset=true",
                .{self.queuedWorkCountLocked()},
            );
            return .{ .compact_context = task };
        }
        const prompt = (try self.takeNextPromptLocked(alloc)) orelse return null;
        return .{ .prompt = prompt };
    }

    fn takeNextPromptLocked(self: *WorkerRuntime, alloc: std.mem.Allocator) !?QueuedPrompt {
        if (self.worker_stop_requested or self.queued_prompts.items.len == 0) return null;

        const queued = self.queued_prompts.items[0];
        const transfer_history = self.queued_prompts.items.len == 1;
        const job_history = if (transfer_history)
            self.queued_history
        else
            try session_runtime.snapshotOwnedContextHistory(
                alloc,
                self.queued_history,
                0,
                0,
            );
        errdefer if (!transfer_history) {
            types.freeHistoryTurnSlice(alloc, job_history);
        };
        if (queued.recovery_resume != null) {
            try self.worker_events.append(alloc, .{
                .begin_resumed_prompt = queued.turn_id,
            });
        } else if (queued.recovery_checkpoint == null and queued.user_prompt_already_presented) {
            try self.worker_events.append(alloc, .{
                .begin_presented_prompt = queued.turn_id,
            });
        } else if (queued.recovery_checkpoint == null) {
            const begin_prompt = try types.dupeUserTurn(alloc, .{ .text = queued.prompt, .images = queued.images, .work_id = queued.work_id, .author = queued.author });
            errdefer types.freeUserTurn(alloc, begin_prompt);
            if (queued.skill_bindings.len > 0 or queued.skill_display_spans.len > 0) {
                const skill_bindings = try dupeSkillBindings(alloc, queued.skill_bindings);
                errdefer freeSkillBindings(alloc, skill_bindings);
                const skill_display_spans = try dupeSkillDisplaySpans(alloc, queued.skill_display_spans);
                errdefer freeSkillDisplaySpans(alloc, skill_display_spans);
                try self.worker_events.append(alloc, .{
                    .begin_prompt_with_skill_bindings = .{
                        .prompt = begin_prompt,
                        .skill_bindings = skill_bindings,
                        .skill_display_spans = skill_display_spans,
                    },
                });
            } else {
                try self.worker_events.append(alloc, .{ .begin_prompt = begin_prompt });
            }
        }

        var job = self.queued_prompts.orderedRemove(0);
        if (transfer_history) self.queued_history = &.{};
        job.history = job_history;
        self.steering_cancel_turn_id = null;
        self.turn_cancel_requested.store(false, .seq_cst);
        self.worker_cancel_requested.store(false, .seq_cst);
        self.worker_processing = true;
        self.active_turn_id = job.turn_id;
        self.tool_phase_step_id = null;
        self.clearToolYieldLocked();
        if (typedByUser(job)) self.noteTypedLocked(alloc, job.turn_id, job.prompt);
        // The last turn's final boundary closed it to messages; this one
        // starts open, as a direct turn does.
        self.direct_steering_closed = false;
        // A turn takes in the messages waiting right behind it, in order, up
        // to the first prompt that needs a turn of its own, so none passes it.
        var absorbed: usize = 0;
        for (self.queued_prompts.items) |*prompt| {
            if (!prompt.delivery.isContinuation() or !sameTurnSteeringEligible(prompt.*)) break;
            prompt.delivery = .{ .active_turn = job.turn_id };
            absorbed += 1;
        }
        if (absorbed > 0) debug_trace.eventf("worker", "continuations_absorbed", .{ .turn_id = job.turn_id }, "count={d}", .{absorbed});
        self.active_context_compaction = false;
        debug_trace.logf(
            "worker",
            "begin prompt bytes={d} remaining_queue={d} fast_mode={s} effort={s}",
            .{ job.prompt.len, self.queuedWorkCountLocked(), if (job.agent_settings.fast_mode) "true" else "false", job.agent_settings.effort.label() },
        );
        debug_trace.eventf(
            "worker",
            "worker_begin",
            .{ .turn_id = job.turn_id },
            "prompt_bytes={d} remaining_queue={d} cancel_reset=true fast_mode={s} effort={s}",
            .{ job.prompt.len, self.queuedWorkCountLocked(), if (job.agent_settings.fast_mode) "true" else "false", job.agent_settings.effort.label() },
        );
        return job;
    }

    pub fn finishProcessing(self: *WorkerRuntime) void {
        debug_trace.logf("worker", "finish processing queued={d}", .{self.queuedPromptCount()});
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        // Close steering admission without moving entries, preserving the exact
        // order in which steering and ordinary prompts were submitted.
        const finished_turn_id = self.active_turn_id;
        self.finishCompactionActivityLocked(finished_turn_id);
        var deferred: usize = 0;
        for (self.queued_prompts.items) |*prompt| {
            if (prompt.delivery.activeTurnId() == finished_turn_id) {
                prompt.delivery = .continuation;
                deferred += 1;
                debug_trace.eventf("worker", "steering_deferred_to_next_turn", .{ .turn_id = finished_turn_id }, "queued_turn_id={d} prompt_bytes={d}", .{ prompt.turn_id, prompt.prompt.len });
            }
        }
        debug_trace.eventf("worker", "processing_finished", .{ .turn_id = finished_turn_id }, "worker={x} deferred={d}", .{ @intFromPtr(self), deferred });
        self.worker_processing = false;
        self.active_turn_id = 0;
        self.steering_cancel_turn_id = null;
        self.clearActiveToolCallsLocked();
        self.tool_phase_step_id = null;
        self.clearToolYieldLocked();
        self.active_context_compaction = false;
        self.worker_cond.broadcast(io_mod.getIo());
        self.worker_mutex.unlock(io_mod.getIo());
    }

    /// Marks an agent turn that is executed directly rather than dequeued by
    /// the interactive worker loop. The caller must pair a successful begin
    /// with `finishProcessing`.
    pub fn beginDirectProcessing(self: *WorkerRuntime, turn_id: u64) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.worker_processing or self.worker_stop_requested) return false;
        self.direct_steering_closed = false;
        self.turn_cancel_requested.store(false, .seq_cst);
        self.worker_cancel_requested.store(false, .seq_cst);
        self.worker_processing = true;
        self.active_turn_id = turn_id;
        self.tool_phase_step_id = null;
        self.clearToolYieldLocked();
        debug_trace.eventf("worker", "processing_begun", .{ .turn_id = turn_id }, "worker={x} queued={d}", .{ @intFromPtr(self), self.queued_prompts.items.len });
        return true;
    }

    const ActiveToolTransition = union(enum) {
        none,
        started: []u8,
        terminal: []const u8,
        clear,

        fn deinit(self: *ActiveToolTransition, alloc: std.mem.Allocator) void {
            switch (self.*) {
                .started => |call_id| alloc.free(call_id),
                .none, .terminal, .clear => {},
            }
            self.* = .none;
        }
    };

    fn prepareActiveToolTransitionLocked(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        event: WorkerEvent,
    ) !ActiveToolTransition {
        return switch (event) {
            .tool_lifecycle => |lifecycle| switch (lifecycle) {
                .authoritative_started => |started| blk: {
                    if (started.id.turn_id != self.active_turn_id or
                        self.active_tool_calls.contains(started.id.call_id))
                    {
                        break :blk .none;
                    }
                    if (self.active_tool_allocator == null) {
                        self.active_tool_allocator = alloc;
                    }
                    try self.active_tool_calls.ensureUnusedCapacity(alloc, 1);
                    break :blk .{ .started = try alloc.dupe(u8, started.id.call_id) };
                },
                .terminal => |terminal| if (terminal.id.turn_id == self.active_turn_id and
                    self.active_tool_calls.contains(terminal.id.call_id))
                    .{ .terminal = terminal.id.call_id }
                else
                    .none,
                .turn_finished => |finished| if (finished.turn_id == self.active_turn_id) .clear else .none,
                .provisional, .progress => .none,
            },
            else => .none,
        };
    }

    fn applyActiveToolTransitionLocked(
        self: *WorkerRuntime,
        transition: ActiveToolTransition,
    ) void {
        switch (transition) {
            .none => {},
            .started => |call_id| {
                self.active_tool_calls.putAssumeCapacity(call_id, {});
            },
            .terminal => |call_id| {
                const removed = self.active_tool_calls.fetchRemove(call_id) orelse return;
                std.debug.assert(self.active_tool_allocator != null);
                const alloc = self.active_tool_allocator.?;
                alloc.free(removed.key);
            },
            .clear => self.clearActiveToolCallsLocked(),
        }
    }

    fn applyToolBoundaryPhaseLocked(self: *WorkerRuntime, event: WorkerEvent) void {
        switch (event) {
            .turn_phase_update => |update| if (update.turn_id == self.active_turn_id) {
                switch (update.phase) {
                    .running => self.tool_phase_step_id = update.step_id,
                    .waiting_for_subagent => {},
                    .thinking, .generating => if (self.tool_phase_step_id != update.step_id) {
                        self.tool_phase_step_id = null;
                    },
                }
            },
            else => {},
        }
    }

    fn hasActiveToolBoundaryLocked(self: *const WorkerRuntime) bool {
        return self.tool_phase_step_id != null or self.active_tool_calls.count() > 0;
    }

    /// True while a context compaction owns the worker: either the compaction
    /// work item is running, or the active turn is inside a compaction
    /// transaction. Compaction reports through the activity channel rather
    /// than the tool/phase event feed, so it is consulted separately.
    fn compactionInFlightLocked(self: *const WorkerRuntime) bool {
        if (self.active_context_compaction) return true;
        if (self.compaction_presentation.snapshot.operation) |operation| return operation.active();
        return false;
    }

    /// Steering must wait whenever the active work cannot absorb guidance right
    /// now: a running tool or tool-producing step, or a compaction in flight.
    /// Cancelling either would discard in-progress work the user expects to
    /// finish; the message is delivered at the next boundary instead.
    fn hasSteeringWaitBoundaryLocked(self: *const WorkerRuntime) bool {
        return self.hasActiveToolBoundaryLocked() or self.compactionInFlightLocked();
    }

    fn clearActiveToolCallsLocked(self: *WorkerRuntime) void {
        const alloc = self.active_tool_allocator orelse {
            std.debug.assert(self.active_tool_calls.count() == 0);
            return;
        };
        var keys = self.active_tool_calls.keyIterator();
        while (keys.next()) |key| alloc.free(@constCast(key.*));
        self.active_tool_calls.deinit(alloc);
        self.active_tool_calls = .empty;
        self.active_tool_allocator = null;
    }

    pub fn waitUntilIdle(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        while (self.worker_processing) {
            self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch break;
        }
    }

    pub fn isProcessing(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.worker_processing;
    }

    pub fn snapshotState(
        self: *WorkerRuntime,
        _: std.mem.Allocator,
    ) error{OutOfMemory}!StateSnapshot {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const cancel_requested = self.worker_cancel_requested.load(.seq_cst);
        return .{
            .processing = self.worker_processing,
            .active_turn_id = self.active_turn_id,
            .queued_count = self.queuedWorkCountLocked(),
            .pending_event_count = self.worker_events.items.len,
            .cancel_requested = cancel_requested,
            .cancel_continues_turn = cancel_requested and
                self.steering_cancel_turn_id == self.active_turn_id,
        };
    }

    pub fn activeTurnId(self: *WorkerRuntime) u64 {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.active_turn_id;
    }

    /// Returns one coherent, allocator-owned steering presentation snapshot.
    /// Its messages are the steering `previewsAsSteering` shows.
    pub fn snapshotSteeringPresentation(self: *WorkerRuntime, alloc: std.mem.Allocator) !SteeringPresentationSnapshot {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        var steering_count: usize = 0;
        for (self.queued_prompts.items) |prompt| {
            if (previewsAsSteering(prompt)) steering_count += 1;
        }
        var snapshot: SteeringPresentationSnapshot = .{
            .waits_for_boundary = steering_count > 0 and self.hasSteeringWaitBoundaryLocked(),
        };
        errdefer snapshot.deinit(alloc);
        snapshot.pending_feedback = pending: {
            var count: usize = 0;
            for (self.worker_events.items) |event| {
                if (event == .append_user_feedback) count += 1;
            }
            if (count == 0) break :pending &.{};
            const feedback = try alloc.alloc([]u8, count);
            errdefer alloc.free(feedback);
            var written: usize = 0;
            errdefer for (feedback[0..written]) |message| alloc.free(message);
            for (self.worker_events.items) |event| {
                if (event == .append_user_feedback) {
                    feedback[written] = try alloc.dupe(u8, event.append_user_feedback);
                    written += 1;
                }
            }
            break :pending feedback;
        };
        if (steering_count == 0) return snapshot;

        const messages = try alloc.alloc([]u8, steering_count);
        var copied: usize = 0;
        errdefer {
            for (messages[0..copied]) |message| alloc.free(message);
            alloc.free(messages);
        }
        for (self.queued_prompts.items) |prompt| {
            if (!previewsAsSteering(prompt)) continue;
            messages[copied] = try alloc.dupe(u8, prompt.prompt);
            copied += 1;
        }
        snapshot.messages = messages;
        return snapshot;
    }

    pub fn queuedPromptCount(self: *WorkerRuntime) usize {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.queuedWorkCountLocked();
    }

    pub fn clearQueuedPrompts(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        retained_images: []const types.ImageAttachment,
    ) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        self.clearQueuedPromptsLocked(alloc, retained_images);
    }

    /// Clears the queue while atomically transferring deletion responsibility
    /// for a matching active or finished turn to the supplied retained images.
    pub fn clearQueuedPromptsForSessionTransition(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        turn_id: u64,
        retained_images: []const types.ImageAttachment,
    ) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        if (retained_images.len > 0) {
            _ = self.preservePromptSnapshotsLocked(turn_id, retained_images);
        }
        self.clearQueuedPromptsLocked(alloc, retained_images);
    }

    fn clearQueuedPromptsLocked(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        retained_images: []const types.ImageAttachment,
    ) void {
        const dropped = self.queuedWorkCountLocked();
        if (dropped > 0) {
            debug_trace.logf("worker", "clear queued prompts dropped={d}", .{dropped});
            debug_trace.eventf("worker", "queued_prompts_cleared", .{}, "dropped={d}", .{dropped});
        }
        for (self.queued_prompts.items) |prompt| {
            discardQueuedPrompt(alloc, prompt, retained_images);
        }
        self.queued_prompts.clearRetainingCapacity();
        types.freeHistoryTurnSlice(alloc, self.queued_history);
        self.queued_history = &.{};
        self.queued_history_owed = 0;
        if (self.queued_context_compaction) |task| {
            if (task.operation_id) |id| self.compaction_presentation.settle(id, .{ .outcome = .cancelled }, io_mod.milliTimestamp());
            freeContextCompactionTask(alloc, task);
            self.queued_context_compaction = null;
        }
        self.worker_cond.broadcast(io_mod.getIo());
    }

    /// Drops every queued event, as a live session switch does. A finish among
    /// them will never be committed, so the commit gate stops waiting for it.
    pub fn discardEvents(self: *WorkerRuntime, alloc: std.mem.Allocator) void {
        var events = self.takeEvents();
        defer events.deinit(alloc);
        var finishes: u32 = 0;
        for (events.items) |event| {
            if (event == .finish_prompt) finishes += 1;
            freeWorkerEvent(alloc, event);
        }
        if (finishes == 0) return;
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (!self.commit_gate) return;
        debug_trace.eventf("worker", "commit_gate_finish_dropped", .{ .turn_id = self.active_turn_id }, "worker={x} count={d} unacknowledged={d} reason=events_discarded", .{ @intFromPtr(self), finishes, self.unacknowledged_finishes });
        self.releaseFinishesLocked(finishes, "events_discarded");
    }

    pub fn syncQueuedPromptModel(self: *WorkerRuntime, alloc: std.mem.Allocator, model: []const u8) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        for (self.queued_prompts.items) |*prompt| {
            const next_model = try alloc.dupe(u8, model);
            alloc.free(prompt.model);
            prompt.model = next_model;
        }
    }

    pub fn syncQueuedPromptFastMode(self: *WorkerRuntime, enabled: bool) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.agent_turn_settings.fast_mode = enabled;
        for (self.queued_prompts.items) |*prompt| prompt.agent_settings.fast_mode = enabled;
    }

    pub fn syncQueuedPromptUltrafastMode(self: *WorkerRuntime, enabled: bool) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.agent_turn_settings.ultrafast_mode = enabled;
        for (self.queued_prompts.items) |*prompt| prompt.agent_settings.ultrafast_mode = enabled;
    }

    pub fn syncQueuedPromptEffort(self: *WorkerRuntime, effort: types.ReasoningEffort) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.agent_turn_settings.effort = effort;
        for (self.queued_prompts.items) |*prompt| prompt.agent_settings.effort = effort;
    }

    pub fn setActiveAgentTurnSettings(self: *WorkerRuntime, settings: AgentTurnSettings) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.active_agent_turn_settings = settings;
    }

    pub fn clearActiveAgentTurnSettings(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.active_agent_turn_settings = null;
    }

    pub fn effectiveAgentTurnSettings(self: *WorkerRuntime) AgentTurnSettings {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.active_agent_turn_settings orelse self.agent_turn_settings;
    }

    pub fn propagateHistoryTurn(self: *WorkerRuntime, alloc: std.mem.Allocator, turn: types.HistoryTurn, max_history_turns: usize) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        try self.propagateHistoryTurnLocked(alloc, turn, max_history_turns, null);
    }

    pub fn commitContextCompaction(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        summary: types.CompactedSummaryHistoryTurn,
        active_prefix: ?types.AssistantHistoryTurn,
        retained_from: ?types.ContextHistoryCut,
        max_history_turns: usize,
    ) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        try self.awaitHistoryPublicationLocked(alloc, .{
            .context_compaction = .{
                .turn_id = self.active_turn_id,
                .summary = summary,
                .active_prefix = active_prefix,
                .retained_from = retained_from,
                .max_history_turns = max_history_turns,
            },
        });
    }

    fn awaitHistoryPublicationLocked(self: *WorkerRuntime, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        if (self.worker_stop_requested or self.isCancelRequested()) return error.Aborted;
        std.debug.assert(self.history_publication_response == .idle);
        const owned_event = try dupeWorkerEvent(alloc, event);
        var owns_event = true;
        defer if (owns_event) freeWorkerEvent(alloc, owned_event);
        try self.worker_events.ensureUnusedCapacity(alloc, 1);
        self.history_publication_response = .{ .waiting = self.active_turn_id };
        defer self.history_publication_response = .idle;
        self.worker_events.appendAssumeCapacity(owned_event);
        owns_event = false;
        self.worker_cond.broadcast(io_mod.getIo());

        while (self.history_publication_response == .waiting and
            !self.worker_stop_requested and !self.isCancelRequested())
        {
            try self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex);
        }
        switch (self.history_publication_response) {
            .committed => return,
            .failed => |err| return err,
            .waiting, .idle => return error.Aborted,
        }
    }

    pub fn failPendingHistoryPublication(self: *WorkerRuntime, err: anyerror) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.history_publication_response != .waiting) return;
        self.history_publication_response = .{ .failed = err };
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn resolveContextCompaction(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        event: ContextCompaction,
        ctx: *anyopaque,
        handler: ContextCompactionHandler,
    ) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.history_publication_response != .waiting or
            self.history_publication_response.waiting != event.turn_id)
        {
            debug_trace.logf("worker", "compaction delivery dropped reason=stale turn_id={d}", .{event.turn_id});
            return;
        }
        defer self.worker_cond.broadcast(io_mod.getIo());
        if (self.worker_stop_requested or self.isCancelRequested()) {
            self.history_publication_response = .{ .failed = error.Aborted };
            return;
        }
        self.publishContextCompactionLocked(alloc, event, ctx, handler) catch |err| {
            self.history_publication_response = .{ .failed = err };
            return;
        };
        self.history_publication_response = .committed;
    }

    pub fn publishContextCompaction(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        event: ContextCompaction,
        ctx: *anyopaque,
        handler: ContextCompactionHandler,
    ) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        try self.publishContextCompactionLocked(alloc, event, ctx, handler);
    }

    fn publishContextCompactionLocked(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        event: ContextCompaction,
        ctx: *anyopaque,
        handler: ContextCompactionHandler,
    ) !void {
        var publication: ContextCompactionPublication = .{ .ctx = ctx, .handler = handler, .event = event };
        try self.propagateHistoryTurnLocked(
            alloc,
            .{ .compacted_summary = event.summary },
            event.max_history_turns,
            .{ .ctx = &publication, .commit_fn = ContextCompactionPublication.commit, .retained_from = event.retained_from },
        );
        if (event.active_prefix != null) {
            if (self.active_prompt_snapshot_ownership) |ownership| {
                _ = ownership.preserve();
            }
        }
    }

    fn propagateHistoryTurnLocked(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        turn: types.HistoryTurn,
        max_history_turns: usize,
        publication: ?HistoryPublication,
    ) !void {
        self.propagateHistoryTurnToQueue(alloc, turn, max_history_turns, publication, .active) catch |err| {
            if (err == error.SessionPersistenceUncertain) {
                if (self.active_prompt_snapshot_ownership) |ownership| {
                    _ = ownership.preserve();
                }
            }
            return err;
        };
    }

    /// Where the snapshot files that each queued prompt keeps for the turn come
    /// from: the turn the worker is running, or, for a turn the loop commits
    /// after the worker finished it, the ownership the finished turn carries.
    const PropagatedOwnership = union(enum) {
        active,
        given: ?types.SnapshotFileOwnership,
    };

    fn propagateHistoryTurnToQueue(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        turn: types.HistoryTurn,
        max_history_turns: usize,
        publication: ?HistoryPublication,
        source: PropagatedOwnership,
    ) !void {
        if (self.queued_prompts.items.len == 0) {
            if (publication) |value| try value.commit();
            return;
        }
        const active_ownership = switch (source) {
            .active => if (self.active_prompt_snapshot_ownership) |ownership|
                try ownership.ensureSharedOwnership(alloc)
            else
                null,
            .given => |ownership| ownership,
        };
        const cut = if (publication) |value| value.retained_from else null;
        const next_history = if (cut) |retained_from| try session_runtime.prepareCompactedHistory(alloc, self.queued_history, turn.compacted_summary, retained_from) else try appendHistoryTurnProjection(
            alloc,
            self.queued_history,
            turn,
            max_history_turns,
        );
        var next_history_owned = true;
        defer if (next_history_owned) types.freeHistoryTurnSlice(alloc, next_history);
        const prepared = try alloc.alloc(
            PreparedHistoryPropagation,
            self.queued_prompts.items.len,
        );
        var prepared_count: usize = 0;
        var committed = false;
        defer {
            if (!committed) {
                for (prepared[0..prepared_count]) |entry| entry.deinit(alloc);
            }
            alloc.free(prepared);
        }

        while (prepared_count < self.queued_prompts.items.len) : (prepared_count += 1) {
            const prompt = self.queued_prompts.items[prepared_count];
            const next_image_catalog = try session_runtime.merge_image_catalog_history_turn(
                alloc,
                prompt.authorized_image_catalog,
                turn,
            );
            errdefer types.freeImageAttachmentSlice(alloc, next_image_catalog);
            const next_root_user_intent_context = try alloc.dupe(u8, prompt.root_user_intent_context);
            errdefer alloc.free(next_root_user_intent_context);
            const next_snapshot_file_ownerships = if (active_ownership) |ownership| blk: {
                const ownership_count = std.math.add(
                    usize,
                    prompt.snapshot_file_ownerships.len,
                    1,
                ) catch return error.OutOfMemory;
                const ownerships = try alloc.alloc(
                    types.SnapshotFileOwnership,
                    ownership_count,
                );
                @memmove(
                    ownerships[0..prompt.snapshot_file_ownerships.len],
                    prompt.snapshot_file_ownerships,
                );
                ownership.retain();
                ownerships[prompt.snapshot_file_ownerships.len] = ownership;
                break :blk ownerships;
            } else null;
            errdefer {
                if (next_snapshot_file_ownerships) |ownerships| {
                    ownerships[ownerships.len - 1].release();
                    alloc.free(ownerships);
                }
            }

            prepared[prepared_count] = .{
                .root_user_intent_context = next_root_user_intent_context,
                .authorized_image_catalog = next_image_catalog,
                .snapshot_file_ownerships = next_snapshot_file_ownerships,
                .added_snapshot_ownership = if (next_snapshot_file_ownerships) |ownerships|
                    ownerships[ownerships.len - 1]
                else
                    null,
            };
        }

        if (publication) |value| try value.commit();
        if (next_history.len <= self.queued_history.len) {
            debug_trace.logf("worker", "queued history replaced by context checkpoint turns={d}", .{self.queued_history.len});
        }
        types.freeHistoryTurnSlice(alloc, self.queued_history);
        self.queued_history = next_history;
        next_history_owned = false;
        for (self.queued_prompts.items, prepared) |*prompt, next| {
            if (turn == .compacted_summary) prompt.unversioned_history_count = 0;
            if (prompt.root_user_intent_context.len > 0) alloc.free(prompt.root_user_intent_context);
            prompt.root_user_intent_context = next.root_user_intent_context;
            types.freeImageAttachmentSlice(alloc, prompt.authorized_image_catalog);
            prompt.authorized_image_catalog = next.authorized_image_catalog;
            if (next.snapshot_file_ownerships) |ownerships| {
                if (prompt.snapshot_file_ownerships.len > 0) {
                    alloc.free(prompt.snapshot_file_ownerships);
                }
                prompt.snapshot_file_ownerships = ownerships;
            }
        }
        committed = true;
    }

    pub fn beginActivePromptSnapshots(
        self: *WorkerRuntime,
        ownership: *ActivePromptSnapshotOwnership,
    ) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        std.debug.assert(self.active_prompt_snapshot_ownership == null);
        if (self.preserve_prompt_snapshot_turn_id == self.active_turn_id) {
            _ = ownership.preserve();
            self.preserve_prompt_snapshot_turn_id = null;
        }
        self.active_prompt_snapshot_ownership = ownership;
    }

    pub fn handoffActivePromptSnapshots(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
    ) !?types.SnapshotFileOwnership {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const ownership = self.active_prompt_snapshot_ownership orelse return null;
        return ownership.handoff(alloc);
    }

    pub fn endActivePromptSnapshots(
        self: *WorkerRuntime,
        ownership: *ActivePromptSnapshotOwnership,
    ) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        std.debug.assert(self.active_prompt_snapshot_ownership == ownership);
        self.active_prompt_snapshot_ownership = null;
        ownership.deinit();
    }

    fn preservePromptSnapshotsLocked(
        self: *WorkerRuntime,
        turn_id: u64,
        images: []const types.ImageAttachment,
    ) bool {
        if (turn_id == 0 or images.len == 0) return false;

        var preserved = false;
        if (self.active_turn_id == turn_id) {
            if (self.active_prompt_snapshot_ownership) |ownership| {
                if (sameImageSnapshots(ownership.images, images)) {
                    preserved = ownership.preserve();
                }
            } else {
                // The unique active turn bridges queue take to ownership
                // registration while both operations remain mutex-serialized.
                self.preserve_prompt_snapshot_turn_id = turn_id;
                preserved = true;
            }
        }
        for (self.worker_events.items) |*event| {
            if (event.* != .finish_prompt) continue;
            const finished = &event.finish_prompt;
            const finished_images = historyTurnImages(finished.turn);
            if (!sameImageSnapshots(finished_images, images)) continue;
            if (finished.snapshot_file_ownership) |ownership| {
                ownership.transfer();
                preserved = true;
            }
        }
        return preserved;
    }

    /// What a turn waits for the user to answer.
    pub const UserWait = enum { question };

    /// What the running turn waits for the user to answer, or null. It reads
    /// atomics, so any thread may call it with any lock held.
    pub fn userWait(self: *const WorkerRuntime) ?UserWait {
        if (self.question_waits.load(.acquire) > 0) return .question;
        return null;
    }

    pub fn requestQuestionBatchAnswerBlocking(self: *WorkerRuntime, alloc: std.mem.Allocator, entries: []const types.QuestionBatchEntry) !?[][]u8 {
        return self.requestQuestionBatchAnswerBlockingWithSource(alloc, entries, .agent_question);
    }

    pub fn requestRouteRecoveryAnswerBlocking(self: *WorkerRuntime, alloc: std.mem.Allocator, entries: []const types.QuestionBatchEntry) !?[][]u8 {
        return self.requestQuestionBatchAnswerBlockingWithSource(alloc, entries, .route_recovery);
    }

    pub fn requestMcpElicitationAnswerBlocking(self: *WorkerRuntime, alloc: std.mem.Allocator, entries: []const types.QuestionBatchEntry) !?[][]u8 {
        return self.requestQuestionBatchAnswerBlockingWithSource(alloc, entries, .mcp_elicitation);
    }

    fn requestQuestionBatchAnswerBlockingWithSource(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        entries: []const types.QuestionBatchEntry,
        source: QuestionPromptSource,
    ) !?[][]u8 {
        const owned = try dupeOwnedQuestionBatch(alloc, entries, source);
        var owns_pending_question = true;
        errdefer if (owns_pending_question) freeOwnedQuestionBatch(alloc, owned);

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        std.debug.assert(self.pending_question_shared == null);
        self.pending_question_shared = owned;
        freeQuestionResponse(alloc, self.pending_question_response);
        self.pending_question_response = .pending;
        self.worker_events.append(alloc, .question_requested) catch |err| {
            self.pending_question_shared = null;
            self.pending_question_response = .pending;
            return err;
        };
        // Under the same lock as every other queued event's line.
        if (self.trace_agent) |agent| {
            debug_trace.eventf("host", "agent_event_queued", .{}, "agent={s} kind={s}", .{ agent, traceKind(.question_requested) });
        }
        owns_pending_question = false;
        self.worker_cond.broadcast(io_mod.getIo());

        _ = self.question_waits.fetchAdd(1, .release);
        while (self.pending_question_response == .pending and !self.worker_stop_requested) {
            self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch break;
        }
        _ = self.question_waits.fetchSub(1, .release);

        if (self.pending_question_shared) |pending| {
            freeOwnedQuestionBatch(alloc, pending);
            self.pending_question_shared = null;
        }

        const response = self.pending_question_response;
        self.pending_question_response = .pending;
        return switch (response) {
            .answered => |labels| labels,
            .cancelled, .pending => null,
        };
    }

    pub fn submitQuestionBatchAnswer(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        answers: ?[]const []const u8,
        on_resume: ?QuestionResumeObserver,
    ) !void {
        var new_response: QuestionResponse = .cancelled;
        if (answers) |labels| {
            const dup = try alloc.alloc([]u8, labels.len);
            errdefer alloc.free(dup);
            var filled: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < filled) : (i += 1) alloc.free(dup[i]);
            }
            while (filled < labels.len) : (filled += 1) dup[filled] = try alloc.dupe(u8, labels[filled]);
            new_response = .{ .answered = dup };
        }

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.pending_question_shared == null or self.pending_question_response != .pending) {
            freeQuestionResponse(alloc, new_response);
            debug_trace.logf("worker", "ignored late question response pending=false", .{});
            return;
        }
        freeQuestionResponse(alloc, self.pending_question_response);
        self.pending_question_response = new_response;
        if (answers != null) {
            if (on_resume) |observer| observer.run(observer.ctx);
        }
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn cancelPendingQuestionBatch(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.pending_question_shared == null or self.pending_question_response != .pending) return false;
        self.pending_question_response = .cancelled;
        self.worker_cond.broadcast(io_mod.getIo());
        return true;
    }

    pub fn snapshotPendingQuestionBatch(self: *WorkerRuntime, alloc: std.mem.Allocator) !?PendingQuestionBatchSnapshot {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const pending = self.pending_question_shared orelse return null;
        return try dupePendingBatchSnapshot(alloc, pending);
    }

    /// True while the worker waits on an answer to its question batch.
    pub fn hasPendingQuestionBatch(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.pending_question_shared != null;
    }

    pub fn pendingQuestionBatchSource(self: *WorkerRuntime) QuestionPromptSource {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const pending = self.pending_question_shared orelse return .agent_question;
        return pending.source;
    }
};

/// A resumed turn starts only on an idle worker with nothing queued.
fn recoveryContinuationAdmission(
    processing: bool,
    queued_count: usize,
) bool {
    return queued_count == 0 and !processing;
}

test "recovery continuation admission requires an empty idle worker" {
    try std.testing.expect(recoveryContinuationAdmission(false, 0));
    try std.testing.expect(!recoveryContinuationAdmission(true, 0));
    try std.testing.expect(!recoveryContinuationAdmission(false, 1));
}

fn dupeOwnedQuestionEntry(alloc: std.mem.Allocator, entry: types.QuestionBatchEntry) !OwnedQuestionEntry {
    const question_dup = try alloc.dupe(u8, entry.question);
    errdefer alloc.free(question_dup);
    const options_dup = try alloc.alloc(OwnedQuestionOption, entry.options.len);
    errdefer alloc.free(options_dup);

    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(options_dup[i].label);
            if (options_dup[i].description) |d| alloc.free(d);
        }
    }
    while (filled < entry.options.len) : (filled += 1) {
        const src = entry.options[filled];
        const label_dup = try alloc.dupe(u8, src.label);
        errdefer alloc.free(label_dup);
        const desc_dup: ?[]u8 = if (src.description) |d| try alloc.dupe(u8, d) else null;
        options_dup[filled] = .{ .label = label_dup, .description = desc_dup };
    }
    return .{ .question = question_dup, .markdown = entry.markdown, .options = options_dup, .submission = entry.submission };
}

fn freeOwnedQuestionEntry(alloc: std.mem.Allocator, entry: OwnedQuestionEntry) void {
    alloc.free(entry.question);
    for (entry.options) |opt| {
        alloc.free(opt.label);
        if (opt.description) |d| alloc.free(d);
    }
    alloc.free(entry.options);
}

fn dupeOwnedQuestionBatch(
    alloc: std.mem.Allocator,
    entries: []const types.QuestionBatchEntry,
    source: QuestionPromptSource,
) !OwnedQuestionBatch {
    const owned_entries = try alloc.alloc(OwnedQuestionEntry, entries.len);
    errdefer alloc.free(owned_entries);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) freeOwnedQuestionEntry(alloc, owned_entries[i]);
    }
    while (filled < entries.len) : (filled += 1) owned_entries[filled] = try dupeOwnedQuestionEntry(alloc, entries[filled]);
    return .{ .entries = owned_entries, .source = source };
}

fn freeOwnedQuestionBatch(alloc: std.mem.Allocator, owned: OwnedQuestionBatch) void {
    for (owned.entries) |entry| freeOwnedQuestionEntry(alloc, entry);
    alloc.free(owned.entries);
}

fn freeOwnedQuestionBatchOpt(alloc: std.mem.Allocator, owned: ?OwnedQuestionBatch) void {
    if (owned) |o| freeOwnedQuestionBatch(alloc, o);
}

fn freeQuestionResponse(alloc: std.mem.Allocator, response: QuestionResponse) void {
    switch (response) {
        .answered => |labels| {
            for (labels) |label| alloc.free(label);
            alloc.free(labels);
        },
        .cancelled, .pending => {},
    }
}

fn dupePendingEntrySnapshot(alloc: std.mem.Allocator, pending: OwnedQuestionEntry) !types.QuestionBatchEntry {
    const question_dup = try alloc.dupe(u8, pending.question);
    errdefer alloc.free(question_dup);
    const options_dup = try alloc.alloc(types.QuestionOption, pending.options.len);
    errdefer alloc.free(options_dup);

    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(@constCast(options_dup[i].label));
            if (options_dup[i].description) |d| alloc.free(@constCast(d));
        }
    }
    while (filled < pending.options.len) : (filled += 1) {
        const src = pending.options[filled];
        const label_dup = try alloc.dupe(u8, src.label);
        errdefer alloc.free(label_dup);
        const desc_dup: ?[]const u8 = if (src.description) |d| try alloc.dupe(u8, d) else null;
        options_dup[filled] = .{ .label = label_dup, .description = desc_dup };
    }
    return .{ .question = question_dup, .markdown = pending.markdown, .options = options_dup, .submission = pending.submission };
}

fn dupePendingBatchSnapshot(alloc: std.mem.Allocator, pending: OwnedQuestionBatch) !PendingQuestionBatchSnapshot {
    const entries_dup = try alloc.alloc(types.QuestionBatchEntry, pending.entries.len);
    errdefer alloc.free(entries_dup);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(@constCast(entries_dup[i].question));
            for (entries_dup[i].options) |opt| {
                alloc.free(@constCast(opt.label));
                if (opt.description) |d| alloc.free(@constCast(d));
            }
            alloc.free(@constCast(entries_dup[i].options));
        }
    }
    while (filled < pending.entries.len) : (filled += 1) entries_dup[filled] = try dupePendingEntrySnapshot(alloc, pending.entries[filled]);
    return .{ .entries = entries_dup, .source = pending.source };
}

fn appendHistoryTurnProjection(
    alloc: std.mem.Allocator,
    current: []const types.HistoryTurn,
    turn: types.HistoryTurn,
    max_history_turns: usize,
) ![]types.HistoryTurn {
    _ = max_history_turns;
    const retained = if (turn == .compacted_summary and
        compactor.replacesPriorContext(turn.compacted_summary.summary))
        &.{}
    else
        current;
    const next = try alloc.alloc(types.HistoryTurn, retained.len + 1);
    errdefer alloc.free(next);
    var copied: usize = 0;
    errdefer for (next[0..copied]) |owned| types.freeHistoryTurn(alloc, owned);
    for (retained, 0..) |entry, index| {
        next[index] = try types.dupeHistoryTurn(alloc, entry);
        copied += 1;
    }
    next[retained.len] = try types.dupeHistoryTurn(alloc, turn);
    return next;
}

/// Copies one leftover steered message into `taken`, marking its receipt
/// not_applied, as a discarded one's is; it drops and traces the message
/// when it can't.
fn keepLeftover(alloc: std.mem.Allocator, taken: *std.ArrayList(WorkerRuntime.LeftoverMessage), prompt: QueuedPrompt) void {
    const receipt = prompt.steering_receipt.?;
    const kept = blk: {
        const item = copyLeftover(alloc, receipt.operation_id, prompt.prompt) catch break :blk false;
        taken.append(alloc, item) catch {
            item.deinit(alloc);
            break :blk false;
        };
        break :blk true;
    };
    if (!kept) debug_trace.eventf("worker", "leftover_steering_dropped", .{ .turn_id = prompt.turn_id }, "operation={s} reason=out_of_memory", .{receipt.operation_id});
    if (receipt.state.cmpxchgStrong(.queued, .not_applied, .seq_cst, .seq_cst) == null) {
        debug_trace.eventf("subagent", "feedback_not_applied", .{}, "operation={s} reason={s}", .{ receipt.operation_id, if (kept) "handed_back" else "out_of_memory" });
    }
}

fn copyLeftover(alloc: std.mem.Allocator, operation_id: []const u8, text: []const u8) !WorkerRuntime.LeftoverMessage {
    const operation = try alloc.dupe(u8, operation_id);
    errdefer alloc.free(operation);
    return .{ .operation_id = operation, .text = try alloc.dupe(u8, text) };
}

pub fn freeQueuedPrompt(alloc: std.mem.Allocator, prompt: QueuedPrompt) void {
    if (prompt.steering_receipt) |receipt| {
        if (receipt.state.cmpxchgStrong(.queued, .not_applied, .seq_cst, .seq_cst) == null) {
            debug_trace.eventf("subagent", "feedback_not_applied", .{}, "operation={s} reason=queue_discarded", .{receipt.operation_id});
        }
    }
    alloc.free(prompt.prompt);
    if (prompt.work_id) |work_id| alloc.free(work_id);
    types.freeImageAttachmentSlice(alloc, prompt.images);
    types.freeImageAttachmentSlice(alloc, prompt.authorized_image_catalog);
    alloc.free(prompt.model);
    secret.zeroAndFree(alloc, prompt.api_key);
    if (prompt.gateway_team) |team| alloc.free(team);
    if (prompt.gateway_team_label) |label| alloc.free(label);
    if (prompt.account_id) |account_id| alloc.free(account_id);
    types.freeHistoryTurnSlice(alloc, prompt.history);
    if (prompt.root_user_intent_context.len > 0) alloc.free(prompt.root_user_intent_context);
    freeSkillBindings(alloc, prompt.skill_bindings);
    freeSkillDisplaySpans(alloc, prompt.skill_display_spans);
    var context_snapshot = prompt.context_snapshot;
    context_snapshot.deinit(alloc);
    for (prompt.snapshot_file_ownerships) |ownership| ownership.release();
    if (prompt.snapshot_file_ownerships.len > 0) {
        alloc.free(prompt.snapshot_file_ownerships);
    }
    if (prompt.recovery_checkpoint) |checkpoint| {
        var owned = checkpoint;
        owned.deinit(alloc);
    }
}

pub fn freeContextCompactionTask(
    alloc: std.mem.Allocator,
    task: ContextCompactionTask,
) void {
    alloc.free(task.model);
    secret.zeroAndFree(alloc, task.api_key);
    if (task.gateway_team) |team| alloc.free(team);
    if (task.account_id) |account_id| alloc.free(account_id);
    types.freeHistoryTurnSlice(alloc, task.history);
}

pub fn freeWorkItem(alloc: std.mem.Allocator, work: WorkItem) void {
    switch (work) {
        .prompt => |prompt| freeQueuedPrompt(alloc, prompt),
        .compact_context => |task| freeContextCompactionTask(alloc, task),
    }
}

fn discardQueuedPrompt(
    alloc: std.mem.Allocator,
    prompt: QueuedPrompt,
    retained_images: []const types.ImageAttachment,
) void {
    if (prompt.stale_shell_handles) {
        debug_trace.logf("worker", "stale shell handles note dropped with queued prompt turn_id={d}", .{prompt.turn_id});
    }
    if (prompt.recovery_checkpoint == null) {
        image_attachments.deleteUnreferencedImageSnapshots(prompt.images, retained_images);
    }
    freeQueuedPrompt(alloc, prompt);
}

fn checkHistoryPropagationAllocation(
    alloc: std.mem.Allocator,
    snapshot_path: []const u8,
    fail_index: usize,
) !bool {
    {
        var file = try std.Io.Dir.createFileAbsolute(
            std.testing.io,
            snapshot_path,
            .{ .truncate = true },
        );
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "snapshot");
    }
    var images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/source.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast(snapshot_path),
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    }};
    const turn: types.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("active"), .images = &images },
        .assistant = @constCast("done"),
    } };

    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    const first = try makePrompt(alloc, "first queued", "model");
    var owns_first = true;
    errdefer if (owns_first) freeQueuedPrompt(alloc, first);
    try runtime.enqueuePrompt(alloc, first);
    owns_first = false;
    const second = try makePrompt(alloc, "second queued", "model");
    var owns_second = true;
    errdefer if (owns_second) freeQueuedPrompt(alloc, second);
    try runtime.enqueuePrompt(alloc, second);
    owns_second = false;

    var active = ActivePromptSnapshotOwnership.init(&images);
    runtime.beginActivePromptSnapshots(&active);
    defer runtime.endActivePromptSnapshots(&active);

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = fail_index },
    );
    runtime.propagateHistoryTurn(failing.allocator(), turn, 8) catch |err| {
        if (!failing.has_induced_failure) return err;
        for (runtime.queued_prompts.items) |prompt| {
            try std.testing.expectEqual(@as(usize, 0), prompt.history.len);
            try std.testing.expectEqual(@as(usize, 0), prompt.authorized_image_catalog.len);
            try std.testing.expectEqual(@as(usize, 0), prompt.snapshot_file_ownerships.len);
        }
        try std.testing.expectEqual(@as(usize, 0), runtime.queued_history.len);
        return false;
    };

    for (runtime.queued_prompts.items) |prompt| {
        try std.testing.expectEqual(@as(usize, 0), prompt.history.len);
        try std.testing.expectEqual(@as(usize, 1), prompt.authorized_image_catalog.len);
        try std.testing.expectEqual(@as(usize, 1), prompt.snapshot_file_ownerships.len);
    }
    try std.testing.expectEqual(@as(usize, 1), runtime.queued_history.len);
    return true;
}

fn checkContextCompactionCommitAllocation(
    alloc: std.mem.Allocator,
    fail_index: usize,
) !bool {
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    var prompt = try makePrompt(alloc, "queued", "model");
    var owns_prompt = true;
    errdefer if (owns_prompt) freeQueuedPrompt(alloc, prompt);
    prompt.history = try session_runtime.snapshotOwnedContextHistory(alloc, &.{.{ .assistant = .{
        .user = .{ .text = @constCast("prior user") },
        .assistant = @constCast("prior answer"),
    } }}, 0, 0);
    try runtime.enqueuePrompt(alloc, prompt);
    owns_prompt = false;

    const turn: types.HistoryTurn = .{ .compacted_summary = .{
        .summary = @constCast("<context_handoff>checkpoint</context_handoff>"),
        .removed_turn_count = 1,
        .compaction_count = 1,
    } };
    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = fail_index },
    );
    runtime.publishContextCompaction(failing.allocator(), .{ .summary = turn.compacted_summary, .max_history_turns = 8 }, &runtime, discardCompactionForTest) catch |err| {
        if (!failing.has_induced_failure) return err;
        try std.testing.expectEqual(
            @as(usize, 1),
            runtime.queued_history.len,
        );
        try std.testing.expectEqualStrings("prior answer", runtime.queued_history[0].assistant.assistant);
        try std.testing.expectEqual(@as(usize, 0), runtime.worker_events.items.len);
        return false;
    };

    try std.testing.expectEqual(
        @as(usize, 1),
        runtime.queued_history.len,
    );
    try std.testing.expectEqual(@as(usize, 0), runtime.worker_events.items.len);
    try std.testing.expectEqualStrings(turn.compacted_summary.summary, runtime.queued_history[0].compacted_summary.summary);
    return true;
}

fn discardCompactionForTest(_: *anyopaque, _: ContextCompaction) !void {}

fn checkFinishOwnershipHandoffAllocation(
    alloc: std.mem.Allocator,
    snapshot_path: []const u8,
) !void {
    {
        var file = try std.Io.Dir.createFileAbsolute(
            std.testing.io,
            snapshot_path,
            .{ .truncate = true },
        );
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "snapshot");
    }
    const images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/source.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast(snapshot_path),
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    }};
    var active = ActivePromptSnapshotOwnership.init(&images);
    const ownership = active.handoff(alloc) catch |err| {
        active.deinit();
        try std.testing.expectError(
            error.FileNotFound,
            std.Io.Dir.accessAbsolute(std.testing.io, snapshot_path, .{}),
        );
        return err;
    };
    active.deinit();
    ownership.?.release();
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(std.testing.io, snapshot_path, .{}),
    );
}

pub fn dupeSkillBindings(alloc: std.mem.Allocator, bindings: []const SkillBinding) ![]SkillBinding {
    if (bindings.len == 0) return &.{};
    const copy = try alloc.alloc(SkillBinding, bindings.len);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(copy[i].name);
            alloc.free(copy[i].path);
        }
        alloc.free(copy);
    }
    while (filled < bindings.len) : (filled += 1) {
        copy[filled] = .{
            .name = try alloc.dupe(u8, bindings[filled].name),
            .path = try alloc.dupe(u8, bindings[filled].path),
        };
    }
    return copy;
}

pub fn freeSkillBindings(alloc: std.mem.Allocator, bindings: []SkillBinding) void {
    for (bindings) |binding| {
        alloc.free(binding.name);
        alloc.free(binding.path);
    }
    if (bindings.len > 0) alloc.free(bindings);
}

pub fn dupeSkillDisplaySpans(alloc: std.mem.Allocator, spans: []const SkillDisplaySpan) ![]SkillDisplaySpan {
    if (spans.len == 0) return &.{};
    const copy = try alloc.alloc(SkillDisplaySpan, spans.len);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(copy[i].name);
            alloc.free(copy[i].path);
        }
        alloc.free(copy);
    }
    while (filled < spans.len) : (filled += 1) {
        copy[filled] = .{
            .raw_start = spans[filled].raw_start,
            .raw_end = spans[filled].raw_end,
            .name = try alloc.dupe(u8, spans[filled].name),
            .path = try alloc.dupe(u8, spans[filled].path),
            .display_source = spans[filled].display_source,
            .owns_trailing_separator = spans[filled].owns_trailing_separator,
        };
    }
    return copy;
}

pub fn freeSkillDisplaySpans(alloc: std.mem.Allocator, spans: []SkillDisplaySpan) void {
    for (spans) |span| {
        alloc.free(span.name);
        alloc.free(span.path);
    }
    if (spans.len > 0) alloc.free(spans);
}

/// The `host` trace kind of a worker event: `text` adds transcript
/// content, `ask` requests an answer, and everything else is `other`.
pub fn traceKind(event: WorkerEvent) []const u8 {
    return switch (event) {
        .assistant_presentation => "text",
        .question_requested => "ask",
        else => "other",
    };
}

pub fn dupeWorkerEvent(alloc: std.mem.Allocator, event: WorkerEvent) !WorkerEvent {
    return switch (event) {
        .begin_prompt => |prompt| .{ .begin_prompt = try types.dupeUserTurn(alloc, prompt) },
        .begin_prompt_with_skill_bindings => |begin| blk: {
            const prompt = try types.dupeUserTurn(alloc, begin.prompt);
            errdefer types.freeUserTurn(alloc, prompt);
            const skill_bindings = try dupeSkillBindings(alloc, begin.skill_bindings);
            errdefer freeSkillBindings(alloc, skill_bindings);
            const skill_display_spans = try dupeSkillDisplaySpans(alloc, begin.skill_display_spans);
            break :blk .{ .begin_prompt_with_skill_bindings = .{
                .prompt = prompt,
                .skill_bindings = skill_bindings,
                .skill_display_spans = skill_display_spans,
            } };
        },
        .begin_presented_prompt => |turn_id| .{ .begin_presented_prompt = turn_id },
        .begin_resumed_prompt => |turn_id| .{ .begin_resumed_prompt = turn_id },
        .append_user_feedback => |text| .{ .append_user_feedback = try alloc.dupe(u8, text) },
        .append_agent_message => |text| .{ .append_agent_message = try alloc.dupe(u8, text) },
        .assistant_presentation => |presentation| .{
            .assistant_presentation = try presentation.clone(alloc),
        },
        .notification => |notification| .{ .notification = notification },
        .question_requested => .question_requested,
        .open_model_picker => .open_model_picker,
        .semantic_notice => |notice| .{ .semantic_notice = try types.dupeSemanticNotice(alloc, notice) },
        .model_call => |record| .{ .model_call = try types.dupeModelCallRecord(alloc, record) },
        .route_recovery_status => |status| .{ .route_recovery_status = status },
        .clear_route_recovery_status => .clear_route_recovery_status,
        .provider_resolved => |slug| .{ .provider_resolved = try alloc.dupe(u8, slug) },
        .api_status_text => |text| .{ .api_status_text = try alloc.dupe(u8, text) },
        .reasoning_delta => |text| .{ .reasoning_delta = try alloc.dupe(u8, text) },
        .remote_assistant_source => |text| .{ .remote_assistant_source = try alloc.dupe(u8, text) },
        .live_text => |text| .{ .live_text = try alloc.dupe(u8, text) },
        .credential_refreshed => |credential| .{
            .credential_refreshed = try credential.clone(alloc),
        },
        .command_output => |chunk| .{ .command_output = .{
            .lifecycle_id = if (chunk.lifecycle_id) |id| .{
                .turn_id = id.turn_id,
                .call_id = try alloc.dupe(u8, id.call_id),
            } else null,
            .stream = chunk.stream,
            .text = try alloc.dupe(u8, chunk.text),
        } },
        .command_output_complete => |lifecycle_id| .{ .command_output_complete = if (lifecycle_id) |id| .{
            .turn_id = id.turn_id,
            .call_id = try alloc.dupe(u8, id.call_id),
        } else null },
        .tool_lifecycle => |lifecycle| .{
            .tool_lifecycle = try dupeToolLifecycleEvent(alloc, lifecycle),
        },
        .turn_token_update => |update| .{ .turn_token_update = update },
        .turn_phase_update => |update| .{ .turn_phase_update = update },
        .diff_block => |payload| blk: {
            const preview = try alloc.dupe(u8, payload.preview);
            errdefer alloc.free(preview);
            const full = if (payload.full) |source| full_value: {
                const content = try alloc.dupe(u8, source.content);
                errdefer alloc.free(content);
                const call_id = try alloc.dupe(u8, source.lifecycle_id.call_id);
                break :full_value diff_mod.FullDiff{
                    .content = content,
                    .lifecycle_id = .{
                        .turn_id = source.lifecycle_id.turn_id,
                        .call_id = call_id,
                    },
                };
            } else null;
            errdefer if (full) |owned| owned.deinit(alloc);
            break :blk .{ .diff_block = .{
                .preview = preview,
                .additions = payload.additions,
                .deletions = payload.deletions,
                .full = full,
            } };
        },
        .context_compaction => |value| blk: {
            const summary = try types.dupeHistoryTurn(alloc, .{ .compacted_summary = value.summary });
            errdefer types.freeHistoryTurn(alloc, summary);
            const prefix = if (value.active_prefix) |prefix|
                (try types.dupeHistoryTurn(alloc, .{ .assistant = prefix })).assistant
            else
                null;
            break :blk .{ .context_compaction = .{
                .turn_id = value.turn_id,
                .summary = summary.compacted_summary,
                .active_prefix = prefix,
                .retained_from = value.retained_from,
                .max_history_turns = value.max_history_turns,
            } };
        },
        .finish_prompt => |finished| .{ .finish_prompt = try types.dupeFinishedPrompt(alloc, finished) },
        .error_text => |notice| .{ .error_text = try types.dupeSemanticNotice(alloc, notice) },
        .restore_failed_prompt => |text| .{ .restore_failed_prompt = try alloc.dupe(u8, text) },
    };
}

pub fn freeWorkerEvent(alloc: std.mem.Allocator, event: WorkerEvent) void {
    switch (event) {
        .begin_prompt => |prompt| types.freeUserTurn(alloc, prompt),
        .begin_prompt_with_skill_bindings => |begin| {
            types.freeUserTurn(alloc, begin.prompt);
            freeSkillBindings(alloc, begin.skill_bindings);
            freeSkillDisplaySpans(alloc, begin.skill_display_spans);
        },
        .begin_presented_prompt, .begin_resumed_prompt => {},
        .append_user_feedback, .append_agent_message => |text| alloc.free(text),
        .assistant_presentation => |presentation| {
            var owned = presentation;
            owned.deinit(alloc);
        },
        .notification => {},
        .open_model_picker => {},
        .semantic_notice => |notice| types.freeSemanticNotice(alloc, notice),
        .model_call => |record| types.freeModelCallRecordStrings(alloc, record),
        .route_recovery_status => {},
        .clear_route_recovery_status => {},
        .provider_resolved => |slug| alloc.free(slug),
        .api_status_text, .reasoning_delta, .remote_assistant_source, .live_text => |text| alloc.free(text),
        .credential_refreshed => |credential| {
            var owned = credential;
            owned.deinit(alloc);
        },
        .command_output => |chunk| {
            if (chunk.lifecycle_id) |id| alloc.free(@constCast(id.call_id));
            alloc.free(chunk.text);
        },
        .command_output_complete => |lifecycle_id| {
            if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));
        },
        .tool_lifecycle => |lifecycle| freeToolLifecycleEvent(alloc, lifecycle),
        .diff_block => |payload| diff_mod.freeDiffEntryPayload(alloc, payload),
        .context_compaction => |value| {
            types.freeHistoryTurn(alloc, .{ .compacted_summary = value.summary });
            if (value.active_prefix) |prefix| types.freeHistoryTurn(alloc, .{ .assistant = prefix });
        },
        .finish_prompt => |finished| types.freeFinishedPrompt(alloc, finished),
        .error_text => |notice| types.freeSemanticNotice(alloc, notice),
        .restore_failed_prompt => |text| alloc.free(text),
        else => {},
    }
}

pub fn dupeToolLifecycleEvent(
    alloc: std.mem.Allocator,
    event: types.ToolLifecycleEvent,
) !types.ToolLifecycleEvent {
    return switch (event) {
        .provisional => |started| blk: {
            const call_id = try alloc.dupe(u8, started.id.call_id);
            errdefer alloc.free(call_id);
            const tool_name = if (started.tool_name) |name| try alloc.dupe(u8, name) else null;
            break :blk .{ .provisional = .{
                .id = .{ .turn_id = started.id.turn_id, .call_id = call_id },
                .presentation_group_id = started.presentation_group_id,
                .tool_name = tool_name,
                .activity_kind = started.activity_kind,
            } };
        },
        .authoritative_started => |started| blk: {
            const call_id = try alloc.dupe(u8, started.id.call_id);
            errdefer alloc.free(call_id);
            const alias = if (started.reconciles_provisional_call_id) |value|
                try alloc.dupe(u8, value)
            else
                null;
            errdefer if (alias) |value| alloc.free(value);
            const tool_name = try alloc.dupe(u8, started.tool_name);
            errdefer alloc.free(tool_name);
            const arguments_json = if (started.arguments_json) |value|
                try alloc.dupe(u8, value)
            else
                null;
            errdefer if (arguments_json) |value| alloc.free(value);
            break :blk .{ .authoritative_started = .{
                .id = .{ .turn_id = started.id.turn_id, .call_id = call_id },
                .presentation_group_id = started.presentation_group_id,
                .reconciles_provisional_call_id = alias,
                .tool_name = tool_name,
                .activity_kind = started.activity_kind,
                .arguments_json = arguments_json,
                .place_after_current_transcript = started.place_after_current_transcript,
            } };
        },
        .progress => |progress| blk: {
            const call_id = try alloc.dupe(u8, progress.id.call_id);
            errdefer alloc.free(call_id);
            const text = try alloc.dupe(u8, progress.text);
            break :blk .{ .progress = .{
                .id = .{ .turn_id = progress.id.turn_id, .call_id = call_id },
                .text = text,
            } };
        },
        .terminal => |terminal| blk: {
            const call_id = try alloc.dupe(u8, terminal.id.call_id);
            errdefer alloc.free(call_id);
            const summary = try alloc.dupe(u8, terminal.outcome.summary);
            errdefer alloc.free(summary);
            const result = if (terminal.result) |value|
                try alloc.dupe(u8, value)
            else
                null;
            errdefer if (result) |value| alloc.free(value);
            const result_memory = try dupeToolResultMemory(alloc, terminal.result_memory);
            errdefer freeToolResultMemory(alloc, result_memory);
            const command_artifact_handle = if (terminal.command_artifact_handle) |handle|
                try alloc.dupe(u8, handle)
            else
                null;
            errdefer if (command_artifact_handle) |handle| alloc.free(handle);
            break :blk .{ .terminal = .{
                .id = .{ .turn_id = terminal.id.turn_id, .call_id = call_id },
                .outcome = .{
                    .kind = terminal.outcome.kind,
                    .summary = summary,
                },
                .result = result,
                .result_memory = result_memory,
                .command_artifact_handle = command_artifact_handle,
            } };
        },
        .turn_finished => |finished| .{ .turn_finished = finished },
    };
}

pub fn freeToolLifecycleEvent(
    alloc: std.mem.Allocator,
    event: types.ToolLifecycleEvent,
) void {
    switch (event) {
        .provisional => |started| {
            alloc.free(@constCast(started.id.call_id));
            if (started.tool_name) |name| alloc.free(@constCast(name));
        },
        .authoritative_started => |started| {
            alloc.free(@constCast(started.id.call_id));
            if (started.reconciles_provisional_call_id) |alias| {
                alloc.free(@constCast(alias));
            }
            alloc.free(@constCast(started.tool_name));
            if (started.arguments_json) |arguments_json| {
                alloc.free(@constCast(arguments_json));
            }
        },
        .progress => |progress| {
            alloc.free(@constCast(progress.id.call_id));
            alloc.free(@constCast(progress.text));
        },
        .terminal => |terminal| {
            alloc.free(@constCast(terminal.id.call_id));
            alloc.free(@constCast(terminal.outcome.summary));
            if (terminal.result) |result| alloc.free(@constCast(result));
            freeToolResultMemory(alloc, terminal.result_memory);
            if (terminal.command_artifact_handle) |handle| alloc.free(@constCast(handle));
        },
        .turn_finished => {},
    }
}

fn dupeToolResultMemory(
    alloc: std.mem.Allocator,
    source: ?types.ToolResultMemory,
) !?types.ToolResultMemory {
    const memory = source orelse return null;
    const output_handle = if (memory.output_handle) |handle|
        try alloc.dupe(u8, handle)
    else
        null;
    errdefer if (output_handle) |handle| alloc.free(handle);
    const preview = if (memory.preview) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (preview) |value| alloc.free(value);
    const command_output_replay = if (memory.command_output_replay) |replay|
        try types.dupeCommandOutputReplay(alloc, replay)
    else
        null;
    errdefer if (command_output_replay) |replay| types.freeCommandOutputReplay(alloc, replay);
    const quiet_crossing: ?types.QuietCrossing = if (memory.quiet_crossing) |crossing|
        .{ .command = try alloc.dupe(u8, crossing.command), .quiet_ms = crossing.quiet_ms }
    else
        null;
    return .{
        .output_handle = output_handle,
        .preview = preview,
        .output_bytes = memory.output_bytes,
        .stored_output_bytes = memory.stored_output_bytes,
        .truncated = memory.truncated,
        .model_view_covers_full_file = memory.model_view_covers_full_file,
        .command_output_replay = command_output_replay,
        .command_process_presentation = memory.command_process_presentation,
        .terminal_action_presentation = memory.terminal_action_presentation,
        .quiet_crossing = quiet_crossing,
    };
}

fn freeToolResultMemory(
    alloc: std.mem.Allocator,
    memory: ?types.ToolResultMemory,
) void {
    const value = memory orelse return;
    if (value.output_handle) |handle| alloc.free(@constCast(handle));
    if (value.preview) |preview| alloc.free(@constCast(preview));
    if (value.command_output_replay) |replay| {
        types.freeCommandOutputReplay(alloc, replay);
    }
    if (value.quiet_crossing) |crossing| alloc.free(@constCast(crossing.command));
}

fn makePrompt(alloc: std.mem.Allocator, text: []const u8, model: []const u8) !QueuedPrompt {
    return .{
        .prompt = try alloc.dupe(u8, text),
        .images = &.{},
        .model = try alloc.dupe(u8, model),
        .api_key = try alloc.dupe(u8, "key"),
        .permission_mode = .yolo,
        .history = try alloc.alloc(types.HistoryTurn, 0),
    };
}

fn makeImagePrompt(alloc: std.mem.Allocator, text: []const u8, model: []const u8) !QueuedPrompt {
    var prompt = try makePrompt(alloc, text, model);
    errdefer freeQueuedPrompt(alloc, prompt);
    const images = try alloc.alloc(types.ImageAttachment, 1);
    errdefer alloc.free(images);
    const path = try alloc.dupe(u8, "/tmp/steering.png");
    errdefer alloc.free(path);
    const media_type = try alloc.dupe(u8, "image/png");
    errdefer alloc.free(media_type);
    images[0] = .{ .path = path, .media_type = media_type };
    prompt.images = images;
    return prompt;
}

fn freeEventList(alloc: std.mem.Allocator, events: *std.ArrayList(WorkerEvent)) void {
    for (events.items) |event| freeWorkerEvent(alloc, event);
    events.deinit(alloc);
}

fn expectContinuedSteering(result: SteeringBoundaryResult) ![]SteeringMessage {
    return switch (result) {
        .continue_turn => |messages| messages,
        .none, .handoff, .interrupt => error.TestExpectedContinuedSteering,
    };
}

fn expectTyped(expected: []const []const u8, typed: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, typed.len);
    for (expected, typed) |want, got| try std.testing.expectEqualStrings(want, got);
}

/// Which numbered messages a fuzzed run sent and delivered: each one
/// delivered must have been accepted, at most once, and after every message
/// sent before it.
const PlacementLog = struct {
    accepted: [64]bool = @splat(false),
    delivered: [64]bool = @splat(false),
    last: ?u32 = null,

    fn deliver(self: *PlacementLog, text: []const u8) !void {
        const n = try std.fmt.parseInt(u32, text[1..], 10);
        try std.testing.expect(self.accepted[n]);
        try std.testing.expect(!self.delivered[n]);
        if (self.last) |last| try std.testing.expect(n > last);
        self.delivered[n] = true;
        self.last = n;
    }

    fn expectAllDelivered(self: *const PlacementLog) !void {
        for (self.accepted, self.delivered) |accepted, delivered| try std.testing.expect(!accepted or delivered);
    }
};

/// Drives one worker through fuzzed steps: a message the user types, plain
/// or with an image; work queued for a turn of its own; a parent's message to
/// the running turn; another agent's posted message; a steering boundary; and
/// a turn ending or the next one starting. Then it drains the queue.
fn fuzzQueuePlacement(_: void, smith: *std.testing.Smith) !void {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    var log: PlacementLog = .{};
    var sent: u32 = 0;
    var steps: usize = 0;
    while (steps < 48 and !smith.eos()) : (steps += 1) {
        switch (smith.valueRangeAtMost(u8, 0, 6)) {
            0, 1 => |kind| {
                try runtime.admitInteractivePrompt(alloc, try placementPrompt(alloc, sent, kind == 1));
                log.accepted[sent] = true;
                sent += 1;
            },
            2 => {
                try runtime.enqueuePrompt(alloc, try placementPrompt(alloc, sent, false));
                log.accepted[sent] = true;
                sent += 1;
            },
            3 => {
                const prompt = try placementPrompt(alloc, sent, false);
                if (try runtime.admitActiveSteering(alloc, prompt)) log.accepted[sent] = true else freeQueuedPrompt(alloc, prompt);
                sent += 1;
            },
            4 => {
                try runtime.postMail(alloc, try placementPrompt(alloc, sent, false));
                log.accepted[sent] = true;
                sent += 1;
            },
            5 => try placementBoundary(alloc, &runtime, &log),
            else => try placementTurn(alloc, &runtime, &log),
        }
    }
    var rounds: usize = 0;
    while (runtime.worker_processing or runtime.queued_prompts.items.len > 0) : (rounds += 1) {
        if (rounds > 400) return error.TestQueueDidNotDrain;
        if (runtime.worker_processing) {
            try placementBoundary(alloc, &runtime, &log);
            if (runtime.worker_processing) runtime.finishProcessing();
        } else try placementTurn(alloc, &runtime, &log);
    }
    try log.expectAllDelivered();
}

fn placementPrompt(alloc: std.mem.Allocator, n: u32, image: bool) !QueuedPrompt {
    var buf: [16]u8 = undefined;
    const text = try std.mem.print(&buf, "m{d}", .{n});
    return if (image) makeImagePrompt(alloc, text, "model") else makePrompt(alloc, text, "model");
}

/// The running turn reaches a boundary, which delivers its messages, or
/// ends it for a handoff or an interrupt.
fn placementBoundary(alloc: std.mem.Allocator, runtime: *WorkerRuntime, log: *PlacementLog) !void {
    if (!runtime.worker_processing) return;
    const kind: SteeringBoundaryKind = if (runtime.worker_cancel_requested.load(.seq_cst)) .cancelled else .model;
    switch (try runtime.takeSteeringBoundary(alloc, runtime.active_turn_id, kind)) {
        .continue_turn => |messages| {
            defer freeSteeringMessages(alloc, messages);
            for (messages) |message| try log.deliver(message.text);
        },
        .none => {},
        .handoff, .interrupt => runtime.finishProcessing(),
    }
}

/// Ends the running turn, or starts the next one, which delivers its prompt.
fn placementTurn(alloc: std.mem.Allocator, runtime: *WorkerRuntime, log: *PlacementLog) !void {
    if (runtime.worker_processing) return runtime.finishProcessing();
    const job = (try runtime.tryTakeNextPrompt(alloc)) orelse return;
    defer freeQueuedPrompt(alloc, job);
    try log.deliver(job.prompt);
}

const PromptTakeThreadState = struct {
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    err: ?anyerror = null,
    job: ?QueuedPrompt = null,
};

fn runPromptTake(state: *PromptTakeThreadState, runtime: *WorkerRuntime) void {
    state.started.store(true, .seq_cst);
    state.job = runtime.waitAndTakeNextPrompt(std.testing.allocator) catch |err| {
        state.err = err;
        state.finished.store(true, .seq_cst);
        return;
    };
    state.finished.store(true, .seq_cst);
}

const EnqueueThreadState = struct {
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    err: ?anyerror = null,
};

fn runEnqueuePrompt(state: *EnqueueThreadState, runtime: *WorkerRuntime, text: []const u8, model: []const u8) void {
    const prompt = makePrompt(std.testing.allocator, text, model) catch |err| {
        state.err = err;
        return;
    };
    state.started.store(true, .seq_cst);
    runtime.enqueuePrompt(std.testing.allocator, prompt) catch |err| {
        freeQueuedPrompt(std.testing.allocator, prompt);
        state.err = err;
        return;
    };
}

fn waitForEnqueueThreadStart(state: *EnqueueThreadState) !void {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (state.started.load(.seq_cst)) return;
        io_mod.sleep(1 * std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

fn checkToolLifecycleDupAllocationFailure(alloc: std.mem.Allocator) !void {
    const owned = try dupeToolLifecycleEvent(alloc, .{ .authoritative_started = .{
        .id = .{ .turn_id = 7, .call_id = "final" },
        .reconciles_provisional_call_id = "provisional",
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    defer freeToolLifecycleEvent(alloc, owned);

    try std.testing.expectEqualStrings(
        "final",
        owned.authoritative_started.id.call_id,
    );
    try std.testing.expectEqualStrings(
        "provisional",
        owned.authoritative_started.reconciles_provisional_call_id.?,
    );
    try std.testing.expectEqualStrings(
        "read_file",
        owned.authoritative_started.tool_name,
    );
}

fn checkSemanticWorkerEventDuplicationAllocationFailure(alloc: std.mem.Allocator) !void {
    const ordinary = try dupeWorkerEvent(alloc, .{ .semantic_notice = .{
        .topic = "context",
        .tone = .warning,
        .body = "source limit reached",
        .visibility = .full_only,
    } });
    defer freeWorkerEvent(alloc, ordinary);

    const error_event = try dupeWorkerEvent(alloc, .{ .error_text = .{
        .topic = "github",
        .tone = .@"error",
        .body = "publish failed",
    } });
    defer freeWorkerEvent(alloc, error_event);

    try std.testing.expectEqualStrings("context", ordinary.semantic_notice.topic);
    try std.testing.expectEqualStrings("source limit reached", ordinary.semantic_notice.body);
    try std.testing.expectEqualStrings("github", error_event.error_text.topic);
    try std.testing.expectEqualStrings("publish failed", error_event.error_text.body);
}

fn checkSemanticNoticeEnqueueAllocationFailure(alloc: std.mem.Allocator) !void {
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    try runtime.pushEvent(alloc, .{ .semantic_notice = .{
        .topic = "permissions",
        .tone = .success,
        .body = "approval",
        .visibility = .full_only,
    } });
    var events = runtime.takeEvents();
    defer freeEventList(alloc, &events);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0] == .semantic_notice);
    try std.testing.expectEqualStrings("permissions", events.items[0].semantic_notice.topic);
    try std.testing.expectEqualStrings("approval", events.items[0].semantic_notice.body);
}

const QuestionThreadState = struct {
    answers: ?[][]u8 = null,
    err: ?anyerror = null,
    /// Set when the asking thread's blocking call has returned.
    returned: std.Io.Event = .unset,
};

fn runQuestionRequest(state: *QuestionThreadState, runtime: *WorkerRuntime, entries: []const types.QuestionBatchEntry) void {
    defer state.returned.set(io_mod.getIo());
    state.answers = runtime.requestQuestionBatchAnswerBlocking(std.testing.allocator, entries) catch |err| {
        state.err = err;
        return;
    };
}

fn runRouteRecoveryRequest(state: *QuestionThreadState, runtime: *WorkerRuntime, entries: []const types.QuestionBatchEntry) void {
    defer state.returned.set(io_mod.getIo());
    state.answers = runtime.requestRouteRecoveryAnswerBlocking(std.testing.allocator, entries) catch |err| {
        state.err = err;
        return;
    };
}

fn waitForQuestionSnapshot(worker: *WorkerRuntime) !PendingQuestionBatchSnapshot {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try worker.snapshotPendingQuestionBatch(std.testing.allocator)) |snapshot| return snapshot;
        io_mod.sleep(1 * std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

fn freeAnswers(alloc: std.mem.Allocator, answers: ?[][]u8) void {
    if (answers) |labels| {
        for (labels) |label| alloc.free(label);
        alloc.free(labels);
    }
}

/// Joins the thread that asked the user once its call has returned, within
/// the bound every test wait has, and expects `runtime` to wait for the user as
/// `expected` says by then: a wait drops its count before its call returns. A
/// thread that is still waiting is released with `requestStop` first, so a
/// wait that does not end fails the test instead of hanging it.
fn expectAskReturns(thread: std.Thread, returned: *std.Io.Event, runtime: *WorkerRuntime, expected: ?WorkerRuntime.UserWait) !void {
    const ended = testing_event.setInTime(returned);
    if (!ended) runtime.requestStop();
    thread.join();
    try std.testing.expect(ended);
    try std.testing.expectEqual(expected, runtime.userWait());
}

fn runMcpElicitationRequest(state: *QuestionThreadState, runtime: *WorkerRuntime, entries: []const types.QuestionBatchEntry) void {
    defer state.returned.set(io_mod.getIo());
    state.answers = runtime.requestMcpElicitationAnswerBlocking(std.testing.allocator, entries) catch |err| {
        state.err = err;
        return;
    };
}

/// Who asks the user a question: the agent's own question tool, an MCP
/// server's elicitation, or the picker a failed request opens.
const QuestionAsker = enum { agent, mcp_server, failed_request };

/// Starts the thread that puts `entries` to the user the way `asker` does.
fn startQuestionAsker(asker: QuestionAsker, state: *QuestionThreadState, runtime: *WorkerRuntime, entries: []const types.QuestionBatchEntry) !std.Thread {
    return switch (asker) {
        .agent => std.Thread.spawn(.{}, runQuestionRequest, .{ state, runtime, entries }),
        .mcp_server => std.Thread.spawn(.{}, runMcpElicitationRequest, .{ state, runtime, entries }),
        .failed_request => std.Thread.spawn(.{}, runRouteRecoveryRequest, .{ state, runtime, entries }),
    };
}

fn makePromptWithHistory(alloc: std.mem.Allocator, text: []const u8, earlier: []const u8) !QueuedPrompt {
    var prompt = try makePrompt(alloc, text, "model");
    alloc.free(prompt.history);
    const history = try alloc.alloc(types.HistoryTurn, 1);
    errdefer alloc.free(history);
    history[0] = try types.dupeHistoryTurn(alloc, .{ .interrupted = .{ .user = .{ .text = @constCast(earlier) } } });
    prompt.history = history;
    return prompt;
}

fn pushTestFinish(alloc: std.mem.Allocator, runtime: *WorkerRuntime) !void {
    const turn: types.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("prompt") },
        .assistant = @constCast("answer"),
    } };
    try runtime.pushEvent(alloc, .{ .finish_prompt = .{ .turn = turn } });
}

/// A worker whose turn 9 closed to mail and finished, with a report that
/// missed it waiting for the next turn.
fn finishedTurnWithMissedMail(alloc: std.mem.Allocator, runtime: *WorkerRuntime) !void {
    runtime.worker_processing = true;
    runtime.active_turn_id = 9;
    runtime.direct_steering_closed = true;
    try pushTestFinish(alloc, runtime);
    try runtime.postMail(alloc, try makePrompt(alloc, "a report", "model"));
    try std.testing.expect(runtime.queued_prompts.items[0].delivery.isContinuation());
    runtime.finishProcessing();
}

/// A worker whose turn 9 finished, `late_ms` ago as far as the limit is
/// concerned, with a report posted only now, behind it.
fn finishedTurnWithLateMail(alloc: std.mem.Allocator, runtime: *WorkerRuntime, late_ms: i64) !void {
    runtime.worker_processing = true;
    runtime.active_turn_id = 9;
    runtime.direct_steering_closed = true;
    try pushTestFinish(alloc, runtime);
    // A limit that counted from the push has run for `late_ms` by now.
    runtime.commit_gate_since_ms -= late_ms;
    try runtime.postMail(alloc, try makePrompt(alloc, "a late report", "model"));
    try std.testing.expect(runtime.queued_prompts.items[0].delivery.isContinuation());
    runtime.finishProcessing();
}

/// What a held spell has left of its limit.
fn commitGateLeftMs(runtime: *WorkerRuntime) ?i64 {
    runtime.worker_mutex.lockUncancelable(io_mod.getIo());
    defer runtime.worker_mutex.unlock(io_mod.getIo());
    return runtime.commitGateRemainingMsLocked();
}

/// The history the loop had when it posted mail: one earlier, committed turn.
fn earlierTurns(alloc: std.mem.Allocator) ![]types.HistoryTurn {
    const turns = try alloc.alloc(types.HistoryTurn, 1);
    errdefer alloc.free(turns);
    turns[0] = .{ .assistant = .{
        .user = .{ .text = try alloc.dupe(u8, "earlier prompt") },
        .assistant = try alloc.dupe(u8, "earlier answer"),
    } };
    return turns;
}

/// A turn the worker finished and the loop commits later.
fn finishedTurn(answer: []const u8) types.HistoryTurn {
    return .{ .assistant = .{
        .user = .{ .text = @constCast("the finished prompt") },
        .assistant = @constCast(answer),
    } };
}

/// Mail posted after the worker finished a turn that the loop has not committed:
/// the history it brings is the one the loop had then, without that turn.
fn postMailWithEarlierHistory(alloc: std.mem.Allocator, runtime: *WorkerRuntime, text: []const u8, mail: agent_frame.MailKind) !void {
    var prompt = try makePrompt(alloc, text, "model");
    types.freeHistoryTurnSlice(alloc, prompt.history);
    prompt.history = try earlierTurns(alloc);
    prompt.mail = mail;
    try runtime.postMail(alloc, prompt);
}

/// The answers of the turns in `runtime`'s queue history, in order.
fn expectQueuedAnswers(runtime: *const WorkerRuntime, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, runtime.queued_history.len);
    for (expected, runtime.queued_history) |answer, turn| {
        const actual: []const u8 = switch (turn) {
            .assistant => |entry| entry.assistant,
            .interrupted => |entry| entry.assistant orelse "",
            .compacted_summary => |entry| entry.summary,
        };
        try std.testing.expectEqualStrings(answer, actual);
    }
}

/// A worker with one report waiting behind `count` finishes the loop has not committed.
fn reportBehindUncommittedFinishes(alloc: std.mem.Allocator, runtime: *WorkerRuntime, count: usize) !void {
    runtime.enableCommitGate();
    runtime.worker_processing = true;
    runtime.active_turn_id = 9;
    runtime.direct_steering_closed = true;
    for (0..count) |_| try pushTestFinish(alloc, runtime);
    try postMailWithEarlierHistory(alloc, runtime, "a report", .report);
    runtime.finishProcessing();
}

fn reportBehindUncommittedFinish(alloc: std.mem.Allocator, runtime: *WorkerRuntime) !void {
    try reportBehindUncommittedFinishes(alloc, runtime, 1);
}

fn dropEveryPrompt(_: void, _: usize, _: *const QueuedPrompt) bool {
    return true;
}

/// A worker whose turn 9 finished, with one message posted behind it, which
/// took the loop's history without that turn: the queue owes it a turn.
fn messageQueuedBehindUncommittedFinish(alloc: std.mem.Allocator, runtime: *WorkerRuntime) !void {
    runtime.enableCommitGate();
    runtime.worker_processing = true;
    runtime.active_turn_id = 9;
    runtime.direct_steering_closed = true;
    try pushTestFinish(alloc, runtime);
    var events = runtime.takeEvents();
    for (events.items) |event| freeWorkerEvent(alloc, event);
    events.deinit(alloc);
    try postMailWithEarlierHistory(alloc, runtime, "first message", .message);
    runtime.finishProcessing();
    try std.testing.expectEqual(@as(u32, 1), runtime.queued_history_owed);
}

const QueueEmptiedBy = enum { discard, take, remove, drop_messages, clear };

const GateWaiter = struct {
    runtime: *WorkerRuntime,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    got_prompt: bool = false,

    fn run(self: *@This()) void {
        const work = self.runtime.waitAndTakeNextWork(std.testing.allocator) catch null;
        if (work) |item| {
            self.got_prompt = true;
            freeWorkItem(std.testing.allocator, item);
        }
        self.done.store(true, .release);
    }

    fn settle() void {
        io_mod.sleep(60 * std.time.ns_per_ms);
    }
};
