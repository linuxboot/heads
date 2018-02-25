run: coreboot.intermediate
run: $(build)/$(BOARD)/coreboot.rom
	qemu-system-x86_64 \
		--machine q35 \
		--bios $< \
