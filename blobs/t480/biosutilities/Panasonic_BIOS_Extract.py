#!/usr/bin/env python3
#coding=utf-8

"""
Panasonic BIOS Extract
Panasonic BIOS Package Extractor
Copyright (C) 2018-2022 Plato Mavropoulos
"""

TITLE = 'Panasonic BIOS Package Extractor v2.0_a10'

import os
import io
import sys
import lznt1
import pefile

# Stop __pycache__ generation
sys.dont_write_bytecode = True

from common.comp_szip import is_szip_supported, szip_decompress
from common.path_ops import get_path_files, make_dirs, path_stem, safe_name
from common.pe_ops import get_pe_file, get_pe_info, is_pe_file, show_pe_info
from common.patterns import PAT_MICROSOFT_CAB
from common.system import printer
from common.templates import BIOSUtility
from common.text_ops import file_to_bytes

from AMI_PFAT_Extract import is_ami_pfat, parse_pfat_file

# Check if input is Panasonic BIOS Package PE
def is_panasonic_pkg(in_file):
    in_buffer = file_to_bytes(in_file)
    
    pe_file = get_pe_file(in_buffer, fast=True)
    
    if not pe_file:
        return False
    
    pe_info = get_pe_info(pe_file)
    
    if not pe_info:
        return False
    
    if pe_info.get(b'FileDescription',b'').upper() != b'UNPACK UTILITY':
        return False
    
    if not PAT_MICROSOFT_CAB.search(in_buffer):
        return False
    
    return True

# Search and Extract Panasonic BIOS Package PE CAB archive
def panasonic_cab_extract(buffer, extract_path, padding=0):
    pe_path,pe_file,pe_info = [None] * 3
    
    cab_bgn = PAT_MICROSOFT_CAB.search(buffer).start()
    cab_len = int.from_bytes(buffer[cab_bgn + 0x8:cab_bgn + 0xC], 'little')
    cab_end = cab_bgn + cab_len
    cab_bin = buffer[cab_bgn:cab_end]
    cab_tag = f'[0x{cab_bgn:06X}-0x{cab_end:06X}]'
    
    cab_path = os.path.join(extract_path, f'CAB_{cab_tag}.cab')
    
    with open(cab_path, 'wb') as cab_file:
        cab_file.write(cab_bin) # Store CAB archive
    
    if is_szip_supported(cab_path, padding, check=True):
        printer(f'Panasonic BIOS Package > PE > CAB {cab_tag}', padding)
        
        if szip_decompress(cab_path, extract_path, 'CAB', padding + 4, check=True) == 0:
            os.remove(cab_path) # Successful extraction, delete CAB archive
        else:
            return pe_path, pe_file, pe_info
    else:
        return pe_path, pe_file, pe_info
    
    for file_path in get_path_files(extract_path):
        pe_file = get_pe_file(file_path, fast=True)
        if pe_file:
            pe_info = get_pe_info(pe_file)
            if pe_info.get(b'FileDescription',b'').upper() == b'BIOS UPDATE':
                pe_path = file_path
                break
    else:
        return pe_path, pe_file, pe_info
    
    return pe_path, pe_file, pe_info

# Extract & Decompress Panasonic BIOS Update PE RCDATA (LZNT1)
def panasonic_res_extract(pe_name, pe_file, extract_path, padding=0):
    is_rcdata = False
    
    # When fast_load is used, IMAGE_DIRECTORY_ENTRY_RESOURCE must be parsed prior to RCDATA Directories
    pe_file.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_RESOURCE']])
    
    # Parse all Resource Data Directories > RCDATA (ID = 10)
    for entry in pe_file.DIRECTORY_ENTRY_RESOURCE.entries:
        if entry.struct.name == 'IMAGE_RESOURCE_DIRECTORY_ENTRY' and entry.struct.Id == 0xA:
            is_rcdata = True
            for resource in entry.directory.entries:
                res_bgn = resource.directory.entries[0].data.struct.OffsetToData
                res_len = resource.directory.entries[0].data.struct.Size
                res_end = res_bgn + res_len
                res_bin = pe_file.get_data(res_bgn, res_len)
                res_tag = f'{pe_name} [0x{res_bgn:06X}-0x{res_end:06X}]'
                res_out = os.path.join(extract_path, f'{res_tag}')
                
                printer(res_tag, padding + 4)
                
                try:
                    res_raw = lznt1.decompress(res_bin[0x8:])
                    
                    printer('Succesfull LZNT1 decompression via lznt1!', padding + 8) 
                except Exception:
                    res_raw = res_bin
                    
                    printer('Succesfull PE Resource extraction!', padding + 8)
                
                # Detect & Unpack AMI BIOS Guard (PFAT) BIOS image
                if is_ami_pfat(res_raw):
                    pfat_dir = os.path.join(extract_path, res_tag)
                    
                    parse_pfat_file(res_raw, pfat_dir, padding + 12)
                else:
                    if is_pe_file(res_raw):
                        res_ext = 'exe'
                    elif res_raw.startswith(b'[') and res_raw.endswith((b'\x0D\x0A',b'\x0A')):
                        res_ext = 'txt'
                    else:
                        res_ext = 'bin'
                    
                    if res_ext == 'txt':
                        printer(new_line=False)
                        for line in io.BytesIO(res_raw).readlines():
                            line_text = line.decode('utf-8','ignore').rstrip()
                            printer(line_text, padding + 12, new_line=False)
                    
                    with open(f'{res_out}.{res_ext}', 'wb') as out_file:
                        out_file.write(res_raw)
    
    return is_rcdata

# Extract Panasonic BIOS Update PE Data when RCDATA is not available
def panasonic_img_extract(pe_name, pe_path, pe_file, extract_path, padding=0):
    pe_data = file_to_bytes(pe_path)
    
    sec_bgn = pe_file.OPTIONAL_HEADER.DATA_DIRECTORY[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_SECURITY']].VirtualAddress
    img_bgn = pe_file.OPTIONAL_HEADER.BaseOfData + pe_file.OPTIONAL_HEADER.SizeOfInitializedData
    img_end = sec_bgn or len(pe_data)
    img_bin = pe_data[img_bgn:img_end]
    img_tag = f'{pe_name} [0x{img_bgn:X}-0x{img_end:X}]'
    img_out = os.path.join(extract_path, f'{img_tag}.bin')
    
    printer(img_tag, padding + 4)
    
    with open(img_out, 'wb') as out_img:
        out_img.write(img_bin)
    
    printer('Succesfull PE Data extraction!', padding + 8)
    
    return bool(img_bin)

# Parse & Extract Panasonic BIOS Package PE
def panasonic_pkg_extract(input_file, extract_path, padding=0):
    input_buffer = file_to_bytes(input_file)
    
    make_dirs(extract_path, delete=True)
    
    pkg_pe_file = get_pe_file(input_buffer, fast=True)
    
    if not pkg_pe_file:
        return 2
    
    pkg_pe_info = get_pe_info(pkg_pe_file)
    
    if not pkg_pe_info:
        return 3
    
    pkg_pe_name = path_stem(input_file)
    
    printer(f'Panasonic BIOS Package > PE ({pkg_pe_name})\n', padding)
    
    show_pe_info(pkg_pe_info, padding + 4)
    
    upd_pe_path,upd_pe_file,upd_pe_info = panasonic_cab_extract(input_buffer, extract_path, padding + 4)
    
    if not (upd_pe_path and upd_pe_file and upd_pe_info):
        return 4
    
    upd_pe_name = safe_name(path_stem(upd_pe_path))
    
    printer(f'Panasonic BIOS Update > PE ({upd_pe_name})\n', padding + 12)
    
    show_pe_info(upd_pe_info, padding + 16)
    
    is_upd_res, is_upd_img = False, False
    
    is_upd_res = panasonic_res_extract(upd_pe_name, upd_pe_file, extract_path, padding + 16)
    
    if not is_upd_res:
        is_upd_img = panasonic_img_extract(upd_pe_name, upd_pe_path, upd_pe_file, extract_path, padding + 16)

    os.remove(upd_pe_path)
    
    return 0 if is_upd_res or is_upd_img else 1

if __name__ == '__main__':
    BIOSUtility(TITLE, is_panasonic_pkg, panasonic_pkg_extract).run_utility()
