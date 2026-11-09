//! Test entry point: pulls in every module so `zig build test` runs all
//! unit tests and type-checks the public surface of the rest.

const std = @import("std");

test {
    std.testing.refAllDecls(@import("config.zig"));
    std.testing.refAllDecls(@import("layout.zig"));
    std.testing.refAllDecls(@import("disk.zig"));
    std.testing.refAllDecls(@import("partition.zig"));
    std.testing.refAllDecls(@import("mkfs.zig"));
    std.testing.refAllDecls(@import("accounts.zig"));
    std.testing.refAllDecls(@import("services.zig"));
    std.testing.refAllDecls(@import("boot.zig"));
    std.testing.refAllDecls(@import("crypt.zig"));
    std.testing.refAllDecls(@import("pkgfile.zig"));
    std.testing.refAllDecls(@import("features.zig"));
    std.testing.refAllDecls(@import("sets.zig"));
    std.testing.refAllDecls(@import("install.zig"));
    std.testing.refAllDecls(@import("installer.zig"));
    std.testing.refAllDecls(@import("term.zig"));
    std.testing.refAllDecls(@import("exec.zig"));
    std.testing.refAllDecls(@import("target.zig"));
    _ = @import("pkg.zig");
    _ = @import("settings.zig");
}
