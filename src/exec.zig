//! Command runner shared by every install stage.
//! In dry-run mode commands are printed instead of executed.

const std = @import("std");
const term = @import("term.zig");

pub var dry_run: bool = false;

pub const ExecError = error{CommandFailed} || std.process.Child.SpawnError || std.process.Child.WaitError;

fn show(argv: []const []const u8) void {
    term.write("  $");
    for (argv) |arg| {
        term.write(" ");
        term.write(arg);
    }
    term.write("\n");
}

pub fn run(a: std.mem.Allocator, argv: []const []const u8) ExecError!void {
    return runStdin(a, argv, null);
}

/// Runs argv, optionally feeding `input` on stdin (used for passwords etc.;
/// never printed in dry-run mode).
pub fn runStdin(a: std.mem.Allocator, argv: []const []const u8, input: ?[]const u8) ExecError!void {
    if (dry_run) {
        show(argv);
        return;
    }
    var child = std.process.Child.init(argv, a);
    if (input != null) child.stdin_behavior = .Pipe;
    try child.spawn();
    if (input) |data| {
        child.stdin.?.writeAll(data) catch {};
        child.stdin.?.close();
        child.stdin = null;
    }
    const result = try child.wait();
    switch (result) {
        .Exited => |code| if (code == 0) return,
        else => {},
    }
    term.print("  command failed: {s}\n", .{argv[0]});
    return error.CommandFailed;
}

/// Runs argv inside `target` via chroot.
pub fn runIn(a: std.mem.Allocator, target: []const u8, argv: []const []const u8) ExecError!void {
    var full: std.ArrayListUnmanaged([]const u8) = .empty;
    defer full.deinit(a);
    full.appendSlice(a, &.{ "chroot", target }) catch return error.CommandFailed;
    full.appendSlice(a, argv) catch return error.CommandFailed;
    return run(a, full.items);
}

/// True if `name` is found on PATH.
pub fn have(a: std.mem.Allocator, name: []const u8) bool {
    const path = std.process.getEnvVarOwned(a, "PATH") catch return false;
    defer a.free(path);
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |dir| {
        const full = std.fs.path.join(a, &.{ dir, name }) catch continue;
        defer a.free(full);
        std.fs.accessAbsolute(full, .{}) catch continue;
        return true;
    }
    return false;
}

/// Runs argv and returns its stdout (caller frees). Fails on non-zero exit.
pub fn capture(a: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv, .max_output_bytes = 16 * 1024 * 1024 });
    a.free(r.stderr);
    switch (r.term) {
        .Exited => |code| if (code == 0) return r.stdout,
        else => {},
    }
    a.free(r.stdout);
    return error.CommandFailed;
}
