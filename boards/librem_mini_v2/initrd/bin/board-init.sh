#!/bin/bash
set -o pipefail

. /tmp/config

# If CONFIG_AUTOMATIC_POWERON is set, always set the EC BRAM setting during
# boot.  It persists as long as the RTC battery is set, but set it during every
# boot for robustness in case the battery is temporarily removed, or the user
# toggles in config-gui and then does not flash, etc.
if [ "$CONFIG_AUTOMATIC_POWERON" = "y" ]; then
	set_ec_poweron.sh y
fi

# Don't disable the setting in the EC BRAM though if CONFIG_AUTOMATIC_POWERON
# is not enabled.  The default is disabled anyway, and the OS could configure
# it.
