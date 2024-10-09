# Targets for downloading optiplex 7010/9010 blobs: including ACM, SINIT and EC blobs

REQUIRED_BLOBS := \
    $(pwd)/blobs/xx30/IVB_BIOSAC_PRODUCTION.bin \
    $(pwd)/blobs/xx30/SNB_IVB_SINIT_20190708_PW.bin \
    $(pwd)/blobs/xx30/sch5545_ecfw.bin

# Make the Coreboot build depend on the required blobs
$(build)/coreboot-$(CONFIG_COREBOOT_VERSION)/$(BOARD)/.build: $(REQUIRED_BLOBS)

# Rule to generate all required blobs
$(REQUIRED_BLOBS):
	$(pwd)/blobs/xx30/optiplex_7010_9010.sh $(pwd)/blobs/xx30
