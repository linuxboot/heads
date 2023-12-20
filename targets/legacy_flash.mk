# legacy-flash boards are "special" in that we need a 4MB top SPI flashable ROM.
# This is enough to allow the board to boot into a minimal Heads and read the full Legacy
# ROM from an external USB media.
#
# No tools outside of flashrom are provided here as you can see per activated modules above.
# Everything Heads is now delegated to the Legacy ROM to be flashed
# from xx30-flash ROMs.
#
# Instructions to mount USB thumb drive and flash legacy 12Mb image will be given on screen
# per CONFIG_BOOTSCRIPT script above.
#
# Below, we just move produced ROM with a name appended with -top.rom for clarity.
all: $(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-top.rom
$(board_build)/heads-$(BOARD)-$(HEADS_GIT_VERSION)-top.rom: $(board_build)/$(CB_OUTPUT_FILE)
	$(call do,MV 4MB top ROM,$@, mv $< $@)
	@sha256sum $@
