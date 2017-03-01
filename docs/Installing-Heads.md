![Flashing Heads on an x230 at HOPE](https://pbs.twimg.com/media/CoKJhJHUkAA-MtS.jpg)

Installing Heads
===
These instructions are only for the Lenovo Thinkpad x230 and require physical access to the hardware. There are risks in installation that might brick your system and cause loss of data. You will need another computer to perform the flashing and building steps. If you want to experiment, consider [[Emulating Heads]] with qemu before installing it on your machine.

![Underside of the x230](https://farm9.static.flickr.com/8778/28686026815_6931443f6c.jpg)

Unplug the system and remove the battery while you're disassebling the machine! You'll need to remove the palm rest to get access to the SPI flash chips, which will require removing the keyboard. There are seven screws marked with keyboard and palm rest symbols.

![Keyboard tilted up](https://farm9.static.flickr.com/8584/28653973936_9cffb2a34e.jpg)

The keyboard tilts up on a ribbon cable. You can keep the cable installed, unless you want to swap the keyboard for the nice x220 model.

![Ribbon cable](https://farm8.static.flickr.com/7667/28608155181_fa4a2bfe45.jpg)

The palm rest trackpad ribbon cable needs to be disconnected. Flip up the retainer and pull the cable out. It shouldn't require much force. Once the palmrest is removed you can replace the keyboard screws and operate the machine without the palm rest. Since the thinkpad has the trackpoint, even mouse applications will still work fine.

![Flash chips](https://farm9.static.flickr.com/8581/28401826120_bd8a84e508.jpg)

There are two SPI flash chips hiding under the black plastic, labelled "SPI1" and "SPI2". The top one is 4MB and contains the BIOS and reset vector. The bottom one is 8MB and has the [Intel Management Engine (ME)|https://www.flashrom.org/ME] firmware, plus the flash descriptor.


Using a chip clip and a [SPI programmer](https://trmm.net/SPI_Flash), dump the existing ROMs to files. Dump them again and compare the different dumps to be sure that were no errors. Maybe dump them both a third time, just to be safe.

Ok, now comes the time to write the 4MB `x230.coreboot.bin` file to SPI2 chip. With my programmer and minicom, I hit i to verify that the flash chip signature is correctly read a few times, and then send `u0 400000`↵ to initiate the upload. I then drop to a shell with Control-A J and finally send the file with `pv x230.rom > /dev/ttyACM0`↵. A minute later, I resume minicom and hit i again to check that the chip is still responding.

Move the clip to the SPI1 chip and flash the 8 MB `x230.me.bin` (TODO: document how to produce this with me cleaner). This time you'll send the command `u0 800000`↵. This will wipe out the official Intel firmware, leaving only a stub of it to bring up the Sandybridge CPU before shutting down the ME. As far as I can tell there are no ill effects other than an inability to power off the machine without using the power switch.

Finally, remove the programmer, connect the power supply and try to reboot.

If all goes well, you should see the keyboard LED flash, and within a second the Heads splash screen appear. It currently drops you immediately into the shell, since the boot script portion has not yet been implemented. If it doesn't work, well, sorry about that. Please let me know what the symptoms are or what happened during the flashing.

Congratulations! You now have a Coreboot + Heads Linux machine. Adding your own signing key, installing Qubes and configuring tpmtotp are the next steps and need to be written.

Adding your PGP key
===
To be written; can it be added as a secondary payload?

Configuring the TPM
===
There aren't very many good details on how to setup TPMs, so this section could use some work.

Taking ownership
---
If you've acquired the machine from elsewhere, you'll need to establish physical presence, perform a force clear and take ownership with your own password. Should the storage root key (SRK) be set to something other than the well-known password?

```
physicalpresence -s↵
physicalenable↵
physicalsetdeactivated -c↵
forceclear↵
physicalenable↵
takeown -pwdo OWNER_PASSWORD↵
```

There is something weird with enabling, presence and disabling. Sometimes reboot fixes the state.

tpmtotp
---

![TPMTOTP QR code](https://pbs.twimg.com/media/Cr8x7f6WEAEbBdq.jpg)

Once you own the TPM, run `sealtotp.sh` to generate a random secret, seal it with the current TPM PCR values and store the sealed value in the TPM's NVRAM. This will generate a QR code that you can scan with your google authenticator application and use to validate that the boot block, rom stage and Linux payload are un-altered.

![TPMTOTP output](https://farm8.static.flickr.com/7564/28580109172_5bd759f336.jpg)

On the next boot, or if you run `unsealtotp.sh`, the script will extract the sealed blob from the NVRAM and the TPM will validate that the PCR values are as expected before it unseals it. If this works, the current TOTP will be computed and you can compare this one-time-password against the value that your phone generates.

This does not eliminate all firmware attacks (such as evil maid ones that replace the SPI flash chip), but when combined with the WP# pin and BP bits should eliminate a software only attack.

Installing Qubes
===
The initial installation is a little tricky since you must have a copy of the Heads modified `xen-4.6.3` file available. You can copy it to a separate USB key and mount it by hand or add a new partition to the USB install media and copy the Xen kernel to it. At the Heads recovery shell prompt:

```
mkdir /tmp/alt-media
mount -o ro /dev/sdb3 /tmp/alt-media
cp /tmp/alt-media/xen-4.6.3.gz /
gunzip /xen-4.6.3.gz
umount /tmp/alt-media
```

And then invoke the Qubes installer via this rather long command line:

```
mount -o ro /dev/sdb2 /boot
cd /boot/efi/boot
kexec -l \
  --module "./vmlinuz inst.stage2=hd:LABEL=Qubes-R3.2-x86_64 \
  --module "./initrd.img" \
  --command-line "no-real-mode reboot=no" \
  /xen-4.6.3
```

If that completes with no errors, finally launch the Xen kernel and watch the fireworks:

```
kexec -e
```

My recommended partitioning scheme is 1G for `/boot` since it will hold the dm-verity hashes, 32G for `/`, 32G for swap and the rest for `/home`.  TODO: Filesystem labels?

Once Qubes has finished installing, you'll need to reboot into the Heads recovery shell and copy the `xen-4.6.3` binary to the newly created `/boot` partition and write a short script to setup the kexec parameters. This is another TODO to make it easier.

```
mkdir /tmp/alt-media
mount -o ro /dev/sdb3 /tmp/alt-media
mount -o rw /dev/sda1 /boot
cp /tmp/alt-media/xen-4.6.3.gz /boot/
umount /tmp/alt-media
```

TODO: write start-xen script, figure out where the root UUID comes from.

Run `/boot/start-xen` and `kexec -e` and wait for the Qubes configuration to finish. The defaults are fine.


Installing extra software
---
dom0 probably has updates available. You'll want to install them before switching `/` to read-only and signing the hashes:

```
sudo qubes-dom0-update
```

You'll need the dm-verity tools to enable hashing

```
sudo qubes-dom0-update veritysetup
```

powertop is useful for debugging power drain issues. In dom0 run:

```
sudo qubes-dom0-update powertop
```

You might want to make the middle button into a scroll wheel. Add this to `/etc/X11/xorg.conf.d/20-thinkpad-scrollwheel.conf`

```
Section "InputClass"
	Identifier	"Trackpoint Wheel Emulation"
	MatchProduct	"TPPS/2 IBM TrackPoint|DualPoint Stick|Synaptics Inc. Composite TouchPad / TrackPoint|ThinkPad USB Keyboard with TrackPoint|USB Trackpoint pointing device|Composite TouchPad / TrackPoint"
	MatchDevicePath	"/dev/input/event*"
	Option		"EmulateWheel"		"true"
	Option		"EmulateWheelButton"	"2"
	Option		"Emulate3Buttons"	"false"
	Option		"XAxisMapping"		"6 7"
	Option		"YAxisMapping"		"4 5"
EndSection
```

You'll probably want to enable fan control, as described on [ThinkWiki](http://www.thinkwiki.org/wiki/Fan_control_scripts).

Disabling the ethernet might make sense to save power

Read-only root
---
There are some changes to Qubes' files that have to be made first. [Patches were posted to the qubes-devel list](https://groups.google.com/forum/?fromgroups#!topic/qubes-devel/hG93VcwWtRY), although they need to be updated.

TODO: write a script to apply all of these fixes

Hashing the / partition and setting up dm-verity
---
Signing /boot
---
TPM Disk encryption keys
---
The keys are currently derived only from the user passphrase, which is expanded via the LUKS expansion algorithm to increase the time to brute force it. For extra protection it is possible to store the keys in the TPM so that they will only be released if the PCRs match.

*This section is an early draft*

There are two tools in the Heads ROM image for working with the TPM keys. `seal-key` will generate a new key, seal it with the current PCRs and add a TPM passphrase, then store it into the TPM NVRAM. `unseal-key` will extract it from the NVRAM and request the user passphrase to decrypt/unseal it. If the PCRs do not match, the TPM will reject the attempt (and hopefully dump keys after too many tries?).

To setup the drive encryption, generate and seal a new key. Then unseal it to create `/tmp/secret.key` in the initial ramdisk. Delete the old keys from the root, home and swap partitions (can this use disk labels?):

```
cryptsetup luksKillSlot /dev/sda2 1
cryptsetup luksKillSlot /dev/sda3 1
cryptsetup luksKillSlot /dev/sda5 1
```

Then add the (now cleartext) key to each partition:

```
cryptsetup luksAddKey /dev/sda2 /tmp/secret.key
cryptsetup luksAddKey /dev/sda3 /tmp/secret.key
cryptsetup luksAddKey /dev/sda5 /tmp/secret.key
```

NOTE: should the new LUKS headers be measured and the key re-sealed with those parameters? This is what the Qubes AEM setup uses and is probably a good idea (although we've already attested to the state of the firmware).

This is where things get messy right now. The key file can not persist on disk anywhere, since it would allow an adversary to decrypt the drive. Instead it is necessary to unseal/decrypt the key from the TPM and then bundle the key file into a RAM copy of Qubes' dom0 initrd on each boot. The initramfs format allows concatenated cpio files, so it is easy for the Heads firmware to inject files into the Qubes startup script.

Hardware hardening
===
Soldering jumpers on WP# pins, setting BP bits, epoxy blobs.