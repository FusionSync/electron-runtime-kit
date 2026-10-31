#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/build.sh [options]

Build native dependencies in the pinned Docker environments.

Options:
  --arch ARCH              x64, arm64, loong64, or all (default: all)
  --build-root DIR         Existing x64/arm64 build workspace
  --extra-root DIR         Prepared landlock/ripgrep/sherpa input workspace
  --loong-root DIR         Loong64 toolchain workspace
  --output DIR             Release archive directory (default: ./dist)
  --host-image IMAGE       Ubuntu18.04 builder image
  --loong-image IMAGE      Loong64 GCC8 old-ABI image
  --help
USAGE
}

arch=all
build_root=${NATIVE_BUILD_ROOT:-/home/ubuntu/electron37-native-build}
extra_root=${NATIVE_EXTRA_ROOT:-}
loong_root=${LOONG_TOOLCHAIN_ROOT:-/home/ubuntu/uos-loongarch64-cross}
output=${NATIVE_OUTPUT_ROOT:-$(pwd)/dist}
host_image=${NATIVE_HOST_IMAGE:-electron37-native-builder:ubuntu18.04}
loong_image=${LOONG_IMAGE:-electron-loong64:gcc8-oldabi}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) arch=${2:?missing value for --arch}; shift 2 ;;
        --build-root) build_root=${2:?missing value for --build-root}; shift 2 ;;
        --extra-root) extra_root=${2:?missing value for --extra-root}; shift 2 ;;
        --loong-root) loong_root=${2:?missing value for --loong-root}; shift 2 ;;
        --output) output=${2:?missing value for --output}; shift 2 ;;
        --host-image) host_image=${2:?missing value for --host-image}; shift 2 ;;
        --loong-image) loong_image=${2:?missing value for --loong-image}; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
case "$arch" in
    x64|arm64) "$script_dir/build-host.sh" "$arch" "$build_root" "$output" "$host_image" "$extra_root" ;;
    loong64) "$script_dir/build-loong64.sh" "$loong_root" "$output" "$loong_image" ;;
    all)
        "$script_dir/build-host.sh" x64 "$build_root" "$output" "$host_image" "$extra_root"
        "$script_dir/build-host.sh" arm64 "$build_root" "$output" "$host_image" "$extra_root"
        "$script_dir/build-loong64.sh" "$loong_root" "$output" "$loong_image"
        ;;
    *) echo "unsupported architecture: $arch" >&2; usage >&2; exit 2 ;;
esac
