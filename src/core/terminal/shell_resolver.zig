const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const builtin = @import("builtin");
const contracts = @import("contracts.zig");
const command_environment = @import("../execution/command_environment.zig");

const Allocator = std.mem.Allocator;

pub const ResolveError = error{
    MissingLoginShell,
    RelativeShellPath,
    UnsupportedShell,
};

pub const Profile = command_environment.Profile;
pub const Environment = command_environment.Environment;

pub const ShellKind = enum { bash, zsh };

pub fn shellKind(path: []const u8) ?ShellKind {
    const basename = std.Io.Dir.path.basename(path);
    if (std.mem.eql(u8, basename, "bash")) return .bash;
    if (std.mem.eql(u8, basename, "zsh")) return .zsh;
    return null;
}

fn fallbackLoginShell() []const u8 {
    return if (builtin.target.os.tag == .macos) "/bin/zsh" else "/bin/bash";
}

fn supportedLoginShell(configured_login_shell: ?[]const u8) ResolveError![]const u8 {
    const path = configured_login_shell orelse return error.MissingLoginShell;
    if (!std.Io.Dir.path.isAbsolute(path)) return error.RelativeShellPath;
    if (shellKind(path) != null) return path;
    return fallbackLoginShell();
}

pub const Invocation = struct {
    path: []const u8,
    values: [8][]const u8 = @splat(""),
    len: usize = 0,

    pub fn argv(self: *const Invocation) []const []const u8 {
        return self.values[0..self.len];
    }

    fn append(self: *Invocation, value: []const u8) void {
        self.values[self.len] = value;
        self.len += 1;
    }

    pub fn setCommand(self: *Invocation, command: []const u8) void {
        self.append("-c");
        self.append(command);
    }
};

pub fn resolve(
    configured_login_shell: ?[]const u8,
    shell: contracts.ShellSpec,
) ResolveError!Invocation {
    const Selection = struct {
        path: []const u8,
        clean_start: bool,
    };
    const selection: Selection = switch (shell) {
        .user_login => .{
            .path = try supportedLoginShell(configured_login_shell),
            .clean_start = false,
        },
        .executable => |value| .{
            .path = value.path,
            .clean_start = value.clean_start,
        },
    };
    if (!std.Io.Dir.path.isAbsolute(selection.path)) {
        return error.RelativeShellPath;
    }

    const kind = shellKind(selection.path) orelse return error.UnsupportedShell;

    var result = Invocation{ .path = selection.path };
    result.append(selection.path);
    switch (kind) {
        .bash => {
            if (selection.clean_start) {
                result.append("--noprofile");
                result.append("--norc");
            } else {
                result.append("--login");
            }
            result.append("-i");
        },
        .zsh => {
            if (selection.clean_start) {
                result.append("-f");
            } else {
                result.append("-l");
            }
            result.append("-i");
        },
    }
    return result;
}

pub fn configuredLoginShellInto(buffer: []u8) ?[]const u8 {
    if (comptime !builtin.link_libc or builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
        return null;
    }
    var entry: std.c.passwd = undefined;
    var scratch: [4096]u8 = undefined;
    var found: ?*std.c.passwd = null;
    if (std.c.getpwuid_r(
        std.c.getuid(),
        &entry,
        &scratch,
        scratch.len,
        &found,
    ) != 0) return null;
    const record = found orelse return null;
    const shell_ptr = record.shell orelse return null;
    const shell = std.mem.span(shell_ptr);
    if (shell.len == 0 or shell.len > buffer.len) return null;
    @memcpy(buffer[0..shell.len], shell);
    return buffer[0..shell.len];
}

pub fn environment(
    alloc: Allocator,
    configured_login_shell: ?[]const u8,
    profile: ?Profile,
) (ResolveError || Allocator.Error)!Environment {
    const selected = profile orelse .user;
    const path = try supportedLoginShell(configured_login_shell);
    _ = try resolve(null, switch (selected) {
        .clean => .{ .executable = .{ .path = path, .clean_start = true } },
        .user => .{ .executable = .{ .path = path } },
    });
    return switch (selected) {
        .clean => .{ .clean = try alloc.dupe(u8, path) },
        .user => .{ .user = try alloc.dupe(u8, path) },
    };
}

pub fn environmentForShellSpec(
    alloc: Allocator,
    configured_login_shell: ?[]const u8,
    shell: contracts.ShellSpec,
) (ResolveError || Allocator.Error)!Environment {
    const invocation = try resolve(configured_login_shell, shell);
    return switch (shell) {
        .user_login => .{ .user = try alloc.dupe(u8, invocation.path) },
        .executable => |value| if (value.clean_start)
            .{ .clean = try alloc.dupe(u8, invocation.path) }
        else
            .{ .user = try alloc.dupe(u8, invocation.path) },
    };
}

pub fn profileShell(
    alloc: Allocator,
    configured_login_shell: ?[]const u8,
    profile: Profile,
) (ResolveError || Allocator.Error)!contracts.ShellSpec {
    return switch (profile) {
        .clean => blk: {
            const path = try supportedLoginShell(configured_login_shell);
            _ = try resolve(null, .{ .executable = .{ .path = path, .clean_start = true } });
            break :blk .{ .executable = .{
                .path = try alloc.dupe(u8, path),
                .clean_start = true,
            } };
        },
        .user => blk: {
            const configured = configured_login_shell orelse
                break :blk .user_login;
            const path = try supportedLoginShell(configured);
            if (std.mem.eql(u8, path, configured)) break :blk .user_login;
            break :blk .{ .executable = .{
                .path = try alloc.dupe(u8, path),
            } };
        },
    };
}

const captured_zsh_user_prelude = "\\builtin trap - TERM; ";

/// A startup file can define a function named `builtin`, and zsh and bash run
/// a function before a builtin of the same name, so every `\builtin` line spark
/// adds would run the user's function instead. spark removes such a function
/// before its own lines. The zsh test runs no command when there is no such
/// function, so it can't fail under `errexit`; bash's `unset -f` succeeds
/// either way.
const zsh_unshadow_builtin = "(( ${+functions[builtin]} )) && \\unfunction builtin; ";
const bash_unshadow_builtin = "\\unset -f builtin; ";

/// zsh's `equals` option expands an unquoted word that starts with `=`, such
/// as a `======` separator or the `==` in `[ a == b ]`, to the path of the
/// command it names, and a word that names no command aborts the rest of the
/// command line. Commands are written for POSIX shells, so every zsh launch
/// turns the option off right before the command, after startup files or a
/// snapshot replay have run.
const zsh_command_prelude = zsh_unshadow_builtin ++ "\\builtin unsetopt equals; ";

pub fn capturedInvocation(
    alloc: Allocator,
    environment_value: Environment,
    command: []const u8,
) (ResolveError || Allocator.Error)!Invocation {
    switch (environment_value) {
        .legacy, .workspace_clean => return error.UnsupportedShell,
        .clean => |path| {
            var invocation = try resolve(null, .{ .executable = .{
                .path = path,
                .clean_start = true,
            } });
            removeInteractiveFlag(&invocation);
            invocation.setCommand(if (shellKind(path) == .zsh)
                try std.mem.concat(alloc, u8, &.{ zsh_command_prelude, command })
            else
                command);
            return invocation;
        },
        .user => |path| {
            var invocation = try resolve(path, .user_login);
            if (std.mem.eql(u8, std.Io.Dir.path.basename(path), "bash")) {
                removeInteractiveFlag(&invocation);
                invocation.append("-O");
                invocation.append("expand_aliases");
            }
            const effective_command = if (shellKind(path) == .zsh)
                try std.mem.concat(alloc, u8, &.{ zsh_command_prelude, captured_zsh_user_prelude, command })
            else
                command;
            invocation.setCommand(effective_command);
            return invocation;
        },
    }
}

/// Stderr marker, followed by a nonce, that a snapshot bootstrap writes with
/// exit status 125 when the replay stopped before the command could start.
pub const snapshot_replay_failure_prefix = "spark-shell-snapshot-replay-failed:";

/// Builds the clean-shell argv for a snapshot run. The shell sources the
/// replay and the command from stdin, so no snapshot text or command appears
/// in argv. `failure_marker` reaches stderr, with exit status 125, only when
/// the replay stopped before the command started.
///
/// The replay runs with stderr saved on fd 9 and pointed at /dev/null, so
/// its errors never reach the command's output. The command gets stderr back
/// through its own redirection (`snapshotScript`), and the bootstrap restores
/// it once the replay returns, for exit traps and the failure marker.
pub fn snapshotInvocation(
    alloc: Allocator,
    shell_path: []const u8,
    failure_marker: []const u8,
) (ResolveError || Allocator.Error)!Invocation {
    const kind = shellKind(shell_path) orelse return error.UnsupportedShell;
    var invocation = Invocation{ .path = shell_path };
    invocation.append(shell_path);
    switch (kind) {
        .zsh => invocation.append("-f"),
        .bash => {
            invocation.append("--noprofile");
            invocation.append("--norc");
            invocation.append("-O");
            invocation.append("expand_aliases");
        },
    }
    // bash's `builtin exec` drops its redirections when it returns, and bash
    // 3.2 hangs on a `command exec`, so bash uses plain `exec`. Nothing is
    // replayed before the first one, and the second runs after the command, so
    // removing a replayed function named `exec` there changes nothing it uses.
    const park_stderr: []const u8, const restore_stderr: []const u8 = switch (kind) {
        .zsh => .{ "\\builtin exec 9>&2 2>/dev/null; ", "\\builtin exec 2>&9 9>&-; " },
        .bash => .{ "exec 9>&2 2>/dev/null; ", "\\builtin unset -f exec; exec 2>&9 9>&-; " },
    };
    // bash 3.2, macOS's /bin/bash, sources a pipe only as far as the bytes it
    // holds at that moment, about 64 KB, so a larger replay would lose its
    // end. That bash reads the whole script with a command substitution and
    // evaluates it. bash 4 and later read a pipe to its end.
    const load_replay: []const u8 = switch (kind) {
        .zsh => "\\builtin source /dev/fd/0; ",
        .bash => "if (( BASH_VERSINFO[0] < 4 )); then \\builtin eval -- \"$(< /dev/fd/0)\"; " ++
            "else \\builtin source /dev/fd/0; fi; ",
    };
    var bootstrap: std.ArrayList(u8) = .empty;
    errdefer bootstrap.deinit(alloc);
    try bootstrap.appendSlice(alloc, park_stderr);
    try bootstrap.appendSlice(alloc, load_replay);
    try bootstrap.appendSlice(alloc, "__spark_snapshot_status=$?; ");
    try bootstrap.appendSlice(alloc, restore_stderr);
    try bootstrap.appendSlice(
        alloc,
        "if [[ -z ${__spark_snapshot_restored-} ]]; then \\builtin printf '%s' ",
    );
    try appendShellWord(&bootstrap, alloc, failure_marker);
    // Re-raise the common termination signals so the supervisor reports a
    // signal, as it does when the shell runs the command directly.
    try bootstrap.appendSlice(
        alloc,
        " >&2; \\builtin exit 125; fi; " ++
            "case $__spark_snapshot_status in 129|130|137|143) " ++
            "\\builtin kill -$((__spark_snapshot_status - 128)) $$;; esac; " ++
            "\\builtin exit $__spark_snapshot_status",
    );
    invocation.setCommand(try bootstrap.toOwnedSlice(alloc));
    return invocation;
}

/// Builds the stdin script for a snapshot run: the replay, the restored flag
/// the bootstrap checks, and the command. The command is single-quoted so it
/// is parsed only when `eval` runs, after the replayed aliases exist, and it
/// runs with stdin from /dev/null so it cannot read the rest of the script.
/// Its stderr is the one `snapshotInvocation` saved on fd 9, which it does
/// not inherit. A redirection, unlike an `exec`, cannot be replaced by a
/// replayed function or alias.
pub fn snapshotScript(
    alloc: Allocator,
    kind: ShellKind,
    replay: []const u8,
    command: []const u8,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    try output.appendSlice(alloc, replay);
    if (replay.len != 0 and replay[replay.len - 1] != '\n') try output.append(alloc, '\n');
    try output.appendSlice(alloc, "__spark_snapshot_restored=1\n");
    if (kind == .zsh) try output.appendSlice(alloc, zsh_command_prelude);
    try output.appendSlice(alloc, "\\builtin eval -- ");
    try appendShellWord(&output, alloc, command);
    try output.appendSlice(alloc, " </dev/null 2>&9 9>&-\n");
    return output.toOwnedSlice(alloc);
}

/// Payload section markers written by `snapshotCaptureScript`. Each marker is
/// followed by `:` and the capture nonce.
pub const snapshot_marker_prefix = "FXSNAP:";

// The replay starts by removing every alias. zsh starts with default aliases
// such as `run-help`, and a startup file that replaces one with a function,
// as Debian's and Ubuntu's global zshrc does, would otherwise make the
// replayed `run-help () {` a parse error that stops the whole replay. The
// captured `alias -L` lines then restore exactly the user's aliases.
//
// Completion functions start with `_`, a setup often has a thousand of them,
// and a command never uses them, so the replay leaves them out. zsh autoloads
// each one from a file of the same name, as compinit does for every
// `#compdef` file, so a `_` function is left out only when
// `functions_source` names no file or a file with the function's name. A `_`
// helper that a startup file defines, such as the one a `pnpm` wrapper
// calls, is replayed. zsh before 5.4 has no `functions_source`, so it leaves
// out every `_` function.
const zsh_capture_script =
    \\{
    \\\builtin zmodload zsh/parameter 2>/dev/null
    \\\builtin printf 'FXSNAP:@NONCE@:ENV\0'
    \\/usr/bin/env -0
    \\\builtin printf 'FXSNAP:@NONCE@:NAMES\0'
    \\\builtin printf '%s\0' ${(k)aliases} ${(k)galiases} ${(k)saliases} ${(k)functions}
    \\\builtin printf 'FXSNAP:@NONCE@:REPLAY\0'
    \\\builtin print -r -- '\builtin unalias -a; \builtin unalias -as'
    \\\builtin typeset -p fpath
    \\for __spark_snapshot_name in ${(ko)functions}; do
    \\  case $__spark_snapshot_name in (prompt_*|__spark_snapshot_*) continue;; esac
    \\  if [[ $__spark_snapshot_name == _* ]]; then
    \\    __spark_snapshot_file=${functions_source[$__spark_snapshot_name]-}
    \\    if [[ -z $__spark_snapshot_file || ${__spark_snapshot_file:t} == "$__spark_snapshot_name" ]]; then continue; fi
    \\  fi
    \\  \builtin functions -- $__spark_snapshot_name
    \\done
    \\\builtin alias -L
    \\\builtin alias -sL
    \\for __spark_snapshot_name in extendedglob globdots nullglob nomatch kshglob shglob globstarshort bareglobqual caseglob numericglobsort rcexpandparam shwordsplit ksharrays magicequalsubst braceccl rcquotes shortloops cshnullglob globsubst; do
    \\  if [[ -o $__spark_snapshot_name ]]; then
    \\    \builtin print -r -- "\\builtin setopt $__spark_snapshot_name"
    \\  else
    \\    \builtin print -r -- "\\builtin unsetopt $__spark_snapshot_name"
    \\  fi
    \\done
    \\\builtin printf '\0FXSNAP:@NONCE@:END\0'
    \\} 2>/dev/null
;

// bash has no autoload. bash-completion and git's completion script define
// their `_` functions in files whose path contains `completion`, so the
// replay leaves out a `_` function only when `declare -F`, with `extdebug`
// on, reports such a file; the name alone does not decide. Under `extdebug`
// a DEBUG trap that fails skips the next command, so the trap is cleared
// first. bash parses a function's patterns when it reads the definition, so
// the replay sets options such as `extglob` before the functions that use
// them.
const bash_capture_script =
    \\{
    \\\unset -f builtin
    \\\builtin printf 'FXSNAP:@NONCE@:ENV\0'
    \\/usr/bin/env -0
    \\\builtin printf 'FXSNAP:@NONCE@:NAMES\0'
    \\\builtin printf '%s\0' $(\builtin compgen -a) $(\builtin compgen -A function)
    \\\builtin printf 'FXSNAP:@NONCE@:REPLAY\0'
    \\for __spark_snapshot_name in extglob nullglob dotglob globstar nocaseglob failglob nocasematch globasciiranges; do
    \\  \builtin shopt -p "$__spark_snapshot_name" 2>/dev/null
    \\done
    \\\builtin trap - DEBUG
    \\\builtin shopt -s extdebug
    \\__spark_snapshot_sources=$(\builtin declare -F $(\builtin compgen -A function))
    \\\builtin shopt -u extdebug
    \\while \builtin read -r __spark_snapshot_name __spark_snapshot_line __spark_snapshot_file; do
    \\  case $__spark_snapshot_name in __spark_snapshot_*|'') continue;; esac
    \\  case $__spark_snapshot_name in _*) case $__spark_snapshot_file in *completion*) continue;; esac;; esac
    \\  \builtin declare -f -- "$__spark_snapshot_name"
    \\done <<< "$__spark_snapshot_sources"
    \\\builtin alias -p
    \\\builtin printf '\0FXSNAP:@NONCE@:END\0'
    \\} 2>/dev/null
;

/// Builds the script a login shell runs once to capture its state as a
/// NUL-delimited payload: exported environment, alias and function names, and
/// a replay of functions, aliases, and selected options. Every section marker
/// carries `nonce`, so output printed by the user's startup files cannot be
/// mistaken for the payload. `nonce` must be ASCII hex.
pub fn snapshotCaptureScript(
    alloc: Allocator,
    kind: ShellKind,
    nonce: []const u8,
) Allocator.Error![]u8 {
    for (nonce) |byte| std.debug.assert(std.ascii.isHex(byte));
    const template = switch (kind) {
        .zsh => zsh_capture_script,
        .bash => bash_capture_script,
    };
    return std.mem.replaceOwned(u8, alloc, template, "@NONCE@", nonce);
}

pub fn formatInvocationCommand(
    alloc: Allocator,
    invocation: *const Invocation,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    for (invocation.argv(), 0..) |word, index| {
        if (index != 0) try output.append(alloc, ' ');
        try appendShellWord(&output, alloc, word);
    }
    return output.toOwnedSlice(alloc);
}

fn removeInteractiveFlag(invocation: *Invocation) void {
    std.debug.assert(invocation.len > 0);
    std.debug.assert(std.mem.eql(u8, invocation.values[invocation.len - 1], "-i"));
    invocation.len -= 1;
}

pub fn buildBootstrap(
    alloc: Allocator,
    kind: ShellKind,
    executable: []const u8,
    control_path: []const u8,
    nonce: []const u8,
    command_path: ?[]const u8,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);

    try output.appendSlice(alloc, "set +x; export AI_AGENT=spark; ");
    if (command_path) |path| {
        try output.appendSlice(alloc, "spark_terminal_command=$(< ");
        try appendShellWord(&output, alloc, path);
        try output.appendSlice(alloc, ") || exit 125; ");
    }
    try appendMarker(&output, alloc, executable, control_path, nonce, "shell-ready");
    if (command_path) |_| {
        try output.appendSlice(alloc, " || exit 125; ");
        try appendMarker(
            &output,
            alloc,
            executable,
            control_path,
            nonce,
            "command-started",
        );
        try output.appendSlice(alloc, " || exit 125; ");
        try output.appendSlice(alloc, switch (kind) {
            .zsh => zsh_command_prelude,
            .bash => bash_unshadow_builtin,
        });
        try output.appendSlice(
            alloc,
            "builtin eval -- \"$spark_terminal_command\"; " ++
                "spark_terminal_status=$?; exit \"$spark_terminal_status\"\n",
        );
    } else {
        try output.appendSlice(alloc, " || exit 125\n");
    }
    return output.toOwnedSlice(alloc);
}

pub fn buildSourceCommand(
    alloc: Allocator,
    bootstrap_path: []const u8,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    try output.appendSlice(alloc, ". ");
    try appendShellWord(&output, alloc, bootstrap_path);
    try output.append(alloc, '\n');
    return output.toOwnedSlice(alloc);
}

fn appendMarker(
    output: *std.ArrayList(u8),
    alloc: Allocator,
    executable: []const u8,
    control_path: []const u8,
    nonce: []const u8,
    event: []const u8,
) Allocator.Error!void {
    try appendShellWord(output, alloc, executable);
    inline for (.{
        "--spark-internal-terminal-control",
        control_path,
        nonce,
        event,
    }) |word| {
        try output.append(alloc, ' ');
        try appendShellWord(output, alloc, word);
    }
}

fn appendShellWord(
    output: *std.ArrayList(u8),
    alloc: Allocator,
    word: []const u8,
) Allocator.Error!void {
    try output.append(alloc, '\'');
    for (word) |byte| {
        if (byte == '\'') {
            try output.appendSlice(alloc, "'\"'\"'");
        } else {
            try output.append(alloc, byte);
        }
    }
    try output.append(alloc, '\'');
}

test "resolver builds Bash and zsh interactive argv" {
    const bash = try resolve("/bin/bash", .user_login);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "/bin/bash", "--login", "-i" },
        bash.argv(),
    );

    const zsh = try resolve(
        null,
        .{ .executable = .{ .path = "/bin/zsh" } },
    );
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "/bin/zsh", "-l", "-i" },
        zsh.argv(),
    );
}

fn checkBootstrapAllocationFailures(alloc: Allocator) !void {
    const bootstrap = try buildBootstrap(
        alloc,
        .zsh,
        "/tmp/spark",
        "/tmp/control",
        "nonce",
        "/tmp/command",
    );
    defer alloc.free(bootstrap);
    const source = try buildSourceCommand(alloc, "/tmp/bootstrap");
    defer alloc.free(source);
}
