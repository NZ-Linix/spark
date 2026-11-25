const std = @import("std");
const command_specs = @import("../core/slash_commands/command_specs.zig");

const Allocator = std.mem.Allocator;

pub const TopLevelKind = command_specs.TopLevelKind;
pub const TopLevelSpec = command_specs.TopLevelSpec;
pub const TopLevelHelpGroup = command_specs.TopLevelHelpGroup;
pub const TopLevelFlag = command_specs.TopLevelFlag;
pub const TopLevelExample = command_specs.TopLevelExample;
pub const TopLevelResource = command_specs.TopLevelResource;
pub const TopLevelRegistry = command_specs.TopLevelRegistry;
pub const HelpStyle = command_specs.HelpStyle;
pub const SlashKind = command_specs.SlashKind;
pub const SlashPresentationCategory = command_specs.SlashPresentationCategory;
pub const SlashSpec = command_specs.SlashSpec;
pub const SlashRegistry = command_specs.SlashRegistry;

const json_option = command_specs.OptionDoc{ .flag = "--json", .description = "Emit machine-readable JSON instead of text" };

/// Options for `spark ask`. `cli_ask` parses against this list and its help is
/// rendered from it, so the two can't disagree.
/// Options for local commands that only take `--json`.
pub const json_only_options = [_]command_specs.OptionDoc{json_option};

pub const sessions_options = [_]command_specs.OptionDoc{
    .{ .flag = "--live", .description = "List only the sessions an spark process has open now, with their subagents" },
    .{ .flag = "--all", .description = "List saved sessions across every workspace in this profile" },
    .{ .flag = "--limit <1-100>", .description = "Set the maximum sessions returned per page" },
    .{ .flag = "--cursor <cursor>", .description = "Continue from a prior sessions result" },
    json_option,
};

pub const sessions_convert_options = [_]command_specs.OptionDoc{json_option};

const sessions_subcommands = [_]command_specs.SubcommandDoc{
    .{ .usage = "ls", .description = "List saved sessions (default)", .options = &sessions_options },
    .{ .usage = "convert", .description = "Convert every session saved in the previous format", .options = &sessions_convert_options },
};

const models_subcommands = [_]command_specs.SubcommandDoc{
    .{ .usage = "ls", .description = "List available models (default)", .options = &.{json_option} },
};

/// Options for `spark doctor`. Its parser in `src/core/cli/cli_surface.zig`
/// reads this list, so help and parsing can't disagree.
pub const doctor_options = [_]command_specs.OptionDoc{
    json_option,
    .{ .flag = "--fix", .description = "Remove old terminal and side folders whose session is gone" },
    .{ .flag = "--deep", .description = "Read every saved file of each session checked, with no time limit; slower" },
};

pub const convo_option: command_specs.OptionDoc = .{
    .flag = "--convo <file>",
    .description = "Keep the conversation in this one file and nowhere else, kept out of saved sessions and /resume; the same command reopens it, and the file can be shared",
};

pub const upgrade_options = [_]command_specs.OptionDoc{
    .{ .flag = "--channel <stable|dev>", .description = "Select and remember the release channel" },
    json_option,
};

pub const uninstall_options = [_]command_specs.OptionDoc{
    .{ .flag = "--yes", .description = "Confirm permanent removal without prompting" },
};

pub const workspace_options = [_]command_specs.OptionDoc{json_option};

const workspace_subcommands = [_]command_specs.SubcommandDoc{
    .{ .usage = "list", .description = "List the primary and additional directories (default)" },
    .{ .usage = "add PATH", .description = "Persist an existing additional directory" },
    .{ .usage = "remove PATH", .description = "Remove an additional directory" },
    .{ .usage = "clear", .description = "Remove all additional directories" },
};

const config_subcommands = [_]command_specs.SubcommandDoc{
    .{ .usage = "list", .description = "List the values set in each settings file (default)", .options = &config_options },
    .{ .usage = "get <key>", .description = "Print the value spark uses for a setting", .options = &config_options },
    .{ .usage = "set <key> <value>", .description = "Save a preference in ~/.spark/settings.json", .settable_key = true },
    .{ .usage = "unset <key>", .description = "Remove a preference from ~/.spark/settings.json", .settable_key = true },
    .{ .usage = "schema", .description = "Print the JSON Schema for ~/.spark/settings.json", .options = &config_schema_options },
};

const config_schema_options = [_]command_specs.OptionDoc{
    .{ .flag = "--project", .description = "Print the schema for a project .spark.json instead" },
};

/// Every flag `spark config` parses: its own and `schema --project`.
pub const config_parse_options = config_options ++ config_schema_options;

const config_options = [_]command_specs.OptionDoc{
    .{ .flag = "--global", .description = "Only the profile's own settings" },
    .{ .flag = "--workspace", .description = "Only this workspace's override in the profile (list and get)" },
    .{ .flag = "--show-origin", .description = "Start each line with where the value is set" },
    json_option,
};

const session_subcommands = [_]command_specs.SubcommandDoc{
    .{ .usage = "last", .description = "Inspect the current workspace session" },
    .{ .usage = "resume [last|<id>]", .description = "Resume the latest workspace session or a session by id" },
    .{ .usage = "recover <id>", .description = "Copy a recoverable corrupt session into a new session" },
};

pub const session_options = [_]command_specs.OptionDoc{
    .{ .flag = "--id <id>", .description = "Inspect a saved session by exact id" },
    .{ .flag = "--tail <1-1000>", .description = "Show only the last turns, each under its own number" },
    json_option,
};

pub const acp_options = agentRunOptions("sessions this server starts") ++ [_]command_specs.OptionDoc{
    .{ .flag = "--log-file <path>", .description = "Write ACP logs to a file" },
};

pub const acp_usage = "acp " ++ agent_run_usage ++ " [--log-file <path>]";

pub const pr_options = agentRunOptions("this request") ++ [_]command_specs.OptionDoc{
    .{ .flag = "--create", .description = "Publish the drafted pull request via the GitHub CLI" },
};

const issue_options = agentRunOptions("this request") ++ [_]command_specs.OptionDoc{
    .{ .flag = "--create", .description = "Publish the drafted issue via the GitHub CLI" },
};

pub const replay_options = [_]command_specs.OptionDoc{
    .{ .flag = "--frames", .description = "Render each captured frame" },
    .{ .flag = "--golden <path>", .description = "Write the final rendered grid to a file" },
    .{ .flag = "--frames-dir <path>", .description = "Write rendered frames to a directory" },
    json_option,
};

/// `spark mcp list` options; `spark mcp --help` shows them in its usage line.
const mcp_subcommands = [_]command_specs.SubcommandDoc{
    .{ .usage = "list", .description = "List configured servers; never connects", .options = &mcp_list_options },
    .{ .usage = "show NAME", .description = "Connect to a server: status, version, and tools", .options = &mcp_show_options },
    .{
        .usage = "add NAME URL",
        .description = "Add an HTTP server, or a command after --",
        .subcommands = &.{.{ .usage = "slack", .description = "Add Slack's server" }},
        .options = &mcp_add_options,
    },
    .{ .usage = "remove NAME", .description = "Remove a server and its login", .options = &mcp_scope_options },
    .{ .usage = "login NAME", .description = "Sign in to an HTTP server", .options = &mcp_login_options },
    .{ .usage = "logout NAME", .description = "Sign out and delete the login" },
    .{ .usage = "approve NAME", .description = "Approve a project server from .mcp.json", .options = &mcp_approve_options },
    .{ .usage = "reject NAME", .description = "Reject a project server" },
    .{
        .usage = "call TOOL [JSON | -]",
        .description = "Run an MCP tool from a command spark's shell tool runs",
        .subcommands = &.{
            .{ .usage = "list SERVER", .description = "List a server's tools" },
            .{ .usage = "search QUERY...", .description = "Find the tools that match QUERY" },
            .{ .usage = "help TOOL", .description = "Show a tool's arguments" },
        },
    },
};

// The flags of the `spark mcp` and `/mcp` verbs, which `src/core/mcp_host/verbs.zig`
// parses and completion offers.

/// `--global` names ~/.spark/mcp.json, the default, and `--project` the
/// project's .mcp.json. `--profile` is the older name for `--global`.
pub const mcp_scope_options = [_]command_specs.OptionDoc{
    .{ .flag = "--global", .description = "Use ~/.spark/mcp.json, the default" },
    .{ .flag = "--profile", .description = "Older name for --global", .hidden = true },
    .{ .flag = "--project", .description = "Use the project's .mcp.json" },
};
pub const mcp_add_options = mcp_scope_options ++ [_]command_specs.OptionDoc{
    .{ .flag = "--env <KEY=VALUE>", .description = "Set an environment variable for a command server" },
    .{ .flag = "--header <KEY=VALUE>", .description = "Send a header to an HTTP server" },
    .{ .flag = "--no-login", .description = "Don't sign in to an HTTP server that needs a login" },
};
/// `list --connect` moved to `show NAME`; it is read to say so.
const mcp_connect_option: command_specs.OptionDoc = .{ .flag = "--connect", .description = "Moved to show NAME", .hidden = true };
pub const mcp_list_options = [_]command_specs.OptionDoc{ json_option, mcp_connect_option };
/// `/mcp list` in a session prints no JSON.
pub const mcp_list_shell_options = [_]command_specs.OptionDoc{mcp_connect_option};
pub const mcp_show_options = [_]command_specs.OptionDoc{json_option};
pub const mcp_login_options = [_]command_specs.OptionDoc{
    .{ .flag = "--no-browser", .description = "Print the sign-in address instead of opening it" },
};
pub const mcp_approve_options = [_]command_specs.OptionDoc{
    .{ .flag = "--all", .description = "Approve every project server" },
};

const permission_modes = [_][]const u8{"full-access"};

/// The flags that shape an agent run, the same on every command that runs the
/// agent: `spark ask`, `spark pr`, `spark issue`, and `spark acp`. `scope` names what they
/// shape, such as "this request". `src/core/cli/agent_run_flags.zig` parses them.
fn agentRunOptions(comptime scope: []const u8) [10]command_specs.OptionDoc {
    return .{
        .{ .flag = "--permission-mode <mode>", .description = "Set the permission mode for " ++ scope ++ "; full-access is the only mode", .values = &permission_modes },
        .{ .flag = "--full-access", .description = "Disable spark permission checks" },
        .{ .flag = "--yolo", .description = "Alias for --full-access" },
        .{ .flag = "--provider <name>", .description = "Override the model provider for " ++ scope ++ " with a configured provider name" },
        .{ .flag = "--model <id>", .description = "Override the model for " ++ scope },
        .{ .flag = "--effort <level>", .description = "Override the reasoning effort for " ++ scope },
        .{ .flag = "--fast", .description = "Enable Fast mode for " ++ scope ++ " when the model supports it" },
        .{ .flag = "--no-fast", .description = "Disable Fast mode for " ++ scope },
        .{ .flag = "--ultrafast", .description = "Request Ultrafast mode for " ++ scope ++ " when the model supports it" },
        .{ .flag = "--no-ultrafast", .description = "Disable Ultrafast mode for " ++ scope },
    };
}

/// The usage-line form of `agentRunOptions`.
const agent_run_usage = "[--permission-mode <mode>|--full-access] [--provider <name>] [--model <id>] [--effort <level>] [--fast|--no-fast] [--ultrafast|--no-ultrafast]";

pub const ask_options = agentRunOptions("this request") ++ [_]command_specs.OptionDoc{
    .{ .flag = "--image PATH", .description = "Attach an image file; repeat for multiple images" },
    .{ .flag = "--system TEXT", .description = "Replace the built-in system prompt for this request" },
    json_option,
    .{ .flag = "--quiet", .description = "Suppress assistant output" },
    .{ .flag = "--timeout <seconds>", .description = "Time limit for each shell command the agent runs" },
    .{ .flag = "--config <key=value>", .description = "Override a setting for this request, with the keys spark config set takes; repeatable" },
    .{ .flag = "--no-save", .description = "Do not save the session; incompatible with --resume" },
    .{ .flag = "--no-color", .description = "Render TTY output without colors or hyperlinks; NO_COLOR or TERM=dumb also turns color off" },
    .{ .flag = "--resume <last|<id>>", .description = "Continue the last session or a session by id" },
    .{ .flag = "--resume-id <id>", .description = "Continue a session by exact id", .replacement = "use --resume <id>" },
    .{ .flag = "--", .description = "Treat every following argument as prompt text" },
};

pub const top_level_specs = [_]TopLevelSpec{
    .{
        .kind = .help,
        .token = "help",
        .aliases = &.{ "--help", "-h" },
        .usage = "help",
        .summary = "Show this help",
    },
    .{
        .kind = .ask,
        .token = "ask",
        .usage = "ask " ++ agent_run_usage ++ " [--image PATH] [--system TEXT] [--json] [--quiet] [--timeout <seconds>] [--config <key=value>] [--no-save] [--no-color] [--resume <last|<id>>] [--] <prompt>",
        .summary = "Run one noninteractive request",
        .options = &ask_options,
        .details = &.{
            "The prompt may be passed as arguments or piped on stdin when no prompt args are given.",
            "TTY stdout uses the Minimal transcript presentation; redirected stdout emits raw assistant Markdown.",
            "Operational progress and diagnostics are written to stderr. JSON `output` keeps accumulated assistant Markdown; `final_output` contains only the completed final response, or an empty string when absent.",
            "JSON usage sums reported main-agent input_tokens and output_tokens, including with --no-save; unreported counts are null. cache_read_tokens and cache_write_tokens appear only when the provider reports them. Subagent usage and dollar spend are excluded.",
            "JSON subagents appears only when a subagent did work in this request. It lists each one in the order it first ran, with its name, id, and usage in the same shape, counted for this request alone. spark session <session_id>/<name> reads one and prints the same id.",
            "--system replaces only the built-in base prompt for this request; tool, skill, project, and runtime context still apply.",
        },
    },
    .{
        .kind = .acp,
        .token = "acp",
        .usage = acp_usage,
        .summary = "Start an ACP server over stdio",
        .options = &acp_options,
    },
    .{
        .kind = .pr,
        .token = "pr",
        .usage = "pr " ++ agent_run_usage ++ " [--create] [--] [context]",
        .summary = "Draft or publish a pull request",
        .options = &pr_options,
        .details = &.{
            "Must run inside a git repository. Without --create, the drafted PR is printed only.",
        },
    },
    .{
        .kind = .issue,
        .token = "issue",
        .usage = "issue " ++ agent_run_usage ++ " [--create] [--] [context]",
        .summary = "Draft or publish a GitHub issue",
        .options = &issue_options,
    },
    .{
        .kind = .status,
        .token = "status",
        .usage = "status [--json]",
        .summary = "Show configuration and runtime information",
        .options = &.{json_option},
    },
    .{
        .kind = .mcp,
        .token = "mcp",
        .usage = "mcp <command> ...",
        // `spark mcp -h` is the verbs' own help (`mcp_host/verbs.zig` writeUsage).
        .summary = "Manage MCP servers without opening the interactive shell",
        .subcommands = &mcp_subcommands,
    },
    .{
        .kind = .models,
        .token = "models",
        .usage = "models [ls] [--json]",
        .summary = "List available models",
        .subcommands = &models_subcommands,
        .options = &.{json_option},
    },
    .{
        .kind = .provider,
        .token = "provider",
        .usage = "provider <name> | show <name> | set <name> [<model>] <field> <value> | unset <name> [<model>] <field> | remove-model <name> <model> | rename <name> <new-name>",
        .summary = "Choose a configured provider, or change one of its fields",
    },
    .{
        .kind = .doctor,
        .token = "doctor",
        .usage = "doctor [--json] [--fix] [--deep]",
        .summary = "Check that spark can work here, with a fix for each problem",
        .options = &doctor_options,
    },
    .{
        .kind = .session,
        .token = "session",
        .usage = "session <last|id|id/agent>|--id <id> [--tail <1-1000>] [--json] | session resume [last|<id>] | session recover <id>|--id <id> [--json]",
        .summary = "Inspect, resume, or recover saved sessions",
        .subcommands = &session_subcommands,
        .options = &session_options,
        .details = &.{
            "<id>/<agent> reads a subagent by the name its parent gave it, and <id>/<agent>/<agent> that subagent's own; spark sessions --live lists them.",
            "Reading takes no lock, so it works while another spark has the session open. --tail shows finished turns; the one in progress is not saved yet.",
        },
    },
    .{
        .kind = .sessions,
        .token = "sessions",
        .usage = "sessions [ls] [--all] [--limit <1-100>] [--cursor <cursor>] [--json] | sessions [ls] --live [--all] [--json] | sessions convert [--json]",
        .summary = "List saved sessions for the current workspace",
        .subcommands = &sessions_subcommands,
        .options = &sessions_options,
        .details = &.{
            "--live shows each session's state (working, idle, or unknown) and the model saved with it, with its subagents in a tree below it; spark session <id>/<agent> reads one.",
        },
    },
    .{
        .kind = .@"resume",
        .token = "resume",
        .aliases = &.{ "--resume", "--continue", "-c", "-r" },
        .help_title = "--resume",
        .hidden_from_top_level_help = true,
        .usage = "session resume [last|<id>] | -r, --resume [last|<id>] | --continue | -c",
        .summary = "Continue a saved interactive session",
        .options = &.{
            .{ .flag = "-r", .description = "Short for --resume; with no value, choose a session from a picker" },
            .{ .flag = "last", .description = "Resume the most recent session" },
            .{ .flag = "<id>", .description = "Resume a session by id" },
        },
    },
    .{
        .kind = .upgrade,
        .token = "upgrade",
        .aliases = &.{"update"},
        .usage = "upgrade [--channel <stable|dev>] [--json]",
        .summary = "Upgrade spark on the selected release channel",
        .options = &upgrade_options,
    },
    .{
        .kind = .pair,
        .token = "pair",
        .usage = "pair",
        .summary = "Pair an iPhone so it can see and start spark sessions here",
        .details = &.{
            "Shows a six-digit code to type into the spark iPhone app, then keeps this computer reachable from the phone.",
            "Runs spark-bridge, which installs beside spark.",
        },
    },
    .{
        .kind = .uninstall,
        .token = "uninstall",
        .usage = "uninstall [--yes]",
        .summary = "Remove spark and its local profile",
        .options = &uninstall_options,
        .details = &.{
            "Permanently deletes the running spark binary and the default profile, including settings, credentials, and saved sessions.",
            "Close other spark sessions first. With a custom SPARK_HOME, back up or remove that profile manually and unset SPARK_HOME before uninstalling.",
        },
    },
    .{
        .kind = .replay,
        .token = "replay",
        .usage = "replay <tape> [--frames] [--json] [--golden <path>] [--frames-dir <path>]",
        .summary = "Replay a recorded terminal session",
        .hidden_from_top_level_help = true,
        .options = &replay_options,
        .details = &.{
            "Developer tool for reproducing terminal rendering bugs from SPARK_RECORD and SPARK_DEBUG_RECORD tapes. It is not listed in `spark help`.",
        },
    },
    .{
        .kind = .workspace,
        .token = "workspace",
        .usage = "workspace [list|add PATH|remove PATH|clear] [--json]",
        .summary = "Manage additional workspace directories",
        .subcommands = &workspace_subcommands,
        .options = &workspace_options,
        .details = &.{
            "Additional directories are stored for the current primary workspace.",
        },
    },
    .{
        .kind = .completion,
        .token = "completion",
        .usage = "completion bash|zsh|fish",
        .summary = "Print a shell completion script",
        .subcommands = &.{
            .{ .usage = "bash", .description = "Load it with: eval \"$(spark completion bash)\"" },
            .{ .usage = "zsh", .description = "Load it after compinit with: source <(spark completion zsh)" },
            .{ .usage = "fish", .description = "Load it with: spark completion fish | source" },
        },
        .details = &.{
            "Add the load line to ~/.bashrc, ~/.zshrc, or ~/.config/fish/config.fish to keep it in new shells.",
            "Tab completes commands, flags, setting keys after spark config get, set, and unset, and fixed flag values.",
        },
    },
    .{
        .kind = .config,
        .token = "config",
        .usage = "config [list|get <key>|set <key> <value>|unset <key>|schema [--project]] [--global|--workspace] [--show-origin] [--json]",
        .summary = "Show and change spark settings",
        .subcommands = &config_subcommands,
        .options = &config_options,
        .details = &.{
            "Values come from .spark.json, ~/.spark/settings.json, and this workspace's override in it. When a key repeats, the last line is the one spark uses.",
            "Keys are dotted, such as status_line.context. A flag or an SPARK_* variable can override a value for one run; spark status shows what a run uses.",
            "set and unset change plain preferences for every workspace, such as fast_mode, effort, theme, and status_line.context. Switches take true or false. Permission, model, provider, and account settings keep their own commands.",
            "schema prints a JSON Schema that editors use to complete and check ~/.spark/settings.json, and --project prints the one for .spark.json. A file whose \"$schema\" names https://github.com/NZ-Linix/spark or https://github.com/NZ-Linix/spark gets the same check.",
        },
    },
    command_specs.slack_install_spec,
};

pub const top_level_help_default_width = command_specs.top_level_help_default_width;
pub const top_level_help_fast_buffer_bytes: usize = 32 * 1024;

pub const top_level_help_groups = [_]TopLevelHelpGroup{
    .{ .entries = &.{
        .{ .kind = .ask, .usage = "ask <prompt>" },
    } },
    .{ .entries = &.{
        .{ .kind = .pr, .usage = "pr [context]" },
        .{ .kind = .issue, .usage = "issue [context]" },
    } },
    .{ .entries = &.{
        .{ .kind = .sessions, .usage = "sessions" },
        .{ .kind = .session, .usage = "session <last|id>" },
        .{ .usage = "session resume [last|id]", .summary = "Resume the latest workspace session or a session by id" },
        .{ .usage = "session recover <id>", .summary = "Copy a recoverable corrupt session" },
    } },
    .{ .entries = &.{
        .{ .kind = .provider, .usage = "provider <name>", .summary = "Choose a configured provider" },
        .{ .kind = .models, .usage = "models" },
    } },
    .{ .entries = &.{
        .{ .kind = .status, .usage = "status" },
        .{ .kind = .doctor, .usage = "doctor" },
        .{ .kind = .mcp, .usage = "mcp <command> ..." },
        .{ .kind = .slack, .usage = "slack <install|status|refresh>" },
        .{ .kind = .workspace, .usage = "workspace" },
        .{ .kind = .config, .usage = "config" },
        .{ .kind = .upgrade, .usage = "upgrade|update", .summary = "Upgrade spark on the selected release channel" },
        .{ .kind = .pair, .usage = "pair", .summary = "Pair an iPhone" },
        .{ .kind = .uninstall, .usage = "uninstall" },
        .{ .kind = .acp, .usage = "acp" },
        .{ .kind = .completion, .usage = "completion <shell>" },
        .{ .kind = .help, .usage = "help" },
    } },
};

/// The launch-wide flags: they go before a command, which can't take them
/// itself, as `git -C dir log` does.
pub const launch_wide_options = [_]command_specs.OptionDoc{
    .{ .flag = "--context-limit <spec>", .description = "" },
    .{ .flag = "--add-dir <path>", .description = "" },
    .{ .flag = "--no-additional-dirs", .description = "" },
    .{ .flag = "--tool-placement <spec>", .description = "" },
};

/// The flags `spark` reads before a command or an interactive launch, in the
/// form the shared flag parser reads. `top_level_flags` documents them in
/// `spark --help`, and a test checks that the two lists match. The usage line
/// after a launch-flag mistake is built from this list.
pub const launch_options = launch_wide_options ++ [_]command_specs.OptionDoc{
    .{ .flag = "--provider <name>", .description = "" },
    .{ .flag = "--model <id>", .description = "" },
    .{ .flag = "--effort <level>", .description = "" },
    .{ .flag = "--fast", .description = "" },
    .{ .flag = "--no-fast", .description = "" },
    .{ .flag = "--ultrafast", .description = "" },
    .{ .flag = "--no-ultrafast", .description = "" },
    .{ .flag = "--permission-mode <mode>", .description = "", .values = &permission_modes },
    .{ .flag = "--full-access", .description = "" },
    .{ .flag = "--yolo", .description = "" },
    .{ .flag = "--profile <name>", .description = "" },
    .{ .flag = "--instances <n>", .description = "" },
};

/// `usage: spark [--context-limit <spec>] ... <command>`, from `launch_options`,
/// with each `--x` and `--no-x` pair written as `[--x|--no-x]`.
pub const launch_usage: []const u8 = blk: {
    @setEvalBranchQuota(20_000);
    var out: []const u8 = "usage: spark";
    var i: usize = 0;
    while (i < launch_options.len) : (i += 1) {
        const doc = launch_options[i];
        if (doc.hidden or doc.replacement != null) continue;
        const name = doc.flag[0 .. std.mem.findScalar(u8, doc.flag, ' ') orelse doc.flag.len];
        if (i + 1 < launch_options.len and std.mem.eql(u8, launch_options[i + 1].flag, "--no-" ++ name[2..])) {
            out = out ++ " [" ++ doc.flag ++ "|" ++ launch_options[i + 1].flag ++ "]";
            i += 1;
            continue;
        }
        out = out ++ " [" ++ doc.flag ++ "]";
    }
    break :blk out ++ " <command>\n";
};

pub const top_level_flags = [_]TopLevelFlag{
    .{
        .usage = "--context-limit <spec>",
        .description = "Set name=bytes|off; repeatable",
    },
    .{
        .usage = "--add-dir <path>",
        .description = "Add a workspace directory; repeatable",
    },
    .{
        .usage = "--no-additional-dirs",
        .description = "Ignore saved additional directories",
    },
    .{
        .usage = "--tool-placement <spec>",
        .description = "Move a built-in tool: tool=toolbox or tool=direct; repeatable",
    },
    .{
        .usage = "--provider <name>",
        .description = "Override the model provider for an interactive session with a configured provider name",
    },
    .{
        .usage = "--model <id>",
        .description = "Override the model for an interactive session",
    },
    .{
        .usage = "--effort <level>",
        .description = "Override the reasoning effort for an interactive session",
    },
    .{
        .usage = "--profile <name>",
        .description = "Run an interactive session in an agent profile from ~/.spark/agents or the repository's .spark/agents",
    },
    .{
        .usage = "--instances <n>",
        .description = "Start n spark instances in one interactive session, each with its own conversation; Down on an empty composer or Ctrl+X lists them to switch",
    },
    .{
        .usage = "--fast, --no-fast",
        .description = "Turn Fast mode on or off for an interactive session",
    },
    .{
        .usage = "--ultrafast, --no-ultrafast",
        .description = "Request Ultrafast mode on or off for an interactive session",
    },
    .{
        .usage = "-c, --continue",
        .description = "Resume the remembered workspace session",
    },
    .{
        .usage = "-r, --resume [last|<id>]",
        .description = "Pick a saved session, or resume the latest or an exact ID",
    },
    .{
        .usage = convo_option.flag,
        .description = convo_option.description,
    },
    .{
        .usage = "-h, --help",
        .description = "Display this help and exit",
    },
    .{
        .usage = "-v, --version",
        .description = "Print the spark version and exit",
    },
};

pub const top_level_examples = [_]TopLevelExample{
    .{ .command = "spark", .description = "Start a fresh interactive session" },
    .{ .command = "spark \"Fix the failing login test\"", .description = "Start a session with a first prompt" },
    .{ .command = "spark ask \"Explain the changes in this repository\"", .description = "Run one request and exit" },
    .{ .command = "spark session resume last", .description = "Continue the latest session for this workspace" },
    .{ .command = "spark --convo chat.spark", .description = "Open the conversation in chat.spark, or start it there" },
    .{ .command = "spark status --json", .description = "Inspect the current configuration as JSON" },
};

pub const top_level_notes = [_][]const u8{
    "Run `spark <command> --help` for command-specific usage and options.",
    "Run `/help` inside an interactive session for slash commands.",
};

pub const top_level_resources = [_]TopLevelResource{
    .{ .label = "Learn more about spark:", .value = "https://github.com/NZ-Linix/spark", .link = true },
    .{ .label = "Report a problem:", .value = "https://github.com/NZ-Linix/spark/issues", .link = true },
};

pub const top_level_registry = TopLevelRegistry{
    .specs = top_level_specs[0..],
    .description = "Fast, native coding agent for the terminal.",
    .interactive_hint = "spark starts an interactive session by default. Use `spark ask` to run one noninteractive request.",
    .help_groups = top_level_help_groups[0..],
    .flags = top_level_flags[0..],
    .examples = top_level_examples[0..],
    .notes = top_level_notes[0..],
    .resources = top_level_resources[0..],
};

pub fn matchesTopLevel(token: []const u8, kind: TopLevelKind) bool {
    return command_specs.matchesTopLevel(top_level_registry, token, kind);
}

pub fn renderTopLevelHelp(alloc: Allocator, columns: usize, version: []const u8) ![]u8 {
    return command_specs.renderTopLevelHelp(alloc, top_level_registry, columns, version);
}

pub fn renderTopLevelHelpWithStyle(alloc: Allocator, columns: usize, version: []const u8, style: HelpStyle) ![]u8 {
    return command_specs.renderTopLevelHelpWithStyle(alloc, top_level_registry, columns, version, style);
}

pub fn renderTopLevelCommandHelp(alloc: Allocator, kind: TopLevelKind) ![]u8 {
    return command_specs.renderTopLevelCommandHelp(alloc, top_level_registry, kind);
}

pub fn topLevelKindFromToken(token: []const u8) ?TopLevelKind {
    return command_specs.topLevelKindFromToken(top_level_registry, token);
}

pub fn topLevelUsage(kind: TopLevelKind) []const u8 {
    return command_specs.topLevelUsage(top_level_registry, kind);
}

pub const slash_specs = [_]SlashSpec{
    .{ .kind = .help, .command = "/help", .help_entry = "/help", .completion_description = "show available slash commands", .presentation_category = .general, .show_in_welcome = true },
    .{ .kind = .new_session, .command = "/clear", .help_entry = "/clear", .completion_description = "close this session and start a new one", .presentation_category = .general, .show_in_welcome = true },
    .{ .kind = .resume_session, .command = "/resume", .help_entry = "/resume", .completion_description = "resume a saved session", .presentation_category = .session },

    .{ .kind = .rename_session, .command = "/rename", .help_entry = "/rename <title>", .completion_description = "rename the current session", .presentation_category = .session, .has_args = true, .requires_args = true, .accepts_payload = true },
    .{ .kind = .fork_session, .command = "/fork", .aliases = &.{"/rewind"}, .help_entry = "/fork (/rewind)", .completion_description = "rewind to a prompt in a fork and edit it", .presentation_category = .session },
    .{ .kind = .provider, .command = "/provider", .help_entry = "/provider", .completion_description = "manage model connections and ChatGPT, Claude and Antigravity subscription accounts", .presentation_category = .account },
    .{ .kind = .status, .command = "/status", .help_entry = "/status", .completion_description = "show runtime configuration and the session ID", .presentation_category = .general, .show_in_welcome = true },
    .{ .kind = .image, .command = "/image", .aliases = &.{"/img"}, .help_entry = "/image <path> (/img)", .completion_description = "attach an image by path", .presentation_category = .media, .has_args = true, .requires_args = true, .accepts_payload = true },
    .{ .kind = .images, .command = "/images", .help_entry = "/images [clear]", .completion_description = "manage pending image attachments", .presentation_category = .media, .has_args = true, .accepts_payload = true },
    .{ .kind = .model, .command = "/model", .help_entry = "/model <id-or-query>", .completion_description = "choose what model and reasoning effort to use", .presentation_category = .model, .has_args = true, .accepts_payload = true },
    .{ .kind = .effort, .command = "/effort", .help_entry = "/effort [level]", .completion_description = "choose the reasoning effort for the current model", .presentation_category = .model, .has_args = true, .accepts_payload = true },
    .{ .kind = .mcp, .command = "/mcp", .help_entry = "/mcp [list|show|add|remove|login|logout|approve|reject]", .completion_description = "manage MCP servers and their logins", .presentation_category = .extensions, .has_args = true, .accepts_payload = true },
    .{ .kind = .skills, .command = "/skills", .help_entry = "/skills [list|add|install|show|create|remove|path] [name|url|path] ($ opens skill search)", .completion_description = "browse and manage skills", .presentation_category = .extensions, .has_args = true, .accepts_payload = true },
    .{ .kind = .copy, .command = "/copy", .help_entry = "/copy", .completion_description = "copy the last assistant response", .presentation_category = .session },
    .{ .kind = .context, .command = "/context", .help_entry = "/context [tokens|auto]", .completion_description = "show or set this session's context limit", .presentation_category = .session, .has_args = true, .accepts_payload = true },
    .{ .kind = .compact, .command = "/compact", .help_entry = "/compact", .completion_description = "summarize context into a fresh window", .presentation_category = .session },
    .{ .kind = .settings, .command = "/settings", .help_entry = "/settings [startup-scrollback [on|off]]", .completion_description = "browse and update settings", .presentation_category = .appearance, .has_args = true, .accepts_payload = true },
    .{ .kind = .paste, .command = "/paste", .help_entry = "/paste", .completion_description = "attach an image from the clipboard when supported", .presentation_category = .media },
    .{ .kind = .fast, .command = "/fast", .help_entry = "/fast [on|off]", .completion_description = "toggle Fast mode when supported", .presentation_category = .model, .has_args = true, .accepts_payload = true },
    .{ .kind = .ultrafast, .command = "/ultrafast", .help_entry = "/ultrafast [on|off|status]", .completion_description = "request Ultrafast mode when supported", .presentation_category = .model, .has_args = true, .accepts_payload = true },
    .{ .kind = .prompt, .command = "/prompt", .help_entry = "/prompt [<name>|default|dir add PATH|dir remove PATH]", .completion_description = "replace the whole system prompt with one from your prompt folders", .presentation_category = .model, .has_args = true, .accepts_payload = true },
    .{ .kind = .version, .command = "/version", .help_entry = "/version", .completion_description = "show the spark version", .presentation_category = .general },
    .{ .kind = .update, .command = "/update", .aliases = &.{"/upgrade"}, .help_entry = "/update", .completion_description = "update spark from GitHub and restart into this session", .presentation_category = .general },
    .{ .kind = .quit, .command = "/quit", .aliases = &.{"/exit"}, .help_entry = "/quit", .completion_description = "exit the interactive shell", .presentation_category = .general, .show_in_welcome = true },
};

pub const slash_registry = SlashRegistry{ .commands = slash_specs[0..] };

pub fn matchesSlashExact(cmd: []const u8, kind: SlashKind) bool {
    return command_specs.matchesSlashExact(slash_registry, cmd, kind);
}

pub fn isExactSlashCommand(cmd: []const u8) bool {
    return slash_registry.matchExact(cmd) != null;
}

pub fn matchedSlashPrefix(cmd: []const u8, kind: SlashKind) ?[]const u8 {
    return command_specs.matchedSlashPrefix(slash_registry, cmd, kind);
}

pub fn renderSlashHelp(alloc: Allocator) ![]u8 {
    return command_specs.renderSlashHelp(alloc, slash_registry);
}

pub fn firstSlashCompletion(prefix: []const u8) ?[]const u8 {
    return command_specs.firstSlashCompletion(slash_registry, prefix);
}

pub fn slashCompletionCount(prefix: []const u8) usize {
    return command_specs.slashCompletionCount(slash_registry, prefix);
}

pub fn nthSlashCompletion(prefix: []const u8, n: usize) ?[]const u8 {
    return command_specs.nthSlashCompletion(slash_registry, prefix, n);
}

pub fn nthSlashCompletionLabel(prefix: []const u8, n: usize) ?[]const u8 {
    return command_specs.nthSlashCompletionLabel(slash_registry, prefix, n);
}

pub fn nthSlashCompletionDescription(prefix: []const u8, n: usize) ?[]const u8 {
    return command_specs.nthSlashCompletionDescription(slash_registry, prefix, n);
}

pub fn nthSlashCompletionCategory(prefix: []const u8, n: usize) ?SlashPresentationCategory {
    return command_specs.nthSlashCompletionCategory(slash_registry, prefix, n);
}

pub fn slashCompletionHasArgs(command: []const u8) bool {
    return command_specs.slashCompletionHasArgs(slash_registry, command);
}

pub const argCompletionAnchor = command_specs.argCompletionAnchor;

test "spark config help names settings by their current keys" {
    const settings_keys = @import("../core/config/settings_keys.zig");
    const spec = for (top_level_specs) |spec| {
        if (spec.kind == .config) break spec;
    } else unreachable;
    var checked: usize = 0;
    for (spec.details) |line| {
        var words = std.mem.tokenizeAny(u8, line, " ,;:()");
        while (words.next()) |raw| {
            const word = std.mem.trimEnd(u8, raw, ".");
            const dot = std.mem.findScalar(u8, word, '.') orelse continue;
            const key = settings_keys.find(word[0..dot]) orelse continue;
            try std.testing.expectEqualStrings(settings_keys.currentPath(word), word);
            var known = false;
            for (key.children) |child| known = known or std.mem.eql(u8, child, word[dot + 1 ..]);
            try std.testing.expect(known);
            checked += 1;
        }
    }
    try std.testing.expect(checked > 0);
}
