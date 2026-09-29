// Layer: deterministic_core
//
// `zentinel check` orchestration (docs/CLI_SPEC.md): validates config, Zig
// version policy, include/exclude paths, configured command syntax, and report
// output directory. Pure and deterministic: it receives already-gathered inputs
// (config bytes and a Zig discovery result) and never reads files, runs Zig, or
// executes configured commands. The presentation adapter performs that I/O.
const std = @import("std");
const config = @import("config.zig");
const command = @import("command.zig");
const zig_version = @import("zig_version.zig");

/// Injected existence probe for `project.workspace_siblings` entries (paths
/// relative to the project root). The adapter answers from the filesystem; tests
/// inject a deterministic mock. Absent, the entries are shape-checked only.
pub const SiblingProbe = struct {
    ctx: *anyopaque,
    existsFn: *const fn (ctx: *anyopaque, path: []const u8) bool,

    pub fn exists(self: SiblingProbe, path: []const u8) bool {
        return self.existsFn(self.ctx, path);
    }
};

pub const Input = struct {
    /// Bytes of the resolved config file, or null when it does not exist.
    config_source: ?[]const u8,
    /// Resolved config path, used only for diagnostics.
    config_path: []const u8,
    zig: zig_version.Discovery,
    sibling_probe: ?SiblingProbe = null,
};

pub const Result = struct {
    exit_code: u8,
    stdout: []const u8 = "",
    /// Public ZNTL error code token, or "" on success.
    code: []const u8 = "",
    message: []const u8 = "",
};

fn fail(code: []const u8, message: []const u8) Result {
    return .{ .exit_code = 2, .code = code, .message = message };
}

pub fn run(arena: std.mem.Allocator, input: Input) std.mem.Allocator.Error!Result {
    // 1. Config file presence.
    const source = input.config_source orelse {
        const msg = try std.fmt.allocPrint(arena, "config file not found: {s}", .{input.config_path});
        return fail(config.Code.not_found.token(), msg);
    };

    // 2. Config parse + validation (covers unknown keys, invalid values, the
    //    experimental-backend opt-in, and report output_dir containment).
    var cdiag: config.Diagnostic = .{};
    const cfg = config.load(arena, source, &cdiag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return fail(cdiag.code.token(), try configMessage(arena, cdiag)),
    };

    // 3. Zig version policy: missing or unsupported Zig is a fatal environment error.
    const zstatus = zig_version.classify(input.zig);
    if (zstatus != .supported) {
        const detected = switch (input.zig) {
            .version => |v| v,
            .not_found => "",
        };
        return fail(zig_version.codeFor(zstatus).token(), try zig_version.message(arena, zstatus, detected));
    }

    // 4. Include/exclude paths must stay within the project root.
    for (cfg.include) |p| {
        if (config.isOutsideRoot(p)) {
            return fail(config.Code.invalid_value.token(), try std.fmt.allocPrint(arena, "include path escapes the project root: {s}", .{p}));
        }
    }
    for (cfg.exclude) |p| {
        if (config.isOutsideRoot(p)) {
            return fail(config.Code.invalid_value.token(), try std.fmt.allocPrint(arena, "exclude path escapes the project root: {s}", .{p}));
        }
    }

    // 5. Configured test command syntax, validated with the shared parser but
    //    never executed.
    for (cfg.test_commands) |c| {
        switch (try command.parse(arena, c)) {
            .ok => {},
            .invalid => |reason| {
                const msg = try std.fmt.allocPrint(arena, "invalid test command syntax ({s}): {s}", .{ @tagName(reason), c });
                return fail(config.Code.invalid_command.token(), msg);
            },
        }
    }

    // 6. Every configured workspace sibling must exist beside the project root,
    //    or each mutant's workspace links to nothing and every build fails there.
    if (input.sibling_probe) |probe| {
        for (cfg.workspace_siblings) |entry| {
            if (!probe.exists(entry)) {
                return fail(config.Code.invalid_value.token(), try std.fmt.allocPrint(arena, "workspace sibling not found beside the project root: {s}", .{entry}));
            }
        }
    }

    return .{ .exit_code = 0, .stdout = "check: configuration and environment OK\n" };
}

fn configMessage(arena: std.mem.Allocator, diag: config.Diagnostic) std.mem.Allocator.Error![]const u8 {
    if (diag.line > 0) {
        return std.fmt.allocPrint(arena, "{s} (line {d})", .{ diag.message, diag.line });
    }
    if (diag.section.len > 0 and diag.key.len > 0) {
        return std.fmt.allocPrint(arena, "{s} [{s}.{s}]", .{ diag.message, diag.section, diag.key });
    }
    return arena.dupe(u8, diag.message);
}
