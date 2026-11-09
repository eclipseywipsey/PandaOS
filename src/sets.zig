//! Install sets: tarballs on the install media, one per package-set name
//! (base, kernel-linux, xbase, xshare, icewm, ...). Names that have no set
//! are queued as source ports to be built after first boot with `pkg`.

const std = @import("std");
const exec = @import("exec.zig");
const term = @import("term.zig");
const target = @import("target.zig");
const cfg = @import("config.zig");

pub const default_dir = "/run/pandaos/sets";

fn setPath(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}.tar.zst", .{ dir, name });
}

pub fn exists(a: std.mem.Allocator, dir: []const u8, name: []const u8) bool {
    if (exec.dry_run) return true;
    const p = setPath(a, dir, name) catch return false;
    defer a.free(p);
    std.fs.cwd().access(p, .{}) catch return false;
    return true;
}

pub fn extract(a: std.mem.Allocator, dir: []const u8, root: []const u8, name: []const u8) !void {
    const p = try setPath(a, dir, name);
    defer a.free(p);
    term.print("  extracting {s}\n", .{name});
    // -p keeps permissions/ownership; --numeric-owner avoids host passwd lookups.
    try exec.run(a, &.{ "tar", "-xpf", p, "--numeric-owner", "-C", root });
}

pub const Outcome = struct {
    /// Names that were extracted from the media.
    installed: []const []const u8,
    /// Names with no set: queued for a source build.
    pending: []const []const u8,
};

pub fn installAll(a: std.mem.Allocator, dir: []const u8, root: []const u8, c: cfg.Config) !Outcome {
    var done: std.ArrayListUnmanaged([]const u8) = .empty;
    var pend: std.ArrayListUnmanaged([]const u8) = .empty;

    const kernel_set = try std.fmt.allocPrint(a, "kernel-{s}", .{c.kernel.name()});
    const required = [_][]const u8{ "base", kernel_set };
    for (required) |name| {
        if (!exists(a, dir, name)) {
            term.print("  required set '{s}' not found in {s}\n", .{ name, dir });
            return error.MissingSet;
        }
        try extract(a, dir, root, name);
        try done.append(a, name);
    }
    for (c.packages) |name| {
        if (exists(a, dir, name)) {
            try extract(a, dir, root, name);
            try done.append(a, name);
        } else {
            term.print("  no prebuilt set for '{s}': queued as a source port\n", .{name});
            try pend.append(a, name);
        }
    }

    if (pend.items.len > 0) {
        const joined = try std.mem.join(a, "\n", pend.items);
        const text = try std.fmt.allocPrint(a, "{s}\n", .{joined});
        try target.writeFile(a, root, "var/lib/pkg/pending", text, 0o644);
    }
    return .{ .installed = done.items, .pending = pend.items };
}
