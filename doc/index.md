# Heads documentation index

Quick reference: read the relevant doc when working on a topic.

## Build System & CI

| File | What it covers |
|------|----------------|
| [`build-artifacts.md`](build-artifacts.md) | x86/ppc64 output layout, ROM/package names, and [size/hash manifest semantics](build-artifacts.md#size-and-hash-manifest-semantics) |
| [`build-freshness.md`](build-freshness.md) | Why rebuilds produce stale artifacts, cpio/XZ composition, and rebuild guidance |
| [`circleci.md`](circleci.md) | CI pipeline: job dependency graph, cache layers, workspace persistence |
| [`docker.md`](docker.md) | Docker-based build environment with pinned image identity |
| [`modules.md`](modules.md) | Module inclusion, stamps/rebuild helpers, and the external HCL dependency |
| [`patches.md`](patches.md) | Creating and maintaining source patches for upstream packages |
| [`prerequisites.md`](prerequisites.md) | Tools and libraries needed before building Heads |
| [`reproducible-builds.md`](reproducible-builds.md) | Deterministic build/archive flags and verifying recorded hashes against CI |
| Hardware Compatibility — intended publication target | Not a working link: `https://osresearch.net/Hardware-Compatibility/` currently returns 404.  Board configs carry the HCL summaries and anchors; the deployment status is recorded once, in [`modules.md`](modules.md#hardware-compatibility-list-hcl) |

## Architecture & Boot Flow

| File | What it covers |
|------|----------------|
| [`architecture.md`](architecture.md) | System layout, x86 versus ppc64/Talos II, and config hierarchy |
| `boot-process.md` | Boot flow stages, ISO boot steps, [OK]/[~]/[X] progress markers |
| `iso_boot.md` | ISO kernel parameters: which framework uses each option |
| `kexec_handoff.md` | Kernel kexec handoff: screen_info, EBDA, sysfb/simpledrm/vesadrm |

## Security, TPM & Keys

| File | What it covers |
|------|----------------|
| `configuring-keys.md` | Setting up GPG keys for signing firmware updates |
| `gpg.md` | GPG tool operation for firmware signing and verification |
| `hotp.md` | HOTP-based remote attestation of firmware state |
| `ibb-measurement.md` | IBB measurement paths, PCR 0 prerequisites, provisioning and signing keys |
| `keys.md` | Key management for firmware signing |
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
| [`config.md`](config.md) | Board config hierarchy, module selection, and architecture/output settings |
| `development.md` | Development environment setup and contribution workflow |
| `faq.md` | Frequently asked questions |
| `logging.md` | Message levels (STATUS, WARN, NOTE, INFO, DEBUG, TRACE) |
| `qemu.md` | QEMU-based board emulation for testing |
| `recovery-shell.md` | Recovery shell usage and diagnostic commands |
| `ux-patterns.md` | User interaction: whiptail dialogs, CLI menus, confirmations |
| `variation-to-defconfig.md` | Converting Kconfig variation files to defconfig format |
