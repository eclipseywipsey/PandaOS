const std = @import("std");

pub fn build(b: *std.Build) void {
    // Main ISO is musl. For the glibc ISO:  zig build -Dtarget=x86_64-linux-gnu
    const target = b.standardTargetOptions(.{
        .default_target = .{ .os_tag = .linux, .abi = .musl },
    });
    // 550 MB ISO budget: stay small by default.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });
    const glibc = target.result.abi.isGnu();

    const Tool = struct { name: []const u8, src: []const u8, needs_crypt: bool };
    const tools = [_]Tool{
        .{ .name = "pandaos-install", .src = "src/main.zig", .needs_crypt = true },
        .{ .name = "panda-settings", .src = "src/settings.zig", .needs_crypt = true },
        .{ .name = "pkg", .src = "src/pkg.zig", .needs_crypt = false },
    };

    for (tools) |t| {
        const mod = b.createModule(.{
            .root_source_file = b.path(t.src),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            // crypt(3) lives in libc on musl; glibc needs libcrypt too.
            .link_libc = t.needs_crypt,
        });
        if (t.needs_crypt and glibc) mod.linkSystemLibrary("crypt", .{});

        const exe = b.addExecutable(.{ .name = t.name, .root_module = mod });
        b.installArtifact(exe);

        if (std.mem.eql(u8, t.name, "pandaos-install")) {
            const run = b.addRunArtifact(exe);
            run.step.dependOn(b.getInstallStep());
            if (b.args) |args| run.addArgs(args);
            b.step("run", "Run the installer (pass --dry-run to change nothing)").dependOn(&run.step);
        }
    }

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    if (glibc) test_mod.linkSystemLibrary("crypt", .{});
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
