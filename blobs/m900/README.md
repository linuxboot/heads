# m900_tower Blobs

The following blobs are needed:

* `m900_tower_ifd.bin`
* `m900_tower_gbe.bin`
* `m900_me.bin`

## m900_me.bin: automatically extract, deactivate, partially neuter and deguard

`m900_download_clean_deguard_me.sh`: Download vulnerable ME from ASRock, verify checksum, extract ME, deactivate ME and partially neuter it, then apply the deguard patch and place it into m900_me.bin.
For the technical details please read the documentation in the script itself, as removing modules is limited on the platform.

The ME blob dumped in this directory comes from the following link: https://download.asrock.com/BIOS/1151/H110M-DGS(7.30)ROM.zip


This provides ME version 11.6.0.1126. In this version CVE-2017-5705 has not yet been fixed.
See https://www.intel.com/content/www/us/en/security-center/advisory/intel-sa-00086.html
Therefore, Bootguard can be disabled by deguard with a patched ME.

As specified in the first link, this ME can be deployed to:

* m900_tower/SFF
* optiplex_3050
* m900_tiny


## ifd.bin and gbe.bin

Both blobs are from a production unit of this platform.

The GBE MAC address was forged to: `00:DE:AD:C0:FF:EE`. Unfortunately, after disabling the ME the onboard ethernet stops working. This was tested on coreboot and is true for heads too. So, PCI ethernet or usb/ethernet adapter is needed. 
IFD blob was unlocked using ifdtool. Moreover, to be sure, the HAP bit was set by altmedisable. 
The IFD layout was changed: the bios region was expanded to take space after reducing the me blob. 

## Integrity

Sha256sums: `blobs/m900/hashes.txt`

# CAVEATS for the board:

> This board is vulnerable to a TPM GPIO reset attack, i.e. the PCRs are reset while the system is running.
> This attack can be used to bypass measured boot when an attacker succeeds at modifying the SPI flash.
> Also it can be used to extract FDE keys from a TPM.
> The related coreboot issue contains more information: https://ticket.coreboot.org/issues/576
> Make sure you understand the implications of the attack for your threat model before using this board.

# Documentation

A guide on how to flash this board can be found at https://osresearch.net/m900_tower-maximized-flashing/

The upstream port for the board can be found here: https://review.coreboot.org/c/coreboot/+/74187

