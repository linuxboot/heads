# Heads modules (tools included in the initrd)

Tools available in the Heads initrd are defined by `CONFIG_*` flags in board configs
(`boards/*/*.config`) and compiled by the top-level `Makefile`. Each `bin_modules-$(CONFIG_*) += <name>`
line adds a package to `tools.cpio` (one of six CPIO archives assembled into the initrd).

Not all tools are BusyBox applets — many are standalone binaries compiled as separate packages.

## Module list (from the `bin_modules-$(CONFIG_* )` block in the Makefile)

| Makefile line | Config flag | Package | Type |
|---|---|---|---|
| 718 | `CONFIG_KEXEC` | kexec | Standalone |
| 719 | `CONFIG_TPMTOTP` | tpmtotp | Standalone |
| 720 | `CONFIG_PCIUTILS` | pciutils | Standalone |
| 721 | `CONFIG_FLASHROM` | flashrom | Standalone |
| 722 | `CONFIG_FLASHPROG` | flashprog | Standalone |
| 723 | `CONFIG_CRYPTSETUP` | cryptsetup | Standalone |
| 724 | `CONFIG_CRYPTSETUP2` | cryptsetup2 | Standalone |
| 725 | `CONFIG_GPG` | gpg | Standalone |
| 726 | `CONFIG_GPG2` | gpg2 | Standalone |
| 727 | `CONFIG_PINENTRY` | pinentry | Standalone |
| 728 | `CONFIG_LVM2` | lvm2 | Standalone |
| 729 | `CONFIG_DROPBEAR` | dropbear | Standalone |
| 730 | `CONFIG_FLASHTOOLS` | flashtools | Standalone |
| 731 | `CONFIG_NEWT` | newt | Standalone |
| 732 | `CONFIG_CAIRO` | cairo | Standalone |
| 733 | `CONFIG_FBWHIPTAIL` | fbwhiptail | Standalone |
| 734 | `CONFIG_HOTPKEY` | hotp-verification | Standalone |
| 735 | `CONFIG_MSRTOOLS` | msrtools | Standalone |
| 736 | `CONFIG_NKSTORECLI` | nkstorecli | Standalone |
| 737 | `CONFIG_UTIL_LINUX` | util-linux | Standalone |
| 738 | `CONFIG_OPENSSL` | openssl | Standalone |
| 739 | `CONFIG_TPM2_TOOLS` | tpm2-tools | Standalone |
| 740 | `CONFIG_BASH` | bash | Standalone |
| 741 | `CONFIG_POWERPC_UTILS` | powerpc-utils | Standalone |
| 742 | `CONFIG_IO386` | io386 | Standalone |
| 743 | `CONFIG_IOPORT` | ioport | Standalone |
| 744 | `CONFIG_KBD` | kbd | Standalone |
| 745 | **`CONFIG_ZSTD`** | **zstd** | **Standalone** |
| 746 | `CONFIG_E2FSPROGS` | e2fsprogs | Standalone |

## BusyBox applets (always available)

BusyBox v1.36.1 provides the following applets relevant to Heads scripts.
These are always available regardless of board config.

```text
[, [[, arch, arp, ascii, ash, awk, base32, basename, blkid, blockdev,
bunzip2, bzcat, bzip2, cat, chattr, chmod, chroot, clear, cmp, cp,
cpio, crc32, cttyhack, cut, date, dc, dd, devmem, df, diff, dirname,
dmesg, du, echo, env, expr, factor, fallocate, false, fdisk, find,
fold, fsck, fsfreeze, getopt, grep, groups, gunzip, gzip, hd, head,
hexdump, hexedit, hostid, hwclock, i2cdetect, i2cdump, i2cget, i2cset,
id, ifconfig, insmod, install, ip, kill, killall, killall5, less, link,
ln, loadkmap, losetup, ls, lsattr, lsmod, lsof, lsscsi, lsusb, lzcat,
lzma, md5sum, mkdir, mkdosfs, mkfifo, mkfs.vfat, mknod, mktemp,
modinfo, more, mount, mv, nc, nl, nproc, nslookup, ntpd, partprobe,
paste, patch, pgrep, pidof, ping, pkill, printf, ps, pwd, readlink,
realpath, reboot, reset, resume, rm, rmdir, route, sed, seedrng, seq,
setfattr, setpriv, setserial, setsid, sh, sha1sum, sha256sum, sha3sum,
sha512sum, shred, sleep, sort, ssl_client, stat, strings, stty, sync,
sysctl, tail, tar, tee, test, tftp, time, top, touch, tr, tree, true,
truncate, tsort, tty, udhcpc, umount, uname, uniq, unlzma, unxz, unzip,
usleep, vconfig, vi, wc, wget, which, xargs, xxd, xz, xzcat, zcat
```

## How the build system includes modules

Three files interact to determine what goes into `tools.cpio` (the initrd):

| File | Line | Role |
|------|------|------|
| `boards/<board>/<board>.config` | `CONFIG_FOO=y` | Board-specific Make variable (e.g. `CONFIG_GPG2=y` enables GPG) |
| `modules/<name>` | `CONFIG_FOO ?= y` | Module default — only sets the variable if the board config did not |
| `Makefile` | `include modules/*` | Loads all module files into the Make namespace |
| `Makefile` | `bin_modules-$(CONFIG_FOO) += foo` | Conditionally builds and adds the module to `tools.cpio` |

**The inclusion decision tree for any board:**

1. `include $(CONFIG)` loads the board config — any `CONFIG_FOO=y`
   (no `export` needed) becomes a Make variable.
2. `include modules/*` loads every module file.  Each module
   can set a default with `?=` which only applies if the board config didn't already
   set the variable.
3. `bin_modules-$(CONFIG_FOO) += foo` conditionally adds the
   module to `tools.cpio` — when `CONFIG_FOO` is `y`, the module is built and included;
   when `n` or unset, it is skipped.
4. `modules-$(CONFIG_FOO) += foo` (in the module file) adds the module to the
   build graph so its compile targets run.

**`export` in board configs is unrelated to module inclusion.**  `export` places the
variable into the initrd's `/etc/config` at build time, where `config-gui.sh` can
modulate it further with user overrides from CBFS `/etc/config.user`.  Module
inclusion is purely based on Make variable state.

### Auto-included modules

These modules use `CONFIG_FOO ?= y` in their `modules/<name>` file, so they
are included in every build unless a board explicitly sets `CONFIG_FOO=n`:

| Module | File | Default |
|--------|------|---------|
| `zstd` | `modules/zstd` | `CONFIG_ZSTD ?= y` — provides `zstd-decompress` |
| `bash` | `Makefile` | `CONFIG_BASH ?= y` — interactive shell |
| `kbd` | `Makefile` | `CONFIG_KBD ?= y` — keymaps and `loadkeys` |
| `heads` | `Makefile` | `CONFIG_HEADS ?= y` — Heads base |

Some auto-included defaults are set in the Makefile itself (before `include modules/*`),
others in the module `.mk` files.  The effect is the same: `?=` only sets the variable
if the board config did not already override it.

### Board-enabled modules

These modules default to `n` and must be explicitly enabled in the board config
with `CONFIG_FOO=y` (no `export` needed for inclusion):

```bash
# boards/qemu-coreboot-fbwhiptail-tpm2/qemu-coreboot-fbwhiptail-tpm2.config
CONFIG_GPG2=y          # enables gpg2 module
CONFIG_TPM2_TOOLS=y    # enables tpm2-tools module
```

### Listing auto-included modules

```bash
grep -r 'CONFIG_.*?= y' modules/ Makefile | grep -v '\.git'
```

## Available targets

### Module targets

Each `modules/<name>` file generates a Make target.  Build a single
package and its dependencies:

```bash
nix develop --command make BOARD=$BOARD kexec     # kexec-tools
nix develop --command make BOARD=$BOARD linux      # Linux kernel
nix develop --command make BOARD=$BOARD coreboot   # coreboot ROM
```

Full ROM build (all modules + initrd + ROM assembly):

```bash
nix develop --command make BOARD=$BOARD
```

### Maintenance targets

| Target | What it does |
|--------|-------------|
| `real.clean` | Remove all build artifacts |
| `real.gitclean` | `git clean` — remove all untracked files |
| `real.gitclean_keep_packages` | `git clean` but keep downloaded tarballs in `packages/` |
| `real.remove_canary_files-extract_patch_rebuild_what_changed` | Remove all `.canary` sentinels, clear install + coreboot/board build caches, then rebuild.  Use this after changing patches. |
| `real.gitclean_keep_packages_and_build` | Keep packages + clean + full rebuild |

All run under `nix develop` (local) or `./docker_repro.sh` (Docker):

```bash
nix develop --command make BOARD=$BOARD real.clean
nix develop --command make BOARD=$BOARD real.remove_canary_files-extract_patch_rebuild_what_changed
```

### Module-level helpers

Some packages define their own helpers in `modules/<name>`.
Common ones (run with `nix develop --command make BOARD=$BOARD <target>`):

| Target | Defined in | What it does |
|--------|-----------|-------------|
| `coreboot.save_in_defconfig_format_in_place` | `modules/coreboot` | Normalize to defconfig (minimal, sorted) |
| `coreboot.save_in_oldconfig_format_in_place` | `modules/coreboot` | Normalize to full .config |
| `coreboot.save_in_defconfig_format_backup` | `modules/coreboot` | Same as defconfig but saves as `_defconfig` backup |
| `coreboot.modify_defconfig_in_place` | `modules/coreboot` | Run `menuconfig`, save as defconfig |
| `coreboot.modify_and_save_oldconfig_in_place` | `modules/coreboot` | Run `menuconfig`, save as full .config |
| `linux.save_in_defconfig_format_in_place` | `modules/linux` | Normalize kernel config to defconfig |
| `linux.save_in_olddefconfig_format_in_place` | `modules/linux` | Normalize to olddefconfig format |
| `linux.save_in_versioned_defconfig_format` | `modules/linux` | Save defconfig with version stamp |
| `linux.save_in_versioned_oldconfig` | `modules/linux` | Save full .config with version stamp |
| `linux.modify_and_save_defconfig_in_place` | `modules/linux` | Run `menuconfig`, save as defconfig |
| `linux.modify_and_save_oldconfig_in_place` | `modules/linux` | Run `menuconfig`, save as full .config |
| `linux.prompt_for_new_config_options_for_kernel_version_bump` | `modules/linux` | Prompt for new kernel Kconfig options on version bump |
| `linuxboot.run` | `modules/linuxboot` | Run Heads under LinuxBoot |
| `u-root.clean` | `modules/u-root` | Clean u-root build artifacts |

These are used after manually editing `config/coreboot-BOARD.config` or
`config/linux-BOARD.config` to normalize the file back to the convention
expected by the build system.

## Build lifecycle

Each module (whether tarball or git-sourced) goes through the same stages
controlled by sentinel files in `build/$ARCH/PACKAGE-DIR/`:

```
tarball / git clone → .canary → .configured → .build → binary → initrd
```

- **`.canary`** — package extracted/cloned and patches applied.  Depends
  only on the tarball or git repo HEAD, NOT on patch files.
- **`.configured`** — `./configure` run (or equivalent setup).
- **`.build`** — `make` / `make install` run.  Depends on `.configured`
  and on all dependency packages' `.build` files.

The binary lands in `build/$ARCH/PACKAGE-DIR/$output` and is copied into
the initrd by `bin_modules-$(CONFIG_FOO)`.

### Rebuilding after changing a patch

**The `.canary` sentinel does NOT depend on patch files.**  Modifying a
patch in `patches/PACKAGE-VERSION/` leaves `.canary` up-to-date and the
old binary is used.  To force re-extraction and re-patching:

**Per-package** (fastest, one package only):

```bash
rm build/$ARCH/PACKAGE-DIR/.canary
rm build/$ARCH/PACKAGE-DIR/.configured
rm build/$ARCH/PACKAGE-DIR/.build
nix develop --command sh -c "make BOARD=$BOARD $PACKAGE"
```

Example: after changing `patches/kexec-2.0.26/0003-screen_info-normalize-for-VLFB.patch`:

```bash
rm build/x86/kexec-tools-2.0.26/.canary
rm build/x86/kexec-tools-2.0.26/.configured
rm build/x86/kexec-tools-2.0.26/.build
nix develop --command sh -c "make BOARD=novacustom-nv4x_adl kexec"
```

**Full rebuild** (all packages, use the helper target):

```bash
nix develop --command make BOARD=$BOARD \
  real.remove_canary_files-extract_patch_rebuild_what_changed
nix develop --command make BOARD=$BOARD
```

## Module file format

Defined in `modules/<name>`.  See `modules/kexec` for a complete example.
Key variables:

```makefile
modules-$(CONFIG_KEXEC) += kexec      # add to build graph
kexec_dir := kexec-tools-$(kexec_version)
kexec_tar := kexec-tools-$(kexec_version).tar.gz
kexec_hash := sha256...
kexec_output := build/sbin/kexec       # installed into initrd
```

The `define_module` function in `Makefile` expands these into the
`.canary` → `.configured` → `.build` chain above.  The package name
is the Make target: `make BOARD=... kexec` builds just that package.
```
