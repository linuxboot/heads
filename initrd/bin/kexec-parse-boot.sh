#!/bin/bash
set -e -o pipefail
. /etc/functions.sh

bootdir="$1"
file="$2"

if [ -z "$bootdir" -o -z "$file" ]; then
	DIE "Usage: $0 /boot /path/to/config.cfg"
fi

reset_entry() {
	name=""
	kexectype="elf"
	kernel=""
	initrd=""
	modules=""
	append=""
}

filedir=$(dirname $file)
bootdir="${bootdir%%/}"
bootlen="${#bootdir}"
appenddir="${filedir:$bootlen}"

fix_path() {
	path="$@"
}

# GRUB kernel lines (linux/multiboot) can include a command line.  Check whether
# the file path exists in $bootdir.
check_path() {
	local checkpath firstval
	checkpath="$1"
	firstval="$(echo "$checkpath" | cut -d\  -f1)"
	if ! [ -r "$bootdir$firstval" ]; then
		return 1
	fi
	return 0
}

echo_entry() {
	if [ -z "$kernel" ]; then return; fi

	fix_path $kernel
	check_path "$path" 2>/dev/null || true
	entry="$name|$kexectype|kernel $path"

	case "$kexectype" in
	elf)
		if [ -n "$initrd" ]; then
			for init in $(echo $initrd | tr ',' ' '); do
				fix_path $init
				check_path "$path" 2>/dev/null || true
				entry="$entry|initrd $path"
			done
		fi
		if [ -n "$append" ]; then
			entry="$entry|append $append"
		fi
		;;
	multiboot | xen)
		entry="$entry$modules"
		;;
	*)
		return
		;;
	esac

	echo $(eval "echo \"$entry\"")
}

search_entry() {
	case $line in
	menuentry* | MENUENTRY*)
		state="grub"
		reset_entry
		name=$(echo $line | tr "'" "\"" | cut -d\" -f 2)
		;;

	label* | LABEL*)
		state="syslinux"
		reset_entry
		name=$(echo $line | cut -c6-)
		;;
	esac
}

grub_entry() {
	if [ "$line" = "}" ]; then
		echo_entry
		state="search"
		return
	fi

	# add info to menuentry
	trimcmd=$(echo $line | tr '\t ' ' ' | tr -s ' ')
	cmd=$(echo "$trimcmd" | sed 's/^[[:space:]]*//' | cut -d\  -f1)
	val=$(echo "$trimcmd" | sed 's/^[[:space:]]*//' | cut -d\  -f2-)
	case $cmd in
	multiboot*)
		# TODO: differentiate between Xen and other multiboot kernels
		kexectype="xen"
		kernel="$val"
		;;
	module*)
		case $val in
		--nounzip*) val=$(echo $val | cut -d\  -f2-) ;;
		esac
		fix_path $val
		modules="$modules|module $path"
		;;
	linux*)
		# Some configs have a device specification in the kernel
		# or initrd path.  Assume this would be /boot and remove
		# it.  Keep the '/' following the device, since this
		# path is relative to the device root, not the config
		# location.
		kernel=$(echo $trimcmd | sed "s/([^)]*)//g" | cut -d\  -f2)
		append=$(echo $trimcmd | cut -d\  -f3-)

		# Strip unresolved GRUB variables that would expand to empty and break kexec.
		# These create malformed params like "iso-scan/filename=" with orphaned paths.
		# Also strip ISO boot parameters that are injected via -a by kexec-iso-init.sh
		# so they don't clutter the boot entry display. They are added to the kexec
		# command separately via cmdadd.
		append=$(echo "$append" | sed \
			-e 's|iso-scan/filename=${[^}]*}| |g' \
			-e 's|iso-scan/filename=$[a-zA-Z_][a-zA-Z0-9_]*| |g' \
			-e 's|iso-scan/filename=| |g' \
			-e 's|findiso=${[^}]*}| |g' \
			-e 's|findiso=$[a-zA-Z_][a-zA-Z0-9_]*| |g' \
			-e 's|findiso=| |g' \
			-e 's|fromiso=[^ ]*| |g' \
			-e 's|img_dev=[^ ]*| |g' \
			-e 's|img_loop=[^ ]*| |g' \
			-e 's|iso=[^ ]*| |g' \
			-e 's|live-media=[^ ]*| |g' \
			-e 's|  *| |g' \
			-e 's|^ ||' \
			-e 's| $||')
		# Strip GRUB bootloader marker "---" (used by Ubuntu) used as append/initrd separator
		append=$(echo "$append" | sed 's|[[:space:]]*---[[:space:]]*| |g' | sed 's|^ ||;s| $||')

		;;
	initrd*)
		# Trim off device specification as above
		initrd="$(echo "$val" | sed "s/([^)]*)//g")"
		;;
	esac
}

syslinux_end() {
	# finish menuentry

	# attempt to parse out of append if missing initrd
	if [ -z "$initrd" ]; then
		newappend=""
		for param in $append; do
			case $param in
			initrd=*)
				initrd="${param#initrd=}"
				;;
			*) newappend="$newappend $param" ;;
			esac
		done
		append="${newappend##' '}"
	fi

	appenddir="$(echo $appenddir | cut -d\/ -f -2)"
	echo_entry
	state="search"
}

syslinux_multiboot_append() {
	splitval=$(echo "${val// --- /|}" | tr '|' '\n')
	while read line; do
		if [ -z "$kernel" ]; then
			kernel="$line"
		else
			fix_path $line
			modules="$modules|module $path"
		fi
	done <<EOF
$splitval
EOF
}

syslinux_entry() {
	case $line in
	"")
		syslinux_end
		return
		;;
	label* | LABEL*)
		syslinux_end
		search_entry
		return
		;;
	esac

	# add info to menuentry
	trimcmd=$(echo $line | tr '\t ' ' ' | tr -s ' ')
	cmd=$(echo "$trimcmd" | sed 's/^[[:space:]]*//' | cut -d\  -f1)
	val=$(echo "$trimcmd" | sed 's/^[[:space:]]*//' | cut -d\  -f2-)
	case $cmd in
	menu* | MENU*)
		cmd2=$(echo $trimcmd | cut -d \  -f2)
		if [ "$cmd2" = "label" -o "$cmd2" = "LABEL" ]; then
			name=$(echo $trimcmd | cut -c11- | tr -d '^')
		fi
		;;
	linux* | LINUX* | kernel* | KERNEL*)
		case $val in
		*mboot.c32) kexectype="xen" ;;
		*.c32)
			state="search"
			;;
		*)
			kernel="$val"
			;;
		esac
		;;
	initrd* | INITRD*)
		initrd="$val"
		;;
	append* | APPEND*)
		if [ "$kexectype" = "multiboot" -o "$kexectype" = "xen" ]; then
			syslinux_multiboot_append
		else
			append="$val"
		fi
		;;
	esac
}

state="search"
while read line; do
	case $state in
	search)
		search_entry
		;;
	grub)
		grub_entry
		;;
	syslinux)
		syslinux_entry
		;;
	esac
done <"$file"

# handle EOF case
if [ "$state" = "syslinux" ]; then
	syslinux_end
fi
