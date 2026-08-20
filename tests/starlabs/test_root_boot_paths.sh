#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/boot/grub"
touch "$tmpdir/boot/vmlinuz" "$tmpdir/boot/initrd" \
	"$tmpdir/boot/xen.gz" "$tmpdir/boot/dom0-vmlinuz" \
	"$tmpdir/boot/dom0-initrd"

printf '%s\n' \
	'menuentry "root boot" {' \
	' linux /boot/vmlinuz root=/dev/test' \
	' initrd /boot/initrd' \
	'}' \
	'menuentry "root xen" {' \
	' multiboot /boot/xen.gz placeholder' \
	' module /boot/dom0-vmlinuz root=/dev/test' \
	' module --nounzip /boot/dom0-initrd' \
	'}' >"$tmpdir/boot/grub/grub.cfg"

printf '%s\n' \
	'DEBUG() { :; }' \
	'DIE() { echo "$*" >&2; exit 1; }' >"$tmpdir/functions.sh"

sed "s|^\. /etc/functions.sh$|. $tmpdir/functions.sh|" \
	"$repo_root/initrd/bin/kexec-parse-boot.sh" >"$tmpdir/kexec-parse-boot.sh"
chmod +x "$tmpdir/kexec-parse-boot.sh"

entry=$("$tmpdir/kexec-parse-boot.sh" "$tmpdir/boot" \
	"$tmpdir/boot/grub/grub.cfg")

case "$entry" in
*'|kernel /vmlinuz|initrd /initrd|append root=/dev/test'*) ;;
*)
	echo "Unexpected parsed entry: $entry" >&2
	exit 1
	;;
esac

case "$entry" in
*'|kernel /xen.gz placeholder|module /dom0-vmlinuz root=/dev/test|module /dom0-initrd'*) ;;
*)
	echo "Unexpected parsed Xen entry: $entry" >&2
	exit 1
	;;
esac

grep -F 'mount -w "$boot_dev" /boot_root' \
	"$repo_root/initrd/etc/functions.sh" >/dev/null
grep -F 'mount -w -o remount,rw "$boot_dev" /boot_root' \
	"$repo_root/initrd/etc/functions.sh" >/dev/null
grep -F 'mount -w -o remount,bind,rw "$boot_dev" /boot' \
	"$repo_root/initrd/etc/functions.sh" >/dev/null

if grep -R -E 'mount -o [^ ]*remount[^ ]* /boot([[:space:]]|$)' \
	"$repo_root/initrd/bin" "$repo_root/initrd/etc/luks-functions.sh"; then
	echo "Found a /boot writer which bypasses remount_boot_device" >&2
	exit 1
fi

if grep -E 'mount -o [^ ]*remount[^ ]*.*\$params(dev|dir)' \
	"$repo_root/initrd/bin/kexec-save-default.sh" \
	"$repo_root/initrd/bin/kexec-save-key.sh" \
	"$repo_root/initrd/bin/kexec-seal-key.sh"; then
	echo "Found an indirect /boot writer which bypasses remount_boot_device" >&2
	exit 1
fi

echo "Root-filesystem /boot path tests passed"
