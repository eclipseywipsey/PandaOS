//! Account setup inside the install target: passwd/shadow/group edits.
//! Text transforms are pure functions so they can be unit tested.

const std = @import("std");
const cfg = @import("config.zig");
const crypt = @import("crypt.zig");
const target = @import("target.zig");
const exec = @import("exec.zig");
const term = @import("term.zig");

const default_passwd = "root:x:0:0:root:/root:/bin/sh\n";
const default_shadow = "root:!:0:0:99999:7:::\n";
const default_group = "root:x:0:\nwheel:x:10:root\n";

// ---------------------------------------------------------------- pure edits

/// Replaces colon-separated field `idx` on the line for `name`. Lines for
/// other names are untouched. Returns an owned copy.
pub fn setField(a: std.mem.Allocator, text: []const u8, name: []const u8, idx: usize, value: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const prefix_ok = line.len > name.len and std.mem.startsWith(u8, line, name) and line[name.len] == ':';
        if (!prefix_ok) {
            try out.appendSlice(a, line);
            try out.append(a, '\n');
            continue;
        }
        var fields = std.mem.splitScalar(u8, line, ':');
        var i: usize = 0;
        while (fields.next()) |f| : (i += 1) {
            if (i != 0) try out.append(a, ':');
            try out.appendSlice(a, if (i == idx) value else f);
        }
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

/// Renames the entry `old` to `new` (first field).
pub fn rename(a: std.mem.Allocator, text: []const u8, old: []const u8, new: []const u8) ![]u8 {
    return setField(a, text, old, 0, new);
}

/// Adds `user` to the member list (field 3) of `group`.
pub fn addToGroup(a: std.mem.Allocator, text: []const u8, group: []const u8, user: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const hit = line.len > group.len and std.mem.startsWith(u8, line, group) and line[group.len] == ':';
        try out.appendSlice(a, line);
        if (hit) {
            const members_empty = line[line.len - 1] == ':';
            if (!members_empty) try out.append(a, ',');
            try out.appendSlice(a, user);
        }
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

fn lastChangedDays() i64 {
    return @divTrunc(std.time.timestamp(), 86400);
}

// ---------------------------------------------------------------- stage

pub fn install(
    a: std.mem.Allocator,
    root: []const u8,
    c: cfg.Config,
    root_pw: []const u8,
    user_pw: []const u8,
) !void {
    var passwd = try target.readFile(a, root, "etc/passwd");
    if (passwd.len == 0) passwd = try a.dupe(u8, default_passwd);
    var shadow = try target.readFile(a, root, "etc/shadow");
    if (shadow.len == 0) shadow = try a.dupe(u8, default_shadow);
    var group = try target.readFile(a, root, "etc/group");
    if (group.len == 0) group = try a.dupe(u8, default_group);

    if (c.root_user) |name| {
        // The uid-0 account is renamed to the chosen username.
        passwd = try rename(a, passwd, "root", name);
        shadow = try rename(a, shadow, "root", name);
        group = try rename(a, group, "root", name);
        const hash = try crypt.hashPassword(a, root_pw);
        const days = try std.fmt.allocPrint(a, "{d}", .{lastChangedDays()});
        shadow = try setField(a, shadow, name, 1, hash);
        shadow = try setField(a, shadow, name, 2, days);
        term.print("  root account renamed to '{s}'\n", .{name});
    } else if (c.user) |name| {
        // root stays locked ('!'); a regular user in group wheel gets doas.
        shadow = try setField(a, shadow, "root", 1, "!");
        const hash = try crypt.hashPassword(a, user_pw);
        const line = try std.fmt.allocPrint(a, "{s}:x:1000:1000:{s}:/home/{s}:/bin/sh\n", .{ name, name, name });
        passwd = try std.mem.concat(a, u8, &.{ passwd, line });
        group = try std.mem.concat(a, u8, &.{ group, try std.fmt.allocPrint(a, "{s}:x:1000:\n", .{name}) });
        group = try addToGroup(a, group, "wheel", name);
        shadow = try std.mem.concat(a, u8, &.{
            shadow,
            try std.fmt.allocPrint(a, "{s}:{s}:{d}:0:99999:7:::\n", .{ name, hash, lastChangedDays() }),
        });
        try target.writeFile(a, root, "etc/doas.conf", "permit persist :wheel\n", 0o600);

        const home = try std.fmt.allocPrint(a, "home/{s}", .{name});
        try target.makeDir(a, root, home);
        const home_abs = try std.fmt.allocPrint(a, "/home/{s}", .{name});
        exec.runIn(a, root, &.{ "chown", "1000:1000", home_abs }) catch {};
        exec.runIn(a, root, &.{ "chmod", "700", home_abs }) catch {};
    }

    try target.writeFile(a, root, "etc/passwd", passwd, 0o644);
    try target.writeFile(a, root, "etc/shadow", shadow, 0o600);
    try target.writeFile(a, root, "etc/group", group, 0o644);
}

// ---------------------------------------------------------------- tests

test "rename root and set hash field" {
    const a = std.testing.allocator;
    const r = try rename(a, default_passwd, "root", "alice");
    defer a.free(r);
    try std.testing.expectEqualStrings("alice:x:0:0:root:/root:/bin/sh\n", r);

    const s = try setField(a, default_shadow, "root", 1, "$6$x$y");
    defer a.free(s);
    try std.testing.expect(std.mem.startsWith(u8, s, "root:$6$x$y:"));
}

test "addToGroup appends with and without existing members" {
    const a = std.testing.allocator;
    const g1 = try addToGroup(a, "wheel:x:10:\n", "wheel", "bob");
    defer a.free(g1);
    try std.testing.expectEqualStrings("wheel:x:10:bob\n", g1);
    const g2 = try addToGroup(a, "wheel:x:10:root\n", "wheel", "bob");
    defer a.free(g2);
    try std.testing.expectEqualStrings("wheel:x:10:root,bob\n", g2);
}

test "setField does not touch similarly named entries" {
    const a = std.testing.allocator;
    const r = try setField(a, "rootkit:x:1:1:::\nroot:x:0:0:::\n", "root", 0, "r2");
    defer a.free(r);
    try std.testing.expectEqualStrings("rootkit:x:1:1:::\nr2:x:0:0:::\n", r);
}
