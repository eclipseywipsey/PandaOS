//! Filesystem creation, mounting under the install target, and fstab.

const std = @import("std");
const layout = @import("layout.zig");
const exec = @import("exec.zig");
const term = @import("term.zig");
const disk = @import("disk.zig");

pub const MkfsError = error{ NoFfsTools, MissingTool } || exec.ExecError || std.mem.Allocator.Error || std.fs.Dir.MakeError;

/// FFS is UFS1 ("44bsd" in Linux terms). The first tool found wins. PandaOS
/// ships `newfs_ffs`, a port of the BSD newfs, on the install media.
const FfsTool = struct { name: []const u8, args: []const []const u8 };
const ffs_tools = [_]FfsTool{
    .{ .name = "newfs_ffs", .args = &.{ "-O", "1" } },
    .{ .name = "newfs", .args = &.{ "-O", "1" } },
    .{ .name = "mkfs.ufs", .args = &.{ "-O", "1" } },
};

pub fn kernelHasFs(a: std.mem.Allocator, name: []const u8) bool {
    const data = std.fs.cwd().readFileAlloc(a, "/proc/filesystems", 64 * 1024) catch return false;
    defer a.free(data);
    var it = std.mem.tokenizeScalar(u8, data, '\n');
    while (it.next()) |line| {
        var cols = std.mem.tokenizeAny(u8, line, " \t");
        var last: []const u8 = "";
        while (cols.next()) |c| last = c;
        if (std.mem.eql(u8, last, name)) return true;
    }
    return false;
}

/// Verifies the running kernel and installed tools can do what the layout needs.
/// Returns false (after explaining) if a hard requirement is missing.
pub fn preflight(a: std.mem.Allocator, slices: []const layout.Slice) bool {
    var ok = true;
    var need_ffs = false;
    var need_btrfs = false;
    var need_vfat = false;
    for (slices) |s| switch (s.fs) {
        .ffs => need_ffs = true,
        .btrfs => need_btrfs = true,
        .vfat => need_vfat = true,
        else => {},
    };

    if (need_ffs) {
        var found = false;
        for (ffs_tools) |t| if (exec.have(a, t.name)) {
            found = true;
        };
        if (!found) {
            term.write("  missing: an FFS mkfs tool (newfs_ffs / newfs / mkfs.ufs)\n");
            ok = false;
        }
        if (!kernelHasFs(a, "ufs")) {
            term.write("  note: this kernel has no 'ufs' driver loaded (try: modprobe ufs)\n");
        }
    }
    if (need_btrfs and !exec.have(a, "mkfs.btrfs")) {
        term.write("  missing: mkfs.btrfs\n");
        ok = false;
    }
    if (need_vfat and !exec.have(a, "mkfs.vfat")) {
        term.write("  missing: mkfs.vfat\n");
        ok = false;
    }
    return ok;
}

fn label(s: layout.Slice) []const u8 {
    if (std.mem.eql(u8, s.mount, "/")) return "root";
    if (std.mem.eql(u8, s.mount, "/boot/efi")) return "EFI";
    return std.mem.trim(u8, s.mount, "/");
}

pub fn makeOne(a: std.mem.Allocator, dev: []const u8, s: layout.Slice) MkfsError!void {
    switch (s.fs) {
        .biosboot => {},
        .vfat => try exec.run(a, &.{ "mkfs.vfat", "-F", "32", "-n", "EFI", dev }),
        .btrfs => try exec.run(a, &.{ "mkfs.btrfs", "-f", "-L", label(s), dev }),
        .swap => try exec.run(a, &.{ "mkswap", "-L", "swap", dev }),
        .ffs => {
            if (exec.dry_run) return exec.run(a, &.{ "newfs_ffs", "-O", "1", dev });
            for (ffs_tools) |t| {
                if (!exec.have(a, t.name)) continue;
                var argv: std.ArrayListUnmanaged([]const u8) = .empty;
                defer argv.deinit(a);
                try argv.append(a, t.name);
                try argv.appendSlice(a, t.args);
                try argv.append(a, dev);
                return exec.run(a, argv.items);
            }
            return error.NoFfsTools;
        },
    }
}

pub fn makeAll(a: std.mem.Allocator, disk_path: []const u8, slices: []const layout.Slice) MkfsError!void {
    for (slices) |s| {
        if (s.fs == .biosboot) continue;
        const dev = try disk.partPath(a, disk_path, s.index);
        defer a.free(dev);
        term.print("  formatting {s} ({s}) as {s}\n", .{ dev, s.mount, s.fs.name() });
        if (exec.have(a, "wipefs")) exec.run(a, &.{ "wipefs", "-a", dev }) catch {};
        try makeOne(a, dev, s);
    }
}

// ---------------------------------------------------------------- mounting

fn mountOptions(s: layout.Slice) []const u8 {
    const hard = std.mem.eql(u8, s.mount, "/tmp") or std.mem.eql(u8, s.mount, "/home");
    return switch (s.fs) {
        .ffs => if (hard) "rw,noatime,nodev,nosuid,ufstype=44bsd" else "rw,noatime,ufstype=44bsd",
        .btrfs => if (hard) "noatime,nodev,nosuid,compress=zstd" else "noatime,compress=zstd",
        .vfat => "umask=0077",
        else => "defaults",
    };
}

fn fsType(fs: layout.Fs) []const u8 {
    return switch (fs) {
        .ffs => "ufs",
        .btrfs => "btrfs",
        .vfat => "vfat",
        .swap => "swap",
        .biosboot => "none",
    };
}

/// Slices in mount order (parents before children), skipping swap/biosboot.
fn mountOrder(a: std.mem.Allocator, slices: []const layout.Slice) ![]layout.Slice {
    var list: std.ArrayListUnmanaged(layout.Slice) = .empty;
    for (slices) |s| if (s.fs != .swap and s.fs != .biosboot) try list.append(a, s);
    std.mem.sort(layout.Slice, list.items, {}, struct {
        fn lt(_: void, x: layout.Slice, y: layout.Slice) bool {
            return x.mount.len < y.mount.len;
        }
    }.lt);
    return list.toOwnedSlice(a);
}

pub fn mountAll(a: std.mem.Allocator, disk_path: []const u8, slices: []const layout.Slice, target: []const u8) !void {
    const order = try mountOrder(a, slices);
    defer a.free(order);
    for (order) |s| {
        const dest = try std.fmt.allocPrint(a, "{s}{s}", .{ target, if (std.mem.eql(u8, s.mount, "/")) "" else s.mount });
        defer a.free(dest);
        if (!exec.dry_run) try std.fs.cwd().makePath(dest);
        const dev = try disk.partPath(a, disk_path, s.index);
        defer a.free(dev);
        try exec.run(a, &.{ "mount", "-t", fsType(s.fs), "-o", mountOptions(s), dev, dest });
    }
    for (slices) |s| if (s.fs == .swap) {
        const dev = try disk.partPath(a, disk_path, s.index);
        defer a.free(dev);
        exec.run(a, &.{ "swapon", dev }) catch {};
    };
}

pub fn unmountAll(a: std.mem.Allocator, target: []const u8) void {
    exec.run(a, &.{ "umount", "-R", target }) catch {};
}

// ---------------------------------------------------------------- fstab

/// Builds /etc/fstab. Uses device paths: with a single-disk install these are
/// stable, and UFS has no UUID for blkid to report.
pub fn fstab(a: std.mem.Allocator, disk_path: []const u8, slices: []const layout.Slice) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(a, "# /etc/fstab: generated by pandaos-install\n# <device> <mount> <type> <options> <dump> <pass>\n");
    for (slices) |s| {
        if (s.fs == .biosboot) continue;
        const dev = try disk.partPath(a, disk_path, s.index);
        const is_root = std.mem.eql(u8, s.mount, "/");
        const line = if (s.fs == .swap)
            try std.fmt.allocPrint(a, "{s} none swap sw 0 0\n", .{dev})
        else
            try std.fmt.allocPrint(a, "{s} {s} {s} {s} 0 {d}\n", .{
                dev, s.mount, fsType(s.fs), mountOptions(s), @as(u8, if (is_root) 1 else 2),
            });
        try out.appendSlice(a, line);
    }
    return out.toOwnedSlice(a);
}

test "fstab has root first-pass and swap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sl = try layout.fitLayout(a, 64 * 1024, .uefi_gpt);
    for (sl, 0..) |*s, i| s.index = @intCast(i + 1);
    const tab = try fstab(a, "/dev/sda", sl);
    try std.testing.expect(std.mem.indexOf(u8, tab, " / ufs ") != null);
    try std.testing.expect(std.mem.indexOf(u8, tab, " none swap sw 0 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, tab, "/home btrfs") != null);
}

test "mount order puts parents first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sl = try layout.fitLayout(a, 64 * 1024, .uefi_gpt);
    const ord = try mountOrder(a, sl);
    try std.testing.expectEqualStrings("/", ord[0].mount);
}
