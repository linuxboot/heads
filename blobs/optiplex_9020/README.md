# OptiPlex 9020 SFF Blobs

- [Overview](#overview)
- [Blob Strategy](#blob-strategy)
- [Building with Default Blobs](#building-with-default-blobs)
- [Using Your Own Blobs](#using-your-own-blobs)

## Overview

Heads on the Dell OptiPlex 9020 SFF requires three small binary blobs:

| Blob      | Size     | Source                                                   |
|-----------|----------|----------------------------------------------------------|
| `ifd.bin` | 4 KB     | Intel Flash Descriptor, shipped in-tree (anonymized)     |
| `me.bin`  | ~120 KB  | Intel ME, downloaded and neutralized by `download-clean-me` |
| `gbe.bin` | 8 KB     | Intel Gigabit Ethernet config, shipped in-tree (anonymized MAC) |

`ifd.bin` and `gbe.bin` are committed to the repository directly. They contain
no personal data: the GbE MAC is set to the anonymized `00:de:ad:c0:ff:ee`,
matching the convention used by other Heads boards. The IFD has its ME region
shrunk and BIOS region expanded, ready for a neutralized ME.

`me.bin` is the only blob that is **not** committed (it is proprietary Intel
firmware). It is downloaded on demand from the public Lenovo installer
`glrg22ww.exe` -- the same source used by the t440p -- because the ME firmware
is platform-generic for Lynx Point, not vendor-specific.

## Blob Strategy

The Intel ME on the 9020 (Lynx Point, ME 9.x) is **neutralized and shrunk**
using [me_cleaner](https://github.com/corna/me_cleaner) with the flags
`-r -t`:

- `-r` removes non-essential ME modules (TDT, FPF, HOSTCOMM, SESSMGR, ...)
- `-t` truncates the ME region to the minimum bootable size (~120 KB)

Result: ME shrunk from 5 MB to ~120 KB. The remaining FTPR module is required
for power/clock management during boot; it cannot be removed without bricking
the board. The ME's RSA signature remains valid (verified by me_cleaner), so
the board boots.

**Notably NOT required** (this is the blob-minimized setup):

- `mrc.bin` -- eliminated. Haswell native RAM initialization (NRI) is used
  instead, via coreboot's `CONFIG_USE_NATIVE_RAMINIT=y`.
- FSP -- Haswell does not use Intel Firmware Support Package.
- Intel ME in full -- only the ~120 KB FTPR bring-up module remains; all AMT,
  networking, anti-theft and backdoor modules removed.

> **Note on "completely removing" the ME:** The ME is physically present in
> the Lynx Point PCH silicon. Software cannot remove hardware. me_cleaner's
> neutralization is the maximum achievable on this platform.

## Building with Default Blobs

The standard build path downloads and neutralizes the ME automatically:

```console
$ make BOARD=dell-optiplex-9020-sff
```

The build system invokes `download-clean-me` to fetch the Lenovo installer,
extract `ME9.1_5M_Production.bin`, and run me_cleaner. No manual steps
required.

## Using Your Own Blobs

If you prefer to extract the blobs from your own Dell BIOS backup (for
example, to preserve your original LAN MAC address), build Heads once to
download the coreboot sources, then run the extraction script:

```console
$ make BOARD=dell-optiplex-9020-sff          # downloads coreboot sources

$ export COREBOOT_DIR="./build/x86/coreboot-25.09/"
$ ./blobs/optiplex_9020/extract /path/to/original_dell_bios.bin ./blobs/optiplex_9020

$ make BOARD=dell-optiplex-9020-sff          # rebuild with your blobs
```

The extraction script performs a more aggressive neutralization
(`me_cleaner -S -r -t -d`, including soft-disable via the AltMeDisable/HAP
bit) and preserves your hardware's original MAC address.
