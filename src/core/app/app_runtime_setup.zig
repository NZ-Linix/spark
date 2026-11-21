const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");

const Allocator = std.mem.Allocator;
pub const LoadSkillsError = Allocator.Error;

pub const LoadedSkills = struct {
    dir: []u8 = &.{},
    skills: []skill_runtime.Skill = &.{},
    diagnostics: []skill_runtime.SkillDiagnostic = &.{},

    pub fn deinit(self: *LoadedSkills, alloc: Allocator) void {
        if (self.dir.len > 0) alloc.free(self.dir);
        skill_runtime.freeSkills(alloc, self.skills);
        skill_runtime.freeSkillDiagnostics(alloc, self.diagnostics);
        self.* = .{};
    }
};

pub fn resolveSkillsHome(alloc: Allocator) Allocator.Error!?[]u8 {
    const configured_home = io_mod.homeDir() orelse return null;
    return io_mod.realpathAlloc(alloc, configured_home) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => try alloc.dupe(u8, configured_home),
    };
}

/// The managed skills directory under the configured HOME, or null without
/// one. The caller owns the returned path.
pub fn resolveManagedSkillsDir(alloc: Allocator) Allocator.Error!?[]u8 {
    const home = (try resolveSkillsHome(alloc)) orelse return null;
    defer alloc.free(home);
    return try managedSkillsDirFor(alloc, home, profile_paths.fxHomeParent());
}

/// The managed skills directory. With `SPARK_HOME`, the folder that holds it is
/// resolved as `resolveSkillsHome` resolves HOME, so a symlinked parent such
/// as macOS's /tmp does not make a missing skills folder read as a symlinked
/// root. The caller owns the returned path.
fn managedSkillsDirFor(alloc: Allocator, home: []const u8, spark_home_parent: ?[]const u8) Allocator.Error![]u8 {
    const parent = spark_home_parent orelse return try profile_paths.managedSkillsDir(alloc, home);
    const real_parent = io_mod.realpathAlloc(alloc, parent) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try profile_paths.managedSkillsDir(alloc, home),
    };
    defer alloc.free(real_parent);
    return try profile_paths.managedSkillsDirIn(alloc, real_parent);
}

pub fn loadSkills(
    alloc: Allocator,
    workspace_root: []const u8,
    root_policy: skill_contract.RootPolicy,
) LoadSkillsError!LoadedSkills {
    const home = (try resolveSkillsHome(alloc)) orelse return .{};
    defer alloc.free(home);
    const dir = try managedSkillsDirFor(alloc, home, profile_paths.fxHomeParent());
    errdefer alloc.free(dir);
    const discovery = try skill_runtime.loadVisibleSkills(alloc, workspace_root, home, dir, root_policy);

    return .{
        .dir = dir,
        .skills = discovery.skills,
        .diagnostics = discovery.diagnostics,
    };
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

fn tmpPath(alloc: Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, dir, sub_path);
}

fn writeTempFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

const test_root_policy: skill_contract.RootPolicy = .{
    .managed_root_source = .global_spark,
};

test "loadSkills returns empty defaults when HOME is missing" {
    const alloc = std.testing.allocator;
    const home = try TestHome.install(alloc, null);
    defer home.deinit();

    var loaded = try loadSkills(alloc, "/tmp/workspace", test_root_policy);
    defer loaded.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), loaded.dir.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.skills.len);
}
