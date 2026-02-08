qemu-coreboot-(fb)whiptail-tpmX(-hotp) boards
===

The `qemu-coreboot-fbwhiptail-tpm1-hotp` configuration (and their variants) permits testing of most features of Heads.  
 It requires a supported USB token (which will be reset for use with the VM, do not use a token needed for a
 real machine).  With KVM acceleration, speed is comparable to a real machine.  If KVM is unavailable,
 lightweight desktops are still usable.

Heads is currently unable to reflash firmware within qemu, which means that OEM reset and re-ownership
 cannot be fully performed within the VM.  Instead, a GPG key can be injected in the Heads image from the
 host during the build.

The TPM and disks for this configuration are persisted in the build/qemu-coreboot-fbwhiptail-tpm1-hotp/ directory by default.

Bootstrapping a working system
===

Important: The supported and tested workflow uses the provided Docker wrappers (`./docker_repro.sh`, `./docker_local_dev.sh`, or `./docker_latest.sh`). Host-side installation of QEMU, `swtpm`, or other QEMU-related tooling is unnecessary and is not part of the standard, supported workflow; only advanced or edge-case scenarios should install those tools on the host (see 'Troubleshooting' below for guidance).

1. Install Docker
   * Install Docker (docker-ce) for your OS by following Docker's official installation guide: https://docs.docker.com/engine/install/

Note: the Nix-built Docker images used by `./docker_repro.sh` include
QEMU (`qemu-system-x86_64`), `swtpm` / `libtpms`, `canokey-qemu` (a
virtual OpenPGP smartcard), and other userspace tooling required to
build and test QEMU targets. These images are intended to be
self-contained for QEMU testing; host-focused build instructions
(e.g., building `swtpm` on the host) were removed to avoid
divergence—use the Docker wrappers for the tested workflow.

If you do not specify `USB_TOKEN` when running QEMU targets, the
container will use the included `canokey-qemu` virtual token by
default. To forward a hardware token from the host, set `USB_TOKEN` or
pass `hostbus`/`hostport`/`vendorid,productid` to the make invocation.

If you plan to manage disk images or use `qemu-img` snapshots on the
host (outside the container), install the `qemu-utils` package locally
(which provides `qemu-img`).


2. Build Heads
   * `./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm1-hotp`
3. Install OS
   * `./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm1-hotp INSTALL_IMG=<~/heads/path_to_iso.iso> run`
   * Lightweight desktops (XFCE, LXDE, etc.) are recommended, especially if KVM acceleration is not available (such nested in Qubes OS)
   * When running nested in a qube, disable memory ballooning for the qube, or performance will be very poor.
   * Include `QEMU_MEMORY_SIZE=6G` to set the guest's memory (`6G`, `8G`, etc.).  The default is 4G to be conservative, but more may be needed depending on the guest OS.
   * Include `QEMU_DISK_SIZE=30G` to set the guest's disk size, the default is `20G`.
4. Shut down and boot Heads with the USB token attached, proceed with OEM reset
   * `./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm1-hotp USB_TOKEN=<token> run`
   * If you do not set `USB_TOKEN`, the included `canokey-qemu` virtual token will be used by default.
   * For `<token>`, use one of:
     * `NitrokeyPro` - a Nitrokey Pro by VID/PID
     * `NitrokeyStorage` - a Nitrokey Storage by VID/PID
     * `Nitrokey3NFC` - a Nitrokey 3 by VID:PID
     * `LibremKey` - a Librem Key by VID/PID
     * `hostbus=#,hostport=#` - indicate a host bus and port (see qemu usb-host)
     * `vendorid=#,productid=#` - indicate a device by VID/PID (decimal, see qemu usb-host)
   * You _do_ need to export the GPG key to a USB disk, otherwise defaults are fine.
   * Head will show an error saying it can't flash the firmware, continue
   * Then Heads will indicate that there is no TOTP code yet, at this point shut down (Continue to main menu -> Power off)
5. Get the public key that was saved to the virtual USB flash drive
   * `sudo mkdir /media/fd_heads_gpg`
   * Attach the image and print the loop device in one step:

     sudo losetup --find --show --partscan ./build/x86/qemu-coreboot-fbwhiptail-tpm1-hotp/usb_fd.raw

     The command prints the loop device used (for example `/dev/loop0`) and the kernel will create partition nodes such as `/dev/loop0p1` and `/dev/loop0p2` when supported.

     Then mount the appropriate partition (usually the second/public partition):

     sudo mount /dev/loop0p2 /media/fd_heads_gpg  # adjust based on the loop device reported above

   * Look in `/media/fd_heads_gpg` and copy the most recent public key
   * `sudo umount /media/fd_heads_gpg`
   * `sudo losetup --detach /dev/loop0`
6. Inject the GPG key into the Heads image and run again
   * `./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm1-hotp PUBKEY_ASC=<path_to_key.asc> inject_gpg`
   * `./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm1-hotp USB_TOKEN=LibremKey PUBKEY_ASC=<path_to_key.asc> run`
7. Initialize the TPM - select "Reset the TPM" at the TOTP error prompt and follow prompts
8. Select "Default boot" and follow prompts to sign /boot for the first time and set a default boot option

You can reuse an already created ROOT_DISK_IMG by passing its path at runtime.
Ex: `./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm1 PUBKEY_ASC=~/pub_key_counterpart_of_usb_dongle.asc USB_TOKEN=NitrokeyStorage ROOT_DISK_IMG=~/heads/build/x86/qemu-coreboot-fbwhiptail-tpm1-hotp/root.qcow2 run`

Note: hardlinks are your friend. You can (should?) have qemu disk images kept somewhere (cp/mv) ~/qemu_img/test.qcow2 and do:
  * `cp -alf ~/qemu_img/test.qcow2 ~/heads/build/x86/qemu-coreboot-fbwhiptail-tpm1-hotp/root.qcow2`

This way, if you accidentally wipe ~/heads/build/x86/qemu-coreboot-fbwhiptail-tpm1-hotp/root.qcow2, the original is kept intact.
Also note that hardlinks share the same underlying data; modifications to one linked copy affect them all, and the filesystem maintains a link count to track how many references exist.

`cp -alf` is basically creating a hardlink to destination overwriting it, and doesn't cost additional disk space.

On a daily development cycle, usage looks like:
1. `./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm1 PUBKEY_ASC=~/pub_key_counterpart_of_usb_dongle.asc USB_TOKEN=NitrokeyStorage ROOT_DISK_IMG=~/heads/build/x86/qemu-coreboot-fbwhiptail-tpm1-hotp/root.qcow2 inject_gpg`
2. `./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm1 PUBKEY_ASC=~/pub_key_counterpart_of_usb_dongle.asc USB_TOKEN=NitrokeyStorage ROOT_DISK_IMG=~/heads/build/x86/qemu-coreboot-fbwhiptail-tpm1-hotp/root.qcow2 run`

The first command builds the latest uncommitted/unsigned changes and injects the public key inside the ROM to be run by the second command.
To test across all qemu variants, one only has to change BOARD name and run the two previous commands, adapting `QEMU_MEMORY_SIZE=1G` or modifying the file directly under build dir to adapt to host resources.


Running via Docker wrappers
===
We provide convenient wrapper scripts at the repository root that encapsulate Docker invocation and automatically handle common host integrations needed for QEMU runs.

Wrapper comparison
---

| Script | Image | Use |
|---|---:|---|
| `docker_latest.sh` | Defaults to pinned digest when available | Convenience: run the latest published image |
| `docker_local_dev.sh` | `linuxboot/heads:dev-env` | Development: use local image built from the flake (rebuilds when flake files are dirty) |
| `docker_repro.sh` | Image pinned from `.circleci/config.yml` | Reproducible builds that match CircleCI |

What the wrappers handle
---

Wrapper options: some runtime behavior is controlled via environment
variables documented in the repository README (see 'Wrapper options &
environment variables'). Wrapper scripts now have focused `--help` output
for their own variables, and `./docker/common.sh` prints the full
environment reference. Important ones are `HEADS_DISABLE_USB`
(set to `1` to disable automatic USB passthrough and cleanup) and
`HEADS_X11_XAUTH` (force mounting your `$HOME/.Xauthority`).

Make variables such as `USB_TOKEN`, `PUBKEY_ASC`, `INSTALL_IMG`,
`QEMU_MEMORY_SIZE`, `QEMU_DISK_SIZE`, `ROOT_DISK_IMG`, `CPUS` and `V`
are forwarded to the `make` invocation and affect how
`targets/qemu.mk` runs QEMU. See `targets/qemu.mk` for token formats
and examples.

Note: when USB passthrough is active the wrapper will warn and, on
interactive shells, give a 3s abort window before attempting to kill
processes that hold the token (e.g., `scdaemon`/`pcscd`) to free the
device; set `HEADS_DISABLE_USB=1` to opt out.

- **KVM passthrough**: when `/dev/kvm` exists on the host the container is run with `/dev/kvm` mounted into the container, enabling KVM-accelerated QEMU.
- **X11 GUI support**: the wrappers mount the X11 socket and programmatically create a temporary Xauthority file (via `mktemp -t heads-docker-xauth-XXXXXX`, or `/tmp/.docker.xauth-<uid>` as fallback when mktemp is unavailable) when `xauth` is available; they fall back to mounting `${HOME}/.Xauthority` when needed and set `XAUTHORITY` inside the container so GTK/SDL QEMU windows work. The temp file is cleaned up automatically after `docker run` completes.
  - To force mounting your `${HOME}/.Xauthority` regardless of socket detection, set `HEADS_X11_XAUTH=1`.
- **USB passthrough**: when host USB buses exist `/dev/bus/usb` is mounted into the container so VMs can access hardware tokens. To explicitly disable automatic USB passthrough set `HEADS_DISABLE_USB=1`.
- **USB token cleanup**: the wrappers attempt to detect and stop local GPG/toolstack processes (e.g., `scdaemon`, `pcscd`) which might hold USB tokens. Behavior notes:
  - If `sudo` can be run without a password the cleanup runs silently.
  - The cleanup avoids prompting for a password in non-interactive shells; it will prompt only when running interactively (attached to a TTY). To skip the cleanup entirely set `HEADS_DISABLE_USB=1`.
- **Convenience variables accepted by the wrappers**: `V=1` for verbose make output, `CPUS=N` to set parallelism for builds, and any `make` variables may be passed through to the container command.
- **Argument forwarding**: arguments given to the wrapper are forwarded directly to the container command (no special separator needed). For example: `./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 run`.

Environment variables reference
---

| Variable | Default | Effect |
|---|---:|---|
| `HEADS_DISABLE_USB` | `0` | When `1`, disable automatic USB passthrough and USB cleanup |
| `HEADS_X11_XAUTH` | `0` | When `1`, mount `${HOME}/.Xauthority` into the container (force usage even when a programmatic Xauthority would otherwise be created) |
| `HEADS_SKIP_DOCKER_REBUILD` | `0` | When `1`, skip rebuilding the local Docker image when `flake.nix`/`flake.lock` are dirty |
| `HEADS_AUTO_INSTALL_NIX` | `0` | When `1`, automatically attempt single-user Nix install if `nix` is missing (suppresses prompt) |
| `HEADS_AUTO_ENABLE_FLAKES` | `0` | When `1`, automatically enable flakes by writing to `$HOME/.config/nix/nix.conf` (suppresses prompt) |
| `HEADS_MIN_DISK_GB` | `50` | Minimum free disk in GB required on `/nix` or `/` before attempting rebuild |
| `HEADS_SKIP_DISK_CHECK` | `0` | When `1`, skip the disk-space preflight check |

Examples
---

- Reproducible (uses image version from CircleCI config):
  - `./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 run`
  - `./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 PUBKEY_ASC=pubkey.asc USB_TOKEN=Nitrokey3NFC inject_gpg`
  - `HEADS_DISABLE_USB=1 ./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 PUBKEY_ASC=pubkey.asc run`
  - `HEADS_X11_XAUTH=1 ./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 run`

- Local development image (uses locally built `linuxboot/heads:dev-env`):
  - `./docker_local_dev.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2`

- Published latest image (convenience):
  - `./docker_latest.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 run`

How I tested these wrappers (smoke checks)
---

- Minimal: `source docker/common.sh && build_docker_opts` — should print a short description and show flags such as `--device=/dev/kvm` when KVM is available and `-v /tmp/heads-docker-xauth-XXXXXX:...` (or `-v /tmp/.docker.xauth-<uid>:...` as fallback) when Xauthority was created.
- Functional (examples tested by PR author): see the tests in the PR body (Ubuntu, Debian, Fedora installer flows). Consider testing `./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 run` locally to verify KVM+GTK behavior.

Troubleshooting
---

- Quick checks:
  - `echo $DISPLAY` — ensure `DISPLAY` is set on the host.
  - `command -v xauth` — preferred for programmatic Xauthority cookies.
  - `ls -l /dev/kvm` — verify `/dev/kvm` exists and is accessible.
  - `groups | grep -q kvm` — confirm your user is in a group with access to KVM (or run with appropriate privileges).
  - `source docker/common.sh && build_docker_opts` — inspect the options the wrapper will use without launching Docker.
- GUI issues: prefer installing `xauth` on the host so the wrappers can create a safe programmatic Xauthority file. As a last resort you can run `xhost +SI:localuser:root` (less secure).
- USB/GPG cleanup: if the cleanup is refusing to run due to non-interactive sudo, run the kill steps manually or set `HEADS_DISABLE_USB=1` to skip automatic cleanup.

Notes
---
- Ensure you have an X server available on the host; the wrappers forward `DISPLAY` automatically.
- If KVM is available but `/dev/kvm` is missing, load kernel modules (e.g., `kvm`, `kvm_intel`, `kvm_amd`) so `/dev/kvm` appears.
