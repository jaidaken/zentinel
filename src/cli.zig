// Layer: presentation_adapter
const std = @import("std");
const zentinel = @import("zentinel");

// Derive the adapter's config path from the core's single source of truth
// (`zentinel.config_default_path`) rather than a private duplicate literal, so
// `init`'s write path and the config-existence probe can never silently diverge
// from the path the rest of the system resolves config from.
const config_path = zentinel.config_default_path;
const read_limit = std.Io.Limit.limited(1 << 20);

/// Thin presentation adapter. Pure decision logic lives in the zentinel core:
/// `zentinel.route` decides how to handle argv, `zentinel.dispatch` owns the
/// frozen Phase 0 commands, and `zentinel.check_command`/`zentinel.zig_version`
/// own check and version-policy logic. The adapter performs the I/O the core
/// cannot: resolving config existence, reading config bytes, running
/// `zig version`, and writing output.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    parent_env: *const std.process.Environ.Map,
) !u8 {
    switch (zentinel.route(args)) {
        .passthrough => return runPassthrough(gpa, io, dir, args, stdout, stderr),
        .version => {
            // stdout stays the policy-only version text; discovered Zig status
            // is environment information on stderr and never makes `version` fatal.
            try stdout.writeAll(zentinel.version_text);
            if (try zentinel.zig_version.statusLine(gpa, discoverZig(gpa, io))) |line| {
                try stderr.print("{s}\n", .{line});
            }
            return 0;
        },
        .check => |globals| {
            const resolved = (try configPathOrReject(gpa, io, dir, globals, stderr)) orelse return 2;
            const result = try zentinel.check_command.run(gpa, .{
                .config_source = readResolvedConfig(gpa, io, dir, resolved),
                .config_path = resolved,
                .zig = discoverZig(gpa, io),
            });
            if (result.stdout.len > 0) try stdout.writeAll(result.stdout);
            if (result.code.len > 0) {
                try stderr.print("error[{s}]: {s}\n", .{ result.code, result.message });
            } else if (result.message.len > 0) {
                try stderr.print("{s}\n", .{result.message});
            }
            return result.exit_code;
        },
        .run => |inv| return runRun(gpa, io, dir, inv, stdout, stderr, parent_env),
        .list_mutants => |inv| return runListMutants(gpa, io, dir, inv, stdout, stderr),
        .doctest => |inv| return runDoctest(gpa, io, dir, inv, stdout, stderr, parent_env),
        .explain => |inv| return runAiCommand(gpa, io, dir, inv, .explain, stdout, stderr),
        .suggest => |inv| return runAiCommand(gpa, io, dir, inv, .suggest, stdout, stderr),
        .review_tests => |inv| return runAiCommand(gpa, io, dir, inv, .review_tests, stdout, stderr),
        .command_help => |topic| {
            // `<command> --help`: deterministic usage block on stdout, exit 0,
            // before any command-local option parsing (docs/CLI_SPEC.md).
            try stdout.writeAll(zentinel.commandHelpText(topic));
            return 0;
        },
    }
}

/// Phase 0 commands (help/version-policy/init/unknown/not-implemented) plus the
/// invalid-option diagnostics owned by the frozen `dispatch`.
fn runPassthrough(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const config_exists = blk: {
        dir.access(io, config_path, .{}) catch break :blk false;
        break :blk true;
    };

    const outcome = zentinel.dispatch(args, config_exists);

    if (outcome.stdout.len > 0) try stdout.writeAll(outcome.stdout);

    if (outcome.error_code != .none) {
        try stderr.print("error[{s}]: {s}\n", .{ outcome.error_code.token(), outcome.detail });
    } else if (outcome.stderr.len > 0) {
        try stderr.writeAll(outcome.stderr);
    }

    if (outcome.write_config) {
        if (zentinel.config.pathEscapesRoot(io, dir, config_path)) {
            try stderr.writeAll("error: zentinel.toml must stay within the project root\n");
            return 2;
        }
        const name = inferProjectName(gpa, io, dir, outcome.init_name);
        const text = try zentinel.initConfigText(gpa, outcome.init_test_command, name);
        try dir.writeFile(io, .{ .sub_path = config_path, .data = text });
    }

    return outcome.exit_code;
}

/// Resolve the `[project] name` for a freshly written init config: an explicit
/// `--name` wins; otherwise the `.name` field of `build.zig.zon` in the project
/// root; otherwise the project root directory's basename. Returns null -- which
/// keeps the template's `"example"` -- when no candidate is embeddable in
/// zentinel's escape-free TOML. Inference is best-effort: any read failure
/// falls through to the next source rather than failing `init`.
fn inferProjectName(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, explicit: ?[]const u8) ?[]const u8 {
    if (explicit) |name| return name; // dispatchInit already validated embeddability
    if (dir.readFileAlloc(io, "build.zig.zon", gpa, read_limit) catch null) |zon| {
        if (zentinel.projectNameFromZon(zon)) |name| {
            if (zentinel.projectNameEmbeddable(name)) return name;
        }
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // Resolve "." relative to the handle rather than realPath on the handle
    // itself: the process-cwd handle is the AT_FDCWD pseudo-fd on POSIX, which
    // has no path of its own.
    const len = dir.realPathFile(io, ".", &buf) catch return null;
    const base = std.fs.path.basename(buf[0..len]);
    if (!zentinel.projectNameEmbeddable(base)) return null;
    return gpa.dupe(u8, base) catch null;
}

/// Resolve the config path, writing a clear error and returning null when an
/// explicit `--config` escapes the project root (F-5). The caller exits 2 on null.
fn configPathOrReject(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, globals: zentinel.Globals, stderr: *std.Io.Writer) !?[]const u8 {
    const resolved = zentinel.resolveConfigPathForRoot(gpa, globals) catch |e| switch (e) {
        error.ConfigOutsideRoot => {
            try stderr.writeAll("error[ZNTL_CLI_INVALID_OPTION]: --config must stay within the project root\n");
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (std.fs.path.isAbsolute(globals.root)) {
        var root_dir = dir.openDir(io, globals.root, .{ .iterate = true }) catch return resolved;
        defer root_dir.close(io);
        if (zentinel.config.pathEscapesRoot(io, root_dir, globals.config_path)) {
            try stderr.writeAll("error[ZNTL_CLI_INVALID_OPTION]: --config must stay within the project root\n");
            return null;
        }
    } else {
        if (zentinel.config.pathEscapesRoot(io, dir, resolved)) {
            try stderr.writeAll("error[ZNTL_CLI_INVALID_OPTION]: --config must stay within the project root\n");
            return null;
        }
    }
    return resolved;
}

/// Read the resolved config bytes, or null on any read failure.
///
/// Precondition: `path` MUST already have been validated by `configPathOrReject`
/// (every caller resolves through it). That guard enforced root containment of
/// the relative `--config` component against the selected root -- including the
/// absolute-root case, where the relative config path was checked against the
/// opened absolute root dir. An absolute `path` here is therefore an already-
/// approved absolute-root read and is read directly: a `pathEscapesRoot` re-check
/// is impossible (it rejects ALL absolute paths via `isOutsideRoot`, which would
/// break legitimate absolute-root reads). A relative `path` keeps its defensive
/// containment re-check against `dir`.
fn readResolvedConfig(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ?[]const u8 {
    if (std.fs.path.isAbsolute(path)) return dir.readFileAlloc(io, path, gpa, read_limit) catch null;
    if (zentinel.config.pathEscapesRoot(io, dir, path)) return null;
    return dir.readFileAlloc(io, path, gpa, read_limit) catch null;
}

/// Run `zig version` and classify the result. Any failure to obtain a version
/// (executable missing, non-zero exit, empty output) is reported as not found.
fn discoverZig(gpa: std.mem.Allocator, io: std.Io) zentinel.zig_version.Discovery {
    const result = zentinel.exec.run(gpa, io, .{
        .argv = &.{ "zig", "version" },
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(5000), .clock = .awake } },
    }) catch return .not_found;
    switch (result.term) {
        .exited => |code| if (code != 0) return .not_found,
        else => return .not_found,
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return .not_found;
    return .{ .version = trimmed };
}

// --- `zentinel run` (Phase 1) ----------------------------------------------

const run_output_limit = std.Io.Limit.limited(1 << 20);

/// Above this mutant count, a serial (`--jobs 1`) run is slow enough that the
/// one-line `--jobs` discoverability hint is worth emitting on stderr. Advisory
/// only; the configured `run.jobs` default stays 1.
const jobs_hint_threshold: u64 = 50;

/// Side-effect context shared by the real baseline and mutant executors. The
/// deterministic orchestration (zentinel.run_command) stays pure; this adapter
/// provides the process execution and per-mutant filesystem workspaces that
/// docs/SANDBOX_SECURITY.md mandates.
const RunCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    /// Stable cwd label recorded in the report (never a raw workspace path).
    root_label: []const u8,
    run_id: []const u8,
    timeout: std.Io.Timeout,
    /// The minimal command environment actually passed to every spawned test
    /// command (docs/SANDBOX_SECURITY.md). This is what makes the report's
    /// `environment_policy = minimal` label truthful.
    env: *const std.process.Environ.Map,
    cleanup_failures: std.atomic.Value(u32),
};

/// Run one configured command via direct argv (no shell), honoring the
/// configured timeout. Spawn/exec failures and timeouts are mapped onto the
/// runner's raw-outcome contract so the deterministic classifier owns the verdict.
/// Wall-clock milliseconds elapsed since `start_ms` (a real-clock millisecond
/// reading). Clamped to >= 0 so a backward clock step can never produce a negative
/// or huge unsigned duration. Report comparisons normalize durations
/// (docs/REPORT_FORMAT.md "Repeated-Run Comparison"), so real timings here stay
/// deterministic for snapshot/dogfood checks.
fn elapsedMs(io: std.Io, start_ms: i64) u64 {
    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    return @intCast(@max(0, now_ms - start_ms));
}

fn execProcess(rt: *RunCtx, argv: []const []const u8, cwd: std.process.Child.Cwd) zentinel.runner.RawOutcome {
    const start_ms = std.Io.Timestamp.now(rt.io, .real).toMilliseconds();
    const result = zentinel.exec.run(rt.gpa, rt.io, .{
        .argv = argv,
        .cwd = cwd,
        .stdout_limit = run_output_limit,
        .stderr_limit = run_output_limit,
        .timeout = rt.timeout,
        // Restrict each test command to the documented minimal allowlist
        // (PATH/HOME/TMPDIR/ZIG caches + LC_ALL=C/LANG=C), so the report's
        // `environment_policy = minimal` label is truthful
        // (docs/SANDBOX_SECURITY.md). Phase 1 still cannot fully OS-sandbox.
        .environ_map = rt.env,
    }) catch |err| {
        const dur = elapsedMs(rt.io, start_ms);
        if (err == error.Timeout) {
            return .{ .exit_code = null, .timed_out = true, .crashed = false, .duration_ms = dur, .stdout = "", .stderr = "" };
        }
        return .{ .exit_code = null, .timed_out = false, .crashed = true, .duration_ms = dur, .stdout = "", .stderr = "" };
    };
    const dur = elapsedMs(rt.io, start_ms);
    return switch (result.term) {
        .exited => |code| .{
            .exit_code = @as(i64, code),
            .timed_out = false,
            .crashed = false,
            .duration_ms = dur,
            .stdout = result.stdout,
            .stderr = result.stderr,
        },
        // A signal/stop/unknown termination is a crash, not a test failure.
        else => .{
            .exit_code = null,
            .timed_out = false,
            .crashed = true,
            .duration_ms = dur,
            .stdout = result.stdout,
            .stderr = result.stderr,
        },
    };
}

fn baselineRunFn(ctx: *anyopaque, argv: []const []const u8) zentinel.runner.RawOutcome {
    const rt: *RunCtx = @ptrCast(@alignCast(ctx));
    return execProcess(rt, argv, .{ .dir = rt.root_dir });
}

/// A placeholder executor for paths where the deterministic runner returns
/// before executing any command (invalid patch / workspace-creation failure).
fn unusedRunFn(ctx: *anyopaque, argv: []const []const u8) zentinel.runner.RawOutcome {
    _ = ctx;
    _ = argv;
    return .{ .exit_code = null, .timed_out = false, .crashed = true, .duration_ms = 0, .stdout = "", .stderr = "" };
}

const WorkspaceCtx = struct { rt: *RunCtx, dir: std.Io.Dir };

fn workspaceRunFn(ctx: *anyopaque, argv: []const []const u8) zentinel.runner.RawOutcome {
    const w: *WorkspaceCtx = @ptrCast(@alignCast(ctx));
    return execProcess(w.rt, argv, .{ .dir = w.dir });
}

const Workspace = zentinel.worker_pool.Workspace;

/// Build an isolated per-mutant workspace under the zentinel-controlled cache
/// location: copy the project tree (minus caches/VCS), then overwrite the
/// mutated file with the patched bytes. Isolated by run + content-addressed
/// mutant id, so the developer working tree is never modified. The workspace
/// lifecycle (creation + failure-path unwind) lives in worker_pool beside
/// the workspace path helpers; on success the caller owns `ws.dir`/`ws.rel`.
fn setupWorkspace(rt: *RunCtx, m: zentinel.mutant.Mutant, patched: []const u8) !Workspace {
    return zentinel.worker_pool.createMutantWorkspace(rt.io, rt.gpa, rt.root_dir, rt.run_id, m.id, m.file, patched, &rt.cleanup_failures);
}

/// Number of times to attempt the per-mutant workspace copy before giving up.
const workspace_setup_attempts: usize = 3;

/// Materialize the workspace, retrying a transient failure a few times. The
/// per-mutant whole-tree copy can hit transient FS pressure (EMFILE/ENFILE from
/// many concurrent workers, a racing external process); the failed attempt
/// already unwinds its partial dir, so a retry starts clean. Between attempts we
/// yield so sibling workers can finish/close their handles. Only after the
/// attempts are exhausted does the caller classify the mutant `invalid` -- without
/// this a momentary FS hiccup silently drops a would-be survivor.
fn setupWorkspaceRetrying(rt: *RunCtx, m: zentinel.mutant.Mutant, patched: []const u8) !Workspace {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        return setupWorkspace(rt, m, patched) catch |err| {
            if (attempt + 1 >= workspace_setup_attempts) return err;
            std.Thread.yield() catch {};
            continue;
        };
    }
}

/// The per-run workspace container parent: every run's `workspaceRunBase`
/// (`.zig-cache/zentinel/workspaces/{run_id}`) is a direct child. Mirrors the
/// `zig_cache_namespace` label in `buildObservation`.
const workspaces_parent = ".zig-cache/zentinel/workspaces";

/// Best-effort sweep of stale `run_*` workspace containers left by interrupted
/// runs (a SIGINT/crash before the end-of-run `deleteTree(run_base)`), which
/// otherwise accumulate one full-tree copy each under the controlled cache
/// namespace. The current run's `run_id` is skipped so an in-flight sibling run
/// is never disturbed. Every step is catch-ignored: a missing parent (first run),
/// an unreadable entry, or a failed delete must never affect the run -- a stale
/// dir that survives is reclaimed on a later run. Only `run_*`-prefixed children
/// are removed, so unrelated entries under the namespace are left intact.
fn sweepStaleRunWorkspaces(io: std.Io, root_dir: std.Io.Dir, current_run_id: []const u8) void {
    var parent = root_dir.openDir(io, workspaces_parent, .{ .iterate = true }) catch return;
    defer parent.close(io);
    var it = parent.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, "run_")) continue;
        if (std.mem.eql(u8, entry.name, current_run_id)) continue;
        // `entry.name` slices the iterator buffer (invalidated by the next
        // `it.next`), so delete it immediately within this iteration.
        parent.deleteTree(io, entry.name) catch continue;
    }
}

/// Terminal `.invalid` result for a single mutant when this worker hits OOM
/// (C3). A worker task that `@panic`s aborts the whole process and skips every
/// deferred workspace cleanup; classifying the one mutant `.invalid` instead
/// lets the run finish and its cleanup defers fire. The `sandbox:` prefix
/// satisfies the report validator's `.invalid` failure-summary contract
/// (report.zig invalidSummaryOk); the static summary needs no allocation, which
/// is exactly what an OOM path must avoid. `runModesFn` mirrors this with
/// `out[k] = .invalid`.
fn oomInvalidResult(m: zentinel.mutant.Mutant, mode: zentinel.report.Mode) zentinel.mutant_runner.MutationResult {
    return .{
        .mutant_id = m.id,
        .status = .invalid,
        .mode = mode,
        .classifier_source = .sandbox_validation,
        .commands = &.{},
        .evidence = .{ .failure_summary = "sandbox: out of memory while running mutant" },
        .skip_reason = null,
    };
}

/// The `runFn` entry the `MutantRunner` contract requires as a mandatory field.
/// UNREACHABLE in the binary: the adapter always supplies `runSpecsFn` and
/// `runModesFn` too (see the `MutantRunner` built in `runRun`), and
/// `run_command.MutantRunner.runSpecs`/`runModes` only fall back to `runFn` when
/// those are null. It exists to satisfy the mandatory field and to back
/// runFn-only test executors that drive the parse-then-runSpecs path. It parses
/// each command string to argv, then delegates to `mutantRunSpecsFn`.
fn mutantRunFn(
    ctx: *anyopaque,
    m: zentinel.mutant.Mutant,
    source: []const u8,
    commands: []const []const u8,
    mode: zentinel.report.Mode,
) zentinel.mutant_runner.MutationResult {
    const rt: *RunCtx = @ptrCast(@alignCast(ctx));
    var specs: std.ArrayList(zentinel.command.Spec) = .empty;
    for (commands) |original| {
        const argv = switch (zentinel.command.parse(rt.gpa, original) catch return oomInvalidResult(m, mode)) {
            .ok => |a| a,
            .invalid => return zentinel.mutant_runner.run(rt.gpa, m, source, .created, commands, rt.root_label, zentinel.runner.Executor{ .ctx = rt, .runFn = unusedRunFn }, mode) catch return oomInvalidResult(m, mode),
        };
        specs.append(rt.gpa, .{ .original = original, .argv = argv }) catch return oomInvalidResult(m, mode);
    }
    return mutantRunSpecsFn(ctx, m, source, specs.items, mode);
}

fn mutantRunSpecsFn(
    ctx: *anyopaque,
    m: zentinel.mutant.Mutant,
    source: []const u8,
    commands: []const zentinel.command.Spec,
    mode: zentinel.report.Mode,
) zentinel.mutant_runner.MutationResult {
    const rt: *RunCtx = @ptrCast(@alignCast(ctx));
    const disabled = zentinel.runner.Executor{ .ctx = rt, .runFn = unusedRunFn };

    // Compute patched bytes up front; an invalid patch is classified by the
    // deterministic runner (which re-validates and returns without executing).
    // An OOM in any classification step is downgraded to a single `.invalid`
    // mutant (oomInvalidResult) instead of a process-aborting panic (C3).
    const patched = zentinel.sandbox.apply(rt.gpa, source, m) catch {
        return zentinel.mutant_runner.runSpecs(rt.gpa, m, source, .created, commands, rt.root_label, disabled, mode) catch return oomInvalidResult(m, mode);
    };
    const ws = setupWorkspaceRetrying(rt, m, patched) catch {
        return zentinel.mutant_runner.runSpecs(rt.gpa, m, source, .create_failed, commands, rt.root_label, disabled, mode) catch return oomInvalidResult(m, mode);
    };
    defer {
        ws.dir.close(rt.io);
        rt.root_dir.deleteTree(rt.io, ws.rel) catch {
            _ = rt.cleanup_failures.fetchAdd(1, .monotonic);
        };
    }
    var wctx = WorkspaceCtx{ .rt = rt, .dir = ws.dir };
    const executor = zentinel.runner.Executor{ .ctx = &wctx, .runFn = workspaceRunFn };
    return zentinel.mutant_runner.runSpecs(rt.gpa, m, source, .created, commands, rt.root_label, executor, mode) catch return oomInvalidResult(m, mode);
}

/// Run one mutant across `modes` in a SINGLE materialized workspace: the
/// patched source is build-mode-independent, so the workspace (and its copied
/// tree) is created once and every mode -- plus an optional per-mode configured
/// reverification -- executes against it, instead of re-copying the project tree
/// per mode. Mirrors `mutantRunSpecsFn`'s validate/create/cleanup contract; called
/// once per mutant under the worker pool, so workspaces stay content-addressed and
/// isolated exactly as in Phase B. `out.len == modes.len`.
fn mutantRunModesFn(
    ctx: *anyopaque,
    m: zentinel.mutant.Mutant,
    source: []const u8,
    specs: []const zentinel.command.Spec,
    reverify_specs: []const zentinel.command.Spec,
    modes: []const zentinel.report.Mode,
    out: []zentinel.report.ResultStatus,
) void {
    const rt: *RunCtx = @ptrCast(@alignCast(ctx));
    const disabled = zentinel.runner.Executor{ .ctx = rt, .runFn = unusedRunFn };
    // An OOM in any per-mode classification writes `.invalid` for that mode and
    // returns normally (C3), so a worker never aborts the process and the
    // workspace-cleanup defer still fires. Mirrors oomInvalidResult's status.
    const patched = zentinel.sandbox.apply(rt.gpa, source, m) catch {
        // Invalid patch: the runner re-validates and classifies each mode invalid.
        for (modes, 0..) |mode, k| out[k] = if (zentinel.mutant_runner.runSpecs(rt.gpa, m, source, .created, specs, rt.root_label, disabled, mode)) |r| r.status else |_| .invalid;
        return;
    };
    const ws = setupWorkspaceRetrying(rt, m, patched) catch {
        for (modes, 0..) |mode, k| out[k] = if (zentinel.mutant_runner.runSpecs(rt.gpa, m, source, .create_failed, specs, rt.root_label, disabled, mode)) |r| r.status else |_| .invalid;
        return;
    };
    defer {
        ws.dir.close(rt.io);
        rt.root_dir.deleteTree(rt.io, ws.rel) catch {
            _ = rt.cleanup_failures.fetchAdd(1, .monotonic);
        };
    }
    var wctx = WorkspaceCtx{ .rt = rt, .dir = ws.dir };
    const executor = zentinel.runner.Executor{ .ctx = &wctx, .runFn = workspaceRunFn };
    for (modes, 0..) |mode, k| {
        const narrowed = zentinel.mutant_runner.runSpecs(rt.gpa, m, source, .created, specs, rt.root_label, executor, mode) catch {
            out[k] = .invalid;
            continue;
        };
        out[k] = if (narrowed.status == .survived and reverify_specs.len > 0)
            (if (zentinel.mutant_runner.runSpecs(rt.gpa, m, source, .created, reverify_specs, rt.root_label, executor, mode)) |r| r.status else |_| .invalid)
        else
            narrowed.status;
    }
}

/// Build the run observation metadata (run id, ISO timestamp, config hash).
fn buildObservation(gpa: std.mem.Allocator, io: std.Io, cfg_bytes: []const u8, zig_label: []const u8, root_label: []const u8) !zentinel.run_command.Observation {
    const ts = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const run_id = try zentinel.allocRunId(gpa, io, "run", ts);

    const started_at = try zentinel.report.isoTimestamp(gpa, ts);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(cfg_bytes, &digest, .{});
    const config_hash = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});

    return .{
        .run_id = run_id,
        .started_at = started_at,
        .project_root = root_label,
        .zentinel_version = zentinel.version,
        .zig_version = zig_label,
        .config_hash = config_hash,
        // Normalized Zig cache namespace label: per-mutant workspaces are
        // isolated under this controlled location (docs/SANDBOX_SECURITY.md).
        .zig_cache_namespace = ".zig-cache/zentinel/workspaces",
        .duration_ms = 0,
    };
}

fn timeoutFromMs(ms: i64) std.Io.Timeout {
    if (ms <= 0) return .none;
    // `.awake` excludes suspend time; `exec.run` resolves this duration to an
    // absolute deadline once, so it bounds wall time and not per-read idle time.
    return .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(ms), .clock = .awake } };
}

const EffectiveProjectRoot = struct {
    selected: std.Io.Dir,
    nested: ?std.Io.Dir = null,

    fn dir(self: EffectiveProjectRoot) std.Io.Dir {
        return self.nested orelse self.selected;
    }

    fn close(self: *EffectiveProjectRoot, io: std.Io) void {
        if (self.nested) |*nested| nested.close(io);
        self.selected.close(io);
    }
};

fn openEffectiveProjectRoot(
    io: std.Io,
    dir: std.Io.Dir,
    selected_root: []const u8,
    project_root: []const u8,
    stderr: *std.Io.Writer,
) !?EffectiveProjectRoot {
    var selected = try dir.openDir(io, selected_root, .{ .iterate = true });
    errdefer selected.close(io);
    if (std.mem.eql(u8, project_root, ".")) return .{ .selected = selected };
    if (zentinel.config.pathEscapesRoot(io, selected, project_root)) {
        try stderr.writeAll("error[ZNTL_CONFIG_INVALID_VALUE]: project.root must stay within the selected root\n");
        return null;
    }
    const nested = selected.openDir(io, project_root, .{ .iterate = true }) catch |err| {
        try stderr.print("error[ZNTL_CONFIG_INVALID_VALUE]: could not open project.root {s}: {s}\n", .{ project_root, @errorName(err) });
        return null;
    };
    return .{ .selected = selected, .nested = nested };
}

fn defaultLoadedConfig(arena: std.mem.Allocator) !zentinel.config.Config {
    var diag: zentinel.config.Diagnostic = .{};
    return zentinel.config.load(arena, "", &diag) catch |err| switch (err) {
        error.Invalid => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn doctestConfigOrDefault(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    globals: zentinel.Globals,
    stderr: *std.Io.Writer,
) !?zentinel.config.Config {
    const resolved = (try configPathOrReject(arena, io, dir, globals, stderr)) orelse return null;
    const bytes = readResolvedConfig(arena, io, dir, resolved) orelse {
        if (globals.config_explicit) {
            try stderr.print("error[ZNTL_CONFIG_NOT_FOUND]: config not found at {s}\n", .{resolved});
            return null;
        }
        return try defaultLoadedConfig(arena);
    };
    var diag: zentinel.config.Diagnostic = .{};
    return zentinel.config.load(arena, bytes, &diag) catch |err| switch (err) {
        error.Invalid => {
            if (globals.config_explicit) {
                try stderr.print("error[{s}]: {s}\n", .{ diag.code.token(), diag.message });
                return null;
            }
            return try defaultLoadedConfig(arena);
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// Per-mutant progress sink for `zentinel run` (docs/CLI_SPEC.md): one line per
/// completed mutant on STDERR only, so stdout stays reserved for the selected
/// `--report` rendering. Worker threads notify concurrently under `--jobs > 1`,
/// so writes are serialized with the same spinlock discipline as
/// worker_pool.LockedAllocator (std.Io.Writer is not thread-safe). Each line is
/// flushed immediately -- progress that sits in a 4 KiB buffer until process
/// exit would defeat its purpose.
const ProgressSink = struct {
    stderr: *std.Io.Writer,
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn notify(ctx: *anyopaque, completed: usize, total: usize, event: zentinel.run_command.ProgressEvent) void {
        const self: *ProgressSink = @ptrCast(@alignCast(ctx));
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
        defer self.locked.store(false, .release);
        // Progress is advisory; a write failure must never affect the run.
        self.stderr.print("[{d}/{d}] {s} {s} {s}:{d}\n", .{
            completed,
            total,
            @tagName(event.status),
            event.operator,
            event.file,
            event.line,
        }) catch return;
        self.stderr.flush() catch return;
    }
};

/// Split a comma-separated `--scope-files` value into trimmed, non-empty
/// project-relative paths.
fn splitScopeCsv(gpa: std.mem.Allocator, csv: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t\r\n");
        if (p.len == 0) continue;
        try list.append(gpa, p);
    }
    return list.toOwnedSlice(gpa);
}

/// Changed project-relative files per git, newline-split. `base` is the comparison
/// point: "HEAD" for tracked working-tree+index changes (`--changed-only`) or an
/// explicit ref (`--diff <ref>`). `--relative` makes git emit paths relative to the
/// project root so they match discovered source paths. Untracked new files are not
/// reported by `git diff`; `--scope-files` covers that case.
fn gitChangedFiles(gpa: std.mem.Allocator, io: std.Io, root_dir: std.Io.Dir, base: []const u8) ![]const []const u8 {
    const result = zentinel.exec.run(gpa, io, .{
        // `--end-of-options` immediately before `base` stops git from
        // interpreting a ref that begins with `-` as an option. A trailing `--`
        // would NOT help: it only separates pathspecs that follow it, not the
        // revision argument before it.
        .argv = &.{ "git", "diff", "--name-only", "--relative", "--end-of-options", base },
        .cwd = .{ .dir = root_dir },
        .stdout_limit = run_output_limit,
        .stderr_limit = run_output_limit,
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(10000), .clock = .awake } },
    }) catch return error.GitUnavailable;
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, result.stdout, '\n');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t\r\n");
        if (p.len == 0) continue;
        try list.append(gpa, try gpa.dupe(u8, p));
    }
    return list.toOwnedSlice(gpa);
}

/// Keep the discovered source paths that appear in `changed`. A changed file
/// outside the include globs (a doc, a build script) has no candidates anyway, so
/// intersecting against discovered files is what bounds mutation to eligible code.
fn intersectScope(gpa: std.mem.Allocator, changed: []const []const u8, files: []const zentinel.run_command.FileSource) ![]const []const u8 {
    var set = std.StringHashMap(void).init(gpa);
    defer set.deinit();
    for (changed) |c| try set.put(c, {});
    var list: std.ArrayList([]const u8) = .empty;
    for (files) |f| {
        if (set.contains(f.path)) try list.append(gpa, f.path);
    }
    return list.toOwnedSlice(gpa);
}

/// Resolve the diff-scope CLI inputs into `opts.scope_files` (the project-relative
/// set the deterministic core filters candidates by). Git runs HERE in the adapter,
/// never in the core (I-022). Returns a non-null exit code the caller should return
/// on a git error; null means resolution succeeded -- the scope set was set, or left
/// null when no scope flag was given so the run stays unscoped (today's behavior).
fn resolveScopeFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    opts: *zentinel.run_command.Options,
    files: []const zentinel.run_command.FileSource,
    stderr: *std.Io.Writer,
) !?u8 {
    var scope: []const []const u8 = undefined;
    if (opts.scope_files_csv) |csv| {
        scope = try intersectScope(gpa, try splitScopeCsv(gpa, csv), files);
    } else if (opts.changed_only or opts.diff_base != null) {
        const base = opts.diff_base orelse "HEAD";
        const changed = gitChangedFiles(gpa, io, root_dir, base) catch |err| {
            try stderr.print("error[ZNTL_DIFF_SCOPE_FAILED]: could not derive changed files from git ({s}); is this a git repository? use --scope-files to pass an explicit list\n", .{@errorName(err)});
            try stderr.flush();
            return 2;
        };
        scope = try intersectScope(gpa, changed, files);
    } else {
        return null; // no diff-scope requested -> full run
    }
    opts.scope_files = scope;
    // An empty scope is a legitimate outcome (nothing eligible changed), so report
    // it clearly and run 0 mutants rather than silently exiting as if a full run
    // found no survivors. Flush so the note is emitted intact before the per-mutant
    // progress sink (which also flushes) starts writing to the same stderr.
    if (scope.len == 0) {
        try stderr.writeAll("note[ZNTL_DIFF_SCOPE_EMPTY]: diff scope matched no eligible source files; running 0 mutants\n");
    } else {
        try stderr.print("note: diff scope -> {d} eligible file(s)\n", .{scope.len});
    }
    try stderr.flush();
    return null;
}

/// `zentinel run`: load config, validate Zig, discover eligible source files
/// from config globs, run the deterministic Phase 1 flow over real executors,
/// then write the JSON report and a concise survivor-focused summary.
fn runRun(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    inv: zentinel.RunInvocation,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    parent_env: *const std.process.Environ.Map,
) !u8 {
    var options = zentinel.run_command.parseArgs(inv.args) catch |err| {
        const detail = switch (err) {
            error.MissingValue => "missing option value",
            error.UnknownOption => "unknown run option",
            error.UnknownOperator => "--operator is not a known operator name; see docs/MUTATOR_SPEC.md for the operator list",
            error.ConflictingOptions => "--verbose/--quiet are mutually exclusive, and --changed-only/--diff/--scope-files are mutually exclusive diff-scope inputs",
            error.DuplicateOption => "a value-taking option was given more than once; specify each of --operator/--mutant/--report/--output/--jobs/--mode/--diff/--scope-files at most once",
            error.InvalidReportFormat => "--report must be text, json, jsonl, or junit",
            error.InvalidJobs => "--jobs must be a positive integer",
            error.InvalidMode => "--mode must be Debug, ReleaseSafe, ReleaseFast, or ReleaseSmall",
            error.BackendNotInRun => "--backend is list-mutants-only; run always uses the stable AST backend (the experimental ZIR backend re-tags AST candidates and does no IR analysis)",
        };
        try stderr.print("error[ZNTL_CLI_INVALID_OPTION]: {s}\n", .{detail});
        return 2;
    };

    const cfg_path = (try configPathOrReject(gpa, io, dir, inv.globals, stderr)) orelse return 2;
    const cfg_bytes = readResolvedConfig(gpa, io, dir, cfg_path) orelse {
        try stderr.print("error[ZNTL_CONFIG_NOT_FOUND]: config not found at {s}\n", .{cfg_path});
        return 2;
    };
    var diag: zentinel.config.Diagnostic = .{};
    const cfg = zentinel.config.load(gpa, cfg_bytes, &diag) catch {
        try stderr.print("error[{s}]: {s}\n", .{ diag.code.token(), diag.message });
        return 2;
    };

    const zig = discoverZig(gpa, io);
    const fatal_zig = try zentinel.zig_version.fatalStatusLine(gpa, zig);
    if (fatal_zig.len > 0) {
        try stderr.print("{s}\n", .{fatal_zig});
        return zentinel.zig_version.failureExit(zig);
    }
    const zig_label = zentinel.zig_version.supportedLabel(zig).?;

    var selected_root_dir = try dir.openDir(io, inv.globals.root, .{ .iterate = true });
    defer selected_root_dir.close(io);
    var effective_root_dir: ?std.Io.Dir = null;
    defer if (effective_root_dir) |*d| d.close(io);
    if (!std.mem.eql(u8, cfg.project_root, ".")) {
        if (zentinel.config.pathEscapesRoot(io, selected_root_dir, cfg.project_root)) {
            try stderr.writeAll("error[ZNTL_CONFIG_INVALID_VALUE]: project.root must stay within the selected root\n");
            return 2;
        }
        effective_root_dir = selected_root_dir.openDir(io, cfg.project_root, .{ .iterate = true }) catch |err| {
            try stderr.print("error[ZNTL_CONFIG_INVALID_VALUE]: could not open project.root {s}: {s}\n", .{ cfg.project_root, @errorName(err) });
            return 2;
        };
    }
    const root_dir = effective_root_dir orelse selected_root_dir;

    const discovered = try zentinel.project_model.discover(gpa, io, root_dir, cfg.include, cfg.exclude);
    var files: std.ArrayList(zentinel.run_command.FileSource) = .empty;
    for (discovered) |rel| {
        if (zentinel.config.pathEscapesRoot(io, root_dir, rel)) {
            try stderr.print("error[ZNTL_SOURCE_READ_FAILED]: source path must stay within the project root: {s}\n", .{rel});
            return 2;
        }
        const bytes = root_dir.readFileAlloc(io, rel, gpa, read_limit) catch |err| {
            try stderr.print("error[ZNTL_SOURCE_READ_FAILED]: could not read {s}: {s}\n", .{ rel, @errorName(err) });
            return 2;
        };
        try files.append(gpa, .{ .path = rel, .source = bytes });
    }

    // Resolve opt-in diff-scoping (--changed-only/--diff/--scope-files) into the
    // project-relative set the deterministic core filters candidates by. Git lives
    // here in the adapter, never in the core (I-022); no scope flag leaves the run
    // unscoped (today's behavior, byte-for-byte).
    if (try resolveScopeFiles(gpa, io, root_dir, &options, files.items, stderr)) |code| return code;

    // Build the minimal command environment once; every test command this run
    // spawns is restricted to it (docs/SANDBOX_SECURITY.md).
    var minimal_env = try zentinel.runner.minimalEnviron(gpa, parent_env);
    defer minimal_env.deinit();
    var obs = try buildObservation(gpa, io, cfg_bytes, zig_label, "<project>");
    obs.environment_hash = try zentinel.cache.environmentHash(gpa, &minimal_env);

    // The parallel mutant phase (worker_pool.run with --jobs > 1) has worker
    // threads allocate concurrently through rt.gpa (sandbox.apply, std.process.run
    // output capture, mutant_runner). `gpa` here is the process arena, which is
    // NOT thread-safe, so route rt.gpa through a mutex-guarded wrapper. Serial
    // phases (baseline, reverification, report building) keep using the wrapped
    // allocator too -- the lock is uncontended off the parallel phase.
    var locked_gpa = zentinel.worker_pool.LockedAllocator{ .child = gpa };
    var rt = RunCtx{
        .gpa = locked_gpa.allocator(),
        .io = io,
        .root_dir = root_dir,
        .root_label = "<project>",
        .run_id = obs.run_id,
        .timeout = timeoutFromMs(cfg.test_timeout_ms),
        .env = &minimal_env,
        .cleanup_failures = std.atomic.Value(u32).init(0),
    };
    // Best-effort sweep of stale `run_*` workspace containers left by interrupted
    // runs before this run materializes its own (skips the current run_id). Done
    // here, before the deterministic run creates any workspace, so an aborted
    // run's full-tree copies cannot accumulate under the cache namespace.
    sweepStaleRunWorkspaces(io, root_dir, rt.run_id);
    const baseline_executor = zentinel.runner.Executor{ .ctx = &rt, .runFn = baselineRunFn };
    const mutant_executor = zentinel.run_command.MutantRunner{ .ctx = &rt, .runFn = mutantRunFn, .runSpecsFn = mutantRunSpecsFn, .runModesFn = mutantRunModesFn };

    // Per-mutant progress on stderr as results complete; `--quiet` suppresses
    // it. The sink outlives the run call and is shared by all worker threads.
    var progress_sink = ProgressSink{ .stderr = stderr };
    if (!options.quiet) {
        options.progress = .{ .ctx = &progress_sink, .notifyFn = ProgressSink.notify };
    }

    // Cross-run result reuse (M1): wire a disk-backed, content-addressed result
    // store so a mutant whose every soundness input is unchanged is served from a
    // prior run's terminal verdict instead of recompiling+retesting. Active only
    // when the cache is enabled and --no-cache was not passed; the deterministic
    // core additionally restricts reuse to single-mode runs and terminal
    // post-reverify verdicts (src/run_command.zig). `result_store` must outlive the
    // run call, so it lives in this scope.
    const cache_active = cfg.cache_enabled and !options.no_cache;
    var result_store: zentinel.result_store.DiskResultStore = undefined;
    var results_dir_path: []const u8 = "";
    if (cache_active) {
        results_dir_path = try std.fmt.allocPrint(gpa, "{s}/results", .{cfg.cache_directory});
        result_store = .{ .io = io, .root_dir = root_dir, .dir_path = results_dir_path, .gpa = gpa };
        options.result_cache = result_store.store();
    }

    const outcome = zentinel.run_command.run(gpa, cfg, files.items, options, baseline_executor, mutant_executor, obs) catch |err| switch (err) {
        error.OutputOutsideRoot => {
            try stderr.writeAll("error: --output must stay within the project root\n");
            return 2;
        },
        error.BackendParseError => {
            if (try zentinel.run_command.firstBackendParseError(gpa, files.items)) |path| {
                try stderr.print("error[ZNTL_BACKEND_PARSE_ERROR]: could not parse source file {s}\n", .{path});
            } else {
                try stderr.writeAll("error[ZNTL_BACKEND_PARSE_ERROR]: could not parse one or more source files\n");
            }
            return 2;
        },
        error.InvalidCandidate => {
            try stderr.writeAll("error[ZNTL_INTERNAL_INVARIANT]: AST backend emitted an invalid mutation candidate\n");
            return 4;
        },
        error.InvalidCommand => {
            try stderr.writeAll("error[ZNTL_CONFIG_INVALID_COMMAND]: configured test command cannot be parsed\n");
            return 2;
        },
        error.SourceFileMissing => {
            try stderr.writeAll("error[ZNTL_INTERNAL_INVARIANT]: generated mutant references a missing source file\n");
            return 4;
        },
        error.OutOfMemory => return err,
    };

    // Remove the per-run workspace container that setupWorkspace materialized via
    // createDirPath (.zig-cache/zentinel/workspaces/{run_id}). mutantRunSpecsFn
    // deletes each content-addressed per-mutant leaf, but nothing removed the
    // {run_id} parent, so every invocation leaked one stale `run_<x>` dir under
    // the controlled cache namespace. Best-effort and counted like the per-mutant
    // cleanup so a failure surfaces in the warning below.
    {
        const run_base = try zentinel.worker_pool.workspaceRunBase(gpa, rt.run_id);
        rt.root_dir.deleteTree(rt.io, run_base) catch {
            _ = rt.cleanup_failures.fetchAdd(1, .monotonic);
        };
    }

    try zentinel.emitCleanupWarningIfNeeded(rt.cleanup_failures.load(.monotonic), stderr);

    // Discoverability hint (advisory, stderr-only): a large mutant set ran
    // serially because the effective worker count resolved to 1. `run.jobs`
    // stays 1 by default; this only nudges toward --jobs. Suppressed under
    // --quiet, and never affects stdout, the report, or the exit code.
    if (!options.quiet) {
        const total = outcome.report.summary.total;
        const requested: usize = options.jobs orelse @intCast(@max(@as(i64, 1), cfg.run_jobs));
        const count: usize = std.math.cast(usize, total) orelse std.math.maxInt(usize);
        if (total > jobs_hint_threshold and zentinel.worker_pool.effectiveJobs(requested, count) == 1) {
            stderr.print("note: ran {d} mutants on a single worker; pass --jobs <n> to run them in parallel\n", .{total}) catch {};
            stderr.flush() catch {};
        }
    }

    // Write the JSON report to the resolved output path (under the project root).
    const json = try zentinel.report.toJson(gpa, outcome.report);
    const out_path = options.output orelse try std.fmt.allocPrint(gpa, "{s}/report.json", .{cfg.report_output_dir});
    // Symlink-safe containment (F-3): the string-level --output check
    // (run_command.run -> OutputOutsideRoot) already rejected absolute and `..`
    // paths, but `writeFile` follows symlinks in the sub-path, so an in-tree
    // symlink that leaves the project tree could redirect the report outside the
    // root. Refuse a symlinked output component before creating any directory or
    // writing, so an untrusted checkout cannot escape the analyzed project.
    if (zentinel.config.pathEscapesRoot(io, root_dir, out_path)) {
        try stderr.writeAll("error: --output must stay within the project root\n");
        return 2;
    }
    if (std.fs.path.dirname(out_path)) |parent| {
        root_dir.createDirPath(io, parent) catch {};
    }
    root_dir.writeFile(io, .{ .sub_path = out_path, .data = json }) catch |err| {
        try stderr.print("error: could not write report to {s}: {s}\n", .{ out_path, @errorName(err) });
        return 2;
    };

    // Emit deterministic cache metadata alongside the report (best-effort). The
    // cache write shares the symlink containment guard; an escape is skipped
    // rather than fatal because the cache is best-effort.
    const cache_json = try zentinel.cache.toJson(gpa, outcome.cache);
    // The cache artifact goes under the configured cache.directory, not the
    // report output dir; the symlink-containment guard and parent-dir creation
    // below keep the write safe and best-effort.
    const cache_path = try std.fmt.allocPrint(gpa, "{s}/cache.json", .{cfg.cache_directory});
    if (!zentinel.config.pathEscapesRoot(io, root_dir, cache_path)) {
        if (std.fs.path.dirname(cache_path)) |parent| root_dir.createDirPath(io, parent) catch {};
        root_dir.writeFile(io, .{ .sub_path = cache_path, .data = cache_json }) catch {};
    }

    // Bound the disk result store (best-effort LRU): keep the newest entries,
    // delete the oldest beyond the cap. Runs once, after this run persisted its
    // own entries, so a hot entry written this run is retained.
    if (cache_active) zentinel.result_store.prune(io, root_dir, results_dir_path, gpa, zentinel.result_store.max_entries);

    // The canonical JSON report is always written to the output path; --report
    // selects only the stdout rendering, so the canonical report data is the same
    // regardless of format. --verbose/--quiet affect only the text rendering.
    const verbosity: zentinel.report_text.Verbosity =
        if (options.quiet) .quiet else if (options.verbose) .verbose else .normal;
    const rendered = switch (options.report_format) {
        .text => try zentinel.report_text.render(gpa, outcome.report, verbosity),
        .json => json,
        .jsonl => try zentinel.report_jsonl.render(gpa, outcome.report),
        .junit => try zentinel.report_junit.render(gpa, outcome.report, options.fail_on_survivors),
    };
    try stdout.writeAll(rendered);
    // Canonical JSON has no trailing newline; the other renderers already end in one.
    if (options.report_format == .json) try stdout.writeAll("\n");
    return outcome.exit_code;
}

// --- `zentinel list-mutants` (Phase 1) -------------------------------------

/// `zentinel list-mutants`: load config, discover eligible files from config
/// globs, generate the stable AST candidate set, and render a deterministic
/// text or JSON listing. No baseline, no executor, no workspace: listing never
/// patches a file or runs a test command.
fn runListMutants(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    inv: zentinel.RunInvocation,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    // Extract the experimental `--backend <ast|zir>` opt-in here in the
    // adapter: the frozen list-mutants parser owns only
    // `--operator`/`--format` and stays unchanged. Default is the stable AST.
    // (AIR was retired: AIR-level mutation mapping is infeasible without SEMA.)
    var backend: []const u8 = "ast";
    var filtered: std.ArrayList([]const u8) = .empty;
    {
        var i: usize = 0;
        while (i < inv.args.len) : (i += 1) {
            const a = inv.args[i];
            if (std.mem.eql(u8, a, "--backend")) {
                i += 1;
                if (i >= inv.args.len) {
                    try stderr.writeAll("error[ZNTL_CLI_INVALID_OPTION]: --backend requires a value\n");
                    return 2;
                }
                backend = inv.args[i];
                if (!std.mem.eql(u8, backend, "ast") and !std.mem.eql(u8, backend, "zir")) {
                    try stderr.writeAll("error[ZNTL_CLI_INVALID_OPTION]: --backend must be 'ast' or 'zir'\n");
                    return 2;
                }
            } else {
                try filtered.append(gpa, a);
            }
        }
    }

    const options = zentinel.list_mutants_command.parseArgs(filtered.items) catch |err| {
        const detail = switch (err) {
            error.MissingValue => "missing option value",
            error.UnknownOption => "unknown list-mutants option",
            error.UnknownOperator => "--operator is not a known operator name; see docs/MUTATOR_SPEC.md for the operator list",
            error.DuplicateOption => "a value-taking option was given more than once; specify each of --operator/--format at most once",
            error.InvalidFormat => "--format must be 'text' or 'json'",
        };
        try stderr.print("error[ZNTL_CLI_INVALID_OPTION]: {s}\n", .{detail});
        return 2;
    };

    const cfg_path = (try configPathOrReject(gpa, io, dir, inv.globals, stderr)) orelse return 2;
    const cfg_bytes = readResolvedConfig(gpa, io, dir, cfg_path) orelse {
        try stderr.print("error[ZNTL_CONFIG_NOT_FOUND]: config not found at {s}\n", .{cfg_path});
        return 2;
    };
    var diag: zentinel.config.Diagnostic = .{};
    const cfg = zentinel.config.load(gpa, cfg_bytes, &diag) catch {
        try stderr.print("error[{s}]: {s}\n", .{ diag.code.token(), diag.message });
        return 2;
    };

    var roots = (try openEffectiveProjectRoot(io, dir, inv.globals.root, cfg.project_root, stderr)) orelse return 2;
    defer roots.close(io);
    const root_dir = roots.dir();

    const discovered = try zentinel.project_model.discover(gpa, io, root_dir, cfg.include, cfg.exclude);
    var files: std.ArrayList(zentinel.list_mutants_command.FileSource) = .empty;
    for (discovered) |rel| {
        if (zentinel.config.pathEscapesRoot(io, root_dir, rel)) {
            try stderr.print("error[ZNTL_SOURCE_READ_FAILED]: source path must stay within the project root: {s}\n", .{rel});
            return 2;
        }
        const bytes = root_dir.readFileAlloc(io, rel, gpa, read_limit) catch |err| {
            try stderr.print("error[ZNTL_SOURCE_READ_FAILED]: could not read {s}: {s}\n", .{ rel, @errorName(err) });
            return 2;
        };
        try files.append(gpa, .{ .path = rel, .source = bytes });
    }

    const candidates = zentinel.list_mutants_command.generate(gpa, cfg, files.items, options.operator_filter) catch |err| switch (err) {
        error.BackendParseError => {
            if (try zentinel.run_command.firstBackendParseError(gpa, files.items)) |path| {
                try stderr.print("error[ZNTL_BACKEND_PARSE_ERROR]: could not parse source file {s}\n", .{path});
            } else {
                try stderr.writeAll("error[ZNTL_BACKEND_PARSE_ERROR]: could not parse one or more source files\n");
            }
            return 2;
        },
        error.InvalidCandidate => {
            try stderr.writeAll("error[ZNTL_INTERNAL_INVARIANT]: AST backend emitted an invalid mutation candidate\n");
            return 4;
        },
        error.OutOfMemory => return err,
    };

    // Experimental backend opt-in (zir). The stable AST default is
    // unchanged; experimental backends are gated by config and emit out-of-report
    // diagnostics for operators with no exact source mapping.
    if (std.mem.eql(u8, backend, "zir")) {
        // Real ZIR lowering: each source file is lowered to ZIR and its
        // comparison mutation sites recognized from the cmp_* instructions; other
        // operators become out-of-report diagnostics. The stable AST default and the
        // `run` path are unaffected.
        const zig_disc = discoverZig(gpa, io);
        const listing = zentinel.zir_backend.listFromTrees(gpa, cfg, zig_disc, files.items, candidates, backend) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.ExperimentalBackendNotEnabled => {
                try stderr.print("error[ZNTL_CONFIG_EXPERIMENTAL_BACKEND]: backend '{s}' requires explicit opt-in via [backend] experimental\n", .{backend});
                return 2;
            },
            error.BackendNotImplemented => {
                try stderr.print("error[ZNTL_CLI_INVALID_OPTION]: backend '{s}' is not implemented yet\n", .{backend});
                return 2;
            },
            error.BackendParseError => {
                try stderr.writeAll("error[ZNTL_BACKEND_PARSE_ERROR]: could not parse one or more source files\n");
                return 2;
            },
            error.UnsupportedZigVersion => {
                // The ZIR path's src_node decoding is version-coupled (zir-0.16.0); a
                // different toolchain would silently mis-resolve, so it declines.
                const detected: []const u8 = switch (zig_disc) {
                    .version => |v| v,
                    .not_found => "not found",
                };
                try stderr.print("error[{s}]: --backend zir requires Zig {s}; detected {s} (the ZIR backend's source mapping is version-coupled)\n", .{ zentinel.zig_version.Code.unsupported.token(), zentinel.zig_version.supported_version, detected });
                return 2;
            },
        };
        const rendered = switch (options.format) {
            .text => try zentinel.list_mutants_command.renderText(gpa, listing.candidates),
            .json => try zentinel.list_mutants_command.renderJson(gpa, listing.candidates),
        };
        try stdout.writeAll(rendered);
        if (options.format == .json) try stdout.writeAll("\n");
        // Out-of-report backend diagnostics: stderr only, never report fields.
        for (listing.diagnostics) |d| {
            try stderr.writeAll(try zentinel.zir_backend.renderDiagnosticNote(gpa, d));
        }
        return 0;
    }

    const rendered = switch (options.format) {
        .text => try zentinel.list_mutants_command.renderText(gpa, candidates),
        .json => try zentinel.list_mutants_command.renderJson(gpa, candidates),
    };
    try stdout.writeAll(rendered);
    if (options.format == .json) try stdout.writeAll("\n");
    return 0;
}

// --- `zentinel doctest` (Phase 1, normal doctests) -------------------------

const default_doctest_file = "docs/CLI_SPEC.md";

const DoctestCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    timeout: std.Io.Timeout,
    env: *const std.process.Environ.Map,
};

/// Execute a doctest CLI command (already validated to begin with `zentinel`)
/// via direct argv, no shell. The deterministic runner owns the verdict.
fn doctestExecFn(ctx: *anyopaque, argv: []const []const u8) zentinel.runner.RawOutcome {
    const rt: *DoctestCtx = @ptrCast(@alignCast(ctx));
    const start_ms = std.Io.Timestamp.now(rt.io, .real).toMilliseconds();
    const result = zentinel.exec.run(rt.gpa, rt.io, .{
        .argv = argv,
        .cwd = .{ .dir = rt.root_dir },
        .stdout_limit = run_output_limit,
        .stderr_limit = run_output_limit,
        .timeout = rt.timeout,
        .environ_map = rt.env,
    }) catch |err| {
        const dur = elapsedMs(rt.io, start_ms);
        if (err == error.Timeout) return .{ .exit_code = null, .timed_out = true, .crashed = false, .duration_ms = dur, .stdout = "", .stderr = "" };
        return .{ .exit_code = null, .timed_out = false, .crashed = true, .duration_ms = dur, .stdout = "", .stderr = "" };
    };
    const dur = elapsedMs(rt.io, start_ms);
    return switch (result.term) {
        .exited => |code| .{ .exit_code = @as(i64, code), .timed_out = false, .crashed = false, .duration_ms = dur, .stdout = result.stdout, .stderr = result.stderr },
        else => .{ .exit_code = null, .timed_out = false, .crashed = true, .duration_ms = dur, .stdout = result.stdout, .stderr = result.stderr },
    };
}

const DoctestWsCtx = struct { gpa: std.mem.Allocator, io: std.Io, root_dir: std.Io.Dir };

/// Materialize a doctest workspace under the zentinel-controlled cache location.
/// Every planned path is confined under the workspace dir, so repository sources
/// are never written.
fn doctestWsFn(ctx: *anyopaque, plan: zentinel.doctest.workspace.Plan) zentinel.doctest.workspace.MaterializeError!void {
    const w: *DoctestWsCtx = @ptrCast(@alignCast(ctx));
    if (!zentinel.doctest.workspace.isConfined(plan)) return error.WorkspaceCreateFailed;
    if (zentinel.config.pathEscapesRoot(w.io, w.root_dir, plan.dir)) return error.WorkspaceCreateFailed;
    w.root_dir.createDirPath(w.io, plan.dir) catch return error.WorkspaceCreateFailed;
    for (plan.files) |f| {
        if (zentinel.config.pathEscapesRoot(w.io, w.root_dir, f.rel_path)) return error.WorkspaceCreateFailed;
        if (std.fs.path.dirname(f.rel_path)) |parent| {
            w.root_dir.createDirPath(w.io, parent) catch return error.WorkspaceCreateFailed;
        }
        w.root_dir.writeFile(w.io, .{ .sub_path = f.rel_path, .data = f.contents }) catch return error.WorkspaceCreateFailed;
    }
}

/// `zentinel doctest`: read the target doc, execute its normal doctests through
/// real process/workspace adapters, and emit a deterministic text or JSON
/// zentinel.doctest.report.v1 report.
/// Adapter for the advisory AI commands `explain`, `suggest`, and `review-tests`.
/// Parses command-local options, reads normalized config and the
/// selected mutation report read-only, then delegates to the deterministic
/// `ai.command` engine. AI-only failures print their documented `ZNTL_AI_*` code
/// and never touch a report.
fn runAiCommand(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    inv: zentinel.RunInvocation,
    flow: zentinel.ai.command.Flow,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var mutant_ref: ?[]const u8 = null;
    var ai_opts = zentinel.ai.command.SharedOptions{};
    var i: usize = 0;
    while (i < inv.args.len) : (i += 1) {
        const a = inv.args[i];
        switch (zentinel.ai.command.parseSharedOption(inv.args, &i, &ai_opts)) {
            .consumed => continue,
            .err => |detail| return aiOptionError(stderr, detail),
            .not_shared => {},
        }
        if (std.mem.startsWith(u8, a, "--")) {
            return aiOptionError(stderr, "unknown AI command option");
        } else if (flow != .review_tests and mutant_ref == null) {
            mutant_ref = a;
        } else {
            return aiOptionError(stderr, "unexpected positional argument");
        }
    }
    const provider_override = ai_opts.provider_override;
    const input_report = ai_opts.input_report;
    const format = ai_opts.format;
    if (flow != .review_tests and mutant_ref == null) {
        return aiOptionError(stderr, "missing <mutant-ref>");
    }
    // Read-side path containment (F-5): an out-of-root --input-report escapes the
    // project root, so reject it like the write-side --output guard.
    if (zentinel.readPathOutsideRootOption(inv.args)) |opt| {
        return aiOptionError(stderr, try std.fmt.allocPrint(arena, "{s} must stay within the project root", .{opt}));
    }

    const ai_cfg = (try aiSettings(arena, gpa, io, dir, inv.globals, stderr)) orelse return 2;

    var roots = (try openEffectiveProjectRoot(io, dir, inv.globals.root, ai_cfg.project_root, stderr)) orelse return 2;
    defer roots.close(io);
    const root_dir = roots.dir();
    const report_path = input_report orelse zentinel.ai.command.default_report_path;
    if (zentinel.config.pathEscapesRoot(io, root_dir, report_path)) {
        return aiOptionError(stderr, "--input-report must stay within the project root");
    }
    const report_json: ?[]const u8 = root_dir.readFileAlloc(io, report_path, arena, read_limit) catch null;

    const input = zentinel.ai.command.Input{
        .flow = flow,
        .mutant_ref = mutant_ref,
        .provider_override = provider_override,
        .report_json = report_json,
        .settings = ai_cfg.settings,
    };

    const out = zentinel.ai.command.run(arena, input, format) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => |f| {
            try stderr.print("error[{s}]: advisory AI command failed\n", .{zentinel.ai.command.failureToken(f)});
            return zentinel.ai.command.failureExit(f);
        },
    };

    return emitAiOutput(stdout, out);
}

fn aiOptionError(stderr: *std.Io.Writer, detail: []const u8) !u8 {
    try stderr.print("error[ZNTL_CLI_INVALID_OPTION]: {s}\n", .{detail});
    return 2;
}

/// Emit an advisory-AI command result and return its exit code. The doctest-AI
/// `Outcome` is an alias of `ai.command.Outcome`, so this single helper serves
/// `runAiCommand`, `runDoctestAi`, and `runDoctestSurvivorAi` identically: write
/// the body, then the JSON renderings' single trailing newline.
fn emitAiOutput(stdout: *std.Io.Writer, out: zentinel.ai.command.Outcome) !u8 {
    try stdout.writeAll(out.body);
    if (out.format == .json) try stdout.writeAll("\n");
    return out.exit_code;
}

const AiCliSettings = struct {
    settings: zentinel.ai.command.Settings,
    project_root: []const u8,
};

/// Build advisory AI settings from normalized config. An omitted or invalid
/// implicit config keeps AI disabled; an explicit missing/invalid config is a
/// usage error and never falls through to provider execution.
fn aiSettings(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    globals: zentinel.Globals,
    stderr: *std.Io.Writer,
) !?AiCliSettings {
    const zig_label: []const u8 = zentinel.zig_version.supportedLabel(discoverZig(gpa, io)) orelse "unknown";
    var settings = zentinel.ai.command.Settings{
        .ai_enabled = false,
        .config_mode = .disabled,
        .remote_allowed = false,
        .redact_patterns = &zentinel.ai.command.default_redact_patterns,
        .project_name = zentinel.project_name,
        .zig_version = zig_label,
        .zentinel_version = zentinel.version,
    };
    const resolved = (try configPathOrReject(arena, io, dir, globals, stderr)) orelse return null;
    const bytes = readResolvedConfig(arena, io, dir, resolved) orelse {
        if (globals.config_explicit) {
            try stderr.print("error[ZNTL_CONFIG_NOT_FOUND]: config not found at {s}\n", .{resolved});
            return null;
        }
        return .{ .settings = settings, .project_root = "." };
    };
    var diag: zentinel.config.Diagnostic = .{};
    const cfg = zentinel.config.load(arena, bytes, &diag) catch |err| switch (err) {
        error.Invalid => {
            if (globals.config_explicit) {
                try stderr.print("error[{s}]: {s}\n", .{ diag.code.token(), diag.message });
                return null;
            }
            return .{ .settings = settings, .project_root = "." };
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    settings.ai_enabled = cfg.ai_enabled;
    settings.config_mode = zentinel.ai.provider.modeFromName(cfg.ai_provider) orelse .disabled;
    settings.remote_allowed = cfg.ai_remote_allowed;
    settings.redact_patterns = cfg.ai_redact_patterns;
    settings.project_name = cfg.project_name;
    // ai.source_context_lines is validated >= 0; clamp to u32 for the context
    // window so a huge configured value cannot overflow the cast.
    settings.source_context_lines = @intCast(@min(cfg.ai_source_context_lines, @as(i64, std.math.maxInt(u32))));
    return .{ .settings = settings, .project_root = cfg.project_root };
}

/// Adapter for the advisory doctest-AI subcommands. Parses
/// command-local options, reads config and the selected doctest report or docs
/// path read-only, then delegates to the deterministic `ai.doctest_command`
/// engine. Doctest AI is advisory only and never edits docs, snapshots, or
/// reports; AI/doctest failures print their documented codes.
fn runDoctestAi(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    inv: zentinel.RunInvocation,
    flow: zentinel.ai.doctest_command.Flow,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var positional: ?[]const u8 = null;
    var file_opt: ?[]const u8 = null;
    var ai_opts = zentinel.ai.command.SharedOptions{};

    var i: usize = 1; // skip the subcommand token at inv.args[0]
    while (i < inv.args.len) : (i += 1) {
        const a = inv.args[i];
        // `--file` is doctest-specific; the rest are the shared AI options.
        if (std.mem.eql(u8, a, "--file")) {
            i += 1;
            if (i >= inv.args.len) return aiOptionError(stderr, "--file requires a value");
            file_opt = inv.args[i];
            continue;
        }
        switch (zentinel.ai.command.parseSharedOption(inv.args, &i, &ai_opts)) {
            .consumed => continue,
            .err => |detail| return aiOptionError(stderr, detail),
            .not_shared => {},
        }
        if (std.mem.startsWith(u8, a, "--")) {
            return aiOptionError(stderr, "unknown doctest AI option");
        } else if (positional == null) {
            positional = a;
        } else {
            return aiOptionError(stderr, "unexpected positional argument");
        }
    }
    const input_report = ai_opts.input_report;
    const provider_override = ai_opts.provider_override;
    const format = ai_opts.format;

    const flow_is_case = (flow == .explain_doctest_failure or flow == .review_snapshot);
    const doc_path: ?[]const u8 = switch (flow) {
        .suggest_doctest => positional,
        .suggest_missing_doctests => file_opt,
        else => null,
    };
    const case_ref: ?[]const u8 = if (flow_is_case) positional else null;

    // Read-side path containment (F-5): reject an out-of-root --input-report,
    // --file, or positional documentation path so reads honor the write-side
    // root-containment contract.
    if (zentinel.readPathOutsideRootOption(inv.args)) |opt| {
        return aiOptionError(stderr, try std.fmt.allocPrint(arena, "{s} must stay within the project root", .{opt}));
    }
    if (doc_path) |d| {
        if (zentinel.config.isOutsideRoot(d)) return aiOptionError(stderr, "documentation path must stay within the project root");
    }

    const ai_cfg = (try aiSettings(arena, gpa, io, dir, inv.globals, stderr)) orelse return 2;

    // A required positional missing (doc-path for suggest, case-ref for explain /
    // review-snapshot) is a CLI usage error, surfaced like the top-level AI commands'
    // `missing <mutant-ref>`/`missing <survivor-ref>` guards instead of being
    // forwarded as a null ref the engine reports as an opaque DOC/CASE_NOT_FOUND.
    // Checked after config/--config validation so a bad --config still wins.
    if (zentinel.ai.doctest_command.missingPositional(flow, positional)) |detail| {
        return aiOptionError(stderr, detail);
    }

    var roots = (try openEffectiveProjectRoot(io, dir, inv.globals.root, ai_cfg.project_root, stderr)) orelse return 2;
    defer roots.close(io);
    const root_dir = roots.dir();

    if (doc_path) |d| {
        if (zentinel.config.pathEscapesRoot(io, root_dir, d)) return aiOptionError(stderr, "documentation path must stay within the project root");
    }

    const doc_exists = blk: {
        const d = doc_path orelse break :blk false;
        root_dir.access(io, d, .{}) catch break :blk false;
        break :blk true;
    };
    const report_json: ?[]const u8 = blk: {
        if (flow_is_case) {
            const rp = input_report orelse zentinel.ai.doctest_command.default_report_path;
            if (zentinel.config.pathEscapesRoot(io, root_dir, rp)) return aiOptionError(stderr, "--input-report must stay within the project root");
            break :blk root_dir.readFileAlloc(io, rp, arena, read_limit) catch null;
        } else if (input_report) |rp| {
            if (zentinel.config.pathEscapesRoot(io, root_dir, rp)) return aiOptionError(stderr, "--input-report must stay within the project root");
            break :blk root_dir.readFileAlloc(io, rp, arena, read_limit) catch null;
        }
        break :blk null;
    };

    const out = zentinel.ai.doctest_command.run(arena, .{
        .flow = flow,
        .case_ref = case_ref,
        .doc_path = doc_path,
        .doc_exists = doc_exists,
        .provider_override = provider_override,
        .report_json = report_json,
        .settings = ai_cfg.settings,
    }, format) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => |f| {
            try stderr.print("error[{s}]: advisory doctest AI command failed\n", .{zentinel.ai.doctest_command.failureToken(f)});
            return zentinel.ai.doctest_command.failureExit(f);
        },
    };

    return emitAiOutput(stdout, out);
}

/// Adapter for `zentinel doctest explain-survivor <survivor-ref>`.
/// Reads config and the selected mutation-aware doctest report read-only and
/// delegates to the deterministic survivor engine. Advisory only: it never
/// changes a survivor's status, the report, snapshots, or documentation.
fn runDoctestSurvivorAi(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    inv: zentinel.RunInvocation,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var survivor_ref: ?[]const u8 = null;
    var ai_opts = zentinel.ai.command.SharedOptions{};

    var i: usize = 1; // skip the subcommand token at inv.args[0]
    while (i < inv.args.len) : (i += 1) {
        const a = inv.args[i];
        switch (zentinel.ai.command.parseSharedOption(inv.args, &i, &ai_opts)) {
            .consumed => continue,
            .err => |detail| return aiOptionError(stderr, detail),
            .not_shared => {},
        }
        if (std.mem.startsWith(u8, a, "--")) {
            return aiOptionError(stderr, "unknown doctest AI option");
        } else if (survivor_ref == null) {
            survivor_ref = a;
        } else {
            return aiOptionError(stderr, "unexpected positional argument");
        }
    }
    const input_report = ai_opts.input_report;
    const provider_override = ai_opts.provider_override;
    const format = ai_opts.format;
    if (survivor_ref == null) return aiOptionError(stderr, "missing <survivor-ref>");
    // Read-side path containment (F-5): reject an out-of-root --input-report.
    if (zentinel.readPathOutsideRootOption(inv.args)) |opt| {
        return aiOptionError(stderr, try std.fmt.allocPrint(arena, "{s} must stay within the project root", .{opt}));
    }

    const ai_cfg = (try aiSettings(arena, gpa, io, dir, inv.globals, stderr)) orelse return 2;

    var roots = (try openEffectiveProjectRoot(io, dir, inv.globals.root, ai_cfg.project_root, stderr)) orelse return 2;
    defer roots.close(io);
    const root_dir = roots.dir();
    const report_path = input_report orelse zentinel.ai.doctest_command.default_report_path;
    if (zentinel.config.pathEscapesRoot(io, root_dir, report_path)) {
        return aiOptionError(stderr, "--input-report must stay within the project root");
    }
    const report_json: ?[]const u8 = root_dir.readFileAlloc(io, report_path, arena, read_limit) catch null;

    const out = zentinel.ai.doctest_command.runSurvivor(arena, .{
        .survivor_ref = survivor_ref,
        .provider_override = provider_override,
        .report_json = report_json,
        .settings = ai_cfg.settings,
    }, format) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => |f| {
            try stderr.print("error[{s}]: advisory doctest AI command failed\n", .{zentinel.ai.doctest_command.failureToken(f)});
            return zentinel.ai.doctest_command.failureExit(f);
        },
    };

    return emitAiOutput(stdout, out);
}

fn runDoctest(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    inv: zentinel.RunInvocation,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    parent_env: *const std.process.Environ.Map,
) !u8 {
    // A recognized named AI subcommand in the first slot dispatches BEFORE the
    // experimental `--mutate` flag scan, so `doctest suggest --mutate` runs the
    // suggest flow instead of being hijacked by `--mutate`.
    switch (zentinel.doctest_command.route(inv.args)) {
        .mutate => return runDoctestMutate(gpa, io, dir, inv, stdout, stderr, parent_env),
        .explain => return runDoctestAi(gpa, io, dir, inv, .explain_doctest_failure, stdout, stderr),
        .suggest => return runDoctestAi(gpa, io, dir, inv, .suggest_doctest, stdout, stderr),
        .review_snapshot => return runDoctestAi(gpa, io, dir, inv, .review_snapshot, stdout, stderr),
        .suggest_missing => return runDoctestAi(gpa, io, dir, inv, .suggest_missing_doctests, stdout, stderr),
        .explain_survivor => return runDoctestSurvivorAi(gpa, io, dir, inv, stdout, stderr),
        .parse => {},
    }

    const options = zentinel.doctest_command.parseArgs(inv.args) catch |err| {
        const detail = switch (err) {
            error.MissingValue => "missing option value",
            error.UnknownOption => "unknown doctest option",
            error.InvalidFormat => "--format must be 'text' or 'json'",
            error.DuplicateOption => "a value-taking option was given more than once; specify each of --file/--format/--case at most once",
            error.UnsupportedSubcommand => "doctest subcommand not implemented yet",
        };
        try stderr.print("error[ZNTL_CLI_INVALID_OPTION]: {s}\n", .{detail});
        return 2;
    };

    const doc_file = options.file orelse default_doctest_file;
    const cfg = (try doctestConfigOrDefault(gpa, io, dir, inv.globals, stderr)) orelse return 2;

    const zig = discoverZig(gpa, io);
    const fatal_zig = try zentinel.zig_version.fatalStatusLine(gpa, zig);
    if (fatal_zig.len > 0) {
        try stderr.print("{s}\n", .{fatal_zig});
        return zentinel.zig_version.failureExit(zig);
    }
    const zig_label = zentinel.zig_version.supportedLabel(zig).?;

    var roots = (try openEffectiveProjectRoot(io, dir, inv.globals.root, cfg.project_root, stderr)) orelse return 2;
    defer roots.close(io);
    const root_dir = roots.dir();

    if (zentinel.config.pathEscapesRoot(io, root_dir, doc_file)) {
        try stderr.writeAll("error[ZNTL_CLI_INVALID_OPTION]: --file must stay within the project root\n");
        return 2;
    }

    const source = root_dir.readFileAlloc(io, doc_file, gpa, read_limit) catch {
        try stderr.print("error: documentation file not found at {s}\n", .{try zentinel.redactCliDiagnosticPath(gpa, doc_file)});
        return 2;
    };

    const ts = std.Io.Timestamp.now(io, .real).toMilliseconds();
    // Same collision guard as the mutation run id: append a random nonce so two
    // doctest runs within 1 ms get distinct ids (and distinct workspace paths).
    const run_id = try zentinel.allocRunId(gpa, io, "doctest_run", ts);
    const started_at = try zentinel.report.isoTimestamp(gpa, ts);
    const fmt_label: []const u8 = switch (options.format) {
        .text => "text",
        .json => "json",
    };
    const command = try std.fmt.allocPrint(gpa, "zentinel doctest --file {s} --format {s}", .{ doc_file, fmt_label });

    var minimal_env = try zentinel.runner.minimalEnviron(gpa, parent_env);
    defer minimal_env.deinit();

    var dctx = DoctestCtx{
        .gpa = gpa,
        .io = io,
        .root_dir = root_dir,
        .timeout = timeoutFromMs(cfg.test_timeout_ms),
        .env = &minimal_env,
    };
    var wctx = DoctestWsCtx{ .gpa = gpa, .io = io, .root_dir = root_dir };
    const deps = zentinel.doctest_command.Deps{
        .executor = .{ .ctx = &dctx, .runFn = doctestExecFn },
        .provider = .{ .ctx = &wctx, .materializeFn = doctestWsFn },
    };
    const obs = zentinel.doctest_command.Observation{
        .run_id = run_id,
        .started_at = started_at,
        .zentinel_version = zentinel.version,
        .zig_version = zig_label,
        .project_root = "<project>",
        .command = command,
    };

    const out = zentinel.doctest_command.run(gpa, options, doc_file, source, obs, deps) catch |err| switch (err) {
        error.CaseNotFound => {
            try stderr.print("error[ZNTL_DOCTEST_CASE_NOT_FOUND]: --case did not resolve to exactly one case\n", .{});
            return 2;
        },
        // A per-case workspace-creation failure no longer reaches here: the runner
        // isolates it as an `.invalid` case so the run still produces a report.
        // Only OOM remains as a run-wide internal error.
        error.OutOfMemory => return err,
    };

    // Per-run cleanup: each zig/zig_test/compile_fail case materializes a
    // content-addressed workspace under .zig-cache/zentinel/doctest (and the Zig
    // compiler writes its own .zig-cache inside). Nothing reclaimed them, so they
    // accumulated unbounded across runs. Mirror the mutation run's base cleanup:
    // remove the whole container (cases regenerate what they need next run).
    // Best-effort -- a cleanup failure must not change the run's exit code.
    root_dir.deleteTree(io, zentinel.doctest.workspace.root) catch {};

    const rendered = switch (options.format) {
        .text => try zentinel.doctest_command.renderText(gpa, out.report),
        .json => try zentinel.doctest.report.toJson(gpa, out.report),
    };
    try stdout.writeAll(rendered);
    if (options.format == .json) try stdout.writeAll("\n");
    return out.exit_code;
}

// --- `zentinel doctest --mutate` (experimental, fixture docs only) ----------

const DoctestMutateCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    timeout: std.Io.Timeout,
    env: *const std.process.Environ.Map,
};

fn doctestMutateRelPath(gpa: std.mem.Allocator, mutated_source: []const u8) ?[]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(mutated_source, &digest, .{});
    return std.fmt.allocPrint(gpa, ".zig-cache/zentinel/doctest-mutate/{s}.zig", .{std.fmt.bytesToHex(digest[0..8], .lower)}) catch null;
}

fn doctestMutateCommandFn(ctx: *anyopaque, mutated_source: []const u8) zentinel.doctest.mutation_experiment.StableCommand {
    const rt: *DoctestMutateCtx = @ptrCast(@alignCast(ctx));
    const rel = doctestMutateRelPath(rt.gpa, mutated_source) orelse return .{ .original = "zig test src/doctest.zig", .argv = &.{ "zig", "test", "src/doctest.zig" }, .cwd = "." };
    const original = std.fmt.allocPrint(rt.gpa, "zig test {s}", .{rel}) catch return .{ .original = "zig test src/doctest.zig", .argv = &.{ "zig", "test", "src/doctest.zig" }, .cwd = "." };
    const argv = rt.gpa.alloc([]const u8, 3) catch return .{ .original = "zig test src/doctest.zig", .argv = &.{ "zig", "test", "src/doctest.zig" }, .cwd = "." };
    argv[0] = "zig";
    argv[1] = "test";
    argv[2] = rel;
    return .{ .original = original, .argv = argv, .cwd = "<project>" };
}

/// Real snippet runner for the mutation experiment: write the mutated snippet to
/// a content-addressed file under the zentinel cache and run `zig test` on it.
/// Confined to the cache dir, so the documentation file is never modified.
fn doctestMutateRunFn(ctx: *anyopaque, mutated_source: []const u8) zentinel.runner.RawOutcome {
    const rt: *DoctestMutateCtx = @ptrCast(@alignCast(ctx));
    const crash: zentinel.runner.RawOutcome = .{ .exit_code = null, .timed_out = false, .crashed = true, .duration_ms = 0, .stdout = "", .stderr = "" };
    const rel = doctestMutateRelPath(rt.gpa, mutated_source) orelse return crash;
    if (zentinel.config.pathEscapesRoot(rt.io, rt.root_dir, rel)) return crash;
    if (std.fs.path.dirname(rel)) |parent| rt.root_dir.createDirPath(rt.io, parent) catch return crash;
    rt.root_dir.writeFile(rt.io, .{ .sub_path = rel, .data = mutated_source }) catch return crash;
    const start_ms = std.Io.Timestamp.now(rt.io, .real).toMilliseconds();
    const result = zentinel.exec.run(rt.gpa, rt.io, .{
        .argv = &.{ "zig", "test", rel },
        .cwd = .{ .dir = rt.root_dir },
        .stdout_limit = run_output_limit,
        .stderr_limit = run_output_limit,
        .timeout = rt.timeout,
        .environ_map = rt.env,
    }) catch |err| {
        const dur = elapsedMs(rt.io, start_ms);
        if (err == error.Timeout) return .{ .exit_code = null, .timed_out = true, .crashed = false, .duration_ms = dur, .stdout = "", .stderr = "" };
        return crash;
    };
    const dur = elapsedMs(rt.io, start_ms);
    return switch (result.term) {
        .exited => |code| .{ .exit_code = @as(i64, code), .timed_out = false, .crashed = false, .duration_ms = dur, .stdout = result.stdout, .stderr = result.stderr },
        else => .{ .exit_code = null, .timed_out = false, .crashed = true, .duration_ms = dur, .stdout = result.stdout, .stderr = result.stderr },
    };
}

fn runDoctestMutate(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    inv: zentinel.RunInvocation,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    parent_env: *const std.process.Environ.Map,
) !u8 {
    var file: ?[]const u8 = null;
    var i: usize = 0;
    while (i < inv.args.len) : (i += 1) {
        const arg = inv.args[i];
        if (std.mem.eql(u8, arg, "--mutate")) continue;
        if (std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= inv.args.len) {
                try stderr.writeAll("error[ZNTL_CLI_INVALID_OPTION]: --file requires a value\n");
                return 2;
            }
            file = inv.args[i];
        } else {
            try stderr.print("error[ZNTL_CLI_INVALID_OPTION]: unsupported doctest --mutate option {s}\n", .{try zentinel.redactCliDiagnosticPath(gpa, arg)});
            return 2;
        }
    }

    const doc = file orelse {
        try stderr.writeAll("error[ZNTL_CLI_INVALID_OPTION]: doctest --mutate requires --file\n");
        return 2;
    };
    // Read-side path containment (F-5): reject an out-of-root --file.
    if (zentinel.config.isOutsideRoot(doc)) {
        try stderr.writeAll("error[ZNTL_CLI_INVALID_OPTION]: --file must stay within the project root\n");
        return 2;
    }
    const cfg = (try doctestConfigOrDefault(gpa, io, dir, inv.globals, stderr)) orelse return 2;
    // Opt-in: passing `--mutate` explicitly is the opt-in (the hardcoded
    // fixtures-only gate was retired, so it now runs over any --file documentation).

    const zig = discoverZig(gpa, io);
    const fatal_zig = try zentinel.zig_version.fatalStatusLine(gpa, zig);
    if (fatal_zig.len > 0) {
        try stderr.print("{s}\n", .{fatal_zig});
        return zentinel.zig_version.failureExit(zig);
    }

    var roots = (try openEffectiveProjectRoot(io, dir, inv.globals.root, cfg.project_root, stderr)) orelse return 2;
    defer roots.close(io);
    const root_dir = roots.dir();
    if (zentinel.config.pathEscapesRoot(io, root_dir, doc)) {
        try stderr.writeAll("error[ZNTL_CLI_INVALID_OPTION]: --file must stay within the project root\n");
        return 2;
    }
    const source = root_dir.readFileAlloc(io, doc, gpa, read_limit) catch {
        try stderr.print("error: documentation file not found at {s}\n", .{try zentinel.redactCliDiagnosticPath(gpa, doc)});
        return 2;
    };

    var minimal_env = try zentinel.runner.minimalEnviron(gpa, parent_env);
    defer minimal_env.deinit();

    var ctx = DoctestMutateCtx{
        .gpa = gpa,
        .io = io,
        .root_dir = root_dir,
        .timeout = timeoutFromMs(cfg.test_timeout_ms),
        .env = &minimal_env,
    };
    const sr = zentinel.doctest.mutation_experiment.SnippetRunner{ .ctx = &ctx, .runFn = doctestMutateRunFn, .commandFn = doctestMutateCommandFn };
    // Produce the STABLE mutation-aware report (durable `dm_` ids, `ds_` survivor
    // refs) and PERSIST it to the survivor report path so `doctest
    // explain-survivor` can resolve a real survivor.
    const json = try zentinel.doctest.mutation_experiment.mutateReportJson(gpa, doc, source, sr);
    const out_path = zentinel.ai.doctest_command.default_report_path;
    if (zentinel.config.pathEscapesRoot(io, root_dir, out_path)) {
        try stderr.writeAll("error: doctest mutation report path must stay within the project root\n");
        return 2;
    }
    if (std.fs.path.dirname(out_path)) |parent| root_dir.createDirPath(io, parent) catch {};
    root_dir.writeFile(io, .{ .sub_path = out_path, .data = json }) catch |err| {
        try stderr.print("error: could not write doctest mutation report to {s}: {s}\n", .{ out_path, @errorName(err) });
        return 2;
    };
    try stdout.writeAll(json);
    try stdout.writeAll("\n");
    // Surviving documentation mutants are reported but do not fail the command;
    // they are resolved advisorily via `doctest explain-survivor`.
    return 0;
}
