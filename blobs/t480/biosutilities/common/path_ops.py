#!/usr/bin/env python3
#coding=utf-8

"""
Copyright (C) 2022 Plato Mavropoulos
"""

import os
import re
import sys
import stat
import shutil
from pathlib import Path, PurePath

from common.text_ops import is_encased, to_string

# Fix illegal/reserved Windows characters
def safe_name(in_name):
    name_repr = repr(in_name).strip("'")

    return re.sub(r'[\\/:"*?<>|]+', '_', name_repr)

# Check and attempt to fix illegal/unsafe OS path traversals
def safe_path(base_path, user_paths):
    # Convert base path to absolute path
    base_path = real_path(base_path)
    
    # Merge user path(s) to string with OS separators
    user_path = to_string(user_paths, os.sep)
    
    # Create target path from base + requested user path
    target_path = norm_path(base_path, user_path)
    
    # Check if target path is OS illegal/unsafe
    if is_safe_path(base_path, target_path):
        return target_path
    
    # Re-create target path from base + leveled/safe illegal "path" (now file)
    nuked_path = norm_path(base_path, safe_name(user_path))
    
    # Check if illegal path leveling worked
    if is_safe_path(base_path, nuked_path):
        return nuked_path
    
    # Still illegal, raise exception to halt execution
    raise Exception(f'ILLEGAL_PATH_TRAVERSAL: {user_path}')

# Check for illegal/unsafe OS path traversal
def is_safe_path(base_path, target_path):
    base_path = real_path(base_path)
    
    target_path = real_path(target_path)
    
    common_path = os.path.commonpath((base_path, target_path))
    
    return base_path == common_path

# Create normalized base path + OS separator + user path
def norm_path(base_path, user_path):
    return os.path.normpath(base_path + os.sep + user_path)

# Get absolute path, resolving any symlinks
def real_path(in_path):
    return os.path.realpath(in_path)

# Get Windows/Posix OS agnostic path
def agnostic_path(in_path):
    return PurePath(in_path.replace('\\', os.sep))

# Get absolute parent of path
def path_parent(in_path):
    return Path(in_path).parent.absolute()

# Get final path component, with suffix
def path_name(in_path):
    return PurePath(in_path).name

# Get final path component, w/o suffix
def path_stem(in_path):
    return PurePath(in_path).stem

# Get list of path file extensions
def path_suffixes(in_path):
    return PurePath(in_path).suffixes or ['']

# Check if path is absolute
def is_path_absolute(in_path):
    return Path(in_path).is_absolute()

# Create folder(s), controlling parents, existence and prior deletion
def make_dirs(in_path, parents=True, exist_ok=False, delete=False):
    if delete:
        del_dirs(in_path)
    
    Path.mkdir(Path(in_path), parents=parents, exist_ok=exist_ok)

# Delete folder(s), if present
def del_dirs(in_path):
    if Path(in_path).is_dir():
        shutil.rmtree(in_path, onerror=clear_readonly)

# Copy file to path with or w/o metadata
def copy_file(in_path, out_path, meta=False):
    if meta:
        shutil.copy2(in_path, out_path)
    else:
        shutil.copy(in_path, out_path)

# Clear read-only file attribute (on shutil.rmtree error)
def clear_readonly(in_func, in_path, _):
    os.chmod(in_path, stat.S_IWRITE)
    in_func(in_path)

# Walk path to get all files
def get_path_files(in_path):
    path_files = []
    
    for root, _, files in os.walk(in_path):
        for name in files:
            path_files.append(os.path.join(root, name))
    
    return path_files

# Get path without leading/trailing quotes
def get_dequoted_path(in_path):
    out_path = to_string(in_path).strip()
    
    if len(out_path) >= 2 and is_encased(out_path, ("'",'"')):
        out_path = out_path[1:-1]
    
    return out_path

# Set utility extraction stem
def extract_suffix():
    return '_extracted'

# Get utility extraction path
def get_extract_path(in_path, suffix=extract_suffix()):
    return f'{in_path}{suffix}'

# Get project's root directory
def project_root():
    root = Path(__file__).parent.parent
    
    return real_path(root)

# Get runtime's root directory
def runtime_root():
    if getattr(sys, 'frozen', False):
        root = Path(sys.executable).parent
    else:
        root = project_root()
    
    return real_path(root)
