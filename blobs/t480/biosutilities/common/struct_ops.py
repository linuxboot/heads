#!/usr/bin/env python3
#coding=utf-8

"""
Copyright (C) 2022 Plato Mavropoulos
"""

import ctypes

char = ctypes.c_char
uint8_t = ctypes.c_ubyte
uint16_t = ctypes.c_ushort
uint32_t = ctypes.c_uint
uint64_t = ctypes.c_uint64

# https://github.com/skochinsky/me-tools/blob/master/me_unpack.py by Igor Skochinsky
def get_struct(buffer, start_offset, class_name, param_list=None):
    if param_list is None:
        param_list = []

    structure = class_name(*param_list) # Unpack parameter list
    struct_len = ctypes.sizeof(structure)
    struct_data = buffer[start_offset:start_offset + struct_len]
    fit_len = min(len(struct_data), struct_len)

    ctypes.memmove(ctypes.addressof(structure), struct_data, fit_len)

    return structure
