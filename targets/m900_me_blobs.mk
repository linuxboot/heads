# Targets for downloading m900 ME blob, neutering it down to BUP+ROMP region and deactivating ME.

# m900-*-maximized boards require of you initially call one of the
#  following to have gbe.bin ifd.bin and me.bin
#  - blobs/m900/download_clean_me.sh
#     To download Lenovo original ME binary, neuter+deactivate ME

# Make the Coreboot build depend on the following 3rd party blobs:
$(build)/coreboot-$(CONFIG_COREBOOT_VERSION)/$(BOARD)/.build: \
    $(pwd)/blobs/m900/m900_me.bin


$(pwd)/blobs/m900/m900_me.bin:
	$(pwd)/blobs/m900/m900_download_clean_deguard_me.sh \
		-m $(pwd)/blobs/utils/me_cleaner/me_cleaner.py $(pwd)/blobs/m900

