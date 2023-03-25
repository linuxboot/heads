#!/bin/bash

# Set the EC BRAM setting for automatic power-on.
# If $1 is 'y', enable automatic power-on.  Otherwise, disable it.

# EC BRAM bank 1
BRAMADDR=0x360
BRAMDATA=0x361

outb "$BRAMADDR" 0x29 # Select byte at offset 29h
if [ "$1" = "y" ]; then
	outb "$BRAMDATA" 0x00 # 0 -> automatic power-on
else
	outb "$BRAMDATA" 0x01 # 1 -> stay off
fi

