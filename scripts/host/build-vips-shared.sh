#!/bin/bash
set -euo pipefail
arch=${1:?Usage: build-vips-shared.sh x64|arm64}
root=/work/research
export PYTHONPATH="$root/tools/meson-0.61.5"
meson=(python3 -m mesonbuild.mesonmain)
stage="$root/vips-shared-$arch"
mkdir -p "$stage"
cross_args=()
destdir=
case "$arch" in
  x64)
    prefix="$stage"
    export PKG_CONFIG_PATH="$stage/lib/pkgconfig"
    ;;
  arm64)
    sysroot="$root/vips-sysroot-arm64"
    prefix=/usr
    destdir="$stage"
    cat > "$root/vips-arm64-cross.ini" <<EOF
[binaries]
c = 'aarch64-linux-gnu-gcc'
cpp = 'aarch64-linux-gnu-g++'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'
pkgconfig = 'pkg-config'
[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_args = ['-I$sysroot/usr/include']
cpp_args = ['-I$sysroot/usr/include']
c_link_args = ['-Wl,-rpath-link,$sysroot/usr/lib/aarch64-linux-gnu', '-Wl,-rpath-link,$sysroot/lib/aarch64-linux-gnu']
cpp_link_args = ['-Wl,-rpath-link,$sysroot/usr/lib/aarch64-linux-gnu', '-Wl,-rpath-link,$sysroot/lib/aarch64-linux-gnu']
EOF
    cross_args=(--cross-file "$root/vips-arm64-cross.ini")
    export PKG_CONFIG_SYSROOT_DIR="$sysroot"
    export PKG_CONFIG_LIBDIR="$sysroot/usr/lib/aarch64-linux-gnu/pkgconfig:$sysroot/usr/lib/pkgconfig:$sysroot/usr/share/pkgconfig"
    unset PKG_CONFIG_PATH
    ;;
  *) exit 2 ;;
esac
bash /repo/scripts/host/build-imagequant.sh "$arch"
if [ "$arch" = arm64 ]; then
  cp -a "$root/imagequant-shared-$arch/." "$stage/usr/"
  cp -a "$root/imagequant-shared-$arch/." "$sysroot/usr/"
else
  cp -a "$root/imagequant-shared-$arch/." "$stage/"
fi
"${meson[@]}" setup "$root/cgif-build-$arch" "$root/cgif-0.3.2" \
  --buildtype=release --prefix="$prefix" --libdir=lib -Dtests=false "${cross_args[@]}"
"${meson[@]}" compile -C "$root/cgif-build-$arch" -j 2
DESTDIR="$destdir" "${meson[@]}" install -C "$root/cgif-build-$arch"
if [ "$arch" = arm64 ]; then
  cp -a "$stage/usr/." "$sysroot/usr/"
fi
"${meson[@]}" setup "$root/vips-build-$arch" "$root/vips-8.14.5" \
  --buildtype=release --prefix="$prefix" --libdir=lib --auto-features=disabled \
  -Dmodules=disabled -Dintrospection=false -Dexamples=false \
  -Djpeg=enabled -Dpng=enabled -Dwebp=enabled -Dtiff=enabled -Drsvg=enabled \
  -Dcgif=enabled -Dimagequant=enabled -Dexif=enabled -Dlcms=enabled -Dzlib=enabled "${cross_args[@]}"
"${meson[@]}" compile -C "$root/vips-build-$arch" -j 2
DESTDIR="$destdir" "${meson[@]}" install -C "$root/vips-build-$arch"
