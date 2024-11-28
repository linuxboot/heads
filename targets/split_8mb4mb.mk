# Many Lenovo boards have two SPI flash chips, an 8 MB that holds the IFD,
# the ME image and part of the coreboot image, and a 4 MB one that
# has the rest of the coreboot and the reset vector.
#
# As a consequence, this replaces the need of having to flash a legacy-flash ROM
#  and expands available CBFS region (11.5Mb available CBFS space)
#
# When flashing via an external programmer it is easiest to have
# two separate files for these pieces.
all: bottom top

bottom: $(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-bottom.rom

$(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-bottom.rom: $(board_build)/$(CB_OUTPUT_FILE) FORCE
	@rm -f $(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-bottom.rom
	$(call do,DD 8MB,$(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-bottom.rom,dd if=$< of=$@ bs=65536 count=128 skip=0 status=none)
	@sha256sum $(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-bottom.rom | tee -a "$(HASHES)"
	@stat -c "%8s:%n" $(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-bottom.rom | tee -a "$(SIZES)"

top: $(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-top.rom

$(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-top.rom: $(board_build)/$(CB_OUTPUT_FILE) FORCE
	@rm -f $(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-top.rom
	$(call do,DD 4MB,$(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-top.rom,dd if=$< of=$@ bs=65536 count=64 skip=128 status=none)
	@sha256sum $(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-top.rom | tee -a "$(HASHES)"
	@stat -c "%8s:%n" $(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-top.rom | tee -a "$(SIZES)"

FORCE:

.PHONY: all bottom top FORCE
