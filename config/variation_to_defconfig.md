# Variation to defconfig (cleaned)

This file lists configuration items found to be inconsistent and/or removed when generating defconfig with `make BOARD=XYZ coreboot.save_in_defconfig_format_in_place` helper for different boards. 


## Questionable configs

These options are inconsistent across boards and should be reviewed.

### Global

```text
CONFIG_USE_OPTION_TABLE=y
CONFIG_STATIC_OPTION_TABLE=y
# CONFIG_USE_PC_CMOS_ALTCENTURY is not set
# CONFIG_DRIVERS_MTK_WIFI is not set
# CONFIG_DRIVERS_INTEL_WIFI is not set
# CONFIG_RAMINIT_ENABLE_ECC is not set
# CONFIG_TIMESTAMPS_ON_CONSOLE is not set
CONFIG_PCI_ALLOW_BUS_MASTER=y
```

### Specifics

#### T480

```text
CONFIG_USE_LEGACY_8254_TIMER=y
```

## Removed undesirables

The following lines were removed from specific board defconfig variations. Filenames (when present) are listed above their removed fragments.

```text
config/coreboot-optiplex-7019_9010-maximized.config
CONFIG_TIMESTAMPS_ON_CONSOLE=y
config/coreboot-optiplex-7019_9010_TXT-maximized.config
IDEM
config/coreboot-qemu-tpm1-prod.config
# CONFIG_INCLUDE_CONFIG_FILE is not set
# CONFIG_CONSOLE_SERIAL is not set
# CONFIG_POST_DEVICE is not set
# CONFIG_POST_IO is not set
CONFIG_PCIEXP_ASPM=y
CONFIG_PCIEXP_HOTPLUG_BUSES=32
CONFIG_PCIEXP_COMMON_CLOCK=y
CONFIG_PCIEXP_HOTPLUG_IO=0x2000
config/coreboot-qemu-tpm1.config
IDEM
config/coreboot-qemu-tpm2-prod.config
IDEM
config/coreboot-qemu-tpm2.config
IDEM
config/coreboot-t420-maximized.config
CONFIG_PCIEXP_HOTPLUG_IO=0x2000
config/coreboot-t430-maximized.config
CONFIG_PCIEXP_HOTPLUG_IO=0x2000
config/coreboot-t480-maximized.config
CONFIG_USE_LEGACY_8254_TIMER=y
CONFIG_PCIEXP_HOTPLUG=y
config/coreboot-w530-maximized.config
CONFIG_PCIEXP_HOTPLUG_IO=0x2000
config/coreboot-x220-maximized.config
CONFIG_PCIEXP_HOTPLUG_IO=0x2000
config/coreboot-x230-maximized-fhd_edp.config
CONFIG_PCIEXP_HOTPLUG_IO=0x2000
config/coreboot-x230-maximized.config
CONFIG_PCIEXP_HOTPLUG_IO=0x2000
# CONFIG_PCI_ALLOW_BUS_MASTER is not set
CONFIG_PCIEXP_HOTPLUG_IO=0x2000
```
