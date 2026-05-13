# BusyBox vs GNU: Heads usage reference

Heads initrd scripts run under BusyBox v1.36.1, not GNU coreutils.
This documents every command usage across Heads scripts and the BusyBox
adaptations required.

## dd

BusyBox `dd` supports `status=`, `iflag=`, `oflag=` the same as GNU.

**Usage in Heads**:
```bash
dd if="$file" bs=6 count=1 status=none   # kexec-iso-init.sh:
dd bs=1 count=1 status=none              # unpack_initramfs.sh:38
dd bs="$segment_end" count=1 status=none # unpack_initramfs.sh:101
```

## xxd

**BusyBox quirk**: `xxd -p` pads the last line to 60 columns with spaces.
GNU xxd does not pad.

**Usage in Heads**:
```bash
# Good: strips padding:
next_byte="$(dd bs=1 count=1 status=none | xxd -p | tr -d '\n ')"  # unpack_initramfs.sh:38
magic="$(dd if="$f" bs=6 count=1 status=none | xxd -p | tr -d '\n ')" # unpack_initramfs.sh:68

# Reverse: needs fold workaround (from etc/functions.sh:2701):
fold -w 60 | xxd -p -r
```

## cpio

**BusyBox quirk**: Stops at first TRAILER. GNU reads past it and exits 2.

**Heads pattern**: `cpio -i -d "${CPIO_ARGS[@]}" 2>/dev/null || true`
The `|| true` handles GNU's exit 2 on multi-segment archives.

For multi-segment extraction (`unpack_initramfs.sh:94-106`), the TRAILER offset
is pre-computed and dd limits cpio's input to exactly one segment, so both
BusyBox and GNU behave identically.

## grep

**BusyBox quirks**:
- No `-b` (byte-offset) flag.  GNU grep's `-b` reports byte offset
  of each match.  BusyBox lacks this.  If you need byte positions
  in binary streams, use `dd bs=1 skip=N count=M` instead.
- `-a` (text mode) is default — no-op on both BusyBox and GNU.
- `-o` (only-matching), `-n` (line number), `-H`/`-h` (filename
  prefix) all work as expected.
- Extended regex (`grep -E`): `|` is alternation.  `\|` is a literal
  pipe character.
- Basic regex (`grep`, no -E): `\|` is alternation.  `|` is a literal
  pipe character.
- **Common mistake**: `grep -E "i915\|nouveau"` searches for the
  literal string `i915|nouveau`, NOT for `i915` OR `nouveau`.
  Correct: `grep -E "i915|nouveau"` or `grep "i915\|nouveau"`.

**Heads pattern**:
```bash
# BRE (basic regex) for alternation:
grep "i915\|nouveau\|amdgpu\|radeon\|bochs" "$initrd"
# ERE (extended regex) for alternation — note plain |, not \|:
grep -E "i915|nouveau|amdgpu|radeon|bochs" "$initrd"
```

## stat

Identical for `stat -c %s FILE`.

**Usage in Heads**:
```bash
orig_size="$(stat -c %s "$unpack_archive")"        # unpack_initramfs.sh:127
rest_size="$(stat -c %s "$rest_archive")"            # unpack_initramfs.sh:128
rest_size="$(stat -c %s "$next_archive" 2>/dev/null || echo 0)" # unpack_initramfs.sh:147
```

## find

**Usage in Heads** (all supported by BusyBox):
```bash
find "$dir" -name "*.ko*" -type f 2>/dev/null | head -1  # kexec-iso-init.sh
find "$dir" -name '*.cfg' -type f 2>/dev/null            # kexec-iso-init.sh
find "$dir" -name "*.ko*" 2>/dev/null | grep -q "ext4"    # kexec-iso-init.sh
```

## gunzip / gzip / zcat

Identical. Used via pipe in segment decompression:
```bash
gunzip | unpack_cpio   # unpack_initramfs.sh:111
```

## unxz / xzcat

Identical:
```bash
unxz | unpack_cpio    # unpack_initramfs.sh:115
```

## zstd / zstd-decompress

**Standalone binary** compiled at `build/x86/zstd-1.5.5/programs/zstd-decompress`
and included in the initrd via `Makefile:745` (`CONFIG_ZSTD`). Not a BusyBox
applet, but available in all boards with `CONFIG_ZSTD=y`.

Usage via pipe (`unpack_initramfs.sh:119`):
```bash
zstd-decompress -d < input.zst   # reads stdin, writes stdout
```

**Current code**: `(zstd-decompress -d 2>/dev/null || zstd -d 2>/dev/null || true) | unpack_cpio`
--  should work if `CONFIG_ZSTD=y` in the board config.

## sed

Identical for all patterns used in Heads:
```bash
sed 's|^/dev/||'          # kexec-iso-init.sh (path stripping)
sed 's/^append //'         # kexec-iso-init.sh (param extraction)
sed 's/^initrd //'         # kexec-iso-init.sh (field extraction)
sed "s|\${$var}|$val|g"    # kexec-iso-init.sh (GRUB var resolution)
```

## awk

BusyBox awk is minimal but sufficient for Heads usage:
```bash
awk -v dev="$dev" 'index($1, dev) == 1 { print $3; exit }' /proc/mounts
awk '{print $2}' /proc/mounts
```

## strings

BusyBox `strings` scans binary files character by character for printable
sequences.  Supports `-f` (prefix filename), `-o` (octal offset),
`-t o|d|x` (offset radix), `-n LEN` (min string length, default 4).
`-a` (scan whole file) is the default.  No byte-offset flag.

```bash
strings "$vmlinuz" | grep -i "efifb\|simpledrm"   # kernel binary scan
```

## tail

BusyBox `tail -c +N` (start at byte N) works identically to GNU.  Used
for byte-offset extraction from kernel images.

```bash
tail -c+$((pos+8)) "$img" | zcat                  # offset + decompress
```

## tr

BusyBox `tr` handles octal escape sequences (`\NNN`) via
`bb_process_escape_sequence()`.  Named escapes (`\n`, `\t`, etc.) work
as expected.  Octal sequences from shell variables (e.g.
`cf1='\037\213\010'`) are interpreted by `tr`, not by the shell.

```bash
cf1='IKCFG_ST\037\213\010'; cf2='0123456789'
tr "$cf1\n$cf2" "\n$cf2=" < "$img"               # extract-ikconfig
```

## cut / head / uniq / fold / basename / dirname / readlink

All identical for Heads usage. No special BusyBox workarounds needed.

## sort

**BusyBox quirk**: `sort -k` keyed sort with `-u` deduplicates based on the
**entire line**, not the sort key.  GNU sort deduplicates by the key alone.

**Heads pattern**: Use `awk -F'|' '!seen[$1]++'` instead of `sort -t\| -k1 -u`
when deduplicating by a single field:
```bash
# Wrong under BusyBox (dedups by full line, not field 1):
sort -t\| -k1 -u

# Correct under both:
awk -F'|' '!seen[$1]++'
```

## cat / mv / rm / mkdir / mktemp / printf / wc / xargs / echo

All identical. No BusyBox workarounds needed.

## Summary of required BusyBox workarounds

| Command | Workaround | Where |
|---------|------------|-------|
| `xxd -p` | `tr -d '\n '` strips 60-col padding | `unpack_initramfs.sh` (multi-segment cpio) |
| `xxd -p -r` | `fold -w 60 \| xxd -p -r` | `etc/functions.sh` (tohex_plain) |
| `cpio` trailing data exit | `|| true` swallows GNU exit 2 | `unpack_initramfs.sh` (multi-segment cpio) |
| `grep -b` | Not available — use `dd bs=1 skip=N count=M` | kernel binary analysis |
| `grep -E` alternation | Use `|` not `\|` in ERE; use `\|` in BRE | initrd module detection |
| `sort -u` with `-k` | Dedups by full line, not key — use awk | `scan_options()` in kexec-select-boot.sh |
| `zstd` not in busybox | `/bin/zstd-decompress -d` standalone binary | `unpack_initramfs.sh` (initrd decompression) |
