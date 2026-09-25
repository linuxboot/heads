# Heads modules (tools included in the initrd)

See also: [reproducible-builds.md](reproducible-builds.md) for archive
determinism, [build-freshness.md](build-freshness.md#building-fresh) for
stale-output debugging, and
[build-artifacts.md](build-artifacts.md#size-and-hash-manifest-semantics) for
size/hash manifest boundaries.

Tools available in the Heads initrd are defined by `CONFIG_*` flags in board configs
(`boards/*/*.config`) and compiled by the top-level `Makefile`. Each `bin_modules-$(CONFIG_*) += <name>`
line adds a package to `tools.cpio`, one of the cpio components merged into the
final initrd.  The component count depends on board/module settings; see
[build-freshness.md](build-freshness.md#initrdcpioxz-composition).

Not all tools are BusyBox applets — many are standalone binaries compiled as separate packages.

## Module list (from the `bin_modules-$(CONFIG_* )` block in the Makefile)

| Config flag | Package | Type |
|---|---|---|
| `CONFIG_KEXEC` | kexec | Standalone |
| `CONFIG_TPMTOTP` | tpmtotp | Standalone |
| `CONFIG_PCIUTILS` | pciutils | Standalone |
| `CONFIG_FLASHROM` | flashrom | Standalone |
| `CONFIG_FLASHPROG` | flashprog | Standalone |
| `CONFIG_CRYPTSETUP` | cryptsetup | Standalone |
| `CONFIG_CRYPTSETUP2` | cryptsetup2 | Standalone |
| `CONFIG_GPG` | gpg | Standalone |
| `CONFIG_GPG2` | gpg2 | Standalone |
| `CONFIG_PINENTRY` | pinentry | Standalone |
| `CONFIG_LVM2` | lvm2 | Standalone |
| `CONFIG_DROPBEAR` | dropbear | Standalone |
| `CONFIG_FLASHTOOLS` | flashtools | Standalone |
| `CONFIG_NEWT` | newt | Standalone |
| `CONFIG_CAIRO` | cairo | Standalone |
| `CONFIG_FBWHIPTAIL` | fbwhiptail | Standalone |
| `CONFIG_HOTPKEY` | hotp-verification | Standalone |
| `CONFIG_MSRTOOLS` | msrtools | Standalone |
| `CONFIG_NKSTORECLI` | nkstorecli | Standalone |
| `CONFIG_UTIL_LINUX` | util-linux | Standalone |
| `CONFIG_OPENSSL` | openssl | Standalone |
| `CONFIG_TPM2_TOOLS` | tpm2-tools | Standalone |
| `CONFIG_TPM2_TOOLS` | tpm-gpio-reset | Standalone |
| `CONFIG_BASH` | bash | Standalone |
| `CONFIG_POWERPC_UTILS` | powerpc-utils | Standalone |
| `CONFIG_IO386` | io386 | Standalone |
| `CONFIG_IOPORT` | ioport | Standalone |
| `CONFIG_KBD` | kbd | Standalone |
| **`CONFIG_ZSTD`** | **zstd** | **Standalone** |
| `CONFIG_E2FSPROGS` | e2fsprogs | Standalone |
| `CONFIG_EXFATPROGS` | exfatprogs | Standalone |
| `CONFIG_NVMUTIL` | nvmutil | Standalone |

## Hardware compatibility list (HCL)

The per-board hardware compatibility list has an intended publication
target in the companion wiki:

<https://osresearch.net/Hardware-Compatibility/>

Each `boards/*/*.config` carries a short hardware-compatibility summary and
preserves its per-board HCL anchor; `unmaintained_boards/*` configs do not.  The
HCL table scope is exactly: Platform, machine type, CPU, maximum RAM,
maximum storage, maximum display, and GPU.  Platform-specific SPI flashing and
USB procedures belong to the
flashing guides, not this HCL page; TPM behavior is documented separately in
[`tpm.md`](tpm.md).  Controller-level implementation coverage is outside this
HCL.

This section is the single place in the repository that records the deployment
status of the companion page.  The page is owned by the separate
[`linuxboot/heads-wiki`](https://github.com/linuxboot/heads-wiki) repository.
It is not live on the intended URL yet: the page remains a draft in
[`heads-wiki#252`](https://github.com/linuxboot/heads-wiki/pull/252), and the
publication target currently returns 404.  The per-board comments therefore
carry a plain "Full details:" URL and a normal summary line, not a published
deep link, and their content does not imply deployment.  Two notes are not
hardware findings of this repository: the X220 i7 discrete-USB-controller
rationale in the two `EOL_x220-*` configs is source-derived from that page and
marked as not independently verified here, and the per-board summaries were
carried from the same draft rather than confirmed against hardware.

## BusyBox applets (default-enabled module)

When `CONFIG_BUSYBOX=y`, BusyBox v1.36.1 provides the following applets relevant
to Heads scripts.  `modules/busybox` sets `CONFIG_BUSYBOX ?= y`, so BusyBox is
included by default but is not unconditional; UROOT-oriented paths can disable
it with `CONFIG_BUSYBOX=n`.

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

### Default-enabled modules and components

These items are enabled by default through `?=` but remain configurable.  Default
location matters: a board or UROOT-path setting of `CONFIG_FOO=n` disables the
corresponding module/component.

| Item | Kind | Default source and effect |
|------|------|--------------------------|
| `busybox` | Module that installs its binary directly | `modules/busybox`: `CONFIG_BUSYBOX ?= y`; can be disabled with `CONFIG_BUSYBOX=n` |
| `zstd` | `bin_modules` module | `modules/zstd`: `CONFIG_ZSTD ?= y` — provides `zstd-decompress` |
| `bash` | `bin_modules` module | `Makefile`: `CONFIG_BASH ?= y` — interactive shell |
| `kbd` | `bin_modules` module | `Makefile`: `CONFIG_KBD ?= y` — keymaps and `loadkeys` |
| `heads.cpio` | Initrd component, not a module | `Makefile`: `CONFIG_HEADS ?= y` selects the Heads base cpio |

Among the `bin_modules` entries listed here, only zstd's default is defined in
a `modules/<name>` file; BusyBox is a separate module that installs its binary
directly.  In every case, `?=` supplies the default only when the board
configuration did not already set the variable.  `CONFIG_HEADS` controls cpio
composition and must not be described as a module target.

### Keymaps

`modules/kbd` stages the keymap tree into `usr/lib/kbd/keymaps`.  The console layout is user-selectable at runtime: `config-gui.sh` browses the shipped keymaps and lets the user pick the layout used at the LUKS passphrase prompt, so the full keymap set is kept.  `loadkeys --default` needs `defkeymap.map`, and the layout `.map` files pull shared fragments from the keymap `include` directories, so those must ship alongside.  A board can set `CONFIG_KBD=n` to omit the keymap tree entirely (the x220 boards do).

### TPM1 vs TPM2 tools

The TPM1 `tpm` mega-binary and its library (`util/tpm` → `bin/tpm`,
`libtpm/libtpm.so`) are built by `modules/tpmtotp`.  They are used only when
`CONFIG_TPM2_TOOLS` is not `y` (TPM1.2 boards); TPM2 boards enable
`CONFIG_TPM2_TOOLS`, which pulls in the `tpm2-tools` module instead, and
`tpmr.sh` dispatches TPM1 vs TPM2 subcommands on that flag.

### Board-enabled modules

These modules default to `n` and must be explicitly enabled in the board config
with `CONFIG_FOO=y` (no `export` needed for inclusion):

```bash
# boards/qemu-coreboot-fbwhiptail-tpm2/qemu-coreboot-fbwhiptail-tpm2.config
CONFIG_GPG2=y          # enables gpg2 module
CONFIG_TPM2_TOOLS=y    # enables tpm2-tools module
```

### Listing default-enabled modules and components

```bash
grep -R -E 'CONFIG_[A-Za-z0-9_]+[[:space:]]*\?=[[:space:]]*y' modules/ Makefile
```

## Available targets

### Module targets

Each `modules/<name>` file generates a Make target.  Build a single
package and its dependencies:

```bash
nix develop --command make BOARD=$BOARD kexec     # kexec-tools
nix develop --command make BOARD=$BOARD linux      # Linux kernel
nix develop --command make BOARD=$BOARD coreboot-25.09 # example: board-selected coreboot source/ROM
```

Full ROM build (all modules + initrd + ROM assembly):

```bash
nix develop --command make BOARD=$BOARD
```

### Maintenance targets

| Target | What it does |
|--------|-------------|
| `real.clean` | `rm -rf` each module build dir under `build/$ARCH/` (all modules except `musl`/`musl-cross-make`), plus `kernel_headers` only when the caller supplies a nonempty value, and wipe `install/*`.  For coreboot, the module dir is board-specific (`coreboot-VERSION/BOARD`), so the nested source clone and its `.git` normally remain; the later overwrite helper can then rewrite the source `.canary`.  Keeps `packages/` and `crossgcc/`.  Destructive last resort. |
| `real.gitclean` | `git clean -fxd` — remove untracked/ignored files, but Git skips nested repositories |
| `real.gitclean_keep_packages` | `git clean -fxd -e "packages"` — keep `packages/`; Git still skips nested repositories |
| `real.remove_canary_files-extract_patch_rebuild_what_changed` | Source/board-output freshness purge: remove every `build/**/.canary`, clear `install/*/*`, remove the board-specific `coreboot-VERSION/<board>` directory including that board's coreboot `.build`, and remove shared board output.  Non-coreboot module trees/objects and their `.build` stamps plus the coreboot source clone normally remain; this is not a from-scratch full rebuild. |
| `real.gitclean_keep_packages_and_build` | `git clean -fxd -e "packages" -e "build"` — keep `packages/` and `build/` |

All run under `nix develop` (local) or `./docker_repro.sh` (Docker):

```bash
nix develop --command make BOARD=$BOARD real.clean
nix develop --command make BOARD=$BOARD real.remove_canary_files-extract_patch_rebuild_what_changed
```

### Rebuild helpers

The build is stamp-driven.  A tarball source recipe extracts the archive,
applies patches, and then creates `.canary`.  A git source recipe attempts to
reset or initialize the pinned source before writing or updating `.canary`; when
`.patched` is absent, its patch branch processes zero or more configured patches
and then creates `.patched`, including the no-patch case.  `.configured`
depends on `.canary`, and `.build` depends on `.configured` and dependency-module
`.build` stamps.  Plain `make` does not
infer arbitrary source-file or `CFLAGS` changes.  The `.clean` targets remove
the selected `.configured` stamps and clean generated outputs while leaving
`.build` in place.  On the next normal build, the regenerated `.configured` file
is newer, so the configured step reruns and the dependent `.build` step follows.
Removing `.build` explicitly is optional when a direct `.build` invocation must
be forced.

Pick the helper by what you changed:

| You need to… | Run |
|---|---|
| change a file inside prepared module source | `<module>.clean`, then `make BOARD=<board> <module>`; touching source alone does not invalidate it, and the normal build reruns `.configured` then `.build` |
| change build flags (`CFLAGS`) | run the relevant `.clean` or `modules.clean` target, then build normally; the selected `.configured` stamps are removed while `.build` remains, so the dependency chain reruns configure and build |
| change board or kernel configuration | plain `make BOARD=<board>` (those config files are explicit prerequisites) |
| change a patch file | for tarball modules remove `.canary`; for git modules remove `.canary` to enter the resynchronization path, which removes `origin`, re-adds it, fetches, resets, cleans, and reapplies patches.  If fetch/reset/permission/network/patch handling fails, remove/recreate the source tree as conservative recovery |
| change an `initrd/` script | plain `make BOARD=<board>`; cpio/initrd measurement recipes are FORCE-driven |
| prove reproducibility is broken | `real.clean` (destructive, last resort) then `make BOARD=<board>` |

Helper → effect, what each removes and keeps:

| Helper | Removes | Keeps |
|---|---|---|
| `<module>.clean` | that module's `.configured`, then `make -C <builddir> clean` (may delete generated sources for `tpm2-tss`/`tpm2-tools`) | `.canary`, **`.build`**; the next normal build reruns `.configured` and then `.build` |
| `modules.clean` | regular-module `make -C <dir> clean` plus selected `.configured` stamps; excludes `musl`, `musl-cross-make`, and `kernel_headers` | `install/`, `packages/`, `.canary`, **`.build`**; normal builds rerun `.configured` then `.build` |
| source/board-output freshness purge (`real.remove_canary_files-…`) | every `build/**/.canary`; `install/*/*`; the board-specific coreboot dir `coreboot-VERSION/<board>` (including that board's coreboot `.build`) and `build/$ARCH/<board>` | non-coreboot module trees/objects and their `.build` stamps; the coreboot source clone and nested `.git` normally remain |
| `real.clean` | each module build dir under `build/$ARCH/` (all modules except `musl`/`musl-cross-make`), `kernel_headers` only when nonempty, and `install/*`; coreboot removes only `coreboot-VERSION/<board>` | `packages/`, `crossgcc/`; the coreboot source clone and nested `.git` normally remain |
| `real.gitclean` | untracked/ignored content outside nested repositories (via `git clean -fxd`) | tracked files and nested Git repositories, including a surviving selected coreboot clone |
| `real.gitclean_keep_packages` | untracked/ignored content outside nested repositories | `packages/`, tracked files, and nested Git repositories, including a surviving selected coreboot clone |
| `real.gitclean_keep_packages_and_build` | untracked/ignored content outside `packages/` and `build/` | `packages/`, the complete `build/` tree, and nested repositories under it |

For a single module whose prepared source or flags changed, clean the selected
module and then run a normal build:

```bash
nix develop --command make BOARD=$BOARD <module>.clean
nix develop --command make BOARD=$BOARD <module>
# Optional when a direct .build invocation must be forced:
# rm -f build/$ARCH/PACKAGE-DIR/.build
```

`<module>.clean` removes `.configured` but not `.build`.  The normal subsequent
build reruns `.configured` and then `.build`; explicit `.build` removal is not
required.

All five `real.*` targets call `overwrite_canary_if_coreboot_git`.  The helper
writes `BOGUS_COMMIT_ID` when the selected coreboot source directory and its
nested `.git` still exist; it is a no-op only when that source clone or `.git`
is actually absent.  `real.clean` and the source/board-output freshness purge
remove only the board-specific `coreboot-VERSION/<board>` directory, so the
source clone and `.git` normally survive and the helper can still write the
placeholder.  `git clean -fxd` skips nested Git repositories, so
`real.gitclean` and `real.gitclean_keep_packages` can also leave a selected
coreboot clone eligible for the placeholder.  `real.gitclean_keep_packages_and_build`
explicitly preserves the build tree and can write it as well.

Two caveats:

- What survives is target-specific.  The freshness purge primarily preserves
  non-coreboot module trees/objects, while the board-specific coreboot directory
  is removed; the coreboot source clone normally remains.  The `git clean`
  targets also skip nested repositories.  The overwrite helper targets only that
  selected coreboot source tree.
- The source/board-output freshness purge cannot fix stale non-coreboot flags
  by itself: those module objects and `.build` stamps survive.  The selected
  board-specific coreboot directory is rebuilt from the retained source clone.
  Run the appropriate clean target,
  then build normally so `.configured` is regenerated before `.build`; explicit
  `.build` removal remains optional.

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

The source and patch work happens inside each module's `.canary` recipe, but
tarball and git modules reach the completed recipe by different branches:

```text
tarball: extract → apply patches → create .canary ┐
git:     init/reset/clean sync → write/update .canary → if .patched absent: process zero or more patches → create .patched ┘
         → .configured → .build → binary → initrd
```

> **Git-source recovery note:** deleting `.canary` on an existing git source
> enters the resynchronization path.  That path removes the existing `origin`
> before adding it again, then fetches, hard-resets, cleans, and reapplies
> patches.  An existing `origin` is therefore not itself a failure condition.
> Network, permission, fetch, reset, clean, or patch-application failures can
> still interrupt the operation.  Removing and recreating the whole source tree
> is conservative recovery when that path fails, not a routine prerequisite
> merely because `origin` already exists.

- **Tarball source branch** extracts the verified archive into
  `build/$ARCH/PACKAGE-DIR/`, applies its patch file or patch directory, and
  then creates `.canary`.
- **Git source branch** initializes or resynchronizes the pinned repository,
  removes/re-adds `origin`, fetches, resets/cleans its worktree, and writes or
  updates `.canary`.  It then checks
  `.patched`; only when the marker is absent does it process zero or more
  configured patches and then create `.patched`.  The branch is otherwise a
  no-op.  The `git clean -df` in the resynchronization branch removes the
  untracked marker before that check, forcing patch reapplication.
- **`.patched`** is created only for git modules and is not a universal target
  between `.canary` and `.configured`.  The tarball branch handles a pre-existing
  marker by reversing/reapplying patches, deleting it, and then creating
  `.canary`.
- **`.configured`** depends on `.canary` and records configure/equivalent setup.
- **`.build`** depends on `.configured` and on dependency modules' `.build`
  stamps; it records compile/install work.

The binary lands in `build/$ARCH/PACKAGE-DIR/$output` and is copied into
the initrd by `bin_modules-$(CONFIG_FOO)`.

### Rebuilding after changing a patch

**The `.canary` sentinel does NOT depend on patch files.**  Modifying a patch
in `patches/PACKAGE-VERSION/` leaves `.canary` up-to-date and the old binary is
used.  The safe invalidation depends on the source type.

**Tarball module:** remove `.canary` to force extraction and patch application:

```bash
rm build/$ARCH/PACKAGE-DIR/.canary
nix develop --command sh -c "make BOARD=$BOARD $PACKAGE"
```

For example, after changing
`patches/kexec-2.0.26/0003-screen_info-normalize-for-VLFB.patch`:

```bash
rm build/x86/kexec-tools-2.0.26/.canary
nix develop --command sh -c "make BOARD=novacustom-nv4x_adl kexec"
```

**Git module:** removing `.canary` enters the normal resynchronization path.  It
removes the existing `origin`, adds it again, fetches the pinned commit,
hard-resets and cleans the worktree, then reapplies patches.  An existing
`origin` alone is not a failure.  Network, permission, fetch, reset, clean, or
patch failures remain possible; remove and recreate the whole git source
directory as conservative recovery if they occur.  Recreating it also removes
its `.configured` and `.build`.

**Broad source/board-output freshness purge** (preserves non-coreboot module
objects and their `.build` stamps, but removes the selected board-specific
coreboot directory including that board's coreboot `.build`, plus shared board
output):

```bash
nix develop --command make BOARD=$BOARD \
  real.remove_canary_files-extract_patch_rebuild_what_changed
nix develop --command make BOARD=$BOARD
```

The helper triggers the normal git resynchronization path, including removal and
re-addition of `origin`.  It can still fail on network, permission, fetch,
reset, clean, or patch errors; use source recreation as conservative recovery
when necessary.

#### Canary-purge and shared-board behavior

`real.remove_canary_files-extract_patch_rebuild_what_changed` explicitly:

- deletes every `build/**/.canary`;
- clears `install/*/*`;
- removes the current board's coreboot build directory
  `build/$ARCH/coreboot-VERSION/$BOARD`; and
- removes `build/$ARCH/$BOARD`, the shared board-output directory owned by the
  kernel/initrd packaging rules.

This removes only the board-specific coreboot build directory.  The nested
coreboot source clone and `.git` normally remain, so
`overwrite_canary_if_coreboot_git` can write `BOGUS_COMMIT_ID` into the surviving
source `.canary`.  It does nothing only when the source clone or `.git` is
actually absent.

A missing module `.canary` requests source preparation.  A tarball module
re-extracts its archive, applies patches, and creates `.canary`.  A git module
removes/re-adds `origin`, fetches and resets/cleans its pinned source
(including untracked `.patched` through `git clean -df`), writes or updates
`.canary`, and, when `.patched` is absent, processes zero or more configured
patches and then creates `.patched` (including no-patch modules).  Network,
permission, fetch, reset, clean, and patch failures remain
possible.  `.configured` and `.build` then follow their normal dependencies.
The standalone git-module recipe
removes only `build/$ARCH/$module-dir/$BOARD`, not the shared
`build/$ARCH/$BOARD` board-output directory.

The purge preserves non-coreboot module objects and their `.build` stamps, while
the selected board-specific coreboot directory (including that board's
coreboot `.build`) and shared board output are removed.  It is therefore a
partial freshness purge, not a from-scratch rebuild.  For a targeted patch
rebuild, use the source-type-specific invalidation described above.
`bin/cpio-clean.pl` preflights named cpio inputs and fails if one
cannot be opened; see
[reproducible-builds.md](reproducible-builds.md#archive-determinism).

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

The `define_module` function in `Makefile` expands the source branches
(source preparation plus patch application) into `.canary`, followed by the
`.configured` → `.build` chain above.  The package name
is the Make target: `make BOARD=... kexec` builds just that package.

### Shared module build flags

Standalone modules each pass their own `CFLAGS`/`LDFLAGS`; these size-oriented
groups are common to most of them:

- `-ffunction-sections -fdata-sections` creates per-function and per-data
  sections, and `-Wl,--gc-sections` can discard sections not reachable from the
  linker's roots.  `-Wl,--no-eh-frame-hdr` suppresses the PT_GNU_EH_FRAME
  program-header entry.  Reachability is link-time reference information, not a
  proof that runtime string/byte inspection needs no code or data: Cairo's
  configure probe is a known example where garbage collection discarded the
  bytes it inspected, so that module supplies an explicit little-endian
  override.
- `-fno-asynchronous-unwind-tables -fno-unwind-tables` asks the compiler not to
  emit asynchronous unwind tables and `.eh_frame` unwind records.  This is safe
  only for modules that do not require exception handling or stack unwinding;
  it should not be copied to a module using C++ exceptions, Rust panics,
  profiler/backtrace support, or similar diagnostics without evaluating that
  dependency.

These flags optimize selected artifacts; they do not by themselves prove the
final ROM or compressed initrd is smaller by a particular amount.  See
[build-artifacts.md](build-artifacts.md#size-and-hash-manifest-semantics) for
what the manifests measure.

## Toolchain Modules

### musl-cross-make

The `MUSL_CROSS_ONCE` guard prevents `modules/musl-cross-make` from being
included multiple times.

The cross-compiler is included **early** in the Makefile so
that `$(CROSS)` and `$(heads_cc)` are available before any userland module is
included.

See `doc/circleci.md` for how CI orchestrates toolchain caching across jobs.
