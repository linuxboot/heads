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


# Estimated memory required per job in GB (e.g., 1GB for gcc)
MEM_PER_JOB_GB ?= 1

# Controls how many parallel jobs are invoked in subshells
CPUS            ?= $(shell nproc)
AVAILABLE_MEM_GB   ?= $(shell cat /proc/meminfo | grep MemAvailable | awk '{print int($$2 / 1024)}')

# Calculate the maximum number of jobs based on available memory
MAX_JOBS_MEM := $(shell echo $$(( $(AVAILABLE_MEM_GB) / $(MEM_PER_JOB_GB) )))

# Use the minimum of the system's CPUs and the calculated max jobs based on memory
CPUS            := $(shell echo $$(($(CPUS) < $(MAX_JOBS_MEM) ? $(CPUS) : $(MAX_JOBS_MEM))))

# Load average can be adjusted to be higher than CPUS to allow for some CPU overcommit
# Multiply by 3 and then divide by 2 to achieve the effect of multiplying by 1.5 using integer arithmetic
LOADAVG         ?= $(shell echo $$(( ($(CPUS) * 3) / 2 )))

# Construct MAKE_JOBS with dynamic CPU count and load average
MAKE_JOBS       := -j$(CPUS) --load-average=$(LOADAVG) # Add other flags as needed to be more adaptive to CIs

# Print out the settings and compare system values with actual ones used
$(info ----------------------------------------------------------------------)
$(info !!!!!! BUILD SYSTEM INFO !!!!!!)
$(info System CPUS: $(shell nproc))
$(info System Available Memory: $(AVAILABLE_MEM_GB) GB)
$(info System Load Average: $(shell uptime | awk '{print $$10}'))
$(info ----------------------------------------------------------------------)
$(info Used **CPUS**: $(CPUS))
$(info Used **LOADAVG**: $(LOADAVG))
$(info Used **AVAILABLE_MEM_GB**: $(AVAILABLE_MEM_GB) GB)
$(info ----------------------------------------------------------------------)
$(info **MAKE_JOBS**: $(MAKE_JOBS))
$(info )
$(info Variables available for override (use 'make VAR_NAME=value'):)
$(info **CPUS** (default: number of processors, e.g., 'make CPUS=4'))
$(info **LOADAVG** (default: 1.5 times CPUS, e.g., 'make LOADAVG=54'))
$(info **AVAILABLE_MEM_GB** (default: memory available on the system in GB, e.g., 'make AVAILABLE_MEM_GB=4'))
$(info **MEM_PER_JOB_GB** (default: 1GB per job, e.g., 'make MEM_PER_JOB_GB=2'))
$(info ----------------------------------------------------------------------)
$(info !!!!!! Build starts !!!!!!)


# Timestamps should be in ISO format
DATE=`date --rfc-3339=seconds`

BOARD		?= qemu-coreboot-fbwhiptail-tpm1
CONFIG		:= $(pwd)/boards/$(BOARD)/$(BOARD).config

ifneq "y" "$(shell [ -r '$(CONFIG)' ] && echo y)"
$(error $(CONFIG): board configuration does not exist)
endif

# By default, we are building for x86, up to a board to change this variable
CONFIG_TARGET_ARCH := x86

# Legacy flash boards have to be handled specifically for some functionality
# (e.g. they don't generate upgrade packages, lack bash, etc.)  Use this to
# guard behavior that is specific to legacy flash boards only.  Don't use it for
# behavior that might be needed for other boards, use specific configs instead.
CONFIG_LEGACY_FLASH := n

include $(CONFIG)

# Include site-local/config only if it exists, downstreams can set configs for
# all boards, including overriding values specified by boards.  site-local is
# not a part of the upstream distribution but is for downstreams to insert
# customizations at well-defined points, like in coreboot:
# https://doc.coreboot.org/tutorial/managing_local_additions.html
-include $(pwd)/site-local/config

CB_OUTPUT_BASENAME	:= $(shell echo $(BRAND_NAME) | tr A-Z a-z)-$(BOARD)-$(HEADS_GIT_VERSION)
CB_OUTPUT_FILE		:= $(CB_OUTPUT_BASENAME).rom
CB_OUTPUT_FILE_GPG_INJ	:= $(CB_OUTPUT_BASENAME)-gpg-injected.rom
CB_BOOTBLOCK_FILE	:= $(CB_OUTPUT_BASENAME).bootblock
CB_UPDATE_PKG_FILE	:= $(CB_OUTPUT_BASENAME).zip
LB_OUTPUT_FILE		:= linuxboot-$(BOARD)-$(HEADS_GIT_VERSION).rom

# Unless otherwise specified, we are building for heads
CONFIG_HEADS	?= y

# Unless otherwise specified, we are building bash to have non-interactive shell for scripts (arrays and bashisms)
CONFIG_BASH	?= y

# Unless otherwise specified, we build kbd to have setfont, loadkeys and keymaps
CONFIG_KBD	?= y
#loadkeys permits to load .map source files directly
CONFIG_KBD_LOADKEYS ?= y


# USB keyboards can be ignored, optionally supported, or required.
#
# To optionally support USB keyboards, export CONFIG_SUPPORT_USB_KEYBOARD=y.  To
# default the setting to 'on', also export CONFIG_USER_USB_KEYBOARD=y.
#
# To require USB keyboard support (not user-configurable, for boards with no
# built-in keyboard), export CONFIG_USB_KEYBOARD_REQUIRED=y.
ifeq "$(CONFIG_USB_KEYBOARD_REQUIRED)" "y"
# CONFIG_USB_KEYBOARD_REQUIRED implies CONFIG_SUPPORT_USB_KEYBOARD.
export CONFIG_SUPPORT_USB_KEYBOARD=y
endif

# Determine arch part for a host triplet
ifeq "$(CONFIG_TARGET_ARCH)" "x86"
MUSL_ARCH := x86_64
else ifeq "$(CONFIG_TARGET_ARCH)" "ppc64"
MUSL_ARCH := powerpc64le
else
$(error "Unexpected value of $$(CONFIG_TARGET_ARCH): $(CONFIG_TARGET_ARCH)")
endif

ifneq "$(BOARD_TARGETS)" ""
include $(foreach TARGET,$(BOARD_TARGETS),targets/$(TARGET).mk)
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
initrd_dir		:= $(BOARD)
initrd_tmp_dir		:= $(shell mktemp -d)
initrd_tools_dir	:= $(initrd_tmp_dir)/tools
initrd_lib_dir		:= $(initrd_tools_dir)/lib
initrd_bin_dir		:= $(initrd_tools_dir)/bin
initrd_data_dir		:= $(initrd_tmp_dir)/data
modules-y += initrd

$(shell mkdir -p "$(initrd_lib_dir)" "$(initrd_bin_dir)" "$(initrd_data_dir)")

# We are running our own version of make,
# proceed with the build.

# Force pipelines to fail if any of the commands in the pipe fail
SHELL := /usr/bin/env bash
.SHELLFLAGS := -o pipefail -c

# Include the musl-cross-make module early so that $(CROSS) will
# be defined prior to any other module.
include modules/musl-cross-make

musl_dep	:= musl-cross-make
target		:= $(shell echo $(CROSS) | grep -Eoe '([^/]*?)-linux-musl')
arch		:= $(subst -linux-musl, , $(target))
heads_cc	:= $(CROSS)gcc \
	-fdebug-prefix-map=$(pwd)=heads \
	-gno-record-gcc-switches \
	-D__MUSL__ \
	--sysroot  $(INSTALL) \
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

# Legacy flash boards don't generate an update package, the only purpose of
# those boards is to be flashed over vendor firmware via an exploit.
ifneq ($(CONFIG_LEGACY_FLASH), y)
# Boards containing 'talos-2' build their own update package, which is not integrated with the ZIP method currently
ifneq ($(findstring talos-2, $(BOARD)),)
else
# Coreboot targets create an update package that can be applied with integrity
# verification before flashing (see flash-gui.sh).  The ZIP package format
# allows other metadata that might be needed to added in the future without
# breaking backward compatibility.
$(board_build)/$(CB_UPDATE_PKG_FILE): $(board_build)/$(CB_OUTPUT_FILE)
	rm -rf "$(board_build)/update_pkg"
	mkdir -p "$(board_build)/update_pkg"
	cp "$<" "$(board_build)/update_pkg/"
	cd "$(board_build)/update_pkg" && sha256sum "$(CB_OUTPUT_FILE)" >sha256sum.txt
	cd "$(board_build)/update_pkg" && zip -9 "$@" "$(CB_OUTPUT_FILE)" sha256sum.txt

# Only add the hash and size if split_8mb4mb.mk is not included
ifeq ($(wildcard split_8mb4mb.mk),)
all: $(board_build)/$(CB_OUTPUT_FILE) $(board_build)/$(CB_UPDATE_PKG_FILE)
	@sha256sum $(board_build)/$(CB_OUTPUT_FILE) | tee -a "$(HASHES)"
	@stat -c "%8s:%n" $(board_build)/$(CB_OUTPUT_FILE) | tee -a "$(SIZES)"
else
all: $(board_build)/$(CB_OUTPUT_FILE) $(board_build)/$(CB_UPDATE_PKG_FILE)
endif
endif
endif

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
# This is used in a command like 'this && $(call install_config ...) && that'
# so it needs to evaluate to a shell command.
define install_config =
	$(pwd)/bin/prepare_module_config.sh "$1" "$2" "$(board_build)" "$(BRAND_NAME)"
endef

# Make helpers to operate on lists of things
# Prefix is "smart" and doesn't add the prefix for absolute file paths
define prefix =
$(foreach _, $2, $(if $(patsubst /%,,$_),$1$_,$_))
endef
define map =
$(foreach _,$2,$(eval $(call $1,$_)))
endef

# Data files can be specified in modules/* to be added into data.cpio.
# Each module should set <modulename>_data += src|dst
# Example (in modules/ncurses):
#   ncurses_data += $(INSTALL)/usr/lib/terminfo/l/linux|etc/terminfo/l/linux
#
# The main Makefile will collect all data files from enabled modules:
#   $(call data,$(modules-y))

# Bring in all of the module definitions;
# these are the external pieces that will be downloaded and built
# as part of creating the Heads firmware image.
include modules/*

# Collect all data files from enabled modules
data_files :=
$(foreach m,$(modules-y),$(eval data_files += $($(m)_data)))

define bins =
$(foreach m,$1,$(call prefix,$(build)/$($m_dir)/,$($m_output)))
endef
define data =
$(foreach m,$1,$(call prefix,$(build)/$($m_dir)/,$($m_data)))
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
  # Dynamically defined modules must tell us what module file defined them
  $(eval $1_module_file = $(or $($1_module_file),$1))

  ifneq ("$($1_repo)","")
    $(eval $1_patch_name = $1$(if $($1_patch_version),-$($1_patch_version),))
    # First time:
    #   Checkout the tree instead and create the canary file with repo and
    #   revision so that we know that the files are all present and their
    #   version.  Submodules are _not_ checked out, because coreboot has
    #   many submodules that won't be used, let coreboot check out its own
    #   submodules during build
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
	if [ ! -e "$$@" ] && [ ! -d "$(build)/$($1_base_dir)" ]; then \
		echo "INFO: .canary file and directory not found. Cloning repository $($1_repo) into $(build)/$($1_base_dir)" && \
		git clone $($1_repo) "$(build)/$($1_base_dir)" && \
		echo "INFO: Resetting repository to commit $($1_commit_hash)" && \
		git -C "$(build)/$($1_base_dir)" reset --hard $($1_commit_hash) && \
		echo "INFO: Creating .canary file with repo and commit hash" && \
		echo -n '$($1_repo)|$($1_commit_hash)' > "$$@" ; \
	elif [ ! -e "$$@" ] || [ "$$$$(cat "$$@")" != '$($1_repo)|$($1_commit_hash)' ]; then \
		echo "INFO: .canary file missing or differs. Resetting $1 to $($1_repo) at $($1_commit_hash)" && \
		git -C "$(build)/$($1_base_dir)" reset --hard HEAD^ && \
		echo "INFO: Fetching commit $($1_commit_hash) from $($1_repo) (without recursing submodules)" && \
		git -C "$(build)/$($1_base_dir)" fetch $($1_repo) $($1_commit_hash) --recurse-submodules=no && \
		echo "INFO: Resetting repository to commit $($1_commit_hash)" && \
		git -C "$(build)/$($1_base_dir)" reset --hard $($1_commit_hash) && \
		echo "INFO: Cleaning repository directory (including payloads and util/cbmem)" && \
		git -C "$(build)/$($1_base_dir)" clean -df && \
		git -C "$(build)/$($1_base_dir)" clean -dffx payloads util/cbmem && \
		echo "INFO: Synchronizing submodules" && \
		git -C "$(build)/$($1_base_dir)" submodule sync && \
		echo "INFO: Updating submodules (init and checkout)" && \
		git -C "$(build)/$($1_base_dir)" submodule update --init --checkout && \
		echo "INFO: Updating .canary file with new repo info" && \
		echo -n '$($1_repo)|$($1_commit_hash)' > "$$@" ; \
	fi
	if [ ! -e "$(build)/$($1_base_dir)/.patched" ]; then \
		echo "INFO: .patched file not found. Beginning patch application for $1" && \
		if [ -r patches/$($1_patch_name).patch ]; then \
			echo "INFO: Applying single patch file: patches/$($1_patch_name).patch" && \
			if ! git apply --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) < patches/$($1_patch_name).patch; then \
				echo "ERROR: Failed to apply patch: patches/$($1_patch_name).patch. Reversing and reapplying." && \
				git apply --reverse --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) < patches/$($1_patch_name).patch || true && \
				git apply --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) < patches/$($1_patch_name).patch || exit 1; \
			fi; \
		fi; \
		if [ -d patches/$($1_patch_name) ]; then \
			echo "INFO: Applying multiple patch files from directory: patches/$($1_patch_name)" && \
			for patch in patches/$($1_patch_name)/*.patch; do \
				echo "INFO: Applying patch file: $$$$patch" && \
				if ! git apply --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) < "$$$$patch"; then \
					echo "ERROR: Failed to apply patch: $$$$patch. Reversing and reapplying." && \
					git apply --reverse --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) < "$$$$patch" || true && \
					git apply --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) < "$$$$patch" || exit 1; \
				fi; \
			done; \
		fi; \
		echo "INFO: Patches applied successfully. Creating .patched file." && \
		touch "$(build)/$($1_base_dir)/.patched"; \
	fi
  else
    # Versioned modules (each version a separate module) don't need to include
    # the version a second time.  (The '-' separator is also omitted then.)
    # $1_patch_version can still be defined manually.
    $(eval $1_patch_version ?= $(if $(filter %-$($1_version),$1),,$($1_version)))
    $(eval $1_patch_name = $1$(if $($1_patch_version),-,)$($1_patch_version))
    # Fetch and verify the source tar file
    # wget creates it early, so we have to cleanup if it fails
    $(packages)/$($1_tar):
	$(call do,WGET,$($1_url),\
		WGET="$(WGET)" bin/fetch_source_archive.sh "$($1_url)" "$$@" "$($1_hash)"
	)

    # Target to fetch all packages, for seeding mirrors
    packages: $(packages)/$($1_tar)

    # Unpack the tar file and touch the canary so that we know
    # that the files are all present
    $(build)/$($1_base_dir)/.canary: $(packages)/$($1_tar)
	mkdir -p "$$(dir $$@)"
	tar -xf "$(packages)/$($1_tar)" $(or $($1_tar_opt),--strip 1) -C "$$(dir $$@)"
	if [ -r patches/$($1_patch_name).patch ]; then \
		echo "INFO: Applying single patch file: patches/$($1_patch_name).patch" && \
		if ! ( git apply --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) < patches/$($1_patch_name).patch ); then \
			echo "ERROR: Failed to apply patch: patches/$($1_patch_name).patch. Reversing and reapplying." && \
			( git apply --reverse --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) < patches/$($1_patch_name).patch ) || true && \
			( git apply --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) < patches/$($1_patch_name).patch ) || exit 1 ; \
		fi ; \
	fi ; \
	if [ -d patches/$($1_patch_name) ]; then \
		echo "INFO: Applying multiple patch files from directory: patches/$($1_patch_name)" && \
		for patch in patches/$($1_patch_name)/*.patch; do \
			echo "INFO: Applying patch file: $$$$patch" && \
			if ! ( git apply --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) < $$$$patch ); then \
				echo "ERROR: Failed to apply patch: $$$$patch. Reversing and reapplying." && \
				( git apply --reverse --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) < $$$$patch ) || true && \
				echo "INFO: Reapplying patch file: $$$$patch" && \
				( git apply --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) < $$$$patch ) || exit 1 ; \
			fi ; \
		done ; \
	fi
	if [ ! -e "$$@" ] && [ -e "$(build)/$($1_base_dir)/.patched" ]; then \
		echo "INFO: .canary file not found but .patched exists. Reversing and reapplying patches for $1" && \
		if [ -r patches/$($1_patch_name).patch ]; then \
			echo "INFO: Reversing single patch file: patches/$($1_patch_name).patch." && \
			( git apply --reverse --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) < patches/$($1_patch_name).patch ) || true && \
			echo "INFO: Reapplying single patch file: patches/$($1_patch_name).patch." && \
			( git apply --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) < patches/$($1_patch_name).patch ) || exit 1 ; \
		fi ; \
		if [ -d patches/$($1_patch_name) ]; then \
			echo "INFO: Reversing and reapplying multiple patch files from directory: patches/$($1_patch_name)" && \
			for patch in patches/$($1_patch_name)/*.patch; do \
				echo "INFO: Reversing patch file: $$$$patch" && \
				( git apply --reverse --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) < $$$$patch ) || true && \
				echo "INFO: Reapplying patch file: $$$$patch" && \
				( git apply --verbose --reject --binary --directory build/$(CONFIG_TARGET_ARCH)/$($1_base_dir) < $$$$patch ) || exit 1 ; \
			done ; \
		fi ; \
		rm -f "$(build)/$($1_base_dir)/.patched" ; \
	fi
	touch "$$@"
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
		modules/$($1_module_file)
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

  #TODO: something better then removing .build: $($1.force) so that newt/ncurses are not rebuilt inconditionally?
  $(build)/$($1_dir)/.build: \
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

# hack to force musl-cross-make to be built before musl
#$(build)/$(musl_dir)/.configured: $(build)/$(musl-cross-make_dir)/../../crossgcc/x86_64-linux-musl/bin/x86_64-musl-linux-gcc

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
# This should probably be done in a more scalable manner
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
#bin_modules-$(CONFIG_MUSL) += musl-cross-make
bin_modules-$(CONFIG_KEXEC) += kexec
bin_modules-$(CONFIG_TPMTOTP) += tpmtotp
bin_modules-$(CONFIG_PCIUTILS) += pciutils
bin_modules-$(CONFIG_FLASHROM) += flashrom
bin_modules-$(CONFIG_FLASHPROG) += flashprog
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
bin_modules-$(CONFIG_KBD) += kbd
bin_modules-$(CONFIG_ZSTD) += zstd
bin_modules-$(CONFIG_E2FSPROGS) += e2fsprogs
bin_modules-$(CONFIG_EXFATPROGS) += exfatprogs

$(foreach m, $(bin_modules-y), \
	$(call map,initrd_bin_add,$(call bins,$m)) \
)

# Install the data for every module that we have built
$(foreach m, $(modules-y), \
	$(call map,initrd_data_add,$(call data,$m)) \
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
: $(build)/$(coreboot_base_dir)/.canary musl-cross-make
	+$(call do,MAKE,$(notdir $@),\
		$(MAKE) -C "$(dir $@)" $(CROSS_TOOLS) \
	)

# superio depends on zlib and pciutils
$(COREBOOT_UTIL_DIR)/superiotool/superiotool: \
	$(build)/$(zlib_dir)/.build \
	$(build)/$(pciutils_dir)/.build \

#
# --- INITRD IMAGE CREATION ---
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

# --- DATA.CPIO STAGING AND CREATION ---

# Macro to handle staging of data files into the initrd temporary data directory
# Arguments:
#   1: Source path (file or directory)
#   2: Destination path inside initrd (relative path inside archive)
define stage_data_file =
$(initrd_data_dir)/$2: $1
	$(call do,INSTALL-DATA,$(1:$(pwd)/%=%) => $2,\
		mkdir -p "$(dir $(initrd_data_dir)/$2)"; \
		cp -R "$1" "$(initrd_data_dir)/$2"; \
	)
data_initrd_files += $(initrd_data_dir)/$2
endef

# Expand all data_files entries. Each entry: "src_path|dest_path"
$(foreach entry,$(data_files),\
  $(eval src := $(word 1,$(subst |, ,$(entry)))) \
  $(eval dst := $(word 2,$(subst |, ,$(entry)))) \
  $(eval $(call stage_data_file,$(src),$(dst))) \
)

# Rule to build final data.cpio archive from staged files
ifneq ($(strip $(data_files)),)
$(build)/$(initrd_dir)/data.cpio: $(data_initrd_files) FORCE
	$(call do-cpio,$@,$(initrd_data_dir))
	@$(RM) -rf "$(initrd_data_dir)"
initrd-y += $(build)/$(initrd_dir)/data.cpio
endif

# --- MODULES.CPIO ---

# modules.cpio is built from kernel modules staged in a temp dir by modules/linux
# The temp dir is cleaned up after cpio creation.
# (see modules/linux for details)

# --- TOOLS.CPIO ---

# tools.cpio is built from all binaries, libraries, and config staged in initrd_tools_dir
$(build)/$(initrd_dir)/tools.cpio: \
	$(initrd_bins) \
	$(initrd_libs) \
	$(initrd_tools_dir)/etc/config \
	FORCE
	$(call do-cpio,$@,$(initrd_tools_dir))
	@$(RM) -rf "$(initrd_tools_dir)"

# --- TOOLS.CPIO'S ETC/CONFIG  ---
#	This is board's config provided defaults (at compilation time)
#  Those defaults can be overriden by cbfs' config.user applied at init through cbfs-init.
#   To view overriden exports at runtime, simply run 'env' and review CONFIG_ exported variables
#   To view compilation time board's config; check /etc/config under recovery shell.
$(initrd_tools_dir)/etc/config: FORCE
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

# --- BOARD.CPIO ---

# board.cpio is built from the board's initrd/ directory and contains 
#  board-specific support scripts.
ifeq ($(wildcard $(pwd)/boards/$(BOARD)/initrd),)
$(build)/$(initrd_dir)/board.cpio:
	# Only create a board.cpio if the board has a initrd directory
	cpio -H newc -o </dev/null >"$@"
else
$(build)/$(initrd_dir)/board.cpio: FORCE
	$(call do-cpio,$@,$(pwd)/boards/$(BOARD)/initrd)
endif

# --- HEADS.CPIO ---

# heads.cpio is built from the initrd directory in the Heads tree
#  This is heads security policies, executed by board's CONFIG_BOOTSCRIPT at init
$(build)/$(initrd_dir)/heads.cpio: FORCE
	$(call do-cpio,$@,$(pwd)/initrd)

# --- FINAL INITRD PACKAGING ---

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

# --- BUNDLED INITRD FOR POWERPC ---

bundle-$(CONFIG_LINUX_BUNDLED)	+= $(board_build)/$(LINUX_IMAGE_FILE).bundled
all: $(bundle-y)

# Ensure that the initrd depends on all of the modules that produce
# binaries for it
$(build)/$(initrd_dir)/tools.cpio: $(foreach d,$(bin_modules-y),$(build)/$($d_dir)/.build)


# List of all modules, excluding the slow to-build modules
modules-slow := musl musl-cross-make kernel_headers
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






# --- Development helpers ---
# Development targets for moving boards between states

board.move_untested_to_tested:
	@echo "Moving $(BOARD) from UNTESTED to tested status"
	@NEW_BOARD=$$(echo $(BOARD) | sed 's/^UNTESTED_//'); \
	INCLUDE_BOARD=$$(grep "include \$$(pwd)/boards/" boards/$(BOARD)/$(BOARD).config | sed 's/.*boards\/\(.*\)\/.*/\1/'); \
	NEW_INCLUDE_BOARD=$$(echo $$INCLUDE_BOARD | sed 's/^UNTESTED_//'); \
	echo "Updating config file: boards/$(BOARD)/$(BOARD).config"; \
	sed -i 's/$(BOARD)/'$${NEW_BOARD}'/g' boards/$(BOARD)/$(BOARD).config; \
	sed -i 's/'$$INCLUDE_BOARD'/'$$NEW_INCLUDE_BOARD'/g' boards/$(BOARD)/$(BOARD).config; \
	echo "Renaming config file to $${NEW_BOARD}.config"; \
	git mv boards/$(BOARD)/$(BOARD).config boards/$(BOARD)/$${NEW_BOARD}.config; \
	echo "Renaming board directory to $${NEW_BOARD}"; \
	git mv boards/$(BOARD) boards/$${NEW_BOARD}; \
	echo "Updating .circleci/config.yml"; \
	sed -i "s/$(BOARD)/$${NEW_BOARD}/g" .circleci/config.yml; \
	echo "Operation completed for $(BOARD) -> $${NEW_BOARD}"

board.move_unmaintained_to_tested:
	@echo "NEW_BOARD variable will remove UNMAINTAINED_ prefix from $(BOARD)"
	@NEW_BOARD=$$(echo $(BOARD) | sed 's/^UNMAINTAINED_//'); \
	echo "Renaming boards/$$BOARD/$$BOARD.config to boards/$$BOARD/$$NEW_BOARD.config"; \
	git mv boards/$$BOARD/$$BOARD.config boards/$$BOARD/$$NEW_BOARD.config; \
	echo "Renaming boards/$$BOARD to boards/$$NEW_BOARD"; \
	rm -rf boards/$$NEW_BOARD; \
	git mv boards/$$BOARD boards/$$NEW_BOARD; \
	echo "Replacing $$BOARD with $$NEW_BOARD in .circleci/config.yml"; \
	sed -i "s/$$BOARD/$$NEW_BOARD/g" .circleci/config.yml; \
	echo "Board $$BOARD has been moved to tested status as $$NEW_BOARD"; \
	echo "Please review and update .circleci/config.yml manually if needed"

board.move_untested_to_unmaintained:
	@echo "NEW_BOARD variable will move from UNTESTED_ to UNMAINTAINED_ from $(BOARD)"
	@NEW_BOARD=$$(echo $(BOARD) | sed 's/^UNTESTED_/UNMAINTAINED_/g'); \
	echo "Renaming boards/$$BOARD/$$BOARD.config to boards/$$BOARD/$$NEW_BOARD.config"; \
	mkdir -p unmaintained_boards; \
	git mv boards/$$BOARD/$$BOARD.config unmaintained_boards/$$BOARD/$$NEW_BOARD.config; \
	echo "Renaming boards/$$BOARD to unmaintainted_boards/$$NEW_BOARD"; \
	rm -rf boards/$$NEW_BOARD; \
	git mv boards/$$BOARD unmaintained_boards/$$NEW_BOARD; \
	echo "Replacing $$BOARD with $$NEW_BOARD in .circleci/config.yml. Delete manually entries"; \
	sed -i "s/$$BOARD/$$NEW_BOARD/g" .circleci/config.yml

board.move_tested_to_untested:
	@echo "NEW_BOARD variable will add UNTESTED_ prefix to $(BOARD)"
	@NEW_BOARD=UNTESTED_$(BOARD); \
	rm -rf boards/$${NEW_BOARD}; \
	echo "Renaming boards/$(BOARD)/$(BOARD).config to boards/$(BOARD)/$${NEW_BOARD}.config"; \
	git mv boards/$(BOARD)/$(BOARD).config boards/$(BOARD)/$${NEW_BOARD}.config; \
	echo "Renaming boards/$(BOARD) to boards/$${NEW_BOARD}"; \
	git mv boards/$(BOARD) boards/$${NEW_BOARD}; \
	echo "Replacing $(BOARD) with $${NEW_BOARD} in .circleci/config.yml"; \
	sed -i "s/$(BOARD)/$${NEW_BOARD}/g" .circleci/config.yml

board.move_tested_to_EOL:
	@echo "NEW_BOARD variable will EOL_$(BOARD)"
	@NEW_BOARD=EOL_$(BOARD); \
	rm -rf boards/$${NEW_BOARD}; \
	echo "Renaming boards/$(BOARD)/$(BOARD).config to boards/$(BOARD)/$${NEW_BOARD}.config"; \
	git mv boards/$(BOARD)/$(BOARD).config boards/$(BOARD)/$${NEW_BOARD}.config; \
	echo "Renaming boards/$(BOARD) to boards/$${NEW_BOARD}"; \
	git mv boards/$(BOARD) boards/$${NEW_BOARD}; \
	echo "Replacing $(BOARD) with $${NEW_BOARD} in .circleci/config.yml"; \
	sed -i "s/$(BOARD)/$${NEW_BOARD}/g" .circleci/config.yml

board.move_tested_to_unmaintained:
	@echo "Moving $(BOARD) from tested to unmaintained status"
	@NEW_BOARD=UNMAINTAINED_$(BOARD); \
	INCLUDE_BOARD=$$(grep "include \$$(pwd)/boards/" boards/$(BOARD)/$(BOARD).config | sed 's/.*boards\/\(.*\)\/.*/\1/'); \
	NEW_INCLUDE_BOARD=UNMAINTAINED_$${INCLUDE_BOARD}; \
	echo "Updating config file: boards/$(BOARD)/$(BOARD).config"; \
	sed -i 's/$(BOARD)/'$${NEW_BOARD}'/g' boards/$(BOARD)/$(BOARD).config; \
	if [ -n "$$INCLUDE_BOARD" ]; then \
		sed -i 's/'$$INCLUDE_BOARD'/'$$NEW_INCLUDE_BOARD'/g' boards/$(BOARD)/$(BOARD).config; \
	fi; \
	echo "Creating unmaintained_boards directory if it doesn't exist"; \
	mkdir -p unmaintained_boards/$${NEW_BOARD}; \
	echo "Moving and renaming config file to unmaintained_boards/$${NEW_BOARD}/$${NEW_BOARD}.config"; \
	git mv boards/$(BOARD)/$(BOARD).config unmaintained_boards/$${NEW_BOARD}/$${NEW_BOARD}.config; \
	echo "Moving board directory contents to unmaintained_boards/$${NEW_BOARD}"; \
	git mv boards/$(BOARD)/* unmaintained_boards/$${NEW_BOARD}/; \
	rmdir boards/$(BOARD); \
	echo "Updating .circleci/config.yml"; \
	sed -i "s/$(BOARD)/$${NEW_BOARD}/g" .circleci/config.yml; \
	echo "Operation completed for $(BOARD) -> $${NEW_BOARD}"; \
	echo "Please manually review and remove any unnecessary entries in .circleci/config.yml"

#Dev cycles helpers:

# Helper function to overwrite coreboot git repo's .canary file with a bogus commit (.canary checked for matching commit on build)
#  TODO: Implement a cleaner solution to ensure files created by patches are properly deleted instead of requiring manual intervention.
define overwrite_canary_if_coreboot_git
	@echo "Checking for coreboot directory: build/${CONFIG_TARGET_ARCH}/coreboot-$(CONFIG_COREBOOT_VERSION)"
	if [ -d "build/${CONFIG_TARGET_ARCH}/coreboot-$(CONFIG_COREBOOT_VERSION)" ] && \
	   [ -d "build/${CONFIG_TARGET_ARCH}/coreboot-$(CONFIG_COREBOOT_VERSION)/.git" ]; then \
		echo "INFO: Recreating .canary file for 'build/${CONFIG_TARGET_ARCH}/coreboot-$(CONFIG_COREBOOT_VERSION)' with placeholder." && \
		echo BOGUS_COMMIT_ID > "build/${CONFIG_TARGET_ARCH}/coreboot-$(CONFIG_COREBOOT_VERSION)/.canary" && \
		echo "INFO: .canary file has been recreated." ; \
	else \
		echo "INFO: Coreboot directory or .git not found, skipping .canary overwrite." ; \
	fi
endef

real.clean:
	@echo "Cleaning build artifacts and install directories, leaving crossgcc intact."
	for dir in \
		$(module_dirs) \
		$(kernel_headers) \
	; do \
		if [ ! -z "$$dir" ]; then \
			rm -rf "build/${CONFIG_TARGET_ARCH}/$$dir" ; \
		fi ; \
	done
	cd install && rm -rf -- *
	$(call overwrite_canary_if_coreboot_git)

real.gitclean:
	@echo "Cleaning the repository using Git ignore file as a base..."
	@echo "This will wipe everything not in the Git tree, but keep downloaded coreboot forks (detected as Git repos)."
	git clean -fxd
	$(call overwrite_canary_if_coreboot_git)

real.gitclean_keep_packages:
	@echo "Cleaning the repository using Git ignore file as a base..."
	@echo "This will wipe everything not in the Git tree, but keep the 'packages' directory."
	git clean -fxd -e "packages"
	$(call overwrite_canary_if_coreboot_git)

real.remove_canary_files-extract_patch_rebuild_what_changed:
	@echo "Removing 'canary' files to force Heads to restart building board configurations..."
	@echo "This will check package integrity, extract them, redo patching on files, and rebuild what needs to be rebuilt."
	@echo "It will also reinstall the necessary files under './install'."
	@echo "Limitations: If a patch creates a file in an extracted package directory, this approach may fail without further manual actions."
	@echo "In such cases, Git will inform you about the file that couldn't be created as expected. Simply delete those files and relaunch the build."
	@echo "This approach economizes time since most build artifacts do not need to be rebuilt, as the file dates should be the same as when you originally built them."
	@echo "Only a minimal time is needed for rebuilding, which is also good for your SSD."
	@echo "*** USE THIS APPROACH FIRST ***"
	@echo "Removing ./build .canary files..."
	@find ./build/ -type f -name ".canary" -print -delete || true
	@echo "Removing install/*/* content..."
	@find ./install/*/* -print -exec rm -rf {} + 2>/dev/null || true
	@echo "Removing coreboot board related artifact directory: $(build)/$(coreboot_dir)"
	rm -rf "$(build)/$(coreboot_dir)"
	@echo "Removing coreboot board related artifacts directory $(board_build)"
	rm -rf "$(board_build)"
	$(call overwrite_canary_if_coreboot_git)

real.gitclean_keep_packages_and_build:
	@echo "Cleaning the repository using Git ignore file as a base..."
	@echo "This will wipe everything not in the Git tree, but keep the 'packages' and 'build' directories."
	git clean -fxd -e "packages" -e "build"
	$(call overwrite_canary_if_coreboot_git)
