//! pkg: PandaOS ports tool (CRUX-inspired).
//!
//!   pkg build <port>     fetch, verify, build in a work dir as a NORMAL user
//!   pkg fetch <port>     fetch + verify sources only
//!   pkg sum <port>       (re)generate <port>/.sha256sum from the sources
//!   pkg add <file>       install a built package (root)
//!   pkg install <port>   build, then add (via doas when not root)
//!   pkg remove <name>    remove an installed package (root)
//!   pkg info <name>      show an installed package
//!   pkg list             list installed packages
//!   pkg pending          build+install everything queued by the installer
//!
//! Security model: sources must have a checksum in the port's .sha256sum;
//! builds refuse to run as root; rootlesskit is used when available so
//! `make install` can run under a fake-root user namespace.

const std = @import("std");
const pf = @import("pkgfile.zig");
const term = @import("term.zig");
const exec = @import("exec.zig");

const ports_root = "/usr/ports";
const db_root = "/var/lib/pkg/db";
const pending_file = "/var/lib/pkg/pending";

fn isRoot() bool {
    return std.os.linux.geteuid() == 0;
}

fn fail(comptime fmt: []const u8, args: anytype) void {
    term.print("pkg: " ++ fmt ++ "\n", args);
}

// ---------------------------------------------------------------- ports + cache

fn findPort(a: std.mem.Allocator, name: []const u8) ![]u8 {
    // Flat layout first: /usr/ports/<name>
    const flat = try std.fs.path.join(a, &.{ ports_root, name });
    const flat_pf = try std.fs.path.join(a, &.{ flat, "Pkgfile" });
    if (std.fs.cwd().access(flat_pf, .{})) |_| return flat else |_| {}

    // Collections: /usr/ports/<collection>/<name>
    var dir = std.fs.cwd().openDir(ports_root, .{ .iterate = true }) catch return error.PortNotFound;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .directory) continue;
        const cand = try std.fs.path.join(a, &.{ ports_root, e.name, name });
        const cand_pf = try std.fs.path.join(a, &.{ cand, "Pkgfile" });
        if (std.fs.cwd().access(cand_pf, .{})) |_| return cand else |_| {}
    }
    return error.PortNotFound;
}

const Cache = struct {
    distfiles: []const u8,
    work: []const u8,
    packages: []const u8,
};

fn cacheDirs(a: std.mem.Allocator) !Cache {
    const home = std.process.getEnvVarOwned(a, "HOME") catch return error.NoHome;
    const base = try std.fs.path.join(a, &.{ home, ".cache", "pkg" });
    const c = Cache{
        .distfiles = try std.fs.path.join(a, &.{ base, "distfiles" }),
        .work = try std.fs.path.join(a, &.{ base, "work" }),
        .packages = try std.fs.path.join(a, &.{ base, "packages" }),
    };
    try std.fs.cwd().makePath(c.distfiles);
    try std.fs.cwd().makePath(c.work);
    try std.fs.cwd().makePath(c.packages);
    return c;
}

const Loaded = struct { dir: []const u8, pkgfile: pf.Pkgfile };

fn loadPort(a: std.mem.Allocator, name: []const u8) !Loaded {
    const dir = try findPort(a, name);
    const path = try std.fs.path.join(a, &.{ dir, "Pkgfile" });
    const text = try std.fs.cwd().readFileAlloc(a, path, 1024 * 1024);
    return .{ .dir = dir, .pkgfile = try pf.parse(a, text) };
}

fn loadSums(a: std.mem.Allocator, dir: []const u8) ![]pf.Sum {
    const path = try std.fs.path.join(a, &.{ dir, ".sha256sum" });
    const text = std.fs.cwd().readFileAlloc(a, path, 1024 * 1024) catch return error.MissingChecksum;
    return pf.parseSums(a, text);
}

// ---------------------------------------------------------------- fetch + verify

/// Returns local paths of all sources, downloaded (if needed) and verified.
fn fetchSources(a: std.mem.Allocator, l: Loaded, c: Cache, verify: bool) ![]const []const u8 {
    const sums: []pf.Sum = if (verify) try loadSums(a, l.dir) else &.{};
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;

    for (l.pkgfile.sources) |raw| {
        const src = try pf.expand(a, raw, l.pkgfile);
        const file = pf.basename(src);
        var local: []const u8 = undefined;

        if (pf.isRemote(src)) {
            local = try std.fs.path.join(a, &.{ c.distfiles, file });
            if (std.fs.cwd().access(local, .{})) |_| {} else |_| {
                if (std.mem.startsWith(u8, src, "http://")) fail("warning: {s} is not https (checksum still enforced)", .{src});
                term.print("  fetching {s}\n", .{src});
                try exec.run(a, &.{ "curl", "-fL", "--retry", "3", "-o", local, src });
            }
        } else {
            local = try std.fs.path.join(a, &.{ l.dir, src });
        }

        if (verify) {
            const want = pf.findSum(sums, file) orelse {
                fail("no checksum for {s} in .sha256sum", .{file});
                return error.MissingChecksum;
            };
            const got = try pf.sha256File(local);
            if (!pf.hexEqual(&got, want)) {
                fail("checksum mismatch for {s}\n  expected {s}\n  got      {s}", .{ file, want, got });
                if (pf.isRemote(src)) std.fs.cwd().deleteFile(local) catch {};
                return error.ChecksumMismatch;
            }
            term.print("  verified {s}\n", .{file});
        }
        try paths.append(a, local);
    }
    return paths.toOwnedSlice(a);
}

fn cmdSum(a: std.mem.Allocator, name: []const u8) !void {
    const l = try loadPort(a, name);
    const c = try cacheDirs(a);
    const paths = try fetchSources(a, l, c, false);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (paths) |p| {
        const h = try pf.sha256File(p);
        const line = try std.fmt.allocPrint(a, "{s}  {s}\n", .{ h, std.fs.path.basename(p) });
        try out.appendSlice(a, line);
    }
    const dest = try std.fs.path.join(a, &.{ l.dir, ".sha256sum" });
    try std.fs.cwd().writeFile(.{ .sub_path = dest, .data = out.items });
    term.print("wrote {s}\n", .{dest});
}

// ---------------------------------------------------------------- build

const build_script =
    \\set -e
    \\. "$PORTDIR/Pkgfile"
    \\cd "$SRC"
    \\build
    \\mkdir -p "$(dirname "$OUT")"
    \\tar -C "$PKG" --owner=0 --group=0 --numeric-owner --zstd -cpf "$OUT" .
    \\
;

fn cmdBuild(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (isRoot() and !envFlag(a, "PKG_ALLOW_ROOT_BUILD")) {
        fail("refusing to build as root (a malicious build script would own the system).\n  Run as a normal user; set PKG_ALLOW_ROOT_BUILD=1 to override.", .{});
        return error.BuildAsRoot;
    }
    const l = try loadPort(a, name);
    const c = try cacheDirs(a);
    const p = l.pkgfile;
    term.print("building {s} {s}-{s}\n", .{ p.name, p.version, p.release });

    const paths = try fetchSources(a, l, c, true);

    const work = try std.fs.path.join(a, &.{ c.work, p.name });
    std.fs.cwd().deleteTree(work) catch {};
    const src_dir = try std.fs.path.join(a, &.{ work, "src" });
    const pkg_dir = try std.fs.path.join(a, &.{ work, "pkg" });
    try std.fs.cwd().makePath(src_dir);
    try std.fs.cwd().makePath(pkg_dir);

    for (paths) |sp| {
        const base = std.fs.path.basename(sp);
        if (pf.isArchive(base)) {
            try exec.run(a, &.{ "tar", "-xf", sp, "-C", src_dir });
        } else {
            const dest = try std.fs.path.join(a, &.{ src_dir, base });
            try std.fs.cwd().copyFile(sp, std.fs.cwd(), dest, .{});
        }
    }

    const out = try std.fmt.allocPrint(a, "{s}/{s}#{s}-{s}.pkg.tar.zst", .{ c.packages, p.name, p.version, p.release });

    var env = try std.process.getEnvMap(a);
    try env.put("PORTDIR", l.dir);
    try env.put("SRC", src_dir);
    try env.put("PKG", pkg_dir);
    try env.put("OUT", out);

    const argv: []const []const u8 = if (exec.have(a, "rootlesskit"))
        &.{ "rootlesskit", "sh", "-c", build_script }
    else
        &.{ "sh", "-c", build_script };

    var child = std.process.Child.init(argv, a);
    child.env_map = &env;
    const res = try child.spawnAndWait();
    switch (res) {
        .Exited => |code| if (code != 0) {
            fail("build failed (exit {d})", .{code});
            return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
    term.print("built {s}\n", .{out});
    return out;
}

fn envFlag(a: std.mem.Allocator, name: []const u8) bool {
    const v = std.process.getEnvVarOwned(a, name) catch return false;
    return std.mem.eql(u8, v, "1");
}

// ---------------------------------------------------------------- install DB

/// "name#version-release.pkg.tar.zst" -> name
fn pkgNameFromFile(file: []const u8) ![]const u8 {
    const base = std.fs.path.basename(file);
    const hash = std.mem.indexOfScalar(u8, base, '#') orelse return error.BadPackageName;
    if (hash == 0) return error.BadPackageName;
    return base[0..hash];
}

fn pkgVersionFromFile(file: []const u8) []const u8 {
    const base = std.fs.path.basename(file);
    const hash = std.mem.indexOfScalar(u8, base, '#') orelse return "";
    const end = std.mem.indexOf(u8, base, ".pkg.tar") orelse base.len;
    return base[hash + 1 .. end];
}

/// Tar member -> absolute path, rejecting traversal and absolute members.
fn safeAbs(a: std.mem.Allocator, member: []const u8) ![]u8 {
    var m = member;
    if (std.mem.startsWith(u8, m, "./")) m = m[2..];
    if (m.len == 0 or m[0] == '/') return error.UnsafePath;
    var it = std.mem.splitScalar(u8, m, '/');
    while (it.next()) |part| if (std.mem.eql(u8, part, "..")) return error.UnsafePath;
    return std.fmt.allocPrint(a, "/{s}", .{m});
}

fn readManifest(a: std.mem.Allocator, name: []const u8) ![]const []const u8 {
    const path = try std.fmt.allocPrint(a, "{s}/{s}/files", .{ db_root, name });
    const text = std.fs.cwd().readFileAlloc(a, path, 64 * 1024 * 1024) catch return &.{};
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |l| try out.append(a, l);
    return out.toOwnedSlice(a);
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

/// Is `path` listed in any installed package other than `except`?
fn ownedByOther(a: std.mem.Allocator, path: []const u8, except: []const u8) !bool {
    var dir = std.fs.cwd().openDir(db_root, .{ .iterate = true }) catch return false;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .directory or std.mem.eql(u8, e.name, except)) continue;
        if (contains(try readManifest(a, e.name), path)) return true;
    }
    return false;
}

fn cmdAdd(a: std.mem.Allocator, file: []const u8) !void {
    if (!isRoot()) {
        fail("'add' needs root (use doas)", .{});
        return error.NotRoot;
    }
    const name = try pkgNameFromFile(file);
    const listing = try exec.capture(a, &.{ "tar", "-tf", file });

    const old = try readManifest(a, name);
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, listing, '\n');
    while (lines.next()) |m| {
        if (std.mem.endsWith(u8, m, "/")) continue; // directories
        const abs = try safeAbs(a, m);
        // Existing file is fine only if this package (an upgrade) owned it.
        if (std.fs.cwd().access(abs, .{})) |_| {
            if (!contains(old, abs)) {
                fail("conflict: {s} already exists and is not owned by {s}", .{ abs, name });
                return error.Conflict;
            }
        } else |_| {}
        try files.append(a, abs);
    }

    term.print("installing {s}\n", .{name});
    try exec.run(a, &.{ "tar", "-xpf", file, "-C", "/", "--numeric-owner" });

    // Remove files from the old version that the new one dropped.
    for (old) |o| if (!contains(files.items, o)) std.fs.cwd().deleteFile(o) catch {};

    const dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ db_root, name });
    try std.fs.cwd().makePath(dir);
    const manifest = try std.mem.join(a, "\n", files.items);
    const mpath = try std.fmt.allocPrint(a, "{s}/files", .{dir});
    try std.fs.cwd().writeFile(.{ .sub_path = mpath, .data = manifest });
    const vpath = try std.fmt.allocPrint(a, "{s}/version", .{dir});
    try std.fs.cwd().writeFile(.{ .sub_path = vpath, .data = pkgVersionFromFile(file) });
}

fn cmdRemove(a: std.mem.Allocator, name: []const u8) !void {
    if (!isRoot()) {
        fail("'remove' needs root (use doas)", .{});
        return error.NotRoot;
    }
    const files = try readManifest(a, name);
    if (files.len == 0) {
        fail("{s} is not installed", .{name});
        return error.NotInstalled;
    }
    for (files) |f| {
        _ = try safeAbs(a, f[1..]); // re-validate what the DB says
        if (try ownedByOther(a, f, name)) continue; // shared path: keep
        std.fs.cwd().deleteFile(f) catch {};
    }
    const dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ db_root, name });
    try std.fs.cwd().deleteTree(dir);
    term.print("removed {s}\n", .{name});
}

fn cmdInfo(a: std.mem.Allocator, name: []const u8) !void {
    const vpath = try std.fmt.allocPrint(a, "{s}/{s}/version", .{ db_root, name });
    const v = std.fs.cwd().readFileAlloc(a, vpath, 4096) catch {
        fail("{s} is not installed", .{name});
        return error.NotInstalled;
    };
    const files = try readManifest(a, name);
    term.print("{s} {s} ({d} files)\n", .{ name, v, files.len });
}

fn cmdList(a: std.mem.Allocator) !void {
    var dir = std.fs.cwd().openDir(db_root, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .directory) continue;
        const vpath = try std.fmt.allocPrint(a, "{s}/{s}/version", .{ db_root, e.name });
        const v = std.fs.cwd().readFileAlloc(a, vpath, 4096) catch "?";
        term.print("{s} {s}\n", .{ e.name, v });
    }
}

fn cmdInstall(a: std.mem.Allocator, name: []const u8) !void {
    const pkg_file = try cmdBuild(a, name);
    if (isRoot()) return cmdAdd(a, pkg_file);
    const self = try std.fs.selfExePathAlloc(a);
    try exec.run(a, &.{ "doas", self, "add", pkg_file });
}

fn cmdPending(a: std.mem.Allocator) !void {
    const text = std.fs.cwd().readFileAlloc(a, pending_file, 1024 * 1024) catch {
        term.write("nothing pending\n");
        return;
    };
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |name| {
        cmdInstall(a, name) catch |e| fail("{s}: {s} (continuing)", .{ name, @errorName(e) });
    }
}

// ---------------------------------------------------------------- entry

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const args = try std.process.argsAlloc(a);
    if (args.len < 2) return usage();
    const cmd = args[1];
    const arg: ?[]const u8 = if (args.len > 2) args[2] else null;

    const result: anyerror!void = blk: {
        if (std.mem.eql(u8, cmd, "list")) break :blk cmdList(a);
        if (std.mem.eql(u8, cmd, "pending")) break :blk cmdPending(a);
        const x = arg orelse return usage();
        if (std.mem.eql(u8, cmd, "build")) {
            _ = cmdBuild(a, x) catch |e| break :blk e;
            break :blk {};
        }
        if (std.mem.eql(u8, cmd, "fetch")) break :blk fetchOnly(a, x);
        if (std.mem.eql(u8, cmd, "sum")) break :blk cmdSum(a, x);
        if (std.mem.eql(u8, cmd, "add")) break :blk cmdAdd(a, x);
        if (std.mem.eql(u8, cmd, "install")) break :blk cmdInstall(a, x);
        if (std.mem.eql(u8, cmd, "remove")) break :blk cmdRemove(a, x);
        if (std.mem.eql(u8, cmd, "info")) break :blk cmdInfo(a, x);
        return usage();
    };
    result catch |e| {
        fail("{s}", .{@errorName(e)});
        std.process.exit(1);
    };
}

fn fetchOnly(a: std.mem.Allocator, name: []const u8) !void {
    const l = try loadPort(a, name);
    const c = try cacheDirs(a);
    _ = try fetchSources(a, l, c, true);
}

fn usage() void {
    term.write(
        \\usage: pkg <command> [argument]
        \\  build <port>     fetch, verify and build (as a normal user)
        \\  fetch <port>     fetch and verify sources only
        \\  sum <port>       generate <port>/.sha256sum
        \\  add <file>       install a built package (root)
        \\  install <port>   build, then add
        \\  remove <name>    remove a package (root)
        \\  info <name>      show an installed package
        \\  list             list installed packages
        \\  pending          install ports queued by the installer
        \\
    );
}

test "package filename parsing" {
    try std.testing.expectEqualStrings("hello", try pkgNameFromFile("/x/hello#2.12-1.pkg.tar.zst"));
    try std.testing.expectEqualStrings("2.12-1", pkgVersionFromFile("hello#2.12-1.pkg.tar.zst"));
    try std.testing.expectError(error.BadPackageName, pkgNameFromFile("nohash.pkg.tar.zst"));
}

test "safeAbs rejects traversal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/usr/bin/x", try safeAbs(a, "./usr/bin/x"));
    try std.testing.expectError(error.UnsafePath, safeAbs(a, "../etc/passwd"));
    try std.testing.expectError(error.UnsafePath, safeAbs(a, "/etc/passwd"));
    try std.testing.expectError(error.UnsafePath, safeAbs(a, "usr/../../etc/x"));
}
