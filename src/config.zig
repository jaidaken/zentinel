// Layer: deterministic_core
//
// Typed zentinel config: parses the in-tree TOML subset (src/config_toml.zig),
// applies documented defaults, validates against docs/CONFIG_SPEC.md, normalizes
// paths, and expands mutator special values deterministically. Pure: no side
// effects beyond the caller-provided arena.
const std = @import("std");
const toml = @import("config_toml.zig");

pub const Code = enum {
    parse_error,
    unknown_key,
    invalid_value,
    invalid_command,
    experimental_backend,
    not_found,

    pub fn token(self: Code) []const u8 {
        return switch (self) {
            .parse_error => "ZNTL_CONFIG_PARSE_ERROR",
            .unknown_key => "ZNTL_CONFIG_UNKNOWN_KEY",
            .invalid_value => "ZNTL_CONFIG_INVALID_VALUE",
            .invalid_command => "ZNTL_CONFIG_INVALID_COMMAND",
            .experimental_backend => "ZNTL_CONFIG_EXPERIMENTAL_BACKEND",
            .not_found => "ZNTL_CONFIG_NOT_FOUND",
        };
    }
};

pub const Diagnostic = struct {
    code: Code = .parse_error,
    section: []const u8 = "",
    key: []const u8 = "",
    message: []const u8 = "",
    line: usize = 0,
};

pub const Error = error{Invalid} || std.mem.Allocator.Error;

pub const Config = struct {
    project_name: []const u8,
    project_root: []const u8,
    include: []const []const u8,
    exclude: []const []const u8,
    /// `../name` entries linked beside every per-mutant workspace copy, so a path
    /// dependency or a `b.path("../x")` the package's build reads resolves there.
    workspace_siblings: []const []const u8,
    zig_version: []const u8,
    zig_modes: []const []const u8,
    backend_default: []const u8,
    backend_experimental: []const []const u8,
    mutators_enabled: []const []const u8,
    test_commands: []const []const u8,
    /// Parent environment variable NAMES copied into the minimal command
    /// environment on top of the fixed allowlist (a DB-backed suite's DSN).
    test_env_passthrough: []const []const u8,
    test_selection: []const u8,
    test_timeout_ms: i64,
    baseline_required: bool,
    run_jobs: i64,
    cache_enabled: bool,
    cache_directory: []const u8,
    report_formats: []const []const u8,
    report_output_dir: []const u8,
    ai_enabled: bool,
    ai_provider: []const u8,
    ai_remote_allowed: bool,
    ai_source_context_lines: i64,
    ai_redact_patterns: []const []const u8,
};

const Stability = enum { stable, preview };
const OperatorInfo = struct { name: []const u8, phase: u8, stability: Stability };

// Operator registry mirrors docs/MUTATOR_SPEC.md.
const operators = [_]OperatorInfo{
    .{ .name = "arithmetic_add_sub", .phase = 1, .stability = .stable },
    .{ .name = "arithmetic_mul_div", .phase = 1, .stability = .stable },
    .{ .name = "equality_swap", .phase = 1, .stability = .stable },
    .{ .name = "comparison_boundary", .phase = 1, .stability = .stable },
    .{ .name = "logical_and_or", .phase = 1, .stability = .stable },
    .{ .name = "boolean_literal", .phase = 1, .stability = .stable },
    .{ .name = "optional_orelse_unreachable", .phase = 2, .stability = .stable },
    .{ .name = "optional_orelse_default", .phase = 2, .stability = .preview },
    .{ .name = "optional_null_check", .phase = 2, .stability = .stable },
    .{ .name = "error_catch_unreachable", .phase = 2, .stability = .stable },
    .{ .name = "error_catch_return", .phase = 2, .stability = .preview },
    .{ .name = "try_to_catch_unreachable", .phase = 2, .stability = .preview },
    .{ .name = "defer_remove", .phase = 2, .stability = .preview },
    .{ .name = "errdefer_remove", .phase = 2, .stability = .stable },
    .{ .name = "allocator_failure_path", .phase = 2, .stability = .preview },
    .{ .name = "comptime_branch_flip", .phase = 2, .stability = .preview },
    .{ .name = "comptime_value_boundary", .phase = 2, .stability = .preview },
    .{ .name = "safety_unreachable_to_return", .phase = 2, .stability = .preview },
    .{ .name = "integer_literal_boundary", .phase = 2, .stability = .stable },
    .{ .name = "loop_boundary", .phase = 2, .stability = .stable },
};

const known_modes = [_][]const u8{ "Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall" };
const known_backends = [_][]const u8{ "ast", "zir" };
// `impact_graph` is deliberately omitted: its resolver is currently an exact
// alias of `same_file_then_package` (src/test_selection.zig), so accepting it
// would record a false `impact_graph` strategy in the report for behavior that is
// really same-file-then-package. The enum variant is kept for forward-compat
// until a real impact-graph resolver lands (docs/TEST_SELECTION.md).
const known_selections = [_][]const u8{ "same_file_then_package", "same_file", "package", "all" };
const known_providers = [_][]const u8{ "disabled", "stub", "local", "remote" };
const known_report_formats = [_][]const u8{ "text", "json", "jsonl", "junit" };
const default_exclude = [_][]const u8{ ".zig-cache/**", "zig-out/**", "test/**" };
const default_redact = [_][]const u8{ "(?i)api[_-]?key", "(?i)token" };

// (section, key) pairs accepted by the v1 schema.
const KnownKey = struct { section: []const u8, key: []const u8 };
const known_keys = [_]KnownKey{
    .{ .section = "project", .key = "name" },
    .{ .section = "project", .key = "root" },
    .{ .section = "project", .key = "include" },
    .{ .section = "project", .key = "exclude" },
    .{ .section = "project", .key = "workspace_siblings" },
    .{ .section = "zig", .key = "version" },
    .{ .section = "zig", .key = "modes" },
    .{ .section = "backend", .key = "default" },
    .{ .section = "backend", .key = "experimental" },
    .{ .section = "mutators", .key = "enabled" },
    .{ .section = "test", .key = "commands" },
    .{ .section = "test", .key = "env_passthrough" },
    .{ .section = "test", .key = "selection" },
    .{ .section = "test", .key = "timeout_ms" },
    .{ .section = "test", .key = "baseline_required" },
    .{ .section = "run", .key = "jobs" },
    .{ .section = "cache", .key = "enabled" },
    .{ .section = "cache", .key = "directory" },
    .{ .section = "report", .key = "formats" },
    .{ .section = "report", .key = "output_dir" },
    .{ .section = "ai", .key = "enabled" },
    .{ .section = "ai", .key = "provider" },
    .{ .section = "ai", .key = "remote_allowed" },
    .{ .section = "ai", .key = "source_context_lines" },
    .{ .section = "ai", .key = "redact_patterns" },
};

fn inList(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

fn knownKey(section: []const u8, key: []const u8) bool {
    for (known_keys) |kk| {
        if (std.mem.eql(u8, kk.section, section) and std.mem.eql(u8, kk.key, key)) return true;
    }
    return false;
}

fn findOperator(name: []const u8) ?OperatorInfo {
    for (operators) |op| {
        if (std.mem.eql(u8, op.name, name)) return op;
    }
    return null;
}

/// True if `name` is a registered mutation operator (the canonical registry that
/// mirrors docs/MUTATOR_SPEC.md). Exposed so CLI parsers can reject an unknown
/// `--operator` value up front instead of silently matching no candidate.
pub fn isKnownOperator(name: []const u8) bool {
    return findOperator(name) != null;
}

fn fail(diag: *Diagnostic, code: Code, section: []const u8, key: []const u8, message: []const u8) Error {
    diag.* = .{ .code = code, .section = section, .key = key, .message = message };
    return error.Invalid;
}

const Lookup = struct {
    doc: toml.Document,

    fn find(self: Lookup, section: []const u8, key: []const u8) ?toml.Value {
        for (self.doc.entries) |e| {
            if (std.mem.eql(u8, e.section, section) and std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    fn getString(self: Lookup, section: []const u8, key: []const u8, default: []const u8, diag: *Diagnostic) Error![]const u8 {
        const v = self.find(section, key) orelse return default;
        return switch (v) {
            .string => |s| s,
            else => fail(diag, .invalid_value, section, key, "expected a string"),
        };
    }

    fn getBool(self: Lookup, section: []const u8, key: []const u8, default: bool, diag: *Diagnostic) Error!bool {
        const v = self.find(section, key) orelse return default;
        return switch (v) {
            .boolean => |b| b,
            else => fail(diag, .invalid_value, section, key, "expected a boolean"),
        };
    }

    fn getInt(self: Lookup, section: []const u8, key: []const u8, default: i64, diag: *Diagnostic) Error!i64 {
        const v = self.find(section, key) orelse return default;
        return switch (v) {
            .integer => |n| n,
            else => fail(diag, .invalid_value, section, key, "expected an integer"),
        };
    }

    fn getArray(self: Lookup, section: []const u8, key: []const u8, default: []const []const u8, diag: *Diagnostic) Error![]const []const u8 {
        const v = self.find(section, key) orelse return default;
        return switch (v) {
            .string_array => |a| a,
            else => fail(diag, .invalid_value, section, key, "expected an array of strings"),
        };
    }
};

fn windowsAbsolute(path: []const u8) bool {
    if (path.len >= 2 and path[0] == '\\' and path[1] == '\\') return true;
    if (path.len < 3) return false;
    const drive = path[0];
    const is_drive = (drive >= 'a' and drive <= 'z') or (drive >= 'A' and drive <= 'Z');
    return is_drive and path[1] == ':' and (path[2] == '/' or path[2] == '\\');
}

fn outsideRoot(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path) or windowsAbsolute(path)) return true;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return true;
    }
    return false;
}

/// Public form of the project-root containment check. A path is outside the
/// project root when it is absolute or contains a `..` segment. Used by
/// `zentinel check` to validate include/exclude paths (docs/CONFIG_SPEC.md).
pub fn isOutsideRoot(path: []const u8) bool {
    return outsideRoot(path);
}

/// The bare name of a `project.workspace_siblings` entry, or null when the entry
/// is not exactly `../<one segment>`. One parent level only: the link is placed
/// beside the workspace copy, which sits one level below where `..` lands.
pub fn siblingName(entry: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, entry, "../")) return null;
    const name = entry["../".len..];
    if (name.len == 0) return null;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return null;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return null;
    return name;
}

/// True if writing project-relative `path` under `root_dir` would traverse a
/// symlinked path component. The string-level `outsideRoot` check rejects
/// absolute paths and `..` segments but never resolves symlinks, so an untrusted
/// checkout can ship an in-tree symlink to an out-of-root directory (or a
/// symlinked output file) and redirect a report/cache write -- which follows
/// symlinks in the sub-path -- outside the project tree (docs/SANDBOX_SECURITY.md,
/// audit F-3). This refuses any symlinked component, an intermediate directory or
/// the final file, by no-follow-stat'ing each path prefix. It reads the
/// filesystem deterministically (reads only; like `project_model.discover`), so
/// it stays in the deterministic core next to `isOutsideRoot`; the caller must
/// still apply `isOutsideRoot` first to reject absolute/`..` paths.
///
/// TOCTOU residue (documented Phase-1 limitation): this is a check-then-write
/// guard, not an atomic open. A component stat'd here as a non-symlink could be
/// swapped for a symlink between this check and the subsequent write, which then
/// follows it. Phase 1 does not close that window (no `openat`/`O_NOFOLLOW`
/// rewrite); it raises the bar against a statically planted in-tree symlink in an
/// untrusted checkout, the realistic threat for a local mutation run
/// (docs/SANDBOX_SECURITY.md, Symlink Policy).
pub fn outputPathHasSymlink(io: std.Io, root_dir: std.Io.Dir, path: []const u8) bool {
    var start: usize = 0;
    while (start < path.len) {
        // Split on both separators ("/" and "\\") so a backslash-separated prefix
        // is checked component-by-component too, matching how `outsideRoot`
        // tokenizes paths; otherwise a `dir\link` component would be stat'd as one
        // opaque name and its symlinked head missed.
        const slash = std.mem.indexOfAnyPos(u8, path, start, "/\\") orelse path.len;
        if (slash > start) {
            // No-follow stat of the prefix ending at this component: only the
            // final component is checked for being a symlink, and we check every
            // prefix in increasing length, so the earliest symlinked component is
            // caught before any later prefix would traverse through it.
            const prefix = path[0..slash];
            if (root_dir.statFile(io, prefix, .{ .follow_symlinks = false })) |st| {
                if (st.kind == .sym_link) return true;
            } else |_| {
                // A component that does not exist yet cannot be a symlink; a stat
                // error (including not-found) is not by itself an escape.
            }
        }
        start = slash + 1;
    }
    return false;
}

/// Shared read/write containment predicate for project-relative paths. It
/// combines the lexical root check with the same no-follow symlink component
/// guard used for report outputs, so adapters can apply one contract before any
/// root-relative filesystem read, write, workspace creation, or report path.
pub fn pathEscapesRoot(io: std.Io, root_dir: std.Io.Dir, path: []const u8) bool {
    return isOutsideRoot(path) or outputPathHasSymlink(io, root_dir, path);
}

// Paths are normalized to forward slashes per docs/CONFIG_SPEC.md.
fn normalizePath(arena: std.mem.Allocator, s: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    const out = try arena.dupe(u8, s);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

fn normalizePaths(arena: std.mem.Allocator, list: []const []const u8) Error![]const []const u8 {
    const out = try arena.alloc([]const u8, list.len);
    for (list, 0..) |p, idx| out[idx] = try normalizePath(arena, p);
    return out;
}

fn expandMutators(arena: std.mem.Allocator, enabled: []const []const u8, diag: *Diagnostic) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (enabled) |item| {
        if (std.mem.eql(u8, item, "phase1")) {
            for (operators) |op| {
                if (op.phase == 1 and op.stability == .stable) try appendUnique(arena, &out, op.name);
            }
        } else if (std.mem.eql(u8, item, "phase2")) {
            for (operators) |op| {
                if (op.phase == 2 and op.stability == .stable) try appendUnique(arena, &out, op.name);
            }
        } else if (std.mem.eql(u8, item, "all_stable")) {
            for (operators) |op| {
                if (op.stability == .stable) try appendUnique(arena, &out, op.name);
            }
        } else if (findOperator(item)) |op| {
            // A `preview` operator has no collector wired into the pipeline, so
            // enabling it would silently emit zero mutants. Reject it instead so
            // every operator that loads can actually emit.
            if (op.stability != .stable) {
                return fail(diag, .invalid_value, "mutators", "enabled", try std.fmt.allocPrint(arena, "operator '{s}' is preview-only and not yet emitted; only stable operators can be enabled", .{item}));
            }
            try appendUnique(arena, &out, item);
        } else {
            return fail(diag, .invalid_value, "mutators", "enabled", try std.fmt.allocPrint(arena, "unknown mutator name '{s}'", .{item}));
        }
    }
    return out.toOwnedSlice(arena);
}

fn appendUnique(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), name: []const u8) Error!void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try list.append(arena, name);
}

pub fn load(arena: std.mem.Allocator, source: []const u8, diag: *Diagnostic) Error!Config {
    var pdiag: toml.Diagnostic = .{};
    const doc = toml.parse(arena, source, &pdiag) catch {
        diag.* = .{ .code = .parse_error, .message = pdiag.message, .line = pdiag.line };
        return error.Invalid;
    };
    const look = Lookup{ .doc = doc };

    // Reject unknown sections/keys.
    for (doc.entries) |e| {
        if (!knownKey(e.section, e.key)) {
            return fail(diag, .unknown_key, e.section, e.key, "unknown config section or key");
        }
    }

    // [zig]
    const zig_version = try look.getString("zig", "version", "0.16.0", diag);
    if (!std.mem.eql(u8, zig_version, "0.16.0")) {
        return fail(diag, .invalid_value, "zig", "version", "only Zig 0.16.0 is supported");
    }
    const zig_modes = try look.getArray("zig", "modes", &.{"Debug"}, diag);
    // Multiple modes are accepted now that the safety-mode matrix exists (task
    // 058); each entry must still be a known Zig mode.
    for (zig_modes) |m| {
        if (!inList(&known_modes, m)) return fail(diag, .invalid_value, "zig", "modes", "unknown Zig mode");
    }
    // An explicit `modes = []` is meaningless intent that the matrix would silently
    // redirect to Debug; reject it (omitting `modes` keeps the Debug default),
    // matching how empty `test.commands` is handled below.
    if (zig_modes.len == 0) return fail(diag, .invalid_value, "zig", "modes", "modes must not be empty");

    // [backend]
    const backend_default = try look.getString("backend", "default", "ast", diag);
    if (!inList(&known_backends, backend_default)) {
        return fail(diag, .invalid_value, "backend", "default", "unknown backend");
    }
    const backend_experimental = try look.getArray("backend", "experimental", &.{}, diag);
    for (backend_experimental) |b| {
        if (!inList(&known_backends, b)) return fail(diag, .invalid_value, "backend", "experimental", "unknown backend");
    }
    if (std.mem.eql(u8, backend_default, "zir") and
        !inList(backend_experimental, backend_default))
    {
        return fail(diag, .experimental_backend, "backend", "default", "experimental backend requires explicit opt-in");
    }

    // [mutators]
    const enabled_raw = try look.getArray("mutators", "enabled", &.{"phase1"}, diag);
    const mutators_enabled = try expandMutators(arena, enabled_raw, diag);
    // An explicit `enabled = []` validates clean but disables all mutation; reject
    // it as meaningless intent (omitting `enabled` keeps the phase1 default),
    // mirroring the zig.modes empty-guard above.
    if (mutators_enabled.len == 0) return fail(diag, .invalid_value, "mutators", "enabled", "enabled must not be empty");

    // [test]
    const test_commands = try look.getArray("test", "commands", &.{"zig build test"}, diag);
    if (test_commands.len == 0) return fail(diag, .invalid_value, "test", "commands", "test commands must not be empty");
    for (test_commands) |c| {
        if (c.len == 0) return fail(diag, .invalid_value, "test", "commands", "test command must not be empty");
    }
    const test_env_passthrough = try look.getArray("test", "env_passthrough", &.{}, diag);
    for (test_env_passthrough) |name| {
        // A name, never an assignment: the config says WHICH parent variables cross,
        // and the parent holds their values.
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '=') != null) {
            return fail(diag, .invalid_value, "test", "env_passthrough", "each entry is an environment variable NAME (non-empty, no '=')");
        }
    }
    const test_selection = try look.getString("test", "selection", "same_file_then_package", diag);
    // `impact_graph` is rejected here (reserved / not-yet-implemented): its
    // resolver is currently an exact alias of same_file_then_package, so accepting
    // it would record a misleading strategy. Any unrecognized strategy is likewise
    // rejected outright, never silently downgraded to same_file_then_package or all
    // (docs/TEST_SELECTION.md).
    if (!inList(&known_selections, test_selection)) {
        return fail(diag, .invalid_value, "test", "selection", "unknown or not-yet-supported selection strategy");
    }
    const test_timeout_ms = try look.getInt("test", "timeout_ms", 30000, diag);
    // A timeout of 0 (or negative) disables the timeout entirely (see
    // cli.timeoutFromMs), leaving hung tests unbounded and never classifying a
    // mutant as `timeout`. Reject it so the "enforce timeouts" sandbox contract
    // (docs/SANDBOX_SECURITY.md) and F-017 stay enforceable.
    if (test_timeout_ms <= 0) return fail(diag, .invalid_value, "test", "timeout_ms", "timeout must be a positive integer");
    const baseline_required = try look.getBool("test", "baseline_required", true, diag);
    if (!baseline_required) return fail(diag, .invalid_value, "test", "baseline_required", "baseline skipping is reserved for a future policy");

    // [run]
    const run_jobs = try look.getInt("run", "jobs", 1, diag);
    if (run_jobs < 1) return fail(diag, .invalid_value, "run", "jobs", "worker count must be a positive integer");

    // [report]
    const report_output_dir = try normalizePath(arena, try look.getString("report", "output_dir", "zig-out/zentinel", diag));
    if (outsideRoot(report_output_dir)) {
        return fail(diag, .invalid_value, "report", "output_dir", "output directory must stay within the project root");
    }
    const report_formats = try look.getArray("report", "formats", &.{ "text", "json" }, diag);
    for (report_formats) |fmt| {
        if (!inList(&known_report_formats, fmt)) {
            return fail(diag, .invalid_value, "report", "formats", "report format must be text, json, jsonl, or junit");
        }
    }

    // [ai]
    const ai_provider = try look.getString("ai", "provider", "disabled", diag);
    if (!inList(&known_providers, ai_provider)) {
        return fail(diag, .invalid_value, "ai", "provider", "unknown AI provider");
    }
    const ai_remote_allowed = try look.getBool("ai", "remote_allowed", false, diag);
    if (std.mem.eql(u8, ai_provider, "remote") and !ai_remote_allowed) {
        return fail(diag, .invalid_value, "ai", "provider", "remote provider requires remote_allowed = true");
    }
    const ai_context_lines = try look.getInt("ai", "source_context_lines", 4, diag);
    if (ai_context_lines < 0) return fail(diag, .invalid_value, "ai", "source_context_lines", "context lines must not be negative");

    const project_root = try normalizePath(arena, try look.getString("project", "root", ".", diag));
    if (outsideRoot(project_root)) {
        return fail(diag, .invalid_value, "project", "root", "project root must stay within the selected root");
    }

    // An explicit `include = []` validates clean but selects no files to mutate;
    // reject it as meaningless intent (omitting `include` keeps the default glob),
    // mirroring the empty-list guards for zig.modes and mutators.enabled.
    const include = try look.getArray("project", "include", &.{"src/**/*.zig"}, diag);
    if (include.len == 0) return fail(diag, .invalid_value, "project", "include", "include must not be empty");

    const workspace_siblings = try normalizePaths(arena, try look.getArray("project", "workspace_siblings", &.{}, diag));
    for (workspace_siblings) |entry| {
        if (siblingName(entry) == null) {
            return fail(diag, .invalid_value, "project", "workspace_siblings", "each entry is exactly `../<name>`: one directory or file beside the project root");
        }
    }

    return Config{
        .project_name = try look.getString("project", "name", "example", diag),
        .project_root = project_root,
        .include = try normalizePaths(arena, include),
        .exclude = try normalizePaths(arena, try look.getArray("project", "exclude", &default_exclude, diag)),
        .workspace_siblings = workspace_siblings,
        .zig_version = zig_version,
        .zig_modes = zig_modes,
        .backend_default = backend_default,
        .backend_experimental = backend_experimental,
        .mutators_enabled = mutators_enabled,
        .test_commands = test_commands,
        .test_env_passthrough = test_env_passthrough,
        .test_selection = test_selection,
        .test_timeout_ms = test_timeout_ms,
        .baseline_required = baseline_required,
        .run_jobs = run_jobs,
        .cache_enabled = try look.getBool("cache", "enabled", true, diag),
        .cache_directory = try normalizePath(arena, try look.getString("cache", "directory", ".zig-cache/zentinel", diag)),
        .report_formats = report_formats,
        .report_output_dir = report_output_dir,
        .ai_enabled = try look.getBool("ai", "enabled", false, diag),
        .ai_provider = ai_provider,
        .ai_remote_allowed = ai_remote_allowed,
        .ai_source_context_lines = ai_context_lines,
        .ai_redact_patterns = try look.getArray("ai", "redact_patterns", &default_redact, diag),
    };
}
