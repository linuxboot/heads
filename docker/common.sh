#!/bin/bash

# Shared common Docker helpers for Heads dev scripts
# Meant to be sourced from docker_latest.sh / docker_local_dev.sh / docker_repro.sh
#
# This module provides:
#   - ensure_nix_and_flakes()      : Infrastructure setup and validation
#   - resolve_docker_image()       : Image reference resolution with digest pinning
#   - maybe_rebuild_local_image()  : Conditional Docker image rebuilding from flake
#   - kill_usb_processes()         : USB device cleanup for token passthrough
#   - build_docker_opts()          : Docker runtime options construction
#   - run_docker()                 : Container execution wrapper
#   - print_digest_info()          : User-friendly digest output
#
# Environment variables and configuration are documented in the usage() function below.

__HEADS_RESTORE_SHELL_OPTS=0
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
	__HEADS_SHELL_OPTS=$(set +o)
	__HEADS_RESTORE_SHELL_OPTS=1
fi
set -euo pipefail

# Color support: enable when stderr is a TTY and not explicitly disabled
if [ -t 2 ] && [ -z "${HEADS_NO_COLOR:-}" ]; then
	RED="$(printf '\033[31m')"
	GREEN="$(printf '\033[32m')"
	YELLOW="$(printf '\033[33m')"
	BOLD="$(printf '\033[1m')"
	RESET="$(printf '\033[0m')"
	# Reference optional colors to avoid unused-variable warnings from shellcheck
	: "${YELLOW}" "${BOLD}"
else
	RED=""
	GREEN=""
	YELLOW=""
	BOLD=""
	RESET=""
fi

# Simple print-once helper to avoid repeated messages during a run
# Usage: print_once <key> <message>
# Note: uses an associative array, requires bash
if [ -z "${__heads_printed_initialized:-}" ]; then
	declare -A __heads_printed
	__heads_printed_initialized=1
fi
print_once() {
	local key="$1"
	shift
	if [ -z "${__heads_printed[$key]:-}" ]; then
		__heads_printed[$key]=1
		printf "%s\n" "$*" >&2
	fi
}

# Ensure docker is available in PATH.
require_docker() {
	if ! command -v docker >/dev/null 2>&1; then
		echo "Error: docker not found in PATH" >&2
		return 127
	fi
	return 0
}

# Interactive prompt helper to confirm pulls. Returns 0 to proceed, 1 to abort.
prompt_for_pull() {
	local remote_image="$1"
	# Respect explicit no-pull or auto-pull flags
	if [ "${HEADS_CHECK_REPRODUCIBILITY_NO_PULL:-0}" = "1" ]; then
		echo "Auto-pull suppressed by HEADS_CHECK_REPRODUCIBILITY_NO_PULL=1; aborting reproducibility check." >&2
		return 1
	fi
	if [ "${HEADS_CHECK_REPRODUCIBILITY_AUTO_PULL:-0}" = "1" ]; then
		return 0
	fi
	# Interactive prompt
	if [ -t 0 ]; then
		printf "${BOLD}Pulling the remote image will download potentially large layers and may still result in a mismatch.${RESET} Continue and pull %s? [y/N] " "$remote_image" >&2
		local _ans
		read -r _ans
		case "${_ans:-N}" in [Yy]*) return 0 ;; *)
			echo "Skipping pull; aborting reproducibility check." >&2
			return 1
			;;
		esac
	else
		echo "Non-interactive session; set HEADS_CHECK_REPRODUCIBILITY_AUTO_PULL=1 to auto-pull or HEADS_CHECK_REPRODUCIBILITY_NO_PULL=1 to abort without pulling." >&2
		return 1
	fi
}

# ================================================================
# Configuration: Maintainer Docker image
# ================================================================
# This is the canonical maintainer's Docker image repository.
# Override by setting HEADS_MAINTAINER_DOCKER_IMAGE in your environment
# for local testing or if you maintain a fork.
# Example: export HEADS_MAINTAINER_DOCKER_IMAGE="myuser/heads-dev-env"
HEADS_MAINTAINER_DOCKER_IMAGE="${HEADS_MAINTAINER_DOCKER_IMAGE:-tlaurion/heads-dev-env}"

# For reproducibility checks, this specifies the remote image to compare against.
# If not set, defaults to ${HEADS_MAINTAINER_DOCKER_IMAGE}:latest
# Example: export HEADS_CHECK_REPRODUCIBILITY_REMOTE="tlaurion/heads-dev-env:v0.2.7"
HEADS_CHECK_REPRODUCIBILITY_REMOTE="${HEADS_CHECK_REPRODUCIBILITY_REMOTE:-}"

# Resolve the default reproducibility remote image.
# Usage: resolve_repro_remote_image [override_image]
resolve_repro_remote_image() {
	local override_image="${1:-}"
	if [ -n "${override_image}" ]; then
		echo "${override_image}"
		return 0
	fi
	if [ -n "${HEADS_CHECK_REPRODUCIBILITY_REMOTE:-}" ]; then
		echo "${HEADS_CHECK_REPRODUCIBILITY_REMOTE}"
		return 0
	fi
	local img base
	img="${HEADS_MAINTAINER_DOCKER_IMAGE:-tlaurion/heads-dev-env}"
	base="${img##*/}"
	if [[ "${base}" == *":"* || "${base}" == *"@"* ]]; then
		echo "${img}"
	else
		echo "${img}:latest"
	fi
}

# Track whether we supply Xauthority into the container
DOCKER_XAUTH_USED=0
# Track temporary Xauthority file for cleanup
DOCKER_XAUTH_FILE=""
DOCKER_XAUTH_TEMP=0

# ================================================================
# Usage and informational functions
# ================================================================

usage() {
	cat <<'USAGE'
Usage: $0 [OPTIONS] -- [COMMAND]
Options:
Environment variables (opt-ins / opt-outs):
	HEADS_MAINTAINER_DOCKER_IMAGE   Override the canonical maintainer's Docker image repository (default: tlaurion/heads-dev-env). Use for forks or local testing.
	HEADS_CHECK_REPRODUCIBILITY_REMOTE  Override the remote image for reproducibility checks (default: ${HEADS_MAINTAINER_DOCKER_IMAGE}:latest). Example: tlaurion/heads-dev-env:v0.2.7
	HEADS_DISABLE_USB=1   Disable automatic USB passthrough (default: enabled when /dev/bus/usb exists)
	HEADS_X11_XAUTH=1     Explicitly mount $HOME/.Xauthority into the container for X11 auth
	HEADS_SKIP_DOCKER_REBUILD=1  Skip automatic rebuild of the local Docker image when flake.nix/flake.lock are uncommitted
	HEADS_FORCE_DOCKER_REBUILD=1  Force rebuild from flake.nix/flake.lock regardless of git status
	HEADS_CHECK_REPRODUCIBILITY=1  Verify reproducibility by comparing local image digest with remote (uses skopeo or curl/jq and network access)
	HEADS_AUTO_INSTALL_NIX=1 Automatically install Nix (single-user) if it's missing (interactive prompt suppressed). For supply-chain safety, this helper will not auto-execute a downloaded installer unless
	HEADS_NIX_INSTALLER_SHA256 is set to the expected sha256 of the installer.
	HEADS_AUTO_ENABLE_FLAKES=1 Automatically enable flakes by writing to $HOME/.config/nix/nix.conf (if needed)
	HEADS_SKIP_DISK_CHECK=1  Skip disk-space preflight check (default: perform check and warn)
	HEADS_MIN_DISK_GB=50     Minimum disk free (GB) required on '/' or '/nix' (default: 50)
Command:
	The command to run inside the Docker container, e.g., make BOARD=BOARD_NAME
USAGE
}

# ================================================================
# Infrastructure and setup functions
# ================================================================

# Build Nix Docker image from flake.nix/flake.lock with proper error handling.
# Verify Nix environment, build image, load it into Docker.
# Usage: _build_nix_docker_image [force_rebuild]
#   force_rebuild=1  passes --rebuild to nix build, forcing re-execution of the
#                    builder even when the store output already exists (bypasses
#                    the nix store cache; 'nix store delete' alone is unreliable
#                    because /nix/var/nix/gcroots/auto/ may still hold the path).
# Returns: 0 on success, 1 on failure
_build_nix_docker_image() {
	local force_rebuild="${1:-0}"

	# Use script-relative paths for deterministic behavior regardless of $PWD
	local script_dir repo_dir out_link
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	repo_dir="$(cd "${script_dir}/.." && pwd)"
	out_link="${script_dir}/result"

	# Ensure Nix and flakes are available; prompt if needed
	ensure_nix_and_flakes || return 1

	# Verify the Nix environment works with a simple develop test
	echo "Verifying Nix environment..." >&2
	if ! (cd "${repo_dir}" && nix develop --ignore-environment --command true); then
		echo "Error: nix develop failed; see above output for diagnostics." >&2
		echo "Suggestion: ensure Nix is installed and flakes are enabled (see README.md)." >&2
		return 1
	fi

	# Build the Docker image from flake using deterministic out-link path.
	# --rebuild forces the builder to re-execute even when the store output already
	# exists, which is required for HEADS_FORCE_DOCKER_REBUILD=1.  Without it,
	# nix build is a no-op (silent re-link) when the path survives in the store via
	# /nix/var/nix/gcroots/auto/ even after the result symlink has been removed.
	local nix_rebuild_flag=""
	if [ "${force_rebuild}" = "1" ]; then
		nix_rebuild_flag="--rebuild"
	fi
	echo "Building Docker image from flake.nix..." >&2
	# shellcheck disable=SC2086
	if ! (cd "${repo_dir}" && nix build --print-build-logs ${nix_rebuild_flag} --out-link "${out_link}" .#dockerImage); then
		echo "Error: nix build .#dockerImage failed; see above output for diagnostics." >&2
		return 1
	fi

	# Load the image into Docker from the same deterministic path
	echo "Loading Docker image..." >&2
	if ! docker load -i "${out_link}"; then
		echo "Error: docker load failed." >&2
		return 1
	fi

	return 0
}

ensure_nix_and_flakes() {
	local _ans ans ans2 installer_detected_version remote_inst_sha
	local -a candidate_sha_urls=()
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
			echo "Detected available: $(df -h "$target" | awk 'NR==2{print $4}')" >&2
			if [ -t 0 ]; then
				printf "Continue despite low disk space? [y/N] " >&2
				read -r _ans
				case "${_ans:-N}" in
				[Yy]*) echo "Continuing despite low disk space." >&2 ;;
				*)
					echo "Aborting due to insufficient disk space." >&2
					return 1
					;;
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

		# Allow non-interactive automation when explicitly requested; checksum pinning still required.
		if [ "${HEADS_AUTO_INSTALL_NIX:-0}" = "1" ]; then
			echo "HEADS_AUTO_INSTALL_NIX=1: attempting automatic Nix install..." >&2
			local installer_url="https://nixos.org/nix/install"
			local tmpf
			tmpf=$(mktemp) || {
				echo "Failed to create temporary file for installer." >&2
				return 1
			}
			if [ "$downloader_cmd" = "curl -L" ]; then
				if ! curl -fsSL "$installer_url" -o "$tmpf"; then
					echo "Failed to download Nix installer." >&2
					rm -f "$tmpf"
					return 1
				fi
			else
				if ! wget -qO "$tmpf" "$installer_url"; then
					echo "Failed to download Nix installer." >&2
					rm -f "$tmpf"
					return 1
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

			# For supply-chain safety, always verify against published checksum when available.
			# First attempt to fetch the published checksum
			local published_sha=""
			local sha_url=""
			if [ -n "${HEADS_NIX_INSTALLER_VERSION:-}" ]; then
				sha_url="https://releases.nixos.org/nix/${HEADS_NIX_INSTALLER_VERSION}/install.sha256"
			fi

			if [ -n "${sha_url}" ]; then
				if command -v curl >/dev/null 2>&1; then
					published_sha=$(curl -fsSL "${sha_url}" 2>/dev/null | tr -d '[:space:]' || true)
				elif command -v wget >/dev/null 2>&1; then
					published_sha=$(wget -qO- "${sha_url}" 2>/dev/null | tr -d '[:space:]' || true)
				fi
			fi

			# If we have both published and downloaded checksums, validate they match
			if [ -n "${inst_sha:-}" ] && [ -n "${published_sha}" ]; then
				if [ "${inst_sha}" = "${published_sha}" ]; then
					echo "✓ Downloaded installer sha256 validated against published checksum." >&2

					# If HEADS_NIX_INSTALLER_SHA256 is already set, proceed with auto-install
					if [ -n "${HEADS_NIX_INSTALLER_SHA256:-}" ] && [ "${HEADS_NIX_INSTALLER_SHA256}" = "${inst_sha}" ]; then
						echo "Installer checksum matches HEADS_NIX_INSTALLER_SHA256; running installer..." >&2
						if ! sh "$tmpf" --no-daemon; then
							echo "Nix install failed." >&2
							rm -f "$tmpf"
							return 1
						fi
						rm -f "$tmpf"
						export PATH="$HOME/.nix-profile/bin:$PATH" || true
						hash -r 2>/dev/null || true
					else
						# HEADS_NIX_INSTALLER_SHA256 not set, but we've validated the installer. Suggest setting it and re-running.
						echo "" >&2
						echo "Installer validated. To enable automatic installation, re-run:" >&2
						_suggest_nix_installer_rerun "${inst_sha}"
						echo "" >&2
						echo "Or verify manually and run: sh $tmpf --no-daemon" >&2
						rm -f "$tmpf"
						return 1
					fi
				else
					echo "Error: Downloaded installer checksum does not match published checksum!" >&2
					echo "Downloaded: ${inst_sha}" >&2
					echo "Published:  ${published_sha}" >&2
					echo "URL: ${sha_url}" >&2
					rm -f "$tmpf"
					return 1
				fi
			elif [ -n "${inst_sha:-}" ] && [ -n "${HEADS_NIX_INSTALLER_SHA256:-}" ]; then
				# We have HEADS_NIX_INSTALLER_SHA256 set but no published checksum to validate against
				if [ "${HEADS_NIX_INSTALLER_SHA256}" = "${inst_sha}" ]; then
					echo "Installer checksum matches HEADS_NIX_INSTALLER_SHA256; running installer..." >&2
					if ! sh "$tmpf" --no-daemon; then
						echo "Nix install failed." >&2
						rm -f "$tmpf"
						return 1
					fi
					rm -f "$tmpf"
					export PATH="$HOME/.nix-profile/bin:$PATH" || true
					hash -r 2>/dev/null || true
				else
					echo "Error: Downloaded installer checksum does not match HEADS_NIX_INSTALLER_SHA256." >&2
					echo "Downloaded: ${inst_sha}" >&2
					echo "Expected:   ${HEADS_NIX_INSTALLER_SHA256}" >&2
					rm -f "$tmpf"
					return 1
				fi
			else
				# Unable to validate; ask user to verify manually
				echo "For supply-chain safety, this helper will not execute the installer without verification." >&2
				echo "" >&2
				if [ -n "${inst_sha:-}" ]; then
					echo "Downloaded installer sha256: ${inst_sha}" >&2
				fi
				if [ -n "${sha_url}" ]; then
					echo "You can verify it at: ${sha_url}" >&2
					echo "" >&2
					if [ -n "${inst_sha:-}" ]; then
						echo "Verification passed? Re-run with:" >&2
						_suggest_nix_installer_rerun "${inst_sha}"
					fi
				else
					echo "Published checksum unavailable; verify the installer before running it." >&2
				fi
				echo "" >&2
				echo "Or run manually when ready: sh $tmpf --no-daemon" >&2
				rm -f "$tmpf"
				return 1
			fi
		elif [ -t 0 ]; then
			echo "Note: building the Docker image and populating /nix may require ${HEADS_MIN_DISK_GB:-50}GB+ free on '/' or '/nix'." >&2
			printf "Install Nix now and enable flakes (required) [Y/n]? " >&2
			read -r ans
			case "${ans:-Y}" in
			[Yy]*)
				# Determine installer URL. If HEADS_NIX_INSTALLER_VERSION is set, use a pinned release URL
				# (e.g. https://releases.nixos.org/nix/nix-2.33.2/install and its .sha256). Otherwise fall back to the
				# canonical script at https://nixos.org/nix/install. Users may also set HEADS_NIX_INSTALLER_URL to override.
				local installer_url
				local sha_url
				if [ -n "${HEADS_NIX_INSTALLER_VERSION:-}" ]; then
					installer_url="https://releases.nixos.org/nix/${HEADS_NIX_INSTALLER_VERSION}/install"
					sha_url="${installer_url}.sha256"
				elif [ -n "${HEADS_NIX_INSTALLER_URL:-}" ]; then
					installer_url="${HEADS_NIX_INSTALLER_URL}"
					sha_url=""
				else
					installer_url="https://nixos.org/nix/install"
					sha_url=""
				fi

				local tmpf
				tmpf=$(mktemp) || {
					echo "Failed to create temporary file for installer." >&2
					return 1
				}
				if [ "$downloader_cmd" = "curl -L" ]; then
					if ! curl -fsSL "$installer_url" -o "$tmpf"; then
						echo "Failed to download Nix installer from $installer_url." >&2
						rm -f "$tmpf"
						return 1
					fi
				else
					if ! wget -qO "$tmpf" "$installer_url"; then
						echo "Failed to download Nix installer from $installer_url." >&2
						rm -f "$tmpf"
						return 1
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

				# Show the installer URL and attempt to detect a version string from the installer contents.
				echo "Installer URL: ${installer_url}" >&2
				installer_detected_version=$(sed -n '1,200p' "$tmpf" | tr -d '\r' | grep -oE 'nix-[0-9]+(\.[0-9]+)*' | head -n1 || true)
				if [ -n "${installer_detected_version}" ]; then
					echo "Detected installer version (heuristic): ${installer_detected_version}" >&2
				fi

				# If we can derive a .sha256 URL (releases.nixos.org), try to fetch it and show it to the user so they
				# can verify the downloaded installer. Do not treat failure to fetch the .sha256 as fatal; it's advisory.
				remote_inst_sha=""
				# Prefer explicit sha_url (set via HEADS_NIX_INSTALLER_VERSION or HEADS_NIX_INSTALLER_URL override)
				candidate_sha_urls=()
				if [ -n "${sha_url:-}" ]; then
					candidate_sha_urls+=("${sha_url}")
				fi
				# If we heuristically detected a version, suggest the canonical releases URL
				if [ -n "${installer_detected_version}" ]; then
					candidate_sha_urls+=("https://releases.nixos.org/nix/${installer_detected_version}/install.sha256")
				fi

				for candidate in "${candidate_sha_urls[@]:-}"; do
					echo "Attempting to fetch published sha256 from: ${candidate}" >&2
					if command -v curl >/dev/null 2>&1; then
						remote_inst_sha=$(curl -fsSL "${candidate}" 2>/dev/null | tr -d '[:space:]' || true)
					elif command -v wget >/dev/null 2>&1; then
						remote_inst_sha=$(wget -qO- "${candidate}" 2>/dev/null | tr -d '[:space:]' || true)
					else
						remote_inst_sha=""
					fi
					if [ -n "${remote_inst_sha:-}" ]; then
						echo "Published sha256 (from ${candidate}): ${remote_inst_sha}" >&2
						if [ -n "$inst_sha" ] && [ "$inst_sha" = "$remote_inst_sha" ]; then
							echo "Published sha256 matches downloaded installer." >&2
						else
							echo "Warning: published sha256 does NOT match downloaded installer; do not run automatically." >&2
						fi
						break
					fi
				done

				if [ -z "${remote_inst_sha:-}" ] && [ ${#candidate_sha_urls[@]} -gt 0 ]; then
					echo "Note: could not fetch published sha256 from any of the suggested locations." >&2
				fi
				# For supply-chain safety, require a pinned installer hash to auto-execute; otherwise instruct user to run manually.
				if [ -n "${inst_sha:-}" ] && [ -n "${HEADS_NIX_INSTALLER_SHA256:-}" ]; then
					# Check if HEADS_NIX_INSTALLER_SHA256 matches the published checksum (if available)
					local checksum_valid=false
					if [ -n "${remote_inst_sha:-}" ] && [ "${HEADS_NIX_INSTALLER_SHA256}" = "${remote_inst_sha}" ] && [ "${HEADS_NIX_INSTALLER_SHA256}" = "${inst_sha}" ]; then
						checksum_valid=true
						echo "Installer checksum matches HEADS_NIX_INSTALLER_SHA256 and published checksum; running installer..." >&2
					elif [ -n "${remote_inst_sha:-}" ] && [ "${HEADS_NIX_INSTALLER_SHA256}" != "${remote_inst_sha}" ]; then
						echo "Error: HEADS_NIX_INSTALLER_SHA256 does not match published checksum" >&2
						echo "Published checksum: ${remote_inst_sha}" >&2
						echo "HEADS_NIX_INSTALLER_SHA256: ${HEADS_NIX_INSTALLER_SHA256}" >&2
					else
						# Require published checksum verification for security - no fallback allowed
						echo "Error: Cannot verify installer against published checksum for automatic execution." >&2
						echo "Published checksum could not be fetched or does not match HEADS_NIX_INSTALLER_SHA256." >&2
						if [ -z "${remote_inst_sha:-}" ]; then
							echo "No published checksum available from any source." >&2
						fi
					fi

					if [ "$checksum_valid" = true ]; then
						if ! sh "$tmpf" --no-daemon; then
							echo "Nix install failed." >&2
							rm -f "$tmpf"
							return 1
						fi
						rm -f "$tmpf"
						export PATH="$HOME/.nix-profile/bin:$PATH" || true
						hash -r 2>/dev/null || true
					else
						echo "For supply-chain safety this helper will not execute a downloaded installer automatically." >&2
						echo "Installer saved to: $tmpf" >&2
						echo "Installer sha256: ${inst_sha}" >&2
						echo "" >&2
						echo "To complete Nix installation, verify the installer and re-run:" >&2
						_suggest_nix_installer_rerun "${inst_sha}"
						echo "" >&2
						echo "Or run manually when ready: sh $tmpf --no-daemon" >&2
						rm -f "$tmpf"
						return 1
					fi
				else
					echo "For supply-chain safety this helper will not execute a downloaded installer automatically." >&2
					echo "Installer saved to: $tmpf" >&2
					if [ -n "${inst_sha:-}" ]; then
						echo "Installer sha256: ${inst_sha}" >&2
						echo "" >&2
						echo "To complete Nix installation, verify the installer and re-run:" >&2
						_suggest_nix_installer_rerun "${inst_sha}"
					else
						echo "sha256 unavailable; verify the downloaded installer before running it." >&2
					fi
					echo "" >&2
					echo "Or run manually when ready: sh $tmpf --no-daemon" >&2
					rm -f "$tmpf"
					return 1
				fi
				;;
			*)
				echo "Flakes are required; aborting." >&2
				return 1
				;;
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
			echo "experimental-features = nix-command flakes" >>"$HOME/.config/nix/nix.conf" || true
		elif [ -t 0 ]; then
			printf "Flakes are required but not enabled. Add 'experimental-features = nix-command flakes' to %s now [Y/n]? " "$HOME/.config/nix/nix.conf" >&2
			read -r ans2
			case "${ans2:-Y}" in
			[Yy]*)
				echo "experimental-features = nix-command flakes" >>"$HOME/.config/nix/nix.conf" || true
				echo "Wrote experimental features to $HOME/.config/nix/nix.conf" >&2
				;;
			*)
				echo "Flakes are required; aborting. Please enable flakes manually and rerun the script." >&2
				return 1
				;;
			esac
		else
			echo "Flakes are required but not enabled in non-interactive shell. Please enable them and rerun the script (see README.md)." >&2
			return 1
		fi
	fi
}

# Build and suggest a re-run command with pinned installer hash and preserved environment variables
# Usage: _suggest_nix_installer_rerun <installer_sha>
_suggest_nix_installer_rerun() {
	local inst_sha="$1"
	local rerun_cmd="HEADS_NIX_INSTALLER_SHA256=${inst_sha} HEADS_AUTO_INSTALL_NIX=1"

	if [ -n "${HEADS_MAINTAINER_DOCKER_IMAGE:-}" ]; then
		rerun_cmd="$rerun_cmd HEADS_MAINTAINER_DOCKER_IMAGE='${HEADS_MAINTAINER_DOCKER_IMAGE}'"
	fi
	if [ -n "${HEADS_CHECK_REPRODUCIBILITY_REMOTE:-}" ]; then
		rerun_cmd="$rerun_cmd HEADS_CHECK_REPRODUCIBILITY_REMOTE='${HEADS_CHECK_REPRODUCIBILITY_REMOTE}'"
	fi
	if [ "${HEADS_CHECK_REPRODUCIBILITY:-0}" = "1" ]; then
		rerun_cmd="$rerun_cmd HEADS_CHECK_REPRODUCIBILITY=1"
	fi
	rerun_cmd="$rerun_cmd $0"

	echo "  $rerun_cmd" >&2
}

# ================================================================
# USB device management functions
# ================================================================

# Kill scdaemon/pcscd when USB passthrough is present (minimal, automatic). Only targets processes that are actually using USB device nodes.
kill_usb_processes() {
	[ -d /dev/bus/usb ] || return 0
	[ "${HEADS_DISABLE_USB:-0}" = "1" ] && {
		echo "HEADS_DISABLE_USB=1: skipping USB cleanup" >&2
		return 0
	}

	# Use lsof to find processes holding /dev/bus/usb nodes, then filter for scdaemon/pcscd
	local pids

	# Choose how to run lsof: prefer direct invocation as root, else use sudo if available without prompting.
	local lsof_cmd=""
	if [ "$(id -u)" = "0" ]; then
		lsof_cmd="lsof"
	elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
		lsof_cmd="sudo lsof"
	elif command -v sudo >/dev/null 2>&1 && [ -t 1 ]; then
		# Interactive shell with sudo available: attempt it (will prompt for password)
		echo "Attempting to check USB device usage; sudo access required:" >&2
		lsof_cmd="sudo lsof"
	elif command -v sudo >/dev/null 2>&1; then
		# Non-interactive shell and sudo would prompt: skip cleanup
		echo "sudo requires a password; skipping automatic USB cleanup in this context" >&2
		return 0
	elif command -v lsof >/dev/null 2>&1; then
		# No sudo, but lsof present; attempt to run it (may fail if insufficient permissions)
		lsof_cmd="lsof"
	else
		echo "lsof not available; cannot detect processes holding USB devices; skipping cleanup" >&2
		return 0
	fi

	# Match all bus/device nodes to avoid missing higher-numbered buses (no assumption about leading zeros).
	# Use lsof -t to obtain PIDs only, then filter those PIDs for the commands we care about so we
	# only attempt to kill numeric PIDs (avoid passing ps headers or other text to kill).
	local raw_pids
	raw_pids=$($lsof_cmd -t /dev/bus/usb/*/* 2>/dev/null || true)
	if [ -z "${raw_pids}" ]; then
		[ "${HEADS_USB_VERBOSE:-0}" = "1" ] && echo "No processes holding /dev/bus/usb nodes." >&2
		return 0
	fi

	local -a matched_pids=()
	for _pid in ${raw_pids}; do
		# Ensure _pid is numeric
		case "${_pid}" in
		'' | *[!0-9]*) continue ;;
		*)
			# Get command name and match exactly 'scdaemon' or 'pcscd'
			local cmd
			cmd=$(ps -p "${_pid}" -o comm= 2>/dev/null || true)
			if printf '%s' "${cmd}" | grep -qE '^scdaemon$|^pcscd$'; then
				matched_pids+=("${_pid}")
			fi
			;;
		esac
	done

	if [ ${#matched_pids[@]} -eq 0 ]; then
		[ "${HEADS_USB_VERBOSE:-0}" = "1" ] && echo "No scdaemon/pcscd processes using USB devices." >&2
		return 0
	fi

	# Join the PIDs into a space-separated string for messaging and kill commands
	pids="${matched_pids[*]}"
	echo "Detected scdaemon/pcscd processes using USB devices: ${pids}" >&2
	echo "WARNING: About to kill the above processes to free USB devices for passthrough. To skip this automatic action set HEADS_DISABLE_USB=1 in your environment." >&2
	if [ -t 1 ]; then
		echo "Press Ctrl-C to abort within 3 seconds if you do NOT want these processes killed." >&2
		sleep 3
	fi

	# Try to kill: prefer running as root, else try sudo without prompting in non-interactive shells
	# Convert the whitespace-separated PID list into an array for safe expansion
	read -r -a pids_array <<<"${pids}"

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
			echo "Attempting to free USB devices for Docker passthrough; sudo access required:" >&2
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
# Force rebuild by setting HEADS_FORCE_DOCKER_REBUILD=1.
maybe_rebuild_local_image() {
	local image="$1"

	# Use script-relative path for deterministic behavior regardless of $PWD
	local script_dir repo_dir result_symlink
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	repo_dir="$(cd "${script_dir}/.." && pwd)"
	result_symlink="${script_dir}/result"

	if [ "${HEADS_FORCE_DOCKER_REBUILD:-0}" = "1" ]; then
		echo "HEADS_FORCE_DOCKER_REBUILD=1: forcing Docker rebuild from flake" >&2
		# Delete cached nix result to force rebuild using script-relative path
		if [ -L "${result_symlink}" ]; then
			local result_target
			result_target=$(readlink -f "${result_symlink}" 2>/dev/null || echo "${result_symlink}")
			# Always remove the symlink, even if dangling
			rm -f "${result_symlink}"
			if [ -n "$result_target" ] && [ -e "$result_target" ]; then
				# Only delete from nix store if it's actually a valid store path
				if [[ "$result_target" == /nix/store/* ]]; then
					echo "Deleting cached nix result: $result_target" >&2
					if command -v nix >/dev/null 2>&1; then
						if ! nix store delete "$result_target" 2>/dev/null; then
							echo "Warning: failed to delete nix store path, may be reused" >&2
						fi
					else
						echo "Warning: nix not available, store path may be reused" >&2
					fi
				else
					echo "Deleting cached nix result symlink: $result_target" >&2
				fi
			fi
		elif [ -e "${result_symlink}" ]; then
			echo "Deleting cached nix result file: ${result_symlink}" >&2
			rm -f "${result_symlink}"
		fi
	elif [ "${HEADS_SKIP_DOCKER_REBUILD:-0}" = "1" ]; then
		echo "HEADS_SKIP_DOCKER_REBUILD=1: skipping Docker rebuild" >&2
		return 0
	fi

	local force_rebuild=0
	force_rebuild=$([ "${HEADS_FORCE_DOCKER_REBUILD:-0}" = "1" ] && echo 1 || echo 0)

	# Check if flake.nix or flake.lock have uncommitted changes
	if [ "$force_rebuild" -eq 0 ] && git -C "${repo_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -n "$(git -C "${repo_dir}" status --porcelain | grep -E 'flake\.nix|flake\.lock' || true)" ]; then
		# There are uncommitted changes in flake files
		echo "**Warning: Uncommitted changes detected in flake.nix or flake.lock. The Docker image will be rebuilt!**" >&2
		echo "If this was not intended, please CTRL-C now, commit your changes and rerun the script." >&2
	elif [ "$force_rebuild" -eq 0 ]; then
		# Check if exact image reference exists locally
		if docker image inspect "${image}" >/dev/null 2>&1; then
			echo "Git repository is clean. Using existing Docker image." >&2
			return 0
		fi

		# Image doesn't exist; try to load from build result using script-relative path
		if [ -L "${result_symlink}" ] && [ -e "${result_symlink}" ]; then
			# Show where the 'result' symlink points and its size to give the user clear feedback
			local result_target
			result_target=$(readlink -f "${result_symlink}" 2>/dev/null || echo "${result_symlink}")
			local result_size=""
			if [ -f "${result_target}" ]; then
				result_size=$(stat -c '%s' "${result_target}" 2>/dev/null || echo "")
			fi
			echo "Git repository is clean but Docker image not found locally; loading existing build result..." >&2
			printf "  Loading from: %s%s\n" "${result_target}" "${result_size:+ (size: ${result_size} bytes)}" >&2
			echo "  This may take a few minutes depending on image size and disk I/O. Showing 'docker load' output below:" >&2

			# If 'result' is a symlink, mention it explicitly (show this before running docker load)
			if [ -L "${result_symlink}" ]; then
				printf "  Note: 'result' is a symlink to: %s\n" "${result_target}" >&2
			fi

			echo "  Running: docker load -i ${result_target}" >&2
			# Run 'docker load -i' directly so its output is printed live to the console in both
			# interactive and non-interactive contexts.
			if docker load -i "${result_target}"; then
				echo "  docker load completed successfully" >&2
			else
				echo "  docker load failed (see output above)" >&2
				return 1
			fi

			# Attempt to show the loaded image summary (best-effort for the requested image name)
			local found
			found=$(docker images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' | grep -E "^${image%%:*}" | head -n1 || true)
			if [ -n "${found}" ]; then
				printf "  Found image: %s\n" "${found}" >&2
			else
				echo "  Note: could not find a matching repo tag in 'docker images'; run 'docker images' to inspect available images." >&2
			fi

			return 0
		fi

		# No image and no build result; need to build
		echo "Git repository is clean but Docker image '${image}' not found locally. Building from flake.nix..." >&2
	fi

	# Build the Docker image using the helper function
	_build_nix_docker_image "${force_rebuild}" || return 1

	return 0
}

# ================================================================
# Image resolution and validation functions
# ================================================================

# Resolve Docker image preferring a pinned digest from the environment or a repository file.
# Usage: resolve_docker_image <fallback_image> <digest_env_varname> <digest_filename> [prompt_on_latest]
# - <fallback_image>: e.g. ${HEADS_MAINTAINER_DOCKER_IMAGE}:vX.Y.Z or ${HEADS_MAINTAINER_DOCKER_IMAGE}:latest
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
			digest_value=$(sed -n 's/#.*//; /^[[:space:]]*$/d; p' "${digest_file}" | head -n1 || true)
			digest_source="file ${repo_dir}/docker/${digest_filename}"
		fi

		# Special-case: if we're resolving the LATEST digest and none is provided, fall
		# back to the REPRO digest (env var first, then repository file) since the
		# latest convenience image normally mirrors the repro image in practice.
		if [ -z "${digest_value}" ] && [ "${digest_env_varname}" = "DOCKER_LATEST_DIGEST" ]; then
			local allow_latest_fallback=0
			local fallback_repo
			fallback_repo="${fallback_image%%@*}"
			local _fallback_last="${fallback_repo##*/}"
			if [[ "${_fallback_last}" == *:* ]]; then
				fallback_repo="${fallback_repo%:*}"
			fi

			if [ "${fallback_repo}" = "${HEADS_MAINTAINER_DOCKER_IMAGE}" ]; then
				allow_latest_fallback=1
			fi

			if [ -n "${DOCKER_REPRO_DIGEST:-}" ] && [[ "${DOCKER_REPRO_DIGEST}" == *@* ]]; then
				local repro_repo="${DOCKER_REPRO_DIGEST%@*}"
				if [ "${repro_repo}" != "${fallback_repo}" ]; then
					allow_latest_fallback=0
					echo "Note: DOCKER_REPRO_DIGEST points to '${repro_repo}', not '${fallback_repo}'; not using it for latest image." >&2
				fi
			fi

			if [ "${allow_latest_fallback}" -eq 1 ]; then
				if [ -n "${DOCKER_REPRO_DIGEST:-}" ]; then
					digest_value="${DOCKER_REPRO_DIGEST}"
					digest_source="env DOCKER_REPRO_DIGEST"
				else
					local repro_file="$repo_dir/docker/DOCKER_REPRO_DIGEST"
					if [ -f "${repro_file}" ]; then
						digest_value=$(sed -n 's/#.*//; /^[[:space:]]*$/d; p' "${repro_file}" | head -n1 || true)
						digest_source="file ${repo_dir}/docker/DOCKER_REPRO_DIGEST"
					fi
				fi
				if [ -n "${digest_value}" ]; then
					echo "Note: no DOCKER_LATEST_DIGEST set; using DOCKER_REPRO_DIGEST as fallback for latest image." >&2
					echo "To change which image 'latest' points to, either:" >&2
					echo "  - Export a digest for convenience: export DOCKER_LATEST_DIGEST=sha256:<hex>" >&2
					echo "    (get a digest with: ./docker/get_digest.sh tlaurion/heads-dev-env:vX.Y.Z | tail -n1)" >&2
					echo "  - Or update the canonical file: edit 'docker/DOCKER_REPRO_DIGEST' in this repo to a preferred digest and commit it." >&2
					echo "  - For one-off runs use the pin-and-run helper: ./docker/pin-and-run.sh <repo:tag> -- ./docker_latest.sh <command>" >&2
				fi
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
			# Final validation: ensure trailing digest is exactly in the expected format after normalization
			if [[ ! "$trailing" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
				echo "Error: Invalid digest format '${trailing}' in '${digest_value}'; expected sha256:<64 hex characters>" >&2
				return 1
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

		# Final validation: ensure digest_value is exactly in the expected format after normalization
		if [[ ! "${digest_value}" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
			echo "Error: Invalid digest format '${digest_value}'; expected sha256:<64 hex characters>" >&2
			return 1
		fi

		# Strip any existing digest and, if present, a tag after the last '/' from fallback_image
		# to get the repository name. This preserves registry prefixes like 'registry.example.com:5000/'
		local image_repo
		# First, drop any '@digest' suffix from the fallback image
		image_repo="${fallback_image%%@*}"
		# Then, if the last path component contains a ':', treat that as a tag and strip it
		local _last_component="${image_repo##*/}"
		if [[ "${_last_component}" == *:* ]]; then
			image_repo="${image_repo%:*}"
		fi
		print_digest_info "${image_repo}@${digest_value}" "${digest_value}" "${digest_source}" "${digest_env_varname}"
		echo "${image_repo}@${digest_value}"
		return 0
	fi

	# No digest available; handle prompts for unpinned :latest if requested
	if [[ "${fallback_image}" == *":latest" && "${HEADS_ALLOW_UNPINNED_LATEST:-0}" != "1" && "${prompt_on_latest}" = "1" ]]; then
		if [ -t 0 ]; then
			printf "The configured image '%s' is unpinned (':latest'). Proceed despite supply-chain risk? [y/N] " "${fallback_image}" >&2
			read -r _ans
			case "${_ans:-N}" in
			[Yy]*) echo "Proceeding with unpinned image." >&2 ;;
			*)
				printf "Aborting: set %s to pin an immutable image or set HEADS_ALLOW_UNPINNED_LATEST=1 to bypass this prompt.\n" "${digest_env_varname}" >&2
				return 1
				;;
			esac
		else
			echo "Refusing to use unpinned ':latest' in non-interactive mode without HEADS_ALLOW_UNPINNED_LATEST=1; aborting." >&2
			return 1
		fi
	fi

	# No digest and no prompting required; return the fallback image as-is
	echo "${fallback_image}"
}

# ================================================================
# Utility functions
# ================================================================

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

# ================================================================
# Docker execution and configuration functions
# ================================================================

# Build docker options (returns single string on stdout)
build_docker_opts() {
	local opts=(-e "DISPLAY=${DISPLAY:-}" --network host --rm -ti)

	# USB passthrough
	if [ -d "/dev/bus/usb" ] && [ "${HEADS_DISABLE_USB:-0}" != "1" ]; then
		opts+=(--device=/dev/bus/usb:/dev/bus/usb)
		echo "--->USB passthrough enabled; to disable set HEADS_DISABLE_USB=1" >&2
	elif [ -d "/dev/bus/usb" ]; then
		echo "--->Host USB present; USB passthrough disabled by HEADS_DISABLE_USB=1" >&2
	fi

	# KVM passthrough
	if [ -e /dev/kvm ]; then
		opts+=(--device=/dev/kvm:/dev/kvm)
		echo "--->Host KVM device found; enabling /dev/kvm passthrough" >&2
	elif [ -e /proc/kvm ]; then
		echo "--->Host reports KVM available but /dev/kvm is missing; load kvm module" >&2
	fi

	# X11 forwarding: mount socket and try programmatic Xauthority when possible
	if [ -d "/tmp/.X11-unix" ]; then
		opts+=(-v /tmp/.X11-unix:/tmp/.X11-unix)

		# If the user explicitly requests to use their $HOME/.Xauthority, honor that and bypass programmatic cookie logic.
		if [ "${HEADS_X11_XAUTH:-0}" != "0" ]; then
			if [ -f "${HOME}/.Xauthority" ]; then
				DOCKER_XAUTH_USED=1
				opts+=(-v "${HOME}/.Xauthority:/root/.Xauthority:ro" -e "XAUTHORITY=/root/.Xauthority")
				echo "--->HEADS_X11_XAUTH set: mounting ${HOME}/.Xauthority into container and bypassing programmatic Xauthority" >&2
			else
				echo "--->HEADS_X11_XAUTH set but ${HOME}/.Xauthority not found; not attempting programmatic Xauthority; GUI may fail" >&2
			fi
		elif command -v xauth >/dev/null 2>&1; then
			local XAUTH_HOST
			XAUTH_HOST=""
			if command -v mktemp >/dev/null 2>&1; then
				XAUTH_HOST=$(mktemp -t heads-docker-xauth-XXXXXX 2>/dev/null || true)
			fi
			if [ -z "${XAUTH_HOST}" ]; then
				XAUTH_HOST="/tmp/.docker.xauth-$(id -u)"
				DOCKER_XAUTH_TEMP=0
				DOCKER_XAUTH_FILE=""
			else
				DOCKER_XAUTH_TEMP=1
				DOCKER_XAUTH_FILE="$XAUTH_HOST"
			fi
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
				opts+=(-v "$XAUTH_HOST:$XAUTH_HOST:ro" -e "XAUTHORITY=$XAUTH_HOST")
				echo "--->Using programmatic Xauthority $XAUTH_HOST for X11 auth" >&2
			elif [ -f "${HOME}/.Xauthority" ]; then
				DOCKER_XAUTH_USED=1
				opts+=(-v "${HOME}/.Xauthority:/root/.Xauthority:ro" -e "XAUTHORITY=/root/.Xauthority")
				echo "--->Falling back to mounting ${HOME}/.Xauthority into container" >&2
			else
				echo "--->X11 socket present but no Xauthority found; GUI may fail" >&2
			fi
		else
			if [ -f "${HOME}/.Xauthority" ]; then
				opts+=(-v "${HOME}/.Xauthority:/root/.Xauthority:ro" -e "XAUTHORITY=/root/.Xauthority")
				echo "--->Mounting ${HOME}/.Xauthority into container for X11 auth (xauth missing)" >&2
			fi
		fi
	elif [ "${HEADS_X11_XAUTH:-0}" != "0" ] && [ -f "${HOME}/.Xauthority" ]; then
		opts+=(-v "${HOME}/.Xauthority:/root/.Xauthority:ro" -e "XAUTHORITY=/root/.Xauthority")
		echo "--->HEADS_X11_XAUTH=1: mounting ${HOME}/.Xauthority into container" >&2
	fi

	# If host xhost does not list LOCAL, warn the user about enabling access only when
	# we did NOT supply an Xauthority cookie. We do NOT modify xhost automatically (security).
	if [ "${DOCKER_XAUTH_USED:-0}" = "0" ] && command -v xhost >/dev/null 2>&1 && ! xhost | grep -q "LOCAL:"; then
		echo "--->X11 auth may be strict; no automatic 'xhost' changes are performed. Provide Xauthority (install xauth) or run 'xhost +SI:localuser:root' manually if you accept the security risk." >&2
	fi

	# Output each option on its own line so callers can safely populate an array
	for o in "${opts[@]}"; do
		printf '%s\n' "$o"
	done
}

# Compare local image digest with remote (docker.io) digest
# Usage: compare_image_reproducibility <local_image_ref> [remote_image_ref]
# Prints comparison info and returns 0 if digests match, 1 if different
# Default remote image uses HEADS_CHECK_REPRODUCIBILITY_REMOTE or ${HEADS_MAINTAINER_DOCKER_IMAGE}:latest
# Helper: fetch remote image's config digest (which corresponds to image ID) without pulling.
# Tries 'skopeo' first, then a lightweight Docker Registry v2 manifest fetch using curl and token auth.
# Output: single line as "<digest>\t<method>".
# Returns 0 on success, else non-zero.
get_remote_config_digest() {
	local remote_image="$1"
	local digest=""
	local method="unknown"

	# 1) Prefer skopeo (simplest, handles auth automatically)
	if command -v skopeo >/dev/null 2>&1; then
		local skopeo_output
		# Run skopeo and capture output for debugging if needed
		if skopeo_output=$(skopeo inspect "docker://${remote_image}" 2>&1); then
			# skopeo succeeded; extract config digest
			if command -v jq >/dev/null 2>&1; then
				digest=$(printf '%s' "${skopeo_output}" | jq -r '.config.digest // empty' 2>/dev/null || true)
				if [ -n "${digest}" ]; then
					method="skopeo+jq"

				fi
			else
				digest=$(printf '%s' "${skopeo_output}" | tr -d '\n' | sed -nE 's/.*"config"[^}]*"digest"[[:space:]]*:[[:space:]]*"([^" ]+)".*/\1/p' || true)
				if [ -n "${digest}" ]; then
					method="skopeo+sed"

				fi
			fi
		else
			true # Silent fallback to registry API if skopeo fails
		fi
		if [ -n "${digest}" ]; then
			printf '%s\t%s\n' "${digest}" "${method}"
			return 0
		fi
	fi

	# 2) Lightweight registry API fetch (best-effort, avoids jq dependency)
	# Skip this method if remote_image is a digest reference (contains @)
	if [[ "${remote_image}" == *"@"* ]]; then
		return 1
	fi
	# Check curl is available before attempting registry API
	if ! command -v curl >/dev/null 2>&1; then
		return 1
	fi

	# Parse host, repo, tag using shared helper
	local parse_result
	parse_result=$(_parse_docker_image "${remote_image}") || return 1
	local host repo tag
	read -r host repo tag <<EOF
${parse_result}
EOF

	# Only use Docker Hub auth for Docker Hub registries
	if [ "${host}" != "registry-1.docker.io" ]; then
		return 1
	fi

	# Get auth token (Docker Hub auth endpoint). Ignore failures silently.
	local auth_url token manifest
	auth_url="https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull"
	if command -v jq >/dev/null 2>&1; then
		token=$(curl -fsSL "${auth_url}" 2>/dev/null | jq -r '.token // empty' 2>/dev/null || true)
	else
		token=$(curl -fsSL "${auth_url}" 2>/dev/null | tr -d '\n' | sed -nE 's/.*"token"[[:space:]]*:[[:space:]]*"([^\"]+)".*/\1/p' || true)
	fi
	if [ -n "${token}" ]; then
		if command -v jq >/dev/null 2>&1; then
			manifest=$(curl -fsSL -H "Accept: application/vnd.docker.distribution.manifest.v2+json" -H "Authorization: Bearer ${token}" "https://${host}/v2/${repo}/manifests/${tag}" 2>/dev/null || true)
			digest=$(printf '%s' "${manifest}" | jq -r '.config.digest // empty' 2>/dev/null || true)
			method="registry+jq"

		else
			manifest=$(curl -fsSL -H "Accept: application/vnd.docker.distribution.manifest.v2+json" -H "Authorization: Bearer ${token}" "https://${host}/v2/${repo}/manifests/${tag}" 2>/dev/null | tr -d '\n' || true)
			digest=$(printf '%s' "${manifest}" | sed -nE 's/.*"config"[^}]*"digest"[[:space:]]*:[[:space:]]*"([^" ]+)".*/\1/p' || true)
			method="registry+sed"

		fi
		if [ -n "${digest}" ]; then
			printf '%s\t%s\n' "${digest}" "${method}"
			return 0
		fi
	fi

	return 1
}

# Parse Docker image reference into host, repo, and tag components
# Usage: _parse_docker_image <image_ref>
# Output: host repo tag (space-separated)
# Returns 0 on success, non-zero on failure (e.g., digest-only references)
_parse_docker_image() {
	local remote_image="$1"
	local host repo tag repo_with_tag last_component had_digest

	repo_with_tag="${remote_image}"
	had_digest=0
	if [ "${repo_with_tag}" != "${repo_with_tag%@*}" ]; then
		had_digest=1
		repo_with_tag="${repo_with_tag%@*}"
	fi

	last_component="${repo_with_tag##*/}"
	if [ "${last_component}" != "${last_component##*:}" ]; then
		tag="${repo_with_tag##*:}"
		repo="${repo_with_tag%:*}"
	else
		if [ "${had_digest}" -eq 1 ]; then
			return 1
		fi
		tag="latest"
		repo="${repo_with_tag}"
	fi

	local first
	first="${repo%%/*}"
	if echo "${first}" | grep -qE '\.|:|localhost'; then
		host="${first}"
		repo="${repo#*/}"
	else
		host="registry-1.docker.io"
	fi

	if [ "${host}" = "docker.io" ] || [ "${host}" = "index.docker.io" ]; then
		host="registry-1.docker.io"
	fi

	if [ "${host}" = "registry-1.docker.io" ] && ! echo "${repo}" | grep -q '/'; then
		repo="library/${repo}"
	fi

	printf '%s\n' "${host} ${repo} ${tag}"
}

# Get remote image manifest digest (what Docker Hub shows in URL)
# Usage: get_remote_manifest_digest <remote_image>
# Returns: manifest digest on stdout (empty on failure)
# Only works for Docker Hub images (not other registries)
get_remote_manifest_digest() {
	local remote_image="$1"

	# Parse host, repo, tag using shared helper
	local parse_result
	parse_result=$(_parse_docker_image "${remote_image}") || return 1
	local host repo tag
	read -r host repo tag <<EOF
${parse_result}
EOF

	# Only fetch manifest for Docker Hub images
	if [ "${host}" != "registry-1.docker.io" ]; then
		return 1
	fi

	# Check curl is available
	if ! command -v curl >/dev/null 2>&1; then
		return 1
	fi

	# Get auth token
	local auth_url token manifest_headers manifest_digest
	auth_url="https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull"
	if command -v jq >/dev/null 2>&1; then
		token=$(curl -fsSL "${auth_url}" 2>/dev/null | jq -r '.token // empty' 2>/dev/null || true)
	else
		token=$(curl -fsSL "${auth_url}" 2>/dev/null | tr -d '\n' | sed -nE 's/.*"token"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' || true)
	fi

	if [ -n "${token}" ]; then
		# Get manifest headers and capture the Docker-Content-Digest header without reading the body into memory
		manifest_headers=$(curl -fsSL -D - -o /dev/null -H "Accept: application/vnd.docker.distribution.manifest.v2+json" -H "Authorization: Bearer ${token}" "https://${host}/v2/${repo}/manifests/${tag}" 2>/dev/null || true)
		manifest_digest=$(printf '%s' "${manifest_headers}" | grep -i "docker-content-digest:" | tail -1 | tr -d '\r' | sed -nE 's/.*:[[:space:]]*(sha256:([a-fA-F0-9]{64})).*/\1/p' || true)
		if [ -n "${manifest_digest}" ]; then
			printf '%s\n' "${manifest_digest}"
			return 0
		fi
	fi

	return 1
}

# Simple helper: get local image ID (docker .Id)
get_local_image_id() {
	docker inspect --format='{{.Id}}' "$1" 2>/dev/null || return 1
}

# Compare local image digest with remote (docker.io) digest
# Usage: compare_image_reproducibility <local_image_ref> [remote_image_ref]
# Prefer comparing image-config digest (image ID) fetched from registry when possible.
compare_image_reproducibility() {
	local local_image="$1"
	local remote_image
	remote_image=$(resolve_repro_remote_image "${2:-}")

	echo "" >&2
	echo "=== Reproducibility Check ===" >&2

	local local_id
	local_id=$(get_local_image_id "${local_image}") || {
		echo "Error: local image not found: ${local_image}" >&2
		return 1
	}
	echo "Local image (${local_image}):   ${local_id}" >&2

	# Get remote config digest
	local remote_config remote_method
	if IFS=$'\t' read -r remote_config remote_method < <(get_remote_config_digest "${remote_image}"); then
		:
	fi

	# Show results
	if [ -n "${remote_config}" ]; then
		echo "Remote image (${remote_image}): ${remote_config}" >&2
		echo "(via ${remote_method:-registry})" >&2
		if [ "${local_id##*:}" = "${remote_config##*:}" ]; then
			echo "✓ MATCH: Config digests identical (bit-for-bit reproducible)" >&2
			echo "Config digest: ${local_id}" >&2
			# Note: manifest digest may differ from config (normal - manifest includes metadata)
			# To manually verify: go to https://hub.docker.com/r/{repo}/tags, click the tag, see URL
			# Only show Docker Hub URL for Docker Hub images (not other registries)
			local remote_manifest is_docker_hub remote_name remote_tag first_component last_segment
			remote_name="${remote_image%@*}" # strip @digest
			remote_tag="latest"
			last_segment="${remote_name##*/}"
			if [ "${last_segment}" != "${last_segment##*:}" ]; then
				remote_tag="${last_segment##*:}"
				remote_name="${remote_name%:*}"
			fi
			first_component="${remote_name%%/*}"
			is_docker_hub=0
			if [ "${first_component}" = "${remote_name}" ]; then
				is_docker_hub=1
			elif ! echo "${first_component}" | grep -qE '[.:]|^localhost$'; then
				is_docker_hub=1
			elif echo "${first_component}" | grep -qE '(^|.*\.)docker\.io$|^index\.docker\.io$|^registry-1\.docker\.io$'; then
				is_docker_hub=1
			fi
			if [ "${is_docker_hub}" = "1" ]; then
				remote_manifest=$(get_remote_manifest_digest "${remote_image}" 2>/dev/null || true)
				if [ -n "${remote_manifest}" ]; then
					local remote_repo="${remote_name}"
					if echo "${first_component}" | grep -qE '(^|.*\.)docker\.io$|^index\.docker\.io$|^registry-1\.docker\.io$'; then
						remote_repo="${remote_name#*/}"
					fi
					if [ "${remote_repo}" = "${remote_repo#*/}" ]; then
						remote_repo="library/${remote_repo}"
					fi
					local hub_manifest="${remote_manifest#sha256:}"
					local hub_url="https://hub.docker.com/layers/${remote_repo}/${remote_tag}/images/sha256-${hub_manifest}"
					echo "Note: manifest digest differs from config (normal - manifest includes metadata)" >&2
					echo "Docker Hub: ${hub_url}" >&2
				fi
			else
				echo "Note: manifest digest not shown (non-Docker-Hub registry)" >&2
			fi
			echo "=== End Reproducibility Check ===" >&2
			return 0
		else
			echo "✗ MISMATCH: Config digests differ" >&2
			echo "=== End Reproducibility Check ===" >&2
			return 1
		fi
	fi

	# Couldn't get remote config digest - need to fall back to pull
	print_once "fetch_failed" "  Could not fetch remote image config digest via registry; falling back to 'docker pull' to compare image IDs (progress will be shown)."
	print_once "tools_notice" "  Tip: Install jq and curl for faster registry-based checks (no pull needed)." >&2
	if [ "${HEADS_CHECK_REPRODUCIBILITY_NO_PULL:-0}" = "1" ]; then
		echo "Auto-pull suppressed by HEADS_CHECK_REPRODUCIBILITY_NO_PULL=1; aborting reproducibility check." >&2
		return 1
	fi
	if ! prompt_for_pull "${remote_image}"; then
		return 1
	fi
	echo "Pulling remote image (progress will be shown)..." >&2
	if ! docker pull "${remote_image}"; then
		echo "Error: failed to pull remote image ${remote_image}" >&2
		return 1
	fi
	local remote_id
	remote_id=$(get_local_image_id "${remote_image}" 2>/dev/null || true)
	echo "Remote image (pulled ${remote_image}): ${remote_id:-<unknown>}" >&2
	if [ "${local_id}" = "${remote_id}" ]; then
		echo "✓ MATCH: Image IDs identical after pull." >&2
		echo "=== End Reproducibility Check ===" >&2
		echo "" >&2
		return 0
	else
		echo "✗ MISMATCH: Image IDs differ after pull." >&2
		echo "  Local:  ${local_id}" >&2
		echo "  Remote: ${remote_id}" >&2
		echo "=== End Reproducibility Check ===" >&2
		echo "" >&2
		return 1
	fi
}

# Common run helper
run_docker() {
	local image="$1"
	shift
	local opts host_workdir container_workdir DOCKER_OPTS_ARRAY
	# Read docker options (one-per-line) into an array, preserving spaces within options
	mapfile -t DOCKER_OPTS_ARRAY < <(build_docker_opts)
	# Also create a single-string representation for legacy substring checks
	opts=$(printf '%s\n' "${DOCKER_OPTS_ARRAY[@]}")
	host_workdir="$(pwd)"
	container_workdir="${host_workdir}"

	local -a parts=()
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

	docker run "${DOCKER_OPTS_ARRAY[@]}" -v "${host_workdir}:${container_workdir}" -w "${container_workdir}" "${image}" -- "$@"
	local status=$?
	if [ "${DOCKER_XAUTH_TEMP:-0}" = "1" ] && [ -n "${DOCKER_XAUTH_FILE}" ]; then
		rm -f "${DOCKER_XAUTH_FILE}" || true
	fi
	return $status
}

# ================================================================
# Script initialization and setup
# ================================================================

# Detect if script is being sourced or executed directly
# When sourced: BASH_SOURCE[0] != $0
# When executed: BASH_SOURCE[0] == $0
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	# Script is being executed directly: show the full environment usage.
	usage
	exit 0
fi

if [ "${__HEADS_RESTORE_SHELL_OPTS}" = "1" ]; then
	eval "${__HEADS_SHELL_OPTS}"
fi
