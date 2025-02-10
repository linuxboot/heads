#!/usr/bin/env python3
#coding=utf-8

"""
Copyright (C) 2022 Plato Mavropoulos
"""

from common.path_ops import project_root, safe_path
from common.system import get_os_ver

# https://github.com/allowitsme/big-tool by Dmitry Frolov
# https://github.com/platomav/BGScriptTool by Plato Mavropoulos
def get_bgs_tool():
    try:
        # noinspection PyUnresolvedReferences
        from external.big_script_tool import BigScript # pylint: disable=E0401,E0611
    except Exception:
        BigScript = None
    
    return BigScript

# Get UEFIFind path
def get_uefifind_path():
    exec_name = f'UEFIFind{".exe" if get_os_ver()[1] else ""}'
    
    return safe_path(project_root(), ['external', exec_name])

# Get UEFIExtract path
def get_uefiextract_path():
    exec_name = f'UEFIExtract{".exe" if get_os_ver()[1] else ""}'
    
    return safe_path(project_root(), ['external', exec_name])

# Get ToshibaComExtractor path
def get_comextract_path():
    exec_name = f'comextract{".exe" if get_os_ver()[1] else ""}'
    
    return safe_path(project_root(), ['external', exec_name])
