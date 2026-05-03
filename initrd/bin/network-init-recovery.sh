#!/bin/bash

. /etc/functions.sh

TRACE_FUNC

mobile_tethering()
{
	TRACE_FUNC
	#Tethering over USB for Mobile phones supporting CDC (Android Pixel 6a+, Librem phone, etc.)
	if [ -e /lib/modules/cdc_ether.ko ]; then
		#prompt user if he wants to enable USB tethering and skip if not
		INFO "USB tethering support is available for mobile phones supporting CDC NCM/EEM tethering"
		INPUT "Do you want to enable USB tethering now? (Y/n):" -n 1 -r REPLY
		if [[ $REPLY =~ ^[Nn]$ ]]; then
			DEBUG "USB tethering not enabled, skipping"
			return 0
		fi

		#first enable USB controllers
		enable_usb

		STATUS "Please connect your mobile phone to a USB port and enable internet connection sharing"
		STATUS "* Android: Select the 'Charging this device via USB' notification and enable tethering"
		STATUS "* Linux: Set the wired connection's IPv4 method on the mobile phone to 'Shared to other computers'"
		INFO "Heads supports CDC-NCM and CDC-EEM. Android phones using RNDIS and Apple phones are not supported"
		INPUT "Press Enter to continue..."

		network_modules="mii usbnet cdc_ether cdc_ncm cdc_eem"
		for module in $(echo $network_modules); do
			if [ -f /lib/modules/$module.ko ]; then
				insmod.sh /lib/modules/$module.ko
			fi
		done

		if ! [ -e /sys/class/net/usb0 ]; then
			WARN "No tethering network interface was found"
			INFO "* Make sure the phone supports CDC-NCM or CDC-EEM. Many, but not all, Android and Linux phones support these"
			INFO "* Android phones requiring RNDIS and Apple phones are not supported"
			INFO "* Make sure the cable used works with data and that the phone has tethering enabled"
			INPUT "Press Enter to continue..."
		fi
	fi
}

ethernet_activation()
{
	TRACE_FUNC
	#Prompt user if he wants to enable ethernet and skip if not
	INPUT "Do you want to enable Ethernet now? (Y/n):" -n 1 -r REPLY
	if [[ $REPLY =~ ^[Nn]$ ]]; then
		DEBUG "Ethernet not enabled, skipping"
		return 0
	fi

	STATUS "Loading Ethernet network modules"
	network_modules="e1000 e1000e igb sfc mdio mlx4_core mlx4_en"
	for module in $(echo $network_modules); do
		if [ -f /lib/modules/$module.ko ]; then
			insmod.sh /lib/modules/$module.ko
		fi
	done
	STATUS_OK "Ethernet network modules loaded"
}

# bring up the ethernet interface
ifconfig lo 127.0.0.1

mobile_tethering
ethernet_activation

if [ -e /sys/class/net/usb0 ]; then
	dev=usb0
	STATUS "USB tethering network interface detected as $dev"
elif [ -e /sys/class/net/eth0 ]; then
	dev=eth0
	STATUS "Ethernet network interface detected as $dev"
else
	WARN "No network interface detected, please check your hardware and board configuration"
	exit 1
fi

if [ -n "$dev" ]; then
	
	#Randomize MAC address for maximized boards
	if echo "$CONFIG_BOARD" | grep -q maximized; then
		ifconfig $dev down
		STATUS "Generating random MAC address"
		mac=$(generate_random_mac_address)
		STATUS "Assigning randomly generated MAC $mac to $dev"
		ifconfig $dev hw ether $mac
		ifconfig $dev up
	fi

	# Set up static IP if configured in board config
	if [ ! -z "$CONFIG_BOOT_STATIC_IP" ]; then
		STATUS "Setting static IP: $CONFIG_BOOT_STATIC_IP"
		ifconfig $dev $CONFIG_BOOT_STATIC_IP
		INFO "No NTP sync with static IP: no DNS server or gateway defined, set time manually"
	# Set up DHCP if no static IP
	elif [ -e /sbin/udhcpc ]; then
		STATUS "Getting IP from DHCP server (this may take a while)"
		if udhcpc -T 1 -i $dev -q; then
			if [ -e /sbin/ntpd ]; then
				DNS_SERVER=$(grep nameserver /etc/resolv.conf | awk -F " " {'print $2'})
				killall ntpd 2 &>1 >/dev/null
				STATUS "Attempting NTP time sync with $DNS_SERVER"
				if ! ntpd -d -N -n -q -p $DNS_SERVER; then
					WARN "NTP sync unsuccessful with DNS server"
					STATUS "Attempting NTP time sync with pool.ntp.org"
					if ! ntpd -d -d -N -n -q -p pool.ntp.org; then
						WARN "NTP sync unsuccessful"
					else
						STATUS_OK "NTP time sync successful"
					fi
				fi
			STATUS "Syncing hardware clock with system time (UTC)"
			hwclock -w
			date=$(date "+%Y-%m-%d %H:%M:%S %Z")
			STATUS_OK "Hardware clock synced: $date"
			fi
		fi
	fi

	if [ -e /bin/dropbear ]; then
		# Set up the ssh server, allow root logins and log to stderr
		if [ ! -d /etc/dropbear ]; then
			mkdir /etc/dropbear
		fi
		STATUS "Starting dropbear SSH server"
		# Make sure dropbear is not already running
		killall dropbear > /dev/null 2>&1 || true
		# Start dropbear with root login and log to stderr
		# -B background
		# -R create host keys
		dropbear -B -R
		STATUS_OK "Dropbear SSH server started"
	fi
	STATUS_OK "Network setup complete"
	ifconfig $dev
fi
