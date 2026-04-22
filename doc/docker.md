# Heads Docker Build Environment

Heads builds inside a versioned Docker image that provides a reproducible, hermetic build
environment. Docker images are built with Nix since
[PR #1661](https://github.com/linuxboot/heads/pull/1661).

See also: [General reproducible-build notes](../README.md#general-notes-on-reproducible-builds),
[QEMU testing](qemu.md), [CircleCI pipeline notes](circleci.md).

---

## Quick start

The short path to build Heads is to do what CircleCI does:

- Install [Docker CE](https://docs.docker.com/engine/install/) for your OS
- Run `./docker_repro.sh make BOARD=XYZ`

```bash
# Canonical, reproducible build (recommended for all users)
./docker_repro.sh make BOARD=x230-hotp-maximized

# Build and run a QEMU board
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 run
```

`./docker_repro.sh` is the canonical, reproducible way to build and test Heads.
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
nix develop --command make BOARD=x230-hotp-maximized
```

Note: `nix develop` provides QEMU, `swtpm`, and other required dependencies in the shell
environment, so separate host installs are not needed for this workflow. The Docker
workflow is still recommended for its canonical isolation and reproducibility benefits.

---

## Docker wrapper scripts

Three wrappers cover different use cases:

| Script | Use case | Reproducibility | When to use |
| --- | --- | --- | --- |
| `./docker_repro.sh` | **Canonical reproducible builds** | Pinned to immutable digest | **All users & maintainers**: Standard way to build Heads; matches CircleCI exactly; use for releases and critical builds |
| `./docker_local_dev.sh` | **Developer customization** | Local build may differ if flake changes | **Developers only**: Rebuilds from local `flake.nix`/`flake.lock` when dirty; use `HEADS_CHECK_REPRODUCIBILITY=1` to verify against published version |
| `./docker_latest.sh` | **Convenience** | Defaults to reproducible digest; may be unpinned if no digest is available | **Testing/convenience**: Uses latest published image; by default falls back to the reproducible digest (`DOCKER_REPRO_DIGEST`) when available (no confirmation needed). Runs unpinned only when no digest is configured, in which case it requires confirmation unless `HEADS_ALLOW_UNPINNED_LATEST=1` or `DOCKER_LATEST_DIGEST` is set. |

**Recommendation by role**:

- **End users & QA**: Use `./docker_repro.sh` for all builds (ensures reproducibility and security)
- **Developers**: Use `./docker_local_dev.sh` when iterating on the build system or Nix flake,
  but verify reproducibility with `HEADS_CHECK_REPRODUCIBILITY=1` before committing
- **Maintainers**: Use `./docker_repro.sh` for official releases; see [Maintenance workflow](#maintenance-workflow)

**Examples**:

```bash
# Canonical builds
./docker_repro.sh make BOARD=x230-hotp-maximized
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 run

# Developer workflow (verify before committing)
./docker_local_dev.sh make BOARD=nitropad-nv41
HEADS_CHECK_REPRODUCIBILITY=1 ./docker_local_dev.sh make BOARD=nitropad-nv41
```

If you are already inside the container interactively, run `make BOARD=board_name` as usual.

### QEMU workflow examples

```bash
# Build ROM, then export public key to emulated USB storage at QEMU runtime
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2

# Inject a GPG public key into the ROM image
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 PUBKEY_ASC=~/pubkey.asc inject_gpg

# Full install run with hardware token, disk image, and install ISO
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 \
  USB_TOKEN=Nitrokey3NFC \
  PUBKEY_ASC=~/pubkey.asc \
  ROOT_DISK_IMG=~/qemu-disks/debian-9.cow2 \
  INSTALL_IMG=~/Downloads/debian-9.13.0-amd64-xfce-CD-1.iso \
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

**`HEADS_CHECK_REPRODUCIBILITY=1`** — **recommended for verifying reproducible builds**.
After building/loading the local image, automatically compares its digest with the
published maintainer image to verify reproducibility. Requires network access. By default
compares against `${HEADS_MAINTAINER_DOCKER_IMAGE}:latest`. Use
`HEADS_CHECK_REPRODUCIBILITY_REMOTE` to specify a different tag (e.g., `v0.2.7`). See
[Verifying reproducibility](#verifying-reproducibility) below for detailed examples.

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
digest: `tlaurion/heads-dev-env@<digest>` (recommended for reproducible and secure
builds). Note: `DOCKER_REPRO_DIGEST` is *consumed by* `./docker_repro.sh` via
`resolve_docker_image` in `docker/common.sh` and is the canonical way to pin the repro
image for reproducible builds. The repository file `docker/DOCKER_REPRO_DIGEST` contains
the pinned digest used by default.

---

## USB token passthrough

When USB passthrough is active the wrappers will detect processes that may be holding a
USB token (for example `scdaemon` or `pcscd`). The wrapper will warn and, on interactive
shells, give a **3-second abort window** before attempting to kill those processes to free
the token. Set `HEADS_DISABLE_USB=1` to opt out of this automatic cleanup.

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

The canonical, reproducible way to build Heads is to use `./docker_repro.sh`, which
automatically pulls the pinned Docker image digest from `docker/DOCKER_REPRO_DIGEST` and
ensures your builds match the CI environment exactly.

```bash
./docker_repro.sh make BOARD=x230-hotp-maximized
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2 run
```

This will:

1. Resolve the canonical image digest from `docker/DOCKER_REPRO_DIGEST` (immutable, pinned to a specific version)
2. Pull the image if not present locally
3. Execute your build inside that exact Docker environment
4. Guarantee reproducibility: your ROM output will match official CircleCI builds for that commit

**About the published image**:

- **Repository**: `tlaurion/heads-dev-env` on Docker Hub is the maintainer's canonical image (configurable via `HEADS_MAINTAINER_DOCKER_IMAGE`)
- **Versioning**: Tagged with version numbers (e.g., `v0.2.7`) for stability; `:latest` is mutable and not recommended
- **Pinning**: The repository file `docker/DOCKER_REPRO_DIGEST` pins an immutable digest (`tlaurion/heads-dev-env@sha256:...`) to ensure reproducibility
- **Trust**: As long as `flake.nix` and `flake.lock` are not modified locally, your build will produce identical digests, confirming integrity
- **Fork/Override**: To use a different image repository, set `HEADS_MAINTAINER_DOCKER_IMAGE="youruser/your-image"` before running any Docker wrapper script

`DOCKER_REPRO_DIGEST` (the environment variable or the repository file `docker/DOCKER_REPRO_DIGEST`)
is consumed by `./docker_repro.sh` via `resolve_docker_image()`; pinning ensures
reproducible builds and mitigates supply-chain risk from mutable `:latest` tags.

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

Your local docker image `linuxboot/heads:dev-env` is ready to use, reproducible for the
specific Heads commit used to build it, and will produce ROMs reproducible for that commit ID.

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

**Best practice**: Verify that your locally-built Docker image is reproducible by
comparing its digest with the published maintainer image.

The Heads project maintains the canonical `tlaurion/heads-dev-env` Docker image on Docker
Hub (configurable via `HEADS_MAINTAINER_DOCKER_IMAGE` for forks or testing). As long as
you do not modify `flake.nix` or `flake.lock`, your locally-built image **should produce
an identical digest** to the published image, demonstrating that your build is fully
reproducible.

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
# ✓ MATCH: Config digests identical (bit-for-bit reproducible)
# Config digest: sha256:8ae7744cc8b4ff0e959aa6dfeeb40dbd40d20ac6fa1f7071dd21ec0c2d0f9f41
# Note: manifest digest differs from config (normal - manifest includes metadata)
# Docker Hub: https://hub.docker.com/layers/tlaurion/heads-dev-env/latest/images/sha256-5f890f3d...
# === End Reproducibility Check ===
```

### Understanding config digest vs manifest digest

Docker images have two different digests that serve different purposes:

- **Config digest** (authoritative): SHA256 hash of the image's config JSON — the actual build
  contents (layers, env, entrypoint). Shown as Image ID in `docker images` and
  `docker inspect --format='{{.Id}}'`.
- **Manifest digest**: SHA256 hash of the manifest JSON — wraps the config digest plus layer
  blob references and media types. Shown in Docker Hub layer URLs.

**For reproducibility verification, the config digest is authoritative** because it represents
the actual build contents. The manifest can change (e.g., when metadata is added) while the
config stays the same.

To verify manually on Docker Hub:

1. Run the check with `HEADS_CHECK_REPRODUCIBILITY=1 ./docker_local_dev.sh`
2. Note the **Config digest** value shown
3. Go to the Docker Hub tags page: `https://hub.docker.com/r/{repo}/tags`
4. Click your tag (e.g., `latest`)
5. The URL will be `https://hub.docker.com/layers/{repo}/{tag}/images/sha256-{digest}` - this shows the **manifest digest**
6. The config digest should match what the script reported (fetched via registry API)

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
# Remote image (pulled tlaurion/heads-dev-env:v0.2.6): sha256:75af4c81...
# ✗ MISMATCH: Image IDs differ after pull.
#   Local:  sha256:5f890f3d...
#   Remote: sha256:75af4c81...
# === End Reproducibility Check ===
```

Note: The reproducibility check compares **config digests** (what matters for reproducibility).
The script also shows manifest digests for reference - these can differ from config digests
because manifest includes additional metadata. The config digest is authoritative.

### Method 2: Standalone reproducibility check

```bash
# Compare your local dev image with a published version
./docker/check_reproducibility.sh linuxboot/heads:dev-env tlaurion/heads-dev-env:v0.2.7

# Output (example of a match):
# ✓ SUCCESS: Digests match!
#   Your local build is reproducible and identical to tlaurion/heads-dev-env:v0.2.7
```

### Method 3: Manual digest inspection

```bash
# Get the digest of your local image (after docker load)
docker inspect --format='{{.Id}}' linuxboot/heads:dev-env

# Compare with the published image (will pull if needed)
docker pull tlaurion/heads-dev-env:v0.2.7
docker inspect --format='{{.Id}}' tlaurion/heads-dev-env:v0.2.7
```

### When digests should match

✓ **Digests match** — your build is **reproducible and trustworthy**; matches the
maintainer's published image for that Nix snapshot. Happens when:

- `flake.nix` and `flake.lock` are **not modified** (repository is clean relative to these files)
- The same Nix version and dependencies are used
- Build runs on the same Nix store state

✗ **Digests differ** — expected when:

- You have uncommitted changes in `flake.nix` or `flake.lock`
- Different Nix version or Nix dependencies resolved differently on your system
- Using a different `nixpkgs` version than the locked one in `flake.lock`

### Trust model

The `tlaurion/heads-dev-env` image on Docker Hub is the **maintainer's canonical build**
and serves as the source of truth for reproducibility. By verifying that your
locally-built image produces the same digest as the published version you confirm:

1. **No tampering**: Your build environment has not been compromised
2. **Reproducibility**: The Heads build system is deterministic for your specific Nix snapshot
3. **Auditability**: You can map your build back to a specific published, reviewed version

**Recommendation**: Always pin to a specific version tag (e.g., `tlaurion/heads-dev-env:v0.2.7`)
rather than `:latest`, and verify the digest matches the published value before using it
for critical builds.

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

# Explicit wrapper flag (avoids ambiguity)
./docker/pin-and-run.sh -w ./docker_repro.sh tlaurion/heads-dev-env:v0.2.7 -- make BOARD=qemu-coreboot-fbwhiptail-tpm2
```

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

1. **Reproducibility**: Before pushing, verify `nix build --out-link docker/result .#dockerImage` produces a deterministic result (`flake.nix` and `flake.lock` must be committed and clean).
2. **Digest verification**: After pushing, use `./docker/check_reproducibility.sh` to verify local and remote digests match.
3. **Supply chain**: Pin digest in `docker/DOCKER_REPRO_DIGEST` and `.circleci/config.yml` to ensure all builds reference an immutable, auditable image.
4. **Documentation**: Update the version comment in `docker/DOCKER_REPRO_DIGEST` so users know which image version is pinned.
5. **User migration**: When releasing a new version, communicate the new digest and version in release notes.

Notes:

- Local builds can use `:latest` tag, which will use the latest tested successful CircleCI run
- To reproduce CircleCI results, make sure to use the same versioned tag declared under `.circleci/config.yml`'s `image:`

### For forks and alternate maintainers

```bash
export HEADS_MAINTAINER_DOCKER_IMAGE="youruser/heads-dev-env"

# All scripts will now reference your repository
./docker_local_dev.sh make BOARD=x230
HEADS_CHECK_REPRODUCIBILITY=1 ./docker_local_dev.sh

# Reproducibility check compares against youruser/heads-dev-env:latest
# resolve_docker_image uses youruser/heads-dev-env as the base image
```

The repository file `docker/DOCKER_REPRO_DIGEST` pins the canonical reproducible image
used by `./docker_repro.sh`, ensuring immutable, secure builds. Update the appropriate
file after publishing a new image to keep the repo in sync.
