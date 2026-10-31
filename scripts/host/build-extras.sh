#!/usr/bin/env bash
set -euo pipefail

arch=${1:?Usage: build-extras.sh x64|arm64 EXTRA_ROOT BUILD_ROOT}
extra_root=${2:?Usage: build-extras.sh x64|arm64 EXTRA_ROOT BUILD_ROOT}
build_root=${3:?Usage: build-extras.sh x64|arm64 EXTRA_ROOT BUILD_ROOT}
case "$arch" in x64|arm64) ;; *) echo "unsupported architecture: $arch" >&2; exit 2 ;; esac

source_root="$extra_root/native-sources"
landlock_source="$source_root/landlock-run"
ripgrep_source="$source_root/ripgrep"
sherpa_source="$source_root/sherpa-onnx"
koffi_platform="$source_root/koffi-platform-$arch"
[[ -d "$koffi_platform" ]] || koffi_platform="$source_root/koffi-platform"
landlock_wrapper="$source_root/landlock-wrapper"
landlock_platform="$source_root/landlock-platform-$arch"
[[ -d "$landlock_platform" ]] || landlock_platform="$source_root/landlock-platform"
ripgrep_wrapper="$source_root/ripgrep-wrapper"
ripgrep_platform="$source_root/ripgrep-platform-$arch"
[[ -d "$ripgrep_platform" ]] || ripgrep_platform="$source_root/ripgrep-platform"
sherpa_wrapper="$source_root/sherpa-wrapper"
onnx_root="$extra_root/onnxruntime/$arch"
onnx_headers="$extra_root/onnxruntime-headers"

for path in "$landlock_source/src/main.c" "$ripgrep_source/Cargo.toml" \
    "$sherpa_source/CMakeLists.txt" "$landlock_wrapper/package.json" \
    "$landlock_platform/package.json" "$ripgrep_wrapper/package.json" \
    "$ripgrep_platform/package.json" "$sherpa_wrapper/package.json" \
    "$koffi_platform/package.json" \
    "$onnx_root" "$onnx_headers"; do
    [[ -e "$path" ]] || { echo "missing native extra input: $path" >&2; exit 2; }
done
command -v patchelf >/dev/null || { echo 'patchelf is required by the native package layout' >&2; exit 2; }

case "$arch" in
  x64)
    rust_target=x86_64-unknown-linux-gnu
    export CC=gcc CXX=g++ AR=ar STRIP=strip
    ;;
  arm64)
    rust_target=aarch64-unknown-linux-gnu
    export CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++
    export AR=aarch64-linux-gnu-ar STRIP=aarch64-linux-gnu-strip
    ;;
esac

node_headers=${NODE_HEADERS:-/opt/node}
node_include="$node_headers/include/node"
[[ -d "$node_include" ]] || { echo "missing Node headers: $node_include" >&2; exit 2; }
jobs=${NATIVE_JOBS:-2}
staging="$build_root/node_modules"
mkdir -p "$staging/@deepseek-ai" "$staging/@vscode"
rm -rf "$staging/@deepseek-ai/node-addon-landlock-run" \
    "$staging/@deepseek-ai/node-addon-landlock-run-$arch" \
    "$staging/@vscode/ripgrep" "$staging/@vscode/ripgrep-$arch" \
    "$staging/@koromix/koffi-linux-$arch" "$staging/sherpa-onnx-linux-$arch"
mkdir -p "$staging/@koromix/koffi-linux-$arch"
cp -a "$koffi_platform/." "$staging/@koromix/koffi-linux-$arch/"

# landlock-run is deliberately static. It has no runtime GLIBC dependency.
mkdir -p "$staging/@deepseek-ai/node-addon-landlock-run"
mkdir -p "$staging/@deepseek-ai/node-addon-landlock-run-$arch/bin"
cp -a "$landlock_wrapper/." "$staging/@deepseek-ai/node-addon-landlock-run/"
cp -a "$landlock_platform/." "$staging/@deepseek-ai/node-addon-landlock-run-$arch/"
"$CC" -O2 -static "$landlock_source/src/main.c" \
    -o "$staging/@deepseek-ai/node-addon-landlock-run-$arch/bin/landlock-run"

# Keep the platform package metadata, but always replace its native payload
# with the binary built in this container.
mkdir -p "$staging/@koromix/koffi-linux-$arch/linux_$arch"
cp "$build_root/node_modules/koffi/build/koffi/linux_$arch/koffi.node" \
    "$staging/@koromix/koffi-linux-$arch/linux_$arch/koffi.node"

# The wrapper is @vscode/ripgrep; the Rust project only supplies bin/rg.
ripgrep_cargo=${RIPGREP_CARGO:-cargo}
ripgrep_config=${RIPGREP_CARGO_CONFIG:-}
ripgrep_rustc=${RIPGREP_RUSTC:-}
ripgrep_rustdoc=${RIPGREP_RUSTDOC:-}
command -v "$ripgrep_cargo" >/dev/null || { echo "missing cargo: $ripgrep_cargo" >&2; exit 2; }
[[ -z "$ripgrep_config" || -f "$ripgrep_config" ]] || { echo "missing cargo config: $ripgrep_config" >&2; exit 2; }
[[ -z "$ripgrep_rustc" || -x "$ripgrep_rustc" ]] || { echo "missing rustc: $ripgrep_rustc" >&2; exit 2; }
[[ -z "$ripgrep_rustdoc" || -x "$ripgrep_rustdoc" ]] || { echo "missing rustdoc: $ripgrep_rustdoc" >&2; exit 2; }
if [[ -n "$ripgrep_rustc" ]]; then export RUSTC="$ripgrep_rustc"; fi
if [[ -n "$ripgrep_rustdoc" ]]; then export RUSTDOC="$ripgrep_rustdoc"; fi
[[ -d "${CARGO_HOME:-}" ]] || { echo 'CARGO_HOME with the pinned Rust crates is required' >&2; exit 2; }
export CARGO_BUILD_TARGET="$rust_target"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$build_root/ripgrep-target-$arch}"
export RUSTFLAGS="${RUSTFLAGS:--C linker=$CC}"
cargo_args=(--locked --release --features pcre2 --target "$rust_target")
if [[ -n "$ripgrep_config" ]]; then cargo_args=(--config "$ripgrep_config" "${cargo_args[@]}"); fi
(cd "$ripgrep_source" && "$ripgrep_cargo" "${cargo_args[@]}")
mkdir -p "$staging/@vscode/ripgrep-$arch/bin"
mkdir -p "$staging/@vscode/ripgrep"
cp -a "$ripgrep_wrapper/." "$staging/@vscode/ripgrep/"
cp -a "$ripgrep_platform/." "$staging/@vscode/ripgrep-$arch/"
cp "$CARGO_TARGET_DIR/$rust_target/release/rg" "$staging/@vscode/ripgrep-$arch/bin/rg"

# Build sherpa's C++ library and then its Node-API addon against the same
# prebuilt ONNX Runtime. The latter is intentionally an explicit input: the
# build must never silently download a different runtime for another ABI.
onnx_stage=/tmp/onnxruntime-$arch
rm -rf "$onnx_stage"
mkdir -p "$onnx_stage/lib" "$onnx_stage/include"
cp -a "$onnx_headers/." "$onnx_stage/include/"
onnx_lib=$(find "$onnx_root" -maxdepth 2 -type f -name 'libonnxruntime.so*' | sort | head -n1)
[[ -n "$onnx_lib" ]] || { echo "missing libonnxruntime.so in $onnx_root" >&2; exit 2; }
cp -a "$onnx_root/lib"/libonnxruntime.so* "$onnx_stage/lib/" 2>/dev/null || cp "$onnx_lib" "$onnx_stage/lib/"
if [[ ! -e "$onnx_stage/lib/libonnxruntime.so" ]]; then
    ln -s "$(basename "$onnx_lib")" "$onnx_stage/lib/libonnxruntime.so"
fi
cp -a "$onnx_root/lib"/libonnxruntime_providers_shared.so* "$onnx_stage/lib/" 2>/dev/null || true
header_dir=$(dirname "$(find "$onnx_stage/include" -name onnxruntime_cxx_api.h -print -quit)")
[[ -n "$header_dir" && -f "$header_dir/onnxruntime_cxx_api.h" ]] || {
    echo "onnxruntime_cxx_api.h was not found under $onnx_headers" >&2; exit 2;
}
export SHERPA_ONNXRUNTIME_INCLUDE_DIR="$header_dir"
export SHERPA_ONNXRUNTIME_LIB_DIR="$onnx_stage/lib"

sherpa_build=/tmp/sherpa-$arch
sherpa_install="$sherpa_build/install"
rm -rf "$sherpa_build"
if [[ -d "${SHERPA_DEPS_CACHE:-}" ]]; then
    mkdir -p "$sherpa_build/_deps"
    cp -a "$SHERPA_DEPS_CACHE/." "$sherpa_build/_deps/"
fi
[[ -d "$sherpa_build/_deps" && -n "$(find "$sherpa_build/_deps" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
    echo 'sherpa-deps-cache is required; provide pre-fetched CMake FetchContent dependencies' >&2
    exit 2
}
cmake_args=(-S "$sherpa_source" -B "$sherpa_build" -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$sherpa_install" -DBUILD_SHARED_LIBS=ON
  -DSHERPA_ONNX_ENABLE_PYTHON=OFF -DSHERPA_ONNX_ENABLE_TESTS=OFF
  -DSHERPA_ONNX_ENABLE_CHECK=OFF -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF
  -DSHERPA_ONNX_ENABLE_JNI=OFF -DSHERPA_ONNX_ENABLE_C_API=ON
  -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF -DSHERPA_ONNX_ENABLE_GPU=OFF
  -DSHERPA_ONNX_ENABLE_TTS=ON -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=ON
  -DSHERPA_ONNX_LINK_LIBSTDCPP_STATICALLY=ON
  -DSHERPA_ONNX_USE_PRE_INSTALLED_ONNXRUNTIME_IF_AVAILABLE=ON)
if [[ -d "${SHERPA_DEPS_CACHE:-}" ]]; then
    cmake_args+=( -DFETCHCONTENT_FULLY_DISCONNECTED=ON )
fi
if [[ "$arch" == arm64 ]]; then
    cmake_args+=( -DCMAKE_TOOLCHAIN_FILE="$sherpa_source/toolchains/aarch64-linux-gnu.toolchain.cmake" )
fi
cmake "${cmake_args[@]}"
cmake --build "$sherpa_build" --parallel "$jobs"
cmake --install "$sherpa_build"

addon_api=${SHERPA_NODE_ADDON_API:-$sherpa_source/scripts/node-addon-api/node_modules/node-addon-api}
[[ -f "$addon_api/napi.h" ]] || { echo "missing node-addon-api headers: $addon_api" >&2; exit 2; }
addon_cmake=/tmp/sherpa-addon-$arch.CMakeLists.txt
cat > "$addon_cmake" <<EOF
cmake_minimum_required(VERSION 3.15)
project(sherpa_node_addon LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
file(GLOB addon_sources CONFIGURE_DEPENDS "$sherpa_source/scripts/node-addon-api/src/*.cc")
add_library(sherpa-onnx SHARED \${addon_sources})
target_compile_definitions(sherpa-onnx PRIVATE BUILDING_NODE_EXTENSION)
target_include_directories(sherpa-onnx PRIVATE "$node_include" "$addon_api" "$sherpa_install/include")
set_target_properties(sherpa-onnx PROPERTIES PREFIX "" SUFFIX ".node" BUILD_RPATH "\$ORIGIN" INSTALL_RPATH "\$ORIGIN")
target_link_libraries(sherpa-onnx PRIVATE "$sherpa_install/lib/libsherpa-onnx-c-api.so" "$onnx_stage/lib/libonnxruntime.so")
install(TARGETS sherpa-onnx DESTINATION .)
EOF
addon_source_dir=/tmp/sherpa-addon-source-$arch
rm -rf "$addon_source_dir"
mkdir -p "$addon_source_dir"
cp "$addon_cmake" "$addon_source_dir/CMakeLists.txt"
addon_build=/tmp/sherpa-addon-build-$arch
rm -rf "$addon_build"
addon_args=(-S "$addon_source_dir" -B "$addon_build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$addon_build/install")
if [[ "$arch" == arm64 ]]; then addon_args+=( -DCMAKE_TOOLCHAIN_FILE="$sherpa_source/toolchains/aarch64-linux-gnu.toolchain.cmake" ); fi
cmake "${addon_args[@]}"
cmake --build "$addon_build" --parallel "$jobs"
cmake --install "$addon_build"

sherpa_target="$staging/sherpa-onnx-linux-$arch"
rm -rf "$sherpa_target"
mkdir -p "$sherpa_target"
cp -a "$sherpa_wrapper/." "$sherpa_target/"
cp "$addon_build/install/sherpa-onnx.node" "$sherpa_target/"
cp "$sherpa_install/lib/libsherpa-onnx-c-api.so" "$sherpa_target/"
cp "$sherpa_install/lib/libsherpa-onnx-cxx-api.so" "$sherpa_target/"
cp -a "$onnx_stage/lib/libonnxruntime.so*" "$sherpa_target/"
cp -a "$onnx_stage/lib/libonnxruntime_providers_shared.so*" "$sherpa_target/" 2>/dev/null || true
for file in "$sherpa_target"/*.so* "$sherpa_target"/*.node; do
    [[ -e "$file" ]] || continue
    patchelf --set-rpath '$ORIGIN' "$file"
done
