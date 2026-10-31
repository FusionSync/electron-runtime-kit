#!/usr/bin/env python3
"""Audit runtime ELF files in a native-module node_modules directory."""
import argparse
import json
import os
import re
import subprocess
from pathlib import Path


def readelf(option, path):
    return subprocess.check_output(
        ['readelf', '--wide', option, str(path)], text=True, env={**os.environ, 'LC_ALL': 'C'}
    )


def version_key(value):
    return tuple(int(part) for part in value.split('.'))


def audit(path, root):
    requirements = {name: set() for name in ('GLIBC', 'GLIBCXX', 'CXXABI')}
    in_needs = False
    for line in readelf('--version-info', path).splitlines():
        if line.startswith('Version '):
            in_needs = line.startswith('Version needs section')
        if in_needs:
            for namespace, version in re.findall(r'Name: (GLIBC|GLIBCXX|CXXABI)_([0-9.]+)\b', line):
                requirements[namespace].add(version)
    maximums = {
        name: max(values, key=version_key) if values else None
        for name, values in requirements.items()
    }
    header = readelf('--file-header', path)
    dynamic = readelf('--dynamic', path)
    glibc = maximums['GLIBC']
    return {
        'path': str(path.relative_to(root)),
        'machine': re.search(r'^\s*Machine:\s*(.+)$', header, re.MULTILINE).group(1),
        'required_versions': maximums,
        'needed': re.findall(r'\(NEEDED\).*?\[([^]]+)\]', dynamic),
        'rpath': re.findall(r'\(RPATH\).*?\[([^]]*)\]', dynamic),
        'runpath': re.findall(r'\(RUNPATH\).*?\[([^]]*)\]', dynamic),
        'glibc_le_2_28': glibc is None or version_key(glibc) <= (2, 28),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('node_modules', type=Path)
    root = parser.parse_args().node_modules.resolve(strict=True)
    seen = set()
    files = []
    excluded = {'test', 'tests', 'obj', 'obj.target', 'CMakeFiles', 'Output'}
    for path in sorted(root.rglob('*')):
        parts = path.relative_to(root).parts
        if excluded.intersection(parts) or any(re.match(r'v\d+\.\d+\.\d+_', part) for part in parts):
            continue
        vendor_library = ('sharp', 'vendor') in tuple(zip(parts, parts[1:])) and '.so' in path.name
        if not (path.suffix == '.node' or vendor_library) or not path.is_file():
            continue
        info = path.stat()
        identity = (info.st_dev, info.st_ino)
        if identity in seen:
            continue
        with path.open('rb') as stream:
            if stream.read(4) != b'\x7fELF':
                continue
        seen.add(identity)
        files.append(audit(path, root))
    passed = bool(files) and all(item['glibc_le_2_28'] for item in files)
    print(json.dumps({'root': str(root), 'glibc_limit': '2.28', 'passed': passed, 'files': files}, indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
