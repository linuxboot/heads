![Heads booting on an x230](https://user-images.githubusercontent.com/827570/156627927-7239a936-e7b1-4ffb-9329-1c422dc70266.jpeg)

Heads: the other side of TAILS
==

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

Documentation
===
Please refer to [Heads-wiki](https://osresearch.net) for your Heads' documentation needs.

Contributing
===
We welcome contributions to the Heads project! Before contributing, please read our [Contributing Guidelines](CONTRIBUTING.md) for information on how to get started, submit issues, and propose changes.


Building heads with prebuilt and versioned docker images
==

Heads now builds with Nix built docker images since https://github.com/linuxboot/heads/pull/1661.

The short path to build Heads is to do what CircleCI would do (./docker_repro.sh under heads git cloned directory):
- Install Docker (docker-ce) for your OS by following Docker's official installation instructions: https://docs.docker.com/engine/install/
- run `./docker_repro.sh make BOARD=XYZ`

Note: `./docker_repro.sh` is the canonical, reproducible way to build and test Heads. The `docker_local_dev.sh` helper is intended for developers who need to modify the local image built from `flake.nix`/`flake.lock` and is not recommended for general testing.

Important: the supported and tested workflow uses the provided Docker
wrappers (`./docker_repro.sh`, `./docker_local_dev.sh`, or
`./docker_latest.sh`). Host-side installation of QEMU, `swtpm`, or other
QEMU-related tooling is unnecessary for the standard workflow and is not
part of the tested configuration. Only advanced or edge-case workflows
may require installing those tools on the host (see `targets/qemu.md`
for guidance).

The Docker images produced by our Nix build include QEMU
(`qemu-system-x86_64`), `swtpm` / `libtpms`, `canokey-qemu` (a virtual
OpenPGP smartcard), and other userspace tooling required to build and
test QEMU boards. If you use `./docker_repro.sh` you only need Docker on
the host (for example, `docker-ce`). For KVM acceleration the host
must expose `/dev/kvm` (load `kvm_intel` / `kvm_amd` as appropriate);
our wrapper scripts mount `/dev/kvm` automatically when it exists.

If you plan to manage disk images or use `qemu-img` snapshots on the
host (outside containers), install the `qemu-utils` package locally
(which provides `qemu-img`).

If you do not specify `USB_TOKEN` when running QEMU targets, the container will use the included `canokey-qemu` virtual token by default; set `USB_TOKEN` (or use `hostbus`/`hostport`/`vendorid,productid`) to forward a hardware token instead.

Wrapper options & environment variables
---

`./docker_repro.sh` `./docker_latest.sh` `./docker_local_dev.sh`:
- `HEADS_DISABLE_USB=1` — disable automatic USB passthrough and the
  automatic USB cleanup (default: `0`).
- `HEADS_X11_XAUTH=1` — force mounting your `${HOME}/.Xauthority` into the container for X11 authentication. When set the helper will bypass programmatic Xauthority generation and mount your `${HOME}/.Xauthority` (if present); if the file is missing the helper will warn and will not attempt automatic cookie creation (GUI may fail).

`./docker_local_dev.sh`:
- `HEADS_SKIP_DOCKER_REBUILD=1` — skip automatically rebuilding the local image when `flake.nix`/`flake.lock` are dirty
- `HEADS_NIX_EXTRA_FLAGS` — extra flags to append to Nix commands during rebuild.
  This variable is parsed as shell words (so quoted multi-word values are preserved). For example:

      export HEADS_NIX_EXTRA_FLAGS="--extra-experimental-features 'nix-command flakes'"

  Note: do not set this from untrusted input because the value is evaluated as shell words.
- `HEADS_NIX_VERBOSE=1` — stream Nix output live during rebuilds (default: on for dev scripts)
- `HEADS_AUTO_INSTALL_NIX=1` — automatically attempt to download the Nix single-user installer when `nix` is missing (interactive prompt suppressed). *For supply-chain safety the script now downloads the installer to a temporary file and prints its SHA256; the installer is not executed automatically. The script will prompt you interactively and you must confirm execution, or you can run the installer manually after verifying its checksum.*
- `HEADS_AUTO_ENABLE_FLAKES=1` — automatically enable flakes by writing `experimental-features = nix-command flakes` to `$HOME/.config/nix/nix.conf` (interactive prompt suppressed)
- `HEADS_MIN_DISK_GB` — minimum free disk space in GB required on `/nix` (or `/` if `/nix` missing) for building (default: `50`)
- `HEADS_SKIP_DISK_CHECK=1` — skip the preflight disk-space check
- `HEADS_STRICT_REBUILD=1` — when set, treat rebuild failures (including `No 'fromImage' provided`) as fatal
- `HEADS_ALLOW_UNPINNED_LATEST=1` — when set, bypass the interactive warning that using `:latest` in `./docker_latest.sh` is a supply-chain risk (otherwise `:latest` requires confirmation or set `DOCKER_LATEST_DIGEST`)
- `DOCKER_REPRO_DIGEST` — pin the image used by `./docker_repro.sh` to an immutable digest: `tlaurion/heads-dev-env@<digest>` (recommended for reproducible and secure builds). Note: `DOCKER_REPRO_DIGEST` is *consumed by* `./docker_repro.sh` (via `resolve_docker_image` in `docker/common.sh`) and is the canonical way to pin the repro image for reproducible builds.

For details about selecting or forwarding a physical USB token to QEMU
(handled by the `USB_TOKEN` make variable), see `targets/qemu.md`.

Note: when USB passthrough is active the wrappers will detect processes that may be holding a USB token (for example `scdaemon` or `pcscd`). The wrapper will warn and, on interactive shells, give a 3s abort window before attempting to kill those processes to free the token. Set `HEADS_DISABLE_USB=1` to opt out of this automatic cleanup.

Example: `HEADS_DISABLE_USB=1 ./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 run`

Using Nix local dev environement / building docker images with Nix
==

Under QubesOS?
===
* Setup nix persistent layer under QubesOS (Thanks @rapenne-s !)
  * https://dataswamp.org/~solene/2023-05-15-qubes-os-install-nix.html
* Install docker under QubesOS (imperfect old article of mine. Better somewhere?)
  * https://gist.github.com/tlaurion/9113983bbdead492735c8438cd14d6cd

Build docker from nix develop layer locally
===

#### Set up Nix and flakes  

* If you don't already have Nix, install it:
    * `[ -d /nix ] || sh <(curl -L https://nixos.org/nix/install) --no-daemon`
    * `. /home/user/.nix-profile/etc/profile.d/nix.sh`
* Enable flake support in nix
    * `mkdir -p ~/.config/nix`
    * `echo 'experimental-features = nix-command flakes' >>~/.config/nix/nix.conf`

Notes on automation and requirements:

- The `./docker_local_dev.sh` helper will attempt to ensure Nix and flakes are available when you run it interactively. If Nix is missing it can optionally install it for you and prompt to enable flakes; set `HEADS_AUTO_INSTALL_NIX=1` / `HEADS_AUTO_ENABLE_FLAKES=1` to suppress prompts.
- Building the Docker image and populating `/nix` can require significant disk space — we recommend at least **50 GB** free on `/nix` (or `/` if `/nix` is not present). Adjust via `HEADS_MIN_DISK_GB` or skip the check with `HEADS_SKIP_DISK_CHECK=1`.
- The Nix installer requires a downloader; either `curl` or `wget` must be available on the host. The helper will guide you to install one if neither is present.
- For reproducible builds prefer `./docker_repro.sh`; `./docker_local_dev.sh` is intended for development and will rebuild the local image when `flake.nix`/`flake.lock` are dirty (unless `HEADS_SKIP_DOCKER_REBUILD=1`).

#### Build image

* Have docker and Nix installed

* Build nix developer local environment with flakes locked to specified versions  
    * Manual: `nix --print-build-logs --verbose build .#dockerImage && docker load < result`  
    * Helper: `./docker_local_dev.sh` will perform a conditional rebuild when `flake.nix`/`flake.lock` are dirty (unless `HEADS_SKIP_DOCKER_REBUILD=1`).

Using `./docker_local_dev.sh`

* `./docker_local_dev.sh` is a developer helper that ensures a local Nix-based Docker image (`linuxboot/heads:dev-env`) is available for interactive development. It performs a few preflight checks and interactive prompts to make the process easier:
  - Ensures `nix` is installed and **flakes** are enabled; if missing it will prompt to install Nix and enable flakes. Set `HEADS_AUTO_INSTALL_NIX=1` and/or `HEADS_AUTO_ENABLE_FLAKES=1` to suppress prompts and proceed automatically.
  - Requires either `curl` or `wget` to fetch the Nix installer; if neither is present the script will print how to install one and abort.
  - Checks disk space on `/nix` (or `/` if `/nix` is absent); default minimum is **50 GB** (`HEADS_MIN_DISK_GB=50`) — override or skip the check with `HEADS_SKIP_DISK_CHECK=1`.
  - If `flake.nix` or `flake.lock` are dirty (uncommitted changes), the helper will rebuild the local Docker image. Skip automatic rebuilds with `HEADS_SKIP_DOCKER_REBUILD=1`.
  - Nix output is streamed live by default (`HEADS_NIX_VERBOSE=1`). You can pass additional Nix flags via `HEADS_NIX_EXTRA_FLAGS`.
  - If the Nix build reports `No 'fromImage' provided` (expected when no base image is used), the helper continues by default; set `HEADS_STRICT_REBUILD=1` to make such errors fatal.

On some hardened OSes, you may encounter problems with ptrace.
```
       > proot error: ptrace(TRACEME): Operation not permitted
```
The most likely reason is that your [kernel.yama.ptrace_scope](https://www.kernel.org/doc/Documentation/security/Yama.txt) variable is too high and doesn't allow docker+nix to run properly.
You'll need to set kernel.yama.ptrace_scope to 1 while you build the heads binary.

```
sudo sysctl kernel.yama.ptrace_scope #show you the actual value, probably 2 or 3
sudo sysctl -w kernel.yama.ptrace_scope=1 #setup the value to let nix+docker run properly
```
(don't forget to put back the value you had after finishing build head)

Done!

Your local docker image "linuxboot/heads:dev-env" is ready to use, reproducible for the specific Heads commit used to build it, and will produce ROMs reproducible for that Heads commit ID.

Jump into nix develop created docker image for interactive workflow
====
There are three helpers:
- `./docker_local_dev.sh`: developer-only — customize the local image built from `flake.nix`/`flake.lock` (not recommended for general testing)
- `./docker_latest.sh`: convenience — use the latest published Docker image for development
- `./docker_repro.sh`: canonical, reproducible builds that match CircleCI; **this is the recommended way to build and test Heads**

ie: `./docker_repro.sh` will jump into CircleCI used versioned docker image for that Heads commit id to build images reproducibly if git repo is clean (not dirty).

From there you can use the docker image interactively.

Use `./docker_repro.sh make BOARD=board_name` to run builds and tests (this runs `make` inside the canonical Docker image). 
If you are already inside the container interactively, run `make BOARD=board_name` as usual.


One such useful example is to build and test qemu board roms and test them through qemu/kvm/swtpm provided in the docker image. 
Please refer to [qemu documentation](targets/qemu.md) for more information.

Eg:
```
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 # Build rom, export public key to emulated usb storage from qemu runtime
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 PUBKEY_ASC=~/pubkey.asc inject_gpg # Inject pubkey into rom image
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 USB_TOKEN=Nitrokey3NFC PUBKEY_ASC=~/pubkey.asc ROOT_DISK_IMG=~/qemu-disks/debian-9.cow2 INSTALL_IMG=~/Downloads/debian-9.13.0-amd64-xfce-CD-1.iso run # Install
```

Alternatively, you can use locally built docker image to build a board ROM image in a single call **but do not expect reproducible builds if not using versioned docker images as per CircleCI as per usage of `./docker_repro.sh`**

Eg:
`./docker_local_dev.sh make BOARD=nitropad-nv41`


Pull docker hub image to prepare reproducible ROMs as CircleCI in one call
====

Pinning the reproducible image
---

- `DOCKER_REPRO_DIGEST` — pin the image used by `./docker_repro.sh` to an immutable digest: `tlaurion/heads-dev-env@<digest>`. This environment variable (or the repository file `docker/DOCKER_REPRO_DIGEST`) is *consumed by* `./docker_repro.sh` via `resolve_docker_image()`; pinning ensures reproducible builds and mitigates supply-chain risk from mutable `:latest` tags.

```
./docker_repro.sh make BOARD=x230-hotp-maximized
./docker_repro.sh make BOARD=nitropad-nv41
```

Maintenance notes on docker image
===
Redo the steps above in case the flake.nix or nix.lock changes. Commit changes. Then publish on docker hub:

```
#put relevant things in variables:
docker_version="vx.y.z" && docker_hub_repo="tlaurion/heads-dev-env"
#update pinned packages to latest available ones if needed, modify flake.nix derivatives if needed:
nix flakes update
#modify CircleCI image to use newly pushed docker image
sed "s@\(image: \)\(.*\):\(v[0-9]*\.[0-9]*\.[0-9]*\)@\1\2:$docker_version@" -i .circleci/config.yml
# commit changes
git commit --signoff -m "Bump nix develop based docker image to $docker_hub_repo:$docker_version"
#use commited flake.nix and flake.lock in nix develop
nix --print-build-logs --verbose develop --ignore-environment --command true
#build new docker image from nix develop environement
nix --print-build-logs --verbose build .#dockerImage && docker load < result
#tag produced docker image with new version
docker tag linuxboot/heads:dev-env "$docker_hub_repo:$docker_version"
#push newly created docker image to docker hub
docker push "$docker_hub_repo:$docker_version"
#test with CircleCI in PR. Merge.
git push ...
#make last tested docker image version the latest
docker tag "$docker_hub_repo:$docker_version" "$docker_hub_repo:latest"
docker push "$docker_hub_repo:latest"
```

This can be put in reproducible oneliners to ease maintainership.

Maintenance tip: to make pinned, reproducible images easy to manage inside the repository, maintainers should pin the canonical reproducible image using the repository file `docker/DOCKER_REPRO_DIGEST`, which is read by `./docker_repro.sh`.

Acceptable formats include `sha256:<64-hex>`, `sha256-<64-hex>` (normalized to `sha256:<hex>`), or just `<64-hex>` (normalized to `sha256:<hex>`). The helper will normalize these formats and produce an image reference like `tlaurion/heads-dev-env@sha256:<hex>`.

If you need to pin the convenience `./docker_latest.sh` wrapper, set the `DOCKER_LATEST_DIGEST` environment variable locally; we do not maintain a `docker/DOCKER_LATEST_DIGEST` file in the repository because 'latest' is a user-level convenience and should be explicitly chosen. Without a digest, `./docker_latest.sh` will prompt before using an unpinned `:latest` unless `HEADS_ALLOW_UNPINNED_LATEST=1` is set in the environment.

Example: obtain the immutable digest for a published image and use it to force `docker_latest.sh` to use an immutable image:

```bash
# 1) Obtain the digest for a published image (exact repo:name:tag form is required)
#
# Tip: inspect tags on Docker Hub: https://hub.docker.com/layers/tlaurion/heads-dev-env/
# Click a tag to see details (Content type, Digest (sha256:...), Size, Last updated).
# Use the shown tag name with docker pull, e.g.:
#   docker pull tlaurion/heads-dev-env:v0.2.6
#
# Example: pull the image and then obtain its digest locally
#   docker pull tlaurion/heads-dev-env:v0.2.6
#   ./docker/get_digest.sh tlaurion/heads-dev-env:v0.2.6
#
# Or: query the registry for the digest and optionally pull it when prompted
#   ./docker/get_digest.sh tlaurion/heads-dev-env:v0.2.6
#   (the script will show the remote digest and ask if you want to pull the image to create a local repo@digest)
#
# Use -y to auto-pull and return the digest in one go:
#   ./docker/get_digest.sh -y tlaurion/heads-dev-env:v0.2.6

./docker/get_digest.sh tlaurion/heads-dev-env:v0.2.6
# Output (example): tlaurion/heads-dev-env@sha256:50a9110c...\nsha256:50a9110c...

# 2) If the image is not present locally, the helper will offer to pull it so a local repo@digest is available.
#    Use '-y' / '--yes' to skip the interactive prompt and pull automatically.
./docker/get_digest.sh -y tlaurion/heads-dev-env:latest

# 3) Export the raw digest into the env var expected by the wrapper
export DOCKER_LATEST_DIGEST=$(./docker/get_digest.sh tlaurion/heads-dev-env:latest | tail -n1)

# 4) Run the convenience wrapper using the pinned digest
DOCKER_LATEST_DIGEST=$DOCKER_LATEST_DIGEST ./docker_latest.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2

Note: when a digest is discovered, helpers print a concise summary to help auditing, for example:

  Image: tlaurion/heads-dev-env@sha256:50a9...
  Digest: sha256:50a9...
  Resolved from: local|registry API|env|file
  Tip: export DOCKER_LATEST_DIGEST=sha256:50a9...

This makes it easy to copy/pin digests or verify provenance.
# Convenience: helper to obtain a digest and run a wrapper pinned to that digest
# Example: obtains digest and runs the 'latest' wrapper pinned to that digest (explicit wrapper is recommended)
./docker/pin-and-run.sh tlaurion/heads-dev-env:v0.2.6 -- ./docker_latest.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2
# Auto-pull and run (non-interactive)
./docker/pin-and-run.sh -y tlaurion/heads-dev-env:v0.2.6 -- ./docker_latest.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2

# Shortcut: omit the wrapper and just provide the command — the helper will use the default './docker_latest.sh'
./docker/pin-and-run.sh tlaurion/heads-dev-env:v0.2.6 -- make BOARD=qemu-coreboot-fbwhiptail-tpm2

# Explicit wrapper flag: use -w/--wrapper to avoid ambiguity
./docker/pin-and-run.sh -w ./docker_repro.sh tlaurion/heads-dev-env:v0.2.6 -- make BOARD=qemu-coreboot-fbwhiptail-tpm2


```

Alternative (manual) commands without the helper script:

```bash
docker pull tlaurion/heads-dev-env:latest
# prints full repo@digest (if available)
docker inspect --format='{{index .RepoDigests 0}}' tlaurion/heads-dev-env:latest
# to get only the digest portion:
docker inspect --format='{{index .RepoDigests 0}}' tlaurion/heads-dev-env:latest | cut -d'@' -f2
```

Notes: some registries or Docker versions may require `docker manifest inspect` or `skopeo inspect` to obtain an authoritative digest; the helper script tries `docker inspect` first, then `docker manifest inspect` when available.

Update the appropriate file after publishing a new image to keep the repo in sync.

Test image in dirty mode:
```
docker_version="vx.y.z" && docker_hub_repo="tlaurion/heads-dev-env" && sed "s@\(image: \)\(.*\):\(v[0-9]*\.[0-9]*\.[0-9]*\)@\1\2:$docker_version@" -i .circleci/config.yml && nix --print-build-logs --verbose develop --ignore-environment --command true && nix --print-build-logs --verbose build .#dockerImage && docker load < result && docker tag linuxboot/heads:dev-env "$docker_hub_repo:$docker_version" && docker push "$docker_hub_repo:$docker_version"
```

Notes:
- Local builds can use ":latest" tag, which will use latest tested successful CircleCI run
- To reproduce CirlceCI results, make sure to use the same versioned tag declared under .circleci/config.yml's "image:" 



General notes on reproducible builds
===
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

The various components that are downloaded are in the `./modules`
directory and include:

* [musl-libc](https://www.musl-libc.org/)
* [busybox](https://busybox.net/)
* [kexec](https://wiki.archlinux.org/index.php/kexec)
* [mbedtls](https://tls.mbed.org/)
* [tpmtotp](https://trmm.net/Tpmtotp)
* [coreboot](https://www.coreboot.org/)
* [cryptsetup](https://gitlab.com/cryptsetup/cryptsetup)
* [lvm2](https://sourceware.org/lvm2/)
* [gnupg](https://www.gnupg.org/)
* [Linux kernel](https://kernel.org)

We also recommend installing [Qubes OS](https://www.qubes-os.org/),
although there Heads can `kexec` into any Linux or
[multiboot](https://www.gnu.org/software/grub/manual/multiboot/multiboot.html)
kernel.

Notes:
---

* Building coreboot's cross compilers can take a while.  Luckily this is only done once.
* Builds are finally reproducible! The [reproduciblebuilds tag](https://github.com/osresearch/heads/issues?q=is%3Aopen+is%3Aissue+milestone%3Areproduciblebuilds) tracks any regressions.
* Currently only tested in QEMU, the Thinkpad x230, Librem series and the Chell Chromebook.
** Xen does not work in QEMU.  Signing, HOTP, and TOTP do work; see below.
* Building for the Lenovo X220 requires binary blobs to be placed in the blobs/x220/ folder.
See the readme.md file in that folder
* Building for the Librem 13 v2/v3 or Librem 15 v3/v4 requires binary blobs to be placed in
the blobs/librem_skl folder. See the readme.md file in that folder

QEMU:
---

OS booting can be tested in QEMU using a software TPM.  HOTP can be tested by forwarding a USB token from the host to the guest.

For more information and setup instructions, refer to the [qemu documentation](targets/qemu.md).

coreboot console messages
---
The coreboot console messages are stored in the CBMEM region
and can be read by the Linux payload with the `cbmem --console | less`
command.  There is lots of interesting data about the state of the
system.
