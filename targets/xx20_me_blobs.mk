# Targets for downloading xx20 ME blob, neutering it down to BUP region and deactivating ME.

# xx20 boards require of you initially call one of the following to habe gbe.bin ifd.bin and me.bin
#  - blobs/xx20/download_parse_me.sh
#     To download Lenovo update ME binary, neuter+deactivate ME, produce reduced IFD ME region and expended BIOS IFD region.

# Make the Coreboot build depend on the following 3rd party blobs:
$(build)/coreboot-$(CONFIG_COREBOOT_VERSION)/$(BOARD)/.build: \
	$(pwd)/blobs/xx20/me.bin


$(pwd)/blobs/xx20/me.bin:
	COREBOOT_DIR="$(build)/$(coreboot_base_dir)" \
		$(pwd)/blobs/xx20/download_parse_me.sh

