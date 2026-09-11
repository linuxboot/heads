# Flash concepts

Four concepts govern how the flash dispatcher handles writes to the SPI
chip. This document states them concisely for future maintainers and AI agents reading the code.

## 1. Flash paths

The dispatcher supports two write paths:

- **Whole-chip write** (default; `CHANGE_FLASH_OPTIONS` unset or empty):
  rewrites the entire SPI image. Used for firmware upgrades.
- **Region-limited write** (`CHANGE_FLASH_OPTIONS=gbe_only`): rewrites only
  the IFD, Flash Descriptor (`fd`), and GbE regions. Used for narrow
  mutations (MAC randomization).

A third case (`whole_spi`) is reserved for future flows that need
BIOS-region access (e.g. MRC cache preservation, #2138). No caller
exists today.

The caller selects the path via `CHANGE_FLASH_OPTIONS`. The dispatcher
applies the matching `flashprog` invocation and decides whether to
gate runtime-configuration preservation.

## 2. Runtime configuration preservation

Some user data lives on the chip at runtime rather than in the firmware
image: GPG key material, runtime config overrides, secrets for unlocking
storage. These live in CBFS under a known prefix. A whole-chip write
would erase them unless they are explicitly carried forward.

`preserve_rom` snapshots `heads/*` CBFS entries from the running chip
and injects them into the new image before the write. It runs only when
both gates hold:

- The flash is a whole-chip write (not region-limited).
- The flash is not a clean factory wipe (`CLEAN=0`).

Either gate being false independently skips preservation.

## 3. CBFS injection semantics

CBFS injection requires the target image to already contain a BIOS-region
CBFS image for the entry to land in. An image with no BIOS region has
no slot to inject into — the tool fails.

Diagnostic fingerprint: on a region-restricted image, `cbfs -l`
succeeds (returns an empty list) but `cbfs -a` fails. The dispatcher
relies on this to gate the preservation step on whole-chip writes only.

## 4. MAC randomization flow

A user-facing submenu offers three actions:

- **Show current MAC**: region-restricted read (descriptor + fd + GbE),
  extract the address, display it. Read-only.
- **Randomize fully**: read → extract GbE → mutate MAC bytes (any
  locally-administered unicast) → read back to verify → user confirms
  → region-restricted write (GbE only).
- **Randomize with vendor prefix**: same flow but preserves a vendor
  prefix in the upper bytes.

The write touches only the GbE region. The rest of the chip stays
byte-identical. Confirmation gates the write. Any failure funnels to
the recovery shell. A successful or cancelled mutation triggers a
reboot so the session's overridden flash-option state does not leak
into the next action.

## Board name conventions

The codebase matches `CONFIG_BOARD` (board directory name) using POSIX
case + glob:

- `*librem_l1um` — first-gen Librem L1UM (Broadwell-DE). Suffix match
  deliberately excludes `_v2` (Coffee Lake Refresh, different silicon).
- `*talos-2*` — Talos 2 (currently `UNTESTED_talos-2`).
- `qemu-*` — QEMU boards (matched on `CONFIG_BOARD_NAME`).

A literal `librem_l1um` check breaks silently after the EOL migration;
a `CONFIG_BOARD%_*` suffix-strip check fails for `UNTESTED_` prefixes.
Use the case+glob pattern.
