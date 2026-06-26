# BusyBox vs GNU: Heads usage reference

Heads initrd scripts run under BusyBox v1.36.1, compiled from `config/busybox.config`.
Not all GNU coreutils features are available. This documents every tool used by
Heads initrd scripts and the adaptations required for BusyBox.

BusyBox applets are always available. Standalone binaries (built by modules/*
and included via `bin_modules-$(CONFIG_FOO)` in the Makefile) are noted separately.

## BusyBox applets (from `busybox --list`)

```
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

**Notably missing:** `od` (CONFIG_OD is not set). Use `hexdump -v -e` instead.

**Shell builtins (available via bash):** `kill`, `printf`, `pwd`, `test`, `echo`, `false`, `true`.
These are listed by `busybox --list` but the bash builtin takes precedence in the initrd.

## Tool-by-tool reference

### awk
BusyBox awk supports `-F SEP` (field separator) and `-v VAR=VAL`.
Sufficient for all Heads usage: `awk '{print $2}' /proc/mounts`, `index()`.

### cpio
**BusyBox quirk**: Stops at first TRAILER. GNU reads past it and exits 2.
Heads pattern: `cpio -i -d "${CPIO_ARGS[@]}" 2>/dev/null || true`.
The `|| true` handles GNU's exit 2 on multi-segment archives.
For multi-segment extraction, the TRAILER offset is pre-computed and
dd limits cpio's input to exactly one segment.

### dd
Supports `if=`, `of=`, `bs=N`, `skip=N`, `count=N`, `status=none`.
Heads usage: `dd bs=1 skip=497 count=1 status=none` (read single byte),
`dd if="$file" bs=6 count=1 status=none` (read magic bytes).
`bs=1` reads one byte per syscall  --  avoid on large ranges (use `tail -c+N` or larger `bs`).

### echo
BusyBox `echo` has no `--help` flag. Prints arguments as-is. Supports `-n` (no newline).

### find
Supports `-name PATTERN`, `-path PATTERN`, `-type f/d`, `-exec ... {} +`.
Heads usage: `find "$dir" -name "*.ko*" -type f`, `find "$dir" -name "*.cfg"`.
`-name` matches only basenames; use `-path` for slash-containing patterns.

### fold
Supports `-s` (break at spaces), `-w WIDTH`. Used with `xxd -p -r` for 60-column padding.

### grep
**BusyBox quirks:**
- No `-b` (byte-offset) flag. Use `dd bs=1 skip=N count=M` for byte-position reads.
- No `-a` flag (text mode is the default, no separate flag).
- `-o` (only-matching), `-q` (quiet), `-F` (fixed string), `-E` (extended regex) all work.
- `-r` recurse, `-v` invert match, `-i` case-insensitive, `-w` word match, `-x` whole line.
- `-m N` stop after N matches.
**Extended regex (`grep -E`):** `|` is alternation. `\|` is literal pipe.
**Basic regex (`grep`):** `\|` is alternation. `|` is literal pipe.
Common mistake: `grep -E "foo\|bar"` searches for literal `foo|bar`, not `foo` OR `bar`.
Correct: `grep -E "foo|bar"` or `grep "foo\|bar"`.
**Fixed strings (`grep -F`):** Treats patterns as literal strings, not regex. Faster than
`grep -E` for simple symbol searches.  Combine with `-o` to extract only the matching text:
`grep -oF -e "vesadrm_probe" -e "vesafb_probe" -e "simpledrm_probe" "$file" | head -1`.
Verified against Heads BusyBox 1.36.1 (`CONFIG_GREP=y` + `CONFIG_FEATURE_GREP_CONTEXT=y`).
Note: `CONFIG_EGREP` and `CONFIG_FGREP` are **not set** in Heads config (no separate
`egrep`/`fgrep` binaries), but `grep -E` and `grep -F` are core features of `grep` itself
and always available.
**Pipefail gotcha:** With `set -e -o pipefail`, a pipeline like `grep ... | head -1` may
abort when `head` terminates early and `grep` receives SIGPIPE.  Always append `|| true`
after the pipeline to suppress the error:
```bash
_result=$(grep ... | head -1) || true
```
**Anchored extraction:** `grep -oE "(^| )key="` matches `key=` only at token boundaries.
Without the `(^| )` anchor, `iso=` in `findiso=` would also match.  `sed 's/^ //'` strips
the leading space from the match.  See `_build_final_cmdline()` in `initrd/etc/functions.sh`.

### gunzip / gzip / zcat
Support `-c` (write to stdout), `-f` (force), `-k` (keep input), `-t` (test).
`gzip -d` decompresses. Used via pipe in initramfs segment extraction.

### hexdump
Supports `-v` (no dup folding), `-C` (canonical hex+ASCII), `-e FMT` (format strings).
Format string example: `-e '16/1 "%02x|""\n"'` for custom output.
**od replacement:** `hexdump -v -e '"%07.7_ad " 16/1 "%02x " "\n"'` produces identical
output to `od -A d -v -t x1` (7-digit zero-padded decimal offset + 16 hex bytes per line).

### head
Supports `-n N` (first N lines), `-c N` (first N bytes), `-q` (no headers), `-v` (always headers).

### mktemp
Supports `-d` (directory), `-t` (tmp dir prefix), `-p DIR` (base directory).
Heads usage: `mktemp -p /tmp -t prefix.XXXXXX`.

### sed

**Basic regex only:** BusyBox `sed` does NOT support `-E` (extended regex).  Use `sed` with
basic regex patterns only.  Grouping with `\(\)` works, but `(^| )` does not.
For anchored replacements, use `[[:space:]]` character classes instead:
```bash
# BAD  --  matches "iso=" inside "findiso=":
sed 's|iso=[^ ]*|newval|g'
# GOOD  --  only matches "iso=" after a space:
sed 's| iso=[^ ]*| newval|g'
```
**Delimiter:** Use `|` instead of `/` when the replacement contains paths: `s|/old/path|/new/path|`.
Supports `-i[SFX]` (in-place), `-n` (quiet), `-r,-E` (extended regex).
Heads usage: `sed 's|^/dev/||'`, `sed 's/^append //'`, `sed -i 's/a/b/g' file`.

### sort
**BusyBox quirk:** `sort -k` keyed sort with `-u` deduplicates based on the
**entire line**, not the sort key. GNU sort deduplicates by key alone.
Heads pattern: use `awk -F'|' '!seen[$1]++'` instead of `sort -t\| -k1 -u`.
Supports `-n` (numeric), `-r` (reverse), `-t CHAR` (field separator), `-z` (NUL).

### stat
Supports `-c FMT` for custom format. Heads usage: `stat -c %s FILE` for file size.

### strings
Supports `-f` (prefix filename), `-o` (octal offset), `-t o|d|x` (offset radix),
`-n LEN` (min string length, default 4). No byte-offset flag.
Heads usage: `strings "$vmlinuz" | grep "vesafb_driver_init"`.

### tail
Supports `-c [+]N[bkm]` for bytes, `-n [+]N[bkm]` for lines.
`tail -c+N` (start at byte N) works identically to GNU for streaming file suffixes.
Heads usage: `tail -c+$((offset + 1)) "$file" | decompressor`.

### tar
Supports `c` (create), `x` (extract), `t` (list), `-z` (gzip), `-J` (xz), `-j` (bzip2).
`-a` auto-detects compression from extension. `-f` for filename, `-C` for chdir.

### tr
Supports `-c` (complement), `-d` (delete), `-s` (squeeze repeats).
Octal escapes (`\NNN`) work via `bb_process_escape_sequence()`.
Heads usage: `tr "$cf1\n$cf2" "\n$cf2=" < "$img"` (extract-ikconfig pattern).

### unxz / xzcat / unlzma / lzcat / lzma
Supports `-c` (stdout), `-f` (force), `-k` (keep). `-d` decompresses.
`xz -d` and `unxz` are equivalent. Used in kernel binary decompression.

**BCJ patches (since Heads ISO boot refactor):** BusyBox's default xz
configuration has ALL BCJ filters disabled in `xz_config.h`
(`/* #define XZ_DEC_X86 */`).  Heads applies two patches to enable
kernel XZ decompression across all supported architectures:

- `patches/busybox-1.36.1/0002-xz_config-enable-bcj.patch`  --  uncomments
  `#define XZ_DEC_X86` and `#define XZ_DEC_POWERPC` to enable the x86
  and PowerPC BCJ (Branch/Call/Jump) filters used by kernel bzImage XZ
  payloads.  Required for x86 boards (x230, t440p, QEMU, etc.) and
  POWER9 boards (Talos II).
- `patches/busybox-1.36.1/0003-xz_decompress-memlimit.patch`  --  raises
  the xz decoder memory limit from 64 MiB to 256 MiB.  Kernel LZMA2
  dictionaries can reach 128 MiB (prop value 0x1e -> dict_size = 2 << 26),
  which exceeds the default 64 MiB limit.

Without these patches, `unxz`/`xzcat` silently rejects kernel XZ streams
with "corrupted data" (actually `XZ_MEMLIMIT_ERROR` caught by the catch-all
handler).  Initramfs XZ decompression is unaffected (no BCJ filter used).

`check_kernel_for_fb()` and `check_kernel_has_driver()` in
`initrd/etc/functions.sh` use the patched BusyBox `xzcat` to decompress
kernel vmlinuz files via `_check_kernel_probe_driver()` when they detect
the `fd377a585a00` XZ stream magic at the kernel payload offset.

**PE (EFI stub) kernel fallback:** `_check_kernel_probe_driver()`
has a two-pass approach for kernel decompression:
1. **bzImage probe**  --  reads `setup_sects` from byte 497, computes the
   payload offset, scans 32 KB for compression magics.
2. **PE fallback**  --  if pass 1 finds nothing (byte 497 is PE header
   data, not `setup_sects` on EFI stub kernels), re-scans from file
   offset 0.  This covers openSUSE Tumbleweed Live, Fedora EFI, and
   other distros shipping PE binaries as kernels.

**zstd decompression (BusyBox applet name resolution):** `_check_kernel_probe_driver()`
also handles zstd-compressed kernels.  BusyBox's `zstd-decompress` applet
resolves via suffix stripping at invocation time but has no PATH symlink
for `command -v`.  A last-resort fallback tries `zstd-decompress -d` even
when `command -v` fails, matching `unpack_initramfs.sh`'s approach.

### wc
Supports `-c` (bytes), `-l` (lines), `-w` (words), `-L` (longest line length).

### xxd
**BusyBox quirk:** `xxd -p` pads the last line to 60 columns with spaces.
GNU xxd does not pad. Heads pattern: `xxd -p | tr -d '\n '` to strip padding.
`xxd -p -r` reverse needs input folded to 60 columns: `fold -w 60 | xxd -p -r`.

## Standalone binaries (not BusyBox applets)

Built by modules/* and included via `bin_modules-$(CONFIG_FOO)` in the Makefile.
Available based on board config. See `doc/modules.md` for inclusion rules.

### zstd-decompress
Built from zstd 1.5.5 source, included in all initrds via `CONFIG_ZSTD ?= y` in `modules/zstd`.
Accepts `-d` (decompress mode  --  required, binary name not recognized by CLI detection).
Reads from stdin (`zstd-decompress -d < input.zst`), writes to stdout.

### bash
Bash 5.1, included in all initrds via `CONFIG_BASH ?= y` in the Makefile.
Used for interactive recovery shell and scripts requiring bash features.

### kbd (setfont, loadkeys)
Built from kbd 2.6.1, included via `CONFIG_KBD ?= y`. Provides keymap loading.

## Summary of required BusyBox workarounds

| GNU feature | BusyBox limitation | Workaround |
|-------------|-------------------|------------|
| `od -A d -v -t x1` | Not compiled in | `hexdump -v -e '"%07.7_ad " 16/1 "%02x " "\n"'` |
| `grep -b` (byte offset) | Not available | `dd bs=1 skip=N count=M` |
| `grep -E "a\|b"` | `\|` is literal in ERE | `grep -E "a|b"` |
| `sort -k N -u` | Dedups by full line | `awk -F'|' '!seen[$1]++'` |
| `xxd -p` (plain hex) | Pads to 60 columns | `xxd -p | tr -d '\n '` |
| `xxd -p -r` (reverse) | Input must be 60-column | `fold -w 60 | xxd -p -r` |
| `cpio` trailing data | GNU exits 2 | `cpio ... 2>/dev/null || true` |
| `zstd -d` (stdin pipe) | Binary not in initrd | `zstd-decompress -d` (standalone binary) |
| `dd bs=1 skip=N` large | 1 syscall per byte | `tail -c+N` for streaming file suffixes |
