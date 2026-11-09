//! Helpers for writing files inside the install target (e.g. /mnt).

const std = @import("std");
const exec = @import("exec.zig");
const term = @import("term.zig");

pub const Error = std.fs.File.OpenError || std.fs.Dir.MakeError || std.fs.File.WriteError || std.mem.Allocator.Error;

fn join(a: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ root, std.mem.trimLeft(u8, rel, "/") });
}

/// Writes `data` to <root>/<rel>, creating parent directories.
pub fn writeFile(a: std.mem.Allocator, root: []const u8, rel: []const u8, data: []const u8, mode: u32) Error!void {
    if (exec.dry_run) {
        term.print("  [dry-run] write {s} ({d} bytes, {o})\n", .{ rel, data.len, mode });
        return;
    }
    const full = try join(a, root, rel);
    defer a.free(full);
    if (std.fs.path.dirname(full)) |dir| try std.fs.cwd().makePath(dir);
    const f = try std.fs.cwd().createFile(full, .{ .mode = @intCast(mode), .truncate = true });
    defer f.close();
    try f.writeAll(data);
}

pub fn makeDir(a: std.mem.Allocator, root: []const u8, rel: []const u8) Error!void {
    if (exec.dry_run) {
        term.print("  [dry-run] mkdir {s}\n", .{rel});
        return;
    }
    const full = try join(a, root, rel);
    defer a.free(full);
    try std.fs.cwd().makePath(full);
}

/// Reads <root>/<rel>; returns an empty slice when the file does not exist.
pub fn readFile(a: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
    const full = try join(a, root, rel);
    defer a.free(full);
    return std.fs.cwd().readFileAlloc(a, full, 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => return a.alloc(u8, 0),
        else => return e,
    };
}

/// Appends a line (adds a trailing newline if missing).
pub fn appendLine(a: std.mem.Allocator, root: []const u8, rel: []const u8, line: []const u8, mode: u32) !void {
    const old = try readFile(a, root, rel);
    defer a.free(old);
    const nl: []const u8 = if (old.len > 0 and old[old.len - 1] != '\n') "\n" else "";
    const merged = try std.fmt.allocPrint(a, "{s}{s}{s}\n", .{ old, nl, line });
    defer a.free(merged);
    try writeFile(a, root, rel, merged, mode);
}
