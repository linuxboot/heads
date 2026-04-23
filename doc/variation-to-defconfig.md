# Configuration Helper Targets

Heads provides make targets for saving and modifying coreboot and Linux configurations in both defconfig (minimal) and oldconfig (full) formats.

## Coreboot Config Helpers

Run from the heads directory with `make BOARD=<board> <target>`:

| Target | Description |
|--------|-------------|
| `coreboot.save_in_defconfig_format_in_place` | Regenerate minimal defconfig, overwrites `config/coreboot-<board>.config` |
| `coreboot.save_in_oldconfig_format_in_place` | Regenerate full oldconfig, overwrites `config/coreboot-<board>.config` |
| `coreboot.save_in_defconfig_format_backup` | Save minimal defconfig to `config/coreboot-<board>.config_defconfig` (backup) |
| `coreboot.modify_defconfig_in_place` | Open menuconfig, then save minimal defconfig in place |
| `coreboot.modify_and_save_oldconfig_in_place` | Open menuconfig, then save full config in place |

## Linux Config Helpers

Run from the heads directory with `make BOARD=<board> <target>`:

| Target | Description |
|--------|-------------|
| `linux.save_in_defconfig_format_in_place` | Regenerate minimal defconfig, overwrites `config/linux-<board>.config` |
| `linux.save_in_versioned_defconfig_format` | Save minimal defconfig to `config/linux-<board>.config_defconfig_<version>` |
| `linux.save_in_olddefconfig_format_in_place` | Regenerate full config with new symbols set to defaults, overwrites in place |
| `linux.save_in_versioned_oldconfig` | Save full config to `config/linux-<board>.config_oldconfig_<version>` |
| `linux.modify_and_save_defconfig_in_place` | Open menuconfig, then save minimal defconfig in place |
| `linux.modify_and_save_oldconfig_in_place` | Open menuconfig, then save full config in place |
| `linux.prompt_for_new_config_options_for_kernel_version_bump` | Interactively prompt for new kernel config options during version bump |

## Usage Notes

- **defconfig** (minimal): Only contains options that differ from the default. Preferred for PRs.
- **oldconfig** (full): Contains all explicitly set options. Use for kernel version bumps to preserve all settings.

Example for kernel version bump:
```bash
# First, save current config in oldconfig format
make BOARD=kgpe-d16_server linux.save_in_oldconfig_format_in_place
# Then bump CONFIG_LINUX_VERSION in board config
# Build to extract new linux tarball
make BOARD=kgpe-d16_server
# Finally, prompt for new config options
make BOARD=kgpe-d16_server linux.prompt_for_new_config_options_for_kernel_version_bump
```

---

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
