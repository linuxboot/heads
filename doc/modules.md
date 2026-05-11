# Heads modules (tools included in the initrd)

Tools available in the Heads initrd are defined by `CONFIG_*` flags in board configs
(`boards/*/*.config`) and compiled by the top-level `Makefile`. Each `bin_modules-$(CONFIG_*) += <name>`
line adds a package to `tools.cpio` (one of six CPIO archives assembled into the initrd).

Not all tools are BusyBox applets — many are standalone binaries compiled as separate packages.

## Module list (from Makefile:718-745)

| Makefile line | Config flag | Package | Type |
|---|---|---|---|
| 718 | `CONFIG_KEXEC` | kexec | Standalone |
| 719 | `CONFIG_TPMTOTP` | tpmtotp | Standalone |
| 720 | `CONFIG_PCIUTILS` | pciutils | Standalone |
| 721 | `CONFIG_FLASHROM` | flashrom | Standalone |
| 722 | `CONFIG_FLASHPROG` | flashprog | Standalone |
| 723 | `CONFIG_CRYPTSETUP` | cryptsetup | Standalone |
| 724 | `CONFIG_CRYPTSETUP2` | cryptsetup2 | Standalone |
| 725 | `CONFIG_GPG` | gpg | Standalone |
| 726 | `CONFIG_GPG2` | gpg2 | Standalone |
| 727 | `CONFIG_PINENTRY` | pinentry | Standalone |
| 728 | `CONFIG_LVM2` | lvm2 | Standalone |
| 729 | `CONFIG_DROPBEAR` | dropbear | Standalone |
| 730 | `CONFIG_FLASHTOOLS` | flashtools | Standalone |
| 731 | `CONFIG_NEWT` | newt | Standalone |
| 732 | `CONFIG_CAIRO` | cairo | Standalone |
| 733 | `CONFIG_FBWHIPTAIL` | fbwhiptail | Standalone |
| 734 | `CONFIG_HOTPKEY` | hotp-verification | Standalone |
| 735 | `CONFIG_MSRTOOLS` | msrtools | Standalone |
| 736 | `CONFIG_NKSTORECLI` | nkstorecli | Standalone |
| 737 | `CONFIG_UTIL_LINUX` | util-linux | Standalone |
| 738 | `CONFIG_OPENSSL` | openssl | Standalone |
| 739 | `CONFIG_TPM2_TOOLS` | tpm2-tools | Standalone |
| 740 | `CONFIG_BASH` | bash | Standalone |
| 741 | `CONFIG_POWERPC_UTILS` | powerpc-utils | Standalone |
| 742 | `CONFIG_IO386` | io386 | Standalone |
| 743 | `CONFIG_IOPORT` | ioport | Standalone |
| 744 | `CONFIG_KBD` | kbd | Standalone |
| 745 | **`CONFIG_ZSTD`** | **zstd** | **Standalone** |
| 746 | `CONFIG_E2FSPROGS` | e2fsprogs | Standalone |

## BusyBox applets (always available)

BusyBox v1.36.1 provides the following applets relevant to Heads scripts.
These are always available regardless of board config.

```text
[, [[, arch, arp, ascii, ash, awk, base32, basename, blkid, blockdev,
bunzip2, bzcat, bzip2, cat, chattr, chmod, chroot, clear, cmp, cp,
cpio, crc32, cttyhack, cut, date, dc, dd, devmem, df, diff, dirname,
dmesg, du, echo, env, expr, factor, fallocate, false, fdisk, find,
fold, fsck, fsfreeze, getopt, grep, groups, gunzip, gzip, hd, head,
hexdump, hexedit, hostid, hwclock, i2cdetect, i2cdump, i2cget, i2cset,
id, ifconfig, insmod, install, ip, kill, killall, killall5, less, link,
ln, loadkmap, losetup, ls, lsattr, lsmod, lsof, lsscsi, lsusb, lzcat,
lzma, md5sum, mkdir, mkdosfs, mkfifo, mkfs.vfat, mknod, mktemp,
modinfo, more, mount, mv, nc, nl, nproc, nslookup, ntpd, partprobe,
paste, patch, pgrep, pidof, ping, pkill, printf, ps, pwd, readlink,
realpath, reboot, reset, resume, rm, rmdir, route, sed, seedrng, seq,
setfattr, setpriv, setserial, setsid, sh, sha1sum, sha256sum, sha3sum,
sha512sum, shred, sleep, sort, ssl_client, stat, strings, stty, sync,
sysctl, tail, tar, tee, test, tftp, time, top, touch, tr, tree, true,
truncate, tsort, tty, udhcpc, umount, uname, uniq, unlzma, unxz, unzip,
usleep, vconfig, vi, wc, wget, which, xargs, xxd, xz, xzcat, zcat
```

## How to check what's available in a build

```bash
# List all BusyBox applets:
busybox --list

# Check if a standalone module is included:
which zstd-decompress kexec-tools gpg 2>/dev/null

# Check board config for CONFIG_ZSTD:
grep CONFIG_ZSTD boards/*/*.config
```
