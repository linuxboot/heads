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

If you plan to manage disk images on the host (outside the container),
install `qemu-utils` for `qemu-img`.  Mounting uses `losetup` (from
`util-linux`, present on all Linux distributions):

    sudo losetup --find --show --partscan \
      ./build/x86/<board>/usb_fd.raw
    # → /dev/loopN; use sudo fdisk -l /dev/loopN to check partitions
    sudo mount /dev/loopNp1 /mnt   # partitioned, or /dev/loopN if flat

The Makefile creates `usb_fd.raw` (sparse — ~200K for a 64G virtual
disk, grows only as ISOs are copied in) with an MBR partition table
and ext4 filesystem.  Older images (from before `qemu-img create`)
may be flat — check with `sudo fdisk -l` first.

Note: the Docker container bind-mounts only the cloned Heads directory
(`$(pwd)`), so images must reside within the clone — use the `qemu_img/`
directory inside the repo as a backing store (see hardlink workflow below).


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
    * Attach the raw image and mount the public partition:

        sudo losetup --find --show --partscan \
          ./build/x86/qemu-coreboot-fbwhiptail-tpm1-hotp/usb_fd.raw
        # → prints /dev/loopN with /dev/loopNp1, /dev/loopNp2, etc.
        sudo fdisk -l /dev/loopN          # verify partition layout
        sudo mount /dev/loopNp2 /media/fd_heads_gpg  # second/public partition

    * Look in `/media/fd_heads_gpg` and copy the most recent public key
    * `sudo umount /media/fd_heads_gpg`
    * `sudo losetup -d /dev/loopN`  # detach (replace N with the actual number)
6. Inject the GPG key into the Heads image and run again
   * `./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm1-hotp PUBKEY_ASC=<path_to_key.asc> inject_gpg`
   * `./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm1-hotp USB_TOKEN=LibremKey PUBKEY_ASC=<path_to_key.asc> run`
7. Initialize the TPM - select "Reset the TPM" at the TOTP error prompt and follow prompts
8. Select "Default boot" and follow prompts to sign /boot for the first time and set a default boot option

You can reuse an already created ROOT_DISK_IMG by passing its path at runtime.
Ex: `./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm1 PUBKEY_ASC=~/pub_key_counterpart_of_usb_dongle.asc USB_TOKEN=NitrokeyStorage ROOT_DISK_IMG=~/heads/build/x86/qemu-coreboot-fbwhiptail-tpm1-hotp/root.qcow2 run`

## Saving Disk Images from Build-Dir Wipes

**The Docker container can only see files inside the cloned Heads directory**
(`docker/common.sh` line 1446: `-v "$(pwd):$(pwd)"`).  Any backup copy
must live at a path inside the clone — `~/QemuImages/` and other
user-home paths are invisible to Docker.

**The build directory (`build/x86/<board>/`) is ephemeral.**  A `make clean`
or fresh checkout deletes `build/` entirely, including installed OS images
and populated USB disks.  Use hardlinks to keep safe copies inside the
clone and share across board variants:

    mkdir -p qemu_img                         # safe storage inside clone
    cp build/x86/<board>/root.qcow2 qemu_img/ # copy OS install to safety
    rm build/x86/<board>/root.qcow2           # remove build-tree copy
    cp -alf qemu_img/root.qcow2 build/x86/<board>/  # hardlink back
    # Now both paths point to the same data on disk.
    # Wiping build/ won't touch qemu_img/.

    # Restore after a wipe:
    cp -alf qemu_img/root.qcow2 build/x86/<board>/root.qcow2
    cp -alf qemu_img/usb_fd.img  build/x86/<board>/usb_fd.raw

`cp -alf` creates a hardlink — a second directory entry pointing to the
same data blocks (zero additional space).  Data is freed only when the
last link is deleted.  **Caveat:** writes to one link affect all links.
Use `qemu-img snapshot` before modifying the root disk.

### USB flash drive workflow

```bash
mkdir -p qemu_img                             # safe storage inside clone

# Step 1: Create the USB image via the Makefile.
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 \
  QEMU_USB_SIZE=64G run
# → build/x86/.../usb_fd.raw now exists.

# Step 2: Save a master copy IMMEDIATELY (before population).
cp build/x86/qemu-coreboot-fbwhiptail-tpm2/usb_fd.raw qemu_img/usb_fd.img
rm build/x86/qemu-coreboot-fbwhiptail-tpm2/usb_fd.raw
cp -alf qemu_img/usb_fd.img build/x86/qemu-coreboot-fbwhiptail-tpm2/usb_fd.raw

# Step 3: Populate with ISOs.
sudo losetup --find --show --partscan build/x86/.../usb_fd.raw
sudo mount /dev/loop0p1 /mnt
cp ~/Downloads/ISOs/*.iso /mnt/
sudo umount /mnt && sudo losetup -d /dev/loop0

# Step 4: Hardlink into other board build directories.
cp -alf qemu_img/usb_fd.img build/x86/qemu-coreboot-fbwhiptail-tpm1-hotp/usb_fd.raw
cp -alf qemu_img/usb_fd.img build/x86/qemu-coreboot-fbwhiptail-tpm2-hotp/usb_fd.raw

# Next run uses the hardlink — Makefile skips creation since the file exists.
```

### Daily development cycle

After OS install + USB provisioned, reference both from `./qemu_img/`:

    ./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm1-hotp \
      PUBKEY_ASC=pubkey.asc \
      USB_TOKEN=Nitrokey3NFC \
      ROOT_DISK_IMG=./qemu_img/root.qcow2 \
      inject_gpg run


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
`QEMU_MEMORY_SIZE`, `QEMU_DISK_SIZE`, `QEMU_USB_SIZE`,
`ROOT_DISK_IMG`, `CPUS` and `V`
are forwarded to the `make` invocation and affect how
`targets/qemu.mk` runs QEMU. See `targets/qemu.mk` for token formats
and examples.

The virtual USB flash drive (`usb_fd.qcow2` by default, or `usb_fd.raw`
if an existing raw image from a previous build is found) is created at
build time under `build/x86/<BOARD>/`.  Default virtual size is 64 GB
— overridable via `QEMU_USB_SIZE`.  QCOW2 is sparse: only written blocks
consume host disk space (initial size ~200K).  Raw files are also sparse
when created via `qemu-img create -f raw`.

The Makefile auto-detects: if `usb_fd.raw` exists in the build directory,
it's used directly; otherwise it creates a new `usb_fd.qcow2` from a
raw temp (partitioned + formatted via losetup, then converted to qcow2).
The conversion is sparse — only written blocks are preserved.

See **Hardlinks for Reusable Images** above for the recommended workflow:
save a master copy immediately, hardlink it back into the build directory,
then populate it (which modifies the shared blocks).

Quick mount reference (after following the hardlink workflow):

```bash
sudo losetup --find --show --partscan \
  build/x86/qemu-coreboot-fbwhiptail-tpm2/usb_fd.raw
# → /dev/loopN; check partitions with sudo fdisk -l /dev/loopN
sudo mount /dev/loopNp1 /mnt   # or /dev/loopN if flat
cp ~/Downloads/ISOs/*.iso /mnt/
sudo umount /mnt && sudo losetup -d /dev/loopN

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

Resetting state
---

QEMU boards using the default virtual token persist canokey and TPM state
between runs.  To simulate a fresh dongle and TPM for testing:

```bash
# Wipe the virtual Canokey (new dongle, no keys on card).
sudo rm -f build/x86/<BOARD>/.canokey-file

# Wipe the virtual TPM (new TPM, no sealed secrets or counters).
sudo rm -rf build/x86/<BOARD>/vtpm/
```

The next `make run` will create fresh `.canokey-file` and `vtpm/`
directories automatically.  The Heads setup wizard will then offer OEM
factory reset (F) or reprovision from backup (K).

To preserve canokey state for reuse:

```bash
cp build/x86/<BOARD>/.canokey-file ~/Qemu_img/.canokey-file.bak
cp ~/Qemu_img/.canokey-file.bak build/x86/<BOARD>/.canokey-file
```

Troubleshooting
---

- Reuse provisioned canokey state across QEMU board build dirs:
  - QEMU boards that use the default virtual token store canokey state at `build/x86/<BOARD>/.canokey-file` (from `targets/qemu.mk`: `-device canokey,file=$(build)/$(BOARD)/.canokey-file`).
  - After provisioning via Heads OEM reset/re-ownership in one QEMU board, you can copy that file into another QEMU board build directory to reuse the same virtual smartcard identity/public key material.
  - Example:
    - `cp build/x86/qemu-coreboot-fbwhiptail-tpm2/.canokey-file build/x86/qemu-coreboot-fbwhiptail-tpm2-prod_quiet/.canokey-file`
  - This is useful when troubleshooting TPM workflows while keeping the same token identity across variants.

- TPM2 interaction capture (pcap) for debugging, similar to a bus sniffer:
  - On TPM2 boards, set `export CONFIG_TPM2_CAPTURE_PCAP=y` in the board config.
  - Heads `tpmr` then uses the pcap TCTI and writes captures to `/tmp/tpm0.pcap` inside the booted Heads environment.
  - Save/copy that file from the guest (mount-usb --mode rw) and inspect it with Wireshark to analyze TPM command/response traffic.
  - This is intended for TPM2 boards (for example the `qemu-coreboot-fbwhiptail-tpm2*` targets).

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
