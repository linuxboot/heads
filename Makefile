all: linux kexec busybox initrd coreboot


kexec_version := 2.0.12
kexec_tar := kexec-tools-$(kexec_version).tar.gz
kexec_url := https://kernel.org/pub/linux/utils/kernel/kexec/$(kexec_tar)
kexec_hash := cc7b60dad0da202004048a6179d8a53606943062dd627a2edba45a8ea3a85135

kexec: $(kexec_tar)
	tar xvf "$(kexec_tar)"
	cd "$(kexec_dir)" && ./configure && make

$(kexec_tar):
	wget "$(kexec_url)"
	sha256sum "$(kexec_tar)"
	echo "$(kexec_hash)"


busybox_version := 1.25.0
busybox_dir := busybox-$(busybox_version)
busybox_tar := busybox-$(busybox_version).tar.bz2
busybox_url := https://busybox.net/downloads/$(busybox_tar)
busybox_hash := 5a0fe06885ee1b805fb459ab6aaa023fe4f2eccee4fb8c0fd9a6c17c0daca2fc
busybox_config := config/busybox.config

busybox: $(busybox_tar) $(busybox_config)
	tar xvf "$(busybox_tar)"
	cp "$(busybox_config)" "$(busybox_dir)/.config"
	cd "$(busybox_dir)" && make oldconfig && make -j 8

$(busybox_tar):
	wget "$(busybox_url)"
	sha256sum "$(busybox_tar)"
	echo "$(busybox_hash)"


linux_version := 4.6.4
linux_dir := linux-$(linux_version)
linux_tar := linux-$(linux_version).tar.bz2
linux_url := https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-$(linux_version).tar.xz
linux_hash := 8568d41c7104e941989b14a380d167129f83db42c04e950d8d9337fe6012ff7e
linux_config := config/linux.config

linux: $(linux_tar) $(linux_config)
	tar xvf "$(linux_tar)"
	cp "$(linux_config)" "$(linux_dir)/.config"
	cd "$(linux_dir)" && make oldconfig && make -j 8 && make bzImage
