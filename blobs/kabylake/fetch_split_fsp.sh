#!/usr/bin/env bash

function usage() {
	echo -n \
		"Usage: $(basename "$0") path_to_output_directory
Get FSP from coreboot git submodule and split.
"
}

# Integrity checks for the coreboot provided fsp blob...
FSP_FD_COREBOOT_HASH="ddfbc51430699e0dfcb24a60bcb5b6e5481b325ebecf1ac177e069013189e4b0"
FSP_SUBMODULE_PATH="3rdparty/fsp"
PATH_TO_FSP_FD_IN_SUBMODULE="KabylakeFspBinPkg/Fsp.fd"
SPLIT_FSP_PATH_IN_SUBMODULE="Tools/SplitFspBin.py"


split_fsp()
{
	fsp_binary="$1"
	fsp_output_dir="$2"
	split_fsp_py="${COREBOOT_DIR}/${FSP_SUBMODULE_PATH}/${SPLIT_FSP_PATH_IN_SUBMODULE}"
	python "$split_fsp_py" split -f "$fsp_binary" -o "$fsp_output_dir" -n "Fsp.fd" || exit 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	if [[ "${1:-}" == "--help" ]]; then
		usage
	else
		output_dir="$(realpath "${1:-./}")"
		fsp_m_path="${output_dir}/Fsp_M.fd"
		fsp_s_path="${output_dir}/Fsp_S.fd"
		#chk_exists

		if [[ -z "${COREBOOT_DIR}" ]]; then
			echo "ERROR: No COREBOOT_DIR variable defined."
			exit 1
		fi
		
		# TODO chk_exists above
		# if [[ ! -f "$fsp_s_path" ]] || [[ ! -f "$fsp_m_path" ]] || [ "$retry" = "y" ]; then
			git -C "$COREBOOT_DIR" submodule update --init --checkout "$FSP_SUBMODULE_PATH"
			fsp_fd="${COREBOOT_DIR}/${FSP_SUBMODULE_PATH}/${PATH_TO_FSP_FD_IN_SUBMODULE}"
			chk_sha256sum "$FSP_FD_COREBOOT_HASH" "$fsp_fd"
			pushd "$(mktemp -d)" || exit
			fsp_file="Fsp.fd"
			cp "$fsp_fd" "$fsp_file"

			split_fsp "$(pwd)/${fsp_file}" "$output_dir"

			rm -rf ./*
			popd || exit
			git -C "$COREBOOT_DIR" submodule deinit "$FSP_SUBMODULE_PATH"
		# fi

		# TODO final checksums
		# chk_sha256sum "$FSP_FD_COREBOOT_HASH" "$fsp_s_path"
		# chk_sha256sum "$FSP_FD_COREBOOT_HASH" "$fsp_m_path"
	fi
fi