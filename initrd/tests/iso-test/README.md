# ISO Boot Test Expectations

Expected behavior for every ISO tested by `iso-boot-test.sh --iso-dir <dir>`.
ISOs change across releases -- re-validate when updating the test set.

## Marker Legend

| Symbol | Meaning |
|--------|---------|
| [OK]   | Ready -- display driver found in kernel, USB filesystem in initramfs |
| [~]    | Degraded -- display has no built-in driver ([~]:drm), or USB fs missing |
| (none) | Not checked -- compat skipped or no loadable modules |

## File-based ISO Boot Support

Heads boots ISOs by injecting kernel parameters (`fromiso=`, `findiso=`,
`iso-scan/filename=`) that tell the target initramfs how to find the ISO file
on USB.  This requires the **initramfs** to implement file-based ISO booting.

Some ISOs **cannot** boot from a file on USB and must be raw-written with
`dd if=iso of=/dev/sdX`.  This is detected during Step 5 by checking
whether the initramfs scripts actually implement `iso-scan/filename` or
`findiso` in a `case`/`if` control block (not just mention it in comments).

### ISOs that require raw-device (dd) boot

| ISO | Reason |
|-----|--------|
| **openSUSE Tumbleweed DVD** | Compiled linuxrc binary as /init (no dracut-live, no |
| (2026-06-05) | findiso/fromiso/iso-scan support).  Network boot fallback. |
| **Debian 13 DVD** | installer image (iso9660 only), not a hybrid/live ISO |
| (2026-12-15) | designed for USB boot.  d-i netinst/installer images |
| | are built for CD boot, not USB loopback. |

## Kernel probe symbol mapping by kernel version

The `_check_kernel_probe_driver()` function in `initrd/etc/functions.sh`
decompresses the kernel and searches for built-in display driver symbols.
Symbol names change across kernel versions — this table explains why
different ISOs show different symbols in Step 7 results:

| Kernel era | Kernel symbol detected | ISOs in this test set |
|------------|----------------------|-----------------------|
| 5.x/6.x (fbdev) | `vesafb_probe` | Debian 13, Tails, PureOS, Kicksecure, Qubes, NixOS |
| 6.x/7.x (SYSFB_SIMPLEFB) | `simpledrm_sysfb` | Ubuntu 26.04 |
| 7.x (sysfb VLFB) | `vesadrm_probe` | openSUSE Tumbleweed |

The multi-pattern search in `_check_kernel_probe_driver` covers all
eras with a single decompression pass:

| Priority | Driver | Symbol | Kernel era | Binds to |
|----------|--------|--------|------------|----------|
| 1 | vesadrm (DRM) | `vesadrm_probe` | 6.x/7.x | "vesa-framebuffer" via VLFB |
| 2 | vesafb (fbdev) | `vesafb_probe` | 5.x/6.x | "vesa-framebuffer" via VLFB |
| 3 | simpledrm (DRM) | `simpledrm_probe` + `sysfb_parse_mode` | 6.x/7.x | "simple-framebuffer" via SYSFB_SIMPLEFB |

## Per-ISO Results

### Tested ISO Versions

| ISO file | Distro | Kernel | Compression |
|----------|--------|--------|-------------|
| `ubuntu-26.04-desktop-amd64.iso` | Ubuntu 26.04 | 7.0.0 | zstd |
| `debian-live-13.2.0-amd64-kde.iso` | Debian 13 Trixie | 6.12.57 | zstd |
| `debian-live-13.2.0-amd64-xfce.iso` | Debian 13 Trixie | 6.12.57 | zstd |
| `debian-13.2.0-amd64-DVD-1.iso` | Debian 13 installer | 6.12.57 | gzip |
| `Fedora-Workstation-Live-43-1.6.x86_64.iso` | Fedora 43 Workstation | 6.17.1 | xz/zstd |
| `Fedora-Silverblue-ostree-x86_64-43-1.6.iso` | Fedora 43 Silverblue | 6.17.1 | xz/zstd |
| `Kicksecure-LXQt-18.1.4.2.Intel_AMD64.iso` | Kicksecure 18.1 | 6.12.69 | zstd |
| `Qubes-R4.3.1-rc1-x86_64.iso` | Qubes OS R4.3 | 6.12/6.17 | xz |
| `nixos-graphical-25.11.*.iso` | NixOS 25.11 | 6.12/6.18 | zstd |
| `pureos-11-gnome-live-20260515_amd64.iso` | PureOS 11 | 6.12 | zstd |
| `tails-amd64-7.8.1.iso` | Tails 7.8 | 6.12.74 | xz |
| `openSUSE-Tumbleweed-KDE-Live-*.iso` | openSUSE TW KDE Live | 7.0.11 | gzip |
| `openSUSE-Tumbleweed-DVD-*.iso` | openSUSE TW DVD | 7.0.11 | gzip |
| `CorePlus-current.iso` | TinyCore 15 | 6.18 | gzip |
| `Samsung_SSD_990_PRO_8B2QJXD7.iso` | Samsung firmware | - | gzip |

### Expected Results

| ISO | Step 3 (loopback) | Isoboot | Step 7 (display) | Marker |
|-----|:---:|:---:|:---:|--------|
| Ubuntu 26.04 | loopback+GRUB vars | supported | [OK] | `simpledrm_sysfb` |
| Debian 13 Live KDE | loopback, no vars | supported | [OK] | `vesafb` |
| Debian 13 Live XFCE | loopback, no vars | supported | [OK] | `vesafb` |
| Debian 13 DVD | no loopback | not detected | [OK] | `vesafb` (installer ISO) |
| Fedora Silverblue | no loopback | supported | [OK] | `vesafb` |
| Fedora Workstation | loopback, no vars | supported | [OK] | `vesafb` |
| Kicksecure | loopback, no vars | supported | [OK] | `vesafb` |
| Qubes | no loopback | supported | [OK] | `vesafb` |
| NixOS | loopback, no vars | supported | [OK] | `vesafb` |
| PureOS 11 | no loopback | supported | [OK] | `vesafb` |
| openSUSE Tumbleweed Live | loopback, no vars | supported | [OK] | `vesadrm` |
| openSUSE Tumbleweed DVD | no loopback | not detected | [OK] | `vesadrm` (installer ISO) |
| Tails 7.8 | no loopback | supported | [OK] | `vesafb` |
| CorePlus | no loopback | not detected | [~] | `[~]:drm` (no display driver) |
| Samsung SSD | no loopback | not detected | [~] | `[~]:drm` (firmware tool) |

**Notes:**
- "not detected" for isoboot = installer ISO that can't boot from a USB
  file (must use `dd` to dedicated drive). Correct detection, not a failure.
- `[~]` markers = no display driver available. CorePlus lacks vesafb/vesadrm;
  Samsung is an EFI firmware tool requiring UEFI runtime unavailable on coreboot.
