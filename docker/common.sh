#!/bin/bash

# Shared common Docker helpers for Heads dev scripts
# Meant to be sourced from docker_latest.sh / docker_local_dev.sh / docker_repro.sh

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: $0 [OPTIONS] -- [COMMAND]
Options:
Environment variables (opt-ins / opt-outs):
  HEADS_DISABLE_USB=1   Disable automatic USB passthrough (default: enabled when /dev/bus/usb exists)
  HEADS_X11_XAUTH=1     Explicitly mount $HOME/.Xauthority into the container for X11 auth
  HEADS_SKIP_DOCKER_REBUILD=1  Skip automatic rebuild of the local Docker image when flake.nix/flake.lock are uncommitted
  HEADS_NIX_EXTRA_FLAGS   Extra flags to append to Nix commands during rebuild (e.g. "--extra-experimental-features 'nix-command flakes'")
  HEADS_NIX_VERBOSE=1      Stream Nix output live during rebuild (default: on for dev scripts; set to 0 to silence)
  HEADS_AUTO_INSTALL_NIX=1 Automatically install Nix (single-user) if it's missing (interactive prompt suppressed)
  HEADS_AUTO_ENABLE_FLAKES=1 Automatically enable flakes by writing to $HOME/.config/nix/nix.conf (if needed)
  HEADS_SKIP_DISK_CHECK=1  Skip disk-space preflight check (default: perform check and warn)
  HEADS_MIN_DISK_GB=50     Minimum disk free (GB) required on '/' or '/nix' (default: 50)
  HEADS_STRICT_REBUILD=1   When set, treat rebuild failures (including 'No "fromImage" provided') as fatal
Command:
  The command to run inside the Docker container, e.g., make BOARD=BOARD_NAME
USAGE
}

# Track whether we supply Xauthority into the container
DOCKER_XAUTH_USED=0

# Ensure Nix is installed and flakes are enabled. Exits nonzero on failure.
ensure_nix_and_flakes() {
  # Check available disk space (on /nix if present, otherwise on /). Warn if < HEADS_MIN_DISK_GB (default 50GB).
  if [ "${HEADS_SKIP_DISK_CHECK:-0}" != "1" ]; then
    local min_gb=${HEADS_MIN_DISK_GB:-50}
    local target="/"
    if [ -d /nix ]; then target="/nix"; fi
    # df -Pk reports 1K-blocks, available in $4
    local avail_kb
    avail_kb=$(df -Pk "$target" | awk 'NR==2{print $4}') || avail_kb=0
    local required_kb=$((min_gb * 1024 * 1024))
    if [ "$avail_kb" -lt "$required_kb" ]; then
      echo "Warning: building the docker image and populating /nix may require ${min_gb}GB+ free on ${target}." >&2
      echo "Detected available: $(df -h --output=avail "$target" | tail -1)" >&2
      if [ -t 1 ]; then
        printf "Continue despite low disk space? [y/N] " >&2
        read -r _ans
        case "${_ans:-N}" in
          [Yy]* ) echo "Continuing despite low disk space." >&2 ;;
          * ) echo "Aborting due to insufficient disk space." >&2; return 1 ;;
        esac
      else
        echo "Non-interactive shell and insufficient disk space; aborting." >&2
        return 1
      fi
    fi
  fi

  # Ensure a downloader (curl or wget) is available for the Nix install script.
  local downloader_cmd=""
  if command -v curl >/dev/null 2>&1; then
    downloader_cmd="curl -L"
  elif command -v wget >/dev/null 2>&1; then
    downloader_cmd="wget -qO-"
  else
    echo "Error: neither 'curl' nor 'wget' is available; one is required to fetch the Nix installer." >&2
    if [ -t 1 ]; then
      echo "Please install 'curl' (recommended) or 'wget' and re-run this script." >&2
      echo "Examples (Debian/Ubuntu): sudo apt-get update && sudo apt-get install -y curl" >&2
      echo "(Fedora): sudo dnf install -y curl; (Arch): sudo pacman -Syu curl" >&2
    fi
    return 1
  fi

  if ! command -v nix >/dev/null 2>&1; then
    echo "Error: 'nix' not found on PATH." >&2
    echo "You can install Nix (single-user) with:" >&2
    echo "  [ -d /nix ] || ${downloader_cmd} https://nixos.org/nix/install | sh -s -- --no-daemon" >&2

    if [ "${HEADS_AUTO_INSTALL_NIX:-0}" = "1" ] && [ -t 1 ]; then
      echo "HEADS_AUTO_INSTALL_NIX=1: attempting automatic Nix install..." >&2
      local installer_url="https://nixos.org/nix/install"
      local tmpf
      tmpf=$(mktemp) || { echo "Failed to create temporary file for installer." >&2; return 1; }
      if [ "$downloader_cmd" = "curl -L" ]; then
        if ! curl -fsSL "$installer_url" -o "$tmpf"; then
          echo "Failed to download Nix installer." >&2; rm -f "$tmpf"; return 1
        fi
      else
        if ! wget -qO "$tmpf" "$installer_url"; then
          echo "Failed to download Nix installer." >&2; rm -f "$tmpf"; return 1
        fi
      fi
      local inst_sha
      if command -v sha256sum >/dev/null 2>&1; then
        inst_sha=$(sha256sum "$tmpf" | awk '{print $1}') || inst_sha=""
      elif command -v shasum >/dev/null 2>&1; then
        inst_sha=$(shasum -a 256 "$tmpf" | awk '{print $1}') || inst_sha=""
      else
        inst_sha=""
      fi
      if [ -n "$inst_sha" ]; then
        echo "Downloaded Nix installer to: $tmpf" >&2
        echo "Installer sha256: $inst_sha" >&2
      else
        echo "Downloaded Nix installer to: $tmpf (sha256 unavailable)" >&2
      fi

      # For supply-chain safety, do not auto-execute the downloaded installer.
      if [ -t 1 ]; then
        printf "Run the downloaded installer now? [y/N] " >&2
        read -r _run_ans
        case "${_run_ans:-N}" in
          [Yy]* ) if ! sh "$tmpf" --no-daemon; then echo "Nix install failed." >&2; rm -f "$tmpf"; return 1; fi ;;
          * ) echo "Installer saved to $tmpf. Verify its sha256 (printed above) and run it manually when ready: sh $tmpf --no-daemon" >&2; rm -f "$tmpf"; return 1 ;;
        esac
      else
        echo "Non-interactive shell: automatic install suppressed. Installer saved to $tmpf; verify and run manually." >&2
        return 1
      fi
      rm -f "$tmpf"
      # Prefer adding the nix profile bin dir to PATH instead of sourcing a dynamic file
      # This is easier to audit and avoids shellcheck SC1091
      export PATH="$HOME/.nix-profile/bin:$PATH" || true
      hash -r 2>/dev/null || true
    elif [ -t 1 ]; then
      echo "Note: building the Docker image and populating /nix may require ${HEADS_MIN_DISK_GB:-50}GB+ free on '/' or '/nix'." >&2
      printf "Install Nix now and enable flakes (required) [Y/n]? " >&2
      read -r ans
      case "${ans:-Y}" in
        [Yy]* )
          # Download installer to temporary file and show sha256 before executing
          local installer_url="https://nixos.org/nix/install"
          local tmpf
          tmpf=$(mktemp) || { echo "Failed to create temporary file for installer." >&2; return 1; }
          if [ "$downloader_cmd" = "curl -L" ]; then
            if ! curl -fsSL "$installer_url" -o "$tmpf"; then
              echo "Failed to download Nix installer." >&2; rm -f "$tmpf"; return 1
            fi
          else
            if ! wget -qO "$tmpf" "$installer_url"; then
              echo "Failed to download Nix installer." >&2; rm -f "$tmpf"; return 1
            fi
          fi
          local inst_sha
          if command -v sha256sum >/dev/null 2>&1; then
            inst_sha=$(sha256sum "$tmpf" | awk '{print $1}') || inst_sha=""
          elif command -v shasum >/dev/null 2>&1; then
            inst_sha=$(shasum -a 256 "$tmpf" | awk '{print $1}') || inst_sha=""
          else
            inst_sha=""
          fi
          if [ -n "$inst_sha" ]; then
            echo "Downloaded Nix installer to: $tmpf" >&2
            echo "Installer sha256: $inst_sha" >&2
          else
            echo "Downloaded Nix installer to: $tmpf (sha256 unavailable)" >&2
          fi
          if ! sh "$tmpf" --no-daemon; then echo "Nix install failed." >&2; rm -f "$tmpf"; return 1; fi
          rm -f "$tmpf"
          # Prefer adding the nix profile bin dir to PATH instead of sourcing a dynamic file
          # This is easier to audit and avoids shellcheck SC1091
          export PATH="$HOME/.nix-profile/bin:$PATH" || true
          hash -r 2>/dev/null || true
          ;;
        * ) echo "Flakes are required; aborting." >&2; return 1 ;;
      esac
    else
      echo "Non-interactive shell: cannot install Nix automatically. Please install Nix and enable flakes (see README.md)." >&2
      return 1
    fi
  fi

  mkdir -p "$HOME/.config/nix"
  if ! grep -q "nix-command" "$HOME/.config/nix/nix.conf" 2>/dev/null && ! grep -q "nix-command" /etc/nix/nix.conf 2>/dev/null; then
    if [ "${HEADS_AUTO_ENABLE_FLAKES:-0}" = "1" ]; then
      echo "Enabling flakes by writing 'experimental-features = nix-command flakes' to $HOME/.config/nix/nix.conf" >&2
      echo "experimental-features = nix-command flakes" >> "$HOME/.config/nix/nix.conf" || true
    elif [ -t 1 ]; then
      printf "Flakes are required but not enabled. Add 'experimental-features = nix-command flakes' to %s now [Y/n]? " "$HOME/.config/nix/nix.conf" >&2
      read -r ans2
      case "${ans2:-Y}" in
        [Yy]* ) echo "experimental-features = nix-command flakes" >> "$HOME/.config/nix/nix.conf" || true; echo "Wrote experimental features to $HOME/.config/nix/nix.conf" >&2 ;; 
        * ) echo "Flakes are required; aborting. Please enable flakes manually and rerun the script." >&2; return 1 ;;
      esac
    else
      echo "Flakes are required but not enabled in non-interactive shell. Please enable them and rerun the script (see README.md)." >&2
      return 1
    fi
  fi
}

# Kill scdaemon/pcscd when USB passthrough is present (minimal, automatic). Only targets processes that are actually using USB device nodes.
kill_usb_processes() {
  [ -d /dev/bus/usb ] || return 0
  [ "${HEADS_DISABLE_USB:-0}" = "1" ] && { echo "HEADS_DISABLE_USB=1: skipping USB cleanup" >&2; return 0; }

  # Use lsof to find processes holding /dev/bus/usb nodes, then filter for scdaemon/pcscd
  local pids

  # Choose how to run lsof: prefer direct invocation as root, else use sudo if available without prompting.
  local lsof_cmd=""
  if [ "$(id -u)" = "0" ]; then
    lsof_cmd="lsof"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    lsof_cmd="sudo lsof"
  elif command -v sudo >/dev/null 2>&1; then
    echo "sudo present but would prompt for a password; skipping automatic USB cleanup to avoid interactive prompts" >&2
    return 0
  elif command -v lsof >/dev/null 2>&1; then
    # No sudo, but lsof present; attempt to run it (may fail if insufficient permissions)
    lsof_cmd="lsof"
  else
    echo "lsof not available; cannot detect processes holding USB devices; skipping cleanup" >&2
    return 0
  fi

  # Match all bus/device nodes to avoid missing higher-numbered buses (no assumption about leading zeros)
  # Make the pipeline resilient to failures so it doesn't abort the caller.
  pids=$($lsof_cmd /dev/bus/usb/*/* 2>/dev/null | awk 'NR>1 {print $2}' | xargs -r ps -p 2>/dev/null || true | grep -E 'scdaemon|pcscd' 2>/dev/null | awk '{print $1}' || true)
  if [ -z "${pids}" ]; then
    [ "${HEADS_USB_VERBOSE:-0}" = "1" ] && echo "No scdaemon/pcscd processes using USB devices." >&2
    return 0
  fi

  echo "Detected scdaemon/pcscd processes using USB devices: ${pids}" >&2
  echo "WARNING: About to kill the above processes to free USB devices for passthrough. To skip this automatic action set HEADS_DISABLE_USB=1 in your environment." >&2
  if [ -t 1 ]; then
    echo "Press Ctrl-C to abort within 3 seconds if you do NOT want these processes killed." >&2
    sleep 3
  fi

  # Try to kill: prefer running as root, else try sudo without prompting in non-interactive shells
  # Convert the whitespace-separated PID list into an array for safe expansion
  read -r -a pids_array <<< "${pids}"

  if [ "$(id -u)" = "0" ]; then
    if kill -9 "${pids_array[@]}" 2>/dev/null; then
      echo "Killed PIDs: ${pids}" >&2
    else
      echo "Failed to kill some PIDs: ${pids}" >&2
    fi
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    if sudo kill -9 "${pids_array[@]}" 2>/dev/null; then
      echo "Killed PIDs: ${pids}" >&2
    else
      echo "Failed to kill some PIDs: ${pids}" >&2
    fi
  elif [ -t 1 ]; then
    # Interactive and sudo present but may prompt for password; attempt it so user can enter password.
    if command -v sudo >/dev/null 2>&1; then
      if sudo kill -9 "${pids_array[@]}"; then
        echo "Killed PIDs: ${pids}" >&2
      else
        echo "Failed to kill some PIDs: ${pids}" >&2
      fi
    else
      echo "Interactive shell but sudo not available; please run: kill -9 ${pids}" >&2
    fi
  else
    echo "Non-interactive: unable to kill PIDs (sudo not available or would prompt); please run: sudo kill -9 ${pids}" >&2
  fi
}

# Rebuild local Docker image when flake.nix or flake.lock are modified and repo is dirty.
# Opt-out by setting HEADS_SKIP_DOCKER_REBUILD=1 in the environment.
maybe_rebuild_local_image() {
  local image="$1"
  if [ "${HEADS_SKIP_DOCKER_REBUILD:-0}" = "1" ]; then
    echo "HEADS_SKIP_DOCKER_REBUILD=1: skipping Docker rebuild" >&2
    return 0
  fi

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -n "$(git status --porcelain | grep -E 'flake\.nix|flake\.lock' || true)" ]; then
    echo "**Warning: Uncommitted changes detected in flake.nix or flake.lock. The Docker image will be rebuilt!**" >&2
    echo "If this was not intended, please CTRL-C now, commit your changes and rerun the script." >&2
    echo "Building the Docker image from flake.nix..." >&2

    # Ensure Nix and flakes are present and enabled (interactive helper)
    ensure_nix_and_flakes || return 1

    # Allow users to supply additional flags, e.g., --extra-experimental-features 'nix-command flakes'
    # Parse HEADS_NIX_EXTRA_FLAGS as shell words so quoted multi-word values are preserved as a single argument.
    # Example: export HEADS_NIX_EXTRA_FLAGS="--extra-experimental-features 'nix-command flakes'"
    # Note: because the variable is evaluated as shell words, do NOT set this from untrusted input.
    local -a extra_flags_array=()
    if [ -n "${HEADS_NIX_EXTRA_FLAGS:-}" ]; then
      # Disable pathname expansion to avoid accidental globbing of values like '*'
      set -f
      # shellcheck disable=SC2086,SC2206 # intentional word-splitting to form args from a wordspec
      eval "extra_flags_array=($HEADS_NIX_EXTRA_FLAGS)"
      set +f
    fi

    # If HEADS_NIX_VERBOSE=1 we stream Nix output live so users can see progress/errors in real time.
    if [ "${HEADS_NIX_VERBOSE:-1}" = "1" ]; then
      echo "HEADS_NIX_VERBOSE=1: streaming 'nix develop' output..." >&2
      if ! nix "${extra_flags_array[@]:-}" --print-build-logs --verbose develop --ignore-environment --command true; then
        echo "nix develop failed; see above output for diagnostics." >&2
        echo "Suggestion: ensure Nix is installed and flakes are enabled (see README.md), or set HEADS_NIX_EXTRA_FLAGS to pass flags (e.g. --extra-experimental-features 'nix-command flakes')." >&2
        return 1
      fi

      echo "HEADS_NIX_VERBOSE=1: streaming 'nix build' output..." >&2
      if ! nix "${extra_flags_array[@]:-}" --print-build-logs --verbose build .#dockerImage; then
        echo "nix build failed; see above output for diagnostics." >&2
        echo "Suggestion: ensure Nix is installed and flakes are enabled (see README.md), or set HEADS_NIX_EXTRA_FLAGS to pass flags (e.g. --extra-experimental-features 'nix-command flakes')." >&2
        return 1
      fi
    else
      # Try developing the nix shell first to catch early errors. Capture output and print diagnostics on failure.
      local develop_out
      if ! develop_out=$(nix "${extra_flags_array[@]:-}" --print-build-logs --verbose develop --ignore-environment --command true 2>&1); then
        echo "nix develop failed; output below:" >&2
        printf '%s
' "$develop_out" >&2
        echo "---" >&2
        echo "Suggestions: ensure Nix is installed and flakes are enabled (see README.md), or set HEADS_NIX_EXTRA_FLAGS to pass flags (e.g. --extra-experimental-features 'nix-command flakes')." >&2
        echo "You can also run the failing command manually to get full diagnostics, e.g.:" >&2
        echo "  nix --print-build-logs --verbose develop --ignore-environment --command true" >&2
        return 1
      fi

      # Build the dockerImage attribute and load it into Docker. Capture output and print diagnostics on failure.
      local build_out
      if ! build_out=$(nix "${extra_flags_array[@]:-}" --print-build-logs --verbose build .#dockerImage 2>&1); then
        echo "nix build failed; output below:" >&2
        printf '%s
' "$build_out" >&2
        echo "---" >&2
        if printf '%s
' "$build_out" | grep -q "No 'fromImage' provided"; then
          echo "Note: build failed with 'No 'fromImage' provided' which can happen when nixpkgs/dockertools expects an explicit 'fromImage'." >&2
          echo "This repository intentionally uses no base image; continuing without rebuilding the Docker image." >&2
          echo "If you want the build to fail instead, set HEADS_STRICT_REBUILD=1 in your environment." >&2
          if [ "${HEADS_STRICT_REBUILD:-0}" = "1" ]; then
            echo "HEADS_STRICT_REBUILD=1: failing due to 'No 'fromImage' provided'" >&2
            return 1
          else
            echo "Proceeding without rebuilding the local Docker image." >&2
            return 0
          fi
        fi
        echo "Suggestions: ensure Nix is installed and flakes are enabled (see README.md), or set HEADS_NIX_EXTRA_FLAGS to pass flags (e.g. --extra-experimental-features 'nix-command flakes')." >&2
        echo "You can also run the failing command manually to get full diagnostics, e.g.:" >&2
        echo "  nix --print-build-logs --verbose build .#dockerImage" >&2
        return 1
      fi
    fi

    docker load <result
  else
    echo "Git repository is clean. Using previously built Docker image." >&2
  fi
}

# Resolve Docker image preferring a pinned digest from the environment or a repository file.
# Usage: resolve_docker_image <fallback_image> <digest_env_varname> <digest_filename> [prompt_on_latest]
# - <fallback_image>: e.g. tlaurion/heads-dev-env:vX.Y.Z or tlaurion/heads-dev-env:latest
# - <digest_env_varname>: name of env var to consult (e.g. DOCKER_REPRO_DIGEST)
# - <digest_filename>: filename under the repo's docker/ directory to read if env var is unset
# - [prompt_on_latest]: if '1', prompt interactively before using an unpinned ':latest' when no digest is found
resolve_docker_image() {
  local fallback_image="$1"
  local digest_env_varname="$2"
  local digest_filename="$3"
  local prompt_on_latest="${4:-1}"

  # If the caller already supplied a digest (image@sha256:...), return as-is
  if [[ "${fallback_image}" == *@* ]]; then
    echo "${fallback_image}"
    return 0
  fi

  # Check environment variable first
  local digest_value=""
  digest_value="${!digest_env_varname:-}"
  local digest_source=""
  if [ -n "${digest_value}" ]; then
    digest_source="env ${digest_env_varname}"
  fi

  # If not present in env, look for a repository file under docker/
  if [ -z "${digest_value}" ]; then
    local repo_dir
    repo_dir=$(cd "$(dirname "$0")" && pwd)
    local digest_file="$repo_dir/docker/${digest_filename}"
    if [ -f "${digest_file}" ]; then
      digest_value=$(sed -n 's/#.*//; /^\s*$/d; p' "${digest_file}" | head -n1 || true)
      digest_source="file ${repo_dir}/docker/${digest_filename}"
    fi

    # Special-case: if we're resolving the LATEST digest and none is provided, fall
    # back to the REPRO digest (env var first, then repository file) since the
    # latest convenience image normally mirrors the repro image in practice.
    if [ -z "${digest_value}" ] && [ "${digest_env_varname}" = "DOCKER_LATEST_DIGEST" ]; then
      if [ -n "${DOCKER_REPRO_DIGEST:-}" ]; then
        digest_value="${DOCKER_REPRO_DIGEST}"
        digest_source="env DOCKER_REPRO_DIGEST"
      else
        local repro_file="$repo_dir/docker/DOCKER_REPRO_DIGEST"
        if [ -f "${repro_file}" ]; then
          digest_value=$(sed -n 's/#.*//; /^\s*$/d; p' "${repro_file}" | head -n1 || true)
          digest_source="file ${repo_dir}/docker/DOCKER_REPRO_DIGEST"
        fi
      fi
      if [ -n "${digest_value}" ]; then
        echo "Note: no DOCKER_LATEST_DIGEST set; using DOCKER_REPRO_DIGEST as fallback for latest image." >&2
      fi
    fi
  fi

  if [ -n "${digest_value}" ]; then
    # Allow digest_value to be either a full 'repo@digest' or just the digest itself.
    # Trim whitespace/newlines
    digest_value=$(printf '%s' "${digest_value}" | tr -d '[:space:]')

    # If the value already contains an '@', treat it as a full image reference and normalize digest form below.
    if [[ "${digest_value}" == *@* ]]; then
      # Normalize possible 'sha256-<hex>' -> 'sha256:<hex>' or raw hex -> 'sha256:<hex>' inside the trailing part
      local prefix=${digest_value%@*}
      local trailing=${digest_value#*@}
      if [[ "$trailing" =~ ^sha256-[0-9a-fA-F]{64}$ ]]; then
        trailing="${trailing/-/:}"
      elif [[ "$trailing" =~ ^[0-9a-fA-F]{64}$ ]]; then
        trailing="sha256:${trailing}"
      fi
      local image_ref="${prefix}@${trailing}"
      print_digest_info "${image_ref}" "${trailing}" "${digest_source}" "${digest_env_varname}"
      echo "${image_ref}"
      return 0
    fi

    # Normalize forms: accept 'sha256-<hex>' or raw 64-hex by converting them to 'sha256:<hex>'
    if [[ "${digest_value}" =~ ^sha256-[0-9a-fA-F]{64}$ ]]; then
      digest_value="${digest_value/-/:}"
    elif [[ "${digest_value}" =~ ^[0-9a-fA-F]{64}$ ]]; then
      digest_value="sha256:${digest_value}"
    fi

    # Strip any tag from fallback_image to get the repository name (tlaurion/heads-dev-env)
    local image_repo
    image_repo="${fallback_image%%[:@]*}"
    print_digest_info "${image_repo}@${digest_value}" "${digest_value}" "${digest_source}" "${digest_env_varname}"
    echo "${image_repo}@${digest_value}"
    return 0
  fi

  # No digest available; handle prompts for unpinned :latest if requested
  if [[ "${fallback_image}" == *":latest" && "${HEADS_ALLOW_UNPINNED_LATEST:-0}" != "1" && "${prompt_on_latest}" = "1" ]]; then
    if [ -t 1 ]; then
      printf "The configured image '%s' is unpinned (':latest'). Proceed despite supply-chain risk? [y/N] " "${fallback_image}" >&2
      read -r _ans
      case "${_ans:-N}" in
        [Yy]* ) echo "Proceeding with unpinned image." >&2 ;;
        * ) printf "Aborting: set %s to pin an immutable image or set HEADS_ALLOW_UNPINNED_LATEST=1 to bypass this prompt.\n" "${digest_env_varname}" >&2; exit 1 ;;
      esac
    else
      echo "Refusing to use unpinned ':latest' in non-interactive mode without HEADS_ALLOW_UNPINNED_LATEST=1; aborting." >&2
      exit 1
    fi
  fi

  # No digest and no prompting required; return the fallback image as-is
  echo "${fallback_image}"
}


# Print concise, consistent digest information for users and scripts.
# Usage: print_digest_info <image_ref> <digest> [<source>] [<envvar>]
print_digest_info() {
  local image_ref="${1:-}"
  local digest="${2:-}"
  local source="${3:-}"
  local envvar="${4:-}"

  # Keep output explicit and easy to copy into an export command
  echo "Image: ${image_ref}" >&2
  echo "Digest: ${digest}" >&2
  if [ -n "${source}" ]; then
    echo "Resolved from: ${source}" >&2
  fi
  if [ -n "${envvar}" ]; then
    echo "Tip: To force this image in future: export ${envvar}=${digest}" >&2
  else
    echo 'Tip: To force a wrapper to use this image next time, export the digest, e.g.:' >&2
    printf "  export DOCKER_LATEST_DIGEST=%s\n" "${digest}" >&2
  fi
}


# Build docker options (returns single string on stdout)
build_docker_opts() {
  local opts=( -e "DISPLAY=${DISPLAY:-}" --network host --rm -ti )

  # USB passthrough
  if [ -d "/dev/bus/usb" ] && [ "${HEADS_DISABLE_USB:-0}" != "1" ]; then
    opts+=( --device=/dev/bus/usb:/dev/bus/usb )
    echo "--->USB passthrough enabled; to disable set HEADS_DISABLE_USB=1" >&2
  elif [ -d "/dev/bus/usb" ]; then
    echo "--->Host USB present; USB passthrough disabled by HEADS_DISABLE_USB=1" >&2
  fi

  # KVM passthrough
  if [ -e /dev/kvm ]; then
    opts+=( --device=/dev/kvm:/dev/kvm )
    echo "--->Host KVM device found; enabling /dev/kvm passthrough" >&2
  elif [ -e /proc/kvm ]; then
    echo "--->Host reports KVM available but /dev/kvm is missing; load kvm module" >&2
  fi

  # X11 forwarding: mount socket and try programmatic Xauthority when possible
  if [ -d "/tmp/.X11-unix" ]; then
    opts+=( -v /tmp/.X11-unix:/tmp/.X11-unix )

    # If the user explicitly requests to use their $HOME/.Xauthority, honor that and bypass programmatic cookie logic.
    if [ "${HEADS_X11_XAUTH:-0}" != "0" ]; then
      if [ -f "${HOME}/.Xauthority" ]; then
        DOCKER_XAUTH_USED=1
        opts+=( -v "${HOME}/.Xauthority:/root/.Xauthority:ro" -e "XAUTHORITY=/root/.Xauthority" )
        echo "--->HEADS_X11_XAUTH set: mounting ${HOME}/.Xauthority into container and bypassing programmatic Xauthority" >&2
      else
        echo "--->HEADS_X11_XAUTH set but ${HOME}/.Xauthority not found; not attempting programmatic Xauthority; GUI may fail" >&2
      fi
    elif command -v xauth >/dev/null 2>&1; then
      local XAUTH_HOST
      XAUTH_HOST="/tmp/.docker.xauth-$(id -u)"
      # Create Xauthority file securely (restrict permissions) to avoid leaking the X11 cookie.
      # Use a restrictive umask so the file is created with 0600, and ensure chmod enforces it.
      local old_umask
      old_umask=$(umask)
      umask 077
      : >"$XAUTH_HOST" 2>/dev/null || true
      umask "$old_umask"
      chmod 600 "$XAUTH_HOST" 2>/dev/null || true
      xauth nlist "${DISPLAY}" 2>/dev/null | sed -e 's/^..../ffff/' | xauth -f "$XAUTH_HOST" nmerge - 2>/dev/null || true
      if [ -s "$XAUTH_HOST" ]; then
        DOCKER_XAUTH_USED=1
        opts+=( -v "$XAUTH_HOST:$XAUTH_HOST:ro" -e "XAUTHORITY=$XAUTH_HOST" )
        echo "--->Using programmatic Xauthority $XAUTH_HOST for X11 auth" >&2
      elif [ -f "${HOME}/.Xauthority" ]; then
        DOCKER_XAUTH_USED=1
        opts+=( -v "${HOME}/.Xauthority:/root/.Xauthority:ro" -e "XAUTHORITY=/root/.Xauthority" )
        echo "--->Falling back to mounting ${HOME}/.Xauthority into container" >&2
      else
        echo "--->X11 socket present but no Xauthority found; GUI may fail" >&2
      fi
    else
      if [ -f "${HOME}/.Xauthority" ]; then
        opts+=( -v "${HOME}/.Xauthority:/root/.Xauthority:ro" -e "XAUTHORITY=/root/.Xauthority" )
        echo "--->Mounting ${HOME}/.Xauthority into container for X11 auth (xauth missing)" >&2
      fi
    fi
  elif [ "${HEADS_X11_XAUTH:-0}" != "0" ] && [ -f "${HOME}/.Xauthority" ]; then
    opts+=( -v "${HOME}/.Xauthority:/root/.Xauthority:ro" -e "XAUTHORITY=/root/.Xauthority" )
    echo "--->HEADS_X11_XAUTH=1: mounting ${HOME}/.Xauthority into container" >&2
  fi

  # If host xhost does not list LOCAL, warn the user about enabling access only when
  # we did NOT supply an Xauthority cookie. We do NOT modify xhost automatically (security).
  if [ "${DOCKER_XAUTH_USED:-0}" = "0" ] && command -v xhost >/dev/null 2>&1 && ! xhost | grep -q "LOCAL:"; then
    echo "--->X11 auth may be strict; no automatic 'xhost' changes are performed. Provide Xauthority (install xauth) or run 'xhost +SI:localuser:root' manually if you accept the security risk." >&2
  fi

  local joined
  printf -v joined "%s " "${opts[@]}"
  echo "${joined}"
}

# Common run helper
run_docker() {
  local image="$1"; shift
  local opts host_workdir container_workdir DOCKER_OPTS_ARRAY
  opts=$(build_docker_opts)
  # Convert the single-line opts string into an array for safe expansion
  read -r -a DOCKER_OPTS_ARRAY <<< "$opts"
  host_workdir="$(pwd)"
  container_workdir="${host_workdir}"

  parts=()
  case "${opts}" in *"/dev/kvm"*) parts+=(KVM=on) ;; *) parts+=(KVM=off) ;; esac
  case "${opts}" in *"/dev/bus/usb"*) parts+=(USB=on) ;; *) parts+=(USB=off) ;; esac
  case "${opts}" in *"/tmp/.X11-unix"*) parts+=(X11=on) ;; *) parts+=(X11=off) ;; esac

  echo "---> Running container with: ${parts[*]} ; mount ${host_workdir} -> ${container_workdir}" >&2

  # If no command was provided by the caller, start an interactive shell inside the container.
  # We prefer bash when available, and fall back to sh; the sh -c wrapper ensures the
  # container will get a usable shell on minimal images.
  if [ $# -eq 0 ]; then
    echo "---> No command provided: launching interactive shell inside container (bash if available, otherwise sh)" >&2
    set -- sh -c 'exec bash || exec sh'
  fi

  echo "---> Full docker command: docker run ${DOCKER_OPTS_ARRAY[*]} -v ${host_workdir}:${container_workdir} -w ${container_workdir} ${image} -- $*" >&2

  exec docker run "${DOCKER_OPTS_ARRAY[@]}" -v "${host_workdir}:${container_workdir}" -w "${container_workdir}" "${image}" -- "$@"
}

trap "echo 'Script interrupted. Exiting...'; exit 1" SIGINT
for arg in "$@"; do
  case "$arg" in -h|--help) usage; exit 0 ;; esac
done

# Note: do NOT run USB cleanup (kill_usb_processes) at source time as it has side effects.
# Call `kill_usb_processes` from wrapper scripts only when they intend to actually launch containers with USB passthrough.

# Informational reminder printed by each docker wrapper
echo "----"
echo "Usage reminder: The minimal command is 'make BOARD=XYZ', where additional options, including 'V=1' or 'CPUS=N' are optional."
echo "For more advanced QEMU testing options, refer to targets/qemu.md and boards/qemu-*/*.config."
echo
echo "Type exit within docker image to get back to host if launched interactively!"
echo "----"
echo
