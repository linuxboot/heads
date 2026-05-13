# Heads Architecture

Heads is a firmware distribution that replaces proprietary BIOS/UEFI with coreboot, a minimal
Linux kernel, and a security-focused initrd. It establishes a hardware root of trust, implements
measured boot via TPM, and verifies the OS boot environment before handing off control.

See also: [security-model.md](security-model.md), [boot-process.md](boot-process.md),
[tpm.md](tpm.md): detailed subsystem documentation.

External reference: [deepwiki.com/linuxboot/heads](https://deepwiki.com/linuxboot/heads)
validated against code in this repository.

---

## Major components

```text
┌─────────────────────────────────────────────────────┐
│  SPI Flash ROM                                       │
│  ┌──────────────┐  ┌───────────────┐  ┌──────────┐  │
│  │  coreboot    │  │ Linux kernel  │  │  initrd  │  │
│  │ (HW init +   │-> │ (minimal,     │-> │ (boot    │  │
│  │  PCR 2 SRTM) │  │  no initramfs)│  │  scripts)│  │
│  └──────────────┘  └───────────────┘  └──────────┘  │
└─────────────────────────────────────────────────────┘
         │                                    │
         ▼                                    ▼
   TPM (PCR values)                OS kernel via kexec
```

### coreboot

Replaces vendor firmware. Performs hardware initialization (memory training, PCIe, USB),
extends PCR 2 in the TPM with each firmware stage (bootblock -> romstage -> ramstage ->
payload) as the Static Root of Trust for Measurement (SRTM), and launches the kernel
directly without a second-stage bootloader.

### Linux kernel (payload)

A minimal, stripped kernel compiled specifically for Heads. No initramfs: it boots directly
into the Heads initrd. Provides device drivers (TPM, USB, storage, network), filesystem
support, and the platform for the boot scripts.

### initrd

The root filesystem that runs at boot. Contains all Heads logic: configuration loading,
TPM operations, GPG verification, whiptail GUI, boot menu, LUKS key injection, and kexec
execution. Source lives in `initrd/`.

---

## initrd subsystems

| Subsystem | Key files | Purpose |
| --- | --- | --- |
| Init / boot flow | `initrd/init`, `initrd/bin/gui-init.sh` | System initialization and main GUI loop |
| TPM abstraction | `initrd/bin/tpmr.sh` | Unified TPM 1.2 / TPM 2.0 wrapper |
| Boot signing | `initrd/bin/kexec-sign-config.sh` | GPG-sign /boot files, create checksums |
| Boot verification | `initrd/bin/kexec-select-boot.sh` | Verify checksums, select and kexec the OS |
| LUKS key sealing | `initrd/bin/kexec-seal-key.sh` | Seal disk encryption key to TPM |
| TOTP/HOTP | `initrd/bin/seal-totp.sh`, `initrd/bin/seal-hotpkey.sh` | Seal attestation secrets to TPM |
| OEM reset | `initrd/bin/oem-factory-reset.sh` | Full re-ownership: GPG, TPM, TOTP, checksums |
| Config GUI | `initrd/bin/config-gui.sh` | Runtime configuration menus |
| Functions lib | `initrd/etc/functions.sh` | Shared utilities: logging, INPUT, TPM helpers |
| GUI lib | `initrd/etc/gui_functions` | Whiptail wrappers, integrity report |

---

## Configuration system

Three-layer hierarchy:

1. **`/etc/config`**: Board defaults compiled into the ROM at build time
2. **`/etc/config.user`**: User overrides extracted from CBFS at runtime
3. **`/tmp/config`**: Combined result, sourced during boot

`combine_configs()` in `initrd/etc/functions.sh` merges these by concatenating
`/etc/config*` into `/tmp/config`. User settings in CBFS take precedence
because they appear last in the concatenation.

Changes to user configuration are persisted by reflashing the ROM (CBFS operations).

---

## Build system

The top-level `Makefile` orchestrates:

- Cross-compiler (`musl-cross-make`, target: `x86_64-linux-musl` or `powerpc64le-linux-musl`)
- Modules (coreboot, Linux, busybox, GPG, cryptsetup, kexec, LVM2, zstd, ...: see [modules.md](modules.md) for the full list)
- Six CPIO archives assembled into the initrd:
  1. `dev.cpio`: device nodes
  2. `modules.cpio`: kernel modules
  3. `tools.cpio`: userspace tools + configuration
  4. `board.cpio`: board-specific scripts
  5. `heads.cpio`: security scripts (`CONFIG_HEADS=y`)
  6. `data.cpio`: data files
- Final ROM image: coreboot ROM with Linux + initrd payload embedded

Reproducible builds are achieved via Nix-pinned Docker images. See [docker.md](docker.md).
The CI pipeline's workspace and cache behavior is documented in
[circleci.md](circleci.md).

---

## Supported architectures

| Architecture | Target triplet | Example boards |
| --- | --- | --- |
| x86-64 | `x86_64-linux-musl` | ThinkPad, Librem, Dell OptiPlex, QEMU |
| PowerPC 64-bit LE | `powerpc64le-linux-musl` | Raptor Talos II |

---

## Key design principles

- **No network at boot**: all verification is local; no certificate authorities
- **Hardware root of trust**: coreboot in SPI flash is the trust anchor; coreboot extends measurements into the TPM
- **Fail-closed**: failed verification drops to authenticated recovery shell, not an unverified OS boot
- **Separation of duties**: the key that signs `/boot` lives on a hardware security dongle, never in the ROM
- **Auditability**: all source is open, builds are reproducible, ROM images are verifiable

---

## Display output after kexec

```
                                                                     kexec boundary
                      ┌──────────────────────────────────────────────────┐
                      │                DISPLAY CONTROLLER                │
                      │  (initialised by coreboot, continuously scans    │
                      │   out from framebuffer at physical address X)    │
                      └──────────────────────┬───────────────────────────┘
                                             │ reads pixels from
                                             ▼
                                    ┌────────────────┐
                                    │  scanout buf   │
                                    │  @ phys addr X │
                                    └────────────────┘
                                             ▲
                      ───────────────────────┼──────────────────────────────
   Heads side                                │                    OS side
                                             │
 ┌──────────────────────────┐       ┌───────────────────────────────┐
 │  coreboot/libgfxinit     │       │  target kernel (after kexec)  │
 │  - initialises display   │       │  sysfb_init() reads boot      │
 │  - sets VIDEO_TYPE_EFI   │       │  params -> VIDEO_TYPE_EFI      │
 │    in screen_info        │       │  -> "efi-framebuffer" device   │
 └────────────┬─────────────┘       │  -> efifb binds                │
              │                     │  BUT: lfb_base == 0           │
              ▼                     │  -> efifb_probe fails          │
 ┌──────────────────────────┐       │  -> no /dev/fb0                │
 │  Heads kernel            │       │  -> initramfs display blank    │
 │  sysfb_init() -> sees     │       └───────────────────────────────┘
 │  VIDEO_TYPE_EFI          │
 │  -> "efi-framebuffer"     │       ┌───────────────────────────────┐
 │  -> efifb binds           │       │  DRM driver (post-switchroot) │
 │  -> Heads GUI visible     │       │  i915 reinitialises display  │
 └────────────┬─────────────┘       │  -> framebuffer works again   │
              │                     └───────────────────────────────┘
              │
              ▼
 ┌──────────────────────────┐
 │  kexec-tools             │
 │  opens /dev/fb0 -> reads  │
 │  fb parameters           │
 │  fix.id = "EFI VGA" ✓    │
 │  smem_start = 0 ✗        │
 │  (kernel hid it)         │
 │  writes to new kernel    │
 │  boot params:            │
 │  orig_video_isVGA = EFI  │
 │  lfb_base = 0            │
 └──────────────────────────┘
```

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
simpledrm are not compatible because the scanout buffer was set up
as an efifb-compatible buffer by coreboot, not as a simplefb buffer.

**Known limitation: lost framebuffer address:**

Linux no longer exposes the physical framebuffer address to userspace.
kexec-tools obtains `smem_start = 0` from `FBIOGET_FSCREENINFO` and
writes `lfb_base = 0` into the new kernel's boot params.  The target
kernel's efifb sees a zero address and cannot map the framebuffer
the display stays blank even though the controller is still scanning
out the correct memory (set up by coreboot, preserved through kexec).

Historically, Heads worked around this by using i915 with
`CONFIG_DRM_FBDEV_LEAK_PHYS_SMEM=y` (leaking the physical address),
but that was suboptimal.  The current efifb approach is also
suboptimal: we are waiting for improvements in coreboot, Linux, and
kexec-tools to properly convey the framebuffer state across kexec.

**TPM Disk Unlock Key** works around this for encrypted disks by
injecting the LUKS key before kexec: the initramfs never prompts for
a passphrase on a blank display.  Serial console is unaffected.