# Config Specification

zentinel config is explicit, deterministic, and stable. The default config should work for conventional Zig projects while allowing advanced projects to opt into experimental behavior.

## File Name

Preferred config file:

```text
zentinel.toml
```

The CLI may accept an explicit path:

```bash
zentinel run --config path/to/zentinel.toml
```

## Minimal Config

```toml config
[project]
name = "example"

[test]
commands = ["zig build test"]
```

## TOML Subset

Phase 0 config parsing uses the deterministic in-tree TOML subset required by `docs/DEPENDENCY_POLICY.md`.

Supported syntax:

- tables such as `[project]`
- string values
- boolean values
- integer values
- arrays of strings
- comments beginning with `#`

Unsupported TOML syntax must fail with `ZNTL_CONFIG_PARSE_ERROR` or `ZNTL_CONFIG_INVALID_VALUE`; agents must not add a TOML dependency only to support syntax outside this subset.

## Full Config Example

```toml config
# zentinel.toml - mutation testing config. See docs/CONFIG_SPEC.md.

# Project source set and identity.
[project]
# Human-readable project name.
name = "example"
# Project root, relative to this config file.
root = "."
# Glob patterns for source files eligible for mutation.
include = ["src/**/*.zig"]
# Paths excluded from mutation.
exclude = [".zig-cache/**", "zig-out/**", "test/**"]

# Zig toolchain policy.
[zig]
# Only accepted Zig policy version for this zentinel release.
version = "0.16.0"
# Optimization/safety modes to run: Debug, ReleaseSafe, ReleaseFast, ReleaseSmall.
modes = ["Debug"]

# Mutation backend selection.
[backend]
# Primary backend (ast is the stable default).
default = "ast"
# Additional experimental backends to opt into (e.g. zir).
experimental = []

# Enabled mutation operators (see docs/MUTATOR_SPEC.md).
[mutators]
# Operator names, or a group: phase1, phase2, all_stable.
enabled = [
  "arithmetic_add_sub",
  "arithmetic_mul_div",
  "equality_swap",
  "comparison_boundary",
  "logical_and_or",
  "boolean_literal"
]

# Baseline and mutation test execution.
[test]
# Baseline and mutation test commands (parsed to argv, no shell).
commands = ["zig build test"]
# Test selection: same_file_then_package, same_file, package, or all.
selection = "same_file_then_package"
# Per-command timeout in milliseconds.
timeout_ms = 30000
# Reserved baseline policy flag; report v1 requires baselines to run.
baseline_required = true

# Mutation run execution.
[run]
# Maximum worker count (1 is the deterministic serial default).
jobs = 1

# Deterministic result cache.
[cache]
# Enable cache reads and writes.
enabled = true
# Cache storage path.
directory = ".zig-cache/zentinel"

# Report output.
[report]
# Report formats to emit: text, json, jsonl, junit.
formats = ["text", "json"]
# Report artifact directory.
output_dir = "zig-out/zentinel"

# Advisory AI (opt-in; disabled by default).
[ai]
# Enable AI commands or advisory report enrichment.
enabled = false
# Provider: disabled, stub, local, or remote.
provider = "disabled"
# Must be true before persisted config may select provider = "remote".
remote_allowed = false
# Lines of source context before/after a mutant for prompts.
source_context_lines = 4
# Regex patterns redacted from prompt payloads.
redact_patterns = ["(?i)api[_-]?key", "(?i)token"]
```

## Validation Failures

Selecting an experimental backend without an explicit opt-in is rejected:

```toml config_fail
[backend]
default = "zir"
```

```text output contains
ZNTL_CONFIG_EXPERIMENTAL_BACKEND
```

An unknown section or key is rejected:

```toml config_fail
[project]
bogus = "x"
```

```text output contains
ZNTL_CONFIG_UNKNOWN_KEY
```

## Project Section

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `name` | string | directory name | Human-readable project name. |
| `root` | string | `.` | Project root relative to config file. |
| `include` | list(string) | `["src/**/*.zig"]` | Source files eligible for mutation. |
| `exclude` | list(string) | `[".zig-cache/**", "zig-out/**", "test/**"]` | Paths excluded from mutation. |

Paths are interpreted relative to project root and normalized to `/`.

The default exclude list is exact for v1. Agents must not silently add or remove defaults such as `.git/**` without an explicit task or ADR, because exclude expansion changes candidate discovery and cache keys.

## Zig Section

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `version` | string | `0.16.0` | Only accepted policy value for this zentinel version. |
| `modes` | list(enum) | `["Debug"]` | Zig optimization/safety modes to execute. |

Allowed modes:

```text
Debug
ReleaseSafe
ReleaseFast
ReleaseSmall
```

Multiple `zig.modes` entries are accepted and drive the safety-mode matrix. An explicit empty `modes = []` is rejected with `ZNTL_CONFIG_INVALID_VALUE` (omitting `modes` keeps the `Debug` default).

## Backend Section

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `default` | enum | `ast` | Primary backend. |
| `experimental` | list(enum) | `[]` | Additional experimental backends. |

Allowed backend values:

```text
ast
zir
```

`zir` is rejected unless explicitly listed in `experimental` or selected by an experimental CLI flag. The experimental CLI backend flag is `list-mutants --backend zir`. (The `air` backend was retired: AIR-level mutation mapping is infeasible without Zig's `Sema` stage.)

## Mutators Section

`enabled` is a list of operator names from `docs/MUTATOR_SPEC.md`.

Special values:

```text
phase1
phase2
all_stable
```

Expansion must be deterministic and tested.

`phase2` expands only to stable Phase 2 operators. Preview Phase 2 operators are **not yet enableable**: they have no pipeline collector, so config validation rejects any non-stable operator — whether named directly or pulled in by a group. `all_stable` means every stable operator whose owning implementation is complete.

## Test Section

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `commands` | list(string) | `["zig build test"]` | Baseline and mutation test commands. |
| `selection` | enum | `same_file_then_package` | Test selection strategy: one of `same_file_then_package`, `same_file`, `package`, `all`. |
| `timeout_ms` | integer | `30000` | Per-command timeout in milliseconds, bounding the command's TOTAL wall time rather than the gap between reads of its output. On expiry the command's whole process group is terminated, so descendants (a `zig build` runner and the test binary it spawned) cannot outlive it. Must be a positive integer (`<= 0` is rejected: a value of 0 disables the timeout and would leave hung tests unbounded). |
| `baseline_required` | bool | `true` | Reserved baseline policy flag; report v1 requires baselines to run. |

Command strings are parsed by zentinel into argv without invoking a shell. The shared parser belongs to the deterministic core module `src/command.zig`; `zentinel check` validates with it, and the runner executes exactly the argv shape it returns.

Config parsing validates that `test.commands` is a non-empty list of non-empty strings; full command grammar validation lives in `src/command.zig`. Command strings are preserved after shape validation rather than re-parsed by a second parser.

`impact_graph` is **reserved but not yet accepted** as a `test.selection` value: config validation currently rejects it. Its planned deterministic impact-set semantics are described in `docs/TEST_SELECTION.md`; until the resolver lands, use one of the accepted strategies above.

The shared command parser accepts this grammar:

```text
command        = spacing? field (spacing+ field)* spacing?
field          = bare | single_quoted | double_quoted
bare           = bare_char+
bare_char      = any non-spacing character except quotes, backslash, or rejected shell metacharacters
single_quoted  = "'" quoted_part* "'"
double_quoted  = '"' quoted_part* '"'
quoted_part    = quoted_char | escape
quoted_char    = any character except quote delimiters, backslash, or rejected shell metacharacters
escape         = backslash escaped_char
escaped_char   = backslash | single_quote | double_quote | space
spacing        = one or more ASCII spaces or tabs
```

Semantics:

- parsing produces a non-empty argv array
- `argv[0]` must be non-empty
- empty quoted fields are valid only after `argv[0]`
- quoting only groups literal text; it does not enable shell expansion
- backslash escaping is valid only inside quoted fields and only for `\`, `'`, `"`, and a literal space
- unmatched quotes, trailing escapes, and unsupported escapes are invalid command syntax

The parser rejects shell features instead of approximating them:

- pipes: `|`
- redirects: `<`, `>`
- command substitution or variable expansion: `$`, backtick
- glob expansion: `*`, `?`, `[`, `]`, `{`, `}`
- environment-variable assignment prefixes such as `FOO=bar zig test`
- command grouping or subshell syntax: `(`, `)`
- command chaining such as `&&`, `||`, or `;`

Rejected shell metacharacters are invalid even when quoted or escaped. The goal is deterministic argv construction, not shell compatibility.

`zentinel check` validates command strings with this parser but does not execute them. The baseline and mutant runners must not implement alternate shell-like parsing.

`baseline_required = false` is reserved for a future cache-backed baseline-skip policy. Until a later ADR or task defines the required fresh-cache proof and report schema, config validation must reject `false` with `ZNTL_CONFIG_INVALID_VALUE`. Report v1 writers must run the baseline or emit `run.status = "baseline_failed"` when it fails.

## Run Section

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `jobs` | integer | `1` | Maximum zentinel worker count for mutation execution. |

`jobs = 1` is the deterministic serial default. Values greater than `1` request bounded parallel mutation execution on the worker pool. The command-line `--jobs <n>` option overrides normalized `run.jobs` only for the current invocation.

Config validation must reject non-positive worker counts with `ZNTL_CONFIG_INVALID_VALUE`.

## Cache Section

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enabled` | bool | `true` | Enables deterministic cache. |
| `directory` | string | `.zig-cache/zentinel` | Cache storage path. |

## Report Section

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `formats` | list(enum) | `["text", "json"]` | Report formats to emit. |
| `output_dir` | string | `zig-out/zentinel` | Report artifact directory. |

## AI Section

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enabled` | bool | `false` | Enables AI commands or advisory report enrichment. |
| `provider` | enum | `disabled` | `disabled`, `stub`, `local`, or `remote`. |
| `remote_allowed` | bool | `false` | Must be `true` before persisted config may select `provider = "remote"`. |
| `source_context_lines` | integer | `4` | Lines before/after mutant for prompts. |
| `redact_patterns` | list(string) | `["(?i)api[_-]?key", "(?i)token"]` | Regex patterns to redact. |

The v1 redaction default list is exact. Omitted `redact_patterns` normalizes to `["(?i)api[_-]?key", "(?i)token"]`; agents must not silently add broader patterns without an explicit docs and snapshot update because redaction changes prompt payloads.

## Validation Rules

Config validation must reject:

- unknown top-level sections
- unknown keys
- unsupported Zig version values
- experimental backend without opt-in
- negative timeouts
- `baseline_required = false`
- empty test command list
- invalid test command syntax
- `ai.provider = "remote"` unless `ai.remote_allowed = true`, reported as `ZNTL_CONFIG_INVALID_VALUE`
- output directory outside project root unless explicitly allowed by future policy
- mutator names not defined in `MUTATOR_SPEC.md`
- non-positive worker counts

The CLI `--output <path>` override inherits this same project-root restriction as `report.output_dir`; CLI and config output paths must not diverge on sandbox boundary behavior.

Validation errors should include the config path and key.

AI command-line overrides are validated after config normalization. Passing `--ai-provider remote` while the normalized config has `remote_allowed = false` fails with `ZNTL_AI_PROVIDER_NOT_ALLOWED`; a persisted config that directly selects `provider = "remote"` with `remote_allowed = false` fails config validation with `ZNTL_CONFIG_INVALID_VALUE`.
