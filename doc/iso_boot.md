# ISO Boot Parameter Reference

## Design

Heads kexec-boots ISO files from USB by injecting kernel command-line
parameters that tell the target initramfs where to find the ISO on the
USB drive.  The parameters are designed to be universal — every common
Linux distribution's initramfs framework finds the ISO via at least one
of the injected parameters.

## Universal parameter set

The following parameters are injected unconditionally.  Each specifies
the ISO location in a format that a different initramfs framework
understands.  Unrecognised parameters are harmless — the kernel passes
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
- `ISO_PATH` — path to the ISO file relative to the USB device root
  (e.g. `ISOs/debian-live-13.2.0-amd64-xfce.iso`)
- `DEV_UUID` — UUID of the USB block device
- `$ISO_PATH` resolves to the relative path (e.g. `ISOs/file.iso`)
- `/$ISO_PATH` resolves to the absolute path within a mounted device
  (e.g. `/ISOs/file.iso`)
- `$DEV_UUID` resolves to the UUID string
- `/dev/disk/by-uuid/$DEV_UUID` resolves to a stable block device path

## Framework coverage

| Param | live-boot (Debian) | casper (Ubuntu) | dracut (Fedora) | NixOS stage-1 |
|-------|--------------------|-----------------|----------------|---------------|
| `iso-scan/filename=` | — | ✓ scans devices | ✓ scans devices | — |
| `findiso=` | ✓ scans devices | — | — | ✓ scans devices |
| `img_dev=` + `img_loop=` | — | — | — | — |
| `live-media=` | ✓ device filter | ✓ device filter | — | — |

### live-boot (Debian, Tails, Devuan)

`findiso=` scans all block devices, mounts each, and checks for
`${mountpoint}/$FINDISO` — so the value must be a relative path from
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

`iso-scan/filename=` is supported identically to casper — it scans
block devices and loop-mounts the ISO.  `root=live:*` is the primary
specification (LABEL, UUID, CDLABEL, or `/path/file.iso`).

Squashfs lives in `/LiveOS/` by default, but Kicksecure overrides to
`rd.live.dir=live`.

### NixOS stage-1

`findiso=` scans block devices identically to Debian live-boot —
mounts each device and checks for `${mountpoint}$isoPath`.

## Parameter value rules

1. **`iso-scan/filename=/$ISO_PATH`** — relative path prefixed with `/`
   (absolute within the mounted filesystem).  The initramfs mounts each
   block device and checks for the file at that path.

2. **`findiso=/$ISO_PATH`** — same format as `iso-scan/filename=`.
   The initramfs scans block devices for the file.

3. **`img_dev=/dev/disk/by-uuid/$DEV_UUID`** — block device path only
   (no file path appended).

4. **`img_loop=$ISO_PATH`** — relative path without `/` prefix.

5. **`live-media=/dev/disk/by-uuid/$DEV_UUID`** — block device path
   only (no file path appended).  This is NOT a file path — the
   initramfs uses it to identify which device to scan.
