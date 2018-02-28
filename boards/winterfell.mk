
$(build)/$(BOARD)/linuxboot.rom: linuxboot.intermediate

# No 0x on these since the flasher doesn't handle that
dxe_offset := 860000
dxe_size := 6a0000
flash-dxe: $(build)/$(BOARD)/linuxboot.rom
	( echo u$(dxe_offset) $(dxe_size) ; \
	pv $(build)/linuxboot-git/build/$(BOARD)/dxe.vol \
	) > /dev/ttyACM0

flash: $(build)/$(BOARD)/linuxboot.rom
	( echo u0 1000000 ; \
	pv $< \
	) > /dev/ttyACM0
