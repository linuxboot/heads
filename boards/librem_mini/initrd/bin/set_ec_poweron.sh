#!/bin/bash

# Set the EC BRAM setting for automatic power-on.
# If $1 is 'y', enable automatic power-on.  Otherwise, disable it.

# EC BRAM bank 1
BRAMADDR=0x360
BRAMDATA=0x361

if [ "$1" = "y" ]; then
	BRAM_VALUE="0x00" # 0 -> automatic power-on
else
	BRAM_VALUE="0x01" # 1 -> stay off
fi

outb "$BRAMADDR" 0x29 # Select byte at offset 29h
outb "$BRAMDATA" "$BRAM_VALUE"
# There's also a 16-bit checksum at offset 3eh in bank 1.  The only byte
# included in the checksum is the automatic power-on setting, so the value is
# the same, and the upper 8 bits remain 0.
outb "$BRAMADDR" 0x3e
outb "$BRAMDATA" "$BRAM_VALUE"
