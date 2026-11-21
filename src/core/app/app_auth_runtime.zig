const std = @import("std");
const agents = @import("../agents/agents.zig");
const config_runtime = @import("../config/config_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const credentials = @import("../auth/credentials.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const model_provider = @import("../config/model_provider.zig");
const provider_runtime = @import("provider_runtime.zig");
const types = @import("../shared/types.zig");

const provider_busy_message = "Switching providers is unavailable until active and queued work finishes.";

pub const PendingPromptCredentialReadiness = enum {
    pending,
    current,
    rejected,
};

/// The interactive app's side of authentication: each configured provider
/// carries its own credential, so there is nothing to sign in to. A prompt
/// needs a provider and that provider's key.
pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};

        fn compactionOwnsCredentialFeedback(_: *const App, agent: *const AppAgent) bool {
            return if (comptime agents.hasAgentField(App, "submission")) agent.submission.compaction_pending else false;
        }

        fn hostManagesAuth(app: anytype) bool {
            return app.auth.isHostManaged();
        }

        /// Whether the session's provider has its credential loaded, loading it
        /// first when the provider changed. Says why when it can't.
        fn ensurePromptCredential(app: *App, agent: *AppAgent) !bool {
            if (comptime @hasField(App, "provider_selection")) {
                if (app.provider_selection.model_requests_blocked) {
                    try writeNotice(app, .@"error", "Repair profile settings and restart spark before sending a message.");
                    return false;
                }
            }
            if (hostManagesAuth(app)) return true;
            const provider: model_provider.ProviderId = if (comptime provider_runtime.supported(App))
                provider_runtime.providerOf(app, agent)
            else
                .none;
            if (provider == .none) return missingPromptCredential(app, agent, provider);
            if (app.auth.credentialSource() != null and app.auth.loaded_for.same_authority(provider)) return true;
            switch (try app.auth.selectForProvider(app.alloc, provider)) {
                .selected, .unchanged => {
                    app.auth.loaded_for = provider;
                    return true;
                },
                .missing => return missingPromptCredential(app, agent, provider),
                .failed => |failure| {
                    if (compactionOwnsCredentialFeedback(app, agent)) return false;
                    const body = try app.alloc.print("{s} {s}", .{ auth_runtime.missingCredentialText(provider), @errorName(failure.err) });
                    defer app.alloc.free(body);
                    try writeNotice(app, .@"error", body);
                    return false;
                },
            }
        }

        fn missingPromptCredential(app: *App, agent: *AppAgent, provider: model_provider.ProviderId) !bool {
            if (compactionOwnsCredentialFeedback(app, agent)) return false;
            try writeNotice(app, .warning, auth_runtime.missingCredentialText(provider));
            return false;
        }

        pub fn admitPromptCredential(app: *App, agent: *AppAgent) !bool {
            return ensurePromptCredential(app, agent);
        }

        pub fn admitQueuedPromptCredential(app: *App, agent: *AppAgent) !bool {
            return ensurePromptCredential(app, agent);
        }

        pub fn collectPendingPromptCredential(app: *App, agent: *AppAgent) !PendingPromptCredentialReadiness {
            return if (try ensurePromptCredential(app, agent)) .current else .rejected;
        }

        pub fn retryPendingPromptCredential(app: *App, agent: *AppAgent) !PendingPromptCredentialReadiness {
            return collectPendingPromptCredential(app, agent);
        }

        /// Loads the credential for the provider a resumed session names.
        pub fn restoreSessionCredential(app: *App, previous_provider: model_provider.ProviderId) !void {
            const provider = provider_runtime.provider(app);
            if (!previous_provider.same_authority(provider)) app.model_cache.resetForProviderChange();
            if (hostManagesAuth(app) or provider == .none) return;
            switch (try app.auth.selectForProvider(app.alloc, provider)) {
                .selected, .unchanged => app.auth.loaded_for = provider,
                .missing => try writeNotice(app, .warning, auth_runtime.missingCredentialText(provider)),
                .failed => |failure| {
                    debug_trace.logf("auth", "resumed credential unavailable err={s}", .{@errorName(failure.err)});
                    try writeNotice(app, .@"error", auth_runtime.missingCredentialText(provider));
                },
            }
        }

        /// Explains, once the first frame is up, why the launch provider has
        /// no credential.
        pub fn writeStartupCredentialFailure(
            app: *App,
            provider: model_provider.ProviderId,
            load_failure: ?credentials.LoadFailure,
        ) !void {
            if (app.auth.credentialSource() != null) return;
            if (provider != .none and load_failure == null) return;
            try writeNotice(app, .warning, auth_runtime.missingCredentialText(provider));
        }

        /// Makes `target`, a provider `/provider` just saved or chose, the
        /// session's provider. The model is the one saved for it, else its
        /// first declared model, else the one in use.
        pub fn switchToConnection(app: *App, agent: *AppAgent, target: model_provider.ProviderId) !void {
            if (agent.stream.active or agent.worker.queuedPromptCount() > 0) {
                try writeNotice(app, .warning, provider_busy_message);
                return;
            }
            const current = provider_runtime.providerOf(app, agent);
            if (current.same_authority(target)) {
                const body = try app.alloc.print("Already using {s}.", .{target.label()});
                defer app.alloc.free(body);
                try writeNotice(app, .neutral, body);
                return;
            }
            var settings = config_runtime.loadMergedSettings(app.alloc, app.workspace_root) catch |err| {
                debug_trace.logf("provider", "settings load failed err={s}", .{@errorName(err)});
                try writeNotice(app, .@"error", "Could not load the saved provider selection. The current provider is unchanged.");
                return;
            };
            defer settings.deinit(app.alloc);
            const definition = app.provider_selection.definitions.get(target.label()) orelse {
                try writeNotice(app, .@"error", "That provider is not configured. Run /provider to add it.");
                return;
            };
            const model = settings.models.get(target) orelse
                (if (definition.model_metadata.len > 0) definition.model_metadata[0].id else provider_runtime.modelOf(app, agent));
            var owned_model = try app.alloc.dupe(u8, model);
            defer app.alloc.free(owned_model);

            app.auth.clearCredential(app.alloc);
            app.provider_selection.adoptOwned(target, &owned_model);
            app.model_cache.resetForProviderChange();
            if (comptime @hasDecl(App, "startModelCacheWarmup")) app.startModelCacheWarmup();

            const body = try app.alloc.print("Switched to {s} with {s}.", .{ target.label(), provider_runtime.modelOf(app, agent) });
            defer app.alloc.free(body);
            var persistence = app.persistRuntimePreferences(agent, .{
                .provider = target,
                .model = provider_runtime.modelOf(app, agent),
            });
            defer persistence.deinit(app.alloc);
            if (persistence.settings_error != null or persistence.session_error != null) {
                try writeNotice(app, .warning, "Provider switched for this run, but the selection could not be saved.");
            } else {
                try writeNotice(app, .neutral, body);
            }
        }

        fn writeNotice(app: *App, tone: types.NoticeTone, body: []const u8) !void {
            try app.writeDomainNotice(.{ .topic = "provider", .tone = tone, .body = body }, true);
            app.shell.render_requests.request(.footer);
        }
    };
}
