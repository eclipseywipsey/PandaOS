//! PandaOS install configuration: the data model the installer questions
//! fill in, validators, default partition layouts, and plan rendering.

const std = @import("std");
const layout = @import("layout.zig");

pub const Kernel = enum {
    linux,
    linux_libre,

    pub fn name(self: Kernel) []const u8 {
        return switch (self) {
            .linux => "linux",
            .linux_libre => "linux-libre",
        };
    }
};

pub const Display = union(enum) {
    console,
    xorg: []const u8, // window manager / desktop, started by xenodm
    wayland: []const u8, // compositor
};

pub const PartitionMethod = enum { whole_gpt, mbr, edit };

/// Choices offered by the installer. Edit these lists to change what
/// the questions accept.
pub const x_wms = [_][]const u8{ "icewm", "cwm", "fvwm", "openbox" };
pub const wayland_compositors = [_][]const u8{ "sway", "hyprland" };

pub const Config = struct {
    kernel: Kernel = .linux_libre,
    use_xenodm: bool = true,
    display: Display = .console,
    root_user: ?[]const u8 = null,
    /// Regular user, created only when no root user was requested.
    user: ?[]const u8 = null,
    hostname: []const u8 = "panda",
    partition: PartitionMethod = .whole_gpt,
    packages: []const []const u8 = &.{},
    /// Target disk (e.g. /dev/sda), its size, and the fitted slice table.
    disk: []const u8 = "",
    disk_sectors: u64 = 0,
    disk_mib: u64 = 0,
    slices: []const layout.Slice = &.{},
    /// Install target: UEFI (GPT + ESP) or legacy BIOS.
    uefi: bool = true,
};

pub fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |e| if (std.mem.eql(u8, e, item)) return true;
    return false;
}

// ---------------------------------------------------------------- validators

pub fn validHostname(s: []const u8) bool {
    if (s.len == 0 or s.len > 63) return false;
    if (s[0] == '-' or s[s.len - 1] == '-') return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

pub fn validUsername(s: []const u8) bool {
    if (s.len == 0 or s.len > 32) return false;
    if (!((s[0] >= 'a' and s[0] <= 'z') or s[0] == '_')) return false;
    for (s[1..]) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

pub fn validPackageName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    if (!(std.ascii.isAlphanumeric(s[0]))) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or
            c == '.' or c == '_' or c == '+' or c == '-';
        if (!ok) return false;
    }
    return true;
}

// ---------------------------------------------------------------- packages

/// Default package set for the chosen display setup (question 7's list).
pub fn defaultPackages(a: std.mem.Allocator, c: Config) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    switch (c.display) {
        .console => {},
        .xorg => |wm| {
            try list.appendSlice(a, &.{ "xbase", "xshare", "xfont", "xserv" });
            try list.append(a, wm);
            try list.appendSlice(a, &.{ "xinit", "xorg-server" });
            if (c.use_xenodm) try list.append(a, "xdm");
        },
        .wayland => |comp| {
            try list.appendSlice(a, &.{ "wayland", "seatd" });
            try list.append(a, comp);
        },
    }
    return list.toOwnedSlice(a);
}

// ---------------------------------------------------------------- plan

/// Renders a key=value plan file. Later install stages (partition, mkfs,
/// extract, bootloader) read this. The root password is NEVER written.
pub fn renderPlan(a: std.mem.Allocator, c: Config) ![]u8 {
    const pkgs = try std.mem.join(a, " ", c.packages);
    const disp: []const u8 = switch (c.display) {
        .console => "console",
        .xorg => |wm| try std.fmt.allocPrint(a, "xorg wm={s} xenodm={s}", .{ wm, if (c.use_xenodm) "yes" else "no" }),
        .wayland => |comp| try std.fmt.allocPrint(a, "wayland compositor={s}", .{comp}),
    };
    const method = switch (c.partition) {
        .whole_gpt => "whole-gpt",
        .mbr => "mbr",
        .edit => "edit",
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    const head = try std.fmt.allocPrint(
        a,
        "kernel={s}\ninit=dinit\ndisplay={s}\nroot_user={s}\nhostname={s}\npartition={s}\npackages={s}\n",
        .{ c.kernel.name(), disp, c.root_user orelse "none", c.hostname, method, pkgs },
    );
    try out.appendSlice(a, head);
    const dl = try std.fmt.allocPrint(a, "disk={s}\nuefi={s}\n", .{ c.disk, if (c.uefi) "yes" else "no" });
    try out.appendSlice(a, dl);
    for (c.slices) |s| {
        const line = try std.fmt.allocPrint(a, "slice={s} {s} {d}M\n", .{ s.mount, s.fs.name(), s.size_mib });
        try out.appendSlice(a, line);
    }
    return out.toOwnedSlice(a);
}

// ---------------------------------------------------------------- tests

test "hostname validation" {
    try std.testing.expect(validHostname("panda"));
    try std.testing.expect(validHostname("my-box-2"));
    try std.testing.expect(!validHostname(""));
    try std.testing.expect(!validHostname("-bad"));
    try std.testing.expect(!validHostname("Bad"));
    try std.testing.expect(!validHostname("has space"));
}

test "username validation" {
    try std.testing.expect(validUsername("example_username"));
    try std.testing.expect(!validUsername("1abc"));
    try std.testing.expect(!validUsername("UPPER"));
    try std.testing.expect(!validUsername(""));
}

test "package name validation" {
    try std.testing.expect(validPackageName("librewolf"));
    try std.testing.expect(validPackageName("gtk+3"));
    try std.testing.expect(!validPackageName("-x"));
    try std.testing.expect(!validPackageName("a b"));
}

test "default x package set matches spec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pk = try defaultPackages(arena.allocator(), .{ .display = .{ .xorg = "icewm" } });
    const joined = try std.mem.join(arena.allocator(), " ", pk);
    try std.testing.expectEqualStrings(
        "xbase xshare xfont xserv icewm xinit xorg-server xdm",
        joined,
    );
}
