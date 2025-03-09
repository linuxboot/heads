# T440p Blobs

- [Overview](#overview)
- [Using Your Own Blobs](#using-your-own-blobs)

## Overview

Coreboot on the T440p requires the following binary blobs:

- `me.bin` - Consists of Intel’s Management Engine (ME), which we modify using [me_cleaner](https://github.com/corna/me_cleaner) to remove all but the modules which are necessary for the CPU to function.
- `gbe.bin` - Consists of hardware/software configuration data for the Gigabit Ethernet (GbE) controller. Intel publishes the data structure [here](https://web.archive.org/web/20230122164346/https://www.intel.com/content/dam/www/public/us/en/documents/design-guides/i-o-controller-hub-8-9-nvm-map-guide.pdf), and an [ImHex](https://github.com/WerWolv/ImHex) hex editor pattern is available [here](https://github.com/rbreslow/ImHex-Patterns/blob/rb/intel-ich8/patterns/intel/ich8_lan_nvm.hexpat).
- `ifd.bin` - Consists of the Intel Flash Descriptor (IFD). Intel publishes the data structure [here](https://web.archive.org/web/20221208011432/https://www.intel.com/content/dam/www/public/us/en/documents/datasheets/io-controller-hub-8-datasheet.pdf), and an ImHex hex editor pattern is available [here](https://github.com/rbreslow/ImHex-Patterns/blob/rb/intel-ich8/patterns/intel/ich8_flash_descriptor.hexpat).

Heads supplies an IFD and GbE blob, which we extracted from a donor board. We changed the MAC address of the GbE blob to `00:de:ad:c0:ff:ee` using [nvmutil](https://libreboot.org/docs/install/nvmutil.html), to support anonymity and build reproducibility.

When building any T440p board variant with `make`, the build system will download a copy of the Intel ME. We extract the `me.bin` from a Lenovo firmware update.

### Native Ram Initialization

Note that due to native ram initialization for haswell boards in coreboot it is no longer necessary to use a third party blob (`mrc.bin`) for that.

## Using Your Own Blobs

You can compile Heads using the Intel ME, GbE, and and IFD blobs from your original ROM.

However, it's worth noting that our analysis showed [no tangible difference](https://github.com/osresearch/heads/pull/1282#issuecomment-1386292403) between the Intel ME from a donor board and Lenovo's website. Also, we found [no meaningful difference](https://github.com/osresearch/heads/pull/1282#issuecomment-1400634600) between the IFD and and GbE blobs extracted from two T440ps, asides from the LAN MAC address.

First, make sure you've built Heads at least once in order to download the Coreboot sources:

```console
$ make BOARD=t440p-hotp-maximized
```

Then, supply the path to the Coreboot sources via the `COREBOOT_DIR` environment variable, and run the blob-extraction script:

```console
$ export COREBOOT_DIR="./build/x86/coreboot-4.17/"
$ ./blobs/t440p/extract /path/to/original_rom.bin ./blobs/t440p
```

Now, you can rebuild Heads:

```console
$ make BOARD=t440p-hotp-maximized
```
