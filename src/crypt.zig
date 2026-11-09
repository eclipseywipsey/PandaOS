//! Password hashing/verification via libc crypt(3), SHA-512 scheme ($6$).
//! musl provides crypt() in libc; on glibc builds libcrypt is linked
//! (see build.zig). The hashes match what /etc/shadow expects.

const std = @import("std");

extern "c" fn crypt(key: [*:0]const u8, setting: [*:0]const u8) ?[*:0]const u8;

pub const CryptError = error{CryptFailed} || std.mem.Allocator.Error;

const salt_chars = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const rounds = 200_000;

/// Returns an owned "$6$rounds=N$salt$hash" string.
pub fn hashPassword(a: std.mem.Allocator, password: []const u8) CryptError![]u8 {
    var raw: [16]u8 = undefined;
    std.crypto.random.bytes(&raw);
    var salt: [16]u8 = undefined;
    for (raw, 0..) |b, i| salt[i] = salt_chars[b % salt_chars.len];

    const plain = try std.fmt.allocPrint(a, "$6$rounds={d}${s}$", .{ rounds, salt });
    defer a.free(plain);
    const setting = try a.dupeZ(u8, plain);
    defer a.free(setting);
    return run(a, password, setting);
}

fn run(a: std.mem.Allocator, password: []const u8, setting: [:0]const u8) CryptError![]u8 {
    const key = try a.allocSentinel(u8, password.len, 0);
    defer {
        std.crypto.secureZero(u8, key);
        a.free(key);
    }
    @memcpy(key, password);

    const out = crypt(key.ptr, setting.ptr) orelse return error.CryptFailed;
    const s = std.mem.span(out);
    if (s.len < 20 or s[0] != '$') return error.CryptFailed; // "*0" / "*1" are failure markers
    return a.dupe(u8, s);
}

/// Constant-time check of `password` against an existing hash.
pub fn verify(a: std.mem.Allocator, password: []const u8, hash: []const u8) bool {
    const setting = a.dupeZ(u8, hash) catch return false;
    defer a.free(setting);
    const got = run(a, password, setting) catch return false;
    defer a.free(got);
    if (got.len != hash.len) return false;
    var diff: u8 = 0;
    for (got, hash) |x, y| diff |= x ^ y;
    return diff == 0;
}

test "hash then verify" {
    const a = std.testing.allocator;
    const h = try hashPassword(a, "correct horse battery");
    defer a.free(h);
    try std.testing.expect(std.mem.startsWith(u8, h, "$6$"));
    try std.testing.expect(verify(a, "correct horse battery", h));
    try std.testing.expect(!verify(a, "wrong password", h));
}
