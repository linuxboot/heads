# Heads: the other side of TAILS

![Heads booting on an x230](https://user-images.githubusercontent.com/827570/156627927-7239a936-e7b1-4ffb-9329-1c422dc70266.jpeg)

Heads is a configuration for laptops and servers that tries to bring
more security to commodity hardware.  Among its goals are:

* Use free software on the boot path
* Move the root of trust into hardware (or at least the ROM bootblock)
* Measure and attest to the state of the firmware
* Measure and verify all filesystems

![Flashing Heads into the boot ROM](https://farm1.staticflickr.com/553/30969183324_c31d8f2dee_z_d.jpg)

NOTE: It is a work in progress and not yet ready for non-technical users.
If you're interested in contributing, please get in touch.
Installation requires disassembly of your laptop or server,
external SPI flash programmers, possible risk of destruction and
significant frustration.

More information is available in [the 33C3 presentation of building "Slightly more secure systems"](https://trmm.net/Heads_33c3).

## Documentation

The `doc/` directory contains technical reference documentation for the
Heads codebase. Start here:

| Document | What it covers |
| --- | --- |
| [doc/architecture.md](doc/architecture.md) | Component overview: coreboot, Linux payload, initrd, build system, configuration layers |
| [doc/security-model.md](doc/security-model.md) | Trust hierarchy, measured boot, TOTP/HOTP attestation, GPG boot signing, LUKS DUK, fail-closed design |
| [doc/boot-process.md](doc/boot-process.md) | Step-by-step boot flow: /init → gui-init → kexec-select-boot → OS handoff |
| [doc/tpm.md](doc/tpm.md) | PCR assignments, sealing policies, SRTM chain, board-specific TPM variations, developer config reference |
| [doc/ux-patterns.md](doc/ux-patterns.md) | GUI/UX conventions: whiptail wrappers, integrity report, error flows |
| [doc/config.md](doc/config.md) | Board and user configuration system |
| [doc/docker.md](doc/docker.md) | Reproducible build workflow using Docker |
| [doc/circleci.md](doc/circleci.md) | CircleCI pipeline layout, workspace flow, and cache behavior |
| [doc/qemu.md](doc/qemu.md) | QEMU board targets for development and testing |
| [doc/wp-notes.md](doc/wp-notes.md) | Flash write-protection status per board |
| [doc/BOARDS_AND_TESTERS.md](doc/BOARDS_AND_TESTERS.md) | Supported boards and their maintainers/testers |
| [doc/prerequisites.md](doc/prerequisites.md) | USB security dongles (HOTP/TPMTOTP), OS requirements, flashing methods |
| [doc/faq.md](doc/faq.md) | Common questions: UEFI vs coreboot, TPM, LUKS, threat models |
| [doc/keys.md](doc/keys.md) | All keys and secrets: TPM owner, GPG PINs, Disk Recovery Key, LUKS DUK |
| [doc/development.md](doc/development.md) | Commit conventions, coding standards, testing checklist |
| [doc/build-freshness.md](doc/build-freshness.md) | Debugging stale builds: initrd.cpio.xz composition, verification |

For user-facing documentation and guides, see [Heads-wiki](https://osresearch.net).

## Contributing

We welcome contributions to the Heads project! Before contributing, please read our [Contributing Guidelines](CONTRIBUTING.md) for information on how to get started, submit issues, and propose changes.

## Building Heads

Heads builds inside a versioned Docker image. The supported and tested workflow uses the
provided Docker wrappers — no host-side QEMU or swtpm installation is needed.

**Quick start** (requires [Docker CE](https://docs.docker.com/engine/install/)):

```bash
./docker_repro.sh make BOARD=x230-hotp-maximized
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 run
```

**No hardware required for testing** — Docker provides the full build stack
and QEMU runtime with software TPM (swtpm) and the bundled `canokey-qemu`
virtual OpenPGP smartcard. Build and test entirely in software before flashing real hardware.

Build targets are the directory names under `boards/`. For the current set of
tested and maintained targets, see [doc/BOARDS_AND_TESTERS.md](doc/BOARDS_AND_TESTERS.md).

For full details — wrapper scripts, Nix local dev, reproducibility verification, and
maintainer workflow — see **[doc/docker.md](doc/docker.md)**.

For CI cache/workspace behavior and the CircleCI job graph, see
**[doc/circleci.md](doc/circleci.md)**.

For QEMU board testing see **[doc/qemu.md](doc/qemu.md)**.

For troubleshooting build issues see **[doc/faq.md](doc/faq.md)** and
**[doc/build-freshness.md](doc/build-freshness.md)**.

## General notes on reproducible builds

In order to build reproducible firmware images, Heads builds a specific
version of gcc and uses it to compile the Linux kernel and various tools
that go into the initrd.  Unfortunately this means the first step is a
little slow since it will clone the `musl-cross-make` tree and build gcc...

Once that is done, the top level `Makefile` will handle most of the
remaining details -- it downloads the various packages, verifies the
hashes, applies Heads specific patches, configures and builds them
with the cross compiler, and then copies the necessary parts into
the `initrd` directory.

There are still dependencies on the build system's coreutils in
`/bin` and `/usr/bin/`, but any problems should be detectable if you
end up with a different hash than the official builds.

## Key components

Heads builds a curated set of packages (from `modules/`). Key components
enabled by most board configs include:

* [musl-cross-make](https://github.com/richfelker/musl-cross-make) — cross-compiler toolchain
* [coreboot](https://www.coreboot.org/) — minimal firmware replacing vendor BIOS/UEFI
* [Linux](https://kernel.org) — minimal kernel payload (no built-in initrd; boots with external initrd such as `initrd.cpio.xz`)
* [busybox](https://busybox.net/) — core utilities
* [kexec](https://wiki.archlinux.org/index.php/kexec) — Linux kernel executor (loads kernels from boot partition, USB, network)
* [tpmtotp](https://github.com/osresearch/tpmtotp) — TPM-based TOTP/HOTP one-time password generator
* [cryptsetup](https://gitlab.com/cryptsetup/cryptsetup) — LUKS disk encryption

The full build also includes: lvm2, tpm2-tools, flashrom/flashprog, dropbear (SSH),
fbwhiptail (GUI), qrencode, and many others. See individual `modules/*` files and
board configs for the complete picture.

We also recommend installing [Qubes OS](https://www.qubes-os.org/),
although there Heads can `kexec` into any Linux or
[multiboot](https://www.gnu.org/software/grub/manual/multiboot/multiboot.html)
kernel.

### Notes

* Building coreboot's cross compilers can take a while.  Luckily this is only done once.
* Builds are finally reproducible! The [reproduciblebuilds tag](https://github.com/osresearch/heads/issues?q=is%3Aopen+is%3Aissue+milestone%3Areproduciblebuilds) tracks any regressions.
* Current tested and maintained boards are tracked in [doc/BOARDS_AND_TESTERS.md](doc/BOARDS_AND_TESTERS.md). Board targets themselves live under `boards/`.
* Xen does not work in QEMU.  Signing, HOTP, and TOTP do work; see below.
* Blob requirements are board- or board-family-specific. Check the relevant documentation under `blobs/` for the target you are building.
* Purism boards use Purism-managed coreboot blob paths from the Purism fork (for example `3rdparty/purism-blobs/...` via `CONFIG_IFD_BIN_PATH` and `CONFIG_ME_BIN_PATH` in `config/coreboot-librem_*.config`). Heads should not maintain those vendor blob payloads. Runtime firmware notes for Librem blob jail are in [blobs/librem_jail/README](blobs/librem_jail/README).
* Lenovo xx20 boards such as X220 and X230 use the shared xx20 blob flow documented in [blobs/xx20/readme.md](blobs/xx20/readme.md). X220-specific notes are in [blobs/x220/readme.md](blobs/x220/readme.md).
* Other boards can source blobs from board-family directories under `blobs/` (for example xx20/xx30/xx80, t420, t440p, w541) or from fork-specific paths configured in coreboot configs (for example Dasharo boards using `3rdparty/dasharo-blobs/...`). Vendor blob payloads remain maintained by their upstream vendors/forks.
* T480 and T480s blob requirements are documented in [blobs/xx80/README.md](blobs/xx80/README.md). Other families have their own docs under `blobs/`, for example `t420/`, `t440p/`, and `w541/`.

### QEMU

OS booting can be tested in QEMU using a software TPM.  HOTP can be tested by forwarding a USB token from the host to the guest.

For more information and setup instructions, refer to the [qemu documentation](doc/qemu.md).

### coreboot console messages

The coreboot console messages are stored in the CBMEM region
and can be read by the Linux payload with the `cbmem --console | less`
command.  There is lots of interesting data about the state of the
system.
