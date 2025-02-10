#!/usr/bin/env python3
#coding=utf-8

"""
Apple EFI PKG
Apple EFI Package Extractor
Copyright (C) 2019-2022 Plato Mavropoulos
"""

TITLE = 'Apple EFI Package Extractor v2.0_a5'

import os
import sys

# Stop __pycache__ generation
sys.dont_write_bytecode = True

from common.comp_szip import is_szip_supported, szip_decompress
from common.path_ops import copy_file, del_dirs, get_path_files, make_dirs, path_name, path_parent, get_extract_path
from common.patterns import PAT_APPLE_PKG
from common.system import printer
from common.templates import BIOSUtility
from common.text_ops import file_to_bytes

from Apple_EFI_ID import apple_efi_identify, is_apple_efi
from Apple_EFI_IM4P import apple_im4p_split, is_apple_im4p
from Apple_EFI_PBZX import apple_pbzx_extract, is_apple_pbzx

# Check if input is Apple EFI PKG package
def is_apple_pkg(input_file):
    input_buffer = file_to_bytes(input_file)
    
    return bool(PAT_APPLE_PKG.search(input_buffer[:0x4]))

# Split Apple EFI image (if applicable) and Rename
def efi_split_rename(in_file, out_path, padding=0):
    exit_codes = []
    
    working_dir = get_extract_path(in_file)
    
    if is_apple_im4p(in_file):
        printer(f'Splitting IM4P via {is_apple_im4p.__module__}...', padding)
        im4p_exit = apple_im4p_split(in_file, working_dir, padding + 4)
        exit_codes.append(im4p_exit)
    else:
        make_dirs(working_dir, delete=True)
        copy_file(in_file, working_dir, True)
    
    for efi_file in get_path_files(working_dir):
        if is_apple_efi(efi_file):
            printer(f'Renaming EFI via {is_apple_efi.__module__}...', padding)
            name_exit = apple_efi_identify(efi_file, efi_file, padding + 4, True)
            exit_codes.append(name_exit)
    
    for named_file in get_path_files(working_dir):
        copy_file(named_file, out_path, True)
    
    del_dirs(working_dir)
    
    return sum(exit_codes)

# Parse & Extract Apple EFI PKG packages
def apple_pkg_extract(input_file, extract_path, padding=0):
    if not os.path.isfile(input_file):
        printer('Error: Could not find input file path!', padding)
        return 1
    
    make_dirs(extract_path, delete=True)
    
    xar_path = os.path.join(extract_path, 'xar')
    
    # Decompress PKG > XAR archive with 7-Zip
    if is_szip_supported(input_file, padding, args=['-tXAR'], check=True):
        if szip_decompress(input_file, xar_path, 'XAR', padding, args=['-tXAR'], check=True) != 0:
            return 3
    else:
        return 2
    
    for xar_file in get_path_files(xar_path):
        if path_name(xar_file) == 'Payload':
            pbzx_module = is_apple_pbzx.__module__
            if is_apple_pbzx(xar_file):
                printer(f'Extracting PBZX via {pbzx_module}...', padding + 4)
                pbzx_path = get_extract_path(xar_file)
                if apple_pbzx_extract(xar_file, pbzx_path, padding + 8) == 0:
                    printer(f'Succesfull PBZX extraction via {pbzx_module}!', padding + 4)
                    for pbzx_file in get_path_files(pbzx_path):
                        if path_name(pbzx_file) == 'UpdateBundle.zip':
                            if is_szip_supported(pbzx_file, padding + 8, args=['-tZIP'], check=True):
                                zip_path = get_extract_path(pbzx_file)
                                if szip_decompress(pbzx_file, zip_path, 'ZIP', padding + 8, args=['-tZIP'], check=True) == 0:
                                    for zip_file in get_path_files(zip_path):
                                        if path_name(path_parent(zip_file)) == 'MacEFI':
                                            printer(path_name(zip_file), padding + 12)
                                            if efi_split_rename(zip_file, extract_path, padding + 16) != 0:
                                                printer(f'Error: Could not split and rename {path_name(zip_file)}!', padding)
                                                return 10
                                else:
                                    return 9
                            else:
                                return 8
                            break # ZIP found, stop
                    else:
                        printer('Error: Could not find "UpdateBundle.zip" file!', padding)
                        return 7
                else:
                    printer(f'Error: Failed to extract PBZX file via {pbzx_module}!', padding)
                    return 6
            else:
                printer(f'Error: Failed to detect file as PBZX via {pbzx_module}!', padding)
                return 5
            
            break # Payload found, stop searching
        
        if path_name(xar_file) == 'Scripts':
            if is_szip_supported(xar_file, padding + 4, args=['-tGZIP'], check=True):
                gzip_path = get_extract_path(xar_file)
                if szip_decompress(xar_file, gzip_path, 'GZIP', padding + 4, args=['-tGZIP'], check=True) == 0:
                    for gzip_file in get_path_files(gzip_path):
                        if is_szip_supported(gzip_file, padding + 8, args=['-tCPIO'], check=True):
                            cpio_path = get_extract_path(gzip_file)
                            if szip_decompress(gzip_file, cpio_path, 'CPIO', padding + 8, args=['-tCPIO'], check=True) == 0:
                                for cpio_file in get_path_files(cpio_path):
                                    if path_name(path_parent(cpio_file)) == 'EFIPayloads':
                                        printer(path_name(cpio_file), padding + 12)
                                        if efi_split_rename(cpio_file, extract_path, padding + 16) != 0:
                                            printer(f'Error: Could not split and rename {path_name(cpio_file)}!', padding)
                                            return 15
                            else:
                                return 14
                        else:
                            return 13
                else:
                    return 12
            else:
                return 11
            
            break # Scripts found, stop searching
    else:
        printer('Error: Could not find "Payload" or "Scripts" file!', padding)
        return 4
    
    del_dirs(xar_path) # Delete temporary/working XAR folder
    
    return 0

if __name__ == '__main__':
    BIOSUtility(TITLE, is_apple_pkg, apple_pkg_extract).run_utility()
