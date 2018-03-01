#!/bin/sh
. /etc/functions

ROM="$1"
if [ -z "$1" ]; then
	die "Usage: $0 /media/kgpe-d16-openbmc.rom"
fi

cp "$ROM" /tmp/kgpe-d16-openbmc.rom
sha256sum /tmp/kgpe-d16-openbmc.rom

flashrom --programmer="ast1100:spibus=2,cpu=reset" -c "S25FL128P......0" -w /tmp/kgpe-d16-openbmc.rom \
|| die "$ROM: Flash failed"

warn "Reboot and hopefully it works..."
exit 0
