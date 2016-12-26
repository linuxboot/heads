![Heads boot ROM motd](https://farm9.staticflickr.com/8638/28577284936_c91100d1f7_z_d.jpg)

Heads: the other side of TAILS
===


Heads is a configuration for laptops that tries to bring more security
to commodity hardware.  Among its goals are:

* Use free software on the boot path
* Move the root of trust into hardware (or at least the ROM bootblock)
* Measure and attest to the state of the firmware
* Measure and verify all filesystems

![Flashing Heads into the boot ROM](https://farm1.staticflickr.com/553/30969183324_c31d8f2dee_z_d.jpg)

NOTE: It is a work in progress and not yet ready for users.
If you're interested in contributing, please get in touch.
Installation requires disassembly of your laptop or server,
external SPI flash programmers, possible risk of destruction and
significant frustration.

More information is available in [the 33C3 presentation of building "Slightly more secure systems"](https://trmm.net/Heads_33c3).


Building heads
===

Components:

* coreboot
* Linux
* busybox
* kexec
* tpmtotp (with qrencode)
* QubesOS (Xen)

The top level `Makefile` will handle most of the details -- it downloads
the various packages, patches them, configures and builds, and then
copies the necessary parts into the `initrd` directory.

Notes:
---

* Building coreboot's cross compilers can take a while.  Luckily this is only done once.
* Builds are not reproducible; there are several issue with the [reproduciblebuilds tag](https://github.com/osresearch/heads/issues?q=is%3Aopen+is%3Aissue+milestone%3Areproduciblebuilds) to track it.
* Currently only tested in Qemu and on a Thinkpad x230.  Xen and the TPM do no t work in Qemu, so it is only for testing the `initrd` image.
* Booting Qubes requires patching Xen's real mode startup code
see `patches/xen-4.6.3.patch` and add `no-real-mode` to start
of the Xen command line.  Booting or installing Qubes is a bit hacky and needs to be documented.
* Coreboot 4.4 does not handle initrd separately from the kernel correctly, so it must be bundled into the coreboot image.  Building from git does the right thing.



Signing with GPG
---
`gpgv` is a stripped down version of GPG that can be used to verify
signatures without extraneous libraries.  This works well with the
Free Software workflow that we want to use.

	gpg --clearsign roothash

The `roothash` and `roothash.sig` files can be embedded into the
HDD image and then extracted at firmware boot time:

	gpgv --keyring /trustedkeys.gpg roothash.sig roothash \
	|| echo "FAILED"

The `mount-boot` script is a start at doing this automatically.
There needs to be an empty block at the end of the partition
that includes a signed script to be executed; typically it will
contain the dm-verity parameters to build the `dmsetup` command
line to mount `/boot`.

The boot script can't be stored in the boot filesystem since the
dm-verity hashes that protect the filesystem would need to have their
own hash pre-computed, which is not feasible with a good hashing
algorithm.  You could store the hashes in the ROM, but that would
not allow upgrades without rewriting the ROM.


coreboot console messages
---
The coreboot console messages are stored in the CBMEM region
and can be read by the Linux payload with the `cbmem --console | less`
command.  There is lots of interesting data about the state of the
system.
