//! L0 (posix storage): the only code in the session manager that touches the
//! file system. It knows nothing about sessions.
//!
//! Policy owned here:
//! - every folder is created `0700` and every file `0600`;
//! - nothing under the root is reached through a symlink: existing files and
//!   folders open with `follow_symlinks = false`, and new files are created
//!   exclusively, which fails on any existing name, a symlink included;
//! - writes and reads loop until done, so callers never see partial I/O.
//!
//! With `-Dhooks=true`, every call first consults the fault injector in
//! `storage_fault.zig`, which models process and machine crashes for tests
//! and the driver. Without hooks that code does not exist in the binary.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;

pub const hooks = build_options.hooks;
pub const Fault = if (hooks) @import("storage_fault.zig").Fault else void;

pub const folder_mode: std.posix.mode_t = 0o700;
pub const file_mode: std.posix.mode_t = 0o600;
/// A blob never changes once written, and a tool may open it by path (D49).
pub const blob_mode: std.posix.mode_t = 0o400;

pub const Error = error{
    /// No file or folder by that name.
    NotFound,
    /// An exclusive create or a folder rename hit an existing name.
    AlreadyExists,
    /// A symlink, a name of the wrong kind, or a permission denial.
    Refused,
    /// Disk full or quota exhausted.
    NoSpace,
    /// The file system is mounted read-only.
    ReadOnly,
    /// A file-size limit (RLIMIT_FSIZE) was reached.
    TooBig,
    /// Any other failure. After a failed write or sync, durability is unknown.
    Io,
    /// The calling task was canceled; the operation may be partly done.
    Canceled,
};

/// I/O failures as the API reports them (D29): the OS cause when it is
/// known, `Io` otherwise. After a failed write or sync, durability is
/// unknown whichever it is.
pub const IoFault = error{ Io, NoSpaceLeft, AccessDenied, ReadOnlyFileSystem, FileTooBig };

/// Keeps the cause of a storage failure, and of one already classified;
/// anything else is `Io`.
pub fn ioFault(err: anyerror) IoFault {
    return switch (err) {
        error.NoSpace, error.NoSpaceLeft => error.NoSpaceLeft,
        error.Refused, error.AccessDenied => error.AccessDenied,
        error.ReadOnly, error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
        error.TooBig, error.FileTooBig => error.FileTooBig,
        else => error.Io,
    };
}

/// A folder opened for listing (`openDir`, `openRoot`). Linux opens any
/// other folder with `O_PATH`, which `syncDir` cannot sync (EBADF).
pub const Dir = struct { handle: Io.Dir };
pub const File = struct { handle: Io.File };

pub const Access = enum { read_only, read_write };

pub const Kind = enum { file, directory, other };

pub const Stat = struct {
    size: u64,
    kind: Kind,
    /// Permission bits only (`0o777` mask).
    mode: std.posix.mode_t,
    /// Last modification, milliseconds since the epoch.
    mtime_ms: i64,
};

pub const Entry = struct {
    /// Borrowed; valid until the next call to `Listing.next`.
    name: []const u8,
    kind: Kind,
};

/// A handle to the file system. Small and copied by value; it owns nothing.
pub const Storage = struct {
    io: Io,
    /// Test-only fault injector, borrowed. Null means real behavior.
    fault: if (hooks) ?*Fault else void = if (hooks) null else {},

    /// Opens the sessions root, creating missing parents with default
    /// permissions and the root itself `0700`. The root may not be a symlink;
    /// its parents may.
    pub fn openRoot(s: Storage, path: []const u8) Error!Dir {
        try s.alive();
        const parent_path = std.Io.Dir.path.dirname(path) orelse ".";
        const name = std.Io.Dir.path.basename(path);
        const cwd = Io.Dir.cwd();
        // Missing parents are the manager's own folders, so private too, for
        // example `~/.spark/sessions` on a machine that never ran v1 (D19).
        // Existing ones are left as they are.
        _ = cwd.createDirPathStatus(s.io, parent_path, .fromMode(folder_mode)) catch |err| return translate(err);
        var parent = cwd.openDir(s.io, parent_path, .{}) catch |err| return translate(err);
        defer parent.close(s.io);
        return s.ensureDir(.{ .handle = parent }, name);
    }

    /// Whether the sessions root exists, creating neither it nor its parents.
    pub fn rootExists(s: Storage, path: []const u8) Error!bool {
        try s.alive();
        const parent_path = std.Io.Dir.path.dirname(path) orelse ".";
        var parent = Io.Dir.cwd().openDir(s.io, parent_path, .{}) catch |err| return switch (translate(err)) {
            error.NotFound => false,
            else => |e| e,
        };
        defer parent.close(s.io);
        _ = s.stat(.{ .handle = parent }, std.Io.Dir.path.basename(path)) catch |err| return switch (err) {
            error.NotFound => false,
            else => err,
        };
        return true;
    }

    /// Opens `name` inside `parent`, creating it `0700` if it is missing.
    pub fn ensureDir(s: Storage, parent: Dir, name: []const u8) Error!Dir {
        s.makeDir(parent, name) catch |err| switch (err) {
            error.AlreadyExists => {},
            else => return err,
        };
        return s.openDir(parent, name);
    }

    pub fn openDir(s: Storage, parent: Dir, name: []const u8) Error!Dir {
        try s.alive();
        assertComponent(name);
        const handle = parent.handle.openDir(s.io, name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| return translate(err);
        return .{ .handle = handle };
    }

    pub fn closeDir(s: Storage, dir: Dir) void {
        dir.handle.close(s.io);
    }

    /// Creates a folder `0700`. Fails with AlreadyExists if the name exists.
    pub fn makeDir(s: Storage, parent: Dir, name: []const u8) Error!void {
        try s.alive();
        try s.mutate();
        assertComponent(name);
        parent.handle.createDir(s.io, name, .fromMode(folder_mode)) catch |err|
            return translate(err);
        if (hooks) if (s.fault) |f| try f.noteCreate(s, parent, name);
    }

    /// Creates a new file `0600`, opened for reading and writing. Fails with
    /// AlreadyExists if the name exists, including as a symlink.
    pub fn createFile(s: Storage, dir: Dir, name: []const u8) Error!File {
        return s.createFileMode(dir, name, file_mode);
    }

    /// As `createFile`, but `0400`: the returned handle still writes the new
    /// file, and nothing can open it for writing afterwards (D49).
    pub fn createReadOnlyFile(s: Storage, dir: Dir, name: []const u8) Error!File {
        return s.createFileMode(dir, name, blob_mode);
    }

    fn createFileMode(s: Storage, dir: Dir, name: []const u8, mode: std.posix.mode_t) Error!File {
        try s.alive();
        try s.mutate();
        assertComponent(name);
        const handle = dir.handle.createFile(s.io, name, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .permissions = .fromMode(mode),
            .resolve_beneath = true,
        }) catch |err| return translate(err);
        if (hooks) if (s.fault) |f| {
            f.noteCreate(s, dir, name) catch |err| {
                handle.close(s.io);
                return err;
            };
        };
        return .{ .handle = handle };
    }

    /// Opens an existing regular file. A symlink or a folder is Refused.
    pub fn openFile(s: Storage, dir: Dir, name: []const u8, access: Access) Error!File {
        try s.alive();
        assertComponent(name);
        const handle = dir.handle.openFile(s.io, name, .{
            .mode = switch (access) {
                .read_only => .read_only,
                .read_write => .read_write,
            },
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| return translate(err);
        return .{ .handle = handle };
    }

    pub fn closeFile(s: Storage, file: File) void {
        if (hooks) if (s.fault) |f| f.noteClose(s, file);
        file.handle.close(s.io);
    }

    /// Closes a derived file that is written without a sync on purpose (the
    /// index): a crash may lose its tail, and rebuild re-derives it.
    pub fn closeDerived(s: Storage, file: File) void {
        if (hooks) if (s.fault) |f| f.forgetWriter(file);
        file.handle.close(s.io);
    }

    pub fn length(s: Storage, file: File) Error!u64 {
        try s.alive();
        return file.handle.length(s.io) catch |err| translate(err);
    }

    /// Reads into `buffer` from `offset` until it is full or the file ends.
    /// Returns the number of bytes read.
    pub fn readAt(s: Storage, file: File, buffer: []u8, offset: u64) Error!usize {
        try s.alive();
        var done: usize = 0;
        while (done < buffer.len) {
            const n = file.handle.readPositional(s.io, &.{buffer[done..]}, offset + done) catch |err|
                return translate(err);
            if (n == 0) break;
            done += n;
        }
        return done;
    }

    /// Writes all of `bytes` at `offset`.
    pub fn writeAt(s: Storage, file: File, bytes: []const u8, offset: u64) Error!void {
        try s.alive();
        try s.mutate();
        var allowed = bytes.len;
        var outcome: WriteOutcome = .complete;
        if (hooks) if (s.fault) |f| {
            try f.noteBeforeWrite(s, file);
            const plan = f.planWrite(bytes.len);
            allowed = plan.allowed;
            outcome = plan.outcome;
        };
        file.handle.writePositionalAll(s.io, bytes[0..allowed], offset) catch |err|
            return translate(err);
        switch (outcome) {
            .complete => {},
            .fail => {
                if (hooks) if (s.fault) |f| return f.fail_error;
                return error.Io;
            },
            .die => {
                if (hooks) if (s.fault) |f| f.kill();
                return error.Io;
            },
        }
    }

    /// Durability point for one file: a plain `fsync` (D3).
    pub fn sync(s: Storage, file: File) Error!void {
        try s.alive();
        try s.mutate();
        if (hooks) if (s.fault) |f| if (f.takeSyncFailure()) return f.fail_error;
        file.handle.sync(s.io) catch |err| return translate(err);
        if (hooks) if (s.fault) |f| try f.noteSync(s, file);
    }

    /// Makes created, renamed and removed names inside `dir` durable.
    pub fn syncDir(s: Storage, dir: Dir) Error!void {
        try s.alive();
        try s.mutate();
        const as_file: Io.File = .{ .handle = dir.handle.handle, .flags = .{ .nonblocking = false } };
        as_file.sync(s.io) catch |err| return translate(err);
        if (hooks) if (s.fault) |f| try f.noteDirSync(s, dir);
    }

    /// Cuts the file to `new_length` bytes.
    pub fn setLength(s: Storage, file: File, new_length: u64) Error!void {
        try s.alive();
        try s.mutate();
        file.handle.setLength(s.io, new_length) catch |err| return translate(err);
        if (hooks) if (s.fault) |f| f.noteSetLength(file, new_length);
    }

    /// Takes an exclusive `flock` without waiting. Returns false if another
    /// open file description holds it. The kernel releases it on process exit.
    pub fn tryLock(s: Storage, file: File) Error!bool {
        try s.alive();
        return file.handle.tryLock(s.io, .exclusive) catch |err| translate(err);
    }

    pub fn unlock(s: Storage, file: File) void {
        file.handle.unlock(s.io);
    }

    /// Renames within the root. A file rename replaces an existing file; a
    /// folder rename never replaces a non-empty folder (AlreadyExists).
    pub fn rename(s: Storage, old_dir: Dir, old_name: []const u8, new_dir: Dir, new_name: []const u8) Error!void {
        try s.alive();
        try s.mutate();
        assertComponent(old_name);
        assertComponent(new_name);
        Io.Dir.rename(old_dir.handle, old_name, new_dir.handle, new_name, s.io) catch |err|
            return translate(err);
        if (hooks) if (s.fault) |f| try f.noteRename(s, old_dir, old_name, new_dir, new_name);
    }

    /// Hard link (fork blobs). Fails if the new name exists.
    pub fn link(s: Storage, old_dir: Dir, old_name: []const u8, new_dir: Dir, new_name: []const u8) Error!void {
        try s.alive();
        try s.mutate();
        assertComponent(old_name);
        assertComponent(new_name);
        Io.Dir.hardLink(old_dir.handle, old_name, new_dir.handle, new_name, s.io, .{
            .follow_symlinks = false,
        }) catch |err| return translate(err);
        if (hooks) if (s.fault) |f| try f.noteCreate(s, new_dir, new_name);
    }

    pub fn deleteFile(s: Storage, dir: Dir, name: []const u8) Error!void {
        try s.alive();
        try s.mutate();
        assertComponent(name);
        dir.handle.deleteFile(s.io, name) catch |err| return translate(err);
    }

    /// Removes a folder and everything in it. A missing name is not an error.
    pub fn deleteTree(s: Storage, dir: Dir, name: []const u8) Error!void {
        try s.alive();
        try s.mutate();
        assertComponent(name);
        dir.handle.deleteTree(s.io, name) catch |err| return translate(err);
    }

    /// Stats a name without following a symlink.
    pub fn stat(s: Storage, dir: Dir, name: []const u8) Error!Stat {
        try s.alive();
        assertComponent(name);
        const st = dir.handle.statFile(s.io, name, .{ .follow_symlinks = false }) catch |err|
            return translate(err);
        return .{
            .size = st.size,
            .kind = switch (st.kind) {
                .file => .file,
                .directory => .directory,
                else => .other,
            },
            .mode = st.permissions.toMode() & 0o777,
            .mtime_ms = st.mtime.toMilliseconds(),
        };
    }

    /// Lists a folder opened by this Storage.
    pub fn list(s: Storage, dir: Dir) Listing {
        return .{ .io = s.io, .iterator = dir.handle.iterate() };
    }

    fn mutate(s: Storage) Error!void {
        if (hooks) if (s.fault) |f| if (f.mutate()) return error.Io;
    }

    fn alive(s: Storage) Error!void {
        if (hooks) if (s.fault) |f| if (f.dead) return error.Io;
    }
};

pub const Listing = struct {
    io: Io,
    iterator: Io.Dir.Iterator,

    pub fn next(l: *Listing) Error!?Entry {
        const entry = (l.iterator.next(l.io) catch |err| return translate(err)) orelse return null;
        return .{
            .name = entry.name,
            .kind = switch (entry.kind) {
                .file => .file,
                .directory => .directory,
                else => .other,
            },
        };
    }
};

pub const WriteOutcome = enum { complete, fail, die };

/// A name must be one path component: the manager builds every path from
/// validated ids and fixed names, so anything else is a programming error.
fn assertComponent(name: []const u8) void {
    std.debug.assert(name.len > 0);
    std.debug.assert(std.mem.findScalar(u8, name, '/') == null);
    std.debug.assert(!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, ".."));
}

fn translate(err: anyerror) Error {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.PathAlreadyExists, error.DirNotEmpty => error.AlreadyExists,
        error.SymLinkLoop,
        error.NotDir,
        error.IsDir,
        error.AccessDenied,
        error.PermissionDenied,
        error.BadPathName,
        => error.Refused,
        error.NoSpaceLeft, error.DiskQuota => error.NoSpace,
        error.ReadOnlyFileSystem => error.ReadOnly,
        error.FileTooBig => error.TooBig,
        error.Canceled => error.Canceled,
        else => error.Io,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn testRoot(tmp: *testing.TmpDir) Dir {
    return .{ .handle = tmp.dir };
}

test "an I/O failure keeps its OS cause, and only unknown ones become Io (D29)" {
    try testing.expectEqual(error.NoSpaceLeft, ioFault(translate(error.NoSpaceLeft)));
    try testing.expectEqual(error.NoSpaceLeft, ioFault(translate(error.DiskQuota)));
    try testing.expectEqual(error.AccessDenied, ioFault(translate(error.AccessDenied)));
    try testing.expectEqual(error.AccessDenied, ioFault(translate(error.PermissionDenied)));
    try testing.expectEqual(error.ReadOnlyFileSystem, ioFault(translate(error.ReadOnlyFileSystem)));
    try testing.expectEqual(error.FileTooBig, ioFault(translate(error.FileTooBig)));
    try testing.expectEqual(error.Io, ioFault(translate(error.InputOutput)));
    // Classified once, it stays classified through every layer above.
    inline for (.{ error.NoSpaceLeft, error.AccessDenied, error.ReadOnlyFileSystem, error.FileTooBig, error.Io }) |kind| {
        try testing.expectEqual(kind, ioFault(ioFault(kind)));
    }
}
