//! Partition layout model and disk-size fitting.
//! Sizes are in MiB. fitLayout() turns the ideal layout into one that fits
//! the actual disk: it merges small slices into their parents, shrinks
//! slices toward their minimums, and gives all leftover space to /home.

const std = @import("std");

pub const Scheme = enum { uefi_gpt, bios_gpt, bios_mbr };

pub const Fs = enum {
    biosboot, // raw 1 MiB partition for GRUB core on BIOS+GPT
    vfat,
    ffs,
    btrfs,
    swap,

    pub fn name(self: Fs) []const u8 {
        return @tagName(self);
    }
};

pub const Slice = struct {
    mount: []const u8,
    fs: Fs,
    min_mib: u32,
    pref_mib: u32,
    /// Receives all leftover space (only /home).
    grow: bool = false,
    /// Filled in by fitLayout.
    size_mib: u32 = 0,
    /// Filled in by the partition stage (1-based).
    index: u8 = 0,
};

pub const FitError = error{DiskTooSmall} || std.mem.Allocator.Error;

/// MiB lost to the first-MiB alignment gap and the GPT backup table.
pub const overhead_mib: u64 = 2;

/// Smallest disk the installer will accept, in MiB.
pub const hard_floor_mib: u64 = 4096;

/// ESP is FAT32 (UEFI firmware cannot read FFS). Only present on GPT.
const esp = Slice{ .mount = "/boot/efi", .fs = .vfat, .min_mib = 128, .pref_mib = 256 };

/// GRUB's core image lives here on BIOS-booted GPT disks.
const bios_boot = Slice{ .mount = "biosboot", .fs = .biosboot, .min_mib = 1, .pref_mib = 1 };

const base = [_]Slice{
    .{ .mount = "/boot", .fs = .ffs, .min_mib = 256, .pref_mib = 512 },
    .{ .mount = "/", .fs = .ffs, .min_mib = 1536, .pref_mib = 4096 },
    .{ .mount = "swap", .fs = .swap, .min_mib = 512, .pref_mib = 2048 },
    .{ .mount = "/usr", .fs = .ffs, .min_mib = 2048, .pref_mib = 6144 },
    .{ .mount = "/usr/local", .fs = .ffs, .min_mib = 1024, .pref_mib = 8192 },
    .{ .mount = "/var", .fs = .ffs, .min_mib = 512, .pref_mib = 4096 },
    .{ .mount = "/tmp", .fs = .ffs, .min_mib = 256, .pref_mib = 2048 },
    .{ .mount = "/home", .fs = .btrfs, .min_mib = 1024, .pref_mib = 1024, .grow = true },
};

/// When the disk is too small, slices are folded into a parent in this order.
const Merge = struct { child: []const u8, parent: []const u8 };
const merge_order = [_]Merge{
    .{ .child = "/usr/local", .parent = "/usr" },
    .{ .child = "/tmp", .parent = "/" },
    .{ .child = "/var", .parent = "/" },
    .{ .child = "/usr", .parent = "/" },
};

fn indexOf(list: []const Slice, mount: []const u8) ?usize {
    for (list, 0..) |s, i| if (std.mem.eql(u8, s.mount, mount)) return i;
    return null;
}

fn sumMin(list: []const Slice) u64 {
    var t: u64 = 0;
    for (list) |s| t += s.min_mib;
    return t;
}

/// The unmodified ideal layout (used for display and the [E]dit starting point).
pub fn ideal(a: std.mem.Allocator, scheme: Scheme) ![]Slice {
    var list: std.ArrayListUnmanaged(Slice) = .empty;
    switch (scheme) {
        .uefi_gpt => try list.append(a, esp),
        .bios_gpt => try list.append(a, bios_boot),
        .bios_mbr => {},
    }
    try list.appendSlice(a, &base);
    for (list.items) |*s| s.size_mib = s.pref_mib;
    return list.toOwnedSlice(a);
}

pub fn fitLayout(a: std.mem.Allocator, disk_mib: u64, scheme: Scheme) FitError![]Slice {
    if (disk_mib < hard_floor_mib) return error.DiskTooSmall;
    const usable = disk_mib - overhead_mib;

    var list: std.ArrayListUnmanaged(Slice) = .empty;
    errdefer list.deinit(a);
    switch (scheme) {
        .uefi_gpt => try list.append(a, esp),
        .bios_gpt => try list.append(a, bios_boot),
        .bios_mbr => {},
    }
    try list.appendSlice(a, &base);

    // 1. Merge slices into parents until the minimums fit.
    for (merge_order) |m| {
        if (sumMin(list.items) <= usable) break;
        const ci = indexOf(list.items, m.child) orelse continue;
        const pi = indexOf(list.items, m.parent) orelse continue;
        list.items[pi].min_mib += list.items[ci].min_mib;
        list.items[pi].pref_mib += list.items[ci].pref_mib;
        _ = list.orderedRemove(ci);
    }
    if (sumMin(list.items) > usable) return error.DiskTooSmall;

    // 2. Everyone starts at their minimum.
    for (list.items) |*s| s.size_mib = s.min_mib;
    var left: u64 = usable - sumMin(list.items);

    // 3. Grow toward preferred sizes, proportionally if space is short.
    var want: u64 = 0;
    for (list.items) |s| want += s.pref_mib - s.min_mib;
    if (want > 0) {
        const give = @min(left, want);
        var used: u64 = 0;
        for (list.items) |*s| {
            const extra: u64 = s.pref_mib - s.min_mib;
            const add: u64 = extra * give / want;
            s.size_mib += @intCast(add);
            used += add;
        }
        left -= used;
    }

    // 4. Whatever remains goes to the growing slice (/home).
    for (list.items) |*s| {
        if (s.grow) {
            s.size_mib += @intCast(left);
            left = 0;
        }
    }
    return list.toOwnedSlice(a);
}

pub fn totalMib(list: []const Slice) u64 {
    var t: u64 = 0;
    for (list) |s| t += s.size_mib;
    return t;
}

// ---------------------------------------------------------------- tests

fn expectFits(disk_gib: u64, scheme: Scheme) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const disk = disk_gib * 1024;
    const l = try fitLayout(arena.allocator(), disk, scheme);
    try std.testing.expect(totalMib(l) <= disk - overhead_mib);
    for (l) |s| try std.testing.expect(s.size_mib >= s.min_mib);
    try std.testing.expect(indexOf(l, "/") != null);
    try std.testing.expect(indexOf(l, "/home") != null);
}

test "layouts fit 8, 16, 32 and 512 GiB disks" {
    try expectFits(8, .uefi_gpt);
    try expectFits(16, .uefi_gpt);
    try expectFits(32, .uefi_gpt);
    try expectFits(512, .uefi_gpt);
    try expectFits(16, .bios_gpt);
    try expectFits(16, .bios_mbr);
}

test "tiny disks are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.DiskTooSmall, fitLayout(arena.allocator(), 2048, .uefi_gpt));
}

test "big disk gives preferred sizes and the rest to /home" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const l = try fitLayout(arena.allocator(), 512 * 1024, .uefi_gpt);
    const root = l[indexOf(l, "/").?];
    try std.testing.expectEqual(@as(u32, 4096), root.size_mib);
    const home = l[indexOf(l, "/home").?];
    try std.testing.expect(home.size_mib > 400 * 1024);
}
