modules 	:=
pwd 		:= $(shell pwd)
packages 	:= $(pwd)/packages
build		:= $(pwd)/build
config		:= $(pwd)/build
INSTALL		:= $(pwd)/install
log_dir		:= $(build)/log
MAKE_JOBS	?= -j8 --max-load 24

# Create the log directory if it doesn't already exist
BUILD_LOG := $(shell [ -d "$(log_dir)" ] || mkdir "$(log_dir)")

# If V is set in the environment, do not redirect the tee
# command to /dev/null.
ifeq "$V" ""
VERBOSE_REDIRECT := > /dev/null
endif

# Check that we have a correct version of make
LOCAL_MAKE_VERSION := $(shell $(MAKE) --version | head -1 | cut -d' ' -f3)
include modules/make

ifeq "$(LOCAL_MAKE_VERSION)" "$(make_version)"
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

#heads_cc	:= $(HOME)/install/x86_64-linux-musl/x86_64-linux-musl/bin/gcc

all: $(BOARD).rom

# Disable all built in rules
.SUFFIXES:

# Timestamps should be in ISO format
DATE=`date --rfc-3339=seconds`

# Bring in all of the module definitions;
# these are the external pieces that will be downloaded and built
# as part of creating the Heads firmware image.
include modules/*

# These will be built via their intermediate targets
# This increases the build time, so it is commented out for now
#all: $(foreach m,$(modules),$m.intermediate)

define prefix =
$(foreach _, $2, $1$_)
endef

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
	git clone "$($1_repo)" "$(build)/$($1_dir)"
	if [ -r patches/$1.patch ]; then \
		( cd $(build)/$($1_dir) ; patch -p1 ) \
			< patches/$1.patch; \
	fi
	touch "$$@"
  else
    # Fetch and verify the source tar file
    $(packages)/$($1_tar):
	wget -O "$$@" $($1_url)
    $(packages)/.$1_verify: $(packages)/$($1_tar)
	echo "$($1_hash)  $$^" | sha256sum --check -
	touch "$$@"

    # Unpack the tar file and touch the canary so that we know
    # that the files are all present
    $(build)/$($1_dir)/.canary: $(packages)/.$1_verify
	tar -xf "$(packages)/$($1_tar)" -C "$(build)"
	if [ -r patches/$1-$($1_version).patch ]; then \
		( cd $(build)/$($1_dir) ; patch -p1 ) \
			< patches/$1-$($1_version).patch; \
	fi
	touch "$$@"
  endif

  ifeq "$($1_config)" ""
    # There is no official .config file
    $(build)/$($1_dir)/.config: $(build)/$($1_dir)/.canary
	touch "$$@"
  else
    # Copy the stored config file into the unpacked directory
    $(build)/$($1_dir)/.config: config/$($1_config) $(build)/$($1_dir)/.canary
	cp -a "$$<" "$$@"
  endif

  # Use the module's configure variable to build itself
  $(build)/$($1_dir)/.configured: \
		$(build)/$($1_dir)/.canary \
		$(build)/$($1_dir)/.config
	@echo "$(DATE) Configuring $1"
	@( \
		cd "$(build)/$($1_dir)" ; \
		echo "$($1_configure)"; \
		$($1_configure) \
	) \
		< /dev/null \
		2>&1 \
		| tee "$(log_dir)/$1.configure.log" \
		$(VERBOSE_REDIRECT)
	touch "$$@"

  # All of the outputs should result from building the intermediate target
  $(call outputs,$1): $1.intermediate

  # Short hand target for the module
  #$1: $(call outputs,$1)

  # Target for all of the outputs, which depend on their dependent modules
  $1.intermediate: \
		$(foreach d,$($1_depends),$d.intermediate) \
		$(foreach d,$($1_depends),$(call outputs,$d)) \
		$(build)/$($1_dir)/.configured
	@echo "$(DATE) Building $1"
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

  $1.clean:
	-$(RM) "$(build)/$($1_dir)/.configured"
	-$(MAKE) -C "$(build)/$($1_dir)" clean

.INTERMEDIATE: $1.intermediate
endef

$(foreach _, $(modules), $(eval $(call define_module,$_)))

initrd_lib_dir := initrd/lib
initrd_bin_dir := initrd/bin

#
# Install a file into the initrd, if it changed from
# the destination file.
#
define install =
	@echo "$(DATE) Installing $2"
	@cp -a "$1" "$2"
endef

#
# Files that should be copied into the initrd
# THis should probably be done in a more scalable manner
#
define initrd_bin_add =
$(initrd_bin_dir)/$(notdir $1): $1
	@if [ ! -d "$(initrd_bin_dir)" ]; \
		then mkdir -p "$(initrd_bin_dir)"; \
	fi
	$(call install,$$<,$$@)
initrd_bins += $(initrd_bin_dir)/$(notdir $1)
endef


define initrd_lib_add =
$(initrd_lib_dir)/$(notdir $1): $1
	@if [ ! -d "$(initrd_lib_dir)" ]; \
		then mkdir -p "$(initrd_lib_dir)"; \
	fi
	$(call install,$$<,$$@)
initrd_libs += $(initrd_lib_dir)/$(notdir $1)
endef

$(foreach _, $(call bins,kexec), $(eval $(call initrd_bin_add,$_)))
$(foreach _, $(call bins,tpmtotp), $(eval $(call initrd_bin_add,$_)))
$(foreach _, $(call bins,cryptsetup), $(eval $(call initrd_bin_add,$_)))
$(foreach _, $(call bins,gpg), $(eval $(call initrd_bin_add,$_)))
$(foreach _, $(call bins,lvm2), $(eval $(call initrd_bin_add,$_)))

$(foreach _, $(call libs,tpmtotp), $(eval $(call initrd_lib_add,$_)))
$(foreach _, $(call libs,mbedtls), $(eval $(call initrd_lib_add,$_)))
$(foreach _, $(call libs,qrencode), $(eval $(call initrd_lib_add,$_)))
$(foreach _, $(call libs,lvm2), $(eval $(call initrd_lib_add,$_)))

#$(foreach _, $(call outputs,xen), $(eval $(call initrd_bin,$_)))

# hack to install busybox into the initrd
initrd_bins += initrd/bin/busybox

initrd/bin/busybox: $(build)/$(busybox_dir)/busybox
	cmp --quiet "$@" "$^" || \
	$(MAKE) \
		-C $(build)/$(busybox_dir) \
		CC="$(heads_cc)" \
		CONFIG_PREFIX="$(pwd)/initrd" \
		$(MAKE_JOBS) \
		install

# hack to build cbmem from coreboot
# this must be built *AFTER* musl
initrd_bins += initrd/bin/cbmem
initrd/bin/cbmem: $(build)/$(coreboot_dir)/util/cbmem/cbmem
	cp "$^" "$@"
$(build)/$(coreboot_dir)/util/cbmem/cbmem: \
		$(build)/$(coreboot_dir)/.canary \
		musl.intermediate
	@echo "$(DATE) Building cbmem"
	@$(MAKE) -C "$(dir $@)" CC="$(heads_cc)"


# Update all of the libraries in the initrd based on the executables
# that were installed.
initrd_lib_install: $(initrd_bins) $(initrd_libs)
	-find initrd/bin -type f -a ! -name '*.sh' -print0 \
		| xargs -0 $(CROSS)strip --preserve-dates
	LD_LIBRARY_PATH="$(INSTALL)/lib" \
	./populate-lib \
		$(initrd_lib_dir) \
		initrd/bin/* \
		initrd/sbin/* \

	-$(CROSS)strip $(initrd_lib_dir)/* ; true


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
initrd.cpio: $(initrd_bins) $(initrd_libs) initrd_lib_install linux_modules
	cd ./initrd ; \
	find . \
	| cpio --quiet -H newc -o \
	| ../cpio-clean ../dev.cpio - \
		> "../$@"

initrd.intermediate: initrd.cpio

linux_modules: linux.intermediate
	@-mkdir initrd/lib/modules
	@for mod in $(linux_modules); do \
		echo "$(DATE) Installing $$mod"; \
		cp -a "$(build)/$(linux_dir)/$$mod" initrd/lib/modules; \
	done
	$(CROSS)strip --strip-debug initrd/lib/modules/*.ko
	


# populate the coreboot initrd image from the one we built.
# 4.4 doesn't allow this, but building from head does.
#$(call outputs,linux): initrd.cpio
coreboot.intermediate: $(build)/$(coreboot_dir)/initrd.cpio.xz
$(build)/$(coreboot_dir)/initrd.cpio.xz: initrd.cpio
	xz \
		--check=crc32 \
		--lzma2=dict=1MiB \
		--extreme \
		< "$<" \
		> "$@"

# hack for the coreboot to find the linux kernel
$(build)/$(coreboot_dir)/bzImage: $(build)/$(linux_dir)/arch/x86/boot/bzImage
	@echo "$(DATE) Copying $@"
	@cp -a "$^" "$@"
coreboot.intermediate: $(build)/$(coreboot_dir)/bzImage


# The coreboot gcc won't work for us since it doesn't have libc
#XGCC := $(build)/$(coreboot_dir)/util/crossgcc/xgcc/
#export CC := $(XGCC)/bin/x86_64-elf-gcc
#export LDFLAGS := -L/lib/x86_64-linux-gnu

x230.rom: $(build)/$(coreboot_dir)/x230/coreboot.rom
	"$(build)/$(coreboot_dir)/$(BOARD)/cbfstool" "$<" print
	dd if="$<" of="$@" bs=1M skip=8
	$(RM) "$<"
	@sha256sum "$@"

qemu.rom: $(build)/$(coreboot_dir)/qemu/coreboot.rom
	"$(build)/$(coreboot_dir)/$(BOARD)/cbfstool" "$<" print
	mv "$<" "$@"
	@sha256sum "$@"


clean-modules:
	for dir in \
		$(busybox_dir) \
		$(cryptsetup_dir) \
		$(gnupg_dir) \
		$(kexec_dir) \
		$(libuuid_dir) \
		$(lvm2_dir) \
		$(mbedtls_dir) \
		$(popt_dir) \
		$(qrencode_dir) \
		$(tpmtotp_dir) \
	; do \
		$(MAKE) -C "build/$$dir" clean ; \
		rm "build/$$dir/.configured" ; \
	done


else
# Wrong make version detected -- build our local version
# and re-invoke the Makefile with it instead.
$(info Wrong make detected: $(LOCAL_MAKE_VERSION))
HEADS_MAKE := $(build)/$(make_dir)/make

# Once we have a proper Make, we can just pass arguments into it
%: $(HEADS_MAKE)
	LANG=C MAKE=$(HEADS_MAKE) $(HEADS_MAKE) $@
all:

# How to download and build the correct version of make
$(HEADS_MAKE): $(build)/$(make_dir)/Makefile
	make -C "`dirname $@`" $(MAKE_JOBS) \
		2>&1 \
		| tee "$(log_dir)/make.log" \
		$(VERBOSE_REDIRECT)

$(build)/$(make_dir)/Makefile: $(packages)/$(make_tar)
	tar xf "$<" -C build/
	cd "`dirname $@`" ; ./configure \
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
