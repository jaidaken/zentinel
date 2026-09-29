const std = @import("std");
const zentinel = @import("zentinel");
const runner = zentinel.runner;
const report = zentinel.report;
const command = zentinel.command;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const command_snapshot = @embedFile("fixtures/runner/baseline_command.json");

fn outcome(exit: ?i64, timed_out: bool, crashed: bool, stdout: []const u8, stderr: []const u8) runner.RawOutcome {
    return .{ .exit_code = exit, .timed_out = timed_out, .crashed = crashed, .duration_ms = 0, .stdout = stdout, .stderr = stderr };
}

/// Deterministic mock executor: returns programmed outcomes in order without
/// spawning any process (tests do not depend on machine-specific commands).
const Mock = struct {
    outcomes: []const runner.RawOutcome,
    next: usize = 0,

    fn run(ctx: *anyopaque, argv: []const []const u8) runner.RawOutcome {
        _ = argv;
        const self: *Mock = @ptrCast(@alignCast(ctx));
        const o = self.outcomes[self.next];
        self.next += 1;
        return o;
    }
    fn exec(self: *Mock) runner.Executor {
        return .{ .ctx = self, .runFn = Mock.run };
    }
};

test "passing baseline command classifies as passed with structured evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const outs = [_]runner.RawOutcome{outcome(0, false, false, "", "")};
    var mock = Mock{ .outcomes = &outs };
    const res = try runner.runBaseline(a, mock.exec(), &.{"zig build test"}, "<project>");

    try expectEqual(report.BaselineStatus.passed, res.status);
    try expectEqual(@as(usize, 1), res.commands.len);
    const c = res.commands[0];
    try expectEqual(report.CommandStatus.passed, c.status);
    try expectEqual(report.FailureKind.none, c.failure_kind);
    try expectEqualStrings("zig build test", c.command.original);
    try expectEqual(@as(usize, 3), c.command.argv.len);
    try expectEqual(false, c.command.shell);
    try expect(c.command.environment_policy == .minimal);
    try expect(c.phase == .baseline);
    try expect(c.skip_reason == null);
}

test "failing baseline command classifies as failed with ZNTL_RUNNER_COMMAND_FAILED" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const outs = [_]runner.RawOutcome{outcome(1, false, false, "", "boom")};
    var mock = Mock{ .outcomes = &outs };
    const res = try runner.runBaseline(a, mock.exec(), &.{"zig build test"}, "<project>");

    try expectEqual(report.BaselineStatus.failed, res.status);
    try expectEqual(report.CommandStatus.failed, res.commands[0].status);
    try expectEqual(report.FailureKind.test_failure, res.commands[0].failure_kind);
    try expectEqualStrings("ZNTL_RUNNER_COMMAND_FAILED", runner.statusCode(.failed));
}

test "baseline timeout maps to baseline failure with null exit code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const outs = [_]runner.RawOutcome{outcome(null, true, false, "", "")};
    var mock = Mock{ .outcomes = &outs };
    const res = try runner.runBaseline(a, mock.exec(), &.{"zig build test"}, "<project>");

    try expectEqual(report.BaselineStatus.failed, res.status);
    try expectEqual(report.CommandStatus.timeout, res.commands[0].status);
    try expect(res.commands[0].timed_out);
    try expect(res.commands[0].exit_code == null);
    try expectEqualStrings("ZNTL_RUNNER_TIMEOUT", runner.statusCode(.timeout));
}

test "baseline compiler crash maps to compiler_crash, not internal error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const outs = [_]runner.RawOutcome{outcome(null, false, true, "", "panic")};
    var mock = Mock{ .outcomes = &outs };
    const res = try runner.runBaseline(a, mock.exec(), &.{"zig build test"}, "<project>");

    try expectEqual(report.BaselineStatus.failed, res.status);
    try expectEqual(report.CommandStatus.compiler_crash, res.commands[0].status);
    try expectEqual(report.FailureKind.compiler_crash, res.commands[0].failure_kind);
    try expect(res.commands[0].exit_code == null);
}

test "captured output excerpts are bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const big = try a.alloc(u8, 5000);
    @memset(big, 'x');
    const outs = [_]runner.RawOutcome{outcome(0, false, false, big, big)};
    var mock = Mock{ .outcomes = &outs };
    const res = try runner.runBaseline(a, mock.exec(), &.{"zig build test"}, "<project>");
    try expectEqual(@as(usize, runner.excerpt_limit), res.commands[0].evidence.stdout_excerpt.len);
    try expectEqual(@as(usize, runner.excerpt_limit), res.commands[0].evidence.stderr_excerpt.len);
}

test "captured output excerpts are bounded on UTF-8 codepoint boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const big = try a.alloc(u8, runner.excerpt_limit + 2);
    @memset(big[0 .. runner.excerpt_limit - 1], 'x');
    @memcpy(big[runner.excerpt_limit - 1 .. runner.excerpt_limit + 2], "€");

    const outs = [_]runner.RawOutcome{outcome(0, false, false, big, big)};
    var mock = Mock{ .outcomes = &outs };
    const res = try runner.runBaseline(a, mock.exec(), &.{"zig build test"}, "<project>");
    try expectEqual(@as(usize, runner.excerpt_limit - 1), res.commands[0].evidence.stdout_excerpt.len);
    try expect(std.unicode.utf8ValidateSlice(res.commands[0].evidence.stdout_excerpt));
    try expect(std.unicode.utf8ValidateSlice(res.commands[0].evidence.stderr_excerpt));
}

test "commands execute in config order as parsed argv without a shell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const outs = [_]runner.RawOutcome{ outcome(0, false, false, "", ""), outcome(0, false, false, "", "") };
    var mock = Mock{ .outcomes = &outs };
    const res = try runner.runBaseline(a, mock.exec(), &.{ "zig build test", "zig test src/main.zig" }, "<project>");

    try expectEqual(@as(usize, 2), res.commands.len);
    try expectEqualStrings("zig build test", res.commands[0].command.original);
    try expectEqualStrings("zig test src/main.zig", res.commands[1].command.original);
    // Runner reuses the shared command parser argv shape (same as `zentinel check`).
    const parsed = try command.parse(a, "zig test src/main.zig");
    try expect(parsed == .ok);
    try expectEqual(parsed.ok.len, res.commands[1].command.argv.len);
    try expectEqualStrings(parsed.ok[2], res.commands[1].command.argv[2]);
    for (res.commands) |c| try expectEqual(false, c.command.shell);
}

test "baseline command evidence matches the documented snapshot shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const outs = [_]runner.RawOutcome{outcome(0, false, false, "", "")};
    var mock = Mock{ .outcomes = &outs };
    const res = try runner.runBaseline(a, mock.exec(), &.{"zig build test"}, "<project>");
    const json = try std.json.Stringify.valueAlloc(a, res.commands[0], .{ .whitespace = .indent_2 });
    try expectEqualStrings(command_snapshot, json);
}

// --- Compile error vs test failure classification (audit F-2) -----
//
// On pinned Zig 0.16 a `zig test`/`zig build` invocation that fails to compile
// emits compiler diagnostics (`<path>:<line>:<col>: error: ...`) and never runs
// the test binary, so the test-runner completion summary
// (`N passed; M skipped; K failed.`) is absent. A post-compile assertion failure
// always prints that summary. The runner must classify the former as
// `compile_error` and the latter as `test_failure`, so a compile-broken mutant is
// reported `compile_error` (I-010), not credited to the tests as `killed`.

const zig_compile_diagnostic =
    \\calc.zig:13:14: error: use of undeclared identifier 'gone'
    \\    return a + gone;
    \\             ^~~~
;

const zig_test_failure =
    \\1/1 calc.test.add...expected 5, found -1
    \\FAIL (TestExpectedEqual)
    \\0 passed; 0 skipped; 1 failed.
    \\error: the following test command failed with exit code 1:
;

fn classifyOne(a: std.mem.Allocator, raw: runner.RawOutcome) !report.CommandResult {
    const parsed = try command.parse(a, "zig test calc.zig");
    return runner.classifyCommand(a, .mutant, "zig test calc.zig", parsed.ok, "<workspace>", raw);
}

test "a non-zero command carrying a Zig compile diagnostic classifies as compile_error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cr = try classifyOne(a, outcome(1, false, false, "", zig_compile_diagnostic));
    try expectEqual(report.CommandStatus.failed, cr.status);
    try expectEqual(report.FailureKind.compile_error, cr.failure_kind);
}

test "a post-compile assertion failure stays test_failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cr = try classifyOne(a, outcome(1, false, false, "", zig_test_failure));
    try expectEqual(report.CommandStatus.failed, cr.status);
    try expectEqual(report.FailureKind.test_failure, cr.failure_kind);
}

test "a bare non-zero exit with no compile diagnostic stays test_failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No compile diagnostic and no test-runner summary: conservatively keep the
    // existing test_failure classification rather than over-claiming compile_error.
    const cr = try classifyOne(a, outcome(1, false, false, "", "boom"));
    try expectEqual(report.FailureKind.test_failure, cr.failure_kind);
}

// --- `zig build test` summary form ------------------------------------
//
// The default configured command is `zig build test`, which uses the `--listen=-`
// build protocol. Ground-truth capture on pinned Zig 0.16: the per-binary
// `N passed; M skipped; K failed.` summary is NEVER forwarded under `zig build`;
// instead the aggregated `Build Summary: .../.. tests passed (K failed|crashed)`
// line carries the result. A runtime test failure can also legitimately print a
// compiler-shaped `path:line:col: error:` line in its asserted output (any
// parser/lint/diagnostic test). With only the old `passed;` + `: error: ` markers
// such a genuine KILL was mis-bucketed as compile_error, deflating the score.

// Faithful excerpt of real `zig build test` stderr for a RUNTIME assertion
// failure whose asserted text contains `path:line:col: error:` (captured Zig
// 0.16, --listen=-): no `passed;`, a `: error: ` token, a `tests passed` clause.
const zig_build_test_runtime_failure_with_diagnostic =
    \\test
    \\+- run test 0 pass, 1 fail (1 total)
    \\error: 'main.test.asserts on a compiler-style diagnostic string' failed:
    \\       ====== expected this output: =========
    \\       src/foo.zig:3:5: warning: nope
    \\       ======== instead found this: =========
    \\       src/foo.zig:3:5: error: expected type 'u8'
    \\       ======================================
    \\Build Summary: 1/3 steps succeeded (1 failed); 0/1 tests passed (1 failed)
;

// Faithful excerpt of real `zig build test` stderr for a runtime PANIC/crash
// (captured Zig 0.16): the `tests passed` clause reports `1 crashed`. The test
// also printed a compiler-shaped `: error: ` line before panicking, so this
// exercises the same override path -- the crash is still a KILL, not a compile.
const zig_build_test_runtime_crash =
    \\test
    \\+- run test 0 pass, 1 crash (1 total)
    \\src/x.zig:1:1: error: diagnostic printed before the panic
    \\thread panic: index out of bounds: index 6, len 2
    \\Build Summary: 1/3 steps succeeded (1 failed); 0/1 tests passed (1 crashed)
;

// Faithful excerpt of real `zig build test` stderr for a COMPILE failure
// (captured Zig 0.16): a `: error: ` diagnostic and a Build Summary with NO
// `tests passed` clause, because no test binary ran.
const zig_build_test_compile_failure =
    \\test
    \\+- run test
    \\   +- compile test Debug native 1 errors
    \\src/main.zig:3:19: error: use of undeclared identifier 'gone_identifier'
    \\    const x: u8 = gone_identifier;
    \\                  ^~~~~~~~~~~~~~~
    \\error: 1 compilation errors
    \\Build Summary: 0/3 steps succeeded (1 failed)
;

test "a zig build test runtime failure with a diagnostic-shaped assertion stays test_failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The `tests passed` aggregate is decisive evidence the binary compiled and
    // ran, so the `: error: ` in the asserted text must NOT win: this is a KILL.
    const cr = try classifyOne(a, outcome(1, false, false, "", zig_build_test_runtime_failure_with_diagnostic));
    try expectEqual(report.CommandStatus.failed, cr.status);
    try expectEqual(report.FailureKind.test_failure, cr.failure_kind);
}

test "a zig build test runtime panic stays test_failure, not compile_error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cr = try classifyOne(a, outcome(1, false, false, "", zig_build_test_runtime_crash));
    try expectEqual(report.FailureKind.test_failure, cr.failure_kind);
}

test "a zig build test compile failure stays compile_error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Guard the other direction: a genuine compile failure (no `tests passed`
    // clause) must remain compile_error so the fix does not over-credit kills.
    const cr = try classifyOne(a, outcome(1, false, false, "", zig_build_test_compile_failure));
    try expectEqual(report.FailureKind.compile_error, cr.failure_kind);
}

// --- Truthful minimal environment -------------------------------
//
// The report labels every command `environment_policy = minimal`; the real
// executor (src/cli.zig) now actually passes runner.minimalEnviron, so the label
// is truthful. This asserts the restriction the executor applies.
test "minimalEnviron restricts the command environment to the documented allowlist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A parent environment with two allowlisted keys, a non-C locale, and a
    // non-allowlisted secret that must not leak into a spawned command. TMPDIR
    // and the ZIG_* caches are intentionally absent.
    var parent = std.process.Environ.Map.init(a);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin");
    try parent.put("HOME", "/home/dev");
    try parent.put("LANG", "en_US.UTF-8");
    try parent.put("ZNTL_SECRET", "leak");

    var minimal = try runner.minimalEnviron(a, &parent, &.{});
    defer minimal.deinit();

    // Allowlisted keys present in the parent are copied through unchanged.
    try expectEqualStrings("/usr/bin", minimal.get("PATH").?);
    try expectEqualStrings("/home/dev", minimal.get("HOME").?);
    // Locale is forced to C (not the inherited en_US.UTF-8) for deterministic,
    // locale-independent tool output.
    try expect(minimal.get("LC_ALL") != null);
    try expectEqualStrings("C", minimal.get("LC_ALL").?);
    try expectEqualStrings("C", minimal.get("LANG").?);
    // Absent allowlisted keys are omitted, never synthesized.
    try expect(minimal.get("TMPDIR") == null);
    try expect(minimal.get("ZIG_GLOBAL_CACHE_DIR") == null);
    // A non-allowlisted parent variable is dropped -- the inherited developer
    // environment does NOT pass through, so `environment_policy = minimal` is true.
    try expect(minimal.get("ZNTL_SECRET") == null);
    // Exactly the allowlisted-present keys (PATH, HOME) plus the two forced locale
    // keys plus the forced per-workspace local cache (ZIG_LOCAL_CACHE_DIR).
    try expectEqual(@as(usize, 5), minimal.keys().len);
    try expectEqualStrings("./.zig-cache", minimal.get("ZIG_LOCAL_CACHE_DIR").?);
}

test "minimalEnviron forces a cwd-relative ZIG_LOCAL_CACHE_DIR, overriding a host absolute value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parent = std.process.Environ.Map.init(a);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin");
    // A host ZIG_LOCAL_CACHE_DIR pointing at one shared absolute dir would, if
    // forwarded, route EVERY parallel worker's local Zig cache into that single
    // directory -- violating the documented per-worker isolation contract
    // (docs/SANDBOX_SECURITY.md, docs/PERFORMANCE_STRATEGY.md). The minimal env must
    // OVERRIDE it with the cwd-relative workspace cache so each command's own
    // working directory (= its per-mutant workspace) owns its `.zig-cache`.
    try parent.put("ZIG_LOCAL_CACHE_DIR", "/tmp/shared-zig-cache");

    var minimal = try runner.minimalEnviron(a, &parent, &.{});
    defer minimal.deinit();

    // Overridden to the cwd-relative cache, NOT the forwarded host absolute value.
    try expectEqualStrings("./.zig-cache", minimal.get("ZIG_LOCAL_CACHE_DIR").?);
    try expect(!std.mem.eql(u8, minimal.get("ZIG_LOCAL_CACHE_DIR").?, "/tmp/shared-zig-cache"));
}

test "minimalEnviron copies exactly the configured passthrough keys that the parent holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parent = std.process.Environ.Map.init(a);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin");
    try parent.put("KC_TEST_DB_URI", "postgresql://kc@127.0.0.1:5/kitcrew");
    try parent.put("ZNTL_SECRET", "leak");

    // A named key present in the parent crosses with its value; a named key the
    // parent lacks is omitted, never synthesized; an unnamed key stays out.
    var minimal = try runner.minimalEnviron(a, &parent, &.{ "KC_TEST_DB_URI", "KC_TEST_RLS_DB_URI" });
    defer minimal.deinit();
    try expectEqualStrings("postgresql://kc@127.0.0.1:5/kitcrew", minimal.get("KC_TEST_DB_URI").?);
    try expect(minimal.get("KC_TEST_RLS_DB_URI") == null);
    try expect(minimal.get("ZNTL_SECRET") == null);
    // PATH, LC_ALL, LANG, ZIG_LOCAL_CACHE_DIR, KC_TEST_DB_URI: nothing else.
    try expectEqual(@as(usize, 5), minimal.keys().len);

    // A passthrough name cannot override the forced per-workspace cache.
    var parent2 = std.process.Environ.Map.init(a);
    defer parent2.deinit();
    try parent2.put("ZIG_LOCAL_CACHE_DIR", "/tmp/shared-zig-cache");
    var minimal2 = try runner.minimalEnviron(a, &parent2, &.{"ZIG_LOCAL_CACHE_DIR"});
    defer minimal2.deinit();
    try expectEqualStrings("./.zig-cache", minimal2.get("ZIG_LOCAL_CACHE_DIR").?);
}
