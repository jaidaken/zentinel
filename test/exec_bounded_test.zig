const std = @import("std");
const zentinel = @import("zentinel");

const exec = zentinel.exec;

const expect = std.testing.expect;
const expectError = std.testing.expectError;

const Clock = std.Io.Clock;

fn millis(ms: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(ms), .clock = .awake } };
}

fn elapsedMs(io: std.Io, start: Clock.Timestamp) i64 {
    const ns = start.durationTo(Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

// Both tests drive real processes because the defects they pin are properties of
// process teardown and of wall time; a mock executor cannot exhibit either. Every
// child self-terminates so that an unfixed tree fails these tests instead of
// hanging the suite.

test "run_times_out_on_wall_clock_while_child_keeps_writing" {
    const io = std.testing.io;

    // The child writes every ~50ms for ~5s, then exits on its own. Against a
    // per-read (idle) timeout each write restarts the clock and nothing ever
    // fires, so the call returns the child's clean exit at ~5s and this test
    // fails on both assertions. Against a wall-clock deadline it fires at 400ms.
    const script = "i=0; while [ $i -lt 100 ]; do echo tick; i=$((i+1)); sleep 0.05; done";
    const argv = [_][]const u8{ "sh", "-c", script };

    const start = Clock.Timestamp.now(io, .awake);
    const result = exec.run(std.testing.allocator, io, .{
        .argv = &argv,
        .timeout = millis(400),
    });
    const took = elapsedMs(io, start);

    try expectError(error.Timeout, result);

    // The decisive half: erroring is not enough, it has to error EARLY. A tree
    // that only gave up when the child exited would also report a timeout on a
    // slower machine, so assert it returned nowhere near the child's ~5s life.
    try expect(took < 2000);
}

test "run_kills_descendants_that_outlive_the_direct_child" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The direct child backgrounds a grandchild that records its own pid and then
    // sleeps far past the timeout, and keeps writing so the deadline is what ends
    // the run. `exec` replaces the inner shell, so `pid` holds the sleeper itself.
    // Killing only the direct child leaves that sleeper alive; killing the process
    // group reaches it.
    const script =
        "sh -c 'echo $$ > pid; exec sleep 300' & " ++
        "i=0; while [ $i -lt 100 ]; do echo tick; i=$((i+1)); sleep 0.05; done";
    const argv = [_][]const u8{ "sh", "-c", script };

    const result = exec.run(std.testing.allocator, io, .{
        .argv = &argv,
        .cwd = .{ .dir = tmp.dir },
        .timeout = millis(400),
    });
    try expectError(error.Timeout, result);

    const raw = try tmp.dir.readFileAlloc(io, "pid", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(raw);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, raw, " \t\r\n"), 10);

    // The group signal is delivered synchronously, but the sleeper is reparented
    // when its shell dies and needs a moment to be reaped, so poll for its
    // disappearance rather than sampling once.
    var waited: i64 = 0;
    while (waited < 3000) : (waited += 50) {
        // Signal 0 performs error checking only: it probes liveness without
        // delivering anything, and reports ESRCH once the pid is gone.
        std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        try millis(50).sleep(io);
    }

    // Still alive after the poll window: the descendant outlived its group.
    return error.DescendantSurvivedTimeout;
}
