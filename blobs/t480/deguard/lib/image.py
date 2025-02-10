# SPDX-License-Identifier: GPL-2.0-only

from enum import Enum
import struct

def word_le(data, off):
    if off+2>len(data):
        return None
    return struct.unpack("<H", data[off:off+2])[0]

def dword_le(data, off):
    if off+4>len(data):
        return None
    return struct.unpack("<I", data[off:off+4])[0]

def ex(val, bf):
    return val >> bf[0] & bf[1]

class IFDRegion(Enum):
    IFD     = 0
    BIOS    = 1
    ME      = 2
    GBE     = 3
    PD      = 4
    EC      = 8

class IFDImage:
    MAGIC_OFF       = 0x10
    MAGIC           = 0x0FF0A55A

    FLMAP0_OFF      = 0x14
    FLMAP0_FRBA     = (16, 0xff)

    FLREGN_BASE     = (0, 0x7fff)
    FLREGN_LIMIT    = (16, 0x7fff)

    def __init__(self, data):
        self.data = bytearray(data)

        # Verify magic
        if dword_le(self.data, self.MAGIC_OFF) != self.MAGIC:
            raise ValueError("Invalid IFD magic")

        # Find base address of regions
        flmap0 = dword_le(self.data, self.FLMAP0_OFF)
        frba = ex(flmap0, self.FLMAP0_FRBA) << 4

        # Parse regions
        self.regions = {}
        for region in IFDRegion:
            flregN = dword_le(self.data, frba + 4 * region.value)
            base = ex(flregN, self.FLREGN_BASE)
            limit = ex(flregN, self.FLREGN_LIMIT)
            if base == 0x7fff and limit == 0x0000:  # Unused region
                continue
            self.regions[region] = (base << 12, limit << 12 | 0xfff)

    def __str__(self):
        return "\n".join(f"  {region.name:<4}  {extent[0]:08x}-{extent[1]:08x}" \
                         for region, extent in self.regions.items())

    def region_data(self, region):
        if region not in self.regions:
            raise ValueError(f"IFD region {region} not present")
        base, limit = self.regions[region]
        return self.data[base:limit]

class MeImage:
    HEADER_OFF  = 0x10

    MARKER_OFF  = 0x10
    MARKER      = b"$FPT"

    NUMENT_OFF  = 0x14
    HDRLEN_OFF  = 0x20
    HDRSUM_OFF  = 0x21

    ENTRY_OFF   = 0x30
    ENTRY_SIZE  = 0x20

    def __init__(self, data):
        self.data = bytearray(data)

        # Verify magic and checksum
        if self.data[self.MARKER_OFF:self.MARKER_OFF+4] != self.MARKER:
            raise ValueError("Invalid $FPT magic")
        if sum(self.data[self.HEADER_OFF:self.data[self.HDRLEN_OFF]]) != 0:
            raise ValueError("Invalid $FPT checksum")

        # Parse entries
        self.entries = {}
        for idx in range(self.data[self.NUMENT_OFF]):
            off = self.ENTRY_OFF + idx * self.ENTRY_SIZE
            name, _, offset, length, _, _, _, flags = struct.unpack("<4sIIIIIII", \
                self.data[off:off+self.ENTRY_SIZE])
            self.entries[name.strip(b"\0").decode()] = (offset, length, flags)

    def __str__(self):
        return "\n".join(f"  {name:<4}  {entry[0]:08x}-{entry[1]:08x} {entry[2]:08x}" \
                         for name, entry in self.entries.items())

    def entry_data(self, name):
        if name not in self.entries:    # No entry
            raise ValueError(f"Unknown $FPT entry {name}")
        offset, length, flags = self.entries[name]
        if flags & 0xff00_0000 != 0:    # Invalid entry
            raise ValueError(f"Invalid $FPT entry {name}")
        return self.data[offset:offset+length]

    def write_entry_data(self, name, data):
        if name not in self.entries:    # No entry
            raise ValueError(f"Unknown $FPT entry {name}")
        offset, length, flags = self.entries[name]
        if flags & 0xff00_0000 != 0:    # Invalid entry
            raise ValueError(f"Invalid $FPT entry {name}")
        if len(data) != length:
            raise ValueError(f"Wrong data length")
        self.data[offset:offset+length] = data

def parse_ifd_or_me(data):
    try:
        # Try parse as full image
        ifd_image = IFDImage(data)
        return MeImage(ifd_image.region_data(IFDRegion.ME))
    except:
        # Assume it is just an ME
        return MeImage(data)
