# Heads documentation index

Quick reference: read the relevant doc when working on a topic.

## Build System & CI

| File | What it covers |
|------|----------------|
| `build-artifacts.md` | ROM filenames, update-package zip layout, LVFS conventions |
| `build-freshness.md` | Why rebuilds produce stale artifacts and how to force a full rebuild |
| `circleci.md` | CI pipeline: job dependency graph, cache layers, workspace persistence |
| `docker.md` | Docker-based build environment with pinned, reproducible images |
| `modules.md` | Module system: toolchain and bin modules, inclusion rules, sentinel chain |
| `patches.md` | Creating and maintaining source patches for upstream packages |
| `prerequisites.md` | Tools and libraries needed before building Heads |
| `reproducible-builds.md` | Deterministic build flags and verifying ROM hashes against CI |

## Architecture & Boot Flow

| File | What it covers |
|------|----------------|
| `architecture.md` | System layout: coreboot → Linux → initramfs, config hierarchy |
| `boot-process.md` | Boot flow stages, ISO boot steps, [OK]/[~]/[X] progress markers |
| `iso_boot.md` | ISO kernel parameters: which framework uses each option |
| `kexec_handoff.md` | Kernel kexec handoff: screen_info, EBDA, sysfb/simpledrm/vesadrm |

## Security, TPM & Keys

| File | What it covers |
|------|----------------|
| `configuring-keys.md` | Setting up GPG keys for signing firmware updates |
| `gpg.md` | GPG tool operation for firmware signing and verification |
| `hotp.md` | HOTP-based remote attestation of firmware state |
| `keys.md` | Key management for firmware signing |
| `opal.md` | TCG Opal disk unlock and optional coreboot S3 credential handoff |
| `security-model.md` | TPM measured boot, trust chain, flash write protection |
| `TPM_GPIO_Reset_Approaches.md` | Eight approaches for resetting TPM via GPIO |
| `TPM_GPIO_Reset_Vulnerability.md` | TPM GPIO reset vulnerability analysis |
| `tpm.md` | TPM 1.2 and 2.0 operation details |
| `wp-notes.md` | Flash write protection: PR0 chipset locking, WP# pin, runtime chain |

## Development & Reference

| File | What it covers |
|------|----------------|
| `BOARDS_AND_TESTERS.md` | Board EOL/ESU status, CPU generations, tester registry |
| `busybox_perks.md` | GNU vs BusyBox command differences for initrd scripts |
| `config.md` | Board config hierarchy: defconfig, oldconfig, variation-to-defconfig |
| `development.md` | Development environment setup and contribution workflow |
| `faq.md` | Frequently asked questions |
| `logging.md` | Message levels (STATUS, WARN, NOTE, INFO, DEBUG, TRACE) |
| `qemu.md` | QEMU-based board emulation for testing |
| `recovery-shell.md` | Recovery shell usage and diagnostic commands |
| `ux-patterns.md` | User interaction: whiptail dialogs, CLI menus, confirmations |
| `variation-to-defconfig.md` | Converting Kconfig variation files to defconfig format |
