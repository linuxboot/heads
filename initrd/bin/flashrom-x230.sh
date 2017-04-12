#!/bin/sh
. /etc/functions

ROM="$1"
if [ -z "$1" ]; then
	die "Usage: $0 /media/x230.rom"
fi

cp "$ROM" /tmp/x230.rom
sha256sum /tmp/x230.rom

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
