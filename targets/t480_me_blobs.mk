# Targets for downloading xx80 ME blob, neutering it and deactivating ME.
# This also uses the deguard tool to bypass Intel Boot Guard exploiting CVE-2017-5705.
# See https://www.intel.com/content/www/us/en/security-center/advisory/intel-sa-00086.html

# xx80-*-maximized boards require of you initially call one of the
#  following to have gbe.bin ifd.bin and me.bin
#  - blobs/xx80/download_clean_me_and_deguard.sh
#     To download Lenovo original ME binary, neuter+deactivate ME, produce
#     reduced IFD ME region and expanded BIOS IFD region.
#	  Also creates the tb.bin blob to flash the Thunderbolt SPI.

# Make the Coreboot build depend on the following 3rd party blobs:
$(build)/coreboot-$(CONFIG_COREBOOT_VERSION)/$(BOARD)/.build: \
    $(pwd)/blobs/xx80/t480_me.bin $(pwd)/blobs/xx80/t480_tb.bin $(build)/$(BOARD)/t480_tb.bin	

$(pwd)/blobs/xx80/t480_me.bin $(pwd)/blobs/xx80/t480_tb.bin &:
	$(pwd)/blobs/xx80/t480_download_clean_deguard_me_pad_tb.sh \
		-m $(pwd)/blobs/utils/me_cleaner/me_cleaner.py $(pwd)/blobs/xx80

$(build)/$(BOARD)/t480_tb.bin: $(pwd)/blobs/xx80/t480_tb.bin
	cp $(pwd)/blobs/xx80/t480_tb.bin $(build)/$(BOARD)
