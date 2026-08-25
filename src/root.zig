// Layer: deterministic_core
const std = @import("std");

/// Stable project name. Deterministic compile-time constant.
pub const project_name = "zentinel";

/// Project version. Single source of truth lives in `version.zig`; this is the
/// public re-export consumed by `zentinel version`, the cache key, and the AI
/// context. Pinned against build.zig.zon by test/version_parity_test.zig.
pub const version = @import("version.zig").version;

/// Zig version policy and discovery classification (deterministic core).
pub const zig_version = @import("zig_version.zig");

/// Pinned supported Zig version, owned by the single version-policy module
/// `zig_version`. `zentinel version` prints it as a policy label; `version` and
/// `check` compare real `zig version` discovery against this pin.
pub const supported_zig_version = zig_version.supported_version;

/// Config parsing and validation (deterministic core).
pub const config = @import("config.zig");
pub const config_toml = @import("config_toml.zig");

/// Shared shell-free command-string parser (deterministic core).
pub const command = @import("command.zig");

/// `zentinel check` orchestration (deterministic core).
pub const check_command = @import("check_command.zig");

/// Shared mutant model + durable `m_...` identity algorithm (deterministic core).
pub const mutant = @import("mutant.zig");

/// Safety/optimization mode matrix model + classification (deterministic core).
pub const safety_modes = @import("safety_modes.zig");

/// Deterministic seeded property-test generator (deterministic core). A pure
/// seeded stream: the same seed always reproduces the same cases. No AI.
pub const property = struct {
    /// Test-support / CI-only infrastructure: exported so the test suite (and
    /// CI seed-determinism checks) can import the generator directly. No binary
    /// command path imports it; do NOT remove -- tests depend on this export.
    pub const generator = @import("property/generator.zig");
};

/// Pure byte <-> line/column source mapping (deterministic core).
pub const source_map = @import("source_map.zig");

/// Config-driven project model + source discovery (deterministic core).
pub const project_model = @import("project_model.zig");

/// AST parsing adapter over the pinned std.zig.Ast (deterministic core).
pub const ast_backend = @import("ast_backend.zig");

/// Experimental ZIR backend prototype (docs/ZIR_BACKEND.md). Opt-in only;
/// re-tags exactly-mapped AST candidates as experimental and records unsupported
/// operators as out-of-report diagnostics.
pub const zir_backend = @import("zir_backend.zig");

// The experimental AIR backend was retired: meaningful AIR-level mutation
// mapping is infeasible without Zig's SEMA stage, and the prototype only
// relabeled AST candidates. AST is the stable default; ZIR is the experimental
// lowered-IR backend.

/// AST mutators (deterministic core). Each recognizer emits candidates through
/// the shared collector; mutators may not import runner/sandbox/report/cli/ai.
pub const mutators = struct {
    pub const arithmetic = @import("mutators/arithmetic.zig");
    pub const comparison = @import("mutators/comparison.zig");
    pub const logical = @import("mutators/logical.zig");
    pub const boolean = @import("mutators/boolean.zig");
    pub const optional = @import("mutators/optional.zig");
    pub const error_path = @import("mutators/error_path.zig");
    pub const integer_boundary = @import("mutators/integer_boundary.zig");
    pub const loop_boundary = @import("mutators/loop_boundary.zig");
};

/// Deterministic patch sandbox: applies one mutant to a source copy (deterministic core).
pub const sandbox = @import("sandbox.zig");

/// Baseline runner: classifies test-command outcomes via an injected executor (deterministic core).
pub const runner = @import("runner.zig");

/// Wall-bounded process execution with process-group teardown (side-effect adapter).
/// Replaces `std.process.run`, whose timeout is per-read and whose kill reaches
/// only the direct child; see the module header.
pub const exec = @import("exec.zig");

/// Mutant runner: runs one patched mutant and classifies the result (deterministic core).
pub const mutant_runner = @import("mutant_runner.zig");

/// Typed report model + deterministic JSON serialization (deterministic core).
pub const report = @import("report.zig");

/// `zentinel run` Phase 1 orchestration + report assembly (deterministic core).
pub const run_command = @import("run_command.zig");

/// CLI-layer disk-backed result store (cross-run result reuse). Injected into the
/// core's `run_command.ResultStore` interface; the core itself never does file I/O.
pub const result_store = @import("result_store.zig");

/// Bounded parallel worker pool: deterministic index->result mapping and
/// content-addressed per-worker workspace isolation (deterministic core).
pub const worker_pool = @import("worker_pool.zig");

/// `zentinel list-mutants` candidate generation + rendering (deterministic core).
pub const list_mutants_command = @import("list_mutants_command.zig");

/// Same-file test selection + fallback (deterministic core).
pub const test_selection = @import("test_selection.zig");

/// Compiler-oracle semantic filter (deterministic core, ZIR_IMPROVEMENTS SEM-1c):
/// replaces the heuristic `expected_compile` prediction with the compiler's actual
/// verdict, derived from the mutant's terminal run status (the runner already
/// compiled it). SEM-1b's TCE equivalence half was descoped (0 measured payoff).
pub const semantic_filter = @import("semantic_filter.zig");

/// Shared error-code tokens (deterministic core).
pub const error_codes = @import("error_codes.zig");

/// Doctest Markdown fenced-block parser + block model + case extraction
/// (deterministic core).
pub const doctest = struct {
    pub const block = @import("doctest/block.zig");
    pub const parser = @import("doctest/parser.zig");
    pub const case = @import("doctest/case.zig");
    pub const extractor = @import("doctest/extractor.zig");
    pub const workspace = @import("doctest/workspace.zig");
    pub const runner = @import("doctest/runner.zig");
    pub const normalizer = @import("doctest/normalizer.zig");
    pub const matcher = @import("doctest/matcher.zig");
    pub const snapshot = @import("doctest/snapshot.zig");
    pub const report = @import("doctest/report.zig");
    /// Test-support / CI-only infrastructure: exported for the test suite, not
    /// referenced on any binary command path. Do NOT remove -- tests import it.
    pub const mutator_doctest = @import("doctest/mutator_doctest.zig");
    pub const cache = @import("doctest/cache.zig");
    pub const mutation_experiment = @import("doctest/mutation_experiment.zig");
    pub const mutation_id = @import("doctest/mutation_id.zig");
};

/// AI provider plumbing, context construction, and privacy redaction. AI is
/// advisory-only and never influences deterministic-core decisions.
pub const ai = struct {
    pub const provider = @import("ai/provider.zig");
    pub const context = @import("ai/context.zig");
    pub const redaction = @import("ai/redaction.zig");
    pub const command = @import("ai/command.zig");
    pub const doctest_command = @import("ai/doctest_command.zig");
};

/// `zentinel doctest` command orchestration (deterministic core).
pub const doctest_command = @import("doctest_command.zig");

/// Deterministic cache key construction + cache metadata (deterministic core).
pub const cache = @import("cache.zig");

/// Report renderers: survivor-focused text, streaming JSONL, and JUnit XML
/// (deterministic core). All derive from the canonical report.v1 model.
pub const report_text = @import("report_text.zig");
pub const report_jsonl = @import("report_jsonl.zig");
pub const report_junit = @import("report_junit.zig");

/// Whether a `--test-command` value can be safely embedded as a TOML basic-string
/// array element in zentinel.toml. zentinel's TOML reader (src/config_toml.zig)
/// has NO string escapes, so a value containing `"` would close the string early
/// and inject extra array elements (e.g. `zig test", "evil` -> two commands), and
/// a control byte (newline/tab/...) would malform the file. Such a value is
/// unrepresentable; `dispatchInit` rejects it rather than write an injected or
/// broken config. Backslash is read literally by the reader, so it is safe.
pub fn testCommandEmbeddable(value: []const u8) bool {
    for (value) |c| {
        if (c == '"' or c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

/// Whether a project name can be embedded as the `[project] name` value in
/// zentinel's escape-free TOML. Same byte constraint as `testCommandEmbeddable`
/// (no `"`, no control bytes), plus non-empty: an empty inferred name would
/// write a useless `name = ""`.
pub fn projectNameEmbeddable(name: []const u8) bool {
    return name.len > 0 and testCommandEmbeddable(name);
}

fn isZonNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn skipZonWhitespace(zon: []const u8, start: usize) usize {
    var j = start;
    while (j < zon.len) : (j += 1) {
        switch (zon[j]) {
            ' ', '\t', '\r', '\n' => {},
            else => return j,
        }
    }
    return j;
}

/// The contents of a zon double-quoted string starting at `start` (just past the
/// opening quote). Values containing escapes are rejected (a verbatim slice
/// would mis-decode them), as is an empty string.
fn zonQuotedValue(zon: []const u8, start: usize) ?[]const u8 {
    const end = std.mem.indexOfScalarPos(u8, zon, start, '"') orelse return null;
    if (end == start) return null;
    const value = zon[start..end];
    if (std.mem.indexOfScalar(u8, value, '\\') != null) return null;
    return value;
}

/// Best-effort extraction of the `.name` field value from `build.zig.zon`
/// bytes, used by `init` to infer the generated `[project] name`. Recognizes
/// the forms Zig writes: `.name = .foo`, `.name = .@"foo"`, and the legacy
/// `.name = "foo"`. Purely lexical by design -- inference is a default, never a
/// dependency on zon validity -- and returns a slice into `zon` or null.
pub fn projectNameFromZon(zon: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, zon, search, ".name")) |idx| {
        search = idx + ".name".len;
        var j = search;
        // `.names`/`.name_x` are different fields, not a match.
        if (j < zon.len and isZonNameChar(zon[j])) continue;
        j = skipZonWhitespace(zon, j);
        if (j >= zon.len or zon[j] != '=') continue;
        j = skipZonWhitespace(zon, j + 1);
        if (j >= zon.len) return null;
        if (zon[j] == '"') return zonQuotedValue(zon, j + 1);
        if (zon[j] != '.') continue;
        j += 1;
        if (j + 1 < zon.len and zon[j] == '@' and zon[j + 1] == '"') return zonQuotedValue(zon, j + 2);
        const ident_start = j;
        while (j < zon.len and isZonNameChar(zon[j])) j += 1;
        if (j > ident_start) return zon[ident_start..j];
    }
    return null;
}

/// Replace exactly the template needle within `haystack` (allocating copy).
fn replaceAlloc(arena: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    const size = std.mem.replacementSize(u8, haystack, needle, replacement);
    const out = try arena.alloc(u8, size);
    _ = std.mem.replace(u8, haystack, needle, replacement, out);
    return out;
}

/// Render the deterministic default `zentinel.toml`, optionally substituting the
/// baseline test command for config-aware `init --test-command` and the
/// `[project] name` for `init --name` / adapter-side inference. Precondition:
/// `dispatchInit` (or the adapter's `projectNameEmbeddable` gate) has rejected
/// any value the escape-free TOML reader cannot embed, so the raw substitutions
/// stay single quoted values and are injection-safe.
pub fn initConfigText(arena: std.mem.Allocator, test_command: ?[]const u8, name_override: ?[]const u8) ![]const u8 {
    var text: []const u8 = default_config;
    if (name_override) |name| {
        if (!std.mem.eql(u8, name, "example")) {
            const replacement = try std.fmt.allocPrint(arena, "name = \"{s}\"", .{name});
            text = try replaceAlloc(arena, text, "name = \"example\"", replacement);
        }
    }
    if (test_command) |cmd| {
        const replacement = try std.fmt.allocPrint(arena, "commands = [\"{s}\"]", .{cmd});
        text = try replaceAlloc(arena, text, "commands = [\"zig build test\"]", replacement);
    }
    return text;
}

/// Deterministic, snapshot-tested `--help` output. Mirrors test/snapshots/cli_help.txt.
pub const help_text =
    \\zentinel - Zig-native mutation testing
    \\
    \\Usage:
    \\  zentinel <command> [options]
    \\
    \\Commands:
    \\  init           create zentinel.toml
    \\  version        print version information
    \\  check          validate config and environment
    \\  list-mutants   list generated mutants without running tests
    \\  run            run mutation testing
    \\  doctest        validate executable documentation
    \\  explain        explain one mutant using advisory AI
    \\  suggest        suggest tests for one mutant using advisory AI
    \\  review-tests   review survivors using advisory AI
    \\
    \\Doctest subcommands (advisory AI is opt-in):
    \\  doctest explain <case-ref>            explain a failing doctest case
    \\  doctest suggest <doc-path>            suggest examples for a doc
    \\  doctest review-snapshot <case-ref>    review snapshot differences
    \\  doctest suggest-missing [--file ...]  list public docs needing examples
    \\  doctest explain-survivor <ref>        explain a mutation-aware survivor
    \\  doctest --mutate --file <doc-path>    run the mutation-aware doctest pass
    \\
    \\Report formats:
    \\  run --report <text|json|jsonl|junit>
    \\  doctest --format <text|json>
    \\
    \\Run 'zentinel <command> --help' for command-specific options.
    \\
;

/// Commands that own a per-command `--help` usage block (docs/CLI_SPEC.md).
/// `route` returns `.command_help` for `<command> --help|-h`; the adapter
/// prints `commandHelpText` to stdout and exits 0.
pub const HelpTopic = enum {
    run,
    init,
    check,
    list_mutants,
    doctest,
    explain,
    suggest,
    review_tests,
    version,
};

/// Shared trailing block for commands that consume the leading global options.
/// Starts with an empty line because the preceding option list ends without a
/// trailing newline, so the concatenation yields one separating blank line.
const global_options_help =
    \\
    \\
    \\Global options (before the command): --config <path>, --root <path>, --no-color
    \\
;

/// Shared options block for the advisory AI commands (ai.command.SharedOptions).
/// Leading empty line for the same concatenation reason as global_options_help.
const ai_shared_options_help =
    \\
    \\Options:
    \\  --ai-provider <disabled|stub|local|remote>
    \\                         explicit advisory AI provider opt-in for this invocation
    \\  --input-report <path>  mutation report to read (default zig-out/zentinel/report.json)
    \\  --format <text|json>   select the response rendering
;

pub const run_help_text =
    \\zentinel run - run mutation testing
    \\
    \\Usage:
    \\  zentinel [global options] run [options]
    \\
    \\Options:
    \\  --operator <name>      run only one documented operator's mutants
    \\  --mutant <id>          run one durable mutant id
    \\  --mode <Debug|ReleaseSafe|ReleaseFast|ReleaseSmall>
    \\                         override configured zig.modes for this invocation
    \\  --jobs <n>             worker count for parallel mutant execution
    \\  --changed-only         mutate only files changed in the working tree (vs HEAD)
    \\  --diff <ref>           mutate only files changed vs <ref> (e.g. main)
    \\  --scope-files <a,b>    mutate only this explicit comma-separated file list
    \\  --fail-on-survivors    exit 1 when survivors are present
    \\  --report <text|json|jsonl|junit>
    \\                         select the stdout report rendering
    \\  --output <path>        write the canonical JSON report to this path
    \\  --no-cache             disable zentinel result-cache reads and writes
    \\  --verbose              list every mutant in the text report
    \\  --quiet                print only the compact summary and suppress progress
++ global_options_help;

pub const init_help_text =
    \\zentinel init - create zentinel.toml in the project root
    \\
    \\Usage:
    \\  zentinel init [options]
    \\
    \\Options:
    \\  --force                   overwrite an existing zentinel.toml
    \\  --name <name>             project name (default: inferred from build.zig.zon or the directory name)
    \\  --test-command <command>  baseline test command written to [test] commands
    \\  --backend <ast>           mutation backend (init writes only the stable ast backend)
    \\
;

pub const check_help_text =
    \\zentinel check - validate config and environment
    \\
    \\Usage:
    \\  zentinel [global options] check
    \\
    \\Options:
    \\  (none; check uses only the global options)
++ global_options_help;

pub const list_mutants_help_text =
    \\zentinel list-mutants - list generated mutants without running tests
    \\
    \\Usage:
    \\  zentinel [global options] list-mutants [options]
    \\
    \\Options:
    \\  --operator <name>     list only one documented operator's candidates
    \\  --format <text|json>  select the listing rendering
    \\  --backend <ast|zir>   candidate backend (zir is experimental and opt-in)
++ global_options_help;

pub const doctest_help_text =
    \\zentinel doctest - validate executable documentation
    \\
    \\Usage:
    \\  zentinel [global options] doctest [options]
    \\
    \\Options:
    \\  --file <path>         documentation file (default docs/CLI_SPEC.md)
    \\  --case <case-ref>     run one extracted doctest case
    \\  --format <text|json>  select the report rendering
    \\  --mutate              run the mutation-aware doctest pass (requires --file)
    \\  --no-color            accepted for CLI uniformity; doctest output has no color
    \\
    \\Doctest AI subcommands are listed by 'zentinel --help'.
++ global_options_help;

pub const explain_help_text =
    \\zentinel explain - explain one mutant using advisory AI
    \\
    \\Usage:
    \\  zentinel [global options] explain <mutant-ref> [options]
    \\
++ ai_shared_options_help ++ global_options_help;

pub const suggest_help_text =
    \\zentinel suggest - suggest tests for one mutant using advisory AI
    \\
    \\Usage:
    \\  zentinel [global options] suggest <mutant-ref> [options]
    \\
++ ai_shared_options_help ++ global_options_help;

pub const review_tests_help_text =
    \\zentinel review-tests - review survivors using advisory AI
    \\
    \\Usage:
    \\  zentinel [global options] review-tests [options]
    \\
++ ai_shared_options_help ++ global_options_help;

pub const version_help_text =
    \\zentinel version - print version information
    \\
    \\Usage:
    \\  zentinel version
    \\
    \\Options:
    \\  (none)
    \\
;

/// Deterministic per-command help block for `<command> --help` (plain text, no
/// ANSI). Flag lists mirror the owning parsers exactly; a flag must exist in
/// the parser before it is documented here (docs/CLI_SPEC.md).
pub fn commandHelpText(topic: HelpTopic) []const u8 {
    return switch (topic) {
        .run => run_help_text,
        .init => init_help_text,
        .check => check_help_text,
        .list_mutants => list_mutants_help_text,
        .doctest => doctest_help_text,
        .explain => explain_help_text,
        .suggest => suggest_help_text,
        .review_tests => review_tests_help_text,
        .version => version_help_text,
    };
}

/// Deterministic `version` output: zentinel version plus pinned Zig policy label.
pub const version_text = "zentinel " ++ version ++ "\nzig " ++ supported_zig_version ++ "\n";

/// Deterministic default `zentinel.toml` template written by `init`.
/// Mirrors test/snapshots/init_config.toml and the full example in docs/CONFIG_SPEC.md.
pub const default_config =
    \\# zentinel.toml - mutation testing config. See docs/CONFIG_SPEC.md.
    \\
    \\# Project source set and identity.
    \\[project]
    \\# Human-readable project name.
    \\name = "example"
    \\# Project root, relative to this config file.
    \\root = "."
    \\# Glob patterns for source files eligible for mutation.
    \\include = ["src/**/*.zig"]
    \\# Paths excluded from mutation.
    \\exclude = [".zig-cache/**", "zig-out/**", "test/**"]
    \\
    \\# Zig toolchain policy.
    \\[zig]
    \\# Only accepted Zig policy version for this zentinel release.
    \\version = "0.16.0"
    \\# Optimization/safety modes to run: Debug, ReleaseSafe, ReleaseFast, ReleaseSmall.
    \\modes = ["Debug"]
    \\
    \\# Mutation backend selection.
    \\[backend]
    \\# Primary backend (ast is the stable default).
    \\default = "ast"
    \\# Additional experimental backends to opt into (e.g. zir).
    \\experimental = []
    \\
    \\# Enabled mutation operators (see docs/MUTATOR_SPEC.md).
    \\[mutators]
    \\# Operator names, or a group: phase1, phase2, all_stable.
    \\enabled = [
    \\  "arithmetic_add_sub",
    \\  "arithmetic_mul_div",
    \\  "equality_swap",
    \\  "comparison_boundary",
    \\  "logical_and_or",
    \\  "boolean_literal"
    \\]
    \\
    \\# Baseline and mutation test execution.
    \\[test]
    \\# Baseline and mutation test commands (parsed to argv, no shell).
    \\commands = ["zig build test"]
    \\# Test selection: same_file_then_package, same_file, package, or all.
    \\selection = "same_file_then_package"
    \\# Per-command timeout in milliseconds.
    \\timeout_ms = 30000
    \\# Reserved baseline policy flag; report v1 requires baselines to run.
    \\baseline_required = true
    \\
    \\# Mutation run execution.
    \\[run]
    \\# Maximum worker count (1 is the deterministic serial default).
    \\jobs = 1
    \\
    \\# Deterministic result cache.
    \\[cache]
    \\# Enable cache reads and writes.
    \\enabled = true
    \\# Cache storage path.
    \\directory = ".zig-cache/zentinel"
    \\
    \\# Report output.
    \\[report]
    \\# Report formats to emit: text, json, jsonl, junit.
    \\formats = ["text", "json"]
    \\# Report artifact directory.
    \\output_dir = "zig-out/zentinel"
    \\
    \\# Advisory AI (opt-in; disabled by default).
    \\[ai]
    \\# Enable AI commands or advisory report enrichment.
    \\enabled = false
    \\# Provider: disabled, stub, local, or remote.
    \\provider = "disabled"
    \\# Must be true before persisted config may select provider = "remote".
    \\remote_allowed = false
    \\# Lines of source context before/after a mutant for prompts.
    \\source_context_lines = 4
    \\# Regex patterns redacted from prompt payloads.
    \\redact_patterns = ["(?i)api[_-]?key", "(?i)token"]
    \\
;

/// CLI usage error codes owned by the Phase 0 shell (docs/ERROR_CODES.md).
pub const ErrorCode = enum {
    none,
    cli_unknown_command,
    cli_command_not_implemented,
    cli_invalid_option,

    pub fn token(self: ErrorCode) []const u8 {
        return switch (self) {
            .none => "",
            .cli_unknown_command => "ZNTL_CLI_UNKNOWN_COMMAND",
            .cli_command_not_implemented => "ZNTL_CLI_COMMAND_NOT_IMPLEMENTED",
            .cli_invalid_option => "ZNTL_CLI_INVALID_OPTION",
        };
    }
};

/// Result of a pure CLI dispatch. The presentation adapter performs all I/O
/// (writing stdout/stderr and, when `write_config` is set, the config file).
pub const Outcome = struct {
    exit_code: u8 = 0,
    stdout: []const u8 = "",
    /// Static stderr text (used for messages without a dynamic name).
    stderr: []const u8 = "",
    error_code: ErrorCode = .none,
    /// Offending command or option name for coded errors; slices into `args`.
    detail: []const u8 = "",
    /// When true, the adapter writes the init config to zentinel.toml.
    write_config: bool = false,
    /// Baseline test command for config-aware `init --test-command`; null uses the default template.
    init_test_command: ?[]const u8 = null,
    /// Explicit `init --name` project name; null lets the adapter infer one
    /// (build.zig.zon `.name`, then the project-root basename, then "example").
    init_name: ?[]const u8 = null,
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isOption(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "--");
}

/// Pure CLI dispatch. `args` excludes the program name. `config_exists` reflects
/// whether zentinel.toml already exists in the project root.
pub fn dispatch(args: []const []const u8, config_exists: bool) Outcome {
    var i: usize = 0;

    // Leading global options parse before command dispatch.
    while (i < args.len and isOption(args[i])) : (i += 1) {
        const opt = args[i];
        if (eq(opt, "--help") or eq(opt, "-h")) {
            return .{ .stdout = help_text };
        }
        if (eq(opt, "--no-color")) {
            // Accepted globally; non-colored output is unchanged.
            continue;
        }
        // Unknown options (including not-yet-owned global ones) are usage errors.
        return .{ .exit_code = 2, .error_code = .cli_invalid_option, .detail = opt };
    }

    if (i >= args.len) {
        // No command: show help.
        return .{ .stdout = help_text };
    }

    const cmd = args[i];
    i += 1;

    if (eq(cmd, "version")) {
        return .{ .stdout = version_text };
    }
    if (eq(cmd, "init")) {
        return dispatchInit(args[i..], config_exists);
    }
    // `check`/`list-mutants`/`run`/`doctest` and the AI commands are real routed
    // commands handled by `route`; they never reach this frozen fallback, so
    // dispatch no longer carries a vestigial "not implemented" roadmap list. Any
    // command that does reach here is genuinely unknown.
    return .{ .exit_code = 2, .error_code = .cli_unknown_command, .detail = cmd };
}

fn dispatchInit(rest: []const []const u8, config_exists: bool) Outcome {
    var force = false;
    var test_command: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (eq(arg, "--force")) {
            force = true;
        } else if (eq(arg, "--name")) {
            i += 1;
            if (i >= rest.len) return .{ .exit_code = 2, .error_code = .cli_invalid_option, .detail = "--name" };
            // Same escape-free-TOML embeddability gate as --test-command: a `"`
            // or control byte would inject structure or malform the file.
            if (!projectNameEmbeddable(rest[i])) return .{ .exit_code = 2, .error_code = .cli_invalid_option, .detail = "--name" };
            name = rest[i];
        } else if (eq(arg, "--test-command")) {
            i += 1;
            if (i >= rest.len) return .{ .exit_code = 2, .error_code = .cli_invalid_option, .detail = "--test-command" };
            // Reject values that cannot be embedded in zentinel's escape-free TOML:
            // a `"` would inject extra commands, a control byte would malform the
            // file. Caught here so no "created zentinel.toml" is printed.
            if (!testCommandEmbeddable(rest[i])) return .{ .exit_code = 2, .error_code = .cli_invalid_option, .detail = "--test-command" };
            test_command = rest[i];
        } else if (eq(arg, "--backend")) {
            i += 1;
            if (i >= rest.len) return .{ .exit_code = 2, .error_code = .cli_invalid_option, .detail = "--backend" };
            const value = rest[i];
            // init only writes the stable AST backend; it never enables experimental backends.
            if (!eq(value, "ast")) return .{ .exit_code = 2, .error_code = .cli_invalid_option, .detail = value };
        } else {
            return .{ .exit_code = 2, .error_code = .cli_invalid_option, .detail = arg };
        }
    }

    if (config_exists and !force) {
        return .{
            .exit_code = 2,
            .stderr = "zentinel.toml already exists; use --force to overwrite\n",
        };
    }

    return .{ .stdout = "created zentinel.toml\n", .write_config = true, .init_test_command = test_command, .init_name = name };
}

/// Default config file path when `--config` is not given.
pub const config_default_path = "zentinel.toml";

/// Parsed global options shared across project commands (docs/CLI_SPEC.md).
/// Shared by `check` and the other project commands.
pub const Globals = struct {
    config_path: []const u8 = config_default_path,
    config_explicit: bool = false,
    root: []const u8 = ".",
};

pub const ConfigPathError = error{ConfigOutsideRoot} || std.mem.Allocator.Error;

/// Resolve the config path relative to the selected project root. An explicit
/// `--config` is project-root-relative, not process-cwd-relative, so `--root x
/// --config zentinel.toml` reads `x/zentinel.toml`.
pub fn resolveConfigPathForRoot(arena: std.mem.Allocator, globals: Globals) ConfigPathError![]const u8 {
    if (globals.config_explicit and config.isOutsideRoot(globals.config_path)) return error.ConfigOutsideRoot;
    if (std.mem.eql(u8, globals.root, ".")) return arena.dupe(u8, globals.config_path);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ globals.root, globals.config_path });
}

/// The single stable cleanup-warning diagnostic format, shared by the allocating
/// `cleanupWarningText` and the streaming `emitCleanupWarningIfNeeded` so the two
/// surfaces cannot drift apart.
const cleanup_warning_fmt = "warning: failed to remove {d} mutation workspace(s)\n";

/// Stable cleanup warning surface shared by the CLI adapter and tests.
pub fn cleanupWarningText(arena: std.mem.Allocator, count: u32) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, cleanup_warning_fmt, .{count});
}

/// Adapter-visible cleanup warning emission. A zero count is intentionally silent;
/// a non-zero count streams `cleanup_warning_fmt` directly. It needs no allocator
/// -- the prior signature accepted one only to discard it via `_ = arena;`.
pub fn emitCleanupWarningIfNeeded(count: u32, stderr: *std.Io.Writer) !void {
    if (count == 0) return;
    try stderr.print(cleanup_warning_fmt, .{count});
}

/// Redact user-supplied path values before echoing them in diagnostics that may
/// cross the same privacy boundary as advisory AI logs.
pub fn redactCliDiagnosticPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    var log = ai.context.RedactionLog.init(arena);
    return ai.context.redactField(arena, path, &ai.command.default_redact_patterns, &log);
}

/// Format a run id as `{prefix}_{ms-timestamp:x}_{16 hex}` from a caller-supplied
/// 8-byte nonce. Pure and deterministic: identical inputs always yield the same
/// id, and distinct nonces always yield distinct ids. The adapter `allocRunId`
/// supplies a random nonce; tests supply fixed nonces to assert the format.
pub fn runIdWithNonce(arena: std.mem.Allocator, prefix: []const u8, ts_ms: i64, nonce: [8]u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}_{x}_{s}", .{
        prefix,
        @as(u64, @intCast(@max(0, ts_ms))),
        std.fmt.bytesToHex(nonce, .lower),
    });
}

/// A unique run id `{prefix}_{ms-timestamp:x}_{16 hex}`. The millisecond
/// timestamp alone collides when two runs start in the same repo within 1 ms,
/// and each run's end-of-run `deleteTree(run_base)` would then wipe the other's
/// live per-mutant sandboxes. The 8-byte random nonce makes the workspace path
/// (`{run_id}/{mutant_id}`) unique per process so concurrent runs never share a
/// run-base directory. The nonce draw (`io.random`, the Io-model entropy source
/// -- threadsafe, non-failing) is the only impurity; the id shape lives in the
/// pure `runIdWithNonce`.
pub fn allocRunId(arena: std.mem.Allocator, io: std.Io, prefix: []const u8, ts_ms: i64) std.mem.Allocator.Error![]const u8 {
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    return runIdWithNonce(arena, prefix, ts_ms, nonce);
}

/// What the presentation adapter should do with an argv. The pure Phase 0
/// `dispatch` above stays frozen for the commands it already owns; `route` adds
/// the task-005 surface (global options, `check`, and Zig-aware `version`)
/// without changing `dispatch`. `.passthrough` means the adapter falls back to
/// `dispatch`, which still rejects options it does not own.
/// A `run` invocation: parsed globals plus the run-specific argv that follows
/// the `run` command (parsed by the run command, not the frozen dispatch).
pub const RunInvocation = struct {
    globals: Globals,
    args: []const []const u8,
};

pub const Route = union(enum) {
    passthrough,
    version,
    check: Globals,
    run: RunInvocation,
    list_mutants: RunInvocation,
    doctest: RunInvocation,
    explain: RunInvocation,
    suggest: RunInvocation,
    review_tests: RunInvocation,
    /// `<command> --help|-h`: the adapter prints `commandHelpText(topic)` to
    /// stdout and exits 0 without parsing the command's other options.
    command_help: HelpTopic,
};

/// Map a command token to its per-command help topic; null for commands that
/// have no documented option surface (and for unknown commands, which keep
/// their deterministic ZNTL_CLI_UNKNOWN_COMMAND failure even with `--help`).
fn helpTopicForCommand(cmd: []const u8) ?HelpTopic {
    if (eq(cmd, "run")) return .run;
    if (eq(cmd, "init")) return .init;
    if (eq(cmd, "check")) return .check;
    if (eq(cmd, "list-mutants")) return .list_mutants;
    if (eq(cmd, "doctest")) return .doctest;
    if (eq(cmd, "explain")) return .explain;
    if (eq(cmd, "suggest")) return .suggest;
    if (eq(cmd, "review-tests")) return .review_tests;
    if (eq(cmd, "version")) return .version;
    return null;
}

/// Whether the argv tail after the command requests per-command help. A help
/// request anywhere after the command name wins over option parsing, so
/// `zentinel run --report json --help` prints help instead of running.
fn containsHelpOption(rest: []const []const u8) bool {
    for (rest) |arg| {
        if (eq(arg, "--help") or eq(arg, "-h")) return true;
    }
    return false;
}

/// Decide how to handle argv. `check` and `version` need environment inputs
/// (config bytes, discovered Zig) that only the adapter can gather, so routing
/// is kept separate from the pure `dispatch`. Global options `--config`/`--root`
/// are consumed only for the commands that own them; anything else passes
/// through to the frozen Phase 0 dispatch.
pub fn route(args: []const []const u8) Route {
    var globals: Globals = .{};
    var i: usize = 0;
    while (i < args.len and isOption(args[i])) {
        const opt = args[i];
        if (eq(opt, "--help") or eq(opt, "-h")) return .passthrough;
        if (eq(opt, "--no-color")) {
            i += 1;
            continue;
        }
        if (eq(opt, "--config")) {
            // A missing value, OR a following option (e.g. `--config --help`), falls
            // through to the frozen dispatch so its clear cli_invalid_option usage
            // error wins instead of capturing the option as the config path.
            if (i + 1 >= args.len or isOption(args[i + 1])) return .passthrough;
            globals.config_path = args[i + 1];
            globals.config_explicit = true;
            i += 2;
            continue;
        }
        if (eq(opt, "--root")) {
            // Same guard as --config: never absorb a following option as the root value.
            if (i + 1 >= args.len or isOption(args[i + 1])) return .passthrough;
            globals.root = args[i + 1];
            i += 2;
            continue;
        }
        // Unowned or unknown option: the frozen dispatch rejects it.
        return .passthrough;
    }

    if (i >= args.len) return .passthrough; // no command -> dispatch prints help

    const cmd = args[i];
    // Per-command help is routed before any command-local parsing so
    // `<command> --help` can never fail with ZNTL_CLI_INVALID_OPTION.
    if (helpTopicForCommand(cmd)) |topic| {
        if (containsHelpOption(args[i + 1 ..])) return .{ .command_help = topic };
    }
    if (eq(cmd, "check")) return .{ .check = globals };
    if (eq(cmd, "run")) return .{ .run = .{ .globals = globals, .args = args[i + 1 ..] } };
    if (eq(cmd, "list-mutants")) return .{ .list_mutants = .{ .globals = globals, .args = args[i + 1 ..] } };
    if (eq(cmd, "doctest")) return .{ .doctest = .{ .globals = globals, .args = args[i + 1 ..] } };
    if (eq(cmd, "explain")) return .{ .explain = .{ .globals = globals, .args = args[i + 1 ..] } };
    if (eq(cmd, "suggest")) return .{ .suggest = .{ .globals = globals, .args = args[i + 1 ..] } };
    if (eq(cmd, "review-tests")) return .{ .review_tests = .{ .globals = globals, .args = args[i + 1 ..] } };
    if (eq(cmd, "version")) {
        // `version` does not own --config/--root; defer to dispatch when present.
        if (globals.config_explicit or !eq(globals.root, ".")) return .passthrough;
        return .version;
    }
    return .passthrough;
}

/// Read-side path containment (audit F-5): a user-supplied `--input-report` or
/// `--file` value that escapes the project root (an absolute path or a `..`
/// segment) is rejected so the read paths honor the same root-containment
/// contract as the write-side `--output` guard (`config.isOutsideRoot`). Returns
/// the offending option name for a clear usage error, or null when every read
/// path in `args` stays within the project root. Pure; reads no filesystem.
pub fn readPathOutsideRootOption(args: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if ((eq(a, "--input-report") or eq(a, "--file")) and i + 1 < args.len) {
            if (config.isOutsideRoot(args[i + 1])) return a;
        }
    }
    return null;
}

test "project name is the stable constant" {
    try std.testing.expectEqualStrings("zentinel", project_name);
}

test "version is non-empty" {
    try std.testing.expect(version.len > 0);
}
