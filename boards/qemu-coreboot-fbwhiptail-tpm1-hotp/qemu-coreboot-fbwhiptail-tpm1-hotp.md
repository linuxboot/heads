qemu-coreboot-(fb)whiptail-tpm[1,2](-hotp) boards
===

The `qemu-coreboot-fbwhiptail-tpm1-hotp` configuration (and their variants) permits testing of most features of Heads.  
 It requires a supported USB token (which will be reset for use with the VM, do not use a token needed for a
 real machine).  With KVM acceleration, speed is comparable to a real machine.  If KVM is unavailable,
 lightweight desktops are still usable.

Heads is currently unable to reflash firmware within qemu, which means that OEM reset and re-ownership
 cannot be fully performed within the VM.  Instead, a GPG key can be injected in the Heads image from the
 host during the build.

The TPM and disks for this configuration are persisted in the build/qemu-coreboot-fbwhiptail-tpm1-hotp/ directory by default.

Bootstrapping a working system
===

1. Install QEMU and swtpm.  (Optionally, KVM.)
   * Many distributions already package swtpm, but Debian Bullseye does not.  (Bookworm does.)  On Bullseye you will have to build and install libtpms and >
     * https://github.com/stefanberger/libtpms
     * https://github.com/stefanberger/swtpm
2. Build Heads
   * `make BOARD=qemu-coreboot-fbwhiptail-tpm1-hotp`
3. Install OS
   * `make BOARD=qemu-coreboot-fbwhiptail-tpm1-hotp INSTALL_IMG=<path_to_installer.iso> run`
   * Lightweight desktops (XFCE, LXDE, etc.) are recommended, especially if KVM acceleration is not available (such nested in Qubes OS)
   * When running nested in a qube, disable memory ballooning for the qube, or performance will be very poor.
   * Include `QEMU_MEMORY_SIZE=6G` to set the guest's memory (`6G`, `8G`, etc.).  The default is 4G to be conservative, but more may be needed depending on>
   * Include `QEMU_DISK_SIZE=30G` to set the guest's disk size, the default is `20G`.
4. Shut down and boot Heads with the USB token attached, proceed with OEM reset
   * `make BOARD=qemu-coreboot-fbwhiptail-tpm1-hotp USB_TOKEN=<token> run`
   * For `<token>`, use one of:
     * `NitrokeyPro` - a Nitrokey Pro by VID/PID
     * `NitrokeyStorage` - a Nitrokey Storage by VID/PID
     * `LibremKey` - a Librem Key by VID/PID
     * `hostbus=#,hostport=#` - indicate a host bus and port (see qemu usb-host)
     * `vendorid=#,productid=#` - indicate a device by VID/PID (decimal, see qemu usb-host)
   * You _do_ need to export the GPG key to a USB disk, otherwise defaults are fine.
   * Head will show an error saying it can't flash the firmware, continue
   * Then Heads will indicate that there is no TOTP code yet, at this point shut down (Continue to main menu -> Power off)
5. Get the public key that was saved to the virtual USB flash drive
   * `sudo mkdir /media/fd_heads_gpg`
   * `sudo mount ./build/qemu-coreboot-fbwhiptail-tpm1-hotp/usb_fd.raw /media/fd_heads_gpg`
   * Look in `/media/fd_heads_gpg` and copy the most recent public key
   * `sudo umount /media/fd_heads_gpg`
6. Inject the GPG key into the Heads image and run again
   * `make BOARD=qemu-coreboot-fbwhiptail-tpm1-hotp PUBKEY_ASC=<path_to_key.asc> inject_gpg`
   * `make BOARD=qemu-coreboot-fbwhiptail-tpm1-hotp USB_TOKEN=LibremKey PUBKEY_ASC=<path_to_key.asc> run`
7. Initialize the TPM - select "Reset the TPM" at the TOTP error prompt and follow prompts
8. Select "Default boot" and follow prompts to sign /boot for the first time and set a default boot option

You can reuse an already created ROOT_DISK_IMG by passing its path at runtime.
Ex: `make BOARD=qemu-coreboot-fbwhiptail-tpm1 PUBKEY_ASC=~/pub_key_counterpart_of_usb_dongle.asc USB_TOKEN=NitrokeyStorage ROOT_DISK_IMG=~/heads/build/x86/qemu-coreboot-fbwhiptail-tpm1-hotp/root.qcow2 run`

On a daily development cycle, usage looks like:
1. `make BOARD=qemu-coreboot-fbwhiptail-tpm1 PUBKEY_ASC=~/pub_key_counterpart_of_usb_dongle.asc USB_TOKEN=NitrokeyStorage ROOT_DISK_IMG=~/heads/build/x86/qemu-coreboot-fbwhiptail-tpm1-hotp/root.qcow2 inject_gpg`
2. `make BOARD=qemu-coreboot-fbwhiptail-tpm1 PUBKEY_ASC=~/pub_key_counterpart_of_usb_dongle.asc USB_TOKEN=NitrokeyStorage ROOT_DISK_IMG=~/heads/build/x86/qemu-coreboot-fbwhiptail-tpm1-hotp/root.qcow2 run`

The first command builds latest uncommited/unsigned changes and injects the public key inside of the rom to be ran by the second command.
To test across all qemu variants, one only has to change BOARD name and run the two previous commands, adapting `QEMU_MEMORY_SIZE=1G` or modifying the file directly under build dir to adapt to host resources.

swtpm on Debian Bullseye
===

libtpms and swtpm must be built and installed from source on Debian Bullseye. Upstream provides tooling to build these as Debian packages, which allows thi>

1. Install dependencies
   * `sudo apt install automake autoconf libtool make gcc libc-dev libssl-dev dh-autoreconf libssl-dev libtasn1-6-dev pkg-config net-tools iproute2 libjson>
2. Build libtpms
   * `git clone https://github.com/stefanberger/libtpms`
   * `cd libtpms; git checkout v0.9.4` (latest release as of this writing)
   * `sudo mk-build-deps --install ./debian/control`
   * `debuild -us -uc`
   * `sudo apt install ../libtpms*.deb`
3. Build swtpm
   * `git clone https://github.com/stefanberger/swtpm`
   * `cd swtpm; git checkout v0.7.3` (latest release as of this writing)
   * `echo "libtpms0 libtpms" > ./debian/shlibs.local`
   * `sudo mk-build-deps --install ./debian/control`
   * `debuild -us -uc`
   * `sudo apt install ../swtpm*.deb`

