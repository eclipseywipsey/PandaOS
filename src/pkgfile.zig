//! CRUX-style Pkgfile parsing, source handling and checksum verification.
//!
//! A port is a directory:
//!   /usr/ports/<name>/Pkgfile        metadata + build() function (shell)
//!   /usr/ports/<name>/.sha256sum     "<hex>  <filename>" per source file
//!
//! Only the declarative fields are parsed here; build() is executed by sh.

const std = @import("std");

pub const Pkgfile = struct {
    name: []const u8,
    version: []const u8,
    release: []const u8,
    /// Raw `source=(...)` tokens, before $name/$version expansion.
    sources: []const []const u8,
};

pub const ParseError = error{ MissingName, MissingVersion, MissingRelease, UnterminatedSource } || std.mem.Allocator.Error;

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
        return s[1 .. s.len - 1];
    }
    return s;
}

pub fn parse(a: std.mem.Allocator, text: []const u8) ParseError!Pkgfile {
    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var release: ?[]const u8 = null;
    var sources: std.ArrayListUnmanaged([]const u8) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "build()")) break;

        if (std.mem.startsWith(u8, line, "name=")) {
            name = try a.dupe(u8, unquote(line[5..]));
        } else if (std.mem.startsWith(u8, line, "version=")) {
            version = try a.dupe(u8, unquote(line[8..]));
        } else if (std.mem.startsWith(u8, line, "release=")) {
            release = try a.dupe(u8, unquote(line[8..]));
        } else if (std.mem.startsWith(u8, line, "source=(")) {
            // Gather text until the closing ')', which may be on a later line.
            var body: std.ArrayListUnmanaged(u8) = .empty;
            var cur: []const u8 = line["source=(".len..];
            while (true) {
                if (std.mem.indexOfScalar(u8, cur, ')')) |end| {
                    try body.appendSlice(a, cur[0..end]);
                    break;
                }
                try body.appendSlice(a, cur);
                try body.append(a, ' ');
                const next = lines.next() orelse return error.UnterminatedSource;
                cur = std.mem.trim(u8, next, " \t\r\\");
            }
            var toks = std.mem.tokenizeAny(u8, body.items, " \t\\");
            while (toks.next()) |t| try sources.append(a, try a.dupe(u8, unquote(t)));
        }
    }
    return .{
        .name = name orelse return error.MissingName,
        .version = version orelse return error.MissingVersion,
        .release = release orelse return error.MissingRelease,
        .sources = try sources.toOwnedSlice(a),
    };
}

/// Expands $name, ${name}, $version, ${version}, $release, ${release}.
pub fn expand(a: std.mem.Allocator, s: []const u8, p: Pkgfile) ![]u8 {
    const vars = [_]struct { key: []const u8, val: []const u8 }{
        .{ .key = "name", .val = p.name },
        .{ .key = "version", .val = p.version },
        .{ .key = "release", .val = p.release },
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    outer: while (i < s.len) {
        if (s[i] == '$') {
            for (vars) |v| {
                const plain = i + 1 + v.key.len;
                if (std.mem.startsWith(u8, s[i + 1 ..], v.key)) {
                    // Do not eat a longer identifier like $names.
                    const boundary = plain >= s.len or !(std.ascii.isAlphanumeric(s[plain]) or s[plain] == '_');
                    if (boundary) {
                        try out.appendSlice(a, v.val);
                        i = plain;
                        continue :outer;
                    }
                }
                const braced = i + 3 + v.key.len;
                if (std.mem.startsWith(u8, s[i..], "${") and
                    std.mem.startsWith(u8, s[i + 2 ..], v.key) and
                    braced <= s.len and s[braced - 1] == '}')
                {
                    try out.appendSlice(a, v.val);
                    i = braced;
                    continue :outer;
                }
            }
        }
        try out.append(a, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

pub fn isRemote(src: []const u8) bool {
    return std.mem.startsWith(u8, src, "https://") or std.mem.startsWith(u8, src, "http://");
}

pub fn basename(src: []const u8) []const u8 {
    const no_query = if (std.mem.indexOfScalar(u8, src, '?')) |q| src[0..q] else src;
    const slash = std.mem.lastIndexOfScalar(u8, no_query, '/') orelse return no_query;
    return no_query[slash + 1 ..];
}

pub fn isArchive(file: []const u8) bool {
    const suffixes = [_][]const u8{ ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".tar.zst", ".tar" };
    for (suffixes) |s| if (std.mem.endsWith(u8, file, s)) return true;
    return false;
}

// ---------------------------------------------------------------- checksums

pub const Sum = struct { file: []const u8, hex: []const u8 };

pub fn parseSums(a: std.mem.Allocator, text: []const u8) ![]Sum {
    var out: std.ArrayListUnmanaged(Sum) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const hex = line[0..sp];
        var file = std.mem.trim(u8, line[sp..], " \t");
        if (file.len > 0 and file[0] == '*') file = file[1..];
        if (hex.len != 64) continue;
        try out.append(a, .{ .file = try a.dupe(u8, file), .hex = try a.dupe(u8, hex) });
    }
    return out.toOwnedSlice(a);
}

pub fn findSum(sums: []const Sum, file: []const u8) ?[]const u8 {
    for (sums) |s| if (std.mem.eql(u8, s.file, file)) return s.hex;
    return null;
}

pub fn sha256File(path: []const u8) ![64]u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// Case-insensitive hex compare, constant time for equal lengths.
pub fn hexEqual(x: []const u8, y: []const u8) bool {
    if (x.len != y.len) return false;
    var diff: u8 = 0;
    for (x, y) |p, q| diff |= std.ascii.toLower(p) ^ std.ascii.toLower(q);
    return diff == 0;
}

// ---------------------------------------------------------------- tests

const sample =
    \\# Description: Tiny example
    \\# URL: https://example.org
    \\name=hello
    \\version=2.12
    \\release=1
    \\source=(https://ftp.gnu.org/gnu/$name/$name-$version.tar.gz
    \\        local.patch)
    \\
    \\build() {
    \\  cd $name-$version
    \\  ./configure --prefix=/usr
    \\  make
    \\  make DESTDIR=$PKG install
    \\}
    \\
;

test "parse sample Pkgfile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parse(a, sample);
    try std.testing.expectEqualStrings("hello", p.name);
    try std.testing.expectEqualStrings("2.12", p.version);
    try std.testing.expectEqual(@as(usize, 2), p.sources.len);
    const url = try expand(a, p.sources[0], p);
    try std.testing.expectEqualStrings("https://ftp.gnu.org/gnu/hello/hello-2.12.tar.gz", url);
    try std.testing.expectEqualStrings("hello-2.12.tar.gz", basename(url));
}

test "expand respects identifier boundaries and braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = Pkgfile{ .name = "x", .version = "1", .release = "2", .sources = &.{} };
    try std.testing.expectEqualStrings("x-1.tar", try expand(a, "$name-${version}.tar", p));
    try std.testing.expectEqualStrings("$names", try expand(a, "$names", p));
}

test "missing fields are errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingName, parse(arena.allocator(), "version=1\nrelease=1\n"));
}

test "parseSums and lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hex = "a" ** 64;
    const sums = try parseSums(a, hex ++ "  hello-2.12.tar.gz\n# comment\nshort  bad\n");
    try std.testing.expectEqual(@as(usize, 1), sums.len);
    try std.testing.expect(findSum(sums, "hello-2.12.tar.gz") != null);
    try std.testing.expect(findSum(sums, "nope") == null);
}

test "isArchive" {
    try std.testing.expect(isArchive("a-1.0.tar.xz"));
    try std.testing.expect(!isArchive("fix.patch"));
}
