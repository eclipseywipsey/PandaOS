//! panda-settings: "Advanced security features" menu.
//!
//! Every change requires the root account's password, verified against
//! /etc/shadow, so enabling a feature is a deliberate act. The tool must run
//! as root (it re-executes itself through doas otherwise) because it reads
//! /etc/shadow and writes system config.

const std = @import("std");
const term = @import("term.zig");
const exec = @import("exec.zig");
const crypt = @import("crypt.zig");
const features = @import("features.zig");

const max_attempts = 3;

/// Name of the uid-0 account (it may have been renamed at install time).
fn rootAccountName(a: std.mem.Allocator, passwd: []const u8) ?[]const u8 {
    _ = a;
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const name = f.next() orelse continue;
        _ = f.next(); // password placeholder
        const uid = f.next() orelse continue;
        if (std.mem.eql(u8, uid, "0")) return name;
    }
    return null;
}

fn shadowHash(shadow: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, shadow, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const n = f.next() orelse continue;
        if (!std.mem.eql(u8, n, name)) continue;
        return f.next();
    }
    return null;
}

/// Prompts for the root password; returns true when it is correct.
fn authenticate(a: std.mem.Allocator) bool {
    const passwd = std.fs.cwd().readFileAlloc(a, "/etc/passwd", 1024 * 1024) catch return false;
    const shadow = std.fs.cwd().readFileAlloc(a, "/etc/shadow", 1024 * 1024) catch {
        term.write("cannot read /etc/shadow (run as root)\n");
        return false;
    };
    const name = rootAccountName(a, passwd) orelse return false;
    const hash = shadowHash(shadow, name) orelse return false;
    if (hash.len < 4 or hash[0] != '$') {
        term.print("the {s} account has no usable password\n", .{name});
        return false;
    }

    var attempt: u8 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        var buf: [128]u8 = undefined;
        term.print("Password for {s}: ", .{name});
        const pw = term.readPassword(&buf) catch return false;
        const ok = crypt.verify(a, pw, hash);
        std.crypto.secureZero(u8, buf[0..]);
        if (ok) return true;
        term.write("Incorrect password.\n");
        std.time.sleep(2 * std.time.ns_per_s); // slow down guessing
    }
    return false;
}

fn showMenu(a: std.mem.Allocator) void {
    term.write("\nAdvanced security features:\n\n");
    for (std.enums.values(features.Feature), 1..) |f, n| {
        const on = features.isOn(a, "/", f);
        term.print("  {d}) [{s}] {s}\n", .{ n, if (on) "on " else "off", f.title() });
    }
    term.write("\n  Enter a number to toggle, or q to quit: ");
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    if (std.os.linux.geteuid() != 0) {
        // Re-run ourselves as root through doas.
        const self = try std.fs.selfExePathAlloc(a);
        try exec.run(a, &.{ "doas", self });
        return;
    }

    var authed = false;
    var buf: [32]u8 = undefined;
    const all = std.enums.values(features.Feature);

    while (true) {
        showMenu(a);
        const line = term.readLine(&buf) catch return;
        if (line.len == 0) continue;
        if (line[0] == 'q' or line[0] == 'Q') return;

        const n = std.fmt.parseInt(usize, line, 10) catch 0;
        if (n < 1 or n > all.len) {
            term.write("  not a valid choice\n");
            continue;
        }
        const f = all[n - 1];

        if (!authed) {
            if (!authenticate(a)) {
                term.write("Authentication failed. No changes made.\n");
                continue;
            }
            authed = true;
        }

        const turning_on = !features.isOn(a, "/", f);
        const result = if (turning_on) features.enable(a, "/", f) else features.disable(a, "/", f);
        result catch |e| {
            term.print("  could not change this feature: {s}\n", .{@errorName(e)});
            continue;
        };
        term.print("  {s}: {s}\n", .{ f.key(), if (turning_on) "enabled" else "disabled" });
        if (f == .lowcontrast) term.write("  (takes effect at next login)\n");
    }
}

test "finds the uid-0 account under any name" {
    const passwd = "daemon:x:1:1::/:/bin/false\nalice:x:0:0:admin:/root:/bin/sh\n";
    try std.testing.expectEqualStrings("alice", rootAccountName(std.testing.allocator, passwd).?);
}

test "shadow lookup" {
    const shadow = "root:!:0::::::\nalice:$6$x$y:19000:0:99999:7:::\n";
    try std.testing.expectEqualStrings("$6$x$y", shadowHash(shadow, "alice").?);
    try std.testing.expect(shadowHash(shadow, "bob") == null);
}
