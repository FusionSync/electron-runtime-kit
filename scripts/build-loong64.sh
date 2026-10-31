#!/usr/bin/env bash
set -euo pipefail

toolchain_root=${1:-${LOONG_TOOLCHAIN_ROOT:-/home/ubuntu/uos-loongarch64-cross}}
output=${2:-${NATIVE_OUTPUT_ROOT:-$PWD/dist}}
image=${3:-${LOONG_IMAGE:-electron-loong64:gcc8-oldabi}}
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
[[ -d "$toolchain_root" ]] || { echo "missing toolchain root: $toolchain_root" >&2; exit 2; }
docker image inspect "$image" >/dev/null 2>&1 || {
    echo "Docker image $image is missing. Build it from FusionSync/electron-loong64 toolchain-v1." >&2
    exit 2
}
mkdir -p "$output"
# Inputs are mounted at /work. Host paths must live below toolchain_root; the
# helper converts them to their container path before docker run.
container_path() {
    local path=$1
    if [[ "$path" == /work/* || "$path" == /opt/* ]]; then
        printf '%s\n' "$path"
    elif [[ "$path" == "$toolchain_root"/* ]]; then
        printf '/work/%s\n' "${path#"$toolchain_root"/}"
    else
        echo "path must be under $toolchain_root (or already be a container path): $path" >&2
        exit 2
    fi
}
source_root=${LOONG_SOURCE_ROOT:-$toolchain_root/native-sources}
mkdir -p "$source_root"
node_pty_source=$(container_path "${NODE_PTY_SOURCE:-$source_root/node-pty}")
sharp_source=$(container_path "${SHARP_SOURCE:-$source_root/sharp}")
koffi_source=$(container_path "${KOFFI_SOURCE:-$source_root/koffi}")
koffi_platform_source=$(container_path "${KOFFI_PLATFORM_SOURCE:-$source_root/koffi-platform}")
landlock_source=$(container_path "${LANDLOCK_SOURCE:-$source_root/landlock-run}")
landlock_wrapper=$(container_path "${LANDLOCK_WRAPPER:-$source_root/node-addon-landlock-run}")
landlock_platform=$(container_path "${LANDLOCK_PLATFORM:-$source_root/node-addon-landlock-run-platform-loong64}")
ripgrep_source=$(container_path "${RIPGREP_SOURCE:-$source_root/ripgrep}")
ripgrep_wrapper=$(container_path "${RIPGREP_WRAPPER:-$source_root/ripgrep-wrapper}")
ripgrep_platform=$(container_path "${RIPGREP_PLATFORM:-$source_root/ripgrep-platform-loong64}")
sherpa_source=$(container_path "${SHERPA_SOURCE:-$source_root/sherpa-onnx}")
sherpa_wrapper=$(container_path "${SHERPA_WRAPPER:-$source_root/sherpa-wrapper}")
onnxruntime_root=$(container_path "${ONNXRUNTIME_ROOT:-$toolchain_root/onnxruntime-loong64}")
onnxruntime_headers=$(container_path "${ONNXRUNTIME_HEADERS:-$toolchain_root/onnxruntime-headers}")
sharp_vendor_root=$(container_path "${SHARP_VENDOR_ROOT:-$source_root/sharp-vendor}")
rust_bin=$(container_path "${RUST_BIN:-$toolchain_root/electron37-attempt/tools/rust188/bin}")
cargo_bin=$(container_path "${CARGO_BIN:-$toolchain_root/electron37-attempt/src/third_party/rust-toolchain/bin/cargo}")
cargo_config=$(container_path "${CARGO_CONFIG:-$toolchain_root/cargo-config/config.toml}")
sherpa_deps_cache=$(container_path "${SHERPA_DEPS_CACHE:-$toolchain_root/sherpa-deps-cache}")
cargo_home=$(container_path "${CARGO_HOME:-$toolchain_root/cargo-home}")
cargo_target_dir=$(container_path "${CARGO_TARGET_DIR:-$toolchain_root/ripgrep-target}")
loong_linker=$(container_path "${LOONG_LINKER:-/opt/loongson/bin/loongarch64-linux-gnu-gcc}")
loong_cmake_toolchain=$(container_path "${LOONG_CMAKE_TOOLCHAIN_FILE:-/opt/uos-cross/uos20-loongarch64.cmake}")

docker run --rm -i --user "$(id -u):$(id -g)" --cpus "${LOONG_CPUS:-8}" \
    --memory "${LOONG_MEMORY:-24g}" --network "${LOONG_NETWORK:-none}" \
    -v "$repo:/repo:ro" -v "$toolchain_root:/work" -v "$output:/artifacts" \
    -e NODE_PTY_SOURCE="$node_pty_source" \
    -e SHARP_SOURCE="$sharp_source" \
    -e KOFFI_SOURCE="$koffi_source" \
    -e KOFFI_PLATFORM_SOURCE="$koffi_platform_source" \
    -e LANDLOCK_SOURCE="$landlock_source" \
    -e LANDLOCK_WRAPPER="$landlock_wrapper" \
    -e LANDLOCK_PLATFORM="$landlock_platform" \
    -e RIPGREP_SOURCE="$ripgrep_source" \
    -e RIPGREP_WRAPPER="$ripgrep_wrapper" \
    -e RIPGREP_PLATFORM="$ripgrep_platform" \
    -e SHERPA_SOURCE="$sherpa_source" \
    -e SHERPA_WRAPPER="$sherpa_wrapper" \
    -e ONNXRUNTIME_ROOT="$onnxruntime_root" \
    -e ONNXRUNTIME_HEADERS="$onnxruntime_headers" \
    -e NODE_HEADERS="${NODE_HEADERS:-/opt/node}" \
    -e SHARP_VENDOR_ROOT="$sharp_vendor_root" \
    -e RUST_BIN="$rust_bin" \
    -e CARGO_BIN="$cargo_bin" \
    -e CARGO_CONFIG="$cargo_config" \
    -e SHERPA_DEPS_CACHE="$sherpa_deps_cache" \
    -e CARGO_HOME="$cargo_home" \
    -e CARGO_TARGET_DIR="$cargo_target_dir" \
    -e LOONG_LINKER="$loong_linker" \
    -e LOONG_CMAKE_TOOLCHAIN_FILE="$loong_cmake_toolchain" \
    -e LOONG_JOBS="${LOONG_JOBS:-2}" \
    -w /work "$image" bash /repo/scripts/loong64-inner.sh /artifacts
