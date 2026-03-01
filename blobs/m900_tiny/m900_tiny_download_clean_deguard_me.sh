#!/usr/bin/env bash

# These variables are all for the deguard tool.
# They would need to be changed if using the tool for other devices with different ME version...
ME_delta="optiplex_3050"
ME_version="11.6.0.1126"
ME_sku="2M"
ME_pch="H"


# Integrity checks for the vendor provided ME blob...
DL_HASH="de26085e1fbfaaa0302ec73dba411a5fd25fe13ae07e69a2287754ada6a7a196"

# ...and the cleaned and deguarded version from that blob.
DEGUARDED_ME_BIN_HASH="9c3eff6be017b36c819a0df3c1f6537bb26b6f3d5780787f60b91cedc789f0f0"


function usage() {
	echo -n \
		"Usage: $(basename "$0") -m <me_cleaner>(optional) path_to_output_directory
Download Intel ME firmware from ASRock, neutralize and shrink keeping the MFS.

"
}

function chk_sha256sum() {
	sha256_hash="$1"
	filename="$2"
	echo "$sha256_hash" "$filename" "$(pwd)"
	sha256sum "$filename"
	if ! echo "${sha256_hash} ${filename}" | sha256sum --check; then
		echo "ERROR: SHA256 checksum for ${filename} doesn't match."
		exit 1
	fi
}

function chk_exists_and_matches() {
	if [[ -f "$1" ]]; then
		if echo "${2} ${1}" | sha256sum --check; then
			echo "SKIPPING: SHA256 checksum for $1 matches."
			[[ "$3" = ME ]] && me_exists="y"
		fi
		echo "$1 exists but checksum doesn't match. Continuing..."
	fi
}

function download_and_clean() {
	me_cleaner="$(realpath "${1}")"
	me_output="$(realpath "${2}")"

	# Download and unpack the Dell installer into a temporary directory and
	# extract the deguardable Intel ME blob.
	pushd "$(mktemp -d)" || exit

	# Download the installer that contains the ME blob
	me_installer_filename="H110M-DGS(7.30)ROM.zip"
	user_agent="Mozilla/5.0 (Windows NT 10.0; rv:91.0) Gecko/20100101 Firefox/91.0"
	curl -A "$user_agent" -s -O "https://download.asrock.com/BIOS/1151/${me_installer_filename}"
	chk_sha256sum "$DL_HASH" "$me_installer_filename"

	# Unpack the ME blob.
	unzip "$me_installer_filename" || exit

	extracted_me_filename="H11MDGS7.30"

	# Deactivate, partially neuter and shrink Intel ME. Note that this doesn't include
	# --soft-disable to set the "ME Disable" or "ME Disable B" (e.g.,
	# High Assurance Program) bits, as they are defined within the Flash
	# Descriptor.
	# However, the HAP bit must be enabled to make the deguarded ME work. We only clean the ME in this function.
	# For ME 11.x this means we must keep the rbe, bup, kernel and syslib modules.
	# https://github.com/corna/me_cleaner/wiki/How-does-it-work%3F#me-versions-from-11x-skylake-1
	# Furthermore, deguard requires keeping the MFS, the HAP bit set, and we cannot relocate the FTPR partition.
	# Some more general info on shrinking:
	# https://github.com/corna/me_cleaner/wiki/External-flashing#neutralize-and-shrink-intel-me-useful-only-for-coreboot

	# MFS is needed for deguard so we whitelist it here and also do not relocate the FTPR partition
	python "$me_cleaner" --whitelist MFS -t -M "$me_output" "${extracted_me_filename}"
	rm -rf ./*
	popd || exit
}

function deguard() {
	me_input="$(realpath "${1}")"
	me_output="$(realpath "${2}")"

	# Download the deguard tool into a temporary directory and apply the patch to the cleaned ME blob.
	pushd "$(mktemp -d)" || exit
	git clone https://github.com/coreboot/deguard
	pushd deguard || exit
	git checkout 0ed3e4ff824fc42f71ee22907d0594ded38ba7b2

	python ./finalimage.py \
		--delta "data/delta/$ME_delta" \
		--version "$ME_version" \
		--pch "$ME_pch" \
		--sku "$ME_sku" \
		--fake-fpfs data/fpfs/zero \
		--input "$me_input" \
		--output "$me_output"

	popd || exit
	#Cleanup
	rm -rf ./*
	popd || exit
}


function usage_err() {
	echo "$1"
	usage
	exit 1
}

function parse_params() {
	while getopts ":m:" opt; do
		case $opt in
		m)
			if [[ -x "$OPTARG" ]]; then
				me_cleaner="$OPTARG"
			fi
			;;
		?)
			usage_err "Invalid Option: -$OPTARG"
			;;
		esac
	done

	if [[ -z "${me_cleaner}" ]]; then
		if [[ -z "${COREBOOT_DIR}" ]]; then
			usage_err "ERROR: me_cleaner.py not found. Set path with -m parameter or define the COREBOOT_DIR variable."
		else
			me_cleaner="${COREBOOT_DIR}/util/me_cleaner/me_cleaner.py"
		fi
	fi
	echo "Using me_cleaner from ${me_cleaner}"

	shift $(($OPTIND - 1))
	output_dir="$(realpath "${1:-./}")"
	if [[ ! -d "${output_dir}" ]]; then
		usage_err "No valid output dir found"
	fi
	me_cleaned="${output_dir}/me_cleaned.bin"
	me_deguarded="${output_dir}/m900_tiny_me.bin"
	echo "Writing cleaned and deguarded ME to ${me_deguarded}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	if [[ "${1:-}" == "--help" ]]; then
		usage
		exit 0
	fi

	parse_params "$@"
	chk_exists_and_matches "$me_deguarded" "$DEGUARDED_ME_BIN_HASH" ME

	if [[ -z "$me_exists" ]]; then
		download_and_clean "$me_cleaner" "$me_cleaned"
		deguard "$me_cleaned" "$me_deguarded"
		rm -f "$me_cleaned"
	fi
	
	chk_sha256sum "$DEGUARDED_ME_BIN_HASH" "$me_deguarded"
fi
