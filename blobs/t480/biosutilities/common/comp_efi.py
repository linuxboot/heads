#!/usr/bin/env python3
#coding=utf-8

"""
Copyright (C) 2022 Plato Mavropoulos
"""

import os
import subprocess

from common.path_ops import project_root, safe_path
from common.system import get_os_ver, printer

def get_compress_sizes(data):    
    size_compress = int.from_bytes(data[0x0:0x4], 'little')
    size_original = int.from_bytes(data[0x4:0x8], 'little')
    
    return size_compress, size_original

def is_efi_compressed(data, strict=True):
    size_comp,size_orig = get_compress_sizes(data)
    
    check_diff = size_comp < size_orig
    
    if strict:
        check_size = size_comp + 0x8 == len(data)
    else:
        check_size = size_comp + 0x8 <= len(data)
    
    return check_diff and check_size

# Get TianoCompress path
def get_tiano_path():
    exec_name = f'TianoCompress{".exe" if get_os_ver()[1] else ""}'
    
    return safe_path(project_root(), ['external',exec_name])

# EFI/Tiano Decompression via TianoCompress
def efi_decompress(in_path, out_path, padding=0, silent=False, comp_type='--uefi'):
    try:
        subprocess.run([get_tiano_path(), '-d', in_path, '-o', out_path, '-q', comp_type], check=True, stdout=subprocess.DEVNULL)
        
        with open(in_path, 'rb') as file:
            _,size_orig = get_compress_sizes(file.read())
        
        if os.path.getsize(out_path) != size_orig:
            raise Exception('EFI_DECOMPRESS_ERROR')
    except Exception:
        if not silent:
            printer(f'Error: TianoCompress could not extract file {in_path}!', padding)
        
        return 1
    
    if not silent:
        printer('Succesfull EFI decompression via TianoCompress!', padding)
    
    return 0
