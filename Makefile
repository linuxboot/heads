modules 	:=
pwd 		:= $(shell pwd)
packages 	:= $(pwd)/packages
build		:= $(pwd)/build
config		:= $(pwd)/build

all:

include modules/qrencode
include modules/kexec
include modules/tpmtotp
include modules/mbedtls
include modules/busybox
include modules/linux
include modules/coreboot
include modules/coreboot-blobs

all: $(modules)

define prefix =
$(foreach _, $2, $1$_)
endef

define outputs =
$(call prefix,$(build)/$($1_dir)/,$($1_output))
endef

#
# Generate the targets for a module.
#
# Special variables like $@ must be written as $$@ to avoid
# expansion during the first evaluation.
#
define define_module =
  # Fetch and verify the source tar file
  $(packages)/$($1_tar):
	wget -O "$$@" $($1_url)
  $(packages)/.$1_verify: $(packages)/$($1_tar)
	echo "$($1_hash) $$^" | sha256sum --check -
	touch "$$@"

  # Unpack the tar file and touch the canary so that we know
  # that the files are all present
  $(build)/$($1_dir)/.canary: $(packages)/.$1_verify
	tar -xvf "$(packages)/$($1_tar)" -C "$(build)"
	touch "$$@"

  # Copy our stored config file into the unpacked directory
  $(build)/$($1_dir)/.config: config/$1.config $(build)/$($1_dir)/.canary
	cp "$$<" "$$@"

  # Use the module's configure variable to build itself
  $(build)/$($1_dir)/.configured: \
		$(build)/$($1_dir)/.canary \
		$(build)/$($1_dir)/.config
	cd "$(build)/$($1_dir)" ; $($1_configure)
	touch "$$@"

  # Build the target after any dependencies
  $(call outputs,$1): \
		$(build)/$($1_dir)/.configured \
		$(call outputs,$($1_depends))
	make -C "$(build)/$($1_dir)" $($1_target)

  # Short hand target for the module
  $1: $(call outputs,$1)

endef

$(foreach _, $(modules), $(eval $(call define_module,$_)))


#
# Files that should be copied into the initrd
# THis should probably be done in a more scalable manner
#
define initrd_bin =
initrd/bin/$(notdir $1): $1
	cmp --quiet "$$@" "$$^" || \
	cp -a "$$^" "$$@"
initrd_bins += initrd/bin/$(notdir $1)
endef

$(foreach _, $(call outputs,kexec), $(eval $(call initrd_bin,$_)))
$(foreach _, $(call outputs,tpmtotp), $(eval $(call initrd_bin,$_)))

# hack to install busybox into the initrd
initrd_bins += initrd/bin/busybox

initrd/bin/busybox: $(build)/$(busybox_dir)/busybox
	cmp --quiet "$@" "$^" || \
	make \
		-C $(build)/$(busybox_dir) \
		CONFIG_PREFIX="$(pwd)/initrd" \
		install


# Update all of the libraries in the initrd based on the executables
# that were installed.
initrd_libs: $(initrd_bins)
	./populate-lib \
		./initrd/lib/x86-64-linux-gnu/ \
		initrd/bin/* \
		initrd/sbin/* \


#
# We also have to include some real /dev files; the minimal
# set should be determined.
#
initrd_devs += /dev/console
initrd_devs += /dev/mem
initrd_devs += /dev/null
initrd_devs += /dev/tty
initrd_devs += /dev/tty0
initrd_devs += /dev/ttyS0

#
# initrd image creation
#
# The initrd is constructed from various bits and pieces
# Note the touch and sort operation on the find output -- this
# ensures that the files always have the same timestamp and
# appear in the same order.
#
# This breaks on the files in /dev.
#
#
initrd.cpio: $(initrd_bins) initrd_libs
	find ./initrd -type f -print0 \
		| xargs -0 touch -d "1970-01-01"
	cd ./initrd; \
	find . $(initrd_devs) \
		| sort \
		| cpio --quiet -H newc -o \
		> "../$@.tmp" 
	if ! cmp --quiet "$@" "$@.tmp"; then \
		mv "$@.tmp" "$@"; \
	else \
		echo "$@: Unchanged"; \
		rm "$@.tmp"; \
	fi
	

# hack for the linux kernel to depend on the initrd image
# this will change once coreboot can link in the initrd separately
$(call outputs,linux): initrd.cpio
