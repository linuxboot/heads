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

# --- kexec-parse-boot.sh ---
# Parses GRUB and SYSLINUX boot config files to extract boot entries.
#
# Input:  bootdir  config_file
# Output: name|kexectype|kernel path[|initrd path][|append params]
#   One line per boot entry, pipe-delimited.  Used by kexec-select-boot.sh
#   to present a boot menu and by collect_initramfs_paths() to find initrds.
#
# Path resolution: SYSLINUX kernel/initrd paths are relative to the config
#   file's directory.  fix_path() resolves them by prepending the config
#   file's directory path (appenddir).  This must be done before the
#   appenddir truncation in syslinux_end().
#
# appenddir lifecycle:
#   - Set at startup to the config file's path relative to bootdir
#     (e.g. "boot/x86_64/loader" for /boot/x86_64/loader/isolinux.cfg)
#   - syslinux_end() truncates it to the parent directory for echo_entry()
#     (heuristic: syslinux often puts kernel one level above the config)
#   - The saved copy is restored after echo_entry() so the next label
#     resolves against the FULL path, not the truncated one.
#   - See https://github.com/linuxboot/heads/issues/... for openSUSE
#     Tumbleweed case (config 3 levels deep: boot/x86_64/loader/).

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
	path="$*"
	if [ "${path:0:1}" != "/" ]; then
		DEBUG "fix_path: path was $*"
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
	if [ -z "$kernel" ]; then return 0; fi

	fix_path $kernel
	if ! check_path "$path" 2>/dev/null; then
		# Keep entries with unresolved GRUB variables (e.g. ${iso_path})
		# since they may resolve at kexec time. Skip genuinely missing files.
		if ! echo "$path" | grep -qE '\$\{?[a-zA-Z_][a-zA-Z0-9_]*\}?' 2>/dev/null; then
			return 0
		fi
	fi
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

	# entry is logged at LOG level via DO_WITH_DEBUG's stdout capture.
	# eval expands any remaining GRUB ${} references into empty strings
	# before writing the entry  --  Heads does not resolve GRUB variables;
	# layer 2 loopback.cfg falls through to universal ADD params when
	# var references are present.
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
	# Finish processing the current syslinux label and emit its entry.
	# Kernel/initrd paths are resolved against the full config directory
	# by echo_entry()'s fix_path.  No appenddir truncation is needed:
	# relative paths like "../vmlinuz" produce "dir/../vmlinuz" which
	# the filesystem resolves correctly.  Truncation broke multi-level
	# config dirs (e.g. openSUSE boot/x86_64/loader/).

	# Parse initrd from append string if no separate initrd directive was given.
	# openSUSE's gfxboot puts "initrd=initrd" inside the append line.
	if [ -z "$initrd" ]; then
		local newappend=""
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
