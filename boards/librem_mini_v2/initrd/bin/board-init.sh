#!/bin/ash
set -o pipefail

. /tmp/config

# Set the Mini v2 EC's automatic power-on setting.
# CONFIG_AUTOMATIC_POWERON is three-valued:
# y - enable automatic power on in EC
# n - disable automatic power on in EC
# <blank> - don't configure EC, could be configured from OS

# EC BRAM bank 1
BRAMADDR=0x360
BRAMDATA=0x361

if [ "$CONFIG_AUTOMATIC_POWERON" = "y" ]; then
	outb "$BRAMADDR" 0x29	# Select byte at offset 29h
	outb "$BRAMDATA" 0x00	# 0 -> automatic power on
elif [ "$CONFIG_AUTOMATIC_POWERON" = "n" ]; then
	outb "$BRAMADDR" 0x29	# Select byte at offset 29h
	outb "$BRAMDATA" 0x01	# 1 -> stay off
fi
