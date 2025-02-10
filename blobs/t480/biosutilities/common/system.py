#!/usr/bin/env python3
#coding=utf-8

"""
Copyright (C) 2022 Plato Mavropoulos
"""

import sys

from common.text_ops import padder, to_string

# Get Python Version (tuple)
def get_py_ver():
    return sys.version_info

# Get OS Platform (string)
def get_os_ver():
    sys_os = sys.platform
    
    is_win = sys_os == 'win32'
    is_lnx = sys_os.startswith('linux') or sys_os == 'darwin' or sys_os.find('bsd') != -1
    
    return sys_os, is_win, is_win or is_lnx

# Check for --auto-exit|-e
def is_auto_exit():
    return bool('--auto-exit' in sys.argv or '-e' in sys.argv)

# Check Python Version
def check_sys_py():
    sys_py = get_py_ver()
    
    if sys_py < (3,10):
        sys.stdout.write(f'\nError: Python >= 3.10 required, not {sys_py[0]}.{sys_py[1]}!')
        
        if not is_auto_exit():
            # noinspection PyUnresolvedReferences
            (raw_input if sys_py[0] <= 2 else input)('\nPress enter to exit') # pylint: disable=E0602
        
        sys.exit(125)

# Check OS Platform
def check_sys_os():
    os_tag,os_win,os_sup = get_os_ver()
    
    if not os_sup:
        printer(f'Error: Unsupported platform "{os_tag}"!')
        
        if not is_auto_exit():
            input('\nPress enter to exit')
        
        sys.exit(126) 
    
    # Fix Windows Unicode console redirection
    if os_win:
        sys.stdout.reconfigure(encoding='utf-8')

# Show message(s) while controlling padding, newline, pausing & separator
def printer(in_message='', padd_count=0, new_line=True, pause=False, sep_char=' '):
    message = to_string(in_message, sep_char)
    
    padding = padder(padd_count)
    
    newline = '\n' if new_line else ''
    
    output = newline + padding + message
    
    (input if pause and not is_auto_exit() else print)(output)
