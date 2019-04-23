#!/bin/bash
# 0- To use this script, install diceware first
# sudo dnf install diceware -y
# sudo apt-get install diceware -y
#
# Then 
# 1- Run this script with ./generate_diceware-eom-provisioning.sh 
# 2- Edit ./oem-provisioning.generated so all variiables are provisioned
# 3- Mount USB drive to /media ( eg. sudo mount /dev/sdb1 /media )
# 4- Copy the file on USB drive ( eg. sudo cp /oem-provisioning.generated /media/oem-provisioning )
# 5- Unmount USB drive to flush changes ( eg. sudo umount /media ) 
# 6- Boot your newly received hardware with USB drive connected.
# 7- Enjoy!
#

echo "#PLEASE KEEP THIS FILE IN A SAFE PLACE FOR FURTHER REFERENCE. " > ./oem-provisioning.generated
echo "#" >> ./oem-provisioning.generated
echo "#############" >> ./oem-provisioning.generated
echo "# IMPORTANT #" >> ./oem-provisioning.generated
echo "#############" >> ./oem-provisioning.generated
echo "# TO REMEMBER: Disk Recovery Key Passphrase (Used at system upgrades to recreate a Disk Unlock Key while setting a new boot default)" >> ./oem-provisioning.generated
echo "#   !!!! IF YOU LOOSE THIS PASSPHRASE YOU'LL BE LOCKED OUT OF YOUR ENCRYPTED DISK !!!" >> ./oem-provisioning.generated
echo "# TO REMEMBER: Disk Unlock Key passphrase (Used at every boot, in between system upgrades)" >> ./oem-provisioning.generated
echo "# TO REMEMBER: GPG User PIN (Used to sign /boot config changes following system upgrades)" >> ./oem-provisioning.generated
echo "#   After 3 bad attempts, you will need to unlock User PIN from Admin PIN" >> ./oem-provisioning.generated
echo "# TO REMEMBER: GPG Admin PIN (Used to manage the GPG card and to attest firmware changes you made.)" >> ./oem-provisioning.generated
echo "#   After 3 bad attempts, YOU WILL BE LOCKED OUT OF THE CARD!" >> ./oem-provisioning.generated
echo "#" >> ./oem-provisioning.generated
echo "#" >> ./oem-provisioning.generated
echo "###########" >> ./oem-provisioning.generated
echo "#   GPG   #" >> ./oem-provisioning.generated
echo "###########" >> ./oem-provisioning.generated
echo "#The following GPG Key Admin PIN will be required from you to manage your Librem Key/Nitrokey" >> ./oem-provisioning.generated
echo "#It will be prompted from you under Heads through HOTP code generation to confirm firmware changes were yours" >> ./oem-provisioning.generated
while [[ ${#oem_gpg_Admin_PIN} -lt 8 || ${#oem_gpg_Admin_PIN} -gt 20 ]];do
  oem_gpg_Admin_PIN=$(diceware -n 2)
done
echo "oem_gpg_Admin_PIN=$oem_gpg_Admin_PIN" >> ./oem-provisioning.generated
while [[ ${#oem_gpg_User_PIN} -lt 6 || ${#oem_gpg_User_PIN} -gt 20 ]];do
  oem_gpg_User_PIN=$(diceware -n 2)
done
echo "#The following GPG Key User PIN will be required from you to Sign/Encrypt/Authenticate with your Librem Key/Nitrokey" >> ./oem-provisioning.generated
echo "#It will be prompted from you under Heads to confirm you are aware of /boot related changes" >> ./oem-provisioning.generated
echo "oem_gpg_User_PIN=$oem_gpg_User_PIN" >> ./oem-provisioning.generated
echo "#The following will be used to identify you publicly in generated public key from Heads." >> ./oem-provisioning.generated
echo "#If you intend to upload the generated public key online, you are invited provision the following accordingly" >> ./oem-provisioning.generated
echo "oem_gpg_real_name=" >> ./oem-provisioning.generated
echo "oem_gpg_email=" >> ./oem-provisioning.generated
echo "#The following is used to differenciate different public keys attached to the same name and e-mail address" >> ./oem-provisioning.generated
echo "oem_gpg_comment=" >> ./oem-provisioning.generated
echo "#" >> ./oem-provisioning.generated
echo "########################################" >> ./oem-provisioning.generated
echo "# LUKS Disk Encryption Key Passphrases #" >> ./oem-provisioning.generated
echo "########################################" >> ./oem-provisioning.generated
echo "#The actual Disk Recovery Key passphrase needs to match the passphrase provided by the OEM to unlock actual Disk encrypted drive" >> ./oem-provisioning.generated
echo "oem_luks_actual_Disk_Recovery_Key=" >> ./oem-provisioning.generated
echo "#The new Disk Recovery Key passphrase will replace the Disk Recovery Key password after reencrypting the container with the actual one" >> ./oem-provisioning.generated
echo "oem_luks_new_Disk_Recovery_Key=$(diceware -n 5)" >> ./oem-provisioning.generated
echo "#The Disk Unlock Key passphrase will be used to lauch default boot option at each system startup, and is bound to measured boot integrity attested by the TPM." >> ./oem-provisioning.generated
echo "oem_luks_Disk_Unlock_Key=$(diceware -n 3)" >> ./oem-provisioning.generated
echo "#" >> ./oem-provisioning.generated
echo "#################################" >> ./oem-provisioning.generated
echo "# Trusted Platform Module (TPM) #" >> ./oem-provisioning.generated
echo "#################################" >> ./oem-provisioning.generated
echo "#The TPM Owner passphrase is needed just to own the machine. It is suggested to use the same passphrase as in Admin PIN to limit the number of secrets to remember." >> ./oem-provisioning.generated
echo "oem_TPM_Owner_Password=$oem_gpg_Admin_PIN" >> ./oem-provisioning.generated
