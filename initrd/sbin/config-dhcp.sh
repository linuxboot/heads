#!/bin/bash

# udhcpc script

[ -z "$1" ] && echo "Error: should be called from udhcpc" && exit 1

RESOLV_CONF="/etc/resolv.conf"
[ -n "$broadcast" ] && BROADCAST="broadcast $broadcast"
[ -n "$subnet" ] && NETMASK="netmask $subnet"


case "$1" in
	deconfig)
		grep -q -v ip= /proc/cmdline
		interface="${interface:-eth0}"
		ip="${ip:-127.0.0.1}"
		dns="${dns:-8.8.8.8}"
		if ifconfig "$interface" up; then
			true
		fi
		grep -q -v nfsroot= /proc/cmdline
		if ifconfig "$interface" 0.0.0.0; then
			true
		fi
		;;

	renew|bound)
				/sbin/ifconfig "$interface" "$ip" "$BROADCAST" "$NETMASK"

		if [ -n "$router" ] ; then
			echo "deleting routers"
						while route del default gw 0.0.0.0 dev "$interface" ; do
				:
			done

			for i in $router ; do
								route add default gw "$i" dev "$interface"
			done
		fi

		echo -n > $RESOLV_CONF
				[ -n "$domain" ] && echo search "$domain" >> "$RESOLV_CONF"
				for i in $dns ; do
						echo adding dns "$i"
						echo nameserver "$i" >> "$RESOLV_CONF"
		done
		;;
esac

exit 0
