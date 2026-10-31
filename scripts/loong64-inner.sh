#!/usr/bin/env bash
set -euo pipefail
output=${1:?output directory is required}
for variable in NODE_PTY_SOURCE SHARP_SOURCE KOFFI_SOURCE KOFFI_PLATFORM_SOURCE LANDLOCK_SOURCE LANDLOCK_WRAPPER LANDLOCK_PLATFORM RIPGREP_SOURCE RIPGREP_WRAPPER RIPGREP_PLATFORM SHERPA_SOURCE SHERPA_WRAPPER ONNXRUNTIME_ROOT ONNXRUNTIME_HEADERS; do
    value=${!variable:-}
    [[ -n "$value" && -e "$value" ]] || { echo "missing $variable=$value" >&2; exit 2; }
done
[[ -f "$LANDLOCK_SOURCE/src/main.c" ]] || { echo "missing landlock source: $LANDLOCK_SOURCE/src/main.c" >&2; exit 2; }
[[ -f "$RIPGREP_SOURCE/Cargo.toml" ]] || { echo "missing ripgrep source: $RIPGREP_SOURCE/Cargo.toml" >&2; exit 2; }
cmake_toolchain=${LOONG_CMAKE_TOOLCHAIN_FILE:-/opt/uos-cross/uos20-loongarch64.cmake}
[[ -f "$cmake_toolchain" ]] || { echo "missing Loong CMake toolchain: $cmake_toolchain" >&2; exit 2; }
export CC=uos-cc CXX=uos-c++ AR=loongarch64-linux-gnu-ar RANLIB=loongarch64-linux-gnu-ranlib STRIP=loongarch64-linux-gnu-strip
export npm_config_platform=linux npm_config_arch=loong64 npm_config_build_from_source=true npm_config_ignore_scripts=true
node_headers=${NODE_HEADERS:-/opt/node}
[[ -d "$node_headers/include/node" ]] || { echo "missing Node headers: $node_headers/include/node" >&2; exit 2; }
node_gyp=/opt/node/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js
command -v patchelf >/dev/null || { echo 'patchelf is required by the native package layout' >&2; exit 2; }

toolchain_root=${LOONG_TOOLCHAIN_ROOT:-/opt/loongson}
rust_bin=${RUST_BIN:-/work/tools/rust188/bin}
cargo_bin=${CARGO_BIN:-/work/tools/rust188/bin/cargo}
cargo_config=${CARGO_CONFIG:-/work/cargo-config/config.toml}
linker=${LOONG_LINKER:-$toolchain_root/bin/loongarch64-linux-gnu-gcc}
[[ -x "$linker" ]] || { echo "missing Loong linker: $linker" >&2; exit 2; }
[[ -x "$cargo_bin" && -x "$rust_bin/rustc" && -f "$cargo_config" ]] || {
    echo "ripgrep requires Rust 1.88, cargo and cargo config; set RUST_BIN, CARGO_BIN and CARGO_CONFIG" >&2
    exit 2
}
export CARGO_HOME="${CARGO_HOME:-/work/cargo-home}"
[[ -d "$CARGO_HOME" ]] || { echo "missing CARGO_HOME: $CARGO_HOME" >&2; exit 2; }
export RUSTC="$rust_bin/rustc" RUSTDOC="$rust_bin/rustdoc" RUSTUP_TOOLCHAIN=none
export PATH="$rust_bin:$PATH" CARGO_BUILD_TARGET=loongarch64-unknown-linux-gnu
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/ripgrep-target}"
export RUSTFLAGS="${RUSTFLAGS:--C linker=$linker}"

# Node-API modules use the UOS GCC 8.3 compiler and the /opt/node headers.
node "$node_gyp" rebuild --directory "$NODE_PTY_SOURCE" --nodedir="$NODE_HEADERS" --arch=loong64
[[ -n "${SHARP_VENDOR_ROOT:-}" && -d "$SHARP_VENDOR_ROOT" ]] || {
    echo 'SHARP_VENDOR_ROOT must point to the prepared libvips 8.14.5 vendor tree' >&2; exit 2;
}
mkdir -p "$SHARP_SOURCE/vendor/8.14.5"
cp -a "$SHARP_VENDOR_ROOT/." "$SHARP_SOURCE/vendor/8.14.5/"
node "$node_gyp" rebuild --directory "$SHARP_SOURCE" --nodedir="$NODE_HEADERS" --arch=loong64
node "$KOFFI_SOURCE/cnoke.cjs" -P "$KOFFI_SOURCE" -D src/koffi --release \
    --toolchain linux_loong64 -d CMAKE_SYSTEM_NAME=Linux -d CMAKE_SYSTEM_PROCESSOR=loongarch64
[[ -f "$KOFFI_PLATFORM_SOURCE/package.json" ]] || { echo "missing Koffi platform package: $KOFFI_PLATFORM_SOURCE" >&2; exit 2; }

# landlock-run is a static C launcher. The source package contains src/main.c.
mkdir -p /tmp/landlock-bin
uos-cc -O2 -static "$LANDLOCK_SOURCE/src/main.c" -o /tmp/landlock-bin/landlock-run

# @vscode/ripgrep's wrapper uses the pinned Rust source and cargo target config.
(cd "$RIPGREP_SOURCE" && "$cargo_bin" --config "$cargo_config" --locked build --release --features pcre2 --target loongarch64-unknown-linux-gnu)

# Build ONNX Runtime separately before sherpa; ONNXRUNTIME_ROOT must contain
# lib/libonnxruntime.so and ONNXRUNTIME_HEADERS the matching C/C++ headers.
onnx_lib="$ONNXRUNTIME_ROOT/lib/libonnxruntime.so"
if [[ ! -f "$onnx_lib" ]]; then
    onnx_lib=$(find "$ONNXRUNTIME_ROOT/lib" -maxdepth 1 -type f -name 'libonnxruntime.so*' | sort | head -n1)
    [[ -n "$onnx_lib" ]] || { echo 'missing ONNXRUNTIME_ROOT/lib/libonnxruntime.so' >&2; exit 2; }
fi
onnx_stage=/tmp/onnxruntime-loong64
rm -rf "$onnx_stage"
mkdir -p "$onnx_stage/lib" "$onnx_stage/include"
cp -a "$ONNXRUNTIME_HEADERS/." "$onnx_stage/include/"
cp -a "$ONNXRUNTIME_ROOT/lib/libonnxruntime.so*" "$onnx_stage/lib/" 2>/dev/null || cp "$onnx_lib" "$onnx_stage/lib/"
if [[ ! -e "$onnx_stage/lib/libonnxruntime.so" ]]; then ln -s "$(basename "$onnx_lib")" "$onnx_stage/lib/libonnxruntime.so"; fi
cp -a "$ONNXRUNTIME_ROOT/lib/libonnxruntime_providers_shared.so*" "$onnx_stage/lib/" 2>/dev/null || true
onnx_header_dir=$(dirname "$(find "$onnx_stage/include" -name onnxruntime_cxx_api.h -print -quit)")
[[ -n "$onnx_header_dir" && -f "$onnx_header_dir/onnxruntime_cxx_api.h" ]] || { echo 'missing onnxruntime_cxx_api.h' >&2; exit 2; }
export SHERPA_ONNXRUNTIME_LIB_DIR="$onnx_stage/lib" SHERPA_ONNXRUNTIME_INCLUDE_DIR="$onnx_header_dir"
if [[ -d "${SHERPA_DEPS_CACHE:-}" ]]; then
    mkdir -p /tmp/sherpa-loong64/_deps
    cp -a "$SHERPA_DEPS_CACHE/." /tmp/sherpa-loong64/_deps/
fi
[[ -d /tmp/sherpa-loong64/_deps && -n "$(find /tmp/sherpa-loong64/_deps -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
    echo 'SHERPA_DEPS_CACHE is required; provide pre-fetched CMake FetchContent dependencies' >&2
    exit 2
}
sherpa_cmake_args=(
    -S "$SHERPA_SOURCE" -B /tmp/sherpa-loong64
    -DCMAKE_TOOLCHAIN_FILE="$cmake_toolchain"
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/tmp/sherpa-loong64/install
    -DBUILD_SHARED_LIBS=ON -DSHERPA_ONNX_ENABLE_PYTHON=OFF
    -DSHERPA_ONNX_ENABLE_TESTS=OFF -DSHERPA_ONNX_ENABLE_CHECK=OFF
    -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF -DSHERPA_ONNX_ENABLE_JNI=OFF
    -DSHERPA_ONNX_ENABLE_C_API=ON -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF
    -DSHERPA_ONNX_ENABLE_GPU=OFF -DSHERPA_ONNX_ENABLE_TTS=ON
    -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=ON
    -DSHERPA_ONNX_LINK_LIBSTDCPP_STATICALLY=ON
    -DSHERPA_ONNX_USE_PRE_INSTALLED_ONNXRUNTIME_IF_AVAILABLE=ON
)
if [[ -d "${SHERPA_DEPS_CACHE:-}" ]]; then
    sherpa_cmake_args+=( -DFETCHCONTENT_FULLY_DISCONNECTED=ON )
fi
cmake "${sherpa_cmake_args[@]}"
cmake --build /tmp/sherpa-loong64 --parallel "$LOONG_JOBS"
cmake --install /tmp/sherpa-loong64

# The top-level sherpa build installs the C/C++ API; compile the Node-API
# addon separately, using the same headers and libraries.
addon_api=${SHERPA_NODE_ADDON_API:-$SHERPA_SOURCE/scripts/node-addon-api/node_modules/node-addon-api}
[[ -f "$addon_api/napi.h" ]] || { echo "missing node-addon-api headers: $addon_api" >&2; exit 2; }
node_include="$node_headers/include/node"
[[ -d "$node_include" ]] || { echo "missing Node headers: $node_include" >&2; exit 2; }
addon_source=/tmp/sherpa-addon-source-loong64
addon_build=/tmp/sherpa-addon-build-loong64
rm -rf "$addon_source" "$addon_build"
mkdir -p "$addon_source"
cat > "$addon_source/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.15)
project(sherpa_node_addon LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
file(GLOB addon_sources CONFIGURE_DEPENDS "$SHERPA_SOURCE/scripts/node-addon-api/src/*.cc")
add_library(sherpa-onnx SHARED \${addon_sources})
target_compile_definitions(sherpa-onnx PRIVATE BUILDING_NODE_EXTENSION)
target_include_directories(sherpa-onnx PRIVATE "$node_include" "$addon_api" "/tmp/sherpa-loong64/install/include")
set_target_properties(sherpa-onnx PROPERTIES PREFIX "" SUFFIX ".node" BUILD_RPATH "\$ORIGIN" INSTALL_RPATH "\$ORIGIN")
target_link_libraries(sherpa-onnx PRIVATE "/tmp/sherpa-loong64/install/lib/libsherpa-onnx-c-api.so" "$onnx_stage/lib/libonnxruntime.so")
install(TARGETS sherpa-onnx DESTINATION .)
EOF
cmake -S "$addon_source" -B "$addon_build" -DCMAKE_TOOLCHAIN_FILE="$cmake_toolchain" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$addon_build/install"
cmake --build "$addon_build" --parallel "$LOONG_JOBS"
cmake --install "$addon_build"

# Assemble one node_modules tree with the exact layouts expected by the loader.
staging=/tmp/native-staging/node_modules
rm -rf /tmp/native-staging
mkdir -p "$staging/node-pty" "$staging/sharp" "$staging/koffi" \
    "$staging/@deepseek-ai" "$staging/@vscode" \
    "$staging/sherpa-onnx-linux-loong64"
cp -a "$NODE_PTY_SOURCE/." "$staging/node-pty/"
cp -a "$SHARP_SOURCE/." "$staging/sharp/"
cp -a "$KOFFI_SOURCE/." "$staging/koffi/"
mkdir -p "$staging/@koromix/koffi-linux-loong64"
cp -a "$KOFFI_PLATFORM_SOURCE/." "$staging/@koromix/koffi-linux-loong64/"
mkdir -p "$staging/@koromix/koffi-linux-loong64/linux_loong64"
cp "$KOFFI_SOURCE/build/koffi/linux_loong64/koffi.node" \
    "$staging/@koromix/koffi-linux-loong64/linux_loong64/koffi.node"
mkdir -p "$staging/@deepseek-ai/node-addon-landlock-run" "$staging/@vscode/ripgrep"
cp -a "$LANDLOCK_WRAPPER/." "$staging/@deepseek-ai/node-addon-landlock-run/"
mkdir -p "$staging/@deepseek-ai/node-addon-landlock-run-linux-loong64"
cp -a "$LANDLOCK_PLATFORM/." "$staging/@deepseek-ai/node-addon-landlock-run-linux-loong64/"
cp -a "$RIPGREP_WRAPPER/." "$staging/@vscode/ripgrep/"
mkdir -p "$staging/@vscode/ripgrep-linux-loong64"
cp -a "$RIPGREP_PLATFORM/." "$staging/@vscode/ripgrep-linux-loong64/"
mkdir -p "$staging/@deepseek-ai/node-addon-landlock-run-linux-loong64/bin"
cp /tmp/landlock-bin/landlock-run "$staging/@deepseek-ai/node-addon-landlock-run-linux-loong64/bin/"
mkdir -p "$staging/@vscode/ripgrep-linux-loong64/bin"
cp "$CARGO_TARGET_DIR/loongarch64-unknown-linux-gnu/release/rg" "$staging/@vscode/ripgrep-linux-loong64/bin/"
cp -a "$SHERPA_WRAPPER/." "$staging/sherpa-onnx-linux-loong64/"
cp "$addon_build/install/sherpa-onnx.node" "$staging/sherpa-onnx-linux-loong64/"
cp /tmp/sherpa-loong64/install/lib/libsherpa-onnx-cxx-api.so "$staging/sherpa-onnx-linux-loong64/"
cp /tmp/sherpa-loong64/install/lib/libsherpa-onnx-c-api.so "$staging/sherpa-onnx-linux-loong64/"
cp -a "$onnx_stage/lib/libonnxruntime.so*" "$staging/sherpa-onnx-linux-loong64/"
cp -a "$onnx_stage/lib/libonnxruntime_providers_shared.so*" "$staging/sherpa-onnx-linux-loong64/" 2>/dev/null || true
while IFS= read -r -d '' file; do
    patchelf --set-rpath '$ORIGIN' "$file"
done < <(find "$staging/sharp/vendor/8.14.5" "$staging/sherpa-onnx-linux-loong64" \
    -type f \( -name '*.so' -o -name '*.so.*' -o -name '*.node' \) -print0)
patchelf --set-rpath '$ORIGIN/../.././vendor/8.14.5/linux-loong64/lib' \
    "$staging/sharp/build/Release/sharp-linux-loong64.node"
python3 /repo/scripts/package-release.py --arch loong64 --output "$output" \
    --modules "$staging" --version /repo/package.json \
    --spec 'node-pty=node-pty' --spec 'sharp=sharp' --spec 'koffi=koffi' \
    --spec 'landlock-run=@deepseek-ai/node-addon-landlock-run,@deepseek-ai/node-addon-landlock-run-linux-loong64' \
    --spec 'ripgrep=@vscode/ripgrep,@vscode/ripgrep-linux-loong64' \
    --spec 'sherpa-onnx-node=sherpa-onnx-linux-loong64'
