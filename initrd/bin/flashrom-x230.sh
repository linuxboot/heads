#!/bin/sh
. /etc/functions

if [ "$1" = "-c" ]; then
	CLEAN=1
	ROM="$2"
else
	CLEAN=0
	ROM="$1"
fi

if [ ! -e "$ROM" ]; then
	die "Usage: $0 [-c] /media/x230.rom"
fi

cp "$ROM" /tmp/x230.rom
sha256sum /tmp/x230.rom
if [ "$CLEAN" -eq 0 ]; then
	preserve_rom /tmp/x230.rom \
	|| die "$ROM: Config preservation failed"
fi

flashrom \
	--force \
	--noverify \
	--programmer internal \
	--layout /etc/x230-layout.txt \
	--image BIOS \
	-w /tmp/x230.rom \
|| die "$ROM: Flash failed"

warn "Reboot and hopefully it works..."
exit 0
