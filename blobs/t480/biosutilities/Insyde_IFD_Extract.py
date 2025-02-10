#!/usr/bin/env python3
#coding=utf-8

"""
Insyde IFD Extract
Insyde iFlash/iFdPacker Extractor
Copyright (C) 2022 Plato Mavropoulos
"""

TITLE = 'Insyde iFlash/iFdPacker Extractor v2.0_a11'

import os
import sys
import ctypes
    
# Stop __pycache__ generation
sys.dont_write_bytecode = True

from common.comp_szip import is_szip_supported, szip_decompress
from common.path_ops import get_path_files, make_dirs, safe_name, get_extract_path
from common.patterns import PAT_INSYDE_IFL, PAT_INSYDE_SFX
from common.struct_ops import char, get_struct, uint32_t
from common.system import printer
from common.templates import BIOSUtility
from common.text_ops import file_to_bytes

class IflashHeader(ctypes.LittleEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('Signature',       char*8),        # 0x00 $_IFLASH
        ('ImageTag',        char*8),        # 0x08
        ('TotalSize',       uint32_t),      # 0x10 from header end
        ('ImageSize',       uint32_t),      # 0x14 from header end
        # 0x18
    ]
    
    def _get_padd_len(self):
        return self.TotalSize - self.ImageSize
    
    def get_image_tag(self):
        return self.ImageTag.decode('utf-8','ignore').strip('_')
    
    def struct_print(self, p):
        printer(['Signature :', self.Signature.decode('utf-8')], p, False)
        printer(['Image Name:', self.get_image_tag()], p, False)
        printer(['Image Size:', f'0x{self.ImageSize:X}'], p, False)
        printer(['Total Size:', f'0x{self.TotalSize:X}'], p, False)
        printer(['Padd Size :', f'0x{self._get_padd_len():X}'], p, False)

# Check if input is Insyde iFlash/iFdPacker Update image
def is_insyde_ifd(input_file):
    input_buffer = file_to_bytes(input_file)
    
    is_ifl = bool(insyde_iflash_detect(input_buffer))
    
    is_sfx = bool(PAT_INSYDE_SFX.search(input_buffer))
    
    return is_ifl or is_sfx

# Parse & Extract Insyde iFlash/iFdPacker Update images
def insyde_ifd_extract(input_file, extract_path, padding=0):
    input_buffer = file_to_bytes(input_file)
    
    iflash_code = insyde_iflash_extract(input_buffer, extract_path, padding)
    
    ifdpack_path = os.path.join(extract_path, 'Insyde iFdPacker SFX')
    
    ifdpack_code = insyde_packer_extract(input_buffer, ifdpack_path, padding)
    
    return iflash_code and ifdpack_code

# Detect Insyde iFlash Update image
def insyde_iflash_detect(input_buffer):
    iflash_match_all = []
    iflash_match_nan = [0x0,0xFFFFFFFF]
    
    for iflash_match in PAT_INSYDE_IFL.finditer(input_buffer):
        ifl_bgn = iflash_match.start()
        
        if len(input_buffer[ifl_bgn:]) <= INS_IFL_LEN:
            continue
        
        ifl_hdr = get_struct(input_buffer, ifl_bgn, IflashHeader)
        
        if ifl_hdr.TotalSize in iflash_match_nan \
        or ifl_hdr.ImageSize in iflash_match_nan \
        or ifl_hdr.TotalSize < ifl_hdr.ImageSize \
        or ifl_bgn + INS_IFL_LEN + ifl_hdr.TotalSize > len(input_buffer):
            continue
        
        iflash_match_all.append([ifl_bgn, ifl_hdr])
    
    return iflash_match_all

# Extract Insyde iFlash Update image
def insyde_iflash_extract(input_buffer, extract_path, padding=0):
    insyde_iflash_all = insyde_iflash_detect(input_buffer)
    
    if not insyde_iflash_all:
        return 127
    
    printer('Detected Insyde iFlash Update image!', padding)
    
    make_dirs(extract_path, delete=True)
    
    exit_codes = []
    
    for insyde_iflash in insyde_iflash_all:
        exit_code = 0
        
        ifl_bgn,ifl_hdr = insyde_iflash
        
        img_bgn = ifl_bgn + INS_IFL_LEN
        img_end = img_bgn + ifl_hdr.ImageSize
        img_bin = input_buffer[img_bgn:img_end]
        
        if len(img_bin) != ifl_hdr.ImageSize:
            exit_code = 1
        
        img_val = [ifl_hdr.get_image_tag(), 'bin']
        img_tag,img_ext = INS_IFL_IMG.get(img_val[0], img_val)
        
        img_name = f'{img_tag} [0x{img_bgn:08X}-0x{img_end:08X}]'
        
        printer(f'{img_name}\n', padding + 4)
        
        ifl_hdr.struct_print(padding + 8)
        
        if img_val == [img_tag,img_ext]:
            printer(f'Note: Detected new Insyde iFlash tag {img_tag}!', padding + 12, pause=True)
        
        out_name = f'{img_name}.{img_ext}'
        
        out_path = os.path.join(extract_path, safe_name(out_name))
        
        with open(out_path, 'wb') as out_image:
            out_image.write(img_bin)
        
        printer(f'Succesfull Insyde iFlash > {img_tag} extraction!', padding + 12)
        
        exit_codes.append(exit_code)
    
    return sum(exit_codes)

# Extract Insyde iFdPacker 7-Zip SFX 7z Update image
def insyde_packer_extract(input_buffer, extract_path, padding=0):
    match_sfx = PAT_INSYDE_SFX.search(input_buffer)
    
    if not match_sfx:
        return 127
    
    printer('Detected Insyde iFdPacker Update image!', padding)
    
    make_dirs(extract_path, delete=True)
    
    sfx_buffer = bytearray(input_buffer[match_sfx.end() - 0x5:])
    
    if sfx_buffer[:0x5] == b'\x6E\xF4\x79\x5F\x4E':
        printer('Detected Insyde iFdPacker > 7-Zip SFX > Obfuscation!', padding + 4)
        
        for index,byte in enumerate(sfx_buffer):
            sfx_buffer[index] = byte // 2 + (128 if byte % 2 else 0)
        
        printer('Removed Insyde iFdPacker > 7-Zip SFX > Obfuscation!', padding + 8)
    
    printer('Extracting Insyde iFdPacker > 7-Zip SFX archive...', padding + 4)
    
    if bytes(INS_SFX_PWD, 'utf-16le') in input_buffer[:match_sfx.start()]:
        printer('Detected Insyde iFdPacker > 7-Zip SFX > Password!', padding + 8)
        printer(INS_SFX_PWD, padding + 12)
    
    sfx_path = os.path.join(extract_path, 'Insyde_iFdPacker_SFX.7z')
    
    with open(sfx_path, 'wb') as sfx_file:
        sfx_file.write(sfx_buffer)
    
    if is_szip_supported(sfx_path, padding + 8, args=[f'-p{INS_SFX_PWD}'], check=True):
        if szip_decompress(sfx_path, extract_path, 'Insyde iFdPacker > 7-Zip SFX',
        padding + 8, args=[f'-p{INS_SFX_PWD}'], check=True) == 0:
            os.remove(sfx_path)
        else:
            return 125
    else:
        return 126
    
    exit_codes = []
    
    for sfx_file in get_path_files(extract_path):
        if is_insyde_ifd(sfx_file):
            printer(f'{os.path.basename(sfx_file)}', padding + 12)
            
            ifd_code = insyde_ifd_extract(sfx_file, get_extract_path(sfx_file), padding + 16)
            
            exit_codes.append(ifd_code)
    
    return sum(exit_codes)

# Insyde iFdPacker known 7-Zip SFX Password
INS_SFX_PWD = 'Y`t~i!L@i#t$U%h^s7A*l(f)E-d=y+S_n?i'

# Insyde iFlash known Image Names
INS_IFL_IMG = {
    'BIOSCER' : ['Certificate', 'bin'],
    'BIOSCR2' : ['Certificate 2nd', 'bin'],
    'BIOSIMG' : ['BIOS-UEFI', 'bin'],
    'DRV_IMG' : ['isflash', 'efi'],
    'EC_IMG' : ['Embedded Controller', 'bin'],
    'INI_IMG' : ['platform', 'ini'],
    'ME_IMG' : ['Management Engine', 'bin'],
    'OEM_ID' : ['OEM Identifier', 'bin'],
    }

# Get common ctypes Structure Sizes
INS_IFL_LEN = ctypes.sizeof(IflashHeader)

if __name__ == '__main__':
    BIOSUtility(TITLE, is_insyde_ifd, insyde_ifd_extract).run_utility()
