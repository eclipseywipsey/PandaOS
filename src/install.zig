//! Install pipeline: runs every stage in order after the questions.
//!
//!   confirm -> partition -> mkfs -> mount -> extract sets -> configure ->
//!   accounts -> bootloader -> unmount

const std = @import("std");
const cfg = @import("config.zig");
const layout = @import("layout.zig");
const installer = @import("installer.zig");
const term = @import("term.zig");
const exec = @import("exec.zig");
const partition = @import("partition.zig");
const mkfs = @import("mkfs.zig");
const sets = @import("sets.zig");
const services = @import("services.zig");
const accounts = @import("accounts.zig");
const boot = @import("boot.zig");
const target = @import("target.zig");

pub const Options = struct {
    target: []const u8 = "/mnt",
    sets_dir: []const u8 = sets.default_dir,
};

fn stage(n: u8, total: u8, name: []const u8) void {
    term.print("\n[{d}/{d}] {s}\n", .{ n, total, name });
}

fn confirmErase(c: cfg.Config, buf: []u8) !void {
    term.print("\n  ALL DATA ON {s} WILL BE ERASED.\n  Type the disk path to continue, anything else aborts: ", .{c.disk});
    const line = term.readLine(buf) catch return error.Aborted;
    if (!std.mem.eql(u8, line, c.disk)) return error.Aborted;
}

pub fn run(a: std.mem.Allocator, res: *installer.Result, opts: Options) !void {
    const c = &res.config;
    const total: u8 = 8;

    var buf: [256]u8 = undefined;
    if (exec.dry_run) {
        term.write("\n  DRY RUN: nothing will be changed.\n");
    } else {
        try confirmErase(c.*, &buf);
    }

    stage(1, total, "Checking tools and kernel support");
    if (!mkfs.preflight(a, c.slices)) {
        if (!exec.dry_run) return error.PreflightFailed;
        term.write("  (dry run: continuing anyway)\n");
    }

    stage(2, total, "Writing partition table");
    const scheme: layout.Scheme = if (c.partition == .mbr) .bios_mbr else if (c.uefi) .uefi_gpt else .bios_gpt;
    const slices = @constCast(c.slices);
    const writes = switch (scheme) {
        .bios_mbr => try partition.planMbr(a, c.disk_sectors, slices),
        .uefi_gpt => try partition.planGpt(a, c.disk_sectors, slices, false),
        .bios_gpt => try partition.planGpt(a, c.disk_sectors, slices, true),
    };
    try partition.commit(a, c.disk, writes);

    stage(3, total, "Creating filesystems");
    try mkfs.makeAll(a, c.disk, c.slices);

    stage(4, total, "Mounting");
    try mkfs.mountAll(a, c.disk, c.slices, opts.target);
    errdefer mkfs.unmountAll(a, opts.target);

    stage(5, total, "Installing system sets");
    _ = try sets.installAll(a, opts.sets_dir, opts.target, c.*);

    stage(6, total, "Configuring the system");
    const tab = try mkfs.fstab(a, c.disk, c.slices);
    try target.writeFile(a, opts.target, "etc/fstab", tab, 0o644);
    try services.install(a, opts.target, c.*);

    stage(7, total, "Creating accounts");
    try accounts.install(a, opts.target, c.*, res.root_password.bytes(), res.user_password.bytes());
    res.root_password.wipe();
    res.user_password.wipe();

    stage(8, total, "Installing the bootloader");
    try boot.install(a, opts.target, c.*);

    term.write("\nUnmounting...\n");
    mkfs.unmountAll(a, opts.target);
    term.write("\nInstallation complete. Remove the install media and reboot.\n");
}
