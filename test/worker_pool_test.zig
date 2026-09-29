const std = @import("std");
const zentinel = @import("zentinel");

const wp = zentinel.worker_pool;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// --- Deterministic output independent of worker count ----------------------

const MapCtx = struct {
    results: []usize,
    calls: []std.atomic.Value(u32),
    max_slot: std.atomic.Value(usize),
};

fn squarePlus(ctx: *anyopaque, index: usize, slot: usize) void {
    const c: *MapCtx = @ptrCast(@alignCast(ctx));
    // Pure function of the index only: output cannot depend on scheduling.
    c.results[index] = index * index + 7;
    _ = c.calls[index].fetchAdd(1, .seq_cst);
    // Track the largest worker slot observed to confirm real lanes exist.
    var cur = c.max_slot.load(.seq_cst);
    while (slot > cur) {
        cur = c.max_slot.cmpxchgWeak(cur, slot, .seq_cst, .seq_cst) orelse break;
    }
}

fn runMap(a: std.mem.Allocator, jobs: usize, count: usize) ![]usize {
    const results = try a.alloc(usize, count);
    @memset(results, 0);
    const calls = try a.alloc(std.atomic.Value(u32), count);
    for (calls) |*c| c.* = std.atomic.Value(u32).init(0);
    var ctx = MapCtx{ .results = results, .calls = calls, .max_slot = std.atomic.Value(usize).init(0) };
    wp.run(jobs, count, &ctx, squarePlus);
    // Every index processed exactly once, regardless of worker count.
    for (calls) |*c| try expectEqual(@as(u32, 1), c.load(.seq_cst));
    return results;
}

test "worker count does not change the index-to-result mapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const count: usize = 200;
    const serial = try runMap(a, 1, count);
    const parallel = try runMap(a, 8, count);
    try expectEqual(serial.len, parallel.len);
    for (serial, parallel) |s, p| try expectEqual(s, p);
    // The serial mapping is exactly the pure function, proving order independence.
    for (serial, 0..) |v, i| try expectEqual(i * i + 7, v);
}

test "empty and single workloads run inline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zero = try runMap(a, 4, 0);
    try expectEqual(@as(usize, 0), zero.len);
    const one = try runMap(a, 4, 1);
    try expectEqual(@as(usize, 1), one.len);
    try expectEqual(@as(usize, 7), one[0]);
}

// --- Bounded, clamped worker count -----------------------------------------

test "effectiveJobs is clamped to [1, min(count, max_jobs)]" {
    try expectEqual(@as(usize, 1), wp.effectiveJobs(0, 10)); // non-positive clamps up to 1
    try expectEqual(@as(usize, 1), wp.effectiveJobs(4, 0)); // no work -> single
    try expectEqual(@as(usize, 4), wp.effectiveJobs(4, 10));
    try expectEqual(@as(usize, 10), wp.effectiveJobs(100, 10)); // never more workers than items
    try expectEqual(wp.max_jobs, wp.effectiveJobs(100000, 100000)); // bounded by the hard cap
    try expect(wp.effectiveJobs(100000, 100000) <= wp.max_jobs);
}

// --- Per-unit workspace isolation ------------------------------------------

test "each mutant gets a dedicated workspace with nested local cache and output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r1 = try wp.workspaceRoot(a, "run_xxxxxxxxxxxxxxxxxxx0", "m_aaaaaaaaaaaaaaaaaaaaaaaaaa");
    const r2 = try wp.workspaceRoot(a, "run_xxxxxxxxxxxxxxxxxxx0", "m_bbbbbbbbbbbbbbbbbbbbbbbbbb");
    // Distinct mutants never share a workspace root: no clobbering.
    try expect(!std.mem.eql(u8, r1, r2));

    const c1 = try wp.cacheDirIn(a, r1);
    const o1 = try wp.outDirIn(a, r1);
    // Local .zig-cache and zig-out live INSIDE the dedicated workspace root.
    try expect(std.mem.startsWith(u8, c1, r1));
    try expect(std.mem.startsWith(u8, o1, r1));
    try expect(std.mem.endsWith(u8, c1, ".zig-cache"));
    try expect(std.mem.endsWith(u8, o1, "zig-out"));

    // Two concurrent workers therefore never share a build cache or output dir.
    const c2 = try wp.cacheDirIn(a, r2);
    try expect(!std.mem.eql(u8, c1, c2));
}

test "every per-mutant workspaceRoot nests under the run's workspaceRunBase, scoped per run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The cli removes one run's whole container with a single
    // deleteTree(workspaceRunBase(run_id)); that only reclaims the leaked
    // per-mutant leaves if EVERY workspaceRoot for the run is nested under it.
    const base = try wp.workspaceRunBase(a, "run_xxxxxxxxxxxxxxxxxxx0");
    try expectEqualStrings(".zig-cache/zentinel/workspaces/run_xxxxxxxxxxxxxxxxxxx0", base);

    const prefix = try std.fmt.allocPrint(a, "{s}/", .{base});
    const r1 = try wp.workspaceRoot(a, "run_xxxxxxxxxxxxxxxxxxx0", "m_aaaaaaaaaaaaaaaaaaaaaaaaaa");
    const r2 = try wp.workspaceRoot(a, "run_xxxxxxxxxxxxxxxxxxx0", "m_bbbbbbbbbbbbbbbbbbbbbbbbbb");
    try expect(std.mem.startsWith(u8, r1, prefix));
    try expect(std.mem.startsWith(u8, r2, prefix));

    // The base is per-run: deleting one run's container cannot touch another's.
    const other = try wp.workspaceRunBase(a, "run_yyyyyyyyyyyyyyyyyyy1");
    try expect(!std.mem.eql(u8, base, other));
    try expect(!std.mem.startsWith(u8, r1, other));
}

// --- Tree copy skips DESCENT into excluded dirs -------------------

fn excludeNothing(path: []const u8) bool {
    _ = path;
    return false;
}

fn fileExists(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) bool {
    dir.access(io, sub_path, .{}) catch return false;
    return true;
}

test "copyProjectTree copies real files but never descends into .zig-cache/zig-out/.git" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // A project (`proj`) with real source at the root and nested, plus the three
    // excluded trees. A parallel run continually creates/deletes per-mutant
    // workspaces under `.zig-cache/zentinel/workspaces`, so a walker that descends
    // there races sibling teardown (spurious `invalid`) and re-walks every other
    // worker's copy (O(N^2)). The destination (`out`) is a sibling, never inside
    // the walked tree.
    try tmp.dir.createDirPath(io, "proj/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/keep.zig", .data = "pub const x = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/src/nested.zig", .data = "pub const y = 2;\n" });
    try tmp.dir.createDirPath(io, "proj/.zig-cache/zentinel/workspaces/run/m_other");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/.zig-cache/zentinel/workspaces/run/m_other/sibling.zig", .data = "pub const z = 3;\n" });
    try tmp.dir.createDirPath(io, "proj/zig-out/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/zig-out/bin/artifact.zig", .data = "pub const w = 4;\n" });
    try tmp.dir.createDirPath(io, "proj/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/.git/config", .data = "[core]\n" });

    var src = try tmp.dir.openDir(io, "proj", .{ .iterate = true });
    defer src.close(io);
    try tmp.dir.createDirPath(io, "out");
    var dst = try tmp.dir.openDir(io, "out", .{});
    defer dst.close(io);

    // The file-copy filter excludes NOTHING here, so the ONLY thing that can keep
    // an excluded-dir file out of the copy is the walker refusing to descend.
    try wp.copyProjectTree(io, a, src, dst, excludeNothing);

    // Real project files are copied -- descent into non-excluded dirs still works.
    try expect(fileExists(io, dst, "keep.zig"));
    try expect(fileExists(io, dst, "src/nested.zig"));
    // The excluded subtrees are never entered, so their files are absent even
    // though `excludeNothing` would have permitted copying them.
    try expect(!fileExists(io, dst, ".zig-cache/zentinel/workspaces/run/m_other/sibling.zig"));
    try expect(!fileExists(io, dst, "zig-out/bin/artifact.zig"));
    try expect(!fileExists(io, dst, ".git/config"));
}

test "copyProjectTree copies a sibling dir that only prefix-collides with an excluded dir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // `zig-outputs/` only PREFIX-collides with the excluded `zig-out`; its first
    // path segment differs, so discovery yields its sources and they must be
    // copied. The raw-prefix copyExcluded wrongly dropped such files, then the
    // patched write of a mutant in that dir failed (missing parent) and the mutant
    // was misclassified `invalid`. The genuinely-excluded `zig-out/` is still
    // skipped.
    try tmp.dir.createDirPath(io, "proj/zig-outputs");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/zig-outputs/foo.zig", .data = "pub const x = 1;\n" });
    try tmp.dir.createDirPath(io, "proj/zig-out/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/zig-out/bin/real.zig", .data = "pub const y = 2;\n" });

    var src = try tmp.dir.openDir(io, "proj", .{ .iterate = true });
    defer src.close(io);
    try tmp.dir.createDirPath(io, "out");
    var dst = try tmp.dir.openDir(io, "out", .{});
    defer dst.close(io);

    try wp.copyProjectTree(io, a, src, dst, wp.excludedCopyPath);

    try expect(fileExists(io, dst, "zig-outputs/foo.zig")); // prefix-collision sibling IS copied
    try expect(!fileExists(io, dst, "zig-out/bin/real.zig")); // the real excluded dir is NOT
}

test "excludedCopyPath matches the whole first path segment, not a raw prefix" {
    // Genuinely excluded: the first path segment equals an excluded dir name.
    try expect(wp.excludedCopyPath("zig-out/bin/app"));
    try expect(wp.excludedCopyPath(".zig-cache/o/x.zig"));
    try expect(wp.excludedCopyPath(".git/config"));
    // Prefix-colliding siblings are NOT excluded.
    try expect(!wp.excludedCopyPath("zig-outputs/foo.zig"));
    try expect(!wp.excludedCopyPath(".github/workflows/ci.zig"));
    try expect(!wp.excludedCopyPath(".gitlab/ci/gen.zig"));
    try expect(!wp.excludedCopyPath("src/zig-out-helper.zig"));
}

test "createMutantWorkspace unwinds the partial workspace dir when setup fails mid-way" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // A minimal project so copyProjectTree (which runs before the failure) succeeds.
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "pub const x = 1;\n" });

    var cleanup_failures = std.atomic.Value(u32).init(0);
    const run_id = "run_l9000000000000000000";
    const mutant_id = "m_l9aaaaaaaaaaaaaaaaaaaaaa";

    // mutant_file `../escape.zig` escapes the workspace dir, so createMutantWorkspace
    // fails at the post-copy containment check -- AFTER createDirPath + copyProjectTree
    // already materialized .zig-cache/zentinel/workspaces/{run_id}/{mutant_id}. The
    // failure-path errdefer must remove that partial dir; previously only the fd was
    // closed, orphaning it (and the caller's success-only cleanup defer never fired).
    const result = wp.createMutantWorkspace(io, a, tmp.dir, run_id, mutant_id, "../escape.zig", "x", &cleanup_failures, &.{});
    try std.testing.expectError(error.WorkspaceCreateFailed, result);

    // The partial per-mutant workspace leaf must NOT survive the failed setup.
    const rel = try wp.workspaceRoot(a, run_id, mutant_id);
    try expect(!fileExists(io, tmp.dir, rel));
    // The unwind deleteTree succeeded, so no cleanup failure was counted.
    try expectEqual(@as(u32, 0), cleanup_failures.load(.monotonic));
}

// --- Workspace siblings: `../name` resolves beside the per-mutant copy ------

test "createMutantWorkspace links each configured sibling beside the copy so ../name resolves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // A repo with two packages: `server` is the project root, `core` its sibling
    // that server's build.zig.zon names as `../core`.
    try tmp.dir.createDirPath(io, "repo/core");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/core/build.zig", .data = "pub const core = 1;\n" });
    try tmp.dir.createDirPath(io, "repo/server/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/server/src/main.zig", .data = "pub const x = 1;\n" });
    var root = try tmp.dir.openDir(io, "repo/server", .{ .iterate = true });
    defer root.close(io);

    var cleanup_failures = std.atomic.Value(u32).init(0);
    const run_id = "run_s1000000000000000000";
    const ws = try wp.createMutantWorkspace(io, a, root, run_id, "m_s1aaaaaaaaaaaaaaaaaaaaaa", "src/main.zig", "pub const x = 2;\n", &cleanup_failures, &.{"../core"});
    defer ws.dir.close(io);

    // From inside the workspace, `../core/build.zig` is the real sibling's file.
    const through = try ws.dir.readFileAlloc(io, "../core/build.zig", a, .limited(1 << 16));
    try expectEqualStrings("pub const core = 1;\n", through);
    // The link sits in the run container, beside the workspace, and IS a link:
    // nothing was copied, so a run with hundreds of mutants copies `core` zero times.
    const link = try std.fmt.allocPrint(a, "{s}/core", .{try wp.workspaceRunBase(a, run_id)});
    const st = try root.statFile(io, link, .{ .follow_symlinks = false });
    try expect(st.kind == .sym_link);
    // The target is relative and climbs exactly out of the run container to the
    // project's parent, so the link is valid wherever the checkout lives.
    try expectEqualStrings("../../../../../core", try wp.siblingLinkTarget(a, "core"));

    // A second mutant of the same run finds the link already there and succeeds.
    const ws2 = try wp.createMutantWorkspace(io, a, root, run_id, "m_s1bbbbbbbbbbbbbbbbbbbbbb", "src/main.zig", "pub const x = 3;\n", &cleanup_failures, &.{"../core"});
    defer ws2.dir.close(io);
    const through2 = try ws2.dir.readFileAlloc(io, "../core/build.zig", a, .limited(1 << 16));
    try expectEqualStrings("pub const core = 1;\n", through2);

    // One deleteTree of the run container reclaims both workspaces AND the link,
    // and never follows the link into the real sibling.
    try root.deleteTree(io, try wp.workspaceRunBase(a, run_id));
    try expect(fileExists(io, tmp.dir, "repo/core/build.zig"));
    try expect(!fileExists(io, root, link));
}

// --- Every item runs even when some fail (visible per-index propagation) ----

const FailCtx = struct { status: []u8, fail_at: usize };

fn maybeFail(ctx: *anyopaque, index: usize, slot: usize) void {
    _ = slot;
    const c: *FailCtx = @ptrCast(@alignCast(ctx));
    c.status[index] = if (index == c.fail_at) 1 else 0;
}

// --- Deterministic scheduling evidence (committed fixture) ------------------

test "scheduling evidence fixture matches the deterministic workspace layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const evidence = @embedFile("fixtures/worker_pool/scheduling_evidence.json");
    try expect(std.mem.indexOf(u8, evidence, "independent of worker count") != null);

    // The committed isolation evidence must match what the module actually
    // produces, so the recorded schedule cannot drift from the implementation.
    const ws_a = try wp.workspaceRoot(a, "run_evidence0000000000000", "m_aaaaaaaaaaaaaaaaaaaaaaaaaa");
    const ws_b = try wp.workspaceRoot(a, "run_evidence0000000000000", "m_bbbbbbbbbbbbbbbbbbbbbbbbbb");
    const cache_a = try wp.cacheDirIn(a, ws_a);
    const out_a = try wp.outDirIn(a, ws_a);
    try expect(std.mem.indexOf(u8, evidence, ws_a) != null);
    try expect(std.mem.indexOf(u8, evidence, ws_b) != null);
    try expect(std.mem.indexOf(u8, evidence, cache_a) != null);
    try expect(std.mem.indexOf(u8, evidence, out_a) != null);
}

test "a failing unit is visible at its index and never drops other units" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const count: usize = 50;
    const status = try a.alloc(u8, count);
    @memset(status, 0xff);
    var ctx = FailCtx{ .status = status, .fail_at = 17 };
    wp.run(6, count, &ctx, maybeFail);

    for (status, 0..) |s, i| {
        if (i == 17) {
            try expectEqual(@as(u8, 1), s); // the failing unit's status propagated
        } else {
            try expectEqual(@as(u8, 0), s); // every other unit still ran
        }
    }
}

// --- LockedAllocator: concurrent allocation from a shared arena (BLOCKER) ----

const AllocCtx = struct {
    gpa: std.mem.Allocator,
    bufs: [][]u8,
};

// Each unit allocates a distinct-sized buffer through the shared allocator and
// fills every byte with a per-index marker. Run across many workers, this drives
// concurrent allocation through one underlying arena -- which is undefined
// behavior on a raw (non-thread-safe) arena, but sound once routed through
// LockedAllocator. Torn/overlapping allocations would corrupt a neighbor's
// bytes and fail the post-run integrity check below.
fn allocAndFill(ctx: *anyopaque, index: usize, slot: usize) void {
    _ = slot;
    const c: *AllocCtx = @ptrCast(@alignCast(ctx));
    const len = (index % 64) + 16;
    const buf = c.gpa.alloc(u8, len) catch @panic("alloc failed");
    @memset(buf, @as(u8, @truncate(index)));
    c.bufs[index] = buf;
}

test "LockedAllocator serializes concurrent allocation from a non-thread-safe arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The bufs slice itself is allocated up front (single-threaded) so workers
    // only ever touch their own disjoint slot.
    const count: usize = 500;
    const bufs = try arena.allocator().alloc([]u8, count);

    var locked = wp.LockedAllocator{ .child = arena.allocator() };
    var ctx = AllocCtx{ .gpa = locked.allocator(), .bufs = bufs };
    wp.run(8, count, &ctx, allocAndFill);

    for (bufs, 0..) |buf, i| {
        try expectEqual((i % 64) + 16, buf.len);
        for (buf) |byte| try expectEqual(@as(u8, @truncate(i)), byte);
    }

    // The guard must actually have run: each of the `count` allocations enters one
    // critical section, so at least `count` acquisitions were recorded. If the lock
    // were removed (reintroducing the data race the test exists to catch), `lock`
    // would never run and this counter would be 0 -- so this assertion is what makes
    // the race test able to FAIL on lock removal rather than merely (usually) pass.
    try expect(locked.acquisitions.load(.monotonic) >= count);
}
