#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Validate that CBFS size fits within IFD BIOS region
# and report space usage statistics

set -e

usage() {
    cat <<EOF
Usage: $0 --coreboot-dir <path> --board-dir <path> --config <path> [--fix]

Validates that CONFIG_CBFS_SIZE from coreboot config matches the BIOS region
size reported by the Intel Flash Descriptor (IFD), and provides space usage
statistics from cbfstool.

Options:
  --coreboot-dir  Path to coreboot build directory
  --board-dir     Path to board build directory  
  --config        Path to coreboot config file
  --fix           Automatically fix CONFIG_CBFS_SIZE to match IFD BIOS region
  --help          Show this help message

Exit codes:
  0: Validation passed (or fix applied successfully, or tools not available yet)
  1: Validation failed - CONFIG_CBFS_SIZE exceeds IFD BIOS region
EOF
    exit "${1:-0}"
}

# Parse arguments
FIX_MODE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --coreboot-dir)
            COREBOOT_DIR="$2"
            shift 2
            ;;
        --board-dir)
            BOARD_DIR="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --fix)
            FIX_MODE=1
            shift
            ;;
        --help)
            usage 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$COREBOOT_DIR" ] || [ -z "$BOARD_DIR" ] || [ -z "$CONFIG_FILE" ]; then
    echo "Error: Missing required arguments" >&2
    usage 1
fi

# Check if tools exist
CBFSTOOL="$COREBOOT_DIR/cbfstool"
IFDTOOL="$COREBOOT_DIR/util/ifdtool/ifdtool"

if [ ! -x "$CBFSTOOL" ]; then
    echo "Warning: cbfstool not found at $CBFSTOOL" >&2
    echo "Skipping CBFS analysis (coreboot not built yet)" >&2
    CBFSTOOL=""
fi

if [ ! -x "$IFDTOOL" ]; then
    echo "Warning: ifdtool not found at $IFDTOOL" >&2
    echo "Skipping IFD validation (coreboot not built yet)" >&2
    IFDTOOL=""
fi

# Extract CONFIG_CBFS_SIZE from config
CBFS_SIZE=$(grep "^CONFIG_CBFS_SIZE=" "$CONFIG_FILE" | cut -d= -f2)
if [ -z "$CBFS_SIZE" ]; then
    echo "Error: CONFIG_CBFS_SIZE not found in $CONFIG_FILE" >&2
    exit 1
fi

# Convert to decimal
CBFS_SIZE_DEC=$((CBFS_SIZE))

# Extract IFD path from config
IFD_PATH=$(grep "^CONFIG_IFD_BIN_PATH=" "$CONFIG_FILE" | cut -d'"' -f2)

# Resolve relative IFD path to absolute, preferring coreboot base dir
if [ -n "$IFD_PATH" ] && [[ "$IFD_PATH" != /* ]] && [[ "$IFD_PATH" != *"@"* ]]; then
    COREBOOT_BASE_DIR="$(dirname "$COREBOOT_DIR")"
    if [ -d "$COREBOOT_BASE_DIR" ]; then
        IFD_PATH="$COREBOOT_BASE_DIR/$IFD_PATH"
    else
        IFD_PATH="$PWD/$IFD_PATH"
    fi
fi

# If IFD path uses @BLOB_DIR@, resolve it
# @BLOB_DIR@ typically expands to blobs/ from the repo root
if [[ "$IFD_PATH" == *"@BLOB_DIR@"* ]]; then
    # Try to find the Heads repo root (go up from coreboot-dir)
    # COREBOOT_DIR is like /home/user/heads/build/x86/coreboot-25.09/BOARD
    # So we need to go up 4 levels: BOARD -> coreboot-25.09 -> x86 -> build -> heads
    if [ -d "$COREBOOT_DIR" ]; then
        REPO_ROOT=$(cd "$COREBOOT_DIR/../../../../" 2>/dev/null && pwd || echo "")
        if [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT/blobs" ]; then
            IFD_PATH="${IFD_PATH/@BLOB_DIR@/$REPO_ROOT/blobs}"
        fi
    fi
fi

# If IFD path uses @BLOB_DIR@, we need to resolve it
# For now, skip validation if no IFD or if path is not resolved
if [ -z "$IFD_PATH" ] || [[ "$IFD_PATH" == *"@"* ]]; then
    # Try to find the IFD in the coreboot build
    BUILD_IFD="$COREBOOT_DIR/flashmap_descriptor.bin"
    if [ ! -f "$BUILD_IFD" ]; then
        echo "Info: No IFD validation possible (CONFIG_IFD_BIN_PATH=$IFD_PATH, build IFD not found)"
        echo "Skipping IFD vs CBFS size validation"
        IFD_VALIDATION_SKIPPED=1
        # Still report CBFS space usage even without IFD
        if [ -n "$CBFSTOOL" ] && [ -f "$COREBOOT_DIR/coreboot.rom" ]; then
            echo ""
            CBFS_OUTPUT=$("$CBFSTOOL" "$COREBOOT_DIR/coreboot.rom" print 2>&1 || true)
            FREE_BYTES=$(echo "$CBFS_OUTPUT" | awk '/\(empty\)/ {sum += $4} END {print sum+0}')
            FREE_KB=$((FREE_BYTES / 1024))
            echo "CBFS configured size: $CBFS_SIZE ($CBFS_SIZE_DEC bytes)"
            echo "CBFS Free Space: $FREE_BYTES bytes ($FREE_KB KiB)"
            echo ""
        fi
    else
        IFD_PATH="$BUILD_IFD"
    fi
fi

# Perform IFD validation if we have a path
if [ -z "$IFD_VALIDATION_SKIPPED" ] && [ -f "$IFD_PATH" ] && [ -n "$IFDTOOL" ]; then
    echo "==================================================================="
    echo "IFD vs CBFS Size Validation"
    echo "==================================================================="
    
    # Try to get platform-specific ifdtool flag
    PLATFORM=""
    # First: check explicit CONFIG_IFD_CHIPSET
    PLATFORM=$(grep '^CONFIG_IFD_CHIPSET=' "$CONFIG_FILE" | cut -d'"' -f2 || true)
    # Second: auto-detect for Haswell/Broadwell (they need ifd2 flag)
    if [ -z "$PLATFORM" ]; then
        if grep -qE 'CONFIG_SOUTHBRIDGE_INTEL_LYNXPOINT|CONFIG_SOUTHBRIDGE_INTEL_WILDCATPOINT' "$CONFIG_FILE"; then
            PLATFORM="ifd2"
            echo "Auto-detected platform: ifd2 (Haswell/Broadwell)"
        fi
    fi
    
    # Run ifdtool to parse the descriptor
    IFD_OUTPUT=""
    if [ -n "$PLATFORM" ]; then
        # Try with platform flag first
        IFD_OUTPUT=$("$IFDTOOL" --platform "$PLATFORM" -d "$IFD_PATH" 2>/dev/null || true)
        if [ -n "$IFD_OUTPUT" ]; then
            echo "Using platform-specific parse: $PLATFORM"
        else
            # Platform flag failed, fall back to generic
            echo "Warning: --platform $PLATFORM failed, using generic parse"
            IFD_OUTPUT=$("$IFDTOOL" -d "$IFD_PATH" 2>/dev/null || true)
        fi
    else
        # No platform needed (e.g., Sandy/Ivy Bridge), use generic parse
        IFD_OUTPUT=$("$IFDTOOL" -d "$IFD_PATH" 2>/dev/null || true)
    fi
    
    
    # Extract BIOS region from IFD output
    BIOS_REGION=$(echo "$IFD_OUTPUT" | grep "Flash Region 1 (BIOS):" | head -1)
    if [ -z "$BIOS_REGION" ]; then
        echo "Error: Could not find BIOS region in IFD" >&2
        exit 1
    fi
    
    # Parse BIOS region addresses (format: "00021000 - 00bfffff")
    BIOS_START=$(echo "$BIOS_REGION" | awk '{print $(NF-2)}')
    BIOS_END=$(echo "$BIOS_REGION" | awk '{print $NF}')
    BIOS_SIZE=$(( 0x$BIOS_END - 0x$BIOS_START + 1 ))
    BIOS_SIZE_KB=$((BIOS_SIZE / 1024))
    CBFS_SIZE_KB=$((CBFS_SIZE_DEC / 1024))
    
    echo "IFD BIOS Region: 0x$BIOS_START - 0x$BIOS_END"
    echo "IFD BIOS Size:   0x$(printf '%X' $BIOS_SIZE) ($BIOS_SIZE_KB KiB)"
    echo "CONFIG_CBFS_SIZE: $CBFS_SIZE ($CBFS_SIZE_KB KiB)"
    echo ""
    
    # CASE 1: CONFIG_CBFS_SIZE is too large
    if [ $CBFS_SIZE_DEC -gt $BIOS_SIZE ]; then
        OVERFLOW=$(( CBFS_SIZE_DEC - BIOS_SIZE ))
        OVERFLOW_KB=$((OVERFLOW / 1024))
        
        if [ $FIX_MODE -eq 1 ]; then
            # Check if current CBFS content will fit after shrinking
            if [ -n "$CBFSTOOL" ] && [ -f "$COREBOOT_DIR/coreboot.rom" ]; then
                CBFS_PRINT=$("$CBFSTOOL" "$COREBOOT_DIR/coreboot.rom" print 2>/dev/null || true)
                FREE_BYTES=$(echo "$CBFS_PRINT" | awk '/\(empty\)/ {sum += $4} END {print sum+0}')
                USED_BYTES=$(( CBFS_SIZE_DEC - FREE_BYTES ))
                USED_KB=$((USED_BYTES / 1024))
                
                if [ $USED_BYTES -gt $BIOS_SIZE ]; then
                    echo "❌ Cannot shrink: Current CBFS content ($USED_KB KiB) won't fit in IFD BIOS region ($BIOS_SIZE_KB KiB)" >&2
                    echo "   Remove payloads/modules before retrying" >&2
                    exit 1
                fi
            fi
            
            # Perform shrink to exact IFD size
            SHRINK_KB=$(( (CBFS_SIZE_DEC - BIOS_SIZE) / 1024 ))
            echo "🔧 Shrinking CONFIG_CBFS_SIZE by $SHRINK_KB KiB"
            sed -i "s/CONFIG_CBFS_SIZE=0x[0-9A-Fa-f]*/CONFIG_CBFS_SIZE=0x$(printf '%X' $BIOS_SIZE)/" "$CONFIG_FILE"
            echo "✓ Updated: CONFIG_CBFS_SIZE=0x$(printf '%X' $BIOS_SIZE)"
            exit 0
        else
            # Report error
            echo "❌ VALIDATION FAILED: CONFIG_CBFS_SIZE exceeds IFD BIOS region by $OVERFLOW_KB KiB"
            echo ""
            echo "Fix: Set CONFIG_CBFS_SIZE=0x$(printf '%X' $BIOS_SIZE) in $CONFIG_FILE"
            if [ -n "$BOARD" ]; then
                echo "Or run: make BOARD=$BOARD fix_cbfs_ifd"
            fi
            exit 1
        fi
    fi
    
    # CASE 2: CONFIG_CBFS_SIZE equals IFD size
    if [ $CBFS_SIZE_DEC -eq $BIOS_SIZE ]; then
        echo "✓ CONFIG_CBFS_SIZE exactly matches IFD BIOS region"
    fi
    
    # CASE 3: CONFIG_CBFS_SIZE is smaller than IFD (normal case)
    if [ $CBFS_SIZE_DEC -lt $BIOS_SIZE ]; then
        FREE_SPACE=$(( BIOS_SIZE - CBFS_SIZE_DEC ))
        FREE_SPACE_KB=$((FREE_SPACE / 1024))
        FREE_BYTES=$(( FREE_SPACE % 1024 ))
        echo "✓ CONFIG_CBFS_SIZE fits within IFD BIOS region"
        
        if [ $FREE_SPACE_KB -eq 0 ] && [ $FREE_SPACE -gt 0 ]; then
            echo "   Unused IFD capacity: $FREE_SPACE bytes (< 1 KiB)"
        else
            echo "   Unused IFD capacity: $FREE_SPACE_KB KiB"
        fi
        
        # Only expand if explicitly requested via fix_cbfs_ifd
        if [ $FIX_MODE -eq 1 ]; then
            # CRITICAL: Intel SPI flash architecture limitation
            # Intel chipsets only memory-map the top 16 MiB of SPI flash to the fixed decode
            # window at 0xFF000000-0xFFFFFFFF (just below 4GB boundary). This is where the CPU
            # must execute XIP (Execute-In-Place) boot stages.
            #
            # cbfstool enforces DEFAULT_DECODE_WINDOW_MAX_SIZE = 16 MiB and will fail with
            # "Assertion `IS_HOST_SPACE_ADDRESS(host_space_address)' failed" when converting
            # XIP stages if CBFS_SIZE > 16 MiB, because the calculated addresses fall outside
            # the memory-mapped region.
            #
            # Exceeding 16 MiB will brick hardware - the CPU cannot fetch boot code from
            # addresses outside the decode window.
            #
            # References:
            # - coreboot util/cbfstool/cbfstool.c: DEFAULT_DECODE_WINDOW_MAX_SIZE
            # - coreboot util/cbfstool/fit.c: "FIT must reside in the top 16MiB"
            # - IS_HOST_SPACE_ADDRESS macro: checks if address is in memory-mapped space
            
            MAX_CBFS_SIZE=0x1000000  # 16 MiB - Intel SPI decode window limit
            
            # Calculate safe expansion target: min(IFD BIOS size, 16 MiB limit)
            if [ $BIOS_SIZE -gt $MAX_CBFS_SIZE ]; then
                TARGET_SIZE=$MAX_CBFS_SIZE
                TARGET_SIZE_KB=$((TARGET_SIZE / 1024))
                BIOS_SIZE_MB=$((BIOS_SIZE / 1024 / 1024))
                echo ""
                echo "⚠️  IFD BIOS region ($BIOS_SIZE_MB MiB) exceeds Intel 16 MiB decode window limit"
                echo "   Capping CONFIG_CBFS_SIZE at 0x$(printf '%X' $MAX_CBFS_SIZE) ($TARGET_SIZE_KB KiB)"
                echo "   Reason: Intel chipsets only memory-map top 16 MiB of SPI flash"
                echo "   Exceeding this limit will brick hardware (CPU cannot execute boot code)"
            else
                TARGET_SIZE=$BIOS_SIZE
            fi
            
            GAIN=$(( TARGET_SIZE - CBFS_SIZE_DEC ))
            GAIN_KB=$((GAIN / 1024))
            
            # Only expand if gain is > 128 KiB
            if [ $GAIN -gt 131072 ]; then
                echo ""
                echo "🔧 Expanding CONFIG_CBFS_SIZE by $GAIN_KB KiB"
                sed -i "s/CONFIG_CBFS_SIZE=0x[0-9A-Fa-f]*/CONFIG_CBFS_SIZE=0x$(printf '%X' $TARGET_SIZE)/" "$CONFIG_FILE"
                echo "✓ Updated: CONFIG_CBFS_SIZE=0x$(printf '%X' $TARGET_SIZE)"
                exit 0
            else
                echo "   Note: Expansion gain too small ($GAIN_KB KiB < 128 KiB threshold), keeping current size"
            fi
        fi
    fi

    # Report CBFS free space
    if [ -n "$CBFSTOOL" ] && [ -f "$COREBOOT_DIR/coreboot.rom" ]; then
        echo ""
        CBFS_OUTPUT=$("$CBFSTOOL" "$COREBOOT_DIR/coreboot.rom" print 2>&1 || true)
        FREE_BYTES=$(echo "$CBFS_OUTPUT" | awk '/\(empty\)/ {sum += $4} END {print sum+0}')
        FREE_KB=$((FREE_BYTES / 1024))
        echo "CBFS Free Space: $FREE_BYTES bytes ($FREE_KB KiB)"
    fi
    
    echo ""
    echo "==================================================================="
    echo "✓ Validation complete"
    echo "==================================================================="
fi

exit 0
