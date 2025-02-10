#!/usr/bin/env python3
#coding=utf-8

"""
Copyright (C) 2022 Plato Mavropoulos
"""

# Generate padding (spaces or tabs)
def padder(padd_count, tab=False):
    return ('\t' if tab else ' ') * padd_count

# Get String from given input object
def to_string(in_object, sep_char=''):
    if type(in_object).__name__ in ('list','tuple'):
        out_string = sep_char.join(map(str, in_object))
    else:
        out_string = str(in_object)
    
    return out_string

# Get Bytes from given buffer or file path
def file_to_bytes(in_object):
    object_bytes = in_object
    
    if type(in_object).__name__ not in ('bytes','bytearray'):
        with open(to_string(in_object), 'rb') as object_data:
            object_bytes = object_data.read()
    
    return object_bytes

# Check if string starts and ends with given character(s)
def is_encased(in_string, chars):
    return in_string.startswith(chars) and in_string.endswith(chars)
