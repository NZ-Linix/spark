const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const terminal_env = @import("../shared/terminal_env.zig");
const app_lifecycle = @import("../app/app_lifecycle.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const acp_runner = @import("acp_runner.zig");
const cli_ask = @import("cli_ask.zig");
const cli_replay = @import("cli_replay.zig");
const cli_flags = @import("cli_flags.zig");
const completion = @import("completion.zig");
const agent_run_flags = @import("agent_run_flags.zig");
const flag_placement = @import("flag_placement.zig");
const cli_config = @import("cli_config.zig");
const prompts = @import("../prompts/prompts.zig");
const cli_provider_edit = @import("cli_provider_edit.zig");
const settings_messages = @import("settings_messages.zig");
const settings_entries = @import("../config/settings_entries.zig");
const settings_keys = @import("../config/settings_keys.zig");
const settings_schema = @import("../config/settings_schema.zig");
const builtin_commands = @import("../../builtins/commands.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const collections = @import("../shared/collections.zig");
const config_runtime = @import("../config/config_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const model_provider = @import("../config/model_provider.zig");
const profiles = @import("../profiles/profiles.zig");
const app_profile_runtime = @import("../app/app_profile_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const doctor_runtime = @import("doctor_runtime.zig");
const doctor_probes = @import("doctor_probes.zig");
const mcp_runtime = @import("../mcp_host/runtime.zig");
const self_exe = @import("../shared/self_exe.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const model_catalog_metadata = @import("../gateway/model_catalog_metadata.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const provider_set = @import("../gateway/provider_set.zig");
const execution_process_provider = @import("../execution/process_provider.zig");
const github_publish = @import("../github/github_publish.zig");
const github_workflows = @import("../github/github_workflows.zig");
const host = @import("../hosts/host.zig");
const pending_revocation = @import("../auth/pending_revocation.zig");
const oauth = @import("../auth/oauth.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const secret = @import("../auth/secret.zig");
const output_contracts = @import("../output/output_contracts.zig");
const prompt_policy = @import("../config/prompt_policy.zig");
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const session_adapter = @import("../session/session_adapter.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const types = @import("../shared/types.zig");
const update_target = @import("../upgrade/update_target.zig");
const context_contract = @import("../workspace/context_contract.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const mcp_health = @import("../mcp/health.zig");
const project_config = @import("../mcp/project_config.zig");
const mcp_host = @import("../mcp_host/host.zig");
const mcp_verbs = @import("../mcp_host/verbs.zig");
const text_utils = @import("../shared/text_utils.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const workspace_commands = @import("../workspace/workspace_commands.zig");

const slack_install = @import("../slack/install.zig");
const Allocator = std.mem.Allocator;
const CommandCatalog = command_specs.TopLevelRegistry;
const TopLevelKind = command_specs.TopLevelKind;

pub const Command = union(enum) {
    interactive,
    help,
    ask: []const [:0]const u8,
    acp: []const [:0]const u8,
    pr: []const [:0]const u8,
    issue: []const [:0]const u8,
    status: []const [:0]const u8,
    mcp: []const [:0]const u8,
    slack: []const [:0]const u8,
    models: []const [:0]const u8,
    provider: []const [:0]const u8,
    doctor: []const [:0]const u8,
    session: []const [:0]const u8,
    sessions: []const [:0]const u8,
    resume_session: ResumeInvocation,
    upgrade: []const [:0]const u8,
    pair: []const [:0]const u8,
    uninstall: []const [:0]const u8,
    replay: []const [:0]const u8,
    workspace: []const [:0]const u8,
    config: []const [:0]const u8,
    completion: []const [:0]const u8,
    unknown: []const u8,
};

const ResumeInvocation = struct {
    args: []const [:0]const u8,
    top_level_alias: bool = false,
    /// Set for `spark resume`, which only the upgrade relaunch may still use: an
    /// older spark that installs this version restarts it with
    /// `spark resume <id> --upgrade-relaunch`.
    legacy_command: bool = false,
};

/// Prefix of the removed `--resume-<id>` alias, matched only to explain the
/// replacement.
const resume_id_alias_prefix = "--resume-";
pub const upgrade_relaunch_arg = "--upgrade-relaunch";

pub const UpgradeRelaunch = struct {
    previous_revision: ?[]u8 = null,

    pub fn deinit(self: *UpgradeRelaunch, alloc: Allocator) void {
        if (self.previous_revision) |revision| alloc.free(revision);
        self.* = undefined;
    }
};

// `-r` is the short form of `--resume`. Given no value, either one opens the
// session picker; given `last` or an ID, it resumes that session.
const resume_short_flag = "-r";
const resume_inline_prefix = "--resume=";

pub const ResumeTarget = union(enum) {
    remembered,
    pick,
    last,
    id: []u8,

    pub fn deinit(self: *ResumeTarget, alloc: Allocator) void {
        switch (self.*) {
            .remembered, .pick, .last => {},
            .id => |value| alloc.free(value),
        }
        self.* = undefined;
    }
};

pub const LaunchModifiers = struct {
    context_limit_overrides: []config_runtime.context_limits.Override = &.{},
    /// `--tool-placement <tool>=<toolbox|direct>`, in order; never saved.
    tool_placement_overrides: []config_runtime.tool_placement.Override = &.{},
    additional_directories: [][]u8 = &.{},
    saved_directories_suppressed: bool = false,
    provider_override: ?model_provider.ProviderId = null,
    model_override: ?[]u8 = null,
    effort_override: ?types.ReasoningEffort = null,
    fast_override: ?bool = null,
    ultrafast_override: ?bool = null,
    /// `--permission-mode` and its shortcuts; never saved.
    permission_override: ?types.PermissionMode = null,

    /// `--profile <name>`: the agent profile main runs in. Owned.
    profile_name: ?[]u8 = null,
    /// `--instances <n>`: how many spark instances the host opens at startup,
    /// each with its own session.
    instances: ?usize = null,

    pub fn deinit(self: *LaunchModifiers, alloc: Allocator) void {
        if (self.context_limit_overrides.len > 0) alloc.free(self.context_limit_overrides);
        if (self.tool_placement_overrides.len > 0) alloc.free(self.tool_placement_overrides);
        for (self.additional_directories) |path| alloc.free(path);
        if (self.additional_directories.len > 0) alloc.free(self.additional_directories);
        if (self.model_override) |model| alloc.free(model);
        if (self.profile_name) |name| alloc.free(name);
        self.* = .{};
    }

    pub fn hasWorkspaceModifiers(self: LaunchModifiers) bool {
        return self.additional_directories.len > 0 or self.saved_directories_suppressed;
    }

    pub fn hasModelOverrides(self: LaunchModifiers) bool {
        return self.provider_override != null or self.model_override != null or
            self.effort_override != null or self.fast_override != null or
            self.ultrafast_override != null or self.permission_override != null;
    }

    pub fn hasOnlyUltrafastOverride(self: LaunchModifiers) bool {
        return self.ultrafast_override != null and self.provider_override == null and
            self.model_override == null and self.effort_override == null and
            self.fast_override != true;
    }
};

pub const InteractiveLaunch = struct {
    requested_resume: ?ResumeTarget = null,
    upgrade_relaunch: ?UpgradeRelaunch = null,
    modifiers: LaunchModifiers = .{},
    /// Why the session the launch resumes could not be converted from v1
    /// (D61), for the message the launch exits with. Owned.
    resume_refusal: ?[]u8 = null,
    /// `spark "<prompt>"`: sent once the session's first frame is on screen.
    /// Owned by the allocator that parsed the launch.
    initial_prompt: ?[]u8 = null,

    pub fn deinit(self: *InteractiveLaunch, alloc: Allocator) void {
        if (self.resume_refusal) |reason| alloc.free(reason);
        if (self.requested_resume) |*target| target.deinit(alloc);
        if (self.upgrade_relaunch) |*relaunch| relaunch.deinit(alloc);
        self.modifiers.deinit(alloc);
        if (self.initial_prompt) |prompt| alloc.free(prompt);
        self.* = undefined;
    }
};

pub const RunResult = union(enum) {
    interactive: InteractiveLaunch,
    handled_success,
    handled_failure,
    handled_exit: u8,
};

/// Result for a command line spark can't accept; see `output_contracts.usage_exit_code`.
const usage_failure: RunResult = .{ .handled_exit = output_contracts.usage_exit_code };

const version_usage = "usage: spark --version\n";

pub const Config = struct {
    version: []const u8 = "",
    revision: []const u8 = "",
    build_channel: update_target.Channel = .stable,
    auth_mode: credentials.AuthMode = .local,
    command_catalog: CommandCatalog,
    default_model: []const u8,
    default_agent_step_limit: usize,
    models_path: []const u8,
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    /// The OAuth transport Slack install and MCP sign-in use. Unavailable unless
    /// the host supplies one.
    oauth_transport: oauth_transport.Provider = oauth_transport.unavailable_provider,
    provider_set: provider_set.Set,
    process_provider: execution_process_provider.Provider = execution_process_provider.unavailable_provider,
    url_opener: host.UrlOpener,
    secret_store: host.SecretStore,
    prompt_policy: prompt_policy.Policy,
    skill_root_policy: skill_contract.RootPolicy,
    ignored_list_entries: []const []const u8,
    max_list_entries: usize,
    max_read_file_bytes: usize,
    max_read_file_lines: usize,
    max_read_file_line_len: usize,
    max_command_output_bytes: usize,
    max_tool_result_bytes: usize,
    max_history_turns: usize,
    context_registry: context_contract.Registry,
    mode_registry: mode_registry.Registry,
    tool_set: tool_set_contract.ToolSet,
    inspect_mcp_profile_config: mcp_contract.InspectProfileConfigFn,
    inspect_mcp_local_config: mcp_health.InspectLocalConfigFn =
        mcp_health.inspectLocalConfigUnavailable,
    load_mcp_host: ?mcp_host.LoadFn = null,
    acp_runner: acp_runner.Runner,
};

const LocalSurfaceOptions = struct {
    format: output_contracts.OutputFormat = .text,
};

fn selectCatalogModel(
    entries: []const model_catalog.ModelCatalogEntry,
    saved: ?[]const u8,
) ?[]const u8 {
    if (saved) |candidate| {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.id, candidate)) return entry.id;
        }
    }
    return if (entries.len > 0) entries[0].id else null;
}

const UpgradeOptions = struct {
    format: output_contracts.OutputFormat = .text,
    channel: ?update_target.Channel = null,
};

const SessionListOptions = struct {
    format: output_contracts.OutputFormat = .text,
    scope: session_store.SessionListScope = .current_workspace,
    limit: usize = session_store.session_list_default_limit,
    continuation: ?session_store.ResumableSessionContinuation = null,
    /// `--live`: only the sessions an spark process has open now.
    live: bool = false,
    /// The first paging flag given, which `--live` refuses.
    paging_flag: ?[]const u8 = null,
};

const WorkspaceOptions = struct {
    format: output_contracts.OutputFormat = .text,
    action: ?workspace_commands.Action = null,
};

const SessionDetailTarget = union(enum) {
    last,
    id: []u8,

    fn deinit(self: *SessionDetailTarget, alloc: Allocator) void {
        switch (self.*) {
            .last => {},
            .id => |value| alloc.free(value),
        }
        self.* = undefined;
    }
};

const SessionDetailOptions = struct {
    format: output_contracts.OutputFormat = .text,
    target: ?SessionDetailTarget = null,
    /// `--tail`: only the last this many turns.
    tail: ?usize = null,

    fn deinit(self: *SessionDetailOptions, alloc: Allocator) void {
        if (self.target) |*target| target.deinit(alloc);
        self.* = undefined;
    }
};

const SessionRecoveryOptions = struct {
    format: output_contracts.OutputFormat = .text,
    session_id: []u8,

    fn deinit(self: *SessionRecoveryOptions, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

const AcpOptions = struct {
    agent: agent_run_flags.Overrides = .{},
    log_file: ?[]const u8 = null,

    fn deinit(self: *AcpOptions, alloc: Allocator) void {
        self.agent.deinit(alloc);
    }
};

const WorkflowOptions = struct {
    agent: agent_run_flags.Overrides = .{},
    create: bool = false,
    context: []u8 = &.{},

    fn deinit(self: *WorkflowOptions, alloc: Allocator) void {
        self.agent.deinit(alloc);
        alloc.free(self.context);
    }
};

/// An agent-run flag given a value it can't take, such as `--effort lots`.
const BadAgentValue = struct { flag: []const u8, value: []const u8 };

/// Applies one agent-run flag `match` from `docs`, noting a value the flag
/// can't take in `bad`.
fn applyAgentFlag(
    alloc: Allocator,
    agent: *agent_run_flags.Overrides,
    flag: agent_run_flags.Flag,
    docs: []const command_specs.OptionDoc,
    match: cli_flags.Match,
    bad: *?BadAgentValue,
) !void {
    const value = match.value orelse "";
    agent.apply(alloc, flag, value) catch |err| switch (err) {
        error.InvalidAgentRunValue => {
            bad.* = .{ .flag = cli_flags.flagName(docs[match.index]), .value = value };
            return err;
        },
        else => |other| return other,
    };
}

fn writeBadAgentValue(alloc: Allocator, deps: RunDeps, command: []const u8, bad: BadAgentValue) !void {
    const message = try alloc.print("spark {s}: invalid value for {s}: {f}\n", .{ command, bad.flag, text_utils.terminalSafe(bad.value) });
    defer alloc.free(message);
    try writeStderr(deps, message);
}

const WriteFn = *const fn (?*anyopaque, []const u8) anyerror!void;
const LoadStartupStateFn = *const fn (Allocator, oauth_transport.Provider, host.SecretStore, []const u8, usize) anyerror!app_lifecycle.StartupState;
const LoadStartupStateWithoutCredentialsFn = *const fn (Allocator, []const u8, usize) anyerror!app_lifecycle.StartupState;
const LoadStartupStatusFn = *const fn (Allocator, host.SecretStore, []const u8, usize) anyerror!app_lifecycle.StartupStatus;
const LoadStartupStateWithAuthModeFn = *const fn (Allocator, oauth_transport.Provider, host.SecretStore, []const u8, usize, credentials.AuthMode) anyerror!app_lifecycle.StartupState;
const LoadCatalogStartupStateWithAuthModeFn = *const fn (Allocator, host.SecretStore, []const u8, usize, credentials.AuthMode, ?model_provider.ProviderId, ?[]const u8) anyerror!app_lifecycle.StartupState;
const LoadStartupStatusWithAuthModeFn = *const fn (Allocator, host.SecretStore, []const u8, usize, credentials.AuthMode) anyerror!app_lifecycle.StartupStatus;
const EnvironMapFn = *const fn (?*anyopaque) ?*const std.process.Environ.Map;
const ReadMaskedKeyFn = *const fn (?*anyopaque, Allocator, WriteFn, ?*anyopaque) anyerror![]u8;
const SetupTerminalAvailableFn = *const fn (?*anyopaque) bool;
const RunDeps = struct {
    stdout_ctx: ?*anyopaque = null,
    stderr_ctx: ?*anyopaque = null,
    setup_ctx: ?*anyopaque = null,
    write_stdout: WriteFn = writeRealStdout,
    write_stderr: WriteFn = writeRealStderr,
    load_startup_state: LoadStartupStateFn = app_lifecycle.loadStartupState,
    load_startup_state_without_credentials: LoadStartupStateWithoutCredentialsFn = app_lifecycle.loadStartupStateWithoutCredentials,
    load_startup_status: LoadStartupStatusFn = app_lifecycle.loadStartupStatus,
    load_startup_state_with_auth_mode: LoadStartupStateWithAuthModeFn = app_lifecycle.loadStartupStateWithAuthMode,
    load_catalog_startup_state_with_auth_mode: LoadCatalogStartupStateWithAuthModeFn = app_lifecycle.loadCatalogStartupStateWithAuthMode,
    load_startup_status_with_auth_mode: LoadStartupStatusWithAuthModeFn = app_lifecycle.loadStartupStatusWithAuthMode,
    environ_map: EnvironMapFn = environMapDefault,
    read_masked_key: ReadMaskedKeyFn = readMaskedKeyDefault,
    setup_terminal_available: SetupTerminalAvailableFn = setupTerminalAvailableDefault,
};

const GlobalLaunchArgs = struct {
    remaining: []const [:0]const u8,
    modifiers: LaunchModifiers = .{},
    /// The one positional argument of `spark [flags] "<prompt>" [flags]`, borrowed
    /// from the arguments. Only set by `parseLaunchFlags(.around_prompt)`.
    prompt: ?[]const u8 = null,

    fn deinit(self: *GlobalLaunchArgs, alloc: Allocator) void {
        self.modifiers.deinit(alloc);
        self.* = undefined;
    }

    fn takeModifiers(self: *GlobalLaunchArgs) LaunchModifiers {
        const result = self.modifiers;
        self.modifiers = .{};
        return result;
    }
};

const LaunchFlag = enum {
    context_limit,
    add_dir,
    no_additional_dirs,
    tool_placement,
    provider,
    model,
    effort,
    fast,
    no_fast,
    ultrafast,
    no_ultrafast,
    permission_mode,
    full_access,
    yolo,
    profile,
    instances,
};

const launch_flag_ids = cli_flags.idTable(LaunchFlag, &builtin_commands.launch_options);

/// Reads the global flags before a command or an interactive launch. When a
/// flag repeats or conflicts, the last one wins. A malformed flag returns
/// `error.InvalidFlag`; `launchFlagFailure` describes it.
/// How `--model`, `--fast`, `--ultrafast`, and `--effort` reach the first turn
/// is modeled in `tests/tla/cli/LaunchSelection.tla`.
fn parseGlobalLaunchArgs(alloc: Allocator, args: []const [:0]const u8) !GlobalLaunchArgs {
    return parseLaunchFlags(alloc, args, .before_command);
}

const LaunchFlagMode = enum {
    /// `spark [flags] <command> ...`: stop at the first argument that isn't a
    /// launch flag, since it and everything after belong to the command.
    before_command,
    /// `spark [flags] "<prompt>" [flags]`: launch flags anywhere, and exactly one
    /// positional argument, the first prompt.
    around_prompt,
};

fn parseLaunchFlags(alloc: Allocator, args: []const [:0]const u8, comptime mode: LaunchFlagMode) !GlobalLaunchArgs {
    var overrides: std.ArrayList(config_runtime.context_limits.Override) = .empty;
    errdefer overrides.deinit(alloc);
    var placements: std.ArrayList(config_runtime.tool_placement.Override) = .empty;
    errdefer placements.deinit(alloc);
    var directories: std.ArrayList([]u8) = .empty;
    errdefer {
        for (directories.items) |path| alloc.free(path);
        directories.deinit(alloc);
    }
    var modifiers: LaunchModifiers = .{};
    errdefer {
        if (modifiers.model_override) |model| alloc.free(model);
        if (modifiers.profile_name) |name| alloc.free(name);
    }

    var prompt: ?[]const u8 = null;
    var parser: cli_flags.Parser = switch (mode) {
        .before_command => .initPrefix(&builtin_commands.launch_options, args),
        .around_prompt => .init(&builtin_commands.launch_options, args),
    };
    while (try parser.next()) |item| {
        // Prefix mode stops at positionals, so only the prompt mode sees one.
        const match = switch (item) {
            .option => |option| option,
            .positional => |positional| {
                if (prompt != null) return error.UnquotedPrompt;
                prompt = positional;
                continue;
            },
        };
        const value = match.value orelse "";
        switch (launch_flag_ids[match.index].?) {
            .context_limit => try overrides.append(alloc, try config_runtime.context_limits.parseOverride(value)),
            .tool_placement => try placements.append(alloc, try config_runtime.tool_placement.parseOverride(value)),
            .add_dir => {
                if (value.len == 0) return error.MissingAddDirectoryValue;
                try directories.append(alloc, try alloc.dupe(u8, value));
            },
            .no_additional_dirs => modifiers.saved_directories_suppressed = true,
            .provider => modifiers.provider_override = model_provider.parse(value) orelse
                return error.InvalidProviderValue,
            .model => {
                const model = std.mem.trim(u8, value, " \t\r\n");
                if (model.len == 0) return error.MissingModelValue;
                const owned_model = try alloc.dupe(u8, model);
                if (modifiers.model_override) |old| alloc.free(old);
                modifiers.model_override = owned_model;
            },
            .effort => modifiers.effort_override = types.ReasoningEffort.parse(value) orelse
                return error.InvalidEffortValue,
            .fast => {
                modifiers.fast_override = true;
                modifiers.ultrafast_override = false;
            },
            .no_fast => modifiers.fast_override = false,
            .ultrafast => {
                modifiers.ultrafast_override = true;
                modifiers.fast_override = false;
            },
            .no_ultrafast => modifiers.ultrafast_override = false,
            .permission_mode => modifiers.permission_override = types.PermissionMode.parse(value) orelse
                return error.InvalidPermissionModeValue,
            .full_access, .yolo => modifiers.permission_override = .yolo,
            .profile => {
                if (value.len == 0) return error.MissingProfileValue;
                if (!profiles.validName(value)) return error.InvalidProfileName;
                const owned = try alloc.dupe(u8, value);
                if (modifiers.profile_name) |old| alloc.free(old);
                modifiers.profile_name = owned;
            },
            .instances => {
                const count = std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidInstancesValue;
                if (count == 0) return error.InvalidInstancesValue;
                modifiers.instances = count;
            },
        }
    }

    const override_slice = try overrides.toOwnedSlice(alloc);
    errdefer if (override_slice.len > 0) alloc.free(override_slice);
    modifiers.context_limit_overrides = override_slice;
    const placement_slice = try placements.toOwnedSlice(alloc);
    errdefer if (placement_slice.len > 0) alloc.free(placement_slice);
    modifiers.tool_placement_overrides = placement_slice;
    modifiers.additional_directories = try directories.toOwnedSlice(alloc);
    return .{ .remaining = args[parser.index..], .modifiers = modifiers, .prompt = prompt };
}

/// Returns the command that follows the supported global launch modifiers.
/// Startup uses this same surface to select the full runtime configuration
/// before the allocating parser runs.
pub fn commandAfterGlobalLaunchArgs(args: []const [:0]const u8) ?[]const u8 {
    const remaining = argsAfterGlobalLaunchArgs(args);
    return if (remaining.len > 0) remaining[0] else null;
}

/// Why the global flags in `args` failed to parse, or null when they parse.
/// A flag after a first prompt, as in `spark "fix it" --jsno`, is past the
/// launch prefix, so the whole line is checked as well.
fn launchFlagFailure(args: []const [:0]const u8) ?cli_flags.Failure {
    var parser: cli_flags.Parser = .initPrefix(&builtin_commands.launch_options, args);
    while (parser.next() catch return parser.failure) |_| {}
    // Flags may also follow a resume word and its target, as in `spark -c --model x`.
    const rest = args[parser.index..];
    if (rest.len > 0 and isResumeWord(rest[0])) {
        return cli_flags.firstFailure(&builtin_commands.launch_options, rest[resumeHeadLen(rest, true)..]);
    }
    return cli_flags.firstFailure(&builtin_commands.launch_options, args);
}

/// Every flag plain `spark` reads, so an unknown one can get a suggestion.
const launch_suggestion_options = builtin_commands.launch_options ++ [_]command_specs.OptionDoc{
    .{ .flag = "--help", .description = "" },
    .{ .flag = "--version", .description = "" },
    .{ .flag = "--continue", .description = "" },
    .{ .flag = "--resume", .description = "" },
};

/// The unknown flag that follows the launch flags in `args`, with the
/// nearest flag `spark` knows. Slices borrow from `args`.
fn unknownLaunchFlagFailure(args: []const [:0]const u8) ?cli_flags.Failure {
    const remaining = argsAfterGlobalLaunchArgs(args);
    if (remaining.len == 0) return null;
    return cli_flags.firstFailure(&launch_suggestion_options, remaining[0..1]) orelse
        .{ .unknown = .{ .flag = remaining[0], .suggestion = null } };
}

/// Writes the line for a first argument that plain `spark` can't take as a
/// command, a flag, or a prompt.
fn writeLaunchWordProblem(
    writer: *std.Io.Writer,
    command_catalog: CommandCatalog,
    args: []const [:0]const u8,
    err: anyerror,
) std.Io.Writer.Error!void {
    const remaining = argsAfterGlobalLaunchArgs(args);
    const word: []const u8 = if (remaining.len > 0) remaining[0] else "";
    switch (err) {
        error.PrintFlagUseAsk => {
            const flag = if (std.mem.findScalar(u8, word, '=')) |at| word[0..at] else word;
            try writer.print("spark: {s} isn't an spark flag; to run one request and exit, use spark ask ", .{flag});
            if (printFlagPrompt(remaining)) |prompt| {
                try writer.print("\"{f}\"\n", .{text_utils.terminalSafe(prompt)});
            } else {
                try writer.writeAll("\"<prompt>\"\n");
            }
        },
        error.UnknownCommandTypo => {
            try writer.print("spark: unknown command {f}", .{text_utils.terminalSafe(word)});
            if (launchWordSuggestion(command_catalog, word)) |suggestion| {
                try writer.print(" (did you mean {s}?)", .{suggestion});
            }
            try writer.writeAll("\n");
        },
        error.EmptyLaunchPrompt => try writer.writeAll("spark: the prompt is empty\n"),
        error.UnquotedPrompt => {
            // The shell split the prompt into words; show them quoted.
            try writer.writeAll("spark: put the prompt in quotes: spark \"");
            var parser: cli_flags.Parser = .init(&builtin_commands.launch_options, args);
            var first = true;
            while (parser.next() catch null) |item| switch (item) {
                .option => {},
                .positional => |positional| {
                    if (!first) try writer.writeByte(' ');
                    try writer.writeAll(positional);
                    first = false;
                },
            };
            try writer.writeAll("\"\n");
        },
        else => {},
    }
}

/// The prompt given with `-p` or `--print`, for the `spark ask` hint.
fn printFlagPrompt(remaining: []const [:0]const u8) ?[]const u8 {
    if (remaining.len == 0) return null;
    if (std.mem.startsWith(u8, remaining[0], "--print=")) {
        const value = remaining[0]["--print=".len..];
        return if (value.len > 0) value else null;
    }
    if (remaining.len < 2 or remaining[1].len == 0 or remaining[1][0] == '-') return null;
    return remaining[1];
}

pub fn argsAfterGlobalLaunchArgs(args: []const [:0]const u8) []const [:0]const u8 {
    var parser: cli_flags.Parser = .initPrefix(&builtin_commands.launch_options, args);
    while (parser.next() catch return &.{}) |_| {}
    return args[parser.index..];
}

pub fn parse(command_catalog: CommandCatalog, args: []const [:0]const u8) Command {
    @setRuntimeSafety(false);
    if (args.len == 0) return .interactive;

    const command = args[0];
    if (command.len == 0) return .{ .unknown = command };
    switch (command[0]) {
        '-', 'h' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .help)) return .help;
            if (command_specs.matchesTopLevel(command_catalog, command, .@"resume") or
                std.mem.startsWith(u8, command, resume_inline_prefix) or
                std.mem.startsWith(u8, command, resume_id_alias_prefix))
            {
                return .{ .resume_session = .{
                    .args = args,
                    .top_level_alias = true,
                } };
            }
        },
        'a' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .ask)) return .{ .ask = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .acp)) return .{ .acp = args[1..] };
        },
        'c' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .config)) return .{ .config = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .completion)) return .{ .completion = args[1..] };
        },
        'd' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .doctor)) return .{ .doctor = args[1..] };
        },
        'i' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .issue)) return .{ .issue = args[1..] };
        },
        'm' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .mcp)) return .{ .mcp = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .models)) return .{ .models = args[1..] };
        },
        'p' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .pr)) return .{ .pr = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .provider)) return .{ .provider = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .pair)) return .{ .pair = args[1..] };
        },
        'r' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .@"resume")) return .{ .resume_session = .{ .args = args[1..], .legacy_command = true } };
            if (command_specs.matchesTopLevel(command_catalog, command, .replay)) return .{ .replay = args[1..] };
        },
        's' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .status)) return .{ .status = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .sessions)) return .{ .sessions = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .session)) {
                if (args.len > 1 and std.mem.eql(u8, args[1], "resume")) {
                    return .{ .resume_session = .{ .args = args[2..] } };
                }
                return .{ .session = args[1..] };
            }
            if (command_specs.matchesTopLevel(command_catalog, command, .slack)) return .{ .slack = args[1..] };
        },
        'u' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .upgrade)) return .{ .upgrade = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .uninstall)) return .{ .uninstall = args[1..] };
        },
        'w' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .workspace)) return .{ .workspace = args[1..] };
        },
        else => {},
    }
    return .{ .unknown = command };
}

pub const NonInteractiveLaunch = struct {
    global_args: GlobalLaunchArgs,
    effective_args: []const [:0]const u8,
    command: Command,

    pub fn deinit(self: *NonInteractiveLaunch, alloc: Allocator) void {
        self.global_args.deinit(alloc);
        self.* = undefined;
    }
};

pub const InteractiveLaunchParseResult = union(enum) {
    interactive: InteractiveLaunch,
    noninteractive: NonInteractiveLaunch,
};

/// Parses the shared interactive launch language without dispatching commands.
/// Returned launch values own their allocations and must be deinitialized.
pub fn parseInteractiveLaunch(
    alloc: Allocator,
    args: []const [:0]const u8,
    command_catalog: CommandCatalog,
) !InteractiveLaunchParseResult {
    var global_args = try parseGlobalLaunchArgs(alloc, args);
    errdefer global_args.deinit(alloc);
    const effective_args = global_args.remaining;

    if (effective_args.len == 0) {
        return .{ .interactive = .{ .modifiers = global_args.takeModifiers() } };
    }

    const command = parse(command_catalog, effective_args);
    if (topLevelHelpRequest(command_catalog, effective_args) != null) {
        return .{ .noninteractive = .{
            .global_args = global_args,
            .effective_args = effective_args,
            .command = command,
        } };
    }
    switch (command) {
        .interactive => return .{ .interactive = .{
            .modifiers = global_args.takeModifiers(),
        } },
        .resume_session => |invocation| {
            const resume_args = invocation.args;
            const has_upgrade_relaunch = !invocation.top_level_alias and
                resume_args.len >= 2 and
                std.mem.eql(u8, resume_args[1], upgrade_relaunch_arg);
            if (has_upgrade_relaunch and resume_args.len > 3) return error.InvalidResumeArgs;
            if (invocation.legacy_command and !has_upgrade_relaunch) return error.RemovedResumeCommand;
            var upgrade_relaunch: ?UpgradeRelaunch = null;
            errdefer if (upgrade_relaunch) |*relaunch| relaunch.deinit(alloc);
            if (has_upgrade_relaunch) {
                const previous_revision = if (resume_args.len == 3) revision: {
                    if (!update_target.isValidRevision(resume_args[2])) return error.InvalidResumeArgs;
                    break :revision try alloc.dupe(u8, resume_args[2]);
                } else null;
                upgrade_relaunch = .{ .previous_revision = previous_revision };
            }
            const resume_line = if (has_upgrade_relaunch) resume_args[0..1] else resume_args;
            const head_len = if (has_upgrade_relaunch) resume_line.len else resumeHeadLen(resume_line, invocation.top_level_alias);
            var prompt: ?[]const u8 = null;
            if (resume_line.len > head_len) {
                // Launch flags may follow the resume word and its target, as in
                // `spark -c --model x` or `spark session resume last --fast`. They're
                // read together with the flags before the resume word, so the
                // last one still wins.
                const before = args[0 .. args.len - effective_args.len];
                const after = resume_line[head_len..];
                const line = try alloc.alloc([:0]const u8, before.len + after.len);
                defer alloc.free(line);
                @memcpy(line[0..before.len], before);
                @memcpy(line[before.len..], after);
                var launch = parseLaunchFlags(alloc, line, .around_prompt) catch |err| {
                    // A second word after the target is a malformed resume,
                    // not an unquoted prompt.
                    if (err == error.UnquotedPrompt) return error.InvalidResumeArgs;
                    // A removed resume spelling, such as `--id`, keeps its own
                    // hint instead of reading as an unknown launch flag.
                    if (err == error.InvalidFlag) {
                        if (parseResumeArgs(alloc, resume_line, invocation.top_level_alias)) |parsed_target| {
                            var unused = parsed_target;
                            unused.deinit(alloc);
                        } else |resume_err| if (removedResumeHint(resume_err) != null) return resume_err;
                    }
                    return err;
                };
                // `spark -c` and `spark -r` take a first prompt; `spark session resume`
                // doesn't.
                if (launch.prompt != null and !invocation.top_level_alias) {
                    launch.deinit(alloc);
                    return error.InvalidResumeArgs;
                }
                prompt = launch.prompt;
                launch.remaining = &.{};
                global_args.deinit(alloc);
                global_args = launch;
            }
            if (prompt) |text| {
                if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.EmptyLaunchPrompt;
            }
            var target = try parseResumeArgs(
                alloc,
                resume_line[0..head_len],
                invocation.top_level_alias,
            );
            errdefer target.deinit(alloc);
            const initial_prompt: ?[]u8 = if (prompt) |text| try alloc.dupe(u8, text) else null;
            const relaunch = upgrade_relaunch;
            upgrade_relaunch = null;
            return .{ .interactive = .{
                .requested_resume = target,
                .upgrade_relaunch = relaunch,
                .modifiers = global_args.takeModifiers(),
                .initial_prompt = initial_prompt,
            } };
        },
        .unknown => |word| switch (classifyLaunchWord(command_catalog, word)) {
            .command_line => {},
            .print_flag => return error.PrintFlagUseAsk,
            .unknown_flag => return error.UnknownLaunchFlag,
            .command_typo => return error.UnknownCommandTypo,
            .prompt => {
                // Read the whole line again so launch flags may also follow
                // the prompt, as in `spark "fix the bug" --model x`.
                var with_prompt = try parseLaunchFlags(alloc, args, .around_prompt);
                errdefer with_prompt.deinit(alloc);
                var initial_prompt: ?[]u8 = null;
                if (with_prompt.prompt) |prompt| {
                    if (std.mem.trim(u8, prompt, " \t\r\n").len == 0) return error.EmptyLaunchPrompt;
                    initial_prompt = try alloc.dupe(u8, prompt);
                }
                global_args.deinit(alloc);
                return .{ .interactive = .{
                    .modifiers = with_prompt.takeModifiers(),
                    .initial_prompt = initial_prompt,
                } };
            },
        },
        else => {},
    }
    return .{ .noninteractive = .{
        .global_args = global_args,
        .effective_args = effective_args,
        .command = command,
    } };
}

/// How many leading words of a resume line name what to resume: the resume
/// word, when `has_resume_word` (`-c`, `-r`, `--resume`), and its target.
/// `-c`, `--continue`, and `--resume=<id>` carry their target. `-r` and
/// `--resume` take the next word as theirs unless it's a long flag, because
/// a session ID can start with a single dash; `spark session resume` does the
/// same with its first word. Every word after these is a launch flag or, for
/// the resume flags, the first prompt.
fn resumeHeadLen(line: []const [:0]const u8, has_resume_word: bool) usize {
    var len: usize = 0;
    if (has_resume_word) {
        if (line.len == 0) return 0;
        const word = line[0];
        len = 1;
        if (!std.mem.eql(u8, word, "--resume") and !std.mem.eql(u8, word, resume_short_flag)) return len;
    }
    if (line.len > len and !std.mem.startsWith(u8, line[len], "--")) len += 1;
    return len;
}

fn isResumeWord(word: []const u8) bool {
    return std.mem.eql(u8, word, "-c") or std.mem.eql(u8, word, "--continue") or
        std.mem.eql(u8, word, "--resume") or std.mem.eql(u8, word, resume_short_flag) or
        std.mem.startsWith(u8, word, resume_inline_prefix);
}

const LaunchWord = enum {
    /// Handled by command dispatch, such as `--version`.
    command_line,
    /// `-p` or `--print`, the one-shot flag of other agents.
    print_flag,
    unknown_flag,
    /// A near miss for a command name, such as `stauts`, or a flag name
    /// typed without its dashes, such as `version`.
    command_typo,
    prompt,
};

/// Decides what plain `spark` does with a first argument that isn't a command.
fn classifyLaunchWord(command_catalog: CommandCatalog, word: []const u8) LaunchWord {
    // `spark -- "-x"` lets a prompt start with a dash.
    if (std.mem.eql(u8, word, "--")) return .prompt;
    if (word.len > 0 and word[0] == '-') {
        if (isVersionFlag(word)) return .command_line;
        if (isPrintFlag(word)) return .print_flag;
        return .unknown_flag;
    }
    if (launchWordSuggestion(command_catalog, word) != null) return .command_typo;
    return .prompt;
}

fn isPrintFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print") or
        std.mem.startsWith(u8, arg, "--print=");
}

/// The command or flag a mistyped first word most likely meant, such as
/// `status` for `stauts` or `--version` for `version`. Words of four letters
/// or fewer allow one edit and longer words two, so a short prompt such as
/// `add` isn't taken for a typo of `acp`.
fn launchWordSuggestion(command_catalog: CommandCatalog, word: []const u8) ?[]const u8 {
    // Flag names people type without their dashes.
    const bare_flags = [_]struct { word: []const u8, flag: []const u8 }{
        .{ .word = "version", .flag = "--version" },
        .{ .word = "continue", .flag = "--continue" },
    };
    for (bare_flags) |entry| {
        if (std.mem.eql(u8, word, entry.word)) return entry.flag;
    }
    // Four letters or fewer get one edit, so a prompt word such as `add` isn't
    // taken for a mistyped command.
    var nearest: cli_flags.Nearest = .{ .word = word, .max_edits = if (word.len <= 4) 1 else 2 };
    for (command_catalog.specs) |spec| {
        // `spark resume` is removed; its typos shouldn't point back to it.
        if (spec.kind == .@"resume") continue;
        const names = [_][]const []const u8{ &.{spec.token}, spec.aliases };
        for (names) |group| for (group) |name| {
            if (name.len == 0 or name[0] == '-') continue;
            nearest.offer(name);
        };
    }
    return nearest.best;
}

/// Detects `spark <subcommand> --help` / `-h` and returns the subcommand kind so the
/// caller can render command-specific help. Top-level `spark --help`/`spark help` are
/// handled separately and intentionally excluded here.
fn topLevelHelpRequest(command_catalog: CommandCatalog, args: []const [:0]const u8) ?TopLevelKind {
    if (args.len < 2) return null;
    const kind = command_specs.topLevelKindFromToken(command_catalog, args[0]) orelse return null;
    if (kind == .help) return null;
    // `spark resume` was removed, so its help request gets the removal hint.
    if (kind == .@"resume" and std.mem.eql(u8, args[0], "resume")) return null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return kind;
    }
    return null;
}

/// Runs the command `args` name. A command that ends because spark couldn't
/// write its own output, stdout or stderr, returns `error.OutputWriteFailed`
/// in place of the `error.WriteFailed` a failed write gives, which on its own
/// reads as a dropped connection, and one whose output reader went away, as
/// `head` does, returns `error.OutputReaderGone`.
pub fn runIfRequested(alloc: Allocator, args: []const [:0]const u8, cfg: Config) !RunResult {
    var output: OwnOutput = .{};
    return runIfRequestedWithDeps(alloc, args, cfg, .{ .stdout_ctx = &output, .stderr_ctx = &output }) catch |err| {
        return output.commandError(err);
    };
}

/// Whether a write to spark's own stdout or stderr failed during a command, or
/// found its reader gone.
const OwnOutput = struct {
    failed: std.atomic.Value(bool) = .init(false),
    reader_gone: std.atomic.Value(bool) = .init(false),

    fn noteFailure(ctx: ?*anyopaque, err: anyerror) void {
        const self: *OwnOutput = @ptrCast(@alignCast(ctx orelse return));
        if (err == error.BrokenPipe) {
            self.reader_gone.store(true, .release);
        } else {
            self.failed.store(true, .release);
        }
    }

    /// The error the command reports for `err`.
    fn commandError(self: *const OwnOutput, err: anyerror) anyerror {
        if (err != error.WriteFailed and err != error.BrokenPipe) return err;
        if (self.reader_gone.load(.acquire)) {
            debug_trace.logf("core", "command output reader went away err={s}", .{@errorName(err)});
            return error.OutputReaderGone;
        }
        if (err != error.WriteFailed or !self.failed.load(.acquire)) return err;
        debug_trace.logf("core", "command output write failed err={s}", .{@errorName(err)});
        return error.OutputWriteFailed;
    }
};

fn runNonInteractiveWithDeps(
    alloc: Allocator,
    parsed_launch: *NonInteractiveLaunch,
    cfg: Config,
    deps: RunDeps,
) !RunResult {
    const global_args = &parsed_launch.global_args;
    const effective_args = parsed_launch.effective_args;
    const parsed_command = parsed_launch.command;

    if (global_args.modifiers.hasWorkspaceModifiers() and
        !commandSupportsWorkspaceModifiers(parsed_command))
    {
        try writeWorkspaceModifierUsage(deps);
        return usage_failure;
    }

    const acp_ultrafast_override = switch (parsed_command) {
        .acp => global_args.modifiers.hasOnlyUltrafastOverride(),
        else => false,
    };
    if (global_args.modifiers.profile_name != null) {
        try writeStderr(deps, "spark: --profile applies to interactive sessions\n");
        return usage_failure;
    }
    if (global_args.modifiers.hasModelOverrides() and !acp_ultrafast_override) {
        try writeModelModifierUsage(alloc, deps, parsed_command, global_args.modifiers);
        return usage_failure;
    }
    if (global_args.modifiers.instances != null) {
        try writeStderr(deps, "spark: --instances applies to interactive sessions\n");
        return usage_failure;
    }

    if (isVersionFlag(effective_args[0])) {
        if (effective_args.len != 1) {
            try writeStderr(deps, version_usage);
            return usage_failure;
        }
        try writeStdout(deps, cfg.version);
        try writeStdout(deps, "\n");
        return .handled_success;
    }

    // The MCP verbs print their own help, and pass `-h` after `--` to the server.
    if (topLevelHelpRequest(cfg.command_catalog, effective_args)) |kind| if (kind != .mcp) {
        const text = try command_specs.renderTopLevelCommandHelp(alloc, cfg.command_catalog, kind);
        defer alloc.free(text);
        try writeStdout(deps, text);
        return .handled_success;
    };

    switch (parsed_command) {
        .interactive, .resume_session => unreachable,
        .help => {
            try writeTopLevelHelp(alloc, cfg.command_catalog, deps, cfg.version, .stdout);
            return .handled_success;
        },
        .ask => |rest| {
            try writeMcpProfileWarningIfPresent(alloc, cfg, deps);
            const exit_code = try cli_ask.run(alloc, rest, workflowConfigWithLaunchModifiers(cfg, global_args.modifiers), cfg.context_registry, cfg.tool_set);
            return if (exit_code == 0) .handled_success else .{ .handled_exit = exit_code };
        },
        .acp => |rest| {
            var bad: ?BadAgentValue = null;
            var acp_opts = parseAcpArgs(alloc, rest, &bad) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    if (bad) |value| {
                        try writeBadAgentValue(alloc, deps, "acp", value);
                    } else {
                        try writeFlagFailure(alloc, deps, .acp, rest);
                    }
                    try writeStderr(deps, "usage: spark " ++ builtin_commands.acp_usage ++ "\n");
                    return usage_failure;
                },
            };
            defer acp_opts.deinit(alloc);
            // SPARK_SYSTEM_PROMPT_FILE names a prompt the iPhone chose: like
            // /prompt, spark sends it alone in place of its own.
            var acp_policy = cfg.prompt_policy;
            const custom_prompt = try readSystemPromptFile(alloc);
            defer if (custom_prompt) |text| alloc.free(text);
            if (custom_prompt) |text| {
                acp_policy.system_prompt = text;
                acp_policy.embedded_system_prompt = null;
                acp_policy.model_prompt_overlay_fn = null;
                acp_policy.exclusive = true;
            }
            try cfg.acp_runner.run(alloc, .{
                .auth_mode = cfg.auth_mode,
                .default_model = cfg.default_model,
                .default_agent_step_limit = cfg.default_agent_step_limit,
                .gateway_retry_count = cfg.gateway_retry_count,
                .gateway_chat_url = cfg.gateway_chat_url,
                .gateway_models_path = cfg.models_path,
                .provider_set = cfg.provider_set,
                .process_provider = cfg.process_provider,
                .secret_store = cfg.secret_store,
                .prompt_policy = acp_policy,
                .ignored_list_entries = cfg.ignored_list_entries,
                .max_list_entries = cfg.max_list_entries,
                .max_read_file_bytes = cfg.max_read_file_bytes,
                .max_read_file_lines = cfg.max_read_file_lines,
                .max_read_file_line_len = cfg.max_read_file_line_len,
                .max_command_output_bytes = cfg.max_command_output_bytes,
                .max_tool_result_bytes = cfg.max_tool_result_bytes,
                .max_history_turns = cfg.max_history_turns,
                .context_registry = cfg.context_registry,
                .mode_registry = cfg.mode_registry,
                .context_limit_overrides = global_args.modifiers.context_limit_overrides,
                .tool_placement_overrides = global_args.modifiers.tool_placement_overrides,
                .additional_directories = global_args.modifiers.additional_directories,
                .saved_directories_suppressed = global_args.modifiers.saved_directories_suppressed,
                .model_override = acp_opts.agent.model,
                .effort_override = if (acp_opts.agent.effort) |*effort| effort.label() else null,
                .fast_override = acp_opts.agent.fast,
                .ultrafast_override = acp_opts.agent.ultrafast orelse global_args.modifiers.ultrafast_override,
                .provider_override = acp_opts.agent.provider,
                .permission_override = acp_opts.agent.permission,
                .log_file = acp_opts.log_file,
            });
            return .handled_success;
        },
        .pr => |rest| return runGithubWorkflow(alloc, rest, cfg, global_args.modifiers, deps, .pull_request),
        .issue => |rest| return runGithubWorkflow(alloc, rest, cfg, global_args.modifiers, deps, .issue),
        .provider => |rest| {
            if (cli_provider_edit.handles(rest)) {
                const result = try cli_provider_edit.run(alloc, rest);
                defer alloc.free(result.text);
                switch (result.status) {
                    .ok => {
                        try writeStdout(deps, result.text);
                        return .handled_success;
                    },
                    .failed => {
                        try writeStderr(deps, result.text);
                        return .handled_failure;
                    },
                    .usage => {
                        try writeStderr(deps, result.text);
                        return usage_failure;
                    },
                }
            }
            if (rest.len != 1) {
                try writeStderr(deps, cli_provider_edit.usage);
                return usage_failure;
            }
            const target = model_provider.parse(rest[0]) orelse {
                try writeStderr(deps, "spark provider: expected a configured provider name\n");
                return usage_failure;
            };
            const activated = activateProviderSelection(alloc, deps, target) catch |err| switch (err) {
                error.UnknownConfiguredProvider => return usage_failure,
                else => return err,
            };
            return if (activated) .handled_success else .handled_failure;
        },
        .status => |rest| {
            const opts = parseLocalSurfaceArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .status, "status", err, rest);
                return usage_failure;
            };
            var startup = if (cfg.auth_mode == .host_managed)
                try deps.load_startup_status_with_auth_mode(
                    alloc,
                    cfg.secret_store,
                    cfg.default_model,
                    cfg.default_agent_step_limit,
                    cfg.auth_mode,
                )
            else
                try deps.load_startup_status(
                    alloc,
                    cfg.secret_store,
                    cfg.default_model,
                    cfg.default_agent_step_limit,
                );
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);
            var mcp_inspection = try cfg.inspect_mcp_local_config(
                alloc,
                startup.workspace_root,
            );
            defer mcp_inspection.deinit(alloc);

            var snapshot = statusSnapshotFromStartupWithBuild(startup, .{
                .channel = cfg.build_channel,
                .version = cfg.version,
                .revision = cfg.revision,
            }, mcp_inspection.profile_diagnostic);
            snapshot.mcp = localMcpView(&mcp_inspection);
            snapshot.provider_endpoint = startup.provider_endpoint;
            snapshot.modes = statusModes(cfg.mode_registry, snapshot.permission_mode);
            const spark_home = try profile_paths.activeRoot(alloc, io_mod.homeDir());
            defer if (spark_home) |path| alloc.free(path);
            snapshot.spark_home = spark_home;
            if (opts.format == .json) {
                try writeStatusJsonLine(alloc, deps, snapshot);
                return .handled_success;
            }

            const text = try snapshot.render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .slack => |rest| {
            if (rest.len == 0) {
                const help = try command_specs.renderTopLevelCommandHelp(alloc, cfg.command_catalog, .slack);
                defer alloc.free(help);
                try writeStdout(deps, help);
                return .handled_success;
            }
            const opts = slack_install.parse(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .slack, "slack", err, rest);
                return usage_failure;
            };
            var arena: std.heap.ArenaAllocator = .init(alloc);
            defer arena.deinit();
            const snapshot = slack_install.run(arena.allocator(), opts.action, cfg.oauth_transport, cfg.url_opener) catch |err| {
                try writeCommandFailure(alloc, deps, "slack", err, opts.format);
                return .handled_failure;
            };
            const text = try snapshot.render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .mcp => |rest| {
            return runTopLevelMcp(alloc, rest, cfg, deps);
        },
        .models => |rest| {
            const opts = parseLocalSurfaceArgs(modelsListArgs(rest)) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .models, "models", err, rest);
                return usage_failure;
            };

            var startup = if (cfg.auth_mode == .host_managed)
                try deps.load_catalog_startup_state_with_auth_mode(
                    alloc,
                    cfg.secret_store,
                    cfg.default_model,
                    cfg.default_agent_step_limit,
                    cfg.auth_mode,
                    null,
                    null,
                )
            else
                try deps.load_startup_state(
                    alloc,
                    cfg.oauth_transport,
                    cfg.secret_store,
                    cfg.default_model,
                    cfg.default_agent_step_limit,
                );
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);

            const catalog_access = startup.modelCatalogAccess();
            var available_providers = cfg.provider_set;
            available_providers.definitions = startup.configured_providers.definitions;
            const catalog_provider = available_providers.select(startup.provider).cli_model_catalog orelse {
                try writeStderr(deps, switch (startup.provider) {
                    .none => "spark models: no provider is set; run spark provider <name>\n",
                    .configured => "spark models: Configured model catalog is unavailable\n",
                });
                return .handled_failure;
            };
            const loaded = switch (catalog_provider.fetch(alloc, .{
                .access = catalog_access,
                .endpoint = cfg.models_path,
            })) {
                .loaded => |loaded| loaded,
                .failure => |failure| {
                    const error_name = @errorName(failure.failure.asError());
                    const message = try modelListFailureMessage(alloc, failure.failure, startup.provider);
                    defer alloc.free(message);
                    if (opts.format == .json) {
                        try writeJsonCommandFailureCode(
                            alloc,
                            deps,
                            "models",
                            error_name,
                            message,
                        );
                    } else {
                        try writeStderr(deps, "spark models: ");
                        try writeStderr(deps, message);
                        try writeStderr(deps, "\n");
                    }
                    return .handled_failure;
                },
            };
            var ids = loaded.ids;
            defer collections.freeStringList(alloc, &ids);
            var entries = loaded.entries;
            defer model_catalog.freeModelCatalog(alloc, &entries);
            defer if (loaded.notice) |notice| alloc.free(notice);
            if (loaded.notice) |notice| {
                try writeStderr(deps, "spark models: ");
                try writeStderr(deps, notice);
                try writeStderr(deps, "\n");
            }
            const details = try modelDetails(
                alloc,
                ids.items,
                entries.items,
                available_providers.select(startup.provider),
            );
            defer alloc.free(details);

            const text = try (output_contracts.ModelListSnapshot{
                .ids = ids.items,
                .details = details,
                .provider = startup.provider,
            }).render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .doctor => |rest| {
            const opts = parseDoctorArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .doctor, "doctor", err, rest);
                return usage_failure;
            };
            return runDoctor(alloc, cfg, deps, opts);
        },
        .session => |rest| {
            if (rest.len > 0 and std.mem.eql(u8, rest[0], "recover")) {
                var recovery = parseSessionRecoveryArgs(
                    alloc,
                    rest[1..],
                ) catch |err| {
                    try writeUsageOrJsonError(
                        alloc,
                        cfg.command_catalog,
                        deps,
                        .session,
                        "session",
                        err,
                        rest[1..],
                    );
                    return usage_failure;
                };
                defer recovery.deinit(alloc);
                return runSessionRecovery(alloc, deps, recovery);
            }

            var opts = parseSessionDetailArgs(alloc, rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .session, "session", err, rest);
                return usage_failure;
            };
            defer opts.deinit(alloc);

            const target = opts.target orelse {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .session, "session", error.InvalidSessionDetailArgs, rest);
                return usage_failure;
            };
            return runSessionDetail(alloc, deps, target, opts.format, opts.tail);
        },
        .sessions => |rest| {
            if (rest.len > 0 and std.mem.eql(u8, rest[0], "convert")) {
                const format = parseSessionConvertArgs(rest[1..]) catch |err| {
                    try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .sessions, "sessions", err, rest);
                    return usage_failure;
                };
                return runSessionConvert(alloc, deps, format);
            }
            const opts = parseSessionListArgs(sessionListArgs(rest)) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .sessions, "sessions", err, rest);
                return usage_failure;
            };
            if (opts.live) {
                if (opts.paging_flag) |flag| {
                    try writeLivePagingError(alloc, cfg.command_catalog, deps, flag, opts.format);
                    return usage_failure;
                }
                return runLiveSessionList(alloc, deps, opts);
            }
            return runSessionList(alloc, deps, opts);
        },
        .workspace => |rest| {
            const opts = parseWorkspaceArgs(rest) catch |err| {
                try writeWorkspaceCommandError(alloc, cfg.command_catalog, deps, rest, err);
                return usage_failure;
            };
            var startup = deps.load_startup_state_without_credentials(
                alloc,
                cfg.default_model,
                cfg.default_agent_step_limit,
            ) catch |err| {
                try writeWorkspaceCommandError(alloc, cfg.command_catalog, deps, rest, err);
                return .handled_failure;
            };
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);

            if (opts.action == null) {
                const snapshot = output_contracts.WorkspaceSnapshot.fromAccess(
                    startup.workspace_root,
                    &startup.workspace_access,
                );
                const text = try snapshot.render(alloc, opts.format);
                defer alloc.free(text);
                try writeFormattedOutput(deps, text, opts.format);
                return .handled_success;
            }

            var failure_phase: workspace_commands.FailurePhase = .stage;
            var result = workspace_commands.execute(
                alloc,
                startup.workspace_root,
                &startup.workspace_access,
                opts.action.?,
                &failure_phase,
            ) catch |err| {
                try writeWorkspaceCommandError(alloc, cfg.command_catalog, deps, rest, err);
                return .handled_failure;
            };
            defer result.deinit(alloc);

            switch (result) {
                .updated => |updated| {
                    var snapshot = output_contracts.WorkspaceSnapshot.fromAccess(startup.workspace_root, &updated.access);
                    snapshot.mutation = updated.mutation;
                    const text = try snapshot.render(alloc, opts.format);
                    defer alloc.free(text);
                    try writeFormattedOutput(deps, text, opts.format);
                    return .handled_success;
                },
                .indeterminate => |reconciliation| {
                    try writeWorkspaceIndeterminateError(alloc, deps, rest, reconciliation);
                    return .handled_failure;
                },
            }
        },
        .upgrade => |rest| {
            const upgrade_runtime = @import("../upgrade/upgrade_runtime.zig");
            var rejected_channel: ?[]const u8 = null;
            const opts = parseUpgradeArgs(rest, &rejected_channel) catch |err| {
                if (rejected_channel) |value| if (!argsContainJson(rest)) {
                    const line = try alloc.print("spark upgrade: invalid value for --channel: {f}\n", .{text_utils.terminalSafe(value)});
                    defer alloc.free(line);
                    try writeStderr(deps, line);
                };
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .upgrade, "upgrade", err, rest);
                return usage_failure;
            };

            var startup = deps.load_startup_state_without_credentials(
                alloc,
                cfg.default_model,
                cfg.default_agent_step_limit,
            ) catch |err| {
                if (opts.format == .json) {
                    try writeJsonCommandFailure(alloc, deps, "upgrade", err, "failed to load update settings");
                } else {
                    try writeStderr(deps, "spark upgrade: failed to load update settings\n");
                }
                return .handled_failure;
            };
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);

            const channel = opts.channel orelse startup.update_channel;
            if (opts.channel) |selected| {
                var outcome = config_runtime.setUserPreferences(alloc, .{ .update_channel = selected }) catch |err| {
                    if (opts.format == .json) {
                        try writeJsonCommandFailure(alloc, deps, "upgrade", err, "failed to save update channel");
                    } else {
                        try writeStderr(deps, "spark upgrade: failed to save update channel\n");
                    }
                    return .handled_failure;
                };
                defer outcome.deinit(alloc);
                if (opts.format == .text) {
                    const line = try channelSavedLine(alloc, selected, outcome);
                    defer alloc.free(line);
                    try writeStdout(deps, line);
                }
            }

            var result = upgrade_runtime.run(alloc, .{
                .channel = cfg.build_channel,
                .version = cfg.version,
                .revision = cfg.revision,
            }, channel, switch (opts.format) {
                .text => .text,
                .json => .json,
            });
            defer result.deinit(alloc);
            const text = result.snapshot.render(alloc, switch (opts.format) {
                .text => .text,
                .json => .json,
            }) catch {
                try writeStderr(deps, "spark upgrade: render failed\n");
                return .handled_failure;
            };
            defer alloc.free(text);
            try writeStdout(deps, text);
            if (opts.format == .json) try writeStdout(deps, "\n");
            return if (result.snapshot.status == .failed) .handled_failure else .handled_success;
        },
        .pair => |rest| {
            const cli_pair = @import("cli_pair.zig");
            const outcome = cli_pair.run(alloc, rest) catch |err| {
                try writeStderrLine(alloc, deps, "spark pair: couldn't start spark-bridge: {s}\n", @errorName(err));
                return .handled_failure;
            };
            switch (outcome) {
                .missing => {
                    try writeStderr(deps, "spark pair: spark-bridge isn't installed. Put it beside spark or on your PATH.\n");
                    return .handled_failure;
                },
                .exited => |code| return if (code == 0) .handled_success else .handled_failure,
            }
        },
        .uninstall => |rest| {
            const uninstall = @import("cli_uninstall.zig");
            const assume_yes = uninstall.parse(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .uninstall, "uninstall", err, rest);
                return usage_failure;
            };
            const outcome = uninstall.run(alloc, assume_yes) catch |err| {
                const message = switch (err) {
                    error.CustomSparkHome => "unset SPARK_HOME before uninstalling the default profile",
                    error.UnsafeHome => "HOME must name a user directory",
                    error.UnsafeExecutable => "the running executable must be named spark",
                    else => @errorName(err),
                };
                try writeStderrLine(alloc, deps, "spark uninstall: {s}\n", message);
                return .handled_failure;
            };
            switch (outcome) {
                .confirmation_required => {
                    try writeStderr(deps, "spark uninstall: use --yes to confirm permanent removal without a terminal\n");
                    return usage_failure;
                },
                .declined => try writeStderr(deps, "Uninstall canceled.\n"),
                .removed => try writeStdout(deps, "Removed spark and its local profile.\n"),
            }
            return .handled_success;
        },
        .completion => |rest| {
            const shell = if (rest.len == 1) completion.parseShell(rest[0]) else null;
            if (shell == null) {
                if (rest.len == 1) {
                    try writeStderrLine(alloc, deps, "spark completion: unknown shell {s}; choose bash, zsh, or fish\n", rest[0]);
                }
                try writeTopLevelUsage(cfg.command_catalog, deps, .completion);
                return usage_failure;
            }
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try completion.writeScript(alloc, &out.writer, shell.?, cfg.command_catalog, &builtin_commands.launch_options);
            try writeStdout(deps, out.written());
            return .handled_success;
        },
        .config => |rest| {
            var unknown_key: ?settings_keys.UnknownPart = null;
            var problem: ?[]const u8 = null;
            const opts = cli_config.parseArgs(rest, &unknown_key, &problem) catch |err| {
                if (problem) |text| {
                    if (argsContainJson(rest)) {
                        try writeJsonCommandFailure(alloc, deps, "config", err, text);
                        return usage_failure;
                    }
                    try writeStderrLine(alloc, deps, "spark config: {s}\n", text);
                }
                if (!argsContainJson(rest)) {
                    if (unknown_key) |part| {
                        const message = try settings_messages.formatUnknownPath(alloc, part);
                        defer alloc.free(message);
                        try writeStderrLine(alloc, deps, "spark config: {s}\n", message);
                    } else if (err == error.WorkspaceConfigWrite) {
                        try writeStderr(deps, "spark config: " ++ workspace_write_message ++ "\n");
                    }
                }
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .config, "config", err, rest);
                return usage_failure;
            };
            return switch (opts.action) {
                .list, .get => runConfig(alloc, cfg, deps, opts),
                .set, .unset => runConfigWrite(alloc, deps, opts),
                .schema => runConfigSchema(alloc, deps, opts),
            };
        },
        .replay => |rest| {
            const exit_code = try cli_replay.run(alloc, rest);
            return if (exit_code == 0) .handled_success else .{ .handled_exit = exit_code };
        },
        .unknown => |command| {
            try writeStderr(deps, "spark: unknown subcommand: ");
            try writeStderr(deps, command);
            try writeStderr(deps, "\n\n");
            try writeTopLevelHelp(alloc, cfg.command_catalog, deps, cfg.version, .stderr);
            return error.UnknownCliCommand;
        },
    }
}

/// One detail per id when the provider described its models, by the same capability merge a
/// session uses for its effort and speed options. Empty when
/// there are no entries. Names borrow from `entries`. Caller frees the returned slice.
fn modelDetails(
    alloc: Allocator,
    ids: []const []const u8,
    entries: []const model_catalog.ModelCatalogEntry,
    bundle: provider_set.Bundle,
) ![]const output_contracts.ModelDetail {
    if (entries.len == 0) return &.{};
    const details = try alloc.alloc(output_contracts.ModelDetail, ids.len);
    for (ids, details) |id, *detail| {
        const entry = for (entries) |candidate| {
            if (std.mem.eql(u8, candidate.id, id)) break candidate;
        } else null;
        const capabilities = model_capabilities.mergeCapabilities(
            bundle.fallbackModelCapabilities(id),
            if (entry) |found| model_catalog_metadata.fromCatalogEntry(found) else null,
        );
        detail.* = .{
            .name = if (entry) |found| found.name else null,
            .efforts = capabilities.reasoning_efforts,
            .fast = capabilities.supports_fast_mode,
            .ultrafast = capabilities.supports_ultrafast_mode,
        };
    }
    return details;
}

fn catalogFailureDetail(failure: model_catalog.Failure) []const u8 {
    return switch (failure.category) {
        .authentication => "AuthenticationRejected",
        .cancellation => "the request was cancelled",
        .malformed_response => "MalformedResponse",
        .resource_exhausted => "OutOfMemory",
        .rate_limited, .gateway_unavailable, .transport, .http_status, .runtime => "Unavailable",
    };
}

fn workflowConfig(cfg: Config) @import("cli_ask.zig").Config {
    return .{
        .auth_mode = cfg.auth_mode,
        .command_usage = command_specs.topLevelUsage(cfg.command_catalog, .ask),
        .default_model = cfg.default_model,
        .default_agent_step_limit = cfg.default_agent_step_limit,
        .gateway_retry_count = cfg.gateway_retry_count,
        .gateway_chat_url = cfg.gateway_chat_url,
        .gateway_models_path = cfg.models_path,
        .oauth_transport = cfg.oauth_transport,
        .provider_set = cfg.provider_set,
        .process_provider = cfg.process_provider,
        .secret_store = cfg.secret_store,
        .prompt_policy = cfg.prompt_policy,
        .skill_root_policy = cfg.skill_root_policy,
        .ignored_list_entries = cfg.ignored_list_entries,
        .max_list_entries = cfg.max_list_entries,
        .max_read_file_bytes = cfg.max_read_file_bytes,
        .max_read_file_lines = cfg.max_read_file_lines,
        .max_read_file_line_len = cfg.max_read_file_line_len,
        .max_command_output_bytes = cfg.max_command_output_bytes,
        .max_tool_result_bytes = cfg.max_tool_result_bytes,
        .max_history_turns = cfg.max_history_turns,
        .mode_registry = cfg.mode_registry,
        .load_mcp_host = cfg.load_mcp_host,
    };
}

/// The line `spark logout` writes to a terminal's stderr while it waits for the
/// provider to revoke the login, so a slow provider does not look like a hang.
/// Like doctor's wait notice, pipes and unit tests never get it.
const LogoutWaitLine = struct {
    deps: RunDeps,
    text: []const u8,

    const request_s = oauth_transport.default_request_timeout_ms / std.time.ms_per_s;
    /// Before a retry of sign-outs that earlier logouts kept
    /// (`pending_revocation.retry`), which sends one sign-out after another.
    const mcp_kept = std.fmt.comptimePrint("revoking earlier MCP sign-outs at their servers (up to {d} s each)...\n", .{request_s});

    fn notice(self: *const LogoutWaitLine) ?oauth.BeforeRevocation {
        if (builtin.is_test or !stderrIsTerminal()) return null;
        return .{ .context = self, .run = write };
    }

    fn write(context: *const anyopaque) void {
        const self: *const LogoutWaitLine = @ptrCast(@alignCast(context));
        writeStderr(self.deps, self.text) catch |err| {
            debug_trace.logf("auth", "logout wait line not written err={s}", .{@errorName(err)});
        };
    }
};

fn testConfig() Config {
    return .{
        .version = "0.0.0",
        .command_catalog = testCommandCatalog(),
        .default_model = "test-model",
        .default_agent_step_limit = 42,
        .models_path = "/v1/models",
        .gateway_retry_count = 1,
        .gateway_chat_url = "https://example.test/chat",
        .provider_set = @import("../../builtins/providers.zig").native,
        .url_opener = host.unavailable_url_opener,
        .secret_store = host.unavailable_secret_store,
        .prompt_policy = .{ .system_prompt = "system" },
        .skill_root_policy = .{ .managed_root_source = .global_spark },
        .ignored_list_entries = &.{},
        .max_list_entries = 10,
        .max_read_file_bytes = 1024,
        .max_read_file_lines = 100,
        .max_read_file_line_len = 200,
        .max_command_output_bytes = 4096,
        .max_tool_result_bytes = 4096,
        .max_history_turns = 8,
        .context_registry = test_surface_context_registry,
        .mode_registry = .{ .default_mode_id = "surface" },
        .inspect_mcp_profile_config = clearMcpConfigInspectionForTest,
        .acp_runner = .{ .run_fn = unexpectedAcpRunForTest },
        .tool_set = .{
            .registry = .{ .tools = &.{} },
            .order = &.{},
            .read_only_tool_names = &.{},
        },
    };
}

fn stubLoadStartupState(
    alloc: Allocator,
    _: oauth_transport.Provider,
    _: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !app_lifecycle.StartupState {
    var state = app_lifecycle.StartupState{ .agent_step_limit = default_agent_step_limit };
    errdefer state.deinit(alloc);
    state.workspace_root = try alloc.dupe(u8, "/tmp/spark");
    state.selected_model = try alloc.dupe(u8, default_model);
    state.credential = .{
        .token = try alloc.dupe(u8, "test-key"),
        .source = .configured,
    };
    state.credential.?.team_id = try alloc.dupe(u8, "team_123");
    return state;
}

test "a command that ends because spark couldn't write its output reports that write" {
    var output: OwnOutput = .{};
    // A failed write elsewhere, such as to the network, keeps its name.
    try std.testing.expectEqual(@as(anyerror, error.WriteFailed), output.commandError(error.WriteFailed));
    OwnOutput.noteFailure(&output, error.WriteFailed);
    try std.testing.expectEqual(@as(anyerror, error.OutputWriteFailed), output.commandError(error.WriteFailed));
    try std.testing.expectEqual(@as(anyerror, error.NoSpaceLeft), output.commandError(error.NoSpaceLeft));
}

fn runNoConfigIfRequestedWithDeps(
    alloc: Allocator,
    args: []const [:0]const u8,
    version: []const u8,
    command_catalog: CommandCatalog,
    deps: RunDeps,
) !bool {
    if (args.len != 1 or !command_specs.matchesTopLevel(command_catalog, args[0], .help)) {
        return false;
    }
    try writeTopLevelHelp(alloc, command_catalog, deps, version, .stdout);
    return true;
}

fn writeProviderActivationError(alloc: Allocator, deps: RunDeps, detail: []const u8) !void {
    const message = try alloc.print("spark provider: {s}\n", .{detail});
    defer alloc.free(message);
    try writeStderr(deps, message);
}

fn writeHostManagedAuthResult(deps: RunDeps) !void {
    try writeStdout(deps, credentials.host_managed_auth_message);
    try writeStdout(deps, "\n");
}

/// Makes the configured provider `target` the saved selection, with the model
/// saved for it, else the first one its settings declare.
fn activateProviderSelection(alloc: Allocator, deps: RunDeps, target: model_provider.ProviderId) !bool {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace_root);
    var settings = config_runtime.loadMergedSettings(alloc, workspace_root) catch |err| {
        const message = try config_runtime.configuredProviderMessage(alloc, err);
        defer if (message) |text| alloc.free(text);
        try writeProviderActivationError(alloc, deps, message orelse "could not load settings");
        debug_trace.logf("config", "provider selection settings load failed err={s}", .{@errorName(err)});
        return false;
    };
    defer settings.deinit(alloc);

    const bound = target.bind(settings.providers orelse .{}) catch |err| switch (err) {
        error.UnknownConfiguredProvider => {
            const detail = try config_runtime.unknownProviderMessage(alloc, target.label());
            defer alloc.free(detail);
            try writeProviderActivationError(alloc, deps, detail);
            // A name spark doesn't know is a bad argument, so the caller
            // exits as a usage error.
            return error.UnknownConfiguredProvider;
        },
        error.ConfiguredProviderChanged, error.ConfiguredProviderRemoved => return err,
    };
    const definition = if (settings.providers) |providers| providers.get(bound.label()) else null;
    const selected_model = settings.models.get(bound) orelse
        (if (definition) |value| (if (value.model_metadata.len > 0) value.model_metadata[0].id else null) else null) orelse {
        try writeProviderActivationError(alloc, deps, "the provider declares no models; add one with /provider");
        return false;
    };
    var attempt = config_runtime.attemptUserPreferences(alloc, .{
        .provider = bound,
        .model_preference = .{ .provider = bound, .model = selected_model },
    });
    defer attempt.deinit(alloc);
    switch (attempt) {
        .failure => {
            try writeProviderActivationError(alloc, deps, "failed to save provider selection");
            return false;
        },
        .outcome => {},
    }
    const message = try alloc.print("Provider set to {s} with {s}.\n", .{ bound.label(), selected_model });
    defer alloc.free(message);
    try writeStdout(deps, message);
    return true;
}

fn runIfRequestedWithDeps(alloc: Allocator, args: []const [:0]const u8, cfg: Config, deps: RunDeps) !RunResult {
    const parsed_launch = parseInteractiveLaunch(alloc, args, cfg.command_catalog) catch |err| {
        if (err == error.InvalidResumeArgs) {
            try writeTopLevelUsage(cfg.command_catalog, deps, .@"resume");
            return usage_failure;
        }
        if (removedResumeHint(err)) |hint| {
            try writeStderr(deps, hint);
            return usage_failure;
        }
        var writer: std.Io.Writer.Allocating = .init(alloc);
        defer writer.deinit();
        switch (err) {
            error.PrintFlagUseAsk, error.UnknownCommandTypo, error.EmptyLaunchPrompt, error.UnquotedPrompt => {
                try writeLaunchWordProblem(&writer.writer, cfg.command_catalog, args, err);
                try writeStderr(deps, writer.written());
                return usage_failure;
            },
            else => {},
        }
        if (err == error.InvalidFlag or err == error.UnknownLaunchFlag) {
            try writer.writer.writeAll("spark: ");
            const failure = if (err == error.InvalidFlag) launchFlagFailure(args) else unknownLaunchFlagFailure(args);
            if (failure) |found| try found.write(&writer.writer);
            try writer.writer.writeAll("\n");
        } else if (globalLaunchErrorMessage(err)) |message| {
            try writer.writer.print("spark: {s}\n", .{message});
        } else {
            try writer.writer.print("spark: invalid global launch option: {s}\n", .{@errorName(err)});
        }
        try writer.writer.writeAll(builtin_commands.launch_usage);
        try writeStderr(deps, writer.written());
        return usage_failure;
    };
    switch (parsed_launch) {
        .interactive => |launch| {
            if (launch.modifiers.profile_name) |name| {
                if (try app_profile_runtime.launchFailure(alloc, name)) |message| {
                    defer alloc.free(message);
                    try writeStderr(deps, message);
                    var rejected = launch;
                    rejected.deinit(alloc);
                    return .handled_failure;
                }
            }
            try writeMcpProfileWarningIfPresent(alloc, cfg, deps);
            return .{ .interactive = launch };
        },
        .noninteractive => |value| {
            var noninteractive = value;
            defer noninteractive.deinit(alloc);
            return runNonInteractiveWithDeps(alloc, &noninteractive, cfg, deps);
        },
    }
}

const TopLevelHelpDestination = enum { stdout, stderr };

fn writeTopLevelHelp(
    alloc: Allocator,
    command_catalog: CommandCatalog,
    deps: RunDeps,
    version: []const u8,
    destination: TopLevelHelpDestination,
) !void {
    const text = try command_specs.renderTopLevelHelp(
        alloc,
        command_catalog,
        command_specs.top_level_help_default_width,
        version,
    );
    defer alloc.free(text);
    switch (destination) {
        .stdout => try writeStdout(deps, text),
        .stderr => try writeStderr(deps, text),
    }
}

fn runGithubWorkflow(
    alloc: Allocator,
    args: []const [:0]const u8,
    cfg: Config,
    launch_modifiers: LaunchModifiers,
    deps: RunDeps,
    workflow: github_workflows.Workflow,
) !RunResult {
    var bad: ?BadAgentValue = null;
    var opts = parseWorkflowArgs(alloc, args, &bad) catch |err| switch (err) {
        error.InvalidWorkflowArgs, error.InvalidAgentRunValue => {
            const kind: TopLevelKind = switch (workflow) {
                .pull_request => .pr,
                .issue => .issue,
            };
            if (bad) |value| {
                try writeBadAgentValue(alloc, deps, @tagName(kind), value);
            } else {
                try writeFlagFailure(alloc, deps, kind, args);
            }
            try writeTopLevelUsage(cfg.command_catalog, deps, kind);
            return usage_failure;
        },
        else => return err,
    };
    defer opts.deinit(alloc);

    const prompt = switch (workflow) {
        .pull_request => github_workflows.buildPrompt(alloc, workflow, workflowLanguagePlaceholder(), opts.context) catch |err| switch (err) {
            error.NotGitRepository => {
                try writeStderr(deps, "spark pr: requires running inside a git repository\n");
                return .handled_failure;
            },
            else => return err,
        },
        .issue => try github_workflows.buildPrompt(alloc, workflow, workflowLanguagePlaceholder(), opts.context),
    };
    defer alloc.free(prompt);

    const workflow_cfg = workflowConfigWithLaunchModifiers(cfg, launch_modifiers);
    if (!opts.create) {
        const exit_code = try cli_ask.runPrompt(alloc, prompt, opts.agent, workflow_cfg, cfg.context_registry, cfg.tool_set);
        return if (exit_code == 0) .handled_success else .handled_failure;
    }

    const run_result = try cli_ask.runPromptCapture(alloc, prompt, opts.agent, workflow_cfg, cfg.context_registry, cfg.tool_set);
    defer run_result.deinit(alloc);
    if (run_result.exit_code != 0) return .handled_failure;

    const draft = draftFromRun(alloc, run_result) catch {
        try writeStderr(deps, switch (workflow) {
            .pull_request => "spark pr: failed to parse drafted PR title/body\n",
            .issue => "spark issue: failed to parse drafted issue title/body\n",
        });
        return .handled_failure;
    };
    defer draft.deinit(alloc);

    const published = try github_publish.publish(alloc, switch (workflow) {
        .pull_request => .pull_request,
        .issue => .issue,
    }, draft);
    defer published.deinit(alloc);
    if (!published.ok) {
        try writeStderr(deps, switch (workflow) {
            .pull_request => "spark pr: ",
            .issue => "spark issue: ",
        });
        try writeStderr(deps, published.text);
        try writeStderr(deps, "\n");
        return .handled_failure;
    }
    try writeStdout(deps, published.text);
    try writeStdout(deps, "\n");
    return .handled_success;
}

/// Parses the draft from the completed final response only, so text the model
/// wrote before a tool call never becomes the title or body.
fn draftFromRun(alloc: Allocator, run_result: cli_ask.PromptRunResult) !github_publish.Draft {
    return github_publish.parseDraft(alloc, run_result.final_source);
}

/// The prompt in `SPARK_SYSTEM_PROMPT_FILE`, or null when the variable is
/// unset or the file is empty. Caller owns the result.
fn readSystemPromptFile(alloc: Allocator) !?[]u8 {
    const path = io_mod.getenv("SPARK_SYSTEM_PROMPT_FILE") orelse return null;
    if (path.len == 0) return null;
    const text = prompts.read(alloc, path) catch |err| {
        debug_trace.logf("acp", "system prompt file unreadable err={s}", .{@errorName(err)});
        return err;
    };
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        alloc.free(text);
        return null;
    }
    return text;
}

fn writeStdout(deps: RunDeps, text: []const u8) !void {
    try deps.write_stdout(deps.stdout_ctx, text);
}

fn writeStderr(deps: RunDeps, text: []const u8) !void {
    try deps.write_stderr(deps.stderr_ctx, text);
}

/// Reads and stores an AI Gateway API key. `command` names the command in
/// failure messages: `spark login` for `spark login --api-key`, `spark setup` for the
/// deprecated spelling.
fn runPasteSetup(
    alloc: Allocator,
    secret_store: host.SecretStore,
    deps: RunDeps,
    command: []const u8,
) !bool {
    if (secret_store.isDisabled()) {
        try writePasteFailure(alloc, deps, command, "stored API keys are disabled by SPARK_DISABLE_KEYCHAIN");
        return false;
    }
    if (!deps.setup_terminal_available(deps.setup_ctx)) {
        try writePasteFailure(alloc, deps, command, "an interactive terminal is required to paste an API key");
        return false;
    }

    try writeStderr(deps, "Paste AI Gateway API key (input hidden): ");
    const stored_interactively = secret_store.storeInteractive() catch {
        try writeStderr(deps, "\n");
        try writePasteFailure(alloc, deps, command, "API key was not saved");
        return false;
    };
    if (!stored_interactively) {
        const key = deps.read_masked_key(
            deps.setup_ctx,
            alloc,
            deps.write_stderr,
            deps.stderr_ctx,
        ) catch {
            try writeStderr(deps, "\n");
            try writePasteFailure(alloc, deps, command, "API key was not saved");
            return false;
        };
        defer secret.zeroAndFree(alloc, key);
        try writeStderr(deps, "\n");
        secret_store.store(alloc, key) catch {
            try writePasteFailure(alloc, deps, command, "API key was not saved");
            return false;
        };
    }

    const message = try alloc.print(
        "Saved API key to {s}.\n",
        .{secret_store.backend_label},
    );
    defer alloc.free(message);
    try writeStdout(deps, message);
    return true;
}

fn writePasteFailure(alloc: Allocator, deps: RunDeps, command: []const u8, problem: []const u8) !void {
    const message = try alloc.print("{s}: {s}\n", .{ command, problem });
    defer alloc.free(message);
    try writeStderr(deps, message);
}

fn setupTerminalAvailableDefault(_: ?*anyopaque) bool {
    return std.c.isatty(std.posix.STDIN_FILENO) != 0 and
        std.c.isatty(std.posix.STDERR_FILENO) != 0;
}

fn readMaskedKeyDefault(
    _: ?*anyopaque,
    alloc: Allocator,
    write_mask: WriteFn,
    write_ctx: ?*anyopaque,
) ![]u8 {
    var raw = try MaskedKeyRawMode.enable();
    defer raw.disable();

    var input: std.ArrayList(u8) = .empty;
    errdefer {
        if (input.capacity > 0) secret.zeroAndFree(alloc, input.allocatedSlice());
    }

    while (input.items.len < 8 * 1024) {
        var byte: [1]u8 = undefined;
        if (try std.posix.read(std.posix.STDIN_FILENO, &byte) == 0) return error.SetupCancelled;
        switch (byte[0]) {
            '\r', '\n' => {
                if (input.items.len == 0) continue;
                // toOwnedSlice shrinks through realloc, which may move the buffer
                // and free the original without zeroing it. Copy out and wipe the
                // source so no unzeroed key is left behind in freed memory.
                const owned = try alloc.dupe(u8, input.items);
                secret.zeroAndFree(alloc, input.allocatedSlice());
                input = .empty;
                return owned;
            },
            3, 4, 0x1b => return error.SetupCancelled,
            8, 127 => if (input.items.len > 0) {
                _ = input.pop();
                try write_mask(write_ctx, "\x08 \x08");
            },
            0x20...0x7e => {
                try input.append(alloc, byte[0]);
                try write_mask(write_ctx, "•");
            },
            else => {},
        }
    }
    return error.SetupKeyTooLong;
}

const MaskedKeyRawMode = struct {
    original: std.posix.termios = undefined,
    active: bool = false,

    fn enable() !MaskedKeyRawMode {
        if (std.c.isatty(std.posix.STDIN_FILENO) == 0 or
            std.c.isatty(std.posix.STDERR_FILENO) == 0)
        {
            return error.NotATerminal;
        }

        var self: MaskedKeyRawMode = .{};
        self.original = try io_mod.tcgetattr(std.posix.STDIN_FILENO);
        var raw = self.original;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.iflag.IXOFF = false;
        raw.cflag.CSIZE = .CS8;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        const vmin_idx = switch (builtin.target.os.tag) {
            .linux => 6,
            else => 16,
        };
        const vtime_idx = switch (builtin.target.os.tag) {
            .linux => 5,
            else => 17,
        };
        if (vmin_idx < raw.cc.len and vtime_idx < raw.cc.len) {
            raw.cc[vmin_idx] = 1;
            raw.cc[vtime_idx] = 0;
        }
        try io_mod.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
        self.active = true;
        return self;
    }

    fn disable(self: *MaskedKeyRawMode) void {
        if (!self.active) return;
        io_mod.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original) catch {};
        self.active = false;
    }
};

fn writeConfigDiagnostics(
    alloc: Allocator,
    deps: RunDeps,
    diagnostics: []const config_runtime.ConfigDiagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        const note = diagnostic.note();
        if (note == null and !diagnostic.reportAtStartup()) continue;
        var notice_writer: std.Io.Writer.Allocating = .init(alloc);
        defer notice_writer.deinit();
        if (note) |text| {
            try notice_writer.writer.print("spark: note: {s}", .{text});
        } else {
            try notice_writer.writer.print(
                "spark: config {s}: {s}",
                .{ @tagName(diagnostic.layer), @tagName(diagnostic.cause) },
            );
            try config_runtime.writeDiagnosticMetadata(&notice_writer.writer, diagnostic);
        }
        try notice_writer.writer.writeByte('\n');
        const notice = try notice_writer.toOwnedSlice();
        defer alloc.free(notice);
        try writeStderr(deps, notice);
    }
}

fn writeFormattedOutput(deps: RunDeps, text: []const u8, format: output_contracts.OutputFormat) !void {
    switch (format) {
        .text => try writeStdout(deps, text),
        .json => try writeJsonLine(deps, text),
    }
}

fn writeJsonLine(deps: RunDeps, text: []const u8) !void {
    @setRuntimeSafety(false);
    var buf: [4096]u8 = undefined;
    if (text.len < buf.len) {
        @memcpy(buf[0..text.len], text);
        buf[text.len] = '\n';
        return writeStdout(deps, buf[0 .. text.len + 1]);
    }

    try writeStdout(deps, text);
    try writeStdout(deps, "\n");
}

const JsonLinePayload = union(enum) {
    status: output_contracts.StatusSnapshot,
    doctor: output_contracts.DoctorSnapshot,
};

fn writeRenderedJsonLine(alloc: Allocator, deps: RunDeps, fixed_buffer: []u8, payload: JsonLinePayload) !void {
    var writer: std.Io.Writer = .fixed(fixed_buffer);
    renderJsonLinePayload(&writer, payload) catch |err| switch (err) {
        error.WriteFailed => {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try renderJsonLinePayload(&out.writer, payload);
            return writeJsonLine(deps, out.writer.buffered());
        },
    };
    try writeJsonLine(deps, writer.buffered());
}

fn renderJsonLinePayload(writer: *std.Io.Writer, payload: JsonLinePayload) std.Io.Writer.Error!void {
    switch (payload) {
        .status => |snapshot| try snapshot.writeJson(writer),
        .doctor => |snapshot| try snapshot.writeJson(writer),
    }
}

fn writeStatusJsonLine(alloc: Allocator, deps: RunDeps, snapshot: output_contracts.StatusSnapshot) !void {
    var buf: [1024]u8 = undefined;
    try writeRenderedJsonLine(alloc, deps, buf[0..], .{ .status = snapshot });
}

fn statusSnapshotFromStartup(startup: app_lifecycle.StartupStatus) output_contracts.StatusSnapshot {
    return statusSnapshotFromStartupWithBuild(startup, .{
        .channel = .stable,
        .version = "",
        .revision = "",
    }, .clear);
}

fn statusSnapshotFromStartupWithBuild(
    startup: app_lifecycle.StartupStatus,
    build: update_target.CurrentBuild,
    mcp_config_diagnostic: mcp_contract.ProfileConfigDiagnostic,
) output_contracts.StatusSnapshot {
    return .{
        .model = startup.selected_model,
        .model_origin = startup.model_origin.label(),
        .effort = startup.effort,
        .provider = startup.provider,
        .permission_mode = permissionModeForSnapshot(startup.permission_mode),
        .workspace_root = startup.workspace_root,
        .history_turns = 0,
        .agent_step_limit = startup.agent_step_limit,
        .ultrafast_requested = startup.ultrafast_mode,
        .update_channel = startup.update_channel.label(),
        .build_channel = build.channel.label(),
        .build_revision = build.revision,
        .mcp_config_error = switch (mcp_config_diagnostic) {
            .clear, .warning => null,
            .failed => |err| @errorName(err),
        },
        .mcp_config_warning = switch (mcp_config_diagnostic) {
            .warning => |warning| warning,
            .clear, .failed => null,
        },
    };
}

fn writeDoctorJsonLine(alloc: Allocator, deps: RunDeps, snapshot: output_contracts.DoctorSnapshot) !void {
    var buf: [4096]u8 = undefined;
    try writeRenderedJsonLine(alloc, deps, buf[0..], .{ .doctor = snapshot });
}

fn doctorSnapshotFromRuntime(snapshot: doctor_runtime.Snapshot) output_contracts.DoctorSnapshot {
    return .{
        .workspace_root = snapshot.workspace_root,
        .model = snapshot.model,
        .provider = snapshot.provider,
        .permission_mode = permissionModeForSnapshot(snapshot.permission_mode),
        .agent_step_limit = snapshot.agent_step_limit,
        .checks = snapshot.checks,
    };
}

fn writeRealStdout(ctx: ?*anyopaque, text: []const u8) !void {
    const written = if (comptime builtin.target.os.tag != .windows)
        writeFdAll(std.posix.STDOUT_FILENO, text)
    else
        std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
    written catch |err| {
        OwnOutput.noteFailure(ctx, err);
        return err;
    };
}

fn writeRealStderr(ctx: ?*anyopaque, text: []const u8) !void {
    const written = if (comptime builtin.target.os.tag != .windows)
        writeFdAll(std.posix.STDERR_FILENO, text)
    else
        std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), text);
    written catch |err| {
        OwnOutput.noteFailure(ctx, err);
        return err;
    };
}

fn writeFdAll(fd: std.posix.fd_t, text: []const u8) !void {
    @setRuntimeSafety(false);
    var remaining = text;
    while (remaining.len > 0) {
        const written = std.c.write(fd, remaining.ptr, remaining.len);
        if (written <= 0) {
            // A reader that went away, as `head` does, is told apart.
            if (written < 0 and std.posix.errno(written) == .PIPE) return error.BrokenPipe;
            return error.WriteFailed;
        }
        remaining = remaining[@intCast(written)..];
    }
}

fn environMapDefault(_: ?*anyopaque) ?*const std.process.Environ.Map {
    return io_mod.environMap();
}

fn writeTopLevelUsage(command_catalog: CommandCatalog, deps: RunDeps, kind: TopLevelKind) !void {
    try writeStderr(deps, "usage: spark ");
    try writeStderr(deps, command_specs.topLevelUsage(command_catalog, kind));
    try writeStderr(deps, "\n");
}

fn localMcpView(
    inspection: *const mcp_health.LocalConfigInspection,
) output_contracts.McpLocalSnapshot {
    return .{
        .servers = inspection.snapshot.servers,
        .configuration_issues = inspection.snapshot.configuration_issues,
        .inspection_error = inspection.inspection_error,
    };
}

fn runTopLevelMcp(
    alloc: Allocator,
    rest: []const [:0]const u8,
    cfg: Config,
    deps: RunDeps,
) !RunResult {
    return runMcpVerbs(alloc, rest, cfg, deps);
}

/// `spark mcp`: the verbs `/mcp` shares.
fn runMcpVerbs(alloc: Allocator, rest: []const [:0]const u8, cfg: Config, deps: RunDeps) !RunResult {
    const home = io_mod.homeDir() orelse {
        try writeStderr(deps, "spark mcp: " ++ io_mod.no_home_dir_reason ++ "\n");
        return .handled_failure;
    };
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace_root);
    // `SPARK_TRACE` and `SPARK_TRACE_LOG` keep a trace here, as in the shell.
    debug_trace.configureFromEnv(alloc, workspace_root);
    const args = try alloc.alloc([]const u8, rest.len);
    defer alloc.free(args);
    for (rest, args) |r, *a| a.* = r;
    var out_buffer: [1024]u8 = undefined;
    var err_buffer: [512]u8 = undefined;
    var out: DepsWriter = .init(deps, .stdout, &out_buffer);
    var err: DepsWriter = .init(deps, .stderr, &err_buffer);
    var hosts: CliMcpHosts = .{ .alloc = alloc, .cfg = cfg, .workspace_root = workspace_root };
    const wait_line: LogoutWaitLine = .{ .deps = deps, .text = LogoutWaitLine.mcp_kept };
    const code = mcp_verbs.run(.{
        .gpa = alloc,
        .out = &out.interface,
        .err = &err.interface,
        .surface = .cli,
        .home = home,
        .workspace_root = workspace_root,
        .hosts = .{ .context = &hosts, .get = CliMcpHosts.get, .release = CliMcpHosts.release, .changed = CliMcpHosts.changed },
        .kept_sign_outs = .{ .transport = cfg.oauth_transport, .notice = wait_line.notice() },
    }, args);
    return switch (code) {
        0 => .handled_success,
        1 => .handled_failure,
        else => .{ .handled_exit = code },
    };
}

/// A host made for one `spark mcp` command.
const CliMcpHosts = struct {
    alloc: Allocator,
    cfg: Config,
    workspace_root: []const u8,

    fn get(context: *anyopaque, notify: ?mcp_verbs.Notify) anyerror!?*mcp_host.Host {
        const self: *CliMcpHosts = @ptrCast(@alignCast(context));
        const load = self.cfg.load_mcp_host orelse return null;
        return load(self.alloc, self.workspace_root, self.cfg.tool_set.registry, .{ .notify = notify });
    }

    /// `spark mcp` exits after its one command, so nothing waits for the
    /// servers; a logout already waited for its revocation.
    fn release(_: *anyopaque, _: *mcp_host.Host) void {
        mcp_host.signalServersForExit();
    }

    fn changed(_: *anyopaque) void {}
};

/// Streams through `deps`, so `login` shows its address while it waits.
const DepsWriter = struct {
    deps: RunDeps,
    stream: enum { stdout, stderr },
    interface: std.Io.Writer,

    fn init(deps: RunDeps, stream: @FieldType(DepsWriter, "stream"), buffer: []u8) DepsWriter {
        return .{ .deps = deps, .stream = stream, .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn emit(self: *DepsWriter, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len == 0) return;
        const written = switch (self.stream) {
            .stdout => writeStdout(self.deps, bytes),
            .stderr => writeStderr(self.deps, bytes),
        };
        written catch return error.WriteFailed;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *DepsWriter = @alignCast(@fieldParentPtr("interface", w));
        try self.emit(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try self.emit(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try self.emit(last);
        return n + last.len * splat;
    }
};

const McpCliAuthorization = struct {
    opener: host.UrlOpener,
    deps: RunDeps,
};

fn openTopLevelMcpUrl(
    raw: ?*anyopaque,
    alloc: Allocator,
    url: []const u8,
) anyerror!bool {
    const presentation: *const McpCliAuthorization = @ptrCast(@alignCast(raw.?));
    var encoded_url = try text_utils.encodeTerminalSafe(alloc, url, std.math.maxInt(usize));
    defer encoded_url.deinit(alloc);
    try writeStdout(presentation.deps, "Open this URL to authenticate the MCP server:\n");
    try writeStdout(presentation.deps, encoded_url.bytes);
    try writeStdout(presentation.deps, "\n\nWaiting for browser authorization...\n");
    if (io_mod.getenv("SPARK_NO_OPEN_BROWSER") == null) {
        _ = try presentation.opener.open(alloc, url);
    }
    return true;
}

fn writeMcpProfileWarningIfPresent(
    alloc: Allocator,
    cfg: Config,
    deps: RunDeps,
) !void {
    const diagnostic = try cfg.inspect_mcp_profile_config(alloc);
    const warning = switch (diagnostic) {
        .warning => |value| value,
        .clear, .failed => return,
    };
    try writeMcpProfileWarning(alloc, deps, warning);
}

fn writeMcpProfileWarning(
    alloc: Allocator,
    deps: RunDeps,
    warning: mcp_contract.ProfileConfigWarning,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print(
        "spark: {s}/mcp.json warning: {s}",
        .{ profile_paths.displayRoot(), @tagName(warning.cause) },
    );
    if (warning.key()) |key| {
        var encoded = try text_utils.encodeTerminalSafe(alloc, key, 128);
        defer encoded.deinit(alloc);
        try out.writer.print(" key={s}", .{encoded.bytes});
    }
    try out.writer.print(
        " additional_matches={d}\n",
        .{warning.additional_matches},
    );
    try writeStderr(deps, out.written());
}

fn writeUsageOrJsonError(
    alloc: Allocator,
    command_catalog: CommandCatalog,
    deps: RunDeps,
    usage_kind: TopLevelKind,
    output_kind: []const u8,
    err: anyerror,
    args: anytype,
) !void {
    if (argsContainJson(args)) {
        if (try flagProblem(alloc, usage_kind, args)) |problem| {
            defer alloc.free(problem);
            return writeJsonCommandFailure(alloc, deps, output_kind, err, problem);
        }
        try writeCommandFailure(alloc, deps, output_kind, err, .json);
    } else {
        try writeFlagFailure(alloc, deps, usage_kind, args);
        try writeTopLevelUsage(command_catalog, deps, usage_kind);
    }
}

/// The options a command's parser reads through `cli_flags`, so a usage
/// error can say which flag was wrong. Commands with their own parser are
/// absent.
fn parsedOptions(kind: TopLevelKind) ?[]const command_specs.OptionDoc {
    return switch (kind) {
        .status, .models => &builtin_commands.json_only_options,
        .doctor => &builtin_commands.doctor_options,
        .slack => &command_specs.slack_options,
        .sessions => &builtin_commands.sessions_options,
        .upgrade => &builtin_commands.upgrade_options,
        .uninstall => &builtin_commands.uninstall_options,
        .workspace => &builtin_commands.workspace_options,
        .config => &builtin_commands.config_parse_options,
        .session => &builtin_commands.session_options,
        .acp => &builtin_commands.acp_options,
        .pr, .issue => &builtin_commands.pr_options,
        else => null,
    };
}

/// Writes `spark <command>: <problem>` when `flagProblem` finds one.
fn writeFlagFailure(alloc: Allocator, deps: RunDeps, kind: TopLevelKind, args: anytype) !void {
    const problem = try flagProblem(alloc, kind, args) orelse return;
    defer alloc.free(problem);
    try writeStderrLine(alloc, deps, "spark {s}: ", @tagName(kind));
    try writeStderr(deps, problem);
    try writeStderr(deps, "\n");
}

/// What is wrong with the flags in `args`: a malformed flag, or a value
/// outside the range its placeholder names, such as `--limit <1-100>`.
/// Null when the flags are fine. The caller frees the result.
fn flagProblem(alloc: Allocator, kind: TopLevelKind, args: anytype) !?[]u8 {
    const docs = parsedOptions(kind) orelse return null;
    // `spark session` and `spark config` read operands that may start with a dash,
    // such as an ID or `-5`; report what their parsers hit.
    const parser: cli_flags.Parser = switch (kind) {
        .session, .config => .initDashOperands(docs, args),
        else => .init(docs, args),
    };
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    if (cli_flags.failureOf(parser)) |failure| {
        try failure.write(&writer.writer);
        switch (kind) {
            .acp, .pr, .issue => try flag_placement.writeLaunchFlagHint(&writer.writer, @tagName(kind), failure),
            else => {},
        }
    } else if (!try cli_flags.writeRangeFailure(&writer.writer, parser)) {
        return null;
    }
    return try writer.toOwnedSlice();
}

fn writeWorkspaceCommandError(
    alloc: Allocator,
    command_catalog: CommandCatalog,
    deps: RunDeps,
    args: []const [:0]const u8,
    err: anyerror,
) !void {
    if (!argsContainJson(args)) {
        if (output_contracts.workspaceErrorMessage(err)) |message| {
            try writeStderr(deps, "spark workspace: ");
            try writeStderr(deps, message);
            try writeStderr(deps, "\n");
            return;
        }
        try writeFlagFailure(alloc, deps, .workspace, args);
        try writeTopLevelUsage(command_catalog, deps, .workspace);
        return;
    }

    const message = output_contracts.workspaceErrorMessage(err) orelse "invalid arguments";
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"kind\":\"workspace\",\"error\":");
    try std.json.Stringify.value(message, .{}, &out.writer);
    try out.writer.writeAll(",\"code\":");
    try std.json.Stringify.value(@errorName(err), .{}, &out.writer);
    try out.writer.writeByte('}');
    try writeJsonLine(deps, out.writer.buffered());
}

fn writeWorkspaceIndeterminateError(
    alloc: Allocator,
    deps: RunDeps,
    args: []const [:0]const u8,
    reconciliation: workspace_commands.Reconciliation,
) !void {
    const message = switch (reconciliation) {
        .intended => "settings durability is uncertain; reloaded settings match the requested update",
        .previous => "settings durability is uncertain; reloaded settings match the previous state, so the update was not applied",
        .unconfirmed => "settings durability is uncertain; reloaded settings match neither the requested nor previous state",
    };
    if (!argsContainJson(args)) {
        try writeStderr(deps, "spark workspace: ");
        try writeStderr(deps, message);
        try writeStderr(deps, "\n");
        return;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"kind\":\"workspace\",\"error\":");
    try std.json.Stringify.value(message, .{}, &out.writer);
    try out.writer.writeAll(",\"code\":\"SettingsCommitIndeterminate\"}");
    try writeJsonLine(deps, out.writer.buffered());
}

fn argsContainJson(args: anytype) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}

fn workflowLanguagePlaceholder() types.ConversationLanguage {
    return types.ConversationLanguage.default();
}

/// The session modes `spark status` reports, so a client can show the mode
/// choice before an ACP session exists. Null for a registry without modes.
fn statusModes(registry: mode_registry.Registry, permission_mode: types.PermissionMode) ?output_contracts.StatusSnapshot.SessionModes {
    if (registry.modes.len == 0) return null;
    return .{ .current = registry.startingModeId(permission_mode), .all = registry.modes };
}

fn permissionModeForSnapshot(mode: anytype) types.PermissionMode {
    _ = mode;
    return .yolo;
}

fn permissionModeLabel(mode: anytype) []const u8 {
    _ = mode;
    return "yolo";
}

/// What `spark models` says when it could not load the catalog. A connection spark
/// could not make is named as one. The caller owns the text.
fn modelListFailureMessage(alloc: Allocator, failure: model_catalog.Failure, provider: model_provider.ProviderId) Allocator.Error![]u8 {
    if (failure.category == .transport) {
        return alloc.print(
            "could not list models: couldn't connect to {s}; check your network connection or firewall",
            .{model_catalog.serviceName(provider)},
        );
    }
    return alloc.print("could not list models: {s}", .{catalogFailureDetail(failure)});
}

fn writeCommandFailure(
    alloc: Allocator,
    deps: RunDeps,
    kind: []const u8,
    err: anyerror,
    format: output_contracts.OutputFormat,
) !void {
    if (format != .json) return err;
    const message = commandFailureMessage(err) orelse return err;
    return writeJsonCommandFailure(alloc, deps, kind, err, message);
}

fn writeJsonCommandFailure(
    alloc: Allocator,
    deps: RunDeps,
    kind: []const u8,
    err: anyerror,
    message: []const u8,
) !void {
    return writeJsonCommandFailureCode(
        alloc,
        deps,
        kind,
        @errorName(err),
        message,
    );
}

fn writeJsonCommandFailureCode(
    alloc: Allocator,
    deps: RunDeps,
    kind: []const u8,
    code: []const u8,
    message: []const u8,
) !void {
    const json = try (output_contracts.CommandFailureSnapshot{
        .kind = kind,
        .message = message,
        .code = code,
    }).renderJson(alloc);
    defer alloc.free(json);
    try writeJsonLine(deps, json);
}

/// How `spark sessions` prints for a person: in color and fitted to the window
/// when it writes to a terminal that takes color, with ages counted from
/// now. A pipe, `NO_COLOR`, or `TERM=dumb` gets plain text with whole titles,
/// and output a test captures is plain, so it reads the same everywhere.
fn sessionListStyle(deps: RunDeps) output_contracts.ListStyle {
    const styled = deps.write_stdout == &writeRealStdout and
        terminal_env.stdoutIsTerminal() and
        !terminal_env.colorDisabled();
    return .{
        .color = styled,
        .columns = if (styled) terminal_env.stdoutColumns() else null,
        .now_ms = io_mod.milliTimestamp(),
        .home = io_mod.homeDir(),
    };
}

fn writeSessionList(
    alloc: Allocator,
    deps: RunDeps,
    page: session_store.SessionListPage,
    opts: SessionListOptions,
) !RunResult {
    const next_cursor = if (page.has_more and page.summaries.items.len > 0)
        try formatSessionListCursor(
            alloc,
            page.summaries.items[page.summaries.items.len - 1],
        )
    else
        null;
    defer if (next_cursor) |cursor| alloc.free(cursor);

    const text = try (output_contracts.SessionListSnapshot{
        .sessions = page.summaries.items,
        .has_more = page.has_more,
        .next_cursor = next_cursor,
        .skipped_invalid = page.skipped_invalid,
        .all_workspaces = opts.scope == .all_workspaces,
        .style = sessionListStyle(deps),
    }).render(alloc, opts.format);
    defer alloc.free(text);
    try writeFormattedOutput(deps, text, opts.format);
    return .handled_success;
}

fn writeSessionSummary(
    alloc: Allocator,
    deps: RunDeps,
    summary: session_store.SessionSummary,
    format: output_contracts.OutputFormat,
) !RunResult {
    const text = try (output_contracts.SessionSummarySnapshot{ .summary = summary }).render(alloc, format);
    defer alloc.free(text);
    try writeFormattedOutput(deps, text, format);
    return .handled_success;
}

fn writeSessionDetail(
    alloc: Allocator,
    deps: RunDeps,
    state: session_codec.DurableSessionState,
    format: output_contracts.OutputFormat,
    tail: ?usize,
    address: ?[]const u8,
) !RunResult {
    const text = try (output_contracts.SessionDetailSnapshot{ .state = state, .tail = tail, .address = address }).render(alloc, format);
    defer alloc.free(text);
    try writeFormattedOutput(deps, text, format);
    return .handled_success;
}

fn writeSessionRecovery(
    alloc: Allocator,
    deps: RunDeps,
    result: session_store.SessionRecoveryResult,
    format: output_contracts.OutputFormat,
) !RunResult {
    const text = try (output_contracts.SessionRecoverySnapshot{ .result = result }).render(alloc, format);
    defer alloc.free(text);
    try writeFormattedOutput(deps, text, format);
    return if (result.status == .recovered) .handled_success else .handled_failure;
}

/// `spark sessions` on v2: the page v1 shows, from the v2 catalog.
fn runSessionList(alloc: Allocator, deps: RunDeps, opts: SessionListOptions) !RunResult {
    var store = session_adapter.Store.openFromEnv(alloc) catch |err| {
        try writeLookupFailure(alloc, deps, "sessions", session_adapter.commandError(err), opts.format);
        return .handled_failure;
    };
    defer store.deinit(alloc);
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace_root);
    const scope: ?[]const u8 = switch (opts.scope) {
        .current_workspace => workspace_root,
        .all_workspaces => null,
    };
    var page = session_adapter.listPage(&store, alloc, scope, opts.continuation, opts.limit) catch |err| {
        try writeLookupFailure(alloc, deps, "sessions", session_adapter.commandError(err), opts.format);
        return .handled_failure;
    };
    defer page.deinit(alloc);
    return writeSessionList(alloc, deps, page, opts);
}

/// `spark sessions --live`: the sessions an spark process has open now, with
/// their subagents (`session_adapter.listLive`). Reads every session in the
/// scope and writes none.
fn runLiveSessionList(alloc: Allocator, deps: RunDeps, opts: SessionListOptions) !RunResult {
    var store = session_adapter.Store.openFromEnv(alloc) catch |err| {
        try writeLookupFailure(alloc, deps, "sessions", session_adapter.commandError(err), opts.format);
        return .handled_failure;
    };
    defer store.deinit(alloc);
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace_root);
    const scope: ?[]const u8 = switch (opts.scope) {
        .current_workspace => workspace_root,
        .all_workspaces => null,
    };
    var list = session_adapter.listLive(&store, alloc, scope) catch |err| {
        try writeLookupFailure(alloc, deps, "sessions", session_adapter.commandError(err), opts.format);
        return .handled_failure;
    };
    defer list.deinit();
    const text = try (output_contracts.LiveSessionListSnapshot{
        .sessions = list.sessions,
        .all_workspaces = opts.scope == .all_workspaces,
        .style = sessionListStyle(deps),
    }).render(alloc, opts.format);
    defer alloc.free(text);
    try writeFormattedOutput(deps, text, opts.format);
    return .handled_success;
}

/// `--live` with `--limit` or `--cursor`: it lists every live session at
/// once, so it has no pages.
fn writeLivePagingError(
    alloc: Allocator,
    command_catalog: CommandCatalog,
    deps: RunDeps,
    flag: []const u8,
    format: output_contracts.OutputFormat,
) !void {
    const message = try alloc.print("--live lists every live session, so it takes no {s}", .{flag});
    defer alloc.free(message);
    if (format == .json) return writeJsonCommandFailure(alloc, deps, "sessions", error.InvalidLocalSurfaceArgs, message);
    try writeStderrLine(alloc, deps, "spark sessions: {s}\n", message);
    try writeTopLevelUsage(command_catalog, deps, .sessions);
}

const SessionConvertFlag = enum { json };
const session_convert_flag_ids = cli_flags.idTable(SessionConvertFlag, &builtin_commands.sessions_convert_options);

fn parseSessionConvertArgs(args: []const [:0]const u8) !output_contracts.OutputFormat {
    var format: output_contracts.OutputFormat = .text;
    var parser: cli_flags.Parser = .init(&builtin_commands.sessions_convert_options, args);
    while (parser.next() catch return error.InvalidLocalSurfaceArgs) |item| switch (item) {
        .positional => return error.InvalidLocalSurfaceArgs,
        .option => |match| switch (session_convert_flag_ids[match.index].?) {
            .json => format = .json,
        },
    };
    return format;
}

/// `spark sessions convert`: converts every v1 session v2 does not hold yet,
/// and fails when it skipped any (D61).
fn runSessionConvert(alloc: Allocator, deps: RunDeps, format: output_contracts.OutputFormat) !RunResult {
    // Each conversion is traced (`[convert]`), as an open's is.
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace_root);
    debug_trace.configureFromEnv(alloc, workspace_root);
    var store = session_adapter.Store.openFromEnv(alloc) catch |err| {
        try writeLookupFailure(alloc, deps, "sessions", session_adapter.commandError(err), format);
        return .handled_failure;
    };
    defer store.deinit(alloc);
    var report = session_adapter.convertAll(&store, alloc) catch |err| {
        try writeLookupFailure(alloc, deps, "sessions", session_adapter.commandError(err), format);
        return .handled_failure;
    };
    defer report.deinit(alloc);
    const skipped = try alloc.alloc(output_contracts.SessionConvertSnapshot.Skipped, report.skipped.items.len);
    defer alloc.free(skipped);
    for (report.skipped.items, skipped) |from, *to| to.* = .{ .id = from.id, .code = from.code, .reason = from.reason };
    const left_out = try alloc.alloc(output_contracts.SessionConvertSnapshot.LeftOut, report.left_out.items.len);
    defer alloc.free(left_out);
    var reasons = std.heap.ArenaAllocator.init(alloc);
    defer reasons.deinit();
    for (report.left_out.items, left_out) |from, *to| to.* = .{
        .id = from.id,
        .member = from.file.member,
        .file = from.file.file,
        .cause = @tagName(from.file.cause),
        .reason = try from.file.reason(reasons.allocator()),
        .bytes = from.file.bytes,
        .limit = session_adapter.ConvertReport.file_limit_bytes,
    };
    const kept = try alloc.alloc(output_contracts.SessionConvertSnapshot.Kept, report.kept_children.len);
    defer alloc.free(kept);
    for (report.kept_children, kept) |from, *to| to.* = .{ .id = from.id, .reason = from.reason };
    const snapshot: output_contracts.SessionConvertSnapshot = .{
        .converted = report.converted,
        .busy = report.busy,
        .unreadable = report.unreadable,
        .skipped = skipped,
        .left_out = left_out,
        .kept = kept,
    };
    const text = try snapshot.render(alloc, format);
    defer alloc.free(text);
    try writeFormattedOutput(deps, text, format);
    return if (skipped.len == 0) .handled_success else .handled_failure;
}

/// `spark session last|{id}|{id}/{agent}` on v2, read without the session's
/// lock (D37). `last` alone is a summary; with `--tail` it is the newest
/// session's last turns.
fn runSessionDetail(
    alloc: Allocator,
    deps: RunDeps,
    target: SessionDetailTarget,
    format: output_contracts.OutputFormat,
    tail: ?usize,
) !RunResult {
    var store = session_adapter.Store.openFromEnv(alloc) catch |err| {
        try writeLookupFailure(alloc, deps, "session", session_adapter.commandError(err), format);
        return .handled_failure;
    };
    defer store.deinit(alloc);
    switch (target) {
        .last => {
            const workspace_root = try io_mod.realpathAlloc(alloc, ".");
            defer alloc.free(workspace_root);
            var page = session_adapter.listPage(&store, alloc, workspace_root, null, 1) catch |err| {
                try writeLookupFailure(alloc, deps, "session", session_adapter.commandError(err), format);
                return .handled_failure;
            };
            defer page.deinit(alloc);
            if (page.summaries.items.len == 0) {
                try writeLookupFailure(alloc, deps, "session", session_adapter.noLatestError(&store, alloc), format);
                return .handled_failure;
            }
            if (tail == null) return writeSessionSummary(alloc, deps, page.summaries.items[0], format);
            return writeRootDetail(alloc, deps, &store, page.summaries.items[0].id, format, tail);
        },
        .id => |id| {
            const parsed = session_adapter.parseSessionTarget(id) catch |err| {
                try writeLookupFailure(alloc, deps, "session", err, format);
                return .handled_failure;
            };
            switch (parsed) {
                .session => return writeRootDetail(alloc, deps, &store, id, format, tail),
                .agent => |address| return writeAgentDetail(alloc, deps, &store, id, address, format, tail),
                .invalid => |problem| {
                    try writeAgentAddressInvalid(alloc, deps, id, problem, format);
                    return .handled_failure;
                },
            }
        },
    }
}

fn writeRootDetail(
    alloc: Allocator,
    deps: RunDeps,
    store: *session_adapter.Store,
    id: []const u8,
    format: output_contracts.OutputFormat,
    tail: ?usize,
) !RunResult {
    var resumed = session_adapter.readSession(store, alloc, id) catch |err| {
        try writeSessionDetailFailure(alloc, deps, id, session_adapter.commandError(err), store.problem.text(), format);
        return .handled_failure;
    };
    defer resumed.deinit(alloc);
    return writeSessionDetail(alloc, deps, resumed.state, format, tail, null);
}

/// `spark session {id}/{agent}`: a subagent by the names its parents gave it.
fn writeAgentDetail(
    alloc: Allocator,
    deps: RunDeps,
    store: *session_adapter.Store,
    target: []const u8,
    address: session_adapter.AgentAddress,
    format: output_contracts.OutputFormat,
    tail: ?usize,
) !RunResult {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const lookup = session_adapter.resolveAgent(store, arena.allocator(), address) catch |err| {
        try writeSessionDetailFailure(alloc, deps, target, session_adapter.commandError(err), store.problem.text(), format);
        return .handled_failure;
    };
    const child_id = switch (lookup) {
        .found => |id| id,
        .missing => |missing| {
            try writeAgentMissing(alloc, deps, missing.parent, missing.name, missing.names, format);
            return .handled_failure;
        },
    };
    var resumed = session_adapter.readChild(store, alloc, child_id) catch |err| {
        try writeSessionDetailFailure(alloc, deps, target, session_adapter.commandError(err), store.problem.text(), format);
        return .handled_failure;
    };
    defer resumed.deinit(alloc);
    return writeSessionDetail(alloc, deps, resumed.state, format, tail, target);
}

/// `text` is an agent address no subagent can have: says which part is at
/// fault and why.
fn writeAgentAddressInvalid(
    alloc: Allocator,
    deps: RunDeps,
    text: []const u8,
    problem: session_adapter.AddressProblem,
    format: output_contracts.OutputFormat,
) !void {
    var message: std.Io.Writer.Allocating = .init(alloc);
    defer message.deinit();
    try problem.describe(&message.writer, text);
    if (format == .json) return writeJsonCommandFailureCode(alloc, deps, "session", "InvalidAgentAddress", message.written());
    try writeStderrLine(alloc, deps, "spark session: {s}\n", message.written());
}

/// No subagent of `parent` goes by `name`: says so, with the names its
/// subagents do go by.
fn writeAgentMissing(
    alloc: Allocator,
    deps: RunDeps,
    parent: []const u8,
    name: []const u8,
    names: []const []const u8,
    format: output_contracts.OutputFormat,
) !void {
    var message: std.Io.Writer.Allocating = .init(alloc);
    defer message.deinit();
    try message.writer.print("session {s} has no agent named {s}; ", .{ parent, name });
    if (names.len == 0) {
        try message.writer.writeAll("it has no agents");
    } else {
        try message.writer.writeAll("its agents: ");
        for (names, 0..) |known, i| {
            if (i > 0) try message.writer.writeAll(", ");
            try message.writer.writeAll(known);
        }
    }
    if (format == .json) return writeJsonCommandFailureCode(alloc, deps, "session", "AgentNotFound", message.written());
    try writeStderrLine(alloc, deps, "spark session: {s}\n", message.written());
}

/// `spark session recover` on v2 (D15): a copy up to the last good turn.
fn runSessionRecovery(alloc: Allocator, deps: RunDeps, recovery: SessionRecoveryOptions) !RunResult {
    var store = session_adapter.Store.openFromEnv(alloc) catch |err| {
        try writeLookupFailure(alloc, deps, "session", session_adapter.commandError(err), recovery.format);
        return .handled_failure;
    };
    defer store.deinit(alloc);
    var recovered = session_adapter.recover(&store, alloc, recovery.session_id) catch |err| {
        const failure = session_adapter.commandError(err);
        // A v1 folder others can write: the reason names it and its fix (D61).
        if (failure == error.DurablePathUnsafe and store.problem.len > 0) {
            const message = try alloc.print("session {s} can't be recovered safely: {s}", .{ recovery.session_id, store.problem.text() });
            defer alloc.free(message);
            if (recovery.format == .json) {
                try writeJsonCommandFailure(alloc, deps, "session", failure, message);
            } else try writeStderrLine(alloc, deps, "spark session: {s}\n", message);
            return .handled_failure;
        }
        try writeLookupFailure(alloc, deps, "session", failure, recovery.format);
        return .handled_failure;
    };
    defer recovered.deinit(alloc);
    const source_id = try alloc.dupe(u8, recovery.session_id);
    const recovered_id = alloc.dupe(u8, recovered.id) catch |err| {
        alloc.free(source_id);
        return err;
    };
    var result: session_store.SessionRecoveryResult = .{
        .source_session_id = source_id,
        .recovered_session_id = recovered_id,
        .history_len = recovered.history_len,
        .status = if (recovered.files_complete) .recovered else .recovered_with_unverified_artifacts,
        .permission_rules_dropped = recovered.permission_rules_dropped,
    };
    defer result.deinit(alloc);
    return writeSessionRecovery(alloc, deps, result, recovery.format);
}

fn writeLookupFailure(
    alloc: Allocator,
    deps: RunDeps,
    kind: []const u8,
    err: anyerror,
    format: output_contracts.OutputFormat,
) !void {
    if (format == .json) {
        return writeCommandFailure(alloc, deps, kind, err, format);
    }

    switch (err) {
        error.NoSavedSessions => {
            try writeStderr(deps, "spark session: no saved sessions for this workspace\n");
        },
        error.NoReadableSessions => {
            try writeStderr(deps, "spark session: saved sessions are unreadable; run `spark doctor` for recovery guidance\n");
        },
        error.SessionNotFound => {
            try writeStderr(deps, "spark session: record not found\n");
        },
        error.InvalidSessionFormat => {
            try writeStderr(
                deps,
                "spark session: record is corrupt; run `spark doctor` for recovery guidance\n",
            );
        },
        error.UnsupportedSessionSchema => {
            try writeStderr(
                deps,
                "spark session: record uses an unsupported session version\n",
            );
        },
        error.InvalidSessionId => {
            try writeStderr(deps, "spark session: invalid session id\n");
        },
        error.SessionRecoveryNotNeeded => {
            try writeStderr(
                deps,
                "spark session: recovery was refused because the session has a valid commit boundary; resume it normally\n",
            );
        },
        error.SessionRecoveryBoundaryInvalid => {
            try writeStderr(
                deps,
                "spark session: no exact trustworthy recovery boundary was found; the source was left unchanged\n",
            );
        },
        error.SessionBusy => {
            try writeStderr(
                deps,
                "spark session: session is busy or the filesystem cannot provide the required lock\n",
            );
        },
        error.DurablePathUnsafe => {
            try writeStderr(
                deps,
                "spark session: durable session storage is unsafe or does not support required private permissions\n",
            );
        },
        error.SessionStoreUnavailable => {
            try writeStderr(deps, "spark session: durable session store is unavailable\n");
        },
        error.HomeNotSet => {
            try writeStderr(deps, "spark ");
            try writeStderr(deps, kind);
            try writeStderr(deps, ": " ++ io_mod.no_home_dir_reason ++ "\n");
        },
        else => return err,
    }
}

/// `reason` names the file and the problem of a v1 session v1's reader
/// refuses (D78), and is empty otherwise.
fn writeSessionDetailFailure(
    alloc: Allocator,
    deps: RunDeps,
    session_id: []const u8,
    err: anyerror,
    reason: []const u8,
    format: output_contracts.OutputFormat,
) !void {
    const message = switch (err) {
        error.InvalidSessionFormat => if (reason.len > 0) try alloc.print(
            "session {s} can't be read: {s}; run `spark doctor`",
            .{ session_id, reason },
        ) else try alloc.print(
            "session {s} is corrupt; run `spark session recover {s}`",
            .{ session_id, session_id },
        ),
        error.UnsupportedSessionSchema => try alloc.print(
            "session {s} uses an unsupported session version",
            .{session_id},
        ),
        // A v1 folder others can write: the reason names it and its fix (D61).
        error.DurablePathUnsafe => if (reason.len > 0) try alloc.print(
            "session {s} can't be read safely: {s}",
            .{ session_id, reason },
        ) else return writeLookupFailure(alloc, deps, "session", err, format),
        else => return writeLookupFailure(
            alloc,
            deps,
            "session",
            err,
            format,
        ),
    };
    defer alloc.free(message);
    if (format == .json) {
        return writeJsonCommandFailure(
            alloc,
            deps,
            "session",
            err,
            message,
        );
    }
    try writeStderr(deps, "spark session: ");
    try writeStderr(deps, message);
    try writeStderr(deps, "\n");
}

fn commandFailureMessage(err: anyerror) ?[]const u8 {
    if (lookupFailureMessage(err)) |message| return message;
    return switch (err) {
        error.InvalidLocalSurfaceArgs,
        error.InvalidUsageArgs,
        error.InvalidSessionDetailArgs,
        error.InvalidSessionMigrationArgs,
        error.InvalidSessionRecoveryArgs,
        error.InvalidResumeArgs,
        error.InvalidUpgradeArgs,
        error.InvalidConfigArgs,
        error.InvalidSlackArguments,
        => "invalid arguments",
        error.UnknownConfigSetting => "unknown setting",
        error.WorkspaceConfigWrite => workspace_write_message,
        else => null,
    };
}

fn lookupFailureMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NoSavedSessions => "no saved sessions for this workspace",
        error.NoReadableSessions => "saved sessions are unreadable; run `spark doctor` for recovery guidance",
        error.SessionNotFound => "record not found",
        error.InvalidSessionFormat => "record is corrupt; run `spark doctor` for recovery guidance",
        error.UnsupportedSessionSchema => "record uses an unsupported session version",
        error.InvalidSessionId => "invalid session id",
        error.SessionRecoveryNotNeeded => "recovery was refused because the session has a valid commit boundary; resume it normally",
        error.SessionRecoveryBoundaryInvalid => "no exact trustworthy recovery boundary was found; the source was left unchanged",
        error.SessionBusy => "session is busy or the filesystem cannot provide the required lock",
        error.SessionPathUnsafe,
        error.DurablePathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => "durable session storage is unsafe or does not support required private permissions",
        error.SessionStoreUnavailable => "durable session store is unavailable",
        error.HomeNotSet => io_mod.no_home_dir_reason,
        else => null,
    };
}

fn workflowConfigWithLaunchModifiers(
    cfg: Config,
    modifiers: LaunchModifiers,
) @import("cli_ask.zig").Config {
    var result = workflowConfig(cfg);
    result.context_limit_overrides = modifiers.context_limit_overrides;
    result.tool_placement_overrides = modifiers.tool_placement_overrides;
    result.additional_directories = modifiers.additional_directories;
    result.saved_directories_suppressed = modifiers.saved_directories_suppressed;
    return result;
}

fn commandSupportsWorkspaceModifiers(command: Command) bool {
    return switch (command) {
        .interactive, .ask, .acp, .pr, .issue, .resume_session => true,
        else => false,
    };
}

fn writeWorkspaceModifierUsage(deps: RunDeps) !void {
    try writeStderr(
        deps,
        "spark: --add-dir and --no-additional-dirs are only supported for interactive, resume, ask, ACP, PR, and issue launches\n",
    );
}

/// For an agent-run flag before a command, says where it goes, as in
/// `spark: put agent-run flags after the command, as in spark ask --model <id>`.
fn writeModelModifierUsage(alloc: Allocator, deps: RunDeps, command: Command, modifiers: LaunchModifiers) !void {
    const example = firstAgentRunFlag(modifiers);
    const target: ?[]const u8 = switch (command) {
        .ask => "ask",
        .pr => "pr",
        .issue => "issue",
        .acp => "acp",
        else => null,
    };
    const message = if (target) |name|
        try alloc.print("spark: put agent-run flags after the command, as in spark {s} {s}\n", .{ name, example })
    else
        try alloc.print("spark: agent-run flags such as {s} apply to a session and to spark ask, spark pr, spark issue, and spark acp\n", .{example[0 .. std.mem.findScalar(u8, example, ' ') orelse example.len]});
    defer alloc.free(message);
    try writeStderr(deps, message);
}

/// The documented spelling of the first agent-run flag set before a command.
fn firstAgentRunFlag(modifiers: LaunchModifiers) []const u8 {
    if (modifiers.permission_override != null) return "--permission-mode <mode>";
    if (modifiers.provider_override != null) return "--provider <name>";
    if (modifiers.model_override != null) return "--model <id>";
    if (modifiers.effort_override != null) return "--effort <level>";
    if (modifiers.fast_override) |fast| return if (fast) "--fast" else "--no-fast";
    if (modifiers.ultrafast_override) |ultrafast| return if (ultrafast) "--ultrafast" else "--no-ultrafast";
    return "--model <id>";
}

fn globalLaunchErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.MissingAddDirectoryValue => "--add-dir requires a directory path",
        error.MissingModelValue => "--model requires a model id",
        error.MissingProfileValue => "--profile requires a profile name",
        error.InvalidProfileName => "--profile names use lowercase letters, digits, '-', or '_'",
        error.InvalidInstancesValue => "--instances takes a whole number of at least 1",
        error.InvalidEffortValue => "--effort value is not a valid reasoning effort",
        error.InvalidProviderValue => "--provider accepts a configured provider name",
        error.InvalidPermissionModeValue => "--permission-mode accepts full-access",
        error.InvalidToolPlacementOverride => "--tool-placement takes <tool>=toolbox or <tool>=direct",
        error.UnknownToolPlacementTool => "--tool-placement names a built-in tool that can move: " ++ config_runtime.tool_placement.movable_list,
        error.InvalidToolPlacementValue => "--tool-placement puts a tool in toolbox or direct",
        else => null,
    };
}

const AcpFlag = enum { permission_mode, full_access, yolo, provider, model, effort, fast, no_fast, ultrafast, no_ultrafast, log_file };
const acp_flag_ids = cli_flags.idTable(AcpFlag, &builtin_commands.acp_options);

fn parseAcpArgs(alloc: Allocator, args: []const [:0]const u8, bad: *?BadAgentValue) !AcpOptions {
    var opts = AcpOptions{};
    errdefer opts.deinit(alloc);
    var parser: cli_flags.Parser = .init(&builtin_commands.acp_options, args);
    while (parser.next() catch return error.InvalidAcpArgs) |item| switch (item) {
        .positional => return error.InvalidAcpArgs,
        .option => |match| {
            const id = acp_flag_ids[match.index].?;
            if (agent_run_flags.fromId(id)) |flag| {
                try applyAgentFlag(alloc, &opts.agent, flag, &builtin_commands.acp_options, match, bad);
                continue;
            }
            switch (id) {
                .log_file => opts.log_file = match.value.?,
                else => unreachable,
            }
        },
    };
    return opts;
}

/// Prints the settings `spark config list` or `spark config get` asks for. `get` of a
/// key that isn't set prints nothing and fails, as `git config get` does.
fn runConfigSchema(alloc: Allocator, deps: RunDeps, opts: cli_config.Options) !RunResult {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try settings_schema.write(&out.writer, if (opts.project) .project else .profile);
    try writeStdout(deps, out.written());
    return .handled_success;
}

fn runConfig(alloc: Allocator, cfg: Config, deps: RunDeps, opts: cli_config.Options) !RunResult {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace_root);
    var paths = try config_runtime.discoverPaths(alloc, workspace_root);
    defer paths.deinit(alloc);

    var failed_file: ?[]const u8 = null;
    var loaded = cli_config.load(alloc, paths, workspace_root, opts.scope, &failed_file) catch |err| {
        const file = failed_file orelse return err;
        const message = try alloc.print("{s} {s}", .{ file, cli_config.loadFailureReason(err) });
        defer alloc.free(message);
        if (opts.format == .json) {
            try writeJsonCommandFailure(alloc, deps, "config", err, message);
        } else {
            try writeStderrLine(alloc, deps, "spark config: {s}\n", message);
        }
        return .handled_failure;
    };
    defer loaded.deinit(alloc);

    // list shows what each file sets, as git config --list does. get without a
    // scope reports the value a run uses, defaults included, so it reads the
    // settings the runtime resolves.
    var resolved_arena: std.heap.ArenaAllocator = .init(alloc);
    defer resolved_arena.deinit();
    const shown: []const settings_entries.Entry = if (opts.scope == .all and opts.key != null)
        resolvedConfigEntries(alloc, resolved_arena.allocator(), cfg, deps, opts.format, workspace_root, loaded.entries.items) catch |err| blk: {
            debug_trace.logf("config", "resolving settings failed err={s}; showing file values", .{@errorName(err)});
            break :blk loaded.entries.items;
        }
    else
        loaded.entries.items;

    const matches: ?[]settings_entries.Entry = if (opts.key) |key|
        try settings_entries.lookup(alloc, shown, key)
    else
        null;
    defer if (matches) |found| alloc.free(found);
    const entries = matches orelse shown;
    const snapshot: output_contracts.ConfigSnapshot = .{
        .entries = entries,
        .unknown = if (opts.key == null) loaded.unknown else &.{},
        .workspace_root = workspace_root,
        .show_origin = opts.show_origin,
        .value_only = opts.key != null and entries.len == 1 and std.mem.eql(u8, entries[0].key, opts.key.?),
    };
    if (opts.format == .text) {
        for (snapshot.unknown) |unknown| {
            const message = try settings_messages.formatUnknownSetting(alloc, unknown.key, unknown.file);
            defer alloc.free(message);
            try writeStderrLine(alloc, deps, "spark config: {s}\n", message);
        }
    }

    // Like git config --get, a key with no value prints nothing and exits 1;
    // JSON names the key, so a script can tell why.
    if (opts.format == .json and opts.key != null and entries.len == 0) {
        const message = try alloc.print("{s} isn't set", .{opts.key.?});
        defer alloc.free(message);
        try writeJsonCommandFailureCode(alloc, deps, "config", "ConfigKeyNotSet", message);
        return .handled_failure;
    }
    const text = try snapshot.render(alloc, opts.format);
    defer alloc.free(text);
    try writeFormattedOutput(deps, text, opts.format);
    return if (opts.key != null and entries.len == 0) .handled_failure else .handled_success;
}

/// The entries `spark config get` looks a key up in without a scope: each value
/// as a run resolves it, through the same `resolveSettings` the session uses.
fn resolvedConfigEntries(
    alloc: Allocator,
    arena: Allocator,
    cfg: Config,
    deps: RunDeps,
    format: output_contracts.OutputFormat,
    workspace_root: []const u8,
    set: []const settings_entries.Entry,
) ![]settings_entries.Entry {
    var detailed = try config_runtime.loadMergedSettingsDetailed(alloc, workspace_root);
    defer detailed.deinit(alloc);
    // The same warnings spark status prints, such as a profile spark rejects, which
    // explain a value shown as the default.
    if (format == .text) try writeConfigDiagnostics(alloc, deps, detailed.diagnostics);
    var state = app_lifecycle.StartupState{ .agent_step_limit = cfg.default_agent_step_limit };
    defer state.deinit(alloc);
    state.model_source = detailed.model_source orelse .compiled_default;
    try app_lifecycle.resolveSettings(alloc, &state, &detailed);
    const selection = try config_runtime.selectProviderModel(cfg.default_model, &detailed.settings, null, config_runtime.modelEnvOverride());
    const entries = try cli_config.effectiveEntries(arena, &state, selection.provider, set);
    // Values borrow from `state`, which is freed on return.
    for (entries) |*entry| entry.value = try dupeJsonValue(arena, entry.value);
    return entries;
}

fn dupeJsonValue(arena: Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .string => |text| .{ .string = try arena.dupe(u8, text) },
        .number_string => |text| .{ .number_string = try arena.dupe(u8, text) },
        .array => |array| blk: {
            var copy: std.json.Array = .init(arena);
            for (array.items) |item| try copy.append(try dupeJsonValue(arena, item));
            break :blk .{ .array = copy };
        },
        else => value,
    };
}

const workspace_write_message = "preferences apply to every workspace, so set and unset don't take --workspace";

/// Saves what `spark config set` or `spark config unset` asks for to the profile's
/// top level and prints one line naming the key, the value, and the file.
fn runConfigWrite(alloc: Allocator, deps: RunDeps, opts: cli_config.Options) !RunResult {
    var problem: cli_config.WriteProblem = .none;
    const planned = cli_config.change(opts, &problem) catch |err| {
        const message = try cli_config.formatWriteProblem(alloc, opts.key.?, opts.value, problem, "spark config");
        defer alloc.free(message);
        if (opts.format == .json) {
            try writeJsonCommandFailure(alloc, deps, "config", err, message);
        } else {
            try writeStderrLine(alloc, deps, "spark config: {s}\n", message);
        }
        return usage_failure;
    };

    var outcome = config_runtime.setUserPreferences(alloc, planned.patch) catch |err| {
        const message = try alloc.print("failed to save {s}/settings.json: {s}", .{ profile_paths.displayRoot(), cli_config.saveFailureReason(err) });
        defer alloc.free(message);
        if (opts.format == .json) {
            try writeJsonCommandFailure(alloc, deps, "config", err, message);
        } else {
            try writeStderrLine(alloc, deps, "spark config: {s}\n", message);
        }
        return .handled_failure;
    };
    defer outcome.deinit(alloc);

    const snapshot: output_contracts.ConfigChangeSnapshot = .{
        .unset = opts.action == .unset,
        .key = opts.key.?,
        .value = planned.value,
        .changed = outcome == .committed,
    };
    const text = try snapshot.render(alloc, opts.format);
    defer alloc.free(text);
    try writeFormattedOutput(deps, text, opts.format);
    return .handled_success;
}

fn writeStderrLine(alloc: Allocator, deps: RunDeps, comptime format: []const u8, value: []const u8) !void {
    const line = try alloc.print(format, .{value});
    defer alloc.free(line);
    try writeStderr(deps, line);
}

fn modelsListArgs(rest: []const [:0]const u8) []const [:0]const u8 {
    if (rest.len > 0 and std.mem.eql(u8, rest[0], "ls")) return rest[1..];
    return rest;
}

fn parseLocalSurfaceArgs(args: []const [:0]const u8) !LocalSurfaceOptions {
    var options = LocalSurfaceOptions{};
    var parser: cli_flags.Parser = .init(&builtin_commands.json_only_options, args);
    while (parser.next() catch return error.InvalidLocalSurfaceArgs) |item| switch (item) {
        .positional => return error.InvalidLocalSurfaceArgs,
        .option => options.format = .json,
    };
    return options;
}

const DoctorOptions = struct {
    format: output_contracts.OutputFormat = .text,
    fix: bool = false,
    deep: bool = false,
};
const DoctorFlag = enum { json, fix, deep };
const doctor_flag_ids = cli_flags.idTable(DoctorFlag, &builtin_commands.doctor_options);

fn parseDoctorArgs(args: []const [:0]const u8) !DoctorOptions {
    var options = DoctorOptions{};
    var parser: cli_flags.Parser = .init(&builtin_commands.doctor_options, args);
    while (parser.next() catch return error.InvalidLocalSurfaceArgs) |item| switch (item) {
        .positional => return error.InvalidLocalSurfaceArgs,
        .option => |match| switch (doctor_flag_ids[match.index].?) {
            .json => options.format = .json,
            .fix => options.fix = true,
            .deep => options.deep = true,
        },
    };
    return options;
}

/// The network and process checks `spark doctor` started, until `wait` stops
/// and joins them. Probes are allocated with `std.heap.c_allocator` and left
/// to the process exit, which follows the report.
const DoctorProbes = struct {
    deadline: i64,
    /// The limit `deadline` ends, in milliseconds.
    limit_ms: i64,
    catalog: ?*doctor_probes.CatalogProbe = null,
    /// The MCP server checks first, then gh.
    processes: std.ArrayList(*doctor_probes.ProcessProbe) = .empty,
    server_children: usize = 0,
    /// The MCP server checks, which `wait` starts from as slots free.
    servers: doctor_probes.ServerChecks = .{},
    gh: ?*doctor_probes.ProcessProbe = null,
    waiters: std.Io.Group = .init,
    mcp_statuses: []const mcp_runtime.Status = &.{},
    mcp_checked: bool = false,

    /// Starts the provider, MCP server, and gh checks. Whatever it started
    /// before an error is still in `self`, for `wait` to stop.
    fn start(self: *DoctorProbes, cfg: Config, deps: RunDeps, snapshot: *const doctor_runtime.Snapshot, workspace_root: []const u8) !void {
        const probe_alloc = std.heap.c_allocator;
        // A configured provider's model list comes from its settings, with no
        // request, so asking it would confirm nothing.
        _ = deps;
        if (cfg.load_mcp_host) |load| {
            // A config doctor cannot load is already a check of its own.
            const doctor_host = load(probe_alloc, workspace_root, cfg.tool_set.registry, .{}) catch |err| blk: {
                debug_trace.logf("doctor", "MCP server checks skipped: host failed to load err={s}", .{@errorName(err)});
                break :blk null;
            };
            if (doctor_host) |loaded_host| {
                self.mcp_statuses = try loaded_host.runtime.statuses(probe_alloc);
                const exe_path = try self_exe.pathForReexec(probe_alloc);
                defer self.server_children = self.processes.items.len;
                self.servers = try doctor_probes.startServerChildren(probe_alloc, &self.waiters, &self.processes, self.mcp_statuses, exe_path, self.deadline, self.limit_ms, doctor_probes.serverCap());
                self.mcp_checked = true;
            }
        }
        // gh matters only to spark pr and spark issue, which need a repository; outside
        // one, doctor does not run it, so gh writes nothing on its behalf. Unit
        // tests run inside this repository and must not reach GitHub.
        if (snapshot.in_git_repository and !builtin.is_test) {
            self.gh = try doctor_probes.startGh(probe_alloc, &self.waiters, &self.processes);
        }
    }

    /// Starts the provider catalog request, when the provider has a catalog.
    fn startCatalog(self: *DoctorProbes, cfg: Config, deps: RunDeps, model: []const u8) !void {
        const probe_alloc = std.heap.c_allocator;
        const startup = try probe_alloc.create(app_lifecycle.StartupState);
        startup.* = (if (cfg.auth_mode == .host_managed)
            deps.load_catalog_startup_state_with_auth_mode(probe_alloc, cfg.secret_store, cfg.default_model, cfg.default_agent_step_limit, cfg.auth_mode, null, null)
        else
            deps.load_startup_state(probe_alloc, cfg.oauth_transport, cfg.secret_store, cfg.default_model, cfg.default_agent_step_limit)) catch |err| {
            // Startup itself refuses this setup, and the config check says why.
            debug_trace.logf("doctor", "provider check skipped: startup state failed err={s}", .{@errorName(err)});
            return;
        };
        var available = cfg.provider_set;
        available.definitions = startup.configured_providers.definitions;
        const catalog = available.select(startup.provider).cli_model_catalog orelse return;
        const probe = try probe_alloc.create(doctor_probes.CatalogProbe);
        probe.* = .{
            .provider = catalog,
            .access = startup.modelCatalogAccess(),
            .endpoint = cfg.models_path,
            .model = try probe_alloc.dupe(u8, model),
        };
        probe.start();
        self.catalog = probe;
    }

    /// Waits for the checks until the deadline, then stops and joins them.
    /// The ending signal that stopped the checks, if one did.
    fn wait(self: *DoctorProbes) ?std.posix.SIG {
        return doctor_probes.wait(self.deadline, self.catalog, self.processes.items, &self.waiters, &self.servers);
    }

    /// One line on a terminal's stderr while doctor waits on its network
    /// checks, so a slow one does not look like a hang.
    fn writeWaitNotice(self: *const DoctorProbes, alloc: Allocator, progress: *DoctorProgress, provider: model_provider.ProviderId, deadline_ms: i64) !void {
        if (!progress.enabled) return;
        var servers: usize = 0;
        for (self.processes.items[0..self.server_children]) |probe| {
            if (!probe.not_started and probe.spawn_error == null) servers += 1;
        }
        const gh_started = if (self.gh) |gh| gh.spawn_error == null else false;
        const notice = try doctor_probes.waitNotice(alloc, .{
            .provider = if (self.catalog != null) provider else null,
            .mcp_servers = servers,
            .gh = if (gh_started) .checking else .not_checked,
        }, deadline_ms) orelse return;
        defer alloc.free(notice);
        progress.line(notice);
    }

    /// The probe check lines, and what doctor found for each MCP server.
    fn checks(
        self: *const DoctorProbes,
        alloc: Allocator,
        provider: model_provider.ProviderId,
        deadline_ms: i64,
        out: *std.ArrayList(doctor_runtime.Check),
        results: *std.ArrayList(output_contracts.McpServerResult),
    ) !void {
        if (self.catalog) |probe| try doctor_probes.catalogChecks(out, alloc, probe, provider, deadline_ms);
        try doctor_probes.serverStatusChecks(out, alloc, self.mcp_statuses);
        try doctor_probes.serverChildChecks(out, results, alloc, self.processes.items[0..self.server_children], deadline_ms);
        try doctor_probes.ghCheck(out, alloc, self.gh, deadline_ms);
    }
};

/// Whether doctor's stderr is a terminal, for its wait notice.
fn stderrIsTerminal() bool {
    return std.Io.File.stderr().isTty(io_mod.getIo()) catch false;
}

/// The local checks with the probe checks after them. The provider's answer
/// replaces the local auth line, which only saw a credential; a credential
/// the provider was asked about and never answered for is not confirmed.
/// `unconfirmed` holds that line's detail, which the caller frees.
fn mergeDoctorChecks(
    alloc: Allocator,
    local: []const doctor_runtime.Check,
    probe_checks: []const doctor_runtime.Check,
    provider_asked: bool,
    out: *std.ArrayList(doctor_runtime.Check),
    unconfirmed: *?[]u8,
) !void {
    var verified_auth = false;
    for (probe_checks) |entry| verified_auth = verified_auth or std.mem.eql(u8, entry.name, "auth");
    for (local) |entry| {
        if (std.mem.eql(u8, entry.name, "auth") and entry.status == .ok) {
            if (verified_auth) continue;
            if (provider_asked) {
                unconfirmed.* = try alloc.print("{s}; the provider did not confirm it", .{entry.detail});
                try out.append(alloc, .{ .name = entry.name, .status = .warn, .detail = unconfirmed.*.?, .fix = "run spark doctor again once the provider check passes" });
                continue;
            }
        }
        try out.append(alloc, entry);
    }
    try out.appendSlice(alloc, probe_checks);
}

/// `spark doctor`: the local checks, then the provider, MCP, and gh checks
/// under one deadline (`doctor_probes.zig`). Exits 1 when a check fails.
fn runDoctor(alloc: Allocator, cfg: Config, deps: RunDeps, opts: DoctorOptions) !RunResult {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace_root);
    var progress: DoctorProgress = .{
        .deps = deps,
        .enabled = opts.format == .text and !builtin.is_test and stderrIsTerminal(),
        .erase = !terminal_env.dumbTerminal(),
    };
    if (progress.enabled) progress.columns = terminal_env.stderrColumns();
    // Never leaves a progress line above the report, or above an error.
    defer progress.clear();
    if (progress.erase) progress.line("checking spark setup...\n");
    var mcp_inspection = try cfg.inspect_mcp_local_config(alloc, workspace_root);
    defer mcp_inspection.deinit(alloc);
    var snapshot = try doctor_runtime.collect(
        alloc,
        cfg.secret_store,
        cfg.default_model,
        cfg.default_agent_step_limit,
        mcp_inspection.profile_diagnostic,
        mcp_inspection.snapshot.configuration_issues,
        .{
            .version = cfg.version,
            .channel = cfg.build_channel.label(),
            .skill_root_policy = cfg.skill_root_policy,
        },
    );
    defer snapshot.deinit(alloc);
    progress.clear();

    const deadline_ms = doctor_probes.deadlineMs();
    var probes: DoctorProbes = .{ .deadline = io_mod.milliTimestamp() + deadline_ms, .limit_ms = deadline_ms };
    const started = probes.start(cfg, deps, &snapshot, workspace_root);
    probes.writeWaitNotice(alloc, &progress, snapshot.provider, deadline_ms) catch |err| {
        debug_trace.logf("doctor", "wait notice not written err={s}", .{@errorName(err)});
    };

    var state_checks: std.ArrayList(doctor_runtime.Check) = .empty;
    defer {
        for (state_checks.items) |*entry| entry.deinit(alloc);
        state_checks.deinit(alloc);
    }
    var stop: DoctorSessionStop = .{ .deadline = if (opts.deep) null else probes.deadline, .probes = if (opts.deep) null else &probes };
    const state_options: doctor_runtime.StateOptions = .{
        .orphans = if (opts.fix) .remove else .count,
        .blobs = if (opts.deep) .hash else .exists,
        .stop = .{ .context = &stop, .requested = DoctorSessionStop.requested },
        .progress = .{ .context = &progress, .report = DoctorProgress.sessions },
        .limit_ms = if (opts.deep) null else deadline_ms,
    };
    // Plain doctor checks the sessions while the network checks run, within
    // their deadline. `--deep` has no limit, so it checks them after.
    const state_result: anyerror!void = if (opts.deep) {} else doctor_runtime.appendStateChecks(&state_checks, alloc, state_options);
    // Runs on every path, so nothing doctor started outlives it.
    if (probes.wait()) |sig| doctor_probes.endBySignal(sig);
    try started;
    try state_result;
    if (opts.deep) try doctor_runtime.appendStateChecks(&state_checks, alloc, state_options);
    progress.clear();

    var probe_checks: std.ArrayList(doctor_runtime.Check) = .empty;
    defer {
        for (probe_checks.items) |*entry| entry.deinit(alloc);
        probe_checks.deinit(alloc);
    }
    var server_results: std.ArrayList(output_contracts.McpServerResult) = .empty;
    defer server_results.deinit(alloc);
    try probes.checks(alloc, snapshot.provider, deadline_ms, &probe_checks, &server_results);

    var local: std.ArrayList(doctor_runtime.Check) = .empty;
    defer local.deinit(alloc);
    try local.appendSlice(alloc, snapshot.checks);
    try local.appendSlice(alloc, state_checks.items);
    var checks: std.ArrayList(doctor_runtime.Check) = .empty;
    defer checks.deinit(alloc);
    var unconfirmed: ?[]u8 = null;
    defer if (unconfirmed) |detail| alloc.free(detail);
    try mergeDoctorChecks(alloc, local.items, probe_checks.items, probes.catalog != null, &checks, &unconfirmed);

    var failed = false;
    for (checks.items) |entry| failed = failed or entry.status == .fail;
    var output_snapshot = doctorSnapshotFromRuntime(snapshot);
    output_snapshot.version = cfg.version;
    output_snapshot.checks = checks.items;
    var mcp_view = localMcpView(&mcp_inspection);
    if (probes.mcp_checked) {
        mcp_view.connection_check = .checked;
        mcp_view.results = server_results.items;
    }
    output_snapshot.mcp = mcp_view;
    try writeDoctorReport(alloc, deps, output_snapshot, opts.format);
    return if (failed) .handled_failure else .handled_success;
}

/// Stops doctor's session check at its deadline, or when an ending signal
/// reached doctor while its handler was in place. Each time it is asked, it
/// also starts the queued MCP server checks a free slot allows, as `wait`
/// does, so the session check costs them none of the limit.
const DoctorSessionStop = struct {
    deadline: ?i64,
    /// Null once `wait` has stopped the probes, as for `--deep`.
    probes: ?*DoctorProbes,

    fn requested(context: *anyopaque) bool {
        const self: *DoctorSessionStop = @ptrCast(@alignCast(context));
        if (self.probes) |probes| probes.servers.startMore(&probes.waiters, probes.deadline);
        if (doctor_probes.stopRequested()) return true;
        const deadline = self.deadline orelse return false;
        return io_mod.milliTimestamp() >= deadline;
    }
};

/// What doctor is doing, on a terminal's stderr while it works: whole lines,
/// then one line it rewrites in place. `clear` erases them all, so the
/// report starts on a clean screen. Each line is cut to fit one row, since
/// `clear` erases one row per line. Pipes and unit tests get none of it, and
/// a `TERM=dumb` terminal, which cannot move the cursor, gets only the whole
/// lines, which stay.
const DoctorProgress = struct {
    deps: RunDeps,
    enabled: bool,
    erase: bool,
    /// The terminal's width, when known. The lines are ASCII, so a byte is
    /// a column.
    columns: ?usize = null,
    /// Whole lines written since the last `clear`.
    lines: usize = 0,
    /// Whether the cursor is at the end of a line `rewrite` wrote.
    open_line: bool = false,

    /// `text` ends with a newline.
    fn line(self: *DoctorProgress, text: []const u8) void {
        if (!self.enabled) return;
        self.closeOpenLine();
        self.write(self.fit(text[0 .. text.len - 1]));
        self.write("\n");
        self.lines += 1;
    }

    fn rewrite(self: *DoctorProgress, text: []const u8) void {
        if (!self.enabled or !self.erase) return;
        self.write(if (self.open_line) "\r\x1b[2K" else "");
        self.write(self.fit(text));
        self.open_line = true;
    }

    /// `text` cut short of the last column, so it never wraps.
    fn fit(self: *const DoctorProgress, text: []const u8) []const u8 {
        const columns = self.columns orelse return text;
        return text[0..@min(text.len, columns -| 1)];
    }

    fn sessions(context: *anyopaque, done: usize, total: usize) void {
        const self: *DoctorProgress = @ptrCast(@alignCast(context));
        if (!self.enabled or total == 0) return;
        var buf: [96]u8 = undefined;
        const text = std.mem.print(&buf, "checking saved sessions ({d} of {d})...", .{ @min(done + 1, total), total }) catch return;
        self.rewrite(text);
    }

    fn clear(self: *DoctorProgress) void {
        if (!self.enabled or !self.erase) return;
        if (self.open_line) self.write("\r\x1b[2K");
        self.open_line = false;
        while (self.lines > 0) : (self.lines -= 1) self.write("\x1b[1A\x1b[2K");
    }

    fn closeOpenLine(self: *DoctorProgress) void {
        if (!self.open_line) return;
        self.write("\n");
        self.open_line = false;
        self.lines += 1;
    }

    fn write(self: *const DoctorProgress, text: []const u8) void {
        if (text.len == 0) return;
        writeStderr(self.deps, text) catch |err| {
            debug_trace.logf("doctor", "progress line not written err={s}", .{@errorName(err)});
        };
    }
};

fn writeDoctorReport(alloc: Allocator, deps: RunDeps, snapshot: output_contracts.DoctorSnapshot, format: output_contracts.OutputFormat) !void {
    if (format == .json) return writeDoctorJsonLine(alloc, deps, snapshot);
    const terminal = !builtin.is_test and terminal_env.stdoutIsTerminal();
    const text = try snapshot.renderTextStyled(alloc, .{
        .color = terminal and !terminal_env.colorDisabled(),
        .columns = if (terminal) terminal_env.stdoutColumns() else null,
    });
    defer alloc.free(text);
    try writeFormattedOutput(deps, text, format);
}

const UpgradeFlag = enum { channel, json };
const upgrade_flag_ids = cli_flags.idTable(UpgradeFlag, &builtin_commands.upgrade_options);

/// On a `--channel` value that names no channel, sets `rejected_channel` to it,
/// borrowed from `args`.
fn parseUpgradeArgs(args: []const [:0]const u8, rejected_channel: *?[]const u8) !UpgradeOptions {
    var options = UpgradeOptions{};
    var parser: cli_flags.Parser = .init(&builtin_commands.upgrade_options, args);
    while (parser.next() catch return error.InvalidUpgradeArgs) |item| switch (item) {
        .positional => return error.InvalidUpgradeArgs,
        .option => |match| switch (upgrade_flag_ids[match.index].?) {
            .channel => options.channel = update_target.Channel.parse(match.value.?) orelse {
                rejected_channel.* = match.value.?;
                return error.InvalidUpgradeArgs;
            },
            .json => options.format = .json,
        },
    };
    return options;
}

/// The line `spark upgrade --channel` prints after saving, so the user knows the
/// channel persists and where. Caller owns the result.
fn channelSavedLine(
    alloc: Allocator,
    channel: update_target.Channel,
    outcome: config_runtime.CommitOutcome,
) ![]u8 {
    return switch (outcome) {
        .unchanged => alloc.print("Release channel is already {s}.\n", .{channel.label()}),
        .committed => alloc.print("Release channel set to {s} in {s}/settings.json.\n", .{ channel.label(), profile_paths.displayRoot() }),
    };
}

const SessionListFlag = enum { live, all, limit, cursor, json };
const session_list_flag_ids = cli_flags.idTable(SessionListFlag, &builtin_commands.sessions_options);

/// The `sessions` arguments that name the list action. `spark sessions` lists by
/// default, and `spark sessions ls` names the same action.
fn sessionListArgs(rest: []const [:0]const u8) []const [:0]const u8 {
    if (rest.len > 0 and std.mem.eql(u8, rest[0], "ls")) return rest[1..];
    return rest;
}

fn parseSessionListArgs(args: []const [:0]const u8) !SessionListOptions {
    var options = SessionListOptions{};
    var parser: cli_flags.Parser = .init(&builtin_commands.sessions_options, args);
    while (parser.next() catch return error.InvalidLocalSurfaceArgs) |item| switch (item) {
        .positional => return error.InvalidLocalSurfaceArgs,
        .option => |match| switch (session_list_flag_ids[match.index].?) {
            .live => options.live = true,
            .all => options.scope = .all_workspaces,
            .limit => {
                options.limit = std.fmt.parseUnsigned(usize, match.value.?, 10) catch
                    return error.InvalidLocalSurfaceArgs;
                if (options.limit == 0 or options.limit > session_store.session_list_max_limit)
                    return error.InvalidLocalSurfaceArgs;
                if (options.paging_flag == null) options.paging_flag = "--limit";
            },
            .cursor => {
                options.continuation = try parseSessionListCursor(match.value.?);
                if (options.paging_flag == null) options.paging_flag = "--cursor";
            },
            .json => options.format = .json,
        },
    };
    return options;
}

fn parseSessionListCursor(raw: []const u8) !session_store.ResumableSessionContinuation {
    if (raw.len == 0 or raw.len > 320) return error.InvalidLocalSurfaceArgs;
    var fields = std.mem.splitScalar(u8, raw, ':');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidLocalSurfaceArgs, "v1")) {
        return error.InvalidLocalSurfaceArgs;
    }
    const updated_text = fields.next() orelse return error.InvalidLocalSurfaceArgs;
    const id = fields.next() orelse return error.InvalidLocalSurfaceArgs;
    if (fields.next() != null) return error.InvalidLocalSurfaceArgs;
    session_store.validateSessionId(id) catch return error.InvalidLocalSurfaceArgs;
    const updated_at_ms = std.fmt.parseInt(i64, updated_text, 10) catch
        return error.InvalidLocalSurfaceArgs;
    var canonical: [320]u8 = undefined;
    const encoded = std.mem.print(
        &canonical,
        "v1:{d}:{s}",
        .{ updated_at_ms, id },
    ) catch return error.InvalidLocalSurfaceArgs;
    if (!std.mem.eql(u8, encoded, raw)) return error.InvalidLocalSurfaceArgs;
    return .{ .updated_at_ms = updated_at_ms, .id = id };
}

fn formatSessionListCursor(
    alloc: Allocator,
    summary: session_store.SessionSummary,
) ![]u8 {
    return alloc.print(
        "v1:{d}:{s}",
        .{ summary.updated_at_ms, summary.id },
    );
}

fn parseWorkspaceArgs(args: []const [:0]const u8) !WorkspaceOptions {
    var positional: [2][]const u8 = undefined;
    var positional_len: usize = 0;
    var options = WorkspaceOptions{};
    var parser: cli_flags.Parser = .init(&builtin_commands.workspace_options, args);
    while (parser.next() catch return error.InvalidWorkspaceArgs) |item| switch (item) {
        // `--json` is the only flag.
        .option => options.format = .json,
        .positional => |arg| {
            if (positional_len >= positional.len) return error.InvalidWorkspaceArgs;
            positional[positional_len] = arg;
            positional_len += 1;
        },
    };

    if (positional_len == 0) return options;
    if (std.mem.eql(u8, positional[0], "list")) {
        if (positional_len != 1) return error.InvalidWorkspaceArgs;
        return options;
    }
    if (std.mem.eql(u8, positional[0], "clear")) {
        if (positional_len != 1) return error.InvalidWorkspaceArgs;
        options.action = .clear;
        return options;
    }
    if (std.mem.eql(u8, positional[0], "add")) {
        if (positional_len != 2 or positional[1].len == 0) return error.InvalidWorkspaceArgs;
        options.action = .{ .add = positional[1] };
        return options;
    }
    if (std.mem.eql(u8, positional[0], "remove")) {
        if (positional_len != 2 or positional[1].len == 0) return error.InvalidWorkspaceArgs;
        options.action = .{ .remove = positional[1] };
        return options;
    }
    return error.InvalidWorkspaceArgs;
}

const SessionFlag = enum { id, tail, json };
const session_flag_ids = cli_flags.idTable(SessionFlag, &builtin_commands.session_options);

/// The most turns `spark session --tail` takes, as its placeholder says.
const session_tail_max = 1000;

/// The flags and the one target shared by `spark session` and
/// `spark session recover`. A repeated `--id` keeps its last value; two
/// targets, or a positional target with `--id`, are an error.
const SessionTargetArgs = struct {
    format: output_contracts.OutputFormat = .text,
    /// Trimmed and non-empty; null when no target was given.
    target: ?[]const u8 = null,
    /// The target came from `--id`, so `last` is a literal ID.
    exact_id: bool = false,
    /// `--tail`, from 1 to `session_tail_max`; only `spark session` takes it.
    tail: ?usize = null,
};

fn parseSessionTargetArgs(args: []const [:0]const u8) error{InvalidSessionArgs}!SessionTargetArgs {
    var parsed: SessionTargetArgs = .{};
    var positional: ?[]const u8 = null;
    var id_flag: ?[]const u8 = null;
    var parser: cli_flags.Parser = .initDashOperands(&builtin_commands.session_options, args);
    while (parser.next() catch return error.InvalidSessionArgs) |item| switch (item) {
        .positional => |arg| {
            if (positional != null) return error.InvalidSessionArgs;
            positional = arg;
        },
        .option => |match| switch (session_flag_ids[match.index].?) {
            .id => id_flag = match.value.?,
            .tail => {
                const count = std.fmt.parseUnsigned(usize, match.value.?, 10) catch return error.InvalidSessionArgs;
                if (count == 0 or count > session_tail_max) return error.InvalidSessionArgs;
                parsed.tail = count;
            },
            .json => parsed.format = .json,
        },
    };
    if (positional != null and id_flag != null) return error.InvalidSessionArgs;
    const raw = id_flag orelse positional orelse return parsed;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidSessionArgs;
    parsed.target = trimmed;
    parsed.exact_id = id_flag != null;
    return parsed;
}

fn parseSessionDetailArgs(
    alloc: Allocator,
    args: []const [:0]const u8,
) !SessionDetailOptions {
    const parsed = parseSessionTargetArgs(args) catch return error.InvalidSessionDetailArgs;
    var options = SessionDetailOptions{ .format = parsed.format, .tail = parsed.tail };
    const target = parsed.target orelse return options;
    options.target = if (!parsed.exact_id and std.mem.eql(u8, target, "last"))
        .last
    else
        .{ .id = try alloc.dupe(u8, target) };
    return options;
}

fn parseSessionRecoveryArgs(
    alloc: Allocator,
    args: []const [:0]const u8,
) !SessionRecoveryOptions {
    const parsed = parseSessionTargetArgs(args) catch return error.InvalidSessionRecoveryArgs;
    // A recovery copies the whole session; it shows no turns to tail.
    if (parsed.tail != null) return error.InvalidSessionRecoveryArgs;
    const target = parsed.target orelse return error.InvalidSessionRecoveryArgs;
    return .{
        .format = parsed.format,
        .session_id = try alloc.dupe(u8, target),
    };
}

fn parseResumeArgs(
    alloc: Allocator,
    args: []const [:0]const u8,
    top_level_alias: bool,
) !ResumeTarget {
    if (args.len == 0) return .last;

    if (top_level_alias) {
        const flag = args[0];
        if (std.mem.startsWith(u8, flag, resume_inline_prefix)) {
            if (args.len != 1) return error.InvalidResumeArgs;
            return resumeFlagTarget(alloc, flag[resume_inline_prefix.len..]);
        }
        if (std.mem.eql(u8, flag, "--resume") or std.mem.eql(u8, flag, resume_short_flag)) {
            return switch (args.len) {
                1 => .pick,
                2 => resumeFlagTarget(alloc, args[1]),
                else => error.InvalidResumeArgs,
            };
        }
        if (std.mem.eql(u8, flag, "--resume-last")) return error.RemovedResumeLast;
        if (std.mem.startsWith(u8, flag, resume_id_alias_prefix)) return error.RemovedResumeIdAlias;
        if (args.len != 1) return error.InvalidResumeArgs;
        if (std.mem.eql(u8, flag, "-c") or std.mem.eql(u8, flag, "--continue")) return .remembered;
        return error.InvalidResumeArgs;
    }

    if (std.mem.eql(u8, args[0], "--resume")) return error.RemovedResumeLastFlag;
    if (std.mem.eql(u8, args[0], "--id")) return error.RemovedResumeIdFlag;
    if (args.len != 1) return error.InvalidResumeArgs;

    const trimmed = std.mem.trim(u8, args[0], " \t\r\n");
    if (trimmed.len == 0) return error.InvalidResumeArgs;
    if (std.mem.eql(u8, trimmed, "last")) return .last;
    return .{ .id = try alloc.dupe(u8, trimmed) };
}

/// The session a `--resume` or `-r` value names: `last`, or an exact ID.
fn resumeFlagTarget(alloc: Allocator, value: []const u8) !ResumeTarget {
    const id = std.mem.trim(u8, value, " \t\r\n");
    if (id.len == 0) return error.InvalidResumeArgs;
    if (std.mem.eql(u8, id, "last")) return .last;
    return .{ .id = try alloc.dupe(u8, id) };
}

/// The hint for a removed resume spelling, or null for any other error.
fn removedResumeHint(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.RemovedResumeLast => "spark: --resume-last was removed; use spark --resume last\n",
        error.RemovedResumeIdAlias => "spark: --resume-<id> was removed; use spark --resume <id>\n",
        error.RemovedResumeCommand => "spark: spark resume was removed; use spark --resume [last|<id>] or spark session resume [last|<id>]\n",
        error.RemovedResumeIdFlag => "spark session resume: --id was removed; use spark session resume <id>\n",
        error.RemovedResumeLastFlag => "spark session resume: --resume --last was removed; use spark session resume last\n",
        else => null,
    };
}

const WorkflowFlag = enum { permission_mode, full_access, yolo, provider, model, effort, fast, no_fast, ultrafast, no_ultrafast, create };
// `spark issue` documents the same flags as `spark pr`.
const workflow_flag_ids = cli_flags.idTable(WorkflowFlag, &builtin_commands.pr_options);

/// Reads `--auto` and `--create`, then joins the rest into the context.
fn parseWorkflowArgs(alloc: Allocator, args: []const [:0]const u8, bad: *?BadAgentValue) !WorkflowOptions {
    var opts: WorkflowOptions = .{};
    errdefer opts.agent.deinit(alloc);
    var parser: cli_flags.Parser = .initPrefix(&builtin_commands.pr_options, args);
    // Prefix mode stops at positionals, so every item is an option.
    while (parser.next() catch return error.InvalidWorkflowArgs) |item| {
        const id = workflow_flag_ids[item.option.index].?;
        if (agent_run_flags.fromId(id)) |flag| {
            try applyAgentFlag(alloc, &opts.agent, flag, &builtin_commands.pr_options, item.option, bad);
            continue;
        }
        switch (id) {
            .create => opts.create = true,
            else => unreachable,
        }
    }
    // Context starts at the first argument that isn't a flag. A dash word
    // there is a flag this command doesn't take, such as a typo, not
    // context: context that starts with a dash follows `--`. Words after the
    // context starts are all context.
    var context_start = parser.index;
    if (context_start < args.len) {
        const arg = args[context_start];
        if (std.mem.eql(u8, arg, "--")) {
            context_start += 1;
        } else if (arg.len >= 2 and arg[0] == '-') {
            return error.InvalidWorkflowArgs;
        }
    }
    opts.context = try joinArgs(alloc, args[context_start..]);
    return opts;
}

fn joinArgs(alloc: Allocator, args: []const [:0]const u8) ![]u8 {
    if (args.len == 0) return alloc.dupe(u8, "");

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (args, 0..) |arg, i| {
        if (i > 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(arg);
    }
    return try out.toOwnedSlice();
}

fn isVersionFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v");
}

fn testCommandCatalog() CommandCatalog {
    return builtin_commands.top_level_registry;
}

const CaptureOutput = struct {
    stdout: std.Io.Writer.Allocating,
    stderr: std.Io.Writer.Allocating,
    setup_store_calls: usize = 0,
    setup_read_calls: usize = 0,
    setup_value_matched: bool = false,
    setup_interactive_store: bool = false,
    setup_store_disabled: bool = false,

    fn init(alloc: Allocator) CaptureOutput {
        return .{
            .stdout = .init(alloc),
            .stderr = .init(alloc),
        };
    }

    fn deinit(self: *@This()) void {
        self.stdout.deinit();
        self.stderr.deinit();
    }

    fn deps(self: *@This()) RunDeps {
        return .{
            .stdout_ctx = self,
            .stderr_ctx = self,
            .setup_ctx = self,
            .write_stdout = captureStdout,
            .write_stderr = captureStderr,
            .read_masked_key = captureReadMaskedKey,
            .setup_terminal_available = captureSetupTerminalAvailable,
        };
    }

    fn secretStore(self: *@This()) host.SecretStore {
        return .{
            .context = self,
            .backend_label = "test credential store",
            .is_disabled_fn = captureSecretStoreIsDisabled,
            .load_fn = captureSecretStoreLoad,
            .store_fn = captureSecretStoreWrite,
            .store_interactive_fn = captureSecretStoreInteractiveWrite,
        };
    }
};

fn captureStdout(ctx: ?*anyopaque, text: []const u8) !void {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    try capture.stdout.writer.writeAll(text);
}

fn captureStderr(ctx: ?*anyopaque, text: []const u8) !void {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    try capture.stderr.writer.writeAll(text);
}

fn captureSetupTerminalAvailable(_: ?*anyopaque) bool {
    return true;
}

fn captureReadMaskedKey(
    ctx: ?*anyopaque,
    alloc: Allocator,
    _: WriteFn,
    _: ?*anyopaque,
) ![]u8 {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    capture.setup_read_calls += 1;
    return alloc.dupe(u8, "paste-only-test-key");
}

fn captureSecretStoreIsDisabled(ctx: ?*anyopaque) bool {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    return capture.setup_store_disabled;
}

fn captureSecretStoreLoad(
    _: ?*anyopaque,
    _: Allocator,
) host.SecretStoreLoadError!?[]u8 {
    return null;
}

fn captureSecretStoreWrite(
    ctx: ?*anyopaque,
    _: Allocator,
    value: []const u8,
) host.SecretStoreWriteError!void {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    capture.setup_store_calls += 1;
    capture.setup_value_matched = std.mem.eql(u8, value, "paste-only-test-key");
}

fn captureSecretStoreInteractiveWrite(
    ctx: ?*anyopaque,
) host.SecretStoreWriteError!bool {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    if (!capture.setup_interactive_store) return false;
    capture.setup_store_calls += 1;
    return true;
}

fn gatherNoopContextForTest(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    return .{};
}

fn appendNoopStaticContextForTest(_: context_contract.StaticContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) context_contract.ProviderError!void {}

fn appendNoopTransientContextForTest(_: context_contract.TransientContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) context_contract.ProviderError!void {}

const test_surface_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.surface_context",
    .gather_project_context_fn = gatherNoopContextForTest,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendNoopStaticContextForTest,
    .append_transient_fn = appendNoopTransientContextForTest,
} };

fn clearMcpConfigInspectionForTest(
    _: Allocator,
) error{OutOfMemory}!mcp_contract.ProfileConfigDiagnostic {
    return .clear;
}

var mcp_local_inspection_calls_for_test: usize = 0;
var mcp_profile_add_calls_for_test: usize = 0;
var mcp_profile_remove_calls_for_test: usize = 0;

fn failingMcpLocalInspectionForTest(
    alloc: Allocator,
    workspace_root: []const u8,
) error{OutOfMemory}!mcp_health.LocalConfigInspection {
    mcp_local_inspection_calls_for_test += 1;
    var result = try mcp_health.inspectLocalConfigUnavailable(
        alloc,
        workspace_root,
    );
    result.profile_diagnostic = .{ .failed = error.McpConfigInvalidJson };
    result.inspection_error = "McpConfigInvalidJson";
    return result;
}

fn unexpectedAcpRunForTest(_: ?*anyopaque, _: Allocator, _: acp_runner.Config) anyerror!void {
    return error.TestUnexpectedAcpRun;
}

fn stubLoadStartupStateWithoutCredentials(
    alloc: Allocator,
    _: []const u8,
    default_agent_step_limit: usize,
) !app_lifecycle.StartupState {
    var state = app_lifecycle.StartupState{
        .agent_step_limit = default_agent_step_limit,
    };
    errdefer state.deinit(alloc);
    state.workspace_root = try alloc.dupe(u8, "/tmp/spark");
    return state;
}

fn failingStartupStateWithoutCredentials(
    _: Allocator,
    _: []const u8,
    _: usize,
) !app_lifecycle.StartupState {
    return error.StartupShouldNotRun;
}

fn stubLoadStartupStatus(
    alloc: Allocator,
    _: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !app_lifecycle.StartupStatus {
    const workspace_root = try alloc.dupe(u8, "/tmp/spark");
    errdefer alloc.free(workspace_root);
    const selected_model = try alloc.dupe(u8, default_model);
    errdefer alloc.free(selected_model);
    return .{
        .workspace_root = workspace_root,
        .selected_model = selected_model,
        .owned_selected_model = selected_model,
        .permission_mode = config_runtime.default_permission_mode,
        .agent_step_limit = default_agent_step_limit,
    };
}

fn failingStartupState(
    _: Allocator,
    _: oauth_transport.Provider,
    _: host.SecretStore,
    _: []const u8,
    _: usize,
) !app_lifecycle.StartupState {
    return error.StartupShouldNotRun;
}

const ChatUrlProbe = struct {
    called: bool = false,

    fn provider(self: *ChatUrlProbe) gateway_provider.ChatUrlProvider {
        return .{
            .context = self,
            .resolve_fn = resolve,
        };
    }

    fn resolve(raw: ?*anyopaque, fallback: []const u8) []const u8 {
        const self: *ChatUrlProbe = @ptrCast(@alignCast(raw.?));
        self.called = std.mem.eql(u8, fallback, "https://example.test/chat");
        return "http://127.0.0.1:43123/chat";
    }
};
