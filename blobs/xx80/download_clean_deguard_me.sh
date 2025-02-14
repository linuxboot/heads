#!/usr/bin/env bash

# These variables are all for the deguard tool.
# They would need to be changed if using the tool for other devices like the T480s or with a different ME version...
ME_delta="thinkpad_t480"
ME_version="11.6.0.1126"
ME_sku="2M"
ME_pch="LP"

# Integrity checks for the vendor provided ME blob...
ME_DOWNLOAD_HASH="ddfbc51430699e0dfcb24a60bcb5b6e5481b325ebecf1ac177e069013189e4b0"
# ...and the cleaned and deguarded version from that blob.
DEGUARDED_ME_BIN_HASH="1990b42df67ba70292f4f6e2660efb909917452dcb9bd4b65ea2f86402cfa16b"

function usage() {
	echo -n \
		"Usage: $(basename "$0") path_to_output_directory
Download Intel ME firmware from Dell, neutralize and shrink keeping the MFS.
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

function chk_exists() {
	if [ -e "$me_deguarded" ]; then
		echo "me.bin already exists"
		if echo "${DEGUARDED_ME_BIN_HASH} $me_deguarded" | sha256sum --check; then
			echo "SKIPPING: SHA256 checksum for me.bin matches."
			exit 0
		fi
		retry="y"
		echo "me.bin exists but checksum doesn't match. Continuing..."
	fi
}

function download_and_clean() {
	me_output="$(realpath "${1}")"

	# Download and unpack the Dell installer into a temporary directory and
	# extract the deguardable Intel ME blob.
	pushd "$(mktemp -d)" || exit

	# Download the installer that contains the ME blob
	me_installer_filename="Inspiron_5468_1.3.0.exe"
	user_agent="Mozilla/5.0 (Windows NT 10.0; rv:91.0) Gecko/20100101 Firefox/91.0"
	curl -A "$user_agent" -s -O "https://dl.dell.com/FOLDER04573471M/1/${me_installer_filename}"
	chk_sha256sum "$ME_DOWNLOAD_HASH" "$me_installer_filename"

	# Download the tool to unpack Dell's installer and unpack the ME blob.
	git clone https://github.com/platomav/BIOSUtilities
	git -C BIOSUtilities checkout ef50b75ae115ae8162fa8b0a7b8c42b1d2db894b

	python "BIOSUtilities/Dell_PFS_Extract.py" "${me_installer_filename}" -e || exit

	extracted_me_filename="1 Inspiron_5468_1.3.0 -- 3 Intel Management Engine (Non-VPro) Update v${ME_version}.bin"

	mv "${me_installer_filename}_extracted/Firmware/${extracted_me_filename}" "${COREBOOT_DIR}/util/me_cleaner"
	rm -rf ./*
	popd || exit

	# Neutralize and shrink Intel ME. Note that this doesn't include
	# --soft-disable to set the "ME Disable" or "ME Disable B" (e.g.,
	# High Assurance Program) bits, as they are defined within the Flash
	# Descriptor.
	# However, the HAP bit must be enabled to make the deguarded ME work. We only clean the ME in this function.
	# https://github.com/corna/me_cleaner/wiki/External-flashing#neutralize-and-shrink-intel-me-useful-only-for-coreboot
	pushd "${COREBOOT_DIR}/util/me_cleaner" || exit

	# MFS is needed for deguard so we whitelist it here and also do not relocate the FTPR partition
	python me_cleaner.py --whitelist MFS -t -O "$me_output" "$extracted_me_filename"
	rm -f "$extracted_me_filename"
	popd || exit
}

function deguard() {
	me_input="$(realpath "${1}")"
	me_output="$(realpath "${2}")"

	# Download the deguard tool into a temporary directory and apply the patch to the cleaned ME blob.
	pushd "$(mktemp -d)" || exit
	git clone https://review.coreboot.org/deguard.git
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	if [[ "${1:-}" == "--help" ]]; then
		usage
	else

		output_dir="$(realpath "${1:-./}")"
		me_cleaned="${output_dir}/me_cleaned.bin"
		me_deguarded="${output_dir}/me.bin"
		chk_exists

		if [[ -z "${COREBOOT_DIR}" ]]; then
			echo "ERROR: No COREBOOT_DIR variable defined."
			exit 1
		fi

		if [[ ! -f "$me_deguarded" ]] || [ "$retry" = "y" ]; then
			download_and_clean "$me_cleaned"
			deguard "$me_cleaned" "$me_deguarded"
			rm -f "$me_cleaned"
		fi

		chk_sha256sum "$DEGUARDED_ME_BIN_HASH" "$me_deguarded"
	fi
fi
