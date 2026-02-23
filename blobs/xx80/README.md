# T480 Blobs

The following blobs are needed:

* `ifd.bin`
* `gbe.bin`
* `me.bin`
* `tb.bin` (optional but recommended flashing this blob to the separate Thunderbolt SPI chip to fix a bug in the original firmware)

## me.bin: automatically extract, deactivate, partially neuter and deguard

download_clean_deguard_me_pad_tb.sh : Download vulnerable ME from Dell, verify checksum, extract ME, deactivate ME and paritally neuter it, then apply the deguard patch and place it into me.bin.
For the technical details please read the documentation in the script itself, as removing modules is limited on the platform.

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

## tb.bin

This blob was extracted from https://download.lenovo.com/pccbbs/mobiles/n24th13w.exe
It is zero-padded to 1MB and should be flashed to the Thunderbolt SPI chip, which is not the same as the 16MB chip to which the heads rom is flashed. External flashing is recommended as the only way to reliably fix a bug in the original Thunderbolt software on the SPI chip. You can find a guide here: https://osresearch.net/T480-maximized-flashing/

## Integrity

Sha256sums: `blobs/xx80/hashes.txt`

# CAVEATS for the board:

See the board configs `boards/t480-[hotp-]maximized/t480-[hotp-]maximized.config`:

> This board is vulnerable to a TPM reset attack, i.e. the PCRs are reset while the system is running.
> This attack can be used to bypass measured boot when an attacker succeeds at modifying the SPI flash.
> Also it can be used to extract FDE keys from a TPM.
> The related coreboot issue contains more information: https://ticket.coreboot.org/issues/576
> Make sure you understand the implications of the attack for your threat model before using this board.

# Documentation

A guide on how to flash this board (both the Heads rom and the Thunderbolt `tb.bin` blob) can be found here:
https://osresearch.net/T480-maximized-flashing/

The upstream documentation is available here. It includes a list of known issues: https://doc.coreboot.org/mainboard/lenovo/t480.html
Please note that some of the listed issues have been fixed under heads by using patches that are not yet merged upstream:
* headphone jack works as expected and is automatically detected when plugged in
* thunderbolt works
* lower USB-C port works
