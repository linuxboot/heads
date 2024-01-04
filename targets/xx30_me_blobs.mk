# Targets for downloading xx30 ME blob, neutering it down to BUP+ROMP region and deactivating ME.

# xx30-*-maximized boards require of you initially call one of the
#  following to have gbe.bin ifd.bin and me.bin
#  - blobs/xx30/download_clean_me.sh
#     To download Lenovo original ME binary, neuter+deactivate ME, produce
#      reduced IFD ME region and expanded BIOS IFD region.
#  - blobs/xx30/extract.sh
#     To extract from backuped 8M (bottom SPI) ME binary, GBE and IFD blobs.

# Make the Coreboot build depend on the following 3rd party blobs:
$(build)/coreboot-$(CONFIG_COREBOOT_VERSION)/$(BOARD)/.build: \
    $(pwd)/blobs/xx30/me.bin


$(pwd)/blobs/xx30/me.bin:
	COREBOOT_DIR="$(build)/$(coreboot_base_dir)" \
		$(pwd)/blobs/xx30/download_clean_me.sh $(pwd)/blobs/xx30
