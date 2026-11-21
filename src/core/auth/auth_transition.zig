const std = @import("std");

pub const AuthReplayFacts = struct {
    authentication_rejected: bool,
    refreshable: bool,
    delivery_safe: bool,
    already_replayed: bool,
};

pub const AuthReplayDecision = enum {
    fail,
    refresh_and_replay,
};

pub fn decideAuthReplay(facts: AuthReplayFacts) AuthReplayDecision {
    if (!facts.authentication_rejected or
        !facts.refreshable or
        !facts.delivery_safe or
        facts.already_replayed)
    {
        return .fail;
    }
    return .refresh_and_replay;
}
