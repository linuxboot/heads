# Targets for downloading m900_tiny ME blob, neutering it down to BUP+ROMP region and deactivating ME.

# m900_tiny-*-maximized boards require of you initially call one of the
#  following to have gbe.bin ifd.bin and me.bin
#  - blobs/m900_tiny/download_clean_me.sh
#     To download Lenovo original ME binary, neuter+deactivate ME, produce
#      reduced IFD ME region and expanded BIOS IFD region.
#  - blobs/m900_tiny/extract.sh
#     To extract from backuped 8M (bottom SPI) ME binary, GBE and IFD blobs.

# Make the Coreboot build depend on the following 3rd party blobs:
$(build)/coreboot-$(CONFIG_COREBOOT_VERSION)/$(BOARD)/.build: \
    $(pwd)/blobs/m900_tiny/m900_tiny_me.bin


$(pwd)/blobs/m900_tiny/m900_tiny_me.bin:
	$(pwd)/blobs/m900_tiny/m900_tiny_download_clean_deguard_me.sh \
		-m $(pwd)/blobs/utils/me_cleaner/me_cleaner.py $(pwd)/blobs/m900_tiny

