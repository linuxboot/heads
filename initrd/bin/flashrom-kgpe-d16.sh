#!/bin/sh
. /etc/functions

ROM="$1"
if [ -z "$1" ]; then
	die "Usage: $0 /media/kgpe-d16.rom"
fi

cp "$ROM" /tmp/kgpe-d16.rom
sha256sum /tmp/kgpe-d16.rom

flashrom \
	--force \
	--noverify \
	--programmer internal \
	-w /tmp/kgpe-d16.rom \
|| die "$ROM: Flash failed"

warn "Reboot and hopefully it works..."
exit 0
