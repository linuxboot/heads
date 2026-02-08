#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage: $0 [--version VERSION] [--url URL]

Download the Nix installer (no execution) and print its sha256. If a release
version is specified (e.g. 'nix-2.33.2') the script will also try to fetch

  https://releases.nixos.org/nix/${VERSION}/install.sha256

so you can compare the published checksum against the downloaded installer.

Examples:
  ./docker/fetch_nix_installer.sh --version nix-2.33.2
  ./docker/fetch_nix_installer.sh --url https://nixos.org/nix/install
USAGE
}

if [ $# -eq 0 ]; then
  usage
  exit 2
fi

installer_url=""
sha_url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      if [ $# -lt 2 ]; then echo "Missing argument for --version" >&2; usage; exit 2; fi
      installer_url="https://releases.nixos.org/nix/$2/install"
      sha_url="$installer_url.sha256"
      shift 2 ;;
    --url)
      if [ $# -lt 2 ]; then echo "Missing argument for --url" >&2; usage; exit 2; fi
      installer_url="$2"
      sha_url=""
      shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$installer_url" ]; then
  echo "No installer URL determined; provide --version or --url" >&2
  usage
  exit 2
fi

# choose downloader
if command -v curl >/dev/null 2>&1; then
  downloader=curl
elif command -v wget >/dev/null 2>&1; then
  downloader=wget
else
  echo "Error: neither curl nor wget available to fetch installer" >&2
  exit 1
fi

tmpf=$(mktemp) || { echo "Failed to create temporary file" >&2; exit 1; }
trap 'rm -f "$tmpf"' EXIT

if [ "$downloader" = "curl" ]; then
  curl -fsSL "$installer_url" -o "$tmpf" || { echo "Failed to download $installer_url" >&2; exit 1; }
else
  wget -qO "$tmpf" "$installer_url" || { echo "Failed to download $installer_url" >&2; exit 1; }
fi

# compute sha
inst_sha=""
if command -v sha256sum >/dev/null 2>&1; then
  inst_sha=$(sha256sum "$tmpf" | awk '{print $1}') || inst_sha=""
elif command -v shasum >/dev/null 2>&1; then
  inst_sha=$(shasum -a 256 "$tmpf" | awk '{print $1}') || inst_sha=""
else
  inst_sha=""
fi

echo "Downloaded installer: $installer_url"
if [ -n "$inst_sha" ]; then
  echo "Installer sha256: $inst_sha"
else
  echo "sha256 unavailable (no sha256sum/shasum)"
fi

if [ -n "$sha_url" ]; then
  pub_sha=""
  if [ "$downloader" = "curl" ]; then
    pub_sha=$(curl -fsSL "$sha_url" 2>/dev/null | tr -d '[:space:]' || true)
  else
    pub_sha=$(wget -qO- "$sha_url" 2>/dev/null | tr -d '[:space:]' || true)
  fi
  if [ -n "$pub_sha" ]; then
    echo "Published sha at: $sha_url"
    echo "Published sha256: $pub_sha"
    if [ -n "$inst_sha" ] && [ "$inst_sha" = "$pub_sha" ]; then
      echo "OK: published sha matches downloaded installer"
    else
      echo "WARNING: published sha does NOT match downloaded installer"
    fi
  else
    echo "Note: could not fetch published sha from: $sha_url"
  fi
fi

exit 0
