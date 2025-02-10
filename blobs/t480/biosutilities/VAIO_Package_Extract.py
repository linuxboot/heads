#!/usr/bin/env python3
#coding=utf-8

"""
VAIO Package Extractor
VAIO Packaging Manager Extractor
Copyright (C) 2019-2022 Plato Mavropoulos
"""

TITLE = 'VAIO Packaging Manager Extractor v3.0_a8'

import os
import sys

# Stop __pycache__ generation
sys.dont_write_bytecode = True

from common.comp_szip import is_szip_supported, szip_decompress
from common.path_ops import make_dirs
from common.patterns import PAT_VAIO_CAB, PAT_VAIO_CFG, PAT_VAIO_CHK, PAT_VAIO_EXT
from common.system import printer
from common.templates import BIOSUtility
from common.text_ops import file_to_bytes

# Check if input is VAIO Packaging Manager
def is_vaio_pkg(in_file):
    buffer = file_to_bytes(in_file)
    
    return bool(PAT_VAIO_CFG.search(buffer))

# Extract VAIO Packaging Manager executable
def vaio_cabinet(name, buffer, extract_path, padding=0):
    match_cab = PAT_VAIO_CAB.search(buffer) # Microsoft CAB Header XOR 0xFF
    
    if not match_cab:
        return 1
    
    printer('Detected obfuscated CAB archive!', padding)
    
    # Determine the Microsoft CAB image size
    cab_size = int.from_bytes(buffer[match_cab.start() + 0x8:match_cab.start() + 0xC], 'little') # Get LE XOR-ed CAB size
    xor_size = int.from_bytes(b'\xFF' * 0x4, 'little') # Create CAB size XOR value
    cab_size ^= xor_size # Perform XOR 0xFF and get actual CAB size

    printer('Removing obfuscation...', padding + 4)
    
    # Determine the Microsoft CAB image Data
    cab_data = int.from_bytes(buffer[match_cab.start():match_cab.start() + cab_size], 'big') # Get BE XOR-ed CAB data
    xor_data = int.from_bytes(b'\xFF' * cab_size, 'big') # Create CAB data XOR value
    cab_data = (cab_data ^ xor_data).to_bytes(cab_size, 'big') # Perform XOR 0xFF and get actual CAB data
    
    printer('Extracting archive...', padding + 4)
    
    cab_path = os.path.join(extract_path, f'{name}_Temporary.cab')
    
    with open(cab_path, 'wb') as cab_file:
        cab_file.write(cab_data) # Create temporary CAB archive
    
    if is_szip_supported(cab_path, padding + 8, check=True):
        if szip_decompress(cab_path, extract_path, 'CAB', padding + 8, check=True) == 0:
            os.remove(cab_path) # Successful extraction, delete temporary CAB archive
        else:
            return 3
    else:
        return 2
    
    return 0

# Unlock VAIO Packaging Manager executable
def vaio_unlock(name, buffer, extract_path, padding=0):
    match_cfg = PAT_VAIO_CFG.search(buffer)
    
    if not match_cfg:
        return 1
    
    printer('Attempting to Unlock executable!', padding)
    
    # Initialize VAIO Package Configuration file variables (assume overkill size of 0x500)
    cfg_bgn,cfg_end,cfg_false,cfg_true = [match_cfg.start(), match_cfg.start() + 0x500, b'', b'']
    
    # Get VAIO Package Configuration file info, split at new_line and stop at payload DOS header (EOF)
    cfg_info = buffer[cfg_bgn:cfg_end].split(b'\x0D\x0A\x4D\x5A')[0].replace(b'\x0D',b'').split(b'\x0A')
    
    printer('Retrieving True/False values...', padding + 4)
    
    # Determine VAIO Package Configuration file True & False values
    for info in cfg_info:
        if info.startswith(b'ExtractPathByUser='):
            cfg_false = bytearray(b'0' if info[18:] in (b'0',b'1') else info[18:]) # Should be 0/No/False
        if info.startswith(b'UseCompression='):
            cfg_true = bytearray(b'1' if info[15:] in (b'0',b'1') else info[15:]) # Should be 1/Yes/True
    
    # Check if valid True/False values have been retrieved
    if cfg_false == cfg_true or not cfg_false or not cfg_true:
        printer('Error: Could not retrieve True/False values!', padding + 8)
        return 2
    
    printer('Adjusting UseVAIOCheck entry...', padding + 4)
    
    # Find and replace UseVAIOCheck entry from 1/Yes/True to 0/No/False
    vaio_check = PAT_VAIO_CHK.search(buffer[cfg_bgn:])
    if vaio_check:
        buffer[cfg_bgn + vaio_check.end():cfg_bgn + vaio_check.end() + len(cfg_true)] = cfg_false
    else:
        printer('Error: Could not find entry UseVAIOCheck!', padding + 8)
        return 3
    
    printer('Adjusting ExtractPathByUser entry...', padding + 4)
    
    # Find and replace ExtractPathByUser entry from 0/No/False to 1/Yes/True
    user_path = PAT_VAIO_EXT.search(buffer[cfg_bgn:])
    if user_path:
        buffer[cfg_bgn + user_path.end():cfg_bgn + user_path.end() + len(cfg_false)] = cfg_true
    else:
        printer('Error: Could not find entry ExtractPathByUser!', padding + 8)
        return 4
    
    printer('Storing unlocked executable...', padding + 4)
    
    # Store Unlocked VAIO Packaging Manager executable
    if vaio_check and user_path:
        unlock_path = os.path.join(extract_path, f'{name}_Unlocked.exe')
        with open(unlock_path, 'wb') as unl_file:
            unl_file.write(buffer)
    
    return 0

# Parse & Extract or Unlock VAIO Packaging Manager
def vaio_pkg_extract(input_file, extract_path, padding=0):
    input_buffer = file_to_bytes(input_file)
    
    input_name = os.path.basename(input_file)
    
    make_dirs(extract_path, delete=True)
    
    if vaio_cabinet(input_name, input_buffer, extract_path, padding) == 0:
        printer('Successfully Extracted!', padding)
    elif vaio_unlock(input_name, bytearray(input_buffer), extract_path, padding) == 0:
        printer('Successfully Unlocked!', padding)
    else:
        printer('Error: Failed to Extract or Unlock executable!', padding)
        return 1
    
    return 0

if __name__ == '__main__':
    BIOSUtility(TITLE, is_vaio_pkg, vaio_pkg_extract).run_utility()
