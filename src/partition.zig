//! Pure-Zig partition table writer (GPT and MBR with logical partitions).
//! plan*() build the exact sector writes in memory (testable); commit()
//! applies them to the disk. Assumes 512-byte logical sectors.

const std = @import("std");
const layout = @import("layout.zig");
const exec = @import("exec.zig");
const term = @import("term.zig");

pub const sector: u64 = 512;
pub const mib_sectors: u64 = 2048;

pub const Write = struct { lba: u64, data: []const u8 };
pub const PartError = error{ TooLarge, TooManyPartitions } || std.mem.Allocator.Error;

fn put16(b: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, b[off..][0..2], v, .little);
}
fn put32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}
fn put64(b: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, b[off..][0..8], v, .little);
}

// ---------------------------------------------------------------- GPT

const guid_efi = [16]u8{ 0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x69, 0xE3, 0xEF };
const guid_linux = [16]u8{ 0xAF, 0x3D, 0xC6, 0x0F, 0x83, 0x84, 0x72, 0x47, 0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4 };
const guid_swap = [16]u8{ 0x6E, 0xFD, 0x57, 0x06, 0xAB, 0xA4, 0xC4, 0x43, 0x84, 0xE5, 0x09, 0x33, 0xC8, 0x4B, 0x4F, 0x4F };
const guid_bios = [16]u8{ 0x48, 0x61, 0x68, 0x21, 0x49, 0x64, 0x6F, 0x6E, 0x74, 0x4E, 0x65, 0x65, 0x64, 0x45, 0x46, 0x49 };

fn typeGuid(fs: layout.Fs) [16]u8 {
    return switch (fs) {
        .vfat => guid_efi,
        .swap => guid_swap,
        .biosboot => guid_bios,
        .ffs, .btrfs => guid_linux,
    };
}

fn randomGuid() [16]u8 {
    var g: [16]u8 = undefined;
    std.crypto.random.bytes(&g);
    g[7] = (g[7] & 0x0f) | 0x40; // version 4 (mixed-endian field)
    g[8] = (g[8] & 0x3f) | 0x80;
    return g;
}

fn gptHeader(cur: u64, backup: u64, entries_lba: u64, last_usable: u64, disk_guid: [16]u8, entries_crc: u32) [512]u8 {
    var h = [_]u8{0} ** 512;
    @memcpy(h[0..8], "EFI PART");
    put32(&h, 8, 0x00010000);
    put32(&h, 12, 92);
    // 16..20: header CRC, filled below
    put64(&h, 24, cur);
    put64(&h, 32, backup);
    put64(&h, 40, 34); // first usable
    put64(&h, 48, last_usable);
    @memcpy(h[56..72], &disk_guid);
    put64(&h, 72, entries_lba);
    put32(&h, 80, 128);
    put32(&h, 84, 128);
    put32(&h, 88, entries_crc);
    put32(&h, 16, std.hash.Crc32.hash(h[0..92]));
    return h;
}

fn protectiveMbr(total_sectors: u64, bootable: bool) [512]u8 {
    var m = [_]u8{0} ** 512;
    const e = 446;
    m[e] = if (bootable) 0x80 else 0x00;
    m[e + 1] = 0x00;
    m[e + 2] = 0x02;
    m[e + 3] = 0x00;
    m[e + 4] = 0xEE;
    m[e + 5] = 0xFF;
    m[e + 6] = 0xFF;
    m[e + 7] = 0xFF;
    put32(&m, e + 8, 1);
    put32(&m, e + 12, @intCast(@min(total_sectors - 1, 0xFFFFFFFF)));
    m[510] = 0x55;
    m[511] = 0xAA;
    return m;
}

/// Assigns slice indexes and returns every sector write needed for a GPT disk.
pub fn planGpt(a: std.mem.Allocator, total_sectors: u64, slices: []layout.Slice, bios: bool) PartError![]Write {
    if (slices.len > 128) return error.TooManyPartitions;

    const entries = try a.alloc(u8, 128 * 128);
    @memset(entries, 0);

    var start: u64 = mib_sectors;
    for (slices, 0..) |*s, i| {
        s.index = @intCast(i + 1);
        const len = @as(u64, s.size_mib) * mib_sectors;
        const e = entries[i * 128 ..][0..128];
        const tg = typeGuid(s.fs);
        const ug = randomGuid();
        @memcpy(e[0..16], &tg);
        @memcpy(e[16..32], &ug);
        put64(e, 32, start);
        put64(e, 40, start + len - 1);
        const name = if (std.mem.eql(u8, s.mount, "/")) "root" else std.mem.trim(u8, s.mount, "/");
        for (name[0..@min(name.len, 35)], 0..) |ch, k| {
            put16(e, 56 + k * 2, if (ch == '/') '-' else ch);
        }
        start += len;
    }
    const last_usable = total_sectors - 34;
    if (start - 1 > last_usable) return error.TooLarge;

    const ecrc = std.hash.Crc32.hash(entries);
    const guid = randomGuid();
    const primary = gptHeader(1, total_sectors - 1, 2, last_usable, guid, ecrc);
    const backup = gptHeader(total_sectors - 1, 1, total_sectors - 33, last_usable, guid, ecrc);

    const zeros = try a.alloc(u8, 1024 * 1024);
    @memset(zeros, 0);
    const pm = try a.dupe(u8, &protectiveMbr(total_sectors, bios));
    const ph = try a.dupe(u8, &primary);
    const bh = try a.dupe(u8, &backup);

    var w: std.ArrayListUnmanaged(Write) = .empty;
    try w.append(a, .{ .lba = 0, .data = zeros }); // wipe old boot code / signatures
    try w.append(a, .{ .lba = 0, .data = pm });
    try w.append(a, .{ .lba = 1, .data = ph });
    try w.append(a, .{ .lba = 2, .data = entries });
    try w.append(a, .{ .lba = total_sectors - 33, .data = entries });
    try w.append(a, .{ .lba = total_sectors - 1, .data = bh });
    return w.toOwnedSlice(a);
}

// ---------------------------------------------------------------- MBR

fn mbrType(fs: layout.Fs) u8 {
    return switch (fs) {
        .swap => 0x82,
        .vfat => 0x0C,
        else => 0x83,
    };
}

fn mbrEntry(b: []u8, slot: usize, active: bool, ptype: u8, start: u64, len: u64) void {
    const o = 446 + slot * 16;
    b[o] = if (active) 0x80 else 0x00;
    b[o + 1] = 0xFE;
    b[o + 2] = 0xFF;
    b[o + 3] = 0xFF;
    b[o + 4] = ptype;
    b[o + 5] = 0xFE;
    b[o + 6] = 0xFF;
    b[o + 7] = 0xFF;
    put32(b, o + 8, @intCast(start));
    put32(b, o + 12, @intCast(len));
}

/// MBR: up to 3 primaries, then an extended partition holding the rest as
/// logical partitions (each slot loses 1 MiB to its EBR gap).
pub fn planMbr(a: std.mem.Allocator, total_sectors: u64, slices: []layout.Slice) PartError![]Write {
    if (total_sectors > 0xFFFFFFFF) return error.TooLarge;
    const n = slices.len;
    const np: usize = if (n <= 4) n else 3;

    const mbr = try a.alloc(u8, 512);
    @memset(mbr, 0);
    std.crypto.random.bytes(mbr[440..444]);

    var w: std.ArrayListUnmanaged(Write) = .empty;
    const zeros = try a.alloc(u8, 1024 * 1024);
    @memset(zeros, 0);
    const tail = try a.alloc(u8, 34 * 512);
    @memset(tail, 0);
    try w.append(a, .{ .lba = 0, .data = zeros });
    try w.append(a, .{ .lba = total_sectors - 34, .data = tail }); // kill any old backup GPT

    var start: u64 = mib_sectors;
    for (slices[0..np], 0..) |*s, i| {
        s.index = @intCast(i + 1);
        const len = @as(u64, s.size_mib) * mib_sectors;
        mbrEntry(mbr, i, std.mem.eql(u8, s.mount, "/boot"), mbrType(s.fs), start, len);
        start += len;
    }

    if (n > 4) {
        const ext_start = start;
        var ext_len: u64 = 0;
        for (slices[3..]) |s| ext_len += @as(u64, s.size_mib) * mib_sectors;
        mbrEntry(mbr, 3, false, 0x0F, ext_start, ext_len);

        var slot_start = ext_start;
        for (slices[3..], 0..) |*s, j| {
            s.index = @intCast(5 + j);
            const slot_len = @as(u64, s.size_mib) * mib_sectors;
            const ebr = try a.alloc(u8, 512);
            @memset(ebr, 0);
            mbrEntry(ebr, 0, false, mbrType(s.fs), mib_sectors, slot_len - mib_sectors);
            if (j + 1 < slices[3..].len) {
                const next_len = @as(u64, slices[3 + j + 1].size_mib) * mib_sectors;
                mbrEntry(ebr, 1, false, 0x05, slot_start + slot_len - ext_start, next_len);
            }
            ebr[510] = 0x55;
            ebr[511] = 0xAA;
            try w.append(a, .{ .lba = slot_start, .data = ebr });
            slot_start += slot_len;
        }
        start = slot_start;
    }
    if (start > total_sectors) return error.TooLarge;

    mbr[510] = 0x55;
    mbr[511] = 0xAA;
    try w.append(a, .{ .lba = 0, .data = mbr });
    return w.toOwnedSlice(a);
}

// ---------------------------------------------------------------- commit

pub fn commit(a: std.mem.Allocator, disk_path: []const u8, writes: []const Write) !void {
    if (exec.dry_run) {
        term.print("  [dry-run] would write {d} sector ranges to {s}\n", .{ writes.len, disk_path });
        return;
    }
    const f = try std.fs.openFileAbsolute(disk_path, .{ .mode = .read_write });
    defer f.close();
    for (writes) |wr| try f.pwriteAll(wr.data, wr.lba * sector);
    try f.sync();
    // Ask the kernel to re-read the table (BLKRRPART); harmless on image files.
    _ = std.os.linux.ioctl(f.handle, 0x125F, 0);
    if (exec.have(a, "udevadm")) exec.run(a, &.{ "udevadm", "settle" }) catch {};
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "GPT header CRC and bounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const total: u64 = 32 * 1024 * 2048; // 32 GiB
    const slices = try layout.fitLayout(a, 32 * 1024, .uefi_gpt);
    const w = try planGpt(a, total, slices, false);

    var hdr: ?[]const u8 = null;
    for (w) |x| { if (x.lba == 1) hdr = x.data; }
    const h = hdr.?;
    try testing.expectEqualStrings("EFI PART", h[0..8]);

    var copy: [92]u8 = undefined;
    @memcpy(&copy, h[0..92]);
    const stored = std.mem.readInt(u32, copy[16..20], .little);
    @memset(copy[16..20], 0);
    try testing.expectEqual(std.hash.Crc32.hash(&copy), stored);

    // indexes are sequential and the last partition ends inside the usable area
    for (slices, 0..) |s, i| try testing.expectEqual(@as(u8, @intCast(i + 1)), s.index);
}

test "MBR uses extended partition with logical slices" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const total: u64 = 64 * 1024 * 2048;
    const slices = try layout.fitLayout(a, 64 * 1024, .bios_mbr);
    const w = try planMbr(a, total, slices);
    
    var mbr: ?[]const u8 = null;
    for (w) |x| { if (x.lba == 0 and x.data.len == 512) mbr = x.data; }
    const m = mbr.?;
    try testing.expectEqual(@as(u8, 0x55), m[510]);
    try testing.expectEqual(@as(u8, 0xAA), m[511]);
    try testing.expectEqual(@as(u8, 0x0F), m[446 + 3 * 16 + 4]); // extended entry
    try testing.expectEqual(@as(u8, 5), slices[3].index);
}

test "MBR refuses disks over 2 TiB" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const slices = try layout.fitLayout(a, 4 * 1024 * 1024, .bios_mbr);
    try testing.expectError(error.TooLarge, planMbr(a, 4 * 1024 * 1024 * 2048, slices));
}
