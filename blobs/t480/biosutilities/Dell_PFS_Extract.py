#!/usr/bin/env python3
#coding=utf-8

"""
Dell PFS Extract
Dell PFS Update Extractor
Copyright (C) 2018-2022 Plato Mavropoulos
"""

TITLE = 'Dell PFS Update Extractor v6.0_a16'

import os
import io
import sys
import lzma
import zlib
import ctypes
import contextlib

# Skip __pycache__ generation
sys.dont_write_bytecode = True

from common.checksums import get_chk_8_xor
from common.comp_szip import is_szip_supported, szip_decompress
from common.num_ops import get_ordinal
from common.path_ops import del_dirs, get_path_files, make_dirs, path_name, path_parent, path_stem, safe_name
from common.patterns import PAT_DELL_FTR, PAT_DELL_HDR, PAT_DELL_PKG
from common.struct_ops import char, get_struct, uint8_t, uint16_t, uint32_t, uint64_t
from common.system import printer
from common.templates import BIOSUtility
from common.text_ops import file_to_bytes

from AMI_PFAT_Extract import IntelBiosGuardHeader, IntelBiosGuardSignature2k, parse_bg_script

# Dell PFS Header Structure
class DellPfsHeader(ctypes.LittleEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('Tag',                 char*8),        # 0x00
        ('HeaderVersion',       uint32_t),      # 0x08
        ('PayloadSize',         uint32_t),      # 0x0C
        # 0x10
    ]
    
    def struct_print(self, p):
        printer(['Header Tag    :', self.Tag.decode('utf-8')], p, False)
        printer(['Header Version:', self.HeaderVersion], p, False)
        printer(['Payload Size  :', f'0x{self.PayloadSize:X}'], p, False)

# Dell PFS Footer Structure    
class DellPfsFooter(ctypes.LittleEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('PayloadSize',         uint32_t),      # 0x00
        ('Checksum',            uint32_t),      # 0x04 ~CRC32 w/ Vector 0
        ('Tag',                 char*8),        # 0x08
        # 0x10
    ]
    
    def struct_print(self, p):
        printer(['Payload Size    :', f'0x{self.PayloadSize:X}'], p, False)
        printer(['Payload Checksum:', f'0x{self.Checksum:08X}'], p, False)
        printer(['Footer Tag      :', self.Tag.decode('utf-8')], p, False)

# Dell PFS Entry Base Structure
class DellPfsEntryBase(ctypes.LittleEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('GUID',                uint32_t*4),    # 0x00 Little Endian
        ('HeaderVersion',       uint32_t),      # 0x10 1 or 2
        ('VersionType',         uint8_t*4),     # 0x14
        ('Version',             uint16_t*4),    # 0x18
        ('Reserved',            uint64_t),      # 0x20
        ('DataSize',            uint32_t),      # 0x28
        ('DataSigSize',         uint32_t),      # 0x2C
        ('DataMetSize',         uint32_t),      # 0x30
        ('DataMetSigSize',      uint32_t),      # 0x34
        # 0x38 (parent class, base)
    ]
    
    def struct_print(self, p):
        GUID = f'{int.from_bytes(self.GUID, "little"):0{0x10 * 2}X}'
        Unknown = f'{int.from_bytes(self.Unknown, "little"):0{len(self.Unknown) * 8}X}'
        Version = get_entry_ver(self.Version, self.VersionType)
        
        printer(['Entry GUID             :', GUID], p, False)
        printer(['Entry Version          :', self.HeaderVersion], p, False)
        printer(['Payload Version        :', Version], p, False)
        printer(['Reserved               :', f'0x{self.Reserved:X}'], p, False)
        printer(['Payload Data Size      :', f'0x{self.DataSize:X}'], p, False)
        printer(['Payload Signature Size :', f'0x{self.DataSigSize:X}'], p, False)
        printer(['Metadata Data Size     :', f'0x{self.DataMetSize:X}'], p, False)
        printer(['Metadata Signature Size:', f'0x{self.DataMetSigSize:X}'], p, False)
        printer(['Unknown                :', f'0x{Unknown}'], p, False)

# Dell PFS Entry Revision 1 Structure
class DellPfsEntryR1(DellPfsEntryBase):
    _pack_ = 1
    _fields_ = [
        ('Unknown',             uint32_t*4),    # 0x38
        # 0x48 (child class, R1)
    ]

# Dell PFS Entry Revision 2 Structure
class DellPfsEntryR2(DellPfsEntryBase):
    _pack_ = 1
    _fields_ = [
        ('Unknown',             uint32_t*8),    # 0x38
        # 0x58 (child class, R2)
    ]

# Dell PFS Information Header Structure
class DellPfsInfo(ctypes.LittleEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('HeaderVersion',       uint32_t),      # 0x00
        ('GUID',                uint32_t*4),    # 0x04 Little Endian
        # 0x14
    ]
    
    def struct_print(self, p):
        GUID = f'{int.from_bytes(self.GUID, "little"):0{0x10 * 2}X}'
        
        printer(['Info Version:', self.HeaderVersion], p, False)
        printer(['Entry GUID  :', GUID], p, False)

# Dell PFS FileName Header Structure
class DellPfsName(ctypes.LittleEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('Version',             uint16_t*4),    # 0x00
        ('VersionType',         uint8_t*4),     # 0x08
        ('CharacterCount',      uint16_t),      # 0x0C UTF-16 2-byte Characters
        # 0x0E
    ]
    
    def struct_print(self, p, name):
        Version = get_entry_ver(self.Version, self.VersionType)
        
        printer(['Payload Version:', Version], p, False)
        printer(['Character Count:', self.CharacterCount], p, False)
        printer(['Payload Name   :', name], p, False)

# Dell PFS Metadata Header Structure
class DellPfsMetadata(ctypes.LittleEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('ModelIDs',            char*501),      # 0x000
        ('FileName',            char*100),      # 0x1F5
        ('FileVersion',         char*33),       # 0x259
        ('Date',                char*33),       # 0x27A
        ('Brand',               char*80),       # 0x29B
        ('ModelFile',           char*80),       # 0x2EB
        ('ModelName',           char*100),      # 0x33B
        ('ModelVersion',        char*33),       # 0x39F
        # 0x3C0
    ]
    
    def struct_print(self, p):
        printer(['Model IDs    :', self.ModelIDs.decode('utf-8').strip(',END')], p, False)
        printer(['File Name    :', self.FileName.decode('utf-8')], p, False)
        printer(['File Version :', self.FileVersion.decode('utf-8')], p, False)
        printer(['Date         :', self.Date.decode('utf-8')], p, False)
        printer(['Brand        :', self.Brand.decode('utf-8')], p, False)
        printer(['Model File   :', self.ModelFile.decode('utf-8')], p, False)
        printer(['Model Name   :', self.ModelName.decode('utf-8')], p, False)
        printer(['Model Version:', self.ModelVersion.decode('utf-8')], p, False)

# Dell PFS BIOS Guard Metadata Structure
class DellPfsPfatMetadata(ctypes.LittleEndianStructure):
    _pack_ = 1
    _fields_ = [
        ('Address',             uint32_t),      # 0x00
        ('Unknown0',            uint32_t),      # 0x04
        ('Offset',              uint32_t),      # 0x08 Matches BG Script > I0
        ('DataSize',            uint32_t),      # 0x0C Matches BG Script > I2 & Header > Data Size
        ('Unknown1',            uint32_t),      # 0x10
        ('Unknown2',            uint32_t),      # 0x14
        ('Unknown3',            uint8_t),       # 0x18
        # 0x19
    ]
    
    def struct_print(self, p):
        printer(['Address  :', f'0x{self.Address:X}'], p, False)
        printer(['Unknown 0:', f'0x{self.Unknown0:X}'], p, False)
        printer(['Offset   :', f'0x{self.Offset:X}'], p, False)
        printer(['Length   :', f'0x{self.DataSize:X}'], p, False)
        printer(['Unknown 1:', f'0x{self.Unknown1:X}'], p, False)
        printer(['Unknown 2:', f'0x{self.Unknown2:X}'], p, False)
        printer(['Unknown 3:', f'0x{self.Unknown3:X}'], p, False)

# The Dell ThinOS PKG update images usually contain multiple sections.
# Each section starts with a 0x30 header, which begins with pattern 72135500.
# The section length is found at 0x10-0x14 and its (optional) MD5 hash at 0x20-0x30.
# Section data can be raw or LZMA2 (7zXZ) compressed. The latter contains the PFS update image.
def is_pfs_pkg(input_file):
    input_buffer = file_to_bytes(input_file)
    
    return PAT_DELL_PKG.search(input_buffer)

# The Dell PFS update images usually contain multiple sections. 
# Each section is zlib-compressed with header pattern ********++EEAA761BECBB20F1E651--789C,
# where ******** is the zlib stream size, ++ is the section type and -- the header Checksum XOR 8.
# The "Firmware" section has type AA and its files are stored in PFS format.
# The "Utility" section has type BB and its files are stored in PFS, BIN or 7z formats.
def is_pfs_hdr(input_file):
    input_buffer = file_to_bytes(input_file)
    
    return bool(PAT_DELL_HDR.search(input_buffer))

# Each section is followed by the footer pattern ********EEAAEE8F491BE8AE143790--,
# where ******** is the zlib stream size and ++ the footer Checksum XOR 8.
def is_pfs_ftr(input_file):
    input_buffer = file_to_bytes(input_file)
    
    return bool(PAT_DELL_FTR.search(input_buffer))

# Check if input is Dell PFS/PKG image
def is_dell_pfs(input_file):
    input_buffer = file_to_bytes(input_file)
    
    is_pkg = is_pfs_pkg(input_buffer)
    
    is_hdr = is_pfs_hdr(input_buffer)
    
    is_ftr = is_pfs_ftr(input_buffer)
    
    return bool(is_pkg or is_hdr and is_ftr)

# Parse & Extract Dell PFS Update image
def pfs_pkg_parse(input_file, extract_path, padding=0, structure=True, advanced=True):
    input_buffer = file_to_bytes(input_file)
    
    make_dirs(extract_path, delete=True)
    
    is_dell_pkg = is_pfs_pkg(input_buffer)
    
    if is_dell_pkg:
        pfs_results = thinos_pkg_extract(input_buffer, extract_path)
    else:
        pfs_results = {path_stem(input_file) if os.path.isfile(input_file) else 'Image': input_buffer}
    
    # Parse each Dell PFS image contained in the input file
    for pfs_index,(pfs_name,pfs_buffer) in enumerate(pfs_results.items(), start=1):
        # At ThinOS PKG packages, multiple PFS images may be included in separate model-named folders
        pfs_path = os.path.join(extract_path, f'{pfs_index} {pfs_name}') if is_dell_pkg else extract_path
        # Parse each PFS ZLIB section
        for zlib_offset in get_section_offsets(pfs_buffer):
            # Call the PFS ZLIB section parser function
            pfs_section_parse(pfs_buffer, zlib_offset, pfs_path, pfs_name, pfs_index, 1, False, padding, structure, advanced)

# Extract Dell ThinOS PKG 7zXZ
def thinos_pkg_extract(input_file, extract_path):
    input_buffer = file_to_bytes(input_file)
    
    # Initialize PFS results (Name: Buffer)
    pfs_results = {}
    
    # Search input image for ThinOS PKG 7zXZ header
    thinos_pkg_match = PAT_DELL_PKG.search(input_buffer)
    
    lzma_len_off = thinos_pkg_match.start() + 0x10
    lzma_len_int = int.from_bytes(input_buffer[lzma_len_off:lzma_len_off + 0x4], 'little')
    lzma_bin_off = thinos_pkg_match.end() - 0x5
    lzma_bin_dat = input_buffer[lzma_bin_off:lzma_bin_off + lzma_len_int]
    
    # Check if the compressed 7zXZ stream is complete
    if len(lzma_bin_dat) != lzma_len_int:
        return pfs_results
    
    working_path = os.path.join(extract_path, 'THINOS_PKG_TEMP')
    
    make_dirs(working_path, delete=True)
    
    pkg_tar_path = os.path.join(working_path, 'THINOS_PKG.TAR')
    
    with open(pkg_tar_path, 'wb') as pkg_payload:
        pkg_payload.write(lzma.decompress(lzma_bin_dat))
    
    if is_szip_supported(pkg_tar_path, 0, args=['-tTAR'], check=True, silent=True):
        if szip_decompress(pkg_tar_path, working_path, 'TAR', 0, args=['-tTAR'], check=True, silent=True) == 0:
            os.remove(pkg_tar_path)
        else:
            return pfs_results
    else:
        return pfs_results
    
    for pkg_file in get_path_files(working_path):
        if is_pfs_hdr(pkg_file):
            pfs_name = path_name(path_parent(pkg_file))
            pfs_results.update({pfs_name: file_to_bytes(pkg_file)})
    
    del_dirs(working_path)
    
    return pfs_results

# Get PFS ZLIB Section Offsets
def get_section_offsets(buffer):
    pfs_zlib_list = [] # Initialize PFS ZLIB offset list
    
    pfs_zlib_init = list(PAT_DELL_HDR.finditer(buffer))
    
    if not pfs_zlib_init:
        return pfs_zlib_list # No PFS ZLIB detected
    
    # Remove duplicate/nested PFS ZLIB offsets
    for zlib_c in pfs_zlib_init:
        is_duplicate = False # Initialize duplicate/nested PFS ZLIB offset
        
        for zlib_o in pfs_zlib_init:
            zlib_o_size = int.from_bytes(buffer[zlib_o.start() - 0x5:zlib_o.start() - 0x1], 'little')
            
            # If current PFS ZLIB offset is within another PFS ZLIB range (start-end), set as duplicate
            if zlib_o.start() < zlib_c.start() < zlib_o.start() + zlib_o_size:
                is_duplicate = True
        
        if not is_duplicate:
            pfs_zlib_list.append(zlib_c.start())
    
    return pfs_zlib_list

# Dell PFS ZLIB Section Parser
def pfs_section_parse(zlib_data, zlib_start, extract_path, pfs_name, pfs_index, pfs_count, is_rec, padding=0, structure=True, advanced=True):
    is_zlib_error = False # Initialize PFS ZLIB-related error state
    
    section_type = zlib_data[zlib_start - 0x1] # Byte before PFS ZLIB Section pattern is Section Type (e.g. AA, BB)
    section_name = {0xAA:'Firmware', 0xBB:'Utilities'}.get(section_type, f'Unknown ({section_type:02X})')
    
    # Show extraction complete message for each main PFS ZLIB Section
    printer(f'Extracting Dell PFS {pfs_index} > {pfs_name} > {section_name}', padding)
    
    # Set PFS ZLIB Section extraction sub-directory path
    section_path = os.path.join(extract_path, safe_name(section_name))
    
    # Create extraction sub-directory and delete old (if present, not in recursions)
    make_dirs(section_path, delete=(not is_rec), parents=True, exist_ok=True)
    
    # Store the compressed zlib stream start offset
    compressed_start = zlib_start + 0xB
    
    # Store the PFS ZLIB section header start offset
    header_start = zlib_start - 0x5
    
    # Store the PFS ZLIB section header contents (16 bytes)
    header_data = zlib_data[header_start:compressed_start]
    
    # Check if the PFS ZLIB section header Checksum XOR 8 is valid
    if get_chk_8_xor(header_data[:0xF]) != header_data[0xF]:
        printer('Error: Invalid Dell PFS ZLIB section Header Checksum!', padding)
        is_zlib_error = True
    
    # Store the compressed zlib stream size from the header contents
    compressed_size_hdr = int.from_bytes(header_data[:0x4], 'little')
    
    # Store the compressed zlib stream end offset
    compressed_end = compressed_start + compressed_size_hdr
    
    # Store the compressed zlib stream contents
    compressed_data = zlib_data[compressed_start:compressed_end]
    
    # Check if the compressed zlib stream is complete, based on header
    if len(compressed_data) != compressed_size_hdr:
        printer('Error: Incomplete Dell PFS ZLIB section data (Header)!', padding)
        is_zlib_error = True
    
    # Store the PFS ZLIB section footer contents (16 bytes)
    footer_data = zlib_data[compressed_end:compressed_end + 0x10]
    
    # Check if PFS ZLIB section footer was found in the section
    if not is_pfs_ftr(footer_data):
        printer('Error: This Dell PFS ZLIB section is corrupted!', padding)
        is_zlib_error = True
    
    # Check if the PFS ZLIB section footer Checksum XOR 8 is valid
    if get_chk_8_xor(footer_data[:0xF]) != footer_data[0xF]:
        printer('Error: Invalid Dell PFS ZLIB section Footer Checksum!', padding)
        is_zlib_error = True
    
    # Store the compressed zlib stream size from the footer contents
    compressed_size_ftr = int.from_bytes(footer_data[:0x4], 'little')
    
    # Check if the compressed zlib stream is complete, based on footer
    if compressed_size_ftr != compressed_size_hdr:
        printer('Error: Incomplete Dell PFS ZLIB section data (Footer)!', padding)
        is_zlib_error = True
    
    # Decompress PFS ZLIB section payload
    try:
        if is_zlib_error:
            raise Exception('ZLIB_ERROR') # ZLIB errors are critical
        section_data = zlib.decompress(compressed_data) # ZLIB decompression
    except Exception:
        section_data = zlib_data # Fallback to raw ZLIB data upon critical error
    
    # Call the PFS Extract function on the decompressed PFS ZLIB Section
    pfs_extract(section_data, pfs_index, pfs_name, pfs_count, section_path, padding, structure, advanced)

# Parse & Extract Dell PFS Volume
def pfs_extract(buffer, pfs_index, pfs_name, pfs_count, extract_path, padding=0, structure=True, advanced=True):    
    # Show PFS Volume indicator
    if structure:
        printer('PFS Volume:', padding)
    
    # Get PFS Header Structure values
    pfs_hdr = get_struct(buffer, 0, DellPfsHeader)
    
    # Validate that a PFS Header was parsed
    if pfs_hdr.Tag != b'PFS.HDR.':
        printer('Error: PFS Header could not be found!', padding + 4)
        
        return # Critical error, abort
    
    # Show PFS Header Structure info
    if structure:
        printer('PFS Header:\n', padding + 4)
        pfs_hdr.struct_print(padding + 8)
    
    # Validate that a known PFS Header Version was encountered
    chk_hdr_ver(pfs_hdr.HeaderVersion, 'PFS', padding + 8)
    
    # Get PFS Payload Data
    pfs_payload = buffer[PFS_HEAD_LEN:PFS_HEAD_LEN + pfs_hdr.PayloadSize]
    
    # Parse all PFS Payload Entries/Components
    entry_index = 1 # Index number of each PFS Entry
    entry_start = 0 # Increasing PFS Entry starting offset
    entries_all = [] # Storage for each PFS Entry details
    filename_info = [] # Buffer for FileName Information Entry Data
    signature_info = [] # Buffer for Signature Information Entry Data
    pfs_entry_struct,pfs_entry_size = get_pfs_entry(pfs_payload, entry_start) # Get PFS Entry Info
    while len(pfs_payload[entry_start:entry_start + pfs_entry_size]) == pfs_entry_size:
        # Analyze PFS Entry Structure and get relevant info
        _,entry_version,entry_guid,entry_data,entry_data_sig,entry_met,entry_met_sig,next_entry = \
        parse_pfs_entry(pfs_payload, entry_start, pfs_entry_size, pfs_entry_struct, 'PFS Entry', padding, structure)
        
        entry_type = 'OTHER' # Adjusted later if PFS Entry is Zlib, PFAT, PFS Info, Model Info
        
        # Get PFS Information from the PFS Entry with GUID E0717CE3A9BB25824B9F0DC8FD041960 or B033CB16EC9B45A14055F80E4D583FD3
        if entry_guid in ['E0717CE3A9BB25824B9F0DC8FD041960','B033CB16EC9B45A14055F80E4D583FD3']:
            filename_info = entry_data
            entry_type = 'NAME_INFO'
        
        # Get Model Information from the PFS Entry with GUID 6F1D619A22A6CB924FD4DA68233AE3FB
        elif entry_guid == '6F1D619A22A6CB924FD4DA68233AE3FB':
            entry_type = 'MODEL_INFO'
        
        # Get Signature Information from the PFS Entry with GUID D086AFEE3ADBAEA94D5CED583C880BB7
        elif entry_guid == 'D086AFEE3ADBAEA94D5CED583C880BB7':
            signature_info = entry_data
            entry_type = 'SIG_INFO'
            
        # Get Nested PFS from the PFS Entry with GUID 900FAE60437F3AB14055F456AC9FDA84
        elif entry_guid == '900FAE60437F3AB14055F456AC9FDA84':
            entry_type = 'NESTED_PFS' # Nested PFS are usually zlib-compressed so it might change to 'ZLIB' later
        
        # Store all relevant PFS Entry details
        entries_all.append([entry_index, entry_guid, entry_version, entry_type, entry_data, entry_data_sig, entry_met, entry_met_sig])
        
        entry_index += 1 # Increase PFS Entry Index number for user-friendly output and name duplicates
        entry_start = next_entry # Next PFS Entry starts after PFS Entry Metadata Signature
    
    # Parse all PFS Information Entries/Descriptors
    info_start = 0 # Increasing PFS Information Entry starting offset
    info_all = [] # Storage for each PFS Information Entry details
    while len(filename_info[info_start:info_start + PFS_INFO_LEN]) == PFS_INFO_LEN:
        # Get PFS Information Header Structure info
        entry_info_hdr = get_struct(filename_info, info_start, DellPfsInfo)
        
        # Show PFS Information Header Structure info
        if structure:
            printer('PFS Information Header:\n', padding + 4)
            entry_info_hdr.struct_print(padding + 8)
        
        # Validate that a known PFS Information Header Version was encountered
        if entry_info_hdr.HeaderVersion != 1:
            printer(f'Error: Unknown PFS Information Header Version {entry_info_hdr.HeaderVersion}!', padding + 8)
            break # Skip PFS Information Entries/Descriptors in case of unknown PFS Information Header Version
        
        # Get PFS Information Header GUID in Big Endian format to match each Info to the equivalent stored PFS Entry details
        entry_guid = f'{int.from_bytes(entry_info_hdr.GUID, "little"):0{0x10 * 2}X}'
        
        # Get PFS FileName Structure values
        entry_info_mod = get_struct(filename_info, info_start + PFS_INFO_LEN, DellPfsName)
        
        # The PFS FileName Structure is not complete by itself. The size of the last field (Entry Name) is determined from
        # CharacterCount multiplied by 2 due to usage of UTF-16 2-byte Characters. Any Entry Name leading and/or trailing
        # space/null characters are stripped and common Windows reserved/illegal filename characters are replaced
        name_start = info_start + PFS_INFO_LEN + PFS_NAME_LEN # PFS Entry's FileName start offset
        name_size = entry_info_mod.CharacterCount * 2 # PFS Entry's FileName buffer total size
        name_data = filename_info[name_start:name_start + name_size] # PFS Entry's FileName buffer
        entry_name = safe_name(name_data.decode('utf-16').strip()) # PFS Entry's FileName value
        
        # Show PFS FileName Structure info
        if structure:
            printer('PFS FileName Entry:\n', padding + 8)
            entry_info_mod.struct_print(padding + 12, entry_name)
        
        # Get PFS FileName Version string via "Version" and "VersionType" fields
        # PFS FileName Version string must be preferred over PFS Entry's Version
        entry_version = get_entry_ver(entry_info_mod.Version, entry_info_mod.VersionType)
        
        # Store all relevant PFS FileName details
        info_all.append([entry_guid, entry_name, entry_version])
        
        # The next PFS Information Header starts after the calculated FileName size
        # Two space/null characters seem to always exist after each FileName value
        info_start += (PFS_INFO_LEN + PFS_NAME_LEN + name_size + 0x2)
    
    # Parse Nested PFS Metadata when its PFS Information Entry is missing
    for index in range(len(entries_all)):
        if entries_all[index][3] == 'NESTED_PFS' and not filename_info:
            entry_guid = entries_all[index][1] # Nested PFS Entry GUID in Big Endian format
            entry_metadata = entries_all[index][6] # Use Metadata as PFS Information Entry
            
            # When PFS Information Entry exists, Nested PFS Metadata contains only Model IDs
            # When it's missing, the Metadata structure is large and contains equivalent info
            if len(entry_metadata) >= PFS_META_LEN:
                # Get Nested PFS Metadata Structure values
                entry_info = get_struct(entry_metadata, 0, DellPfsMetadata)
                
                # Show Nested PFS Metadata Structure info
                if structure:
                    printer('PFS Metadata Information:\n', padding + 4)
                    entry_info.struct_print(padding + 8)
                
                # As Nested PFS Entry Name, we'll use the actual PFS File Name
                # Replace common Windows reserved/illegal filename characters
                entry_name = safe_name(entry_info.FileName.decode('utf-8').strip('.exe'))
                
                # As Nested PFS Entry Version, we'll use the actual PFS File Version
                entry_version = entry_info.FileVersion.decode('utf-8')
                
                # Store all relevant Nested PFS Metadata/Information details
                info_all.append([entry_guid, entry_name, entry_version])
                
                # Re-set Nested PFS Entry Version from Metadata
                entries_all[index][2] = entry_version
    
    # Parse all PFS Signature Entries/Descriptors
    sign_start = 0 # Increasing PFS Signature Entry starting offset
    while len(signature_info[sign_start:sign_start + PFS_INFO_LEN]) == PFS_INFO_LEN:
        # Get PFS Information Header Structure info
        entry_info_hdr = get_struct(signature_info, sign_start, DellPfsInfo)
        
        # Show PFS Information Header Structure info
        if structure:
            printer('PFS Information Header:\n', padding + 4)
            entry_info_hdr.struct_print(padding + 8)
        
        # Validate that a known PFS Information Header Version was encountered
        if entry_info_hdr.HeaderVersion != 1:
            printer(f'Error: Unknown PFS Information Header Version {entry_info_hdr.HeaderVersion}!', padding + 8)
            break # Skip PFS Signature Entries/Descriptors in case of unknown Header Version
        
        # PFS Signature Entries/Descriptors have DellPfsInfo + DellPfsEntryR* + Sign Size [0x2] + Sign Data [Sig Size]
        pfs_entry_struct, pfs_entry_size = get_pfs_entry(signature_info, sign_start + PFS_INFO_LEN) # Get PFS Entry Info
        
        # Get PFS Entry Header Structure info
        entry_hdr = get_struct(signature_info, sign_start + PFS_INFO_LEN, pfs_entry_struct)
        
        # Show PFS Information Header Structure info
        if structure:
            printer('PFS Information Entry:\n', padding + 8)
            entry_hdr.struct_print(padding + 12)
        
        # Show PFS Signature Size & Data (after DellPfsEntryR*)
        sign_info_start = sign_start + PFS_INFO_LEN + pfs_entry_size
        sign_size = int.from_bytes(signature_info[sign_info_start:sign_info_start + 0x2], 'little')
        sign_data_raw = signature_info[sign_info_start + 0x2:sign_info_start + 0x2 + sign_size]
        sign_data_txt = f'{int.from_bytes(sign_data_raw, "little"):0{sign_size * 2}X}'
        
        if structure:
            printer('Signature Information:\n', padding + 8)
            printer(f'Signature Size: 0x{sign_size:X}', padding + 12, False)
            printer(f'Signature Data: {sign_data_txt[:32]} [...]', padding + 12, False)
        
        # The next PFS Signature Entry/Descriptor starts after the previous Signature Data
        sign_start += (PFS_INFO_LEN + pfs_entry_size + 0x2 + sign_size)
        
    # Parse each PFS Entry Data for special types (zlib or PFAT)
    for index in range(len(entries_all)):
        entry_data = entries_all[index][4] # Get PFS Entry Data
        entry_type = entries_all[index][3] # Get PFS Entry Type
        
        # Very small PFS Entry Data cannot be of special type
        if len(entry_data) < PFS_HEAD_LEN:
            continue
        
        # Check if PFS Entry contains zlib-compressed sub-PFS Volume
        pfs_zlib_offsets = get_section_offsets(entry_data)
        
        # Check if PFS Entry contains sub-PFS Volume with PFAT Payload
        is_pfat = False # Initial PFAT state for sub-PFS Entry
        _, pfat_entry_size = get_pfs_entry(entry_data, PFS_HEAD_LEN) # Get possible PFS PFAT Entry Size
        pfat_hdr_off = PFS_HEAD_LEN + pfat_entry_size # Possible PFAT Header starts after PFS Header & Entry
        pfat_entry_hdr = get_struct(entry_data, 0, DellPfsHeader) # Possible PFS PFAT Entry
        if len(entry_data) - pfat_hdr_off >= PFAT_HDR_LEN:
            pfat_hdr = get_struct(entry_data, pfat_hdr_off, IntelBiosGuardHeader)
            is_pfat = pfat_hdr.get_platform_id().upper().startswith('DELL')
        
        # Parse PFS Entry which contains sub-PFS Volume with PFAT Payload
        if pfat_entry_hdr.Tag == b'PFS.HDR.' and is_pfat:
            entry_type = 'PFAT' # Re-set PFS Entry Type from OTHER to PFAT, to use such info afterwards
            
            entry_data = parse_pfat_pfs(pfat_entry_hdr, entry_data, padding, structure) # Parse sub-PFS PFAT Volume
        
        # Parse PFS Entry which contains zlib-compressed sub-PFS Volume
        elif pfs_zlib_offsets:
            entry_type = 'ZLIB' # Re-set PFS Entry Type from OTHER to ZLIB, to use such info afterwards
            pfs_count += 1 # Increase the count/index of parsed main PFS structures by one
            
            # Parse each sub-PFS ZLIB Section
            for offset in pfs_zlib_offsets:                
                # Get the Name of the zlib-compressed full PFS structure via the already stored PFS Information
                # The zlib-compressed full PFS structure(s) are used to contain multiple FW (CombineBiosNameX)
                # When zlib-compressed full PFS structure(s) exist within the main/first full PFS structure,
                # its PFS Information should contain their names (CombineBiosNameX). Since the main/first
                # full PFS structure has count/index 1, the rest start at 2+ and thus, their PFS Information
                # names can be retrieved in order by subtracting 2 from the main/first PFS Information values
                sub_pfs_name = f'{info_all[pfs_count - 2][1]} v{info_all[pfs_count - 2][2]}' if info_all else ' UNKNOWN'
                
                # Set the sub-PFS output path (create sub-folders for each sub-PFS and its ZLIB sections)
                sub_pfs_path = os.path.join(extract_path, f'{pfs_count} {safe_name(sub_pfs_name)}')
                
                # Recursively call the PFS ZLIB Section Parser function for the sub-PFS Volume (pfs_index = pfs_count)
                pfs_section_parse(entry_data, offset, sub_pfs_path, sub_pfs_name, pfs_count, pfs_count, True, padding + 4, structure, advanced)
            
        entries_all[index][4] = entry_data # Adjust PFS Entry Data after parsing PFAT (same ZLIB raw data, not stored afterwards)
        entries_all[index][3] = entry_type # Adjust PFS Entry Type from OTHER to PFAT or ZLIB (ZLIB is ignored at file extraction)
        
    # Name & Store each PFS Entry/Component Data, Data Signature, Metadata, Metadata Signature
    for entry_index in range(len(entries_all)):
        file_index = entries_all[entry_index][0]
        file_guid = entries_all[entry_index][1]
        file_version = entries_all[entry_index][2]
        file_type = entries_all[entry_index][3]
        file_data = entries_all[entry_index][4]
        file_data_sig = entries_all[entry_index][5]
        file_meta = entries_all[entry_index][6]
        file_meta_sig = entries_all[entry_index][7]
        
        # Give Names to special PFS Entries, not covered by PFS Information
        if file_type == 'MODEL_INFO':
            file_name = 'Model Information'
        elif file_type == 'NAME_INFO':
            file_name = 'Filename Information'
            if not advanced:
                continue # Don't store Filename Information in non-advanced user mode
        elif file_type == 'SIG_INFO':
            file_name = 'Signature Information'
            if not advanced:
                continue # Don't store Signature Information in non-advanced user mode
        else:
            file_name = ''
        
        # Most PFS Entry Names & Versions are found at PFS Information via their GUID
        # Version can be found at DellPfsEntryR* but prefer PFS Information when possible
        for info_index in range(len(info_all)):
            info_guid = info_all[info_index][0]
            info_name = info_all[info_index][1]
            info_version = info_all[info_index][2]
            
            # Give proper Name & Version info if Entry/Information GUIDs match
            if info_guid == file_guid:
                file_name = info_name
                file_version = info_version
                
                info_all[info_index][0] = 'USED' # PFS with zlib-compressed sub-PFS use the same GUID
                
                break # Break at 1st Name match to not rename again from next zlib-compressed sub-PFS with the same GUID
        
        # For both advanced & non-advanced users, the goal is to store final/usable files only
        # so empty or intermediate files such as sub-PFS, PFS w/ PFAT or zlib-PFS are skipped
        # Main/First PFS CombineBiosNameX Metadata files must be kept for accurate Model Information
        # All users should check these files in order to choose the correct CombineBiosNameX modules
        write_files = [] # Initialize list of output PFS Entry files to be written/extracted
        
        is_zlib = bool(file_type == 'ZLIB') # Determine if PFS Entry Data was zlib-compressed
        
        if file_data and not is_zlib:
            write_files.append([file_data, 'data']) # PFS Entry Data Payload
        
        if file_data_sig and advanced:
            write_files.append([file_data_sig, 'sign_data']) # PFS Entry Data Signature
        
        if file_meta and (is_zlib or advanced):
            write_files.append([file_meta, 'meta']) # PFS Entry Metadata Payload
        
        if file_meta_sig and advanced:
            write_files.append([file_meta_sig, 'sign_meta']) # PFS Entry Metadata Signature
        
        # Write/Extract PFS Entry files
        for file in write_files:
            full_name = f'{pfs_index} {pfs_name} -- {file_index} {file_name} v{file_version}' # Full PFS Entry Name
            pfs_file_write(file[0], file[1], file_type, full_name, extract_path, padding, structure, advanced)
    
    # Get PFS Footer Data after PFS Header Payload
    pfs_footer = buffer[PFS_HEAD_LEN + pfs_hdr.PayloadSize:PFS_HEAD_LEN + pfs_hdr.PayloadSize + PFS_FOOT_LEN]
    
    # Analyze PFS Footer Structure
    chk_pfs_ftr(pfs_footer, pfs_payload, pfs_hdr.PayloadSize, 'PFS', padding, structure)

# Analyze Dell PFS Entry Structure
def parse_pfs_entry(entry_buffer, entry_start, entry_size, entry_struct, text, padding=0, structure=True):    
    # Get PFS Entry Structure values
    pfs_entry = get_struct(entry_buffer, entry_start, entry_struct)
    
    # Show PFS Entry Structure info
    if structure:
        printer('PFS Entry:\n', padding + 4)
        pfs_entry.struct_print(padding + 8)
    
    # Validate that a known PFS Entry Header Version was encountered
    chk_hdr_ver(pfs_entry.HeaderVersion, text, padding + 8)
    
    # Validate that the PFS Entry Reserved field is empty
    if pfs_entry.Reserved != 0:
        printer(f'Error: Detected non-empty {text} Reserved field!', padding + 8)
    
    # Get PFS Entry Version string via "Version" and "VersionType" fields
    entry_version = get_entry_ver(pfs_entry.Version, pfs_entry.VersionType)
    
    # Get PFS Entry GUID in Big Endian format
    entry_guid = f'{int.from_bytes(pfs_entry.GUID, "little"):0{0x10 * 2}X}'
    
    # PFS Entry Data starts after the PFS Entry Structure
    entry_data_start = entry_start + entry_size
    entry_data_end = entry_data_start + pfs_entry.DataSize
    
    # PFS Entry Data Signature starts after PFS Entry Data
    entry_data_sig_start = entry_data_end
    entry_data_sig_end = entry_data_sig_start + pfs_entry.DataSigSize
    
    # PFS Entry Metadata starts after PFS Entry Data Signature
    entry_met_start = entry_data_sig_end 
    entry_met_end = entry_met_start + pfs_entry.DataMetSize
    
    # PFS Entry Metadata Signature starts after PFS Entry Metadata
    entry_met_sig_start = entry_met_end
    entry_met_sig_end = entry_met_sig_start + pfs_entry.DataMetSigSize
    
    entry_data = entry_buffer[entry_data_start:entry_data_end] # Store PFS Entry Data
    entry_data_sig = entry_buffer[entry_data_sig_start:entry_data_sig_end] # Store PFS Entry Data Signature
    entry_met = entry_buffer[entry_met_start:entry_met_end] # Store PFS Entry Metadata
    entry_met_sig = entry_buffer[entry_met_sig_start:entry_met_sig_end] # Store PFS Entry Metadata Signature
    
    return pfs_entry, entry_version, entry_guid, entry_data, entry_data_sig, entry_met, entry_met_sig, entry_met_sig_end

# Parse Dell PFS Volume with PFAT Payload
def parse_pfat_pfs(entry_hdr, entry_data, padding=0, structure=True):
    # Show PFS Volume indicator
    if structure:
        printer('PFS Volume:', padding + 4)
    
    # Show sub-PFS Header Structure Info
    if structure:
        printer('PFS Header:\n', padding + 8)
        entry_hdr.struct_print(padding + 12)
    
    # Validate that a known sub-PFS Header Version was encountered
    chk_hdr_ver(entry_hdr.HeaderVersion, 'sub-PFS', padding + 12)
    
    # Get sub-PFS Payload Data
    pfat_payload = entry_data[PFS_HEAD_LEN:PFS_HEAD_LEN + entry_hdr.PayloadSize]
    
    # Get sub-PFS Footer Data after sub-PFS Header Payload (must be retrieved at the initial entry_data, before PFAT parsing)
    pfat_footer = entry_data[PFS_HEAD_LEN + entry_hdr.PayloadSize:PFS_HEAD_LEN + entry_hdr.PayloadSize + PFS_FOOT_LEN]
    
    # Parse all sub-PFS Payload PFAT Entries
    pfat_entries_all = [] # Storage for all sub-PFS PFAT Entries Order/Offset & Payload/Raw Data
    pfat_entry_start = 0 # Increasing sub-PFS PFAT Entry start offset
    pfat_entry_index = 1 # Increasing sub-PFS PFAT Entry count index
    _, pfs_entry_size = get_pfs_entry(pfat_payload, 0) # Get initial PFS PFAT Entry Size for loop
    while len(pfat_payload[pfat_entry_start:pfat_entry_start + pfs_entry_size]) == pfs_entry_size:
        # Get sub-PFS PFAT Entry Structure & Size info
        pfat_entry_struct,pfat_entry_size = get_pfs_entry(pfat_payload, pfat_entry_start)
        
        # Analyze sub-PFS PFAT Entry Structure and get relevant info
        pfat_entry,_,_,pfat_entry_data,_,pfat_entry_met,_,pfat_next_entry = parse_pfs_entry(pfat_payload,
        pfat_entry_start, pfat_entry_size, pfat_entry_struct, 'sub-PFS PFAT Entry', padding + 4, structure)
        
        # Each sub-PFS PFAT Entry includes an AMI BIOS Guard (a.k.a. PFAT) block at the beginning
        # We need to parse the PFAT block and remove its contents from the final Payload/Raw Data
        pfat_hdr_off = pfat_entry_start + pfat_entry_size # PFAT block starts after PFS Entry
        
        # Get sub-PFS PFAT Header Structure values
        pfat_hdr = get_struct(pfat_payload, pfat_hdr_off, IntelBiosGuardHeader)
        
        # Get ordinal value of the sub-PFS PFAT Entry Index
        pfat_entry_idx_ord = get_ordinal(pfat_entry_index)
        
        # Show sub-PFS PFAT Header Structure info
        if structure:
            printer(f'PFAT Block {pfat_entry_idx_ord} - Header:\n', padding + 12)
            pfat_hdr.struct_print(padding + 16)
        
        pfat_script_start = pfat_hdr_off + PFAT_HDR_LEN # PFAT Block Script Start
        pfat_script_end = pfat_script_start + pfat_hdr.ScriptSize # PFAT Block Script End
        pfat_script_data = pfat_payload[pfat_script_start:pfat_script_end] # PFAT Block Script Data
        pfat_payload_start = pfat_script_end # PFAT Block Payload Start (at Script end)
        pfat_payload_end = pfat_script_end + pfat_hdr.DataSize # PFAT Block Data End
        pfat_payload_data = pfat_payload[pfat_payload_start:pfat_payload_end] # PFAT Block Raw Data
        pfat_hdr_bgs_size = PFAT_HDR_LEN + pfat_hdr.ScriptSize # PFAT Block Header & Script Size
        
        # The PFAT Script End should match the total Entry Data Size w/o PFAT block 
        if pfat_hdr_bgs_size != pfat_entry.DataSize - pfat_hdr.DataSize:
            printer(f'Error: Detected sub-PFS PFAT Block {pfat_entry_idx_ord} Header & PFAT Size mismatch!', padding + 16)
        
        # Get PFAT Header Flags (SFAM, ProtectEC, GFXMitDis, FTU, Reserved)
        is_sfam,_,_,_,_ = pfat_hdr.get_flags()
        
        # Parse sub-PFS PFAT Signature, if applicable (only when PFAT Header > SFAM flag is set)
        if is_sfam and len(pfat_payload[pfat_payload_end:pfat_payload_end + PFAT_SIG_LEN]) == PFAT_SIG_LEN:
            # Get sub-PFS PFAT Signature Structure values
            pfat_sig = get_struct(pfat_payload, pfat_payload_end, IntelBiosGuardSignature2k)
            
            # Show sub-PFS PFAT Signature Structure info
            if structure:
                printer(f'PFAT Block {pfat_entry_idx_ord} - Signature:\n', padding + 12)
                pfat_sig.struct_print(padding + 16)
        
        # Show PFAT Script via BIOS Guard Script Tool
        if structure:
            printer(f'PFAT Block {pfat_entry_idx_ord} - Script:\n', padding + 12)
            
            _ = parse_bg_script(pfat_script_data, padding + 16)
        
        # The payload of sub-PFS PFAT Entries is not in proper order by default
        # We can get each payload's order from PFAT Script > OpCode #2 (set I0 imm)
        # PFAT Script OpCode #2 > Operand #3 stores the payload Offset in final image
        pfat_entry_off = int.from_bytes(pfat_script_data[0xC:0x10], 'little')
        
        # We can get each payload's length from PFAT Script > OpCode #4 (set I2 imm)
        # PFAT Script OpCode #4 > Operand #3 stores the payload Length in final image
        pfat_entry_len = int.from_bytes(pfat_script_data[0x1C:0x20], 'little')
        
        # Check that the PFAT Entry Length from Header & Script match
        if pfat_hdr.DataSize != pfat_entry_len:
            printer(f'Error: Detected sub-PFS PFAT Block {pfat_entry_idx_ord} Header & Script Length mismatch!', padding + 12)
        
        # Initialize sub-PFS PFAT Entry Metadata Address
        pfat_entry_adr = pfat_entry_off
        
        # Parse sub-PFS PFAT Entry/Block Metadata
        if len(pfat_entry_met) >= PFS_PFAT_LEN:
            # Get sub-PFS PFAT Metadata Structure values
            pfat_met = get_struct(pfat_entry_met, 0, DellPfsPfatMetadata)
            
            # Store sub-PFS PFAT Entry Metadata Address
            pfat_entry_adr = pfat_met.Address
            
            # Show sub-PFS PFAT Metadata Structure info
            if structure:
                printer(f'PFAT Block {pfat_entry_idx_ord} - Metadata:\n', padding + 12)
                pfat_met.struct_print(padding + 16)
            
            # Another way to get each PFAT Entry Offset is from its Metadata, if applicable
            # Check that the PFAT Entry Offsets from PFAT Script and PFAT Metadata match
            if pfat_entry_off != pfat_met.Offset:
                printer(f'Error: Detected sub-PFS PFAT Block {pfat_entry_idx_ord} Metadata & PFAT Offset mismatch!', padding + 16)
                pfat_entry_off = pfat_met.Offset # Prefer Offset from Metadata, in case PFAT Script differs
            
            # Another way to get each PFAT Entry Length is from its Metadata, if applicable
            # Check that the PFAT Entry Length from PFAT Script and PFAT Metadata match
            if not (pfat_hdr.DataSize == pfat_entry_len == pfat_met.DataSize):
                printer(f'Error: Detected sub-PFS PFAT Block {pfat_entry_idx_ord} Metadata & PFAT Length mismatch!', padding + 16)
            
            # Check that the PFAT Entry payload Size from PFAT Header matches the one from PFAT Metadata
            if pfat_hdr.DataSize != pfat_met.DataSize:
                printer(f'Error: Detected sub-PFS PFAT Block {pfat_entry_idx_ord} Metadata & PFAT Block Size mismatch!', padding + 16)        
        
        # Get sub-PFS Entry Raw Data by subtracting PFAT Header & Script from PFAT Entry Data
        pfat_entry_data_raw = pfat_entry_data[pfat_hdr_bgs_size:]
        
        # The sub-PFS Entry Raw Data (w/o PFAT Header & Script) should match with the PFAT Block payload
        if pfat_entry_data_raw != pfat_payload_data:
            printer(f'Error: Detected sub-PFS PFAT Block {pfat_entry_idx_ord} w/o PFAT & PFAT Block Data mismatch!', padding + 16)
            pfat_entry_data_raw = pfat_payload_data # Prefer Data from PFAT Block, in case PFAT Entry differs
        
        # Store each sub-PFS PFAT Entry/Block Offset, Address, Ordinal Index and Payload/Raw Data
        # Goal is to sort these based on Offset first and Address second, in cases of same Offset
        # For example, Precision 3430 has two PFAT Entries with the same Offset of 0x40000 at both
        # BG Script and PFAT Metadata but their PFAT Metadata Address is 0xFF040000 and 0xFFA40000
        pfat_entries_all.append((pfat_entry_off, pfat_entry_adr, pfat_entry_idx_ord, pfat_entry_data_raw))
        
        # Check if next sub-PFS PFAT Entry offset is valid 
        if pfat_next_entry <= 0:
            printer(f'Error: Detected sub-PFS PFAT Block {pfat_entry_idx_ord} with invalid next PFAT Block offset!', padding + 16)
            pfat_next_entry += pfs_entry_size # Avoid a potential infinite loop if next sub-PFS PFAT Entry offset is bad
        
        pfat_entry_start = pfat_next_entry # Next sub-PFS PFAT Entry starts after sub-PFS Entry Metadata Signature
        
        pfat_entry_index += 1
    
    pfat_entries_all.sort() # Sort all sub-PFS PFAT Entries based on their Offset/Address
    
    block_start_exp = 0 # Initialize sub-PFS PFAT Entry expected Offset
    total_pfat_data = b'' # Initialize final/ordered sub-PFS Entry Data
    
    # Parse all sorted sub-PFS PFAT Entries and merge their payload/data
    for block_start,_,block_index,block_data in pfat_entries_all:
        # Fill any data gaps between sorted sub-PFS PFAT Entries with padding
        # For example, Precision 7960 v0.16.68 has gap at 0x1190000-0x11A0000
        block_data_gap = block_start - block_start_exp
        if block_data_gap > 0:
            printer(f'Warning: Filled sub-PFS PFAT {block_index} data gap 0x{block_data_gap:X} [0x{block_start_exp:X}-0x{block_start:X}]!', padding + 8)
            total_pfat_data += b'\xFF' * block_data_gap # Use 0xFF padding to fill in data gaps in PFAT UEFI firmware images
        
        total_pfat_data += block_data # Append sorted sub-PFS PFAT Entry payload/data
        
        block_start_exp = len(total_pfat_data) # Set next sub-PFS PFAT Entry expected Start
    
    # Verify that the end offset of the last PFAT Entry matches the final sub-PFS Entry Data Size
    if len(total_pfat_data) != pfat_entries_all[-1][0] + len(pfat_entries_all[-1][3]):
        printer('Error: Detected sub-PFS PFAT total buffer size and last block end mismatch!', padding + 8)
    
    # Analyze sub-PFS Footer Structure
    chk_pfs_ftr(pfat_footer, pfat_payload, entry_hdr.PayloadSize, 'Sub-PFS', padding + 4, structure)
    
    return total_pfat_data

# Get Dell PFS Entry Structure & Size via its Version
def get_pfs_entry(buffer, offset):
    pfs_entry_ver = int.from_bytes(buffer[offset + 0x10:offset + 0x14], 'little') # PFS Entry Version
    
    if pfs_entry_ver == 1:
        return DellPfsEntryR1, ctypes.sizeof(DellPfsEntryR1)
    
    if pfs_entry_ver == 2:
        return DellPfsEntryR2, ctypes.sizeof(DellPfsEntryR2)

    return DellPfsEntryR2, ctypes.sizeof(DellPfsEntryR2)

# Determine Dell PFS Entry Version string
def get_entry_ver(version_fields, version_types):
    version = '' # Initialize Version string
    
    # Each Version Type (1 byte) determines the type of each Version Value (2 bytes)
    # Version Type 'N' is Number, 'A' is Text and ' ' is Empty/Unused
    for index,field in enumerate(version_fields):
        eol = '' if index == len(version_fields) - 1 else '.'
        
        if version_types[index] == 65:
            version += f'{field:X}{eol}' # 0x41 = ASCII
        elif version_types[index] == 78:
            version += f'{field:d}{eol}' # 0x4E = Number
        elif version_types[index] in (0, 32):
            version = version.strip('.') # 0x00 or 0x20 = Unused
        else:
            version += f'{field:X}{eol}' # Unknown
            
    return version

# Check if Dell PFS Header Version is known
def chk_hdr_ver(version, text, padding=0):
    if version in (1,2):
        return
    
    printer(f'Error: Unknown {text} Header Version {version}!', padding)
    
    return

# Analyze Dell PFS Footer Structure
def chk_pfs_ftr(footer_buffer, data_buffer, data_size, text, padding=0, structure=True):    
    # Get PFS Footer Structure values
    pfs_ftr = get_struct(footer_buffer, 0, DellPfsFooter)
    
    # Validate that a PFS Footer was parsed
    if pfs_ftr.Tag == b'PFS.FTR.':
        # Show PFS Footer Structure info
        if structure:
            printer('PFS Footer:\n', padding + 4)
            pfs_ftr.struct_print(padding + 8)
    else:
        printer(f'Error: {text} Footer could not be found!', padding + 4)
    
    # Validate that PFS Header Payload Size matches the one at PFS Footer
    if data_size != pfs_ftr.PayloadSize:
        printer(f'Error: {text} Header & Footer Payload Size mismatch!', padding + 4)
    
    # Calculate the PFS Payload Data CRC-32 w/ Vector 0
    pfs_ftr_crc = ~zlib.crc32(data_buffer, 0) & 0xFFFFFFFF
    
    # Validate PFS Payload Data Checksum via PFS Footer
    if pfs_ftr.Checksum != pfs_ftr_crc:
        printer(f'Error: Invalid {text} Footer Payload Checksum!', padding + 4)

# Write/Extract Dell PFS Entry Files (Data, Metadata, Signature)
def pfs_file_write(bin_buff, bin_name, bin_type, full_name, out_path, padding=0, structure=True, advanced=True):
    # Store Data/Metadata Signature (advanced users only)
    if bin_name.startswith('sign'):
        final_name = f'{safe_name(full_name)}.{bin_name.split("_")[1]}.sig'
        final_path = os.path.join(out_path, final_name)
        
        with open(final_path, 'wb') as pfs_out:
            pfs_out.write(bin_buff) # Write final Data/Metadata Signature
        
        return # Skip further processing for Signatures
    
    # Store Data/Metadata Payload
    bin_ext = f'.{bin_name}.bin' if advanced else '.bin' # Simpler Data/Metadata Extension for non-advanced users
    
    # Some Data may be Text or XML files with useful information for non-advanced users
    is_text,final_data,file_ext,write_mode = bin_is_text(bin_buff, bin_type, bin_name == 'meta', padding, structure, advanced)
    
    final_name = f'{safe_name(full_name)}{bin_ext[:-4] + file_ext if is_text else bin_ext}'
    final_path = os.path.join(out_path, final_name)
    
    with open(final_path, write_mode) as pfs_out:
        pfs_out.write(final_data) # Write final Data/Metadata Payload

# Check if Dell PFS Entry file/data is Text/XML and Convert
def bin_is_text(buffer, file_type, is_metadata, padding=0, structure=True, advanced=True):
    is_text = False
    write_mode = 'wb'
    extension = '.bin'
    buffer_in = buffer
    
    if b',END' in buffer[-0x8:]: # Text Type 1
        is_text = True
        write_mode = 'w'
        extension = '.txt'
        buffer = buffer.decode('utf-8').split(',END')[0].replace(';','\n')
    elif buffer.startswith(b'VendorName=Dell'): # Text Type 2
        is_text = True
        write_mode = 'w'
        extension = '.txt'
        buffer = buffer.split(b'\x00')[0].decode('utf-8').replace(';','\n')
    elif b'<Rimm x-schema="' in buffer[:0x50]: # XML Type
        is_text = True
        write_mode = 'w'
        extension = '.xml'
        buffer = buffer.decode('utf-8')
    elif file_type in ('NESTED_PFS','ZLIB') and is_metadata and len(buffer) == PFS_META_LEN: # Text Type 3
        is_text = True
        write_mode = 'w'
        extension = '.txt'
        with io.StringIO() as text_buffer, contextlib.redirect_stdout(text_buffer):
            get_struct(buffer, 0, DellPfsMetadata).struct_print(0)
            buffer = text_buffer.getvalue()
    
    # Show Model/PCR XML Information, if applicable
    if structure and is_text and not is_metadata: # Metadata is shown at initial DellPfsMetadata analysis
        printer(f'PFS { {".txt": "Model", ".xml": "PCR XML"}[extension] } Information:\n', padding + 8)
        _ = [printer(line.strip('\r'), padding + 12, False) for line in buffer.split('\n') if line]
    
    # Only for non-advanced users due to signature (.sig) invalidation
    if advanced:
        return False, buffer_in, '.bin', 'wb'
    
    return is_text, buffer, extension, write_mode

# Get ctypes Structure Sizes
PFS_HEAD_LEN = ctypes.sizeof(DellPfsHeader)
PFS_FOOT_LEN = ctypes.sizeof(DellPfsFooter)
PFS_INFO_LEN = ctypes.sizeof(DellPfsInfo)
PFS_NAME_LEN = ctypes.sizeof(DellPfsName)
PFS_META_LEN = ctypes.sizeof(DellPfsMetadata)
PFS_PFAT_LEN = ctypes.sizeof(DellPfsPfatMetadata)
PFAT_HDR_LEN = ctypes.sizeof(IntelBiosGuardHeader)
PFAT_SIG_LEN = ctypes.sizeof(IntelBiosGuardSignature2k)

if __name__ == '__main__':
    utility = BIOSUtility(TITLE, is_dell_pfs, pfs_pkg_parse)
    utility.parse_argument('-a', '--advanced', help='extract signatures and metadata', action='store_true')
    utility.parse_argument('-s', '--structure', help='show PFS structure information', action='store_true')
    utility.run_utility()
