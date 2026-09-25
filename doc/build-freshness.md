# Build Freshness Debugging Guide

See also: [modules.md](modules.md#rebuild-helpers) for stamp-driven rebuilds,
[reproducible-builds.md](reproducible-builds.md) for ROM verification,
[build-artifacts.md](build-artifacts.md#size-and-hash-manifest-semantics) for
manifest semantics, and [architecture.md](architecture.md#supported-architectures)
for the x86/ppc64 output split.

## The Problem

Changes to source files in `initrd/` or other build dependencies were not being packed into `initrd.cpio.xz`, causing stale artifacts in the final ROM. The test system showed old commit hashes in `/tmp/config` even after rebuilding.

## initrd.cpio.xz Composition

The final `initrd.cpio.xz` is assembled from four unconditional inputs plus
conditional additions.  Seven component names are defined, but `heads.cpio` and
`u-root.cpio` are alternatives because `CONFIG_UROOT=y` disables `CONFIG_HEADS`;
the selected set therefore contains at most six archives.

| CPIO | Source | Built by | Presence |
|------|--------|----------|----------|
| `dev.cpio` | `blobs/dev.cpio` | Static (pre-built; also embedded in maintained x86 kernels) | Always |
| `modules.cpio` | Linux kernel modules | `modules/linux` | Always |
| `tools.cpio` | Binaries + libraries + **/etc/config** | Makefile | Always |
| `board.cpio` | Board-specific scripts | Makefile | Always; direct empty archive when no files exist |
| `data.cpio` | Configurable module data files | Makefile | Only when enabled modules contribute `*_data` |
| `heads.cpio` | `initrd/*` Heads scripts | Makefile | When `CONFIG_HEADS=y` (default outside u-root) |
| `u-root.cpio` | u-root BusyBox-format cpio | `modules/u-root` | When `CONFIG_UROOT=y`; this path sets `CONFIG_HEADS=n` |

The final packaging rule:
```makefile
$(build)/$(initrd_dir)/initrd.cpio.xz: $(initrd-y)
```

### xz recipe

The final `initrd.cpio.xz` is compressed with:

```makefile
xz --check=crc32 $(INITRD_XZ_ARCH_FILTER) $(INITRD_XZ_FILTER)
```

| Variable | Value | Applies to |
|----------|-------|------------|
| `INITRD_XZ_ARCH_FILTER` | `--x86` | x86 targets only; empty otherwise |
| `INITRD_XZ_FILTER` | `--lzma2=preset=9e,lc=4,lp=0,pb=1,mf=bt3,nice=128` | all targets |

- The x86 BCJ filter only helps x86 code, and its decoder requires
  `CONFIG_XZ_DEC_X86`.  Maintained x86 coreboot kernel configs enable the needed
  XZ options, but the Makefile gates on `CONFIG_TARGET_ARCH=x86`, not decoder
  capability.  `config/linux-linuxboot.config` does not explicitly list
  `CONFIG_RD_XZ`, `CONFIG_XZ_DEC`, or `CONFIG_XZ_DEC_X86`; `modules/linux` runs
  `olddefconfig`, and for Linux 4.14 those options default through Kconfig to
  enabled (`RD_XZ` → `DECOMPRESS_XZ` → `XZ_DEC`, with `XZ_DEC_X86` defaulting
  to `y`).  Generated-config inspection and runtime LinuxBoot boot verification
  remain pending, so omission alone is not a verified decoder limitation.
- The chain must be BCJ then LZMA2; a bare `-9`/`-9e` cannot be combined
  with `--x86` because it replaces the chain, so the level rides on the
  LZMA2 filter as `preset=9e`.
- The comma must live in a variable: make splits `$(call)` arguments on
  commas before expansion.
- `--check=crc32` because the kernel's XZ decoder rejects CRC64.

### Why no BCJ filter on non-x86

An xz stream is a chain of filters.  Here it is an optional Branch/Call/Jump
(BCJ) byte transform followed by LZMA2 compression.  BCJ makes branch targets
more repetitive before LZMA2, but it is part of the stream: a decoder must
support the selected BCJ filter to reverse it before running the LZMA2 decoder.
The transform's reversibility is not a reason to omit decoder support.

On maintained x86 coreboot targets, the component that decodes the final initrd
is the Linux kernel, not BusyBox.  Their kernel configs enable
`CONFIG_XZ_DEC_X86`; this is a configuration property, not something the
current Makefile probes.  `INITRD_XZ_ARCH_FILTER` selects `--x86` solely from
`CONFIG_TARGET_ARCH`.  The LinuxBoot config omits those symbols explicitly, but
`olddefconfig` and Linux 4.14 Kconfig defaults are expected to enable the
required chain.  Generated-config inspection and runtime LinuxBoot boot
verification remain pending; no config fix is inferred from omission alone.

On non-x86 targets the initrd stream is plain LZMA2 without a BCJ transform.
If a kernel must decode an *external* initrd at runtime, that path needs
`CONFIG_RD_XZ=y` together with `CONFIG_XZ_DEC=y`.  LZMA2 itself is
endianness-independent, but a BCJ filter is tied to one instruction encoding.

Talos II ends up with two different XZ streams, and neither is BCJ-filtered:

1. The standalone `initrd.cpio.xz` produced by the recipe above.  The build
   host decompresses it to raw CPIO and embeds that CPIO in `zImage.bundled`,
   so the guest never decodes this stream.  `CONFIG_RD_XZ` is not used on this
   path: there is no external initrd for the kernel to unpack.
2. The kernel's own built-in initramfs inside the ppc64le `zImage`.  It is XZ
   compressed (`CONFIG_INITRAMFS_COMPRESSION_XZ=y`) and the guest decodes it
   through `CONFIG_XZ_DEC=y`.  The image itself is compressed by the PowerPC
   boot wrapper (`arch/powerpc/boot/wrapper`), which runs plain
   `xz --check=crc32 -f -6` and does not use `scripts/xz_wrap.sh`; that is why
   the `powerpc) BCJ=--powerpc` line in `scripts/xz_wrap.sh` has no effect for
   ppc.  The Heads BCJ choice cannot reach this stream in any case, because
   `INITRD_XZ_ARCH_FILTER` applies only to the `initrd.cpio.xz` recipe above.

`--powerpc` was therefore not added.  xz's PowerPC BCJ filter matches
big-endian PowerPC branch encoding, while Talos Linux is ppc64le, so it would
not match the little-endian branch encoding and would yield no useful size
reduction.  It is safe rather than forbidden: `config/linux-talos-2.config`
already sets `CONFIG_XZ_DEC_POWERPC=y`, and the BusyBox BCJ patches below
enable their PowerPC decoder too, so no decoder support would be missing.
Applying a PowerPC BCJ filter to the zImage itself would require an upstream
patch to the PowerPC boot wrapper, not a Heads Makefile option.

These Talos statements are read from the kernel build configuration and the
wrapper code path.  No ppc64 boot harness exists in this tree, so none of them
is a hardware boot result.

The BusyBox BCJ decoder patches in [busybox_perks.md](busybox_perks.md#unxz--xzcat--unlzma--lzcat--lzma)
serve a different path: userspace inspection/decompression of external kernel
images.  They do not supply the Linux kernel's initrd decoder and are not
selected by `INITRD_XZ_ARCH_FILTER`.

## Build Flow

### 1. Initrd Build (Makefile)

```
dev.cpio: static blobs/dev.cpio
modules.cpio: Linux kernel modules
tools.cpio: binaries + libraries + /etc/config (from board .config)
board.cpio: boards/BOARD/initrd/* scripts, or an empty direct archive
data.cpio: module data files (only when contributed)
heads.cpio: initrd/* Heads scripts (CONFIG_HEADS=y)
u-root.cpio: direct u-root cpio (CONFIG_UROOT=y; disables CONFIG_HEADS)

initrd.cpio.xz = cpio-clean(all selected components)
```

**tools.cpio contains /etc/config**:
- Includes `CONFIG_*` variables that the board config marks `export` (not every `CONFIG_*` assignment)
- Adds `GIT_HASH`, `GIT_STATUS`, `CONFIG_BOARD`, and `CONFIG_BRAND_NAME`

### 2. Payload build (selected coreboot module and `modules/linux`)

On maintained x86 coreboot targets, the coreboot build depends on `bzImage` and
`initrd.cpio.xz`.  `CONFIG_LINUX_INITRD` adds the compressed initrd as a
separate CBFS file; it is not embedded inside the `bzImage` payload.  The
unmaintained `CONFIG_LINUXBOOT` path instead passes external `bzImage` and
initrd files to `modules/linuxboot`.

On ppc64/Talos II, `CONFIG_LINUX_BUNDLED=y` makes `modules/linux` decompress
`initrd.cpio.xz` to `initrd.cpio`, rebuild the ppc64le `zImage` with that
initramfs, and emit `zImage.bundled`.  The big-endian coreboot ROM separately
loads skiboot; the Talos `.tgz` ships `zImage.bundled` alongside the ROM and
bootblock rather than embedding it in the coreboot ROM.

### 3. Final output

```
x86 coreboot: build/x86/<board>/<basename>.rom
x86 coreboot: build/x86/<board>/<basename>.zip  # where the update ZIP applies
x86 LinuxBoot: build/x86/<board>/linuxboot-<board>-<GIT_VERSION_SUFFIX>.rom
ppc64: build/ppc64/<board>/<basename>.rom
ppc64: build/ppc64/<board>/heads-<board>-<git-describe>-zImage.bundled
ppc64: build/ppc64/<board>/heads-<board>-<git-describe>.tgz
```

See [build-artifacts.md](build-artifacts.md#architecture-specific-output-layout)
for package contents and the Talos naming exception.

## Dependency Chain

The build system uses file dependencies + FORCE for consistent output:

| Target | Dependencies / production path |
|--------|-------------------------------|
| `dev.cpio` | Static tracked `blobs/dev.cpio`; no recipe |
| `modules.cpio` | Produced by `modules/linux` from the kernel-module staging tree |
| `heads.cpio` | `$(HEADS_INITRD_FILES)` (variable with find results) + FORCE |
| `board.cpio` | `$(BOARD_INITRD_FILES)` + FORCE, or a direct empty-archive rule when no files exist |
| `tools.cpio` | `$(initrd_bins)`, `$(initrd_libs)`, `etc/config` |
| `etc/config` | `$(CONFIG)` |
| `data.cpio` | Staged `*_data` files; created only when `data_files` is nonempty |
| `u-root.cpio` | u-root builder plus optional board `uinit.go`; direct cpio output, not `do-cpio` |
| `initrd.cpio.xz` | `$(initrd-y)` (all selected cpio components) |
| selected coreboot module `.build` (for example, `coreboot-25.09 .build`) | `$(LINUX_IMAGE_FILE)` (`bzImage` on x86, `zImage` on ppc64), `initrd.cpio.xz` |

`hashes.txt` and `sizes.txt` are rule-dependent records, not complete
manifests; only explicit measurement recipes append rows.  Components rebuilt
through the `do-cpio` macro receive an archive row plus per-file sections for
their staging directories.  Static `dev.cpio`, a direct empty `board.cpio`, and
directly generated `u-root.cpio` receive neither an independent row nor per-file
sections here.

**Key insight**: Using `$(shell find ...)` directly in prerequisites causes Make to evaluate the file list ONCE at parse time. Instead, we use variable assignment:
```makefile
HEADS_INITRD_FILES := $(shell find $(pwd)/initrd -type f 2>/dev/null)
$(build)/$(initrd_dir)/heads.cpio: $(HEADS_INITRD_FILES) FORCE
```

This ensures the file list is re-evaluated each time Make runs, properly tracking source file changes.

**Why FORCE?** Make may skip the recipe if it thinks the target is up-to-date based on file timestamps. FORCE ensures the recipe always runs so our do-cpio macro can use `cmp` to check if content actually changed. This provides:
1. **Consistent output** - always shows "CPIO" or "UNCHANGED"
2. **Efficient rebuilds** - actual filesystem write only happens when content differs

FORCE targets run their recipe on every build, but `cmp` preserves the target
when the generated bytes are unchanged.  Non-FORCE targets run only when their
prerequisites are newer or missing.

## Verifying Freshness

### Check if your changes are in the built initrd:

```bash
# Run from the repository root; use an absolute path for the build input.
repo=$PWD
rm -rf /tmp/initrd_check && mkdir /tmp/initrd_check
xz -dc < "$repo/build/x86/BOARD/initrd.cpio.xz" \
  | cpio -idm -D /tmp/initrd_check

# Check your file
grep "your_pattern" /tmp/initrd_check/path/to/file
```

### Check /etc/config (GIT_HASH, CONFIG_*):

```bash
repo=$PWD
xz -dc < "$repo/build/x86/BOARD/initrd.cpio.xz" \
  | cpio -idm -D /tmp/initrd_check
grep -E "GIT_HASH|CONFIG_BOARD" /tmp/initrd_check/etc/config
```

### List all cpio contents:

```bash
xz -dc < build/x86/BOARD/initrd.cpio.xz | cpio -it | head -30
```

### Compare timestamps:

```bash
# Source file
ls -la initrd/bin/oem-factory-reset.sh

# Built initrd
ls -la build/x86/BOARD/initrd.cpio.xz

# Final ROM (use the exact generated filename)
ls -la build/x86/BOARD/heads-BOARD-*.rom
```

Timestamps alone do not prove that content is fresh: FORCE-driven recipes use
`cmp` to preserve an unchanged target's mtime.  Inspect the generated content
or compare the recorded hashes as described in
[reproducible-builds.md](reproducible-builds.md#output-files).

### Check what Makefile thinks is needed:

```bash
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2-hotp -n
```

> **Dry-run warning:** this command is not side-effect-free.  Every Makefile
> parse executes `BOARD_LOG := $(shell ...)`, which resets `hashes.txt` and
> `sizes.txt` before recipe expansion.  `make -n` does not run the measurement
> recipes, so the manifests can be left header-only.  This does not rebuild or
> update an existing ZIP's copied `hashes.txt`; CI deletes `*.rom` and `*.zip`
> before its default build so the package is regenerated.

## Building Fresh

The Docker wrapper is the default for pinned-environment and CI builds; `nix develop`
is the local equivalent.  See `doc/docker.md` for the wrapper.

```bash
# Build in Docker
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2-hotp

# Build in the local Nix environment
nix develop --command make BOARD=qemu-coreboot-fbwhiptail-tpm2-hotp
```

Rebuild guidance lives in the `Rebuild helpers` section of `doc/modules.md`.
Escalation order, least to most destructive:

1. plain `make BOARD=<board>` when the changed file is an explicit prerequisite (for example a board/kernel config or an initrd source handled by a FORCE recipe)
2. targeted output cleanup with `<module>.clean`, then a normal build; `.clean` removes `.configured`, so the build reruns `.configured` and then `.build`
3. regular-module output cleanup with `modules.clean`, then a normal build; this excludes `musl`, `musl-cross-make`, and `kernel_headers`, removes selected `.configured` stamps, and leaves `.build` in place
4. source/board-output freshness purge (`real.remove_canary_files-extract_patch_rebuild_what_changed`; not a from-scratch rebuild)
5. `real.clean` (last resort)

> **Git-source recovery note:** removing `.canary` on an existing git module
> enters the normal resynchronization path.  That path removes the existing
> `origin`, adds it again, fetches, hard-resets, cleans, and reapplies patches;
> an existing `origin` is not itself an error.  Network, permission, fetch,
> reset, clean, and patch failures can still occur.  Removing and recreating the
> source tree is conservative recovery when that path fails.  The broad purge
> preserves non-coreboot module objects and their `.build` stamps, but removes
> the selected board-specific coreboot directory including that board's
> coreboot `.build`, plus shared board output.
