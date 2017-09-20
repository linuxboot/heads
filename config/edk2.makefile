# Wrapper around the edk2 "build" script to generate
# the few files that we actually want and avoid rebuilding
# if we don't have to.

PWD := $(shell pwd)
EDK2_OUTPUT_DIR := $(PWD)/Build/MdeModule/DEBUG_GCC5/X64/MdeModulePkg/Core
EDK2_BIN_DIR := $(PWD)/BaseTools/BinWrappers/PosixLike

export PATH := $(EDK2_BIN_DIR):$(PATH)
export CONFIG_PATH := $(PWD)/Conf
export EDK_TOOLS_PATH := $(PWD)/BaseTools
export WORKSPACE := $(PWD)

EDK2_BINS += Dxe/DxeMain/DEBUG/DxeCore.efi
EDK2_BINS += RuntimeDxe/RuntimeDxe/DEBUG/RuntimeDxe.efi

EDK2_OUTPUTS = $(addprefix $(EDK2_OUTPUT_DIR)/,$(EDK2_BINS))

# build takes too long, so we check to see if our executables exist
# before we start a build.  run the clean target if they must be rebuilt
all: $(EDK2_OUTPUTS)
	ls -Fla $(EDK2_OUTPUTS)
	cp -a $(EDK2_OUTPUTS) .

$(EDK2_OUTPUTS):
	build

clean:
	$(RM) $(EDK2_OUTPUTS)

real-clean: clean
	build clean
