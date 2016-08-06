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


Threat model
---
Heads considers two broad classes of threats:
* Attackers with physical access to the system
* Attackers with ring0 code execution on the runtime system

The first is hardest to deal with since it allows an attacker to
make physical changes to the machine.  Without a hardware root of
trust and secrets stored inside that CPU, it is very difficult to
project against a physical attackers who can replace components and
fake measurements.  Hardware measurements of the boot ROM (such as
Intel's Boot Guard) can help, although a dedicated attacker could
replace the CPU with one that is not fused to do the initial measurement.
The best that we can do is to lock the bootblock on the SPI flash,
perform the first measurement from it and hope that there are not any
exploits against the chip itself.

The second class is also a difficult challenge, but since it is only
a software attack, we have better hopes of handling with some harware
modifications.  The SPI flash chip's boot block protection modes can
be locked on and the WP# pin grounded, which will prevent any software
attacks from overwriting that portion of the boot ROM.  This gives us
a better root of trust than any of the other x86 boot processes,
since we now have 




---

Components:

* CoreBoot
* Linux
* busybox
* kexec
* tpmtotp (with qrencode)
* QubesOS (Xen)

---

Notes:

* Building coreboot's cross compilers can take a while.
* Currently only tested in Qemu and on a Thinkpad x230
* Booting Qubes requires patching Xen's real mode startup code;
see `patches/xen-4.6.3.patch` and add `no-real-mode` to start
of the Xen command line.
* Builds are not reproducible; this is a significant project


dm-verity setup
===
This set of tools isn't the easiest to use.  It is possible to store
hashes on the device that is being hashed if some work is done ahead
of time to reserve the last few blocks or if the file system can be
resized.

The size of the hash table grows logarithmic with the size of the
filesystem.  Every 4K block is hashed, and then 4K of those blocks
are hashed, and so on until there is only one hash left.
Each hash is 32 bytes, so the hash tree size is 32 * log_4096(fs)

The hashes can be stored on a separate device or on the free space
at the end of an existing partition.  This will require resizing
if you didn't allocate the space initially.

The sizes of physical partitions can be read (in 512-byte blocks) from
`/sys/class/block/sda1/size`.  The `resize2fs` tool (assuming you're using
a normal ext4 filesystem) will not resize smaller than the free
space.  Figure out the desired size

    fs_size = $[30 * 1024 * 1024]
    e2fsck hdd.img
    resize2fs hdd.img $fs_size

Once the file system has been resized to make space at the end,
the dm-verity tools can generate the hashes.  The file system
must be unmounted before this is done, otherwise the hashes
will not be correct.

    veritysetup \
	--data-blocks $[$fs_size / 4096] \
	--hash-offset $fs_size \
	format hdd.img hdd.img \
    | tee verity.log

This will output a text file that contains several important
constants for mounting the filesystem later:

    VERITY header information for hdd.img
    UUID:            	73532888-a3e9-4f16-a50a-1d03a265b94f
    Hash type:       	1
    Data blocks:     	7680
    Data block size: 	4096
    Hash block size: 	4096
    Hash algorithm:  	sha256
    Salt:            	3d0cd593d29715005794c4e1cd5164c14ba6456c3dbd2c6d8a26007c01ca9937
    Root hash:      	91beda90d7fa1ab92463344966eb56ec9706f4f26063933a86d701a02a961a10

Unfortunately this is in the wrong form for the `dmsetup` command
and must be reformmated like this:

    dmsetup create vroot --readonly --table \
    "0 61440 verity 1 /dev/sda /dev/sda 4096 4096 7680 7681 sha256 "\
    "c51e171a1403eda7636c89f10d90066d6a593223399fdd4c36ab214da3c6fc11 "\
    "f6c6c6b6cbdf2682d6213e65b0e577cb57c8af3015f88f9a40fb512eaf48aca9"

The 61440 is the number of 512-byte blocks that the filesystem uses.
The two 4096 are the data block size and hash block size.
The 7680 is the number of data blocks and the 7861 is the first
datablock containing hashes (note that block 7680 contains the `VERITY`
header and the salt, but not the root hash).  The hash and salt are
reversed in the order from the `veritysetup` printout.

We sign this command and stash it in the block after the `VERITY`
header so that the firmware can validate the image before mounting it.
This does require that the firmware be able to find the header;
for now we have it hard coded.


mbedtls vs OpenSSL
---
mbedtls is a significantly smaller and more modular library than
OpenSSL's libcrypto (380KB vs 2.3MB).  It is not API compatible,
so applications must be written to use it.

One the build host side we can make use of openssl's tools, but in
the firmware we are limited to the smaller library.  They are mostly
compatible, although the tools are quite different.

Generate the private/public key pair (and copy the public key to
the initrd):

	openssl genrsa -aes256 -out signing.key
	openssl rsa -pubout -in signing.key -out signing.pub

Sign something (requires password and private key):

	openssl pkeyutl \
		-sign \
		-inkey signing.key \
		-in roothash \
		-out roothash.sig

Verify it (requires public key, no password):

	openssl pkeyutl \
		-verify \
		-pubin
		-inkey signing.pub \
		-sigfile roothash.sig \
		-in roothash

but this doesn't work with pk_verify from mbedtls.  more work is necessary.


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

