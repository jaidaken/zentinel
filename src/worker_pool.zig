// Layer: deterministic_core
//
// Bounded worker pool for parallel mutant execution (docs/PERFORMANCE_STRATEGY.md).
// The pool maps work-item indices [0, count)
// to results by INDEX, never by completion order, so the worker count changes
// only concurrency and never which result belongs to which item. The run command
// sorts the report into canonical order afterward, so serial and parallel runs
// produce equivalent reports except for normalized durations. jobs == 1 runs
// inline with no threads -- the conservative default. Per-unit workspace paths
// are content-addressed so concurrent workers never share a writable workspace,
// local .zig-cache, or zig-out directory. Pure scheduling: process execution and
// filesystem I/O are performed by the injected task, not by this module.
const std = @import("std");
const config = @import("config.zig");

/// Hard upper bound on concurrent workers, independent of any configured value,
/// so an over-large `--jobs` / `run.jobs` can never spawn unbounded threads.
pub const max_jobs: usize = 64;

/// A lock-guarded allocator wrapper. The parallel mutant phase (`run` with
/// `--jobs > 1`) has multiple worker threads allocate through one underlying
/// allocator -- in production that is the process arena (`std.heap.ArenaAllocator`),
/// which is NOT thread-safe. Serializing every allocator call makes concurrent
/// allocation sound. Subprocess execution (zig build/test) dominates wall time,
/// so the guard is not a contention bottleneck.
///
/// The guard is an atomic test-and-set spinlock rather than a mutex: Zig 0.16
/// removed `std.heap.ThreadSafeAllocator`, and `std.Io.Mutex.lock` needs an `Io`
/// handle the allocator vtable cannot reach. Critical sections are a single arena
/// bump, so spinning is appropriate.
pub const LockedAllocator = struct {
    child: std.mem.Allocator,
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Count of critical sections entered (one per guarded vtable call). Purely
    /// observational: it lets a test assert the guard actually ran, so silently
    /// deleting the lock (and reintroducing the data race) trips the assertion.
    acquisitions: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn allocator(self: *LockedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn lock(self: *LockedAllocator) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
        _ = self.acquisitions.fetchAdd(1, .monotonic);
    }
    fn unlock(self: *LockedAllocator) void {
        self.locked.store(false, .release);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        return self.child.rawAlloc(len, alignment, ret_addr);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

/// A unit of work: process item `index`, optionally using worker lane `slot`
/// (in [0, jobs)) for per-worker scratch. The task writes its own result through
/// the shared `ctx`; the pool never interprets the result.
pub const Task = *const fn (ctx: *anyopaque, index: usize, slot: usize) void;

/// Clamp a requested worker count to `[1, min(count, max_jobs)]`. A zero-work or
/// non-positive request collapses to a single inline worker (conservative).
pub fn effectiveJobs(requested: usize, count: usize) usize {
    if (count == 0) return 1;
    const capped = @min(requested, max_jobs);
    return @max(@as(usize, 1), @min(capped, count));
}

const Shared = struct {
    next: std.atomic.Value(usize),
    count: usize,
    ctx: *anyopaque,
    task: Task,
};

/// Pull item indices off the shared counter until exhausted. Each index is
/// claimed by exactly one worker via an atomic fetch-add, so no item is run
/// twice or skipped regardless of how many workers participate.
fn drain(shared: *Shared, slot: usize) void {
    while (true) {
        const index = shared.next.fetchAdd(1, .seq_cst);
        if (index >= shared.count) return;
        shared.task(shared.ctx, index, slot);
    }
}

/// Run `count` tasks across at most `jobs` workers (after clamping). Each index
/// is processed exactly once and `run` returns only after every task completes,
/// so the caller's result buffer is fully populated. Deterministic in output:
/// the index->result mapping is independent of worker count and scheduling.
pub fn run(jobs: usize, count: usize, ctx: *anyopaque, task: Task) void {
    const workers = effectiveJobs(jobs, count);
    if (workers <= 1 or count <= 1) {
        var i: usize = 0;
        while (i < count) : (i += 1) task(ctx, i, 0);
        return;
    }

    var shared = Shared{
        .next = std.atomic.Value(usize).init(0),
        .count = count,
        .ctx = ctx,
        .task = task,
    };

    var threads: [max_jobs]std.Thread = undefined;
    var spawned: usize = 0;
    var slot: usize = 1;
    while (slot < workers) : (slot += 1) {
        // A spawn failure degrades to fewer workers; correctness is preserved
        // because the calling thread (lane 0) still drains every remaining item.
        threads[spawned] = std.Thread.spawn(.{}, drain, .{ &shared, slot }) catch break;
        spawned += 1;
    }

    drain(&shared, 0);

    var j: usize = 0;
    while (j < spawned) : (j += 1) threads[j].join();
}

/// The per-run workspace container holding every per-mutant workspace for one
/// run: `.zig-cache/zentinel/workspaces/{run_id}`. setupWorkspace materializes it
/// (via createDirPath of a nested `workspaceRoot`), but the per-mutant cleanup
/// only removes the content-addressed leaf, so the caller must deleteTree this
/// base after the run or it leaks one stale `run_<x>` dir per invocation.
/// Every `workspaceRoot` for the run is nested under it, so a single deleteTree
/// reclaims all leaves.
pub fn workspaceRunBase(arena: std.mem.Allocator, run_id: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, ".zig-cache/zentinel/workspaces/{s}", .{run_id});
}

/// Dedicated, content-addressed writable workspace root for one mutant run,
/// isolated by run id and mutant id so two concurrent workers never share a
/// directory. The developer working tree is never mutated in place. Built as
/// `{workspaceRunBase}/{mutant_id}` so the run-base deleteTree reclaims it.
pub fn workspaceRoot(arena: std.mem.Allocator, run_id: []const u8, mutant_id: []const u8) std.mem.Allocator.Error![]const u8 {
    const base = try workspaceRunBase(arena, run_id);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ base, mutant_id });
}

/// Relative target for the link `{workspaceRunBase}/{name}` that stands in for the
/// project's sibling `../{name}`: one `..` per run-base segment climbs back to the
/// project root, one more reaches its parent. Relative, so a checkout can move.
pub fn siblingLinkTarget(arena: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    const base = try workspaceRunBase(arena, "run");
    const depth = std.mem.count(u8, base, "/") + 1;
    var out: std.ArrayList(u8) = .empty;
    for (0..depth + 1) |_| try out.appendSlice(arena, "../");
    try out.appendSlice(arena, name);
    return out.toOwnedSlice(arena);
}

/// The local Zig build cache for a workspace root, nested inside the root so a
/// worker's `zig build` / `zig test` cache cannot collide with another worker's.
/// Wired into the runner: `runner.minimalEnviron` sets `ZIG_LOCAL_CACHE_DIR =
/// cacheDirIn(".")` (cwd-relative), so each spawned command's cwd (= its per-mutant
/// workspace) owns its `.zig-cache` independent of host env -- this is what makes
/// the per-worker local-cache isolation contract true rather than aspirational.
pub fn cacheDirIn(arena: std.mem.Allocator, root: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/.zig-cache", .{root});
}

/// The local Zig output directory for a workspace root, nested inside the root so a
/// worker's `zig-out` cannot collide with another worker's. Unlike the local cache,
/// `zig-out` needs no env override: Zig defaults the install prefix to
/// build-root/`zig-out` (cwd-relative), and each command's cwd is its own workspace,
/// so output isolation is inherent. This builder is the canonical path used by tests
/// and tools asserting that invariant.
pub fn outDirIn(arena: std.mem.Allocator, root: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/zig-out", .{root});
}

/// Directories whose entire subtree is excluded from a per-mutant workspace copy:
/// the zentinel-controlled build cache, the build-output dir, and the VCS dir.
/// Matched by exact path SEGMENT (a sibling like `zig-outputs/` is NOT excluded).
const excluded_descent_dirs = [_][]const u8{ ".zig-cache", "zig-out", ".git" };

fn isExcludedDescentDir(basename: []const u8) bool {
    for (excluded_descent_dirs) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }
    return false;
}

/// Whether a project-relative `path` is excluded from the workspace copy because
/// its FIRST path segment is a cache / build-output / VCS dir. Segment-based (not
/// a raw byte prefix), so a sibling like `zig-outputs/foo.zig` (first segment
/// `zig-outputs`, not `zig-out`) or `.github/workflows/x.zig` is NOT excluded --
/// the prior `startsWith` check wrongly dropped such discovered sources, which
/// then failed the patched write and misclassified the mutant `invalid`.
pub fn excludedCopyPath(path: []const u8) bool {
    const first = path[0 .. std.mem.indexOfScalar(u8, path, '/') orelse path.len];
    return isExcludedDescentDir(first);
}

/// Copy the project tree from `src` into `dst`, descending into every directory
/// EXCEPT `excluded_descent_dirs`. The walker never enters those dirs, which is
/// what keeps a parallel run's per-mutant workspace builders from racing sibling
/// workers tearing down their workspaces under `.zig-cache/zentinel/workspaces`
/// (a transient openDir/copyFile failure there was collapsed into a spurious
/// `invalid` mutant, hiding survivors) and avoids the O(N^2) re-walk of every
/// other worker's copied tree.
///
/// A file whose path matches `copyExcluded` (a raw-prefix legacy filter owned by
/// the caller) is still skipped, so the copied set is byte-identical to the prior
/// full-walk behavior; an entry that escapes `src` by symlink is rejected. `src`
/// must be opened with `iterate = true`.
pub fn copyProjectTree(
    io: std.Io,
    gpa: std.mem.Allocator,
    src: std.Io.Dir,
    dst: std.Io.Dir,
    copyExcluded: *const fn (path: []const u8) bool,
) !void {
    var walker = try src.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            // Descend only into non-excluded dirs: never enter the cache / build
            // output / VCS trees. This removes the sibling-teardown race and the
            // O(N^2) re-walk that the prior full `walk()` suffered.
            if (!isExcludedDescentDir(entry.basename)) try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;
        if (copyExcluded(entry.path)) continue;
        if (config.pathEscapesRoot(io, src, entry.path)) return error.WorkspaceCreateFailed;
        try src.copyFile(entry.path, dst, entry.path, io, .{ .make_path = true });
    }
}

/// An isolated per-mutant workspace: the project-relative `rel` path and an open
/// handle `dir` to it. On success the caller owns both (close `dir`, deleteTree
/// `rel`).
pub const Workspace = struct { rel: []const u8, dir: std.Io.Dir };

/// Build an isolated per-mutant workspace under the run base: create the
/// content-addressed `{run_id}/{mutant_id}` dir, copy the project tree (minus
/// caches/VCS), and overwrite `mutant_file` with `patched`. Isolated by run +
/// content-addressed mutant id, so the developer working tree is never modified.
///
/// On ANY failure after the directory is created, the partial workspace is
/// unwound -- the fd is closed and the on-disk tree removed -- so no orphaned
/// `{mutant_id}` dir is left behind; if that removal itself fails, `cleanup_failures`
/// is bumped so the end-of-run warning stays truthful. Without this unwind the
/// caller's success-only cleanup defer never fired on the failure path, silently
/// leaking a partial dir and undercounting cleanup failures.
pub fn createMutantWorkspace(
    io: std.Io,
    arena: std.mem.Allocator,
    root_dir: std.Io.Dir,
    run_id: []const u8,
    mutant_id: []const u8,
    mutant_file: []const u8,
    patched: []const u8,
    cleanup_failures: *std.atomic.Value(u32),
    siblings: []const []const u8,
) !Workspace {
    const rel = try workspaceRoot(arena, run_id, mutant_id);
    if (config.pathEscapesRoot(io, root_dir, rel)) return error.WorkspaceCreateFailed;
    try root_dir.createDirPath(io, rel);
    // Unwind the on-disk workspace on ANY failure below. createDirPath just
    // materialized {rel}; the caller's deleteTree/cleanup defer is armed only
    // after this returns successfully, so without this a copyProjectTree /
    // containment / writeFile / openDir error would orphan a partial {mutant_id}
    // dir and leave it uncounted. A failed removal still bumps
    // cleanup_failures so the end-of-run warning stays truthful. errdefers unwind
    // in reverse, so the fd (closed just below) is released before this deleteTree.
    errdefer root_dir.deleteTree(io, rel) catch {
        _ = cleanup_failures.fetchAdd(1, .monotonic);
    };
    var dir = try root_dir.openDir(io, rel, .{});
    errdefer dir.close(io);

    // `project.workspace_siblings`: one link per entry in the run container, beside
    // every workspace of the run, so `../name` resolves from inside a copy. A sibling
    // worker may have placed it first, and the run-container deleteTree unlinks it
    // without following it.
    const run_base = try workspaceRunBase(arena, run_id);
    for (siblings) |entry| {
        const name = config.siblingName(entry) orelse return error.WorkspaceCreateFailed;
        const link = try std.fmt.allocPrint(arena, "{s}/{s}", .{ run_base, name });
        root_dir.symLink(io, try siblingLinkTarget(arena, name), link, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.WorkspaceCreateFailed,
        };
    }

    try copyProjectTree(io, arena, root_dir, dir, excludedCopyPath);
    if (config.pathEscapesRoot(io, dir, mutant_file)) return error.WorkspaceCreateFailed;
    // Ensure the mutated file's parent dir exists before the patched write:
    // `writeFile` does not create parents, so a missing parent would otherwise
    // fail the write and misclassify a real mutant as `invalid`.
    if (std.fs.path.dirname(mutant_file)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = mutant_file, .data = patched });
    return .{ .rel = rel, .dir = dir };
}
