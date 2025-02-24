# T480 Blobs

The following blobs are needed:

* `ifd.bin`
* `gbe.bin`
* `me.bin`

## me.bin: automatically extract, neuter and deguard

download_clean_me.sh : Download vulnerable ME from Dell, verify checksum, extract ME, neuter ME and trim it, then apply the deguard patch and place it into me.bin

The ME blob dumped in this directory comes from the following link: https://dl.dell.com/FOLDER04573471M/1/Inspiron_5468_1.3.0.exe

This provides ME version 11.6.0.1126. In this version CVE-2017-5705 has not yet been fixed.
See https://www.intel.com/content/www/us/en/security-center/advisory/intel-sa-00086.html
Therefore, Bootguard can be disabled by deguard with a patched ME.

As specified in the first link, this ME can be deployed to:

* T480
* T480s

## ifd.bin and gbe.bin

Both blobs were taken from libreboot: https://codeberg.org/libreboot/lbmk/src/commit/68ebde2f033ce662813dbf8f5ab21f160014029f/config/ifd/t480

The GBE MAC address was forged to: `00:DE:AD:C0:FF:EE MAC`

## Integrity

Sha256sums: `blobs/xx80/hashes.txt`

# CAVEATS for the board:

See the board configs `boards/t480-[hotp-]maximized/t480-[hotp-]maximized.config`:

> This board is vulnerable to a TPM reset attack, i.e. the PCRs are reset while the system is running.
> This attack can be used to bypass measured boot when an attacker succeeds at modifying the SPI flash.
> Also it can be used to extract FDE keys from a TPM.
> The related coreboot issue contains more information: https://ticket.coreboot.org/issues/576
> Make sure you understand the implications of the attack for your threat model before using this board.