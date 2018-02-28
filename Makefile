all:
-include .config

modules-y 	:=
pwd 		:= $(shell pwd)
packages 	:= $(pwd)/packages
build		:= $(pwd)/build
config		:= $(pwd)/config
INSTALL		:= $(pwd)/install
log_dir		:= $(build)/log

BOARD		?= qemu-coreboot
CONFIG		:= $(pwd)/boards/$(BOARD).config

ifneq "y" "$(shell [ -r '$(CONFIG)' ] && echo y)"
$(error $(CONFIG): board configuration does not exist)
endif

include $(CONFIG)

# Unless otherwise specified, we are building for heads
CONFIG_HEADS	?= y

# Controls how many parallel jobs are invoked in subshells
CPUS		:= $(shell nproc)
MAKE_JOBS	?= -j$(CPUS) --max-load 16

# Create the log directory if it doesn't already exist
BUILD_LOG := $(shell mkdir -p "$(log_dir)" "$(build)/$(BOARD)" )

# Some things want usernames, we use the current checkout
# so that they are reproducible
GIT_HASH	:= $(shell git rev-parse HEAD)

# Timestamps should be in ISO format
DATE=`date --rfc-3339=seconds`

# If V is set in the environment, do not redirect the tee
# command to /dev/null.
ifeq "$V" ""
VERBOSE_REDIRECT := > /dev/null
# Not verbose, so we only show the header
define do =
	@echo "$(DATE) $1 $(2:$(pwd)/%=%)"
	@$3
endef
else
# Verbose, so we display what we are doing
define do =
	@echo "$(DATE) $1 $(2:$(pwd)/%=%)"
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

# We are running our own version of make,
# proceed with the build.

# Force pipelines to fail if any of the commands in the pipe fail
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

# If musl-libc is being used in the initrd, set the heads_cc
# variable to point to it.
musl_dep	:= musl
heads_cc	:= $(INSTALL)/bin/musl-gcc \
	-fdebug-prefix-map=$(pwd)=heads \
	-gno-record-gcc-switches \
	-D__MUSL__ \

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
all: $(build)/$(BOARD)/coreboot.rom
else ifeq "$(CONFIG_LINUXBOOT)" "y"
all: $(build)/$(BOARD)/linuxboot.rom
else
$(error "$(BOARD): neither CONFIG_COREBOOT nor CONFIG_LINUXBOOT is set?")
endif

# helpful targets for common uses
linux: $(build)/$(BOARD)/bzImage
cpio: $(build)/$(BOARD)/initrd.cpio.xz

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
# Build a cpio from a directory
#
define do-cpio =
	$(call do,CPIO,$1,\
		( cd "$2"; \
		find . \
		| cpio \
			--quiet \
			-H newc \
			-o \
		) > "$1.tmp" \
	)
	@if ! cmp --quiet "$1.tmp" "$1" ; then \
		mv "$1.tmp" "$1" ; \
	else \
		rm "$1.tmp" ; \
	fi
endef

define do-copy =
	$(call do,COPY,$1 => $2',\
		sha256sum "$(1:$(pwd)/%=%)" ; \
		if ! cmp --quiet "$1" "$2" ; then \
			cp -a "$1" "$2"; \
		fi
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

  # Allow the module to override the destination configuration file
  # via a relative path.  Linux uses this to have a per-board build.
  $(eval $1_config_file_path := $(build)/$($1_dir)/$(or $($1_config_file),.config))

  ifeq "$($1_config)" ""
    # There is no official .config file
    $($1_config_file_path): $(build)/$($1_dir)/.canary
	@mkdir -p $$(dir $$@)
	@touch "$$@"
  else
    # Copy the stored config file into the unpacked directory
    $($1_config_file_path): $($1_config) $(build)/$($1_dir)/.canary
	@mkdir -p $$(dir $$@)
	$(call do-copy,$($1_config),$$@)
  endif

  # Use the module's configure variable to build itself
  $(dir $($1_config_file_path)).configured: \
		$(build)/$($1_dir)/.canary \
		$($1_config_file_path) \
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
		$(dir $($1_config_file_path)).configured \

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
	$(call do,INSTALL-BIN,$$(<:$(pwd)/%=%),cp -a "$$<" "$$@")
	@$(CROSS)strip --preserve-dates "$$@" 2>&-; true
initrd_bins += $(initrd_bin_dir)/$(notdir $1)
endef


define initrd_lib_add =
$(initrd_lib_dir)/$(notdir $1): $1
	$(call do,INSTALL-LIB,$(1:$(pwd)/%=%),\
		$(CROSS)strip --preserve-dates -o "$$@" "$$<")
initrd_libs += $(initrd_lib_dir)/$(notdir $1)
endef

# Only some modules have binaries that we install
# Shouldn't this be specified in the module file?
bin_modules-$(CONFIG_KEXEC) += kexec
bin_modules-$(CONFIG_TPMTOTP) += tpmtotp
bin_modules-$(CONFIG_PCIUTILS) += pciutils
bin_modules-$(CONFIG_FLASHROM) += flashrom
bin_modules-$(CONFIG_CRYPTSETUP) += cryptsetup
bin_modules-$(CONFIG_GPG) += gpg
bin_modules-$(CONFIG_LVM2) += lvm2
bin_modules-$(CONFIG_DROPBEAR) += dropbear
bin_modules-$(CONFIG_FLASHTOOLS) += flashtools
bin_modules-$(CONFIG_NEWT) += newt

$(foreach m, $(bin_modules-y), \
	$(call map,initrd_bin_add,$(call bins,$m)) \
)

# Install the libraries for every module that we have built
$(foreach m, $(modules-y), \
	$(call map,initrd_lib_add,$(call libs,$m)) \
)

# hack to install busybox into the initrd
$(build)/$(BOARD)/heads.cpio: busybox.intermediate
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
#$(eval $(call initrd_bin_add,$(build)/$(coreboot_dir)/util/inteltool/inteltool))
endif

$(build)/$(coreboot_dir)/util/cbmem/cbmem: \
		$(build)/$(coreboot_dir)/.canary \
		musl.intermediate
	$(call do,MAKE,cbmem,\
		$(MAKE) -C "$(dir $@)" CC="$(heads_cc)" \
	)
$(build)/$(coreboot_dir)/util/inteltool/inteltool: \
		$(build)/$(coreboot_dir)/.canary \
		musl.intermediate
	$(call do,MAKE,inteltool,\
		$(MAKE) -C "$(dir $@)" CC="$(heads_cc)" \
	)

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

initrd-y += $(pwd)/blobs/dev.cpio
initrd-y += $(build)/$(BOARD)/modules.cpio
initrd-y += $(build)/$(BOARD)/tools.cpio
initrd-$(CONFIG_HEADS) += $(build)/$(BOARD)/heads.cpio

initrd.intermediate: $(build)/$(BOARD)/initrd.cpio.xz
$(build)/$(BOARD)/initrd.cpio.xz: $(initrd-y)
	$(call do,CPIO-CLEAN,$@,\
	$(pwd)/bin/cpio-clean \
		$^ \
	| xz \
		--check=crc32 \
		--lzma2=dict=1MiB \
		-9 \
	| dd bs=512 conv=sync > "$@" \
	)
	@sha256sum "$(@:$(pwd)/%=%)"

#
# The heads.cpio is built from the initrd directory in the
# Heads tree.
#
$(build)/$(BOARD)/heads.cpio: FORCE
	$(call do-cpio,$@,$(pwd)/initrd)


#
# The tools initrd is made from all of the things that we've
# created during the submodule build.
#
$(build)/$(BOARD)/tools.cpio: \
	$(initrd_bins) \
	$(initrd_libs) \

	$(call do,INSTALL,$(CONFIG), \
		mkdir -p "$(initrd_dir)/etc" ; \
		export \
			| grep ' CONFIG_' \
			| sed 's/^declare -x /export /' \
			> "$(initrd_dir)/etc/config" \
	)
	$(call do-cpio,$@,$(initrd_dir))
	@$(RM) -rf "$(initrd_dir)"



# This produces a ROM image that is written with the flashrom program
$(build)/$(BOARD)/coreboot.rom: $(build)/$(coreboot_dir)/$(BOARD)/coreboot.rom
	"$(build)/$(coreboot_dir)/$(BOARD)/cbfstool" "$<" print
	$(call do,EXTRACT,$@,mv "$<" "$@")
	@sha256sum "$(@:$(pwd)/%=%)"


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
		$(slang_dir) \
		$(newt_dir) \

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

else
# Wrong make version detected -- build our local version
# and re-invoke the Makefile with it instead.
$(eval $(shell echo >&2 "$(DATE) Wrong make detected: $(LOCAL_MAKE_VERSION)"))
HEADS_MAKE := $(build)/$(make_dir)/make

# Once we have a proper Make, we can just pass arguments into it
all bootstrap linux cpio: $(HEADS_MAKE)
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
