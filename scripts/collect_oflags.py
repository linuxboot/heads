#!/usr/bin/env python3
"""collect_oflags.py
Scan build logs for -O flags and write a CSV summary.

Usage:
  ./scripts/collect_oflags.py [--out FILE]

Produces lines: module,O,Os,O2,O3,Oz,total,examples
"""

import argparse
import os
import re
from collections import defaultdict

def module_from_path(p):
    # If path contains /log/, use basename without .log
    if '/log/' in p:
        name = os.path.splitext(os.path.basename(p))[0]
    else:
        parts = p.split(os.sep)
        try:
            bi = parts.index('build')
            name = parts[bi+2] if len(parts) > bi+2 else os.path.basename(os.path.dirname(p))
        except ValueError:
            name = os.path.basename(os.path.dirname(p))
    m = re.match(r'(.+)-([0-9].*)$', name)
    if m:
        return m.group(1)
    m = re.match(r'(.+)-([0-9a-f]{8,})$', name)
    if m:
        return m.group(1)
    return name

def scan(root='build'):
    # Use token-aware regex matches to avoid false positives (e.g., '-os' CLI
    # options or lowercase '-os' in source strings). Match only uppercase 'O'
    # followed by the expected suffix and ensure the flag is a separate token.
    regexes = {
        'O2': re.compile(rb'(?<![A-Za-z0-9_-])\-O2(?![A-Za-z0-9_-])'),
        'O3': re.compile(rb'(?<![A-Za-z0-9_-])\-O3(?![A-Za-z0-9_-])'),
        'Os': re.compile(rb'(?<![A-Za-z0-9_-])\-Os(?![A-Za-z0-9_-])'),
        'Oz': re.compile(rb'(?<![A-Za-z0-9_-])\-Oz(?![A-Za-z0-9_-])'),
        # Generic -O that is not -O2/-O3/-Os/-Oz
        'O': re.compile(rb'(?<![A-Za-z0-9_-])\-O(?![0-9sSzZA-Za-z0-9_-])'),
    }
    counts = defaultdict(lambda: {'O':0,'Os':0,'O2':0,'O3':0,'Oz':0,'paths':[]})
    for dirpath, _, filenames in os.walk(root):
        for fn in filenames:
            if not (fn.endswith('.log') or fn == 'config.log'):
                continue
            fp = os.path.join(dirpath, fn)
            try:
                with open(fp, 'rb') as fh:
                    b = fh.read()
            except Exception:
                continue
            # Quick reject: if none of the uppercase patterns exist in the file, skip
            if not any(p in b for p in [b'-O2', b'-O3', b'-Os', b'-Oz', b'-O']):
                continue
            mod = module_from_path(fp)
            cO2 = len(regexes['O2'].findall(b))
            cO3 = len(regexes['O3'].findall(b))
            cOs = len(regexes['Os'].findall(b))
            cOz = len(regexes['Oz'].findall(b))
            cO = len(regexes['O'].findall(b))
            counts[mod]['O'] += cO
            counts[mod]['Os'] += cOs
            counts[mod]['O2'] += cO2
            counts[mod]['O3'] += cO3
            counts[mod]['Oz'] += cOz
            counts[mod]['paths'].append(fp)
    return counts

def write_csv(counts, out):
    with open(out, 'w') as f:
        f.write('module,O,Os,O2,O3,Oz,total,examples\n')
        rows = []
        for mod, v in counts.items():
            total = v['O'] + v['Os'] + v['O2'] + v['O3'] + v['Oz']
            if total == 0:
                continue
            rows.append((total, mod, v))
        rows.sort(reverse=True)
        for total, mod, v in rows:
            ex = ';'.join(v['paths'][:3])
            f.write(f'{mod},{v["O"]},{v["Os"]},{v["O2"]},{v["O3"]},{v["Oz"]},{total},{ex}\n')

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--out', '-o', default='build_oflags_summary.csv', help='Output CSV file')
    p.add_argument('--root', default='build', help='Build tree root to scan')
    args = p.parse_args()
    counts = scan(args.root)
    write_csv(counts, args.out)
    print(f'Wrote {args.out} (modules with non-zero -O counts)')

if __name__ == '__main__':
    main()
