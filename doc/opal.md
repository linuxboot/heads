# TCG Opal disk unlock

Heads can unlock TCG Opal disks before any normal, basic, or network boot
script starts. Enable the boot gate with:

```make
export CONFIG_HEADS_OPAL=y
```

The board must use Linux 6.1 or later and its Linux configuration must enable
`CONFIG_BLK_SED_OPAL=y`. The build rejects a production configuration that
enables the gate without this kernel support. The `heads-opal` helper uses the
kernel's `IOC_OPAL_GET_STATUS` and `IOC_OPAL_LOCK_UNLOCK` interfaces. It
unlocks the global locking range as `Admin1`.

The gate is keyed to the helper installed in the immutable initrd, not the
mutable runtime user configuration. Production always uses `/bin/heads-opal`
and the built-in password dialog. A board may replace those fixed paths in its
initrd overlay for a fixture, but user configuration cannot select another
backend or disable the gate.

The prompt completes before the unlock begins. Heads opens and unlinks its
mode-0600 password file before passing the anonymous file descriptor to the C
helper, so the password is not placed in command arguments, the environment,
or a production Bash variable. The helper locks and clears its credential
buffers. If a later disk or S3 handoff fails, Heads uses the retained anonymous
descriptors to relock earlier disks before recovery. A rollback failure powers
the machine off instead of exposing an unlocked disk to a recovery shell.

coreboot provides the optional OPAL S3 APMC service through
[change 91045](https://review.coreboot.org/c/coreboot/+/91045). Boards built
with that service can explicitly select its version 1 ABI with:

```make
export CONFIG_HEADS_OPAL_S3_APMC_V1=y
```

Only enable this option when the running coreboot contains that ABI: APMC port
`0xb2`, command `0xee`, context signature `OPS3`, and context version 1. The
option makes failure to install or clear the password in coreboot SMM fatal.
The Linux configuration must additionally enable `CONFIG_PROC_PAGE_MONITOR=y`,
and the ABI limits passwords to 32 bytes. This selection is compiled into the
helper and cannot be disabled through runtime user configuration. The S3
handoff path currently supports NVMe devices only; ordinary cold-boot unlock
uses the kernel OPAL interface for any supported block device.

## QEMU fixture

`qemu-coreboot-fbwhiptail-tpm2-opal` overlays the fixed helper and prompt paths
with deterministic fixtures. Its explicit `CONFIG_HEADS_OPAL_TEST_FIXTURE=y`
setting is the only exception to the production kernel-configuration check. It
exercises Heads'
scan parsing, secret transport, unlock and rollback gates, post-unlock status
check, S3-handoff request, and transition to the boot script.

Upstream QEMU does not emulate a TCG Opal device or this SMM service. The
fixture therefore does not exercise the production OPAL ioctls, NVMe Security
Receive, physical-address lookup, or SMI handler. Those operations and S3
resume require hardware validation on a system with an Opal SSD.
