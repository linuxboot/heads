# Many Lenovo boards have two SPI flash chips, an 8 MB that holds the IFD,
# the ME image and part of the coreboot image, and a 4 MB one that
# has the rest of the coreboot and the reset vector.
#
# As a consequence, this replaces the need of having to flash a legacy-flash ROM
#  and expands available CBFS region (11.5Mb available CBFS space)
#
# When flashing via an external programmer it is easiest to have
# two separate files for these pieces.
all: $(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-bottom.rom
$(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-bottom.rom: $(board_build)/$(CB_OUTPUT_FILE)
	$(call do,DD 8MB,$@,dd of=$@ if=$< bs=65536 count=128 skip=0 status=none)
	@sha256sum $@ | tee -a "$(HASHES)"

all: $(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-top.rom
$(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-top.rom: $(board_build)/$(CB_OUTPUT_FILE)
	$(call do,DD 4MB,$@,dd of=$@ if=$< bs=65536 count=64 skip=128 status=none)
	@sha256sum $@ | tee -a "$(HASHES)"
