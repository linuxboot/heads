# TCG Opal disk unlock

Heads can unlock TCG Opal disks before boot-device discovery. Enable the boot
gate with:

```make
export CONFIG_HEADS_OPAL=y
```

The board's Linux configuration must enable `CONFIG_BLK_SED_OPAL`. The
`heads-opal` helper uses the kernel's `IOC_OPAL_GET_STATUS` and
`IOC_OPAL_LOCK_UNLOCK` interfaces. It unlocks the global locking range as
`Admin1`; the password is read from standard input and is not passed through
the command line or environment.

Star Labs coreboot builds that provide the OPAL S3 APMC service can also use:

```make
export CONFIG_HEADS_OPAL_S3_HANDOFF=y
```

This makes failure to install the password in coreboot SMM fatal. The Linux
configuration must additionally enable `CONFIG_PROC_PAGE_MONITOR`, and the
coreboot SMM ABI currently limits passwords to 32 bytes. The S3 handoff path
currently supports NVMe devices only; ordinary cold-boot unlock uses the
kernel OPAL interface for any supported block device.

## QEMU fixture

`qemu-coreboot-fbwhiptail-tpm2-opal` replaces only the disk backend and
password prompt. It exercises Heads' scan, hidden-secret transport, unlock
gate, post-unlock status check, S3-handoff request, and subsequent boot flow.
Upstream QEMU does not emulate a TCG Opal device, so the fixture does not test
NVMe Security Send/Receive or the physical SMM handler. Those two operations
require final validation on a Star Labs system with an Opal SSD.
