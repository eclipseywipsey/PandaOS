//! Writes the base system configuration into the target: hostname, dinit
//! service tree, display manager / session config, and the default wallpaper.
//!
//! dinit is the default init; everything here is plain text so the user can
//! swap init systems after install.

const std = @import("std");
const cfg = @import("config.zig");
const target = @import("target.zig");

pub const wallpaper = "/usr/share/backgrounds/pandaos/default.png";

// ---------------------------------------------------------------- dinit

const early_fs_script =
    \\#!/bin/sh
    \\# Early filesystem setup. dinit itself lives on the root slice, so this
    \\# runs before /usr, /var etc. are available.
    \\mount -o remount,rw / || exit 1
    \\mount -a
    \\swapon -a 2>/dev/null
    \\exit 0
    \\
;

const hostname_script =
    \\#!/bin/sh
    \\hostname "$(cat /etc/hostname)"
    \\
;

const udev_settle_script =
    \\#!/bin/sh
    \\udevadm trigger --action=add
    \\udevadm settle
    \\
;

/// Service name -> file contents. Only services this config needs.
pub const Service = struct { name: []const u8, body: []const u8 };

pub fn dinitServices(a: std.mem.Allocator, c: cfg.Config) ![]Service {
    var list: std.ArrayListUnmanaged(Service) = .empty;

    try list.append(a, .{ .name = "early-fs", .body = "type = scripted\ncommand = /etc/dinit.d/scripts/early-fs\n" });
    try list.append(a, .{ .name = "hostname", .body = "type = scripted\ncommand = /etc/dinit.d/scripts/hostname\ndepends-on = early-fs\n" });
    try list.append(a, .{ .name = "udev", .body = "type = process\ncommand = /sbin/udevd\ndepends-on = early-fs\n" });
    try list.append(a, .{ .name = "udev-settle", .body = "type = scripted\ncommand = /etc/dinit.d/scripts/udev-settle\ndepends-on = udev\n" });
    try list.append(a, .{
        .name = "tty1",
        .body = "type = process\ncommand = /sbin/agetty --noclear tty1 linux\nrestart = true\ndepends-on = udev-settle\n",
    });

    var boot: std.ArrayListUnmanaged(u8) = .empty;
    try boot.appendSlice(a, "type = internal\ndepends-on = early-fs\ndepends-on = hostname\nwaits-for = udev-settle\nwaits-for = tty1\n");

    switch (c.display) {
        .xorg => if (c.use_xenodm) {
            try list.append(a, .{
                .name = "xenodm",
                .body = "type = process\ncommand = /usr/bin/xenodm -nodaemon\nrestart = true\ndepends-on = udev-settle\n",
            });
            try boot.appendSlice(a, "waits-for = xenodm\n");
        },
        else => {},
    }
    // Optional features (ramdisk, i2p) are added by `panda-settings`, not here.
    try boot.appendSlice(a, "waits-for.d = /etc/dinit.d/boot.d\n");
    try list.append(a, .{ .name = "boot", .body = try boot.toOwnedSlice(a) });
    return list.toOwnedSlice(a);
}

// ---------------------------------------------------------------- display configs

pub fn xsession(a: std.mem.Allocator, wm: []const u8) ![]u8 {
    // icewm ships a session wrapper that starts the panel and settings daemons.
    const exe: []const u8 = if (std.mem.eql(u8, wm, "icewm")) "icewm-session" else wm;
    return std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\# Per-session hooks from panda-settings (e.g. low contrast)
        \\for f in /etc/panda/session.d/*.sh; do [ -r "$f" ] && . "$f"; done
        \\exec {s}
        \\
    , .{exe});
}

const xsetup =
    \\#!/bin/sh
    \\# xenodm login screen background
    \\[ -x /usr/bin/feh ] && feh --bg-fill /usr/share/backgrounds/pandaos/default.png
    \\for f in /etc/panda/session.d/*.sh; do [ -r "$f" ] && . "$f"; done
    \\
;

const icewm_prefs =
    \\# PandaOS defaults
    \\DesktopBackgroundImage="/usr/share/backgrounds/pandaos/default.png"
    \\DesktopBackgroundScaled=1
    \\DesktopBackgroundCenter=0
    \\
;

const sway_bg = "output * bg /usr/share/backgrounds/pandaos/default.png fill\n";
const hyprpaper_conf =
    \\preload = /usr/share/backgrounds/pandaos/default.png
    \\wallpaper = , /usr/share/backgrounds/pandaos/default.png
    \\
;

// ---------------------------------------------------------------- stage

pub fn install(a: std.mem.Allocator, root: []const u8, c: cfg.Config) !void {
    // identity
    const host = try std.fmt.allocPrint(a, "{s}\n", .{c.hostname});
    try target.writeFile(a, root, "etc/hostname", host, 0o644);
    const hosts = try std.fmt.allocPrint(a, "127.0.0.1 localhost {s}\n::1 localhost {s}\n", .{ c.hostname, c.hostname });
    try target.writeFile(a, root, "etc/hosts", hosts, 0o644);

    // dinit
    try target.writeFile(a, root, "etc/dinit.d/scripts/early-fs", early_fs_script, 0o755);
    try target.writeFile(a, root, "etc/dinit.d/scripts/hostname", hostname_script, 0o755);
    try target.writeFile(a, root, "etc/dinit.d/scripts/udev-settle", udev_settle_script, 0o755);
    try target.makeDir(a, root, "etc/dinit.d/boot.d");
    for (try dinitServices(a, c)) |s| {
        const path = try std.fmt.allocPrint(a, "etc/dinit.d/{s}", .{s.name});
        try target.writeFile(a, root, path, s.body, 0o644);
    }

    // feature state file read by panda-settings (all off by default)
    try target.writeFile(a, root, "etc/panda/features.conf", "ramdisk=off\nlowcontrast=off\ngpggrid=off\ni2p=off\n", 0o644);

    // display + wallpaper
    switch (c.display) {
        .console => {},
        .xorg => |wm| {
            try target.writeFile(a, root, "etc/skel/.xsession", try xsession(a, wm), 0o755);
            if (c.use_xenodm) try target.writeFile(a, root, "etc/X11/xenodm/Xsetup_0", xsetup, 0o755);
            if (std.mem.eql(u8, wm, "icewm")) try target.writeFile(a, root, "etc/icewm/preferences", icewm_prefs, 0o644);
        },
        .wayland => |comp| {
            if (std.mem.eql(u8, comp, "sway")) try target.writeFile(a, root, "etc/sway/config.d/00-pandaos-wallpaper", sway_bg, 0o644);
            if (std.mem.eql(u8, comp, "hyprland")) try target.writeFile(a, root, "etc/xdg/hypr/hyprpaper.conf", hyprpaper_conf, 0o644);
        },
    }

    // Copy the skeleton session file for a regular user, if one exists.
    if (c.user) |u| {
        if (c.display == .xorg) {
            const dest = try std.fmt.allocPrint(a, "home/{s}/.xsession", .{u});
            try target.writeFile(a, root, dest, try xsession(a, c.display.xorg), 0o755);
        }
    }
}

// ---------------------------------------------------------------- tests

test "dinit boot service waits for xenodm only when selected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const with = try dinitServices(a, .{ .display = .{ .xorg = "icewm" }, .use_xenodm = true });
    var found = false;
    for (with) |s| {
        if (std.mem.eql(u8, s.name, "boot")) found = std.mem.indexOf(u8, s.body, "waits-for = xenodm") != null;
    }
    try std.testing.expect(found);

    const without = try dinitServices(a, .{ .display = .console, .use_xenodm = false });
    for (without) |s| try std.testing.expect(!std.mem.eql(u8, s.name, "xenodm"));
}

test "xsession wraps icewm" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try xsession(arena.allocator(), "icewm");
    try std.testing.expect(std.mem.indexOf(u8, s, "exec icewm-session") != null);
}
