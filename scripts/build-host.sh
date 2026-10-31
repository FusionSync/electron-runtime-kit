#!/usr/bin/env bash
set -euo pipefail

arch=${1:?Usage: build-host.sh x64|arm64 [build-root] [output] [image] [extra-root]}
build_root=${2:-${NATIVE_BUILD_ROOT:-/home/ubuntu/electron37-native-build}}
output=${3:-${NATIVE_OUTPUT_ROOT:-$PWD/dist}}
image=${4:-${NATIVE_HOST_IMAGE:-electron37-native-builder:ubuntu18.04}}
extra_root=${5:-${NATIVE_EXTRA_ROOT:-}}
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
case "$arch" in x64|arm64) ;; *) echo "unsupported architecture: $arch" >&2; exit 2 ;; esac
[[ -d "$build_root" ]] || { echo "missing build root: $build_root" >&2; exit 2; }
[[ -d "$extra_root" ]] || {
    echo "missing native extra root: $extra_root" >&2
    echo 'It must contain the landlock, ripgrep, sherpa and ONNX Runtime inputs described in README.md.' >&2
    exit 2
}
for required in dependencies/package.json dependencies/package-lock.json dependencies/node_modules \
    docker/zig-cc-x64 docker/zig-cxx-x64 docker/zig-cc-arm64 docker/zig-cxx-arm64 \
    research/tools/meson-0.61.5 research/vips-8.14.5 research/cgif-0.3.2 \
    research/libimagequant-ce5fdeb1ccd9db288950faa21fd09c42c0a59bbb; do
    [[ -e "$build_root/$required" ]] || { echo "missing $build_root/$required" >&2; exit 2; }
done
[[ -d "$build_root/research/vips-shared-licenses" ]] || {
    echo "missing $build_root/research/vips-shared-licenses" >&2
    exit 2
}
if [[ "$arch" == arm64 ]]; then
    [[ -d "$build_root/research/vips-sysroot-arm64" ]] || {
        echo "missing $build_root/research/vips-sysroot-arm64" >&2
        exit 2
    }
fi
docker image inspect "$image" >/dev/null 2>&1 || {
    echo "Docker image $image is missing. Build or load the pinned Ubuntu 18.04 image first." >&2
    exit 2
}
mkdir -p "$output"
docker run --rm -i --user "$(id -u):$(id -g)" --cpus "${NATIVE_CPUS:-2}" \
    --memory "${NATIVE_MEMORY:-2g}" --network "${NATIVE_NETWORK:-host}" \
    -v "$repo:/repo:ro" -v "$build_root:/work" -v "$extra_root:/extras:ro" -v "$output:/artifacts" \
    -e RIPGREP_CARGO="${RIPGREP_CARGO:-/extras/rust/bin/cargo}" \
    -e RIPGREP_CARGO_CONFIG="${RIPGREP_CARGO_CONFIG:-/extras/rust/cargo-config.toml}" \
    -e RIPGREP_RUSTC="${RIPGREP_RUSTC:-/extras/rust/bin/rustc}" \
    -e RIPGREP_RUSTDOC="${RIPGREP_RUSTDOC:-/extras/rust/bin/rustdoc}" \
    -e CARGO_HOME="${CARGO_HOME:-/extras/rust/cargo-home}" \
    -e SHERPA_DEPS_CACHE="${SHERPA_DEPS_CACHE:-/extras/sherpa-deps-cache}" \
    -w /work "$image" bash -se -- build-host "$arch" /extras <<'CONTAINER'
set -euo pipefail
arch=${1:?missing architecture}
extra_root=${2:?missing native extra root}
[[ -d /work/dependencies/node_modules ]] || {
    echo 'missing /work/dependencies/node_modules; prepare the audited dependency workspace first' >&2
    exit 2
}
[[ -f /work/dependencies/package.json && -f /work/dependencies/package-lock.json ]] || {
    echo 'dependencies/package.json and package-lock.json are required by the validated build' >&2
    exit 2
}
rm -rf "/work/build/$arch"
bash /repo/scripts/host/build-vips-shared.sh "$arch"
bash /repo/scripts/host/build-native.sh "$arch"
command -v patchelf >/dev/null || { echo 'patchelf is required by the sharp vendor layout' >&2; exit 2; }
sharp_arch=x64
[[ "$arch" == arm64 ]] && sharp_arch=arm64v8
patchelf --set-rpath '$ORIGIN/../.././vendor/8.14.5/linux-'"$sharp_arch"'/lib' \
    "/work/build/$arch/node_modules/sharp/build/Release/sharp-linux-$sharp_arch.node"
bash /repo/scripts/host/build-extras.sh "$arch" "$extra_root" "/work/build/$arch"
platform_koffi="@koromix/koffi-linux-$arch"
python3 /repo/scripts/package-release.py --arch "$arch" --output /artifacts \
    --modules "/work/build/$arch/node_modules" --version /repo/package.json \
    --spec "node-pty=node-pty" --spec "sharp=sharp" \
    --spec "koffi=koffi,$platform_koffi" \
    --spec "landlock-run=@deepseek-ai/node-addon-landlock-run,@deepseek-ai/node-addon-landlock-run-$arch" \
    --spec "ripgrep=@vscode/ripgrep,@vscode/ripgrep-$arch" \
    --spec "sherpa-onnx-node=sherpa-onnx-linux-$arch"
CONTAINER
