all: coreboot


kexec_version := 2.0.12
kexec_dir := kexec-tools-$(kexec_version)
kexec_tar := kexec-tools-$(kexec_version).tar.gz
kexec_url := https://kernel.org/pub/linux/utils/kernel/kexec/$(kexec_tar)
kexec_hash := cc7b60dad0da202004048a6179d8a53606943062dd627a2edba45a8ea3a85135

$(kexec_tar):
	wget "$(kexec_url)"
	sha256sum "$(kexec_tar)"
	echo "$(kexec_hash)"

$(kexec_dir): $(kexec_tar)
	tar xvf "$(kexec_tar)"
	cd "$(kexec_dir)" && ./configure

kexec: $(kexec_dir)
	make -C "$(kexec_dir)" -j 8


busybox_version := 1.25.0
busybox_dir := busybox-$(busybox_version)
busybox_tar := busybox-$(busybox_version).tar.bz2
busybox_url := https://busybox.net/downloads/$(busybox_tar)
busybox_hash := 5a0fe06885ee1b805fb459ab6aaa023fe4f2eccee4fb8c0fd9a6c17c0daca2fc
busybox_config := config/busybox.config

busybox: $(busybox_dir) $(busybox_dir)/.config
	make -C "$(busybox_dir)" -j 8

$(busybox_dir): $(busybox_tar)
	tar xvf "$(busybox_tar)"

$(busybox_dir)/.config: $(busybox_config)
	cp "$<" "$@"
	make -C "$(busybox_dir)" oldconfig

$(busybox_tar):
	wget "$(busybox_url)"
	sha256sum "$(busybox_tar)"
	echo "$(busybox_hash)"


linux_version := 4.6.4
linux_dir := linux-$(linux_version)
linux_tar := linux-$(linux_version).tar.xz
linux_url := https://cdn.kernel.org/pub/linux/kernel/v4.x/$(linux_tar)
linux_hash := 8568d41c7104e941989b14a380d167129f83db42c04e950d8d9337fe6012ff7e
linux_config := config/linux.config

$(linux_dir): $(linux_tar)
	tar xvf "$(linux_tar)"

$(linux_dir)/.config: $(linux_config)
	cp "$<" "$@"
	make -C "$(linux_dir)" oldconfig

$(linux_dir)/arch/x86/boot/bzImage: $(linux_dir) $(linux_dir)/.config
	make -C "$(linux_dir)" -j 8
	make -C "$(linux_dir)" bzImage
	ls -Fla "$@"

coreboot_version := 4.4
coreboot_dir := coreboot-$(coreboot_version)
coreboot_tar := coreboot-$(coreboot_version).tar.xz
coreboot_url := https://www.coreboot.org/releases/$(coreboot_tar)
coreboot_config := config/coreboot.config

coreboot-blobs_tar := coreboot-blobs-$(coreboot_version).tar.xz
coreboot-blobs_url := https://www.coreboot.org/releases/$(coreboot-blobs_tar)
coreboot-blobs_dir := coreboot-$(coreboot_version)/3rdparty/blobs
coreboot-blobs_hash := 43b993915c0f46a77ee7ddaa2dbe47581f399510632c62f2558dff931358d8ab
coreboot-blobs_canary := $(coreboot-blobs_dir)/documentation/binary_policy.md


$(coreboot_dir)/util/crossgcc/xgcc/bin/iasl:
	echo '******* Building gcc (this might take a while) ******'
	time make -C "$(coreboot_dir)" crossgcc

$(coreboot_dir)/bzImage: $(linux_dir)/arch/x86/boot/bzImage
	cp "$<" "$@"

$(coreboot_dir)/initrd.img: FORCE
	echo '*** Building initrd ***'
	( cd initrd && \
		find . \
		| cpio --quiet -H newc -o \
		) | bzip2 -9  > "$@"


initrd: \
	initrd/bin/busybox \
	initrd/sbin/kexec \
	initrd/libs

initrd/bin/busybox: $(busybox_dir)/busybox
	make -C "$(busybox_dir)" CONFIG_PREFIX="`pwd`/initrd" install 

initrd/sbin/kexec: $(kexec_dir)/build/sbin/kexec
	-mkdir "`dirnname "$@"`"
	cp "$<" "$@"

INITRD_LIBS += \
	liblzma.so.5 \
	libz.so.1 \
	libc.so.6 \
	libdl.so.2 \

initrd/libs:
	-mkdir -p initrd/lib/x86_64-linux-gnu
	-mkdir -p initrd/lib64
	cp /lib64/ld-linux-x86-64.so.2 initrd/lib64/
	for lib in $(INITRD_LIBS); do \
		cp "/lib/x86_64-linux-gnu/$$lib" initrd/lib/x86_64-linux-gnu/; \
	done


$(coreboot_tar):
	wget "$(coreboot_url)"
	sha256sum "$(coreboot_tar)"
	echo "$(coreboot_hash)"

$(coreboot-blobs_tar):
	wget "$(coreboot-blobs_url)"
	sha256sum "$(coreboot-blobs_tar)"
	echo "$(coreboot-blobs_hash)"

$(coreboot_blobs_canary): $(coreboot-blobs_tar)
	tar xvf "$(coreboot-blobs_tar)"

$(coreboot_dir): $(coreboot_tar)
	tar xvf "$(coreboot_tar)"

$(coreboot_dir)/.config: $(coreboot_config)
	cp "$<" "$@"
	make -C "$(coreboot_dir)" oldconfig

$(coreboot_dir)/build/coreboot.rom: \
	$(coreboot_dir) \
	$(coreboot_dir)/.config \
	$(coreboot_dir)/util/crossgcc/xgcc/bin/iasl \
	$(coreboot_dir)/bzImage \
	$(coreboot_dir)/initrd.img \
	$(coreboot-blobs_canary) \

	make -C "$(coreboot_dir)"

heads-x230.rom: $(coreboot_dir)/build/coreboot.rom
	dd if="$<" of="$@" bs=1M skip=8
	sha256sum "$@"
	xxd -g 1 "$@" | head
	xxd -g 1 "$@" | tail

coreboot: heads-x230.rom

FORCE:
