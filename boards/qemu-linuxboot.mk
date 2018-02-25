# You can ssh into the qemu instance by running
# ssh -p 5555 root@localhost
# The LinuxBoot firmware should set its ip address to 10.0.2.15
# or run udhcpc to get a qemu address

run: linuxboot.intermediate
	qemu-system-x86_64 \
		-machine q35,smm=on  \
		-global ICH9-LPC.disable_s3=1 \
		-global driver=cfi.pflash01,property=secure,value=on \
		-redir tcp:5555::22 \
		--serial $(or $(SERIAL),/dev/tty) \
		-drive if=pflash,format=raw,unit=0,file=$(build)/$(BOARD)/linuxboot.rom
	stty sane

