# T480 Blobs

Coreboot on the T480 requires the following binary blobs:

- `me.bin` - Consists of Intel’s Management Engine (ME), which was modified and deguarded using [me_cleaner](https://github.com/corna/me_cleaner) and [deguard](https://codeberg.org/libreboot/deguard) (written by Mate Kukri) to remove all but the modules which are necessary for the CPU to function.
- `tb.bin` - Consists of Thunderbolt firmware. 
- `gbe.bin` - Consists of hardware/software configuration data for the Gigabit Ethernet (GbE) controller. 
- `ifd_16.bin` - Consists of the Intel Flash Descriptor (IFD).

Heads supplies an IFD and GbE blob, which were copied from libreboot. We changed the MAC address of the GbE blob to `00:de:ad:c0:ff:ee` using [nvmutil](https://libreboot.org/docs/install/nvmutil.html), to support anonymity and build reproducibility.

When building any T480 board variant with `make`, the build system will download a copy the Intel ME. `me.bin` was extracted from a  Dell-Inspiron Windows installer firmware update.

