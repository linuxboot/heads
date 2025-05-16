# Make the Coreboot build depend on the following 3rd party blobs:
$(build)/coreboot-$(CONFIG_COREBOOT_VERSION)/$(BOARD)/.build: \
    $(pwd)/blobs/msi_z790p_ddr5/ifd.bin $(pwd)/blobs/msi_z790p_ddr5/me.bin

$(pwd)/blobs/msi_z790p_ddr5/ifd.bin $(pwd)/blobs/msi_z790p_ddr5/me.bin:
	COREBOOT_DIR="$(build)/$(coreboot_base_dir)" \
		$(pwd)/blobs/msi_z790p_ddr5/download_extract.sh
