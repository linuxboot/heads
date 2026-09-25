# Build Artifacts and ROM Filename Convention

For architecture and initrd handoff details, see
[architecture.md](architecture.md).  For what `sizes.txt` and `hashes.txt`
measure, see [Size and hash manifest semantics](#size-and-hash-manifest-semantics).

## Common output location

Board outputs are written below `build/<CONFIG_TARGET_ARCH>/<BOARD>/`:

- x86 boards: `build/x86/<BOARD>/`
- ppc64/Talos II: `build/ppc64/UNTESTED_talos-2/`

The architecture is selected by the board config, not inferred from the
firmware filename.

## Common x86 coreboot outputs

A typical non-Talos x86 coreboot build produces:

| File | Purpose |
|------|---------|
| `<basename>.rom` | Full ROM image for external or internal flashing |
| `<basename>-gpg-injected.rom` | ROM with a public key injected by the optional `inject_gpg` step |
| `<basename>.bootblock` | Coreboot bootblock only, when `CONFIG_COREBOOT_BOOTBLOCK` is set |
| `<basename>.zip` | Update package containing the ROM, `sha256sum.txt`, and `hashes.txt` |
| `bzImage` | Linux payload copied from the kernel build tree |
| `initrd.cpio.xz` | External initrd packaged as a separate coreboot CBFS file |

The common x86 `.zip` rule is disabled only for `CONFIG_LEGACY_FLASH=y`
and the Talos II path.  Board-specific split/blob/QEMU behavior does not by
itself disable the common ZIP rule.  `logs.tar.gz` is not in this local-output
table: CircleCI's shared
`build_board` command creates it on every build and stores the board output
directory as a CI artifact.

## Filename format

The common coreboot basename is derived as follows:

```
<lowercase-brand>-<board>-<version-suffix>.rom
```

### Release builds

HEAD must be exactly on a tag and the release check's
`git diff --exit-code` must succeed.  `git diff` checks unstaged tracked files,
so it misses staged-only and untracked changes.  `git describe --dirty` does
detect staged tracked changes, but not untracked files.  Consequently, an exact
tag with staged changes can remain release-classified while its describe value
is dirty, and an exact tag with only untracked changes can look clean to both
checks.  In the ordinary clean case, the suffix is the tag itself:

```
heads-EOL_x230-hotp-maximized-v0.2.1.rom
```

Release names retain the board's full target name, including status prefixes
such as `EOL_` or `UNTESTED_`.

### Development builds

A development suffix has this form:

```
<YYYYMMDD-HHMM>-<git-describe>
```

For example:

```
heads-EOL_x230-hotp-maximized-20260327-2020-v0.2.1-42-g0b9d8e4-dirty.rom
```

- **`YYYYMMDD-HHMM`** is the last commit's committer date at minute
  resolution.  It is a filename prefix, not the build start time and not a
  guaranteed chronological ordering across commits.
- **`git-describe`** is `git describe --abbrev=7 --tags --dirty`.  It carries
  the nearest tag, commit distance, abbreviated commit ID, and dirty marker.
  The current filename convention does not include the git branch name.

Release filenames remain compatible with consumers that expect a tag directly
after the board.  Development consumers should anchor on the board rather than
assuming that a version tag follows it:

```bash
# Board-anchored patterns work for release and development names.
heads-${BOARD}-*.rom
heads-${BOARD}-*.zip

# This is not a general release/development detection rule.
heads-${BOARD}-v*.rom
```

## Architecture-specific output layout

### x86

The maintained x86 coreboot path copies its ROM and optional bootblock into
`build/x86/<BOARD>/` and creates the `.zip` described above.  Its Linux kernel is
`bzImage`; the compressed initrd remains a separate CBFS input selected by
`CONFIG_LINUX_INITRD`.

The unmaintained `CONFIG_LINUXBOOT` path is different.  `modules/linuxboot`
receives external `bzImage` and `initrd.cpio.xz` inputs and copies a completed
`linuxboot.rom` to the board output directory as
`linuxboot-<board>-<GIT_VERSION_SUFFIX>.rom`; that suffix is the release tag
or the development `timestamp-git-describe` value described above.  The initrd
is not described as a coreboot CBFS file on that path.

### ppc64 / IBM Talos II

`UNTESTED_talos-2` sets `CONFIG_TARGET_ARCH=ppc64`.  Its ppc64le Linux payload
sets `CONFIG_LINUX_BUNDLED=y`; the build decompresses `initrd.cpio.xz` to
`initrd.cpio`, rebuilds `zImage` with that initramfs, and copies the result as:

```
build/ppc64/UNTESTED_talos-2/heads-UNTESTED_talos-2-<git-describe>-zImage.bundled
```

The target also emits a coreboot ROM, a bootblock, and:

```
build/ppc64/UNTESTED_talos-2/heads-UNTESTED_talos-2-<git-describe>.tgz
```

The `.tgz` contains the ROM, bootblock, bundled Linux image, and a
`sha256sum.txt` covering those three files.  The Talos target intentionally does
not use the common x86 `.zip` path.

## Downstream integration

### fwupd / LVFS

fwupd identifies firmware by GUID, not by the ROM filename inside a cabinet.
The cabinet's component/version metadata is authoritative.  Release ROM
filenames keep the pre-development form for this reason.

### Artifact upload and download

Workflows should use board-anchored patterns rather than assuming a version tag
immediately follows the board.  The update `.zip`, where produced, is the
preferred artifact for internal update workflows because `flash-gui.sh` checks
its embedded `sha256sum.txt` before flashing.

### Forks

Forks that override `BRAND_NAME` have that value lowercased in common coreboot
filenames.  The Talos `ppc_tgz` target has its own `heads-` prefix convention.

## Size and hash manifest semantics

`build/<arch>/<board>/hashes.txt` and `sizes.txt` are measurement records for
the current `make` invocation.  At Makefile parse time,
`BOARD_LOG := $(shell ...)` writes a fresh build metadata header to both files
before recipes are considered.  Measurement recipes then append their records
when they execute.

- These are rule-dependent records, not complete manifests: only explicit
  measurement recipes append rows.  Components rebuilt through `do-cpio` receive
  an archive row plus per-file sections for their staging directory.  Static
  `dev.cpio`, a direct empty `board.cpio`, and directly generated `u-root.cpio`
  receive neither an independent row nor per-file sections here.
- `sizes.txt` uses `stat -c '%8s:%n'`: the logical byte length
  and name, not the file's
  allocated disk blocks, CBFS member size, flash-region use, or compressed
  contribution to the ROM.
- Every Makefile parse resets both files, including `make -n`, because the
  `BOARD_LOG := $(shell ...)` assignment executes before recipe expansion.
  Measurement recipes append as they execute, including FORCE-driven recipes
  whose output bytes are unchanged.

> **Dry-run warning:** `make -n` is not side-effect-free here.  Its parse still
> resets `hashes.txt` and `sizes.txt`; because recipe measurement commands do not
> run, the files can be left with only their new header.  A dry run or another
> non-default target that executes no measurement recipe can leave header-only
> manifests.  The existing ZIP is not rebuilt merely because these manifests
> were reset, so a local `make -n` or non-ROM target can leave the current
> manifests incomplete while an older ZIP and its copied `hashes.txt` remain.
> CI deletes `*.rom` and `*.zip` before its default build to avoid that stale
> package state.
- Hash and size coverage is rule-dependent.  A target can append a hash without
  a corresponding size (the bundled ppc64 kernel is one current example), so
  do not treat the files as strict one-to-one tables.

Do not add the constituent cpio sizes together and call the result a ROM
payload measurement: compression, CBFS framing, and other ROM contents affect
the final image.  The final ROM row is the logical size of that ROM file, not a
report of how much of a particular SPI/IFD region is available.

An x86 update ZIP copies the current `hashes.txt` only when the ZIP recipe
rebuilds the package.  Resetting the build-directory manifest alone does not
invalidate or rewrite an already-existing ZIP.  Its `sha256sum.txt` covers the
packaged ROM.  In the Talos II `.tgz`, `sha256sum.txt` covers the ROM,
bootblock, and bundled Linux image.  These package checksums and the
build-directory manifests have different scopes.

## Coreboot filename variables

| Variable | Value | Notes |
|----------|-------|-------|
| `HEADS_GIT_VERSION` | `git describe --abbrev=7 --tags --dirty` | Used by the common coreboot names and the Talos package prefix |
| `GIT_TIMESTAMP` | Minute-resolution committer-date prefix from the last commit | Used in the development suffix; not a guaranteed ordering key |
| `GIT_IS_RELEASE` | `y` or `n` | Exact tag plus successful `git diff --exit-code`; staged-only changes can remain release-classified, and untracked changes are missed by both release checks, as described above |
| `GIT_VERSION_SUFFIX` | tag, or `timestamp-git-describe` | Used by common coreboot outputs |
| `CB_OUTPUT_BASENAME` | `<lowercase-brand>-<board>-<GIT_VERSION_SUFFIX>` | Base for common coreboot outputs |
