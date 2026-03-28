# Development Workflow

## Commit Conventions

All commits to `linuxboot/heads` must be:

```bash
git commit -S -s -m "component: short description"
```

- **`-S`** — GPG-sign the commit (required; see [CONTRIBUTING.md](../CONTRIBUTING.md))
- **`-s`** — add `Signed-off-by:` trailer for [DCO](https://developercertificate.org/) compliance (required; CI enforces this)

### Message Format

```
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

```
Co-Authored-By: Name <email@example.com>
```

## Documentation: `doc/*.md` vs `heads-wiki`

| Location | Purpose | Signing required |
|----------|---------|-----------------|
| `doc/*.md` in this repo | Developer-facing: architecture, patterns, internals, build conventions | Yes (same as all commits) |
| `linuxboot/heads-wiki` | User-facing: installation, configuration, how-to guides published at osresearch.net | No (lower bar for contribution) |

Content should live in `doc/*.md` when it describes how the code works or how
to build/develop.  Content should live in `heads-wiki` when it describes how a
user installs, configures, or operates a Heads-equipped device.

Over time, `doc/*.md` and the wiki may overlap; the canonical user-facing
source is the wiki.

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
