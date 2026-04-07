# Build Artifacts and ROM Filename Convention

## Output Files

A Heads build produces the following artifacts per board:

| File | Purpose |
|------|---------|
| `<basename>.rom` | Full ROM image for external or internal flashing |
| `<basename>-gpg-injected.rom` | ROM with a GPG public key injected (post key-generation step) |
| `<basename>.bootblock` | coreboot bootblock only (board-specific use) |
| `<basename>.zip` | Update package: ROM + `sha256sum.txt`, used by `flash-gui.sh` for verified internal upgrades |
| `linuxboot-<board>-<suffix>.rom` | LinuxBoot variant (where applicable) |

## Filename Format

The basename follows the pattern:

```
<brand>-<board>-<version-suffix>
```

Where `<version-suffix>` differs between release and development builds.

### Release Builds

Condition: HEAD is exactly on a git tag **and** the working tree is clean.

```
heads-x230-v0.2.1.rom
```

`BRAND-BOARD-TAG`

Release filenames are identical to the pre-timestamp convention and safe for
all downstream consumers including LVFS cabinet naming and OEM distribution.

### Development Builds

Condition: any untagged commit, commits ahead of a tag, a dirty working tree,
or a non-release branch.

```
heads-x230-20260327-202007-tpm_reseal_ux-feat-v0.2.1-42-g0b9d8e4-dirty.rom
```

`BRAND-BOARD-YYYYMMDD-HHMMSS-BRANCH-GITDESCRIBE`

- **`YYYYMMDD-HHMMSS`** — timestamp of the last commit (UTC).  Sorts
  chronologically in file managers.  `flash-gui.sh` reverse-sorts the ROM
  list so the newest build appears first.
- **`BRANCH`** — git branch name at build time.  Identifies which PR or
  feature a binary corresponds to without consulting git.
- **`GITDESCRIBE`** — output of `git describe --abbrev=7 --tags --dirty`
  (e.g. `v0.2.1-42-g0b9d8e4-dirty`).  Pinpoints the exact commit.

## Downstream Integration

### Safe glob patterns

```bash
# Always safe — board name is always the second component:
heads-${BOARD}-*.rom
heads-${BOARD}-*.zip

# Breaks for dev builds — tag no longer follows board directly:
heads-${BOARD}-v*.rom   # DON'T USE for dev artifact detection
```

### Parsing the filename structurally

Branch names contain hyphens, so splitting on `-` is ambiguous for dev builds.
Parse by anchoring on the timestamp pattern instead:

```bash
# Extract timestamp from a dev build filename:
basename="heads-x230-20260327-202007-my-feature-v0.2.1-42-gabc1234-dirty"
timestamp=$(echo "$basename" | grep -oP '\d{8}-\d{6}')
```

For release builds there is no timestamp; the third field is the tag directly.

### fwupd / LVFS

fwupd identifies firmware by **GUID**, not filename.  The ROM filename inside
the cabinet (`.cab`) is not parsed for versioning purposes.  The cabinet
metadata (`<component><version>`) carries the authoritative version string.

Release ROM filenames (`heads-x230-v0.2.1.rom`) are unchanged from the
pre-timestamp convention, so existing LVFS submissions are unaffected.

For LVFS pre-release / testing channels, the dev filename carries enough
information (timestamp + branch + git describe) to identify the exact build
without additional metadata.

### CI / GitHub Actions

Workflows that upload or download build artifacts should use the board-anchored
glob (`heads-${BOARD}-*.rom`) rather than the version-anchored form.

The `.zip` update package follows the same naming convention as the `.rom` and
is the preferred artifact for internal upgrade workflows — it includes an
embedded `sha256sum.txt` that `flash-gui.sh` verifies before flashing.

### Dasharo and other forks

Forks that override `BRAND_NAME` in their build will see their brand name
substituted for `heads` in all filenames.  The timestamp and branch logic
applies equally; no fork-specific changes are needed.

## Build Variables (Makefile)

| Variable | Value | Notes |
|----------|-------|-------|
| `HEADS_GIT_VERSION` | `git describe --abbrev=7 --tags --dirty` | Always set |
| `GIT_TIMESTAMP` | `YYYYMMDD-HHMMSS` of last commit | Always set |
| `GIT_BRANCH` | current branch name, truncated to 30 chars | Always set |
| `GIT_IS_RELEASE` | `y` or `n` | `y` only on clean exact tag |
| `GIT_VERSION_SUFFIX` | tag (release) or timestamp-branch-describe (dev) | Used in all output filenames |
| `CB_OUTPUT_BASENAME` | `<brand>-<board>-<GIT_VERSION_SUFFIX>` | Base for all coreboot outputs |
