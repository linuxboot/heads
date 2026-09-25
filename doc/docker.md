# Heads Docker Build Environment

Heads builds inside a versioned Docker image that provides a consistent build
environment. ROM reproducibility still depends on matching source and build
inputs. Docker images are built with Nix since
[PR #1661](https://github.com/linuxboot/heads/pull/1661).  `flake.nix` and
`flake.lock` define the local image's Nix inputs; the published image selected
by `docker_repro.sh` is pinned separately through `docker/DOCKER_REPRO_DIGEST`
(or its environment override) and cross-checked against the canonical CI image
pin.  A local image build does not by itself establish bit-identical ROM output.

See also: [General reproducible-build notes](../README.md#general-notes-on-reproducible-builds),
[Reproducible build practices](reproducible-builds.md),
[QEMU testing](qemu.md), [CircleCI pipeline notes](circleci.md).

---

## Quick start

The short path to build Heads is to do what CircleCI does:

- Install [Docker CE](https://docs.docker.com/engine/install/) for your OS
- Run `./docker_repro.sh make BOARD=XYZ`

```bash
# Pinned-image build (recommended for all users)
./docker_repro.sh make BOARD=EOL_x230-hotp-maximized

# Build and run a QEMU board
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 run
```

`./docker_repro.sh` is the canonical wrapper for the configured pinned image.
`docker_local_dev.sh` is intended for developers who need to modify the local image built
from `flake.nix`/`flake.lock` and is not recommended for general testing.

The supported and tested workflow uses the provided Docker wrappers
(`./docker_repro.sh`, `./docker_local_dev.sh`, or `./docker_latest.sh`). Host-side
installation of QEMU, `swtpm`, or other QEMU-related tooling is unnecessary for the
standard workflow and is not part of the tested configuration. Only advanced or edge-case
workflows may require installing those tools on the host (see [qemu.md](qemu.md)).

The Docker images produced by our Nix build include QEMU (`qemu-system-x86_64`),
`swtpm` / `libtpms`, `canokey-qemu` (a virtual OpenPGP smartcard), and other userspace
tooling required to build and test QEMU boards. You only need Docker on the host. For KVM
acceleration expose `/dev/kvm` (load `kvm_intel` / `kvm_amd`); the wrapper scripts mount
it automatically when present.

If you plan to manage disk images or use `qemu-img` snapshots on the host (outside
containers), install the `qemu-utils` package locally (which provides `qemu-img`).

### Alternative: Using Nix directly without Docker

You can also use Nix to enter a development shell or build Heads directly without Docker:

```bash
# Enter a development shell with all dependencies
nix develop

# Or run a single command in the environment
nix develop --command make BOARD=EOL_x230-hotp-maximized
```

Note: `nix develop` provides QEMU, `swtpm`, and other required dependencies in the shell
environment, so separate host installs are not needed for this workflow. The Docker
workflow is still recommended for its consistent container image identity.

---

## Docker wrapper scripts

Three wrappers cover different use cases:

| Script | Use case | Reproducibility | When to use |
| --- | --- | --- | --- |
| `./docker_repro.sh` | **Canonical build environment** | Pinned to an image manifest digest | **Canonical default path**: cross-checks the pinned image against the current CI digest; ROM equality still depends on matching source/build inputs |
| `./docker_local_dev.sh` | **Developer customization** | Local build may differ if flake changes | **Developers only**: Rebuilds from local `flake.nix`/`flake.lock` when dirty; use `HEADS_CHECK_REPRODUCIBILITY=1` to verify against published version |
| `./docker_latest.sh` | **Convenience** | Defaults to the configured digest; may be unpinned if none is available | **Testing/convenience**: Uses the selected image; by default falls back to `DOCKER_REPRO_DIGEST` when available. Runs unpinned only when no digest is configured, in which case confirmation is required unless `HEADS_ALLOW_UNPINNED_LATEST=1` or `DOCKER_LATEST_DIGEST` is set. |

**Recommendation by role**:

- **End users & QA**: Use `./docker_repro.sh` when the pinned image identity is desired; verify ROM reproducibility separately when required
- **Developers**: Use `./docker_local_dev.sh` when iterating on the build system or Nix flake,
  but verify reproducibility with `HEADS_CHECK_REPRODUCIBILITY=1` before committing
- **Maintainers**: Use `./docker_repro.sh` for official releases; see [Maintenance workflow](#maintenance-workflow)

**Examples**:

```bash
# Canonical builds
./docker_repro.sh make BOARD=EOL_x230-hotp-maximized
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 run

# Developer workflow (verify before committing)
./docker_local_dev.sh make BOARD=UNTESTED_nitropad-ns50
HEADS_CHECK_REPRODUCIBILITY=1 ./docker_local_dev.sh make BOARD=UNTESTED_nitropad-ns50
```

If you are already inside the container interactively, run `make BOARD=board_name` as usual.

### QEMU workflow examples

The current worktree is bind-mounted at the same path inside the container.
X11 sockets, `/dev/kvm` when available, and USB devices are passed separately.
This does not make arbitrary host paths visible: repository, build, key, disk,
and install-image paths passed to the build must resolve inside the worktree.
Use repository-contained paths such as `./qemu_img/`.

```bash
# Build ROM, then export public key to emulated USB storage at QEMU runtime
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2

# Inject a GPG public key into the ROM image
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 \
  PUBKEY_ASC=./qemu_img/public-key.asc inject_gpg

# QEMU run with repository-contained disk and install-image paths
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 \
  USB_TOKEN=Nitrokey3NFC \
  PUBKEY_ASC=./qemu_img/public-key.asc \
  ROOT_DISK_IMG=./qemu_img/root.qcow2 \
  INSTALL_IMG=./install-images/installer.iso \
  run
```

If you do not specify `USB_TOKEN`, the container uses the included `canokey-qemu` virtual
token by default. Set `USB_TOKEN` (or use `hostbus`/`hostport`/`vendorid,productid`) to
forward a hardware token instead. See [qemu.md](qemu.md) for details.

---

## Wrapper help and environment variables

Each wrapper shows its own focused help (only variables it actually uses). For the complete
environment reference run `docker/common.sh` directly:

```bash
# Wrapper-specific help
./docker_repro.sh --help
./docker_latest.sh --help
./docker_local_dev.sh --help

# Full environment variable reference (shared helper)
./docker/common.sh
```

The shared helper documents all supported environment variables (opt-ins and opt-outs) and
defaults. Wrapper help is intentionally narrower so it only lists variables relevant to
that wrapper.

### All wrapper scripts

**`HEADS_MAINTAINER_DOCKER_IMAGE`** — override the canonical maintainer's Docker image
repository (default: `tlaurion/heads-dev-env`). Use this for local testing or if you
maintain a fork. Example: `export HEADS_MAINTAINER_DOCKER_IMAGE="myuser/heads-dev-env"`.
This affects reproducibility checks and default image references across all Docker wrapper
scripts.

**`HEADS_CHECK_REPRODUCIBILITY_REMOTE`** — specify which remote image to compare against
when verifying reproducibility (default: `${HEADS_MAINTAINER_DOCKER_IMAGE}:latest`). Use
this to test against a specific tagged version instead of `:latest`.

```bash
# Compare against a specific version
export HEADS_CHECK_REPRODUCIBILITY_REMOTE="tlaurion/heads-dev-env:v0.2.7"
HEADS_CHECK_REPRODUCIBILITY=1 ./docker_local_dev.sh
```

**`HEADS_DISABLE_USB=1`** — disable automatic USB passthrough and the automatic USB
cleanup (default: `0`).

**`HEADS_X11_XAUTH=1`** — force mounting your `${HOME}/.Xauthority` into the container
for X11 authentication. When set the helper will bypass programmatic Xauthority generation
and mount your `${HOME}/.Xauthority` (if present); if the file is missing the helper will
warn and will not attempt automatic cookie creation (GUI may fail).

### `./docker_local_dev.sh`

**`HEADS_FORCE_DOCKER_REBUILD=1`** — force rebuild from flake.nix/flake.lock regardless of git status. Also attempts to delete the cached nix store result/link before rebuilding. Takes precedence over `HEADS_SKIP_DOCKER_REBUILD=1`.

**`HEADS_SKIP_DOCKER_REBUILD=1`** — skip automatically rebuilding the local image when
`flake.nix`/`flake.lock` are dirty.

**`HEADS_CHECK_REPRODUCIBILITY=1`** — compares the locally built image ID with
the remote maintainer image's config digest through
`compare_image_reproducibility()`.  This checks Docker image identity only; it
does not compare Heads ROMs or authenticate the publisher.  It requires network
access and compares against `${HEADS_MAINTAINER_DOCKER_IMAGE}:latest` by default.
Use `HEADS_CHECK_REPRODUCIBILITY_REMOTE` for a different tag (for example
`v0.2.7`).  See [Verifying reproducibility](#verifying-reproducibility) below.

**`HEADS_AUTO_INSTALL_NIX=1`** — automatically attempt to download the Nix single-user
installer when `nix` is missing (interactive prompt suppressed).

For supply-chain safety the helper will download the installer to a temporary file and
print its SHA256; it will NOT execute the installer automatically unless the downloaded
installer matches a pinned hash. The helper will also attempt to detect the installer
version heuristically (when possible) and suggest the canonical releases URL (for example
`https://releases.nixos.org/nix/nix-2.33.2/install.sha256`) so you can fetch the
published sha and compare. To verify:

- **Preferred — pin a release version**: set `HEADS_NIX_INSTALLER_VERSION` to a release
  (for example `nix-2.33.2`). The helper will fetch
  `https://releases.nixos.org/nix/${HEADS_NIX_INSTALLER_VERSION}/install` and
  `install.sha256` and show both checksums for you to compare. To auto-run in trusted
  automation, set `HEADS_NIX_INSTALLER_SHA256` to the expected sha256 as well.

- **Or compute-and-pin locally**: run
  `./docker/fetch_nix_installer.sh --version nix-2.33.2` (or `--url`) to download the
  installer and print its sha256, then set `HEADS_NIX_INSTALLER_SHA256` to that value for
  automation.

  Otherwise verify the downloaded installer manually and run it yourself:
  `sh /path/to/installer --no-daemon`.

**`HEADS_AUTO_ENABLE_FLAKES=1`** — automatically enable flakes by writing
`experimental-features = nix-command flakes` to `$HOME/.config/nix/nix.conf`
(interactive prompt suppressed).

**`HEADS_MIN_DISK_GB`** — minimum free disk space in GB required on `/nix` (or `/` if
`/nix` missing) for building (default: `50`).

**`HEADS_SKIP_DISK_CHECK=1`** — skip the preflight disk-space check.

### `./docker_latest.sh`

**`HEADS_ALLOW_UNPINNED_LATEST=1`** — when set, bypass the interactive warning that using
`:latest` in `./docker_latest.sh` is a supply-chain risk (otherwise `:latest` requires
confirmation unless `DOCKER_LATEST_DIGEST` is set or the wrapper can fall back to
`DOCKER_REPRO_DIGEST` for the maintainer image).

**`DOCKER_LATEST_DIGEST`** — pin the convenience wrapper to a specific immutable digest.

### `./docker_repro.sh`

**`DOCKER_REPRO_DIGEST`** — pin the image used by `./docker_repro.sh` to an immutable
digest: `tlaurion/heads-dev-env@<digest>`.  A non-empty environment value takes
precedence; otherwise `docker_repro.sh` falls back to the non-comment digest in
`docker/DOCKER_REPRO_DIGEST`.  The pin fixes image identity only; it does not
guarantee ROM reproducibility.  On the canonical default
`tlaurion/heads-dev-env` path, the wrapper also extracts the digest from
`.circleci/config.yml` and aborts on a mismatch.  Fork or other non-canonical
repository overrides can skip that CI digest cross-check.

---

## USB token passthrough

When USB passthrough is active the wrappers will detect processes that may be holding a
USB token (for example `scdaemon` or `pcscd`). The wrapper will warn and, on interactive
shells, give a **3-second abort window** before attempting to kill those processes to free
the token. Set `HEADS_DISABLE_USB=1` to opt out of this automatic cleanup.

For fully unattended builds (script/non-interactive shell), wrap the command in
`script` to provide the pseudo-TTY that `docker_repro.sh`'s `-ti` requires. Pass
`-f` (flush) as well: without it, `script` buffers its output and a non-tty/agent
context that reads the stream incrementally can see the build stall or lose
output. `HEADS_DISABLE_USB=1` skips the USB token passthrough (and its 3-second
abort window) so nothing prompts:

```bash
script -qefc "HEADS_DISABLE_USB=1 ./docker_repro.sh make BOARD=EOL_t480-hotp-maximized"
script -qefc "HEADS_DISABLE_USB=1 ./docker_repro.sh make BOARD=EOL_x220-maximized"
```

`script` (util-linux) allocates a pseudo-terminal (PTY) so `docker run -ti` has
a TTY in a non-interactive/agent context; the command's output is still shown on
screen (stdout). The options used above:

- `-c "<cmd>"` runs that command.
- `-q` suppresses `script`'s own start/done banners.
- `-e` propagates the command's exit status, so a failed build is detectable.
- `-f` flushes output as it is written (no buffering), so incremental readers
  don't see it stall.

`script` also records the session to a file — by default `./typescript`, which
this repo gitignores (`.gitignore:34` `typescript*`). Leave it default to keep
the transcript; pass `/dev/null` as the trailing argument to skip recording.

`HEADS_DISABLE_USB=1` skips USB-token passthrough and its 3-second abort window.

Both `HEADS_DISABLE_USB=1` and `script` are unnecessary when running from
an interactive terminal.

```bash
HEADS_DISABLE_USB=1 ./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 run
```

For details about selecting or forwarding a physical USB token to QEMU (handled by the
`USB_TOKEN` make variable), see [qemu.md](qemu.md).

---

## Managing local Docker images

Note: you may need to prefix commands with `sudo` depending on your Docker setup.

```bash
# List local images
docker images

# Inspect a specific image (IDs, digests, repo tags)
docker image inspect <image>

# Remove a specific image
docker rmi <image>

# Remove all local images (destructive)
docker rmi -f $(docker images -aq)

# Remove unused images/containers/networks/build cache (destructive)
docker system prune -a --volumes
```

---

## QEMU disk snapshots with `qemu-img`

If you manage qcow2 disk images on the host, `qemu-img` can create, list, restore, and
delete snapshots. These examples assume a qcow2 disk image:

```bash
# Create a snapshot
qemu-img snapshot -c clean root.qcow2

# List snapshots
qemu-img snapshot -l root.qcow2

# Restore (apply) a snapshot
qemu-img snapshot -a clean root.qcow2

# Delete a snapshot
qemu-img snapshot -d clean root.qcow2

# Optional: create an overlay backed by a base image
qemu-img create -f qcow2 -b base.qcow2 overlay.qcow2
```

If you prefer to run these inside the container, prefix with `./docker_repro.sh`:

```bash
./docker_repro.sh qemu-img snapshot -l root.qcow2
```

---

## Building with the published Docker image

The canonical build wrapper is `./docker_repro.sh`.  It prefers a non-empty
`DOCKER_REPRO_DIGEST` environment value, falls back to the pinned value in
`docker/DOCKER_REPRO_DIGEST`, and resolves the selected reference to an immutable
manifest digest.  The canonical default `tlaurion/heads-dev-env` path
cross-checks that digest against `.circleci/config.yml` before running the
command; fork/non-canonical overrides can skip that check.  The pin fixes the
container image identity only; it does not compare or guarantee equality with CI
build outputs when the repository commit, working-tree state, or other build
inputs differ.

```bash
./docker_repro.sh make BOARD=EOL_x230-hotp-maximized
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 run
```

This will:

1. Select `DOCKER_REPRO_DIGEST` from the environment, falling back to `docker/DOCKER_REPRO_DIGEST`
2. Validate and resolve the selected reference to a manifest digest; on the canonical default path, cross-check `.circleci/config.yml` (fork/non-canonical overrides can skip this)
3. Pull that exact image if it is not present locally
4. Execute the requested build or QEMU command in the resolved image

`docker_repro.sh` does not download or compare CI `hashes.txt`, final ROM
hashes, or other build outputs.  Use the separate verification procedure in
[reproducible-builds.md](reproducible-builds.md#comparing-rom-output)
when a same-commit ROM comparison is wanted.

**About the published image**:

- **Repository**: `tlaurion/heads-dev-env` on Docker Hub is the maintainer's canonical image (configurable via `HEADS_MAINTAINER_DOCKER_IMAGE`)
- **Versioning**: Tagged with version numbers (e.g., `v0.2.7`) for stability; `:latest` is mutable and not recommended
- **Pinning**: `DOCKER_REPRO_DIGEST` from the environment takes precedence; `docker/DOCKER_REPRO_DIGEST` is the fallback manifest reference (`tlaurion/heads-dev-env@sha256:...`)
- **Local image comparison**: Rebuilding the flake without local changes is intended to reproduce the image, but a digest comparison is a verification step, not a premise that guarantees success
- **Fork/Override**: To use a different image repository, set `HEADS_MAINTAINER_DOCKER_IMAGE="youruser/your-image"` before running any Docker wrapper script

`DOCKER_REPRO_DIGEST` (the environment variable or the repository file `docker/DOCKER_REPRO_DIGEST`)
is consumed by `./docker_repro.sh` via `resolve_docker_image()`; pinning fixes
image identity and avoids accidental selection of a mutable `:latest` tag.  It
does not prove ROM reproducibility or authenticate the publisher.

---

## Using Nix for local development

`./docker_local_dev.sh` is a developer helper that ensures a local Nix-based Docker image
(`linuxboot/heads:dev-env`) is available for interactive development. It performs preflight
checks and interactive prompts to make the process easier:

- Ensures `nix` is installed and **flakes** are enabled; if missing it will prompt to
  install Nix and enable flakes. Set `HEADS_AUTO_INSTALL_NIX=1` and/or
  `HEADS_AUTO_ENABLE_FLAKES=1` to suppress prompts and proceed automatically.
- Requires either `curl` or `wget` to fetch the Nix installer; if neither is present the
  script will print how to install one and abort.
- Checks disk space on `/nix` (or `/` if `/nix` is absent); default minimum is **50 GB**
  (`HEADS_MIN_DISK_GB=50`) — override or skip the check with `HEADS_SKIP_DISK_CHECK=1`.
- If `flake.nix` or `flake.lock` are dirty (uncommitted changes), the helper will rebuild
  the local Docker image. To intentionally trigger a rebuild, make and keep changes to
  `flake.nix` (for example update an input or a harmless comment) or update `flake.lock`,
  then run `./docker_local_dev.sh`; the helper detects the dirty flake files and will
  rebuild automatically. To avoid an automatic rebuild, commit or stash your changes or
  set `HEADS_SKIP_DOCKER_REBUILD=1` to disable the check.

Notes on automation:

- The `./docker_local_dev.sh` helper will attempt to ensure Nix and flakes are available
  when you run it interactively. Set `HEADS_AUTO_INSTALL_NIX=1` /
  `HEADS_AUTO_ENABLE_FLAKES=1` to suppress prompts.
- Building the Docker image and populating `/nix` can require significant disk space — at
  least **50 GB** free on `/nix` (or `/` if `/nix` is not present). Adjust via
  `HEADS_MIN_DISK_GB` or skip the check with `HEADS_SKIP_DISK_CHECK=1`.
- The Nix installer requires a downloader; either `curl` or `wget` must be available on
  the host. The helper will guide you to install one if neither is present.
- For reproducible builds prefer `./docker_repro.sh`; `./docker_local_dev.sh` is intended
  for development and will rebuild the local image when `flake.nix`/`flake.lock` are dirty
  (unless `HEADS_SKIP_DOCKER_REBUILD=1`).

### Set up Nix and flakes

If you don't already have Nix, install it:

```bash
[ -d /nix ] || sh <(curl -L https://nixos.org/nix/install) --no-daemon
. /home/user/.nix-profile/etc/profile.d/nix.sh
```

Enable flake support in nix:

```bash
mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes' >>~/.config/nix/nix.conf
```

### Build the local image

```bash
# Manual
nix build --print-build-logs --verbose --out-link docker/result .#dockerImage && docker load -i docker/result

# Via helper (rebuilds automatically when flake files are dirty)
./docker_local_dev.sh
```

Your local Docker image `linuxboot/heads:dev-env` is ready to use.  Image
identity can be compared with the helper, but ROM reproducibility still
depends on matching repository and build inputs.

On some hardened OSes, you may encounter problems with ptrace:

```text
> proot error: ptrace(TRACEME): Operation not permitted
```

The most likely reason is that your
[kernel.yama.ptrace_scope](https://www.kernel.org/doc/Documentation/security/Yama.txt)
variable is too high and doesn't allow docker+nix to run properly. You'll need to
temporarily set it to 1 while you build:

```bash
sudo sysctl kernel.yama.ptrace_scope   # show current value (probably 2 or 3)
sudo sysctl -w kernel.yama.ptrace_scope=1   # lower for the build
# ... build ...
sudo sysctl -w kernel.yama.ptrace_scope=<original_value>   # restore after
```

### Local build without Docker

For development iterations that don't require Docker reproducibility:

```bash
nix develop --command make BOARD=novacustom-nv4x_adl
nix develop --command make BOARD=novacustom-nv4x_adl kexec   # single package
```

`nix develop` drops into the same Nix environment that builds the Docker
image.  Packages are cached in `build/$ARCH/`; subsequent builds are
fast.  No sudo, no Docker.

See [modules.md](modules.md#build-lifecycle) for the sentinel chain and
how to force a rebuild after changing patches.

### Stale host-built tooling can be incompatible with the container

The host and container share `build/`.  Binaries produced by one environment
can therefore be unusable in the other if their runtime/toolchain assumptions
differ.  This is a generic cleanup case, not a claim about one particular Nix
loader path or a reproduced incident.

The conservative recovery is to remove the affected kernel build directory so
the container regenerates it:

```bash
rm -rf build/x86/linux-<ver>/<kconfig-name>
```

If only a specific helper is known to be stale, remove that helper and rerun;
otherwise keep host and container build trees separate to avoid mixed artifacts.


### Verify reproducibility before committing

```bash
# Verify local image matches maintainer's latest
HEADS_CHECK_REPRODUCIBILITY=1 ./docker_local_dev.sh

# Verify against a specific version
HEADS_CHECK_REPRODUCIBILITY=1 \
  HEADS_CHECK_REPRODUCIBILITY_REMOTE="tlaurion/heads-dev-env:v0.2.7" \
  ./docker_local_dev.sh
```

### Under QubesOS

- [Setup Nix persistent layer under QubesOS](https://dataswamp.org/~solene/2023-05-15-qubes-os-install-nix.html) (Thanks @rapenne-s!)
- [Install Docker under QubesOS](https://gist.github.com/tlaurion/9113983bbdead492735c8438cd14d6cd)

---

## Verifying reproducibility

`compare_image_reproducibility()` compares the local Docker image ID with the
remote image's config digest.  This is an image-build identity check only: it
does not compare Heads ROMs or authenticate the publisher.

The Heads project maintains `tlaurion/heads-dev-env` on Docker Hub (the
repository is configurable through `HEADS_MAINTAINER_DOCKER_IMAGE`).  The
repository's pinned `repo@digest` reference is a **manifest digest**: it
identifies the exact manifest, including its config digest and layer
references, selected from the registry.  A matching manifest digest is the
strongest registry-level equality check.  The wrapper helper instead performs a
local image-ID versus remote config-digest comparison.

### Quick reference

| Scenario | Command |
| --- | --- |
| Check against latest maintainer image | `HEADS_CHECK_REPRODUCIBILITY=1 ./docker_local_dev.sh` |
| Check against specific version tag | `HEADS_CHECK_REPRODUCIBILITY=1 HEADS_CHECK_REPRODUCIBILITY_REMOTE="tlaurion/heads-dev-env:v0.2.7" ./docker_local_dev.sh` |
| Check fork maintainer's image | `HEADS_MAINTAINER_DOCKER_IMAGE="youruser/heads-dev-env" HEADS_CHECK_REPRODUCIBILITY=1 ./docker_local_dev.sh` |
| Standalone check at any time | `./docker/check_reproducibility.sh linuxboot/heads:dev-env tlaurion/heads-dev-env:v0.2.7` |

### Prerequisites

You have either:

- Built a local Docker image with `./docker_local_dev.sh` (produces `linuxboot/heads:dev-env`), or
- Built from `nix build --out-link docker/result .#dockerImage` (results in `docker/result` symlink loadable via `docker load -i docker/result`)

### Method 1: Automated check during build (recommended)

Enable reproducibility verification automatically during your build with
`HEADS_CHECK_REPRODUCIBILITY=1`:

```bash
# Verify against the default (maintainer's :latest image)
HEADS_CHECK_REPRODUCIBILITY=1 ./docker_local_dev.sh

# Example output when digests MATCH (reproducible build):
# === Reproducibility Check ===
# Local image (linuxboot/heads:dev-env):   sha256:8ae7744cc8b4ff0e959aa6dfeeb40dbd40d20ac6fa1f7071dd21ec0c2d0f9f41
# Remote image (tlaurion/heads-dev-env:latest): sha256:8ae7744cc8b4ff0e959aa6dfeeb40dbd40d20ac6fa1f7071dd21ec0c2d0f9f41
# (via registry+jq)
# ✓ MATCH: Config digests identical
# Config digest: sha256:8ae7744cc8b4ff0e959aa6dfeeb40dbd40d20ac6fa1f7071dd21ec0c2d0f9f41
# Note: this check compares image config IDs, not manifest identity
# Docker Hub: https://hub.docker.com/layers/tlaurion/heads-dev-env/latest/images/sha256-5f890f3d...
# === End Reproducibility Check ===
```

### Understanding config digest vs manifest digest

Docker images expose two distinct identities:

- **Config digest / image ID** is the SHA-256 of the image config JSON.  It
  names a config that references layer digests and runtime metadata such as
  environment and entrypoint.  `docker inspect --format='{{.Id}}'` prints this
  value.  Equal image IDs are useful evidence that two images have the same
  config and layer references, but they do not identify the exact registry
  manifest selected by a tag.
- **Manifest digest** is the SHA-256 of the manifest that lists the config and
  layer blobs.  A `repo@sha256:...` pin uses this digest.  Different manifests
  can reference the same config digest, for example with different manifest
  media types or annotations.

Accordingly, a config-ID match is narrower than a manifest-digest match.  A
config-ID mismatch proves the images differ; a config-ID match alone does not
prove that the published manifest has the same media type or annotations as a
locally compared one.  Use `docker buildx imagetools inspect`,
`docker manifest inspect`, or the helper's `repo@digest` output when registry
manifest identity is the property being checked.

To test against a **specific version tag** instead of `:latest`:

```bash
HEADS_CHECK_REPRODUCIBILITY=1 \
  HEADS_CHECK_REPRODUCIBILITY_REMOTE="tlaurion/heads-dev-env:v0.2.7" \
  ./docker_local_dev.sh

# Example output when digests DIFFER (expected for different versions):
# === Reproducibility Check ===
# Local image (linuxboot/heads:dev-env):   sha256:5f890f3d...
# Remote image (tlaurion/heads-dev-env:v0.2.7): sha256:75af4c81...
# (via registry+jq)
# ✗ MISMATCH: Config digests differ
# === End Reproducibility Check ===
#
# If remote config digest cannot be fetched, falls back to pulling the image:
# === Reproducibility Check ===
# Local image (linuxboot/heads:dev-env):   sha256:5f890f3d...
# Could not fetch remote image config digest via registry; falling back to 'docker pull' to compare image IDs (progress will be shown).
# Tip: Install jq and curl for faster registry-based checks (no pull needed).
# Pulling remote image (progress will be shown)...
# Remote image (pulled tlaurion/heads-dev-env:v0.2.7): sha256:75af4c81...
# ✗ MISMATCH: Image IDs differ after pull.
#   Local:  sha256:5f890f3d...
#   Remote: sha256:75af4c81...
# === End Reproducibility Check ===
```

`compare_image_reproducibility()` compares the local **image ID** with the
remote image's **config digest**.  Use a manifest inspection when the
requirement is to verify the exact `repo@digest`
reference or distinguish images that share a config but use different manifest
metadata.

### Method 2: Standalone image comparison

The standalone helper delegates to the same centralized image comparison used
by the wrapper.  Its output and exit status are governed by
`docker/common.sh`; it compares image identity, not Heads ROMs or build
manifests.

```bash
./docker/check_reproducibility.sh \
  linuxboot/heads:dev-env tlaurion/heads-dev-env:v0.2.7
```

### Method 3: Manual digest inspection

```bash
# Get the digest of your local image (after docker load)
docker inspect --format='{{.Id}}' linuxboot/heads:dev-env

# Compare with the published image (will pull if needed)
docker pull tlaurion/heads-dev-env:v0.2.7
docker inspect --format='{{.Id}}' tlaurion/heads-dev-env:v0.2.7
```

### Interpreting the helper comparison

✓ **Image ID/config digest match** — the local Docker image ID equals the remote
image config digest reported by `compare_image_reproducibility()`.  This
compares build-environment identity only; it is not a ROM comparison, does not
prove manifest-digest equality, and does not authenticate the publisher.  The
comparison can succeed when:

- `flake.nix` and `flake.lock` are **not modified** (repository is clean relative to these files)
- The same Nix version and dependencies are used
- Build runs on the same Nix store state

✗ **Digests differ** — expected when:

- You have uncommitted changes in `flake.nix` or `flake.lock`
- Different Nix version or Nix dependencies resolved differently on your system
- Using a different `nixpkgs` version than the locked one in `flake.lock`

### Trust model

A manifest-digest pin fixes the registry object requested by the wrapper, but
a digest by itself does not establish who published that image or prove that the
local build environment was uncompromised.  A matching local image ID and
remote config digest establish only that image-config identity comparison; a
matching manifest digest establishes exact registry-manifest identity.
Supply-chain review and signature/provenance checks
are separate concerns.

**Recommendation**: pin the canonical `repo@sha256:...` reference for critical
builds rather than a mutable tag, and record both the manifest digest and the
source commit used for the build.

---

## Pinning `./docker_latest.sh`

We do not maintain a `docker/DOCKER_LATEST_DIGEST` file in the repository because
`latest` is a user-level convenience and should be explicitly chosen. When
`DOCKER_LATEST_DIGEST` is unset, `./docker_latest.sh` may fall back to `DOCKER_REPRO_DIGEST`
only when the base image matches the maintainer repo; otherwise it will prompt before
using an unpinned `:latest` unless `HEADS_ALLOW_UNPINNED_LATEST=1` is set.

```bash
# 1) Obtain the digest for a published image
#    Tip: inspect tags on Docker Hub: https://hub.docker.com/layers/tlaurion/heads-dev-env/
#
./docker/get_digest.sh tlaurion/heads-dev-env:v0.2.7
# Output (example): tlaurion/heads-dev-env@sha256:50a9110c...

# Auto-pull and return digest in one go:
./docker/get_digest.sh -y tlaurion/heads-dev-env:v0.2.7

# 2) Export and use the digest
export DOCKER_LATEST_DIGEST=$(./docker/get_digest.sh tlaurion/heads-dev-env:latest | tail -n1)
DOCKER_LATEST_DIGEST=$DOCKER_LATEST_DIGEST ./docker_latest.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2
```

When a digest is discovered, helpers print a concise summary to help auditing:

```text
Image: tlaurion/heads-dev-env@sha256:50a9...
Digest: sha256:50a9...
Resolved from: local|registry API|env|file
Tip: export DOCKER_LATEST_DIGEST=sha256:50a9...
```

To change what `./docker_latest.sh` uses as the "latest" image:

- **Temporary override**: `./docker/pin-and-run.sh <repo:tag> -- ./docker_latest.sh <command>`
- **Local convenience env**: `export DOCKER_LATEST_DIGEST=$(./docker/get_digest.sh tlaurion/heads-dev-env:vX.Y.Z | tail -n1)`
- **Canonical fallback**: edit `docker/DOCKER_REPRO_DIGEST` with the desired digest and commit

```bash
# pin-and-run helper examples
./docker/pin-and-run.sh tlaurion/heads-dev-env:v0.2.7 -- ./docker_latest.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2
./docker/pin-and-run.sh -y tlaurion/heads-dev-env:v0.2.7 -- ./docker_latest.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2

# Omit the wrapper — helper defaults to './docker_latest.sh'
./docker/pin-and-run.sh tlaurion/heads-dev-env:v0.2.7 -- make BOARD=qemu-coreboot-fbwhiptail-tpm2
```

Use `docker_latest.sh` for the historical `v0.2.7` image.  Do not select that
historical tag through `docker_repro.sh`, whose digest source is the current
reproducible-image configuration.

Alternative manual commands without the helper:

```bash
docker pull tlaurion/heads-dev-env:latest
# prints full repo@digest (if available)
docker inspect --format='{{index .RepoDigests 0}}' tlaurion/heads-dev-env:latest
# to get only the digest portion:
docker inspect --format='{{index .RepoDigests 0}}' tlaurion/heads-dev-env:latest | cut -d'@' -f2
```

Notes: some registries or Docker versions may require `docker manifest inspect` or
`skopeo inspect` to obtain an authoritative digest; the helper script tries
`docker inspect` first, then `docker manifest inspect` when available.

Acceptable digest formats for `DOCKER_REPRO_DIGEST` / `DOCKER_LATEST_DIGEST`:
`sha256:<64-hex>`, `sha256-<64-hex>`, or bare `<64-hex>` — all normalized to `sha256:<hex>`.

---

## Maintenance workflow

To update the Docker image to a new version (e.g., `vx.y.z`):

```bash
docker_version="vx.y.z"
docker_hub_repo="tlaurion/heads-dev-env"

# Update pinned packages to latest if needed, modify flake.nix as required
nix flake update

# Commit flake changes
git add flake.nix flake.lock
git commit --signoff -m "Bump nix develop based docker image to $docker_version"

# Verify reproducibility: ensure the local build matches (no further changes to flake files)
nix develop --ignore-environment --command true

# Build the new Docker image
nix build --out-link docker/result .#dockerImage
docker load -i docker/result

# Verify you can extract the digest (flake.nix/flake.lock must be committed)
docker inspect --format='{{.Id}}' linuxboot/heads:dev-env

# Tag the image with the new version
docker tag linuxboot/heads:dev-env "$docker_hub_repo:$docker_version"

# Push the new version to Docker Hub (requires push access)
docker push "$docker_hub_repo:$docker_version"

# Capture the digest of the pushed image (use --yes to auto-pull)
new_digest=$(./docker/get_digest.sh -y "$docker_hub_repo:$docker_version" | tail -n1)
prev_digest=$(grep '^[^#]' docker/DOCKER_REPRO_DIGEST | head -n1)

# Update the digest in the repository file
sed -i "s|$prev_digest|$new_digest|" docker/DOCKER_REPRO_DIGEST

# Update the version comment in the repository file
sed -i "s|# Version: .*|# Version: $docker_version|" docker/DOCKER_REPRO_DIGEST

# Update .circleci/config.yml (remove old comment, insert fresh one above the image line)
sed -i \
  -e "/^[[:space:]]*# Docker image: /d" \
  -e "/^[[:space:]]*- image: ${docker_hub_repo//\//\\/}@/ s|^\([[:space:]]*\)\(- image: ${docker_hub_repo//\//\\/}@\)|\\1# Docker image: $docker_hub_repo:$docker_version\n\\1\\2|" \
  .circleci/config.yml

# Commit the digest and config changes
git add docker/DOCKER_REPRO_DIGEST .circleci/config.yml
git commit --signoff -m "Pin docker image to digest for $docker_version"

# Push the branch and create a PR for testing with CircleCI
git push origin docker/squash-docker-changes

# After PR is merged and tested, optionally tag as latest (use with caution)
# docker tag "$docker_hub_repo:$docker_version" "$docker_hub_repo:latest"
# docker push "$docker_hub_repo:latest"
```

### Maintainer checklist

1. **Image comparison**: Build the local image with committed, clean `flake.nix`/`flake.lock`, then compare its image ID/config digest with the intended published image.  One local `nix build` is not evidence of deterministic or bit-identical output.
2. **Digest verification**: After pushing, use `./docker/check_reproducibility.sh` to verify local and remote digests match.
3. **Supply chain**: Pin digest in `docker/DOCKER_REPRO_DIGEST` and `.circleci/config.yml` to ensure all builds reference an immutable, auditable image.
4. **Documentation**: Update the version comment in `docker/DOCKER_REPRO_DIGEST` so users know which image version is pinned.
5. **User migration**: When releasing a new version, communicate the new digest and version in release notes.

Notes:

- `:latest` is a mutable registry tag; its contents are not established by this repository documentation
- `docker_repro.sh` uses the image digest declared by `.circleci/config.yml`; reproducing a CI ROM additionally requires the same repository/build inputs and a separate artifact comparison

### For forks and alternate maintainers

```bash
export HEADS_MAINTAINER_DOCKER_IMAGE="youruser/heads-dev-env"

# All scripts will now reference your repository
./docker_local_dev.sh make BOARD=EOL_x230-maximized
HEADS_CHECK_REPRODUCIBILITY=1 ./docker_local_dev.sh

# Reproducibility check compares against youruser/heads-dev-env:latest
# resolve_docker_image uses youruser/heads-dev-env as the base image
```

The repository file `docker/DOCKER_REPRO_DIGEST` pins the image identity used
by `./docker_repro.sh`.  Update it after publishing a new image to keep the
configured reference synchronized; pinning alone does not establish ROM
reproducibility or publisher authenticity.
