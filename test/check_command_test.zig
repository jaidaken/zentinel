const std = @import("std");
const zentinel = @import("zentinel");
const check = zentinel.check_command;
const command = zentinel.command;
const zig_version = zentinel.zig_version;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const valid_cfg = @embedFile("fixtures/check/valid.toml");
const unknown_key_cfg = @embedFile("fixtures/check/unknown_key.toml");
const bad_command_cfg = @embedFile("fixtures/check/bad_command.toml");
const include_outside_cfg = @embedFile("fixtures/check/include_outside_root.toml");
const output_outside_cfg = @embedFile("fixtures/check/output_outside_root.toml");

const ok_zig: zig_version.Discovery = .{ .version = "0.16.0" };

fn runCheck(a: std.mem.Allocator, source: ?[]const u8, zig: zig_version.Discovery) !check.Result {
    return check.run(a, .{ .config_source = source, .config_path = "zentinel.toml", .zig = zig });
}

fn parse(a: std.mem.Allocator, s: []const u8) !command.Result {
    return command.parse(a, s);
}

fn expectInvalid(a: std.mem.Allocator, s: []const u8, reason: command.Reason) !void {
    switch (try parse(a, s)) {
        .invalid => |got| try expectEqual(reason, got),
        .ok => return error.TestUnexpectedResult,
    }
}

// --- Shared command parser (src/command.zig) -------------------------------

test "command parser splits bare argv fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "zig build test");
    try expect(r == .ok);
    try expectEqual(@as(usize, 3), r.ok.len);
    try expectEqualStrings("zig", r.ok[0]);
    try expectEqualStrings("build", r.ok[1]);
    try expectEqualStrings("test", r.ok[2]);
}

test "command parser groups quoted fields and empty quoted args after argv0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "zig \"build step\" \"\"");
    try expect(r == .ok);
    try expectEqual(@as(usize, 3), r.ok.len);
    try expectEqualStrings("build step", r.ok[1]);
    try expectEqualStrings("", r.ok[2]);
}

test "command parser allows supported escapes inside quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "zig \"a\\\"b\"");
    try expect(r == .ok);
    try expectEqualStrings("a\"b", r.ok[1]);
}

test "command parser rejects unmatched quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectEqual(command.Reason.unmatched_quote, (try parse(arena.allocator(), "zig \"abc")).invalid);
}

test "command parser rejects empty argv and empty argv0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectEqual(command.Reason.empty, (try parse(arena.allocator(), "")).invalid);
    try expectEqual(command.Reason.empty, (try parse(arena.allocator(), "   ")).invalid);
    try expectEqual(command.Reason.empty_argv0, (try parse(arena.allocator(), "\"\" zig")).invalid);
}

test "command parser rejects unsupported escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectEqual(command.Reason.unsupported_escape, (try parse(arena.allocator(), "zig \"a\\xb\"")).invalid);
}

test "command parser rejects backslash escapes outside quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectEqual(command.Reason.backslash_outside_quote, (try parse(arena.allocator(), "zig\\ build")).invalid);
}

test "command parser rejects shell metacharacters, expansion, and chaining" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectEqual(command.Reason.metacharacter, (try parse(a, "zig | cat")).invalid); // pipe
    try expectEqual(command.Reason.metacharacter, (try parse(a, "zig > out")).invalid); // redirect
    try expectEqual(command.Reason.metacharacter, (try parse(a, "zig $HOME")).invalid); // variable expansion
    try expectEqual(command.Reason.metacharacter, (try parse(a, "zig build && rm")).invalid); // chaining
    try expectEqual(command.Reason.metacharacter, (try parse(a, "echo *.zig")).invalid); // glob
    // Metacharacters are rejected even inside quotes -- the quoted and unquoted
    // branches share one isMeta rule (no separate isQuotedMeta wrapper), so a
    // quoted pipe is rejected exactly like a bare pipe.
    try expectEqual(command.Reason.metacharacter, (try parse(a, "zig \"$HOME\"")).invalid);
    try expectInvalid(a, "zig \"*.zig\"", .metacharacter);
    try expectInvalid(a, "zig \"test[0]\"", .metacharacter);
    try expectInvalid(a, "zig \"a|b\"", .metacharacter);
}

test "command parser rejects environment-assignment prefixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectEqual(command.Reason.env_assignment, (try parse(arena.allocator(), "FOO=bar zig test")).invalid);
}

// --- zentinel check (src/check_command.zig) --------------------------------

test "check passes for valid config and supported Zig" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runCheck(arena.allocator(), valid_cfg, ok_zig);
    try expectEqual(@as(u8, 0), r.exit_code);
    try expectEqualStrings("", r.code);
}

test "check fails with ZNTL_CONFIG_NOT_FOUND when config is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runCheck(arena.allocator(), null, ok_zig);
    try expectEqual(@as(u8, 2), r.exit_code);
    try expectEqualStrings("ZNTL_CONFIG_NOT_FOUND", r.code);
}

test "check fails on invalid config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runCheck(arena.allocator(), unknown_key_cfg, ok_zig);
    try expectEqual(@as(u8, 2), r.exit_code);
    try expectEqualStrings("ZNTL_CONFIG_UNKNOWN_KEY", r.code);
}

test "check treats missing Zig as a fatal environment error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runCheck(arena.allocator(), valid_cfg, .not_found);
    try expectEqual(@as(u8, 2), r.exit_code);
    try expectEqualStrings("ZNTL_ZIG_NOT_FOUND", r.code);
}

test "check treats unsupported Zig as a fatal environment error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runCheck(arena.allocator(), valid_cfg, .{ .version = "0.15.1" });
    try expectEqual(@as(u8, 2), r.exit_code);
    try expectEqualStrings("ZNTL_ZIG_UNSUPPORTED_VERSION", r.code);
    try expect(std.mem.indexOf(u8, r.message, "0.15.1") != null);
    try expect(std.mem.indexOf(u8, r.message, "0.16.0") != null);
}

test "check rejects include paths outside the project root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runCheck(arena.allocator(), include_outside_cfg, ok_zig);
    try expectEqual(@as(u8, 2), r.exit_code);
    try expectEqualStrings("ZNTL_CONFIG_INVALID_VALUE", r.code);
}

test "check rejects report output directory outside the project root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runCheck(arena.allocator(), output_outside_cfg, ok_zig);
    try expectEqual(@as(u8, 2), r.exit_code);
    try expectEqualStrings("ZNTL_CONFIG_INVALID_VALUE", r.code);
}

test "check rejects invalid configured command syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runCheck(arena.allocator(), bad_command_cfg, ok_zig);
    try expectEqual(@as(u8, 2), r.exit_code);
    try expectEqualStrings("ZNTL_CONFIG_INVALID_COMMAND", r.code);
}

test "check validates command syntax without executing the command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A syntactically valid command naming a nonexistent binary still passes
    // check; check parses argv but never runs it.
    const bogus =
        \\[project]
        \\name = "demo"
        \\[test]
        \\commands = ["definitely-not-a-real-binary --version"]
    ;
    const r = try runCheck(arena.allocator(), bogus, ok_zig);
    try expectEqual(@as(u8, 0), r.exit_code);
}

// --- Workspace siblings are probed, never assumed ---------------------------

const siblings_cfg =
    \\[project]
    \\name = "server"
    \\workspace_siblings = ["../core", "../contracts"]
    \\[test]
    \\commands = ["zig build test"]
;

const ProbeMock = struct {
    present: []const []const u8,
    asked: usize = 0,

    fn exists(ctx: *anyopaque, path: []const u8) bool {
        const self: *ProbeMock = @ptrCast(@alignCast(ctx));
        self.asked += 1;
        for (self.present) |p| if (std.mem.eql(u8, p, path)) return true;
        return false;
    }
    fn probe(self: *ProbeMock) check.SiblingProbe {
        return .{ .ctx = self, .existsFn = ProbeMock.exists };
    }
};

test "check fails when a configured workspace sibling is not beside the project root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mock = ProbeMock{ .present = &.{"../core"} };
    const r = try check.run(arena.allocator(), .{ .config_source = siblings_cfg, .config_path = "zentinel.toml", .zig = ok_zig, .sibling_probe = mock.probe() });
    try expectEqual(@as(u8, 2), r.exit_code);
    try expectEqualStrings("ZNTL_CONFIG_INVALID_VALUE", r.code);
    try expect(std.mem.indexOf(u8, r.message, "../contracts") != null);
    try expectEqual(@as(usize, 2), mock.asked);
}

test "check passes when every configured workspace sibling is present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mock = ProbeMock{ .present = &.{ "../core", "../contracts" } };
    const r = try check.run(arena.allocator(), .{ .config_source = siblings_cfg, .config_path = "zentinel.toml", .zig = ok_zig, .sibling_probe = mock.probe() });
    try expectEqual(@as(u8, 0), r.exit_code);
    try expectEqual(@as(usize, 2), mock.asked);
}

test "check without a sibling probe validates the config shape only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runCheck(arena.allocator(), siblings_cfg, ok_zig);
    try expectEqual(@as(u8, 0), r.exit_code);
}

// --- Global option routing (src/root.zig route) ----------------------------

test "route sends check to the check handler with the default config path" {
    const r = zentinel.route(&[_][]const u8{"check"});
    try expect(r == .check);
    try expectEqualStrings("zentinel.toml", r.check.config_path);
    try expect(!r.check.config_explicit);
}

test "route parses --config and --root before the check command" {
    const r = zentinel.route(&[_][]const u8{ "--config", "custom.toml", "--root", "sub", "check" });
    try expect(r == .check);
    try expectEqualStrings("custom.toml", r.check.config_path);
    try expect(r.check.config_explicit);
    try expectEqualStrings("sub", r.check.root);
}

test "route sends version to the version handler" {
    try expect(zentinel.route(&[_][]const u8{"version"}) == .version);
}

test "unowned global options still fail with ZNTL_CLI_INVALID_OPTION" {
    // --verbose is not an owned global option; route passes it to the frozen
    // Phase 0 dispatch, which rejects it deterministically.
    try expect(zentinel.route(&[_][]const u8{ "--verbose", "check" }) == .passthrough);
    const out = zentinel.dispatch(&[_][]const u8{ "--verbose", "check" }, false);
    try expectEqual(@as(u8, 2), out.exit_code);
    try expect(out.error_code == .cli_invalid_option);
}

test "--quiet is an unowned global option rejected with ZNTL_CLI_INVALID_OPTION" {
    // The removed `future_global_options` array listed --quiet as a "known future
    // option" but nothing read it: dispatch rejects --quiet generically like any
    // unknown option, and --quiet has no explicit guard. Pin its real behavior so
    // the deleted array's claim is enforced by a test, not a stale comment.
    try expect(zentinel.route(&[_][]const u8{ "--quiet", "check" }) == .passthrough);
    const out = zentinel.dispatch(&[_][]const u8{ "--quiet", "check" }, false);
    try expectEqual(@as(u8, 2), out.exit_code);
    try expect(out.error_code == .cli_invalid_option);
    // The detail names the exact offending option, not a generic message.
    try std.testing.expectEqualStrings("--quiet", out.detail);
}
