// Layer: side_effect_adapter

//! Wall-bounded process execution with process-group teardown.
//!
//! Exists because `std.process.run` is wrong for a mutation runner in two ways
//! that only appear when a mutant hangs:
//!
//! 1. `RunOptions.timeout` is forwarded to every `MultiReader.fill` call in the
//!    collection loop. An `Io.Timeout.duration` resolves with `.fromNow` at each
//!    use, so a child that writes anything before the limit expires restarts the
//!    clock. That is an idle timeout, not a wall-clock bound, and `zig build`
//!    emits progress continuously, so a mutant looping forever is never timed
//!    out. This module resolves the timeout to an absolute `.deadline` once,
//!    before the loop.
//!
//! 2. Teardown is `child.kill`, which signals only the DIRECT child. `zig build
//!    test` is three processes deep (zig -> build runner -> test binary), so the
//!    two that hold the memory are orphaned. `RunOptions` has no `pgid` field,
//!    so the stdlib helper cannot be configured out of this. Here the child is a
//!    new process-group leader and teardown signals the whole group.
//!
//! The collection loop is otherwise a deliberate copy of `std.process.run` (Zig
//! 0.16 `lib/std/process.zig`), kept structurally identical so the two can be
//! diffed on a toolchain bump.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Child = std.process.Child;

pub const RunError = std.process.RunError;

pub const RunResult = struct {
    term: Child.Term,
    stdout: []u8,
    stderr: []u8,
};

pub const RunOptions = struct {
    argv: []const []const u8,
    stdout_limit: Io.Limit = .unlimited,
    stderr_limit: Io.Limit = .unlimited,
    /// How many bytes to initially allocate for stderr and stdout.
    reserve_amount: usize = 64,
    cwd: Child.Cwd = .inherit,
    environ_map: ?*const std.process.Environ.Map = null,
    /// Bounds the TOTAL wall time of the command, not the gap between reads.
    timeout: Io.Timeout = .none,
};

/// Process groups are a POSIX concept. On targets without them the group
/// teardown degrades to the direct-child kill that `std.process.run` performs,
/// which is strictly no worse than the stdlib behaviour.
pub const process_groups_supported = switch (builtin.os.tag) {
    .windows, .wasi => false,
    else => true,
};

/// Terminate the child and every descendant it left behind, then reap it.
///
/// The group is signalled FIRST so that descendants which have outlived the
/// direct child (an orphaned build runner, a wedged test binary) are covered:
/// once `child.kill` returns, `child.id` is null and the group id is no longer
/// recoverable from the child. Signalling an already-empty group fails with
/// `ProcessNotFound`, which is the expected outcome on the success path and is
/// not an error worth surfacing.
fn terminateGroup(io: Io, child: *Child, group: ?Child.Id) void {
    if (process_groups_supported) {
        if (group) |gid| {
            // Teardown on a path that is already unwinding: a failure to signal
            // leaves nothing for the caller to act on, and the reap below is
            // still attempted.
            std.posix.kill(-gid, .KILL) catch {};
        }
    }
    child.kill(io);
}

/// Spawn `options.argv`, collect stdout/stderr, and return the result.
///
/// Differs from `std.process.run` only in the two properties this module exists
/// for: the timeout is an absolute wall-clock deadline, and teardown reaches the
/// whole process group. Caller owns `stdout`/`stderr` on success.
pub fn run(gpa: std.mem.Allocator, io: Io, options: RunOptions) RunError!RunResult {
    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,

        // Make the child a process-group leader so its whole tree can be
        // signalled by group id. `0` means "new group whose id is the child pid".
        .pgid = if (process_groups_supported) 0 else null,

        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    // Captured now because `child.kill`/`child.wait` clear `child.id`, and the
    // group id is the child's pid.
    const group = child.id;
    defer terminateGroup(io, &child, group);

    // THE FIX FOR (1). Resolve the timeout to an absolute timestamp ONCE, here,
    // rather than letting each `fill` below re-resolve a duration from "now".
    const deadline = options.timeout.toDeadline(io);

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(options.reserve_amount, deadline)) |_| {
        if (options.stdout_limit.toInt()) |limit| {
            if (stdout_reader.buffered().len > limit)
                return error.StreamTooLong;
        }
        if (options.stderr_limit.toInt()) |limit| {
            if (stderr_reader.buffered().len > limit)
                return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();

    const term = try child.wait(io);

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer gpa.free(stdout_slice);

    const stderr_slice = try multi_reader.toOwnedSlice(1);
    errdefer gpa.free(stderr_slice);

    return .{
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .term = term,
    };
}
