#!/bin/bash

set -eo pipefail
. /etc/functions

TRACE "Under /bin/setconsolefont.sh"

# If the board ships setfont, and the console size is >=1600 lines tall,
# increase the console font size.
if [ ! -x /bin/setfont ]; then
	DEBUG "Board does not ship setfont, not checking console font"
	exit 0
fi

if [ ! -f /sys/class/graphics/fb0/virtual_size ]; then
	DEBUG "fb0 virtual size is not known"
	exit 0
fi

CONSOLE_HEIGHT="$(cut -d, -f2 /sys/class/graphics/fb0/virtual_size)"

if [ "$CONSOLE_HEIGHT" -ge 1600 ]; then
	DEBUG "Double console font size due to framebuffer height $CONSOLE_HEIGHT"
	# Double the default font size by reading it out, then applying it again
	# with setfont's -d option (double font size)
	setfont -O /tmp/default_font
	setfont -d /tmp/default_font
	rm /tmp/default_font
else
	DEBUG "Keep default console font size due to framebuffer height $CONSOLE_HEIGHT"
fi
