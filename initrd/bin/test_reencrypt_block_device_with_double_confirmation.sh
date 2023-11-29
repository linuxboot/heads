echo "Mounting USB drive to /media"
mount-usb --mode rw

#Prompt user to specify block device's partition to format and reencrypt with big fat warning
echo "WARNING: This script will format and reencrypt specified partition next. Please make sure you have backed up your data before proceeding."
echo "Please specify block device's partition to format and reencrypt. Example: /dev/sda2"
read DISK

#validate one last time with user prior of proceeding
echo "You have specified $DISK. Are you sure you want to proceed? (y/n)"
read CONFIRM
if [ "$CONFIRM" != "y" ]; then
    echo "Aborting..."
    exit 1
fi

#echo "PLACEHOLDER - Creating 8GB file in /tmp" | tee -a /media/ram_reencrypt.log
#dd if=/dev/zero of=/tmp/disk8gb.raw bs=1M count=8k | tee -a /media/ram_reencrypt.log
echo "This is test passphrase used to create LUKS key" > /tmp/passphrase.txt

#Doing benchmarking
echo "PLACEHOLDER - Running benchmark..." | tee /media/block_reencrypt.log

cryptsetup benchmark | tee -a /media/block_reencrypt.log

echo "PLACEHOLDER - Creating LUKS container on $DISK..." | tee -a /media/block_reencrypt.log
time cryptsetup luksFormat "$DISK" --debug --key-file /tmp/passphrase.txt | tee -a /media/block_reencrypt.log

echo "PLACEHOLDER - Reeencrypting LUKS container on $DISK..." | tee -a /media/block_reencrypt.log
time cryptsetup reencrypt "$DISK" --debug --resilience=none --key-file /tmp/passphrase.txt | tee -a /media/block_reencrypt.log

echo "PLACEHOLDER - Unmounting USB drive from /media"
umount /media
echo "Done. You can remove USB drive now and upload ram_reencrypt.log from another computer to github PR."
