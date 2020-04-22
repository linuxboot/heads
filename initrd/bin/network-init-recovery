#!/bin/ash

# bring up the ethernet; maybe should do DHCP?
ifconfig lo 127.0.0.1

network_modules="e1000 e1000e igb sfc mdio mlx4_core mlx4_en"
for module in `echo $network_modules`; do
	if [ -f /lib/modules/$module.ko ]; then
		insmod /lib/modules/$module.ko
	fi
done

if [ -e /sys/class/net/eth0 ]; then
	# Set up static IP
	if [ ! -z "$CONFIG_BOOT_STATIC_IP" ]; then
		ifconfig eth0 $CONFIG_BOOT_STATIC_IP
	#Get ip from DHCP
	elif [ -e /sbin/udhcpc ];then
		if udhcpc -T 1 -q; then
			if [ -e /sbin/ntpd ]; then
				DNS_SERVER=$(grep nameserver /etc/resolv.conf|awk -F " " {'print $2'})
				killall ntpd 2&>1 > /dev/null
		 		if ! ntpd -d -N -n -q -p $DNS_SERVER > /dev/ttyprintk; then
					if ! ntpd -d -d -N -n -q -p ntp.pool.org> /dev/ttyprintk; then
						echo "NTP sync unsuccessful." > /dev/tty0
					fi
				fi
				hwclock -w
				echo "" > /dev/tty0
				echo "UTC/GMT current date and time:" > /dev/tty0
				date > /dev/tty0
			fi
		fi		 
	fi
	
	ifconfig eth0 > /dev/ttyprintk
	
	if [ -e /bin/dropbear ]; then
		# Set up the ssh server, allow root logins and log to stderr
		if [ ! -d /etc/dropbear ]; then
			mkdir /etc/dropbear
		fi
		dropbear -B -R 2>/dev/ttyprintk
	fi
	echo  "" > /dev/tty0
	ifconfig eth0 | head -2 > /dev/tty0
fi
