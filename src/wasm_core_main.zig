const std = @import("std");
const build_options = @import("build_options");
const acp_server = @import("acp/server.zig");
const js_host_stream_provider = @import("gateway/js_host_stream_provider.zig");
const host_chat_completions = @import("gateway/host_chat_completions.zig");
const model_provider = @import("core/config/model_provider.zig");
const context_contract = @import("core/workspace/context_contract.zig");
const provider_set = @import("core/gateway/provider_set.zig");
const agent_steps = @import("core/config/agent_steps.zig");
const host = @import("core/hosts/host.zig");
const js_host_attachments = @import("core/hosts/js_host_attachments.zig");
const io_mod = @import("core/shared/io.zig");
const builtin_modes = @import("builtins/modes.zig");

comptime {
    if (build_options.wasm_surface != .core) {
        @compileError("spark-core requires -Dwasm-surface=core");
    }
}

pub const panic = @import("core/hosts/wasm_panic.zig").panic;

pub fn main(init: std.process.Init) !void {
    io_mod.setIo(init.io);
    io_mod.setEnvironMap(init.environ_map);
    const alloc = std.heap.c_allocator;
    // SPARK_CONFIGURED_PROVIDERS defines the app's own provider, if it has one.
    const configured_providers = io_mod.getenv("SPARK_CONFIGURED_PROVIDERS");
    var custom_context: ?host_chat_completions.Context = null;
    defer if (custom_context) |*context| context.deinit(alloc);
    var providers: provider_set.Set = .{};
    if (configured_providers) |json| {
        custom_context = try host_chat_completions.Context.init(alloc, js_host_stream_provider.transport, json);
        providers.definitions = custom_context.?.registry.definitions;
        providers.configured_fn = host_chat_completions.bundle;
        providers.configured_context = &custom_context.?;
    }
    try acp_server.run(alloc, .{
        .default_model = "",
        .default_agent_step_limit = agent_steps.default_max_agent_steps,
        .provider_set = providers,
        .secret_store = host.unavailable_secret_store,
        .prompt_policy = .{ .system_prompt = "" },
        .ignored_list_entries = &.{},
        .max_list_entries = 0,
        .max_read_file_bytes = 0,
        .max_read_file_lines = 0,
        .max_read_file_line_len = 0,
        .max_command_output_bytes = 0,
        .max_tool_result_bytes = 64 * 1024,
        .max_history_turns = 100,
        .context_registry = .{ .default_provider = context_contract.empty_provider },
        .mode_registry = builtin_modes.registry,
        .provider_override = try providerOverrideFromEnv(io_mod.getenv("SPARK_PROVIDER"), if (custom_context) |*context| context else null),
        // The JS host adds provider credentials at its fetch edge.
        .provider_auth_mode = .host_managed,
        .configured_providers_json = configured_providers,
        .model_override = io_mod.getenv("SPARK_MODEL"),
        .effort_override = io_mod.getenv("SPARK_EFFORT"),
        .fast_override = fastOverrideFromEnv(io_mod.getenv("SPARK_FAST")),
        .ultrafast_override = fastOverrideFromEnv(io_mod.getenv("SPARK_ULTRAFAST")),
        .workspace_root_override = "/",
        .allow_acp_mcp = false,
        .allow_native_tools = false,
        .minimal_kernel = true,
        .host_attachments = js_host_attachments.store,
    });
}

/// libfx engines run the configured provider, bound to its definition so saved
/// sessions record it. Null keeps the startup provider, which is `.none` when
/// nothing is configured.
fn providerOverrideFromEnv(value: ?[]const u8, configured: ?*const host_chat_completions.Context) error{InvalidProvider}!?model_provider.ProviderId {
    const raw = value orelse return null;
    const context = configured orelse return error.InvalidProvider;
    const provider = model_provider.parse(raw) orelse return error.InvalidProvider;
    return provider.bind(context.registry) catch error.InvalidProvider;
}

/// Parses an SPARK_FAST or SPARK_ULTRAFAST host toggle: "true"/"1" enable the
/// lane, "false"/"0" disable it, and anything else leaves the default in place.
fn fastOverrideFromEnv(value: ?[]const u8) ?bool {
    const raw = value orelse return null;
    if (std.ascii.eqlIgnoreCase(raw, "true") or std.mem.eql(u8, raw, "1")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "false") or std.mem.eql(u8, raw, "0")) return false;
    return null;
}
