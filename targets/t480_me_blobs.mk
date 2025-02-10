# TODO describe the process for t480
#Targets for downloading t480 ME blob, cleaning and deguarding.

# t480-*-maximized boards require you to initially call
#  - blobs/t480/download-clean-deguard-me.sh
#     To download donor's Dells-Inspiron.exe, extract ME binary with biosutilities from libreboot, clean ME,
#      and deguard it using Mate Kukri deguard tool.

# Make the Coreboot build depend on the following 3rd party blobs:
$(build)/coreboot-$(CONFIG_COREBOOT_VERSION)/$(BOARD)/.build: \
    $(pwd)/blobs/t480/me.bin

$(pwd)/blobs/t480/me.bin:
	COREBOOT_DIR="$(build)/$(coreboot_base_dir)" \
		$(pwd)/blobs/t480/download-clean-deguard-me.sh $(pwd)/blobs/t480
