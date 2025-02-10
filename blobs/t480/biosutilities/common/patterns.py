#!/usr/bin/env python3
#coding=utf-8

"""
Copyright (C) 2022 Plato Mavropoulos
"""

import re

PAT_AMI_PFAT = re.compile(br'_AMIPFAT.AMI_BIOS_GUARD_FLASH_CONFIGURATIONS', re.DOTALL)
PAT_AMI_UCP = re.compile(br'@(UAF|HPU).{12}@', re.DOTALL)
PAT_APPLE_EFI = re.compile(br'\$IBIOSI\$.{16}\x2E\x00.{6}\x2E\x00.{8}\x2E\x00.{6}\x2E\x00.{20}\x00{2}', re.DOTALL)
PAT_APPLE_IM4P = re.compile(br'\x16\x04IM4P\x16\x04mefi')
PAT_APPLE_PBZX = re.compile(br'pbzx')
PAT_APPLE_PKG = re.compile(br'xar!')
PAT_AWARD_LZH = re.compile(br'-lh[04567]-')
PAT_DELL_FTR = re.compile(br'\xEE\xAA\xEE\x8F\x49\x1B\xE8\xAE\x14\x37\x90')
PAT_DELL_HDR = re.compile(br'\xEE\xAA\x76\x1B\xEC\xBB\x20\xF1\xE6\x51.\x78\x9C', re.DOTALL)
PAT_DELL_PKG = re.compile(br'\x72\x13\x55\x00.{45}7zXZ', re.DOTALL)
PAT_FUJITSU_SFX = re.compile(br'FjSfxBinay\xB2\xAC\xBC\xB9\xFF{4}.{4}\xFF{4}.{4}\xFF{4}\xFC\xFE', re.DOTALL)
PAT_INSYDE_IFL = re.compile(br'\$_IFLASH')
PAT_INSYDE_SFX = re.compile(br'\x0D\x0A;!@InstallEnd@!\x0D\x0A(7z\xBC\xAF\x27|\x6E\xF4\x79\x5F\x4E)')
PAT_INTEL_ENG = re.compile(br'\x04\x00{3}[\xA1\xE1]\x00{3}.{8}\x86\x80.{9}\x00\$((MN2)|(MAN))', re.DOTALL)
PAT_INTEL_IFD = re.compile(br'\x5A\xA5\xF0\x0F.{172}\xFF{16}', re.DOTALL)
PAT_MICROSOFT_CAB = re.compile(br'MSCF\x00{4}')
PAT_MICROSOFT_MZ = re.compile(br'MZ')
PAT_MICROSOFT_PE = re.compile(br'PE\x00{2}')
PAT_PHOENIX_TDK = re.compile(br'\$PACK\x00{3}..\x00{2}.\x00{3}', re.DOTALL)
PAT_PORTWELL_EFI = re.compile(br'<U{2}>')
PAT_TOSHIBA_COM = re.compile(br'\x00{2}[\x00-\x02]BIOS.{20}[\x00\x01]', re.DOTALL)
PAT_VAIO_CAB = re.compile(br'\xB2\xAC\xBC\xB9\xFF{4}.{4}\xFF{4}.{4}\xFF{4}\xFC\xFE', re.DOTALL)
PAT_VAIO_CFG = re.compile(br'\[Setting]\x0D\x0A')
PAT_VAIO_CHK = re.compile(br'\x0AUseVAIOCheck=')
PAT_VAIO_EXT = re.compile(br'\x0AExtractPathByUser=')
