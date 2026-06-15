# Targets for downloading m900 ME blob, neutering it down to BUP+ROMP region and deactivating ME.
#
# m900-*-maximized boards require you to initially call:
#  make blobs/m900/m900_me.bin
# which runs blobs/m900/m900_download_clean_deguard_me.sh to:
#  1. Download the ASRock H110M-DGS BIOS zip containing ME 11.6.0.1126
#  2. Extract, partially neuter and deguard the ME firmware
#  3. Place the result into blobs/m900/m900_me.bin
#
# The IFD (m900_tower_ifd.bin) and GBE (m900_tower_gbe.bin) blobs are
# taken from a donor board and committed to the repo directly.

# Make the Coreboot build depend on the following 3rd party blobs:
$(build)/coreboot-$(CONFIG_COREBOOT_VERSION)/$(BOARD)/.build: \
    $(pwd)/blobs/m900/m900_me.bin


$(pwd)/blobs/m900/m900_me.bin:
	$(pwd)/blobs/m900/m900_download_clean_deguard_me.sh \
		-m $(pwd)/blobs/utils/me_cleaner/me_cleaner.py $(pwd)/blobs/m900

