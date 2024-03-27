#!/usr/bin/env python

"""ME7 Update binary parser."""

# Copyright (C) 2020 Tom Hiller <thrilleratplay@gmail.com>
# Copyright (C) 2016-2018 Nicola Corna <nicola@corna.info>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#

# Based on the amazing me_cleaner, https://github.com/corna/me_cleaner, parses
# the required signed partition from an ME update file to generate a valid
# flashable ME binary.
#
#  This was written for Heads ROM, https://github.com/osresearch/heads
#  to allow continuous integration reproducible builds for Lenovo xx20 models
#  (X220, T420, T520, etc).
#
#  A full model list can be found:
#   https://download.lenovo.com/ibmdl/pub/pc/pccbbs/mobiles/83rf46ww.txt


from struct import pack, unpack
from typing import List
import argparse
import sys
import hashlib
import binascii
import os.path

#############################################################################

FTPR_END = 0x76000
MINIFIED_FTPR_OFFSET = 0x400  # offset start of Factory Partition (FTPR)
ORIG_FTPR_OFFSET = 0xCC000
PARTITION_HEADER_OFFSET = 0x30  # size of partition header

DEFAULT_OUTPUT_FILE_NAME = "flashregion_2_intel_me.bin"

#############################################################################


class EntryFlags:
    """EntryFlag bitmap values."""

    ExclBlockUse = 8192
    WOPDisable = 4096
    Logical = 2048
    Execute = 1024
    Write = 512
    Read = 256
    DirectAccess = 128
    Type = 64


def generateHeader() -> bytes:
    """Generate Header."""
    ROM_BYPASS_INSTR_0 = binascii.unhexlify("2020800F")
    ROM_BYPASS_INSTR_1 = binascii.unhexlify("40000010")
    ROM_BYPASS_INSTR_2 = pack("<I", 0)
    ROM_BYPASS_INSTR_3 = pack("<I", 0)

    # $FPT Partition table header
    HEADER_TAG = "$FPT".encode()
    HEADER_NUM_PARTITIONS = pack("<I", 1)
    HEADER_VERSION = b"\x20"  # version 2.0
    HEADER_ENTRY_TYPE = b"\x10"
    HEADER_LENGTH = b"\x30"
    HEADER_CHECKSUM = pack("<B", 0)
    HEADER_FLASH_CYCLE_LIFE = pack("<H", 7)
    HEADER_FLASH_CYCLE_LIMIT = pack("<H", 100)
    HEADER_UMA_SIZE = pack("<H", 32)
    HEADER_FLAGS = binascii.unhexlify("000000FCFFFF")
    HEADER_FITMAJOR = pack("<H", 0)
    HEADER_FITMINOR = pack("<H", 0)
    HEADER_FITHOTFIX = pack("<H", 0)
    HEADER_FITBUILD = pack("<H", 0)

    FTPR_header_layout = bytearray(
        ROM_BYPASS_INSTR_0
        + ROM_BYPASS_INSTR_1
        + ROM_BYPASS_INSTR_2
        + ROM_BYPASS_INSTR_3
        + HEADER_TAG
        + HEADER_NUM_PARTITIONS
        + HEADER_VERSION
        + HEADER_ENTRY_TYPE
        + HEADER_LENGTH
        + HEADER_CHECKSUM
        + HEADER_FLASH_CYCLE_LIFE
        + HEADER_FLASH_CYCLE_LIMIT
        + HEADER_UMA_SIZE
        + HEADER_FLAGS
        + HEADER_FITMAJOR
        + HEADER_FITMINOR
        + HEADER_FITHOTFIX
        + HEADER_FITBUILD
    )

    # Update checksum
    FTPR_header_layout[27] = (0x100 - sum(FTPR_header_layout) & 0xFF) & 0xFF

    return FTPR_header_layout


def generateFtpPartition() -> bytes:
    """Partition table entry."""
    ENTRY_NAME = binascii.unhexlify("46545052")
    ENTRY_OWNER = binascii.unhexlify("FFFFFFFF")  # "None"
    ENTRY_OFFSET = binascii.unhexlify("00040000")
    ENTRY_LENGTH = binascii.unhexlify("00600700")
    ENTRY_START_TOKENS = pack("<I", 1)
    ENTRY_MAX_TOKENS = pack("<I", 1)
    ENTRY_SCRATCH_SECTORS = pack("<I", 0)
    ENTRY_FLAGS = pack(
        "<I",
        (
            EntryFlags.ExclBlockUse
            + EntryFlags.Execute
            + EntryFlags.Write
            + EntryFlags.Read
            + EntryFlags.DirectAccess
        ),
    )

    partition = (
        ENTRY_NAME
        + ENTRY_OWNER
        + ENTRY_OFFSET
        + ENTRY_LENGTH
        + ENTRY_START_TOKENS
        + ENTRY_MAX_TOKENS
        + ENTRY_SCRATCH_SECTORS
        + ENTRY_FLAGS
    )

    # offset of the partition - length of partition entry -length of header
    pad_len = MINIFIED_FTPR_OFFSET - (len(partition) + PARTITION_HEADER_OFFSET)
    padding = b""

    for i in range(0, pad_len):
        padding += b"\xFF"

    return partition + padding


############################################################################


class OutOfRegionException(Exception):
    """Out of Region Exception."""

    pass


class clean_ftpr:
    """Clean Factory Parition (FTPR)."""

    UNREMOVABLE_MODULES = ("ROMP", "BUP")
    COMPRESSION_TYPE_NAME = ("uncomp.", "Huffman", "LZMA")

    def __init__(self, ftpr: bytes):
        """Init."""
        self.orig_ftpr = ftpr
        self.ftpr = ftpr
        self.mod_headers: List[bytes] = []
        self.check_and_clean_ftpr()

    #####################################################################
    # tilities
    #####################################################################
    def slice(self, offset: int, size: int) -> bytes:
        """Copy data of a given size from FTPR starting from offset."""
        offset_end = offset + size
        return self.ftpr[offset:offset_end]

    def unpack_next_int(self, offset: int) -> int:
        """Sugar syntax for unpacking a little-endian UINT at offset."""
        return self.unpack_val(self.slice(offset, 4))

    def unpack_val(self, data: bytes) -> int:
        """Sugar syntax for unpacking a little-endian unsigned integer."""
        return unpack("<I", data)[0]

    def bytes_to_ascii(self, data: bytes) -> str:
        """Decode bytes into ASCII."""
        return data.rstrip(b"\x00").decode("ascii")

    def clear_ftpr_data(self, start: int, end: int) -> None:
        """Replace values in range with 0xFF."""
        empty_data = bytes()

        for i in range(0, end - start):
            empty_data += b"\xff"
        self.write_ftpr_data(start, empty_data)

    def write_ftpr_data(self, start: int, data: bytes) -> None:
        """Replace data in FTPR starting at a given offset."""
        end = len(data) + start

        new_partition = self.ftpr[:start]
        new_partition += data

        if end != FTPR_END:
            new_partition += self.ftpr[end:]

        self.ftpr = new_partition

    ######################################################################
    # FTPR cleanig/checking functions
    ######################################################################
    def get_chunks_offsets(self, llut: bytes):
        """Calculate Chunk offsets from LLUT."""
        chunk_count = self.unpack_val(llut[0x04:0x08])
        huffman_stream_end = sum(unpack("<II", llut[0x10:0x18]))
        nonzero_offsets = [huffman_stream_end]
        offsets = []

        for i in range(0, chunk_count):
            llut_start = 0x40 + (i * 4)
            llut_end = 0x44 + (i * 4)

            chunk = llut[llut_start:llut_end]
            offset = 0

            if chunk[3] != 0x80:
                offset = self.unpack_val(chunk[0:3] + b"\x00")

            offsets.append([offset, 0])

            if offset != 0:
                nonzero_offsets.append(offset)

        nonzero_offsets.sort()

        for i in offsets:
            if i[0] != 0:
                i[1] = nonzero_offsets[nonzero_offsets.index(i[0]) + 1]

        return offsets

    def relocate_partition(self) -> int:
        """Relocate partition."""
        new_offset = MINIFIED_FTPR_OFFSET
        name = self.bytes_to_ascii(self.slice(PARTITION_HEADER_OFFSET, 4))

        old_offset, partition_size = unpack(
            "<II", self.slice(PARTITION_HEADER_OFFSET + 0x8, 0x8)
        )

        llut_start = 0
        for mod_header in self.mod_headers:
            if (self.unpack_val(mod_header[0x50:0x54]) >> 4) & 7 == 0x01:
                llut_start = self.unpack_val(mod_header[0x38:0x3C])
                llut_start += old_offset
                break

        if self.mod_headers and llut_start != 0:
            # Bytes 0x9:0xb of the LLUT (bytes 0x1:0x3 of the AddrBase) are
            # added to the SpiBase (bytes 0xc:0x10 of the LLUT) to compute the
            # final start of the LLUT. Since AddrBase is not modifiable, we can
            # act only on SpiBase and here we compute the minimum allowed
            # new_offset.
            llut_start_corr = unpack("<H", self.slice(llut_start + 0x9, 2))[0]
            new_offset = max(
                new_offset, llut_start_corr - llut_start - 0x40 + old_offset
            )
            new_offset = ((new_offset + 0x1F) // 0x20) * 0x20
        offset_diff = new_offset - old_offset

        print(
            "Relocating {} from {:#x} - {:#x} to {:#x} - {:#x}...".format(
                name,
                old_offset,
                old_offset + partition_size,
                new_offset,
                new_offset + partition_size,
            )
        )

        print(" Adjusting FPT entry...")
        self.write_ftpr_data(
            PARTITION_HEADER_OFFSET + 0x08,
            pack("<I", new_offset),
        )

        if self.mod_headers:
            if llut_start != 0:
                if self.slice(llut_start, 4) == b"LLUT":
                    print(" Adjusting LUT start offset...")
                    llut_offset = pack(
                        "<I", llut_start + offset_diff + 0x40 - llut_start_corr
                    )
                    self.write_ftpr_data(llut_start + 0x0C, llut_offset)

                    print(" Adjusting Huffman start offset...")
                    old_huff_offset = self.unpack_next_int(llut_start + 0x14)
                    ftpr_offset_diff = MINIFIED_FTPR_OFFSET - ORIG_FTPR_OFFSET
                    self.write_ftpr_data(
                        llut_start + 0x14,
                        pack("<I", old_huff_offset + ftpr_offset_diff),
                    )

                    print(" Adjusting chunks offsets...")
                    chunk_count = self.unpack_next_int(llut_start + 0x4)
                    offset = llut_start + 0x40
                    offset_end = chunk_count * 4
                    chunks = bytearray(self.slice(offset, offset_end))

                    for i in range(0, offset_end, 4):
                        i_plus_3 = i + 3

                        if chunks[i_plus_3] != 0x80:
                            chunks[i:i_plus_3] = pack(
                                "<I",
                                self.unpack_val(chunks[i:i_plus_3] + b"\x00")
                                + (MINIFIED_FTPR_OFFSET - ORIG_FTPR_OFFSET),
                            )[0:3]
                    self.write_ftpr_data(offset, bytes(chunks))
                else:
                    sys.exit("Huffman modules present but no LLUT found!")
            else:
                print(" No Huffman modules found")

        print(" Moving data...")
        partition_size = min(partition_size, FTPR_END - old_offset)

        if (
            old_offset + partition_size <= FTPR_END
            and new_offset + partition_size <= FTPR_END
        ):
            for i in range(0, partition_size, 4096):
                block_length = min(partition_size - i, 4096)
                block = self.slice(old_offset + i, block_length)
                self.clear_ftpr_data(old_offset + i, len(block))

                self.write_ftpr_data(new_offset + i, block)
        else:
            raise OutOfRegionException()

        return new_offset

    def remove_modules(self) -> int:
        """Remove modules."""
        unremovable_huff_chunks = []
        chunks_offsets = []
        base = 0
        chunk_size = 0
        end_addr = 0

        for mod_header in self.mod_headers:
            name = self.bytes_to_ascii(mod_header[0x04:0x14])
            offset = self.unpack_val(mod_header[0x38:0x3C])
            size = self.unpack_val(mod_header[0x40:0x44])
            flags = self.unpack_val(mod_header[0x50:0x54])
            comp_type = (flags >> 4) & 7
            comp_type_name = self.COMPRESSION_TYPE_NAME[comp_type]

            print(" {:<16} ({:<7}, ".format(name, comp_type_name), end="")

            # If compresion type uncompressed or LZMA
            if comp_type == 0x00 or comp_type == 0x02:
                offset_end = offset + size
                range_msg = "0x{:06x} - 0x{:06x}       ): "
                print(range_msg.format(offset, offset_end), end="")

                if name in self.UNREMOVABLE_MODULES:
                    end_addr = max(end_addr, offset + size)
                    print("NOT removed, essential")
                else:
                    offset_end = min(offset + size, FTPR_END)
                    self.clear_ftpr_data(offset, offset_end)
                    print("removed")

            # Else if compression type huffman
            elif comp_type == 0x01:
                if not chunks_offsets:
                    # Check if Local Look Up Table (LLUT) is present
                    if self.slice(offset, 4) == b"LLUT":
                        llut = self.slice(offset, 0x40)

                        chunk_count = self.unpack_val(llut[0x4:0x8])
                        base = self.unpack_val(llut[0x8:0xC]) + 0x10000000
                        chunk_size = self.unpack_val(llut[0x30:0x34])

                        llut = self.slice(offset, (chunk_count * 4) + 0x40)

                        # calculate offsets of chunks from LLUT
                        chunks_offsets = self.get_chunks_offsets(llut)
                    else:
                        no_llut_msg = "Huffman modules found,"
                        no_llut_msg += "but LLUT is not present."
                        sys.exit(no_llut_msg)

                module_base = self.unpack_val(mod_header[0x34:0x38])
                module_size = self.unpack_val(mod_header[0x3C:0x40])
                first_chunk_num = (module_base - base) // chunk_size
                last_chunk_num = first_chunk_num + module_size // chunk_size
                huff_size = 0

                chunk_length = last_chunk_num + 1
                for chunk in chunks_offsets[first_chunk_num:chunk_length]:
                    huff_size += chunk[1] - chunk[0]

                size_in_kiB = "~" + str(int(round(huff_size / 1024))) + " KiB"
                print(
                    "fragmented data, {:<9}): ".format(size_in_kiB),
                    end="",
                )

                # Check if module is in the unremovable list
                if name in self.UNREMOVABLE_MODULES:
                    print("NOT removed, essential")

                    # add to list of unremovable chunks
                    for x in chunks_offsets[first_chunk_num:chunk_length]:
                        if x[0] != 0:
                            unremovable_huff_chunks.append(x)
                else:
                    print("removed")

            # Else unknown compression type
            else:
                unkwn_comp_msg = " 0x{:06x} - 0x{:06x}): "
                unkwn_comp_msg += "unknown compression, skipping"
                print(unkwn_comp_msg.format(offset, offset + size), end="")

        if chunks_offsets:
            removable_huff_chunks = []

            for chunk in chunks_offsets:
                # if chunk is not in a unremovable chunk, it must be removable
                if all(
                    not (
                        unremovable_chk[0] <= chunk[0] < unremovable_chk[1]
                        or unremovable_chk[0] < chunk[1] <= unremovable_chk[1]
                    )
                    for unremovable_chk in unremovable_huff_chunks
                ):
                    removable_huff_chunks.append(chunk)

            for removable_chunk in removable_huff_chunks:
                if removable_chunk[1] > removable_chunk[0]:
                    chunk_start = removable_chunk[0] - ORIG_FTPR_OFFSET
                    chunk_end = removable_chunk[1] - ORIG_FTPR_OFFSET
                    self.clear_ftpr_data(chunk_start, chunk_end)

            end_addr = max(
                end_addr, max(unremovable_huff_chunks, key=lambda x: x[1])[1]
            )
            end_addr -= ORIG_FTPR_OFFSET

        return end_addr

    def find_mod_header_size(self) -> None:
        """Find module header size."""
        self.mod_header_size = 0
        data = self.slice(0x290, 0x84)

        # check header size
        if data[0x0:0x4] == b"$MME":
            if data[0x60:0x64] == b"$MME" or self.num_modules == 1:
                self.mod_header_size = 0x60
            elif data[0x80:0x84] == b"$MME":
                self.mod_header_size = 0x80

    def find_mod_headers(self) -> None:
        """Find module headers."""
        data = self.slice(0x290, self.mod_header_size * self.num_modules)

        for i in range(0, self.num_modules):
            header_start = i * self.mod_header_size
            header_end = (i + 1) * self.mod_header_size
            self.mod_headers.append(data[header_start:header_end])

    def resize_partition(self, end_addr: int) -> None:
        """Resize partition."""
        spared_blocks = 4
        if end_addr > 0:
            end_addr = (end_addr // 0x1000 + 1) * 0x1000
            end_addr += spared_blocks * 0x1000

            # partition header not added yet
            # remove  trailing data the same size as the header.
            end_addr -= MINIFIED_FTPR_OFFSET

            me_size_msg = "The ME minimum size should be {0} "
            me_size_msg += "bytes ({0:#x} bytes)"
            print(me_size_msg.format(end_addr))
            print("Truncating file at {:#x}...".format(end_addr))
            self.ftpr = self.ftpr[:end_addr]

    def check_and_clean_ftpr(self) -> None:
        """Check and clean FTPR (factory partition)."""
        self.num_modules = self.unpack_next_int(0x20)
        self.find_mod_header_size()

        if self.mod_header_size != 0:
            self.find_mod_headers()

            # ensure all of the headers begin with b'$MME'
            if all(hdr.startswith(b"$MME") for hdr in self.mod_headers):
                end_addr = self.remove_modules()
                new_offset = self.relocate_partition()
                end_addr += new_offset

                self.resize_partition(end_addr)

                # flip bit
                # XXX: I have no idea why this works and passes RSA signiture
                self.write_ftpr_data(0x39, b"\x00")
            else:
                sys.exit(
                    "Found less modules than expected in the FTPR "
                    "partition; skipping modules removal and exiting."
                )
        else:
            sys.exit(
                "Can't find the module header size; skipping modules"
                "removal and exiting."
            )


##########################################################################


def check_partition_signature(f, offset) -> bool:
    """check_partition_signature copied/shamelessly stolen from me_cleaner."""
    f.seek(offset)
    header = f.read(0x80)
    modulus = int(binascii.hexlify(f.read(0x100)[::-1]), 16)
    public_exponent = unpack("<I", f.read(4))[0]
    signature = int(binascii.hexlify(f.read(0x100)[::-1]), 16)

    header_len = unpack("<I", header[0x4:0x8])[0] * 4
    manifest_len = unpack("<I", header[0x18:0x1C])[0] * 4
    f.seek(offset + header_len)

    sha256 = hashlib.sha256()
    sha256.update(header)
    tmp = f.read(manifest_len - header_len)
    sha256.update(tmp)

    decrypted_sig = pow(signature, public_exponent, modulus)
    return "{:#x}".format(decrypted_sig).endswith(sha256.hexdigest())  # FIXME


##########################################################################


def generate_me_blob(input_file: str, output_file: str) -> None:
    """Generate ME blob."""
    print("Starting ME 7.x Update parser.")

    orig_f = open(input_file, "rb")
    cleaned_ftpr = clean_ftpr(orig_f.read(FTPR_END))
    orig_f.close()

    fo = open(output_file, "wb")
    fo.write(generateHeader())
    fo.write(generateFtpPartition())
    fo.write(cleaned_ftpr.ftpr)
    fo.close()


def verify_output(output_file: str) -> None:
    """Verify Generated ME file."""
    file_verifiy = open(output_file, "rb")

    if check_partition_signature(file_verifiy, MINIFIED_FTPR_OFFSET):
        print(output_file + " is VALID")
        file_verifiy.close()
    else:
        print(output_file + " is INVALID!!")
        file_verifiy.close()
        sys.exit("The FTPR partition signature is not valid.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Tool to remove as much code "
        "as possible from Intel ME/TXE 7.x firmware "
        "update and create paratition for a flashable ME parition."
    )


parser.add_argument("file", help="ME/TXE image or full dump")
parser.add_argument(
    "-O",
    "--output",
    metavar="output_file",
    help="save "
    "save file name other than the default '" + DEFAULT_OUTPUT_FILE_NAME + "'",
)

args = parser.parse_args()

output_file_name = DEFAULT_OUTPUT_FILE_NAME if not args.output else args.output

# Check if output file exists, ask to overwrite or exit
if os.path.isfile(output_file_name):
    input_msg = output_file_name
    input_msg += " exists.  Do you want to overwrite? [y/N]: "
    if not str(input(input_msg)).lower().startswith("y"):
        sys.exit("Not overwriting file.  Exiting.")

generate_me_blob(args.file, output_file_name)
verify_output(output_file_name)
