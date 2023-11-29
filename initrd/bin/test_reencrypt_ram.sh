echo "Mounting USB drive to /media"
mount-usb --mode rw

echo "PLACEHOLDER - Creating 8GB file in /tmp" | tee /media/ram_reencrypt.log
dd if=/dev/zero of=/tmp/disk8gb.raw bs=1M count=8k | tee -a /media/ram_reencrypt.log
echo "This is test passphrase used to create LUKS key" > /tmp/passphrase.txt

#cryptsetup benchmark | tee -a /media/ram_reencrypt.log

echo "PLACEHOLDER - Creating LUKS container on /tmp/disk8gb.raw..." | tee -a /media/ram_reencrypt.log
cryptsetup luksFormat /tmp/disk8gb.raw --debug --batch-mode --key-file /tmp/passphrase.txt | tee -a /media/ram_reencrypt.log

echo "PLACEHOLDER - Reeencrypting LUKS container on /tmp/disk8gb.raw..." | tee -a /media/ram_reencrypt.log
cryptsetup reencrypt /tmp/disk8gb.raw --disable-locks --force-offline-reencrypt --debug --batch-mode --key-file /tmp/passphrase.txt | tee -a /media/ram_reencrypt.log

echo "PLACEHOLDER - Unmounting USB drive from /media"
umount /media
echo "Done. You can remove USB drive now and upload ram_reencrypt.log from another computer to github PR."
