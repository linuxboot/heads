# ISO Boot Parameter Reference

## Design

Heads kexec-boots ISO files from USB by injecting kernel command-line
parameters that tell the target initramfs where to find the ISO on the
USB drive.  The parameters are designed to be universal: every common
Linux distribution's initramfs framework finds the ISO via at least one
of the injected parameters.

The layered boot approach (mount ISO -> check initrd compat -> parse
loopback.cfg -> interactive menu) was inspired by
[u-root's boot/iso implementation](https://github.com/u-root/u-root/pull/3578).

## Universal parameter set

The following parameters are injected unconditionally.  Each specifies
the ISO location in a format that a different initramfs framework
understands.  Unrecognised parameters are harmless: the kernel passes
them to userspace and each initramfs ignores what it doesn't understand.

```
iso-scan/filename=/$ISO_PATH
findiso=/$ISO_PATH
img_dev=/dev/disk/by-uuid/$DEV_UUID
img_loop=$ISO_PATH
iso=$DEV_UUID/$ISO_PATH
live-media=/dev/disk/by-uuid/$DEV_UUID
```

Where:
- `ISO_PATH`: path to the ISO file relative to the USB device root
  (e.g. `ISOs/debian-live-13.2.0-amd64-xfce.iso`)
- `DEV_UUID`: UUID of the USB block device
- `$ISO_PATH` resolves to the relative path (e.g. `ISOs/file.iso`)
- `/$ISO_PATH` resolves to the absolute path within a mounted device
  (e.g. `/ISOs/file.iso`)
- `$DEV_UUID` resolves to the UUID string
- `/dev/disk/by-uuid/$DEV_UUID` resolves to a stable block device path

## Framework coverage

| Param | live-boot (Debian) | casper (Ubuntu) | dracut (Fedora) | NixOS stage-1 |
|-------|--------------------|-----------------|----------------|---------------|
| `iso-scan/filename=` |: | ✓ scans devices | ✓ scans devices |: |
| `findiso=` | ✓ scans devices |: |: | ✓ scans devices |
| `img_dev=` + `img_loop=` |: |: |: |: |
| `live-media=` | ✓ device filter | ✓ device filter |: |: |

### live-boot (Debian, Tails, Devuan)

`findiso=` scans all block devices, mounts each, and checks for
`${mountpoint}/$FINDISO`: so the value must be a relative path from
the device root.

`live-media=` narrows the device scan to a specific device.

Squashfs lives in `/live/` on the ISO.

### casper (Ubuntu, PureOS)

`iso-scan/filename=` scans all block devices and looks for the ISO at
the given relative path.  `live-media=` specifies the block device.
`live-media-path` defaults to `casper` and does not need to be
specified.

Squashfs lives in `/casper/` on the ISO.

### dracut/dmsquash-live (Fedora, RHEL, Kicksecure)

`iso-scan/filename=` is supported identically to casper: it scans
block devices and loop-mounts the ISO.  `root=live:*` is the primary
specification (LABEL, UUID, CDLABEL, or `/path/file.iso`).

Squashfs lives in `/LiveOS/` by default, but Kicksecure overrides to
`rd.live.dir=live`.

### NixOS stage-1

`findiso=` scans block devices identically to Debian live-boot
mounts each device and checks for `${mountpoint}$isoPath`.

## Parameter value rules

1. **`iso-scan/filename=/$ISO_PATH`**: relative path prefixed with `/`
   (absolute within the mounted filesystem).  The initramfs mounts each
   block device and checks for the file at that path.

2. **`findiso=/$ISO_PATH`**: same format as `iso-scan/filename=`.
   The initramfs scans block devices for the file.

3. **`img_dev=/dev/disk/by-uuid/$DEV_UUID`**: block device path only
   (no file path appended).

4. **`img_loop=$ISO_PATH`**: relative path without `/` prefix.

5. **`live-media=/dev/disk/by-uuid/$DEV_UUID`**: block device path
   only (no file path appended).  This is NOT a file path: the
   initramfs uses it to identify which device to scan.

## Known Limitations

### Debian DVD (installer) ISOs are not supported

Debian DVD images (e.g. `debian-13.2.0-amd64-DVD-1.iso`) use the
Debian installer initramfs, which is fundamentally different from the
live-boot framework used by Debian Live images.

**How the Debian installer finds media:**

After kexec, `cdrom-detect` in the installer initrd enumerates block
devices via `list-devices cd`, `list-devices usb-partition`, and
`list-devices disk`.  It mounts each device as iso9660 or vfat and
checks for `/cdrom/.disk/info`: it does NOT scan for an ISO file on a
filesystem.

**Why it doesn't work with Heads:**

The loop device Heads uses to mount the ISO at `/boot` does not
survive kexec.  The installer then scans the USB block device
(`/dev/sda`), finds an ext4 partition (Heads' USB format), tries to
mount it as iso9660: which fails: and prompts for manual
configuration.  The installer initrd has no `iso-scan` or `findiso`
support; `iso-scan/filename=` and `findiso=` parameters are ignored.

**Workaround:** Write the ISO directly to a USB drive with `dd` and
boot from Heads' external USB boot option, bypassing the ISO file
approach.

### Graphical output after kexec on coreboot boards

Heads' initrd runs under a kernel compiled with `CONFIG_FB_EFI=y`.
coreboot/libgfxinit initialises the display hardware (PLL, timings,
scanout buffer) and presents it to Linux as an efifb-compatible
framebuffer (`screen_info` set to `VIDEO_TYPE_EFI`).  Heads' kernel
binds efifb, maps the scanout buffer, and the Heads console and
whiptail GUI are visible.  Without this, Heads would have no
framebuffer at all.

After kexec, the display hardware remains in its initialised state
(kexec does not reset devices: the controller keeps scanning out
from the same physical address).  The target kernel must also have
`CONFIG_FB_EFI=y` to adopt the same framebuffer: simplefb and
simpledrm are not compatible.

**Known limitation: lost framebuffer address:**

Linux no longer exposes the physical framebuffer address to userspace.
kexec-tools obtains `smem_start = 0` from `FBIOGET_FSCREENINFO` and
writes `lfb_base = 0` into the new kernel's boot params.  The target
kernel's efifb sees a zero address and cannot map the framebuffer
the display stays blank.

The display controller is still scanning out the correct memory (set
up by coreboot and preserved across kexec), but efifb does not know
where to write because the address was lost in transit.

Historically, Heads worked around this by using i915 with
`CONFIG_DRM_FBDEV_LEAK_PHYS_SMEM=y` (leaking the physical address),
but that was suboptimal.  The current efifb approach is also
suboptimal: we are waiting for improvements in coreboot, Linux, and
kexec-tools to properly convey the framebuffer state across kexec.

**TPM Disk Unlock Key** works around this for encrypted disks by
injecting the LUKS key before kexec: the initramfs never prompts for
a passphrase on a blank display.  Serial console is unaffected.

#### Layer 1 display driver check

Before showing boot options, Heads inspects each initrd for DRM/KMS
kernel modules (i915, nouveau, amdgpu, bochs, virtio-gpu, etc.).
These drivers reinitialize the display after kexec and make the booted
OS visible regardless of efifb availability.

Entries where at least one such driver is found get `[OK]` markers.
Where none is found and the initrd has other loadable modules, a warning
dialog is shown before the boot menu.

#### ISOs without display drivers (CorePlus/TinyCore)

CorePlus and TinyCore ship a minimal kernel that uses `vesafb.ko`
(VESA framebuffer) as its only display driver.  `vesafb` requires
VESA BIOS, which is unavailable under coreboot without a
Compatibility Support Module (CSM).

The ISO's userspace extensions (`Xvesa.tcz`, window managers, etc.)
are loaded by TinyCore's init after boot and do not provide kernel
display drivers.  After kexec, the target kernel has no KMS or
framebuffer driver for any GPU: the display stays blank even though
the OS boots and runs normally.

All other distributions tested (Debian, Ubuntu, Fedora, PureOS,
NixOS, Tails) ship at least one DRM/KMS driver in their initrd and
pass the display check.
