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

  # Actually build the target
  $(call outputs,$1): $(build)/$($1_dir)/.configured $(call outputs,$($1_depends))
	make -C "$(build)/$($1_dir)" $($1_target)
  $1: $(call outputs,$1)

  # Update any dependencies
endef

$(foreach _, $(modules), $(eval $(call define_module,$_)))

