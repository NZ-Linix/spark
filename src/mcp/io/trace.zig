//! JSONL trace of core steps (format version 1).
//!
//! The I/O layer writes one line per `step` call when tracing is on. The Bun
//! bridge in `tests/tla/drivers/mcp/bridge.ts` turns a trace into a TLA+
//! observation and asks TLC whether it is a behavior of the machine's model
//! in `tests/tla/mcp/`. `data` carries only model projections (ids, versions,
//! flags, counters), never tokens or user content.

const std = @import("std");

pub const format_version = 1;

/// Whether trace code is compiled in. Release spark leaves it out:
/// a program has it only by declaring `pub const mcpv2_trace = true;` in its
/// root file, and tests always have it.
pub const enabled = @import("builtin").is_test or
    (@hasDecl(@import("root"), "mcpv2_trace") and @import("root").mcpv2_trace);

/// `writer` when trace code is compiled in, else a null known at compile
/// time, so the mapping behind `if (trace.on(w)) |t|` isn't compiled either.
pub inline fn on(writer: ?*Writer) ?*Writer {
    if (!enabled) return null;
    return writer;
}

pub const Value = union(enum) {
    int: i64,
    boolean: bool,
    string: []const u8,
};

pub const Field = struct {
    name: []const u8,
    value: Value,
};

pub const Step = struct {
    machine: []const u8,
    instance: []const u8,
    event: []const u8,
    from: []const u8,
    to: []const u8,
    effects: []const []const u8 = &.{},
    data: []const Field = &.{},
};

/// Writes trace lines to `out`. Sequence numbers start at 1 and are contiguous
/// for the life of the writer. Does not flush; the owner of `out` does.
pub const Writer = struct {
    out: *std.Io.Writer,
    next_seq: u64 = 1,
    /// A child's records go to its parent, each instance after `prefix` and
    /// a dot (the engine: one child per server, one trace).
    parent: ?*Writer = null,
    prefix: []const u8 = "",

    pub fn init(out: *std.Io.Writer) Writer {
        return .{ .out = out };
    }

    pub fn child(parent: *Writer, prefix: []const u8) Writer {
        return .{ .out = parent.out, .parent = parent, .prefix = prefix };
    }

    pub fn write(self: *Writer, step: Step) std.Io.Writer.Error!void {
        if (self.parent) |parent| {
            var buffer: [256]u8 = undefined;
            var named = step;
            named.instance = std.mem.print(&buffer, "{s}.{s}", .{ self.prefix, step.instance }) catch return error.WriteFailed;
            return parent.write(named);
        }
        const w = self.out;
        try w.print("{{\"v\":{d},\"seq\":{d},\"machine\":", .{ format_version, self.next_seq });
        try writeString(w, step.machine);
        try w.writeAll(",\"inst\":");
        try writeString(w, step.instance);
        try w.writeAll(",\"event\":");
        try writeString(w, step.event);
        try w.writeAll(",\"from\":");
        try writeString(w, step.from);
        try w.writeAll(",\"to\":");
        try writeString(w, step.to);
        try w.writeAll(",\"effects\":[");
        for (step.effects, 0..) |effect, index| {
            if (index > 0) try w.writeByte(',');
            try writeString(w, effect);
        }
        try w.writeAll("],\"data\":{");
        for (step.data, 0..) |field, index| {
            if (index > 0) try w.writeByte(',');
            try writeString(w, field.name);
            try w.writeByte(':');
            switch (field.value) {
                .int => |n| try w.print("{d}", .{n}),
                .boolean => |b| try w.writeAll(if (b) "true" else "false"),
                .string => |s| try writeString(w, s),
            }
        }
        try w.writeAll("}}\n");
        self.next_seq += 1;
    }
};

fn writeString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try std.json.Stringify.value(s, .{}, w);
}
