#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage: $0 [--yes|-y] IMAGE[:TAG|@DIGEST]

Helper to print the full 'repo@digest' and the raw digest for a docker image.
Behavior:
 - The script treats the provided image reference literally. Provide exact `repo/name:tag` or `repo@digest` (e.g. `tlaurion/heads-dev-env:v0.2.7`).
 - If the image exists locally, the script prints the first RepoDigest (repo@digest) and the raw digest.
 - If the image is not present locally, the script will offer to pull the exact provided reference to obtain a local RepoDigest (interactive or `-y`).
 - The script prefers to operate on local image state (e.g., Docker local RepoDigests). If a local digest is not available it may query the Docker Hub v2 HTTP API (docker.io) via `curl` to obtain an authoritative manifest digest for docker.io images; this requires network access and appropriate registry connectivity. For other registries or Docker versions you may still need to use `docker manifest inspect` or `skopeo inspect` manually if `RepoDigests` is not populated.

Options:
  -y, --yes   Automatically pull the image if it is not present locally (non-interactive)
  -h, --help  Show this help message

Examples:
  ./docker/get_digest.sh tlaurion/heads-dev-env:v0.2.7
  ./docker/get_digest.sh tlaurion/heads-dev-env:latest
  ./docker/get_digest.sh -y tlaurion/heads-dev-env:v0.2.7
  # Note: provide the exact repo:name:tag you intend; the script treats the reference literally.
USAGE
}

if [ $# -lt 1 ]; then
  usage
  exit 2
fi

auto_yes=0
if [ "${1:-}" = "-y" ] || [ "${1:-}" = "--yes" ]; then
  auto_yes=1
  shift
fi
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ $# -ne 1 ]; then
  usage
  exit 2
fi

image="$1"

# Treat the provided image reference literally and do not try to append ':latest'.
# The caller should provide the exact reference they intend (e.g. 'tlaurion/heads-dev-env:v0.2.7'),
# and the script will inspect that exact reference and prompt to pull it if missing.
image_provided="${image}"
image="${image_provided}"

# Reject refs without a tag (unless a digest was provided).
if [[ "${image}" != *@* ]]; then
  _last_component="${image##*/}"
  if [[ "${_last_component}" != *:* ]]; then
    echo "Error: image reference '${image}' has no tag; please specify :tag or @digest." >&2
    exit 2
  fi
fi

# Ensure docker is available
if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker not found in PATH" >&2
  exit 1
fi

# Source shared helpers so we can print digest info consistently
# shellcheck source=docker/common.sh
. "$(dirname "$0")/common.sh"

# If the image already includes a digest (repo@sha256:...), return it
if [[ "${image}" == *@* ]]; then
  echo "${image}"
  echo "${image#*@}"
  exit 0
fi

# Use the provided image reference exactly; do not attempt alternate forms.
local_repo_digest=""
manifest_digest=""

# Check local RepoDigest for the exact provided image reference
local_repo_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "${image}" 2>/dev/null || true)
if [ -n "${local_repo_digest}" ]; then
  echo "${local_repo_digest}"
  echo "${local_repo_digest#*@}"
  exit 0
fi

# We prefer to operate on local image state (RepoDigests). If there's no local RepoDigest we may query the
# Docker Hub v2 API (docker.io) to obtain a manifest digest for docker.io images as a best-effort. This requires
# network access and a working curl; for non-docker.io registries or if the Hub API cannot be used, the user may
# need to pull the image or use tools like `docker manifest inspect`/`skopeo inspect` manually.
manifest_digest=""

# If we couldn't get a manifest digest locally, try the Docker Hub registry API as a fallback
if [ -z "${manifest_digest}" ]; then
  # Only attempt the Docker Hub v2 API for docker.io-style images
  # Parse repo and tag
  repo="${image%:*}"
  tag="${image##*:}"

  # Normalize repo for Docker Hub API: strip docker.io/ or registry-1.docker.io/ prefixes and
  # ensure 'library/' prefix for official images (e.g., 'ubuntu' -> 'library/ubuntu').
  repo_for_api="${repo#docker.io/}"
  repo_for_api="${repo_for_api#registry-1.docker.io/}"
  if ! printf '%s' "${repo_for_api}" | grep -q '/'; then
    repo_for_api="library/${repo_for_api}"
  fi

  # If repo contains a registry hostname (e.g., myregistry.example.com/...), skip hub API
  if ! printf '%s' "${repo}" | grep -q '/'; then
    # no slash in repo -- unlikely, but skip
    :
  fi

  # Determine if it's a docker.io (default) reference, explicitly docker.io, or a non-Hub registry.
  # We only attempt the Docker Hub API when:
  #   - the first path component is explicitly 'docker.io' or 'registry-1.docker.io', or
  #   - there is no explicit registry-like first component (no '.' or ':' and not 'localhost').
  # This avoids misclassifying host:port registries (e.g. localhost:5000/repo:tag) as docker.io.
  first_component="${repo%%/*}"
  is_docker_hub_ref=0
  if [ "${first_component}" = "docker.io" ] || [ "${first_component}" = "registry-1.docker.io" ]; then
    # Explicit Docker Hub hostname
    is_docker_hub_ref=1
  elif printf '%s' "${first_component}" | grep -q '\.'; then
    # Has a dot: looks like a custom registry hostname (e.g., myregistry.example.com)
    is_docker_hub_ref=0
  elif printf '%s' "${first_component}" | grep -q ':'; then
    # Has a colon: likely host:port (e.g., localhost:5000), treat as non-Hub
    is_docker_hub_ref=0
  elif [ "${first_component}" = "localhost" ]; then
    # localhost without an explicit port: also treat as non-Hub
    is_docker_hub_ref=0
  else
    # No dot, no colon, not localhost: treat as implicit Docker Hub (e.g., 'library/ubuntu', 'user/repo')
    is_docker_hub_ref=1
  fi
  if [ "${is_docker_hub_ref}" -eq 1 ]; then
    registry_api="https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo_for_api}:pull"

    # Prefer curl but fall back to wget; if neither is present skip the Hub API gracefully.
    downloader=""
    if command -v curl >/dev/null 2>&1; then
      downloader="curl"
    elif command -v wget >/dev/null 2>&1; then
      downloader="wget"
    else
      downloader=""
    fi

    if [ -z "${downloader}" ]; then
      echo "Note: neither 'curl' nor 'wget' is available; skipping Docker Hub API fallback." >&2
    elif ! command -v jq >/dev/null 2>&1; then
      echo "Note: 'jq' is not available; skipping Docker Hub API fallback (jq required for secure JSON parsing)." >&2
      echo "Install jq to enable registry API queries without pulling the image." >&2
    else
      if [ "${downloader}" = "curl" ]; then
        # Use jq for robust JSON parsing
        token=$(curl -fsSL "${registry_api}" | jq -r '.token // empty' 2>/dev/null || true)
        if [ -n "${token}" ]; then
          header=$(curl -fsSI -H "Accept: application/vnd.docker.distribution.manifest.v2+json" -H "Authorization: Bearer ${token}" "https://registry-1.docker.io/v2/${repo_for_api}/manifests/${tag}" 2>/dev/null || true)
          manifest_digest=$(printf '%s\n' "$header" | sed -n 's/Docker-Content-Digest:[[:space:]]*//Ip' | tr -d '\r' | head -n1 || true)
        fi
      else
        # wget path: fetch token body, then request manifest and parse headers from stderr
        # Use jq for robust JSON parsing
        token=$(wget -qO- "${registry_api}" | jq -r '.token // empty' 2>/dev/null || true)
        if [ -n "${token}" ]; then
          header=$(wget --server-response --header="Accept: application/vnd.docker.distribution.manifest.v2+json" --header="Authorization: Bearer ${token}" "https://registry-1.docker.io/v2/${repo_for_api}/manifests/${tag}" -O - 2>&1 || true)
          manifest_digest=$(printf '%s\n' "$header" | sed -n 's/Docker-Content-Digest:[[:space:]]*//Ip' | tr -d '\r' | head -n1 || true)
        fi
      fi
    fi
  fi

  if [ -n "${manifest_digest}" ]; then
    print_digest_info "${image%@*}@${manifest_digest}" "${manifest_digest}" "registry API" ""
    echo "${image%@*}@${manifest_digest}"
    echo "${manifest_digest}"

    # Offer to pull the exact image so the local Docker daemon has a repo@digest entry.
    if [ "${auto_yes}" = 1 ]; then
      echo "Auto-pull enabled: pulling ${image} (progress will be shown)..." >&2
      if ! docker pull "${image}" 2>&1 | sed -u 's/^/    /'; then
        exit 1
      fi
      local_repo_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "${image}" 2>/dev/null || true)
      if [ -n "${local_repo_digest}" ]; then
        echo "${local_repo_digest}"
        echo "${local_repo_digest#*@}"
        exit 0
      fi
      # else fall through and print the manifest digest as best-effort
      exit 0
    fi

    if [ -t 0 ]; then
      printf "Image '%s' is not present locally. Pull it now to obtain a local repo@digest? [y/N] " "${image}" >&2
      read -r ans
      case "${ans:-N}" in
        [Yy]* )
          if ! docker pull "${image}"; then
            echo "Failed to pull ${image}; aborting." >&2
            exit 1
          fi
          local_repo_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "${image}" 2>/dev/null || true)
          if [ -n "${local_repo_digest}" ]; then
            echo "${local_repo_digest}"
            echo "${local_repo_digest#*@}"
            exit 0
          fi
          # If still no RepoDigests, print manifest digest
          echo "${image%@*}@${manifest_digest}"
          echo "${manifest_digest}"
          exit 0
          ;;
        * )
          echo "Aborting without pulling; remote digest was: ${manifest_digest}" >&2
          echo "${image%@*}@${manifest_digest}"
          echo "${manifest_digest}"
          exit 0
          ;;
      esac
    else
      echo "Non-interactive shell: image not present locally and --yes not supplied; remote digest: ${manifest_digest}" >&2
      echo "${image%@*}@${manifest_digest}"
      echo "${manifest_digest}"
      exit 0
    fi
  fi
fi

# If we're here, we could not determine a digest from local RepoDigests or the registry.
# Offer to pull the image interactively (or non-interactively with --yes) to obtain a local RepoDigest.
if [ -t 0 ] || [ "${auto_yes}" = 1 ]; then
  if [ "${auto_yes}" = 1 ]; then
    pull_yes=1
  else
    echo "Note: the script treats the provided image reference literally. If you intended the tag 'v0.2.6' of repo 'tlaurion/heads', pass 'tlaurion/heads:v0.2.6'." >&2
    printf "Image '%s' is not present locally. Pull it now to try to obtain a local repo@digest? [y/N] " "${image}" >&2
    read -r _ans
    case "${_ans:-N}" in
      [Yy]* ) pull_yes=1 ;;
      * ) pull_yes=0 ;;
    esac
  fi

  if [ "${pull_yes:-0}" = 1 ]; then
    echo "Pulling ${image}..." >&2
    if ! docker pull "${image}"; then
      echo "Failed to pull ${image}; check network/credentials, ensure the reference is correct (e.g. 'tlaurion/heads:v0.2.6' if v0.2.6 is a tag), and run 'docker login' if needed." >&2
      exit 1
    fi
    # After pull, prefer repo@digest from local RepoDigests if available
    local_repo_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "${image}" 2>/dev/null || true)
    if [ -n "${local_repo_digest}" ]; then
      print_digest_info "${local_repo_digest}" "${local_repo_digest#*@}" "local" "DOCKER_LATEST_DIGEST"
      echo "${local_repo_digest}"
      echo "${local_repo_digest#*@}"
      exit 0
    fi

    # After pulling, check local RepoDigest again. If still missing, fail with a clear message.
    local_repo_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "${image}" 2>/dev/null || true)
    if [ -n "${local_repo_digest}" ]; then
      print_digest_info "${local_repo_digest}" "${local_repo_digest#*@}" "local" "DOCKER_LATEST_DIGEST"
      echo "${local_repo_digest}"
      echo "${local_repo_digest#*@}"
      exit 0
    fi

    echo "Pull completed but still did not produce a repo@digest for ${image}." >&2
    echo "You may need to inspect the image manually with 'docker inspect' or consult the registry for this specific ref." >&2
    exit 1
  fi
fi

# Nothing else we can do
echo "Failed to obtain digest for ${image}. Try pulling the image or use 'docker inspect'/'docker manifest inspect' manually." >&2
exit 1
