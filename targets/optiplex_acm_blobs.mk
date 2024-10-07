# Targets for downloading optiplex 7010/9010 ACM blobs

# Make the Coreboot build depend on the following 3rd party blobs:
$(build)/coreboot-$(CONFIG_COREBOOT_VERSION)/$(BOARD)/.build: \
    $(pwd)/blobs/xx30/IVB_BIOSAC_PRODUCTION.bin


$(pwd)/blobs/xx30/IVB_BIOSAC_PRODUCTION.bin:
	$(pwd)/blobs/xx30/optiplex_7010_9010.sh $(pwd)/blobs/xx30
