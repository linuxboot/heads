# Coreboot Firmware Settings

Heads can optionally show the standard Linux firmware-attributes interface
published by the coreboot CFR driver. The feature is disabled unless a board
sets `CONFIG_HEADS_CFR=y` in its board configuration. Its build-generated
`/etc/heads-cfr-enabled` marker is immutable at runtime, so `config.user`
cannot enable or disable the feature.

The UI reads only:

```text
/sys/class/firmware-attributes/coreboot-cfr/attributes
```

It does not parse the coreboot table, access EFI variables or SMMSTORE, or
invoke an SMI. A board must therefore provide a kernel and firmware stack that
implements this standard interface before enabling the feature.

The board configuration must select kernel and coreboot revisions that provide
the required CFR firmware-attributes ABI. Source selection and board enablement
are intentionally outside this generic UI change.

The settings menu is available under Options only when both the immutable
feature marker and the firmware-attributes class/device exist. Missing,
malformed, disappearing, or unwritable attributes are handled as unavailable
or read-only. Every selected write requires an explicit confirmation showing
the display name, current value, requested value, and pending-reboot status;
cancelling that confirmation does not write.

The Linux driver currently exposes writability through the `current_value` mode
and does not publish a `flags` attribute. The UI works with no `flags` files.
It tolerates an optional flags file for forward compatibility, hiding
`inactive`/`suppressed` entries and treating `readonly` or `volatile` as
non-writable, but that file is not part of the required ABI. Enumeration values
use the standard semicolon delimiter; labels containing spaces are preserved. A literal
semicolon cannot be represented unambiguously by that sysfs ABI and is rejected
rather than guessed.
