#!/bin/bash

gpg_flash_rom() {
	if [ "$1" = "replace" ]; then
		[ -e /.gnupg/pubring.gpg ] && rm /.gnupg/pubring.gpg
		[ -e /.gnupg/pubring.kbx ] && rm /.gnupg/pubring.kbx
		[ -e /.gnupg/trustdb.gpg ] && rm /.gnupg/trustdb.gpg
	fi

	cat "$PUBKEY" | gpg --import
	gpg --list-keys --fingerprint --with-colons | sed -E -n -e 's/^fpr:::::::::([0-9A-F]+):$/\1:6:/p' | gpg --import-ownertrust
	gpg --update-trust

	if cbfs.sh -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/pubring.kbx"; then
		cbfs.sh -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/pubring.kbx"
		if cbfs.sh -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/pubring.gpg"; then
			cbfs.sh -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/pubring.gpg"
			[ -e /.gnupg/pubring.gpg ] && rm /.gnupg/pubring.gpg
		fi
	fi

	if [ -e /.gnupg/pubring.kbx ]; then
		cbfs.sh -o /tmp/gpg-gui.rom -a "heads/initrd/.gnupg/pubring.kbx" -f /.gnupg/pubring.kbx
		[ -e /.gnupg/pubring.gpg ] && rm /.gnupg/pubring.gpg
	fi
	if [ -e /.gnupg/pubring.gpg ]; then
		cbfs.sh -o /tmp/gpg-gui.rom -a "heads/initrd/.gnupg/pubring.gpg" -f /.gnupg/pubring.gpg
	fi

	if cbfs.sh -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/trustdb.gpg"; then
		cbfs.sh -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/trustdb.gpg"
	fi
	if [ -e /.gnupg/trustdb.gpg ]; then
		cbfs.sh -o /tmp/gpg-gui.rom -a "heads/initrd/.gnupg/trustdb.gpg" -f /.gnupg/trustdb.gpg
	fi

	if cbfs.sh -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/.gnupg/otrust.txt"; then
		cbfs.sh -o /tmp/gpg-gui.rom -d "heads/initrd/.gnupg/otrust.txt"
	fi

	if cbfs.sh -o /tmp/gpg-gui.rom -l | grep -q "heads/initrd/etc/config.user"; then
		cbfs.sh -o /tmp/gpg-gui.rom -d "heads/initrd/etc/config.user"
	fi
	if [ -e /etc/config.user ]; then
		cbfs.sh -o /tmp/gpg-gui.rom -a "heads/initrd/etc/config.user" -f /etc/config.user
	fi
	/bin/flash.sh /tmp/gpg-gui.rom
}

gpg_post_gen_mgmt() {
	GPG_GEN_KEY=$(grep -A1 pub /tmp/gpg_card_edit_output | tail -n1 | sed -nr 's/^([ ])*//p')
	gpg --export --armor $GPG_GEN_KEY >"/tmp/${GPG_GEN_KEY}.asc"
	if (whiptail_warning --title 'Add Public Key to USB disk?' \
		--yesno "Would you like to copy the GPG public key you generated to a USB disk?\n\nYou may need it, if you want to use it outside of Heads later.\n\nThe file will show up as ${GPG_GEN_KEY}.asc" 0 80); then
		mount_usb
		mount -o remount,rw /media
		cp "/tmp/${GPG_GEN_KEY}.asc" "/media/${GPG_GEN_KEY}.asc"
		if [ $? -eq 0 ]; then
			whiptail_type $BG_COLOR_MAIN_MENU --title "The GPG Key Copied Successfully" \
				--msgbox "${GPG_GEN_KEY}.asc copied successfully." 0 80
		else
			whiptail_error --title 'ERROR: Copy Failed' \
				--msgbox "Unable to copy ${GPG_GEN_KEY}.asc to /media" 0 80
		fi
		umount /media
	fi
	if (whiptail --title 'Add Public Key to Running BIOS?' \
		--yesno "Would you like to add the GPG public key you generated to the BIOS?\n\nThis makes it a trusted key used to sign files in /boot\n\n" 0 80); then
		/bin/flash.sh -r /tmp/gpg-gui.rom
		if [ ! -s /tmp/gpg-gui.rom ]; then
			whiptail_error --title 'ERROR: BIOS Read Failed!' \
				--msgbox "Unable to read BIOS" 0 80
			exit 1
		fi
		PUBKEY="/tmp/${GPG_GEN_KEY}.asc"
		gpg_flash_rom
	fi
}

gpg_add_key_reflash() {
	if (whiptail --title 'GPG public key required' \
		--yesno "This requires you insert a USB drive containing:\n* Your GPG public key (*.key or *.asc)\n\nAfter you select this file, this program will copy and reflash your BIOS\n\nDo you want to proceed?" 0 80); then
		mount_usb
		if grep -q /media /proc/mounts; then
			find /media -name '*.key' >/tmp/filelist.txt
			find /media -name '*.asc' >>/tmp/filelist.txt
			file_selector "/tmp/filelist.txt" "Choose your GPG public key"
			if [ "$FILE" = "" ]; then
				return 1
			fi
			PUBKEY=$FILE

			/bin/flash.sh -r /tmp/gpg-gui.rom
			if [ ! -s /tmp/gpg-gui.rom ]; then
				whiptail_error --title 'ERROR: BIOS Read Failed!' \
					--msgbox "Unable to read BIOS" 0 80
				return 1
			fi

			if (whiptail --title 'Update ROM?' \
				--yesno "This will reflash your BIOS with the updated version\n\nDo you want to proceed?" 0 80); then
				gpg_flash_rom
			fi
		fi
	fi
	return 1
}

gpg_add_key_to_standalone_rom() {
	if (whiptail --title 'ROM and GPG public key required' \
		--yesno "This requires you insert a USB drive containing:\n* Your GPG public key (*.key or *.asc)\n* Your BIOS image (*.rom)\n\nAfter you select these files, this program will reflash your BIOS\n\nDo you want to proceed?" 0 80); then
		mount_usb
		if grep -q /media /proc/mounts; then
			find /media -name '*.key' >/tmp/filelist.txt
			find /media -name '*.asc' >>/tmp/filelist.txt
			file_selector "/tmp/filelist.txt" "Choose your GPG public key"
			if [ "$FILE" == "" ]; then
				return 1
			fi
			PUBKEY=$FILE

			find /media -name '*.rom' >/tmp/filelist.txt
			file_selector "/tmp/filelist.txt" "Choose the ROM to load your key onto"
			if [ "$FILE" == "" ]; then
				return 1
			fi
			cp "$FILE" /tmp/gpg-gui.rom

			if (whiptail_warning --title 'Flash ROM?' \
				--yesno "This will replace your old ROM with the selected ROM\n\nDo you want to proceed?" 0 80); then
				gpg_flash_rom
			fi
		fi
	fi
	return 1
}

gpg_replace_key_reflash() {
	[ -e /.gnupg/pubring.gpg ] && rm /.gnupg/pubring.gpg
	[ -e /.gnupg/pubring.kbx ] && rm /.gnupg/pubring.kbx
	[ -e /.gnupg/trustdb.gpg ] && rm /.gnupg/trustdb.gpg
	gpg_add_key_reflash
}
