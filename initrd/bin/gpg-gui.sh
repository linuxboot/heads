#!/bin/bash
#
set -e -o pipefail
. /etc/functions.sh
. /etc/gui_functions.sh
. /etc/gpg_functions.sh
. /tmp/config

TRACE_FUNC

while true; do
	unset menu_choice
	whiptail_type $BG_COLOR_MAIN_MENU --title "GPG Management Menu" \
		--menu 'Select the GPG function to perform' 0 80 10 \
		'r' ' Add GPG key to running BIOS and reflash' \
		'a' ' Add GPG key to standalone BIOS image and flash' \
		'e' ' Replace GPG key(s) in the current ROM and reflash' \
		'l' ' List GPG keys in your keyring' \
		'p' ' Export public GPG key to USB drive' \
		'g' ' Generate GPG keys manually on a USB security dongle' \
		'x' ' Exit' \
		2>/tmp/whiptail || recovery "GUI menu failed"

	menu_choice=$(cat /tmp/whiptail)

	case "$menu_choice" in
	"x")
		exit 0
		;;
	"a")
		gpg_add_key_to_standalone_rom
		;;
	"r")
		gpg_add_key_reflash
		exit 0
		;;
	"e")
		gpg_replace_key_reflash
		;;
	"l")
		GPG_KEYRING=$(gpg -k)
		whiptail_type $BG_COLOR_MAIN_MENU --title 'GPG Keyring' \
			--msgbox "${GPG_KEYRING}" 0 80
		;;
	"p")
		if (whiptail_warning --title 'Export Public Key(s) to USB drive?' \
			--yesno "Would you like to copy GPG public key(s) to a USB drive?\n\nThe file will show up as public-key.asc" 0 80); then
			if gpg_export_pubkey_to_usb; then
				whiptail_type $BG_COLOR_MAIN_MENU --title "The GPG Key Copied Successfully" \
					--msgbox "public-key.asc copied successfully." 0 80
			else
				whiptail_error --title 'ERROR: Copy Failed' \
					--msgbox "Unable to copy public-key.asc to /media" 0 80
			fi
		fi
		;;
	"g")
		confirm_gpg_card
		STATUS "INSTRUCTIONS:"
		INFO "Type 'admin' then 'generate' and follow the prompts to generate a GPG key"
		INFO "Type 'quit' once the key is generated to exit GPG"
		gpg --card-edit >/tmp/gpg_card_edit_output
		if [ $? -eq 0 ]; then
			gpg_post_gen_mgmt
		fi
		;;
	esac

done
exit 0
