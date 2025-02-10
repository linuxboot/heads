#!/usr/bin/env python3
#coding=utf-8

"""
Apple PBZX Extract
Apple EFI PBZX Extractor
Copyright (C) 2021-2022 Plato Mavropoulos
"""

TITLE = 'Apple EFI PBZX Extractor v1.0_a5'

import os
import sys
import lzma
import ctypes

# Stop __pycache__ generation
sys.dont_write_bytecode = True

from common.comp_szip import is_szip_supported, szip_decompress
from common.path_ops import make_dirs, path_stem
from common.patterns import PAT_APPLE_PBZX
from common.struct_ops import get_struct, uint32_t
from common.system import printer
from common.templates import BIOSUtility
from common.text_ops import file_to_bytes

class PbzxChunk(ctypes.BigEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('Reserved0',       uint32_t),      # 0x00
        ('InitSize',        uint32_t),      # 0x04
        ('Reserved1',       uint32_t),      # 0x08
        ('CompSize',        uint32_t),      # 0x0C
        # 0x10
    ]
    
    def struct_print(self, p):
        printer(['Reserved 0     :', f'0x{self.Reserved0:X}'], p, False)
        printer(['Initial Size   :', f'0x{self.InitSize:X}'], p, False)
        printer(['Reserved 1     :', f'0x{self.Reserved1:X}'], p, False)
        printer(['Compressed Size:', f'0x{self.CompSize:X}'], p, False)

# Check if input is Apple PBZX image
def is_apple_pbzx(input_file):
    input_buffer = file_to_bytes(input_file)
    
    return bool(PAT_APPLE_PBZX.search(input_buffer[:0x4]))

# Parse & Extract Apple PBZX image
def apple_pbzx_extract(input_file, extract_path, padding=0):
    input_buffer = file_to_bytes(input_file)
    
    make_dirs(extract_path, delete=True)
    
    cpio_bin = b'' # Initialize PBZX > CPIO Buffer
    cpio_len = 0x0 # Initialize PBZX > CPIO Length
    
    chunk_off = 0xC # First PBZX Chunk starts at 0xC
    while chunk_off < len(input_buffer):
        chunk_hdr = get_struct(input_buffer, chunk_off, PbzxChunk)
        
        printer(f'PBZX Chunk at 0x{chunk_off:08X}\n', padding)
        
        chunk_hdr.struct_print(padding + 4)
        
        # PBZX Chunk data starts after its Header
        comp_bgn = chunk_off + PBZX_CHUNK_HDR_LEN
        
        # To avoid a potential infinite loop, double-check Compressed Size
        comp_end = comp_bgn + max(chunk_hdr.CompSize, PBZX_CHUNK_HDR_LEN)
        
        comp_bin = input_buffer[comp_bgn:comp_end]
        
        try:
            # Attempt XZ decompression, if applicable to Chunk data
            cpio_bin += lzma.LZMADecompressor().decompress(comp_bin)
            
            printer('Successful LZMA decompression!', padding + 8)
        except Exception:
            # Otherwise, Chunk data is not compressed
            cpio_bin += comp_bin
        
        # Final CPIO size should match the sum of all Chunks > Initial Size
        cpio_len += chunk_hdr.InitSize
        
        # Next Chunk starts at the end of current Chunk's data
        chunk_off = comp_end
    
    # Check that CPIO size is valid based on all Chunks > Initial Size
    if cpio_len != len(cpio_bin):
        printer('Error: Unexpected CPIO archive size!', padding)
        
        return 1
    
    cpio_name = path_stem(input_file) if os.path.isfile(input_file) else 'Payload'
    
    cpio_path = os.path.join(extract_path, f'{cpio_name}.cpio')
    
    with open(cpio_path, 'wb') as cpio_object:
        cpio_object.write(cpio_bin)
    
    # Decompress PBZX > CPIO archive with 7-Zip
    if is_szip_supported(cpio_path, padding, args=['-tCPIO'], check=True):
        if szip_decompress(cpio_path, extract_path, 'CPIO', padding, args=['-tCPIO'], check=True) == 0:
            os.remove(cpio_path) # Successful extraction, delete PBZX > CPIO archive
        else:
            return 3
    else:
        return 2
    
    return 0

# Get common ctypes Structure Sizes
PBZX_CHUNK_HDR_LEN = ctypes.sizeof(PbzxChunk)

if __name__ == '__main__':
    BIOSUtility(TITLE, is_apple_pbzx, apple_pbzx_extract).run_utility()
