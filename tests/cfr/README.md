# CFR settings fixture

`test_cfr_settings.sh` runs the production `cfr-settings.sh` entry point against
a temporary sysfs-shaped tree. Its whiptail stub drives enum and numeric writes,
changes a dependent attribute's writability, presents a read-only attribute,
removes attributes during selection, rejects malformed enum and unsigned
32-bit numeric metadata, and exercises an actual failed write through
`/dev/full`. The
fixture starts with `pending_reboot=1`, so a successful authoritative write also
checks the aggregate pending-reboot report.

This is a host UI/ABI fixture only. It does not test the Linux
firmware-attributes driver, coreboot CFR parsing, EFI variables, SMMSTORE, or
the SMI/APM apply path. Production board policy and runtime apply callbacks
require hardware validation.
