#!/bin/bash
# Execute kexec to boot an OS kernel from parsed boot configuration
#
# This script takes a boot entry (from kexec-parse-boot.sh) and executes
# kexec to load and boot the OS kernel. It handles:
# - ELF kernels (standard Linux)
# - Multiboot kernels (Xen)
# - Initial ramdisks (initrd)
# - Kernel command line modification (add/remove parameters)
#
# Options:
#   -b  Boot directory (e.g., /boot)
#   -e  Entry string (name|kexectype|kernel path[|initrd][|append])
#   -r  Parameters to remove from cmdline
#   -a  Parameters to add to cmdline
#   -o  Override initrd path
#   -f  Dry run: print files only
#   -i  Dry run: print initrd only
#
set -e -o pipefail
. /tmp/config
. /etc/functions.sh

dryrun="n"
printfiles="n"
printinitrd="n"
	while getopts "b:e:r:a:o:fi" arg; do
		case $arg in
		b) bootdir="$OPTARG" ;;
		e) entry="$OPTARG" ;;
		r) cmdremove="$OPTARG" ;;
		a) cmdadd="$OPTARG" ;;
		o) override_initrd="$OPTARG" ;;
		f) dryrun="y"; printfiles="y" ;;
		i) dryrun="y"; printinitrd="y" ;;
		esac
	done

	if [ -z "$bootdir" -o -z "$entry" ]; then
		DIE "Usage: $0 -b /boot -e 'kexec params|...|...'"
	fi

	bootdir="${bootdir%%/}"

	kexectype=$(echo $entry | cut -d\| -f2)
	kexecparams=$(echo $entry | cut -d\| -f3- | tr '|' '\n')
	kexeccmd="kexec"

	DEBUG "kexec-boot: entry='$entry'"
	DEBUG "kexec-boot: kexectype='$kexectype'"
	DEBUG "kexec-boot: kexecparams='$kexecparams'"
	DEBUG "kexec-boot: cmdadd='$cmdadd'"

cmdremove="$CONFIG_BOOT_KERNEL_REMOVE $cmdremove"

if [ "$(load_config_value CONFIG_USE_BLOB_JAIL)" = "y" ]; then
	cmdadd="$cmdadd firmware_class.path=/firmware/"
fi

fix_file_path() {
	if [ "$printfiles" = "y" ]; then
		# output file relative to local boot directory
		echo ".$firstval"
	fi

	filepath="$bootdir$firstval"

	if ! [ -r $filepath ]; then
		DIE "Failed to find file $firstval"
	fi
}

adjusted_cmd_line="n"
adjust_cmd_line() {
	TRACE_FUNC
	DEBUG "adjust_cmd_line: original cmdline='$cmdline'"
	# Strip the GRUB '---' separator (not a kernel param) but keep
	# everything after it  --  those are initramfs params for the target OS.
	cmdline=$(echo "$cmdline" | sed 's/ --- / /g;s/^--- //g;s/ ---$//g' | xargs)
	DEBUG "adjust_cmd_line: after removing --- separator='$cmdline'"
	cmdline=$(_build_final_cmdline "$cmdline" "${cmdadd:-}" "${cmdremove:-}" "$CONFIG_BOOT_KERNEL_ADD")
	DEBUG "adjust_cmd_line: after _build_final_cmdline='$cmdline'"
	adjusted_cmd_line="y"
}

if [ "$CONFIG_DEBUG_OUTPUT" = "y" ];then
	#If expecting debug output, have kexec load (-l) output debug info
	kexeccmd="$kexeccmd -d"
fi

module_number="1"
# Track whether the kernel line had command-line arguments (e.g. restval
# is non-empty for Linux kernels, empty for standalone ELF binaries such
# as memtest86+).  Used below to avoid forcing --append=$cmdadd on ELF
# binaries that take no kernel arguments.
kernel_had_args=""
while read line; do
	key=$(echo $line | cut -d\  -f1)
	firstval=$(echo $line | cut -d\  -f2)
	restval=$(echo $line | cut -d\  -f3-)
	if [ "$key" = "kernel" ]; then
		kernel_had_args="$restval"
		fix_file_path
		if [ "$kexectype" = "xen" ]; then
			# always use xen with custom arguments
			kexeccmd="$kexeccmd -l $filepath"
			kexeccmd="$kexeccmd --command-line \"$restval no-real-mode reboot=no vga=current\""
		elif [ "$kexectype" = "multiboot" ]; then
			kexeccmd="$kexeccmd -l $filepath"
			kexeccmd="$kexeccmd --command-line \"$restval\""
		elif [ "$kexectype" = "elf" ]; then
			DEBUG "kexectype= $kexectype"
			DEBUG "restval= $restval"
			DEBUG "filepath= $filepath"
			kexeccmd="$kexeccmd -l $filepath"
			DEBUG "kexeccmd= $kexeccmd"
		else
			DEBUG "unknown kexectype"
			kexeccmd="$kexeccmd -l $filepath"
		fi
	fi
	if [ "$key" = "module" ]; then
		fix_file_path
		cmdline="$restval"
		if [ "$kexectype" = "xen" ]; then
			if [ "$module_number" -eq 1 ]; then
				adjust_cmd_line
			elif [ "$module_number" -eq 2 ]; then
				if [ "$printinitrd" = "y" ]; then
					# output the current path to initrd
					echo $filepath
				fi
				if [ -n "$override_initrd" ]; then
					filepath="$override_initrd"
				fi
			fi
		fi
		module_number=$((module_number + 1))
		kexeccmd="$kexeccmd --module \"$filepath $cmdline\""
	fi
	if [ "$key" = "initrd" ]; then
		fix_file_path
		if [ "$printinitrd" = "y" ]; then
			# output the current path to initrd
			echo $filepath
		fi
		if [ -n "$override_initrd" ]; then
			filepath="$override_initrd"
		fi
		firmware_initrd="$(inject_firmware.sh "$filepath" || true)"
		if [ -n "$firmware_initrd" ]; then
			filepath="$firmware_initrd"
		fi
		kexeccmd="$kexeccmd --initrd=$filepath"
	fi
	if [ "$key" = "append" ]; then
		cmdline="$firstval $restval"
		adjust_cmd_line
		kexeccmd="$kexeccmd --append=\"$cmdline\""
	fi
done << EOF
$kexecparams
EOF

if [ "$adjusted_cmd_line" = "n" ]; then
	if [ "$kexectype" = "elf" ]; then
		# Only pass $cmdadd if the kernel line had arguments --
		# standalone ELF binaries (e.g. memtest86+) take no kernel
		# command line and adding --append with ISO params breaks kexec.
		if [ -n "$kernel_had_args" ]; then
			kexeccmd="$kexeccmd --append=\"$cmdadd\""
		fi
	else
		DIE "Failed to add required kernel commands: $cmdadd"
	fi
fi

if [ "$dryrun" = "y" ]; then exit 0; fi

DEBUG "kexec-boot: cmdadd='$cmdadd'"
DEBUG "kexec-boot: cmdremove='$cmdremove'"
DEBUG "kexec-boot: final cmdline='$cmdline'"

# Kernel command line length limit is typically 2047 bytes (CONFIG_COMMAND_LINE_SIZE).
# If the final cmdline exceeds this, warn before attempting kexec.
cmdline_len=${#cmdline}
if [ "$cmdline_len" -gt 2047 ]; then
	WARN "Kernel command line is $cmdline_len bytes, kernel limit is 2047. USB boot may fail."
	WARN "Check for duplicate kernel options in the ISO's boot configuration."
	WARN "Report to ISO distributor: duplicate options waste command line space."
fi

STATUS "Loading the new kernel"
DEBUG "kexec command: $kexeccmd"
DO_WITH_DEBUG eval "$kexeccmd" \
|| DIE "Failed to load the new kernel${cmdline_len:+ (cmdline length: $cmdline_len bytes, kernel limit typically 2047)}"

if [ "$CONFIG_DEBUG_OUTPUT" = "y" ];then
	#Ask user if they want to continue booting without echoing back the input (-s)
	INPUT "[DEBUG] Continue booting? [Y/n]:" -s -n 1 debug_boot_confirm
	if [ "${debug_boot_confirm^^}" = N ]; then
		# abort
		DIE "Boot aborted"
	fi
fi

if [ "$CONFIG_TPM" = "y" ]; then
	tpmr.sh kexec_finalize
fi

if [ -x /bin/io386 -a "$CONFIG_FINALIZE_PLATFORM_LOCKING" = "y" ]; then
	lock_chip.sh
fi

if [ "$CONFIG_BRAND_NAME" = "Heads" ]; then
	STATUS_OK "Heads firmware job done - handing off to your OS. Consider donating: https://opencollective.com/insurgo"
	qrenc "https://opencollective.com/insurgo"
else
	STATUS_OK "$CONFIG_BRAND_NAME firmware job done - starting your OS"
fi
exec kexec -e
