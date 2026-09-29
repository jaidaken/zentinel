// Layer: deterministic_core
//
// Baseline test-command runner (docs/REPORT_FORMAT.md, docs/SANDBOX_SECURITY.md).
// The runner parses configured command strings into argv with the shared
// src/command.zig parser, executes them through an injected `Executor`
// abstraction, and deterministically classifies each result and the overall
// baseline status. Process spawning itself is a side_effect_adapter concern: the
// real `Executor` is wired by the run command / binary, while unit tests inject
// a deterministic mock. This keeps classification pure and testable through the
// deterministic-core hub without depending on machine-specific commands.
const std = @import("std");
const command = @import("command.zig");
const report = @import("report.zig");
const worker_pool = @import("worker_pool.zig");

/// Bound for normalized command output excerpts (docs/SANDBOX_SECURITY.md).
pub const excerpt_limit = 4096;

/// The exact keys copied from the parent environment into the minimal command
/// environment (docs/SANDBOX_SECURITY.md). Locale (`LC_ALL`/`LANG`) is forced to
/// `C` separately, so it is intentionally not in this copy list.
pub const env_allowlist = [_][]const u8{ "PATH", "HOME", "TMPDIR", "ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR" };

/// Build the minimal command environment from a parent environment: copy only the
/// allowlisted keys that are present (absent keys are omitted, never synthesized),
/// force `LC_ALL=C`/`LANG=C` for deterministic, locale-independent tool output, and
/// force a cwd-relative `ZIG_LOCAL_CACHE_DIR` (docs/SANDBOX_SECURITY.md). This makes
/// the report's `environment_policy = minimal` label truthful -- the real executor
/// passes exactly this restricted map, not the inherited developer environment.
///
/// The forced `ZIG_LOCAL_CACHE_DIR` enforces the documented per-worker cache
/// isolation regardless of host env: each test command runs with cwd = its own
/// per-mutant workspace, so a cwd-relative local cache resolves to THAT workspace's
/// `.zig-cache`. `ZIG_LOCAL_CACHE_DIR` is in the allowlist, so without this override
/// a host-set absolute value would be forwarded and collapse every parallel worker's
/// local cache into one shared directory -- violating docs/PERFORMANCE_STRATEGY.md
/// and docs/SANDBOX_SECURITY.md ("No two workers may write the same local cache").
/// Pure: it transforms one map into a new owned map and never spawns a process.
pub fn minimalEnviron(gpa: std.mem.Allocator, parent: *const std.process.Environ.Map, passthrough: []const []const u8) std.mem.Allocator.Error!std.process.Environ.Map {
    var out = std.process.Environ.Map.init(gpa);
    errdefer out.deinit();
    for (env_allowlist) |key| {
        if (parent.get(key)) |value| try out.put(key, value);
    }
    // `test.env_passthrough`: named keys the project declares its suite needs (a
    // database DSN). Copied exactly like the allowlist, absent keys omitted, and
    // hashed into the report's environment_hash like everything else in this map.
    for (passthrough) |key| {
        if (parent.get(key)) |value| try out.put(key, value);
    }
    try out.put("LC_ALL", "C");
    try out.put("LANG", "C");
    // Override any forwarded ZIG_LOCAL_CACHE_DIR with the cwd-relative per-workspace
    // cache (worker_pool.cacheDirIn, the canonical workspace cache-path builder), so
    // each worker's own workspace owns its `.zig-cache` independent of host env.
    try out.put("ZIG_LOCAL_CACHE_DIR", try worker_pool.cacheDirIn(gpa, "."));
    return out;
}

/// Raw outcome of executing one command, produced by an injected `Executor`.
/// `exit_code` is null on timeout or abnormal termination.
pub const RawOutcome = struct {
    exit_code: ?i64,
    timed_out: bool,
    crashed: bool,
    duration_ms: u64,
    stdout: []const u8,
    stderr: []const u8,
};

/// Command execution abstraction. The runner never spawns processes directly;
/// the production executor (std.process-based, side_effect_adapter) is injected
/// by the run command, and tests inject a deterministic mock.
pub const Executor = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, argv: []const []const u8) RawOutcome,

    pub fn run(self: Executor, argv: []const []const u8) RawOutcome {
        return self.runFn(self.ctx, argv);
    }
};

pub const BaselineError = error{InvalidCommand} || std.mem.Allocator.Error;

pub const BaselineResult = struct {
    status: report.BaselineStatus,
    commands: []const report.CommandResult,
};

/// Public ZNTL diagnostic code for a non-passed baseline command status
/// (docs/ERROR_CODES.md). Returns "" for a passed command.
pub fn statusCode(status: report.CommandStatus) []const u8 {
    return switch (status) {
        .passed => "",
        .failed => "ZNTL_RUNNER_COMMAND_FAILED",
        .timeout => "ZNTL_RUNNER_TIMEOUT",
        .compiler_crash => "ZNTL_RUNNER_COMPILER_CRASH",
        .skipped => "",
    };
}

/// Normalize then bound a captured command-output excerpt. Normalization happens
/// BEFORE truncation so the cut point is itself deterministic: ASLR addresses of
/// different widths would otherwise shift the truncation boundary between runs.
/// The normalizer (report.normalizeExcerpt) replaces hex pointer addresses and
/// absolute machine paths with stable placeholders so repeated runs over the same
/// project produce identical excerpts (docs/REPORT_FORMAT.md).
pub fn utf8BoundaryLen(text: []const u8, max_bytes: usize) usize {
    if (text.len <= max_bytes) return text.len;
    var end = max_bytes;
    while (end > 0 and end < text.len and (text[end] & 0xC0) == 0x80) end -= 1;
    return end;
}

/// Normalize-then-bound a captured stream into a long-lived excerpt without
/// retaining the full (up to ~1 MiB) normalized buffer in `arena`. Normalization
/// is done in a caller-provided `scratch` allocator (reset per command, see
/// `classifyCommand`); only the bounded `<= excerpt_limit` slice is duped into the
/// long-lived `arena`. Keeping normalize-before-truncate preserves the
/// deterministic cut point (see the `utf8BoundaryLen` doc comment above).
fn boundedExcerpt(arena: std.mem.Allocator, scratch: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    const normalized = try report.normalizeExcerpt(scratch, text);
    const len = utf8BoundaryLen(normalized, excerpt_limit);
    return arena.dupe(u8, normalized[0..len]);
}

/// Markers that distinguish a Zig compile failure from a post-compile test
/// failure in pinned Zig 0.16 `zig test`/`zig build test` output
/// (docs/REPORT_FORMAT.md, I-010). A compile failure emits compiler diagnostics of
/// the form `<path>:<line>:<col>: error: ...` and never runs the test binary, so
/// neither test-runner completion summary below is present.
///
/// The summary takes one of two forms, and the classifier must recognize BOTH
/// -- the default configured command is `zig build test`, not direct
/// `zig test`:
///   - direct `zig test <file>`: the per-binary runner prints
///     `N passed; M skipped; K failed.` -> substring `passed;`.
///   - `zig build test` (uses the `--listen=-` build protocol): the per-binary
///     `passed;` line is NOT forwarded; instead the aggregated Build Summary
///     carries `N/M tests passed (K failed|crashed)` -> substring `tests passed`,
///     for both assertion failures and runtime panics/crashes. A compile
///     failure's Build Summary (`0/N steps succeeded ...`) has no `tests passed`
///     clause, so either summary marker is decisive positive evidence that
///     compilation succeeded and the test binary ran.
const compile_diagnostic_marker = ": error: ";
const test_runner_summary_marker = "passed;";
const build_test_summary_marker = "tests passed";

/// True if `marker` appears in either captured stream.
fn outputContains(stdout: []const u8, stderr: []const u8, marker: []const u8) bool {
    return std.mem.indexOf(u8, stderr, marker) != null or std.mem.indexOf(u8, stdout, marker) != null;
}

/// Deterministically decide whether a non-zero (non-timeout, non-crash) command
/// outcome is a Zig compile failure rather than a post-compile test failure. The
/// signal is taken only from captured command output -- AI never influences
/// `failure_kind` or `status` (I-001).
///
/// Positive evidence that the test binary actually ran (either runner-summary
/// form) is DECISIVE and overrides the compile-diagnostic marker: a failing test
/// may legitimately print a `path:line:col: error:` line in its asserted output
/// (parser/lint/diagnostic tests), and under `zig build test` -- the default
/// command -- that is exactly the genuine KILL that was previously mis-bucketed as
/// compile_error, deflating the score. Absent any runner summary, a Zig
/// compile diagnostic means compile_error; absent both (for example a custom
/// non-Zig command) the result conservatively stays a test failure, preserving the
/// prior classification.
fn isCompileFailure(stdout: []const u8, stderr: []const u8) bool {
    if (outputContains(stdout, stderr, test_runner_summary_marker)) return false;
    if (outputContains(stdout, stderr, build_test_summary_marker)) return false;
    return outputContains(stdout, stderr, compile_diagnostic_marker);
}

/// Classify one raw outcome into a `CommandResult` for the given phase. Status is
/// derived only from the command outcome (runner evidence authority, I-001); AI
/// cannot influence it. Reused for baseline and mutant command classification.
pub fn classifyCommand(
    arena: std.mem.Allocator,
    phase: report.Phase,
    original: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    raw: RawOutcome,
) std.mem.Allocator.Error!report.CommandResult {
    var status: report.CommandStatus = .passed;
    var failure_kind: report.FailureKind = .none;
    var exit_code: ?i64 = raw.exit_code;

    if (raw.timed_out) {
        status = .timeout;
        failure_kind = .timeout;
        exit_code = null;
    } else if (raw.crashed) {
        status = .compiler_crash;
        failure_kind = .compiler_crash;
        exit_code = null;
    } else if (raw.exit_code) |code| {
        if (code == 0) {
            status = .passed;
            failure_kind = .none;
        } else {
            status = .failed;
            // A compile failure is a normal Zig compile diagnostic with no test
            // run; a post-compile assertion failure stays `test_failure`. This
            // keeps `compile_error` out of the headline kill count (I-010, F-2).
            failure_kind = if (isCompileFailure(raw.stdout, raw.stderr)) .compile_error else .test_failure;
        }
    } else {
        // No exit code without timeout/crash: treat as a command failure.
        status = .failed;
        failure_kind = .test_failure;
    }

    const failure_summary: []const u8 = if (status == .passed) "" else statusCode(status);

    // Normalize each captured stream (up to ~1 MiB) in a per-command scratch arena
    // that is released here, so only the bounded `<= excerpt_limit` excerpts duped
    // into the long-lived `arena` survive. Without this the full normalized buffers
    // would be retained in the never-reset run arena (one per command), growing run
    // memory unboundedly. Backed by the page allocator so deinit returns the pages.
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const scratch_alloc = scratch.allocator();

    return .{
        .command = .{
            .original = original,
            .argv = argv,
            .cwd = cwd,
            .environment_policy = .minimal,
            .shell = false,
        },
        .phase = phase,
        .status = status,
        .exit_code = exit_code,
        .timed_out = raw.timed_out,
        .failure_kind = failure_kind,
        .duration_ms = raw.duration_ms,
        .evidence = .{
            .stdout_excerpt = try boundedExcerpt(arena, scratch_alloc, raw.stdout),
            .stderr_excerpt = try boundedExcerpt(arena, scratch_alloc, raw.stderr),
            .failure_summary = failure_summary,
        },
        .skip_reason = null,
    };
}

/// Run each configured command in order through `executor`, classify it, and
/// derive the baseline status. The baseline passes only if every command passed;
/// any failure, timeout, or compiler crash is a baseline failure (which blocks
/// later mutation execution at the run/report layer).
pub fn runBaseline(
    arena: std.mem.Allocator,
    executor: Executor,
    commands: []const []const u8,
    cwd: []const u8,
) BaselineError!BaselineResult {
    var results: std.ArrayList(report.CommandResult) = .empty;
    for (commands) |original| {
        const parsed = try command.parse(arena, original);
        const argv = switch (parsed) {
            .ok => |a| a,
            .invalid => return error.InvalidCommand,
        };
        const raw = executor.run(argv);
        const result = try classifyCommand(arena, .baseline, original, argv, cwd, raw);
        try results.append(arena, result);
        // Fail-fast: a non-passing baseline command blocks the whole run, so the
        // remaining baseline commands are not executed. Baseline commands are
        // never recorded as `skipped` (report invariant), so the run shortens by
        // truncation -- only the executed prefix ending at the failure is kept.
        if (result.status != .passed) {
            return .{ .status = .failed, .commands = try results.toOwnedSlice(arena) };
        }
    }
    return .{
        .status = .passed,
        .commands = try results.toOwnedSlice(arena),
    };
}
