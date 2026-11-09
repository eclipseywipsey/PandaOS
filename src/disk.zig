//! Disk discovery via sysfs. No external tools needed.

const std = @import("std");

pub const Disk = struct {
    /// Device node, e.g. /dev/sda
    path: []const u8,
    /// Exact size in 512-byte sectors (needed for the GPT backup header)
    sectors: u64,
    /// Size in MiB
    mib: u64,
    model: []const u8,
    removable: bool,
};

fn skipDevice(name: []const u8) bool {
    const prefixes = [_][]const u8{ "loop", "ram", "sr", "zram", "dm-", "md", "fd", "nbd" };
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

fn readTrimmed(a: std.mem.Allocator, path: []const u8) ?[]u8 {
    const data = std.fs.cwd().readFileAlloc(a, path, 4096) catch return null;
    return @constCast(std.mem.trim(u8, data, " \t\r\n"));
}

pub fn list(a: std.mem.Allocator) ![]Disk {
    var out: std.ArrayListUnmanaged(Disk) = .empty;
    var dir = std.fs.cwd().openDir("/sys/block", .{ .iterate = true }) catch return out.toOwnedSlice(a);
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |e| {
        if (skipDevice(e.name)) continue;

        const size_path = try std.fmt.allocPrint(a, "/sys/block/{s}/size", .{e.name});
        const sectors_s = readTrimmed(a, size_path) orelse continue;
        const sectors = std.fmt.parseInt(u64, sectors_s, 10) catch continue;
        if (sectors == 0) continue;

        const model_path = try std.fmt.allocPrint(a, "/sys/block/{s}/device/model", .{e.name});
        const rem_path = try std.fmt.allocPrint(a, "/sys/block/{s}/removable", .{e.name});
        const removable = if (readTrimmed(a, rem_path)) |r| std.mem.eql(u8, r, "1") else false;

        try out.append(a, .{
            .path = try std.fmt.allocPrint(a, "/dev/{s}", .{e.name}),
            .sectors = sectors,
            .mib = sectors / 2048,
            .model = readTrimmed(a, model_path) orelse "unknown",
            .removable = removable,
        });
    }
    std.mem.sort(Disk, out.items, {}, struct {
        fn lt(_: void, x: Disk, y: Disk) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    return out.toOwnedSlice(a);
}

/// True when the running system was booted through UEFI.
pub fn isUefi() bool {
    std.fs.accessAbsolute("/sys/firmware/efi", .{}) catch return false;
    return true;
}

/// Partition device node for slice `n` of `disk`: /dev/sda -> /dev/sda1,
/// /dev/nvme0n1 -> /dev/nvme0n1p1 (names ending in a digit get a 'p').
pub fn partPath(a: std.mem.Allocator, disk: []const u8, n: u8) ![]u8 {
    const last = disk[disk.len - 1];
    const sep: []const u8 = if (last >= '0' and last <= '9') "p" else "";
    return std.fmt.allocPrint(a, "{s}{s}{d}", .{ disk, sep, n });
}

test "partPath naming" {
    const a = std.testing.allocator;
    const p1 = try partPath(a, "/dev/sda", 2);
    defer a.free(p1);
    try std.testing.expectEqualStrings("/dev/sda2", p1);
    const p2 = try partPath(a, "/dev/nvme0n1", 1);
    defer a.free(p2);
    try std.testing.expectEqualStrings("/dev/nvme0n1p1", p2);
}
