OUTPUT_PREFIX	:= heads-$(BOARD)-$(HEADS_GIT_VERSION)
BUNDLED_LINUX	:= $(OUTPUT_PREFIX)-zImage.bundled
OUTPUT_FILES	:= $(CB_OUTPUT_FILE) $(CB_BOOTBLOCK_FILE) $(BUNDLED_LINUX)

all: $(board_build)/$(BUNDLED_LINUX)
$(board_build)/$(BUNDLED_LINUX): $(board_build)/zImage.bundled
	$(call do-copy,$<,$@)

all: $(board_build)/$(OUTPUT_PREFIX).tgz
$(board_build)/$(OUTPUT_PREFIX).tgz: \
	$(addprefix $(board_build)/,$(OUTPUT_FILES))
	rm -rf $(board_build)/pkg # cleanup in case directory exists
	mkdir $(board_build)/pkg
	cp $^ $(board_build)/pkg
	cd $(board_build)/pkg && sha256sum * > sha256sum.txt
	cd $(board_build)/pkg && tar zcf $@ *
	rm -r $(board_build)/pkg
