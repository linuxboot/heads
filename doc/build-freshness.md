# Build Freshness Debugging Guide

## The Problem

Changes to source files in `initrd/` or other build dependencies were not being packed into `initrd.cpio.xz`, causing stale artifacts in the final ROM. The test system showed old commit hashes in `/tmp/config` even after rebuilding.

## initrd.cpio.xz Composition

The final initrd.cpio.xz is built from **6 separate cpio archives** (Makefile line 794-798):

| CPIO | Source | Built by |
|------|--------|----------|
| `dev.cpio` | `blobs/dev.cpio` | Static (pre-built) |
| `modules.cpio` | Linux kernel modules | modules/linux |
| `tools.cpio` | Binaries + libraries + **/etc/config** | Makefile |
| `board.cpio` | Board-specific scripts | Makefile |
| `data.cpio` | Configurable data files | Makefile |
| `heads.cpio` | initrd/* scripts | Makefile |

The final packaging rule:
```makefile
$(build)/$(initrd_dir)/initrd.cpio.xz: $(initrd-y)
```

## Build Flow

### 1. Initrd Build (Makefile)

```
tools.cpio: binaries + libraries + /etc/config (from board .config)
board.cpio: boards/BOARD/initrd/* scripts  
heads.cpio: initrd/* scripts (oem-factory-reset.sh, etc.)
data.cpio: module data files

initrd.cpio.xz = cpio-clean(dev.cpio + modules.cpio + tools.cpio + board.cpio + data.cpio + heads.cpio)
```

**tools.cpio contains /etc/config**:
- Exports all CONFIG_* variables from board config
- GIT_HASH, GIT_STATUS, CONFIG_BOARD

### 2. coreboot Build (modules/coreboot)

```
.build rule: depends on bzImage + initrd.cpio.xz
```

coreboot is configured with `CONFIG_LINUX_INITRD` pointing to initrd.cpio.xz. The initrd is embedded in the Linux kernel payload, not in CBFS.

### 3. Final Output

```
$(BOARD)/$(CB_OUTPUT_FILE) = coreboot-VERSION/board/coreboot.rom (copied and renamed)
$(BOARD)/$(CB_UPDATE_PKG_FILE) = .rom + sha256sum.txt in a zip
```

## Dependency Chain

The build system uses file dependencies + FORCE for consistent output:

| Target | Dependencies |
|--------|--------------|
| `heads.cpio` | `$(HEADS_INITRD_FILES)` (variable with find results) + FORCE |
| `board.cpio` | `$(BOARD_INITRD_FILES)` (variable with find results) + FORCE |
| `tools.cpio` | `$(initrd_bins)`, `$(initrd_libs)`, `etc/config` |
| `etc/config` | `$(CONFIG)` |
| `initrd.cpio.xz` | `$(initrd-y)` (all cpio components) |
| `coreboot .build` | `bzImage`, `initrd.cpio.xz` |

**Key insight**: Using `$(shell find ...)` directly in prerequisites causes Make to evaluate the file list ONCE at parse time. Instead, we use variable assignment:
```makefile
HEADS_INITRD_FILES := $(shell find $(pwd)/initrd -type f 2>/dev/null)
$(build)/$(initrd_dir)/heads.cpio: $(HEADS_INITRD_FILES) FORCE
```

This ensures the file list is re-evaluated each time Make runs, properly tracking source file changes.

**Why FORCE?** Make may skip the recipe if it thinks the target is up-to-date based on file timestamps. FORCE ensures the recipe always runs so our do-cpio macro can use `cmp` to check if content actually changed. This provides:
1. **Consistent output** - always shows "CPIO" or "UNCHANGED"
2. **Efficient rebuilds** - actual filesystem write only happens when content differs

Each target only rebuilds when its dependencies change:
- `cmp` checks if content actually changed before writing output
- Timestamps are preserved when content is identical

## Verifying Freshness

### Check if your changes are in the built initrd:

```bash
# Extract initrd to temp directory
cd /tmp && rm -rf initrd_check && mkdir initrd_check
xz -dc < build/x86/BOARD/initrd.cpio.xz | cpio -idm -D /tmp/initrd_check

# Check your file
grep "your_pattern" /tmp/initrd_check/path/to/file
```

### Check /etc/config (GIT_HASH, CONFIG_*):

```bash
xz -dc < build/x86/BOARD/initrd.cpio.xz | cpio -idm -D /tmp/initrd_check
cat /tmp/initrd_check/etc/config | grep -E "GIT_HASH|CONFIG_BOARD"
```

### List all cpio contents:

```bash
xz -dc < build/x86/BOARD/initrd.cpio.xz | cpio -it | head -30
```

### Compare timestamps:

```bash
# Source file
ls -la initrd/bin/oem-factory-reset.sh

# Built initrd
ls -la build/x86/BOARD/initrd.cpio.xz

# coreboot ROM
ls -la build/x86/BOARD/coreboot.rom
```

If source is newer but initrd.cpio.xz is older, it wasn't rebuilt.

### Check what Makefile thinks is needed:

```bash
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2-hotp -n
```

## Building Fresh

### Using Docker (Required)

The build must run inside Docker to ensure proper permissions and dependencies:

```bash
# Full rebuild
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2-hotp

# Force rebuild of initrd (touch source)
touch initrd/bin/oem-factory-reset.sh
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2-hotp

# Force complete rebuild of board artifacts
rm -rf build/x86/BOARD
./docker_repro.sh make BOARD=qemu-coreboot-fbwhiptail-tpm2-hotp
```

**Never run `make` directly** - it will fail due to permission issues on the build directory (owned by root from docker container).
