//! "Advanced security features": the four toggles behind panda-settings.
//!
//! State lives in <root>/etc/panda/features.conf as key=on|off. Enabling a
//! feature installs config/service files; disabling removes them. Everything
//! takes a `root` path so it can be tested against a scratch directory.

const std = @import("std");
const target = @import("target.zig");
const exec = @import("exec.zig");
const term = @import("term.zig");

pub const Feature = enum {
    ramdisk,
    lowcontrast,
    gpggrid,
    i2p,

    pub fn key(self: Feature) []const u8 {
        return @tagName(self);
    }

    pub fn title(self: Feature) []const u8 {
        return switch (self) {
            .ramdisk => "Encrypted RAM disk for temporary files (destroyed on shutdown)",
            .lowcontrast => "Ultra-low contrast display (foils shoulder surfers)",
            .gpggrid => "gpg-grid (attempts to foil keystroke loggers)",
            .i2p => "I2P proxy for internet traffic",
        };
    }
};

pub const features_conf = "etc/panda/features.conf";

pub const FeatureError = error{ NotImplemented, MissingTool } || target.Error || exec.ExecError;

// ---------------------------------------------------------------- state file

/// Returns `text` with `key` set to `val` (appended if absent). Owned copy.
pub fn setKey(a: std.mem.Allocator, text: []const u8, k: []const u8, val: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var found = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line.len > k.len and std.mem.startsWith(u8, line, k) and line[k.len] == '=') {
            try out.writer(a).print("{s}={s}\n", .{ k, val });
            found = true;
        } else {
            try out.appendSlice(a, line);
            try out.append(a, '\n');
        }
    }
    if (!found) try out.writer(a).print("{s}={s}\n", .{ k, val });
    return out.toOwnedSlice(a);
}

pub fn getKey(text: []const u8, k: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > k.len and std.mem.startsWith(u8, line, k) and line[k.len] == '=') {
            return std.mem.trim(u8, line[k.len + 1 ..], " \t\r");
        }
    }
    return null;
}

pub fn isOn(a: std.mem.Allocator, root: []const u8, f: Feature) bool {
    const text = target.readFile(a, root, features_conf) catch return false;
    defer a.free(text);
    const v = getKey(text, f.key()) orelse return false;
    return std.mem.eql(u8, v, "on");
}

fn setState(a: std.mem.Allocator, root: []const u8, f: Feature, on: bool) !void {
    const old = try target.readFile(a, root, features_conf);
    defer a.free(old);
    const new = try setKey(a, old, f.key(), if (on) "on" else "off");
    defer a.free(new);
    try target.writeFile(a, root, features_conf, new, 0o644);
}

// ---------------------------------------------------------------- file contents

pub const ramdisk_start =
    \\#!/bin/sh
    \\# Encrypted RAM disk mounted over /tmp. The key is random, lives only in
    \\# this process' memory, and is never written anywhere: once the mapping
    \\# is closed the data is unrecoverable.
    \\set -e
    \\modprobe brd rd_nr=1 rd_size=1048576   # 1 GiB
    \\head -c 64 /dev/urandom | cryptsetup open --type plain \
    \\    --cipher aes-xts-plain64 --key-size 512 --hash plain \
    \\    --key-file=- /dev/ram0 pandatmp
    \\mkfs.btrfs -q -f /dev/mapper/pandatmp
    \\mount -o nodev,nosuid /dev/mapper/pandatmp /tmp
    \\chmod 1777 /tmp
    \\
;

pub const ramdisk_stop =
    \\#!/bin/sh
    \\umount /tmp 2>/dev/null
    \\cryptsetup close pandatmp 2>/dev/null
    \\dd if=/dev/zero of=/dev/ram0 bs=1M 2>/dev/null
    \\rmmod brd 2>/dev/null
    \\exit 0
    \\
;

pub const ramdisk_service =
    \\type = scripted
    \\command = /etc/dinit.d/scripts/ramdisk-start
    \\stop-command = /etc/dinit.d/scripts/ramdisk-stop
    \\depends-on = early-fs
    \\
;

pub const lowcontrast_session =
    \\# PandaOS ultra-low contrast: dim every output so the screen is hard to
    \\# read from a distance. Applies to X sessions.
    \\for out in $(xrandr 2>/dev/null | awk '/ connected/ {print $1}'); do
    \\    xrandr --output "$out" --brightness 0.30 --gamma 0.7:0.7:0.7
    \\done
    \\
;

pub const i2pd_service =
    \\type = process
    \\command = /usr/bin/i2pd --conf=/etc/i2pd/i2pd.conf --datadir=/var/lib/i2pd
    \\restart = true
    \\depends-on = early-fs
    \\
;

/// HTTP proxy 4444 and SOCKS 4447 are i2pd's defaults.
pub const i2p_profile =
    \\# PandaOS: route command-line tools through the local i2pd proxy.
    \\export http_proxy=http://127.0.0.1:4444
    \\export https_proxy=http://127.0.0.1:4444
    \\export all_proxy=socks5h://127.0.0.1:4447
    \\export no_proxy=localhost,127.0.0.1
    \\
;

/// LibreWolf enterprise policy: point the browser at i2pd.
pub const librewolf_policy =
    \\{
    \\  "policies": {
    \\    "Proxy": {
    \\      "Mode": "manual",
    \\      "HTTPProxy": "127.0.0.1:4444",
    \\      "SSLProxy": "127.0.0.1:4444",
    \\      "SOCKSProxy": "127.0.0.1:4447",
    \\      "SOCKSVersion": 5,
    \\      "Passthrough": "localhost,127.0.0.1",
    \\      "Locked": false
    \\    }
    \\  }
    \\}
    \\
;

const librewolf_policy_path = "usr/lib/librewolf/distribution/policies.json";

// ---------------------------------------------------------------- helpers

fn requireTool(a: std.mem.Allocator, name: []const u8) FeatureError!void {
    if (exec.dry_run) return;
    if (!exec.have(a, name)) {
        term.print("  missing required tool: {s}\n", .{name});
        return error.MissingTool;
    }
}

fn removeFile(a: std.mem.Allocator, root: []const u8, rel: []const u8) void {
    if (exec.dry_run) {
        term.print("  [dry-run] remove {s}\n", .{rel});
        return;
    }
    const full = std.fs.path.join(a, &.{ root, rel }) catch return;
    defer a.free(full);
    std.fs.cwd().deleteFile(full) catch {};
}

fn linkIntoBoot(a: std.mem.Allocator, root: []const u8, service: []const u8) !void {
    if (exec.dry_run) {
        term.print("  [dry-run] symlink boot.d/{s}\n", .{service});
        return;
    }
    try target.makeDir(a, root, "etc/dinit.d/boot.d");
    const link = try std.fmt.allocPrint(a, "{s}/etc/dinit.d/boot.d/{s}", .{ root, service });
    defer a.free(link);
    const dest = try std.fmt.allocPrint(a, "../{s}", .{service});
    defer a.free(dest);
    std.fs.cwd().deleteFile(link) catch {};
    try std.fs.cwd().symLink(dest, link, .{});
}

fn dinitctl(a: std.mem.Allocator, root: []const u8, verb: []const u8, service: []const u8) void {
    // Only talk to the live init when operating on the running system.
    if (!std.mem.eql(u8, root, "/")) return;
    exec.run(a, &.{ "dinitctl", verb, service }) catch {};
}

// ---------------------------------------------------------------- enable / disable

pub fn enable(a: std.mem.Allocator, root: []const u8, f: Feature) !void {
    switch (f) {
        .ramdisk => {
            try requireTool(a, "cryptsetup");
            try requireTool(a, "mkfs.btrfs");
            try target.writeFile(a, root, "etc/dinit.d/scripts/ramdisk-start", ramdisk_start, 0o755);
            try target.writeFile(a, root, "etc/dinit.d/scripts/ramdisk-stop", ramdisk_stop, 0o755);
            try target.writeFile(a, root, "etc/dinit.d/panda-ramdisk", ramdisk_service, 0o644);
            try linkIntoBoot(a, root, "panda-ramdisk");
            dinitctl(a, root, "start", "panda-ramdisk");
        },
        .lowcontrast => {
            try target.writeFile(a, root, "etc/panda/session.d/10-lowcontrast.sh", lowcontrast_session, 0o644);
        },
        .gpggrid => {
            // The grid input method itself is not written yet. Recording "on"
            // would claim protection that does not exist, so refuse.
            term.write("  gpg-grid is not implemented yet: nothing was enabled.\n");
            return error.NotImplemented;
        },
        .i2p => {
            try requireTool(a, "i2pd");
            try target.writeFile(a, root, "etc/dinit.d/i2pd", i2pd_service, 0o644);
            try linkIntoBoot(a, root, "i2pd");
            try target.writeFile(a, root, "etc/profile.d/panda-i2p.sh", i2p_profile, 0o644);
            try target.writeFile(a, root, librewolf_policy_path, librewolf_policy, 0o644);
            dinitctl(a, root, "start", "i2pd");
        },
    }
    try setState(a, root, f, true);
}

pub fn disable(a: std.mem.Allocator, root: []const u8, f: Feature) !void {
    switch (f) {
        .ramdisk => {
            dinitctl(a, root, "stop", "panda-ramdisk");
            removeFile(a, root, "etc/dinit.d/boot.d/panda-ramdisk");
            removeFile(a, root, "etc/dinit.d/panda-ramdisk");
            removeFile(a, root, "etc/dinit.d/scripts/ramdisk-start");
            removeFile(a, root, "etc/dinit.d/scripts/ramdisk-stop");
        },
        .lowcontrast => {
            removeFile(a, root, "etc/panda/session.d/10-lowcontrast.sh");
        },
        .gpggrid => {},
        .i2p => {
            dinitctl(a, root, "stop", "i2pd");
            removeFile(a, root, "etc/dinit.d/boot.d/i2pd");
            removeFile(a, root, "etc/dinit.d/i2pd");
            removeFile(a, root, "etc/profile.d/panda-i2p.sh");
            removeFile(a, root, librewolf_policy_path);
        },
    }
    try setState(a, root, f, false);
}

// ---------------------------------------------------------------- tests

test "setKey replaces or appends" {
    const a = std.testing.allocator;
    const t1 = try setKey(a, "ramdisk=off\ni2p=off\n", "i2p", "on");
    defer a.free(t1);
    try std.testing.expectEqualStrings("ramdisk=off\ni2p=on\n", t1);
    const t2 = try setKey(a, "ramdisk=off\n", "gpggrid", "off");
    defer a.free(t2);
    try std.testing.expectEqualStrings("ramdisk=off\ngpggrid=off\n", t2);
}

test "getKey" {
    try std.testing.expectEqualStrings("on", getKey("a=off\nb=on\n", "b").?);
    try std.testing.expect(getKey("a=off\n", "zzz") == null);
}

test "lowcontrast toggles a session script and state in a scratch root" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    try enable(a, root, .lowcontrast);
    try std.testing.expect(isOn(a, root, .lowcontrast));
    const script = try target.readFile(a, root, "etc/panda/session.d/10-lowcontrast.sh");
    defer a.free(script);
    try std.testing.expect(script.len > 0);

    try disable(a, root, .lowcontrast);
    try std.testing.expect(!isOn(a, root, .lowcontrast));
    const gone = try target.readFile(a, root, "etc/panda/session.d/10-lowcontrast.sh");
    defer a.free(gone);
    try std.testing.expectEqual(@as(usize, 0), gone.len);
}

test "gpg-grid refuses to claim protection" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NotImplemented, enable(a, "/nonexistent-root", .gpggrid));
}
