#!/usr/bin/env python3
#coding=utf-8

"""
AMI UCP Extract
AMI UCP Update Extractor
Copyright (C) 2021-2022 Plato Mavropoulos
"""

TITLE = 'AMI UCP Update Extractor v2.0_a20'

import os
import re
import sys
import struct
import ctypes
import contextlib

# Stop __pycache__ generation
sys.dont_write_bytecode = True

from common.checksums import get_chk_16
from common.comp_efi import efi_decompress, is_efi_compressed
from common.path_ops import agnostic_path, make_dirs, safe_name, safe_path, get_extract_path
from common.patterns import PAT_AMI_UCP, PAT_INTEL_ENG
from common.struct_ops import char, get_struct, uint8_t, uint16_t, uint32_t
from common.system import printer
from common.templates import BIOSUtility
from common.text_ops import file_to_bytes, to_string

from AMI_PFAT_Extract import is_ami_pfat, parse_pfat_file
from Insyde_IFD_Extract import insyde_ifd_extract, is_insyde_ifd

class UafHeader(ctypes.LittleEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('ModuleTag',       char*4),        # 0x00
        ('ModuleSize',      uint32_t),      # 0x04
        ('Checksum',        uint16_t),      # 0x08
        ('Unknown0',        uint8_t),       # 0x0A
        ('Unknown1',        uint8_t),       # 0x0A
        ('Reserved',        uint8_t*4),     # 0x0C
        # 0x10
    ]
    
    def _get_reserved(self):
        res_bytes = bytes(self.Reserved)
        
        res_hex = f'0x{int.from_bytes(res_bytes, "big"):0{0x4 * 2}X}'
        
        res_str = re.sub(r'[\n\t\r\x00 ]', '', res_bytes.decode('utf-8','ignore'))
        
        res_txt = f' ({res_str})' if len(res_str) else ''
        
        return f'{res_hex}{res_txt}'
    
    def struct_print(self, p):
        printer(['Tag          :', self.ModuleTag.decode('utf-8')], p, False)
        printer(['Size         :', f'0x{self.ModuleSize:X}'], p, False)
        printer(['Checksum     :', f'0x{self.Checksum:04X}'], p, False)
        printer(['Unknown 0    :', f'0x{self.Unknown0:02X}'], p, False)
        printer(['Unknown 1    :', f'0x{self.Unknown1:02X}'], p, False)
        printer(['Reserved     :', self._get_reserved()], p, False)

class UafModule(ctypes.LittleEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('CompressSize',    uint32_t),      # 0x00
        ('OriginalSize',    uint32_t),      # 0x04
        # 0x08
    ]
    
    def struct_print(self, p, filename, description):
        printer(['Compress Size:', f'0x{self.CompressSize:X}'], p, False)
        printer(['Original Size:', f'0x{self.OriginalSize:X}'], p, False)
        printer(['Filename     :', filename], p, False)
        printer(['Description  :', description], p, False)

class UiiHeader(ctypes.LittleEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('UIISize',         uint16_t),      # 0x00
        ('Checksum',        uint16_t),      # 0x02
        ('UtilityVersion',  uint32_t),      # 0x04 AFU|BGT (Unknown, Signed)
        ('InfoSize',        uint16_t),      # 0x08
        ('SupportBIOS',     uint8_t),       # 0x0A
        ('SupportOS',       uint8_t),       # 0x0B
        ('DataBusWidth',    uint8_t),       # 0x0C
        ('ProgramType',     uint8_t),       # 0x0D
        ('ProgramMode',     uint8_t),       # 0x0E
        ('SourceSafeRel',   uint8_t),       # 0x0F
        # 0x10
    ]
    
    SBI = {1: 'ALL', 2: 'AMIBIOS8', 3: 'UEFI', 4: 'AMIBIOS8/UEFI'}
    SOS = {1: 'DOS', 2: 'EFI', 3: 'Windows', 4: 'Linux', 5: 'FreeBSD', 6: 'MacOS', 128: 'Multi-Platform'}
    DBW = {1: '16b', 2: '16/32b', 3: '32b', 4: '64b'}
    PTP = {1: 'Executable', 2: 'Library', 3: 'Driver'}
    PMD = {1: 'API', 2: 'Console', 3: 'GUI', 4: 'Console/GUI'}
    
    def struct_print(self, p, description):
        SupportBIOS = self.SBI.get(self.SupportBIOS, f'Unknown ({self.SupportBIOS})')
        SupportOS = self.SOS.get(self.SupportOS, f'Unknown ({self.SupportOS})')
        DataBusWidth = self.DBW.get(self.DataBusWidth, f'Unknown ({self.DataBusWidth})')
        ProgramType = self.PTP.get(self.ProgramType, f'Unknown ({self.ProgramType})')
        ProgramMode = self.PMD.get(self.ProgramMode, f'Unknown ({self.ProgramMode})')
        
        printer(['UII Size      :', f'0x{self.UIISize:X}'], p, False)
        printer(['Checksum      :', f'0x{self.Checksum:04X}'], p, False)
        printer(['Tool Version  :', f'0x{self.UtilityVersion:08X}'], p, False)
        printer(['Info Size     :', f'0x{self.InfoSize:X}'], p, False)
        printer(['Supported BIOS:', SupportBIOS], p, False)
        printer(['Supported OS  :', SupportOS], p, False)
        printer(['Data Bus Width:', DataBusWidth], p, False)
        printer(['Program Type  :', ProgramType], p, False)
        printer(['Program Mode  :', ProgramMode], p, False)
        printer(['SourceSafe Tag:', f'{self.SourceSafeRel:02d}'], p, False)
        printer(['Description   :', description], p, False)

class DisHeader(ctypes.LittleEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('PasswordSize',    uint16_t),      # 0x00
        ('EntryCount',      uint16_t),      # 0x02
        ('Password',        char*12),       # 0x04
        # 0x10
    ]
    
    def struct_print(self, p):
        printer(['Password Size:', f'0x{self.PasswordSize:X}'], p, False)
        printer(['Entry Count  :', self.EntryCount], p, False)
        printer(['Password     :', self.Password.decode('utf-8')], p, False)

class DisModule(ctypes.LittleEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('EnabledDisabled', uint8_t),       # 0x00
        ('ShownHidden',     uint8_t),       # 0x01
        ('Command',         char*32),       # 0x02
        ('Description',     char*256),      # 0x22
        # 0x122
    ]
    
    ENDIS = {0: 'Disabled', 1: 'Enabled'}
    SHOWN = {0: 'Hidden', 1: 'Shown', 2: 'Shown Only'}
    
    def struct_print(self, p):
        EnabledDisabled = self.ENDIS.get(self.EnabledDisabled, f'Unknown ({self.EnabledDisabled})')
        ShownHidden = self.SHOWN.get(self.ShownHidden, f'Unknown ({self.ShownHidden})')
        
        printer(['State      :', EnabledDisabled], p, False)
        printer(['Display    :', ShownHidden], p, False)
        printer(['Command    :', self.Command.decode('utf-8').strip()], p, False)
        printer(['Description:', self.Description.decode('utf-8').strip()], p, False)

# Validate UCP Module Checksum-16
def chk16_validate(data, tag, padd=0):
    if get_chk_16(data) != 0:
        printer(f'Error: Invalid UCP Module {tag} Checksum!', padd, pause=True)
    else:
        printer(f'Checksum of UCP Module {tag} is valid!', padd)

# Check if input is AMI UCP image
def is_ami_ucp(in_file):
    buffer = file_to_bytes(in_file)
    
    return bool(get_ami_ucp(buffer)[0] is not None)

# Get all input file AMI UCP patterns
def get_ami_ucp(in_file):
    buffer = file_to_bytes(in_file)
    
    uaf_len_max = 0x0 # Length of largest detected @UAF|@HPU
    uaf_buf_bin = None # Buffer of largest detected @UAF|@HPU
    uaf_buf_tag = '@UAF' # Tag of largest detected @UAF|@HPU
    
    for uaf in PAT_AMI_UCP.finditer(buffer):
        uaf_len_cur = int.from_bytes(buffer[uaf.start() + 0x4:uaf.start() + 0x8], 'little')
        
        if uaf_len_cur > uaf_len_max:
            uaf_len_max = uaf_len_cur
            uaf_hdr_off = uaf.start()
            uaf_buf_bin = buffer[uaf_hdr_off:uaf_hdr_off + uaf_len_max]
            uaf_buf_tag = uaf.group(0)[:4].decode('utf-8','ignore')
    
    return uaf_buf_bin, uaf_buf_tag

# Get list of @UAF|@HPU Modules
def get_uaf_mod(buffer, uaf_off=0x0):
    uaf_all = [] # Initialize list of all @UAF|@HPU Modules
    
    while buffer[uaf_off] == 0x40: # ASCII of @ is 0x40
        uaf_hdr = get_struct(buffer, uaf_off, UafHeader) # Parse @UAF|@HPU Module Structure
        
        uaf_tag = uaf_hdr.ModuleTag.decode('utf-8') # Get unique @UAF|@HPU Module Tag
        
        uaf_all.append([uaf_tag, uaf_off, uaf_hdr]) # Store @UAF|@HPU Module Info
        
        uaf_off += uaf_hdr.ModuleSize # Adjust to next @UAF|@HPU Module offset
        
        if uaf_off >= len(buffer):
            break # Stop parsing at EOF
    
    # Check if @UAF|@HPU Module @NAL exists and place it first
    # Parsing @NAL first allows naming all @UAF|@HPU Modules
    for mod_idx,mod_val in enumerate(uaf_all):
        if mod_val[0] == '@NAL':
            uaf_all.insert(1, uaf_all.pop(mod_idx)) # After UII for visual purposes
            
            break # @NAL found, skip the rest
    
    return uaf_all

# Parse & Extract AMI UCP structures
def ucp_extract(in_file, extract_path, padding=0, checksum=False):
    input_buffer = file_to_bytes(in_file)
    
    nal_dict = {} # Initialize @NAL Dictionary per UCP
    
    printer('Utility Configuration Program', padding)
    
    make_dirs(extract_path, delete=True)
    
    # Get best AMI UCP Pattern match based on @UAF|@HPU Size
    ucp_buffer,ucp_tag = get_ami_ucp(input_buffer)
    
    uaf_hdr = get_struct(ucp_buffer, 0, UafHeader) # Parse @UAF|@HPU Header Structure
    
    printer(f'Utility Auxiliary File > {ucp_tag}:\n', padding + 4)
    
    uaf_hdr.struct_print(padding + 8)
    
    fake = struct.pack('<II', len(ucp_buffer), len(ucp_buffer)) # Generate UafModule Structure
    
    uaf_mod = get_struct(fake, 0x0, UafModule) # Parse @UAF|@HPU Module EFI Structure
    
    uaf_name = UAF_TAG_DICT[ucp_tag][0] # Get @UAF|@HPU Module Filename
    uaf_desc = UAF_TAG_DICT[ucp_tag][1] # Get @UAF|@HPU Module Description
    
    uaf_mod.struct_print(padding + 8, uaf_name, uaf_desc) # Print @UAF|@HPU Module EFI Info
    
    if checksum:
        chk16_validate(ucp_buffer, ucp_tag, padding + 8)
    
    uaf_all = get_uaf_mod(ucp_buffer, UAF_HDR_LEN)
    
    for mod_info in uaf_all:
        nal_dict = uaf_extract(ucp_buffer, extract_path, mod_info, padding + 8, checksum, nal_dict)

# Parse & Extract AMI UCP > @UAF|@HPU Module/Section
def uaf_extract(buffer, extract_path, mod_info, padding=0, checksum=False, nal_dict=None):
    if nal_dict is None:
        nal_dict = {}
    
    uaf_tag,uaf_off,uaf_hdr = mod_info
    
    uaf_data_all = buffer[uaf_off:uaf_off + uaf_hdr.ModuleSize] # @UAF|@HPU Module Entire Data
    
    uaf_data_mod = uaf_data_all[UAF_HDR_LEN:] # @UAF|@HPU Module EFI Data
    
    uaf_data_raw = uaf_data_mod[UAF_MOD_LEN:] # @UAF|@HPU Module Raw Data
    
    printer(f'Utility Auxiliary File > {uaf_tag}:\n', padding)
    
    uaf_hdr.struct_print(padding + 4) # Print @UAF|@HPU Module Info
    
    uaf_mod = get_struct(buffer, uaf_off + UAF_HDR_LEN, UafModule) # Parse UAF Module EFI Structure
    
    is_comp = uaf_mod.CompressSize != uaf_mod.OriginalSize # Detect @UAF|@HPU Module EFI Compression
    
    if uaf_tag in nal_dict:
        uaf_name = nal_dict[uaf_tag][1] # Always prefer @NAL naming first
    elif uaf_tag in UAF_TAG_DICT:
        uaf_name = UAF_TAG_DICT[uaf_tag][0] # Otherwise use built-in naming
    elif uaf_tag == '@ROM':
        uaf_name = 'BIOS.bin' # BIOS/PFAT Firmware (w/o Signature)
    elif uaf_tag.startswith('@R0'):
        uaf_name = f'BIOS_0{uaf_tag[3:]}.bin' # BIOS/PFAT Firmware
    elif uaf_tag.startswith('@S0'):
        uaf_name = f'BIOS_0{uaf_tag[3:]}.sig' # BIOS/PFAT Signature
    elif uaf_tag.startswith('@DR'):
        uaf_name = f'DROM_0{uaf_tag[3:]}.bin' # Thunderbolt Retimer Firmware
    elif uaf_tag.startswith('@DS'):
        uaf_name = f'DROM_0{uaf_tag[3:]}.sig' # Thunderbolt Retimer Signature
    elif uaf_tag.startswith('@EC'):
        uaf_name = f'EC_0{uaf_tag[3:]}.bin' # Embedded Controller Firmware
    elif uaf_tag.startswith('@ME'):
        uaf_name = f'ME_0{uaf_tag[3:]}.bin' # Management Engine Firmware
    else:
        uaf_name = uaf_tag # Could not name the @UAF|@HPU Module, use Tag instead
    
    uaf_fext = '' if uaf_name != uaf_tag else '.bin'
    
    uaf_fdesc = UAF_TAG_DICT[uaf_tag][1] if uaf_tag in UAF_TAG_DICT else uaf_name
    
    uaf_mod.struct_print(padding + 4, uaf_name + uaf_fext, uaf_fdesc) # Print @UAF|@HPU Module EFI Info
    
    # Check if unknown @UAF|@HPU Module Tag is present in @NAL but not in built-in dictionary
    if uaf_tag in nal_dict and uaf_tag not in UAF_TAG_DICT and not uaf_tag.startswith(('@ROM','@R0','@S0','@DR','@DS')):
        printer(f'Note: Detected new AMI UCP Module {uaf_tag} ({nal_dict[uaf_tag][1]}) in @NAL!', padding + 4, pause=True)
    
    # Generate @UAF|@HPU Module File name, depending on whether decompression will be required
    uaf_sname = safe_name(uaf_name + ('.temp' if is_comp else uaf_fext))
    if uaf_tag in nal_dict:
        uaf_npath = safe_path(extract_path, nal_dict[uaf_tag][0])
        make_dirs(uaf_npath, exist_ok=True)
        uaf_fname = safe_path(uaf_npath, uaf_sname)
    else:
        uaf_fname = safe_path(extract_path, uaf_sname)
    
    if checksum:
        chk16_validate(uaf_data_all, uaf_tag, padding + 4)
    
    # Parse Utility Identification Information @UAF|@HPU Module (@UII)
    if uaf_tag == '@UII':
        info_hdr = get_struct(uaf_data_raw, 0, UiiHeader) # Parse @UII Module Raw Structure
        
        info_data = uaf_data_raw[max(UII_HDR_LEN,info_hdr.InfoSize):info_hdr.UIISize] # @UII Module Info Data
        
        # Get @UII Module Info/Description text field
        info_desc = info_data.decode('utf-8','ignore').strip('\x00 ')
        
        printer('Utility Identification Information:\n', padding + 4)
        
        info_hdr.struct_print(padding + 8, info_desc) # Print @UII Module Info
        
        if checksum:
            chk16_validate(uaf_data_raw, '@UII > Info', padding + 8)
        
        # Store/Save @UII Module Info in file
        with open(uaf_fname[:-4] + '.txt', 'a', encoding='utf-8') as uii_out:
            with contextlib.redirect_stdout(uii_out):
                info_hdr.struct_print(0, info_desc) # Store @UII Module Info
    
    # Adjust @UAF|@HPU Module Raw Data for extraction
    if is_comp:
        # Some Compressed @UAF|@HPU Module EFI data lack necessary EOF padding
        if uaf_mod.CompressSize > len(uaf_data_raw):
            comp_padd = b'\x00' * (uaf_mod.CompressSize - len(uaf_data_raw))
            uaf_data_raw = uaf_data_mod[:UAF_MOD_LEN] + uaf_data_raw + comp_padd # Add missing padding for decompression
        else:
            uaf_data_raw = uaf_data_mod[:UAF_MOD_LEN] + uaf_data_raw # Add the EFI/Tiano Compression info before Raw Data
    else:
        uaf_data_raw = uaf_data_raw[:uaf_mod.OriginalSize] # No compression, extend to end of Original @UAF|@HPU Module size
    
    # Store/Save @UAF|@HPU Module file
    if uaf_tag != '@UII': # Skip @UII binary, already parsed
        with open(uaf_fname, 'wb') as uaf_out:
            uaf_out.write(uaf_data_raw)
    
    # @UAF|@HPU Module EFI/Tiano Decompression
    if is_comp and is_efi_compressed(uaf_data_raw, False):
        dec_fname = uaf_fname.replace('.temp', uaf_fext) # Decompressed @UAF|@HPU Module file path
        
        if efi_decompress(uaf_fname, dec_fname, padding + 4) == 0:
            with open(dec_fname, 'rb') as dec:
                uaf_data_raw = dec.read() # Read back the @UAF|@HPU Module decompressed Raw data
            
            os.remove(uaf_fname) # Successful decompression, delete compressed @UAF|@HPU Module file
            
            uaf_fname = dec_fname # Adjust @UAF|@HPU Module file path to the decompressed one
    
    # Process and Print known text only @UAF|@HPU Modules (after EFI/Tiano Decompression)
    if uaf_tag in UAF_TAG_DICT and UAF_TAG_DICT[uaf_tag][2] == 'Text':
        printer(f'{UAF_TAG_DICT[uaf_tag][1]}:', padding + 4)
        printer(uaf_data_raw.decode('utf-8','ignore'), padding + 8)
    
    # Parse Default Command Status @UAF|@HPU Module (@DIS)
    if len(uaf_data_raw) and uaf_tag == '@DIS':
        dis_hdr = get_struct(uaf_data_raw, 0x0, DisHeader) # Parse @DIS Module Raw Header Structure
        
        printer('Default Command Status Header:\n', padding + 4)
        
        dis_hdr.struct_print(padding + 8) # Print @DIS Module Raw Header Info
        
        # Store/Save @DIS Module Header Info in file
        with open(uaf_fname[:-3] + 'txt', 'a', encoding='utf-8') as dis:
            with contextlib.redirect_stdout(dis):
                dis_hdr.struct_print(0) # Store @DIS Module Header Info
        
        dis_data = uaf_data_raw[DIS_HDR_LEN:] # @DIS Module Entries Data
        
        # Parse all @DIS Module Entries
        for mod_idx in range(dis_hdr.EntryCount):
            dis_mod = get_struct(dis_data, mod_idx * DIS_MOD_LEN, DisModule) # Parse @DIS Module Raw Entry Structure
            
            printer(f'Default Command Status Entry {mod_idx + 1:02d}/{dis_hdr.EntryCount:02d}:\n', padding + 8)
            
            dis_mod.struct_print(padding + 12) # Print @DIS Module Raw Entry Info
            
            # Store/Save @DIS Module Entry Info in file
            with open(uaf_fname[:-3] + 'txt', 'a', encoding='utf-8') as dis:
                with contextlib.redirect_stdout(dis):
                    printer()
                    dis_mod.struct_print(4) # Store @DIS Module Entry Info
        
        os.remove(uaf_fname) # Delete @DIS Module binary, info exported as text
    
    # Parse Name List @UAF|@HPU Module (@NAL)
    if len(uaf_data_raw) >= 5 and (uaf_tag,uaf_data_raw[0],uaf_data_raw[4]) == ('@NAL',0x40,0x3A):
        nal_info = uaf_data_raw.decode('utf-8','ignore').replace('\r','').strip().split('\n')
        
        printer('AMI UCP Module Name List:\n', padding + 4)
        
        # Parse all @NAL Module Entries
        for info in nal_info:
            info_tag,info_value = info.split(':',1)
            
            printer(f'{info_tag} : {info_value}', padding + 8, False) # Print @NAL Module Tag-Path Info
            
            info_part = agnostic_path(info_value).parts # Split OS agnostic path in parts
            info_path = to_string(info_part[1:-1], os.sep) # Get path without drive/root or file
            info_name = info_part[-1] # Get file from last path part
            
            nal_dict[info_tag] = (info_path,info_name) # Assign a file path & name to each Tag
    
    # Parse Insyde BIOS @UAF|@HPU Module (@INS)
    if uaf_tag == '@INS' and is_insyde_ifd(uaf_fname):
        ins_dir = os.path.join(extract_path, safe_name(f'{uaf_tag}_nested-IFD')) # Generate extraction directory
        
        if insyde_ifd_extract(uaf_fname, get_extract_path(ins_dir), padding + 4) == 0:
            os.remove(uaf_fname) # Delete raw nested Insyde IFD image after successful extraction
    
    # Detect & Unpack AMI BIOS Guard (PFAT) BIOS image
    if is_ami_pfat(uaf_data_raw):
        pfat_dir = os.path.join(extract_path, safe_name(uaf_name))
        
        parse_pfat_file(uaf_data_raw, get_extract_path(pfat_dir), padding + 4)
        
        os.remove(uaf_fname) # Delete raw PFAT BIOS image after successful extraction
    
    # Detect Intel Engine firmware image and show ME Analyzer advice
    if uaf_tag.startswith('@ME') and PAT_INTEL_ENG.search(uaf_data_raw):
        printer('Intel Management Engine (ME) Firmware:\n', padding + 4)
        printer('Use "ME Analyzer" from https://github.com/platomav/MEAnalyzer', padding + 8, False)
    
    # Parse Nested AMI UCP image
    if is_ami_ucp(uaf_data_raw):
        uaf_dir = os.path.join(extract_path, safe_name(f'{uaf_tag}_nested-UCP')) # Generate extraction directory
        
        ucp_extract(uaf_data_raw, get_extract_path(uaf_dir), padding + 4, checksum) # Call recursively
        
        os.remove(uaf_fname) # Delete raw nested AMI UCP image after successful extraction
    
    return nal_dict

# Get common ctypes Structure Sizes
UAF_HDR_LEN = ctypes.sizeof(UafHeader)
UAF_MOD_LEN = ctypes.sizeof(UafModule)
DIS_HDR_LEN = ctypes.sizeof(DisHeader)
DIS_MOD_LEN = ctypes.sizeof(DisModule)
UII_HDR_LEN = ctypes.sizeof(UiiHeader)

# AMI UCP Tag Dictionary
UAF_TAG_DICT = {
    '@3FI' : ['HpBiosUpdate32.efi', 'HpBiosUpdate32.efi', ''],
    '@3S2' : ['HpBiosUpdate32.s12', 'HpBiosUpdate32.s12', ''],
    '@3S4' : ['HpBiosUpdate32.s14', 'HpBiosUpdate32.s14', ''],
    '@3S9' : ['HpBiosUpdate32.s09', 'HpBiosUpdate32.s09', ''],
    '@3SG' : ['HpBiosUpdate32.sig', 'HpBiosUpdate32.sig', ''],
    '@AMI' : ['UCP_Nested.bin', 'Nested AMI UCP', ''],
    '@B12' : ['BiosMgmt.s12', 'BiosMgmt.s12', ''],
    '@B14' : ['BiosMgmt.s14', 'BiosMgmt.s14', ''],
    '@B32' : ['BiosMgmt32.s12', 'BiosMgmt32.s12', ''],
    '@B34' : ['BiosMgmt32.s14', 'BiosMgmt32.s14', ''],
    '@B39' : ['BiosMgmt32.s09', 'BiosMgmt32.s09', ''],
    '@B3E' : ['BiosMgmt32.efi', 'BiosMgmt32.efi', ''],
    '@BM9' : ['BiosMgmt.s09', 'BiosMgmt.s09', ''],
    '@BME' : ['BiosMgmt.efi', 'BiosMgmt.efi', ''],
    '@CKV' : ['Check_Version.txt', 'Check Version', 'Text'],
    '@CMD' : ['AFU_Command.txt', 'AMI AFU Command', 'Text'],
    '@CML' : ['CMOSD4.txt', 'CMOS Item Number-Value (MSI)', 'Text'],
    '@CMS' : ['CMOSD4.exe', 'Get or Set CMOS Item (MSI)', ''],
    '@CPM' : ['AC_Message.txt', 'Confirm Power Message', ''],
    '@DCT' : ['DevCon32.exe', 'Device Console WIN32', ''],
    '@DCX' : ['DevCon64.exe', 'Device Console WIN64', ''],
    '@DFE' : ['HpDevFwUpdate.efi', 'HpDevFwUpdate.efi', ''],
    '@DFS' : ['HpDevFwUpdate.s12', 'HpDevFwUpdate.s12', ''],
    '@DIS' : ['Command_Status.bin', 'Default Command Status', ''],
    '@ENB' : ['ENBG64.exe', 'ENBG64.exe', ''],
    '@HPU' : ['UCP_Main.bin', 'Utility Auxiliary File (HP)', ''],
    '@INS' : ['Insyde_Nested.bin', 'Nested Insyde SFX', ''],
    '@M32' : ['HpBiosMgmt32.s12', 'HpBiosMgmt32.s12', ''],
    '@M34' : ['HpBiosMgmt32.s14', 'HpBiosMgmt32.s14', ''],
    '@M39' : ['HpBiosMgmt32.s09', 'HpBiosMgmt32.s09', ''],
    '@M3I' : ['HpBiosMgmt32.efi', 'HpBiosMgmt32.efi', ''],
    '@MEC' : ['FWUpdLcl.txt', 'Intel FWUpdLcl Command', 'Text'],
    '@MED' : ['FWUpdLcl_DOS.exe', 'Intel FWUpdLcl DOS', ''],
    '@MET' : ['FWUpdLcl_WIN32.exe', 'Intel FWUpdLcl WIN32', ''],
    '@MFI' : ['HpBiosMgmt.efi', 'HpBiosMgmt.efi', ''],
    '@MS2' : ['HpBiosMgmt.s12', 'HpBiosMgmt.s12', ''],
    '@MS4' : ['HpBiosMgmt.s14', 'HpBiosMgmt.s14', ''],
    '@MS9' : ['HpBiosMgmt.s09', 'HpBiosMgmt.s09', ''],
    '@NAL' : ['UCP_List.txt', 'AMI UCP Module Name List', ''],
    '@OKM' : ['OK_Message.txt', 'OK Message', ''],
    '@PFC' : ['BGT_Command.txt', 'AMI BGT Command', 'Text'],
    '@R3I' : ['CryptRSA32.efi', 'CryptRSA32.efi', ''],
    '@RFI' : ['CryptRSA.efi', 'CryptRSA.efi', ''],
    '@UAF' : ['UCP_Main.bin', 'Utility Auxiliary File (AMI)', ''],
    '@UFI' : ['HpBiosUpdate.efi', 'HpBiosUpdate.efi', ''],
    '@UII' : ['UCP_Info.txt', 'Utility Identification Information', ''],
    '@US2' : ['HpBiosUpdate.s12', 'HpBiosUpdate.s12', ''],
    '@US4' : ['HpBiosUpdate.s14', 'HpBiosUpdate.s14', ''],
    '@US9' : ['HpBiosUpdate.s09', 'HpBiosUpdate.s09', ''],
    '@USG' : ['HpBiosUpdate.sig', 'HpBiosUpdate.sig', ''],
    '@VER' : ['OEM_Version.txt', 'OEM Version', 'Text'],
    '@VXD' : ['amifldrv.vxd', 'amifldrv.vxd', ''],
    '@W32' : ['amifldrv32.sys', 'amifldrv32.sys', ''],
    '@W64' : ['amifldrv64.sys', 'amifldrv64.sys', ''],
    }

if __name__ == '__main__':
    utility = BIOSUtility(TITLE, is_ami_ucp, ucp_extract)
    utility.parse_argument('-c', '--checksum', help='verify AMI UCP Checksums (slow)', action='store_true')
    utility.run_utility()
