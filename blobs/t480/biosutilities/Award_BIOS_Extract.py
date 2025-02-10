#!/usr/bin/env python3
#coding=utf-8

"""
Award BIOS Extract
Award BIOS Module Extractor
Copyright (C) 2018-2022 Plato Mavropoulos
"""

TITLE = 'Award BIOS Module Extractor v2.0_a5'

import os
import sys

# Stop __pycache__ generation
sys.dont_write_bytecode = True

from common.comp_szip import szip_decompress
from common.path_ops import make_dirs, safe_name, get_extract_path
from common.patterns import PAT_AWARD_LZH
from common.system import printer
from common.templates import BIOSUtility
from common.text_ops import file_to_bytes

# Check if input is Award BIOS image
def is_award_bios(in_file):
    in_buffer = file_to_bytes(in_file)
    
    return bool(PAT_AWARD_LZH.search(in_buffer))

# Parse & Extract Award BIOS image
def award_bios_extract(input_file, extract_path, padding=0):
    input_buffer = file_to_bytes(input_file)
    
    make_dirs(extract_path, delete=True)
    
    for lzh_match in PAT_AWARD_LZH.finditer(input_buffer):
        lzh_type = lzh_match.group(0).decode('utf-8')
        lzh_text = f'LZH-{lzh_type.strip("-").upper()}'
        
        lzh_bgn = lzh_match.start()
        
        mod_bgn = lzh_bgn - 0x2
        hdr_len = input_buffer[mod_bgn]
        mod_len = int.from_bytes(input_buffer[mod_bgn + 0x7:mod_bgn + 0xB], 'little')
        mod_end = lzh_bgn + hdr_len + mod_len
        mod_bin = input_buffer[mod_bgn:mod_end]
        
        tag_bgn = mod_bgn + 0x16
        tag_end = tag_bgn + input_buffer[mod_bgn + 0x15]
        tag_txt = input_buffer[tag_bgn:tag_end].decode('utf-8','ignore')
        
        printer(f'{lzh_text} > {tag_txt} [0x{mod_bgn:06X}-0x{mod_end:06X}]', padding)
        
        mod_path = os.path.join(extract_path, safe_name(tag_txt))
        lzh_path = f'{mod_path}.lzh'
        
        with open(lzh_path, 'wb') as lzh_file:
            lzh_file.write(mod_bin) # Store LZH archive
        
        # 7-Zip returns critical exit code (i.e. 2) if LZH CRC is wrong, do not check result
        szip_decompress(lzh_path, extract_path, lzh_text, padding + 4, check=False)
        
        # Manually check if 7-Zip extracted LZH due to its CRC check issue
        if os.path.isfile(mod_path):
            os.remove(lzh_path) # Successful extraction, delete LZH archive
            
            # Extract any nested LZH archives
            if is_award_bios(mod_path):
                # Recursively extract nested Award BIOS modules
                award_bios_extract(mod_path, get_extract_path(mod_path), padding + 8)

if __name__ == '__main__':
    BIOSUtility(TITLE, is_award_bios, award_bios_extract).run_utility()
