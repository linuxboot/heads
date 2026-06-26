# ISO Boot Parameter Reference

## Overview

Heads kexec's into target OS kernels from ISO files on a USB drive.
Each distro uses a different initramfs framework to locate and
loopback-mount the ISO file.  Heads injects universal fallback
parameters that cover all common frameworks.

## Initramfs frameworks

| Distro | Framework | ISO detection | Key parameters |
|--------|-----------|---------------|----------------|
| Ubuntu, PureOS | casper | `iso-scan/filename=` | `iso-scan/filename=/$path` |
| Debian, Tails, Kicksecure | live-boot (Debian) | `findiso=` | `boot=live findiso=/$path` |
| Fedora | dracut dmsquash-live | `iso-scan/filename=` + `root=live:` | `root=live:UUID=... iso-scan/filename=/$path` |
| openSUSE | kiwi-live (dracut) | `iso-scan/filename=` + `root=live:` | `root=live:UUID=... iso-scan/filename=/$path` |
| NixOS | custom stage-1 | `findiso=` | `findiso=/$path` |
| Qubes OS | dracut dmsquash-live (Xen) | `inst.repo=hd:` + `iso-scan/filename=` | Xen multiboot2 — not kexec-compatible |
| Samsung SSD firmware | EFI firmware updater | N/A | Requires UEFI runtime — cannot boot under Heads |

### 1. casper (Ubuntu, PureOS)

**init file**: `scripts/casper-premount/20iso_scan` in initramfs

**Parameters:**
- `iso-scan/filename=/$path` — path to ISO on a partition (REQUIRED)
- `fromiso=/$path` — alternative (GRUB-originated)
- `live-media=$dev` — restrict scanning to specific device
- `live-media-path=/casper` — path to live filesystem inside ISO

**How it works:**
1. `20iso_scan` reads `iso-scan/filename=` from cmdline
2. Calls `find_path "${iso_path}" /isodevice rw`
3. `find_path` scans `/sys/block/*` (excludes RAM, LOOP, FD)
4. For each partition: mounts, checks `[ -e "${mountpoint}${path}" ]`
5. On match: writes `LIVEMEDIA=${FOUNDPATH}` to `/conf/param.conf`
6. Other scripts mount the ISO and pivot to the squashfs root

**Partition table required.** Without one, BusyBox `fstype` may not detect
ext4 on whole-disk filesystems, and the device is skipped.

### 2. live-boot (Debian, Tails, Kicksecure)

**init file**: `/lib/live/boot/9990-misc-helpers.sh` in initramfs

**Parameters:**
- `boot=live` — activates live-boot initramfs pipeline (REQUIRED)
- `findiso=/$path` — path to ISO on any partition (REQUIRED)
- `fromiso=<$dev>$path` — alternative ISO source
- `live-media=$dev` — restrict scanning to specific device
- `live-media-path=$path` — path to squashfs inside ISO (default: `live`)
- `noeject` — don't eject CD after boot

**How it works:**
1. `init` reads `boot=live` → sources `/scripts/live`
2. `Cmdline_old()` in `9990-cmdline-old.sh` parses all parameters
3. `find_livefs()` iterates block devices, calls `check_dev()`
4. For each partition: mounts, checks `[ -f "${mountpoint}/${FINDISO}" ]`
5. On match: unmounts USB → remounts at `/run/live/findiso` →
   `losetup` the ISO → mounts ISO9660 → finds squashfs at `$LIVE_MEDIA_PATH`

### 3. dmsquash-live (Fedora, dracut-based)

**init file**: `/usr/lib/dracut/hooks/cmdline/30-parse-dmsquash-live.sh`

**Parameters:**
- `root=live:*` — **REQUIRED** for dmsquash-live module activation
  - `root=live:UUID=$uuid` — find by filesystem UUID
  - `root=live:CDLABEL=$label` — find by volume label
  - `root=live:LABEL=$label` — find by filesystem label
  - `root=live:/dev/$dev` — direct device path
  - `root=live:/$path/file.iso` — ISO file on partition (→ `liveiso:`)
- `iso-scan/filename=/$path` — path to ISO on partition
- `rd.live.dir=LiveOS` — directory with squashfs (default: `LiveOS`)
- `rd.live.squashimg=squashfs.img` — squashfs filename
- `rd.live.ram` — copy to RAM before boot
- `rd.live.overlay.*` — persistent overlay options

**How it works:**
1. `30-parse-dmsquash-live.sh` parses `root=live:*` → sets `liveroot`
2. `31-parse-iso-scan.sh` parses `iso-scan/filename=` → runs `iso-scan`
3. `iso-scan` scans block devices by UUID, mounts, checks file path
4. On match: `losetup` the ISO → udev trigger fires for the loop device
5. `dmsquash-live-root` finds `LiveOS/squashfs.img` on the loop device,
   mounts it as the root filesystem

**`root=live:` is mandatory.** Without it, the dmsquash-live module
never activates.  `iso-scan/filename=` alone is NOT sufficient for Fedora.

### 4. kiwi-live (openSUSE, dracut-based)

**init file**: `/usr/lib/dracut/hooks/cmdline/30-parse-kiwi-live.sh`

**Parameters:**
- `root=live:*` — required (same syntax as dmsquash-live)
- `iso-scan/filename=/$path` — optional, for file-based ISO discovery

**How it works:** Same structure as Fedora's dmsquash-live, but uses
`kiwi-live-lib.sh` for the actual mount/overlay logic.  The ISO is
found via UUID or device scanning, loopback-mounted, and the squashfs
image is used as the root filesystem.

### 5. NixOS stage-1

**Parameters:**
- `findiso=/$path` — path to ISO on any partition
- `boot.debug=1` — debug output

**How it works:** Custom `stage-1` init script scans block devices,
mounts, and looks for the path specified by `findiso=`.  On match,
loopback-mounts the ISO and pivots to the squashfs root.

## Heads parameter injection

The function `_build_universal_add()` in `initrd/bin/kexec-iso-init.sh`
builds a fallback parameter string covering all frameworks:

```bash
result="iso-scan/filename=/$iso_path findiso=/$iso_path \
    img_dev=$iso_dev img_loop=$iso_path \
    iso=$iso_id/$iso_path live-media=$iso_dev"
```

This is used as a fallback when the ISO's loopback.cfg has no resolvable
GRUB variables.  When GRUB var references are detected, they are
stripped (removed) — the remaining non-ISO tokens are kept, and the
the universal params are appended as extras (each framework ignores
what it doesn't understand).

### What's covered

| Framework | Uses | Notes |
|-----------|------|-------|
| casper (Ubuntu) | `iso-scan/filename=` | ✅ Works |
| live-boot (Debian) | `findiso=` | ✅ Works (`boot=live` comes from ISO's own cfg) |
| dmsquash-live (Fedora) | `iso-scan/filename=` + needs `root=live:` | ⚠️ `root=live:` only from ISO's own cfg |
| kiwi-live (openSUSE) | `iso-scan/filename=` + needs `root=live:` | ⚠️ Same — relies on ISO's own cfg |
| NixOS | `findiso=` | ✅ Works |

### Parameters NOT handled by each framework

| Parameter | casper | live-boot | dmsquash | kiwi | NixOS |
|-----------|--------|-----------|----------|------|-------|
| `iso-scan/filename=` | ✅ | ❌ | ✅ | ✅ | ❌ |
| `findiso=` | ❌ | ✅ | ❌ | ❌ | ✅ |
| `img_dev=` | ❌ | ❌ | ❌ | ❌ | ❌ |
| `img_loop=` | ❌ | ❌ | ❌ | ❌ | ❌ |
| `iso=` | ❌ | ❌ | ❌ | ❌ | ❌ |
| `live-media=` | ✅ | ✅ | ❌ | ❌ | ❌ |
| `boot=live` | ❌ | ✅ | ❌ | ❌ | ❌ |
| `root=live:*` | ❌ | ❌ | ✅ | ✅ | ❌ |

These parameters are harmless extras — each framework silently ignores
parameters it doesn't recognize.

### Known limitations

**Fedora (dmsquash-live):** Requires `root=live:` to activate the live
pipeline.  Heads' universal fallback does NOT include this parameter
because it varies per ISO (CDLABEL, UUID, or device path).  When the
ISO's loopback.cfg or grub.cfg is parsed, the original `root=live:`
from the ISO is preserved.  Only when the fallback is used (no GRUB
vars), `root=live:` is missing, and Fedora falls back to the disk
installer instead of live boot.

**Partition table requirement:** casper's `find_path()` uses BusyBox
`fstype` which may not detect ext4 on whole-disk filesystems (no
partition table).  The QEMU USB image creation in `targets/qemu.mk`
now creates an MBR partition table + single ext4 partition to
work around this.

## Test expectations

The ISO boot test (`initrd/tests/iso-test/iso-boot-test.sh`) verifies:

1. **Kernel display driver detection** — decompresses bzImage, searches for
   built-in driver symbols (`vesadrm_probe`, `vesafb_probe`, `simpledrm_probe`).
   The kernel's built-in driver binds via `sysfb_init()` before the initramfs.
2. **Filesystem module support** — checks initrd for filesystem drivers
   (ext4, vfat, exfat)
3. **Isoboot keywords** — checks initrd scripts for `findiso`,
   `iso-scan/filename`, `live-media`

### Marker legend

| Boot menu | Display | Filesystem | Meaning |
|-----------|---------|------------|---------|
| `[OK]` | `[OK]:*` | `[OK]` | All good — display works continuously |
| `[~]` | `[~]:drm` or `[OK]` w/ degraded fs | Degraded | DRM reinit, or missing USB fs module |
| `[X]` | `[!]` | Any | No display driver — blank until GPU reinit |

### Driver marker mapping

| Detected | Marker | Kernel config | Distro example |
|----------|--------|---------------|----------------|
| `simpledrm` + `sysfb_parse_mode` | `simpledrm_sysfb` | `SYSFB_SIMPLEFB=y` | Ubuntu 26.04, Gentoo (6.x+) |
| `vesadrm` | `vesadrm` | VLFB (7.x sysfb fallback) | openSUSE 7.x |
| `vesafb` | `vesafb` | VLFB fbdev (5.x/6.x) | Fedora, Debian, NixOS, Tails |
| none | `[!]` | no built-in driver | CorePlus, Samsung fw

### Symbol search priority

In `_check_kernel_probe_driver()`, the decompressed kernel is searched
for these symbols in priority order:

1. `vesadrm_probe` / `vesadrm_platform_driver_init` (VLFB DRM, 7.x)
2. `vesafb_probe` / `vesafb_driver_init` (VLFB fbdev, 5.x/6.x)
3. `simpledrm_probe` / `simpledrm_platform_driver_init` (simpledrm, 6.x/7.x)

When simpledrm is found, an additional check for `sysfb_parse_mode`
confirms `CONFIG_SYSFB_SIMPLEFB=y`.  Without it, simpledrm cannot
bind because no `simple-framebuffer` platform device is created.

### Real hardware test requirements

| Category | Test case | What to check |
|----------|-----------|---------------|
| `simpledrm_sysfb` | Ubuntu 26.04 Live | `dmesg | grep simple-framebuffer` — simpledrm bind |
| `vesadrm` | openSUSE Tumbleweed | `dmesg | grep vesa-framebuffer` — vesadrm bind, stride OK |
| `vesafb` | Debian 13 Live | `dmesg | grep vesafb` — vesafb bind |
| Debian live-boot ISO | Debian live | `dmesg | grep "findiso\|live"` — findiso path match |
| Fedora live ISO | Fedora Workstation | `dmesg | grep "root=live\|iso-scan"` — dmsquash-live activation |

## GRUB variable stripping

When an ISO provides `loopback.cfg`, Heads parses the `linux` kernel
command line to extract boot parameters.  Many loopback.cfg files use
GRUB variables like `${iso_path}` and `${isofile}` that are set by
GRUB at boot time.  In `kexec` context these variables are undefined.

`_strip_grub_vars()` (in `kexec-iso-init.sh`) removes ANY kernel
parameter containing `$` — this handles `${iso_path}`, `${isofile}`,
`$iso_path`, and any unknown variable format a distribution might use.
The stripped command line is then augmented with universal ADD params
that provide absolute paths to the ISO file:

```
iso-scan/filename=/ISOs/ubuntu.iso
findiso=/ISOs/ubuntu.iso
img_loop=/ISOs/ubuntu.iso
live-media=/dev/disk/by-uuid/...
```

This approach is safer than trying to resolve variables: unknown
variable names would be passed literally to the kernel as parameters,
potentially allowing a crafted loopback.cfg to inject arbitrary
kernel arguments.

---

## Distro Compatibility Notes

The test harness (`initrd/tests/iso-test/iso-boot-test.sh`) validates
USB boot **detection** — kernel display symbols, initramfs filesystem
modules, isoboot keywords, and boot menu markers.  It does **not**
test whether the OS installs correctly with Heads' TPM+LUKS workflow.

Below are observations for each distro tested (as of 2026-06):

| Distro | Boot detection | Install with Heads | Notes |
|--------|:--------------:|:------------------:|-------|
| **Ubuntu 26.04** | ✅ loopback+GRUB → `simpledrm_sysfb` | ✅ | Default: unencrypted `/boot` + LUKS encrypted rootfs.  Heads can verify `/boot` contents.  `live-media=` with `iso-scan/filename=` works. |
| **Debian 13 Live** | ✅ `vesafb` | ⚠️ | Installer defaults to encrypted rootfs (Debian live).  Heads cannot verify/boot an encrypted `/boot`.  Workaround: manual partitioning with separate unencrypted `/boot`.  See [Heads docs](https://osresearch.net/). |
| **Debian 13 DVD** | ✅ (installer) | ✅ | Classic installer ISO — boot from Heads USB menu; select "Install Debian" for a custom partition layout. |
| **Fedora 43 Live** | ✅ `vesafb` | ⚠️ | Default: LUKS2 + Argon2.  Heads TPM DUK (LUKS1) may not unlock directly.  Workaround: select LUKS1 during install or use manual partition with unencrypted `/boot`. |
| **openSUSE TW Live** | ✅ `vesadrm` | ⚠️ | Default: encrypted root with LUKS2.  Same Argon2 consideration as Fedora.  Live ISO boots correctly; install requires manual `/boot` setup. |
| **openSUSE TW DVD** | ✅ `vesadrm` (installer) | ❌ | Installer ISO — no isoboot detection.  Must `dd` to dedicated drive.  Not designed for USB file boot. |
| **Tails 7.8** | ✅ `vesafb` | N/A | Persistent encrypted storage on USB; not a standard OS install.  Boots live from USB under Heads. |
| **Qubes R4.3** | ✅ `vesafb` | ⚠️ | Xen hypervisor — multiboot2 not kexec-compatible per Xen path.  USB ISO boot works; install via `dd` to drive is recommended. |
| **NixOS 25.11** | ✅ `vesafb` | ✅ | Flexible partitioning — works when `/boot` is unencrypted (as configured by default in Heads-compatible community guides). |
| **PureOS 11** | ✅ `vesafb` | ✅ | Debian derivative — standard LUKS1 + separate `/boot`.  Works with Heads. |
| **Kicksecure 18** | ✅ `vesafb` | ✅ | Hardened Debian derivative.  Similar to Debian — manual partitioning with unencrypted `/boot` recommended. |
| **CorePlus 15** | ❌ `[~]:drm` | ❌ | No display driver, no kexec loopback.  TinyCore minimal distribution — not designed for Heads. |

### Key takeaway

Any distro installed with a **separate unencrypted `/boot`** partition
can work with Heads (Heads verifies and measures `/boot` before booting
the kernel).  Distros that default to **encrypted `/boot`** (Debian
live, Fedora encrypted, openSUSE encrypted) need manual partitioning
to separate `/boot` from the encrypted rootfs during installation.
