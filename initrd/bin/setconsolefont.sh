#!/bin/bash

set -eo pipefail
. /etc/functions

TRACE_FUNC

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

# Deciding scale based on resolution is inherently heuristic, as the scale
# really depends on resolution, physical size, how close the display is to the
# user, and personal preference.
#
# fbwhiptail starts using 1.5x scale at 1350 lines, but we can only choose 1x
# or 2x (without shipping more fonts).  Err toward making the console too large
# rather than too small and go to 2x at 1350 lines.
if [ "$CONSOLE_HEIGHT" -ge 1350 ]; then
	DEBUG "Double console font size due to framebuffer height $CONSOLE_HEIGHT"
	# Double the default font size by reading it out, then applying it again
	# with setfont's -d option (double font size)
	setfont -O /tmp/default_font
	setfont -d /tmp/default_font
	rm /tmp/default_font
else
	DEBUG "Keep default console font size due to framebuffer height $CONSOLE_HEIGHT"
fi
