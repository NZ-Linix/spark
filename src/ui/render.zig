const std = @import("std");
const build_options = @import("build_options");
const io_mod = @import("../core/shared/io.zig");
const host = @import("../core/hosts/host.zig");
const display_width = @import("../core/shared/display_width.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const types = @import("../core/shared/types.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const assistant_presentation = @import("../core/agent/assistant_presentation.zig");
const theme_detection = @import("terminal/theme_detection.zig");
const theme_protocol = @import("terminal/theme_protocol.zig");
const shared_theme = @import("../core/shared/theme.zig");
const visual_layout = @import("input/visual_layout.zig");
const update_target = @import("../core/upgrade/update_target.zig");

pub const TerminalRgb = user_message_card.Rgb;
pub const reset_style = "\x1b[0m";
pub const bold_style = "\x1b[1m";
pub const ask_activity_label = "⏺ Asking";

const user_message_card = @import("assistant/user_message_card.zig");

pub const welcome_message_reserved_rows: u16 = 11;

pub var is_light: bool = false;
/// Whether the transcript shows the model's reasoning under each "Thought
/// for" line. Ctrl+O flips it; off by default.
pub var expand_thinking: bool = false;
pub var divider_style: []const u8 = shared_theme.spark_dark.divider_style;
pub var hint_style: []const u8 = shared_theme.spark_dark.hint_style;
pub var statusline_style: []const u8 = shared_theme.spark_dark.statusline_style;
pub var tag_style: []const u8 = shared_theme.spark_dark.tag_style;
pub var subtitle_style: []const u8 = shared_theme.spark_dark.subtitle_style;
pub var system_notice_label_style: []const u8 = shared_theme.spark_dark.system_notice_label_style;
pub var system_notice_text_style: []const u8 = shared_theme.spark_dark.system_notice_text_style;
pub var dim_style: []const u8 = shared_theme.spark_dark.dim_style;
pub var warning_style: []const u8 = shared_theme.spark_dark.warning_style;
pub var green_style: []const u8 = shared_theme.spark_dark.green_style;
pub var red_style: []const u8 = shared_theme.spark_dark.red_style;
/// A failed tool call's ✗ and the words that say it failed: the red of a
/// named theme that sets its own, and dim under spark's themes, where a failure
/// the model works past stays quiet.
pub var failure_style: []const u8 = shared_theme.spark_dark.dim_style;
pub var diff_added_style: []const u8 = shared_theme.spark_dark.diff_added_style;
pub var diff_removed_style: []const u8 = shared_theme.spark_dark.diff_removed_style;
pub var diff_added_marker_style: []const u8 = "";
pub var diff_removed_marker_style: []const u8 = "";
pub var approval_button_active_style: []const u8 = shared_theme.spark_dark.approval_button_active_style;
pub var approval_button_inactive_style: []const u8 = shared_theme.spark_dark.approval_button_inactive_style;
pub var selected_completion_style: []const u8 = shared_theme.spark_dark.selected_completion_style;
// Statusbar permissions "auto": a step brighter than the statusline gray.
pub var permission_auto_style: []const u8 = shared_theme.spark_dark.permission_auto_style;
var active_terminal_background: ?TerminalRgb = null;

var truecolor_enabled: bool = true;

pub fn setTruecolorSupport(enabled: bool) void {
    truecolor_enabled = enabled;
}

// A configured light|dark pin (SPARK_THEME or the settings "theme" key) locks the
// variant. Custom themes keep the live monitor so terminal mode flips
// re-resolve the theme pair without a restart.
pub fn themeInputLocked() bool {
    return explicitThemeOverride() != null or shared_theme.variantPinned();
}

pub fn truecolorIsEnabled() bool {
    return truecolor_enabled;
}

/// The failure style under `theme`: its own red when it is a named theme
/// that sets one, and its dim otherwise, since spark's themes have no red.
fn failureStyle(theme: shared_theme.Theme, named: bool) []const u8 {
    const base = shared_theme.builtin(theme.light);
    if (named and !std.mem.eql(u8, theme.red_style, base.red_style)) return theme.red_style;
    return theme.dim_style;
}

test "a failure is dim under spark's themes and red under a named theme that sets red" {
    try std.testing.expectEqualStrings(shared_theme.spark_dark.dim_style, failureStyle(shared_theme.spark_dark, false));
    try std.testing.expectEqualStrings(shared_theme.spark_light.dim_style, failureStyle(shared_theme.spark_light, false));
    // A named theme that keeps spark's red, which is not red, stays dim too.
    try std.testing.expectEqualStrings(shared_theme.spark_dark.dim_style, failureStyle(shared_theme.spark_dark, true));
    var named = shared_theme.spark_dark;
    named.red_style = "\x1b[38;2;227;70;113m";
    try std.testing.expectEqualStrings("\x1b[38;2;227;70;113m", failureStyle(named, true));
    // Without a name, the theme is spark's own.
    try std.testing.expectEqualStrings(named.dim_style, failureStyle(named, false));
}

pub fn initTheme(light: bool, terminal_bg: ?TerminalRgb) void {
    applyTheme(shared_theme.builtin(light), terminal_bg);
}

pub fn applyTheme(theme: shared_theme.Theme, terminal_bg: ?TerminalRgb) void {
    shared_theme.activate(theme);
    is_light = theme.light;
    active_terminal_background = terminal_bg;
    assistant_presentation.applyTheme(theme);
    divider_style = theme.divider_style;
    hint_style = theme.hint_style;
    statusline_style = theme.statusline_style;
    tag_style = theme.tag_style;
    subtitle_style = theme.subtitle_style;
    system_notice_label_style = theme.system_notice_label_style;
    system_notice_text_style = theme.system_notice_text_style;
    dim_style = theme.dim_style;
    warning_style = theme.warning_style;
    green_style = theme.green_style;
    red_style = theme.red_style;
    failure_style = failureStyle(theme, shared_theme.sourceName() != null);
    diff_added_style = theme.diff_added_style;
    diff_removed_style = theme.diff_removed_style;
    approval_button_active_style = theme.approval_button_active_style;
    approval_button_inactive_style = theme.approval_button_inactive_style;
    selected_completion_style = theme.selected_completion_style;
    permission_auto_style = theme.permission_auto_style;

    // Terminal-following defaults keep diff markers monochrome. An explicit
    // light/dark pin or named theme enables its green/red marker colors.
    const theme_selected = shared_theme.variantPinned() or shared_theme.sourceName() != null;
    if (!theme_selected) {
        diff_added_marker_style = "";
        diff_removed_marker_style = "";
    } else if (truecolor_enabled) {
        diff_added_marker_style = theme.diff_added_marker_truecolor;
        diff_removed_marker_style = theme.diff_removed_marker_truecolor;
    } else {
        diff_added_marker_style = theme.diff_added_marker_fallback;
        diff_removed_marker_style = theme.diff_removed_marker_fallback;
    }

    user_message_card.applyTheme(theme, terminal_bg);
}

pub fn themeNeedsUpdate(light: bool, terminal_bg: ?TerminalRgb) bool {
    if (light != is_light) return true;
    const background = terminal_bg orelse return false;
    const current = active_terminal_background orelse return true;
    return current.r != background.r or current.g != background.g or current.b != background.b;
}

// Explicit theme overrides skip OSC 11, leaving `rgb` null for fallback shading.
pub const explicitThemeOverride = theme_detection.explicitThemeOverride;
pub const explicitThemeName = theme_detection.explicitThemeName;
pub const detectTheme = theme_detection.detectTheme;
pub const parseOsc11Response = theme_protocol.parseOsc11Response;
pub const truecolorSupportedForValues = theme_protocol.truecolorSupportedForValues;

pub const InputLineView = struct {
    line: []const u8,
    cursor_col: u16,
};

pub const MultilineInfo = struct {
    total_lines: u16,
    cursor_line: u16,
};

pub fn countMultilineInfo(input: []const u8, cursor: usize, width: u16) MultilineInfo {
    const summary = visual_layout.summarize(.{ .input = input, .cursor = cursor, .terminal_cols = width }, null);
    return .{
        .total_lines = @intCast(@min(summary.total_rows, std.math.maxInt(u16))),
        .cursor_line = @intCast(@min(summary.cursor.row_index, std.math.maxInt(u16))),
    };
}

pub fn buildInputLineForRow(input: []const u8, cursor: usize, line_index: usize, total_lines: usize, width: u16, out: []u8) InputLineView {
    if (width == 0 or out.len == 0) return .{ .line = "", .cursor_col = 1 };

    const source = visual_layout.Source{ .input = input, .cursor = cursor, .terminal_cols = width };
    const summary = visual_layout.summarize(source, null);
    const visible_rows = @max(total_lines, 1);
    const window = visual_layout.visibleWindow(summary.cursor.row_index, summary.total_rows, visible_rows);
    const actual_row = window.first_row + line_index;
    const line = copyVisualRowToBuffer(source, actual_row, out);
    return .{
        .line = line,
        .cursor_col = if (summary.cursor.row_index == actual_row) visual_layout.terminalColumn(summary.cursor, width) else 0,
    };
}

const build_channel = update_target.Channel.parse(build_options.update_channel) orelse .stable;
const welcome_build_label_bytes: usize = 96;
const dev_revision_bytes: usize = 7;

/// Dev builds ship on every merged PR, so the version alone cannot identify the
/// binary: the header carries the commit and a brighter `[dev]` tag.
fn writeBuildLabel(
    out: []u8,
    channel: update_target.Channel,
    version_text: []const u8,
    revision: []const u8,
) ![]const u8 {
    if (channel != .dev) return std.mem.print(out, "v{s}", .{version_text});
    if (revision.len < dev_revision_bytes or std.mem.eql(u8, revision, "unknown")) {
        return std.mem.print(out, "v{s} {s}[dev]{s}", .{ version_text, hint_style, dim_style });
    }
    return std.mem.print(out, "v{s}-{s} {s}[dev]{s}", .{
        version_text,
        revision[0..dev_revision_bytes],
        hint_style,
        dim_style,
    });
}

pub fn welcomeMessage(alloc: std.mem.Allocator) ![]u8 {
    var label_buf: [welcome_build_label_bytes]u8 = undefined;
    const build_label = try writeBuildLabel(
        &label_buf,
        build_channel,
        build_options.app_version,
        build_options.git_commit,
    );
    return alloc.print(
        "{s}-=✦{s}{s} {s}" ++ reset_style ++ "\n\n",
        .{ subtitle_style, reset_style, dim_style, build_label },
    );
}

pub const StatuslineItems = struct {
    model_name: ?[]const u8 = null,
    usage: ?types.SessionUsageCounters = null,
    ultrafast_indicator_active: bool = false,
    workspace_label: []const u8 = "",
    git_branch: ?[]const u8 = null,
    context_used: u64 = 0,
    context_total: ?u32 = null,
    session_title: ?[]const u8 = null,
};

/// Cell budget for the session title segment. The title is capped at 8 words
/// upstream, so this only bounds pathological single-word titles.
const max_session_title_cells: usize = 32;

/// A short model label for tables with limited column space. May use `out`.
pub fn compactModelLabel(model: []const u8, out: []u8) []const u8 {
    var start: usize = 0;
    for (model, 0..) |byte, i| {
        if (byte == '/') start = i + 1;
    }
    const bare = model[start..];

    const claude_prefix = "claude-";
    if (!std.mem.startsWith(u8, bare, claude_prefix)) return bare;
    const claude_name = bare[claude_prefix.len..];

    inline for (&.{
        .{ "opus-", "opus " },
        .{ "sonnet-", "sonnet " },
        .{ "haiku-", "haiku " },
    }) |mapping| {
        const prefix = mapping[0];
        const label = mapping[1];
        if (std.mem.startsWith(u8, claude_name, prefix)) {
            return std.mem.print(out, "{s}{s}", .{ label, claude_name[prefix.len..] }) catch bare;
        }
    }

    return claude_name;
}

fn statusModelLabel(label: []const u8, out: []u8) []const u8 {
    if (text_utils.isTerminalSafe(label)) return label;
    return std.mem.print(out, "{f}", .{text_utils.terminalSafe(label)}) catch "";
}

/// spark always runs in full access, so the status line names no mode.
fn permissionModeStatusLabel(mode: types.PermissionMode, out: []u8) []const u8 {
    _ = mode;
    _ = out;
    return "";
}

fn appendStatusSegment(out: []u8, end: *usize, segment: []const u8) void {
    if (segment.len == 0) return;
    const sep = " · ";
    const sep_len = if (end.* > 0) sep.len else 0;
    if (end.* + sep_len + segment.len > out.len) return;

    if (sep_len > 0) {
        @memcpy(out[end.* .. end.* + sep.len], sep);
        end.* += sep.len;
    }
    @memcpy(out[end.* .. end.* + segment.len], segment);
    end.* += segment.len;
}

const statusline_separator = " · ";

fn leadingPermissionModeFits(
    limit: usize,
    permission_label: []const u8,
    model_label: []const u8,
) bool {
    if (limit == 0) return false;
    return display_width.visibleWidthIgnoringAnsi(permission_label) +
        display_width.visibleWidth(statusline_separator) +
        display_width.visibleWidth(model_label) <= limit;
}

const ClippedSegment = struct {
    bytes: []const u8,
    marker_before: bool = false,
    marker_after: bool = false,
};

fn clippedWorkspaceSuffix(encoded: []const u8, max_width: usize) ClippedSegment {
    if (display_width.visibleWidth(encoded) <= max_width) return .{ .bytes = encoded };
    if (max_width <= 1) return .{ .bytes = "", .marker_before = max_width == 1 };
    return .{
        .bytes = text_utils.suffixTerminalSafeByWidth(encoded, max_width - 1),
        .marker_before = true,
    };
}

fn clippedBranchPrefix(encoded: []const u8, max_width: usize) ClippedSegment {
    if (display_width.visibleWidth(encoded) <= max_width) return .{ .bytes = encoded };
    if (max_width <= 1) return .{ .bytes = "", .marker_after = max_width == 1 };
    return .{
        .bytes = text_utils.prefixTerminalSafeByWidth(encoded, max_width - 1),
        .marker_after = true,
    };
}

fn appendIdentityBytes(out: []u8, end: *usize, bytes: []const u8) bool {
    if (end.* + bytes.len > out.len) return false;
    @memcpy(out[end.* .. end.* + bytes.len], bytes);
    end.* += bytes.len;
    return true;
}

fn appendClippedIdentityPart(
    out: []u8,
    end: *usize,
    clipped: ClippedSegment,
) bool {
    if (clipped.marker_before and !appendIdentityBytes(out, end, "…")) return false;
    if (!appendIdentityBytes(out, end, clipped.bytes)) return false;
    if (clipped.marker_after and !appendIdentityBytes(out, end, "…")) return false;
    return true;
}

fn composeWorkspaceIdentity(
    statusline: StatuslineItems,
    max_width: usize,
    out: []u8,
) ?[]const u8 {
    if (statusline.workspace_label.len == 0 or max_width == 0) return null;

    var width_budget = @min(max_width, out.len);
    while (width_budget > 0) : (width_budget -= 1) {
        var end: usize = 0;
        if (statusline.git_branch) |branch| {
            if (branch.len > 0) {
                // Below seven cells, showing fragments of both values is less
                // useful than retaining the working-directory tail alone.
                if (width_budget >= 7) {
                    const branch_width = display_width.visibleWidth(branch);
                    const max_branch_width = width_budget - 4;
                    const branch_budget = @min(
                        branch_width,
                        @min(max_branch_width, @max(@as(usize, 4), width_budget / 2)),
                    );
                    const path_budget = width_budget - 3 - branch_budget;
                    const path = clippedWorkspaceSuffix(statusline.workspace_label, path_budget);
                    const branch_label = clippedBranchPrefix(branch, branch_budget);
                    if (appendClippedIdentityPart(out, &end, path) and
                        appendIdentityBytes(out, &end, " (") and
                        appendClippedIdentityPart(out, &end, branch_label) and
                        appendIdentityBytes(out, &end, ")"))
                    {
                        return out[0..end];
                    }
                    continue;
                }
            }
        }

        const path = clippedWorkspaceSuffix(statusline.workspace_label, width_budget);
        if (appendClippedIdentityPart(out, &end, path)) return out[0..end];
    }
    return null;
}

fn appendWorkspaceIdentity(
    out: []u8,
    end: *usize,
    status_limit: usize,
    statusline: StatuslineItems,
) void {
    if (statusline.workspace_label.len == 0) return;
    const used_width = display_width.visibleWidthIgnoringAnsi(out[0..end.*]);
    const separator_width = if (end.* > 0)
        display_width.visibleWidth(statusline_separator)
    else
        0;
    if (used_width + separator_width >= status_limit) return;

    const separator_bytes = if (end.* > 0) statusline_separator.len else 0;
    if (end.* + separator_bytes >= out.len) return;
    const available_width = status_limit - used_width - separator_width;
    const available_bytes = out.len - end.* - separator_bytes;
    var identity_buf: [512]u8 = undefined;
    const identity = composeWorkspaceIdentity(
        statusline,
        available_width,
        identity_buf[0..@min(identity_buf.len, available_bytes)],
    ) orelse return;
    appendStatusSegment(out, end, identity);
}

fn appendSessionStatusSegments(
    out: []u8,
    end: *usize,
    status_limit: usize,
    model_label: []const u8,
    effort: types.ReasoningEffort,
    model_supports_effort: bool,
    fast_indicator_active: bool,
    statusline: StatuslineItems,
) void {
    appendStatusSegment(out, end, model_label);
    if (model_supports_effort and !effort.isDefault()) {
        appendStatusSegment(out, end, effort.displayLabel());
    }
    if (statusline.ultrafast_indicator_active) {
        const marker_style = if (truecolor_enabled) "\x1b[38;2;255;204;0m" else "\x1b[38;5;220m";
        var marker_buf: [64]u8 = undefined;
        const marker = std.mem.print(&marker_buf, "{s}⚡︎{s}", .{ marker_style, statusline_style }) catch "⚡︎";
        appendStatusSegment(out, end, marker);
    } else if (fast_indicator_active) {
        appendStatusSegment(out, end, "⚡︎");
    }
    if (statusline.session_title) |title| {
        appendStatusSegment(out, end, display_width.prefixByWidth(title, max_session_title_cells));
    }
    var ctx_buf: [48]u8 = undefined;
    var count_buf: [32]u8 = undefined;
    if (statusline.context_total) |total| {
        if (total != 0) appendStatusSegment(out, end, std.fmt.bufPrint(&ctx_buf, "{d:.1}%/{s}", .{
            percent(statusline.context_used, total), compactTokens(&count_buf, total),
        }) catch "");
    } else if (statusline.context_used > 0) {
        appendStatusSegment(out, end, compactTokens(&count_buf, statusline.context_used));
    }
    if (statusline.usage) |usage| {
        var bufs: [4][32]u8 = undefined;
        var usage_buf: [160]u8 = undefined;
        var w: std.Io.Writer = .fixed(&usage_buf);
        w.print("↑{s} ↓{s} R{s} W{s}", .{
            compactTokens(&bufs[0], usage.input), compactTokens(&bufs[1], usage.output),
            compactTokens(&bufs[2], usage.read),  compactTokens(&bufs[3], usage.write),
        }) catch unreachable;
        if (usage.cacheable > 0) w.print(" CH{d:.1}%", .{percent(usage.read, usage.cacheable)}) catch unreachable;
        appendStatusSegment(out, end, w.buffered());
    }
    appendWorkspaceIdentity(out, end, status_limit, statusline);
}

fn percent(n: u64, d: u64) f64 {
    return @as(f64, @floatFromInt(n)) * 100 / @as(f64, @floatFromInt(d));
}

fn compactTokens(buf: []u8, n: u64) []const u8 {
    const scale: u64, const suffix: []const u8 = if (n >= 1_000_000) .{ 1_000_000, "M" } else if (n >= 1_000) .{ 1_000, "k" } else .{ 1, "" };
    const tenths = (n % scale) * 10 / scale;
    return if (tenths > 0 and n / scale < 100)
        std.fmt.bufPrint(buf, "{d}.{d}{s}", .{ n / scale, tenths, suffix }) catch ""
    else
        std.fmt.bufPrint(buf, "{d}{s}", .{ n / scale, suffix }) catch "";
}

pub const subagent_status_width: u16 = 200;

pub fn buildSessionStatusLine(
    model: []const u8,
    effort: types.ReasoningEffort,
    model_supports_effort: bool,
    statusline: StatuslineItems,
    width: u16,
    out: []u8,
) []const u8 {
    var end: usize = 0;
    const status_limit = @min(@as(usize, width), out.len);
    var model_buf: [512]u8 = undefined;
    const model_label = statusModelLabel(statusline.model_name orelse model, &model_buf);
    appendSessionStatusSegments(out, &end, status_limit, model_label, effort, model_supports_effort, false, statusline);
    if (width == 0) return "";
    return display_width.prefixByWidthIgnoringAnsi(out[0..end], width);
}

pub fn buildHintLine(
    has_api_key: bool,
    model: []const u8,
    permission_mode: types.PermissionMode,
    fast_indicator_active: bool,
    effort: types.ReasoningEffort,
    model_supports_effort: bool,
    statusline: StatuslineItems,
    width: u16,
    out: []u8,
) []const u8 {
    // With no connection there is no model yet; don't name the built-in default.
    var model_buf: [512]u8 = undefined;
    const model_label = if (has_api_key) statusModelLabel(statusline.model_name orelse model, &model_buf) else "Select a model";
    var permission_buf: [64]u8 = undefined;
    const permission_label = permissionModeStatusLabel(permission_mode, &permission_buf);

    var end: usize = 0;
    if (!has_api_key) {
        appendStatusSegment(out, &end, "run /provider");
    }
    const status_limit = @min(@as(usize, width), out.len);
    if (leadingPermissionModeFits(status_limit, permission_label, model_label)) {
        appendStatusSegment(out, &end, permission_label);
    }
    appendSessionStatusSegments(out, &end, status_limit, model_label, effort, model_supports_effort and has_api_key, fast_indicator_active, statusline);

    const width_usize: usize = width;
    if (width_usize == 0) return "";
    return display_width.prefixByWidthIgnoringAnsi(out[0..end], width_usize);
}

test "status line uses the exact model ID or its display name" {
    const id = "claude-opus-5-5";
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(id ++ " · medium", buildHintLine(true, id, .yolo, false, types.ReasoningEffort.literal("medium"), true, .{}, 80, &buf));
    const name: StatuslineItems = .{ .model_name = "Claude Opus 5.5" };
    try std.testing.expectEqualStrings("Claude Opus 5.5 · medium", buildHintLine(true, id, .yolo, false, types.ReasoningEffort.literal("medium"), true, name, 80, &buf));
    try std.testing.expectEqualStrings("Claude Opus 5.5 · medium", buildSessionStatusLine(id, types.ReasoningEffort.literal("medium"), true, name, 80, &buf));
    try std.testing.expectEqualStrings("anthropic/" ++ id, buildSessionStatusLine("anthropic/" ++ id, .auto, false, .{}, 80, &buf));
    try std.testing.expectEqualStrings("run /provider · Select a model", buildHintLine(false, id, .yolo, false, types.ReasoningEffort.literal("medium"), true, name, 80, &buf));
}

pub fn buildInputLine(input: []const u8, cursor: usize, width: u16, out: []u8) InputLineView {
    const ml = countMultilineInfo(input, cursor, width);
    return buildInputLineForRow(input, cursor, ml.cursor_line, ml.total_lines, width, out);
}

pub fn inputColumnForIndex(input: []const u8, cursor: usize, target: usize, width: u16) u16 {
    const summary = visual_layout.summarize(.{ .input = input, .cursor = cursor, .terminal_cols = width }, target);
    return visual_layout.projectedAnchorColumn(summary, width);
}

fn copyVisualRowToBuffer(source: visual_layout.Source, target_row: usize, out: []u8) []const u8 {
    if (source.terminal_cols == 0 or out.len == 0) return "";

    var len: usize = 0;
    var row_started = false;
    var remaining_cells: usize = 0;
    var omitted_positive_unit = false;
    var it = visual_layout.iterator(source);
    while (it.next()) |event| switch (event) {
        .unit => |unit| {
            if (unit.row_index < target_row) continue;
            if (unit.row_index > target_row) break;
            startVisualRow(source.terminal_cols, target_row, out, &len, &row_started, &remaining_cells);
            if (remaining_cells == 0) continue;
            switch (unit.kind) {
                .text => {
                    if (unit.cell_width == 0) {
                        if (!omitted_positive_unit) appendBytesToBuffer(out, &len, source.input[unit.raw_start..unit.raw_end]);
                    } else if (unit.cell_width <= remaining_cells) {
                        appendBytesToBuffer(out, &len, source.input[unit.raw_start..unit.raw_end]);
                        remaining_cells -= unit.cell_width;
                        omitted_positive_unit = false;
                    } else {
                        omitted_positive_unit = true;
                    }
                },
                .paste_placeholder => {
                    const visible = display_width.prefixByWidth(
                        source.input[unit.raw_start..unit.raw_end],
                        remaining_cells,
                    );
                    appendBytesToBuffer(out, &len, visible);
                    const emitted_width = display_width.visibleWidth(visible);
                    remaining_cells -= emitted_width;
                    omitted_positive_unit = emitted_width < unit.cell_width;
                },
                .tab => {
                    if (unit.cell_width > 0 and unit.cell_width <= remaining_cells) {
                        appendSpacesToBuffer(out, &len, unit.cell_width);
                        remaining_cells -= unit.cell_width;
                        omitted_positive_unit = false;
                    } else if (unit.cell_width > 0) {
                        omitted_positive_unit = true;
                    }
                },
                .skill_token => |token_index| {
                    const token = source.skill_tokens[token_index];
                    if (unit.cell_width <= remaining_cells) {
                        appendBytesToBuffer(out, &len, token.name);
                        remaining_cells -= unit.cell_width;
                        omitted_positive_unit = false;
                    } else {
                        omitted_positive_unit = true;
                    }
                },
                .image_badge => {},
            }
        },
        .row_end => |row| {
            if (row.index < target_row) continue;
            if (row.index == target_row) startVisualRow(source.terminal_cols, target_row, out, &len, &row_started, &remaining_cells);
            break;
        },
    };
    return out[0..len];
}

fn startVisualRow(width: u16, row_index: usize, out: []u8, len: *usize, started: *bool, remaining_cells: *usize) void {
    if (started.*) return;
    started.* = true;
    const prefix = visual_layout.inputPrefix(row_index);
    const clipped = display_width.prefixByWidth(prefix.bytes, width);
    appendBytesToBuffer(out, len, clipped);
    const width_usize: usize = width;
    remaining_cells.* = if (width_usize > prefix.cell_width) width_usize - prefix.cell_width else 0;
}

fn appendBytesToBuffer(out: []u8, len: *usize, bytes: []const u8) void {
    if (bytes.len > out.len - len.*) return;
    @memcpy(out[len.* .. len.* + bytes.len], bytes);
    len.* += bytes.len;
}

fn appendSpacesToBuffer(out: []u8, len: *usize, count: usize) void {
    var i: usize = 0;
    while (i < count and len.* < out.len) : (i += 1) {
        out[len.*] = ' ';
        len.* += 1;
    }
}

/// Writes the title to the same file the transcript renders to, so a host
/// that redirects its output keeps the escape sequence out of the real
/// stdout. `out` must outlive every call.
pub fn terminalTitleFor(out: *const std.Io.File) host.TerminalTitle {
    return .{
        .context = @constCast(out),
        .set_fn = setTerminalTitleLabel,
        .clear_fn = clearTerminalTitleProvider,
    };
}

fn titleOutput(raw: ?*anyopaque) std.Io.File {
    const out: *const std.Io.File = @ptrCast(@alignCast(raw.?));
    return out.*;
}

const terminal_title_osc_prefix = "\x1b]2;";
const terminal_title_max_content_bytes: usize = 128;
const terminal_title_max_label_bytes = terminal_title_max_content_bytes;

fn sanitizedTerminalTitleLabel(raw: []const u8, buffer: *[terminal_title_max_label_bytes]u8) []const u8 {
    const marker = "...";
    var source_index: usize = 0;
    var written: usize = 0;
    while (source_index < raw.len) {
        const sequence_len: usize = std.unicode.utf8ByteSequenceLength(raw[source_index]) catch {
            source_index += 1;
            continue;
        };
        if (raw.len - source_index < sequence_len) break;
        const sequence = raw[source_index .. source_index + sequence_len];
        const codepoint = display_width.decodeUtf8Sequence(sequence) catch {
            source_index += 1;
            continue;
        };
        source_index += sequence_len;
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) continue;
        if (written + sequence_len > buffer.len) {
            written = text_utils.utf8BackwardBoundary(buffer[0..written], buffer.len - marker.len);
            @memcpy(buffer[written .. written + marker.len], marker);
            written += marker.len;
            break;
        }
        @memcpy(buffer[written .. written + sequence_len], sequence);
        written += sequence_len;
    }
    return buffer[0..written];
}

fn setTerminalTitleLabel(raw: ?*anyopaque, label: []const u8) void {
    const out = titleOutput(raw);
    var label_buffer: [terminal_title_max_label_bytes]u8 = undefined;
    const sanitized = sanitizedTerminalTitleLabel(label, &label_buffer);
    var sequence_buffer: [terminal_title_osc_prefix.len + terminal_title_max_content_bytes + 1]u8 = undefined;
    var sequence: std.Io.Writer = .fixed(&sequence_buffer);
    sequence.writeAll(terminal_title_osc_prefix) catch return;
    sequence.writeAll(sanitized) catch return;
    sequence.writeByte('\x07') catch return;
    out.writeStreamingAll(io_mod.getIo(), sequence.buffered()) catch return;
}

fn clearTerminalTitleProvider(raw: ?*anyopaque) void {
    const out = titleOutput(raw);
    out.writeStreamingAll(io_mod.getIo(), "\x1b]2;\x07") catch return;
}

/// The command gets a line to itself, so selecting that line copies only the
/// command.
pub fn formatResumeHandoff(buffer: []u8, session_id: []const u8) ![]const u8 {
    return std.mem.print(
        buffer,
        "{s}Resume this session with:\nspark --resume {s}{s}\n",
        .{ dim_style, session_id, reset_style },
    );
}
