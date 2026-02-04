#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage: $0 [-y|--yes] [-w|--wrapper WRAPPER] IMAGE [-- [WRAPPER [WRAPPER_ARGS...]]]

Helper: obtain an image digest and run a docker wrapper pinned to that digest.
- IMAGE: an exact docker image ref (e.g. tlaurion/heads-dev-env:v0.2.6)
- If the image is not present locally, the helper will probe the registry and
  offer to pull it (use -y/--yes to auto-pull).
- WRAPPER: the docker wrapper to execute (e.g. ./docker_latest.sh or ./docker_repro.sh).
  If omitted the helper will use ./docker_latest.sh by default when the first
  argument after '--' does not look like a wrapper or when none is supplied.

Options:
  -y, --yes      Automatically pull the image if it is not present locally (non-interactive)
  -w, --wrapper  Specify the wrapper to run (explicitly); useful when default detection is ambiguous
  -h, --help     Show this help message

Examples:
  # Interactive: obtain digest and run the 'latest' wrapper pinned to that digest (explicit wrapper recommended)
  ./docker/pin-and-run.sh tlaurion/heads-dev-env:v0.2.6 -- ./docker_latest.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2

  # Auto-pull and run (auto-pull the ref to obtain a local digest then run wrapper)
  ./docker/pin-and-run.sh -y tlaurion/heads-dev-env:v0.2.6 -- ./docker_latest.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2

  # Shortcut: omit the wrapper and just provide the command — the helper will use the default './docker_latest.sh'
  ./docker/pin-and-run.sh tlaurion/heads-dev-env:v0.2.6 -- make BOARD=qemu-coreboot-fbwhiptail-tpm2

  # Use a different wrapper explicitly (e.g. repro):
  ./docker/pin-and-run.sh -w ./docker_repro.sh tlaurion/heads-dev-env:v0.2.6 -- make BOARD=qemu-coreboot-fbwhiptail-tpm2
USAGE
}

auto_yes=0
wrapper_override=0
wrapper=""

# Parse options (allow -y/--yes, -w/--wrapper WRAPPER, -h/--help)
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)
      auto_yes=1; shift ;;
    -w|--wrapper)
      if [ $# -lt 2 ]; then
        echo "Missing argument for --wrapper" >&2; usage; exit 2
      fi
      wrapper="$2"; wrapper_override=1; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    *)
      break ;;
  esac
done

if [ $# -lt 1 ]; then
  usage
  exit 2
fi

image="$1"; shift

# Default wrapper if none supplied via -w
default_wrapper="$(dirname "$0")/docker_latest.sh"
wrapper_args=()

if [ $wrapper_override -eq 0 ]; then
  # No explicit wrapper - try heuristic or use default
  wrapper="$default_wrapper"
  if [ $# -gt 0 ]; then
    # Allow the caller to separate with '--' or just provide the wrapper/args directly
    if [ "$1" = "--" ]; then
      shift
    fi
    if [ $# -gt 0 ]; then
      # Heuristic: if the first argument looks like a wrapper (existing file/executable, ends with .sh, or starts with 'docker_'),
      # treat it as the wrapper. Otherwise use the default wrapper and treat all args as wrapper_args.
      first_arg="$1"
      if [ -f "$first_arg" ] || [ -x "$first_arg" ] || [[ "$first_arg" == *.sh ]] || [[ "$first_arg" == docker_* ]]; then
        wrapper="$1"; shift || true
        wrapper_args=("$@")
      else
        wrapper_args=("$@")
      fi
    fi
  fi
else
  # Explicit wrapper provided with -w: consume optional leading '--' and treat remaining args as wrapper_args
  if [ $# -gt 0 ] && [ "$1" = "--" ]; then
    shift
  fi
  wrapper_args=("$@")
fi

# Source common helpers so the output is consistent
# shellcheck source=docker/common.sh
. "$(dirname "$0")/common.sh"

# Obtain the raw digest (second line of output). Use script-relative path so this works regardless of $PWD
if [ "$auto_yes" = 1 ]; then
  digest="$("$(dirname "$0")/get_digest.sh" -y "$image" | tail -n1)"
else
  digest="$("$(dirname "$0")/get_digest.sh" "$image" | tail -n1)"
fi

if [ -z "${digest:-}" ]; then
  echo "Failed to obtain a digest for ${image}; aborting." >&2
  exit 1
fi

# Decide which env var to set based on wrapper name
case "$(basename "$wrapper")" in
  *repro*) envvar=DOCKER_REPRO_DIGEST ;;
  *) envvar=DOCKER_LATEST_DIGEST ;;
esac

print_digest_info "${image%@*}@${digest}" "${digest}" "user" "${envvar}"
echo "Running ${wrapper} pinned to ${digest} (exporting ${envvar})" >&2

# Validate that the wrapper exists and is executable before exec'ing it
if [ -z "${wrapper:-}" ] || [ ! -x "$wrapper" ]; then
  echo "Error: wrapper '${wrapper:-<unset>}' not found or not executable." >&2
  usage
  exit 1
fi

# Exec the wrapper with the pinned digest in the environment
# Note: use env to avoid exporting the var in caller environment
env "${envvar}=${digest}" "$wrapper" "${wrapper_args[@]:-}"