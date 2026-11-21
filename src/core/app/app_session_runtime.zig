const std = @import("std");
const agents = @import("../agents/agents.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const agent_runtime = @import("../agent/agent_runtime.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const question_answer = @import("../agent/question_answer.zig");
const config_runtime = @import("../config/config_runtime.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const assistant_presentation = @import("../agent/assistant_presentation.zig");
const tool_admission = @import("../agent/runtime/tool_admission.zig");
const tool_presentation = @import("../agent/runtime/tool_presentation.zig");
const runtime_execution_memory = @import("../agent/runtime/execution_memory.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const mem_utils = @import("../shared/mem_utils.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const host_capability = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const diff = @import("../output/diff.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const app_lifecycle = @import("app_lifecycle.zig");
const provider_runtime = @import("provider_runtime.zig");
const input_completion_runtime = @import("input_completion_runtime.zig");
const image_attachments = @import("../images/image_attachments.zig");
const core_input_runtime = @import("../input/runtime.zig");
const io_mod = @import("../shared/io.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const list_window = @import("../shared/list_window.zig");
const text_utils = @import("../shared/text_utils.zig");
const session_runtime = @import("../session/session.zig");
const session_catalog = @import("../session/session_catalog.zig");
const session_codec = @import("../session/session_codec.zig");
const js_host_session_store = @import("../session/js_host_session_store.zig");
const session_event = @import("../session/session_event.zig");
const session_child_store = @import("../session/session_child_store.zig");
const result_store = @import("../session/result_store.zig");
const command_replay_store = @import("../session/command_replay_store.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const tooling_presentation = @import("../tooling/tool_presentation.zig");
const tool_args = @import("../tooling/tool_args.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const skill_invocation = @import("../skills/skill_invocation.zig");
const captured_command = @import("../tooling/captured_command.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const session_display_metadata = @import("../session/session_display_metadata.zig");
const session_title_generation = @import("../session/session_title_generation.zig");
const session_adapter = @import("../session/session_adapter.zig");
const turn_capture = @import("../workspace/turn_capture.zig");
const session_store = @import("../session/session_store.zig");
const session_catalog_cache = @import("../session/session_catalog_cache.zig");
const session_summary_codec = @import("../session/session_summary_codec.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const subagent_child_state = @import("../subagent/child_state.zig");
const subagent_reports = @import("../subagent/reports.zig");
const agent_frame = @import("../shared/agent_frame.zig");
const recovery_prompt = @import("../shared/recovery_prompt.zig");
const subagent_authority = @import("../subagent/authority.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const builtin_tools = @import("../../builtins/tools.zig");
const types = @import("../shared/types.zig");
const full_transcript_metadata = @import("../output/full_transcript_metadata.zig");
const history_range = @import("../shared/history_range.zig");
const permissions = @import("../permissions/permissions.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const operation_control = @import("../mcp/operation_control.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");
const resume_projection = @import("../../ui/transcript/resume_projection.zig");
const tool_group_projection = @import("../../ui/transcript/tool_group_projection.zig");
const question_ui = @import("../../ui/footer/question_ui.zig");
const render_input = @import("../../ui/footer/render_input.zig");
const ui_input = @import("../../ui/input/runtime.zig");
const ui_render = @import("../../ui/render.zig");
const update_notes = @import("../upgrade/update_notes.zig");
const update_target = @import("../upgrade/update_target.zig");
const session_persistence = @import("session_persistence.zig");
const BackgroundSessionPolicy = session_persistence.BackgroundSessionPolicy;
const LiveSessionWait = session_persistence.LiveSessionWait;
pub const SessionPickerScope = session_persistence.SessionPickerScope;
pub const ResumeHandoffIntent = session_persistence.ResumeHandoffIntent;
pub const SessionPicker = session_persistence.SessionPicker;
const SessionPickerCatalogCache = session_persistence.SessionPickerCatalogCache;
const SessionPickerLoad = session_persistence.SessionPickerLoad;
const TitleGenerationLoad = session_persistence.TitleGenerationLoad;
const JsHostSessionStore = session_persistence.JsHostSessionStore;
const PendingCancelledCommand = session_persistence.PendingCancelledCommand;
pub const Persistence = session_persistence.Persistence;
pub const TranscriptArchiveBoundaries = session_persistence.TranscriptArchiveBoundaries;
const optionalStringEql = session_persistence.optionalStringEql;
const applySessionPickerCatalogPage = session_persistence.applySessionPickerCatalogPage;
const selectionAfterLoadedPage = session_persistence.selectionAfterLoadedPage;
const resumePageLimitForRows = session_persistence.resumePageLimitForRows;

/// What the footer draws of `menu`.
pub fn forkMenuProjection(menu: *const session_persistence.ForkMenu) render_input.ForkMenuProjection {
    return .{
        .points = menu.points,
        .selected = menu.selected,
        .window_start = menu.window_start,
        .question = if (menu.question) |children| copyableCount(children) else null,
    };
}

/// How many of `children` a fork can take a copy of (D97).
fn copyableCount(children: []const session_adapter.Child) usize {
    var count: usize = 0;
    for (children) |child| {
        if (subagent_child_state.copyableAtFork(child)) count += 1;
    }
    return count;
}

const Allocator = std.mem.Allocator;
const live_session_handoff_timeout_ms: u64 = 2_000;
const live_session_worker_cancel_timeout_ms: u64 = 5_000;

const LiveSessionTransitionEvent = union(enum) {
    request: BackgroundSessionPolicy,
    settle,
};

const LiveSessionTransitionAction = union(enum) {
    apply_now: BackgroundSessionPolicy,
    cancel_and_defer,
    apply_pending: BackgroundSessionPolicy,
    none,
};

const LiveSessionTransitionDecision = struct {
    pending_policy: ?BackgroundSessionPolicy,
    action: LiveSessionTransitionAction,
};

const LiveSessionTimeout = enum { worker, geometry };

fn liveSessionWaitTimeout(wait: LiveSessionWait, processing: bool, now_ms: u64) ?LiveSessionTimeout {
    return switch (wait) {
        .worker => |started| if (processing and now_ms -| started >= live_session_worker_cancel_timeout_ms) .worker else null,
        .geometry => |started| if (!processing and now_ms -| started >= live_session_handoff_timeout_ms) .geometry else null,
    };
}

fn decideLiveSessionTransition(
    cooperative: bool,
    processing: bool,
    pending_policy: ?BackgroundSessionPolicy,
    event: LiveSessionTransitionEvent,
) LiveSessionTransitionDecision {
    return switch (event) {
        .request => |policy| if (!cooperative or !processing)
            .{
                .pending_policy = null,
                .action = .{ .apply_now = policy },
            }
        else if (pending_policy == null)
            .{
                .pending_policy = policy,
                .action = .cancel_and_defer,
            }
        else
            .{
                .pending_policy = policy,
                .action = .none,
            },
        .settle => if (processing)
            .{
                .pending_policy = pending_policy,
                .action = .none,
            }
        else if (pending_policy) |policy|
            .{
                .pending_policy = null,
                .action = .{ .apply_pending = policy },
            }
        else
            .{
                .pending_policy = null,
                .action = .none,
            },
    };
}

test "session wait deadlines distinguish worker cancellation from stalled geometry" {
    try std.testing.expectEqual(@as(?LiveSessionTimeout, null), liveSessionWaitTimeout(.{ .worker = 1_000 }, true, 5_999));
    try std.testing.expectEqual(@as(?LiveSessionTimeout, .worker), liveSessionWaitTimeout(.{ .worker = 1_000 }, true, 6_000));
    try std.testing.expectEqual(@as(?LiveSessionTimeout, null), liveSessionWaitTimeout(.{ .worker = 1_000 }, false, 10_000));
    try std.testing.expectEqual(@as(?LiveSessionTimeout, null), liveSessionWaitTimeout(.{ .geometry = 1_000 }, true, 10_000));
    try std.testing.expectEqual(@as(?LiveSessionTimeout, null), liveSessionWaitTimeout(.{ .geometry = 1_000 }, false, 2_999));
    try std.testing.expectEqual(@as(?LiveSessionTimeout, .geometry), liveSessionWaitTimeout(.{ .geometry = 1_000 }, false, 3_000));
}

fn nextImageIdForResume(alloc: Allocator, history: []const types.HistoryTurn) !usize {
    const restored_catalog = try session_runtime.collect_image_catalog(
        alloc,
        history,
        &.{},
    );
    defer types.freeImageAttachmentSlice(alloc, restored_catalog);
    return (try image_attachments.calculate_next_image_id(restored_catalog)).next_id;
}

pub const HistoryAppendOutcome = enum {
    uncommitted,
    committed,
};

const UpgradeNotice = struct {
    version: []const u8,
    channel: update_target.Channel,
    previous_revision: []const u8,
    revision: []const u8,
};

const ResumeNotice = union(enum) {
    session,
    upgrade: UpgradeNotice,
    /// The id of the session this one was forked from.
    fork: []const u8,
};

fn writeUpgradeNoticeBody(writer: *std.Io.Writer, upgrade: UpgradeNotice) !void {
    try writer.writeAll("spark has been updated to ");
    if (upgrade.channel == .dev and update_target.isValidRevision(upgrade.revision)) {
        try writer.print("dev {s} (v{s})", .{
            upgrade.revision[0..@min(upgrade.revision.len, 12)],
            update_target.normalizeVersion(upgrade.version),
        });
    } else {
        try writer.print("v{s}", .{update_target.normalizeVersion(upgrade.version)});
    }
    if (update_notes.destination(
        upgrade.channel,
        upgrade.version,
        upgrade.previous_revision,
        upgrade.revision,
    )) |notes| {
        try writer.writeByte(' ');
        try notes.writeHyperlinkLabel(writer);
    }
}

pub const ResumeHandoffState = struct {
    intent: ResumeHandoffIntent,
    has_writable_session: bool,
    is_pristine: bool,
};

pub fn shouldCreateResumeHandoff(state: ResumeHandoffState) bool {
    return state.intent != .none and
        state.has_writable_session and
        (!state.is_pristine or state.intent == .upgrade_requested);
}

/// Owns `session_id`; callers must release it with `deinit`.
pub const ResumeHandoff = struct {
    session_id: []u8,

    pub fn deinit(self: *ResumeHandoff, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

pub const ShutdownOutcome = struct {
    handoff: ?ResumeHandoff = null,
    failure: ?anyerror = null,

    pub fn deinit(self: *ShutdownOutcome, alloc: Allocator) void {
        if (self.handoff) |*handoff| handoff.deinit(alloc);
        self.* = undefined;
    }
};

pub const SessionPreferencePatch = struct {
    provider: ?model_provider.ProviderId = null,
    model: ?[]const u8 = null,
    effort: ?types.ReasoningEffort = null,
    fast_mode: ?bool = null,
    ultrafast_mode: ?bool = null,

    pub fn userSettingsPatch(self: SessionPreferencePatch) config_runtime.UserSettingsPatch {
        var patch = config_runtime.UserSettingsPatch{
            .provider = self.provider,
            .effort = self.effort,
            .fast_mode = self.fast_mode,
            .ultrafast_mode = self.ultrafast_mode,
        };
        if (self.model) |model| patch.model_preference = .{
            .provider = self.provider orelse .none,
            .model = model,
        };
        return patch;
    }
};

pub const PreferenceCommitResult = struct {
    settings_outcome: ?config_runtime.CommitOutcome = null,
    settings_error: ?anyerror = null,
    settings_failure_cleanup: config_runtime.LegacyCleanup = .{},
    session_error: ?anyerror = null,

    pub fn deinit(self: *PreferenceCommitResult, alloc: Allocator) void {
        if (self.settings_outcome) |*outcome| outcome.deinit(alloc);
        self.settings_failure_cleanup.deinit(alloc);
        self.* = undefined;
    }
};

/// A request saved this long ago, or dated this far in the future, asks
/// before it is sent again (`tests/tla/recovery/Resume.tla` OldAsks).
const resume_max_age_ms: i64 = 24 * std.time.ms_per_hour;
const resume_clock_slack_ms: i64 = 5 * std.time.ms_per_min;

fn resumeIsStale(now_ms: i64, saved_ms: u64) bool {
    const saved = std.math.cast(i64, saved_ms) orelse return true;
    return now_ms -| saved > resume_max_age_ms or saved -| now_ms > resume_clock_slack_ms;
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        pub fn captureImageAttachment(
            app: *App,
            agent: *AppAgent,
            attachment: *types.ImageAttachment,
        ) !void {
            const snapshot_dir = try imageSnapshotStorageDir(app, agent);
            defer app.alloc.free(snapshot_dir);
            try image_attachments.captureImageSnapshot(
                app.alloc,
                attachment,
                snapshot_dir,
            );
            // A v2 session keeps the image inside the turn (D44).
            if (agent.session_persistence.v2 != null) try image_attachments.inlineCapturedSnapshot(app.alloc, attachment);
        }

        fn imageSnapshotStorageDir(app: *App, agent: *AppAgent) ![]u8 {
            // Captured into the process's temporary folder; the turn keeps
            // the bytes (D44).
            return session_store.imageSnapshotTempDir(app.alloc, &agent.session_persistence.image_snapshot_temp_dir);
        }

        pub fn configureStartupPreferences(
            app: *App,
            agent: *AppAgent,
            provider: model_provider.ProviderId,
            configured_model: []const u8,
            model_source: config_runtime.ModelSource,
            selected_model: []const u8,
            effort: types.ReasoningEffort,
            fast_mode: bool,
            fast_mode_model_bound: bool,
            configured_ultrafast_mode: bool,
            ultrafast_process_override: ?bool,
            effort_process_override: ?types.ReasoningEffort,
            fast_process_override: ?bool,
            provider_process_override: ?model_provider.ProviderId,
        ) !void {
            try replacePreferences(
                app.alloc,
                &agent.session_persistence.workspace_preferences,
                .{
                    .provider = provider,
                    .model = @constCast(configured_model),
                    .effort = effort,
                    .fast_mode = fast_mode,
                    .ultrafast_mode = configured_ultrafast_mode,
                },
            );
            try replacePreferences(
                app.alloc,
                &agent.session_persistence.session_preferences,
                agent.session_persistence.workspace_preferences.?,
            );
            agent.session_persistence.fast_mode_model_bound = fast_mode_model_bound;
            if (agent.session_persistence.process_model_override) |model| {
                app.alloc.free(model);
                agent.session_persistence.process_model_override = null;
            }
            if (model_source == .process_override) {
                agent.session_persistence.process_model_override =
                    try app.alloc.dupe(u8, selected_model);
            }
            agent.session_persistence.process_effort_override = effort_process_override;
            agent.session_persistence.process_fast_override = fast_process_override;
            agent.session_persistence.process_ultrafast_override = ultrafast_process_override;
            agent.session_persistence.process_provider_override = provider_process_override;
            // A provider override must pin the resolved model too, or a resume
            // would restore the session's model from a different provider.
            if (provider_process_override != null and
                agent.session_persistence.process_model_override == null)
            {
                agent.session_persistence.process_model_override =
                    try app.alloc.dupe(u8, selected_model);
            }
        }

        /// Gives an instance launched after the first, at launch and after each
        /// `/new`, the model the launch chose with `--model`, `--provider`, or
        /// `SPARK_MODEL`, which the first instance takes through the app's
        /// selection at startup. An instance's
        /// model is its own session preference, and its fresh session still
        /// saves the one it started with, its profile's or the configured one,
        /// as the first instance's does.
        pub fn applyProcessModelOverride(app: *App, agent: *AppAgent) !void {
            const model = agent.session_persistence.process_model_override orelse return;
            const preferences = if (agent.session_persistence.session_preferences) |*value| value else return;
            const owned = try app.alloc.dupe(u8, model);
            app.alloc.free(preferences.model);
            preferences.model = owned;
            if (agent.session_persistence.process_provider_override) |provider| preferences.provider = provider;
        }

        /// The v2 store's notice that converting a v1 session is slow, as a
        /// dim line (D61).
        fn conversionNotice(context: ?*anyopaque, text: []const u8) void {
            if (comptime !@hasDecl(App, "writeDomainNotice")) return;
            const app: *App = @ptrCast(@alignCast(context.?));
            app.writeDomainNotice(.{ .topic = "session", .tone = .information, .body = text }, true) catch |err|
                debug_trace.logf("convert", "action=NoticeDropped err={s}", .{@errorName(err)});
        }

        /// The reason a v1 session the startup resume refused with `err`
        /// can't be converted (D61), for the launch's exit message, or null.
        /// Caller owns it.
        pub fn conversionRefusal(agent: *AppAgent, alloc: Allocator, err: anyerror) ?[]u8 {
            if (err != error.InvalidSessionFormat) return null;
            const store = agent.session_persistence.v2_store orelse return null;
            const problem = store.conversionProblem() orelse return null;
            return alloc.dupe(u8, problem) catch null;
        }

        /// Says in a notice why a session v1 holds can't be converted (D61),
        /// on an in-app resume that `err` refused.
        fn noteConversionProblem(app: *App, store: *const session_adapter.Store, err: anyerror) void {
            if (comptime !@hasDecl(App, "writeDomainNotice")) return;
            if (err != error.InvalidSessionFormat) return;
            const problem = store.conversionProblem() orelse return;
            var buffer: [640]u8 = undefined;
            const body = std.mem.print(&buffer, "This session can't be converted (InvalidSessionFormat): {s}", .{problem}) catch problem;
            app.writeDomainNotice(.{ .topic = "session", .tone = .@"error", .body = body }, true) catch |write_err|
                debug_trace.logf("convert", "action=NoticeDropped err={s}", .{@errorName(write_err)});
        }

        pub fn initializePersistence(
            app: *App,
            agent: *AppAgent,
            required: bool,
        ) !void {
            if (comptime !runtime_profile.allows(App, .durable_sessions)) return;
            const opened = session_adapter.Store.openFromEnv(app.alloc) catch |err| {
                if (required) return err;
                return;
            };
            const store = try agent.session_persistence.adoptStore(app.alloc, opened);
            store.notice = .{ .context = app, .emit = conversionNotice };
        }

        pub fn enableSessionStores(app: *App, agent: *AppAgent) void {
            if (comptime !runtime_profile.allows(App, .durable_sessions)) return;
            const v2 = agent.session_persistence.v2 orelse return;
            if (comptime @hasDecl(@TypeOf(agent.session), "configureWebFetchArtifactBlobs")) {
                // A v2 session's downloads are its blobs (D44, D49).
                if (v2.childCapability()) |capability| {
                    agent.session.configureWebFetchArtifactBlobs(app.alloc, capability, v2.id());
                } else |err| {
                    debug_trace.logf("session", "event=sessions_v2_web_fetch_store_unavailable session={s} err={s}", .{ v2.id(), @errorName(err) });
                    agent.session.clearWebFetchArtifacts();
                }
            }
            enableSubagentHostV2(app, agent, v2);
        }

        /// Starts the session an instance opens with. In a profile, it starts
        /// with and saves the profile's model and effort, so resuming it
        /// brings them back; `--model`, `--effort`, and `SPARK_MODEL` shape only
        /// the run that passed them. A session `/new` starts later begins
        /// with what the one it replaces had saved (`installFreshLiveSession`).
        pub fn beginInstanceSession(app: *App, agent: *AppAgent) !void {
            return beginFresh(app, agent, .instance_start, null);
        }

        const FreshStart = enum { instance_start, later };

        /// `carried`, when given, is what the new session starts with in
        /// place of the workspace's preferences. The caller keeps it.
        fn beginFresh(app: *App, agent: *AppAgent, start: FreshStart, carried: ?session_codec.DurableSessionPreferences) !void {
            closeWritableSession(app, agent);
            // A fresh session starts with no usage, whether or not it persists.
            agent.total_input_tokens = 0;
            agent.total_output_tokens = 0;
            agent.total_web_search_requests = 0;
            if (comptime runtime_profile.allows(App, .js_host_sessions)) {
                try beginFreshJsHostSession(app, agent, carried);
            }
            defer syncTranscriptWindowSaveMode(app, agent);
            defer syncTranscriptArchiveAvailable(app, agent);
            if (comptime !runtime_profile.allows(App, .durable_sessions)) return;
            if (agent.session_persistence.v2_store) |v2_store| try beginFreshV2Session(app, agent, v2_store, start, carried);
        }

        /// The preferences `agent`'s open session has saved, or null when it
        /// has no session or they can't be read. Caller owns.
        fn savedPreferences(app: *App, agent: *AppAgent) ?session_codec.DurableSessionPreferences {
            if (comptime runtime_profile.allows(App, .js_host_sessions)) {
                if (jsHostSavedPreferences(app, agent)) |preferences| return preferences;
            }
            if (comptime !runtime_profile.allows(App, .durable_sessions)) return null;
            agent.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer agent.session_persistence.write_mutex.unlock(io_mod.getIo());
            const v2 = agent.session_persistence.v2 orelse return null;
            return v2.currentPreferences(app.alloc) catch |err| {
                debug_trace.logf("session", "saved preferences unavailable session={s} err={s}; the new session starts from the workspace's", .{ v2.id(), @errorName(err) });
                return null;
            };
        }

        /// The transcript window drops entries only once the session log holds
        /// them, so it follows whether `agent`'s session writes one; only the
        /// transcript in context is set.
        pub fn syncTranscriptWindowSaveMode(app: *App, agent: *AppAgent) void {
            if (comptime !@hasField(App, "shell")) return;
            if (comptime !@hasDecl(@TypeOf(app.shell), "setTranscriptWindowSaved")) return;
            if (!transcriptInContext(app, agent)) return;
            const saved = if (comptime @hasField(@TypeOf(agent.session_persistence), "v2")) agent.session_persistence.v2 != null else false;
            app.shell.setTranscriptWindowSaved(app.alloc, saved) catch |err| {
                debug_trace.logf("transcript_window", "save mode not set saved={} err={s}", .{ saved, @errorName(err) });
            };
        }

        /// Starts the window of `agent`'s transcript, in context, when it is
        /// not running: an agent's session can start while another's
        /// transcript is on screen.
        pub fn ensureTranscriptWindow(app: *App, agent: *AppAgent) void {
            if (comptime !@hasField(App, "shell")) return;
            if (comptime !@hasField(@TypeOf(app.shell), "transcript_window")) return;
            if (app.shell.transcript_window != null) return;
            syncTranscriptWindowSaveMode(app, agent);
        }

        /// A v2 session starts in memory; its folder appears with the first
        /// turn (D2), so a launch that never prompts leaves nothing behind.
        fn beginFreshV2Session(
            app: *App,
            agent: *AppAgent,
            v2_store: *session_adapter.Store,
            start: FreshStart,
            carried: ?session_codec.DurableSessionPreferences,
        ) !void {
            const seed = carried orelse agent.session_persistence.workspace_preferences orelse
                return error.SessionPreferencesUnavailable;
            var preferences = try seed.dupe(app.alloc);
            defer preferences.deinit(app.alloc);
            if (comptime agents.hasAgentField(App, "profile")) {
                if (start == .instance_start) {
                    const profile = &agent.profile.profile;
                    if (profile.model) |model| {
                        const owned = try app.alloc.dupe(u8, model);
                        app.alloc.free(preferences.model);
                        preferences.model = owned;
                    }
                    if (profile.effort) |effort| preferences.effort = effort;
                }
            }
            try replacePreferences(
                app.alloc,
                &agent.session_persistence.session_preferences,
                preferences,
            );
            agent.session_persistence.v2 = session_adapter.Session.create(app.alloc, v2_store, app.workspace_root, .app, .{
                .preferences = preferences,
                .language = agent.session.languageSnapshot(),
            }) catch |err| {
                try warnNonDurable(app, "session creation failed", err);
                return;
            };
            agent.session_persistence.degraded_warning_emitted = false;
        }

        /// The preferences `agent`'s JS-host session has saved, or null when
        /// it has none or they can't be copied. Caller owns.
        fn jsHostSavedPreferences(app: *App, agent: *AppAgent) ?session_codec.DurableSessionPreferences {
            const owner = if (agent.session_persistence.js_host_session) |*value| value else return null;
            return owner.state.preferences.dupe(app.alloc) catch |err| {
                debug_trace.logf("session", "saved preferences unavailable session={s} err={s}; the new session starts from the workspace's", .{ owner.state.id, @errorName(err) });
                return null;
            };
        }

        /// `carried`, when given, is what the new session starts with in
        /// place of the workspace's preferences, as in `beginFresh`.
        fn beginFreshJsHostSession(app: *App, agent: *AppAgent, carried: ?session_codec.DurableSessionPreferences) !void {
            const preferences = carried orelse agent.session_persistence.workspace_preferences orelse
                return error.SessionPreferencesUnavailable;
            try replacePreferences(
                app.alloc,
                &agent.session_persistence.session_preferences,
                preferences,
            );
            var state = try freshState(app, agent, preferences);
            errdefer state.deinit(app.alloc);
            if (agent.session_persistence.js_host_session) |*owner| owner.deinit(app.alloc);
            agent.session_persistence.js_host_session = .{
                .state = state,
                .revision = null,
            };
            state = undefined;
        }

        pub fn clearSession(app: *App, agent: *AppAgent) !void {
            try resetSessionWithBackgroundPolicy(app, agent, .carry_forward);
        }

        pub fn newSession(app: *App, agent: *AppAgent) !void {
            try resetSessionWithBackgroundPolicy(app, agent, .carry_forward);
        }

        pub fn resetSession(app: *App, agent: *AppAgent) !void {
            try resetSessionWithBackgroundPolicy(app, agent, .stop_forget);
        }

        fn resetSessionWithBackgroundPolicy(
            app: *App,
            agent: *AppAgent,
            background_policy: BackgroundSessionPolicy,
        ) !void {
            if (comptime @hasDecl(@TypeOf(agent.worker), "holdSessionTransition")) {
                agent.worker.holdSessionTransition();
            }
            errdefer {
                agent.session_persistence.pending_live_session_wait = null;
                releaseLiveSessionTransitionHold(app, agent);
            }
            const previous_policy = agent.session_persistence.pending_live_session_policy;
            const processing = agent.worker.isProcessing();
            const decision = decideLiveSessionTransition(
                runtime_profile.allows(App, .cooperative_agent),
                processing,
                previous_policy,
                .{ .request = background_policy },
            );
            if (previous_policy == null) {
                const now = operation_control.monotonicMillis(io_mod.getIo());
                agent.session_persistence.pending_live_session_wait = if (processing) .{ .worker = now } else .{ .geometry = now };
            }
            if (previous_policy) |previous| {
                if (decision.pending_policy) |next| {
                    if (previous != next) {
                        debug_trace.logf(
                            "session",
                            "event=live_session_transition_coalesced previous={s} next={s}",
                            .{ @tagName(previous), @tagName(next) },
                        );
                    }
                }
            }
            agent.session_persistence.pending_live_session_policy = decision.pending_policy;
            switch (decision.action) {
                .apply_now => |policy| {
                    if (!freshSessionResizeReady(app)) {
                        agent.session_persistence.pending_live_session_policy = policy;
                        if (processing) agent.worker.requestCancel();
                        debug_trace.logf("session", "event=live_session_transition_deferred reason=resize_pending", .{});
                        return;
                    }
                    applyLiveSessionTransition(app, agent, policy) catch |err| {
                        if (handleScrollbackHandoffError(app, agent, policy, err)) return;
                        return err;
                    };
                },
                .cancel_and_defer => agent.worker.requestCancel(),
                .none => if (decision.pending_policy == null) {
                    agent.session_persistence.pending_live_session_wait = null;
                    releaseLiveSessionTransitionHold(app, agent);
                },
                .apply_pending => unreachable,
            }
        }

        fn freshSessionResizeReady(app: *App) bool {
            if (comptime @hasField(@TypeOf(app.shell), "has_committed_frame")) {
                if (!app.shell.has_committed_frame) return true;
            }
            if (comptime @hasDecl(App, "admitPendingResizeSignal")) {
                _ = app.admitPendingResizeSignal("session_handoff");
            }
            if (!shell_runtime.resizeLifecycleIdle(&app.shell)) return false;
            if (comptime !host_target.is_wasm and @hasField(App, "terminal")) {
                const actual = app.terminal.queryLayout(app.shell.layout.rows -| app.shell.layout.content_bottom) catch return false;
                if (actual.cols != app.shell.layout.cols or actual.rows != app.shell.layout.rows) return false;
            }
            return true;
        }

        fn handleScrollbackHandoffError(app: *App, agent: *AppAgent, policy: BackgroundSessionPolicy, err: anyerror) bool {
            switch (err) {
                error.SessionScrollbackHandoffUnavailable,
                error.SessionScrollbackHandoffIncomplete,
                => {
                    agent.session_persistence.pending_live_session_policy = policy;
                    debug_trace.logf("session", "event=live_session_transition_deferred reason=scrollback_handoff err={s}", .{@errorName(err)});
                    return true;
                },
                error.SessionScrollbackHandoffGeometryChanged => {
                    agent.session_persistence.pending_live_session_policy = null;
                    agent.session_persistence.pending_live_session_wait = null;
                    app.shell.cancelSessionScrollbackHandoff("geometry_changed");
                    releaseLiveSessionTransitionHold(app, agent);
                    debug_trace.logf("session", "event=live_session_transition_cancelled reason=scrollback_handoff_geometry_changed", .{});
                    if (comptime @hasDecl(App, "writeDomainNotice")) {
                        app.writeDomainNotice(.{
                            .topic = "session",
                            .tone = .warning,
                            .body = "Session change cancelled after a terminal resize. The old session was kept; an active turn may have been cancelled. Retry the command.",
                        }, true) catch |notice_err| {
                            debug_trace.logf("session", "event=transition_cancel_notice_dropped err={s}", .{@errorName(notice_err)});
                        };
                    }
                    return true;
                },
                else => return false,
            }
        }

        pub fn cancelPendingLiveSessionForInputLimit(app: *App, agent: *AppAgent) !void {
            try cancelPendingLiveSessionForInput(app, agent, "deferred_input_limit", "Session change cancelled because input arrived faster than it could finish. Your input is still being delivered to the old session; retry the command.");
        }

        pub fn cancelPendingLiveSessionForTimeout(app: *App, agent: *AppAgent) !void {
            try cancelPendingLiveSessionForInput(app, agent, "resize_timeout", "Session change cancelled because the terminal resize did not settle. Continuing in the old session; retry the command.");
        }

        fn cancelPendingLiveSessionForWorkerTimeout(app: *App, agent: *AppAgent) !void {
            try cancelPendingLiveSessionForInput(app, agent, "worker_timeout", "Session change cancelled because the active turn did not stop. Continuing in the old session; retry the command.");
        }

        fn cancelPendingLiveSessionForInput(app: *App, agent: *AppAgent, reason: []const u8, notice: []const u8) !void {
            if (agent.session_persistence.pending_live_session_policy == null) return;
            agent.session_persistence.pending_live_session_policy = null;
            agent.session_persistence.pending_live_session_wait = null;
            try giveUpScrollbackHandoff(app, reason);
            releaseLiveSessionTransitionHold(app, agent);
            debug_trace.logf("session", "event=live_session_transition_cancelled reason={s}", .{reason});
            try app.writeDomainNotice(.{ .topic = "session", .tone = .warning, .body = notice }, true);
        }

        /// Gives up a scrollback handoff that still has rows to write. When
        /// its frame already pushed some rows into scrollback, the terminal
        /// is cleared and the transcript printed again, as after a resize, so
        /// the switch's next handoff does not push those rows a second time.
        fn giveUpScrollbackHandoff(app: *App, reason: []const u8) !void {
            if (comptime !@hasField(@TypeOf(app.shell), "pending_session_scrollback_handoff") or !@hasField(App, "metrics")) return;
            const pending = app.shell.pending_session_scrollback_handoff orelse return;
            app.shell.cancelSessionScrollbackHandoff(reason);
            if (pending.remaining_rows < pending.total_rows) {
                try app.shell.requestTerminalReset(&app.metrics);
                debug_trace.logf("session", "event=scrollback_handoff_reset reason={s} pushed_rows={d}", .{ reason, pending.total_rows - pending.remaining_rows });
            }
        }

        pub fn settlePendingLiveSessionTransition(app: *App, agent: *AppAgent) !void {
            if (agent.session_persistence.pending_live_session_policy == null) return;
            const processing = agent.worker.isProcessing();
            // The handoff goes on only while the agent is idle, and no agent's
            // transcript can be swapped in until it ends. A turn that starts
            // meanwhile, such as one a subagent's report starts, would hold
            // the handoff, and every hidden agent, until it ends, and that
            // turn may wait on a hidden agent. So the handoff yields; the
            // change hands the rows off again once the agent is idle.
            if (processing) try giveUpScrollbackHandoff(app, "agent_busy");
            const now = operation_control.monotonicMillis(io_mod.getIo());
            var wait = agent.session_persistence.pending_live_session_wait orelse if (processing) LiveSessionWait{ .worker = now } else LiveSessionWait{ .geometry = now };
            if (wait == .worker and !processing) wait = .{ .geometry = now };
            agent.session_persistence.pending_live_session_wait = wait;
            if (liveSessionWaitTimeout(wait, processing, now)) |timeout| {
                switch (timeout) {
                    .worker => try cancelPendingLiveSessionForWorkerTimeout(app, agent),
                    .geometry => try cancelPendingLiveSessionForTimeout(app, agent),
                }
                return;
            }
            errdefer {
                agent.session_persistence.pending_live_session_wait = null;
                releaseLiveSessionTransitionHold(app, agent);
            }
            const decision = decideLiveSessionTransition(
                runtime_profile.allows(App, .cooperative_agent),
                processing,
                agent.session_persistence.pending_live_session_policy,
                .settle,
            );
            agent.session_persistence.pending_live_session_policy = decision.pending_policy;
            switch (decision.action) {
                .apply_pending => |policy| {
                    if (comptime @hasDecl(@TypeOf(app.shell), "sessionScrollbackHandoffPending")) {
                        if (app.shell.sessionScrollbackHandoffPending()) {
                            if (comptime @hasDecl(App, "admitPendingResizeSignal")) {
                                _ = app.admitPendingResizeSignal("session_handoff");
                            }
                            if (!shell_runtime.resizeLifecycleIdle(&app.shell)) {
                                _ = handleScrollbackHandoffError(app, agent, policy, error.SessionScrollbackHandoffGeometryChanged);
                                return;
                            }
                        }
                    }
                    applyIdleLiveSessionTransition(app, agent, policy, true) catch |err| {
                        if (handleScrollbackHandoffError(app, agent, policy, err)) return;
                        return err;
                    };
                    try installFreshLiveSession(app, agent);
                },
                .none => {},
                .apply_now, .cancel_and_defer => unreachable,
            }
        }

        fn applyLiveSessionTransition(
            app: *App,
            agent: *AppAgent,
            background_policy: BackgroundSessionPolicy,
        ) !void {
            try prepareLiveSessionTransition(app, agent, background_policy, true);
            try installFreshLiveSession(app, agent);
        }

        fn installFreshLiveSession(app: *App, agent: *AppAgent) !void {
            defer {
                agent.session_persistence.pending_live_session_wait = null;
                releaseLiveSessionTransitionHold(app, agent);
            }
            // The new session keeps what the one it replaces had saved: its
            // profile's model and effort, or a /model or /effort choice, never
            // a run flag.
            var carried = agent.session_persistence.next_session_preferences;
            agent.session_persistence.next_session_preferences = null;
            defer if (carried) |*value| value.deinit(app.alloc);
            const keeps_process_model = runsProcessModel(app, agent);
            try beginFresh(app, agent, .later, carried);
            enableSessionStores(app, agent);
            // An instance launched after the first runs its session's model,
            // so the --model or SPARK_MODEL it ran is laid over it again; the
            // first keeps the app's selection across sessions.
            if (keeps_process_model) try applyProcessModelOverride(app, agent);
            try finishLiveSessionTransition(app);
            try noteStoppedSubagentTasks(app, agent);
        }

        fn stopSubagentsForSwitch(app: *App, agent: *AppAgent) !usize {
            if (comptime !@hasField(App, "child_agents")) return 0;
            return @import("app_agents_runtime.zig").Runtime(App).stopSubagentsForSwitch(app, agent);
        }

        /// Says, in the session a switch opened, how many subagent tasks the
        /// switch stopped; the subagents stay in the session it left (D97).
        fn noteStoppedSubagentTasks(app: *App, agent: *AppAgent) !void {
            const stopped = agent.session_persistence.switch_stopped_tasks;
            agent.session_persistence.switch_stopped_tasks = 0;
            if (stopped == 0) return;
            var buf: [128]u8 = undefined;
            const body = if (stopped == 1)
                "stopped 1 running subagent task; the subagent stays in the previous session"
            else
                try std.mem.print(&buf, "stopped {d} running subagent tasks; the subagents stay in the previous session", .{stopped});
            try app.writeDomainNotice(.{ .topic = "session", .tone = .neutral, .body = body }, true);
        }

        /// Whether `agent`, an instance launched after the first, runs the
        /// model `--model` or `SPARK_MODEL` chose, not one picked since with
        /// `/model`.
        fn runsProcessModel(app: *App, agent: *AppAgent) bool {
            if (comptime !agents.hasAgentField(App, "role")) return false;
            if (agent == &app.main_agent or agent.role != .instance) return false;
            if (agent.session_persistence.session_preferences == null) return false;
            return provider_runtime.runsProcessModel(app, agent);
        }

        fn releaseLiveSessionTransitionHold(app: *App, agent: *AppAgent) void {
            if (comptime @hasField(App, "terminal_input_runtime")) {
                if (comptime @hasDecl(@TypeOf(app.terminal_input_runtime), "hasDeferredSessionInput") and
                    @hasDecl(@TypeOf(app.terminal_input_runtime), "allowCurrentDeferredSessionInputForReplay"))
                {
                    if (app.terminal_input_runtime.hasDeferredSessionInput()) {
                        app.terminal_input_runtime.allowCurrentDeferredSessionInputForReplay();
                        return;
                    }
                }
            }
            if (comptime @hasDecl(@TypeOf(agent.worker), "releaseSessionTransitionHold")) {
                agent.worker.releaseSessionTransitionHold();
            }
        }

        pub fn finishDeferredSessionInputReplay(app: *App, agent: *AppAgent) void {
            if (agent.session_persistence.pending_live_session_policy != null) return;
            releaseLiveSessionTransitionHold(app, agent);
        }

        pub fn prepareLiveSessionResume(app: *App, agent: *AppAgent) !void {
            try prepareLiveSessionTransition(app, agent, .stop_forget, false);
        }

        pub fn finishLiveSessionResume(app: *App) !void {
            debug_trace.logf("session", "event=live_session_resume_redraw dropped=terminal_screen_and_scrollback reason=switched_session_redraws_conversation", .{});
            try app.shell.requestTerminalReset(&app.metrics);
            app.shell.render_requests.request(.footer);
        }

        fn prepareLiveSessionTransition(
            app: *App,
            agent: *AppAgent,
            background_policy: BackgroundSessionPolicy,
            preserve_scrollback: bool,
        ) !void {
            if (preserve_scrollback) {
                agent.worker.requestCancel();
            } else {
                beginLiveSessionCancellation(app, agent);
            }
            agent.worker.waitUntilIdle();
            try applyIdleLiveSessionTransition(app, agent, background_policy, preserve_scrollback);
        }

        fn beginLiveSessionCancellation(app: *App, agent: *AppAgent) void {
            agent.worker.requestCancel();
            app_worker_runtime.Runtime(App).clearPacer(app, agent, "session_switch");
            if (comptime @hasDecl(App, "clearPendingSubmissionForSessionTransition")) {
                App.clearPendingSubmissionForSessionTransition(app, agent);
            } else {
                if (comptime @hasDecl(App, "clearPendingSubmission")) {
                    App.clearPendingSubmission(app, "session_transition");
                }
                agent.worker.clearQueuedPrompts(std.heap.c_allocator, &.{});
            }
        }

        fn retireLiveSessionCompaction(agent: *AppAgent) void {
            // Called after the worker is idle, before installing the next session.
            const observed = agent.worker.compactionActivitySnapshot();
            if (observed.operation) |op| {
                _ = agent.worker.dismissCompactionActivity(op.id, observed.revision);
            }
        }

        fn applyIdleLiveSessionTransition(
            app: *App,
            agent: *AppAgent,
            background_policy: BackgroundSessionPolicy,
            preserve_scrollback: bool,
        ) !void {
            if (preserve_scrollback) {
                if (comptime @hasField(App, "terminal")) {
                    if (comptime @hasField(@TypeOf(app.terminal), "alternate_screen_owner")) {
                        if (app.terminal.alternate_screen_owner != .none) return error.SessionScrollbackHandoffUnavailable;
                    }
                }
                if (!freshSessionResizeReady(app)) return error.SessionScrollbackHandoffUnavailable;
                try app.shell.commitVisibleTranscriptBeforeFreshSession(app.alloc, &app.metrics);
                beginLiveSessionCancellation(app, agent);
            }
            retireLiveSessionCompaction(agent);
            clearCachedSessionTitle(app, agent);
            agent.worker.discardEvents(std.heap.c_allocator);

            if (comptime @hasField(App, "subagents") and
                @hasDecl(@TypeOf(app.subagents), "clearProjection"))
            {
                app.subagents.clearProjection(app.alloc);
            }

            // What the session saved, read before it closes, for a fresh
            // session `installFreshLiveSession` starts next; a resume leaves
            // it to the next transition, which reads it again.
            if (agent.session_persistence.next_session_preferences) |*previous| previous.deinit(app.alloc);
            agent.session_persistence.next_session_preferences = savedPreferences(app, agent);
            // The session's subagents stop before its host joins their slot
            // threads, as /close and quit stop them (D97;
            // `tests/tla/session_manager/Wiring.tla` SwitchEnds).
            agent.session_persistence.switch_stopped_tasks = try stopSubagentsForSwitch(app, agent);
            closeWritableSession(app, agent);
            app.stopStream(agent);
            app.shell.clearTranscript(app.alloc);
            agent.session.reset(app.alloc);
            app.input_runtime.inputResetState().resetForSession(app.alloc);
            app.terminal_input_runtime.resetEscapeDecoder();
            app.clearPendingImages(agent);
            agent.change_tracker.clear(std.heap.c_allocator);
            diagnostics.resetSession();
            _ = background_policy;
            agent.context_snapshot.deinit(app.alloc);
            if (comptime @hasDecl(App, "returnLentQuestion")) app.returnLentQuestion();
            agent.question_prompt.discard(app.alloc, "session_reset");
            cancelSessionPicker(app, agent);
            agent.session_persistence.fork_menu.close(app.alloc);
            invalidateSessionPickerCaches(agent);
        }

        fn finishLiveSessionTransition(app: *App) !void {
            const welcome = try ui_render.welcomeMessage(app.alloc);
            defer app.alloc.free(welcome);
            try app.writeTranscriptClassified(welcome, true, .welcome);
            app.shell.render_requests.request(.footer);
            try shell_runtime.requestRedraw(&app.shell, &app.metrics, .replay_viewport);
        }

        pub fn resumeRequestedSession(app: *App, agent: *AppAgent) !void {
            return resumeRequestedSessionWithNotice(app, agent, .session);
        }

        /// The update's notice, in the fresh session an update relaunch
        /// opens when the session it handed over had no turn to resume (D81),
        /// drawn on a cleared terminal like a resumed one.
        pub fn writeUpgradeNotice(
            app: *App,
            version: []const u8,
            channel: update_target.Channel,
            previous_revision: []const u8,
            revision: []const u8,
        ) !void {
            try requestUpgradeRelaunchRedraw(app);
            var body: std.Io.Writer.Allocating = .init(app.alloc);
            defer body.deinit();
            try writeUpgradeNoticeBody(&body.writer, .{
                .version = version,
                .channel = channel,
                .previous_revision = previous_revision,
                .revision = revision,
            });
            try app.writeDomainNotice(.{ .topic = "", .tone = .success, .body = body.written() }, true);
        }

        /// Plain `spark` points at a turn the session `spark -c` opens left
        /// unfinished, whether or not `spark -c` would send it again on its own.
        /// The check reads the session index, so it waits for the first frame
        /// (`collectInterruptedTurnHint`).
        pub fn queueInterruptedTurnHint(app: *App) void {
            app.main_agent.session_persistence.interrupted_turn_hint_pending = true;
        }

        pub fn collectInterruptedTurnHint(app: *App) void {
            const first = &app.main_agent;
            if (!first.session_persistence.interrupted_turn_hint_pending) return;
            if (app.shell.render_requests.hasReason(.first_frame)) return;
            first.session_persistence.interrupted_turn_hint_pending = false;
            const v2_store = first.session_persistence.v2_store orelse return;
            if (!session_adapter.hasInterruptedTurn(v2_store, app.alloc, app.workspace_root)) return;
            debug_trace.logf("session", "event=interrupted_turn_hint", .{});
            app.writeDomainNotice(.{
                .topic = "session",
                .tone = .neutral,
                .body = "Interrupted turn · /resume to continue",
            }, true) catch |err| {
                debug_trace.logf("session", "event=interrupted_turn_hint_failed err={s}", .{@errorName(err)});
            };
        }

        pub fn resumeRequestedSessionAfterUpgrade(
            app: *App,
            agent: *AppAgent,
            version: []const u8,
            channel: update_target.Channel,
            previous_revision: []const u8,
            revision: []const u8,
        ) !void {
            return resumeRequestedSessionWithNotice(app, agent, .{ .upgrade = .{
                .version = version,
                .channel = channel,
                .previous_revision = previous_revision,
                .revision = revision,
            } });
        }

        /// Loads saved session `session_id` into `agent`, as startup's resume
        /// does, for an instance that resuming a host brings back. Run
        /// it in `agent`'s screen context, so its conversation draws into
        /// its own transcript. The first instance's startup alone sets the
        /// terminal's replay anchor and the remembered session.
        pub fn resumeSessionById(app: *App, agent: *AppAgent, session_id: []const u8) !void {
            if (comptime !runtime_profile.allows(App, .durable_sessions)) return error.SessionPersistenceUnavailable;
            const v2_store = agent.session_persistence.v2_store orelse return error.SessionPersistenceUnavailable;
            const v2 = try session_adapter.Session.resumeSession(app.alloc, v2_store, .{ .id = session_id }, app.workspace_root, .app);
            try installResumedV2Session(app, agent, v2, .session);
        }

        fn resumeRequestedSessionWithNotice(
            app: *App,
            agent: *AppAgent,
            notice: ResumeNotice,
        ) !void {
            if (comptime runtime_profile.allows(App, .js_host_sessions) and
                !runtime_profile.allows(App, .durable_sessions))
            {
                return resumeRequestedJsHostSessionWithNotice(app, agent, notice);
            }
            var target = app.requested_resume orelse return;
            app.requested_resume = null;
            defer target.deinit(app.alloc);

            const v2_store = agent.session_persistence.v2_store orelse return error.SessionStoreUnavailable;
            const v2_target: session_adapter.Target = switch (target) {
                .pick => return openSessionPicker(app, agent),
                .last => .last,
                // The manager records the session each host last opened.
                .remembered => .last_opened,
                .id => |session_id| .{ .id = session_id },
            };
            // A refusal's reason is the launch's exit message
            // (`conversionRefusal`).
            const v2 = try session_adapter.Session.resumeSession(app.alloc, v2_store, v2_target, app.workspace_root, .app);
            try installResumedV2Session(app, agent, v2, notice);
            errdefer closeWritableSession(app, agent);
            if (notice == .upgrade) try requestUpgradeRelaunchRedraw(app);
            try app.commitStartupResumeReplayAnchor();
        }

        /// An update relaunch takes over the previous build's screen. Its
        /// first frame clears the terminal and its scrollback and draws the
        /// conversation from the top, as a resize does, instead of drawing a
        /// second copy below the old one.
        fn requestUpgradeRelaunchRedraw(app: *App) !void {
            debug_trace.logf("session", "event=upgrade_relaunch_redraw dropped=terminal_screen_and_scrollback reason=relaunched_build_redraws_conversation", .{});
            try app.shell.requestTerminalReset(&app.metrics);
        }

        fn resumeRequestedJsHostSession(app: *App, agent: *AppAgent) !void {
            return resumeRequestedJsHostSessionWithNotice(app, agent, .session);
        }

        fn resumeRequestedJsHostSessionWithNotice(
            app: *App,
            agent: *AppAgent,
            notice: ResumeNotice,
        ) !void {
            var target = app.requested_resume orelse return;
            app.requested_resume = null;
            defer target.deinit(app.alloc);

            if (target == .pick) {
                debug_trace.logf(
                    "session",
                    "event=js_host_session_restore outcome=dropped reason=picker_unsupported",
                    .{},
                );
                try continueWithFreshJsHostSession(app, agent);
                try app.writeDomainNotice(.{
                    .topic = "session",
                    .tone = .neutral,
                    .body = "session picker is unavailable in this host; use --resume last or a session ID",
                }, true);
                return;
            }

            var listed: ?[]js_host_session_store.Metadata = null;
            defer if (listed) |entries| {
                for (entries) |*entry| entry.deinit(app.alloc);
                app.alloc.free(entries);
            };
            const session_id = switch (target) {
                .pick => unreachable,
                .id => |id| id,
                .remembered, .last => latest: {
                    const entries = agent.session_persistence.js_host_store.list(app.alloc) catch |err| {
                        traceJsHostRestoreFailure("list", null, err);
                        try continueWithFreshJsHostSession(app, agent);
                        return;
                    };
                    listed = entries;
                    if (entries.len == 0) {
                        debug_trace.logf(
                            "session",
                            "event=js_host_session_restore outcome=dropped reason=missing_record target=last",
                            .{},
                        );
                        try continueWithFreshJsHostSession(app, agent);
                        return;
                    }
                    var latest_index: usize = 0;
                    for (entries[1..], 1..) |entry, index| {
                        if (entry.updated_at_ms > entries[latest_index].updated_at_ms) {
                            latest_index = index;
                        }
                    }
                    break :latest entries[latest_index].id;
                },
            };

            var loaded = (agent.session_persistence.js_host_store.load(app.alloc, session_id) catch |err| {
                traceJsHostRestoreFailure(jsHostLoadFailureStage(err), session_id, err);
                try continueWithFreshJsHostSession(app, agent);
                return;
            }) orelse {
                debug_trace.logf(
                    "session",
                    "event=js_host_session_restore outcome=dropped reason=missing_record id={s}",
                    .{session_id},
                );
                try continueWithFreshJsHostSession(app, agent);
                return;
            };
            var loaded_owned = true;
            defer if (loaded_owned) loaded.deinit(app.alloc);

            var display = session_display_metadata.deriveFromHistory(
                app.alloc,
                loaded.state.history,
            ) catch |err| {
                traceJsHostRestoreFailure("display", session_id, err);
                try continueWithFreshJsHostSession(app, agent);
                return;
            };
            defer display.deinit(app.alloc);
            hydrateResumedSession(app, agent, loaded.state, &display, notice) catch |err| {
                traceJsHostRestoreFailure("hydrate", session_id, err);
                try continueWithFreshJsHostSession(app, agent);
                return;
            };

            if (agent.session_persistence.js_host_session) |*owner| owner.deinit(app.alloc);
            agent.session_persistence.js_host_session = .{
                .state = loaded.state,
                .revision = loaded.revision,
            };
            loaded_owned = false;
            loaded = undefined;
            try app.commitStartupResumeReplayAnchor();
        }

        fn continueWithFreshJsHostSession(app: *App, agent: *AppAgent) !void {
            agent.session.reset(app.alloc);
            app.shell.clearTranscript(app.alloc);
            clearCachedSessionTitle(app, agent);
            try beginFreshJsHostSession(app, agent, null);
            try finishLiveSessionTransition(app);
        }

        fn jsHostLoadFailureStage(err: anyerror) []const u8 {
            return switch (err) {
                error.InvalidDurableField,
                error.InvalidDurableBytes,
                error.InvalidSessionFormat,
                error.InvalidSessionId,
                => "decode",
                else => "load",
            };
        }

        fn traceJsHostRestoreFailure(stage: []const u8, id: ?[]const u8, err: anyerror) void {
            if (id) |session_id| {
                debug_trace.logf(
                    "session",
                    "event=js_host_session_restore outcome=dropped stage={s} id={s} err={s}",
                    .{ stage, session_id, @errorName(err) },
                );
            } else {
                debug_trace.logf(
                    "session",
                    "event=js_host_session_restore outcome=dropped stage={s} err={s}",
                    .{ stage, @errorName(err) },
                );
            }
        }

        pub fn startResumedSessionWarmup(app: *App) void {
            if (comptime @hasDecl(App, "startModelCacheWarmup")) app.startModelCacheWarmup();
            // The subagents the session started before count at once, so the
            // footer offers the list before it is first opened.
            if (comptime @hasField(App, "child_agents")) @import("app_agents_runtime.zig").Runtime(App).listRestoredSubagents(app);
        }

        pub fn resumeSelectedSession(app: *App, agent: *AppAgent) !bool {
            const selected_id = agent.session_persistence.session_picker.selectedId() orelse return false;
            const v2_store = agent.session_persistence.v2_store orelse return false;
            // A session open in another spark shows as busy at once (D38).
            const v2 = session_adapter.Session.resumeSessionWithoutWaiting(app.alloc, v2_store, .{ .id = selected_id }, app.workspace_root, .app) catch |err| {
                noteConversionProblem(app, v2_store, err);
                return err;
            };
            var v2_owned = true;
            errdefer if (v2_owned) v2.close();
            try app.prepareLiveSessionResume(agent);
            v2_owned = false;
            try installResumedV2Session(app, agent, v2, .session);
            startResumedSessionWarmup(app);
            try app.finishLiveSessionResume();
            try noteStoppedSubagentTasks(app, agent);
            startPendingResume(app, agent);
            return true;
        }

        /// Opens `/fork`'s menu of the session's prompts, newest selected,
        /// or says why it cannot (D58).
        pub fn openForkMenu(app: *App, agent: *AppAgent) !void {
            const v2 = agent.session_persistence.v2 orelse return app.writeDomainNotice(.{
                .topic = "session",
                .tone = .warning,
                .body = "/fork needs a saved session",
            }, true);
            if (agent.stream.active) return app.writeDomainNotice(.{
                .topic = "session",
                .tone = .neutral,
                .body = "/fork is available once the current turn finishes",
            }, true);
            const points = try v2.forkPoints(app.alloc);
            if (points.len == 0) {
                session_adapter.Session.freeForkPoints(app.alloc, points);
                return app.writeDomainNotice(.{
                    .topic = "session",
                    .tone = .neutral,
                    .body = "nothing to fork yet",
                }, true);
            }
            const menu = &agent.session_persistence.fork_menu;
            menu.close(app.alloc);
            menu.* = .{ .points = points, .selected = points.len - 1 };
            app.shell.render_requests.request(.footer);
        }

        /// Enter on `/fork`'s menu, and the answer to its question (D97). On
        /// the prompts, Enter (`bring` null) asks whether the fork takes
        /// copies of the subagents the session had at the chosen prompt, or
        /// forks at once when it had none to copy. The answer forks with a
        /// copy of each of them or of none. Returns the chosen prompt's text
        /// for the composer once it forked, else null; caller owns it.
        pub fn submitForkMenu(app: *App, agent: *AppAgent, bring: ?bool) !?[]u8 {
            const menu = &agent.session_persistence.fork_menu;
            if (menu.question) |children| {
                const yes = bring orelse return null;
                if (!yes) return try forkBeforeSelectedPrompt(app, agent, &.{});
                var arena = std.heap.ArenaAllocator.init(app.alloc);
                defer arena.deinit();
                var copies: std.ArrayList(session_adapter.Session.ChildCopy) = .empty;
                for (children) |child| {
                    if (!subagent_child_state.copyableAtFork(child)) continue;
                    try copies.append(arena.allocator(), try subagent_child_state.forkCopy(arena.allocator(), child));
                }
                return try forkBeforeSelectedPrompt(app, agent, copies.items);
            }
            const source = agent.session_persistence.v2 orelse return error.SessionStoreUnavailable;
            const children = try source.forkChildren(app.alloc, menu.points[menu.selected].turn);
            if (copyableCount(children) == 0) {
                session_adapter.freeChildren(app.alloc, children);
                return try forkBeforeSelectedPrompt(app, agent, &.{});
            }
            menu.question = children;
            app.shell.render_requests.request(.footer);
            return null;
        }

        /// Forks the session before the fork menu's selected prompt, with
        /// `copies` of its subagents (D97), and switches to the fork, which
        /// opens before the source closes (D58). Returns that prompt's text
        /// for the composer; caller owns it.
        fn forkBeforeSelectedPrompt(app: *App, agent: *AppAgent, copies: []const session_adapter.Session.ChildCopy) ![]u8 {
            const menu = &agent.session_persistence.fork_menu;
            const points = menu.points;
            const point = points[menu.selected];
            // `copies` borrow the question's children until the fork is made.
            const question = menu.question;
            menu.* = .{};
            defer session_adapter.Session.freeForkPoints(app.alloc, points);
            defer if (question) |children| session_adapter.freeChildren(app.alloc, children);
            const source = agent.session_persistence.v2 orelse return error.SessionStoreUnavailable;
            const source_id = try app.alloc.dupe(u8, source.id());
            defer app.alloc.free(source_id);
            const prompt = try app.alloc.dupe(u8, point.prompt);
            errdefer app.alloc.free(prompt);
            const fork = try source.fork(app.alloc, .{
                .before_turn = point.turn,
                .workspace = app.workspace_root,
                .host = .app,
                .title = cachedSessionTitle(agent),
                .children = copies,
            });
            var fork_owned = true;
            errdefer if (fork_owned) fork.close();
            try app.prepareLiveSessionResume(agent);
            fork_owned = false;
            // The fork is committed: it keeps the source's captures from
            // retention (D98), copied off the UI thread. `copies` and the fork
            // are read here, before the install takes the fork.
            if (comptime turn_capture.supported) {
                if (agent.session_persistence.workspace_capture) agent.session_persistence.startForkCaptureCopy(app.alloc, fork.store.home, source_id, fork, copies);
            }
            try installResumedV2Session(app, agent, fork, .{ .fork = source_id });
            startResumedSessionWarmup(app);
            try app.finishLiveSessionResume();
            try noteStoppedSubagentTasks(app, agent);
            return prompt;
        }

        /// Makes `v2` the open session, taking ownership, and restores the app
        /// from it through v1's state.
        fn installResumedV2Session(app: *App, agent: *AppAgent, v2: *session_adapter.Session, notice: ResumeNotice) !void {
            var v2_owned = true;
            errdefer if (v2_owned) v2.close();
            var resumed = try v2.durableState(app.alloc, app.workspace_root);
            defer resumed.deinit(app.alloc);
            var display: session_display_metadata.DisplayMetadata = if (resumed.title) |title|
                .{ .present = true, .title = try app.alloc.dupe(u8, title) }
            else
                try session_display_metadata.deriveFromHistory(app.alloc, resumed.state.history);
            defer display.deinit(app.alloc);

            closeWritableSession(app, agent);
            agent.session_persistence.v2 = v2;
            v2_owned = false;
            errdefer closeWritableSession(app, agent);
            // Before the replay: the resume projection copies the window's
            // retention, so the whole newest cycle comes back.
            syncTranscriptWindowSaveMode(app, agent);
            try hydrateResumedSession(app, agent, resumed.state, &display, notice);
            enableSessionStores(app, agent);
            syncTranscriptArchiveAvailable(app, agent);
            // A fork is a new session: it continues nothing on its own.
            if (notice != .fork) noteInterruptedRequest(agent, v2);
        }

        /// Notes the request the newest turn left unfinished, if a crash or a
        /// close ended it (`tests/tla/recovery/Resume.tla` AutoResumes).
        fn noteInterruptedRequest(agent: *AppAgent, v2: *session_adapter.Session) void {
            agent.session_persistence.pending_request_resume = null;
            const found = (v2.interruptedRequest() catch |err| {
                debug_trace.logf("recovery", "event=resume_check_failed err={s}", .{@errorName(err)});
                return;
            }) orelse return;
            const now_ms = io_mod.milliTimestamp();
            const stale = resumeIsStale(now_ms, found.saved_ms);
            agent.session_persistence.pending_request_resume = .{ .record = found.record, .stale = stale };
            debug_trace.logf("recovery", "event=resume_pending record={} stale={} saved_ms={d} now_ms={d}", .{ found.record != null, stale, found.saved_ms, now_ms });
        }

        /// Sends the noted request again, as a turn whose prompt is spark's note
        /// to the model. The recovery module decides whether it goes at once
        /// or asks first.
        pub fn startPendingResume(app: *App, agent: *AppAgent) void {
            if (comptime !@hasDecl(App, "queueResumedRequest")) return;
            const resumed = agent.session_persistence.pending_request_resume orelse return;
            agent.session_persistence.pending_request_resume = null;
            _ = app.queueResumedRequest(agent, session_runtime.resumed_request_prompt, resumed) catch |err| {
                debug_trace.logf("recovery", "event=resume_dropped reason=queue_failed err={s}", .{@errorName(err)});
            };
        }

        /// `AgentRuntimeDeps.save_recovery_record` on v2.
        pub fn saveRecoveryRecord(agent: *AppAgent, record: types.RecoveryRecordWrite) !bool {
            agent.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer agent.session_persistence.write_mutex.unlock(io_mod.getIo());
            const v2 = agent.session_persistence.v2 orelse return false;
            return v2.saveRecovery(record);
        }

        /// Saves the row of a call a command made through `spark mcp call` in
        /// the open turn, so a resume shows it in its shell call's group
        /// (D99). A session that is not saved keeps nothing.
        pub fn saveBridgeCall(agent: *AppAgent, record: types.BridgeCallRecord) !void {
            agent.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer agent.session_persistence.write_mutex.unlock(io_mod.getIo());
            const v2 = agent.session_persistence.v2 orelse return;
            try v2.saveBridgeCall(record);
        }

        /// Record whether restored history references shell execution handles
        /// this process does not own. Registry membership, not the resume
        /// itself, decides staleness (see session_runtime.detectStaleShellHandles).
        fn updateStaleShellHandles(app: *App, agent: *AppAgent, history: []const session_runtime.HistoryTurn) void {
            if (comptime !agents.hasAgentField(App, "managed_executions")) return;
            agent.session.has_stale_shell_handles = session_runtime.detectStaleShellHandles(
                app.alloc,
                history,
                &agent.managed_executions,
            ) catch |err| blk: {
                debug_trace.logf(
                    "session",
                    "event=stale_shell_handle_scan outcome=skipped err={s}",
                    .{@errorName(err)},
                );
                break :blk false;
            };
        }

        /// `attachChildSession` for a v2 subagent session.
        pub fn attachChildV2Session(app: *App, agent: *AppAgent, v2: *session_adapter.Session) !void {
            var v2_owned = true;
            errdefer if (v2_owned) v2.close();
            var resumed = try v2.durableState(app.alloc, app.workspace_root);
            defer resumed.deinit(app.alloc);
            agent.session_persistence.v2 = v2;
            // A subagent captures its own turns as the first agent does (D98).
            agent.session_persistence.workspace_capture = app.main_agent.session_persistence.workspace_capture;
            v2_owned = false;
            errdefer {
                agent.session_persistence.v2 = null;
                v2.close();
            }
            try restoreChildState(app, agent, resumed.state);
            if (resumed.title) |title| if (cachedSessionTitle(agent) == null) try setCachedSessionTitle(app, agent, title);
            if (comptime @hasDecl(@TypeOf(agent.session), "configureWebFetchArtifactBlobs")) {
                if (v2.childCapability()) |capability| {
                    agent.session.configureWebFetchArtifactBlobs(app.alloc, capability, v2.id());
                } else |err| {
                    debug_trace.logf("session", "event=child_web_fetch_store_unavailable session={s} err={s}", .{ v2.id(), @errorName(err) });
                    agent.session.clearWebFetchArtifacts();
                }
            }
            // Its own subagents' state lives in its own log, as main's does.
            enableSubagentHostV2(app, agent, v2);
        }

        /// The session-state half of `hydrateResumedSession`, for a subagent.
        fn restoreChildState(app: *App, agent: *AppAgent, state: session_codec.DurableSessionState) !void {
            if (comptime agents.hasAgentField(App, "next_image_id")) {
                agent.next_image_id = try nextImageIdForResume(app.alloc, state.history);
            }
            try agent.session.restore(
                app.alloc,
                state.conversation_language,
                state.history,
            );
            updateStaleShellHandles(app, agent, state.history);
            try replacePreferences(
                app.alloc,
                &agent.session_persistence.session_preferences,
                state.preferences,
            );
            agent.effort = state.preferences.effort;
            // Its own fast mode from its saved preferences, which started from
            // main's. The child is in context, so this is its own slot.
            if (comptime @hasField(App, "fast_mode")) {
                app.fast_mode = state.preferences.fast_mode;
                agent.worker.syncQueuedPromptFastMode(state.preferences.fast_mode);
            }
            agents.storeTotal(&agent.total_input_tokens, state.total_input_tokens);
            agents.storeTotal(&agent.total_output_tokens, state.total_output_tokens);
            agents.storeTotal(&agent.total_web_search_requests, 0);
        }

        fn hydrateResumedSession(
            app: *App,
            agent: *AppAgent,
            loaded_state: session_codec.DurableSessionState,
            display: *const session_display_metadata.DisplayMetadata,
            notice: ResumeNotice,
        ) !void {
            const state = loaded_state;
            const previous_provider = provider_runtime.providerOf(app, agent);
            if (comptime agents.hasAgentField(App, "next_image_id")) {
                agent.next_image_id = try nextImageIdForResume(app.alloc, state.history);
            }
            try agent.session.restore(
                app.alloc,
                state.conversation_language,
                state.history,
            );
            updateStaleShellHandles(app, agent, state.history);
            try replacePreferences(
                app.alloc,
                &agent.session_persistence.session_preferences,
                state.preferences,
            );
            try restoreRuntimePreferences(app, agent, state.preferences);

            agents.storeTotal(&agent.total_input_tokens, state.total_input_tokens);
            agents.storeTotal(&agent.total_output_tokens, state.total_output_tokens);
            agents.storeTotal(&agent.total_web_search_requests, 0);

            var historical_labels = HistoricalSessionLabels{ .workspace_root = app.workspace_root };
            defer historical_labels.deinit(app.alloc);

            if (comptime @hasDecl(App, "beginResumeProjection")) {
                const projection_started_ns = io_mod.nanoTimestamp();
                var projection = try app.beginResumeProjection(agent);
                defer projection.deinit();
                var sink = DetachedHistorySink(@TypeOf(projection)){
                    .app = app,
                    .projection = &projection,
                    .labels = &historical_labels,
                };
                const holds_previous = try replayWithResumeNotice(app, agent, &sink, display, notice, state.history, &historical_labels);
                const projection_finished_ns = io_mod.nanoTimestamp();
                try projection.finalize();
                const finalization_finished_ns = io_mod.nanoTimestamp();
                try app.installResumeProjection(agent, &projection, holds_previous);
                const install_finished_ns = io_mod.nanoTimestamp();
                debug_trace.logf(
                    "session",
                    "event=resume_projection turns={d} project_us={d} finalize_us={d} install_us={d}",
                    .{
                        state.history.len,
                        @divTrunc(projection_finished_ns - projection_started_ns, std.time.ns_per_us),
                        @divTrunc(finalization_finished_ns - projection_finished_ns, std.time.ns_per_us),
                        @divTrunc(install_finished_ns - finalization_finished_ns, std.time.ns_per_us),
                    },
                );
            } else {
                var sink = LiveHistorySink(App){ .app = app };
                _ = try replayWithResumeNotice(app, agent, &sink, display, notice, state.history, &historical_labels);
            }
            if (comptime @hasDecl(App, "restoreSessionCredential")) {
                try app.restoreSessionCredential(previous_provider);
            }
        }

        /// The picker lists from the backend this process runs on.
        fn pickerSource(app: *App, agent: *AppAgent) ?SessionPickerLoad.Source {
            if (agent.session_persistence.v2_store) |store| {
                return .{ .store = store, .workspace_root = app.workspace_root };
            }
            return null;
        }

        /// The open session, which the picker leaves out.
        fn pickerActiveId(agent: *AppAgent) ?[]const u8 {
            return if (agent.session_persistence.v2) |v2| v2.id() else null;
        }

        pub fn openSessionPicker(app: *App, agent: *AppAgent) !void {
            return openSessionPickerWithScope(app, agent, .current_workspace);
        }

        pub fn openAllSessionPicker(app: *App, agent: *AppAgent) !void {
            return openSessionPickerWithScope(app, agent, .all_workspaces);
        }

        fn openSessionPickerWithScope(app: *App, agent: *AppAgent, scope: SessionPickerScope) !void {
            if (agent.stream.active) {
                try app.writeDomainNotice(.{
                    .topic = "session",
                    .tone = .neutral,
                    .body = "resume is unavailable until the response finishes",
                }, true);
                return;
            }
            try listSessionPicker(app, agent, scope);
        }

        /// Re-lists the open picker for the composer's current text, so the
        /// search covers every saved session in scope, not only loaded pages.
        pub fn searchSessionPicker(app: *App, agent: *AppAgent) !void {
            const picker = &agent.session_persistence.session_picker;
            if (!picker.active) return;
            // A listing still in flight applies the query when it lands.
            if (picker.load_state != .ready) {
                picker.setQuery(app.input_runtime.edit_state.input.items);
                return;
            }
            listSessionPicker(app, agent, picker.scope) catch |err| {
                picker.load_state = .failed;
                return err;
            };
        }

        /// Lists the first page for `scope` and the composer's text from the
        /// held catalog, refreshing a stale or missing catalog in the background.
        fn listSessionPicker(app: *App, agent: *AppAgent, scope: SessionPickerScope) !void {
            var picker = &agent.session_persistence.session_picker;
            const previous_generation = picker.generation;
            picker.deinit(app.alloc);
            picker.active = true;
            picker.load_state = .loading;
            picker.scope = scope;
            picker.setQuery(app.input_runtime.edit_state.input.items);
            const source = pickerSource(app, agent) orelse {
                picker.load_state = .failed;
                try writeSessionPickerError(app, error.SessionStoreUnavailable);
                app.shell.render_requests.request(.footer);
                return;
            };
            const active_id = pickerActiveId(agent);
            const limit = if (comptime @hasField(App, "shell"))
                resumePageLimitForRows(app.shell.layout.rows)
            else
                session_store.default_resume_page_limit;
            const loader = &agent.session_persistence.session_picker_load;
            const matching = loader.matchingInitialGeneration(active_id);
            if (matching != previous_generation) loader.cancelGeneration(previous_generation);
            const cache = &agent.session_persistence.session_picker_cache;
            var cache_visible = false;
            if (cache.matches(active_id)) {
                try applySessionPickerCatalogPage(
                    picker,
                    app.alloc,
                    cache,
                    source.workspace_root,
                    null,
                    limit,
                    false,
                );
                cache_visible = true;
                if (cache.isFresh()) {
                    picker.generation = agent.session_persistence.session_picker_load.allocateGeneration();
                    return;
                }
            }

            if (matching) |generation| {
                picker.generation = generation;
                return;
            }
            const request = SessionPickerLoad.PageRequest.init(
                loader.allocateGeneration(),
                active_id,
            ) catch |err| {
                if (!cache_visible) picker.load_state = .failed;
                try writeSessionPickerError(app, err);
                return;
            };
            picker.generation = request.generation;
            loader.schedule(source, request) catch |err| {
                if (!cache_visible) picker.load_state = .failed;
                try writeSessionPickerError(app, err);
                return;
            };
        }

        pub fn toggleSessionPickerScope(app: *App, agent: *AppAgent) !bool {
            const picker = &agent.session_persistence.session_picker;
            if (!picker.active) return false;
            const next: SessionPickerScope = switch (picker.scope) {
                .current_workspace => .all_workspaces,
                .all_workspaces => .current_workspace,
            };
            try openSessionPickerWithScope(app, agent, next);
            return true;
        }

        pub fn pollSessionPicker(app: *App, agent: *AppAgent) !void {
            const loader = &agent.session_persistence.session_picker_load;
            const task = loader.takeCompleted() orelse return;
            var task_owned = true;
            defer if (task_owned) task.deinit();

            const active_id = pickerActiveId(agent);
            const valid = pickerSource(app, agent) != null and
                !task.abandoned and optionalStringEql(task.request.active_id, active_id);
            var cache_installed = false;
            if (valid and task.failure == null) {
                if (task.catalog) |*catalog| {
                    const cache = &agent.session_persistence.session_picker_cache;
                    cache.install(catalog, task.request.active_id) catch |err| {
                        task.failure = err;
                    };
                    cache_installed = task.failure == null;
                }
            }

            const picker = &agent.session_persistence.session_picker;
            const current = valid and picker.active and picker.generation == task.request.generation;
            if (!current) {
                debug_trace.logf(
                    "core",
                    "session picker completion {s} generation={d}",
                    .{
                        if (cache_installed) "cached" else "dropped",
                        task.request.generation,
                    },
                );
            } else if (task.failure) |err| {
                if (picker.load_state != .ready) picker.load_state = .failed;
                try writeSessionPickerError(app, err);
            } else {
                const cache = &agent.session_persistence.session_picker_cache;
                const limit = if (comptime @hasField(App, "shell"))
                    resumePageLimitForRows(app.shell.layout.rows)
                else
                    session_store.default_resume_page_limit;
                applySessionPickerCatalogPage(
                    picker,
                    app.alloc,
                    cache,
                    pickerSource(app, agent).?.workspace_root,
                    null,
                    limit,
                    false,
                ) catch |err| {
                    picker.load_state = .failed;
                    try writeSessionPickerError(app, err);
                };
            }

            task.deinit();
            task_owned = false;

            const source = pickerSource(app, agent) orelse return;
            const pending_generation = loader.pendingGeneration();
            _ = loader.startPending(source) catch |err| {
                if (pending_generation) |generation| {
                    if (picker.active and picker.generation == generation) {
                        if (picker.loading_more) {
                            picker.loading_more = false;
                        } else {
                            picker.load_state = .failed;
                        }
                        try writeSessionPickerError(app, err);
                    }
                }
                return;
            };
            if (comptime @hasField(App, "shell")) {
                if (picker.active) app.shell.render_requests.request(.footer);
            }
        }

        fn writeSessionPickerError(app: *App, err: anyerror) !void {
            const notice = try app.alloc.print(
                "unable to list saved sessions: {s}",
                .{@errorName(err)},
            );
            defer app.alloc.free(notice);
            try app.writeDomainNotice(.{
                .topic = "session",
                .tone = .@"error",
                .body = notice,
            }, true);
        }

        pub fn loadMoreSessionPicker(app: *App, agent: *AppAgent) !bool {
            const picker = &agent.session_persistence.session_picker;
            if (!picker.isLoadMoreSelected()) return false;
            if (picker.loading_more) return true;
            try scheduleMoreSessions(app, agent);
            return true;
        }

        fn scheduleMoreSessions(app: *App, agent: *AppAgent) !void {
            const picker = &agent.session_persistence.session_picker;
            const continuation = picker.continuation orelse
                return error.SessionStoreUnavailable;
            const source = pickerSource(app, agent) orelse return error.SessionStoreUnavailable;
            const active_id = pickerActiveId(agent);
            const cache = &agent.session_persistence.session_picker_cache;
            if (!cache.matches(active_id)) return error.SessionStoreUnavailable;
            const limit = if (comptime @hasField(App, "shell"))
                resumePageLimitForRows(app.shell.layout.rows)
            else
                session_store.default_resume_page_limit;

            picker.loading_more = true;
            applySessionPickerCatalogPage(
                picker,
                app.alloc,
                cache,
                source.workspace_root,
                continuation.view(),
                limit,
                true,
            ) catch |err| {
                picker.loading_more = false;
                return err;
            };
            try input_completion_runtime.CompletionRuntime(App).syncSessionPickerWindowStart(app, agent);
            if (comptime @hasField(App, "shell")) {
                app.shell.render_requests.request(.footer);
            }
        }

        // Prefetch the next page as the selection reaches the last loaded
        // session (or the load-more slot), so scrolling down fills the list in
        // without stopping to activate "Load more".
        fn maybePrefetchMoreSessions(app: *App, agent: *AppAgent) void {
            const picker = &agent.session_persistence.session_picker;
            if (!picker.active or picker.load_state != .ready) return;
            if (!picker.has_more or picker.loading_more) return;
            if (picker.summaries.items.len == 0) return;
            if (picker.selected + 1 < picker.filteredItemCount()) return;
            scheduleMoreSessions(app, agent) catch |err| {
                debug_trace.logf(
                    "core",
                    "session picker prefetch failed err={s}",
                    .{@errorName(err)},
                );
            };
        }

        pub fn cancelSessionPicker(app: *App, agent: *AppAgent) void {
            const picker = &agent.session_persistence.session_picker;
            const loader = &agent.session_persistence.session_picker_load;
            if (loader.task) |task| loader.cancelGeneration(task.request.generation);
            if (loader.pending) |pending| loader.cancelGeneration(pending.generation);
            picker.deinit(app.alloc);
        }

        pub fn cancelSessionPickerToComposer(app: *App, agent: *AppAgent) void {
            cancelSessionPicker(app, agent);
            if (comptime !agents.hasAgentField(App, "session")) return;
            if (agent.session_persistence.v2 != null) return;
            // With no session yet, this is the one the instance opens with.
            beginInstanceSession(app, agent) catch |err| {
                debug_trace.logf(
                    "session",
                    "fresh session after picker cancel unavailable err={s}",
                    .{@errorName(err)},
                );
                return;
            };
            enableSessionStores(app, agent);
        }

        fn invalidateSessionPickerCaches(agent: *AppAgent) void {
            const loader = &agent.session_persistence.session_picker_load;
            if (loader.task) |task| loader.cancelGeneration(task.request.generation);
            if (loader.pending) |pending| loader.cancelGeneration(pending.generation);
            agent.session_persistence.session_picker_cache.deinit();
        }

        pub fn moveSessionPicker(app: *App, agent: *AppAgent, delta: i32, visible_items: u16) bool {
            const moved = agent.session_persistence.session_picker.moveVisibleItems(delta, visible_items);
            maybePrefetchMoreSessions(app, agent);
            return moved;
        }

        pub fn recordToolTerminal(
            app: *App,
            agent: *AppAgent,
            event: types.ToolLifecycleEvent,
            captured_command_call: bool,
        ) void {
            const terminal = switch (event) {
                .terminal => |value| value,
                .provisional, .authoritative_started, .progress, .turn_finished => return,
            };
            if (!captured_command_call) {
                discardPendingCancelledCommand(app, agent, terminal.id, "non_command_terminal");
                return;
            }
            if (terminal.outcome.kind != .cancelled) {
                discardPendingCancelledCommand(app, agent, terminal.id, "ordinary_command_terminal");
                return;
            }
            const pending = ensurePendingCancelledCommand(app, agent, terminal.id) orelse return;
            if (pending.command_artifact_handle) |handle| {
                app.alloc.free(handle);
                pending.command_artifact_handle = null;
            }
            if (terminal.command_artifact_handle) |handle| {
                pending.command_artifact_handle = app.alloc.dupe(u8, handle) catch |err| {
                    debug_trace.logf(
                        "session",
                        "cancelled command artifact capture unavailable call_id={s} err={s}",
                        .{ terminal.id.call_id, @errorName(err) },
                    );
                    return;
                };
            }
        }

        pub fn appendHistoryTurn(app: *App, agent: *AppAgent, turn: types.HistoryTurn) !void {
            _ = try appendHistoryTurnWithPendingPresentation(app, agent, turn, .strict, null, 0);
        }

        /// Tells the agent's worker that a finished turn is committed, or
        /// failed to commit, so mail held for it may start the next turn
        /// (`WorkerRuntime.acknowledgeFinishCommitted`). `committed` is the turn
        /// added to the agent's history, null when there was none: the worker
        /// adds it to mail that was posted after the turn finished and before
        /// this commit (`WorkerRuntime.acknowledgeFinishCommittedTurn`).
        fn acknowledgeFinishCommitted(
            agent: *AppAgent,
            committed: ?types.HistoryTurn,
            ownership: ?types.SnapshotFileOwnership,
        ) void {
            if (comptime @hasField(AppAgent, "worker") and
                @hasDecl(@TypeOf(agent.worker), "acknowledgeFinishCommitted"))
            {
                if (comptime @hasDecl(@TypeOf(agent.worker), "acknowledgeFinishCommittedTurn")) {
                    if (committed) |turn| {
                        // The worker's queue is allocated with `c_allocator`, by
                        // `postAgentMessage` and by the worker threads, so the
                        // turn is added with the same allocator.
                        agent.worker.acknowledgeFinishCommittedTurn(std.heap.c_allocator, turn, ownership, agent.session.max_history_turns);
                        return;
                    }
                }
                agent.worker.acknowledgeFinishCommitted();
            }
        }

        pub fn appendFinishedPrompt(
            app: *App,
            agent: *AppAgent,
            finished: types.FinishedPrompt,
        ) !void {
            var committed: ?types.HistoryTurn = null;
            defer acknowledgeFinishCommitted(agent, committed, finished.snapshot_file_ownership);
            var turn = finished.turn;
            if (finished.summary) |summary| {
                types.setHistoryTurnSummary(&turn, summary);
            }
            if (try appendHistoryTurnWithPendingPresentation(
                app,
                agent,
                turn,
                .finished_prompt,
                finished.snapshot_file_ownership,
                finished.capture_turn,
            ) == .committed) committed = turn;
            if (comptime agents.hasAgentField(App, "child_run")) {
                @import("app_agents_runtime.zig").Runtime(App).commitChildTurn(app, agent, finished);
            }
        }

        pub fn appendHistoryTurnForVisualEpoch(
            app: *App,
            agent: *AppAgent,
            turn: types.HistoryTurn,
        ) !HistoryAppendOutcome {
            return appendHistoryTurnWithPendingPresentation(
                app,
                agent,
                turn,
                .visual_epoch,
                null,
                0,
            );
        }

        pub fn appendFinishedPromptForVisualEpoch(
            app: *App,
            agent: *AppAgent,
            finished: types.FinishedPrompt,
        ) !HistoryAppendOutcome {
            const outcome = try appendHistoryTurnWithPendingPresentation(
                app,
                agent,
                finished.turn,
                .visual_epoch,
                finished.snapshot_file_ownership,
                finished.capture_turn,
            );
            // An uncommitted turn stays with the pacer, which commits it later
            // through `appendFinishedPrompt`.
            if (outcome == .committed) {
                acknowledgeFinishCommitted(agent, finished.turn, finished.snapshot_file_ownership);
            }
            return outcome;
        }

        const AppendHistoryMode = enum {
            strict,
            visual_epoch,
            /// A rendered, user-visible finished turn. A validation or commit
            /// failure must not take the session down: commit in memory, warn,
            /// and keep the process alive.
            finished_prompt,
        };

        fn appendHistoryTurnWithPendingPresentation(
            app: *App,
            agent: *AppAgent,
            turn: types.HistoryTurn,
            mode: AppendHistoryMode,
            snapshot_file_ownership: ?types.SnapshotFileOwnership,
            /// The turn's workspace capture token from its finished prompt
            /// (`types.FinishedPrompt.capture_turn`); 0 commits no captures.
            capture_turn: u64,
        ) !HistoryAppendOutcome {
            if (comptime !agents.hasAgentField(App, "session_persistence")) {
                return appendHistoryTurnWithOutcome(app, agent, turn, mode, snapshot_file_ownership, capture_turn);
            }
            const interrupted = switch (turn) {
                .interrupted => |entry| entry,
                else => return appendHistoryTurnWithOutcome(app, agent, turn, mode, snapshot_file_ownership, capture_turn),
            };
            var pending = agent.session_persistence.pending_cancelled_command orelse {
                return appendHistoryTurnWithOutcome(app, agent, turn, mode, snapshot_file_ownership, capture_turn);
            };
            agent.session_persistence.pending_cancelled_command = null;
            const call = interrupted.tool_call orelse {
                pending.discard(app.alloc);
                return appendHistoryTurnWithOutcome(app, agent, turn, mode, snapshot_file_ownership, capture_turn);
            };
            const is_command = try captured_command.isToolCall(
                app.alloc,
                call.name,
                call.arguments_json,
            );
            if (!is_command or
                !std.mem.eql(u8, call.id, pending.lifecycle_id.call_id))
            {
                pending.discard(app.alloc);
                return appendHistoryTurnWithOutcome(app, agent, turn, mode, snapshot_file_ownership, capture_turn);
            }
            defer pending.discard(app.alloc);

            if (interrupted.cancelled_command) |authoritative| {
                var enriched_presentation = authoritative;
                if (enriched_presentation.command_artifact_handle == null) {
                    enriched_presentation.command_artifact_handle =
                        pending.command_artifact_handle;
                }
                var enriched_interrupted = interrupted;
                enriched_interrupted.cancelled_command = enriched_presentation;
                return appendHistoryTurnWithOutcome(
                    app,
                    agent,
                    .{ .interrupted = enriched_interrupted },
                    mode,
                    snapshot_file_ownership,
                    capture_turn,
                );
            }

            var enriched_interrupted = interrupted;
            enriched_interrupted.cancelled_command = .{
                .command_artifact_handle = pending.command_artifact_handle,
            };
            const enriched: types.HistoryTurn = .{ .interrupted = enriched_interrupted };
            return appendHistoryTurnWithOutcome(app, agent, enriched, mode, snapshot_file_ownership, capture_turn);
        }

        fn ensurePendingCancelledCommand(
            app: *App,
            agent: *AppAgent,
            id: types.ToolLifecycleId,
        ) ?*PendingCancelledCommand {
            if (agent.session_persistence.pending_cancelled_command) |*pending| {
                if (pending.matches(id)) return pending;
                discardAnyPendingCancelledCommand(app, agent, "lifecycle_replaced");
            }

            const call_id = app.alloc.dupe(u8, id.call_id) catch |err| {
                debug_trace.logf(
                    "session",
                    "cancelled command metadata identity unavailable call_id={s} err={s}",
                    .{ id.call_id, @errorName(err) },
                );
                return null;
            };
            agent.session_persistence.pending_cancelled_command = .{
                .lifecycle_id = .{
                    .turn_id = id.turn_id,
                    .call_id = call_id,
                },
            };
            return &agent.session_persistence.pending_cancelled_command.?;
        }

        fn discardPendingCancelledCommand(
            app: *App,
            agent: *AppAgent,
            id: types.ToolLifecycleId,
            reason: []const u8,
        ) void {
            const pending = if (agent.session_persistence.pending_cancelled_command) |*value|
                value
            else
                return;
            if (!pending.matches(id)) return;
            discardAnyPendingCancelledCommand(app, agent, reason);
        }

        fn discardAnyPendingCancelledCommand(app: *App, agent: *AppAgent, reason: []const u8) void {
            const pending = if (agent.session_persistence.pending_cancelled_command) |*value|
                value
            else
                return;
            debug_trace.logf(
                "session",
                "cancelled command metadata discarded call_id={s} reason={s}",
                .{ pending.lifecycle_id.call_id, reason },
            );
            pending.discard(app.alloc);
            agent.session_persistence.pending_cancelled_command = null;
        }

        fn appendHistoryTurnWithOutcome(
            app: *App,
            agent: *AppAgent,
            turn: types.HistoryTurn,
            mode: AppendHistoryMode,
            snapshot_file_ownership: ?types.SnapshotFileOwnership,
            capture_turn: u64,
        ) !HistoryAppendOutcome {
            var prepared = (if (comptime @hasDecl(@TypeOf(agent.session), "prepareHistoryEntry"))
                agent.session.prepareHistoryEntry(app.alloc, turn)
            else
                types.dupeHistoryTurn(app.alloc, turn)) catch |err| {
                return switch (mode) {
                    // In-memory preparation failure (out of memory) cannot be
                    // degraded: the in-memory commit needs the prepared copy.
                    .strict, .finished_prompt => err,
                    .visual_epoch => .uncommitted,
                };
            };
            var prepared_owned = true;
            defer if (prepared_owned) types.freeHistoryTurn(app.alloc, prepared);
            if (comptime !agents.hasAgentField(App, "session_persistence")) {
                if (comptime @hasDecl(@TypeOf(agent.session), "commitPreparedHistoryEntry")) {
                    agent.session.commitPreparedHistoryEntry(app.alloc, prepared);
                    prepared_owned = false;
                } else {
                    try agent.session.appendHistoryEntry(app.alloc, prepared);
                }
                if (snapshot_file_ownership) |ownership| ownership.transfer();
                ensureCachedSessionTitle(app, agent) catch {};
                commitJsHostSnapshot(app, agent, "history_turn");
                return .committed;
            }
            // The turn's end capture was taken on its worker as the turn
            // finished (`endWorkspaceCapture`); this commit, which may run on
            // the UI thread, only writes what is held, and a retry reuses it.
            agent.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            if (agent.session_persistence.v2) |v2| {
                defer agent.session_persistence.write_mutex.unlock(io_mod.getIo());
                if (try commitV2HistoryTurn(app, agent, v2, &prepared, mode, capture_turn)) |outcome| return outcome;
                if (comptime @hasDecl(@TypeOf(agent.session), "commitPreparedHistoryEntry")) {
                    agent.session.commitPreparedHistoryEntry(app.alloc, prepared);
                    prepared_owned = false;
                } else {
                    try agent.session.appendHistoryEntry(app.alloc, prepared);
                }
                if (snapshot_file_ownership) |ownership| ownership.transfer();
                ensureCachedSessionTitle(app, agent) catch {};
                return .committed;
            }
            agent.session_persistence.write_mutex.unlock(io_mod.getIo());
            if (comptime @hasDecl(@TypeOf(agent.session), "commitPreparedHistoryEntry")) {
                agent.session.commitPreparedHistoryEntry(app.alloc, prepared);
                prepared_owned = false;
            } else {
                try agent.session.appendHistoryEntry(app.alloc, prepared);
            }
            if (snapshot_file_ownership) |ownership| ownership.transfer();
            ensureCachedSessionTitle(app, agent) catch {};
            commitJsHostSnapshot(app, agent, "history_turn");
            return .committed;
        }

        /// Saves a finished turn to v2 with v1's failure modes. Null means the
        /// caller commits the turn in memory: it was saved, or its failure
        /// was recorded and shown.
        fn commitV2HistoryTurn(
            app: *App,
            agent: *AppAgent,
            v2: *session_adapter.Session,
            prepared: *types.HistoryTurn,
            mode: AppendHistoryMode,
            capture_turn: u64,
        ) !?HistoryAppendOutcome {
            const failure: anyerror = saved: {
                v2.prepareTurn(prepared) catch |err| break :saved err;
                const captures = &agent.session_persistence.turn_capture;
                // The token the turn's finished prompt carried, never one
                // asked of `captures`: a turn the UI commits late must not
                // take a later turn's captures (D98). The session writes
                // none when it no longer holds this token's.
                const capture_token: ?session_adapter.Session.CaptureTurn = if (capture_turn != 0) @fromBackingInt(capture_turn) else null;
                if (comptime turn_capture.supported) {
                    if (agent.session_persistence.workspace_capture) debug_trace.logf("workspace", "event=workspace_capture_commit session={s} held={} thread={d}", .{ v2.id(), capture_token != null, std.Thread.getCurrentId() });
                }
                const committed = if (capture_token) |token|
                    v2.commitTurnWithCaptures(prepared.*, agent.session.languageSnapshot(), token)
                else
                    v2.commitTurn(prepared.*, agent.session.languageSnapshot());
                committed catch |err| break :saved err;
                captures.committed(capture_token);
                return null;
            };
            switch (mode) {
                .strict => return failure,
                .visual_epoch => {
                    debug_trace.logf("session", "visual epoch history not committed err={s}", .{@errorName(failure)});
                    return .uncommitted;
                },
                .finished_prompt => {
                    recordShutdownFailure(agent, failure);
                    if (comptime @hasDecl(App, "writeDomainNotice")) {
                        var plain_buf: [96]u8 = undefined;
                        const body = try app.alloc.print(
                            "Couldn't save this turn: {s}. It may be missing when you reopen this session.",
                            .{types.plainErrorText(@errorName(failure), &plain_buf)},
                        );
                        defer app.alloc.free(body);
                        app.writeDomainNotice(.{ .topic = "session", .tone = .@"error", .body = body }, true) catch {};
                    }
                    return null;
                },
            }
        }

        /// `AgentRuntimeDeps.append_turn_piece` on v2: the pieces finished so
        /// far reach the log before the next request (D12).
        pub fn appendTurnPiece(agent: *AppAgent, progress: agent_runtime.TurnProgress) !void {
            agent.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer agent.session_persistence.write_mutex.unlock(io_mod.getIo());
            const v2 = agent.session_persistence.v2 orelse return;
            try v2.appendProgressWithRecord(progress.user, progress.execution, .{ .calls = progress.running_calls, .assistant = progress.running_assistant }, progress.recovery_record);
        }

        /// `AgentRuntimeDeps.record_usage` on v2: each reply's usage
        /// reaches the log as it arrives (D92).
        pub fn recordUsage(agent: *AppAgent, usage: types.Usage) !void {
            agent.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer agent.session_persistence.write_mutex.unlock(io_mod.getIo());
            const v2 = agent.session_persistence.v2 orelse return;
            try v2.recordUsage(usage);
        }

        /// What a workspace capture of `agent`'s session needs, or null when
        /// captures are off or the session is not saved.
        fn workspaceCaptureContext(app: *App, agent: *AppAgent) ?turn_capture.Context {
            if (comptime !@hasField(App, "workspace_root")) return null;
            const persistence = &agent.session_persistence;
            if (!persistence.workspace_capture) return null;
            const v2 = persistence.v2 orelse return null;
            // The session's own store: a subagent's agent has no `v2_store`.
            return .{ .session = v2, .home = v2.store.home, .path = app.workspace_root, .alloc = std.heap.c_allocator, .cancel = captureCancelFlag(agent) };
        }

        /// The flag that ends `agent`'s workspace captures early: set by a
        /// cancel that stops its turn, never by a steer or a subagent's report
        /// that only interrupts the model (`WorkerRuntime.turn_cancel_requested`).
        fn captureCancelFlag(agent: *AppAgent) ?*const std.atomic.Value(bool) {
            if (comptime !@hasField(AppAgent, "worker") or !@hasField(@FieldType(AppAgent, "worker"), "turn_cancel_requested")) return null;
            return &agent.worker.turn_cancel_requested;
        }

        /// `AgentRuntimeDeps.reach_workspace` on v2 (D98).
        pub fn reachWorkspace(app: *App, agent: *AppAgent, dir: []const u8, tool_name: []const u8) void {
            const context = workspaceCaptureContext(app, agent) orelse return;
            agent.session_persistence.turn_capture.reach(context, dir, tool_name, &agent.session_persistence.write_mutex);
        }

        /// `AgentRuntimeDeps.start_workspace_capture` on v2 (D98).
        pub fn startWorkspaceCapture(app: *App, agent: *AppAgent, fresh: bool, step: agent_runtime.AgentRuntimeDeps.WorkspaceCaptureStep) void {
            const context = workspaceCaptureContext(app, agent) orelse return;
            const captures = &agent.session_persistence.turn_capture;
            switch (step) {
                .begin => captures.begin(context, fresh),
                .capture => captures.start(context, &agent.session_persistence.write_mutex),
            }
        }

        /// The repository as the turn left it, taken on the agent's worker
        /// as its turn finishes and before the finished prompt reaches the
        /// UI, whose commit writes it (D98). Returns the turn's token, which
        /// the finished prompt carries to that commit; null when captures
        /// are off. A capture can take seconds, so it never runs on the UI
        /// thread.
        pub fn endWorkspaceCapture(app: *App, agent: *AppAgent) ?session_adapter.Session.CaptureTurn {
            if (comptime !turn_capture.supported) return null;
            const context = workspaceCaptureContext(app, agent) orelse return null;
            return agent.session_persistence.turn_capture.end(context, &agent.session_persistence.write_mutex);
        }

        /// `AgentRuntimeDeps.save_prompt_images` on v2: the prompt's images
        /// become the session's blobs before its first request (D89).
        pub fn savePromptImages(agent: *AppAgent, alloc: std.mem.Allocator, images: []types.ImageAttachment) !void {
            agent.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer agent.session_persistence.write_mutex.unlock(io_mod.getIo());
            const v2 = agent.session_persistence.v2 orelse return;
            try v2.savePromptImages(alloc, images);
        }

        pub fn commitRuntimePreferences(
            app: *App,
            agent: *AppAgent,
            patch: SessionPreferencePatch,
        ) PreferenceCommitResult {
            var result = PreferenceCommitResult{};
            applySessionPreferencePatch(app, agent, patch) catch |err| {
                result.session_error = err;
            };
            if (patch.model != null or patch.fast_mode != null) {
                agent.session_persistence.fast_mode_model_bound =
                    patch.model != null and patch.fast_mode != null;
            }

            var settings_attempt = config_runtime.attemptUserPreferences(
                app.alloc,
                patch.userSettingsPatch(),
            );
            switch (settings_attempt) {
                .outcome => |outcome| {
                    result.settings_outcome = outcome;
                    settings_attempt = undefined;
                },
                .failure => |failure| {
                    result.settings_error = failure.err;
                    result.settings_failure_cleanup = failure.cleanup;
                    settings_attempt = undefined;
                },
            }
            // A subagent keeps no workspace seed for new sessions: its
            // preferences live in its own session alone.
            const subagent = if (comptime @hasField(App, "screen_owner")) agent.role == .subagent else false;
            if (result.settings_error == null and !subagent) {
                applyPreferencePatch(
                    app.alloc,
                    &agent.session_persistence.workspace_preferences,
                    patch,
                ) catch |err| {
                    result.session_error = err;
                };
            }

            if (result.session_error == null) {
                commitJsHostSnapshot(app, agent, "preferences");
            }

            agent.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer agent.session_persistence.write_mutex.unlock(io_mod.getIo());
            if (agent.session_persistence.v2) |v2| {
                if (result.session_error != null) return result;
                const preferences = agent.session_persistence.session_preferences orelse return result;
                // An instance launched after the first runs the --model or
                // SPARK_MODEL model in its preferences; the session keeps its own
                // unless this change picked one.
                var without_run_model: ?session_codec.DurableSessionPreferences = null;
                defer if (without_run_model) |*value| value.deinit(app.alloc);
                if (patch.model == null and runsProcessModel(app, agent)) {
                    without_run_model = withSavedModel(app.alloc, v2, preferences) catch |err| {
                        result.session_error = err;
                        warnDegraded(app, agent, err) catch {};
                        return result;
                    };
                }
                v2.setPreferences(without_run_model orelse preferences) catch |err| {
                    result.session_error = err;
                    warnDegraded(app, agent, err) catch {};
                };
                return result;
            }
            return result;
        }

        /// `preferences` with the model and provider `v2` has saved in place of
        /// theirs. Caller owns.
        fn withSavedModel(
            alloc: Allocator,
            v2: *session_adapter.Session,
            preferences: session_codec.DurableSessionPreferences,
        ) !session_codec.DurableSessionPreferences {
            var saved = try v2.currentPreferences(alloc);
            defer saved.deinit(alloc);
            var copy = try preferences.dupe(alloc);
            errdefer copy.deinit(alloc);
            const model = try alloc.dupe(u8, saved.model);
            alloc.free(copy.model);
            copy.model = model;
            copy.provider = saved.provider;
            return copy;
        }

        pub fn activeSessionId(agent: *AppAgent) ?[]const u8 {
            if (agent.session_persistence.v2) |v2| return v2.id();
            if (agent.session_persistence.js_host_session) |*owner| return owner.state.id;
            return null;
        }

        /// The id of `agent`'s session once it is on disk, so `spark --resume`
        /// finds it; null for one that holds no turn yet (D2).
        pub fn savedSessionId(agent: *AppAgent) ?[]const u8 {
            const v2 = agent.session_persistence.v2 orelse return null;
            if (!v2.saved()) return null;
            return v2.id();
        }

        /// Replaces the cached footer title. App owns the copy.
        pub fn setCachedSessionTitle(app: *App, agent: *AppAgent, title: []const u8) !void {
            if (comptime !agents.hasAgentField(App, "session_title")) return;
            agent.session_title.clearRetainingCapacity();
            try appendTitleWithoutControlBytes(app, agent, title);
            syncTerminalTitle(app, agent);
        }

        pub fn clearCachedSessionTitle(app: *App, agent: *AppAgent) void {
            if (comptime !agents.hasAgentField(App, "session_title")) return;
            agent.session_title.clearRetainingCapacity();
            syncTerminalTitle(app, agent);
        }

        /// Drops C0 and DEL bytes before the cached title reaches the statusline.
        /// Derived titles come from untrusted prompt text and display sidecars;
        /// `/rename` input is already rejected by `validateSessionTitle`.
        fn appendTitleWithoutControlBytes(app: *App, agent: *AppAgent, title: []const u8) !void {
            var start: usize = 0;
            for (title, 0..) |byte, index| {
                if (byte >= 0x20 and byte != 0x7f) continue;
                try agent.session_title.appendSlice(app.alloc, title[start..index]);
                start = index + 1;
            }
            try agent.session_title.appendSlice(app.alloc, title[start..]);
        }

        fn terminalTitle(app: *App) host_capability.TerminalTitle {
            if (comptime @hasDecl(App, "terminalTitle")) {
                return app.terminalTitle();
            }
            if (comptime builtin.is_test) return host_capability.unavailable_terminal_title;
            @compileError("interactive session runtime requires a terminal title host capability");
        }

        /// Terminal tabs show the agent on screen: its session title once one
        /// exists, before its first prompt the running build and workspace.
        /// Another agent's title leaves the tab alone until it is on screen.
        pub fn syncTerminalTitle(app: *App, agent: *AppAgent) void {
            if (comptime !provider_runtime.supported(App)) return;
            // The agent the user sees, not a hidden one the loop is visiting,
            // as the terminal's program status does.
            if (comptime @hasField(App, "agent_on_screen")) {
                const on_screen: *const AppAgent = if (app.agent_on_screen) |child| &child.agent else &app.main_agent;
                if (agent != on_screen) return;
            }
            syncTerminalTitleWith(app, agent, terminalTitle(app));
        }

        pub fn syncTerminalTitleWith(
            app: *App,
            agent: *AppAgent,
            provider: host_capability.TerminalTitle,
        ) void {
            if (comptime !provider_runtime.supported(App)) return;
            if (cachedSessionTitle(agent)) |title| {
                provider.set(title);
                return;
            }
            const basename = if (comptime @hasField(App, "workspace_root"))
                std.Io.Dir.path.basename(app.workspace_root)
            else
                "";
            const folder = if (basename.len == 0) "workspace" else basename;
            const prefix = "spark v" ++ build_options.app_version ++ " | ";
            var label_buffer: [prefix.len + std.Io.Dir.max_path_bytes]u8 = undefined;
            const label = std.mem.print(&label_buffer, "{s}{s}", .{ prefix, folder }) catch |err| {
                debug_trace.logf("session", "terminal title workspace omitted err={s}", .{@errorName(err)});
                provider.set("spark v" ++ build_options.app_version);
                return;
            };
            provider.set(label);
        }

        pub fn cachedSessionTitle(agent: *AppAgent) ?[]const u8 {
            if (comptime !agents.hasAgentField(App, "session_title")) return null;
            return if (agent.session_title.items.len == 0) null else agent.session_title.items;
        }

        /// Derives and caches the title on the first turn of a fresh session.
        /// Derivation freezes at the first usable prompt, so this is a no-op
        /// once a title is cached.
        pub fn ensureCachedSessionTitle(app: *App, agent: *AppAgent) !void {
            if (comptime !agents.hasAgentField(App, "session_title")) return;
            if (agent.session_title.items.len > 0) return;
            var display = session_display_metadata.deriveFromHistory(
                app.alloc,
                agent.session.agent.history.items,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return,
            };
            defer display.deinit(app.alloc);
            if (!display.present) return;
            try setCachedSessionTitle(app, agent, display.title);
        }

        /// Starts background title generation for a fresh session on the first
        /// user prompt submit. Fire-and-forget: every gate failure is a silent
        /// no-op because the locally derived title remains in place. The
        /// generated title is applied by `pollSessionTitleGeneration`.
        pub fn maybeStartSessionTitleGeneration(app: *App, agent: *AppAgent, prompt: []const u8) void {
            if (comptime host_target.is_wasm) return;
            if (comptime !agents.hasAgentField(App, "session_persistence")) return;
            if (comptime !@hasField(App, "session_title_generation")) return;
            if (comptime !agents.hasAgentField(App, "session_title")) return;
            if (comptime !agents.hasAgentField(App, "session")) return;
            if (comptime !@hasField(App, "auth")) return;
            if (comptime !@hasDecl(App, "agentStreamProvider")) return;
            if (comptime !@hasDecl(App, "sessionTitleModel")) return;

            const excerpt = session_title_generation.promptExcerpt(prompt) orelse return;
            const title_model = titleModelFor(app, agent, app.sessionTitleModel());
            const session_id = activeSessionId(agent) orelse return;
            const gate: session_title_generation.Gate = .{
                .setting_enabled = app.session_title_generation,
                .provider_supports_titles = title_model != null,
                .session_untitled = agent.session_title.items.len == 0 and
                    agent.session.agent.history.items.len == 0,
                .recovery_replay = false,
                .task_running = agent.session_persistence.title_generation.task != null,
                .title_started = agent.session_persistence.title_generation.startedFor(session_id),
            };
            if (!session_title_generation.shouldGenerate(gate)) {
                var without_record = gate;
                without_record.title_started = false;
                if (session_title_generation.shouldGenerate(without_record)) {
                    debug_trace.logf("session", "event=title_generation_skipped reason=already_started session={s}", .{session_id});
                }
                return;
            }

            const credential_source = app.auth.credentialSource() orelse return;

            const task = session_title_generation.Task.create(.{
                .session_id = session_id,
                .model = title_model.?,
                .prompt_excerpt = excerpt,
                .api_key = app.auth.apiKey(),
                .credential_source = credential_source,
                .stream_provider = app.agentStreamProvider(),
            }) catch |err| {
                agent.session_persistence.title_generation.recordSpawnFailure(session_id, title_model.?, err);
                return;
            };
            task.spawn() catch |err| {
                debug_trace.logf("session", "event=title_generation result=unavailable reason=spawn err={s}", .{@errorName(err)});
                agent.session_persistence.title_generation.recordSpawnFailure(session_id, title_model.?, err);
                task.destroy();
                return;
            };
            agent.session_persistence.title_generation.start(task);
        }

        /// The provider's title model.
        fn titleModelFor(_: *App, _: *AppAgent, provider_title_model: ?[]const u8) ?[]const u8 {
            return provider_title_model;
        }

        /// Applies a finished background title generation on the main loop.
        /// Returns true when the session title changed.
        pub fn pollSessionTitleGeneration(app: *App, agent: *AppAgent) !bool {
            if (comptime host_target.is_wasm) return false;
            if (comptime !agents.hasAgentField(App, "session_persistence")) return false;
            if (comptime !agents.hasAgentField(App, "session_title")) return false;
            if (comptime !agents.hasAgentField(App, "session")) return false;
            const task = agent.session_persistence.title_generation.takeCompleted() orelse return false;
            defer task.destroy();
            agent.session_persistence.title_generation.recordFinished(task);
            const title = task.takeTitle() orelse {
                debug_trace.logf("session", "event=title_generation_apply result=unavailable session={s}", .{task.session_id});
                return false;
            };
            defer std.heap.c_allocator.free(title);
            const active_id = activeSessionId(agent) orelse {
                debug_trace.logf("session", "event=title_generation_apply result=dropped reason=no_active_session", .{});
                agent.session_persistence.title_generation.recordDropped(.no_active_session, "");
                return false;
            };
            if (!std.mem.eql(u8, active_id, task.session_id)) {
                debug_trace.logf(
                    "session",
                    "event=title_generation_apply result=dropped reason=session_changed session={s} active={s}",
                    .{ task.session_id, active_id },
                );
                agent.session_persistence.title_generation.recordDropped(.session_changed, "");
                return false;
            }
            var installed = false;
            {
                agent.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
                defer agent.session_persistence.write_mutex.unlock(io_mod.getIo());
                if (agent.session_persistence.v2) |v2| {
                    installed = v2.installGeneratedTitle(agent.session.agent.history.items, title) catch |err| {
                        debug_trace.logf(
                            "session",
                            "event=title_generation_apply result=failed session={s} err={s}",
                            .{ task.session_id, @errorName(err) },
                        );
                        agent.session_persistence.title_generation.recordDropped(.install_failed, @errorName(err));
                        return false;
                    };
                    if (!installed) {
                        agent.session_persistence.title_generation.recordDropped(.user_title_present, "");
                    }
                } else {
                    debug_trace.logf(
                        "session",
                        "event=title_generation_apply result=dropped reason=not_writable session={s}",
                        .{task.session_id},
                    );
                    agent.session_persistence.title_generation.recordDropped(.not_writable, "");
                }
            }
            if (!installed) return false;
            try setCachedSessionTitle(app, agent, title);
            invalidateSessionPickerCaches(agent);
            debug_trace.logf("session", "event=title_generation_apply result=installed session={s}", .{task.session_id});
            return true;
        }

        pub const RenameError = error{
            EmptyTitle,
            TitleTooLong,
            InvalidTitle,
            MultilineTitle,
            NoActiveSession,
        };

        /// Validates a user-supplied session title. Returns the trimmed slice,
        /// without one pair of quotes wrapped around the whole title, which
        /// borrows from `raw`.
        pub fn validateSessionTitle(raw: []const u8) RenameError![]const u8 {
            const title = std.mem.trim(u8, withoutWrappingQuotes(std.mem.trim(u8, raw, " \t\r\n")), " \t");
            if (title.len == 0) return error.EmptyTitle;
            if (title.len > session_display_metadata.max_title_bytes) return error.TitleTooLong;
            if (!std.unicode.utf8ValidateSlice(title)) return error.InvalidTitle;
            if (std.mem.findAny(u8, title, "\r\n") != null) return error.MultilineTitle;
            for (title) |byte| {
                if (byte < 0x20 or byte == 0x7f) return error.InvalidTitle;
            }
            return title;
        }

        /// `"deploy fix"` names the session `deploy fix`; a quote that only
        /// opens, or one inside the title, stays.
        fn withoutWrappingQuotes(text: []const u8) []const u8 {
            if (text.len < 2) return text;
            const quote = text[0];
            if (quote != '"' and quote != '\'') return text;
            if (text[text.len - 1] != quote) return text;
            const inner = text[1 .. text.len - 1];
            if (std.mem.findScalar(u8, inner, quote) != null) return text;
            return inner;
        }

        /// Renames the active session in memory and in session metadata.
        pub fn renameActiveSession(app: *App, agent: *AppAgent, raw: []const u8) !void {
            const title = try validateSessionTitle(raw);
            if (comptime !agents.hasAgentField(App, "session_persistence")) return error.NoActiveSession;
            const v2 = agent.session_persistence.v2 orelse return error.NoActiveSession;

            try setCachedSessionTitle(app, agent, title);

            agent.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer agent.session_persistence.write_mutex.unlock(io_mod.getIo());
            try v2.rename(title);
            invalidateSessionPickerCaches(agent);
        }

        pub fn activeSessionDisplayPath(
            agent: *AppAgent,
            alloc: Allocator,
        ) !?[]u8 {
            const v2 = agent.session_persistence.v2 orelse return null;
            return try v2.folderPath(alloc);
        }

        pub fn childCapability(agent: *AppAgent) ?*session_child_store.SessionChildCapability {
            if (agent.session_persistence.v2 == null) return null;
            return activeChildCapability(agent) catch null;
        }

        /// The open session's side-file capability.
        fn activeChildCapability(agent: *AppAgent) !*session_child_store.SessionChildCapability {
            const v2 = agent.session_persistence.v2 orelse return error.SessionPersistenceUnavailable;
            return v2.childCapability();
        }

        pub fn subagentHost(app: *App) ?*subagent_tool_host.Runtime {
            if (comptime !agents.hasAgentField(App, "session_persistence")) return null;
            return app.main_agent.session_persistence.subagent_host;
        }

        /// The host of the agent in context: main's for main, a subagent's
        /// own for a subagent, where its `subagent` calls go.
        pub fn ownSubagentHost(agent: *AppAgent) ?*subagent_tool_host.Runtime {
            if (comptime !agents.hasAgentField(App, "session_persistence")) return null;
            return agent.session_persistence.subagent_host;
        }

        /// Points what holds `agent` back at the app after `App.init` copies
        /// it: the store's notice and the subagent host.
        pub fn rebindAfterMove(app: *App, agent: *AppAgent) void {
            if (agent.session_persistence.v2_store) |store| {
                if (store.notice != null) store.notice = .{ .context = app, .emit = conversionNotice };
            }
            const host = agent.session_persistence.subagent_host orelse return;
            host.rebindHost(app, subagentAuthorityResolver(app));
            bindToolboxBehind(app, host);
        }

        /// Points `host`'s children at the app's tools behind toolbox, so a
        /// child whose profile lists one keeps toolbox to reach it. Bound
        /// again after the app moves, as the host's callbacks are.
        fn bindToolboxBehind(app: *App, host: *subagent_tool_host.Runtime) void {
            if (comptime @hasField(App, "toolbox_behind")) host.authority_resolver.toolbox_behind = &app.toolbox_behind;
        }

        /// Stops the subagent host, joining its child threads, before the
        /// session they append to can close (`tests/tla/session_manager/Wiring.tla`
        /// ParentOutlivesChildren).
        pub fn disableSubagentHost(app: *App, agent: *AppAgent) void {
            if (agent.session_persistence.subagent_host) |host| {
                host.deinit();
                agent.session_persistence.subagent_host = null;
            }
            if (agent.session_persistence.v2_children) |children| {
                children.deinit();
                app.alloc.destroy(children);
                agent.session_persistence.v2_children = null;
            }
        }

        pub fn finalizePersistence(app: *App, agent: *AppAgent) void {
            closeWritableSession(app, agent);
        }

        pub fn recordShutdownFailure(agent: *AppAgent, err: anyerror) void {
            if (agent.session_persistence.shutdown_failure == null) {
                agent.session_persistence.shutdown_failure = err;
            }
            debug_trace.logf("session", "shutdown finished prompt persistence failed err={s}", .{@errorName(err)});
        }

        pub fn finalizePersistenceWithResumeHandoff(app: *App, agent: *AppAgent) ?ResumeHandoff {
            return closeWritableSessionWithResumeHandoff(app, agent);
        }

        pub fn requestResumeHandoff(agent: *AppAgent) void {
            agent.session_persistence.resume_handoff_intent = .requested;
        }

        pub fn requestUpgradeResumeHandoff(agent: *AppAgent) void {
            agent.session_persistence.resume_handoff_intent = .upgrade_requested;
        }

        pub fn prepareResumeHandoff(agent: *AppAgent) !void {
            agent.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer agent.session_persistence.write_mutex.unlock(io_mod.getIo());
            if (agent.session_persistence.v2 == null) return error.SessionPersistenceUnavailable;
        }

        pub fn suspendToJobControl(app: *App, footer_rows: u16) !void {
            return app_lifecycle.suspendToJobControl(
                &app.terminal,
                &app.shell,
                &app.metrics,
                footer_rows,
            );
        }

        pub fn deinitPersistence(app: *App, agent: *AppAgent) void {
            closeWritableSession(app, agent);
            agent.session_persistence.deinit(app.alloc);
            finishCaptureMaintenance(app, agent);
        }

        pub fn deinitPersistenceForProcessExit(app: *App, agent: *AppAgent) void {
            closeWritableSession(app, agent);
            agent.session_persistence.deinitForProcessExit(app.alloc);
            finishCaptureMaintenance(app, agent);
        }

        /// Retention's maintenance ends with the app: the main agent's
        /// persistence goes last, once every worker has stopped (D98). A
        /// child agent closing leaves it running.
        fn finishCaptureMaintenance(app: *App, agent: *AppAgent) void {
            if (comptime !turn_capture.supported or !@hasField(App, "main_agent")) return;
            if (agent != &app.main_agent) return;
            turn_capture.finishMaintenance();
        }

        pub fn requestPersistenceShutdown(agent: *AppAgent) void {
            agent.session_persistence.session_picker_load.requestStop();
            agent.session_persistence.title_generation.requestStop();
        }

        fn LiveHistorySink(comptime SinkApp: type) type {
            return struct {
                app: *SinkApp,

                const Self = @This();

                fn appendNotice(self: *Self, notice: types.SemanticNotice) !void {
                    try self.app.writeDomainNotice(notice, true);
                }

                fn setCreatedAtMs(_: *Self, _: i64) void {}

                fn materializeCommandReplay(_: *const Self) bool {
                    return true;
                }

                fn appendTurnSummary(self: *Self, summary: types.TurnSummary) !void {
                    if (comptime @hasField(SinkApp, "shell")) {
                        if (comptime @hasDecl(@TypeOf(self.app.shell), "appendTurnSummaryEntry")) {
                            _ = try self.app.shell.appendTurnSummaryEntry(self.app.alloc, summary);
                        }
                    }
                }

                fn appendUserTurn(self: *Self, user: types.UserTurn, has_prior_turns: bool) !void {
                    try self.app.writeUserPromptCardWithSpacing(user, has_prior_turns);
                }

                fn appendRaw(self: *Self, text: []const u8) !void {
                    try self.app.writeTranscript(text, true);
                }

                fn appendTurnCancellation(self: *Self) !void {
                    const line = try transcript_runtime.formatHistoricalToolStatusLine(
                        self.app.alloc,
                        .cancelled,
                        "Cancelled",
                    );
                    defer self.app.alloc.free(line);
                    try self.app.writeTranscriptClassified(
                        line,
                        true,
                        .turn_cancellation,
                    );
                }

                fn appendToolStatus(
                    self: *Self,
                    kind: types.ToolOutcomeKind,
                    status: []const u8,
                ) !u32 {
                    if (comptime @hasDecl(SinkApp, "writeCompletedToolStatusReturningEntryId")) {
                        return self.app.writeCompletedToolStatusReturningEntryId(kind, status, true);
                    }
                    try self.app.writeCompletedToolStatus(kind, status, true);
                    return 0;
                }

                fn appendCommandOutput(
                    self: *Self,
                    stream: command_output_content.Stream,
                    text: []const u8,
                ) !void {
                    try self.app.writeCommandOutputChunk(stream, text, true);
                }

                fn finishCommandOutput(self: *Self) !void {
                    try self.app.flushCommandOutputSummary(true);
                }

                fn attachHistoricalToolDetail(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                ) !void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalToolDetail")) {
                        try self.app.attachHistoricalToolDetail(entry_id, call, result);
                    }
                }

                fn attachHistoricalToolDetailWithLifecycle(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                    lifecycle_id: types.ToolLifecycleId,
                ) !void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalToolDetailWithLifecycle")) {
                        try self.app.attachHistoricalToolDetailWithLifecycle(
                            entry_id,
                            call,
                            result,
                            lifecycle_id,
                        );
                    } else {
                        try self.attachHistoricalToolDetail(entry_id, call, result);
                    }
                }

                fn attachHistoricalToolDetailAfterCommandOutput(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                ) !void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalToolDetailAfterCommandOutput")) {
                        try self.app.attachHistoricalToolDetailAfterCommandOutput(
                            entry_id,
                            call,
                            result,
                        );
                    } else {
                        try self.attachHistoricalToolDetail(entry_id, call, result);
                    }
                }

                fn attachHistoricalToolCallWithoutResult(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                ) !void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalToolCallWithoutResult")) {
                        try self.app.attachHistoricalToolCallWithoutResult(entry_id, call);
                    }
                }

                fn attachHistoricalBridgeCall(
                    self: *Self,
                    entry_id: u32,
                    tool: []const u8,
                    outcome: types.ToolOutcomeKind,
                ) !void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalBridgeCall")) {
                        try self.app.attachHistoricalBridgeCall(entry_id, tool, outcome);
                    }
                }

                fn attachHistoricalCommandOutput(self: *Self, entry_id: u32) void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalCommandOutput")) {
                        self.app.attachHistoricalCommandOutput(entry_id);
                    }
                }

                fn attachHistoricalCancelledCommandDetail(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    command_artifact_handle: ?[]const u8,
                    replayed_output: bool,
                ) !void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalCancelledCommandDetail")) {
                        try self.app.attachHistoricalCancelledCommandDetail(
                            entry_id,
                            call,
                            command_artifact_handle,
                            replayed_output,
                        );
                    }
                }

                fn appendQuestionResolution(
                    self: *Self,
                    answers: []const types.QuestionAnswer,
                ) !u32 {
                    return self.app.writeHistoricalQuestionResolution(answers);
                }

                fn appendDiff(self: *Self, payload: diff.DiffEntryPayload) !void {
                    try self.app.registerAndEmitDiffBlock(payload);
                }

                fn appendAssistantText(self: *Self, text: []const u8) !void {
                    try SinkApp.pacerEmit(self.app, text);
                }

                fn appendAssistantTable(
                    self: *Self,
                    table: assistant_presentation.TablePayload,
                ) !void {
                    try self.app.appendAssistantTable(table);
                }

                fn appendAssistantCodeBlock(
                    self: *Self,
                    block: assistant_presentation.CodeBlockPayload,
                ) !void {
                    try self.app.appendAssistantCodeBlock(block);
                }

                fn appendAssistantThematicRule(self: *Self) !void {
                    try self.app.appendAssistantThematicRule();
                }
            };
        }

        fn DetachedHistorySink(comptime Projection: type) type {
            return struct {
                app: *App,
                projection: *Projection,
                labels: *const HistoricalSessionLabels,

                const Self = @This();

                fn activityKind(self: *Self, call: types.ToolCall) types.ToolActivityKind {
                    return self.app.historicalToolActivityKind(agents.screenAgentOf(self.app), call);
                }

                /// Terminal-session actions (interact, stop) carry no command
                /// argument; restore their full launch command from the recorded
                /// session label so resumed rows reclip to the live width.
                fn attachSessionCommandDisplay(self: *Self, entry_id: u32, call: types.ToolCall) !void {
                    var scratch_state = std.heap.ArenaAllocator.init(self.projection.alloc);
                    defer mem_utils.deinit_arena(scratch_state);
                    const scratch = scratch_state.allocator();
                    const label = tooling_presentation.terminalSessionCompletedActionLabel(
                        scratch,
                        self.app.toolRegistry(agents.screenAgentOf(self.app)),
                        call,
                    ) catch |err| {
                        debug_trace.logf(
                            "session",
                            "historical session action label unavailable entry_id={d} err={s}",
                            .{ entry_id, @errorName(err) },
                        );
                        return;
                    } orelse return;
                    const reflow = historicalSessionReflow(scratch, self.labels, call) orelse {
                        debug_trace.logf(
                            "session",
                            "historical session command unknown entry_id={d}",
                            .{entry_id},
                        );
                        return;
                    };
                    self.projection.setHistoricalToolCommandMetadata(
                        entry_id,
                        reflow,
                        label,
                    ) catch |err| debug_trace.logf(
                        "session",
                        "historical session command metadata unavailable entry_id={d} err={s}",
                        .{ entry_id, @errorName(err) },
                    );
                }

                fn attachCommandDisplay(self: *Self, entry_id: u32, call: types.ToolCall) !void {
                    var parsed = std.json.parseFromSlice(std.json.Value, self.projection.alloc, call.arguments_json, .{}) catch |err| {
                        debug_trace.logf(
                            "session",
                            "historical command metadata parse failed entry_id={d} err={s}",
                            .{ entry_id, @errorName(err) },
                        );
                        return;
                    };
                    defer parsed.deinit();
                    if (parsed.value != .object) return;
                    const command_value = parsed.value.object.get("command") orelse {
                        try self.attachSessionCommandDisplay(entry_id, call);
                        return;
                    };
                    if (command_value != .string) {
                        try self.attachSessionCommandDisplay(entry_id, call);
                        return;
                    }
                    // Use the app's live workspace root: the replayed status
                    // phrases are generated with that same root, so this keeps
                    // both halves of the row consistent.
                    const display = (tooling_presentation.formatRunCommandDetailBounded(
                        self.projection.alloc,
                        command_value.string,
                        self.app.workspace_root,
                        tooling_presentation.max_run_command_reflow_bytes,
                    ) catch |err| blk: {
                        debug_trace.logf(
                            "session",
                            "historical command display unavailable entry_id={d} err={s}",
                            .{ entry_id, @errorName(err) },
                        );
                        break :blk null;
                    }) orelse {
                        debug_trace.logf(
                            "session",
                            "historical command display withheld entry_id={d}",
                            .{entry_id},
                        );
                        return;
                    };
                    defer self.projection.alloc.free(display);
                    const label = tooling_presentation.runCommandCompletedActionLabel(
                        self.projection.alloc,
                        self.app.toolRegistry(agents.screenAgentOf(self.app)),
                        call,
                    ) catch |err| blk: {
                        debug_trace.logf(
                            "session",
                            "historical command action label unavailable entry_id={d} err={s}",
                            .{ entry_id, @errorName(err) },
                        );
                        break :blk null;
                    };
                    if (label == null) debug_trace.logf(
                        "session",
                        "historical command action label withheld entry_id={d}",
                        .{entry_id},
                    );
                    if (label) |value| self.projection.setHistoricalToolCommandMetadata(
                        entry_id,
                        display,
                        value,
                    ) catch |err| debug_trace.logf(
                        "session",
                        "historical command metadata unavailable entry_id={d} err={s}",
                        .{ entry_id, @errorName(err) },
                    );
                }

                fn appendNotice(self: *Self, notice: types.SemanticNotice) !void {
                    _ = try self.projection.appendNotice(notice);
                }

                fn setCreatedAtMs(self: *Self, created_at_ms: i64) void {
                    self.projection.setCreatedAtMs(created_at_ms);
                }

                fn materializeCommandReplay(_: *const Self) bool {
                    return false;
                }

                fn appendTurnSummary(self: *Self, summary: types.TurnSummary) !void {
                    try self.projection.appendTurnSummary(summary);
                }

                fn appendUserTurn(self: *Self, user: types.UserTurn, _: bool) !void {
                    // A report's turn comes back as its subagent row, as it
                    // showed live.
                    if (try subagent_reports.row(self.projection.alloc, user)) |shown| {
                        defer shown.deinit(self.projection.alloc);
                        const entry_id = try self.projection.appendToolStatus(shown.outcome, shown.status);
                        try self.projection.attachSubagentReportDetail(entry_id, subagent_reports.Row.call, shown.result(self.projection.created_at_ms));
                        return;
                    }
                    _ = try self.projection.appendUserTurn(user);
                }

                fn appendRaw(self: *Self, text: []const u8) !void {
                    _ = try self.projection.appendRawClassified(text, .unknown_raw);
                }

                fn appendTurnCancellation(self: *Self) !void {
                    const line = try transcript_runtime.formatHistoricalToolStatusLine(
                        self.projection.alloc,
                        .cancelled,
                        "Cancelled",
                    );
                    defer self.projection.alloc.free(line);
                    _ = try self.projection.appendRawClassified(
                        line,
                        .turn_cancellation,
                    );
                }

                fn appendToolStatus(
                    self: *Self,
                    kind: types.ToolOutcomeKind,
                    status: []const u8,
                ) !u32 {
                    return self.projection.appendToolStatus(kind, status);
                }

                fn appendCommandOutput(
                    self: *Self,
                    stream: command_output_content.Stream,
                    text: []const u8,
                ) !void {
                    try self.projection.appendCommandOutput(null, stream, text);
                }

                fn finishCommandOutput(self: *Self) !void {
                    try self.projection.finishCommandOutput(null);
                }

                fn attachHistoricalToolDetail(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                ) !void {
                    try self.projection.attachHistoricalToolDetail(
                        entry_id,
                        call,
                        self.activityKind(call),
                        result,
                    );
                    try self.attachCommandDisplay(entry_id, call);
                }

                fn attachHistoricalToolDetailWithLifecycle(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                    lifecycle_id: types.ToolLifecycleId,
                ) !void {
                    try self.projection.attachHistoricalToolDetailWithLifecycle(
                        entry_id,
                        call,
                        self.activityKind(call),
                        result,
                        lifecycle_id,
                    );
                    try self.attachCommandDisplay(entry_id, call);
                }

                fn attachHistoricalToolDetailAfterCommandOutput(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                ) !void {
                    try self.projection.attachHistoricalToolDetailAfterCommandOutput(
                        entry_id,
                        call,
                        self.activityKind(call),
                        result,
                    );
                    try self.attachCommandDisplay(entry_id, call);
                }

                fn attachHistoricalToolCallWithoutResult(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                ) !void {
                    try self.projection.attachHistoricalToolCallWithoutResult(entry_id, call);
                }

                fn attachHistoricalBridgeCall(
                    self: *Self,
                    entry_id: u32,
                    tool: []const u8,
                    outcome: types.ToolOutcomeKind,
                ) !void {
                    try self.projection.attachHistoricalBridgeCall(entry_id, tool, outcome);
                }

                fn attachHistoricalCommandOutput(self: *Self, entry_id: u32) void {
                    self.projection.attachHistoricalCommandOutput(entry_id);
                }

                fn attachHistoricalCancelledCommandDetail(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    command_artifact_handle: ?[]const u8,
                    replayed_output: bool,
                ) !void {
                    try self.projection.attachHistoricalCancelledCommandDetail(
                        entry_id,
                        call,
                        command_artifact_handle,
                        replayed_output,
                    );
                    // The live row's command metadata, so the compact view
                    // shows the command's short form, as it did live.
                    try self.attachCommandDisplay(entry_id, call);
                }

                fn appendQuestionResolution(
                    self: *Self,
                    answers: []const types.QuestionAnswer,
                ) !u32 {
                    const text = try self.app.prepareHistoricalQuestionResolution(answers);
                    defer self.app.alloc.free(text);
                    return self.projection.appendReplaceableLine(text);
                }

                fn appendDiff(self: *Self, payload: diff.DiffEntryPayload) !void {
                    try self.projection.appendDiff(payload);
                }

                fn appendAssistantText(self: *Self, text: []const u8) !void {
                    try self.projection.appendAssistantText(text);
                }

                fn appendAssistantTable(
                    self: *Self,
                    table: assistant_presentation.TablePayload,
                ) !void {
                    try self.projection.appendAssistantTable(table);
                }

                fn appendAssistantCodeBlock(
                    self: *Self,
                    block: assistant_presentation.CodeBlockPayload,
                ) !void {
                    try self.projection.appendAssistantCodeBlock(block);
                }

                fn appendAssistantThematicRule(self: *Self) !void {
                    try self.projection.appendAssistantThematicRule();
                }
            };
        }

        /// Maps historical shell session ids to their launch-command label so a
        /// resumed transcript can render the same `Observed <command>` text the
        /// live session showed, after the in-memory execution registry is gone.
        /// Session ids restart per process, so a session resumed across epochs
        /// can contain two runs that both produced `shell-1`; the later record
        /// wins, matching the most recent epoch's live rendering.
        const HistoricalSessionLabels = struct {
            const Label = struct {
                /// Compact-bound text baked into frozen status lines.
                label: []const u8,
                /// Reflow-bound command stored as tool detail metadata so group
                /// projection can reclip resumed rows to the live terminal width.
                reflow: ?[]const u8,
            };

            workspace_root: []const u8,
            map: std.StringHashMapUnmanaged(Label) = .empty,
            /// Calls whose saved output later `read_tool_result` rows read, so
            /// those rows name them as the live session did.
            saved_output_sources: tool_presentation.ReplayedSavedOutputSources = .{},

            fn deinit(self: *HistoricalSessionLabels, alloc: Allocator) void {
                var it = self.map.iterator();
                while (it.next()) |entry| {
                    alloc.free(entry.key_ptr.*);
                    alloc.free(entry.value_ptr.label);
                    if (entry.value_ptr.reflow) |value| alloc.free(value);
                }
                self.map.deinit(alloc);
                self.saved_output_sources.deinit(alloc);
            }
        };

        /// Returns the recorded launch-command label for a session-scoped call
        /// (borrowed from `labels`), or null when the session is unknown.
        fn historicalSessionTarget(
            arena: Allocator,
            labels: *const HistoricalSessionLabels,
            call: types.ToolCall,
        ) ?[]const u8 {
            const entry = historicalSessionLabelEntry(arena, labels, call) orelse return null;
            return entry.label;
        }

        /// Returns the recorded reflow-bound launch command for a
        /// session-scoped call (borrowed from `labels`), or null when the
        /// session is unknown or no full display was recorded.
        fn historicalSessionReflow(
            arena: Allocator,
            labels: *const HistoricalSessionLabels,
            call: types.ToolCall,
        ) ?[]const u8 {
            const entry = historicalSessionLabelEntry(arena, labels, call) orelse return null;
            return entry.reflow;
        }

        fn historicalSessionLabelEntry(
            arena: Allocator,
            labels: *const HistoricalSessionLabels,
            call: types.ToolCall,
        ) ?HistoricalSessionLabels.Label {
            const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch return null;
            const session_id = tool_args.optionalStringArg(args, "session_id") orelse return null;
            return labels.map.get(session_id);
        }

        /// Reads the session id out of a persisted shell status payload into
        /// `buffer`, returning a slice of it. The preview can be truncated
        /// mid-JSON, so fall back to a bounded scan for the leading
        /// `"session_id"` field when a full parse fails.
        fn historicalSessionIdFromOutput(
            alloc: Allocator,
            output: []const u8,
            buffer: *[128]u8,
        ) ?[]const u8 {
            if (copyParsedSessionId(alloc, output, buffer)) |session_id| return session_id;
            const key = "\"session_id\":\"";
            const start = (std.mem.find(u8, output, key) orelse return null) + key.len;
            const end = std.mem.findScalarPos(u8, output, start, '"') orelse return null;
            return copyHistoricalSessionId(output[start..end], buffer);
        }

        fn copyParsedSessionId(alloc: Allocator, output: []const u8, buffer: *[128]u8) ?[]const u8 {
            var parsed = std.json.parseFromSlice(
                std.json.Value,
                alloc,
                output,
                .{},
            ) catch return null;
            defer parsed.deinit();
            if (parsed.value != .object) return null;
            const value = parsed.value.object.get("session_id") orelse return null;
            if (value != .string) return null;
            return copyHistoricalSessionId(value.string, buffer);
        }

        fn copyHistoricalSessionId(raw: []const u8, buffer: *[128]u8) ?[]const u8 {
            if (!validHistoricalSessionId(raw)) return null;
            @memcpy(buffer[0..raw.len], raw);
            return buffer[0..raw.len];
        }

        fn validHistoricalSessionId(session_id: []const u8) bool {
            if (session_id.len == 0 or session_id.len > 128) return false;
            for (session_id) |byte| {
                if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
            }
            return true;
        }

        /// Records the launch command of a completed `run` call whose result
        /// still owns a live session, so later interact/stop calls naming that
        /// session render the command instead of the raw session id. Calls
        /// without a command argument, or whose result names no session,
        /// return without recording.
        fn recordHistoricalSessionLabel(
            app: *App,
            labels: *HistoricalSessionLabels,
            call: types.ToolCall,
            result: types.PersistedToolResult,
        ) Allocator.Error!void {
            var scratch_state = std.heap.ArenaAllocator.init(app.alloc);
            defer mem_utils.deinit_arena(scratch_state);
            const scratch = scratch_state.allocator();
            const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch return;
            const command = tool_args.optionalStringArg(args, "command") orelse return;
            const output = if (result.output.len > 0)
                result.output
            else
                result.preview orelse return;
            var session_id_buffer: [128]u8 = undefined;
            const session_id = historicalSessionIdFromOutput(scratch, output, &session_id_buffer) orelse return;
            const label = (try tooling_presentation.formatHistoricalTerminalDisplayTarget(
                app.alloc,
                command,
                labels.workspace_root,
            )) orelse {
                debug_trace.logf(
                    "session",
                    "historical session label withheld call_id={s} session_id={s}",
                    .{ call.id, session_id },
                );
                return;
            };
            errdefer app.alloc.free(label);
            const reflow: ?[]const u8 = (try tooling_presentation.formatRunCommandDetailBounded(
                app.alloc,
                command,
                labels.workspace_root,
                tooling_presentation.max_run_command_reflow_bytes,
            )) orelse null;
            errdefer if (reflow) |value| app.alloc.free(value);
            const owned_id = try app.alloc.dupe(u8, session_id);
            errdefer app.alloc.free(owned_id);
            const gop = try labels.map.getOrPut(app.alloc, owned_id);
            if (gop.found_existing) {
                app.alloc.free(owned_id);
                app.alloc.free(gop.value_ptr.label);
                if (gop.value_ptr.reflow) |value| app.alloc.free(value);
            }
            gop.value_ptr.* = .{ .label = label, .reflow = reflow };
        }

        /// Reads an older compaction cycle of `agent`, whose transcript is
        /// on screen, from its session log for Ctrl+O: `back` cycles before
        /// the held entries, 1 being the newest. Finds where the cycle
        /// starts here, walking back from the cycles already found, and
        /// reads only that cycle's turns, on a background thread;
        /// `pollTranscriptArchive` replays them once they are read. A read of
        /// the same cycle already running goes on.
        pub fn loadTranscriptArchive(app: *App, agent: *AppAgent, back: u32) !void {
            if (comptime !@hasField(App, "shell") or !@hasDecl(App, "beginResumeProjection")) return error.TranscriptArchiveUnavailable;
            if (back == 0) return error.TranscriptArchiveUnavailable;
            const read = &agent.session_persistence.transcript_archive_read;
            const generation = app.shell.transcript_archive_generation;
            if (read.pendingFor(back, generation)) return;
            const v2 = agent.session_persistence.v2 orelse return error.SessionPersistenceUnavailable;
            const started_ns = io_mod.nanoTimestamp();
            const newest = (try v2.previousCompactionCursor(app.alloc, null)).cursor orelse return error.TranscriptArchiveUnavailable;
            const holds_previous = app.shell.transcriptWindowHoldsPreviousCycle();
            const cache = &agent.session_persistence.transcript_archive_boundaries;
            const stale = if (cache.key) |key| !std.meta.eql(key.newest, newest) or key.holds_previous != holds_previous else true;
            if (stale) {
                cache.starts.clearRetainingCapacity();
                cache.key = .{ .newest = newest, .holds_previous = holds_previous };
                cache.damaged_from = null;
                cache.held_start = if (holds_previous) cache.startOf(1, try v2.previousCompactionCursor(app.alloc, newest)) else newest;
            }
            while (cache.starts.items.len < back) {
                // Below `back`, a u32, so the cast holds.
                const next_back: u32 = @intCast(cache.starts.items.len + 1);
                const end = (if (next_back == 1) cache.held_start else cache.starts.items[next_back - 2]) orelse
                    return if (cache.damages(next_back)) error.TranscriptArchiveDamaged else error.TranscriptArchiveUnavailable;
                try cache.starts.append(app.alloc, cache.startOf(next_back, try v2.previousCompactionCursor(app.alloc, end)));
            }
            const start = cache.starts.items[back - 1];
            const reader = try v2.cycleReader(std.heap.c_allocator);
            try read.start(reader, .{ .back = back, .start = start, .generation = generation });
            debug_trace.logf("full_transcript_cache", "archive_read_started back={d} generation={d} find_us={d}", .{
                back,
                generation,
                @divTrunc(io_mod.nanoTimestamp() - started_ns, std.time.ns_per_us),
            });
        }

        /// The detached transcript a finished read's turns replay into, a
        /// few turns per loop turn (`pollTranscriptArchive`).
        const ArchiveReplay = struct {
            alloc: Allocator,
            projection: resume_projection.ResumeProjection,
            labels: HistoricalSessionLabels,
            has_prior_turns: bool = false,
            /// The next turn to replay.
            next: usize = 0,
            replay_ns: i128 = 0,
            /// The longest loop turn spent replaying.
            longest_slice_ns: i128 = 0,

            fn create(app: *App, back: u32) !*ArchiveReplay {
                const self = try app.alloc.create(ArchiveReplay);
                errdefer app.alloc.destroy(self);
                self.* = .{
                    .alloc = app.alloc,
                    .projection = try resume_projection.ResumeProjection.initEmpty(app.alloc, &app.shell, 0, 1),
                    .labels = .{ .workspace_root = app.workspace_root },
                };
                // Apart from the live ids: Ctrl+O joins this cycle to the held entries.
                self.projection.runtime.notebook.next_entry_id = transcript_runtime.archiveEntryIdBase(back);
                return self;
            }

            fn destroy(context: *anyopaque) void {
                const self: *ArchiveReplay = @ptrCast(@alignCast(context));
                self.projection.deinit();
                self.labels.deinit(self.alloc);
                self.alloc.destroy(self);
            }
        };

        /// How long one loop turn replays a read's turns before it lets
        /// input and painting run; a turn always replays whole.
        const archive_replay_slice_ns: i128 = 4 * std.time.ns_per_ms;

        /// Replays the cycle a background read of `agent`'s session log
        /// finished into a detached transcript, a few turns per call, and
        /// installs it for Ctrl+O once every turn is in. A read that a
        /// compaction, resume, or drop made stale is dropped. Returns whether
        /// it installed one.
        pub fn pollTranscriptArchive(app: *App, agent: *AppAgent) !bool {
            if (comptime !@hasField(App, "shell") or !@hasDecl(App, "beginResumeProjection")) return false;
            const read = &agent.session_persistence.transcript_archive_read;
            if (read.dropIfStale(app.shell.transcript_archive_generation)) return false;
            const task = read.completed() orelse return false;
            const back = task.request.back;
            const outcome = advanceTranscriptArchiveReplay(app, agent, task) catch |err| {
                read.finish();
                return err;
            };
            switch (outcome) {
                .replaying => return false,
                .installed => {
                    read.finish();
                    return true;
                },
                .empty_cycle_skipped => {
                    // This read is done, so the next one is not taken for it.
                    read.finish();
                    try loadTranscriptArchive(app, agent, back);
                    return false;
                },
            }
        }

        const ArchiveReplayOutcome = enum { replaying, installed, empty_cycle_skipped };

        /// One loop turn of `pollTranscriptArchive`'s replay of `task`'s
        /// turns, and the install once they are all in.
        fn advanceTranscriptArchiveReplay(app: *App, agent: *AppAgent, task: *session_persistence.TranscriptArchiveRead.Task) !ArchiveReplayOutcome {
            if (task.failure) |err| return err;
            const back = task.request.back;
            const cache = &agent.session_persistence.transcript_archive_boundaries;
            const replay: *ArchiveReplay = if (task.replay) |held| @ptrCast(@alignCast(held.state)) else blk: {
                const created = try ArchiveReplay.create(app, back);
                task.replay = .{ .state = created, .deinit_fn = ArchiveReplay.destroy };
                break :blk created;
            };
            var sink = DetachedHistorySink(resume_projection.ResumeProjection){
                .app = app,
                .projection = &replay.projection,
                .labels = &replay.labels,
            };
            const slice_started_ns = io_mod.nanoTimestamp();
            while (replay.next < task.turns.items.len) {
                try replayHistoryToSinkIncremental(app, agent, &sink, task.turns.items[replay.next..][0..1], &replay.has_prior_turns, &replay.labels);
                replay.next += 1;
                if (io_mod.nanoTimestamp() - slice_started_ns >= archive_replay_slice_ns) break;
            }
            const slice_ns = io_mod.nanoTimestamp() - slice_started_ns;
            replay.replay_ns += slice_ns;
            replay.longest_slice_ns = @max(replay.longest_slice_ns, slice_ns);
            if (replay.next < task.turns.items.len) return .replaying;
            const projection = &replay.projection;
            if (projection.runtime.notebook.entries.items.len == 0) if (task.request.start) |empty_start| {
                // Two compactions with no turn between leave an empty cycle;
                // it is not a page of its own, so the cycle before it takes
                // its place. Each skip moves to an older compaction line, so
                // this ends.
                const v2 = agent.session_persistence.v2 orelse return error.SessionPersistenceUnavailable;
                if (cache.starts.items.len < back) return error.TranscriptArchiveUnavailable;
                cache.starts.items[back - 1] = cache.startOf(back, try v2.previousCompactionCursor(app.alloc, empty_start));
                cache.starts.shrinkRetainingCapacity(back);
                debug_trace.logf("full_transcript_cache", "archive_empty_cycle_skipped back={d}", .{back});
                return .empty_cycle_skipped;
            };
            const archived = try projection.intoArchivedRuntime();
            const entries = archived.notebook.entries.items.len;
            // A read that stops at a damaged line still shows what it read.
            const damaged = task.damaged or cache.damages(back);
            try app.shell.installTranscriptArchive(app.alloc, back, task.request.start != null, archived, damaged);
            debug_trace.logf("full_transcript_cache", "archive_loaded back={d} entries={d} damaged={} read_us={d} replay_us={d} longest_slice_us={d}", .{
                back,
                entries,
                damaged,
                @divTrunc(task.read_ns, std.time.ns_per_us),
                @divTrunc(replay.replay_ns, std.time.ns_per_us),
                @divTrunc(replay.longest_slice_ns, std.time.ns_per_us),
            });
            return .installed;
        }

        /// Whether `agent`'s transcript is the one on the screen's slot: the
        /// agent on screen, or the hidden one a visit put there.
        fn transcriptInContext(app: *App, agent: *AppAgent) bool {
            if (comptime @hasDecl(App, "screenAgent")) return app.screenAgent() == agent;
            return true;
        }

        /// Whether Ctrl+O can page into older compaction cycles: the window
        /// holds only the newest cycle, and the log holds the older ones.
        fn syncTranscriptArchiveAvailable(app: *App, agent: *AppAgent) void {
            if (comptime !@hasField(App, "shell")) return;
            if (comptime !@hasField(@TypeOf(app.shell), "transcript_archive_available")) return;
            if (!transcriptInContext(app, agent)) return;
            const v2 = agent.session_persistence.v2 orelse {
                app.shell.transcript_archive_available = false;
                return;
            };
            const newest = v2.previousCompactionCursor(app.alloc, null) catch null;
            app.shell.transcript_archive_available = if (newest) |found| found.cursor != null else false;
        }

        /// Builds the notebook of the agent in context from `history`, as
        /// resume builds main's: for a subagent's agent the first time this
        /// process shows its conversation. The projection is installed
        /// into a scratch transcript and only its slot is moved in, so the
        /// screen, which shows another agent, is untouched.
        pub fn rebuildChildView(app: *App, agent: *AppAgent, history: []const types.HistoryTurn) !void {
            if (comptime !@hasDecl(App, "installResumeProjectionInto")) return;
            var labels = HistoricalSessionLabels{ .workspace_root = app.workspace_root };
            defer labels.deinit(app.alloc);
            var projection = try app.beginResumeProjection(agent);
            defer projection.deinit();
            var sink = DetachedHistorySink(@TypeOf(projection)){
                .app = app,
                .projection = &projection,
                .labels = &labels,
            };
            const holds_previous = try replayResumedHistoryToSink(app, agent, &sink, history, &labels);
            try projection.finalize();
            var scratch: transcript_runtime.TranscriptRuntime = .{};
            defer scratch.deinit(app.alloc);
            // The scratch transcript runs the agent's window before the
            // replay is installed, as main's resume does.
            try scratch.setTranscriptWindowSaved(app.alloc, agent.session_persistence.v2 != null);
            try app.installResumeProjectionInto(agent, &projection, &scratch, holds_previous);
            var slot: transcript_runtime.TranscriptSlot = .{};
            scratch.swapSlot(&slot);
            app.shell.swapSlot(&slot);
            transcript_runtime.TranscriptRuntime.deinitSlot(&slot, app.alloc);
            syncTranscriptArchiveAvailable(app, agent);
        }

        /// True when the replayed turns are the cycle before the newest
        /// compaction, because no turn finished after it.
        fn replayResumedHistoryToSink(
            app: *App,
            agent: *AppAgent,
            sink: anytype,
            context_history: []const types.HistoryTurn,
            labels: *HistoricalSessionLabels,
        ) !bool {
            if (comptime runtime_profile.allows(App, .durable_sessions)) {
                // The screen holds the newest compaction cycle; Ctrl+O reads
                // the older ones from the log.
                if (agent.session_persistence.v2) |v2| {
                    const Visitor = struct {
                        app: *App,
                        agent: *AppAgent,
                        sink: @TypeOf(sink),
                        labels: *HistoricalSessionLabels,
                        has_prior_turns: bool = false,

                        pub fn append(self: *@This(), turn: types.HistoryTurn) !void {
                            return replayHistoryToSinkIncremental(self.app, self.agent, self.sink, &.{turn}, &self.has_prior_turns, self.labels);
                        }
                    };
                    var visitor = Visitor{ .app = app, .agent = agent, .sink = sink, .labels = labels };
                    return v2.visitHistorySinceCompaction(app.alloc, &visitor);
                }
            }
            try replayHistoryToSink(app, agent, sink, context_history, labels);
            return false;
        }

        /// Replays `history` to `sink` with the resume notice. A fork's notice
        /// names the command that reopens its source, so it follows the
        /// replay, where it stays in view however long the session is; the
        /// other notices open it. Returns what `replayResumedHistoryToSink`
        /// returns.
        fn replayWithResumeNotice(
            app: *App,
            agent: *AppAgent,
            sink: anytype,
            display: *const session_display_metadata.DisplayMetadata,
            notice: ResumeNotice,
            history: []const types.HistoryTurn,
            labels: *HistoricalSessionLabels,
        ) !bool {
            // Only a real title enters the cache: the fallback placeholder must
            // not count as an existing title, or background title generation
            // would consider the session already named and never run.
            if (display.present) try setCachedSessionTitle(app, agent, display.title);
            if (notice != .fork) try writeResumeNotice(app, sink, display, notice);
            const holds_previous = try replayResumedHistoryToSink(app, agent, sink, history, labels);
            if (notice == .fork) try writeResumeNotice(app, sink, display, notice);
            return holds_previous;
        }

        fn writeResumeNotice(
            app: *App,
            sink: anytype,
            display: *const session_display_metadata.DisplayMetadata,
            notice: ResumeNotice,
        ) !void {
            switch (notice) {
                .session => try sink.appendNotice(.{
                    .topic = "session resumed",
                    .tone = .neutral,
                    .body = display.title,
                }),
                .upgrade => |upgrade| {
                    var body: std.Io.Writer.Allocating = .init(app.alloc);
                    defer body.deinit();
                    try writeUpgradeNoticeBody(&body.writer, upgrade);
                    const owned_body = try body.toOwnedSlice();
                    defer app.alloc.free(owned_body);
                    try sink.appendNotice(.{
                        .topic = "",
                        .tone = .success,
                        .body = owned_body,
                    });
                },
                .fork => |source_id| {
                    try sink.appendNotice(.{
                        .topic = "session forked",
                        .tone = .neutral,
                        .body = display.title,
                    });
                    // Plain lines, and the command alone on its own, so
                    // selecting that line copies only the command. The blank
                    // line keeps a row between it and the input box while it
                    // is the newest entry.
                    const lines = try app.alloc.print("Resume the original session with:\nspark --resume {s}\n\n", .{source_id});
                    defer app.alloc.free(lines);
                    try sink.appendRaw(lines);
                },
            }
        }

        /// A turn that resumed an interrupted request replays as the line it
        /// showed live, not as spark's note to the model.
        fn appendHistoryUserTurn(sink: anytype, user: types.UserTurn, has_prior_turns: bool) !void {
            if (std.mem.eql(u8, user.text, session_runtime.resumed_request_prompt)) {
                return sink.appendNotice(session_runtime.resumed_request_notice);
            }
            return sink.appendUserTurn(user, has_prior_turns);
        }

        fn replayHistory(app: *App, agent: *AppAgent, history: []const types.HistoryTurn) !void {
            var sink = LiveHistorySink(App){ .app = app };
            var labels = HistoricalSessionLabels{ .workspace_root = app.workspace_root };
            defer labels.deinit(app.alloc);
            return replayHistoryToSink(app, agent, &sink, history, &labels);
        }

        fn replayHistoryToSink(
            app: *App,
            agent: *AppAgent,
            sink: anytype,
            history: []const types.HistoryTurn,
            labels: *HistoricalSessionLabels,
        ) !void {
            var has_prior_turns = false;
            return replayHistoryToSinkIncremental(app, agent, sink, history, &has_prior_turns, labels);
        }

        fn replayHistoryToSinkIncremental(
            app: *App,
            agent: *AppAgent,
            sink: anytype,
            history: []const types.HistoryTurn,
            has_prior_turns: *bool,
            labels: *HistoricalSessionLabels,
        ) !void {
            for (history) |turn| {
                switch (turn) {
                    .compacted_summary => {},
                    .assistant => |entry| {
                        if (promptTime(entry.user, entry.execution.turn_summary)) |at| sink.setCreatedAtMs(at);
                        try appendHistoryUserTurn(sink, entry.user, has_prior_turns.*);
                        has_prior_turns.* = true;
                        try writeExecutionHistoryToSink(app, agent, sink, entry.execution, labels);
                        if (entry.execution.turn_summary) |summary| {
                            sink.setCreatedAtMs(summary.completed_at_ms);
                        }
                        const final_calls = full_transcript_metadata.stepModelCalls(entry.execution.model_calls, entry.execution.tool_steps.len);
                        try writeModelCallNotices(sink, final_calls.before);
                        if (entry.assistant.len > 0) {
                            try writeAssistantHistoryMarkdownToSink(app, sink, entry.assistant);
                        }
                        try writeModelCallNotices(sink, final_calls.after);
                        if (entry.execution.turn_summary) |summary| {
                            try sink.appendTurnSummary(summary);
                        }
                    },
                    .interrupted => |entry| {
                        if (promptTime(entry.user, entry.execution.turn_summary)) |at| sink.setCreatedAtMs(at);
                        try appendHistoryUserTurn(sink, entry.user, has_prior_turns.*);
                        has_prior_turns.* = true;
                        try writeExecutionHistoryToSink(app, agent, sink, entry.execution, labels);
                        if (entry.execution.turn_summary) |summary| {
                            sink.setCreatedAtMs(summary.completed_at_ms);
                        }
                        const final_calls = full_transcript_metadata.stepModelCalls(entry.execution.model_calls, entry.execution.tool_steps.len);
                        try writeModelCallNotices(sink, final_calls.before);
                        if (entry.assistant) |assistant| {
                            if (assistant.len > 0) try writeAssistantHistoryMarkdownToSink(app, sink, assistant);
                        }
                        try writeModelCallNotices(sink, final_calls.after);
                        if (entry.cancelled_command) |presentation| {
                            try writeCancelledCommandPresentation(app, agent, sink, entry.tool_call.?, presentation, labels);
                        }
                        if (entry.tool_call) |call| {
                            try writeBridgeCallRows(app, sink, entry.execution.bridge_calls, call.id);
                        }
                        switch (entry.terminal_reason) {
                            .cancelled => if (entry.cancelled_command == null and entry.cancellation_origin == .turn) {
                                try sink.appendTurnCancellation();
                            },
                            .failed => try sink.appendNotice(
                                session_runtime.interruptedTurnNotice(entry),
                            ),
                        }
                        if (entry.execution.turn_summary) |summary| {
                            try sink.appendTurnSummary(summary);
                        }
                    },
                }
            }
        }

        /// Replay canonical session turns into a detached presentation using
        /// the exact same tool, message, markdown, diff, and command-output
        /// adapters as ordinary session resume.
        pub fn appendHistoryToDetachedProjection(
            app: *App,
            agent: *AppAgent,
            projection: anytype,
            history: []const types.HistoryTurn,
            has_prior_turns: *bool,
        ) !void {
            var labels = HistoricalSessionLabels{ .workspace_root = app.workspace_root };
            defer labels.deinit(app.alloc);
            var sink = DetachedHistorySink(@TypeOf(projection.*)){
                .app = app,
                .projection = projection,
                .labels = &labels,
            };
            return replayHistoryToSinkIncremental(
                app,
                agent,
                &sink,
                history,
                has_prior_turns,
                &labels,
            );
        }

        fn writeCancelledCommandPresentation(
            app: *App,
            agent: *AppAgent,
            sink: anytype,
            call: types.ToolCall,
            presentation: types.CancelledCommandPresentation,
            labels: *HistoricalSessionLabels,
        ) !void {
            var action_arena = std.heap.ArenaAllocator.init(app.alloc);
            defer mem_utils.deinit_arena(action_arena);
            const action = try app.describeToolActionDeniedWithAdvertised(
                agent,
                action_arena.allocator(),
                call,
                historicalSessionTarget(action_arena.allocator(), labels, call),
                "Cancelled",
                &.{},
            );
            const entry_id = try writeCompletedToolStatus(sink, .cancelled, action);
            const replayed_output = try writeCommandReplay(
                app,
                agent,
                sink,
                presentation.output_replay,
                call.id,
            );
            try sink.attachHistoricalCancelledCommandDetail(
                entry_id,
                call,
                presentation.command_artifact_handle,
                replayed_output,
            );
        }

        fn writeExecutionHistory(app: *App, agent: *AppAgent, execution: types.ExecutionMemory) !void {
            var sink = LiveHistorySink(App){ .app = app };
            var labels = HistoricalSessionLabels{ .workspace_root = app.workspace_root };
            defer labels.deinit(app.alloc);
            return writeExecutionHistoryToSink(app, agent, &sink, execution, &labels);
        }

        fn writeExecutionHistoryToSink(
            app: *App,
            agent: *AppAgent,
            sink: anytype,
            execution: types.ExecutionMemory,
            labels: *HistoricalSessionLabels,
        ) !void {
            var steering_index: usize = 0;
            for (execution.tool_steps, 0..) |step, step_index| {
                try writePersistedSteeringAtBoundary(
                    app,
                    sink,
                    execution.steering,
                    &steering_index,
                    step_index,
                );
                const calls = full_transcript_metadata.stepModelCalls(execution.model_calls, step_index);
                try writeModelCallNotices(sink, calls.before);
                if (step.assistant) |assistant| {
                    if (assistant.len > 0) try writeAssistantHistoryMarkdownToSink(app, sink, assistant);
                }
                try writeModelCallNotices(sink, calls.after);

                for (step.tool_calls) |call| {
                    if (findPersistedToolResult(step.tool_results, call.id)) |result| {
                        try writeCompletedToolResult(app, agent, sink, call, result, labels);
                        try writeBridgeCallRows(app, sink, execution.bridge_calls, call.id);
                        try writePermissionFeedback(sink, result.permission_feedback);
                    } else {
                        try writeUnreportedToolStatus(app, sink, call);
                        try writeBridgeCallRows(app, sink, execution.bridge_calls, call.id);
                    }
                }

                for (step.tool_results) |result| {
                    if (!hasPersistedToolCall(step.tool_calls, result.tool_call_id)) {
                        try writeUnpairedToolResult(app, sink, result);
                        try writePermissionFeedback(sink, result.permission_feedback);
                    }
                }
            }
            while (steering_index < execution.steering.len) : (steering_index += 1) {
                const steering = execution.steering[steering_index];
                if (steering.assistant_prefix) |prefix| {
                    if (prefix.len > 0) try writeAssistantHistoryMarkdownToSink(app, sink, prefix);
                }
                if (steering.text.len == 0 or isRecoveryPrompt(steering.text)) continue;
                try sink.appendUserTurn(savedSteeringTurn(steering.text), true);
            }
        }

        /// When a saved turn's message was sent: its own line's time, else its
        /// summary's start. A turn with neither keeps the clock it finds.
        fn promptTime(user: types.UserTurn, summary: ?types.TurnSummary) ?i64 {
            if (user.sent_at_ms > 0) return user.sent_at_ms;
            const value = summary orelse return null;
            return value.started_at_ms;
        }

        /// Writes each call record as the full-only notice Ctrl+O shows, at
        /// the time the call settled.
        fn writeModelCallNotices(sink: anytype, records: []const types.ModelCallRecord) !void {
            for (records) |record| {
                var body: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
                defer body.deinit();
                try full_transcript_metadata.writeModelCallText(&body.writer, record);
                sink.setCreatedAtMs(record.at_ms);
                try sink.appendNotice(.{
                    .topic = full_transcript_metadata.model_call_topic,
                    .tone = if (record.outcome == .failed) .@"error" else .neutral,
                    .body = body.written(),
                    .visibility = .full_only,
                });
            }
        }

        /// Whether a saved steering entry is spark's own prompt to a stalled turn,
        /// which was never on screen, so a replay leaves it out.
        fn isRecoveryPrompt(text: []const u8) bool {
            if (recovery_prompt.fromSaved(text) == null) return false;
            debug_trace.logf("session", "replay skipped a recovery prompt bytes={d}", .{text.len});
            return true;
        }

        /// A saved steering entry as the message it was: the user's update, a
        /// parent's steer as the words its parent wrote, which draw the same
        /// way, or a subagent's report a boundary took, which draws as its card.
        /// Every sink copies the text, so the turn borrows `text`.
        fn savedSteeringTurn(text: []u8) types.UserTurn {
            if (agent_frame.isFrame(text)) return .{ .text = text, .author = .child };
            // The parent's words are the end of `text`, past its label, so the
            // turn keeps the same `[]u8` slice of the saved text.
            if (runtime_execution_memory.parentSteeringText(text)) |own| {
                return .{ .text = text[text.len - own.len ..], .author = .user };
            }
            return .{ .text = text, .author = .user };
        }

        fn writePersistedSteeringAtBoundary(
            app: *App,
            sink: anytype,
            steering: []const types.PersistedSteering,
            index: *usize,
            tool_step_count: usize,
        ) !void {
            while (index.* < steering.len and
                steering[index.*].after_tool_step_count == tool_step_count)
            {
                const item = steering[index.*];
                if (item.assistant_prefix) |prefix| {
                    if (prefix.len > 0) try writeAssistantHistoryMarkdownToSink(app, sink, prefix);
                }
                if (item.text.len > 0 and !isRecoveryPrompt(item.text)) {
                    try sink.appendUserTurn(savedSteeringTurn(item.text), true);
                }
                index.* += 1;
            }
        }

        fn writePermissionFeedback(sink: anytype, feedback: []const []const u8) !void {
            for (feedback) |text| {
                if (text.len == 0) continue;
                try sink.appendUserTurn(.{
                    .text = @constCast(text),
                }, true);
            }
        }

        fn findPersistedToolResult(
            results: []const types.PersistedToolResult,
            tool_call_id: []const u8,
        ) ?types.PersistedToolResult {
            for (results) |result| {
                if (std.mem.eql(u8, result.tool_call_id, tool_call_id)) return result;
            }
            return null;
        }

        fn hasPersistedToolCall(
            calls: []const types.ToolCall,
            tool_call_id: []const u8,
        ) bool {
            for (calls) |call| {
                if (std.mem.eql(u8, call.id, tool_call_id)) return true;
            }
            return false;
        }

        fn writeCompletedToolResult(
            app: *App,
            agent: *AppAgent,
            sink: anytype,
            call: types.ToolCall,
            result: types.PersistedToolResult,
            labels: *HistoricalSessionLabels,
        ) !void {
            try labels.saved_output_sources.record(
                app.alloc,
                app.toolAdvertisementSet(agent).registry,
                labels.workspace_root,
                call,
                result,
            );
            if (try writeAnsweredQuestionResult(app, sink, call, result)) return;
            if (try writeCommittedFilePresentation(app, agent, sink, call, result)) return;

            const is_command = try captured_command.isToolCall(
                app.alloc,
                call.name,
                call.arguments_json,
            );
            const context_deferred = types.isContextDeferredToolResult(result);
            const deferred = types.isDeferredToolResult(result);
            const permission_denial_reason = tool_result_errors.toolPermissionDenialReason(result.output);

            var action_arena = std.heap.ArenaAllocator.init(app.alloc);
            defer mem_utils.deinit_arena(action_arena);
            const action_target = historicalSessionTarget(action_arena.allocator(), labels, call) orelse
                try tool_presentation.readToolResultDisplayTarget(
                    action_arena.allocator(),
                    app.toolAdvertisementSet(agent).registry,
                    call,
                    &labels.saved_output_sources,
                );
            const command_decision = if (is_command)
                try tool_presentation.commandOutcomeDecision(
                    action_arena.allocator(),
                    result.command_process_presentation,
                )
            else
                null;
            const terminal_action_decision = if (std.mem.eql(u8, call.name, "terminal"))
                try tool_presentation.terminalActionOutcomeDecision(
                    action_arena.allocator(),
                    result.terminal_action_presentation,
                )
            else
                null;
            // A shell run that returned its command running, captured or tty,
            // has no exit status and reads "Still running", as it did live.
            const outcome_decision = command_decision orelse terminal_action_decision orelse
                try tool_presentation.runningCommandDecision(action_arena.allocator(), call, result.output);
            const formatted_action_base = if (deferred)
                try app.describeToolActionDeniedWithAdvertised(
                    agent,
                    action_arena.allocator(),
                    call,
                    action_target,
                    if (context_deferred)
                        types.context_deferred_tool_status_label
                    else
                        types.deferred_tool_result_output,
                    &.{},
                )
            else if (permission_denial_reason) |reason|
                try app.describeToolActionDeniedWithAdvertised(
                    agent,
                    action_arena.allocator(),
                    call,
                    action_target,
                    tool_admission.permissionDeniedStatusLabel(reason),
                    &.{},
                )
            else if (outcome_decision) |decision|
                try app.describeToolActionDeniedWithAdvertised(
                    agent,
                    action_arena.allocator(),
                    call,
                    action_target,
                    decision.label,
                    &.{},
                )
            else if (try tooling_presentation.subagentStatusLine(action_arena.allocator(), call, result.output)) |line|
                line
            else if (result.status == .success)
                try app.describeToolActionCompletedWithAdvertised(
                    agent,
                    action_arena.allocator(),
                    call,
                    action_target,
                    &.{},
                )
            else
                try app.describeToolActionDeniedWithAdvertised(
                    agent,
                    action_arena.allocator(),
                    call,
                    action_target,
                    try tooling_presentation.subagentFailureLabel(action_arena.allocator(), call, result.output),
                    &.{},
                );
            const formatted_action = if (outcome_decision) |decision|
                if (decision.detail) |detail|
                    try action_arena.allocator().print(
                        "{s}: {s}",
                        .{ formatted_action_base, detail },
                    )
                else
                    formatted_action_base
            else
                formatted_action_base;
            const action = try app.alloc.dupe(u8, formatted_action);
            defer app.alloc.free(action);

            const outcome: types.ToolOutcomeKind = if (context_deferred)
                .deferred
            else if (deferred or permission_denial_reason != null)
                .denied
            else if (outcome_decision) |decision|
                decision.outcome
            else if (result.status == .success)
                .completed
            else
                .failed;
            // tty runs are not captured commands but still own a live session
            // with a launch command worth recording for later session rows.
            if (outcome == .completed and (is_command or std.mem.eql(u8, call.name, "shell"))) {
                try recordHistoricalSessionLabel(app, labels, call, result);
            }
            const entry_id = try writeCompletedToolStatus(
                sink,
                outcome,
                action,
            );
            if (!is_command or deferred or permission_denial_reason != null) {
                try sink.attachHistoricalToolDetail(entry_id, call, result);
                return;
            }
            if (!sink.materializeCommandReplay()) {
                try sink.attachHistoricalToolDetail(entry_id, call, result);
                return;
            }
            const wrote_command_output =
                try writeCommandReplay(
                    app,
                    agent,
                    sink,
                    result.command_output_replay,
                    result.tool_call_id,
                ) or
                try writeStoredCommandOutput(app, agent, sink, result) or
                try writeSavedCommandOutput(sink, result.output);
            // Attach terminal detail after historical command chunks so typed
            // process presentation joins the existing block instead of
            // synthesizing a second, empty command-output block.
            if (wrote_command_output) {
                try sink.attachHistoricalToolDetailAfterCommandOutput(
                    entry_id,
                    call,
                    result,
                );
            } else {
                try sink.attachHistoricalToolDetail(entry_id, call, result);
            }
            if (wrote_command_output) {
                sink.attachHistoricalCommandOutput(entry_id);
                return;
            }

            debug_trace.logf(
                "session",
                "resume command replay fell back to raw result call_id={s}",
                .{result.tool_call_id},
            );
            try writeReplayResultFallback(sink, result.output);
        }

        fn writeCommandReplay(
            app: *App,
            agent: *AppAgent,
            sink: anytype,
            replay_value: ?types.CommandOutputReplay,
            call_id: []const u8,
        ) !bool {
            const replay = replay_value orelse return false;
            const descriptor = switch (replay) {
                .available => |value| value,
                .unavailable => {
                    debug_trace.logf(
                        "session",
                        "resume command replay unavailable call_id={s}",
                        .{call_id},
                    );
                    return false;
                },
            };
            if (agent.session_persistence.v2 == null) return false;
            const capability = activeChildCapability(agent) catch |err| {
                debug_trace.logf(
                    "session",
                    "resume command replay capability unavailable handle_bytes={d} err={s}",
                    .{ descriptor.handle.len, @errorName(err) },
                );
                return false;
            };
            if (!validateCommandReplay(app.alloc, capability, descriptor)) {
                debug_trace.logf(
                    "session",
                    "resume command replay invalid handle_bytes={d}",
                    .{descriptor.handle.len},
                );
                return false;
            }

            var reader = command_replay_store.Reader.open(
                app.alloc,
                capability,
                descriptor,
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "resume command replay reopen failed handle_bytes={d} err={s}",
                    .{ descriptor.handle.len, @errorName(err) },
                );
                return false;
            };
            defer reader.deinit();
            var wrote = false;
            while (try reader.next(app.alloc)) |frame| {
                defer app.alloc.free(frame.payload);
                try sink.appendCommandOutput(frame.stream, frame.payload);
                wrote = true;
            }
            if (wrote) try sink.finishCommandOutput();
            return wrote;
        }

        fn validateCommandReplay(
            alloc: Allocator,
            capability: *session_child_store.SessionChildCapability,
            descriptor: types.CommandOutputReplayDescriptor,
        ) bool {
            var reader = command_replay_store.Reader.open(
                alloc,
                capability,
                descriptor,
            ) catch return false;
            defer reader.deinit();
            while (reader.nextByte() catch return false) |_| {}
            return true;
        }

        /// Builds the full review of a resumed edit the first time it is
        /// opened, from the spilled snapshots. Runs at most once per entry. A
        /// missing or corrupt artifact leaves only the preview and never
        /// fails; the full-diff expansion is simply absent. The built diff is
        /// owned by `entry` and allocated with `std.heap.c_allocator`.
        pub fn materializeDeferredDiff(
            app: *App,
            agent: *AppAgent,
            entry: *diff.DiffEntry,
            styles: diff.FormatStyles,
        ) void {
            const deferred = entry.deferred orelse return;
            entry.deferred = null;
            defer deferred.deinit(std.heap.c_allocator);
            const capability = childCapability(agent) orelse {
                debug_trace.logf(
                    "session",
                    "event=diff_content_unavailable call_id={s} reason=no_session",
                    .{deferred.call_id},
                );
                return;
            };
            var pack = result_store.loadDiffContentManaged(
                app.alloc,
                capability,
                deferred.call_id,
                deferred.content_handle,
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=diff_content_unavailable call_id={s} err={s}; preview only",
                    .{ deferred.call_id, @errorName(err) },
                );
                return;
            };
            defer pack.deinit(app.alloc);
            const after = pack.after_content orelse return;
            entry.full = diff.formatFileChangeFullDiff(
                std.heap.c_allocator,
                pack.previous_content,
                .{ .after_content = after, .lifecycle_id = deferred.lifecycle_id },
                styles,
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=diff_content_unavailable call_id={s} err={s}; preview only",
                    .{ deferred.call_id, @errorName(err) },
                );
                return;
            };
            debug_trace.logf(
                "session",
                "event=diff_content_loaded call_id={s} previous_bytes={d} after_bytes={d}",
                .{
                    deferred.call_id,
                    if (pack.previous_content) |content| content.len else 0,
                    after.len,
                },
            );
        }

        fn writeCommittedFilePresentation(
            app: *App,
            agent: *AppAgent,
            sink: anytype,
            call: types.ToolCall,
            result: types.PersistedToolResult,
        ) !bool {
            const presentation = result.committed_file_presentation orelse return false;
            if (result.status != .success or
                (!std.mem.eql(u8, result.tool_name, "write_file") and
                    !std.mem.eql(u8, result.tool_name, "edit_file")) or
                !@hasDecl(App, "preparePersistedFileDiff") or
                !@hasDecl(App, "registerAndEmitDiffBlock")) return false;

            // Spilled snapshots stay on disk: the transcript renders the inline
            // preview, and the full review is built only when it is opened.
            var deferred: ?diff.DeferredFullDiff = null;
            if (presentation.content_handle) |handle| {
                if (presentation.lifecycle_id) |lifecycle_id| {
                    if (presentation.previous_content == null or presentation.after_content == null) {
                        deferred = try diff.DeferredFullDiff.clone(
                            std.heap.c_allocator,
                            result.tool_call_id,
                            handle,
                            lifecycle_id,
                        );
                    }
                }
            }

            var payload = app.preparePersistedFileDiff(presentation) catch |err| {
                if (deferred) |value| value.deinit(std.heap.c_allocator);
                debug_trace.logf(
                    "session",
                    "resume committed file presentation unavailable call_id={s} err={s}",
                    .{ result.tool_call_id, @errorName(err) },
                );
                return false;
            };
            payload.deferred = deferred;
            var owns_payload = true;
            errdefer if (owns_payload) diff.freeDiffEntryPayload(std.heap.c_allocator, payload);

            var action_arena = std.heap.ArenaAllocator.init(app.alloc);
            defer mem_utils.deinit_arena(action_arena);
            const base = try app.describeToolActionCompletedWithAdvertised(
                agent,
                action_arena.allocator(),
                call,
                presentation.path,
                &.{},
            );
            const action = try tool_presentation.formatToolStatusWithStats(
                action_arena.allocator(),
                base,
                presentation.additions,
                presentation.deletions,
                .{
                    .added = ui_render.diff_added_marker_style,
                    .removed = ui_render.diff_removed_marker_style,
                },
            );
            const entry_id = try writeCompletedToolStatus(sink, .completed, action);
            try sink.appendDiff(payload);
            owns_payload = false;

            if (presentation.lifecycle_id) |lifecycle_id| {
                try sink.attachHistoricalToolDetailWithLifecycle(
                    entry_id,
                    call,
                    result,
                    lifecycle_id,
                );
                return true;
            }
            try sink.attachHistoricalToolDetail(entry_id, call, result);
            return true;
        }

        fn writeAnsweredQuestionResult(
            app: *App,
            sink: anytype,
            call: types.ToolCall,
            result: types.PersistedToolResult,
        ) !bool {
            if (result.status != .success or
                !std.mem.eql(u8, result.tool_name, "ask_user_question") or
                !@hasDecl(App, "writeHistoricalQuestionResolution")) return false;

            var answer_arena = std.heap.ArenaAllocator.init(app.alloc);
            defer mem_utils.deinit_arena(answer_arena);
            const answers = (try question_answer.decodeJson(
                answer_arena.allocator(),
                result.output,
            )) orelse return false;

            const entry_id = try sink.appendQuestionResolution(answers);
            try sink.attachHistoricalToolDetail(entry_id, call, result);
            return true;
        }

        fn writeStoredCommandOutput(
            app: *App,
            agent: *AppAgent,
            sink: anytype,
            result: types.PersistedToolResult,
        ) !bool {
            const handle = result.output_handle orelse return false;
            if (agent.session_persistence.v2 == null) return false;
            const capability = activeChildCapability(agent) catch |err| {
                debug_trace.logf(
                    "session",
                    "resume command replay could not open result handle={s} err={s}",
                    .{ handle, @errorName(err) },
                );
                return false;
            };
            const output = result_store.readForReplayManaged(
                app.alloc,
                capability,
                handle,
                result.stored_output_bytes,
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "resume command replay could not read result handle={s} err={s}",
                    .{ handle, @errorName(err) },
                );
                return false;
            };
            defer app.alloc.free(output);
            return writeSavedCommandOutput(sink, output);
        }

        fn writeUnreportedToolStatus(
            app: *App,
            sink: anytype,
            call: types.ToolCall,
        ) !void {
            const status = try app.alloc.print(
                "● Tool completion was not reported: {s}",
                .{call.name},
            );
            defer app.alloc.free(status);
            const entry_id = try writeCompletedToolStatus(sink, .failed, status);
            try sink.attachHistoricalToolCallWithoutResult(entry_id, call);
        }

        fn writeUnpairedToolResult(
            app: *App,
            sink: anytype,
            result: types.PersistedToolResult,
        ) !void {
            const status = try app.alloc.print(
                "● {s} tool result: {s}",
                .{ @tagName(result.status), result.tool_name },
            );
            defer app.alloc.free(status);
            _ = try writeCompletedToolStatus(sink, switch (result.status) {
                .success => .completed,
                .failure => .failed,
            }, status);
            try writeReplayResultFallback(sink, result.output);
        }

        fn writeCompletedToolStatus(
            sink: anytype,
            kind: types.ToolOutcomeKind,
            status: []const u8,
        ) !u32 {
            return sink.appendToolStatus(kind, status);
        }

        /// Writes the row of each call that the command of shell call
        /// `call_id` made through `spark mcp call`, as its live row ended, right
        /// after the shell call's row, so the two share a group again (D99).
        fn writeBridgeCallRows(
            app: *App,
            sink: anytype,
            records: []const types.BridgeCallRecord,
            call_id: []const u8,
        ) !void {
            for (records) |record| {
                if (!std.mem.eql(u8, record.call_id, call_id)) continue;
                const status = try tooling_presentation.bridgeCallRowSummary(app.alloc, record.tool, record.outcome);
                defer app.alloc.free(status);
                const kind = record.outcome.toolOutcome();
                const entry_id = try writeCompletedToolStatus(sink, kind, status);
                try sink.attachHistoricalBridgeCall(entry_id, record.tool, kind);
            }
        }

        fn writeSavedCommandOutput(sink: anytype, output: []const u8) !bool {
            var wrote = false;
            wrote = try writeCommandEnvelope(sink, output, "<stdout>\n", "\n</stdout>", .stdout) or wrote;
            wrote = try writeCommandEnvelope(sink, output, "<stderr>\n", "\n</stderr>", .stderr) or wrote;
            if (wrote) try sink.finishCommandOutput();
            return wrote;
        }

        fn writeCommandEnvelope(
            sink: anytype,
            output: []const u8,
            open: []const u8,
            close: []const u8,
            stream: command_output_content.Stream,
        ) !bool {
            const text = envelopeBody(output, open, close) orelse return false;
            if (text.len == 0) return false;
            var remaining = text;
            while (std.mem.findScalar(u8, remaining, '\n')) |newline_index| {
                try sink.appendCommandOutput(stream, remaining[0 .. newline_index + 1]);
                remaining = remaining[newline_index + 1 ..];
            }
            if (remaining.len > 0) try sink.appendCommandOutput(stream, remaining);
            return true;
        }

        fn envelopeBody(output: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
            const start = std.mem.find(u8, output, open) orelse return null;
            const body = output[start + open.len ..];
            const end = std.mem.find(u8, body, close) orelse return null;
            return body[0..end];
        }

        fn writeReplayResultFallback(sink: anytype, output: []const u8) !void {
            if (output.len == 0) return;
            try sink.appendRaw(output);
            if (!std.mem.endsWith(u8, output, "\n")) try sink.appendRaw("\n");
        }

        fn AssistantHistoryMarkdownReplay(comptime Sink: type) type {
            return struct {
                sink: *Sink,

                const Self = @This();

                fn flushText(self: *Self, out: *std.ArrayList(u8)) !void {
                    if (out.items.len == 0) return;
                    try self.sink.appendAssistantText(out.items);
                    out.clearRetainingCapacity();
                }

                fn deliverTable(
                    raw: *anyopaque,
                    table: assistant_presentation.TablePayload,
                    out: *std.ArrayList(u8),
                ) anyerror!void {
                    const self: *Self = @ptrCast(@alignCast(raw));
                    try self.flushText(out);
                    try self.sink.appendAssistantTable(table);
                }

                fn deliverCodeBlock(
                    raw: *anyopaque,
                    block: assistant_presentation.CodeBlockPayload,
                    out: *std.ArrayList(u8),
                ) anyerror!void {
                    const self: *Self = @ptrCast(@alignCast(raw));
                    try self.flushText(out);
                    try self.sink.appendAssistantCodeBlock(block);
                }

                fn deliverThematicRule(
                    raw: *anyopaque,
                    out: *std.ArrayList(u8),
                ) anyerror!void {
                    const self: *Self = @ptrCast(@alignCast(raw));
                    try self.flushText(out);
                    try self.sink.appendAssistantThematicRule();
                }
            };
        }

        fn writeAssistantHistoryMarkdown(app: *App, text: []const u8) !void {
            var sink = LiveHistorySink(App){ .app = app };
            return writeAssistantHistoryMarkdownToSink(app, &sink, text);
        }

        fn writeAssistantHistoryMarkdownToSink(
            app: *App,
            sink: anytype,
            text: []const u8,
        ) !void {
            var processor = assistant_presentation.MarkdownProcessor{};
            defer processor.deinit(app.alloc);
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(app.alloc);
            const Sink = @TypeOf(sink.*);
            const Replay = AssistantHistoryMarkdownReplay(Sink);
            var replay = Replay{ .sink = sink };
            var table_completion = assistant_presentation.TableCompletion{
                .ctx = &replay,
                .deliver = Replay.deliverTable,
            };
            var code_completion = assistant_presentation.CodeBlockCompletion{
                .ctx = &replay,
                .deliver = Replay.deliverCodeBlock,
            };
            var thematic_rule_completion = assistant_presentation.ThematicRuleCompletion{
                .ctx = &replay,
                .deliver = Replay.deliverThematicRule,
            };
            const completions = assistant_presentation.MarkdownCompletions{
                .table = &table_completion,
                .code = &code_completion,
                .thematic_rule = &thematic_rule_completion,
            };

            try processor.pushWithCompletions(app.alloc, text, &out, completions);
            try processor.flushWithCompletions(app.alloc, &out, completions);
            try replay.flushText(&out);
            try sink.appendAssistantText("\n");
        }

        fn closeWritableSession(app: *App, agent: *AppAgent) void {
            agent.session_persistence.resume_handoff_intent = .none;
            _ = closeWritableSessionWithResumeHandoff(app, agent);
        }

        fn closeWritableSessionWithResumeHandoff(app: *App, agent: *AppAgent) ?ResumeHandoff {
            const handoff_intent = agent.session_persistence.resume_handoff_intent;
            agent.session_persistence.resume_handoff_intent = .none;
            agent.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer agent.session_persistence.write_mutex.unlock(io_mod.getIo());
            discardAnyPendingCancelledCommand(app, agent, "writable_session_close");
            if (agent.session_persistence.v2) |v2| return closeV2Session(app, agent, v2, handoff_intent);
            return null;
        }

        /// Closes; the manager ends an open turn as `closed`, and a session
        /// with no turn leaves nothing on disk (D2).
        fn closeV2Session(app: *App, agent: *AppAgent, v2: *session_adapter.Session, handoff_intent: ResumeHandoffIntent) ?ResumeHandoff {
            const create_handoff = shouldCreateResumeHandoff(.{
                .intent = handoff_intent,
                .has_writable_session = true,
                .is_pristine = !v2.saved(),
            });
            const handoff: ?ResumeHandoff = if (create_handoff) blk: {
                const session_id = app.alloc.dupe(u8, v2.id()) catch |err| {
                    debug_trace.logf("session", "resume handoff unavailable session={s} err={s}", .{ v2.id(), @errorName(err) });
                    break :blk null;
                };
                break :blk .{ .session_id = session_id };
            } else null;
            if (comptime @hasDecl(@TypeOf(agent.session), "clearWebFetchArtifacts")) {
                agent.session.clearWebFetchArtifacts();
            }
            disableSubagentHost(app, agent);
            v2.close();
            agent.session_persistence.v2 = null;
            return handoff;
        }

        /// Subagents on v2 keep their state in the session's log (D22). A
        /// host that cannot start leaves them off and says why, as on v1.
        fn enableSubagentHostV2(app: *App, agent: *AppAgent, v2: *session_adapter.Session) void {
            disableSubagentHost(app, agent);
            const children = app.alloc.create(subagent_child_state.V2Children) catch |err| {
                debug_trace.logf("session", "interactive subagent host unavailable session={s} err={s}", .{ v2.id(), @errorName(err) });
                return;
            };
            children.* = subagent_child_state.V2Children.init(app.alloc, v2, app.workspace_root);
            agent.session_persistence.subagent_host = subagent_tool_host.Runtime.create(
                app.alloc,
                children,
                subagentAuthorityResolver(app),
                if (comptime @hasDecl(App, "runSubagentChild"))
                    .{ .context = app, .bind_fn = App.bindSubagentWorker, .run_fn = App.runSubagentChild }
                else
                    .{},
            ) catch |err| {
                debug_trace.logf("session", "interactive subagent host unavailable session={s} err={s}", .{ v2.id(), @errorName(err) });
                children.deinit();
                app.alloc.destroy(children);
                return;
            };
            agent.session_persistence.v2_children = children;
            bindToolboxBehind(app, agent.session_persistence.subagent_host.?);
            // Its children report to this agent, through the main loop.
            if (comptime @hasDecl(App, "postSubagentReport")) {
                const host = agent.session_persistence.subagent_host.?;
                host.report_sink = .{ .context = app, .post_fn = App.postSubagentReport };
                // A subagent's own host can message the subagent's parent,
                // and its children are as deep as spark nests.
                host.owner_has_parent = agent.role == .subagent;
                host.authority_resolver.children_nest = agent.role != .subagent;
                // What a restart left owed reaches this agent now.
                host.resumeReports(v2);
            }
        }

        fn subagentAuthorityResolver(app: *App) subagent_authority.HostResolver {
            return .{
                .context = app,
                .resolve_fn = resolveSubagentAuthority,
                .child_permission_mode_fn = subagentOwnPermissionMode,
                .parent_permission_mode_fn = subagentParentPermissionMode,
                .base_fn = resolveSubagentBase,
            };
        }

        /// The permission mode agent `parent_id` works in now, which its
        /// subagents follow unless their own screen or profile sets one: an
        /// instance's own, or a subagent's as the host that started it
        /// resolves it. A subagent parent whose mode can't be resolved gives
        /// ask, so no child runs looser than its parent. Null for an id that
        /// is neither, whose children's authority doesn't resolve anyway.
        fn subagentParentPermissionMode(raw: ?*anyopaque, alloc: Allocator, parent_id: []const u8) ?types.PermissionMode {
            const app: *App = @ptrCast(@alignCast(raw.?));
            if (parentResolverOf(app, parent_id)) |parent| return parent.currentMode(alloc, parent_id) catch |err| {
                debug_trace.logf("subagent", "parent permission mode unavailable parent={s} err={s}; using full access", .{ parent_id, @errorName(err) });
                return .yolo;
            };
            if (comptime @hasField(App, "authority_mutex")) {
                app.authority_mutex.lockUncancelable(io_mod.getIo());
            }
            defer if (comptime @hasField(App, "authority_mutex")) {
                app.authority_mutex.unlock(io_mod.getIo());
            };
            _ = instanceWithSession(app, parent_id) orelse return null;
            return .yolo;
        }

        /// spark's own tools, MCP integrations, and MCP view, before any
        /// profile, for a subagent whose profile decides them. Configured
        /// denies still remove tools here, as they do for every agent.
        fn resolveSubagentBase(
            raw: ?*anyopaque,
            alloc: Allocator,
            root_id: []const u8,
        ) subagent_authority.HostResolveError!subagent_authority.HostAuthority {
            const app: *App = @ptrCast(@alignCast(raw.?));
            if (comptime @hasField(App, "authority_mutex")) {
                app.authority_mutex.lockUncancelable(io_mod.getIo());
            }
            defer if (comptime @hasField(App, "authority_mutex")) {
                app.authority_mutex.unlock(io_mod.getIo());
            };
            const integrations = if (comptime @hasDecl(App, "snapshotMcpToolNames"))
                try app.snapshotMcpToolNames(alloc)
            else
                try alloc.alloc([]u8, 0);
            defer {
                for (integrations) |name| alloc.free(name);
                alloc.free(integrations);
            }
            var mcp_view: ?mcp_access.View = if (comptime @hasDecl(App, "snapshotMcpAccessView"))
                try app.snapshotMcpAccessView(alloc, root_id, root_id)
            else
                null;
            defer if (mcp_view) |*view| view.deinit(alloc);
            return subagent_tool_host.captureHostAuthorityWithMcpView(
                alloc,
                .{
                    .tool_set = if (comptime @hasDecl(App, "baseToolSet")) app.baseToolSet() else app.toolAdvertisementSet(&app.main_agent),
                    .mode = .full,
                },
                integrations,
                if (mcp_view) |*view| view else null,
            );
        }

        /// The permission mode the user chose on subagent `child_id`'s own
        /// screen, if any. Main's authority lock guards it and the list
        /// of subagents, for the slot and worker threads that resolve here.
        fn subagentOwnPermissionMode(raw: ?*anyopaque, child_id: []const u8) ?types.PermissionMode {
            if (comptime !@hasField(App, "child_agents")) return null;
            const app: *App = @ptrCast(@alignCast(raw.?));
            app.authority_mutex.lockUncancelable(io_mod.getIo());
            defer app.authority_mutex.unlock(io_mod.getIo());
            for (app.child_agents.items) |child| {
                if (child.agent.role != .subagent) continue;
                if (std.mem.eql(u8, child.id, child_id)) return child.agent.permission_mode;
            }
            return null;
        }

        /// The resolver of the host that started subagent `root_id`, when
        /// `root_id` is a subagent rather than an instance.
        fn parentResolverOf(app: *App, root_id: []const u8) ?*subagent_authority.Resolver {
            if (comptime !@hasField(App, "child_agents")) return null;
            app.authority_mutex.lockUncancelable(io_mod.getIo());
            defer app.authority_mutex.unlock(io_mod.getIo());
            for (app.child_agents.items) |child| {
                if (!std.mem.eql(u8, child.id, root_id)) continue;
                const host = child.parent_host orelse return null;
                return host.authorityResolver();
            }
            return null;
        }

        /// The instance whose own session is `root_id`, the first or a launched
        /// one, or null. Call under the authority lock, which guards the list
        /// of hosted agents.
        fn instanceWithSession(app: *App, root_id: []const u8) ?*AppAgent {
            if (app.main_agent.session_persistence.v2) |v2| if (std.mem.eql(u8, v2.id(), root_id)) return &app.main_agent;
            if (comptime @hasField(App, "child_agents")) {
                for (app.child_agents.items) |child| {
                    if (child.agent.role != .instance) continue;
                    const v2 = child.agent.session_persistence.v2 orelse continue;
                    if (std.mem.eql(u8, v2.id(), root_id)) return &child.agent;
                }
            }
            return null;
        }

        /// A subagent's authority as the parent of its own subagents:
        /// its own, as the host that started it resolves it, so a nested
        /// subagent never holds what its parent lacks. The mode is not part of
        /// it: each of its subagents reads the parent's current mode through
        /// `subagentParentPermissionMode`.
        fn subagentRootAuthority(
            alloc: Allocator,
            parent: *subagent_authority.Resolver,
            root_id: []const u8,
        ) subagent_authority.HostResolveError!subagent_authority.HostAuthority {
            var snapshot = parent.resolveForUser(alloc, root_id, .yolo) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.HostAuthorityUnavailable,
            };
            defer snapshot.deinit(alloc);
            return try subagent_authority.HostAuthority.captureWithMcpView(
                alloc,
                snapshot.tools,
                snapshot.integrations,
                if (snapshot.mcp_view) |*view| view else null,
            );
        }

        fn resolveSubagentAuthority(
            raw: ?*anyopaque,
            alloc: Allocator,
            root_id: []const u8,
        ) subagent_authority.HostResolveError!subagent_authority.HostAuthority {
            const app: *App = @ptrCast(@alignCast(raw.?));
            if (parentResolverOf(app, root_id)) |parent| return subagentRootAuthority(alloc, parent, root_id);
            // The root is an instance, the first or a launched one, and its
            // tree starts from its authority, whichever thread resolves it: a
            // slot thread capturing an admission, or a child's worker checking
            // a tool call. The instance's own profile narrows its tools here too.
            if (comptime @hasField(App, "authority_mutex")) {
                app.authority_mutex.lockUncancelable(io_mod.getIo());
            }
            defer if (comptime @hasField(App, "authority_mutex")) {
                app.authority_mutex.unlock(io_mod.getIo());
            };
            const instance = instanceWithSession(app, root_id) orelse return error.HostAuthorityUnavailable;
            const integrations = if (comptime @hasDecl(App, "snapshotMcpToolNames"))
                try app.snapshotMcpToolNames(alloc)
            else
                try alloc.alloc([]u8, 0);
            defer {
                for (integrations) |name| alloc.free(name);
                alloc.free(integrations);
            }
            var mcp_view: ?mcp_access.View = if (comptime @hasDecl(App, "snapshotMcpAccessView"))
                try app.snapshotMcpAccessView(alloc, root_id, root_id)
            else
                null;
            defer if (mcp_view) |*view| view.deinit(alloc);
            var authority = try subagent_tool_host.captureHostAuthorityWithMcpView(
                alloc,
                .{
                    .tool_set = app.toolAdvertisementSet(instance),
                    .mode = .full,
                },
                integrations,
                if (mcp_view) |*view| view else null,
            );
            errdefer authority.deinit(alloc);
            // The instance's own profile narrows the MCP servers its tree starts
            // from, as it narrows the tools above.
            if (comptime agents.hasAgentField(App, "profile")) {
                try subagent_authority.narrowHostToMcpServers(alloc, &authority, &instance.profile.profile);
            }
            return authority;
        }

        pub fn commitContextCompaction(
            app: *App,
            agent: *AppAgent,
            summary: types.CompactedSummaryHistoryTurn,
            active_prefix: ?types.AssistantHistoryTurn,
            retained_from: ?types.ContextHistoryCut,
        ) !void {
            const prepared = try session_runtime.prepareCompactedHistory(app.alloc, agent.session.agent.history.items, summary, retained_from orelse .{ .turns = history_range.rawHistoryTurnCount(agent.session.agent.history.items) });
            var prepared_owned = true;
            defer if (prepared_owned) types.freeHistoryTurnSlice(app.alloc, prepared);
            // A child's own agent holds its session, so its compaction
            // is saved here like main's.
            if (comptime agents.hasAgentField(App, "session_persistence")) {
                agent.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
                defer agent.session_persistence.write_mutex.unlock(io_mod.getIo());
                if (agent.session_persistence.v2) |v2| {
                    try v2.commitCompaction(summary, active_prefix != null, retained_from);
                } else if (agent.session_persistence.js_host_session) |*owner| {
                    var next = try snapshotCurrentState(app, agent, owner.state, io_mod.milliTimestamp());
                    var next_owned = true;
                    defer if (next_owned) next.deinit(app.alloc);
                    const history = try session_runtime.snapshotOwnedContextHistory(app.alloc, prepared, 0, 0);
                    types.freeHistoryTurnSlice(app.alloc, next.history);
                    next.history = history;
                    next.context_history_start = 0;
                    const revision = try agent.session_persistence.js_host_store.commit(app.alloc, next, owner.revision);
                    if (owner.revision) |old| app.alloc.free(old);
                    owner.state.deinit(app.alloc);
                    owner.state = next;
                    owner.revision = revision;
                    next_owned = false;
                }
            }
            agent.session.commitCompactedHistory(app.alloc, prepared);
            prepared_owned = false;
            if (comptime @hasField(App, "shell")) {
                if (comptime @hasDecl(@TypeOf(app.shell), "transcriptWindowCompacted")) {
                    if (transcriptInContext(app, agent)) try app.shell.transcriptWindowCompacted(app.alloc);
                    syncTranscriptArchiveAvailable(app, agent);
                }
            }
        }

        fn commitJsHostSnapshot(app: *App, agent: *AppAgent, boundary: []const u8) void {
            if (comptime !agents.hasAgentField(App, "session_persistence")) return;
            if (comptime !runtime_profile.allows(App, .js_host_sessions)) return;
            commitJsHostSnapshotEnabled(app, agent, boundary);
        }

        fn commitJsHostSnapshotEnabled(app: *App, agent: *AppAgent, boundary: []const u8) void {
            agent.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer agent.session_persistence.write_mutex.unlock(io_mod.getIo());
            const owner = if (agent.session_persistence.js_host_session) |*value|
                value
            else
                return;
            var next = snapshotCurrentState(
                app,
                agent,
                owner.state,
                io_mod.milliTimestamp(),
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=js_host_session_commit outcome=dropped boundary={s} id={s} err={s}",
                    .{ boundary, owner.state.id, @errorName(err) },
                );
                return;
            };
            var next_owned = true;
            defer if (next_owned) next.deinit(app.alloc);
            const revision = agent.session_persistence.js_host_store.commit(
                app.alloc,
                next,
                owner.revision,
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=js_host_session_commit outcome=dropped boundary={s} id={s} expected_revision={s} err={s}",
                    .{
                        boundary,
                        owner.state.id,
                        owner.revision orelse "",
                        @errorName(err),
                    },
                );
                return;
            };

            if (owner.revision) |old_revision| app.alloc.free(old_revision);
            owner.state.deinit(app.alloc);
            owner.state = next;
            owner.revision = revision;
            next_owned = false;
        }

        fn snapshotCurrentState(
            app: *App,
            agent: *AppAgent,
            base_state: session_codec.DurableSessionState,
            now_ms: i64,
        ) !session_codec.DurableSessionState {
            const preferences = agent.session_persistence.session_preferences orelse
                base_state.preferences;
            const id = try app.alloc.dupe(u8, base_state.id);
            errdefer app.alloc.free(id);
            const origin = try app.alloc.dupe(
                u8,
                base_state.origin_workspace_root,
            );
            errdefer app.alloc.free(origin);
            const workspace = try app.alloc.dupe(u8, app.workspace_root);
            errdefer app.alloc.free(workspace);
            const owned_preferences = try preferences.dupe(app.alloc);
            errdefer {
                var value = owned_preferences;
                value.deinit(app.alloc);
            }
            const history = try agent.session.snapshotHistory(app.alloc);
            errdefer session_runtime.freeHistoryTurnSlice(app.alloc, history);
            const recovery_checkpoint = if (base_state.recovery_checkpoint) |checkpoint|
                try checkpoint.dupe(app.alloc)
            else
                null;
            errdefer if (recovery_checkpoint) |*checkpoint| checkpoint.deinit(app.alloc);
            return .{
                .id = id,
                .origin_workspace_root = origin,
                .workspace_root = workspace,
                .created_at_ms = base_state.created_at_ms,
                .updated_at_ms = now_ms,
                .conversation_language = agent.session.languageSnapshot(),
                .preferences = owned_preferences,
                .history = history,
                .total_input_tokens = agents.loadTotal(&agent.total_input_tokens),
                .total_output_tokens = agents.loadTotal(&agent.total_output_tokens),
                .recovery_checkpoint = recovery_checkpoint,
            };
        }

        fn freshState(
            app: *App,
            agent: *AppAgent,
            preferences: session_codec.DurableSessionPreferences,
        ) !session_codec.DurableSessionState {
            const now = io_mod.milliTimestamp();
            const id = try session_store.generateSessionId(app.alloc);
            errdefer app.alloc.free(id);
            const origin = try app.alloc.dupe(u8, app.workspace_root);
            errdefer app.alloc.free(origin);
            const workspace = try app.alloc.dupe(u8, app.workspace_root);
            errdefer app.alloc.free(workspace);
            const owned_preferences = try preferences.dupe(app.alloc);
            errdefer {
                var value = owned_preferences;
                value.deinit(app.alloc);
            }
            const history = try app.alloc.alloc(types.HistoryTurn, 0);
            errdefer app.alloc.free(history);
            return .{
                .id = id,
                .origin_workspace_root = origin,
                .workspace_root = workspace,
                .created_at_ms = now,
                .updated_at_ms = now,
                .conversation_language = agent.session.languageSnapshot(),
                .preferences = owned_preferences,
                .history = history,
                .total_input_tokens = 0,
                .total_output_tokens = 0,
            };
        }

        fn restoreRuntimePreferences(
            app: *App,
            agent: *AppAgent,
            preferences: session_codec.DurableSessionPreferences,
        ) !void {
            const fast_mode_model_bound = restoredFastModeModelBound(
                agent.session_persistence.fast_mode_model_bound,
                agent.session_persistence.workspace_preferences,
                preferences,
            );
            if (agent.session_persistence.process_provider_override) |override_provider| {
                // --provider pins the provider for this resumed launch; the
                // resolved model arrives through process_model_override below.
                try provider_runtime.replaceSelection(app, override_provider, preferences.model);
            } else if (config_runtime.providerEnvOverride() != null) {
                var settings = try config_runtime.loadMergedSettings(app.alloc, app.workspace_root);
                defer settings.deinit(app.alloc);
                const selected = settings.provider orelse return error.InvalidProviderValue;
                const model = settings.models.get(selected) orelse fallback: {
                    const seeded = agent.session_persistence.workspace_preferences orelse return error.ConfiguredModelNotSelected;
                    if (!seeded.provider.eql(selected)) return error.ConfiguredModelNotSelected;
                    break :fallback seeded.model;
                };
                try provider_runtime.replaceSelection(app, selected, model);
            } else try provider_runtime.replaceSelection(app, preferences.provider, preferences.model);
            if (agent.session_persistence.process_model_override) |model| {
                try provider_runtime.replaceModel(app, model);
            }
            try agent.worker.syncQueuedPromptModel(
                std.heap.c_allocator,
                provider_runtime.modelOf(app, agent),
            );
            // Launch flags (spark --effort/--fast) win over the resumed session's
            // stored preferences for this launch, without rewriting them.
            const effective_effort = agent.session_persistence.process_effort_override orelse preferences.effort;
            const effective_fast_mode = agent.session_persistence.process_fast_override orelse preferences.fast_mode;
            const effective_ultrafast_mode = resolveUltrafastMode(
                preferences.ultrafast_mode,
                agent.session_persistence.process_ultrafast_override,
            );
            agent.effort = effective_effort;
            app.fast_mode = effective_fast_mode;
            agent.session_persistence.fast_mode_model_bound = if (agent.session_persistence.process_fast_override != null)
                effective_fast_mode
            else
                fast_mode_model_bound;
            agent.worker.syncQueuedPromptEffort(effective_effort);
            agent.worker.syncQueuedPromptFastMode(effective_fast_mode);
            agent.worker.syncQueuedPromptUltrafastMode(effective_ultrafast_mode);
        }

        pub fn fastModeModelBound(_: *const App, agent: *const AppAgent) bool {
            return agent.session_persistence.fast_mode_model_bound;
        }

        fn applySessionPreferencePatch(
            app: *App,
            agent: *AppAgent,
            patch: SessionPreferencePatch,
        ) !void {
            try applyPreferencePatch(
                app.alloc,
                &agent.session_persistence.session_preferences,
                patch,
            );
        }

        fn warnDegraded(app: *App, agent: *AppAgent, err: anyerror) !void {
            if (agent.session_persistence.degraded_warning_emitted) {
                debug_trace.logf(
                    "session",
                    "canonical persistence remains degraded err={s}",
                    .{@errorName(err)},
                );
                return;
            }
            agent.session_persistence.degraded_warning_emitted = true;
            try warnNonDurable(app, "session persistence degraded", err);
        }

        fn warnNonDurable(
            app: *App,
            label: []const u8,
            err: anyerror,
        ) !void {
            const notice = try app.alloc.print(
                "{s}: {s}; continuing non-durably",
                .{ label, @errorName(err) },
            );
            defer app.alloc.free(notice);
            try app.writeDomainNotice(.{
                .topic = "session",
                .tone = .warning,
                .body = notice,
            }, true);
        }
    };
}

fn replacePreferences(
    alloc: Allocator,
    target: *?session_codec.DurableSessionPreferences,
    source: session_codec.DurableSessionPreferences,
) !void {
    const replacement = try source.dupe(alloc);
    if (target.*) |*current| current.deinit(alloc);
    target.* = replacement;
}

fn resolveUltrafastMode(preference: bool, process_override: ?bool) bool {
    return process_override orelse preference;
}

fn restoredFastModeModelBound(
    current_bound: bool,
    configured: ?session_codec.DurableSessionPreferences,
    restored: session_codec.DurableSessionPreferences,
) bool {
    if (!current_bound) return false;
    const current = configured orelse return false;
    return current.provider.same_authority(restored.provider) and
        std.mem.eql(u8, current.model, restored.model) and
        current.fast_mode == restored.fast_mode;
}

fn applyPreferencePatch(
    alloc: Allocator,
    target: *?session_codec.DurableSessionPreferences,
    patch: SessionPreferencePatch,
) !void {
    var current = target.* orelse return error.SessionPreferencesUnavailable;
    if (patch.provider) |provider| current.provider = provider;
    if (patch.model) |model| {
        const replacement = try alloc.dupe(u8, model);
        alloc.free(current.model);
        current.model = replacement;
    }
    if (patch.effort) |effort| current.effort = effort;
    if (patch.fast_mode) |fast_mode| current.fast_mode = fast_mode;
    if (patch.ultrafast_mode) |ultrafast_mode| current.ultrafast_mode = ultrafast_mode;
    target.* = current;
}

const TestHome = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, home: ?[]const u8) !*TestHome {
        const self = try alloc.create(TestHome);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        if (home) |value| {
            try self.map.put("HOME", value);
        }

        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestHome) void {
        io_mod.resetEnvironForTest();
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

const TestResumeTarget = union(enum) {
    remembered,
    pick,
    last,
    id: []u8,

    fn deinit(self: *TestResumeTarget, alloc: Allocator) void {
        switch (self.*) {
            .remembered, .pick, .last => {},
            .id => |id| alloc.free(id),
        }
        self.* = .last;
    }
};

const FakeWorker = struct {
    model: std.ArrayList(u8) = .empty,
    effort: types.ReasoningEffort = .auto,
    fast_mode: bool = false,
    ultrafast_mode: bool = false,
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// What the loop told the worker about the commit of a finished turn.
    acknowledgements_without_turn: usize = 0,
    acknowledgements_with_turn: usize = 0,
    acknowledged_answer: ?[]const u8 = null,
    acknowledged_ownership: bool = false,
    acknowledged_history_limit: usize = 0,

    fn deinit(self: *FakeWorker, alloc: Allocator) void {
        self.model.deinit(alloc);
        self.* = .{};
    }

    pub fn acknowledgeFinishCommitted(self: *FakeWorker) void {
        self.acknowledgements_without_turn += 1;
    }

    pub fn acknowledgeFinishCommittedTurn(
        self: *FakeWorker,
        _: Allocator,
        turn: types.HistoryTurn,
        ownership: ?types.SnapshotFileOwnership,
        max_history_turns: usize,
    ) void {
        self.acknowledgements_with_turn += 1;
        self.acknowledged_answer = switch (turn) {
            .assistant => |entry| entry.assistant,
            else => null,
        };
        self.acknowledged_ownership = ownership != null;
        self.acknowledged_history_limit = max_history_turns;
    }

    pub fn isCancelRequested(self: *const FakeWorker) bool {
        return self.cancel_requested.load(.seq_cst);
    }

    pub fn queuedPromptCount(self: *const FakeWorker) usize {
        _ = self;
        return 0;
    }

    fn syncQueuedPromptModel(
        self: *FakeWorker,
        alloc: Allocator,
        model: []const u8,
    ) !void {
        self.model.clearRetainingCapacity();
        try self.model.appendSlice(alloc, model);
    }

    fn syncQueuedPromptEffort(
        self: *FakeWorker,
        effort: types.ReasoningEffort,
    ) void {
        self.effort = effort;
    }

    fn syncQueuedPromptFastMode(self: *FakeWorker, fast_mode: bool) void {
        self.fast_mode = fast_mode;
    }

    fn syncQueuedPromptUltrafastMode(self: *FakeWorker, ultrafast_mode: bool) void {
        self.ultrafast_mode = ultrafast_mode;
    }
};

const PromptCard = struct {
    text: []u8,
    has_prior_turns: bool,

    fn deinit(self: *PromptCard, alloc: Allocator) void {
        alloc.free(self.text);
        self.* = undefined;
    }
};

const AssistantPresentationEvent = enum {
    text,
    table,
    code_block,
    thematic_rule,
    raw_transcript,
};

const CapturedCommandOutput = struct {
    stream: command_output_content.Stream,
    text: []u8,
};

const ReplayEvent = enum {
    command_output_chunk,
    command_output_summary_flush,
    completed_tool_status,
    raw_transcript,
};

const TestApp = struct {
    alloc: Allocator,
    workspace_root: []u8,
    main_agent: struct {
        session_title: std.ArrayList(u8) = .empty,
        pending_images: std.ArrayList(types.ImageAttachment) = .empty,
        next_image_id: usize = 1,
        effort: types.ReasoningEffort = .auto,
        total_input_tokens: u64 = 0,
        total_output_tokens: u64 = 0,
        total_web_search_requests: u64 = 0,
        session: session_runtime.SessionRuntime = .{ .max_history_turns = 8 },
        session_persistence: Persistence = .{},
        stream: types.StreamState = .{},
        worker: FakeWorker = .{},
    } = .{},
    terminal_title_label: [128]u8 = undefined,
    terminal_title_label_len: usize = 0,
    input_runtime: core_input_runtime.Runtime = .{},
    terminal_input_runtime: ui_input.Runtime = .{},
    shell: transcript_runtime.TranscriptRuntime = .{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 21,
        .divider_top_row = 22,
        .input_row = 23,
        .divider_bottom_row = 24,
        .hint_row = 22,
    } },
    metrics: types.Metrics = .{},
    requested_resume: ?TestResumeTarget = null,
    terminal: shell_runtime.TerminalState = .{},
    selected_model: std.ArrayList(u8) = .empty,
    fast_mode: bool = false,
    notices: std.ArrayList([]u8) = .empty,
    cards: std.ArrayList(PromptCard) = .empty,
    transcript: std.ArrayList(u8) = .empty,
    raw_transcript_classes: std.ArrayList(transcript_runtime.RawEntryClass) = .empty,
    completed_tool_statuses: std.ArrayList([]u8) = .empty,
    completed_tool_outcomes: std.ArrayList(types.ToolOutcomeKind) = .empty,
    next_transcript_entry_id: u32 = 1,
    historical_question_entry_ids: std.ArrayList(u32) = .empty,
    historical_question_answer_count: usize = 0,
    historical_tool_detail_entry_ids: std.ArrayList(u32) = .empty,
    cancelled_command_detail_count: usize = 0,
    cancelled_command_artifact_handle: ?[]u8 = null,
    cancelled_command_replayed_output: bool = false,
    command_stdout: std.ArrayList(u8) = .empty,
    command_stderr: std.ArrayList(u8) = .empty,
    command_output_writes: std.ArrayList(CapturedCommandOutput) = .empty,
    command_output_flush_count: usize = 0,
    replay_events: std.ArrayList(ReplayEvent) = .empty,
    assistant_text: std.ArrayList(u8) = .empty,
    assistant_tables: std.ArrayList(assistant_presentation.TablePayload) = .empty,
    assistant_code_blocks: std.ArrayList(assistant_presentation.CodeBlockPayload) = .empty,
    assistant_thematic_rule_count: usize = 0,
    assistant_presentation_events: std.ArrayList(AssistantPresentationEvent) = .empty,
    fail_system_notice: bool = false,
    fail_assistant_table_append: bool = false,
    fail_assistant_code_block_append: bool = false,
    writable_seen_during_notice_failure: bool = false,
    fail_startup_resume_anchor: bool = false,
    startup_resume_anchor_count: usize = 0,
    startup_resume_anchor_saw_writable: bool = false,
    startup_resume_anchor_history_len: usize = 0,
    startup_resume_anchor_notice_count: usize = 0,
    startup_resume_anchor_saw_reset: bool = false,
    action_description_allocates_scratch: bool = false,
    live_resume_prepare_count: usize = 0,
    live_resume_finish_count: usize = 0,
    authority_mutex: std.Io.Mutex = .init,
    mcp_tool_names: std.ArrayList([]u8) = .empty,

    fn init(alloc: Allocator, workspace_root: []const u8) !TestApp {
        return .{
            .alloc = alloc,
            .workspace_root = try alloc.dupe(u8, workspace_root),
        };
    }

    fn toolAdvertisementSet(_: *const TestApp, _: anytype) tool_set_contract.ToolSet {
        return builtin_tools.advertisement_set;
    }

    fn toolRegistry(_: *const TestApp, _: anytype) tool_dispatch.Registry {
        return builtin_tools.advertisement_set.registry;
    }

    fn historicalToolActivityKind(self: *TestApp, _: anytype, call: types.ToolCall) types.ToolActivityKind {
        return tool_dispatch.toolActivityKindForCall(self.alloc, builtin_tools.advertisement_set.registry, call);
    }

    fn prepareHistoricalQuestionResolution(self: *TestApp, answers: []const types.QuestionAnswer) ![]u8 {
        return question_ui.composeResolvedQuestionAnswers(
            self.alloc,
            answers,
            self.shell.layout.cols,
        );
    }

    pub fn snapshotMcpToolNames(self: *TestApp, alloc: Allocator) ![][]u8 {
        const names = try alloc.alloc([]u8, self.mcp_tool_names.items.len);
        var initialized: usize = 0;
        errdefer {
            for (names[0..initialized]) |name| alloc.free(name);
            alloc.free(names);
        }
        for (self.mcp_tool_names.items, names) |name, *owned| {
            owned.* = try alloc.dupe(u8, name);
            initialized += 1;
        }
        return names;
    }

    pub fn terminalTitle(self: *TestApp) host_capability.TerminalTitle {
        return .{
            .context = self,
            .set_fn = setTerminalTitleLabelForTest,
            .clear_fn = clearTerminalTitleForTest,
        };
    }

    fn setTerminalTitleLabelForTest(raw: ?*anyopaque, label: []const u8) void {
        const self: *TestApp = @ptrCast(@alignCast(raw.?));
        self.terminal_title_label_len = @min(label.len, self.terminal_title_label.len);
        @memcpy(
            self.terminal_title_label[0..self.terminal_title_label_len],
            label[0..self.terminal_title_label_len],
        );
    }

    fn clearTerminalTitleForTest(raw: ?*anyopaque) void {
        const self: *TestApp = @ptrCast(@alignCast(raw.?));
        self.terminal_title_label_len = 0;
    }

    fn terminalTitleLabelText(self: *const TestApp) []const u8 {
        return self.terminal_title_label[0..self.terminal_title_label_len];
    }

    fn deinit(self: *TestApp) void {
        self.input_runtime.deinit(self.alloc);
        self.terminal_input_runtime.deinit(self.alloc);
        self.agent().session_title.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        self.agent().pending_images.deinit(self.alloc);
        for (self.notices.items) |notice| self.alloc.free(notice);
        self.notices.deinit(self.alloc);
        for (self.cards.items) |*card| card.deinit(self.alloc);
        self.cards.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.raw_transcript_classes.deinit(self.alloc);
        for (self.completed_tool_statuses.items) |status| self.alloc.free(status);
        self.completed_tool_statuses.deinit(self.alloc);
        self.completed_tool_outcomes.deinit(self.alloc);
        self.historical_question_entry_ids.deinit(self.alloc);
        self.historical_tool_detail_entry_ids.deinit(self.alloc);
        if (self.cancelled_command_artifact_handle) |handle| self.alloc.free(handle);
        self.command_stdout.deinit(self.alloc);
        self.command_stderr.deinit(self.alloc);
        for (self.command_output_writes.items) |write| self.alloc.free(write.text);
        self.command_output_writes.deinit(self.alloc);
        self.replay_events.deinit(self.alloc);
        self.assistant_text.deinit(self.alloc);
        for (self.assistant_tables.items) |*table| table.deinit(self.alloc);
        self.assistant_tables.deinit(self.alloc);
        for (self.assistant_code_blocks.items) |*block| block.deinit(self.alloc);
        self.assistant_code_blocks.deinit(self.alloc);
        self.assistant_presentation_events.deinit(self.alloc);
        Runtime(TestApp).deinitPersistence(self, self.agent());
        if (self.requested_resume) |*target| target.deinit(self.alloc);
        self.agent().session.deinit(self.alloc);
        self.agent().worker.deinit(std.heap.c_allocator);
        self.selected_model.deinit(self.alloc);
        for (self.mcp_tool_names.items) |name| self.alloc.free(name);
        self.mcp_tool_names.deinit(self.alloc);
        self.alloc.free(self.workspace_root);
        self.* = undefined;
    }

    pub fn writeDomainNotice(self: *TestApp, notice: types.SemanticNotice, _: bool) !void {
        if (self.fail_system_notice) {
            self.writable_seen_during_notice_failure =
                self.agent().session_persistence.v2 != null;
            return error.TestSystemNoticeFailure;
        }
        try self.notices.append(self.alloc, if (notice.topic.len > 0)
            try self.alloc.print(
                "{s} {s}: {s}",
                .{ types.noticeGlyph(notice.tone), notice.topic, notice.body },
            )
        else
            try self.alloc.print("{s} {s}", .{ types.noticeGlyph(notice.tone), notice.body }));
    }

    fn commitStartupResumeReplayAnchor(self: *TestApp) !void {
        self.startup_resume_anchor_count += 1;
        self.startup_resume_anchor_saw_writable = self.agent().session_persistence.v2 != null;
        self.startup_resume_anchor_history_len = self.agent().session.historyLen();
        self.startup_resume_anchor_notice_count = self.notices.items.len;
        self.startup_resume_anchor_saw_reset = self.shell.terminal_reset_pending;
        if (self.fail_startup_resume_anchor) return error.TestStartupResumeAnchorFailure;
    }

    fn prepareLiveSessionResume(self: *TestApp, _: anytype) !void {
        self.live_resume_prepare_count += 1;
        Runtime(TestApp).cancelSessionPicker(self, self.agent());
        self.agent().session.reset(self.alloc);
    }

    fn finishLiveSessionResume(self: *TestApp) !void {
        self.live_resume_finish_count += 1;
    }

    fn writeUserPromptCardWithSpacing(self: *TestApp, user: types.UserTurn, has_prior_turns: bool) !void {
        try self.cards.append(self.alloc, .{
            .text = try self.alloc.dupe(u8, user.text),
            .has_prior_turns = has_prior_turns,
        });
    }

    fn writeTranscript(self: *TestApp, text: []const u8, record: bool) !void {
        try self.writeTranscriptClassified(text, record, .unknown_raw);
    }

    fn writeTranscriptClassified(
        self: *TestApp,
        text: []const u8,
        record: bool,
        class: transcript_runtime.RawEntryClass,
    ) !void {
        _ = record;
        try self.transcript.appendSlice(self.alloc, text);
        try self.raw_transcript_classes.append(self.alloc, class);
        try self.replay_events.append(self.alloc, .raw_transcript);
        try self.assistant_presentation_events.append(self.alloc, .raw_transcript);
    }

    fn writeCompletedToolStatus(
        self: *TestApp,
        kind: types.ToolOutcomeKind,
        text: []const u8,
        record: bool,
    ) !void {
        _ = record;
        const line = if (std.mem.endsWith(u8, text, "\n"))
            try self.alloc.dupe(u8, text)
        else
            try self.alloc.print("{s}\n", .{text});
        try self.completed_tool_statuses.append(self.alloc, line);
        try self.completed_tool_outcomes.append(self.alloc, kind);
        try self.replay_events.append(self.alloc, .completed_tool_status);
    }

    pub fn writeCompletedToolStatusReturningEntryId(
        self: *TestApp,
        kind: types.ToolOutcomeKind,
        text: []const u8,
        record: bool,
    ) !u32 {
        try self.writeCompletedToolStatus(kind, text, record);
        return self.allocateTranscriptEntryId();
    }

    pub fn writeHistoricalQuestionResolution(
        self: *TestApp,
        answers: []const types.QuestionAnswer,
    ) !u32 {
        const entry_id = self.allocateTranscriptEntryId();
        try self.historical_question_entry_ids.append(self.alloc, entry_id);
        self.historical_question_answer_count += answers.len;
        return entry_id;
    }

    pub fn attachHistoricalToolDetail(
        self: *TestApp,
        entry_id: u32,
        _: types.ToolCall,
        _: types.PersistedToolResult,
    ) !void {
        try self.historical_tool_detail_entry_ids.append(self.alloc, entry_id);
    }

    pub fn attachHistoricalCancelledCommandDetail(
        self: *TestApp,
        entry_id: u32,
        _: types.ToolCall,
        command_artifact_handle: ?[]const u8,
        replayed_output: bool,
    ) !void {
        try self.historical_tool_detail_entry_ids.append(self.alloc, entry_id);
        self.cancelled_command_detail_count += 1;
        self.cancelled_command_replayed_output = replayed_output;
        if (command_artifact_handle) |handle| {
            self.cancelled_command_artifact_handle = try self.alloc.dupe(u8, handle);
        }
    }

    fn allocateTranscriptEntryId(self: *TestApp) u32 {
        const entry_id = self.next_transcript_entry_id;
        self.next_transcript_entry_id +%= 1;
        return entry_id;
    }

    fn writeCommandOutputChunk(self: *TestApp, stream: command_output_content.Stream, text: []const u8, record: bool) !void {
        _ = record;
        const owned = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(owned);
        try self.command_output_writes.append(self.alloc, .{
            .stream = stream,
            .text = owned,
        });
        try self.replay_events.append(self.alloc, .command_output_chunk);
        switch (stream) {
            .stdout => try self.command_stdout.appendSlice(self.alloc, text),
            .stderr => try self.command_stderr.appendSlice(self.alloc, text),
        }
    }

    fn flushCommandOutputSummary(self: *TestApp, record: bool) !void {
        _ = record;
        self.command_output_flush_count += 1;
        try self.replay_events.append(self.alloc, .command_output_summary_flush);
    }

    fn describeToolActionCompletedWithAdvertised(self: *TestApp, _: anytype, arena: Allocator, call: types.ToolCall, display_target: ?[]const u8, _: []const []const u8) ![]const u8 {
        if (self.action_description_allocates_scratch) {
            _ = try arena.dupe(u8, "temporary parsed arguments");
        }
        if (std.mem.eql(u8, call.name, "run_command")) {
            return arena.dupe(u8, "● Ran pwd");
        }
        if (display_target) |target| {
            return arena.print("● Completed {s} {s}", .{ call.name, target });
        }
        return arena.print("● Completed {s}", .{call.name});
    }

    fn describeToolActionDeniedWithAdvertised(self: *TestApp, _: anytype, arena: Allocator, call: types.ToolCall, _: ?[]const u8, label: []const u8, _: []const []const u8) ![]const u8 {
        if (self.action_description_allocates_scratch) {
            _ = try arena.dupe(u8, "temporary parsed arguments");
        }
        return arena.print("● {s} {s}", .{ label, call.name });
    }

    fn pacerEmit(ctx: *anyopaque, text: []const u8) anyerror!void {
        const self: *TestApp = @ptrCast(@alignCast(ctx));
        try self.assistant_text.appendSlice(self.alloc, text);
        try self.assistant_presentation_events.append(self.alloc, .text);
    }

    fn appendAssistantTable(
        self: *TestApp,
        table: assistant_presentation.TablePayload,
    ) !void {
        if (self.fail_assistant_table_append) {
            return error.TestAssistantTableAppendFailure;
        }
        try self.assistant_presentation_events.append(self.alloc, .table);
        try self.assistant_tables.append(self.alloc, table);
    }

    fn appendAssistantCodeBlock(
        self: *TestApp,
        block: assistant_presentation.CodeBlockPayload,
    ) !void {
        if (self.fail_assistant_code_block_append) {
            return error.TestAssistantCodeBlockAppendFailure;
        }
        try self.assistant_presentation_events.append(self.alloc, .code_block);
        try self.assistant_code_blocks.append(self.alloc, block);
    }

    fn appendAssistantThematicRule(self: *TestApp) !void {
        self.assistant_thematic_rule_count += 1;
        try self.assistant_presentation_events.append(self.alloc, .thematic_rule);
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

const FakeJsHostSessionStore = struct {
    state: ?session_codec.DurableSessionState = null,
    revision: []const u8 = "revision-1",
    updated_at_ms: i64 = 1,
    list_error: ?anyerror = null,
    load_error: ?anyerror = null,
    commit_error: ?anyerror = null,
    load_missing: bool = false,
    commit_count: usize = 0,
    committed_state: ?session_codec.DurableSessionState = null,
    expected_revision: ?[]u8 = null,

    fn deinit(self: *FakeJsHostSessionStore, alloc: Allocator) void {
        if (self.state) |*state| state.deinit(alloc);
        if (self.committed_state) |*state| state.deinit(alloc);
        if (self.expected_revision) |revision| alloc.free(revision);
        self.* = .{};
    }

    fn store(self: *FakeJsHostSessionStore) JsHostSessionStore {
        return .{
            .ctx = self,
            .load_fn = load,
            .commit_fn = commit,
            .list_fn = list,
        };
    }

    fn load(raw: ?*anyopaque, alloc: Allocator, id: []const u8) !?js_host_session_store.Loaded {
        const self: *FakeJsHostSessionStore = @ptrCast(@alignCast(raw.?));
        if (self.load_error) |err| return err;
        if (self.load_missing) return null;
        const state = self.state orelse return null;
        if (!std.mem.eql(u8, state.id, id)) return null;
        var owned_state = try state.dupe(alloc);
        errdefer owned_state.deinit(alloc);
        return .{
            .state = owned_state,
            .revision = try alloc.dupe(u8, self.revision),
        };
    }

    fn commit(
        raw: ?*anyopaque,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        expected_revision: ?[]const u8,
    ) ![]u8 {
        const self: *FakeJsHostSessionStore = @ptrCast(@alignCast(raw.?));
        self.commit_count += 1;
        if (self.commit_error) |err| return err;
        if (self.expected_revision) |revision| alloc.free(revision);
        self.expected_revision = if (expected_revision) |revision|
            try alloc.dupe(u8, revision)
        else
            null;
        if (self.committed_state) |*committed| committed.deinit(alloc);
        self.committed_state = try state.dupe(alloc);
        return alloc.dupe(u8, "revision-next");
    }

    fn list(raw: ?*anyopaque, alloc: Allocator) ![]js_host_session_store.Metadata {
        const self: *FakeJsHostSessionStore = @ptrCast(@alignCast(raw.?));
        if (self.list_error) |err| return err;
        const state = self.state orelse return alloc.alloc(js_host_session_store.Metadata, 0);
        const entries = try alloc.alloc(js_host_session_store.Metadata, 1);
        errdefer alloc.free(entries);
        entries[0] = .{
            .id = try alloc.dupe(u8, state.id),
            .updated_at_ms = self.updated_at_ms,
        };
        return entries;
    }
};

fn makeJsHostTestState(
    alloc: Allocator,
    id: []const u8,
    user: []const u8,
    assistant: []const u8,
) !session_codec.DurableSessionState {
    const history = try alloc.alloc(types.HistoryTurn, 1);
    errdefer alloc.free(history);
    history[0] = try session_runtime.makeAssistantTurn(alloc, user, assistant);
    errdefer session_runtime.freeHistoryTurn(alloc, history[0]);
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const origin = try alloc.dupe(u8, "/origin");
    errdefer alloc.free(origin);
    const workspace = try alloc.dupe(u8, "/workspace");
    errdefer alloc.free(workspace);
    const model = try alloc.dupe(u8, "restored/model");
    errdefer alloc.free(model);
    return .{
        .id = owned_id,
        .origin_workspace_root = origin,
        .workspace_root = workspace,
        .created_at_ms = 10,
        .updated_at_ms = 20,
        .conversation_language = session_runtime.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = model,
            .effort = types.ReasoningEffort.literal("high"),
            .fast_mode = true,
        },
        .history = history,
        .context_history_start = 0,
        .total_input_tokens = 17,
        .total_output_tokens = 23,
    };
}

fn testPaths(alloc: Allocator, tmp: *std.testing.TmpDir) !struct { home: []u8, workspace: []u8 } {
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.spark");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    errdefer alloc.free(home);
    // spark keeps `.spark` private, and resuming a session verifies that.
    const spark_dir = try std.Io.Dir.path.joinZ(alloc, &.{ home, ".spark" });
    defer alloc.free(spark_dir);
    if (std.c.chmod(spark_dir.ptr, 0o700) != 0) return error.TestChmodFailed;
    return .{ .home = home, .workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace") };
}

fn configureTestPreferences(app: *TestApp) !void {
    try Runtime(TestApp).configureStartupPreferences(
        app,
        app.agent(),
        .none,
        "configured/model",
        .user_workspace,
        "configured/model",
        types.ReasoningEffort.literal("high"),
        true,
        true,
        false,
        null,
        null,
        null,
        null,
    );
}

/// Saves `history` as a new session in the app's store, as a run of
/// prompts would, with the preferences of a session saved earlier, and
/// returns its id. Caller frees.
fn writeSessionFixture(app: *TestApp, history: []const types.HistoryTurn) ![]u8 {
    try Runtime(TestApp).beginFresh(app, app.agent(), .later, null);
    const v2 = app.agent().session_persistence.v2.?;
    for (history) |turn| try v2.commitTurn(turn, session_runtime.ConversationLanguage.literal("en"));
    var model = "saved/model".*;
    try v2.setPreferences(.{ .model = &model, .effort = types.ReasoningEffort.literal("medium"), .fast_mode = false });
    const id = try app.alloc.dupe(u8, v2.id());
    Runtime(TestApp).closeWritableSession(app, app.agent());
    return id;
}

/// Begins a new session's first turn and stores `body` as one of its blobs
/// (D44), returning the blob's name for the turn to name it by. Finish with
/// `commitSessionFixture`.
fn beginSessionWithBody(app: *TestApp, body: []const u8) !session_child_store.Blobs.Hash {
    try Runtime(TestApp).beginFresh(app, app.agent(), .later, null);
    const v2 = app.agent().session_persistence.v2.?;
    try v2.beginTurn();
    return (try v2.childCapability()).putBlob(body);
}

/// Commits `turn` to the session `beginSessionWithBody` began, closes it and
/// returns its id. The caller frees it.
fn commitSessionFixture(app: *TestApp, turn: types.HistoryTurn) ![]u8 {
    const v2 = app.agent().session_persistence.v2.?;
    try v2.commitTurn(turn, session_runtime.ConversationLanguage.literal("en"));
    const id = try app.alloc.dupe(u8, v2.id());
    Runtime(TestApp).closeWritableSession(app, app.agent());
    return id;
}

/// Closes the app's session and restores what it saved, as a later spark
/// would. The caller deinits the result.
fn reopenSaved(app: anytype) !session_adapter.Restored {
    const id = try app.alloc.dupe(u8, app.agent().session_persistence.v2.?.id());
    defer app.alloc.free(id);
    Runtime(@TypeOf(app.*)).closeWritableSession(app, app.agent());
    const resumed = try session_adapter.Session.resumeSession(app.alloc, app.agent().session_persistence.v2_store.?, .{ .id = id }, app.workspace_root, .app);
    defer resumed.close();
    return resumed.restore(app.alloc);
}

/// A step whose command made three calls through `spark mcp call`, two that
/// worked and one that failed, then read a file, as a resume reads it.
const BridgeReplayFixture = struct {
    calls: [2]types.ToolCall = .{
        .{ .id = "call_pages", .name = "run_command", .arguments_json = "{\"command\":\"sh pages.sh\"}" },
        .{ .id = "call_read", .name = "read_file", .arguments_json = "{\"path\":\"notes.txt\"}" },
    },
    results: [2]types.PersistedToolResult = .{
        .{
            .tool_call_id = @constCast("call_pages"),
            .tool_name = @constCast("run_command"),
            .status = .success,
            .output = @constCast("exit_code=0\n<stdout>\ncalls=3\n</stdout>\n"),
            .output_bytes = 39,
            .stored_output_bytes = 39,
        },
        .{
            .tool_call_id = @constCast("call_read"),
            .tool_name = @constCast("read_file"),
            .status = .success,
            .output = @constCast("notes"),
            .output_bytes = 5,
            .stored_output_bytes = 5,
        },
    },
    bridge_calls: [4]types.BridgeCallRecord = .{
        .{ .call_id = "call_pages", .request_id = "spark-mcp-call-1", .tool = "mcp_fixture_echo", .outcome = .completed },
        .{ .call_id = "call_pages", .request_id = "spark-mcp-call-2", .tool = "mcp_fixture_echo", .outcome = .completed },
        .{ .call_id = "call_pages", .request_id = "spark-mcp-call-3", .tool = "mcp_fixture_echo", .outcome = .failed },
        // Its shell call is not in the turn, as after a compaction cut it.
        .{ .call_id = "call_gone", .request_id = "spark-mcp-call-4", .tool = "mcp_fixture_echo", .outcome = .completed },
    },
    steps: [1]types.ToolExecutionStep = undefined,

    fn execution(self: *BridgeReplayFixture) types.ExecutionMemory {
        self.steps[0] = .{ .tool_calls = self.calls[0..], .tool_results = self.results[0..] };
        return .{ .tool_steps = self.steps[0..], .bridge_calls = self.bridge_calls[0..] };
    }
};

fn expectCancelledHistoryKeepsAuthoritativeReplay() !void {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try testPaths(alloc, &tmp);
    defer {
        alloc.free(paths.home);
        alloc.free(paths.workspace);
    }
    const home = try TestHome.install(alloc, paths.home);
    defer home.deinit();
    var app = try TestApp.init(alloc, paths.workspace);
    defer app.deinit();
    try configureTestPreferences(&app);
    try Runtime(TestApp).initializePersistence(&app, (&app).agent(), true);
    try Runtime(TestApp).beginFresh(&app, (&app).agent(), .later, null);
    // The turn is open on disk while its command runs (D44).
    try app.agent().session_persistence.v2.?.beginTurn();
    const capability = Runtime(TestApp).childCapability((&app).agent()) orelse
        return error.TestExpectedSessionCapability;
    const authoritative = try command_replay_store.Capture.create(
        alloc,
        1,
        capability,
    );
    authoritative.setPolicyBeforeCapture(.required);
    try authoritative.appendAcceptedRequired(
        alloc,
        .stdout,
        "SHARED-CANCELLED-OUTPUT\n",
    );
    const descriptor = (try authoritative.retainRequired(alloc)) orelse
        return error.TestExpectedReplay;
    var published = false;
    defer {
        if (published)
            authoritative.releaseRetained(alloc)
        else
            authoritative.discard(alloc);
        alloc.destroy(authoritative);
    }

    const lifecycle_id = types.ToolLifecycleId{
        .turn_id = 9,
        .call_id = "authoritative-cancelled-command",
    };
    Runtime(TestApp).recordToolTerminal(
        &app,
        (&app).agent(),
        .{ .terminal = .{
            .id = lifecycle_id,
            .outcome = .{ .kind = .cancelled, .summary = "Cancelled" },
            .command_artifact_handle = "spark-command-cancelled.log",
        } },
        true,
    );

    try Runtime(TestApp).appendHistoryTurn(&app, (&app).agent(), .{ .interrupted = .{
        .user = .{ .text = @constCast("cancel") },
        .tool_call = .{
            .id = "authoritative-cancelled-command",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"slow\",\"timeout_ms\":600000}",
        },
        .cancelled_command = .{
            .output_replay = .{ .available = descriptor },
        },
    } });
    published = true;

    const history = try app.agent().session.snapshotHistory(alloc);
    defer session_runtime.freeHistoryTurnSlice(alloc, history);
    const stored = switch (history[0].interrupted.cancelled_command.?
        .output_replay orelse return error.TestExpectedReplay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedReplay,
    };
    try std.testing.expectEqualStrings(descriptor.handle, stored.handle);
    try std.testing.expectEqualStrings(
        "spark-command-cancelled.log",
        history[0].interrupted.cancelled_command.?
            .command_artifact_handle orelse return error.TestExpectedArtifactHandle,
    );
    const page = try command_replay_store.readAgentPageManaged(
        alloc,
        capability,
        stored.handle,
        1,
        4096,
    );
    defer alloc.free(page);
    try std.testing.expect(
        std.mem.find(u8, page, "SHARED-CANCELLED-OUTPUT") != null,
    );
}

const SnapshotOwnershipProbe = struct {
    transfers: usize = 0,

    fn retain(_: *anyopaque) void {}

    fn release(_: *anyopaque) void {}

    fn transfer(raw: *anyopaque) void {
        const self: *SnapshotOwnershipProbe = @ptrCast(@alignCast(raw));
        self.transfers += 1;
    }

    fn handle(self: *SnapshotOwnershipProbe) types.SnapshotFileOwnership {
        return .{
            .ctx = self,
            .retain_fn = retain,
            .release_fn = release,
            .transfer_fn = transfer,
        };
    }
};

/// Saves each workspace capture as a real item named by `label` and its
/// phase, such as `A-start`, so a test can read which turn holds it.
const CaptureLabelRecorder = struct {
    var label: []const u8 = "";

    fn record(context: turn_capture.Context, turn: session_adapter.Session.CaptureTurn, phase: @import("../workspace/capture_store.zig").Phase, lock: *std.Io.Mutex, trigger_tool: ?[]const u8, skip: ?@import("../workspace/workspace_capture.zig").Reason) void {
        _ = .{ trigger_tool, skip };
        var buf: [64]u8 = undefined;
        const payload = std.mem.print(&buf, "{{\"capture\":\"{s}-{t}\"}}", .{ label, phase }) catch return;
        lock.lockUncancelable(io_mod.getIo());
        defer lock.unlock(io_mod.getIo());
        _ = context.session.saveWorkspaceCapture(turn, payload, switch (phase) {
            .start => .start,
            .end => .end,
        }) catch {};
    }
};

fn createHeldSessionPickerTask(
    generation: u64,
    active_id: []const u8,
    store: *session_adapter.Store,
) !*SessionPickerLoad.Task {
    const alloc = std.heap.c_allocator;
    var request = try SessionPickerLoad.PageRequest.init(
        generation,
        active_id,
    );
    errdefer request.deinit();
    const task = try alloc.create(SessionPickerLoad.Task);
    task.* = .{ .request = request, .store = store };
    return task;
}

fn waitForPickerCancellation(task: *SessionPickerLoad.Task) void {
    while (!task.cancel_requested.load(.acquire)) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    task.done.store(true, .release);
}

fn waitForSessionPickerLoad(app: *TestApp) !void {
    const deadline_ms = io_mod.milliTimestamp() + 5_000;
    while (io_mod.milliTimestamp() < deadline_ms) {
        try Runtime(TestApp).pollSessionPicker(app, app.agent());
        const picker = &app.agent().session_persistence.session_picker;
        if (!picker.isLoading() and !picker.loading_more) return;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

fn waitForSessionPickerPrewarm(app: *TestApp) !void {
    const deadline_ms = io_mod.milliTimestamp() + 5_000;
    while (io_mod.milliTimestamp() < deadline_ms) {
        try Runtime(TestApp).pollSessionPicker(app, app.agent());
        const loader = &app.agent().session_persistence.session_picker_load;
        if (loader.task == null and loader.pending == null) return;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

fn fuzzSessionTitle(_: void, smith: *std.testing.Smith) !void {
    var bytes: [512]u8 = undefined;
    const raw = bytes[0..@intCast(smith.slice(&bytes))];
    const title = Runtime(TestApp).validateSessionTitle(raw) catch |err| switch (err) {
        error.EmptyTitle, error.TitleTooLong, error.InvalidTitle, error.MultilineTitle => return,
        error.NoActiveSession => return error.TestUnexpectedResult,
    };
    // The title borrows from the input.
    try std.testing.expect(@intFromPtr(title.ptr) >= @intFromPtr(raw.ptr));
    try std.testing.expect(@intFromPtr(title.ptr) - @intFromPtr(raw.ptr) + title.len <= raw.len);
    try std.testing.expect(title.len > 0 and title.len <= session_display_metadata.max_title_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(title));
    try std.testing.expectEqual(title.len, std.mem.trim(u8, title, " \t\r\n").len);
    for (title) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
    // Either the trimmed input, or the trimmed text inside one pair of quotes.
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (!std.mem.eql(u8, trimmed, title)) {
        try std.testing.expect(trimmed.len >= 2);
        try std.testing.expect(trimmed[0] == '"' or trimmed[0] == '\'');
        try std.testing.expectEqual(trimmed[0], trimmed[trimmed.len - 1]);
        try std.testing.expectEqualStrings(std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t"), title);
    }
}

const TitleGenerationFakeApp = struct {
    alloc: Allocator,
    workspace_root: []u8,
    main_agent: struct {
        session_title: std.ArrayList(u8) = .empty,
        session: session_runtime.SessionRuntime = .{ .max_history_turns = 8 },
        session_persistence: Persistence = .{},
    } = .{},
    session_title_generation: bool = true,
    auth: TitleTestAuth = .{},
    selected_model: std.ArrayList(u8) = .empty,
    stream_content: []const u8 = "Refactor the renderer loop",
    stream_error: ?anyerror = null,

    const TitleTestAuth = struct {
        pub fn credentialSource(_: *const TitleTestAuth) ?@import("../auth/credentials.zig").Source {
            return .configured;
        }

        pub fn apiKey(_: *const TitleTestAuth) []const u8 {
            return "test-key";
        }
    };

    fn init(alloc: Allocator, workspace_root: []const u8) !TitleGenerationFakeApp {
        return .{
            .alloc = alloc,
            .workspace_root = try alloc.dupe(u8, workspace_root),
        };
    }

    fn deinit(self: *TitleGenerationFakeApp) void {
        self.agent().session_title.deinit(self.alloc);
        self.selected_model.deinit(self.alloc);
        self.agent().session.deinit(self.alloc);
        self.agent().session_persistence.deinit(self.alloc);
        self.alloc.free(self.workspace_root);
    }

    pub fn agentStreamProvider(self: *TitleGenerationFakeApp) @import("../agent/stream_provider.zig").Provider {
        return .{ .context = self, .stream_fn = titleStream };
    }

    pub fn sessionTitleModel(_: *TitleGenerationFakeApp) ?[]const u8 {
        return "test/title-model";
    }

    fn titleStream(raw: ?*anyopaque, _: Allocator, request: @import("../agent/stream_provider.zig").ModelRequest) anyerror!@import("../agent/stream_provider.zig").Result {
        const self: *TitleGenerationFakeApp = @ptrCast(@alignCast(raw.?));
        try std.testing.expectEqualStrings("test/title-model", request.model);
        try std.testing.expectEqual(@as(usize, 1), request.messages.len);
        if (self.stream_error) |err| return err;
        try request.admission.admit();
        return .{ .completed = .{ .completion = .{
            .content = self.stream_content,
            .finish_reason = .stop,
        }, .ownership = .borrowed } };
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

/// Opens a new session for the title tests, as a first prompt finds it.
fn initTitleTestSession(app: *TitleGenerationFakeApp, alloc: Allocator, root: []const u8) !void {
    _ = try app.agent().session_persistence.adoptStore(alloc, try session_adapter.Store.openFromEnv(alloc));
    var model = "test-model".*;
    app.agent().session_persistence.v2 = try session_adapter.Session.create(alloc, app.agent().session_persistence.v2_store.?, root, .app, .{
        .preferences = .{ .model = &model, .effort = .auto, .fast_mode = false },
        .language = .literal("en"),
    });
}

fn awaitTitleTask(app: *TitleGenerationFakeApp) !void {
    var waited_ms: i64 = 0;
    while (app.agent().session_persistence.title_generation.task != null) {
        if (waited_ms > 10_000) return error.TitleGenerationTimedOut;
        io_mod.sleep(10 * std.time.ns_per_ms);
        waited_ms += 10;
        _ = try Runtime(TitleGenerationFakeApp).pollSessionTitleGeneration(app, app.agent());
    }
}
