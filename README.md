# PandaOS

Minimal, privacy-focused GNU/Linux, written in Zig. Two ISOs: **musl** (default) and **glibc**. Budget: 550 MiB target, 625 MiB hard cap.

## Status: 0.0.1 code-complete, NOT YET COMPILED

All of this was written without a Zig compiler available. Expect compile errors on the first `zig build`, mostly std API drift. Written against 0.14/0.15-style `std`. Fix those, then run `zig build test`.

```
zig build                                # musl binaries in zig-out/bin
zig build -Dtarget=x86_64-linux-gnu      # glibc (links libcrypt)
zig build test                           # unit tests for every module
zig build run -- --dry-run               # run the installer, change nothing
scripts/build-iso.sh                     # assemble the ISO (see header for inputs)
```

## Binaries

| Binary | Source | Purpose |
|---|---|---|
| `pandaos-install` | `src/main.zig` | the `[I]nstaller, [S]hell` flow and install pipeline |
| `pkg` | `src/pkg.zig` | CRUX-style ports tool |
| `panda-settings` | `src/settings.zig` | "Advanced security features" menu |

## Source map

| File | Role |
|---|---|
| `installer.zig` | the question cascade (+ disk picker, layout editor) |
| `install.zig` | pipeline: confirm → partition → mkfs → mount → sets → configure → accounts → bootloader |
| `config.zig` | config model, validators, default package list, plan file |
| `layout.zig` | slices and `fitLayout()`: merges/shrinks slices to the real disk size |
| `disk.zig` | sysfs disk discovery, UEFI detection |
| `partition.zig` | pure-Zig GPT writer and MBR writer (extended + logical) |
| `mkfs.zig` | mkfs wrappers, mount order, fstab, preflight checks |
| `sets.zig` | extracts `<name>.tar.zst` sets from the media; unknown names queue as ports |
| `services.zig` | hostname, dinit service tree, xenodm/icewm/sway/hyprland config, wallpaper |
| `accounts.zig` | passwd/shadow/group edits (root rename, or locked root + wheel user) |
| `crypt.zig` | SHA-512 crypt via libc `crypt(3)` |
| `boot.zig` | static `grub.cfg` + `grub-install` (UEFI or BIOS) |
| `pkgfile.zig` | Pkgfile parser, `$name` expansion, sha256 verification |
| `features.zig` | the four security toggles |
| `exec.zig`, `target.zig`, `term.zig` | command runner (dry-run aware), target-root file helpers, terminal I/O |

## Behaviour notes

- **Install is destructive.** It requires typing the disk path to confirm. `--dry-run` prints every command and file write instead.
- **Layouts adapt.** Disks under 4 GiB are refused. Small disks merge `/usr/local`→`/usr`, then `/tmp`, `/var`, `/usr`→`/`. `/home` (btrfs) gets whatever is left.
- **FFS = UFS1** (`ufstype=44bsd` on Linux). The ESP is FAT32 because UEFI cannot read FFS. BIOS+GPT gets a 1 MiB BIOS-boot partition. MBR uses 3 primaries + extended/logicals (each logical loses 1 MiB to its EBR).
- **Question 4:** a name renames the uid-0 account to that name. `N` locks `root` and creates a regular user in `wheel` with `doas`, because otherwise the system would have no login.
- **dinit** is the default init; all service files are plain text under `/etc/dinit.d`.
- **Ports:** sources need a checksum in `.sha256sum` (`pkg sum <port>` generates it); builds refuse to run as root and use `rootlesskit` when present; `pkg add` refuses to overwrite files it doesn't own and rejects `..` paths.
- **Security toggles** (`panda-settings`) all require the root password (checked against `/etc/shadow`, 3 tries, 2 s delay):
  - encrypted RAM disk: `brd` + dm-crypt with a random in-memory key, mounted over `/tmp`
  - low contrast: `xrandr` brightness/gamma via `/etc/panda/session.d`
  - i2p: `i2pd` service, proxy env vars, LibreWolf policy. Clearnet through I2P needs an outproxy configured in `i2pd.conf`.
  - **gpg-grid: NOT IMPLEMENTED.** It refuses to enable instead of pretending.
