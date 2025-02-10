#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-only

import argparse
import os
from lib.image import parse_ifd_or_me
from lib.mfs import INTEL_IDX, FITC_IDX, HOME_IDX, MFS
from lib.cfg import CFG

def delta_from_fitc_cfg(overridable, fitc_files, output):
    if set(fitc_files.keys()).difference(overridable.keys()) != set():
        raise ValueError("fitc.cfg contains unexpected data, please report this for investigation")
    # Iterate overridable paths from intel.cfg
    for path, intel_file in overridable.items():
        # Skip dirs
        if intel_file.isDirectory():
            continue
        # Skip files not in fitc
        if path not in fitc_files:
            continue
        fitc_file = fitc_files[path]
        if intel_file.data != fitc_file.data:
            # Write out differing file to delta
            filepath = os.path.join(output, path.lstrip("/"))
            os.makedirs(os.path.dirname(filepath), exist_ok=True)
            with open(filepath, "wb") as f:
                f.write(fitc_file.data)

def delta_from_home(overridable, home_files, output):
    # Iterate overridable paths from intel.cfg
    for path, intel_file in overridable.items():
        # Skip dirs
        if intel_file.isDirectory():
            continue
        # Skip files not in /home
        if path not in home_files:
            continue
        if intel_file.data != home_files[path]:
            # Write out differing file to delta
            filepath = os.path.join(output, path.lstrip("/"))
            os.makedirs(os.path.dirname(filepath), exist_ok=True)
            with open(filepath, "wb") as f:
                f.write(home_files[path])

parser = argparse.ArgumentParser()
parser.add_argument("--input", required=True, help="Input vendor image (either full with IFD or just ME)")
parser.add_argument("--output", required=True, help="Output MFS delta directory")
args = parser.parse_args()

# Get ME from input image
with open(args.input, "rb") as f:
    me = parse_ifd_or_me(f.read())

# Parse MFS and get its system volume
mfs = MFS(me.entry_data("MFS"))
sysvol = mfs.getSystemVolume()

# Lookup table of directories and overridable paths in intel.cfg
intel_cfg = CFG(sysvol.getFile(INTEL_IDX).data)
overridable = { file.path: file for file in intel_cfg.files \
                if file.isDirectory() or (file.record.opt & 1) != 0 }

fitc = sysvol.getFile(FITC_IDX)

if fitc:
    # We have a fitc.cfg, so compute delta from that
    fitc_cfg = CFG(fitc.data)
    fitc_files = { file.path: file for file in fitc_cfg.files }
    delta_from_fitc_cfg(overridable, fitc_files, args.output)
else:
    # If there is no fitc we must have a /home
    if not sysvol.getFile(HOME_IDX):
        raise Error("MFS has no fitc.cfg or home directory, please provide an image with valid config data")
    # Build lookup table from files in home in /home
    home_files = { path: data for path, data in sysvol.listDir(HOME_IDX, True, "/home") }
    delta_from_home(overridable, home_files, args.output)
