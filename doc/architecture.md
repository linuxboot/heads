# Heads Architecture

Heads is a firmware distribution that replaces proprietary BIOS/UEFI with coreboot, a minimal
Linux kernel, and a security-focused initramfs. It establishes a hardware root of trust, implements
measured boot via TPM, and verifies the OS boot environment before handing off control.

See also: [security-model.md](security-model.md), [boot-process.md](boot-process.md),
[tpm.md](tpm.md) — detailed subsystem documentation.

External reference: [deepwiki.com/linuxboot/heads](https://deepwiki.com/linuxboot/heads) —
validated against code in this repository.

---

## Major components

```text
┌─────────────────────────────────────────────────────┐
│  SPI Flash ROM                                       │
│  ┌──────────────┐  ┌───────────────┐  ┌──────────┐  │
│  │  coreboot    │  │ Linux kernel  │  │ initramfs │  │
│  │ (HW init +   │→ │ (minimal,     │→ │ (boot    │  │
│  │  PCR 2 SRTM) │  │  no initramfs)│  │  scripts)│  │
│  └──────────────┘  └───────────────┘  └──────────┘  │
└─────────────────────────────────────────────────────┘
         │                                    │
         ▼                                    ▼
   TPM (PCR values)                OS kernel via kexec
```

### coreboot

Replaces vendor firmware. Performs hardware initialization (memory training, PCIe, USB),
records each firmware stage (bootblock → romstage → ramstage → payload) into TPM PCR 2
as the Static Root of Trust for Measurement (SRTM), and launches the kernel directly
without a second-stage bootloader.  Measured boot is transitive: each stage measures the
next before executing it.  The CRTM (running in bootblock) measures FMAP and the bootblock
image into the preram log.  Measurements taken before the TPM hardware is initialized are
cached in the preram log and flushed to PCR 2 once TPM setup is complete.  See
[tpm.md](tpm.md#srtm-in-coreboot) for per-board TPM init timing.

The framebuffer initialized by coreboot (libgfxinit on pre-Alder Lake,
FSP GOP on Alder Lake and newer) must survive across kexec for display
to work in the booted OS.  Boards without a coreboot framebuffer
(talos-2: kernel AST DRM, librem_l1um: BMC serial, KGPE-D16: native
VGA init — server variants output to BMC serial + AST VGA; workstation
variants use external discrete NVIDIA/AMD GPUs with fbwhiptail) have
different display paths that do not involve sysfb handoff.
See [boot-process.md](boot-process.md#target-kernel-display-handoff)
and [kexec_handoff.md](kexec_handoff.md) for the display handoff mechanism,
per-board GPU init paths, limitations, and the TPM Disk Unlock Key
workaround.

### Linux kernel (payload)

A minimal, stripped kernel compiled specifically for Heads. No initramfs — it boots directly
into the Heads initramfs. Provides device drivers (TPM, USB, storage, network), filesystem
support, and the platform for the boot scripts.

### initramfs

The root filesystem that runs at boot. Contains all Heads logic: configuration loading,
TPM operations, GPG verification, whiptail GUI, boot menu, LUKS key injection, and kexec
execution. Source lives in `initrd/`.

---

## initramfs subsystems

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
| GUI lib | `initrd/etc/gui_functions.sh` | Whiptail wrappers, integrity report |

---

## Configuration system

Three-layer hierarchy:

1. **`/etc/config`** — Board defaults compiled into the ROM at build time
2. **`/etc/config.user`** — User overrides extracted from CBFS at runtime
3. **`/tmp/config`** — Combined result, sourced during boot

`combine_configs()` in `initrd/etc/functions.sh` merges these by concatenating
`/etc/config*` into `/tmp/config`. User settings in CBFS take precedence
because they appear last in the concatenation.

Changes to user configuration are persisted by reflashing the ROM (CBFS operations).

---

## Build system

The top-level `Makefile` orchestrates:

- Cross-compiler (`musl-cross-make`, target: `x86_64-linux-musl` or `powerpc64le-linux-musl`)
- Modules (coreboot, Linux, busybox, GPG, cryptsetup, kexec, LVM2, …)
- Six CPIO archives assembled into the initramfs:
  1. `dev.cpio` — device nodes
  2. `modules.cpio` — kernel modules
  3. `tools.cpio` — userspace tools + configuration
  4. `board.cpio` — board-specific scripts
  5. `heads.cpio` — security scripts (`CONFIG_HEADS=y`)
  6. `data.cpio` — data files
- Final ROM image: coreboot ROM with Linux + initramfs payload embedded

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

- **No network at boot** — all verification is local; no certificate authorities
- **Hardware root of trust** — the coreboot bootblock (IBB) is the Static Core Root of Trust for Measurement (S-CRTM): the first code executed by the CPU, directly from SPI flash.  Coreboot implements a transitive measurement chain: the CRTM measures FMAP and the bootblock image into the preram log, then each subsequent stage measures the next before executing it — bootblock measures romstage, romstage measures ramstage, ramstage measures the Heads payload.  Measurements are taken during CBFS file loading, before decompression, and are recorded in TPM PCR 2 (SRTM) once the TPM hardware is initialized (`tpm_setup()`).  Measurements taken before TPM init are cached in the preram log and flushed to PCR 2 by `tspi_measure_cache_to_pcr()` during `tpm_setup()`.  The full chain — bootblock → romstage → ramstage → Heads Linux kernel + initrd — is recorded into PCR 2.  PCRs 0, 1, and 3 remain zero as policy anchors.  See [tpm.md](tpm.md#srtm-in-coreboot) for TPM init timing per board.  See [wp-notes.md](wp-notes.md#pr0-chipset-locking) for SPI write-protection and PR0 chipset locking details.
- **Fail-closed** -- failed integrity verification drops to a recovery shell.  Recovery shell authentication via GPG smartcard is enforced when GPG key backup has been configured (`CONFIG_HAVE_GPG_KEY_BACKUP=y`), which is set by answering "y" to `"Would you like to format an encrypted USB Thumb drive to store GPG key material? (Required to enable GPG authentication)"` during OEM Factory Reset / Re-Ownership, or by running "Reprovision smartcard from GPG key backup" from the GPG Management Menu.  Otherwise the recovery shell is unauthenticated.  An "Ignore tampering and force a boot (Unsafe!)" option is available to override this.  See [recovery-shell.md](recovery-shell.md#authentication) for details.
- **Separation of duties** — the public key that verifies `/boot` signatures is stored in CBFS (ROM).  The private key that signs `/boot` stays on a USB security dongle and never leaves it.
- **Auditability** — all source is open, builds are reproducible, ROM images are verifiable

### Purism boot modes

Purism developed and upstreamed two boot enforcement modes for Heads as part
of **PureBoot** (their integrated stack of coreboot + TPM + Heads + USB
security dongle + LUKS).  The modes are mutually exclusive and configurable
via Options → Change Configuration Settings in `config-gui.sh`:

| Mode | Config | Boot script | Behavior |
|------|--------|-------------|----------|
| **Normal** | (default) | `gui-init.sh` | Full GUI, hash verification, TPM checks, HOTP/TOTP, USB dongle, unsafe boot available |
| **Basic** | `CONFIG_BASIC=y` | `gui-init-basic.sh` → `basic-autoboot.sh` | `/init` overrides `CONFIG_BOOTSCRIPT`. No signature checks, no dongle, no HOTP. Auto-boots first OS entry. |
| **Restricted** | `CONFIG_RESTRICTED_BOOT=y` | `gui-init.sh` | Same as Normal but: failsafe boot disabled, recovery console blocked, unsigned USB blocked. When disabled, erases TOTP/HOTP secret in TPM and reflashes. |

### Flash write protection

The SPI flash ROM is locked against writes via Intel chipset-level PR0
lockdown just before kexec.  Coreboot prepares the SPI controller for
SMM-initiated locking; Heads triggers the lock via `io386` SMI:

```text
kexec-boot.sh → lock_chip.sh → io386 0xb2 0xcb → SMI → FLOCKDN
                                                    └─ PR0 locked,
                                                       flash read-only
                                                       until reset
```

This is x86/Intel only — QEMU (emulated), Talos II (POWER9), Librem L1UM,
and AMD-based boards (KGPE-D16) lack Intel chipset locking.  29 Intel
boards across all generations from Sandy Bridge to Alder Lake use this
mechanism.

See [wp-notes.md](wp-notes.md#pr0-chipset-locking) for the full config
requirements, runtime chain details, and board-level status.

See also: [wp-notes.md](wp-notes.md) — per-board write-protection
status and tracking.
