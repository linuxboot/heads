modules-y 	:=
pwd 		:= $(shell pwd)
packages 	:= $(pwd)/packages
build		:= $(pwd)/build
config		:= $(pwd)/build
INSTALL		:= $(pwd)/install
log_dir		:= $(build)/log

# Controls how many parallel jobs are invoked in subshells
CPUS		:= $(shell nproc)
MAKE_JOBS	?= -j$(CPUS) --max-load 16

# Create the log directory if it doesn't already exist
BUILD_LOG := $(shell [ -d "$(log_dir)" ] || mkdir -p "$(log_dir)")

# Timestamps should be in ISO format
DATE=`date --rfc-3339=seconds`

# If V is set in the environment, do not redirect the tee
# command to /dev/null.
ifeq "$V" ""
VERBOSE_REDIRECT := > /dev/null
# Not verbose, so we only show the header
define do =
	@echo "$(DATE) $1 $2"
	@$3
endef
else
# Verbose, so we display what we are doing
define do =
	@echo "$(DATE) $1 $2"
	$3
endef
endif


# Check that we have a correct version of make
LOCAL_MAKE_VERSION := $(shell $(MAKE) --version | head -1 | cut -d' ' -f3)
include modules/make

ifeq "$(LOCAL_MAKE_VERSION)" "$(make_version)"

# Create a temporary directory for the initrd
initrd_dir	:= $(shell mktemp -d)
initrd_lib_dir	:= $(initrd_dir)/lib
initrd_bin_dir	:= $(initrd_dir)/bin

$(shell mkdir -p "$(initrd_lib_dir)" "$(initrd_bin_dir)")
$(shell echo "Initrd: $initrd_dir")

ifeq "$(CONFIG)" ""
CONFIG := config/qemu-moc.config
$(eval $(shell echo >&2 "$(DATE) CONFIG is not set, defaulting to $(CONFIG)"))
endif

include $(CONFIG)

# We are running our own version of make,
# proceed with the build.

# Force pipelines to fail if any of the commands in the pipe fail
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

# Currently supported targets are x230, chell and qemu
BOARD		?= qemu

# If musl-libc is being used in the initrd, set the heads_cc
# variable to point to it.
musl_dep	:= musl
heads_cc	:= $(INSTALL)/bin/musl-gcc \
	-fdebug-prefix-map=$(pwd)=heads \
	-gno-record-gcc-switches \

CROSS		:= $(build)/../crossgcc/x86_64-linux-musl/bin/x86_64-musl-linux-
CROSS_TOOLS_NOCC := \
	AR="$(CROSS)ar" \
	LD="$(CROSS)ld" \
	STRIP="$(CROSS)strip" \
	NM="$(CROSS)nm" \
	OBJCOPY="$(CROSS)objcopy" \
	OBJDUMP="$(CROSS)objdump" \

CROSS_TOOLS := \
	CC="$(heads_cc)" \
	$(CROSS_TOOLS_NOCC) \



ifeq "$(CONFIG_COREBOOT)" "y"
all: $(BOARD).rom
else
all: nerf-$(BOARD).rom
endif

# Disable all built in rules
.SUFFIXES:
FORCE:

# Make helpers to operate on lists of things
define prefix =
$(foreach _, $2, $1$_)
endef
define map =
$(foreach _,$2,$(eval $(call $1,$_)))
endef

# Bring in all of the module definitions;
# these are the external pieces that will be downloaded and built
# as part of creating the Heads firmware image.
include modules/*

# These will be built via their intermediate targets
# This increases the build time, so it is commented out for now
#all: $(foreach m,$(modules-y),$m.intermediate)

define bins =
$(foreach m,$1,$(call prefix,$(build)/$($m_dir)/,$($m_output)))
endef
define libs =
$(foreach m,$1,$(call prefix,$(build)/$($m_dir)/,$($m_libraries)))
endef

define outputs =
$(foreach m,$1,\
	$(call bins,$m)\
	$(call libs,$m)\
)
endef

#
# Generate the targets for a module.
#
# Special variables like $@ must be written as $$@ to avoid
# expansion during the first evaluation.
#
define define_module =
  ifneq ("$($1_repo)","")
    # Checkout the tree instead and touch the canary file so that we know
    # that the files are all present. No signature hashes are checked in
    # this case, since we don't have a stable version to compare against.
    $(build)/$($1_dir)/.canary:
	git clone $($1_repo) "$(build)/$($1_dir)"
	if [ -r patches/$1.patch ]; then \
		( cd $(build)/$($1_dir) ; patch -p1 ) \
			< patches/$1.patch; \
	fi
	@touch "$$@"
  else
    # Fetch and verify the source tar file
    $(packages)/$($1_tar):
	wget -O "$$@" $($1_url)
    $(packages)/.$1-$($1_version)_verify: $(packages)/$($1_tar)
	echo "$($1_hash)  $$^" | sha256sum --check -
	@touch "$$@"

    # Unpack the tar file and touch the canary so that we know
    # that the files are all present
    $(build)/$($1_dir)/.canary: $(packages)/.$1-$($1_version)_verify
	tar -xf "$(packages)/$($1_tar)" -C "$(build)"
	if [ -r patches/$1-$($1_version).patch ]; then \
		( cd $(build)/$($1_dir) ; patch -p1 ) \
			< patches/$1-$($1_version).patch; \
	fi
	@touch "$$@"
  endif

  ifeq "$($1_config)" ""
    # There is no official .config file
    $(build)/$($1_dir)/.config: $(build)/$($1_dir)/.canary
	@touch "$$@"
  else
    # Copy the stored config file into the unpacked directory
    $(build)/$($1_dir)/.config: config/$($1_config) $(build)/$($1_dir)/.canary
	$(call do,COPY,"$$<",cp "$$<" "$$@")
  endif

  # Use the module's configure variable to build itself
  $(build)/$($1_dir)/.configured: \
		$(build)/$($1_dir)/.canary \
		$(build)/$($1_dir)/.config \
		$(foreach d,$($1_depends),$(call outputs,$d)) \
		modules/$1
	@echo "$(DATE) CONFIG $1"
	@( \
		cd "$(build)/$($1_dir)" ; \
		echo "$($1_configure)"; \
		$($1_configure) \
	) \
		< /dev/null \
		2>&1 \
		| tee "$(log_dir)/$1.configure.log" \
		$(VERBOSE_REDIRECT)
	@touch "$$@"

  # All of the outputs should result from building the intermediate target
  $(call outputs,$1): $1.intermediate

  # Short hand target for the module
  #$1: $(call outputs,$1)

  # Target for all of the outputs, which depend on their dependent modules
  $1.intermediate: \
		$(foreach d,$($1_depends),$d.intermediate) \
		$(foreach d,$($1_depends),$(call outputs,$d)) \
		$(build)/$($1_dir)/.configured
	@echo "$(DATE) MAKE $1"
	@( \
		echo "$(MAKE) \
			-C \"$(build)/$($1_dir)\" \
			$($1_target)" ;  \
		$(MAKE) \
			-C "$(build)/$($1_dir)" \
			$($1_target)  \
	) \
		< /dev/null \
		2>&1 \
		| tee "$(log_dir)/$1.log" \
		$(VERBOSE_REDIRECT) \
	|| ( \
		echo "tail $(log_dir)/$1.log"; \
		echo "-----"; \
		tail -20 "$(log_dir)/$1.log"; \
		exit 1; \
	)
	@echo "$(DATE) DONE $1"

  $1.clean:
	-$(RM) "$(build)/$($1_dir)/.configured"
	-$(MAKE) -C "$(build)/$($1_dir)" clean

endef

$(call map, define_module, $(modules-y))

# hack to force musl-cross to be built before musl
#$(build)/$(musl_dir)/.configured: $(build)/$(musl-cross_dir)/../../crossgcc/x86_64-linux-musl/bin/x86_64-linux-musl-gcc

#
# Install a file into the initrd, if it changed from
# the destination file.
#
define install =
	@-mkdir -p "$(dir $2)"
	$(call do,INSTALL,$2,cp -a "$1" "$2")
endef

#
# Files that should be copied into the initrd
# THis should probably be done in a more scalable manner
#
define initrd_bin_add =
$(initrd_bin_dir)/$(notdir $1): $1
	$(call do,INSTALL-BIN,$$<,cp -a "$$<" "$$@")
	@$(CROSS)strip --preserve-dates "$$@" 2>&-; true
initrd_bins += $(initrd_bin_dir)/$(notdir $1)
endef


define initrd_lib_add =
$(initrd_lib_dir)/$(notdir $1): $1
	$(call do,INSTALL-LIB,$$@,$(CROSS)strip --preserve-dates -o "$$@" "$$<")
initrd_libs += $(initrd_lib_dir)/$(notdir $1)
endef

# Only some modules have binaries that we install
bin_modules-$(CONFIG_KEXEC) += kexec
bin_modules-$(CONFIG_TPMTOTP) += tpmtotp
bin_modules-$(CONFIG_PCIUTILS) += pciutils
bin_modules-$(CONFIG_FLASHROM) += flashrom
bin_modules-$(CONFIG_CRYPTSETUP) += cryptsetup
bin_modules-$(CONFIG_GPG) += gpg
bin_modules-$(CONFIG_LVM2) += lvm2
bin_modules-$(CONFIG_XEN) += xen
bin_modules-$(CONFIG_DROPBEAR) += dropbear

$(foreach m, $(bin_modules-y), \
	$(call map,initrd_bin_add,$(call bins,$m)) \
)

# Install the libraries for every module that we have built
$(foreach m, $(modules-y), \
	$(call map,initrd_lib_add,$(call libs,$m)) \
)

#$(foreach _, $(call outputs,xen), $(eval $(call initrd_bin,$_)))

# hack to install busybox into the initrd
initrd.cpio: busybox.intermediate
initrd_bins += $(initrd_bin_dir)/busybox

$(initrd_bin_dir)/busybox: $(build)/$(busybox_dir)/busybox
	$(do,SYMLINK,$@,$(MAKE) \
		-C $(build)/$(busybox_dir) \
		CC="$(heads_cc)" \
		CONFIG_PREFIX="$(pwd)/initrd" \
		$(MAKE_JOBS) \
		install \
	)

#
# hack to build cbmem from coreboot
# this must be built *AFTER* musl, but since coreboot depends on other things
# that depend on musl it should be ok.
#
ifeq ($(CONFIG_COREBOOT),y)
$(eval $(call initrd_bin_add,$(build)/$(coreboot_dir)/util/cbmem/cbmem))
endif

$(build)/$(coreboot_dir)/util/cbmem/cbmem: \
		$(build)/$(coreboot_dir)/.canary \
		musl.intermediate
	$(call do,MAKE,cbmem,\
		$(MAKE) -C "$(dir $@)" CC="$(heads_cc)" \
	)

#
# Linux kernel module installation
#
# This is special cases since we have to do a special strip operation on
# the kernel modules to make them fit into the ROM image.
#
define linux_module =
$(build)/$(linux_dir)/$1: linux.intermediate
initrd.cpio: $(initrd_lib_dir)/modules/$(notdir $1)
$(initrd_lib_dir)/modules/$(notdir $1): $(build)/$(linux_dir)/$1
	@-mkdir -p "$(initrd_lib_dir)/modules"
	$(call do,INSTALL-MODULE,$$@,$(CROSS)strip --preserve-dates --strip-debug -o "$$@" "$$<")
endef
$(call map,linux_module,$(linux_modules-y))


#
# initrd image creation
#
# The initrd is constructed from various bits and pieces
# The cpio-clean program is used ensure that the files
# always have the same timestamp and appear in the same order.
#
# If there is no /dev/console, initrd can't startup.
# We have to force it to be included into the cpio image.
# Since we are picking up the system's /dev/console, there
# is a chance the build will not be reproducible (although
# unlikely that their device file has a different major/minor)
#
#
initrd.cpio: $(initrd_bins) $(initrd_libs) dev.cpio FORCE
	$(call do,OVERLAY,initrd,\
		tar -C ./initrd -cf - . | tar -C "$(initrd_dir)" -xf - \
	)
	$(call do,INSTALL,$(CONFIG),cp "$(CONFIG)" "$(initrd_dir)/etc/config")
	$(call do,CPIO,$@, \
	cd "$(initrd_dir)"; \
	find . \
	| cpio --quiet -H newc -o \
	| $(pwd)/bin/cpio-clean \
		$(pwd)/dev.cpio \
		- \
		> "$(pwd)/$@" \
	)
	$(call do,RM,$(initrd_dir),$(RM) -rf "$(initrd_dir)")

initrd.intermediate: initrd.cpio


#
# Compress the initrd into a xz file that can be included by coreboot.
# The extra options are necessary to let the Linux kernel decompress it
# and the extra padding is to ensure that it can be concatenated to
# other cpio files.
#
coreboot.intermediate: $(build)/$(coreboot_dir)/initrd.cpio.xz
$(build)/$(coreboot_dir)/initrd.cpio.xz: initrd.cpio

%.xz: %
	$(call do,COMPRESS,$<,\
	xz \
		--check=crc32 \
		--lzma2=dict=1MiB \
		-9 \
		< "$<" \
	| dd bs=512 conv=sync > "$@" \
	)
	@sha256sum "$@"

# hack for the coreboot to find the linux kernel
$(build)/$(coreboot_dir)/bzImage: $(build)/$(linux_dir)/arch/x86/boot/bzImage
	$(call do,COPY,$@,cp "$^" "$@")
	@sha256sum "$@"

coreboot.intermediate: $(build)/$(coreboot_dir)/bzImage


# Each board output has its own fixup required to turn the coreboot.rom
# into a flashable image.

# This produces a ROM image suitable for writing into the top chip;
x230.flash.rom: $(build)/$(coreboot_dir)/x230.flash/coreboot.rom
	"$(build)/$(coreboot_dir)/$(BOARD)/cbfstool" "$<" print
	$(call do,EXTRACT,$@,dd if="$<" of="$@" bs=1M skip=8)
	@-$(RM) $<
	@sha256sum "$@"

# This produces a ROM image that is written with the flashrom program
%.rom: $(build)/$(coreboot_dir)/%/coreboot.rom
	"$(build)/$(coreboot_dir)/$(BOARD)/cbfstool" "$<" print
	$(call do,EXTRACT,$@,mv "$<" "$@")
	@sha256sum "$@"

module_dirs := \
		$(busybox_dir) \
		$(cryptsetup_dir) \
		$(dropbear_dir) \
		$(flashrom_dir) \
		$(gpg_dir) \
		$(kexec_dir) \
		$(libusb_dir) \
		$(libusb-compat_dir) \
		$(lvm2_dir) \
		$(mbedtls_dir) \
		$(pciutils_dir) \
		$(popt_dir) \
		$(qrencode_dir) \
		$(tpmtotp_dir) \
		$(util-linux_dir) \
		$(zlib_dir) \
		$(kernel-headers_dir) \

modules.clean:
	for dir in $(module_dirs) \
	; do \
		$(MAKE) -C "build/$$dir" clean ; \
		rm "build/$$dir/.configured" ; \
	done

real.clean:
	for dir in \
		$(module_dirs) \
		$(musl_dir) \
		$(kernel_headers) \
	; do \
		if [ ! -z "$$dir" ]; then \
			rm -rf "build/$$dir"; \
		fi; \
	done
	rm -rf ./install

bootstrap:
	$(MAKE) \
		-j`nproc` \
		musl-cross.intermediate \
		$(build)/$(coreboot_dir)/util/crossgcc/xgcc/bin/i386-elf-gcc \

include Makefile.nerf

else
# Wrong make version detected -- build our local version
# and re-invoke the Makefile with it instead.
$(eval $(shell echo >&2 "$(DATE) Wrong make detected: $(LOCAL_MAKE_VERSION)"))
HEADS_MAKE := $(build)/$(make_dir)/make

# Once we have a proper Make, we can just pass arguments into it
all bootstrap: $(HEADS_MAKE)
	LANG=C MAKE=$(HEADS_MAKE) $(HEADS_MAKE) $@
%.clean %.intermediate %.vol: $(HEADS_MAKE)
	LANG=C MAKE=$(HEADS_MAKE) $(HEADS_MAKE) $@

# How to download and build the correct version of make
$(HEADS_MAKE): $(build)/$(make_dir)/Makefile
	make -C "$(dir $@)" $(MAKE_JOBS) \
		2>&1 \
		| tee "$(log_dir)/make.log" \
		$(VERBOSE_REDIRECT)

$(build)/$(make_dir)/Makefile: $(packages)/$(make_tar)
	tar xf "$<" -C build/
	cd "$(dir $@)" ; ./configure \
		2>&1 \
		| tee "$(log_dir)/make.configure.log" \
		$(VERBOSE_REDIRECT)

$(packages)/$(make_tar):
	wget -O "$@" "$(make_url)"
	if ! echo "$(make_hash)  $@" | sha256sum --check -; then \
		$(MV) "$@" "$@.failed"; \
		false; \
	fi

endif
