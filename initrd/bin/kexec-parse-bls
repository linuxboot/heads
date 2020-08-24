#!/bin/sh
set -e -o pipefail
bootdir="$1"
file="$2"
blsdir="$3"
kernelopts=""

if [ -z "$bootdir" -o -z "$file" ]; then
	die "Usage: $0 /boot /boot/grub/grub.cfg blsdir"
fi

reset_entry() {
	name=""
	kexectype="elf"
	kernel=""
	initrd=""
	modules=""
	append="$kernelopts"
}

filedir=`dirname $file`
bootdir="${bootdir%%/}"
bootlen="${#bootdir}"
appenddir="${filedir:$bootlen}"
# assumption. grubenv is in same location as config file
# ignored if doesn't exist
grubenv="$filedir/grubenv"

fix_path() {
	path="$@"
	if [ "${path:0:1}" != "/" ]; then
		path="$appenddir/$path"
	fi
}

echo_entry() {
	if [ "$kexectype" = "elf" ]; then
		if [ -z "$kernel" ]; then return; fi

		fix_path $kernel
		entry="$name|$kexectype|kernel $path"
		if [ -n "$initrd" ]; then
			fix_path $initrd
			entry="$entry|initrd $path"
		fi
		if [ -n "$append" ]; then
			entry="$entry|append $append"
		fi

		echo $(eval "echo \"$entry\"")
	fi
	if [ "$kexectype" = "multiboot" -o "$kexectype" = "xen" ]; then
		if [ -z "$kernel" ]; then return; fi

		fix_path $kernel
		echo $(eval "echo \"$name|$kexectype|kernel $path$modules\"")
	fi
}

bls_entry() {
	# add info to menuentry
	trimcmd=`echo $line | tr '\t ' ' ' | tr -s ' '`
	cmd=`echo $trimcmd | cut -d\  -f1`
	val=`echo $trimcmd | cut -d\  -f2-`
	case $cmd in
		title)
			name=$val
			;;
		linux*)
			kernel=${val#"$bootdir"}
			;;
		initrd*)
			initrd=${val#"$bootdir"}
			;;
		options)
			# default is "options $kernelopts"
			# need to substitute that variable if set in .cfg/grubenv
			append=`echo "$val" | sed "s@\\$kernelopts@$kernelopts@"`
			;;
	esac
}

# This is the default append value if no options field in bls entry
grep -q "set default_kernelopts" "$file" && 
	kernelopts=`grep "set default_kernelopts" "$file" |
		tr "'" "\"" | cut -d\" -f 2`
[ -f "$grubenv" ] && grep -q "^kernelopts" "$grubenv" &&
	kernelopts=`grep "^kernelopts" "$grubenv" | tr '@' '_' | cut -d= -f 2-`
reset_entry
find $blsdir -type f -name \*.conf |
while read f
do
	while read line
	do
		bls_entry
	done < "$f"
	echo_entry
	reset_entry
done
