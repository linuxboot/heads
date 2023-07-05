# Need to set CB_OUTPUT_FILE before board .config included so
# that target overrides in x230/x430-flash (eg) are properly handled
GIT_HASH	:= $(shell git rev-parse HEAD)
GIT_STATUS	:= $(shell \
	if git diff --exit-code >/dev/null ; then \
		echo clean ; \
	else \
		echo dirty ; \
	fi)
HEADS_GIT_VERSION	:= $(shell git describe --abbrev=7 --tags --dirty)

# Override BRAND_NAME to set the name displayed in the UI, filenames, versions, etc.
BRAND_NAME	?= Heads

CB_OUTPUT_BASENAME	:= $(shell echo $(BRAND_NAME) | tr A-Z a-z)-$(BOARD)-$(HEADS_GIT_VERSION)
CB_OUTPUT_FILE		:= $(CB_OUTPUT_BASENAME).rom
CB_OUTPUT_FILE_GPG_INJ	:= $(CB_OUTPUT_BASENAME)-gpg-injected.rom
CB_BOOTBLOCK_FILE	:= $(CB_OUTPUT_BASENAME).bootblock
LB_OUTPUT_FILE		:= linuxboot-$(BOARD)-$(HEADS_GIT_VERSION).rom

all:
-include .config

modules-y 	:=
pwd 		:= $(shell pwd)
config		:= $(pwd)/config
# These are dynamic, must not expand right here
build		= $(pwd)/build/$(CONFIG_TARGET_ARCH)
packages 	= $(pwd)/packages/$(CONFIG_TARGET_ARCH)
INSTALL		= $(pwd)/install/$(CONFIG_TARGET_ARCH)
log_dir		= $(build)/log
board_build	= $(build)/$(BOARD)

# Controls how many parallel jobs are invoked in subshells
CPUS		?= $(shell nproc)
MAKE_JOBS	?= -j$(CPUS) --max-load 16

WGET ?= wget

# Timestamps should be in ISO format
DATE=`date --rfc-3339=seconds`

BOARD		?= qemu-coreboot-fbwhiptail-tpm1
CONFIG		:= $(pwd)/boards/$(BOARD)/$(BOARD).config

ifneq "y" "$(shell [ -r '$(CONFIG)' ] && echo y)"
$(error $(CONFIG): board configuration does not exist)
endif

# By default, we are building for x86, up to a board to change this variable
CONFIG_TARGET_ARCH := x86

include $(CONFIG)

# Unless otherwise specified, we are building for heads
CONFIG_HEADS	?= y

# Unless otherwise specified, we are building bash to have non-interactive shell for scripts (arrays and bashisms)
CONFIG_BASH	?= y

# Determine arch part for a host triplet
ifeq "$(CONFIG_TARGET_ARCH)" "x86"
MUSL_ARCH := x86_64
else ifeq "$(CONFIG_TARGET_ARCH)" "ppc64"
MUSL_ARCH := powerpc64le
else
$(error "Unexpected value of $$(CONFIG_TARGET_ARCH): $(CONFIG_TARGET_ARCH)")
endif

# Create directories if they don't already exist
BUILD_LOG	:= $(shell mkdir -p "$(log_dir)")
PACKAGES	:= $(shell mkdir -p "$(packages)")

# record the build date / git hashes and other files here
HASHES		:= $(board_build)/hashes.txt
SIZES		:= $(board_build)/sizes.txt

# Create the board output directory if it doesn't already exist
BOARD_LOG	:= $(shell \
	mkdir -p "$(board_build)" ; \
	echo "$(DATE) $(GIT_HASH) $(GIT_STATUS)" > "$(HASHES)" ; \
	echo "$(DATE) $(GIT_HASH) $(GIT_STATUS)" > "$(SIZES)" ; \
)

ifeq "y" "$(CONFIG_LINUX_BUNDLED)"
# Create empty initrd for initial kernel "without" initrd.
$(shell cpio -o < /dev/null > $(board_build)/initrd.cpio)
endif

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


# Create a temporary directory for the initrd
initrd_dir	:= $(BOARD)
initrd_tmp_dir	:= $(shell mktemp -d)
initrd_lib_dir	:= $(initrd_tmp_dir)/lib
initrd_bin_dir	:= $(initrd_tmp_dir)/bin
modules-y += initrd

$(shell mkdir -p "$(initrd_lib_dir)" "$(initrd_bin_dir)")

# We are running our own version of make,
# proceed with the build.

# Force pipelines to fail if any of the commands in the pipe fail
SHELL := /usr/bin/env bash
.SHELLFLAGS := -o pipefail -c

# Include the musl-cross module early so that $(CROSS) will
# be defined prior to any other module.
include modules/musl-cross

musl_dep	:= musl-cross
target		:= $(shell echo $(CROSS) | grep -Eoe '([^/]*?)-linux-musl')
arch		:= $(subst -linux-musl, , $(target))
heads_cc	:= $(CROSS)gcc \
	-fdebug-prefix-map=$(pwd)=heads \
	-gno-record-gcc-switches \
	-D__MUSL__ \
	-isystem $(INSTALL)/include \
	-L$(INSTALL)/lib \

# Cross-compiling with pkg-config requires clearing PKG_CONFIG_PATH and setting
# both PKG_CONFIG_LIBDIR and PKG_CONFIG_SYSROOT_DIR.
# https://autotools.info/pkgconfig/cross-compiling.html
CROSS_TOOLS_NOCC := \
	AR="$(CROSS)ar" \
	LD="$(CROSS)ld" \
	STRIP="$(CROSS)strip" \
	NM="$(CROSS)nm" \
	OBJCOPY="$(CROSS)objcopy" \
	OBJDUMP="$(CROSS)objdump" \
	PKG_CONFIG_PATH= \
	PKG_CONFIG_LIBDIR="$(INSTALL)/lib/pkgconfig" \
	PKG_CONFIG_SYSROOT_DIR="$(INSTALL)" \

CROSS_TOOLS := \
	CC="$(heads_cc)" \
	$(CROSS_TOOLS_NOCC) \

# Targets to build payload only
.PHONY: payload
payload: $(build)/$(BOARD)/bzImage $(build)/$(initrd_dir)/initrd.cpio.xz

ifeq ($(CONFIG_COREBOOT), y)

all: $(board_build)/$(CB_OUTPUT_FILE)
ifneq ($(CONFIG_COREBOOT_BOOTBLOCK),)
all: $(board_build)/$(CB_BOOTBLOCK_FILE)
endif

else ifeq ($(CONFIG_LINUXBOOT), y)
all: $(board_build)/$(LB_OUTPUT_FILE)
else
$(error "$(BOARD): neither CONFIG_COREBOOT nor CONFIG_LINUXBOOT is set?")
endif

all payload:
	@sha256sum $< | tee -a "$(HASHES)"
	@stat -c "%8s:%n" $< | tee -a "$(SIZES)"

# Disable all built in rules
.INTERMEDIATE:
.SUFFIXES:
FORCE:

# Copies config while replacing predefined placeholders with actual values
define install_config =
	sed -e 's!@BOARD_BUILD_DIR@!$(board_build)!g' \
	    -e 's!@BLOB_DIR@!$(pwd)/blobs!g' \
	    -e 's!@BRAND_NAME@!$(BRAND_NAME)!g' \
	    "$1" > "$2"
endef

# Make helpers to operate on lists of things
# Prefix is "smart" and doesn't add the prefix for absolute file paths
define prefix =
$(foreach _, $2, $(if $(patsubst /%,,$_),$1$_,$_))
endef
define map =
$(foreach _,$2,$(eval $(call $1,$_)))
endef

# Bring in all of the module definitions;
# these are the external pieces that will be downloaded and built
# as part of creating the Heads firmware image.
include modules/*

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
	$(call do,CPIO     ,$1,\
		( cd "$2"; \
		find . \
		| cpio \
			--quiet \
			-H newc \
			-o \
		) \
		| ./bin/cpio-clean \
		> "$1.tmp" \
	)
	@if ! cmp --quiet "$1.tmp" "$1" ; then \
		mv "$1.tmp" "$1" ; \
	else \
		echo "$(DATE) UNCHANGED $(1:$(pwd)/%=%)" ; \
		rm "$1.tmp" ; \
	fi
	@sha256sum "$1" | tee -a "$(HASHES)"
	@stat -c "%8s:%n" "$1" | tee -a "$(SIZES)"
	$(call do,HASHES   , $1,\
		( cd "$2"; \
		echo "-----" ; \
		find . -type f -print0 \
		| xargs -0 sha256sum ; \
		echo "-----" ; \
		) >> "$(HASHES)" \
	)
	$(call do,SIZES    , $1,\
		( cd "$2"; \
		echo "-----" ; \
		find . -type f -print0 \
		| xargs -0 stat -c "%8s:%n" ; \
		echo "-----" ; \
		) >> "$(SIZES)" \
	)
endef

define do-copy =
	$(call do,INSTALL  ,$1 => $2,\
		if cmp --quiet "$1" "$2" ; then \
			echo "$(DATE) UNCHANGED $(1:$(pwd)/%=%)" ; \
		fi ; \
		cp -a --remove-destination "$1" "$2" ; \
	)
	@sha256sum "$(2:$(pwd)/%=%)"
	@stat -c "%8s:%n" "$(2:$(pwd)/%=%)"
endef


#
# Generate the targets for a module.
#
# Special variables like $@ must be written as $$@ to avoid
# expansion during the first evaluation.
#
define define_module =
  # if they have not defined a separate base dir, define it
  # as the same as their build dir.
  $(eval $1_base_dir = $(or $($1_base_dir),$($1_dir)))

  ifneq ("$($1_repo)","")
    $(eval $1_patch_name = $1$(if $($1_patch_version),-$($1_patch_version),))
    # First time:
    #   Checkout the tree instead and create the canary file with repo and
    #   revision so that we know that the files are all present and their
    #   version.
    #
    # Other times:
    #   If .canary contains the same repo and revision combination, do nothing.
    #   Otherwise, pull a new revision and checkout with update of submodules
    #
    # No signature hashes are checked in this case, since we don't have a
    # stable version to compare against.
    #
    # XXX: "git clean -dffx" is a hack for coreboot during commit switching, need
	#      module-specific cleanup action to get rid of it.
    $(build)/$($1_base_dir)/.canary: FORCE
	if [ ! -e "$$@" ]; then \
		git clone $($1_repo) "$(build)/$($1_base_dir)"; \
		git -C "$(build)/$($1_base_dir)" reset --hard $($1_commit_hash) && git submodule update --init --checkout; \
		echo -n '$($1_repo)|$($1_commit_hash)' > "$$@"; \
	elif [ "$$$$(cat "$$@")" != '$($1_repo)|$($1_commit_hash)' ]; then \
		echo "Switching $1 to $($1_repo) at $($1_commit_hash)" && \
		git -C "$(build)/$($1_base_dir)" fetch $($1_repo) $($1_commit_hash) && \
		git -C "$(build)/$($1_base_dir)" reset --hard $($1_commit_hash) && \
		git -C "$(build)/$($1_base_dir)" clean -df && \
		git -C "$(build)/$($1_base_dir)" clean -dffx payloads util/cbmem && \
		git -C "$(build)/$($1_base_dir)" submodule sync && \
		git -C "$(build)/$($1_base_dir)" submodule update --init --checkout && \
		echo -n '$($1_repo)|$($1_commit_hash)' > "$$@"; \
	fi
	if [ ! -e "$(build)/$($1_base_dir)/.patched" ]; then \
		if [ -r patches/$($1_patch_name).patch ]; then \
			( git apply --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) ) \
				< patches/$($1_patch_name).patch \
				|| exit 1 ; \
		fi && \
		if [ -d patches/$($1_patch_name) ] && \
		   [ -r patches/$($1_patch_name) ] ; then \
			for patch in patches/$($1_patch_name)/*.patch ; do \
				echo "Applying patch file : $$$$patch " ;  \
				( git apply --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) ) \
					< $$$$patch \
					|| exit 1 ; \
			done ; \
		fi && \
		touch "$(build)/$($1_base_dir)/.patched"; \
	fi
  else
    $(eval $1_patch_version ?= $($1_version))
    $(eval $1_patch_name = $1-$($1_patch_version))
    # Fetch and verify the source tar file
    # wget creates it early, so we have to cleanup if it fails
    $(packages)/$($1_tar):
	$(call do,WGET,$($1_url),\
		if ! $(WGET) -O "$$@.tmp" $($1_url) ; then \
			exit 1 ; \
		fi ; \
		mv "$$@.tmp" "$$@" \
	)
    $(packages)/.$1-$($1_version)_verify: $(packages)/$($1_tar)
	echo "$($1_hash)  $$^" | sha256sum --check -
	@touch "$$@"

    # Unpack the tar file and touch the canary so that we know
    # that the files are all present
    $(build)/$($1_base_dir)/.canary: $(packages)/.$1-$($1_version)_verify
	mkdir -p "$$(dir $$@)"
	tar -xf "$(packages)/$($1_tar)" $(or $($1_tar_opt),--strip 1) -C "$$(dir $$@)"
	if [ -r patches/$($1_patch_name).patch ]; then \
		( git apply --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) ) \
			< patches/$($1_patch_name).patch \
			|| exit 1 ; \
	fi
	if [ -d patches/$($1_patch_name) ] && \
	   [ -r patches/$($1_patch_name) ] ; then \
		for patch in patches/$($1_patch_name)/*.patch ; do \
			echo "Applying patch file : $$$$patch " ;  \
			( git apply --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) ) \
				< $$$$patch \
				|| exit 1 ; \
		done ; \
	fi
	@touch "$$@"
  endif

  # Allow the module to override the destination configuration file
  # via a relative path.  Linux uses this to have a per-board build.
  $(eval $1_config_file_path := $(build)/$($1_dir)/$(or $($1_config_file),.config))

  ifeq "$($1_config)" ""
    # There is no official .config file
    $($1_config_file_path): $(build)/$($1_base_dir)/.canary
	@mkdir -p $$(dir $$@)
	@touch "$$@"
  else
    # Copy the stored config file into the unpacked directory
    $($1_config_file_path): $($1_config) $(build)/$($1_base_dir)/.canary
	@mkdir -p $$(dir $$@)
	$(call do-copy,$($1_config),$$@)
  endif

  # The first time we have to wait for all the dependencies to be built
  # before we can configure the target. Once the dep has been built,
  # we only depend on it for a rebuild.
  $(eval $1_config_wait := $(foreach d,$($1_depends),\
	$(shell [ -r $(build)/$($d_dir)/.build ] || echo $d)))

  # Use the module's configure variable to build itself
  # this has to wait for the dependencies to be built since
  # cross compilers and libraries might be messed up
  $(dir $($1_config_file_path)).configured: \
		$(build)/$($1_base_dir)/.canary \
		$(foreach d,$($1_config_wait),$(build)/$($d_dir)/.build) \
		$($1_config_file_path) \
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

  # Short hand for our module build target
  $1: \
	$(build)/$($1_dir)/.build \
	$(call outputs,$1) \

  # Target for all of the outputs, which depend on their dependent modules
  # being built, as well as this module being configured
  $(call outputs,$1): $(build)/$($1_dir)/.build

  # If any of the outputs are missing, we should force a rebuild
  # of the entire module
  $(eval $1.force = $(shell \
	stat $(call outputs,$1) >/dev/null 2>/dev/null || echo FORCE \
  ))

  $(build)/$($1_dir)/.build: $($1.force) \
		$(foreach d,$($1_depends),$(build)/$($d_dir)/.build) \
		$(dir $($1_config_file_path)).configured \

	@echo "$(DATE) MAKE $1"
	+@( \
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
	$(call do,DONE,$1,\
		touch $(build)/$($1_dir)/.build \
	)



  $1.clean:
	-$(RM) "$(build)/$($1_dir)/.configured"
	-$(MAKE) -C "$(build)/$($1_dir)" clean

endef

$(call map, define_module, $(modules-y))

# hack to force musl-cross to be built before musl
#$(build)/$(musl_dir)/.configured: $(build)/$(musl-cross_dir)/../../crossgcc/x86_64-linux-musl/bin/x86_64-musl-linux-gcc

#
# Install a file into the initrd, if it changed from
# the destination file.
#
define install =
	@-mkdir -p "$(dir $2)"
	$(call do,INSTALL,$2,cp -a --remove-destination "$1" "$2")
endef

#
# Files that should be copied into the initrd
# THis should probably be done in a more scalable manner
#
define initrd_bin_add =
$(initrd_bin_dir)/$(notdir $1): $1
	$(call do,INSTALL-BIN,$$(<:$(pwd)/%=%),cp -a --remove-destination "$$<" "$$@")
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
#bin_modules-$(CONFIG_MUSL) += musl-cross
bin_modules-$(CONFIG_KEXEC) += kexec
bin_modules-$(CONFIG_TPMTOTP) += tpmtotp
bin_modules-$(CONFIG_PCIUTILS) += pciutils
bin_modules-$(CONFIG_FLASHROM) += flashrom
bin_modules-$(CONFIG_CRYPTSETUP) += cryptsetup
bin_modules-$(CONFIG_CRYPTSETUP2) += cryptsetup2
bin_modules-$(CONFIG_GPG) += gpg
bin_modules-$(CONFIG_GPG2) += gpg2
bin_modules-$(CONFIG_PINENTRY) += pinentry
bin_modules-$(CONFIG_LVM2) += lvm2
bin_modules-$(CONFIG_DROPBEAR) += dropbear
bin_modules-$(CONFIG_FLASHTOOLS) += flashtools
bin_modules-$(CONFIG_NEWT) += newt
bin_modules-$(CONFIG_CAIRO) += cairo
bin_modules-$(CONFIG_FBWHIPTAIL) += fbwhiptail
bin_modules-$(CONFIG_HOTPKEY) += hotp-verification
bin_modules-$(CONFIG_MSRTOOLS) += msrtools
bin_modules-$(CONFIG_NKSTORECLI) += nkstorecli
bin_modules-$(CONFIG_UTIL_LINUX) += util-linux
bin_modules-$(CONFIG_OPENSSL) += openssl
bin_modules-$(CONFIG_TPM2_TOOLS) += tpm2-tools
bin_modules-$(CONFIG_BASH) += bash
bin_modules-$(CONFIG_POWERPC_UTILS) += powerpc-utils
bin_modules-$(CONFIG_IO386) += io386
bin_modules-$(CONFIG_IOPORT) += ioport
bin_modules-$(CONFIG_ZSTD) += zstd

$(foreach m, $(bin_modules-y), \
	$(call map,initrd_bin_add,$(call bins,$m)) \
)

# Install the libraries for every module that we have built
$(foreach m, $(modules-y), \
	$(call map,initrd_lib_add,$(call libs,$m)) \
)

#
# hack to build cbmem from coreboot
# this must be built *AFTER* musl, but since coreboot depends on other things
# that depend on musl it should be ok.
#
COREBOOT_UTIL_DIR=$(build)/$(coreboot_base_dir)/util
ifeq ($(CONFIG_COREBOOT),y)
$(eval $(call initrd_bin_add,$(COREBOOT_UTIL_DIR)/cbmem/cbmem))
#$(eval $(call initrd_bin_add,$(COREBOOT_UTIL_DIR)/superiotool/superiotool))
#$(eval $(call initrd_bin_add,$(COREBOOT_UTIL_DIR)/inteltool/inteltool))
endif

$(COREBOOT_UTIL_DIR)/cbmem/cbmem \
$(COREBOOT_UTIL_DIR)/superiotool/superiotool \
$(COREBOOT_UTIL_DIR)/inteltool/inteltool \
: $(build)/$(coreboot_base_dir)/.canary musl-cross
	+$(call do,MAKE,$(notdir $@),\
		$(MAKE) -C "$(dir $@)" $(CROSS_TOOLS) \
	)

# superio depends on zlib and pciutils
$(COREBOOT_UTIL_DIR)/superiotool/superiotool: \
	$(build)/$(zlib_dir)/.build \
	$(build)/$(pciutils_dir)/.build \

#
# initrd image creation
#
# The initrd is constructed from various bits and pieces
# The cpio-clean program is used ensure that the files
# always have the same timestamp and appear in the same order.
#
# The blobs/dev.cpio is also included in the Linux kernel
# and has a reproducible version of /dev/console.
#
# The xz parameters are copied from the Linux kernel build scripts.
# Without them the kernel will not decompress the initrd.
#
# The padding is to ensure that if anyone wants to cat another
# file onto the initrd then the kernel will be able to find it.
#

initrd-y += $(pwd)/blobs/dev.cpio
initrd-y += $(build)/$(initrd_dir)/modules.cpio
initrd-y += $(build)/$(initrd_dir)/tools.cpio
initrd-y += $(build)/$(initrd_dir)/board.cpio
initrd-$(CONFIG_HEADS) += $(build)/$(initrd_dir)/heads.cpio

#$(build)/$(initrd_dir)/.build: $(build)/$(initrd_dir)/initrd.cpio.xz

$(build)/$(initrd_dir)/initrd.cpio.xz: $(initrd-y)
	$(call do,CPIO-XZ  ,$@,\
	$(pwd)/bin/cpio-clean \
		$^ \
	| xz \
		--check=crc32 \
		--lzma2=dict=1MiB \
		-9 \
	| dd bs=512 conv=sync status=none > "$@.tmp" \
	)
	@if ! cmp --quiet "$@.tmp" "$@" ; then \
		mv "$@.tmp" "$@" ; \
	else \
		echo "$(DATE) UNCHANGED $(@:$(pwd)/%=%)" ; \
		rm "$@.tmp" ; \
	fi
	@sha256sum "$(@:$(pwd)/%=%)" | tee -a "$(HASHES)"
	@stat -c "%8s:%n" "$(@:$(pwd)/%=%)" | tee -a "$(SIZES)"

#
# At the moment PowerPC can only load initrd bundled with the kernel.
#
bundle-$(CONFIG_LINUX_BUNDLED)	+= $(board_build)/$(LINUX_IMAGE_FILE).bundled
all: $(bundle-y)

# The board.cpio is built from the board's initrd/ directory.  It contains
# board-specific support scripts.

ifeq ($(wildcard $(pwd)/boards/$(BOARD)/initrd),)
$(build)/$(initrd_dir)/board.cpio:
	cpio -H newc -o </dev/null >"$@"
else
$(build)/$(initrd_dir)/board.cpio: FORCE
	$(call do-cpio,$@,$(pwd)/boards/$(BOARD)/initrd)
endif

#
# The heads.cpio is built from the initrd directory in the
# Heads tree.
#
$(build)/$(initrd_dir)/heads.cpio: FORCE
	$(call do-cpio,$@,$(pwd)/initrd)


#
# The tools initrd is made from all of the things that we've
# created during the submodule build.
#
$(build)/$(initrd_dir)/tools.cpio: \
	$(initrd_bins) \
	$(initrd_libs) \
	$(initrd_tmp_dir)/etc/config \

	$(call do-cpio,$@,$(initrd_tmp_dir))
	@$(RM) -rf "$(initrd_tmp_dir)"

$(initrd_tmp_dir)/etc/config: FORCE
	@mkdir -p $(dir $@)
	$(call do,INSTALL,$(CONFIG), \
		export \
			| grep ' CONFIG_' \
			| sed -e 's/^declare -x /export /' \
			-e 's/\\\"//g' \
			> $@ \
	)
	$(call do,HASH,$(GIT_HASH) $(GIT_STATUS) $(BOARD), \
		echo export GIT_HASH=\'$(GIT_HASH)\' \
		>> $@ ; \
		echo export GIT_STATUS=$(GIT_STATUS) \
		>> $@ ; \
		echo export CONFIG_BOARD=$(BOARD) \
		>> $@ ; \
		echo export CONFIG_BRAND_NAME=$(BRAND_NAME) \
		>> $@ ; \
	)

# Ensure that the initrd depends on all of the modules that produce
# binaries for it
$(build)/$(initrd_dir)/tools.cpio: $(foreach d,$(bin_modules-y),$(build)/$($d_dir)/.build)


# List of all modules, excluding the slow to-build modules
modules-slow := musl musl-cross kernel_headers
module_dirs := $(foreach m,$(filter-out $(modules-slow),$(modules-y)),$($m_dir))

echo_modules:
	echo $(module_dirs)

modules.clean:
	for dir in $(module_dirs) \
	; do \
		$(MAKE) -C "build/${CONFIG_TARGET_ARCH}/$$dir" clean ; \
		rm -f "build/${CONFIG_TARGET_ARCH}/$$dir/.configured" ; \
	done

# Inject a GPG key into the image - this is most useful when testing in qemu,
# since we can't reflash the firmware in qemu to update the keychain.  Instead,
# inject the public key ahead of time.  Specify the location of the key with
# PUBKEY_ASC.
inject_gpg: $(board_build)/$(CB_OUTPUT_FILE_GPG_INJ)

$(board_build)/$(CB_OUTPUT_BASENAME)-gpg-injected.rom: $(board_build)/$(CB_OUTPUT_FILE)
	cp "$(board_build)/$(CB_OUTPUT_FILE)" \
		"$(board_build)/$(CB_OUTPUT_FILE_GPG_INJ)"
	./bin/inject_gpg_key.sh --cbfstool "$(build)/$(coreboot_dir)/cbfstool" \
		"$(board_build)/$(CB_OUTPUT_FILE_GPG_INJ)" "$(PUBKEY_ASC)"

real.clean:
	for dir in \
		$(module_dirs) \
		$(kernel_headers) \
	; do \
		if [ ! -z "$$dir" ]; then \
			rm -rf "build/${CONFIG_TARGET_ARCH}/$$dir"; \
		fi; \
	done
	cd install && rm -rf -- *
