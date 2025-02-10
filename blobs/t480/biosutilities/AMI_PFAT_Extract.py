#!/usr/bin/env python3
#coding=utf-8

"""
AMI PFAT Extract
AMI BIOS Guard Extractor
Copyright (C) 2018-2022 Plato Mavropoulos
"""

TITLE = 'AMI BIOS Guard Extractor v4.0_a12'

import os
import re
import sys
import ctypes

# Stop __pycache__ generation
sys.dont_write_bytecode = True

from common.externals import get_bgs_tool
from common.num_ops import get_ordinal
from common.path_ops import make_dirs, safe_name, get_extract_path, extract_suffix
from common.patterns import PAT_AMI_PFAT
from common.struct_ops import char, get_struct, uint8_t, uint16_t, uint32_t
from common.system import printer
from common.templates import BIOSUtility
from common.text_ops import file_to_bytes

class AmiBiosGuardHeader(ctypes.LittleEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('Size',            uint32_t),      # 0x00 Header + Entries
        ('Checksum',        uint32_t),      # 0x04 ?
        ('Tag',             char*8),        # 0x04 _AMIPFAT
        ('Flags',           uint8_t),       # 0x10 ?
        # 0x11
    ]
    
    def struct_print(self, p):
        printer(['Size    :', f'0x{self.Size:X}'], p, False)
        printer(['Checksum:', f'0x{self.Checksum:04X}'], p, False)
        printer(['Tag     :', self.Tag.decode('utf-8')], p, False)
        printer(['Flags   :', f'0x{self.Flags:02X}'], p, False)

class IntelBiosGuardHeader(ctypes.LittleEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('BGVerMajor',      uint16_t),      # 0x00
        ('BGVerMinor',      uint16_t),      # 0x02
        ('PlatformID',      uint8_t*16),    # 0x04
        ('Attributes',      uint32_t),      # 0x14
        ('ScriptVerMajor',  uint16_t),      # 0x16
        ('ScriptVerMinor',  uint16_t),      # 0x18
        ('ScriptSize',      uint32_t),      # 0x1C
        ('DataSize',        uint32_t),      # 0x20
        ('BIOSSVN',         uint32_t),      # 0x24
        ('ECSVN',           uint32_t),      # 0x28
        ('VendorInfo',      uint32_t),      # 0x2C
        # 0x30
    ]
    
    def get_platform_id(self):
        id_byte = bytes(self.PlatformID)
        
        id_text = re.sub(r'[\n\t\r\x00 ]', '', id_byte.decode('utf-8','ignore'))
        
        id_hexs = f'{int.from_bytes(id_byte, "big"):0{0x10 * 2}X}'
        id_guid = f'{{{id_hexs[:8]}-{id_hexs[8:12]}-{id_hexs[12:16]}-{id_hexs[16:20]}-{id_hexs[20:]}}}'
        
        return f'{id_text} {id_guid}'
    
    def get_flags(self):
        attr = IntelBiosGuardHeaderGetAttributes()
        attr.asbytes = self.Attributes
        
        return attr.b.SFAM, attr.b.ProtectEC, attr.b.GFXMitDis, attr.b.FTU, attr.b.Reserved
    
    def struct_print(self, p):
        no_yes = ['No','Yes']
        f1,f2,f3,f4,f5 = self.get_flags()
        
        printer(['BIOS Guard Version          :', f'{self.BGVerMajor}.{self.BGVerMinor}'], p, False)
        printer(['Platform Identity           :', self.get_platform_id()], p, False)
        printer(['Signed Flash Address Map    :', no_yes[f1]], p, False)
        printer(['Protected EC OpCodes        :', no_yes[f2]], p, False)
        printer(['Graphics Security Disable   :', no_yes[f3]], p, False)
        printer(['Fault Tolerant Update       :', no_yes[f4]], p, False)
        printer(['Attributes Reserved         :', f'0x{f5:X}'], p, False)
        printer(['Script Version              :', f'{self.ScriptVerMajor}.{self.ScriptVerMinor}'], p, False)
        printer(['Script Size                 :', f'0x{self.ScriptSize:X}'], p, False)
        printer(['Data Size                   :', f'0x{self.DataSize:X}'], p, False)
        printer(['BIOS Security Version Number:', f'0x{self.BIOSSVN:X}'], p, False)
        printer(['EC Security Version Number  :', f'0x{self.ECSVN:X}'], p, False)
        printer(['Vendor Information          :', f'0x{self.VendorInfo:X}'], p, False)
        
class IntelBiosGuardHeaderAttributes(ctypes.LittleEndianStructure):
    _fields_ = [
        ('SFAM',            uint32_t,       1),     # Signed Flash Address Map
        ('ProtectEC',       uint32_t,       1),     # Protected EC OpCodes
        ('GFXMitDis',       uint32_t,       1),     # GFX Security Disable
        ('FTU',             uint32_t,       1),     # Fault Tolerant Update
        ('Reserved',        uint32_t,       28)     # Reserved/Unknown
    ]

class IntelBiosGuardHeaderGetAttributes(ctypes.Union):
    _fields_ = [
        ('b',               IntelBiosGuardHeaderAttributes),
        ('asbytes',         uint32_t)
    ]

class IntelBiosGuardSignature2k(ctypes.LittleEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('Unknown0',        uint32_t),      # 0x000
        ('Unknown1',        uint32_t),      # 0x004
        ('Modulus',         uint32_t*64),   # 0x008
        ('Exponent',        uint32_t),      # 0x108
        ('Signature',       uint32_t*64),   # 0x10C
        # 0x20C
    ]
    
    def struct_print(self, p):
        Modulus = f'{int.from_bytes(self.Modulus, "little"):0{0x100 * 2}X}'
        Signature = f'{int.from_bytes(self.Signature, "little"):0{0x100 * 2}X}'
        
        printer(['Unknown 0:', f'0x{self.Unknown0:X}'], p, False)
        printer(['Unknown 1:', f'0x{self.Unknown1:X}'], p, False)
        printer(['Modulus  :', f'{Modulus[:32]} [...]'], p, False)
        printer(['Exponent :', f'0x{self.Exponent:X}'], p, False)
        printer(['Signature:', f'{Signature[:32]} [...]'], p, False)

def is_ami_pfat(input_file):
    input_buffer = file_to_bytes(input_file)
    
    return bool(get_ami_pfat(input_buffer))

def get_ami_pfat(input_file):
    input_buffer = file_to_bytes(input_file)
    
    match = PAT_AMI_PFAT.search(input_buffer)
    
    return input_buffer[match.start() - 0x8:] if match else b''

def get_file_name(index, name):
    return safe_name(f'{index:02d} -- {name}')

def parse_bg_script(script_data, padding=0):
    is_opcode_div = len(script_data) % 8 == 0
    
    if not is_opcode_div:
        printer('Error: Script is not divisible by OpCode length!', padding, False)
        
        return 1
    
    is_begin_end = script_data[:8] + script_data[-8:] == b'\x01' + b'\x00' * 7 + b'\xFF' + b'\x00' * 7
    
    if not is_begin_end:
        printer('Error: Script lacks Begin and/or End OpCodes!', padding, False)
        
        return 2
    
    BigScript = get_bgs_tool()
    
    if not BigScript:
        printer('Note: BIOS Guard Script Tool optional dependency is missing!', padding, False)
        
        return 3
    
    script = BigScript(code_bytes=script_data).to_string().replace('\t','    ').split('\n')
    
    for opcode in script:
        if opcode.endswith(('begin','end')): spacing = padding
        elif opcode.endswith(':'): spacing = padding + 4
        else: spacing = padding + 12
        
        operands = [operand for operand in opcode.split(' ') if operand]
        printer(('{:<12s}' + '{:<11s}' * (len(operands) - 1)).format(*operands), spacing, False)
    
    return 0

def parse_pfat_hdr(buffer, padding=0):
    block_all = []
    
    pfat_hdr = get_struct(buffer, 0x0, AmiBiosGuardHeader)
    
    hdr_size = pfat_hdr.Size
    hdr_data = buffer[PFAT_AMI_HDR_LEN:hdr_size]
    hdr_text = hdr_data.decode('utf-8').splitlines()
    
    printer('AMI BIOS Guard Header:\n', padding)
    
    pfat_hdr.struct_print(padding + 4)
    
    hdr_title,*hdr_files = hdr_text
    
    files_count = len(hdr_files)
    
    hdr_tag,*hdr_indexes = hdr_title.split('II')
    
    printer(hdr_tag + '\n', padding + 4)
    
    bgt_indexes = [int(h, 16) for h in re.findall(r'.{1,4}', hdr_indexes[0])] if hdr_indexes else []
    
    for index,entry in enumerate(hdr_files):
        entry_parts = entry.split(';')
        
        info = entry_parts[0].split()
        name = entry_parts[1]
        
        flags = int(info[0])
        param = info[1]
        count = int(info[2])
        
        order = get_ordinal((bgt_indexes[index] if bgt_indexes else index) + 1)
        
        desc = f'{name} (Index: {index + 1:02d}, Flash: {order}, Parameter: {param}, Flags: 0x{flags:X}, Blocks: {count})'
        
        block_all += [(desc, name, order, param, flags, index, i, count) for i in range(count)]
    
    _ = [printer(block[0], padding + 8, False) for block in block_all if block[6] == 0]
    
    return block_all, hdr_size, files_count

def parse_pfat_file(input_file, extract_path, padding=0):
    input_buffer = file_to_bytes(input_file)
    
    pfat_buffer = get_ami_pfat(input_buffer)
    
    file_path = ''
    all_blocks_dict = {}
    
    extract_name = os.path.basename(extract_path).rstrip(extract_suffix())
    
    make_dirs(extract_path, delete=True)
    
    block_all,block_off,file_count = parse_pfat_hdr(pfat_buffer, padding)

    for block in block_all:
        file_desc,file_name,_,_,_,file_index,block_index,block_count = block
        
        if block_index == 0:
            printer(file_desc, padding + 4)
            
            file_path = os.path.join(extract_path, get_file_name(file_index + 1, file_name))
            
            all_blocks_dict[file_index] = b''
        
        block_status = f'{block_index + 1}/{block_count}'
        
        bg_hdr = get_struct(pfat_buffer, block_off, IntelBiosGuardHeader)
        
        printer(f'Intel BIOS Guard {block_status} Header:\n', padding + 8)
        
        bg_hdr.struct_print(padding + 12)
        
        bg_script_bgn = block_off + PFAT_BLK_HDR_LEN
        bg_script_end = bg_script_bgn + bg_hdr.ScriptSize
        bg_script_bin = pfat_buffer[bg_script_bgn:bg_script_end]
        
        bg_data_bgn = bg_script_end
        bg_data_end = bg_data_bgn + bg_hdr.DataSize
        bg_data_bin = pfat_buffer[bg_data_bgn:bg_data_end]

        block_off = bg_data_end # Assume next block starts at data end

        is_sfam,_,_,_,_ = bg_hdr.get_flags() # SFAM, ProtectEC, GFXMitDis, FTU, Reserved
        
        if is_sfam:
            bg_sig_bgn = bg_data_end
            bg_sig_end = bg_sig_bgn + PFAT_BLK_S2K_LEN
            bg_sig_bin = pfat_buffer[bg_sig_bgn:bg_sig_end]
            
            if len(bg_sig_bin) == PFAT_BLK_S2K_LEN:
                bg_sig = get_struct(bg_sig_bin, 0x0, IntelBiosGuardSignature2k)
                
                printer(f'Intel BIOS Guard {block_status} Signature:\n', padding + 8)
                
                bg_sig.struct_print(padding + 12)

            block_off = bg_sig_end # Adjust next block to start at data + signature end
        
        printer(f'Intel BIOS Guard {block_status} Script:\n', padding + 8)
        
        _ = parse_bg_script(bg_script_bin, padding + 12)
        
        with open(file_path, 'ab') as out_dat:
            out_dat.write(bg_data_bin)
        
        all_blocks_dict[file_index] += bg_data_bin
    
    pfat_oob_data = pfat_buffer[block_off:] # Store out-of-bounds data after the end of PFAT files
    
    pfat_oob_name = get_file_name(file_count + 1, f'{extract_name}_OOB.bin')
    
    pfat_oob_path = os.path.join(extract_path, pfat_oob_name)
    
    with open(pfat_oob_path, 'wb') as out_oob:
        out_oob.write(pfat_oob_data)
    
    if is_ami_pfat(pfat_oob_data):
        parse_pfat_file(pfat_oob_data, get_extract_path(pfat_oob_path), padding)
    
    in_all_data = b''.join([block[1] for block in sorted(all_blocks_dict.items())])
    
    in_all_name = get_file_name(0, f'{extract_name}_ALL.bin')
    
    in_all_path = os.path.join(extract_path, in_all_name)
    
    with open(in_all_path, 'wb') as out_all:
        out_all.write(in_all_data + pfat_oob_data)
    
    return 0

PFAT_AMI_HDR_LEN = ctypes.sizeof(AmiBiosGuardHeader)
PFAT_BLK_HDR_LEN = ctypes.sizeof(IntelBiosGuardHeader)
PFAT_BLK_S2K_LEN = ctypes.sizeof(IntelBiosGuardSignature2k)

if __name__ == '__main__':
    BIOSUtility(TITLE, is_ami_pfat, parse_pfat_file).run_utility()
