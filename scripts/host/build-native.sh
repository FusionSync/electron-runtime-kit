#!/bin/bash
set -euo pipefail
arch=${1:?Usage: build-native.sh x64|arm64}
case "$arch" in
  x64) triple=x86_64; vips_arch=x64; export CC=gcc CXX=g++ AR=ar STRIP=strip ;;
  arm64) triple=aarch64; vips_arch=arm64v8; export CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++ AR=aarch64-linux-gnu-ar STRIP=aarch64-linux-gnu-strip ;;
  *) exit 2 ;;
esac
export npm_config_arch="$arch" npm_config_platform=linux npm_config_build_from_source=true
export PYTHON=/usr/bin/python3 MAKEFLAGS=-j2 CMAKE_BUILD_PARALLEL_LEVEL=2
export SHARP_IGNORE_GLOBAL_LIBVIPS=1
root=/work/build/$arch
rm -rf "$root"
mkdir -p "$root"
cp /work/dependencies/package.json /work/dependencies/package-lock.json "$root/"
cp -a /work/dependencies/node_modules "$root/"
node_gyp=/opt/node/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js
cd "$root/node_modules/node-pty"
node "$node_gyp" rebuild --nodedir=/opt/node --arch="$arch" --jobs=2
"$STRIP" build/Release/pty.node
cd "$root/node_modules/sharp"
python3 /repo/scripts/host/prepare-sharp-vendor.py "$arch"
node "$node_gyp" rebuild --nodedir=/opt/node --arch="$arch" --jobs=2
command -v patchelf >/dev/null || { echo 'patchelf is required to set sharp relative RPATH' >&2; exit 2; }
sharp_platform="linux-$arch"
[[ "$arch" == arm64 ]] && sharp_platform=linux-arm64v8
patchelf --force-rpath --set-rpath "\$ORIGIN/../../vendor/8.14.5/$sharp_platform/lib" \
  "build/Release/sharp-$sharp_platform.node"
cd "$root/node_modules/koffi"
node cnoke.cjs -P . -D src/koffi --release --toolchain "linux_$arch" \
  -d CMAKE_SYSTEM_NAME=Linux -d CMAKE_SYSTEM_PROCESSOR="$triple" \
  -d CMAKE_C_COMPILER="/work/docker/zig-cc-$arch" \
  -d CMAKE_CXX_COMPILER="/work/docker/zig-cxx-$arch" \
  -d CMAKE_ASM_COMPILER="/work/docker/zig-cc-$arch" \
  -d CMAKE_STRIP="/usr/bin/$STRIP"
