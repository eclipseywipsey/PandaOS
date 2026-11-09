//! pandaos-install: entry point.
//! Shows the [I]nstaller / [S]hell prompt, runs the question cascade, then
//! the install pipeline (see install.zig).
//!
//! Flags:
//!   --dry-run          print every command / file write, change nothing
//!   --plan-only        write the plan file and stop after the questions
//!   --plan <path>      where to write the plan (default ./pandaos-install.plan)
//!   --target <dir>     mount point for the new system (default /mnt)
//!   --sets <dir>       directory holding <name>.tar.zst sets

const std = @import("std");
const term = @import("term.zig");
const config = @import("config.zig");
const installer = @import("installer.zig");
const install = @import("install.zig");
const exec = @import("exec.zig");

const banner =
    \\
    \\    PandaOS  GNU/linux
    \\    minimal. private. yours.
    \\
    \\
;

const usage =
    \\usage: pandaos-install [--dry-run] [--plan-only] [--plan <path>] [--target <dir>] [--sets <dir>]
    \\
;

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var plan_path: []const u8 = "pandaos-install.plan";
    var plan_only = false;
    var opts = install.Options{};

    const args = try std.process.argsAlloc(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            exec.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--plan-only")) {
            plan_only = true;
        } else if (std.mem.eql(u8, arg, "--plan") and i + 1 < args.len) {
            i += 1;
            plan_path = args[i];
        } else if (std.mem.eql(u8, arg, "--target") and i + 1 < args.len) {
            i += 1;
            opts.target = args[i];
        } else if (std.mem.eql(u8, arg, "--sets") and i + 1 < args.len) {
            i += 1;
            opts.sets_dir = args[i];
        } else {
            term.write(usage);
            return;
        }
    }

    term.write(banner);

    var buf: [64]u8 = undefined;
    while (true) {
        term.write("[I]nstaller, [S]hell: ");
        const line = term.readLine(&buf) catch |e| switch (e) {
            error.EndOfStream => return,
            error.LineTooLong => continue,
            else => return e,
        };
        const choice: u8 = if (line.len == 0) 'i' else std.ascii.toLower(line[0]);
        switch (choice) {
            'i' => {
                try runInstaller(arena, plan_path, plan_only, opts);
                return;
            },
            's' => {
                var child = std.process.Child.init(&.{"/bin/sh"}, arena);
                _ = child.spawnAndWait() catch |e| {
                    term.print("could not start /bin/sh: {s}\n", .{@errorName(e)});
                };
            },
            else => term.write("please choose I or S\n"),
        }
    }
}

fn runInstaller(arena: std.mem.Allocator, plan_path: []const u8, plan_only: bool, opts: install.Options) !void {
    var result = try installer.run(arena);
    defer result.root_password.wipe();
    defer result.user_password.wipe();

    const plan = try config.renderPlan(arena, result.config);
    const file = try std.fs.cwd().createFile(plan_path, .{});
    defer file.close();
    try file.writeAll(plan);
    term.print("\nPlan written to {s}.\n", .{plan_path});

    if (plan_only) return;
    install.run(arena, &result, opts) catch |e| switch (e) {
        error.Aborted => term.write("\nAborted. Nothing was changed.\n"),
        else => {
            term.print("\nInstall failed: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        },
    };
}
