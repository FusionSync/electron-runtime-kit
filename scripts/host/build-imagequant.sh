#!/bin/bash
set -euo pipefail
arch=${1:?Usage: build-imagequant.sh x64|arm64}
root=/work/research
stage="$root/imagequant-shared-$arch"
build="$root/imagequant-meson-$arch"
export PYTHONPATH="$root/tools/meson-0.61.5"
meson=(python3 -m mesonbuild.mesonmain)
cross_args=()
destdir=
case "$arch" in
  x64) prefix="$stage" ;;
  arm64)
    prefix=/usr
    destdir="$stage/staging"
    cross_args=(--cross-file "$root/vips-arm64-cross.ini")
    ;;
  *) exit 2 ;;
esac
mkdir -p "$stage/lib"
rm -f "$stage/lib/libimagequant.so" "$stage/lib/libimagequant.so.0"
"${meson[@]}" setup "$build" "$root/libimagequant-ce5fdeb1ccd9db288950faa21fd09c42c0a59bbb" \
  --buildtype=release --prefix="$prefix" --libdir=lib "${cross_args[@]}"
"${meson[@]}" compile -C "$build" -j2
DESTDIR="$destdir" "${meson[@]}" install -C "$build"
if [ "$arch" = arm64 ]; then
  cp -a "$destdir/usr/." "$stage/"
  rm -rf -- "$destdir"
fi
