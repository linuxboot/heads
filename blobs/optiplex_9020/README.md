# OptiPlex 9020 SFF Blobs

- [Overview](#overview)
- [Blob Strategy](#blob-strategy)
- [Using Your Own Blobs](#using-your-own-blobs)

## Overview

Heads on the Dell OptiPlex 9020 SFF requires three small binary blobs, all
extracted from the user's own Dell BIOS backup. **No proprietary code blobs
are downloaded from third parties** — everything comes from your hardware.

| Blob      | Size     | What it is                                                |
|-----------|----------|-----------------------------------------------------------|
| `ifd.bin` | 4 KB     | Intel Flash Descriptor (resized: ME shrunk, BIOS grown)   |
| `me.bin`  | ~120 KB  | Intel ME, **neutralized + soft-disabled** via me_cleaner |
| `gbe.bin` | 16 KB    | Intel Gigabit Ethernet config (incl. LAN MAC address)    |

**Notably NOT required** (this is the blob-minimized setup):

- `mrc.bin` — **eliminated**. Haswell native RAM initialization (NRI) is used
  instead, via coreboot's `CONFIG_USE_NATIVE_RAMINIT=y`. No proprietary
  memory-init blob.
- FSP — Haswell does not use Intel Firmware Support Package.
- Intel ME in full — only the ~120 KB FTPR bring-up module remains; all AMT,
  networking, anti-theft and backdoor modules removed.

## Blob Strategy

The Intel ME on the 9020 (Lynx Point, ME 9.x) is **neutralized and
soft-disabled** using [me_cleaner](https://github.com/corna/me_cleaner)
with the flags `-S -r -t -d`:

- `-S` sets the AltMeDisable bit (HAP) in PCHSTRP10 → ME disabled after boot
- `-r` removes non-essential ME modules (TDT, FPF, HOSTCOMM, SESSMGR, ...)
- `-t` truncates the ME region to the minimum bootable size (~120 KB)
- `-d` additionally deactivates ME features

Result: ME shrunk from 6 MB → ~120 KB, **98% reduction**. The remaining FTPR
module is required for power/clock management during boot; it cannot be
removed without bricking the board. The ME's RSA signature remains valid
(verified by me_cleaner), so the board boots.

> **Note on "completely removing" the ME:** The ME is physically present in
> the Lynx Point PCH silicon. Software cannot remove hardware. me_cleaner's
> neutralization is the maximum achievable on this platform.

## Using Your Own Blobs

If you have a different Dell 9020 SFF (or want to re-extract from a fresh
backup), first build Heads at least once to download the coreboot sources,
then run the extraction script:

```console
$ make BOARD=dell-optiplex-9020-sff          # downloads coreboot sources

$ export COREBOOT_DIR="./build/x86/coreboot-25.09/"
$ ./blobs/optiplex_9020/extract /path/to/original_dell_bios.bin ./blobs/optiplex_9020

$ make BOARD=dell-optiplex-9020-sff          # rebuild with your blobs
```

The extraction script performs the same operations that produced the blobs
shipped here. Your MAC address will differ; if you want anonymity, override
it to `00:de:ad:c0:ff:ee` using [nvmutil](https://libreboot.org/docs/install/nvmutil.html).
