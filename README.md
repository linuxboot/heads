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


Building heads
===

Components:

* CoreBoot
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


Threat model
===
Heads considers two broad classes of threats:

* Attackers with physical access to the system
** Customs officials, LEO, etc with brief access
** "Evil maid" attacks with longer, but still limited access (sans password)
** Stolen machines, with unlimited physical access without password
** Insider attacks with unlimited time, with password
** Insider attacks with unlimited time, with password and without regard for the machine

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
a better root of trust than the EFI configurations, most of which do
not lock the boot ROM.

Even if they are not able to write to the ROM, the attackers might
be able to use their software code execution to modify the system
software or boot partition on the drive.  The recommended OS
configuration is a read-only `/boot` and `/` filesystem, with
only the user data directories writable.  Additional protection
comes from using dm-verity on the file systems, which will
detect any writes to the filesystem through a hash tree
that is signed by the user's (offline) key.

Updates to `/` or `/boot` will require a special boot mode,
which can be selected by the boot firmware.  After the file
systems are updated, the user can sign the new hashes with their
key on a different machine and store the signed root hash on the
drive.  TPM keys might need to be migrated as well for the recovery
boot mode.  On next boot the firmware will mount the drives read-only
and verify that the correct key was used to sign the changes,
and the TPM should be able to unseal the secrets for TPMTOTP
as well as the drive decryption.



---


dm-verity setup
===
*You must install `libdevmapper-dev`, `libpopt-dev` and `libgcrypt-dev` to build cryptsetup*

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

Signing with BSD Signify
---
`signify` is the BSD answer to gpg and openssl in order to sign and verify
packages. We make use of signify because less space is left firmware image and
signify is only around 350kb big therefore it's perfect for us. You can download
signify from this [repository](https://github.com/aperezdc/signify).
In order to create a curve25519 keypair for an eddsa operation execute:

    signify -G -c "roothash key" -p initrd/root.pub -s /path/to/home/root.sec

You will be asked to enter a password and a new keypair is generated.
The signing command works as followed:

    signify -S -s /path/to/root.sec -m roothash

The `roothash` and `roothash.sig` files can be embedded into the
HDD image and then extracted at firmware boot time:

    signify -V -p /root.pub -x roothash.sig -m roothash \
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


CoreBoot console messages
---
The CoreBoot console messages are stored in the CBMEM region
and can be read by the Linux payload with the `cbmem --console | less`
command.  There is lots of interesting data about the state of the
system.
