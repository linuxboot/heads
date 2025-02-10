#!/usr/bin/env python3
#coding=utf-8

"""
Copyright (C) 2022 Plato Mavropoulos
"""

import pefile

from common.system import printer
from common.text_ops import file_to_bytes

# Check if input is a PE file
def is_pe_file(in_file):
    return bool(get_pe_file(in_file))

# Get pefile object from PE file
def get_pe_file(in_file, fast=True):
    in_buffer = file_to_bytes(in_file)
    
    try:
        # Analyze detected MZ > PE image buffer
        pe_file = pefile.PE(data=in_buffer, fast_load=fast)
    except Exception:
        pe_file = None
    
    return pe_file

# Get PE info from pefile object
def get_pe_info(pe_file):
    try:
        # When fast_load is used, IMAGE_DIRECTORY_ENTRY_RESOURCE must be parsed prior to FileInfo > StringTable
        pe_file.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_RESOURCE']])
        
        # Retrieve MZ > PE > FileInfo > StringTable information
        pe_info = pe_file.FileInfo[0][0].StringTable[0].entries
    except Exception:
        pe_info = {}
    
    return pe_info

# Print PE info from pefile StringTable
def show_pe_info(pe_info, padding=0):
    if type(pe_info).__name__ == 'dict':
        for title,value in pe_info.items():
            info_title = title.decode('utf-8','ignore').strip()
            info_value = value.decode('utf-8','ignore').strip()
            if info_title and info_value:
                printer(f'{info_title}: {info_value}', padding, new_line=False)
