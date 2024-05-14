![Heads booting on an x230](https://user-images.githubusercontent.com/827570/156627927-7239a936-e7b1-4ffb-9329-1c422dc70266.jpeg)

Heads: the other side of TAILS
===

Heads is a configuration for laptops and servers that tries to bring
more security to commodity hardware.  Among its goals are:

* Use free software on the boot path
* Move the root of trust into hardware (or at least the ROM bootblock)
* Measure and attest to the state of the firmware
* Measure and verify all filesystems

![Flashing Heads into the boot ROM](https://farm1.staticflickr.com/553/30969183324_c31d8f2dee_z_d.jpg)

NOTE: It is a work in progress and not yet ready for non-technical users.
If you're interested in contributing, please get in touch.
Installation requires disassembly of your laptop or server,
external SPI flash programmers, possible risk of destruction and
significant frustration.

More information is available in [the 33C3 presentation of building "Slightly more secure systems"](https://trmm.net/Heads_33c3).

Documentation
===
Please refer to [Heads-wiki](https://osresearch.net) for your Heads' documentation needs.


Building heads
===

Under QubesOS?
====
* Setup nix persistent layer under QubesOS (Thanks @rapenne-s !)
  * https://dataswamp.org/~solene/2023-05-15-qubes-os-install-nix.html
* Install docker under QubesOS (imperfect old article of mine. Better somewhere?)
  * https://gist.github.com/tlaurion/9113983bbdead492735c8438cd14d6cd

Build docker from nix develop layer locally
====

#### Set up Nix and flakes  

* If you don't already have Nix, install it:  
    * `[ -d /nix ] || sh <(curl -L https://nixos.org/nix/install) --no-daemon`  
    * `. /home/user/.nix-profile/etc/profile.d/nix.sh`  
* Enable flake support in nix  
    * `mkdir -p ~/.config/nix`  
    * `echo 'experimental-features = nix-command flakes' >>~/.config/nix/nix.conf`  

#### Build image

* Build nix developer local environment with flakes locked to specified versions  
    * `nix --print-build-logs --verbose develop --ignore-environment --command true`  
* Build docker image with current develop created environment (this will take a while and create "linuxboot/heads:dev-env" local docker image:  
    * `nix build .#dockerImage && docker load < result` 

Done!

Your local docker image "linuxboot/heads:dev-env" is ready to use, reproducible for the specific Heads commit used and will produce ROMs reproducible for that Heads commit ID.

Jump into nix develop created docker image for interactive workflow
=====
`docker run -e DISPLAY=$DISPLAY --network host --rm -ti -v $(pwd):$(pwd) -w $(pwd) linuxboot/heads:dev-env`


From there you can use the docker image interactively.

`make BOARD=board_name` where board_name is the name of the board directory under `./boards` directory.


One such useful example is to build and test qemu board roms and test them through qemu/kvm/swtpm provided in the docker image. 
Please refer to [qemu documentation](targets/qemu.md) for more information.

Eg:
```
make BOARD=qemu-coreboot-fbwhiptail-tpm2 # Build rom, export public key to emulated usb storage from qemu runtime
make BOARD=qemu-coreboot-fbwhiptail-tpm2 PUBKEY_ASC=~/pubkey.asc inject_gpg # Inject pubkey into rom image
make BOARD=qemu-coreboot-fbwhiptail-tpm2 USB_TOKEN=Nitrokey3NFC PUBKEY_ASC=~/pubkey.asc ROOT_DISK_IMG=~/qemu-disks/debian-9.cow2 INSTALL_IMG=~/Downloads/debian-9.13.0-amd64-xfce-CD-1.iso run # Install
```

Alternatively, you can use locally built docker image to build a board ROM image in a single call.

Eg:
`docker run -e DISPLAY=$DISPLAY --network host --rm -ti -v $(pwd):$(pwd) -w $(pwd) linuxboot/heads:dev-env -- make BOARD=nitropad-nv41`


Pull docker hub image to prepare reproducible ROMs as CircleCI in one call
====
```
docker run -e DISPLAY=$DISPLAY --network host --rm -ti -v $(pwd):$(pwd) -w $(pwd) tlaurion/heads-dev-env:latest -- make BOARD=x230-hotp-maximized
docker run -e DISPLAY=$DISPLAY --network host --rm -ti -v $(pwd):$(pwd) -w $(pwd) tlaurion/heads-dev-env:latest -- make BOARD=nitropad-nv41
```

Maintenance notes on docker image
===
Redo the steps above in case the flake.nix or nix.lock changes. Then publish on docker hub:

```
docker tag linuxboot/heads:dev-env tlaurion/heads-dev-env:vx.y.z
docker push tlaurion/heads-dev-env:vx.y.z
#test against CircleCI in PR. Merge.
#make last version the latest
docker tag tlaurion/heads-dev-env:vx.y.z tlaurion/heads-dev-env:latest
docker push tlaurion/heads-dev-env:latest
```

Notes:
- Local builds can use ":latest" tag, which will use latest tested successful CircleCI run
- To reproduce CirlceCI results, make sure to use the same versioned tag declared under .circleci/config.yml's "image:" 



General notes on reproducible builds
===
In order to build reproducible firmware images, Heads builds a specific
version of gcc and uses it to compile the Linux kernel and various tools
that go into the initrd.  Unfortunately this means the first step is a
little slow since it will clone the `musl-cross-make` tree and build gcc...

Once that is done, the top level `Makefile` will handle most of the
remaining details -- it downloads the various packages, verifies the
hashes, applies Heads specific patches, configures and builds them
with the cross compiler, and then copies the necessary parts into
the `initrd` directory.

There are still dependencies on the build system's coreutils in
`/bin` and `/usr/bin/`, but any problems should be detectable if you
end up with a different hash than the official builds.

The various components that are downloaded are in the `./modules`
directory and include:

* [musl-libc](https://www.musl-libc.org/)
* [busybox](https://busybox.net/)
* [kexec](https://wiki.archlinux.org/index.php/kexec)
* [mbedtls](https://tls.mbed.org/)
* [tpmtotp](https://trmm.net/Tpmtotp)
* [coreboot](https://www.coreboot.org/)
* [cryptsetup](https://gitlab.com/cryptsetup/cryptsetup)
* [lvm2](https://sourceware.org/lvm2/)
* [gnupg](https://www.gnupg.org/)
* [Linux kernel](https://kernel.org)

We also recommend installing [Qubes OS](https://www.qubes-os.org/),
although there Heads can `kexec` into any Linux or
[multiboot](https://www.gnu.org/software/grub/manual/multiboot/multiboot.html)
kernel.

Notes:
---

* Building coreboot's cross compilers can take a while.  Luckily this is only done once.
* Builds are finally reproducible! The [reproduciblebuilds tag](https://github.com/osresearch/heads/issues?q=is%3Aopen+is%3Aissue+milestone%3Areproduciblebuilds) tracks any regressions.
* Currently only tested in QEMU, the Thinkpad x230, Librem series and the Chell Chromebook.
** Xen does not work in QEMU.  Signing, HOTP, and TOTP do work; see below.
* Building for the Lenovo X220 requires binary blobs to be placed in the blobs/x220/ folder.
See the readme.md file in that folder
* Building for the Librem 13 v2/v3 or Librem 15 v3/v4 requires binary blobs to be placed in
the blobs/librem_skl folder. See the readme.md file in that folder

QEMU:
---

OS booting can be tested in QEMU using a software TPM.  HOTP can be tested by forwarding a USB token from the host to the guest.

For more information and setup instructions, refer to the [qemu documentation](targets/qemu.md).

coreboot console messages
---
The coreboot console messages are stored in the CBMEM region
and can be read by the Linux payload with the `cbmem --console | less`
command.  There is lots of interesting data about the state of the
system.
