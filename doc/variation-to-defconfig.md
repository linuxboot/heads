# Variation to defconfig (cleaned)

This file lists coreboot Kconfig options found to be inconsistent across
boards after regenerating defconfigs with `make BOARD=XYZ
coreboot.save_in_defconfig_format_in_place`.  The goal is to document
which values are "intentional" per-board differences vs. stale defaults
that should be uniform.

## CMOS option backend: OPTION_BACKEND_NONE vs USE_OPTION_TABLE

Coreboot can read configuration values (boot order, debug level, power-on
behavior, etc.) from either compiled-in defaults or from CMOS NVRAM.

```
OPTION_BACKEND_NONE  (default in Heads)
USE_OPTION_TABLE     (explicit CMOS option table)
```

`OPTION_BACKEND_NONE` means every value comes from the `.config` --
Heads manages all runtime config through its initrd scripts and TPM
measured boot, so the coreboot option table is redundant.

`USE_OPTION_TABLE` means coreboot reads those values from CMOS and the
cmos.layout / cmos.default files are used at runtime.  It also affects
defaults of related options:

| Option | Default when OPTION_BACKEND_NONE | Default when USE_OPTION_TABLE=y |
|---|---|---|
| `USE_PC_CMOS_ALTCENTURY` | `y` | `n` |
| `STATIC_OPTION_TABLE` | absent | depends on board |

**Heads impact:** Neither breaks anything.  `OPTION_BACKEND_NONE` is
preferred since Heads does not rely on coreboot's CMOS option table.

## Current state audit

Options are listed with their current count across all
`config/coreboot-*.config` files and the per-board breakdown.

### CONFIG_USE_OPTION_TABLE

Total: **12 `=y`**, **35 `not set`**

`=y` boards (use CMOS option table):
`kgpe-d16_server`, `kgpe-d16_server-whiptail`, `kgpe-d16_workstation`,
`kgpe-d16_workstation-usb_keyboard`, `librem_mini`, `librem_mini_v2`,
`t430-legacy`, `t430-maximized`, `t530-dgpu-maximized`,
`w530-dgpu-K1000m-maximized`, `w530-dgpu-K2000m-maximized`,
`w530-maximized`

Notable: among Ivy Bridge ThinkPads, T430/T530/W530 use option table but
x230 does not -- this appears to be a historical artifact, not a
technical requirement.

### CONFIG_STATIC_OPTION_TABLE

Total: **6 `=y`**, **6 `not set`**, rest absent (irrelevant when `USE_OPTION_TABLE=n`)

Only meaningful when `USE_OPTION_TABLE=y`.  `=y` resets CMOS to defaults
every boot.  Present on: `t430-legacy`, `t430-maximized`,
`t530-dgpu-maximized`, `w530-dgpu-K1000m-maximized`,
`w530-dgpu-K2000m-maximized`, `w530-maximized`.

### CONFIG_USE_PC_CMOS_ALTCENTURY

Writes century byte to CMOS register `0x32` (`RTC_CLK_ALTCENTURY`) and
reports it in ACPI FADT.  Coreboot default is `y` when
`!USE_OPTION_TABLE`.  Help: "May be useful for legacy OSes that assume
its presence."  Heads boots Linux directly which handles century
internally -- no functional impact either way.

Total: **29 `=y`**, **18 `not set`**

`=y` boards (using coreboot default, never explicitly disabled):
`librem_11`, `librem_13v2`, `librem_13v4`, `librem_14`,
`librem_15v3`, `librem_15v4`, `librem_l1um_v2`, `m900-maximized`,
`msi_z690a_ddr4`, `msi_z690a_ddr5`, `msi_z790p_ddr4`,
`msi_z790p_ddr5`, `optiplex-7019_9010-maximized`,
`optiplex-7019_9010_TXT-maximized`, `p8z77-m_pro-tpm1`,
`qemu-tpm1`, `qemu-tpm1-prod`, `qemu-tpm2`, `qemu-tpm2-prod`,
`t420`, `t440p`, `t480-maximized`, `t480s-maximized`,
`t520-maximized`, `w541`, `x220`, `x220-maximized`,
`x230-maximized-fhd_edp`, `z220-cmt`

`not set` boards (explicitly cleaned):
`librem_mini`, `librem_mini_v2`, `nitropad-ns50`,
`novacustom-nv4x_adl`, `novacustom-v540tu`, `novacustom-v560tu`,
`t420-maximized` *(cleaned 2026-07-01)*, `t430-legacy`,
`t430-legacy-flash`, `t430-maximized`, `t530-dgpu-maximized`,
`t530-maximized`, `w530-dgpu-K1000m-maximized`,
`w530-dgpu-K2000m-maximized`, `w530-maximized`, `x230-legacy`,
`x230-legacy-flash`, `x230-maximized`

Note: T430/T530/W530 are `not set` because their `USE_OPTION_TABLE=y`
flips the default to `n` -- they were never explicitly set.

### CONFIG_RAMINIT_ENABLE_ECC

Only relevant on Sandy/Ivy Bridge boards using native raminit.  Enables
ECC memory initialization.  Most laptop DIMMs are non-ECC, so this is
typically harmless but useless.

Total: **14 `=y`**, **7 `not set`**, **34 absent** (non-native-raminit boards)

`=y` boards:
`optiplex-7019_9010-maximized`, `optiplex-7019_9010_TXT-maximized`,
`p8z77-m_pro-tpm1`, `t420`, `t430-maximized`, `t520-maximized`,
`t530-dgpu-maximized`, `w530-dgpu-K1000m-maximized`,
`w530-dgpu-K2000m-maximized`, `w530-maximized`, `x220`,
`x220-maximized`, `x230-maximized-fhd_edp`, `z220-cmt`

`not set` boards:
`t420-maximized` *(cleaned 2026-07-01)*, `t430-legacy`,
`t430-legacy-flash`, `t530-maximized`, `x230-legacy`,
`x230-legacy-flash`, `x230-maximized`

### CONFIG_PCI_ALLOW_BUS_MASTER

Total: nearly all `=y`.  Only exception was `x230-maximized` which had
`not set` -- listed below as a previously removed undesirable.

## Questionable configs

Options that appeared in the `make BOARD=XYZ
coreboot.save_in_defconfig_format_in_place` output and were found to be
inconsistent across boards.

### Global

```
CONFIG_USE_OPTION_TABLE=y        # see CMOS option backend section above
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

```
CONFIG_USE_LEGACY_8254_TIMER=y
```

## Removed undesirables

The following lines were removed from specific board defconfig
variations.  Filenames (when present) are listed above their removed
fragments.

```
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
