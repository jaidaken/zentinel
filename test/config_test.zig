const std = @import("std");
const zentinel = @import("zentinel");
const config = zentinel.config;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const full_config = @embedFile("snapshots/init_config.toml");

fn load(a: std.mem.Allocator, src: []const u8, diag: *config.Diagnostic) config.Error!config.Config {
    return config.load(a, src, diag);
}

test "empty config normalizes to documented defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    const cfg = try load(arena.allocator(), "", &diag);
    try expectEqualStrings("example", cfg.project_name);
    try expectEqualStrings("ast", cfg.backend_default);
    try expectEqual(@as(i64, 1), cfg.run_jobs);
    try expectEqual(@as(i64, 30000), cfg.test_timeout_ms);
    try expect(cfg.baseline_required);
    try expectEqual(@as(usize, 3), cfg.exclude.len);
    try expectEqualStrings(".zig-cache/**", cfg.exclude[0]);
    try expectEqualStrings("zig-out/**", cfg.exclude[1]);
    try expectEqualStrings("test/**", cfg.exclude[2]);
}

test "minimal config parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    const cfg = try load(arena.allocator(),
        \\[project]
        \\name = "demo"
        \\
        \\[test]
        \\commands = ["zig build test"]
        \\
    , &diag);
    try expectEqualStrings("demo", cfg.project_name);
    try expectEqual(@as(usize, 1), cfg.test_commands.len);
}

test "full default config (init output) parses with expected fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    const cfg = try load(arena.allocator(), full_config, &diag);
    try expectEqualStrings("example", cfg.project_name);
    try expectEqual(@as(usize, 6), cfg.mutators_enabled.len);
    try expect(!cfg.ai_enabled);
    try expectEqualStrings("disabled", cfg.ai_provider);
    try expectEqual(@as(usize, 2), cfg.report_formats.len);
}

test "report.formats validates each element against the known formats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Every known format is accepted...
    var diag: config.Diagnostic = .{};
    const ok = try load(arena.allocator(), "[report]\nformats = [\"text\", \"json\", \"jsonl\", \"junit\"]\n", &diag);
    try expectEqual(@as(usize, 4), ok.report_formats.len);

    // ...but an unknown per-element value is rejected at load, not silently kept.
    var diag2: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(), "[report]\nformats = [\"invalid_format\"]\n", &diag2));
    var diag3: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(), "[report]\nformats = [\"json\", \"bogus\"]\n", &diag3));
}

test "parser accepts tables, strings, booleans, integers, arrays, and comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    const cfg = try load(arena.allocator(),
        \\# a comment
        \\[cache]
        \\enabled = false   # inline comment
        \\directory = "build/cache"
        \\
        \\[run]
        \\jobs = 1
        \\
        \\[project]
        \\include = ["a.zig", "b.zig"]
        \\
    , &diag);
    try expect(!cfg.cache_enabled);
    try expectEqualStrings("build/cache", cfg.cache_directory);
    try expectEqual(@as(usize, 2), cfg.include.len);
}

test "unsupported TOML syntax fails with parse_error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(), "[project]\nname = { inline = true }\n", &diag));
    try expect(diag.code == .parse_error);
}

test "explicit empty zig.modes is rejected, like empty test.commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An explicit `modes = []` is meaningless intent the matrix would silently run
    // as Debug-only; it is a usage error, not a silently-accepted no-op.
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(a, "[zig]\nmodes = []\n", &diag));
    try expect(diag.code == .invalid_value);
    try expectEqualStrings("zig", diag.section);
    try expectEqualStrings("modes", diag.key);

    // Omitting `modes` keeps the Debug default; an explicit non-empty list loads.
    var d2: config.Diagnostic = .{};
    const dflt = try load(a, "", &d2);
    try expectEqual(@as(usize, 1), dflt.zig_modes.len);
    try expectEqualStrings("Debug", dflt.zig_modes[0]);

    var d3: config.Diagnostic = .{};
    const multi = try load(a, "[zig]\nmodes = [\"Debug\", \"ReleaseFast\"]\n", &d3);
    try expectEqual(@as(usize, 2), multi.zig_modes.len);
}

test "duplicate keys in the same section are rejected, not silently first-wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // config.load surface: the same key twice in one section is a usage error
    // (parse_error at the redefinition line), not a silent first-wins drop of the
    // later value the author actually wrote.
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(a, "[test]\ncommands = [\"zig build test\"]\ncommands = [\"true\"]\n", &diag));
    try expect(diag.code == .parse_error);
    try expectEqual(@as(usize, 3), diag.line); // line of the second (duplicate) commands

    // Parser surface: a duplicate (section, key) fails with a duplicate-key message
    // at the redefinition line.
    var pdiag: zentinel.config_toml.Diagnostic = .{};
    try expectError(error.ParseError, zentinel.config_toml.parse(a, "[a]\nx = 1\nx = 2\n", &pdiag));
    try expect(std.mem.indexOf(u8, pdiag.message, "duplicate") != null);
    try expectEqual(@as(usize, 3), pdiag.line);

    // Not over-broad: the SAME key name under a DIFFERENT section is a distinct
    // (section, key) and parses cleanly (two entries retained).
    var ok_diag: zentinel.config_toml.Diagnostic = .{};
    const doc = try zentinel.config_toml.parse(a, "[a]\nx = 1\n[b]\nx = 2\n", &ok_diag);
    try expectEqual(@as(usize, 2), doc.entries.len);
}

test "a leading UTF-8 BOM (TOML 1.0) is tolerated" {
    // Regression: a config saved with a leading U+FEFF BOM (common on Windows
    // editors) used to fail at the first byte with "expected section header or
    // key" and no hint about the BOM. TOML 1.0 permits exactly one leading BOM.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: zentinel.config_toml.Diagnostic = .{};
    const bom_src = "\xEF\xBB\xBF[a]\nx = 1\n";
    const doc = try zentinel.config_toml.parse(a, bom_src, &diag);
    try expectEqual(@as(usize, 1), doc.entries.len);
}

test "double-quoted strings decode TOML basic escape sequences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Raw TOML source. This is a Zig multiline literal, so the backslashes and
    // quotes below are LITERAL source bytes handed to the parser (no Zig-level
    // escape processing) -- i.e. the parser sees `back = "p\\q"` with two backslashes.
    const src =
        \\[s]
        \\back = "p\\q"
        \\quote = "say \"hi\""
        \\nl = "a\nb"
        \\tab = "a\tb"
        \\plain = "nochange"
        \\
    ;
    var diag: zentinel.config_toml.Diagnostic = .{};
    const doc = try zentinel.config_toml.parse(a, src, &diag);
    try expectEqual(@as(usize, 5), doc.entries.len);
    // `\\` decodes to a single backslash (previously kept as two literal backslashes).
    try expectEqualStrings("p\\q", doc.entries[0].value.string);
    // `\"` embeds a quote (the prior loop terminated the string early at the first \").
    try expectEqualStrings("say \"hi\"", doc.entries[1].value.string);
    // `\n` / `\t` decode to the actual control byte, not a literal backslash-letter.
    try expectEqualStrings("a\nb", doc.entries[2].value.string);
    try expectEqualStrings("a\tb", doc.entries[3].value.string);
    // No backslash: the zero-copy fast path returns the bytes unchanged.
    try expectEqualStrings("nochange", doc.entries[4].value.string);
}

test "an unknown string escape is a parse error, not silently kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `\z` is not a TOML basic escape; it must fail rather than pass through verbatim.
    var diag: zentinel.config_toml.Diagnostic = .{};
    try expectError(error.ParseError, zentinel.config_toml.parse(a, "[s]\nx = \"a\\zb\"\n", &diag));
    try expect(std.mem.indexOf(u8, diag.message, "escape") != null);
}

test "unknown key is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(), "[project]\nbogus = \"x\"\n", &diag));
    try expect(diag.code == .unknown_key);
    try expectEqualStrings("project", diag.section);
    try expectEqualStrings("bogus", diag.key);
}

test "unknown section is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(), "[nope]\nx = 1\n", &diag));
    try expect(diag.code == .unknown_key);
}

test "wrong value type is rejected with invalid_value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(), "[run]\njobs = \"two\"\n", &diag));
    try expect(diag.code == .invalid_value);
}

test "invalid Zig mode is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(), "[zig]\nmodes = [\"Turbo\"]\n", &diag));
    try expect(diag.code == .invalid_value);
}

test "multiple Zig modes are accepted by the safety-mode matrix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Task 058 lifts the pre-058 single-mode restriction: more than one
    // configured zig.modes entry is now accepted.
    var diag: config.Diagnostic = .{};
    const cfg = try load(arena.allocator(), "[zig]\nmodes = [\"Debug\", \"ReleaseSafe\"]\n", &diag);
    try expect(cfg.zig_modes.len == 2);
    // Unknown modes are still rejected, with or without multiple entries.
    var diag2: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(), "[zig]\nmodes = [\"Debug\", \"Turbo\"]\n", &diag2));
    try expect(diag2.code == .invalid_value);
}

test "experimental backend without opt-in is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(), "[backend]\ndefault = \"zir\"\n", &diag));
    try expect(diag.code == .experimental_backend);
}

test "negative timeout is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(), "[test]\ntimeout_ms = -1\n", &diag));
    try expect(diag.code == .invalid_value);
}

test "zero timeout is rejected (it would disable the timeout and leave hung tests unbounded)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(), "[test]\ntimeout_ms = 0\n", &diag));
    try expect(diag.code == .invalid_value);
}

test "baseline_required = false is reserved and rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(), "[test]\nbaseline_required = false\n", &diag));
    try expect(diag.code == .invalid_value);
}

test "empty test command list is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(), "[test]\ncommands = []\n", &diag));
    try expect(diag.code == .invalid_value);
}

test "unknown mutator name is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(), "[mutators]\nenabled = [\"make_it_fast\"]\n", &diag));
    try expect(diag.code == .invalid_value);
}

test "output directory outside project root is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(), "[report]\noutput_dir = \"../escape\"\n", &diag));
    try expect(diag.code == .invalid_value);
}

test "non-positive worker count is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(), "[run]\njobs = 0\n", &diag));
    try expect(diag.code == .invalid_value);
}

test "remote AI provider without remote_allowed is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(), "[ai]\nprovider = \"remote\"\n", &diag));
    try expect(diag.code == .invalid_value);
}

test "mutator special values expand deterministically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: config.Diagnostic = .{};

    const p1 = try load(a, "[mutators]\nenabled = [\"phase1\"]\n", &diag);
    try expectEqual(@as(usize, 6), p1.mutators_enabled.len);
    try expectEqualStrings("arithmetic_add_sub", p1.mutators_enabled[0]);

    const p2 = try load(a, "[mutators]\nenabled = [\"phase2\"]\n", &diag);
    try expectEqual(@as(usize, 6), p2.mutators_enabled.len);

    const all = try load(a, "[mutators]\nenabled = [\"all_stable\"]\n", &diag);
    try expectEqual(@as(usize, 12), all.mutators_enabled.len);
}

test "path normalization converts backslashes to forward slashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    // A literal backslash in a TOML basic string is written `\\`; the parser
    // decodes that to one backslash, which normalizePath then converts to `/`.
    // (The Zig `\\\\` literal below is two source backslashes = the TOML `\\` escape.)
    const cfg = try load(arena.allocator(), "[cache]\ndirectory = \"build\\\\cache\"\n", &diag);
    try expectEqualStrings("build/cache", cfg.cache_directory);
}

test "config-aware init output parses with the custom test command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try zentinel.initConfigText(a, "zig build test -Dfoo", null);
    var diag: config.Diagnostic = .{};
    const cfg = try load(a, text, &diag);
    try expectEqual(@as(usize, 1), cfg.test_commands.len);
    try expectEqualStrings("zig build test -Dfoo", cfg.test_commands[0]);
}

test "default init output equals the static template" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try zentinel.initConfigText(arena.allocator(), null, null);
    try expectEqualStrings(zentinel.default_config, text);
}

test "impact_graph selection is rejected (reserved / not-yet-implemented)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // impact_graph's resolver is currently an exact alias of
    // same_file_then_package, so accepting it would record a misleading strategy.
    // Config rejects it (the enum variant is kept only for forward-compat).
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(),
        \\[project]
        \\name = "demo"
        \\
        \\[test]
        \\commands = ["zig build test"]
        \\selection = "impact_graph"
        \\
    , &diag));
    try expectEqual(config.Code.invalid_value, diag.code);
    try expectEqualStrings("test", diag.section);
    try expectEqualStrings("selection", diag.key);
}

test "an unknown selection strategy is still rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: config.Diagnostic = .{};
    try expectError(error.Invalid, load(arena.allocator(),
        \\[project]
        \\name = "demo"
        \\
        \\[test]
        \\commands = ["zig build test"]
        \\selection = "call_graph"
        \\
    , &diag));
    try expectEqual(config.Code.invalid_value, diag.code);
    try expectEqualStrings("test", diag.section);
    try expectEqualStrings("selection", diag.key);
}

// --- test.env_passthrough and project.workspace_siblings -----------
//
// A DB-backed suite needs its connection string, and a package whose build.zig.zon
// names `../core` needs that sibling beside every per-mutant workspace copy. Both
// are opt-in config, never defaults: an omitted key leaves the minimal environment
// and the self-contained workspace exactly as before.

test "env_passthrough and workspace_siblings default to empty and parse when given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var d0: config.Diagnostic = .{};
    const dflt = try load(a, "", &d0);
    try expectEqual(@as(usize, 0), dflt.test_env_passthrough.len);
    try expectEqual(@as(usize, 0), dflt.workspace_siblings.len);

    var diag: config.Diagnostic = .{};
    const cfg = try load(a,
        \\[project]
        \\workspace_siblings = ["../core", "../contracts"]
        \\
        \\[test]
        \\env_passthrough = ["KC_TEST_DB_URI", "KC_TEST_RLS_DB_URI"]
        \\
    , &diag);
    try expectEqual(@as(usize, 2), cfg.test_env_passthrough.len);
    try expectEqualStrings("KC_TEST_DB_URI", cfg.test_env_passthrough[0]);
    try expectEqualStrings("KC_TEST_RLS_DB_URI", cfg.test_env_passthrough[1]);
    try expectEqual(@as(usize, 2), cfg.workspace_siblings.len);
    try expectEqualStrings("../core", cfg.workspace_siblings[0]);
    try expectEqualStrings("../contracts", cfg.workspace_siblings[1]);
}

test "env_passthrough rejects an empty name and a name carrying a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var d1: config.Diagnostic = .{};
    try expectError(error.Invalid, load(a, "[test]\nenv_passthrough = [\"\"]\n", &d1));
    try expectEqual(config.Code.invalid_value, d1.code);
    try expectEqualStrings("test", d1.section);
    try expectEqualStrings("env_passthrough", d1.key);

    // `KEY=value` is an assignment, not a name: the config names WHICH parent
    // variables cross, never what they hold.
    var d2: config.Diagnostic = .{};
    try expectError(error.Invalid, load(a, "[test]\nenv_passthrough = [\"KC_TEST_DB_URI=postgres://x\"]\n", &d2));
    try expectEqual(config.Code.invalid_value, d2.code);
}

test "workspace_siblings accepts only one-segment parent paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Each rejected shape would either point inside the project (no `..`, so the
    // copy already has it), escape further than the project's parent, or name
    // nothing at all.
    const bad = [_][]const u8{
        "[project]\nworkspace_siblings = [\"core\"]\n",
        "[project]\nworkspace_siblings = [\"../../core\"]\n",
        "[project]\nworkspace_siblings = [\"../core/src\"]\n",
        "[project]\nworkspace_siblings = [\"..\"]\n",
        "[project]\nworkspace_siblings = [\"../\"]\n",
        "[project]\nworkspace_siblings = [\"/abs/core\"]\n",
        "[project]\nworkspace_siblings = [\"../.\"]\n",
    };
    for (bad) |src| {
        var diag: config.Diagnostic = .{};
        try expectError(error.Invalid, load(a, src, &diag));
        try expectEqual(config.Code.invalid_value, diag.code);
        try expectEqualStrings("project", diag.section);
        try expectEqualStrings("workspace_siblings", diag.key);
    }
    var ok_diag: config.Diagnostic = .{};
    const ok = try load(a, "[project]\nworkspace_siblings = [\"../core\", \"../wire.json\"]\n", &ok_diag);
    try expectEqual(@as(usize, 2), ok.workspace_siblings.len);
}

test "siblingName strips the parent segment and rejects everything else" {
    try expectEqualStrings("core", config.siblingName("../core").?);
    try expectEqualStrings("wire.json", config.siblingName("../wire.json").?);
    try expect(config.siblingName("core") == null);
    try expect(config.siblingName("../../core") == null);
    try expect(config.siblingName("../core/src") == null);
    try expect(config.siblingName("../") == null);
    try expect(config.siblingName("..") == null);
    try expect(config.siblingName("../..") == null);
    try expect(config.siblingName("../.") == null);
}

// --- Symlink-safe output containment (audit F-3) ------------------
//
// `config.isOutsideRoot` is string-only: it rejects absolute paths and `..`
// segments but never resolves symlinks, so an in-tree symlink that leaves the
// project tree slips past it and the report/cache write (which follows symlinks
// in the sub-path) lands outside the root. `outputPathHasSymlink` resolves
// containment by refusing any symlinked component in the output path (no-follow
// semantics, docs/SANDBOX_SECURITY.md). It reads the filesystem deterministically
// (like project_model.discover), so it lives next to isOutsideRoot in the
// deterministic core and is exercised here with a real temp directory + symlink.

test "outputPathHasSymlink flags a symlinked output component the string check misses (F-3)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // An in-tree symlink whose target leaves the project root, and a legitimate
    // in-root output directory (a real directory, not a symlink).
    try tmp.dir.symLink(io, "../outside_root_target", "escape_link", .{});
    try tmp.dir.createDirPath(io, "out");

    // The existing string-only containment check misses the symlink: the path is
    // relative and has no `..` segment, so it cannot keep the write in-tree.
    try expect(!config.isOutsideRoot("escape_link/report.json"));

    // The symlink-aware check catches the escape, while legitimate in-root output
    // (a plain subdirectory or a bare filename) still passes.
    try expect(config.outputPathHasSymlink(io, tmp.dir, "escape_link/report.json"));
    try expect(!config.outputPathHasSymlink(io, tmp.dir, "out/report.json"));
    try expect(!config.outputPathHasSymlink(io, tmp.dir, "report.json"));
}

test "outputPathHasSymlink flags a symlinked final output file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // An untrusted checkout could ship the report path itself as a symlink to an
    // out-of-root file; following it on write would clobber that file.
    try tmp.dir.symLink(io, "../outside.json", "report.json", .{});
    try expect(config.outputPathHasSymlink(io, tmp.dir, "report.json"));
}

test "pathEscapesRoot combines lexical and symlink containment for reads and writes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.symLink(io, "../outside_root_target", "escape_link", .{});
    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/README.md", .data = "# ok\n" });

    try expect(config.pathEscapesRoot(io, tmp.dir, "/absolute/path"));
    try expect(config.pathEscapesRoot(io, tmp.dir, "docs/../outside.md"));
    try expect(config.pathEscapesRoot(io, tmp.dir, "escape_link/secret.md"));
    try expect(!config.pathEscapesRoot(io, tmp.dir, "docs/README.md"));
}
