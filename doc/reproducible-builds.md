# Reproducible Builds

See `doc/docker.md` for build-environment reproducibility.

These practices follow the [reproducible-builds.org](https://reproducible-builds.org/)
project's documentation.  Every mechanism below contributes to producing
bit-identical output across independent environments (CI and local).

## Cross-compiler (musl-cross-make)

`BUILD = x86_64-pc-linux-gnu` pins config.guess so different CI runners
produce the same build triplet instead of probing the Docker host kernel.
`-Wa,--no-pad-sections` prevents gas from padding section ends (non-deterministic
alignment).  `--with-debug-prefix-map=$(pwd)=.` normalizes build paths in debug
info.  `--enable-compressed-debug-sections=no` disables zlib debug-section
compression.  `SOURCE_DATE_EPOCH` from the pinned musl-cross-make commit epoch
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
`KBUILD_BUILD_VERSION=0` pin all kernel build-identity variables.  Modules are
stripped with `strip --strip-debug --preserve-dates`.

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

`BUILD_TIMELESS=1` is passed to coreboot's build to produce reproducible ROMs.

## Busybox

`SOURCE_DATE_EPOCH=0` in `busybox_target` triggers
`patches/busybox-1.36.1/0004-trylink-reproducible.patch`, which disables
ld.bfd `--gc-sections` (ASLR-influenced hash tables in binutils 2.44).
`patches/busybox-1.36.1/0001-messages.patch` replaces `AUTOCONF_TIMESTAMP`
with a fixed `"(heads)"` string.  The install rule copies the binary and runs
`applets/install.sh` directly, avoiding `make install`'s FORCE re-link.

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

`bin/cpio-clean.pl` rewrites every newc cpio entry for determinism: files
sorted by name, inodes derived from MD5(filename), timestamps/uid/gid zeroed,
nlink=0, devmajor/devminor=0, check=0, and 512-byte trailing padding.
`blobs/dev.cpio` is a pre-built, git-tracked archive providing a reproducible
`/dev/console`.

`modules/linux` adds a `FORCE` dependency on `modules.cpio` so `hashes.txt`
is always complete on every rebuild, not just cold builds.  The `do-cpio`
macro uses `cmp --quiet` to short-circuit identical output, avoiding
unnecessary rewrites.

## Tarball downloads

`bin/fetch_source_archive.sh` uses `--timeout=30 --tries=3 -4` (IPv4
preference, fast wget timeout).  All download attempts are logged to
`build/mirror_fallbacks.log`.  `bin/fetch_musl_cross_make_archive.sh`
pre-seeds musl-cross-make component tarballs into `packages/` via
fetch_source_archive.sh.

## Verifying ROM Reproducibility

### Prerequisites
- Same git commit on both CI and local (different commits produce different ROMs — see below)
- Build with `docker_repro.sh` locally (same Docker image as CI)

### Understanding hashes.txt

`build/$ARCH/$BOARD/hashes.txt` records the SHA256 of **every file inside every
cpio archive**, not just the cpio archives themselves.  Each cpio section is
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

### Same commit: everything should match

When CI and local build the **same git commit**, the ROM hash should match.
If it does, the build is reproducible:

```bash
grep '\.rom' /tmp/ci-hashes.txt build/x86/EOL_t480-hotp-maximized/hashes.txt
```

If the ROM differs, step down: `initrd.cpio.xz` → `tools.cpio` →
individual files.  The innermost differing file (e.g. `./bin/busybox`) is the
root cause — fix it and the cascade resolves.  `hashes.txt` records every file
at every level so no diffoscope is needed until you've identified what differs.

For a comprehensive same-commit check:
```bash
diff <(grep '^[0-9a-f]\{64\}' /tmp/ci-hashes.txt | awk '{print $1}' | sort) \
     <(grep '^[0-9a-f]\{64\}' build/x86/EOL_t480-hotp-maximized/hashes.txt | awk '{print $1}' | sort)
```
Zero output = all hashes match.

### Different commits: ROMs always differ

`tools.cpio` contains `./etc/config`, which embeds `GIT_HASH` from
`git rev-parse HEAD`.  Every commit changes `GIT_HASH`, so `./etc/config`
differs between ANY two commits.  This cascades: `./etc/config` → `tools.cpio`
→ `initrd.cpio.xz` → ROM.  The ROM hash WILL differ between different commits —
this is expected.

When `./etc/config` is the **only** differing file inside `tools.cpio`, the
build is still reproducible — all binaries (busybox, kexec, gpg, etc.) are
byte-identical.  A binary mismatch is the actual reproducibility bug to
investigate.
