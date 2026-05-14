#!/bin/bash
# Parse boot loader configs (GRUB, syslinux, ISOLINUX) to extract boot entries
#
# This script parses boot configuration files to build a list of boot entries
# that can be used by kexec-boot.sh to boot an OS. It handles:
# - GRUB config files (grub.cfg)
# - SYSLINUX/ISOLINUX config files (isolinux.cfg, syslinux.cfg)
# - Multiboot kernels (Xen)
#
# Output format: name|kexectype|kernel path[|initrd path][|append params]
#
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
	if [ "${path:0:1}" != "/" ]; then
		DEBUG "fix_path: path was $@"
		path="$appenddir/$path"
		DEBUG "fix_path: path is now $path"
	fi
}

# GRUB kernel lines (linux/multiboot) can include a command line.  Check whether
# the file path exists in $bootdir.
check_path() {
	local checkpath firstval
	checkpath="$1"
	firstval="$(echo "$checkpath" | cut -d\  -f1)"
	if ! [ -r "$bootdir$firstval" ]; then
		DEBUG "parse-boot: check_path $bootdir$firstval not found"
		return 1
	fi
	return 0
}

echo_entry() {
	if [ -z "$kernel" ]; then return; fi

	fix_path $kernel
	check_path "$path" 2>/dev/null || {
		# Keep entries with unresolved GRUB variables (e.g. ${iso_path})
		# since they may resolve at kexec time. Skip genuinely missing files.
		echo "$path" | grep -qE '\$\{?[a-zA-Z_][a-zA-Z0-9_]*\}?' || return
	}
	name=$(echo "$name" | tr -d '|')
	entry="$name|$kexectype|kernel $path"

	case "$kexectype" in
		elf)
			if [ -n "$initrd" ]; then
				for init in $(echo $initrd | tr ',' ' '); do
					fix_path $init
					check_path "$path" 2>/dev/null || {
						echo "$path" | grep -qE '\$\{?[a-zA-Z_][a-zA-Z0-9_]*\}?' || return
					}
					entry="$entry|initrd $path"
				done
			fi
			if [ -n "$append" ]; then
				entry="$entry|append $append"
			fi
			;;
		multiboot|xen)
			entry="$entry$modules"
			;;
		*)
			return
			;;
	esac

	# entry is logged at LOG level via DO_WITH_DEBUG's stdout capture
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

	trimcmd=$(echo $line | tr '\t ' ' ' | tr -s ' ')
	cmd=$(echo "$trimcmd" | sed 's/^[[:space:]]*//' | cut -d\  -f1)
	val=$(echo "$trimcmd" | sed 's/^[[:space:]]*//' | cut -d\  -f2-)
	case $cmd in
		multiboot*)
			kexectype="xen"
			kernel="$val"
			DEBUG "parse-boot: multiboot kernel=$kernel"
			;;
		module*)
			case $val in
				--nounzip*) val=$(echo $val | cut -d\  -f2-) ;;
			esac
			fix_path $val
			modules="$modules|module $path"
			;;
		linux*)
			DEBUG "parse-boot: linux line: $trimcmd"
			kernel=$(echo $trimcmd | sed "s/([^)]*)//g" | cut -d\  -f2)
			append=$(echo $trimcmd | cut -d\  -f3-)
			# Strip GRUB bootloader marker "---" used as append/initrd separator
			append=$(echo "$append" | sed 's|[[:space:]]*---[[:space:]]*| |g' | sed 's|^ ||;s| $||')
			;;
		initrd*)
			initrd="$(echo "$val" | sed "s/([^)]*)//g")"
			DEBUG "parse-boot: initrd=$initrd"
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
	while read line
	do
		if [ -z "$kernel" ]; then
			kernel="$line"
		else
			fix_path $line
			modules="$modules|module $path"
		fi
	done << EOF
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

	trimcmd=$(echo $line | tr '\t ' ' ' | tr -s ' ')
	cmd=$(echo "$trimcmd" | sed 's/^[[:space:]]*//' | cut -d\  -f1)
	val=$(echo "$trimcmd" | sed 's/^[[:space:]]*//' | cut -d\  -f2-)
	case $trimcmd in
		menu* | MENU* )
			cmd2=$(echo $trimcmd | cut -d \  -f2)
			if [ "$cmd2" = "label" -o "$cmd2" = "LABEL" ]; then
				name=$(echo $trimcmd | cut -c11- | tr -d '^')
			fi
			;;
		linux* | LINUX* | kernel* | KERNEL* )
			case $val in
				# TODO: differentiate between Xen and other multiboot kernels
				*mboot.c32) kexectype="xen" ;;
				*.c32)
					# skip this entry
					state="search"
					;;
				*)
					kernel="$val"
					DEBUG "parse-boot: syslinux kernel=$kernel"
					;;
			esac
			;;
		initrd* | INITRD* )
			initrd="$val"
			DEBUG "parse-boot: syslinux initrd=$initrd"
			;;
		append* | APPEND* )
			if [ "$kexectype" = "multiboot" -o "$kexectype" = "xen" ]; then
				syslinux_multiboot_append
			else
				append="$val"
				DEBUG "parse-boot: syslinux append=$append"
			fi
			;;
	esac
}

state="search"
while read line
do
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
done < "$file"

# handle EOF case
if [ "$state" = "syslinux" ]; then
	syslinux_end
fi
