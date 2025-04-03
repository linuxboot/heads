#!/usr/bin/env bash

# These variables are all for the deguard tool.
# They would need to be changed if using the tool for other devices like the T480s or with a different ME version...
ME_delta="thinkpad_t480"
ME_version="11.6.0.1126"
ME_sku="2M"
ME_pch="LP"

# Thunderbolt firmware offset in bytes to pad to 1M
TBFW_SIZE=1048575

# Integrity checks for the vendor provided ME blob...
ME_DOWNLOAD_HASH="ddfbc51430699e0dfcb24a60bcb5b6e5481b325ebecf1ac177e069013189e4b0"
# ...and the cleaned and deguarded version from that blob.
DEGUARDED_ME_BIN_HASH="1990b42df67ba70292f4f6e2660efb909917452dcb9bd4b65ea2f86402cfa16b"
# Integrity checks for the vendor provided Thunderbolt blob...
TB_DOWNLOAD_HASH="a500a93fe6a3728aa6676c70f98cf46785ef15da7c5b1ccd7d3a478d190a28a8"
# ...and the padded and flashable version from that blob.
TB_BIN_HASH="fc9c47ff4b16f036a7f49900f9da1983a5db44ca46156238b7b42e636d317388"

function usage() {
	echo -n \
		"Usage: $(basename "$0") -m <me_cleaner>(optional) path_to_output_directory
Download Intel ME firmware from Dell, neutralize and shrink keeping the MFS.
Download Thunderbolt firmware from Lenovo and pad it for flashing externally.
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
			[[ "$3" = TB ]] && tb_exists="y"
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
	me_installer_filename="Inspiron_5468_1.3.0.exe"
	user_agent="Mozilla/5.0 (Windows NT 10.0; rv:91.0) Gecko/20100101 Firefox/91.0"
	curl -A "$user_agent" -s -O "https://dl.dell.com/FOLDER04573471M/1/${me_installer_filename}"
	chk_sha256sum "$ME_DOWNLOAD_HASH" "$me_installer_filename"

	# Download the tool to unpack Dell's installer and unpack the ME blob.
	git clone https://github.com/platomav/BIOSUtilities
	git -C BIOSUtilities checkout ef50b75ae115ae8162fa8b0a7b8c42b1d2db894b

	python "BIOSUtilities/Dell_PFS_Extract.py" "${me_installer_filename}" -e || exit

	extracted_me_filename="1 Inspiron_5468_1.3.0 -- 3 Intel Management Engine (Non-VPro) Update v${ME_version}.bin"

	# Neutralize and shrink Intel ME. Note that this doesn't include
	# --soft-disable to set the "ME Disable" or "ME Disable B" (e.g.,
	# High Assurance Program) bits, as they are defined within the Flash
	# Descriptor.
	# However, the HAP bit must be enabled to make the deguarded ME work. We only clean the ME in this function.
	# https://github.com/corna/me_cleaner/wiki/External-flashing#neutralize-and-shrink-intel-me-useful-only-for-coreboot

	# MFS is needed for deguard so we whitelist it here and also do not relocate the FTPR partition
	python "$me_cleaner" --whitelist MFS -t -O "$me_output" "${me_installer_filename}_extracted/Firmware/${extracted_me_filename}"
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

function download_and_pad_tb() {
	tb_output="$(realpath "${1}")"

	# Download and unpack the Lenovo installer into a temporary directory and
	# extract the TB blob.
	pushd "$(mktemp -d)" || exit

	# Download the installer that contains the TB blob
	tb_installer_filename=""n24th13w.exe""
	user_agent="Mozilla/5.0 (Windows NT 10.0; rv:91.0) Gecko/20100101 Firefox/91.0"
	curl -A "$user_agent" -s -O "https://download.lenovo.com/pccbbs/mobiles/${tb_installer_filename}"
	chk_sha256sum "$TB_DOWNLOAD_HASH" "$tb_installer_filename"

	# https://www.reddit.com/r/thinkpad/comments/9rnimi/ladies_and_gentlemen_i_present_to_you_the/
	innoextract n24th13w.exe -d .
	mv ./code\$GetExtractPath\$/TBT.bin tb.bin
	# pad with zeros
	dd if=/dev/zero of=tb.bin bs=1 seek="$TBFW_SIZE" count=1
	mv "tb.bin" "$tb_output"

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
	me_deguarded="${output_dir}/me.bin"
	tb_flashable="${output_dir}/tb.bin"
	echo "Writing cleaned and deguarded ME to ${me_deguarded}"
	echo "Writing flashable TB to ${tb_flashable}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	if [[ "${1:-}" == "--help" ]]; then
		usage
		exit 0
	fi

	parse_params "$@"
	chk_exists_and_matches "$me_deguarded" "$DEGUARDED_ME_BIN_HASH" ME
	chk_exists_and_matches "$tb_flashable" "$TB_BIN_HASH" TB

	if [[ -z "$me_exists" ]]; then
		download_and_clean "$me_cleaner" "$me_cleaned"
		deguard "$me_cleaned" "$me_deguarded"
		rm -f "$me_cleaned"
	fi
	
	if [[ -z "$tb_exists" ]]; then
		download_and_pad_tb "$tb_flashable"
	fi
	
	chk_sha256sum "$DEGUARDED_ME_BIN_HASH" "$me_deguarded"
	chk_sha256sum "$TB_BIN_HASH" "$tb_flashable"
fi
