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
	die "Usage: $0 [-c] /media/kgpe-d16.rom"
fi

cp "$ROM" /tmp/kgpe-d16.rom
sha256sum /tmp/kgpe-d16.rom
if [ "$CLEAN" -eq 0 ]; then
	preserve_rom /tmp/kgpe-d16.rom \
	|| die "$ROM: Config preservation failed"
fi

flashrom \
	--force \
	--noverify \
	--programmer internal \
	-w /tmp/kgpe-d16.rom \
|| die "$ROM: Flash failed"

warn "Reboot and hopefully it works..."
exit 0
