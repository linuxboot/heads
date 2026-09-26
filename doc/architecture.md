# Heads Architecture

Heads is a firmware distribution that replaces proprietary BIOS/UEFI with coreboot, a minimal
Linux kernel, and a security-focused initramfs. On supported targets it establishes a hardware
root of trust, and x86 targets with TPM support and `CONFIG_TPM_MEASURED_BOOT=y` use TPM measured
boot before the OS boot environment is verified and control is handed off.

See also: [build-artifacts.md](build-artifacts.md) for output/package layout,
[modules.md](modules.md) for build modules, [reproducible-builds.md](reproducible-builds.md),
[security-model.md](security-model.md), [boot-process.md](boot-process.md), and
[tpm.md](tpm.md).

External reference: [deepwiki.com/linuxboot/heads](https://deepwiki.com/linuxboot/heads) —
validated against code in this repository.

---

## Major components

The following diagram shows a typical x86 coreboot configuration with TPM support and
`CONFIG_TPM_MEASURED_BOOT=y`; it is not the Talos II or LinuxBoot path:

```text
┌─────────────────────────────────────────────────────┐
│  SPI Flash ROM                                       │
│  ┌──────────────┐  ┌───────────────┐  ┌──────────┐  │
│  │  coreboot    │  │ Linux kernel  │  │ initramfs │  │
│  │ (HW init +   │→ │ (bzImage)     │→ │ (boot    │  │
│  │  PCR 2 SRTM) │  │               │  │  scripts)│  │
│  └──────────────┘  └───────────────┘  └──────────┘  │
└─────────────────────────────────────────────────────┘
         │                                    │
         ▼                                    ▼
   TPM (PCR values)                OS kernel via kexec
```

### coreboot

On maintained x86 coreboot targets with TPM support and
`CONFIG_TPM_MEASURED_BOOT=y`, coreboot performs hardware initialization (memory
training, PCIe, USB), records the bootblock → romstage → ramstage → payload chain
into TPM PCR 2 as the Static Root of Trust for Measurement (SRTM), and launches
the Linux payload without a second-stage bootloader.  The CRTM (running in
bootblock) measures FMAP and the bootblock image into the preram log.
Measurements taken before TPM initialization are flushed to PCR 2 once TPM setup
completes.  This is a typical x86 path, not a universal description: X280
measured boot is disabled, Librem Mini has TPM support disabled, the
unmaintained `CONFIG_LINUXBOOT` path builds a separate linuxboot ROM, and Talos
uses coreboot → skiboot rather than the direct x86 coreboot → Linux chain.  See
[tpm.md](tpm.md#root-of-trust-and-srtm-chain) for per-board TPM timing.

The framebuffer initialized by coreboot (libgfxinit on pre-Alder Lake,
FSP GOP on Alder Lake and newer) must survive across kexec for display
to work in the booted OS.  Boards without a coreboot framebuffer
(talos-2: kernel AST DRM, librem_l1um: BMC serial, KGPE-D16: native
VGA init — server variants output to BMC serial + AST VGA; workstation
variants use external discrete NVIDIA/AMD GPUs with fbwhiptail) have
different display paths that do not involve sysfb handoff.
See [boot-process.md](boot-process.md#os-boot-execution-do_boot).
and [kexec_handoff.md](kexec_handoff.md) for the display handoff mechanism,
per-board GPU init paths, limitations, and the TPM Disk Unlock Key
workaround.

### Linux kernel (payload)

A minimal, stripped kernel compiled specifically for Heads.  On maintained
x86 coreboot targets, the kernel embeds the small static `blobs/dev.cpio` as its
built-in initramfs (including the early `/dev/console` setup), while the main
Heads userspace, tools, module payload, and board scripts are carried separately
as external XZ-compressed `initrd.cpio.xz` through `CONFIG_LINUX_INITRD`.  The
unmaintained LinuxBoot path passes `bzImage` and the external
`initrd.cpio.xz` to `modules/linuxboot`.  `config/linux-linuxboot.config` does
not explicitly list `CONFIG_RD_XZ`, `CONFIG_XZ_DEC`, or
`CONFIG_XZ_DEC_X86`; `modules/linux` runs `olddefconfig`, and for Linux 4.14
those options default through Kconfig to enabled (`RD_XZ` → `DECOMPRESS_XZ` →
`XZ_DEC`, with `XZ_DEC_X86` defaulting to `y`).  Generated-config inspection and
runtime LinuxBoot boot verification remain pending, so omission alone is not a
verified decoder limitation.  Talos II is a different layout:
`CONFIG_LINUX_BUNDLED=y` rebuilds a ppc64le `zImage` with the decompressed
`initrd.cpio` embedded and exports `zImage.bundled`.  There the standalone
`initrd.cpio.xz` is decompressed on the build host, so the guest never decodes
it and the external-initrd options (`CONFIG_RD_XZ`) do not apply; the guest
instead decodes the kernel's own built-in initramfs XZ stream
(`CONFIG_INITRAMFS_COMPRESSION_XZ` with `CONFIG_XZ_DEC=y`).  Neither stream
carries a BCJ filter: see
[build-freshness.md](build-freshness.md#why-no-bcj-filter-on-non-x86).  The
coreboot ROM loads skiboot; the resulting `.tgz` ships `zImage.bundled`
separately alongside the ROM and bootblock.  Coreboot does not embed that Linux
image in the Talos ROM.

### initramfs

The root filesystem that runs at boot. It contains the Heads logic for
configuration loading, TPM operations, GPG verification, the boot menu, LUKS
key injection, and kexec execution. Its main source is `initrd/`, with
board-specific additions under `boards/<board>/initrd/`.  On maintained x86
coreboot targets, `blobs/dev.cpio` is the kernel's small built-in initramfs and
the main Heads filesystem is a separate xz CBFS input.  That external initrd is
also passed to the unmaintained LinuxBoot build, while Talos embeds its
decompressed main cpio in `zImage.bundled`.  The Talos guest then boots the
zImage's own built-in initramfs, which is itself XZ compressed and decoded in
the kernel with `CONFIG_XZ_DEC=y`.

---

## initramfs subsystems

| Subsystem | Key files | Purpose |
| --- | --- | --- |
| Init / boot flow | `initrd/init`, `initrd/bin/gui-init.sh` | System initialization and main GUI loop |
| TPM abstraction | `initrd/bin/tpmr.sh` | Unified TPM 1.2 / TPM 2.0 wrapper |
| Boot signing | `initrd/bin/kexec-sign-config.sh` | GPG-sign /boot files, create checksums |
| Boot verification | `initrd/bin/kexec-select-boot.sh` | Verify checksums, select and kexec the OS |
| LUKS key sealing | `initrd/bin/kexec-seal-key.sh` | Seal disk encryption key to TPM |
| TOTP/HOTP | `initrd/bin/seal-totp.sh` (seal), `initrd/bin/seal-hotpkey.sh` (reuse) | TOTP secret sealed to TPM; the same secret programs the HOTP dongle |
| OEM reset | `initrd/bin/oem-factory-reset.sh` | Full re-ownership: GPG, TPM, TOTP, checksums |
| Config GUI | `initrd/bin/config-gui.sh` | Runtime configuration menus |
| Functions lib | `initrd/etc/functions.sh` | Shared utilities: logging, INPUT, TPM helpers |
| GUI lib | `initrd/etc/gui_functions.sh` | Whiptail wrappers, integrity report |

---

## Configuration system

Three-layer hierarchy:

1. **`/etc/config`** — Exported `CONFIG_*` board defaults compiled into the ROM at build time
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
- Modules (the board-selected coreboot module, for example `coreboot-25.09`, plus Linux, busybox, GPG, cryptsetup, kexec, LVM2, …)
- Four unconditional cpio inputs (`dev.cpio`, `modules.cpio`, `tools.cpio`,
  `board.cpio`), plus conditional `data.cpio` and either `heads.cpio`
  (`CONFIG_HEADS=y`) or `u-root.cpio` (`CONFIG_UROOT=y`).  The u-root path
  disables Heads cpio inclusion, so the selected set has at most six archives;
  see [build-freshness.md](build-freshness.md#initrdcpioxz-composition)
- Architecture-specific final output: maintained x86 coreboot targets use an
  external xz initrd in CBFS; the unmaintained LinuxBoot path packages its
  external `bzImage`/initrd inputs through linuxboot; ppc64/Talos II has
  coreboot load skiboot while its `.tgz` separately ships the ROM, bootblock,
  and bundled-initramfs `zImage.bundled`

`flake.nix`/`flake.lock` define the inputs used to build the local Nix/Docker
image; they do not pin the published image selected by the wrappers.  That image
identity comes from `docker/DOCKER_REPRO_DIGEST` (or its environment override)
and the canonical CI image pin described in [docker.md](docker.md).  The build
also applies flags intended to reduce nondeterminism (see
[reproducible-builds.md](reproducible-builds.md)).  These mechanisms do not by
themselves guarantee bit-identical ROM output; that requires comparable
same-commit builds and an explicit artifact comparison.  The CI pipeline's
workspace and cache behavior is documented in [circleci.md](circleci.md).

---

## Supported architectures

| Architecture | Userspace/Linux target triplet | Example board | Initrd handoff |
| --- | --- | --- | --- |
| x86-64 coreboot | `x86_64-linux-musl` | ThinkPad, Librem, Dell OptiPlex, QEMU | Separate `initrd.cpio.xz` in coreboot CBFS |
| x86-64 LinuxBoot (unmaintained) | `x86_64-linux-musl` | `UNMAINTAINED_qemu-linuxboot` | External `bzImage` and initrd passed to linuxboot |
| PowerPC 64-bit LE | `powerpc64le-linux-musl` | IBM Talos II (`UNTESTED_talos-2`) | Bundled into ppc64le `zImage.bundled` |

Talos II combines a big-endian coreboot ROM whose payload is skiboot with a
separately shipped little-endian ppc64le Linux image and userspace.  The
`.tgz` carries the ROM, bootblock, and `zImage.bundled`; the Linux image is not
embedded in the coreboot ROM.  `CONFIG_TARGET_ARCH=ppc64` selects the
`build/ppc64/UNTESTED_talos-2/` output tree.  Its artifacts and `.tgz` layout
differ from the x86 ROM/ZIP workflow; see
[build-artifacts.md](build-artifacts.md#architecture-specific-output-layout).

---

## Key design principles

- **No network at boot** — all verification is local; no certificate authorities
- **Hardware root of trust** — on the typical x86 path with TPM support and `CONFIG_TPM_MEASURED_BOOT=y`, the coreboot bootblock (IBB) acts as the Static Core Root of Trust for Measurement (S-CRTM): the first code executed by the CPU, directly from SPI flash.  Coreboot implements a transitive chain: the CRTM measures FMAP and the bootblock image into the preram log, then bootblock measures romstage, romstage measures ramstage, and ramstage measures the Heads payload.  Measurements are cached before TPM initialization and flushed to PCR 2 during `tpm_setup()`.  This is not the Talos or LinuxBoot path, and measured boot/TPM availability varies by board.  See [tpm.md](tpm.md#root-of-trust-and-srtm-chain) for the per-board PCR map and timing, and [wp-notes.md](wp-notes.md#pr0-chipset-locking) for SPI write protection.
- **Fail-closed** — failed integrity verification drops to a recovery shell.  Recovery shell authentication via GPG smartcard is enforced when GPG key backup has been configured (`CONFIG_HAVE_GPG_KEY_BACKUP=y`), which is set by answering "y" to `"Would you like to format an encrypted USB Thumb drive to store GPG key material? (Required to enable GPG authentication)"` during OEM Factory Reset / Re-Ownership.  Otherwise the recovery shell is unauthenticated.  An "Ignore tampering and force a boot (Unsafe!)" option is available to override this.
- **Separation of duties** — the public key that verifies `/boot` signatures is stored in CBFS (ROM).  The private key that signs `/boot` stays on a USB security dongle and never leaves it.
- **Auditability** — source inputs, build recipes, and recorded hashes can be inspected; byte-identical ROM output must be demonstrated for the compared build

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
and AMD-based boards (KGPE-D16) lack Intel chipset locking.  Board applicability
is determined by the relevant `boards/*/*.config` settings; no fixed Intel-board
count is asserted here.  See the authoritative config/status discussion in
[wp-notes.md](wp-notes.md#board-coverage).

See [wp-notes.md](wp-notes.md#pr0-chipset-locking) for the full config
requirements, runtime chain details, and board-level status.

See also: [wp-notes.md](wp-notes.md) — per-board write-protection
status and tracking.
