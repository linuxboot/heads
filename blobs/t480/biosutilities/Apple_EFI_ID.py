#!/usr/bin/env python3
#coding=utf-8

"""
Apple EFI ID
Apple EFI Image Identifier
Copyright (C) 2018-2022 Plato Mavropoulos
"""

TITLE = 'Apple EFI Image Identifier v2.0_a5'

import os
import sys
import zlib
import struct
import ctypes
import subprocess

# Stop __pycache__ generation
sys.dont_write_bytecode = True

from common.externals import get_uefifind_path, get_uefiextract_path
from common.path_ops import del_dirs, path_parent, path_suffixes
from common.patterns import PAT_APPLE_EFI
from common.struct_ops import char, get_struct, uint8_t
from common.system import printer
from common.templates import BIOSUtility
from common.text_ops import file_to_bytes

class IntelBiosId(ctypes.LittleEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('Signature',       char*8),        # 0x00
        ('BoardID',         uint8_t*16),    # 0x08
        ('Dot1',            uint8_t*2),     # 0x18
        ('BoardExt',        uint8_t*6),     # 0x1A
        ('Dot2',            uint8_t*2),     # 0x20
        ('VersionMajor',    uint8_t*8),     # 0x22
        ('Dot3',            uint8_t*2),     # 0x2A
        ('BuildType',       uint8_t*2),     # 0x2C
        ('VersionMinor',    uint8_t*4),     # 0x2E
        ('Dot4',            uint8_t*2),     # 0x32
        ('Year',            uint8_t*4),     # 0x34
        ('Month',           uint8_t*4),     # 0x38
        ('Day',             uint8_t*4),     # 0x3C
        ('Hour',            uint8_t*4),     # 0x40
        ('Minute',          uint8_t*4),     # 0x44
        ('NullTerminator',  uint8_t*2),     # 0x48
        # 0x4A
    ]
    
    # https://github.com/tianocore/edk2-platforms/blob/master/Platform/Intel/BoardModulePkg/Include/Guid/BiosId.h
    
    @staticmethod
    def decode(field):
        return struct.pack('B' * len(field), *field).decode('utf-16','ignore').strip('\x00 ')
    
    def get_bios_id(self):
        BoardID = self.decode(self.BoardID)
        BoardExt = self.decode(self.BoardExt)
        VersionMajor = self.decode(self.VersionMajor)
        BuildType = self.decode(self.BuildType)
        VersionMinor = self.decode(self.VersionMinor)
        BuildDate = f'20{self.decode(self.Year)}-{self.decode(self.Month)}-{self.decode(self.Day)}'
        BuildTime = f'{self.decode(self.Hour)}-{self.decode(self.Minute)}'
        
        return BoardID, BoardExt, VersionMajor, BuildType, VersionMinor, BuildDate, BuildTime
    
    def struct_print(self, p):
        BoardID,BoardExt,VersionMajor,BuildType,VersionMinor,BuildDate,BuildTime = self.get_bios_id()
        
        printer(['Intel Signature:', self.Signature.decode('utf-8')], p, False)
        printer(['Board Identity: ', BoardID], p, False)
        printer(['Apple Identity: ', BoardExt], p, False)
        printer(['Major Version:  ', VersionMajor], p, False)
        printer(['Minor Version:  ', VersionMinor], p, False)
        printer(['Build Type:     ', BuildType], p, False)
        printer(['Build Date:     ', BuildDate], p, False)
        printer(['Build Time:     ', BuildTime.replace('-',':')], p, False)

# Check if input is Apple EFI image
def is_apple_efi(input_file):
    input_buffer = file_to_bytes(input_file)
    
    if PAT_APPLE_EFI.search(input_buffer):
        return True
    
    if not os.path.isfile(input_file):
        return False
    
    try:
        _ = subprocess.run([get_uefifind_path(), input_file, 'body', 'list', PAT_UEFIFIND],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        
        return True
    except Exception:
        return False

# Parse & Identify (or Rename) Apple EFI image
def apple_efi_identify(input_file, extract_path, padding=0, rename=False):
    if not os.path.isfile(input_file):
        printer('Error: Could not find input file path!', padding)
        
        return 1
    
    input_buffer = file_to_bytes(input_file)
    
    bios_id_match = PAT_APPLE_EFI.search(input_buffer) # Detect $IBIOSI$ pattern
    
    if bios_id_match:
        bios_id_res = f'0x{bios_id_match.start():X}'
        
        bios_id_hdr = get_struct(input_buffer, bios_id_match.start(), IntelBiosId)
    else:
        # The $IBIOSI$ pattern is within EFI compressed modules so we need to use UEFIFind and UEFIExtract
        try:
            bios_id_res = subprocess.check_output([get_uefifind_path(), input_file, 'body', 'list', PAT_UEFIFIND],
            text=True)[:36]
            
            del_dirs(extract_path) # UEFIExtract must create its output folder itself, make sure it is not present
            
            _ = subprocess.run([get_uefiextract_path(), input_file, bios_id_res, '-o', extract_path, '-m', 'body'],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            
            with open(os.path.join(extract_path, 'body.bin'), 'rb') as raw_body:
                body_buffer = raw_body.read()
            
            bios_id_match = PAT_APPLE_EFI.search(body_buffer) # Detect decompressed $IBIOSI$ pattern
            
            bios_id_hdr = get_struct(body_buffer, bios_id_match.start(), IntelBiosId)
            
            del_dirs(extract_path) # Successful UEFIExtract extraction, remove its output (temp) folder
        except Exception:
            printer('Error: Failed to parse compressed $IBIOSI$ pattern!', padding)
            
            return 2
    
    printer(f'Detected $IBIOSI$ at {bios_id_res}\n', padding)
    
    bios_id_hdr.struct_print(padding + 4)
    
    if rename:
        input_parent = path_parent(input_file)
        
        input_suffix = path_suffixes(input_file)[-1]
        
        input_adler32 = zlib.adler32(input_buffer)
        
        ID,Ext,Major,Type,Minor,Date,Time = bios_id_hdr.get_bios_id()
        
        output_name = f'{ID}_{Ext}_{Major}_{Type}{Minor}_{Date}_{Time}_{input_adler32:08X}{input_suffix}'
        
        output_file = os.path.join(input_parent, output_name)
        
        if not os.path.isfile(output_file):
            os.replace(input_file, output_file) # Rename input file based on its EFI tag
        
        printer(f'Renamed to {output_name}', padding)
    
    return 0

PAT_UEFIFIND = f'244942494F534924{"."*32}2E00{"."*12}2E00{"."*16}2E00{"."*12}2E00{"."*40}0000'

if __name__ == '__main__':
    utility = BIOSUtility(TITLE, is_apple_efi, apple_efi_identify)
    utility.parse_argument('-r', '--rename', help='rename EFI image based on its tag', action='store_true')
    utility.run_utility()
