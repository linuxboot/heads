#!/usr/bin/env python3
#coding=utf-8

"""
Copyright (C) 2022 Plato Mavropoulos
"""

import os
import sys
import ctypes
import argparse
import traceback

from common.num_ops import get_ordinal
from common.path_ops import get_dequoted_path, get_extract_path, get_path_files, is_path_absolute, path_parent, runtime_root, safe_path
from common.system import check_sys_os, check_sys_py, get_os_ver, is_auto_exit, printer

class BIOSUtility:
    
    MAX_FAT32_ITEMS = 65535
    
    def __init__(self, title, check, main, padding=0):
        self._title = title
        self._main = main
        self._check = check
        self._padding = padding
        self._arguments_kw = {}
        
        # Initialize argparse argument parser
        self._argparser = argparse.ArgumentParser()
        
        self._argparser.add_argument('files', type=argparse.FileType('r', encoding='utf-8'), nargs='*')
        self._argparser.add_argument('-e', '--auto-exit', help='skip all user action prompts', action='store_true')
        self._argparser.add_argument('-v', '--version', help='show utility name and version', action='store_true')
        self._argparser.add_argument('-o', '--output-dir', help='extract in given output directory')
        self._argparser.add_argument('-i', '--input-dir', help='extract from given input directory')
        
        self._arguments,self._arguments_unk = self._argparser.parse_known_args()
        
        # Managed Python exception handler
        sys.excepthook = self._exception_handler
        
        # Check Python Version
        check_sys_py()
        
        # Check OS Platform
        check_sys_os()
        
        # Show Script Title
        printer(self._title, new_line=False)
        
        # Show Utility Version on demand
        if self._arguments.version:
            sys.exit(0)
        
        # Set console/terminal window title (Windows only)
        if get_os_ver()[1]:
            ctypes.windll.kernel32.SetConsoleTitleW(self._title)
        
        # Process input files and generate output path
        self._process_input_files()
        
        # Count input files for exit code
        self._exit_code = len(self._input_files)
    
    def parse_argument(self, *args, **kwargs):
        _dest = self._argparser.add_argument(*args, **kwargs).dest
        self._arguments = self._argparser.parse_known_args(self._arguments_unk)[0]
        self._arguments_kw.update({_dest: self._arguments.__dict__[_dest]})
    
    def run_utility(self):
        for _input_file in self._input_files:
            _input_name = os.path.basename(_input_file)
            
            printer(['***', _input_name], self._padding)
            
            if not self._check(_input_file):
                printer('Error: This is not a supported input!', self._padding + 4)
                
                continue # Next input file
            
            _extract_path = os.path.join(self._output_path, get_extract_path(_input_name))
            
            if os.path.isdir(_extract_path):
                for _suffix in range(2, self.MAX_FAT32_ITEMS):
                    _renamed_path = f'{os.path.normpath(_extract_path)}_{get_ordinal(_suffix)}'
                    
                    if not os.path.isdir(_renamed_path):
                        _extract_path = _renamed_path
                        
                        break # Extract path is now unique
            
            if self._main(_input_file, _extract_path, self._padding + 4, **self._arguments_kw) in [0, None]:
                self._exit_code -= 1
        
        printer('Done!', pause=True)
        
        sys.exit(self._exit_code)

    # Process input files
    def _process_input_files(self):
        self._input_files = []
        
        if len(sys.argv) >= 2:
            # Drag & Drop or CLI
            if self._arguments.input_dir:
                _input_path_user = self._arguments.input_dir
                _input_path_full = self._get_input_path(_input_path_user) if _input_path_user else ''
                self._input_files = get_path_files(_input_path_full)
            else:
                # Parse list of input files (i.e. argparse FileType objects)
                for _file_object in self._arguments.files:
                    # Store each argparse FileType object's name (i.e. path)
                    self._input_files.append(_file_object.name)
                    # Close each argparse FileType object (i.e. allow input file changes)
                    _file_object.close()
            
            # Set output fallback value for missing argparse Output and Input Path
            _output_fallback = path_parent(self._input_files[0]) if self._input_files else None
            
            # Set output path via argparse Output path or argparse Input path or first input file path
            _output_path = self._arguments.output_dir or self._arguments.input_dir or _output_fallback
        else:
            # Script w/o parameters
            _input_path_user = get_dequoted_path(input('\nEnter input directory path: '))
            _input_path_full = self._get_input_path(_input_path_user) if _input_path_user else ''
            self._input_files = get_path_files(_input_path_full)
            
            _output_path = get_dequoted_path(input('\nEnter output directory path: '))
        
        self._output_path = self._get_input_path(_output_path)
    
    # Get absolute input file path
    @staticmethod
    def _get_input_path(input_path):
        if not input_path:
            # Use runtime directory if no user path is specified
            absolute_path = runtime_root()
        else:
            # Check if user specified path is absolute
            if is_path_absolute(input_path):
                absolute_path = input_path
            # Otherwise, make it runtime directory relative
            else:
                absolute_path = safe_path(runtime_root(), input_path)
        
        return absolute_path

    # https://stackoverflow.com/a/781074 by Torsten Marek
    @staticmethod
    def _exception_handler(exc_type, exc_value, exc_traceback):
        if exc_type is KeyboardInterrupt:
            printer('')
        else:
            printer('Error: Utility crashed, please report the following:\n')
            
            traceback.print_exception(exc_type, exc_value, exc_traceback)

        if not is_auto_exit():
            input('\nPress enter to exit')

        sys.exit(127)
