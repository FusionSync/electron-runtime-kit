#!/usr/bin/env python3
"""Run inside the builder: package shared libvips and its image/GLib dependencies."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

arch = sys.argv[1]
triple = {'x64': 'x86_64-linux-gnu', 'arm64': 'aarch64-linux-gnu'}[arch]
platform = 'linux-' + ('arm64v8' if arch == 'arm64' else arch)
work = Path('/work')
prefix = work / 'research' / ('vips-shared-' + arch)
sysroot = Path('/') if arch == 'x64' else work / 'research/vips-sysroot-arm64'
vendor = work / 'build' / arch / 'node_modules/sharp/vendor/8.14.5' / platform
# libvips installs may use a /usr prefix with DESTDIR for cross compilation.
if not (prefix / 'include/vips').exists():
    prefix = prefix / 'usr'
if vendor.exists():
    shutil.rmtree(vendor)
shutil.copytree(prefix / 'include', vendor / 'include')
shutil.copytree(sysroot / 'usr/include/glib-2.0', vendor / 'include/glib-2.0')
shutil.copytree(sysroot / ('usr/lib/' + triple + '/glib-2.0/include'), vendor / 'lib/glib-2.0/include')
search = [prefix / 'lib', prefix / ('lib/' + triple), work / 'research' / ('imagequant-shared-' + arch) / 'lib', sysroot / ('usr/lib/' + triple), sysroot / ('lib/' + triple)]
system_runtime = {'libc.so.6', 'libm.so.6', 'libpthread.so.0', 'libdl.so.2', 'librt.so.1', 'libutil.so.1', 'libresolv.so.2', 'libgcc_s.so.1', 'libstdc++.so.6', 'ld-linux-x86-64.so.2', 'ld-linux-aarch64.so.1'}
queue = ['libvips-cpp.so.42']
seen = set()
while queue:
    name = queue.pop()
    if name in seen or name in system_runtime:
        continue
    seen.add(name)
    source = next((directory / name for directory in search if (directory / name).exists()), None)
    if source is None:
        raise RuntimeError('Missing shared library: ' + name)
    target = vendor / 'lib' / name
    shutil.copy2(str(source.resolve()), str(target))
    dynamic = subprocess.check_output(['readelf', '--dynamic', str(target)], universal_newlines=True)
    queue.extend(re.findall(r'\(NEEDED\).*?\[([^]]+)\]', dynamic))
    subprocess.check_call(['patchelf', '--force-rpath', '--set-rpath', '$ORIGIN', str(target)])
(vendor / 'platform.json').write_text(json.dumps(platform) + '\n')
(vendor / 'versions.json').write_text(json.dumps({'vips': '8.14.5', 'glib': '2.56.4', 'cgif': '0.3.2', 'imagequant': '2.4.1'}, indent=2) + '\n')
(vendor / 'runtime-libraries.json').write_text(json.dumps(sorted(seen), indent=2) + '\n')
print(vendor)

licenses = vendor / 'licenses'
licenses.mkdir()
for copyright_file in (sysroot / 'usr/share/doc').glob('*/copyright'):
    if copyright_file.is_file():
        shutil.copy2(str(copyright_file), str(licenses / (copyright_file.parent.name + '.copyright')))
for component, filename in [('vips-8.14.5', 'COPYING'), ('cgif-0.3.2', 'LICENSE'), ('libimagequant-2.4.1', 'COPYRIGHT')]:
    notice = work / 'research' / component / filename
    if notice.is_file():
        shutil.copy2(str(notice), str(licenses / (component + '.txt')))

for notice in (work / 'research/vips-shared-licenses').iterdir():
    if notice.is_file():
        shutil.copy2(str(notice), str(licenses / notice.name))
