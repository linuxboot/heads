# Update ZIP disassembly and reproducibility checks

This guide covers comparing Heads x86 update packages (`*.zip`) built from the
same commit. An update ZIP contains the ROM, `sha256sum.txt`, and `hashes.txt`
(see [build-artifacts.md](build-artifacts.md)). `hashes.txt` is a build-system
manifest packed into the ZIP; with deterministic packaging the ZIP should be
bit-identical for a given commit when its packaged contents match.

## Comparison tool

`bin/compare-update-zip.sh` disassembles and compares update ZIPs:

```sh
# Disassemble one ZIP (listing, member checksums/modes/mtimes, hashes header)
bin/compare-update-zip.sh --disassemble build/x86/<board>/<pkg>.zip

# Compare two ZIPs from the same commit
bin/compare-update-zip.sh /path/to/build/<pkg>.zip /path/to/reference/<pkg>.zip

# Keep extracted members for external inspection
bin/compare-update-zip.sh --extract /tmp/zipcmp /path/to/build/<pkg>.zip /path/to/reference/<pkg>.zip

# Compare and run host-built ROM tools on the extracted images
bin/compare-update-zip.sh --rom-tools --extract /tmp/zipcmp /path/to/build/<pkg>.zip /path/to/reference/<pkg>.zip
```

The comparison reports ZIP byte identity, per-member checksums and diffs, and
for `hashes.txt`/`sizes.txt` a sorted entry diff. An empty sorted diff while the
raw files differ can mean a header-only change, a member-entry order change, or
another difference outside the compared entries; it does not prove that ordering
alone changed. A non-empty sorted diff means the recorded entries differ.

## ROM inspection with coreboot host tools

`--rom-tools` locates host-built `ifdtool` and `cbfstool` from the local
coreboot build tree (as used by the Makefile, under
`build/<arch>/coreboot-*/util`) and diffs `ifdtool -d` and `cbfstool print`
output for the extracted ROMs. When a ZIP was built locally, these tools are
already present in the corresponding coreboot build directory and are reused.
`--extract` keeps the unpacked ROMs so you can also run them manually:

```sh
# Use the exact paths printed by --rom-tools; a local build does not put these
# tools on PATH. Skip an inspection when its tool is absent rather than
# selecting an arbitrary file from the build tree.
IFDTOOL=build/x86/coreboot-<version>/util/ifdtool/ifdtool
CBFSTOOL=build/x86/coreboot-<version>/<board>/cbfstool
# Use the exact "extracted:" run directory printed for the run you inspect.
RUN=/tmp/zipcmp/zipcmp.XXXXXX
[ -x "$IFDTOOL" ] && "$IFDTOOL" -d "$RUN/a/"*.rom
[ -x "$CBFSTOOL" ] && "$CBFSTOOL" "$RUN/a/"*.rom print
```

## Manual disassembly

The final comparison uses Bash process substitution; run this block in Bash.

```bash
# Let the script list, checksum and extract each archive (it also rejects
# symlink members and handles literal archive names).
bin/compare-update-zip.sh --disassemble --extract /tmp/zipcmp <pkg>.zip
bin/compare-update-zip.sh --disassemble --extract /tmp/zipcmp /path/to/reference/<pkg>.zip

# Use the two "extracted:" run directories printed above for the comparison.
# Stop if either manifest is unreadable; an empty grep result is not a match.
[ -r /path/to/runA/a/hashes.txt ] && [ -r /path/to/runB/a/hashes.txt ] || exit 1
diff <(grep '^[0-9a-f]\{64\}  ' /path/to/runA/a/hashes.txt | sort) \
     <(grep '^[0-9a-f]\{64\}  ' /path/to/runB/a/hashes.txt | sort)
```

## Interpreting results

- **ZIP and members identical**: bit-identical package for the compared
  contents (for a given commit, when packaged contents match).
- **`hashes.txt` differs but sorted entries match**: the difference is outside
  the compared entries — a header-only change, a member-entry order change, or
  other content. A deterministic build sorts `do-cpio` member listings; compare
  the raw files to tell these cases apart.
- **ROM/`sha256sum.txt` differ**: compare the ROM digests or bytes first.
  `sha256sum.txt` also records the ROM filename, so identical ROM bytes under
  different names make that file differ without any flash-region change. Only
  when the ROM bytes actually differ should you use `--rom-tools` or
  `ifdtool`/`cbfstool` to attribute the difference to flash regions or CBFS.
- **Same commit, different contents**: byte-identical manifests/ZIPs require
  identical packaged contents; compare as a reproducibility test, not a proof
  that a ROM rebuilt identically (see [reproducible-builds.md](reproducible-builds.md)).
