# Targets for running in qemu, including:
# * virtual TPM
# * virtual disk image (configurable size)
# * virtual USB flash drive
# * configurable guest memory size
# * forwarded USB security token

# Use the GPG-injected ROM if a key was given, since we can't reflash a GPG
# keyring in QEMU.  Otherwise use the plain ROM, some things can still be tested
# that way without a GPG key.
ifneq "$(PUBKEY_ASC)" ""
QEMU_BOOT_ROM := $(build)/$(BOARD)/$(CB_OUTPUT_FILE_GPG_INJ)
else
QEMU_BOOT_ROM := $(build)/$(BOARD)/$(CB_OUTPUT_FILE)
endif

ifeq "$(CONFIG_TPM2_TSS)" "y"
SWTPM_TPMVER := --tpm2
SWTPM_PRESETUP := swtpm_setup --create-config-files root,skip-if-exist
else
# TPM1 is the default
SWTPM_TPMVER :=
# No pre-setup
SWTPM_PRESETUP := true
endif

#borrowed from https://github.com/orangecms/webboot/blob/boot-via-qemu/run-webboot.sh
TPMDIR=$(build)/$(BOARD)/vtpm
CANOKEY_DIR=$(build)/$(BOARD)
$(TPMDIR)/.manufacture:
	mkdir -p "$(TPMDIR)"
	$(SWTPM_PRESETUP)
	swtpm_setup --tpm-state "$(TPMDIR)" --create-platform-cert --lock-nvram $(SWTPM_TPMVER)
	touch "$(TPMDIR)/.manufacture"
ROOT_DISK_IMG:=$(build)/$(BOARD)/root.qcow2
# Default to 20G disk
QEMU_DISK_SIZE?=20G
$(ROOT_DISK_IMG):
	qemu-img create -f qcow2 "$(ROOT_DISK_IMG)" $(QEMU_DISK_SIZE)
# Remember the amount of memory so it doesn't have to be specified every time.
# Default to 4G, most bootable OSes are not usable with less.
QEMU_MEMORY_SIZE?=4G
MEMORY_SIZE_FILE=$(build)/$(BOARD)/memory
$(MEMORY_SIZE_FILE):
	@echo "$(QEMU_MEMORY_SIZE)" >"$(MEMORY_SIZE_FILE)"
USB_FD_IMG=$(build)/$(BOARD)/usb_fd.raw
# Default USB flash drive size (accepts K/M/G suffixes).
# Raw sparse: only written blocks consume host disk space, so
# 128G virtual costs ~200K until ISOs are copied in.
QEMU_USB_SIZE?=64G
$(USB_FD_IMG):
	# Create raw sparse image, partition/format via parted + mkfs direct
	# ( -E offset= writes ext4 at partition offset without a loop device ).
	qemu-img create -f raw "$(USB_FD_IMG)" $(QEMU_USB_SIZE) >/dev/null 2>&1
	@if parted -s "$(USB_FD_IMG)" mklabel msdos mkpart primary ext4 2048s 100% \
	      >/dev/null 2>&1 && \
	    mkfs.ext4 -F -E offset=$$((2048*512)) "$(USB_FD_IMG)" >/dev/null 2>&1; then \
	  echo "USB: MBR+ext4 created"; \
	else \
	  echo "USB: warning — MBR creation failed, creating flat ext4" >&2; \
	  mkfs.ext4 -F "$(USB_FD_IMG)" >/dev/null 2>&1; \
	fi
# Pass INSTALL_IMG=<path_to_img.iso> to attach an installer as a USB flash drive instead
# of the temporary flash drive for exporting GPG keys.
ifneq "$(INSTALL_IMG)" ""
QEMU_USB_FD_IMG := $(INSTALL_IMG)
else
QEMU_USB_FD_IMG := $(USB_FD_IMG)
endif
# To forward a USB token, set USB_TOKEN to one of the following:
# - NitrokeyPro - forwards a Nitrokey Pro by VID:PID
# - NitrokeyStorage - forwards a Nitrokey Storage by VID:PID
# - Nitrokey3NFC - forwards a Nitrokey 3 by VID:PID
# - LibremKey - forwards a Librem Key by VID:PID
# - <other> - Provide the QEMU usb-host parameters, such as
#   'hostbus=<#>,hostport=<#>' or 'vendorid=<#>,productid=<#>'
ifeq "$(USB_TOKEN)" "NitrokeyPro"
QEMU_USB_TOKEN_DEV := -device usb-host,vendorid=8352,productid=16648
else ifeq "$(USB_TOKEN)" "NitrokeyStorage"
QEMU_USB_TOKEN_DEV := -device usb-host,vendorid=8352,productid=16649
else ifeq "$(USB_TOKEN)" "Nitrokey3NFC"
QEMU_USB_TOKEN_DEV := -device usb-host,vendorid=8352,productid=17074
else ifeq "$(USB_TOKEN)" "LibremKey"
QEMU_USB_TOKEN_DEV := -device usb-host,vendorid=12653,productid=19531
else ifneq "$(USB_TOKEN)" ""
QEMU_USB_TOKEN_DEV := -device "usb-host,$(USB_TOKEN)"
# If no USB token is specified, support canokey by default
else
# official instruction -usb -device canokey,file=$HOME/.canokey-file -device canokey
QEMU_USB_TOKEN_DEV := -usb -device canokey,file=$(CANOKEY_DIR)/.canokey-file
endif


run: $(TPMDIR)/.manufacture $(ROOT_DISK_IMG) $(MEMORY_SIZE_FILE) $(USB_FD_IMG)
	swtpm socket \
		$(SWTPM_TPMVER) \
		--tpmstate dir="$(TPMDIR)" \
		--flags "startup-clear" \
		--terminate \
		--ctrl type=unixio,path="$(TPMDIR)/sock" &
	sleep 0.5

	-qemu-system-x86_64 -drive file="$(ROOT_DISK_IMG)",if=virtio \
		--machine q35,accel=kvm:tcg \
		-rtc base=utc \
		-smp 1 \
		-vga std \
		-m "$$(cat "$(MEMORY_SIZE_FILE)")" \
		-serial stdio \
		--bios "$(QEMU_BOOT_ROM)" \
		-object rng-random,filename=/dev/urandom,id=rng0 \
		-device virtio-rng-pci,rng=rng0 \
		-netdev user,id=u1 -device e1000,netdev=u1 \
		-chardev socket,id=chrtpm,path="$(TPMDIR)/sock" \
		-tpmdev emulator,id=tpm0,chardev=chrtpm \
		-device tpm-tis,tpmdev=tpm0 \
		-device qemu-xhci,id=usb \
		-device usb-tablet \
		-drive file="$(QEMU_USB_FD_IMG)",if=none,id=usb-fd-drive,format=raw \
		-device usb-storage,bus=usb.0,drive=usb-fd-drive \
		$(QEMU_USB_TOKEN_DEV) \

	stty sane
	@echo
