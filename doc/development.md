# Development Workflow

## Commit Conventions

All commits to `linuxboot/heads` must be:

```bash
git commit -S -s -m "component: short description"
```

- **`-S`** — GPG-sign the commit (required; see [CONTRIBUTING.md](../CONTRIBUTING.md))
- **`-s`** — add `Signed-off-by:` trailer for [DCO](https://developercertificate.org/) compliance (required; CI enforces this)

### Message Format

```text
component: short imperative description (72 chars max)

Optional body explaining the why, not the what.  Wrap at 72 chars.
Reference issues or PRs with #NNN.

Signed-off-by: Your Name <email@example.com>
```

- **Subject line**: imperative mood ("fix", "add", "remove", not "fixed"/"adds")
- **Component prefix**: the file or subsystem changed (`oem-factory-reset`, `tpmr`, `gui-init`, `Makefile`, `doc`, etc.)
- **Body**: explain motivation and context; the diff shows what changed

### `Co-Authored-By`

Add a `Co-Authored-By:` trailer only on commits whose **primary content is
collaborative documentation** (`doc/*.md` writing).  Never add it to code
fixes, features, or refactors.

```text
Co-Authored-By: Name <email@example.com>
```

## Documentation: `doc/*.md` vs `heads-wiki`

| Location | Purpose | Signing required |
| -------- | ------- | ---------------- |
| `doc/*.md` in this repo | Developer-facing: architecture, patterns, internals, build conventions | Yes (same as all commits) |
| `linuxboot/heads-wiki` | User-facing: installation, configuration, how-to guides published at osresearch.net | No (lower bar for contribution) |

Content should live in `doc/*.md` when it describes how the code works or how
to build/develop.  Content should live in `heads-wiki` when it describes how a
user installs, configures, or operates a Heads-equipped device.

Over time, `doc/*.md` and the wiki may overlap; the canonical user-facing
source is the wiki.

For CI internals, cache layering, and workspace-vs-cache behavior, see
[circleci.md](circleci.md).
Use the maintainer checklist there when changing `.circleci/config.yml`.

## Build Artifacts

See [build-artifacts.md](build-artifacts.md) for the full ROM filename
convention.  Quick reference:

```bash
# Release build (clean tag, e.g. v0.2.1):
heads-x230-v0.2.1.rom

# Development build (any other state):
heads-x230-20260327-202007-my-feature-branch-v0.2.1-42-g0b9d8e4-dirty.rom
#              ^timestamp  ^branch name           ^git describe
```

The timestamp sorts builds chronologically.  The branch name identifies which
PR or feature a binary corresponds to without consulting git.

When testing a development build, the ROM filename is your primary build
identifier — include it verbatim in bug reports and PR comments.

## Testing Checklist

When touching provisioning code (`oem-factory-reset`, `seal-hotpkey`,
`gui-init`):

- [ ] Run a full OEM Factory Reset / Re-Ownership with custom identity (name + email)
- [ ] Verify `gpg --card-status` reflects cardholder name and login data
- [ ] Verify dongle branding shows correctly for the attached device
- [ ] Verify TOTP/HOTP sealing succeeds after reset
- [ ] Check `/boot` signing succeeds with the new GPG key

When touching the Makefile or build system:

- [ ] Verify dev build filename includes timestamp + branch
- [ ] Verify a locally-tagged clean commit produces the short filename
- [ ] Verify `.zip` package extracts and `sha256sum -c` passes
- [ ] If changing `.circleci/config.yml`, verify the documented cache/workspace
  behavior in [circleci.md](circleci.md) still matches the pipeline

## Coding Conventions

### Shell scripts

- All user-visible output through logging helpers: `STATUS`, `STATUS_OK`,
  `INFO`, `NOTE`, `WARN`, `ERROR`, `DEBUG` (see [logging.md](logging.md))
- Interactive prompts via `INPUT` only — never raw `read`
- All interactive text output routed through `>"${HEADS_TTY:-/dev/stderr}"` to
  avoid interleaving with `DO_WITH_DEBUG` buffered stdout
- Terminology: **passphrase** for TPM/LUKS secrets; **PIN** for GPG smartcard
  (OpenPGP spec); never "password" in user-facing text
- Diceware references when prompting users to choose passphrases

### UX patterns

See [ux-patterns.md](ux-patterns.md) for `INPUT`, `STATUS`/`STATUS_OK`,
`DO_WITH_DEBUG`, `HEADS_TTY` routing, and PIN caching conventions.

## Testing ISO Boot Logic from Host

ISO boot scripts (`kexec-iso-init.sh`, `kexec-parse-boot.sh`, `kexec-select-boot.sh`)
can be tested directly against mounted ISOs without building or running QEMU.

### Heads Runtime Environment

Heads runtime uses:

- **Busybox** (unconditional) — coreutils (ls, cp, mv, dd, find, grep, sed, awk, etc.)
- **Bash** (`CONFIG_BASH=y` by default) — full bash for scripting
- **Shell shebang** — `#!/bin/bash` in scripts (bash is always available)
- **Tools** — kexec, blkid, cpio, xz, zstd, gzip for ISO boot handling

See `config/busybox.config` for busybox features and `boards/*/` for module selection.

### Mount ISO and Test

```bash
# Mount an ISO (fuseiso works without root)
mkdir -p /tmp/iso-test/kicksecure
fuseiso -p /path/to/Kicksecure-LXQt-18.1.4.2.Intel_AMD64.iso /tmp/iso-test/kicksecure

# Test initrd path extraction from GRUB configs
bootdir="/tmp/iso-test/kicksecure"
for cfg in $(find "$bootdir" -name '*.cfg' -type f 2>/dev/null); do
  grep -E "^[ 	]*initrd[ 	]" "$cfg" | while read line; do
    echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="initrd") print $(i+1)}'
  done
done

# Test initramfs unpacking
bash initrd/bin/unpack_initramfs.sh \
  /tmp/iso-test/kicksecure/live/initrd.img-6.12.69+deb13-amd64 \
  /tmp/initrd-unpacked

# Test GRUB config parsing (kexec-parse-boot.sh logic)
bootdir="/tmp/iso-test/kicksecure"
for cfg in $(find "$bootdir" -name '*.cfg' -type f 2>/dev/null); do
  bash initrd/bin/kexec-parse-boot.sh "$bootdir" "$cfg"
done

# Cleanup
fusermount -u /tmp/iso-test/kicksecure
```

### Key Differences from Heads Runtime

| Aspect | Heads Runtime | Host Testing |
|--------|-------------|--------------|
| Root filesystem | Read-only initramfs | Full system |
| `/boot` mount | FUSE/loopback of ISO | Direct ISO mount |
| `blkid` output | ISO9660 with UUID | Same |
| Device paths | `/dev/sda` etc | Same |
| `unpack_initramfs.sh` | Works the same | Works the same |
| Bash | Full bash available | Same |
| Busybox awk | Limited regex (no `[[:space:]]`) | Use `[ \t]` instead |
| TPM/PCR | N/A | N/A |
| GPG keys | Different | Different |

### What Can Be Tested

- ✅ GRUB/ISOLINUX config parsing (`kexec-parse-boot.sh`)
- ✅ Initrd path extraction from configs
- ✅ Initramfs unpacking and module scanning
- ✅ Boot method detection (boot=live, casper, etc.)
- ✅ Path handling (`/boot` prefix stripping)
- ⚠️  Combined boot params (injected params tested conceptually, not end-to-end)
- ❌ Actual `kexec` kernel loading
- ❌ TPM PCR extending
- ❌ Whiptail/GUI dialogs
- ❌ FUSE mount behavior inside initrd

### Test Suite: `tests/iso-parser/run.sh`

The test suite validates ISO boot compatibility:

```bash
cd tests/iso-parser
./run.sh                    # test all ISOs
./run.sh /path/to/iso.iso   # test single ISO
```

Output shows:
- **First section**: ISO metadata (entries count, hybrid MBR, sample boot params)
- **Second section**: Initramfs boot support detection (mechanisms found, compatibility)

Compatibility status:
- **OK**: Known boot mechanism detected → should work via kexec-ISO-boot
- **WARN**: No known mechanism detected → may work but unverified
- **SKIP**: Installer ISO → use dd/Ventoy instead

The test scans both:
1. **Initrd content** (primary): Unpacks initrd and searches for boot mechanisms
2. **Config files** (fallback): Greps *.cfg for known boot params

Runtime injection (not tested):
- `findiso=`, `fromiso=`, `iso-scan/filename=`, `img_dev=`, `img_loop=`
- `live-media=`, `boot=live`, `boot=casper`

These are injected unconditionally by `kexec-iso-init.sh` and combined with
parsed params in `kexec-boot.sh`. Duplicates resolve naturally (kernel uses
last value).
