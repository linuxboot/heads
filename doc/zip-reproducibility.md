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
for `hashes.txt`/`sizes.txt` a sorted hash-entry diff. A sorted-entry diff that
is empty while the raw files differ means only member-entry order differs; a
non-empty sorted diff means the recorded contents differ.

## ROM inspection with coreboot host tools

`--rom-tools` locates host-built `ifdtool` and `cbfstool` from the local
coreboot build tree (as used by the Makefile, under
`build/<arch>/coreboot-*/util`) and diffs `ifdtool -d` and `cbfstool print`
output for the extracted ROMs. When a ZIP was built locally, these tools are
already present in the corresponding coreboot build directory and are reused.
`--extract` keeps the unpacked ROMs so you can also run them manually:

```sh
ifdtool -d /tmp/zipcmp/a/*.rom
cbfstool /tmp/zipcmp/a/*.rom print
```

## Manual disassembly

```sh
# Archive listing and member metadata
unzip -lv <pkg>.zip

# Extract and checksum members
mkdir /tmp/zip-a && unzip -q <pkg>.zip -d /tmp/zip-a
(cd /tmp/zip-a && sha256sum *)

# Compare member hash entries independent of order
diff <(grep '^[0-9a-f]\{64\}  ' /tmp/zip-a/hashes.txt | sort) \
     <(grep '^[0-9a-f]\{64\}  ' /tmp/zip-b/hashes.txt | sort)
```

## Interpreting results

- **ZIP and members identical**: bit-identical package for the compared
  contents (for a given commit, when packaged contents match).
- **`hashes.txt` differs but sorted hash entries match**: manifest entry order
  differs (member bytes unchanged). A deterministic build sorts `do-cpio`
  member listings in the manifest.
- **ROM/`sha256sum.txt` differ**: packaged image contents differ; use
  `--rom-tools` or `ifdtool`/`cbfstool` on the extracted ROMs to attribute the
  difference to flash regions or CBFS contents.
- **Same commit, different contents**: byte-identical manifests/ZIPs require
  identical packaged contents; compare as a reproducibility test, not a proof
  that a ROM rebuilt identically (see [reproducible-builds.md](reproducible-builds.md)).
