# Heads Configuration Variables

Heads contains a number of configuration variables.

All variables can be set at build time.
(Variables used only at runtime can still be set at build time, this changes the default runtime setting.)
However some variables can _only_ be set at build time, they cannot be changed later.

## User Settings

These variables are explicit user settings managed via the Heads menus.
Setting any of these at build time sets the default setting.

| Variable | Purpose |
|---|---|
| CONFIG_AUTO_BOOT_TIMEOUT | Whether to boot automatically, and how long to wait if so.  Empty disables automatic boo.  A positive integer is the number of seconds to wait before booting automatically. |
| CONFIG_AUTOMATIC_POWERON | Whether to power on automatically after power loss.  Only available if board provides CONFIG_SUPPORT_AUTOMATIC_POWERON. |
| CONFIG_BASIC | 'Basic' mode - no tamper evident boot. |
| CONFIG_BASIC_NO_AUTOMATIC_DEFAULT | In Basic mode: By default, Basic mode detects the default boot option during boot, so it does not need to be updated when the OS boot options change.  Enabling this setting uses a manually-specified boot option instead. |
| CONFIG_BASIC_USB_AUTOBOOT | In Basic mode: Causes Heads to boot to a bootable USB flash drive by default if inserted.  Allows headless systems to perform OS recovery using appropriate bootable images designed for network recovery. |

:point_right: TODO: document these:

```
CONFIG_BOOT_DEV
CONFIG_DEBUG_OUTPUT
CONFIG_ENABLE_FUNCTION_TRACING_OUTPUT
CONFIG_FINALIZE_PLATFORM_LOCKING
CONFIG_RESTRICTED_BOOT
CONFIG_ROOT_CHECK_AT_BOOT
CONFIG_ROOT_DEV
CONFIG_ROOT_DIRLIST
CONFIG_USE_BLOB_JAIL
CONFIG_USER_USB_KEYBOARD
```

## Build configuration

These variables are configure the firmware build.
Many are also available at runtime.
These are not intended to be changed in user config.

| Variable | Purpose |
|---|---|
| CONFIG_BOARD | Internal name of the board being built.  Avoid testing this for specific boards in initrd/, instead add a customization point and override it with boards/<name>/initrd/bin/<file>.  (For example, boards/librem_mini_v2/initrd/bin/board-init.sh.) |
| CONFIG_BOARD_NAME | Display name of the board being built.  Use this to show the board name to the user. |
| CONFIG_BRAND_NAME | Brand name to use to refer to the firmware itself.  Upstream, this is "Heads".  For example, "Heads main menu", "Enable Heads debug tracing", etc.  Distributions can override this to their specific brand name (usually in site-local/config). |

## Feature support

These variables enable features that can be controlled by the user.
Usually, they require some board-specific support.
These are not intended to be changed in user config.

| Variable | Purpose |
|---|---|
| CONFIG_REQUIRE_USB_KEYBOARD | Board must always have USB input support, there is no other input method.  This hides the USB keyboard support setting from the config GUI, and CONFIG_USER_USB_KEYBOARD is ignored. |
| CONFIG_SUPPORT_AUTOMATIC_POWERON | Board supports powering on automatically after power loss.  The board must provide /bin/set_ec_poweron.sh to control this setting.  User can set CONFIG_AUTOMATIC_POWERON from the config GUI. |
| CONFIG_SUPPORT_BLOB_JAIL | Board supports the firmware blob jail to provide nonfree device firmware to the OS kernel.  The board must provide relevant device firmware.  User can set CONFIG_USE_BLOB_JAIL from the config GUI. |

## Module Variables

These variables enable modules or functions of modules, usually adding output from that module to the initrd.
These are not intended to be changed in user config.
(A few might work when overridden to 'n', but this is not intentionally supported.)

| Variable | Purpose |
|---|---|
| CONFIG_BASH | Bash shell.  Most of Heads requires this. |
| CONFIG_BUSYBOX | BusyBox userspace tools.  Alternative is CONFIG_UROOT |
| CONFIG_CAIRO | Cairo libraries, needed by fbwhiptail. |
| CONFIG_COREBOOT | coreboot is the base firmware that loads Heads.  Alternative is CONFIG_LINUXBOOT |
| CONFIG_CRYPTSETUP2 | cryptsetup2 tools (used for LUKS) |
| CONFIG_DROPBEAR | DropBear SSH server (for debug / troubleshooting) |
| CONFIG_FBWHIPTAIL | fbwhiptail, framebuffer-based graphical whiptail implementation.  Alternative is CONFIG_NEWT |

:point_right: TODO: document these:

```
CONFIG_CRYPTSETUP
CONFIG_EXFATPROGS
CONFIG_FLASHPROG
CONFIG_FLASHPROG_AST1100
CONFIG_FLASHROM
CONFIG_FLASHTOOLS
CONFIG_FROTZ
CONFIG_GPG2
CONFIG_HOTPKEY
CONFIG_IO386
CONFIG_IOPORT
CONFIG_KBD
CONFIG_KBD_DEVTOOLS
CONFIG_KBD_EXTRATOOLS
CONFIG_KBD_LOADKEYS
CONFIG_KEXEC
CONFIG_LINUXBOOT
CONFIG_LINUX_AHCI
CONFIG_LINUX_ATA
CONFIG_LINUX_BCM
CONFIG_LINUX_BUNDLED
CONFIG_LINUX_COMMAND_LINE
CONFIG_LINUX_CONFIG
CONFIG_LINUX_E1000
CONFIG_LINUX_E1000E
CONFIG_LINUX_IGB
CONFIG_LINUX_MEGARAID
CONFIG_LINUX_MEI
CONFIG_LINUX_MLX4
CONFIG_LINUX_NVME
CONFIG_LINUX_SCSI_GDTH
CONFIG_LINUX_SFC
CONFIG_LINUX_USB
CONFIG_LINUX_USB_COMPANION_CONTROLLER
CONFIG_LINUX_VERSION
CONFIG_LVM2
CONFIG_MBEDTLS
CONFIG_MSRTOOLS
CONFIG_MUSL
CONFIG_NEWT
CONFIG_NKSTORECLI
CONFIG_OPENSSL
CONFIG_PCIUTILS
CONFIG_POWERPC_UTILS
CONFIG_PURISM_BLOBS
CONFIG_QRENCODE
CONFIG_SLANG
CONFIG_SYSCTL
CONFIG_TPM2_TOOLS
CONFIG_TPM2_TSS
CONFIG_UROOT
CONFIG_UTIL_LINUX
CONFIG_ZLIB
CONFIG_ZSTD
```

## Historical

These variables are no longer used, except possibly in a migration for older settings.
Remember that these could still exist in user configs, so avoid reusing the name for a future variable.

| Variable | Purpose |
|---|---|
| CONFIG_PUREBOOT_BASIC | Migrated to CONFIG_BASIC. |
| CONFIG_SUPPORT_USB_KEYBOARD | All builds now include USB keyboard support. |
| CONFIG_USB_KEYBOARD | This was a build-time setting when USB keyboard support could only be enabled at build time.  When this became a runtime setting, the existing variable name was not reused to avoid confusing older firmware if a user would downgrade.  (CONFIG_USER_USB_KEYBOARD is the user-controlled setting, CONFIG_REQUIRE_USB_KEYBOARD indicates that a board requires USB keyboard all the time.) |

# Updating this document

Use `bin/find_undocumented_config.sh` to find CONFIG_ variables that haven't been documented yet.
It has some exclusions to avoid lots of false matches against subproject configs, etc., see the script implementation.

<!--

A few other spurious non-Heads variables get picked up by bin/find_undocumented_config.sh.

List them here to silence them from output.

CONFIG_PREFIX: from modules/busybox

-->
