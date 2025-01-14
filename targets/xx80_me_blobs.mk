# Targets for downloading xx80 ME blob, neutering it and deactivating ME.
# This also uses the deguard tool to bypass Intel Boot Guard exploiting CVE-2017-5705.
# See https://www.intel.com/content/www/us/en/security-center/advisory/intel-sa-00086.html

# xx80-*-maximized boards require of you initially call one of the
#  following to have gbe.bin ifd.bin and me.bin
#  - blobs/xx80/download_clean_me_and_deguard.sh
#     To download Lenovo original ME binary, neuter+deactivate ME, produce
#      reduced IFD ME region and expanded BIOS IFD region.
#  - blobs/xx80/extract_and_deguard.sh
#     To extract ME binary, GBE and IFD blobs and apply the deguard exploit to the the ME binary.

# Make the Coreboot build depend on the following 3rd party blobs:
$(build)/coreboot-$(CONFIG_COREBOOT_VERSION)/$(BOARD)/.build: \
    $(pwd)/blobs/xx80/me.bin

$(pwd)/blobs/kabylake/Fsp_M.fd:
	COREBOOT_DIR="$(build)/$(coreboot_base_dir)" \
		$(pwd)/blobs/kabylake/fetch_split_fsp.sh $(pwd)/blobs/kabylake

$(pwd)/blobs/kabylake/Fsp_S.fd:
	COREBOOT_DIR="$(build)/$(coreboot_base_dir)" \
		$(pwd)/blobs/kabylake/fetch_split_fsp.sh $(pwd)/blobs/kabylake		

$(pwd)/blobs/xx80/me.bin:
	COREBOOT_DIR="$(build)/$(coreboot_base_dir)" \
		$(pwd)/blobs/xx80/download_clean_deguard_me.sh $(pwd)/blobs/xx80