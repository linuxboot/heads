![Heads boot ROM motd](https://farm9.staticflickr.com/8638/28577284936_c91100d1f7_z_d.jpg)

Heads: the other side of TAILS
===


Heads is a configuration for laptops that tries to bring more security
to commodity hardware.  Among its goals are:

* Use free software on the boot path
* Move the root of trust into hardware (or at least the ROM bootblock)
* Measure and attest to the state of the firmware
* Measure and verify all filesystems

![Flashing Heads into the boot ROM](https://farm9.staticflickr.com/8887/28070128343_b6e942fa60_z_d.jpg)

NOTE: It is a work in progress and not yet ready for users.
If you're interested in contributing, please get in touch.
Installation requires disassembly of your laptop or server,
external SPI flash programmers, possible risk of destruction and
significant frustration.

---

Components:

* CoreBoot
* Linux
* busybox
* kexec
* tpmtotp
* QubesOS (Xen)

---

Notes:

* Building coreboot's cross compilers can take a while.
* Currently only tested in Qemu and on a Thinkpad x230
* Booting Qubes requires patching Xen's real mode startup code;
see `patches/xen-4.6.3.patch` and add `no-real-mode` to start
of the Xen command line.
