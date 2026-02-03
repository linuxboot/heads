#mount /boot in read-only by default
mount /boot
#verify detached signature of /boot content
find /boot/kexec*.txt | gpg --verify /boot/kexec.sig -
#remove invalid kexec_* signed files
mount /dev/sda1 /boot && mount -o remount,rw /boot && rm /boot/kexec* && mount -o remount,ro /boot
#Generate keys on OpenPGP smartcard: 
mount-usb --mode rw && gpg --home=/.gnupg/ --card-edit
#Copy generated public key, private_subkey, trustdb and artifacts to external media for backup: 
mkdir -p /media/gpg_keys; gpg --export-secret-keys --armor email@address.com > /media/gpg_keys/private.key && gpg --export --armor email@address.com  > /media/gpg_keys/public.key && gpg --export-ownertrust > /media/gpg_keys/otrust.txt && cp -r ./.gnupg/* /media/gpg_keys/ 2> /dev/null
#Insert public key and trustdb export into reproducible rom:
cbfs -o /media/coreboot.rom -a "heads/initrd/.gnupg/keys/public.key" -f /media/gpg_keys/public.key && cbfs -o /media/coreboot.rom -a "heads/initrd/.gnupg/keys/otrust.txt" -f /media/gpg_keys/otrust.txt
#Flush changes to external media: 
mount -o,remount ro /media
#Flash modified reproducible rom with inserted public key and trustdb export from precedent step. Flushes actual rom's keys (-c: clean):
flash.sh -c /media/coreboot.rom
#Attest integrity of firmware as it is
seal-totp
#Verify Intel ME state:
cbmem --console | grep '^ME'
cbmem --console | less
# Reboot/power off (important for devices with no keyboard to escape recovery shell)
reboot  # Press Enter with this command to reboot
poweroff  # Press Enter with this command to power off
