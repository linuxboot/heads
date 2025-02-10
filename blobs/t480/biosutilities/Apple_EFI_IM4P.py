#!/usr/bin/env python3
#coding=utf-8

"""
Apple EFI IM4P
Apple EFI IM4P Splitter
Copyright (C) 2018-2022 Plato Mavropoulos
"""

TITLE = 'Apple EFI IM4P Splitter v3.0_a5'

import os
import sys

# Stop __pycache__ generation
sys.dont_write_bytecode = True

from common.path_ops import make_dirs, path_stem
from common.patterns import PAT_APPLE_IM4P, PAT_INTEL_IFD
from common.system import printer
from common.templates import BIOSUtility
from common.text_ops import file_to_bytes

# Check if input is Apple EFI IM4P image
def is_apple_im4p(input_file):
    input_buffer = file_to_bytes(input_file)
    
    is_im4p = PAT_APPLE_IM4P.search(input_buffer)
    
    is_ifd = PAT_INTEL_IFD.search(input_buffer)
    
    return bool(is_im4p and is_ifd)

# Parse & Split Apple EFI IM4P image
def apple_im4p_split(input_file, extract_path, padding=0):    
    exit_codes = []
    
    input_buffer = file_to_bytes(input_file)
    
    make_dirs(extract_path, delete=True)
    
    # Detect IM4P EFI pattern
    im4p_match = PAT_APPLE_IM4P.search(input_buffer)
    
    # After IM4P mefi (0x15), multi EFI payloads have _MEFIBIN (0x100) but is difficult to RE w/o varying samples.
    # However, _MEFIBIN is not required for splitting SPI images due to Intel Flash Descriptor Components Density.
    
    # IM4P mefi payload start offset
    mefi_data_bgn = im4p_match.start() + input_buffer[im4p_match.start() - 0x1]
    
    # IM4P mefi payload size
    mefi_data_len = int.from_bytes(input_buffer[im4p_match.end() + 0x5:im4p_match.end() + 0x9], 'big')
    
    # Check if mefi is followed by _MEFIBIN
    mefibin_exist = input_buffer[mefi_data_bgn:mefi_data_bgn + 0x8] == b'_MEFIBIN'
    
    # Actual multi EFI payloads start after _MEFIBIN
    efi_data_bgn = mefi_data_bgn + 0x100 if mefibin_exist else mefi_data_bgn
    
    # Actual multi EFI payloads size without _MEFIBIN
    efi_data_len = mefi_data_len - 0x100 if mefibin_exist else mefi_data_len
    
    # Adjust input file buffer to actual multi EFI payloads data
    input_buffer = input_buffer[efi_data_bgn:efi_data_bgn + efi_data_len]
    
    # Parse Intel Flash Descriptor pattern matches
    for ifd in PAT_INTEL_IFD.finditer(input_buffer):
        # Component Base Address from FD start (ICH8-ICH10 = 1, IBX = 2, CPT+ = 3)
        ifd_flmap0_fcba = input_buffer[ifd.start() + 0x4] * 0x10
        
        # I/O Controller Hub (ICH)
        if ifd_flmap0_fcba == 0x10:
            # At ICH, Flash Descriptor starts at 0x0
            ifd_bgn_substruct = 0x0
            
            # 0xBC for [0xAC] + 0xFF * 16 sanity check
            ifd_end_substruct = 0xBC
        
        # Platform Controller Hub (PCH)
        else:
            # At PCH, Flash Descriptor starts at 0x10
            ifd_bgn_substruct = 0x10
            
            # 0xBC for [0xAC] + 0xFF * 16 sanity check
            ifd_end_substruct = 0xBC
        
        # Actual Flash Descriptor Start Offset
        ifd_match_start = ifd.start() - ifd_bgn_substruct
        
        # Actual Flash Descriptor End Offset
        ifd_match_end = ifd.end() - ifd_end_substruct
        
        # Calculate Intel Flash Descriptor Flash Component Total Size
        
        # Component Count (00 = 1, 01 = 2)
        ifd_flmap0_nc = ((int.from_bytes(input_buffer[ifd_match_end:ifd_match_end + 0x4], 'little') >> 8) & 3) + 1
        
        # PCH/ICH Strap Length (ME 2-8 & TXE 0-2 & SPS 1-2 <= 0x12, ME 9+ & TXE 3+ & SPS 3+ >= 0x13)
        ifd_flmap1_isl = input_buffer[ifd_match_end + 0x7]
        
        # Component Density Byte (ME 2-8 & TXE 0-2 & SPS 1-2 = 0:5, ME 9+ & TXE 3+ & SPS 3+ = 0:7)
        ifd_comp_den = input_buffer[ifd_match_start + ifd_flmap0_fcba]
        
        # Component 1 Density Bits (ME 2-8 & TXE 0-2 & SPS 1-2 = 3, ME 9+ & TXE 3+ & SPS 3+ = 4)
        ifd_comp_1_bitwise = 0xF if ifd_flmap1_isl >= 0x13 else 0x7
        
        # Component 2 Density Bits (ME 2-8 & TXE 0-2 & SPS 1-2 = 3, ME 9+ & TXE 3+ & SPS 3+ = 4)
        ifd_comp_2_bitwise = 0x4 if ifd_flmap1_isl >= 0x13 else 0x3
        
        # Component 1 Density (FCBA > C0DEN)
        ifd_comp_all_size = IFD_COMP_LEN[ifd_comp_den & ifd_comp_1_bitwise]
        
        # Component 2 Density (FCBA > C1DEN)
        if ifd_flmap0_nc == 2:
            ifd_comp_all_size += IFD_COMP_LEN[ifd_comp_den >> ifd_comp_2_bitwise]
        
        ifd_data_bgn = ifd_match_start
        ifd_data_end = ifd_data_bgn + ifd_comp_all_size
        ifd_data_txt = f'0x{ifd_data_bgn:07X}-0x{ifd_data_end:07X}'
        
        output_data = input_buffer[ifd_data_bgn:ifd_data_end]
        
        output_size = len(output_data)
        
        output_name = path_stem(input_file) if os.path.isfile(input_file) else 'Part'
        
        output_path = os.path.join(extract_path, f'{output_name}_[{ifd_data_txt}].fd')
        
        with open(output_path, 'wb') as output_image:
            output_image.write(output_data)
        
        printer(f'Split Apple EFI image at {ifd_data_txt}!', padding)
        
        if output_size != ifd_comp_all_size:
            printer(f'Error: Bad image size 0x{output_size:07X}, expected 0x{ifd_comp_all_size:07X}!', padding + 4)
            
            exit_codes.append(1)
    
    return sum(exit_codes)

# Intel Flash Descriptor Component Sizes (4MB, 8MB, 16MB and 32MB)
IFD_COMP_LEN = {3: 0x400000, 4: 0x800000, 5: 0x1000000, 6: 0x2000000}

if __name__ == '__main__':
    BIOSUtility(TITLE, is_apple_im4p, apple_im4p_split).run_utility()
