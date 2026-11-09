//! The text installer: the seven-question cascade.

const std = @import("std");
const term = @import("term.zig");
const cfg = @import("config.zig");
const layout = @import("layout.zig");
const disk = @import("disk.zig");

/// Holds the root password in a fixed buffer so it can be wiped.
pub const Secret = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    pub fn bytes(self: *const Secret) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn wipe(self: *Secret) void {
        std.crypto.secureZero(u8, self.buf[0..]);
        self.len = 0;
    }
};

pub const Result = struct {
    config: cfg.Config,
    root_password: Secret = .{},
    user_password: Secret = .{},
};

/// Prompts twice (no echo) into `secret`; loops until both entries match.
fn promptPassword(secret: *Secret) !void {
    while (true) {
        term.write("     password: ");
        const p1 = term.readPassword(secret.buf[0..]) catch |e| switch (e) {
            error.LineTooLong => {
                term.write("     too long (max 127 characters)\n");
                continue;
            },
            else => return e,
        };
        if (p1.len < 8) {
            term.write("     too short (minimum 8 characters)\n");
            secret.wipe();
            continue;
        }
        secret.len = p1.len;

        var confirm: [128]u8 = undefined;
        term.write("     confirm:  ");
        const p2 = term.readPassword(confirm[0..]) catch |e| switch (e) {
            error.LineTooLong => {
                std.crypto.secureZero(u8, confirm[0..]);
                secret.wipe();
                term.write("     too long\n");
                continue;
            },
            else => return e,
        };
        const same = std.mem.eql(u8, secret.bytes(), p2);
        std.crypto.secureZero(u8, confirm[0..]);
        if (same) return;
        secret.wipe();
        term.write("     passwords did not match\n");
    }
}

// ---------------------------------------------------------------- helpers

/// Reads a line, lower-cased in place. Re-prompts on over-long input.
fn readInput(buf: []u8) ![]u8 {
    while (true) {
        const line = term.readLine(buf) catch |e| switch (e) {
            error.LineTooLong => {
                term.write("  input too long, try again: ");
                continue;
            },
            else => return e,
        };
        for (line) |*ch| ch.* = std.ascii.toLower(ch.*);
        return line;
    }
}

/// "<question> [<default>]: " -> trimmed lower-case answer, or `default`
/// when the user just presses enter. Result may alias `buf`.
fn ask(buf: []u8, question: []const u8, default: []const u8) ![]const u8 {
    term.print("{s} [{s}]: ", .{ question, default });
    const line = try readInput(buf);
    if (line.len == 0) return default;
    return line;
}

fn askYesNo(buf: []u8, question: []const u8, default_yes: bool) !bool {
    const default = if (default_yes) "y" else "n";
    while (true) {
        const a = try ask(buf, question, default);
        if (std.mem.eql(u8, a, "y") or std.mem.eql(u8, a, "yes")) return true;
        if (std.mem.eql(u8, a, "n") or std.mem.eql(u8, a, "no")) return false;
        term.write("  please answer y or n\n");
    }
}

fn askFromList(
    arena: std.mem.Allocator,
    buf: []u8,
    title: []const u8,
    list: []const []const u8,
    default: []const u8,
) ![]const u8 {
    while (true) {
        term.print("{s} (", .{title});
        for (list, 0..) |item, i| {
            if (i != 0) term.write(", ");
            term.write(item);
        }
        term.print(", lower-case name) [{s}]: ", .{default});
        const line = try readInput(buf);
        const pick = if (line.len == 0) default else line;
        if (cfg.contains(list, pick)) return arena.dupe(u8, pick);
        term.write("  not one of the listed options\n");
    }
}

fn printPackages(pkgs: []const []const u8) void {
    term.write("\n     ");
    for (pkgs, 0..) |p, i| {
        if (i != 0) term.write(", ");
        term.write(p);
    }
    term.write("\n\n");
}

fn showPartitionScreen(c: cfg.Config) void {
    term.print("\n  Disk: {s}  ({d} MiB, {s})\n\n", .{ c.disk, c.disk_mib, if (c.uefi) "UEFI" else "BIOS" });
    term.write("     #  mount        fs        size\n");
    term.write("     -  ----------   -------   ----------\n");
    for (c.slices, 1..) |s, n| {
        term.print("     {d}  {s: <10}   {s: <7}   {d} MiB\n", .{ n, s.mount, s.fs.name(), s.size_mib });
    }
    term.write("\n");
}

fn schemeFor(c: cfg.Config) layout.Scheme {
    return switch (c.partition) {
        .mbr => .bios_mbr,
        .whole_gpt, .edit => if (c.uefi) .uefi_gpt else .bios_gpt,
    };
}

/// Lets the user pick a disk, then fits the layout to its real size.
fn chooseDisk(arena: std.mem.Allocator, buf: []u8, c: *cfg.Config) !void {
    const disks = try disk.list(arena);
    if (disks.len == 0) {
        term.write("  no disks found\n");
        return error.NoDisk;
    }
    term.write("\n  Available disks:\n\n");
    for (disks, 1..) |d, n| {
        term.print("     {d}) {s}  {d} MiB  {s}{s}\n", .{ n, d.path, d.mib, d.model, if (d.removable) "  (removable)" else "" });
    }
    term.write("\n");

    var pick: usize = 0;
    while (true) {
        const a = try ask(buf, "  Which disk? (number)", "1");
        const n = std.fmt.parseInt(usize, a, 10) catch 0;
        if (n >= 1 and n <= disks.len) {
            pick = n - 1;
            break;
        }
        term.write("  not a valid number\n");
    }
    c.disk = disks[pick].path;
    c.disk_sectors = disks[pick].sectors;
    c.disk_mib = disks[pick].mib;
    c.uefi = disk.isUefi();

    if (c.partition == .mbr and c.disk_sectors > 0xFFFFFFFF) {
        term.write("  MBR cannot address disks over 2 TiB; using GPT instead.\n");
        c.partition = .whole_gpt;
    }
    c.slices = layout.fitLayout(arena, c.disk_mib, schemeFor(c.*)) catch |e| switch (e) {
        error.DiskTooSmall => {
            term.print("  {s} is too small: PandaOS needs at least {d} MiB.\n", .{ c.disk, layout.hard_floor_mib });
            return error.DiskTooSmall;
        },
        else => return e,
    };
}

/// Minimal slice editor: change a slice's filesystem or size.
fn editLayout(buf: []u8, c: *cfg.Config) !void {
    const slices = @constCast(c.slices);
    term.write("  Commands:  fs <n> <ffs|btrfs>   size <n> <MiB>   done\n");
    while (true) {
        showPartitionScreen(c.*);
        term.write("  edit> ");
        const line = try readInput(buf);
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = it.next() orelse continue;
        if (std.mem.eql(u8, cmd, "done")) return;

        const n_s = it.next() orelse {
            term.write("  missing slice number\n");
            continue;
        };
        const n = std.fmt.parseInt(usize, n_s, 10) catch 0;
        if (n < 1 or n > slices.len) {
            term.write("  no such slice\n");
            continue;
        }
        const sl = &slices[n - 1];
        const arg = it.next() orelse "";

        if (std.mem.eql(u8, cmd, "fs")) {
            if (sl.fs == .vfat or sl.fs == .swap or sl.fs == .biosboot) {
                term.write("  that slice's filesystem is fixed\n");
            } else if (std.mem.eql(u8, arg, "ffs")) {
                sl.fs = .ffs;
            } else if (std.mem.eql(u8, arg, "btrfs")) {
                sl.fs = .btrfs;
            } else term.write("  choose ffs or btrfs\n");
        } else if (std.mem.eql(u8, cmd, "size")) {
            const mib = std.fmt.parseInt(u32, arg, 10) catch 0;
            if (mib < sl.min_mib) {
                term.print("  minimum for {s} is {d} MiB\n", .{ sl.mount, sl.min_mib });
                continue;
            }
            // /home absorbs the difference so the total stays constant.
            var home: ?*layout.Slice = null;
            for (slices) |*x| if (x.grow) {
                home = x;
            };
            const h = home orelse continue;
            if (h == sl) {
                term.write("  /home takes whatever is left; resize another slice\n");
                continue;
            }
            const delta: i64 = @as(i64, mib) - @as(i64, sl.size_mib);
            const new_home: i64 = @as(i64, h.size_mib) - delta;
            if (new_home < h.min_mib) {
                term.write("  not enough space left for /home\n");
                continue;
            }
            sl.size_mib = mib;
            h.size_mib = @intCast(new_home);
        } else term.write("  unknown command\n");
    }
}

// ---------------------------------------------------------------- the cascade

pub fn run(arena: std.mem.Allocator) !Result {
    var buf: [256]u8 = undefined;
    var res = Result{ .config = .{} };
    const c = &res.config;

    // 1. kernel
    term.write("\n1. ");
    term.write("(Keep in mind, linux-libre may not be compatible with your system.)\n   ");
    while (true) {
        const a = try ask(&buf, "What kernel would you prefer? (linux, linux-libre)", "linux-libre");
        if (std.mem.eql(u8, a, "linux")) {
            c.kernel = .linux;
            break;
        } else if (std.mem.eql(u8, a, "linux-libre")) {
            c.kernel = .linux_libre;
            break;
        }
        term.write("  please type 'linux' or 'linux-libre'\n   ");
    }

    // 2. xenodm
    term.write("\n2. ");
    c.use_xenodm = try askYesNo(&buf, "Would you like to use xenodm? (Y/n)", true);

    // 3. WM/DE (X path) or Wayland (fallback path)
    term.write("\n3. ");
    if (c.use_xenodm) {
        const wm = try askFromList(arena, &buf, "What WM/DE would you like to use?", &cfg.x_wms, "icewm");
        c.display = .{ .xorg = wm };
    } else {
        term.write("xenodm skipped.\n   ");
        if (try askYesNo(&buf, "Would you like to use Wayland instead? (y/N)", false)) {
            term.write("   ");
            const comp = try askFromList(arena, &buf, "Which Wayland compositor?", &cfg.wayland_compositors, "sway");
            c.display = .{ .wayland = comp };
        } else {
            c.display = .console;
            term.write("   Console-only install.\n");
        }
    }

    // 4. root user
    term.write("\n4. ");
    while (true) {
        const a = try ask(&buf, "Would you like to set up a root user? (lowercase-root-username/N)", "N");
        if (std.ascii.eqlIgnoreCase(a, "n")) {
            // Without a root user the system would have no usable login, so
            // root stays locked and a regular (doas-enabled) user is created.
            term.write("\n     No root user: root stays locked. Create a regular user instead.\n");
            while (true) {
                const u = try ask(&buf, "     username", "panda");
                if (cfg.validUsername(u)) {
                    c.user = try arena.dupe(u8, u);
                    break;
                }
                term.write("     invalid username\n");
            }
            term.write("\n     Password will not be shown for security reasons\n");
            try promptPassword(&res.user_password);
            break;
        }
        if (!cfg.validUsername(a)) {
            term.write("  invalid username (a-z, 0-9, _ and -, max 32, no leading digit)\n   ");
            continue;
        }
        c.root_user = try arena.dupe(u8, a);

        term.write("\n     Password will not be shown for security reasons\n");
        try promptPassword(&res.root_password);
        term.write("\nDISCLAIMER: root access is most vulnerable to password attacks\n");
        break;
    }

    // 5. hostname
    term.write("\n5. ");
    while (true) {
        const a = try ask(&buf, "what hostname would you like to use? (lowercase hostname/panda)", "panda");
        if (cfg.validHostname(a)) {
            c.hostname = try arena.dupe(u8, a);
            break;
        }
        term.write("  invalid hostname (a-z, 0-9, '-', max 63)\n   ");
    }

    // 6. partitioning
    term.write("\n6. What partitioning method would you like?\n\n     ");
    while (true) {
        const a = try ask(&buf, "[W]hole GPT, [M]BR, [E]dit", "W");
        if (std.ascii.eqlIgnoreCase(a, "w")) c.partition = .whole_gpt else if (std.ascii.eqlIgnoreCase(a, "m")) c.partition = .mbr else if (std.ascii.eqlIgnoreCase(a, "e")) c.partition = .edit else {
            term.write("     please choose w, m or e\n     ");
            continue;
        }
        break;
    }
    try chooseDisk(arena, &buf, c);
    if (c.partition == .edit) try editLayout(&buf, c);
    showPartitionScreen(c.*);

    // 7. packages
    term.write("7. Confirm these are the packages you want to install:\n");
    var pkgs: std.ArrayListUnmanaged([]const u8) = .empty;
    try pkgs.appendSlice(arena, try cfg.defaultPackages(arena, c.*));
    while (true) {
        printPackages(pkgs.items);
        const a = try ask(&buf, "     (y/Extra package names)", "y");
        if (std.mem.eql(u8, a, "y") or std.mem.eql(u8, a, "yes")) break;

        var it = std.mem.tokenizeAny(u8, a, " ,\t");
        while (it.next()) |name| {
            if (!cfg.validPackageName(name)) {
                term.print("     skipped invalid package name '{s}'\n", .{name});
            } else if (cfg.contains(pkgs.items, name)) {
                term.print("     '{s}' is already in the list\n", .{name});
            } else {
                try pkgs.append(arena, try arena.dupe(u8, name));
            }
        }
    }
    c.packages = pkgs.items;

    return res;
}
