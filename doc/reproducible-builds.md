# Reproducible Builds

See also: [modules.md](modules.md) for module stamps and rebuilds,
[build-artifacts.md](build-artifacts.md#size-and-hash-manifest-semantics) for
artifact measurements, [build-freshness.md](build-freshness.md) for stale-output
debugging, and [docker.md](docker.md) for build-environment pinning.

These practices follow the [reproducible-builds.org](https://reproducible-builds.org/)
project's documentation.  The mechanisms below reduce common sources of build
variation.  They are inputs to a reproducibility comparison, not a guarantee
that independent environments produce bit-identical output.

## Cross-compiler (musl-cross-make)

`BUILD = x86_64-pc-linux-gnu` pins config.guess so different CI runners
produce the same build triplet instead of probing the Docker host kernel.
`-Wa,--no-pad-sections` prevents gas from padding section ends (non-deterministic
alignment).  `--with-debug-prefix-map=$(pwd)=.` normalizes build paths in debug
info.  `--enable-compressed-debug-sections=no` disables zlib debug-section
compression.  `SOURCE_DATE_EPOCH=0` (extracted tarballs lack .git; the build system cannot
derive a commit timestamp from extracted tarballs, so `modules/musl-cross-make` falls back to
`echo 0` when `git log` fails)
prevents `__DATE__`/`__TIME__` embedding during the GCC build.

## Userland compiler flags

`heads_cc` (Makefile) injects `-fdebug-prefix-map=$(pwd)=heads` and
`-gno-record-gcc-switches` for every userland module, normalizing build paths
and suppressing non-deterministic compiler flag recording in debug info.
`modules/libnitrokey` additionally uses `-ffile-prefix-map=$(pwd)=heads`.

## Kernel

`EXTRA_FLAGS` passes `-fdebug-prefix-map=$(pwd)=heads -gno-record-gcc-switches`
to the kernel build.  `KBUILD_BUILD_USER` (pinned to the Linux config filename),
`KBUILD_BUILD_HOST=linuxboot`, `KBUILD_BUILD_TIMESTAMP="1970-00-00"`, and
`KBUILD_BUILD_VERSION=0` pin all kernel build-identity variables.  Kernel
modules are copied with `strip --strip-unneeded --preserve-dates`; for
relocatable kernel modules this removes symbol information that is not needed
for loading while retaining relocation and loader metadata.

## Prefix normalization

Most autotools-based modules use `--prefix "/"` or `--prefix ""` combined
with `DESTDIR="$(INSTALL)"` so generated Makefiles carry fixed paths; the
install target redirects output to the actual build tree.  (`modules/bash`
is an exception, using `--prefix="/usr"`.)  `modules/pciutils` additionally
sets `IDSDIR="/"` and `PREFIX="/"` so `libpci.so.3` is path-independent.

## rpath removal

`modules/gpg2` and `modules/cryptsetup2` use `--disable-rpath` to prevent
build paths from being embedded in binaries.  `modules/tpm2-tss` and
`modules/tpm2-tools` use `sed` to rewrite libtool's `hardcode_libdir_flag_spec`
or `hardcode_into_libs` in generated configure scripts.  `modules/cairo`
rewrites the same variables in the generated `libtool` file post-configure.
`modules/util-linux` removes `.la` libtool files post-install.

## gpg2

`--disable-tpm2d` in `gpg2_configure` eliminates the entire TPM probe chain,
removing the non-deterministic `BUILD_WITH_TPM2D`/`HAVE_INTEL_TSS`/`HAVE_LIBTSS`
defines from `config.h`.

## coreboot

`BUILD_TIMELESS=1` is passed to coreboot's build to omit build-time metadata.
A same-commit ROM comparison is still needed to establish byte identity.

## Busybox

`SOURCE_DATE_EPOCH=0` in `busybox_target` triggers
`patches/busybox-1.36.1/0004-trylink-reproducible.patch`, which disables
ld.bfd `--gc-sections` (ASLR-influenced hash tables in binutils 2.44).
`patches/busybox-1.36.1/0001-messages.patch` replaces `AUTOCONF_TIMESTAMP`
with a fixed `"(heads)"` string.  The install rule copies the binary and runs
`applets/install.sh` directly, avoiding `make install`'s FORCE re-link.

Any exact byte figures attached to local XZ/patch experiments are unverified
local measurements, not CI evidence.  Reproducible or CI confirmation remains a
separate follow-up; the patch files themselves are outside this documentation
correction.

## Patches for reproducibility

| Patch | Mechanism |
|---|---|
| `bash-5.1.16.patch` | Drops `-b` from `mkversion.sh` — removes build timestamp from `version.h` |
| `busybox-1.36.1/0001-messages.patch` | Replaces `AUTOCONF_TIMESTAMP` with fixed `"(heads)"` |
| `busybox-1.36.1/0004-trylink-reproducible.patch` | Disables `--gc-sections` when `SOURCE_DATE_EPOCH` set |
| `coreboot-4.11/0073-build-race-condition-fixes.patch` | Fixes parallel-make race conditions (non-deterministic ordering) |
| `openssl-3.0.8.patch` | `SOURCE_DATE_EPOCH` replaces `time()` in `mkbuildinf.pl`; compiler flags replaced with fixed literal |
| `tpm2-tools-5.6.patch` | Disables `git describe --tags --dirty > VERSION` |

## Version and timestamp pins

| Module | Mechanism |
|---|---|
| `modules/hotp-verification` | `GITVERSION=""` — removes git-derived version string |
| `modules/tpm2-tools` | `echo version > ./VERSION` — pinned version file |
| `modules/bash` | `LDFLAGS="-s"`, `CFLAGS="-g0 -Os"` — strip symbols, no debug |
| `modules/fbwhiptail` | `LDFLAGS="-s"`, `CFLAGS="-g0 -Os"` — strip symbols, no debug |
| `modules/zstd` | `CFLAGS="-g0 -Os"` — no debug info |

## Archive determinism

`bin/cpio-clean.pl` rewrites every newc cpio entry for determinism:
directories first (by full path), then the remaining entries by
(extension, size descending, name); inodes set to 0; timestamps/uid/gid
zeroed, nlink=0, devmajor/devminor=0, check=0, and 512-byte trailing
padding.  The zero inode is safe because nlink is also 0, so the kernel
never builds a hardlink key.  Directories must precede their contents:
the kernel's `init/initramfs.c do_name()` silently skips a file whose
parent directory has not been unpacked yet.  The original full-name sort
already placed parents before children; the `(extension, size, name)`
grouping broke that guarantee, since a dot-directory such as `.gnupg`
(whose basename looks like it has an extension) could sort after the files
it contains, so directories are kept in a leading group.
`blobs/dev.cpio` is a pre-built, git-tracked archive providing a fixed
`/dev/console` input.  Before merging named inputs, `bin/cpio-clean.pl` verifies that
each one can be opened.  An unreadable or missing component therefore aborts the
recipe instead of being silently omitted from the initrd.

`modules/linux` adds a `FORCE` dependency on `modules.cpio` so its archive
hashes and sizes are refreshed on every rebuild, not just cold builds.  The
`do-cpio` macro uses `cmp --quiet` to short-circuit identical output, avoiding
unnecessary rewrites.

## Tarball downloads

`bin/fetch_source_archive.sh` uses `--timeout=30 --tries=3 -4` (IPv4
preference, fast wget timeout).  All download attempts are logged to
`build/mirror_fallbacks.log`.  `bin/fetch_musl_cross_make_archive.sh`
pre-seeds musl-cross-make component tarballs into `packages/` via
fetch_source_archive.sh.

## Comparing ROM output

### Prerequisites
- Same git commit on both CI and local (different commits normally produce different ROMs — see below)
- For a same-CI-image comparison, use the default canonical `docker_repro.sh` path and verify that its resolved digest matches `.circleci/config.yml`.  Pin sources are the `DOCKER_REPRO_DIGEST` environment value when set, otherwise `docker/DOCKER_REPRO_DIGEST`.  A fork/noncanonical repository override can skip the CI cross-check and is not a same-CI-image comparison
- For a same-commit comparison, avoid changes that affect build metadata.  The build's `git diff` check misses staged-only and untracked changes; `git describe --dirty` detects staged tracked changes but not untracked files, so neither path is a complete cleanliness test
- Download CI `hashes.txt` from CircleCI artifacts for the same commit (see
  [Downloading Heads](https://osresearch.net/Downloading) for details).
  Example URL:
  ```bash
  wget -O /tmp/ci-hashes.txt \
    "https://output.circle-artifacts.com/output/job/circleci-job-id/artifacts/0/build/x86/EOL_t480-hotp-maximized/hashes.txt"
  ```

### Output files

Every Makefile parse resets these files under `build/<arch>/<board>/` through
`BOARD_LOG := $(shell ...)`; measurement recipes append their records as they
execute:

| File | Content |
|---|---|
| `hashes.txt` | Rule-dependent records from explicit measurement recipes, not a complete manifest.  `do-cpio` components receive archive rows plus per-file staging-directory sections; static `dev.cpio`, direct empty `board.cpio`, and direct `u-root.cpio` receive neither independent rows nor per-file sections here. |
| `sizes.txt` | GNU `stat` logical byte sizes in `stat -c '%8s:%n'` format.  It is not a CBFS-region, flash-budget, compressed-payload, or disk-allocation report. |
| `sha256sum.txt` | In an x86 update ZIP, SHA-256 of the packaged ROM.  Talos II instead generates a `sha256sum.txt` inside its `.tgz` for the ROM, bootblock, and bundled Linux image. |

`hashes.txt` and `sizes.txt` are rule-dependent records, not complete manifests:
only explicit measurement recipes append rows.

Every Makefile parse resets the manifests before recipes are considered,
including `make -n`, because `BOARD_LOG := $(shell ...)` writes the headers at
parse time.  Measurement recipes then append records, including FORCE-driven
cpio/artifact recipes even when generated bytes are unchanged.

> **Dry-run warning:** `make -n` is not side-effect-free in this build.  It
> resets `hashes.txt` and `sizes.txt` but does not execute the measurement
> recipes, so it can leave both files header-only.  A non-default target that
> executes no measurement recipe can have the same result.  This is not the
> normal result of a default incremental build.  Resetting manifests does not
> rebuild an existing update ZIP: its copied `hashes.txt` can therefore remain
> older.  CI removes `*.rom` and `*.zip` before its default build so the stored
> package is regenerated.

`hashes.txt` and `sizes.txt` are related measurements, not guaranteed
one-to-one: for example, the bundled ppc64 kernel is hashed without a
corresponding `sizes.txt` append.  See
[build-artifacts.md](build-artifacts.md#size-and-hash-manifest-semantics) for the
measurement boundary.

The x86 update ZIP receives a copy of `hashes.txt` only when its ZIP recipe
rebuilds the package; a manifest reset alone does not rewrite an existing ZIP.
Inside a rebuilt ZIP, `hashes.txt` supports same-commit build comparison, while
`sha256sum.txt` is the update package's final-ROM integrity check.

### Understanding hashes.txt

For every cpio component rebuilt through `do-cpio`,
`build/$ARCH/$BOARD/hashes.txt` records the archive's SHA-256 followed by
SHA-256 values for regular files in that component's staging directory.  These
are component measurements, not a separate list extracted from the merged
initrd.  Static `dev.cpio`, direct empty `board.cpio`, and direct
`u-root.cpio` receive neither independent rows nor these per-file sections.
Each `do-cpio` section is
separated by `-----` lines:

```
<hash>  /path/to/modules.cpio
-----
<hash>  ./lib/modules/usbhid.ko
<hash>  ./lib/modules/e1000e.ko
...
-----
<hash>  /path/to/tools.cpio
-----
<hash>  ./bin/busybox
<hash>  ./bin/kexec
...
-----
```

### Same commit: compare the recorded outputs

When CI and local build the **same git commit** with comparable invocations, the
recorded hashes may match.  A match is evidence for the compared artifacts; it
does not by itself establish reproducibility for every board, environment, or
future build.

```bash
grep '\.rom' /tmp/ci-hashes.txt build/x86/EOL_t480-hotp-maximized/hashes.txt
```

If the ROM differs, step down through the entries produced by both runs:
`initrd.cpio.xz`/kernel image → cpio components → individual files.  The first
differing file is a useful starting point, but the manifest covers only files
measured by the recipes that ran.  Use `diffoscope` on the differing artifacts
when the recorded entries do not identify the cause.

For a comprehensive same-commit check:
```bash
diff <(grep '^[0-9a-f]\{64\}' /tmp/ci-hashes.txt | sort) \
     <(grep '^[0-9a-f]\{64\}' build/x86/EOL_t480-hotp-maximized/hashes.txt | sort)
```
Zero output = the recorded hash and path entries match.  This is meaningful
only when both manifests were populated by comparable build invocations; see
[build-freshness.md](build-freshness.md) if a manifest contains only its header.

### Different commits: embedded metadata changes

`tools.cpio` contains `./etc/config`, which embeds `GIT_HASH` from
`git rev-parse HEAD`.  Different commits have different `GIT_HASH` values, so
`./etc/config` differs.  This normally cascades through `tools.cpio` and
`initrd.cpio.xz` into the ROM, making a ROM-hash difference expected.

When `./etc/config` is the **only** differing file inside `tools.cpio`, that
comparison shows the other recorded binary payloads (busybox, kexec, gpg, etc.)
are byte-identical.  A binary mismatch identifies an additional source of
variation to investigate.
