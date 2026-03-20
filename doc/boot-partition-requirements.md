# Boot Partition Requirements

Heads has one hard, non-negotiable requirement about disk layout:
**`/boot` must be a separate, unencrypted partition.**

This is not a preference or a recommendation. It is the foundation of how
Heads works. If this requirement is not met, Heads' entire integrity model
is broken — and prior to this change, it would fail silently with confusing
"first boot setup" dialogs rather than a clear error.

## Why

Heads runs from ROM (SPI flash), not from disk. When the machine powers on,
the ROM payload (Heads) runs before any disk is decrypted or mounted. Heads'
job is to:

1. Mount `/boot` from the disk
2. Check the GPG-signed hashes of every file in `/boot`
3. Verify TPM PCR measurements match what was sealed at last-known-good state
4. Only then `kexec` into the OS kernel

If `/boot` is part of an encrypted root (`/`), step 1 is impossible without
first decrypting the disk — but Heads has no key to do that until *after*
the integrity check. The circular dependency makes the security model
collapse entirely.

If `/boot` is a subdirectory of an unencrypted `/` (merged layout, no
separate partition), Heads has no way to identify the correct block device
to measure, and the `CONFIG_BOOT_DEV` variable — which the entire boot
integrity system depends on — is meaningless.

## Requirements

| Property | Required value | Why |
|---|---|---|
| Separate partition | Yes | Heads identifies `/boot` by block device (`CONFIG_BOOT_DEV`), not by path |
| Unencrypted | Yes | Heads reads `/boot` before any LUKS container is opened |
| Filesystem | ext2, ext3, or ext4 | These are what the Heads initrd mounts |
| Size | ≥ 512 MB recommended | Kernels, initrds, and Xen images can be large |

## Correct partition layout

```
/dev/sda1   512MB   ext4    (unencrypted)   → mounted as /boot by Heads
/dev/sda2   rest    LUKS    (encrypted)     → root filesystem, swap, etc.
```

Inside the LUKS container, you can use LVM or btrfs subvolumes freely.
The only constraint is that `/boot` itself is outside the encrypted layer.

## Incorrect layouts (will now error at boot)

### Merged /boot (no separate partition)

```
/dev/sda1   LUKS → / (with /boot as a subdirectory)
```

Heads cannot mount this. `CONFIG_BOOT_DEV` has no valid value.

### Encrypted /boot

```
/dev/sda1   512MB  LUKS → /boot   ← THIS DOES NOT WORK
/dev/sda2   rest   LUKS → /
```

Heads cannot read an encrypted `/boot` before the integrity check.

### Full-disk encryption with no /boot partition

Many installers (notably Debian 11+ default) do this. You **must** select
manual partitioning during OS install and create a separate unencrypted
`/boot` partition.

## OS-specific notes

### Debian / Ubuntu

The default installer in recent versions creates a single encrypted
partition. You must use **manual partitioning**:

- Create a 512MB primary partition, format as ext4, mount at `/boot`,
  do **not** encrypt it
- Create a second partition, encrypt with LUKS, use for `/` (and optionally
  LVM inside for swap/home)

### Fedora / RHEL

The default partitioning scheme creates a separate unencrypted `/boot`.
Heads works with the defaults. Use ext4 for `/boot` rather than btrfs
(the Heads recovery shell does not support btrfs).

### Qubes OS

The default Qubes partitioner creates a separate unencrypted `/boot`.
This is compatible with Heads without modification.

### NixOS / Guix

These systems do not always default to a separate `/boot`. You must
explicitly declare a separate `/boot` partition in your configuration.

For NixOS, in `configuration.nix`:

```nix
fileSystems."/boot" = {
  device = "/dev/sda1";
  fsType = "ext4";
};
```

For Guix, in `config.scm`:

```scheme
(file-system
  (device "/dev/sda1")
  (mount-point "/boot")
  (type "ext4"))
```

## Setting CONFIG_BOOT_DEV

Once the OS is installed with the correct layout, Heads needs to know which
partition is `/boot`. This is stored in the Heads config:

```sh
# From the Heads recovery shell:
echo "export CONFIG_BOOT_DEV='/dev/sda1'" > /etc/config.user
```

Alternatively, use the GUI: **Options → Change Configuration Settings →
Change the Boot Device**.

This setting is saved into the ROM on the next firmware write, so it
persists across reboots without needing to set it again.

## What happens if the requirement is not met

Starting with the commit that introduced `check-boot-partition`, Heads will
**refuse to boot** with a clear error message if:

- `CONFIG_BOOT_DEV` is not set
- `CONFIG_BOOT_DEV` does not exist as a block device
- `CONFIG_BOOT_DEV` is a LUKS-encrypted partition
- `CONFIG_BOOT_DEV` is the same device as `/` (merged layout)

Previously, these conditions produced confusing "first boot setup" dialogs
that gave no indication the disk layout was fundamentally incompatible.

## Recovery

If you are stuck in the recovery shell because of a boot partition error:

1. Check what partitions exist: `lsblk` or `fdisk -l`
2. Try mounting candidate partitions: `mount /dev/sda1 /boot && ls /boot`
3. If `/boot` contents are there (vmlinuz, initrd, grub.cfg), set the
   variable: `echo "export CONFIG_BOOT_DEV='/dev/sda1'" > /etc/config.user`
4. If there is no separate `/boot` partition, you will need to reinstall
   the OS with the correct layout. There is no workaround.
